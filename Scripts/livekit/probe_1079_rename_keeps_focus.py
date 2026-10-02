#!/usr/bin/env python3
"""#1079: does an inline track rename keep Logic's keyboard focus while the server sits idle?

Usage: LPM_LIVE_LOCK=<held lock> /usr/bin/python3 Scripts/livekit/probe_1079_rename_keeps_focus.py \\
       <control-binary> <candidate-binary> <out.json> [samples]

Three conditions, `samples` each (default 3), in the Logic that is open:
  none       -- no server, so the probe's own focus reads alone;
  control    -- a server without the #1079 yield, connected and idle;
  candidate  -- a server with it, connected and idle.

Each sample makes the arrange window key, gives the Tracks header rail the focus, presses Track >
Rename Track (canon labels through System Events), and requires the focused element to be an
AXTextField, trying once more if it is not. It then reads the focus every 0.5 s
for HOLD seconds, typing nothing, and records when the role stops being AXTextField. A rename still
open at the end is cancelled with one Escape, sent only while Logic holds the keyboard.

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

HOLD = 20.0


def build_helper():
    out = os.path.join(tempfile.mkdtemp(prefix="lpm1079-"), "helper")
    subprocess.run(["swiftc", "-O", os.path.join(HERE, "ax_1079_rename_focus.swift"), "-o", out],
                   check=True, capture_output=True)
    return out


def focused_role(helper):
    try:
        return json.loads(subprocess.run([helper, "focus"], capture_output=True, text=True,
                                         timeout=5).stdout).get("role")
    except (subprocess.SubprocessError, ValueError):
        return None


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
            row["skipped"] = "the keyboard is not Logic's"
            return row
        row["pressed"] = open_rename(helper)
        time.sleep(0.5)
        row["role_at_start"] = focused_role(helper)
        if row["role_at_start"] != "AXTextField":
            row["first_attempt_role"] = row["role_at_start"]
            row["pressed"] = open_rename(helper)
            time.sleep(0.5)
            row["role_at_start"] = focused_role(helper)
        if row["role_at_start"] != "AXTextField":
            row["skipped"] = "the rename did not open a text field"
            return row
        started, lost, reads, role = time.monotonic(), None, 0, None
        while time.monotonic() - started < HOLD:
            role = focused_role(helper)
            reads += 1
            if role != "AXTextField":
                lost = round(time.monotonic() - started, 2)
                break
            time.sleep(0.5)
        row.update(focus_lost_after_s=lost, reads=reads, role_after=role)
        if lost is None and P.keyboard_owner_is_logic() is True:
            P.post_escape()
            time.sleep(0.5)
        row["role_after_cancel"] = focused_role(helper)
        return row
    finally:
        if driver is not None:
            driver.close()


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    control, candidate, out = sys.argv[1], sys.argv[2], sys.argv[3]
    samples = int(sys.argv[4]) if len(sys.argv) > 4 else 3
    if not os.environ.get("LPM_LIVE_LOCK") or not os.path.exists(os.environ["LPM_LIVE_LOCK"]):
        sys.exit("cannot run: LPM_LIVE_LOCK must name a held lock")
    E.REPO = os.path.dirname(os.path.dirname(HERE))
    if E.screen_is_locked() is not False:
        sys.exit("cannot run: the screen is locked or its state did not read; nothing was sent to Logic")
    helper = build_helper()
    rows = []
    for condition, binary in (("none", None), ("control", control), ("candidate", candidate)):
        for n in range(samples):
            rows.append(sample(helper, condition, binary, n))
            print(json.dumps(rows[-1], ensure_ascii=False), flush=True)
            time.sleep(1.0)
    def sha256(path):
        with open(path, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()
    binaries = {"control": control, "control_sha256": sha256(control),
                "candidate": candidate, "candidate_sha256": sha256(candidate)}
    with open(out, "w", encoding="utf-8") as handle:
        json.dump({"binaries": binaries, "hold_seconds": HOLD, "rows": rows}, handle, ensure_ascii=False, indent=1)
    lost = {c: sum(1 for r in rows if r["condition"] == c and r.get("focus_lost_after_s") is not None)
            for c in ("none", "control", "candidate")}
    print(json.dumps({"lost": lost}))
    return 0 if lost["none"] == 0 and lost["candidate"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
