#!/usr/bin/env python3
"""Live check that an `insert_plugin` refusal leaves no Logic menu open (#1016), with a control.

Usage: /usr/bin/python3 Scripts/livekit/probe_1016_refusal_leaves_no_menu.py \
       <worktree> <full-40-char-head> <candidate-binary> <control-binary> [--samples N]
       (caller sets LPM_EVIDENCE_ROOT to an absolute directory outside the repository)

WHAT IS ASKED AND HOW IT IS READ
--------------------------------
Logic is running on a project, in any language, and the product's `logic://mixer` shows a strip with a
free insert slot 0. Each sample asks `logic_mixer.insert_plugin` for Gain on that slot with a channel
configuration no strip offers, so the slot is pressed, the plug-in menu opens, the Gain submenu is
walked, and the request is refused as `leaf_not_offered_by_this_strip` (#871: a requested value the
strip does not have is refused, never substituted). Nothing is inserted; the mixer is read back after
every sample to show slot 0 is still free.

Right after each response the window server's on-screen list is read for Logic windows at or above the
pop-up menu level. That reading is the measurement, and a list the window server did not hand back is
unknown, never empty. A menu found open is photographed, then closed with System Events Escapes,
outside the measured bracket, so the next sample starts with no menu open. The Mixer is captured
before and after every sample, and the two captures must match: the refusal inserts nothing.

The control and the candidate alternate, control first, on the same strip.

PASS
----
Every candidate refusal reports `plugin_popup_menu_state: dismissed` and leaves no such window, and at
least one control refusal leaves one open. Without that control the reading could simply be unable to
see a menu, and a clean candidate would prove nothing, so the run fails. The exit code is also the
evidence document's own `is_clean`, which requires the captures, the visual comparisons and the
screen recording this surface calls for.

WHAT IS NOT JUDGED
------------------
Only this refusal branch is driven. `root_menu_not_found` ends in the same cleanup call and is read in
#993's locale sweep, not here. One Logic installation, one project.
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

CONFIGURATION = "lpm-1016-no-such-layout"
READ_TIMEOUT = 15.0
# A hard duration: `screencapture -v` finalises its file only when this elapses. Three samples of
# each binary took about two minutes on the first run.
RECORDING_SECONDS = 240


def arguments():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("worktree")
    parser.add_argument("head")
    parser.add_argument("candidate")
    parser.add_argument("control")
    parser.add_argument("--samples", type=int, default=3)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.head):
        parser.error("head must be a full lowercase 40-character SHA")
    if not os.path.isdir(args.worktree):
        parser.error("worktree does not exist")
    for path in (args.candidate, args.control):
        if not os.access(path, os.X_OK):
            parser.error(f"binary is not executable: {path}")
    if args.samples < 1:
        parser.error("--samples must be at least 1")
    if not os.path.isabs(os.environ.get("LPM_EVIDENCE_ROOT", "")):
        parser.error("LPM_EVIDENCE_ROOT must be set by the caller to an absolute path")
    return args


def osa(script, timeout=20):
    try:
        result = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True,
                                text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    return (result.stdout or "").strip() if result.returncode == 0 else None


def open_logic_menus():
    """Logic's on-screen windows at or above the pop-up menu level; None when they cannot be read."""
    try:
        import Quartz
        level = Quartz.CGWindowLevelForKey(Quartz.kCGPopUpMenuWindowLevelKey)
        windows = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly,
                                                    Quartz.kCGNullWindowID)
        if windows is None:
            # The window server did not answer. An empty list here would read as "no menu open",
            # which is the one answer this probe exists to establish.
            return None
        return [{"id": int(window.get(Quartz.kCGWindowNumber)),
                 "layer": int(window.get(Quartz.kCGWindowLayer)),
                 "bounds": {key: int(value) for key, value
                            in dict(window.get(Quartz.kCGWindowBounds) or {}).items()}}
                for window in windows
                if E._is_logic_owned_window(window)
                and int(window.get(Quartz.kCGWindowLayer) or 0) >= int(level)]
    except Exception:  # noqa: BLE001 - an unread window list is not an empty one
        return None


def close_menus():
    """Escape until no Logic menu is on screen; the final reading is returned."""
    for _ in range(4):
        found = open_logic_menus()
        if found is not None and not found:
            return found
        osa('tell application "System Events" to key code 53', timeout=5)
        time.sleep(0.5)
    return open_logic_menus()


def free_slot_zero(mixer):
    return [row.get("trackIndex") for row in mixer.get("strips") or []
            if isinstance(row.get("trackIndex"), int) and isinstance(row.get("plugins"), list)
            and not any(p.get("index") == 0 for p in row["plugins"])]


def read_mixer(driver, predicate):
    """Force a poll, then read the resource until it answers the predicate or the bound expires."""
    deadline = time.monotonic() + READ_TIMEOUT
    while True:
        driver.tool("logic_system", "refresh_cache")
        latest = driver.resource("logic://mixer") or {}
        if latest.get("data_source") == "ax_poll" and predicate(latest):
            return latest, True
        if time.monotonic() >= deadline:
            return latest, False
        time.sleep(0.5)


def mixer_band(ev):
    """The Mixer's band and the description it was found by, read off the live tree."""
    with open(os.path.join(HERE, "..", "..", "docs", "locale", "ui-labels.json"), encoding="utf-8") as h:
        row = json.load(h)["labels"]["mixerNamedElement"]
    # Measured 2026-09-26 (ko): the label also names a 235-wide AXLayoutArea beside the 1317-wide
    # Mixer, and the tool refuses the pair as ambiguous.
    for name in [row["canonical"], *row["variants"]]:
        band, subject = ev.located_band(name, "--role", "AXLayoutArea", "--min-width", "600")
        if band:
            return band, subject
    return None, None


def capture_menu(ev, tag, menu):
    """Photograph a popup window by its window-server id; a title lookup cannot reach it."""
    bounds = menu.get("bounds") or {}
    ev.shot(tag, window={"id": menu["id"], "title": "",
                         "x": bounds.get("X", 0), "y": bounds.get("Y", 0),
                         "w": bounds.get("Width", 0), "h": bounds.get("Height", 0)})


def sample(ev, binary, track, tag, band, subject, photographed=True):
    """One refusal. `photographed=False` is the warm-up, which records no capture or comparison."""
    driver = E.Driver(binary=binary)
    try:
        before, fresh = read_mixer(driver, lambda mixer: track in free_slot_zero(mixer))
        if not fresh:
            return {"error": f"track {track} slot 0 was not read free before the request"}
        before_shot = ev.shot(f"{tag}-mixer-before", settle_region=band) if photographed else None
        response = driver.tool("logic_mixer", "insert_plugin", {
            "track": track, "slot": 0, "plugin_name": "Gain",
            "configuration": CONFIGURATION, "confirmed": True}) or {}
        menus = open_logic_menus()
        for number, menu in enumerate((menus or []) if photographed else []):
            capture_menu(ev, f"{tag}-menu-left-open-{number}", menu)
        # Unknown is cleaned up too; only a reading of none skips it.
        closed = [] if menus == [] else close_menus()
        if photographed:
            after_shot = ev.shot(f"{tag}-mixer-after", settle_region=band)
            ev.visual(f"{tag}-mixer-unchanged", before_shot["file"], after_shot["file"], band,
                      expect_change=False,
                      why="the request is refused before any plug-in is chosen, so nothing is inserted",
                      subject=subject)
        after, still_free = read_mixer(driver, lambda mixer: track in free_slot_zero(mixer))
        return {"response": response, "menus_open_after_response": menus,
                "menus_open_after_cleanup": closed, "slot_zero_still_free": still_free}
    finally:
        driver.close()


def main():
    args = arguments()
    E.REPO = args.worktree
    E.BIN = args.candidate
    missing = E.have_tools()
    if missing:
        sys.exit(f"cannot run: missing {missing}")
    ev = E.Evidence(args.head, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")
    start = close_menus()
    ev.note("1016/menus-open-at-start-after-cleanup", start)
    if start is None or start:
        ev.check("1016/started-with-no-menu-open", False, "no Logic menu is open before sampling",
                 start, "a menu left open by an earlier run would be counted as this run's")
        print(json.dumps({"written": ev.write()}))
        return 1

    probe = E.Driver(binary=args.control)
    try:
        mixer, fresh = read_mixer(probe, lambda m: bool(free_slot_zero(m)))
    finally:
        probe.close()
    tracks = free_slot_zero(mixer) if fresh else []
    ev.note("1016/free-slot-zero-tracks", tracks)
    if not tracks:
        ev.check("1016/found-a-free-slot-zero", False, "a strip with a free insert slot 0",
                 tracks, "the refusal cannot be driven without a free slot")
        print(json.dumps({"written": ev.write()}))
        return 1
    track = tracks[0]

    band, subject = mixer_band(ev)
    if not band:
        ev.check("1016/found-the-mixer-band", False, "the Mixer located on the live tree by its label",
                 None, "without the band the no-insert comparison has nothing to look at")
        print(json.dumps({"written": ev.write()}))
        return 1

    # Pressing a slot selects its strip, which recolours it. One unmeasured refusal first, so the
    # sampled before/after captures compare a strip that is already selected.
    warm_up = sample(ev, args.control, track, "1016/warm-up", band, subject, photographed=False)
    ev.note("1016/warm-up", warm_up)
    if warm_up.get("error") or warm_up.get("menus_open_after_cleanup") != []:
        ev.check("1016/warm-up-left-a-clean-screen", False, "the warm-up refusal ends with no menu open",
                 warm_up, "a menu left by the warm-up would be read as the first sample's")
        print(json.dumps({"written": ev.write()}))
        return 1

    recording = ev.record_screen(seconds=RECORDING_SECONDS)
    runs = {"control": [], "candidate": []}
    for number in range(args.samples):
        for label, binary in (("control", args.control), ("candidate", args.candidate)):
            result = sample(ev, binary, track, f"1016/{label}-{number}", band, subject)
            runs[label].append(result)
            ev.note(f"1016/{label}-sample-{number}", result)
            ev.restored(f"1016/{label}-sample-{number}-slot-zero-still-free",
                        result.get("slot_zero_still_free") is True, f"track={track} slot=0")
            print(json.dumps({"label": label, "sample": number,
                              "menu_failure": (result.get("response") or {}).get("menu_failure"),
                              "plugin_popup_menu_state":
                                  (result.get("response") or {}).get("plugin_popup_menu_state"),
                              "menus_open_after_response": result.get("menus_open_after_response"),
                              "error": result.get("error")}, ensure_ascii=False), flush=True)
            # An unread list after cleanup is as disqualifying as an open menu: the next sample
            # could start over one, and nothing here would know.
            if result.get("error") or result.get("menus_open_after_cleanup") != []:
                ev.stop_recording(recording)
                ev.check("1016/harness-closed-what-it-found", False,
                         "the sample ran and System Events Escapes left a readable list with no "
                         "Logic menu before the next sample",
                         result, "a menu left by one sample would be read as the next one's")
                print(json.dumps({"written": ev.write()}))
                return 1
    ev.stop_recording(recording)

    def refused(result):
        return (result.get("response") or {}).get("menu_failure") == "leaf_not_offered_by_this_strip"

    control_left = [r["menus_open_after_response"] for r in runs["control"]
                    if refused(r) and r.get("menus_open_after_response")]
    ev.check("1016/control-refusal-leaves-a-menu-open", bool(control_left),
             "the control's blind Escape leaves a Logic menu open after at least one refusal, "
             "so the reading can see one",
             {"track": track, "control": [{"menu_failure": (r.get("response") or {}).get("menu_failure"),
                                           "menus": r.get("menus_open_after_response")}
                                          for r in runs["control"]]},
             "a window reading that cannot see a menu would pass the candidate check vacuously")
    candidate_clean = all(
        refused(r) and r.get("menus_open_after_response") == []
        and (r.get("response") or {}).get("plugin_popup_menu_state") == "dismissed"
        for r in runs["candidate"])
    ev.check("1016/candidate-refusal-closes-its-menu", candidate_clean,
             "every candidate refusal reports plugin_popup_menu_state dismissed and leaves no "
             "Logic window at or above the pop-up menu level",
             {"track": track, "candidate": [
                 {"menu_failure": (r.get("response") or {}).get("menu_failure"),
                  "plugin_popup_menu_state": (r.get("response") or {}).get("plugin_popup_menu_state"),
                  "menus": r.get("menus_open_after_response")} for r in runs["candidate"]]},
             "restore the blind Escape in the refusal branch: the candidate then leaves the menu "
             "open as the control does, and reports no popup state")
    out = ev.write()
    clean = E.is_clean(out)
    print(json.dumps({"written": out, "is_clean": clean}))
    return 0 if control_left and candidate_clean and clean else 1


if __name__ == "__main__":
    sys.exit(main())
