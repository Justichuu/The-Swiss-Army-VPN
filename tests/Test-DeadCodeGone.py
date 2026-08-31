#!/usr/bin/env python3
"""Witness: deleted unused code stays gone. Remaining widget states stay named."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src" / "SwissArmyVPN.cs"
STATES = ROOT / "docs" / "media" / "widget-states" / "states.json"
RENDER_SCRIPT = ROOT / "scripts" / "Render-WidgetStatePreviews.ps1"

MUST_BE_GONE = [
    ROOT / "assets" / "Legacy Pirate Background.png",
    ROOT / "src" / "Installer" / "Program.cs",
    ROOT / "src" / "Installer" / "AssemblyInfo.cs",
    ROOT / "installer" / "Programs" / "PowershellBackup" / "ManualBackup" / "Swiss Army VPN.ps1",
    ROOT / "artifacts" / "verifier-integration-test" / "Verify Switzerland VPN Release 1.3.3.exe",
]

MUST_NOT_CONTAIN = [
    (SOURCE, "working2"),
    (SOURCE, "working3"),
    (SOURCE, "firewalloff-empty"),
    (SOURCE, "private static string Quote("),
    (ROOT / ".github" / "workflows" / "ci-build-and-release.yml", "switzerland-vpn-"),
    (ROOT / "installer" / "Programs" / "PowershellBackup" / "Update Swiss Army VPN.ps1", "ManualBackup"),
    (ROOT / "installer" / "Programs" / "PowershellBackup" / "Install Swiss Army VPN.ps1", "ManualBackup"),
    (ROOT / "installer" / "Programs" / "Package Checksums.txt", "ManualBackup"),
]

MUST_CONTAIN = [
    (SOURCE, "internal static string QuoteArgument("),
    (SOURCE, "Arguments = PrivateUpdateManager.QuoteArgument(name)"),
    (SOURCE, '"-d " + PrivateUpdateManager.QuoteArgument(name)'),
    (SOURCE, "--preview-state"),
    (SOURCE, "internal void RenderPreview("),
    (RENDER_SCRIPT, "--preview-state"),
    (ROOT / ".github" / "workflows" / "ci-build-and-release.yml", "Render-WidgetStatePreviews.ps1"),
    (ROOT / "scripts" / "Build-Release.ps1", "'tests', 'docs'"),
]

DELETED_PREVIEW_STATES = ("working2", "working3", "firewalloff-empty")


def create_preview_names(source_text: str) -> list[str]:
    match = re.search(
        r"private static WidgetState CreatePreview\(string name\)\s*\{(.*?)\n        \}",
        source_text,
        re.S,
    )
    if not match:
        return []
    return re.findall(r'case "([a-z0-9-]+)":', match.group(1))


def catalog_names() -> list[str]:
    catalog = json.loads(STATES.read_text(encoding="utf-8"))
    return [str(item["name"]) for item in catalog["states"]]


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

    source_text = SOURCE.read_text(encoding="utf-8")
    preview_names = create_preview_names(source_text)
    if not preview_names:
        failures.append("CreatePreview has no remaining state names")
    for deleted in DELETED_PREVIEW_STATES:
        if deleted in preview_names:
            failures.append(f"deleted preview state came back: {deleted}")

    if not STATES.is_file():
        failures.append("missing docs/media/widget-states/states.json")
    else:
        listed = catalog_names()
        if listed != preview_names:
            failures.append(
                "widget-states/states.json names must match CreatePreview exactly: "
                f"catalog={listed!r} preview={preview_names!r}"
            )
        render_text = RENDER_SCRIPT.read_text(encoding="utf-8")
        if "states.json" not in render_text:
            failures.append("Render-WidgetStatePreviews.ps1 must read states.json")

    if failures:
        print("DEAD CODE GONE: FAIL")
        for item in failures:
            print("  " + item)
        return 1
    print("DEAD CODE GONE: PASS")
    print("  unused installer sources, pirate art, old verifier, ManualBackup, extra preview states,")
    print("  and the extra RAS Quote helper stay deleted; RAS names use QuoteArgument")
    print("  remaining widget states: " + ", ".join(preview_names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
