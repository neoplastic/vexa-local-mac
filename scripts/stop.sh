#!/usr/bin/env bash
# Stop Vexa, the desktop host and Whisper. Pass --colima to also stop the Colima VM.
. "$(dirname "$0")/lib.sh"
load_env

if docker info >/dev/null 2>&1; then
  info "Stopping meeting bots"
  bots=$(docker ps -q --filter "ancestor=${BROWSER_IMAGE:-$BOT_IMAGE_LOCAL}")
  [ -n "$bots" ] && docker stop $bots >/dev/null
  info "Stopping Vexa containers"
  compose down
else
  warn "Docker isn't reachable; skipping containers"
fi

"$ROOT/scripts/desktop.sh" stop >/dev/null || true
"$ROOT/scripts/whisper.sh" stop

if [ "${1:-}" = "--colima" ]; then
  info "Stopping Colima"
  colima stop --profile "${COLIMA_PROFILE:-default}"
fi
ok "Stopped"
