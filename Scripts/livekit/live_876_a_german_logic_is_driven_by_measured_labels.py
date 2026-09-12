#!/usr/bin/env python3
"""Live proof that a menu-routed operation reaches State A on a Logic running in German.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_876_a_german_logic_is_driven_by_measured_labels.py <worktree> <full-40-char-head-sha>

WHAT #876 REPORTED AND WHAT WAS ACTUALLY TRUE
---------------------------------------------
The report says the server works for English and Chinese and asks for German. Both halves of that
premise were wrong: it worked for English, Korean and Japanese, Chinese appeared in two string
arrays and in no `LabelSet` variant at all, and German was at zero.

The fix is NOT a translation. Logic's German is its own and is not derivable from its English — the
first alignment of the two censuses shows the application's own name carries a NON-BREAKING space
between the words, and every German ellipsis is preceded by a space (`MIDI-Datei …`). Nobody types
those. So German joined the locale campaign the way Japanese did, and this run is the part that a
census cannot do: driving the PRODUCT against a German Logic and watching an edit land.

WHY THE EXPECTED STRINGS ARE READ OUT OF THE PRODUCT
----------------------------------------------------
This file transcribes no German. Every label it compares against Logic is read from
`AXLocalePolicy.swift` at run time, so the claim is about the product's label sets rather than about
this harness agreeing with itself. Editing a LabelSet changes what this run checks — which is the
point, and is why the mutation below is stated as an edit to the policy rather than to the test.

WHAT THIS RUN DOES TO THE MACHINE
---------------------------------
It switches Logic's UI language and restarts it — there is no other way to observe a German menu.
The original `AppleLanguages` value is captured first and restored at the end, and the restoration
is CONFIRMED by reading Logic's menu bar back rather than by reading the setting that was written.
It works on the disposable locale-campaign fixture and refuses to run against anything else, because
relaunching Logic over somebody's project is not this run's to do.

WHAT IT DOES NOT CLAIM, SAID BEFORE THE RESULT
----------------------------------------------
It does not claim the product WORKS in German. `tracks.record_sequence` does not: it imports a
standard MIDI file and the import panel is localised too, so on a German Logic the operation refuses
at `preflight_blocking_dialog` naming a dialog called `Importieren`. That refusal is recorded here
as an observation rather than left out, because a run that quietly picked operations that pass would
be measuring its own selection. The reachable German surface today is MENU-ROUTED navigation, and
that is exactly what this asserts.

THE COUNTEREXAMPLE
------------------
A product that succeeds on a German Logic by not using the German labels at all — falling back to a
position, an index, or the English string. Then `edit_menu_bar_is_not_english` would still be true
while the resolved path came back empty, so the run asserts the RESOLVED LEAVES as well as the
outcome: success with nothing resolved is the shape that would pass a weaker check and prove nothing.
"""
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402

COVERS = [
    "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift",
    # This run drives Navigate ▸ Go To ▸ Position… end to end, which is the route whose dialog
    # matcher moved out of an AppleScript literal and onto the policy for #876. Nothing else in the
    # tree claimed that file, so the change that made German work was covered by no live run.
    "Sources/LogicProMCP/Channels/AccessibilityChannel+Transport.swift",
]

FIXTURE = os.path.expanduser("~/Music/Logic/lpm-locale-campaign.logicx")
FIXTURE_NAME = os.path.basename(FIXTURE)
LAUNCH_TIMEOUT = 120.0
TARGET_BAR = 9

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

POLICY = os.path.join(WT, "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift")
ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def label_set(name):
    """Canonical + variants for one LabelSet, read from the Swift the product compiles."""
    text = open(POLICY, encoding="utf-8").read()
    m = re.search(r"static let " + name + r"\s*=\s*LabelSet\(\s*canonical:\s*\"([^\"]*)\",\s*"
                  r"variants:\s*\[([^\]]*)\]", text, re.S)
    if not m:
        return []
    return [m.group(1)] + re.findall(r"\"([^\"]*)\"", m.group(2))


def logic_running():
    return osa('tell application "System Events" to return (count of (every process whose '
               'name is "Logic Pro"))') == "1"


def windows():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def documents():
    raw = osa('''tell application "System Events" to tell process "Logic Pro"
  set out to ""
  repeat with w in windows
    try
      set out to out & (value of attribute "AXDocument" of w as string) & "|"
    end try
  end repeat
  return out
end tell''')
    return [d for d in raw.split("|") if d and d != "missing value"]


def menu_bar_items():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every menu bar item of menu bar 1')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def menu_items(bar):
    raw = osa(f'tell application "System Events" to tell process "Logic Pro" to '
              f'return name of every menu item of menu 1 of menu bar item "{bar}" of menu bar 1')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def submenu_items(bar, item):
    raw = osa(f'tell application "System Events" to tell process "Logic Pro" to '
              f'return name of every menu item of menu 1 of '
              f'(first menu item of menu 1 of menu bar item "{bar}" of menu bar 1 '
              f'whose name is "{item}")')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def press_discard():
    """Answer a save prompt STRUCTURALLY — the button that is neither default nor cancel.

    Matching a localised word here would make a locale harness carry a locale bug, which is the
    defect this whole issue is about. Borrowed from `locale-campaign.sh`, which learned it the
    same way.
    """
    return osa('''tell application "System Events" to tell process "Logic Pro"
  if (count of (windows whose subrole is "AXDialog")) is 0 then return ""
  set d to first window whose subrole is "AXDialog"
  set skip to {}
  try
    set end of skip to name of (value of attribute "AXDefaultButton" of d) as string
  end try
  try
    set end of skip to name of (value of attribute "AXCancelButton" of d) as string
  end try
  if (count of skip) is not 2 then return ""
  repeat with b in (every button of d)
    set n to name of b as string
    if n is not in skip then
      click b
      return n
    end if
  end repeat
  return ""
end tell''')


def press_default_button():
    return osa('''tell application "System Events" to tell process "Logic Pro"
  if (count of (windows whose subrole is "AXDialog")) is 0 then return ""
  set d to first window whose subrole is "AXDialog"
  try
    set b to value of attribute "AXDefaultButton" of d
    set n to name of b as string
    click b
    return n
  end try
  return ""
end tell''')


def quit_logic():
    if not logic_running():
        return True
    for _ in range(4):
        osa('tell application "Logic Pro" to quit')
        deadline = time.time() + 20
        while logic_running() and time.time() < deadline:
            time.sleep(2)
        if not logic_running():
            return True
        press_discard()
        time.sleep(3)
    return not logic_running()


def launch_on_fixture():
    subprocess.run(["open", "-a", "Logic Pro", FIXTURE], capture_output=True)
    deadline = time.time() + LAUNCH_TIMEOUT
    while time.time() < deadline:
        if any(" - " in t for t in windows()):
            return True
        press_default_button()   # the autosave-recovery sheet, if this is not the first launch
        time.sleep(3)
    return False


def language_setting():
    raw = subprocess.run(["defaults", "read", "com.apple.logic10", "AppleLanguages"],
                         capture_output=True, text=True).stdout
    return re.findall(r"[\w-]+", raw) or ["en"]


def set_language(code):
    subprocess.run(["defaults", "write", "com.apple.logic10", "AppleLanguages", "-array", code],
                   capture_output=True)


original = language_setting()
ev.note("876/original-language", {"AppleLanguages": original})

# Only the disposable fixture may be open. Authorisation to switch Logic's language is not
# authorisation to relaunch over somebody's project, and the only way to restart without a save
# prompt over their work is to never have it open.
open_docs = documents() if logic_running() else []
foreign = [d for d in open_docs if FIXTURE_NAME not in d]
ev.check("876/precondition-only-the-disposable-fixture-is-open",
         not foreign,
         f"no document other than {FIXTURE_NAME} is open, so the relaunches below cannot discard "
         f"anyone's unsaved work",
         f"documents={open_docs!r}", None)
if foreign:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

stopped = quit_logic()
ev.check("876/precondition-logic-stopped-before-the-language-was-switched",
         stopped,
         "Logic is not running, so the language written next is the one the launch reads — a quit "
         "that was merely SENT leaves the old language in place and the run measures English while "
         "reporting German",
         f"running={logic_running()} windows={windows()!r}", None)
if not stopped:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

set_language("de")
launched = launch_on_fixture()
bar_items = menu_bar_items()
ev.note("876/launch", {"launched": launched, "windows": windows(), "menu_bar": bar_items})

edit_labels = label_set("editMenuBar")
# The English spelling is READ, never written in — `canonical` is the en-US form, and comparing
# against it is how this run knows Logic did not silently come up in English. Writing "Edit" here
# would put one language's spelling in a file whose whole subject is that spellings are measured.
edit_english = edit_labels[0] if edit_labels else ""
move_labels = label_set("moveMenuItem")
playhead_labels = label_set("toPlayheadMenuItem")
edit_live = next((b for b in bar_items if b in edit_labels), "")

if not edit_live or edit_live == edit_english:
    ev.check("876/precondition-logic-came-up-in-german", False,
             "Logic's own menu bar is not English, read from the application rather than from the "
             "setting that was written",
             f"menu bar={bar_items!r} · Edit reads {edit_live!r}", None)
    set_language(original[0])
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

recording = ev.record_screen(seconds=300)

d = E.Driver()
d.tool("logic_system", "refresh_cache")

edit_item_list = menu_items(edit_live)
move_live = next((i for i in edit_item_list if i in move_labels), "")
playhead_live = next((i for i in submenu_items(edit_live, move_live) if i in playhead_labels), "") \
    if move_live else ""
ev.note("876/menu-path", {"edit": edit_live, "move": move_live, "to_playhead": playhead_live,
                          "policy": {"edit": edit_labels, "move": move_labels,
                                     "to_playhead": playhead_labels}})

# `--max-width 400` picks the LCD rather than the whole bar. Two AXGroups carry this description —
# measured 1900x58 for the bar and 264x48 for the readout — and the wide one is full of indicators
# that change on their own, so a capture of it never settles and a difference in it would prove
# nothing about the playhead. The narrow one is where Logic writes the position.
band, band_subject = ev.located_band("Control Bar", "--max-width", "400")
ev.check("876/the-control-bar-was-located-through-its-german-description",
         band is not None and bool(band_subject),
         "the control bar's position readout is found by the AXDescription it carries, which IS localised — the German "
         "spelling was read off the de-DE census of 2026-09-12, and without it no capture can be "
         "taken on the one run where the locale is the point",
         f"band={band!r} subject={band_subject!r}", None)

canvas, canvas_subject = ev.located_band("Tracks contents")
ev.note("876/the-canvas-is-also-german", {"band": canvas, "subject": canvas_subject})

before = ev.shot("876/before-the-playhead-moved", settle_region=band)

seek = d.tool("logic_transport", "goto_position", {"bar": str(TARGET_BAR)})
time.sleep(2)
ev.note("876/goto", seek if isinstance(seek, dict) else {"raw": str(seek)[:200]})

after = ev.shot("876/after-the-playhead-moved", settle_region=band)
ev.visual("876/the-playhead-readout-moved-on-a-german-logic",
          before["file"], after["file"], band, subject=band_subject, expect_change=True,
          why=f"the playhead was driven to bar {TARGET_BAR} through Logic's GERMAN Navigate ▸ Go To "
              "▸ Position… chain, and the control bar's position readout is where Logic shows where "
              "the playhead is — a route reporting success while the readout still says bar 1 would "
              "leave this band identical")

# NOT a passing clause, and deliberately so. It is the next German gap, measured in the same run
# that proves the menus work, so nobody has to take its size on trust.
blocked = d.tool("logic_tracks", "record_sequence", {"notes": "60,0,480"})
ev.note("876/the-import-path-is-not-reachable-in-german",
        {k: v for k, v in (blocked or {}).items()
         if k in ("state", "error", "failure_stage", "dialog_title", "hint")})

seek_body = seek if isinstance(seek, dict) else {}
reading = {
    "menu_bar": bar_items,
    "edit_menu_bar_live": edit_live,
    "edit_menu_bar_is_not_english": edit_live != edit_english,
    "edit_menu_bar_is_a_policy_label": edit_live in edit_labels,
    "move_leaf_resolved": move_live,
    "to_playhead_leaf_resolved": playhead_live,
    "move_leaf_is_a_policy_label": move_live in move_labels,
    "to_playhead_leaf_is_a_policy_label": playhead_live in playhead_labels,
    "goto_state": seek_body.get("state"),
    "goto_succeeded": seek_body.get("success"),
    "goto_took_no_dialog_route": seek_body.get("dialog_route_outcome") is None,
    "import_refused_naming_a_german_dialog": (blocked or {}).get("dialog_title"),
}

ev.falsifiable(
    "876/a-german-logic-is-navigated-by-labels-the-product-declares",
    lambda o: (o["edit_menu_bar_is_not_english"]
               and o["edit_menu_bar_is_a_policy_label"]
               and bool(o["move_leaf_resolved"]) and o["move_leaf_is_a_policy_label"]
               and bool(o["to_playhead_leaf_resolved"]) and o["to_playhead_leaf_is_a_policy_label"]
               and o["goto_succeeded"] is True
               and o["goto_state"] in ("A", "B")),
    reading,
    {"menu_bar": ["Logic Pro", "Ablage", "Bearbeiten"],
     "edit_menu_bar_live": "Bearbeiten",
     "edit_menu_bar_is_not_english": True,
     "edit_menu_bar_is_a_policy_label": True,
     "move_leaf_resolved": "", "to_playhead_leaf_resolved": "",
     "move_leaf_is_a_policy_label": False,
     "to_playhead_leaf_is_a_policy_label": False,
     "goto_state": "B", "goto_succeeded": True, "goto_took_no_dialog_route": True,
     "import_refused_naming_a_german_dialog": "Importieren"},
    "on a Logic whose menu bar is German, Edit ▸ Move ▸ To Playhead resolves entirely out of labels "
    "`AXLocalePolicy` declares, and Navigate ▸ Go To ▸ Position… drives the playhead successfully. "
    "THE COUNTEREXAMPLE is the product succeeding on a German Logic without using German labels — "
    "the menu bar is still German and the call still succeeds, but nothing resolved; a check that "
    "asked only for success would call that a working German build",
    mutation="delete the German variant from `editMenuBar`, `moveMenuItem` or `toPlayheadMenuItem` "
            "in `AXLocalePolicy.swift`. The corresponding `*_resolved` field empties and its "
            "`*_is_a_policy_label` clause goes false on its own, while the menu-bar clauses stay "
            "green — which is why the resolved leaves are asserted separately from the outcome "
            "rather than folded into it",
)

# ---- put the machine back, and CONFIRM it from Logic rather than from the setting ---------------
d.close()
quit_logic()
set_language(original[0])
restored_launch = launch_on_fixture()
restored_bar = menu_bar_items()
ev.check("876/the-original-language-was-restored-and-confirmed-from-logic",
         restored_launch and any(b in edit_labels for b in restored_bar)
         and (next((b for b in restored_bar if b in edit_labels), "") == edit_english
              or original[0] == "de"),
         "Logic is back on the language this run found it in, read back off its own menu bar — "
         "checking the `defaults` value would only confirm that the write happened",
         f"original={original!r} menu bar now={restored_bar!r}", None)

ev.stop_recording(recording)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
