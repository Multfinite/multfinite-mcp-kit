#Requires -Version 5.1
<#
.SYNOPSIS
    Keeps a WSL 2 distribution and its kit services running.
.DESCRIPTION
    WSL stops the systemd user manager when the last session of the distribution
    ends, even with linger enabled. Every unit started by
    `run-metamcp.sh register-service` then runs its ExecStop, which stops the
    containers that were just started. This script guarantees that one holder
    session always exists and that the kit's own units are active.

    -Ensure performs one pass and exits, so it is safe to call from a short
    repeating scheduled task. Both the holder and the distribution start are
    created outside the caller's job object, so they survive the task instance.

    -Hold runs the loop in the foreground instead, for manual use from a terminal.
.PARAMETER Distribution
    Distribution name exactly as shown by `wsl --list --quiet`.
.PARAMETER Hold
    Run the restart loop in the foreground instead of a single ensure pass.
.PARAMETER RetrySeconds
    Delay between attempts in -Hold mode.
.PARAMETER Register
    Create or update the repeating scheduled task that runs -Ensure.
.PARAMETER Unregister
    Remove that scheduled task.
.PARAMETER IntervalMinutes
    Repetition interval of the registered task.
.EXAMPLE
    .\windows\wsl-keepalive.ps1 -Distribution Debian -Register
.EXAMPLE
    .\windows\wsl-keepalive.ps1 -Distribution Debian -Ensure
.EXAMPLE
    .\windows\wsl-keepalive.ps1 -Distribution Debian -Hold
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Distribution = 'Debian',
    [switch]$Ensure,
    [switch]$Hold,
    [switch]$Register,
    [switch]$Unregister,
    [ValidateRange(1, 3600)][int]$RetrySeconds = 10,
    [ValidateRange(1, 1440)][int]$IntervalMinutes = 5
)
$ErrorActionPreference = 'Stop'
$modes = @($Ensure, $Hold, $Register, $Unregister) | Where-Object { $_ }
if ($modes.Count -gt 1) { throw 'Choose only one of -Ensure, -Hold, -Register or -Unregister.' }
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
if ([string]::IsNullOrWhiteSpace($Distribution)) { throw 'Distribution name is required.' }
$Wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
if (-not (Test-Path -LiteralPath $Wsl -PathType Leaf)) { throw "wsl.exe was not found at $Wsl." }

function Get-RunningDistributions {
    # wsl.exe writes UTF-16; Windows PowerShell 5.1 decodes it as ANSI and leaves
    # NUL bytes between characters, so strip them before splitting lines.
    $text = (& $Wsl --list --running --quiet 2>$null) -join "`n"
    if (-not $text) { return @() }
    return @(($text -replace "`0", '') -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-DistroRunning {
    return (Get-RunningDistributions) -contains $Distribution
}

function Test-Holder {
    # The holder is the long-lived session that keeps the user manager alive.
    # Match the whole command line so the surrounding shell is not counted.
    $output = (& $Wsl -d $Distribution --exec bash -c "ps -eo args= | grep -cx 'sleep infinity' || true" 2>$null) -join ''
    $count = 0
    return ([int]::TryParse(($output -replace '\D', ''), [ref]$count) -and $count -gt 0)
}

function Start-Detached([string]$Arguments) {
    # Win32_Process.Create spawns the process from the WMI provider host, so it is
    # not a child of this task and is not killed when the task instance ends.
    $commandLine = '"' + $Wsl + '" ' + $Arguments
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine }
    if ($result.ReturnValue -ne 0) { throw "Could not start '$commandLine' (Win32_Process.Create returned $($result.ReturnValue))." }
    return [int]$result.ProcessId
}

function Repair-KitUnits {
    # Start or restart the kit's own units whose app container is not running.
    # Units are recognised by the marker written by linux/service-registration.sh.
    $script = @'
set -u
repaired=0
for unit in $(systemctl --user list-unit-files 'mcpkit-*.service' --no-legend --no-pager 2>/dev/null | awk '{print $1}'); do
    file="$HOME/.config/systemd/user/$unit"
    [ -f "$file" ] || continue
    grep -q 'mcpkit-managed-service' "$file" || continue
    kind=$(sed -n 's/^# mcpkit-managed-service: v1 kind=\([a-z-]*\) directory=.*/\1/p' "$file" | head -n1)
    directory=$(sed -n 's/^# mcpkit-managed-service: v1 kind=[a-z-]* directory=//p' "$file" | head -n1)
    [ -n "$directory" ] || continue
    state="$directory/.mcpkit/state.json"
    [ -f "$state" ] || continue
    project=$(node -e 'process.stdout.write(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).project)' "$state" 2>/dev/null) || continue
    [ -n "$project" ] || continue
    # MetaMCP projects publish an "app" service, GLOBAL projects a "gateway".
    if [ "$kind" = global ]; then service=gateway; else service=app; fi
    active=$(systemctl --user is-active "$unit" 2>/dev/null || true)
    running=$(docker ps --filter "label=com.docker.compose.project=$project" --filter "label=com.docker.compose.service=$service" --format '{{.Names}}' 2>/dev/null | wc -l)
    if [ "$active" != active ]; then
        echo "starting $unit"
        systemctl --user start "$unit" && repaired=$((repaired + 1))
    elif [ "$running" -eq 0 ]; then
        echo "restarting $unit (app container is not running)"
        systemctl --user restart "$unit" && repaired=$((repaired + 1))
    fi
done
echo "repaired=$repaired"
'@
    return (& $Wsl -d $Distribution --exec bash -c $script 2>&1) -join "`n"
}

if ($Hold) {
    while ($true) {
        & $Wsl -d $Distribution --exec sleep infinity
        Start-Sleep -Seconds $RetrySeconds
    }
}

if ($Register -or $Unregister) {
    $taskName = "Multfinite-MCPKit-wsl-$Distribution-keepalive"
    $description = 'MCPKIT-MANAGED: v1 kind=wsl-keepalive'
    $existing = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($existing -and $existing.Description -cne $description) {
        throw "Refusing to change a scheduled task not owned by MCP Kit: $taskName"
    }
    if ($Unregister) {
        if (-not $existing) { Write-Host "No keepalive task is registered for $Distribution."; exit 0 }
        Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
        Write-Host "Removed the keepalive task for $Distribution. A running distribution was left running."
        exit 0
    }
    $engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $engine = Join-Path $PSHOME $engineName
    if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) {
        $found = Get-Command $engineName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $engine = $found.Source } else { throw "PowerShell executable '$engineName' was not found." }
    }
    $argument = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath +
        '" -Distribution ' + $Distribution + ' -Ensure'
    $action = New-ScheduledTaskAction -Execute $engine -Argument $argument -WorkingDirectory (Split-Path -Parent $PSCommandPath)
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $user
    # Short, repeating passes instead of one long-lived holder: a process that
    # must live for hours is what Task Scheduler terminated with 0xC000013A.
    $repeat = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 1)
    $task = New-ScheduledTask -Action $action -Trigger @($logon, $repeat) -Settings $settings -Principal $principal -Description $description
    Register-ScheduledTask -TaskName $taskName -TaskPath '\' -InputObject $task -Force | Out-Null
    if ((Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -ne 'Running') {
        Start-ScheduledTask -TaskName $taskName -TaskPath '\'
    }
    Write-Host "Registered '$taskName': runs at logon and every $IntervalMinutes minute(s)."
    exit 0
}

$changed = $false
if (-not (Test-DistroRunning)) {
    [void](Start-Detached "-d $Distribution --exec true")
    $changed = $true
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Seconds 1
        if (Test-DistroRunning) { break }
    }
    if (-not (Test-DistroRunning)) { throw "$Distribution did not start within 30 seconds." }
    Write-Host "Started $Distribution."
}

if (-not (Test-Holder)) {
    [void](Start-Detached "-d $Distribution --exec sleep infinity")
    $changed = $true
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Seconds 1
        if (Test-Holder) { break }
    }
    if (-not (Test-Holder)) { throw "Could not keep a session open in $Distribution." }
    Write-Host "Started the session holder in $Distribution."
}

if (-not $changed) { Write-Host "$Distribution is running with an active holder." }

$repair = Repair-KitUnits
if ($repair) { Write-Host $repair }
if ($repair -notmatch 'repaired=[1-9]') { Write-Host 'All kit services are running.' }
