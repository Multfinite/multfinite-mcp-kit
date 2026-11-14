#!/usr/bin/env bash
# Targeted, disposable PostgreSQL test of the explicitly requested Windows reset.
# Never point TEST_DATABASE_URL at production: this creates/drops a schema.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
: "${TEST_DATABASE_URL:?Set TEST_DATABASE_URL to a disposable PostgreSQL database}"
for c in psql jq base64; do command -v "$c" >/dev/null || { echo "$c is required" >&2; exit 1; }; done
SCHEMA="mcpkit_reset_${RANDOM}_$$"
export PGOPTIONS="-c search_path=$SCHEMA,public"
cleanup() { PGOPTIONS='' psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -q -c "DROP SCHEMA IF EXISTS \"$SCHEMA\" CASCADE" >/dev/null 2>&1 || true; }
trap cleanup EXIT
PGOPTIONS='' psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -q -c "CREATE SCHEMA \"$SCHEMA\";"
psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -q -f "$ROOT/tests/fixtures/metamcp-schema.sql"
query() { psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -qAt -c "$1"; }
assert_eq() { if [ "$1" != "$2" ]; then printf 'FAIL: %s\nExpected: %s\nActual: %s\n' "$3" "$1" "$2" >&2; exit 1; fi; }
run_seed() {
    local mode="$1" bundle encoded
    bundle="$(jq -cn --arg key "$(printf 'a%.0s' {1..64})" '{version:1,hostId:"workstation-abc123",ownerEmail:"",port:13001,gatewayKey:$key}')"
    encoded="$(printf %s "$bundle" | base64 | tr -d '\r\n')"
    { printf "\\set local_bundle_b64 '%s'\n\\set local_force '%s'\n" "$encoded" "$mode"; cat "$ROOT/windows/seed-local.sql"; } |
        psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -qAt
}
base='local-workstation-abc123'
groups="$base-code,$base-data,$base-files,$base-memory,$base-system,$base-web"
query "INSERT INTO users(id,email) VALUES ('alice','alice@example.com'),('bob','bob@example.com');
 INSERT INTO api_keys(name,key,user_id) VALUES ('personal','test-api-key','alice');
 INSERT INTO config(id,value) VALUES ('DISABLE_SIGNUP','true'),('custom-setting','keep');" >/dev/null
assert_eq "seeded||$groups|||" "$(run_seed false)" 'initial V3 registration succeeds'
query "INSERT INTO config(id,value) VALUES
 ('MULTFINITE_MCP_KIT_LOCAL_DOCKER_V1:alice:workstation-abc123','complete'),
 ('MULTFINITE_MCP_KIT_LOCAL_DOCKER_PUBLIC_V2:workstation-abc123','{}'),
 ('MULTFINITE_MCP_KIT_LOCAL_DOCKER_PUBLIC_V3:another-host','{}');
 INSERT INTO namespaces(name,user_id) VALUES ('manual-namespace','alice');
 INSERT INTO endpoints(name,namespace_uuid,user_id) SELECT 'manual-endpoint',uuid,'alice' FROM namespaces WHERE name='manual-namespace';
 INSERT INTO mcp_servers(name,type,command,user_id) VALUES ('manual-server','STDIO','echo','alice');
 INSERT INTO namespace_server_mappings(namespace_uuid,mcp_server_uuid,status)
 SELECT n.uuid,s.uuid,'INACTIVE' FROM namespaces n,mcp_servers s WHERE n.name='manual-namespace' AND s.name='manual-server';
 INSERT INTO tools(name,tool_schema,mcp_server_uuid)
 SELECT 'manual-tool','{\"type\":\"object\"}',uuid FROM mcp_servers WHERE name='manual-server';
 INSERT INTO namespace_tool_mappings(namespace_uuid,tool_uuid,mcp_server_uuid,status)
 SELECT n.uuid,t.uuid,t.mcp_server_uuid,'INACTIVE' FROM namespaces n,tools t WHERE n.name='manual-namespace' AND t.name='manual-tool';
 INSERT INTO oauth_sessions(mcp_server_uuid,tokens) SELECT uuid,'{\"access_token\":\"test\"}' FROM mcp_servers WHERE name='manual-server';
 INSERT INTO mcp_request_audit_logs(namespace_uuid,api_key_uuid,mcp_server_uuid,mcp_server_name)
 SELECT n.uuid,k.uuid,s.uuid,'manual-server' FROM namespaces n,api_keys k,mcp_servers s
 WHERE n.name='manual-namespace' AND k.name='personal' AND s.name='manual-server';" >/dev/null
old_filesystem="$(query "SELECT uuid FROM mcp_servers WHERE name='filesystem'")"
assert_eq "seeded||$groups|||" "$(run_seed reset-all)" 'explicit reset recreates clean defaults'
assert_eq '13|6|6|13|0|0|0' "$(query "SELECT (SELECT count(*) FROM mcp_servers)||'|'||(SELECT count(*) FROM namespaces)||'|'||(SELECT count(*) FROM endpoints WHERE enable_api_key_auth AND NOT enable_oauth)||'|'||(SELECT count(*) FROM namespace_server_mappings WHERE status='ACTIVE')||'|'||(SELECT count(*) FROM tools)||'|'||(SELECT count(*) FROM namespace_tool_mappings)||'|'||(SELECT count(*) FROM oauth_sessions)")" 'only fresh servers and protected groups remain'
assert_eq 'codebase-memory-mcp,codegraph,dbhub,desktop-commander,everything-search,filesystem,git,markitdown,obsidian,playwright,serena,simple-files-vectorstore,windows-mcp' "$(query 'SELECT string_agg(name,chr(44) ORDER BY name) FROM mcp_servers')" 'servers use official short names'
assert_eq '2|test-api-key|true|keep' "$(query "SELECT (SELECT count(*) FROM users)||'|'||(SELECT key FROM api_keys WHERE name='personal')||'|'||(SELECT value FROM config WHERE id='DISABLE_SIGNUP')||'|'||(SELECT value FROM config WHERE id='custom-setting')")" 'accounts, API key, signup and unrelated config survive'
assert_eq '0|0|1' "$(query "SELECT (SELECT count(*) FROM config WHERE starts_with(id,'MULTFINITE_MCP_KIT_LOCAL_DOCKER_V1:') OR starts_with(id,'MULTFINITE_MCP_KIT_LOCAL_DOCKER_PUBLIC_V2:'))||'|'||(SELECT count(*) FROM config WHERE id='MULTFINITE_MCP_KIT_LOCAL_DOCKER_PUBLIC_V3:another-host')||'|'||(SELECT count(*) FROM config WHERE id='MULTFINITE_MCP_KIT_LOCAL_DOCKER_PUBLIC_V3:workstation-abc123')")" 'stale Windows markers are cleared and current V3 marker is written'
assert_eq '1|true|true|true' "$(query "SELECT count(*)||'|'||bool_and(namespace_uuid IS NULL)||'|'||bool_and(mcp_server_uuid IS NULL)||'|'||bool_and(api_key_uuid IS NOT NULL) FROM mcp_request_audit_logs WHERE mcp_server_name='manual-server'")" 'audit row and API key link survive while deleted resource links are cleared'
[ "$(query "SELECT uuid FROM mcp_servers WHERE name='filesystem'")" != "$old_filesystem" ] || { echo 'FAIL: reset did not replace old server UUID' >&2; exit 1; }

# Neither a subsequent ordinary start nor an ordinary forced seed is a reset.
query "INSERT INTO mcp_servers(name,type,command,user_id) VALUES ('manual-after','STDIO','echo','bob');
 UPDATE mcp_servers SET description='my edit' WHERE name='filesystem';" >/dev/null
assert_eq "skipped||$groups|||" "$(run_seed skip-only)" 'normal startup only probes the V3 marker'
assert_eq '1|my edit' "$(query "SELECT (SELECT count(*) FROM mcp_servers WHERE name='manual-after')||'|'||(SELECT description FROM mcp_servers WHERE name='filesystem')")" 'normal startup preserves later records and edits'
assert_eq "seeded||$groups|||" "$(run_seed true)" 'explicit seed remains non-destructive'
assert_eq 1 "$(query "SELECT count(*) FROM mcp_servers WHERE name='manual-after'")" 'ordinary seed does not remove manual records'

# An unknown cascading FK must block the reset before it can remove unrelated data.
query "CREATE TABLE custom_reference (server_uuid uuid REFERENCES mcp_servers(uuid) ON DELETE CASCADE);
 INSERT INTO custom_reference SELECT uuid FROM mcp_servers WHERE name='manual-after';" >/dev/null
if run_seed reset-all >/dev/null 2>&1; then echo 'FAIL: unknown FK did not block reset' >&2; exit 1; fi
assert_eq '1|1|14' "$(query "SELECT (SELECT count(*) FROM custom_reference)||'|'||(SELECT count(*) FROM mcp_servers WHERE name='manual-after')||'|'||(SELECT count(*) FROM mcp_servers)")" 'unknown dependent records remain intact'
query 'DROP TABLE custom_reference' >/dev/null
query 'CREATE FUNCTION custom_reset_hook() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN OLD; END$$;
 CREATE TRIGGER custom_reset_trigger BEFORE DELETE ON mcp_servers FOR EACH ROW EXECUTE FUNCTION custom_reset_hook();' >/dev/null
if run_seed reset-all >/dev/null 2>&1; then echo 'FAIL: unknown trigger did not block reset' >&2; exit 1; fi
assert_eq 1 "$(query "SELECT count(*) FROM mcp_servers WHERE name='manual-after'")" 'unknown trigger leaves existing records intact'
query 'DROP TRIGGER custom_reset_trigger ON mcp_servers; DROP FUNCTION custom_reset_hook();' >/dev/null

# A failure while re-creating defaults must roll back even the preceding deletes.
query "ALTER TABLE mcp_servers ADD CONSTRAINT reject_reset_filesystem CHECK (name <> 'filesystem') NOT VALID;" >/dev/null
before="$(query "SELECT string_agg(name,chr(44) ORDER BY name) FROM mcp_servers")"
if run_seed reset-all >/dev/null 2>&1; then echo 'FAIL: failed reset reported success' >&2; exit 1; fi
assert_eq "$before" "$(query "SELECT string_agg(name,chr(44) ORDER BY name) FROM mcp_servers")" 'failed re-creation rolls deletion back'
assert_eq '6|6|1' "$(query "SELECT (SELECT count(*) FROM namespaces)||'|'||(SELECT count(*) FROM endpoints)||'|'||(SELECT count(*) FROM config WHERE id='MULTFINITE_MCP_KIT_LOCAL_DOCKER_PUBLIC_V3:workstation-abc123')")" 'failed reset keeps groups, endpoints and marker'
printf 'Windows explicit reset scenarios passed.\n'
