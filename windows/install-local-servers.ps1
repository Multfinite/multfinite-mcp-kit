#Requires -Version 5.1
<# Windows spelling parallel to linux/install-local-servers.sh. #>
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Directory = $(if ($env:MCPKIT_LOCAL_DIR) { $env:MCPKIT_LOCAL_DIR } else { Join-Path $env:USERPROFILE 'mcp-kit\local' }),
    [Parameter(Position=1)][ValidateRange(1, 65535)][int]$Port = 13001,
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
& (Join-Path $Here 'install-local-server.ps1') -Directory $base -GatewayPort $Port `
    -NonInteractive:$NonInteractive -InstallBuildTools:$InstallBuildTools `
    -SkipEverything:$SkipEverything -SkipBrowserDownload:$SkipBrowserDownload
exit $LASTEXITCODE
