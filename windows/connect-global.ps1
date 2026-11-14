#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Directory = (Join-Path $env:USERPROFILE 'mcp-kit\global')
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
$node = Get-IndependentNode
& $node (Join-Path $Here '..\common\register.mjs') global --dir ([IO.Path]::GetFullPath($Directory))
exit $LASTEXITCODE
