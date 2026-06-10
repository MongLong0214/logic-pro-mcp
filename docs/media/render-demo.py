#!/usr/bin/env python3
"""Render the README demo media from a fixed Logic Pro screenshot.

The Logic Pro background is intentionally a still frame. Only overlays fade,
progress, or pulse so the README demo cannot appear to pan or wobble.
"""

from __future__ import annotations

import math
import os
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
BG_PATH = ROOT / "artifacts/acid-track-composition/logic-after-feeder-finished.png"
OUT_MP4 = ROOT / "docs/media/logic-pro-mcp-demo.mp4"
OUT_THUMB = ROOT / "docs/media/logic-pro-mcp-thumbnail.png"

W, H = 1920, 1080
FPS = 24
DURATION = 22.0
FRAMES = int(FPS * DURATION)

FONT = "/System/Library/Fonts/SFNS.ttf"
FONT_BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
FONT_MONO = "/System/Library/Fonts/SFNSMono.ttf"
if not os.path.exists(FONT_MONO):
    FONT_MONO = "/System/Library/Fonts/Monaco.ttf"


def font(size: int, *, bold: bool = False, mono: bool = False) -> ImageFont.FreeTypeFont:
    path = FONT_MONO if mono else (FONT_BOLD if bold and os.path.exists(FONT_BOLD) else FONT)
    return ImageFont.truetype(path, size)


FONTS = {
    "brand": font(62, bold=True),
    "hero": font(68, bold=True),
    "tag": font(31),
    "pill": font(22, bold=True),
    "title": font(47, bold=True),
    "body": font(31),
    "small": font(24),
    "tiny": font(19),
    "mono": font(27, mono=True),
    "mono_small": font(23, mono=True),
    "metric": font(48, bold=True),
    "metric_label": font(22),
}

WHITE = (246, 250, 255)
MUTED = (196, 207, 222)
SUBTLE = (143, 157, 176)
TEAL = (20, 224, 181)
BLUE = (83, 142, 255)
ORANGE = (255, 157, 34)
PURPLE = (163, 108, 255)
GREEN = (62, 232, 134)

REGION_BOX = (570, 252, 1906, 650)


def clamp(v: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, v))


def smoothstep(x: float) -> float:
    x = clamp(x)
    return x * x * (3 - 2 * x)


def inout(t: float, start: float, end: float, fade: float = 0.55) -> float:
    return smoothstep((t - start) / fade) * (1 - smoothstep((t - (end - fade)) / fade))


def ease_inout(x: float) -> float:
    x = clamp(x)
    return 0.5 - 0.5 * math.cos(math.pi * x)


def rgba(color: tuple[int, int, int], opacity: float) -> tuple[int, int, int, int]:
    return (*color, int(255 * clamp(opacity)))


def with_alpha(color: tuple[int, ...], opacity: float) -> tuple[int, int, int, int]:
    if len(color) == 4:
        return (*color[:3], int(color[3] * clamp(opacity)))
    return (*color, int(255 * clamp(opacity)))


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
    if shadow:
        draw.text((xy[0] + 2, xy[1] + 2), value, font=face, fill=(0, 0, 0, int(150 * opacity)), anchor=anchor)
    draw.text(xy, value, font=face, fill=with_alpha(fill, opacity), anchor=anchor)


def paste_opacity(dst: Image.Image, src: Image.Image, xy: tuple[int, int], opacity: float) -> None:
    if opacity <= 0:
        return
    if opacity >= 0.999:
        dst.alpha_composite(src, xy)
        return
    tmp = src.copy()
    tmp.putalpha(tmp.getchannel("A").point(lambda p: int(p * opacity)))
    dst.alpha_composite(tmp, xy)


def rounded_layer(
    size: tuple[int, int],
    radius: int,
    fill: tuple[int, int, int, int],
    outline: tuple[int, int, int, int],
) -> Image.Image:
    w, h = size
    layer = Image.new("RGBA", (w + 64, h + 64), (0, 0, 0, 0))
    shadow = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((32, 32, 32 + w, 32 + h), radius=radius, fill=(0, 0, 0, 122))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    layer = Image.alpha_composite(layer, shadow)
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((32, 32, 32 + w, 32 + h), radius=radius, fill=fill, outline=outline, width=1)
    d.rounded_rectangle((32, 32, 32 + w, 32 + h), radius=radius, outline=(255, 255, 255, 22), width=1)
    return layer


def pill(draw: ImageDraw.ImageDraw, x: int, y: int, label: str, color: tuple[int, int, int], opacity: float = 1.0) -> None:
    bbox = draw.textbbox((0, 0), label, font=FONTS["pill"])
    width = bbox[2] - bbox[0] + 34
    draw.rounded_rectangle((x, y, x + width, y + 33), radius=17, fill=rgba(color, 0.95 * opacity))
    draw_text(draw, (x + width / 2, y + 6), label, FONTS["pill"], (2, 9, 16), opacity, anchor="ma")


def chip(draw: ImageDraw.ImageDraw, x: int, y: int, label: str, color: tuple[int, int, int]) -> int:
    bbox = draw.textbbox((0, 0), label, font=FONTS["tiny"])
    width = bbox[2] - bbox[0] + 28
    draw.rounded_rectangle((x, y, x + width, y + 30), radius=15, fill=rgba(color, 0.86))
    draw_text(draw, (x + width / 2, y + 6), label, FONTS["tiny"], WHITE, 1, anchor="ma")
    return width


def make_base() -> Image.Image:
    bg = Image.open(BG_PATH).convert("RGB").resize((W, H), Image.Resampling.LANCZOS).convert("RGBA")
    base = Image.alpha_composite(bg, Image.new("RGBA", (W, H), (0, 0, 0, 36)))

    gradient = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    px = gradient.load()
    for y in range(H):
        alpha = 0
        if y < 175:
            alpha = max(alpha, int(74 * (1 - y / 175)))
        if y > 610:
            alpha = max(alpha, int(98 * ((y - 610) / (H - 610))))
        if alpha:
            for x in range(W):
                px[x, y] = (0, 0, 0, alpha)
    base = Image.alpha_composite(base, gradient)

    vignette = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    vd = ImageDraw.Draw(vignette)
    for i in range(90):
        vd.rounded_rectangle((i * 2, i * 2, W - i * 2, H - i * 2), radius=22, outline=(0, 0, 0, int(i * 0.42)), width=2)
    return Image.alpha_composite(base, vignette)


BASE = make_base()


def draw_header(frame: Image.Image, t: float) -> None:
    d = ImageDraw.Draw(frame)
    op = smoothstep(t / 0.7)
    draw_text(d, (66, 44), "Logic Pro MCP", FONTS["brand"], WHITE, op, shadow=True)
    draw_text(d, (492, 62), "verified agent control plane for Logic Pro", FONTS["tag"], MUTED, op)

    x, y, w, h = 1468, 36, 376, 58
    d.rounded_rectangle((x, y, x + w, y + h), radius=29, fill=(7, 16, 30, int(218 * op)), outline=(64, 89, 116, int(135 * op)), width=1)
    d.ellipse((x + 25, y + 19, x + 47, y + 41), fill=rgba(TEAL, op))
    draw_text(d, (x + 62, y + 16), "Live readback, not blind macros", FONTS["small"], WHITE, op)


def draw_region_highlight(frame: Image.Image, t: float) -> None:
    op = max(inout(t, 4.8, 10.4, 0.75), inout(t, 9.5, 15.0, 0.75))
    if op <= 0:
        return
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    x0, y0, x1, y1 = REGION_BOX
    for i in range(7):
        d.rounded_rectangle((x0 - i * 3, y0 - i * 3, x1 + i * 3, y1 + i * 3), radius=14 + i * 2, outline=(31, 238, 180, int(28 * op * (1 - i / 7))), width=3)
    d.rounded_rectangle((x0, y0, x1, y1), radius=12, outline=(41, 242, 190, int(155 * op)), width=3)
    call_x, call_y = 1140, 222
    d.rounded_rectangle((call_x, call_y, call_x + 390, call_y + 54), radius=27, fill=(7, 15, 27, int(210 * op)), outline=(52, 222, 178, int(130 * op)), width=1)
    d.ellipse((call_x + 22, call_y + 18, call_x + 40, call_y + 36), fill=rgba(TEAL, op))
    draw_text(d, (call_x + 54, call_y + 13), "MIDI regions created in Logic", FONTS["small"], WHITE, op)
    frame.alpha_composite(layer)


def draw_pipeline(frame: Image.Image, t: float) -> None:
    d = ImageDraw.Draw(frame)
    op = smoothstep((t - 1.0) / 0.7)
    x0, x1, y = 102, 1818, 1000
    d.rounded_rectangle((70, 948, 1850, 1042), radius=14, fill=(6, 13, 25, int(218 * op)), outline=(80, 107, 137, int(122 * op)), width=1)
    d.line((x0, y, x1, y), fill=(91, 118, 149, int(145 * op)), width=5)
    progress = ease_inout(t / DURATION)
    d.line((x0, y, x0 + (x1 - x0) * progress, y), fill=rgba(TEAL, 0.96 * op), width=7)
    nodes = [
        (205, "MCP client", TEAL),
        (635, "Swift server", TEAL),
        (1035, "ChannelRouter", BLUE),
        (1445, "Logic Pro", GREEN),
        (1692, "Readback", TEAL),
    ]
    for nx, label, color in nodes:
        active = 0.35 + 0.65 * clamp((progress * (x1 - x0) + x0 - (nx - 70)) / 140)
        d.ellipse((nx - 12, y - 12, nx + 12, y + 12), fill=rgba(color, op * active), outline=rgba(WHITE, 0.22 * op), width=1)
        draw_text(d, (nx + 20, y - 32), label, FONTS["small"], WHITE, op * active)


def draw_terminal(frame: Image.Image, t: float) -> None:
    op = inout(t, 1.8, 6.8, 0.7)
    if op <= 0:
        return
    x, y, w, h = 92, 646, 760, 250
    layer = rounded_layer((w, h), 20, (4, 10, 19, 232), (79, 108, 142, 120))
    d = ImageDraw.Draw(layer)
    ox, oy = 32, 32
    for i, color in enumerate([(255, 94, 86), (255, 189, 46), (39, 201, 63)]):
        d.ellipse((ox + 26 + i * 28, oy + 26, ox + 40 + i * 28, oy + 40), fill=(*color, 230))
    draw_text(d, (ox + 128, oy + 18), "mcp-client request", FONTS["small"], SUBTLE)
    lines = [
        ("> logic_tracks.record_sequence", TEAL),
        ("  tempo: 140     key: A minor", (219, 231, 244)),
        ("  bars: 4        pattern: acid-techno", (219, 231, 244)),
        ("  safety: require confirmed readback", ORANGE),
    ]
    for i, (line, color) in enumerate(lines):
        draw_text(d, (ox + 32, oy + 76 + i * 36), line, FONTS["mono"], color)
    paste_opacity(frame, layer, (x - 32, y - 32), op)


def draw_card(frame: Image.Image, t: float, spec: dict[str, object], opacity: float) -> None:
    if opacity <= 0:
        return
    x, y, w, h = spec["rect"]  # type: ignore[misc]
    layer = rounded_layer((w, h), 22, (6, 14, 27, 226), (91, 119, 151, 135))
    d = ImageDraw.Draw(layer)
    ox, oy = 32, 32
    pill(d, ox + 28, oy + 28, str(spec["pill"]), spec["accent"])  # type: ignore[arg-type]
    draw_text(d, (ox + 28, oy + 84), str(spec["title"]), FONTS["title"], WHITE, shadow=True)
    for i, line in enumerate(spec.get("body", [])):  # type: ignore[union-attr]
        draw_text(d, (ox + 30, oy + 146 + i * 38), str(line), FONTS["body"], MUTED)
    chips = spec.get("chips")  # type: ignore[union-attr]
    if chips:
        cx, cy = ox + 28, oy + h - 54
        for label, color in chips:  # type: ignore[union-attr]
            cx += chip(d, cx, cy, label, color) + 12
    paste_opacity(frame, layer, (x - 32, y - 32), opacity)


def draw_readout(frame: Image.Image, t: float) -> None:
    op = inout(t, 10.0, 15.6, 0.65)
    if op <= 0:
        return
    x, y, w, h = 104, 650, 610, 246
    layer = rounded_layer((w, h), 20, (4, 10, 18, 230), (79, 108, 142, 118))
    d = ImageDraw.Draw(layer)
    ox, oy = 32, 32
    draw_text(d, (ox + 28, oy + 24), "readback", FONTS["small"], SUBTLE)
    rows = [
        ("track_count", "7", TEAL),
        ("tempo", "140 BPM", BLUE),
        ("source", "AX poll + CoreMIDI", ORANGE),
        ("outcome", "confirmed", GREEN),
    ]
    for i, (key, value, color) in enumerate(rows):
        yy = oy + 66 + i * 40
        draw_text(d, (ox + 30, yy), key, FONTS["mono_small"], SUBTLE)
        draw_text(d, (ox + 230, yy), value, FONTS["mono_small"], color)
    paste_opacity(frame, layer, (x - 32, y - 32), op)


def draw_final(frame: Image.Image, t: float) -> None:
    op = inout(t, 18.0, 22.1, 0.7)
    if op <= 0:
        return
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rectangle((0, 598, W, H), fill=(0, 0, 0, int(100 * op)))
    draw_text(d, (104, 678), "Compose. Control. Verify.", FONTS["hero"], WHITE, op, shadow=True)
    draw_text(d, (108, 766), "Logic Pro MCP turns DAW automation into structured agent operations with live state and provenance.", FONTS["tag"], MUTED, op)
    metrics = [("8", "tools", TEAL), ("14", "resources", BLUE), ("7", "templates", PURPLE), ("293", "strict-live checks", GREEN)]
    mx, my = 108, 842
    for value, label, color in metrics:
        draw_text(d, (mx, my), value, FONTS["metric"], color, op, shadow=True)
        draw_text(d, (mx, my + 53), label, FONTS["metric_label"], MUTED, op)
        mx += 230
    frame.alpha_composite(layer)


CARDS = [
    {
        "rect": (884, 636, 890, 286),
        "pill": "ROUTE",
        "accent": BLUE,
        "title": "The server chooses the right channel",
        "body": [
            "ChannelRouter balances CoreMIDI, AX, AppleScript,",
            "CGEvent, Scripter, MCU, and key commands.",
            "Uncertain writes fail closed instead of pretending.",
        ],
    },
    {
        "rect": (824, 618, 948, 304),
        "pill": "VERIFY",
        "accent": ORANGE,
        "title": "Readback closes the loop",
        "body": [
            "Every critical result carries a source label:",
            "confirmed / uncertain / failed",
            "so agents can trust the session state.",
        ],
        "chips": [("MCU", TEAL), ("AX", (82, 112, 147)), ("CoreMIDI", BLUE), ("AppleScript", ORANGE)],
    },
    {
        "rect": (778, 624, 995, 298),
        "pill": "CONTROL PLANE",
        "accent": TEAL,
        "title": "Not screen macros. Agent-grade DAW state.",
        "body": [
            "Tools mutate. Resources read. Evidence stays labeled.",
            "A Logic Pro session becomes inspectable, routable,",
            "and safer for Claude, Cursor, or any MCP client.",
        ],
    },
]


def render_frame(t: float) -> Image.Image:
    frame = BASE.copy()
    draw_header(frame, t)
    draw_region_highlight(frame, t)
    draw_terminal(frame, t)
    draw_card(frame, t, CARDS[0], inout(t, 5.8, 10.6, 0.65))
    draw_card(frame, t, CARDS[1], inout(t, 9.8, 15.4, 0.65))
    draw_readout(frame, t)
    draw_card(frame, t, CARDS[2], inout(t, 14.4, 17.5, 0.65))
    draw_final(frame, t)
    draw_pipeline(frame, t)
    return frame.convert("RGB")


def render_video() -> None:
    OUT_THUMB.parent.mkdir(parents=True, exist_ok=True)
    render_frame(12.4).resize((1280, 720), Image.Resampling.LANCZOS).save(OUT_THUMB, optimize=True)

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
    print(f"rendered {OUT_MP4} frames={FRAMES} fps={FPS} duration={DURATION}s")
    print(f"thumbnail {OUT_THUMB}")


if __name__ == "__main__":
    render_video()
