#!/usr/bin/env python3
"""
Analysis → Logic Pro Session Bootstrap

Takes an audio-analysis output folder and prepares a Logic Pro session:
- Launches / connects to Logic Pro via the MCP server
- Sets BPM from analysis.json
- Creates one audio track per stem (named + selected)
- Invokes `open` on each stem WAV so Logic imports it to the current project
- Prints a session brief (key, LUFS, preset hints) for continued production

Usage:
    python3 analysis-to-logic.py /path/to/analysis/folder
    python3 analysis-to-logic.py /path/to/analysis/folder --bounce-target -14
    python3 analysis-to-logic.py /path/to/analysis/folder --no-import  # prep only
"""

import json
import subprocess
import sys
import time
import threading
import argparse
from pathlib import Path

BINARY_CANDIDATES = [
    "/Users/isaac/bin/LogicProMCP",
    "/usr/local/bin/LogicProMCP",
    str(Path(__file__).resolve().parents[1] / ".build/release/LogicProMCP"),
    str(Path(__file__).resolve().parents[1] / ".build/debug/LogicProMCP"),
]

# ── MCP stdio client ─────────────────────────────────────────────────

class MCP:
    def __init__(self, binary):
        self.p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=open("/tmp/a2l-mcp.err", "w"), bufsize=0)
        self.r = {}
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        try:
            for line in self.p.stdout:
                try:
                    m = json.loads(line.decode().strip())
                    if "id" in m and m["id"] is not None:
                        self.r[m["id"]] = m
                except json.JSONDecodeError:
                    pass
        except Exception:
            pass

    def send(self, msg, timeout=15):
        try:
            self.p.stdin.write((json.dumps(msg) + "\n").encode())
            self.p.stdin.flush()
        except BrokenPipeError:
            return None
        if "id" not in msg:
            return None
        deadline = time.time() + timeout
        while time.time() < deadline:
            if msg["id"] in self.r:
                return self.r.pop(msg["id"])
            time.sleep(0.03)
        return None

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=3)
        except Exception:
            self.p.kill()


_ID = [0]
def nid():
    _ID[0] += 1; return _ID[0]

def init(mcp):
    r = mcp.send({
        "jsonrpc": "2.0", "id": nid(), "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                   "clientInfo": {"name": "a2l", "version": "1"}}
    })
    if not r or "result" not in r:
        return False
    mcp.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    time.sleep(2.5)
    return True

def tool(mcp, name, cmd, params=None):
    args = {"command": cmd}
    if params:
        args["params"] = params
    r = mcp.send({"jsonrpc": "2.0", "id": nid(), "method": "tools/call",
                  "params": {"name": name, "arguments": args}})
    if not r:
        return "(timeout)", True
    try:
        return r["result"]["content"][0]["text"], r["result"].get("isError", False)
    except Exception:
        return str(r), True

def res(mcp, uri):
    r = mcp.send({"jsonrpc": "2.0", "id": nid(), "method": "resources/read",
                  "params": {"uri": uri}})
    try:
        return r["result"]["contents"][0]["text"]
    except Exception:
        return "(no content)"

# ── utilities ────────────────────────────────────────────────────────

def find_binary():
    for b in BINARY_CANDIDATES:
        if Path(b).is_file():
            return b
    return None

def c(color, text):
    codes = {"green": "32", "red": "31", "yellow": "33", "blue": "34", "cyan": "36", "dim": "2"}
    return f"\033[0;{codes.get(color, '0')}m{text}\033[0m"

def banner(title):
    print()
    print("═" * 72)
    print(f"  {title}")
    print("═" * 72)

def ensure_logic_running():
    """Ensure Logic Pro is running. Launch if not."""
    try:
        pgrep = subprocess.run(["pgrep", "-x", "Logic Pro"], capture_output=True, text=True)
        if pgrep.returncode != 0:
            print(c("yellow", "  Logic Pro is not running — launching..."))
            subprocess.run(["open", "-a", "Logic Pro"], check=True)
            for _ in range(30):
                time.sleep(1)
                if subprocess.run(["pgrep", "-x", "Logic Pro"],
                                  capture_output=True).returncode == 0:
                    time.sleep(3)  # let it finish loading
                    return True
            return False
        return True
    except Exception as e:
        print(c("red", f"  Failed to check/launch Logic Pro: {e}"))
        return False

def activate_logic():
    subprocess.run(["osascript", "-e",
                    'tell application "Logic Pro" to activate'],
                   capture_output=True)

def logic_front_window_title() -> str:
    """Read Logic Pro's front window title. Empty if no window/project."""
    r = subprocess.run([
        "osascript", "-e",
        'tell application "System Events" to tell process "Logic Pro" '
        'to get title of front window'
    ], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def logic_has_loaded_project() -> bool:
    """True iff a real project is loaded (not the template chooser)."""
    title = logic_front_window_title()
    if not title:
        return False
    # Template chooser is titled "Project Chooser" / "프로젝트 선택기" / "Templates"
    lowered = title.lower()
    chooser_markers = ("project chooser", "프로젝트 선택", "templates", "template chooser",
                       "choose a project", "새로운 프로젝트")
    if any(m in lowered for m in chooser_markers):
        return False
    return True


def import_audio_file_via_ui(path: Path) -> bool:
    """Invoke File → Import → Audio File… by clicking the menu item directly.

    Works in both Korean (`파일 → 가져오기 → 오디오 파일…`) and
    English (`File → Import → Audio File…`) Logic Pro.

    Sequence:
      1. Click menu: File > Import > Audio File…
      2. ⇧⌘G → 'Go to Folder' prompt
      3. Type absolute path → Return
      4. Return → confirm 'Add to Project' / 'Open'
    """
    abs_path = str(path.resolve())
    # Escape for AppleScript string literal
    escaped_path = abs_path.replace("\\", "\\\\").replace('"', '\\"')
    script = f'''
    tell application "Logic Pro" to activate
    delay 0.3
    tell application "System Events"
        tell process "Logic Pro"
            set didClick to false
            -- Try Korean menu path first
            try
                click menu item "오디오 파일…" of menu 1 of menu item "가져오기" of menu "파일" of menu bar 1
                set didClick to true
            end try
            -- English fallback
            if not didClick then
                try
                    click menu item "Audio File…" of menu 1 of menu item "Import" of menu "File" of menu bar 1
                    set didClick to true
                end try
            end if
            if not didClick then
                return "ERROR: Could not find Import Audio File menu"
            end if
            delay 1.2
            -- Go-to-folder dialog in open panel
            keystroke "g" using {{command down, shift down}}
            delay 0.5
            keystroke "{escaped_path}"
            delay 0.4
            keystroke return
            delay 0.8
            -- Confirm open
            keystroke return
            delay 0.6
        end tell
    end tell
    return "OK"
    '''
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return r.returncode == 0 and "ERROR" not in (r.stdout or "")


def import_audio_via_drag(path: Path) -> bool:
    """Alternative: reveal in Finder, then simulate drag using AppleScript+CGEvent.

    Logic Pro accepts Finder drag drops reliably.
    """
    # Use Finder to reveal + then keyboard shortcut to send file to front app's workspace
    abs_path = str(path.resolve())
    script = f'''
    tell application "Finder"
        open POSIX file "{abs_path}" using application file (POSIX file "/Applications/Logic Pro.app")
    end tell
    '''
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return r.returncode == 0


def reveal_in_finder(path):
    subprocess.run(["open", "-R", str(path)], check=False)

# ── stem naming + color heuristics ───────────────────────────────────

STEM_COLOR_HINTS = {
    "drums": "🥁",
    "bass":  "🎸",
    "vocals": "🎤",
    "other": "🎹",
    "kick":  "🥁",
    "hat":   "🥁",
    "clap":  "🥁",
    "pad":   "🎹",
    "lead":  "🎹",
    "arp":   "🎹",
}

def friendly_stem_name(stem_filename: str) -> str:
    base = Path(stem_filename).stem.lower()
    icon = STEM_COLOR_HINTS.get(base, "🎵")
    return f"{icon} {base.capitalize()}"

# ── main ─────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="Bootstrap a Logic Pro session from an analysis folder.")
    ap.add_argument("analysis_dir", help="Path to analysis folder (contains analysis.json + stems/)")
    ap.add_argument("--no-import", action="store_true", help="Skip stem import (prep session only)")
    ap.add_argument("--bounce-target", type=float, default=None,
                    help="Target integrated LUFS for reference (e.g. -14 for streaming, -9 for club)")
    args = ap.parse_args()

    folder = Path(args.analysis_dir).resolve()
    if not folder.is_dir():
        print(c("red", f"Not a directory: {folder}"))
        sys.exit(1)

    analysis_path = folder / "analysis.json"
    preset_path = folder / "preset.json"
    stems_dir = folder / "stems"
    samples_dir = folder / "samples"
    scene_path = folder / "scene-audio.json"

    if not analysis_path.exists():
        print(c("red", f"Missing analysis.json in {folder}"))
        sys.exit(1)

    analysis = json.loads(analysis_path.read_text())
    preset = json.loads(preset_path.read_text()) if preset_path.exists() else {}
    scene = json.loads(scene_path.read_text()) if scene_path.exists() else {}

    stems = sorted([p for p in stems_dir.glob("*.wav")]) if stems_dir.is_dir() else []

    banner(f"🎼 Analysis → Logic Pro — {folder.name}")

    # ─── Summary ─────────────────────────────────────────────────────
    bpm = analysis.get("bpm", {}).get("value") or preset.get("bpm", {}).get("default", 120)
    key = analysis.get("key", "?")
    lufs = analysis.get("loudness", {}).get("integrated", 0)
    genre = scene.get("genre", "?")
    energy = scene.get("energy", 0)
    preset_name = preset.get("name", folder.name)

    print()
    print(f"  {c('cyan', 'Preset')}       : {preset_name}")
    print(f"  {c('cyan', 'Genre')}        : {genre}  (energy: {energy:.2f})")
    print(f"  {c('cyan', 'Tempo')}        : {bpm} BPM")
    print(f"  {c('cyan', 'Key')}          : {key}")
    print(f"  {c('cyan', 'Source LUFS')}  : {lufs} (integrated)")
    if args.bounce_target:
        gap = args.bounce_target - lufs
        direction = "down" if gap < 0 else "up"
        print(f"  {c('cyan', 'Target LUFS')}  : {args.bounce_target} ({abs(gap):.1f} dB {direction} from source)")
    print(f"  {c('cyan', 'Stems')}        : {len(stems)}  ({', '.join(p.name for p in stems)})")
    if samples_dir.is_dir():
        sample_count = len(list(samples_dir.glob("*")))
        print(f"  {c('cyan', 'Samples')}      : {sample_count} files in {samples_dir.name}/")
    if preset.get("synthParams"):
        instruments = list(preset["synthParams"].keys())
        print(f"  {c('cyan', 'Instruments')}  : {len(instruments)}  ({', '.join(instruments[:6])}{'...' if len(instruments) > 6 else ''})")

    # ─── MCP connect ─────────────────────────────────────────────────
    banner("🔌 MCP Connection")

    binary = find_binary()
    if not binary:
        print(c("red", "  LogicProMCP binary not found. Build first: swift build -c release"))
        sys.exit(1)
    print(f"  {c('green', 'Binary')}: {binary}")

    if not ensure_logic_running():
        print(c("red", "  Failed to launch Logic Pro"))
        sys.exit(1)
    print(f"  {c('green', 'Logic Pro')}: running")

    mcp = MCP(binary)
    if not init(mcp):
        print(c("red", "  MCP handshake failed"))
        mcp.close()
        sys.exit(1)
    print(f"  {c('green', 'MCP')}: initialized")

    # ─── Session setup ───────────────────────────────────────────────
    banner("⚙️  Session Setup")

    # Check Logic Pro has a REAL project loaded (not the Template chooser)
    window_title = logic_front_window_title()
    if not logic_has_loaded_project():
        print(f"  {c('yellow', '⚠')}  No loaded project (front window: '{window_title or 'none'}')")
        print(f"     Logic Pro needs an open project to import stems into.")
        print()
        print(f"  {c('cyan', 'Please do this:')}")
        print(f"     1. In Logic Pro: File → New (⌘N)")
        print(f"     2. Select {c('yellow', 'Empty Project')} template  → click Choose")
        print(f"     3. In 'New Tracks' dialog: pick {c('yellow', 'Audio')}, Number: 1, click Create")
        print(f"     4. Re-run this script")
        activate_logic()
        mcp.close()
        sys.exit(2)

    print(f"  {c('green', '✓')} Loaded project: {c('dim', window_title)}")

    # Set tempo
    text, err = tool(mcp, "logic_transport", "set_tempo", {"tempo": round(float(bpm), 1)})
    if err:
        print(f"  {c('yellow', '⚠')}  Could not set tempo via MCP: {text[:80]}")
    else:
        print(f"  {c('green', '✓')} Tempo set to {bpm} BPM")

    # ─── Stem import — manual drag-drop (safer than UI scripting) ────
    # UI scripting the File→Import menu is unreliable: Logic Pro 12 can crash
    # under rapid AppleScript UI automation (EXC_BAD_ACCESS seen in testing).
    # Instead: reveal the stems folder in Finder and instruct the user to drag.
    if stems and not args.no_import:
        print()
        print(f"  {c('cyan', 'Stem import (manual drag-drop):')}")
        reveal_in_finder(stems[0])  # reveals stems folder with bass.wav highlighted
        print(f"    {c('green', '✓')} Finder window opened at: {stems_dir}")
        print()
        print(f"  {c('yellow', 'YOU DO:')} select all 4 WAVs in Finder (⌘A), then drag them into")
        print(f"           the Logic Pro Tracks area. Logic will create one audio track per file.")
    elif args.no_import:
        print(f"  {c('yellow', '—')}  Skipping stem import (--no-import)")

    # ─── Open samples folder in Finder ───────────────────────────────
    if samples_dir.is_dir():
        reveal_in_finder(samples_dir)
        print(f"  {c('green', '✓')} Samples folder revealed in Finder")

    # ─── Session brief ───────────────────────────────────────────────
    banner("📝 Session Brief")

    print()
    print(f"  {c('cyan', 'Set in Logic Pro manually:')}")
    print(f"    • Key signature : {c('yellow', key)}  (Signature menu — not scriptable)")
    print(f"    • Time sig      : 4/4 (techno default)")
    if args.bounce_target:
        print(f"    • Bounce target : {c('yellow', f'{args.bounce_target} LUFS, -1.0 dBTP')}")
    print()

    if preset.get("synthParams"):
        print(f"  {c('cyan', 'Preset synth hints (from preset.json):')}")
        for inst, params in list(preset["synthParams"].items())[:5]:
            joined = ", ".join(f"{k}={v}" for k, v in list(params.items())[:3])
            print(f"    • {inst:15} → {c('dim', joined)}")
        if len(preset["synthParams"]) > 5:
            print(f"    ... {len(preset['synthParams']) - 5} more in preset.json")
        print()

    print(f"  {c('cyan', 'Recommended mastering chain (on Stereo Out):')}")
    print(f"    1. Linear Phase EQ — cut below 30 Hz, trim mud around 200-400 Hz")
    print(f"    2. Multi-pressor (4-band)  — gentle gluing (1-2 dB GR each band)")
    print(f"    3. Stereo Imager      — tighten mono below 120 Hz")
    print(f"    4. Adaptive Limiter   — target:")
    if args.bounce_target and args.bounce_target >= -10:
        print(f"       • Club/PA master: -9 LUFS integrated, -1.0 dBTP ceiling")
    else:
        print(f"       • Streaming:     -14 LUFS integrated, -1.0 dBTP ceiling")
        print(f"       • Club/PA:       -9 LUFS integrated, -1.0 dBTP ceiling")
    print()

    # ─── Next steps ──────────────────────────────────────────────────
    banner("⏭️  Next")
    print()
    print("  1. Confirm stems landed on correct tracks (rename if Logic placed them elsewhere)")
    print("  2. Set key signature in Signature List (Project Settings)")
    print("  3. Drag samples from the Finder window into tracks as needed")
    print("  4. Apply mastering chain on Stereo Out")
    print("  5. A/B against source: `open {folder}/stems/other.wav` to reference")
    print()
    if samples_dir.is_dir():
        print(f"  Samples folder: {samples_dir}")
    print(f"  Analysis: {analysis_path}")
    print(f"  Preset:   {preset_path}")
    print()

    mcp.close()


if __name__ == "__main__":
    main()
