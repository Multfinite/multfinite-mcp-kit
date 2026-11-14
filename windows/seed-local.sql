-- The bundle is base64 JSON on stdin, never interpolated into SQL source.
-- Public means shared inside MetaMCP (user_id IS NULL), not unauthenticated.
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
    requested_email text := bundle->>'ownerEmail';
    actual_email text;
    owner_matches integer;
    port_text text := bundle->>'port';
    gateway_key text := bundle->>'gatewayKey';
    base_name text;
    base_url text;
    marker text;
    legacy_prefix text := 'MULTFINITE_MCP_KIT_LOCAL_DOCKER_V1:';
    upgrading_legacy boolean;
    legacy_owners integer;
    legacy_markers integer;
    group_spec record;
    group_name text;
    namespace_id uuid;
    namespace_matches integer;
    server_id uuid;
    server_matches integer;
    existing_type mcp_server_type;
    existing_url text;
    existing_headers jsonb;
    item_id text;
    item_description text;
    full_name text;
    target_url text;
    blocked text[] := ARRAY[]::text[];
    conflicts text[] := ARRAY[]::text[];
    deferred text[] := ARRAY[]::text[];
    diagnostics jsonb;
    known_namespaces jsonb := '{}'::jsonb;
    current_blocked text;
    available_groups text;
BEGIN
    IF COALESCE((bundle->>'version') = '1', false) IS NOT TRUE
       OR COALESCE(host_id ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(host_id) <= 32, false) IS NOT TRUE
       OR COALESCE(gateway_key ~ '^[a-f0-9]{64}$', false) IS NOT TRUE
       OR COALESCE(port_text ~ '^[0-9]{1,5}$', false) IS NOT TRUE
       OR COALESCE(requested_email = '' OR (length(requested_email) BETWEEN 3 AND 320
          AND requested_email ~ '^[^[:space:],|@]+@[^[:space:],|@]+$'), false) IS NOT TRUE THEN
        RAISE EXCEPTION 'Invalid local Docker registration bundle';
    END IF;
    IF port_text::integer NOT BETWEEN 1 AND 65535 THEN
        RAISE EXCEPTION 'Invalid local gateway port';
    END IF;
    PERFORM set_config('mcpkit.local_result', '', false);
    PERFORM set_config('mcpkit.local_owner', '', false);
    PERFORM set_config('mcpkit.local_groups', '', false);
    PERFORM set_config('mcpkit.local_blocked', '', false);
    PERFORM set_config('mcpkit.local_conflicts', '', false);
    PERFORM set_config('mcpkit.local_deferred', '', false);

    -- Account creation/registration remains manual. An optional explicit email
    -- is used only to add an already-registered user to a legacy admin list;
    -- shared server groups do not need an owner or an existing user account.
    IF requested_email <> '' THEN
        SELECT count(*), min(email) INTO owner_matches, actual_email
        FROM users WHERE lower(email) = lower(requested_email);
        IF owner_matches = 0 THEN
            PERFORM set_config('mcpkit.local_result', 'missing', false);
            RETURN;
        ELSIF owner_matches <> 1 THEN
            PERFORM set_config('mcpkit.local_result', 'ambiguous', false);
            RETURN;
        END IF;
        IF length(actual_email) NOT BETWEEN 3 AND 320 OR actual_email !~ '^[^[:space:],|@]+@[^[:space:],|@]+$' THEN
            RAISE EXCEPTION 'Unsupported MetaMCP account email';
        END IF;
        PERFORM set_config('mcpkit.local_owner', replace(encode(convert_to(actual_email, 'UTF8'), 'base64'), E'\n', ''), false);
    END IF;

    base_name := 'local-' || host_id;
    -- Only Docker Desktop's own host alias is allowed; never redirect a public
    -- server or disclose the gateway key to an arbitrary URL.
    base_url := 'http://host.docker.internal:' || port_text;
    marker := 'MULTFINITE_MCP_KIT_LOCAL_DOCKER_PUBLIC_V2:' || host_id;
    -- Keep the previous lock key so old and new seeders cannot race.
    PERFORM pg_advisory_xact_lock(hashtext('multfinite-mcp-kit:local-docker-seed-v1'));
    LOCK TABLE namespaces, mcp_servers, namespace_server_mappings, endpoints, namespace_tool_mappings
        IN SHARE ROW EXCLUSIVE MODE;

    -- Remember created namespace UUIDs, not just names: a manually created or
    -- replaced namespace must not acquire powerful native tools by accident.
    -- A malformed marker is never trusted as proof of ownership.
    BEGIN
        SELECT c.value::jsonb INTO diagnostics FROM config c WHERE c.id = marker;
        IF jsonb_typeof(diagnostics->'namespaces') = 'object' THEN
            known_namespaces := diagnostics->'namespaces';
        END IF;
    EXCEPTION WHEN invalid_text_representation THEN NULL;
    END;

    IF current_setting('mcpkit.local_force') <> 'true' AND EXISTS (SELECT 1 FROM config WHERE id = marker) THEN
        PERFORM set_config('mcpkit.local_result', 'skipped', false);
        -- Repeat outstanding upgrade warnings until the user reviews them and
        -- explicitly seeds again. No credentials are stored in this marker.
        IF jsonb_typeof(diagnostics) = 'object' THEN
            IF COALESCE(diagnostics->>'blocked', '') ~ '^[a-z0-9_,:-]*$' THEN
                PERFORM set_config('mcpkit.local_blocked', COALESCE(diagnostics->>'blocked', ''), false);
            END IF;
            IF COALESCE(diagnostics->>'conflicts', '') ~ '^[a-z0-9_,:-]*$' THEN
                PERFORM set_config('mcpkit.local_conflicts', COALESCE(diagnostics->>'conflicts', ''), false);
            END IF;
            IF COALESCE(diagnostics->>'deferred', '') ~ '^[a-z0-9_,:-]*$' THEN
                PERFORM set_config('mcpkit.local_deferred', COALESCE(diagnostics->>'deferred', ''), false);
            END IF;
        END IF;
    ELSE
        -- A V1 private installation is kept intact. During automatic upgrade,
        -- do not re-expose a server that any previously initialized owner had
        -- deleted, disabled or edited. Explicit `seed` can restore defaults.
        upgrading_legacy := current_setting('mcpkit.local_force') <> 'true' AND EXISTS (
            SELECT 1 FROM config c WHERE starts_with(c.id, legacy_prefix)
              AND right(c.id, length(host_id) + 1) = ':' || host_id
        );
        SELECT count(*) INTO legacy_markers FROM config c
        WHERE starts_with(c.id, legacy_prefix) AND right(c.id, length(host_id) + 1) = ':' || host_id;
        SELECT count(*) INTO legacy_owners FROM users u
        WHERE EXISTS (SELECT 1 FROM config c WHERE c.id = legacy_prefix || u.id || ':' || host_id);

        FOR group_spec IN SELECT * FROM (VALUES
            ('system', 'Windows desktop and system control', ARRAY['desktop-commander', 'windows-mcp']::text[]),
            ('files', 'Files, search and document conversion', ARRAY['everything-search', 'filesystem', 'markitdown']::text[]),
            ('code', 'Code navigation and development', ARRAY['git', 'codegraph', 'codebase-memory-mcp', 'serena']::text[]),
            ('web', 'Browser automation', ARRAY['playwright']::text[]),
            ('data', 'Database access', ARRAY['dbhub']::text[]),
            ('memory', 'Notes and document memory', ARRAY['simple-files-vectorstore', 'obsidian']::text[])
        ) AS defaults(suffix, description, servers)
        LOOP
            group_name := base_name || '-' || group_spec.suffix;
            SELECT count(*) INTO namespace_matches FROM namespaces n WHERE n.name = group_name AND n.user_id IS NULL;
            IF namespace_matches > 1 OR EXISTS (
                SELECT 1 FROM namespaces n WHERE n.name = group_name AND n.user_id IS NOT NULL
            ) THEN
                conflicts := array_append(conflicts, 'namespace:' || group_name);
                CONTINUE;
            END IF;
            SELECT n.uuid INTO namespace_id FROM namespaces n WHERE n.name = group_name AND n.user_id IS NULL LIMIT 1;
            IF namespace_id IS NULL THEN
                INSERT INTO namespaces (name, description, user_id)
                VALUES (group_name, group_spec.description, NULL)
                RETURNING uuid INTO namespace_id;
                known_namespaces := jsonb_set(known_namespaces, ARRAY[group_spec.suffix], to_jsonb(namespace_id::text), true);
            END IF;
            -- A public namespace may have other endpoints. Never attach native
            -- desktop/file tools if *any* of them is unauthenticated.
            IF EXISTS (SELECT 1 FROM endpoints e WHERE e.namespace_uuid = namespace_id
                       AND NOT e.enable_api_key_auth AND NOT e.enable_oauth) THEN
                blocked := array_append(blocked, group_name);
                CONTINUE;
            END IF;
            IF namespace_id::text IS DISTINCT FROM known_namespaces->>group_spec.suffix THEN
                conflicts := array_append(conflicts, 'namespace:' || group_name);
                CONTINUE;
            END IF;
            IF EXISTS (SELECT 1 FROM endpoints e WHERE e.name = group_name
                       AND (e.namespace_uuid <> namespace_id OR e.user_id IS NOT NULL)) THEN
                conflicts := array_append(conflicts, 'endpoint:' || group_name);
                CONTINUE;
            END IF;
            IF NOT EXISTS (SELECT 1 FROM endpoints e WHERE e.name = group_name) THEN
                INSERT INTO endpoints (name, description, namespace_uuid, enable_api_key_auth, user_id)
                VALUES (group_name, group_spec.description, namespace_id, true, NULL);
            END IF;

            FOREACH item_id IN ARRAY group_spec.servers LOOP
                -- Keep names distinct from V1's private records: upstream has
                -- lookups by name without owner. Short prefixes also keep the
                -- server-prefixed MCP tool names usable by more clients.
                full_name := 'winpub-' || substr(md5(host_id), 1, 8) || '-' || CASE item_id
                    WHEN 'desktop-commander' THEN 'desktop'
                    WHEN 'everything-search' THEN 'everything'
                    WHEN 'windows-mcp' THEN 'windows'
                    WHEN 'codebase-memory-mcp' THEN 'codebase'
                    WHEN 'simple-files-vectorstore' THEN 'vectorstore'
                    ELSE item_id
                END;
                target_url := base_url || '/servers/' || item_id || '/mcp';
                IF upgrading_legacy AND (legacy_owners = 0 OR legacy_markers <> legacy_owners OR EXISTS (
                    SELECT 1 FROM users u
                    WHERE EXISTS (SELECT 1 FROM config c WHERE c.id = legacy_prefix || u.id || ':' || host_id)
                      AND (
                        NOT EXISTS (
                            SELECT 1 FROM namespaces n
                            JOIN namespace_server_mappings m ON m.namespace_uuid = n.uuid
                            JOIN mcp_servers s ON s.uuid = m.mcp_server_uuid
                            WHERE n.user_id = u.id AND s.user_id = u.id
                              AND n.name IN (base_name, base_name || '-' || substr(md5(u.id), 1, 8))
                              AND s.name = n.name || '-' || item_id AND m.status = 'ACTIVE'
                              AND s.type = 'STREAMABLE_HTTP' AND s.url = target_url
                              AND s.args = ARRAY[]::text[] AND s.env = '{}'::jsonb
                              AND s.bearer_token IS NULL AND s.headers = jsonb_build_object('X-API-Key', gateway_key)
                              AND s.forward_headers = '{}'::jsonb
                              -- A removed/private endpoint or disabled/edited
                              -- tool must not silently become accessible again.
                              AND EXISTS (
                                  SELECT 1 FROM endpoints e WHERE e.name = n.name AND e.namespace_uuid = n.uuid
                                    AND e.user_id = u.id AND e.enable_api_key_auth AND NOT e.enable_oauth
                                    AND NOT e.use_query_param_auth AND NOT e.enable_max_rate
                                    AND NOT e.enable_client_max_rate AND NOT e.enable_metamcp_admin_tools
                              )
                              AND NOT EXISTS (
                                  SELECT 1 FROM namespace_tool_mappings tm
                                  WHERE tm.namespace_uuid = n.uuid AND tm.mcp_server_uuid = s.uuid
                                    AND (tm.status <> 'ACTIVE' OR tm.override_name IS NOT NULL
                                         OR tm.override_title IS NOT NULL OR tm.override_description IS NOT NULL
                                         OR tm.override_annotations IS NOT NULL)
                              )
                        )
                        OR EXISTS (
                            SELECT 1 FROM namespaces n
                            JOIN namespace_server_mappings m ON m.namespace_uuid = n.uuid
                            JOIN mcp_servers s ON s.uuid = m.mcp_server_uuid
                            WHERE n.user_id = u.id AND s.user_id = u.id
                              AND n.name IN (base_name, base_name || '-' || substr(md5(u.id), 1, 8))
                              AND s.name = n.name || '-' || item_id AND m.status <> 'ACTIVE'
                        )
                      )
                )) THEN
                    deferred := array_append(deferred, full_name);
                    CONTINUE;
                END IF;

                SELECT count(*) INTO server_matches FROM mcp_servers s WHERE s.name = full_name AND s.user_id IS NULL;
                IF server_matches > 1 OR EXISTS (
                    SELECT 1 FROM mcp_servers s WHERE s.name = full_name AND s.user_id IS NOT NULL
                ) THEN
                    conflicts := array_append(conflicts, 'server:' || full_name);
                    CONTINUE;
                END IF;
                SELECT s.uuid, s.type, s.url, s.headers INTO server_id, existing_type, existing_url, existing_headers
                FROM mcp_servers s WHERE s.name = full_name AND s.user_id IS NULL LIMIT 1;
                IF server_id IS NULL THEN
                    item_description := CASE item_id
                        WHEN 'desktop-commander' THEN 'Desktop Commander'
                        WHEN 'everything-search' THEN 'Everything Search'
                        WHEN 'filesystem' THEN 'Filesystem MCP'
                        WHEN 'windows-mcp' THEN 'Windows MCP'
                        WHEN 'git' THEN 'Git MCP'
                        WHEN 'codegraph' THEN 'CodeGraph'
                        WHEN 'codebase-memory-mcp' THEN 'Codebase Memory MCP'
                        WHEN 'serena' THEN 'Serena'
                        WHEN 'playwright' THEN 'Playwright MCP'
                        WHEN 'dbhub' THEN 'DBHub'
                        WHEN 'simple-files-vectorstore' THEN 'Simple Files Vectorstore'
                        WHEN 'markitdown' THEN 'MarkItDown'
                        WHEN 'obsidian' THEN 'Obsidian MCP'
                    END;
                    INSERT INTO mcp_servers (name, description, type, command, args, env, url, headers, user_id)
                    VALUES (full_name, item_description, 'STREAMABLE_HTTP', NULL, ARRAY[]::text[], '{}'::jsonb,
                            target_url, jsonb_build_object('X-API-Key', gateway_key), NULL)
                    RETURNING uuid INTO server_id;
                ELSIF existing_type <> 'STREAMABLE_HTTP' OR existing_url IS DISTINCT FROM target_url
                      OR existing_headers IS DISTINCT FROM jsonb_build_object('X-API-Key', gateway_key)
                      OR EXISTS (
                          SELECT 1 FROM mcp_servers s WHERE s.uuid = server_id
                            AND (s.args <> ARRAY[]::text[] OR s.env <> '{}'::jsonb
                                 OR s.bearer_token IS NOT NULL OR s.forward_headers <> '{}'::jsonb)
                      ) THEN
                    -- An existing public record may be a deliberate edit. Do
                    -- not rewrite or link it to a new endpoint.
                    conflicts := array_append(conflicts, 'server:' || full_name);
                    CONTINUE;
                END IF;
                INSERT INTO namespace_server_mappings (namespace_uuid, mcp_server_uuid)
                VALUES (namespace_id, server_id)
                ON CONFLICT (namespace_uuid, mcp_server_uuid) DO NOTHING;
            END LOOP;
        END LOOP;
        INSERT INTO config (id, value, description)
        VALUES (marker, jsonb_build_object('blocked', array_to_string(blocked, ','),
                                          'conflicts', array_to_string(conflicts, ','),
                                          'deferred', array_to_string(deferred, ','),
                                          'namespaces', known_namespaces)::text,
                'Shared grouped Windows LOCAL servers initialized by multfinite-mcp-kit')
        ON CONFLICT (id) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
        PERFORM set_config('mcpkit.local_result', 'seeded', false);
        PERFORM set_config('mcpkit.local_blocked', array_to_string(blocked, ','), false);
        PERFORM set_config('mcpkit.local_conflicts', array_to_string(conflicts, ','), false);
        PERFORM set_config('mcpkit.local_deferred', array_to_string(deferred, ','), false);
    END IF;

    -- Also report groups whose endpoints were opened after initial seeding.
    SELECT string_agg(DISTINCT b.name, ',' ORDER BY b.name) INTO current_blocked
    FROM (
        SELECT unnest(string_to_array(current_setting('mcpkit.local_blocked'), ',')) AS name
        UNION ALL
        SELECT n.name FROM namespaces n JOIN endpoints e ON e.namespace_uuid = n.uuid
        WHERE n.user_id IS NULL
          AND n.name IN (base_name || '-system', base_name || '-files', base_name || '-code',
                         base_name || '-web', base_name || '-data', base_name || '-memory')
          AND NOT e.enable_api_key_auth AND NOT e.enable_oauth
    ) b WHERE b.name <> '';
    PERFORM set_config('mcpkit.local_blocked', COALESCE(current_blocked, ''), false);

    -- Report only currently existing, shared and authenticated endpoints;
    -- automatic repeats never recreate deliberately deleted/disabled records.
    SELECT string_agg(e.name, ',' ORDER BY e.name) INTO available_groups
    FROM endpoints e JOIN namespaces n ON n.uuid = e.namespace_uuid
    WHERE e.name IN (base_name || '-system', base_name || '-files', base_name || '-code',
                     base_name || '-web', base_name || '-data', base_name || '-memory')
      AND n.name = e.name AND n.user_id IS NULL AND e.user_id IS NULL
      AND n.uuid::text = known_namespaces->>substr(n.name, length(base_name) + 2)
      AND (e.enable_api_key_auth OR e.enable_oauth)
      AND NOT EXISTS (SELECT 1 FROM namespaces other WHERE other.name = n.name AND other.uuid <> n.uuid)
      AND NOT EXISTS (SELECT 1 FROM endpoints open_endpoint
                      WHERE open_endpoint.namespace_uuid = n.uuid
                        AND NOT open_endpoint.enable_api_key_auth AND NOT open_endpoint.enable_oauth);
    PERFORM set_config('mcpkit.local_groups', COALESCE(available_groups, ''), false);
END
$seed$;
COMMIT;
SELECT current_setting('mcpkit.local_result') || '|' || current_setting('mcpkit.local_owner') || '|' ||
       current_setting('mcpkit.local_groups') || '|' || current_setting('mcpkit.local_blocked') || '|' ||
       current_setting('mcpkit.local_conflicts') || '|' || current_setting('mcpkit.local_deferred');
