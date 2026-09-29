#!/usr/bin/env python3
"""Verify bring-your-own endpoint rules and that PowerShell copies stay identical."""

from __future__ import annotations

import ipaddress
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MARKER_BEGIN = "# --- managed-server-address-begin ---"
MARKER_END = "# --- managed-server-address-end ---"

SCRIPT_PATHS = [
    ROOT / "installer/Programs/PowershellBackup/Switch Swiss Army VPN Server.ps1",
    ROOT / "installer/Programs/PowershellBackup/Install Swiss Army VPN.ps1",
    ROOT / "installer/Programs/PowershellBackup/Uninstall Swiss Army VPN.ps1",
    ROOT / "installer/Programs/PowershellBackup/Emergency Unlock.ps1",
    ROOT / "installer/Programs/PowershellBackup/Update Swiss Army VPN.ps1",
]

UNSAFE = re.compile(r"""[:/\\ @\$;`|&<>'\"()\[\]{}#?%!,~]""")
LABEL = re.compile(
    r"^(?:[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?|xn--[a-z0-9-]{1,59})$",
    re.IGNORECASE,
)
DOTTED_QUAD = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")
NORD = re.compile(r"^[a-z]{2}[0-9]+\.nordvpn\.com$", re.IGNORECASE)
SWISS = re.compile(r"^ch[0-9]+\.nordvpn\.com$", re.IGNORECASE)


def is_allowed_vpn_ipv4(address: ipaddress.IPv4Address) -> bool:
    packed = address.packed
    if packed[0] in (0, 127):
        return False
    if packed[0] == 169 and packed[1] == 254:
        return False
    if packed[0] >= 224:
        return False
    return True


def is_safe_vpn_endpoint(value: str | None) -> bool:
    if value is None or not str(value).strip():
        return False
    candidate = value.strip().lower()
    if not candidate or len(candidate) > 253:
        return False

    if DOTTED_QUAD.match(candidate):
        try:
            parsed = ipaddress.ip_address(candidate)
        except ValueError:
            return False
        return isinstance(parsed, ipaddress.IPv4Address) and is_allowed_vpn_ipv4(parsed)

    if UNSAFE.search(candidate) or ".." in candidate or candidate.startswith(".") or candidate.endswith("."):
        return False
    if re.search(r"[^a-z0-9._-]", candidate):
        return False
    labels = candidate.split(".")
    if len(labels) < 2:
        return False
    return all(LABEL.match(label) for label in labels)


def extract_marked_function(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    start = text.find(MARKER_BEGIN)
    end = text.find(MARKER_END)
    if start < 0 or end < 0 or end <= start:
        raise AssertionError(f"Missing managed-server-address markers in {path}")
    return text[start : end + len(MARKER_END)].strip()


def extract_csharp_regex(name: str, source: str) -> str:
    match = re.search(
        rf"{name} = new Regex\(\s*@\"([^\"]+)\"",
        source,
        re.MULTILINE,
    )
    if not match:
        raise AssertionError(f"Could not find C# regex {name}")
    return match.group(1)


def main() -> int:
    copies = {path: extract_marked_function(path) for path in SCRIPT_PATHS}
    canonical = next(iter(copies.values()))
    for path, body in copies.items():
        if body != canonical:
            raise AssertionError(f"Test-ManagedServerAddress drifted in {path}")

    csharp = (ROOT / "src/SwissArmyVPN.cs").read_text(encoding="utf-8")
    expected = {
        "NordVpnHostnamePattern": r"^[a-z]{2}[0-9]+\.nordvpn\.com$",
        "SwissNordVpnHostnamePattern": r"^ch[0-9]+\.nordvpn\.com$",
        "SafeDnsLabelPattern": r"^(?:[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?|xn--[a-z0-9-]{1,59})$",
    }
    for name, pattern in expected.items():
        found = extract_csharp_regex(name, csharp)
        if found != pattern:
            raise AssertionError(f"{name} was {found!r}, expected {pattern!r}")

    accepted = [
        "ch221.nordvpn.com",
        "US1234.NordVPN.com",
        "ikev2.protonvpn.com",
        "nl-free-1.protonvpn.net",
        "vpn.company.local",
        "gate_way.corp.internal",
        "xn--bcher-kva.example",
        "example.com",
        "ch.nordvpn.com",
        "ch123.example.com",
        "10.0.0.1",
        "192.168.10.20",
        "203.0.113.10",
        "100.64.1.2",
    ]
    rejected = [
        "",
        "   ",
        "localhost",
        "vpn",
        "https://ikev2.example.com",
        "ikev2.example.com:500",
        "ikev2.example.com/path",
        "user@ikev2.example.com",
        "ikev2.example.com;calc.exe",
        "ikev2.example.com|whoami",
        "$(whoami).example.com",
        "127.0.0.1",
        "0.0.0.0",
        "169.254.1.1",
        "224.0.0.1",
        "255.255.255.255",
        "::1",
        "2001:db8::1",
        "1",
        ".example.com",
        "example.com.",
        "exa..mple.com",
        "bad host.com",
    ]

    failures = []
    for host in accepted:
        if not is_safe_vpn_endpoint(host):
            failures.append(f"expected accept: {host!r}")
    for host in rejected:
        if is_safe_vpn_endpoint(host):
            failures.append(f"expected reject: {host!r}")

    if not SWISS.match("ch221.nordvpn.com") or SWISS.match("us1234.nordvpn.com"):
        failures.append("Swiss NordVPN regex mismatch")
    if not NORD.match("us1234.nordvpn.com") or NORD.match("ikev2.protonvpn.com"):
        failures.append("NordVPN regex mismatch")

    if failures:
        print("MANAGED SERVER ADDRESS: FAIL")
        for item in failures:
            print("  " + item)
        return 1

    print("MANAGED SERVER ADDRESS: PASS")
    print(f"  PowerShell copies: {len(SCRIPT_PATHS)}")
    print(f"  accepted: {len(accepted)}")
    print(f"  rejected: {len(rejected)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
