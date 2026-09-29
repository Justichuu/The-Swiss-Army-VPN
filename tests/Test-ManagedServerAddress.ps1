# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$scriptPaths = @(
    (Join-Path $repositoryRoot 'installer\Programs\PowershellBackup\Switch Swiss Army VPN Server.ps1')
    (Join-Path $repositoryRoot 'installer\Programs\PowershellBackup\Install Swiss Army VPN.ps1')
    (Join-Path $repositoryRoot 'installer\Programs\PowershellBackup\Uninstall Swiss Army VPN.ps1')
    (Join-Path $repositoryRoot 'installer\Programs\PowershellBackup\Emergency Unlock.ps1')
    (Join-Path $repositoryRoot 'installer\Programs\PowershellBackup\Update Swiss Army VPN.ps1')
)

$begin = '# --- managed-server-address-begin ---'
$end = '# --- managed-server-address-end ---'
$bodies = @()
foreach ($path in $scriptPaths) {
    $text = Get-Content -LiteralPath $path -Raw
    $startIndex = $text.IndexOf($begin)
    $endIndex = $text.IndexOf($end)
    if ($startIndex -lt 0 -or $endIndex -lt 0 -or $endIndex -le $startIndex) {
        throw "Missing managed-server-address markers in $path"
    }
    $bodies += $text.Substring($startIndex, ($endIndex + $end.Length) - $startIndex).Trim()
}
for ($i = 1; $i -lt $bodies.Count; $i++) {
    if (-not [string]::Equals($bodies[$i], $bodies[0], [StringComparison]::Ordinal)) {
        throw "Test-ManagedServerAddress drifted in $($scriptPaths[$i])"
    }
}

Invoke-Expression $bodies[0]

$accepted = @(
    'ch221.nordvpn.com'
    'US1234.NordVPN.com'
    'ikev2.protonvpn.com'
    'nl-free-1.protonvpn.net'
    'vpn.company.local'
    'gate_way.corp.internal'
    'xn--bcher-kva.example'
    'example.com'
    'ch.nordvpn.com'
    'ch123.example.com'
    '10.0.0.1'
    '192.168.10.20'
    '203.0.113.10'
    '100.64.1.2'
)
$rejected = @(
    ''
    '   '
    'localhost'
    'vpn'
    'https://ikev2.example.com'
    'ikev2.example.com:500'
    'ikev2.example.com/path'
    'user@ikev2.example.com'
    'ikev2.example.com;calc.exe'
    'ikev2.example.com|whoami'
    '$(whoami).example.com'
    '127.0.0.1'
    '0.0.0.0'
    '169.254.1.1'
    '224.0.0.1'
    '255.255.255.255'
    '::1'
    '2001:db8::1'
    '1'
    '.example.com'
    'example.com.'
    'exa..mple.com'
    'bad host.com'
)

$failures = @()
foreach ($hostName in $accepted) {
    if (-not (Test-ManagedServerAddress -Value $hostName)) {
        $failures += "expected accept: $hostName"
    }
}
foreach ($hostName in $rejected) {
    if (Test-ManagedServerAddress -Value $hostName) {
        $failures += "expected reject: $hostName"
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'MANAGED SERVER ADDRESS: FAIL'
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host 'MANAGED SERVER ADDRESS: PASS'
exit 0
