-- Input is a base64-encoded JSON bundle sent to the local Docker container
-- on stdin. Never interpolate an email, port, or secret into SQL source.
BEGIN;
SET LOCAL lock_timeout = '10s';
SELECT
    set_config('mcpkit.local_bundle', convert_from(decode(:'local_bundle_b64', 'base64'), 'UTF8'), true) AS local_bundle,
    set_config('mcpkit.local_force', :'local_force', true) AS local_force
\gset

DO $seed$
DECLARE
    bundle jsonb := current_setting('mcpkit.local_bundle')::jsonb;
    host_id text := bundle->>'hostId';
    owner_id text;
    owner_matches integer;
    port_text text := bundle->>'port';
    base_url text;
    gateway_key text := bundle->>'gatewayKey';
    group_name text;
    marker text;
    namespace_id uuid;
    server_id uuid;
    existing_type mcp_server_type;
    existing_url text;
    existing_headers jsonb;
    item record;
    full_name text;
    target_url text;
    conflicts text[] := ARRAY[]::text[];
BEGIN
    IF COALESCE((bundle->>'version') = '1', false) IS NOT TRUE
       OR COALESCE(host_id ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(host_id) <= 32, false) IS NOT TRUE
       OR COALESCE(gateway_key ~ '^[a-f0-9]{64}$', false) IS NOT TRUE
       OR COALESCE(port_text ~ '^[0-9]{1,5}$', false) IS NOT TRUE
       OR COALESCE(length(bundle->>'ownerEmail') BETWEEN 3 AND 320, false) IS NOT TRUE THEN
        RAISE EXCEPTION 'Invalid local Docker registration bundle';
    END IF;
    IF port_text::integer NOT BETWEEN 1 AND 65535 THEN
        RAISE EXCEPTION 'Invalid local gateway port';
    END IF;
    -- Only Docker Desktop's own host alias is allowed; there is no LAN or
    -- arbitrary-URL fallback in the automatic local registration.
    base_url := 'http://host.docker.internal:' || port_text;

    SELECT count(*), min(id) INTO owner_matches, owner_id FROM users WHERE lower(email) = lower(bundle->>'ownerEmail');
    IF owner_matches <> 1 THEN
        RAISE EXCEPTION 'MetaMCP account not found or email is ambiguous; use a unique existing account';
    END IF;
    -- Upstream creates the bootstrap user through the normal signup hook.
    -- Registration must be enabled during that initial creation; once the
    -- owner exists, close it on this dedicated loopback-only instance. The
    -- upstream bootstrap resets this flag on each app start, so apply it on
    -- each successful automatic seed, including the idempotent skip path.
    INSERT INTO config (id, value, description)
    VALUES ('DISABLE_SIGNUP', 'true', 'Whether new user signup is disabled')
    ON CONFLICT (id) DO UPDATE SET value = 'true', updated_at = now();
    group_name := 'local-' || host_id;
    marker := 'MULTFINITE_MCP_KIT_LOCAL_DOCKER_V1:' || owner_id || ':' || host_id;
    PERFORM pg_advisory_xact_lock(hashtext('multfinite-mcp-kit:local-docker-seed-v1'));
    PERFORM set_config('mcpkit.local_conflicts', '', false);
    IF current_setting('mcpkit.local_force') <> 'true' AND EXISTS (SELECT 1 FROM config WHERE id = marker) THEN
        PERFORM set_config('mcpkit.local_result', 'skipped', false);
        RETURN;
    END IF;

    -- Same order as the global seeder. Serialize checks with UI and other
    -- seeders; never attach this machine to a public namespace or endpoint.
    LOCK TABLE namespaces, mcp_servers, namespace_server_mappings, endpoints IN SHARE ROW EXCLUSIVE MODE;
    SELECT n.uuid INTO namespace_id FROM namespaces n WHERE n.name = group_name AND n.user_id = owner_id;
    IF namespace_id IS NULL THEN
        INSERT INTO namespaces (name, description, user_id)
        VALUES (group_name, 'Private native Windows MCP servers', owner_id)
        RETURNING uuid INTO namespace_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM endpoints e WHERE e.namespace_uuid = namespace_id
          AND (e.user_id IS DISTINCT FROM owner_id OR (NOT e.enable_api_key_auth AND NOT e.enable_oauth))
    ) THEN
        RAISE EXCEPTION 'The target namespace has an open or non-owner endpoint; protect it before seeding';
    END IF;
    IF EXISTS (
        SELECT 1 FROM endpoints e WHERE e.name = group_name
          AND (e.namespace_uuid <> namespace_id OR e.user_id IS DISTINCT FROM owner_id)
    ) THEN
        RAISE EXCEPTION 'The endpoint name is already owned by another namespace or user';
    END IF;

    FOR item IN SELECT * FROM (VALUES
        ('desktop-commander', 'Desktop Commander'),
        ('everything-search', 'Everything Search'),
        ('filesystem', 'Filesystem MCP'),
        ('windows-mcp', 'Windows MCP'),
        ('git', 'Git MCP'),
        ('codegraph', 'CodeGraph'),
        ('codebase-memory-mcp', 'Codebase Memory MCP'),
        ('serena', 'Serena'),
        ('playwright', 'Playwright MCP'),
        ('dbhub', 'DBHub'),
        ('simple-files-vectorstore', 'Simple Files Vectorstore'),
        ('markitdown', 'MarkItDown'),
        ('obsidian', 'Obsidian MCP')
    ) AS defaults(id, description)
    LOOP
        full_name := group_name || '-' || item.id;
        target_url := base_url || '/servers/' || item.id || '/mcp';
        SELECT s.uuid, s.type, s.url, s.headers INTO server_id, existing_type, existing_url, existing_headers
        FROM mcp_servers s WHERE s.name = full_name AND s.user_id = owner_id;
        IF server_id IS NULL THEN
            INSERT INTO mcp_servers (name, description, type, command, args, env, url, headers, user_id)
            VALUES (full_name, item.description, 'STREAMABLE_HTTP', NULL, ARRAY[]::text[], '{}'::jsonb,
                    target_url, jsonb_build_object('X-API-Key', gateway_key), owner_id)
            RETURNING uuid INTO server_id;
        ELSIF existing_type <> 'STREAMABLE_HTTP' OR existing_url IS DISTINCT FROM target_url
              OR existing_headers->>'X-API-Key' IS DISTINCT FROM gateway_key THEN
            -- It might be a manual record or an intentional edit. Never link,
            -- redirect, or overwrite it as part of an automatic or forced seed.
            conflicts := array_append(conflicts, full_name);
            CONTINUE;
        END IF;
        INSERT INTO namespace_server_mappings (namespace_uuid, mcp_server_uuid)
        VALUES (namespace_id, server_id)
        ON CONFLICT (namespace_uuid, mcp_server_uuid) DO NOTHING;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM endpoints e WHERE e.name = group_name) THEN
        INSERT INTO endpoints (name, description, namespace_uuid, enable_api_key_auth, user_id)
        VALUES (group_name, 'Private Windows MCP endpoint', namespace_id, true, owner_id);
    END IF;
    INSERT INTO config (id, value, description)
    VALUES (marker, 'complete', 'Native Windows LOCAL servers initialized by multfinite-mcp-kit')
    ON CONFLICT (id) DO NOTHING;
    PERFORM set_config('mcpkit.local_result', 'seeded', false);
    PERFORM set_config('mcpkit.local_conflicts', array_to_string(conflicts, ','), false);
END
$seed$;
COMMIT;
SELECT current_setting('mcpkit.local_result') || '|' || current_setting('mcpkit.local_conflicts');
