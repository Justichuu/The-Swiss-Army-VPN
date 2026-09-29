# SPDX-License-Identifier: GPL-3.0-only
# Offline state and phase scrubber. It never opens the network.
[CmdletBinding()]
param(
    [string]$Source = '',
    [string]$OutputDirectory = '',
    [string]$ReportPath = '',
    [switch]$ScanOnly,
    [switch]$PhaseMap
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $PSCommandPath
$repositoryRoot = Split-Path -Parent $scriptRoot
$rulesPath = Join-Path $scriptRoot 'scrub-rules.json'
$pythonCore = Join-Path $scriptRoot 'scrub_core.py'

function Show-PhaseMap {
    @'
Swiss Army VPN - phases and colours

Eye
  green  #2CC478   shut   Hidden. Traffic is not observable.
  red    #E24448   open   Watched. Traffic can be seen.
  grey   #808694   half   Unknown. The app has not proven either.

Buttons
  green  #1B8B5D   connect / arm
  red    #B13F44   disconnect / unlock
  blue   #375990   apply / sign-in
  brown  #744E2E   clear credentials
  grey   #3F434C   disabled

Status
  green            protected
  red              blocked or leak risk
  blue             route / leak probe
  grey             monitor off

Scrubber phases
  collect -> classify -> redact -> verify -> witness -> report
  The witness is Justichuu's local check. If it is not here, the built-in checks still run. Ask later.
'@
}

if ($PhaseMap) {
    Show-PhaseMap
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Source)) {
    $Source = $repositoryRoot
}

$python = Get-Command python3, python -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $python) {
    throw 'Python is required for the scrubber on this machine. Install Python 3, or run tests/Test-StatePhaseScrubber.py where Python already exists.'
}

$arguments = @(
    $pythonCore
    '--source', $Source
)
if ($ScanOnly) { $arguments += '--scan-only' }
if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $arguments += '--output', $OutputDirectory
}
if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $arguments += '--report', $ReportPath
}

& $python.Source @arguments
exit $LASTEXITCODE
