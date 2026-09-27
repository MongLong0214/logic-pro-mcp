"""The live lifecycle behind the runner (ADR-027 P0b-2): Logic, the lock, the build and the server.

`LiveLifecycle` is the `runner.Lifecycle` that touches the world, over P0b's live library:

    build     live.binary.Builds: a clean detached checkout of the head, `swift build -c release`,
              the product copied to a new path and hashed there. No binary is BuildFailed.
    claim     live.exclusive.claim: LPM_LIVE_LOCK (no default, D7) taken with O_EXCL, waited on
              for up to LOCK_WAIT_S while another run holds it and NEVER moved aside when stale,
              then no rival LogicProMCP server or test bundle. Refused is a record, not a raise.
    switch    live.locale.switch_to; `reading` is live.locale.reading, taken again per entry.
    start     a live.mcp.Server from the Built path with the declaration's env, as McpSession.
              Its pid joins the pids `problems` does not count as rivals.
    fixture   setups.SETUPS names the live/fixture.py declaration; a fixture with none, one at a
              path other than live.locale.FIXTURE (the file every switch reopens), or one that
              needs the Mixer shown is refused before anything is built.
    gate      live.fixture.read (the verifier's own track_flags_ax walk, D1; the walk goes to a
              sidecar) plus display.upperRow of logic://mcu/state (the product's reading: nothing
              else reads the LCD), shaped for setups.gate_problems by `gate_reading_of`.
    reset     live.fixture.reset: Don't Save, reopen from disk, read. The record, walk and all,
              goes to a sidecar; the evidence keeps the fixture, the locale and its sha256.
    ready     with the declaration's ready "mcu", a bounded wait on logic://mcu/state until
              connection.isConnected and registeredAsDevice are both true (live_1020 slept 8 s
              twice instead); with none, ready at once.
    settle    live.screen.settle_to_clean, between rows only; it may send Escape, and says so.
              Its samples go to a sidecar; the evidence keeps the dirt before and after, the
              Escapes sent, whether it timed out, and the sidecar's sha256.
    problems  live.screen.clean_state's dirt, plus every LogicProMCP server or test bundle this
              run did not start. An unreadable process table is dirt of its own kind.
    rest      live.locale.restore_locale, confirmed by live.locale.in_locale over its reading.
    sidecar   bytes too large for the evidence (transcripts, raw AX walks), written to SIDECARS
              under their own sha256, which is what the evidence cites (D5).

`probe` is probes.run: live/spec_probes.py's implementation of the declared probe.

WHAT A REPLY STORES (D2)
------------------------
`McpSession.call` returns a tools/call result's `content[0].text`: the string the server sent, as
the parse of its JSON-RPC line holds it, never re-serialized. `read` returns a resources/read
result's `contents[0].text` the same way. Either raises runner.StepUnreadable, saying why, when the
request was not sent, timed out, found the server gone, or got a JSON-RPC error; when the result
has no text in its first item; and when the result also carries structuredContent that is not the
same JSON as the text (predicates.same). A reply that says two things is read as neither.
"""
from __future__ import annotations

import contextlib
import datetime
import hashlib
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
for _path in (HERE, SCRIPTS):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import engine  # noqa: E402
import evidence_doc as E  # noqa: E402
import predicates as P  # noqa: E402
import probes  # noqa: E402
import runner  # noqa: E402
from live import binary, exclusive, fixture, mcp, obs, screen, spec_probes  # noqa: E402
from live import locale as live_locale  # noqa: E402

#: Where sidecars go, one file per sha256 of its bytes (D5).
SIDECARS = os.path.expanduser("~/lpm-evidence/verify-runs")
#: How long a run waits for another holder of the live lock before it refuses, and how often it looks.
LOCK_WAIT_S = 3600.0
LOCK_POLL_S = 30.0
#: The MCU surface. plan-p0b2 section 5 puts registration at 8-16 s; the bound leaves room for both.
MCU_STATE = spec_probes.MCU_STATE
READY_TIMEOUT_S = 45.0
READY_INTERVAL_S = 0.5
READY_READ_S = 10.0
SETTLE_S = 8.0
SERVER_INIT_S = 60.0


# ---------------------------------------------------------------------------------------------
# what a reply stores
# ---------------------------------------------------------------------------------------------

def _same_json(text: str, value) -> bool:
    try:
        return P.same(E.loads(text), value)
    except ValueError:
        return False


def _unsent(call: dict):
    """Why a request record holds no reply to read, or None when it holds one."""
    if not call.get("sent"):
        return f"the request was not sent: {call.get('cause')}"
    if call.get("server_exited"):
        return f"the server exited before replying (returncode {call.get('returncode')})"
    reply = call.get("reply")
    if not isinstance(reply, dict):
        return "no reply was matched to the request"
    if "error" in reply:
        return (f"the reply is a JSON-RPC error: "
                f"{json.dumps(reply['error'], ensure_ascii=False, sort_keys=True)}")
    if not isinstance(reply.get("result"), dict):
        return "the reply has no result object"
    return None


def text_of(call: dict, items: str) -> str:
    """The text of `result[items][0]` in a live.mcp request record, exactly as the server sent it."""
    if call.get("timed_out"):
        raise runner.StepUnreadable(f"no reply within {call.get('elapsed_s') or 0:.1f} s")
    why = _unsent(call)
    if why:
        raise runner.StepUnreadable(why)
    result = call["reply"]["result"]
    listed = result.get(items)
    first = listed[0] if isinstance(listed, list) and listed else None
    if not (isinstance(first, dict) and isinstance(first.get("text"), str)):
        raise runner.StepUnreadable(f"the result has no text in {items}[0]")
    structured = result.get("structuredContent")
    if structured is not None and not _same_json(first["text"], structured):
        raise runner.StepUnreadable("the result's text and its structuredContent are not the same JSON")
    return first["text"]


class McpSession(runner.Session):
    """A live.mcp.Server as the runner's Session: started here, stopped by `close`."""

    def __init__(self, server: mcp.Server, init_timeout_s: float = SERVER_INIT_S):
        self.server = server
        self.started = server.start(init_timeout_s=init_timeout_s)

    @property
    def pid(self):
        return self.server.pid

    def call(self, tool, command, params, timeout_s):
        return text_of(self.server.tool(tool, command, params, timeout_s), "content")

    def read(self, uri, timeout_s):
        return text_of(self.server.resource(uri, timeout_s), "contents")

    def close(self):
        self.server.stop()
        return self.server.record()


# ---------------------------------------------------------------------------------------------
# the gate's reading
# ---------------------------------------------------------------------------------------------

def gate_reading_of(fx: dict, flags: dict, upper_row) -> dict:
    """The reading setups.gate_problems judges, from one track_flags_ax probe output, the
    live/fixture.py declaration `fx` it is compared with, and an upper-row reading (or None)."""
    observation = flags.get("observation") or {}
    reading = {"declared": {"track_count": fx["track_count"], "names": list(fx["names"])},
               "fingerprint": fixture.fingerprint_of(observation), "upper_row": upper_row}
    if not observation.get("readable"):
        reading["cause"] = observation.get("cause") or flags.get("cause") or "track_flags_ax did not read"
    return reading


# ---------------------------------------------------------------------------------------------
# the lifecycle
# ---------------------------------------------------------------------------------------------

class LiveLifecycle(runner.Lifecycle):
    """The world, driven. One instance per `verify.py run` or `batch`."""

    def __init__(self, repo: str = None, lock_wait_s: float = LOCK_WAIT_S, sidecars: str = SIDECARS):
        self.repo = repo or engine.repo_root()
        self.builds = binary.Builds(self.repo)
        self.lock_wait_s = lock_wait_s
        self.sidecars = sidecars
        self.own_pids = set()

    def now(self):
        return obs.now()

    def sleep(self, seconds):
        time.sleep(seconds)

    def today(self):
        return datetime.date.today().isoformat()

    def build(self, head):
        result = self.builds.get(head)
        if not result.get("binary_path") or not result.get("binary_sha256"):
            tail = (result.get("build_log_tail") or "").strip().splitlines()[-1:]
            raise runner.BuildFailed(f"{result.get('cause') or 'the build returned no binary'}"
                                     f"{'; ' + tail[0] if tail else ''}")
        return runner.Built(head=result["head"], sha256=result["binary_sha256"],
                            path=result["binary_path"], record=result)

    @contextlib.contextmanager
    def claim(self, purpose):
        record = {}
        try:
            where = exclusive.lock_path()
        except exclusive.LockPathUnset as exc:
            where = f"(none: {exc})"
        print(f"run: waiting up to {self.lock_wait_s:g} s for the live lock {where}")
        with exclusive.claim(purpose, self.lock_wait_s, record, interval_s=LOCK_POLL_S,
                             break_stale=False) as held:
            yield {"held": bool(held), "refused": record.get("refused"), "record": record}

    def current_locale(self):
        setting = live_locale.language_setting()
        if not setting.get("readable") or not setting.get("value"):
            return None
        code = setting["value"][0]
        return next((lproj for lproj, c in live_locale.CODES.items() if c == code), None)

    def switch(self, lproj):
        record = live_locale.switch_to(lproj)
        return {**record, "switched": bool(record.get("switched"))}

    def reading(self, lproj):
        return live_locale.reading(lproj)

    def host(self, lproj):
        import observation_host
        return observation_host.host()

    def start(self, ctx, env):
        session = McpSession(mcp.Server(ctx["built"].path, env=env))
        if session.pid is not None:
            self.own_pids.add(session.pid)
        return session

    def fixture_problems(self, decl):
        name = decl.get("live")
        fx = fixture.FIXTURES.get(name)
        if fx is None:
            return [f"fixture {decl['id']!r} has no live declaration (setups.SETUPS gives "
                    f"{name!r}); only the self-test drives it"]
        out = []
        if os.path.realpath(fx["path"]) != os.path.realpath(live_locale.FIXTURE):
            out.append(f"fixture {decl['id']!r} is {fx['path']}, but every locale switch reopens "
                       f"{live_locale.FIXTURE}")
        if fx["mixer_strips"] is not None:
            out.append(f"fixture {decl['id']!r} needs the Mixer shown, which neither a switch nor "
                       f"the gate does")
        if decl.get("ready") not in (None, "mcu"):
            out.append(f"fixture {decl['id']!r} waits on {decl.get('ready')!r}; this lifecycle "
                       f"knows \"mcu\" and none")
        return out

    def gate_reading(self, ctx):
        decl = ctx["decl"]
        record = fixture.read(decl["live"], ctx["lproj"])
        upper_row = self._upper_row(ctx) if "mcu_upper_row_is_baseline" in decl["gate"] else None
        reading = gate_reading_of(fixture.FIXTURES[decl["live"]], record["track_flags"], upper_row)
        data = json.dumps(record["track_flags"], ensure_ascii=False, sort_keys=True, default=repr)
        reading["walk_sha256"] = self.sidecar(data.encode("utf-8"))
        return reading

    def _upper_row(self, ctx):
        session = ctx.get("session")
        if session is None:
            return {"readable": False, "cause": "no server is running to read it"}
        try:
            return spec_probes.upper_row_of(session.read(MCU_STATE, READY_READ_S))
        except runner.StepUnreadable as exc:
            return {"readable": False, "cause": str(exc)}

    def reset(self, ctx):
        record = fixture.reset(ctx["decl"]["live"], ctx["lproj"])
        return {"fixture": ctx["decl"]["live"], "lproj": ctx["lproj"],
                "record_sha256": self._kept(record)}

    def ready(self, ctx):
        if ctx["decl"].get("ready") is None:
            return {"ready": True, "surface": None}
        session = ctx["session"]

        def poll():
            try:
                state = E.loads(session.read(MCU_STATE, READY_READ_S))
            except (runner.StepUnreadable, ValueError) as exc:
                return {"unreadable": str(exc)}
            conn = state.get("connection") if isinstance(state, dict) else None
            conn = conn if isinstance(conn, dict) else {}
            return {"isConnected": conn.get("isConnected"),
                    "registeredAsDevice": conn.get("registeredAsDevice")}

        waited = obs.wait_until(poll, READY_TIMEOUT_S, READY_INTERVAL_S,
                                done=lambda r: r.get("isConnected") is True
                                and r.get("registeredAsDevice") is True)
        return {"ready": not waited["timed_out"], "surface": MCU_STATE, "polls": waited["polls"],
                "elapsed_s": round(waited["elapsed_s"], 3), "last": waited["last"]}

    def settle(self, ctx):
        record = screen.settle_to_clean(timeout_s=SETTLE_S)
        dirt = {when: (record.get(when) if isinstance(record.get(when), dict) else {}).get("dirt")
                for when in ("initial", "final")}
        return {"dirt": dirt, "escapes_sent": record.get("escapes_sent"),
                "timed_out": record.get("timed_out"), "record_sha256": self._kept(record)}

    def probe(self, name, ctx, args):
        return probes.run(name, ctx, args)

    def problems(self, ctx, when):
        dirt = list(screen.clean_state()["dirt"])
        rivals = exclusive.competing_now(tuple(self.own_pids))
        if not rivals.get("readable"):
            dirt.append({"kind": "process_table_unreadable", "cause": rivals.get("cause")})
        else:
            dirt += [{"kind": "rival_process", "what": r.get("kind"), "pid": r.get("pid"),
                      "comm": r.get("comm")} for r in rivals["value"]]
        return dirt

    def rest(self):
        record = live_locale.restore_locale()
        after = record.get("after") or live_locale.reading(runner.RESTING)
        return {"in_locale": live_locale.in_locale(after), "record": record}

    def _kept(self, record) -> str:
        """A lifecycle record kept whole in a sidecar (D5); its sha256 is what the evidence holds."""
        return self.sidecar(json.dumps(record, ensure_ascii=False, sort_keys=True,
                                       default=repr).encode("utf-8"))

    def sidecar(self, data):
        sha = hashlib.sha256(data).hexdigest()
        path = os.path.join(self.sidecars, f"{sha}.json")
        if not (os.path.isfile(path) and E.sha256_of_file(path) == sha):
            E.write_bytes_atomic(path, data)
        return sha
