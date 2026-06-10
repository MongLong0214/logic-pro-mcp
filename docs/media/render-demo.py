#!/usr/bin/env python3
"""Render the README product walkthrough media.

The previous README video optimized for atmosphere and did not answer the
buyer's first questions. This renderer treats the GIF/MP4 as a compact product
walkthrough: what it is, how it connects, what it controls, why it is safer than
macros, and what proof exists.

The Logic Pro screenshot is a locked still. Only overlays animate so the demo
cannot introduce camera pan, crop drift, or UI wobble.
"""

from __future__ import annotations

import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
BG_PATH = ROOT / "artifacts/acid-track-composition/logic-after-feeder-finished.png"
OUT_MP4 = ROOT / "docs/media/logic-pro-mcp-demo.mp4"
OUT_GIF = ROOT / "docs/media/logic-pro-mcp-demo.gif"
OUT_THUMB = ROOT / "docs/media/logic-pro-mcp-thumbnail.png"

W, H = 1920, 1080
FPS = 24
GIF_FPS = 12
DURATION = 34.0
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
    "brand": load_font(48, bold=True),
    "hero": load_font(66, bold=True),
    "headline": load_font(54, bold=True),
    "title": load_font(38, bold=True),
    "body": load_font(30),
    "small": load_font(24),
    "tiny": load_font(20),
    "mono": load_font(25, mono=True),
    "mono_small": load_font(22, mono=True),
    "metric": load_font(58, bold=True),
    "metric_label": load_font(22, bold=True),
}

WHITE = (248, 251, 255)
INK = (5, 10, 18)
MUTED = (196, 207, 222)
SUBTLE = (143, 158, 178)
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
TEMPO_BOX = (884, 63, 1166, 126)


@dataclass(frozen=True)
class Scene:
    start: float
    end: float
    label: str


SCENES = [
    Scene(0.0, 4.2, "What it is"),
    Scene(4.2, 10.0, "Connect"),
    Scene(10.0, 16.7, "Control"),
    Scene(16.7, 23.2, "Safety"),
    Scene(23.2, 29.0, "Readback"),
    Scene(29.0, 34.0, "Proof"),
]


def clamp(value: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, value))


def smoothstep(value: float) -> float:
    value = clamp(value)
    return value * value * (3 - 2 * value)


def scene_opacity(t: float, start: float, end: float, fade: float = 0.45) -> float:
    return smoothstep((t - start) / fade) * (1 - smoothstep((t - (end - fade)) / fade))


def rgba(color: tuple[int, int, int], opacity: float) -> tuple[int, int, int, int]:
    return (*color, int(255 * clamp(opacity)))


def with_alpha(color: tuple[int, ...], opacity: float) -> tuple[int, int, int, int]:
    if len(color) == 4:
        return (*color[:3], int(color[3] * clamp(opacity)))
    return (*color, int(255 * clamp(opacity)))


def text_bbox(draw: ImageDraw.ImageDraw, text: str, face: ImageFont.FreeTypeFont) -> tuple[int, int, int, int]:
    return draw.textbbox((0, 0), text, font=face)


def text_size(draw: ImageDraw.ImageDraw, text: str, face: ImageFont.FreeTypeFont) -> tuple[int, int]:
    box = text_bbox(draw, text, face)
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


def wrap_text(draw: ImageDraw.ImageDraw, value: str, face: ImageFont.FreeTypeFont, max_width: int) -> list[str]:
    words = value.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = word if not current else f"{current} {word}"
        if text_size(draw, candidate, face)[0] <= max_width:
            current = candidate
            continue
        if current:
            lines.append(current)
        current = word
    if current:
        lines.append(current)
    return lines


def draw_wrapped(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int],
    value: str,
    face: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int] = MUTED,
    opacity: float = 1.0,
    *,
    max_width: int,
    line_gap: int = 12,
) -> int:
    x, y = xy
    line_h = text_size(draw, "Ag", face)[1] + line_gap
    for line in wrap_text(draw, value, face, max_width):
        draw_text(draw, (x, y), line, face, fill, opacity)
        y += line_h
    return y


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


def make_base() -> Image.Image:
    bg = Image.open(BG_PATH).convert("RGB").resize((W, H), Image.Resampling.LANCZOS).convert("RGBA")
    base = Image.alpha_composite(bg, Image.new("RGBA", (W, H), (0, 0, 0, 76)))

    gradient = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    px = gradient.load()
    for y in range(H):
        top = int(104 * max(0, 1 - y / 260))
        bottom = int(170 * max(0, (y - 520) / (H - 520)))
        side = 0
        alpha = max(top, bottom, side)
        if alpha:
            for x in range(W):
                horizontal = int(58 * max(0, 1 - x / 520))
                px[x, y] = (0, 0, 0, max(alpha, horizontal))

    vignette = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    vd = ImageDraw.Draw(vignette)
    for i in range(72):
        vd.rounded_rectangle((i * 2, i * 2, W - i * 2, H - i * 2), radius=18, outline=(0, 0, 0, int(i * 0.55)), width=2)
    return Image.alpha_composite(Image.alpha_composite(base, gradient), vignette)


BASE = make_base()


def draw_locked_background_note(frame: Image.Image, t: float) -> None:
    d = ImageDraw.Draw(frame)
    op = 0.82
    d.rounded_rectangle((1500, 36, 1844, 86), radius=25, fill=(5, 11, 20, int(210 * op)), outline=(77, 101, 126, int(130 * op)), width=1)
    d.ellipse((1523, 54, 1541, 72), fill=rgba(TEAL, op))
    draw_text(d, (1554, 51), "fixed Logic Pro frame", F["small"], WHITE, op)


def draw_header(frame: Image.Image, t: float) -> None:
    d = ImageDraw.Draw(frame)
    draw_text(d, (66, 42), "Logic Pro MCP", F["brand"], WHITE, 1.0, shadow=True)
    draw_text(d, (68, 97), "MCP server for agent-controlled Logic Pro sessions", F["small"], MUTED, 1.0)
    draw_locked_background_note(frame, t)


def draw_scene_nav(frame: Image.Image, t: float) -> None:
    d = ImageDraw.Draw(frame)
    x0, y = 92, 1006
    w = 1736
    d.rounded_rectangle((64, 960, 1856, 1046), radius=14, fill=(5, 12, 23, 222), outline=(78, 102, 131, 112), width=1)
    d.line((x0, y, x0 + w, y), fill=(89, 117, 150, 150), width=4)
    progress = clamp(t / DURATION)
    d.line((x0, y, x0 + w * progress, y), fill=rgba(TEAL, 0.95), width=7)
    for scene in SCENES:
        sx = x0 + w * (scene.start / DURATION)
        active = 0.55 + 0.45 * clamp((t - scene.start) / 0.45) * (1 - 0.5 * clamp((t - scene.end) / 0.45))
        color = TEAL if scene.start <= t < scene.end else BLUE
        d.ellipse((sx - 9, y - 9, sx + 9, y + 9), fill=rgba(color, active), outline=rgba(WHITE, 0.2), width=1)
        draw_text(d, (sx + 18, y - 35), scene.label, F["tiny"], MUTED if scene.start > t else WHITE, active)


def draw_callout_rect(frame: Image.Image, box: tuple[int, int, int, int], color: tuple[int, int, int], opacity: float) -> None:
    if opacity <= 0:
        return
    d = ImageDraw.Draw(frame)
    x0, y0, x1, y1 = box
    for i in range(5):
        d.rounded_rectangle(
            (x0 - i * 5, y0 - i * 5, x1 + i * 5, y1 + i * 5),
            radius=12 + i * 2,
            outline=rgba(color, opacity * (0.35 - i * 0.05)),
            width=3,
        )
    d.rounded_rectangle((x0, y0, x1, y1), radius=10, outline=rgba(color, 0.85 * opacity), width=3)


def draw_intro(frame: Image.Image, t: float) -> None:
    op = scene_opacity(t, 0.0, 4.2)
    if op <= 0:
        return
    d = ImageDraw.Draw(frame)
    x, y, w, h = 92, 222, 846, 520
    layer = panel_layer((w, h), fill=(4, 10, 19, 238), outline=(76, 112, 146, 136))
    ld = ImageDraw.Draw(layer)
    ox, oy = 32, 32
    pill(ld, ox + 32, oy + 30, "README WALKTHROUGH", TEAL, 1)
    draw_text(ld, (ox + 32, oy + 95), "What this is", F["headline"], WHITE, 1, shadow=True)
    next_y = draw_wrapped(
        ld,
        (ox + 34, oy + 178),
        "Claude, Cursor, or any MCP client gets typed tools for Logic actions and read resources for session state.",
        F["body"],
        MUTED,
        1,
        max_width=w - 92,
        line_gap=12,
    )
    bullets = [
        ("8 write tools", "transport, tracks, mixer, MIDI, project", TEAL),
        ("14 read resources", "tracks, mixer, project, plugins", BLUE),
        ("Fail-closed safety", "confirmed, uncertain, failed", AMBER),
    ]
    yy = next_y + 32
    for title, body, color in bullets:
        ld.ellipse((ox + 36, yy + 7, ox + 52, yy + 23), fill=(*color, 230))
        draw_text(ld, (ox + 68, yy), title, F["small"], WHITE)
        draw_text(ld, (ox + 68, yy + 30), body, F["tiny"], SUBTLE)
        yy += 66
    paste_opacity(frame, layer, (x - 32, y - 32), op)

    draw_callout_rect(frame, ARRANGE_BOX, TEAL, op * 0.9)
    d.rounded_rectangle((1144, 212, 1532, 260), radius=24, fill=(5, 12, 23, int(224 * op)), outline=rgba(TEAL, 0.7 * op), width=1)
    d.ellipse((1170, 228, 1188, 246), fill=rgba(TEAL, op))
    draw_text(d, (1204, 223), "real Logic Pro project state", F["small"], WHITE, op)


def flow_node(layer: Image.Image, center: tuple[int, int], title: str, subtitle: str, color: tuple[int, int, int]) -> None:
    d = ImageDraw.Draw(layer)
    x, y = center
    d.rounded_rectangle((x - 132, y - 58, x + 132, y + 58), radius=18, fill=(9, 19, 34, 236), outline=rgba(color, 0.72), width=2)
    d.ellipse((x - 98, y - 20, x - 64, y + 14), fill=rgba(color, 0.95))
    draw_text(d, (x - 48, y - 27), title, F["small"], WHITE)
    draw_text(d, (x - 48, y + 7), subtitle, F["tiny"], SUBTLE)


def draw_connect(frame: Image.Image, t: float) -> None:
    op = scene_opacity(t, 4.2, 10.0)
    if op <= 0:
        return
    d = ImageDraw.Draw(frame)
    left = panel_layer((720, 610), fill=(4, 10, 19, 240), outline=(78, 111, 145, 134))
    ld = ImageDraw.Draw(left)
    ox, oy = 32, 32
    pill(ld, ox + 30, oy + 28, "1. CONNECT", BLUE)
    draw_text(ld, (ox + 30, oy + 92), "Two commands, then permissions", F["title"], WHITE, shadow=True)
    commands = [
        "brew tap MongLong0214/logic-pro-mcp",
        "brew install logic-pro-mcp",
        "claude mcp add --scope user logic-pro --",
        "  LogicProMCP",
    ]
    code_y = oy + 158
    ld.rounded_rectangle((ox + 28, code_y, ox + 660, code_y + 194), radius=14, fill=(1, 7, 14, 235), outline=(73, 103, 136, 118), width=1)
    for i, line in enumerate(commands):
        prefix = "$ " if i < 3 else "  "
        draw_text(ld, (ox + 52, code_y + 28 + i * 42), f"{prefix}{line}", F["mono_small"], TEAL if i >= 2 else WHITE)
    checklist_y = code_y + 222
    draw_text(ld, (ox + 30, checklist_y), "Runtime grants the server checks:", F["small"], MUTED)
    checks = [("Accessibility", TEAL), ("Automation", BLUE), ("CoreMIDI visibility", AMBER)]
    for i, (label, color) in enumerate(checks):
        yy = checklist_y + 48 + i * 44
        ld.rounded_rectangle((ox + 32, yy, ox + 64, yy + 32), radius=8, fill=rgba(color, 0.92))
        draw_text(ld, (ox + 41, yy + 4), "OK", F["tiny"], INK)
        draw_text(ld, (ox + 82, yy + 2), label, F["body"], WHITE)
    paste_opacity(frame, left, (88 - 32, 210 - 32), op)

    flow = Image.new("RGBA", (900, 400), (0, 0, 0, 0))
    fd = ImageDraw.Draw(flow)
    centers = [(170, 190), (450, 190), (730, 190)]
    for (x0, y0), (x1, y1) in zip(centers, centers[1:]):
        fd.line((x0 + 140, y0, x1 - 140, y1), fill=rgba(TEAL, 0.78), width=5)
        fd.polygon([(x1 - 150, y1 - 12), (x1 - 122, y1), (x1 - 150, y1 + 12)], fill=rgba(TEAL, 0.78))
    flow_node(flow, centers[0], "MCP client", "Claude / Cursor", TEAL)
    flow_node(flow, centers[1], "Swift server", "stdio MCP", BLUE)
    flow_node(flow, centers[2], "Logic Pro", "native channels", GREEN)
    draw_text(fd, (450, 294), "One typed interface hides seven macOS control channels.", F["small"], MUTED, anchor="ma")
    paste_opacity(frame, flow, (920, 374), op)


def draw_control(frame: Image.Image, t: float) -> None:
    op = scene_opacity(t, 10.0, 16.7)
    if op <= 0:
        return
    d = ImageDraw.Draw(frame)
    draw_callout_rect(frame, TEMPO_BOX, AMBER, op)
    draw_callout_rect(frame, TRACK_BOX, BLUE, op)
    draw_callout_rect(frame, ARRANGE_BOX, TEAL, op)
    d.rounded_rectangle((1068, 136, 1358, 184), radius=24, fill=(5, 12, 23, int(224 * op)), outline=rgba(AMBER, 0.7 * op), width=1)
    draw_text(d, (1092, 148), "tempo + project state", F["small"], WHITE, op)
    d.rounded_rectangle((456, 672, 756, 720), radius=24, fill=(5, 12, 23, int(224 * op)), outline=rgba(BLUE, 0.7 * op), width=1)
    draw_text(d, (480, 684), "tracks and instruments", F["small"], WHITE, op)
    d.rounded_rectangle((1320, 672, 1608, 720), radius=24, fill=(5, 12, 23, int(224 * op)), outline=rgba(TEAL, 0.7 * op), width=1)
    draw_text(d, (1344, 684), "MIDI regions created", F["small"], WHITE, op)

    panel = panel_layer((760, 620), fill=(4, 10, 19, 240), outline=(78, 111, 145, 134))
    pd = ImageDraw.Draw(panel)
    ox, oy = 32, 32
    pill(pd, ox + 28, oy + 28, "2. CONTROL", TEAL)
    draw_text(pd, (ox + 28, oy + 92), "The agent calls tools, not random clicks", F["title"], WHITE, shadow=True)
    prompt = '"Make a 4-bar techno loop in A minor at 140 BPM."'
    draw_wrapped(pd, (ox + 30, oy + 148), prompt, F["body"], MUTED, max_width=680)
    code_y = oy + 224
    pd.rounded_rectangle((ox + 28, code_y, ox + 704, code_y + 300), radius=14, fill=(1, 7, 14, 236), outline=(73, 103, 136, 118), width=1)
    code = [
        "logic_project.new(...)",
        "logic_tracks.record_sequence",
        "  tempo: 140   key: A minor   bars: 4",
        "logic_tracks.set_instrument -> Studio Grand",
        "logic_mixer.insert_plugin -> Gain",
        "  confirmation: true",
    ]
    for i, line in enumerate(code):
        color = TEAL if i in (0, 1, 3, 4) else MUTED
        draw_text(pd, (ox + 54, code_y + 28 + i * 42), line, F["mono_small"], color)
    paste_opacity(frame, panel, (92 - 32, 304 - 32), op)


def draw_safety_table(draw: ImageDraw.ImageDraw, x: int, y: int, rows: Sequence[tuple[str, str, str, tuple[int, int, int]]]) -> None:
    col = [x, x + 210, x + 470]
    draw_text(draw, (col[0], y), "Operation", F["eyebrow"], SUBTLE)
    draw_text(draw, (col[1], y), "Best channel", F["eyebrow"], SUBTLE)
    draw_text(draw, (col[2], y), "Guard", F["eyebrow"], SUBTLE)
    y += 44
    for operation, channel, guard, color in rows:
        draw.rounded_rectangle((x - 16, y - 12, x + 700, y + 42), radius=12, fill=(255, 255, 255, 10), outline=(255, 255, 255, 16), width=1)
        draw_text(draw, (col[0], y), operation, F["small"], WHITE)
        draw_text(draw, (col[1], y), channel, F["small"], color)
        draw_text(draw, (col[2], y), guard, F["small"], MUTED)
        y += 66


def draw_safety(frame: Image.Image, t: float) -> None:
    op = scene_opacity(t, 16.7, 23.2)
    if op <= 0:
        return
    panel = panel_layer((930, 630), fill=(4, 10, 19, 242), outline=(78, 111, 145, 134))
    d = ImageDraw.Draw(panel)
    ox, oy = 32, 32
    pill(d, ox + 30, oy + 28, "3. SAFETY", AMBER)
    draw_text(d, (ox + 30, oy + 92), "Different operation, different route", F["title"], WHITE, shadow=True)
    draw_wrapped(
        d,
        (ox + 32, oy + 145),
        "The server does not pretend one automation channel is reliable for everything. It routes each action to the strongest available macOS surface, then keeps failure explicit.",
        F["body"],
        MUTED,
        max_width=820,
        line_gap=10,
    )
    rows = [
        ("Transport", "CoreMIDI + AX", "live state readback", TEAL),
        ("MIDI regions", "SMF import", "/tmp import jail", BLUE),
        ("Mixer/plugin", "MCU + AX", "slot readback", AMBER),
        ("Project ops", "policy gate", "confirmation required", RED),
    ]
    draw_safety_table(d, ox + 42, oy + 256, rows)
    d.rounded_rectangle((ox + 30, oy + 555, ox + 870, oy + 602), radius=12, fill=rgba(RED, 0.14), outline=rgba(RED, 0.48), width=1)
    draw_text(d, (ox + 54, oy + 565), "Uncertain writes stay uncertain. They are not reported as success.", F["small"], WHITE)
    paste_opacity(frame, panel, (92 - 32, 266 - 32), op)

    meter = Image.new("RGBA", (520, 380), (0, 0, 0, 0))
    md = ImageDraw.Draw(meter)
    outcomes = [("confirmed", GREEN, 0.92), ("uncertain", AMBER, 0.58), ("failed", RED, 0.34)]
    for i, (label, color, length) in enumerate(outcomes):
        yy = 92 + i * 82
        md.rounded_rectangle((80, yy, 480, yy + 34), radius=17, fill=(7, 15, 28, 232), outline=(84, 112, 142, 120), width=1)
        md.rounded_rectangle((80, yy, 80 + int(400 * length), yy + 34), radius=17, fill=rgba(color, 0.9))
        draw_text(md, (80, yy - 34), label, F["small"], WHITE)
    draw_text(md, (280, 320), "Honest Contract envelope", F["small"], MUTED, anchor="ma")
    paste_opacity(frame, meter, (1220, 420), op)


def draw_readback(frame: Image.Image, t: float) -> None:
    op = scene_opacity(t, 23.2, 29.0)
    if op <= 0:
        return
    d = ImageDraw.Draw(frame)
    draw_callout_rect(frame, ARRANGE_BOX, GREEN, op * 0.8)
    panel = panel_layer((900, 610), fill=(4, 10, 19, 242), outline=(78, 111, 145, 134))
    pd = ImageDraw.Draw(panel)
    ox, oy = 32, 32
    pill(pd, ox + 30, oy + 28, "4. READBACK", GREEN)
    draw_text(pd, (ox + 30, oy + 92), "Read state before success", F["title"], WHITE, shadow=True)
    draw_wrapped(
        pd,
        (ox + 32, oy + 146),
        "Tools mutate. Resources read. Agents can inspect the Logic session after the action instead of trusting a prompt transcript.",
        F["body"],
        MUTED,
        max_width=810,
        line_gap=10,
    )
    code_y = oy + 238
    pd.rounded_rectangle((ox + 30, code_y, ox + 842, code_y + 300), radius=14, fill=(1, 7, 14, 236), outline=(73, 103, 136, 118), width=1)
    code = [
        "read logic://transport/state",
        "tempo: 140   cycle: true   source: ax_poll",
        "",
        "read logic://mixer/strip/2",
        "plugin: Gain   verified: true",
        "",
        "outcome: confirmed | uncertain | failed",
    ]
    for i, line in enumerate(code):
        if not line:
            continue
        color = TEAL if line.startswith("resources/read") else (GREEN if "outcome" in line else MUTED)
        draw_text(pd, (ox + 58, code_y + 26 + i * 38), line, F["mono_small"], color)
    paste_opacity(frame, panel, (92 - 32, 268 - 32), op)

    badges = Image.new("RGBA", (650, 230), (0, 0, 0, 0))
    bd = ImageDraw.Draw(badges)
    labels = [("logic://tracks", TEAL), ("logic://mixer", BLUE), ("logic://project/info", AMBER), ("logic://stock-plugins", PURPLE), ("logic://workflow-skills", GREEN)]
    x, y = 24, 30
    for label, color in labels:
        width = pill(bd, x, y, label, color, 1, fill_dark=True)
        x += width + 14
        if x > 430:
            x, y = 24, y + 58
    draw_text(bd, (330, 188), "read surfaces, not extra clicks", F["small"], MUTED, anchor="ma")
    paste_opacity(frame, badges, (1180, 650), op)


def draw_metric_card(draw: ImageDraw.ImageDraw, x: int, y: int, value: str, label: str, color: tuple[int, int, int], opacity: float) -> None:
    draw.rounded_rectangle((x, y, x + 214, y + 134), radius=16, fill=(8, 18, 32, int(226 * opacity)), outline=rgba(color, 0.65 * opacity), width=1)
    draw_text(draw, (x + 28, y + 24), value, F["metric"], color, opacity, shadow=True)
    draw_text(draw, (x + 30, y + 91), label, F["metric_label"], MUTED, opacity)


def draw_proof(frame: Image.Image, t: float) -> None:
    op = scene_opacity(t, 29.0, 34.0)
    if op <= 0:
        return
    d = ImageDraw.Draw(frame)
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.rectangle((0, 548, W, H), fill=(0, 0, 0, int(148 * op)))
    pill(ld, 92, 618, "5. PROOF", TEAL, op)
    draw_text(ld, (92, 680), "Agent-grade DAW control, with evidence attached", F["hero"], WHITE, op, shadow=True)
    draw_text(
        ld,
        (96, 768),
        "Use it when you want agents to compose, edit, mix, inspect, and stop honestly when Logic cannot be verified.",
        F["body"],
        MUTED,
        op,
    )
    metrics = [
        ("8", "MCP tools", TEAL),
        ("14", "resources", BLUE),
        ("7", "templates", PURPLE),
        ("1256", "Swift tests", GREEN),
        ("293", "strict live", AMBER),
    ]
    mx = 96
    for value, label, color in metrics:
        draw_metric_card(ld, mx, 836, value, label, color, op)
        mx += 236
    ld.rounded_rectangle((1410, 840, 1814, 966), radius=18, fill=(6, 14, 26, int(232 * op)), outline=rgba(TEAL, 0.58 * op), width=1)
    draw_text(ld, (1440, 866), "Stable install line", F["small"], SUBTLE, op)
    draw_text(ld, (1440, 904), "v3.4.6", F["headline"], TEAL, op, shadow=True)
    draw_text(ld, (1592, 919), "ADHOC universal", F["small"], WHITE, op)
    frame.alpha_composite(layer)


def render_frame(t: float) -> Image.Image:
    frame = BASE.copy()
    draw_header(frame, t)
    draw_intro(frame, t)
    draw_connect(frame, t)
    draw_control(frame, t)
    draw_safety(frame, t)
    draw_readback(frame, t)
    draw_proof(frame, t)
    draw_scene_nav(frame, t)
    return frame.convert("RGB")


def run(cmd: Sequence[str]) -> None:
    proc = subprocess.run(cmd, text=True, capture_output=True)
    if proc.returncode != 0:
        print(proc.stdout, file=sys.stderr)
        print(proc.stderr, file=sys.stderr)
        raise SystemExit(proc.returncode)


def render_video() -> None:
    OUT_THUMB.parent.mkdir(parents=True, exist_ok=True)
    render_frame(30.4).resize((1280, 720), Image.Resampling.LANCZOS).save(OUT_THUMB, optimize=True)

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
