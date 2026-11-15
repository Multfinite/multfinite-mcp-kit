# Windows LOCAL-шлюз для MetaMCP в WSL 2

Пошаговый пример конфигурации, в которой **нативные LOCAL-серверы Windows** (`windows/install-local.ps1`), работающие за шлюзом на Windows-хосте, подключаются к **MetaMCP, установленному в WSL 2** с нативным Docker Engine. Сетевая схема — внутренний коммутатор Hyper-V `NATSwitch 192.168.100.0/24` из [настройки Hyper-V и WSL](wsl-hyperv-network.md): Windows-хост — `192.168.100.1`, WSL — статический `192.168.100.10`. Все адреса и порт `13001` ниже — примеры из этой схемы; подставляйте свои.

Регистрация записей выполняется штатным регистратором ([подключение набора к выбранному MetaMCP](independent-installation.md#4-подключение-набора-к-выбранному-metamcp)); этот документ описывает только сетевую подготовку, которую регистратор сам не делает: он не настраивает LAN-маршруты, TLS, VPN или брандмауэр.

## Схема и принцип

```
MCP-клиент → MetaMCP (Docker в WSL 2, UI на 127.0.0.1:<порт>)
                └─ записи серверов: http://192.168.100.1:13001/servers/<id>/mcp
                     (заголовок X-API-Key = ключ шлюза)
                     └→ Windows-шлюз 0.0.0.0:13001
                          └→ mcp-proxy на свободном loopback-порту → stdio-сервер
```

Ключевое правило: **«Gateway base URL as seen FROM MetaMCP»** — адрес, доступный из app-контейнера MetaMCP, а не из терминала, где запускается регистратор. Отсюда следствия:

- `127.0.0.1` и `localhost` в записях не работают никогда. В создаваемых комплектом MetaMCP-проектах автоподмена `localhost` на `host.docker.internal` выключена (`TRANSFORM_LOCALHOST_TO_DOCKER_INTERNAL: "false"`); адрес из записи используется буквально.
- При нативном Docker Engine внутри WSL 2 `host.docker.internal` (`extra_hosts: host-gateway` из `common/metamcp-linux.yml`) указывает на **сам WSL VM**, а не на Windows. Шлюз по умолчанию слушает Windows-loopback `127.0.0.1:13001`, который из WSL недостижим ни в NAT, ни в bridged. Типичный симптом — `ECONNREFUSED` у всех серверов во всех экземплярах MetaMCP.

Варианты решения:

1. **Этот гайд** — открыть шлюз на реальном адресе хоста и ограничить доступ брандмауэром адресом WSL. WSL, Docker и существующие экземпляры MetaMCP не трогаются.
2. Docker Desktop с WSL-интеграцией: `host.docker.internal` из контейнеров указывает на Windows, включая loopback; шлюз можно вернуть на `127.0.0.1`, брандмауэр не нужен. Цена — существующие Docker-проекты и тома (экземпляры MetaMCP, GLOBAL) не переносятся автоматически.

## 1. Открыть шлюз на адресе хоста (Windows)

В `%USERPROFILE%\mcp-local\config\local-settings.json` (поля описаны в [справочнике](configuration.md#windows-local-настройки-и-секреты)):

```json
"listenHost": "0.0.0.0",
"allowInsecureLan": true
```

Шлюз отказывается слушать нелокальный адрес по HTTP, если явно не задано `allowInsecureLan` или TLS. `allowInsecureLan` — осознанное подтверждение, что HTTP без шифрования принимается: в этой схеме трафик ходит только по внутреннему коммутатору хоста. Если есть сертификат, доверенный на обеих сторонах, вместо этого задайте `"tlsCertFile"` и `"tlsKeyFile"` — URL записей тогда `https://<имя>:13001`, а `allowInsecureLan` не нужен.

Перезапуск и проверки:

```powershell
.\windows\run-local.ps1 gateway-restart
.\windows\run-local.ps1 gateway-status          # все серверы ready
Get-NetTCPConnection -LocalPort 13001 -State Listen | Select-Object LocalAddress, OwningProcess
# ожидание: LocalAddress 0.0.0.0
```

Прямой адрес `http://127.0.0.1:13001/...` после этого продолжает работать.

## 2. Брандмауэр: доступ только для WSL

Адрес WSL (в WSL): `ip -4 addr show` → интерфейс `eth0`; в схеме `NATSwitch` он статический (`192.168.100.10`).

```powershell
New-NetFirewallRule -DisplayName 'mcpkit gateway (WSL only)' -Direction Inbound `
  -Protocol TCP -LocalPort 13001 -RemoteAddress '192.168.100.10/32' -Action Allow
```

Проверка: `Get-NetFirewallRule -DisplayName 'mcpkit gateway (WSL only)' | Get-NetFirewallAddressFilter`. Без этого правила соединения из WSL блокируются по умолчанию. Правило обязано оставаться узким (`/32`): за шлюзом файлы, терминал и рабочий стол. При изменении подсети WSL правило обновляется (`Set-NetFirewallRule … -RemoteAddress '<новый>/32'`). Скрипты комплекта брандмауэр не изменяют.

## 3. Проверка шлюза локально (Windows)

Полный MCP-хендшейк curl'ом. В PowerShell 5.1 обратная косая **не** экранирует кавычки: тело, переданное как `-d "{\"jsonrpc\"...}"`, искажается, и шлюз-прокси отвечает `400 Bad Request: No valid session ID provided` (сломанный JSON не распознан как `initialize`). Передавайте тело файлом:

```powershell
$key = (Get-Content "$env:USERPROFILE\mcp-local\config\private\secrets.json" | ConvertFrom-Json).gatewayApiKey

@'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}
'@ | Set-Content -Encoding ascii "$env:TEMP\mcp-init.json"

curl.exe -s -i -X POST "http://127.0.0.1:13001/servers/filesystem/mcp" `
  -H "X-API-Key: $key" -H "Content-Type: application/json" `
  -H "Accept: application/json, text/event-stream" `
  -d "@$env:TEMP\mcp-init.json"
```

Успех: `HTTP/1.1 200 OK`, заголовок `mcp-session-id: …`, JSON-RPC `result` с `serverInfo` (например, `filesystem-mcp`). Ключ — именно `gatewayApiKey` из `secrets.json`, а не API-ключ MetaMCP: первый проверяет шлюз, второй — само MetaMCP.

## 4. Проверка маршрута из WSL и из контейнера MetaMCP

```sh
ip route | grep default     # в схеме NATSwitch: default via 192.168.100.1
# быстрый тест: 401 означает, что пакет дошёл до шлюза и отвергнут только из-за отсутствия ключа
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://192.168.100.1:13001/servers/filesystem/mcp
```

Полный хендшейк из app-контейнера MetaMCP (имя — из `docker ps --filter label=com.multfinite.mcpkit.instance`):

```sh
SEC=$(ls /mnt/*/Users/*/mcp-local/config/private/secrets.json 2>/dev/null | head -1)
KEY=$(grep -oP '"gatewayApiKey"\s*:\s*"\K[a-f0-9]{64}' "$SEC")
docker exec mcpkit-meta-<id>-app-1 node -e "fetch('http://192.168.100.1:13001/servers/filesystem/mcp',{method:'POST',headers:{'X-API-Key':process.argv[1],'content-type':'application/json',accept:'application/json, text/event-stream'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2025-03-26',capabilities:{},clientInfo:{name:'probe',version:'0'}}})}).then(async r=>console.log('HTTP',r.status,(await r.text()).slice(0,120))).catch(e=>console.log('NET FAIL:',e.cause?.code||e.message))" "$KEY"
```

Успех: `HTTP 200` и начало JSON-RPC `result`. Это та же цепочка, по которой MetaMCP обращается к записям.

## 5. Регистрация и правка записей MetaMCP

Регистратор существующие записи **не перезаписывает**, а при конфликте видимых имён останавливается ([подробнее](independent-installation.md#4-подключение-набора-к-выбранному-metamcp)). Два пути:

- **Правка в UI**: у каждого LOCAL-сервера base-URL заменить на `http://192.168.100.1:13001` — полный адрес подключения `http://192.168.100.1:13001/servers/<id>/mcp`. Заголовок `X-API-Key` уже содержит ключ шлюза — не менять.
- **Перерегистрация**: удалить LOCAL-записи в UI, затем на Windows выполнить `.\windows\connect-local.ps1`: MetaMCP origin — адрес UI, доступный с Windows (по умолчанию `http://localhost:<порт>`), gateway URL — `http://192.168.100.1:13001`; на предупреждение о незащищённом HTTP ввести `TRUSTED TUNNEL`.

`<id>` в пути — идентификатор сервера шлюза из `windows/manifest.json` (`filesystem`, `desktop-commander`, …), не имя записи MetaMCP. При нескольких экземплярах MetaMCP LOCAL регистрируется только в тот, для которого выполнялся `connect-local`; каждому экземпляру — своя регистрация. Ключ шлюза один на все серверы и даёт прямой доступ ко всем им в обход авторизации MetaMCP.

## 6. GLOBAL

Серверы GLOBAL работают за контейнером `mcpkit-global-<id>-gateway-1`, записи ссылаются на внутреннее Docker-имя `http://mcpkit-global-<id>-gateway:13001/servers/<id>/mcp`. Оно резолвится только при подключённой общей Docker-сети:

```sh
bash linux/link-global-metamcp.sh "$HOME/mcp-kit/global" "<каталог выбранного MetaMCP>"
```

Если офлайн стоят и GLOBAL-серверы — проверьте эту линковку; диагностика шлюза GLOBAL аналогична (зонд из app-контейнера на его внутреннее имя).

## 7. Диагностика по кодам ответов

Проверять по цепочке: локальный хендшейк ([§3](#3-проверка-шлюза-локально-windows)) → маршрут из WSL ([§4](#4-проверка-маршрута-из-wsl-и-из-контейнера-metamcp)) → записи.

| Ответ | Смысл | Где чинить |
| --- | --- | --- |
| connection refused / timeout (curl `000`) | нет маршрута или брандмауэр | §1–2, §4; `Get-NetTCPConnection` должен показывать `0.0.0.0` |
| `401` | нет/неверен `X-API-Key` | `gatewayApiKey` из `secrets.json`, не API-ключ MetaMCP |
| `404` | несуществующий `<id>` в пути | id из `windows/manifest.json`, не имя записи MetaMCP |
| `503 server_not_ready` (+ статус) | сервер стартует/ошибка/waiting | `gateway-status`, `.\windows\run-local.ps1 logs <id>` |
| `502 upstream_unavailable` | сервер завершился после готовности | лог `<id>.log`, повторный запуск |
| `400 No valid session ID provided` | тело не распознано как JSON-RPC `initialize` (обычно испорчено экранированием PowerShell) | тело файлом, §3 |
| `Session not found` | нет/чужой `Mcp-Session-Id` | заголовок из ответа `initialize`; в PS 5.1 ключи `$r.Headers` регистрозависимы — перебирать через `GetEnumerator()` |
| `NET FAIL: ECONNREFUSED` на `host.docker.internal` | нативный Docker в WSL: имя указывает на WSL VM, шлюз — на Windows-loopback | этот гайд, вариант 1 или 2 из «Схемы» |
| `NET FAIL: ENOTFOUND host.docker.internal` | у контейнера нет `extra_hosts` (старый экземпляр) | использовать IP хоста вместо имени |

## 8. Безопасность и ограничения

- HTTP без TLS не шифрует ключ шлюза и данные; сегмент `192.168.100.0/24` — внутренний коммутатор хоста и не выходит в физическую LAN, но правило брандмауэра держать узким (`/32`) и обновлять при смене схемы.
- Один `gatewayApiKey` даёт прямой доступ ко **всем** LOCAL-серверам (файлы, терминалы, базы, рабочий стол) в обход авторизации MetaMCP — ограничивайте круг лиц с доступом к хосту и записям.
- Служебные маршруты `/_mcpkit/status` и `/_mcpkit/stop` защищены отдельным `controlKey` и предназначены для управляющих скриптов комплекта, а не для клиентов.
- Режим WSL `bridged`/подключение к внутреннему коммутатору устарел и поддерживается не во всех версиях WSL — см. предупреждение в [настройке Hyper-V и WSL](wsl-hyperv-network.md). Альтернатива — Docker Desktop (вариант 2 в начале) или `networkingMode=mirrored` на Windows 11 22H2+; последний меняет сетевую модель всего WSL и здесь не описан.
- Проверки этого гайда проводились на одной машине; при других версиях Windows, WSL и Docker поведение может отличаться.

## 9. Откат

1. `local-settings.json` → `"listenHost": "127.0.0.1"`, `"allowInsecureLan": false` → `.\windows\run-local.ps1 gateway-restart`.
2. Удалить правило: `Remove-NetFirewallRule -DisplayName 'mcpkit gateway (WSL only)'`.
3. Записи в MetaMCP — удалить или вернуть прежний base; подключения клиентов могут потребовать переподключения.
