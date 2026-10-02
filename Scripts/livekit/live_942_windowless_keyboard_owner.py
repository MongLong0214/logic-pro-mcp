#!/usr/bin/env python3
"""Live proof that an application with no window on screen is read as the keyboard's owner (#942).

Usage: LPM_LIVE_LOCK=<held lock> LPM_EVIDENCE_ROOT=<absolute dir> /usr/bin/python3 \
       Scripts/livekit/live_942_windowless_keyboard_owner.py \
       <worktree> <full-40-char-head> <candidate-binary> <control-binary> [--lprojs lproj ...] [--samples N]
       (default lprojs: en ko ja de es fr it pt zh_CN zh_TW; two samples; both binaries debug builds)

WHAT IS ASKED
-------------
The server decides who holds the keyboard from the window server's list: the owner of the first
window at the normal or the modal-panel level. Clicking the desktop activates Finder without giving
it a window, and then the first window at either level is Logic's, so that rule says Logic while the
keystrokes go to Finder. The candidate also asks the accessibility server for the focused application
and needs both to name Logic. The control is a build with the window rule alone. This asks whether,
on Logic, the candidate reads Finder there and the control reads Logic.

HOW THE SCREEN IS PUT INTO THE STATE
------------------------------------
Each sample, per binary, from Logic active and no Finder window on screen: Finder is activated, the
server is started with LOGIC_MCP_942_POST_LEAF_HOLD_DIR (the seam that replaces goto_position's script
and nothing else; see live_942_post_leaf_settlement_in_every_locale.py) and asked for
`logic_transport goto_position`. Its frontmost gate runs first and its answer is the reply's
`frontmost_preparation`. When the server writes `entered`, Finder is activated again, since a server
that activated Logic took it away, and the harness reads the screen. Then it writes `release`, and the
settlement reads the screen itself and reports its `keyboard_owner`.

The harness's reading at the hold is the condition, and it is made of pids, not names: the front
application per `lsappinfo front` is Finder's process; the first window at layer 0 or the modal-panel
level is Logic's; no Finder window is at layer 0; the system-wide AXFocusedApplication is Finder's. A
sample whose condition did not hold fails, because then a candidate's "other" would not show that it
read the focused application.

The positive control for the candidate is one more hold per sample with Logic left active and nothing
arranged: it must read Logic, so a candidate that reads every screen as "other" fails.

PASS
----
In every language and sample: the condition held at the candidate's and the control's holds; the
candidate answered `activated` and its settlement read `other`; the control answered
`already_frontmost` and read `logic`; the candidate with Logic active answered `already_frontmost`
and read `logic`. No binary sent an Escape. Each check is run against the other binary's row as the
state it must reject. Korean is restored at the end and read back. The exit code is also the
evidence document's own `is_clean`.

WHAT IS NOT JUDGED
------------------
The script, which the seam replaces; no keystroke is posted into Finder by either binary. One
windowless application (Finder), one fixture, one Logic installation. The modal-panel prompts the
window rule was built for cannot be raised on demand and are not part of this run.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import evidence as E  # noqa: E402
import live_993_plugin_root_menu_in_every_locale as L993  # noqa: E402
import probe_942_escape_over_goto_dialog as P  # noqa: E402

HOLD_KEY = "LOGIC_MCP_942_POST_LEAF_HOLD_DIR"
HOLD_RESULT = "leaf_click_error"
ENTER_WAIT = 20.0
FRONT_WAIT = 4.0
SETTLE = 0.6
LOGIC_BUNDLE = "com.apple.logic10"
FINDER_BUNDLE = "com.apple.finder"


def arguments():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("worktree")
    parser.add_argument("head")
    parser.add_argument("candidate")
    parser.add_argument("control")
    parser.add_argument("--lprojs", nargs="+", default=list(L993.DEFAULT_LPROJS), metavar="lproj")
    parser.add_argument("--samples", type=int, default=2)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.head):
        parser.error("head must be a full lowercase 40-character SHA")
    if not os.path.isdir(args.worktree):
        parser.error("worktree does not exist")
    for path in (args.candidate, args.control):
        if not os.access(path, os.X_OK):
            parser.error(f"binary is not executable: {path}")
    unknown = [name for name in args.lprojs if name not in L993.CODES]
    if unknown:
        parser.error(f"unknown lproj(s): {', '.join(unknown)}")
    if args.samples < 1:
        parser.error("--samples must be at least 1")
    if not os.path.isabs(os.environ.get("LPM_EVIDENCE_ROOT", "")):
        parser.error("LPM_EVIDENCE_ROOT must be set by the caller to an absolute path")
    lock = os.environ.get("LPM_LIVE_LOCK") or ""
    if not os.path.isfile(lock):
        parser.error(f"LPM_LIVE_LOCK must name an existing lock file held by the caller (got {lock!r})")
    return args


def sha256_of(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def pid_of_bundle(bundle):
    """The pid of the running application with this bundle id, or None."""
    out = subprocess.run(["/usr/bin/lsappinfo", "info", "-only", "pid", "-app", bundle],
                         capture_output=True, text=True).stdout
    found = re.search(r"=\s*(\d+)", out)
    return int(found.group(1)) if found else None


def front_pid():
    """The pid of the application `lsappinfo front` names, or None."""
    asn = subprocess.run(["/usr/bin/lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    if not asn:
        return None
    out = subprocess.run(["/usr/bin/lsappinfo", "info", "-only", "pid", asn],
                         capture_output=True, text=True).stdout
    found = re.search(r"=\s*(\d+)", out)
    return int(found.group(1)) if found else None


def window_list():
    import Quartz
    return Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)


def keyboard_window_pid(windows):
    """The owner pid of the first window at layer 0 or the modal-panel level, the server's
    `LogicOnScreenWindows.keyboardWindow`; None when there is none."""
    import Quartz
    modal_panel = int(Quartz.CGWindowLevelForKey(Quartz.kCGModalPanelWindowLevelKey))
    for window in windows or []:
        if int(window.get(Quartz.kCGWindowLayer) or 0) in (0, modal_panel):
            return int(window.get(Quartz.kCGWindowOwnerPID))
    return None


def normal_windows_of(windows, pid):
    import Quartz
    return [int(w.get(Quartz.kCGWindowNumber)) for w in windows or []
            if int(w.get(Quartz.kCGWindowOwnerPID)) == pid and int(w.get(Quartz.kCGWindowLayer) or 0) == 0]


def reading(logic_pid, finder_pid):
    """The screen by pids. The window list is read before the focused application: the
    accessibility read fails until this process has called the window server."""
    windows = window_list()
    focused = P.focused_application_pid()
    front = front_pid()
    keyboard = keyboard_window_pid(windows)
    finder_windows = normal_windows_of(windows, finder_pid)
    return {
        "list_read": windows is not None,
        "front": "logic" if front == logic_pid else "finder" if front == finder_pid else front,
        "keyboard_window": "logic" if keyboard == logic_pid else "finder" if keyboard == finder_pid else keyboard,
        "focused_application": "logic" if focused == logic_pid else "finder" if focused == finder_pid else focused,
        "finder_normal_windows": len(finder_windows),
        "windowless_finder_holds_the_keyboard": (
            windows is not None and front == finder_pid and keyboard == logic_pid
            and focused == finder_pid and not finder_windows),
    }


def wait_front(pid):
    end = time.time() + FRONT_WAIT
    while time.time() < end:
        if front_pid() == pid:
            time.sleep(SETTLE)
            return True
        time.sleep(0.1)
    return False


def activate(bundle, pid):
    subprocess.run(["/usr/bin/osascript", "-e", f'tell application id "{bundle}" to activate'],
                   capture_output=True, timeout=10)
    return wait_front(pid)


def hold(binary, arrange):
    """One goto_position call held at the seam; `arrange` runs at the hold and returns the reading
    taken there. Returns the reply and that reading."""
    folder = tempfile.mkdtemp(prefix="lpm942wl-")
    with open(os.path.join(folder, "result"), "w") as handle:
        handle.write(HOLD_RESULT)
    os.environ[HOLD_KEY] = folder
    taken = {}
    done = threading.Event()

    def at_hold():
        end = time.time() + ENTER_WAIT
        while time.time() < end and not done.is_set():
            if os.path.exists(os.path.join(folder, "entered")):
                taken["reading"] = arrange()
                open(os.path.join(folder, "release"), "w").close()
                return
            time.sleep(0.05)
        taken["reading"] = {"error": "the server never wrote entered"}
        open(os.path.join(folder, "release"), "w").close()

    thread = threading.Thread(target=at_hold, daemon=True)
    thread.start()
    driver = E.Driver(binary=binary)
    try:
        reply = driver.tool("logic_transport", "goto_position", {"bar": 9})
    finally:
        done.set()
        thread.join(timeout=ENTER_WAIT)
        try:
            driver.close()
        except Exception:  # noqa: BLE001 - the reply is already in hand
            pass
        os.environ.pop(HOLD_KEY, None)
    return reply, taken.get("reading")


def summarise(reply, at_hold, front_at_entry=None):
    settlement = (reply or {}).get("post_leaf_settlement") or {}
    return {
        "frontmost_preparation": (reply or {}).get("frontmost_preparation"),
        "keyboard_owner": (settlement.get("read") or {}).get("keyboard_owner"),
        "escapes_sent": settlement.get("escapes_sent"),
        "front_at_entry": front_at_entry,
        "at_hold": at_hold,
    }


def windowless(row):
    return bool((row.get("at_hold") or {}).get("windowless_finder_holds_the_keyboard"))


def candidate_reads_finder(row):
    return (windowless(row) and row.get("frontmost_preparation") == "activated"
            and row.get("keyboard_owner") == "other" and row.get("escapes_sent") == 0)


def control_reads_logic(row):
    return (windowless(row) and row.get("frontmost_preparation") == "already_frontmost"
            and row.get("keyboard_owner") == "logic" and row.get("escapes_sent") == 0)


def candidate_reads_logic_when_logic_is_front(row):
    at_hold = row.get("at_hold") or {}
    return (at_hold.get("front") == "logic" and at_hold.get("focused_application") == "logic"
            and row.get("frontmost_preparation") == "already_frontmost"
            and row.get("keyboard_owner") == "logic" and row.get("escapes_sent") == 0)


def run_sample(candidate, control, logic_pid, finder_pid):
    sample = {}
    for role, binary in (("candidate", candidate), ("control", control)):
        if not activate(LOGIC_BUNDLE, logic_pid):
            return sample, f"{role}: Logic did not come to the front"
        if normal_windows_of(window_list(), finder_pid):
            return sample, "a Finder window is open; the windowless state cannot be arranged"
        if not activate(FINDER_BUNDLE, finder_pid):
            return sample, f"{role}: Finder did not come to the front"
        before = reading(logic_pid, finder_pid)
        entry = {}

        def arrange():
            entry["front"] = "logic" if front_pid() == logic_pid else "other"
            activate(FINDER_BUNDLE, finder_pid)
            return reading(logic_pid, finder_pid)

        reply, at_hold = hold(binary, arrange)
        sample[role] = summarise(reply, at_hold, entry.get("front"))
        sample[role]["before"] = before
    if not activate(LOGIC_BUNDLE, logic_pid):
        return sample, "candidate positive control: Logic did not come to the front"
    reply, at_hold = hold(candidate, lambda: reading(logic_pid, finder_pid))
    sample["candidate_logic_front"] = summarise(reply, at_hold)
    return sample, None


def main():
    args = arguments()
    sys.path.insert(0, os.path.join(args.worktree, "Scripts"))
    import logic_canon  # noqa: E402
    # live_993's main binds this module global for its own helpers; set it the same way.
    setattr(L993, "logic_canon", logic_canon)
    E.REPO = args.worktree
    E.BIN = args.candidate
    missing = E.have_tools()
    if missing:
        sys.exit(f"cannot run: missing {missing}")
    if E.screen_is_locked() is not False:
        sys.exit("cannot run: the screen is locked or its state did not read; nothing was sent to Logic")
    others = subprocess.run(["/usr/bin/pgrep", "-fl", "LogicProMCP"], capture_output=True, text=True)
    if others.stdout.strip():
        sys.exit(f"cannot run: a LogicProMCP process is already running and would hold the MCU "
                 f"ports: {others.stdout.strip()[:300]}")

    ev = E.Evidence(args.head, os.environ["LPM_EVIDENCE_ROOT"], surface="non_ui")
    ev.note("942-windowless/binaries", {
        "candidate": args.candidate, "candidate_sha256": sha256_of(args.candidate),
        "control": args.control, "control_sha256": sha256_of(args.control),
        "lprojs": args.lprojs, "samples": args.samples})
    runs, failures, restored = {}, {}, {}
    try:
        for lproj in args.lprojs:
            language = L993.switch_to(lproj, force=True)
            runs[lproj] = {"launch": language, "samples": []}
            if language.get("arrange_window") is None \
                    or language.get("language_setting", [])[:1] != [L993.CODES[lproj]]:
                failures[lproj] = "the fixture did not open in this language"
                break
            logic_pid, finder_pid = pid_of_bundle(LOGIC_BUNDLE), pid_of_bundle(FINDER_BUNDLE)
            if logic_pid is None or finder_pid is None:
                failures[lproj] = f"pids did not read: Logic {logic_pid}, Finder {finder_pid}"
                break
            for _ in range(args.samples):
                sample, error = run_sample(args.candidate, args.control, logic_pid, finder_pid)
                runs[lproj]["samples"].append(sample)
                ev.note(f"942-windowless/{lproj}/sample-{len(runs[lproj]['samples'])}", sample)
                if error:
                    failures[lproj] = error
                    break
            if lproj in failures:
                break
    finally:
        activate(LOGIC_BUNDLE, pid_of_bundle(LOGIC_BUNDLE))
        try:
            restored = L993.switch_to(L993.RESTORE, force=True)
        except Exception as exc:  # noqa: BLE001 - recorded as a failed restoration
            restored = {"error": f"Korean restoration raised: {exc!r}"}
        restored["language_setting_after_restore"] = L993.language_setting()
        restored["window_names_after_restore"] = L993.window_names()
        restored["ok"] = (restored.get("arrange_window") is not None
                          and restored["language_setting_after_restore"][:1] == [L993.CODES[L993.RESTORE]]
                          and restored["arrange_window"] in (restored["window_names_after_restore"] or []))
        ev.restored("942-windowless/Logic-language-restored-to-Korean", restored["ok"], repr(restored))

    ev.note("942-windowless/failures", failures)
    for lproj in args.lprojs:
        for number, sample in enumerate((runs.get(lproj) or {}).get("samples") or [], start=1):
            tag = f"942-windowless/{lproj}/{number}"
            candidate, control = sample.get("candidate") or {}, sample.get("control") or {}
            ev.falsifiable(f"{tag}/candidate", candidate_reads_finder, candidate, control,
                           "with Finder active and windowless, the candidate activates Logic and its "
                           "settlement reads the keyboard as another process's, sending nothing",
                           mutation="drop the focused application from keyboardOwnerIsLogic and "
                                    "logicOwnsTheKeyboard (the control binary): already_frontmost, logic")
            ev.falsifiable(f"{tag}/control", control_reads_logic, control, candidate,
                           "the same screen read by the window rule alone answers already_frontmost "
                           "and logic: the defect reproduces",
                           mutation="none: this is the positive control; a screen on which the window "
                                    "rule did not misread would fail it and void the candidate check")
            ev.falsifiable(f"{tag}/candidate-logic-front", candidate_reads_logic_when_logic_is_front,
                           sample.get("candidate_logic_front") or {}, candidate,
                           "with Logic active the candidate answers already_frontmost and reads logic",
                           mutation="keyboardOwnerIsLogic answering false whenever a focused application "
                                    "is read")
    out = ev.write()
    clean = E.is_clean(out)
    print(json.dumps({"written": out, "is_clean": clean, "failures": failures,
                      "korean_restored": restored.get("ok")}, ensure_ascii=False))
    return 0 if clean and not failures else 1


if __name__ == "__main__":
    sys.exit(main())
