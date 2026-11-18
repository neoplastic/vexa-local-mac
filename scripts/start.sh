#!/usr/bin/env bash
# Start everything: Colima, native Whisper, then the Vexa containers.
. "$(dirname "$0")/lib.sh"
load_env

[ -d "$COMPOSE_DIR" ] || die "Vexa is not set up. Run 'make setup' first."

ensure_colima
"$ROOT/scripts/whisper.sh" start

info "Starting Vexa containers"
compose up -d --no-build

info "Waiting for the API gateway"
for _ in $(seq 1 90); do
  http_ok "http://localhost:${API_GATEWAY_HOST_PORT}/health" && break
  sleep 2
done
http_ok "http://localhost:${API_GATEWAY_HOST_PORT}/health" || die "The gateway did not become healthy. Check: make logs"

# Desktop host for the browser extension (Google Meet and Zoom). Not fatal if it fails.
if command -v pnpm >/dev/null; then
  "$ROOT/scripts/desktop.sh" start || warn "The desktop host didn't start. See logs/desktop.log"
else
  warn "pnpm isn't installed, so the browser-extension route is off (brew install pnpm)"
fi

ok "Vexa is up"
cat <<EOF

  Vexa web app  http://localhost:${TERMINAL_PORT}
  API gateway   http://localhost:${API_GATEWAY_HOST_PORT}
  MCP server    http://localhost:18010
  Whisper       $(whisper_url)  (native, logs/whisper.log)
  Desktop host  http://localhost:8056  (browser extension, logs/desktop.log)
  Extension     $VEXA_DIR/clients/extension/dist  (Chrome → Load unpacked)

  Create an API key:   make user EMAIL=you@example.com
EOF
