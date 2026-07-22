# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [switch]$ApplyUpdate,

    [switch]$RecoverOnly,

    [string]$PackageZip = '',

    [string]$ExpectedSha256 = '',

    [string]$ExpectedVersion = '',

    [string]$ExpectedTag = '',

    [string]$TransactionId = '',

    [string]$GitHubCliPath = '',

    [int]$ParentProcessId = 0,

    [long]$ParentProcessStartTimeUtcTicks = 0,

    [int]$UpdaterProcessId = 0,

    [long]$UpdaterProcessStartTimeUtcTicks = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms

$productName = 'Switzerland VPN'
$repository = 'Justichuu/The-Swiss-Army-VPN'
$publisher = 'Justichuu'
# The project handle changed because I got bored; accept the old publisher only for safe upgrades.
$legacyPublisher = 'Jaye'
$stateDir = Join-Path $env:ProgramData $productName
$statePath = Join-Path $stateDir 'install-state.json'
$journalPath = Join-Path $stateDir 'update-journal.json'
$journalPreviousPath = Join-Path $stateDir 'update-journal.previous.json'
$ownershipFileName = 'install-ownership.json'
$uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Switzerland VPN Widget'
$powershellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$maximumPackageBytes = 100MB
$applicationMutexName = 'Global\SwitzerlandVPNWidget-9F71DB12'
$updaterMutexName = 'Global\SwitzerlandVPNUpdater-5DFB5198'
$minimumGitHubCliVersion = [version]'2.96.0'
$managedInstallFiles = @(
    'Emergency Unlock.exe'
    'Switzerland VPN.exe'
    'Switzerland VPN.ico'
    'Switzerland VPN.png'
    'Switzerland VPN Background.png'
    'Uninstall Switzerland VPN.ps1'
    'Emergency Unlock.ps1'
    'Switch Switzerland VPN Server.ps1'
    'Update Switzerland VPN.ps1'
    'VPN Servers.txt'
)
$preservedInstallFiles = @(
    'VPN Server.txt'
    $ownershipFileName
)
$allowedPackageEntries = @(
    'Install Switzerland VPN.exe'
    'Install Switzerland VPN.cmd'
    'Uninstall Switzerland VPN.cmd'
    'VPN Server.txt'
    'VPN Servers.txt'
    'Programs\Package Checksums.txt'
    'Programs\Executables\NordVPN Server Authentication Only.inf'
    'Programs\Executables\Emergency Unlock.exe'
    'Programs\Executables\Switzerland VPN Background.png'
    'Programs\Executables\Switzerland VPN.exe'
    'Programs\Executables\Switzerland VPN.ico'
    'Programs\Executables\Switzerland VPN.png'
    'Programs\PowerShell Backup\Emergency Unlock.ps1'
    'Programs\PowerShell Backup\Install Switzerland VPN.ps1'
    'Programs\PowerShell Backup\Switch Switzerland VPN Server.ps1'
    'Programs\PowerShell Backup\Uninstall Switzerland VPN.ps1'
    'Programs\PowerShell Backup\Update Switzerland VPN.ps1'
    'Programs\PowerShell Backup\Manual Backup\Switzerland VPN OFF.ps1'
    'Programs\PowerShell Backup\Manual Backup\Switzerland VPN ON.ps1'
    'Programs\PowerShell Backup\Manual Backup\Switzerland VPN.ps1'
    'Programs\PowerShell Backup\Manual Backup\VPN Profile.txt'
)

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-SupportedPublisher([string]$Value) {
    return [string]::Equals($Value, $publisher, [StringComparison]::Ordinal) -or
        [string]::Equals($Value, $legacyPublisher, [StringComparison]::Ordinal)
}

function Get-ExactFullPath {
    param([Parameter(Mandatory)][string]$Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-TrustedDirectoryPrincipalSids {
    $trustedSids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($sid in @(
        'S-1-5-18'
        'S-1-5-32-544'
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    )) {
        [void]$trustedSids.Add($sid)
    }
    return ,$trustedSids
}

function Assert-DirectoryChainHasNoReparsePoints {
    param([Parameter(Mandatory)][string]$Path)

    $current = [IO.DirectoryInfo]::new((Get-ExactFullPath $Path))
    if (-not $current.Exists) { throw "The protected folder is missing: $($current.FullName)" }
    while ($null -ne $current) {
        $item = Get-Item -LiteralPath $current.FullName -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "A protected update path uses a directory link or mount point: $($item.FullName)"
        }
        $current = $current.Parent
    }
}

function Test-RuleGrantsDirectoryWrite {
    param([Parameter(Mandatory)][Security.AccessControl.FileSystemAccessRule]$Rule)

    if ($Rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
        return $false
    }
    if (($Rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0 -and
        $Rule.InheritanceFlags -eq [Security.AccessControl.InheritanceFlags]::None) {
        return $false
    }

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
    $writeMask = $writeMask -bor 0x10000000L -bor 0x40000000L
    return (($rights -band $writeMask) -ne 0)
}

function Assert-InstallParentIsProtected {
    param([Parameter(Mandatory)][string]$Path)

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
        throw 'The installed app parent has an unsafe unrestricted access list.'
    }
    $ownerSid = $security.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if (-not $trustedSids.Contains($ownerSid)) {
        throw 'The installed app parent is controlled by an untrusted account. Reinstall into Program Files.'
    }
    foreach ($rule in $security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        $sid = $rule.IdentityReference.Value
        $safeCreatorOwner = $sid -eq 'S-1-3-0' -and
            ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0
        if (-not $trustedSids.Contains($sid) -and -not $safeCreatorOwner -and
            (Test-RuleGrantsDirectoryWrite -Rule $rule)) {
            throw 'The installed app parent is writable by an untrusted account. Reinstall into Program Files.'
        }
    }
}

function Assert-ProtectedApplicationDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Get-ExactFullPath $Path
    Assert-DirectoryChainHasNoReparsePoints -Path $fullPath
    $security = [IO.Directory]::GetAccessControl(
        $fullPath,
        [Security.AccessControl.AccessControlSections]::Access -bor
            [Security.AccessControl.AccessControlSections]::Owner
    )
    $administratorsSid = 'S-1-5-32-544'
    if (-not $security.AreAccessRulesProtected -or
        $security.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $administratorsSid) {
        throw 'The Switzerland VPN protected-folder permissions changed. Reinstall before updating.'
    }

    $expectedRules = [Collections.Generic.Dictionary[string, uint64]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($definition in @(
        [pscustomobject]@{ Sid = 'S-1-5-18'; Rights = [Security.AccessControl.FileSystemRights]::FullControl }
        [pscustomobject]@{ Sid = $administratorsSid; Rights = [Security.AccessControl.FileSystemRights]::FullControl }
        [pscustomobject]@{ Sid = 'S-1-5-32-545'; Rights = [Security.AccessControl.FileSystemRights]::ReadAndExecute }
    )) {
        $expectedRules.Add(
            $definition.Sid,
            [uint64]([int64][int32]$definition.Rights -band 0xFFFFFFFFL)
        )
    }
    $actualRules = @($security.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
    if ($actualRules.Count -ne $expectedRules.Count) {
        throw 'The Switzerland VPN protected-folder permissions changed. Reinstall before updating.'
    }
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($rule in $actualRules) {
        $sid = $rule.IdentityReference.Value
        $rights = [uint64]([int64][int32]$rule.FileSystemRights -band 0xFFFFFFFFL)
        if (-not $expectedRules.ContainsKey($sid) -or
            $rights -ne $expectedRules[$sid] -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.InheritanceFlags -ne $inheritance -or
            $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) {
            throw 'The Switzerland VPN protected-folder permissions changed. Reinstall before updating.'
        }
    }
}

function Set-ProtectedApplicationDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Get-ExactFullPath $Path
    Assert-DirectoryChainHasNoReparsePoints -Path $fullPath
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $usersSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($administratorsSid)
    foreach ($definition in @(
        [pscustomobject]@{ Sid = $systemSid; Rights = [Security.AccessControl.FileSystemRights]::FullControl }
        [pscustomobject]@{ Sid = $administratorsSid; Rights = [Security.AccessControl.FileSystemRights]::FullControl }
        [pscustomobject]@{ Sid = $usersSid; Rights = [Security.AccessControl.FileSystemRights]::ReadAndExecute }
    )) {
        [void]$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $definition.Sid,
            $definition.Rights,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            $allow
        ))
    }
    [IO.Directory]::SetAccessControl($fullPath, $security)
    Assert-ProtectedApplicationDirectoryAcl -Path $fullPath
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Write-DurableJournal {
    param([Parameter(Mandatory)][object]$Value)

    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    $temporaryPath = Join-Path $stateDir ('update-journal.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $json = $Value | ConvertTo-Json -Depth 12
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = $null
    try {
        $stream = [IO.FileStream]::new(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null

        if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $journalPath, $journalPreviousPath, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $journalPath)
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-UpdateJournal {
    foreach ($path in @($journalPath, $journalPreviousPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        }
        catch { }
    }
    throw 'An unreadable update recovery journal exists. Ask Justichuu before updating again.'
}

function Get-ValidatedTransactionId {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -cnotmatch '^[a-f0-9]{32}$') {
        throw 'The updater received an invalid transaction ID.'
    }
    return $Value
}

function New-SecureStatusDirectory {
    param([Parameter(Mandatory)][string]$Id)

    $validatedId = Get-ValidatedTransactionId $Id
    $updatesRoot = Join-Path $stateDir 'Updates'
    if (-not (Test-Path -LiteralPath $updatesRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $updatesRoot | Out-Null
    }
    $rootItem = Get-Item -LiteralPath $updatesRoot -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The protected update-status folder is linked. Update stopped safely.'
    }

    $statusDirectory = Join-Path $updatesRoot $validatedId
    if (Test-Path -LiteralPath $statusDirectory) {
        throw 'The protected update transaction already exists. Try the update again.'
    }
    New-Item -ItemType Directory -Path $statusDirectory | Out-Null

    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sid in @(
        [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    )) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            $allow
        )
        $security.AddAccessRule($rule)
    }
    $usersRule = [Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $inheritance,
        $propagation,
        $allow
    )
    $security.AddAccessRule($usersRule)
    Set-Acl -LiteralPath $statusDirectory -AclObject $security
    return $statusDirectory
}

function Get-StatusDirectoryPath {
    param([Parameter(Mandatory)][string]$Id)

    return Join-Path (Join-Path $stateDir 'Updates') (Get-ValidatedTransactionId $Id)
}

function Show-UpdateMessage {
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][Windows.Forms.MessageBoxIcon]$Icon
    )

    [Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [Windows.Forms.MessageBoxButtons]::OK,
        $Icon
    ) | Out-Null
}

function Get-SafeInstallDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [IO.Path]::IsPathRooted($Path) -or
        $Path.StartsWith('\\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('//', [StringComparison]::Ordinal) -or
        $Path.Contains('"')) {
        throw 'The saved install location is not a safe local folder.'
    }

    try {
        $fullPath = Get-ExactFullPath $Path
        $root = [IO.Path]::GetPathRoot($fullPath)
        if ($root -notmatch '^[A-Za-z]:\\$' -or
            -not [string]::Equals(
                [IO.Path]::GetFileName($fullPath),
                $productName,
                [StringComparison]::Ordinal
            )) {
            throw 'invalid path'
        }

        $drive = [IO.DriveInfo]::new($root)
        if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) {
            throw 'invalid drive'
        }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
            throw 'missing folder'
        }
        $directory = Get-Item -LiteralPath $fullPath -Force
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'linked folder'
        }
    }
    catch {
        throw 'The saved install location is not a Switzerland VPN folder on a local fixed drive.'
    }

    return $fullPath
}

function Get-ValidatedInstallContext {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'Switzerland VPN installation data is missing. Reinstall the app before updating.'
    }

    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    }
    catch {
        throw 'Switzerland VPN installation data is damaged. Reinstall the app before updating.'
    }

    foreach ($propertyName in @(
        'ProductName', 'Version', 'InstallId', 'InstallDirectory', 'ProfileName',
        'ServerAddress', 'FirewallRuleGroup', 'CertificateThumbprint'
    )) {
        if ($state.PSObject.Properties.Name -notcontains $propertyName -or
            [string]::IsNullOrWhiteSpace([string]$state.$propertyName)) {
            throw "Switzerland VPN installation data is incomplete ($propertyName)."
        }
    }
    if (-not [string]::Equals([string]$state.ProductName, $productName, [StringComparison]::Ordinal) -or
        -not [guid]::TryParse([string]$state.InstallId, [ref]([guid]::Empty)) -or
        [string]$state.Version -notmatch '^\d+\.\d+\.\d+$') {
        throw 'Switzerland VPN installation ownership data is invalid.'
    }

    $installDirectory = Get-SafeInstallDirectory ([string]$state.InstallDirectory)
    $markerPath = Join-Path $installDirectory $ownershipFileName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw 'The installation ownership marker is missing. Nothing was changed.'
    }
    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    }
    catch {
        throw 'The installation ownership marker is damaged. Nothing was changed.'
    }
    foreach ($propertyName in @('ProductName', 'InstallId', 'InstallDirectory', 'Version')) {
        if ($marker.PSObject.Properties.Name -notcontains $propertyName -or
            [string]::IsNullOrWhiteSpace([string]$marker.$propertyName)) {
            throw "The installation ownership marker is incomplete ($propertyName)."
        }
    }
    if (-not [string]::Equals([string]$marker.ProductName, $productName, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$marker.InstallId, [string]$state.InstallId, [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            (Get-ExactFullPath ([string]$marker.InstallDirectory)),
            $installDirectory,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals([string]$marker.Version, [string]$state.Version, [StringComparison]::Ordinal)) {
        throw 'The installation ownership marker does not match the saved installation. Nothing was changed.'
    }

    $appPath = Join-Path $installDirectory 'Switzerland VPN.exe'
    if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) {
        throw 'The installed Switzerland VPN program is missing.'
    }
    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($appPath)
    if (-not (Test-SupportedPublisher ([string]$versionInfo.CompanyName)) -or
        $versionInfo.FileVersion -ne (([string]$state.Version) + '.0')) {
        throw 'The installed program version does not match its ownership data. Reinstall before updating.'
    }

    return [pscustomobject]@{
        State = $state
        Marker = $marker
        InstallDirectory = $installDirectory
        AppPath = $appPath
        CurrentVersion = [version]([string]$state.Version)
    }
}

function Assert-CurrentInstallLayout {
    param([Parameter(Mandatory)][string]$InstallDirectory)

    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $managedInstallFiles + $preservedInstallFiles) {
        [void]$allowed.Add($name)
    }
    foreach ($item in Get-ChildItem -LiteralPath $InstallDirectory -Force) {
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not $allowed.Contains($item.Name)) {
            throw "The install folder contains an unexpected item: $($item.Name). Nothing was overwritten."
        }
    }
    foreach ($name in $preservedInstallFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $InstallDirectory $name) -PathType Leaf)) {
            throw "The installed file '$name' is missing. Nothing was changed."
        }
    }
}

function Get-GitHubCliPath {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe')
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'GitHub CLI\gh.exe' })
    )
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate) -or
            -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }

        $fullPath = Get-ExactFullPath $candidate
        if (-not [IO.Path]::IsPathRooted($fullPath) -or $fullPath.StartsWith('\\')) { continue }
        $file = Get-Item -LiteralPath $fullPath -Force
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $signature = Get-AuthenticodeSignature -LiteralPath $fullPath
        if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
            $null -eq $signature.SignerCertificate -or
            [string]$signature.SignerCertificate.Subject -notmatch '(?i)(CN|O)="?GitHub, Inc\."?') { continue }
        $productVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($fullPath).ProductVersion
        if ([string]$productVersion -notmatch '^(\d+\.\d+\.\d+)' -or
            [version]$matches[1] -lt $minimumGitHubCliVersion) { continue }
        return $fullPath
    }
    throw 'A signed, system-wide GitHub CLI 2.96 or newer is required. Install it with: winget install --id GitHub.cli'
}

function Get-ValidatedGitHubCliPath {
    param([Parameter(Mandatory)][string]$RequestedPath)

    $trustedPath = Get-GitHubCliPath
    if ([string]::IsNullOrWhiteSpace($RequestedPath)) { return $trustedPath }
    if (-not [string]::Equals(
        (Get-ExactFullPath $RequestedPath),
        $trustedPath,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The update request did not use the trusted system GitHub CLI.'
    }
    return $trustedPath
}

function Invoke-GitHubCli {
    param(
        [Parameter(Mandatory)][string]$GitHubCli,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$ReturnOutput,
        [ValidateRange(5, 240)][int]$TimeoutSeconds = 45
    )

    foreach ($variableName in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_HOST', 'GH_REPO', 'GH_CONFIG_DIR')) {
        Remove-Item -LiteralPath ("Env:" + $variableName) -ErrorAction SilentlyContinue
    }

    $quotedArguments = foreach ($argument in $Arguments) {
        $value = [string]$argument
        if ($value.Contains('"') -or $value.Contains("`r") -or $value.Contains("`n")) {
            throw 'GitHub CLI received an unsafe argument.'
        }
        if ($value.Length -eq 0 -or $value.IndexOfAny([char[]]" `t") -ge 0) {
            '"' + $value + '"'
        }
        else {
            $value
        }
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $GitHubCli
    $startInfo.Arguments = $quotedArguments -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($variableName in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_HOST', 'GH_REPO', 'GH_CONFIG_DIR')) {
        $startInfo.EnvironmentVariables.Remove($variableName)
    }

    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'GitHub CLI did not start.' }
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            $process.WaitForExit()
            throw 'GitHub did not respond in time. Nothing was installed.'
        }
        if (-not $standardOutput.Wait(5000) -or -not $standardError.Wait(5000)) {
            throw 'GitHub output did not finish cleanly. Nothing was installed.'
        }
        if ($process.ExitCode -ne 0) {
            throw 'GitHub could not verify the private immutable release. Check sign-in, repository access, and internet access.'
        }
        if ($ReturnOutput) {
            $output = [string]$standardOutput.Result
            if ($output.Length -gt 1MB) { throw 'GitHub returned too much release data.' }
            return $output
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-ExactReleaseAssets {
    param(
        [Parameter(Mandatory)][object]$Release,
        [Parameter(Mandatory)][string]$Version
    )

    $escapedVersion = [regex]::Escape($Version)
    $zipPattern = "^Switzerland[ .]VPN[ .]Distribution[ .]$escapedVersion\.zip$"
    $checksumPattern = "^Switzerland[ .]VPN[ .]Distribution[ .]$escapedVersion[ .]SHA256\.txt$"
    $zipAssets = @($Release.assets | Where-Object { [string]$_.name -match $zipPattern })
    $checksumAssets = @($Release.assets | Where-Object { [string]$_.name -match $checksumPattern })
    if ($zipAssets.Count -ne 1 -or $checksumAssets.Count -ne 1) {
        throw 'The release does not contain exactly one application ZIP and checksum file.'
    }
    return [pscustomobject]@{ Zip = $zipAssets[0]; Checksum = $checksumAssets[0] }
}

function Get-VerifiedReleaseMetadata {
    param(
        [Parameter(Mandatory)][string]$GitHubCli,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Version
    )

    if ($Tag -cne ('v' + $Version) -or $Tag -cnotmatch '^v\d+\.\d+\.\d+$') {
        throw 'The requested release tag and version do not match.'
    }
    $releaseJson = Invoke-GitHubCli -GitHubCli $GitHubCli -Arguments @(
        'release', 'view', $Tag, '--repo', $repository,
        '--json', 'tagName,isDraft,isPrerelease,isImmutable,assets,url'
    ) -ReturnOutput
    try { $release = $releaseJson | ConvertFrom-Json }
    catch { throw 'GitHub returned unreadable release information.' }
    if ([string]$release.tagName -cne $Tag -or $release.isDraft -or
        $release.isPrerelease -or -not $release.isImmutable) {
        throw 'The requested release is not a final immutable release.'
    }

    $assets = Get-ExactReleaseAssets -Release $release -Version $Version
    if ([string]$assets.Zip.state -cne 'uploaded' -or
        [string]$assets.Checksum.state -cne 'uploaded' -or
        [long]$assets.Zip.size -le 0 -or [long]$assets.Zip.size -gt $maximumPackageBytes -or
        [long]$assets.Checksum.size -le 0 -or [long]$assets.Checksum.size -gt 4096 -or
        [string]$assets.Zip.digest -notmatch '^sha256:[A-Fa-f0-9]{64}$' -or
        [string]$assets.Checksum.digest -notmatch '^sha256:[A-Fa-f0-9]{64}$') {
        throw 'The immutable release assets have invalid metadata.'
    }
    return [pscustomobject]@{ Release = $release; Assets = $assets }
}

function Get-ExpectedChecksum {
    param(
        [Parameter(Mandatory)][string]$ChecksumPath,
        [Parameter(Mandatory)][string]$Version
    )

    $content = (Get-Content -LiteralPath $ChecksumPath -Raw).Trim()
    $escapedVersion = [regex]::Escape($Version)
    $pattern = "^([A-Fa-f0-9]{64})\s+\*?Switzerland[ .]VPN[ .]Distribution[ .]$escapedVersion\.zip$"
    if ($content -notmatch $pattern) {
        throw 'The release checksum file has an invalid format or filename.'
    }
    return $matches[1].ToUpperInvariant()
}

function Copy-AndLockPackage {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ExpectedHash
    )

    $sourceStream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($sourceStream.Length -le 0 -or $sourceStream.Length -gt $maximumPackageBytes) {
            throw 'The update ZIP has an unsafe size.'
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $actual = ([BitConverter]::ToString($sha.ComputeHash($sourceStream))).Replace('-', '')
        }
        finally {
            $sha.Dispose()
        }
        if ($actual -ne $ExpectedHash) { throw 'The update ZIP changed after verification.' }
        $sourceStream.Position = 0
        $destinationStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $sourceStream.CopyTo($destinationStream) }
        finally { $destinationStream.Dispose() }
    }
    finally {
        $sourceStream.Dispose()
    }

    $copiedHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($copiedHash -ne $ExpectedHash) { throw 'The protected update copy failed verification.' }
}

function Expand-ValidatedPackage {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $allowedPackageEntries) { [void]$allowed.Add($name) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $totalBytes = [long]0
    $stream = [IO.File]::Open($ZipPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            foreach ($entry in $archive.Entries) {
                $name = $entry.FullName.Replace('/', '\')
                if ([string]::IsNullOrWhiteSpace($entry.Name) -or
                    -not $allowed.Contains($name) -or
                    -not $seen.Add($name) -or
                    $name.StartsWith('\', [StringComparison]::Ordinal) -or
                    $name.Contains(':') -or
                    @($name.Split('\') | Where-Object { $_ -eq '..' }).Count -gt 0 -or
                    (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or
                    ($entry.ExternalAttributes -band 0x400) -ne 0) {
                    throw "The update ZIP contains an unsafe or unexpected entry: $name"
                }
                $totalBytes += [long]$entry.Length
                if ($entry.Length -gt $maximumPackageBytes -or $totalBytes -gt $maximumPackageBytes) {
                    throw 'The expanded update package is too large.'
                }
            }
            if ($seen.Count -ne $allowed.Count) {
                $missing = @($allowedPackageEntries | Where-Object { -not $seen.Contains($_) })
                throw "The update package is incomplete. Missing: $($missing -join ', ')"
            }

            foreach ($entry in $archive.Entries) {
                $name = $entry.FullName.Replace('/', '\')
                $target = Join-Path $Destination $name
                $parent = Split-Path -Parent $target
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                $input = $entry.Open()
                try {
                    $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try { $input.CopyTo($output) }
                    finally { $output.Dispose() }
                }
                finally { $input.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Assert-PackageManifest {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$Version
    )

    $programs = Join-Path $PackageRoot 'Programs'
    $manifest = Join-Path $programs 'Package Checksums.txt'
    $listed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in Get-Content -LiteralPath $manifest) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([A-Fa-f0-9]{64})\s+\*(Programs\\.+)$') {
            throw "Invalid package checksum entry: $line"
        }
        $relative = $matches[2]
        $expected = $matches[1].ToUpperInvariant()
        if (-not $listed.Add($relative)) { throw "Duplicate package checksum entry: $relative" }
        $path = Join-Path $PackageRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expected) {
            throw "Package integrity check failed: $relative"
        }
    }
    $actual = @(
        Get-ChildItem -LiteralPath $programs -Recurse -File |
            Where-Object { -not [string]::Equals($_.FullName, $manifest, [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { 'Programs\' + $_.FullName.Substring($programs.Length + 1) }
    )
    if ($listed.Count -ne $actual.Count -or @($actual | Where-Object { -not $listed.Contains($_) }).Count -gt 0) {
        throw 'The package checksum manifest does not exactly cover the Programs payload.'
    }

    $newExe = Join-Path $PackageRoot 'Programs\Executables\Switzerland VPN.exe'
    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($newExe)
    if ($versionInfo.CompanyName -ne $publisher -or $versionInfo.FileVersion -ne ($Version + '.0')) {
        throw 'The update executable has the wrong publisher or version.'
    }
}

function Get-ExactAppProcess {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][long]$StartTimeUtcTicks,
        [Parameter(Mandatory)][string]$AppPath
    )

    if ($ProcessId -le 0) { return $null }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    try {
        if (-not [string]::Equals(
            (Get-ExactFullPath $process.Path),
            (Get-ExactFullPath $AppPath),
            [StringComparison]::OrdinalIgnoreCase
        ) -or ($StartTimeUtcTicks -gt 0 -and $process.StartTime.ToUniversalTime().Ticks -ne $StartTimeUtcTicks)) {
            return $null
        }
    }
    catch { return $null }
    return $process
}

function Get-ExactUpdaterProcess {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][long]$StartTimeUtcTicks,
        [Parameter(Mandatory)][string]$ScriptPath
    )

    if ($ProcessId -le 0 -or $StartTimeUtcTicks -le 0) { return $null }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    try {
        if (-not [string]::Equals(
            (Get-ExactFullPath $process.Path),
            (Get-ExactFullPath $powershellPath),
            [StringComparison]::OrdinalIgnoreCase
        ) -or $process.StartTime.ToUniversalTime().Ticks -ne $StartTimeUtcTicks) {
            return $null
        }
        $wmi = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId=" + $ProcessId)
        if ($null -eq $wmi -or [string]::IsNullOrWhiteSpace([string]$wmi.CommandLine)) { return $null }
        $escapedScript = [regex]::Escape((Get-ExactFullPath $ScriptPath))
        if ([string]$wmi.CommandLine -notmatch ("(?i)(?:^|\s)-File\s+`"?" + $escapedScript + "`"?(?:\s|$)")) {
            return $null
        }
    }
    catch { return $null }
    return $process
}

function Wait-ForAppExit {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][long]$StartTimeUtcTicks,
        [Parameter(Mandatory)][string]$AppPath
    )

    if ($ProcessId -le 0) { return }
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($null -eq (Get-ExactAppProcess -ProcessId $ProcessId -StartTimeUtcTicks $StartTimeUtcTicks -AppPath $AppPath)) {
            return
        }
        Start-Sleep -Milliseconds 150
    }
    throw 'The widget did not close in time. The update was canceled before any files changed.'
}

function Enter-NamedMutex {
    param([Parameter(Mandatory)][string]$Name)

    $created = $false
    $mutex = [Threading.Mutex]::new($false, $Name, [ref]$created)
    try {
        try { $owned = $mutex.WaitOne(1000) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another Switzerland VPN update is already running.' }
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-NamedMutex {
    param([AllowNull()][Threading.Mutex]$Mutex)

    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { }
    $Mutex.Dispose()
}

function New-UpdatedObject {
    param(
        [Parameter(Mandatory)][object]$Source,
        [Parameter(Mandatory)][string]$Version
    )

    $copy = $Source | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $copy.Version = $Version
    if ($copy.PSObject.Properties.Name -contains 'UpdatedUtc') {
        $copy.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    }
    else {
        $copy | Add-Member -NotePropertyName UpdatedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
    }
    return $copy
}

function Get-InstallFileManifest {
    param([Parameter(Mandatory)][string]$Directory)

    $directoryPath = Get-ExactFullPath $Directory
    $directoryItem = Get-Item -LiteralPath $directoryPath -Force
    if (-not $directoryItem.PSIsContainer -or
        ($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'An update backup folder is not a normal directory.'
    }

    $requiredNames = @($managedInstallFiles + $preservedInstallFiles)
    $required = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $requiredNames) { [void]$required.Add($name) }
    $items = @(Get-ChildItem -LiteralPath $directoryPath -Force)
    if ($items.Count -ne $required.Count) {
        throw 'The installed-file backup is incomplete.'
    }

    $manifest = @()
    foreach ($item in $items) {
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not $required.Contains($item.Name)) {
            throw "The installed-file backup contains an unexpected item: $($item.Name)."
        }
    }
    foreach ($name in $requiredNames) {
        $path = Join-Path $directoryPath $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The installed-file backup is missing $name."
        }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The installed-file backup contains a linked file: $name."
        }
        $manifest += [pscustomobject][ordered]@{
            Name = $name
            Length = [long]$item.Length
            Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
    }
    return $manifest
}

function Assert-MatchingFileManifests {
    param(
        [Parameter(Mandatory)][object[]]$Expected,
        [Parameter(Mandatory)][object[]]$Actual
    )

    if ($Expected.Count -ne $Actual.Count) { throw 'The installed-file backup is incomplete.' }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if (-not [string]::Equals([string]$Expected[$index].Name, [string]$Actual[$index].Name, [StringComparison]::Ordinal) -or
            [long]$Expected[$index].Length -ne [long]$Actual[$index].Length -or
            -not [string]::Equals([string]$Expected[$index].Sha256, [string]$Actual[$index].Sha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The installed-file backup does not match $([string]$Expected[$index].Name)."
        }
    }
}

function Assert-BackupMatchesJournal {
    param(
        [Parameter(Mandatory)][string]$BackupDirectory,
        [Parameter(Mandatory)][object]$Journal
    )

    if ($Journal.PSObject.Properties.Name -notcontains 'BackupFiles') {
        throw 'The update recovery journal has no verified backup manifest.'
    }
    $expected = @($Journal.BackupFiles)
    $actual = @(Get-InstallFileManifest -Directory $BackupDirectory)
    foreach ($entry in $expected) {
        if ($entry.PSObject.Properties.Name -notcontains 'Name' -or
            $entry.PSObject.Properties.Name -notcontains 'Length' -or
            $entry.PSObject.Properties.Name -notcontains 'Sha256' -or
            [string]$entry.Sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            [long]$entry.Length -lt 0) {
            throw 'The update recovery journal has an invalid backup manifest.'
        }
    }
    Assert-MatchingFileManifests -Expected $expected -Actual $actual
}

function Set-JournalPhase {
    param(
        [Parameter(Mandatory)][object]$Journal,
        [Parameter(Mandatory)][string]$Phase
    )

    $Journal.Phase = $Phase
    $Journal.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    Write-DurableJournal -Value $Journal
}

function Set-FileFromStagedCopy {
    param(
        [Parameter(Mandatory)][string]$StagedPath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
        [IO.File]::Replace($StagedPath, $DestinationPath, $null, $true)
    }
    else {
        [IO.File]::Move($StagedPath, $DestinationPath)
    }
}

function Assert-StateFileMatchesJournal {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Journal,
        [Parameter(Mandatory)][string]$Version
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'The saved installation state needed for recovery is missing.'
    }
    try { $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw 'The saved installation state needed for recovery is damaged.' }
    foreach ($propertyName in @('ProductName', 'InstallId', 'InstallDirectory', 'Version')) {
        if ($state.PSObject.Properties.Name -notcontains $propertyName) {
            throw 'The saved installation state needed for recovery is incomplete.'
        }
    }
    if (-not [string]::Equals([string]$state.ProductName, $productName, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$state.InstallId, [string]$Journal.InstallId, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$state.Version, $Version, [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            (Get-ExactFullPath ([string]$state.InstallDirectory)),
            (Get-ExactFullPath ([string]$Journal.InstallDirectory)),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'The saved installation state does not match the update recovery journal.'
    }
}

function Assert-InstalledVersionMatchesJournal {
    param(
        [Parameter(Mandatory)][object]$Journal,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][bool]$RegistryVersionExisted,
        [AllowEmptyString()][string]$RegistryVersion = ''
    )

    $context = Get-ValidatedInstallContext
    if (-not [string]::Equals([string]$context.State.InstallId, [string]$Journal.InstallId, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$context.State.Version, $Version, [StringComparison]::Ordinal) -or
        -not [string]::Equals($context.InstallDirectory, (Get-ExactFullPath ([string]$Journal.InstallDirectory)), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The recovered installation does not match the update recovery journal.'
    }

    if (-not (Test-Path -LiteralPath $uninstallKey)) {
        throw 'The Windows uninstall registration is missing after update recovery.'
    }
    $registration = Get-ItemProperty -LiteralPath $uninstallKey
    $displayVersionExists = $registration.PSObject.Properties.Name -contains 'DisplayVersion'
    if ($RegistryVersionExisted) {
        if (-not $displayVersionExists -or
            -not [string]::Equals([string]$registration.DisplayVersion, $RegistryVersion, [StringComparison]::Ordinal)) {
            throw 'The Windows version registration was not recovered.'
        }
    }
    elseif ($displayVersionExists) {
        throw 'The Windows version registration was not recovered.'
    }
}

function Remove-UpdateRecoveryArtifacts {
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [switch]$RemoveJournal
    )

    if ($RemoveJournal -and (Test-Path -LiteralPath $journalPreviousPath -PathType Leaf)) {
        Remove-Item -LiteralPath $journalPreviousPath -Force
    }
    foreach ($path in $Paths) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
    if ($RemoveJournal -and (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        Remove-Item -LiteralPath $journalPath -Force
    }
}

function Restore-IncompleteUpdate {
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf) -and
        -not (Test-Path -LiteralPath $journalPreviousPath -PathType Leaf)) { return }
    Assert-ProtectedApplicationDirectoryAcl -Path $stateDir
    $journal = Read-UpdateJournal
    foreach ($propertyName in @(
        'TransactionId', 'InstallId', 'InstallDirectory', 'Phase',
        'FromVersion', 'ToVersion', 'RegistryVersionExisted', 'OldRegistryVersion'
    )) {
        if ($journal.PSObject.Properties.Name -notcontains $propertyName) {
            throw 'The update recovery journal is incomplete. Ask Justichuu before updating again.'
        }
    }
    if ([string]$journal.FromVersion -notmatch '^\d+\.\d+\.\d+$' -or
        [string]$journal.ToVersion -notmatch '^\d+\.\d+\.\d+$' -or
        @('Prepared', 'BackupReady', 'FilesUpdated', 'StateUpdated', 'RegistryUpdated', 'Committed', 'RolledBack') `
            -cnotcontains [string]$journal.Phase) {
        throw 'The update recovery journal contains an invalid phase or version.'
    }

    $id = Get-ValidatedTransactionId ([string]$journal.TransactionId)
    $installDirectory = Get-ExactFullPath ([string]$journal.InstallDirectory)
    $root = [IO.Path]::GetPathRoot($installDirectory)
    if ($root -notmatch '^[A-Za-z]:\\$' -or
        -not [string]::Equals([IO.Path]::GetFileName($installDirectory), $productName, [StringComparison]::Ordinal)) {
        throw 'The update recovery journal has an unsafe install location.'
    }
    $drive = [IO.DriveInfo]::new($root)
    if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) {
        throw 'The update recovery journal points to an unavailable drive.'
    }

    $parentDirectory = Split-Path -Parent $installDirectory
    Assert-InstallParentIsProtected -Path $parentDirectory
    Assert-ProtectedApplicationDirectoryAcl -Path $installDirectory
    $transactionRoot = Join-Path $parentDirectory ('.Switzerland VPN.update-' + $id)
    $backupDirectory = Join-Path $parentDirectory ('.Switzerland VPN.backup-' + $id)
    $restoreDirectory = Join-Path $parentDirectory ('.Switzerland VPN.restore-' + $id)
    $stateTemporary = Join-Path $stateDir ('install-state.update-' + $id + '.json')
    $stateBackup = Join-Path $stateDir ('install-state.backup-' + $id + '.json')
    $recoveryPaths = @($restoreDirectory, $transactionRoot, $stateTemporary, $stateBackup, $backupDirectory)

    if ([string]$journal.Phase -eq 'Committed') {
        Assert-InstalledVersionMatchesJournal -Journal $journal -Version ([string]$journal.ToVersion) `
            -RegistryVersionExisted $true -RegistryVersion ([string]$journal.ToVersion)
        Remove-UpdateRecoveryArtifacts -Paths $recoveryPaths -RemoveJournal
        return
    }

    if ([string]$journal.Phase -eq 'RolledBack') {
        Assert-InstalledVersionMatchesJournal -Journal $journal -Version ([string]$journal.FromVersion) `
            -RegistryVersionExisted ([bool]$journal.RegistryVersionExisted) `
            -RegistryVersion ([string]$journal.OldRegistryVersion)
        Remove-UpdateRecoveryArtifacts -Paths $recoveryPaths -RemoveJournal
        return
    }

    if ([string]$journal.Phase -eq 'Prepared') {
        Assert-InstalledVersionMatchesJournal -Journal $journal -Version ([string]$journal.FromVersion) `
            -RegistryVersionExisted ([bool]$journal.RegistryVersionExisted) `
            -RegistryVersion ([string]$journal.OldRegistryVersion)
        Set-JournalPhase -Journal $journal -Phase 'RolledBack'
        Remove-UpdateRecoveryArtifacts -Paths $recoveryPaths -RemoveJournal
        return
    }

    if (-not (Test-Path -LiteralPath $backupDirectory -PathType Container)) {
        throw 'An interrupted update has no complete rollback folder. Ask Justichuu before updating again.'
    }
    Assert-BackupMatchesJournal -BackupDirectory $backupDirectory -Journal $journal

    if (Test-Path -LiteralPath $stateBackup -PathType Leaf) {
        Assert-StateFileMatchesJournal -Path $stateBackup -Journal $journal -Version ([string]$journal.FromVersion)
    }
    else {
        Assert-StateFileMatchesJournal -Path $statePath -Journal $journal -Version ([string]$journal.FromVersion)
    }
    if (-not (Test-Path -LiteralPath $installDirectory -PathType Container)) {
        throw 'The installed app folder is missing. The verified backup was kept for manual recovery.'
    }
    $installItem = Get-Item -LiteralPath $installDirectory -Force
    if (($installItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The installed app folder is linked. Automatic recovery stopped safely.'
    }

    if (Test-Path -LiteralPath $restoreDirectory) {
        Remove-Item -LiteralPath $restoreDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $restoreDirectory | Out-Null
    Set-ProtectedApplicationDirectoryAcl -Path $restoreDirectory
    foreach ($name in @($managedInstallFiles + $preservedInstallFiles)) {
        $stagedPath = Join-Path $restoreDirectory $name
        Copy-Item -LiteralPath (Join-Path $backupDirectory $name) -Destination $stagedPath
        Set-FileFromStagedCopy -StagedPath $stagedPath -DestinationPath (Join-Path $installDirectory $name)
    }

    if (Test-Path -LiteralPath $stateBackup -PathType Leaf) {
        $stagedState = Join-Path $restoreDirectory 'install-state.json'
        Copy-Item -LiteralPath $stateBackup -Destination $stagedState
        Set-FileFromStagedCopy -StagedPath $stagedState -DestinationPath $statePath
    }
    if ([bool]$journal.RegistryVersionExisted) {
        New-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion `
            -Value ([string]$journal.OldRegistryVersion) -PropertyType String -Force | Out-Null
    }
    else {
        Remove-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -ErrorAction SilentlyContinue
    }

    Assert-InstalledVersionMatchesJournal -Journal $journal -Version ([string]$journal.FromVersion) `
        -RegistryVersionExisted ([bool]$journal.RegistryVersionExisted) `
        -RegistryVersion ([string]$journal.OldRegistryVersion)
    Set-JournalPhase -Journal $journal -Phase 'RolledBack'
    Remove-UpdateRecoveryArtifacts -Paths $recoveryPaths -RemoveJournal
}

function Invoke-SecureElevatedApply {
    $updaterMutex = $null
    $applicationMutex = $null
    $transactionRoot = $null
    $backupDirectory = $null
    $restoreDirectory = $null
    $stateBackup = $null
    $stateTemporary = $null
    $backupCreated = $false
    $filesChanged = $false
    $registryVersionExisted = $false
    $oldRegistryVersion = ''
    $context = $null
    $statusDirectory = $null
    $readyPath = $null
    $resultPath = $null
    $failurePath = $null
    $journal = $null
    $committed = $false
    $rollbackComplete = $false

    try {
        if (-not (Test-Administrator)) { throw 'Administrator approval is required to apply the update.' }
        Assert-ProtectedApplicationDirectoryAcl -Path $stateDir
        if ($ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            $ExpectedVersion -notmatch '^\d+\.\d+\.\d+$' -or
            $ExpectedTag -cne ('v' + $ExpectedVersion)) {
            throw 'The elevated updater received invalid release verification data.'
        }
        $validatedId = Get-ValidatedTransactionId $TransactionId
        $statusDirectory = New-SecureStatusDirectory -Id $validatedId
        $readyPath = Join-Path $statusDirectory 'ready.txt'
        $resultPath = Join-Path $statusDirectory 'result.json'
        $failurePath = Join-Path $statusDirectory 'failure.txt'

        $updaterMutex = Enter-NamedMutex -Name $updaterMutexName
        Restore-IncompleteUpdate
        $context = Get-ValidatedInstallContext
        Assert-InstallParentIsProtected -Path (Split-Path -Parent $context.InstallDirectory)
        Assert-ProtectedApplicationDirectoryAcl -Path $context.InstallDirectory
        Assert-CurrentInstallLayout -InstallDirectory $context.InstallDirectory
        $trustedScript = Join-Path $context.InstallDirectory 'Update Switzerland VPN.ps1'
        if (-not [string]::Equals(
            (Get-ExactFullPath $PSCommandPath),
            (Get-ExactFullPath $trustedScript),
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw 'Administrator mode must run the installed update helper directly.'
        }
        if ($null -eq (Get-ExactUpdaterProcess -ProcessId $UpdaterProcessId `
            -StartTimeUtcTicks $UpdaterProcessStartTimeUtcTicks -ScriptPath $trustedScript)) {
            throw 'The elevated update was not started by the trusted installed updater.'
        }
        $targetVersion = [version]$ExpectedVersion
        if ($targetVersion -le $context.CurrentVersion) {
            throw 'The selected release is not newer than the installed version.'
        }
        if ($ParentProcessId -le 0 -or $ParentProcessStartTimeUtcTicks -le 0 -or
            $null -eq (Get-ExactAppProcess -ProcessId $ParentProcessId `
                -StartTimeUtcTicks $ParentProcessStartTimeUtcTicks -AppPath $context.AppPath)) {
            throw 'The update request did not come from the installed widget process.'
        }

        $packageFullPath = Get-ExactFullPath $PackageZip
        $packageParent = Split-Path -Parent $packageFullPath
        $cancelPath = Join-Path $packageParent 'cancel.txt'
        $requiredSuffix = '\Justichuu\Switzerland VPN\Updates\' + $validatedId
        if (-not [IO.Path]::IsPathRooted($packageFullPath) -or
            $packageFullPath.StartsWith('\\') -or
            -not $packageParent.EndsWith($requiredSuffix, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $packageFullPath -PathType Leaf)) {
            throw 'The downloaded update ZIP is not in its private transaction folder.'
        }
        $packageItem = Get-Item -LiteralPath $packageFullPath -Force
        if (($packageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The downloaded update ZIP is linked. Update stopped safely.'
        }

        $trustedHash = $ExpectedSha256.ToUpperInvariant()
        $escapedVersion = [regex]::Escape($ExpectedVersion)
        if ([IO.Path]::GetFileName($packageFullPath) -notmatch
            "^Switzerland[ .]VPN[ .]Distribution[ .]$escapedVersion\.zip$") {
            throw 'The downloaded ZIP name does not match the requested release.'
        }

        $parentDirectory = Split-Path -Parent $context.InstallDirectory
        $transactionRoot = Join-Path $parentDirectory ('.Switzerland VPN.update-' + $validatedId)
        $backupDirectory = Join-Path $parentDirectory ('.Switzerland VPN.backup-' + $validatedId)
        $restoreDirectory = Join-Path $parentDirectory ('.Switzerland VPN.restore-' + $validatedId)
        foreach ($path in @($transactionRoot, $backupDirectory, $restoreDirectory)) {
            if (Test-Path -LiteralPath $path) { throw 'A protected update path unexpectedly already exists.' }
        }
        New-Item -ItemType Directory -Path $transactionRoot | Out-Null
        Set-ProtectedApplicationDirectoryAcl -Path $transactionRoot
        $protectedZip = Join-Path $transactionRoot ([IO.Path]::GetFileName($packageFullPath))
        Copy-AndLockPackage -Source $packageFullPath -Destination $protectedZip -ExpectedHash $trustedHash

        # Administrator mode must establish release authenticity independently. The
        # unelevated process is intentionally not trusted to choose an executable hash.
        $elevatedGitHubCli = Get-ValidatedGitHubCliPath -RequestedPath $GitHubCliPath
        Invoke-GitHubCli -GitHubCli $elevatedGitHubCli -Arguments @(
            'auth', 'status', '--active', '--hostname', 'github.com'
        )
        $elevatedMetadata = Get-VerifiedReleaseMetadata -GitHubCli $elevatedGitHubCli `
            -Tag $ExpectedTag -Version $ExpectedVersion
        $elevatedAssets = $elevatedMetadata.Assets
        if (-not [string]::Equals(
            [string]$elevatedAssets.Zip.name,
            [IO.Path]::GetFileName($protectedZip),
            [StringComparison]::Ordinal
        ) -or
            -not [string]::Equals(
                [string]$elevatedAssets.Zip.digest,
                ('sha256:' + $trustedHash),
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            [long]$elevatedAssets.Zip.size -ne (Get-Item -LiteralPath $protectedZip).Length) {
            throw 'Administrator mode found release metadata that does not match the verified update ZIP.'
        }
        Invoke-GitHubCli -GitHubCli $elevatedGitHubCli -Arguments @(
            'release', 'verify', $ExpectedTag, '--repo', $repository
        )
        Invoke-GitHubCli -GitHubCli $elevatedGitHubCli -Arguments @(
            'release', 'verify-asset', $ExpectedTag, $protectedZip, '--repo', $repository
        )

        $packageRoot = Join-Path $transactionRoot 'package'
        New-Item -ItemType Directory -Path $packageRoot | Out-Null
        Expand-ValidatedPackage -ZipPath $protectedZip -Destination $packageRoot
        Assert-PackageManifest -PackageRoot $packageRoot -Version $ExpectedVersion

        $newInstall = Join-Path $transactionRoot 'new-install'
        New-Item -ItemType Directory -Path $newInstall | Out-Null
        foreach ($name in @(
            'Emergency Unlock.exe', 'Switzerland VPN.exe', 'Switzerland VPN.ico', 'Switzerland VPN.png',
            'Switzerland VPN Background.png'
        )) {
            Copy-Item -LiteralPath (Join-Path $packageRoot ('Programs\Executables\' + $name)) `
                -Destination (Join-Path $newInstall $name)
        }
        foreach ($name in @(
            'Uninstall Switzerland VPN.ps1', 'Emergency Unlock.ps1',
            'Switch Switzerland VPN Server.ps1', 'Update Switzerland VPN.ps1'
        )) {
            Copy-Item -LiteralPath (Join-Path $packageRoot ('Programs\PowerShell Backup\' + $name)) `
                -Destination (Join-Path $newInstall $name)
        }
        Copy-Item -LiteralPath (Join-Path $packageRoot 'VPN Servers.txt') `
            -Destination (Join-Path $newInstall 'VPN Servers.txt')
        Write-JsonFile -Path (Join-Path $newInstall $ownershipFileName) `
            -Value (New-UpdatedObject -Source $context.Marker -Version $ExpectedVersion)
        $updatedState = New-UpdatedObject -Source $context.State -Version $ExpectedVersion

        if (-not (Test-Path -LiteralPath $uninstallKey)) {
            throw 'The Windows uninstall registration is missing. Nothing was changed.'
        }
        $registration = Get-ItemProperty -LiteralPath $uninstallKey
        if (-not [string]::Equals([string]$registration.InstallLocation, $context.InstallDirectory, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-SupportedPublisher ([string]$registration.Publisher))) {
            throw 'The Windows uninstall registration does not match this installation.'
        }
        $registryVersionExisted = $registration.PSObject.Properties.Name -contains 'DisplayVersion'
        if ($registryVersionExisted) { $oldRegistryVersion = [string]$registration.DisplayVersion }
        $stateTemporary = Join-Path $stateDir ('install-state.update-' + $validatedId + '.json')
        $stateBackup = Join-Path $stateDir ('install-state.backup-' + $validatedId + '.json')
        Write-JsonFile -Path $stateTemporary -Value $updatedState
        $journal = [pscustomobject][ordered]@{
            TransactionId = $validatedId
            InstallId = [string]$context.State.InstallId
            InstallDirectory = $context.InstallDirectory
            FromVersion = [string]$context.State.Version
            ToVersion = $ExpectedVersion
            Phase = 'Prepared'
            RegistryVersionExisted = $registryVersionExisted
            OldRegistryVersion = $oldRegistryVersion
            UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-DurableJournal -Value $journal

        if (Test-Path -LiteralPath $cancelPath -PathType Leaf) {
            throw 'The update was canceled before any installed files changed.'
        }
        [IO.File]::WriteAllText($readyPath, 'ready', [Text.UTF8Encoding]::new($false))
        Wait-ForAppExit -ProcessId $ParentProcessId -StartTimeUtcTicks $ParentProcessStartTimeUtcTicks `
            -AppPath $context.AppPath
        $applicationMutex = Enter-NamedMutex -Name $applicationMutexName

        New-Item -ItemType Directory -Path $backupDirectory | Out-Null
        Set-ProtectedApplicationDirectoryAcl -Path $backupDirectory
        foreach ($name in @($managedInstallFiles + $preservedInstallFiles)) {
            Copy-Item -LiteralPath (Join-Path $context.InstallDirectory $name) `
                -Destination (Join-Path $backupDirectory $name)
        }
        $sourceManifest = @(Get-InstallFileManifest -Directory $context.InstallDirectory)
        $backupManifest = @(Get-InstallFileManifest -Directory $backupDirectory)
        Assert-MatchingFileManifests -Expected $sourceManifest -Actual $backupManifest
        $journal | Add-Member -NotePropertyName BackupFiles -NotePropertyValue $backupManifest
        $backupCreated = $true
        Set-JournalPhase -Journal $journal -Phase 'BackupReady'

        $replacementOrder = @(
            @($managedInstallFiles | Where-Object { $_ -ne 'Switzerland VPN.exe' }) +
            @('Switzerland VPN.exe', $ownershipFileName)
        )
        foreach ($name in $replacementOrder) {
            Set-FileFromStagedCopy -StagedPath (Join-Path $newInstall $name) `
                -DestinationPath (Join-Path $context.InstallDirectory $name)
            $filesChanged = $true
        }
        Set-JournalPhase -Journal $journal -Phase 'FilesUpdated'

        [IO.File]::Replace($stateTemporary, $statePath, $stateBackup)
        Set-JournalPhase -Journal $journal -Phase 'StateUpdated'
        New-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -Value $ExpectedVersion `
            -PropertyType String -Force | Out-Null
        Set-JournalPhase -Journal $journal -Phase 'RegistryUpdated'

        $verified = Get-ValidatedInstallContext
        $verifiedRegistration = Get-ItemProperty -LiteralPath $uninstallKey
        if ($verified.CurrentVersion -ne $targetVersion -or
            -not [string]::Equals([string]$verified.State.InstallId, [string]$context.State.InstallId, [StringComparison]::Ordinal) -or
            [string]$verifiedRegistration.DisplayVersion -ne $ExpectedVersion) {
            throw 'The updated installation failed its final ownership or version check.'
        }

        Set-JournalPhase -Journal $journal -Phase 'Committed'
        $committed = $true
        Write-JsonFile -Path $resultPath -Value ([ordered]@{
            Status = 'Success'
            Message = "Switzerland VPN was updated to $ExpectedVersion."
            Version = $ExpectedVersion
            InstallDirectory = $context.InstallDirectory
        })
        try {
            Remove-UpdateRecoveryArtifacts `
                -Paths @($restoreDirectory, $transactionRoot, $stateTemporary, $stateBackup, $backupDirectory) `
                -RemoveJournal
        }
        catch { }
        return 0
    }
    catch {
        $failure = $_.Exception.Message
        if (-not $committed) {
            try {
                if ((Test-Path -LiteralPath $journalPath -PathType Leaf) -or
                    (Test-Path -LiteralPath $journalPreviousPath -PathType Leaf)) {
                    Restore-IncompleteUpdate
                }
                elseif ($backupCreated -or $filesChanged) {
                    throw 'The verified backup exists without its recovery journal.'
                }
                $rollbackComplete = $true
            }
            catch {
                $failure += ' Automatic rollback also had a problem. Keep the backup and update journal; ask Justichuu for help.'
            }
        }
        if ($statusDirectory) {
            try {
                [IO.File]::WriteAllText($failurePath, $failure, [Text.UTF8Encoding]::new($false))
                Write-JsonFile -Path $resultPath -Value ([ordered]@{
                    Status = 'Failure'
                    Message = $failure
                    InstallDirectory = if ($context) { $context.InstallDirectory } else { '' }
                })
            }
            catch { }
        }
        return 2
    }
    finally {
        Exit-NamedMutex -Mutex $applicationMutex
        Exit-NamedMutex -Mutex $updaterMutex
        if (-not $committed -and $rollbackComplete) {
            if ($stateTemporary -and (Test-Path -LiteralPath $stateTemporary)) {
                Remove-Item -LiteralPath $stateTemporary -Force -ErrorAction SilentlyContinue
            }
            if ($stateBackup -and (Test-Path -LiteralPath $stateBackup)) {
                Remove-Item -LiteralPath $stateBackup -Force -ErrorAction SilentlyContinue
            }
            if ($transactionRoot -and (Test-Path -LiteralPath $transactionRoot)) {
                Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-RecoveryOnly {
    $updaterMutex = $null
    $applicationMutex = $null
    try {
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $journalPreviousPath -PathType Leaf)) {
            throw 'There is no interrupted Switzerland VPN update to recover.'
        }
        Assert-ProtectedApplicationDirectoryAcl -Path $stateDir
        $journal = Read-UpdateJournal
        if ($journal.PSObject.Properties.Name -notcontains 'InstallDirectory') {
            throw 'The update recovery journal has no install location.'
        }
        $installDirectory = Get-SafeInstallDirectory ([string]$journal.InstallDirectory)
        $trustedScript = Join-Path $installDirectory 'Update Switzerland VPN.ps1'
        if (-not [string]::Equals(
            (Get-ExactFullPath $PSCommandPath),
            (Get-ExactFullPath $trustedScript),
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not (Test-Path -LiteralPath $trustedScript -PathType Leaf)) {
            throw 'Update recovery must run from the installed Switzerland VPN helper.'
        }
        $scriptItem = Get-Item -LiteralPath $trustedScript -Force
        if (($scriptItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The installed update recovery helper is linked. Recovery stopped safely.'
        }

        if (-not (Test-Administrator)) {
            $arguments = @(
                '-NoProfile'
                '-ExecutionPolicy'
                'Bypass'
                '-WindowStyle'
                'Hidden'
                '-File'
                ('"' + $trustedScript + '"')
                '-RecoverOnly'
            )
            if ($ParentProcessId -gt 0) {
                if ($ParentProcessStartTimeUtcTicks -le 0) {
                    throw 'The update recovery request has invalid widget process information.'
                }
                $arguments += @(
                    '-ParentProcessId'
                    [string]$ParentProcessId
                    '-ParentProcessStartTimeUtcTicks'
                    [string]$ParentProcessStartTimeUtcTicks
                )
            }
            $argumentText = $arguments -join ' '
            try {
                $elevated = Start-Process -FilePath $powershellPath -Verb RunAs -ArgumentList $argumentText `
                    -WorkingDirectory $env:SystemRoot -WindowStyle Hidden -PassThru
            }
            catch {
                if ($_.Exception -is [ComponentModel.Win32Exception] -and $_.Exception.NativeErrorCode -eq 1223) {
                    throw 'Administrator approval was canceled. The recovery backup was kept.'
                }
                throw 'Windows could not open Administrator approval. The recovery backup was kept.'
            }
            $elevated.WaitForExit()
            return $elevated.ExitCode
        }

        $updaterMutex = Enter-NamedMutex -Name $updaterMutexName
        $appPath = Join-Path $installDirectory 'Switzerland VPN.exe'
        if ($ParentProcessId -gt 0) {
            if ($ParentProcessStartTimeUtcTicks -le 0) {
                throw 'The update recovery request has invalid widget process information.'
            }
            Wait-ForAppExit -ProcessId $ParentProcessId `
                -StartTimeUtcTicks $ParentProcessStartTimeUtcTicks -AppPath $appPath
        }
        $applicationMutex = Enter-NamedMutex -Name $applicationMutexName
        Restore-IncompleteUpdate
        if ($ParentProcessId -gt 0) {
            Exit-NamedMutex -Mutex $applicationMutex
            $applicationMutex = $null
            Start-Process -FilePath $appPath -WorkingDirectory $installDirectory | Out-Null
        }
        return 0
    }
    catch {
        Show-UpdateMessage -Message $_.Exception.Message -Title 'Switzerland VPN Update Recovery' -Icon Error
        return 2
    }
    finally {
        Exit-NamedMutex -Mutex $applicationMutex
        Exit-NamedMutex -Mutex $updaterMutex
    }
}

if ($ApplyUpdate -and $RecoverOnly) {
    throw 'The updater received conflicting operation modes.'
}
if ($RecoverOnly) {
    exit (Invoke-RecoveryOnly)
}
if ($ApplyUpdate) {
    exit (Invoke-SecureElevatedApply)
}

$workDirectory = $null
$localFailurePath = $null
$keepWorkDirectory = $false
try {
    if (Test-Administrator) {
        throw 'Run Check for Updates normally, not as Administrator. Only the file-replacement step asks for approval.'
    }
    if ($ExpectedTag -cnotmatch '^v(\d+\.\d+\.\d+)$') {
        throw 'The widget requested an invalid release tag.'
    }
    $newVersionText = $matches[1]
    $validatedId = Get-ValidatedTransactionId $TransactionId
    Assert-ProtectedApplicationDirectoryAcl -Path $stateDir
    $context = Get-ValidatedInstallContext
    Assert-InstallParentIsProtected -Path (Split-Path -Parent $context.InstallDirectory)
    Assert-ProtectedApplicationDirectoryAcl -Path $context.InstallDirectory
    Assert-CurrentInstallLayout -InstallDirectory $context.InstallDirectory
    $trustedScript = Join-Path $context.InstallDirectory 'Update Switzerland VPN.ps1'
    if (-not [string]::Equals(
        (Get-ExactFullPath $PSCommandPath),
        (Get-ExactFullPath $trustedScript),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Private updates are available only from the installed Switzerland VPN app.'
    }
    $parent = Get-ExactAppProcess -ProcessId $ParentProcessId -StartTimeUtcTicks $ParentProcessStartTimeUtcTicks -AppPath $context.AppPath
    if ($ParentProcessId -le 0 -or $ParentProcessStartTimeUtcTicks -le 0 -or $null -eq $parent) {
        throw 'The updater could not verify the widget process that opened it.'
    }
    if ([version]$newVersionText -le $context.CurrentVersion) {
        throw 'The selected release is not newer than the installed version.'
    }

    $gh = Get-ValidatedGitHubCliPath -RequestedPath $GitHubCliPath
    Invoke-GitHubCli -GitHubCli $gh -Arguments @('auth', 'status', '--active', '--hostname', 'github.com')
    $metadata = Get-VerifiedReleaseMetadata -GitHubCli $gh -Tag $ExpectedTag -Version $newVersionText
    $assets = $metadata.Assets
    Invoke-GitHubCli -GitHubCli $gh -Arguments @('release', 'verify', $ExpectedTag, '--repo', $repository)

    $workRoot = Join-Path $env:LOCALAPPDATA 'Justichuu\Switzerland VPN\Updates'
    $workDirectory = Join-Path $workRoot $validatedId
    $localFailurePath = Join-Path $workDirectory 'failure.txt'
    if (Test-Path -LiteralPath $workDirectory) {
        throw 'The private update transaction folder already exists. Try again.'
    }
    New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
    $zipPath = Join-Path $workDirectory ([string]$assets.Zip.name)
    $checksumPath = Join-Path $workDirectory ([string]$assets.Checksum.name)
    Invoke-GitHubCli -GitHubCli $gh -Arguments @(
        'release', 'download', $ExpectedTag, '--repo', $repository,
        '--pattern', [string]$assets.Zip.name, '--pattern', [string]$assets.Checksum.name,
        '--dir', $workDirectory
    ) -TimeoutSeconds 180
    Invoke-GitHubCli -GitHubCli $gh -Arguments @(
        'release', 'verify-asset', $ExpectedTag, $zipPath, '--repo', $repository
    )

    $expectedHash = Get-ExpectedChecksum -ChecksumPath $checksumPath -Version $newVersionText
    $zipDigest = ([string]$assets.Zip.digest).Substring(7).ToUpperInvariant()
    $checksumDigest = ([string]$assets.Checksum.digest).Substring(7).ToUpperInvariant()
    if ($expectedHash -ne $zipDigest -or
        (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash -ne $zipDigest -or
        (Get-FileHash -LiteralPath $checksumPath -Algorithm SHA256).Hash -ne $checksumDigest -or
        (Get-Item -LiteralPath $zipPath).Length -ne [long]$assets.Zip.size -or
        (Get-Item -LiteralPath $checksumPath).Length -ne [long]$assets.Checksum.size) {
        throw 'The downloaded update does not match the immutable release metadata.'
    }

    $rechecked = Get-VerifiedReleaseMetadata -GitHubCli $gh -Tag $ExpectedTag -Version $newVersionText
    if ([string]$rechecked.Assets.Zip.id -cne [string]$assets.Zip.id -or
        [string]$rechecked.Assets.Checksum.id -cne [string]$assets.Checksum.id -or
        [string]$rechecked.Assets.Zip.digest -cne [string]$assets.Zip.digest -or
        [string]$rechecked.Assets.Checksum.digest -cne [string]$assets.Checksum.digest -or
        [long]$rechecked.Assets.Zip.size -ne [long]$assets.Zip.size -or
        [long]$rechecked.Assets.Checksum.size -ne [long]$assets.Checksum.size) {
        throw 'The release metadata changed during download. Nothing was installed.'
    }

    if (Test-Path -LiteralPath (Join-Path $workDirectory 'cancel.txt') -PathType Leaf) {
        throw 'The update was canceled before Administrator approval.'
    }

    Set-Location -LiteralPath $env:SystemRoot
    $updaterProcess = Get-Process -Id $PID -ErrorAction Stop
    $updaterStartTicks = $updaterProcess.StartTime.ToUniversalTime().Ticks
    $argumentText = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-WindowStyle'
        'Hidden'
        '-File'
        ('"' + $trustedScript + '"')
        '-ApplyUpdate'
        '-PackageZip'
        ('"' + $zipPath + '"')
        '-ExpectedSha256'
        $expectedHash
        '-ExpectedVersion'
        $newVersionText
        '-ExpectedTag'
        $ExpectedTag
        '-TransactionId'
        $validatedId
        '-GitHubCliPath'
        ('"' + $gh + '"')
        '-ParentProcessId'
        [string]$ParentProcessId
        '-ParentProcessStartTimeUtcTicks'
        [string]$ParentProcessStartTimeUtcTicks
        '-UpdaterProcessId'
        [string]$PID
        '-UpdaterProcessStartTimeUtcTicks'
        [string]$updaterStartTicks
    ) -join ' '
    try {
        $elevated = Start-Process -FilePath $powershellPath -Verb RunAs -ArgumentList $argumentText -WorkingDirectory $env:SystemRoot -WindowStyle Hidden -PassThru
    }
    catch {
        if ($_.Exception -is [ComponentModel.Win32Exception] -and $_.Exception.NativeErrorCode -eq 1223) {
            throw 'Administrator approval was canceled. Nothing was changed.'
        }
        throw 'Windows could not open Administrator approval. Nothing was changed.'
    }

    $elevated.WaitForExit()
    $statusDirectory = Get-StatusDirectoryPath -Id $validatedId
    $resultPath = Join-Path $statusDirectory 'result.json'
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw 'The elevated updater ended without a result. Nothing was installed.'
    }
    try { $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json }
    catch { throw 'The updater returned an unreadable result.' }

    if ([string]$result.Status -ne 'Success') {
        $parentAfterFailure = Get-ExactAppProcess -ProcessId $ParentProcessId -StartTimeUtcTicks $ParentProcessStartTimeUtcTicks -AppPath $context.AppPath
        if ($null -eq $parentAfterFailure) {
            if (Test-Path -LiteralPath $context.AppPath -PathType Leaf) {
                Start-Process -FilePath $context.AppPath -WorkingDirectory $context.InstallDirectory | Out-Null
            }
            Show-UpdateMessage -Message ([string]$result.Message) -Title 'Switzerland VPN Update Stopped' -Icon Error
        }
        exit 2
    }

    $installedApp = Join-Path ([string]$result.InstallDirectory) 'Switzerland VPN.exe'
    Start-Process -FilePath $installedApp -WorkingDirectory ([string]$result.InstallDirectory) | Out-Null
}
catch {
    $message = if ([string]::IsNullOrWhiteSpace($_.Exception.Message)) {
        'The private update stopped safely. Nothing was installed.'
    }
    else {
        $_.Exception.Message
    }
    if ($localFailurePath) {
        try { [IO.File]::WriteAllText($localFailurePath, $message, [Text.UTF8Encoding]::new($false)) }
        catch { }
        $keepWorkDirectory = $true
    }
    if ($ParentProcessId -le 0) {
        Show-UpdateMessage -Message $message -Title 'Switzerland VPN Update Stopped' -Icon Error
    }
    exit 2
}
finally {
    if (-not $keepWorkDirectory -and $workDirectory -and (Test-Path -LiteralPath $workDirectory -PathType Container)) {
        $safeRoot = (Get-ExactFullPath (Join-Path $env:LOCALAPPDATA 'Justichuu\Switzerland VPN\Updates')) + '\'
        $resolvedWork = Get-ExactFullPath $workDirectory
        if ($resolvedWork.StartsWith($safeRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Start-Sleep -Milliseconds 750
            Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

exit 0
