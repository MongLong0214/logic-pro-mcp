#!/usr/bin/env python3
"""Live proof that `set_automation` Write leaves no Logic warning up behind its reply (#1077).

Usage: LPM_LIVE_LOCK=<held lock> LPM_EVIDENCE_ROOT=<absolute dir> /usr/bin/python3 \
       Scripts/livekit/live_1077_write_warning_is_cleared_in_every_locale.py \
       <worktree> <full-40-char-head> <candidate-binary> <control-binary> \
       [--crash-control lproj ...] [--lprojs lproj ...]
       (default lprojs: en ko ja de es fr it pt zh_CN zh_TW; default crash control: de)

WHAT IS ASKED AND HOW IT IS READ
--------------------------------
Measured 2026-09-30 (#1077): Logic answered the MCU Write press with a one-button warning, the reply
of `logic_tracks.set_automation` returned while it was still up, and quitting Logic under it crashed
a German Logic 4 of 4 times. The candidate claims to read Logic's modal set after the mode press and
to acknowledge that warning before it replies.

Each language gets two fresh launches of the locale-campaign fixture through live_993's quit, switch
and relaunch, so every Write press is the first of its launch. On each launch one binary drives
`logic_navigate.toggle_view automation`, `set_automation read` and then `set_automation write` on
the first track, the way the #904 runner did. A thread lists Logic's on-screen windows, waiting 20 ms
after each listing, from just before the write call until its reply, so a window that comes and goes inside the call is
seen by an instrument the server does not share. After the reply the window server's list and
System Events' count of Logic AXDialog windows with exactly one button are read, and both are read
again 1.5 s later.

  1. control (the base binary): the warning is expected up at both readings, and its window is
     captured at both and compared. In the crash-control languages Logic is then quit with it still
     up, as the #904 runner did. In the others the harness presses its AXDefaultButton, outside the
     measured bracket, and quits.
  2. candidate: the reply must name `informational_alert` and `acknowledge_alert` with
     `modal_after_press: clear`; the thread must have seen a Logic window appear during the call;
     no window that was not there before the call may be listed after the reply; and System Events
     must count no one-button dialog at either reading. Logic is then quit at once.

Every quit is read the same way: whether live_993's `quit_logic` returned True, Logic's process
count before the quit and 8 s after it (live_993's `logic_census`, which keeps a count that did not
read apart from a count of 0), and which `Logic Pro-*.ips` crash reports appeared in
~/Library/Logs/DiagnosticReports within those 8 s. A quit counts only when it returned True and the
count read as running before it and as 0 after it; an unreadable or malformed count is not a quit.

PASS
----
In every language the control leaves the warning up, the candidate clears it, and the candidate's
quit leaves no crash report. The control's quit with the warning up must write a crash report in at
least one crash-control language, or the crash reading could be blind. Korean is restored at the end
and read back. The exit code is also the evidence document's own `is_clean`.

WHAT IS NOT JUDGED
------------------
The automation mode's own readback: the reply's `state` and `observed_mode` are recorded, not
judged, because the #904 run returned `readback_unavailable` for Read and Touch too, which raise no
dialog. The dialog's text is kept as a digest and a length, not as a string: which Logic string it
is belongs to the canon axis, and this measures a window. One track, one fixture, one Logic
installation.
"""

import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import evidence as E  # noqa: E402
import live_993_plugin_root_menu_in_every_locale as L993  # noqa: E402

COVERS = [
    "Sources/LogicProMCP/Channels/MCUChannel.swift",
    "Sources/LogicProMCP/Channels/AccessibilityChannel+ModalReconcile.swift",
]

WATCH_INTERVAL = 0.02
SURVIVAL_SECONDS = 1.5
CRASH_WAIT = 8.0
EDGE_POINTS = 16
# Two launches, two phases and two quits per language measured about 150 s on the #904 runs.
RECORDING_SECONDS_PER_LANGUAGE = 170
DIAGNOSTIC_REPORTS = os.path.expanduser("~/Library/Logs/DiagnosticReports")
FIELD = "\x1f"

# The count and the text of every Logic AXDialog with exactly one button. A save prompt has three
# and is not counted. An unread answer is None to the caller, never zero.
ONE_BUTTON_DIALOGS = '''tell application "System Events" to tell process "Logic Pro"
  set texts to {}
  repeat with d in (windows whose subrole is "AXDialog")
    if (count of buttons of d) is 1 then
      set t to ""
      try
        set t to (value of static text 1 of d) as string
      end try
      set end of texts to t
    end if
  end repeat
  set AppleScript's text item delimiters to (ASCII character 31)
  return ((count of texts) as string) & (ASCII character 31) & (texts as string)
end tell'''

# The harness's own acknowledgement, outside every measured bracket: the default button of each
# one-button AXDialog, which is how the #904 X5 run cleared the warning.
ACKNOWLEDGE = '''tell application "System Events" to tell process "Logic Pro"
  set n to 0
  repeat with d in (windows whose subrole is "AXDialog")
    if (count of buttons of d) is 1 then
      click (value of attribute "AXDefaultButton" of d)
      set n to n + 1
    end if
  end repeat
  return n as string
end tell'''


def arguments():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("worktree")
    parser.add_argument("head")
    parser.add_argument("candidate")
    parser.add_argument("control")
    parser.add_argument("--crash-control", nargs="+", default=["de"], metavar="lproj")
    parser.add_argument("--lprojs", nargs="+", default=list(L993.DEFAULT_LPROJS), metavar="lproj")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.head):
        parser.error("head must be a full lowercase 40-character SHA")
    if not os.path.isdir(args.worktree):
        parser.error("worktree does not exist")
    for path in (args.candidate, args.control):
        if not os.access(path, os.X_OK):
            parser.error(f"binary is not executable: {path}")
    unknown = [name for name in args.lprojs + args.crash_control if name not in L993.CODES]
    if unknown:
        parser.error(f"unknown lproj(s): {', '.join(unknown)}")
    if not set(args.crash_control) & set(args.lprojs):
        parser.error("at least one --crash-control language must be among the languages run")
    if not os.path.isabs(os.environ.get("LPM_EVIDENCE_ROOT", "")):
        parser.error("LPM_EVIDENCE_ROOT must be set by the caller to an absolute path")
    lock = os.environ.get("LPM_LIVE_LOCK") or ""
    if not os.path.isfile(lock):
        parser.error(f"LPM_LIVE_LOCK must name an existing lock file held by the caller (got {lock!r})")
    return args


def sha256_of(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def menu_level():
    import Quartz
    return int(Quartz.CGWindowLevelForKey(Quartz.kCGPopUpMenuWindowLevelKey))


def logic_windows():
    """Logic-owned on-screen windows below the pop-up menu level, or None when the list is unread."""
    try:
        import Quartz
        windows = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly,
                                                    Quartz.kCGNullWindowID)
        if windows is None:
            return None
        level = menu_level()
        found = []
        for window in windows:
            if not E._is_logic_owned_window(window):
                continue
            layer = int(window.get(Quartz.kCGWindowLayer) or 0)
            if layer >= level:
                continue
            bounds = dict(window.get(Quartz.kCGWindowBounds) or {})
            found.append({"id": int(window.get(Quartz.kCGWindowNumber)), "layer": layer,
                          "bounds": {key: int(value) for key, value in bounds.items()}})
        return found
    except Exception:  # noqa: BLE001 - an unread window list is not an empty one
        return None


def new_windows(windows, baseline_ids):
    return None if windows is None else [w for w in windows if w["id"] not in baseline_ids]


def one_button_dialogs():
    """`{"count", "texts"}` with each text as a digest and a length, or None when unread."""
    raw = L993.osa(ONE_BUTTON_DIALOGS)
    if raw is None:
        return None
    count, _, joined = raw.partition(FIELD)
    try:
        number = int(count)
    except ValueError:
        return None
    texts = joined.split(FIELD) if number else []
    return {"count": number,
            "texts": [{"sha256": hashlib.sha256(t.encode("utf-8")).hexdigest(), "length": len(t)}
                      for t in texts]}


class WindowWatch:
    """Lists Logic's windows on a thread while a call runs; records each one not in the baseline."""

    def __init__(self, baseline_ids):
        self.baseline = set(baseline_ids)
        self.seen = {}
        self.reads = 0
        self.unread = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._start = None

    def _run(self):
        while not self._stop.is_set():
            windows = logic_windows()
            at = round(time.monotonic() - self._start, 3)
            self.reads += 1
            if windows is None:
                self.unread += 1
            else:
                for window in new_windows(windows, self.baseline):
                    row = self.seen.setdefault(window["id"], dict(window, first_seen=at))
                    row["last_seen"] = at
            self._stop.wait(WATCH_INTERVAL)

    def __enter__(self):
        self._start = time.monotonic()
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._stop.set()
        self._thread.join(timeout=2)
        return False

    def result(self):
        return {"reads": self.reads, "unread": self.unread, "new_windows": list(self.seen.values())}


def inner_region(w, h):
    """The dialog inside its rounded edge, in window points.

    Measured 2026-10-01 (#1077, de pilot): two captures of the same warning 1.5 s apart differed in
    5 pixels of 594x500, by at most 2 levels, every one within 7 points of the edge, beside the
    top-right and bottom-left corners. Every pixel further in was identical. That the rounded
    outline is blended with what Logic draws behind it is the likely cause and was not measured,
    so the comparison and the settling are judged 16 points inside the edge.
    """
    return (EDGE_POINTS, EDGE_POINTS, max(0, w - 2 * EDGE_POINTS), max(0, h - 2 * EDGE_POINTS))


def capture(ev, tag, window):
    """Capture one window by number, settled inside its edge."""
    bounds = window.get("bounds") or {}
    w, h = bounds.get("Width", 0), bounds.get("Height", 0)
    return ev.shot(tag, settle_region=inner_region(w, h),
                   window={"id": window["id"], "title": "", "x": bounds.get("X", 0),
                           "y": bounds.get("Y", 0), "w": w, "h": h})


def first_track(driver):
    driver.tool("logic_system", "refresh_cache", {})
    rows = [t for t in ((driver.resource("logic://tracks") or {}).get("data") or [])
            if isinstance(t, dict) and isinstance(t.get("id"), int)]
    return rows[0] if rows else None


def drive(ev, binary, tag, photograph):
    """One launch's Write press by one binary, and the readings around it."""
    result = {}
    driver = E.Driver(binary=binary)
    try:
        track = first_track(driver)
        result["track"] = track
        if track is None:
            result["error"] = "logic://tracks listed no track with an id"
            return result
        result["toggle_view"] = driver.tool("logic_navigate", "toggle_view", {"view": "automation"})
        read = driver.tool("logic_tracks", "set_automation", {"index": track["id"], "mode": "read"})
        if isinstance(read, dict) and "observed_mode" not in read:
            # As in #904: the toggle may have HIDDEN a view the fixture already showed.
            result["first_read"] = read
            result["second_toggle_view"] = driver.tool("logic_navigate", "toggle_view",
                                                       {"view": "automation"})
            read = driver.tool("logic_tracks", "set_automation", {"index": track["id"], "mode": "read"})
        result["read"] = read
        before = logic_windows()
        result["before_write"] = {"windows": before, "one_button_dialogs": one_button_dialogs()}
        if before is None:
            result["error"] = "the window list was not read before the write press"
            return result
        baseline = {w["id"] for w in before}
        with WindowWatch(baseline) as watch:
            started = time.monotonic()
            result["write"] = driver.tool("logic_tracks", "set_automation",
                                          {"index": track["id"], "mode": "write"})
            result["write_seconds"] = round(time.monotonic() - started, 3)
        result["during_write"] = watch.result()
        after = new_windows(logic_windows(), baseline)
        result["after_reply"] = {"new_windows": after, "one_button_dialogs": one_button_dialogs()}
        first_shot = capture(ev, f"{tag}-dialog-after-reply", after[0]) if photograph and after else None
        time.sleep(SURVIVAL_SECONDS)
        later = new_windows(logic_windows(), baseline)
        result["after_survival"] = {"new_windows": later, "one_button_dialogs": one_button_dialogs()}
        if first_shot and first_shot.get("window") and later \
                and any(w["id"] == after[0]["id"] for w in later):
            second_shot = capture(ev, f"{tag}-dialog-after-survival", after[0])
            size = (first_shot["window"]["w"], first_shot["window"]["h"])
            ev.visual(f"{tag}-dialog-unchanged", first_shot["file"], second_shot["file"],
                      inner_region(*size), expect_change=False,
                      why="nothing dismissed or changed the window the Write press raised",
                      subject="the inside of the rounded edge of the Logic window below the pop-up "
                              "menu level that the window server first listed after this "
                              "control's Write press",
                      window_points=size)
        return result
    finally:
        driver.close()
        stray = subprocess.run(["/usr/bin/pgrep", "-f", binary], capture_output=True, text=True)
        result["server_pids_after_close"] = stray.stdout.split()
        for pid in result["server_pids_after_close"]:
            subprocess.run(["/bin/kill", "-9", pid], capture_output=True)


def host_block(worktree):
    """Scripts/observation_host.py's host block, or the error it gave."""
    result = subprocess.run([sys.executable, os.path.join(worktree, "Scripts", "observation_host.py")],
                            capture_output=True, text=True)
    try:
        return json.loads(result.stdout)
    except ValueError:
        return {"error": (result.stderr or "")[-300:]}


def crash_reports():
    """The Logic crash reports on disk, or None when the directory is unreadable."""
    try:
        os.listdir(DIAGNOSTIC_REPORTS)
    except OSError:
        return None
    return set(glob.glob(os.path.join(DIAGNOSTIC_REPORTS, "Logic Pro-*.ips")))


def quit_and_read():
    """Quit Logic through live_993, then list the crash reports that appeared within CRASH_WAIT.

    The process is counted before the quit and after the wait with live_993's `logic_census`, which
    keeps a count that did not read apart from a count of 0. `quit_logic` alone cannot witness the
    quit: it returns True without quitting when its own first count does not read.
    """
    before = crash_reports()
    census_before = L993.logic_census()
    started = time.monotonic()
    quit_returned = L993.quit_logic()
    seconds = round(time.monotonic() - started, 3)
    time.sleep(CRASH_WAIT)
    after = crash_reports()
    return {"quit_returned": quit_returned, "quit_seconds": seconds,
            "census_before": census_before, "census_after": L993.logic_census(),
            "new_crash_reports": None if before is None or after is None
            else sorted(os.path.basename(p) for p in after - before)}


def quit_witnessed(quit):
    """Logic read as running before the quit, the quit returned True, and Logic read as gone after.

    A census that did not read, or answered something other than a count, is not "gone", and a quit
    that returned anything but True is not a quit, whatever the count says afterwards.
    """
    quit = quit if isinstance(quit, dict) else {}
    return (quit.get("quit_returned") is True
            and (quit.get("census_before") or {}).get("status") == "running"
            and (quit.get("census_after") or {}).get("status") == "gone")


def control_left_it_up(phase):
    """The warning was not there before the press, and was up at both readings after the reply."""
    before = ((phase or {}).get("before_write") or {}).get("one_button_dialogs") or {}
    after = (phase or {}).get("after_reply") or {}
    later = (phase or {}).get("after_survival") or {}
    kept = ({w["id"] for w in after.get("new_windows") or []}
            & {w["id"] for w in later.get("new_windows") or []})
    return (before.get("count") == 0
            and (after.get("one_button_dialogs") or {}).get("count") == 1
            and (later.get("one_button_dialogs") or {}).get("count") == 1
            and bool(kept))


def candidate_cleared_it(phase):
    """The reply names the acknowledged alert, a window came during the call, and none is left."""
    phase = phase or {}
    reply = phase.get("write") if isinstance(phase.get("write"), dict) else {}
    before = (phase.get("before_write") or {}).get("one_button_dialogs") or {}
    during = phase.get("during_write") or {}
    after = phase.get("after_reply") or {}
    later = phase.get("after_survival") or {}
    return (reply.get("reconciled_modal_kind") == "informational_alert"
            and reply.get("reconciled_action") == "acknowledge_alert"
            and reply.get("modal_after_press") == "clear"
            and before.get("count") == 0
            and bool(during.get("new_windows"))
            and after.get("new_windows") == [] and later.get("new_windows") == []
            and (after.get("one_button_dialogs") or {}).get("count") == 0
            and (later.get("one_button_dialogs") or {}).get("count") == 0)


def quit_left_no_crash(quit):
    return quit_witnessed(quit) and quit.get("new_crash_reports") == []


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

    ev = E.Evidence(args.head, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")
    ev.note("1077/binaries", {"candidate": args.candidate, "candidate_sha256": sha256_of(args.candidate),
                              "control": args.control, "control_sha256": sha256_of(args.control),
                              "lprojs": args.lprojs, "crash_control": args.crash_control})
    runs, failures = {}, {}
    recording = ev.record_screen(seconds=RECORDING_SECONDS_PER_LANGUAGE * len(args.lprojs) + 120)
    restored = {}
    try:
        for lproj in args.lprojs:
            row = runs[lproj] = {}
            for role, binary in (("control", args.control), ("candidate", args.candidate)):
                tag = f"1077/{lproj}/{role}"
                language = L993.switch_to(lproj, force=True)
                row[f"{role}_launch"] = language
                if language.get("arrange_window") is None \
                        or language.get("language_setting", [])[:1] != [L993.CODES[lproj]]:
                    failures[lproj] = f"the fixture did not open in this language for the {role}"
                    break
                # Generated while Logic is in this language, so a record written from this run
                # takes its host block from the run rather than from the Korean it ends in.
                row[f"{role}_host"] = host_block(args.worktree)
                phase = drive(ev, binary, tag, photograph=role == "control")
                row[role] = phase
                if role == "control" and lproj not in args.crash_control:
                    row["control_acknowledged"] = L993.osa(ACKNOWLEDGE)
                    row["control_after_acknowledge"] = one_button_dialogs()
                row[f"{role}_quit"] = quit_and_read()
                ev.note(tag, {"host": row[f"{role}_host"], "launch": language, "phase": phase,
                              "quit": row[f"{role}_quit"],
                              "acknowledged": row.get("control_acknowledged"),
                              "after_acknowledge": row.get("control_after_acknowledge")})
                reply = phase.get("write") if isinstance(phase.get("write"), dict) else {}
                print(json.dumps({"lproj": lproj, "role": role, "error": phase.get("error"),
                                  "state": reply.get("state"),
                                  "reconciled_modal_kind": reply.get("reconciled_modal_kind"),
                                  "reconciled_action": reply.get("reconciled_action"),
                                  "modal_after_press": reply.get("modal_after_press"),
                                  "after_reply": phase.get("after_reply"),
                                  "quit": row[f"{role}_quit"]}, ensure_ascii=False), flush=True)
                if not quit_witnessed(row[f"{role}_quit"]):
                    failures[lproj] = (f"the {role}'s quit was not witnessed: it did not return "
                                       f"True, or Logic was not counted running before it and "
                                       f"gone after it")
                    break
            if lproj in failures:
                break
    finally:
        try:
            restored = L993.switch_to(L993.RESTORE, force=True)
        except Exception as exc:  # noqa: BLE001 - recorded as a failed restoration
            restored = {"error": f"Korean restoration raised: {exc!r}"}
        restored["language_setting_after_restore"] = L993.language_setting()
        restored["window_names_after_restore"] = L993.window_names()
        restored["ok"] = (restored.get("arrange_window") is not None
                          and restored["language_setting_after_restore"][:1] == [L993.CODES[L993.RESTORE]]
                          and restored["arrange_window"] in (restored["window_names_after_restore"] or []))
        ev.restored("1077/Logic-language-restored-to-Korean", restored["ok"], repr(restored))
        ev.stop_recording(recording)

    ev.note("1077/locale-failures", failures)
    for lproj in args.lprojs:
        row = runs.get(lproj) or {}
        ev.falsifiable(f"1077/{lproj}/control-leaves-the-warning-up", control_left_it_up,
                       row.get("control"), row.get("candidate"),
                       "the base binary's Write press leaves a one-button Logic dialog up after the "
                       "reply and 1.5 s later, where none was up before the press",
                       mutation="none: this is the positive control; a Logic that raised no warning "
                                "would fail it and void the candidate check")
        ev.falsifiable(f"1077/{lproj}/candidate-clears-the-warning", candidate_cleared_it,
                       row.get("candidate"), row.get("control"),
                       "the candidate's reply names informational_alert, acknowledge_alert and "
                       "modal_after_press clear; a Logic window appeared during the call; no new "
                       "window and no one-button dialog is left after the reply or 1.5 s later",
                       mutation="drop the modal poll after the mode press (MCUChannel "
                                "executeAutomation): the warning stays up as it does for the control")
        ev.check(f"1077/{lproj}/candidate-quit-leaves-no-crash-report",
                 quit_left_no_crash(row.get("candidate_quit")),
                 "the quit that follows the candidate's Write press returned True, Logic's process "
                 "count read as running before it and as 0 after it, and no Logic Pro crash report "
                 "appeared within 8 s",
                 row.get("candidate_quit"),
                 "drop the modal poll after the mode press: the quit then meets the warning, as the "
                 "control's does")
    crashed = {lproj: (runs.get(lproj) or {}).get("control_quit") for lproj in args.crash_control}
    ev.check("1077/control-quit-under-the-warning-writes-a-crash-report",
             any(bool((q or {}).get("new_crash_reports")) for q in crashed.values()),
             "quitting Logic with the base binary's warning still up writes a Logic Pro crash report "
             "in at least one crash-control language, so the crash reading can see a crash",
             crashed,
             "none: this is the positive control for the crash reading")
    out = ev.write()
    clean = E.is_clean(out)
    print(json.dumps({"written": out, "is_clean": clean, "failures": failures,
                      "korean_restored": restored.get("ok")}, ensure_ascii=False))
    return 0 if clean and not failures else 1


if __name__ == "__main__":
    sys.exit(main())
