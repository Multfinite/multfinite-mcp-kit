
## Конфигурация

Подробный справочник по всем `.env`, `mcp-local.json`, переменным Compose и их применению: [docs/configuration.md](docs/configuration.md).

## The idea

### Structure

├── 🌐 Global \
│ ├── [sequentialthinking](https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking)  
│ ├── [graphiti](https://github.com/getzep/graphiti)  
│ ├── [cognee](https://github.com/topoteretes/cognee)  
│ ├── [memory-bank-mcp](https://github.com/alioshr/memory-bank-mcp)  
│ ├── [context7](https://github.com/upstash/context7)  
│ ├── [duckduckgo](https://github.com/nickclyde/duckduckgo-mcp-server)  
│ ├── [fetch](https://github.com/modelcontextprotocol/servers/blob/main/src/fetch/README.md)  
│ ├── [github-mcp-server](https://github.com/github/github-mcp-server)<br>
│ ├── [io.draw](https://github.com/jgraph/drawio-mcp)<br>
│ ├── [mcp-compass](https://github.com/liuyoshio/mcp-compass)  
│ └── [gdrive](https://github.com/modelcontextprotocol/servers-archived/tree/main/src/gdrive)  
│  
├── 💻 LOCAL \
│ ├── [DesktopCommanderMCP](https://github.com/wonderwhy-er/DesktopCommanderMCP)  
│ ├── [mcp-everything-search](https://github.com/mamertofabian/mcp-everything-search)  
│ ├── [filesystem-mcp](https://github.com/j0hanz/filesystem-mcp)  
│ ├── [Windows-MCP](https://github.com/CursorTouch/Windows-MCP)  
│ ├── [git](https://github.com/modelcontextprotocol/servers/tree/main/src/git)  
│ ├── [codegraph](https://github.com/colbymchenry/codegraph)  
│ ├── [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp)  
│ ├── [serena](https://github.com/oraios/serena)  
│ ├── [playwright-mcp](https://github.com/mcp/microsoft/playwright-mcp)  
│ ├── [dbhub](https://github.com/mcp/bytebase/dbhub)  
│ ├── [simple-files-vectorstore](https://github.com/lishenxydlgzs/simple-files-vectorstore)  
│ ├── [markitdown](https://github.com/mcp/microsoft/markitdown)  
│ └── [mcp-obsidian](https://github.com/MarkusPfundstein/mcp-obsidian)  
│  
└── 💻 LOCAL (the same as above)\
&nbsp;&nbsp;&nbsp;&nbsp;├── ...\
&nbsp;&nbsp;&nbsp;&nbsp;└── ...

### MetaMCP

**MetaMCP** *.env*  
```
APP_URL=${YOUR_PUBLIC_DOMAIN}
NEXT_PUBLIC_APP_URL=http://localhost:12008
```

## Installation and run

### Global on Linux

Requirements: Debian/Ubuntu (or WSL), Docker accessible without `sudo`, the Docker Compose plugin, and internet access. The first install pulls Graphiti and Cognee images and builds a small Node image; Cognee is large and can require several gigabytes of disk and significant time.

```sh
bash linux/install-global.sh
```

The installer starts Neo4j, Qdrant and MetaMCP, waits for its migrations, then registers **all 11 servers in the Global list** as shared servers. New namespaces and endpoints are organized as follows:

| Namespace | Servers | Protected endpoint name |
| --- | --- | --- |
| `global-reasoning` | `sequentialthinking`, `mcp-compass` | `global-reasoning` |
| `global-memory` | `graphiti`, `cognee`, `memory-bank-mcp` | `global-memory` |
| `global-web` | `context7`, `duckduckgo`, `fetch` | `global-web` |
| `global-integrations` | `github-mcp-server`, `io-draw`, `gdrive` | `global-integrations` |
| `global` (legacy) | `neo4j-global`, `qdrant-global`, `fetch`, `playwright` | `global-sse` |

`io-draw` is the README's `io.draw`: MetaMCP does not permit dots in server names. The legacy group is retained for compatibility, and `fetch` is shared between the legacy and web groups. On a fresh installation, open MetaMCP at `http://localhost:12008`, create an account and an API key. For each endpoint above, use either:

- Streamable HTTP: `http://localhost:12008/metamcp/<endpoint-name>/mcp`
- SSE: `http://localhost:12008/metamcp/<endpoint-name>/sse`

Use your configured `APP_URL` instead of `http://localhost:12008` if it differs. Newly created endpoints require an API key: configure your MCP client to send `Authorization: Bearer <API key>` (or `X-API-Key: <API key>`). Keep the key private. Refresh an already-open UI to see the records.

The seed is transactional and **additive**: existing server settings, disabled mappings, private resources, endpoints, `.env` files and Compose overrides are not overwritten. An existing public server with the same name is reused *as configured*, not replaced by the default. A private server is never linked to a shared namespace. If an endpoint name already belongs to a different namespace or user, it is left alone and a warning is shown. If **any** existing endpoint of a target namespace has neither API-key nor OAuth authentication, that namespace gets no new mappings or endpoint; protect its existing endpoints and explicitly run `seed` below. Other groups are still registered.

Automatic seeding runs once per version per MetaMCP database; subsequent starts preserve intentional deletions. An installation initialized by the earlier four-server seed is upgraded once to the new groups without restoring its deleted legacy records, changing `global-sse`, or re-exposing a removed/disabled `fetch` mapping through `global-web`. To explicitly add missing defaults again after fixing conflicts, without overwriting existing settings or enabling inactive mappings:

```sh
bash linux/run-global.sh seed
```

`start`, `stop`, `restart`, `status`, `logs`, `services-logs`, and `apply-services` are also available as `bash linux/run-global.sh <command>`. Normal starts never recreate an existing MetaMCP container or sidecar; stop/restart stops rather than removes containers, preserving their writable layers. Consequently, changed Compose settings are **not** automatically applied: back up any manual files before deliberately recreating a container yourself. `METAMCP_START_TIMEOUT` controls the readiness wait in seconds (default 180).

#### Server prerequisites and credentials

The installer creates `~/mcp-global/config/.env` only if it does not exist; edit it using shell-compatible quoting and keep it private. To set a different initial Neo4j password or provider keys before the first install, create this file with the desired variables beforehand; omitted variables use the defaults. Changes to an already registered server must be made in the MetaMCP UI; rerunning `seed` does not overwrite it.

- **Graphiti and Cognee:** the default setup uses OpenAI for the LLM and embeddings. Set `OPENAI_API_KEY` in `~/mcp-global/config/.env`, then run `bash linux/run-global.sh apply-services`. Without provider keys these two sidecars wait instead of serving tools. Graphiti uses the configured `NEO4J_URI`, `NEO4J_USER`/`NEO4J_USERNAME`, `NEO4J_PASSWORD`, and optionally `NEO4J_DATABASE` (default `neo4j`); `GRAPHITI_MODEL`, `GRAPHITI_EMBEDDER_MODEL`, and `GRAPHITI_GROUP_ID` (default `multfinite-mcp-kit-global`) are optional. Graphiti creates its indexes in the configured Neo4j database, and its tools can modify or delete graph data: use a separate existing database/instance if existing graphs must be isolated. For Cognee, optional `COGNEE_LLM_PROVIDER`, `COGNEE_LLM_API_KEY`, `COGNEE_LLM_MODEL`, `COGNEE_LLM_ENDPOINT`, `COGNEE_EMBEDDING_PROVIDER`, `COGNEE_EMBEDDING_API_KEY`, `COGNEE_EMBEDDING_MODEL`, and `COGNEE_EMBEDDING_DIMENSIONS` override the defaults. Use matching model/dimensions and a provider supported by Cognee. `apply-services` explicitly recreates **only** the two kit-owned Graphiti/Cognee containers, keeping Neo4j and Cognee volumes; back up any manual files in those containers' writable layers first. It does not edit MetaMCP's records.
- **GitHub:** the official remote GitHub MCP server at `https://api.githubcopilot.com/mcp/` needs a suitable GitHub token and service access. If `GITHUB_PERSONAL_ACCESS_TOKEN` is set before the first seed it is stored as the server's bearer token; otherwise add it to `github-mcp-server` in the MetaMCP UI after installation. Grant only the permissions needed.
- **Context7:** works without a key subject to its limits. `CONTEXT7_API_KEY` is optional; set it before first seed or add it to the server's environment in the UI later.
- **Google Drive:** requires a Google OAuth client and a separate browser authorization, not `GOOGLE_APPLICATION_CREDENTIALS`. Follow the [upstream setup](https://github.com/modelcontextprotocol/servers-archived/tree/main/src/gdrive) to enable the Drive API and create a Desktop OAuth client. On a machine with Node.js/npm and a browser, obtain the server's token file (choose your actual OAuth-client JSON path):

  ```sh
  (
    umask 077
    export GDRIVE_OAUTH_PATH="$HOME/gcp-oauth.keys.json"
    export GDRIVE_CREDENTIALS_PATH="$HOME/.gdrive-server-credentials.json"
    npx -y @modelcontextprotocol/server-gdrive@2025.1.14 auth
    test -s "$GDRIVE_CREDENTIALS_PATH" && chmod 600 "$GDRIVE_CREDENTIALS_PATH"
  )
  ```

  Transfer that token file securely to the Linux Docker host if necessary. With the stack running, copy it into the persistent volume and fix ownership **before** publishing it to the waiting server:

  ```sh
  # On the Docker host, point this to the transferred token file.
  GDRIVE_CREDENTIALS_PATH="$HOME/.gdrive-server-credentials.json"
  container=$(docker ps -q --filter label=com.docker.compose.project=multfinite-mcp-kit-global \
      --filter label=com.docker.compose.service=mcpkit-gdrive)
  test -n "$container" || { echo 'Start the global stack first'; exit 1; }
  docker cp "$GDRIVE_CREDENTIALS_PATH" "$container:/mcpkit/gdrive/credentials.import.json"
  docker exec -u 0 "$container" sh -c 'chown node:node /mcpkit/gdrive/credentials.import.json && chmod 600 /mcpkit/gdrive/credentials.import.json && mv -f /mcpkit/gdrive/credentials.import.json /mcpkit/gdrive/credentials.json'
  docker restart "$container"
  ```

  The upstream GDrive server is archived and may require reauthorization when its credentials expire. The same Google account and stored memory are shared by clients of these shared endpoints; they are not per-user sandboxes.

The remaining README servers use their official packages: Sequential Thinking is pinned to a Node 20-compatible version; DuckDuckGo includes its browser-TLS fallback; draw.io runs headlessly and returns links. GitHub uses the official remote service. Packages run by `npx`/`uvx` and models may download on first use. Qdrant's FastEmbed model may download; the legacy Playwright server additionally needs Chromium and system libraries inside the MetaMCP container or a separately configured browser. External services, credentials, rates and network access determine actual tool availability. Check `services-logs`, MetaMCP logs and its UI; after fixing a failed server, reconnect/reset its error state in the UI if needed.

#### Persistence and security

Graphiti uses the configured Neo4j database (the installer-managed default persists under `~/mcp-global/data/neo4j`). Cognee's system and data files, Memory Bank files and the GDrive token each use named Docker volumes (`multfinite-mcp-kit-global-cognee-system`, `-cognee-data`, `-memory-data`, `-gdrive-data`). Stop/restart and `apply-services` do not remove those volumes. Back them up alongside MetaMCP's PostgreSQL volume and the kit configuration.

The four local sidecars are launched in a separate kit-owned Compose project, each on its own Docker network, with **no published host ports**. The app is attached to those networks without rewriting its Compose files or recreating it. The raw sidecar HTTP services themselves do not enforce MetaMCP API-key authentication: Docker/host administrators and any container attached to a sidecar network can bypass MetaMCP. Restrict Docker access, do not attach untrusted containers, and firewall the host. The installer also publishes Neo4j and Qdrant ports on the host; Qdrant has no authentication by default and Neo4j's default password is `mcp-neo4j-pass`. Set a strong `NEO4J_PASSWORD` before creating a new Neo4j container, restrict network access, and secure the MetaMCP UI/endpoints before exposing them. Existing database containers, credentials and volumes are not reconfigured.

### Seed regression tests

The integration tests require `psql`, `jq`, and a disposable PostgreSQL database (the test user must be allowed to create and drop a schema). Docker and system package installation are mocked; no real containers or system packages are changed.

```sh
TEST_DATABASE_URL='postgresql://user:password@localhost:5432/test_db' bash tests/test-global-seed.sh
```
