#Requires -Version 5.1
<#
.SYNOPSIS
    Register this machine's native LOCAL MCP servers in a selected MetaMCP.
.DESCRIPTION
    Supports both the current native-only install-local.ps1 directory and the
    independent install-servers.ps1 directory. New records use the same names
    and per-server namespace/endpoint layout as GLOBAL. The MetaMCP host must
    be able to reach the supplied LOCAL gateway URL.
.EXAMPLE
    .\windows\connect-local.ps1
    .\windows\connect-local.ps1 "$env:USERPROFILE\mcp-local"
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Directory = $(if ($env:MCPKIT_LOCAL_DIR) { $env:MCPKIT_LOCAL_DIR } elseif ($env:MCP_LOCAL_DIR) { $env:MCP_LOCAL_DIR } elseif ((Test-Path -LiteralPath (Join-Path $env:USERPROFILE 'mcp-local\config\local-settings.json')) -and -not (Test-Path -LiteralPath (Join-Path $env:USERPROFILE 'mcp-local\config\private\metamcp-state.json'))) { Join-Path $env:USERPROFILE 'mcp-local' } else { Join-Path $env:USERPROFILE 'mcp-kit\local' })
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
$base = [IO.Path]::GetFullPath($Directory)
# The registrar validates either the independent LOCAL marker or the native-
# only config created by install-local.ps1. It refuses a linked legacy MetaMCP.
$node = Get-IndependentNode $base
& $node (Join-Path $Here '..\common\register.mjs') local --dir $base
exit $LASTEXITCODE
