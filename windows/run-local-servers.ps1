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
    'start'                { $runnerCommand = 'gateway-start' }
    'stop'                 { $runnerCommand = 'gateway-stop' }
    'restart'              { $runnerCommand = 'gateway-restart' }
    'status'               { $runnerCommand = 'gateway-status' }
    'logs'                 { $runnerCommand = 'logs' }
    'register-service'     { $runnerCommand = 'register-service' }
    'unregister-service'   { $runnerCommand = 'unregister-service' }
}
# run-local.ps1 has positional Server and GatewayPort parameters, so splat a
# hashtable; an array splat would bind the literal '-Directory' as a value.
$runnerArguments = @{ Command = $runnerCommand; Directory = $base }
if ($Command -eq 'logs' -and $Server) { $runnerArguments.Server = $Server }
& $runner @runnerArguments
$code = $LASTEXITCODE
exit $code
