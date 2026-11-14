#Requires -Version 5.1
<#
.SYNOPSIS
    Install the native Windows LOCAL servers and local Docker Desktop MetaMCP.
.DESCRIPTION
    Uses isolated, pinned runtimes under %USERPROFILE%\mcp-local. Existing
    .env, mcp-local.json, user data, and global npm/Python packages are kept.
    MetaMCP is cloned and built into a separate Docker Desktop project.
    Run from an interactive Windows user session, not as a Windows service.
#>
[CmdletBinding()]
param(
    [switch]$NonInteractive,
    # Add local Docker MetaMCP to an already installed native LOCAL stack.
    [switch]$MetaMcpOnly,
    [switch]$InstallBuildTools,
    [switch]$SkipEverything,
    [switch]$SkipBrowserDownload
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseDir = if ($env:MCP_LOCAL_DIR) { [IO.Path]::GetFullPath($env:MCP_LOCAL_DIR) } else { Join-Path $env:USERPROFILE 'mcp-local' }
$Runtime = Join-Path $BaseDir 'runtime'
$PrivateDir = Join-Path $BaseDir 'config\private'
$Manifest = Get-Content -LiteralPath (Join-Path $ScriptDir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Failures = New-Object 'System.Collections.Generic.List[string]'
. (Join-Path $ScriptDir 'local-common.ps1')

function Step([string]$Message) { Write-KitHeader $Message }
function Ok([string]$Message) { Write-KitOk $Message }
function Note([string]$Message) { Write-KitWarn $Message }
function Fail([string]$Message) { Write-KitError $Message; $Failures.Add($Message) }
function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$env:Path;$machine;$user;$(Join-Path $env:USERPROFILE '.local\bin')"
}
function Find-Application([string]$Name) {
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}
function Invoke-Native([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$(Split-Path -Leaf $Executable) failed with exit code $LASTEXITCODE" }
}
function Invoke-Runner([string]$Command) {
    & (Join-Path $ScriptDir 'run-local.ps1') $Command
    if ($LASTEXITCODE -ne 0) { throw "run-local.ps1 $Command failed with exit code $LASTEXITCODE" }
}
function Install-Winget([string]$Id, [string[]]$Extra = @()) {
    $winget = Find-Application 'winget.exe'
    if (-not $winget) { throw 'winget is required for missing prerequisites. Install Microsoft App Installer or install the dependency manually.' }
    $args = @('install', '--id', $Id, '--exact', '--silent', '--accept-source-agreements', '--accept-package-agreements') + $Extra
    Invoke-Native $winget $args
    Refresh-Path
}
function Ensure-GitPrerequisite {
    Step 'Git'
    $git = Find-Application 'git.exe'
    if (-not $git) { Install-Winget 'Git.Git'; $git = Find-Application 'git.exe' }
    if (-not $git) { throw 'Git was installed but is not in PATH. Reopen PowerShell and retry.' }
    Ok "Git: $git"
}
function Ensure-DockerPrerequisite {
    Step 'Docker Desktop'
    $docker = Find-Application 'docker.exe'
    $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    $desktopCli = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'
    if (-not $docker -and (Test-Path -LiteralPath $desktopCli -PathType Leaf)) { $docker = $desktopCli }
    if (-not $docker -and -not (Test-Path -LiteralPath $desktop -PathType Leaf)) {
        Note 'Docker Desktop may require administrator approval, WSL 2 setup, and a Windows reboot.'
        Install-Winget 'Docker.DockerDesktop'
        $docker = Find-Application 'docker.exe'
        if (-not $docker -and (Test-Path -LiteralPath $desktopCli -PathType Leaf)) { $docker = $desktopCli }
    }
    if (-not $docker) { throw 'Docker Desktop was found or installed, but its CLI is not available yet. Complete its setup/reboot, reopen PowerShell, and retry.' }
    Ok "Docker CLI: $docker (the runner checks the local Docker Desktop Linux engine)"
}
function Get-UvVersion([string]$Executable) {
    if (-not $Executable) { return $null }
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $Executable --version 2>$null)
        if ($LASTEXITCODE -eq 0 -and $output.Count -gt 0 -and $output[0] -match '^uv (\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    } catch { return $null }
    finally { $ErrorActionPreference = $previous }
    return $null
}
function Install-KitUv {
    # A pre-existing, older uv is not upgraded or replaced. Use a verified,
    # versioned PyPI wheel in the kit runtime instead, without Python or WinGet.
    $pin = $Manifest.uvBootstrap
    $dest = Join-Path $Runtime "uv\$($pin.version)"
    $exe = Join-Path $dest 'uv.exe'
    if (Test-Path -LiteralPath $exe) {
        if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $pin.exeSha256) { throw "Unexpected existing kit uv binary; back it up and remove it manually: $exe" }
        return $exe
    }
    $scratch = Join-Path $env:TEMP ("mcpkit-uv-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    try {
        $zip = Join-Path $scratch 'uv-wheel.zip'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $pin.wheelUrl -OutFile $zip -UseBasicParsing
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $pin.wheelSha256) { throw 'The downloaded uv wheel did not match its pinned SHA-256.' }
        $expanded = Join-Path $scratch 'expanded'
        Expand-Archive -LiteralPath $zip -DestinationPath $expanded
        $source = Join-Path $expanded "uv-$($pin.version).data\scripts\uv.exe"
        if (-not (Test-Path -LiteralPath $source) -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $pin.exeSha256) { throw 'The downloaded uv wheel did not contain the expected executable.' }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        [IO.File]::Copy($source, $exe, $false)
    } finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
    return $exe
}
function Find-VisualCpp {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { return $false }
    $location = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($location | Out-String)))
}
function Ensure-VisualCpp {
    if (Find-VisualCpp) { Ok 'Visual C++ build tools found'; return }
    $install = $InstallBuildTools.IsPresent
    if (-not $NonInteractive -and -not $install) {
        Write-KitWarn 'simple-files-vectorstore needs Visual C++ Build Tools (multi-GB download and possibly UAC).'
        $answer = Read-Host 'Install the Visual Studio 2022 C++ workload now? (Y/n)'
        $install = $answer -notmatch '^[Nn]'
    }
    if (-not $install) { throw 'C++ build tools were not installed. Rerun with -InstallBuildTools or install the Desktop C++ workload.' }
    Install-Winget 'Microsoft.VisualStudio.2022.BuildTools' @('--override', '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended')
    if (-not (Find-VisualCpp)) { throw 'Visual C++ workload not detected. If Build Tools were already installed, add the Desktop C++ workload in Visual Studio Installer, then retry.' }
}
function Find-Everything {
    $exe = Find-Application 'Everything.exe'
    if ($exe) { return $exe }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Everything\Everything.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Everything\Everything.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Everything\Everything.exe')
    )
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
    return $null
}
function Install-EverythingSdk {
    $destDir = Join-Path $Runtime 'everything-sdk'
    $dll = Join-Path $destDir 'Everything64.dll'
    $settingsFile = Join-Path $BaseDir 'config\local-settings.json'
    $configuredDll = (Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json).everythingSdkPath
    if ($configuredDll -and (Test-Path -LiteralPath $configuredDll -PathType Leaf)) { Ok 'Configured Everything SDK already present'; return }
    if ($configuredDll -and $configuredDll -ne $dll) { throw "The configured Everything SDK DLL is missing: $configuredDll. Restore it or update everythingSdkPath before retrying." }
    if (Test-Path -LiteralPath $dll) { Ok 'Everything SDK already present'; return }
    $scratch = Join-Path $env:TEMP ("mcpkit-sdk-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    try {
        $zip = Join-Path $scratch 'Everything-SDK.zip'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri 'https://www.voidtools.com/Everything-SDK.zip' -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $scratch 'expanded')
        $files = @(Get-ChildItem -LiteralPath (Join-Path $scratch 'expanded') -Filter 'Everything64.dll' -Recurse -File)
        if ($files.Count -ne 1) { throw 'The official SDK archive did not contain exactly one Everything64.dll.' }
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Copy-Item -LiteralPath $files[0].FullName -Destination $dll
        Ok 'Everything SDK installed'
    } finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($env:OS -ne 'Windows_NT' -or [IntPtr]::Size -ne 8) { throw 'Use 64-bit PowerShell on Windows 10 or 11.' }
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'This installer currently targets Windows x64; ARM64 native dependencies have not been verified.' }

$originalPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
$originalNpmPython = [Environment]::GetEnvironmentVariable('npm_config_python', 'Process')
$originalNodeGypPython = [Environment]::GetEnvironmentVariable('NODE_GYP_FORCE_PYTHON', 'Process')
$originalSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
try {
Step 'Private kit directories'
Protect-PrivateDirectory $PrivateDir
Protect-PrivateDirectory (Join-Path $BaseDir 'logs')
Protect-PrivateDirectory $Runtime
Refresh-Path

if ($MetaMcpOnly) {
    if (-not (Test-Path -LiteralPath (Join-Path $BaseDir 'config\local-settings.json') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $PrivateDir 'secrets.json') -PathType Leaf)) {
        throw 'The native LOCAL stack is not initialized. Run install-local.ps1 without -MetaMcpOnly first.'
    }
    # Do not reinstall npm/Python packages or stop an already-running gateway.
    Ensure-GitPrerequisite
    Ensure-DockerPrerequisite
    Step 'Starting local MetaMCP and connecting existing Windows servers'
    Invoke-Runner 'start'
    Ok 'MetaMCP is running. Shared Windows groups are initialized automatically; register in the UI and create an API key.'
    exit 0
}

Step 'Preparing the kit for updates'
# Windows may lock running executables and packages. Stop only this kit's
# authenticated gateway before touching its runtimes; never kill a port owner.
Invoke-Runner 'gateway-stop'

Ensure-GitPrerequisite
try { Ensure-DockerPrerequisite } catch { Fail "Docker Desktop: $($_.Exception.Message)" }

Step 'Node.js bootstrap'
$nodeDir = Join-Path $Runtime 'node'
$node = Join-Path $nodeDir 'node_modules\node\bin\node.exe'
$npmCli = Join-Path $nodeDir 'node_modules\npm\bin\npm-cli.js'
if (-not ((Test-Path -LiteralPath $node) -and (Test-Path -LiteralPath $npmCli))) {
    $systemNode = Find-Application 'node.exe'
    $systemNpm = Find-Application 'npm.cmd'
    if (-not $systemNode -or -not $systemNpm) {
        Install-Winget 'OpenJS.NodeJS.LTS'
        $systemNode = Find-Application 'node.exe'
        $systemNpm = Find-Application 'npm.cmd'
    }
    if (-not $systemNode -or -not $systemNpm) { throw 'Node.js/npm could not be found. Reopen PowerShell and retry.' }
    $npmDir = Split-Path -Parent $systemNpm
    $bootstrapNpmCli = Join-Path $npmDir 'node_modules\npm\bin\npm-cli.js'
    $siblingNode = Join-Path $npmDir 'node.exe'
    $bootstrapNode = if ((Test-Path -LiteralPath $bootstrapNpmCli -PathType Leaf) -and (Test-Path -LiteralPath $siblingNode -PathType Leaf)) { $siblingNode } else { $systemNode }
    $bootstrapArch = (& $bootstrapNode -p 'process.arch')
    if ($LASTEXITCODE -ne 0 -or $bootstrapArch -ne 'x64') { throw 'Install a 64-bit Node.js/npm bootstrap and retry; the existing global installation was not changed.' }
    New-Item -ItemType Directory -Path $nodeDir -Force | Out-Null
    $bootstrapArgs = @('install', '--prefix', $nodeDir, '--no-audit', '--no-fund', "node@$($Manifest.nodeVersion)", "npm@$($Manifest.npmVersion)")
    if (Test-Path -LiteralPath $bootstrapNpmCli -PathType Leaf) {
        # The standard Node installer exposes this JS next to npm.cmd. Calling
        # it directly avoids cmd.exe reinterpreting characters in profile paths.
        Invoke-Native $bootstrapNode (@($bootstrapNpmCli) + $bootstrapArgs)
    } else {
        # Retain compatibility with nonstandard Node managers that only expose
        # an npm.cmd shim; the user's installation is never upgraded in place.
        Invoke-Native $systemNpm $bootstrapArgs
    }
}
if (-not ((Test-Path -LiteralPath $node) -and (Test-Path -LiteralPath $npmCli))) { throw 'The isolated Node.js/npm runtime was not created.' }
$env:Path = "$(Split-Path -Parent $node);$env:Path"
$nodeVersion = (& $node --version)
if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v24\.') { throw "Expected the kit Node.js 24 runtime, got $nodeVersion." }
$nodeArch = (& $node -p 'process.arch')
if ($LASTEXITCODE -ne 0 -or $nodeArch -ne 'x64') { throw 'The isolated Node runtime is not x64. Install a 64-bit Node.js bootstrap, back up and remove only runtime\node, then retry.' }
Ok "Isolated Node.js $nodeVersion ($nodeArch)"

Step 'Configuration'
Invoke-Runner 'init'

Step 'uv and Python interpreters'
$uv = Find-Application 'uv.exe'
$uvVersion = Get-UvVersion $uv
if (-not $uvVersion -or $uvVersion -lt [version]'0.9.0') {
    if ($uv) { Note "Existing uv is missing required Python 3.14 support; it will be left unchanged: $uv" }
    $uv = Install-KitUv
    $uvVersion = Get-UvVersion $uv
}
if (-not $uvVersion -or $uvVersion -lt [version]'0.9.0') { throw 'Could not start a compatible uv executable.' }
Ok "uv $uvVersion`: $uv"
function Find-Python([string]$Version) {
    # A system/uv-managed interpreter is preferred over a transient activated
    # venv. uv writes UTF-8, but Windows PowerShell 5.1 otherwise decodes native
    # output using the console code page, corrupting non-ASCII profile paths.
    # Decode only this subprocess explicitly, without changing the user's console.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $uv
    $start.Arguments = "python find --system --no-project --no-python-downloads cpython-$Version-windows-x86_64"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start uv to find Python.' }
        # Drain stderr concurrently so a verbose failure cannot block the child.
        $stderr = $process.StandardError.ReadToEndAsync()
        $found = $process.StandardOutput.ReadToEnd() -split '\r?\n'
        $process.WaitForExit()
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -eq 0 -and $found.Count -gt 0 -and (Test-Path -LiteralPath $found[0])) { return $found[0] }
        return $null
    } finally { $process.Dispose() }
}
$pythons = @{}
foreach ($version in @($Manifest.pythonVersion, $Manifest.windowsMcpPythonVersion) | Select-Object -Unique) {
    $python = Find-Python $version
    if (-not $python) {
        # Do not register or put the additional interpreter on the user's PATH.
        Invoke-Native $uv @('python', 'install', '--no-bin', '--no-registry', "cpython-$version-windows-x86_64")
        $python = Find-Python $version
    }
    if (-not $python) { throw "uv could not locate Python $version." }
    $pythons[$version] = $python
    Ok "Python $version`: $python"
}
$env:npm_config_python = $pythons[$Manifest.pythonVersion]
# NODE_GYP_FORCE_PYTHON has higher priority than npm_config_python. Override it
# only during installation so an inherited incompatible Python cannot break a
# native addon build; the original value is restored below.
$env:NODE_GYP_FORCE_PYTHON = $pythons[$Manifest.pythonVersion]

Step 'Native Windows applications'
if (-not $SkipEverything) {
    try {
        $everything = Find-Everything
        if (-not $everything) { Install-Winget 'voidtools.Everything'; $everything = Find-Everything }
        if (-not $everything) { throw 'Everything executable not found after installation.' }
        if (-not (Get-Process -Name 'Everything' -ErrorAction SilentlyContinue)) { Start-Process -FilePath $everything -ArgumentList '-startup' | Out-Null }
        Install-EverythingSdk
        Note 'Everything must be running and its index/service must be ready for file searches.'
    } catch { Fail "Everything: $($_.Exception.Message)" }
} else { Note 'Everything was explicitly skipped; its server may be unavailable.' }

Step 'Node MCP packages'
foreach ($group in @('core', 'codebase', 'vectorstore')) {
    $folder = Join-Path $Runtime "npm\$group"
    try {
        if ($group -eq 'vectorstore') { Ensure-VisualCpp }
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $packageFile = Join-Path $folder 'package.json'
        if (-not (Test-Path -LiteralPath $packageFile)) {
            # The upstream transformers package pins an obsolete sharp that
            # downloads binaries from GitHub. The compatible 0.33 release uses
            # npm platform packages and works with the isolated Node 24 runtime.
            $initial = if ($group -eq 'vectorstore') { '{"private":true,"overrides":{"@xenova/transformers":{"sharp":"0.33.5"}}}' } else { '{"private":true}' }
            [IO.File]::WriteAllText($packageFile, $initial, (New-Object Text.UTF8Encoding($false)))
        }
        $packages = @($Manifest.npmGroups.$group)
        Invoke-Native $node (@($npmCli, 'install', '--prefix', $folder, '--no-audit', '--no-fund', '--save-exact') + $packages)
        Ok "npm group: $group"
    } catch { Fail "npm group $group`: $($_.Exception.Message)" }
}

Step 'Python MCP packages (isolated environments)'
foreach ($package in $Manifest.pythonPackages) {
    $venv = Join-Path $Runtime "python\$($package.name)"
    $venvPython = Join-Path $venv 'Scripts\python.exe'
    try {
        $requiredVersion = if ($package.name -eq 'windows-mcp') { $Manifest.windowsMcpPythonVersion } else { $Manifest.pythonVersion }
        if (-not (Test-Path -LiteralPath $venvPython)) {
            # uv can clear an existing incomplete venv non-interactively. Never
            # let a retry erase a directory whose contents may be user data.
            if (Test-Path -LiteralPath $venv) { throw "Existing environment has no Scripts\python.exe. Back it up and remove it manually before retrying: $venv" }
            Invoke-Native $uv @('venv', '--python', $pythons[$requiredVersion], $venv)
        }
        # Windows PowerShell 5.1 strips embedded double quotes when passing
        # native arguments. Keep the Python probe free of double quotes so the
        # version and architecture check also works in the built-in shell.
        $actualVersion = (& $venvPython -c "import sys,struct;print('%s.%s-%s'%(*sys.version_info[:2],struct.calcsize('P')*8))")
        if ($LASTEXITCODE -ne 0 -or $actualVersion -ne "$requiredVersion-64") {
            throw "Existing kit environment uses Python $actualVersion instead of $requiredVersion-64. Back it up and remove this environment before retrying: $venv"
        }
        Invoke-Native $uv @('pip', 'install', '--python', $venvPython, $package.spec)
        $exe = Join-Path $venv "Scripts\$($package.executable).exe"
        if (-not (Test-Path -LiteralPath $exe)) { throw "Expected entry point $exe was not installed." }
        Ok $package.name
    } catch { Fail "Python package $($package.name)`: $($_.Exception.Message)" }
}

Step 'Playwright Chromium'
if (-not $SkipBrowserDownload) {
    try {
        $playwright = Join-Path $Runtime 'npm\core\node_modules\@playwright\mcp\cli.js'
        if (-not (Test-Path -LiteralPath $playwright)) { throw 'Playwright MCP package is missing.' }
        Invoke-Native $node @($playwright, 'install-browser', 'chromium')
        Ok 'Playwright Chromium installed'
    } catch { Fail "Playwright browser: $($_.Exception.Message)" }
} else { Note 'Browser download was explicitly skipped; Playwright may need a browser.' }

# The long-lived gateway should inherit the user's original environment, not
# this installer's temporary node-gyp selection.
[Environment]::SetEnvironmentVariable('npm_config_python', $originalNpmPython, 'Process')
[Environment]::SetEnvironmentVariable('NODE_GYP_FORCE_PYTHON', $originalNodeGypPython, 'Process')
Step 'Starting LOCAL servers and Docker Desktop MetaMCP'
# Even if one native server fails, the runner still starts MetaMCP and
# registers the other servers, then reports the incomplete status.
try { Invoke-Runner 'start' }
catch { Fail "LOCAL stack: $($_.Exception.Message)" }

Write-KitHeader 'Windows LOCAL configuration'
Write-KitInfo "Settings: $BaseDir\config\local-settings.json"
Write-KitInfo "Secrets:  $PrivateDir\secrets.json (keep private)"
Write-KitInfo 'MetaMCP: register in the UI and create an API key. Shared server groups are set up automatically. Disable signup yourself in MetaMCP Settings.'
Write-KitInfo 'Commands: .\windows\run-local.ps1 status | logs | restart | stop | ports'
Write-KitInfo 'Change existing MetaMCP ports: .\windows\run-local.ps1 set-ports -WebPort 13008 -BackendPort 13009'
Note 'Obsidian requires its Local REST API plugin and key; the server waits until configured.'
if ($Failures.Count -gt 0) {
    Write-KitError 'Installation is incomplete. Fix the errors above and rerun this script; existing configuration and data are preserved.'
    exit 1
}
Ok 'Installation completed. Open local MetaMCP and check server-specific prerequisites as described above.'
} finally {
    # Restore the caller's PATH, node-gyp Python and TLS protocol settings.
    [Environment]::SetEnvironmentVariable('Path', $originalPath, 'Process')
    [Environment]::SetEnvironmentVariable('npm_config_python', $originalNpmPython, 'Process')
    [Environment]::SetEnvironmentVariable('NODE_GYP_FORCE_PYTHON', $originalNodeGypPython, 'Process')
    [Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol
}
