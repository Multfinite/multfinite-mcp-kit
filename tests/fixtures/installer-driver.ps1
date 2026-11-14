# Run the real installer with synthetic tools and verify it restores the caller's environment.
param([string]$Installer)
$ErrorActionPreference = 'Stop'
# Emulate a non-UTF-8 Windows console. uv's UTF-8 output must still yield the
# real non-ASCII Python path, and the installer must leave this setting alone.
[Console]::OutputEncoding = [Text.Encoding]::ASCII
$beforeConsoleEncoding = [Console]::OutputEncoding
$beforePath = [Environment]::GetEnvironmentVariable('Path', 'Process')
$beforePython = [Environment]::GetEnvironmentVariable('npm_config_python', 'Process')
$beforeNodeGyp = [Environment]::GetEnvironmentVariable('NODE_GYP_FORCE_PYTHON', 'Process')
$beforeProtocol = [Net.ServicePointManager]::SecurityProtocol
if ($env:MCP_TEST_UV_WHEEL) {
    # Keep this test offline: substitute a synthetic wheel for the network
    # download and mark its fake POSIX executable runnable after extraction.
    function Invoke-WebRequest([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing) {
        Copy-Item -LiteralPath $env:MCP_TEST_UV_WHEEL -Destination $OutFile
    }
    function Expand-Archive([string]$LiteralPath, [string]$DestinationPath) {
        Microsoft.PowerShell.Archive\Expand-Archive -LiteralPath $LiteralPath -DestinationPath $DestinationPath
        & chmod +x (Join-Path $DestinationPath 'uv-0.13.8.data/scripts/uv.exe')
        if ($LASTEXITCODE -ne 0) { throw 'Unable to mark the synthetic uv executable runnable.' }
    }
}
try {
    & $Installer -NonInteractive -SkipEverything -SkipBrowserDownload
    $result = $LASTEXITCODE
} catch {
    Write-Host "Installer exception: $($_.Exception.Message)"
    $result = 1
}
if ([Environment]::GetEnvironmentVariable('Path', 'Process') -cne $beforePath -or
    [Environment]::GetEnvironmentVariable('npm_config_python', 'Process') -cne $beforePython -or
    [Environment]::GetEnvironmentVariable('NODE_GYP_FORCE_PYTHON', 'Process') -cne $beforeNodeGyp -or
    [Net.ServicePointManager]::SecurityProtocol -ne $beforeProtocol -or
    [Console]::OutputEncoding.CodePage -ne $beforeConsoleEncoding.CodePage) {
    Write-Host 'Installer leaked changes to the caller environment.'
    exit 42
}
exit $result
