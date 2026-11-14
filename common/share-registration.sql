-- Only used to convert a completed independent LOCAL/GLOBAL registration.
-- The manifest is validated, secret-free JSON encoded as base64 by the caller.
-- Preflight and apply use the same checks under locks; no records are deleted.
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
BEGIN
    -- Do not run an UPDATE with unknown, non-PostgreSQL-internal triggers.
    IF EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname IN ('mcp_servers', 'namespaces', 'endpoints')
          AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION 'Unexpected trigger on a target table; no records changed';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_rewrite r
        JOIN pg_class c ON c.oid = r.ev_class
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname IN ('mcp_servers', 'namespaces', 'endpoints')
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

    FOR item IN SELECT * FROM jsonb_to_recordset(manifest->'namespaces') AS r(uuid uuid, old_name text, name text, servers jsonb)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM public.namespaces n
            WHERE n.uuid = item.uuid AND n.name IN (item.old_name, item.name)
              AND (n.user_id = owner_id OR n.user_id IS NULL)
        ) THEN
            RAISE EXCEPTION 'A registered namespace is missing, renamed, or has another owner; no records changed';
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

    FOR item IN SELECT * FROM jsonb_to_recordset(manifest->'endpoints') AS r(uuid uuid, old_name text, name text, namespace_uuid uuid)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM public.endpoints e
            WHERE e.uuid = item.uuid AND e.name IN (item.old_name, item.name) AND e.namespace_uuid = item.namespace_uuid
              AND (e.user_id = owner_id OR e.user_id IS NULL)
              AND e.enable_api_key_auth AND NOT e.enable_metamcp_admin_tools
        ) THEN
            RAISE EXCEPTION 'A registered endpoint is missing, changed, unprotected, or has another owner; no records changed';
        END IF;
        -- Endpoint names are globally unique, including other users' private ones.
        IF EXISTS (SELECT 1 FROM public.endpoints e WHERE e.name = item.name AND e.uuid <> item.uuid) THEN
            RAISE EXCEPTION 'Another endpoint already has the target name %; no records changed', item.name;
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
        IF EXISTS (
            SELECT 1 FROM public.mcp_servers s JOIN jsonb_to_recordset(manifest->'servers') AS r(uuid uuid, name text) ON s.uuid = r.uuid
            WHERE s.user_id IS NOT NULL OR s.name IS DISTINCT FROM r.name
        ) OR EXISTS (
            SELECT 1 FROM public.namespaces n JOIN jsonb_to_recordset(manifest->'namespaces') AS r(uuid uuid, name text) ON n.uuid = r.uuid
            WHERE n.user_id IS NOT NULL OR n.name IS DISTINCT FROM r.name
        ) OR EXISTS (
            SELECT 1 FROM public.endpoints e JOIN jsonb_to_recordset(manifest->'endpoints') AS r(uuid uuid, name text) ON e.uuid = r.uuid
            WHERE e.user_id IS NOT NULL OR e.name IS DISTINCT FROM r.name
        ) THEN
            RAISE EXCEPTION 'Unexpected name or ownership after update; transaction rolled back';
        END IF;
    END IF;
END;
$share$;
COMMIT;
SELECT 'MCPKIT_PUBLIC_OK';
