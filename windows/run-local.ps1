#Requires -Version 5.1
<#
.SYNOPSIS
    Manage the native Windows LOCAL MCP gateway and its servers.
.EXAMPLE
    .\windows\run-local.ps1 start
    .\windows\run-local.ps1 status
    .\windows\run-local.ps1 logs obsidian
    .\windows\run-local.ps1 configure
    .\windows\run-local.ps1 register
#>
[CmdletBinding()]
param(
    # init is used by the installer; it never replaces existing settings.
    [ValidateSet('init', 'start', 'stop', 'restart', 'status', 'logs', 'configure', 'register', 'seed', 'export')]
    [string]$Command = 'start',
    [string]$Server = ''
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
        advertiseBaseUrl = ''
        metamcpOwnerEmail = ''
        linuxSshTarget = ''
        linuxKitDir = ''
    }
    $secrets = [ordered]@{
        gatewayApiKey = New-RandomHex 32
        obsidianApiKey = if ($legacy.OBSIDIAN_API_KEY) { $legacy.OBSIDIAN_API_KEY } else { '' }
        dbhubDsn = if ($legacy.DBHUB_DSN) { $legacy.DBHUB_DSN } else { '' }
    }
    $created = Save-Json $SettingsFile $settings -CreateOnly
    Write-Host "$(if ($created) { 'Created' } else { 'Preserved' }) $SettingsFile"
    $created = Save-Json $SecretsFile $secrets -CreateOnly
    Write-Host "$(if ($created) { 'Created' } else { 'Preserved' }) $SecretsFile"
    if (Test-Path -LiteralPath (Join-Path $ConfigDir 'mcp-local.json')) { Write-Host 'The legacy mcp-local.json and .env are not modified.' }
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
    foreach ($key in @('tlsCertFile', 'tlsKeyFile', 'advertiseBaseUrl', 'metamcpOwnerEmail', 'linuxSshTarget', 'linuxKitDir')) {
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
        Write-Host ('{0,-9} {1}{2}' -f $item.status, $item.id, $detail)
        if ($counts.ContainsKey([string]$item.status)) { $counts[[string]$item.status]++ }
    }
    Write-Host "Ready: $($counts.ready); waiting for configuration: $($counts.waiting); starting: $($counts.starting); errors: $($counts.error)."
    return $counts
}
function Start-Gateway {
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
            Write-Host 'Gateway is already running; settings are unchanged until restart.'
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
        Write-Host "Gateway listening on $scheme`://$($settings.listenHost):$($settings.port)"
        $counts = Show-Status $status
        if ($counts.error -or $counts.starting) { throw 'Some servers failed or are still starting. See the individual logs and rerun installation if packages are missing.' }
    } finally {
        $lock.Dispose()
        Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
    }
}
function Stop-Gateway {
    $current = Get-RunningState
    if (-not $current) { Write-Host 'Gateway is not running.'; return }
    $null = Invoke-Control $current.state 'stop'
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 250
        if (-not (Test-ProcessAlive $current.state.pid)) {
            Remove-StateIfMatching $current.state.instanceId
            Write-Host 'Gateway and its child servers stopped; data and configuration were kept.'
            return
        }
    }
    throw 'Shutdown was not confirmed. Inspect logs gateway; no unrelated process was killed.'
}
function Get-GatewayStatus {
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
        Write-Host "`n=== $(Split-Path -Leaf $file) ==="
        Get-Content -LiteralPath $file -Encoding UTF8 -Tail 100
    }
}

function Get-RegistrationData($Settings, $Secrets) {
    $email = $Settings.metamcpOwnerEmail.Trim()
    if ($email.Length -gt 320 -or $email -notmatch '^[^\s@]+@[^\s@]+$') { throw 'Set metamcpOwnerEmail to an existing MetaMCP account email.' }
    $rawUrl = $Settings.advertiseBaseUrl
    $uri = $null
    if (-not [Uri]::TryCreate($rawUrl, [UriKind]::Absolute, [ref]$uri)) { throw 'Set advertiseBaseUrl to the gateway URL reachable from MetaMCP.' }
    if ($rawUrl -notmatch '^https?://[a-zA-Z0-9.-]+(?::[0-9]+)?(?:/[a-zA-Z0-9._~/-]*)?$' -or $rawUrl.Contains('..')) {
        throw 'advertiseBaseUrl must be an HTTP(S) URL without credentials, query, fragment, IPv6, or unsafe path characters.'
    }
    if ($uri.Scheme -eq 'http' -and $uri.Host.ToLowerInvariant() -notin @('localhost', '127.0.0.1') -and -not $Settings.allowInsecureLan) {
        throw 'Refusing plaintext HTTP to a non-loopback address. Use HTTPS or explicitly permit HTTP inside a protected tunnel/VPN.'
    }
    return [ordered]@{ version = 1; hostId = $Settings.hostId; ownerEmail = $email; baseUrl = $uri.AbsoluteUri.TrimEnd('/'); gatewayKey = $Secrets.gatewayApiKey; allowInsecureLan = $Settings.allowInsecureLan }
}
function Configure-Gateway {
    if ([Console]::IsInputRedirected) { throw 'configure requires an interactive terminal; edit config/local-settings.json instead.' }
    $config = Get-Configuration
    $settings = $config.settings
    Write-Host 'For a VPN, bind to this Windows machine VPN IP. For a local tunnel or TLS reverse proxy, keep 127.0.0.1.'
    $questions = @(
        @('Windows gateway listen address', 'listenHost', $false),
        @('Gateway base URL reachable from the Linux MetaMCP container', 'advertiseBaseUrl', $false),
        @('TLS certificate PEM path (empty for tunnel/VPN; - clears)', 'tlsCertFile', $true),
        @('TLS private key PEM path (empty for tunnel/VPN; - clears)', 'tlsKeyFile', $true),
        @('MetaMCP account email (the endpoint will be private)', 'metamcpOwnerEmail', $false),
        @('Linux SSH destination, for example user@host', 'linuxSshTarget', $false),
        @('Absolute path to this repository on the Linux host', 'linuxKitDir', $false)
    )
    foreach ($question in $questions) {
        $label, $key, $clearable = $question
        $prompt = if ($settings.$key) { "$label [$($settings.$key)]" } else { $label }
        $value = (Read-Host $prompt).Trim()
        if ($clearable -and $value -eq '-') { $settings.$key = '' }
        elseif ($value) { $settings.$key = $value }
    }
    $localBind = $settings.listenHost.ToLowerInvariant() -in @('127.0.0.1', '::1', 'localhost')
    $uri = $null
    $hasUrl = [Uri]::TryCreate($settings.advertiseBaseUrl, [UriKind]::Absolute, [ref]$uri)
    $nonlocalHttp = $hasUrl -and $uri.Scheme -eq 'http' -and $uri.Host.ToLowerInvariant() -notin @('127.0.0.1', 'localhost')
    if (((-not $localBind -and -not $settings.tlsCertFile) -or $nonlocalHttp) -and -not $settings.allowInsecureLan) {
        $settings.allowInsecureLan = (Read-Host 'Allow plaintext HTTP ONLY inside a trusted encrypted VPN/tunnel? Type YES to allow') -ceq 'YES'
    }
    Test-Settings $settings $config.secrets
    $data = Get-RegistrationData $settings $config.secrets
    Save-Json $SettingsFile $settings
    if ($data.baseUrl -match '^http://(localhost|127\.0\.0\.1)(:|/|$)') { Write-Host 'WARNING: localhost refers to the MetaMCP container itself. Use it only if your tunnel terminates inside that container.' }
    if ($localBind -and $data.baseUrl -notmatch '^https?://(localhost|127\.0\.0\.1)(:|/|$)') { Write-Host 'The listener is loopback-only: ensure your tunnel or reverse proxy forwards the advertised address to it.' }
    Write-Host "Saved $SettingsFile. Restart the gateway to apply changes, then run register."
}
function Quote-NativeArgument([string]$Value) {
    # The Windows C runtime parses backslashes before quotes specially.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}
function Register-Gateway([bool]$Force, [bool]$ExportOnly) {
    $config = Get-Configuration
    $settings = $config.settings
    $data = Get-RegistrationData $settings $config.secrets
    if ($ExportOnly) {
        $file = Join-Path $PrivateDir 'registration.json'
        Save-Json $file $data
        Write-Host "Wrote $file. It contains a secret: transfer it securely and remove the copy after registration."
        return
    }
    if ($settings.linuxSshTarget -notmatch '^(?:[a-zA-Z0-9._-]+@)?[a-zA-Z0-9.-]+$') { throw 'Set linuxSshTarget to an SSH user and hostname.' }
    if (-not $settings.linuxKitDir.StartsWith('/') -or $settings.linuxKitDir -match '[\r\n\x00]') { throw 'Set linuxKitDir to the absolute path of this repository on Linux.' }
    $ssh = Get-Command 'ssh.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ssh) { $ssh = Get-Command 'ssh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $ssh) { throw 'Windows OpenSSH client was not found in PATH.' }
    $remotePath = $settings.linuxKitDir.TrimEnd('/') + '/linux/register-local.sh'
    $shellQuoted = "'" + $remotePath.Replace("'", "'\''") + "'"
    $remote = "bash $shellQuoted --stdin"
    if ($Force) { $remote += ' --force' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $ssh.Source
    $start.Arguments = '-- ' + (Quote-NativeArgument $settings.linuxSshTarget) + ' ' + (Quote-NativeArgument $remote)
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $child = New-Object Diagnostics.Process
    $child.StartInfo = $start
    Write-Host 'Registering private Windows servers through SSH. The gateway key is sent on stdin, not in the command line.'
    try {
        if (-not $child.Start()) { throw 'Could not start SSH.' }
        $writer = New-Object IO.StreamWriter($child.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
        try { $writer.WriteLine((ConvertTo-Json -InputObject $data -Depth 10 -Compress)) } finally { $writer.Dispose() }
        $child.WaitForExit()
        if ($child.ExitCode -ne 0) { throw "SSH registration failed (exit $($child.ExitCode)). Existing MetaMCP settings were not overwritten." }
    } finally { $child.Dispose() }
}

try {
    switch ($Command) {
        'init'      { Initialize-Configuration }
        'start'     { Start-Gateway }
        'stop'      { Stop-Gateway }
        'restart'   { Stop-Gateway; Start-Gateway }
        'status'    { Get-GatewayStatus }
        'logs'      { Show-Logs $Server }
        'configure' { Configure-Gateway }
        'register'  { Register-Gateway $false $false }
        'seed'      { Register-Gateway $true $false }
        'export'    { Register-Gateway $false $true }
    }
    exit 0
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
