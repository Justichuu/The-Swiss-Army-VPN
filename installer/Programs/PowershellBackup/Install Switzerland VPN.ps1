param(
    [switch]$ValidatePackageOnly,

    [string]$InstallParentDirectory
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

$vpnName = 'Switzerland VPN'
$ruleGroup = 'Switzerland VPN Kill Switch'
$publisher = 'Justichuu'
# The project handle changed because I got bored; accept the old publisher only while upgrading.
$legacyPublisher = 'Jaye'
$installVersion = '1.3.2'
$installParent = $null
$installDir = $null
$validatedInstallTarget = $null
$stateDir = Join-Path $env:ProgramData 'Switzerland VPN'
$statePath = Join-Path $stateDir 'install-state.json'
$ownershipFileName = 'install-ownership.json'
$uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Switzerland VPN Widget'
$programsDir = Split-Path -Parent $PSScriptRoot
$packageRoot = Split-Path -Parent $programsDir
$payloadDir = Join-Path $programsDir 'Executables'
$powershellBackupDir = $PSScriptRoot
$manualBackupDir = Join-Path $powershellBackupDir 'ManualBackup'
$serverFile = Join-Path $packageRoot 'VPN Server.txt'
$serverPoolFile = Join-Path $packageRoot 'VPN Servers.txt'
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

function Get-TrustedDirectoryPrincipalSids {
    $trustedSids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($sid in @(
        'S-1-5-18' # Local System
        'S-1-5-32-544' # Built-in Administrators
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' # TrustedInstaller
    )) {
        [void]$trustedSids.Add($sid)
    }
    return ,$trustedSids
}

function Assert-DirectoryChainHasNoReparsePoints {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = Get-ExactFullPath $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "The folder does not exist: $fullPath"
    }

    $current = [IO.DirectoryInfo]::new($fullPath)
    while ($null -ne $current) {
        $item = Get-Item -LiteralPath $current.FullName -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The install location cannot use directory links or mount points: $($item.FullName)"
        }
        $current = $current.Parent
    }
}

function Test-RuleGrantsDirectoryWrite {
    param(
        [Parameter(Mandatory)]
        [Security.AccessControl.FileSystemAccessRule]$Rule
    )

    if ($Rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
        return $false
    }
    if (($Rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0 -and
        $Rule.InheritanceFlags -eq [Security.AccessControl.InheritanceFlags]::None) {
        return $false
    }

    # FileSystemRights can contain signed generic-access bits. Normalize it to
    # an unsigned 32-bit value before testing every permission that permits a
    # caller to create, alter, delete, or take control of directory contents.
    $rights = [uint64]([int64][int32]$Rule.FileSystemRights -band 0xFFFFFFFFL)
    $writeMask = [uint64]0
    foreach ($right in @(
        [Security.AccessControl.FileSystemRights]::Write
        [Security.AccessControl.FileSystemRights]::Delete
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
        [Security.AccessControl.FileSystemRights]::ChangePermissions
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    )) {
        $writeMask = $writeMask -bor [uint64]([int64][int32]$right -band 0xFFFFFFFFL)
    }
    $writeMask = $writeMask -bor 0x10000000L -bor 0x40000000L # GENERIC_ALL and GENERIC_WRITE

    return (($rights -band $writeMask) -ne 0)
}

function Assert-InstallParentIsProtected {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = Get-ExactFullPath $Path
    Assert-DirectoryChainHasNoReparsePoints -Path $fullPath

    $trustedSids = Get-TrustedDirectoryPrincipalSids
    $security = [IO.Directory]::GetAccessControl(
        $fullPath,
        [Security.AccessControl.AccessControlSections]::Access -bor
            [Security.AccessControl.AccessControlSections]::Owner
    )
    $rawDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
        $security.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
    )
    if ($null -eq $rawDescriptor.DiscretionaryAcl) {
        throw 'The selected install parent has an unsafe unrestricted access list.'
    }

    $ownerSid = $security.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if (-not $trustedSids.Contains($ownerSid)) {
        $ownerIdentity = try {
            ([Security.Principal.SecurityIdentifier]::new($ownerSid)).Translate(
                [Security.Principal.NTAccount]
            ).Value
        }
        catch {
            $ownerSid
        }
        throw "The selected install parent is controlled by an untrusted owner: $ownerIdentity"
    }

    $rules = $security.GetAccessRules(
        $true,
        $true,
        [Security.Principal.SecurityIdentifier]
    )
    foreach ($rule in $rules) {
        $sid = $rule.IdentityReference.Value
        $isSafeCreatorOwnerRule = (
            $sid -eq 'S-1-3-0' -and
            ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0
        )
        if (-not $trustedSids.Contains($sid) -and
            -not $isSafeCreatorOwnerRule -and
            (Test-RuleGrantsDirectoryWrite -Rule $rule)) {
            $identity = try {
                $rule.IdentityReference.Translate([Security.Principal.NTAccount]).Value
            }
            catch {
                $sid
            }
            throw "The selected install parent is writable by an untrusted account: $identity"
        }
    }
}

function Set-ProtectedApplicationDirectoryAcl {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = Get-ExactFullPath $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "Windows did not create the protected application folder: $fullPath"
    }
    Assert-DirectoryChainHasNoReparsePoints -Path $fullPath

    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $usersSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow

    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($administratorsSid)

    $expectedRules = [Collections.Generic.Dictionary[string, uint64]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($definition in @(
        [pscustomobject]@{ Sid = $systemSid; Rights = [Security.AccessControl.FileSystemRights]::FullControl }
        [pscustomobject]@{ Sid = $administratorsSid; Rights = [Security.AccessControl.FileSystemRights]::FullControl }
        [pscustomobject]@{ Sid = $usersSid; Rights = [Security.AccessControl.FileSystemRights]::ReadAndExecute }
    )) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $definition.Sid,
            $definition.Rights,
            $inheritance,
            $propagation,
            $allow
        )
        [void]$security.AddAccessRule($rule)
        $expectedRules.Add(
            $definition.Sid.Value,
            [uint64]([int64][int32]$rule.FileSystemRights -band 0xFFFFFFFFL)
        )
    }

    [IO.Directory]::SetAccessControl($fullPath, $security)

    $verified = [IO.Directory]::GetAccessControl(
        $fullPath,
        [Security.AccessControl.AccessControlSections]::Access -bor
            [Security.AccessControl.AccessControlSections]::Owner
    )
    if (-not $verified.AreAccessRulesProtected -or
        $verified.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $administratorsSid.Value) {
        throw "Windows did not protect the permissions on: $fullPath"
    }

    $actualRules = @($verified.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
    if ($actualRules.Count -ne $expectedRules.Count) {
        throw "Windows retained unexpected permissions on: $fullPath"
    }
    foreach ($rule in $actualRules) {
        $sid = $rule.IdentityReference.Value
        $rights = [uint64]([int64][int32]$rule.FileSystemRights -band 0xFFFFFFFFL)
        if (-not $expectedRules.ContainsKey($sid) -or
            $rights -ne $expectedRules[$sid] -or
            $rule.AccessControlType -ne $allow -or
            $rule.InheritanceFlags -ne $inheritance -or
            $rule.PropagationFlags -ne $propagation) {
            throw "Windows retained unexpected permissions on: $fullPath"
        }
    }
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
        'Emergency Unlock.exe'
        'Switzerland VPN.exe'
        'Switzerland VPN.ico'
        'Switzerland VPN.png'
        'Switzerland VPN Background.png'
        'NordVPN Server Authentication Only.inf'
    )

    $missingExecutables = @(
        $requiredExecutables | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $payloadDir $_) -PathType Leaf)
        }
    )
    if ($missingExecutables.Count -gt 0) {
        $sourceRoot = Split-Path -Parent $packageRoot
        $sourceBuildScript = Join-Path $sourceRoot 'scripts\Build-Release.ps1'
        $sourceApplication = Join-Path $sourceRoot 'src\SwitzerlandVPN.cs'
        if ((Test-Path -LiteralPath $sourceBuildScript -PathType Leaf) -and
            (Test-Path -LiteralPath $sourceApplication -PathType Leaf)) {
            throw @"
This is GitHub's source-code ZIP, not the installable application package.

Open:
https://github.com/Justichuu/The-Swiss-Army-VPN/releases/latest

Download and extract "Switzerland VPN Distribution ${installVersion}.zip", then run "Install Switzerland VPN.exe". Do not use GitHub's green Code > Download ZIP option.
"@
        }
    }

    foreach ($name in $requiredExecutables) {
        $path = Join-Path $payloadDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The package is incomplete. Missing: Programs\Executables\$name"
        }
    }

    foreach ($name in @(
        'Install Switzerland VPN.ps1'
        'Update Switzerland VPN.ps1'
        'Uninstall Switzerland VPN.ps1'
        'Emergency Unlock.ps1'
    )) {
        $path = Join-Path $powershellBackupDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The package is incomplete. Missing: Programs\PowershellBackup\$name"
        }
    }

    foreach ($name in @('Switzerland VPN.ps1', 'Switzerland VPN ON.ps1', 'Switzerland VPN OFF.ps1', 'VPN Profile.txt')) {
        $path = Join-Path $manualBackupDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The package is incomplete. Missing: Programs\PowershellBackup\ManualBackup\$name"
        }
    }

    foreach ($path in $serverFile, $serverPoolFile, $checksumFile) {
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

function Test-SupportedPublisher([string]$Value) {
    return [string]::Equals($Value, $publisher, [StringComparison]::Ordinal) -or
        [string]::Equals($Value, $legacyPublisher, [StringComparison]::Ordinal)
}

function Assert-ValidatedServerPool {
    $servers = @(
        Get-Content -LiteralPath $serverPoolFile |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    )
    if ($servers.Count -lt 2) {
        throw 'VPN Servers.txt must contain at least two Swiss backup servers.'
    }
    foreach ($server in $servers) {
        if ($server -cnotmatch '^ch[0-9]+\.nordvpn\.com$') {
            throw "VPN Servers.txt contains an invalid Swiss NordVPN hostname: $server"
        }
    }
    if (@($servers | Sort-Object -Unique).Count -ne $servers.Count) {
        throw 'VPN Servers.txt contains duplicate server hostnames.'
    }
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

        foreach ($vpnProfile in $scopeProfiles) {
            $name = [string]$vpnProfile.Name
            $server = [string]$vpnProfile.ServerAddress
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
    $lines = foreach ($vpnProfile in $Profiles) {
        $server = if ([string]::IsNullOrWhiteSpace($vpnProfile.ServerAddress)) { '<none>' } else { $vpnProfile.ServerAddress }
        "- Scope: $($vpnProfile.Scope)`r`n  Name: $($vpnProfile.Name)`r`n  Server: $server"
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

    foreach ($vpnProfile in $Profiles) {
        $current = Get-ExactVpnProfile -Name $vpnProfile.Name -AllUser $vpnProfile.AllUser
        if (-not $current) { continue }

        if (-not [string]::Equals(
            [string]$current.ServerAddress,
            [string]$vpnProfile.ServerAddress,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "VPN profile '$($vpnProfile.Name)' changed after the removal list was approved. Nothing else was removed."
        }

        if ($vpnProfile.AllUser) {
            Remove-VpnConnection -Name $vpnProfile.Name -AllUserConnection -Force
        }
        else {
            Remove-VpnConnection -Name $vpnProfile.Name -Force
        }

        if (Get-ExactVpnProfile -Name $vpnProfile.Name -AllUser $vpnProfile.AllUser) {
            throw "Windows did not remove the approved VPN profile '$($vpnProfile.Name)' from $($vpnProfile.Scope)."
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

function Get-ManagedInstallParentHint {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $uninstallKey)) {
        return $null
    }

    try {
        $registration = Get-ItemProperty -LiteralPath $uninstallKey
        $location = Get-ExactFullPath ([string]$registration.InstallLocation)
        if (-not [string]::Equals([string]$registration.DisplayName, $vpnName, [StringComparison]::Ordinal) -or
            -not (Test-SupportedPublisher ([string]$registration.Publisher)) -or
            -not [string]::Equals([IO.Path]::GetFileName($location), $vpnName, [StringComparison]::Ordinal)) {
            return $null
        }
        return Split-Path -Parent $location
    }
    catch {
        return $null
    }
}

function Get-ValidatedManagedUpgradeContext {
    param(
        [Parameter(Mandatory)]
        [string]$ExpectedVersion,

        [switch]$RequireUpdateHelper
    )

    Assert-InstallParentIsProtected -Path $installParent
    Assert-DirectoryChainHasNoReparsePoints -Path $installDir
    Assert-InstallParentIsProtected -Path $installDir
    Assert-DirectoryChainHasNoReparsePoints -Path $stateDir

    foreach ($path in @($statePath, (Join-Path $installDir $ownershipFileName))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The existing installation ownership files are missing or linked. Nothing was changed.'
        }
    }

    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $marker = Get-Content -LiteralPath (Join-Path $installDir $ownershipFileName) -Raw | ConvertFrom-Json
    }
    catch {
        throw 'The existing installation ownership data is damaged. Nothing was changed.'
    }

    foreach ($propertyName in @(
        'ProductName', 'Version', 'InstallId', 'InstallDirectory', 'ProfileName',
        'ServerAddress', 'FirewallRuleGroup', 'CertificateThumbprint'
    )) {
        if ($state.PSObject.Properties.Name -notcontains $propertyName -or
            [string]::IsNullOrWhiteSpace([string]$state.$propertyName)) {
            throw "The existing installation record is incomplete ($propertyName). Nothing was changed."
        }
    }
    foreach ($propertyName in @('ProductName', 'Version', 'InstallId', 'InstallDirectory')) {
        if ($marker.PSObject.Properties.Name -notcontains $propertyName -or
            [string]::IsNullOrWhiteSpace([string]$marker.$propertyName)) {
            throw "The existing ownership marker is incomplete ($propertyName). Nothing was changed."
        }
    }

    $parsedInstallId = [guid]::Empty
    if (-not [guid]::TryParse([string]$state.InstallId, [ref]$parsedInstallId) -or
        -not [string]::Equals([string]$state.ProductName, $vpnName, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$state.Version, $ExpectedVersion, [StringComparison]::Ordinal) -or
        -not [string]::Equals((Get-ExactFullPath ([string]$state.InstallDirectory)), $installDir, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$state.ProfileName, $vpnName, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$state.FirewallRuleGroup, $ruleGroup, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$state.CertificateThumbprint, $certThumbprint, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$state.ServerAddress -cnotmatch '^ch[0-9]+\.nordvpn\.com$') {
        throw 'The existing installation record does not match this package. Nothing was changed.'
    }
    if (-not [string]::Equals([string]$marker.ProductName, $vpnName, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$marker.Version, $ExpectedVersion, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$marker.InstallId, [string]$state.InstallId, [StringComparison]::Ordinal) -or
        -not [string]::Equals((Get-ExactFullPath ([string]$marker.InstallDirectory)), $installDir, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The existing ownership marker does not match the installation record. Nothing was changed.'
    }

    $installedServerPath = Join-Path $installDir 'VPN Server.txt'
    if (-not (Test-Path -LiteralPath $installedServerPath -PathType Leaf) -or
        ((Get-Item -LiteralPath $installedServerPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::Equals(
            (Get-Content -LiteralPath $installedServerPath -Raw).Trim(),
            [string]$state.ServerAddress,
            [StringComparison]::Ordinal
        )) {
        throw 'The existing VPN server setting does not match its installation record. Nothing was changed.'
    }

    $requiredFiles = @(
        'Switzerland VPN.exe'
        'Switzerland VPN.ico'
        'Switzerland VPN.png'
        'Switzerland VPN Background.png'
        'Uninstall Switzerland VPN.ps1'
        'Emergency Unlock.ps1'
        'VPN Server.txt'
        $ownershipFileName
    )
    if ([version]$ExpectedVersion -ge [version]'1.2.0') {
        $requiredFiles += 'Switch Switzerland VPN Server.ps1', 'VPN Servers.txt'
    }
    if ([version]$ExpectedVersion -ge [version]'1.3.1') {
        $requiredFiles += 'Emergency Unlock.exe'
    }
    if ($RequireUpdateHelper) { $requiredFiles += 'Update Switzerland VPN.ps1' }
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $requiredFiles) { [void]$allowed.Add($name) }
    $items = @(Get-ChildItem -LiteralPath $installDir -Force)
    if ($items.Count -ne $requiredFiles.Count) {
        throw 'The existing application folder contains missing or unexpected files. Nothing was changed.'
    }
    foreach ($item in $items) {
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not $allowed.Contains($item.Name)) {
            throw "The existing application folder contains an unexpected item: $($item.Name). Nothing was changed."
        }
    }

    $appPath = Join-Path $installDir 'Switzerland VPN.exe'
    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($appPath)
    if (-not (Test-SupportedPublisher ([string]$versionInfo.CompanyName)) -or
        $versionInfo.FileVersion -ne ($ExpectedVersion + '.0')) {
        throw 'The installed program does not match its owned version record. Nothing was changed.'
    }

    if (-not (Test-Path -LiteralPath $uninstallKey)) {
        throw 'The existing Windows uninstall registration is missing. Nothing was changed.'
    }
    $registration = Get-ItemProperty -LiteralPath $uninstallKey
    if (-not [string]::Equals([string]$registration.DisplayName, $vpnName, [StringComparison]::Ordinal) -or
        -not (Test-SupportedPublisher ([string]$registration.Publisher)) -or
        -not [string]::Equals([string]$registration.InstallLocation, $installDir, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$registration.DisplayVersion, $ExpectedVersion, [StringComparison]::Ordinal)) {
        throw 'The existing Windows uninstall registration does not match this installation. Nothing was changed.'
    }

    $installedUtc = [DateTime]::UtcNow.ToString('o')
    if ($state.PSObject.Properties.Name -contains 'InstalledUtc') {
        $parsedInstalledUtc = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$state.InstalledUtc, [ref]$parsedInstalledUtc)) {
            throw 'The existing installation timestamp is invalid. Nothing was changed.'
        }
        $installedUtc = [string]$state.InstalledUtc
    }
    $certificateInstalledByThisRun = $false
    if ($state.PSObject.Properties.Name -contains 'CertificateInstalledByThisRun') {
        if ($state.CertificateInstalledByThisRun -isnot [bool]) {
            throw 'The existing certificate ownership setting is invalid. Nothing was changed.'
        }
        $certificateInstalledByThisRun = [bool]$state.CertificateInstalledByThisRun
    }
    $replacedProfiles = @()
    if ($state.PSObject.Properties.Name -contains 'ReplacedProfiles') {
        foreach ($replacedProfile in @($state.ReplacedProfiles)) {
            if ($null -eq $replacedProfile -or
                $replacedProfile.PSObject.Properties.Name -notcontains 'Scope' -or
                $replacedProfile.PSObject.Properties.Name -notcontains 'Name' -or
                $replacedProfile.PSObject.Properties.Name -notcontains 'ServerAddress' -or
                @('Current user', 'All users') -cnotcontains [string]$replacedProfile.Scope -or
                [string]::IsNullOrWhiteSpace([string]$replacedProfile.Name) -or
                [string]$replacedProfile.ServerAddress -notmatch '(?i)^ch[0-9]+\.nordvpn\.com$') {
                throw 'The existing replaced-profile record is invalid. Nothing was changed.'
            }
            $replacedProfiles += [ordered]@{
                Scope = [string]$replacedProfile.Scope
                Name = [string]$replacedProfile.Name
                ServerAddress = [string]$replacedProfile.ServerAddress
            }
        }
    }

    return [pscustomobject]@{
        InstallDirectory = $installDir
        AppPath = $appPath
        InstallId = [string]$state.InstallId
        ServerAddress = [string]$state.ServerAddress
        OldVersion = $ExpectedVersion
        RequiredUpdateHelper = [bool]$RequireUpdateHelper
        SanitizedState = [ordered]@{
            ProductName = $vpnName
            Version = $ExpectedVersion
            InstallId = [string]$state.InstallId
            InstalledUtc = $installedUtc
            InstallDirectory = $installDir
            ProfileName = $vpnName
            ServerAddress = [string]$state.ServerAddress
            FirewallRuleGroup = $ruleGroup
            CertificateThumbprint = $certThumbprint
            CertificateInstalledByThisRun = $certificateInstalledByThisRun
            ReplacedProfiles = $replacedProfiles
        }
    }
}

function Assert-WidgetIsClosedForUpgrade {
    param([Parameter(Mandatory)][string]$AppPath)

    foreach ($process in @(Get-Process -Name 'Switzerland VPN' -ErrorAction SilentlyContinue)) {
        try {
            if ([string]::Equals((Get-ExactFullPath $process.Path), $AppPath, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Close Switzerland VPN from its tray icon, then run the installer again. The VPN and kill switch were not changed.'
            }
        }
        finally {
            $process.Dispose()
        }
    }
}

function Copy-AndVerifyUpgradeFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    if ((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash) {
        throw "Windows did not copy this upgrade file correctly: $(Split-Path -Leaf $Destination)"
    }
}

function Invoke-ManagedInstallUpgrade {
    param([Parameter(Mandatory)][object]$Context)

    $transactionRoot = Join-Path $installParent ('.Switzerland VPN.install-upgrade-' + [guid]::NewGuid().ToString('N'))
    $newInstall = Join-Path $transactionRoot 'new-install'
    $backupInstall = Join-Path $transactionRoot 'old-install'
    $failedInstall = Join-Path $transactionRoot 'failed-install'
    $stateBackup = Join-Path $transactionRoot 'install-state.json'
    $stateTemporary = Join-Path $stateDir ('install-state.upgrade-' + [guid]::NewGuid().ToString('N') + '.json')
    $stateReplaceBackup = Join-Path $stateDir ('install-state.rollback-' + [guid]::NewGuid().ToString('N') + '.json')
    $oldRegistration = Get-ItemProperty -LiteralPath $uninstallKey
    $oldRegistryVersion = [string]$oldRegistration.DisplayVersion
    $oldRegistryPublisher = [string]$oldRegistration.Publisher
    $backupMoved = $false
    $stateChanged = $false
    $registryChanged = $false
    $serverShortcutCreated = $false
    $emergencyShortcutChanged = $false
    $serverShortcutPath = Join-Path `
        (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Switzerland VPN') `
        'Choose Swiss VPN Server.lnk'
    $serverShortcutPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $serverShortcutArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $installDir 'Switch Switzerland VPN Server.ps1')`""
    $serverShortcutPreexisting = Test-Path -LiteralPath $serverShortcutPath -PathType Leaf
    if ($serverShortcutPreexisting -and -not (Test-PackageShortcut `
        -Path $serverShortcutPath `
        -ExpectedTarget $serverShortcutPowerShell `
        -ExpectedArguments $serverShortcutArguments)) {
        throw "An unmanaged shortcut already exists: $serverShortcutPath"
    }
    $emergencyShortcutPath = Join-Path `
        (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Switzerland VPN') `
        'Emergency Unlock.lnk'
    $emergencyShortcutBackup = Join-Path $transactionRoot 'Emergency Unlock.lnk'
    $legacyEmergencyArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $installDir 'Emergency Unlock.ps1')`""
    $emergencyShortcutPreexisting = Test-Path -LiteralPath $emergencyShortcutPath -PathType Leaf
    if ($emergencyShortcutPreexisting -and -not (Test-PackageShortcut `
        -Path $emergencyShortcutPath `
        -ExpectedTarget $serverShortcutPowerShell `
        -ExpectedArguments $legacyEmergencyArguments)) {
        throw "An unmanaged shortcut already exists: $emergencyShortcutPath"
    }

    try {
        Assert-WidgetIsClosedForUpgrade -AppPath $Context.AppPath
        Assert-PackageChecksums
        New-Item -ItemType Directory -Path $transactionRoot | Out-Null
        Set-ProtectedApplicationDirectoryAcl -Path $transactionRoot
        New-Item -ItemType Directory -Path $newInstall | Out-Null

        foreach ($name in @(
            'Emergency Unlock.exe', 'Switzerland VPN.exe', 'Switzerland VPN.ico', 'Switzerland VPN.png',
            'Switzerland VPN Background.png'
        )) {
            Copy-AndVerifyUpgradeFile -Source (Join-Path $payloadDir $name) -Destination (Join-Path $newInstall $name)
        }
        foreach ($name in @('Update Switzerland VPN.ps1', 'Uninstall Switzerland VPN.ps1', 'Emergency Unlock.ps1', 'Switch Switzerland VPN Server.ps1')) {
            Copy-AndVerifyUpgradeFile -Source (Join-Path $powershellBackupDir $name) -Destination (Join-Path $newInstall $name)
        }
        Copy-AndVerifyUpgradeFile -Source (Join-Path $installDir 'VPN Server.txt') `
            -Destination (Join-Path $newInstall 'VPN Server.txt')
        Copy-AndVerifyUpgradeFile -Source $serverPoolFile -Destination (Join-Path $newInstall 'VPN Servers.txt')

        $updatedMarker = [ordered]@{
            ProductName = $vpnName
            InstallId = $Context.InstallId
            InstallDirectory = $installDir
            Version = $installVersion
        }
        [IO.File]::WriteAllText(
            (Join-Path $newInstall $ownershipFileName),
            ($updatedMarker | ConvertTo-Json),
            [Text.UTF8Encoding]::new($false)
        )
        Set-ProtectedApplicationDirectoryAcl -Path $newInstall

        $newVersionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $newInstall 'Switzerland VPN.exe'))
        if ($newVersionInfo.CompanyName -ne $publisher -or $newVersionInfo.FileVersion -ne ($installVersion + '.0') -or
            @(Get-ChildItem -LiteralPath $newInstall -Force).Count -ne 10) {
            throw 'The staged upgrade failed its publisher, version, or file-layout check.'
        }

        Copy-AndVerifyUpgradeFile -Source $statePath -Destination $stateBackup
        Set-ProtectedApplicationDirectoryAcl -Path $installDir
        Set-ProtectedApplicationDirectoryAcl -Path $stateDir

        $rechecked = Get-ValidatedManagedUpgradeContext `
            -ExpectedVersion $Context.OldVersion `
            -RequireUpdateHelper:$Context.RequiredUpdateHelper
        if (-not [string]::Equals($rechecked.InstallId, $Context.InstallId, [StringComparison]::Ordinal)) {
            throw 'The installed ownership record changed while the upgrade was being prepared.'
        }
        Assert-PackageChecksums

        Move-Item -LiteralPath $installDir -Destination $backupInstall
        $backupMoved = $true
        Move-Item -LiteralPath $newInstall -Destination $installDir

        $updatedState = [ordered]@{}
        foreach ($entry in $Context.SanitizedState.GetEnumerator()) { $updatedState[$entry.Key] = $entry.Value }
        $updatedState.Version = $installVersion
        [IO.File]::WriteAllText($stateTemporary, ($updatedState | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
        [IO.File]::Replace($stateTemporary, $statePath, $stateReplaceBackup)
        $stateChanged = $true

        New-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -Value $installVersion `
            -PropertyType String -Force | Out-Null
        New-ItemProperty -LiteralPath $uninstallKey -Name Publisher -Value $publisher `
            -PropertyType String -Force | Out-Null
        $registryChanged = $true

        $verified = Get-ValidatedManagedUpgradeContext -ExpectedVersion $installVersion -RequireUpdateHelper
        if (-not [string]::Equals($verified.InstallId, $Context.InstallId, [StringComparison]::Ordinal)) {
            throw 'The upgraded installation failed its final ownership check.'
        }
        $verifiedRegistration = Get-ItemProperty -LiteralPath $uninstallKey
        if (-not [string]::Equals([string]$verifiedRegistration.Publisher, $publisher, [StringComparison]::Ordinal)) {
            throw 'The upgraded installation did not retain the new publisher identity.'
        }

        $upgradedExecutable = Join-Path $installDir 'Switzerland VPN.exe'
        $upgradedEmergencyUnlock = Join-Path $installDir 'Emergency Unlock.exe'
        New-Shortcut -Path $serverShortcutPath -Target $serverShortcutPowerShell `
            -Arguments $serverShortcutArguments `
            -WorkingDirectory $installDir -IconLocation "$upgradedExecutable,0"
        $serverShortcutCreated = $true
        if ($emergencyShortcutPreexisting) {
            Copy-Item -LiteralPath $emergencyShortcutPath -Destination $emergencyShortcutBackup -Force
        }
        $emergencyShortcutChanged = $true
        New-Shortcut -Path $emergencyShortcutPath -Target $upgradedEmergencyUnlock `
            -Arguments '' -WorkingDirectory $installDir -IconLocation "$upgradedEmergencyUnlock,0"

        try { Remove-Item -LiteralPath $transactionRoot -Recurse -Force }
        catch { }
        try {
            if (Test-Path -LiteralPath $stateReplaceBackup) {
                Remove-Item -LiteralPath $stateReplaceBackup -Force
            }
        }
        catch { }
    }
    catch {
        $failure = $_.Exception.Message
        $rollbackFailure = $null
        try {
            if ($emergencyShortcutChanged) {
                if ($emergencyShortcutPreexisting -and (Test-Path -LiteralPath $emergencyShortcutBackup -PathType Leaf)) {
                    Copy-Item -LiteralPath $emergencyShortcutBackup -Destination $emergencyShortcutPath -Force
                }
                else {
                    Remove-Item -LiteralPath $emergencyShortcutPath -Force -ErrorAction SilentlyContinue
                }
            }
            if ($serverShortcutCreated -and -not $serverShortcutPreexisting -and
                (Test-Path -LiteralPath $serverShortcutPath -PathType Leaf)) {
                Remove-Item -LiteralPath $serverShortcutPath -Force
            }
            if ($registryChanged) {
                New-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -Value $oldRegistryVersion `
                    -PropertyType String -Force | Out-Null
                New-ItemProperty -LiteralPath $uninstallKey -Name Publisher -Value $oldRegistryPublisher `
                    -PropertyType String -Force | Out-Null
            }
            if ($stateChanged -and (Test-Path -LiteralPath $stateBackup -PathType Leaf)) {
                Copy-Item -LiteralPath $stateBackup -Destination $stateTemporary -Force
                [IO.File]::Replace($stateTemporary, $statePath, $null)
            }
            if ($backupMoved -and (Test-Path -LiteralPath $backupInstall -PathType Container)) {
                if (Test-Path -LiteralPath $installDir) {
                    Move-Item -LiteralPath $installDir -Destination $failedInstall
                }
                Move-Item -LiteralPath $backupInstall -Destination $installDir
            }
            if (Test-Path -LiteralPath $installDir -PathType Container) {
                Get-ValidatedManagedUpgradeContext `
                    -ExpectedVersion $Context.OldVersion `
                    -RequireUpdateHelper:$Context.RequiredUpdateHelper | Out-Null
            }
            if (Test-Path -LiteralPath $transactionRoot) {
                Remove-Item -LiteralPath $transactionRoot -Recurse -Force
            }
            foreach ($path in @($stateTemporary, $stateReplaceBackup)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
            }
        }
        catch {
            $rollbackFailure = $_.Exception.Message
        }
        if ($rollbackFailure) {
            throw "$failure Automatic rollback also failed: $rollbackFailure Keep the installer open and ask Justichuu for help."
        }
        throw "$failure The previous installation was restored."
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($InstallParentDirectory)) {
        if ($ValidatePackageOnly) {
            $InstallParentDirectory = $env:ProgramFiles
        }
        else {
            $InstallParentDirectory = Get-ManagedInstallParentHint
            if ([string]::IsNullOrWhiteSpace($InstallParentDirectory)) {
                $InstallParentDirectory = Select-InstallParentDirectory
            }
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
    Assert-ValidatedServerPool
    $serverAddress = if ($ValidatePackageOnly -or -not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Get-ValidatedServer
    }
    else {
        $null
    }
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

    Assert-InstallParentIsProtected -Path $installParent
    Assert-DirectoryChainHasNoReparsePoints -Path (Split-Path -Parent $stateDir)
    if (Test-Path -LiteralPath $installDir -PathType Container) {
        Assert-DirectoryChainHasNoReparsePoints -Path $installDir
    }
    if (Test-Path -LiteralPath $stateDir -PathType Container) {
        Assert-DirectoryChainHasNoReparsePoints -Path $stateDir
    }

    $existingFolderIsManaged = Test-Path -LiteralPath $statePath -PathType Leaf
    $managedUpgradeContext = $null
    if ($existingFolderIsManaged) {
        try {
            $recordedVersion = [string](Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).Version
        }
        catch {
            throw 'The existing installation version record is damaged. Nothing was changed.'
        }
        if (@('1.0.9', '1.1.0', '1.1.1', '1.1.2', '1.2.0', '1.3.0', '1.3.1') -cnotcontains $recordedVersion) {
            throw "The installed version $recordedVersion cannot be upgraded by this package. Nothing was changed."
        }
        $managedUpgradeContext = Get-ValidatedManagedUpgradeContext `
            -ExpectedVersion $recordedVersion `
            -RequireUpdateHelper:($recordedVersion -in @('1.1.0', '1.1.1', '1.1.2', '1.2.0', '1.3.0', '1.3.1'))
    }
    if ((Test-Path -LiteralPath $installDir) -and -not $existingFolderIsManaged) {
        $items = @(Get-ChildItem -LiteralPath $installDir -Force -ErrorAction SilentlyContinue)
        if ($items.Count -gt 0) {
            throw "$installDir already exists and is not marked as this package's installation. Nothing was overwritten."
        }
    }

    if ((Test-Path -LiteralPath $stateDir) -and -not $existingFolderIsManaged) {
        $stateItems = @(Get-ChildItem -LiteralPath $stateDir -Force -ErrorAction SilentlyContinue)
        if ($stateItems.Count -gt 0) {
            throw "$stateDir already contains unmanaged files. Nothing was overwritten."
        }
    }

    $commonDesktopCollision = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Switzerland VPN.lnk'
    $commonStartCollision = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Switzerland VPN'
    if (-not $existingFolderIsManaged) {
        foreach ($collisionPath in $commonDesktopCollision, $commonStartCollision, $uninstallKey) {
            if (Test-Path -LiteralPath $collisionPath) {
                throw "An unmanaged installation item already exists: $collisionPath"
            }
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

if ($null -ne $managedUpgradeContext) {
    $answer = [Windows.Forms.MessageBox]::Show(
        "Upgrade Switzerland VPN from $($managedUpgradeContext.OldVersion) to ${installVersion}?`r`n`r`nOnly the app files and protected version records will change. The VPN profile, saved sign-in, certificate, connection, kill switch, firewall rules, and VPN server setting will stay as they are.",
        'Upgrade Switzerland VPN',
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Question,
        [Windows.Forms.MessageBoxDefaultButton]::Button1
    )
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { exit 0 }

    try {
        Invoke-ManagedInstallUpgrade -Context $managedUpgradeContext
    }
    catch {
        [Windows.Forms.MessageBox]::Show(
            "The app upgrade stopped.`r`n`r`n$($_.Exception.Message)`r`n`r`nThe VPN profile, connection, sign-in, certificate, and firewall rules were not changed.",
            'Switzerland VPN Upgrade Stopped',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit 2
    }

    $exePath = Join-Path $installDir 'Switzerland VPN.exe'
    $runNow = [Windows.Forms.MessageBox]::Show(
        "Upgrade complete. Run Switzerland VPN now?",
        'Switzerland VPN Upgraded',
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
                'The upgrade succeeded, but Windows could not open the app automatically. Open it from the Desktop or Start menu.',
                'Switzerland VPN Upgraded',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    }
    exit 0
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

    $connectionProfile = Get-VpnConnection -Name $vpnName -AllUserConnection -ErrorAction Stop
    if ($connectionProfile.ServerAddress -ne $serverAddress -or
        $connectionProfile.TunnelType -ne 'Ikev2' -or
        $connectionProfile.EncryptionLevel -ne 'Required' -or
        $connectionProfile.SplitTunneling -ne $false -or
        $connectionProfile.RememberCredential -ne $true -or
        $connectionProfile.IdleDisconnectSeconds -ne 0 -or
        $connectionProfile.AuthenticationMethod -notcontains 'Eap') {
        throw 'The installed Windows VPN profile failed verification.'
    }

    $remainingSwissProfiles = @(Get-ManagedSwissProfiles)
    if ($remainingSwissProfiles.Count -ne 1 -or
        $remainingSwissProfiles[0].Scope -ne 'All users' -or
        $remainingSwissProfiles[0].Name -ne $vpnName -or
        $remainingSwissProfiles[0].ServerAddress -ne $serverAddress) {
        throw 'Windows did not retain exactly one canonical all-user Switzerland VPN profile.'
    }

    # Repeat the trust checks immediately before creating privileged content so
    # a directory-link or ACL swap cannot hide in the confirmation window.
    Assert-InstallParentIsProtected -Path $installParent
    Assert-DirectoryChainHasNoReparsePoints -Path (Split-Path -Parent $stateDir)
    if (Test-Path -LiteralPath $installDir -PathType Container) {
        Assert-DirectoryChainHasNoReparsePoints -Path $installDir
    }
    if (Test-Path -LiteralPath $stateDir -PathType Container) {
        Assert-DirectoryChainHasNoReparsePoints -Path $stateDir
    }

    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    $createdInstallFolder = $true
    Set-ProtectedApplicationDirectoryAcl -Path $installDir
    if (@(Get-ChildItem -LiteralPath $installDir -Force).Count -ne 0) {
        throw 'The application folder changed while it was being secured. Nothing from it was used.'
    }
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    Set-ProtectedApplicationDirectoryAcl -Path $stateDir
    if (@(Get-ChildItem -LiteralPath $stateDir -Force).Count -ne 0) {
        throw 'The installation state folder changed while it was being secured. Nothing from it was used.'
    }

    foreach ($name in @(
        'Emergency Unlock.exe'
        'Switzerland VPN.exe'
        'Switzerland VPN.ico'
        'Switzerland VPN.png'
        'Switzerland VPN Background.png'
    )) {
        Copy-Item -LiteralPath (Join-Path $payloadDir $name) -Destination (Join-Path $installDir $name) -Force
    }
    foreach ($name in @('Update Switzerland VPN.ps1', 'Uninstall Switzerland VPN.ps1', 'Emergency Unlock.ps1', 'Switch Switzerland VPN Server.ps1')) {
        Copy-Item -LiteralPath (Join-Path $powershellBackupDir $name) -Destination (Join-Path $installDir $name) -Force
    }
    [IO.File]::WriteAllText((Join-Path $installDir 'VPN Server.txt'), $serverAddress + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath $serverPoolFile -Destination (Join-Path $installDir 'VPN Servers.txt') -Force

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
    $emergencyUnlockPath = Join-Path $installDir 'Emergency Unlock.exe'
    $powershellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    New-Shortcut -Path (Join-Path $desktop 'Switzerland VPN.lnk') -Target $exePath -Arguments '' -WorkingDirectory $installDir -IconLocation "$exePath,0"
    New-Shortcut -Path (Join-Path $startFolder 'Switzerland VPN.lnk') -Target $exePath -Arguments '' -WorkingDirectory $installDir -IconLocation "$exePath,0"
    New-Shortcut -Path (Join-Path $startFolder 'Emergency Unlock.lnk') -Target $emergencyUnlockPath `
        -Arguments '' -WorkingDirectory $installDir -IconLocation "$emergencyUnlockPath,0"
    New-Shortcut -Path (Join-Path $startFolder 'Choose Swiss VPN Server.lnk') -Target $powershellPath `
        -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $installDir 'Switch Switzerland VPN Server.ps1')`"" `
        -WorkingDirectory $installDir -IconLocation "$exePath,0"
    New-Shortcut -Path (Join-Path $startFolder 'Uninstall Switzerland VPN.lnk') -Target $powershellPath `
        -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $installDir 'Uninstall Switzerland VPN.ps1')`"" `
        -WorkingDirectory $env:SystemRoot -IconLocation "$exePath,0"
    Remove-VerifiedPerUserShortcuts -InstalledExecutable $exePath -PowerShellExecutable $powershellPath

    $registryCreationStarted = $true
    New-Item -Path $uninstallKey -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name DisplayName -Value 'Switzerland VPN' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value $installVersion -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name Publisher -Value $publisher -PropertyType String -Force | Out-Null
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
            ) -and
                (((Get-Item -LiteralPath $installDir -Force).Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -eq 0)) {
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
    if (-not $existingFolderIsManaged -and (Test-Path -LiteralPath $stateDir)) {
        try {
            if ((Get-ExactFullPath $stateDir) -eq (Get-ExactFullPath (Join-Path $env:ProgramData 'Switzerland VPN')) -and
                (((Get-Item -LiteralPath $stateDir -Force).Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -eq 0)) {
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
