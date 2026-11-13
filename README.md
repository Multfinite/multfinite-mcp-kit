
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
│ ├── [github-mcp-server](https://github.com/mcp/github/github-mcp-server)  
│ ├── [io.draw](https://github.com/mcp/io.draw/mcp)  
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

Requirements: Debian/Ubuntu (or WSL), Docker running and accessible without `sudo`, and the Docker Compose plugin. The installer also needs internet access to download the images and MCP packages.

```sh
bash linux/install-global.sh
```

The installer starts Neo4j, Qdrant and MetaMCP, waits for MetaMCP's migrations and registers these **shared** servers in MetaMCP:

| Server | Command |
| --- | --- |
| `neo4j-global` | `uvx mcp-neo4j-cypher` |
| `qdrant-global` | `uvx mcp-server-qdrant` |
| `fetch` | `uvx mcp-server-fetch` |
| `playwright` | `npx -y @playwright/mcp --headless` |

They are linked to the shared `global` namespace and, on a fresh installation, the API-key-protected `global-sse` endpoint. Open the MetaMCP UI at `http://localhost:12008`, create an account, and create or retrieve an API key there. The endpoint URLs are:

- SSE: `http://localhost:12008/metamcp/global-sse/sse`
- Streamable HTTP: `http://localhost:12008/metamcp/global-sse/mcp`

Use your configured `APP_URL` instead of `http://localhost:12008` if it differs. Newly generated MetaMCP configuration disables the example login/password; existing configuration is left untouched. Refresh an already-open UI to see the new records.

The seed is transactional and only adds missing records: it never replaces existing server settings, disabled mappings, private resources, endpoints or the `.env`/Compose override files. If `global-sse` already belongs to another namespace or user, it is left unchanged and a warning is shown. If the existing shared `global` namespace has **any endpoint without authentication**, the servers are registered but no new mappings or endpoint are added, to avoid exposing database tools. Protect that endpoint first and explicitly run `seed` below.

Automatic seeding runs once per MetaMCP database. Subsequent starts preserve servers and mappings that you intentionally removed. To explicitly add missing defaults again, without overwriting existing settings, run:

```sh
bash linux/run-global.sh seed
```

Other commands: `bash linux/run-global.sh start`, `stop`, `restart`, `status`, or `logs`. `start` also starts existing Neo4j and Qdrant containers if they were stopped. It does not recreate existing MetaMCP containers; use `restart` when you deliberately want to apply changed Compose configuration (this interrupts active sessions). `METAMCP_START_TIMEOUT` controls the readiness wait in seconds (default: 180).

Connection settings for newly added servers come from `~/mcp-global/config/.env`: `NEO4J_URI`, `NEO4J_USER` (or `NEO4J_USERNAME`), `NEO4J_PASSWORD`, `QDRANT_URL`, and optionally `QDRANT_API_KEY`. Localhost addresses are translated to `host.docker.internal` inside the official MetaMCP container. Configure them before the first seed; after a server exists, change its settings in the MetaMCP UI rather than expecting another seed to overwrite them. A new Neo4j container has the initial user `neo4j`; another configured user must already exist. Existing Neo4j containers and database volumes are never recreated or reconfigured.

MetaMCP's `APP_URL` and PostgreSQL settings come from `~/mcp-global/metamcp/.env`; published ports are controlled by the Compose configuration. The kit does not rewrite these existing files.

Registration does not guarantee that every tool is already running. MCP packages and Qdrant's FastEmbed model may need to download on first use. Playwright additionally needs a compatible Chromium browser and its system libraries **inside the MetaMCP container**, or a separately configured browser service. Check the MetaMCP logs/UI for connection errors.

**Network security:** the existing installer publishes Neo4j and Qdrant ports on the host; Qdrant has no authentication by default, and the default Neo4j password is `mcp-neo4j-pass`. Restrict access with a firewall and set a strong `NEO4J_PASSWORD` in the kit config before creating a new Neo4j container. Also secure the MetaMCP UI and its endpoints before exposing them outside your machine.

### Seed regression tests

The integration tests require `psql` and a disposable PostgreSQL database (the test user must be allowed to create and drop a schema). Docker and system package installation are mocked; no real containers or system packages are changed.

```sh
TEST_DATABASE_URL='postgresql://user:password@localhost:5432/test_db' bash tests/test-global-seed.sh
```
