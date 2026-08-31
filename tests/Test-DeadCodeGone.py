#!/usr/bin/env python3
"""Unused files stay gone. No source-string hunting."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]

GONE = [
    "assets/Legacy Pirate Background.png",
    "src/Installer/Program.cs",
    "src/Installer/AssemblyInfo.cs",
    "installer/Programs/PowershellBackup/ManualBackup/Swiss Army VPN.ps1",
    "artifacts/verifier-integration-test/Verify Switzerland VPN Release 1.3.3.exe",
    "scripts/Render-WidgetStatePreviews.ps1",
    "scripts/assemble_widget_state_gif.py",
    "docs/media/vpn-working-demo/CAPTIONS.md",
    "docs/media/widget-states/states.json",
    "ROADMAP.md",
]

KEEP = [
    "ROADMAP.png",
    "docs/media/vpn-working-demo/vpn-working-demo.gif",
    "docs/media/widget-states/disconnected.png",
    "docs/media/widget-states/connecting.png",
    "docs/media/widget-states/protected.png",
    "docs/media/widget-states/working.png",
    "docs/media/widget-states/unprotected.png",
    "docs/media/widget-states/blocked.png",
    "docs/media/widget-states/incomplete.png",
    "docs/media/widget-states/firewalloff.png",
    "docs/media/widget-states/error.png",
]


def main() -> int:
    bad = []
    for rel in GONE:
        if (ROOT / rel).exists():
            bad.append("still present: " + rel)
    for rel in KEEP:
        if not (ROOT / rel).is_file():
            bad.append("missing: " + rel)
    if bad:
        print("DEAD CODE GONE: FAIL")
        for item in bad:
            print("  " + item)
        return 1
    print("DEAD CODE GONE: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
