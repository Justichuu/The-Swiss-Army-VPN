#!/usr/bin/env python3
"""Caption remaining widget stills into one GIF and MP4. Requires ffmpeg."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_STATES = ROOT / "docs" / "media" / "widget-states" / "states.json"
DEFAULT_OUTPUT_GIF = ROOT / "docs" / "media" / "vpn-working-demo" / "vpn-working-demo.gif"
DEFAULT_OUTPUT_MP4 = ROOT / "docs" / "media" / "vpn-working-demo" / "vpn-working-demo.mp4"
DEFAULT_WIDGET_PNG = ROOT / "docs" / "widget.png"
FONT_CANDIDATES = [
    Path("/usr/share/fonts/truetype/macos/Inter-SemiBold.ttf"),
    Path("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"),
    Path("/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"),
]


def load_states(path: Path) -> list[dict]:
    catalog = json.loads(path.read_text(encoding="utf-8"))
    states = catalog.get("states")
    if not isinstance(states, list) or not states:
        raise SystemExit(f"No states in {path}")
    return states


def find_font() -> Path:
    for candidate in FONT_CANDIDATES:
        if candidate.is_file():
            return candidate
    raise SystemExit("No caption font found.")


def run_ffmpeg(args: list[str]) -> None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("ffmpeg is required to assemble the widget-state film.")
    completed = subprocess.run(
        [ffmpeg, "-hide_banner", "-loglevel", "error", *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip()
        raise SystemExit(f"ffmpeg failed: {detail}")


def escape_drawtext(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace(":", "\\:")
        .replace("'", "\\'")
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input-directory",
        type=Path,
        default=ROOT / "artifacts" / "widget-previews",
        help="Directory of {state}.png stills from Render-WidgetStatePreviews.ps1",
    )
    parser.add_argument("--states", type=Path, default=DEFAULT_STATES)
    parser.add_argument("--gif", type=Path, default=DEFAULT_OUTPUT_GIF)
    parser.add_argument("--mp4", type=Path, default=DEFAULT_OUTPUT_MP4)
    parser.add_argument("--widget-png", type=Path, default=DEFAULT_WIDGET_PNG)
    args = parser.parse_args()

    states = load_states(args.states)
    font = find_font()
    input_directory = args.input_directory.resolve()
    missing = [state["name"] for state in states if not (input_directory / f"{state['name']}.png").is_file()]
    if missing:
        raise SystemExit("Missing preview stills: " + ", ".join(missing))

    args.gif.parent.mkdir(parents=True, exist_ok=True)
    args.mp4.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="widget-state-film-") as raw_temp:
        temp = Path(raw_temp)
        captioned: list[Path] = []
        for index, state in enumerate(states):
            source = input_directory / f"{state['name']}.png"
            dest = temp / f"{index:02d}-{state['name']}.png"
            caption = escape_drawtext(f"{index + 1}/{len(states)}  {state['caption']}")
            run_ffmpeg(
                [
                    "-y",
                    "-i",
                    str(source),
                    "-vf",
                    (
                        "pad=iw:ih+56:0:0:color=0x181A1F,"
                        f"drawtext=fontfile={font}:fontsize=18:fontcolor=0xEBEFF4:"
                        f"text='{caption}':x=16:y=h-38"
                    ),
                    str(dest),
                ]
            )
            captioned.append(dest)

        list_path = temp / "frames.txt"
        list_path.write_text(
            "".join(f"file '{frame.as_posix()}'\nduration 2.2\n" for frame in captioned)
            + f"file '{captioned[-1].as_posix()}'\n",
            encoding="utf-8",
        )
        palette = temp / "palette.png"
        concat = ["-f", "concat", "-safe", "0", "-i", str(list_path)]
        run_ffmpeg([*concat, "-vf", "palettegen=reserve_transparent=0", str(palette)])
        run_ffmpeg(
            [
                *concat,
                "-i",
                str(palette),
                "-lavfi",
                "paletteuse=dither=bayer:bayer_scale=4",
                "-loop",
                "0",
                "-y",
                str(args.gif),
            ]
        )
        run_ffmpeg(
            [
                *concat,
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-vf",
                "pad=ceil(iw/2)*2:ceil(ih/2)*2",
                "-movflags",
                "+faststart",
                "-y",
                str(args.mp4),
            ]
        )

    working = input_directory / "working.png"
    if working.is_file():
        shutil.copyfile(working, args.widget_png)

    print(f"GIF: {args.gif}")
    print(f"MP4: {args.mp4}")
    if working.is_file():
        print(f"Still: {args.widget_png}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
