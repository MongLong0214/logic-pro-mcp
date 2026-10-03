#!/usr/bin/env python3
"""#1092: transport.rewind and transport.fast_forward move the playhead one bar and stop, in every
language, through the route production takes.

No LOGIC_MCP_DEBUG_ONLY_CHANNEL is set, so the server routes each call as a user's would. For each
language Logic is relaunched in it with the fixture and one server is started. Each trial stops the
transport, moves the playhead to bar 9 and reads it back, makes the call, then reads the bar 0.5,
1.5 and 3.0 s after the reply. A step reads 8 (rewind) or 10 (fast_forward) at all three; a shuttle
reads a different bar at each, and a call that did nothing reads 9.

The bar is read by this process from Logic's control bar (canon `playheadPositionGroupLabel`,
`barSliderLabel`), not from the server. The rung that answered is read from the call's operation
trace (`channel.started` / `channel.completed`), not from the reply.

    LPM_LIVE_LOCK=<lock> LPM_EVIDENCE_ROOT=<dir> LPM_LOCALE_FIXTURE=<fixture> \\
        python3 live_1092_rewind_and_forward_step_one_bar.py <worktree> <head> <binary> \\
        [--lprojs en ko ...] [--trials 3]

The run holds LIVE.lock (the caller takes it), moves only the playhead, and leaves Logic in Korean.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import evidence as E  # noqa: E402
import live_993_plugin_root_menu_in_every_locale as L993  # noqa: E402

LABELS = os.path.join(HERE, "..", "..", "docs", "locale", "ui-labels.json")
HISERVICES = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework"
LOGIC_BUNDLE = "com.apple.logic10"
START_BAR = 9
SAMPLES = (0.5, 1.5, 3.0)
STEPS = (("rewind", -1), ("fast_forward", 1))


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("worktree")
    parser.add_argument("head")
    parser.add_argument("binary")
    parser.add_argument("--lprojs", nargs="+", default=list(L993.DEFAULT_LPROJS))
    parser.add_argument("--trials", type=int, default=3)
    return parser.parse_args()


# --- reading Logic from this process -------------------------------------------------------------

def canon_matches(text, key):
    """Whether `text` matches the canon key under its mode, as `AXLocalePolicy` compares."""
    if not text:
        return False
    with open(LABELS, encoding="utf-8") as handle:
        row = json.load(handle)["labels"][key]
    mode, names = row.get("match") or "exact", [row["canonical"], *row["variants"]]
    if mode == "contains":
        return any(name.casefold() in text.casefold() for name in names)
    if mode == "exact_strict":
        return any(text.casefold() == name.casefold() for name in names)
    return any(text.strip().casefold() == name.strip().casefold() for name in names)


class AX:
    def __init__(self):
        import objc
        from Foundation import NSBundle
        self.f = {}
        objc.loadBundleFunctions(NSBundle.bundleWithPath_(HISERVICES), self.f,
                                 [("AXUIElementCreateApplication", b"@i"),
                                  ("AXUIElementCopyAttributeValue", b"i@@o^@"),
                                  ("AXUIElementPerformAction", b"i@@"),
                                  ("AXUIElementSetAttributeValue", b"i@@@")])

    def value(self, element, name):
        status, found = self.f["AXUIElementCopyAttributeValue"](element, name, None)
        return found if status == 0 else None

    def walk(self, element, depth_left):
        yield element
        if depth_left:
            for child in self.value(element, "AXChildren") or []:
                yield from self.walk(child, depth_left - 1)

    def window_titled(self, title):
        pid = logic_pid()
        if pid is None:
            return None
        for window in self.value(self.f["AXUIElementCreateApplication"](pid), "AXWindows") or []:
            if self.value(window, "AXTitle") == title:
                return window
        return None


def logic_pid():
    out = subprocess.run(["/usr/bin/lsappinfo", "info", "-only", "pid", "-app", LOGIC_BUNDLE],
                         capture_output=True, text=True).stdout
    found = re.search(r"=\s*(\d+)", out)
    return int(found.group(1)) if found else None


def playhead_bar(ax, window):
    """The bar Logic's playhead group shows, or None when it did not read."""
    if window is None:
        return None
    for group in ax.walk(window, 8):
        if ax.value(group, "AXRole") == "AXGroup" \
                and canon_matches(ax.value(group, "AXDescription"), "playheadPositionGroupLabel"):
            for slider in ax.walk(group, 8):
                if ax.value(slider, "AXRole") == "AXSlider" \
                        and canon_matches(ax.value(slider, "AXDescription"), "barSliderLabel"):
                    value = ax.value(slider, "AXValue")
                    return int(value) if isinstance(value, (int, float)) else None
    return None


def bring_forward(ax, title):
    """Logic frontmost with the arrange window raised and main: the fixture also opens a Marker List
    window, which holds the focus right after a launch."""
    subprocess.run(["/usr/bin/osascript", "-e", f'tell application id "{LOGIC_BUNDLE}" to activate'],
                   capture_output=True, timeout=10)
    time.sleep(0.8)
    window = ax.window_titled(title)
    if window is not None:
        ax.f["AXUIElementPerformAction"](window, "AXRaise")
        ax.f["AXUIElementSetAttributeValue"](window, "AXMain", True)
        time.sleep(0.3)
    return window


# --- what a call did -----------------------------------------------------------------------------

def stepped(row):
    """A step: the bar read START_BAR before the call, the reply succeeded, the CGEvent rung
    answered, and every reading after it is the bar one away in the call's direction."""
    expected = row["start"] + row["direction"] if isinstance(row.get("start"), int) else None
    return (row.get("start") == START_BAR
            and row.get("reply_success") is True
            and row.get("answered_by") == ["CGEvent"]
            and len(row.get("readings") or []) == len(SAMPLES)
            and all(reading == expected for reading in row["readings"]))


def as_shuttle(row):
    """The counterexample: the same row, with the readings the MCU rung gave in ko on 2026-10-03."""
    shuttle = [5, 2, -3] if row["direction"] < 0 else [13, 16, 19]
    return dict(row, readings=shuttle)


def answered_by(driver, operation):
    """The channels that ran for the newest trace of `operation`, from its channel events."""
    listed = driver.tool("logic_system", "list_recent_traces", {})
    traces = [t for t in (listed or {}).get("traces", []) if t.get("operation_id") == operation]
    if not traces:
        return None, None
    trace_id = traces[0]["trace_id"]
    trace = driver.tool("logic_system", "get_trace", {"trace_id": trace_id}) or {}
    ran = [event["attributes"]["channel"] for event in trace.get("events", [])
           if event.get("phase") == "channel.started" and "channel" in (event.get("attributes") or {})]
    return trace_id, ran


def reply_success(reply):
    if not isinstance(reply, dict):
        return None
    inner = reply.get("write_result") if isinstance(reply.get("write_result"), dict) else reply
    return inner.get("success")


def trial(driver, ax, title, command, direction):
    bring_forward(ax, title)
    driver.tool("logic_transport", "stop", {})
    driver.tool("logic_transport", "goto_position", {"bar": START_BAR})
    time.sleep(1.0)
    window = bring_forward(ax, title)
    start = playhead_bar(ax, window)
    reply = driver.tool("logic_transport", command, {})
    replied = time.monotonic()
    readings = []
    for at in SAMPLES:
        time.sleep(max(0.0, replied + at - time.monotonic()))
        readings.append(playhead_bar(ax, window))
    driver.tool("logic_transport", "stop", {})
    trace_id, ran = answered_by(driver, f"transport.{command}")
    return {"op": f"transport.{command}", "direction": direction, "start": start,
            "readings": readings, "seconds_after_reply": list(SAMPLES),
            "reply_success": reply_success(reply), "reply": reply,
            "trace_id": trace_id, "answered_by": ran}


def embedded_commit(binary):
    """The commit the build embedded in the Mach-O section __TEXT,__lpm_commit, or None when the binary
    carries none. Read from the artifact itself, at the file offset `otool -l` gives for the section,
    it ties the measured binary to its source commit (#1095 review round 2: built_from was the
    worktree's head at writing time, not a measurement)."""
    listing = subprocess.run(["/usr/bin/otool", "-l", binary], capture_output=True, text=True).stdout
    for block in listing.split("Section\n")[1:]:
        if re.search(r"sectname __lpm_commit\b", block) and re.search(r"segname __TEXT\b", block):
            size = int(re.search(r"\bsize 0x([0-9a-f]+)", block).group(1), 16)
            offset = int(re.search(r"\boffset (\d+)", block).group(1))
            with open(binary, "rb") as handle:
                handle.seek(offset)
                text = handle.read(size).decode("ascii", "replace")
            return text if re.fullmatch(r"[0-9a-f]{40}", text) else None
    return None


def provenance_refusal(carried, head):
    """Why the binary may not be driven, or None. It must carry, in __TEXT,__lpm_commit, the full commit
    it is being run as: a missing or malformed stamp is refused like a different one (#1095 review
    round 3, R1092-04). Scripts/livekit/build_attested_binary.sh builds such a binary."""
    if carried is None:
        return (f"the binary carries no commit in __TEXT,__lpm_commit (or a malformed one); build it with "
                f"Scripts/livekit/build_attested_binary.sh at {head}. Nothing was driven.")
    if carried != head:
        return f"the binary carries commit {carried}, not the head {head}. Nothing was driven."
    return None


def sha256_of(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def main():
    args = arguments()
    # The evidence document's artifact block reads these: the binary's sha256, the worktree head it
    # was built from, and whether the tree was clean and the binary newer than its sources.
    E.REPO = args.worktree
    E.BIN = args.binary
    sys.path.insert(0, os.path.join(args.worktree, "Scripts"))
    import logic_canon  # noqa: E402
    setattr(L993, "logic_canon", logic_canon)
    if os.environ.get("LOGIC_MCP_DEBUG_ONLY_CHANNEL"):
        sys.exit("LOGIC_MCP_DEBUG_ONLY_CHANNEL is set; this run measures the production route")
    ev = E.Evidence(args.head, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")
    carried = embedded_commit(args.binary)
    refusal = provenance_refusal(carried, args.head)
    ev.note("1092/binary", {"binary": args.binary, "sha256": sha256_of(args.binary),
                            "embedded_commit": carried, "embedded_commit_is_head": refusal is None})
    if refusal is not None:
        sys.exit(refusal)
    ax = AX()
    rows, failures = [], []
    try:
        for lproj in args.lprojs:
            launch = L993.switch_to(lproj, force=True)
            title = launch.get("arrange_window")
            ev.note(f"1092/{lproj}/launch", launch)
            if not title:
                failures.append({"lproj": lproj, "error": "launch", "launch": launch})
                continue
            deadline = time.monotonic() + 40
            while playhead_bar(ax, ax.window_titled(title)) is None and time.monotonic() < deadline:
                time.sleep(1.0)
            driver = E.Driver(binary=args.binary)
            try:
                time.sleep(5)
                for number in range(args.trials):
                    for command, direction in STEPS:
                        row = dict(trial(driver, ax, title, command, direction), lproj=lproj, trial=number)
                        rows.append(row)
                        ev.falsifiable(f"1092/{lproj}/{number}/{row['op']}", stepped, row, as_shuttle(row),
                                       expected=f"bar {START_BAR} then {START_BAR + direction} at every "
                                                f"sample, answered by CGEvent")
                        print(json.dumps({key: row[key] for key in
                                          ("lproj", "trial", "op", "start", "readings", "answered_by")},
                                         ensure_ascii=False), flush=True)
                        if not stepped(row):
                            failures.append({key: row[key] for key in
                                             ("lproj", "trial", "op", "start", "readings", "answered_by")})
            finally:
                driver.close()
    finally:
        restored = L993.switch_to(L993.RESTORE, force=True)
        ev.note("1092/restore", restored)
    ev.note("1092/rows", rows)
    ev.note("1092/failures", failures)
    out = ev.write()
    print("written", out)
    print(json.dumps({"rows": len(rows), "failures": len(failures)}))
    return 0 if rows and not failures and len(rows) == len(args.lprojs) * args.trials * len(STEPS) else 1


if __name__ == "__main__":
    sys.exit(main())
