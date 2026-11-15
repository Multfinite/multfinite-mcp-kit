#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)][ValidateSet('start','stop','restart','status','logs','register-service','unregister-service')][string]$Command = 'start',
    [Parameter(Position=1)][string]$Directory = $(if ($env:MCPKIT_LOCAL_DIR) { $env:MCPKIT_LOCAL_DIR } elseif ($env:MCP_LOCAL_DIR) { $env:MCP_LOCAL_DIR } else { Join-Path $env:USERPROFILE 'mcp-kit\local' }),
    [Parameter(Position=2)][string]$Server = ''
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
$base = [IO.Path]::GetFullPath($Directory)
# Unregister must still be possible after the LOCAL directory was removed.
if ($Command -ne 'unregister-service') { Assert-IndependentWindowsLocal $base }
$runner = Join-Path $Here 'run-local.ps1'
switch ($Command) {
    'start'                { $forward = @('gateway-start') }
    'stop'                 { $forward = @('gateway-stop') }
    'restart'              { $forward = @('gateway-restart') }
    'status'               { $forward = @('gateway-status') }
    'logs'                 { $forward = @('logs'); if ($Server) { $forward += $Server } }
    'register-service'     { $forward = @('register-service') }
    'unregister-service'   { $forward = @('unregister-service') }
}
$forward += @('-Directory', $base)
& $runner @forward
$code = $LASTEXITCODE
exit $code
