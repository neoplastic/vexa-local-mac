# Shared helpers. Sourced by the other scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VEXA_DIR="$ROOT/vexa"
RUN_DIR="$ROOT/.run"
LOG_DIR="$ROOT/logs"
WHISPER_DIR="$ROOT/whisper-server"

# Upstream Vexa repo and the commit this setup was tested against.
VEXA_REPO="${VEXA_REPO:-https://github.com/SaharCarmel/vexa}"
VEXA_REF="${VEXA_REF:-1bf81edeecd6b30ca6a2114946609ef0cb3c0eb3}"

mkdir -p "$RUN_DIR" "$LOG_DIR"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

load_env() {
  [ -f "$ROOT/.env" ] || die "No .env found. Run 'make setup' first."
  set -a; . "$ROOT/.env"; set +a
}

compose() {
  docker compose \
    --project-directory "$VEXA_DIR" \
    --env-file "$ROOT/.env" \
    -f "$VEXA_DIR/docker-compose.yml" \
    -f "$VEXA_DIR/docker-compose.local-db.yml" \
    -f "$ROOT/compose.mac.yml" \
    "$@"
}

http_ok() {  # http_ok URL  -> exit 0 if the URL answers 2xx
  python3 - "$1" <<'PY' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen(sys.argv[1], timeout=3)
PY
}

ensure_colima() {
  if colima status --profile "${COLIMA_PROFILE:-default}" >/dev/null 2>&1; then
    ok "Colima is running"
  else
    info "Starting Colima (${COLIMA_CPUS:-6} CPU, ${COLIMA_MEMORY:-12} GB RAM, ${COLIMA_DISK:-100} GB disk)"
    # --vz-rosetta: only needed if you build the bot with BOT_PLATFORM=linux/amd64.
    colima start --profile "${COLIMA_PROFILE:-default}" \
      --cpu "${COLIMA_CPUS:-6}" --memory "${COLIMA_MEMORY:-12}" --disk "${COLIMA_DISK:-100}" \
      --vm-type vz --vz-rosetta
  fi
  docker info >/dev/null 2>&1 || die "Docker cannot reach Colima. Try: docker context use colima"
}

whisper_url() { echo "http://${WHISPER_HOST:-127.0.0.1}:${WHISPER_PORT:-8083}"; }

whisper_running() {
  [ -f "$RUN_DIR/whisper.pid" ] && kill -0 "$(cat "$RUN_DIR/whisper.pid")" 2>/dev/null
}
