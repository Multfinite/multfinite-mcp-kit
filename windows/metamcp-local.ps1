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
                Write-Host 'Starting Docker Desktop; complete its first-run/WSL setup if prompted.'
                Start-Process -FilePath $desktop | Out-Null
            } else { Write-Host 'Waiting for Docker Desktop and its local Linux engine...' }
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
function Get-MetaState {
    if (-not (Test-Path -LiteralPath $MetaStateFile -PathType Leaf)) { return $null }
    $state = Read-Json $MetaStateFile
    if ($state.version -ne 1 -or $state.instanceId -cnotmatch '^[a-f0-9]{16}$' -or
        $state.project -cne ('mcpkit-win-' + $state.instanceId) -or
        $state.ownerEmail -cne ('local-' + $state.instanceId + '@mcpkit.local') -or
        ($state.port -isnot [int] -and $state.port -isnot [long]) -or $state.port -lt 1 -or $state.port -gt 65535 -or
        $state.envCreated -isnot [bool]) { throw "Invalid MetaMCP state; existing files were not changed: $MetaStateFile" }
    # Old installations published only the frontend. Do not change their
    # ports or recreate their app unless the user explicitly asks to do so.
    if (-not $state.PSObject.Properties['backendPort']) { $state | Add-Member -NotePropertyName backendPort -NotePropertyValue 0 }
    if (-not $state.PSObject.Properties['portsPending']) { $state | Add-Member -NotePropertyName portsPending -NotePropertyValue $false }
    if (-not $state.PSObject.Properties['appImage']) { $state | Add-Member -NotePropertyName appImage -NotePropertyValue '' }
    if (($state.backendPort -isnot [int] -and $state.backendPort -isnot [long]) -or
        $state.backendPort -lt 0 -or $state.backendPort -gt 65535 -or
        ($state.backendPort -ne 0 -and $state.backendPort -eq $state.port) -or
        $state.portsPending -isnot [bool] -or $state.appImage -isnot [string]) {
        throw "Invalid MetaMCP port state; existing files were not changed: $MetaStateFile"
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
            Write-Host "An existing metamcp directory was preserved; the kit will use $clone instead."
        }
        $candidate = [ordered]@{ version = 1; instanceId = $id; project = 'mcpkit-win-' + $id; port = $port;
            backendPort = $backendPort; portsPending = $false; appImage = '';
            ownerEmail = 'local-' + $id + '@mcpkit.local'; cloneDir = [IO.Path]::GetFullPath($clone); envCreated = $false }
        $null = Save-Json $MetaStateFile $candidate -CreateOnly
        $state = Get-MetaState
    }
    if (-not (Test-Path -LiteralPath $MetaEnvFile -PathType Leaf)) {
        if ($state.envCreated) { throw "The existing MetaMCP env file is missing. Restore it from backup; credentials were not regenerated: $MetaEnvFile" }
        $pgPassword = New-RandomHex 32
        $authSecret = New-RandomHex 32
        $userPassword = New-RandomHex 24
        $image = $state.project + '-metamcp:' + $Manifest.metamcp.revision.Substring(0, 12)
        $keys = '[{"name":"Windows LOCAL","is_public":false,"user_email":"' + $state.ownerEmail + '"}]'
        $lines = @(
            'NODE_ENV=production', 'LOG_LEVEL=errors-only',
            'POSTGRES_HOST=postgres', 'POSTGRES_PORT=5432', 'POSTGRES_USER=metamcp_user',
            "POSTGRES_PASSWORD=$pgPassword", 'POSTGRES_DB=metamcp_db',
            "APP_URL=http://localhost:$($state.port)", "BETTER_AUTH_SECRET=$authSecret",
            'TRANSFORM_LOCALHOST_TO_DOCKER_INTERNAL=false',
            'BOOTSTRAP_ENABLE=true', 'BOOTSTRAP_USER_NAME=Windows LOCAL',
            "BOOTSTRAP_USER_EMAIL=$($state.ownerEmail)", "BOOTSTRAP_USER_PASSWORD=$userPassword",
            'BOOTSTRAP_RECREATE_USER=false', 'BOOTSTRAP_DELETE_OTHER_USERS=false',
            'BOOTSTRAP_ONLY_FIRST_RUN=true', 'BOOTSTRAP_DISABLE_REGISTRATION_UI=false',
            'BOOTSTRAP_DISABLE_REGISTRATION_SSO=true', "BOOTSTRAP_API_KEYS=$keys",
            "METAMCP_ADMIN_EMAILS=$($state.ownerEmail)",
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
        Write-Host 'Cloning the official MetaMCP repository...'
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
        $envs.BETTER_AUTH_SECRET -cnotmatch '^[a-f0-9]{64}$' -or $envs.BOOTSTRAP_USER_EMAIL -cne $State.ownerEmail -or
        $envs.BOOTSTRAP_USER_PASSWORD -cnotmatch '^[a-f0-9]{48}$' -or $envs.BOOTSTRAP_ENABLE -cne 'true' -or
        $envs.BOOTSTRAP_RECREATE_USER -cne 'false' -or $envs.BOOTSTRAP_DELETE_OTHER_USERS -cne 'false' -or
        $envs.BOOTSTRAP_ONLY_FIRST_RUN -cne 'true' -or $envs.BOOTSTRAP_DISABLE_REGISTRATION_UI -cne 'false' -or
        $envs.BOOTSTRAP_DISABLE_REGISTRATION_SSO -cne 'true') { throw 'Unexpected local MetaMCP authentication or bootstrap settings; existing credentials were not changed.' }
    # Supplying a second bootstrap array can override the single generated
    # owner, or affect existing records. It is never used by this installer.
    foreach ($name in @('BOOTSTRAP_USERS', 'BOOTSTRAP_NAMESPACES', 'BOOTSTRAP_ENDPOINTS')) {
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
    Write-Host 'Building the cloned MetaMCP image (first run can take several minutes and download dependencies)...'
    $build = Invoke-Compose $State @('build', 'app') 3600
    Assert-DockerResult $build 'MetaMCP image build'
    if (-not (Test-OwnedDockerObject 'image' $image $State)) { throw 'The expected local MetaMCP image was not created.' }
}
function Wait-MetaMcp($State) {
    $timeout = 240
    if ($env:MCPKIT_METAMCP_START_TIMEOUT -match '^\d{1,3}$') { $timeout = [Math]::Max(1, [Math]::Min(600, [int]$env:MCPKIT_METAMCP_START_TIMEOUT)) }
    $deadline = [DateTime]::UtcNow.AddSeconds($timeout)
    Write-Host 'Waiting for MetaMCP and its database to initialize...'
    do {
        $health = Invoke-Docker @('--context', 'desktop-linux', 'exec', ($State.project + '-app'), 'sh', '-c',
            'curl --fail --silent --max-time 3 http://127.0.0.1:12008/health >/dev/null && curl --fail --silent --max-time 3 http://127.0.0.1:12009/health >/dev/null') '' 10
        if ($health.code -eq 0) { return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'MetaMCP did not become ready. Check .\windows\run-local.ps1 logs metamcp; its database and containers were preserved.'
}
function Invoke-MetaSeed($State, [bool]$Force) {
    $config = Get-Configuration
    $settings = $config.settings
    if ($settings.listenHost.ToLowerInvariant() -notin @('127.0.0.1', 'localhost') -or $settings.tlsCertFile -or $settings.tlsKeyFile) {
        throw 'Automatic Docker Desktop connection requires the existing gateway to use local IPv4 HTTP. Your customized gateway settings were not changed.'
    }
    $bundle = [ordered]@{ version = 1; hostId = $settings.hostId; ownerEmail = $State.ownerEmail; port = $settings.port; gatewayKey = $config.secrets.gatewayApiKey }
    $json = ConvertTo-Json -InputObject $bundle -Depth 10 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $sql = Get-Content -LiteralPath (Join-Path $ScriptDir 'seed-local.sql') -Raw -Encoding UTF8
    $forceValue = if ($Force) { 'true' } else { 'false' }
    $inputText = "\set local_bundle_b64 '$encoded'`n\set local_force '$forceValue'`n$sql`n"
    $script = 'PGPASSWORD="$POSTGRES_PASSWORD"; export PGPASSWORD; exec psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -v ON_ERROR_STOP=1 -qAt'
    $result = Invoke-Docker @('--context', 'desktop-linux', 'exec', '-i', ($State.project + '-app'), 'sh', '-c', $script) $inputText 120
    # The input includes a gateway key, so never print SQL/stdout/stderr on an
    # error. The transaction rolls back if migrations or owner are missing.
    Assert-DockerResult $result 'local server registration; check MetaMCP logs and retry' $false
    $response = $result.stdout.Trim()
    if ($response -match '^seeded\|(.*)$') {
        if ($Matches[1]) { throw "Some existing server records conflict and were not changed or linked: $($Matches[1])" }
        Write-Host 'Registered the 13 Windows servers in a private, API-key-protected MetaMCP endpoint.'
    } elseif ($response -eq 'skipped|') {
        Write-Host 'The local server configuration was already initialized; user edits and deletions were preserved.'
    } else { throw 'Unexpected local MetaMCP registration result; existing records were not overwritten.' }
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
    Write-Host 'Docker Desktop can reach the authenticated loopback Windows gateway.'
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
    # Port bindings cannot be changed on an existing container. Stop only the
    # verified kit app, snapshot its writable layer, and run the replacement
    # from that snapshot. The PostgreSQL and uv-cache volumes remain attached.
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $image = $State.project + '-app-backup:' + $stamp + '-' + (New-RandomHex 4)
    $probe = Invoke-Docker @('--context', 'desktop-linux', 'image', 'inspect', '--format', '{{.Id}}', $image)
    if ($probe.code -eq 0) { throw 'The generated MetaMCP backup image name already exists; nothing was overwritten.' }
    if ($probe.stderr -notmatch '(?i)(no such image|not found)') { Assert-DockerResult $probe 'backup image inspection' }
    Write-Host 'Stopping the kit MetaMCP app and preserving its writable layer before changing ports...'
    $stop = Invoke-Docker @('--context', 'desktop-linux', 'stop', '--time', '20', $app) '' 180
    Assert-DockerResult $stop 'MetaMCP app stop for port change'
    $commit = Invoke-Docker @('--context', 'desktop-linux', 'commit', '--change', ('LABEL com.multfinite.mcpkit.instance=' + $State.instanceId), $app, $image) '' 600
    Assert-DockerResult $commit 'MetaMCP app backup'
    if (-not (Test-OwnedDockerObject 'image' $image $State)) { throw 'The MetaMCP app backup could not be verified; the old container was kept.' }
    Write-Host "Preserved app image: $image (local only; it may contain secrets)."
    return $image
}
function Start-MetaMcp {
    $lock = Enter-MetaLock
    try {
        Ensure-DesktopDocker
        $state = Initialize-MetaState
        Ensure-MetaClone $state
        Test-MetaCompose $state
        Test-MetaResources $state
        Ensure-MetaImage $state
        Test-MetaResources $state
        if ($state.portsPending) {
            # Changing published ports requires replacing only the app. Keep a
            # retry marker until Compose has created the new binding. Never
            # recreate the database, remove volumes, or touch other projects.
            $database = Invoke-Compose $state @('up', '-d', '--no-recreate', '--no-build', 'postgres') 600
            Assert-DockerResult $database 'MetaMCP database start'
            $snapshot = Save-MetaAppImage $state
            if ($snapshot) {
                $state.appImage = $snapshot
                $null = Save-Json $MetaStateFile $state
                Test-MetaCompose $state
                Test-MetaResources $state
            }
            $start = Invoke-Compose $state @('up', '-d', '--no-deps', '--force-recreate', '--no-build', 'app') 600
            Assert-DockerResult $start 'MetaMCP start with new ports'
            $state.portsPending = $false
            $null = Save-Json $MetaStateFile $state
        } else {
            $start = Invoke-Compose $state @('up', '-d', '--no-recreate', '--no-build') 600
            Assert-DockerResult $start 'MetaMCP start'
        }
        Wait-MetaMcp $state
        Invoke-MetaSeed $state $false
        Test-MetaBridge $state
        $settings = (Get-Configuration).settings
        Write-Host "MetaMCP: http://localhost:$($state.port)"
        Write-Host "MCP endpoint: http://localhost:$($state.port)/metamcp/local-$($settings.hostId)/mcp"
        if ($state.backendPort -gt 0) { Write-Host "MetaMCP backend (loopback only): http://localhost:$($state.backendPort)" }
        Write-Host 'Initial login: .\windows\run-local.ps1 credentials (keep it private). The private API key is in the MetaMCP UI.'
    } finally { Exit-MetaLock $lock }
}
function Show-MetaPorts {
    $state = Get-MetaState
    if (-not $state) {
        Write-Host "New-install defaults: frontend $($Manifest.metamcp.frontendPort), backend $($Manifest.metamcp.backendPort)."
        Write-Host 'Override before first install with MCPKIT_METAMCP_PORT and MCPKIT_METAMCP_BACKEND_PORT.'
        return
    }
    Write-Host "Frontend / MCP endpoint (loopback): $($state.port)"
    if ($state.backendPort -gt 0) { Write-Host "Backend (loopback): $($state.backendPort)" }
    else { Write-Host 'Backend: not published on the Windows host.' }
    if ($state.portsPending) { Write-Host 'The change is pending; run start to retry it.' }
    Write-Host "Managed port state: $MetaStateFile"
    Write-Host 'Change it with: run-local.ps1 set-ports -WebPort <port> -BackendPort <port-or-0>'
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
            Write-Host "Saved MetaMCP host ports: frontend $FrontendPort, backend $BackendPort (0 = unpublished)."
        } elseif ($state.portsPending) {
            Write-Host 'The requested port change is already pending; retrying it.'
        } else { Write-Host 'The requested MetaMCP ports are already configured.' }
    } finally { Exit-MetaLock $lock }
}
function Stop-MetaMcp {
    $state = Get-MetaState
    if (-not $state) { Write-Host 'No kit-managed local MetaMCP has been created.'; return }
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
        Write-Host 'Kit MetaMCP containers stopped; their volumes, writable layers, and settings were kept.'
    } finally { Exit-MetaLock $lock }
}
function Show-MetaStatus {
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
    Write-Host "MetaMCP: http://localhost:$($state.port)"
}
function Show-MetaCredentials {
    $state = Get-MetaState
    if (-not $state) { throw 'Local MetaMCP has not been created. Run start.' }
    $values = Read-MetaEnv
    if ($values.BOOTSTRAP_USER_EMAIL -cne $state.ownerEmail -or -not $values.BOOTSTRAP_USER_PASSWORD) { throw 'The existing MetaMCP login file is invalid; it was not changed.' }
    Write-Host "MetaMCP: http://localhost:$($state.port)"
    Write-Host "Initial email: $($values.BOOTSTRAP_USER_EMAIL)"
    Write-Host "Initial password: $($values.BOOTSTRAP_USER_PASSWORD)"
    Write-Host 'Keep these private. If you changed the password in MetaMCP, use the changed password instead.'
}
function Show-MetaLogs {
    $state = Get-MetaState
    if (-not $state) { throw 'Local MetaMCP has not been created.' }
    Ensure-DesktopDocker -NoStart
    if (-not (Test-OwnedDockerObject 'container' ($state.project + '-app') $state)) { throw 'The local MetaMCP app container has not been created.' }
    $result = Invoke-Docker @('--context', 'desktop-linux', 'logs', '--tail', '100', ($state.project + '-app'))
    Assert-DockerResult $result 'MetaMCP logs'
    if ($result.stdout) { Write-Host $result.stdout.TrimEnd() }
    if ($result.stderr) { Write-Host $result.stderr.TrimEnd() }
}
function Repair-MetaSeed {
    $state = Get-MetaState
    if (-not $state) { throw 'Local MetaMCP has not been created. Run start.' }
    $lock = Enter-MetaLock
    try {
        Ensure-DesktopDocker -NoStart
        Assert-MetaClone $state
        Test-MetaCompose $state
        Test-MetaResources $state
        Wait-MetaMcp $state
        Invoke-MetaSeed $state $true
        Test-MetaBridge $state
    } finally { Exit-MetaLock $lock }
}
