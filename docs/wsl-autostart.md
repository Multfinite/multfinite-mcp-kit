# Автозапуск WSL при входе в Windows

Это руководство поднимает выбранный дистрибутив WSL 2 при входе в Windows и удерживает его запущенным, чтобы пользовательские systemd-службы (`systemctl --user`), включая зарегистрированные командами MCP Kit `register-service`, начинали работу без ручного открытия терминала. Руководство не настраивает сеть, Docker и сами компоненты: маршруты между Windows, WSL и ВМ описаны в [руководстве по Hyper-V, WSL и ВМ](wsl-hyperv-network.md), установка и регистрация компонентов — в [руководстве по раздельной установке](independent-installation.md#автозапуск-полного-набора-в-wsl-2).

## Из чего состоит автозапуск

Нужны три независимых условия:

1. внутри дистрибутива работает systemd (`[boot] systemd=true` в `/etc/wsl.conf`);
2. пользовательский manager живёт без интерактивного входа (`sudo loginctl enable-linger "$USER"`);
3. Windows запускает дистрибутив при входе пользователя и **не даёт ему остановиться**.

Первые два настраиваются внутри Debian, третье — задачей Планировщика Windows. В актуальных версиях WSL нет отдельного параметра «запускать дистрибутив при загрузке Windows», а сам WSL 2 не поднимает дистрибутивы при старте системы. Параметр `command` в секции `[boot]` файла `/etc/wsl.conf` выполняется при старте дистрибутива, но тоже не удерживает его запущенным.

## Почему `wsl.exe -d Debian --exec /bin/true` не работает

`wsl.exe ... --exec <команда>` открывает сеанс. Когда последний процесс сеанса завершается, WSL останавливает дистрибутив: `wsl -l -v` показывает `Stopped`. Вместе с дистрибутивом останавливается пользовательский systemd manager, поэтому `enable-linger` уже нечего выполнять, и зарегистрированные units не запускаются. Проверить это можно на своей системе: команда возвращает код 0, но через несколько секунд дистрибутив остановлен.

Поэтому задача должна держать один долгоживущий процесс внутри дистрибутива. В примерах ниже это `sleep infinity`: он не требует прав root, не пишет в журналы и завершается только вместе с задачей.

> **Важное уточнение по WSL 3.x.** Даже при `Linger=yes` WSL останавливает **пользовательский manager** (`user@1000.service`), когда закрывается последний сеанс дистрибутива; сама ВМ при этом может остаться запущенной. Тогда все юниты, созданные `run-metamcp.sh register-service`, останавливаются, и их `ExecStop` вызывает `run-metamcp.sh stop` — контейнеры, которые только что поднялись, гаснут. В журнале это видно так:
>
> ```text
> systemd[1]: Stopping user@1000.service - User Manager for UID 1000...
> bash[…]: Kit service containers stopped. Credentials, files and volumes were not changed.
> ```
>
> Поэтому держатель сеанса — не необязательная деталь, а условие живучести. Готовый способ — `windows\wsl-keepalive.ps1`: он держит один сеанс, а также сам поднимает дистрибутив и перезапускает юниты кита, у которых остановился контейнер.

## Шаг 1. systemd, linger и Docker (внутри Debian)

Сохраните существующий `/etc/wsl.conf` и добавьте параметр, если его ещё нет:

```ini
[boot]
systemd=true
```

В PowerShell Windows выполните `wsl --shutdown`, снова откройте дистрибутив и проверьте:

```sh
ps -p 1 -o comm=            # ожидается systemd
sudo loginctl enable-linger "$USER"
loginctl show-user "$USER" -p Linger   # ожидается Linger=yes
```

Если компоненты используют Docker Engine внутри Debian, убедитесь, что он поднимается сам:

```sh
sudo systemctl enable --now docker
docker info
```

Другой Docker (Docker Desktop, удалённый или rootless daemon) настраивается отдельно; команды комплекта его не переключают.

## Шаг 2. Задача Планировщика при входе

Рекомендуемый способ — встроенный помощник кита: он сам создаёт задачу, а его режим `-Ensure` держит сеанс, поднимает дистрибутив и перезапускает юниты, у которых остановился контейнер.

```powershell
.\windows\wsl-keepalive.ps1 -Distribution Debian -Register
```

Задача `Multfinite-MCPKit-wsl-Debian-keepalive` запускается при входе и повторяется каждые 5 минут. Один проход занимает секунды, поэтому нет долгоживущего процесса, который Планировщик иногда завершает с кодом `0xC000013A`. Отдельный длинный держатель при этом не нужен: его создаёт сам скрипт (через `Win32_Process.Create`, вне job-объекта задачи), а повторный проход лишь проверяет, что сеанс и контейнеры на месте.

Проверить и убрать регистрацию:

```powershell
.\windows\wsl-keepalive.ps1 -Distribution Debian -Ensure      # один проход вручную
.\windows\wsl-keepalive.ps1 -Distribution Debian -Unregister  # убрать задачу
```

Если задача-держатель уже настроена вручную, её можно оставить: она не мешает, но и не восстанавливает контейнеры.

### Ручной вариант

Выполните в обычном сеансе пользователя, под которым должны работать службы. Права администратора не нужны.

```powershell
$distro = 'Debian'                                  # должно совпадать с `wsl -l -q`
$taskName = "Multfinite-MCPKit-wsl-$distro"
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name

$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wsl.exe" `
    -Argument "-d $distro --exec sleep infinity"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'Keeps the WSL distribution running at logon so registered user units can start.' -Force

Start-ScheduledTask -TaskName $taskName
```

Параметры важны:

- `-AtLogOn -User $user` и `-LogonType Interactive` — задача работает в сеансе этого пользователя; WSL и его дистрибутивы привязаны к профилю пользователя.
- `-ExecutionTimeLimit ([TimeSpan]::Zero)` — снимает стандартный лимит в три дня, иначе задача и вместе с ней дистрибутив остановятся.
- `-RestartCount 3 -RestartInterval 1 мин` — повторный запуск при сбое `wsl.exe`.
- `-MultipleInstances IgnoreNew` — второй экземпляр не создаётся, если задача уже выполняется.
- `-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries` — ноутбук не отключит держатель при переходе на батарею.
- `-RunLevel Limited` — запуск без повышения прав.

### Через графический интерфейс

1. Планировщик заданий → **Создать задачу** (не «Создать простую задачу»).
2. **Общие**: имя, например `Multfinite-MCPKit-wsl-Debian`; выберите «Выполнять только при входе пользователя»; «Выполнять с наивысшими правами» — выключено.
3. **Триггеры** → «При входе в систему» → «Конкретный пользователь» → ваша учётная запись.
4. **Действия** → «Запуск программы»: программа `C:\Windows\System32\wsl.exe`, аргументы `-d Debian --exec sleep infinity`, рабочая папка пустая.
5. **Условия**: снимите «Запускать задачу только при питании от электросети» и «Останавливать при переходе на аккумулятор».
6. **Параметры**: снимите «Остановить задачу, если она выполняется дольше: 3 дня»; включите «Если запрос не выполнен, перезапускать каждые: 1 мин, не более 3 раз»; «Не запускать новый экземпляр».

## Шаг 3. Приёмка

```powershell
Get-ScheduledTask -TaskName 'Multfinite-MCPKit-wsl-Debian' | Select-Object TaskName,State
wsl.exe -l -v
```

Ожидается `State = Running` и состояние дистрибутива `Running`. Затем внутри дистрибутива:

```sh
systemctl is-system-running
systemctl --user --failed
systemctl --user list-units 'mcpkit-*'
docker ps
```

Надёжная проверка «как после перезагрузки» — принудительно остановить дистрибутив и запустить задачу заново:

```powershell
wsl.exe --terminate Debian
Start-ScheduledTask -TaskName 'Multfinite-MCPKit-wsl-Debian'
Start-Sleep -Seconds 45
wsl.exe -l -v
```

Если дистрибутив остаётся `Running`, а units активны — автозапуск настроен.

## Обслуживание

- **Остановить автозапуск:** `.\windows\wsl-keepalive.ps1 -Distribution Debian -Unregister`, затем при необходимости `wsl --terminate Debian`. Это не удаляет установки и данные.
- **После `wsl --shutdown`:** дистрибутив и держатель останавливаются; следующий проход задачи-keepalive поднимет дистрибутив сам (до 5 минут). Открытие терминала дистрибутива тоже поднимает ВМ, но не восстанавливает остановленные контейнеры — это делает проход `-Ensure`.
- **Контейнеры пропали через минуту-две после запуска:** проверьте `bash linux/fix-legacy-metamcp-units.sh`. Такой симптом даёт конкурирующий системный юнит, а не сеть или образ.
- **Диагностика:** `Get-ScheduledTaskInfo -TaskName ...` (код последнего запуска), `systemctl --user --failed`, `journalctl --user -b`, `journalctl -b | grep user@1000` (остановки пользовательского manager), `docker info`.
- **Обновления WSL и Windows** могут менять поведение; после крупного обновления повторите приёмку из шага 3.

## Ограничения и подводные камни

- Триггер **«При входе»**, а не «При загрузке»: запуск до входа пользователя требует сохранённого пароля учётной записи и работы в служебном сеансе. WSL в таком режиме не гарантирует доступ к профилю, сети и Docker; не настраивайте это без отдельной проверки.
- Задача держит **один** сеанс. `wsl --shutdown`, `wsl --terminate`, завершение задачи или перезагрузка компьютера останавливают дистрибутив.
- Не задавайте лимит времени выполнения и не включайте остановку задачи при работе от батареи — держатель должен работать всё время сеанса.
- Не используйте `vmIdleTimeout` в `.wslconfig` как замену держателю: он управляет простоем виртуальной машины WSL, а не временем жизни дистрибутива и его пользовательских служб.
- Одна задача на дистрибутив. Для второго дистрибутива повторите шаги с другим именем задачи и идентификатором из `wsl -l -q`.
- **Не регистрируйте системные юниты.** `systemctl` (без `--user`) и файлы в `/etc/systemd/system` не нужны: кит создаёт пользовательские юниты. Системный шаблон вида `/etc/systemd/system/metamcp@.service` с `Type=forking` и `Restart=on-failure` конфликтует с ними — `run-metamcp.sh start` работает в foreground, systemd считает запуск неуспешным и на каждом рестарте выполняет `ExecStop`, то есть останавливает только что поднятые контейнеры. Проверка и удаление: `bash linux/fix-legacy-metamcp-units.sh`, затем `sudo bash linux/fix-legacy-metamcp-units.sh --remove`.

## Необязательно: перезапуск внутри процесса

Режим `-Hold` держит сеанс в foreground и повторяет попытку через `-RetrySeconds`, если сеанс завершился:

```powershell
.\windows\wsl-keepalive.ps1 -Distribution Debian -Hold
```

Используйте его из терминала или для ручной задачи. Для Планировщика предпочтителен `-Register`: короткие повторяющиеся проходы надёжнее одного долгоживущего процесса, который Планировщик может завершить с кодом `0xC000013A`.

Проверка восстановления: `wsl.exe --terminate Debian`, затем дождитесь следующего прохода задачи (до 5 минут) — дистрибутив снова `Running`, а `docker ps` показывает контейнеры кита. Остановленный вручную контейнер приложения тоже поднимается: `docker stop <project>-app-1` и следующий проход перезапускает соответствующий юнит.

> **Кто владеет задачей.** Задачу, созданную из сеанса с повышенными правами, нельзя изменить без таких же прав: обычный сеанс получает `Отказано в доступе`. Для этого `windows\run-local.ps1` и `windows\run-global-servers.ps1` при ошибке создают отдельную задачу `<имя>-watchdog` с повтором каждые 10 минут и предупреждают об этом. Чтобы обновить саму задачу входа, повторите `register-service` из PowerShell, запущенного от имени администратора.

## Альтернатива без Планировщика

Ярлык в `shell:startup` на `C:\Windows\System32\wsl.exe` с аргументами `-d Debian --exec sleep infinity` запускается при входе без прав администратора, но не имеет политики перезапуска и не виден в списке задач. Для постоянной инфраструктуры предпочтительна задача Планировщика.
