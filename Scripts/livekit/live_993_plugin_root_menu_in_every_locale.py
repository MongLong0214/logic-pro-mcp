#!/usr/bin/env python3
"""Live proof that `insert_plugin` reaches Gain through the plug-in root menu in every locale.

Usage: /usr/bin/python3 Scripts/livekit/live_993_plugin_root_menu_in_every_locale.py \
       <worktree> <full-40-char-head> <binary> [--control <control-binary>] [lproj ...]
       (default lprojs: en ko ja de es fr it pt zh_CN zh_TW; caller sets LPM_EVIDENCE_ROOT)

WHAT IS ASKED AND HOW IT IS READ
--------------------------------
Logic is quit, switched and relaunched on the locale-campaign fixture as in the #993/#1004 probe.
The AppleLanguages setting and Apple's `Tracks` window title read the language back. In each language
the product's `logic://mixer` finds a strip with a free insert 0. `logic_mixer.insert_plugin` asks for
Gain; another mixer read must show Gain at the response's slot. Logic's own Edit > Undo is clicked,
and a third mixer read must show the strip's original plug-in chain. An optional control binary gets
the same operation on the same Logic immediately after the candidate. The evidence document keeps
the complete response and mixer readings for both. Korean is restored and read back at the end.

WHAT IS NOT JUDGED
------------------
The control's zh_TW refusal is diagnostic, not a pass condition: if it inserts too, the defect did
not reproduce in this run. This measures one Logic installation and this fixture; it does not claim
that other projects or Logic builds have the same menu shape. No result is inferred from the tool's
`verified` flag alone: the mixer readback and the undo readback decide the verdict.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import evidence as E  # noqa: E402


COVERS = [
    "Sources/LogicProMCP/Channels/AccessibilityChannel+Plugins.swift",
    "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift",
]

DEFAULT_LPROJS = ("en", "ko", "ja", "de", "es", "fr", "it", "pt", "zh_CN", "zh_TW")
CODES = {"en": "en", "ko": "ko", "ja": "ja", "de": "de", "es": "es", "fr": "fr",
         "it": "it", "pt": "pt-BR", "zh_CN": "zh-CN", "zh_TW": "zh-TW"}
APP = "/Applications/Logic Pro.app"
STRINGS = (APP + "/Contents/Frameworks/Logic.framework/Versions/A/Resources/%s.lproj/"
           "Localizable.strings")
FIXTURE = os.path.expanduser("~/Music/Logic/lpm-locale-campaign.logicx")
FIXTURE_NAME = os.path.splitext(os.path.basename(FIXTURE))[0]
RESTORE = "ko"
LAUNCH_TIMEOUT = 150.0
READ_TIMEOUT = 20.0


def arguments():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     usage="%(prog)s <worktree> <full-40-char-head> <binary> "
                                           "[--control <control-binary>] [lproj ...]")
    parser.add_argument("worktree")
    parser.add_argument("head")
    parser.add_argument("binary")
    parser.add_argument("--control", metavar="control-binary")
    parser.add_argument("lprojs", nargs="*")
    if len(sys.argv) == 1:
        parser.error("worktree, head and binary are required")
    # Intermixed, because the usage puts lprojs after `--control`: plain parse_args binds the
    # optional positional with the three before it and then refuses every lproj that follows.
    args = parser.parse_intermixed_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.head):
        parser.error("head must be a full lowercase 40-character SHA")
    if not os.path.isdir(args.worktree):
        parser.error("worktree does not exist")
    for path in (args.binary, args.control):
        if path and not os.access(path, os.X_OK):
            parser.error(f"binary is not executable: {path}")
    args.lprojs = args.lprojs or list(DEFAULT_LPROJS)
    unknown = [name for name in args.lprojs if name not in CODES]
    if unknown:
        parser.error(f"unknown lproj(s): {', '.join(unknown)}")
    if not os.environ.get("LPM_EVIDENCE_ROOT"):
        parser.error("LPM_EVIDENCE_ROOT must be set by the caller")
    return args


def osa(script, timeout=20):
    try:
        result = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True,
                                text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    return (result.stdout or "").strip() if result.returncode == 0 else None


def apple_string(lproj, key):
    # The Edit menu's Apple row is `Edit#mti` in Logic.framework/Localizable.strings, also cited
    # by AXLocalePolicy.editMenuBar. Resolving the per-locale row avoids guessing a translation.
    with open(STRINGS % lproj, "rb") as handle:
        return logic_canon.parse_strings(handle.read()).get(key)


def language_setting():
    result = subprocess.run(["defaults", "read", "com.apple.logic10", "AppleLanguages"],
                            capture_output=True, text=True)
    return re.findall(r"[\w-]+", result.stdout) if result.returncode == 0 else []


def logic_running():
    return osa('tell application "System Events" to return (count of (every process whose '
               'name is "Logic Pro"))') == "1"


def window_names():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'get name of every window')
    return [] if not raw else [part.strip() for part in raw.split(", ")]


def blocking_counts():
    raw = osa('''tell application "System Events" to tell process "Logic Pro"
  set n to 0
  repeat with w in every window
    set n to n + (count of sheets of w)
  end repeat
  return (n as string) & "," & ((count of (windows whose subrole is "AXDialog")) as string)
end tell''')
    try:
        return tuple(int(part) for part in raw.split(","))
    except (AttributeError, ValueError):
        return None


def press_discard():
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


def dismiss_sheets():
    first = blocking_counts()
    for _ in range(3):
        counts = blocking_counts()
        if not counts or counts[0] == 0:
            break
        osa('tell application "Logic Pro" to activate')
        osa('tell application "System Events" to key code 53')
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and (blocking_counts() or (0, 0))[0] > 0:
            time.sleep(0.25)
    return first


def quit_logic():
    if not logic_running():
        return True
    dismiss_sheets()
    for _ in range(4):
        osa('tell application "Logic Pro" to quit', timeout=8)
        deadline = time.monotonic() + 20
        while logic_running() and time.monotonic() < deadline:
            if press_discard():
                break
            time.sleep(0.5)
        deadline = time.monotonic() + 20
        while logic_running() and time.monotonic() < deadline:
            time.sleep(0.5)
        if not logic_running():
            return True
    return not logic_running()


def launch(document, title):
    subprocess.run(["open", "-a", APP, document], capture_output=True)
    deadline = time.monotonic() + LAUNCH_TIMEOUT
    while time.monotonic() < deadline:
        names = window_names()
        if title in names:
            return names
        press_default_button()
        time.sleep(0.5)
    return None


def switch_to(lproj, force=False):
    suffix = apple_string(lproj, "Tracks")
    if not suffix:
        return {"error": "Apple's Tracks row did not resolve"}
    title = f"{FIXTURE_NAME} - {suffix}"
    if not force and language_setting()[:1] == [CODES[lproj]] and title in window_names():
        return {"switched": False, "arrange_window": title,
                "language_setting": language_setting(), "window_names": window_names()}
    if not quit_logic():
        return {"error": "Logic did not quit", "language_setting": language_setting()}
    written = subprocess.run(["defaults", "write", "com.apple.logic10", "AppleLanguages",
                              "-array", CODES[lproj]], capture_output=True, text=True)
    if written.returncode != 0:
        return {"error": "AppleLanguages write failed", "stderr": written.stderr[-300:]}
    names = launch(FIXTURE, title)
    return {"switched": True, "arrange_window": title if names else None,
            "language_setting": language_setting(), "window_names": names}


def strip(mixer, track):
    return next((row for row in mixer.get("strips") or [] if row.get("trackIndex") == track), None)


def plugins(row):
    return (row or {}).get("plugins") or []


def plugin_chain(row):
    return [(p.get("index"), p.get("name")) for p in plugins(row)]


def plugin_at(row, slot):
    return next((p for p in plugins(row) if p.get("index") == slot), None)


def read_mixer_until(driver, predicate, timeout=READ_TIMEOUT):
    """Force a poll, then read the resource until its strip state answers or the bound expires."""
    deadline = time.monotonic() + timeout
    latest = {}
    while True:
        driver.tool("logic_system", "refresh_cache")
        latest = driver.resource("logic://mixer") or {}
        if latest.get("data_source") == "ax_poll" and predicate(latest):
            return latest, True
        if time.monotonic() >= deadline:
            return latest, False
        time.sleep(0.5)


def undo_and_verify(driver, track, before, edit_name):
    # #855's menu-only undo path; the title is Apple's per-language `Edit#mti` row above.
    quoted = '"' + edit_name.replace("\\", "\\\\").replace('"', '\\"') + '"'
    script = ('tell application "Logic Pro" to activate\n'
              'tell application "System Events" to tell process "Logic Pro"\n'
              f'  click menu item 1 of menu 1 of menu bar item {quoted} of menu bar 1\n'
              'end tell')
    try:
        action = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True,
                                text=True, timeout=60)
        undo_exit, undo_stderr = action.returncode, action.stderr[-300:]
    except subprocess.TimeoutExpired:
        undo_exit, undo_stderr = None, "Edit-menu undo timed out"
    original = plugin_chain(strip(before, track))
    after, verified = read_mixer_until(
        driver, lambda mixer: strip(mixer, track) is not None
        and isinstance(strip(mixer, track).get("plugins"), list)
        and plugin_chain(strip(mixer, track)) == original)
    return {"edit_menu": edit_name, "undo_exit": undo_exit,
            "undo_stderr": undo_stderr, "mixer_after_undo": after,
            "verified": undo_exit == 0 and verified}


def run_binary(binary, edit_name, preferred_track=None):
    driver = E.Driver(binary=binary)
    try:
        before, fresh = read_mixer_until(driver, lambda mixer: bool(mixer.get("strips")))
        available = [row.get("trackIndex") for row in before.get("strips") or []
                     if isinstance(row.get("trackIndex"), int)
                     and isinstance(row.get("plugins"), list)
                     and plugin_at(row, 0) is None]
        tracks = [preferred_track] if preferred_track in available else available
        result = {"mixer_before": before, "mixer_before_fresh": fresh,
                  "free_slot_zero_tracks": available, "attempts": []}
        if not fresh or not tracks:
            result["error"] = "no fresh mixer with a free insert slot 0"
            return result
        # A free mono strip can refuse Gain without a named channel configuration (#871). The
        # fixture also has stereo strips, so walk free strips until one answers; keep every refusal.
        for track in tracks[:6]:
            before_track, still_free = read_mixer_until(
                driver, lambda mixer: strip(mixer, track) is not None
                and plugin_at(strip(mixer, track), 0) is None)
            if not still_free:
                result["attempts"].append({"track": track, "error": "slot 0 ceased to be free",
                                           "mixer_before": before_track})
                continue
            response = driver.tool("logic_mixer", "insert_plugin", {
                "track": track, "slot": 0, "plugin_name": "Gain", "confirmed": True,
            }) or {}
            response_slot = response.get("slot")
            slot = response_slot if isinstance(response_slot, int) and response_slot >= 0 else 0
            after, gain_seen = read_mixer_until(
                driver,
                lambda mixer: (plugin_at(strip(mixer, track), slot) or {}).get("name") == "Gain"
                or response.get("state") != "A",
                timeout=READ_TIMEOUT if response.get("state") == "A" else 3.0)
            gain_at_slot = (plugin_at(strip(after, track), slot) or {}).get("name") == "Gain"
            attempt = {"track": track, "mixer_before": before_track,
                       "response": response, "response_slot": response_slot,
                       "mixer_after": after,
                       "gain_seen_at_response_slot": gain_seen and gain_at_slot
                       and isinstance(response_slot, int) and response_slot == 0}
            if gain_at_slot:
                undo = undo_and_verify(driver, track, before_track, edit_name)
                attempt.update(undo)
                attempt["undo_verified"] = undo["verified"]
            else:
                attempt["undo_verified"] = None
            attempt["inserted"] = (response.get("state") == "A"
                                   and attempt["gain_seen_at_response_slot"])
            result["attempts"].append(attempt)
            result.update({key: value for key, value in attempt.items() if key != "mixer_before"})
            if attempt["inserted"] or gain_at_slot:
                break
        return result
    finally:
        driver.close()


def main():
    args = arguments()
    global logic_canon
    sys.path.insert(0, os.path.join(args.worktree, "Scripts"))
    import logic_canon  # noqa: E402

    E.REPO = args.worktree
    E.BIN = args.binary
    missing = E.have_tools()
    if missing:
        sys.exit(f"cannot run: missing {missing}")
    ev = E.Evidence(args.head, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")
    edit_labels = E.label_set("editMenuBar", repo=args.worktree) or []
    ev.note("993/edit-menu-label-set", edit_labels)
    recording = ev.record_screen(seconds=max(150, 90 * len(args.lprojs)))
    results = {}
    band, subject, before_shot = None, None, None
    try:
        baseline = switch_to(RESTORE)
        ev.note("993/korean-baseline", baseline)
        if baseline.get("arrange_window"):
            band, subject = ev.located_band("Tracks header")
            if band:
                before_shot = ev.shot("993/korean-fixture-before", settle_region=band,
                                      window_title=baseline["arrange_window"])
        for lproj in args.lprojs:
            entry = {"language": switch_to(lproj), "apple_edit_menu": apple_string(lproj, "Edit#mti")}
            entry["edit_menu_in_label_set"] = entry["apple_edit_menu"] in edit_labels
            valid_language = (entry["language"].get("arrange_window") is not None
                              and entry["language"].get("language_setting", [])[:1]
                              == [CODES[lproj]])
            if not valid_language or not entry["apple_edit_menu"] or not entry["edit_menu_in_label_set"]:
                entry["error"] = "fixture language or Apple's Edit#mti / editMenuBar could not be read"
            else:
                entry["candidate"] = run_binary(args.binary, entry["apple_edit_menu"])
                if args.control:
                    if any(attempt.get("undo_verified") is False
                           for attempt in entry["candidate"].get("attempts", [])):
                        entry["control"] = {"error": "candidate undo was not verified; "
                                                     "control insert was not attempted"}
                    else:
                        entry["control"] = run_binary(args.control, entry["apple_edit_menu"],
                                                       entry["candidate"].get("track"))
                    if lproj == "zh_TW":
                        entry["control_zh_TW_outcome"] = (
                            "control also inserted Gain; defect did not reproduce"
                            if entry["control"].get("inserted") is True else
                            "control did not insert Gain; full response recorded below")
                for label in ("candidate", "control"):
                    for number, attempt in enumerate((entry.get(label) or {}).get("attempts", [])):
                        if attempt.get("undo_verified") is not None:
                            ev.restored(f"993/{lproj}/{label}-attempt-{number}-undone",
                                        attempt["undo_verified"],
                                        f"track={attempt.get('track')} slot={attempt.get('response_slot')}")
            results[lproj] = entry
            ev.note(f"993/{lproj}", entry)
            all_undos = all(attempt.get("undo_verified") is not False
                            for label in ("candidate", "control")
                            for attempt in (entry.get(label) or {}).get("attempts", []))
            ok = (valid_language and (entry.get("candidate") or {}).get("inserted") is True
                  and (entry.get("candidate") or {}).get("undo_verified") is True
                  and all_undos)
            ev.check(f"993/{lproj}/candidate-insert-and-undo", ok,
                     "the candidate inserts Gain at its reported slot and Logic's Edit menu "
                     "undo restores the original strip",
                     {"language": entry["language"], "candidate_inserted":
                      (entry.get("candidate") or {}).get("inserted"),
                      "candidate_undo_verified": (entry.get("candidate") or {}).get("undo_verified"),
                      "all_undos_verified": all_undos},
                     "remove the zh_TW flat Audio Units prefix recognition: Gain cannot reach "
                     "State A there, even though the other nine menu roots can be walked")
            print(json.dumps({"lproj": lproj, "candidate_inserted":
                              (entry.get("candidate") or {}).get("inserted"),
                              "candidate_undo_verified":
                              (entry.get("candidate") or {}).get("undo_verified"),
                              "control_inserted": (entry.get("control") or {}).get("inserted")},
                             ensure_ascii=False), flush=True)
    except Exception as exc:  # Restore the locale even when a driver or AX call fails unexpectedly.
        ev.note("993/harness-exception", repr(exc))
        ev.check("993/harness-completed", False, "all requested locales were read",
                 repr(exc), "a driver exception prevents a complete locale sweep")
    finally:
        try:
            restored = switch_to(RESTORE, force=True)
        except Exception as exc:
            restored = {"error": f"Korean restoration raised: {exc!r}"}
        restored["language_setting_after_restore"] = language_setting()
        restored["window_names_after_restore"] = window_names()
        ev.note("993/korean-restoration", restored)
        ev.restored("993/Logic-language-restored-to-Korean",
                    restored.get("arrange_window") is not None
                    and restored["language_setting_after_restore"][:1] == [CODES[RESTORE]]
                    and restored["arrange_window"] in restored["window_names_after_restore"],
                    repr(restored))
        if before_shot and restored.get("arrange_window"):
            after_shot = ev.shot("993/korean-fixture-after", settle_region=band,
                                 window_title=restored["arrange_window"])
            ev.visual("993/korean-fixture-rail-after-locale-sweep",
                      before_shot["file"], after_shot["file"], band,
                      expect_change=False,
                      why="the locale sweep returned to the Korean fixture and every inserted "
                          "plug-in was checked after Logic's undo",
                      subject=subject)
        ev.stop_recording(recording)
    complete = len(results) == len(args.lprojs) and all(
        (entry.get("candidate") or {}).get("inserted") is True
        and (entry.get("candidate") or {}).get("undo_verified") is True
        and all(attempt.get("undo_verified") is not False
                for label in ("candidate", "control")
                for attempt in (entry.get(label) or {}).get("attempts", []))
        for entry in results.values())
    ev.check("993/every-requested-language-inserts-and-restores-Gain", complete,
             "every requested language has candidate Gain in the mixer's response-named slot "
             "and its original strip after Edit > Undo",
             {"requested": args.lprojs, "completed": list(results), "all_passed": complete},
             "restore rootMenuNotFound for a zh_TW root holding only flat Audio Units: "
             "manufacturer rows; the zh_TW mixer never reads Gain back")
    out = ev.write()
    print(json.dumps(out, indent=1))
    return 0 if complete and E.is_clean(out) else 1


if __name__ == "__main__":
    sys.exit(main())
