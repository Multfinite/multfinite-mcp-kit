#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)][ValidateSet('start','stop','status','logs','check-env','apply','rebuild','remove')][string]$Command,
    [Parameter(Mandatory=$true, Position=1)][string]$Directory,
    [switch]$DeleteVolumes,
    [switch]$AllowLocalSource
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
if ($DeleteVolumes -and $Command -ne 'remove') { throw 'DeleteVolumes is only valid for remove.' }
if ($AllowLocalSource -and $Command -notin @('start','apply','rebuild')) { throw 'AllowLocalSource is only valid for start, apply and rebuild.' }
$node = Get-IndependentNode
if ($Command -in @('start','rebuild')) { Ensure-IndependentDocker } else { Ensure-IndependentDocker -NoStart }
$argsForNode = @((Join-Path $Here '..\common\stack.mjs'), $Command, '--dir', [IO.Path]::GetFullPath($Directory))
if ($DeleteVolumes) { $argsForNode += '--delete-volumes' }
if ($AllowLocalSource) { $argsForNode += '--allow-local-source' }
& $node @argsForNode
exit $LASTEXITCODE
