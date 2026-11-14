#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Directory = (Join-Path $env:USERPROFILE 'mcp-kit\global'),
    [ValidateRange(0, 65535)][int]$Port = 0
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
$Directory = [IO.Path]::GetFullPath($Directory)
if (-not (Test-Path -LiteralPath (Join-Path $Directory '.mcpkit\state.json') -PathType Leaf) -and -not $Port) {
    $answer = Read-Host 'Loopback port for the new GLOBAL gateway (1-65535)'
    $parsed = 0
    if (-not [int]::TryParse($answer, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 65535) { throw 'A port between 1 and 65535 is required.' }
    $Port = $parsed
}
$node = Get-IndependentNode
Ensure-IndependentDocker
Protect-NewIndependentDirectory $Directory
$argsForNode = @((Join-Path $Here '..\common\stack.mjs'), 'init-global', '--dir', $Directory)
if ($Port) { $argsForNode += @('--port', [string]$Port) }
& $node @argsForNode
exit $LASTEXITCODE
