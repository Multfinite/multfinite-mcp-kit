-- MetaMCP's current schema uses UUID keys, a text[] for args and uppercase
-- transport/status enums.  Run only after the application has migrated its DB.
-- The caller supplies base64-encoded values through psql variables on stdin,
-- so configuration values (including passwords) never become SQL code.
BEGIN;
-- Avoid waiting indefinitely behind a manual operation holding a table lock.
SET LOCAL lock_timeout = '10s';

SELECT
    set_config('mcpkit.neo4j_uri', convert_from(decode(:'neo4j_uri_b64', 'base64'), 'UTF8'), true) AS neo4j_uri,
    set_config('mcpkit.neo4j_user', convert_from(decode(:'neo4j_user_b64', 'base64'), 'UTF8'), true) AS neo4j_user,
    set_config('mcpkit.neo4j_password', convert_from(decode(:'neo4j_password_b64', 'base64'), 'UTF8'), true) AS neo4j_password,
    set_config('mcpkit.qdrant_url', convert_from(decode(:'qdrant_url_b64', 'base64'), 'UTF8'), true) AS qdrant_url,
    set_config('mcpkit.qdrant_api_key', convert_from(decode(:'qdrant_api_key_b64', 'base64'), 'UTF8'), true) AS qdrant_api_key,
    set_config('mcpkit.seed_force', :'seed_force', true) AS seed_force
\gset

DO $seed$
DECLARE
    target_namespace_uuid uuid;
    target_server_uuid uuid;
    server_spec record;
    endpoint_conflict boolean := false;
    unprotected_namespace boolean := false;
BEGIN
    -- Serialize concurrent invocations, including the check for the marker.
    PERFORM pg_advisory_xact_lock(hashtext('multfinite-mcp-kit:global-seed-v1'));

    IF current_setting('mcpkit.seed_force') <> 'true'
       AND EXISTS (SELECT 1 FROM config WHERE id = 'MULTFINITE_MCP_KIT_GLOBAL_SEED_V1') THEN
        PERFORM set_config('mcpkit.seed_result', 'skipped', false);
        RETURN;
    END IF;

    -- PostgreSQL's UNIQUE(name, user_id) permits multiple NULL user_ids. Lock
    -- while checking and inserting so concurrent UI writes cannot create a
    -- duplicate public server or namespace between those two steps.
    LOCK TABLE namespaces, mcp_servers, namespace_server_mappings, endpoints
        IN SHARE ROW EXCLUSIVE MODE;

    SELECT n.uuid INTO target_namespace_uuid
    FROM namespaces n
    WHERE n.name = 'global' AND n.user_id IS NULL
    ORDER BY n.created_at, n.uuid
    LIMIT 1;

    IF target_namespace_uuid IS NULL THEN
        INSERT INTO namespaces (name, description, user_id)
        VALUES ('global', 'Основное пространство инструментов', NULL)
        RETURNING uuid INTO target_namespace_uuid;
    END IF;

    -- Adding database tools to an existing unauthenticated endpoint would
    -- expose them to anyone. Register the servers but leave the namespace's
    -- mappings untouched until the owner enables auth and explicitly retries.
    SELECT EXISTS (
        SELECT 1 FROM endpoints e
        WHERE e.namespace_uuid = target_namespace_uuid
          AND NOT e.enable_api_key_auth AND NOT e.enable_oauth
    ) INTO unprotected_namespace;

    FOR server_spec IN
        SELECT * FROM (VALUES
            ('neo4j-global', 'Neo4j Graph DB', 'uvx',
             ARRAY['mcp-neo4j-cypher']::text[],
             jsonb_build_object(
                 'NEO4J_URI', current_setting('mcpkit.neo4j_uri'),
                 'NEO4J_USERNAME', current_setting('mcpkit.neo4j_user'),
                 'NEO4J_PASSWORD', current_setting('mcpkit.neo4j_password'))),
            ('qdrant-global', 'Qdrant Vector DB', 'uvx',
             ARRAY['mcp-server-qdrant']::text[],
             jsonb_strip_nulls(jsonb_build_object(
                 'QDRANT_URL', current_setting('mcpkit.qdrant_url'),
                 'QDRANT_API_KEY', NULLIF(current_setting('mcpkit.qdrant_api_key'), '')))),
            ('fetch', 'Web Fetcher', 'uvx',
             ARRAY['mcp-server-fetch']::text[], '{}'::jsonb),
            ('playwright', 'Browser Automation', 'npx',
             ARRAY['-y', '@playwright/mcp', '--headless']::text[], '{}'::jsonb)
        ) AS defaults(name, description, command, args, env)
    LOOP
        -- Do not use a private server with the same name in a public namespace.
        -- An existing public server, including its command and secrets, is kept.
        SELECT s.uuid INTO target_server_uuid
        FROM mcp_servers s
        WHERE s.name = server_spec.name AND s.user_id IS NULL
        ORDER BY s.created_at, s.uuid
        LIMIT 1;

        IF target_server_uuid IS NULL THEN
            INSERT INTO mcp_servers (name, description, type, command, args, env, user_id)
            VALUES (server_spec.name, server_spec.description, 'STDIO',
                    server_spec.command, server_spec.args, server_spec.env, NULL)
            RETURNING uuid INTO target_server_uuid;
        END IF;

        -- Keep every existing mapping, including deliberately inactive ones.
        IF NOT unprotected_namespace THEN
            INSERT INTO namespace_server_mappings (namespace_uuid, mcp_server_uuid)
            VALUES (target_namespace_uuid, target_server_uuid)
            ON CONFLICT (namespace_uuid, mcp_server_uuid) DO NOTHING;
        END IF;
    END LOOP;

    IF NOT unprotected_namespace THEN
        IF NOT EXISTS (SELECT 1 FROM endpoints e WHERE e.name = 'global-sse') THEN
            INSERT INTO endpoints (name, description, namespace_uuid, enable_api_key_auth, user_id)
            VALUES ('global-sse', 'Глобальный MCP endpoint', target_namespace_uuid, true, NULL);
        ELSIF NOT EXISTS (
            SELECT 1 FROM endpoints e
            WHERE e.name = 'global-sse'
              AND e.namespace_uuid = target_namespace_uuid
              AND e.user_id IS NULL
        ) THEN
            -- Endpoint names are globally unique. Never redirect a user's endpoint.
            endpoint_conflict := true;
        END IF;
    END IF;

    -- Only a successful transaction creates the marker. Future automatic
    -- starts leave intentional deletions/unlinks alone; explicit `seed` retries.
    INSERT INTO config (id, value, description)
    VALUES ('MULTFINITE_MCP_KIT_GLOBAL_SEED_V1', 'complete',
            'Default global MCP servers initialized by multfinite-mcp-kit')
    ON CONFLICT (id) DO NOTHING;

    PERFORM set_config('mcpkit.seed_result',
        CASE
            WHEN unprotected_namespace THEN 'unprotected-namespace'
            WHEN endpoint_conflict THEN 'endpoint-conflict'
            ELSE 'seeded'
        END,
        false);
END
$seed$;

COMMIT;
SELECT current_setting('mcpkit.seed_result');
