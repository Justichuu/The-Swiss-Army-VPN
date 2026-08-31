$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

$productName = 'Swiss Army VPN'
$vpnName = 'Swiss Army VPN'
$ruleGroup = 'Swiss Army VPN Kill Switch'
$certificateThumbprint = 'B0A21991007734F5E80C977DD295FFEFB5AD6229'
$stateDir = Join-Path $env:ProgramData 'Swiss Army VPN'
$statePath = Join-Path $stateDir 'install-state.json'
$ownershipFileName = 'install-ownership.json'
$powershellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Swiss Army VPN Widget'
$ruleNames = @(
    'Swiss Army VPN Kill Switch - Wired IPv4'
    'Swiss Army VPN Kill Switch - Wired IPv6'
    'Swiss Army VPN Kill Switch - Wireless IPv4'
    'Swiss Army VPN Kill Switch - Wireless IPv6'
)

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ExactFullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

# --- managed-server-address-begin ---
function Test-ManagedServerAddress {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $normalized = $Value.Trim().ToLowerInvariant()
    if ($normalized.Length -gt 253) { return $false }

    $parsed = [Net.IPAddress]::None
    if ($normalized -match '^\d{1,3}(?:\.\d{1,3}){3}$' -and
        [Net.IPAddress]::TryParse($normalized, [ref]$parsed)) {
        if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
        $bytes = $parsed.GetAddressBytes()
        if ($bytes[0] -eq 0 -or $bytes[0] -eq 127) { return $false }
        if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $false }
        if ($bytes[0] -ge 224) { return $false }
        return $true
    }

    if ($normalized -match '[:/\\ @\$;`|&<>''"()\[\]{}#?%!,~]') { return $false }
    if ($normalized.StartsWith('.') -or $normalized.EndsWith('.') -or $normalized.Contains('..')) { return $false }
    if ($normalized -notmatch '^[a-z0-9._-]+$') { return $false }
    $labels = $normalized.Split('.')
    if ($labels.Count -lt 2) { return $false }
    foreach ($label in $labels) {
        if ($label -notmatch '^(?:[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?|xn--[a-z0-9-]{1,59})$') {
            return $false
        }
    }
    return $true
}
# --- managed-server-address-end ---

function Get-SafeInstallDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [IO.Path]::IsPathRooted($Path) -or
        $Path.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw 'The saved install location is not a safe local folder. Nothing was removed.'
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

        if ([string]::Equals(
            $fullPath,
            (Get-ExactFullPath $stateDir),
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw 'invalid state collision'
        }

        if (Test-Path -LiteralPath $fullPath -PathType Container) {
            $directory = Get-Item -LiteralPath $fullPath -Force
            if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'invalid linked folder'
            }
        }
    }
    catch {
        throw 'The saved install location is not a Swiss Army VPN folder on a local fixed drive. Nothing was removed.'
    }

    return $fullPath
}

function Show-UninstallMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [Windows.Forms.MessageBoxIcon]$Icon
    )

    [Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [Windows.Forms.MessageBoxButtons]::OK,
        $Icon
    ) | Out-Null
}

function Get-ValidatedOwnershipMarker {
    param(
        [Parameter(Mandatory)]
        [string]$MarkerPath,

        [Parameter(Mandatory)]
        [object]$State,

        [Parameter(Mandatory)]
        [string]$InstallDirectory
    )

    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
        throw 'The installation ownership marker is missing. Nothing was removed.'
    }

    try {
        $marker = Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json
    }
    catch {
        throw 'The installation ownership marker is damaged. Nothing was removed.'
    }

    foreach ($propertyName in @('ProductName', 'InstallId', 'InstallDirectory', 'Version')) {
        if ($marker.PSObject.Properties.Name -notcontains $propertyName -or
            [string]::IsNullOrWhiteSpace([string]$marker.$propertyName)) {
            throw "The installation ownership marker is incomplete ($propertyName). Nothing was removed."
        }
    }

    $markerDirectory = Get-SafeInstallDirectory ([string]$marker.InstallDirectory)
    if (-not [string]::Equals([string]$marker.ProductName, $productName, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$marker.InstallId, [string]$State.InstallId, [StringComparison]::Ordinal) -or
        -not [string]::Equals($markerDirectory, $InstallDirectory, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$marker.Version, [string]$State.Version, [StringComparison]::Ordinal)) {
        throw 'The installation ownership marker does not match the saved installation. Nothing was removed.'
    }

    return $marker
}

function Get-ValidatedInstallState {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'The installation ownership record is missing. Nothing was removed. Use Emergency Unlock if internet is blocked, then ask Justichuu for help repairing or removing the app.'
    }

    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    }
    catch {
        throw 'The installation ownership record is damaged. Nothing was removed. Use Emergency Unlock if internet is blocked, then ask Justichuu for help.'
    }

    $requiredProperties = @(
        'Version'
        'InstallDirectory'
        'ProfileName'
        'ServerAddress'
        'FirewallRuleGroup'
        'CertificateThumbprint'
    )
    foreach ($propertyName in $requiredProperties) {
        if ($state.PSObject.Properties.Name -notcontains $propertyName -or
            [string]::IsNullOrWhiteSpace([string]$state.$propertyName)) {
            throw "The installation ownership record is incomplete ($propertyName). Nothing was removed."
        }
    }

    $validatedInstallDir = Get-SafeInstallDirectory ([string]$state.InstallDirectory)
    if (-not [string]::Equals([string]$state.ProfileName, $vpnName, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$state.FirewallRuleGroup, $ruleGroup, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$state.CertificateThumbprint, $certificateThumbprint, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-ManagedServerAddress -Value ([string]$state.ServerAddress))) {
        throw 'The installation ownership record does not match this Swiss Army VPN package. Nothing was removed.'
    }

    $hasInstallId = (
        $state.PSObject.Properties.Name -contains 'InstallId' -and
        -not [string]::IsNullOrWhiteSpace([string]$state.InstallId)
    )
    if ($hasInstallId) {
        if ($state.PSObject.Properties.Name -notcontains 'ProductName' -or
            -not [string]::Equals([string]$state.ProductName, $productName, [StringComparison]::Ordinal)) {
            throw 'The installation ownership record has the wrong product name. Nothing was removed.'
        }

        $markerPath = Join-Path $validatedInstallDir $ownershipFileName
        if (Test-Path -LiteralPath $validatedInstallDir) {
            if (-not (Test-Path -LiteralPath $validatedInstallDir -PathType Container)) {
                throw 'The saved install location is no longer a folder. Nothing was removed.'
            }
        }
        else {
            $markerPath = Join-Path (Join-Path $stateDir 'uninstall-recovery') $ownershipFileName
        }
        Get-ValidatedOwnershipMarker -MarkerPath $markerPath -State $state `
            -InstallDirectory $validatedInstallDir | Out-Null
    }
    else {
        $legacyInstallDir = Get-ExactFullPath (Join-Path $env:ProgramFiles $productName)
        if (@('1.0.6', '1.0.7') -cnotcontains [string]$state.Version -or
            -not [string]::Equals($validatedInstallDir, $legacyInstallDir, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'This installation has no valid ownership ID. Nothing was removed.'
        }
    }

    return [pscustomobject]@{
        State = $state
        InstallDirectory = $validatedInstallDir
        AppPath = Join-Path $validatedInstallDir 'Swiss Army VPN.exe'
        IsLegacy = -not $hasInstallId
    }
}

function Get-ManagedFirewallRules {
    return @(
        Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop |
            Where-Object { $ruleNames -ccontains [string]$_.Name }
    )
}

function Remove-AndVerifyKillSwitchRules {
    $helperFailure = $null
    if (Test-Path -LiteralPath $appPath -PathType Leaf) {
        try {
            $helper = Start-Process -FilePath $appPath -ArgumentList '--firewall-remove' -Wait -PassThru
            if ($helper.ExitCode -ne 0) {
                $helperFailure = 'The installed app helper could not remove every rule.'
            }
        }
        catch {
            $helperFailure = $_.Exception.Message
        }
    }

    # The native exact-name path is both a fallback for a missing/damaged EXE and
    # a second verification pass after the helper reports success.
    foreach ($rule in @(Get-ManagedFirewallRules)) {
        $rule | Remove-NetFirewallRule -ErrorAction Stop
    }

    $remaining = @(Get-ManagedFirewallRules)
    if ($remaining.Count -gt 0) {
        $detail = if ([string]::IsNullOrWhiteSpace($helperFailure)) { '' } else { "`r`n`r`nHelper detail: $helperFailure" }
        throw "Uninstall stopped because Windows did not remove every Swiss Army VPN kill-switch rule. Emergency recovery and uninstall registration were kept.$detail"
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

function Remove-VerifiedShortcutSet {
    param(
        [Parameter(Mandatory)]
        [string]$DesktopDirectory,

        [Parameter(Mandatory)]
        [string]$ProgramsDirectory
    )

    $startFolder = Join-Path $ProgramsDirectory 'Swiss Army VPN'
    $definitions = @(
        [pscustomobject]@{ Path = (Join-Path $DesktopDirectory 'Swiss Army VPN.lnk'); Target = $appPath; Arguments = '' }
        [pscustomobject]@{ Path = (Join-Path $startFolder 'Swiss Army VPN.lnk'); Target = $appPath; Arguments = '' }
        [pscustomobject]@{
            Path = Join-Path $startFolder 'Emergency Unlock.lnk'
            Target = Join-Path $installDir 'Emergency Unlock.exe'
            Arguments = ''
        }
        [pscustomobject]@{
            Path = Join-Path $startFolder 'Choose Swiss VPN Server.lnk'
            Target = $powershellPath
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $installDir 'Switch Swiss Army VPN Server.ps1')`""
        }
        [pscustomobject]@{
            Path = Join-Path $startFolder 'Uninstall Swiss Army VPN.lnk'
            Target = $powershellPath
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $installDir 'Uninstall Swiss Army VPN.ps1')`""
        }
    )

    foreach ($definition in $definitions) {
        if (Test-PackageShortcut -Path $definition.Path -ExpectedTarget $definition.Target -ExpectedArguments $definition.Arguments) {
            Remove-Item -LiteralPath $definition.Path -Force
        }
    }

    if ((Test-Path -LiteralPath $startFolder -PathType Container) -and
        @(Get-ChildItem -LiteralPath $startFolder -Force).Count -eq 0) {
        Remove-Item -LiteralPath $startFolder -Force
    }
}

function Stop-InstalledApp {
    $running = @(
        Get-Process -Name 'Swiss Army VPN' -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    $_.Path -and
                    (Get-ExactFullPath $_.Path) -eq (Get-ExactFullPath $appPath)
                }
                catch {
                    $false
                }
            }
    )

    foreach ($process in $running) {
        if ($process.CloseMainWindow()) {
            $process.WaitForExit(3000) | Out-Null
        }
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force
            $process.WaitForExit(3000) | Out-Null
        }
    }
}

function Remove-OwnedVpnProfile {
    param(
        [Parameter(Mandatory)]
        [object]$State
    )

    $profile = Get-VpnConnection -Name $vpnName -AllUserConnection -ErrorAction SilentlyContinue
    if (-not $profile) { return }

    if (-not [string]::Equals(
        [string]$profile.ServerAddress,
        [string]$State.ServerAddress,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The Swiss Army VPN profile was changed after installation. Uninstall stopped before deleting that profile or the recovery files.'
    }

    & "$env:SystemRoot\System32\rasdial.exe" $vpnName /disconnect 2>&1 | Out-Null
    Remove-VpnConnection -Name $vpnName -AllUserConnection -Force
    if (Get-VpnConnection -Name $vpnName -AllUserConnection -ErrorAction SilentlyContinue) {
        throw 'Windows did not remove the package-owned Swiss Army VPN profile. Recovery files were kept.'
    }
}

function Remove-InstallDirectorySafely {
    param(
        [Parameter(Mandatory)]
        [object]$State,

        [Parameter(Mandatory)]
        [bool]$IsLegacy
    )

    $backupDir = Join-Path $stateDir 'uninstall-recovery'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $recoveryFiles = @('Emergency Unlock.ps1', 'Uninstall Swiss Army VPN.ps1', $ownershipFileName)
    foreach ($name in $recoveryFiles) {
        $source = Join-Path $installDir $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $backupDir $name) -Force
        }
    }

    if (-not $IsLegacy) {
        Get-ValidatedOwnershipMarker `
            -MarkerPath (Join-Path $backupDir $ownershipFileName) `
            -State $State `
            -InstallDirectory $installDir | Out-Null
    }

    Set-Location -LiteralPath $env:SystemRoot
    try {
        if (Test-Path -LiteralPath $installDir) {
            Remove-Item -LiteralPath $installDir -Recurse -Force
        }
        if (Test-Path -LiteralPath $installDir) {
            throw 'Windows left part of the application folder behind.'
        }
    }
    catch {
        $deleteFailure = $_.Exception.Message
        try {
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
            foreach ($name in $recoveryFiles) {
                $backup = Join-Path $backupDir $name
                if (Test-Path -LiteralPath $backup -PathType Leaf) {
                    Copy-Item -LiteralPath $backup -Destination (Join-Path $installDir $name) -Force
                }
            }
        }
        catch { }
        throw "The application folder could not be completely removed. Normal internet access was restored, and recovery data plus uninstall registration were kept.`r`n`r`n$deleteFailure"
    }
}

if (-not (Test-Administrator)) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    try {
        $process = Start-Process -FilePath $powershellPath -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        exit $process.ExitCode
    }
    catch {
        if ($_.Exception -is [ComponentModel.Win32Exception] -and $_.Exception.NativeErrorCode -eq 1223) {
            Show-UninstallMessage -Message 'Uninstall was canceled. Nothing was removed.' `
                -Title 'Swiss Army VPN Uninstall Canceled' -Icon Information
            exit 0
        }

        Show-UninstallMessage -Message "Windows could not open the Administrator approval prompt.`r`n`r`n$($_.Exception.Message)" `
            -Title 'Swiss Army VPN Uninstall Stopped' -Icon Error
        exit 2
    }
}

try {
    $installContext = Get-ValidatedInstallState
    $installState = $installContext.State
    $installDir = $installContext.InstallDirectory
    $appPath = $installContext.AppPath
    Set-Location -LiteralPath $env:SystemRoot
}
catch {
    Show-UninstallMessage -Message $_.Exception.Message -Title 'Swiss Army VPN Uninstall Stopped' -Icon Error
    exit 2
}

$answer = [Windows.Forms.MessageBox]::Show(
    "Remove Swiss Army VPN, its profile, four firewall rules, and shortcuts?`r`n`r`nThe shared NordVPN Root CA will remain installed.",
    'Uninstall Swiss Army VPN',
    [Windows.Forms.MessageBoxButtons]::YesNo,
    [Windows.Forms.MessageBoxIcon]::Warning,
    [Windows.Forms.MessageBoxDefaultButton]::Button2
)
if ($answer -ne [Windows.Forms.DialogResult]::Yes) { exit 0 }

try {
    Remove-AndVerifyKillSwitchRules
    Stop-InstalledApp
    Remove-OwnedVpnProfile -State $installState

    # Recovery scripts, state, shortcuts, and uninstall registration remain in
    # place until the application directory has been removed successfully.
    Remove-InstallDirectorySafely -State $installState -IsLegacy $installContext.IsLegacy

    Remove-VerifiedShortcutSet `
        -DesktopDirectory ([Environment]::GetFolderPath('CommonDesktopDirectory')) `
        -ProgramsDirectory ([Environment]::GetFolderPath('CommonPrograms'))
    Remove-VerifiedShortcutSet `
        -DesktopDirectory ([Environment]::GetFolderPath('Desktop')) `
        -ProgramsDirectory ([Environment]::GetFolderPath('Programs'))

    if (Test-Path -LiteralPath $uninstallKey) {
        Remove-Item -LiteralPath $uninstallKey -Recurse -Force
    }
    if (Test-Path -LiteralPath $stateDir) {
        Remove-Item -LiteralPath $stateDir -Recurse -Force
    }

    Show-UninstallMessage `
        -Message 'Swiss Army VPN was removed. Its kill switch is off, and the shared NordVPN Root CA was left installed.' `
        -Title 'Uninstall Complete' `
        -Icon Information
}
catch {
    Show-UninstallMessage -Message $_.Exception.Message -Title 'Uninstall Stopped Safely' -Icon Error
    exit 2
}

exit 0
