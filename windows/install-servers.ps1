#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Directory = $(if ($env:MCPKIT_LOCAL_DIR) { $env:MCPKIT_LOCAL_DIR } else { Join-Path $env:USERPROFILE 'mcp-kit\local' }),
    [ValidateRange(1, 65535)][int]$Port = 13001,
    [switch]$NonInteractive,
    [switch]$InstallBuildTools,
    [switch]$SkipEverything,
    [switch]$SkipBrowserDownload
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
$base = [IO.Path]::GetFullPath($Directory)
Initialize-IndependentWindowsLocal $base
$previousBase = $env:MCP_LOCAL_DIR
try {
    $env:MCP_LOCAL_DIR = $base
    # Initialize create-only before the installer can start a gateway, so a
    # second independent LOCAL can choose a different port on its first run.
    & (Join-Path $Here 'run-local.ps1') init -GatewayPort $Port
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize independent LOCAL configuration.' }
    & (Join-Path $Here 'install-local.ps1') -ServersOnly -NonInteractive:$NonInteractive -InstallBuildTools:$InstallBuildTools -SkipEverything:$SkipEverything -SkipBrowserDownload:$SkipBrowserDownload
    $code = $LASTEXITCODE
} finally {
    [Environment]::SetEnvironmentVariable('MCP_LOCAL_DIR', $previousBase, 'Process')
}
exit $code
