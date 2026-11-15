#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Directory = '',
    [ValidateRange(0, 65535)][int]$Port = 0,
    [string]$PublicUrl = ''
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
if (-not $Directory) {
    $default = Join-Path $env:USERPROFILE 'mcp-kit\metamcp\instance'
    $Directory = Read-Host "Instance directory [$default]"
    if (-not $Directory) { $Directory = $default }
}
$Directory = [IO.Path]::GetFullPath($Directory)
$state = Join-Path $Directory '.mcpkit\state.json'
if (-not (Test-Path -LiteralPath $state -PathType Leaf)) {
    if (-not $Port) {
        $answer = Read-Host 'Port for this new MetaMCP (1-65535)'
        $parsed = 0
        if (-not [int]::TryParse($answer, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 65535) { throw 'A port between 1 and 65535 is required.' }
        $Port = $parsed
    }
    if (-not $PublicUrl) { $PublicUrl = Read-Host 'Public HTTPS origin, or Enter for localhost' }
}
$node = Get-IndependentNode
if (-not (Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue)) { throw 'Git is required. Install Git and reopen PowerShell.' }
Ensure-IndependentDocker
Protect-NewIndependentDirectory $Directory
$argsForNode = @((Join-Path $Here '..\common\stack.mjs'), 'init-meta', '--dir', $Directory)
if ($Port) { $argsForNode += @('--port', [string]$Port) }
if ($PublicUrl) { $argsForNode += @('--app-url', $PublicUrl) }
& $node @argsForNode
exit $LASTEXITCODE
