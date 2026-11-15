#Requires -Version 5.1
<# Compatibility wrapper; use run-local-servers.ps1 for the canonical CLI. #>
[CmdletBinding()]
param(
    [Parameter(Position=0)][ValidateSet('start','stop','restart','status','logs','register-service','unregister-service')][string]$Command = 'start',
    [Parameter(Position=1)][string]$Server = '',
    [string]$Directory = $(if ($env:MCPKIT_LOCAL_DIR) { $env:MCPKIT_LOCAL_DIR } elseif ($env:MCP_LOCAL_DIR) { $env:MCP_LOCAL_DIR } else { Join-Path $env:USERPROFILE 'mcp-kit\local' })
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$runner = Join-Path $Here 'run-local-servers.ps1'
& $runner $Command $Directory $Server
exit $LASTEXITCODE
