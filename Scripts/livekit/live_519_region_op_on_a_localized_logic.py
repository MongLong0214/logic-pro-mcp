#!/usr/bin/env python3
"""Live proof that a region operation succeeds on a Logic running in Korean.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_519_region_op_on_a_localized_logic.py <worktree> <full-40-char-head-sha>

WHAT #519 IS ABOUT
------------------
Ten AppleScript menu drives hard-coded the ENGLISH menu-bar item name, so every operation routed
through them failed on a Logic in any other language. The menu names are now resolved from
`AXLocalePolicy` LabelSets, and the issue's remaining acceptance criterion is that a REGION operation
be shown to succeed on a Korean Logic.

It could not be met until now for two reasons, both fixed and merged:

  #589   `region.move_to_playhead` was implemented and reachable from no tool — there was no region
         operation to drive. It is now `logic_edit.move_to_playhead`.
  #590   on a freshly launched Logic the project chooser was counted as an open document, so
         `project.new` refused and a Korean project could not be opened at all.

WHY THE LABELS ARE CHECKED AGAINST THE POLICY FILE, NOT AGAINST A TRANSCRIPTION
------------------------------------------------------------------------------
A harness that hard-codes "편집" and compares it to the live menu proves only that this file and Logic
agree. The claim that matters is that the PRODUCT's label sets are right, so the expected strings are
read out of `AXLocalePolicy.swift` at run time and the live menus are checked against those. If
someone edits a LabelSet, this run notices.

That check could have failed. Logic's Korean renderings are not derivable from the English: this
repository already records `New` = `신규`, not the `새로 만들기` a translation produces.

WHAT THIS RUN DOES TO THE MACHINE
---------------------------------
It switches Logic's UI language and restarts it, twice — there is no other way to observe a localized
menu. The original `AppleLanguages` value is captured first and restored at the end, and the
restoration is verified by reading the menu bar back from Logic rather than by reading the setting it
just wrote.
"""

import json
import os
import re
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
POLICY = os.path.join(WT, "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift")
TARGET_BAR = 9
LAUNCH_TIMEOUT = 90.0
CHOOSER_TITLES = ("Choose a Project", "프로젝트 선택")


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def label_set(name):
    """The canonical + variants `AXLocalePolicy` declares for one LabelSet, read from the source."""
    text = open(POLICY, encoding="utf-8").read()
    match = re.search(
        r"static let " + name + r"\s*=\s*LabelSet\(\s*canonical:\s*\"([^\"]*)\",\s*"
        r"variants:\s*\[([^\]]*)\]", text, re.S)
    if not match:
        return []
    variants = re.findall(r"\"([^\"]*)\"", match.group(2))
    return [match.group(1)] + variants


def windows():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def logic_running():
    return osa('tell application "System Events" to return (count of (every process whose '
               'name is "Logic Pro"))') == "1"


def menu_bar_items():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every menu bar item of menu bar 1')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def submenu_items(bar, item):
    raw = osa(f'tell application "System Events" to tell process "Logic Pro" to '
              f'return name of every menu item of menu 1 of '
              f'(first menu item of menu 1 of menu bar item "{bar}" of menu bar 1 '
              f'whose name is "{item}")')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def dismiss_single_button_alert():
    deadline = time.time() + 15
    while time.time() < deadline:
        raw = osa('tell application "System Events" to tell process "Logic Pro" to '
                  'return (count of (every button of (first window whose subrole is "AXDialog")))')
        if raw.isdigit() and int(raw) == 1:
            text = osa('tell application "System Events" to tell process "Logic Pro" to return '
                       'value of every static text of (first window whose subrole is "AXDialog")')
            osa('tell application "System Events" to tell process "Logic Pro" to '
                'click button 1 of (first window whose subrole is "AXDialog")')
            time.sleep(2)
            return {"dismissed": True, "text": text[:160]}
        time.sleep(2)
    return {"dismissed": False}


DISCARD_LABELS = ("Don’t Save", "Don't Save", "저장 안 함")


def quit_logic():
    """Quit Logic, and answer only the thing that is actually refusing the quit.

    An earlier version pressed Escape first and then looked for the discard button. Escape CANCELS
    the save prompt, so the sequence defeated itself: the prompt went away, the click found nothing,
    Logic stayed running, and the language switch that followed had no effect — the run came up in
    English. The precondition caught that rather than testing English and calling it Korean, but the
    cause was here.

    So the dialog is inspected before anything is sent to it. A save prompt is answered by its
    discard button, because the only unsaved document this run can be holding is the scratch project
    it created itself. Anything else that is merely a sheet gets Escape.
    """
    for _ in range(3):
        osa('tell application "Logic Pro" to quit')
        deadline = time.time() + 20
        while logic_running() and time.time() < deadline:
            time.sleep(2)
        if not logic_running():
            return True

        osa('tell application "Logic Pro" to activate')
        time.sleep(1)
        buttons = osa('tell application "System Events" to tell process "Logic Pro" to '
                      'return name of every button of window 1')
        discard = next((label for label in DISCARD_LABELS if label in (buttons or "")), None)
        if discard:
            osa('tell application "System Events" to tell process "Logic Pro" to '
                f'click button "{discard}" of window 1')
        else:
            osa('tell application "System Events" to key code 53')
        time.sleep(3)
    return not logic_running()


def launch_logic():
    subprocess.run(["open", "-a", "Logic Pro"], capture_output=True)
    deadline = time.time() + LAUNCH_TIMEOUT
    while time.time() < deadline:
        if any(any(c in t for c in CHOOSER_TITLES) or "Tracks" in t or "트랙" in t
               for t in windows()):
            return True
        time.sleep(3)
    return False


def set_language(code):
    subprocess.run(["defaults", "write", "com.apple.logic10", "AppleLanguages", "-array", code],
                   capture_output=True)


def current_language_setting():
    raw = subprocess.run(["defaults", "read", "com.apple.logic10", "AppleLanguages"],
                         capture_output=True, text=True).stdout
    codes = re.findall(r"[\w-]+", raw)
    return [c for c in codes if c not in ("", )] or ["en"]


def start_bar(help_text):
    """The bar Logic's help string says a region starts at — the two languages differ in order."""
    text = help_text or ""
    korean = re.search(r"(\d+)\s*마디[^0-9]*시작", text)
    if korean:
        return int(korean.group(1))
    english = re.search(r"starts at\D*(\d+)", text)
    return int(english.group(1)) if english else None


original_languages = current_language_setting()
ev.note("519/original-language", {"AppleLanguages": original_languages})

# ---- put Logic into Korean --------------------------------------------------------------------

# The quit has to be CONFIRMED before the language is switched: a Logic that never stopped keeps its
# old language, `open -a` on a running app does nothing, and the run would come up in English with
# the setting saying otherwise.
stopped = quit_logic()
ev.check("519/precondition-logic-actually-stopped-before-the-language-was-switched",
         stopped,
         "Logic is not running, so the language written below is the one the next launch reads — a "
         "quit that was merely SENT would leave the old language in place and the run would measure "
         "the wrong thing",
         f"running={logic_running()} windows={windows()!r}", None)

if not stopped:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

set_language("ko")
launched = launch_logic()
alert = dismiss_single_button_alert()
bar_items = menu_bar_items()
ev.note("519/launch", {"launched": launched, "windows": windows(), "menu_bar": bar_items,
                       "alert": alert})

edit_labels = label_set("editMenuBar")
move_labels = label_set("moveMenuItem")
playhead_labels = label_set("toPlayheadMenuItem")
edit_live = next((b for b in bar_items if b in edit_labels), "")

ev.check("519/precondition-logic-is-running-in-korean",
         bool(edit_live) and edit_live != "Edit",
         "Logic's own menu bar is in a language other than English, read from the application rather "
         "than from the setting that was written — a run that silently came up in English would "
         "prove nothing about localization",
         f"menu bar={bar_items!r} · Edit reads {edit_live!r}", None)

if not edit_live or edit_live == "Edit":
    set_language(original_languages[0])
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=300)

ev.check("519/the-edit-menu-bar-label-is-one-the-policy-carries",
         edit_live in edit_labels,
         "the live Edit menu-bar item is a label `AXLocalePolicy.editMenuBar` declares — read out of "
         "the policy source at run time, so this compares the PRODUCT against Logic rather than "
         "comparing a transcription in this file against Logic",
         f"live={edit_live!r} policy={edit_labels!r}",
         "remove the Korean variant from `editMenuBar`: this check goes red and every menu drive "
         "under it stops resolving")

# ---- a project, then a region --------------------------------------------------------------------

d = E.Driver()
time.sleep(4)
created = d.tool("logic_project", "new", {})
time.sleep(10)
ev.note("519/project-new", created if isinstance(created, dict) else {"raw": str(created)[:200]})

ev.check("519/a-project-can-be-created-on-a-korean-logic-from-a-cold-launch",
         any("트랙" in t or "Tracks" in t for t in windows()),
         "`project.new` produced an arrange window from the state a fresh launch lands in — the "
         "chooser no longer counts as an open document (#590), which is what made a Korean project "
         "reachable at all",
         f"windows={windows()!r} state={(created or {}).get('state')!r}",
         "count the chooser as a document again: the call is refused `precondition_open_document` "
         "and nothing below can run")

edit_items = osa(f'tell application "System Events" to tell process "Logic Pro" to '
                 f'return name of every menu item of menu 1 of menu bar item "{edit_live}" '
                 f'of menu bar 1')
edit_item_list = [t.strip() for t in edit_items.split(",") if t.strip()]
move_live = next((i for i in edit_item_list if i in move_labels), "")
playhead_list = submenu_items(edit_live, move_live) if move_live else []
playhead_live = next((i for i in playhead_list if i in playhead_labels), "")
ev.note("519/menu-path", {"edit": edit_live, "move": move_live, "to_playhead": playhead_live,
                          "policy": {"edit": edit_labels, "move": move_labels,
                                     "to_playhead": playhead_labels}})

ev.check("519/the-localized-move-to-playhead-path-matches-the-policy",
         bool(move_live) and bool(playhead_live),
         "Edit ▸ Move ▸ To Playhead resolves on this Logic using labels the policy declares — the "
         "path the region operation drives, in the language under test",
         f"live path={edit_live!r} > {move_live!r} > {playhead_live!r} · policy move={move_labels!r} "
         f"to_playhead={playhead_labels!r}",
         "drop the Korean variant from `toPlayheadMenuItem`: the leaf stops resolving and the "
         "operation below returns State C with a menu-not-found hint")

recorded = None
for attempt in range(3):
    recorded = d.tool("logic_tracks", "record_sequence", {"notes": "60,0,480"})
    if isinstance(recorded, dict) and recorded.get("verified") is True:
        break
    time.sleep(4)
ev.note("519/record", {k: v for k, v in (recorded or {}).items() if k != "raw_help"})

ev.check("519/a-region-exists-and-its-korean-help-string-parses",
         isinstance(recorded, dict) and recorded.get("verified") is True
         and isinstance(recorded.get("start_bar"), int),
         "an import created a region and the product parsed its LOCALIZED help string into bars — "
         "the readback that every region verification downstream depends on",
         f"verified={(recorded or {}).get('verified')!r} start_bar={(recorded or {}).get('start_bar')!r} "
         f"name={(recorded or {}).get('region_name')!r}",
         "restore the English-only region-help keyword: the enumeration stops recognising the "
         "region and this check goes red before the move is ever attempted")

# #622: this run recorded the screen and took no captures, so `is_clean` refused it for having
# looked at nothing — a gap that predates the counter and only became visible when the counter
# landed. The band is the arrange canvas, located by the AXDescription it carries, and it is
# resolved HERE rather than at the top of the file because a Korean Logic has only just been
# launched and given a project; before that there is no canvas to find.
#
# This comment used to say the lookup "does not depend on Logic's language — the one property this
# harness needs above all others." That was WRONG, and this run is what disproved it: measured
# 2026-08-21, the canvas answers to `트랙 콘텐츠` on a Korean Logic and the English name finds
# nothing, so the capture could not be taken on the single run where the locale was the point.
# `located_band` now tries the measured translations; an unmeasured locale still finds nothing, and
# that is deliberate.
CANVAS, CANVAS_SUBJECT = ev.located_band("Tracks contents")
ev.check("519/precondition-the-arrange-canvas-was-located",
         CANVAS is not None and bool(CANVAS_SUBJECT),
         "the arrange canvas, located by the AXDescription it carries — through the measured "
         "translation table, because that description IS localized",
         f"band={CANVAS!r} subject={CANVAS_SUBJECT!r}", None)

arrange_window = next((t for t in windows() if "트랙" in t or "Tracks" in t), None)
before_move = ev.shot("519/region-before-move", settle_region=CANVAS, window_title=arrange_window)

seek = d.tool("logic_transport", "goto_position", {"bar": str(TARGET_BAR)})
time.sleep(2)
moved = d.tool("logic_edit", "move_to_playhead", {})
time.sleep(2)

after_move = ev.shot("519/region-after-move", settle_region=CANVAS, window_title=arrange_window)
ev.visual("519/the-region-visibly-moved-on-a-korean-logic",
          before_move["file"], after_move["file"], CANVAS, subject=CANVAS_SUBJECT,
          expect_change=True,
          why=f"the region was dragged to bar {TARGET_BAR} through Logic's Korean menus, so the "
              "canvas it is drawn on must differ — an envelope reporting State A about a region "
              "nobody can see moving would leave this band alone")
ev.note("519/move", {"seek": (seek or {}).get("observed"), "move": moved})

body = moved if isinstance(moved, dict) else {}
ev.check("519/the-region-operation-reaches-state-a-on-a-korean-logic",
         body.get("state") == "A" and body.get("verified") is True
         and body.get("region_name") == body.get("post_region_name")
         and body.get("pre_track_index") == body.get("post_track_index")
         and isinstance(body.get("post_start_bar"), int)
         and abs(body["post_start_bar"] - TARGET_BAR) <= 1
         and body.get("pre_start_bar") != body.get("post_start_bar"),
         "the region moved to the playhead and was verified against the SAME region it started "
         "with, driven entirely through Logic's Korean menus — which is #519's outstanding "
         "acceptance criterion",
         f"state={body.get('state')!r} verified={body.get('verified')!r} "
         f"{body.get('region_name')!r} track {body.get('pre_track_index')!r} bar "
         f"{body.get('pre_start_bar')!r} -> {body.get('post_start_bar')!r} "
         f"(playhead {body.get('playhead_bar')!r})",
         "hard-code \"Edit\" as the menu-bar name again: the drive cannot find the menu on a Korean "
         "Logic and the operation returns State C, which is the defect this issue is about")

d.close()

# ---- put the machine back ------------------------------------------------------------------------

quit_logic()
set_language(original_languages[0])
launch_logic()
dismiss_single_button_alert()
restored_bar_items = menu_bar_items()
ev.stop_recording(rec)

ev.restored("519/logic-is-back-in-its-original-language",
            any(b == "Edit" for b in restored_bar_items) if original_languages[0] == "en"
            else bool(restored_bar_items),
            f"AppleLanguages restored to {original_languages!r} and Logic relaunched; its menu bar "
            f"now reads {restored_bar_items!r}. The check is the menu bar read back from Logic, not "
            f"the setting this run wrote. The scratch project it created is discarded at the save "
            f"prompt during the final quit; no other project is touched.")

out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
