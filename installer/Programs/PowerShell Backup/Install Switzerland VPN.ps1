param(
    [switch]$ValidatePackageOnly,

    [string]$InstallParentDirectory
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

$vpnName = 'Switzerland VPN'
$ruleGroup = 'Switzerland VPN Kill Switch'
$installVersion = '1.0.9'
$installParent = $null
$installDir = $null
$validatedInstallTarget = $null
$stateDir = Join-Path $env:ProgramData 'Switzerland VPN'
$statePath = Join-Path $stateDir 'install-state.json'
$programsDir = Split-Path -Parent $PSScriptRoot
$packageRoot = Split-Path -Parent $programsDir
$payloadDir = Join-Path $programsDir 'Executables'
$powershellBackupDir = $PSScriptRoot
$manualBackupDir = Join-Path $powershellBackupDir 'Manual Backup'
$serverFile = Join-Path $packageRoot 'VPN Server.txt'
$checksumFile = Join-Path $programsDir 'Package Checksums.txt'
$certUrl = 'https://downloads.nordcdn.com/certificates/root.der'
$certSha256 = '8B5A495DB498A6C2C8CA7AF6AE4A5CDF65E689D06CBECCB02453C91C3191E2FF'
$certThumbprint = 'B0A21991007734F5E80C977DD295FFEFB5AD6229'
$certSubject = 'CN=NordVPN Root CA, O=NordVPN, C=PA'
$serverAuthOid = '1.3.6.1.5.5.7.3.1'
$createdProfile = $false
$createdCertificate = $false
$createdInstallFolder = $false
$profileCreationStarted = $false
$shortcutCreationStarted = $false
$registryCreationStarted = $false
$matchingProfiles = @()
$phonebookSnapshot = @()
$installId = [guid]::NewGuid().ToString('D')

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ExactFullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-ValidatedInstallParent {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Choose the parent folder where Switzerland VPN should be installed.'
    }
    if ($Path.StartsWith('\\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('//', [StringComparison]::Ordinal) -or
        -not [IO.Path]::IsPathRooted($Path) -or
        $Path -ne $Path.Trim() -or
        ($Path.Length -gt 2 -and $Path.Substring(2).Contains(':')) -or
        $Path.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or
        $Path.IndexOfAny([char[]]'*?') -ge 0) {
        throw 'The install location must be an absolute folder on a local fixed drive.'
    }

    try {
        $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $root = [IO.Path]::GetPathRoot($fullPath)
    }
    catch {
        throw 'The selected install location is not a valid Windows folder path.'
    }

    if ($root -notmatch '^[A-Za-z]:\\$' -or
        [string]::Equals($fullPath, $root.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Choose a folder on a local fixed drive, not the drive root.'
    }
    if ([string]::Equals(
        [IO.Path]::GetFileName($fullPath),
        'Switzerland VPN',
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Choose the parent folder, not a folder already named Switzerland VPN.'
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw 'The selected parent folder does not exist.'
    }

    try {
        $drive = [IO.DriveInfo]::new($root)
        if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) {
            throw 'not-fixed'
        }
    }
    catch {
        throw 'The install location must be on a ready local fixed drive.'
    }

    return $fullPath
}

function Select-InstallParentDirectory {
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    try {
        $dialog.Description = "Select the parent folder.`r`nSwitzerland VPN will be installed inside it."
        $dialog.SelectedPath = $env:ProgramFiles
        $dialog.ShowNewFolderButton = $true
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {
            return $null
        }
        return $dialog.SelectedPath
    }
    finally {
        $dialog.Dispose()
    }
}

function Assert-ExactInstallPaths {
    $expectedInstall = Get-ExactFullPath (Join-Path $installParent 'Switzerland VPN')
    $expectedState = Get-ExactFullPath (Join-Path $env:ProgramData 'Switzerland VPN')
    if ((Get-ExactFullPath $installDir) -ne $expectedInstall) {
        throw 'The installation folder failed its safety check.'
    }
    if ((Get-ExactFullPath $stateDir) -ne $expectedState) {
        throw 'The installation state folder failed its safety check.'
    }
    if ([string]::Equals($expectedInstall, $expectedState, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Choose a different parent folder. The program and install state cannot share one folder.'
    }

    $script:validatedInstallTarget = $expectedInstall
}

function Assert-PackageFiles {
    $requiredExecutables = @(
        'Switzerland VPN.exe'
        'Switzerland VPN.ico'
        'Switzerland VPN.png'
        'Switzerland VPN Background.png'
        'NordVPN Server Authentication Only.inf'
    )

    foreach ($name in $requiredExecutables) {
        $path = Join-Path $payloadDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The package is incomplete. Missing: Programs\Executables\$name"
        }
    }

    foreach ($name in @('Install Switzerland VPN.ps1', 'Uninstall Switzerland VPN.ps1', 'Emergency Unlock.ps1')) {
        $path = Join-Path $powershellBackupDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The package is incomplete. Missing: Programs\PowerShell Backup\$name"
        }
    }

    foreach ($name in @('Switzerland VPN.ps1', 'Switzerland VPN ON.ps1', 'Switzerland VPN OFF.ps1', 'VPN Profile.txt')) {
        $path = Join-Path $manualBackupDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The package is incomplete. Missing: Programs\PowerShell Backup\Manual Backup\$name"
        }
    }

    foreach ($path in $serverFile, $checksumFile) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The package is incomplete. Missing: $(Split-Path -Leaf $path)"
        }
    }
}

function Assert-PackageChecksums {
    $packageRootPrefix = (Get-ExactFullPath $packageRoot) + '\'
    $lines = Get-Content -LiteralPath $checksumFile
    $listedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($line in $lines) {
        if ($line -notmatch '^([A-Fa-f0-9]{64})\s+\*(.+)$') {
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
            throw "Invalid checksum entry: $line"
        }

        $expected = $matches[1].ToUpperInvariant()
        $relative = $matches[2].Trim().Replace('/', '\')
        $path = Get-ExactFullPath (Join-Path $packageRoot $relative)
        if (-not ($path + '\').StartsWith($packageRootPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            -not $path.StartsWith($packageRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A checksum path points outside the package.'
        }
        if (-not $relative.StartsWith('Programs\', [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($path, (Get-ExactFullPath $checksumFile), [StringComparison]::OrdinalIgnoreCase)) {
            throw "A checksum entry is outside the verifiable Programs payload: $relative"
        }
        if (-not $listedFiles.Add($relative)) {
            throw "The checksum file contains a duplicate entry: $relative"
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "A checksummed file is missing: $relative"
        }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actual -ne $expected) {
            throw "Package integrity check failed for: $relative"
        }
    }

    $actualFiles = @(
        Get-ChildItem -LiteralPath $programsDir -Recurse -File |
            Where-Object {
                -not [string]::Equals(
                    (Get-ExactFullPath $_.FullName),
                    (Get-ExactFullPath $checksumFile),
                    [StringComparison]::OrdinalIgnoreCase
                )
            } |
            ForEach-Object { $_.FullName.Substring($packageRoot.Length + 1) }
    )
    $missingEntries = @($actualFiles | Where-Object { -not $listedFiles.Contains($_) })
    if ($missingEntries.Count -gt 0 -or $listedFiles.Count -ne $actualFiles.Count) {
        $missingText = if ($missingEntries.Count -gt 0) { $missingEntries -join ', ' } else { '<unknown mismatch>' }
        throw "The checksum file does not exactly cover the Programs payload. Missing entries: $missingText"
    }
}

function Get-ValidatedServer {
    $server = (Get-Content -LiteralPath $serverFile -Raw).Trim()
    if ($server -notmatch '^ch[0-9]+\.nordvpn\.com$') {
        throw 'VPN Server.txt must contain a Swiss NordVPN hostname such as ch221.nordvpn.com.'
    }

    $addresses = @(
        Resolve-DnsName -Name $server -Type A -ErrorAction Stop |
            Where-Object IPAddress |
            ForEach-Object { [Net.IPAddress]::Parse($_.IPAddress) }
    )
    if ($addresses.Count -eq 0) {
        throw "Could not resolve $server to an IPv4 address."
    }
    return $server
}

function Get-ManagedSwissProfiles {
    $profiles = @()
    $scopes = @(
        [pscustomobject]@{ Label = 'Current user'; AllUser = $false }
        [pscustomobject]@{ Label = 'All users'; AllUser = $true }
    )

    foreach ($scope in $scopes) {
        if ($scope.AllUser) {
            $scopeProfiles = @(Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue)
        }
        else {
            $scopeProfiles = @(Get-VpnConnection -ErrorAction SilentlyContinue)
        }

        foreach ($profile in $scopeProfiles) {
            $name = [string]$profile.Name
            $server = [string]$profile.ServerAddress
            $isCanonicalName = [string]::Equals($name, $vpnName, [StringComparison]::OrdinalIgnoreCase)
            $isSwissNordVpnServer = $server -match '(?i)^ch[0-9]+\.nordvpn\.com$'
            if (-not $isCanonicalName -and -not $isSwissNordVpnServer) { continue }

            $profiles += [pscustomobject]@{
                Scope = $scope.Label
                AllUser = [bool]$scope.AllUser
                Name = $name
                ServerAddress = $server
            }
        }
    }

    return @($profiles | Sort-Object Scope, Name, ServerAddress)
}

function Format-VpnProfileList([object[]]$Profiles) {
    $lines = foreach ($profile in $Profiles) {
        $server = if ([string]::IsNullOrWhiteSpace($profile.ServerAddress)) { '<none>' } else { $profile.ServerAddress }
        "- Scope: $($profile.Scope)`r`n  Name: $($profile.Name)`r`n  Server: $server"
    }
    return ($lines -join "`r`n")
}

function New-VpnPhonebookSnapshot {
    $locations = @(
        (Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk')
        (Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk')
    )
    $snapshot = @()
    foreach ($path in $locations) {
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        $snapshot += [pscustomobject]@{
            Path = $path
            Existed = $exists
            Bytes = if ($exists) { [IO.File]::ReadAllBytes($path) } else { $null }
        }
    }
    return @($snapshot)
}

function Restore-VpnPhonebookSnapshot([object[]]$Snapshot) {
    foreach ($item in $Snapshot) {
        if (-not $item.Existed) { continue }
        $parent = Split-Path -Parent $item.Path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [IO.File]::WriteAllBytes($item.Path, [byte[]]$item.Bytes)
    }
}

function Get-ExactVpnProfile([string]$Name, [bool]$AllUser) {
    if ($AllUser) {
        return Get-VpnConnection -Name $Name -AllUserConnection -ErrorAction SilentlyContinue
    }
    return Get-VpnConnection -Name $Name -ErrorAction SilentlyContinue
}

function Remove-ApprovedVpnProfiles([object[]]$Profiles) {
    $names = @($Profiles | Select-Object -ExpandProperty Name -Unique)
    foreach ($name in $names) {
        & "$env:SystemRoot\System32\rasdial.exe" $name /disconnect 2>&1 | Out-Null
    }

    foreach ($profile in $Profiles) {
        $current = Get-ExactVpnProfile -Name $profile.Name -AllUser $profile.AllUser
        if (-not $current) { continue }

        if (-not [string]::Equals(
            [string]$current.ServerAddress,
            [string]$profile.ServerAddress,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "VPN profile '$($profile.Name)' changed after the removal list was approved. Nothing else was removed."
        }

        if ($profile.AllUser) {
            Remove-VpnConnection -Name $profile.Name -AllUserConnection -Force
        }
        else {
            Remove-VpnConnection -Name $profile.Name -Force
        }

        if (Get-ExactVpnProfile -Name $profile.Name -AllUser $profile.AllUser) {
            throw "Windows did not remove the approved VPN profile '$($profile.Name)' from $($profile.Scope)."
        }
    }
}

function Remove-CanonicalProfileForRollback {
    & "$env:SystemRoot\System32\rasdial.exe" $vpnName /disconnect 2>&1 | Out-Null
    if (Get-VpnConnection -Name $vpnName -AllUserConnection -ErrorAction SilentlyContinue) {
        Remove-VpnConnection -Name $vpnName -AllUserConnection -Force
    }
}

function Set-ProfileIpv6Disabled {
    $phonebook = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
    if (-not (Test-Path -LiteralPath $phonebook -PathType Leaf)) {
        throw 'Windows did not create the all-user VPN phonebook.'
    }

    $bytes = [IO.File]::ReadAllBytes($phonebook)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [Text.UTF8Encoding]::new($true)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [Text.UnicodeEncoding]::new($false, $true)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [Text.UnicodeEncoding]::new($true, $true)
    }
    else {
        $encoding = [Text.UTF8Encoding]::new($false)
    }

    $text = [IO.File]::ReadAllText($phonebook, $encoding)
    $escaped = [regex]::Escape($vpnName)
    $sectionMatch = [regex]::Match($text, "(?ms)^\[$escaped\]\r?\n(?<body>.*?)(?=^\[|\z)")
    if (-not $sectionMatch.Success) {
        throw 'Windows created the VPN profile, but its phonebook entry could not be found.'
    }

    $body = $sectionMatch.Groups['body'].Value
    $lineMatch = [regex]::Match($body, '(?m)^ExcludedProtocols=(\d+)[ \t]*\r?$')
    if (-not $lineMatch.Success) {
        throw 'The VPN phonebook entry has no ExcludedProtocols setting.'
    }

    $current = [int]$lineMatch.Groups[1].Value
    $replacement = "ExcludedProtocols=$($current -bor 8)"
    $newBody = $body.Remove($lineMatch.Index, $lineMatch.Length).Insert($lineMatch.Index, $replacement)
    $newText = $text.Remove($sectionMatch.Groups['body'].Index, $sectionMatch.Groups['body'].Length).
        Insert($sectionMatch.Groups['body'].Index, $newBody)
    [IO.File]::WriteAllText($phonebook, $newText, $encoding)

    $verifyText = [IO.File]::ReadAllText($phonebook, $encoding)
    $verifySection = [regex]::Match($verifyText, "(?ms)^\[$escaped\]\r?\n(?<body>.*?)(?=^\[|\z)")
    $verifyLine = [regex]::Match($verifySection.Groups['body'].Value, '(?m)^ExcludedProtocols=(\d+)[ \t]*\r?$')
    if (-not $verifyLine.Success -or (([int]$verifyLine.Groups[1].Value -band 8) -ne 8)) {
        throw 'Windows did not retain the IPv6-disabled VPN setting.'
    }
}

function Install-NordVpnCertificate {
    $tempDir = Join-Path $env:TEMP ("SwitzerlandVPN-Install-" + [guid]::NewGuid().ToString('N'))
    $certPath = Join-Path $tempDir 'root.der'
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $certUrl -OutFile $certPath -UseBasicParsing

        $hash = (Get-FileHash -LiteralPath $certPath -Algorithm SHA256).Hash
        if ($hash -ne $certSha256) {
            throw 'The downloaded NordVPN certificate failed its pinned SHA-256 check.'
        }

        $downloaded = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certPath)
        if ($downloaded.Thumbprint -ne $certThumbprint -or $downloaded.Subject -ne $certSubject) {
            throw 'The downloaded certificate identity did not match the expected NordVPN Root CA.'
        }

        $existing = Get-ChildItem Cert:\LocalMachine\Root\$certThumbprint -ErrorAction SilentlyContinue
        if (-not $existing) {
            $output = & "$env:SystemRoot\System32\certutil.exe" -f -addstore Root $certPath 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Windows could not install the NordVPN certificate. $($output -join ' ')"
            }
            $script:createdCertificate = $true
        }

        $ekuInf = Join-Path $payloadDir 'NordVPN Server Authentication Only.inf'
        $output = & "$env:SystemRoot\System32\certutil.exe" -f -repairstore Root $certThumbprint $ekuInf 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Windows could not restrict the NordVPN certificate to Server Authentication. $($output -join ' ')"
        }

        # EnhancedKeyUsageList reads the certificate's built-in extension, not
        # the Local Machine store restriction written as property 9. Verify the
        # actual CERT_ENHKEY_USAGE_PROP_ID block that certutil just persisted.
        $verifyOutput = & "$env:SystemRoot\System32\certutil.exe" -v -store Root $certThumbprint 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Windows could not read back the NordVPN certificate restriction. $($verifyOutput -join ' ')"
        }
        $verifyText = $verifyOutput -join "`n"
        $propertyBlock = [regex]::Match(
            $verifyText,
            '(?ms)^\s*CERT_ENHKEY_USAGE_PROP_ID\(9\):\s*(?<body>.*?)(?=^\s*CERT_[A-Z0-9_]+_PROP_ID\(|\z)'
        )
        $oids = @(
            [regex]::Matches($propertyBlock.Groups['body'].Value, '(?<![0-9.])[0-9]+(?:\.[0-9]+)+(?![0-9.])') |
                ForEach-Object { $_.Value } |
                Sort-Object -Unique
        )
        if (-not $propertyBlock.Success -or $oids.Count -ne 1 -or $oids[0] -ne $serverAuthOid) {
            throw 'The NordVPN certificate is installed, but its Server Authentication restriction did not verify.'
        }
    }
    finally {
        $expectedPrefix = (Get-ExactFullPath $env:TEMP) + '\SwitzerlandVPN-Install-'
        $resolvedTemp = Get-ExactFullPath $tempDir
        if ($resolvedTemp.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $tempDir)) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-Shortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkingDirectory, [string]$IconLocation) {
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $Target
        $shortcut.Arguments = $Arguments
        $shortcut.WorkingDirectory = $WorkingDirectory
        $shortcut.IconLocation = $IconLocation
        $shortcut.Save()
    }
    finally {
        if ($shortcut) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null }
        [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
    }
}

function Test-PackageShortcut {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExpectedTarget,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ExpectedArguments
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        if ([string]::IsNullOrWhiteSpace([string]$shortcut.TargetPath)) { return $false }

        return (
            [string]::Equals(
                (Get-ExactFullPath ([string]$shortcut.TargetPath)),
                (Get-ExactFullPath $ExpectedTarget),
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                ([string]$shortcut.Arguments).Trim(),
                $ExpectedArguments.Trim(),
                [StringComparison]::OrdinalIgnoreCase
            )
        )
    }
    catch {
        return $false
    }
    finally {
        if ($shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
        }
        if ($shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
        }
    }
}

function Remove-VerifiedPerUserShortcuts {
    param(
        [Parameter(Mandatory)]
        [string]$InstalledExecutable,

        [Parameter(Mandatory)]
        [string]$PowerShellExecutable
    )

    $desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Switzerland VPN.lnk'
    $userStartFolder = Join-Path ([Environment]::GetFolderPath('Programs')) 'Switzerland VPN'
    $shortcutDefinitions = @(
        [pscustomobject]@{ Path = $desktopShortcut; Target = $InstalledExecutable; Arguments = '' }
        [pscustomobject]@{ Path = (Join-Path $userStartFolder 'Switzerland VPN.lnk'); Target = $InstalledExecutable; Arguments = '' }
        [pscustomobject]@{
            Path = Join-Path $userStartFolder 'Emergency Unlock.lnk'
            Target = $PowerShellExecutable
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $installDir 'Emergency Unlock.ps1')`""
        }
        [pscustomobject]@{
            Path = Join-Path $userStartFolder 'Uninstall Switzerland VPN.lnk'
            Target = $PowerShellExecutable
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $installDir 'Uninstall Switzerland VPN.ps1')`""
        }
    )

    foreach ($definition in $shortcutDefinitions) {
        if (Test-PackageShortcut -Path $definition.Path -ExpectedTarget $definition.Target -ExpectedArguments $definition.Arguments) {
            Remove-Item -LiteralPath $definition.Path -Force
        }
    }

    if ((Test-Path -LiteralPath $userStartFolder -PathType Container) -and
        @(Get-ChildItem -LiteralPath $userStartFolder -Force).Count -eq 0) {
        Remove-Item -LiteralPath $userStartFolder -Force
    }
}

function Start-AsInteractiveShellUser {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw 'The installed Switzerland VPN program is missing.'
    }

    $shell = $null
    $shellWindows = $null
    $desktop = $null
    $desktopDocument = $null
    $explorerApplication = $null

    try {
        $shell = New-Object -ComObject Shell.Application
        $shellWindows = $shell.Windows()
        $desktopLocation = 0
        $desktopRoot = $null
        $desktopHwnd = 0
        $desktop = $shellWindows.FindWindowSW(
            [ref]$desktopLocation,
            [ref]$desktopRoot,
            8,
            [ref]$desktopHwnd,
            1
        )
        if ($null -eq $desktop) {
            throw 'Windows Explorer is not available.'
        }

        $desktopDocument = $desktop.Document
        $explorerApplication = $desktopDocument.Application
        $explorerApplication.ShellExecute($FilePath, '', $WorkingDirectory, 'open', 1)
    }
    finally {
        foreach ($comObject in @($explorerApplication, $desktopDocument, $desktop, $shellWindows, $shell)) {
            if ($null -ne $comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                try { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject) | Out-Null }
                catch { }
            }
        }
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($InstallParentDirectory)) {
        if ($ValidatePackageOnly) {
            $InstallParentDirectory = $env:ProgramFiles
        }
        else {
            $InstallParentDirectory = Select-InstallParentDirectory
            if ([string]::IsNullOrWhiteSpace($InstallParentDirectory)) {
                [Windows.Forms.MessageBox]::Show(
                    'Installation was canceled. No changes were made.',
                    'Switzerland VPN Installation Canceled',
                    [Windows.Forms.MessageBoxButtons]::OK,
                    [Windows.Forms.MessageBoxIcon]::Information
                ) | Out-Null
                exit 0
            }
        }
    }

    $installParent = Get-ValidatedInstallParent -Path $InstallParentDirectory
    $installDir = Get-ExactFullPath (Join-Path $installParent 'Switzerland VPN')
    Assert-ExactInstallPaths
    Assert-PackageFiles
    Assert-PackageChecksums
    $serverAddress = Get-ValidatedServer
}
catch {
    $failure = $_.Exception.Message
    if ($ValidatePackageOnly) {
        Write-Host 'PACKAGE VALIDATION: FAIL' -ForegroundColor Red
        Write-Host $failure
    }
    else {
        [Windows.Forms.MessageBox]::Show(
            "Installation could not start. No changes were made.`r`n`r`n$failure",
            'Switzerland VPN Installation Stopped',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    exit 2
}

if ($ValidatePackageOnly) {
    Write-Host 'PACKAGE VALIDATION: PASS' -ForegroundColor Green
    Write-Host "Server: $serverAddress"
    Write-Host "Install target: $installDir"
    Write-Host 'All required payload files and checksums are valid.'
    exit 0
}

if (-not (Test-Administrator)) {
    $arguments = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', "`"$PSCommandPath`""
        '-InstallParentDirectory', "`"$installParent`""
    )
    try {
        $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        exit $process.ExitCode
    }
    catch {
        if ($_.Exception -is [ComponentModel.Win32Exception] -and $_.Exception.NativeErrorCode -eq 1223) {
            [Windows.Forms.MessageBox]::Show(
                'Installation was canceled. No changes were made.',
                'Switzerland VPN Installation Canceled',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            exit 0
        }

        [Windows.Forms.MessageBox]::Show(
            "Windows could not open the Administrator approval prompt.`r`n`r`n$($_.Exception.Message)",
            'Switzerland VPN Installation Stopped',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit 2
    }
}

try {
    if ([Environment]::OSVersion.Version.Major -lt 10) {
        throw 'This package requires Windows 10 or Windows 11.'
    }

    $existingFolderIsManaged = Test-Path -LiteralPath $statePath -PathType Leaf
    if ($existingFolderIsManaged) {
        throw 'Switzerland VPN is already installed. Uninstall the existing copy before running this installer again.'
    }
    if ((Test-Path -LiteralPath $installDir) -and -not $existingFolderIsManaged) {
        $items = @(Get-ChildItem -LiteralPath $installDir -Force -ErrorAction SilentlyContinue)
        if ($items.Count -gt 0) {
            throw "$installDir already exists and is not marked as this package's installation. Nothing was overwritten."
        }
    }

    if (Test-Path -LiteralPath $stateDir) {
        $stateItems = @(Get-ChildItem -LiteralPath $stateDir -Force -ErrorAction SilentlyContinue)
        if ($stateItems.Count -gt 0) {
            throw "$stateDir already contains unmanaged files. Nothing was overwritten."
        }
    }

    $commonDesktopCollision = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Switzerland VPN.lnk'
    $commonStartCollision = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Switzerland VPN'
    $uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Switzerland VPN Widget'
    foreach ($collisionPath in $commonDesktopCollision, $commonStartCollision, $uninstallKey) {
        if (Test-Path -LiteralPath $collisionPath) {
            throw "An unmanaged installation item already exists: $collisionPath"
        }
    }
}
catch {
    [Windows.Forms.MessageBox]::Show(
        "Installation could not continue. No changes were made.`r`n`r`n$($_.Exception.Message)",
        'Switzerland VPN Installation Stopped',
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 2
}

$message = @"
Install Switzerland VPN for all users?

Folder: $installDir

- Replaces only matching Swiss VPN profiles.
- Installs the NordVPN Root CA for Server Authentication.
- Adds the tray app, kill switch, shortcuts, and recovery tools.

Credentials are not included. The kill switch affects the whole computer.
Continue?
"@
$answer = [Windows.Forms.MessageBox]::Show(
    $message,
    'Install Switzerland VPN',
    [Windows.Forms.MessageBoxButtons]::YesNo,
    [Windows.Forms.MessageBoxIcon]::Warning,
    [Windows.Forms.MessageBoxDefaultButton]::Button2
)
if ($answer -ne [Windows.Forms.DialogResult]::Yes) { exit 0 }

$matchingProfiles = @(Get-ManagedSwissProfiles)
if ($matchingProfiles.Count -gt 0) {
    $profileList = Format-VpnProfileList -Profiles $matchingProfiles
    $collisionAnswer = [Windows.Forms.MessageBox]::Show(
        "These matching Swiss VPN profiles will be replaced:`r`n`r`n$profileList`r`n`r`nTheir saved credentials will be cleared. USA and unrelated profiles stay unchanged. Continue?",
        'Replace Switzerland VPN Profiles',
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning,
        [Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    if ($collisionAnswer -ne [Windows.Forms.DialogResult]::Yes) { exit 0 }
}

$phonebookSnapshot = @(New-VpnPhonebookSnapshot)

try {
    Install-NordVpnCertificate

    $profileCreationStarted = $true
    if ($matchingProfiles.Count -gt 0) {
        Remove-ApprovedVpnProfiles -Profiles $matchingProfiles
    }

    $eap = New-EapConfiguration
    Add-VpnConnection `
        -Name $vpnName `
        -ServerAddress $serverAddress `
        -TunnelType Ikev2 `
        -EncryptionLevel Required `
        -AuthenticationMethod Eap `
        -EapConfigXmlStream $eap.EapConfigXmlStream `
        -AllUserConnection `
        -RememberCredential `
        -IdleDisconnectSeconds 0 `
        -Force | Out-Null
    $createdProfile = $true

    Set-ProfileIpv6Disabled

    $profile = Get-VpnConnection -Name $vpnName -AllUserConnection -ErrorAction Stop
    if ($profile.ServerAddress -ne $serverAddress -or
        $profile.TunnelType -ne 'Ikev2' -or
        $profile.EncryptionLevel -ne 'Required' -or
        $profile.SplitTunneling -ne $false -or
        $profile.RememberCredential -ne $true -or
        $profile.IdleDisconnectSeconds -ne 0 -or
        $profile.AuthenticationMethod -notcontains 'Eap') {
        throw 'The installed Windows VPN profile failed verification.'
    }

    $remainingSwissProfiles = @(Get-ManagedSwissProfiles)
    if ($remainingSwissProfiles.Count -ne 1 -or
        $remainingSwissProfiles[0].Scope -ne 'All users' -or
        $remainingSwissProfiles[0].Name -ne $vpnName -or
        $remainingSwissProfiles[0].ServerAddress -ne $serverAddress) {
        throw 'Windows did not retain exactly one canonical all-user Switzerland VPN profile.'
    }

    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    $createdInstallFolder = $true
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

    foreach ($name in @(
        'Switzerland VPN.exe'
        'Switzerland VPN.ico'
        'Switzerland VPN.png'
        'Switzerland VPN Background.png'
    )) {
        Copy-Item -LiteralPath (Join-Path $payloadDir $name) -Destination (Join-Path $installDir $name) -Force
    }
    foreach ($name in @('Uninstall Switzerland VPN.ps1', 'Emergency Unlock.ps1')) {
        Copy-Item -LiteralPath (Join-Path $powershellBackupDir $name) -Destination (Join-Path $installDir $name) -Force
    }
    [IO.File]::WriteAllText((Join-Path $installDir 'VPN Server.txt'), $serverAddress + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

    $ownership = [ordered]@{
        ProductName = $vpnName
        InstallId = $installId
        InstallDirectory = $installDir
        Version = $installVersion
    }
    $ownership | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installDir 'install-ownership.json') -Encoding UTF8

    $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $programs = [Environment]::GetFolderPath('CommonPrograms')
    $startFolder = Join-Path $programs 'Switzerland VPN'
    $shortcutCreationStarted = $true
    New-Item -ItemType Directory -Path $startFolder -Force | Out-Null
    $exePath = Join-Path $installDir 'Switzerland VPN.exe'
    $powershellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    New-Shortcut -Path (Join-Path $desktop 'Switzerland VPN.lnk') -Target $exePath -Arguments '' -WorkingDirectory $installDir -IconLocation "$exePath,0"
    New-Shortcut -Path (Join-Path $startFolder 'Switzerland VPN.lnk') -Target $exePath -Arguments '' -WorkingDirectory $installDir -IconLocation "$exePath,0"
    New-Shortcut -Path (Join-Path $startFolder 'Emergency Unlock.lnk') -Target $powershellPath `
        -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $installDir 'Emergency Unlock.ps1')`"" `
        -WorkingDirectory $env:SystemRoot -IconLocation "$exePath,0"
    New-Shortcut -Path (Join-Path $startFolder 'Uninstall Switzerland VPN.lnk') -Target $powershellPath `
        -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $installDir 'Uninstall Switzerland VPN.ps1')`"" `
        -WorkingDirectory $env:SystemRoot -IconLocation "$exePath,0"
    Remove-VerifiedPerUserShortcuts -InstalledExecutable $exePath -PowerShellExecutable $powershellPath

    $registryCreationStarted = $true
    New-Item -Path $uninstallKey -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name DisplayName -Value 'Switzerland VPN' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value $installVersion -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name Publisher -Value 'Jaye' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name DisplayIcon -Value "$exePath,0" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $installDir -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name UninstallString `
        -Value "$powershellPath -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $installDir 'Uninstall Switzerland VPN.ps1')`"" `
        -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null

    $state = [ordered]@{
        ProductName = $vpnName
        Version = $installVersion
        InstallId = $installId
        InstalledUtc = [DateTime]::UtcNow.ToString('o')
        InstallDirectory = $installDir
        ProfileName = $vpnName
        ServerAddress = $serverAddress
        FirewallRuleGroup = $ruleGroup
        CertificateThumbprint = $certThumbprint
        CertificateInstalledByThisRun = $createdCertificate
        ReplacedProfiles = @(
            $matchingProfiles | ForEach-Object {
                [ordered]@{
                    Scope = $_.Scope
                    Name = $_.Name
                    ServerAddress = $_.ServerAddress
                }
            }
        )
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

}
catch {
    $failure = $_.Exception.Message

    if ($createdProfile -or $profileCreationStarted) {
        try { Remove-CanonicalProfileForRollback } catch { }
        try { Restore-VpnPhonebookSnapshot -Snapshot $phonebookSnapshot } catch { }
    }
    if ($createdCertificate) {
        try { Remove-Item -LiteralPath "Cert:\LocalMachine\Root\$certThumbprint" -Force } catch { }
    }
    if ($createdInstallFolder -and (Test-Path -LiteralPath $installDir)) {
        try {
            if ([string]::Equals(
                (Get-ExactFullPath $installDir),
                $validatedInstallTarget,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                Remove-Item -LiteralPath $installDir -Recurse -Force
            }
        }
        catch { }
    }
    if ($shortcutCreationStarted) {
        try { Remove-Item -LiteralPath $commonDesktopCollision -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath $commonStartCollision -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($registryCreationStarted) {
        try { Remove-Item -LiteralPath $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    if (Test-Path -LiteralPath $stateDir) {
        try {
            if ((Get-ExactFullPath $stateDir) -eq (Get-ExactFullPath (Join-Path $env:ProgramData 'Switzerland VPN'))) {
                Remove-Item -LiteralPath $stateDir -Recurse -Force
            }
        }
        catch { }
    }

    [Windows.Forms.MessageBox]::Show(
        "Installation failed and package-created changes were rolled back where possible.`r`n`r`n$failure",
        'Switzerland VPN Installation Failed',
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 2
}

$runNow = [Windows.Forms.MessageBox]::Show(
    "Installation complete. Run Switzerland VPN now?`r`n`r`nUse SET UP SIGN-IN if needed.",
    'Switzerland VPN Installed',
    [Windows.Forms.MessageBoxButtons]::YesNo,
    [Windows.Forms.MessageBoxIcon]::Question,
    [Windows.Forms.MessageBoxDefaultButton]::Button1
)

if ($runNow -eq [Windows.Forms.DialogResult]::Yes) {
    try {
        Start-AsInteractiveShellUser -FilePath $exePath -WorkingDirectory $installDir
    }
    catch {
        [Windows.Forms.MessageBox]::Show(
            "Switzerland VPN installed successfully, but Windows could not open it automatically.`r`n`r`nOpen it from the Desktop or Start menu.",
            'Switzerland VPN Installed',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

exit 0
