#!/usr/bin/env bash
# Vexa "desktop" capture host: transcribes meetings you attend yourself, from the
# Vexa browser extension (no bot joins). Uses the native Whisper server.
#   scripts/desktop.sh start|stop|restart|status|selftest
# Listens on ws://localhost:9099/ingest (extension audio) and http://localhost:8056
# (transcripts). No Docker needed.
. "$(dirname "$0")/lib.sh"
load_env
use_modern_node

DESKTOP_DIR="$VEXA_DIR/core/meetings/services/desktop"
EXT_DIR="$VEXA_DIR/clients/extension"
PID_FILE="$RUN_DIR/desktop.pid"
GATEWAY="http://localhost:8056"

desktop_running() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

install_desktop() {
  if [ ! -x "$DESKTOP_DIR/node_modules/.bin/tsx" ]; then
    info "Installing the desktop host (pnpm)"
    (cd "$VEXA_DIR" && pnpm install --silent --filter "@vexa/desktop...")
  fi
  # The host imports its sibling Vexa modules from their compiled dist/.
  if [ ! -f "$VEXA_DIR/core/meetings/modules/whisper/dist/index.js" ]; then
    info "Building the desktop host's Vexa modules"
    (cd "$VEXA_DIR" && pnpm --silent --filter "@vexa/desktop^..." run build)
  fi
  # Build once, and again whenever its source changes (e.g. a patch in patches/).
  if [ ! -f "$EXT_DIR/dist/manifest.json" ] \
     || [ -n "$(find "$EXT_DIR/src" -newer "$EXT_DIR/dist/manifest.json" -type f -print -quit)" ]; then
    info "Building the browser extension"
    (cd "$EXT_DIR" && npm ci --silent --no-audit --no-fund && node build.mjs)
  fi
}

start_desktop() {
  command -v pnpm >/dev/null || die "pnpm is needed: brew install pnpm (or corepack enable)"
  install_desktop
  "$ROOT/scripts/whisper.sh" start
  if desktop_running; then
    ok "Desktop host already running (pid $(cat "$PID_FILE"))"
  else
    info "Starting the desktop host"
    mkdir -p "$ROOT/recordings"
    (
      cd "$DESKTOP_DIR"
      TRANSCRIPTION_SERVICE_URL="$(whisper_url)" \
      TRANSCRIPTION_SERVICE_TOKEN="$TRANSCRIPTION_SERVICE_TOKEN" \
      TRANSCRIPTION_MODEL="${TRANSCRIPTION_MODEL:-whisper-large-v3-turbo}" \
      VEXA_RECORDINGS_DIR="$ROOT/recordings" \
        nohup ./node_modules/.bin/tsx src/desktop.ts >> "$LOG_DIR/desktop.log" 2>&1 < /dev/null &
      echo $! > "$PID_FILE"
    )
  fi
  for _ in $(seq 1 60); do http_ok "$GATEWAY/bots" && break; desktop_running || die "Desktop host exited. See logs/desktop.log"; sleep 1; done
  http_ok "$GATEWAY/bots" || die "Desktop host did not start. See logs/desktop.log"
  ok "Desktop host ready: ingest ws://localhost:9099/ingest, transcripts $GATEWAY"
  echo "  Extension to load in Chrome (chrome://extensions → Load unpacked): $EXT_DIR/dist"
}

stop_desktop() {
  if desktop_running; then
    pid="$(cat "$PID_FILE")"
    info "Stopping the desktop host"
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
}

selftest_desktop() {
  desktop_running || die "Desktop host isn't running. Run: scripts/desktop.sh start"
  # Global (not local): the EXIT trap runs after this function has returned.
  SELFTEST_TMP="$(mktemp -d "$RUN_DIR/desktop-selftest.XXXXXX")"
  trap 'rm -rf "$SELFTEST_TMP"; rm -f "$DESKTOP_DIR/.selftest.tmp.mts"' EXIT
  local tmp="$SELFTEST_TMP"
  say -o "$tmp/t.aiff" "Good morning everyone. Let's review the launch plan and agree on the next steps before Friday."
  ffmpeg -loglevel error -y -i "$tmp/t.aiff" -ar 16000 -ac 1 -f f32le "$tmp/t.f32"
  # Run from inside the package so its imports resolve.
  cp "$ROOT/scripts/desktop-selftest.mts" "$DESKTOP_DIR/.selftest.tmp.mts"
  info "Streaming a spoken clip into the desktop host, like the extension does"
  (cd "$DESKTOP_DIR" && ./node_modules/.bin/tsx ./.selftest.tmp.mts "$tmp/t.f32" google_meet)
}

case "${1:-status}" in
  start)   start_desktop ;;
  selftest) selftest_desktop ;;
  stop)    stop_desktop; ok "Desktop host stopped" ;;
  restart) stop_desktop; start_desktop ;;
  status)  if desktop_running && http_ok "$GATEWAY/bots"; then ok "Desktop host up ($GATEWAY)"; else warn "Desktop host not running"; exit 1; fi ;;
  *)       die "Usage: desktop.sh start|stop|restart|status|selftest" ;;
esac
