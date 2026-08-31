#!/usr/bin/env python3
"""Witness: deleted unused code stays gone. Fails if it comes back."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

MUST_BE_GONE = [
    ROOT / "assets" / "Legacy Pirate Background.png",
    ROOT / "src" / "Installer" / "Program.cs",
    ROOT / "src" / "Installer" / "AssemblyInfo.cs",
    ROOT / "installer" / "Programs" / "PowershellBackup" / "ManualBackup" / "Swiss Army VPN.ps1",
    ROOT / "artifacts" / "verifier-integration-test" / "Verify Switzerland VPN Release 1.3.3.exe",
]

MUST_NOT_CONTAIN = [
    (ROOT / "src" / "SwissArmyVPN.cs", "working2"),
    (ROOT / "src" / "SwissArmyVPN.cs", "working3"),
    (ROOT / "src" / "SwissArmyVPN.cs", "firewalloff-empty"),
    (ROOT / "src" / "SwissArmyVPN.cs", "private static string Quote("),
    (ROOT / ".github" / "workflows" / "ci-build-and-release.yml", "switzerland-vpn-"),
    (ROOT / "installer" / "Programs" / "PowershellBackup" / "Update Swiss Army VPN.ps1", "ManualBackup"),
    (ROOT / "installer" / "Programs" / "PowershellBackup" / "Install Swiss Army VPN.ps1", "ManualBackup"),
    (ROOT / "installer" / "Programs" / "Package Checksums.txt", "ManualBackup"),
]

MUST_CONTAIN = [
    (ROOT / "src" / "SwissArmyVPN.cs", "internal static string QuoteArgument("),
    (ROOT / "src" / "SwissArmyVPN.cs", "Arguments = PrivateUpdateManager.QuoteArgument(name)"),
    (ROOT / "src" / "SwissArmyVPN.cs", '"-d " + PrivateUpdateManager.QuoteArgument(name)'),
]


def main() -> int:
    failures = []
    for path in MUST_BE_GONE:
        if path.exists():
            failures.append("still present: " + str(path.relative_to(ROOT)))
    for path, needle in MUST_NOT_CONTAIN:
        text = path.read_text(encoding="utf-8")
        if needle in text:
            failures.append(f"{path.relative_to(ROOT)} still contains {needle!r}")
    for path, needle in MUST_CONTAIN:
        text = path.read_text(encoding="utf-8")
        if needle not in text:
            failures.append(f"{path.relative_to(ROOT)} is missing {needle!r}")

    if failures:
        print("DEAD CODE GONE: FAIL")
        for item in failures:
            print("  " + item)
        return 1
    print("DEAD CODE GONE: PASS")
    print("  unused installer sources, pirate art, old verifier, ManualBackup, extra preview states,")
    print("  and the extra RAS Quote helper stay deleted; RAS names use QuoteArgument")
    return 0


if __name__ == "__main__":
    sys.exit(main())
