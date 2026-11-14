-- Relevant MetaMCP schema (upstream migrations 0000, 0002 and 0003).
-- Kept local so the seed regression tests do not depend on a live GitHub repo.
CREATE TYPE mcp_server_type AS ENUM ('STDIO', 'SSE', 'STREAMABLE_HTTP');
CREATE TYPE mcp_server_status AS ENUM ('ACTIVE', 'INACTIVE');
CREATE TYPE mcp_server_error_status AS ENUM ('NONE', 'ERROR');

CREATE TABLE users (id text PRIMARY KEY, email text UNIQUE);
CREATE TABLE config (
    id text PRIMARY KEY,
    value text NOT NULL,
    description text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE mcp_servers (
    uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    description text,
    type mcp_server_type NOT NULL DEFAULT 'STDIO',
    command text,
    args text[] NOT NULL DEFAULT '{}'::text[],
    env jsonb NOT NULL DEFAULT '{}'::jsonb,
    url text,
    error_status mcp_server_error_status NOT NULL DEFAULT 'NONE',
    created_at timestamptz NOT NULL DEFAULT now(),
    bearer_token text,
    headers jsonb NOT NULL DEFAULT '{}'::jsonb,
    forward_headers jsonb NOT NULL DEFAULT '{}'::jsonb,
    user_id text REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT mcp_servers_name_user_unique_idx UNIQUE (name, user_id),
    CONSTRAINT mcp_servers_name_regex_check CHECK (name ~ '^[a-zA-Z0-9_-]+$'),
    CONSTRAINT mcp_servers_url_check CHECK (
        (type = 'STDIO' AND url IS NULL AND command IS NOT NULL) OR
        (type IN ('SSE', 'STREAMABLE_HTTP') AND url IS NOT NULL AND command IS NULL)
    )
);
CREATE TABLE namespaces (
    uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    description text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    user_id text REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT namespaces_name_user_unique_idx UNIQUE (name, user_id),
    CONSTRAINT namespaces_name_regex_check CHECK (name ~ '^[a-zA-Z0-9_-]+$')
);
CREATE TABLE endpoints (
    uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL UNIQUE,
    description text,
    namespace_uuid uuid NOT NULL REFERENCES namespaces(uuid) ON DELETE CASCADE,
    enable_api_key_auth boolean NOT NULL DEFAULT true,
    enable_oauth boolean NOT NULL DEFAULT false,
    enable_max_rate boolean NOT NULL DEFAULT false,
    enable_client_max_rate boolean NOT NULL DEFAULT false,
    enable_metamcp_admin_tools boolean NOT NULL DEFAULT false,
    use_query_param_auth boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    user_id text REFERENCES users(id) ON DELETE CASCADE
);
CREATE TABLE namespace_server_mappings (
    uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    namespace_uuid uuid NOT NULL REFERENCES namespaces(uuid) ON DELETE CASCADE,
    mcp_server_uuid uuid NOT NULL REFERENCES mcp_servers(uuid) ON DELETE CASCADE,
    status mcp_server_status NOT NULL DEFAULT 'ACTIVE',
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT namespace_server_mappings_unique_idx UNIQUE (namespace_uuid, mcp_server_uuid)
);
CREATE TABLE tools (
    uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    mcp_server_uuid uuid NOT NULL REFERENCES mcp_servers(uuid) ON DELETE CASCADE,
    name text NOT NULL,
    description text,
    tool_schema jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tools_unique_tool_name_per_server_idx UNIQUE (mcp_server_uuid, name)
);
CREATE TABLE oauth_sessions (
    uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    mcp_server_uuid uuid NOT NULL UNIQUE REFERENCES mcp_servers(uuid) ON DELETE CASCADE,
    client_information jsonb NOT NULL DEFAULT '{}'::jsonb,
    tokens jsonb,
    code_verifier text,
    expected_state text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE mcp_request_audit_logs (
    uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    mcp_server_uuid uuid REFERENCES mcp_servers(uuid) ON DELETE SET NULL,
    mcp_server_name text,
    tool_name text NOT NULL DEFAULT 'example-tool'
);
CREATE TABLE namespace_tool_mappings (
    uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    namespace_uuid uuid NOT NULL REFERENCES namespaces(uuid) ON DELETE CASCADE,
    tool_uuid uuid NOT NULL REFERENCES tools(uuid) ON DELETE CASCADE,
    mcp_server_uuid uuid NOT NULL REFERENCES mcp_servers(uuid) ON DELETE CASCADE,
    status mcp_server_status NOT NULL DEFAULT 'ACTIVE',
    override_name text,
    override_title text,
    override_description text,
    override_annotations jsonb,
    CONSTRAINT namespace_tool_mappings_unique_idx UNIQUE (namespace_uuid, tool_uuid)
);
