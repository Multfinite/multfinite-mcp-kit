# Независимые MetaMCP и наборы MCP-серверов

Это руководство описывает текущие независимые установки. MetaMCP, GLOBAL и LOCAL устанавливаются и запускаются отдельно. На одной машине можно создать несколько экземпляров MetaMCP и наборов, указав каждому собственный каталог и свободный порт. Каждый экземпляр MetaMCP имеет отдельный Docker Compose-проект, PostgreSQL, тома и секреты. Для каждого нового компонента выбирайте предназначенный ему каталог; его состояние нельзя переносить редактированием файлов вручную.

## Перед началом

- Для установки MetaMCP нужны Git и Node.js **20+**; команды GLOBAL и регистрация требуют Node.js **20+**. Если репозиторий получен через `git clone`, Git нужен и для этого шага. Linux LOCAL требует Node.js **24+**, npm, Python **3.11–3.14** с `venv`/pip, Git и инструменты сборки нативных модулей: закреплённый сервер filesystem требует Node.js 24. Windows LOCAL может установить Git и изолированные runtime через WinGet. Версии и доступность отдельных пакетов зависят также от архитектуры системы.
- Для MetaMCP и GLOBAL нужны Docker Engine/Compose на Linux или Docker Desktop с Linux-контейнерами на Windows. LOCAL работает нативно и Docker не использует; Windows-установщик может установить изолированные runtime. Команды MetaMCP/GLOBAL, которым нужен Docker Engine, при необходимости пытаются запустить локальный сервис на Linux через `systemctl` или `service` с `sudo`, а на Windows могут запустить Docker Desktop и ждут его локальный `desktop-linux` контекст. Команды `status`/`stop` не запускают остановленный Engine. Скрипты не устанавливают и не переустанавливают Docker, не запускают службу для выбранного удалённого, rootless или Desktop endpoint. Доступ текущего пользователя к сокету Docker обязателен; после добавления в группу `docker` нужен новый вход. Членство в этой группе эквивалентно административным правам. На Windows может потребоваться закончить первоначальную настройку WSL и перезагрузить компьютер.
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
bash linux/run-metamcp.sh apply  "$HOME/mcp-kit/metamcp/global"
bash linux/run-metamcp.sh logs   "$HOME/mcp-kit/metamcp/global"

# Optional per-user systemd autostart; register starts this MetaMCP now.
bash linux/run-metamcp.sh register-service "$HOME/mcp-kit/metamcp/global"
bash linux/run-metamcp.sh unregister-service "$HOME/mcp-kit/metamcp/global"
```

`register-service` creates a user systemd unit for this one MetaMCP instance, starts it immediately, and enables it for the user's systemd session. It does not enable WSL/systemd itself or start the WSL distribution from Windows. WSL boot configuration and registering multiple instances are described below in [Autostart for a complete WSL setup](#autostart-for-a-complete-wsl-setup).

### Windows

```powershell
# Интерактивно: каталог, порт и необязательный внешний HTTPS-origin.
.\windows\install-metamcp.ps1

.\windows\install-metamcp.ps1 -Directory "$env:USERPROFILE\mcp-kit\metamcp\global" -Port 12008
.\windows\install-metamcp.ps1 -Directory "$env:USERPROFILE\mcp-kit\metamcp\local-a" -Port 13008
.\windows\install-metamcp.ps1 -Directory "$env:USERPROFILE\mcp-kit\metamcp\local-b" -Port 14008

.\windows\run-metamcp.ps1 status "$env:USERPROFILE\mcp-kit\metamcp\global"
.\windows\run-metamcp.ps1 stop   "$env:USERPROFILE\mcp-kit\metamcp\global"
.\windows\run-metamcp.ps1 start  "$env:USERPROFILE\mcp-kit\metamcp\global"
.\windows\run-metamcp.ps1 apply  "$env:USERPROFILE\mcp-kit\metamcp\global"
.\windows\run-metamcp.ps1 logs   "$env:USERPROFILE\mcp-kit\metamcp\global"
```

Windows `install-metamcp.ps1` принимает `-Directory`, `-Port` и `-PublicUrl`; новый экземпляр всегда требует порт, который скрипт спросит, если он не передан. Установщик Linux имеет дополнительные first-setup и LAN-опции, описанные ниже. На обеих платформах приложение по умолчанию публикуется только на loopback хоста.

`stop` проверяет сохранённое состояние и Docker-метки экземпляра и останавливает только его обычные контейнеры, даже если приватный `.env` отсутствует или повреждён; разовые Compose-контейнеры не останавливаются. В этом случае `status` показывает только состояние контейнеров. Для `start`, `apply` и удаления по-прежнему нужен корректный `.env`. Сгенерированные пароли и ключи имеют вид 64 строчных шестнадцатеричных символов без кавычек; для существующего экземпляра необходимо сохранить именно исходные значения. Не заменяйте их новыми при ошибке: пароль в файле сам по себе не изменяет пароль в уже созданной базе.

Если оба собственных контейнера ещё существуют, сравните секреты в `.env` с их сохранённой конфигурацией, не выводя значения. Контейнеры могут быть как запущены, так и остановлены:

```sh
bash linux/run-metamcp.sh check-env "$HOME/mcp-kit/metamcp/global"
```

```powershell
.\windows\run-metamcp.ps1 check-env "$env:USERPROFILE\mcp-kit\metamcp\global"
```

Команда ничего не изменяет и не запускает Docker; для проверки применяет также `docker compose config --format json`. Несовпадение, ошибка разбора `.env` или отсутствие контейнера требует разбирательства до запуска/пересоздания. **Совпадение не доказывает** актуальность пароля внутри PostgreSQL или исторического секрета авторизации: контейнеры могли быть пересозданы с ошибочной конфигурацией поверх существующего тома. Успех также не подтверждает целостность базы или готовность приложения.

### Первый запуск без публикации до настройки администратора (Linux)

Для нового MetaMCP, который планируется опубликовать через reverse proxy, безопаснее сначала выполнить встроенный staged setup. Установщик запустит app и PostgreSQL без host-порта, создаст/проверит администратора и API-ключ, закроет email- и SSO-регистрацию, проверит эти условия и только затем опубликует app на loopback. Нужны интерактивный терминал и Docker Compose 2.24.4 или новее:

```sh
bash linux/install-metamcp.sh --setup --dir "$HOME/mcp-kit/metamcp/public" --port 12008 --app-url "https://mcp.example.org" --admin-email "admin@example.org"
```

Скрипт запросит пароль администратора скрытым вводом. Внешний HTTPS reverse proxy, DNS и firewall не настраиваются. До подтверждения успешного завершения не создавайте внешний маршрут к app. После завершения проверьте состояние, приватный файл `.mcpkit/client-api-key` и закройте доступ к нему; эта команда не публикует ключ в терминал.

`--setup` сейчас доступен в Linux-установщике. Windows `install-metamcp.ps1` не выполняет staged setup; не считайте обычный запуск Windows-установщика эквивалентным сценарию без публикации. На Linux для ручного staged workflow существуют также `--staged` и `bash linux/run-metamcp.sh setup <каталог>`, но не запускайте их повторно поверх опубликованной или уже настроенной установки.

Linux также поддерживает явную привязку MetaMCP к одному локальному IPv4-адресу, только совместно с явным подтверждением HTTP-риска:

```sh
bash linux/install-metamcp.sh --dir "$HOME/mcp-kit/metamcp/lan" --port 12008 --lan-ip 192.168.100.20 --allow-insecure-lan
```

`--lan-ip` принимает только адрес RFC 1918, уже назначенный этому Linux-хосту; Compose публикует порт приложения на loopback и на этом IPv4, а `APP_URL` использует этот адрес как единственный origin. Комплект не добавляет в MetaMCP поддержку нескольких origin, не шифрует HTTP-трафик и не создаёт firewall/VPN. Применяйте привязку только в отдельно проверенной и ограниченной сети. Windows-установщик этих Linux-only параметров не принимает.

Комплект клонирует и собирает закреплённую версию upstream MetaMCP **без изменения его исходников**. Он не реализует дополнительные runtime-политики endpoint, чистые имена инструментов или multi-origin authentication. Поведение namespaces, endpoints и авторизации определяется самой версией MetaMCP. Установщик не принимает `--clean-tools`.

Существующие установки, созданные более ранними версиями комплекта, могли уже получить изменённый исходный код или образ. Новый комплект не исправляет, не очищает и не переписывает такой исходный clone автоматически. Он использует имеющийся образ, если тот уже есть; перед сборкой нового образа откажет, если принадлежащий экземпляру upstream clone содержит локальные изменения. Сохраните данные и отдельно проверьте план перехода на чистую upstream-копию; не удаляйте clone или контейнеры вслепую. `--fresh` отказывает, если выбранный каталог уже содержит состояние экземпляра; он ничего не очищает и не удаляет.

### Восстановление конфигурации MetaMCP на Linux

Если приватный `.env` MetaMCP случайно заменён, а его собственные остановленные контейнеры приложения и PostgreSQL, том базы и `state.json` сохранились, можно попробовать восстановить прежние секреты из конфигурации этих контейнеров:

```sh
bash linux/run-metamcp.sh recover-env /путь/к/экземпляру
```

Команда проверяет метки владельца, назначение тома и совпадение конфигурации контейнеров. Перед заменой `.env` требуется подтверждение; прежний файл сохраняется как приватная `.mcpkit/.env.before-recovery-*.backup`. Новый файл содержит настройки MetaMCP из контейнеров: остальные и ещё не применённые настройки остаются только в резервной копии. Восстановление не переносит настройки GLOBAL-серверов. Контейнеры и тома не удаляются и не запускаются, секреты не выводятся. Если проверки не прошли или существующее непустое значение секрета отличается от значения контейнера либо неоднозначно, восстановление откажет.

Значения Docker отражают конфигурацию **при создании контейнеров**, но не доказывают актуальность пароля базы или исторического секрета приложения. Например, пароль мог быть изменён через SQL, а контейнеры — пересозданы с другим `.env` поверх уже инициализированного тома; изменение `POSTGRES_PASSWORD` в конфигурации контейнера не меняет пароль существующей базы. Если вы знаете или подозреваете такое изменение, остановитесь и используйте проверенную резервную копию и ручную процедуру. Даже при успешном восстановлении том ещё нужно проверить при обычном запуске.

### Адрес и настройки администратора MetaMCP

`APP_URL` задаётся при установке через `--app-url` (Linux) или `-PublicUrl` (Windows) и сохраняется в приватном `<MetaMCP>/.mcpkit/.env`. Чтобы изменить адрес или другие параметры, отредактируйте только **соответствующие строки**, не заменяя файл целиком и не меняя секреты базы и авторизации:

```dotenv
APP_URL='https://mcp.example.org'
METAMCP_ADMIN_EMAILS='admin@example.org'
EXTRA_TRUSTED_ORIGINS='https://another-trusted.example.org'
```

`APP_URL` должен быть буквально записан как `APP_URL=...` без `export`, пробелов вокруг имени, интерполяции и комментария в строке. Он содержит только схему, хост и необязательный порт, без пути; для нелокального адреса требуется HTTPS. Приложение получает его одновременно как `APP_URL` и `NEXT_PUBLIC_APP_URL`, а также как доверенный origin Better Auth. `EXTRA_TRUSTED_ORIGINS` — необязательный список **дополнительных** origin через запятую; он сам по себе не меняет основной `APP_URL`. Не добавляйте недоверенные адреса.

Редактирование `.env` и обычный `start` не пересоздают имеющийся контейнер. Сначала убедитесь, что исходные секреты корректны, сделайте согласованную резервную копию базы и сохраните необходимые вручную созданные файлы из записываемого слоя app-контейнера. Резервная копия нужна **до запуска приложения**, поскольку исходный MetaMCP может выполнять миграции базы при каждом старте. Затем запустите MetaMCP и дождитесь состояния `healthy` у приложения и PostgreSQL. Создайте перечисленные учётные записи и закройте регистрацию **до публикации сервиса**: исходная версия не требует подтверждения email при регистрации. Пустой `METAMCP_ADMIN_EMAILS` означает, что **каждый вошедший считается администратором**. Примените настройки:

```sh
bash linux/run-metamcp.sh apply "$HOME/mcp-kit/metamcp/global"
```

```powershell
.\windows\run-metamcp.ps1 apply "$env:USERPROFILE\mcp-kit\metamcp\global"
```

Если параметры уже совпадают с конфигурацией app-контейнера, команда ничего не пересоздаёт; проверьте его статус отдельно. Иначе интерактивная команда использует `docker compose config --format json`, проверяет принадлежность контейнеров, существующие секреты, тома и образ, а затем после подтверждения пересоздаёт только приложение с `--no-deps`: PostgreSQL и именованные тома не пересоздаются и не удаляются. Содержимое записываемого слоя приложения при этом теряется; запуск приложения может изменить схему базы миграциями. Дополнительные или неожиданные сети, монтирования, порты, переменные окружения и некоторые изменённые настройки запуска вызывают отказ: например, сначала сохраните данные подключения и явно отсоедините сеть GLOBAL командой `link-global-metamcp.sh ... --unlink`, а после применения подключите её снова. Проверка не охватывает все возможные ручные изменения контейнера. Не запускайте параллельно другие команды комплекта и не редактируйте `.env` во время применения. При сбое во время пересоздания сначала изучите состояние, а не повторяйте команду вслепую.

Интерфейс и MCP-точки по умолчанию слушают только `127.0.0.1` на выбранном порту; PostgreSQL и backend наружу не опубликованы. Для доступа извне отдельно настройте DNS, сертификат, HTTPS reverse proxy и маршруты до этого loopback-порта: сам `APP_URL` их не создаёт. Входите по основному настроенному адресу: даже `localhost` и `127.0.0.1` для браузера являются разными origin. При смене адреса существующим клиентам может потребоваться заново войти и обновить URL. Текущая команда не меняет порт и не настраивает сеть или прокси.

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

# Optional: register/start the per-user systemd service, or remove registration.
bash linux/run-global-servers.sh register-service "$HOME/mcp-kit/global"
bash linux/run-global-servers.sh unregister-service "$HOME/mcp-kit/global"
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

# Optional: register a per-user Task Scheduler logon task, or remove it.
.\windows\run-global-servers.ps1 register-service "$env:USERPROFILE\mcp-kit\global"
.\windows\run-global-servers.ps1 unregister-service "$env:USERPROFILE\mcp-kit\global"
```

GLOBAL включает Sequential Thinking, Graphiti, Cognee, Memory Bank, Context7, DuckDuckGo, Fetch, GitHub, draw.io, MCP Compass, GDrive, Neo4j, Qdrant и Playwright. GitHub — удалённый сервис, а не контейнер на этой машине. Остальные работают за одним шлюзом с отдельным ключом; контейнеры БД и внутренних сервисов не публикуют порты на хосте. Шлюз опубликован **только на loopback**. Не открывайте его в LAN без защищённого доступа.

Регистрация автозапуска необязательна. Linux-команда создаёт пользовательскую systemd-службу, запускает её сразу и включает для входа пользователя; нужен доступный `systemctl --user` (обычно systemd-enabled Linux/WSL user session). Windows-команда регистрирует задачу Task Scheduler для входа текущего пользователя и запрашивает немедленный запуск. `unregister-service` удаляет только регистрацию автозапуска; уже работающий стек остаётся запущенным. GLOBAL-команды запускают только выбранный independent GLOBAL-каталог и не запускают MetaMCP.

`status` показывает контейнеры и состояния отдельных MCP-серверов; `ready` означает только успешный MCP `initialize`. При первом запуске пакеты могут ещё загружаться, а серверы без учётных данных могут оставаться в `waiting` или `starting`. Python-серверы запускаются в раздельных окружениях: Fetch закреплён на MCP SDK 1.26.0 из-за несовместимых изменений SDK 2, а другие пакеты могут использовать свои версии. Общая команда `logs` показывает журналы Compose; `logs <каталог> <server-id>` показывает соответствующий журнал сервера (для stdio-серверов шлюз должен работать). Журналы могут содержать секреты и личные данные.

Для Graphiti и Cognee задайте `LLM_API_KEY`, при необходимости `LLM_API_ENDPOINT`, модель и провайдер в приватном `<GLOBAL>/.mcpkit/.env`; Context7 поддерживает `CONTEXT7_API_KEY`. Используется синтаксис Docker Compose `.env`. Не изменяйте сгенерированные `MCPKIT_GATEWAY_KEY`, `MCPKIT_CONTROL_KEY` и `NEO4J_PASSWORD` без отдельного плана перенастройки: повторная регистрация намеренно не перезаписывает существующие подключения, а смена пароля в файле не меняет пароль уже существующей БД. Применение настроек пересоздаёт **только** контейнеры шлюза, Graphiti и Cognee; их именованные тома сохраняются, но ручные файлы в записываемом слое контейнеров могут быть потеряны:

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
# Устанавливает только Windows LOCAL-серверы и шлюз, без Docker/MetaMCP.
.\windows\install-local-servers.ps1
.\windows\run-local-servers.ps1 status "$env:USERPROFILE\mcp-kit\local"
.\windows\run-local-servers.ps1 logs "$env:USERPROFILE\mcp-kit\local" filesystem
.\windows\run-local-servers.ps1 stop "$env:USERPROFILE\mcp-kit\local"
.\windows\run-local-servers.ps1 start "$env:USERPROFILE\mcp-kit\local"

# Ещё один набор: выберите отдельный каталог и свободный порт шлюза.
.\windows\install-local-servers.ps1 "$env:USERPROFILE\mcp-kit\local-work" -Port 13101
.\windows\run-local-servers.ps1 status "$env:USERPROFILE\mcp-kit\local-work"

# Необязательный автозапуск gateway через Task Scheduler текущего пользователя.
.\windows\run-local-servers.ps1 register-service "$env:USERPROFILE\mcp-kit\local"
.\windows\run-local-servers.ps1 unregister-service "$env:USERPROFILE\mcp-kit\local"
```

По умолчанию `install-local-servers.ps1` использует `%USERPROFILE%\mcp-kit\local`. Для каждой команды управления и регистрации используйте тот же каталог; `$env:MCPKIT_LOCAL_DIR` задаёт каталог по умолчанию для команд LOCAL. Параметр `-Port` действует только при создании настроек. Установщик сохраняет существующие настройки и отказывает для непустого каталога без состояния комплекта. Он может установить Git/Node.js через WinGet, скачать Python/Chromium и предложить Everything или C++ Build Tools; параметры `-NonInteractive`, `-InstallBuildTools`, `-SkipEverything` и `-SkipBrowserDownload` передаются текущим установщиком. Всё, что зависит от рабочего стола, запускайте из интерактивного сеанса Windows. Поля конфигурации описаны в [справочнике](configuration.md#local-windows-и-linux).

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

# Optional per-user systemd autostart; register also starts the gateway now.
bash linux/run-local-servers.sh register-service "$HOME/mcp-kit/local"
bash linux/run-local-servers.sh unregister-service "$HOME/mcp-kit/local"
```

Пакеты ставятся в собственные npm-каталоги и отдельные Python venv. На Debian/Ubuntu может потребоваться самостоятельно установить `python3-venv`, `python3-pip`, `build-essential` и системные библиотеки Chromium. Если venv был прерван и не содержит `bin/python`, скрипт его не очищает: сохраните и проверьте каталог перед повтором. Чтобы пропустить загрузку Chromium, задайте `MCPKIT_SKIP_BROWSER_DOWNLOAD=1`; сервер Playwright тогда потребует браузер отдельно. Регистрация `register-service` создаёт пользовательскую systemd-службу и запускает gateway; нужен доступный `systemctl --user`. `unregister-service` снимает автозапуск, не останавливая уже работающий gateway.

- Вместо Windows Everything используется **тот же `mcp-server-everything-search` с Linux-поиском через `locate/plocate`**. Установите `plocate` и `which`, затем инициализируйте индекс средствами вашей системы; `sudo updatedb` обходит файловую систему и выполняется только по вашему решению. Возможности и актуальность результатов отличаются от Windows Everything.
- Вместо Windows-MCP установлен **Universal Computer Control** (`linux-desktop`). Это другой сервер с другим набором инструментов: для управления экраном нужен интерактивный X11/XWayland-сеанс и `DISPLAY`, а доступность конкретных приложений зависит от сессии, библиотек и прав. Для управления окнами нужны `wmctrl` и/или `xdotool`; некоторые возможности требуют AT-SPI, OCR и дополнительных системных библиотек. Python-окружение изолировано и не обязательно видит системный пакет `python3-pyatspi`; доступность каждого backend проверяйте отдельно. Нативный Wayland/безголовый сервер не обещается. Необязательная собственная конфигурация аналога — `config/computer-control.yaml`; настройки другого `~/.universal-computer` не подхватываются. Инструменты могут управлять реальным рабочим столом, выполнять действия и передавать снимки экрана клиенту/модели. Рассмотрите отдельный сеанс или ВМ и ограничьте доверенных клиентов.
- Obsidian требует ключ Local REST API; доступ к нему ограничен loopback. CodeGraph/Serena/Codebase Memory требуют настройки или индексации проектов. DBHub, файловый доступ и Desktop Commander способны изменять данные. `ready` означает успешный MCP `initialize`, а не проверку каждой операции; `waiting` требует дополнительной настройки, а `starting`/`error` дают ненулевой код контроллера после ожидания. Файлы `config/local-settings.json`, `config/private/secrets.json`, данные и логи могут содержать секреты и пользовательские файлы.

### Автозапуск полного набора в WSL 2

Автозапуск состоит из двух частей: systemd запускает зарегистрированные компоненты **после старта Debian**, а Windows должен запустить саму WSL-дистрибуцию. Команды ниже запускайте из Debian под тем же Linux-пользователем, которому принадлежат установки; укажите реальные каталоги всех экземпляров (путь из сохранённого состояния должен совпадать с текущим).

1. Включите systemd в WSL. Сохраните существующие настройки `/etc/wsl.conf` и добавьте в него, если такого раздела/параметра ещё нет:

   ```ini
   [boot]
   systemd=true
   ```

   В PowerShell Windows выполните `wsl --shutdown`, затем снова откройте Debian. Проверьте `ps -p 1 -o comm=` (ожидается `systemd`) и `systemctl --user show-environment`.

2. Включите пользовательский systemd manager без интерактивного входа. Команда требует sudo один раз:

   ```sh
   sudo loginctl enable-linger "$USER"
   loginctl show-user "$USER" -p Linger
   ```

   В результате ожидается `Linger=yes`. Для Docker Engine, установленного внутри Debian, проверьте его автозапуск и доступ к сокету:

   ```sh
   sudo systemctl enable --now docker
   docker info
   ```

   Если Docker установлен/управляется иначе, не выполняйте эту команду вслепую: выберите и настройте именно тот локальный Docker Engine, который используют текущие проекты. Независимые установки комплекта не переключают Docker context и не используют удалённый daemon.

3. Зарегистрируйте **каждую** WSL-установку отдельно. Повторите MetaMCP-команду для всех трёх каталогов, а команды GLOBAL и Linux LOCAL — для тех наборов, которые действительно установлены в Debian. Примеры путей ниже замените точными текущими путями:

   ```sh
   KIT="$HOME/mcp-kit"
   # Сначала шлюзы MCP, затем все экземпляры MetaMCP.
   bash linux/run-global-servers.sh register-service "$KIT/global"
   bash linux/run-local-servers.sh register-service "$KIT/local"
   bash linux/run-metamcp.sh register-service "$KIT/metamcp/global-localhost"
   bash linux/run-metamcp.sh register-service "$KIT/metamcp/local-wslhost"
   bash linux/run-metamcp.sh register-service "$KIT/metamcp/local-vmhost"
   ```

   Замените примеры на **точные каталоги ваших установок**; повторите регистрацию для каждого установленного GLOBAL/LOCAL и MetaMCP. `register-service` сразу запускает выбранный компонент и включает его в systemd. MCP Kit связывает GLOBAL/LOCAL units с `mcpkit-mcp-servers.target`, а MetaMCP — с порядком `After=mcpkit-mcp-servers.target`: при следующем старте сначала завершаются команды запуска шлюзов, затем запускаются MetaMCP. Для запуска в текущем сеансе регистрируйте шлюзы первыми, как в примере. Повторная регистрация заменяет только принадлежащий комплекту unit, обновляет конфигурацию и повторяет запуск — этим можно исправить ранее созданный неисправный unit.

   Для диагностики используйте `systemctl --user --failed`, `systemctl --user status mcpkit-mcp-servers.target`, `systemctl --user status 'mcpkit-*'` и соответствующие `run-*.sh status <каталог>` команды. У LOCAL запуск desktop-control всё равно зависит от существующей интерактивной графической сессии, а отдельные MCP-серверы могут оставаться `waiting` без ключей/настроек. GLOBAL управляет всеми серверами своего GLOBAL-шлюза; команда не запускает серверы MetaMCP или Windows/VM LOCAL.

4. Настройте запуск Debian при входе в Windows. Задача должна держать один долгоживущий процесс: короткая команда вроде `/bin/true` открывает только сеанс, после чего WSL останавливает дистрибутив, и включённым units нечего выполнять. В Планировщике заданий создайте задачу с триггером **At log on** для вашей учётной записи и действием:

   - Program/script: `C:\Windows\System32\wsl.exe`
   - Arguments: `-d Debian --exec sleep infinity`

   Идентификатор `Debian` должен совпадать с `wsl -l -q`. Готовые команды PowerShell, параметры задачи, приёмка, обслуживание и ограничения описаны в [руководстве по автозапуску WSL](wsl-autostart.md). Если нужен запуск до входа пользователя Windows, задачу планировщика нужно отдельно настроить с учётом политики Windows и доступности профиля/WSL.

Если сервисы зарегистрированы, но не стартовали после перезагрузки, сначала проверьте, что дистрибутив не только был запущен, но и остаётся в состоянии `Running` (`wsl -l -v`), затем `systemctl --user --failed`, `journalctl --user -b` и `docker info`. Чтобы снять регистрацию отдельного компонента, вызовите его `unregister-service <тот-же-каталог>`; это не останавливает уже работающий стек. Для всей WSL-инфраструктуры можно снять linger командой `sudo loginctl disable-linger "$USER"`, но это остановит автозапуск user services при отсутствии активного входа.

Если `register-service` отвечает, что каталог не является инициализированной независимой установкой, проверьте владельца и права: установки, созданные через `sudo`, принадлежат `root`, и под обычным пользователем файл `.mcpkit/state.json` недоступен, поэтому проверка не может его прочитать. Зарегистрируйте установку под её владельцем либо заранее верните владение (`sudo chown -R "$(id -un):$(id -gn)" <каталог>`); данные баз и кэшей MetaMCP и GLOBAL хранятся в томах Docker, поэтому смена владельца каталога проекта их не затрагивает.

Важно: это автозапуск только внутри WSL. Windows LOCAL на Host и LOCAL-серверы в Windows VM запускаются механизмами Windows на соответствующих машинах; настройка WSL не запускает Windows VM и её локальные процессы.

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
# Явно выберите каталог установленного Windows LOCAL.
.\windows\connect-local.ps1 "$env:USERPROFILE\mcp-kit\local"
.\windows\connect-global.ps1 "$env:USERPROFILE\mcp-kit\global"
```

Используйте `connect-local.ps1` с каталогом, созданным текущим `install-local-servers.ps1`. Выберите MetaMCP, из приложения которого сетевой адрес Windows gateway действительно доступен. Регистратор создаёт записи, но не настраивает LAN-маршруты, TLS, VPN или брандмауэр. Для отдельной схемы Windows LOCAL → MetaMCP в WSL 2 см. [пошаговое руководство](windows-local-to-wsl-metamcp.md): оно применимо только после проверки маршрута и не настраивает WSL-сеть. Команды `run-local-servers.ps1 register-service`/`unregister-service` управляют только автозапуском gateway через Task Scheduler текущего пользователя; они не запускают MetaMCP.

Регистратор поддерживает frontend API MetaMCP закреплённой ревизии; совместимость с другими версиями не гарантирована. Для **обоих** наборов войдите под администратором: новые серверы, пространства имён и конечные точки создаются **общими для всех пользователей MetaMCP**. Имена серверов берутся из проекта/README, без префикса комплекта или случайного идентификатора, например `sequentialthinking`, `github-mcp-server`, `DesktopCommanderMCP`, `filesystem-mcp`, `playwright-mcp`. Для `io.draw` используется официальное имя репозитория `drawio-mcp`: MetaMCP не допускает точку в имени. Linux-замена Windows-MCP называется `universal-computer-control`. Точные соответствия приведены в `common/registration-manifest.mjs`.

При новой регистрации для **каждого** сервера создаются одноимённые пространство имён и endpoint, например `playwright-mcp` / `playwright-mcp` / `playwright-mcp`. Искусственных префиксов и тематических групп нет. Новые конечные точки требуют API-ключ MetaMCP, не ключ шлюза. Существующие записи и намеренно удалённые ранее записи регистратор не обновляет и не удаляет. При конфликте **видимых** имён он останавливается, а не захватывает запись или добавляет префикс. Например, `playwright-mcp` присутствует и в GLOBAL, и в LOCAL, но их подключения могут вести на разные машины: для двух разных экземпляров в одном MetaMCP потребуется отдельное решение конфликта либо разные MetaMCP. API не показывает приватные записи других пользователей: скрытый конфликт имени endpoint может обнаружиться уже после частичной регистрации, а одноимённые приватные серверы или пространства имён других пользователей API не позволяет обнаружить заранее. При обрыве или ошибке проверяйте журнал, не повторяйте создание вслепую.

Создаваемые конечные точки требуют авторизацию: любой действующий личный или общий API-ключ MetaMCP может использовать общую конечную точку. Каждый пользователь MetaMCP также может добавить общие серверы в собственное пространство имён и создать другую конечную точку; в закреплённой версии точка без API-ключа и OAuth доступна анонимно независимо от её владельца. Общие серверы дают доступ к своим инструментам и настроенным данным и интеграционным полномочиям, даже если секреты скрыты в интерфейсе. **LOCAL может управлять файлами, терминалом, базами и рабочим столом.** Ограничьте регистрацию, пользователей и ключи доверенными лицами и следите за настройками всех конечных точек.

### Перенос каталога Docker-проекта на Linux

После ручного переноса каталога с текущим independent GLOBAL или MetaMCP обновите сохранённый путь, чтобы команды комплекта и Compose продолжили использовать тот же экземпляр:

```sh
bash linux/relocate-kit.sh /новый/путь/к/global
# если переносился и MetaMCP:
bash linux/relocate-kit.sh /новый/путь/к/metamcp
```

После проверки меток Docker, исходных секретов в контейнерах и томов команда попросит ввести `MOVE GLOBAL` или `MOVE META`, сохранит приватную резервную копию `state.json` и обновит только путь в состоянии. Старый путь должен отсутствовать или указывать на тот же каталог; при двух разных копиях команда откажет. Не запускайте её параллельно с другими командами комплекта. Она не переносит произвольные пользовательские bind-mounts, не копирует данные, не изменяет секреты и не пересоздаёт контейнеры. До последующих операций Compose, особенно `apply`, отдельно сохраните необходимые данные записываемых слоёв контейнеров.

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

<a id="metamcp-to-metamcp"></a>
### Одностороннее подключение MetaMCP A к MetaMCP B в одной Docker-машине или WSL

Используйте отдельный `link-metamcp`, а не `link-global-metamcp`: последний подключает только к GLOBAL gateway. **Порядок каталогов важен:** первый аргумент — источник A, второй — целевой MetaMCP B. Скрипт подключает приложения общей внутренней Docker-сетью, проверяет из контейнера B выбранный MCP endpoint на A и через API MetaMCP создаёт в B удалённый MCP-сервер, одноимённые namespace и защищённый endpoint. Запись появляется **только в B**; в A обратный MCP-сервер не добавляется. Сама Docker bridge-сеть технически двунаправленная, но конфигурация MCP создаётся только в выбранном направлении.

Параметр `--endpoint` задаёт endpoint **на A**: можно указать его имя (`all`) или полный URL этого endpoint. Для полного URL скрипт проверит, что он относится к выбранному A, и заменит адрес хоста на внутренний Docker DNS alias. Например, `http://127.0.0.1:12108/metamcp/all/mcp` из другого контейнера напрямую не работает — там `127.0.0.1` указывает на сам контейнер.

```sh
# A — первый каталог; B — второй. Укажите endpoint на A.
bash linux/link-metamcp.sh "$HOME/mcp-kit/metamcp/A" "$HOME/mcp-kit/metamcp/B" --endpoint all

# Можно передать полный URL endpoint A; он будет переведён во внутренний адрес.
bash linux/link-metamcp.sh "$HOME/mcp-kit/metamcp/A" "$HOME/mcp-kit/metamcp/B" --endpoint http://127.0.0.1:12108/metamcp/all/mcp

# Отключить внутреннюю Docker-сеть этой пары; созданные MCP-записи в B не удаляются.
bash linux/link-metamcp.sh "$HOME/mcp-kit/metamcp/A" "$HOME/mcp-kit/metamcp/B" --unlink
```

```powershell
.\windows\link-metamcp.ps1 "$env:USERPROFILE\mcp-kit\metamcp\A" "$env:USERPROFILE\mcp-kit\metamcp\B" -Endpoint all
.\windows\link-metamcp.ps1 "$env:USERPROFILE\mcp-kit\metamcp\A" "$env:USERPROFILE\mcp-kit\metamcp\B" -Endpoint 'http://127.0.0.1:12108/metamcp/all/mcp'
.\windows\link-metamcp.ps1 "$env:USERPROFILE\mcp-kit\metamcp\A" "$env:USERPROFILE\mcp-kit\metamcp\B" -Unlink
```

Для регистрации нужен администратор B: email и пароль запрашиваются интерактивно, пароль не отображается и не передаётся в аргументах. Ключ endpoint A берётся из приватного `<A>/.mcpkit/client-api-key`; если файла нет, скрипт запросит его скрытым вводом (нажмите Enter только для открытого endpoint). Ключ сохраняется в конфигурации удалённого MCP-сервера в B, но не выводится в терминал или приватный журнал. API-ключ MetaMCP может давать доступ ко всем общим защищённым endpoints A, а не только к выбранному; подключайте только доверенный B и не передавайте его секреты недоверенным администраторам.

В B скрипт создаёт общие server, namespace и endpoint с именем `mcpkit-meta-<A-id>-<endpoint>`. Endpoint в B защищён API-ключом; при наличии `<B>/.mcpkit/client-api-key` скрипт укажет путь к нему, иначе API-ключ нужно создать в интерфейсе B. Общие записи доступны пользователям B с допустимым API-ключом; выдавайте его только доверенным клиентам. Из хоста endpoint B будет доступен по адресу `http://127.0.0.1:<порт-B>/metamcp/<имя>/mcp`, из другого контейнера в peer-сети — `http://mcpkit-meta-<B-id>:12008/metamcp/<имя>/mcp`.

Поддерживаются только независимые установки комплекта с корректным `<каталог>/.mcpkit/state.json` и именами проектов `mcpkit-meta-…`; оба app-контейнера должны быть запущены. Скрипт проверяет локальный Docker context, kit-метки контейнеров, частные default-сети и существующих участников. Он создаёт отдельную internal bridge-сеть только для двух приложений — не PostgreSQL, не сети `_default` другого проекта и не GLOBAL backend. Неожиданные владельцы/контейнеры/сети вызывают отказ; чужие ресурсы скрипт не перенастраивает. Один MetaMCP может быть связан с несколькими peers; каждой паре соответствует отдельная сеть и каждый запуск создаёт MCP-записи только в указанном втором экземпляре.

Обе установки сохраняют сеть в приватном `.mcpkit` и Compose-overlay; обычный `run-metamcp.sh start/apply` (или Windows `run-metamcp.ps1`) восстановит её при пересоздании app. Если сеть была удалена или заменена, повторите `link-metamcp` для этой пары: скрипт восстановит сеть только после проверки её имени, меток и состава. `--unlink` удаляет только сеть и сетевые метаданные, но оставляет server/namespace/endpoint в B; удалите эти записи в интерфейсе B, если они больше не нужны. Перед удалением связанного MetaMCP отсоедините пару. Не запускайте link/unlink одновременно с Compose-командами этих проектов.

Связь использует внутренний HTTP без TLS. Сеть не публикует дополнительные host-порты, но не защищает от администратора Docker/хоста и не шифрует MCP-трафик. Скрипт не меняет API-ключи/endpoint A, аутентификация A проверяется тестовым MCP initialize-запросом из контейнера B. Для другого endpoint укажите его явно через `--endpoint`.

Регистрация идемпотентна по source/target/endpoint и журналируется в приватном `<B>/.mcpkit/metamcp-peer-registrations/`. При конфликте имён существующие записи не принимаются и не перезаписываются. Если ответ API потерян после создания записи, журнал помечает неизвестный результат; проверьте его и интерфейс MetaMCP B вручную, прежде чем повторять команду. Изменённые после создания записи не обновляются скриптом автоматически.

## Резервное копирование и удаление

Сохраняйте согласованные резервные копии PostgreSQL и остальных БД вне Docker и вне машины, каталоги `.mcpkit`/LOCAL, секреты, пользовательские проекты и соответствующие тома. Автоматическое копирование данных между экземплярами не предусмотрено. Инструкции по удалению с сохранением или явным удалением данных: [docs/uninstall.md](uninstall.md).
