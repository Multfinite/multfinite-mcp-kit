#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)][string]$MetaDirectory,
    [Parameter(Mandatory=$true, Position=1)][string]$PeerMetaDirectory,
    [switch]$Unlink
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
$node = Get-IndependentNode
Ensure-IndependentDocker
$action = if ($Unlink) { 'unlink-metamcp' } else { 'link-metamcp' }
& $node (Join-Path $Here '..\common\stack.mjs') $action --dir ([IO.Path]::GetFullPath($MetaDirectory)) --peer-dir ([IO.Path]::GetFullPath($PeerMetaDirectory)) --expect-type meta
exit $LASTEXITCODE
