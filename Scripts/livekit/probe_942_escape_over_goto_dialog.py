#!/usr/bin/env python3
"""Live measurement of what one Escape closes when a Logic menu is open over Go To Position (#942).

Usage: /usr/bin/python3 Scripts/livekit/probe_942_escape_over_goto_dialog.py \
       <worktree> <full-40-char-head> [--samples N]
       (caller sets LPM_EVIDENCE_ROOT to an absolute directory outside the repository)

THE QUESTION
------------
Fourteen goto-position refusals end with the Go To Position dialog possibly still up and a Logic menu
possibly still open. An open menu wedges Logic's AppleEvent handler, so the server would like to close
it; but an Escape that reaches a modal dialog cancels the dialog. Which one does a single Escape close
when both are on screen? The answer decides whether the server may send the menu Escape while the
dialog is unresolved, and it is measured here rather than assumed.

HOW IT IS READ
--------------
Everything is read from the window server's on-screen list, not from AX: a modal dialog poisons AX
reads, and an open menu wedges AppleEvents, so neither can be trusted in exactly the state under test.
A Logic menu is a Logic-owned window at or above the pop-up menu level. The dialog is the Logic-owned
window that appeared after its menu item was clicked and whose window-server name is one of the
dialog's measured titles in docs/locale/ui-labels.json. A list the window server did not hand back is
unknown, and the sample fails.

The Escape is posted the way the server posts it (`AXLogicProElements.Runtime.livePostPopupMenuEscape`):
a key-down and key-up for virtual key 53 at the HID event tap, which goes to whichever application owns
the keyboard. The first layer-0 window's owner is recorded before every Escape, and a sample in which it
is not Logic fails, because that Escape would have gone somewhere else.

Each sample, from a screen with no Logic menu and no dialog:
  1. open the dialog from the menu bar; one Escape; the dialog must be gone. This is the control: it
     shows the Escape reaches the dialog, so a dialog that survives step 3 did not survive by being out
     of the Escape's reach.
  2. open the dialog again; open the Navigate menu over it.
  3. one Escape; read which of the two is still on screen. The dialog counts as surviving only if it is
     still listed after five times the control's measured disappearance time (at least 1.5 s), so a
     dialog the same Escape is closing is not caught mid-close and read as untouched.
Clean-up (Escapes until neither is on screen) is outside the measured bracket and verified by a re-read.

WHAT IS NOT JUDGED
------------------
This measures Logic, not the server: no server operation is driven, so the evidence document does not
earn `is_clean`'s `operations_driven` and the exit code does not claim it. One menu (Navigate) over one
dialog (Go To Position), on one Logic installation, in whatever language it runs.
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

LABELS = os.path.join(HERE, "..", "..", "docs", "locale", "ui-labels.json")
WAIT_SECONDS = 3.0
SURVIVAL_FACTOR = 5
SURVIVAL_FLOOR = 1.5
ESCAPE_KEY = 53


def arguments():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("worktree")
    parser.add_argument("head")
    parser.add_argument("--samples", type=int, default=3)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.head):
        parser.error("head must be a full lowercase 40-character SHA")
    if not os.path.isdir(args.worktree):
        parser.error("worktree does not exist")
    if args.samples < 1:
        parser.error("--samples must be at least 1")
    if not os.path.isabs(os.environ.get("LPM_EVIDENCE_ROOT", "")):
        parser.error("LPM_EVIDENCE_ROOT must be set by the caller to an absolute path")
    return args


def names(key):
    with open(LABELS, encoding="utf-8") as h:
        row = json.load(h)["labels"][key]
    return [row["canonical"], *row["variants"]]


def osa(script, timeout=10):
    try:
        result = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True,
                                text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    return (result.stdout or "").strip() if result.returncode == 0 else None


def applescript_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def logic_windows():
    """Logic-owned on-screen windows, or None when the window server did not answer."""
    import Quartz
    windows = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly,
                                                Quartz.kCGNullWindowID)
    if windows is None:
        return None
    found = []
    for window in windows:
        if not E._is_logic_owned_window(window):
            continue
        bounds = dict(window.get(Quartz.kCGWindowBounds) or {})
        found.append({"id": int(window.get(Quartz.kCGWindowNumber)),
                      "layer": int(window.get(Quartz.kCGWindowLayer) or 0),
                      "name": window.get(Quartz.kCGWindowName),
                      "bounds": {key: int(value) for key, value in bounds.items()}})
    return found


def keyboard_owner_is_logic():
    """Whether the first layer-0 window on screen is Logic's, as the server judges it; None if unread."""
    import Quartz
    windows = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly,
                                                Quartz.kCGNullWindowID)
    if windows is None:
        return None
    for window in windows:
        if int(window.get(Quartz.kCGWindowLayer) or 0) == 0:
            return E._is_logic_owned_window(window)
    return None


def menu_level():
    import Quartz
    return int(Quartz.CGWindowLevelForKey(Quartz.kCGPopUpMenuWindowLevelKey))


def menus(windows):
    return None if windows is None else [w for w in windows if w["layer"] >= menu_level()]


def dialogs(windows, baseline_ids, titles):
    if windows is None:
        return None
    return [w for w in windows if w["id"] not in baseline_ids and w["name"] in titles
            and w["layer"] < menu_level()]


def wait_for(predicate, seconds=WAIT_SECONDS):
    """Read until the predicate holds or the bound passes; the last reading is returned either way."""
    return wait_timed(predicate, seconds)[0]


def wait_timed(predicate, seconds=WAIT_SECONDS):
    """`(last reading, seconds until the predicate held or None)`."""
    started = time.monotonic()
    while True:
        windows = logic_windows()
        if windows is not None and predicate(windows):
            return windows, round(time.monotonic() - started, 3)
        if time.monotonic() - started >= seconds:
            return windows, None
        time.sleep(0.05)


def post_escape():
    """Key 53 at the HID tap, exactly as the server's popup-menu Escape posts it."""
    import Quartz
    source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for down in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(source, ESCAPE_KEY, down)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


def menu_path():
    """The Navigate menu, its Go To item and the Position… leaf, by the names this Logic shows."""
    bar = osa('tell application "System Events" to tell process "Logic Pro" to '
              'get name of every menu bar item of menu bar 1')
    if bar is None:
        return None
    shown = [item.strip() for item in bar.split(",")]
    navigate = next((n for n in names("navigateMenuBar") if n in shown), None)
    if navigate is None:
        return None
    items = osa('tell application "System Events" to tell process "Logic Pro" to get name of every '
                f'menu item of menu 1 of menu bar item {applescript_string(navigate)} of menu bar 1')
    if items is None:
        return None
    shown = [item.strip() for item in items.split(",")]
    go_to = next((n for n in names("goToMenuItem") if n in shown), None)
    if go_to is None:
        return None
    leaves = osa('tell application "System Events" to tell process "Logic Pro" to get name of every '
                 f'menu item of menu 1 of menu item {applescript_string(go_to)} of menu 1 of '
                 f'menu bar item {applescript_string(navigate)} of menu bar 1')
    if leaves is None:
        return None
    shown = [item.strip() for item in leaves.split(",")]
    position = next((n for n in names("goToPositionMenuItem") if n in shown), None)
    if position is None:
        return None
    return {"navigate": navigate, "go_to": go_to, "position": position}


def open_dialog(path):
    return osa('with timeout of 4 seconds\ntell application "System Events" to tell process "Logic Pro" '
               f'to click menu item {applescript_string(path["position"])} of menu 1 of menu item '
               f'{applescript_string(path["go_to"])} of menu 1 of menu bar item '
               f'{applescript_string(path["navigate"])} of menu bar 1\nend timeout', timeout=8)


def open_menu(path):
    """Click the Navigate menu without waiting on the click: an open menu holds the AppleEvent."""
    return subprocess.Popen(
        ["/usr/bin/osascript", "-e",
         'with timeout of 3 seconds\ntell application "System Events" to tell process "Logic Pro" to '
         f'click menu bar item {applescript_string(path["navigate"])} of menu bar 1\nend timeout'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def settle_clean(baseline_ids, titles):
    """Escapes until no menu and no dialog is on screen; the final reading is returned."""
    for _ in range(4):
        windows = logic_windows()
        if windows is not None and not menus(windows) and not dialogs(windows, baseline_ids, titles):
            return windows
        post_escape()
        time.sleep(0.6)
    return logic_windows()


def capture(ev, tag, window):
    """Capture one window by number, settled on the whole window: `shot` with no region never settles.

    Measured 2026-09-26: capturing the Navigate menu by its window number returns the menu itself
    (348x436 points, 696x872 pixels, three identical frames); a plug-in popup's number does not, which
    is why this probe opens a menu-bar menu. The pixel size is recorded so a mismatch shows.
    """
    bounds = window.get("bounds") or {}
    w, h = bounds.get("Width", 0), bounds.get("Height", 0)
    shot = ev.shot(tag, settle_region=(0, 0, w, h),
                   window={"id": window["id"], "title": window.get("name") or "",
                           "x": bounds.get("X", 0), "y": bounds.get("Y", 0), "w": w, "h": h})
    ev.note(f"{tag}/pixels-versus-points", {"pixels": png_size(shot["file"]), "points": [w, h]})
    return shot


def png_size(path):
    """`[width, height]` from the PNG header, or None when the file is missing or not a PNG."""
    try:
        with open(path, "rb") as h:
            head = h.read(24)
    except OSError:
        return None
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return [int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")]


def sample(ev, number, path, baseline_ids, titles):
    tag = f"942/sample-{number}"
    result = {}

    # 1. The control: the dialog alone, one Escape.
    result["open_dialog_for_control"] = open_dialog(path)
    shown = wait_for(lambda ws: bool(dialogs(ws, baseline_ids, titles)))
    result["control_dialog"] = dialogs(shown, baseline_ids, titles)
    if not result["control_dialog"]:
        result["error"] = "the dialog did not appear for the control"
        return result
    result["control_keyboard_owner_is_logic"] = keyboard_owner_is_logic()
    post_escape()
    control_ids = {w["id"] for w in result["control_dialog"]}
    after, gone_in = wait_timed(lambda ws: not [w for w in ws if w["id"] in control_ids])
    result["control_after_escape"] = None if after is None else [w for w in after if w["id"] in control_ids]
    result["control_dialog_gone_after_seconds"] = gone_in

    settled = settle_clean(baseline_ids, titles)
    if settled is None or menus(settled) or dialogs(settled, baseline_ids, titles):
        result["error"] = "the screen was not clean before the measured step"
        return result

    # 2. The dialog again, and the Navigate menu over it.
    result["open_dialog"] = open_dialog(path)
    shown = wait_for(lambda ws: bool(dialogs(ws, baseline_ids, titles)))
    result["dialog"] = dialogs(shown, baseline_ids, titles)
    if not result["dialog"]:
        result["error"] = "the dialog did not appear for the measured step"
        return result
    dialog_ids = {w["id"] for w in result["dialog"]}
    dialog_before = capture(ev, f"{tag}-dialog-before-escape", result["dialog"][0])
    click = open_menu(path)
    with_menu = wait_for(lambda ws: bool(menus(ws)))
    try:
        click.wait(timeout=4)
    except subprocess.TimeoutExpired:
        click.kill()
        click.wait()
    result["menus_over_dialog"] = menus(with_menu)
    result["dialog_under_menu"] = None if with_menu is None else [
        w for w in with_menu if w["id"] in dialog_ids]
    if not result["menus_over_dialog"]:
        result["error"] = "no Logic menu opened over the dialog"
        return result
    capture(ev, f"{tag}-menu-over-dialog", result["menus_over_dialog"][0])

    # 3. One Escape.
    result["keyboard_owner_is_logic"] = keyboard_owner_is_logic()
    post_escape()
    after, menu_gone_in = wait_timed(lambda ws: not menus(ws))
    result["menus_after_one_escape"] = menus(after)
    result["menu_gone_after_seconds"] = menu_gone_in
    # Read at the instant the menu vanished, a dialog that the same Escape is also closing can still
    # be listed. It is given SURVIVAL_FACTOR times the control's own measured disappearance time (and
    # at least SURVIVAL_FLOOR seconds) to vanish before it is read as having survived.
    bound = max(SURVIVAL_FLOOR, SURVIVAL_FACTOR * (result.get("control_dialog_gone_after_seconds") or 0))
    result["dialog_survival_bound_seconds"] = round(bound, 3)
    later, dialog_gone_in = wait_timed(lambda ws: not [w for w in ws if w["id"] in dialog_ids], bound)
    result["dialog_gone_after_seconds"] = dialog_gone_in
    result["dialog_after_one_escape"] = None if later is None else [
        w for w in later if w["id"] in dialog_ids]
    result["menus_after_survival_bound"] = menus(later)
    if result["dialog_after_one_escape"]:
        dialog_after = capture(ev, f"{tag}-dialog-after-escape", result["dialog_after_one_escape"][0])
        ev.visual(f"{tag}-dialog-unchanged-by-the-menu-escape", dialog_before["file"],
                  dialog_after["file"], (0, 0, dialog_before["window"]["w"], dialog_before["window"]["h"])
                  if dialog_before.get("window") else None,
                  expect_change=False,
                  why="the Escape closed the menu; the dialog under it is the same window, untouched",
                  subject=f"the Logic window named {result['dialog'][0]['name']!r}",
                  window_points=(dialog_before["window"]["w"], dialog_before["window"]["h"])
                  if dialog_before.get("window") else None)
    return result


def main():
    args = arguments()
    E.REPO = args.worktree
    ev = E.Evidence(args.head, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")
    titles = set(names("goToPositionDialogTitle"))

    osa('tell application "Logic Pro" to activate')
    time.sleep(0.5)
    path = menu_path()
    ev.note("942/menu-path", path)
    if path is None:
        ev.check("942/found-the-go-to-position-menu-item", False,
                 "Navigate > Go To > Position… found by the names this Logic shows", None,
                 "a missing label row would leave nothing to open")
        print(json.dumps({"written": ev.write()}))
        return 1

    baseline = settle_clean(set(), titles)
    ev.note("942/baseline", baseline)
    if baseline is None or menus(baseline):
        ev.check("942/started-clean", False, "a readable window list with no Logic menu open",
                 baseline, "a menu left by an earlier run would be counted as this run's")
        print(json.dumps({"written": ev.write()}))
        return 1
    baseline_ids = {w["id"] for w in baseline}

    recording = ev.record_screen(seconds=30 + 20 * args.samples)
    results = []
    for number in range(args.samples):
        result = sample(ev, number, path, baseline_ids, titles)
        final = settle_clean(baseline_ids, titles)
        result["after_cleanup"] = final
        results.append(result)
        ev.note(f"942/sample-{number}", result)
        print(json.dumps({"sample": number, "error": result.get("error"),
                          "menus_over_dialog": len(result.get("menus_over_dialog") or []),
                          "menus_after_one_escape": result.get("menus_after_one_escape"),
                          "dialog_after_one_escape": len(result.get("dialog_after_one_escape") or []),
                          "control_after_escape": result.get("control_after_escape")},
                         ensure_ascii=False), flush=True)
        ev.restored(f"942/sample-{number}-left-no-menu-and-no-dialog",
                    final is not None and not menus(final) and not dialogs(final, baseline_ids, titles))
        if result.get("error") or final is None or menus(final) or dialogs(final, baseline_ids, titles):
            break
        time.sleep(0.5)
    ev.stop_recording(recording)

    complete = len(results) == args.samples and not any(r.get("error") for r in results)
    ev.check("942/escape-reaches-the-dialog-alone", complete and all(
        r.get("control_keyboard_owner_is_logic") is True and r.get("control_after_escape") == []
        for r in results),
        "with only the dialog up and Logic owning the keyboard, one Escape removes the dialog",
        [{k: r.get(k) for k in ("control_dialog", "control_keyboard_owner_is_logic",
                                "control_after_escape", "control_dialog_gone_after_seconds", "error")}
         for r in results],
        "if the Escape could not reach the dialog, a dialog surviving the measured Escape would prove "
        "nothing about which window it closes")
    ev.check("942/one-escape-closes-the-menu-and-leaves-the-dialog", complete and all(
        r.get("keyboard_owner_is_logic") is True and r.get("menus_after_one_escape") == []
        and r.get("menus_after_survival_bound") == [] and bool(r.get("dialog_after_one_escape"))
        for r in results),
        "with a Logic menu open over the dialog and Logic owning the keyboard, one Escape leaves no "
        "Logic menu and the same dialog window still on screen",
        [{k: r.get(k) for k in ("menus_over_dialog", "dialog_under_menu", "keyboard_owner_is_logic",
                                "menus_after_one_escape", "menu_gone_after_seconds",
                                "dialog_survival_bound_seconds", "dialog_gone_after_seconds",
                                "dialog_after_one_escape", "menus_after_survival_bound", "error")}
         for r in results],
        "if Logic routed the Escape to the modal first, the dialog would be gone after it and this "
        "check fails")
    out = ev.write()
    print(json.dumps({"written": out, "is_clean": E.is_clean(out)}))
    return 0 if complete and out.get("passed") == out.get("checks") else 1


if __name__ == "__main__":
    sys.exit(main())
