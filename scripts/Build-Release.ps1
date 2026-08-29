# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    # Four parts on purpose. The installer rejects same-version replacement, so a single fix can
    # need several packages; the fourth segment absorbs those without burning patch numbers.
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$Version = '1.5.0.0',

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
# Every build gets its own versioned folder so packages from different versions can never sit
# side by side and be mistaken for each other: artifacts\builds\1.4.5\...
$outputRoot = Get-NormalizedPath (Join-Path (Join-Path $OutputDirectory 'builds') $Version)
$buildRoot = Join-Path $outputRoot ('.build-' + [guid]::NewGuid().ToString('N'))
$applicationName = "Swiss Army VPN Distribution $Version"
$sourceName = "Swiss Army VPN Source $Version"
$applicationStage = Join-Path $buildRoot $applicationName
$sourceStage = Join-Path $buildRoot $sourceName
$applicationZip = Join-Path $outputRoot ($applicationName + '.zip')
$sourceZip = Join-Path $outputRoot ($sourceName + '.zip')
$applicationChecksum = Join-Path $outputRoot ($applicationName + ' SHA256.txt')
$sourceChecksum = Join-Path $outputRoot ($sourceName + ' SHA256.txt')
$releaseVerifier = Join-Path $outputRoot ("Verify Swiss Army VPN Release $Version.exe")
$applicationOutput = Join-Path $outputRoot $applicationName

$sourceCode = Join-Path $sourceDirectory 'SwissArmyVPN.cs'
$manifest = Join-Path $sourceDirectory 'SwissArmyVPN.exe.manifest'
$installerSourceCode = Join-Path $sourceDirectory 'SwissArmyVPN.Installer.cs'
$installerManifest = Join-Path $sourceDirectory 'SwissArmyVPN.Installer.exe.manifest'
$unlockSourceCode = Join-Path $sourceDirectory 'SwissArmyVPN.EmergencyUnlock.cs'
$unlockManifest = Join-Path $sourceDirectory 'SwissArmyVPN.EmergencyUnlock.exe.manifest'
$releaseVerifierSourceCode = Join-Path $sourceDirectory 'SwissArmyVPN.ReleaseVerifier.cs'
$releaseVerifierManifest = Join-Path $sourceDirectory 'SwissArmyVPN.ReleaseVerifier.exe.manifest'
$releaseVerifierBuildScript = Join-Path $repositoryRoot 'scripts\Build-ReleaseVerifier.ps1'
$installerScript = Join-Path $installerDirectory 'Programs\PowershellBackup\Install Swiss Army VPN.ps1'
$icon = Join-Path $assetDirectory 'Swiss Army VPN.ico'
$mandala = Join-Path $assetDirectory 'Theme Mandala.jpg'
$iconPng = Join-Path $assetDirectory 'Swiss Army VPN.png'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

foreach ($requiredFile in @(
    $sourceCode,
    $manifest,
    $installerSourceCode,
    $installerManifest,
    $unlockSourceCode,
    $unlockManifest,
    $releaseVerifierSourceCode,
    $releaseVerifierManifest,
    $releaseVerifierBuildScript,
    $icon,
    $mandala,
    $iconPng,
    $compiler,
    $installerScript
)) {
    Assert-FileExists $requiredFile
}

$scrubberTest = Join-Path $repositoryRoot 'tests\Test-StatePhaseScrubber.py'
Assert-FileExists $scrubberTest
$python = Get-Command python, python3 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $python) {
    throw 'Python is required to witness the state and phase scrubber.'
}
& $python.Source $scrubberTest
if ($LASTEXITCODE -ne 0) {
    throw "State and phase scrubber witness failed with exit code $LASTEXITCODE."
}

$escapedVersion = [regex]::Escape($Version)
$expectedAssemblyVersion = $Version
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
    # The mandala is embedded in the executable, not shipped beside it, so it is not copied here.
    Copy-Item -LiteralPath $iconPng -Destination $executableDirectory -Force

    $executable = Join-Path $executableDirectory 'Swiss Army VPN.exe'
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
        "/resource:$mandala,SwissArmyVpn.Mandala.jpg" `
        "/out:$executable" `
        $sourceCode
    if ($LASTEXITCODE -ne 0) {
        throw "C# compilation failed with exit code $LASTEXITCODE."
    }

    $installerExecutable = Join-Path $applicationStage 'Install Swiss Army VPN.exe'
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

    $expectedFileVersion = $Version
    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($executable)
    if ($versionInfo.FileVersion -ne $expectedFileVersion -or $versionInfo.CompanyName -ne 'Justichuu') {
        throw "Built executable metadata does not match version $expectedFileVersion and publisher Justichuu."
    }
    $installerVersionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($installerExecutable)
    if ($installerVersionInfo.FileVersion -ne $expectedFileVersion -or
        $installerVersionInfo.CompanyName -ne 'Justichuu' -or
        $installerVersionInfo.FileDescription -ne 'Swiss Army VPN Installer') {
        throw "Built installer metadata does not match version $expectedFileVersion and publisher Justichuu."
    }
    $unlockVersionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($unlockExecutable)
    if ($unlockVersionInfo.FileVersion -ne $expectedFileVersion -or
        $unlockVersionInfo.CompanyName -ne 'Justichuu' -or
        $unlockVersionInfo.FileDescription -ne 'Swiss Army VPN Emergency Unlock') {
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

    $installerValidator = Join-Path $applicationStage 'Programs\PowershellBackup\Install Swiss Army VPN.ps1'
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
        $sourceChecksum,
        $releaseVerifier
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

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $releaseVerifierBuildScript `
        -Version $Version `
        -DistributionPath $applicationZip `
        -SourcePath $sourceZip `
        -OutputPath $releaseVerifier | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $releaseVerifier -PathType Leaf)) {
        throw "Release verifier build failed with exit code $LASTEXITCODE."
    }

    [pscustomobject]@{
        Version = $Version
        ApplicationZip = $applicationZip
        ApplicationSha256 = $applicationHash
        SourceZip = $sourceZip
        SourceSha256 = $sourceHash
        ReleaseVerifier = $releaseVerifier
    }
}
finally {
    if (Test-Path -LiteralPath $buildRoot) {
        Remove-Item -LiteralPath $buildRoot -Recurse -Force
    }
}
