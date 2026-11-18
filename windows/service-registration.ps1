# Helpers for per-user Task Scheduler registration. Windows PowerShell 5.1 compatible.
function ConvertTo-McpKitCommandLineArgument([string]$Value) {
    # Quote according to the Windows C runtime command-line rules. This keeps
    # paths with spaces, quotes, or trailing backslashes as one PowerShell arg.
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            if ($slashes) { [void]$builder.Append(('\' * (2 * $slashes + 1))) }
            else { [void]$builder.Append('\') }
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes) { [void]$builder.Append(('\' * (2 * $slashes))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-McpKitAccountSid([string]$Name) {
    # Task Scheduler stores the same account as "User" where GetCurrent() returns
    # "MACHINE\User", so compare identities, not spellings.
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    try { return (New-Object Security.Principal.NTAccount($Name)).Translate([Security.Principal.SecurityIdentifier]).Value }
    catch { return $null }
}

function Test-McpKitSameAccount([string]$Left, [string]$Right) {
    $leftSid = ConvertTo-McpKitAccountSid $Left
    $rightSid = ConvertTo-McpKitAccountSid $Right
    if ($leftSid -and $rightSid) { return $leftSid -eq $rightSid }
    return [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
}

function Get-McpKitScheduledTaskIdentity([ValidateSet('global','local')][string]$Kind, [string]$Directory) {
    $full = [IO.Path]::GetFullPath($Directory)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $user = if ($identity.User) { $identity.User.Value } else { $identity.Name }
    $material = "$Kind`n$user`n$($full.ToUpperInvariant())"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($material))) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{
        Directory = $full
        User = $identity.Name
        Key = $digest.Substring(0, 16)
        TaskName = "Multfinite-MCPKit-$Kind-$($digest.Substring(0, 16))"
        Description = "MCPKIT-MANAGED: v1 kind=$Kind key=$($digest.Substring(0, 16))"
    }
}

function Register-McpKitScheduledTask(
    [ValidateSet('global','local')][string]$Kind,
    [string]$Directory,
    [string]$ScriptPath,
    [string[]]$StartArguments
) {
    if ($env:OS -ne 'Windows_NT') { throw 'Task Scheduler registration is available only on Windows.' }
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) { throw 'The Windows Task Scheduler PowerShell module is unavailable.' }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw "Installation directory not found: $Directory" }
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Runner not found: $ScriptPath" }

    $identity = Get-McpKitScheduledTaskIdentity $Kind $Directory
    $existing = Get-ScheduledTask -TaskName $identity.TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($existing -and $existing.Description -cne $identity.Description) {
        throw "Refusing to replace a scheduled task not owned by MCP Kit: $($identity.TaskName)"
    }
    if ($existing -and -not (Test-McpKitSameAccount ([string]$existing.Principal.UserId) ([string]$identity.User))) {
        throw "The existing MCP Kit task belongs to another Windows account: $($identity.TaskName)"
    }

    $engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $powershell = Join-Path $PSHOME $engineName
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) {
        $engine = Get-Command $engineName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($engine) { $powershell = $engine.Source }
        else { throw "PowerShell executable '$engineName' was not found in PSHOME or PATH." }
    }
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($StartArguments)
    $argumentLine = (($arguments | ForEach-Object { ConvertTo-McpKitCommandLineArgument ([string]$_) }) -join ' ')
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $argumentLine -WorkingDirectory (Split-Path -Parent $ScriptPath)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.User
    # A logon trigger alone misses a resume from sleep and a task that exited
    # while the user stayed signed in. The start command is idempotent, so a
    # slow watchdog keeps the service available without duplicating containers
    # or processes (MultipleInstances IgnoreNew).
    $watchdog = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2)) -RepetitionInterval (New-TimeSpan -Minutes 10)
    $principal = New-ScheduledTaskPrincipal -UserId $identity.User -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $task = New-ScheduledTask -Action $action -Trigger @($trigger, $watchdog) -Settings $settings -Principal $principal -Description $identity.Description
    $registeredName = $identity.TaskName
    try {
        Register-ScheduledTask -TaskName $identity.TaskName -TaskPath '\' -InputObject $task -Force | Out-Null
    } catch {
        # A task created by an elevated session cannot be rewritten without the
        # same rights. The current user may still create a new task, so install
        # a separate watchdog instead of leaving the machine without recovery.
        $watchdogName = "$($identity.TaskName)-watchdog"
        $watchdogDescription = "MCPKIT-MANAGED: v1 kind=$Kind-watchdog key=$(($identity.Key))"
        $watchdogSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $watchdogTask = New-ScheduledTask -Action $action -Trigger @($watchdog) -Settings $watchdogSettings -Principal $principal -Description $watchdogDescription
        Register-ScheduledTask -TaskName $watchdogName -TaskPath '\' -InputObject $watchdogTask -Force | Out-Null
        $registered = Get-ScheduledTask -TaskName $watchdogName -TaskPath '\'
        if ($registered.State -ne 'Running') { Start-ScheduledTask -TaskName $watchdogName -TaskPath '\' }
        Write-Warning ("Task '$($identity.TaskName)' is owned by another/elevated session and was not changed: $($_.Exception.Message.Trim())")
        Write-Warning "Registered the $Kind watchdog task '$watchdogName' instead; it restarts the service every 10 minutes. Re-run this command from an elevated PowerShell to update the logon task itself."
        return
    }

    $registered = Get-ScheduledTask -TaskName $identity.TaskName -TaskPath '\'
    if ($registered.State -ne 'Running') { Start-ScheduledTask -TaskName $identity.TaskName -TaskPath '\' }
    Write-Host "Registered $Kind auto-start task '$($identity.TaskName)' for the current user's logon and requested one start now."
}

function Unregister-McpKitScheduledTask([ValidateSet('global','local')][string]$Kind, [string]$Directory) {
    if ($env:OS -ne 'Windows_NT') { throw 'Task Scheduler registration is available only on Windows.' }
    if (-not (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue)) { throw 'The Windows Task Scheduler PowerShell module is unavailable.' }
    $identity = Get-McpKitScheduledTaskIdentity $Kind $Directory
    $watchdogName = "$($identity.TaskName)-watchdog"
    foreach ($name in @($watchdogName, $identity.TaskName)) {
        $existing = Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
        if (-not $existing) { continue }
        if ($existing.Description -cne $identity.Description -and
            $existing.Description -cne "MCPKIT-MANAGED: v1 kind=$Kind-watchdog key=$($identity.Key)") {
            throw "Refusing to remove a scheduled task not owned by this MCP Kit installation: $name"
        }
        if (-not (Test-McpKitSameAccount ([string]$existing.Principal.UserId) ([string]$identity.User))) {
            throw "Refusing to remove a scheduled task owned by another Windows account: $name"
        }
        Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false
        Write-Host "Removed auto-start task '$name'. A currently running server was left running."
    }
    if (-not (Get-ScheduledTask -TaskName $identity.TaskName -TaskPath '\' -ErrorAction SilentlyContinue) -and
        -not (Get-ScheduledTask -TaskName $watchdogName -TaskPath '\' -ErrorAction SilentlyContinue)) {
        Write-Host "No MCP Kit $Kind auto-start task remains for $($identity.Directory)."
    }
}
