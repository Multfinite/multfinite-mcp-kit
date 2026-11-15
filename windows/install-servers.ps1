#Requires -Version 5.1
<# Compatibility name for independent LOCAL; use install-local-servers.ps1. #>
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
& (Join-Path $Here 'install-local-servers.ps1') $Directory $Port `
    -NonInteractive:$NonInteractive -InstallBuildTools:$InstallBuildTools `
    -SkipEverything:$SkipEverything -SkipBrowserDownload:$SkipBrowserDownload
exit $LASTEXITCODE
