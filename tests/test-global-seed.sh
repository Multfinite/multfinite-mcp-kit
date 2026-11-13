#!/usr/bin/env bash
# Real PostgreSQL, with Docker/Compose mocked at the boundary. The tests never
# create real containers or install system packages.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
: "${TEST_DATABASE_URL:?Set TEST_DATABASE_URL to a disposable PostgreSQL database}"
command -v psql >/dev/null || { echo "psql is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

TMP="$(mktemp -d)"
SCHEMA="mcpkit_test_${RANDOM}_$$"
export MOCK_STATE="$TMP/state" MOCK_LOG="$TMP/docker.log"
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin" "$MOCK_STATE"

cleanup() {
    PGOPTIONS='' psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -q -c "DROP SCHEMA IF EXISTS \"$SCHEMA\" CASCADE" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT
export PGOPTIONS="-c search_path=$SCHEMA,public"

reset_db() {
    PGOPTIONS='' psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -q -c "DROP SCHEMA IF EXISTS \"$SCHEMA\" CASCADE; CREATE SCHEMA \"$SCHEMA\";" >/dev/null 2>&1
    psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -q -f "$ROOT/tests/fixtures/metamcp-schema.sql"
}
query() { psql "$TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -qAt -c "$1"; }
assert_eq() {
    if [ "$1" != "$2" ]; then
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$3" "$1" "$2" >&2
        exit 1
    fi
}
assert_contains() {
    if ! grep -Fq -- "$2" "$1"; then
        printf 'FAIL: %s\n' "$3" >&2
        cat "$1" >&2
        exit 1
    fi
}
assert_not_contains() {
    if grep -Fq -- "$2" "$1"; then
        printf 'FAIL: %s\n' "$3" >&2
        cat "$1" >&2
        exit 1
    fi
}
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$MOCK_LOG"; printf '\n' >> "$MOCK_LOG"
project=multfinite-mcp-kit-global
case "${1:-}" in
    info) exit 0 ;;
    --version) echo 'Docker test' ;;
    network|volume)
        kind="$1"
        case "${2:-}" in
            inspect)
                if [ "${3:-}" = --format ]; then
                    [ -f "$MOCK_STATE/$kind-$5" ] || exit 1
                    cat "$MOCK_STATE/$kind-$5"
                else
                    [ -f "$MOCK_STATE/$kind-$3" ] || exit 1
                fi
                ;;
            create) echo "$project" > "$MOCK_STATE/$kind-$3"; echo mock-network-id ;;
            connect)
                [ "$kind" = network ] && [ -f "$MOCK_STATE/network-$3" ] && [ "$4" = mock-app ] || exit 1
                [ "${MOCK_CONNECT_FAIL:-0}" != 1 ] || exit 1
                : > "$MOCK_STATE/attached-$3"
                ;;
            *) exit 1 ;;
        esac
        ;;
    inspect)
        if [ "${2:-}" = --format ] && [ "${4:-}" = mock-app ]; then
            if [[ "${3:-}" == *'.Config.Env'* ]]; then
                [ ! -f "$MOCK_STATE/app-env" ] || cat "$MOCK_STATE/app-env"
            else
                printf '{'
                sep=''
                for f in "$MOCK_STATE"/attached-*; do
                    [ -f "$f" ] || continue
                    name="${f##*/attached-}"
                    printf '%s"%s":{}' "$sep" "$name"
                    sep=,
                done
                echo '}'
            fi
        elif [ "${2:-}" = --format ]; then
            [ -f "$MOCK_STATE/container-$4" ] || exit 1
            cat "$MOCK_STATE/container-$4"
        else
            [ -f "$MOCK_STATE/container-$2" ] || exit 1
        fi
        ;;
    run)
        name=''
        while [ "$#" -gt 0 ]; do
            if [ "$1" = --name ]; then name="$2"; break; fi
            shift
        done
        [ -n "$name" ] || exit 1
        echo true > "$MOCK_STATE/container-$name"
        echo mock-container-id
        ;;
    start) echo true > "$MOCK_STATE/container-$2"; echo "$2" ;;
    stop) exit 0 ;;
    ps) printf 'metamcp\nneo4j-mcp\nqdrant-mcp\nmcpkit-memory-bank\n' ;;
    compose)
        shift
        if [ "${1:-}" = -p ]; then
            [ "$2" = "$project" ] && [ "$3" = -f ] || exit 1
            shift 4
            case "${1:-}" in
                up)
                    [ "${MOCK_SERVICES_FAIL:-0}" != 1 ] || { echo 'simulated sidecar failure' >&2; exit 1; }
                    for n in graphiti cognee memory gdrive; do echo "$project|$n" > "$MOCK_STATE/network-$project-$n"; done
                    for n in cognee-system cognee-data memory-data gdrive-data; do echo "$project|${n//-/_}" > "$MOCK_STATE/volume-$project-$n"; done
                    printf '%s' "${MCPKIT_NEO4J_URI:-}" > "$MOCK_STATE/graphiti-uri"
                    printf '%s' "${MCPKIT_NEO4J_USER:-}" > "$MOCK_STATE/graphiti-user"
                    printf '%s' "${MCPKIT_NEO4J_PASSWORD:-}" > "$MOCK_STATE/graphiti-password"
                    printf '%s' "${MCPKIT_NEO4J_DATABASE:-}" > "$MOCK_STATE/graphiti-database"
                    printf '%s' "${MCPKIT_GRAPHITI_GROUP_ID:-}" > "$MOCK_STATE/graphiti-group"
                    printf '%s' "${MCPKIT_GRAPHITI_API_KEY:-}" > "$MOCK_STATE/graphiti-openai"
                    printf '%s' "${MCPKIT_GRAPHITI_API_ENDPOINT:-}" > "$MOCK_STATE/graphiti-base-url"
                    printf '%s' "${MCPKIT_GRAPHITI_API_MODEL:-}" > "$MOCK_STATE/graphiti-model"
                    printf '%s' "${MCPKIT_COGNEE_LLM_API_KEY:-}" > "$MOCK_STATE/cognee-llm"
                    printf '%s' "${MCPKIT_COGNEE_LLM_API_ENDPOINT:-}" > "$MOCK_STATE/cognee-llm-endpoint"
                    printf '%s' "${MCPKIT_COGNEE_LLM_API_MODEL:-}" > "$MOCK_STATE/cognee-llm-model"
                    printf '%s' "${MCPKIT_COGNEE_LLM_API_PROVIDER:-}" > "$MOCK_STATE/cognee-llm-provider"
                    printf '%s' "${MCPKIT_COGNEE_EMBEDDING_API_KEY:-}" > "$MOCK_STATE/cognee-embedding"
                    printf '%s' "${MCPKIT_COGNEE_EMBEDDING_API_ENDPOINT:-}" > "$MOCK_STATE/cognee-embedding-endpoint"
                    printf '%s' "${MCPKIT_COGNEE_EMBEDDING_API_MODEL:-}" > "$MOCK_STATE/cognee-embedding-model"
                    printf '%s' "${MCPKIT_COGNEE_EMBEDDING_API_PROVIDER:-}" > "$MOCK_STATE/cognee-embedding-provider"
                    ;;
                stop|logs) exit 0 ;;
                *) echo "Unexpected service Compose command: $*" >&2; exit 1 ;;
            esac
            exit 0
        fi
        if [ "${POSTGRES_PASSWORD:-}" = must-not-override-compose ]; then
            echo 'kit .env leaked into MetaMCP Compose environment' >&2
            exit 1
        fi
        case "${1:-}" in
            version) echo '2.30.0' ;;
            pull|stop|down|logs) exit 0 ;;
            up)
                if [[ " $* " == *" --force-recreate app "* ]] || [ ! -f "$MOCK_STATE/app-env" ]; then
                    grep -E '^(APP_URL|NEXT_PUBLIC_APP_URL)=' "$HOME/mcp-global/metamcp/.env" > "$MOCK_STATE/app-env" || :
                fi
                ;;
            run)
                if [[ " $* " == *" --user 1001:1001 "* ]]; then
                    if [ "${MOCK_UV_CACHE_BAD:-0}" = 1 ] && [ ! -f "$MOCK_STATE/uv-cache-repaired" ]; then exit 1; fi
                elif [[ " $* " == *" --user 0:0 "* ]]; then
                    : > "$MOCK_STATE/uv-cache-repaired"
                else
                    echo "Unexpected compose run: $*" >&2; exit 1
                fi
                ;;
            ps)
                if { [ "$2" = -q ] && [ "$3" = app ]; } || { [ "$2" = -a ] && [ "$3" = -q ] && [ "$4" = app ]; }; then echo mock-app; fi
                ;;
            exec)
                [ "$2" = -T ] && [ "$3" = app ] || exit 1
                shift 3
                case "$1" in
                    curl)
                        count=0
                        [ ! -f "$MOCK_STATE/health-count" ] || count="$(cat "$MOCK_STATE/health-count")"
                        count=$((count + 1))
                        echo "$count" > "$MOCK_STATE/health-count"
                        if [ "${MOCK_HEALTH_ALWAYS_FAIL:-0}" = 1 ] || (( count <= ${MOCK_HEALTH_FAILURES:-0} )); then exit 1; fi
                        ;;
                    sh)
                        [ "$2" = -c ] || exit 1
                        case "$3" in
                            *'DATABASE_URL'*'ON_ERROR_STOP=1'*) ;;
                            *) echo 'seed must use app DATABASE_URL and ON_ERROR_STOP' >&2; exit 1 ;;
                        esac
                        export DATABASE_URL="$TEST_DATABASE_URL"
                        exec sh -c "$3"
                        ;;
                    *) echo "Unexpected compose exec: $*" >&2; exit 1 ;;
                esac
                ;;
            *) echo "Unexpected MetaMCP Compose command: $*" >&2; exit 1 ;;
        esac
        ;;
    *) echo "Unexpected docker command: $*" >&2; exit 1 ;;
esac
MOCK
cat > "$TMP/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
exec "$@"
MOCK
cat > "$TMP/bin/apt-get" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$TMP/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMP/bin/"*

prepare_home() {
    HOME="$(mktemp -d "$TMP/home.XXXXXX")"
    export HOME
    rm -f "$MOCK_STATE"/*
    mkdir -p "$HOME/mcp-global/metamcp/.git" "$HOME/mcp-global/config"
    cat > "$HOME/mcp-global/metamcp/example.env" <<'EOF'
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_USER=metamcp_user
POSTGRES_PASSWORD=m3t4mcp
POSTGRES_DB=metamcp_db
DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
APP_URL=http://localhost:12008
NEXT_PUBLIC_APP_URL=http://localhost:12008
BETTER_AUTH_SECRET=your-super-secret-key-change-this-in-production
BOOTSTRAP_USER_EMAIL=test@user.example
BOOTSTRAP_USER_PASSWORD=changeme
BOOTSTRAP_RECREATE_USER=true
BOOTSTRAP_NAMESPACES=[{"name":"Default","update":true}]
BOOTSTRAP_ENDPOINTS=[{"name":"Public","update":true}]
EOF
    : > "$MOCK_LOG"
}
prepare_existing() {
    prepare_home
    cp "$HOME/mcp-global/metamcp/example.env" "$HOME/mcp-global/metamcp/.env"
    cat > "$HOME/mcp-global/config/.env" <<'EOF'
NEO4J_URI=bolt://localhost:7687
NEO4J_USER=neo4j
NEO4J_PASSWORD=mcp-neo4j-pass
QDRANT_URL=http://localhost:6333
EOF
}
export METAMCP_START_TIMEOUT=4

# A fresh install registers all eleven README servers, the four legacy records,
# five groups and five protected endpoints. fetch belongs to two groups.
reset_db
prepare_home
export MOCK_HEALTH_FAILURES=2
if ! bash "$ROOT/linux/install-global.sh" > "$TMP/install.out" 2>&1; then
    cat "$TMP/install.out" >&2; fail 'fresh installation failed'
fi
unset MOCK_HEALTH_FAILURES
assert_eq 3 "$(cat "$MOCK_STATE/health-count")" 'startup retries health until migrations finish'
assert_eq 14 "$(query 'SELECT count(*) FROM mcp_servers WHERE user_id IS NULL')" 'all global and legacy servers registered'
assert_eq 11 "$(query "SELECT count(*) FROM mcp_servers WHERE user_id IS NULL AND name IN ('sequentialthinking','graphiti','cognee','memory-bank-mcp','context7','duckduckgo','fetch','github-mcp-server','io-draw','mcp-compass','gdrive')")" 'all eleven README servers are present'
assert_eq 'global:fetch,neo4j-global,playwright,qdrant-global;global-integrations:gdrive,github-mcp-server,io-draw;global-memory:cognee,graphiti,memory-bank-mcp;global-reasoning:mcp-compass,sequentialthinking;global-web:context7,duckduckgo,fetch' \
    "$(query "SELECT string_agg(name||':'||servers, ';' ORDER BY name) FROM (SELECT n.name, string_agg(s.name, ',' ORDER BY s.name) servers FROM namespaces n JOIN namespace_server_mappings m ON m.namespace_uuid=n.uuid JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid GROUP BY n.name) x")" 'every group contains its intended servers'
assert_eq 'global:global-sse;global-integrations:global-integrations;global-memory:global-memory;global-reasoning:global-reasoning;global-web:global-web' \
    "$(query "SELECT string_agg(n.name||':'||e.name, ';' ORDER BY n.name) FROM endpoints e JOIN namespaces n ON n.uuid=e.namespace_uuid WHERE e.user_id IS NULL AND e.enable_api_key_auth")" 'new endpoints target the correct namespaces and require API keys'
assert_eq 0 "$(query 'SELECT count(*) FROM endpoints WHERE NOT enable_api_key_auth AND NOT enable_oauth')" 'no new endpoint is unauthenticated'
assert_eq 'npx|-y|@modelcontextprotocol/server-sequential-thinking@2025.12.18' "$(query "SELECT command||'|'||args[1]||'|'||args[2] FROM mcp_servers WHERE name='sequentialthinking'")" 'Node 20 compatible sequentialthinking version'
assert_eq 'npx|@upstash/context7-mcp@4.7.0|{}' "$(query "SELECT command||'|'||args[2]||'|'||env::text FROM mcp_servers WHERE name='context7'")" 'Context7 starts without a placeholder key'
assert_eq 'uvx|--with|duckduckgo-mcp-server[browser]==0.7.0|duckduckgo-mcp-server' "$(query "SELECT command||'|'||args[1]||'|'||args[2]||'|'||args[3] FROM mcp_servers WHERE name='duckduckgo'")" 'DuckDuckGo includes browser fallback'
assert_eq 'npx|@drawio/mcp@1.12.0|off' "$(query "SELECT command||'|'||args[2]||'|'||(env->>'DRAWIO_BROWSER') FROM mcp_servers WHERE name='io-draw'")" 'draw.io is headless'
assert_eq 'npx|@liuyoshio/mcp-compass@1.0.7' "$(query "SELECT command||'|'||args[2] FROM mcp_servers WHERE name='mcp-compass'")" 'official Compass package'
assert_eq 'STDIO|uvx|mcp-server-qdrant|http://host.docker.internal:6333' "$(query "SELECT type||'|'||command||'|'||args[1]||'|'||(env->>'QDRANT_URL') FROM mcp_servers WHERE name='qdrant-global'")" 'Qdrant package and host URL'
assert_eq 'uvx|mcp-neo4j-cypher|bolt://host.docker.internal:7687' "$(query "SELECT command||'|'||args[1]||'|'||(env->>'NEO4J_URI') FROM mcp_servers WHERE name='neo4j-global'")" 'Neo4j package and host URL'
assert_eq 'npx|@playwright/mcp|--headless' "$(query "SELECT command||'|'||args[2]||'|'||args[3] FROM mcp_servers WHERE name='playwright'")" 'legacy Playwright is retained'
assert_eq 'STREAMABLE_HTTP|https://api.githubcopilot.com/mcp/|true' "$(query "SELECT type||'|'||url||'|'||(bearer_token IS NULL) FROM mcp_servers WHERE name='github-mcp-server'")" 'official GitHub remote URL, without a fake token'
assert_eq 'cognee:http://mcpkit-cognee:8000/mcp;gdrive:http://mcpkit-gdrive:8000/mcp;graphiti:http://mcpkit-graphiti:8000/mcp;memory-bank-mcp:http://mcpkit-memory-bank:8000/mcp' \
    "$(query "SELECT string_agg(name||':'||url, ';' ORDER BY name) FROM mcp_servers WHERE name IN ('graphiti','cognee','memory-bank-mcp','gdrive') AND type='STREAMABLE_HTTP'")" 'four local sidecar addresses'
assert_eq 2 "$(query "SELECT count(*) FROM config WHERE id IN ('MULTFINITE_MCP_KIT_GLOBAL_SEED_V1','MULTFINITE_MCP_KIT_GLOBAL_SEED_V2')")" 'both version markers written'
assert_contains "$HOME/mcp-global/metamcp/.env" 'BOOTSTRAP_USER_PASSWORD=' 'example password disabled'
assert_not_contains "$HOME/mcp-global/metamcp/.env" 'BOOTSTRAP_USER_PASSWORD=changeme' 'example password not retained'
assert_contains "$HOME/mcp-global/metamcp/.env" 'BOOTSTRAP_RECREATE_USER=false' 'bootstrap will not recreate users'
assert_contains "$HOME/mcp-global/metamcp/.env" '"update":false' 'bootstrap will not overwrite edits'
assert_contains "$HOME/mcp-global/config/.env" 'LLM_API_ENDPOINT=https://api.openai.com/v1' 'global LLM endpoint default is configured'
assert_contains "$HOME/mcp-global/config/.env" 'LLM_API_KEY=' 'global LLM key setting is available'
assert_contains "$HOME/mcp-global/config/.env" 'LLM_API_MODEL=gpt-4o-mini' 'global LLM model default is configured'
assert_contains "$HOME/mcp-global/config/.env" '# GRAPHITI_API_ENDPOINT=' 'Graphiti can override the global endpoint'
assert_contains "$HOME/mcp-global/config/.env" '# COGNEE_LLM_API_ENDPOINT=' 'Cognee LLM can override the global endpoint'
assert_contains "$HOME/mcp-global/config/.env" 'COGNEE_EMBEDDING_API_ENDPOINT=' 'Cognee embedding endpoint can be overridden'
assert_contains "$HOME/mcp-global/config/.env" 'APP_URL=' 'public MetaMCP URL is configurable from the kit environment'
assert_not_contains "$HOME/mcp-global/config/.env" 'your-openai-key-here' 'new installs must not send fake keys'
assert_not_contains "$HOME/mcp-global/config/.env" "$(printf '\033')" 'config template contains no executed ANSI output'
assert_contains "$MOCK_LOG" 'compose up -d --no-recreate' 'MetaMCP is not recreated on start'
assert_contains "$MOCK_LOG" 'compose -p multfinite-mcp-kit-global -f ' 'separate Compose project used'
assert_contains "$MOCK_LOG" ' up -d --no-recreate ' 'sidecars are not recreated on start'
assert_eq 4 "$(find "$MOCK_STATE" -name 'attached-*' | wc -l | tr -d ' ')" 'app is attached to four isolated sidecar networks'
assert_eq 4 "$(find "$MOCK_STATE" -name 'volume-multfinite-mcp-kit-global-*' | wc -l | tr -d ' ')" 'four kit volumes are provisioned'
assert_eq neo4j "$(cat "$MOCK_STATE/graphiti-database")" 'Graphiti uses the standard Neo4j database by default'
assert_eq multfinite-mcp-kit-global "$(cat "$MOCK_STATE/graphiti-group")" 'Graphiti defaults to a kit-specific group'
assert_contains "$TMP/install.out" 'ГЛОБАЛЬНЫЙ СТЕК УСТАНОВЛЕН И ЗАПУЩЕН' 'success follows seeding and service startup'
printf 'ok - fresh installation, all servers, grouping, endpoints, sidecars and persistence\n'

# A transient startup failure must not leave kit-owned public servers stuck in
# ERROR after cache/network recovery; manual/user-owned rows are not touched.
query "UPDATE mcp_servers SET error_status='ERROR' WHERE user_id IS NULL AND name IN ('neo4j-global','qdrant-global','fetch','duckduckgo','graphiti','cognee','memory-bank-mcp','gdrive')" >/dev/null
bash "$ROOT/linux/run-global.sh" start > "$TMP/reset-error-state.out" 2>&1 || { cat "$TMP/reset-error-state.out" >&2; fail 'start did not recover kit server error states'; }
assert_eq 0 "$(query "SELECT count(*) FROM mcp_servers WHERE user_id IS NULL AND name IN ('neo4j-global','qdrant-global','fetch','duckduckgo','graphiti','cognee','memory-bank-mcp','gdrive') AND error_status='ERROR'")" 'start clears stale error state from kit-owned public servers'
assert_contains "$TMP/reset-error-state.out" 'Сброшен устаревший Error Status' 'stale error recovery is reported'
printf 'ok - startup clears stale kit-server ERROR state after dependencies are ready\n'

# A pre-existing public server is reused, private servers stay private, and
# disabled mappings/manual endpoint ownership and configuration survive.
reset_db
prepare_existing
cat > "$HOME/mcp-global/metamcp/.env" <<'EOF'
POSTGRES_USER=my_custom_user
POSTGRES_PASSWORD=my_custom_password
DATABASE_URL=postgresql://my_custom_user:my_custom_password@custom-db/private_db
APP_URL=https://my-existing-host.example
BETTER_AUTH_SECRET=my-existing-secret-that-must-not-change
EOF
cat > "$HOME/mcp-global/metamcp/docker-compose.override.yml" <<'EOF'
services:
  app:
    environment:
      MY_MANUAL_SETTING: keep-me
    networks:
      - default
      - mcp-net
networks:
  mcp-net:
    name: mcp-net
    external: true
EOF
cat > "$HOME/mcp-global/config/.env" <<'EOF'
NEO4J_URI=bolt://127.0.0.1:9767
NEO4J_USER=custom-user
NEO4J_PASSWORD='pa$$word'"'"' with spaces; SELECT pg_sleep(99); --'
QDRANT_URL='https://qdrant.example.test:443'
QDRANT_API_KEY='key-with-"quotes"'
GRAPHITI_API_KEY='graphiti-specific-secret'
GRAPHITI_API_ENDPOINT='https://graphiti.example.test/v1'
COGNEE_LLM_API_KEY='cognee-llm-secret'
COGNEE_LLM_API_ENDPOINT='https://llm.example.test/v1'
COGNEE_EMBEDDING_API_KEY='cognee-embedding-secret'
COGNEE_EMBEDDING_API_ENDPOINT='https://embeddings.example.test/v1'
GITHUB_PERSONAL_ACCESS_TOKEN='github-secret-$quoted'
CONTEXT7_API_KEY='context-secret-$quoted'
export POSTGRES_PASSWORD=must-not-override-compose
EOF
cp "$HOME/mcp-global/metamcp/.env" "$TMP/env-before"
cp "$HOME/mcp-global/metamcp/docker-compose.override.yml" "$TMP/override-before"
cp "$HOME/mcp-global/config/.env" "$TMP/global-env-before"
query "
INSERT INTO users VALUES ('owner');
INSERT INTO namespaces (uuid, name, description, user_id) VALUES
 ('00000000-0000-0000-0000-000000000101', 'global', 'manual shared namespace', NULL),
 ('00000000-0000-0000-0000-000000000102', 'global', 'private namespace', 'owner'),
 ('00000000-0000-0000-0000-000000000103', 'global-reasoning', 'private reasoning', 'owner');
INSERT INTO mcp_servers (uuid, name, description, command, args, env, user_id) VALUES
 ('00000000-0000-0000-0000-000000000201', 'fetch', 'manual fetch', 'custom-fetch', ARRAY['--manual'], '{\"custom\":\"keep\"}', NULL),
 ('00000000-0000-0000-0000-000000000202', 'manual-server', 'manual server', 'custom-server', ARRAY[]::text[], '{}', NULL),
 ('00000000-0000-0000-0000-000000000203', 'neo4j-global', 'private server', 'private-command', ARRAY[]::text[], '{\"secret\":\"private\"}', 'owner');
INSERT INTO namespace_server_mappings (uuid, namespace_uuid, mcp_server_uuid, status) VALUES
 ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000201', 'INACTIVE'),
 ('00000000-0000-0000-0000-000000000302', '00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000202', 'ACTIVE'),
 ('00000000-0000-0000-0000-000000000303', '00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000203', 'ACTIVE');
INSERT INTO endpoints (uuid, name, description, namespace_uuid, enable_api_key_auth, user_id) VALUES
 ('00000000-0000-0000-0000-000000000401', 'global-sse', 'private manual endpoint', '00000000-0000-0000-0000-000000000102', false, 'owner');
INSERT INTO tools (uuid, mcp_server_uuid, name) VALUES ('00000000-0000-0000-0000-000000000501', '00000000-0000-0000-0000-000000000202', 'manual-tool');
INSERT INTO namespace_tool_mappings (namespace_uuid, tool_uuid, mcp_server_uuid, status) VALUES ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000501', '00000000-0000-0000-0000-000000000202', 'INACTIVE');" >/dev/null
if ! bash "$ROOT/linux/install-global.sh" > "$TMP/manual.out" 2>&1; then
    cat "$TMP/manual.out" >&2; fail 'installation with existing configuration failed'
fi
cmp -s "$TMP/env-before" "$HOME/mcp-global/metamcp/.env" || fail 'existing MetaMCP .env changed'
cmp -s "$TMP/override-before" "$HOME/mcp-global/metamcp/docker-compose.override.yml" || fail 'existing Compose override changed'
cmp -s "$TMP/global-env-before" "$HOME/mcp-global/config/.env" || fail 'existing kit .env changed'
assert_contains "$MOCK_LOG" 'network create mcp-net' 'legacy external network is recreated if missing'
assert_contains "$TMP/manual.out" 'Endpoint (global-sse) уже используется' 'endpoint collision reported'
assert_eq 'manual fetch|custom-fetch|--manual|keep' "$(query "SELECT description||'|'||command||'|'||args[1]||'|'||(env->>'custom') FROM mcp_servers WHERE uuid='00000000-0000-0000-0000-000000000201'")" 'public server settings preserved'
assert_eq INACTIVE "$(query "SELECT status FROM namespace_server_mappings WHERE uuid='00000000-0000-0000-0000-000000000301'")" 'inactive mapping remains inactive'
assert_eq 1 "$(query "SELECT count(*) FROM namespace_server_mappings WHERE uuid='00000000-0000-0000-0000-000000000302'")" 'manual mapping survives'
assert_eq INACTIVE "$(query 'SELECT status FROM namespace_tool_mappings')" 'manual tool setting survives'
assert_eq 'private manual endpoint|00000000-0000-0000-0000-000000000102|false|owner' "$(query "SELECT description||'|'||namespace_uuid||'|'||enable_api_key_auth||'|'||user_id FROM endpoints WHERE name='global-sse'")" 'endpoint is not redirected or modified'
assert_eq 0 "$(query "SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE n.user_id IS NULL AND s.user_id IS NOT NULL")" 'private servers never enter public namespaces'
assert_eq 2 "$(query "SELECT count(*) FROM mcp_servers WHERE name='neo4j-global'")" 'private and public servers with same name coexist'
assert_eq 2 "$(query "SELECT count(*) FROM namespaces WHERE name='global-reasoning'")" 'private and public namespaces with same name coexist'
assert_eq 'custom-user' "$(query "SELECT env->>'NEO4J_USERNAME' FROM mcp_servers WHERE name='neo4j-global' AND user_id IS NULL")" 'custom Neo4j user'
assert_eq "pa\$\$word' with spaces; SELECT pg_sleep(99); --" "$(query "SELECT env->>'NEO4J_PASSWORD' FROM mcp_servers WHERE name='neo4j-global' AND user_id IS NULL")" 'unsafe-looking password is data, not SQL'
assert_eq 'bolt://host.docker.internal:9767' "$(cat "$MOCK_STATE/graphiti-uri")" 'Graphiti gets container-compatible Neo4j address'
assert_eq 'custom-user' "$(cat "$MOCK_STATE/graphiti-user")" 'Graphiti gets configured Neo4j user'
assert_eq "pa\$\$word' with spaces; SELECT pg_sleep(99); --" "$(cat "$MOCK_STATE/graphiti-password")" 'Graphiti gets the exact password'
assert_eq 'graphiti-specific-secret' "$(cat "$MOCK_STATE/graphiti-openai")" 'Graphiti gets its per-service API key instead of the legacy shared key'
assert_eq 'https://graphiti.example.test/v1' "$(cat "$MOCK_STATE/graphiti-base-url")" 'Graphiti gets its custom OpenAI-compatible base URL'
assert_eq 'cognee-llm-secret' "$(cat "$MOCK_STATE/cognee-llm")" 'Cognee gets its independent LLM key'
assert_eq 'https://llm.example.test/v1' "$(cat "$MOCK_STATE/cognee-llm-endpoint")" 'Cognee gets its independent LLM endpoint'
assert_eq 'cognee-embedding-secret' "$(cat "$MOCK_STATE/cognee-embedding")" 'Cognee gets its independent embedding key'
assert_eq 'https://embeddings.example.test/v1' "$(cat "$MOCK_STATE/cognee-embedding-endpoint")" 'Cognee gets its independent embedding endpoint'
assert_eq "github-secret-\$quoted" "$(query "SELECT bearer_token FROM mcp_servers WHERE name='github-mcp-server'")" 'GitHub bearer token encoded safely'
assert_eq "context-secret-\$quoted" "$(query "SELECT env->>'CONTEXT7_API_KEY' FROM mcp_servers WHERE name='context7'")" 'Context7 key encoded safely'
assert_eq 'https://qdrant.example.test:443|key-with-"quotes"' "$(query "SELECT (env->>'QDRANT_URL')||'|'||(env->>'QDRANT_API_KEY') FROM mcp_servers WHERE name='qdrant-global' AND user_id IS NULL")" 'custom Qdrant settings'
assert_not_contains "$TMP/manual.out" "github-secret-\$quoted" 'secrets must not be logged'
assert_not_contains "$TMP/manual.out" "openai-secret-\$quoted" 'sidecar secrets must not be logged'
assert_not_contains "$MOCK_LOG" 'cognee-llm-secret' 'sidecar secrets must not be Docker CLI arguments'

query "DELETE FROM mcp_servers WHERE name='qdrant-global' AND user_id IS NULL; DELETE FROM mcp_servers WHERE name='mcp-compass' AND user_id IS NULL; DELETE FROM namespace_server_mappings WHERE mcp_server_uuid=(SELECT uuid FROM mcp_servers WHERE name='playwright' AND user_id IS NULL); UPDATE mcp_servers SET description='edited after install' WHERE name='neo4j-global' AND user_id IS NULL;" >/dev/null
: > "$MOCK_LOG"
bash "$ROOT/linux/run-global.sh" restart > "$TMP/restart.out" 2>&1 || { cat "$TMP/restart.out" >&2; fail 'restart failed'; }
assert_contains "$TMP/restart.out" 'Первоначальная регистрация уже выполнена' 'automatic restart skips V2'
assert_not_contains "$MOCK_LOG" 'compose down' 'restart does not remove containers'
assert_eq 0 "$(query "SELECT count(*) FROM mcp_servers WHERE name IN ('qdrant-global','mcp-compass') AND user_id IS NULL")" 'deleted old and new servers stay deleted'
assert_eq 0 "$(query "SELECT count(*) FROM namespace_server_mappings m JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE s.name='playwright' AND m.namespace_uuid='00000000-0000-0000-0000-000000000101'")" 'deleted mapping stays deleted'
bash "$ROOT/linux/install-global.sh" > "$TMP/reinstall.out" 2>&1 || { cat "$TMP/reinstall.out" >&2; fail 'reinstall failed'; }
cmp -s "$TMP/env-before" "$HOME/mcp-global/metamcp/.env" || fail 'reinstall changed MetaMCP .env'
assert_eq 0 "$(query "SELECT count(*) FROM mcp_servers WHERE name='mcp-compass' AND user_id IS NULL")" 'reinstall preserves deletion'
bash "$ROOT/linux/run-global.sh" seed > "$TMP/seed.out" 2>&1 || { cat "$TMP/seed.out" >&2; fail 'explicit seed failed'; }
assert_eq 2 "$(query "SELECT count(*) FROM mcp_servers WHERE name IN ('qdrant-global','mcp-compass') AND user_id IS NULL")" 'explicit seed restores missing servers'
assert_eq 1 "$(query "SELECT count(*) FROM namespace_server_mappings m JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE s.name='playwright' AND m.namespace_uuid='00000000-0000-0000-0000-000000000101'")" 'explicit seed restores missing mapping'
assert_eq 'edited after install' "$(query "SELECT description FROM mcp_servers WHERE name='neo4j-global' AND user_id IS NULL")" 'explicit seed never overwrites edits'
assert_eq INACTIVE "$(query "SELECT status FROM namespace_server_mappings WHERE uuid='00000000-0000-0000-0000-000000000301'")" 'explicit seed never reactivates mappings'
printf 'ok - existing data, ownership, collisions, secrets and intentional deletions\n'

# An automatic V1->V2 upgrade adds the missing groups without restoring old
# deletions or bypassing a disabled fetch mapping through the new web endpoint.
reset_db
prepare_existing
query "
INSERT INTO config (id,value) VALUES ('MULTFINITE_MCP_KIT_GLOBAL_SEED_V1','complete');
INSERT INTO namespaces (uuid,name,description) VALUES ('00000000-0000-0000-0000-000000000101','global','edited global');
INSERT INTO mcp_servers (uuid,name,description,command) VALUES
 ('00000000-0000-0000-0000-000000000201','neo4j-global','edited neo4j','my-neo4j'),
 ('00000000-0000-0000-0000-000000000202','fetch','edited fetch','my-fetch'),
 ('00000000-0000-0000-0000-000000000204','fetch','second fetch','other-fetch');
INSERT INTO namespace_server_mappings (namespace_uuid,mcp_server_uuid,status) VALUES
 ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000201','ACTIVE'),
 ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000202','INACTIVE'),
 ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000204','ACTIVE');
INSERT INTO endpoints (name,description,namespace_uuid,enable_api_key_auth) VALUES ('global-sse','edited endpoint','00000000-0000-0000-0000-000000000101',true);" >/dev/null
bash "$ROOT/linux/run-global.sh" start > "$TMP/upgrade.out" 2>&1 || { cat "$TMP/upgrade.out" >&2; fail 'V1 upgrade failed'; }
assert_eq 10 "$(query "SELECT count(*) FROM mcp_servers WHERE name IN ('sequentialthinking','graphiti','cognee','memory-bank-mcp','context7','duckduckgo','github-mcp-server','io-draw','mcp-compass','gdrive')")" 'V1 upgrade adds ten new servers'
assert_eq 0 "$(query "SELECT count(*) FROM mcp_servers WHERE name IN ('qdrant-global','playwright')")" 'V1 deletions remain deleted'
assert_eq 3 "$(query "SELECT count(*) FROM namespace_server_mappings WHERE namespace_uuid='00000000-0000-0000-0000-000000000101'")" 'old namespace mappings and duplicate public records remain unchanged'
assert_eq INACTIVE "$(query "SELECT status FROM namespace_server_mappings WHERE mcp_server_uuid='00000000-0000-0000-0000-000000000202'")" 'disabled fetch remains disabled'
assert_eq 0 "$(query "SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE n.name='global-web' AND s.name='fetch'")" 'new web endpoint does not bypass disabled V1 fetch'
assert_eq 'edited neo4j|my-neo4j' "$(query "SELECT description||'|'||command FROM mcp_servers WHERE name='neo4j-global'")" 'edited V1 server preserved'
assert_eq 'edited endpoint|00000000-0000-0000-0000-000000000101|true' "$(query "SELECT description||'|'||namespace_uuid||'|'||enable_api_key_auth FROM endpoints WHERE name='global-sse'")" 'edited V1 endpoint preserved'
assert_eq 1 "$(query "SELECT count(*) FROM config WHERE id='MULTFINITE_MCP_KIT_GLOBAL_SEED_V2'")" 'V2 marker written on upgrade'
bash "$ROOT/linux/run-global.sh" seed > "$TMP/upgrade-seed.out" 2>&1 || { cat "$TMP/upgrade-seed.out" >&2; fail 'explicit upgrade seed failed'; }
assert_eq 2 "$(query "SELECT count(*) FROM mcp_servers WHERE name IN ('qdrant-global','playwright')")" 'explicit seed may restore V1 deletions'
assert_eq INACTIVE "$(query "SELECT status FROM namespace_server_mappings WHERE mcp_server_uuid='00000000-0000-0000-0000-000000000202' AND namespace_uuid='00000000-0000-0000-0000-000000000101'")" 'explicit seed still preserves inactive V1 mapping'
printf 'ok - safe V1 upgrade and explicit restoration\n'

reset_db
prepare_existing
query "INSERT INTO config (id,value) VALUES ('MULTFINITE_MCP_KIT_GLOBAL_SEED_V1','complete');" >/dev/null
bash "$ROOT/linux/run-global.sh" start > "$TMP/upgrade-deleted.out" 2>&1 || { cat "$TMP/upgrade-deleted.out" >&2; fail 'upgrade with deleted namespace failed'; }
assert_eq 0 "$(query "SELECT count(*) FROM mcp_servers WHERE name IN ('neo4j-global','qdrant-global','fetch','playwright')")" 'deleted V1 servers are not re-created on upgrade'
assert_eq 0 "$(query "SELECT count(*) FROM namespaces WHERE name='global'")" 'deleted V1 namespace is not re-created on upgrade'
assert_eq 0 "$(query "SELECT count(*) FROM endpoints WHERE name='global-sse'")" 'deleted V1 endpoint is not re-created on upgrade'
printf 'ok - V1 namespace and server deletions survive upgrade\n'

reset_db
prepare_existing
query "
INSERT INTO config (id,value) VALUES ('MULTFINITE_MCP_KIT_GLOBAL_SEED_V1','complete');
INSERT INTO namespaces (uuid,name) VALUES ('00000000-0000-0000-0000-000000000101','global');
INSERT INTO mcp_servers (uuid,name,command) VALUES ('00000000-0000-0000-0000-000000000201','fetch','uvx');
INSERT INTO namespace_server_mappings (namespace_uuid,mcp_server_uuid,status) VALUES ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000201','ACTIVE');" >/dev/null
bash "$ROOT/linux/run-global.sh" start > "$TMP/upgrade-active.out" 2>&1 || { cat "$TMP/upgrade-active.out" >&2; fail 'upgrade with active fetch failed'; }
assert_eq 1 "$(query "SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid WHERE n.name='global-web' AND m.mcp_server_uuid='00000000-0000-0000-0000-000000000201' AND m.status='ACTIVE'")" 'active V1 fetch is linked to the web group'
printf 'ok - active V1 fetch is included in the web namespace\n'

# If a namespace has any open endpoint, do not silently add tools there, even
# if another endpoint is protected. Other namespaces can still be seeded.
reset_db
prepare_existing
query "
INSERT INTO users VALUES ('owner');
INSERT INTO namespaces (uuid,name,user_id) VALUES ('00000000-0000-0000-0000-000000000101','global-memory',NULL), ('00000000-0000-0000-0000-000000000102','private-web','owner');
INSERT INTO mcp_servers (uuid,name,command) VALUES ('00000000-0000-0000-0000-000000000201','manual-server','manual');
INSERT INTO namespace_server_mappings (namespace_uuid,mcp_server_uuid,status) VALUES ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000201','INACTIVE');
INSERT INTO endpoints (name,namespace_uuid,enable_api_key_auth,enable_oauth,user_id) VALUES
 ('manual-open','00000000-0000-0000-0000-000000000101',false,false,NULL),
 ('manual-protected','00000000-0000-0000-0000-000000000101',true,false,NULL),
 ('global-web','00000000-0000-0000-0000-000000000102',true,false,'owner');" >/dev/null
bash "$ROOT/linux/run-global.sh" start > "$TMP/unprotected.out" 2>&1 || { cat "$TMP/unprotected.out" >&2; fail 'registration with open endpoint failed'; }
assert_contains "$TMP/unprotected.out" 'global-memory) есть endpoint без аутентификации' 'unprotected namespace reported'
assert_contains "$TMP/unprotected.out" 'Endpoint (global-web) уже используется' 'simultaneous endpoint conflict also reported'
assert_eq '00000000-0000-0000-0000-000000000102|owner' "$(query "SELECT namespace_uuid||'|'||user_id FROM endpoints WHERE name='global-web'")" 'colliding endpoint remains private and unchanged'
assert_eq 14 "$(query "SELECT count(*) FROM mcp_servers WHERE name <> 'manual-server'")" 'servers are still registered'
assert_eq 1 "$(query "SELECT count(*) FROM namespace_server_mappings WHERE namespace_uuid='00000000-0000-0000-0000-000000000101'")" 'open namespace gains no mappings'
assert_eq 0 "$(query "SELECT count(*) FROM endpoints WHERE name='global-memory'")" 'do not add an endpoint to the open namespace'
assert_eq 12 "$(query "SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid WHERE n.name <> 'global-memory'")" 'other protected groups are seeded'
query "UPDATE endpoints SET enable_api_key_auth=true WHERE name='manual-open'" >/dev/null
bash "$ROOT/linux/run-global.sh" seed > "$TMP/protected.out" 2>&1 || { cat "$TMP/protected.out" >&2; fail 'protected retry failed'; }
assert_eq 4 "$(query "SELECT count(*) FROM namespace_server_mappings WHERE namespace_uuid='00000000-0000-0000-0000-000000000101'")" 'explicit seed links memory servers after protection'
assert_eq INACTIVE "$(query "SELECT status FROM namespace_server_mappings WHERE mcp_server_uuid='00000000-0000-0000-0000-000000000201'")" 'manual inactive mapping remains unchanged'
assert_eq 1 "$(query "SELECT count(*) FROM endpoints WHERE name='global-memory' AND enable_api_key_auth")" 'protected endpoint created on explicit retry'
printf 'ok - open endpoints do not expose newly linked tools\n'

# The old shared key is ignored; only explicit service-specific keys count.
reset_db
prepare_existing
cat >> "$HOME/mcp-global/config/.env" <<'EOF'
OPENAI_API_KEY=legacy-shared-secret
GITHUB_PERSONAL_ACCESS_TOKEN=ghp_your_token_here
EOF
bash "$ROOT/linux/run-global.sh" start > "$TMP/placeholders.out" 2>&1 || { cat "$TMP/placeholders.out" >&2; fail 'legacy shared key caused startup failure'; }
assert_eq '' "$(cat "$MOCK_STATE/graphiti-openai")" 'legacy shared OpenAI key is not passed to Graphiti'
assert_eq '' "$(cat "$MOCK_STATE/cognee-llm")" 'legacy shared key is not passed to Cognee LLM'
assert_eq '' "$(cat "$MOCK_STATE/cognee-embedding")" 'legacy shared key is not passed to Cognee embeddings'
assert_eq t "$(query "SELECT bearer_token IS NULL FROM mcp_servers WHERE name='github-mcp-server'")" 'example GitHub token is not stored as a real credential'
printf 'ok - legacy shared key and placeholder credentials are ignored\n'

# Failure rolls back every database change and does not start sidecars.
reset_db
prepare_home
query "ALTER TABLE mcp_servers ADD CONSTRAINT reject_qdrant CHECK (name <> 'qdrant-global'); INSERT INTO mcp_servers (name,command) VALUES ('manual-server','manual-command');" >/dev/null
if bash "$ROOT/linux/install-global.sh" > "$TMP/failure.out" 2>&1; then fail 'SQL error reported as success'; fi
assert_contains "$TMP/failure.out" 'Не удалось подтвердить регистрацию' 'SQL error explained'
assert_not_contains "$TMP/failure.out" 'ГЛОБАЛЬНЫЙ СТЕК УСТАНОВЛЕН И ЗАПУЩЕН' 'installer does not claim success after rollback'
assert_not_contains "$MOCK_LOG" 'compose -p multfinite-mcp-kit-global -f ' 'sidecars not started when transaction fails'
assert_eq 1 "$(query 'SELECT count(*) FROM mcp_servers')" 'failed transaction rolls back servers'
assert_eq 0 "$(query 'SELECT count(*) FROM namespaces')" 'failed transaction rolls back namespaces'
assert_eq 0 "$(query "SELECT count(*) FROM config WHERE id LIKE 'MULTFINITE_MCP_KIT_GLOBAL_SEED_%'")" 'failure writes no marker'
query 'ALTER TABLE mcp_servers DROP CONSTRAINT reject_qdrant' >/dev/null
bash "$ROOT/linux/run-global.sh" start > "$TMP/retry.out" 2>&1 || { cat "$TMP/retry.out" >&2; fail 'retry after rollback failed'; }
assert_eq 14 "$(query "SELECT count(*) FROM mcp_servers WHERE name <> 'manual-server'")" 'retry registers all defaults'
assert_eq 1 "$(query "SELECT count(*) FROM mcp_servers WHERE name='manual-server'")" 'manual record survives'
printf 'ok - transaction rollback and retry\n'

# A sidecar build/pull/connect failure is surfaced, not reported as a complete
# installation. Committed registry entries remain safe for a subsequent retry.
reset_db
prepare_home
export MOCK_SERVICES_FAIL=1
if bash "$ROOT/linux/install-global.sh" > "$TMP/sidecar-fail.out" 2>&1; then fail 'failed sidecar startup reported as success'; fi
unset MOCK_SERVICES_FAIL
assert_contains "$TMP/sidecar-fail.out" 'Дополнительные MCP-сервисы не запущены' 'sidecar failure explained'
assert_not_contains "$TMP/sidecar-fail.out" 'ГЛОБАЛЬНЫЙ СТЕК УСТАНОВЛЕН И ЗАПУЩЕН' 'no success banner when sidecars fail'
assert_eq 14 "$(query 'SELECT count(*) FROM mcp_servers')" 'successful seed is retained after sidecar failure'
bash "$ROOT/linux/run-global.sh" start > "$TMP/sidecar-retry.out" 2>&1 || { cat "$TMP/sidecar-retry.out" >&2; fail 'sidecar retry failed'; }
assert_contains "$TMP/sidecar-retry.out" 'Первоначальная регистрация уже выполнена' 'retry does not overwrite DB'
assert_eq 4 "$(find "$MOCK_STATE" -name 'attached-*' | wc -l | tr -d ' ')" 'retry connects all networks'
printf 'ok - sidecar failure and retry\n'

reset_db
prepare_existing
export MOCK_CONNECT_FAIL=1
if bash "$ROOT/linux/run-global.sh" start > "$TMP/connect-fail.out" 2>&1; then fail 'failed app network attachment reported as success'; fi
unset MOCK_CONNECT_FAIL
assert_contains "$TMP/connect-fail.out" 'Не удалось подключить MetaMCP к сети' 'network attachment failure explained'
assert_eq 14 "$(query 'SELECT count(*) FROM mcp_servers')" 'network failure preserves committed registry entries'
bash "$ROOT/linux/run-global.sh" start > "$TMP/connect-retry.out" 2>&1 || { cat "$TMP/connect-retry.out" >&2; fail 'network attachment retry failed'; }
assert_eq 4 "$(find "$MOCK_STATE" -name 'attached-*' | wc -l | tr -d ' ')" 'retry attaches all sidecar networks'
printf 'ok - network attachment failure and retry\n'

reset_db
prepare_existing
echo 'manual-project' > "$MOCK_STATE/network-multfinite-mcp-kit-global-graphiti"
if bash "$ROOT/linux/run-global.sh" start > "$TMP/collision.out" 2>&1; then fail 'foreign Docker network was adopted'; fi
assert_contains "$TMP/collision.out" 'не принадлежит проекту' 'foreign Docker resource is reported'
assert_eq 'manual-project' "$(cat "$MOCK_STATE/network-multfinite-mcp-kit-global-graphiti")" 'foreign network was not modified'
assert_not_contains "$MOCK_LOG" 'compose -p multfinite-mcp-kit-global -f ' 'service project did not start after network collision'
printf 'ok - foreign Docker resources are not adopted\n'

reset_db
prepare_existing
echo 'manual-project' > "$MOCK_STATE/volume-multfinite-mcp-kit-global-memory-data"
if bash "$ROOT/linux/run-global.sh" start > "$TMP/volume-collision.out" 2>&1; then fail 'foreign Docker volume was adopted'; fi
assert_contains "$TMP/volume-collision.out" 'не принадлежит проекту' 'foreign volume is reported'
assert_eq 'manual-project' "$(cat "$MOCK_STATE/volume-multfinite-mcp-kit-global-memory-data")" 'foreign volume was not modified'
printf 'ok - foreign Docker volumes are not adopted\n'

# Applying changed provider settings is explicit and recreates only the two
# kit-owned provider containers. It must not recreate app or delete volumes.
reset_db
prepare_existing
printf '\nLLM_API_KEY=global-provider-key\nLLM_API_ENDPOINT=https://global-gateway.example/v1\nLLM_API_MODEL=global-chat-model\nLLM_API_PROVIDER=global-provider\n' >> "$HOME/mcp-global/config/.env"
bash "$ROOT/linux/run-global.sh" start > "$TMP/provider-start.out" 2>&1 || { cat "$TMP/provider-start.out" >&2; fail 'provider start failed'; }
assert_eq global-provider-key "$(cat "$MOCK_STATE/graphiti-openai")" 'global LLM key is Graphiti default'
assert_eq https://global-gateway.example/v1 "$(cat "$MOCK_STATE/graphiti-base-url")" 'global LLM endpoint is Graphiti default'
assert_eq global-provider-key "$(cat "$MOCK_STATE/cognee-llm")" 'global LLM key is Cognee LLM default'
assert_eq global-provider-key "$(cat "$MOCK_STATE/cognee-embedding")" 'global API key is Cognee embedding default'
assert_eq global-chat-model "$(cat "$MOCK_STATE/cognee-llm-model")" 'global model is Cognee LLM default'
assert_eq global-provider "$(cat "$MOCK_STATE/cognee-llm-provider")" 'global provider is Cognee LLM default'
assert_eq https://global-gateway.example/v1 "$(cat "$MOCK_STATE/cognee-embedding-endpoint")" 'global endpoint is Cognee embedding default'
printf '\nGRAPHITI_API_KEY=graphiti-updated-key\nGRAPHITI_API_ENDPOINT=https://graphiti-gateway.example/v1\nGRAPHITI_API_MODEL=graphiti-chat-model\nCOGNEE_LLM_API_KEY=llm-updated-key\nCOGNEE_LLM_API_ENDPOINT=https://llm-gateway.example/v1\nCOGNEE_LLM_API_MODEL=cognee-chat-model\nCOGNEE_LLM_API_PROVIDER=cognee-provider\nCOGNEE_EMBEDDING_API_KEY=embedding-updated-key\nCOGNEE_EMBEDDING_API_ENDPOINT=https://embedding-gateway.example/v1\nCOGNEE_EMBEDDING_API_MODEL=embedding-specific-model\nCOGNEE_EMBEDDING_API_PROVIDER=embedding-provider\nNEO4J_DATABASE=separate-graph\nGRAPHITI_GROUP_ID=custom-group\n' >> "$HOME/mcp-global/config/.env"
: > "$MOCK_LOG"
bash "$ROOT/linux/run-global.sh" apply-services > "$TMP/provider-apply.out" 2>&1 || { cat "$TMP/provider-apply.out" >&2; fail 'provider apply failed'; }
assert_contains "$MOCK_LOG" 'up -d --no-deps --force-recreate mcpkit-graphiti mcpkit-cognee' 'only provider services are explicitly recreated'
assert_not_contains "$MOCK_LOG" 'compose up ' 'MetaMCP is not recreated by provider apply'
assert_not_contains "$MOCK_LOG" 'volume rm' 'provider apply never removes persistent volumes'
assert_eq graphiti-updated-key "$(cat "$MOCK_STATE/graphiti-openai")" 'Graphiti API key is configured independently'
assert_eq https://graphiti-gateway.example/v1 "$(cat "$MOCK_STATE/graphiti-base-url")" 'Graphiti base URL can be changed independently'
assert_eq https://llm-gateway.example/v1 "$(cat "$MOCK_STATE/cognee-llm-endpoint")" 'Cognee LLM endpoint reaches its own client'
assert_eq https://embedding-gateway.example/v1 "$(cat "$MOCK_STATE/cognee-embedding-endpoint")" 'Cognee embedding endpoint reaches its own client'
assert_eq graphiti-chat-model "$(cat "$MOCK_STATE/graphiti-model")" 'Graphiti model can override the global model'
assert_eq cognee-chat-model "$(cat "$MOCK_STATE/cognee-llm-model")" 'Cognee LLM model can override the global model'
assert_eq cognee-provider "$(cat "$MOCK_STATE/cognee-llm-provider")" 'Cognee LLM provider can override the global provider'
assert_eq embedding-specific-model "$(cat "$MOCK_STATE/cognee-embedding-model")" 'Cognee embedding model remains specific'
assert_eq embedding-provider "$(cat "$MOCK_STATE/cognee-embedding-provider")" 'Cognee embedding provider can be set independently'
assert_eq separate-graph "$(cat "$MOCK_STATE/graphiti-database")" 'Graphiti database override is passed to Compose'
assert_eq custom-group "$(cat "$MOCK_STATE/graphiti-group")" 'Graphiti group override is passed to Compose'
assert_eq llm-updated-key "$(cat "$MOCK_STATE/cognee-llm")" 'Cognee LLM key is configured independently'
assert_eq embedding-updated-key "$(cat "$MOCK_STATE/cognee-embedding")" 'Cognee embedding key is configured independently'
: > "$MOCK_LOG"
bash "$ROOT/linux/run-global.sh" stop > "$TMP/provider-stop.out" 2>&1 || { cat "$TMP/provider-stop.out" >&2; fail 'stop failed'; }
assert_contains "$MOCK_LOG" 'compose stop' 'stop preserves MetaMCP container writable layer'
assert_not_contains "$MOCK_LOG" 'compose down' 'stop must not remove MetaMCP containers'
assert_not_contains "$MOCK_LOG" 'volume rm' 'stop never removes persistent volumes'
printf 'ok - explicit provider configuration update and non-destructive stop\n'

# APP_URL values in the kit .env are synced into MetaMCP and explicitly applied
# by recreating only the app container; public and frontend URLs stay aligned.
reset_db
prepare_existing
bash "$ROOT/linux/run-global.sh" start > "$TMP/url-start.out" 2>&1 || { cat "$TMP/url-start.out" >&2; fail 'URL setup start failed'; }
printf '\nAPP_URL=https://mcp.example.test\n' >> "$HOME/mcp-global/config/.env"
: > "$MOCK_LOG"
bash "$ROOT/linux/run-global.sh" apply-metamcp-config > "$TMP/url-apply.out" 2>&1 || { cat "$TMP/url-apply.out" >&2; fail 'MetaMCP URL apply failed'; }
assert_contains "$HOME/mcp-global/metamcp/.env" 'APP_URL=https://mcp.example.test' 'kit APP_URL reaches MetaMCP dotenv'
assert_contains "$HOME/mcp-global/metamcp/.env" 'NEXT_PUBLIC_APP_URL=https://mcp.example.test' 'frontend URL follows APP_URL when omitted'
assert_contains "$MOCK_LOG" 'compose up -d --no-deps --force-recreate app' 'URL update explicitly recreates only app'
assert_contains "$TMP/url-apply.out" 'APP_URL и NEXT_PUBLIC_APP_URL применены' 'URL update reports success'
# A normal start must also sync a later URL edit and recreate only app.
printf '\nAPP_URL=https://mcp-auto.example.test\n' >> "$HOME/mcp-global/config/.env"
export MOCK_UV_CACHE_BAD=1
: > "$MOCK_LOG"
bash "$ROOT/linux/run-global.sh" start > "$TMP/url-start-auto.out" 2>&1 || { cat "$TMP/url-start-auto.out" >&2; fail 'automatic URL sync on start failed'; }
[ -f "$MOCK_STATE/uv-cache-repaired" ] || fail 'root-owned uv cache is repaired before app start'
unset MOCK_UV_CACHE_BAD
assert_contains "$HOME/mcp-global/metamcp/.env" 'APP_URL=https://mcp-auto.example.test' 'normal start syncs kit APP_URL automatically'
assert_contains "$HOME/mcp-global/metamcp/.env" 'NEXT_PUBLIC_APP_URL=https://mcp-auto.example.test' 'normal start syncs frontend URL automatically'
assert_contains "$MOCK_STATE/app-env" 'APP_URL=https://mcp-auto.example.test' 'recreated app receives APP_URL in its container environment'
assert_contains "$MOCK_STATE/app-env" 'NEXT_PUBLIC_APP_URL=https://mcp-auto.example.test' 'recreated app receives NEXT_PUBLIC_APP_URL in its container environment'
assert_contains "$MOCK_LOG" 'up -d --no-deps --force-recreate app' 'normal start recreates app only when runtime URL differs'
# Even if the host dotenv already matches, repair an app container with stale env.
printf 'APP_URL=http://localhost:12008\nNEXT_PUBLIC_APP_URL=http://localhost:12008\n' > "$MOCK_STATE/app-env"
: > "$MOCK_LOG"
bash "$ROOT/linux/run-global.sh" start > "$TMP/url-start-stale-container.out" 2>&1 || { cat "$TMP/url-start-stale-container.out" >&2; fail 'stale container URL repair failed'; }
assert_contains "$MOCK_LOG" 'up -d --no-deps --force-recreate app' 'start recreates app if its runtime env is stale even when dotenv matches'
assert_contains "$MOCK_STATE/app-env" 'APP_URL=https://mcp-auto.example.test' 'stale container receives current APP_URL'
printf 'ok - public URL sync and automatic runtime environment repair on start\n'

# A pre-created kit .env also supplies the public address when the installer
# creates MetaMCP's .env for the first time.
reset_db
prepare_home
cat > "$HOME/mcp-global/config/.env" <<'EOF'
APP_URL=https://initial.example.test
EOF
bash "$ROOT/linux/install-global.sh" > "$TMP/initial-url-install.out" 2>&1 || { cat "$TMP/initial-url-install.out" >&2; fail 'install with preconfigured APP_URL failed'; }
assert_contains "$HOME/mcp-global/metamcp/.env" 'APP_URL=https://initial.example.test' 'installer seeds APP_URL from pre-existing kit config'
assert_contains "$HOME/mcp-global/metamcp/.env" 'NEXT_PUBLIC_APP_URL=https://initial.example.test' 'installer aligns frontend URL with APP_URL'
assert_not_contains "$HOME/mcp-global/config/.env" "$(printf '\033')" 'installer template does not expand comments as shell commands'
assert_not_contains "$MOCK_LOG" 'force-recreate app' 'installer template generation does not execute documented commands'
printf 'ok - initial installer carries the configured public origin without executing template comments\n'

reset_db
prepare_existing
export MOCK_HEALTH_ALWAYS_FAIL=1 METAMCP_START_TIMEOUT=0
if bash "$ROOT/linux/run-global.sh" start > "$TMP/timeout.out" 2>&1; then fail 'health timeout reported as success'; fi
unset MOCK_HEALTH_ALWAYS_FAIL
export METAMCP_START_TIMEOUT=4
assert_contains "$TMP/timeout.out" 'MetaMCP не запустился' 'health timeout explained'
assert_eq 0 "$(query 'SELECT count(*) FROM mcp_servers')" 'timeout never seeds before migrations'
printf 'ok - bounded readiness timeout\n'

reset_db
prepare_existing
bash "$ROOT/linux/run-global.sh" seed > "$TMP/concurrent-1.out" 2>&1 & pid1=$!
bash "$ROOT/linux/run-global.sh" seed > "$TMP/concurrent-2.out" 2>&1 & pid2=$!
wait "$pid1" || { cat "$TMP/concurrent-1.out" >&2; fail 'first concurrent seed failed'; }
wait "$pid2" || { cat "$TMP/concurrent-2.out" >&2; fail 'second concurrent seed failed'; }
assert_eq 14 "$(query 'SELECT count(*) FROM mcp_servers WHERE user_id IS NULL')" 'concurrent seeds create no duplicate servers'
assert_eq 5 "$(query 'SELECT count(*) FROM namespaces WHERE user_id IS NULL')" 'concurrent seeds create no duplicate namespaces'
assert_eq 15 "$(query 'SELECT count(*) FROM namespace_server_mappings')" 'concurrent seeds create no duplicate mappings'
assert_eq 5 "$(query 'SELECT count(*) FROM endpoints')" 'concurrent seeds create no duplicate endpoints'
printf 'ok - concurrent seed transactions\n'

# Static deployment invariants supplement the mocked Docker boundary.
assert_not_contains "$ROOT/linux/services/docker-compose.yml" 'ports:' 'sidecars must not publish host ports'
assert_eq 4 "$(grep -c 'restart: unless-stopped' "$ROOT/linux/services/docker-compose.yml")" 'all sidecars restart after transient failures'
for mount in 'cognee_system:/cognee-storage/system' 'cognee_data:/cognee-storage/data' 'memory_data:/mcpkit/memory' 'gdrive_data:/mcpkit/gdrive'; do
    assert_contains "$ROOT/linux/services/docker-compose.yml" "$mount" "persistent mount $mount"
done
assert_contains "$ROOT/linux/services/docker-compose.yml" 'MCP_ALLOWED_HOSTS: "mcpkit-cognee:*"' 'Cognee DNS-rebinding allowlist accepts its service name'
assert_eq 1 "$(grep -c 'build: ./node-mcp' "$ROOT/linux/services/docker-compose.yml")" 'shared Node image has exactly one build definition'
assert_eq 2 "$(grep -c 'pull_policy: never' "$ROOT/linux/services/docker-compose.yml")" 'local Node image is built rather than pulled for both services'
assert_contains "$ROOT/linux/services/docker-compose.yml" 'depends_on: [mcpkit-memory-bank]' 'Drive waits for the service that builds the shared image'
assert_contains "$ROOT/linux/services/node-mcp/Dockerfile" '@allpepper/memory-bank-mcp@0.2.2' 'actual Memory Bank package installed'
assert_contains "$ROOT/linux/services/node-mcp/Dockerfile" '@modelcontextprotocol/server-gdrive@2025.1.14' 'actual GDrive package installed'
assert_contains "$ROOT/linux/services/docker-compose.yml" '/mcpkit/gdrive/credentials.json' 'GDrive uses persistent OAuth credentials'
printf 'ok - sidecar deployment invariants\n'
