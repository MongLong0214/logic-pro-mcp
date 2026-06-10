#!/usr/bin/env python3
"""Maintain the README live Logic Pro demo media.

The README hero video is a real Logic Pro 12.2 screen recording, not a
synthetic DAW surface. This script validates the captured MP4 and regenerates
the GIF/thumbnail derivatives from that MP4 so the README stays tied to the
actual Logic interface artifact.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from typing import Sequence

ROOT = Path(__file__).resolve().parents[2]
OUT_MP4 = ROOT / "docs/media/logic-pro-mcp-demo.mp4"
OUT_GIF = ROOT / "docs/media/logic-pro-mcp-demo.gif"
OUT_THUMB = ROOT / "docs/media/logic-pro-mcp-thumbnail.png"

GIF_FPS = 12
REQUIRED_PROBE_FIELDS = [
    "width=1920",
    "height=1080",
    "r_frame_rate=24/1",
    "duration=6.000000",
]


def run_checked(cmd: Sequence[str]) -> str:
    proc = subprocess.run(cmd, text=True, capture_output=True)
    if proc.returncode != 0:
        print(proc.stdout, file=sys.stderr)
        print(proc.stderr, file=sys.stderr)
        raise SystemExit(proc.returncode)
    return proc.stdout + proc.stderr


def render_derivatives_from_live_capture() -> None:
    if not OUT_MP4.exists():
        raise SystemExit(
            f"{OUT_MP4} is missing. Recapture a live Logic Pro screen recording first."
        )

    probe = run_checked(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "stream=width,height,r_frame_rate,nb_frames",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1",
            str(OUT_MP4),
        ]
    )
    missing = [item for item in REQUIRED_PROBE_FIELDS if item not in probe]
    if missing:
        raise SystemExit(f"{OUT_MP4} does not match the live-capture spec: {missing}\n{probe}")

    blackframe_report = run_checked(
        [
            "ffmpeg",
            "-i",
            str(OUT_MP4),
            "-vf",
            "blackframe=amount=98:threshold=32",
            "-an",
            "-f",
            "null",
            "-",
        ]
    )
    if "blackframe:" in blackframe_report:
        raise SystemExit(f"{OUT_MP4} contains black frames:\n{blackframe_report}")

    palette = OUT_MP4.with_suffix(".palette.png")
    run_checked(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-i",
            str(OUT_MP4),
            "-vf",
            f"fps={GIF_FPS},scale=920:-1:flags=lanczos,palettegen=stats_mode=diff",
            str(palette),
        ]
    )
    run_checked(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-i",
            str(OUT_MP4),
            "-i",
            str(palette),
            "-lavfi",
            f"fps={GIF_FPS},scale=920:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
            "-loop",
            "0",
            str(OUT_GIF),
        ]
    )
    run_checked(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-ss",
            "2",
            "-i",
            str(OUT_MP4),
            "-frames:v",
            "1",
            "-vf",
            "scale=1280:720:flags=lanczos",
            str(OUT_THUMB),
        ]
    )
    palette.unlink(missing_ok=True)
    print(probe.strip())
    print("blackframe check passed")
    print(f"rendered {OUT_GIF} from live Logic capture")
    print(f"rendered {OUT_THUMB} from live Logic capture")


if __name__ == "__main__":
    render_derivatives_from_live_capture()
