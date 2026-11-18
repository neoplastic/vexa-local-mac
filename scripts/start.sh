#!/usr/bin/env bash
# Start everything: Colima, native Whisper, then the Vexa containers.
. "$(dirname "$0")/lib.sh"
load_env

[ -d "$VEXA_DIR" ] || die "Vexa is not set up. Run 'make setup' first."

ensure_colima

# --- Native Whisper -----------------------------------------------------------
"$ROOT/scripts/whisper.sh" start

# --- Vexa ---------------------------------------------------------------------
info "Starting Vexa containers"
compose up -d

info "Waiting for Postgres"
for _ in $(seq 1 60); do
  compose exec -T postgres pg_isready -U postgres -q 2>/dev/null && break
  sleep 2
done

info "Running database migrations"
make -s -C "$VEXA_DIR" migrate-or-init >/dev/null

for _ in $(seq 1 60); do
  http_ok "http://localhost:${API_GATEWAY_HOST_PORT}/docs" && break
  sleep 2
done

ok "Vexa is up"
cat <<EOF

  API gateway   http://localhost:${API_GATEWAY_HOST_PORT}/docs
  Admin API     http://localhost:${ADMIN_API_HOST_PORT}/docs
  Dashboard     http://localhost:${DASHBOARD_HOST_PORT}   (user: ${DASHBOARD_ADMIN_USERNAME}, password in .env)
  MCP server    http://localhost:${MCP_HOST_PORT}
  Whisper       $(whisper_url)  (native, logs/whisper.log)

  Create an API key:   make user EMAIL=you@example.com
EOF
