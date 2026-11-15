-- Only used to convert a completed grouped independent LOCAL/GLOBAL registration.
-- The manifest is validated, secret-free JSON encoded as base64 by the caller.
-- Preflight and apply use the same checks under locks; no records are deleted.
-- Existing groups retain all mappings; additional single-server endpoints copy
-- the status/overrides and auth settings of their designated source group.
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL search_path = pg_catalog, public;
LOCK TABLE public.mcp_servers, public.namespaces, public.namespace_server_mappings,
           public.namespace_tool_mappings, public.tools, public.endpoints
    IN SHARE ROW EXCLUSIVE MODE;

DO $share$
DECLARE
    manifest jsonb := convert_from(decode('__MCPKIT_BUNDLE_BASE64__', 'base64'), 'UTF8')::jsonb;
    owner_id text := manifest->>'owner';
    apply_change boolean := (manifest->>'apply')::boolean;
    item record;
    expected_servers uuid[];
    actual_servers uuid[];
    affected integer;
BEGIN
    -- Do not write target tables with unknown, non-PostgreSQL-internal triggers.
    IF EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname IN ('mcp_servers', 'namespaces', 'endpoints', 'namespace_server_mappings', 'namespace_tool_mappings')
          AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION 'Unexpected trigger on a target table; no records changed';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_rewrite r
        JOIN pg_class c ON c.oid = r.ev_class
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname IN ('mcp_servers', 'namespaces', 'endpoints', 'namespace_server_mappings', 'namespace_tool_mappings')
          AND r.rulename <> '_RETURN' AND r.ev_enabled <> 'D'
    ) OR EXISTS (
        SELECT 1 FROM pg_constraint f
        JOIN pg_class c ON c.oid = f.confrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(f.confkey)
        WHERE f.contype = 'f' AND n.nspname = 'public'
          AND c.relname IN ('mcp_servers', 'namespaces', 'endpoints')
          AND a.attname IN ('name', 'user_id') AND f.confupdtype IN ('c', 'n', 'd')
    ) THEN
        RAISE EXCEPTION 'Unexpected update rule or cascading reference; no records changed';
    END IF;

    FOR item IN SELECT * FROM jsonb_to_recordset(manifest->'servers') AS r(uuid uuid, old_name text, name text)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM public.mcp_servers s
            WHERE s.uuid = item.uuid AND s.name IN (item.old_name, item.name)
              AND (s.user_id = owner_id OR s.user_id IS NULL)
        ) THEN
            RAISE EXCEPTION 'A registered server is missing, renamed, or has another owner; no records changed';
        END IF;
        -- PostgreSQL UNIQUE(name,user_id) allows duplicate NULL owners.
        IF EXISTS (
            SELECT 1 FROM public.mcp_servers s
            WHERE s.name = item.name AND s.uuid <> item.uuid
        ) THEN
            RAISE EXCEPTION 'Another server already has the target name %; no records changed', item.name;
        END IF;
    END LOOP;

    FOR item IN SELECT * FROM jsonb_to_recordset(manifest->'namespaces') AS r(uuid uuid, old_name text, previous_name text, name text, servers jsonb)
    LOOP
        -- An official target name means this conversion may already have
        -- committed. Stop rather than recreating a deliberately removed pair.
        IF NOT EXISTS (
            SELECT 1 FROM public.namespaces n
            WHERE n.uuid = item.uuid AND n.name IN (item.old_name, item.previous_name)
              AND (n.user_id = owner_id OR n.user_id IS NULL)
        ) THEN
            RAISE EXCEPTION 'A registered namespace is missing, already converted, renamed, or has another owner; no records changed';
        END IF;
        IF EXISTS (
            SELECT 1 FROM public.namespaces n
            WHERE n.name = item.name AND n.uuid <> item.uuid
        ) THEN
            RAISE EXCEPTION 'Another namespace already has the target name %; no records changed', item.name;
        END IF;
        SELECT COALESCE(array_agg(v::uuid ORDER BY v::uuid), ARRAY[]::uuid[])
        INTO expected_servers FROM jsonb_array_elements_text(item.servers) AS x(v);
        SELECT COALESCE(array_agg(m.mcp_server_uuid ORDER BY m.mcp_server_uuid), ARRAY[]::uuid[])
        INTO actual_servers FROM public.namespace_server_mappings m WHERE m.namespace_uuid = item.uuid;
        IF actual_servers IS DISTINCT FROM expected_servers THEN
            RAISE EXCEPTION 'A registered namespace has changed server membership; no records changed';
        END IF;
        IF EXISTS (
            SELECT 1 FROM public.namespace_tool_mappings m
            LEFT JOIN public.tools t ON t.uuid = m.tool_uuid
            WHERE m.namespace_uuid = item.uuid
              AND (NOT (m.mcp_server_uuid = ANY(expected_servers))
                   OR t.uuid IS NULL OR t.mcp_server_uuid IS DISTINCT FROM m.mcp_server_uuid)
        ) THEN
            RAISE EXCEPTION 'A registered namespace has unexpected tool mappings; no records changed';
        END IF;
        IF EXISTS (
            SELECT 1 FROM public.endpoints e
            WHERE e.namespace_uuid = item.uuid AND NOT e.enable_api_key_auth AND NOT e.enable_oauth
        ) THEN
            RAISE EXCEPTION 'A registered namespace has an unauthenticated endpoint; no records changed';
        END IF;
    END LOOP;

    FOR item IN SELECT * FROM jsonb_to_recordset(manifest->'endpoints') AS r(uuid uuid, old_name text, previous_name text, name text, namespace_uuid uuid)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM public.endpoints e
            WHERE e.uuid = item.uuid AND e.name IN (item.old_name, item.previous_name) AND e.namespace_uuid = item.namespace_uuid
              AND (e.user_id = owner_id OR e.user_id IS NULL)
              AND e.enable_api_key_auth AND NOT e.enable_metamcp_admin_tools
        ) THEN
            RAISE EXCEPTION 'A registered endpoint is missing, already converted, changed, unprotected, or has another owner; no records changed';
        END IF;
        -- Endpoint names are globally unique, including other users' private ones.
        IF EXISTS (SELECT 1 FROM public.endpoints e WHERE e.name = item.name AND e.uuid <> item.uuid) THEN
            RAISE EXCEPTION 'Another endpoint already has the target name %; no records changed', item.name;
        END IF;
    END LOOP;

    -- Supplemental per-server pairs are new records, never name-based
    -- adoptions. Check all owners, including otherwise invisible endpoints.
    FOR item IN SELECT * FROM jsonb_to_recordset(manifest->'additional') AS r(
        namespace_uuid uuid, endpoint_uuid uuid, name text, server_uuid uuid,
        source_namespace_uuid uuid, source_endpoint_uuid uuid, description text)
    LOOP
        IF EXISTS (SELECT 1 FROM public.namespaces n WHERE n.uuid = item.namespace_uuid OR n.name = item.name) THEN
            RAISE EXCEPTION 'Another namespace already has the target identity or name %; no records changed', item.name;
        END IF;
        IF EXISTS (SELECT 1 FROM public.endpoints e WHERE e.uuid = item.endpoint_uuid OR e.name = item.name) THEN
            RAISE EXCEPTION 'Another endpoint already has the target identity or name %; no records changed', item.name;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.namespace_server_mappings m
            JOIN public.endpoints e ON e.uuid = item.source_endpoint_uuid AND e.namespace_uuid = m.namespace_uuid
            WHERE m.namespace_uuid = item.source_namespace_uuid AND m.mcp_server_uuid = item.server_uuid
              AND e.enable_api_key_auth AND NOT e.enable_metamcp_admin_tools
        ) THEN
            RAISE EXCEPTION 'Source group or protected endpoint for % changed; no records changed', item.name;
        END IF;
    END LOOP;

    IF apply_change THEN
        UPDATE public.mcp_servers AS s SET name = r.name, user_id = NULL
        FROM jsonb_to_recordset(manifest->'servers') AS r(uuid uuid, name text)
        WHERE s.uuid = r.uuid AND (s.name IS DISTINCT FROM r.name OR s.user_id IS NOT NULL);
        UPDATE public.namespaces AS n SET name = r.name, user_id = NULL
        FROM jsonb_to_recordset(manifest->'namespaces') AS r(uuid uuid, name text)
        WHERE n.uuid = r.uuid AND (n.name IS DISTINCT FROM r.name OR n.user_id IS NOT NULL);
        UPDATE public.endpoints AS e SET name = r.name, user_id = NULL
        FROM jsonb_to_recordset(manifest->'endpoints') AS r(uuid uuid, name text)
        WHERE e.uuid = r.uuid AND (e.name IS DISTINCT FROM r.name OR e.user_id IS NOT NULL);

        FOR item IN SELECT * FROM jsonb_to_recordset(manifest->'additional') AS r(
            namespace_uuid uuid, endpoint_uuid uuid, name text, server_uuid uuid,
            source_namespace_uuid uuid, source_endpoint_uuid uuid, description text)
        LOOP
            INSERT INTO public.namespaces (uuid, name, description, user_id)
            VALUES (item.namespace_uuid, item.name, item.description, NULL);

            INSERT INTO public.namespace_server_mappings (namespace_uuid, mcp_server_uuid, status)
            SELECT item.namespace_uuid, m.mcp_server_uuid, m.status
            FROM public.namespace_server_mappings m
            WHERE m.namespace_uuid = item.source_namespace_uuid AND m.mcp_server_uuid = item.server_uuid;
            GET DIAGNOSTICS affected = ROW_COUNT;
            IF affected <> 1 THEN RAISE EXCEPTION 'Source server mapping changed; transaction rolled back'; END IF;

            -- Preserve disabled tools and overrides rather than silently
            -- enabling every tool of an already configured server.
            INSERT INTO public.namespace_tool_mappings (
                namespace_uuid, tool_uuid, mcp_server_uuid, status,
                override_name, override_title, override_description, override_annotations)
            SELECT item.namespace_uuid, m.tool_uuid, m.mcp_server_uuid, m.status,
                   m.override_name, m.override_title, m.override_description, m.override_annotations
            FROM public.namespace_tool_mappings m
            WHERE m.namespace_uuid = item.source_namespace_uuid AND m.mcp_server_uuid = item.server_uuid;

            INSERT INTO public.endpoints (
                uuid, name, description, namespace_uuid, user_id,
                enable_api_key_auth, enable_oauth, enable_max_rate, enable_client_max_rate,
                max_rate, max_rate_seconds, client_max_rate, client_max_rate_seconds,
                client_max_rate_strategy, client_max_rate_strategy_key,
                use_query_param_auth, enable_metamcp_admin_tools)
            SELECT item.endpoint_uuid, item.name, item.description, item.namespace_uuid, NULL,
                   e.enable_api_key_auth, e.enable_oauth, e.enable_max_rate, e.enable_client_max_rate,
                   e.max_rate, e.max_rate_seconds, e.client_max_rate, e.client_max_rate_seconds,
                   e.client_max_rate_strategy, e.client_max_rate_strategy_key,
                   e.use_query_param_auth, e.enable_metamcp_admin_tools
            FROM public.endpoints e WHERE e.uuid = item.source_endpoint_uuid;
            GET DIAGNOSTICS affected = ROW_COUNT;
            IF affected <> 1 THEN RAISE EXCEPTION 'Source endpoint changed; transaction rolled back'; END IF;
        END LOOP;

        IF EXISTS (
            SELECT 1 FROM public.mcp_servers s JOIN jsonb_to_recordset(manifest->'servers') AS r(uuid uuid, name text) ON s.uuid = r.uuid
            WHERE s.user_id IS NOT NULL OR s.name IS DISTINCT FROM r.name
        ) OR EXISTS (
            SELECT 1 FROM public.namespaces n JOIN jsonb_to_recordset(manifest->'namespaces') AS r(uuid uuid, name text) ON n.uuid = r.uuid
            WHERE n.user_id IS NOT NULL OR n.name IS DISTINCT FROM r.name
        ) OR EXISTS (
            SELECT 1 FROM public.endpoints e JOIN jsonb_to_recordset(manifest->'endpoints') AS r(uuid uuid, name text) ON e.uuid = r.uuid
            WHERE e.user_id IS NOT NULL OR e.name IS DISTINCT FROM r.name
        ) OR EXISTS (
            SELECT 1 FROM jsonb_to_recordset(manifest->'additional') AS r(
                namespace_uuid uuid, endpoint_uuid uuid, name text, server_uuid uuid)
            LEFT JOIN public.namespaces n ON n.uuid = r.namespace_uuid
            LEFT JOIN public.endpoints e ON e.uuid = r.endpoint_uuid
            LEFT JOIN public.namespace_server_mappings m ON m.namespace_uuid = r.namespace_uuid AND m.mcp_server_uuid = r.server_uuid
            WHERE n.uuid IS NULL OR n.name IS DISTINCT FROM r.name OR n.user_id IS NOT NULL
               OR e.uuid IS NULL OR e.name IS DISTINCT FROM r.name OR e.user_id IS NOT NULL
               OR e.namespace_uuid IS DISTINCT FROM r.namespace_uuid OR NOT e.enable_api_key_auth
               OR e.enable_metamcp_admin_tools OR m.uuid IS NULL
        ) THEN
            RAISE EXCEPTION 'Unexpected name, ownership, mapping or authentication after update; transaction rolled back';
        END IF;
    END IF;
END;
$share$;
COMMIT;
SELECT 'MCPKIT_PUBLIC_OK';
