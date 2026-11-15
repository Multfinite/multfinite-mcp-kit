#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)][string]$GlobalDirectory,
    [Parameter(Mandatory=$true, Position=1)][string]$MetaDirectory,
    [switch]$Unlink
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
$node = Get-IndependentNode
Ensure-IndependentDocker
$action = if ($Unlink) { 'unlink' } else { 'link' }
& $node (Join-Path $Here '..\common\stack.mjs') $action --dir ([IO.Path]::GetFullPath($GlobalDirectory)) --meta-dir ([IO.Path]::GetFullPath($MetaDirectory))
exit $LASTEXITCODE
