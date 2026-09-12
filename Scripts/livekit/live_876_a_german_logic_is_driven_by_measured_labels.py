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

THE COUNTEREXAMPLE
------------------
A product that reaches State A on a German Logic by not using the German labels at all — falling
back to a position, an index, or the English string. Then `edit_menu_bar_is_not_english` would still
be true while the resolved path came back empty, so the run asserts the RESOLVED LEAF as well as the
outcome: State A with nothing resolved is the shape that would pass a weaker check and prove nothing.
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
move_labels = label_set("moveMenuItem")
playhead_labels = label_set("toPlayheadMenuItem")
edit_live = next((b for b in bar_items if b in edit_labels), "")

if not edit_live or edit_live == "Edit":
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

band, band_subject = ev.located_band("Tracks contents")
ev.check("876/the-arrange-canvas-was-located-through-its-german-description",
         band is not None and bool(band_subject),
         "the canvas is found by the AXDescription it carries, which IS localised — the German "
         "spelling was read off the de-DE census of 2026-09-12 and added to the locator's measured "
         "table, without which no capture can be taken on the one run where the locale is the point",
         f"band={band!r} subject={band_subject!r}", None)

before = ev.shot("876/before", settle_region=band)

recorded = None
for _ in range(3):
    recorded = d.tool("logic_tracks", "record_sequence", {"notes": "60,0,480"})
    if isinstance(recorded, dict) and recorded.get("verified") is True:
        break
    time.sleep(4)
ev.note("876/record", {k: v for k, v in (recorded or {}).items() if k != "raw_help"})

seek = d.tool("logic_transport", "goto_position", {"bar": str(TARGET_BAR)})
time.sleep(2)
moved = d.tool("logic_edit", "move_to_playhead", {})
time.sleep(2)
ev.note("876/move", {"seek": (seek or {}).get("observed"), "move": moved})

after = ev.shot("876/after", settle_region=band)
ev.visual("876/the-region-visibly-moved-on-a-german-logic",
          before["file"], after["file"], band, subject=band_subject, expect_change=True,
          why=f"a region was created and dragged to bar {TARGET_BAR} through Logic's GERMAN menus, "
              "so the canvas it is drawn on must differ — an envelope reporting State A about a "
              "region nobody can see move would leave this band untouched")

body = moved if isinstance(moved, dict) else {}
reading = {
    "menu_bar": bar_items,
    "edit_menu_bar_live": edit_live,
    "edit_menu_bar_is_not_english": edit_live != "Edit",
    "edit_menu_bar_is_a_policy_label": edit_live in edit_labels,
    "move_leaf_resolved": move_live,
    "to_playhead_leaf_resolved": playhead_live,
    "move_leaf_is_a_policy_label": move_live in move_labels,
    "to_playhead_leaf_is_a_policy_label": playhead_live in playhead_labels,
    "region_readback_verified": (recorded or {}).get("verified"),
    "move_state": body.get("state"),
}

ev.falsifiable(
    "876/a-german-logic-is-driven-by-labels-the-product-declares",
    lambda o: (o["edit_menu_bar_is_not_english"]
               and o["edit_menu_bar_is_a_policy_label"]
               and bool(o["move_leaf_resolved"]) and o["move_leaf_is_a_policy_label"]
               and bool(o["to_playhead_leaf_resolved"]) and o["to_playhead_leaf_is_a_policy_label"]
               and o["region_readback_verified"] is True
               and o["move_state"] == "A"),
    reading,
    {"menu_bar": ["Logic Pro", "Ablage", "Bearbeiten"],
     "edit_menu_bar_live": "Bearbeiten",
     "edit_menu_bar_is_not_english": True,
     "edit_menu_bar_is_a_policy_label": True,
     "move_leaf_resolved": "", "to_playhead_leaf_resolved": "",
     "move_leaf_is_a_policy_label": False,
     "to_playhead_leaf_is_a_policy_label": False,
     "region_readback_verified": True,
     "move_state": "A"},
    "on a Logic whose menu bar is German, the Edit ▸ Move ▸ To Playhead path resolves entirely out "
    "of labels `AXLocalePolicy` declares, a region's LOCALISED help string parses into a verified "
    "readback, and the move reaches State A. THE COUNTEREXAMPLE is the product reaching State A on "
    "a German Logic without using German labels — the menu bar is still German and the outcome is "
    "still A, but nothing resolved; a check that asked only for State A would call that success",
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
         restored_launch and any(b in label_set("editMenuBar") for b in restored_bar)
         and ("Bearbeiten" not in restored_bar or original[0] == "de"),
         "Logic is back on the language this run found it in, read back off its own menu bar — "
         "checking the `defaults` value would only confirm that the write happened",
         f"original={original!r} menu bar now={restored_bar!r}", None)

ev.stop_recording(recording)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
