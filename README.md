
## Конфигурация

Подробный справочник по Linux `.env`, Windows JSON-настройкам, переменным Compose и их применению: [docs/configuration.md](docs/configuration.md).

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

For a public URL, set the MetaMCP values in `~/mcp-global/config/.env` (for example `APP_URL=https://mcp.example.com` and `NEXT_PUBLIC_APP_URL=https://mcp.example.com`), then apply them with `bash linux/run-global.sh apply-metamcp-config`. This syncs them to MetaMCP's own `.env` and recreates only its app container when needed; save any manual files in that container's writable layer first. A public URL also requires DNS, TLS/reverse proxy or reachable port, and suitable firewall rules. See [the complete configuration reference](docs/configuration.md).

## Installation and run

### Global on Linux

Requirements: Debian/Ubuntu (or WSL), `sudo`, internet access, and Docker with the Compose plugin accessible without `sudo`. If the Docker executable is absent, the installer adds the official Docker Engine/Compose packages and, if necessary, appends the current user to the `docker` group. That group grants administrator-equivalent privileges; a new login may be required. Existing Docker installations, APT repositories and keyrings are not replaced, and a stopped/inaccessible daemon or missing Compose plugin is reported rather than reinstalled. The first install pulls Graphiti and Cognee images and builds a small Node image; Cognee is large and can require several gigabytes of disk and significant time.

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

`start`, `stop`, `restart`, `status`, `logs`, `services-logs`, `apply-services`, and `apply-metamcp-config` are available as `bash linux/run-global.sh <command>`. Normal starts never recreate an existing MetaMCP container or sidecar; stop/restart stops rather than removes containers, preserving their writable layers. `apply-services` deliberately recreates only Graphiti/Cognee; `apply-metamcp-config` syncs `APP_URL`/`NEXT_PUBLIC_APP_URL` and may recreate MetaMCP's app container, so back up any manual files in its writable layer first. `METAMCP_START_TIMEOUT` controls the readiness wait in seconds (default 180).

#### Server prerequisites and credentials

The installer creates `~/mcp-global/config/.env` only if it does not exist; edit it using shell-compatible quoting and keep it private. To set a different initial Neo4j password or provider keys before the first install, create this file with the desired variables beforehand; omitted variables use the defaults. Changes to an already registered server must be made in the MetaMCP UI; rerunning `seed` does not overwrite it.

- **Graphiti and Cognee:** the default setup uses OpenAI-compatible APIs, but each component can use its own provider key and `/v1` base URL. Set `GRAPHITI_API_KEY` and `GRAPHITI_BASE_URL` for Graphiti; `COGNEE_LLM_API_KEY` and `COGNEE_LLM_ENDPOINT` for Cognee's LLM; and `COGNEE_EMBEDDING_API_KEY` and `COGNEE_EMBEDDING_ENDPOINT` for Cognee embeddings. Example endpoints are `https://llm-gateway.example/v1` and `https://embedding-gateway.example/v1`. There is no shared `OPENAI_API_KEY` fallback: configure every required service-specific key explicitly. Then run `bash linux/run-global.sh apply-services`. If the relevant key for an OpenAI provider is absent, that sidecar waits instead of serving tools. Graphiti uses `NEO4J_URI`, `NEO4J_USER`/`NEO4J_USERNAME`, `NEO4J_PASSWORD`, and optionally `NEO4J_DATABASE` (default `neo4j`); `GRAPHITI_MODEL`, `GRAPHITI_EMBEDDER_MODEL`, and `GRAPHITI_GROUP_ID` (default `multfinite-mcp-kit-global`) are also configurable. Graphiti's tools can modify or delete graph data: use a separate existing database/instance to isolate it. Cognee's LLM and embedding provider, model, key and endpoint are independent; use provider-supported models and matching embedding dimensions. `apply-services` recreates **only** the two kit-owned Graphiti/Cognee containers, keeping data volumes; back up manual files in their writable layers first. It does not edit MetaMCP records.
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

### LOCAL на Windows

Нужны Windows 10/11 **x64**, интерактивный вход пользователя, PowerShell 5.1 или новее и интернет. Docker на Windows не нужен. Установка, запуск, управление и регистрация выполняются скриптами PowerShell; Node.js используется для MCP-шлюза и Node-серверов. При отсутствии зависимостей установщик использует WinGet ID `Git.Git`, `OpenJS.NodeJS.LTS`, `voidtools.Everything` и, с согласия пользователя, `Microsoft.VisualStudio.2022.BuildTools`. Нужен WinGet из Microsoft App Installer; возможен запрос UAC. Скрипт устанавливает отдельный Node 24, Python-окружения 3.12 и 3.14, все **13 серверов LOCAL**, Everything SDK и Chromium. Если подходящего `uv` нет, проверенная по SHA-256 копия ставится в каталог комплекта, не заменяя старую. Для `simple-files-vectorstore` могут потребоваться Visual Studio C++ Build Tools (несколько гигабайт); установщик спросит разрешение. Повторный запуск временно останавливает шлюз этого комплекта перед обновлением и пытается запустить его снова; пользовательские данные и глобальные npm/Python-пакеты не удаляются.

Из корня этого репозитория в **пользовательской** сессии Windows:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\install-local.ps1
.\windows\run-local.ps1 status
```

Если установка сообщает об ошибке, исправьте её и повторите команду: итог с ошибкой имеет ненулевой код. Для запуска без вопросов используйте `.\windows\install-local.ps1 -NonInteractive -InstallBuildTools`. Явные ключи `-SkipEverything` и `-SkipBrowserDownload` пропускают соответствующие компоненты; тогда часть функций может не работать. После установки скрипт предлагает настроить регистрацию в MetaMCP. Её также можно выполнить позже, как описано ниже.

По умолчанию данные находятся в `%USERPROFILE%\mcp-local`. Можно заранее задать `$env:MCP_LOCAL_DIR` и использовать то же значение при всех последующих запусках. Старые `config\.env` и `config\mcp-local.json` **не перезаписываются**; старый JSON не используется как исполняемый конфиг. При первом создании новых настроек существующие абсолютные `PROJECTS_DIR` и `WRITING_DIR` из `.env` копируются, как и заданные пользователем `DBHUB_DSN` и `OBSIDIAN_API_KEY`; старый пример DSN `postgres://user:pass@localhost:5432/devdb` игнорируется. Значения читаются буквально, без выполнения `.env`. Последующие изменения делайте в новых файлах:

- `config\local-settings.json` — папки проектов и заметок, слушающий адрес, URL и параметры регистрации;
- `config\private\secrets.json` — отдельный ключ шлюза, ключ Obsidian и необязательный DSN DBHub; файл не следует отправлять в чат или коммитить;
- `logs\` и `runtime\` — журналы и изолированные зависимости; их ACL, как и ACL `config\private`, ограничиваются текущим пользователем, SYSTEM и администраторами. Остальные старые файлы не изменяются.

Изменённые настройки применяются после `restart`. В JSON обратные слеши Windows должны быть удвоены (`C:\\...`).

```powershell
.\windows\run-local.ps1 start        # запустить после входа в Windows
.\windows\run-local.ps1 restart      # применить новые настройки
.\windows\run-local.ps1 status
.\windows\run-local.ps1 logs         # последние строки всех журналов
.\windows\run-local.ps1 logs gateway # журнал последнего запуска шлюза
.\windows\run-local.ps1 logs obsidian
.\windows\run-local.ps1 stop         # только процессы этого комплекта
```

`ready` означает, что отдельный MCP-прокси ответил на `initialize`; это не проверка всех реальных операций. `waiting` означает отсутствие необходимого внешнего условия/настройки; `error` и `starting` делают команду `status` неуспешной. Запуск не создаёт системную службу или автозапуск: GUI-серверы работают в сессии вошедшего пользователя и после выхода или перезагрузки могут потребовать нового `start`.

#### Что нужно для отдельных серверов

- **Windows-MCP** управляет реальным рабочим столом. Нужна доступная интерактивная сессия и необходимые права; экран входа/UAC и заблокированный рабочий стол не гарантируют работу. **Desktop Commander** и Git также могут выполнять команды и изменять файлы от имени пользователя. Ограничения каталогов `filesystem` не являются песочницей для остальных серверов.
- **Everything** должен быть запущен, его служба/индекс готовы. Установщик ставит SDK, но `ready` сам по себе не означает, что поиск уже проиндексирован.
- **Obsidian**: откройте Obsidian с включённым плагином Local REST API и HTTPS на `127.0.0.1:27124`. Скопируйте ключ плагина в `obsidianApiKey` файла `config\private\secrets.json`, сохраните и выполните `restart`. Без ключа сервер ожидает настройку. Сторонний `mcp-obsidian` не проверяет сертификат Local REST API, поэтому разрешён только `localhost`/`127.0.0.1`; для удалённого Obsidian нужен локально завершающийся защищённый туннель.
- **CodeGraph** запускается без изменения существующих проектов; индекс для нужного проекта создаётся отдельно. Например, при стандартном пути комплекта:

  ```powershell
  $node = "$env:USERPROFILE\mcp-local\runtime\node\node_modules\node\bin\node.exe"
  $codegraph = "$env:USERPROFILE\mcp-local\runtime\npm\core\node_modules\@colbymchenry\codegraph\npm-shim.js"
  $previousTelemetry = $env:CODEGRAPH_TELEMETRY
  $previousCodegraphDir = $env:CODEGRAPH_INSTALL_DIR
  try {
    $env:CODEGRAPH_TELEMETRY = '0'
    $env:CODEGRAPH_INSTALL_DIR = "$env:USERPROFILE\mcp-local\runtime\codegraph"
    & $node $codegraph init 'C:\path\to\your\project'
  } finally {
    $env:CODEGRAPH_TELEMETRY = $previousTelemetry
    $env:CODEGRAPH_INSTALL_DIR = $previousCodegraphDir
  }
  ```

  Передайте путь индексированного проекта в параметре `projectPath` инструмента CodeGraph, если он отличается от `projectsDir`. Codebase Memory и Serena также требуют указания/активации проекта; необходимые LSP и индексы могут загружаться или создаваться при использовании.
- **Playwright** запускает установленный Chromium в headless-режиме. **DBHub** по умолчанию использует сохраняемый `data\dbhub.sqlite`; другой DSN можно указать в `dbhubDsn` в `secrets.json`. **Simple Files Vectorstore** следит за `writingDir`, при первом индексировании скачивает модель из Hugging Face и, согласно текущей реализации сервера, хранит индекс в памяти и перестраивает его после перезапуска. **MarkItDown** ставится с дополнительными форматами.

#### Подключение Windows к Linux MetaMCP

Шлюз по умолчанию слушает только `127.0.0.1:13001`, требует свой случайный `X-API-Key` и не доступен Linux-машине напрямую. Ключ шлюза и ключ клиента MetaMCP — **разные** ключи. Для подключения сначала обеспечьте защищённый маршрут из **контейнера MetaMCP** к шлюзу: TLS с доверенным для контейнера сертификатом либо зашифрованный VPN/туннель. `localhost` внутри контейнера — это контейнер, а не Windows или хост Linux. SSH ниже переносит только конфигурацию, туннель для MCP-трафика он автоматически не создаёт.

Например, если защищённый VPN уже соединяет машины и адрес Windows в нём `10.55.0.2`:

1. На Linux должен работать ранее установленный MetaMCP, существовать учётная запись и находиться актуальная копия этого репозитория с `linux/register-local.sh` и `linux/seed-local.sql`. SSH-пользователю нужны доступ к Docker без `sudo` и этот же `$HOME`, где установлен `~/mcp-global/metamcp`.
2. В PowerShell выполните `.\windows\run-local.ps1 configure`. Введите `10.55.0.2` как **listen address**, `http://10.55.0.2:13001` как URL, оставьте TLS-пути пустыми, укажите email существующей учётной записи MetaMCP, SSH-адрес `user@linux-host` и абсолютный путь к репозиторию на Linux. Подтвердите `YES` **только для зашифрованного VPN/туннеля**. Для прямого TLS задайте оба PEM-файла, используйте `https://...` и убедитесь, что сертификату доверяет контейнер. При наличии внешнего TLS-прокси можно оставить шлюз на loopback.
3. Ограничьте Windows Firewall разрешённым адресом/подсетью Linux и нужным VPN-интерфейсом. Скрипт не создаёт сетевых исключений автоматически. Проверьте, что адрес доступен именно контейнеру MetaMCP, а не только хосту Linux.
4. Выполните:

   ```powershell
   .\windows\run-local.ps1 restart
   .\windows\run-local.ps1 register
   ```

   Нужен установленный Windows OpenSSH и доступ по SSH (удобно настроить ключ/ssh-agent заранее). Ключ шлюза передаётся по stdin SSH, а не в аргументах команды. При недоступности SSH команда `export` создаёт `config\private\registration.json`: передайте его безопасно на Linux, выполните там `bash linux/register-local.sh --stdin < /путь/registration.json` и удалите переданную копию.

Регистрация транзакционно добавляет приватные серверы, namespace и endpoint `local-<hostId>` **указанному владельцу**. Для нового endpoint в UI MetaMCP создайте личный API-ключ того же владельца и подключайте MCP-клиент к `http(s)://<адрес-metamcp>/metamcp/local-<hostId>/mcp` с `Authorization: Bearer <личный ключ MetaMCP>`. Если существующий endpoint был вручную переключён только на OAuth, используйте его настройки авторизации: скрипт их не меняет. Узнать `hostId` можно из `config\local-settings.json`. Обновите UI; при необходимости переподключите серверы после исправления ошибок сети. API-ключ шлюза хранится в заголовках записей MetaMCP: защищайте резервные копии БД и доступ администраторов.

Повторный `register` не восстанавливает намеренно удалённые записи и не меняет существующие. Команда `.\windows\run-local.ps1 seed` явно добавляет недостающие значения, не перезаписывая изменённые серверы и не включая отключённые mappings. Конфликты URL/ключа нужно разрешить вручную в UI; если адрес шлюза или ключ менялся, существующие записи также меняются вручную. Если у целевого namespace есть открытый или принадлежащий другому пользователю endpoint, регистрация прерывается. Не отключайте авторизацию endpoint и не открывайте этот шлюз в недоверенную сеть: его инструменты дают доступ к рабочему столу, файлам и командам Windows.

### Seed regression tests

The integration tests require `psql`, `jq`, and a disposable PostgreSQL database (the test user must be allowed to create and drop a schema). Docker and system package installation are mocked; no real containers or system packages are changed.

```sh
TEST_DATABASE_URL='postgresql://user:password@localhost:5432/test_db' bash tests/test-global-seed.sh
TEST_DATABASE_URL='postgresql://user:password@localhost:5432/test_db' bash tests/test-local-seed.sh
```

Gateway and installer/lifecycle tests use Node 24 and an installed copy of `mcp-proxy@6.10.0`. The PowerShell tests also require PowerShell Core and Python 3 on a POSIX host; they run the actual scripts with synthetic installers and POSIX MCP executables:

```sh
npm install --prefix /tmp/mcp-proxy-test mcp-proxy@6.10.0
export MCP_PROXY_CLI=/tmp/mcp-proxy-test/node_modules/mcp-proxy/dist/bin/mcp-proxy.mjs
export MCP_POWERSHELL="$(command -v pwsh)"
node --test tests/test-windows-gateway.mjs tests/test-local-cli.mjs tests/test-windows-installer.mjs
python3 tests/test-local-configure.py
```

An optional real semantic-search test uses an existing vectorstore installation and a pre-populated `Xenova/all-MiniLM-L6-v2` model cache (the model is about 90 MB). It forbids model downloads during the test and writes only to a temporary directory:

```sh
MCP_PROXY_CLI=/absolute/path/to/mcp-proxy.mjs \
MCP_VECTORSTORE_CLI=/absolute/path/to/simple-files-vectorstore/build/index.js \
MCP_VECTORSTORE_CACHE=/absolute/path/to/@xenova/transformers/.cache \
  node --test tests/test-vectorstore-real.mjs
```

These protocol/database tests do not replace a native Windows test of installation, desktop interaction, Everything, Chromium, Obsidian, firewall rules, or the actual VPN/TLS path.
