#!/usr/bin/env bash
# One-time setup: check tools, fetch Vexa, write .env, install Whisper,
# download the model from Hugging Face, and build the Docker images.
. "$(dirname "$0")/lib.sh"

info "Checking prerequisites"
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || die "This setup needs an Apple Silicon Mac."
missing=()
for cmd in colima docker git uv ffmpeg python3 openssl; do
  command -v "$cmd" >/dev/null || missing+=("$cmd")
done
docker compose version >/dev/null 2>&1 || missing+=("docker-compose")
if [ ${#missing[@]} -gt 0 ]; then
  die "Missing: ${missing[*]}. Install with: brew install colima docker docker-compose docker-buildx uv ffmpeg"
fi
ok "Tools present"

# Docker Desktop leaves credsStore=desktop behind, which breaks image pulls
# once Docker Desktop is gone.
if [ -f "$HOME/.docker/config.json" ] && grep -q '"credsStore": *"desktop"' "$HOME/.docker/config.json" \
   && ! command -v docker-credential-desktop >/dev/null; then
  warn "~/.docker/config.json uses Docker Desktop's credential helper, which isn't installed."
  warn "Remove the \"credsStore\": \"desktop\" line, or image pulls will fail."
fi

info "Fetching Vexa ($VEXA_REF)"
if [ ! -d "$VEXA_DIR/.git" ]; then
  git clone "$VEXA_REPO" "$VEXA_DIR"
fi
git -C "$VEXA_DIR" fetch --quiet origin "$VEXA_REF" 2>/dev/null || git -C "$VEXA_DIR" fetch --quiet origin
# Reset tracked files so patches always apply to a clean tree.
git -C "$VEXA_DIR" checkout --quiet --force "$VEXA_REF"
git -C "$VEXA_DIR" submodule update --init --recursive --quiet
ok "Vexa checked out at $(git -C "$VEXA_DIR" rev-parse --short HEAD)"

for p in "$ROOT"/patches/*.patch; do
  [ -e "$p" ] || continue
  git -C "$VEXA_DIR" apply "$p" || die "Patch failed: $(basename "$p")"
  ok "Applied $(basename "$p")"
done

if [ ! -f "$ROOT/.env" ]; then
  info "Writing .env with fresh secrets"
  : > "$ROOT/.env"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^([A-Z_]+)=generate$ ]]; then
      echo "${BASH_REMATCH[1]}=$(openssl rand -hex 24)" >> "$ROOT/.env"
    else
      echo "$line" >> "$ROOT/.env"
    fi
  done < "$ROOT/.env.example"
  chmod 600 "$ROOT/.env"
  ok ".env created"
else
  ok ".env already exists (kept)"
fi
# Vexa's own Makefile reads vexa/.env, so point it at ours.
ln -sf ../.env "$VEXA_DIR/.env"
load_env

info "Installing the Whisper server (mlx-whisper)"
(cd "$WHISPER_DIR" && uv sync --quiet)
info "Downloading $WHISPER_MODEL from Hugging Face"
(cd "$WHISPER_DIR" && .venv/bin/python -c "import sys; from huggingface_hub import snapshot_download; print(snapshot_download(sys.argv[1]))" "$WHISPER_MODEL")
ok "Model cached"

ensure_colima

# Native ARM by default: Chromium handles Meet and Teams. linux/amd64 adds
# Microsoft Edge for Teams but runs under Rosetta, which is much slower.
BOT_PLATFORM="${BOT_PLATFORM:-linux/arm64}"
info "Building the meeting-bot image ($BOT_PLATFORM; this is the slow one)"
docker build --platform "$BOT_PLATFORM" -t "$BOT_IMAGE_NAME" -f "$VEXA_DIR/services/vexa-bot/Dockerfile" "$VEXA_DIR/services/vexa-bot"

info "Building the Vexa service images"
compose build

ok "Setup finished. Next: make start"
