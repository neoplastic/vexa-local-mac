#!/usr/bin/env bash
# One-time setup: check tools, fetch Vexa, write .env, install Whisper, download
# the model, pull Vexa's published images, build the meeting bot natively, and
# build the app into /Applications.
. "$(dirname "$0")/lib.sh"

info "Checking prerequisites"
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || die "This setup needs an Apple Silicon Mac."
missing=()
for cmd in colima docker git uv ffmpeg pnpm python3 openssl; do
  command -v "$cmd" >/dev/null || missing+=("$cmd")
done
docker compose version >/dev/null 2>&1 || missing+=("docker-compose")
docker buildx version >/dev/null 2>&1 || missing+=("docker-buildx")
if [ ${#missing[@]} -gt 0 ]; then
  plugins="$(brew --prefix 2>/dev/null || echo /opt/homebrew)/lib/docker/cli-plugins"
  if [ -e "$plugins/docker-compose" ] || [ -e "$plugins/docker-buildx" ]; then
    warn "If docker-compose and docker-buildx are installed, Docker may not see them. Add"
    warn "  \"cliPluginsExtraDirs\": [\"$plugins\"]  to ~/.docker/config.json"
  fi
  die "Missing: ${missing[*]}. Install with: brew install colima docker docker-compose docker-buildx uv ffmpeg pnpm"
fi
ok "Tools present"
use_modern_node
ok "Node $(node --version) ($(command -v node))"

# Docker Desktop leaves credsStore=desktop behind, which breaks image pulls.
if [ -f "$HOME/.docker/config.json" ] && grep -q '"credsStore": *"desktop"' "$HOME/.docker/config.json" \
   && ! command -v docker-credential-desktop >/dev/null; then
  warn "~/.docker/config.json uses Docker Desktop's credential helper, which isn't installed."
  warn "Remove the \"credsStore\": \"desktop\" line, or image pulls will fail."
fi

# --- Vexa source ----------------------------------------------------------------
info "Fetching Vexa $VEXA_REF"
if [ -d "$VEXA_DIR/.git" ] && [ "$(git -C "$VEXA_DIR" remote get-url origin)" != "$VEXA_REPO" ]; then
  warn "vexa/ is a checkout of $(git -C "$VEXA_DIR" remote get-url origin); replacing it with $VEXA_REPO"
  rm -rf "$VEXA_DIR"
fi
if [ ! -d "$VEXA_DIR/.git" ]; then
  git clone --quiet --filter=blob:none "$VEXA_REPO" "$VEXA_DIR"
fi
git -C "$VEXA_DIR" fetch --quiet --tags origin
git -C "$VEXA_DIR" checkout --quiet --force "$VEXA_REF"
ok "Vexa checked out at $VEXA_REF ($(git -C "$VEXA_DIR" rev-parse --short HEAD))"

for p in "$ROOT"/patches/*.patch; do
  [ -e "$p" ] || continue
  git -C "$VEXA_DIR" apply "$p" || die "Patch failed: $(basename "$p")"
  ok "Applied $(basename "$p")"
done

# --- .env -----------------------------------------------------------------------
if [ -f "$ROOT/.env" ] && ! grep -q '^TRANSCRIPTION_SERVICE_URL=' "$ROOT/.env"; then
  mv "$ROOT/.env" "$ROOT/.env.v010.bak"
  warn "Moved the old Vexa 0.10 settings to .env.v010.bak"
fi
if [ ! -f "$ROOT/.env" ]; then
  info "Writing .env (Vexa defaults + local settings + fresh secrets)"
  ( umask 077; cp "$COMPOSE_DIR/.env.example" "$ROOT/.env" )
  printf '\n# ==== vexa-local-mac (applied by scripts/setup.sh) ====\n' >> "$ROOT/.env"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    [ "$value" = generate ] && value="$(openssl rand -hex 32)"
    set_env "$key" "$value"
  done < "$ROOT/.env.example"
  ok ".env created"
else
  ok ".env already exists (kept)"
fi
# The runtime container needs the Docker socket's group inside the Colima VM.
ensure_colima
gid="$(docker run --rm -v /var/run/docker.sock:/s alpine:3.20 stat -c %g /s)"
set_env DOCKER_GID "$gid"
# Vexa's compose file also reads deploy/compose/.env (env_file:), so point it at ours.
ln -sf "$ROOT/.env" "$COMPOSE_DIR/.env"
load_env

# --- Whisper ----------------------------------------------------------------------
info "Installing the Whisper server (mlx-whisper)"
(cd "$WHISPER_DIR" && uv sync --quiet)
info "Downloading $WHISPER_MODEL from Hugging Face"
(cd "$WHISPER_DIR" && .venv/bin/python -c "import sys; from huggingface_hub import snapshot_download; print(snapshot_download(sys.argv[1]))" "$WHISPER_MODEL")
ok "Model cached"

# --- Images -----------------------------------------------------------------------
info "Pulling Vexa's published images (arm64)"
compose pull --quiet

info "Building the meeting bot natively for Apple Silicon (the slow step)"
docker build -t vexa/meet-join-env:dev \
  -f "$VEXA_DIR/core/meetings/modules/join/Dockerfile.env" "$VEXA_DIR/core/meetings/modules/join"
docker build -t "$BOT_IMAGE_LOCAL" \
  --build-arg VEXA_IMAGE_VERSION="$(git -C "$VEXA_DIR" rev-parse --short HEAD)" \
  -f "$VEXA_DIR/core/meetings/services/bot/Dockerfile" "$VEXA_DIR"
ok "Built $BOT_IMAGE_LOCAL ($(docker image inspect -f '{{.Architecture}}' "$BOT_IMAGE_LOCAL"))"

# --- Browser extension + desktop host ---------------------------------------------
# Google Meet and Zoom refuse bots, so those meetings are captured from your own
# Chrome tab by Vexa's extension, which streams audio to a local "desktop host".
if command -v pnpm >/dev/null; then
  "$ROOT/scripts/desktop.sh" start && "$ROOT/scripts/desktop.sh" stop >/dev/null
else
  warn "pnpm isn't installed; skipping the browser extension (brew install pnpm, then make setup)"
fi

# --- Cleanup ----------------------------------------------------------------------
# Pulls and rebuilds leave the previous images behind (several GB each time).
# Remove superseded Vexa images, stopped bot containers and the build cache.
info "Removing superseded Vexa images and the build cache"
"$ROOT/scripts/cleanup.sh" || warn "Cleanup didn't finish; run 'make cleanup' later to free disk space."

# --- The app ----------------------------------------------------------------------
# Same steps as 'make install'. Not fatal: Vexa itself is set up by now. When this runs
# from the app (or the app is open), the running copy isn't replaced; the app's setup
# assistant offers "Move to Applications" instead.
APP_NAME="Vexa Local.app"
info "Building the Vexa Local app"
if "$ROOT/app/build-app.sh"; then
  if pgrep -x VexaLocal >/dev/null; then
    warn "Vexa Local is open, so it wasn't copied to /Applications."
    warn "Use Move to Applications in its setup assistant, or quit it and run: make install"
  elif rm -rf "/Applications/$APP_NAME" && ditto "$ROOT/app/build/$APP_NAME" "/Applications/$APP_NAME"; then
    defaults write io.github.vexa-local-mac vexa.projectPath "$ROOT"
    ok "Installed /Applications/$APP_NAME"
  else
    warn "Couldn't copy the app to /Applications. Run: make install"
  fi
else
  warn "The app didn't build (it needs Xcode or the Command Line Tools). Run 'make install' later."
fi

ok "Setup finished. Next: make start (or open Vexa Local from Applications)"
