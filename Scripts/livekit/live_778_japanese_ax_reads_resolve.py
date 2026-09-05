#!/usr/bin/env python3
"""Live proof that two AX reads work on a Logic Pro whose UI language is Japanese.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_778_japanese_ax_reads_resolve.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
`AXLocalePolicy` addresses two elements by their AXDescription, and on a Japanese Logic neither
string was the one Logic shows.

    trackContentExplicit        no Japanese form at all
    playheadPositionGroupLabel  carried `再生ヘッド位置`; Logic shows `再生ヘッドの位置`

The first is #778's headline: `logic_project get_regions` came back `channels_exhausted`, "Track
Content group not found", listing the Japanese landmarks it had scanned past. The second was found
while measuring the first and is the same defect one surface over — a translated string rather than
a read one, and it is matched with `.exactStrict`, so a missing `の` means the group is never found
and the bar/beat sliders every transport readback resolves through are unreachable.

Both forms now in the policy are verbatim from the ja-JP arrange census of 2026-09-05 (Logic 12.3
build 6674), filed under `docs/observations/`.

WHY THIS RUN IS ABOUT A JAPANESE LOGIC AND REFUSES TO BE ANYTHING ELSE
---------------------------------------------------------------------
Against an English Logic both reads have always worked, so every check below would pass while
observing nothing about the change. The locale is therefore a precondition with a red check rather
than a comment, and the run stops when it is not met.
"""

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402

COVERS = [
    "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift",
    "Sources/LogicProMCP/Channels/AccessibilityChannel+Regions.swift",
    "Sources/LogicProMCP/Accessibility/AXValueExtractors.swift",
]

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

# The strings under test, written here once so every check names the same thing.
JA_CANVAS = "トラックコンテンツ"
JA_PLAYHEAD = "再生ヘッドの位置"
PARK = "1.1.1.1"
TARGET = "9.1.1.1"

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])
rec = ev.record_screen(seconds=120)
d = E.Driver()

# The menu bar, read through osascript rather than through the server: the server's own locale
# report is one of the things this change fixes, so using it as the precondition would let the run
# certify itself. The three titles are the ones the detector recognises, measured 2026-09-05.
menu_titles = subprocess.run(
    ["osascript", "-e", 'tell application "System Events" to tell process "Logic Pro" to '
                        'return name of every menu bar item of menu bar 1'],
    capture_output=True, text=True).stdout.strip()
japanese_ui = all(t in menu_titles for t in ("ファイル", "編集", "トラック"))
ev.check("778/precondition-logic-ui-is-japanese",
         japanese_ui,
         "Logic's menu bar carries the Japanese top-level titles, which is the only state this "
         "change is about",
         f"menu bar={menu_titles!r}",
         # Not a mutation: on any other locale every read below worked before this change, so the
         # checks would pass without observing it.
         None)

system = d.tool("logic_system", "health") or {}
ev.falsifiable(
    "778/the-server-reports-the-japanese-ui-locale-rather-than-unknown",
    lambda o: o.get("logic_pro_ui_locale") == "ja-JP" and o.get("logic_pro_running") is True,
    system,
    {"logic_pro_running": True, "logic_pro_ui_locale": "unknown"},
    "logic_system health names the locale ja-JP, so an unsupported language is distinguishable "
    "from a menu bar that could not be read — the same answer both used to get",
    "remove the ja-JP row from topLevelMenuTitlesByLocale: no language's three titles are a "
    "subset of the menu bar, the read returns nil, and the field falls back to `unknown`")

# The band is resolved by AXDescription through the live-kit alias table, so a run that gets a band
# at all has proved that table can find the canvas in Japanese — the harness-side half of the same
# gap. `subject` comes back off the element that was found, so it is a reading, not a label.
CANVAS, CANVAS_SUBJECT = ev.located_band("Tracks contents")
ev.check("778/the-arrange-canvas-is-located-by-its-japanese-description",
         CANVAS is not None and CANVAS_SUBJECT == JA_CANVAS,
         f"the canvas is found and the description read back off it is {JA_CANVAS!r}",
         f"band={CANVAS!r} subject={CANVAS_SUBJECT!r}",
         "remove the Japanese row from AX_REGION_LABELS['Tracks contents']: the locator answers "
         "'no element with that exact AXDescription' and every band below is None")

LCD, LCD_SUBJECT = ev.located_band("Playhead Position")
ev.check("778/the-playhead-readout-is-located-by-its-japanese-description",
         LCD is not None and LCD_SUBJECT == JA_PLAYHEAD,
         f"the playhead-position readout is found and reads back as {JA_PLAYHEAD!r}",
         f"band={LCD!r} subject={LCD_SUBJECT!r}",
         "remove the AX_REGION_LABELS['Playhead Position'] row: it had none at all, so this "
         "selector located nothing on any Logic that is not English")

if CANVAS is None or LCD is None or not japanese_ui:
    d.close()
    ev.stop_recording(rec)
    print(json.dumps(ev.write(), indent=1))
    sys.exit(1)

# --- 1. Region enumeration, the read #778 reports ---------------------------------------------
regions = d.tool("logic_project", "get_regions") or {}
ev.note("778/get_regions-envelope", regions)

# WHAT THIS ASSERTS, and what it deliberately does not.
#
# #778's subject is a REFUSAL: `get_regions` answered `channels_exhausted`, "Track Content group not
# found", because no AXGroup matched any spelling the policy knew. So the question is whether the
# reader reaches that group and produces an enumeration — not how much of the arrangement happened
# to be on screen while it did.
#
# The first cut asked `complete is True`, and that conflated the two. Measured 2026-09-06: the same
# call answered `complete: False, reason: logic_ax_viewport_only` with `track_headers: 7,
# track_headers_in_viewport: 6` — one track scrolled out of view — and the check went red about a
# read that had worked. Three earlier runs passed only because every track happened to fit. A check
# that fails when a track scrolls is not a check about localization.
#
# `logic_ax_viewport_only` is the reader saying honestly that it saw the viewport and knows there
# may be more; `channels_exhausted` is it never finding the group at all. The predicate keeps
# rejecting any error and now requires an enumeration to exist, which the counterexample — the
# envelope #778 actually recorded — has no `regions` key for at all.
ev.note("778/get_regions-viewport", {
    "complete": regions.get("complete"), "reason": regions.get("reason"),
    "returned_count": regions.get("returned_count"), "_debug": regions.get("_debug")})
ev.falsifiable(
    "778/region-enumeration-is-not-refused-on-a-japanese-ui",
    lambda o: (o.get("error") is None
               and isinstance(o.get("regions"), list)
               and o.get("reason") != "channels_exhausted"),
    regions,
    {"error": "channels_exhausted",
     "hint": "Track Content group not found (scanned 35 AXGroups; landmarks: 'コントロールバー' | "
             "'再生ヘッドの位置' | 'インスペクタ' | 'ライブラリ' ...)"},
    "get_regions reaches the Track Content group and returns an enumeration rather than the "
    "channels_exhausted refusal #778 recorded, whose hint listed the Japanese landmarks it had "
    "scanned past",
    "remove トラックコンテンツ from trackContentExplicit: no AXGroup in the arrange window matches "
    "any spelling the policy knows, and the reader refuses with exactly the counterexample")

# --- 2. The playhead-position group, found while measuring the first --------------------------
parked = d.tool("logic_transport", "goto_position", {"position": PARK}) or {}
ev.note("778/park", parked)
time.sleep(1)

pre = ev.shot("778/before-goto", settle_region=LCD)
moved = d.tool("logic_transport", "goto_position", {"position": TARGET}) or {}
time.sleep(1)
post = ev.shot("778/after-goto", settle_region=LCD)
ev.note("778/move", moved)

# `observed` and `observed_position_components` are filled from the two sliders INSIDE the
# playhead-position group; nothing else in the control bar publishes bar and beat. The
# counterexample is what the pre-fix binary returned against this same Logic minutes earlier —
# `observed: null` with an empty component list — which is the shape a run gets when the group is
# never found, and it is why `goto_position` could not verify anything on a Japanese UI.
ev.falsifiable(
    "778/the-playhead-position-group-is-read-through-in-japanese",
    lambda o: (o.get("observed") or "").split(".")[0] == "9"
    and "bar" in (o.get("observed_position_components") or []),
    moved,
    {"observed": None, "observed_before": None, "observed_position_components": []},
    f"the move to {TARGET} reads bar 9 back off the sliders inside the {JA_PLAYHEAD!r} group",
    "restore 再生ヘッド位置 (no の): .exactStrict never matches the description Logic shows, the "
    "group is not found, positionSliders is empty and no bar/beat is ever read")

ev.visual("778/the-playhead-readout-changes-with-the-move",
          pre["file"], post["file"], LCD, subject=LCD_SUBJECT, expect_change=True,
          why="the band is the playhead-position readout located by its Japanese AXDescription, "
              "and the run moved the playhead from bar 1 to bar 9 between the two captures")

restore = d.tool("logic_transport", "goto_position", {"position": PARK})
d.close()
ev.restored("778/the-playhead-is-put-back",
            bool(restore) and restore.get("error") is None,
            f"moved to {TARGET} to make the readout change, returned to {PARK}: "
            f"{ {k: restore.get(k) for k in ('state', 'error', 'verified')} }")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
