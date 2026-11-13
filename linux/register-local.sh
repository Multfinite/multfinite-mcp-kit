#!/usr/bin/env bash
# Register one Windows gateway into an existing MetaMCP database. The JSON
# bundle (including its secret) arrives only on stdin, e.g. through SSH.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
METAMCP_DIR="${HOME}/mcp-global/metamcp"
SEED_SQL="${SCRIPT_DIR}/seed-local.sql"
force=false
stdin=false
for arg in "$@"; do
    case "$arg" in
        --stdin) stdin=true ;;
        --force) force=true ;;
        *) echo "Usage: $0 --stdin [--force] < registration.json" >&2; exit 2 ;;
    esac
done
if [ "$stdin" != true ]; then
    echo "Usage: $0 --stdin [--force] < registration.json" >&2
    exit 2
fi
command -v jq >/dev/null || { echo 'jq is required.' >&2; exit 1; }
command -v docker >/dev/null || { echo 'Docker is required.' >&2; exit 1; }
[ -f "$SEED_SQL" ] || { echo "Missing $SEED_SQL." >&2; exit 1; }
[ -f "$METAMCP_DIR/.env" ] || { echo 'Existing MetaMCP installation not found; run install-global.sh first.' >&2; exit 1; }
if ! docker info >/dev/null 2>&1; then echo 'Docker is not available to this user.' >&2; exit 1; fi

bundle="$(cat)"
if (( ${#bundle} > 16384 )) || ! jq -e '
    type == "object" and .version == 1
    and (.hostId | type == "string" and length <= 32 and test("^[a-z0-9]+(-[a-z0-9]+)*$"))
    and (.gatewayKey | type == "string" and test("^[a-f0-9]{64}$"))
    and (.ownerEmail | type == "string" and length >= 3 and length <= 320 and test("^[^[:space:]]+@[^[:space:]]+$"))
    and (.baseUrl | type == "string" and length <= 2048 and test("^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/[a-zA-Z0-9._~/-]*)?$") and (contains("..") | not) and (endswith("/") | not))
    and (.allowInsecureLan | type == "boolean")
    and ((.baseUrl | startswith("https://")) or (.baseUrl | test("^http://(localhost|127[.]0[.]0[.]1)(:[0-9]+)?(/|$)")) or .allowInsecureLan == true)
' <<< "$bundle" >/dev/null 2>&1; then
    echo 'Invalid registration bundle or non-TLS address without explicit VPN/tunnel opt-in.' >&2
    exit 1
fi

encoded="$(printf '%s' "$bundle" | base64 | tr -d '\n')"
# psql gets the JSON as base64 on stdin. No credential is placed in process
# arguments, environment, files, or terminal output on this Linux host.
if ! result="$(
    {
        printf "\\set local_bundle_b64 '%s'\n" "$encoded"
        printf "\\set local_force '%s'\n" "$force"
        cat "$SEED_SQL"
    } | (cd "$METAMCP_DIR" && docker compose exec -T app sh -c '
        test -n "${DATABASE_URL:-}" || { echo "DATABASE_URL is not set in the MetaMCP app" >&2; exit 1; }
        exec psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -qAt
    ')
)"; then
    echo 'Registration failed; the transaction was rolled back.' >&2
    exit 1
fi
case "$result" in
    seeded\|*)
        conflicts="${result#seeded|}"
        echo 'Windows servers registered in a private, API-key-protected MetaMCP namespace.'
        if [ -n "$conflicts" ]; then
            echo "Existing differently configured servers were left untouched and not newly linked: $conflicts" >&2
            echo 'Review them in the MetaMCP UI; use the explicit seed command after resolving conflicts.' >&2
        fi
        ;;
    skipped\|*) echo 'This machine was already registered; intentional deletions and edits were preserved. Use seed to repair missing defaults.' ;;
    *) echo 'Unexpected result from MetaMCP. Inspect its logs.' >&2; exit 1 ;;
esac
