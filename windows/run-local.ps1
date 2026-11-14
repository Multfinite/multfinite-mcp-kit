#Requires -Version 5.1
<#
.SYNOPSIS
    Manage the native Windows servers and local MetaMCP in Docker Desktop.
.EXAMPLE
    .\windows\run-local.ps1 start
    .\windows\run-local.ps1 status
    .\windows\run-local.ps1 logs obsidian
    .\windows\run-local.ps1 seed
    .\windows\run-local.ps1 seed -OwnerEmail 'you@example.com'
    .\windows\run-local.ps1 reset-metamcp-records
    .\windows\run-local.ps1 enable-signup
    .\windows\run-local.ps1 logs metamcp
    .\windows\run-local.ps1 ports
    .\windows\run-local.ps1 set-ports -WebPort 13008 -BackendPort 13009
#>
[CmdletBinding()]
param(
    # init is used by the installer; it never replaces existing settings.
    [ValidateSet('init', 'start', 'stop', 'restart', 'status', 'logs', 'credentials', 'seed', 'reset-metamcp-records', 'enable-signup', 'ports', 'set-ports', 'gateway-start', 'gateway-stop', 'gateway-restart', 'gateway-status')]
    [string]$Command = 'start',
    [string]$Server = '',
    [string]$OwnerEmail = '',
    [ValidateRange(0, 65535)]
    [int]$WebPort = 0,
    [ValidateRange(0, 65535)]
    [int]$BackendPort = 0
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This script must be run in a Windows user session.' }
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseDir = if ($env:MCP_LOCAL_DIR) { [IO.Path]::GetFullPath($env:MCP_LOCAL_DIR) } else { Join-Path $env:USERPROFILE 'mcp-local' }
$ConfigDir = Join-Path $BaseDir 'config'
$PrivateDir = Join-Path $ConfigDir 'private'
$Runtime = Join-Path $BaseDir 'runtime'
$Logs = Join-Path $BaseDir 'logs'
$SettingsFile = Join-Path $ConfigDir 'local-settings.json'
$SecretsFile = Join-Path $PrivateDir 'secrets.json'
$StateFile = Join-Path $PrivateDir 'gateway-state.json'
$Node = Join-Path $Runtime 'node\node_modules\node\bin\node.exe'
$Manifest = Get-Content -LiteralPath (Join-Path $ScriptDir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
. (Join-Path $ScriptDir 'local-common.ps1')

function New-RandomHex([int]$ByteCount) {
    $bytes = New-Object byte[] $ByteCount
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}
function Read-Json([string]$File) {
    return (Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Save-Json([string]$File, $Value, [switch]$CreateOnly) {
    # Write in the same directory and rename; never replace a first-run file
    # created concurrently by the user or another installer.
    $temp = "$File.$PID.$(New-RandomHex 4).tmp"
    try {
        $json = (ConvertTo-Json -InputObject $Value -Depth 30) + "`n"
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
        $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        if ($CreateOnly) {
            try { [IO.File]::Move($temp, $File); return $true }
            catch [IO.IOException] { if (Test-Path -LiteralPath $File) { return $false }; throw }
        }
        if (Test-Path -LiteralPath $File) { [IO.File]::Replace($temp, $File, [NullString]::Value) }
        else { [IO.File]::Move($temp, $File) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}

function Get-LegacyValues {
    $values = @{}
    $file = Join-Path $ConfigDir '.env'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $values }
    foreach ($line in [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)) {
        # Literal parsing only; never execute or expand the existing .env.
        $match = [regex]::Match($line.TrimStart([char]0xFEFF), '^\s*(?:export\s+)?(PROJECTS_DIR|WRITING_DIR|DBHUB_DSN|OBSIDIAN_API_KEY)=(.*)$')
        if (-not $match.Success) { continue }
        $key = $match.Groups[1].Value
        $value = $match.Groups[2].Value.Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if ($key -in @('PROJECTS_DIR', 'WRITING_DIR')) {
            if ([IO.Path]::IsPathRooted($value) -and (Test-Path -LiteralPath $value -PathType Container)) { $values[$key] = $value }
        } elseif ($key -eq 'DBHUB_DSN') {
            if ($value -ne 'postgres://user:pass@localhost:5432/devdb' -and $value -match '^[a-zA-Z][a-zA-Z0-9+.-]*://' -and $value -notmatch '[<>]') { $values[$key] = $value }
        } elseif ($value -and $value -notmatch '[<>]') { $values[$key] = $value }
    }
    return $values
}
function Initialize-Configuration {
    Protect-PrivateDirectory $PrivateDir
    Protect-PrivateDirectory $Logs
    Protect-PrivateDirectory $Runtime
    foreach ($dir in @((Join-Path $BaseDir 'data\projects'), (Join-Path $BaseDir 'data\writing'))) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $legacy = Get-LegacyValues
    $name = [Environment]::MachineName.ToLowerInvariant() -creplace '[^a-z0-9]+', '-'
    $name = $name.Trim('-')
    if ($name.Length -gt 20) { $name = $name.Substring(0, 20).TrimEnd('-') }
    if (-not $name) { $name = 'windows' }
    $settings = [ordered]@{
        version = 1
        hostId = "$name-$(New-RandomHex 3)"
        listenHost = '127.0.0.1'
        port = 13001
        tlsCertFile = ''
        tlsKeyFile = ''
        allowInsecureLan = $false
        projectsDir = if ($legacy.PROJECTS_DIR) { $legacy.PROJECTS_DIR } else { Join-Path $BaseDir 'data\projects' }
        writingDir = if ($legacy.WRITING_DIR) { $legacy.WRITING_DIR } else { Join-Path $BaseDir 'data\writing' }
        everythingSdkPath = Join-Path $Runtime 'everything-sdk\Everything64.dll'
        obsidianHost = '127.0.0.1'
        obsidianPort = 27124
    }
    $secrets = [ordered]@{
        gatewayApiKey = New-RandomHex 32
        obsidianApiKey = if ($legacy.OBSIDIAN_API_KEY) { $legacy.OBSIDIAN_API_KEY } else { '' }
        dbhubDsn = if ($legacy.DBHUB_DSN) { $legacy.DBHUB_DSN } else { '' }
    }
    $created = Save-Json $SettingsFile $settings -CreateOnly
    Write-KitOk "$(if ($created) { 'Created' } else { 'Preserved' }) $SettingsFile"
    $created = Save-Json $SecretsFile $secrets -CreateOnly
    Write-KitOk "$(if ($created) { 'Created' } else { 'Preserved' }) $SecretsFile"
    if (Test-Path -LiteralPath (Join-Path $ConfigDir 'mcp-local.json')) { Write-KitInfo 'The legacy mcp-local.json and .env are not modified.' }
}
function Test-Settings($Settings, $Secrets) {
    if ($Settings.version -ne 1) { throw 'Unsupported local settings version.' }
    if ($Settings.hostId -isnot [string] -or $Settings.hostId.Length -gt 32 -or $Settings.hostId -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'Invalid hostId.' }
    if ($Settings.listenHost -isnot [string] -or $Settings.listenHost -notmatch '^[a-zA-Z0-9.:-]+$') { throw 'Invalid listenHost.' }
    if (($Settings.port -isnot [int] -and $Settings.port -isnot [long]) -or $Settings.port -lt 1 -or $Settings.port -gt 65535) { throw 'port must be between 1 and 65535.' }
    foreach ($key in @('projectsDir', 'writingDir', 'everythingSdkPath')) {
        if ($Settings.$key -isnot [string] -or -not [IO.Path]::IsPathRooted($Settings.$key)) { throw "$key must be an absolute path." }
    }
    if ($Settings.obsidianHost -isnot [string] -or $Settings.obsidianHost.ToLowerInvariant() -notin @('127.0.0.1', 'localhost')) { throw 'obsidianHost must be localhost or 127.0.0.1; use a local tunnel for a remote Obsidian API.' }
    if (($Settings.obsidianPort -isnot [int] -and $Settings.obsidianPort -isnot [long]) -or $Settings.obsidianPort -lt 1 -or $Settings.obsidianPort -gt 65535) { throw 'Invalid obsidianPort.' }
    if ($Settings.allowInsecureLan -isnot [bool]) { throw 'allowInsecureLan must be true or false.' }
    if ($Secrets.gatewayApiKey -isnot [string] -or $Secrets.gatewayApiKey -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid gateway key in secrets.json; do not delete it on an existing installation.' }
    foreach ($key in @('obsidianApiKey', 'dbhubDsn')) { if ($Secrets.$key -isnot [string]) { throw "$key must be a string in secrets.json." } }
    foreach ($key in @('tlsCertFile', 'tlsKeyFile')) {
        if ($Settings.$key -isnot [string]) { throw "$key must be a string." }
    }
    if ([bool]$Settings.tlsCertFile -ne [bool]$Settings.tlsKeyFile) { throw 'Set both tlsCertFile and tlsKeyFile, or leave both blank.' }
    foreach ($key in @('tlsCertFile', 'tlsKeyFile')) {
        if ($Settings.$key -and (-not [IO.Path]::IsPathRooted($Settings.$key) -or -not (Test-Path -LiteralPath $Settings.$key -PathType Leaf))) { throw "$key must be an existing absolute file path." }
    }
    if ($Settings.listenHost.ToLowerInvariant() -notin @('127.0.0.1', '::1', 'localhost') -and -not $Settings.tlsCertFile -and -not $Settings.allowInsecureLan) {
        throw 'A non-loopback listener needs TLS, or explicit HTTP opt-in for an encrypted private VPN/tunnel.'
    }
}
function Get-Configuration {
    if (-not (Test-Path -LiteralPath $SettingsFile) -or -not (Test-Path -LiteralPath $SecretsFile)) { throw 'Run install-local.ps1 first.' }
    $settings = Read-Json $SettingsFile
    $secrets = Read-Json $SecretsFile
    Test-Settings $settings $secrets
    return [pscustomobject]@{ settings = $settings; secrets = $secrets }
}

function Get-CertificatePin([string]$File) {
    # Pin the exact first certificate for local control requests. A self-signed
    # gateway certificate is fine here; no global TLS setting is changed.
    $pem = [IO.File]::ReadAllText($File)
    $match = [regex]::Match($pem, '-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----')
    if (-not $match.Success) { throw 'tlsCertFile must contain a PEM certificate.' }
    return [Convert]::ToBase64String([Convert]::FromBase64String($match.Groups[1].Value))
}
function Enable-CertificatePinType {
    if ('McpKitControlCertPin' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public sealed class McpKitControlCertPin {
    private readonly string expected;
    public McpKitControlCertPin(string expected) { this.expected = expected; }
    public bool Validate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
        return cert != null && Convert.ToBase64String(cert.GetRawCertData()) == expected;
    }
    public static RemoteCertificateValidationCallback Create(string expected) {
        return new RemoteCertificateValidationCallback(new McpKitControlCertPin(expected).Validate);
    }
}
'@
}
function Invoke-Control($State, [string]$Action) {
    $hostName = if ($State.host -in @('0.0.0.0', '::', '[::]')) { '127.0.0.1' } else { [string]$State.host }
    $builder = New-Object UriBuilder
    $builder.Scheme = if ($State.tls) { 'https' } else { 'http' }
    $builder.Host = $hostName
    $builder.Port = [int]$State.port
    $builder.Path = "/_mcpkit/$Action"
    $request = [Net.HttpWebRequest][Net.WebRequest]::Create($builder.Uri)
    $request.Proxy = $null
    $request.Timeout = 2500
    $request.ReadWriteTimeout = 2500
    $request.KeepAlive = $false
    $request.AllowAutoRedirect = $false
    $request.Method = if ($Action -eq 'stop') { 'POST' } else { 'GET' }
    if ($Action -eq 'stop') { $request.ContentLength = 0 }
    $request.Headers.Add('X-Mcpkit-Control', [string]$State.controlKey)
    if ($State.tls) {
        if (-not $State.certPin) { throw 'The gateway state has no TLS certificate pin.' }
        Enable-CertificatePinType
        $request.ServerCertificateValidationCallback = [McpKitControlCertPin]::Create([string]$State.certPin)
    }
    $response = $request.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $result = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        if ($result.instanceId -cne $State.instanceId) { throw 'Unexpected control response.' }
        return $result
    } finally { $response.Dispose() }
}
function Test-ProcessAlive([int]$ProcessId) {
    if ($ProcessId -le 0) { return $false }
    try { $process = Get-Process -Id $ProcessId -ErrorAction Stop; return -not $process.HasExited }
    catch { return $false }
}
function Remove-StateIfMatching([string]$InstanceId) {
    try {
        if ((Read-Json $StateFile).instanceId -ceq $InstanceId) { Remove-Item -LiteralPath $StateFile -Force }
    } catch { # Another shutdown may already have removed the file.
    }
}
function Get-RunningState {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) { return $null }
    $state = Read-Json $StateFile
    if ($state.pid -isnot [int] -and $state.pid -isnot [long]) { throw "Invalid gateway state: $StateFile" }
    try { return [pscustomobject]@{ state = $state; status = (Invoke-Control $state 'status') } }
    catch {
        if (Test-ProcessAlive $state.pid) { throw "A process recorded as gateway PID $($state.pid) is still alive but not responding. No process was killed; investigate $StateFile." }
        Remove-StateIfMatching $state.instanceId
        return $null
    }
}
function Show-Status($Status) {
    $counts = @{ ready = 0; waiting = 0; starting = 0; error = 0 }
    foreach ($item in @($Status.servers)) {
        $detail = if ($item.detail) { ": $($item.detail)" } else { '' }
        $line = '{0,-9} {1}{2}' -f $item.status, $item.id, $detail
        switch ($item.status) {
            'ready'    { Write-KitOk $line }
            'waiting'  { Write-KitWarn $line }
            'starting' { Write-KitInfo $line }
            'error'    { Write-KitError $line }
            default    { Write-KitInfo $line }
        }
        if ($counts.ContainsKey([string]$item.status)) { $counts[[string]$item.status]++ }
    }
    $summary = "Ready: $($counts.ready); waiting for configuration: $($counts.waiting); starting: $($counts.starting); errors: $($counts.error)."
    if ($counts.error -or $counts.waiting -or $counts.starting) { Write-KitWarn $summary } else { Write-KitOk $summary }
    return $counts
}
function Start-Gateway {
    Write-KitHeader 'Windows LOCAL MCP servers'
    $config = Get-Configuration
    $settings = $config.settings
    if (-not (Test-Path -LiteralPath $Node -PathType Leaf)) { throw 'The kit Node runtime is missing. First run install-local.ps1.' }
    $lockFile = Join-Path $PrivateDir 'start.lock'
    try { $lock = [IO.File]::Open($lockFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
    catch [IO.IOException] {
        if (Test-Path -LiteralPath $lockFile) { throw "Another start may be in progress. If it crashed, inspect and remove $lockFile before retrying." }
        throw
    }
    try {
        $current = Get-RunningState
        if ($current) {
            Write-KitInfo 'Gateway is already running; settings are unchanged until restart.'
            $counts = Show-Status $current.status
            if ($counts.error -or $counts.starting) { throw 'Some servers failed or are still starting. See status and logs.' }
            return
        }
        $controlKey = New-RandomHex 32
        $instanceId = New-RandomHex 16
        $certPin = if ($settings.tlsCertFile) { Get-CertificatePin $settings.tlsCertFile } else { '' }
        $logStem = 'gateway-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff') + '-' + (New-RandomHex 4)
        $outputLog = Join-Path $Logs "$logStem.out.log"
        $errorLog = Join-Path $Logs "$logStem.err.log"
        $scriptPath = Join-Path $ScriptDir 'local-kit.mjs'
        # Start-Process on Windows combines ArgumentList into a command line;
        # quote the script path so spaces in the repository remain one argument.
        $params = @{
            FilePath = $Node
            ArgumentList = ('"' + $scriptPath + '" serve')
            WorkingDirectory = $BaseDir
            PassThru = $true
            RedirectStandardOutput = $outputLog
            RedirectStandardError = $errorLog
        }
        if ([IO.Path]::DirectorySeparatorChar -eq '\') { $params.WindowStyle = 'Hidden' }
        $pathName = if ([IO.Path]::DirectorySeparatorChar -eq '\') { 'Path' } else { 'PATH' }
        $names = @('MCP_LOCAL_DIR', 'MCPKIT_CONTROL_KEY', 'MCPKIT_INSTANCE_ID', $pathName)
        $previous = @{}
        foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        try {
            [Environment]::SetEnvironmentVariable('MCP_LOCAL_DIR', $BaseDir, 'Process')
            [Environment]::SetEnvironmentVariable('MCPKIT_CONTROL_KEY', $controlKey, 'Process')
            [Environment]::SetEnvironmentVariable('MCPKIT_INSTANCE_ID', $instanceId, 'Process')
            $machinePath = [Environment]::GetEnvironmentVariable($pathName, 'Machine')
            $userPath = [Environment]::GetEnvironmentVariable($pathName, 'User')
            $envPath = @($previous[$pathName], $machinePath, $userPath) -join [IO.Path]::PathSeparator
            [Environment]::SetEnvironmentVariable($pathName, $envPath, 'Process')
            $child = Start-Process @params
        } finally {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
        }
        $state = [ordered]@{ pid = $child.Id; instanceId = $instanceId; controlKey = $controlKey; host = $settings.listenHost; port = $settings.port; tls = [bool]$settings.tlsCertFile; certPin = $certPin }
        try { Save-Json $StateFile $state }
        catch {
            # This handle is the child we just started, never a PID read from disk.
            try { $child.Kill() } catch { }
            throw
        }
        $status = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ([DateTime]::UtcNow -lt $deadline) {
            try { $status = Invoke-Control $state 'status'; break } catch { }
            if (-not (Test-ProcessAlive $child.Id)) { break }
            Start-Sleep -Milliseconds 300
        }
        if (-not $status) {
            if (-not (Test-ProcessAlive $child.Id)) { Remove-StateIfMatching $instanceId }
            throw 'Gateway did not start. Check logs gateway; no existing process was stopped.'
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(190)
        while (@($status.servers | Where-Object { $_.status -eq 'starting' }).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 750
            $status = Invoke-Control $state 'status'
        }
        $scheme = if ($settings.tlsCertFile) { 'https' } else { 'http' }
        Write-KitOk "Gateway listening on $scheme`://$($settings.listenHost):$($settings.port)"
        $counts = Show-Status $status
        if ($counts.error -or $counts.starting) { throw 'Some servers failed or are still starting. See the individual logs and rerun installation if packages are missing.' }
    } finally {
        $lock.Dispose()
        Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
    }
}
function Stop-Gateway {
    Write-KitHeader 'Stopping Windows gateway'
    $current = Get-RunningState
    if (-not $current) { Write-KitInfo 'Gateway is not running.'; return }
    $null = Invoke-Control $current.state 'stop'
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 250
        if (-not (Test-ProcessAlive $current.state.pid)) {
            Remove-StateIfMatching $current.state.instanceId
            Write-KitOk 'Gateway and its child servers stopped; data and configuration were kept.'
            return
        }
    }
    throw 'Shutdown was not confirmed. Inspect logs gateway; no unrelated process was killed.'
}
function Get-GatewayStatus {
    Write-KitHeader 'Windows gateway status'
    $current = Get-RunningState
    if (-not $current) { throw 'Gateway is not running.' }
    $counts = Show-Status $current.status
    if ($counts.error -or $counts.starting) { throw 'Some servers failed or are still starting.' }
}
function Show-Logs([string]$Name) {
    if ($Name -and $Name -ne 'gateway' -and $Name -notin @($Manifest.servers)) { throw 'Unknown log name.' }
    $files = @()
    if (-not $Name -or $Name -eq 'gateway') {
        $latest = Get-ChildItem -LiteralPath $Logs -Filter 'gateway-*.out.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($latest) {
            $files += $latest.FullName
            $files += ($latest.FullName -replace '\.out\.log$', '.err.log')
        }
        $files += (Join-Path $Logs 'gateway.log') # logs created by an earlier kit version
    }
    if ($Name -and $Name -ne 'gateway') { $files += (Join-Path $Logs "$Name.log") }
    if (-not $Name) { foreach ($id in $Manifest.servers) { $files += (Join-Path $Logs "$id.log") } }
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        Write-KitHeader "Logs: $(Split-Path -Leaf $file)"
        Get-Content -LiteralPath $file -Encoding UTF8 -Tail 100
    }
}

# The local Docker integration uses the same generated gateway key and
# settings, but never asks for a Linux host, SSH, a URL, TLS or VPN details.
. (Join-Path $ScriptDir 'metamcp-local.ps1')

function Start-LocalStack {
    $problems = New-Object 'System.Collections.Generic.List[string]'
    try { Start-Gateway } catch {
        $message = "Windows MCP gateway: $($_.Exception.Message)"
        Write-KitWarn $message
        $problems.Add($message)
    }
    # An individual native server may be broken while the gateway and the
    # others work. Still start MetaMCP and register all servers, then report
    # the partial failure rather than hiding it or leaving Docker unconfigured.
    try { Start-MetaMcp } catch {
        $message = "Local MetaMCP: $($_.Exception.Message)"
        Write-KitWarn $message
        $problems.Add($message)
    }
    if ($problems.Count -gt 0) { throw ($problems -join '; ') }
}
function Stop-LocalStack {
    $problems = New-Object 'System.Collections.Generic.List[string]'
    try { Stop-Gateway } catch { $problems.Add("Windows MCP gateway: $($_.Exception.Message)") }
    try { Stop-MetaMcp } catch { $problems.Add("Local MetaMCP: $($_.Exception.Message)") }
    if ($problems.Count -gt 0) { throw ($problems -join '; ') }
}
function Get-LocalStackStatus {
    $problems = New-Object 'System.Collections.Generic.List[string]'
    try { Get-GatewayStatus } catch { $problems.Add("Windows MCP gateway: $($_.Exception.Message)") }
    try { Show-MetaStatus } catch { $problems.Add("Local MetaMCP: $($_.Exception.Message)") }
    if ($problems.Count -gt 0) { throw ($problems -join '; ') }
}

try {
    if ($PSBoundParameters.ContainsKey('OwnerEmail') -and $Command -ne 'seed') { throw 'OwnerEmail is only accepted by the seed command.' }
    switch ($Command) {
        'init'      { Initialize-Configuration }
        'start'        { Start-LocalStack }
        'stop'         { Stop-LocalStack }
        'restart'      { Stop-LocalStack; Start-LocalStack }
        'status'       { Get-LocalStackStatus }
        'logs'         { if ($Server -eq 'metamcp') { Show-MetaLogs } else { Show-Logs $Server } }
        'credentials'  { Show-MetaCredentials }
        'seed'            { Repair-MetaSeed $OwnerEmail }
        'reset-metamcp-records' { Reset-MetaRecords }
        'enable-signup'   { Enable-MetaSignup }
        'ports'           { Show-MetaPorts }
        'set-ports'       {
            if (-not $PSBoundParameters.ContainsKey('WebPort') -or -not $PSBoundParameters.ContainsKey('BackendPort')) {
                throw 'Use set-ports -WebPort <port> -BackendPort <port-or-0>.'
            }
            Set-MetaPorts $WebPort $BackendPort
            Start-LocalStack
        }
        'gateway-start'   { Start-Gateway }
        'gateway-stop'    { Stop-Gateway }
        'gateway-restart' { Stop-Gateway; Start-Gateway }
        'gateway-status'  { Get-GatewayStatus }
    }
    exit 0
} catch {
    Write-KitError $_.Exception.Message
    exit 1
}
