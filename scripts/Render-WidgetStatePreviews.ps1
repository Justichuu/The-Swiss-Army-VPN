# SPDX-License-Identifier: GPL-3.0-only
# Draws every remaining widget state with the live executable's --preview-state
# renderer. Does not invent a second UI. Deleted extras stay gone.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$WidgetExecutable,

    [string]$OutputDirectory = '',

    [string]$StatesPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

$repositoryRoot = Get-NormalizedPath (Join-Path $PSScriptRoot '..')
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot 'artifacts\widget-previews'
}
else {
    $OutputDirectory = Get-NormalizedPath $OutputDirectory
}
if ([string]::IsNullOrWhiteSpace($StatesPath)) {
    $StatesPath = Join-Path $repositoryRoot 'docs\media\widget-states\states.json'
}
else {
    $StatesPath = Get-NormalizedPath $StatesPath
}

$WidgetExecutable = Get-NormalizedPath $WidgetExecutable
if (-not (Test-Path -LiteralPath $WidgetExecutable -PathType Leaf)) {
    throw "Widget executable is missing: $WidgetExecutable"
}
if (-not (Test-Path -LiteralPath $StatesPath -PathType Leaf)) {
    throw "Widget state list is missing: $StatesPath"
}

$catalog = Get-Content -LiteralPath $StatesPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $catalog.states -or @($catalog.states).Count -lt 1) {
    throw "Widget state list has no states: $StatesPath"
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$pngSignature = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
foreach ($state in @($catalog.states)) {
    $name = [string]$state.name
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'A widget state is missing its name.'
    }
    $outputPath = Join-Path $OutputDirectory ($name + '.png')
    if (Test-Path -LiteralPath $outputPath) {
        Remove-Item -LiteralPath $outputPath -Force
    }

    $process = Start-Process -FilePath $WidgetExecutable `
        -ArgumentList @('--preview-state', $name, '--preview-output', $outputPath) `
        -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw "Preview '$name' exited $($process.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw "Preview '$name' did not write $outputPath"
    }

    $bytes = [IO.File]::ReadAllBytes($outputPath)
    if ($bytes.Length -lt 8000) {
        throw "Preview '$name' is too small to be a widget window ($($bytes.Length) bytes)."
    }
    for ($i = 0; $i -lt $pngSignature.Length; $i++) {
        if ($bytes[$i] -ne $pngSignature[$i]) {
            throw "Preview '$name' is not a PNG."
        }
    }
}

Write-Output "Rendered $(@($catalog.states).Count) widget states to $OutputDirectory"
