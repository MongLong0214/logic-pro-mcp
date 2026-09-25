#!/usr/bin/env python3
"""Live proof that each track type is created, and no sheet is left behind, in every Logic language.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        /usr/bin/python3 live_883_each_track_type_in_every_locale.py <worktree> <full-40-char-head-sha> \
        [lproj ...]

WHAT #883 REPORTED
------------------
A German Logic stopped in its New Track sheet: the requested track was not created, the sheet stayed
open, and every later operation was blocked until a person cleared it. Its "done when" asks for a
clean German session creating each supported type through MCP, the sheet closing, the response
identifying the created track, and failure leaving no sheet behind.

WHAT THIS RUN DOES
------------------
For each language it quits Logic, switches its UI language (`AppleLanguages` for com.apple.logic10),
cold-launches it with no document, and follows the report: `project.new`, then
`track.create_instrument`, `track.create_drummer`, `track.create_external_midi` and
`track.create_audio` through the release binary, in the one new project. After each call it asks
three things, of three different paths:

- the envelope: State A and `verified: true`;
- System Events, which the product does not use: no sheet and no dialog is up;
- the product's own track readback: exactly one track was inserted, and the response names it.

`project.new` gets the System Events question too. It raises the mandatory New Track sheet and
confirms it itself, through the same Create button the drummer's sheet is confirmed with; that is
where the first run of this harness found Spanish failing.

The new project is discarded when Logic quits for the next language. At the end the original
language is restored and Logic relaunched on the locale-campaign fixture, confirmed by the arrange
window's title rather than by the setting written.

WHY THE LANGUAGE CHECK IS APPLE'S STRING
----------------------------------------
Whether Logic really came up in the requested language is read off the arrange window's title,
whose suffix is the `Tracks` row of Apple's own `Localizable.strings` for that locale, parsed out of
the installed bundle here. It is not a LabelSet: a run that proved a German Logic from the
product's own German would be the product agreeing with itself.

WHAT IT DOES NOT CLAIM
----------------------
It does not prove the TYPE of the created track. The track rail cannot tell the types apart
(#766), and the inspector's channel strip tells only audio and external MIDI from the instrument
family; the response's `observed_track_type` and its source are recorded per language as notes. The
four operations are told apart by `Issue883TrackCreationAsRenderedTests`, which drives each against the
menu as a German Logic renders it. The Track menu's titles are recorded here too, as read through
System Events, so a language whose rendering differs from the policy is visible in the evidence.
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
    "Sources/LogicProMCP/Channels/AccessibilityChannel+Tracks.swift",
    "Sources/LogicProMCP/Channels/AccessibilityChannel+ModalReconcile.swift",
    "Sources/LogicProMCP/Accessibility/ModalReconciliation.swift",
    "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift",
]

FIXTURE = os.path.expanduser("~/Music/Logic/lpm-locale-campaign.logicx")
FIXTURE_NAME = os.path.splitext(os.path.basename(FIXTURE))[0]
LAUNCH_TIMEOUT = 150.0
APP = "/Applications/Logic Pro.app"
STRINGS = (APP + "/Contents/Frameworks/Logic.framework/Versions/A/Resources/%s.lproj/"
           "Localizable.strings")

#: (bundle lproj, AppleLanguages code). The lproj names are the ten Logic ships.
LOCALES = [("en", "en"), ("ko", "ko"), ("ja", "ja"), ("de", "de"), ("es", "es"), ("fr", "fr"),
           ("it", "it"), ("pt", "pt-BR"), ("zh_CN", "zh-CN"), ("zh_TW", "zh-TW")]

OPS = ["create_instrument", "create_drummer", "create_external_midi", "create_audio"]

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)
ONLY = set(sys.argv[3:])

E.REPO = WT
E.BIN = os.environ.get("LPM_BINARY") or f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

sys.path.insert(0, os.path.join(WT, "Scripts"))
import logic_canon  # noqa: E402

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")


def osa(script, timeout=20):
    try:
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    return (r.stdout or "").strip()


def apple_string(lproj, key):
    with open(STRINGS % lproj, "rb") as handle:
        return logic_canon.parse_strings(handle.read()).get(key)


def logic_running():
    return osa('tell application "System Events" to return (count of (every process whose '
               'name is "Logic Pro"))') == "1"


def window_names():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'get name of every window')
    return [] if not raw else [part.strip() for part in raw.split(", ")]


def blocking_counts():
    """(sheets on any window, AXDialog windows), read through System Events."""
    raw = osa('''tell application "System Events" to tell process "Logic Pro"
  set n to 0
  repeat with w in every window
    set n to n + (count of sheets of w)
  end repeat
  return (n as string) & "," & ((count of (windows whose subrole is "AXDialog")) as string)
end tell''')
    try:
        sheets, dialogs = (int(part) for part in raw.split(","))
    except (AttributeError, ValueError):
        return None
    return sheets, dialogs


def track_menu_titles(bar):
    raw = osa('tell application "System Events" to tell process "Logic Pro" to get name of '
              f'every menu item of menu 1 of menu bar item "{bar}" of menu bar 1')
    return None if raw is None else raw.split(", ")[:6]


def press_discard():
    """Answer a save prompt STRUCTURALLY: the button that is neither default nor cancel.

    Matching a localised word here would make a locale harness carry a locale bug. The same helper
    is in `live_876_locale_switch.py`, which borrowed it from `locale-campaign.sh`. The prompt is an
    AXDialog window, not a sheet of the arrange window.
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
    """The autosave-recovery prompt on launch, answered by its default button."""
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


def dismiss_sheets():
    """Escape every sheet still up, and say how many were up.

    A sheet swallows `quit`: the first run of this harness left the Spanish New Track sheet up, and
    the next language's quit failed on it and ended the run with five languages unmeasured. Escape
    on the New Track sheet cancels the untitled project behind it, which this harness would discard
    anyway, so nothing is lost that the quit was not already going to lose.
    """
    first = blocking_counts()
    for _ in range(3):
        counts = blocking_counts()
        if not counts or counts[0] == 0:
            break
        osa('tell application "Logic Pro" to activate')
        osa('tell application "System Events" to key code 53')
        time.sleep(1.5)
    return first


def quit_logic():
    if not logic_running():
        return True
    dismiss_sheets()
    for _ in range(4):
        # `quit` does not return while the save prompt is up, so its timeout is short.
        osa('tell application "Logic Pro" to quit', timeout=8)
        deadline = time.time() + 20
        while logic_running() and time.time() < deadline:
            if press_discard():
                break
            time.sleep(2)
        deadline = time.time() + 20
        while logic_running() and time.time() < deadline:
            time.sleep(2)
        if not logic_running():
            return True
    return not logic_running()


def launch(document=None, title=None):
    """Launch Logic, on `document` if given, and wait for a window (named `title` if given)."""
    subprocess.run(["open", "-a", APP] + ([document] if document else []), capture_output=True)
    deadline = time.time() + LAUNCH_TIMEOUT
    while time.time() < deadline:
        names = window_names()
        if names and (title is None or title in names):
            return names
        if title is not None:
            press_default_button()
        time.sleep(3)
    return None


def set_language(codes):
    subprocess.run(["defaults", "write", "com.apple.logic10", "AppleLanguages", "-array", *codes],
                   capture_output=True)


def language_setting():
    raw = subprocess.run(["defaults", "read", "com.apple.logic10", "AppleLanguages"],
                         capture_output=True, text=True).stdout
    return re.findall(r"[\w-]+", raw)


def tracks(d):
    """A `select` forces a live AX read; without it the resource answers with synthesised names."""
    d.tool("logic_tracks", "select", {"index": 0})
    return d.resource("logic://tracks").get("data", []) or []


def settled_after(d, before, named, seconds=12.0):
    """Read the rail until it shows one inserted track named `named`, or until `seconds` pass.

    `logic://tracks` answers from a cache a poller fills, so one read right after a create can
    predate it. The first run read once (with one retry on a name mismatch) and failed six checks on
    readbacks that had not caught up: the drummer's `SoCal` was missing after its create and then
    appeared beside the NEXT operation's track. Waiting for agreement does not lower the bar. The
    judgment is still made on the readback, and a rail that never agrees inside the window fails.
    """
    deadline = time.time() + seconds
    while True:
        after = tracks(d)
        new = inserted_track(before, after)
        if (new is not None and new.get("name") == named) or len(after) > len(before) + 1:
            return after
        if time.time() >= deadline:
            return after
        time.sleep(1.0)


def inserted_track(before, after):
    """The one track whose removal turns `after` back into `before`, or None.

    Logic inserts a new track below the selected one, so every track after it moves down one index
    and an (id, name) difference reports all of them as new. Comparing the sequences with one entry
    removed finds the inserted row wherever it landed.
    """
    if len(after) != len(before) + 1:
        return None
    key = [t.get("name") for t in before]
    for i, track in enumerate(after):
        if [t.get("name") for t in after[:i] + after[i + 1:]] == key:
            return track
    return None


original = language_setting()
ev.note("883/original-language", {"AppleLanguages": original})
original_lproj = next((lproj for lproj, code in LOCALES if [code] == original), None)

summary = {}
for lproj, code in LOCALES:
    if ONLY and lproj not in ONLY:
        continue
    suffix = apple_string(lproj, "Tracks")
    bar = apple_string(lproj, "Track#mti")
    tag = f"883/{lproj}"
    if logic_running():
        left = dismiss_sheets()
        if left and left[0]:
            ev.note(f"{tag}/sheets-escaped-before-quit", {"sheets_and_dialogs": left})
    if not quit_logic():
        ev.check(f"{tag}/logic-quit", False, "Logic quits before the language switch",
                 f"still running; windows={window_names()!r}", None)
        break
    set_language([code])
    launched = launch()
    time.sleep(4)

    d = E.Driver()
    tracks(d)  # the first read of a new server can answer before the rail is read at all
    created = d.tool("logic_project", "new", {})
    time.sleep(6)
    names = window_names()
    arrange = [n for n in names if n.endswith(f" - {suffix}")]
    ok_lang = len(arrange) == 1
    ev.check(f"{tag}/a-new-project-is-open-in-this-language", ok_lang,
             f"one arrange window whose title ends with ' - {suffix}', Apple's `Tracks` for {lproj}",
             f"launched={launched!r} windows={names!r} "
             f"project_new={ {k: created.get(k) for k in ('state', 'reason', 'error')} !r}", None)
    if not ok_lang:
        summary[lproj] = "no new project in this language"
        d.close()
        continue
    blocking = blocking_counts()
    ev.check(f"{tag}/project-new-leaves-no-sheet", blocking == (0, 0),
             "System Events reports no sheet and no dialog after project.new",
             f"sheets_and_dialogs={blocking!r}", None)
    ev.note(f"{tag}/track-menu", {"bar": bar, "titles": track_menu_titles(bar)})

    results = []
    for op in OPS:
        before = tracks(d)
        body = d.tool("logic_tracks", op)
        time.sleep(2.0)
        blocking = blocking_counts()
        body = body if isinstance(body, dict) else {}
        named = body.get("observed_track_name")
        after = settled_after(d, before, named)
        new = inserted_track(before, after)
        brief = {k: body.get(k) for k in ("state", "verified", "reason", "error", "failure_stage",
                                          "menu_clicked", "method", "observed_track_name",
                                          "observed_track_type", "track_type_verification_source",
                                          "reconciled_modal_kind", "new_track_dialog_auto_confirmed")
                 if k in body}
        ev.note(f"{tag}/{op}/response", {"body": body})
        ev.check(f"{tag}/{op}/envelope-is-state-a",
                 body.get("state") == "A" and body.get("verified") is True,
                 "State A with verified true", f"{brief!r}", None)
        ev.check(f"{tag}/{op}/no-sheet-or-dialog-is-left", blocking == (0, 0),
                 "System Events reports no sheet and no dialog after the call",
                 f"sheets_and_dialogs={blocking!r}", None)
        ev.check(f"{tag}/{op}/exactly-one-track-was-inserted-and-the-response-names-it",
                 new is not None and named == new.get("name"),
                 "one track inserted in the readback, and the response's observed_track_name is its name",
                 f"before={[t.get('name') for t in before]!r} after={[t.get('name') for t in after]!r} "
                 f"inserted={None if new is None else new.get('name')!r} named={named!r}", None)
        results.append(brief)
        if blocking != (0, 0):
            # A sheet left up blocks every later call; the next result would be a reading of it.
            ev.note(f"{tag}/{op}/stopped", {"reason": "a sheet or dialog was left up",
                                            "sheets_and_dialogs": blocking})
            break
    d.close()
    summary[lproj] = results

# ---- restore the language this machine had, and confirm it from the window title ----
restored_ok = False
detail = "no original language to restore"
if original:
    quit_logic()
    set_language(original)
    back_suffix = apple_string(original_lproj or "en", "Tracks")
    names = launch(FIXTURE, f"{FIXTURE_NAME} - {back_suffix}")
    restored_ok = names is not None and language_setting() == original
    detail = f"AppleLanguages={language_setting()!r} windows={names!r}"
ev.restored("883/original-language-restored", restored_ok, detail)

ev.note("883/summary", summary)
out = ev.write()
print(json.dumps({"summary": summary, "clean": E.is_clean(out)}, indent=1, ensure_ascii=False))
sys.exit(0 if E.is_clean(out) else 1)
