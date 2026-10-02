#!/usr/bin/env python3
"""#1079: does an inline track rename keep Logic's keyboard focus while the server sits idle?

Usage: LPM_LIVE_LOCK=<held lock> LPM_LOCALE_FIXTURE=<fixture> /usr/bin/python3 \\
       Scripts/livekit/probe_1079_rename_keeps_focus.py <control-binary> <candidate-binary> <out.json> \\
       [--samples N] [--lprojs lproj ...] [--subscribe]
       (default: two samples, all ten languages; Korean is restored at the end)

Per language, on a fresh launch of the locale-campaign fixture, three conditions, `samples` each, in
this order:
  none       -- no server, so the probe's own focus reads alone;
  candidate  -- a server with the #1079 yield, connected and idle;
  control    -- a server without it, connected and idle.

Each sample makes the arrange window key, gives the Tracks header rail the focus, presses Track >
Rename Track (canon labels through System Events), and reads the focus every 0.1 s for OPEN_WAIT
seconds until it is an AXTextField with a string value: that first sighting, and the field's frame,
is what makes the rename OPEN. Kept means that same field, at that frame, still has the focus. Only a press
after which no text field was ever seen is tried once more; a field that was seen and then left is
a focus loss, never a retry. It then reads the focus every 0.5 s for HOLD seconds and types one key
every TYPE_EVERY seconds at the HID tap, and records when the role stops being AXTextField and how
long the field's value grew while it held. The key is the letter K; under the 2-Set Korean source this
machine runs, a letter that reaches Logic outside a text field runs nothing (#1039), so a control
sample that loses the field types into nothing. A rename still open at the end is cancelled with
one Escape, sent only while Logic holds the keyboard, which leaves the name as it was.
With --subscribe, each server is first subscribed to every resource a poll cycle publishes, so a
cycle's publication reads them back (#1079 review R3). The notifications that arrive during the
idle wait are counted: a server sample with none fails, since its publication was not shown to run.

Before each sample the focus is left on the Tracks rail (`settle_focus`), and the role read there is
recorded; a sample that cannot leave a text field does not run.
PASS: every sample in every language opened its rename; every none and candidate sample kept the
field for HOLD seconds and its value grew; and the control lost the field in at least one sample
per language, so the run shows the defect it rules out. A sample that did not run or did not open
fails the run instead of counting toward it.

Measured 2026-10-02 (Korean Logic 12.3, the locale-campaign fixture): none 3 of 3 kept the field
for 20 s; the control lost it in 3 of 3, after 2.18, 1.66 and 0.55 s, the focus moving to an AXSlider
or an AXCheckBox; the candidate kept it in 3 of 3
(docs/observations/2026-10-02-ko-KR-an-idle-poll-ends-an-inline-track-rename.json).
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import evidence as E  # noqa: E402
import probe_942_escape_over_goto_dialog as P  # noqa: E402


def _load_harness(name):
    """A live harness is an entry point (check-dead-harness-helpers), so its language switch is
    loaded from its file rather than imported."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


L993 = _load_harness("live_993_plugin_root_menu_in_every_locale")

HOLD = 20.0
OPEN_WAIT = 2.0
TYPE_EVERY = 1.0
TYPE_KEY = 40  # K


def build_helper():
    out = os.path.join(tempfile.mkdtemp(prefix="lpm1079-"), "helper")
    subprocess.run(["swiftc", "-O", os.path.join(HERE, "ax_1079_rename_focus.swift"), "-o", out],
                   check=True, capture_output=True)
    return out


def focus(helper):
    """The focused element's role and value length, or {} when the focus did not read."""
    try:
        return json.loads(subprocess.run([helper, "focus"], capture_output=True, text=True,
                                         timeout=5).stdout)
    except (subprocess.SubprocessError, ValueError):
        return {}


def focused_role(helper):
    return focus(helper).get("role")


def post_key(code):
    """One key, down and up, at the HID tap: what a person typing sends."""
    import Quartz
    source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for down in (True, False):
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateKeyboardEvent(source, code, down))


def is_rename_field(reading):
    """A text field with a string value and a frame: the rename field shows the track's name. A
    focused text field with no string value was seen in the Korean run of 2026-10-02 after a slow
    open, and Escape did not close it, so it was not the rename."""
    return (reading.get("role") == "AXTextField" and reading.get("value_length") is not None
            and reading.get("frame") is not None)


def wait_for_field(helper):
    """(seconds, frame) when the focus first read as the rename field, or (None, None) within
    OPEN_WAIT."""
    started = time.monotonic()
    while time.monotonic() - started < OPEN_WAIT:
        reading = focus(helper)
        if is_rename_field(reading):
            return round(time.monotonic() - started, 2), reading["frame"]
        time.sleep(0.1)
    return None, None


def open_rename(helper):
    # The rename opens only from the Tracks area. After a focus loss the key focus sat on a slider and
    # the next rename did not open (2026-10-02), so the rail is given the focus before every rename.
    P.osa('tell application "Logic Pro" to activate')
    subprocess.run([helper, "keymain", *P.names("arrangeWindowTitleSuffix")], capture_output=True,
                   text=True, timeout=10)
    subprocess.run([helper, "focusrail", *P.names("trackHeadersDescription")], capture_output=True,
                   text=True, timeout=15)
    for bar in P.names("trackMenuBar"):
        for item in P.names("renameTrackMenuItem"):
            clicked = P.osa('with timeout of 4 seconds\ntell application "System Events" to tell process '
                            f'"Logic Pro" to click menu item {P.applescript_string(item)} of menu 1 of '
                            f'menu bar item {P.applescript_string(bar)} of menu bar 1\nend timeout', timeout=8)
            if clicked is not None:
                return {"bar": bar, "item": item}
    return None


SUBSCRIBE_ALL = ("logic://project/info", "logic://tracks", "logic://transport/state", "logic://mixer",
             "logic://markers", "logic://project/audit")
SUBSCRIBE = SUBSCRIBE_ALL
SUBSCRIBING = False


def subscribe_and_count(driver, uris, seconds):
    """Subscribe to `uris` and, for `seconds`, count the resources/updated notifications the server
    sends. Returns ([accepted per uri], notifications).

    The server's output is read by one thread, line by line, into a queue. The first version
    called select() on the pipe after the client's own reads, and those reads had already
    buffered lines past the replies, so select() saw nothing and notifications that had arrived
    were counted as none (2026-10-03: four of six French samples read 0 with identical
    starting screens)."""
    import queue
    import threading
    lines = queue.Queue()

    def pump():
        while True:
            line = driver.proc.stdout.readline()
            lines.put(line)
            if not line:
                return

    ids = []
    for uri in uris:
        driver._id += 1
        ids.append(driver._id)
        driver._write({"jsonrpc": "2.0", "id": driver._id, "method": "resources/subscribe",
                       "params": {"uri": uri}})
    threading.Thread(target=pump, daemon=True).start()
    replies, notifications = {}, 0
    deadline = time.monotonic() + seconds
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            break
        try:
            line = lines.get(timeout=left)
        except queue.Empty:
            break
        if not line:
            break
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if message.get("id") in ids:
            replies[message["id"]] = "error" not in message
        elif message.get("method") == "notifications/resources/updated":
            notifications += 1
    return [replies.get(i, False) for i in ids], notifications


TEXT_ROLES = ("AXTextField", "AXTextArea")


def settle_focus(helper):
    """Leave the focus on the Tracks rail before a sample starts, and return its role. A sample
    that lost the field can leave a text field focused, and a server started then yields from its
    first tick, so its publication never runs (seen 2026-10-03: the candidate's first subscribed
    sample in every language had no notification). Up to three rounds: an Escape, sent only while
    Logic holds the keyboard and a text field has the focus, then the rail. Every round is returned,
    so a sample that could not leave a text field says why (seen in German: two in a row)."""
    attempts = []
    for _ in range(3):
        P.osa('tell application "Logic Pro" to activate')
        role = focused_role(helper)
        owner = P.keyboard_owner_is_logic()
        escaped = role in TEXT_ROLES and owner is True
        if escaped:
            P.post_escape()
            time.sleep(0.7)
        subprocess.run([helper, "keymain", *P.names("arrangeWindowTitleSuffix")], capture_output=True,
                       text=True, timeout=10)
        subprocess.run([helper, "focusrail", *P.names("trackHeadersDescription")], capture_output=True,
                       text=True, timeout=15)
        after = focused_role(helper)
        attempts.append({"role": role, "keyboard_owner_is_logic": owner, "escaped": escaped, "role_after": after})
        if after not in TEXT_ROLES:
            break
    return attempts


def server_trace(driver, start_ms, end_ms):
    """The `poll-trace` lines a debug build writes to stderr under LOGIC_MCP_DEBUG_POLL_TRACE=1,
    between two wall-clock times, as [ms, stage]. Empty for a build without the trace."""
    out = []
    try:
        with open(driver._stderr_path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if not line.startswith("poll-trace "):
                    continue
                _, ms, stage = line.rstrip("\n").split(" ", 2)
                if start_ms <= int(ms) <= end_ms:
                    out.append([int(ms), stage[:160]])
    except (OSError, ValueError):
        pass
    return out[-300:]


def sample(helper, condition, binary, n):
    row, driver = {"condition": condition, "sample": n}, None
    try:
        row["settle"] = settle_focus(helper)
        row["role_before_server"] = row["settle"][-1]["role_after"]
        if row["role_before_server"] in TEXT_ROLES:
            row["outcome"] = "not_run"
            row["why"] = "a text field kept the focus before the server started"
            return row
        if binary:
            driver = E.Driver(binary=binary)
            if SUBSCRIBING:
                # The first publication after a subscription notifies every resource, since the
                # notifier has no earlier content to compare with: these show it ran.
                row["subscribed"], row["notifications_before_rename"] = subscribe_and_count(
                    driver, SUBSCRIBE, 6.0)
            else:
                time.sleep(4.0)  # the idle poll runs
        if P.keyboard_owner_is_logic() is not True:
            row["outcome"] = "not_run"
            row["why"] = "the keyboard is not Logic's"
            return row
        row["attempts"] = []
        opened, frame = None, None
        for _ in range(2):
            pressed = open_rename(helper)
            opened, frame = wait_for_field(helper)
            row["attempts"].append({"pressed": pressed, "field_seen_after_s": opened, "frame": frame})
            if opened is not None:
                break
        if opened is None:
            row["outcome"] = "not_opened"
            return row
        row["opened_epoch_ms"] = int(time.time() * 1000)
        started, lost, reads, typed = time.monotonic(), None, [], 0
        next_key = started + TYPE_EVERY
        while time.monotonic() - started < HOLD:
            reading = focus(helper)
            reads.append({"t": round(time.monotonic() - started, 2), "role": reading.get("role"),
                          "value_length": reading.get("value_length"),
                          "same_field": reading.get("frame") == frame})
            # Kept means the same field: a text field elsewhere taking the focus is a loss too.
            if not (is_rename_field(reading) and reading.get("frame") == frame):
                lost = reads[-1]["t"]
                row["lost_epoch_ms"] = int(time.time() * 1000)
                break
            if time.monotonic() >= next_key:
                post_key(TYPE_KEY)
                typed += 1
                next_key += TYPE_EVERY
            time.sleep(0.5)
        lengths = [r["value_length"] for r in reads if r["same_field"] and r["value_length"] is not None]
        row.update(focus_lost_after_s=lost, typed=typed, reads=len(reads),
                   role_after=reads[-1]["role"] if reads else None,
                   value_grew_by=(lengths[-1] - lengths[0]) if len(lengths) >= 2 else None,
                   outcome="lost" if lost is not None else "kept")
        if lost is None and P.keyboard_owner_is_logic() is True:
            P.post_escape()
            time.sleep(0.5)
        row["role_after_cancel"] = focused_role(helper)
        return row
    finally:
        if driver is not None:
            if os.environ.get("LOGIC_MCP_DEBUG_POLL_TRACE") == "1" and row.get("opened_epoch_ms"):
                row["trace"] = server_trace(driver, row["opened_epoch_ms"] - 6000,
                                            row.get("lost_epoch_ms", row["opened_epoch_ms"] + 3000) + 500)
            driver.close()


CONDITIONS = ("none", "candidate", "control")


def verdict(rows, lprojs, conditions, samples):
    """Per language: every sample ran and opened; none and candidate kept the field and typed into
    it; the control lost it at least once. A run without all three conditions is a search and
    cannot pass, and every (language, condition, sample) asked for must have a row: a broken
    candidate must not be able to pass a run that never ran it (supplementary review S-02). The
    languages, conditions and sample count are required: without them no call can know what is
    missing, and the first repair kept a default call that passed candidate-free rows."""
    failures = []
    if tuple(sorted(conditions)) != tuple(sorted(CONDITIONS)):
        failures.append(f"conditions {', '.join(conditions)}: a search, not a verdict")
    have = {(r.get("lproj"), r.get("condition"), r.get("sample")) for r in rows}
    for lproj in lprojs:
        for condition in conditions:
            for n in range(samples):
                if (lproj, condition, n) not in have:
                    failures.append(f"{lproj}/{condition}/{n}: no row")
    for row in rows:
        if SUBSCRIBING and row["condition"] in ("control", "candidate") and row.get("outcome") in ("kept", "lost"):
            if not row.get("subscribed") or not all(row["subscribed"]):
                failures.append(f"{row['lproj']}/{row['condition']}/{row['sample']}: a subscription was refused")
            if not row.get("notifications_before_rename"):
                failures.append(f"{row['lproj']}/{row['condition']}/{row['sample']}: no notification arrived, so no publication was shown to run")
        if row.get("outcome") not in ("kept", "lost"):
            failures.append(f"{row['lproj']}/{row['condition']}/{row['sample']}: {row.get('outcome')}")
        elif row["condition"] in ("none", "candidate"):
            if row["outcome"] != "kept":
                failures.append(f"{row['lproj']}/{row['condition']}/{row['sample']}: lost the field")
            elif not row.get("value_grew_by"):
                failures.append(f"{row['lproj']}/{row['condition']}/{row['sample']}: the typing did not reach the field")
    for lproj in sorted({r["lproj"] for r in rows}):
        control = [r for r in rows if r["lproj"] == lproj and r["condition"] == "control"]
        if not any(r.get("outcome") == "lost" for r in control):
            failures.append(f"{lproj}/control: never lost the field, so the run shows no defect to rule out")
    return failures


def arguments():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("control")
    parser.add_argument("candidate")
    parser.add_argument("out")
    parser.add_argument("--samples", type=int, default=2)
    parser.add_argument("--lprojs", nargs="+", default=list(L993.DEFAULT_LPROJS))
    parser.add_argument("--subscribe", action="store_true",
                        help="subscribe each server to the resources a poll cycle publishes")
    parser.add_argument("--subscribe-uri", action="append", choices=SUBSCRIBE_ALL, metavar="uri",
                        help="with --subscribe, only this resource (repeatable); to find which one matters")
    parser.add_argument("--conditions", nargs="+", choices=("none", "control", "candidate"),
                        default=["none", "control", "candidate"],
                        help="the conditions to run; a run without all three is a search, not a verdict")
    args = parser.parse_args()
    unknown = [name for name in args.lprojs if name not in L993.CODES]
    if unknown:
        parser.error(f"unknown lproj(s): {', '.join(unknown)}")
    return args


def main():
    args = arguments()
    global SUBSCRIBING, SUBSCRIBE
    SUBSCRIBING = args.subscribe
    if args.subscribe_uri:
        SUBSCRIBE = tuple(args.subscribe_uri)
    if not os.environ.get("LPM_LIVE_LOCK") or not os.path.exists(os.environ["LPM_LIVE_LOCK"]):
        sys.exit("cannot run: LPM_LIVE_LOCK must name a held lock")
    E.REPO = os.path.dirname(os.path.dirname(HERE))
    sys.path.insert(0, os.path.join(E.REPO, "Scripts"))
    import logic_canon  # noqa: E402
    setattr(L993, "logic_canon", logic_canon)
    if E.screen_is_locked() is not False:
        sys.exit("cannot run: the screen is locked or its state did not read; nothing was sent to Logic")
    helper = build_helper()
    rows, launches, restored = [], {}, {}
    try:
        for lproj in args.lprojs:
            launch = L993.switch_to(lproj, force=True)
            launches[lproj] = launch
            if launch.get("arrange_window") is None \
                    or launch.get("language_setting", [])[:1] != [L993.CODES[lproj]]:
                rows.append({"lproj": lproj, "condition": "launch", "sample": 0, "outcome": "not_launched"})
                break
            # The control runs last: a sample it loses can leave Logic's rename editor open behind the
            # focus, and a server started then yields from its first tick (2026-10-03, every
            # candidate sample that followed a control loss had no notification).
            for condition, binary in (("none", None), ("candidate", args.candidate), ("control", args.control)):
                if condition not in args.conditions:
                    continue
                for n in range(args.samples):
                    row = sample(helper, condition, binary, n)
                    row["lproj"] = lproj
                    rows.append(row)
                    print(json.dumps(row, ensure_ascii=False), flush=True)
                    time.sleep(1.0)
    finally:
        restored = L993.switch_to(L993.RESTORE, force=True)
        restored["language_setting_after_restore"] = L993.language_setting()

    def sha256(path):
        with open(path, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()
    binaries = {"control": args.control, "control_sha256": sha256(args.control),
                "candidate": args.candidate, "candidate_sha256": sha256(args.candidate)}
    failures = verdict(rows, args.lprojs, args.conditions, args.samples)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump({"binaries": binaries, "hold_seconds": HOLD, "type_every_seconds": TYPE_EVERY,
                   "open_wait_seconds": OPEN_WAIT, "lprojs": args.lprojs, "samples": args.samples,
                   "subscribed_to": list(SUBSCRIBE) if SUBSCRIBING else [],
                   "launches": launches, "korean_restored": restored, "rows": rows,
                   "failures": failures}, handle, ensure_ascii=False, indent=1, default=str)
    print(json.dumps({"failures": failures, "rows": len(rows)}, ensure_ascii=False))
    return 0 if not failures and rows else 1


if __name__ == "__main__":
    sys.exit(main())
