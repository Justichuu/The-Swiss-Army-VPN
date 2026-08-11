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

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from PowerShell as Administrator.'
    }
}

function Get-ManagedVpnConnection {
    try {
        return Get-VpnConnection -Name $vpnName -AllUserConnection -ErrorAction Stop
    }
    catch {
        return Get-VpnConnection -Name $vpnName -ErrorAction Stop
    }
}

function ConvertTo-UInt32Ip([System.Net.IPAddress]$Address) {
    $bytes = $Address.GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function ConvertFrom-UInt32Ip([uint64]$Value) {
    $bytes = [BitConverter]::GetBytes([uint32]$Value)
    [Array]::Reverse($bytes)
    return [System.Net.IPAddress]::new($bytes).ToString()
}

function Get-IPv4Complement([System.Net.IPAddress[]]$AllowedAddresses) {
    $allowed = @($AllowedAddresses | ForEach-Object { [uint64](ConvertTo-UInt32Ip $_) } | Sort-Object -Unique)
    $ranges = [System.Collections.Generic.List[string]]::new()
    [uint64]$start = 0

    foreach ($address in $allowed) {
        if ($start -lt $address) {
            $ranges.Add("$(ConvertFrom-UInt32Ip $start)-$(ConvertFrom-UInt32Ip ($address - 1))")
        }
        $start = $address + 1
    }

    if ($start -le [uint64][uint32]::MaxValue) {
        $ranges.Add("$(ConvertFrom-UInt32Ip $start)-255.255.255.255")
    }

    return $ranges.ToArray()
}

Assert-Administrator

$vpn = Get-ManagedVpnConnection
$serverAddresses = @(
    Resolve-DnsName -Name $vpn.ServerAddress -Type A |
        Where-Object IPAddress |
        ForEach-Object { [System.Net.IPAddress]::Parse($_.IPAddress) }
)

if (-not $serverAddresses) {
    throw "Could not resolve $($vpn.ServerAddress). The kill switch was not enabled."
}

# Clear only rules created by these scripts, then connect before closing other paths.
Get-NetFirewallRule -Group $ruleGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule

if ((Get-ManagedVpnConnection).ConnectionStatus -ne 'Connected') {
    & rasdial.exe $vpnName
    if ($LASTEXITCODE -ne 0) {
        throw 'Swiss Army VPN failed to connect. The kill switch was not enabled.'
    }
}

$blockedIPv4 = Get-IPv4Complement -AllowedAddresses $serverAddresses

try {
    foreach ($interfaceType in 'Wired', 'Wireless') {
        New-NetFirewallRule `
            -DisplayName "Swiss Army VPN kill switch - block $interfaceType IPv4" `
            -Group $ruleGroup `
            -Direction Outbound `
            -Action Block `
            -Enabled True `
            -Profile Any `
            -InterfaceType $interfaceType `
            -RemoteAddress $blockedIPv4 | Out-Null

        # Windows Firewall rejects an IPv6 /0 here. Two /1 prefixes cover the
        # complete IPv6 address space and are accepted by the NetSecurity API.
        New-NetFirewallRule `
            -DisplayName "Swiss Army VPN kill switch - block $interfaceType IPv6" `
            -Group $ruleGroup `
            -Direction Outbound `
            -Action Block `
            -Enabled True `
            -Profile Any `
            -InterfaceType $interfaceType `
            -RemoteAddress '::/1', '8000::/1' | Out-Null
    }
}
catch {
    # Never leave a partially configured rule set behind.
    Get-NetFirewallRule -Group $ruleGroup -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    throw
}

$status = Get-ManagedVpnConnection
if ($status.ConnectionStatus -ne 'Connected') {
    throw 'The VPN dropped while the kill switch was being enabled. Physical internet remains blocked; run Swiss Army VPN OFF.ps1 to recover.'
}

Write-Host 'Swiss Army VPN is connected. Whole-computer kill switch is ACTIVE.' -ForegroundColor Green
Write-Host 'If the tunnel drops, run Swiss Army VPN OFF.ps1 to restore normal internet.'
