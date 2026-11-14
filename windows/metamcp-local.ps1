# Local Docker Desktop integration. Dot-sourced by run-local.ps1 after its
# configuration and gateway functions are defined; Windows PowerShell 5.1.
$MetaStateFile = Join-Path $PrivateDir 'metamcp-state.json'
$MetaEnvFile = Join-Path $PrivateDir 'metamcp.env'
$MetaOverride = Join-Path $ScriptDir 'metamcp.local.yml'
$MetaBackendOverride = Join-Path $ScriptDir 'metamcp-backend.local.yml'

function Quote-NativeArgument([string]$Value) {
    # Windows C runtime quoting, also usable for ProcessStartInfo on POSIX.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}
function Find-Docker {
    $command = Get-Command 'docker.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    if ($env:ProgramFiles) {
        $standard = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'
        if (Test-Path -LiteralPath $standard -PathType Leaf) { return $standard }
    }
    # The fallback is useful for non-Windows protocol tests; on Windows the
    # Docker Desktop CLI is docker.exe, not a shell script.
    if ([IO.Path]::DirectorySeparatorChar -ne '\') {
        $command = Get-Command 'docker' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }
    return $null
}
function Find-Desktop {
    if ($env:ProgramFiles) {
        $standard = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
        if (Test-Path -LiteralPath $standard -PathType Leaf) { return $standard }
    }
    $command = Get-Command 'Docker Desktop.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}
function Invoke-KitProcess {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$InputText = '',
        [int]$TimeoutSeconds = 60,
        [hashtable]$ExtraEnvironment = @{}
    )
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.Arguments = (@($Arguments | ForEach-Object { Quote-NativeArgument ([string]$_) }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    # Compose gives shell variables precedence over --env-file. Never let a
    # caller's unrelated DB, Compose, Docker context, or bootstrap settings
    # redirect this dedicated local project or change its credentials.
    foreach ($name in @($start.EnvironmentVariables.Keys)) {
        $upper = $name.ToUpperInvariant()
        if ($upper -match '^(COMPOSE_|POSTGRES_|BOOTSTRAP_|MCPKIT_|METAMCP_)' -or
            $upper -in @('DATABASE_URL', 'APP_URL', 'NEXT_PUBLIC_APP_URL', 'BETTER_AUTH_SECRET',
                'TRANSFORM_LOCALHOST_TO_DOCKER_INTERNAL', 'DOCKER_HOST', 'DOCKER_CONTEXT',
                'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH', 'DOCKER_API_VERSION',
                'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES')) {
            $start.EnvironmentVariables.Remove($name)
        }
    }
    $start.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    foreach ($name in $ExtraEnvironment.Keys) { $start.EnvironmentVariables[$name] = [string]$ExtraEnvironment[$name] }
    $child = New-Object Diagnostics.Process
    $child.StartInfo = $start
    try {
        if (-not $child.Start()) { throw "Could not start $(Split-Path -Leaf $Executable)." }
        # Drain both pipes concurrently, including during builds, to avoid a
        # full stderr pipe deadlocking the child. Never print config/SQL input.
        $outTask = $child.StandardOutput.ReadToEndAsync()
        $errTask = $child.StandardError.ReadToEndAsync()
        $writer = New-Object IO.StreamWriter($child.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
        try { if ($InputText) { $writer.Write($InputText) } } finally { $writer.Dispose() }
        if (-not $child.WaitForExit($TimeoutSeconds * 1000)) {
            try { $child.Kill() } catch { }
            throw "$(Split-Path -Leaf $Executable) timed out after $TimeoutSeconds seconds. No Docker resources were removed."
        }
        $output = $outTask.GetAwaiter().GetResult()
        $errors = $errTask.GetAwaiter().GetResult()
        return [pscustomobject]@{ code = $child.ExitCode; stdout = $output; stderr = $errors }
    } finally { $child.Dispose() }
}
function Invoke-Docker([string[]]$DockerArguments, [string]$InputText = '', [int]$TimeoutSeconds = 60, [hashtable]$ExtraEnvironment = @{}) {
    $docker = Find-Docker
    if (-not $docker) { throw 'Docker Desktop CLI was not found. Run install-local.ps1, then start Docker Desktop.' }
    return Invoke-KitProcess $docker $DockerArguments $InputText $TimeoutSeconds $ExtraEnvironment
}
function Assert-DockerResult($Result, [string]$Action, [bool]$ShowDetails = $true) {
    if ($Result.code -eq 0) { return }
    $details = ''
    if ($ShowDetails -and $Result.stderr) {
        $text = $Result.stderr.Trim()
        if ($text.Length -gt 2000) { $text = $text.Substring($text.Length - 2000) }
        $details = ": $text"
    }
    throw "Docker $Action failed (exit $($Result.code))$details"
}
function Ensure-DesktopDocker([switch]$NoStart) {
    if (-not (Find-Docker)) { throw 'Docker Desktop is not installed or its CLI is not available. Run install-local.ps1.' }
    $timeout = 120
    if ($env:MCPKIT_DOCKER_START_TIMEOUT -match '^\d{1,3}$') { $timeout = [Math]::Max(1, [Math]::Min(600, [int]$env:MCPKIT_DOCKER_START_TIMEOUT)) }
    $deadline = [DateTime]::UtcNow.AddSeconds($timeout)
    $startedDesktop = $false
    do {
        $context = Invoke-Docker @('context', 'inspect', 'desktop-linux', '--format', '{{.Endpoints.docker.Host}}')
        if ($context.code -eq 0) {
            # An explicitly named local Desktop context is mandatory. Do not
            # use the user's current context or DOCKER_HOST, which may be a
            # remote Linux machine or someone else's Docker daemon.
            if ($context.stdout.Trim() -notmatch '^npipe:////[.]/pipe/dockerDesktopLinuxEngine$') {
                throw 'The desktop-linux Docker context does not point to the local Docker Desktop named pipe. It was not used or modified.'
            }
            $info = Invoke-Docker @('--context', 'desktop-linux', 'info', '--format', '{{.OperatingSystem}}|{{.OSType}}')
            if ($info.code -eq 0) {
                if ($info.stdout.Trim() -ne 'Docker Desktop|linux') { throw 'Docker Desktop must be using Linux containers on this Windows machine.' }
                $version = Invoke-Docker @('--context', 'desktop-linux', 'compose', 'version', '--short')
                Assert-DockerResult $version 'Compose version check'
                $match = [regex]::Match($version.stdout, '\d+\.\d+\.\d+')
                if (-not $match.Success -or [version]$match.Value -lt [version]$Manifest.metamcp.composeMinimum) {
                    throw "Docker Compose $($Manifest.metamcp.composeMinimum) or newer is required. Update Docker Desktop."
                }
                return
            }
        }
        if ($NoStart) { throw 'Docker Desktop is unavailable; the kit containers could not be checked or stopped. No other context was used.' }
        if (-not $startedDesktop) {
            $desktop = Find-Desktop
            if ($desktop -and -not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
                Write-KitInfo 'Starting Docker Desktop; complete its first-run/WSL setup if prompted.'
                Start-Process -FilePath $desktop | Out-Null
            } else { Write-KitInfo 'Waiting for Docker Desktop and its local Linux engine...' }
            $startedDesktop = $true
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Docker Desktop Linux engine did not become ready. Start Docker Desktop, complete any setup/reboot, then retry. No remote Docker context was used.'
}
function Write-CreateOnlyText([string]$File, [string]$Text) {
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
    $stream = [IO.File]::Open($File, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
}
function Test-MetaEmail([string]$Email) {
    # Email is a selector, never SQL source or a shell command. Commas delimit
    # the upstream administrator list; exclude controls and line separators.
    return ($Email.Length -ge 3 -and $Email.Length -le 320 -and $Email -cmatch '^[^@\s,|]+@[^@\s,|]+$')
}
function Get-MetaState {
    if (-not (Test-Path -LiteralPath $MetaStateFile -PathType Leaf)) { return $null }
    $state = Read-Json $MetaStateFile
    if ($state.version -ne 1 -or $state.instanceId -cnotmatch '^[a-f0-9]{16}$' -or
        $state.project -cne ('mcpkit-win-' + $state.instanceId) -or
        $state.ownerEmail -isnot [string] -or ($state.ownerEmail -and -not (Test-MetaEmail $state.ownerEmail)) -or
        ($state.port -isnot [int] -and $state.port -isnot [long]) -or $state.port -lt 1 -or $state.port -gt 65535 -or
        $state.envCreated -isnot [bool]) { throw "Invalid MetaMCP state; existing files were not changed: $MetaStateFile" }
    # Legacy instances need one app-only recreation to stop upstream bootstrap
    # from reopening signup on every restart. Do not alter their saved ports.
    if (-not $state.PSObject.Properties['backendPort']) { $state | Add-Member -NotePropertyName backendPort -NotePropertyValue 0 }
    if (-not $state.PSObject.Properties['portsPending']) { $state | Add-Member -NotePropertyName portsPending -NotePropertyValue $false }
    if (-not $state.PSObject.Properties['appImage']) { $state | Add-Member -NotePropertyName appImage -NotePropertyValue '' }
    if (-not $state.PSObject.Properties['manualAuthApplied']) { $state | Add-Member -NotePropertyName manualAuthApplied -NotePropertyValue $false }
    if (-not $state.PSObject.Properties['authPending']) { $state | Add-Member -NotePropertyName authPending -NotePropertyValue $false }
    if (-not $state.PSObject.Properties['additionalAdminEmails']) { $state | Add-Member -NotePropertyName additionalAdminEmails -NotePropertyValue @() }
    if (($state.backendPort -isnot [int] -and $state.backendPort -isnot [long]) -or
        $state.backendPort -lt 0 -or $state.backendPort -gt 65535 -or
        ($state.backendPort -ne 0 -and $state.backendPort -eq $state.port) -or
        $state.portsPending -isnot [bool] -or $state.appImage -isnot [string] -or
        $state.manualAuthApplied -isnot [bool] -or $state.authPending -isnot [bool] -or
        $state.additionalAdminEmails -isnot [array]) {
        throw "Invalid MetaMCP state; existing files were not changed: $MetaStateFile"
    }
    foreach ($email in $state.additionalAdminEmails) {
        if ($email -isnot [string] -or -not (Test-MetaEmail $email)) { throw 'Invalid MetaMCP administrator email in local state.' }
    }
    $imagePattern = '^' + [regex]::Escape($state.project) + '-app-backup:[0-9]{14}-[a-f0-9]{8}$'
    if ($state.appImage -and $state.appImage -cnotmatch $imagePattern) {
        throw 'Unexpected MetaMCP app image in local state; existing files were not changed.'
    }
    $first = [IO.Path]::GetFullPath((Join-Path $BaseDir 'metamcp'))
    $second = [IO.Path]::GetFullPath((Join-Path $BaseDir ('metamcp-kit-' + $state.instanceId)))
    if (-not $state.cloneDir -or -not [IO.Path]::IsPathRooted($state.cloneDir)) { throw 'Invalid MetaMCP clone path in local state.' }
    $actual = [IO.Path]::GetFullPath($state.cloneDir)
    if ($actual -ine $first -and $actual -ine $second) { throw 'The MetaMCP clone path in local state is outside the expected kit directories.' }
    return $state
}
function Initialize-MetaState {
    $state = Get-MetaState
    if (-not $state) {
        if (Test-Path -LiteralPath $MetaEnvFile) { throw "An existing MetaMCP env file has no matching kit state. It was preserved: $MetaEnvFile" }
        $id = New-RandomHex 8
        # These defaults and environment overrides apply only to a new instance.
        # Use set-ports for an existing instance; do not rewrite its secrets.
        $port = [int]$Manifest.metamcp.frontendPort
        $backendPort = [int]$Manifest.metamcp.backendPort
        if ($env:MCPKIT_METAMCP_PORT) {
            if ($env:MCPKIT_METAMCP_PORT -notmatch '^\d{1,5}$' -or [int]$env:MCPKIT_METAMCP_PORT -lt 1 -or [int]$env:MCPKIT_METAMCP_PORT -gt 65535) {
                throw 'MCPKIT_METAMCP_PORT must be a port between 1 and 65535.'
            }
            $port = [int]$env:MCPKIT_METAMCP_PORT
        }
        if ($env:MCPKIT_METAMCP_BACKEND_PORT) {
            if ($env:MCPKIT_METAMCP_BACKEND_PORT -notmatch '^\d{1,5}$' -or [int]$env:MCPKIT_METAMCP_BACKEND_PORT -gt 65535) {
                throw 'MCPKIT_METAMCP_BACKEND_PORT must be between 1 and 65535, or 0 to keep the backend unpublished.'
            }
            $backendPort = [int]$env:MCPKIT_METAMCP_BACKEND_PORT
        }
        if ($port -lt 1 -or $port -gt 65535 -or $backendPort -lt 0 -or $backendPort -gt 65535 -or
            ($backendPort -ne 0 -and $backendPort -eq $port)) { throw 'Invalid or duplicate MetaMCP frontend/backend ports.' }
        $gatewayPort = (Get-Configuration).settings.port
        if ($port -eq $gatewayPort -or ($backendPort -ne 0 -and $backendPort -eq $gatewayPort)) {
            throw 'MetaMCP ports must differ from the Windows gateway port in config/local-settings.json.'
        }
        $clone = Join-Path $BaseDir 'metamcp'
        if (Test-Path -LiteralPath $clone) {
            $clone = Join-Path $BaseDir ('metamcp-kit-' + $id)
            if (Test-Path -LiteralPath $clone) { throw "The alternate MetaMCP clone path already exists; it was not modified: $clone" }
            Write-KitInfo "An existing metamcp directory was preserved; the kit will use $clone instead."
        }
        $candidate = [ordered]@{ version = 1; instanceId = $id; project = 'mcpkit-win-' + $id; port = $port;
            backendPort = $backendPort; portsPending = $false; appImage = '';
            manualAuthApplied = $true; authPending = $false; additionalAdminEmails = @();
            ownerEmail = ''; cloneDir = [IO.Path]::GetFullPath($clone); envCreated = $false }
        $null = Save-Json $MetaStateFile $candidate -CreateOnly
        $state = Get-MetaState
    }
    if (-not (Test-Path -LiteralPath $MetaEnvFile -PathType Leaf)) {
        if ($state.envCreated) { throw "The existing MetaMCP env file is missing. Restore it from backup; credentials were not regenerated: $MetaEnvFile" }
        $pgPassword = New-RandomHex 32
        $authSecret = New-RandomHex 32
        $image = $state.project + '-metamcp:' + $Manifest.metamcp.revision.Substring(0, 12)
        $lines = @(
            'NODE_ENV=production', 'LOG_LEVEL=errors-only',
            'POSTGRES_HOST=postgres', 'POSTGRES_PORT=5432', 'POSTGRES_USER=metamcp_user',
            "POSTGRES_PASSWORD=$pgPassword", 'POSTGRES_DB=metamcp_db',
            "APP_URL=http://localhost:$($state.port)", "BETTER_AUTH_SECRET=$authSecret",
            'TRANSFORM_LOCALHOST_TO_DOCKER_INTERNAL=false', 'BOOTSTRAP_ENABLE=false',
            "MCPKIT_INSTANCE=$($state.instanceId)", "MCPKIT_PROJECT=$($state.project)",
            "MCPKIT_METAMCP_PORT=$($state.port)", "MCPKIT_METAMCP_BACKEND_PORT=$($state.backendPort)", "MCPKIT_IMAGE=$image"
        )
        # CreateNew avoids ever replacing a user's existing secrets, including
        # if another installation races this one.
        Write-CreateOnlyText $MetaEnvFile (($lines -join "`n") + "`n")
    }
    if (-not $state.envCreated) {
        $state.envCreated = $true
        $null = Save-Json $MetaStateFile $state
    }
    return $state
}
function Read-MetaEnv {
    if (-not (Test-Path -LiteralPath $MetaEnvFile -PathType Leaf)) { throw "MetaMCP credentials are missing; restore $MetaEnvFile from backup." }
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($MetaEnvFile, [Text.Encoding]::UTF8)) {
        $match = [regex]::Match($line, '^([A-Z][A-Z0-9_]*)=(.*)$')
        if (-not $match.Success) { continue }
        $name = $match.Groups[1].Value
        if ($values.ContainsKey($name)) { throw "Duplicate $name in the existing MetaMCP env file; it was not modified." }
        $values[$name] = $match.Groups[2].Value
    }
    return $values
}
function Get-MetaAdminEmails($State) {
    # Preserve any legacy administrator allowlist. New installations have no
    # allowlist until an administrator is selected explicitly; upstream then
    # treats all signed-in users as administrators (single-user mode).
    $values = Read-MetaEnv
    $sources = @()
    if ($values.METAMCP_ADMIN_EMAILS) { $sources += @(([string]$values.METAMCP_ADMIN_EMAILS).Split(',')) }
    $sources += @($State.additionalAdminEmails)
    $emails = @()
    foreach ($source in $sources) {
        $email = ([string]$source).Trim()
        if (-not $email) { continue }
        if (-not (Test-MetaEmail $email)) { throw 'Invalid MetaMCP administrator allowlist; existing configuration was not changed.' }
        if (@($emails | Where-Object { $_ -ieq $email }).Count -eq 0) { $emails += $email }
    }
    return ($emails -join ',')
}
function Get-MetaImage($State) {
    if ($State.appImage) { return [string]$State.appImage }
    return ($State.project + '-metamcp:' + $Manifest.metamcp.revision.Substring(0, 12))
}
function Get-ComposeArguments($State, [string[]]$Subcommand) {
    $arguments = @('--context', 'desktop-linux', 'compose', '--project-name', $State.project,
        '--project-directory', $State.cloneDir, '--env-file', $MetaEnvFile,
        '-f', (Join-Path $State.cloneDir 'docker-compose.yml'), '-f', $MetaOverride)
    if ($State.backendPort -gt 0) { $arguments += @('-f', $MetaBackendOverride) }
    return $arguments + $Subcommand
}
function Invoke-Compose($State, [string[]]$Subcommand, [int]$TimeoutSeconds = 60) {
    # State is the authoritative source for ports. Shell interpolation takes
    # precedence over old values in the private env file, so credentials and
    # the original file remain byte-for-byte intact when ports are changed.
    $envs = @{
        MCPKIT_ENV_FILE = $MetaEnvFile
        MCPKIT_METAMCP_PORT = [string]$State.port
        MCPKIT_METAMCP_BACKEND_PORT = [string]$State.backendPort
        MCPKIT_METAMCP_ADMIN_EMAILS = (Get-MetaAdminEmails $State)
        MCPKIT_IMAGE = (Get-MetaImage $State)
        APP_URL = 'http://localhost:' + $State.port
    }
    return Invoke-Docker (Get-ComposeArguments $State $Subcommand) '' $TimeoutSeconds $envs
}
function Invoke-Git([string[]]$GitArguments, [int]$TimeoutSeconds = 300) {
    $git = Get-Command 'git.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git -and [IO.Path]::DirectorySeparatorChar -ne '\') { $git = Get-Command 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $git) { throw 'Git is required to clone MetaMCP. Run install-local.ps1.' }
    $result = Invoke-KitProcess $git.Source $GitArguments '' $TimeoutSeconds
    if ($result.code -ne 0) { throw "Git failed (exit $($result.code)): $($result.stderr.Trim())" }
    return $result.stdout.Trim()
}
function Assert-MetaClone($State) {
    $marker = Join-Path $State.cloneDir '.git\mcpkit-instance'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or ([IO.File]::ReadAllText($marker)).Trim() -cne $State.instanceId) {
        throw "The MetaMCP clone is missing or is not owned by this kit; existing files were not changed: $($State.cloneDir)"
    }
}
function Ensure-MetaClone($State) {
    if (Test-Path -LiteralPath $State.cloneDir) { Assert-MetaClone $State; return }
    # Clone to a new private temporary directory, then atomically move it into
    # place. A failed clone is the only directory this function ever removes.
    $scratch = Join-Path $PrivateDir ('metamcp-clone-' + (New-RandomHex 8))
    if (Test-Path -LiteralPath $scratch) { throw "Temporary clone path already exists: $scratch" }
    try {
        Write-KitInfo 'Cloning the official MetaMCP repository...'
        $null = Invoke-Git @('clone', '--no-checkout', '--depth', '1', $Manifest.metamcp.repository, $scratch) 600
        $null = Invoke-Git @('-C', $scratch, 'fetch', '--depth', '1', 'origin', $Manifest.metamcp.revision) 600
        $null = Invoke-Git @('-C', $scratch, 'checkout', '--detach', $Manifest.metamcp.revision) 300
        if ((Invoke-Git @('-C', $scratch, 'rev-parse', 'HEAD')) -cne $Manifest.metamcp.revision) { throw 'The cloned MetaMCP revision did not match the requested version.' }
        Write-CreateOnlyText (Join-Path $scratch '.git\mcpkit-instance') ($State.instanceId + "`n")
        [IO.Directory]::Move($scratch, $State.cloneDir)
        Protect-PrivateDirectory $State.cloneDir
    } finally {
        if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
function Test-MetaCompose($State) {
    $result = Invoke-Compose $State @('config', '--format', 'json') 120
    # The resolved config contains secrets. Never put it in logs or errors.
    Assert-DockerResult $result 'Compose configuration' $false
    try { $config = $result.stdout | ConvertFrom-Json } catch { throw 'Docker Compose did not return a valid local project configuration.' }
    $app = $config.services.app
    $pg = $config.services.postgres
    $serviceNames = @($config.services.PSObject.Properties.Name | Sort-Object)
    if (($serviceNames -join ',') -cne 'app,postgres' -or -not $app -or -not $pg) { throw 'Unexpected MetaMCP Compose services; no containers were started.' }
    $expectedImage = Get-MetaImage $State
    if ($app.image -cne $expectedImage -or $app.container_name -cne ($State.project + '-app') -or
        $pg.image -cne 'postgres:16-alpine' -or $pg.container_name -cne ($State.project + '-postgres')) { throw 'Unexpected local Docker images or container names; no containers were started.' }
    if (-not $app.build -or -not $app.build.context -or [IO.Path]::GetFullPath([string]$app.build.context) -ine [IO.Path]::GetFullPath($State.cloneDir) -or
        $app.build.dockerfile -ne 'Dockerfile') { throw 'Unexpected MetaMCP build context; no image was built.' }
    $ports = @($app.ports | Where-Object { $_ })
    $frontend = @($ports | Where-Object { $_.host_ip -ceq '127.0.0.1' -and [string]$_.published -ceq [string]$State.port -and [int]$_.target -eq 12008 -and $_.protocol -ceq 'tcp' })
    $backend = @($ports | Where-Object { $_.host_ip -ceq '127.0.0.1' -and [string]$_.published -ceq [string]$State.backendPort -and [int]$_.target -eq 12009 -and $_.protocol -ceq 'tcp' })
    $expectedCount = if ($State.backendPort -gt 0) { 2 } else { 1 }
    if ($ports.Count -ne $expectedCount -or $frontend.Count -ne 1 -or
        ($State.backendPort -gt 0 -and $backend.Count -ne 1) -or ($pg.ports -and @($pg.ports).Count -gt 0)) {
        throw 'Unsafe published ports in MetaMCP Compose configuration; no containers were started.'
    }
    if ($app.extra_hosts -and @($app.extra_hosts).Count -gt 0) { throw 'Unexpected host aliases in MetaMCP Compose; no containers were started.' }
    foreach ($service in @($app, $pg)) {
        if ($service.privileged -or $service.network_mode -or $service.pid -or $service.ipc -or $service.devices -or $service.cap_add -or $service.volumes_from) {
            throw 'Unexpected privileged, host-networked, or device configuration; no containers were started.'
        }
        if ($service.labels.'com.multfinite.mcpkit.instance' -cne $State.instanceId) { throw 'Missing local project ownership label.' }
        foreach ($volume in @($service.volumes)) {
            if ($volume -and $volume.type -cne 'volume') { throw 'Unexpected host bind mount in MetaMCP Compose; no containers were started.' }
        }
    }
    $envs = $app.environment
    $pgEnv = $pg.environment
    $dbPassword = [string]$envs.POSTGRES_PASSWORD
    $expectedDb = 'postgresql://metamcp_user:' + $dbPassword + '@postgres:5432/metamcp_db'
    if ($envs.POSTGRES_HOST -cne 'postgres' -or [string]$envs.POSTGRES_PORT -cne '5432' -or
        $envs.POSTGRES_USER -cne 'metamcp_user' -or $envs.POSTGRES_DB -cne 'metamcp_db' -or $dbPassword -cnotmatch '^[a-f0-9]{64}$' -or
        $envs.DATABASE_URL -cne $expectedDb -or $pgEnv.POSTGRES_PASSWORD -cne $dbPassword -or
        $pgEnv.POSTGRES_USER -cne 'metamcp_user' -or $pgEnv.POSTGRES_DB -cne 'metamcp_db') { throw 'MetaMCP database must use its dedicated local PostgreSQL service; existing configuration was not changed.' }
    if ($envs.APP_URL -cne ('http://localhost:' + $State.port) -or $envs.NEXT_PUBLIC_APP_URL -cne $envs.APP_URL -or
        $envs.BETTER_AUTH_SECRET -cnotmatch '^[a-f0-9]{64}$' -or $envs.BOOTSTRAP_ENABLE -cne 'false' -or
        $envs.BOOTSTRAP_RECREATE_USER -cne 'false' -or $envs.BOOTSTRAP_DELETE_OTHER_USERS -cne 'false' -or
        [string]$envs.METAMCP_ADMIN_EMAILS -cne (Get-MetaAdminEmails $State)) {
        throw 'Unexpected local MetaMCP authentication or bootstrap settings; existing credentials were not changed.'
    }
    foreach ($name in @('BOOTSTRAP_USER_NAME', 'BOOTSTRAP_USER_EMAIL', 'BOOTSTRAP_USER_PASSWORD',
            'BOOTSTRAP_USERS', 'BOOTSTRAP_API_KEYS', 'BOOTSTRAP_NAMESPACES', 'BOOTSTRAP_ENDPOINTS')) {
        if ($envs.$name) { throw "Unexpected $name in local MetaMCP config; it was not changed." }
    }
}
function Test-OwnedDockerObject([string]$Kind, [string]$Name, $State) {
    $template = if ($Kind -in @('container', 'image')) { '{{json .Config.Labels}}' } else { '{{json .Labels}}' }
    $result = Invoke-Docker @('--context', 'desktop-linux', $Kind, 'inspect', '--format', $template, $Name)
    if ($result.code -ne 0) {
        if ($result.stderr -match '(?i)(no such (container|object|volume|network|image)|not found)') { return $false }
        Assert-DockerResult $result "$Kind inspection"
    }
    try { $labels = $result.stdout | ConvertFrom-Json } catch { throw "Cannot inspect ownership of existing Docker $Kind $Name." }
    if (-not $labels -or $labels.'com.multfinite.mcpkit.instance' -cne $State.instanceId) {
        throw "Docker $Kind $Name already exists but is not owned by this kit. It was not changed."
    }
    if ($Kind -ne 'image' -and $labels.'com.docker.compose.project' -cne $State.project) {
        throw "Docker $Kind $Name belongs to a different Compose project. It was not changed."
    }
    return $true
}
function Test-MetaResources($State) {
    $allowed = @(($State.project + '-app'), ($State.project + '-postgres'))
    $listing = Invoke-Docker @('--context', 'desktop-linux', 'container', 'ls', '-a', '--filter', ('label=com.docker.compose.project=' + $State.project), '--format', '{{.Names}}')
    Assert-DockerResult $listing 'project inspection'
    foreach ($name in @($listing.stdout -split '\r?\n' | Where-Object { $_ })) {
        if ($name -cnotin $allowed) { throw "A different container already uses this Compose project ($name). It was not changed." }
    }
    foreach ($name in $allowed) { $null = Test-OwnedDockerObject 'container' $name $State }
    foreach ($name in @(($State.project + '_postgres_data'), ($State.project + '_uv_cache'))) { $null = Test-OwnedDockerObject 'volume' $name $State }
    $null = Test-OwnedDockerObject 'network' ($State.project + '_metamcp-network') $State
}
function Ensure-MetaImage($State) {
    $image = Get-MetaImage $State
    if (Test-OwnedDockerObject 'image' $image $State) { return }
    if ($State.appImage) {
        throw "The preserved MetaMCP app image is missing; restore it before starting: $image"
    }
    # Do not send a modified or untracked user file to the Docker build context.
    if ((Invoke-Git @('-C', $State.cloneDir, 'rev-parse', 'HEAD')) -cne $Manifest.metamcp.revision -or
        (Invoke-Git @('-C', $State.cloneDir, 'status', '--porcelain', '--ignored', '--untracked-files=all'))) {
        throw "The MetaMCP clone has user changes or extra files. Nothing was built or removed: $($State.cloneDir)"
    }
    Write-KitInfo 'Building the cloned MetaMCP image (first run can take several minutes and download dependencies)...'
    $build = Invoke-Compose $State @('build', 'app') 3600
    Assert-DockerResult $build 'MetaMCP image build'
    if (-not (Test-OwnedDockerObject 'image' $image $State)) { throw 'The expected local MetaMCP image was not created.' }
}
function Wait-MetaMcp($State) {
    $timeout = 240
    if ($env:MCPKIT_METAMCP_START_TIMEOUT -match '^\d{1,3}$') { $timeout = [Math]::Max(1, [Math]::Min(600, [int]$env:MCPKIT_METAMCP_START_TIMEOUT)) }
    $deadline = [DateTime]::UtcNow.AddSeconds($timeout)
    Write-KitInfo 'Waiting for MetaMCP and its database to initialize...'
    do {
        $health = Invoke-Docker @('--context', 'desktop-linux', 'exec', ($State.project + '-app'), 'sh', '-c',
            'curl --fail --silent --max-time 3 http://127.0.0.1:12008/health >/dev/null && curl --fail --silent --max-time 3 http://127.0.0.1:12009/health >/dev/null') '' 10
        if ($health.code -eq 0) { Write-KitOk 'MetaMCP and its database are ready.'; return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'MetaMCP did not become ready. Check .\windows\run-local.ps1 logs metamcp; its database and containers were preserved.'
}
function Invoke-MetaSeedQuery($State, [string]$Sql, [string]$Encoded, [string]$Mode) {
    $inputText = "\set local_bundle_b64 '$Encoded'`n\set local_force '$Mode'`n$Sql`n"
    # The app can be stopped during migration; the owned PostgreSQL container
    # has psql and its own database credentials. Neither appears in argv.
    $script = 'PGPASSWORD="$POSTGRES_PASSWORD"; export PGPASSWORD; exec psql -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -v ON_ERROR_STOP=1 -qAt'
    $result = Invoke-Docker @('--context', 'desktop-linux', 'exec', '-i', ($State.project + '-postgres'), 'sh', '-c', $script) $inputText 120
    # SQL input includes the gateway key. Never echo SQL/stdout/stderr on error.
    if ($Mode -ceq 'reset-all' -and $result.code -ne 0) {
        if ($result.stderr -match 'MCPKIT_RESET_UNSUPPORTED_SCHEMA') {
            throw 'Reset was blocked by custom database foreign keys or triggers; no records were deleted.'
        }
        if ($result.stderr -match 'MCPKIT_RESET_INCOMPLETE') {
            throw 'Reset was rolled back because the new default records could not be confirmed.'
        }
        Assert-DockerResult $result 'reset; outcome may be unknown, inspect MetaMCP before retrying' $false
    }
    Assert-DockerResult $result 'local server registration; check MetaMCP logs and retry' $false
    return $result.stdout.Trim()
}
function Backup-MetaDatabase($State, [bool]$ForReset = $false) {
    # Keep a private pre-change dump in the existing PostgreSQL volume; it is
    # never copied into the repository and is not an independent volume backup.
    $purpose = if ($ForReset) { 'reset' } else { 'seed' }
    $name = 'mcpkit-pre-' + $purpose + '-v3-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + (New-RandomHex 4) + '.dump'
    $script = @'
set -eu
umask 077
dir="$PGDATA/mcpkit-backups"
if [ -L "$dir" ]; then exit 1; fi
if [ ! -d "$dir" ]; then mkdir -m 700 "$dir"; fi
file="$dir/__BACKUP_NAME__"
if [ -e "$file" ] || [ -L "$file" ]; then exit 1; fi
PGPASSWORD="$POSTGRES_PASSWORD"; export PGPASSWORD
pg_dump -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -f "$file"
printf 'backup-ok\n'
'@
    $script = $script.Replace('__BACKUP_NAME__', $name)
    $result = Invoke-Docker @('--context', 'desktop-linux', 'exec', '--user', 'postgres', ($State.project + '-postgres'), 'sh', '-c', $script) '' 600
    $action = if ($ForReset) { 'pre-reset PostgreSQL backup; no reset was attempted' } else { 'pre-migration PostgreSQL backup; no migration was attempted' }
    Assert-DockerResult $result $action $false
    if ($result.stdout.Trim() -cne 'backup-ok') {
        if ($ForReset) { throw 'Could not confirm the PostgreSQL backup; no reset was attempted.' }
        throw 'Could not confirm the PostgreSQL backup; no migration was attempted.'
    }
    Write-KitOk "Database backup: PostgreSQL volume /mcpkit-backups/$name (contains secrets; keep private)."
}
function Assert-MetaResetContract([string]$Sql) {
    # Detect an older SQL file mixed with the new PowerShell runner before it
    # can delete anything. This is a compatibility marker, not an integrity
    # check; local modifications still need to be reviewed separately.
    if ($Sql -cnotmatch '(?m)^-- MCPKIT_RESET_CONTRACT: short-names-v4\r?$') {
        throw 'Reset not attempted: seed-local.sql is not the short-name reset version. Update all kit files together and inspect the current MetaMCP state and backup before retrying.'
    }
}
function Invoke-MetaSeed($State, [bool]$Force, [string]$RequestedOwner = '', [bool]$ResetAll = $false) {
    if ($ResetAll -and (-not $Force -or $RequestedOwner)) { throw 'Invalid reset request; no records were changed.' }
    $config = Get-Configuration
    $settings = $config.settings
    if ($settings.listenHost.ToLowerInvariant() -notin @('127.0.0.1', 'localhost') -or $settings.tlsCertFile -or $settings.tlsKeyFile) {
        throw 'Automatic Docker Desktop connection requires the existing gateway to use local IPv4 HTTP. Your customized gateway settings were not changed.'
    }
    if ($RequestedOwner -and -not (Test-MetaEmail $RequestedOwner)) { throw 'OwnerEmail must be the email of an existing MetaMCP account.' }
    # Shared resources do not belong to an account. Only an explicitly
    # requested email is resolved (for the legacy administrator allowlist).
    $bundle = [ordered]@{ version = 1; hostId = $settings.hostId; ownerEmail = $RequestedOwner; port = $settings.port; gatewayKey = $config.secrets.gatewayApiKey }
    $json = ConvertTo-Json -InputObject $bundle -Depth 10 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $sql = Get-Content -LiteralPath (Join-Path $ScriptDir 'seed-local.sql') -Raw -Encoding UTF8
    if ($ResetAll) { Assert-MetaResetContract $sql }
    $rawResult = ''
    $needsApply = $Force
    if (-not $Force) {
        # This mode cannot mutate the database, even if a marker disappears
        # between checks. An initialized database does not restart the app.
        $rawResult = Invoke-MetaSeedQuery $State $sql $encoded 'skip-only'
        $needsApply = $rawResult -ceq 'needs-apply|||||'
    }
    if ($needsApply) {
        if (-not (Test-OwnedDockerObject 'container' ($State.project + '-app') $State) -or
            -not (Test-OwnedDockerObject 'container' ($State.project + '-postgres') $State)) {
            throw 'The kit MetaMCP containers could not be verified; no database changes were attempted.'
        }
        # Stopping (not recreating) clears both active sessions and prewarmed
        # idle servers, and prevents stale tool names during the DB change.
        if ($ResetAll) { Write-KitInfo 'Stopping the kit MetaMCP app for a database backup and explicit reset; clients will need to reconnect.' }
        else { Write-KitInfo 'Temporarily stopping the kit MetaMCP app for a database backup and server-name migration; clients will need to reconnect.' }
        $stop = Invoke-Docker @('--context', 'desktop-linux', 'stop', '--time', '20', ($State.project + '-app')) '' 180
        Assert-DockerResult $stop 'MetaMCP app stop before local seed'
        $resetAttempted = $false
        $resetCommitted = $false
        try {
            Backup-MetaDatabase $State $ResetAll
            $forceValue = if ($ResetAll) { 'reset-all' } elseif ($Force) { 'true' } else { 'false' }
            if ($ResetAll) { $resetAttempted = $true }
            try { $rawResult = Invoke-MetaSeedQuery $State $sql $encoded $forceValue }
            catch {
                if ($ResetAll -and $_.Exception.Message -notmatch '^Reset was (blocked|rolled back)') {
                    Write-KitWarn 'The reset result is uncertain. Inspect MetaMCP and the backup before running reset again.'
                }
                throw
            }
            if ($ResetAll -and $rawResult.StartsWith('seeded|')) {
                $resetCommitted = $true
                Write-KitOk 'The reset transaction committed; do not run reset again if the app restart fails.'
            }
        } finally {
            # The same container and writable layer are reused, even if the
            # backup or transaction failed. A later start can restore the app.
            try {
                $restart = Invoke-Docker @('--context', 'desktop-linux', 'start', ($State.project + '-app')) '' 180
                Assert-DockerResult $restart 'MetaMCP app restart; run start to retry'
                Wait-MetaMcp $State
            } catch {
                if ($resetAttempted) {
                    $status = if ($resetCommitted) { 'committed' } else { 'may have committed' }
                    Write-KitWarn "The reset $status. Do not repeat it; run start and inspect MetaMCP first."
                }
                throw
            }
        }
        Write-KitOk 'MetaMCP app restarted without recreating its container. Reconnect MCP clients to refresh server and tool names.'
    }
    $parts = $rawResult -split '\|', 6
    if ($parts.Count -ne 6) {
        if ($ResetAll) { throw 'The reset may have committed, but its result could not be confirmed. Inspect MetaMCP before retrying.' }
        throw 'Unexpected local MetaMCP registration result; existing records were not overwritten.'
    }
    if ($ResetAll -and ($parts[0] -cne 'seeded' -or $parts[1] -or $parts[3] -or $parts[4] -or $parts[5] -or
            @($parts[2] -split ',' | Where-Object { $_ }).Count -ne 6)) {
        throw 'The reset may have committed, but its result could not be confirmed. Inspect MetaMCP before retrying.'
    }
    switch ($parts[0]) {
        'missing'   { throw 'The selected MetaMCP account was not found. Register first, then run seed -OwnerEmail <your-email>.' }
        'ambiguous' { throw 'The selected MetaMCP email is ambiguous. Choose a unique existing account with seed -OwnerEmail <your-email>.' }
        'seeded'    { }
        'skipped'   { }
        default     { throw 'Unexpected local MetaMCP registration result; existing records were not overwritten.' }
    }
    $baseGroup = 'local-' + $settings.hostId
    $shortGroups = @('system', 'files', 'code', 'web', 'data', 'memory')
    $allowedGroups = $shortGroups + @(foreach ($suffix in $shortGroups) { $baseGroup + '-' + $suffix })
    if ($parts[2]) {
        foreach ($group in @($parts[2] -split ',')) {
            if ($allowedGroups -cnotcontains $group -or ($ResetAll -and $shortGroups -cnotcontains $group)) {
                if ($ResetAll) { throw 'The reset may have committed, but its endpoint names are unexpected. Inspect MetaMCP before retrying.' }
                throw 'Unexpected local MetaMCP endpoint name; existing state was not changed.'
            }
        }
    }
    # Explicit selection remains backward-compatible for legacy installations
    # with an admin allowlist. Ordinary public seeding never chooses an owner.
    if ($RequestedOwner) {
        try { $actualOwner = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[1])) }
        catch { throw 'Unexpected MetaMCP account in registration result; existing state was not changed.' }
        if (-not (Test-MetaEmail $actualOwner) -or $actualOwner -ine $RequestedOwner) {
            throw 'Unexpected MetaMCP account in registration result; existing state was not changed.'
        }
        $changed = $State.ownerEmail -cne $actualOwner
        $State.ownerEmail = $actualOwner
        $admins = Get-MetaAdminEmails $State
        if ($admins -and @($admins.Split(',') | Where-Object { $_ -ieq $actualOwner }).Count -eq 0) {
            $State.additionalAdminEmails = @($State.additionalAdminEmails) + @($actualOwner)
            $State.authPending = $true
            $changed = $true
            Write-KitInfo 'Adding the selected existing account to the MetaMCP administrator allowlist; existing administrators are retained.'
        }
        if ($changed) { $null = Save-Json $MetaStateFile $State }
    } elseif ($parts[1]) { throw 'Unexpected MetaMCP account in registration result; existing state was not changed.' }

    if ($parts[3]) { Write-KitWarn "Unauthenticated endpoint detected or previously blocked group: $($parts[3]). Seed adds no tools while open; existing mappings may already be exposed. Protect all endpoints and run seed again." }
    if ($parts[4]) { Write-KitWarn "Some records could not be safely merged or linked: $($parts[4]). Conflicting records (including possible old duplicates) were preserved. Review them and run seed again." }
    if ($parts[5]) { Write-KitWarn "Some removed, restricted or incompatible legacy mappings were not added to shared groups: $($parts[5]). Review them before explicitly running seed." }
    if ($parts[0] -eq 'seeded' -and -not ($parts[3] -or $parts[4] -or $parts[5])) {
        Write-KitOk 'Registered the 13 Windows servers in shared, API-key-protected groups.'
    } elseif ($parts[0] -eq 'seeded') {
        Write-KitWarn 'Shared Windows server groups were initialized; review the warnings above for skipped records.'
    } else {
        Write-KitOk 'The local server configuration was already initialized; user edits and deletions were preserved.'
    }
    return $parts[2]
}
function Show-MetaEndpoints($State, [string]$Groups) {
    Write-KitHeader 'MCP endpoints'
    if (-not $Groups) {
        Write-KitWarn 'No usable shared MCP endpoint was found. Check the warnings and MetaMCP settings.'
        return
    }
    $groupNames = @($Groups -split ',')
    foreach ($group in $groupNames) {
        Write-KitInfo "MCP endpoint ($group): http://localhost:$($State.port)/metamcp/$group/mcp"
    }
    if (@($groupNames | Where-Object { $_ -clike 'local-*' }).Count -gt 0) {
        Write-KitWarn 'Legacy prefixed endpoints were preserved; start and seed do not rename them. Before any explicit reset, check the active kit files and make a separate backup.'
    }
    if ($groupNames.Count -lt 6) {
        Write-KitWarn 'One or more shared endpoints are missing, conflicting or open. Check MetaMCP settings before explicitly running seed.'
    }
}
function Test-MetaBridge($State) {
    $running = Get-RunningState
    if (-not $running) { throw 'The Windows gateway is not running; MetaMCP was started but cannot reach the native servers.' }
    $gatewayState = $running.state
    if ($gatewayState.tls -or $gatewayState.host.ToLowerInvariant() -notin @('127.0.0.1', 'localhost')) {
        throw 'The running gateway uses customized network settings. They were preserved; restart it with local IPv4 HTTP for Docker Desktop.'
    }
    # Check the actual container-to-Windows path with the control secret on
    # stdin, not the command line. No broad listener or firewall rule is added.
    $probe = @'
const http = require('http');
let data = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', part => data += part);
process.stdin.on('end', () => {
  let c; try { c = JSON.parse(data); } catch { process.exit(2); }
  const request = http.get({hostname:'host.docker.internal', port:c.port, path:'/_mcpkit/status', headers:{'X-Mcpkit-Control':c.key}, timeout:5000}, response => {
    let body = ''; response.setEncoding('utf8'); response.on('data', part => body += part);
    response.on('end', () => { try { const s = JSON.parse(body); if (response.statusCode === 200 && s.instanceId === c.instanceId) { console.log('bridge-ok'); return; } } catch {} process.exitCode = 1; });
  });
  request.on('timeout', () => request.destroy());
  request.on('error', () => { process.exitCode = 1; });
});
'@
    $inputText = ConvertTo-Json -InputObject @{ port = $gatewayState.port; key = $gatewayState.controlKey; instanceId = $gatewayState.instanceId } -Compress
    $result = Invoke-Docker @('--context', 'desktop-linux', 'exec', '-i', ($State.project + '-app'), 'node', '-e', $probe) $inputText 15
    if ($result.code -ne 0 -or $result.stdout.Trim() -cne 'bridge-ok') {
        throw 'Docker Desktop cannot reach the loopback Windows gateway via host.docker.internal. Check Docker Desktop networking and retry; the gateway was not exposed to the LAN.'
    }
    Write-KitOk 'Docker Desktop can reach the authenticated loopback Windows gateway.'
}
function Enter-MetaLock {
    $file = Join-Path $PrivateDir 'metamcp.lock'
    try { return [IO.File]::Open($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
    catch [IO.IOException] { throw "Another MetaMCP operation may be running. If it crashed, inspect and remove $file before retrying." }
}
function Exit-MetaLock($Lock) {
    $Lock.Dispose()
    Remove-Item -LiteralPath (Join-Path $PrivateDir 'metamcp.lock') -Force -ErrorAction SilentlyContinue
}
function Save-MetaAppImage($State) {
    $app = $State.project + '-app'
    if (-not (Test-OwnedDockerObject 'container' $app $State)) { return '' }
    # Port bindings and container environment cannot be changed in place.
    # Stop only the verified kit app, snapshot its writable layer, and run the
    # replacement from that snapshot. PostgreSQL and uv-cache volumes remain.
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $image = $State.project + '-app-backup:' + $stamp + '-' + (New-RandomHex 4)
    $probe = Invoke-Docker @('--context', 'desktop-linux', 'image', 'inspect', '--format', '{{.Id}}', $image)
    if ($probe.code -eq 0) { throw 'The generated MetaMCP backup image name already exists; nothing was overwritten.' }
    if ($probe.stderr -notmatch '(?i)(no such image|not found)') { Assert-DockerResult $probe 'backup image inspection' }
    Write-KitInfo 'Stopping the kit MetaMCP app and preserving its writable layer before applying configuration...'
    $stop = Invoke-Docker @('--context', 'desktop-linux', 'stop', '--time', '20', $app) '' 180
    Assert-DockerResult $stop 'MetaMCP app stop for port change'
    $commit = Invoke-Docker @('--context', 'desktop-linux', 'commit', '--change', ('LABEL com.multfinite.mcpkit.instance=' + $State.instanceId), $app, $image) '' 600
    Assert-DockerResult $commit 'MetaMCP app backup'
    if (-not (Test-OwnedDockerObject 'image' $image $State)) { throw 'The MetaMCP app backup could not be verified; the old container was kept.' }
    Write-KitOk "Preserved app image: $image (local only; it may contain secrets)."
    return $image
}
function Start-MetaApp($State) {
    if ($State.portsPending -or -not $State.manualAuthApplied -or $State.authPending) {
        # A port change, old bootstrap environment, or an explicitly added
        # administrator requires replacing only the app. Keep retry state
        # until Compose succeeds; never recreate the DB or remove volumes.
        $database = Invoke-Compose $State @('up', '-d', '--no-recreate', '--no-build', 'postgres') 600
        Assert-DockerResult $database 'MetaMCP database start'
        $snapshot = Save-MetaAppImage $State
        if ($snapshot) {
            $State.appImage = $snapshot
            $null = Save-Json $MetaStateFile $State
            Test-MetaCompose $State
            Test-MetaResources $State
        }
        $start = Invoke-Compose $State @('up', '-d', '--no-deps', '--force-recreate', '--no-build', 'app') 600
        Assert-DockerResult $start 'MetaMCP start with updated configuration'
        $State.portsPending = $false
        $State.manualAuthApplied = $true
        $State.authPending = $false
        $null = Save-Json $MetaStateFile $State
    } else {
        $start = Invoke-Compose $State @('up', '-d', '--no-recreate', '--no-build') 600
        Assert-DockerResult $start 'MetaMCP start'
    }
    Wait-MetaMcp $State
}
function Start-MetaMcp {
    Write-KitHeader 'MetaMCP Fullstack'
    $lock = Enter-MetaLock
    try {
        Ensure-DesktopDocker
        $state = Initialize-MetaState
        Ensure-MetaClone $state
        Test-MetaCompose $state
        Test-MetaResources $state
        Ensure-MetaImage $state
        Test-MetaResources $state
        Start-MetaApp $state
        $endpointGroups = Invoke-MetaSeed $state $false
        Test-MetaBridge $state
        Write-KitInfo "MetaMCP: http://localhost:$($state.port)"
        Show-MetaEndpoints $state $endpointGroups
        if ($state.backendPort -gt 0) { Write-KitInfo "MetaMCP backend (loopback only): http://localhost:$($state.backendPort)" }
        Write-KitInfo 'Sign in or register in MetaMCP. To close registration, use Settings > Authentication > Disable UI Registration.'
        Write-KitInfo 'Create an API key in the MetaMCP UI; new shared endpoints require it.'
    } finally { Exit-MetaLock $lock }
}
function Show-MetaPorts {
    Write-KitHeader 'MetaMCP ports'
    $state = Get-MetaState
    if (-not $state) {
        Write-KitInfo "New-install defaults: frontend $($Manifest.metamcp.frontendPort), backend $($Manifest.metamcp.backendPort)."
        Write-KitInfo 'Override before first install with MCPKIT_METAMCP_PORT and MCPKIT_METAMCP_BACKEND_PORT.'
        return
    }
    Write-KitInfo "Frontend / MCP endpoint (loopback): $($state.port)"
    if ($state.backendPort -gt 0) { Write-KitInfo "Backend (loopback): $($state.backendPort)" }
    else { Write-KitInfo 'Backend: not published on the Windows host.' }
    if ($state.portsPending) { Write-KitWarn 'The change is pending; run start to retry it.' }
    Write-KitInfo "Managed port state: $MetaStateFile"
    Write-KitInfo 'Change it with: run-local.ps1 set-ports -WebPort <port> -BackendPort <port-or-0>'
}
function Set-MetaPorts([int]$FrontendPort, [int]$BackendPort) {
    if ($FrontendPort -lt 1 -or $FrontendPort -gt 65535 -or $BackendPort -lt 0 -or $BackendPort -gt 65535 -or
        ($BackendPort -ne 0 -and $FrontendPort -eq $BackendPort)) {
        throw 'WebPort must be 1-65535; BackendPort must be a different port or 0 to keep the backend unpublished.'
    }
    $lock = Enter-MetaLock
    try {
        $state = Get-MetaState
        if (-not $state) { throw 'MetaMCP is not initialized. Set MCPKIT_METAMCP_PORT and MCPKIT_METAMCP_BACKEND_PORT before the first install.' }
        $gatewayPort = (Get-Configuration).settings.port
        if ($FrontendPort -eq $gatewayPort -or ($BackendPort -ne 0 -and $BackendPort -eq $gatewayPort)) {
            throw 'MetaMCP ports must differ from the Windows gateway port in config/local-settings.json.'
        }
        Ensure-DesktopDocker
        Assert-MetaClone $state
        Test-MetaCompose $state
        Test-MetaResources $state
        if ($state.port -ne $FrontendPort -or $state.backendPort -ne $BackendPort) {
            $state.port = $FrontendPort
            $state.backendPort = $BackendPort
            $state.portsPending = $true
            # Validate the proposed config before saving; existing credentials
            # and the database are never edited by a port change.
            Test-MetaCompose $state
            $null = Save-Json $MetaStateFile $state
            Write-KitOk "Saved MetaMCP host ports: frontend $FrontendPort, backend $BackendPort (0 = unpublished)."
        } elseif ($state.portsPending) {
            Write-KitInfo 'The requested port change is already pending; retrying it.'
        } else { Write-KitOk 'The requested MetaMCP ports are already configured.' }
    } finally { Exit-MetaLock $lock }
}
function Stop-MetaMcp {
    Write-KitHeader 'Stopping MetaMCP'
    $state = Get-MetaState
    if (-not $state) { Write-KitInfo 'No kit-managed local MetaMCP has been created.'; return }
    $lock = Enter-MetaLock
    try {
        # Never launch a stopped Docker Desktop just to stop containers, and
        # don't require an intact env/clone to stop verified owned containers.
        Ensure-DesktopDocker -NoStart
        Test-MetaResources $state
        $containers = @()
        foreach ($name in @(($state.project + '-app'), ($state.project + '-postgres'))) {
            if (Test-OwnedDockerObject 'container' $name $state) { $containers += $name }
        }
        if ($containers.Count -gt 0) {
            $stop = Invoke-Docker (@('--context', 'desktop-linux', 'stop', '--time', '20') + $containers) '' 180
            Assert-DockerResult $stop 'MetaMCP stop'
        }
        Write-KitOk 'Kit MetaMCP containers stopped; their volumes, writable layers, and settings were kept.'
    } finally { Exit-MetaLock $lock }
}
function Show-MetaStatus {
    Write-KitHeader 'MetaMCP status'
    $state = Get-MetaState
    if (-not $state) { throw 'Local MetaMCP has not been created. Run start.' }
    Ensure-DesktopDocker -NoStart
    Assert-MetaClone $state
    Test-MetaCompose $state
    Test-MetaResources $state
    $result = Invoke-Compose $state @('ps') 30
    Assert-DockerResult $result 'MetaMCP status'
    Write-Host $result.stdout.TrimEnd()
    Test-MetaBridge $state
    Write-KitInfo "MetaMCP: http://localhost:$($state.port)"
}
function Show-MetaCredentials {
    $state = Get-MetaState
    if (-not $state) { throw 'Local MetaMCP has not been created. Run start.' }
    $values = Read-MetaEnv
    $legacyEmail = 'local-' + $state.instanceId + '@mcpkit.local'
    if ($values.BOOTSTRAP_USER_EMAIL -cne $legacyEmail -or $values.BOOTSTRAP_USER_PASSWORD -cnotmatch '^[a-f0-9]{48}$') {
        Write-Host 'No bootstrap login was created. Register your own account in the MetaMCP UI.'
        return
    }
    # Backward compatibility only: do not create, change, or delete this old
    # account. Its original password may no longer be current.
    Write-Host "MetaMCP: http://localhost:$($state.port)"
    Write-Host "Legacy initial email: $($values.BOOTSTRAP_USER_EMAIL)"
    Write-Host "Legacy initial password: $($values.BOOTSTRAP_USER_PASSWORD)"
    Write-Host 'Keep these private. If the password was changed in MetaMCP, use the current password instead.'
}
function Show-MetaLogs {
    Write-KitHeader 'MetaMCP logs'
    $state = Get-MetaState
    if (-not $state) { throw 'Local MetaMCP has not been created.' }
    Ensure-DesktopDocker -NoStart
    if (-not (Test-OwnedDockerObject 'container' ($state.project + '-app') $state)) { throw 'The local MetaMCP app container has not been created.' }
    $result = Invoke-Docker @('--context', 'desktop-linux', 'logs', '--tail', '100', ($state.project + '-app'))
    Assert-DockerResult $result 'MetaMCP logs'
    if ($result.stdout) { Write-Host $result.stdout.TrimEnd() }
    if ($result.stderr) { Write-Host $result.stderr.TrimEnd() }
}
function Enable-MetaSignup {
    Write-KitHeader 'MetaMCP registration'
    # This changes only the UI-signup flag, and only on an explicit command.
    # It is useful when an older kit version already closed registration.
    $lock = Enter-MetaLock
    try {
        $state = Get-MetaState
        if (-not $state) { throw 'Local MetaMCP has not been created. Run start.' }
        if (-not $state.manualAuthApplied -or $state.authPending -or $state.portsPending) {
            throw 'MetaMCP configuration is pending. Run start before enabling registration.'
        }
        Ensure-DesktopDocker -NoStart
        Assert-MetaClone $state
        Test-MetaCompose $state
        Test-MetaResources $state
        Wait-MetaMcp $state
        $sql = @'
BEGIN;
INSERT INTO config (id, value, description)
VALUES ('DISABLE_SIGNUP', 'false', 'Whether new user signup is disabled')
ON CONFLICT (id) DO UPDATE SET value = 'false', updated_at = now();
COMMIT;
SELECT 'signup-open';
'@
        $script = 'PGPASSWORD="$POSTGRES_PASSWORD"; export PGPASSWORD; exec psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -v ON_ERROR_STOP=1 -qAt'
        $result = Invoke-Docker @('--context', 'desktop-linux', 'exec', '-i', ($state.project + '-app'), 'sh', '-c', $script) $sql 120
        Assert-DockerResult $result 'enable UI registration' $false
        if ($result.stdout.Trim() -cne 'signup-open') { throw 'Could not confirm that UI registration was enabled.' }
        Write-KitOk "UI registration is enabled at http://localhost:$($state.port). Register, then turn it off yourself in MetaMCP Settings."
        Write-KitInfo 'SSO registration and existing accounts were not changed.'
    } finally { Exit-MetaLock $lock }
}
function Repair-MetaSeed([string]$RequestedOwner = '') {
    Write-KitHeader 'Registering Windows servers in MetaMCP'
    $lock = Enter-MetaLock
    $needsApply = $false
    try {
        $state = Get-MetaState
        if (-not $state) { throw 'Local MetaMCP has not been created. Run start.' }
        if (-not $state.manualAuthApplied -or $state.authPending -or $state.portsPending) {
            throw 'MetaMCP configuration is pending. Run start before registering the servers.'
        }
        Ensure-DesktopDocker -NoStart
        Assert-MetaClone $state
        Test-MetaCompose $state
        Test-MetaResources $state
        Wait-MetaMcp $state
        $endpointGroups = Invoke-MetaSeed $state $true $RequestedOwner
        Test-MetaBridge $state
        $needsApply = $state.authPending
        if (-not $needsApply) { Show-MetaEndpoints $state $endpointGroups }
    } finally { Exit-MetaLock $lock }
    # An explicitly selected owner of a legacy multi-user instance becomes an
    # administrator without removing the old allowlist. Recreate only the app,
    # after releasing the lock; a failed application remains retryable.
    if ($needsApply) { Start-MetaMcp }
}
function Reset-MetaRecords {
    # This command is intentionally separate from start/seed. It applies to
    # the dedicated Windows MetaMCP database, including manually added rows.
    Write-KitHeader 'Reset Windows MetaMCP records'
    $initialState = Get-MetaState
    if (-not $initialState) { throw 'Local MetaMCP has not been created. No reset was attempted.' }
    Write-KitInfo "Kit scripts: $ScriptDir"
    $seedPath = Join-Path $ScriptDir 'seed-local.sql'
    if (-not (Test-Path -LiteralPath $seedPath -PathType Leaf)) { throw "Reset not attempted: seed-local.sql is missing: $seedPath" }
    Assert-MetaResetContract (Get-Content -LiteralPath $seedPath -Raw -Encoding UTF8)
    Write-KitWarn "Reset ALL servers, namespaces and endpoints in Windows MetaMCP project $($initialState.project), including manually created records."
    Write-KitWarn 'Their tool settings, mappings and server OAuth sessions will be deleted; historical audit links to those records will be cleared.'
    Write-KitInfo 'User accounts, MetaMCP API keys, native server files, other databases and Docker volumes are not deleted.'
    Write-KitWarn 'A secret-bearing PostgreSQL dump will be made inside the same database volume; make a separate secure backup first.'
    Write-KitInfo 'The new protected endpoints will be named system, files, code, web, data and memory.'
    $confirmation = Read-Host 'Type DELETE ALL LOCAL RECORDS to continue'
    if ($confirmation -cne 'DELETE ALL LOCAL RECORDS') {
        Write-KitInfo 'Reset cancelled; no records were changed.'
        return
    }
    $lock = Enter-MetaLock
    try {
        $state = Get-MetaState
        if (-not $state -or $state.instanceId -cne $initialState.instanceId -or $state.project -cne $initialState.project -or
            $state.cloneDir -cne $initialState.cloneDir) {
            throw 'The target MetaMCP project changed after confirmation; no reset was attempted.'
        }
        Ensure-DesktopDocker
        Assert-MetaClone $state
        Test-MetaCompose $state
        Test-MetaResources $state
        Ensure-MetaImage $state
        Test-MetaResources $state
        # Apply pending app/bootstrap settings without invoking the normal V3
        # migration first. Otherwise an old bootstrap could recreate old rows
        # when the stopped app is restarted after the reset.
        Start-MetaApp $state
        $endpointGroups = Invoke-MetaSeed $state $true '' $true
        Write-KitOk 'Windows MetaMCP records were reset once and the 13 default short-name servers and six protected groups were created.'
        Show-MetaEndpoints $state $endpointGroups
        try { Test-MetaBridge $state }
        catch { Write-KitWarn "Reset already completed, but gateway connectivity could not be verified: $($_.Exception.Message)" }
    } finally { Exit-MetaLock $lock }
}
