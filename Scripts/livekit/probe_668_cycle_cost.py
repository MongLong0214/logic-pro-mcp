#!/usr/bin/env python3
"""Measures what #668 actually turns on: how much of a `refresh_cache` call is the AX walk itself.

Usage:  python3 probe_668_cycle_cost.py <worktree> [concurrent-callers]

WHY THIS IS NOT A `live_*` HARNESS, AND WRITES NO EVIDENCE
----------------------------------------------------------
`Scripts/livekit/live_*.py` is a contract: `harness_evidence_coverage.py` treats any file matching
it as a harness the branch must prove clean, and `is_clean` requires captures, visual assertions and
recordings, "because the zeros have to be earned". This probe never looks at the screen, so it could
not satisfy that honestly — the same reason `probe_289_stale_write_counter.py` was renamed out.

It also deliberately writes NO evidence document. The ship gate binds every `*.evidence.json` at a
head to the built binary, so a diagnostic dropped there starts being read as proof of something.
This prints a report and returns an exit code; it proves nothing and should not look like it does.

THE QUESTION
------------
#668 is "`system.refresh_cache` exceeds its own 25s `.short` deadline on projects around 74 tracks".
Coalescing (#675) bounds a late caller to the remainder of an in-flight cycle plus one fresh cycle —
so the worst case is about **two** cycles. Whether that fits the deadline is therefore a question
about ONE number: the cost of a single uncontended cycle at that project size.

  2 x solo_cycle  <  25s   ->  coalescing has closed this; re-measure and close #668
  2 x solo_cycle  >= 25s   ->  the cycle itself must get cheaper (split it), or `.short` is the
                              wrong deadline class for this operation

WHAT WOULD MAKE THIS VACUOUS, AND WHAT STOPS IT
-----------------------------------------------
1. An unreadable project. `logic://tracks` answers `readable:false` with `reason:
   "no_live_track_read_yet"` when the poller has not read yet, and its `data` is then an empty list.
   Reading that as "0 tracks" is exactly the defect #668 fixed in the receipt — and I made it myself
   in an ad-hoc probe on the day it merged. This refuses to report unless `readable` is true, and
   prints the track count with every number so nobody reads a small-project result as a large one.
2. A cycle that costs nothing. On a project the poller cannot read, cycles return in ~0ms and every
   ratio here is 1.0 while measuring nothing. The floor check below refuses that case by name
   instead of reporting a meaningless zero.
3. Reporting a median over censored samples. A call that hits its deadline is a lower bound, not a
   duration; two of them subtract to about nothing. Ceiling hits are counted and reported
   separately, and the verdict says so rather than averaging them in.
"""
import json
import os
import statistics
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

WT = sys.argv[1] if len(sys.argv) > 1 else ""
CALLERS = int(sys.argv[2]) if len(sys.argv) > 2 else 4
if not WT:
    sys.exit(__doc__)

BIN = f"{WT}/.build/release/LogicProMCP"
if not os.path.exists(BIN):
    sys.exit(f"cannot run: {BIN} does not exist — build release at the head you want to measure")

SHORT_DEADLINE_S = 25.0   # DeadlineClass.short, OperationRegistry.swift
CEILING_S = SHORT_DEADLINE_S * 0.95
FLOOR_S = 0.05            # below this the poller is not really reading anything


class Server:
    """One stdio server, driven by id. Concurrent callers share it, which is the point."""

    def __init__(self):
        self.p = subprocess.Popen(
            [BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self._id = 0
        self._lock = threading.Lock()
        self._pending = {}
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()
        self._call("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "probe-668", "version": "1"}}, budget=60)

    def _read_loop(self):
        for line in self.p.stdout:
            try:
                msg = json.loads(line)
            except Exception:
                continue
            with self._lock:
                slot = self._pending.get(msg.get("id"))
            if slot is not None:
                slot["msg"] = msg
                slot["event"].set()

    def _call(self, method, params, budget):
        with self._lock:
            self._id += 1
            rid = self._id
            slot = {"event": threading.Event(), "msg": None}
            self._pending[rid] = slot
            self.p.stdin.write(json.dumps(
                {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n")
            self.p.stdin.flush()
        slot["event"].wait(budget)
        with self._lock:
            self._pending.pop(rid, None)
        return slot["msg"]

    def refresh(self, budget=SHORT_DEADLINE_S + 10):
        t0 = time.monotonic()
        msg = self._call("tools/call", {
            "name": "logic_system",
            "arguments": {"command": "refresh_cache", "params": {}}}, budget)
        elapsed = time.monotonic() - t0
        body = ((msg or {}).get("result") or {}).get("structuredContent") or {}
        return elapsed, body.get("refreshed")

    def resource(self, uri, budget=60):
        msg = self._call("resources/read", {"uri": uri}, budget)
        try:
            return json.loads(msg["result"]["contents"][0]["text"])
        except Exception:
            return {}

    def close(self):
        try:
            self.p.terminate()
        except Exception:
            pass


def main():
    s = Server()
    try:
        # --- precondition: is this project actually readable, and how big is it? --------------
        s.refresh()                       # one cycle so the poller has read at least once
        tracks = s.resource("logic://tracks")
        readable = tracks.get("readable")
        rows = tracks.get("data")
        count = len(rows) if isinstance(rows, list) else None

        print(f"project: readable={readable!r} reason={tracks.get('reason')!r} tracks={count}")
        if not readable:
            print("REFUSED: the poller has not read this project, so every number below would "
                  "describe an empty walk rather than a project. Open a document and retry.")
            return 2

        # --- solo: one caller, nothing else driving the poller ---------------------------------
        solo, solo_ceiling = [], 0
        for i in range(5):
            time.sleep(4)                 # longer than the 3s poll interval, so the loop is idle
            dt, _ = s.refresh()
            solo.append(dt)
            if dt >= CEILING_S:
                solo_ceiling += 1
            print(f"  solo {i + 1}: {dt:7.2f}s")

        solo_median = statistics.median(solo)
        if solo_median < FLOOR_S:
            print(f"REFUSED: a cycle costs {solo_median:.3f}s here, which means the walk is not "
                  "happening. Every ratio would be 1.0 and mean nothing.")
            return 2

        # --- contended: N callers at once, which is what a nudge burst looks like --------------
        results = [None] * CALLERS
        def one(i):
            results[i] = s.refresh()
        threads = [threading.Thread(target=one, args=(i,)) for i in range(CALLERS)]
        t0 = time.monotonic()
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        wall = time.monotonic() - t0
        contended = [r[0] for r in results if r]
        contended_ceiling = sum(1 for d in contended if d >= CEILING_S)

        print(f"\nsolo      median {solo_median:6.2f}s  max {max(solo):6.2f}s  "
              f"at-ceiling {solo_ceiling}/{len(solo)}")
        print(f"contended median {statistics.median(contended):6.2f}s  max {max(contended):6.2f}s  "
              f"at-ceiling {contended_ceiling}/{len(contended)}  wall {wall:.2f}s "
              f"({CALLERS} callers)")

        # --- the verdict #668 turns on ---------------------------------------------------------
        worst_case = 2 * solo_median
        print(f"\ncoalesced worst case ~= 2 x solo = {worst_case:.2f}s against a "
              f"{SHORT_DEADLINE_S:.0f}s .short deadline")
        if solo_ceiling or contended_ceiling:
            print("CENSORED: at least one sample sat at the deadline ceiling, so it is a lower "
                  "bound, not a duration. The medians above understate the real cost.")
            return 1
        if worst_case < SHORT_DEADLINE_S:
            print(f"FITS at {count} tracks: coalescing bounds a late caller inside the deadline. "
                  "Re-run at the project size #668 names before closing it.")
            return 0
        print(f"EXCEEDS at {count} tracks: the cycle itself has to get cheaper, or .short is the "
              "wrong deadline class for this operation.")
        return 1
    finally:
        s.close()


sys.exit(main())
