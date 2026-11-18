#!/usr/bin/env bash
# Create a Vexa user (or reuse an existing one) and issue an API key.
# Usage: scripts/create-user.sh you@example.com [name]
. "$(dirname "$0")/lib.sh"
load_env

EMAIL="${1:-}"
[ -n "$EMAIL" ] || die "Usage: make user EMAIL=you@example.com"

python3 - "$EMAIL" "${2:-}" "http://localhost:${ADMIN_API_HOST_PORT}" "$ADMIN_API_TOKEN" <<'PY'
import json, sys, urllib.request, urllib.error

email, name, base, token = sys.argv[1:5]
headers = {"X-Admin-API-Key": token, "Content-Type": "application/json"}

def call(method, path, body=None):
    req = urllib.request.Request(base + path, method=method, headers=headers,
                                 data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read() or b"{}")

try:
    user = call("POST", "/admin/users", {"email": email, "name": name or None, "max_concurrent_bots": 3})
    tok = call("POST", f"/admin/users/{user['id']}/tokens")
except urllib.error.HTTPError as e:
    sys.exit(f"Admin API error {e.code}: {e.read().decode(errors='replace')}")
except urllib.error.URLError as e:
    sys.exit(f"Cannot reach the admin API at {base} ({e.reason}). Is Vexa running? Try: make start")
print(f"User:    {user['email']} (id {user['id']})")
print(f"API key: {tok['token']}")
PY
