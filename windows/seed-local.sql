-- The bundle is base64 JSON on stdin, never interpolated into SQL source.
-- Public means shared inside MetaMCP (user_id IS NULL), not unauthenticated.
-- The caller stops the kit app and backs up PostgreSQL before an applying run.
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
    forced boolean := current_setting('mcpkit.local_force') = 'true';
    base_name text;
    base_url text;
    marker text;
    v2_marker text;
    legacy_prefix text := 'MULTFINITE_MCP_KIT_LOCAL_DOCKER_V1:';
    v2_exists boolean;
    v3_exists boolean;
    legacy_markers integer;
    legacy_owners integer;
    owner_row record;
    old record;
    item record;
    group_spec record;
    candidate record;
    tool record;
    namespace_id uuid;
    namespace_matches integer;
    old_namespace_id uuid;
    old_namespace_name text;
    old_issue text;
    group_name text;
    old_public_name text;
    target_url text;
    server_id uuid;
    secondary_tool_id uuid;
    candidate_count integer;
    description_count integer;
    merged_description text;
    any_error boolean;
    default_connection boolean;
    can_link boolean;
    link_status mcp_server_status;
    tool_status mcp_server_status;
    override_name text;
    override_title text;
    override_description text;
    override_annotations jsonb;
    target_mapping namespace_tool_mappings%ROWTYPE;
    blocked text[] := ARRAY[]::text[];
    conflicts text[] := ARRAY[]::text[];
    deferred text[] := ARRAY[]::text[];
    diagnostics jsonb;
    known_namespaces jsonb := '{}'::jsonb;
    known_servers jsonb := '{}'::jsonb;
    known_legacy jsonb := '{}'::jsonb;
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

    -- Registration is manual. An optional existing account is only used by
    -- PowerShell to extend an older installation's administrator allowlist.
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
    -- Never send the gateway key to an arbitrary URL.
    base_url := 'http://host.docker.internal:' || port_text;
    marker := 'MULTFINITE_MCP_KIT_LOCAL_DOCKER_PUBLIC_V3:' || host_id;
    v2_marker := 'MULTFINITE_MCP_KIT_LOCAL_DOCKER_PUBLIC_V2:' || host_id;
    PERFORM pg_advisory_xact_lock(hashtext('multfinite-mcp-kit:local-docker-seed-v1'));
    v2_exists := EXISTS (SELECT 1 FROM config WHERE id = v2_marker);
    v3_exists := EXISTS (SELECT 1 FROM config WHERE id = marker);

    -- V2 stored the UUIDs of the namespaces it created. Import those on the
    -- first V3 run; names alone are not proof that a namespace is kit-owned.
    BEGIN
        SELECT c.value::jsonb INTO diagnostics FROM config c WHERE c.id = CASE WHEN v3_exists THEN marker ELSE v2_marker END;
        IF jsonb_typeof(diagnostics->'namespaces') = 'object' THEN known_namespaces := diagnostics->'namespaces'; END IF;
        IF jsonb_typeof(diagnostics->'servers') = 'object' THEN known_servers := diagnostics->'servers'; END IF;
        IF jsonb_typeof(diagnostics->'legacyNamespaces') = 'object' THEN known_legacy := diagnostics->'legacyNamespaces'; END IF;
    EXCEPTION WHEN invalid_text_representation THEN NULL;
    END;

    IF NOT forced AND v3_exists THEN
        PERFORM set_config('mcpkit.local_result', 'skipped', false);
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
        -- The running app is only allowed a read-only check. PowerShell then
        -- stops it, backs up PostgreSQL, and retries in an applying mode. This
        -- also makes a missing/changed marker race safe.
        IF current_setting('mcpkit.local_force') = 'skip-only' THEN
            PERFORM set_config('mcpkit.local_result', 'needs-apply', false);
            RETURN;
        END IF;
        -- Serialize with UI/other seeders, and keep all FK transfers in the
        -- same transaction. In particular, DELETE on a server would otherwise
        -- cascade into tools, tool mappings and OAuth sessions.
        LOCK TABLE namespaces, mcp_servers, namespace_server_mappings, endpoints,
                   namespace_tool_mappings, tools, oauth_sessions, mcp_request_audit_logs
            IN SHARE ROW EXCLUSIVE MODE;
        CREATE TEMP TABLE mcpkit_legacy_owners (
            owner_id text PRIMARY KEY, namespace_id uuid, namespace_name text, issue text NOT NULL
        ) ON COMMIT DROP;
        CREATE TEMP TABLE mcpkit_candidates (
            server_uuid uuid PRIMARY KEY, origin text NOT NULL, owner_id text
        ) ON COMMIT DROP;
        CREATE TEMP TABLE mcpkit_chosen (
            id text PRIMARY KEY, server_uuid uuid NOT NULL, default_connection boolean NOT NULL
        ) ON COMMIT DROP;

        SELECT count(*) INTO legacy_markers FROM config c
        WHERE starts_with(c.id, legacy_prefix) AND right(c.id, length(host_id) + 1) = ':' || host_id;
        FOR owner_row IN SELECT u.id FROM users u
            WHERE EXISTS (SELECT 1 FROM config c WHERE c.id = legacy_prefix || u.id || ':' || host_id)
        LOOP
            -- On retry a successfully promoted V1 namespace is already
            -- public. Remember its UUID so we can still copy its restrictions
            -- and never adopt a replacement merely because its name matches.
            SELECT count(*), min(n.uuid::text)::uuid, min(n.name)
            INTO namespace_matches, old_namespace_id, old_namespace_name
            FROM namespaces n
            WHERE n.name IN (base_name, base_name || '-' || substr(md5(owner_row.id), 1, 8))
              AND ((known_legacy ? owner_row.id AND n.uuid::text = known_legacy->>owner_row.id
                    AND (n.user_id = owner_row.id OR n.user_id IS NULL))
                   OR (NOT (known_legacy ? owner_row.id) AND n.user_id = owner_row.id));
            IF namespace_matches = 1 THEN
                known_legacy := jsonb_set(known_legacy, ARRAY[owner_row.id], to_jsonb(old_namespace_id::text), true);
            END IF;
            old_issue := 'ok';
            IF namespace_matches = 0 THEN
                old_issue := 'missing';
            ELSIF namespace_matches <> 1 THEN
                old_issue := 'unsafe';
                old_namespace_id := NULL;
            ELSIF EXISTS (SELECT 1 FROM endpoints e WHERE e.namespace_uuid = old_namespace_id
                          AND NOT e.enable_api_key_auth AND NOT e.enable_oauth) THEN
                old_issue := 'unsafe';
            ELSIF NOT EXISTS (SELECT 1 FROM endpoints e WHERE e.name = old_namespace_name) THEN
                old_issue := 'missing';
            ELSIF NOT EXISTS (
                SELECT 1 FROM endpoints e WHERE e.name = old_namespace_name AND e.namespace_uuid = old_namespace_id
                  AND (e.user_id = owner_row.id OR (e.user_id IS NULL AND known_legacy->>owner_row.id = old_namespace_id::text))
                  AND e.enable_api_key_auth AND NOT e.enable_oauth
                  AND NOT e.use_query_param_auth AND NOT e.enable_max_rate
                  AND NOT e.enable_client_max_rate AND NOT e.enable_metamcp_admin_tools
            ) THEN
                old_issue := 'unsafe';
            END IF;
            INSERT INTO mcpkit_legacy_owners VALUES (owner_row.id, old_namespace_id, old_namespace_name, old_issue);
        END LOOP;
        SELECT count(*) INTO legacy_owners FROM mcpkit_legacy_owners;

        -- Each official name has exactly one shared server. Only records with
        -- the old kit's marker and name are candidates for in-place migration;
        -- unknown/foreign same-name or same-URL records are never deleted.
        FOR item IN SELECT * FROM (VALUES
            ('desktop-commander', 'Desktop Commander', 'desktop'),
            ('everything-search', 'Everything Search', 'everything'),
            ('filesystem', 'Filesystem MCP', 'filesystem'),
            ('windows-mcp', 'Windows MCP', 'windows'),
            ('git', 'Git MCP', 'git'),
            ('codegraph', 'CodeGraph', 'codegraph'),
            ('codebase-memory-mcp', 'Codebase Memory MCP', 'codebase'),
            ('serena', 'Serena', 'serena'),
            ('playwright', 'Playwright MCP', 'playwright'),
            ('dbhub', 'DBHub', 'dbhub'),
            ('simple-files-vectorstore', 'Simple Files Vectorstore', 'vectorstore'),
            ('markitdown', 'MarkItDown', 'markitdown'),
            ('obsidian', 'Obsidian MCP', 'obsidian')
        ) AS defaults(id, description, v2_alias)
        LOOP
            old_public_name := 'winpub-' || substr(md5(host_id), 1, 8) || '-' || item.v2_alias;
            target_url := base_url || '/servers/' || item.id || '/mcp';
            TRUNCATE mcpkit_candidates;
            INSERT INTO mcpkit_candidates
            SELECT s.uuid, CASE WHEN s.user_id IS NOT NULL THEN 'v1'
                                WHEN s.name = item.id THEN 'short' ELSE 'v2' END, s.user_id
            FROM mcp_servers s
            WHERE (s.user_id IS NULL AND (s.name = item.id OR (v2_exists AND s.name = old_public_name)))
               OR EXISTS (
                    SELECT 1 FROM mcpkit_legacy_owners l WHERE l.owner_id = s.user_id
                      AND s.name IN (item.id, base_name || '-' || item.id,
                                     base_name || '-' || substr(md5(l.owner_id), 1, 8) || '-' || item.id)
               );
            SELECT count(*) INTO candidate_count FROM mcpkit_candidates;
            IF EXISTS (
                SELECT 1 FROM mcp_servers s
                WHERE (s.name = item.id OR s.url = target_url OR (v2_exists AND s.name = old_public_name))
                  AND NOT EXISTS (SELECT 1 FROM mcpkit_candidates c WHERE c.server_uuid = s.uuid)
            ) THEN
                conflicts := array_append(conflicts, 'server:' || item.id);
                CONTINUE;
            END IF;
            IF candidate_count = 0 THEN
                -- Do not resurrect a deliberately deleted V1/V2 record on an
                -- automatic upgrade; an explicit seed can restore defaults.
                IF NOT forced AND (legacy_markers > 0 OR v2_exists) THEN
                    deferred := array_append(deferred, item.id);
                    CONTINUE;
                END IF;
                INSERT INTO mcp_servers (name, description, type, command, args, env, url, headers, user_id)
                VALUES (item.id, item.description, 'STREAMABLE_HTTP', NULL, ARRAY[]::text[], '{}'::jsonb,
                        target_url, jsonb_build_object('X-API-Key', gateway_key), NULL)
                RETURNING uuid INTO server_id;
            ELSE
                -- Publishing a customized *private* connection could expose
                -- secrets or a different service to every MetaMCP user.
                IF EXISTS (
                    SELECT 1 FROM mcp_servers s JOIN mcpkit_candidates c ON c.server_uuid = s.uuid
                    WHERE c.origin = 'v1' AND (s.type <> 'STREAMABLE_HTTP' OR s.command IS NOT NULL
                      OR s.url IS DISTINCT FROM target_url OR s.args <> ARRAY[]::text[] OR s.env <> '{}'::jsonb
                      OR s.bearer_token IS NOT NULL OR s.headers IS DISTINCT FROM jsonb_build_object('X-API-Key', gateway_key)
                      OR s.forward_headers <> '{}'::jsonb)
                ) OR EXISTS (
                    -- A foreign short-name record is only adopted if it has
                    -- the exact kit connection. V3-owned edits are retained.
                    SELECT 1 FROM mcp_servers s JOIN mcpkit_candidates c ON c.server_uuid = s.uuid
                    WHERE c.origin = 'short' AND s.uuid::text IS DISTINCT FROM known_servers->>item.id
                      AND (s.type <> 'STREAMABLE_HTTP' OR s.command IS NOT NULL OR s.url IS DISTINCT FROM target_url
                           OR s.args <> ARRAY[]::text[] OR s.env <> '{}'::jsonb OR s.bearer_token IS NOT NULL
                           OR s.headers IS DISTINCT FROM jsonb_build_object('X-API-Key', gateway_key)
                           OR s.forward_headers <> '{}'::jsonb)
                ) THEN
                    conflicts := array_append(conflicts, 'server:' || item.id);
                    CONTINUE;
                END IF;
                -- Prefer an existing short-name UUID, otherwise the oldest V1
                -- UUID so the old endpoint and its settings keep their IDs.
                SELECT s.uuid INTO server_id FROM mcp_servers s JOIN mcpkit_candidates c ON c.server_uuid = s.uuid
                ORDER BY CASE WHEN c.origin = 'short' THEN 0 WHEN c.origin = 'v1' THEN 1 ELSE 2 END,
                         s.created_at, s.uuid LIMIT 1;
                IF EXISTS (
                    SELECT 1 FROM mcp_servers s JOIN mcpkit_candidates c ON c.server_uuid = s.uuid
                    JOIN mcp_servers keep ON keep.uuid = server_id
                    WHERE ROW(s.type, s.command, s.args, s.env, s.url, s.bearer_token, s.headers, s.forward_headers)
                      IS DISTINCT FROM ROW(keep.type, keep.command, keep.args, keep.env, keep.url,
                                           keep.bearer_token, keep.headers, keep.forward_headers)
                ) THEN
                    conflicts := array_append(conflicts, 'server:' || item.id);
                    CONTINUE;
                END IF;
                SELECT count(DISTINCT COALESCE(to_jsonb(s.description), 'null'::jsonb)) INTO description_count
                FROM mcp_servers s JOIN mcpkit_candidates c ON c.server_uuid = s.uuid
                WHERE s.description IS DISTINCT FROM item.description;
                IF description_count > 1 THEN
                    conflicts := array_append(conflicts, 'server:' || item.id);
                    CONTINUE;
                END IF;
                SELECT s.description INTO merged_description FROM mcp_servers s
                JOIN mcpkit_candidates c ON c.server_uuid = s.uuid
                WHERE s.description IS DISTINCT FROM item.description ORDER BY s.created_at, s.uuid LIMIT 1;
                IF NOT FOUND THEN SELECT description INTO merged_description FROM mcp_servers WHERE uuid = server_id; END IF;
                SELECT EXISTS (SELECT 1 FROM mcp_servers s JOIN mcpkit_candidates c ON c.server_uuid = s.uuid
                               WHERE s.error_status = 'ERROR') INTO any_error;

                -- A mismatched tool/server reference is ambiguous even when
                -- there is only one candidate; do not copy its restrictions.
                IF EXISTS (SELECT 1 FROM namespace_tool_mappings tm JOIN tools t ON t.uuid = tm.tool_uuid
                           WHERE (tm.mcp_server_uuid IN (SELECT server_uuid FROM mcpkit_candidates)
                                  OR t.mcp_server_uuid IN (SELECT server_uuid FROM mcpkit_candidates))
                             AND tm.mcp_server_uuid <> t.mcp_server_uuid) THEN
                    conflicts := array_append(conflicts, 'server:' || item.id);
                    CONTINUE;
                END IF;
                IF candidate_count > 1 AND (
                    -- Unknown schema extensions may have their own cascade
                    -- FKs. Do not delete anything we cannot transfer safely.
                    EXISTS (SELECT 1 FROM pg_constraint c WHERE c.contype = 'f' AND (
                        (c.confrelid = 'mcp_servers'::regclass AND NOT (
                            c.conrelid IN ('tools'::regclass, 'oauth_sessions'::regclass, 'namespace_server_mappings'::regclass,
                                           'namespace_tool_mappings'::regclass, 'mcp_request_audit_logs'::regclass)
                            AND cardinality(c.conkey) = 1 AND cardinality(c.confkey) = 1
                            AND (SELECT a.attname FROM pg_attribute a WHERE a.attrelid = c.conrelid AND a.attnum = c.conkey[1]) = 'mcp_server_uuid'
                            AND (SELECT a.attname FROM pg_attribute a WHERE a.attrelid = c.confrelid AND a.attnum = c.confkey[1]) = 'uuid'
                        )) OR
                        (c.confrelid = 'tools'::regclass AND NOT (
                            c.conrelid = 'namespace_tool_mappings'::regclass
                            AND cardinality(c.conkey) = 1 AND cardinality(c.confkey) = 1
                            AND (SELECT a.attname FROM pg_attribute a WHERE a.attrelid = c.conrelid AND a.attnum = c.conkey[1]) = 'tool_uuid'
                            AND (SELECT a.attname FROM pg_attribute a WHERE a.attrelid = c.confrelid AND a.attnum = c.confkey[1]) = 'uuid'
                        )) OR c.confrelid IN ('namespace_server_mappings'::regclass, 'namespace_tool_mappings'::regclass)
                    )) OR
                    (SELECT count(*) FROM oauth_sessions o JOIN mcpkit_candidates c ON c.server_uuid = o.mcp_server_uuid) > 1 OR
                    EXISTS (SELECT 1 FROM tools t JOIN mcpkit_candidates c ON c.server_uuid = t.mcp_server_uuid
                            GROUP BY t.name HAVING count(DISTINCT ROW(t.description, t.tool_schema)) > 1) OR
                    EXISTS (SELECT 1 FROM namespace_server_mappings m JOIN mcpkit_candidates c ON c.server_uuid = m.mcp_server_uuid
                            GROUP BY m.namespace_uuid HAVING count(DISTINCT m.status) > 1) OR
                    EXISTS (SELECT 1 FROM namespace_tool_mappings tm JOIN tools t ON t.uuid = tm.tool_uuid
                            JOIN mcpkit_candidates c ON c.server_uuid = t.mcp_server_uuid
                            GROUP BY tm.namespace_uuid, t.name
                            HAVING count(DISTINCT ROW(tm.status, tm.override_name, tm.override_title,
                                                      tm.override_description, tm.override_annotations)) > 1)
                ) THEN
                    conflicts := array_append(conflicts, 'server:' || item.id);
                    CONTINUE;
                END IF;

                FOR candidate IN SELECT c.server_uuid FROM mcpkit_candidates c WHERE c.server_uuid <> server_id ORDER BY c.server_uuid LOOP
                    FOR tool IN SELECT t.uuid, t.name FROM tools t WHERE t.mcp_server_uuid = candidate.server_uuid ORDER BY t.uuid LOOP
                        SELECT t.uuid INTO secondary_tool_id FROM tools t WHERE t.mcp_server_uuid = server_id AND t.name = tool.name;
                        IF secondary_tool_id IS NULL THEN
                            UPDATE tools SET mcp_server_uuid = server_id WHERE uuid = tool.uuid;
                            UPDATE namespace_tool_mappings SET mcp_server_uuid = server_id WHERE tool_uuid = tool.uuid;
                        ELSE
                            -- Preflight above established equality before any
                            -- colliding per-namespace mapping is discarded.
                            DELETE FROM namespace_tool_mappings duplicate USING namespace_tool_mappings keep
                            WHERE duplicate.tool_uuid = tool.uuid AND keep.tool_uuid = secondary_tool_id
                              AND duplicate.namespace_uuid = keep.namespace_uuid;
                            UPDATE namespace_tool_mappings SET tool_uuid = secondary_tool_id, mcp_server_uuid = server_id
                            WHERE tool_uuid = tool.uuid;
                            DELETE FROM tools WHERE uuid = tool.uuid;
                        END IF;
                    END LOOP;
                    DELETE FROM namespace_server_mappings duplicate USING namespace_server_mappings keep
                    WHERE duplicate.mcp_server_uuid = candidate.server_uuid AND keep.mcp_server_uuid = server_id
                      AND duplicate.namespace_uuid = keep.namespace_uuid;
                    UPDATE namespace_server_mappings SET mcp_server_uuid = server_id WHERE mcp_server_uuid = candidate.server_uuid;
                    UPDATE oauth_sessions SET mcp_server_uuid = server_id WHERE mcp_server_uuid = candidate.server_uuid;
                    -- Keep the historical server name in the audit row.
                    UPDATE mcp_request_audit_logs SET mcp_server_uuid = server_id WHERE mcp_server_uuid = candidate.server_uuid;
                    DELETE FROM mcp_servers WHERE uuid = candidate.server_uuid;
                END LOOP;
                UPDATE mcp_servers SET name = item.id, user_id = NULL, description = merged_description,
                    error_status = CASE WHEN any_error THEN 'ERROR'::mcp_server_error_status ELSE error_status END
                WHERE uuid = server_id;
            END IF;
            SELECT s.type = 'STREAMABLE_HTTP' AND s.command IS NULL AND s.url = target_url
                AND s.args = ARRAY[]::text[] AND s.env = '{}'::jsonb AND s.bearer_token IS NULL
                AND s.headers = jsonb_build_object('X-API-Key', gateway_key) AND s.forward_headers = '{}'::jsonb
            INTO default_connection FROM mcp_servers s WHERE s.uuid = server_id;
            INSERT INTO mcpkit_chosen VALUES (item.id, server_id, default_connection);
            known_servers := jsonb_set(known_servers, ARRAY[item.id], to_jsonb(server_id::text), true);
        END LOOP;

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
            SELECT count(*), min(n.uuid::text)::uuid INTO namespace_matches, namespace_id
            FROM namespaces n WHERE n.name = group_name AND n.user_id IS NULL;
            IF namespace_matches > 1 OR EXISTS (SELECT 1 FROM namespaces n WHERE n.name = group_name AND n.user_id IS NOT NULL) THEN
                conflicts := array_append(conflicts, 'namespace:' || group_name);
                CONTINUE;
            END IF;
            IF namespace_id IS NULL THEN
                -- An initialized V2 database may have deliberately deleted a
                -- group. Automatic V3 migration must not recreate it.
                IF v2_exists AND NOT forced THEN CONTINUE; END IF;
                IF EXISTS (SELECT 1 FROM endpoints e WHERE e.name = group_name) THEN
                    conflicts := array_append(conflicts, 'endpoint:' || group_name);
                    CONTINUE;
                END IF;
                INSERT INTO namespaces (name, description, user_id) VALUES (group_name, group_spec.description, NULL)
                RETURNING uuid INTO namespace_id;
                known_namespaces := jsonb_set(known_namespaces, ARRAY[group_spec.suffix], to_jsonb(namespace_id::text), true);
            END IF;
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
                IF v2_exists AND NOT forced THEN CONTINUE; END IF;
                INSERT INTO endpoints (name, description, namespace_uuid, enable_api_key_auth, user_id)
                VALUES (group_name, group_spec.description, namespace_id, true, NULL);
            END IF;

            FOREACH old_public_name IN ARRAY group_spec.servers LOOP
                SELECT chosen.server_uuid, chosen.default_connection INTO server_id, default_connection
                FROM mcpkit_chosen chosen WHERE chosen.id = old_public_name;
                IF server_id IS NULL THEN CONTINUE; END IF;
                IF EXISTS (SELECT 1 FROM namespace_server_mappings m WHERE m.namespace_uuid = namespace_id AND m.mcp_server_uuid = server_id) THEN
                    CONTINUE; -- includes inactive or customized existing mappings
                END IF;
                IF v2_exists AND NOT forced THEN
                    deferred := array_append(deferred, old_public_name);
                    CONTINUE;
                END IF;
                IF NOT default_connection THEN
                    conflicts := array_append(conflicts, 'server:' || old_public_name);
                    CONTINUE;
                END IF;
                -- A changed/open legacy endpoint is never bypassed. Missing
                -- old records require explicit seed; inactive mappings and
                -- tool overrides are carried to the new group instead.
                IF EXISTS (SELECT 1 FROM mcpkit_legacy_owners l WHERE l.issue = 'unsafe')
                   OR (NOT forced AND (legacy_markers <> legacy_owners OR EXISTS (
                        SELECT 1 FROM mcpkit_legacy_owners l WHERE l.issue <> 'ok' OR NOT EXISTS (
                            SELECT 1 FROM namespace_server_mappings m
                            WHERE m.namespace_uuid = l.namespace_id AND m.mcp_server_uuid = server_id
                        )
                   ))) THEN
                    deferred := array_append(deferred, old_public_name);
                    CONTINUE;
                END IF;
                -- Different per-owner overrides cannot be represented by one
                -- shared group. Preserve each old namespace and ask for review.
                IF EXISTS (
                    SELECT 1 FROM tools t CROSS JOIN mcpkit_legacy_owners l
                    LEFT JOIN namespace_tool_mappings tm ON tm.namespace_uuid = l.namespace_id
                        AND tm.tool_uuid = t.uuid AND tm.mcp_server_uuid = server_id
                    WHERE t.mcp_server_uuid = server_id GROUP BY t.uuid
                    HAVING count(DISTINCT ROW(tm.override_name, tm.override_title,
                                              tm.override_description, tm.override_annotations)) > 1
                ) THEN
                    deferred := array_append(deferred, old_public_name);
                    CONTINUE;
                END IF;
                link_status := CASE WHEN EXISTS (
                    SELECT 1 FROM mcpkit_legacy_owners l JOIN namespace_server_mappings m ON m.namespace_uuid = l.namespace_id
                    WHERE m.mcp_server_uuid = server_id AND m.status = 'INACTIVE'
                ) THEN 'INACTIVE'::mcp_server_status ELSE 'ACTIVE'::mcp_server_status END;
                -- If a dangling target tool mapping already exists, do not
                -- overwrite it or make a legacy-disabled tool active there.
                can_link := true;
                FOR tool IN SELECT t.uuid FROM tools t WHERE t.mcp_server_uuid = server_id LOOP
                    tool_status := CASE WHEN EXISTS (
                        SELECT 1 FROM mcpkit_legacy_owners l JOIN namespace_tool_mappings tm ON tm.namespace_uuid = l.namespace_id
                        WHERE tm.tool_uuid = tool.uuid AND tm.mcp_server_uuid = server_id AND tm.status = 'INACTIVE'
                    ) THEN 'INACTIVE'::mcp_server_status ELSE 'ACTIVE'::mcp_server_status END;
                    SELECT tm.override_name, tm.override_title, tm.override_description, tm.override_annotations
                    INTO override_name, override_title, override_description, override_annotations
                    FROM mcpkit_legacy_owners l LEFT JOIN namespace_tool_mappings tm
                        ON tm.namespace_uuid = l.namespace_id AND tm.tool_uuid = tool.uuid AND tm.mcp_server_uuid = server_id
                    ORDER BY l.owner_id LIMIT 1;
                    SELECT tm.* INTO target_mapping FROM namespace_tool_mappings tm
                    WHERE tm.namespace_uuid = namespace_id AND tm.tool_uuid = tool.uuid;
                    IF FOUND AND ((tool_status = 'INACTIVE' AND target_mapping.status <> 'INACTIVE') OR
                        ROW(target_mapping.override_name, target_mapping.override_title, target_mapping.override_description, target_mapping.override_annotations)
                        IS DISTINCT FROM ROW(override_name, override_title, override_description, override_annotations)) THEN
                        can_link := false;
                        EXIT;
                    END IF;
                END LOOP;
                IF NOT can_link THEN
                    deferred := array_append(deferred, old_public_name);
                    CONTINUE;
                END IF;
                INSERT INTO namespace_server_mappings (namespace_uuid, mcp_server_uuid, status)
                VALUES (namespace_id, server_id, link_status) ON CONFLICT (namespace_uuid, mcp_server_uuid) DO NOTHING;
                FOR tool IN SELECT t.uuid FROM tools t WHERE t.mcp_server_uuid = server_id LOOP
                    tool_status := CASE WHEN EXISTS (
                        SELECT 1 FROM mcpkit_legacy_owners l JOIN namespace_tool_mappings tm ON tm.namespace_uuid = l.namespace_id
                        WHERE tm.tool_uuid = tool.uuid AND tm.mcp_server_uuid = server_id AND tm.status = 'INACTIVE'
                    ) THEN 'INACTIVE'::mcp_server_status ELSE 'ACTIVE'::mcp_server_status END;
                    SELECT tm.override_name, tm.override_title, tm.override_description, tm.override_annotations
                    INTO override_name, override_title, override_description, override_annotations
                    FROM mcpkit_legacy_owners l LEFT JOIN namespace_tool_mappings tm
                        ON tm.namespace_uuid = l.namespace_id AND tm.tool_uuid = tool.uuid AND tm.mcp_server_uuid = server_id
                    ORDER BY l.owner_id LIMIT 1;
                    INSERT INTO namespace_tool_mappings (namespace_uuid, tool_uuid, mcp_server_uuid, status,
                                                         override_name, override_title, override_description, override_annotations)
                    VALUES (namespace_id, tool.uuid, server_id, tool_status,
                            override_name, override_title, override_description, override_annotations)
                    ON CONFLICT (namespace_uuid, tool_uuid) DO NOTHING;
                END LOOP;
            END LOOP;
        END LOOP;

        -- The old endpoint URL and namespace UUID can also be made shared
        -- without replacing them, but only if doing so does not publish extra
        -- foreign servers or an unauthenticated endpoint.
        FOR old IN SELECT * FROM mcpkit_legacy_owners LOOP
            IF old.namespace_id IS NULL THEN CONTINUE; END IF;
            IF EXISTS (SELECT 1 FROM endpoints e WHERE e.namespace_uuid = old.namespace_id
                       AND NOT e.enable_api_key_auth AND NOT e.enable_oauth) THEN
                blocked := array_append(blocked, old.namespace_name);
                CONTINUE;
            END IF;
            IF EXISTS (SELECT 1 FROM namespaces n WHERE n.name = old.namespace_name AND n.uuid <> old.namespace_id)
               OR NOT EXISTS (SELECT 1 FROM endpoints e WHERE e.name = old.namespace_name AND e.namespace_uuid = old.namespace_id
                              AND (e.user_id = old.owner_id OR e.user_id IS NULL)
                              AND (e.enable_api_key_auth OR e.enable_oauth))
               OR EXISTS (SELECT 1 FROM namespace_server_mappings m WHERE m.namespace_uuid = old.namespace_id
                          AND m.mcp_server_uuid NOT IN (SELECT server_uuid FROM mcpkit_chosen))
               OR EXISTS (SELECT 1 FROM namespace_tool_mappings tm WHERE tm.namespace_uuid = old.namespace_id
                          AND tm.mcp_server_uuid NOT IN (SELECT server_uuid FROM mcpkit_chosen)) THEN
                conflicts := array_append(conflicts, 'namespace:' || old.namespace_name);
                CONTINUE;
            END IF;
            UPDATE namespaces SET user_id = NULL WHERE uuid = old.namespace_id AND user_id = old.owner_id;
            UPDATE endpoints SET user_id = NULL WHERE name = old.namespace_name AND namespace_uuid = old.namespace_id AND user_id = old.owner_id;
        END LOOP;

        -- Sort/deduplicate diagnostics, but keep them until an explicit retry.
        SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), ARRAY[]::text[]) INTO blocked FROM unnest(blocked) x WHERE x IS NOT NULL;
        SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), ARRAY[]::text[]) INTO conflicts FROM unnest(conflicts) x WHERE x IS NOT NULL;
        SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), ARRAY[]::text[]) INTO deferred FROM unnest(deferred) x WHERE x IS NOT NULL;
        INSERT INTO config (id, value, description)
        VALUES (marker, jsonb_build_object('blocked', array_to_string(blocked, ','),
                                          'conflicts', array_to_string(conflicts, ','),
                                          'deferred', array_to_string(deferred, ','),
                                          'namespaces', known_namespaces, 'servers', known_servers,
                                          'legacyNamespaces', known_legacy)::text,
                'Shared Windows LOCAL short-name migration initialized by multfinite-mcp-kit')
        ON CONFLICT (id) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
        PERFORM set_config('mcpkit.local_result', 'seeded', false);
        PERFORM set_config('mcpkit.local_blocked', array_to_string(blocked, ','), false);
        PERFORM set_config('mcpkit.local_conflicts', array_to_string(conflicts, ','), false);
        PERFORM set_config('mcpkit.local_deferred', array_to_string(deferred, ','), false);
    END IF;

    -- Warn about a group endpoint opened after the initial migration as well.
    SELECT string_agg(DISTINCT b.name, ',' ORDER BY b.name) INTO current_blocked FROM (
        SELECT unnest(string_to_array(current_setting('mcpkit.local_blocked'), ',')) AS name
        UNION ALL
        SELECT n.name FROM namespaces n JOIN endpoints e ON e.namespace_uuid = n.uuid
        WHERE n.user_id IS NULL AND n.name IN (base_name || '-system', base_name || '-files', base_name || '-code',
                                               base_name || '-web', base_name || '-data', base_name || '-memory')
          AND NOT e.enable_api_key_auth AND NOT e.enable_oauth
    ) b WHERE b.name <> '';
    PERFORM set_config('mcpkit.local_blocked', COALESCE(current_blocked, ''), false);
    SELECT string_agg(e.name, ',' ORDER BY e.name) INTO available_groups
    FROM endpoints e JOIN namespaces n ON n.uuid = e.namespace_uuid
    WHERE e.name IN (base_name || '-system', base_name || '-files', base_name || '-code',
                     base_name || '-web', base_name || '-data', base_name || '-memory')
      AND n.name = e.name AND n.user_id IS NULL AND e.user_id IS NULL
      AND n.uuid::text = known_namespaces->>substr(n.name, length(base_name) + 2)
      AND (e.enable_api_key_auth OR e.enable_oauth)
      AND NOT EXISTS (SELECT 1 FROM namespaces other WHERE other.name = n.name AND other.uuid <> n.uuid)
      AND NOT EXISTS (SELECT 1 FROM endpoints open_endpoint WHERE open_endpoint.namespace_uuid = n.uuid
                      AND NOT open_endpoint.enable_api_key_auth AND NOT open_endpoint.enable_oauth);
    PERFORM set_config('mcpkit.local_groups', COALESCE(available_groups, ''), false);
END
$seed$;
COMMIT;
SELECT current_setting('mcpkit.local_result') || '|' || current_setting('mcpkit.local_owner') || '|' ||
       current_setting('mcpkit.local_groups') || '|' || current_setting('mcpkit.local_blocked') || '|' ||
       current_setting('mcpkit.local_conflicts') || '|' || current_setting('mcpkit.local_deferred');
