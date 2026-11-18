#!/usr/bin/env bash
# Show a meeting bot's browser so you can see it and take over (sign in, join by hand).
#   scripts/bot-view.sh            # newest running bot
#   scripts/bot-view.sh <container>
#   scripts/bot-view.sh stop       # close the viewer
# Opens http://localhost:6080 (this Mac only). Mouse and keyboard work in the viewer.
. "$(dirname "$0")/lib.sh"

RELAY=vexa-bot-view
PORT="${BOT_VIEW_PORT:-6080}"

if [ "${1:-}" = "stop" ]; then
  docker rm -f "$RELAY" >/dev/null 2>&1 && ok "Viewer closed" || ok "No viewer running"
  exit 0
fi

bot="${1:-$(docker ps --filter name=vexa-mtg- --format '{{.CreatedAt}}\t{{.Names}}' | sort -r | head -1 | cut -f2)}"
[ -n "$bot" ] || die "No meeting bot is running. Send a bot to a meeting first."
docker ps --format '{{.Names}}' | grep -qx "$bot" || die "Bot container '$bot' isn't running."

# The bot starts its own VNC server when it asks for help; start one now if it hasn't.
if ! docker exec "$bot" sh -c 'pgrep -x x11vnc >/dev/null'; then
  info "Starting the VNC server inside $bot"
  docker exec -d "$bot" x11vnc -display "${BOT_DISPLAY:-:99}" -forever -shared -nopw -rfbport 5900 -quiet
  for _ in $(seq 1 20); do
    docker exec "$bot" sh -c 'pgrep -x x11vnc >/dev/null' && break
    sleep 0.5
  done
fi

network="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$bot")"
relay_image="$(docker image inspect -f '{{.Id}}' vexa/meet-join-env:dev >/dev/null 2>&1 && echo vexa/meet-join-env:dev || echo "$BOT_IMAGE_LOCAL")"

docker rm -f "$RELAY" >/dev/null 2>&1 || true
info "Relaying $bot's screen to http://localhost:$PORT"
docker run -d --rm --name "$RELAY" --network "$network" -p "127.0.0.1:$PORT:6080" \
  --entrypoint websockify "$relay_image" --web /usr/share/novnc 6080 "$bot:5900" >/dev/null

for _ in $(seq 1 30); do http_ok "http://localhost:$PORT/vnc.html" && break; sleep 0.5; done
http_ok "http://localhost:$PORT/vnc.html" || die "The viewer didn't start. Check: docker logs $RELAY"

url="http://localhost:$PORT/vnc.html?autoconnect=1&resize=scale&reconnect=1"
ok "Viewer ready: $url"
echo "  Close it with: scripts/bot-view.sh stop"
[ "${BOT_VIEW_NO_OPEN:-}" = 1 ] || open "$url"
