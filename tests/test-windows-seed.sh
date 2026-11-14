#!/usr/bin/env bash
# Disposable PostgreSQL integration test for the Windows Docker seeder.
# Never point TEST_DATABASE_URL at production: this creates/drops a schema.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
: "${TEST_DATABASE_URL:?Set TEST_DATABASE_URL to a disposable PostgreSQL database}"
for c in psql jq base64; do command -v "$c" >/dev/null || { echo "$c is required" >&2; exit 1; }; done
SCHEMA="mcpkit_windows_${RANDOM}_$$"
export PGOPTIONS="-c search_path=$SCHEMA,public"
cleanup() { PGOPTIONS='' psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -q -c "DROP SCHEMA IF EXISTS \"$SCHEMA\" CASCADE" >/dev/null 2>&1 || true; }
trap cleanup EXIT
PGOPTIONS='' psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -q -c "CREATE SCHEMA \"$SCHEMA\";"
psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -q -f "$ROOT/tests/fixtures/metamcp-schema.sql"
query() { psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -qAt -c "$1"; }
assert_eq() { if [ "$1" != "$2" ]; then printf 'FAIL: %s\nExpected: %s\nActual: %s\n' "$3" "$1" "$2" >&2; exit 1; fi; }
run_seed() {
    local email="${1:-}" force="${2:-false}" bundle encoded
    bundle="$(jq -cn --arg owner "$email" --arg key "$(printf 'a%.0s' {1..64})" '{version:1,hostId:"workstation-abc123",ownerEmail:$owner,port:13001,gatewayKey:$key}')"
    encoded="$(printf %s "$bundle" | base64 | tr -d '\r\n')"
    { printf "\\set local_bundle_b64 '%s'\n\\set local_force '%s'\n" "$encoded" "$force"; cat "$ROOT/windows/seed-local.sql"; } |
        psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -qAt
}

query "INSERT INTO config(id,value) VALUES ('DISABLE_SIGNUP','true');" >/dev/null
assert_eq 'waiting|||' "$(run_seed)" 'no user means wait without creating an account'
assert_eq '0|0|true' "$(query "SELECT (SELECT count(*) FROM users)||'|'||(SELECT count(*) FROM mcp_servers)||'|'||(SELECT value FROM config WHERE id='DISABLE_SIGNUP')")" 'no account or signup change'
query "INSERT INTO users(id,email) VALUES ('alice','alice@example.com');" >/dev/null
alice64="$(printf alice@example.com | base64 | tr -d '\r\n')"
assert_eq "seeded|local-workstation-abc123|$alice64|" "$(run_seed)" 'sole manually registered owner'
assert_eq '13|1|13|true' "$(query "SELECT (SELECT count(*) FROM mcp_servers WHERE user_id='alice')||'|'||(SELECT count(*) FROM endpoints WHERE user_id='alice' AND enable_api_key_auth)||'|'||(SELECT count(*) FROM namespace_server_mappings)||'|'||(SELECT value FROM config WHERE id='DISABLE_SIGNUP')")" 'private servers and unchanged manual signup flag'
query "UPDATE config SET value='false' WHERE id='DISABLE_SIGNUP';" >/dev/null
assert_eq "skipped|local-workstation-abc123|$alice64|" "$(run_seed alice@example.com)" 'repeat preserves records'
assert_eq false "$(query "SELECT value FROM config WHERE id='DISABLE_SIGNUP'")" 'repeat never closes or opens signup'

query "INSERT INTO users(id,email) VALUES ('bob','bob@example.com');" >/dev/null
assert_eq 'ambiguous|||' "$(run_seed)" 'multiple accounts must not be selected arbitrarily'
bob64="$(printf bob@example.com | base64 | tr -d '\r\n')"
hash="$(query "SELECT substr(md5('bob'),1,8)")"
assert_eq "seeded|local-workstation-abc123-$hash|$bob64|" "$(run_seed bob@example.com true)" 'new owner gets a distinct private endpoint'
assert_eq '13|13|2|false' "$(query "SELECT (SELECT count(*) FROM mcp_servers WHERE user_id='alice')||'|'||(SELECT count(*) FROM mcp_servers WHERE user_id='bob')||'|'||(SELECT count(*) FROM endpoints)||'|'||(SELECT value FROM config WHERE id='DISABLE_SIGNUP')")" 'old owner and signup setting preserved'
assert_eq 'missing|||' "$(run_seed nobody@example.com true)" 'unknown account does not create a user'
query "DELETE FROM endpoints WHERE user_id='alice';" >/dev/null
assert_eq "skipped||$alice64|" "$(run_seed alice@example.com)" 'automatic restart does not restore a deleted endpoint'
assert_eq 1 "$(query 'SELECT count(*) FROM endpoints')" 'intentional deletion is preserved'

echo 'Windows local seed scenarios passed.'
