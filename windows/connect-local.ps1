#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Directory = $(if ($env:MCPKIT_LOCAL_DIR) { $env:MCPKIT_LOCAL_DIR } else { Join-Path $env:USERPROFILE 'mcp-kit\local' })
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
$base = [IO.Path]::GetFullPath($Directory)
Assert-IndependentWindowsLocal $base
$node = Get-IndependentNode $base
& $node (Join-Path $Here '..\common\register.mjs') local --dir $base
exit $LASTEXITCODE
