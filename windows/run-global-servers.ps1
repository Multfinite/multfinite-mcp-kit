#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)][ValidateSet('start','stop','status','logs','apply','remove','register-service','unregister-service')][string]$Command,
    [Parameter(Position=1)][string]$Directory = (Join-Path $env:USERPROFILE 'mcp-kit\global'),
    [Parameter(Position=2)][string]$Server = '',
    [switch]$DeleteVolumes
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'independent-common.ps1')
. (Join-Path $Here 'service-registration.ps1')
if ($DeleteVolumes -and $Command -ne 'remove') { throw 'DeleteVolumes is only valid for remove.' }
if ($Server -and $Command -ne 'logs') { throw 'Server is only valid for logs.' }
$Directory = [IO.Path]::GetFullPath($Directory)
if ($Command -in @('register-service','unregister-service')) {
    if ($Server -or $DeleteVolumes) { throw 'Service commands do not accept Server or DeleteVolumes.' }
    if ($Command -eq 'register-service') {
        $stateFile = Join-Path $Directory '.mcpkit\state.json'
        if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) { throw 'The independent GLOBAL installation is not initialized. Install it first.' }
        $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.version -ne 1 -or $state.type -ne 'global' -or -not [string]::Equals([string]$state.base, $Directory, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The selected directory is not a valid independent GLOBAL installation.'
        }
        Register-McpKitScheduledTask -Kind global -Directory $Directory -ScriptPath $MyInvocation.MyCommand.Path -StartArguments @('start', '-Directory', $Directory)
    } else {
        Unregister-McpKitScheduledTask -Kind global -Directory $Directory
    }
    exit 0
}
$node = Get-IndependentNode
if ($Command -in @('start','apply')) { Ensure-IndependentDocker } else { Ensure-IndependentDocker -NoStart }
$argsForNode = @((Join-Path $Here '..\common\stack.mjs'), $Command, '--dir', $Directory)
if ($DeleteVolumes) { $argsForNode += '--delete-volumes' }
if ($Server) { $argsForNode += @('--server', $Server) }
& $node @argsForNode
exit $LASTEXITCODE
