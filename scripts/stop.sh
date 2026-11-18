#!/usr/bin/env bash
# Stop Vexa and Whisper. Pass --colima to also stop the Colima VM.
. "$(dirname "$0")/lib.sh"
load_env

if docker info >/dev/null 2>&1; then
  info "Stopping meeting-bot containers"
  bots=$(docker ps -q --filter "ancestor=$BOT_IMAGE_NAME")
  [ -n "$bots" ] && docker stop $bots >/dev/null
  info "Stopping Vexa containers"
  compose down
fi

"$ROOT/scripts/whisper.sh" stop

if [ "${1:-}" = "--colima" ]; then
  info "Stopping Colima"
  colima stop --profile "${COLIMA_PROFILE:-default}"
fi
ok "Stopped"
