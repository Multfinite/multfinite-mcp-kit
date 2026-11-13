-- Run only after MetaMCP migrations. Values arrive as base64 psql variables on
-- stdin, so even quotes, dollar signs and newlines in secrets cannot become SQL.
BEGIN;
SET LOCAL lock_timeout = '10s';

SELECT
    set_config('mcpkit.neo4j_uri', convert_from(decode(:'neo4j_uri_b64', 'base64'), 'UTF8'), true) AS neo4j_uri,
    set_config('mcpkit.neo4j_user', convert_from(decode(:'neo4j_user_b64', 'base64'), 'UTF8'), true) AS neo4j_user,
    set_config('mcpkit.neo4j_password', convert_from(decode(:'neo4j_password_b64', 'base64'), 'UTF8'), true) AS neo4j_password,
    set_config('mcpkit.qdrant_url', convert_from(decode(:'qdrant_url_b64', 'base64'), 'UTF8'), true) AS qdrant_url,
    set_config('mcpkit.qdrant_api_key', convert_from(decode(:'qdrant_api_key_b64', 'base64'), 'UTF8'), true) AS qdrant_api_key,
    set_config('mcpkit.github_token', convert_from(decode(:'github_token_b64', 'base64'), 'UTF8'), true) AS github_token,
    set_config('mcpkit.context7_key', convert_from(decode(:'context7_key_b64', 'base64'), 'UTF8'), true) AS context7_key,
    set_config('mcpkit.seed_force', :'seed_force', true) AS seed_force
\gset

DO $seed$
DECLARE
    target_namespace_uuid uuid;
    target_server_uuid uuid;
    server_spec record;
    namespace_spec record;
    server_name text;
    upgrading_v1 boolean;
    blocked_namespaces text[] := ARRAY[]::text[];
    conflicting_endpoints text[] := ARRAY[]::text[];
BEGIN
    -- Keep the V1 lock key so old and new scripts cannot seed concurrently.
    PERFORM pg_advisory_xact_lock(hashtext('multfinite-mcp-kit:global-seed-v1'));
    PERFORM set_config('mcpkit.seed_blocked', '', false);
    PERFORM set_config('mcpkit.seed_conflicts', '', false);

    IF current_setting('mcpkit.seed_force') <> 'true'
       AND EXISTS (SELECT 1 FROM config WHERE id = 'MULTFINITE_MCP_KIT_GLOBAL_SEED_V2') THEN
        PERFORM set_config('mcpkit.seed_result', 'skipped', false);
        RETURN;
    END IF;

    upgrading_v1 := current_setting('mcpkit.seed_force') <> 'true'
        AND EXISTS (SELECT 1 FROM config WHERE id = 'MULTFINITE_MCP_KIT_GLOBAL_SEED_V1');

    -- UNIQUE(name, user_id) permits multiple NULL user_ids. Serialize the
    -- check/insert with UI writes as well as other seed processes.
    LOCK TABLE namespaces, mcp_servers, namespace_server_mappings, endpoints
        IN SHARE ROW EXCLUSIVE MODE;

    FOR server_spec IN
        SELECT * FROM (VALUES
            -- The four V1 records remain in the legacy namespace. On an
            -- automatic V1 upgrade never restore a deliberately deleted one.
            ('neo4j-global', 'Neo4j Graph DB', 'STDIO', 'uvx',
             ARRAY['mcp-neo4j-cypher']::text[],
             jsonb_build_object('NEO4J_URI', current_setting('mcpkit.neo4j_uri'),
                                'NEO4J_USERNAME', current_setting('mcpkit.neo4j_user'),
                                'NEO4J_PASSWORD', current_setting('mcpkit.neo4j_password')),
             NULL::text, NULL::text, '{}'::jsonb, true),
            ('qdrant-global', 'Qdrant Vector DB', 'STDIO', 'uvx',
             ARRAY['mcp-server-qdrant']::text[],
             jsonb_strip_nulls(jsonb_build_object('QDRANT_URL', current_setting('mcpkit.qdrant_url'),
                                'QDRANT_API_KEY', NULLIF(current_setting('mcpkit.qdrant_api_key'), ''))),
             NULL::text, NULL::text, '{}'::jsonb, true),
            ('fetch', 'Web Fetcher', 'STDIO', 'uvx',
             ARRAY['mcp-server-fetch']::text[], '{}'::jsonb,
             NULL::text, NULL::text, '{}'::jsonb, true),
            ('playwright', 'Browser Automation', 'STDIO', 'npx',
             ARRAY['-y', '@playwright/mcp', '--headless']::text[], '{}'::jsonb,
             NULL::text, NULL::text, '{}'::jsonb, true),

            ('sequentialthinking', 'Sequential Thinking', 'STDIO', 'npx',
             ARRAY['-y', '@modelcontextprotocol/server-sequential-thinking@2025.12.18']::text[], '{}'::jsonb,
             NULL::text, NULL::text, '{}'::jsonb, false),
            ('graphiti', 'Graphiti Knowledge Graph', 'STREAMABLE_HTTP', NULL::text,
             ARRAY[]::text[], '{}'::jsonb, 'http://mcpkit-graphiti:8000/mcp', NULL::text, '{}'::jsonb, false),
            ('cognee', 'Cognee Memory', 'STREAMABLE_HTTP', NULL::text,
             ARRAY[]::text[], '{}'::jsonb, 'http://mcpkit-cognee:8000/mcp', NULL::text, '{}'::jsonb, false),
            ('memory-bank-mcp', 'Memory Bank', 'STREAMABLE_HTTP', NULL::text,
             ARRAY[]::text[], '{}'::jsonb, 'http://mcpkit-memory-bank:8000/mcp', NULL::text, '{}'::jsonb, false),
            ('context7', 'Context7 Documentation', 'STDIO', 'npx',
             ARRAY['-y', '@upstash/context7-mcp@4.7.0']::text[],
             jsonb_strip_nulls(jsonb_build_object('CONTEXT7_API_KEY', NULLIF(current_setting('mcpkit.context7_key'), ''))),
             NULL::text, NULL::text, '{}'::jsonb, false),
            ('duckduckgo', 'DuckDuckGo Search', 'STDIO', 'uvx',
             ARRAY['--with', 'duckduckgo-mcp-server[browser]==0.7.0', 'duckduckgo-mcp-server']::text[], '{}'::jsonb,
             NULL::text, NULL::text, '{}'::jsonb, false),
            ('github-mcp-server', 'GitHub MCP Server', 'STREAMABLE_HTTP', NULL::text,
             ARRAY[]::text[], '{}'::jsonb, 'https://api.githubcopilot.com/mcp/',
             NULLIF(current_setting('mcpkit.github_token'), ''), '{}'::jsonb, false),
            -- MetaMCP names do not permit dots; this is the README's io.draw.
            ('io-draw', 'draw.io Diagrams', 'STDIO', 'npx',
             ARRAY['-y', '@drawio/mcp@1.12.0']::text[], jsonb_build_object('DRAWIO_BROWSER', 'off'),
             NULL::text, NULL::text, '{}'::jsonb, false),
            ('mcp-compass', 'MCP Server Discovery', 'STDIO', 'npx',
             ARRAY['-y', '@liuyoshio/mcp-compass@1.0.7']::text[], '{}'::jsonb,
             NULL::text, NULL::text, '{}'::jsonb, false),
            ('gdrive', 'Google Drive', 'STREAMABLE_HTTP', NULL::text,
             ARRAY[]::text[], '{}'::jsonb, 'http://mcpkit-gdrive:8000/mcp', NULL::text, '{}'::jsonb, false)
        ) AS defaults(name, description, transport, command, args, env, url, bearer_token, headers, legacy)
    LOOP
        IF upgrading_v1 AND server_spec.legacy THEN
            CONTINUE;
        END IF;

        -- Reuse only public servers; never alter an existing command, secret,
        -- transport or a private record with the same name.
        SELECT s.uuid INTO target_server_uuid
        FROM mcp_servers s
        WHERE s.name = server_spec.name AND s.user_id IS NULL
        ORDER BY s.created_at, s.uuid LIMIT 1;

        IF target_server_uuid IS NULL THEN
            INSERT INTO mcp_servers (name, description, type, command, args, env, url, bearer_token, headers, user_id)
            VALUES (server_spec.name, server_spec.description, server_spec.transport::mcp_server_type,
                    server_spec.command, server_spec.args, server_spec.env, server_spec.url,
                    server_spec.bearer_token, server_spec.headers, NULL);
        END IF;
    END LOOP;

    FOR namespace_spec IN
        SELECT * FROM (VALUES
            ('global', 'Основное пространство инструментов', 'global-sse',
             ARRAY['neo4j-global', 'qdrant-global', 'fetch', 'playwright']::text[]),
            ('global-reasoning', 'Рассуждения и поиск MCP-серверов', 'global-reasoning',
             ARRAY['sequentialthinking', 'mcp-compass']::text[]),
            ('global-memory', 'Память и граф знаний', 'global-memory',
             ARRAY['graphiti', 'cognee', 'memory-bank-mcp']::text[]),
            ('global-web', 'Поиск и документация', 'global-web',
             ARRAY['context7', 'duckduckgo', 'fetch']::text[]),
            ('global-integrations', 'Интеграции и диаграммы', 'global-integrations',
             ARRAY['github-mcp-server', 'io-draw', 'gdrive']::text[])
        ) AS defaults(name, description, endpoint, servers)
    LOOP
        -- V1's namespace, mappings and endpoint may have been intentionally
        -- removed or edited. Do not touch them during an automatic upgrade.
        IF upgrading_v1 AND namespace_spec.name = 'global' THEN
            CONTINUE;
        END IF;

        SELECT n.uuid INTO target_namespace_uuid
        FROM namespaces n
        WHERE n.name = namespace_spec.name AND n.user_id IS NULL
        ORDER BY n.created_at, n.uuid LIMIT 1;
        IF target_namespace_uuid IS NULL THEN
            INSERT INTO namespaces (name, description, user_id)
            VALUES (namespace_spec.name, namespace_spec.description, NULL)
            RETURNING uuid INTO target_namespace_uuid;
        END IF;

        -- A protected new endpoint is insufficient if ANY other endpoint of
        -- this namespace is open. Do not add tools to that namespace at all.
        IF EXISTS (
            SELECT 1 FROM endpoints e
            WHERE e.namespace_uuid = target_namespace_uuid
              AND NOT e.enable_api_key_auth AND NOT e.enable_oauth
        ) THEN
            blocked_namespaces := array_append(blocked_namespaces, namespace_spec.name);
            CONTINUE;
        END IF;

        FOREACH server_name IN ARRAY namespace_spec.servers LOOP
            SELECT s.uuid INTO target_server_uuid
            FROM mcp_servers s
            WHERE s.name = server_name AND s.user_id IS NULL
            ORDER BY s.created_at, s.uuid LIMIT 1;

            -- On a V1 upgrade, only expose the same fetch instance that is
            -- still active in the original selected global namespace. Checking
            -- UUIDs matters when old databases contain duplicate public names.
            IF upgrading_v1 AND server_name = 'fetch' AND NOT EXISTS (
                SELECT 1 FROM namespace_server_mappings m
                WHERE m.mcp_server_uuid = target_server_uuid AND m.status = 'ACTIVE'
                  AND m.namespace_uuid = (
                      SELECT n.uuid FROM namespaces n
                      WHERE n.name = 'global' AND n.user_id IS NULL
                      ORDER BY n.created_at, n.uuid LIMIT 1
                  )
            ) THEN
                CONTINUE;
            END IF;

            IF target_server_uuid IS NOT NULL THEN
                -- Keep deliberately inactive mappings and all manual mappings.
                INSERT INTO namespace_server_mappings (namespace_uuid, mcp_server_uuid)
                VALUES (target_namespace_uuid, target_server_uuid)
                ON CONFLICT (namespace_uuid, mcp_server_uuid) DO NOTHING;
            END IF;
        END LOOP;

        IF NOT EXISTS (SELECT 1 FROM endpoints e WHERE e.name = namespace_spec.endpoint) THEN
            INSERT INTO endpoints (name, description, namespace_uuid, enable_api_key_auth, user_id)
            VALUES (namespace_spec.endpoint, namespace_spec.description, target_namespace_uuid, true, NULL);
        ELSIF NOT EXISTS (
            SELECT 1 FROM endpoints e
            WHERE e.name = namespace_spec.endpoint AND e.namespace_uuid = target_namespace_uuid AND e.user_id IS NULL
        ) THEN
            -- Endpoint names are globally unique; do not redirect another user.
            conflicting_endpoints := array_append(conflicting_endpoints, namespace_spec.endpoint);
        END IF;
    END LOOP;

    INSERT INTO config (id, value, description)
    VALUES ('MULTFINITE_MCP_KIT_GLOBAL_SEED_V1', 'complete', 'Default global MCP servers initialized by multfinite-mcp-kit'),
           ('MULTFINITE_MCP_KIT_GLOBAL_SEED_V2', 'complete', 'All README global MCP servers initialized by multfinite-mcp-kit')
    ON CONFLICT (id) DO NOTHING;

    PERFORM set_config('mcpkit.seed_result', 'seeded', false);
    PERFORM set_config('mcpkit.seed_blocked', array_to_string(blocked_namespaces, ','), false);
    PERFORM set_config('mcpkit.seed_conflicts', array_to_string(conflicting_endpoints, ','), false);
END
$seed$;

COMMIT;
SELECT current_setting('mcpkit.seed_result') || '|' || current_setting('mcpkit.seed_blocked') || '|' || current_setting('mcpkit.seed_conflicts');
