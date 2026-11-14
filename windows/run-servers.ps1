#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)][ValidateSet('start','stop','restart','status','logs')][string]$Command = 'start',
    [Parameter(Position=1)][string]$Server = '',
    [string]$Directory = $(if ($env:MCPKIT_LOCAL_DIR) { $env:MCPKIT_LOCAL_DIR } else { Join-Path $env:USERPROFILE 'mcp-kit\local' })
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
$base = [IO.Path]::GetFullPath($Directory)
Assert-IndependentWindowsLocal $base
$runner = Join-Path $Here 'run-local.ps1'
$previousBase = $env:MCP_LOCAL_DIR
try {
    $env:MCP_LOCAL_DIR = $base
    switch ($Command) {
        'start'   { & $runner gateway-start }
        'stop'    { & $runner gateway-stop }
        'restart' { & $runner gateway-restart }
        'status'  { & $runner gateway-status }
        'logs'    { & $runner logs $Server }
    }
    $code = $LASTEXITCODE
} finally {
    [Environment]::SetEnvironmentVariable('MCP_LOCAL_DIR', $previousBase, 'Process')
}
exit $code
