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
    local email="${1:-}" mode="${2:-false}" bundle encoded
    bundle="$(jq -cn --arg owner "$email" --arg key "$(printf 'a%.0s' {1..64})" '{version:1,hostId:"workstation-abc123",ownerEmail:$owner,port:13001,gatewayKey:$key}')"
    encoded="$(printf %s "$bundle" | base64 | tr -d '\r\n')"
    { printf "\\set local_bundle_b64 '%s'\n\\set local_force '%s'\n" "$encoded" "$mode"; cat "$ROOT/windows/seed-local.sql"; } |
        psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -qAt
}
base='local-workstation-abc123'
public="winpub-$(query "SELECT substr(md5('workstation-abc123'),1,8)")"
groups="code,data,files,memory,system,web"
legacy_groups="$base-code,$base-data,$base-files,$base-memory,$base-system,$base-web"
without_code="data,files,memory,system,web"
# The V1 and V2 layouts below reproduce their names, connections and markers.
specs="('desktop-commander','Desktop Commander','desktop','system'),
('everything-search','Everything Search','everything','files'),
('filesystem','Filesystem MCP','filesystem','files'),
('windows-mcp','Windows MCP','windows','system'),
('git','Git MCP','git','code'),('codegraph','CodeGraph','codegraph','code'),
('codebase-memory-mcp','Codebase Memory MCP','codebase','code'),('serena','Serena','serena','code'),
('playwright','Playwright MCP','playwright','web'),('dbhub','DBHub','dbhub','data'),
('simple-files-vectorstore','Simple Files Vectorstore','vectorstore','memory'),
('markitdown','MarkItDown','markitdown','files'),('obsidian','Obsidian MCP','obsidian','memory')"
setup_legacy() {
    local owner="$1" email="$2" group="$3"
    query "INSERT INTO users(id,email) VALUES ('$owner','$email');
      INSERT INTO config(id,value) VALUES ('MULTFINITE_MCP_KIT_LOCAL_DOCKER_V1:$owner:workstation-abc123','complete');
      INSERT INTO namespaces(name,description,user_id) VALUES ('$group','Private legacy','$owner');
      INSERT INTO endpoints(name,namespace_uuid,enable_api_key_auth,user_id) SELECT name,uuid,true,'$owner' FROM namespaces WHERE name='$group' AND user_id='$owner';
      INSERT INTO mcp_servers(name,description,type,url,headers,user_id)
      SELECT '$group-'||x.id,x.description,'STREAMABLE_HTTP','http://host.docker.internal:13001/servers/'||x.id||'/mcp',jsonb_build_object('X-API-Key',repeat('a',64)),'$owner'
      FROM (VALUES $specs) AS x(id,description,alias,suffix);
      INSERT INTO namespace_server_mappings(namespace_uuid,mcp_server_uuid)
      SELECT n.uuid,s.uuid FROM namespaces n,mcp_servers s WHERE n.name='$group' AND n.user_id='$owner' AND s.user_id='$owner';" >/dev/null
}
setup_v2() {
    query "INSERT INTO namespaces(name,user_id) SELECT '$base-'||x.suffix,NULL FROM (VALUES ('system'),('files'),('code'),('web'),('data'),('memory')) x(suffix);
      INSERT INTO endpoints(name,namespace_uuid,enable_api_key_auth,user_id) SELECT name,uuid,true,NULL FROM namespaces WHERE user_id IS NULL AND name LIKE '$base-%';
      INSERT INTO mcp_servers(name,description,type,url,headers,user_id)
      SELECT '$public-'||x.alias,x.description,'STREAMABLE_HTTP','http://host.docker.internal:13001/servers/'||x.id||'/mcp',jsonb_build_object('X-API-Key',repeat('a',64)),NULL
      FROM (VALUES $specs) AS x(id,description,alias,suffix);
      INSERT INTO namespace_server_mappings(namespace_uuid,mcp_server_uuid)
      SELECT n.uuid,s.uuid FROM (VALUES $specs) AS x(id,description,alias,suffix)
        JOIN mcp_servers s ON s.name='$public-'||x.alias AND s.user_id IS NULL
        JOIN namespaces n ON n.name='$base-'||x.suffix AND n.user_id IS NULL;
      INSERT INTO config(id,value)
      SELECT 'MULTFINITE_MCP_KIT_LOCAL_DOCKER_PUBLIC_V2:workstation-abc123',
        jsonb_build_object('namespaces',jsonb_object_agg(substr(name,length('$base')+2),uuid::text),
                           'blocked','','conflicts','','deferred','')::text
      FROM namespaces WHERE user_id IS NULL AND name LIKE '$base-%';" >/dev/null
}

# Fresh seed: no owner/account required, only the 13 official names and six
# public groups protected by API key. Probe-only cannot mutate an absent seed.
query "INSERT INTO config(id,value) VALUES ('DISABLE_SIGNUP','true');" >/dev/null
assert_eq 'needs-apply|||||' "$(run_seed '' skip-only)" 'read-only preflight requests an offline seed'
assert_eq '0' "$(query 'SELECT count(*) FROM mcp_servers')" 'preflight makes no changes'
assert_eq "seeded||$groups|||" "$(run_seed)" 'fresh public seed without an account'
assert_eq '0|13|6|6|13|true' "$(query "SELECT (SELECT count(*) FROM users)||'|'||(SELECT count(*) FROM mcp_servers WHERE user_id IS NULL)||'|'||(SELECT count(*) FROM namespaces WHERE user_id IS NULL)||'|'||(SELECT count(*) FROM endpoints WHERE user_id IS NULL AND enable_api_key_auth AND NOT enable_oauth)||'|'||(SELECT count(*) FROM namespace_server_mappings)||'|'||(SELECT value FROM config WHERE id='DISABLE_SIGNUP')")" '13 shared servers and six protected groups; signup unchanged'
assert_eq 'codebase-memory-mcp,codegraph,dbhub,desktop-commander,everything-search,filesystem,git,markitdown,obsidian,playwright,serena,simple-files-vectorstore,windows-mcp' "$(query 'SELECT string_agg(name,chr(44) ORDER BY name) FROM mcp_servers')" 'official short names only'
assert_eq 'code:4,data:1,files:3,memory:2,system:2,web:1' "$(query "SELECT string_agg(suffix || ':' || cnt, ',' ORDER BY suffix) FROM (SELECT n.name suffix, count(*) cnt FROM namespaces n JOIN namespace_server_mappings m ON n.uuid=m.namespace_uuid GROUP BY n.name) x")" 'each server is mapped to its intended group'
assert_eq "skipped||$groups|||" "$(run_seed '' skip-only)" 'ordinary restart is read-only'
assert_eq 'missing|||||' "$(run_seed nobody@example.com true)" 'unknown explicit account does not create a user'
query "INSERT INTO users(id,email) VALUES ('alice','alice@example.com'),('bob','bob@example.com');" >/dev/null
alice64="$(printf alice@example.com | base64 | tr -d '\r\n')"
assert_eq "seeded|$alice64|$groups|||" "$(run_seed alice@example.com true)" 'explicit existing account is returned separately'
query "INSERT INTO users(id,email) VALUES ('alice2','ALICE@example.com');" >/dev/null
assert_eq 'ambiguous|||||' "$(run_seed alice@example.com true)" 'case-insensitive ambiguous account is not selected'

# Repeats preserve deletions, user edits and disabled mappings. Explicit repair
# restores missing defaults without overwriting edited connections or statuses.
query "DELETE FROM endpoints WHERE name='code'; DELETE FROM mcp_servers WHERE name='playwright' AND user_id IS NULL;
 UPDATE namespace_server_mappings SET status='INACTIVE' WHERE mcp_server_uuid=(SELECT uuid FROM mcp_servers WHERE name='filesystem');
 UPDATE mcp_servers SET url='http://example.com/custom' WHERE name='dbhub';" >/dev/null
assert_eq "skipped||$without_code|||" "$(run_seed '' skip-only)" 'automatic repeat preserves deletions'
assert_eq '0|0|INACTIVE|http://example.com/custom' "$(query "SELECT (SELECT count(*) FROM endpoints WHERE name='code')||'|'||(SELECT count(*) FROM mcp_servers WHERE name='playwright')||'|'||(SELECT m.status FROM namespace_server_mappings m JOIN mcp_servers s ON m.mcp_server_uuid=s.uuid WHERE s.name='filesystem')||'|'||(SELECT url FROM mcp_servers WHERE name='dbhub')")" 'deleted and customized records are untouched'
assert_eq "seeded||$groups|||" "$(run_seed '' true)" 'explicit repair restores only missing defaults'
assert_eq '1|1|INACTIVE|http://example.com/custom' "$(query "SELECT (SELECT count(*) FROM endpoints WHERE name='code')||'|'||(SELECT count(*) FROM mcp_servers WHERE name='playwright')||'|'||(SELECT m.status FROM namespace_server_mappings m JOIN mcp_servers s ON m.mcp_server_uuid=s.uuid WHERE s.name='filesystem')||'|'||(SELECT url FROM mcp_servers WHERE name='dbhub')")" 'repair preserves edits and inactive mapping'
query "UPDATE endpoints SET enable_api_key_auth=false WHERE name='memory';" >/dev/null
assert_has "$(run_seed '' skip-only)" "|memory|" 'a subsequently opened endpoint is reported'
query "DELETE FROM namespaces WHERE name='code'; INSERT INTO namespaces(name,user_id) VALUES ('code',NULL);
 INSERT INTO endpoints(name,namespace_uuid,enable_api_key_auth,user_id) SELECT 'foreign-code',uuid,true,NULL FROM namespaces WHERE name='code';" >/dev/null
assert_has "$(run_seed '' true)" "namespace:code" 'replacement namespace is not adopted'
assert_eq 0 "$(query "SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid WHERE n.name='code'")" 'no tools are added to a foreign namespace'

# An actual V1-shaped installation is promoted in place. The old endpoint and
# server UUIDs survive; disabled server/tool statuses and overrides are copied.
groups="$legacy_groups"
reset_db
setup_legacy alice alice@example.com "$base"
old_filesystem="$(query "SELECT uuid FROM mcp_servers WHERE name='$base-filesystem'")"
old_endpoint="$(query "SELECT uuid FROM endpoints WHERE name='$base'")"
query "INSERT INTO config(id,value) VALUES ('DISABLE_SIGNUP','true');
 UPDATE namespace_server_mappings SET status='INACTIVE' WHERE mcp_server_uuid=(SELECT uuid FROM mcp_servers WHERE name='$base-windows-mcp');
 INSERT INTO tools(name,mcp_server_uuid,tool_schema) SELECT 'git_status',uuid,'{\"type\":\"object\"}' FROM mcp_servers WHERE name='$base-git';
 INSERT INTO namespace_tool_mappings(namespace_uuid,tool_uuid,mcp_server_uuid,status,override_name)
 SELECT n.uuid,t.uuid,t.mcp_server_uuid,'INACTIVE','custom_git_status' FROM namespaces n,tools t WHERE n.name='$base';" >/dev/null
assert_eq "seeded||$groups|||" "$(run_seed)" 'V1 is migrated automatically'
assert_eq '13|13|0|1|1|true' "$(query "SELECT (SELECT count(*) FROM mcp_servers)||'|'||(SELECT count(*) FROM mcp_servers WHERE user_id IS NULL)||'|'||(SELECT count(*) FROM mcp_servers WHERE name LIKE '$base-%')||'|'||(SELECT count(*) FROM namespaces WHERE name='$base' AND user_id IS NULL)||'|'||(SELECT count(*) FROM endpoints WHERE name='$base' AND user_id IS NULL AND enable_api_key_auth)||'|'||(SELECT value FROM config WHERE id='DISABLE_SIGNUP')")" 'V1 records are shared without duplicates or changing signup'
assert_eq "$old_filesystem|$old_endpoint" "$(query "SELECT (SELECT uuid FROM mcp_servers WHERE name='filesystem')||'|'||(SELECT uuid FROM endpoints WHERE name='$base')")" 'V1 server and endpoint UUIDs are reused'
assert_eq 'INACTIVE|INACTIVE|INACTIVE|custom_git_status' "$(query "SELECT (SELECT m.status FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE n.name='$base' AND s.name='windows-mcp')||'|'||(SELECT m.status FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE n.name='$base-system' AND s.name='windows-mcp')||'|'||(SELECT tm.status FROM namespace_tool_mappings tm JOIN namespaces n ON n.uuid=tm.namespace_uuid WHERE n.name='$base-code')||'|'||(SELECT tm.override_name FROM namespace_tool_mappings tm JOIN namespaces n ON n.uuid=tm.namespace_uuid WHERE n.name='$base-code')")" 'legacy restrictions are copied rather than re-enabled'
# Retry after the old namespace is already public: its stored UUID still lets
# seed copy restrictions and does not adopt a different namespace by name.
query "DELETE FROM namespace_tool_mappings WHERE namespace_uuid=(SELECT uuid FROM namespaces WHERE name='$base-code');
 DELETE FROM namespace_server_mappings WHERE namespace_uuid=(SELECT uuid FROM namespaces WHERE name='$base-code') AND mcp_server_uuid=(SELECT uuid FROM mcp_servers WHERE name='git');" >/dev/null
assert_eq "seeded||$groups|||" "$(run_seed '' true)" 'explicit retry reuses the promoted legacy namespace'
assert_eq 'INACTIVE|custom_git_status' "$(query "SELECT tm.status||'|'||tm.override_name FROM namespace_tool_mappings tm JOIN namespaces n ON n.uuid=tm.namespace_uuid WHERE n.name='$base-code'")" 'restrictions are still copied after promotion'

# A deleted V1 server is not silently restored. Explicit seed restores a new
# public default, without recreating its old legacy namespace mapping.
reset_db
setup_legacy alice alice@example.com "$base"
query "DELETE FROM mcp_servers WHERE name='$base-playwright';" >/dev/null
assert_has "$(run_seed)" '|playwright' 'deleted V1 server is deferred on automatic upgrade'
assert_eq 0 "$(query "SELECT count(*) FROM mcp_servers WHERE name='playwright'")" 'no new server on automatic upgrade'
assert_eq "seeded||$groups|||" "$(run_seed '' true)" 'explicit seed restores missing default'
assert_eq '1|0' "$(query "SELECT (SELECT count(*) FROM mcp_servers WHERE name='playwright')||'|'||(SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE n.name='$base' AND s.name='playwright')")" 'legacy deletion remains untouched'

# V1 + already-applied V2: consolidate 26 rows to 13, preserving UUIDs,
# endpoints, tools, overrides, OAuth state, audit history and descriptions.
reset_db
setup_legacy alice alice@example.com "$base"
setup_v2
old_server="$(query "SELECT uuid FROM mcp_servers WHERE name='$base-filesystem'")"
old_endpoint="$(query "SELECT uuid FROM endpoints WHERE name='$base'")"
v2_endpoint="$(query "SELECT uuid FROM endpoints WHERE name='$base-files'")"
query "UPDATE mcp_servers SET description='My filesystem' WHERE name='$base-filesystem';
 INSERT INTO tools(name,tool_schema,mcp_server_uuid) SELECT 'read_file','{\"type\":\"object\"}',uuid FROM mcp_servers WHERE name IN ('$base-filesystem','$public-filesystem');
 INSERT INTO tools(name,tool_schema,mcp_server_uuid) SELECT 'v2_only','{\"type\":\"object\"}',uuid FROM mcp_servers WHERE name='$public-filesystem';
 INSERT INTO namespace_tool_mappings(namespace_uuid,tool_uuid,mcp_server_uuid,status,override_name)
 SELECT n.uuid,t.uuid,s.uuid,CASE WHEN n.user_id='alice' THEN 'INACTIVE'::mcp_server_status ELSE 'ACTIVE'::mcp_server_status END,
        CASE WHEN n.user_id='alice' THEN 'private_read' ELSE NULL END
 FROM namespaces n JOIN namespace_server_mappings m ON m.namespace_uuid=n.uuid JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid JOIN tools t ON t.mcp_server_uuid=s.uuid
 WHERE t.name IN ('read_file','v2_only');
 INSERT INTO oauth_sessions(mcp_server_uuid,tokens) SELECT uuid,'{\"access_token\":\"keep\"}' FROM mcp_servers WHERE name='$public-filesystem';
 INSERT INTO mcp_request_audit_logs(mcp_server_uuid,mcp_server_name) SELECT uuid,name FROM mcp_servers WHERE name='$public-filesystem';" >/dev/null
v2_only_tool="$(query "SELECT t.uuid FROM tools t JOIN mcp_servers s ON s.uuid=t.mcp_server_uuid WHERE t.name='v2_only' AND s.name='$public-filesystem'")"
assert_eq "seeded||$groups|||" "$(run_seed)" 'V2 marker does not skip V3 deduplication'
assert_eq '13|0|0|2|1|1' "$(query "SELECT (SELECT count(*) FROM mcp_servers)||'|'||(SELECT count(*) FROM mcp_servers WHERE name LIKE 'winpub-%')||'|'||(SELECT count(*) FROM mcp_servers WHERE name LIKE '$base-%')||'|'||(SELECT count(*) FROM tools)||'|'||(SELECT count(*) FROM oauth_sessions)||'|'||(SELECT count(*) FROM mcp_request_audit_logs WHERE mcp_server_uuid IS NOT NULL)")" 'no duplicate servers or cascade data loss'
assert_eq "$old_server|$old_endpoint|$v2_endpoint|My filesystem|$v2_only_tool" "$(query "SELECT (SELECT uuid FROM mcp_servers WHERE name='filesystem')||'|'||(SELECT uuid FROM endpoints WHERE name='$base')||'|'||(SELECT uuid FROM endpoints WHERE name='$base-files')||'|'||(SELECT description FROM mcp_servers WHERE name='filesystem')||'|'||(SELECT uuid FROM tools WHERE name='v2_only')")" 'old server/endpoint and unique V2 tool UUIDs are preserved'
assert_eq 'INACTIVE|private_read|ACTIVE|keep|true' "$(query "SELECT (SELECT tm.status FROM namespace_tool_mappings tm JOIN namespaces n ON n.uuid=tm.namespace_uuid JOIN tools t ON t.uuid=tm.tool_uuid WHERE n.name='$base' AND t.name='read_file')||'|'||(SELECT tm.override_name FROM namespace_tool_mappings tm JOIN namespaces n ON n.uuid=tm.namespace_uuid JOIN tools t ON t.uuid=tm.tool_uuid WHERE n.name='$base' AND t.name='read_file')||'|'||(SELECT tm.status FROM namespace_tool_mappings tm JOIN namespaces n ON n.uuid=tm.namespace_uuid JOIN tools t ON t.uuid=tm.tool_uuid WHERE n.name='$base-files' AND t.name='read_file')||'|'||(SELECT tokens->>'access_token' FROM oauth_sessions)||'|'||(SELECT mcp_server_uuid=(SELECT uuid FROM mcp_servers WHERE name='filesystem') FROM mcp_request_audit_logs)")" 'tool restrictions, OAuth and audit links survived'
assert_eq "skipped||$groups|||" "$(run_seed '' skip-only)" 'V3 migration is idempotent'

# V2 deletions stay deleted during automatic V3 migration, including group
# mappings; explicit seed can restore them after review.
reset_db
setup_legacy alice alice@example.com "$base"
setup_v2
query "DELETE FROM endpoints WHERE name='$base-memory';
 DELETE FROM namespace_server_mappings WHERE mcp_server_uuid=(SELECT uuid FROM mcp_servers WHERE name='$public-playwright');
 DELETE FROM mcp_servers WHERE name='$public-markitdown';" >/dev/null
v2_upgrade="$(run_seed)"
assert_has "$v2_upgrade" 'markitdown' 'missing V2 server mapping is deferred'
assert_has "$v2_upgrade" 'playwright' 'deleted V2 group mapping is deferred'
assert_eq '0|0|0|13' "$(query "SELECT (SELECT count(*) FROM endpoints WHERE name='$base-memory')||'|'||(SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE n.name='$base-web' AND s.name='playwright')||'|'||(SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE n.name='$base-files' AND s.name='markitdown')||'|'||(SELECT count(*) FROM mcp_servers)")" 'V2 deletions remain intentional'
assert_eq "seeded||$groups|||" "$(run_seed '' true)" 'explicit retry restores missing V2 defaults'

# Conflicts do not discard different configurations, OAuth sessions, tool
# schemas, colliding mapping statuses, or an unrelated short-name server.
reset_db
setup_legacy alice alice@example.com "$base"
setup_v2
query "INSERT INTO users(id,email) VALUES ('foreign','foreign@example.com');
 INSERT INTO mcp_servers(name,type,command,user_id) VALUES ('filesystem','STDIO','foreign-filesystem','foreign');
 UPDATE mcp_servers SET url='http://example.com/custom' WHERE name='$base-dbhub';
 INSERT INTO oauth_sessions(mcp_server_uuid,tokens) SELECT uuid,jsonb_build_object('token',name) FROM mcp_servers WHERE name IN ('$base-git','$public-git');
 INSERT INTO tools(name,tool_schema,mcp_server_uuid) SELECT 'different',CASE WHEN user_id IS NULL THEN '{\"type\":\"object\",\"x\":1}'::jsonb ELSE '{\"type\":\"object\",\"x\":2}'::jsonb END,uuid FROM mcp_servers WHERE name IN ('$base-codegraph','$public-codegraph');
 INSERT INTO namespace_server_mappings(namespace_uuid,mcp_server_uuid,status) SELECT n.uuid,s.uuid,'INACTIVE' FROM namespaces n,mcp_servers s WHERE n.name='$base' AND s.name='$public-serena';
 INSERT INTO tools(name,mcp_server_uuid,tool_schema) SELECT 'same_tool',uuid,'{\"type\":\"object\"}' FROM mcp_servers WHERE name IN ('$base-obsidian','$public-obsidian');
 INSERT INTO namespace_server_mappings(namespace_uuid,mcp_server_uuid) SELECT n.uuid,s.uuid FROM namespaces n,mcp_servers s WHERE n.name='$base' AND s.name='$public-obsidian';
 INSERT INTO namespace_tool_mappings(namespace_uuid,tool_uuid,mcp_server_uuid,status) SELECT n.uuid,t.uuid,t.mcp_server_uuid,CASE WHEN s.user_id IS NULL THEN 'ACTIVE'::mcp_server_status ELSE 'INACTIVE'::mcp_server_status END FROM namespaces n,tools t JOIN mcp_servers s ON s.uuid=t.mcp_server_uuid WHERE n.name='$base' AND t.name='same_tool';" >/dev/null
conflicted="$(run_seed)"
for id in filesystem dbhub git codegraph serena obsidian; do assert_has "$conflicted" "server:$id" 'unsafe server merge is reported'; done
assert_has "$conflicted" "namespace:$base" 'legacy namespace with unresolved foreign/private servers is not published'
assert_eq '3|2|2|2|2|foreign-filesystem|alice' "$(query "SELECT (SELECT count(*) FROM mcp_servers WHERE name IN ('filesystem','$base-filesystem','$public-filesystem'))||'|'||(SELECT count(*) FROM mcp_servers WHERE name IN ('$base-dbhub','$public-dbhub'))||'|'||(SELECT count(*) FROM oauth_sessions)||'|'||(SELECT count(*) FROM tools WHERE name='different')||'|'||(SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE n.name='$base' AND s.name IN ('$base-serena','$public-serena'))||'|'||(SELECT command FROM mcp_servers WHERE name='filesystem')||'|'||(SELECT user_id FROM endpoints WHERE name='$base')")" 'all conflicting records and private endpoint are preserved'
assert_eq '2|1' "$(query "SELECT (SELECT count(*) FROM namespace_tool_mappings tm JOIN tools t ON t.uuid=tm.tool_uuid WHERE t.name='same_tool')||'|'||(SELECT count(*) FROM namespace_tool_mappings tm JOIN tools t ON t.uuid=tm.tool_uuid WHERE t.name='same_tool' AND tm.status='INACTIVE')")" 'conflicting tool mappings are not merged or re-enabled'
assert_has "$(run_seed '' skip-only)" 'server:git' 'warnings survive restart'

# A user-installed FK with cascading deletion prevents deduplication, rather
# than allowing the pinned schema assumptions to destroy extension data.
reset_db
setup_legacy alice alice@example.com "$base"
setup_v2
query "CREATE TABLE user_extension (server_uuid uuid REFERENCES mcp_servers(uuid) ON DELETE CASCADE, value text); INSERT INTO user_extension SELECT uuid,'keep' FROM mcp_servers WHERE name='$public-filesystem';" >/dev/null
extension="$(run_seed)"
assert_has "$extension" 'server:filesystem' 'unknown foreign key blocks deletion'
assert_eq '26|1|keep' "$(query "SELECT (SELECT count(*) FROM mcp_servers)||'|'||(SELECT count(*) FROM user_extension)||'|'||(SELECT value FROM user_extension)")" 'unknown extension data is preserved'
query 'DROP TABLE user_extension;' >/dev/null

# A legacy endpoint that was opened is not promoted or used to create new
# server mappings; the warning makes the pre-existing exposure explicit.
reset_db
setup_legacy alice alice@example.com "$base"
query "UPDATE endpoints SET enable_api_key_auth=false WHERE name='$base';" >/dev/null
opened_legacy="$(run_seed)"
assert_has "$opened_legacy" "|$base|" 'open legacy endpoint is reported'
assert_eq 'alice|0' "$(query "SELECT (SELECT user_id FROM endpoints WHERE name='$base')||'|'||(SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid WHERE n.name LIKE '$base-%' AND n.user_id IS NULL)")" 'open old endpoint stays private and no group mappings are added'

# Multiple V1 owners can share one server without losing their individual
# statuses. A public group uses the most restrictive status and refuses
# mutually incompatible per-owner overrides.
reset_db
setup_legacy alice alice@example.com "$base"
bob_base="$base-$(query "SELECT substr(md5('bob'),1,8)")"
setup_legacy bob bob@example.com "$bob_base"
query "UPDATE namespace_server_mappings SET status='INACTIVE' WHERE mcp_server_uuid=(SELECT uuid FROM mcp_servers WHERE name='$bob_base-git');
 INSERT INTO tools(name,mcp_server_uuid,tool_schema) SELECT 'read_file',uuid,'{\"type\":\"object\"}' FROM mcp_servers WHERE name IN ('$base-filesystem','$bob_base-filesystem');
 INSERT INTO tools(name,mcp_server_uuid,tool_schema) SELECT 'inspect',uuid,'{\"type\":\"object\"}' FROM mcp_servers WHERE name IN ('$base-codegraph','$bob_base-codegraph');
 INSERT INTO namespace_tool_mappings(namespace_uuid,tool_uuid,mcp_server_uuid,status,override_name)
 SELECT n.uuid,t.uuid,s.uuid,CASE WHEN s.user_id='bob' AND t.name='read_file' THEN 'INACTIVE'::mcp_server_status ELSE 'ACTIVE'::mcp_server_status END,
        CASE WHEN s.user_id='bob' AND t.name='inspect' THEN 'bob_override' ELSE NULL END
 FROM namespaces n JOIN namespace_server_mappings m ON m.namespace_uuid=n.uuid JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid JOIN tools t ON t.mcp_server_uuid=s.uuid;" >/dev/null
multi="$(run_seed)"
assert_has "$multi" 'codegraph' 'conflicting per-owner overrides are deferred'
assert_eq '13|2|INACTIVE|INACTIVE|0' "$(query "SELECT (SELECT count(*) FROM mcp_servers)||'|'||(SELECT count(*) FROM endpoints WHERE name IN ('$base','$bob_base') AND user_id IS NULL)||'|'||(SELECT m.status FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE n.name='$base-code' AND s.name='git')||'|'||(SELECT tm.status FROM namespace_tool_mappings tm JOIN namespaces n ON n.uuid=tm.namespace_uuid JOIN tools t ON t.uuid=tm.tool_uuid WHERE n.name='$base-files' AND t.name='read_file')||'|'||(SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE n.name='$base-code' AND s.name='codegraph')")" 'both old endpoints and restrictive mappings survive'
query "UPDATE namespace_tool_mappings SET override_name=NULL WHERE namespace_uuid=(SELECT uuid FROM namespaces WHERE name='$bob_base') AND override_name='bob_override';" >/dev/null
assert_eq "seeded||$groups|||" "$(run_seed '' true)" 'after resolving overrides, retry works with both promoted legacy namespaces'

# Existing open or foreign namespaces are not used, even on explicit repair.
reset_db
query "INSERT INTO users(id,email) VALUES ('bob','bob@example.com');
 INSERT INTO namespaces(name,user_id) VALUES ('files','bob'),('web',NULL),('other','bob');
 INSERT INTO endpoints(name,namespace_uuid,enable_api_key_auth,user_id) SELECT 'open-web',uuid,false,NULL FROM namespaces WHERE name='web';
 INSERT INTO endpoints(name,namespace_uuid,enable_api_key_auth,user_id) SELECT 'data',uuid,true,'bob' FROM namespaces WHERE name='other';
 INSERT INTO mcp_servers(name,type,command,user_id) VALUES ('git','STDIO','foreign-one',NULL),('git','STDIO','foreign-two',NULL),('serena','STDIO','custom','bob');" >/dev/null
conflicted="$(run_seed)"
assert_has "$conflicted" "|web|" 'open namespace is reported'
for problem in "namespace:files" "endpoint:data" 'server:git' 'server:serena'; do assert_has "$conflicted" "$problem" 'foreign name is reported'; done
assert_eq '0|0|2|1' "$(query "SELECT (SELECT count(*) FROM endpoints WHERE name='web')||'|'||(SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid WHERE n.name='web')||'|'||(SELECT count(*) FROM mcp_servers WHERE name='git')||'|'||(SELECT count(*) FROM mcp_servers WHERE name='serena' AND user_id='bob')")" 'foreign/open records remain intact'

echo 'Windows local short-name migration scenarios passed.'
