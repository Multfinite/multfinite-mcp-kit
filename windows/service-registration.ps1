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
    if ($existing -and -not [string]::Equals([string]$existing.Principal.UserId, [string]$identity.User, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The existing MCP Kit task belongs to another Windows account: $($identity.TaskName)"
    }

    $powershell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) { throw 'Windows PowerShell 5.1 was not found.' }
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($StartArguments)
    $argumentLine = (($arguments | ForEach-Object { ConvertTo-McpKitCommandLineArgument ([string]$_) }) -join ' ')
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $argumentLine -WorkingDirectory (Split-Path -Parent $ScriptPath)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.User
    $principal = New-ScheduledTaskPrincipal -UserId $identity.User -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description $identity.Description
    Register-ScheduledTask -TaskName $identity.TaskName -TaskPath '\' -InputObject $task -Force | Out-Null

    $registered = Get-ScheduledTask -TaskName $identity.TaskName -TaskPath '\'
    if ($registered.State -ne 'Running') { Start-ScheduledTask -TaskName $identity.TaskName -TaskPath '\' }
    Write-Host "Registered $Kind auto-start task '$($identity.TaskName)' for the current user's logon and requested one start now."
}

function Unregister-McpKitScheduledTask([ValidateSet('global','local')][string]$Kind, [string]$Directory) {
    if ($env:OS -ne 'Windows_NT') { throw 'Task Scheduler registration is available only on Windows.' }
    if (-not (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue)) { throw 'The Windows Task Scheduler PowerShell module is unavailable.' }
    $identity = Get-McpKitScheduledTaskIdentity $Kind $Directory
    $existing = Get-ScheduledTask -TaskName $identity.TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host "No MCP Kit $Kind auto-start task is registered for $($identity.Directory)."
        return
    }
    if ($existing.Description -cne $identity.Description -or
        -not [string]::Equals([string]$existing.Principal.UserId, [string]$identity.User, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a scheduled task not owned by this MCP Kit installation: $($identity.TaskName)"
    }
    Unregister-ScheduledTask -TaskName $identity.TaskName -TaskPath '\' -Confirm:$false
    Write-Host "Removed auto-start task '$($identity.TaskName)'. A currently running server was left running."
}
