$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

$productName = 'Swiss Army VPN'
$vpnName = 'Swiss Army VPN'
$ruleGroup = 'Swiss Army VPN Kill Switch'
$certificateThumbprint = 'B0A21991007734F5E80C977DD295FFEFB5AD6229'
$statePath = Join-Path (Join-Path $env:ProgramData 'Swiss Army VPN') 'install-state.json'
$ownershipFileName = 'install-ownership.json'
$powershellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
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

function Get-SafeInstallDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [IO.Path]::IsPathRooted($Path) -or
        $Path.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw 'Unsafe install path.'
    }

    $fullPath = Get-ExactFullPath $Path
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($root -notmatch '^[A-Za-z]:\\$' -or
        -not [string]::Equals([IO.Path]::GetFileName($fullPath), $productName, [StringComparison]::Ordinal)) {
        throw 'Unsafe install path.'
    }

    $drive = [IO.DriveInfo]::new($root)
    if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) {
        throw 'Unsafe install drive.'
    }

    $stateDirectory = Get-ExactFullPath (Split-Path -Parent $statePath)
    if ([string]::Equals($fullPath, $stateDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unsafe install path.'
    }

    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        $directory = Get-Item -LiteralPath $fullPath -Force
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Unsafe linked install path.'
        }
    }

    return $fullPath
}

function Test-OwnershipMarker {
    param(
        [Parameter(Mandatory)]
        [string]$InstallDirectory,

        [AllowNull()]
        [object]$State
    )

    $markerPath = Join-Path $InstallDirectory $ownershipFileName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }

    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        foreach ($propertyName in @('ProductName', 'InstallId', 'InstallDirectory', 'Version')) {
            if ($marker.PSObject.Properties.Name -notcontains $propertyName -or
                [string]::IsNullOrWhiteSpace([string]$marker.$propertyName)) {
                return $false
            }
        }

        $markerDirectory = Get-SafeInstallDirectory ([string]$marker.InstallDirectory)
        if (-not [string]::Equals([string]$marker.ProductName, $productName, [StringComparison]::Ordinal) -or
            -not [string]::Equals($markerDirectory, $InstallDirectory, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$marker.Version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
            return $false
        }

        if ($null -ne $State -and (
            -not [string]::Equals([string]$marker.InstallId, [string]$State.InstallId, [StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$marker.Version, [string]$State.Version, [StringComparison]::Ordinal)
        )) {
            return $false
        }

        return $true
    }
    catch {
        return $false
    }
}

function Get-SafeHelperPath {
    $legacyInstallDir = Get-ExactFullPath (Join-Path $env:ProgramFiles $productName)

    # An installed recovery script can find its sibling helper without relying
    # on ProgramData, but only when the folder has valid ownership evidence.
    try {
        $scriptDirectory = Get-SafeInstallDirectory $PSScriptRoot
        if (Test-OwnershipMarker -InstallDirectory $scriptDirectory -State $null) {
            $siblingHelper = Join-Path $scriptDirectory 'Swiss Army VPN.exe'
            if (Test-Path -LiteralPath $siblingHelper -PathType Leaf) { return $siblingHelper }
        }
    }
    catch { }

    # A packaged recovery script can instead locate the installed helper from a
    # validated state record. Invalid state never prevents the native fallback.
    try {
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        foreach ($propertyName in @(
            'Version'
            'InstallDirectory'
            'ProfileName'
            'ServerAddress'
            'FirewallRuleGroup'
            'CertificateThumbprint'
        )) {
            if ($state.PSObject.Properties.Name -notcontains $propertyName -or
                [string]::IsNullOrWhiteSpace([string]$state.$propertyName)) {
                return $null
            }
        }

        if (-not [string]::Equals([string]$state.ProfileName, $vpnName, [StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$state.FirewallRuleGroup, $ruleGroup, [StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$state.CertificateThumbprint, $certificateThumbprint, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$state.ServerAddress -notmatch '(?i)^ch[0-9]+\.nordvpn\.com$') {
            return $null
        }

        $installDirectory = Get-SafeInstallDirectory ([string]$state.InstallDirectory)
        $hasInstallId = (
            $state.PSObject.Properties.Name -contains 'InstallId' -and
            -not [string]::IsNullOrWhiteSpace([string]$state.InstallId)
        )
        if ($hasInstallId) {
            if ($state.PSObject.Properties.Name -notcontains 'ProductName' -or
                -not [string]::Equals([string]$state.ProductName, $productName, [StringComparison]::Ordinal)) {
                return $null
            }
            if (-not (Test-OwnershipMarker -InstallDirectory $installDirectory -State $state)) { return $null }
        }
        elseif (@('1.0.6', '1.0.7') -cnotcontains [string]$state.Version -or
            -not [string]::Equals($installDirectory, $legacyInstallDir, [StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }

        $stateHelper = Join-Path $installDirectory 'Swiss Army VPN.exe'
        if (Test-Path -LiteralPath $stateHelper -PathType Leaf) { return $stateHelper }
    }
    catch { }

    return $null
}

function Show-RecoveryMessage {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [Windows.Forms.MessageBoxIcon]$Icon
    )
    [Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [Windows.Forms.MessageBoxButtons]::OK,
        $Icon
    ) | Out-Null
}

function Get-ManagedFirewallRules {
    return @(
        Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop |
            Where-Object { $ruleNames -ccontains [string]$_.Name }
    )
}

function Remove-AndVerifyKillSwitchRules {
    $appPath = Get-SafeHelperPath
    if (-not [string]::IsNullOrWhiteSpace($appPath)) {
        try {
            $helper = Start-Process -FilePath $appPath -ArgumentList '--firewall-remove' -Wait -PassThru
            if ($helper.ExitCode -ne 0) { throw 'The app helper reported that rule removal was incomplete.' }
        }
        catch {
            # Continue into the native exact-name recovery path below.
        }
    }

    foreach ($rule in @(Get-ManagedFirewallRules)) {
        $rule | Remove-NetFirewallRule -ErrorAction Stop
    }
    if (@(Get-ManagedFirewallRules).Count -ne 0) {
        throw 'Windows did not remove every Swiss Army VPN kill-switch rule. Internet may still be blocked.'
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
            Show-RecoveryMessage -Message 'Emergency Unlock was canceled. No changes were made.' `
                -Title 'Emergency Unlock Canceled' -Icon Information
            exit 0
        }
        Show-RecoveryMessage -Message "Windows could not open the Administrator approval prompt.`r`n`r`n$($_.Exception.Message)" `
            -Title 'Emergency Unlock Stopped' -Icon Error
        exit 2
    }
}

try {
    Remove-AndVerifyKillSwitchRules
}
catch {
    Show-RecoveryMessage -Message $_.Exception.Message -Title 'Emergency Unlock Failed' -Icon Error
    exit 2
}

$disconnectWarning = $null
try {
    & "$env:SystemRoot\System32\rasdial.exe" $vpnName /disconnect 2>&1 | Out-Null
    $profile = Get-VpnConnection -Name $vpnName -AllUserConnection -ErrorAction SilentlyContinue
    if ($profile -and $profile.ConnectionStatus -eq 'Connected') {
        $disconnectWarning = 'The kill switch is off, but Windows still reports the VPN as connected. Disconnect it from Windows Settings if needed.'
    }
}
catch {
    $disconnectWarning = 'The kill switch is off, but Windows could not confirm that the VPN disconnected. Disconnect it from Windows Settings if needed.'
}

if ($disconnectWarning) {
    Show-RecoveryMessage -Message $disconnectWarning -Title 'Emergency Unlock Completed With Warning' -Icon Warning
}
else {
    Show-RecoveryMessage -Message 'The Swiss Army VPN kill switch is off. Normal internet access is restored.' `
        -Title 'Emergency Unlock Complete' -Icon Information
}

exit 0
