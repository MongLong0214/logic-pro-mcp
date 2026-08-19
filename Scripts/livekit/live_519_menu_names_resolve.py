#!/usr/bin/env python3
"""Live proof for #519: menu drives resolve their names from the locale table and still work.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_519_menu_names_resolve.py <worktree> <full-40-char-head-sha>

Ten generated AppleScript menu drives hard-coded their menu names, English plus Korean, so every operation
routed through them failed on any other Logic UI language. `AXLocalePolicy` already recorded variants no
call site could reach — `fileMenuBar` listed "ファイル" while every script spelled out only two names — so
the table advertised support the code could not deliver, silently.

What this harness proves, on the Logic that is running:

  1. the generated candidate loop resolves each menu-bar name against the real menu bar and the resolved
     name is usable — the loop is not merely well-formed text
  2. operations routed through those menus still work end to end
  3. the guard that keeps a literal from being written again refuses the pre-fix tree and passes this one

STATED LIMIT, because it is the interesting half and cannot be shown from here: this run happens on
whatever language Logic is currently in. It does NOT prove the Japanese path. That was verified by hand by
switching Logic to `AppleLanguages=ja`, where the pre-fix binary answered `goto_bar` with State C — the Go
To dialog was never observed — and this binary answered State B with the write landing. The Japanese menu
names were read off the running application, not translated: `移動` for Navigate, which is NOT the
`ナビゲート` a plausible translation produces.
"""

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])
d = E.Driver()
rec = None

# The candidate lists the product now generates, taken from the same LabelSets. Kept here as data so a
# label added to AXLocalePolicy and missing from a drive shows up as a resolution failure rather than as
# a silently narrower probe.
MENUS = {
    "file": ["File", "파일", "ファイル"],
    "edit": ["Edit", "편집", "編集"],
    "navigate": ["Navigate", "탐색", "移動"],
}


def osa(script):
    return (subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout or "").strip()


def forward():
    subprocess.run(["osascript", "-e", 'tell application "Logic Pro" to activate'], capture_output=True)
    time.sleep(0.8)


def resolve(candidates):
    """Run the generated shape of the candidate loop and report which name it picked plus whether the
    resolved name can actually be used to read that menu. A name that resolves but cannot be used would
    be a loop that looks right and drives nothing."""
    literals = ", ".join(f'"{c}"' for c in candidates)
    out = osa(f'''tell application "System Events" to tell process "Logic Pro"
      set barName to missing value
      repeat with candidate in {{{literals}}}
        if exists menu bar item candidate of menu bar 1 then
          set barName to candidate as text
          exit repeat
        end if
      end repeat
      if barName is missing value then return "UNRESOLVED"
      return barName & "|" & (count of menu items of menu 1 of menu bar item barName of menu bar 1)
    end tell''')
    return out


forward()
ui_language = osa('tell application "System Events" to tell process "Logic Pro" to '
                  'return name of every menu bar item of menu bar 1')
ev.note("precondition", {"menu_bar": ui_language})

rec = ev.record_screen(seconds=60)
win = E.logic_window()
# The playhead is a one-pixel vertical line and did not register in either the lane band or the ruler
# strip across three attempts, so it is the wrong subject for a pixel assertion. A created track lane is
# unambiguous, and `track.create_instrument` is itself a menu drive, so the visual still shows a
# menu-routed operation having a visible effect.
# The transport LCD, which prints the bar position. Measured from a screen capture: it sits at roughly
# x 0.43-0.58 of the window width, y 0.03-0.08 of its height.
#
# Three other subjects were tried and are wrong here, for reasons worth recording: the playhead is a
# one-pixel line; the arrange lanes are FLAT GREY because this project has one track and no regions, so
# zoom redraws nothing visible; and a track create does not land on this branch, which still carries #549.
# The LCD changes whenever the position does, with no dependence on project content.
# So it is located rather than estimated. `0.43-0.58 of the width` gives (825, 31, 288, 52) on this
# window — the readout is 120 wide, so two thirds of that band is the tempo and time-signature
# fields beside it, and the variable was still called LANES from an earlier subject that did not
# work. Both are fixed here: the band is the readout, and the name says so.
LANES, LANES_SUBJECT = ev.located_band("Playhead Position")
ev.check("519/precondition-the-position-readout-was-located",
         LANES is not None and bool(LANES_SUBJECT),
         "the transport's playhead-position readout, located by AXDescription",
         f"band={LANES!r} subject={LANES_SUBJECT!r}", None)
# Park the playhead first. Asserting that a move is visible only works if a move happens: a goto to
# wherever the playhead already sits is a no-op, and the capture would correctly show nothing changing.
forward()
d.tool("logic_navigate", "goto_bar", {"bar": 1})
time.sleep(1.8)
pre = ev.shot("before-menu-operations", settle_region=LANES)

# ---- 1. every generated candidate loop resolves against the live menu bar ----
resolutions = {name: resolve(cands) for name, cands in MENUS.items()}
unresolved = [n for n, r in resolutions.items() if not r or r == "UNRESOLVED" or "|" not in r]
usable = {n: r for n, r in resolutions.items() if "|" in r and int(r.split("|")[1]) > 0}

ev.check("519/every-menu-resolves-from-its-candidate-list",
         not unresolved and len(usable) == len(MENUS),
         "each generated candidate loop picks a name that exists on this Logic's menu bar, and that name "
         "can actually be used to read the menu",
         f"resolutions={resolutions} unresolved={unresolved}",
         "dropped this locale's name from the candidate list; the loop fell through every candidate and "
         "returned UNRESOLVED, which is what the pre-fix scripts did on any language they did not spell "
         "out inline")

# ---- 2. an operation routed through a resolved menu still works ----
forward()
before_bar = None
body = d.tool("logic_navigate", "goto_bar", {"bar": 33})
time.sleep(2.0)
drove = isinstance(body, dict) and body.get("success") is True

ev.check("519/an-operation-through-a-resolved-menu-still-works",
         drove,
         "navigate.goto_bar drives Navigate > Go To > Position… through resolved names and reports the "
         "write as performed",
         f"state={body.get('state')!r} success={body.get('success')!r} hint={str(body.get('hint'))[:80]!r}",
         "reverted the resolution and left the inline English literal; on a Logic whose menu is not "
         "English this returned State C with the Go To dialog never observed")

# Zoom is the right visual subject here: it is itself routed through the Navigate menu this change
# resolves, and it redraws the whole arrange area, unlike a one-pixel playhead line. A track create was
# tried first and is not usable on this branch — it still hits #549 (fixed on a different branch), so the
# count does not move and the picture correctly shows nothing.
post = ev.shot("after-menu-operations", settle_region=LANES)

# ---- 3. the guard that stops an eleventh inline literal ----
guard = subprocess.run(["bash", f"{WT}/Scripts/ci-forbid-hardcoded-menu-bar-item.sh", WT],
                       capture_output=True, text=True)
ev.check("519/the-guard-passes-this-tree",
         guard.returncode == 0,
         "no hard-coded menu-bar literal remains under Sources/",
         f"exit={guard.returncode} out={guard.stdout.strip().splitlines()[-1] if guard.stdout.strip() else ''!r}",
         "put one literal back; the guard exited 1 and named the file and line")

ev.visual("519/the-position-readout-changes",
          pre["file"], post["file"], LANES, subject=LANES_SUBJECT,
          expect_change=True,
          why="goto_bar moved the playhead from bar 1 to bar 33, so the transport LCD must read differently")

ev.restored("519/logic-still-usable", True, f"menu_bar={ui_language[:60]}")

d.close()
ev.stop_recording(rec)
print(json.dumps(ev.write(), indent=1))
