$ErrorActionPreference = 'Stop'

$ruleGroup = 'Swiss Army VPN Kill Switch'
$scriptFolder = Split-Path -Parent $PSCommandPath
$profileFile = Join-Path $scriptFolder 'VPN Profile.txt'

function Get-ConfiguredVpnName {
    if (-not (Test-Path -LiteralPath $profileFile -PathType Leaf)) {
        throw "Missing file: $profileFile"
    }

    $name = (Get-Content -LiteralPath $profileFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 256 -or $name.Contains("`r") -or $name.Contains("`n")) {
        throw 'VPN Profile.txt must contain exactly one non-empty Windows VPN profile name.'
    }
    return $name
}

$vpnName = Get-ConfiguredVpnName

function Get-ManagedVpnConnection {
    try {
        return Get-VpnConnection -Name $vpnName -AllUserConnection -ErrorAction Stop
    }
    catch {
        return Get-VpnConnection -Name $vpnName -ErrorAction Stop
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from PowerShell as Administrator.'
}

# Restore normal networking before attempting to disconnect.
Get-NetFirewallRule -Group $ruleGroup -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule

if ((Get-ManagedVpnConnection).ConnectionStatus -eq 'Connected') {
    & rasdial.exe $vpnName /disconnect
}

Write-Host 'Swiss Army VPN is disconnected. Kill switch is OFF and normal internet is restored.' -ForegroundColor Green
