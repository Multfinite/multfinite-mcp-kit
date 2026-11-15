# Три MetaMCP в одной WSL: текущие установки и автозапуск

Эти три экземпляра уже установлены в одной WSL. Эта инструкция относится к существующим каталогам: она не переустанавливает, не пересоздаёт и не удаляет их.

| Экземпляр | Каталог | Порт | Compose project из ранее предоставленного статуса |
| --- | --- | ---: | --- |
| GLOBAL localhost | `/metamcp/global-localhost` | `12008` | `mcpkit-meta-3091da030542105b` |
| LOCAL WSL host | `/metamcp/local-wslhost` | `12108` | `mcpkit-meta-e01fad9d88857c85` |
| LOCAL VM host | `/metamcp/local-vmhost` | `12208` | `mcpkit-meta-81ff3704a345af33` |

Имена Compose project взяты из статуса, присланного ранее; текущий `status` показывает авторитетное состояние. Команды ниже выполняйте из корня клона MCP Kit внутри этой WSL.

## Проверить, запустить и посмотреть логи

Проверка всех трёх экземпляров не меняет их состояние:

```sh
for dir in /metamcp/global-localhost /metamcp/local-wslhost /metamcp/local-vmhost; do
  echo "=== $dir ==="
  bash linux/run-metamcp.sh status "$dir"
done
```

Чтобы вручную запустить существующий экземпляр, используйте его каталог:

```sh
bash linux/run-metamcp.sh start /metamcp/global-localhost
bash linux/run-metamcp.sh start /metamcp/local-wslhost
bash linux/run-metamcp.sh start /metamcp/local-vmhost
```

Логи конкретного экземпляра можно посмотреть так:

```sh
bash linux/run-metamcp.sh logs /metamcp/global-localhost
```

Замените каталог на один из двух остальных, если нужно. Логи могут содержать приватные данные — не отправляйте их целиком. Не останавливайте контейнеры через `stop` или `docker compose stop`, если рассчитываете на автоматический перезапуск: политика `unless-stopped` оставляет вручную остановленные контейнеры остановленными до следующего явного запуска.

## Как устроен автозапуск

В Compose-шаблоне MCP Kit (`common/metamcp-compose.yml`) для `app` и `postgres` указана политика `restart: unless-stopped`. Для автоматического запуска после остановки Docker должны выполняться все условия:

1. Сама WSL-дистрибуция запущена.
2. Внутри неё работает systemd, а служба Docker включена и запущена.
3. У уже созданных контейнеров действительно установлена политика `unless-stopped`, и их не останавливали вручную.

В комплекте нет отдельных systemd-служб для этих трёх Compose-проектов: предполагается запуск контейнеров механизмом restart policy Docker. Наличие `restart: unless-stopped` в YAML-шаблоне само по себе не подтверждает политику уже существующих контейнеров. Она сохраняется в конфигурации контейнера при создании; `linux/run-metamcp.sh start` использует `--no-recreate` и не применяет изменения Compose к существующему контейнеру. При ручном запуске вспомогательный скрипт может сам запустить остановленный локальный Docker через `systemctl start`; поэтому успешный запуск вручную не означает, что Docker включён для автоматического старта WSL.

Проверка среды и фактических политик контейнеров ничего не меняет:

```sh
printf 'PID 1: '; ps -p 1 -o comm=
printf 'WSL systemd runtime: '
if [ -d /run/systemd/system ]; then echo present; else echo absent; fi
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  printf 'Docker enabled: '; systemctl is-enabled docker 2>&1 || true
  printf 'Docker active:  '; systemctl is-active docker 2>&1 || true
else
  echo 'systemctl недоступен или systemd не запущен.'
fi

if docker info --format 'Docker Engine: {{.ServerVersion}}'; then
  for project in \
    mcpkit-meta-3091da030542105b \
    mcpkit-meta-e01fad9d88857c85 \
    mcpkit-meta-81ff3704a345af33
  do
    echo "=== $project ==="
    ids="$(docker ps -aq --filter "label=com.docker.compose.project=$project")"
    if [ -z "$ids" ]; then
      echo 'Контейнеры проекта не найдены.'
      continue
    fi
    for id in $ids; do
      docker inspect --format 'name={{.Name}} state={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restart={{.HostConfig.RestartPolicy.Name}} restartCount={{.RestartCount}} error={{.State.Error}}' "$id"
    done
  done
else
  echo 'Docker недоступен: проверка политик контейнеров пропущена.'
fi
```

`Exited (137)` само по себе не доказывает нехватку памяти. Для этого отдельно проверяется `OOMKilled` и системные журналы. Если Docker включён, но не запускается сама WSL после старта Windows, служба внутри неё также не стартует: `systemd` и `systemctl enable docker` управляют запуском внутри уже запущенной дистрибуции, а не запускают WSL из Windows. Если проверка покажет, что systemd работает, но Docker выключен при старте WSL, включить Docker можно командой `sudo systemctl enable --now docker`; применяйте её только при таком результате.

## Подключить установленный GLOBAL

Если нужно подключить существующий GLOBAL Docker-проект к экземпляру MetaMCP, укажите имя этого проекта и целевой каталог:

```sh
read -r -p 'Docker-проект существующего GLOBAL: ' GLOBAL_PROJECT
bash linux/connect-global.sh --live-global "$GLOBAL_PROJECT" /metamcp/global-localhost
```

Эта операция подключает GLOBAL только к `/metamcp/global-localhost`; два LOCAL экземпляра ей не затрагиваются. Команда проверяет контейнеры и изолированную сеть, при необходимости запускает существующие контейнеры выбранного проекта и сохраняет связь при пересоздании MetaMCP. Данные и тома GLOBAL не удаляются и не пересоздаются. Для входа будут запрошены email и пароль. Передачу по незашифрованной внутренней Docker-сети подтверждайте строкой `TRUSTED TUNNEL` только если доверяете этому хосту и сети.

Для каждого сервера создаются одноимённые общие сервер, namespace и защищённый API-ключом endpoint; префикс к именам инструментов и промптов не добавляется. Для однозначной маршрутизации в namespace должен оставаться ровно один сервер. Готовность шлюза не означает готовность каждого MCP-сервера: отдельным интеграциям могут понадобиться настройки или учётные данные.

Для поиска причины автозапуска нужны вывод проверки выше и уточнение, после какого события контейнеры не стартуют: перезагрузка Windows, запуск WSL, перезапуск Docker или неожиданное завершение контейнера. Также укажите, не останавливали ли их перед этим вручную. Не присылайте `.env`, пароли, API-ключи, cookies или полные логи.
