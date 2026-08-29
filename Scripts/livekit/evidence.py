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
- **A check that cannot fail.** `check()` requires you to NAME a mutation you believe would flip it —
  which is a claim, and the field says so (`mutation_claimed`). `falsifiable()` is the form that
  establishes something: it hands the assertion to this module, which runs it against the observation
  AND against a counterexample the author wrote down, and passes only if the first is accepted and the
  second REJECTED. A condition that cannot fail fails there.
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
import tempfile
import sys
import time

# Set by the harness before use.
REPO = ""
BIN = ""

_SETTLE_TRIES = 8
_SETTLE_GAP = 0.35


# The Event tab of the List Editors pane. Measured 2026-08-29 on a Korean Logic, where the four
# list tabs describe themselves `이벤트`, `마커`, `템포`, `조표 및 박자표` — and where the
# collector's own literal `== "Event"` meant it could not find the tab at all.
EVENT_LIST_TAB_NAMES = ["event", "Event", "이벤트", "イベント"]
# The Marker tab, needed only to point the pane somewhere else so a refusal can be observed.
# Measured beside the others on 2026-08-29: `마커`.
MARKER_LIST_TAB_NAMES = ["Marker", "마커", "マーカー"]
# The other two, measured in the same read. They are here so a harness can tell "no list tab is
# selected" from "a tab I do not recognise is selected" — filtering to only the tabs a run drives
# turns the second into the first, and a run that then skips restoration reports itself clean.
OTHER_LIST_TAB_NAMES = ["Tempo", "템포", "テンポ",
                        "Signature", "조표 및 박자표", "調号と拍子記号"]
ALL_LIST_TAB_NAMES = (EVENT_LIST_TAB_NAMES + MARKER_LIST_TAB_NAMES + OTHER_LIST_TAB_NAMES)


def label_set(name, repo=None):
    """`[canonical] + variants` for one `AXLocalePolicy` LabelSet, read from the Swift source.

    PARSED, not imported — a harness cannot link the product, and shelling out to it would make the
    thing under test supply the labels its own assertion is checked against.

    The limit is worth stating: the harness and the product then read the SAME declaration, so a
    declaration that is wrong for a locale is wrong in both and this comparison cannot see it. What
    it does catch is the case it was written for — Logic rendering a different set of columns than
    the product expects — and it catches it in every language, which a list of English literals in
    a harness does not.
    """
    repo = repo or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    path = os.path.join(repo, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return None
    # Comments first. Swift `// "위치" is documentation` inside a variants list is not a declared
    # variant, and a regex that cannot see the difference reports one the compiler does not.
    text = re.sub(r"//[^\n]*", "", text)
    m = re.search(r"static let " + re.escape(name) + r"\s*=\s*LabelSet\((.*?)\)\s*\n", text, re.S)
    if not m:
        return None
    body = m.group(1)
    canonical = re.search(r'canonical:\s*"((?:[^"\\]|\\.)*)"', body)
    if not canonical:
        return None
    out = [canonical.group(1)]
    variants = re.search(r"variants:\s*\[(.*?)\]", body, re.S)
    if variants:
        out += re.findall(r'"((?:[^"\\]|\\.)*)"', variants.group(1))
    return out


# ---------------------------------------------------------------------------
# Window geometry
# ---------------------------------------------------------------------------

_NAME_SAFE = re.compile(r"[^A-Za-z0-9._-]")


def _safe_name(raw):
    """A document name that can only ever be a single file inside the head directory.

    `name` used to live only inside the JSON. It is now a PATH COMPONENT, so an unconstrained value
    escapes: `Evidence(..., name="../escaped")` wrote `escaped.evidence.json` in the evidence ROOT,
    outside the head directory, where the gate would never look for it and nothing would notice.
    """
    stem = os.path.basename(str(raw)).strip() or "livekit"
    stem = _NAME_SAFE.sub("_", stem).lstrip(".") or "livekit"
    return stem[:80]


def _running_harness_name():
    """The stem of the script that is running, e.g. `live_608_first_call_is_not_refused`.

    When the entry point cannot be determined — `python3 -c`, a REPL, a wrapper that execs without
    setting `__file__` — this used to fall back to the WORKTREE basename, which is exactly the
    ambiguity #612 is about: two harnesses under one worktree share it and overwrite each other
    again. The fallback now carries the pid, so two such runs cannot collide, and it says in the name
    that it could not identify itself.
    """
    path = getattr(sys.modules.get("__main__"), "__file__", None)
    if path:
        return _safe_name(os.path.splitext(os.path.basename(path))[0])
    return _safe_name(f"unidentified-harness-pid{os.getpid()}")


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
        # The server's diagnostics go to stderr (`Logger.swift:60`). Discarding them made every
        # `Log.info` in the product unobservable from a live document -- code could say "this
        # fallback fired" and no harness could assert it fired or did not. Measured 2026-08-21:
        # that is exactly the state the two #628 branches were in.
        #
        # A FILE, not a PIPE. Nothing drains this stream while `_read` blocks on stdout, so a pipe
        # would deadlock the server once the buffer filled -- silently, and only on the runs that
        # logged the most.
        self._stderr_file = tempfile.NamedTemporaryFile(
            prefix="lpm-server-stderr-", suffix=".log", delete=False)
        self._stderr_path = self._stderr_file.name
        # `Log` gates on LOG_LEVEL (`Logger.swift:69`), which the driver would otherwise INHERIT.
        # At LOG_LEVEL=warn every `Log.info` vanishes while an unrelated warning still fills the
        # file -- so a harness asserting absence would see a non-empty log and conclude the channel
        # carried, when the only lines that could have carried were suppressed. Pinned, not inherited.
        env = dict(os.environ, LOG_LEVEL="info")
        self.proc = subprocess.Popen(
            [self.binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self._stderr_file, text=True, bufsize=1, env=env)
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

    def _record_operation(self, name, command, params, body):
        """Put a driven operation in the document, however it was sent.

        `tool()` is not the only path: a harness that needs the full JSON-RPC envelope calls `_send`
        directly, and the very first run under this recording showed why that matters — the harness
        drove ONE operation through `tool()` and the operation it was actually about through `_send`,
        so `operations_driven` read 1 and the subject of the run was absent from its own receipt.
        """
        if Evidence.current is None:
            return
        Evidence.current.records.append({
            "kind": "operation",
            "tool": name,
            "command": command,
            "params": params or {},
            "response": {k: body.get(k) for k in
                         ("state", "success", "error", "hint", "verified", "write_attempted")}
            if isinstance(body, dict) else {"raw": str(body)[:400]},
        })

    def _send(self, method, params=None):
        self._id += 1
        self._write({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or {}})
        raw = self._read()
        # Record here as well as in `tool()`, because a harness that needs the full envelope calls
        # this directly — and the first run under this recording proved it: the operation the harness
        # was ABOUT went through `_send` and was absent from the document, while a warm-up call made
        # through `tool()` was the only thing `operations_driven` counted.
        if method == "tools/call" and isinstance(params, dict):
            args = params.get("arguments") or {}
            self._record_operation(params.get("name"), args.get("command"),
                                   args.get("params"), _body(raw))
        return raw

    def tool(self, name, command, params=None):
        """Call a tool and return its parsed body.

        Arguments nest under `params`, matching the wire shape the server actually accepts.

        The call is recorded in the evidence document by `_send`, not here — a harness that needs the
        full JSON-RPC envelope bypasses this wrapper, and recording in both places would double-count
        everything that does come through it.
        """
        args = {"command": command}
        if params is not None:
            args["params"] = params
        return _body(self._send("tools/call", {"name": name, "arguments": args}))

    def resource(self, uri):
        raw = self._send("resources/read", {"uri": uri})
        try:
            return json.loads(raw["result"]["contents"][0]["text"])
        except (KeyError, IndexError, TypeError, ValueError):
            return {}

    def get(self, uri, key, default=None):
        return self.resource(uri).get(key, default)

    def server_log(self):
        """Everything the server has written to stderr so far.

        Returns "" when the file is unreadable, which is indistinguishable from a server that logged
        nothing -- so a caller asserting ABSENCE must pair this with a control proving the channel
        carries at all. `server_logged` returns that control; prefer it over this.
        """
        try:
            self._stderr_file.flush()
            with open(self._stderr_path, "r", errors="replace") as fh:
                return fh.read()
        except Exception:
            return ""

    def server_logged(self, needle, since=0):
        """(present, channel_is_live) -- the second value is the control.

        `since` is a byte offset from a previous `len(server_log())`, so a caller can ask about the
        window AFTER something it did rather than about the whole run. Without it every later read
        still sees the earlier lines, and "nothing was logged by the write" is indistinguishable
        from "nothing was logged by the read either" -- the check reads as scoped and is not.

        `channel_is_live` requires an `[INFO]` line, not merely a non-empty file. A log holding only
        warnings proves the stream is connected and proves nothing about whether an INFO line could
        have arrived, which is the level every caller of this asserts absence at.
        """
        log = self.server_log()
        window = log[since:] if since else log
        return (needle in window, "[INFO]" in log)

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass
        # `delete=False` is required -- the server holds this file open and Python must not remove
        # it underneath. That makes cleanup THIS function's job: without it every Driver in a run
        # leaves a descriptor and a file behind, and a long harness accumulates both.
        for step in (self._stderr_file.close, lambda: os.unlink(self._stderr_path)):
            try:
                step()
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

# An AXDescription is LOCALIZED, and not uniformly. Measured on Logic 12.3, 2026-08-21, by running
# the same window under `AppleLanguages -array en` and `-array ko`:
#
#     Tracks contents  ->  트랙 콘텐츠          Library    ->  라이브러리
#     Tracks header    ->  트랙 헤더            Mixer      ->  믹서
#     Tracks           ->  트랙                 Inspector  ->  인스펙터
#     Step Sequencer   ->  Step Sequencer      <- NOT translated
#
# That last row is why this is a measured table and not a rule. Some descriptions translate and
# some do not, so neither "they are stable identifiers" nor "they are all localized" is safe — and
# the first of those is exactly what a comment in `live_519_region_op_on_a_localized_logic` used to
# claim. A Korean run disproved it: the canvas lookup found nothing and the harness could not take
# a capture, on the one run where the locale was the entire point.
#
# ONLY measured pairs belong here. An unmeasured locale must fail to resolve, loudly, rather than
# be guessed at — guessing localized labels is the defect #519 exists to remove from the product,
# and a harness is not exempt from it.
AX_REGION_LABELS = {
    # Measured 2026-08-29: absent until then, so `located_band("Control Bar", ...)` answered
    # `no element with that exact AXDescription` on a Korean Logic and three harnesses failed a
    # precondition about a window frame. Every other region in this table already had its row —
    # this was one missing line, not a missing mechanism.
    "Control Bar": ["컨트롤 막대", "コントロールバー"],
    "Tracks contents": ["트랙 콘텐츠"],
    # Four ASCII spellings because the policy declares four and nothing here knows which one a
    # given Logic renders — measured `Tracks header` in English 12.x, `트랙 헤더` in Korean. The
    # alias guard found the other three unreachable: the policy claimed to know them and the
    # locator would never have tried them.
    "Tracks header": ["트랙 헤더", "track headers", "track header", "tracks headers"],
    "Tracks": ["트랙"],
    "Library": ["라이브러리"],
    "Mixer": ["믹서"],
    "Inspector": ["인스펙터"],
}


class Evidence:
    """Accumulates records and writes `<root>/<head>/evidence.json`.

    `head` must be the FULL 40-character SHA. The gate looks the directory up by that exact name, and a
    short SHA fails it with a message that reads like missing evidence rather than a misfiled path.
    """

    # The Evidence in play, so `Driver` can record what it drove without every harness threading it
    # through. Set on construction; a harness that builds two Evidences gets the later one, which is
    # the only sensible reading of "the run".
    current = None

    def __init__(self, head, root, name=None):
        if not re.fullmatch(r"[0-9a-f]{40}", head or ""):
            # Not fatal: exploratory runs use a label. The gate will simply not find it, which is correct.
            pass
        self.head = head
        self.dir = os.path.join(root, head)
        os.makedirs(self.dir, exist_ok=True)
        # #612: the document used to be named after the WORKTREE, so two harnesses run at the same
        # head both called themselves `lpm-wt-608` and there was no field saying which script wrote
        # it. Name it after the running script instead, and key the file by that name too — see
        # `write()`.
        self.name = _safe_name(name) if name else _running_harness_name()
        self.records = []
        self._window_points = None
        Evidence.current = self

    # -- locating a band ----------------------------------------------------

    def located_band(self, *selector):
        """`(band, subject)` for a region named by AXDescription, or `(None, None)`.

        A rectangle written as four numbers is not defined by its content. The five harnesses that
        shared `(0, 0.10h, 0.20w, 0.80h)` were all claiming something about the track-header rail,
        and measured on 2026-08-20 with the Library pane open that rectangle lies 94% inside the
        LIBRARY: the rail sits at x=603. The band was right in the layout it was written in and
        wrong in the next one, and nothing in the run could say which.

        So the band is resolved from the live tree and the `subject` comes back off the element
        that was found, not off the request — which is what makes it evidence rather than a label.

        `(None, None)` on any failure, INCLUDING an ambiguous description, which the tool reports
        as an error with all its candidates. Callers must treat that as a red precondition; before
        #634 a `None` band silently became a whole-image comparison that passed.
        """
        source = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_control_bar_band.swift")
        tool = os.path.join(self.dir, "ax_control_bar_band")
        if not os.path.exists(tool):
            built = subprocess.run(["swiftc", "-O", source, "-o", tool], capture_output=True)
            if built.returncode != 0:
                self.note("located_band/build-failed",
                          {"selector": list(selector),
                           "stderr": (built.stderr or b"").decode("utf-8", "replace")[:400]})
                return None, None

        def refuse(why, r=None):
            # A refusal that says nothing is a wall. Every one of these has been mistaken for a
            # different failure at least once: an ambiguous description reads exactly like a
            # missing element, and both read like the tool not having run at all.
            self.note("located_band/refused",
                      {"selector": list(selector), "why": why,
                       "rc": None if r is None else r.returncode,
                       "stdout": "" if r is None else (r.stdout or "")[:400],
                       "stderr": "" if r is None else (r.stderr or "")[:400]})
            return None, None

        # The requested name first, then the measured translations of it. Not a fallback in the
        # sense this file spends so much effort removing — each candidate is an exact match against
        # a description read off a live window, and a name nobody has measured is simply absent
        # from the table and cannot be tried.
        wanted = selector[0] if selector else ""
        candidates = [wanted] + [alt for alt in AX_REGION_LABELS.get(wanted, []) if alt != wanted]
        r = None
        payload = {}
        for candidate in candidates:
            r = subprocess.run([tool, candidate, *selector[1:]], capture_output=True, text=True)
            try:
                payload = json.loads(r.stdout or "{}")
            except ValueError:
                return refuse("the tool printed something that is not JSON", r)
            if isinstance(payload.get("band"), list):
                break
            # An AMBIGUOUS name is an answer, not a miss: trying the next language's word for it
            # would be answering a different question than the one that just failed.
            if payload.get("matches"):
                break
        band = payload.get("band")
        if not (isinstance(band, list) and len(band) == 4):
            return refuse(payload.get("error") or "no band in the tool's answer", r)
        if payload.get("description") and payload["description"] != wanted:
            # Which language's label actually matched. Silence here would let a run claim it
            # watched `Tracks header` when what it found was `트랙 헤더` — the same region, but the
            # record should say which word was on screen.
            self.note("located_band/matched-a-localized-label",
                      {"requested": wanted, "matched": payload["description"]})
        subject = payload.get("description")
        if not isinstance(subject, str) or not subject.strip():
            return refuse("a band with no description cannot be named", r)
        attempts = payload.get("windowAttempts")
        if isinstance(attempts, int) and attempts > 1:
            # Absorbed, not hidden: the lookup succeeded, and it took more than one read of the AX
            # tree to see a window at all.
            self.note("located_band/window-list-was-empty-at-first",
                      {"selector": list(selector), "attempts": attempts})
        # #628, item 3: the candidate count reaches the DOCUMENT, not just the tool's stdout.
        #
        # Refusing when a name is ambiguous is half the job. The other half is that "there was
        # exactly one" survives into the record — a lookup that stays silent on success leaves a
        # result with no way to tell a discriminator from tree order, which is the whole issue.
        #
        # Recorded on EVERY success, including `candidates: 1`, and including the case where the
        # tool did not report a count at all. A note written only when the number is interesting
        # cannot be distinguished from a run of an older tool that never counted: both are silence,
        # and one of them is a lookup nobody has checked.
        self.note("located_band/candidates",
                  {"selector": list(selector), "subject": subject,
                   "candidates": payload.get("candidates"),
                   "counted": isinstance(payload.get("candidates"), int)})
        return tuple(band), subject

    # -- observations -------------------------------------------------------

    def note(self, tag, payload):
        """Record a reading that is context rather than a claim."""
        self.records.append({"kind": "observation", "tag": tag, "payload": payload})

    def check(self, tag, passed, expected, observed, mutation):
        """Assert something about the run.

        `mutation` NAMES a change to the product the author believes would flip this check. The
        field recording it is called `mutation_claimed` because that is all it is. It was called
        `mutation_flips` until 2026-08-28, one word away from a claim nothing here establishes:
        nobody reruns the build with the mutation applied, so `bool(mutation)` only ever meant "a
        non-empty string was supplied". The docstring above it said "a check nobody has watched fail
        is decoration" while the value beneath it counted decoration.

        Requiring a mutant receipt was considered and rejected. The live gate hashes every
        `*.evidence.json` at a head against the shipped release binary, and a mutant binary has a
        different digest by construction — so a receipt cannot live in that directory at all, and
        exempting it would move the trust rather than establish it. A second GUI run against another
        binary in another UI state also cannot show that the NAMED mutation caused the red; it shows
        only that something did.

        `falsifiable()` below is the cheap form that does establish something.
        """
        self.records.append({
            "kind": "check", "tag": tag, "passed": bool(passed),
            "expected": expected, "observed": observed,
            "mutation": mutation or None, "mutation_claimed": bool(mutation),
        })
        return bool(passed)

    def falsifiable(self, tag, predicate, observation, counterexample, expected, mutation=None):
        """A check whose assertion is run against a state it MUST reject, in the same run.

        `check()` records whether the author's condition held. It cannot notice a condition that
        could not have failed — a constant, a field that is never read, a comparison too weak to
        reject the state it names. Those pass live and pass everywhere.

        So the predicate is handed to the framework and the framework calls it twice: once on what
        the run observed, once on an explicit counterexample the author had to write down. The check
        passes only when the first is accepted AND the second is rejected. An author cannot supply
        the second result; there is no parameter for it.

        This costs no rebuild and no second Logic session, and it catches the defects that make an
        assertion decoration. What it does NOT establish is that the check would catch a real
        regression in the product — only that its condition can distinguish the observation from one
        stated alternative. That boundary is the tag and that counterexample, and nothing wider.
        """
        try:
            live_ok = bool(predicate(observation))
        except Exception as exc:                       # noqa: BLE001 - recorded, not swallowed
            live_ok, observation = False, f"predicate raised on the observation: {exc!r}"
        try:
            counter_ok = bool(predicate(counterexample))
        except Exception as exc:                       # noqa: BLE001
            # A predicate that throws on the counterexample has not rejected it on the merits, and
            # reading a crash as a rejection is how a broken condition looks strong.
            counter_ok, counterexample = True, f"predicate raised on the counterexample: {exc!r}"

        passed = live_ok and not counter_ok
        self.records.append({
            "kind": "check", "tag": tag, "passed": passed,
            "expected": expected,
            "observed": {"observation": repr(observation)[:400],
                         "accepted_the_observation": live_ok,
                         "counterexample": repr(counterexample)[:400],
                         "rejected_the_counterexample": not counter_ok},
            "mutation": mutation or None, "mutation_claimed": bool(mutation),
            "has_counterexample": True,
            "counterexample_rejected": not counter_ok,
        })
        return passed

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
        # Keyed by harness as well as tag (#612 follow-up). Tags collide across harnesses —
        # `575/before` is used by three different files, `before-create` by two — so a document
        # rotated aside for later comparison used to name PNGs a later run had already replaced.
        # Archiving a document whose pixels are gone is the opposite of keeping a flake visible.
        path = os.path.join(self.dir, f"{self.name}__{tag.replace('/', '_')}.png")
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
            h = _region_hash(path, _clip_to_window(settle_region, (win["w"], win["h"])),
                             (win["w"], win["h"]))
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
               window_points=None, subject=None):
        """Compare one named region across two captures and state what was expected there.

        A region is mandatory. A full-window diff answers "did anything at all change", which is true
        whenever the transport clock advances, and proves nothing about the feature.

        `subject` is mandatory too, and it is the harder requirement: state what the region IS, as the
        UI itself describes it — not where it is. Measured this week, three different rectangles over
        one window each produced a confident wrong answer, and every one of them looked identical in
        the receipt because a receipt that records only `(x, y, w, h)` cannot show that the band moved
        onto something else:

            (0, 0, 1920, 28)    named "the title band"; `screencapture -l` excludes the title bar, so
                                it was window CONTENT — track names and the Inspector
            (0, 0, 240, 28)     the track-name column with the Mixer closed, a column of MIXER STRIPS
                                with it open, and mixer strips carry level meters
            the rail by AXDescription   correct, and still wrong for the claim: the arrange SCROLLS
                                when a modal takes and returns focus

        So pass what AX says the element is — its description, and ideally its parent's. A run that
        aimed at the wrong thing then says so in its own document instead of reading as a clean pass.
        """
        # NOT raised. Twenty-nine harnesses predate this parameter, and filling their `subject` in
        # bulk would mean writing down what I believe each band is without measuring it — which is the
        # defect this parameter exists to catch, committed at scale. So an absent subject is RECORDED
        # as absent and `is_clean` refuses the run: each harness's next run tells its owner that this
        # assertion does not say what it watches, and the fix arrives with a measurement attached.
        wp = window_points or self._window_points
        # What was HASHED, which is not always what was asked for — see `_clip_to_window`. The
        # record carries the clipped rectangle, and says so when the two differ.
        effective = _clip_to_window(region, wp)
        b = _region_hash(before_file, effective, wp)
        a = _region_hash(after_file, effective, wp)
        readable = b is not None and a is not None
        changed = readable and b != a
        # An unreadable comparison is not a passing one, whichever way the expectation points.
        passed = readable and (changed == bool(expect_change))
        self.records.append({
            "kind": "visual", "tag": tag, "region": list(effective) if effective else None,
            "subject": subject,   # None until the harness measures what the region is

            "before": before_file, "after": after_file,
            "expected": ("region changes" if expect_change else "region does not change") + f" — {why}",
            "observed": f"before {(b or '?')[:16]} after {(a or '?')[:16]} changed={changed}",
            "passed": passed,
        })
        if effective is not None and region is not None and tuple(effective) != tuple(region):
            self.records[-1]["region_requested"] = list(region)
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
        path = os.path.join(self.dir, f"{self.name}__run.mov")
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
        # #612: one file per HARNESS per head, not one per head. `evidence.json` was keyed by the
        # head SHA alone, so the last harness to run at a given head silently replaced every earlier
        # one's document — measured: running #606's harness on the #608 branch to check for a
        # regression overwrote #608's own evidence, and the gate then validated #608 against #606's
        # proof and reported ok. A check whose subject can be swapped without the check noticing is
        # not a check.
        out = os.path.join(self.dir, f"{self.name}.evidence.json")
        # A re-run against the SAME binary is a re-measurement of the same thing. Replacing the
        # earlier document silently would hide a flake — two runs disagreeing is exactly what you
        # want to see — so the previous one is kept beside it rather than dropped.
        # Rotate ANY existing document, not only one from the same binary.
        #
        # The first cut rotated only when the artifact sha256 matched, on the theory that a different
        # binary is a new measurement and may replace cleanly. That erases the case the rotation
        # exists for: the normal loop is edit → rebuild → re-run, so the second run almost always has
        # a DIFFERENT hash, and the flake it was meant to preserve was the thing overwritten.
        # Unreadable or pre-schema JSON took the same overwrite path for the same reason.
        #
        # Keeping every document costs a few kilobytes and is the only way "two runs disagreeing" is
        # something anyone can see afterwards.
        if os.path.exists(out):
            n = 1
            while os.path.exists(os.path.join(self.dir, f"{self.name}.evidence.{n}.json")):
                n += 1
            os.replace(out, os.path.join(self.dir, f"{self.name}.evidence.{n}.json"))
        with open(out, "w") as fh:
            json.dump(doc, fh, indent=1)
        # The old single-file name is still written, because the gate reads it. It is the LAST run at
        # this head whatever produced it, which is the very ambiguity #612 is about — the per-harness
        # file above is the one to trust, and the gate should move to requiring one per harness.
        legacy = os.path.join(self.dir, "evidence.json")
        with open(legacy, "w") as fh:
            json.dump(doc, fh, indent=1)
        return self._summary(out)

    def _summary(self, out):
        return summarize(self.records, out)


def summarize(recs, out=None):
    """The counters `is_clean` reads, from a list of records.

    Module-level rather than a method because the records are the whole input: a document read back
    off disk has records and no Evidence around them, and the alternative — building a throwaway
    object with a `.records` attribute so a method can be called on it — is a shim standing where an
    argument belongs. The test file already had to write that shim once.

    Indexed with `.get` rather than `[...]` throughout: a document read back off disk may predate a
    field or have been truncated, and every missing key here reads as the FAILING value — an absent
    `passed` is not a pass, an absent `settled` is unsettled. Crashing on a malformed document would
    turn "this evidence is unreadable" into a stack trace at the gate.
    """
    if not isinstance(recs, list):
        return None
    recs = [r for r in recs if isinstance(r, dict) and "kind" in r]
    checks = [r for r in recs if r["kind"] == "check"]
    caps = [r for r in recs if r["kind"] == "capture"]
    vis = [r for r in recs if r["kind"] == "visual"]
    return {
        "file": out,
        "checks": len(checks),
        "passed": sum(1 for c in checks if c.get("passed")),
        "mutation_claimed": sum(1 for c in checks if c.get("mutation_claimed")),
        "checks_with_a_counterexample": sum(1 for c in checks if c.get("has_counterexample")),
        "counterexamples_not_rejected":
            sum(1 for c in checks if c.get("has_counterexample") and not c.get("counterexample_rejected")),
        "captures_unsettled": sum(1 for c in caps if not c.get("settled")),
        "captures_straddling_displays":
            sum(1 for c in caps if not c.get("display", {}).get("wholly_within")),
        "restorations_failed":
            sum(1 for r in recs if r["kind"] == "restoration" and not r.get("restored")),
        "cached_reads_used_as_live":
            sum(1 for r in recs if r["kind"] == "provenance" and not r.get("usable_as_live_evidence")),
        "captures": len(caps),
        "visual_assertions": len(vis),
        "visual_failed": sum(1 for v in vis if not v.get("passed")),
        "recordings": sum(1 for r in recs if r["kind"] == "recording"),
        "operations_driven": sum(1 for r in recs if r["kind"] == "operation"),
        # A subject must be a non-empty STRING. `not v.get("subject")` alone accepted True, a
        # dict, or any other truthy object as a name.
        "visual_assertions_without_a_subject":
            sum(1 for v in vis
                if not isinstance(v.get("subject"), str) or not v["subject"].strip()),
    }


# Every counter `is_clean` reads. A summary missing any of them is not clean.
#
# The polarity used to depend on which key it was: `summary.get("visual_assertions_without_a_subject", 0) == 0`
# passed when the key was ABSENT, while `summary.get("mutation_claimed", 0) > 0` failed when absent.
# So a summary carrying the new counters but not that one — an older _summary, a hand-built dict —
# was clean, and the newest condition was the one that vanished quietly. Listing the keys fixes the
# shape of the bug rather than the one clause where it was noticed.
_REQUIRED_SUMMARY_KEYS = (
    "checks", "passed", "mutation_claimed", "operations_driven",
    "checks_with_a_counterexample", "counterexamples_not_rejected",
    "captures", "captures_unsettled", "captures_straddling_displays",
    "restorations_failed", "cached_reads_used_as_live",
    "visual_assertions", "visual_failed", "visual_assertions_without_a_subject",
    "recordings",
)


def is_clean(summary):
    """Whether a run may be reported as passing.

    Exists because every harness got this wrong the same way: `sys.exit(0 if out["passed"] else 1)`.
    `passed` is a COUNT, not a boolean — 5-of-7 is truthy, so a harness with two red checks exited 0 and
    reported success. The only value that failed was zero, i.e. a run where NOTHING passed. A harness
    whose exit code cannot express failure is not an instrument.

    Every dimension the evidence document tracks has to be clean, not just the check count: an unsettled
    capture, a failed visual assertion, a restoration that did not happen, or a cached read presented as
    live each invalidate the run on their own.

    THE ZEROS HAVE TO BE EARNED. Every `== 0` clause below is satisfied by a run that never did the
    thing at all: no visual assertion means no visual can lack a subject, and no capture means none
    was unsettled. So the counts that make those zeros meaningful are required to be positive. The
    cheapest way to satisfy "every visual names a subject" must not be to assert nothing.

    What these clauses do NOT establish, stated so nobody reads them as more:

      * `operations_driven` counts tool calls, not successful ones. A warm-up call, a read, or a
        call that came back a transport error each increment it. It rules out a harness that never
        touched the product; it does not show the run drove its own subject.
      * `mutation_claimed` counts checks that NAME a mutation. Naming is not demonstrating — the
        string is prose, and nothing here reruns the build with the mutation applied. Whether the
        named mutation would actually flip that check is the author's claim and a reviewer's job.
        It was called `mutation_backed` until 2026-08-28, which read as though something backed it.
      * `counterexamples_not_rejected` is enforced and `checks_with_a_counterexample` is NOT, yet.
        A `falsifiable()` check whose predicate accepts the state it was supposed to reject fails
        immediately — that clause is real. Requiring every harness to HAVE one is the clause with
        teeth, and it is left counted-but-unenforced for the same reason
        `visual_assertions_without_a_subject` was: thirty-odd harnesses predate the affordance, and
        turning the whole live suite red in one step invites someone to delete the clause instead of
        converting the call sites. Enforce it when the count reaches the harness count, not before.
      * a subject is any non-empty string. That it truthfully names what the rectangle contains is
        not checkable here.

    `visual_assertions_without_a_subject` is GATED as of #622. It was counted and not enforced for
    one release, because enforcing it while thirty harnesses passed no subject would have turned
    the whole live suite red in a step and the predictable next move is that somebody deletes the
    clause. All thirty-one call sites name a subject now, and the count reached zero by measuring
    what each band contains rather than by writing a string that would satisfy the counter.

    What the clause still cannot do is check that the name is TRUE. Most bands are resolved from
    the live tree by `located_band`, so their subject is read back off the element that was found
    and cannot drift from it; the few that are authored — a window's title bar, a slice offset into
    a located rail — are the ones a reviewer has to read.
    """
    if not isinstance(summary, dict):
        return False
    if any(key not in summary for key in _REQUIRED_SUMMARY_KEYS):
        return False
    return (
        summary["checks"] > 0
        and summary["passed"] == summary["checks"]
        # Non-vacuity: the run has to have looked, driven, and recorded.
        and summary["captures"] > 0
        and summary["visual_assertions"] > 0
        and summary["recordings"] > 0
        and summary["mutation_claimed"] > 0
        and summary["counterexamples_not_rejected"] == 0
        and summary["operations_driven"] > 0
        # ... and nothing it did may have gone wrong.
        and summary["visual_failed"] == 0
        and summary["captures_unsettled"] == 0
        and summary["captures_straddling_displays"] == 0
        and summary["restorations_failed"] == 0
        and summary["cached_reads_used_as_live"] == 0
        and summary["visual_assertions_without_a_subject"] == 0
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


# --- Restored after a merge dropped them -------------------------------------------------------
#
# #620 rewrote this file from a base that predated these three, so merging it deleted them while
# every CALL SITE stayed: `_region_hash` at shot()/visual(), `_worktree_head` at write(), and
# `have_tools` in thirty-two harnesses. Main could not run a single live harness.
#
# Neither gate could see it. The ship gate runs the Swift suite, and #620 changed no Sources/ so it
# needed no live evidence; #620's own test exercises is_clean and _safe_name and never calls shot(),
# visual(), or write(). Each branch was green and the breakage existed only in their merge.
#
# The import smoke test beside this file is the part that would have caught it.

def _clip_to_window(region, window_points):
    """The part of `region` a capture of that window can actually contain, or None if none of it.

    A band can legitimately be larger than the window it is measured in: `Tracks contents` is 6162
    points wide on a 1920-point window, because the arrange canvas extends past the viewport it is
    drawn into. `CGImageCreateWithImageInRect` intersects an oversized crop against the image and
    says nothing, so the record claimed the whole canvas while the hash covered the visible part.

    Clipping here rather than there keeps the two honest: what is recorded as the region is what
    was hashed. A band lying entirely outside the window returns None, which reads as unreadable
    rather than as a comparison of two empty crops — those would be equal, and equal is a PASS for
    every negative assertion.
    """
    if not region or not window_points:
        return tuple(region) if region else None
    wpts, hpts = window_points
    if not wpts or not hpts:
        return tuple(region)
    x, y, w, h = region
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(x + w, wpts), min(y + h, hpts)
    if x1 <= x0 or y1 <= y0:
        return None
    return (x0, y0, x1 - x0, y1 - y0)


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
    # A falsy region hashes the WHOLE FILE, which is how a region-less visual passes. The docstring
    # above has always said otherwise, and the #620 review said so again; it stayed true anyway.
    # Measured today: a band lookup returned None, `visual()` compared two whole images, found them
    # equal, and reported a passing negative assertion about a rectangle it never looked at.
    #
    # A comparison with no region is not a weak comparison, it is a different one — "did anything on
    # screen change" instead of "did this change" — and the run has no way to know it was answered.
    if not region:
        return None
    # The whole-image fallback that used to live further down is DELETED, not merely bypassed. It
    # said the opposite of this guard, in the same function, and this guard won only by running
    # first — so deleting it would have restored the defect silently, and anyone reading that
    # branch had every reason to think whole-image hashing was supported.
    #
    # With the fallback gone this guard is no longer individually load-bearing: `x, y, w, h = region`
    # raises on None and the broad `except` below returns None anyway. Measured — removing this line
    # leaves the shape test green. It stays because being correct by way of an exception handler is
    # not the same as being correct on purpose, and that handler also swallows real failures. Said
    # plainly so nobody reads a passing suite as proof this line is doing the work.
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
