#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)][ValidateSet('start','stop','status','logs','check-env','apply','remove')][string]$Command,
    [Parameter(Mandatory=$true, Position=1)][string]$Directory,
    [switch]$DeleteVolumes
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
if ($DeleteVolumes -and $Command -ne 'remove') { throw 'DeleteVolumes is only valid for remove.' }
$node = Get-IndependentNode
if ($Command -eq 'start') { Ensure-IndependentDocker } else { Ensure-IndependentDocker -NoStart }
$argsForNode = @((Join-Path $Here '..\common\stack.mjs'), $Command, '--dir', [IO.Path]::GetFullPath($Directory))
if ($DeleteVolumes) { $argsForNode += '--delete-volumes' }
& $node @argsForNode
exit $LASTEXITCODE
