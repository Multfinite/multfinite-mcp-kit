# Windows LOCAL: подключение шлюза к MetaMCP в WSL 2

Это руководство описывает один конкретный маршрут: нативные Windows LOCAL-серверы и шлюз на Windows-хосте, а MetaMCP запущен в контейнере нативного Docker Engine внутри WSL 2. Примеры адресов соответствуют одной конфигурации с внутренним коммутатором Hyper-V `NATSwitch`: WSL `192.168.100.10`, Windows-хост `192.168.100.1`, шлюз `13001`. **Это не стандартные адреса и не готовая настройка сети: подставляйте адреса, фактически проверенные в своей среде.**

> **Важно про WSL-сеть.** Руководство по [сети Hyper-V и WSL](wsl-hyperv-network.md) отмечает, что подключение WSL к пользовательскому `NATSwitch` через прежний режим `bridged` устарело и не гарантируется. Не рассчитывайте, что WSL получит адрес `.10` или подключится к этому коммутатору. Этот документ применим только если маршрут от контейнера MetaMCP до адреса Windows-хоста уже подтверждён. Он не создаёт NATSwitch и не меняет конфигурацию WSL.

## 1. Маршрут и адреса

```text
MCP-клиент
  └─ MetaMCP app (Docker Engine внутри WSL 2)
       └─ URL сервера: http://192.168.100.1:13001/servers/<server-id>/mcp
            └─ заголовок X-API-Key: ключ Windows-шлюза
                 └─ Windows-хост: шлюз слушает 192.168.100.1:13001 (пример)
                      └─ локальный mcp-proxy → stdio-сервер
```

| Узел | Адрес в примере | Что проверить |
|---|---|---|
| Windows-хост на `NATSwitch` | `192.168.100.1` | Этот адрес должен принадлежать интерфейсу Windows, доступному из WSL. |
| WSL | `192.168.100.10` | Найдите фактический IPv4-адрес в работающем дистрибутиве; имя интерфейса может отличаться от `eth0`. |
| Windows LOCAL gateway | `192.168.100.1:13001` | В примере шлюз привязан только к адресу интерфейса `NATSwitch`; адрес должен действительно принадлежать Windows. Если вместо этого слушать `0.0.0.0`, шлюз откроется на всех IPv4-интерфейсах и потребует особенно строгого брандмауэра. |

MetaMCP должен использовать адрес, доступный **из его app-контейнера**, а не только из Windows или WSL-терминала. В контейнере `127.0.0.1` означает сам контейнер; в используемой конфигурации `TRANSFORM_LOCALHOST_TO_DOCKER_INTERNAL` выключен, поэтому не рассчитывайте на автоматическое преобразование `localhost`. В нативном Docker Engine внутри WSL `host.docker.internal`, если это имя настроено и разрешается, обычно указывает на Docker-хост/WSL и не гарантирует адрес Windows. В этой схеме используйте проверенный адрес Windows-хоста, например `192.168.100.1`; для Docker Desktop или другой WSL-сети маршрут может быть иным.

## 2. Безопасность и условия

Windows-шлюз по умолчанию слушает только `127.0.0.1:13001`. Чтобы запросы из WSL пришли на Windows, шлюз нужно привязать к доступному интерфейсу. При этом:

- `allowInsecureLan: true` — только явное разрешение на незашифрованный HTTP вне loopback. Оно **не шифрует трафик**, не настраивает VPN и не ограничивает источники подключений.
- В HTTP ключ шлюза передаётся открытым текстом. Внутренний Hyper-V-коммутатор сам по себе не обеспечивает шифрование.
- Ключ `gatewayApiKey` даёт доступ ко всем серверам этого шлюза, в том числе к инструментам работы с файлами, базами и рабочим столом. MetaMCP хранит его в заголовках серверных записей; выдавайте доступ к MetaMCP только доверенным пользователям. Защищённые заголовком `X-Mcpkit-Control` адреса `/_mcpkit/status` и `/_mcpkit/stop` используют отдельный контрольный ключ.
- Предпочтительный вариант для недоверенной сети — TLS с сертификатом, которому доверяют и Windows, и Node.js в контейнере MetaMCP, либо отдельно настроенный шифрованный туннель. Сертификат должен соответствовать адресу, указанному в URL.

Продолжайте с HTTP только если проверили изоляцию и маршрут, принимаете передачу ключа без шифрования и ограничите входящий доступ точным адресом-источником. Не открывайте порт в физическую LAN или интернет.

## 3. Настройка Windows-шлюза

Ниже путь для стандартной native-only установки `%USERPROFILE%\mcp-local`. Если выбран независимый LOCAL, замените путь на `%USERPROFILE%\mcp-kit\local` или фактический каталог; используйте одну и ту же установку во всех командах. В PowerShell из корня репозитория задайте каталог (пример по умолчанию — `mcp-local`):

```powershell
$localDir = if ($env:MCP_LOCAL_DIR) { $env:MCP_LOCAL_DIR } else { Join-Path $env:USERPROFILE 'mcp-local' }
```

`run-local.ps1` использует `MCP_LOCAL_DIR` или параметр `-Directory`; если у вас задан только `MCPKIT_LOCAL_DIR`, укажите каталог явно в `$localDir`.

Сначала остановите текущий шлюз из корня репозитория, чтобы он не оставался доступным на прежнем listener во время настройки брандмауэра:

```powershell
.\windows\run-local.ps1 gateway-stop -Directory $localDir
```

В `config\local-settings.json` **измените существующие поля**, не заменяя весь файл и не удаляя остальные настройки. Привязывайте шлюз к конкретному IPv4-адресу Windows, который доступен из WSL; в примере это `.1`:

```json
"listenHost": "192.168.100.1",
"allowInsecureLan": true
```

Подставьте фактический адрес интерфейса, не используйте `.1`, если он не назначен Windows. `0.0.0.0` — запасной вариант только если конкретный адрес привязать нельзя: он слушает на всех IPv4-интерфейсах, поэтому не выбирайте его без соответствующих ограничений брандмауэра. Оставьте `port` равным `13001` (или используйте выбранный порт и замените его во всех следующих примерах). При TLS укажите оба существующих абсолютных пути `tlsCertFile` и `tlsKeyFile`, а `allowInsecureLan` оставьте `false`. URL ниже показаны для HTTP с явным opt-in; при TLS замените схему на `https` и используйте hostname/IP, включённый в сертификат. Сертификат должен проверяться и Windows, и Node.js в app-контейнере — не отключайте проверку TLS.

**Не запускайте шлюз с новым listener до создания узкого правила брандмауэра в §4.** Там же будут команды для безопасного перезапуска и проверки.

## 4. Брандмауэр Windows: разрешить только проверенный источник

Сначала в WSL проверьте адреса и маршрут:

```sh
ip -4 addr
ip -4 route
```

Если в вашей **проверенной** схеме локальный адрес Windows — `192.168.100.1`, а запросы приходят с WSL `192.168.100.10`, в PowerShell **от имени администратора** создайте узкое входящее правило. Если значения отличаются, замените оба адреса на фактические проверенные адреса:

```powershell
if (Get-NetFirewallRule -DisplayName 'mcpkit gateway (WSL only)' -ErrorAction SilentlyContinue) {
  throw 'Firewall rule already exists; inspect its filters before changing it.'
}
New-NetFirewallRule -DisplayName 'mcpkit gateway (WSL only)' `
  -Direction Inbound -Protocol TCP -LocalAddress '192.168.100.1' -LocalPort 13001 `
  -RemoteAddress '192.168.100.10/32' -Action Allow
```

Посмотрите фильтры созданного правила:

```powershell
$rule = Get-NetFirewallRule -DisplayName 'mcpkit gateway (WSL only)'
$rule | Format-List DisplayName, Enabled, Profile, Direction, Action
$rule | Get-NetFirewallAddressFilter
$rule | Get-NetFirewallPortFilter
```

Только после создания этого правила запустите шлюз:

```powershell
.\windows\run-local.ps1 gateway-restart -Directory $localDir
.\windows\run-local.ps1 gateway-status -Directory $localDir
Get-NetTCPConnection -LocalPort 13001 -State Listen |
  Select-Object LocalAddress, LocalPort, OwningProcess
```

При настройке конкретного адреса ожидайте его в `LocalAddress`; только при `listenHost: "0.0.0.0"` ожидается wildcard `0.0.0.0`. В статусе проверьте состояние именно `filesystem`: остальные серверы могут ждать своих ключей или локальной настройки, это не обязательно означает, что шлюз недоступен.

**Не считайте адрес WSL автоматически адресом-источником контейнерного трафика.** Docker может выполнять NAT; Windows может видеть другой источник, чем адрес `eth0` в WSL. Если проверка из app-контейнера не проходит, сначала выясните фактический адрес-источник по сетевым журналам/наблюдению соединения. Не расширяйте правило до всей подсети наугад. Также убедитесь, что нет другого более широкого разрешающего правила для этого порта: добавление узкого правила не отменяет уже существующие правила.

Если меняется адрес-источник, обновите **только это правило**, предварительно сверив его имя и фильтры, либо удалите его и создайте заново с проверенным адресом. Чтобы откатить правило в конце процедуры, используйте `Remove-NetFirewallRule -DisplayName 'mcpkit gateway (WSL only)'`.

## 5. Проверка MCP на Windows

Этот запрос отправляет корректный JSON-RPC `initialize` на маршрут сервера `filesystem`. Блок использует `$localDir`, заданный в §3, и передаёт ключ напрямую из PowerShell — **не** через аргументы `curl.exe` или другого процесса:

```powershell
$key = (Get-Content -LiteralPath (Join-Path $localDir 'config\private\secrets.json') -Raw |
  ConvertFrom-Json).gatewayApiKey
if ($key -notmatch '^[a-f0-9]{64}$') { throw 'Invalid gatewayApiKey in secrets.json.' }
$body = @{
  jsonrpc = '2.0'
  id = 1
  method = 'initialize'
  params = @{
    protocolVersion = '2024-11-05'
    capabilities = @{}
    clientInfo = @{ name = 'probe'; version = '0' }
  }
} | ConvertTo-Json -Depth 5 -Compress

try {
  $response = Invoke-WebRequest -UseBasicParsing `
    -Uri 'http://192.168.100.1:13001/servers/filesystem/mcp' `
    -Method Post `
    -Headers @{ 'X-API-Key' = $key; Accept = 'application/json, text/event-stream' } `
    -ContentType 'application/json' -Body $body -TimeoutSec 10
  Write-Output "HTTP $($response.StatusCode)"
  Write-Output "mcp-session-id: $($response.Headers['mcp-session-id'])"
  Write-Output $response.Content
} finally {
  Remove-Variable key -ErrorAction SilentlyContinue
}
```

Успешный ответ — `HTTP 200`, заголовок `mcp-session-id` и MCP `initialize`-результат с `serverInfo`. Формат тела может быть JSON или SSE-строкой `data:`. Используйте именно `gatewayApiKey` из `secrets.json`, не API-ключ MetaMCP. Не публикуйте значение ключа или вывод команды.

## 6. Проверка сети из WSL и app-контейнера

Сначала проверьте маршрут с WSL-хоста. Ответ `401` здесь ожидаем: запрос дошёл до шлюза, но в нём нет ключа.

```sh
ip route | grep '^default'
curl -sS --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}\n' \
  -X POST 'http://192.168.100.1:13001/servers/filesystem/mcp' || true
```

Затем проверьте именно app-контейнер нужного MetaMCP. Укажите его каталог, если он отличается от примера:

```sh
META_DIR="$HOME/mcp-kit/metamcp/global"
INSTANCE="$(node -e 'const fs=require("node:fs");const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(!/^[a-f0-9]{16}$/.test(s.id||""))process.exit(1);process.stdout.write(s.id)' "$META_DIR/.mcpkit/state.json")"
APP_IDS="$(docker ps \
  --filter "label=com.multfinite.mcpkit.instance=$INSTANCE" \
  --filter 'label=com.docker.compose.service=app' \
  --format '{{.ID}}')"
[ -n "$APP_IDS" ] || { echo 'Running MetaMCP app container not found.' >&2; exit 1; }
[ "$(printf '%s\n' "$APP_IDS" | wc -l)" -eq 1 ] || { echo 'Expected exactly one matching app container.' >&2; exit 1; }
APP_ID="$APP_IDS"
```

Оставайтесь в том же WSL-терминале, где задан `APP_ID`. Укажите фактический каталог Windows LOCAL. Пример ниже — стандартный native-only `%USERPROFILE%\mcp-local` при профиле Windows на диске `C:`; замените `your-windows-user` и путь, если используется независимая установка, другой профиль или корень automount. Ключ считывается в переменную Bash и передаётся контейнеру через stdin — **не** как аргумент `docker exec`:

```sh
(
  set -euo pipefail
  WIN_USER='your-windows-user'
  SEC="/mnt/c/Users/$WIN_USER/mcp-local/config/private/secrets.json"
  test -r "$SEC" || { echo "Cannot read $SEC; set the actual Windows LOCAL secrets path." >&2; exit 1; }
  KEY="$(node -e 'const fs=require("node:fs");const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(!/^[a-f0-9]{64}$/.test(s.gatewayApiKey||""))process.exit(1);process.stdout.write(s.gatewayApiKey)' "$SEC")"
  trap 'unset KEY' EXIT
  printf '%s' "$KEY" | docker exec -i "$APP_ID" node -e '
let key = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => { key += chunk; });
process.stdin.on("end", async () => {
  try {
    const response = await fetch("http://192.168.100.1:13001/servers/filesystem/mcp", {
      method: "POST",
      headers: {
        "X-API-Key": key,
        "content-type": "application/json",
        accept: "application/json, text/event-stream"
      },
      body: JSON.stringify({
        jsonrpc: "2.0", id: 1, method: "initialize",
        params: { protocolVersion: "2024-11-05", capabilities: {},
          clientInfo: { name: "probe", version: "0" } }
      }),
      signal: AbortSignal.timeout(10000)
    });
    const body = await response.text();
    console.log("HTTP", response.status,
      "mcp-session-id:", response.headers.has("mcp-session-id") ? "present" : "missing");
    console.log(body.slice(0, 300));
    if (!response.ok) process.exitCode = 1;
  } catch (error) {
    console.error("NET FAIL:", error.cause?.code || error.message);
    process.exitCode = 1;
  }
});
'
)
```

Успех — `HTTP 200`, session-id и результат `initialize` (`serverInfo`); для SSE результат будет внутри `data:`. Если адрес или порт отличаются, замените `192.168.100.1:13001` в обоих запросах на фактические значения. Эта проверка подтверждает маршрут из контейнера, а не только из WSL-хоста.

## 7. Регистрация серверов Windows LOCAL в MetaMCP

После успешной проверки маршрута запустите регистратор из корня репозитория в Windows PowerShell:

```powershell
.\windows\connect-local.ps1 "$localDir"
```

Введите origin MetaMCP, **доступный с Windows** (например, `http://localhost:<порт>` только если этот адрес действительно открывается на Windows), и gateway base URL, **доступный из app-контейнера**, например:

```text
http://192.168.100.1:13001
```

Передавайте именно base URL, без `/servers/...`. Регистратор создаёт URL каждого сервера самостоятельно. Для встроенного сервера `filesystem` маршрут будет `/servers/filesystem/mcp`; имя записи в MetaMCP может быть `filesystem-mcp` — это разные идентификаторы.

Если регистратор предупреждает о non-loopback HTTP и просит ввести `TRUSTED TUNNEL`, вводите эту фразу только после проверки сети и принятия риска незашифрованного трафика. Она подтверждает решение пользователя, но **не создаёт туннель и не включает TLS**.

Для регистрации потребуется учётная запись администратора MetaMCP. Серверы, пространства имён и конечные точки создаются общими: пользователи MetaMCP смогут использовать опубликованные серверы и настроенные на них данные/учётные данные. LOCAL может предоставлять доступ к файлам, терминалу, базам и рабочему столу; ограничьте пользователей и доверяйте всем, кому доступен этот MetaMCP.

Регистратор существующие записи не перезаписывает и не удаляет; при конфликте видимых имён он откажется их захватывать. API MetaMCP может не показывать приватные записи других пользователей, поэтому скрытый конфликт иногда обнаруживается уже после частичной регистрации. При ошибке или обрыве сначала изучите результат и записи, не повторяйте создание вслепую. Если сервер уже зарегистрирован с неправильным URL, безопаснее сначала проверить и исправить его запись в интерфейсе MetaMCP, сохранив `X-API-Key`. Удаляйте и создавайте запись заново только если точно знаете, что она принадлежит этой LOCAL-установке, и сохранили нужные настройки. Для каждого экземпляра MetaMCP регистрация выполняется отдельно.

## 8. GLOBAL — другой маршрут

Этот документ относится к Windows LOCAL. Если MetaMCP и независимый GLOBAL находятся в одном Docker Engine внутри WSL, GLOBAL-шлюз не нужно открывать на интерфейсе Windows: подключите выбранный MetaMCP к приватной сети GLOBAL и затем выполните его регистратор:

```sh
bash linux/link-global-metamcp.sh \
  "$HOME/mcp-kit/global" \
  "$HOME/mcp-kit/metamcp/global"
bash linux/connect-global.sh "$HOME/mcp-kit/global"
```

Команда `link-global-metamcp.sh` выводит URL внутреннего gateway. Такой DNS-адрес доступен только подключённому Docker-контейнеру. Это отдельная связь; она не изменяет Windows listener и не заменяет `connect-local.ps1`.

## 9. Диагностика

| Симптом | Вероятная причина и проверка |
|---|---|
| `curl` показывает `000`, timeout или connection refused | Нет маршрута, listener не слушает адрес Windows или брандмауэр блокирует соединение. Проверьте `Get-NetTCPConnection`, IP Windows/WSL, firewall-правила и повторите тест из app-контейнера. |
| `401` | Маршрут работает, но отсутствует/неверен `X-API-Key`. Нужен `gatewayApiKey` именно этой Windows-установки, не API-ключ MetaMCP. |
| `404` | Путь или внутренний ID сервера неверен. Для файлового сервера шлюза ID — `filesystem`, даже если запись в MetaMCP называется `filesystem-mcp`. |
| `503 server_not_ready` | Сервер шлюза ещё запускается, ждёт конфигурации или находится в ошибке. Проверьте `gateway-status` и `.\windows\run-local.ps1 logs filesystem -Directory $localDir`. |
| `502 upstream_unavailable` | Upstream-процесс остановился между проверками готовности и запросом. Проверьте `.\windows\run-local.ps1 logs filesystem -Directory $localDir` и статус сервера. |
| `400 No valid session ID provided` при `initialize` | Тело запроса — не корректный JSON-RPC `initialize`. Формируйте его через `ConvertTo-Json`, как в §5. |
| `Session not found` на следующем MCP-запросе | Используйте `mcp-session-id` именно из ответа `initialize`. В PowerShell 5.1 перечисляйте `$response.Headers.GetEnumerator()` и сравнивайте имя заголовка без учёта регистра. |
| `NET FAIL: ENOTFOUND host.docker.internal` | Имя не указывает на Windows-хост в этой конфигурации нативного Docker в WSL. Используйте только проверенный адрес, доступный из app-контейнера. |
| TLS `certificate`/`hostname` error | Имя или IP в URL должен входить в SAN сертификата, а его цепочка должна быть доверенной и в Windows, и в Node.js app-контейнера. Не отключайте проверку сертификата. |

## 10. Откат

Чтобы вернуть доступ только с Windows-хоста, восстановите исходные значения в `local-settings.json`:

```json
"listenHost": "127.0.0.1",
"allowInsecureLan": false
```

Если настраивали TLS, очистите `tlsCertFile` и `tlsKeyFile` только если они были добавлены исключительно для этой схемы. Перезапустите шлюз и удалите только созданное правило брандмауэра:

```powershell
.\windows\run-local.ps1 gateway-restart -Directory $localDir
Remove-NetFirewallRule -DisplayName 'mcpkit gateway (WSL only)'
```

В MetaMCP проверьте URL созданных записей и удалите либо исправьте только те записи, которые точно относятся к этой Windows LOCAL-установке. Не сбрасывайте все записи MetaMCP ради отката одного шлюза.
