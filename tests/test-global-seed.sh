#!/usr/bin/env bash
# Integration tests against a disposable PostgreSQL database, with Docker
# mocked at the Compose boundary. No real containers or system packages change.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
: "${TEST_DATABASE_URL:?Set TEST_DATABASE_URL to a disposable PostgreSQL database}"
command -v psql >/dev/null || { echo "psql is required" >&2; exit 1; }

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
fail() { echo "FAIL: $*" >&2; exit 1; }

# Simulate the official Compose services, but execute the real psql against the
# test database. The application container's DATABASE_URL is deliberately
# different from the kit's default PostgreSQL user, host and database.
cat > "$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$MOCK_LOG"; printf '\n' >> "$MOCK_LOG"
case "${1:-}" in
    info) exit 0 ;;
    --version) echo 'Docker test' ;;
    network)
        case "${2:-}" in
            inspect) [ -f "$MOCK_STATE/network-$3" ] ;;
            create) echo true > "$MOCK_STATE/network-$3"; echo mock-network-id ;;
            *) exit 1 ;;
        esac
        ;;
    inspect)
        if [ "${2:-}" = --format ]; then
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
    start)
        echo true > "$MOCK_STATE/container-$2"
        echo "$2"
        ;;
    stop) exit 0 ;;
    ps) printf 'metamcp\nneo4j-mcp\nqdrant-mcp\n' ;;
    compose)
        if [ "${POSTGRES_PASSWORD:-}" = must-not-override-compose ]; then
            echo 'kit .env leaked into the Compose environment' >&2
            exit 1
        fi
        shift
        case "${1:-}" in
            version) echo '2.30.0' ;;
            pull|up|down|logs) exit 0 ;;
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
                            *) echo 'seed must use the app DATABASE_URL and ON_ERROR_STOP' >&2; exit 1 ;;
                        esac
                        export DATABASE_URL="$TEST_DATABASE_URL"
                        exec sh -c "$3"
                        ;;
                    *) echo "Unexpected compose exec: $*" >&2; exit 1 ;;
                esac
                ;;
            *) echo "Unexpected compose command: $*" >&2; exit 1 ;;
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
    export HOME="$TMP/home"
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
    rm -f "$MOCK_STATE/health-count"
    : > "$MOCK_LOG"
}

# Fresh installation starts MetaMCP, waits for health/migrations, and seeds
# the actual app database using the current PostgreSQL schema.
reset_db
prepare_home
export MOCK_HEALTH_FAILURES=2 METAMCP_START_TIMEOUT=4
if ! bash "$ROOT/linux/install-global.sh" > "$TMP/install.out" 2>&1; then
    cat "$TMP/install.out" >&2; fail 'fresh installation failed'
fi
assert_eq 3 "$(cat "$MOCK_STATE/health-count")" 'startup must retry the health check'
assert_eq 4 "$(query "SELECT count(*) FROM mcp_servers WHERE user_id IS NULL AND name IN ('neo4j-global','qdrant-global','fetch','playwright')")" 'fresh install registers four public servers'
assert_eq 4 "$(query "SELECT count(*) FROM namespace_server_mappings m JOIN namespaces n ON n.uuid=m.namespace_uuid WHERE n.name='global' AND n.user_id IS NULL")" 'fresh install links all servers'
assert_eq 'STDIO|uvx|mcp-server-qdrant|http://host.docker.internal:6333' "$(query "SELECT type || '|' || command || '|' || args[1] || '|' || (env->>'QDRANT_URL') FROM mcp_servers WHERE name='qdrant-global'")" 'Qdrant package and container network URL'
assert_eq 'uvx|mcp-neo4j-cypher|bolt://host.docker.internal:7687' "$(query "SELECT command || '|' || args[1] || '|' || (env->>'NEO4J_URI') FROM mcp_servers WHERE name='neo4j-global'")" 'Neo4j package and container network URL'
assert_eq 'npx|-y|@playwright/mcp|--headless' "$(query "SELECT command || '|' || args[1] || '|' || args[2] || '|' || args[3] FROM mcp_servers WHERE name='playwright'")" 'Playwright package and headless mode'
assert_eq 'true|true' "$(query "SELECT (e.user_id IS NULL)::text || '|' || e.enable_api_key_auth::text FROM endpoints e JOIN namespaces n ON n.uuid=e.namespace_uuid WHERE e.name='global-sse' AND n.name='global'")" 'new endpoint is public and API-key protected'
assert_contains "$HOME/mcp-global/metamcp/.env" 'BOOTSTRAP_USER_PASSWORD=' 'fresh install disables upstream example password'
if grep -q '^BOOTSTRAP_USER_PASSWORD=changeme' "$HOME/mcp-global/metamcp/.env"; then fail 'example credentials were left enabled'; fi
assert_contains "$HOME/mcp-global/metamcp/.env" 'BOOTSTRAP_RECREATE_USER=false' 'fresh install must not recreate users on restart'
assert_contains "$HOME/mcp-global/metamcp/.env" '"update":false' 'fresh bootstrap must not overwrite manual changes'
assert_contains "$TMP/install.out" 'ЗАПУЩЕН' 'installer must report success after seeding'
assert_contains "$MOCK_LOG" 'compose up -d --no-recreate' 'installation must start the stack without recreating existing containers'
unset MOCK_HEALTH_FAILURES
printf 'ok - fresh installation and health retries\n'

# Existing public records are reused unchanged; private records are never
# shared, and an endpoint name collision must not redirect the user's endpoint.
reset_db
prepare_home
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
export POSTGRES_PASSWORD=must-not-override-compose
EOF
cp "$HOME/mcp-global/metamcp/.env" "$TMP/env-before"
cp "$HOME/mcp-global/metamcp/docker-compose.override.yml" "$TMP/override-before"
cp "$HOME/mcp-global/config/.env" "$TMP/global-env-before"
query "
INSERT INTO users VALUES ('owner');
INSERT INTO namespaces (uuid, name, description, user_id) VALUES
 ('00000000-0000-0000-0000-000000000101', 'global', 'manual shared namespace', NULL),
 ('00000000-0000-0000-0000-000000000102', 'global', 'private namespace', 'owner');
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
INSERT INTO tools (uuid, mcp_server_uuid, name) VALUES
 ('00000000-0000-0000-0000-000000000501', '00000000-0000-0000-0000-000000000202', 'manual-tool');
INSERT INTO namespace_tool_mappings (namespace_uuid, tool_uuid, mcp_server_uuid, status) VALUES
 ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000501', '00000000-0000-0000-0000-000000000202', 'INACTIVE');" >/dev/null

if ! bash "$ROOT/linux/install-global.sh" > "$TMP/manual.out" 2>&1; then
    cat "$TMP/manual.out" >&2; fail 'installation with existing configuration failed'
fi
cmp -s "$TMP/env-before" "$HOME/mcp-global/metamcp/.env" || fail 'existing MetaMCP .env changed'
cmp -s "$TMP/override-before" "$HOME/mcp-global/metamcp/docker-compose.override.yml" || fail 'existing Compose override changed'
cmp -s "$TMP/global-env-before" "$HOME/mcp-global/config/.env" || fail 'existing kit .env changed'
assert_contains "$MOCK_LOG" 'network create mcp-net' 'legacy external network should be recreated if missing'
assert_contains "$TMP/manual.out" 'Endpoint global-sse уже используется' 'name collision must be reported'
assert_eq 'manual fetch|custom-fetch|--manual|keep' "$(query "SELECT description || '|' || command || '|' || args[1] || '|' || (env->>'custom') FROM mcp_servers WHERE uuid='00000000-0000-0000-0000-000000000201'")" 'existing public server must not be overwritten'
assert_eq 'INACTIVE' "$(query "SELECT status FROM namespace_server_mappings WHERE uuid='00000000-0000-0000-0000-000000000301'")" 'disabled mapping must stay disabled'
assert_eq 1 "$(query "SELECT count(*) FROM namespace_server_mappings WHERE uuid='00000000-0000-0000-0000-000000000302'")" 'manual server mapping must survive'
assert_eq INACTIVE "$(query "SELECT status FROM namespace_tool_mappings")" 'manual tool mapping must survive'
assert_eq 'private manual endpoint|00000000-0000-0000-0000-000000000102|false|owner' "$(query "SELECT description || '|' || namespace_uuid || '|' || enable_api_key_auth || '|' || user_id FROM endpoints WHERE name='global-sse'")" 'existing endpoint must not be changed'
assert_eq 0 "$(query "SELECT count(*) FROM namespace_server_mappings m JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE m.namespace_uuid='00000000-0000-0000-0000-000000000101' AND s.user_id IS NOT NULL")" 'private servers must not be exposed in public namespace'
assert_eq 2 "$(query "SELECT count(*) FROM mcp_servers WHERE name='neo4j-global'")" 'private and public servers may have the same name'
assert_eq 'custom-user' "$(query "SELECT env->>'NEO4J_USERNAME' FROM mcp_servers WHERE name='neo4j-global' AND user_id IS NULL")" 'configured Neo4j user'
assert_eq "pa\$\$word' with spaces; SELECT pg_sleep(99); --" "$(query "SELECT env->>'NEO4J_PASSWORD' FROM mcp_servers WHERE name='neo4j-global' AND user_id IS NULL")" 'quoted password must be passed safely'
assert_eq 'bolt://host.docker.internal:9767' "$(query "SELECT env->>'NEO4J_URI' FROM mcp_servers WHERE name='neo4j-global' AND user_id IS NULL")" 'loopback URI must target the host'
assert_eq 'https://qdrant.example.test:443|key-with-"quotes"' "$(query "SELECT (env->>'QDRANT_URL') || '|' || (env->>'QDRANT_API_KEY') FROM mcp_servers WHERE name='qdrant-global' AND user_id IS NULL")" 'custom Qdrant URL and API key'
# shellcheck disable=SC2016 # This is a literal part of the test password.
if grep -Fq 'pa$$word' "$TMP/manual.out"; then fail 'password appeared in installation output'; fi

# Intentional removals survive automatic starts/reinstallation. Explicit seed
# adds missing defaults again, without resetting existing records or statuses.
query "DELETE FROM namespace_server_mappings WHERE mcp_server_uuid = (SELECT uuid FROM mcp_servers WHERE name='playwright' AND user_id IS NULL); DELETE FROM mcp_servers WHERE name='qdrant-global' AND user_id IS NULL; UPDATE mcp_servers SET description='edited after install' WHERE name='neo4j-global' AND user_id IS NULL;" >/dev/null
bash "$ROOT/linux/run-global.sh" start > "$TMP/restart.out" 2>&1 || { cat "$TMP/restart.out" >&2; fail 'repeat start failed'; }
assert_contains "$TMP/restart.out" 'Первоначальная регистрация уже выполнена' 'automatic repeat must skip'
assert_eq 0 "$(query "SELECT count(*) FROM mcp_servers WHERE name='qdrant-global' AND user_id IS NULL")" 'deleted server must stay deleted'
assert_eq 0 "$(query "SELECT count(*) FROM namespace_server_mappings m JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE s.name='playwright' AND m.namespace_uuid='00000000-0000-0000-0000-000000000101'")" 'removed mapping must stay removed'
bash "$ROOT/linux/install-global.sh" > "$TMP/reinstall.out" 2>&1 || { cat "$TMP/reinstall.out" >&2; fail 'repeat installation failed'; }
assert_eq 0 "$(query "SELECT count(*) FROM mcp_servers WHERE name='qdrant-global' AND user_id IS NULL")" 'reinstallation must not restore intentional deletions'
cmp -s "$TMP/env-before" "$HOME/mcp-global/metamcp/.env" || fail 'reinstallation changed the existing MetaMCP .env'
bash "$ROOT/linux/run-global.sh" seed > "$TMP/seed.out" 2>&1 || { cat "$TMP/seed.out" >&2; fail 'explicit reseed failed'; }
assert_eq 1 "$(query "SELECT count(*) FROM mcp_servers WHERE name='qdrant-global' AND user_id IS NULL")" 'explicit seed restores a missing server'
assert_eq 1 "$(query "SELECT count(*) FROM namespace_server_mappings m JOIN mcp_servers s ON s.uuid=m.mcp_server_uuid WHERE s.name='playwright' AND m.namespace_uuid='00000000-0000-0000-0000-000000000101'")" 'explicit seed restores a missing mapping'
assert_eq 'edited after install' "$(query "SELECT description FROM mcp_servers WHERE name='neo4j-global' AND user_id IS NULL")" 'explicit seed must not overwrite edits'
assert_eq INACTIVE "$(query "SELECT status FROM namespace_server_mappings WHERE uuid='00000000-0000-0000-0000-000000000301'")" 'explicit seed must not reactivate manual mapping'
printf 'ok - existing data, collisions and intentional deletions\n'

# An existing unauthenticated endpoint must never silently acquire the new
# database tools. Register the servers, preserve the endpoint and mappings,
# and allow an explicit retry once the owner has enabled authentication.
reset_db
query "
INSERT INTO namespaces (uuid, name) VALUES ('00000000-0000-0000-0000-000000000101', 'global');
INSERT INTO mcp_servers (uuid, name, command) VALUES ('00000000-0000-0000-0000-000000000201', 'manual-server', 'custom');
INSERT INTO namespace_server_mappings (namespace_uuid, mcp_server_uuid, status) VALUES ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000201', 'INACTIVE');
INSERT INTO endpoints (name, namespace_uuid, enable_api_key_auth, enable_oauth) VALUES ('manual-open', '00000000-0000-0000-0000-000000000101', false, false);" >/dev/null
bash "$ROOT/linux/run-global.sh" start > "$TMP/unprotected.out" 2>&1 || { cat "$TMP/unprotected.out" >&2; fail 'registration with an unprotected endpoint failed'; }
assert_contains "$TMP/unprotected.out" 'endpoint без аутентификации' 'unprotected endpoint must be reported'
assert_eq 4 "$(query "SELECT count(*) FROM mcp_servers WHERE name IN ('neo4j-global','qdrant-global','fetch','playwright')")" 'defaults should still appear in MetaMCP'
assert_eq 1 "$(query 'SELECT count(*) FROM namespace_server_mappings')" 'unprotected namespace must not gain new mappings'
assert_eq INACTIVE "$(query 'SELECT status FROM namespace_server_mappings')" 'manual mapping status must remain unchanged'
assert_eq 'false|false' "$(query "SELECT enable_api_key_auth || '|' || enable_oauth FROM endpoints WHERE name='manual-open'")" 'manual endpoint auth must not be modified'
assert_eq 0 "$(query "SELECT count(*) FROM endpoints WHERE name='global-sse'")" 'do not advertise a protected endpoint while another endpoint is open'
query "UPDATE endpoints SET enable_api_key_auth=true WHERE name='manual-open'" >/dev/null
bash "$ROOT/linux/run-global.sh" seed > "$TMP/protected-retry.out" 2>&1 || { cat "$TMP/protected-retry.out" >&2; fail 'reseed after enabling authentication failed'; }
assert_eq 5 "$(query 'SELECT count(*) FROM namespace_server_mappings')" 'explicit seed should link defaults after protection'
assert_eq 1 "$(query "SELECT count(*) FROM endpoints WHERE name='global-sse' AND enable_api_key_auth")" 'protected global endpoint should be created on retry'
printf 'ok - unprotected endpoints are not exposed to new tools\n'

# An SQL error must abort the whole transaction and propagate a failure. A
# later attempt must be able to complete without a partially written marker.
reset_db
query "ALTER TABLE mcp_servers ADD CONSTRAINT reject_qdrant CHECK (name <> 'qdrant-global'); INSERT INTO mcp_servers (name, command) VALUES ('manual-server', 'manual-command');" >/dev/null
if bash "$ROOT/linux/install-global.sh" > "$TMP/failure.out" 2>&1; then fail 'installation with SQL error was incorrectly reported as success'; fi
assert_contains "$TMP/failure.out" 'Не удалось подтвердить регистрацию' 'SQL error should be explained'
if grep -Fq 'ГЛОБАЛЬНЫЙ СТЕК УСТАНОВЛЕН И ЗАПУЩЕН' "$TMP/failure.out"; then fail 'installer printed a success banner after seed failed'; fi
assert_eq 1 "$(query 'SELECT count(*) FROM mcp_servers')" 'failed transaction must roll back inserted servers'
assert_eq 0 "$(query 'SELECT count(*) FROM namespaces')" 'failed transaction must roll back namespace'
assert_eq 0 "$(query "SELECT count(*) FROM config WHERE id='MULTFINITE_MCP_KIT_GLOBAL_SEED_V1'")" 'failed transaction must not write the marker'
query 'ALTER TABLE mcp_servers DROP CONSTRAINT reject_qdrant' >/dev/null
bash "$ROOT/linux/run-global.sh" start > "$TMP/retry.out" 2>&1 || { cat "$TMP/retry.out" >&2; fail 'retry after rollback failed'; }
assert_eq 4 "$(query "SELECT count(*) FROM mcp_servers WHERE name IN ('neo4j-global','qdrant-global','fetch','playwright')")" 'retry must register every default'
assert_eq 1 "$(query "SELECT count(*) FROM mcp_servers WHERE name='manual-server'")" 'manual server must survive rollback and retry'
printf 'ok - atomic rollback and retry\n'

# A health timeout must not touch the DB or claim success.
reset_db
export MOCK_HEALTH_ALWAYS_FAIL=1 METAMCP_START_TIMEOUT=0
if bash "$ROOT/linux/run-global.sh" start > "$TMP/timeout.out" 2>&1; then fail 'health timeout was incorrectly reported as success'; fi
assert_contains "$TMP/timeout.out" 'MetaMCP не запустился' 'health timeout should be explained'
assert_eq 0 "$(query 'SELECT count(*) FROM mcp_servers')" 'timeout must not seed before migrations'
unset MOCK_HEALTH_ALWAYS_FAIL
export METAMCP_START_TIMEOUT=4
printf 'ok - bounded startup timeout\n'

# NULL user IDs are not unique under MetaMCP's composite constraints. Two
# simultaneous invocations must still produce a single set of public records.
reset_db
bash "$ROOT/linux/run-global.sh" seed > "$TMP/concurrent-1.out" 2>&1 & pid1=$!
bash "$ROOT/linux/run-global.sh" seed > "$TMP/concurrent-2.out" 2>&1 & pid2=$!
wait "$pid1" || { cat "$TMP/concurrent-1.out" >&2; fail 'first concurrent seed failed'; }
wait "$pid2" || { cat "$TMP/concurrent-2.out" >&2; fail 'second concurrent seed failed'; }
assert_eq 4 "$(query 'SELECT count(*) FROM mcp_servers WHERE user_id IS NULL')" 'concurrent seeds must not create duplicate public servers'
assert_eq 1 "$(query "SELECT count(*) FROM namespaces WHERE name='global' AND user_id IS NULL")" 'concurrent seeds must not create duplicate namespaces'
assert_eq 4 "$(query 'SELECT count(*) FROM namespace_server_mappings')" 'concurrent seeds must not create duplicate mappings'
assert_eq 1 "$(query "SELECT count(*) FROM endpoints WHERE name='global-sse'")" 'concurrent seeds must not create duplicate endpoints'
printf 'ok - concurrent seeds\n'
