#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)][ValidateSet('start','stop','status','logs','apply','remove')][string]$Command,
    [Parameter(Position=1)][string]$Directory = (Join-Path $env:USERPROFILE 'mcp-kit\global'),
    [Parameter(Position=2)][string]$Server = '',
    [switch]$DeleteVolumes
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
if ($DeleteVolumes -and $Command -ne 'remove') { throw 'DeleteVolumes is only valid for remove.' }
if ($Server -and $Command -ne 'logs') { throw 'Server is only valid for logs.' }
$node = Get-IndependentNode
if ($Command -in @('start','apply')) { Ensure-IndependentDocker } else { Ensure-IndependentDocker -NoStart }
$argsForNode = @((Join-Path $Here '..\common\stack.mjs'), $Command, '--dir', [IO.Path]::GetFullPath($Directory))
if ($DeleteVolumes) { $argsForNode += '--delete-volumes' }
if ($Server) { $argsForNode += @('--server', $Server) }
& $node @argsForNode
exit $LASTEXITCODE
