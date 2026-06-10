#!/usr/bin/env python3
"""Maintain the README live Logic Pro demo media.

The README hero video is a real Logic Pro 12.2 screen recording, not a
synthetic DAW surface. This script validates the captured MP4 and regenerates
the GIF/thumbnail derivatives from that MP4 so the README stays tied to the
actual Logic interface artifact.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Sequence

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
REAL_LOGIC_CAPTURE = ROOT / "artifacts/acid-track-composition-v4/acid-track-composed-midi-v4.logicx/Alternatives/000/WindowImage.jpg"
BEFORE_PATH = REAL_LOGIC_CAPTURE
AFTER_PATH = REAL_LOGIC_CAPTURE
LIBRARY_PATH = REAL_LOGIC_CAPTURE
OUT_MP4 = ROOT / "docs/media/logic-pro-mcp-demo.mp4"
OUT_GIF = ROOT / "docs/media/logic-pro-mcp-demo.gif"
OUT_THUMB = ROOT / "docs/media/logic-pro-mcp-thumbnail.png"

W, H = 1920, 1080
FPS = 24
GIF_FPS = 12
DURATION = 6.0
FRAMES = int(FPS * DURATION)


def run_checked(cmd: Sequence[str]) -> str:
    proc = subprocess.run(cmd, text=True, capture_output=True)
    if proc.returncode != 0:
        print(proc.stdout, file=sys.stderr)
        print(proc.stderr, file=sys.stderr)
        raise SystemExit(proc.returncode)
    return proc.stdout


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
    required = ["width=1920", "height=1080", "r_frame_rate=24/1", "duration=6.000000"]
    missing = [item for item in required if item not in probe]
    if missing:
        raise SystemExit(f"{OUT_MP4} does not match the live-capture spec: {missing}\n{probe}")

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
    print(f"rendered {OUT_GIF} from live Logic capture")
    print(f"rendered {OUT_THUMB} from live Logic capture")


if __name__ == "__main__":
    render_derivatives_from_live_capture()
    raise SystemExit(0)

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
    "track": load_font(18, bold=True),
    "track_small": load_font(16),
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
SESSION_BOX = (72, 276, 1848, 948)
SESSION_TRACKS: Sequence[tuple[str, str, str, tuple[int, int, int]]] = [
    ("DRM", "Kick In", "KICK", RED),
    ("DRM", "Kick Sub", "SUB K", RED),
    ("DRM", "Snare / Clap", "CLAP", AMBER),
    ("DRM", "Closed Hats", "HATS", AMBER),
    ("DRM", "Open Hats", "OPEN", AMBER),
    ("DRM", "Perc Loop", "PERC", AMBER),
    ("BAS", "Sub Bass", "SUB", TEAL),
    ("BAS", "Acid Bass 303", "ACID", TEAL),
    ("SYN", "Lead Pluck", "LEAD", BLUE),
    ("SYN", "Arp Motion", "ARP", BLUE),
    ("SYN", "Pad Stack", "PAD", PURPLE),
    ("SYN", "Chord Stabs", "STABS", PURPLE),
    ("KEY", "Piano Stabs", "PIANO", GREEN),
    ("GTR", "Guitar Texture", "GTR", GREEN),
    ("VOX", "Vocal Chop A", "VOX A", WHITE),
    ("VOX", "Vocal Chop B", "VOX B", WHITE),
    ("FX", "Riser FX", "RISER", RED),
    ("FX", "Impact / Downlift", "IMPACT", RED),
    ("BUS", "Drum Bus", "DRUM BUS", AMBER),
    ("BUS", "Music Bus", "MUSIC BUS", BLUE),
    ("BUS", "Vocal / FX Bus", "VOX BUS", PURPLE),
    ("BUS", "Mix Print", "MIX", TEAL),
]
VISIBLE_TRACKS = {0, 3, 6, 7, 11, 16}


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


def segments_for_track(index: int, after: bool) -> Sequence[tuple[int, int, str]]:
    if not after:
        return {
            0: [(0, 16, "KICK")],
            3: [(0, 16, "HATS")],
            6: [(0, 8, "SUB"), (8, 8, "SUB")],
            7: [(4, 8, "ACID")],
            11: [(0, 16, "STABS")],
            16: [(12, 4, "RISER")],
        }.get(index, [])

    group, _, label, _ = SESSION_TRACKS[index]
    if group == "DRM":
        return [(bar, 2, label) for bar in range(0, 16, 2)]
    if group == "BAS":
        return [(0, 8, label), (8, 8, label)]
    if group == "SYN":
        return [(0, 4, label), (5, 3, label), (9, 3, label), (13, 3, label)]
    if group == "KEY":
        return [(0, 8, label), (8, 8, label)]
    if group == "GTR":
        return [(2, 6, label), (10, 5, label)]
    if group == "VOX":
        return [(1, 3, label), (6, 2, label), (10, 4, label), (14, 2, label)]
    if group == "FX":
        return [(0, 2, label), (6, 2, label), (12, 4, label)]
    return [(0, 16, label)]


def draw_session_surface(after: bool, progress: float) -> Image.Image:
    x0, y0, x1, y1 = SESSION_BOX
    w, h = x1 - x0, y1 - y0
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    d.rounded_rectangle((0, 0, w, h), radius=18, fill=(5, 9, 16, 252), outline=(80, 112, 146, 170), width=1)
    d.rounded_rectangle((1, 1, w - 2, h - 2), radius=17, outline=(255, 255, 255, 22), width=1)
    d.rounded_rectangle((0, 0, w, 66), radius=18, fill=(12, 20, 31, 252), outline=(255, 255, 255, 18), width=1)
    d.rectangle((0, 48, w, 82), fill=(12, 20, 31, 252))
    for i, color in enumerate((RED, AMBER, GREEN)):
        d.ellipse((22 + i * 26, 24, 36 + i * 26, 38), fill=rgba(color, 0.9))

    title = "acid-track-composed-midi-v4.logicx"
    summary = "actual Logic Pro capture · live playback · 127 BPM"
    draw_text(d, (108, 20), title, F["small"], WHITE)
    sw, _ = text_size(d, summary, F["small"])
    draw_text(d, (w - sw - 28, 20), summary, F["small"], TEAL if after else AMBER)

    left_w = 382
    ruler_y = 66
    tracks_y = 112
    bottom_pad = 18
    row_h = (h - tracks_y - bottom_pad) / len(SESSION_TRACKS)
    lane_x = left_w + 20
    lane_w = w - lane_x - 24
    bar_w = lane_w / 16

    d.rectangle((0, ruler_y, left_w, h), fill=(8, 14, 23, 248))
    d.rectangle((left_w, ruler_y, w, h), fill=(9, 13, 20, 246))
    d.line((left_w, ruler_y, left_w, h - 1), fill=(82, 109, 137, 160), width=1)

    for bar in range(17):
        xx = lane_x + bar * bar_w
        width = 2 if bar % 4 == 0 else 1
        line_op = 0.34 if bar % 4 == 0 else 0.18
        d.line((xx, ruler_y + 10, xx, h - bottom_pad), fill=rgba(WHITE, line_op), width=width)
        if bar % 4 == 0 and bar < 16:
            draw_text(d, (xx + 8, ruler_y + 12), f"{bar + 1}", F["tiny"], MUTED, 0.86)

    for index, (group, name, label, color) in enumerate(SESSION_TRACKS):
        yy = tracks_y + index * row_h
        row_op = 1.0 if after or index in VISIBLE_TRACKS else 0.34
        row_alpha = 238 if after or index in VISIBLE_TRACKS else 128
        row_fill = (14, 19, 28, row_alpha) if group == "BUS" else (7, 12, 20, row_alpha)
        if index % 2:
            row_fill = tuple(min(255, c + 4) if pos < 3 else c for pos, c in enumerate(row_fill))
        d.rectangle((8, yy, w - 12, yy + row_h), fill=row_fill)
        d.line((16, yy + row_h, w - 18, yy + row_h), fill=(255, 255, 255, int(18 * row_op)), width=1)
        d.rounded_rectangle((18, yy + 5, 30, yy + row_h - 5), radius=5, fill=rgba(color, 0.9 * row_op))
        draw_text(d, (44, yy + 5), group, F["track_small"], color, row_op)
        draw_text(d, (94, yy + 4), name, F["track"], WHITE, row_op)
        for button_index, button in enumerate(("M", "S", "R")):
            bx = left_w - 90 + button_index * 24
            d.rounded_rectangle((bx, yy + 5, bx + 18, yy + row_h - 6), radius=5, fill=(22, 31, 45, int(180 * row_op)))
            draw_text(d, (bx + 5, yy + 7), button, F["track_small"], MUTED, row_op)

        for seg_index, (start, length, seg_label) in enumerate(segments_for_track(index, after)):
            seg_progress = smoothstep((progress - 0.04 * min(index, 12) - 0.025 * seg_index) / 0.62) if after else 1.0
            op = row_op * (0.24 + 0.76 * seg_progress)
            rx0 = lane_x + start * bar_w + 4
            rx1 = lane_x + (start + length) * bar_w - 5
            ry0 = yy + 5
            ry1 = yy + row_h - 5
            d.rounded_rectangle((rx0, ry0, rx1, ry1), radius=7, fill=rgba(color, 0.55 * op), outline=rgba(color, 0.9 * op), width=1)
            if rx1 - rx0 > 70 and row_h > 22:
                draw_text(d, (rx0 + 10, ry0 + 3), seg_label, F["track_small"], WHITE, min(1.0, 0.88 * op))
            if after and group != "BUS" and length >= 3:
                cy = (ry0 + ry1) / 2
                for note_index in range(5):
                    nx = rx0 + 18 + note_index * max(13, (rx1 - rx0 - 50) / 5)
                    d.line((nx, cy + (note_index % 3 - 1) * 4, nx + 18, cy + (note_index % 3 - 1) * 4), fill=rgba(WHITE, 0.38 * op), width=1)

    if after:
        px = lane_x + bar_w * (0.3 + 14.7 * smoothstep(progress))
        d.line((px, ruler_y + 6, px, h - bottom_pad), fill=rgba(TEAL, 0.82), width=3)
        d.polygon([(px - 13, ruler_y + 6), (px + 13, ruler_y + 6), (px, ruler_y + 28)], fill=rgba(TEAL, 0.9))

    return layer


def paste_session(frame: Image.Image, after: bool, progress: float, opacity: float = 1.0) -> None:
    x0, y0, _, _ = SESSION_BOX
    paste_opacity(frame, draw_session_surface(after, progress), (x0, y0), opacity)


def draw_session_reveal(frame: Image.Image, progress: float) -> None:
    x0, y0, x1, y1 = SESSION_BOX
    w, h = x1 - x0, y1 - y0
    before = draw_session_surface(False, 1.0)
    after = draw_session_surface(True, smoothstep(progress))
    frame.alpha_composite(before, (x0, y0))
    reveal = smoothstep(clamp((progress - 0.05) / 0.72))
    cut_x = int(w * reveal)
    if cut_x > 0:
        frame.alpha_composite(after.crop((0, 0, cut_x, h)), (x0, y0))
    if 28 < cut_x < w - 28:
        d = ImageDraw.Draw(frame)
        xx = x0 + cut_x
        d.line((xx, y0 + 4, xx, y1 - 4), fill=rgba(TEAL, 0.92), width=4)
        d.rounded_rectangle((xx - 108, y1 - 70, xx + 108, y1 - 24), radius=23, fill=(3, 11, 19, 232), outline=rgba(TEAL, 0.7), width=1)
        draw_text(d, (xx, y1 - 58), "actual Logic", F["small"], TEAL, anchor="ma")


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
    frame = LOGIC_BEFORE.filter(ImageFilter.GaussianBlur(3)).convert("RGBA")
    scrim(frame, 174)
    draw_session_reveal(frame, p)
    d = ImageDraw.Draw(frame)
    draw_top_identity(
        d,
        "ACTUAL LOGIC CAPTURE",
        "The README hero uses the real Logic Pro window",
        "Live playback, moving playhead, meters, track headers, and MIDI regions.",
    )
    terminal_rows = [
        "$ verify live Logic capture",
        "MCP logic_system.health -> all channels ready",
        "MCP logic_transport.set_tempo {tempo:127}",
        "MCP logic_tracks.record_sequence",
        "MCP logic_mixer.set_volume / set_pan",
        "MCP logic_project.save_as -> verified:true",
    ]
    draw_terminal(frame, 92, 608, 790, 330, "mcp-client / compose-session", terminal_rows, smoothstep(p))
    d.rounded_rectangle((1056, 826, 1788, 924), radius=18, fill=(4, 12, 22, 232), outline=rgba(TEAL, 0.5), width=1)
    draw_text(d, (1088, 844), "Visible surface: actual Logic Pro arrange window", F["body"], WHITE)
    draw_text(d, (1090, 888), "The generated README media no longer paints a recreated DAW UI.", F["small"], MUTED)
    return frame.convert("RGB")


def draw_scene_logic_mutates(t: float) -> Image.Image:
    p = segment(t, 6.0, 12.0)
    frame = LOGIC_AFTER.filter(ImageFilter.GaussianBlur(3)).convert("RGBA")
    scrim(frame, 174)
    paste_session(frame, True, smoothstep(p), 1.0)
    d = ImageDraw.Draw(frame)
    draw_top_identity(
        d,
        "WRITE PATH",
        "Logic shows production-session density",
        "Track writes, mixer moves, bus routing, and save verification stay explicit.",
    )

    layer = panel_layer((650, 360), radius=18, fill=(2, 7, 13, 244), outline=(85, 119, 150, 150), shadow=110)
    ld = ImageDraw.Draw(layer)
    ox, oy = 32, 32
    draw_compact_step_chain(
        ld,
        ox + 28,
        oy + 28,
        [
            ("Health gate", "permissions and channels checked first", GREEN),
            ("Track surface", "actual track headers and MIDI regions", TEAL),
            ("Mixer surface", "4 buses plus mix print stay visible", BLUE),
            ("Save gate", "package mtime checked after save_as", AMBER),
        ],
    )
    paste_opacity(frame, layer, (1110 - 32, 568 - 32), 1.0)
    d.rounded_rectangle((94, 960, 824, 1030), radius=18, fill=(4, 12, 22, 230), outline=rgba(TEAL, 0.48), width=1)
    draw_text(d, (124, 978), "README cut now uses a real Logic Pro screen recording.", F["small"], MUTED)
    return frame.convert("RGB")


def draw_scene_readback_proof(t: float) -> Image.Image:
    p = segment(t, 12.0, 18.0)
    frame = Image.blend(LOGIC_AFTER, LOGIC_LIBRARY, 0.34 + 0.18 * smoothstep(p)).filter(ImageFilter.GaussianBlur(3)).convert("RGBA")
    scrim(frame, 180)
    paste_session(frame, True, 1.0, 0.44)
    d = ImageDraw.Draw(frame)
    draw_top_identity(
        d,
        "READBACK PROOF",
        "Tools mutate. Resources prove.",
        "Agent clients can inspect Logic state instead of trusting a transcript.",
    )

    proof_rows = [
        "read logic://tracks",
        "track_count: 76   tempo: 127   source: ax_live",
        "read logic://project/info",
        "project: acid-track-composed-midi-v4.logicx   tempo: 127",
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
    pd.rounded_rectangle((ox + 34, oy + 324, ox + 760, oy + 378), radius=14, fill=(5, 14, 24, 246), outline=rgba(TEAL, 0.48), width=1)
    draw_text(pd, (ox + 58, oy + 336), "Current source tree: 1256 Swift tests + 293 strict live checks", F["small"], WHITE)
    paste_opacity(frame, panel, (1012 - 32, 330 - 32), 1.0)

    mx, my = 88, 842
    for value, label, color in [
        ("76", "live tracks", TEAL),
        ("127", "BPM", BLUE),
        ("8", "MCP tools", PURPLE),
        ("14", "resources", GREEN),
        ("1256", "Swift tests", GREEN),
        ("293", "strict live", AMBER),
    ]:
        draw_metric(d, mx, my, value, label, color)
        mx += 248
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
    render_frame(8.4).resize((1280, 720), Image.Resampling.LANCZOS).save(OUT_THUMB, optimize=True)

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
