# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding(DefaultParameterSetName = 'Best')]
param(
    [Parameter(ParameterSetName = 'Server', Mandatory)]
    [string]$Server,

    [Parameter(ParameterSetName = 'Server')]
    [switch]$AllowAnyNordVpn,

    [Parameter(ParameterSetName = 'Server')]
    [switch]$BringYourOwn,

    [Parameter(ParameterSetName = 'List', Mandatory)]
    [switch]$List,

    [Parameter(ParameterSetName = 'Best')]
    [switch]$Best
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$vpnName = 'Swiss Army VPN'
$ruleGroup = 'Swiss Army VPN Kill Switch'
$installDirectory = Split-Path -Parent $PSCommandPath
$serverFile = Join-Path $installDirectory 'VPN Server.txt'
$installedPoolFile = Join-Path $installDirectory 'VPN Servers.txt'
$packagePoolFile = Join-Path (Split-Path -Parent (Split-Path -Parent $installDirectory)) 'VPN Servers.txt'
$stateFile = Join-Path $env:ProgramData 'Swiss Army VPN\install-state.json'
$apiUri = 'https://api.nordvpn.com/v1/servers?limit=1000&filters%5Bcountry_id%5D=209'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-AdministratorRelaunch {
    $arguments = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', ('"{0}"' -f $PSCommandPath)
    )
    if ($PSCmdlet.ParameterSetName -eq 'Server') {
        $arguments += '-Server', ('"{0}"' -f $Server)
        if ($BringYourOwn) { $arguments += '-BringYourOwn' }
        elseif ($AllowAnyNordVpn) { $arguments += '-AllowAnyNordVpn' }
    }
    else {
        $arguments += '-Best'
    }

    try {
        $process = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList $arguments `
            -Verb RunAs `
            -WorkingDirectory $installDirectory `
            -Wait `
            -PassThru
    }
    catch {
        throw 'Administrator approval was canceled or Windows could not open it. The VPN server was not changed.'
    }
    if ($process.ExitCode -ne 0) {
        throw 'The administrator server switch did not complete. The VPN server may be unchanged; review the elevated window for details.'
    }
}

function Get-SeedServers {
    $poolFile = @($installedPoolFile, $packagePoolFile) |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if ($null -eq $poolFile) { return @() }
    return @(
        Get-Content -LiteralPath $poolFile |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '(?i)^ch[0-9]+\.nordvpn\.com$' } |
            Sort-Object -Unique
    )
}

function Get-LiveServers {
    try {
        $response = Invoke-RestMethod -Uri $apiUri -TimeoutSec 15
        return @(
            $response |
                Where-Object {
                    $_.status -eq 'online' -and
                    $_.hostname -match '(?i)^ch[0-9]+\.nordvpn\.com$' -and
                    $_.technologies.name -contains 'IKEv2/IPSec'
                } |
                Sort-Object @{ Expression = { [int]$_.load } }, hostname |
                ForEach-Object {
                    [pscustomobject]@{ Hostname = [string]$_.hostname; Load = [int]$_.load; Source = 'Live' }
                }
        )
    }
    catch {
        Write-Warning "NordVPN's live server list was unavailable: $($_.Exception.Message)"
        return @()
    }
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

function Test-AllowedVpnIPv4 {
    param([Parameter(Mandatory)][Net.IPAddress]$Address)

    if ($Address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $bytes = $Address.GetAddressBytes()
    if ($bytes[0] -eq 0 -or $bytes[0] -eq 127) { return $false }
    if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $false }
    if ($bytes[0] -ge 224) { return $false }
    return $true
}

function Resolve-PublicIPv4 {
    param([Parameter(Mandatory)][string]$Hostname)

    $parsed = [Net.IPAddress]::None
    if ($Hostname -match '^\d{1,3}(?:\.\d{1,3}){3}$' -and
        [Net.IPAddress]::TryParse($Hostname, [ref]$parsed)) {
        if (-not (Test-AllowedVpnIPv4 -Address $parsed)) {
            throw "$Hostname is not an allowed VPN IPv4 address."
        }
        return
    }

    $addresses = @(
        Resolve-DnsName -Name $Hostname -Type A -ErrorAction Stop |
            Where-Object IPAddress |
            ForEach-Object { [Net.IPAddress]::Parse($_.IPAddress) } |
            Where-Object { Test-AllowedVpnIPv4 -Address $_ }
    )
    if ($addresses.Count -eq 0) { throw "$Hostname did not resolve to an allowed IPv4 address." }
}

function Get-CandidateServers {
    $live = @(Get-LiveServers)
    if ($live.Count -gt 0) { return $live }
    return @(
        Get-SeedServers | ForEach-Object {
            [pscustomobject]@{ Hostname = $_; Load = $null; Source = 'Seed fallback' }
        }
    )
}

function Assert-SafeToSwitch {
    $vpn = Get-VpnConnection -Name $vpnName -AllUserConnection -ErrorAction Stop
    if ($vpn.ConnectionStatus -eq 'Connected') {
        throw 'Disconnect Swiss Army VPN before changing its server.'
    }
    $rules = @(Get-NetFirewallRule -Group $ruleGroup -ErrorAction SilentlyContinue)
    if ($rules.Count -gt 0) {
        throw 'The kill switch is armed. Use DISCONNECT + UNLOCK before changing the server.'
    }
}

function Set-ManagedServer {
    param([Parameter(Mandatory)][string]$Hostname)

    if (-not (Test-Administrator)) {
        throw 'Run this script from PowerShell as Administrator to change the VPN server.'
    }
    $Hostname = $Hostname.Trim().ToLowerInvariant()
    if ($BringYourOwn) {
        if (-not (Test-ManagedServerAddress -Value $Hostname)) {
            throw 'Enter a VPN hostname or IPv4 address such as ikev2.example.com, vpn.company.local, or 203.0.113.10. URLs, ports, and IPv6 literals are not accepted.'
        }
    }
    else {
        if ($Hostname -notmatch '(?i)^[a-z]{2}[0-9]+\.nordvpn\.com$') {
            throw 'Enter an official NordVPN hostname such as ch221.nordvpn.com or us1234.nordvpn.com.'
        }
        if (-not $AllowAnyNordVpn -and $Hostname -notmatch '(?i)^ch[0-9]+\.nordvpn\.com$') {
            throw 'Swiss-only mode accepts ch<number>.nordvpn.com servers. Enable Any NordVPN or Bring your own.'
        }
    }
    Assert-SafeToSwitch
    Resolve-PublicIPv4 -Hostname $Hostname

    $current = Get-VpnConnection -Name $vpnName -AllUserConnection -ErrorAction Stop
    $previousHostname = [string]$current.ServerAddress
    $previousServerFile = Get-Content -LiteralPath $serverFile -Raw
    $previousStateFile = if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        Get-Content -LiteralPath $stateFile -Raw
    }
    else { $null }

    try {
        Set-VpnConnection -Name $vpnName -ServerAddress $Hostname -AllUserConnection -Force -PassThru | Out-Null
        $verified = Get-VpnConnection -Name $vpnName -AllUserConnection -ErrorAction Stop
        if (-not [string]::Equals([string]$verified.ServerAddress, $Hostname, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Windows did not retain the selected VPN server.'
        }

        [IO.File]::WriteAllText($serverFile, $Hostname + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        if ($null -ne $previousStateFile) {
            $state = $previousStateFile | ConvertFrom-Json
            $state.ServerAddress = $Hostname
            [IO.File]::WriteAllText(
                $stateFile,
                (($state | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
                [Text.UTF8Encoding]::new($false))
        }
    }
    catch {
        $failure = $_
        try {
            Set-VpnConnection -Name $vpnName -ServerAddress $previousHostname -AllUserConnection -Force | Out-Null
            [IO.File]::WriteAllText($serverFile, $previousServerFile, [Text.UTF8Encoding]::new($false))
            if ($null -ne $previousStateFile) {
                [IO.File]::WriteAllText($stateFile, $previousStateFile, [Text.UTF8Encoding]::new($false))
            }
        }
        catch {
            throw "The server change failed and rollback was incomplete. Reinstall Swiss Army VPN before connecting. Original error: $($failure.Exception.Message)"
        }
        throw $failure
    }
    Write-Host "Swiss Army VPN now uses $Hostname." -ForegroundColor Green
}

if (-not $List -and -not (Test-Administrator)) {
    Request-AdministratorRelaunch
    exit 0
}

$candidates = @()
if ($List -or $PSCmdlet.ParameterSetName -ne 'Server') {
    $candidates = @(Get-CandidateServers)
    if ($candidates.Count -eq 0) { throw 'No Swiss IKEv2 servers were available from the live list or the seed pool.' }
}

if ($List) {
    $candidates | Format-Table Hostname, Load, Source -AutoSize
    exit 0
}

$selected = if ($PSCmdlet.ParameterSetName -eq 'Server') {
    $Server.Trim().ToLowerInvariant()
}
else {
    $reachable = $null
    foreach ($candidate in $candidates) {
        try {
            Resolve-PublicIPv4 -Hostname $candidate.Hostname
            $reachable = $candidate.Hostname
            break
        }
        catch { continue }
    }
    if ($null -eq $reachable) { throw 'None of the Swiss server candidates resolved successfully.' }
    $reachable
}

Set-ManagedServer -Hostname $selected
