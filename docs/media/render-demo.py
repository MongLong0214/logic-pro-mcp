#!/usr/bin/env python3
"""Render the README product walkthrough media.

This cut is a compact proof chain, not a slide deck. It uses captured Logic Pro
frames, a readable MCP-client surface, visible before/after project change, and
resource readback evidence. It intentionally avoids debug badges, bottom scene
navigation, tiny copy, and claims that are not grounded in repo artifacts.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Sequence

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
BEFORE_PATH = ROOT / "artifacts/acid-track-composition/logic-before-new-composition.png"
AFTER_PATH = ROOT / "artifacts/acid-track-composition/logic-after-feeder-finished.png"
LIBRARY_PATH = ROOT / "artifacts/acid-track-composition/logic-v2-library-current.png"
OUT_MP4 = ROOT / "docs/media/logic-pro-mcp-demo.mp4"
OUT_GIF = ROOT / "docs/media/logic-pro-mcp-demo.gif"
OUT_THUMB = ROOT / "docs/media/logic-pro-mcp-thumbnail.png"

W, H = 1920, 1080
FPS = 24
GIF_FPS = 12
DURATION = 18.0
FRAMES = int(FPS * DURATION)

FONT = "/System/Library/Fonts/SFNS.ttf"
FONT_BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
FONT_MONO = "/System/Library/Fonts/SFNSMono.ttf"
if not os.path.exists(FONT_MONO):
    FONT_MONO = "/System/Library/Fonts/Monaco.ttf"


def load_font(size: int, *, bold: bool = False, mono: bool = False) -> ImageFont.FreeTypeFont:
    path = FONT_MONO if mono else (FONT_BOLD if bold and os.path.exists(FONT_BOLD) else FONT)
    return ImageFont.truetype(path, size)


F = {
    "eyebrow": load_font(24, bold=True),
    "hero": load_font(66, bold=True),
    "title": load_font(38, bold=True),
    "body": load_font(30),
    "small": load_font(24),
    "tiny": load_font(20),
    "mono_small": load_font(22, mono=True),
    "metric": load_font(58, bold=True),
    "metric_label": load_font(22, bold=True),
}

WHITE = (248, 251, 255)
INK = (5, 10, 18)
MUTED = (196, 207, 222)
LINE = (84, 112, 142)
TEAL = (35, 226, 184)
BLUE = (83, 145, 255)
AMBER = (255, 176, 54)
GREEN = (83, 232, 128)
RED = (255, 94, 112)
PURPLE = (169, 118, 255)
PANEL = (6, 13, 25)

ARRANGE_BOX = (572, 252, 1908, 650)
TRACK_BOX = (250, 204, 570, 650)


def clamp(value: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, value))


def smoothstep(value: float) -> float:
    value = clamp(value)
    return value * value * (3 - 2 * value)


def rgba(color: tuple[int, int, int], opacity: float) -> tuple[int, int, int, int]:
    return (*color, int(255 * clamp(opacity)))


def with_alpha(color: tuple[int, ...], opacity: float) -> tuple[int, int, int, int]:
    if len(color) == 4:
        return (*color[:3], int(color[3] * clamp(opacity)))
    return (*color, int(255 * clamp(opacity)))


def text_size(draw: ImageDraw.ImageDraw, text: str, face: ImageFont.FreeTypeFont) -> tuple[int, int]:
    box = draw.textbbox((0, 0), text, font=face)
    return box[2] - box[0], box[3] - box[1]


def draw_text(
    draw: ImageDraw.ImageDraw,
    xy: tuple[float, float],
    value: str,
    face: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int] = WHITE,
    opacity: float = 1.0,
    *,
    anchor: str | None = None,
    shadow: bool = False,
) -> None:
    if opacity <= 0:
        return
    if shadow:
        draw.text(
            (xy[0] + 2, xy[1] + 3),
            value,
            font=face,
            fill=(0, 0, 0, int(148 * clamp(opacity))),
            anchor=anchor,
        )
    draw.text(xy, value, font=face, fill=with_alpha(fill, opacity), anchor=anchor)


def paste_opacity(dst: Image.Image, src: Image.Image, xy: tuple[int, int], opacity: float) -> None:
    if opacity <= 0:
        return
    if opacity >= 0.999:
        dst.alpha_composite(src, xy)
        return
    tmp = src.copy()
    tmp.putalpha(tmp.getchannel("A").point(lambda p: int(p * clamp(opacity))))
    dst.alpha_composite(tmp, xy)


def panel_layer(
    size: tuple[int, int],
    *,
    radius: int = 18,
    fill: tuple[int, int, int, int] = (*PANEL, 236),
    outline: tuple[int, int, int, int] = (*LINE, 130),
    shadow: int = 130,
) -> Image.Image:
    w, h = size
    layer = Image.new("RGBA", (w + 64, h + 64), (0, 0, 0, 0))
    sh = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(sh)
    sd.rounded_rectangle((32, 32, 32 + w, 32 + h), radius=radius, fill=(0, 0, 0, shadow))
    sh = sh.filter(ImageFilter.GaussianBlur(18))
    layer = Image.alpha_composite(layer, sh)
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((32, 32, 32 + w, 32 + h), radius=radius, fill=fill, outline=outline, width=1)
    d.rounded_rectangle((33, 33, 31 + w, 31 + h), radius=max(0, radius - 1), outline=(255, 255, 255, 20), width=1)
    return layer


def pill(
    draw: ImageDraw.ImageDraw,
    x: int,
    y: int,
    label: str,
    color: tuple[int, int, int],
    opacity: float = 1.0,
    *,
    fill_dark: bool = False,
) -> int:
    face = F["tiny"] if len(label) > 18 else F["eyebrow"]
    tw, th = text_size(draw, label, face)
    w = tw + 32
    fill = (9, 18, 32, int(220 * opacity)) if fill_dark else rgba(color, opacity)
    outline = rgba(color, 0.7 * opacity) if fill_dark else None
    draw.rounded_rectangle((x, y, x + w, y + 36), radius=18, fill=fill, outline=outline, width=1)
    text_fill = color if fill_dark else INK
    draw_text(draw, (x + w / 2, y + (36 - th) / 2 - 1), label, face, text_fill, opacity, anchor="ma")
    return w


def load_logic_capture(path: Path) -> Image.Image:
    return Image.open(path).convert("RGB").resize((W, H), Image.Resampling.LANCZOS).convert("RGBA")


LOGIC_BEFORE = load_logic_capture(BEFORE_PATH)
LOGIC_AFTER = load_logic_capture(AFTER_PATH)
LOGIC_LIBRARY = load_logic_capture(LIBRARY_PATH)


def segment(t: float, start: float, end: float) -> float:
    return clamp((t - start) / (end - start))


def scrim(frame: Image.Image, opacity: int = 92) -> None:
    frame.alpha_composite(Image.new("RGBA", (W, H), (0, 0, 0, opacity)))


def draw_top_identity(draw: ImageDraw.ImageDraw, eyebrow: str, title: str, subtitle: str) -> None:
    pill(draw, 72, 58, eyebrow, TEAL, 1.0, fill_dark=True)
    draw_text(draw, (72, 120), title, F["hero"], WHITE, 1.0, shadow=True)
    draw_text(draw, (76, 202), subtitle, F["body"], MUTED, 1.0, shadow=True)


def terminal_line_color(line: str) -> tuple[int, int, int]:
    if line.startswith("$") or line.startswith("MCP"):
        return TEAL
    if "verified:true" in line or "confirmed" in line or "ready" in line:
        return GREEN
    if line.startswith("read") or "logic://" in line:
        return BLUE
    if "uncertain" in line or "fail" in line:
        return AMBER
    return MUTED


def draw_terminal(
    frame: Image.Image,
    x: int,
    y: int,
    w: int,
    h: int,
    title: str,
    rows: Sequence[str],
    progress: float,
) -> None:
    layer = panel_layer((w, h), radius=18, fill=(2, 7, 13, 244), outline=(85, 119, 150, 150), shadow=110)
    d = ImageDraw.Draw(layer)
    ox, oy = 32, 32
    d.rounded_rectangle((ox, oy, ox + w, oy + 58), radius=18, fill=(12, 21, 33, 235), outline=(255, 255, 255, 18), width=1)
    for i, color in enumerate((RED, AMBER, GREEN)):
        d.ellipse((ox + 22 + i * 26, oy + 22, ox + 36 + i * 26, oy + 36), fill=rgba(color, 0.88))
    draw_text(d, (ox + 108, oy + 18), title, F["small"], WHITE)

    visible = max(1, min(len(rows), int(progress * (len(rows) + 1.3))))
    row_y = oy + 88
    for idx, line in enumerate(rows[:visible]):
        op = 1.0 if idx < visible - 1 else 0.72 + 0.28 * smoothstep((progress * (len(rows) + 1.3)) % 1)
        draw_text(d, (ox + 30, row_y), line, F["mono_small"], terminal_line_color(line), op)
        row_y += 42

    if visible < len(rows):
        cursor_x = ox + 30
        cursor_y = row_y + 4
        if int(progress * 18) % 2 == 0:
            d.rectangle((cursor_x, cursor_y, cursor_x + 14, cursor_y + 25), fill=rgba(TEAL, 0.78))
    paste_opacity(frame, layer, (x - 32, y - 32), 1.0)


def draw_playhead(frame: Image.Image, progress: float, opacity: float = 1.0) -> None:
    d = ImageDraw.Draw(frame)
    x = int(612 + (2032 - 612) * progress)
    x = max(612, min(1848, x))
    d.line((x, 166, x, 746), fill=rgba(WHITE, 0.42 * opacity), width=2)
    d.line((x + 2, 166, x + 2, 746), fill=rgba(TEAL, 0.88 * opacity), width=3)
    d.polygon([(x - 12, 164), (x + 16, 164), (x + 2, 190)], fill=rgba(TEAL, 0.92 * opacity))


def draw_pro_highlight(
    frame: Image.Image,
    box: tuple[int, int, int, int],
    color: tuple[int, int, int],
    opacity: float = 1.0,
) -> None:
    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    x0, y0, x1, y1 = box
    d.rounded_rectangle((x0, y0, x1, y1), radius=14, fill=rgba(color, 0.06 * opacity), outline=rgba(color, 0.7 * opacity), width=3)
    d.rounded_rectangle((x0 + 6, y0 + 6, x1 - 6, y1 - 6), radius=10, outline=rgba(WHITE, 0.12 * opacity), width=1)
    frame.alpha_composite(overlay)


def draw_change_reveal(frame: Image.Image, progress: float) -> None:
    reveal = smoothstep(clamp((progress - 0.08) / 0.72))
    cut_x = int(W * reveal)
    if cut_x > 0:
        frame.alpha_composite(LOGIC_AFTER.crop((0, 0, cut_x, H)), (0, 0))
    if 24 < cut_x < W - 24:
        d = ImageDraw.Draw(frame)
        d.line((cut_x, 0, cut_x, H), fill=rgba(TEAL, 0.92), width=4)
        d.rounded_rectangle((cut_x - 86, 904, cut_x + 86, 952), radius=24, fill=(3, 11, 19, 230), outline=rgba(TEAL, 0.65), width=1)
        draw_text(d, (cut_x, 916), "after MCP", F["small"], TEAL, anchor="ma")


def draw_compact_step_chain(draw: ImageDraw.ImageDraw, x: int, y: int, steps: Sequence[tuple[str, str, tuple[int, int, int]]]) -> None:
    for i, (label, body, color) in enumerate(steps):
        yy = y + i * 86
        draw.ellipse((x, yy + 6, x + 28, yy + 34), fill=rgba(color, 0.92))
        draw_text(draw, (x + 9, yy + 5), str(i + 1), F["tiny"], INK)
        draw_text(draw, (x + 46, yy), label, F["title"], WHITE)
        draw_text(draw, (x + 48, yy + 43), body, F["small"], MUTED)


def draw_metric(draw: ImageDraw.ImageDraw, x: int, y: int, value: str, label: str, color: tuple[int, int, int]) -> None:
    draw.rounded_rectangle((x, y, x + 232, y + 132), radius=14, fill=(5, 14, 24, 232), outline=rgba(color, 0.58), width=1)
    draw_text(draw, (x + 28, y + 22), value, F["metric"], color, 1.0, shadow=True)
    draw_text(draw, (x + 30, y + 90), label, F["metric_label"], MUTED)


def draw_scene_prompt_to_tools(t: float) -> Image.Image:
    p = segment(t, 0.0, 6.0)
    frame = LOGIC_BEFORE.copy()
    draw_change_reveal(frame, p)
    scrim(frame, 86)
    d = ImageDraw.Draw(frame)
    draw_top_identity(
        d,
        "REAL LOGIC CAPTURE",
        "One prompt becomes typed Logic tools",
        "Client call, DAW change, and resource readback in one chain.",
    )
    terminal_rows = [
        "$ compose A-minor acid track",
        "MCP logic_system.health -> all channels ready",
        "MCP logic_transport.set_tempo {tempo:127}",
        "MCP logic_tracks.record_sequence x11",
        "MCP logic_project.save_as -> verified:true",
    ]
    draw_terminal(frame, 86, 342, 820, 378, "mcp-client / compose-session", terminal_rows, smoothstep(p))
    draw_pro_highlight(frame, ARRANGE_BOX, TEAL, 0.72)
    d.rounded_rectangle((1110, 792, 1794, 888), radius=18, fill=(4, 12, 22, 228), outline=rgba(TEAL, 0.48), width=1)
    draw_text(d, (1140, 810), "Visible change: audio reference -> 11 MIDI regions", F["body"], WHITE)
    draw_text(d, (1142, 852), "save_as returns verified:true after the project write.", F["small"], MUTED)
    return frame.convert("RGB")


def draw_scene_logic_mutates(t: float) -> Image.Image:
    p = segment(t, 6.0, 12.0)
    frame = LOGIC_AFTER.copy()
    scrim(frame, 58)
    draw_pro_highlight(frame, TRACK_BOX, BLUE, 0.7 + 0.2 * smoothstep(p))
    draw_pro_highlight(frame, ARRANGE_BOX, TEAL, 0.78)
    draw_playhead(frame, smoothstep(p), 1.0)
    d = ImageDraw.Draw(frame)
    draw_top_identity(
        d,
        "WRITE PATH",
        "MIDI lands in Logic, not in a mock UI",
        "Health, import, track writes, and save verification stay explicit.",
    )

    layer = panel_layer((690, 430), radius=18, fill=(2, 7, 13, 244), outline=(85, 119, 150, 150), shadow=110)
    ld = ImageDraw.Draw(layer)
    ox, oy = 32, 32
    draw_compact_step_chain(
        ld,
        ox + 28,
        oy + 28,
        [
            ("Health gate", "permissions and channels checked first", GREEN),
            ("SMF import jail", "/tmp/LogicProMCP before Logic import", BLUE),
            ("Track writes", "11 MIDI regions placed into the project", TEAL),
            ("Save gate", "package mtime checked after save_as", AMBER),
        ],
    )
    paste_opacity(frame, layer, (1066 - 32, 354 - 32), 1.0)
    d.rounded_rectangle((94, 882, 764, 952), radius=18, fill=(4, 12, 22, 230), outline=rgba(TEAL, 0.48), width=1)
    draw_text(d, (124, 900), "Captured project state: 11 MIDI regions after MCP writes.", F["small"], MUTED)
    return frame.convert("RGB")


def draw_scene_readback_proof(t: float) -> Image.Image:
    p = segment(t, 12.0, 18.0)
    frame = Image.blend(LOGIC_AFTER, LOGIC_LIBRARY, 0.34 + 0.18 * smoothstep(p)).convert("RGBA")
    scrim(frame, 96)
    d = ImageDraw.Draw(frame)
    draw_top_identity(
        d,
        "READBACK PROOF",
        "Tools mutate. Resources prove.",
        "Agent clients can inspect Logic state instead of trusting a transcript.",
    )

    proof_rows = [
        "read logic://tracks",
        "track_count: 11   regions: 11   source: ax_live",
        "read logic://project/info",
        "tempo: 127   key: A minor   saved: true",
        "outcome: confirmed | uncertain | failed",
    ]
    draw_terminal(frame, 88, 330, 820, 438, "resource-readback / after-write", proof_rows, 0.62 + 0.38 * smoothstep(p))

    panel = panel_layer((820, 438), radius=18, fill=(3, 9, 17, 242), outline=(85, 119, 150, 150), shadow=110)
    pd = ImageDraw.Draw(panel)
    ox, oy = 32, 32
    draw_compact_step_chain(
        pd,
        ox + 32,
        oy + 36,
        [
            ("Confirmed", "verified writes get explicit provenance", GREEN),
            ("Uncertain", "ambiguous UI state stays non-success", AMBER),
            ("Failed", "bad target or missing permission stops closed", RED),
        ],
    )
    pd.rounded_rectangle((ox + 34, oy + 324, ox + 760, oy + 378), radius=14, fill=rgba(TEAL, 0.12), outline=rgba(TEAL, 0.48), width=1)
    draw_text(pd, (ox + 58, oy + 336), "Current source tree: 1256 Swift tests + 293 strict live checks", F["small"], WHITE)
    paste_opacity(frame, panel, (1012 - 32, 330 - 32), 1.0)

    mx, my = 88, 842
    for value, label, color in [
        ("8", "MCP tools", TEAL),
        ("14", "resources", BLUE),
        ("7", "templates", PURPLE),
        ("1256", "Swift tests", GREEN),
        ("293", "strict live", AMBER),
    ]:
        draw_metric(d, mx, my, value, label, color)
        mx += 260
    return frame.convert("RGB")


def render_frame(t: float) -> Image.Image:
    if t < 6.0:
        return draw_scene_prompt_to_tools(t)
    if t < 12.0:
        return draw_scene_logic_mutates(t)
    return draw_scene_readback_proof(t)


def run(cmd: Sequence[str]) -> None:
    proc = subprocess.run(cmd, text=True, capture_output=True)
    if proc.returncode != 0:
        print(proc.stdout, file=sys.stderr)
        print(proc.stderr, file=sys.stderr)
        raise SystemExit(proc.returncode)


def render_video() -> None:
    OUT_THUMB.parent.mkdir(parents=True, exist_ok=True)
    render_frame(15.1).resize((1280, 720), Image.Resampling.LANCZOS).save(OUT_THUMB, optimize=True)

    cmd = [
        "ffmpeg",
        "-y",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "-s",
        f"{W}x{H}",
        "-r",
        str(FPS),
        "-i",
        "-",
        "-an",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-profile:v",
        "high",
        "-level",
        "4.1",
        "-crf",
        "18",
        "-preset",
        "slow",
        "-movflags",
        "+faststart",
        str(OUT_MP4),
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        assert proc.stdin is not None
        for frame_index in range(FRAMES):
            proc.stdin.write(render_frame(frame_index / FPS).tobytes())
    finally:
        if proc.stdin:
            proc.stdin.close()
    stderr = proc.stderr.read().decode("utf-8", errors="replace")
    code = proc.wait()
    if code != 0:
        print(stderr, file=sys.stderr)
        raise SystemExit(code)

    palette = OUT_MP4.with_suffix(".palette.png")
    run(
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
    run(
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
    palette.unlink(missing_ok=True)
    print(f"rendered {OUT_MP4} frames={FRAMES} fps={FPS} duration={DURATION}s")
    print(f"rendered {OUT_GIF} fps={GIF_FPS}")
    print(f"thumbnail {OUT_THUMB}")


if __name__ == "__main__":
    render_video()
