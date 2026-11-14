# Multfinite MCP Kit

Комплект содержит два независимых варианта: **GLOBAL на Linux** и **LOCAL на Windows**. Каждый управляет собственным MetaMCP; Windows-установщик не подключает серверы к Linux автоматически. Настройки, данные и ключи этих установок не взаимозаменяемы. Для ручной межмашинной регистрации есть [отдельный низкоуровневый регистратор](docs/configuration.md#linux-низкоуровневая-регистрация-windows-шлюза), но защищённое соединение необходимо настроить самостоятельно.

Для новой копии перейдите в каталог, где хотите разместить проект, и, если Git уже установлен, выполните:

```sh
git clone https://github.com/Multfinite/multfinite-mcp-kit.git
cd multfinite-mcp-kit
```

Если Git ещё не установлен, можно скачать архив через GitHub (**Code → Download ZIP**) и распаковать его; Windows-установщик при необходимости попробует установить Git через WinGet. Остальные команды выполняются из корня полученной копии на соответствующем компьютере.

## Конфигурация

Подробный справочник по Linux `.env`, Windows JSON-настройкам, переменным Compose и их применению: [docs/configuration.md](docs/configuration.md).

## The idea

### Structure

├── 🌐 GLOBAL (Linux) \
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
├── 💻 LOCAL (Windows) \
│ ├── [DesktopCommanderMCP](https://github.com/wonderwhy-er/DesktopCommanderMCP)  
│ ├── [mcp-everything-search](https://github.com/mamertofabian/mcp-everything-search)  
│ ├── [filesystem-mcp](https://github.com/j0hanz/filesystem-mcp)  
│ ├── [Windows-MCP](https://github.com/CursorTouch/Windows-MCP)  
│ ├── [git](https://github.com/modelcontextprotocol/servers/tree/main/src/git)  
│ ├── [codegraph](https://github.com/colbymchenry/codegraph)  
│ ├── [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp)  
│ ├── [serena](https://github.com/oraios/serena)  
│ ├── [playwright-mcp](https://github.com/microsoft/playwright-mcp)<br>
│ ├── [dbhub](https://github.com/bytebase/dbhub)<br>
│ ├── [simple-files-vectorstore](https://github.com/lishenxydlgzs/simple-files-vectorstore)  
│ ├── [markitdown](https://github.com/microsoft/markitdown/tree/main/packages/markitdown-mcp)<br>
│ └── [mcp-obsidian](https://github.com/MarkusPfundstein/mcp-obsidian)

### MetaMCP

For a public URL, set `APP_URL=https://mcp.example.com` in `~/mcp-global/config/.env`. Every `bash linux/run-global.sh start` syncs it (and `NEXT_PUBLIC_APP_URL`) to MetaMCP's Compose `.env`, which injects them into the container environment; the script checks the running app's environment and recreates only the app if it is stale. To apply immediately without waiting for the next start, run `bash linux/run-global.sh apply-metamcp-config`. Save any manual files in the app container's writable layer before a recreation. External access also requires DNS, a reachable port, TLS (usually a reverse proxy), and suitable firewall rules; do not send credentials over an unprotected network. See [the complete configuration reference](docs/configuration.md).

## Installation and run

### Global on Linux

Requirements: Debian/Ubuntu (including WSL), `sudo`, internet access, and Docker with the Compose plugin accessible without `sudo`. If the Docker executable is absent, the installer adds the official Docker Engine/Compose packages and, if necessary, appends the current user to the `docker` group. That group grants administrator-equivalent privileges; a new login may be required. Existing Docker installations, APT repositories and keyrings are not replaced, and a stopped/inaccessible daemon or missing Compose plugin is reported rather than reinstalled. The first install pulls Graphiti and Cognee images and builds a small Node image; Cognee is large and can require several gigabytes of disk and significant time.

The Linux installer shallow-clones the upstream MetaMCP **default branch**, without pinning a revision, only when `~/mcp-global/metamcp/.git` is absent. It reuses an existing clone without pulling it; it also attempts `docker compose pull`. The effective upstream files and image versions can therefore differ between installations. See [updates and backups](#обновление-и-восстановление) before changing an existing installation.

```sh
bash linux/install-global.sh
```

The installer leaves an existing Docker installation alone. If Docker is newly installed and your user is added to the `docker` group, membership takes effect in a new session; if Docker remains inaccessible, restart the session (on WSL, use `wsl.exe --shutdown`) and rerun the installer. It does not invoke an interactive `newgrp` shell. It then starts Neo4j, Qdrant and MetaMCP, waits for MetaMCP's migrations, and attempts to register the **11 servers in the Global list** as shared servers, plus the legacy Neo4j, Qdrant and Playwright records. Registration can be skipped or limited by existing records or conflicts; a registered server is not necessarily ready. On a fresh, conflict-free installation the groups are:

> The Linux installer and runner use the fixed container names `neo4j-mcp` and `qdrant-mcp`. They start an existing container with either name without checking its ownership or configuration; `stop` and `restart` also stop those names. Check for name collisions before installing or using these commands. Configuring remote database URLs does not prevent the installer from creating or starting these local containers.

| Namespace | Servers | Protected endpoint name |
| --- | --- | --- |
| `global-reasoning` | `sequentialthinking`, `mcp-compass` | `global-reasoning` |
| `global-memory` | `graphiti`, `cognee`, `memory-bank-mcp` | `global-memory` |
| `global-web` | `context7`, `duckduckgo`, `fetch` | `global-web` |
| `global-integrations` | `github-mcp-server`, `io-draw`, `gdrive` | `global-integrations` |
| `global` (legacy) | `neo4j-global`, `qdrant-global`, `fetch`, `playwright` | `global-sse` |

`io-draw` is the README's `io.draw`: MetaMCP does not permit dots in server names. The legacy group is retained for compatibility, and `fetch` is shared between the legacy and web groups. On a fresh installation using the standard URL, open MetaMCP at `http://localhost:12008`; create an account if registration is enabled and create an API key. For each endpoint above, use either:

- Streamable HTTP: `http://localhost:12008/metamcp/<endpoint-name>/mcp`
- SSE: `http://localhost:12008/metamcp/<endpoint-name>/sse`

Use your configured `APP_URL` instead of `http://localhost:12008` if it differs. Newly created endpoints require an API key: configure your MCP client to send `Authorization: Bearer <API key>` (or `X-API-Key: <API key>`). Keep the key private. Refresh an already-open UI to see the records. Existing endpoints may have different authentication settings; check every endpoint rather than assuming it is protected.

Unlike Windows LOCAL, the Linux installer leaves upstream bootstrap enabled or disabled as specified by the cloned `example.env`. Bootstrap can reapply registration settings on restart. Review the effective `BOOTSTRAP_*` settings, close unwanted UI/SSO signup and configure administrators before exposing the service. If `METAMCP_ADMIN_EMAILS` is empty, upstream treats every signed-in user as an administrator. Inspect the actual Compose port bindings and firewall rules: `APP_URL` does not configure access restrictions, DNS, HTTPS or a reverse proxy.

The seed is transactional and **additive**: existing server settings, disabled mappings, private resources, endpoints, `.env` files and Compose overrides are not overwritten. An existing public server with the same name is reused *as configured*, not replaced by the default. A private server is never linked to a shared namespace. If an endpoint name already belongs to a different namespace or user, it is left alone and a warning is shown. If **any** existing endpoint of a target namespace has neither API-key nor OAuth authentication, that namespace gets no new mappings or endpoint; protect its existing endpoints and explicitly run `seed` below. Other groups are still registered.

Automatic seeding runs once per version per MetaMCP database; subsequent starts preserve intentional deletions and, once the marker exists, do not recheck endpoints for newly introduced insecure settings. An installation initialized by the earlier four-server seed is upgraded once to the new groups without restoring its deleted legacy records, changing `global-sse`, or re-exposing a removed/disabled `fetch` mapping through `global-web`. To explicitly add missing defaults again after fixing conflicts, without overwriting existing settings or enabling inactive mappings:

```sh
bash linux/run-global.sh seed
```

Use `bash linux/run-global.sh <command>`:

| Command | Effect |
| --- | --- |
| `start` (default) | Starts the existing named storage containers, MetaMCP and sidecars; waits for MetaMCP and runs automatic seed if needed. |
| `seed` | Explicitly adds missing defaults after review; existing settings and inactive mappings are preserved. |
| `stop` / `restart` | Stop, or stop then start, the sidecars, MetaMCP and the two fixed-name storage containers. Containers and volumes are not removed. |
| `status` | Lists matching Docker containers; it is not a tool-readiness check. |
| `logs` / `services-logs` | Follow app logs, or all sidecar logs, respectively; stop viewing with Ctrl+C. |
| `apply-services` | Recreates only Graphiti and Cognee to apply their configuration; named volumes are kept. |
| `apply-metamcp-config` | Applies a non-empty public URL; when necessary, recreates only the MetaMCP app. |

Normal starts use `--no-recreate` for the app and sidecars, except when an app URL change is pending or its running environment is stale. Back up manual files in the app's writable layer before a possible recreation. Starts also check the MetaMCP `uv` cache volume and repair its ownership if needed, without running the app as root. After sidecar networks are connected, `start` clears `Error Status` for **public records with certain default names**, including pre-existing records with those names; see the [configuration reference](docs/configuration.md) for the exact list. `METAMCP_START_TIMEOUT` controls the readiness wait in seconds (default 180).

#### Server prerequisites and credentials

The installer creates `~/mcp-global/config/.env` only if it does not exist; edit it using shell-compatible quoting and keep it private. To set a different initial Neo4j password or provider keys before the first install, create this file with the desired variables beforehand; omitted variables use the defaults. Changes to an already registered server must be made in the MetaMCP UI; rerunning `seed` does not overwrite it.

- **Graphiti and Cognee:** configure APIs with a consistent `SERVICE_API_*` naming pattern. Global LLM defaults are `LLM_API_ENDPOINT`, `LLM_API_KEY`, `LLM_API_MODEL`, and `LLM_API_PROVIDER`; per-consumer settings override them when non-empty: `GRAPHITI_API_ENDPOINT` / `GRAPHITI_API_KEY` / `GRAPHITI_API_MODEL`, and `COGNEE_LLM_API_ENDPOINT` / `COGNEE_LLM_API_KEY` / `COGNEE_LLM_API_MODEL` / `COGNEE_LLM_API_PROVIDER`. Cognee embeddings have their own `COGNEE_EMBEDDING_API_ENDPOINT`, `COGNEE_EMBEDDING_API_KEY`, `COGNEE_EMBEDDING_API_MODEL`, and `COGNEE_EMBEDDING_API_PROVIDER`; the model is specific to embeddings. For example, set `LLM_API_ENDPOINT=https://llm-gateway.example/v1` and `LLM_API_KEY='shared-provider-key'`, then override just `GRAPHITI_API_KEY='graphiti-specific-key'` if Graphiti uses a separate credential. Old service-specific names remain accepted as aliases; the old shared `OPENAI_API_KEY` is ignored. The generated file sets `COGNEE_EMBEDDING_API_PROVIDER=openai`, so it must be cleared or changed if embeddings should inherit another global provider. Then run `bash linux/run-global.sh apply-services`. Graphiti waits if its effective API key is empty; Cognee waits for a missing key only when the corresponding provider is `openai`. Other providers may require their own credentials. Graphiti's `GRAPHITI_EMBEDDER_MODEL` and `GRAPHITI_GROUP_ID` (default `multfinite-mcp-kit-global`) remain additional service parameters; `NEO4J_URI`, `NEO4J_USER`/`NEO4J_USERNAME`, `NEO4J_PASSWORD`, and optionally `NEO4J_DATABASE` (default `neo4j`) configure its database. Graphiti's tools can modify or delete graph data: use a separate existing database/instance to isolate it. Cognee supports its own provider settings and embedding dimensions; use provider-supported models and matching dimensions. `apply-services` recreates **only** the two kit-owned Graphiti/Cognee containers, keeping data volumes; back up manual files in their writable layers first. It does not edit MetaMCP records.
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

Нужны Windows 10/11 x64, 64-битный PowerShell 5.1+, интерактивный вход и **Docker Desktop с Linux containers и Compose 2.24.4 или новее**. Для отсутствующих системных компонентов может понадобиться WinGet, UAC, WSL 2 или перезагрузка. Отдельный Linux-сервер, SSH, VPN и настройка сетевых адресов не нужны. MetaMCP клонируется на закреплённую в `windows/manifest.json` ревизию и собирается в отдельный Docker-проект на этом же компьютере; первый build может занять несколько минут и загрузить зависимости.

Если текущий Windows LOCAL **уже установлен** и содержит `config\local-settings.json`, `config\private\secrets.json` и необходимые runtime-пакеты, из корня обновлённого репозитория выполните:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\install-local.ps1 -MetaMcpOnly
```

Этот вариант проверяет Git и Docker, запускает существующий шлюз и локальный MetaMCP, но не переустанавливает npm/Python-серверы. Только старых `config\.env` или `config\mcp-local.json` для `-MetaMcpOnly` недостаточно. Если необходимые файлы или пакеты отсутствуют, используйте полную установку. Откройте Docker Desktop и повторите команду, если установка попросила перезапуск.

Для **новой полной установки**:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\install-local.ps1
```

Установщик использует WinGet для недостающих Git, Docker Desktop, Node, Everything и, с согласия, C++ Build Tools; устанавливает 13 серверов и изолированные runtime-пакеты, Everything SDK и Chromium. `-NonInteractive` пропускает вопрос о C++ Build Tools, а `-InstallBuildTools` явно разрешает их установку; вместе они не исключают системные запросы UAC или настройки Docker/WSL. `-SkipEverything` пропускает установку Everything и SDK, `-SkipBrowserDownload` — загрузку Chromium; соответствующие серверы могут быть недоступны. Подробнее о параметрах и версиях — в [справочнике](docs/configuration.md#windows-local-настройки-и-секреты).

При первой успешной установке без конфликтов создаются 13 **общих/public** MCP-серверов с короткими именами и шесть тематических public namespaces и endpoints тоже без префиксов. Учётная запись для создания этих записей не требуется; `start` или `seed` выводит доступные адреса. При предупреждениях проверьте фактические записи и авторизацию в UI.

| Namespace и endpoint | Точные имена серверов в MetaMCP |
| --- | --- |
| `system` | `desktop-commander`, `windows-mcp` |
| `files` | `everything-search`, `filesystem`, `markitdown` |
| `code` | `git`, `codegraph`, `codebase-memory-mcp`, `serena` |
| `web` | `playwright` |
| `data` | `dbhub` |
| `memory` | `simple-files-vectorstore`, `obsidian` |

После первого запуска новой установки:

1. Откройте `http://localhost:13008` (или адрес, выведенный скриптом при изменённом порте) и **самостоятельно зарегистрируйтесь**. Скрипт не создаёт учётную запись и не выбирает пароль.
2. В MetaMCP откройте **Настройки → Настройки авторизации** и включите **«Отключить регистрацию через форму»**. При необходимости отдельно отключите регистрацию через SSO. Скрипт не изменяет эти настройки при перезапуске.
3. В **API Keys** создайте личный ключ и передайте его MCP-клиенту в `Authorization: Bearer <ключ>` (или `X-API-Key: <ключ>`). Укажите адрес нужной группы, например при стандартном порте `http://localhost:13008/metamcp/code/mcp`; для SSE замените `/mcp` на `/sse`. Ключ шлюза Windows — отдельный секрет.

**Public в MetaMCP** означает, что записи видны всем его пользователям, а не анонимный доступ или публикацию в интернет. Новые endpoints требуют API key и по умолчанию доступны только на loopback. В закреплённой версии MetaMCP любой действующий личный или общий API-ключ может пройти авторизацию на любом public endpoint с включённой проверкой API key, в том числе на остальных группах. Выбор одного URL в клиенте **не ограничивает** владельца ключа этой группой. Доступные инструменты могут управлять файлами и рабочим столом: выдавайте ключи только доверенным клиентам и храните их приватно.

Основные команды:

```powershell
.\windows\run-local.ps1 start                  # полный стек; команда по умолчанию
.\windows\run-local.ps1 status                 # шлюз и MetaMCP
.\windows\run-local.ps1 logs codebase-memory-mcp
.\windows\run-local.ps1 logs gateway
.\windows\run-local.ps1 logs metamcp
.\windows\run-local.ps1 restart
.\windows\run-local.ps1 stop
```

Для управления только нативными серверами доступны `gateway-start`, `gateway-stop`, `gateway-restart` и `gateway-status`: они не запускают и не останавливают MetaMCP и не регистрируют серверы в его БД. Полный список, включая `init`, `seed`, `credentials`, `enable-signup`, `ports` и `set-ports`, приведён в [справочнике](docs/configuration.md#команды-windows-local). `reset-metamcp-records` — отдельная разрушительная операция, описанная ниже.

Новая установка использует upstream-режим одного пользователя: пока не задан список администраторов, **любой вошедший пользователь является администратором**. UI и backend доступны только на loopback, но их могут открыть другие пользователи этого компьютера; закройте регистрацию сразу после создания нужных учётных записей.

#### Если MetaMCP уже был установлен прежней версией

Перед первым `start` после обновления сохраните независимую копию. Миграция может сделать ранее приватные kit-серверы и совместимые namespace/endpoint **общими для пользователей MetaMCP**: это изменение видимости и доступа, даже когда endpoint остаётся защищённым. Проверьте, кому можно доверять доступ к инструментам.

Обновите файлы комплекта и выполните из корня репозитория:

```powershell
.\windows\run-local.ps1 start
.\windows\run-local.ps1 enable-signup  # только если регистрация уже закрыта и нужно создать новую учётную запись
```

Если старый app ещё использует bootstrap, первый `start` отключит его, пересоздав только app-контейнер и сначала сохранив его записываемый слой в локальный образ. База, учётные записи, их настройки, volumes и приватный `metamcp.env` сохраняются; состояние регистрации не меняется. `enable-signup` **явно включает только регистрацию через форму**. После регистрации самостоятельно отключите её в настройках MetaMCP.

При необходимости `start` пытается безопасно перевести прежние серверы V1 и записи V2 на короткие имена — например, `filesystem`. Совместимые дубликаты объединяются; при конфликтах они могут остаться. По возможности сохраняются прежние UUID, подключения, tool mappings, ограничения, OAuth-сессия и ссылки аудита. Старый endpoint сохраняет свой URL и UUID; если это безопасно, его namespace и сам endpoint также становятся public, сохраняя аутентификацию. При создании новых групп ограничения старого namespace по возможности копируются; уже существующие настройки групп V2 не перезаписываются.

Перед применением скрипт временно останавливает **только app**, сохраняет `pg_dump` в каталоге `mcpkit-backups` PostgreSQL volume и запускает тот же контейнер без пересоздания, чтобы сбросить активные и заранее созданные MCP-сессии. Дамп содержит секреты и находится в том же volume, поэтому это не замена отдельной резервной копии: сохраните её в защищённом месте. При ошибке резервного копирования миграция не выполняется. Повторный обычный `start` без изменений миграцию и дамп не повторяет; явный `seed` создаёт новый дамп. Остальные containers и volumes не удаляются.

**После миграции переподключите MCP-клиенты.** URL старого endpoint остаётся прежним, но имена инструментов включают имя сервера и меняются, например на `filesystem__...`: при необходимости обновите allowlist и сохранённые вызовы клиентов.

Если записи отличаются по подключению, tool schema или несовместимым ограничениям, содержат несколько OAuth-сессий, принадлежат чужой конфигурации или ссылаются на неизвестные расширения БД, скрипт не удаляет их вслепую: он выводит предупреждение, и такие дубликаты могут временно остаться. Проверьте и согласуйте настройки в MetaMCP, сохраните нужные данные и после устранения конфликта запустите `.\windows\run-local.ps1 seed`. Открытый endpoint необходимо защитить: существующие mappings уже могут быть доступны без ключа. Намеренно удалённые записи V1/V2 автоматом не восстанавливаются; явный `seed` после проверки может снова добавить удалённые defaults, но не переписывает отключённые mappings. Несовместимые настройки или чужие/заменённые namespace автоматически не захватываются даже при `seed`.

#### Разовый полный сброс записей Windows MetaMCP

Если сохранение старых записей не нужно, можно **явно** сбросить их и создать чистый набор из 13 серверов и шести защищённых групп с короткими именами. На прежней установке старые имена `local-<hostId>-...` остаются до этого явного сброса: обычный `start` не переименовывает и не удаляет их. Сброс удалит **все** серверы, namespaces и endpoints в отдельной базе Windows LOCAL MetaMCP, включая добавленные вручную, а также их tool settings, mappings и OAuth-сессии серверов. Строки аудита останутся, но ссылки на удалённые серверы и namespaces будут очищены. Учётные записи, API-ключи MetaMCP, состояние регистрации, файлы и данные Windows-серверов, другие базы и Docker volumes не удаляются. Linux GLOBAL не затрагивается.

Сначала сохраните отдельную защищённую резервную копию базы. Затем в корне репозитория выполните:

```powershell
.\windows\run-local.ps1 reset-metamcp-records
```

Команда покажет целевой локальный Docker-проект и попросит ввести `DELETE ALL LOCAL RECORDS`; любой другой ответ отменит операцию. Она остановит app, сделает содержащий секреты `pg_dump` внутри PostgreSQL volume и удалит старые записи вместе с созданием новых в одной транзакции. Внутренний дамп **не заменяет независимую копию volume**. Неизвестные внешние ссылки или триггеры БД блокируют сброс. Если старому app нужно отключить bootstrap, команда сначала сохранит его слой в локальный образ и применит конфигурацию, не запуская отдельную миграцию записей.

Обычные `start` и `seed` полный сброс не выполняют. После успешного сброса автоматическая регистрация при `start` проверяет маркер и сохраняет последующие ручные изменения; повторный запуск самой команды сброса с подтверждением снова удалит записи. UUID будут новыми, старые адреса endpoints могут перестать существовать — переподключите клиентов. Если связь прервалась после SQL или app не перезапустился, сброс мог уже завершиться: **не повторяйте его вслепую**, выполните `start` и проверьте MetaMCP и backup.

Если после сброса всё ещё показаны имена с префиксом, **не повторяйте сброс сразу**. В том же каталоге, из которого запускали команду, проверьте версию и файлы без изменения базы:

```powershell
Get-Location
Get-Item .\windows\run-local.ps1, .\windows\metamcp-local.ps1, .\windows\seed-local.sql | Select-Object FullName
git rev-parse HEAD
git status --short -- windows/run-local.ps1 windows/metamcp-local.ps1 windows/seed-local.sql windows/local-common.ps1
Select-String -Path .\windows\seed-local.sql -Pattern 'MCPKIT_RESET_CONTRACT|short_names := reset_all|group_prefix :='
Select-String -Path .\windows\metamcp-local.ps1 -Pattern '\$shortGroups =|\$ResetAll -and \$shortGroups'
```

Сверьте HEAD и изменения файлов с актуальной версией комплекта и проверьте реальные namespaces/endpoints в UI MetaMCP; если есть локальные изменения, сохраните их перед обновлением всех файлов вместе. Новый runner показывает каталог скриптов и отказывает до удаления, если `seed-local.sql` не содержит метку `MCPKIT_RESET_CONTRACT: short-names-v4`. Это только проверка совместимости, а не целостности локальных правок; старый runner такой проверки не делает. Уже выполненный сброс не отменяется обновлением кода; решение о повторном отдельном сбросе принимайте только после проверки состояния и резервной копии.

Если на старой установке сохранён список администраторов и новой учётной записи нужны права администратора, выполните `.\windows\run-local.ps1 seed -OwnerEmail 'ваш-email'` **после проверки предупреждений**: команда также является явным `seed` и добавляет отсутствующие public-записи. Она добавит существующую учётную запись к прежним администраторам; для применения может ещё раз пересоздаться только app с предварительным сохранением слоя. Для обычного использования public endpoints выбирать владельца не нужно, даже при нескольких учётных записях.

Команда `credentials` сохранена **только для доступа к распознаваемой старой автоматически созданной учётной записи** и показывает её исходный пароль. Если пароль уже изменён, показанное значение не актуально. Новой учётной записи или пароля команда не создаёт; не отправляйте её вывод никому.

#### Порты MetaMCP

Для новой установки порты Windows по умолчанию — **13008** (интерфейс и MCP endpoint) и **13009** (прямой доступ к backend). Оба публикуются только на `127.0.0.1`. На старой установке сохраняется прежний frontend-порт, а если в старом состоянии ещё нет `backendPort`, backend остаётся неопубликованным (`0`). Backend не нужен для обычного доступа: frontend проксирует запросы к нему. Внутри контейнера upstream по-прежнему использует 12008/12009; это не занимает эти порты Windows.

Для **уже установленного** MetaMCP задайте порты и запустите приложение без переустановки серверов:

```powershell
.\windows\run-local.ps1 set-ports -WebPort 13008 -BackendPort 13009
.\windows\run-local.ps1 ports
```

Для отключения прямого доступа к backend укажите `-BackendPort 0`. Для новой установки можно до первого запуска задать `$env:MCPKIT_METAMCP_PORT` и `$env:MCPKIT_METAMCP_BACKEND_PORT`; после создания установки используйте `set-ports`, а не редактирование внутренних файлов. Например, для новой установки с frontend на 14008 и без опубликованного backend:

```powershell
$env:MCPKIT_METAMCP_PORT = '14008'
$env:MCPKIT_METAMCP_BACKEND_PORT = '0'
.\windows\install-local.ps1
```

В этом примере UI и endpoints используют `http://localhost:14008`. `set-ports` сохраняет порты в `config\private\metamcp-state.json` и применяет их к `APP_URL`; значения портов, оставшиеся в `metamcp.env` после первоначальной установки, не определяют действующие порты.

Изменение портов, применение ручной регистрации к старой установке или добавление администратора останавливает и пересоздаёт **только** контейнер приложения: его записываемый слой сохраняется в локальном Docker-образе и используется новым контейнером. PostgreSQL, volumes, учётные данные и другие контейнеры не удаляются и не пересоздаются. Такой образ может содержать секреты — не публикуйте его. Если применение прервано, исправьте причину и повторите `start`: изменение останется ожидающим. При смене портов MCP-клиентам понадобится новый URL; активные сессии могут потребовать повторного входа.

По умолчанию данные хранятся в `%USERPROFILE%\mcp-local`; прежние `config\.env`, `config\mcp-local.json`, `config\local-settings.json`, `config\private\secrets.json` и данные не перезаписываются. Если задан `$env:MCP_LOCAL_DIR`, используйте его и при дальнейших запусках. MetaMCP получает свои отдельные имена контейнеров/volumes и отдельный приватный `config\private\metamcp.env`; чужие Docker-проекты не используются. Остановка не удаляет контейнеры или volumes.

PostgreSQL не публикуется на хост. По умолчанию Windows MCP-шлюз слушает `127.0.0.1:13001` и требует отдельный `gatewayApiKey` в заголовке `X-API-Key`. Например, прямой адрес одного сервера — `http://127.0.0.1:13001/servers/filesystem/mcp`; это не групповой endpoint MetaMCP. Один ключ шлюза даёт прямой доступ ко всем его серверам; клиентам MetaMCP он не нужен. При этом API-ключ MetaMCP тоже может давать доступ ко всем public-группам, как описано выше. Docker Desktop обращается к шлюзу через `host.docker.internal`; скрипт проверяет этот маршрут и не открывает доступ в LAN, если он не работает. Автоматической Docker-регистрации нужны IPv4 loopback и HTTP без TLS; другие настройки шлюза не настраивают удалённое подключение автоматически.

Не меняйте `hostId`, порт или ключ шлюза существующей установки без согласования с записями MetaMCP: `start` и `seed` не перезаписывают существующие подключения новым адресом или ключом. Любой, кто получит доступ к ключу шлюза, Docker или обладающей правами учётной записи, может получить широкие права на файлы и рабочий стол Windows — храните секреты и резервные копии БД приватно.

`ready` означает ответ на MCP `initialize`, а не проверку всех операций. `waiting` означает, что требуется настройка, и само по себе не считается ошибкой; `error` или остающийся `starting` даёт ненулевой код. При ошибке шлюза `start` всё равно пытается запустить MetaMCP и выполнить регистрацию, но стек может остаться работоспособным лишь частично. Например, для Obsidian нужен ключ плагина, а причину ошибки Codebase Memory смотрите в его журнале, не удаляя его кэш или данные. Перед отправкой журналов удалите секреты и личные пути.

#### Что нужно для отдельных серверов

- **Windows-MCP** управляет реальным рабочим столом. Нужна доступная интерактивная сессия и необходимые права; экран входа/UAC и заблокированный рабочий стол не гарантируют работу. **Desktop Commander** может выполнять команды и изменять файлы от имени пользователя, а Git — изменять репозитории. Ограничения каталогов `filesystem` не являются песочницей для остальных серверов.
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
- **Playwright** запускает установленный Chromium в headless-режиме. **DBHub** по умолчанию использует сохраняемый `data\dbhub.sqlite`; другой DSN можно указать в `dbhubDsn` в `secrets.json`. **Simple Files Vectorstore** следит за `writingDir`, при первом индексировании может скачать модель из Hugging Face и, согласно текущей реализации сервера, хранит индекс в памяти и перестраивает его после перезапуска. Поддерживаемые **MarkItDown** форматы зависят от установленного пакета и его зависимостей.

#### Локальное подключение к MetaMCP

Группы создаются один раз при `start`, в том числе до регистрации. Повторный автоматический запуск не восстанавливает намеренно удалённые записи и не перезаписывает настройки. Управляемые серверы и новые группы получают `user_id = NULL`; перевод старого namespace и endpoint в public выполняется только при безопасной миграции, как описано выше. Чужие и несовместимые записи сохраняются с предупреждением. В чужой или заменённый namespace инструменты не добавляются даже по `seed`; если в целевом namespace есть **хотя бы один endpoint без API-key и OAuth**, новые инструменты туда также не добавляются. Уже существующие mappings открытого endpoint могут быть доступны без ключа — защитите все endpoints. Выбор владельца для public-групп не требуется.

Если сеть Docker Desktop не даёт контейнеру обратиться к loopback-шлюзу Windows, команда сообщит об этом отдельно. Не меняйте адрес на `0.0.0.0` и не открывайте порт для решения проблемы: проверьте Docker Desktop и выполните `start` снова. Native Windows/Docker Desktop следует проверить на целевой машине.

## Обновление и восстановление

Перед обновлением сделайте независимую резервную копию, особенно если следующий `start` может выполнить миграцию Windows. Затем согласуйте простой и остановите соответствующий стек штатной командой `bash linux/run-global.sh stop` или `.\windows\run-local.ps1 stop`; убедитесь, что остановка завершилась. На Linux сначала проверьте владельцев контейнеров с фиксированными именами, как указано выше. Linux `stop` может лишь предупредить об ошибке и всё равно вывести итоговое сообщение: проверьте предупреждения и реальное состояние контейнеров, например через `bash linux/run-global.sh status` и `docker ps`. В каталоге комплекта проверьте ветку и локальные изменения, сохраните их отдельно и обновляйте **все файлы комплекта вместе**. Например, если текущая ветка отслеживает нужную удалённую ветку:

```sh
git status --short --branch
git log -1 --oneline
git pull --ff-only
```

Если обновление невозможно из-за локальных правок или расхождения веток, сначала разберите и сохраните их; не используйте `git reset --hard` или `git clean` как способ установки. Для копии из ZIP вместо `git pull` распакуйте новую версию в отдельный каталог и перенесите только согласованные пользовательские изменения, сохранив конфигурацию и данные. Затем из обновлённого каталога на Linux выполните `bash linux/run-global.sh start`, на Windows — `.\windows\run-local.ps1 start`. Windows-полная установка дополнительно переустанавливает/обновляет пакетные зависимости по манифесту и останавливает шлюз на время работы; `-MetaMcpOnly` этого не делает. Обычный запуск или повтор установщика не обновляет автоматически уже существующий клон MetaMCP; на Windows существующий управляемый образ также сохраняется. Не считайте обновление комплекта обновлением upstream-приложения.

### Независимые копии и восстановление

- **Windows:** сохраните актуальный согласованный PostgreSQL backup вне Docker volume и вне самого компьютера, а также каталог `%USERPROFILE%\mcp-local` (или `$env:MCP_LOCAL_DIR`), данные серверов и пользовательские проекты, включая данные вне этого каталога. Особенно важны `config\private\metamcp.env`, `metamcp-state.json` и `secrets.json`: они связаны с базой, ключом шлюза, путём клона и идентификатором Docker-проекта. Сохраните также нужные kit volumes и образы `*-app-backup:*`, если они используются. Образы, дампы, логи и эти файлы могут содержать секреты.
- **Linux:** сохраните `~/mcp-global/config`, `~/mcp-global/metamcp/.env` и пользовательские Compose-файлы, согласованный backup PostgreSQL, `~/mcp-global/data` для Neo4j/Qdrant и named volumes MetaMCP, Cognee, Memory Bank и GDrive. Для согласованности используйте средства резервного копирования соответствующих БД и сервисов; не считайте копию работающего каталога БД автоматически пригодной для восстановления.
- Автоматический Windows `pg_dump` при первом применении регистрации, миграции, явном `seed` или сбросе находится в `mcpkit-backups` **внутри того же PostgreSQL volume**, под `PGDATA`. Скопируйте нужную актуальную копию в защищённое независимое хранилище или заранее создайте отдельный backup; сам volume не является независимой копией. Дамп отражает состояние на момент своего создания и имеет PostgreSQL custom format (`pg_dump -Fc`). Для копирования готового файла из контейнера используйте бинарно-безопасный способ, например `docker cp` с фактического пути `<PGDATA>/mcpkit-backups/<имя>` внутри PostgreSQL-контейнера; значение `PGDATA` нужно определять внутри контейнера. Перенаправление вывода native-команды через `>` в Windows PowerShell 5.1 может повредить бинарный файл.
- В комплекте нет общей команды `restore` или автоматического переноса на другой компьютер. Проверяйте резервные копии в изолированной среде и используйте подходящие средства PostgreSQL/Docker и соответствующих серверов: например, документацию [PostgreSQL по резервному копированию](https://www.postgresql.org/docs/16/backup-dump.html), [`pg_restore`](https://www.postgresql.org/docs/16/app-pgrestore.html) для custom dump и [Docker по копированию volumes](https://docs.docker.com/engine/storage/volumes/#back-up-restore-or-migrate-data-volumes). Восстановление поверх существующей базы может перезаписать данные; сначала сохраните её и проверьте совместимость версий, путей, Docker-проекта и секретов. Если Windows-секрет или управляемый образ пропал, восстановите его из копии; не удаляйте оставшиеся state/volumes и не рассчитывайте на регенерацию ключей при переустановке.
- При прерванном изменении портов или конфигурации Windows исправьте причину и повторите `start`. Если результат **сброса** неизвестен, не повторяйте сброс: выполните `start`, проверьте UI и backup, как описано выше. Удалять оставшийся lock-файл допустимо только убедившись, что соответствующая операция действительно не выполняется; не убивайте неизвестный процесс и не удаляйте данные для освобождения порта.

## Seed regression tests

The integration tests require `psql`, `jq`, and a disposable PostgreSQL database (the test user must be allowed to create and drop a schema). Docker and system package installation are mocked; no real containers or system packages are changed.

```sh
TEST_DATABASE_URL='postgresql://user:password@localhost:5432/test_db' bash tests/test-global-seed.sh
TEST_DATABASE_URL='postgresql://user:password@localhost:5432/test_db' bash tests/test-local-seed.sh
TEST_DATABASE_URL='postgresql://user:password@localhost:5432/test_db' bash tests/test-windows-seed.sh
TEST_DATABASE_URL='postgresql://user:password@localhost:5432/test_db' bash tests/test-windows-reset.sh
```

Gateway and installer/lifecycle tests use Node 24 and an installed copy of `mcp-proxy@6.10.0`. The PowerShell tests also require PowerShell Core and Python 3 on a POSIX host; they run the actual scripts with synthetic installers and POSIX MCP executables:

```sh
npm install --prefix /tmp/mcp-proxy-test mcp-proxy@6.10.0
export MCP_PROXY_CLI=/tmp/mcp-proxy-test/node_modules/mcp-proxy/dist/bin/mcp-proxy.mjs
export MCP_POWERSHELL="$(command -v pwsh)"
node --test tests/test-windows-gateway.mjs tests/test-local-cli.mjs tests/test-windows-installer.mjs tests/test-windows-docker.mjs
```

An optional real semantic-search test uses an existing vectorstore installation and a pre-populated `Xenova/all-MiniLM-L6-v2` model cache (the model is about 90 MB). It forbids model downloads during the test and writes only to a temporary directory:

```sh
MCP_PROXY_CLI=/absolute/path/to/mcp-proxy.mjs \
MCP_VECTORSTORE_CLI=/absolute/path/to/simple-files-vectorstore/build/index.js \
MCP_VECTORSTORE_CACHE=/absolute/path/to/@xenova/transformers/.cache \
  node --test tests/test-vectorstore-real.mjs
```

These protocol/database tests do not replace a native Windows test of installation, desktop interaction, Everything, Chromium, Obsidian, firewall rules, or actual Docker Desktop networking.
