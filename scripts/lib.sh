# Shared helpers. Sourced by the other scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VEXA_DIR="$ROOT/vexa"
COMPOSE_DIR="$VEXA_DIR/deploy/compose"
RUN_DIR="$ROOT/.run"
LOG_DIR="$ROOT/logs"
WHISPER_DIR="$ROOT/whisper-server"

# Official Vexa and the release this setup was tested against.
VEXA_REPO="${VEXA_REPO:-https://github.com/Vexa-ai/vexa}"
VEXA_REF="${VEXA_REF:-v0.12.28}"

# The meeting bot is built locally for the Mac's architecture (the published
# vexaai/vexa-bot image is amd64-only).
BOT_IMAGE_LOCAL="vexa/vexa-bot:local"

mkdir -p "$RUN_DIR" "$LOG_DIR"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Reads .env as plain KEY=VALUE lines (no shell evaluation: values may contain
# spaces or ${...} that Docker Compose, not bash, should interpret).
load_env() {
  [ -f "$ROOT/.env" ] || die "No .env found. Run 'make setup' first."
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
    export "$key=$value"
  done < "$ROOT/.env"
}

# Talk to Colima's Docker directly, whatever `docker context` is currently set to.
export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.colima/${COLIMA_PROFILE:-default}/docker.sock}"

compose() {
  docker compose \
    --project-directory "$COMPOSE_DIR" \
    --env-file "$ROOT/.env" \
    -f "$COMPOSE_DIR/docker-compose.yml" \
    "$@"
}

http_ok() {  # http_ok URL  -> exit 0 if the URL answers 2xx
  python3 - "$1" <<'PY' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen(sys.argv[1], timeout=3)
PY
}

# Vexa's desktop host needs Node 20 or newer. The app starts scripts without your
# shell setup, so nvm/fnm/Volta Nodes aren't on PATH and an old /usr/local/bin/node
# can win. Put a suitable Node first on PATH, preferring the one your shell uses
# (so native modules match the Node they were installed with).
node_major() { "$1" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }
use_modern_node() {
  local min=20 cand nvm_default="" alias="default" i
  # nvm aliases chain (default → lts/jod → v22.23.4); follow them to a version.
  for i in 1 2 3 4; do
    [ -f "$HOME/.nvm/alias/$alias" ] || break
    alias="$(head -1 "$HOME/.nvm/alias/$alias")"
  done
  if [ -n "$alias" ] && [ "$alias" != "default" ]; then
    nvm_default="$( (ls -d "$HOME"/.nvm/versions/node/v"${alias#v}"* 2>/dev/null || true) | sort -V | tail -1)"
    [ -n "$nvm_default" ] && nvm_default="$nvm_default/bin/node"
  fi
  # shellcheck disable=SC2046
  for cand in "$(command -v node 2>/dev/null)" "$nvm_default" \
              /opt/homebrew/bin/node "$HOME/.volta/bin/node" \
              $(ls -d "$HOME"/.nvm/versions/node/*/bin/node "$HOME"/.local/share/fnm/node-versions/*/installation/bin/node 2>/dev/null | sort -rV); do
    [ -x "$cand" ] && [ "$(node_major "$cand")" -ge "$min" ] || continue
    export PATH="$(dirname "$cand"):$PATH"
    return 0
  done
  die "Node $min or newer is needed for the desktop host (found $(node --version 2>/dev/null || echo none)). Install it: brew install node"
}

ensure_colima() {
  if colima status --profile "${COLIMA_PROFILE:-default}" >/dev/null 2>&1; then
    ok "Colima is running"
  else
    info "Starting Colima (${COLIMA_CPUS:-6} CPU, ${COLIMA_MEMORY:-12} GB RAM, ${COLIMA_DISK:-100} GB disk)"
    colima start --profile "${COLIMA_PROFILE:-default}" \
      --cpu "${COLIMA_CPUS:-6}" --memory "${COLIMA_MEMORY:-12}" --disk "${COLIMA_DISK:-100}" \
      --vm-type vz
  fi
  docker info >/dev/null 2>&1 || die "Docker cannot reach Colima at $DOCKER_HOST"
}

whisper_url() { echo "http://${WHISPER_HOST:-127.0.0.1}:${WHISPER_PORT:-8083}"; }

whisper_running() {
  [ -f "$RUN_DIR/whisper.pid" ] && kill -0 "$(cat "$RUN_DIR/whisper.pid")" 2>/dev/null
}

# set_env KEY VALUE — set a key in .env in place (keeps the file's permissions).
set_env() {
  local key="$1" value="$2" file="$ROOT/.env" tmp
  tmp="$(mktemp "$RUN_DIR/env.XXXXXX")"
  if grep -qE "^${key}=" "$file"; then
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k {print k "=" v; next} {print}' "$file" > "$tmp"
  else
    cat "$file" > "$tmp"; printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  cat "$tmp" > "$file"; rm -f "$tmp"
}
