#!/usr/bin/env python3
"""#1079: does an inline track rename keep Logic's keyboard focus while the server sits idle?

Usage: LPM_LIVE_LOCK=<held lock> LPM_LOCALE_FIXTURE=<fixture> /usr/bin/python3 \\
       Scripts/livekit/probe_1079_rename_keeps_focus.py <control-binary> <candidate-binary> <out.json> \\
       [--samples N] [--lprojs lproj ...]
       (default: two samples, all ten languages; Korean is restored at the end)

Per language, on a fresh launch of the locale-campaign fixture, three conditions, `samples` each:
  none       -- no server, so the probe's own focus reads alone;
  control    -- a server without the #1079 yield, connected and idle;
  candidate  -- a server with it, connected and idle.

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


def sample(helper, condition, binary, n):
    row, driver = {"condition": condition, "sample": n}, None
    try:
        if binary:
            driver = E.Driver(binary=binary)
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
            driver.close()


def verdict(rows):
    """Per language: every sample ran and opened; none and candidate kept the field and typed into
    it; the control lost it at least once."""
    failures = []
    for row in rows:
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
    args = parser.parse_args()
    unknown = [name for name in args.lprojs if name not in L993.CODES]
    if unknown:
        parser.error(f"unknown lproj(s): {', '.join(unknown)}")
    return args


def main():
    args = arguments()
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
            for condition, binary in (("none", None), ("control", args.control), ("candidate", args.candidate)):
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
    failures = verdict(rows)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump({"binaries": binaries, "hold_seconds": HOLD, "type_every_seconds": TYPE_EVERY,
                   "open_wait_seconds": OPEN_WAIT, "lprojs": args.lprojs, "samples": args.samples,
                   "launches": launches, "korean_restored": restored, "rows": rows,
                   "failures": failures}, handle, ensure_ascii=False, indent=1, default=str)
    print(json.dumps({"failures": failures, "rows": len(rows)}, ensure_ascii=False))
    return 0 if not failures and rows else 1


if __name__ == "__main__":
    sys.exit(main())
