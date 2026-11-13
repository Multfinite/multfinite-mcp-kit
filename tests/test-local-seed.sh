#!/usr/bin/env bash
# PostgreSQL integration tests with a mocked Docker boundary. Never use a
# production database: this test creates/drops a disposable schema.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
: "${TEST_DATABASE_URL:?Set TEST_DATABASE_URL to a disposable PostgreSQL database}"
for c in psql jq; do command -v "$c" >/dev/null || { echo "$c is required" >&2; exit 1; }; done
TMP="$(mktemp -d)"
SCHEMA="mcpkit_local_${RANDOM}_$$"
export PGOPTIONS="-c search_path=$SCHEMA,public"
export HOME="$TMP/home" MOCK_LOG="$TMP/docker.log" PATH="$TMP/bin:$PATH"
mkdir -p "$HOME/mcp-global/metamcp" "$TMP/bin"
: > "$HOME/mcp-global/metamcp/.env"
cleanup() {
    PGOPTIONS='' psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -q -c "DROP SCHEMA IF EXISTS \"$SCHEMA\" CASCADE" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT
cat > "$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$MOCK_LOG"; printf '\n' >> "$MOCK_LOG"
if [ "$1" = info ]; then exit 0; fi
if [ "$1" = compose ] && [ "$2" = exec ] && [ "$3" = -T ] && [ "$4" = app ] && [ "$5" = sh ] && [ "$6" = -c ]; then
    export DATABASE_URL="$TEST_DATABASE_URL"
    exec sh -c "$7"
fi
echo 'Unexpected docker command' >&2
exit 1
MOCK
chmod +x "$TMP/bin/docker"
reset_db() {
    PGOPTIONS='' psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -q -c "DROP SCHEMA IF EXISTS \"$SCHEMA\" CASCADE; CREATE SCHEMA \"$SCHEMA\";" >/dev/null 2>&1
    psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -q -f "$ROOT/tests/fixtures/metamcp-schema.sql"
    psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -q -c "INSERT INTO users (id,email) VALUES ('alice','alice@example.com'),('bob','bob@example.com');"
    : > "$MOCK_LOG"
}
query() { psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -qAt -c "$1"; }
assert_eq() { if [ "$1" != "$2" ]; then printf 'FAIL: %s\nExpected: %s\nActual: %s\n' "$3" "$1" "$2" >&2; exit 1; fi; }
fail() { echo "FAIL: $*" >&2; exit 1; }
key="$(printf 'a%.0s' {1..64})"
make_bundle() {
    jq -cn --arg host "${1:-workstation-abc123}" --arg owner "${2:-alice@example.com}" --arg url "${3:-https://win.example.com:13001}" --arg key "$key" --argjson allow "${4:-false}" \
      '{version:1,hostId:$host,ownerEmail:$owner,baseUrl:$url,gatewayKey:$key,allowInsecureLan:$allow}'
}
run_seed() { printf '%s' "$bundle" | bash "$ROOT/linux/register-local.sh" --stdin "$@"; }

echo '1. Fresh private registration and protected endpoint'
reset_db
bundle="$(make_bundle)"
run_seed > "$TMP/out"
assert_eq '13|1|1|13' "$(query "SELECT (SELECT count(*) FROM mcp_servers)||'|'||(SELECT count(*) FROM namespaces)||'|'||(SELECT count(*) FROM endpoints)||'|'||(SELECT count(*) FROM namespace_server_mappings)")" 'expected complete seed'
assert_eq '13' "$(query "SELECT count(*) FROM mcp_servers WHERE user_id='alice' AND type='STREAMABLE_HTTP' AND headers->>'X-API-Key'='$key' AND url LIKE 'https://win.example.com:13001/servers/%/mcp'")" 'private servers, urls and key'
assert_eq 'true|true|alice' "$(query "SELECT enable_api_key_auth::text || '|' || (NOT enable_oauth)::text || '|' || user_id FROM endpoints WHERE name='local-workstation-abc123'")" 'private authenticated endpoint'
if grep -Fq "$key" "$TMP/out" "$MOCK_LOG"; then fail 'key appeared in output or docker arguments'; fi

echo '2. Automatic repeat preserves removals and disabled mappings'
query "DELETE FROM namespace_server_mappings WHERE mcp_server_uuid=(SELECT uuid FROM mcp_servers WHERE name LIKE '%-git'); UPDATE namespace_server_mappings SET status='INACTIVE' WHERE mcp_server_uuid=(SELECT uuid FROM mcp_servers WHERE name LIKE '%-serena');" >/dev/null
run_seed > "$TMP/out"
grep -q 'already registered' "$TMP/out" || fail 'expected idempotent skip'
assert_eq '12|1' "$(query "SELECT count(*)||'|'||count(*) FILTER (WHERE status='INACTIVE') FROM namespace_server_mappings")" 'repeat must not restore edits'

echo '3. Explicit repair is additive and preserves inactive mappings'
run_seed --force > "$TMP/out"
assert_eq '13|1' "$(query "SELECT count(*)||'|'||count(*) FILTER (WHERE status='INACTIVE') FROM namespace_server_mappings")" 'repair must preserve inactive mappings'

echo '4. Existing manually changed server is never overwritten or linked'
query "UPDATE mcp_servers SET url='https://other.example/mcp' WHERE name='local-workstation-abc123-git'; DELETE FROM namespace_server_mappings WHERE mcp_server_uuid=(SELECT uuid FROM mcp_servers WHERE name='local-workstation-abc123-git');" >/dev/null
run_seed --force > "$TMP/out" 2> "$TMP/err"
grep -q 'local-workstation-abc123-git' "$TMP/err" || fail 'expected conflict warning'
assert_eq 'https://other.example/mcp|12' "$(query "SELECT (SELECT url FROM mcp_servers WHERE name='local-workstation-abc123-git')||'|'||(SELECT count(*) FROM namespace_server_mappings)")" 'existing edit preserved'

echo '5. An open or non-owner endpoint blocks the whole transaction'
reset_db
query "INSERT INTO namespaces(name,user_id) VALUES ('local-workstation-abc123','alice'); INSERT INTO endpoints(name,namespace_uuid,user_id,enable_api_key_auth) SELECT 'open-existing',uuid,'alice',false FROM namespaces;" >/dev/null
if run_seed > "$TMP/out" 2> "$TMP/err"; then fail 'open namespace accepted'; fi
assert_eq '0|0|1' "$(query "SELECT (SELECT count(*) FROM mcp_servers)||'|'||(SELECT count(*) FROM config)||'|'||(SELECT count(*) FROM endpoints)")" 'open namespace must rollback'
query "UPDATE endpoints SET enable_api_key_auth=true,user_id='bob'" >/dev/null
if run_seed > "$TMP/out" 2> "$TMP/err"; then fail 'non-owner endpoint accepted'; fi
assert_eq '0' "$(query 'SELECT count(*) FROM mcp_servers')" 'non-owner endpoint must rollback'

echo '6. Globally occupied endpoint name rolls back without touching owner'
reset_db
query "INSERT INTO namespaces(name,user_id) VALUES ('bob-group','bob'); INSERT INTO endpoints(name,namespace_uuid,user_id) SELECT 'local-workstation-abc123',uuid,'bob' FROM namespaces WHERE name='bob-group';" >/dev/null
if run_seed > "$TMP/out" 2> "$TMP/err"; then fail 'endpoint collision accepted'; fi
assert_eq '0|1|bob' "$(query "SELECT (SELECT count(*) FROM mcp_servers)||'|'||(SELECT count(*) FROM namespaces)||'|'||(SELECT user_id FROM endpoints)")" 'collision must rollback'

echo '7. Private names cannot adopt public or other users servers'
reset_db
query "INSERT INTO mcp_servers(name,type,url,user_id) VALUES ('local-workstation-abc123-git','STREAMABLE_HTTP','https://other.example/mcp',NULL),('local-workstation-abc123-git','STREAMABLE_HTTP','https://other.example/mcp','bob');" >/dev/null
run_seed > "$TMP/out"
assert_eq '3|1' "$(query "SELECT count(*)||'|'||count(*) FILTER (WHERE user_id='alice') FROM mcp_servers WHERE name='local-workstation-abc123-git'")" 'private ownership'
assert_eq '13' "$(query "SELECT count(*) FROM namespace_server_mappings m JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE s.user_id='alice'")" 'only owner servers linked'

echo '8. Unsafe URL, bad user, and invalid bundle fail without seed'
reset_db
bundle="$(make_bundle workstation-abc123 alice@example.com 'http://192.168.1.2:13001')"
if run_seed > "$TMP/out" 2> "$TMP/err"; then fail 'plaintext LAN accepted without opt-in'; fi
bundle="$(make_bundle workstation-abc123 nobody@example.com)"
if run_seed > "$TMP/out" 2> "$TMP/err"; then fail 'missing user accepted'; fi
assert_eq '0|0' "$(query "SELECT (SELECT count(*) FROM mcp_servers)||'|'||(SELECT count(*) FROM config)")" 'invalid inputs must not write'
bundle="$(make_bundle workstation-abc123 alice@example.com 'http://192.168.1.2:13001' true)"
run_seed > "$TMP/out"
assert_eq '13' "$(query 'SELECT count(*) FROM mcp_servers')" 'explicit tunnel/VPN opt-in'

echo '9. Two workstations and owners remain isolated'
bundle="$(make_bundle second-a1b2c3 bob@example.com)"
run_seed > "$TMP/out"
assert_eq '26|2|2|2' "$(query "SELECT (SELECT count(*) FROM mcp_servers)||'|'||(SELECT count(*) FROM namespaces)||'|'||(SELECT count(*) FROM endpoints)||'|'||(SELECT count(DISTINCT user_id) FROM endpoints)")" 'multiple private machines'

echo '10. Concurrent registration is serialized and idempotent'
reset_db
bundle="$(make_bundle)"
run_seed > "$TMP/one" 2> "$TMP/one.err" & p1=$!
run_seed > "$TMP/two" 2> "$TMP/two.err" & p2=$!
wait "$p1"; wait "$p2"
assert_eq '13|1|1|13' "$(query "SELECT (SELECT count(*) FROM mcp_servers)||'|'||(SELECT count(*) FROM namespaces)||'|'||(SELECT count(*) FROM endpoints)||'|'||(SELECT count(*) FROM namespace_server_mappings)")" 'concurrent seed'
grep -q 'already registered' "$TMP/one" "$TMP/two" || fail 'one concurrent call should skip'

echo '11. Failed SQL is transactional and retryable'
reset_db
query 'DROP TABLE namespace_server_mappings' >/dev/null
if run_seed > "$TMP/out" 2> "$TMP/err"; then fail 'broken schema unexpectedly succeeded'; fi
assert_eq '0|0|0' "$(query "SELECT (SELECT count(*) FROM mcp_servers)||'|'||(SELECT count(*) FROM namespaces)||'|'||(SELECT count(*) FROM config)")" 'rollback on SQL failure'
reset_db
run_seed > "$TMP/out"
assert_eq '13' "$(query 'SELECT count(*) FROM mcp_servers')" 'retry after schema repaired'

echo 'All 11 local registration scenarios passed.'
