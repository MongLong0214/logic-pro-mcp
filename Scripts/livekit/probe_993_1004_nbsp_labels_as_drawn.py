#!/usr/bin/env python3
"""Read which space character a running Logic draws in three labels, per language (#993, #1004).

Usage:  /usr/bin/python3 probe_993_1004_nbsp_labels_as_drawn.py <worktree> <out.json> <scratch-dir> \
        [lproj ...]        (default: de es fr ko)

WHAT IS ASKED
-------------
Apple ships some rows with U+00A0 (no-break space) where an ordinary space would look the same, and a
`LabelSet` compares exactly, so a member holding one spelling does not match the other. Which one
Logic DRAWS is not in the bundle; it can only be read off the running application. #883 found a
German Track-menu leaf drawn with U+0020 where Apple's row has U+00A0, so the row alone does not say.

Three items, each read as `AXTitle` together with its raw Unicode scalars:

- `controlSurfaceInstallMenuItem` (#1004): the first item of the Control Surface Setup window's own
  `New` menu. Apple's German row is `Installieren …`, with U+00A0 before the ellipsis.
- `pluginMenuAudioUnits` (#993): the `Audio Units` item of the plug-in menu an empty audio-effect
  slot opens. Apple's Spanish row has U+00A0.
- `stemExportProgressWindowTitle` (#993): the title of the window Logic shows while File > Export >
  All Tracks as Audio Files… runs. Apple's `Logic Pro` row has U+00A0 in de, es, fr and ko.

HOW EACH IS REACHED, AND WHAT IS NOT JUDGED
-------------------------------------------
Every label used to FIND an element comes from `AXLocalePolicy` (through `evidence.label_set`) or
from Apple's bundle -- the slot's description is MAMixer's `audio plug-in` row for the language.
Navigation folds U+00A0 into U+0020 (`fold_nbsp`), because a menu path whose German member holds one
character must not stop the walk before the item being measured. The READING is never folded: the
title is printed as Logic returned it, scalar by scalar, and this file decides nothing about it.

The progress window lives only while the export runs. The export is sent to `<scratch-dir>`, a
watcher polls the window list every 20 ms from before the press, the window list is also read once
while the export runs, and the export is then cancelled with Command-period -- the key the window
itself names, since it has no button. Whatever the export wrote is deleted, and the directory is
listed afterwards so the deletion is read back rather than assumed.

LANGUAGE SWITCHING
------------------
The same way #883's harness `live_883_each_track_type_in_every_locale.py` does it, with its helpers
copied here, since that harness is not on this branch: quit Logic,
write `AppleLanguages` for com.apple.logic10, relaunch on the locale-campaign fixture, and prove the
language from the arrange window's title, whose suffix is Apple's `Tracks` row for that language.
At the end Korean is restored and Logic relaunched on the fixture, confirmed the same way.

WHAT IT DOES NOT CLAIM
----------------------
It reads one Logic (12.3) on one host. It does not show that any other window or menu draws the
character its row holds. It does not exercise the product: a reading here says what Logic shows,
and `AXLocalePolicyNoBreakSpaceAsDrawnTests` says what the LabelSets match.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time

WT = sys.argv[1] if len(sys.argv) > 1 else ""
OUT = sys.argv[2] if len(sys.argv) > 2 else ""
SCRATCH = sys.argv[3] if len(sys.argv) > 3 else ""
if not WT or not OUT or not SCRATCH or not os.path.isabs(SCRATCH):
    sys.exit(__doc__)
LPROJS = sys.argv[4:] or ["de", "es", "fr", "ko"]

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402

sys.path.insert(0, os.path.join(WT, "Scripts"))
import logic_canon  # noqa: E402

FIXTURE = os.path.expanduser("~/Music/Logic/lpm-locale-campaign.logicx")
FIXTURE_NAME = os.path.splitext(os.path.basename(FIXTURE))[0]
LAUNCH_TIMEOUT = 150.0
APP = "/Applications/Logic Pro.app"
STRINGS = (APP + "/Contents/Frameworks/Logic.framework/Versions/A/Resources/%s.lproj/"
           "Localizable.strings")
MIXER_STRINGS = (APP + "/Contents/Frameworks/MAMixer.framework/Resources/%s.lproj/"
                 "Localizable.strings")
#: lproj -> AppleLanguages code, as the #883 harness writes them.
CODES = {"en": "en", "ko": "ko", "ja": "ja", "de": "de", "es": "es", "fr": "fr", "it": "it",
         "pt": "pt-BR", "zh_CN": "zh-CN", "zh_TW": "zh-TW"}
RESTORE = "ko"
PROBE_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_nbsp_label_probe.swift")
PROBE = os.path.join(SCRATCH, "nbsp_probe")


# -- helpers copied from live_883_each_track_type_in_every_locale.py --------------------------------

def osa(script, timeout=20):
    try:
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    return (r.stdout or "").strip()


def apple_string(lproj, key, table=STRINGS):
    with open(table % lproj, "rb") as handle:
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


def press_discard():
    """Answer a save prompt STRUCTURALLY: the button that is neither default nor cancel."""
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


# -- this probe -------------------------------------------------------------------------------------

def _unescape(text):
    """`evidence.label_set` returns the Swift source text, so `\\u{00A0}` arrives as six characters."""
    return re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), text)


def labels(name):
    found = E.label_set(name, repo=WT)
    if not found:
        sys.exit(f"cannot run: AXLocalePolicy has no LabelSet {name}")
    return [_unescape(text) for text in found]


def folded(text):
    return (text or "").replace("\u00a0", " ").strip().casefold()


def probe(mode, spec=None, timeout=90):
    args = [PROBE, mode] + ([json.dumps(spec, ensure_ascii=False)] if spec is not None else [])
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"outcome": "probe_timeout", "mode": mode}
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"outcome": "probe_output_unreadable", "mode": mode, "stderr": r.stderr[-400:]}


def activate():
    osa('tell application "Logic Pro" to activate')
    time.sleep(1.0)


def row(surface, path, reading):
    """A census-shaped row: what `locale-propose.py` reads, plus the scalars it does not."""
    return {"surface": surface, "path": path, "role": reading.get("role"),
            "subrole": reading.get("subrole"), "title": reading.get("title"),
            "title_scalars": reading.get("title_scalars"), "description": None, "help": None,
            "value": None, "identifier": None}


def menus_left_open(pressed):
    """What the probe read back after cancelling; Escape once more if a menu is still up."""
    left = pressed.get("menus_open_after_cancel")
    if left:
        activate()
        osa('tell application "System Events" to key code 53')
        time.sleep(0.8)
    return left


def read_setup_install(lproj):
    out = {"item": "controlSurfaceInstallMenuItem"}
    setup_titles = labels("controlSurfaceSetupWindowTitle")
    activate()
    opened = probe("press-menu-path", {
        "path": [labels("applicationMenuBarItem"), labels("controlSurfacesMenuItem"),
                 labels("controlSurfaceSetupMenuItem")],
        "expect_window": setup_titles, "fold_nbsp": True})
    out["open_setup"] = opened.get("outcome")
    if opened.get("outcome") not in ("pressed", "already_open"):
        out["trail"] = opened.get("trail")
        return out
    setup_title = next((w["title"] for w in opened.get("windows_after", [])
                        if folded(w.get("title")) in {folded(t) for t in setup_titles}), None)
    menu = probe("press-and-read", {"role": "AXMenuButton", "attribute": "AXDescription",
                                    "equals": labels("controlSurfaceNewMenuButton"), "index": 0,
                                    "cancel": True})
    out["menu_outcome"] = menu.get("outcome")
    out["new_button"] = menu.get("pressed")
    out["press_rc"] = menu.get("press_rc")
    wanted = {folded(t) for t in labels("controlSurfaceInstallMenuItem")}
    items = next((m["items"] for m in menu.get("open_menus_after") or []
                  if any(folded(i.get("title")) in wanted for i in m["items"])), None)
    out["menu_items"] = items
    if items:
        hit = next(i for i in items if folded(i.get("title")) in wanted)
        new_label = (menu.get("pressed") or {}).get("description")
        out["reading"] = row("system.midi",
                             f"AXWindow[{setup_title}]/AXMenuButton{{{new_label}}}/AXMenu/"
                             f"AXMenuItem[{hit.get('title')}]", hit)
    out["menus_open_after_cancel"] = menus_left_open(menu)
    out["close_setup"] = probe("close-window", {"title": setup_titles, "fold_nbsp": True}).get("outcome")
    return out


def read_plugin_menu(lproj):
    out = {"item": "pluginMenuAudioUnits"}
    slot = apple_string(lproj, "audio plug-in", MIXER_STRINGS)
    out["slot_description"] = slot
    activate()
    menu = probe("press-and-read", {"role": "AXButton", "attribute": "AXDescription",
                                    "equals": [slot], "min_height": 12.0, "index": 0,
                                    "cancel": True})
    out["menu_outcome"] = menu.get("outcome")
    out["slot_candidates"] = len(menu.get("candidates") or [])
    out["press_rc"] = menu.get("press_rc")
    wanted = {folded(t) for t in labels("pluginMenuAudioUnits")}
    items = next((m["items"] for m in menu.get("open_menus_after") or []
                  if any(folded(i.get("title")) in wanted for i in m["items"])), None)
    out["menu_items"] = [{"title": i.get("title"), "title_scalars": i.get("title_scalars"),
                          "role": i.get("role")} for i in (items or [])]
    if items:
        hit = next(i for i in items if folded(i.get("title")) in wanted)
        out["reading"] = row("mixer.inserts",
                             f"AXButton{{{slot}}}/AXMenu/AXMenuItem[{hit.get('title')}]", hit)
    out["menus_open_after_cancel"] = menus_left_open(menu)
    return out


def _dialogs():
    return [w for w in probe("windows").get("windows") or [] if w.get("subrole") == "AXDialog"]


def read_stem_progress(lproj):
    out = {"item": "stemExportProgressWindowTitle"}
    dest = os.path.join(SCRATCH, f"stems-{lproj}")
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest)
    activate()
    opened = probe("press-menu-path", {
        "path": [labels("fileMenuBar"), labels("exportMenuItem"),
                 labels("allTracksAsAudioFilesMenuItem")], "fold_nbsp": True})
    out["open_export"] = opened.get("outcome")
    if opened.get("outcome") != "pressed":
        out["trail"] = opened.get("trail")
        return out
    commit = {"role": "AXButton", "attribute": "AXTitle",
              "equals": labels("stemExportCommitButton"), "depth": 4, "index": 0, "fold_nbsp": True}
    # A running transport puts up a dialog first that asks for playback to stop; its own default
    # button stops it and goes on. The export panel is told apart by its `One File per Track` popup,
    # not by the Export button both of them carry, so the panel itself is never default-pressed.
    per_track = {"role": "AXPopUpButton", "attribute": "AXValue",
                 "equals": labels("oneFilePerTrackPopupValue"), "depth": 4, "fold_nbsp": True}
    panel = False
    for _ in range(12):
        time.sleep(0.8)
        if probe("candidates", per_track).get("candidates"):
            panel = True
            break
        if _dialogs():
            pressed = probe("press-default")
            if pressed.get("outcome") == "pressed":
                out.setdefault("pre_panel_dialogs", []).append(
                    {"button": pressed.get("button"), "text": pressed.get("panel_text")})
    out["panel_open"] = panel
    if not panel:
        return out
    activate()
    osa('tell application "System Events" to keystroke "g" using {command down, shift down}')
    time.sleep(1.5)
    field = probe("set-sheet-field", {"value": dest + "/"})
    if field.get("outcome") != "set":
        osa('tell application "System Events" to keystroke "/"')
        time.sleep(1.5)
        field = probe("set-sheet-field", {"value": dest + "/"})
    out["destination_field"] = field
    osa('tell application "System Events" to key code 36')
    time.sleep(1.5)
    if field.get("outcome") != "set" or probe("sheets").get("sheets"):
        out["refused"] = "the export panel's destination could not be set; nothing was exported"
        activate()
        osa('tell application "System Events" to key code 53')
        time.sleep(1.0)
        osa('tell application "System Events" to key code 53')
        return out
    watch_path = os.path.join(SCRATCH, f"watch-{lproj}.json")
    with open(watch_path, "w") as sink:
        watcher = subprocess.Popen([PROBE, "watch-windows", json.dumps(
            {"seconds": 10, "interval_ms": 20, "contains": []})], stdout=sink)
        try:
            time.sleep(1.0)
            out["export_press"] = probe("press", commit, timeout=30)
            time.sleep(3.0)
            out["windows_during_export"] = probe("windows", timeout=30).get("windows")
            out["files_during_export"] = len(os.listdir(dest))
        finally:
            # Cancelled whatever happened above: an export left running fills the disk.
            out["cancel"] = [probe("cancel-bounce", timeout=30).get("outcome")]
            try:
                watcher.wait(timeout=60)
            except subprocess.TimeoutExpired:
                watcher.kill()
                out["watcher_killed"] = True
    with open(watch_path) as handle:
        try:
            watched = json.load(handle)
        except ValueError:
            watched = {}
    out["watch"] = {"polls": watched.get("polls"), "interval_ms": watched.get("interval_ms"),
                    "titles": watched.get("titles")}
    for attempt in range(10):
        if not _dialogs():
            break
        if attempt in (3, 6):
            out["cancel"].append(probe("cancel-bounce", timeout=30).get("outcome"))
        time.sleep(1.0)
    out["dialogs_after_cancel"] = [w.get("title") for w in _dialogs()]
    shutil.rmtree(dest, ignore_errors=True)
    out["export_directory_exists_after_cleanup"] = os.path.exists(dest)
    arrange = [w.get("title") for w in probe("windows").get("windows") or []]
    progress = [w for w in out.get("windows_during_export") or []
                if w.get("title") not in arrange and w.get("subrole") == "AXDialog"]
    if len(progress) == 1:
        out["reading"] = row("project.export", f"AXWindow[{progress[0].get('title')}]", progress[0])
    return out


def switch_to(lproj):
    suffix = apple_string(lproj, "Tracks")
    title = f"{FIXTURE_NAME} - {suffix}"
    if language_setting()[:1] == [CODES[lproj]] and title in (window_names() or []):
        return {"switched": False, "arrange_window": title}
    if not quit_logic():
        return {"error": "Logic did not quit"}
    set_language([CODES[lproj]])
    names = launch(FIXTURE, title)
    time.sleep(4)
    return {"switched": True, "arrange_window": title if names else None, "windows": names}


def host_block():
    r = subprocess.run([sys.executable, os.path.join(WT, "Scripts", "observation_host.py")],
                       capture_output=True, text=True)
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": r.stderr[-300:]}


def main():
    os.makedirs(SCRATCH, exist_ok=True)
    built = subprocess.run(["swiftc", "-O", PROBE_SOURCE, "-o", PROBE], capture_output=True,
                           text=True)
    if built.returncode != 0:
        sys.exit(f"probe did not build: {built.stderr[-600:]}")
    result = {"readings": {}}
    for lproj in LPROJS:
        entry = {"language": switch_to(lproj)}
        if not entry["language"].get("arrange_window"):
            entry["error"] = "the fixture did not come up in this language; nothing was read"
            result["readings"][lproj] = entry
            continue
        entry["host"] = host_block()
        entry["windows_before"] = [w.get("title") for w in probe("windows").get("windows") or []]
        entry["setup_install"] = read_setup_install(lproj)
        entry["plugin_menu"] = read_plugin_menu(lproj)
        entry["stem_progress"] = read_stem_progress(lproj)
        result["readings"][lproj] = entry
        with open(OUT, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=1)
    restored = switch_to(RESTORE)
    result["restored"] = {"language_setting": language_setting(), "launch": restored,
                          "window_names": window_names()}
    with open(OUT, "w", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=1)
    print(json.dumps({lproj: {k: (v.get("reading") or {}).get("title_scalars")
                              for k, v in entry.items() if isinstance(v, dict) and "item" in v}
                      for lproj, entry in result["readings"].items()}, ensure_ascii=False))
    print(json.dumps(result["restored"], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
