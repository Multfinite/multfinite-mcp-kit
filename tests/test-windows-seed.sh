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
reset_db() { query 'TRUNCATE users, config, namespaces, mcp_servers CASCADE;' >/dev/null; }
assert_eq() { if [ "$1" != "$2" ]; then printf 'FAIL: %s\nExpected: %s\nActual: %s\n' "$3" "$1" "$2" >&2; exit 1; fi; }
assert_has() { case "$1" in *"$2"*) ;; *) printf 'FAIL: %s\nMissing: %s\nActual: %s\n' "$3" "$2" "$1" >&2; exit 1;; esac; }
run_seed() {
    local email="${1:-}" force="${2:-false}" bundle encoded
    bundle="$(jq -cn --arg owner "$email" --arg key "$(printf 'a%.0s' {1..64})" '{version:1,hostId:"workstation-abc123",ownerEmail:$owner,port:13001,gatewayKey:$key}')"
    encoded="$(printf %s "$bundle" | base64 | tr -d '\r\n')"
    { printf "\\set local_bundle_b64 '%s'\n\\set local_force '%s'\n" "$encoded" "$force"; cat "$ROOT/windows/seed-local.sql"; } |
        psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -qAt
}
base='local-workstation-abc123'
public="winpub-$(query "SELECT substr(md5('workstation-abc123'),1,8)")"
groups="$base-code,$base-data,$base-files,$base-memory,$base-system,$base-web"
without_code="$base-data,$base-files,$base-memory,$base-system,$base-web"

# Shared records are created even with no users; public does not mean anonymous.
query "INSERT INTO config(id,value) VALUES ('DISABLE_SIGNUP','true');" >/dev/null
assert_eq "seeded||$groups|||" "$(run_seed)" 'fresh public seed without an account'
assert_eq '0|13|6|6|13|true' "$(query "SELECT (SELECT count(*) FROM users)||'|'||(SELECT count(*) FROM mcp_servers WHERE user_id IS NULL)||'|'||(SELECT count(*) FROM namespaces WHERE user_id IS NULL)||'|'||(SELECT count(*) FROM endpoints WHERE user_id IS NULL AND enable_api_key_auth AND NOT enable_oauth)||'|'||(SELECT count(*) FROM namespace_server_mappings)||'|'||(SELECT value FROM config WHERE id='DISABLE_SIGNUP')")" '13 shared servers and six protected groups; signup unchanged'
assert_eq 'code:4,data:1,files:3,memory:2,system:2,web:1' "$(query "SELECT string_agg(suffix || ':' || cnt, ',' ORDER BY suffix) FROM (SELECT substr(n.name, length('$base') + 2) suffix, count(*) cnt FROM namespaces n JOIN namespace_server_mappings m ON n.uuid=m.namespace_uuid GROUP BY n.name) x")" 'each server is mapped to its intended group'
assert_eq "skipped||$groups|||" "$(run_seed)" 'normal repeat skips'
assert_eq 'missing|||||' "$(run_seed nobody@example.com true)" 'unknown explicit account does not create a user'
query "INSERT INTO users(id,email) VALUES ('alice','alice@example.com'),('bob','bob@example.com');" >/dev/null
assert_eq "skipped||$groups|||" "$(run_seed)" 'multiple users do not require choosing an owner'
alice64="$(printf alice@example.com | base64 | tr -d '\r\n')"
assert_eq "seeded|$alice64|$groups|||" "$(run_seed alice@example.com true)" 'an explicitly selected existing account is returned separately'
query "INSERT INTO users(id,email) VALUES ('alice2','ALICE@example.com');" >/dev/null
assert_eq 'ambiguous|||||' "$(run_seed alice@example.com true)" 'case-insensitive ambiguous account is not selected'

# Automatic restart never restores deleted endpoints/servers, inactive mappings
# or modified servers. Explicit seed restores missing defaults but not edits.
query "DELETE FROM endpoints WHERE name='$base-code'; DELETE FROM mcp_servers WHERE name='$public-playwright' AND user_id IS NULL;
       UPDATE namespace_server_mappings SET status='INACTIVE' WHERE mcp_server_uuid=(SELECT uuid FROM mcp_servers WHERE name='$public-filesystem' AND user_id IS NULL);
       UPDATE mcp_servers SET url='http://example.com/custom' WHERE name='$public-dbhub' AND user_id IS NULL;" >/dev/null
assert_eq "skipped||$without_code|||" "$(run_seed)" 'automatic repeat preserves deletions'
assert_eq '0|0|INACTIVE|http://example.com/custom' "$(query "SELECT (SELECT count(*) FROM endpoints WHERE name='$base-code')||'|'||(SELECT count(*) FROM mcp_servers WHERE name='$public-playwright' AND user_id IS NULL)||'|'||(SELECT m.status FROM namespace_server_mappings m JOIN mcp_servers s ON m.mcp_server_uuid=s.uuid WHERE s.name='$public-filesystem' AND s.user_id IS NULL)||'|'||(SELECT url FROM mcp_servers WHERE name='$public-dbhub' AND user_id IS NULL)")" 'deleted and customized records were not changed'
assert_eq "seeded||$groups||server:$public-dbhub|" "$(run_seed '' true)" 'explicit repair adds missing defaults and reports edited server'
assert_eq '1|1|INACTIVE|http://example.com/custom' "$(query "SELECT (SELECT count(*) FROM endpoints WHERE name='$base-code')||'|'||(SELECT count(*) FROM mcp_servers WHERE name='$public-playwright' AND user_id IS NULL)||'|'||(SELECT m.status FROM namespace_server_mappings m JOIN mcp_servers s ON m.mcp_server_uuid=s.uuid WHERE s.name='$public-filesystem' AND s.user_id IS NULL)||'|'||(SELECT url FROM mcp_servers WHERE name='$public-dbhub' AND user_id IS NULL)")" 'repair does not overwrite edits or re-enable a mapping'
query "UPDATE endpoints SET enable_api_key_auth=false WHERE name='$base-memory';" >/dev/null
opened="$(run_seed)"
assert_has "$opened" "|$base-memory|" 'endpoint opened after seeding is reported on restart'
assert_eq 2 "$(query "SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid WHERE n.name='$base-memory'")" 'warning does not remove existing user mappings'
query "DELETE FROM namespaces WHERE name='$base-code'; INSERT INTO namespaces(name,user_id) VALUES ('$base-code',NULL);
       INSERT INTO endpoints(name,namespace_uuid,enable_api_key_auth,user_id) SELECT 'foreign-code',uuid,true,NULL FROM namespaces WHERE name='$base-code';" >/dev/null
replaced="$(run_seed '' true)"
assert_has "$replaced" "namespace:$base-code" 'a replaced namespace is not treated as kit-owned'
assert_eq 0 "$(query "SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid WHERE n.name='$base-code'")" 'no tools are added to the replacement namespace'

# Conflicting names, duplicate public names, and any unauthenticated endpoint
# are left alone. An inactive mapping in a protected namespace stays inactive.
reset_db
query "INSERT INTO users(id,email) VALUES ('bob','bob@example.com');
 INSERT INTO namespaces(name,user_id) VALUES ('$base-files','bob'),('$base-web',NULL),('$base-memory',NULL),('other','bob');
 INSERT INTO endpoints(name,namespace_uuid,enable_api_key_auth,user_id) SELECT 'open-web',uuid,false,NULL FROM namespaces WHERE name='$base-web';
 INSERT INTO endpoints(name,namespace_uuid,enable_api_key_auth,user_id) SELECT 'foreign-memory',uuid,true,NULL FROM namespaces WHERE name='$base-memory';
 INSERT INTO endpoints(name,namespace_uuid,enable_api_key_auth,user_id) SELECT '$base-data',uuid,true,'bob' FROM namespaces WHERE name='other';
 INSERT INTO mcp_servers(name,type,command,user_id) VALUES ('$public-git','STDIO','git-one',NULL),('$public-git','STDIO','git-two',NULL),('$public-serena','STDIO','custom',NULL),('$public-codebase','STDIO','private-codebase','bob');
 INSERT INTO mcp_servers(name,type,url,headers,user_id) VALUES ('$public-codegraph','STREAMABLE_HTTP','http://host.docker.internal:13001/servers/codegraph/mcp',jsonb_build_object('X-API-Key',repeat('a',64)),NULL);" >/dev/null
conflicted="$(run_seed)"
assert_has "$conflicted" "|$base-web|" 'open namespace reported'
for problem in "namespace:$base-files" "namespace:$base-memory" "endpoint:$base-data" "server:$public-git" "server:$public-serena" "server:$public-codebase"; do assert_has "$conflicted" "$problem" 'name/setting conflict reported'; done
query "UPDATE namespace_server_mappings SET status='INACTIVE' WHERE mcp_server_uuid=(SELECT uuid FROM mcp_servers WHERE name='$public-codegraph' AND user_id IS NULL);" >/dev/null
forced_conflicts="$(run_seed '' true)"
assert_has "$forced_conflicts" "namespace:$base-memory" 'explicit seed does not adopt a foreign namespace'
assert_eq '0|0|0|2|custom|bob|INACTIVE|0|private-codebase' "$(query "SELECT (SELECT count(*) FROM endpoints WHERE name='$base-web')||'|'||(SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid WHERE n.name='$base-web')||'|'||(SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid WHERE n.name='$base-memory')||'|'||(SELECT count(*) FROM mcp_servers WHERE name='$public-git' AND user_id IS NULL)||'|'||(SELECT command FROM mcp_servers WHERE name='$public-serena' AND user_id IS NULL)||'|'||(SELECT user_id FROM endpoints WHERE name='$base-data')||'|'||(SELECT m.status FROM namespace_server_mappings m JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE s.name='$public-codegraph')||'|'||(SELECT count(*) FROM mcp_servers WHERE name='$public-codebase' AND user_id IS NULL)||'|'||(SELECT command FROM mcp_servers WHERE name='$public-codebase' AND user_id='bob')")" 'foreign namespaces, conflicts and inactive mapping preserved'
repeated="$(run_seed)"
assert_has "$repeated" 'skipped|' 'conflict run has a marker'
assert_has "$repeated" "server:$public-serena" 'outstanding warnings survive restart'
assert_has "$repeated" "|$base-web|" 'open endpoint remains visible as warning'

# V1 is an actual older private seed layout, not an in-place visibility flip.
setup_legacy() {
    query "INSERT INTO users(id,email) VALUES ('alice','alice@example.com');
      INSERT INTO config(id,value) VALUES ('DISABLE_SIGNUP','true'),('MULTFINITE_MCP_KIT_LOCAL_DOCKER_V1:alice:workstation-abc123','complete');
      INSERT INTO namespaces(name,description,user_id) VALUES ('$base','Private legacy','alice');
      INSERT INTO endpoints(name,namespace_uuid,enable_api_key_auth,user_id) SELECT '$base',uuid,true,'alice' FROM namespaces WHERE name='$base';
      INSERT INTO mcp_servers(name,type,url,headers,user_id)
      SELECT '$base-'||id,'STREAMABLE_HTTP','http://host.docker.internal:13001/servers/'||id||'/mcp',jsonb_build_object('X-API-Key',repeat('a',64)),'alice'
      FROM unnest(ARRAY['desktop-commander','everything-search','filesystem','windows-mcp','git','codegraph','codebase-memory-mcp','serena','playwright','dbhub','simple-files-vectorstore','markitdown','obsidian']) id;
      INSERT INTO namespace_server_mappings(namespace_uuid,mcp_server_uuid)
      SELECT n.uuid,s.uuid FROM namespaces n,mcp_servers s WHERE n.name='$base' AND n.user_id='alice' AND s.user_id='alice';" >/dev/null
}
reset_db
setup_legacy
query "DELETE FROM mcp_servers WHERE name='$base-playwright' AND user_id='alice';
 DELETE FROM namespace_server_mappings m USING mcp_servers s WHERE m.mcp_server_uuid=s.uuid AND s.name='$base-everything-search' AND s.user_id='alice';
 UPDATE namespace_server_mappings SET status='INACTIVE' WHERE mcp_server_uuid=(SELECT uuid FROM mcp_servers WHERE name='$base-git' AND user_id='alice');
 UPDATE mcp_servers SET url='http://example.com/custom' WHERE name='$base-dbhub' AND user_id='alice';
 INSERT INTO tools(name,mcp_server_uuid) SELECT 'example-tool',uuid FROM mcp_servers WHERE user_id='alice' AND name IN ('$base-windows-mcp','$base-codegraph');
 INSERT INTO namespace_tool_mappings(namespace_uuid,tool_uuid,mcp_server_uuid,status,override_name)
 SELECT n.uuid,t.uuid,s.uuid,CASE WHEN s.name='$base-windows-mcp' THEN 'INACTIVE'::mcp_server_status ELSE 'ACTIVE'::mcp_server_status END,
        CASE WHEN s.name='$base-codegraph' THEN 'custom-name' ELSE NULL END
 FROM namespaces n JOIN mcp_servers s ON s.user_id=n.user_id JOIN tools t ON t.mcp_server_uuid=s.uuid
 WHERE n.name='$base' AND n.user_id='alice';" >/dev/null
upgraded="$(run_seed)"
for id in windows everything git codegraph playwright dbhub; do assert_has "$upgraded" "$public-$id" 'legacy customized/deleted/disabled server deferred'; done
assert_eq '7|12|1|true|INACTIVE|custom-name' "$(query "SELECT (SELECT count(*) FROM mcp_servers WHERE user_id IS NULL)||'|'||(SELECT count(*) FROM mcp_servers WHERE user_id='alice')||'|'||(SELECT count(*) FROM endpoints WHERE name='$base' AND user_id='alice')||'|'||(SELECT value FROM config WHERE id='DISABLE_SIGNUP')||'|'||(SELECT m.status FROM namespace_server_mappings m JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE s.name='$base-git' AND s.user_id='alice')||'|'||(SELECT tm.override_name FROM namespace_tool_mappings tm JOIN mcp_servers s ON s.uuid=tm.mcp_server_uuid WHERE s.name='$base-codegraph' AND s.user_id='alice')")" 'upgrade is additive and preserves old settings'
assert_has "$(run_seed)" "$public-windows" 'legacy deferral warning survives restart'
assert_eq "seeded||$groups|||" "$(run_seed '' true)" 'explicit seed can add the deferred public defaults'
assert_eq '13|12|INACTIVE|custom-name' "$(query "SELECT (SELECT count(*) FROM mcp_servers WHERE user_id IS NULL)||'|'||(SELECT count(*) FROM mcp_servers WHERE user_id='alice')||'|'||(SELECT m.status FROM namespace_server_mappings m JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE s.name='$base-git' AND s.user_id='alice')||'|'||(SELECT tm.override_name FROM namespace_tool_mappings tm JOIN mcp_servers s ON s.uuid=tm.mcp_server_uuid WHERE s.name='$base-codegraph' AND s.user_id='alice')")" 'explicit seed leaves all private records intact'

# With multiple old owners, do not re-expose a server disabled by either one.
reset_db
setup_legacy
query "INSERT INTO users(id,email) VALUES ('bob','bob@example.com');
 INSERT INTO config(id,value) VALUES ('MULTFINITE_MCP_KIT_LOCAL_DOCKER_V1:bob:workstation-abc123','complete');
 INSERT INTO namespaces(name,user_id) VALUES ('$base-'||substr(md5('bob'),1,8),'bob');
 INSERT INTO endpoints(name,namespace_uuid,enable_api_key_auth,user_id) SELECT name,uuid,true,'bob' FROM namespaces WHERE user_id='bob';
 INSERT INTO mcp_servers(name,type,url,headers,user_id)
 SELECT '$base-'||substr(md5('bob'),1,8)||substring(name FROM length('$base')+1),type,url,headers,'bob' FROM mcp_servers WHERE user_id='alice';
 INSERT INTO namespace_server_mappings(namespace_uuid,mcp_server_uuid) SELECT n.uuid,s.uuid FROM namespaces n,mcp_servers s WHERE n.user_id='bob' AND s.user_id='bob';
 UPDATE namespace_server_mappings SET status='INACTIVE' WHERE mcp_server_uuid=(SELECT uuid FROM mcp_servers WHERE user_id='bob' AND name LIKE '%-git');" >/dev/null
multi="$(run_seed)"
assert_has "$multi" "$public-git" 'disabled mapping in second legacy account is deferred'
assert_eq '12|2|1' "$(query "SELECT (SELECT count(*) FROM mcp_servers WHERE user_id IS NULL)||'|'||(SELECT count(*) FROM endpoints WHERE user_id IS NOT NULL)||'|'||(SELECT count(*) FROM namespace_server_mappings m JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE s.user_id='bob' AND s.name LIKE '%-git' AND m.status='INACTIVE')")" 'multi-owner legacy records are unchanged'

reset_db
setup_legacy
query "DELETE FROM endpoints WHERE name='$base';" >/dev/null
removed="$(run_seed)"
assert_has "$removed" "$public-desktop" 'deleted old endpoint defers re-exposure'
assert_has "$removed" "$public-obsidian" 'deleted endpoint defers every old server'
assert_eq 0 "$(query 'SELECT count(*) FROM mcp_servers WHERE user_id IS NULL')" 'no private tools silently republished after endpoint deletion'

reset_db
setup_legacy
query "INSERT INTO config(id,value) VALUES ('MULTFINITE_MCP_KIT_LOCAL_DOCKER_V1:deleted-user:workstation-abc123','complete');" >/dev/null
assert_has "$(run_seed)" "$public-desktop" 'orphaned legacy owner marker is handled conservatively'
assert_eq 0 "$(query 'SELECT count(*) FROM mcp_servers WHERE user_id IS NULL')" 'orphaned owner does not silently expose tools'

echo 'Windows local public seed scenarios passed.'
