# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.3.3',

    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Assert-FileExists {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required build input is missing: $Path"
    }
}

function Write-Utf8NoBomLines {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Lines
    )

    [IO.File]::WriteAllLines($Path, $Lines, [Text.UTF8Encoding]::new($false))
}

function New-ZipFromDirectory {
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $SourceDirectory,
        $DestinationPath,
        [IO.Compression.CompressionLevel]::Optimal,
        $false)
}

$repositoryRoot = Get-NormalizedPath (Join-Path $PSScriptRoot '..')
$OutputDirectory = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Join-Path $repositoryRoot 'artifacts'
}
else {
    $OutputDirectory
}
$sourceDirectory = Join-Path $repositoryRoot 'src'
$assetDirectory = Join-Path $repositoryRoot 'assets'
$installerDirectory = Join-Path $repositoryRoot 'installer'
$outputRoot = Get-NormalizedPath $OutputDirectory
$buildRoot = Join-Path $outputRoot ('.build-' + [guid]::NewGuid().ToString('N'))
$applicationName = "Switzerland VPN Distribution $Version"
$sourceName = "Switzerland VPN Source $Version"
$applicationStage = Join-Path $buildRoot $applicationName
$sourceStage = Join-Path $buildRoot $sourceName
$applicationZip = Join-Path $outputRoot ($applicationName + '.zip')
$sourceZip = Join-Path $outputRoot ($sourceName + '.zip')
$applicationChecksum = Join-Path $outputRoot ($applicationName + ' SHA256.txt')
$sourceChecksum = Join-Path $outputRoot ($sourceName + ' SHA256.txt')
$applicationOutput = Join-Path $outputRoot $applicationName

$sourceCode = Join-Path $sourceDirectory 'SwitzerlandVPN.cs'
$manifest = Join-Path $sourceDirectory 'SwitzerlandVPN.exe.manifest'
$installerSourceCode = Join-Path $sourceDirectory 'SwitzerlandVPN.Installer.cs'
$installerManifest = Join-Path $sourceDirectory 'SwitzerlandVPN.Installer.exe.manifest'
$unlockSourceCode = Join-Path $sourceDirectory 'SwitzerlandVPN.EmergencyUnlock.cs'
$unlockManifest = Join-Path $sourceDirectory 'SwitzerlandVPN.EmergencyUnlock.exe.manifest'
$installerScript = Join-Path $installerDirectory 'Programs\PowershellBackup\Install Switzerland VPN.ps1'
$icon = Join-Path $assetDirectory 'Switzerland VPN.ico'
$background = Join-Path $assetDirectory 'Switzerland VPN Background.png'
$iconPng = Join-Path $assetDirectory 'Switzerland VPN.png'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

foreach ($requiredFile in @(
    $sourceCode,
    $manifest,
    $installerSourceCode,
    $installerManifest,
    $unlockSourceCode,
    $unlockManifest,
    $icon,
    $background,
    $iconPng,
    $compiler,
    $installerScript
)) {
    Assert-FileExists $requiredFile
}

$escapedVersion = [regex]::Escape($Version)
$expectedAssemblyVersion = $Version + '.0'
$sourceText = Get-Content -LiteralPath $sourceCode -Raw
if ($sourceText -notmatch
    ('AssemblyVersion\("' + [regex]::Escape($expectedAssemblyVersion) + '"\)')) {
    throw "Source assembly identity does not match build version $Version."
}
if ($sourceText -notmatch
    ('AssemblyFileVersion\("' + [regex]::Escape($expectedAssemblyVersion) + '"\)')) {
    throw "Source assembly version does not match build version $Version."
}
if ($sourceText -notmatch
    ('CurrentVersion\s*=\s*"' + $escapedVersion + '"')) {
    throw "Application runtime version does not match build version $Version."
}
if ((Get-Content -LiteralPath $manifest -Raw) -notmatch
    ('assemblyIdentity version="' + [regex]::Escape($expectedAssemblyVersion) + '"')) {
    throw "Application manifest version does not match build version $Version."
}
if ((Get-Content -LiteralPath $installerManifest -Raw) -notmatch
    ('assemblyIdentity version="' + [regex]::Escape($expectedAssemblyVersion) + '"')) {
    throw "Installer manifest version does not match build version $Version."
}
if ((Get-Content -LiteralPath $installerSourceCode -Raw) -notmatch
    ('AssemblyFileVersion\("' + [regex]::Escape($expectedAssemblyVersion) + '"\)')) {
    throw "Installer source version does not match build version $Version."
}
if ((Get-Content -LiteralPath $unlockManifest -Raw) -notmatch
    ('assemblyIdentity version="' + [regex]::Escape($expectedAssemblyVersion) + '"')) {
    throw "Emergency Unlock manifest version does not match build version $Version."
}
if ((Get-Content -LiteralPath $unlockSourceCode -Raw) -notmatch
    ('AssemblyFileVersion\("' + [regex]::Escape($expectedAssemblyVersion) + '"\)')) {
    throw "Emergency Unlock source version does not match build version $Version."
}
if ((Get-Content -LiteralPath $installerScript -Raw) -notmatch
    ('\$installVersion\s*=\s*''' + $escapedVersion + '''')) {
    throw "Installer version does not match build version $Version."
}

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
New-Item -ItemType Directory -Path $applicationStage -Force | Out-Null
New-Item -ItemType Directory -Path $sourceStage -Force | Out-Null

try {
    Copy-Item -Path (Join-Path $installerDirectory '*') -Destination $applicationStage -Recurse -Force
    $executableDirectory = Join-Path $applicationStage 'Programs\Executables'
    New-Item -ItemType Directory -Path $executableDirectory -Force | Out-Null
    Copy-Item -LiteralPath $icon -Destination $executableDirectory -Force
    Copy-Item -LiteralPath $background -Destination $executableDirectory -Force
    Copy-Item -LiteralPath $iconPng -Destination $executableDirectory -Force

    $executable = Join-Path $executableDirectory 'Switzerland VPN.exe'
    & $compiler `
        /nologo `
        /target:winexe `
        /optimize+ `
        /platform:anycpu `
        /warn:4 `
        /warnaserror+ `
        "/win32manifest:$manifest" `
        "/win32icon:$icon" `
        /reference:System.Drawing.dll `
        /reference:System.Net.Http.dll `
        /reference:System.Windows.Forms.dll `
        /reference:System.ServiceProcess.dll `
        "/out:$executable" `
        $sourceCode
    if ($LASTEXITCODE -ne 0) {
        throw "C# compilation failed with exit code $LASTEXITCODE."
    }

    $installerExecutable = Join-Path $applicationStage 'Install Switzerland VPN.exe'
    & $compiler `
        /nologo `
        /target:winexe `
        /optimize+ `
        /platform:anycpu `
        /warn:4 `
        /warnaserror+ `
        "/win32manifest:$installerManifest" `
        "/win32icon:$icon" `
        /reference:System.Windows.Forms.dll `
        "/out:$installerExecutable" `
        $installerSourceCode
    if ($LASTEXITCODE -ne 0) {
        throw "Installer compilation failed with exit code $LASTEXITCODE."
    }

    $unlockExecutable = Join-Path $executableDirectory 'Emergency Unlock.exe'
    & $compiler `
        /nologo `
        /target:winexe `
        /optimize+ `
        /platform:anycpu `
        /warn:4 `
        /warnaserror+ `
        "/win32manifest:$unlockManifest" `
        "/win32icon:$icon" `
        /reference:System.Windows.Forms.dll `
        "/out:$unlockExecutable" `
        $unlockSourceCode
    if ($LASTEXITCODE -ne 0) {
        throw "Emergency Unlock compilation failed with exit code $LASTEXITCODE."
    }

    $expectedFileVersion = $Version + '.0'
    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($executable)
    if ($versionInfo.FileVersion -ne $expectedFileVersion -or $versionInfo.CompanyName -ne 'Justichuu') {
        throw "Built executable metadata does not match version $expectedFileVersion and publisher Justichuu."
    }
    $installerVersionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($installerExecutable)
    if ($installerVersionInfo.FileVersion -ne $expectedFileVersion -or
        $installerVersionInfo.CompanyName -ne 'Justichuu' -or
        $installerVersionInfo.FileDescription -ne 'Switzerland VPN Installer') {
        throw "Built installer metadata does not match version $expectedFileVersion and publisher Justichuu."
    }
    $unlockVersionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($unlockExecutable)
    if ($unlockVersionInfo.FileVersion -ne $expectedFileVersion -or
        $unlockVersionInfo.CompanyName -ne 'Justichuu' -or
        $unlockVersionInfo.FileDescription -ne 'Switzerland VPN Emergency Unlock') {
        throw "Built Emergency Unlock metadata does not match version $expectedFileVersion and publisher Justichuu."
    }

    $programRoot = Join-Path $applicationStage 'Programs'
    $checksumManifest = Join-Path $programRoot 'Package Checksums.txt'
    $checksumLines = [System.Collections.Generic.List[string]]::new()
    $checksumLines.Add('# SHA-256 checksums for every file under Programs')
    Get-ChildItem -LiteralPath $programRoot -Recurse -File |
        Where-Object { $_.FullName -ne $checksumManifest } |
        ForEach-Object {
            [pscustomobject]@{
                RelativePath = 'Programs\' + $_.FullName.Substring($programRoot.Length + 1)
                Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        } |
        Sort-Object RelativePath |
        ForEach-Object { $checksumLines.Add(('{0}  *{1}' -f $_.Hash, $_.RelativePath)) }
    Write-Utf8NoBomLines -Path $checksumManifest -Lines $checksumLines

    $parseFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($scriptFile in Get-ChildItem -LiteralPath $applicationStage -Recurse -File -Filter '*.ps1') {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $scriptFile.FullName,
            [ref]$tokens,
            [ref]$errors)
        foreach ($parseError in $errors) {
            $parseFailures.Add("$($scriptFile.FullName): $($parseError.Message)")
        }
    }
    if ($parseFailures.Count -gt 0) {
        throw ($parseFailures -join [Environment]::NewLine)
    }

    $installerValidator = Join-Path $applicationStage 'Programs\PowershellBackup\Install Switzerland VPN.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installerValidator `
        -ValidatePackageOnly `
        -InstallParentDirectory (Join-Path $env:SystemDrive 'Program Files')
    if ($LASTEXITCODE -ne 0) {
        throw "Package validation failed with exit code $LASTEXITCODE."
    }

    foreach ($name in @('src', 'assets', 'installer', 'scripts')) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot $name) -Destination $sourceStage -Recurse -Force
    }
    foreach ($name in @('README.md', 'ROADMAP.md', 'SECURITY.md', 'LICENSE', '.gitattributes', '.gitignore')) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot $name) -Destination $sourceStage -Force
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temporaryApplicationZip = Join-Path $buildRoot ($applicationName + '.zip')
    $temporarySourceZip = Join-Path $buildRoot ($sourceName + '.zip')
    New-ZipFromDirectory -SourceDirectory $applicationStage -DestinationPath $temporaryApplicationZip
    New-ZipFromDirectory -SourceDirectory $sourceStage -DestinationPath $temporarySourceZip

    foreach ($oldPath in @(
        $applicationOutput,
        $applicationZip,
        $sourceZip,
        $applicationChecksum,
        $sourceChecksum
    )) {
        if (Test-Path -LiteralPath $oldPath) {
            Remove-Item -LiteralPath $oldPath -Recurse -Force
        }
    }

    Move-Item -LiteralPath $applicationStage -Destination $applicationOutput
    Move-Item -LiteralPath $temporaryApplicationZip -Destination $applicationZip
    Move-Item -LiteralPath $temporarySourceZip -Destination $sourceZip

    $applicationHash = (Get-FileHash -LiteralPath $applicationZip -Algorithm SHA256).Hash
    $sourceHash = (Get-FileHash -LiteralPath $sourceZip -Algorithm SHA256).Hash
    Write-Utf8NoBomLines -Path $applicationChecksum -Lines @(
        "$applicationHash  $([IO.Path]::GetFileName($applicationZip))"
    )
    Write-Utf8NoBomLines -Path $sourceChecksum -Lines @(
        "$sourceHash  $([IO.Path]::GetFileName($sourceZip))"
    )

    [pscustomobject]@{
        Version = $Version
        ApplicationZip = $applicationZip
        ApplicationSha256 = $applicationHash
        SourceZip = $sourceZip
        SourceSha256 = $sourceHash
    }
}
finally {
    if (Test-Path -LiteralPath $buildRoot) {
        Remove-Item -LiteralPath $buildRoot -Recurse -Force
    }
}
