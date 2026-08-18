"""Live-evidence recorder for driving Logic Pro through a built LogicProMCP binary.

A unit test says the code does what its fixtures say. Only a run against the real application says it
does what the user needs. This module is the instrument for that run, and it is deliberately hostile to
its own operator: every affordance here exists because a specific class of false evidence was produced
without it.

What it refuses to let you record:

- **An unsettled capture.** A screenshot taken while Logic is still redrawing shows a state nobody was
  ever in. `shot()` takes frames until two consecutive ones are byte-identical, and marks the record
  `settled: false` if they never converge.
- **A capture straddling two displays.** On a multi-monitor desk a window can span screens and the
  resulting image is not what the user sees. Every capture records which display it fell wholly within.
- **A whole-window diff as a visual assertion.** A full-window comparison changes when the clock ticks.
  `visual()` requires an explicit region and states what it expected to happen there.
- **A region measured once and carried as a constant.** A rectangle taken on one window shape silently
  watches something else after a resize — measured, a stale band landed on the Step Sequencer and made
  a negative assertion report movement in a part of the screen the run never touched. Derive the band
  at run time; `track_header_band()` does it for the arrange rail.
- **A check that cannot fail.** `check()` requires you to name the mutation you applied to the product
  that flipped it. A check nobody has seen fail is not evidence.
- **A cached read presented as live.** `provenance()` records the source and age of any value that did
  not come from a fresh read, and marks it unusable as live evidence.

The ship gate (`~/.claude/scripts/lpm-ship.sh` -> `lpm-live-gate.sh`) reads the document this writes and
refuses the push if any of the above is violated. The gate is the enforcement; this module is what makes
compliance the easy path.

Usage:

    import evidence as E
    E.REPO = "/path/to/worktree"
    E.BIN  = f"{E.REPO}/.build/release/LogicProMCP"

    ev = E.Evidence(HEAD_SHA_40_CHARS, os.environ["LPM_EVIDENCE_ROOT"])
    rec = ev.record_screen()             # start a screen recording of the whole run
    d   = E.Driver()                     # MCP stdio client against the built binary

    before = ev.shot("before", settle_region=REGION)
    body   = d.tool("logic_tracks", "delete", {"index": 3})
    after  = ev.shot("after", settle_region=REGION)

    ev.check("523/the-count-drops-by-one", observed == before_n - 1,
             "Logic's own count readout drops by exactly one",
             f"before={before_n} after={observed}",
             "reverted the post-write inventory guard; this check went green on a delete that never happened")
    ev.visual("523/the-readout-changes", before["file"], after["file"], REGION,
              expect_change=True, why="one marker was deleted")
    ev.stop_recording(rec)
    print(json.dumps(ev.write(), indent=1))

`LPM_EVIDENCE_ROOT` must be an absolute path OUTSIDE every worktree of the repository; the gate refuses
otherwise, because evidence living inside the tree can be rewritten by the thing it is judging.
"""

import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import time

# Set by the harness before use.
REPO = ""
BIN = ""

_SETTLE_TRIES = 8
_SETTLE_GAP = 0.35


# ---------------------------------------------------------------------------
# Window geometry
# ---------------------------------------------------------------------------

def logic_window(title_contains="Tracks"):
    """The on-screen bounds of a Logic window, via CoreGraphics rather than AX.

    Deliberately not an AX read: the harness must be able to see the window even when the AX tree is
    exactly what is under test. Returns None when no matching window is on screen.
    """
    try:
        import Quartz
    except ImportError:
        return None
    wins = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)
    for w in wins or []:
        # Measured 2026-08-17: with Logic running in Korean, `kCGWindowOwnerName` comes back as
        # "Logic Pro" — a NO-BREAK SPACE — while English and Japanese give an ordinary space.
        # An exact compare therefore found ZERO Logic windows on a Korean Logic, and every capture
        # in the run recorded `window: null` while Logic was plainly on screen.
        owner = (w.get("kCGWindowOwnerName") or "").replace(" ", " ")
        if owner != "Logic Pro":
            continue
        name = w.get("kCGWindowName") or ""
        if title_contains and title_contains not in name:
            continue
        b = w["kCGWindowBounds"]
        return {"id": w["kCGWindowNumber"], "title": name,
                "x": int(b["X"]), "y": int(b["Y"]),
                "w": int(b["Width"]), "h": int(b["Height"])}
    return None


def track_header_band():
    """The arrange window's track-header rail, in window coordinates, read from AX at run time.

    Use this instead of writing a rectangle into a harness. Every band in this directory started as a
    number measured once, and a number measured once is right until someone resizes a window: the
    #592 harness carried `(603, 162, 325, 406)`, taken on a 1920x1050 window with the Library closed,
    and after the window changed shape that rectangle landed on the Step Sequencer — which animates
    on its own. A NEGATIVE visual assertion over it then reported movement in a part of the screen
    the run had never touched, and failed a run in which nothing was written.

    Against the window that broke it, this returns 366,707 235x1182. Nowhere near the constant.

    Returns None when the rail cannot be located, which a caller should treat as a failed
    precondition rather than a reason to fall back to a guess.

    Two AppleScript hazards are handled here so a caller does not rediscover them:

    - `by` is a reserved word, so a variable named that fails to PARSE rather than to run.
    - `first window whose name is "…"` has been measured answering "invalid index" for a window that
      `name of every window` listed a moment earlier, with a plain-ASCII title that matched exactly.
      So the window is not chosen by name at all: every window is tried until one yields a rail.
      Excluding the chooser by title was not enough either — a run that overlapped an "Import" dialog
      picked that dialog and got nothing.
    """
    script = """
    tell application "System Events" to tell process "Logic Pro"
      -- Chosen by WHAT IT CONTAINS, not by its name. Excluding the project chooser by title was not
      -- enough: a run that overlapped an "Import" dialog picked that dialog as the project window
      -- and the lookup returned nothing. The window this wants is the one that has a track rail, so
      -- every window is tried until one yields it.
      set out to "none"
      repeat with cand in (every window)
        set w to contents of cand
        try
          set wp to position of w
          set ec to entire contents of w
          repeat with e in ec
            set el to contents of e
            try
              if (role of el as text) is equal to "AXLayoutItem" then
                set t to (first UI element of el whose role is "AXTextField")
                set p1 to (value of attribute "AXParent" of el)
                set rail to (value of attribute "AXParent" of p1)
                set rp to position of rail
                set rs to size of rail
                set relX to ((item 1 of rp) - (item 1 of wp)) as integer
                set relY to ((item 2 of rp) - (item 2 of wp)) as integer
                set railW to (item 1 of rs) as integer
                set railH to (item 2 of rs) as integer
                set out to (relX as text) & "," & (relY as text) & "," & (railW as text) & "," & (railH as text)
                exit repeat
              end if
            end try
          end repeat
        end try
        if out is not "none" then exit repeat
      end repeat
      return out
    end tell
    """
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    parts = [p.strip() for p in (r.stdout or "").strip().split(",")]
    if len(parts) != 4 or not all(p.lstrip("-").isdigit() for p in parts):
        return None
    x, y, w, h = (int(p) for p in parts)
    return (x, y, w, h) if w > 0 and h > 0 else None


def _displays():
    try:
        import Quartz
    except ImportError:
        return []
    err, ids, _ = Quartz.CGGetActiveDisplayList(16, None, None)
    if err:
        return []
    out = []
    for i, did in enumerate(ids):
        r = Quartz.CGDisplayBounds(did)
        out.append({"display": i,
                    "bounds": [int(r.origin.x), int(r.origin.y),
                               int(r.size.width), int(r.size.height)]})
    return out


def _display_containing(win):
    """Which display wholly contains this window, if any.

    A window spanning two screens produces a capture that matches nothing the user saw, so the answer
    `wholly_within: False` is recorded rather than silently accepted.
    """
    for d in _displays():
        x, y, w, h = d["bounds"]
        if win["x"] >= x and win["y"] >= y and \
           win["x"] + win["w"] <= x + w and win["y"] + win["h"] <= y + h:
            return {**d, "wholly_within": True}
    ds = _displays()
    return {**(ds[0] if ds else {"display": -1, "bounds": []}), "wholly_within": False}


# ---------------------------------------------------------------------------
# MCP stdio driver
# ---------------------------------------------------------------------------

class Driver:
    """A minimal MCP stdio client against the built binary.

    Speaks to the same artifact the gate hashes, so the evidence and the shipped code cannot diverge.
    """

    def __init__(self, binary=None, timeout=180):
        self.binary = binary or BIN
        self.timeout = timeout
        self._id = 0
        self.proc = subprocess.Popen(
            [self.binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self._send("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "livekit", "version": "1"}})
        self._notify("notifications/initialized")

    def _write(self, obj):
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def _read(self):
        deadline = time.time() + self.timeout
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                continue
            try:
                return json.loads(line)
            except ValueError:
                continue
        return None

    def _notify(self, method, params=None):
        self._write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def _send(self, method, params=None):
        self._id += 1
        self._write({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or {}})
        return self._read()

    def tool(self, name, command, params=None):
        """Call a tool and return its parsed body.

        Arguments nest under `params`, matching the wire shape the server actually accepts.
        """
        args = {"command": command}
        if params is not None:
            args["params"] = params
        raw = self._send("tools/call", {"name": name, "arguments": args})
        return _body(raw)

    def resource(self, uri):
        raw = self._send("resources/read", {"uri": uri})
        try:
            return json.loads(raw["result"]["contents"][0]["text"])
        except (KeyError, IndexError, TypeError, ValueError):
            return {}

    def get(self, uri, key, default=None):
        return self.resource(uri).get(key, default)

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


def _body(raw):
    if not raw or "result" not in raw:
        return {"_transport_error": raw}
    res = raw["result"]
    if res.get("structuredContent") is not None:
        return res["structuredContent"]
    text = "".join(c.get("text", "") for c in res.get("content", []))
    try:
        return json.loads(text)
    except ValueError:
        return {"_text": text}


# ---------------------------------------------------------------------------
# Evidence document
# ---------------------------------------------------------------------------

class Evidence:
    """Accumulates records and writes `<root>/<head>/evidence.json`.

    `head` must be the FULL 40-character SHA. The gate looks the directory up by that exact name, and a
    short SHA fails it with a message that reads like missing evidence rather than a misfiled path.
    """

    def __init__(self, head, root, name=None):
        if not re.fullmatch(r"[0-9a-f]{40}", head or ""):
            # Not fatal: exploratory runs use a label. The gate will simply not find it, which is correct.
            pass
        self.head = head
        self.dir = os.path.join(root, head)
        os.makedirs(self.dir, exist_ok=True)
        self.name = name or os.path.basename(REPO or "livekit")
        self.records = []
        self._window_points = None

    # -- observations -------------------------------------------------------

    def note(self, tag, payload):
        """Record a reading that is context rather than a claim."""
        self.records.append({"kind": "observation", "tag": tag, "payload": payload})

    def check(self, tag, passed, expected, observed, mutation):
        """Assert something about the run.

        `mutation` names the change to the PRODUCT that was seen to flip this check. A check whose
        mutation is unknown is recorded with `mutation_flips: false` and the gate refuses the run — a
        check nobody has watched fail is decoration.
        """
        self.records.append({
            "kind": "check", "tag": tag, "passed": bool(passed),
            "expected": expected, "observed": observed,
            "mutation": mutation or None, "mutation_flips": bool(mutation),
        })
        return bool(passed)

    def provenance(self, tag, source, cache_age_sec, usable):
        """Record where a value came from when it did not come from a fresh read."""
        self.records.append({
            "kind": "provenance", "tag": tag, "source": source,
            "cache_age_sec": cache_age_sec,
            "usable_as_live_evidence": bool(usable),
        })

    def restored(self, tag, restored, detail=""):
        """Record that state the run mutated was put back."""
        self.records.append({
            "kind": "restoration", "tag": tag,
            "restored": bool(restored), "detail": detail,
        })

    # -- capture ------------------------------------------------------------

    def shot(self, tag, settle_region=None, window_title="Tracks"):
        """Capture the Logic window, waiting until the pixels stop moving.

        `settle_region` is an (x, y, w, h) rectangle in window coordinates. Settling is judged on that
        region alone: Logic repaints level meters and clocks continuously, so a whole-window settle
        never converges and would silently record `settled: false` on a perfectly good run.
        """
        path = os.path.join(self.dir, f"{tag.replace('/', '_')}.png")
        win = logic_window(window_title)
        if not win:
            self.records.append({"kind": "capture", "tag": tag, "file": path,
                                 "window": None, "display": {"wholly_within": False},
                                 "hash": None, "frames": 0, "settled": False,
                                 "why": "no Logic window on screen"})
            return {"file": path, "settled": False}

        prev, frames, settled = None, 0, False
        for _ in range(_SETTLE_TRIES):
            _capture_window(win["id"], path)
            frames += 1
            h = _region_hash(path, settle_region, (win["w"], win["h"]))
            if prev is not None and h == prev:
                settled = True
                break
            prev = h
            time.sleep(_SETTLE_GAP)

        self._window_points = (win["w"], win["h"])
        self.records.append({
            "kind": "capture", "tag": tag, "file": path, "window": win,
            "display": _display_containing(win),
            "hash": _file_hash(path), "region_hash": prev,
            "frames": frames, "settled": settled,
        })
        return {"file": path, "settled": settled, "window": win, "region_hash": prev}

    def visual(self, tag, before_file, after_file, region, expect_change, why,
               window_points=None):
        """Compare one named region across two captures and state what was expected there.

        A region is mandatory. A full-window diff answers "did anything at all change", which is true
        whenever the transport clock advances, and proves nothing about the feature.
        """
        wp = window_points or self._window_points
        b = _region_hash(before_file, region, wp)
        a = _region_hash(after_file, region, wp)
        readable = b is not None and a is not None
        changed = readable and b != a
        # An unreadable comparison is not a passing one, whichever way the expectation points.
        passed = readable and (changed == bool(expect_change))
        self.records.append({
            "kind": "visual", "tag": tag, "region": list(region) if region else None,
            "before": before_file, "after": after_file,
            "expected": ("region changes" if expect_change else "region does not change") + f" — {why}",
            "observed": f"before {(b or '?')[:16]} after {(a or '?')[:16]} changed={changed}",
            "passed": passed,
        })
        return passed

    # -- recording ----------------------------------------------------------

    def record_screen(self, seconds=90):
        """Start a screen recording covering the whole run.

        `seconds` is a hard duration, not a maximum, and `stop_recording` waits it out. That is not a
        convenience choice: `screencapture -v` only finalises its file when its own `-V` timer elapses.
        Measured on macOS 15 — SIGINT, SIGTERM, closing stdin, and a process-group SIGINT all leave NO
        file at all. Pick a duration a little longer than the run rather than a generous one, since the
        wait is real.

        The file name never begins with a dot: `screencapture` rejects dotfiles while still exiting 0,
        which produces a silent absence rather than an error.
        """
        path = os.path.join(self.dir, "run.mov")
        proc = subprocess.Popen(
            ["/usr/sbin/screencapture", "-v", "-V", str(seconds), path],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.5)
        return {"proc": proc, "file": path, "seconds": seconds}

    def stop_recording(self, handle, settle=1.0):
        """Wait for the recording to finalise, then record what actually landed on disk."""
        if not handle:
            return
        time.sleep(settle)
        try:
            handle["proc"].wait(timeout=handle.get("seconds", 90) + 30)
        except Exception:
            try:
                handle["proc"].kill()
            except Exception:
                pass
        time.sleep(1.0)
        self.recording(handle["file"])

    def recording(self, path):
        exists = os.path.isfile(path)
        self.records.append({
            "kind": "recording", "file": path, "exists": exists,
            "bytes": os.path.getsize(path) if exists else 0,
        })

    # -- output -------------------------------------------------------------

    def write(self):
        built_from, dirty = _worktree_head(REPO)
        if dirty:
            # A binary built from a dirty tree does not correspond to the commit it claims. Say so in
            # the document rather than letting the SHA imply a correspondence that does not hold.
            self.records.append({
                "kind": "provenance", "tag": "artifact/worktree-was-dirty",
                "source": "git status --porcelain", "cache_age_sec": None,
                "usable_as_live_evidence": False,
            })
        doc = {
            "name": self.name,
            "head": self.head,
            "artifact": {
                "path": BIN,
                "sha256": _file_hash(BIN),
                "built_from": built_from,
                "worktree_clean": not dirty,
            },
            "records": self.records,
        }
        out = os.path.join(self.dir, "evidence.json")
        with open(out, "w") as fh:
            json.dump(doc, fh, indent=1)
        return self._summary(out)

    def _summary(self, out):
        recs = self.records
        checks = [r for r in recs if r["kind"] == "check"]
        caps = [r for r in recs if r["kind"] == "capture"]
        vis = [r for r in recs if r["kind"] == "visual"]
        return {
            "file": out,
            "checks": len(checks),
            "passed": sum(1 for c in checks if c["passed"]),
            "mutation_backed": sum(1 for c in checks if c["mutation_flips"]),
            "captures_unsettled": sum(1 for c in caps if not c["settled"]),
            "captures_straddling_displays":
                sum(1 for c in caps if not c.get("display", {}).get("wholly_within")),
            "restorations_failed":
                sum(1 for r in recs if r["kind"] == "restoration" and not r["restored"]),
            "cached_reads_used_as_live":
                sum(1 for r in recs if r["kind"] == "provenance" and not r["usable_as_live_evidence"]),
            "visual_assertions": len(vis),
            "visual_failed": sum(1 for v in vis if not v["passed"]),
            "recordings": sum(1 for r in recs if r["kind"] == "recording"),
        }


def is_clean(summary):
    """Whether a run may be reported as passing.

    Exists because every harness got this wrong the same way: `sys.exit(0 if out["passed"] else 1)`.
    `passed` is a COUNT, not a boolean — 5-of-7 is truthy, so a harness with two red checks exited 0 and
    reported success. The only value that failed was zero, i.e. a run where NOTHING passed. A harness
    whose exit code cannot express failure is not an instrument.

    Every dimension the evidence document tracks has to be clean, not just the check count: an unsettled
    capture, a failed visual assertion, a restoration that did not happen, or a cached read presented as
    live each invalidate the run on their own.
    """
    return (
        summary.get("checks", 0) > 0
        and summary.get("passed") == summary.get("checks")
        and summary.get("visual_failed", 0) == 0
        and summary.get("captures_unsettled", 0) == 0
        and summary.get("captures_straddling_displays", 0) == 0
        and summary.get("restorations_failed", 0) == 0
        and summary.get("cached_reads_used_as_live", 0) == 0
    )


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _capture_window(window_id, path):
    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window_id), path],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def _file_hash(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


def _region_hash(png, region, window_points=None):
    """Hash one rectangle of a PNG.

    `region` is in WINDOW POINTS, the same units `logic_window()` reports. The capture is in backing
    PIXELS — measured 3840x2100 for a 1920x1050 window on this hardware — so the rectangle is scaled by
    the ratio the image itself reveals. Without that scaling the crop lands somewhere else entirely and
    the assertion compares two identical wrong regions, which reads as "nothing changed" on a run where
    the feature plainly worked.

    Returns None rather than falling back to a whole-file hash: an unusable comparison must be visible
    as unusable, not disguised as a difference.
    """
    if not os.path.isfile(png):
        return None
    try:
        from Quartz import (CGImageSourceCreateWithURL, CGImageSourceCreateImageAtIndex,
                            CGImageCreateWithImageInRect, CGRectMake, CGDataProviderCopyData,
                            CGImageGetDataProvider, CGImageGetWidth, CGImageGetHeight)
        from Foundation import NSURL
        url = NSURL.fileURLWithPath_(png)
        src = CGImageSourceCreateWithURL(url, None)
        if src is None:
            return None
        img = CGImageSourceCreateImageAtIndex(src, 0, None)
        if img is None:
            return None
        if not region:
            data = CGDataProviderCopyData(CGImageGetDataProvider(img))
            return hashlib.sha256(bytes(data)).hexdigest()
        pw, ph = CGImageGetWidth(img), CGImageGetHeight(img)
        sx = sy = 1.0
        if window_points:
            wpts, hpts = window_points
            if wpts:
                sx = pw / float(wpts)
            if hpts:
                sy = ph / float(hpts)
        x, y, w, h = region
        sub = CGImageCreateWithImageInRect(
            img, CGRectMake(x * sx, y * sy, w * sx, h * sy))
        if sub is None:
            return None
        data = CGDataProviderCopyData(CGImageGetDataProvider(sub))
        return hashlib.sha256(bytes(data)).hexdigest()
    except Exception:
        return None


def have_tools():
    """Everything the recorder needs, checked before a run rather than mid-run."""
    missing = []
    if not shutil.which("screencapture") and not os.path.exists("/usr/sbin/screencapture"):
        missing.append("screencapture")
    try:
        import Quartz  # noqa: F401
    except ImportError:
        missing.append("pyobjc (Quartz)")
    if BIN and not os.access(BIN, os.X_OK):
        missing.append(f"built binary at {BIN}")
    return missing


def _worktree_head(repo):
    """(HEAD sha, dirty) for the worktree the binary was built in.

    `dirty` counts tracked-file modifications under Sources/ and Tests/ only: an untracked scratch file
    does not change what was compiled, but an edited source does, and a binary built from an edited tree
    is not evidence about the commit it is filed under.
    """
    if not repo:
        return None, False
    try:
        head = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"],
                              capture_output=True, text=True, check=False).stdout.strip()
        st = subprocess.run(["git", "-C", repo, "status", "--porcelain", "--", "Sources", "Tests"],
                            capture_output=True, text=True, check=False).stdout.strip()
        return (head or None), bool(st)
    except Exception:
        return None, False
