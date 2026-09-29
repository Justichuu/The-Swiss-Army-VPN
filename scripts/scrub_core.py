#!/usr/bin/env python3
"""Offline state and phase scrubber. Never opens the network."""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RULES_PATH = Path(__file__).resolve().parent / "scrub-rules.json"

REPLACEMENTS = {
    "secret": "[secret]",
    "identity": "[redacted]",
    "ai-id": "[removed]",
}


class OfflineError(RuntimeError):
    pass


def refuse_network() -> None:
    def blocked(*_args, **_kwargs):
        raise OfflineError("The scrubber stays offline. Nothing was sent.")

    socket.socket = blocked  # type: ignore[assignment]
    os.environ.pop("HTTP_PROXY", None)
    os.environ.pop("HTTPS_PROXY", None)
    os.environ.pop("ALL_PROXY", None)


def load_rules() -> dict:
    return json.loads(RULES_PATH.read_text(encoding="utf-8"))


def compile_rules(rules: dict) -> list[tuple[str, str, re.Pattern[str]]]:
    compiled = []
    for group in ("secret_patterns", "identity_patterns", "ai_id_patterns"):
        for item in rules[group]:
            compiled.append((item["id"], item["kind"], re.compile(item["pattern"])))
    return compiled


def should_skip(path: Path, rules: dict) -> bool:
    name = path.name
    return name in set(rules.get("skip_names", [])) or name.endswith(".png") or name.endswith(".jpg") or name.endswith(".ico") or name.endswith(".gif")


def classify_and_redact(text: str, compiled) -> tuple[str, list[dict]]:
    findings = []
    redacted = text
    for rule_id, kind, pattern in compiled:
        matches = list(pattern.finditer(redacted))
        if not matches:
            continue
        findings.append({"id": rule_id, "kind": kind, "count": len(matches)})
        redacted = pattern.sub(REPLACEMENTS[kind], redacted)
    return redacted, findings


def verify(text: str, compiled) -> list[dict]:
    leftover = []
    for rule_id, kind, pattern in compiled:
        if kind != "secret":
            continue
        count = len(pattern.findall(text))
        if count:
            leftover.append({"id": rule_id, "kind": kind, "count": count})
    return leftover


def find_local_witness() -> Path | None:
    env = os.environ.get("JUSTICHUU_WITNESS", "").strip()
    if env:
        path = Path(env)
        return path if path.is_file() else None
    home = Path.home()
    for relative in (
        Path("Justichuu") / "witness" / "scrub.ps1",
        Path("Justichuu") / "witness" / "witness.ps1",
        Path("Justichuu") / "Swiss Army VPN" / "witness.ps1",
    ):
        candidate = home / relative
        if candidate.is_file():
            return candidate
    return None


def walk_sources(source: Path, rules: dict) -> list[Path]:
    if source.is_file():
        return [source]
    files = []
    for path in source.rglob("*"):
        if not path.is_file():
            continue
        if any(part in {".git", "artifacts", "node_modules"} for part in path.parts):
            continue
        if should_skip(path, rules):
            continue
        if path.stat().st_size > 2_000_000:
            continue
        files.append(path)
    return files


def scrub(source: Path, output: Path | None, scan_only: bool) -> dict:
    refuse_network()
    rules = load_rules()
    compiled = compile_rules(rules)
    findings = []
    leftover = []
    written = []

    for path in walk_sources(source, rules):
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        redacted, file_findings = classify_and_redact(text, compiled)
        if file_findings:
            findings.append({"path": str(path), "findings": file_findings})
        if output is not None and not scan_only:
            target = output / path.name
            if path != source and source.is_dir():
                target = output / path.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(redacted, encoding="utf-8")
            written.append(str(target))
            leftover.extend(verify(redacted, compiled))
        elif scan_only:
            leftover.extend(verify(redacted, compiled) if file_findings else [])

    witness = find_local_witness()
    report = {
        "tool": "Swiss Army VPN state and phase scrubber",
        "offline": True,
        "phases": rules["phases"],
        "source": str(source),
        "finding_files": len(findings),
        "findings": findings,
        "leftover_secrets": leftover,
        "written": written,
        "local_witness": str(witness) if witness else None,
        "ask_later": (
            "Justichuu has a local witness for this. This machine does not. "
            "The built-in checks still ran. Ask for that witness when you are at the local system."
        ),
        "safe_to_share": len(leftover) == 0 and (output is not None or scan_only),
    }
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Redact secrets from Swiss Army VPN state. Stays offline.")
    parser.add_argument("--source", default=str(ROOT), help="File or folder to read")
    parser.add_argument("--output", help="Folder for redacted copies")
    parser.add_argument("--scan-only", action="store_true", help="Report only. Write nothing.")
    parser.add_argument("--report", help="Write the JSON report here")
    args = parser.parse_args()

    source = Path(args.source).resolve()
    output = Path(args.output).resolve() if args.output else None
    if output is not None:
        output.mkdir(parents=True, exist_ok=True)

    try:
        report = scrub(source, output, args.scan_only)
    except OfflineError as error:
        print(error, file=sys.stderr)
        return 2

    text = json.dumps(report, indent=2)
    if args.report:
        Path(args.report).write_text(text + "\n", encoding="utf-8")
    print(text)
    if report["leftover_secrets"]:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
