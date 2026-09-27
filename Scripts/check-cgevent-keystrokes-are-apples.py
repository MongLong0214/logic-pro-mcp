#!/usr/bin/env python3
"""Every keystroke `CGEventChannel.keyMap` posts must be the one Apple's U.S. preset binds to that op.

WHY THIS EXISTS (#1029)
-----------------------
The CGEvent channel is the last rung of most routing chains: when it is reached it presses a key
in Logic and reports that it did. The table was hand-typed, several entries carried the comment
`(approximate)`, and nothing compared it with anything. Re-joined against Apple's Logic Pro User
Guide on 2026-09-27, entries pressed a key Apple binds to a DIFFERENT command, among them:

    transport.stop           Space      is Play or Stop -- it starts playback when stopped
    transport.rewind         Left       selects the previous region
    view.toggle_score_editor Opt-Cmd-P  creates a Session Player track
    project.close            Cmd-W      closes a window, not the project
    edit.quantize            /          opens Go to Position
    track.create_drummer     Opt-Cmd-Z  toggles individual track zoom

and others stood for a function Apple's tables give no default at all. A fallback that changes the
wrong state is worse than none, so an op whose function has no default in Apple's table carries no
keystroke: the channel then answers that no shortcut is mapped, which is true.

WHAT IT READS
-------------
- the `keyMap` literal and the `Shortcut` constructors in CGEventChannel.swift; each constructor's
  flags are read from its body, not assumed from its name;
- Apple's tables pinned under docs/canon/web/logicpro-key-commands/, whose SOURCE.json records the
  URL, the fetch date and the digest of every table file. The digest is re-derived before a row is
  read, so an edited table is refused rather than trusted.

`JOIN` below is the only place that says which Apple function an op performs. `KEYS` and
`KEYPAD_KEYS` are the only place that says which physical key Apple's key name is.

THE KEYBOARD LAYOUT, STATED ONCE
--------------------------------
Apple's table names keys as printed on a U.S. keyboard ("Comma (,)", "Slash (/)") and every page
pinned says it lists "the U.S. default preset". A CGEvent keycode is a PHYSICAL key position:
the values below are HIToolbox's kVK_* constants, which Events.h defines "according to the key
position on an ANSI-standard US keyboard" (values checked against the macOS SDK header on
2026-09-27). On any other layout the same keycode is the same key position, which may print a
different character, and Logic binds its commands by what that layout's preset says. Nothing here
models that; it is a limit, not a claim.

`𝍖` marks a numeric-keypad key in Apple's table. Logic tells keypad digits from the main row
("Go to Marker Number 1 | 𝍖 1"), so a keypad row must be posted as the keypad key with
`.maskNumericPad`, the flag hardware sets for it.

Exit: 0 = every keystroke is Apple's - 1 = one is not, or something could not be read
"""
import hashlib
import html
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
#: Seams, so the self-test can drive main() -- the entry point -- at a tree that must fail.
SWIFT = os.environ.get("LPM_CGEVENT_SWIFT") or os.path.join(
    REPO, "Sources", "LogicProMCP", "Channels", "CGEventChannel.swift")
CANON = os.environ.get("LPM_KEYCMD_CANON") or os.path.join(
    REPO, "docs", "canon", "web", "logicpro-key-commands")

#: op -> (pinned page, Apple's Function cell). The judgement of which function an op performs.
JOIN = {
    "transport.play": ("global-commands", "Play"),
    "transport.stop": ("global-commands", "Stop"),
    "transport.record": ("global-commands", "Record"),
    "transport.pause": ("global-commands", "Pause"),
    "transport.rewind": ("global-commands", "Rewind"),
    # `Forward | Period`, the counterpart of `Rewind | Comma` and of the control bar's Forward
    # button. `Fast Forward | Shift-Period` is a different command in the same table.
    "transport.fast_forward": ("global-commands", "Forward"),
    "transport.toggle_cycle": ("global-commands", "Toggle Cycle Mode"),
    "transport.toggle_metronome": ("global-commands", "Toggle Metronome Click"),
    "transport.goto_position": ("global-commands", "Go to Position"),
    "edit.undo": ("various-windows", "Undo"),
    "edit.redo": ("various-windows", "Redo"),
    "edit.cut": ("various-windows", "Cut"),
    "edit.copy": ("various-windows", "Copy"),
    "edit.paste": ("various-windows", "Paste"),
    "edit.select_all": ("various-windows", "Select All"),
    "edit.split": ("main-window-tracks-and-various-editors", "Split Regions/Events at Playhead Position"),
    "edit.join": ("main-window-tracks-and-various-editors", "Join Regions/Notes"),
    "edit.quantize": ("main-window-tracks-and-various-editors", "Quantize Selected Regions/Cells/Events"),
    # The op acts on the selection; `Bounce Tracks in Place | Control-Command-B` is the track form.
    "edit.bounce_in_place": ("main-window-tracks", "Bounce Regions/Cells in Place"),
    "view.toggle_mixer": ("global-commands", "Show/Hide Mixer"),
    "view.toggle_piano_roll": ("global-commands", "Show/Hide Piano Roll"),
    "view.toggle_library": ("global-commands", "Show/Hide Library"),
    "view.toggle_score_editor": ("global-commands", "Show/Hide Score Editor"),
    "project.save": ("global-commands", "Save"),
    "project.close": ("global-commands", "Close Project"),
    "track.create_audio": ("main-window-tracks-and-various-editors", "New Audio Track"),
    "track.create_instrument": ("main-window-tracks-and-various-editors", "New Software Instrument Track"),
    "track.duplicate": ("main-window-tracks-and-various-editors", "New Track with Duplicate Settings"),
    "track.delete": ("main-window-tracks-and-various-editors", "Delete Track"),
    "nav.zoom_to_fit": ("various-windows", "Toggle Zoom to Fit Selection or All Contents"),
    "automation.toggle_view": ("main-window-tracks-and-various-editors", "Show/Hide Automation"),
}

#: Apple's key name (parenthetical glyph removed) -> kVK_* keycode, main keyboard. US ANSI.
KEYS = {
    "A": 0x00, "S": 0x01, "D": 0x02, "F": 0x03, "H": 0x04, "G": 0x05, "Z": 0x06, "X": 0x07,
    "C": 0x08, "V": 0x09, "B": 0x0B, "Q": 0x0C, "W": 0x0D, "E": 0x0E, "R": 0x0F, "Y": 0x10,
    "T": 0x11, "O": 0x1F, "U": 0x20, "I": 0x22, "P": 0x23, "L": 0x25, "J": 0x26, "K": 0x28,
    "N": 0x2D, "M": 0x2E,
    "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19, "7": 0x1A,
    "8": 0x1C, "0": 0x1D,
    "Equal Sign": 0x18, "Hyphen": 0x1B, "Right Bracket": 0x1E, "Left Bracket": 0x21,
    "Apostrophe": 0x27, "Semicolon": 0x29, "Backslash": 0x2A, "Comma": 0x2B, "Slash": 0x2C,
    "Period": 0x2F, "Grave Accent": 0x32,
    "Return": 0x24, "Tab": 0x30, "Space bar": 0x31, "Delete": 0x33,
    "Home": 0x73, "Page Up": 0x74, "Forward Delete": 0x75, "End": 0x77, "Page Down": 0x79,
    "Left Arrow": 0x7B, "Right Arrow": 0x7C, "Down Arrow": 0x7D, "Up Arrow": 0x7E,
}
#: The same for a row marked `𝍖` (numeric keypad).
KEYPAD_KEYS = {
    "Period": 0x41, "Asterisk": 0x43, "Slash": 0x4B, "Enter": 0x4C, "Equal Sign": 0x51,
    "0": 0x52, "1": 0x53, "2": 0x54, "3": 0x55, "4": 0x56, "5": 0x57, "6": 0x58, "7": 0x59,
    "8": 0x5B, "9": 0x5C,
}
MODIFIERS = {"Command": "command", "Shift": "shift", "Option": "option", "Control": "control"}
FLAGS = {".maskCommand": "command", ".maskShift": "shift", ".maskAlternate": "option",
         ".maskControl": "control", ".maskNumericPad": "keypad"}
KEYPAD_MARK = "\U0001D356"

_KEYMAP = re.compile(r"static let keyMap: \[String: Shortcut\] = \[\n(.*?)\n\s*\]\n", re.S)
_ENTRY = re.compile(r'\s*"([a-z_]+\.[a-z_]+)":\s*\.([A-Za-z]+)\((\d+)\),\s*(?://.*)?')
_CTOR = re.compile(
    r"static func ([A-Za-z]+)\(_ code: CGKeyCode\) -> Shortcut \{\s*"
    r"Shortcut\(keyCode: code, flags: (\[[^\]]*\]|\.[A-Za-z]+)\)\s*\}")


def _text(cell: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", cell))).strip()


def load_tables(canon_dir: str, failures: list) -> dict:
    """page -> {function: [key command, ...]}, only from files whose digest SOURCE.json records."""
    try:
        with open(os.path.join(canon_dir, "SOURCE.json"), encoding="utf-8") as handle:
            source = json.load(handle)
        pages = source["pages"]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        failures.append(f"cannot read {canon_dir}/SOURCE.json: {exc}")
        return {}
    tables = {}
    for page, meta in sorted(pages.items()):
        path = os.path.join(canon_dir, str(meta.get("table_file", "")))
        try:
            with open(path, "rb") as handle:
                data = handle.read()
        except OSError as exc:
            failures.append(f"{page}: cannot read the pinned table: {exc}")
            continue
        if hashlib.sha256(data).hexdigest() != meta.get("table_sha256"):
            failures.append(f"{page}: {os.path.basename(path)} is not the bytes SOURCE.json pinned "
                            f"(sha256 differs); re-cut it from a capture and record the new digest")
            continue
        rows = {}
        body = 0
        for tr in re.findall(r"<tr>(.*?)</tr>", data.decode("utf-8"), re.S):
            if "<th" in tr:
                continue
            cells = [_text(c) for c in re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)]
            if len(cells) != 2:
                failures.append(f"{page}: a row with {len(cells)} cells, not Function | Key command")
                continue
            body += 1
            rows.setdefault(cells[0], []).append(cells[1])
        if body != meta.get("body_rows"):
            failures.append(f"{page}: {body} rows read, SOURCE.json says {meta.get('body_rows')}")
        tables[page] = rows
    return tables


def apple_keystroke(text: str):
    """`Option-Command-W` -> (13, {"option", "command"}); None when this table cannot express it."""
    keypad = text.startswith(KEYPAD_MARK)
    if keypad:
        text = text[len(KEYPAD_MARK):].strip()
    text = re.sub(r"\s*\([^()]*\)$", "", text)
    *mods, key = text.split("-")
    if any(m not in MODIFIERS for m in mods):
        return None
    code = (KEYPAD_KEYS if keypad else KEYS).get(key)
    if code is None:
        return None
    flags = {MODIFIERS[m] for m in mods} | ({"keypad"} if keypad else set())
    return code, flags


def parse_constructors(source: str, failures: list) -> dict:
    ctors = {}
    for name, flags in _CTOR.findall(source):
        tokens = [t.strip() for t in flags.strip("[]").split(",") if t.strip()]
        unknown = [t for t in tokens if t not in FLAGS]
        if unknown:
            failures.append(f"Shortcut.{name} sets {unknown}, which this guard cannot compare")
            continue
        ctors[name] = {FLAGS[t] for t in tokens}
    if not ctors:
        failures.append("no Shortcut constructor could be read from the Swift source")
    return ctors


def parse_keymap(source: str, failures: list) -> dict:
    block = _KEYMAP.search(source)
    if not block:
        failures.append("the `static let keyMap: [String: Shortcut] = [ ... ]` literal was not found")
        return {}
    entries = {}
    for line in block.group(1).split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith("//"):
            continue
        match = _ENTRY.fullmatch(line)
        if not match:
            failures.append(f"a keyMap line this guard cannot read, refused rather than skipped: {stripped}")
            continue
        op, ctor, code = match.group(1), match.group(2), int(match.group(3))
        if op in entries:
            failures.append(f"{op} appears twice in keyMap")
        entries[op] = (ctor, code)
    return entries


def check(source: str, canon_dir: str) -> list:
    failures = []
    tables = load_tables(canon_dir, failures)
    ctors = parse_constructors(source, failures)
    entries = parse_keymap(source, failures)
    for op, (ctor, code) in sorted(entries.items()):
        if ctor not in ctors:
            failures.append(f"{op}: .{ctor}(...) is not a Shortcut constructor this guard could read")
            continue
        if op not in JOIN:
            failures.append(f"{op} posts a keystroke but names no Apple row. Add its (page, function) "
                            f"to JOIN if Apple's U.S. preset has a default for it; otherwise remove "
                            f"the keystroke -- a wrong fallback is worse than none")
            continue
        page, function = JOIN[op]
        if page not in tables:
            failures.append(f"{op}: page {page!r} is not pinned in {os.path.relpath(canon_dir, REPO)}")
            continue
        cells = tables[page].get(function, [])
        if len(cells) != 1:
            failures.append(f"{op}: {page} has {len(cells)} rows named {function!r}, not exactly one")
            continue
        expected = apple_keystroke(cells[0])
        if expected is None:
            failures.append(f"{op}: Apple's {function!r} | {cells[0]!r} is a key this table cannot express")
            continue
        actual = (code, ctors[ctor])
        if actual != expected:
            failures.append(f"{op}: posts keycode {code} with {sorted(ctors[ctor])}, but Apple's "
                            f"{page} row reads {function!r} | {cells[0]!r} = keycode {expected[0]} "
                            f"with {sorted(expected[1])}")
    for op in sorted(set(JOIN) - set(entries)):
        failures.append(f"JOIN names {op}, which keyMap no longer has; remove the stale row")
    return failures


def main() -> int:
    with open(SWIFT, encoding="utf-8") as handle:
        source = handle.read()
    failures = check(source, CANON)
    if failures:
        print(f"{len(failures)} CGEvent keystroke(s) are not Apple's:", file=sys.stderr)
        for failure in failures[:40]:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"cgevent keystrokes are Apple's: {len(JOIN)} ops, each its function's U.S. default "
          f"preset binding on a pinned page whose digest matches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
