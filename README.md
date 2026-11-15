# Multfinite MCP Kit

Multfinite MCP Kit устанавливает и управляет **независимыми** проектами MetaMCP, GLOBAL и LOCAL на Linux/WSL и Windows. Каждый компонент имеет собственный каталог и состояние; наборы можно подключать к выбранному экземпляру MetaMCP отдельными командами.

## Установка и подключение

Склонируйте репозиторий через Git или скачайте ZIP с GitHub. Установка MetaMCP требует Git и Node.js 20+; команды GLOBAL и регистрация требуют Node.js 20+. Linux LOCAL дополнительно требует Node.js 24+, npm, Python 3.11–3.14, Git и инструменты сборки. LOCAL работает нативно и не требует Docker; Windows-установщик может установить Git и изолированные runtime. MetaMCP/GLOBAL требуют Docker Engine/Compose на Linux или Docker Desktop с Linux-контейнерами на Windows.

```sh
# Linux: компоненты устанавливаются отдельно.
bash linux/install-metamcp.sh
bash linux/install-global-servers.sh
bash linux/install-local-servers.sh

# Подключение к выбранному MetaMCP выполняется отдельным шагом.
bash linux/connect-global.sh
bash linux/connect-local.sh
```

```powershell
# Windows: компоненты устанавливаются отдельно.
.\windows\install-metamcp.ps1
.\windows\install-global-servers.ps1
.\windows\install-local-servers.ps1

# Подключение к выбранному MetaMCP выполняется отдельным шагом.
.\windows\connect-global.ps1
.\windows\connect-local.ps1 "$env:USERPROFILE\mcp-kit\local"
```

Установщики спрашивают необходимые каталоги и порты. Подробные требования, варианты установки, параметры и команды управления приведены в [руководстве по раздельной установке](docs/independent-installation.md).

Регистрация требует учётную запись администратора MetaMCP и создаёт **общие** серверы, пространства имён и конечные точки. По умолчанию каждый MCP endpoint ограничен namespace ровно с одним сервером; явное отключение настройки и ручной Compose-сценарий описаны в [конфигурации](docs/configuration.md#metamcp). Адрес шлюза в записях должен открываться **из приложения MetaMCP**, а не только с компьютера, где запущен регистратор. Пользователи MetaMCP получают доступ к зарегистрированным инструментам и настроенным данным. LOCAL может управлять файлами, терминалом, базами и рабочим столом; регистрируйте только в доверенном MetaMCP и ограничивайте доступ пользователей и API-ключей.

## Состав наборов

**GLOBAL:** `sequentialthinking`, `graphiti`, `cognee`, `memory-bank-mcp`, `context7`, `duckduckgo-mcp-server`, `fetch`, `github-mcp-server`, `drawio-mcp`, `mcp-compass`, `gdrive`, `mcp-neo4j-cypher`, `mcp-server-qdrant`, `playwright-mcp`.

**LOCAL:** `DesktopCommanderMCP`, `mcp-everything-search`, `filesystem-mcp`, `git`, `codegraph`, `codebase-memory-mcp`, `serena`, `playwright-mcp`, `dbhub`, `simple-files-vectorstore`, `markitdown-mcp`, `mcp-obsidian`. На Windows используется `Windows-MCP`, на Linux — `universal-computer-control`.

Состав и имена для регистрации определены в `common/registration-manifest.mjs`; закреплённые версии и образы — в `windows/manifest.json`, `common/global/global-kit.mjs`, Compose-файлах и установщиках платформ.

## Документация

- [Раздельная установка, настройки, регистрация и управление](docs/independent-installation.md)
- [Конфигурация текущих установок](docs/configuration.md)
- [Безопасное удаление проектов и данных](docs/uninstall.md)
- [Одностороннее подключение одного MetaMCP к другому](docs/independent-installation.md#metamcp-to-metamcp)
- [Windows LOCAL → MetaMCP в WSL 2](docs/windows-local-to-wsl-metamcp.md)
- [Сеть Hyper-V, WSL 2 и Windows-ВМ](docs/wsl-hyperv-network.md)

Для сетевой связи между компьютерами заранее настройте проверяемый HTTPS либо отдельный защищённый туннель/VPN, маршруты и брандмауэр. Установка и регистраторы сами не создают сетевую инфраструктуру. HTTP не шифрует пароль, ключи и MCP-трафик.

## Проверки для разработки

Тесты регистрации и связанных текущих механизмов используют локальные фикстуры и не требуют запуска production MetaMCP:

```sh
node --test \
  tests/test-local-registration.mjs \
  tests/test-metamcp-link.mjs \
  tests/test-metamcp-peer-registration.mjs \
  tests/test-metamcp-single-server-policy.mjs
bash tests/test-linux-service-registration.sh
```

Для end-to-end теста Windows LOCAL gateway нужны PowerShell Core, `mcp-proxy@6.10.0` и Node.js 24+; см. комментарии и переменные окружения в `tests/test-windows-gateway.mjs` и `tests/test-local-cli.mjs`. Тест `tests/test-vectorstore-real.mjs` необязателен и требует заранее установленного vectorstore и кэша модели.
