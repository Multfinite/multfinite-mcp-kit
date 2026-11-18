#Requires -Version 5.1
<#
.SYNOPSIS
    Keeps a WSL 2 distribution running so its systemd user services stay up.
.DESCRIPTION
    WSL stops a distribution when the last session ends, which also stops Docker
    and every container started by the kit. -Ensure starts a single holder
    session only when the distribution is stopped, so it is safe to run from a
    repeating watchdog task. -Hold runs the holder loop in the foreground and
    restarts the distribution after `wsl --shutdown` or a crashed session.
.PARAMETER Distribution
    Distribution name exactly as shown by `wsl --list --quiet`.
.PARAMETER Hold
    Run the restart loop in the foreground instead of a single ensure pass.
.PARAMETER RetrySeconds
    Delay between attempts in -Hold mode.
.EXAMPLE
    .\windows\wsl-keepalive.ps1 -Distribution Debian -Ensure
.EXAMPLE
    .\windows\wsl-keepalive.ps1 -Distribution Debian -Hold
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Distribution = 'Debian',
    [switch]$Ensure,
    [switch]$Hold,
    [ValidateRange(1, 3600)][int]$RetrySeconds = 10
)
$ErrorActionPreference = 'Stop'
if ($Ensure -and $Hold) { throw 'Choose either -Ensure or -Hold.' }
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
if ([string]::IsNullOrWhiteSpace($Distribution)) { throw 'Distribution name is required.' }
$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
if (-not (Test-Path -LiteralPath $wsl -PathType Leaf)) { throw "wsl.exe was not found at $wsl." }

function Get-RunningDistributions {
    # wsl.exe writes UTF-16; Windows PowerShell 5.1 decodes it as ANSI and leaves
    # NUL bytes between characters, so strip them before splitting lines.
    $text = (& $wsl --list --running --quiet 2>$null) -join "`n"
    if (-not $text) { return @() }
    return @(($text -replace "`0", '') -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Start-WslHolder {
    Start-Process -FilePath $wsl -ArgumentList @('-d', $Distribution, '--exec', 'sleep', 'infinity') -WindowStyle Hidden | Out-Null
}

if ($Hold) {
    while ($true) {
        & $wsl -d $Distribution --exec sleep infinity
        Start-Sleep -Seconds $RetrySeconds
    }
}

if ((Get-RunningDistributions) -contains $Distribution) {
    Write-Host "$Distribution is already running; nothing was started."
    exit 0
}
Start-WslHolder
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    Start-Sleep -Seconds 1
    if ((Get-RunningDistributions) -contains $Distribution) {
        Write-Host "Started $Distribution and its registered user services."
        exit 0
    }
}
throw "$Distribution did not start within 20 seconds."
