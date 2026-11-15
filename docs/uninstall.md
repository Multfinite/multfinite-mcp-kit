# Удаление Multfinite MCP Kit

Удаление контейнеров и удаление **данных** — разные действия. Команды ниже не удаляют Docker целиком, другие Compose-проекты или записи в MetaMCP автоматически. Сначала определите установленные на этой машине экземпляры и наборы, проверьте их каталоги и Docker context, сделайте независимые резервные копии нужных баз, томов, настроек, секретов и пользовательских файлов. Дамп внутри удаляемого тома не является независимой копией.

Текущие Docker-проекты имеют приватное `<каталог>/.mcpkit/state.json` с типом, путем, портом и именем Compose-проекта `mcpkit-meta-…` или `mcpkit-global-…`. Не копируйте в чат `.mcpkit/.env` и другие секреты. Если состояние отсутствует, повреждено или не совпадает с каталогом, автоматическое удаление откажет: отдельно проверяйте владельца каждого ресурса. Не удаляйте неизвестные файлы и не используйте `docker system prune`, `docker volume prune`, `docker rm -f $(docker ps -aq)` или подобные общие команды.

## 1. Удалить MetaMCP и GLOBAL

Сначала остановите зависимые клиенты и отключите каждую созданную связь:

- MetaMCP, подключённый к GLOBAL через `link-global-metamcp`, отсоедините командой `--unlink` / `-Unlink`, пока оба проекта запущены; примеры есть в [руководстве](independent-installation.md#два-новых-docker-проекта-на-одной-машине). Удаление GLOBAL не отключает произвольные контейнеры.
- Для связи двух MetaMCP через `link-metamcp` отсоедините каждую пару командой `--unlink` / `-Unlink` по [инструкции](independent-installation.md#metamcp-to-metamcp). Удаление MetaMCP с активной peer-связью завершится отказом.
- Удаление локальных Docker-проектов не удаляет созданные в MetaMCP серверы, пространства имён и endpoints.

Команда `remove` показывает имя проекта и требует точного подтверждения `REMOVE <имя-проекта>`. Она удаляет только принадлежащие выбранному проекту контейнеры и сеть, но **сохраняет именованные тома и каталог на диске**. Содержимое записываемого слоя контейнеров при удалении теряется; отдельно сохраните его, если помещали туда файлы. Если Docker Desktop/Engine остановлен, сначала запустите его. Удаляйте по одному выбранному экземпляру.

### Linux

```sh
# Если регистрировали автозапуск GLOBAL — снимите его.
bash linux/run-global-servers.sh unregister-service "$HOME/mcp-kit/global"
bash linux/run-global-servers.sh status "$HOME/mcp-kit/global"
bash linux/run-global-servers.sh stop   "$HOME/mcp-kit/global"
bash linux/run-global-servers.sh remove "$HOME/mcp-kit/global"

bash linux/run-metamcp.sh status "$HOME/mcp-kit/metamcp/global"
bash linux/run-metamcp.sh stop   "$HOME/mcp-kit/metamcp/global"
bash linux/run-metamcp.sh remove "$HOME/mcp-kit/metamcp/global"
```

### Windows

```powershell
# Если регистрировали автозапуск GLOBAL — снимите его.
.\windows\run-global-servers.ps1 unregister-service "$env:USERPROFILE\mcp-kit\global"
.\windows\run-global-servers.ps1 status "$env:USERPROFILE\mcp-kit\global"
.\windows\run-global-servers.ps1 stop   "$env:USERPROFILE\mcp-kit\global"
.\windows\run-global-servers.ps1 remove "$env:USERPROFILE\mcp-kit\global"

.\windows\run-metamcp.ps1 status "$env:USERPROFILE\mcp-kit\metamcp\global"
.\windows\run-metamcp.ps1 stop   "$env:USERPROFILE\mcp-kit\metamcp\global"
.\windows\run-metamcp.ps1 remove "$env:USERPROFILE\mcp-kit\metamcp\global"
```

Если нужно удалить **и данные**, после независимого резервного копирования и проверки проекта выполните `remove` с `--delete-volumes` (`-DeleteVolumes` в PowerShell). Эта операция удаляет выбранные контейнеры и сеть вместе со всеми именованными томами проекта, включая базы и данные GDrive; она требует подтверждения `DELETE <имя-проекта>`. Это необратимо, файлы каталога установки остаются. Флаг можно использовать вместо обычного `remove`; если обычное удаление уже завершено, тома можно удалить отдельным повторным вызовом, пока состояние и конфигурация проекта сохранены.

```sh
# Linux — только для выбранных проектов:
bash linux/run-global-servers.sh remove "$HOME/mcp-kit/global" --delete-volumes
bash linux/run-metamcp.sh remove "$HOME/mcp-kit/metamcp/global" --delete-volumes
```

```powershell
# Windows — только для выбранных проектов:
.\windows\run-global-servers.ps1 remove "$env:USERPROFILE\mcp-kit\global" -DeleteVolumes
.\windows\run-metamcp.ps1 remove "$env:USERPROFILE\mcp-kit\metamcp\global" -DeleteVolumes
```

Перед удалением GLOBAL отключите все подключённые к нему MetaMCP через `link-global-metamcp` с `--unlink` / `-Unlink` по [примерам](independent-installation.md#два-новых-docker-проекта-на-одной-машине). Команда `remove` откажется удалять сеть, если она используется другим контейнером. При ошибке проверки меток установите владельца и подключения ресурсов; не применяйте принудительное удаление. Docker-образы сохраняются. Удаляйте только вручную проверенные образы выбранного проекта, если уверены, что ими больше не пользуются другие контейнеры или теги.

После удаления контейнеров и, при необходимости, томов просмотрите содержимое выбранного каталога, включая пользовательские данные и `.mcpkit`. Только если каталог и секреты больше не нужны, удалите его вручную. Не удаляйте родительский каталог, если в нём есть другие установки. Удаление каталога до завершения операций Docker лишает вас состояния и конфигурации, необходимых для безопасного управления проектом.

## 2. Удалить LOCAL-серверы

LOCAL не имеет команды `remove`, удаляющей каталог или данные. Сначала отключите автозапуск, остановите gateway и проверьте выбранную установку:

### Linux

```sh
bash linux/run-local-servers.sh unregister-service "$HOME/mcp-kit/local"
bash linux/run-local-servers.sh status "$HOME/mcp-kit/local"
bash linux/run-local-servers.sh stop "$HOME/mcp-kit/local"
```

### Windows

```powershell
.\windows\run-local-servers.ps1 unregister-service "$env:USERPROFILE\mcp-kit\local"
.\windows\run-local-servers.ps1 status "$env:USERPROFILE\mcp-kit\local"
.\windows\run-local-servers.ps1 stop "$env:USERPROFILE\mcp-kit\local"
```

Если при установке выбран другой каталог, подставьте его в **каждую** команду. Проверьте `data/projects`, `data/writing`, базу DBHub, данные управления рабочим столом, настройки, журналы, секреты и резервные копии. `projectsDir`/`writingDir` могут ссылаться на файлы за пределами каталога LOCAL; они не удаляются автоматически. Удалите только выбранный каталог вручную после проверки и сохранения нужных данных. Пакеты WinGet, системные Node/Python, кэши Chromium/uv, Everything и системные библиотеки могут использовать другие программы и не удаляются автоматически.

## 3. Записи в MetaMCP и копия репозитория

Регистратор сохраняет приватный журнал под выбранным GLOBAL `<GLOBAL>/.mcpkit/registrations/` или LOCAL `<LOCAL>/config/private/registrations/`. Сверьте имена и UUID журнала с объектами в целевом MetaMCP. Остановка или удаление LOCAL/GLOBAL не удаляет эти записи. Удалите их в интерфейсе MetaMCP только после проверки владельца, изменений, связей и использования другими людьми: операции MetaMCP могут каскадно удалить связанные данные. Не удаляйте общие серверы или пространства, нужные другим пользователям.

После завершения и резервирования нужных файлов можно удалить саму копию репозитория или распакованную папку. Сначала проверьте пользовательские изменения и файлы. Копия репозитория не содержит автоматически Docker-тома, внешние проекты или данные за пределами выбранных каталогов.
