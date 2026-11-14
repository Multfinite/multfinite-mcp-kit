# Helpers for independent Docker projects. Windows PowerShell 5.1 compatible.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'local-common.ps1')
function Get-IndependentNode([string]$PreferredLocalDirectory = '') {
    $node = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($node) {
        $version = & $node.Source --version
        if ($LASTEXITCODE -eq 0 -and $version -match '^v(\d+)\.' -and [int]$Matches[1] -ge 20) { return $node.Source }
    }
    # Read an isolated runtime if already installed; never modify an old LOCAL.
    $bases = @()
    if ($PreferredLocalDirectory) { $bases += $PreferredLocalDirectory }
    if ($env:MCPKIT_LOCAL_DIR) { $bases += $env:MCPKIT_LOCAL_DIR }
    $bases += (Join-Path $env:USERPROFILE 'mcp-kit\local')
    if ($env:MCP_LOCAL_DIR) { $bases += $env:MCP_LOCAL_DIR }
    $bases += (Join-Path $env:USERPROFILE 'mcp-local')
    foreach ($base in $bases) {
        $isolated = Join-Path $base 'runtime\node\node_modules\node\bin\node.exe'
        if (Test-Path -LiteralPath $isolated -PathType Leaf) {
            $version = & $isolated --version
            if ($LASTEXITCODE -eq 0 -and $version -match '^v(\d+)\.' -and [int]$Matches[1] -ge 20) { return $isolated }
        }
    }
    throw 'Node.js 20 or newer is required. Install Node.js or the separate LOCAL servers, then reopen PowerShell.'
}
function Initialize-IndependentWindowsLocal([string]$Directory) {
    # New LOCAL installs are isolated from the legacy mcp-local stack. Never
    # adopt an arbitrary nonempty directory or a linked MetaMCP installation.
    $private = Join-Path $Directory 'config\private'
    $marker = Join-Path $private 'independent-windows-kit.json'
    if (Test-Path -LiteralPath $Directory) {
        $item = Get-Item -LiteralPath $Directory -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The LOCAL installation directory must be a real directory, not a link.' }
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            $privateItem = Get-Item -LiteralPath $private -Force
            $markerItem = Get-Item -LiteralPath $marker -Force
            if (($privateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The LOCAL marker and private directory must not be links.' }
            $state = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($state.version -ne 1 -or $state.kind -ne 'windows-local' -or
                -not [string]::Equals([string]$state.base, $Directory, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Invalid or relocated independent LOCAL marker; existing files were preserved.'
            }
            if (Test-Path -LiteralPath (Join-Path $private 'metamcp-state.json')) { throw 'This directory contains a legacy linked MetaMCP; choose a different directory.' }
            return
        }
        if (@(Get-ChildItem -LiteralPath $Directory -Force).Count -gt 0) {
            throw 'LOCAL directory is not empty and has no independent marker. Choose an empty directory; existing files were not changed.'
        }
    }
    Protect-PrivateDirectory $private
    $json = (ConvertTo-Json -Compress -InputObject ([ordered]@{ version = 1; kind = 'windows-local'; base = $Directory })) + "`n"
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    $stream = [IO.File]::Open($marker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
}
function Assert-IndependentWindowsLocal([string]$Directory) {
    $private = Join-Path $Directory 'config\private'
    $marker = Join-Path $private 'independent-windows-kit.json'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'Independent LOCAL marker not found; install the independent servers first.' }
    foreach ($itemPath in @($Directory, $private, $marker)) {
        $item = Get-Item -LiteralPath $itemPath -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The LOCAL directory, marker and private directory must not be links.' }
    }
    $state = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.version -ne 1 -or $state.kind -ne 'windows-local' -or
        -not [string]::Equals([string]$state.base, $Directory, [StringComparison]::OrdinalIgnoreCase) -or
        (Test-Path -LiteralPath (Join-Path $Directory 'config\private\metamcp-state.json'))) {
        throw 'Invalid, relocated or legacy-linked LOCAL directory; existing files were not changed.'
    }
}
function Ensure-IndependentDocker([switch]$NoStart) {
    $docker = Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $docker) {
        $standard = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'
        if (Test-Path -LiteralPath $standard -PathType Leaf) {
            $env:Path = (Split-Path -Parent $standard) + [IO.Path]::PathSeparator + $env:Path
            $docker = Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        }
    }
    if (-not $docker) { throw 'Docker Desktop is not installed or its CLI is unavailable. Install Docker Desktop and complete its first-run setup.' }
    if ($env:DOCKER_HOST -or $env:DOCKER_CONTEXT) { throw 'Unset DOCKER_HOST and DOCKER_CONTEXT; independent projects use only local Docker Desktop.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    $attempted = $false
    do {
        $old = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $endpoint = @(& $docker.Source context inspect desktop-linux --format '{{.Endpoints.docker.Host}}' 2>$null)
            $contextOk = $LASTEXITCODE -eq 0
            if ($contextOk -and (($endpoint -join '').Trim() -notmatch '^npipe:////[.]/pipe/dockerDesktopLinuxEngine$')) {
                throw 'desktop-linux does not point to the local Docker Desktop Linux engine.'
            }
            if ($contextOk) {
                $info = @(& $docker.Source --context desktop-linux info --format '{{.OperatingSystem}}|{{.OSType}}' 2>$null)
                if ($LASTEXITCODE -eq 0) {
                    if (($info -join '').Trim() -ne 'Docker Desktop|linux') { throw 'Docker Desktop must use Linux containers.' }
                    & $docker.Source --context desktop-linux compose version 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose plugin is unavailable.' }
                    return
                }
            }
        } finally { $ErrorActionPreference = $old }
        if ($NoStart) { throw 'Local Docker Desktop is not running. No other context was used.' }
        if (-not $attempted) {
            $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
            if ((Test-Path -LiteralPath $desktop -PathType Leaf) -and -not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
                Write-KitInfo 'Starting Docker Desktop; complete first-run setup if prompted.'
                Start-Process -FilePath $desktop | Out-Null
            } else { Write-KitInfo 'Waiting for the local Docker Desktop Linux engine.' }
            $attempted = $true
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Docker Desktop did not become ready. Complete its setup/reboot and retry.'
}
function Protect-NewIndependentDirectory([string]$Directory) {
    if (Test-Path -LiteralPath $Directory) {
        $item = Get-Item -LiteralPath $Directory -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The installation directory must be a real directory, not a link.' }
        if (Test-Path -LiteralPath (Join-Path $Directory '.mcpkit\state.json') -PathType Leaf) { return }
        if (@(Get-ChildItem -LiteralPath $Directory -Force).Count -gt 0) { throw 'Directory is not empty and has no independent kit state; it was not changed.' }
    }
    Protect-PrivateDirectory $Directory
}
