# Независимые MetaMCP и наборы MCP-серверов

Здесь описаны **новые** раздельные установки. MetaMCP, GLOBAL и LOCAL устанавливаются и запускаются независимо. Одну машину можно использовать для нескольких экземпляров MetaMCP и нескольких наборов, задав каждому свой каталог и свободный порт. Каждый экземпляр MetaMCP имеет отдельный Docker Compose-проект, PostgreSQL, тома и секреты. Существующие `~/mcp-global` и `%USERPROFILE%\mcp-local` не переносятся автоматически. Старые команды и ограничения описаны ниже в [README](../README.md#прежние-объединённые-установки).

## Перед началом

- Установите Git и Node.js **20+** для независимых Docker-проектов и регистрации. Для Linux LOCAL нужен Node.js **24+**, npm, Python **3.11–3.14** с `venv`/pip и инструменты сборки нативных модулей: закреплённый сервер filesystem требует Node.js 24. Версии и доступность отдельных пакетов зависят также от архитектуры системы.
- Для MetaMCP и GLOBAL нужны Docker Engine/Compose на Linux или Docker Desktop с Linux-контейнерами на Windows. Windows LOCAL может устанавливаться без Docker. На Linux скрипт запуска пытается поднять локальную службу через `systemctl` или `service` с `sudo`. Он не переустанавливает Docker и не запускает локальную службу для выбранного удалённого, rootless или Desktop endpoint. Доступ текущего пользователя к сокету Docker обязателен; после добавления в группу `docker` нужен новый вход. Членство в этой группе эквивалентно административным правам. На Windows скрипты запускают Docker Desktop и ждут его локальный `desktop-linux` контекст; может потребоваться закончить настройку WSL и перезагрузить компьютер.
- Независимые Docker-команды не используют удалённый демон и требуют, чтобы `DOCKER_HOST` и `DOCKER_CONTEXT` не были заданы. На Linux выбранный сохранённый контекст должен указывать на локальный Unix-сокет; на Windows проверяется локальный канал Docker Desktop. Существующие контексты и другие Docker-проекты не переключаются. Для диагностики Linux можно отдельно посмотреть `service docker status` и `docker info`; скрипты не выполняют `docker run hello-world`, чтобы не скачивать лишний образ и не создавать контейнер. При желании пользователь может самостоятельно выполнить `docker run --rm hello-world` в проверенном контексте: это скачает образ, если его ещё нет.
- Скачайте комплект и выполняйте команды из корня:

  ```sh
  git clone https://github.com/Multfinite/multfinite-mcp-kit.git
  cd multfinite-mcp-kit
  ```

  В Windows можно скачать ZIP через GitHub, распаковать и открыть PowerShell в этой папке. Запуск неподписанных PowerShell-скриптов зависит от политики вашей системы.
- Скрипты загружают пакеты и образы из интернета; для сборки и Chromium потребуется свободное место. Сборка MetaMCP закреплена на ревизии `05818ec2767b946f98d280ae9cefa401f0362d62`. Образы Neo4j, Qdrant, Graphiti и Cognee используют изменяемые теги; часть пакетов `npx`/`uvx` и моделей загружается при первом запуске. Готовность контейнера не гарантирует готовности всех инструментов.

## 1. Отдельный MetaMCP

Новый экземпляр **обязательно** получает порт от пользователя: установщик спрашивает его или принимает явно переданный параметр. Каталог должен быть новым либо пустым; чужое содержимое не заменяется. При повторном вызове для существующего экземпляра сохраняются его порт, база и секреты. Не редактируйте вручную `.mcpkit/state.json`: если порт занят, остановите конфликтующий сервис или создайте новый экземпляр в другом каталоге с другим портом.

### Linux

```sh
# Интерактивно: каталог, порт и необязательный внешний HTTPS-адрес.
bash linux/install-metamcp.sh

# Пример трёх раздельных экземпляров; каждый использует свой порт.
bash linux/install-metamcp.sh --dir "$HOME/mcp-kit/metamcp/global" --port 12008
bash linux/install-metamcp.sh --dir "$HOME/mcp-kit/metamcp/local-a" --port 13008
bash linux/install-metamcp.sh --dir "$HOME/mcp-kit/metamcp/local-b" --port 14008

bash linux/run-metamcp.sh status "$HOME/mcp-kit/metamcp/global"
bash linux/run-metamcp.sh stop   "$HOME/mcp-kit/metamcp/global"
bash linux/run-metamcp.sh start  "$HOME/mcp-kit/metamcp/global"
bash linux/run-metamcp.sh logs   "$HOME/mcp-kit/metamcp/global"
```

### Windows

```powershell
# Интерактивно: каталог, порт и необязательный внешний HTTPS-адрес.
.\windows\install-metamcp.ps1

.\windows\install-metamcp.ps1 -Directory "$env:USERPROFILE\mcp-kit\metamcp\global" -Port 12008
.\windows\install-metamcp.ps1 -Directory "$env:USERPROFILE\mcp-kit\metamcp\local-a" -Port 13008
.\windows\install-metamcp.ps1 -Directory "$env:USERPROFILE\mcp-kit\metamcp\local-b" -Port 14008

.\windows\run-metamcp.ps1 status "$env:USERPROFILE\mcp-kit\metamcp\global"
.\windows\run-metamcp.ps1 stop   "$env:USERPROFILE\mcp-kit\metamcp\global"
.\windows\run-metamcp.ps1 start  "$env:USERPROFILE\mcp-kit\metamcp\global"
.\windows\run-metamcp.ps1 logs   "$env:USERPROFILE\mcp-kit\metamcp\global"
```

`stop` проверяет сохранённое состояние и Docker-метки экземпляра и останавливает только его обычные контейнеры, даже если приватный `.env` отсутствует или повреждён; разовые Compose-контейнеры не останавливаются. В этом случае `status` показывает только состояние контейнеров. Для `start`, `apply` и удаления по-прежнему нужен корректный `.env`. Сгенерированные пароли и ключи имеют вид 64 строчных шестнадцатеричных символов без кавычек; для существующего экземпляра необходимо сохранить именно исходные значения. Не заменяйте их новыми при ошибке: пароль в файле сам по себе не изменяет пароль в уже созданной базе.

### Восстановление конфигурации MetaMCP на Linux

Если приватный `.env` MetaMCP случайно заменён, а его собственные остановленные контейнеры приложения и PostgreSQL, том базы и `state.json` сохранились, можно попробовать восстановить прежние секреты из конфигурации этих контейнеров:

```sh
bash linux/run-metamcp.sh recover-env /путь/к/экземпляру
```

Команда проверяет метки владельца, назначение тома и совпадение конфигурации контейнеров. Перед заменой `.env` требуется подтверждение; прежний файл сохраняется как приватная `.mcpkit/.env.before-recovery-*.backup`. Новый файл содержит настройки MetaMCP из контейнеров: остальные и ещё не применённые настройки остаются только в резервной копии. Восстановление не переносит настройки GLOBAL-серверов. Контейнеры и тома не удаляются и не запускаются, секреты не выводятся. Если проверки не прошли или существующее непустое значение секрета отличается от значения контейнера либо неоднозначно, восстановление откажет.

Значения Docker отражают конфигурацию **при создании контейнеров**, но не доказывают актуальность пароля базы или исторического секрета приложения. Например, пароль мог быть изменён через SQL, а контейнеры — пересозданы с другим `.env` поверх уже инициализированного тома; изменение `POSTGRES_PASSWORD` в конфигурации контейнера не меняет пароль существующей базы. Если вы знаете или подозреваете такое изменение, остановитесь и используйте проверенную резервную копию и ручную процедуру. Даже при успешном восстановлении том ещё нужно проверить при обычном запуске.

Интерфейс и MCP-точки по умолчанию доступны только через `127.0.0.1` на выбранном порту; PostgreSQL и backend наружу не опубликованы. Создайте свою учётную запись в интерфейсе, затем закройте регистрацию в настройках. Пустой `METAMCP_ADMIN_EMAILS` в исходном MetaMCP означает, что **каждый вошедший считается администратором**. Не открывайте регистрацию или незащищённый интерфейс в сеть. Новые команды пока не применяют изменения списка администраторов к уже созданному контейнеру: простое редактирование `.env` и `start` с `--no-recreate` недостаточно. Для многопользовательской публикации сначала настройте и проверьте ограничение администраторов средствами MetaMCP/Docker, сохранив БД и файлы контейнера; автоматического безопасного применения этого изменения здесь нет.

Для доступа с других машин заранее настройте DNS, TLS, обратный прокси и правила сети; приложение по-прежнему слушает loopback. При установке укажите внешний origin `https://mcp.example.org` на вопрос либо через `--app-url` (Linux) / `-PublicUrl` (Windows). Входите именно по этому адресу: даже `localhost` и `127.0.0.1` для браузера являются разными origin. Сам URL **не** создаёт DNS, сертификат или прокси. Выбранный origin добавляется к списку доверенных Better Auth наряду с дополнительными источниками из приватного `.env`; не добавляйте недоверенные адреса. Доверяйте прокси и учётной записи: MetaMCP хранит ключи подключённых серверов. Для изменения origin/порта после создания эта новая команда пока не делает безопасного пересоздания: не правьте состояние вручную; согласуйте резервную копию и создайте отдельный экземпляр или настраивайте существующий через средства MetaMCP/Docker.

## 2. Отдельный GLOBAL

Скрипт устанавливает общие для набора сервисы в собственном проекте Docker, **не устанавливает MetaMCP и не меняет его базу**. Порт шлюза должен отличаться от занятых портов MetaMCP/LOCAL.

```sh
# Linux: по умолчанию ~/mcp-kit/global; установщик спросит порт.
bash linux/install-global-servers.sh
# Или указать каталог и порт явно:
bash linux/install-global-servers.sh "$HOME/mcp-kit/global" 13002
bash linux/run-global-servers.sh status "$HOME/mcp-kit/global"
bash linux/run-global-servers.sh stop   "$HOME/mcp-kit/global"
bash linux/run-global-servers.sh start  "$HOME/mcp-kit/global"
bash linux/run-global-servers.sh logs   "$HOME/mcp-kit/global"
bash linux/run-global-servers.sh logs   "$HOME/mcp-kit/global" fetch
```

```powershell
# Windows: по умолчанию %USERPROFILE%\mcp-kit\global.
.\windows\install-global-servers.ps1
.\windows\install-global-servers.ps1 -Directory "$env:USERPROFILE\mcp-kit\global" -Port 13002
.\windows\run-global-servers.ps1 status "$env:USERPROFILE\mcp-kit\global"
.\windows\run-global-servers.ps1 stop   "$env:USERPROFILE\mcp-kit\global"
.\windows\run-global-servers.ps1 start  "$env:USERPROFILE\mcp-kit\global"
.\windows\run-global-servers.ps1 logs   "$env:USERPROFILE\mcp-kit\global"
.\windows\run-global-servers.ps1 logs   "$env:USERPROFILE\mcp-kit\global" fetch
```

GLOBAL включает перечисленные в README Sequential Thinking, Graphiti, Cognee, Memory Bank, Context7, DuckDuckGo, Fetch, GitHub, draw.io, MCP Compass и GDrive, а также прежние Neo4j, Qdrant и Playwright. GitHub — удалённый сервис, а не контейнер на этой машине. Остальные работают за одним шлюзом с отдельным ключом; контейнеры БД и внутренних сервисов не публикуют порты на хосте. Шлюз опубликован **только на loopback**. Не открывайте его в LAN без защищённого доступа.

`status` показывает контейнеры и состояния отдельных MCP-серверов; `ready` означает только успешный MCP `initialize`. При первом запуске пакеты могут ещё загружаться, а серверы без учётных данных могут оставаться в `waiting` или `starting`. Python-серверы запускаются в раздельных окружениях: Fetch закреплён на MCP SDK 1.26.0 из-за несовместимых изменений SDK 2, а другие пакеты могут использовать свои версии. Общая команда `logs` показывает журналы Compose; `logs <каталог> <server-id>` показывает соответствующий журнал сервера (для stdio-серверов шлюз должен работать). Журналы могут содержать секреты и личные данные.

Для Graphiti и Cognee задайте `LLM_API_KEY`, при необходимости `LLM_API_ENDPOINT`, модель и провайдер в приватном `<GLOBAL>/.mcpkit/.env`; Context7 поддерживает `CONTEXT7_API_KEY`. Используется синтаксис Docker Compose `.env`. Не изменяйте сгенерированные `MCPKIT_GATEWAY_KEY`, `MCPKIT_CONTROL_KEY` и `NEO4J_PASSWORD` без отдельного плана перенастройки: повторная регистрация намеренно не перезаписывает старые подключения, а смена пароля в файле не меняет пароль уже существующей БД. Применение настроек пересоздаёт **только** контейнеры шлюза, Graphiti и Cognee; их именованные тома сохраняются, но ручные файлы в записываемом слое контейнеров могут быть потеряны:

```sh
bash linux/run-global-servers.sh apply "$HOME/mcp-kit/global"
```

```powershell
.\windows\run-global-servers.ps1 apply "$env:USERPROFILE\mcp-kit\global"
```

Без LLM-ключа Graphiti и Cognee ожидают настройки. Для GitHub внесите подходящий токен **в созданную запись сервера MetaMCP** после регистрации. GDrive ждёт OAuth-токен в принадлежащем GLOBAL томе; получите его по [инструкции исходного сервера](https://github.com/modelcontextprotocol/servers-archived/tree/main/src/gdrive), сохраните текущий токен перед заменой и поместите новый в `/mcpkit/gdrive/credentials.json` контейнера `gdrive` с владельцем `node` и правами `0600`. Этот токен и данные доступны всем клиентам данного сервиса. Qdrant может загружать модель эмбеддингов; Playwright требует Chromium и системные библиотеки, а DuckDuckGo использует браузерную TLS-имитацию через `curl_cffi`, а не установленный браузер. Установка и готовность отдельных внешних сервисов зависят от их ключей, сети и текущих версий образов.

## 3. Отдельный LOCAL

### Windows

```powershell
# Установит только нативные серверы и шлюз, без Docker/MetaMCP.
.\windows\install-servers.ps1
.\windows\run-servers.ps1 status
.\windows\run-servers.ps1 logs filesystem
.\windows\run-servers.ps1 stop
.\windows\run-servers.ps1 start

# Ещё один набор: укажите другой каталог и свободный порт шлюза.
.\windows\install-servers.ps1 "$env:USERPROFILE\mcp-kit\local-work" -Port 13101
.\windows\run-servers.ps1 status -Directory "$env:USERPROFILE\mcp-kit\local-work"
```

По умолчанию используется **новый** `%USERPROFILE%\mcp-kit\local`, отдельно от прежнего `%USERPROFILE%\mcp-local`. Для другого набора передайте его пустой каталог в `install-servers.ps1`, затем используйте `-Directory <каталог>` в `run-servers.ps1` и тот же каталог в `connect-local.ps1`; либо задайте `$env:MCPKIT_LOCAL_DIR` для всех трёх команд. Параметр `-Port` действует только при создании настроек: повторная установка сохраняет прежний порт. Непустой каталог без собственного маркера и каталог со старым связанным MetaMCP не принимаются. Существующие установки не перезаписываются. Установщик может предложить WinGet, Everything, C++ Build Tools и загрузить Python/Chromium; флаги `-NonInteractive`, `-InstallBuildTools`, `-SkipEverything` и `-SkipBrowserDownload` описаны в [прежнем справочнике](configuration.md#windows-local-настройки-и-секреты). Всё, что зависит от рабочего стола, запускайте из интерактивного сеанса Windows.

### Linux

```sh
# Требуются Node 24+, npm, Python 3.11–3.14 с venv/pip, Git и компилятор.
# Каталог по умолчанию ~/mcp-kit/local, порт шлюза по умолчанию 13001.
bash linux/install-local-servers.sh
# Другой отдельный каталог и порт:
bash linux/install-local-servers.sh "$HOME/mcp-kit/local-work" 13003

bash linux/run-local-servers.sh status "$HOME/mcp-kit/local"
bash linux/run-local-servers.sh logs   "$HOME/mcp-kit/local" filesystem
bash linux/run-local-servers.sh stop   "$HOME/mcp-kit/local"
bash linux/run-local-servers.sh start  "$HOME/mcp-kit/local"
```

Пакеты ставятся в собственные npm-каталоги и отдельные Python venv. На Debian/Ubuntu может потребоваться самостоятельно установить `python3-venv`, `python3-pip`, `build-essential` и системные библиотеки Chromium. Если venv был прерван и не содержит `bin/python`, скрипт его не очищает: сохраните и проверьте каталог перед повтором. Чтобы пропустить загрузку Chromium, задайте `MCPKIT_SKIP_BROWSER_DOWNLOAD=1`; сервер Playwright тогда потребует браузер отдельно.

- Вместо Windows Everything используется **тот же `mcp-server-everything-search` с Linux-поиском через `locate/plocate`**. Установите `plocate` и `which`, затем инициализируйте индекс средствами вашей системы; `sudo updatedb` обходит файловую систему и выполняется только по вашему решению. Возможности и актуальность результатов отличаются от Windows Everything.
- Вместо Windows-MCP установлен **Universal Computer Control** (`linux-desktop`). Это другой сервер с другим набором инструментов: для управления экраном нужен интерактивный X11/XWayland-сеанс и `DISPLAY`, а доступность конкретных приложений зависит от сессии, библиотек и прав. Для управления окнами нужны `wmctrl` и/или `xdotool`; некоторые возможности требуют AT-SPI, OCR и дополнительных системных библиотек. Python-окружение изолировано и не обязательно видит системный пакет `python3-pyatspi`; доступность каждого backend проверяйте отдельно. Нативный Wayland/безголовый сервер не обещается. Необязательная собственная конфигурация аналога — `config/computer-control.yaml`; настройки другого `~/.universal-computer` не подхватываются. Инструменты могут управлять реальным рабочим столом, выполнять действия и передавать снимки экрана клиенту/модели. Рассмотрите отдельный сеанс или ВМ и ограничьте доверенных клиентов.
- Obsidian требует ключ Local REST API; доступ к нему ограничен loopback. CodeGraph/Serena/Codebase Memory требуют настройки или индексации проектов. DBHub, файловый доступ и Desktop Commander способны изменять данные. `ready` означает успешный MCP `initialize`, а не проверку каждой операции; `waiting` требует дополнительной настройки, а `starting`/`error` дают ненулевой код контроллера после ожидания. Файлы `config/local-settings.json`, `config/private/secrets.json`, данные и логи могут содержать секреты и пользовательские файлы.

## 4. Подключение набора к выбранному MetaMCP

Это отдельный интерактивный шаг для **каждой пары набор → MetaMCP**. Скрипт спрашивает:

1. Адрес интерфейса MetaMCP, например `https://mcp.example.org`.
2. Базовый URL шлюза, **доступный из самого MetaMCP**, например `https://gateway.example.org`. Это не обязательно тот адрес, который видит терминал. Для LOCAL он указывает на машину с LOCAL, для GLOBAL — на машину/контейнер GLOBAL.
3. Учётную запись MetaMCP: email/пароль или Cookie действующей сессии для SSO. Пароль и Cookie вводятся без отображения, не передаются аргументами и не сохраняются в журнале.

```sh
# Linux
bash linux/connect-local.sh  "$HOME/mcp-kit/local"
bash linux/connect-global.sh "$HOME/mcp-kit/global"
```

```powershell
# Windows: для LOCAL по умолчанию используется MCPKIT_LOCAL_DIR или mcp-kit\local.
.\windows\connect-local.ps1
.\windows\connect-global.ps1 "$env:USERPROFILE\mcp-kit\global"
```

Регистратор поддерживает frontend API MetaMCP ревизии, указанной выше; совместимость с произвольно изменёнными или другими версиями MetaMCP не гарантирована. Войдите в существующую учётную запись до подключения. Скрипт добавляет **новые приватные** серверы, пространства имён и конечные точки с обязательной проверкой API-ключа; GLOBAL означает состав сервисов, а не публичный доступ ко всем учётным записям. Каждой группе присваивается уникальный префикс `mcpkit-…`. Создайте **приватный API-ключ MetaMCP** в интерфейсе и передайте его MCP-клиенту; это не ключ шлюза. Существующие записи, сопоставления, настройки и намеренно удалённые ранее записи не обновляются и не удаляются.

Для удалённых машин настройте проверяемый HTTPS либо отдельно шифрованный туннель/VPN в **обе стороны, где это нужно**: регистратор должен достичь MetaMCP, а MetaMCP — шлюза. Обычный HTTP не шифрует пароль и ключ шлюза. Для нелокального HTTP скрипт требует ввести `TRUSTED TUNNEL`; делайте это только после проверки защищённой сети. Сертификаты должны быть доверенными и для Node на машине регистрации, и для приложения MetaMCP; скрипт не отключает проверку TLS. Он не устанавливает DNS, прокси, VPN, firewall или маршруты. Например, `localhost` внутри Docker-контейнера относится к контейнеру, а не к машине с серверами. Для адреса шлюза MetaMCP этой ревизии принимает DNS/IPv4, но не IPv6-литерал или percent-encoded путь.

### Два новых Docker-проекта на одной машине

Можно явно подключить **только выбранный принадлежащий kit MetaMCP** к сети принадлежащего kit GLOBAL и использовать напечатанный URL:

```sh
bash linux/link-global-metamcp.sh "$HOME/mcp-kit/global" "$HOME/mcp-kit/metamcp/global"
bash linux/connect-global.sh "$HOME/mcp-kit/global"
# Когда связь больше не нужна:
bash linux/link-global-metamcp.sh "$HOME/mcp-kit/global" "$HOME/mcp-kit/metamcp/global" --unlink
```

```powershell
.\windows\link-global-metamcp.ps1 "$env:USERPROFILE\mcp-kit\global" "$env:USERPROFILE\mcp-kit\metamcp\global"
.\windows\connect-global.ps1 "$env:USERPROFILE\mcp-kit\global"
.\windows\link-global-metamcp.ps1 "$env:USERPROFILE\mcp-kit\global" "$env:USERPROFILE\mcp-kit\metamcp\global" -Unlink
```

Связь добавляет приложение MetaMCP в отдельную внутреннюю сеть **только со шлюзом**: базы и незащищённые внутренние сервисы GLOBAL находятся в другой сети. Скрипт проверяет состав сети и откажет в подключении при неожиданном контейнере или прямом подключении MetaMCP к сети внутренних сервисов; самостоятельно отключать существующие подключения он не будет. Это не защита от администратора Docker или последующего ручного изменения сетей. Записи MetaMCP не редактируются, дополнительные порты на хосте не открываются. Внутренний Docker HTTP **не зашифрован**: подтверждение `TRUSTED TUNNEL` здесь допустимо только при доверии машине и всем контейнерам этой сети. После пересоздания контейнера MetaMCP связь может потребоваться добавить снова. Перед удалением GLOBAL отключите от сети все добавленные MetaMCP.

Для Windows LOCAL и Docker Desktop на той же машине можно попробовать `http://host.docker.internal:13001` как URL шлюза: работа маршрута loopback зависит от Docker Desktop. Для Linux LOCAL `host.docker.internal` в новом MetaMCP указывает на Docker host gateway, но слушающий только `127.0.0.1` шлюз обычно недоступен по адресу интерфейса моста. Либо используйте защищённый локальный прокси/туннель, либо после проверки сети явно настройте шлюз на **адрес Docker-моста**, не на публичный интерфейс: узнайте адрес через `docker network inspect bridge`, проверьте его через `ip address`, задайте `listenHost` и `allowInsecureLan: true` в Linux LOCAL `local-settings.json` и перезапустите LOCAL. Такая связь остаётся незашифрованной и доступной другим контейнерам с маршрутом до моста; фильтрация, изоляция и проверка результата остаются за администратором. Не открывайте `0.0.0.0` для обхода ошибки.

При обрыве связи создание может завершиться частично. Журнал в приватном `registrations/*.json` фиксирует UUID и отмечает операцию с неизвестным результатом. Скрипт **не угадывает** владельца записи по имени, не заменяет отредактированные записи и не повторяет неопределённую операцию. Проверьте журнал и интерфейс, сделайте резервную копию и вручную разберите незавершённый шаг, прежде чем повторять. Изменение URL или учётной записи создаёт отдельный набор записей; старые не удаляются.

## Резервное копирование и удаление

Сохраняйте согласованные резервные копии PostgreSQL и остальных БД вне Docker и вне машины, каталоги `.mcpkit`/LOCAL, секреты, пользовательские проекты и соответствующие тома. Отдельной автоматической миграции/восстановления между экземплярами нет. Инструкции по удалению с сохранением или явным удалением данных: [docs/uninstall.md](uninstall.md).
