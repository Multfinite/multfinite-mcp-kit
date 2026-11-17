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

### PowerShell (рекомендуется)

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

- **Остановить автозапуск:** `Stop-ScheduledTask -TaskName 'Multfinite-MCPKit-wsl-Debian'; Unregister-ScheduledTask -TaskName 'Multfinite-MCPKit-wsl-Debian' -Confirm:$false`, затем при необходимости `wsl --terminate Debian`. Это не удаляет установки и данные.
- **После `wsl --shutdown`:** дистрибутив и задача останавливаются; запустите задачу снова (`Start-ScheduledTask ...`). Открытие терминала дистрибутива само по себе не восстанавливает задачу.
- **Диагностика:** `Get-ScheduledTaskInfo -TaskName ...` (код последнего запуска), `systemctl --user --failed`, `journalctl --user -b`, `docker info`.
- **Обновления WSL и Windows** могут менять поведение; после крупного обновления повторите приёмку из шага 3.

## Ограничения и подводные камни

- Триггер **«При входе»**, а не «При загрузке»: запуск до входа пользователя требует сохранённого пароля учётной записи и работы в служебном сеансе. WSL в таком режиме не гарантирует доступ к профилю, сети и Docker; не настраивайте это без отдельной проверки.
- Задача держит **один** сеанс. `wsl --shutdown`, `wsl --terminate`, завершение задачи или перезагрузка компьютера останавливают дистрибутив.
- Не задавайте лимит времени выполнения и не включайте остановку задачи при работе от батареи — держатель должен работать всё время сеанса.
- Не используйте `vmIdleTimeout` в `.wslconfig` как замену держателю: он управляет простоем виртуальной машины WSL, а не временем жизни дистрибутива и его пользовательских служб.
- Одна задача на дистрибутив. Для второго дистрибутива повторите шаги с другим именем задачи и идентификатором из `wsl -l -q`.

## Необязательно: самовосстановление после `wsl --shutdown`

Если дистрибутив должен подниматься снова и после ручной остановки, укажите в задаче не `wsl.exe`, а небольшой командный файл:

```bat
@echo off
rem Keeps the WSL distribution running; restarts it after wsl --shutdown.
:loop
wsl.exe -d Debian --exec sleep infinity
timeout /t 10 /nobreak >nul
goto loop
```

Действие задачи: программа `C:\Windows\System32\cmd.exe`, аргументы `/c "<полный путь к файлу>.cmd"`. Такая задача действительно работает всё время сеанса и перезапускает дистрибутив через 10 секунд после остановки. Не используйте этот вариант, если `wsl --shutdown` должен надолго освобождать память и остановить все службы.

## Альтернатива без Планировщика

Ярлык в `shell:startup` на `C:\Windows\System32\wsl.exe` с аргументами `-d Debian --exec sleep infinity` запускается при входе без прав администратора, но не имеет политики перезапуска и не виден в списке задач. Для постоянной инфраструктуры предпочтительна задача Планировщика.
