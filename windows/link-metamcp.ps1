#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)][string]$SourceMetaDirectory,
    [Parameter(Mandatory=$true, Position=1)][string]$TargetMetaDirectory,
    [string]$Endpoint,
    [switch]$Unlink
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
if ($Unlink -and $Endpoint) { throw '-Endpoint cannot be combined with -Unlink.' }
if (-not $Unlink -and -not $Endpoint) { throw 'Pass -Endpoint NAME or a full /metamcp/NAME/mcp URL from the source MetaMCP.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
$node = Get-IndependentNode
Ensure-IndependentDocker
$action = if ($Unlink) { 'unlink-metamcp' } else { 'link-metamcp' }
$stackArgs = @($action, '--dir', [IO.Path]::GetFullPath($SourceMetaDirectory), '--peer-dir', [IO.Path]::GetFullPath($TargetMetaDirectory), '--expect-type', 'meta')
if (-not $Unlink) { $stackArgs += @('--endpoint', $Endpoint) }
& $node (Join-Path $Here '..\common\stack.mjs') @stackArgs
exit $LASTEXITCODE
