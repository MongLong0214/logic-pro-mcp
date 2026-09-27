"""The runner of the fixed verifier (ADR-027 D2, D5): it drives a spec's rows and certifies what it made.

`verify.py run` and `verify.py batch` call `run_spec` and `run_batch`. Everything that touches the
world -- the build, the live lock, Logic's locale, the fixture, the server, the probes, the screen --
is a `Lifecycle`, injected. `runner_live.LiveLifecycle` drives Logic; the self-test's
`FakeLifecycle` scripts it, on a fake clock. This module decides only the order of things and what
is stored, and it holds the one place outside the self-test that builds an `engine.Attestation`.

THE FLOW, per run (plan-p0b2 section 1)
---------------------------------------
    admit    engine.validate_spec, which also refuses a fixture the registry (setups.py) does not
             declare; probes.unimplemented, a declared probe live/spec_probes.py lacks; then
             life.fixture_problems: the lifecycle must be able to drive the
             declaration; any problem is exit 2 and Logic is not touched
    build    life.build(head) -> Built; a failed build is exit 2 and writes no evidence
    claim    life.claim(): the live lock and no rival server; refused is exit 2
    locales  current locale first, Korean last. Per locale: switch once; per entry: a fresh locale
             reading; a run whose reading does not show Logic in that locale drives nothing
             (every step unreadable, and the engine refuses or reports it). Then the server is
             started with the declaration's server_env and the fixture's surface awaited; the
             fixture's baseline (life.gate_reading) is read once per locale, after it was first
             opened there. Before each row the screen is settled and the fixture gated: the
             lifecycle reads, setups.gate_problems judges against the declaration and the
             baseline, and both are logged; a gate miss gets one full reset (server stopped, fixture reopened,
             server restarted, surface awaited) and a second gate; a row whose gate still fails is
             stored with every step unreadable. A switch that found Logic already in the locale
             is followed by a reset, so every locale starts from the file on disk.
    rest     back to Korean, confirmed by the lifecycle; the lock is released
    produce  the document, serialized once; the attestation over the digest of those bytes
             as parsed back, the same parse `judge` and `record_attested` make
    judge    engine.judge(parsed, attestation) -- the exit code is its verdict
    record   with a records directory: verify.record_attested over the same bytes

WHAT A STEP STORES
------------------
Before each step the lifecycle is sampled (screen lock, a modal, an open menu, a rival server). A
step taken while any of that is dirty is not taken: it is stored unreadable with the dirt. After a
probe or wait the sample is taken again, and dirt then makes the reading unreadable. A step's text
is stored whole through `evidence_doc.make_observation`; a step that could not be read is stored
through `evidence_doc.unreadable_observation` with why. Nothing here stores a default in place of a
reading, and restore steps always run, whatever happened to the steps before them.

A `wait` polls its probe until its condition holds or its bound passes, on the lifecycle's clock:
at most timeout/interval + 1 polls. It stores the last reading either way; whether that reading
passes is the engine's to say.

WHO CAN CERTIFY CLEAN
---------------------
`_attest` is the one Attestation site outside the self-test (selftest.ATTESTATION_SITES). Its four
fields come from this process: the `Built` it got from its own build, the locale readings it took
(normalized once when taken, so the stored copy and the attested copy are the same JSON), and the
digest of the bytes it serialized. It reads no file. The self-test refuses, in every tracked file
but this one, a reference to the four names that reach an Attestation or take a lifecycle
positionally (`_attest`, `_produce`, `_finish`, `_drive`), and a `_life=` keyword outside the
self-test: a fake lifecycle reaching clean, or writing records, is the self-test's business only.
"""
from __future__ import annotations

import dataclasses
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import engine  # noqa: E402
import evidence_doc as E  # noqa: E402
import predicates as P  # noqa: E402
import probes  # noqa: E402
import setups  # noqa: E402

#: The locale Logic rests in between runs, and the one every run ends in.
RESTING = "ko"
#: Seconds a tools/call or resources/read may take before the step is unreadable.
CALL_TIMEOUT_S = 120.0
READ_TIMEOUT_S = 60.0
PURPOSE = "verify.py run"


class StepUnreadable(Exception):
    """A step could not be read. The message is stored as the observation's reason."""


class BuildFailed(Exception):
    """The head did not build. A run exits 2 on it and writes no evidence."""


@dataclasses.dataclass(frozen=True)
class Built:
    """A binary this process built from `head`, measured by the builder right after it built it."""
    head: str
    sha256: str
    path: str
    record: dict = dataclasses.field(compare=False, repr=False)

    def block(self) -> dict:
        """The evidence's binary block, keyed by evidence_doc's names."""
        log = self.record.get("build_log") if isinstance(self.record, dict) else None
        return {E.BINARY_PATH: self.path, E.BINARY_SHA256: self.sha256, E.HEAD: self.head,
                E.BINDING: E.BOUND,
                "note": f"built by verify.py run from a clean detached checkout of {self.head}, "
                        f"copied to a new path and hashed there; build log {log}"}


class Session:
    """One MCP server process started from a `Built` binary, for one locale of one entry."""

    pid = None

    def call(self, tool: str, command: str, params: dict, timeout_s: float) -> str:
        """The tools/call reply's text, exactly as received; StepUnreadable when there is none."""
        raise NotImplementedError

    def read(self, uri: str, timeout_s: float) -> str:
        """The resources/read text, exactly as received; StepUnreadable when there is none."""
        raise NotImplementedError

    def close(self) -> dict:
        """Stop the server; its record (start, transcript, stop) as JSON-able data."""
        raise NotImplementedError


class Lifecycle:
    """Everything the runner does to the world. `ctx` is the runner's per-locale context:
    {"life", "lproj", "decl", "built", "session", "row", "step", "log"}."""

    def now(self) -> float:
        raise NotImplementedError

    def sleep(self, seconds: float) -> None:
        raise NotImplementedError

    def today(self) -> str:
        """YYYY-MM-DD, stored as the run's date."""
        raise NotImplementedError

    def build(self, head: str) -> Built:
        """Build `head`; raise BuildFailed with why."""
        raise NotImplementedError

    def claim(self, purpose: str):
        """A context manager yielding {"held": bool, ...record}; released on exit."""
        raise NotImplementedError

    def current_locale(self):
        """The lproj Logic is in now, or None when that cannot be read."""
        raise NotImplementedError

    def switch(self, lproj: str) -> dict:
        """Put Logic in `lproj` on the fixture: {"switched": bool (False when it already was), ...}."""
        raise NotImplementedError

    def reading(self, lproj: str) -> dict:
        """live/locale.py reading(lproj), taken now."""
        raise NotImplementedError

    def host(self, lproj: str) -> dict:
        """Scripts/observation_host.py's host block, measured now."""
        raise NotImplementedError

    def start(self, ctx: dict, env: dict) -> Session:
        """Start a server from ctx["built"] with `env` added to its environment."""
        raise NotImplementedError

    def ready(self, ctx: dict) -> dict:
        """Wait (bounded) until the fixture's surface answers ctx["session"]: {"ready": bool, ...}."""
        raise NotImplementedError

    def fixture_problems(self, decl: dict) -> list:
        """Why this lifecycle cannot drive the declared fixture at all; empty when it can."""
        raise NotImplementedError

    def gate_reading(self, ctx: dict) -> dict:
        """The fixture as it is now, in the shape setups.gate_problems reads. The first one taken in
        a locale is that locale's baseline."""
        raise NotImplementedError

    def reset(self, ctx: dict) -> dict:
        """Put the fixture back as found (Don't Save, reopen). The runner restarts the server."""
        raise NotImplementedError

    def settle(self, ctx: dict) -> dict:
        """Between rows only: bring the screen to clean if a menu is open; a record."""
        raise NotImplementedError

    def problems(self, ctx: dict, when: str) -> list:
        """What is dirty now ("before" or "after" ctx["step"]): [{"kind": ..., ...}]; empty is clean."""
        raise NotImplementedError

    def probe(self, name: str, ctx: dict, args: dict) -> str:
        """A declared probe's reading as JSON text; probes.ProbeUnreadable when it cannot read."""
        raise NotImplementedError

    def rest(self) -> dict:
        """Put Logic back in Korean: {"in_locale": bool, "reading": ...}."""
        raise NotImplementedError

    def sidecar(self, data: bytes) -> str:
        """Keep bytes too large for the evidence beside it; their sha256."""
        raise NotImplementedError


# ---------------------------------------------------------------------------------------------
# admission and order
# ---------------------------------------------------------------------------------------------

def normalize(value):
    """A reading as JSON gives it back: a tuple becomes a list, and a NaN is refused (ValueError).
    Taken once when a reading is taken, so the stored and the attested copies are the same JSON."""
    return json.loads(json.dumps(value, ensure_ascii=False, allow_nan=False))


def declaration(spec: dict) -> dict:
    """The fixture a spec names, as the registry declares it (setups.SETUPS)."""
    return setups.declaration(spec["fixture"]["id"])


def admit(spec, locales) -> list:
    """Why this spec cannot be run in these locales; empty when it can."""
    problems = [f"spec: {p}" for p in engine.validate_spec(spec)]
    if not problems:
        problems = [f"spec: {p}" for p in probes.unimplemented(spec)]
    if problems or locales is None:
        return problems
    required = engine.required_locales(spec)
    out = [f"locale {x!r} is not one of the spec's required locales {required}" for x in locales
           if x not in required]
    if len(set(locales)) != len(locales) or not locales:
        out.append(f"locales {locales} name a locale twice, or none")
    return out


def order(locales, current) -> list:
    """The order locales are driven in: the current one first, Korean last, else canonical."""
    rest = [x for x in engine.ALL_LOCALES if x in locales and x != RESTING]
    if current in rest:
        rest.remove(current)
        rest.insert(0, current)
    return rest + ([RESTING] if RESTING in locales else [])


# ---------------------------------------------------------------------------------------------
# steps
# ---------------------------------------------------------------------------------------------

def _dirt_text(dirt: list) -> str:
    return ", ".join(sorted({str(d.get("kind")) if isinstance(d, dict) else str(d) for d in dirt}))


def _holds(until: dict, text: str) -> bool:
    """Whether a wait's condition holds over one reading's text."""
    try:
        value = E.loads(text)
    except ValueError:
        return False
    joiner = "" if until["path"].startswith("[") else "."
    _, segments = P.parse_path("reading" + joiner + until["path"])
    operand = P.Found(until["value"]) if "value" in until else None
    return P.check(until["op"], P.walk(value, segments), operand)[0] == P.PASS


def _wait(ctx: dict, step: dict) -> str:
    life, wait = ctx["life"], step["wait"]
    bound = life.now() + wait["timeout_ms"] / 1000.0
    last, why, polls, held = None, None, 0, False
    while True:
        polls += 1
        try:
            last, why = life.probe(wait["probe"]["name"], ctx, wait["probe"]["args"]), None
        except probes.ProbeUnreadable as exc:
            last, why = None, str(exc) or "the probe could not read"
        if last is not None and _holds(wait["until"], last):
            held = True
            break
        if life.now() >= bound:
            break
        life.sleep(wait["interval_ms"] / 1000.0)
    ctx["log"].append({"t": life.now(), "at": f"{ctx['row']}/{step['as']}", "wait_polls": polls,
                       "wait_held": held})
    print(f"  wait {ctx['lproj']}/{ctx['row']}/{step['as']}: {polls} poll(s), "
          f"condition {'held' if held else 'did not hold'}")
    if last is None:
        raise probes.ProbeUnreadable(f"the wait's last poll could not read: {why}")
    return last


def _take(ctx: dict, step: dict) -> str:
    if "call" in step:
        call = step["call"]
        return ctx["session"].call(call["tool"], call["command"], call["params"], CALL_TIMEOUT_S)
    if "read" in step:
        return ctx["session"].read(step["read"]["uri"], READ_TIMEOUT_S)
    if "probe" in step:
        return ctx["life"].probe(step["probe"]["name"], ctx, step["probe"]["args"])
    return _wait(ctx, step)


def execute_step(ctx: dict, step: dict) -> dict:
    """Run one step and return its observation entry. Never raises for a step that went wrong."""
    life = ctx["life"]
    ctx["step"] = step
    at = f"{ctx['row']}/{step['as']}"
    dirt = life.problems(ctx, "before")
    ctx["log"].append({"t": life.now(), "at": at, "before": _dirt_text(dirt)})
    if dirt:
        return E.unreadable_observation(step, f"the machine was not clean before the step: "
                                              f"{_dirt_text(dirt)}")
    try:
        text = _take(ctx, step)
    except (StepUnreadable, probes.ProbeUnreadable) as exc:
        return E.unreadable_observation(step, str(exc) or type(exc).__name__)
    except Exception as exc:  # noqa: BLE001 - a step that raised is unreadable, with its type
        return E.unreadable_observation(step, f"the step raised {type(exc).__name__}: {exc}")
    if not isinstance(text, str):
        return E.unreadable_observation(step, f"the step returned {type(text).__name__}, not text")
    if "probe" in step or "wait" in step:
        after = life.problems(ctx, "after")
        ctx["log"].append({"t": life.now(), "at": at, "after": _dirt_text(after)})
        if after:
            return E.unreadable_observation(step, f"the machine was not clean after the read: "
                                                  f"{_dirt_text(after)}")
    return E.make_observation(step, text)


def run_row(ctx: dict, row: dict) -> dict:
    """Every step, then every restore step, whatever happened to the steps before it."""
    entries = {}
    try:
        for step in row["steps"]:
            entries[step["as"]] = execute_step(ctx, step)
    finally:
        for step in row["restore"]:
            entries[step["as"]] = execute_step(ctx, step)
    return {"observations": entries}


def _unread_row(row: dict, why: str) -> dict:
    return {"observations": {s["as"]: E.unreadable_observation(s, why)
                             for s in row["steps"] + row["restore"]}}


def _stored(lproj: str, row: dict, stored: dict) -> None:
    shown = [name + ("" if "raw" in entry else " (unreadable)")
             for name, entry in stored["observations"].items()]
    print(f"  {lproj}/{row['id']}: stored {', '.join(shown)}")


# ---------------------------------------------------------------------------------------------
# a locale
# ---------------------------------------------------------------------------------------------

def _close(ctx: dict, run: dict) -> None:
    session = ctx.get("session")
    if session is None:
        return
    ctx["session"] = None
    try:
        record = session.close()
    except Exception as exc:  # noqa: BLE001 - a failed stop is recorded, not raised
        record = {"close_raised": f"{type(exc).__name__}: {exc}"}
    data = json.dumps(record, ensure_ascii=False, sort_keys=True, default=repr).encode("utf-8")
    run["transcripts"].append(ctx["life"].sidecar(data))


def _start(ctx: dict) -> bool:
    life, env = ctx["life"], dict(ctx["decl"]["server_env"])
    ctx["session"] = life.start(ctx, env)
    ready = life.ready(ctx)
    ctx["log"].append({"t": life.now(), "event": "start", "pid": ctx["session"].pid, "env": env,
                       "ready": ready})
    print(f"  {ctx['lproj']}: server pid {ctx['session'].pid} env {json.dumps(env, sort_keys=True)}; "
          f"{'ready' if ready.get('ready') else 'NOT ready'}")
    return bool(ready.get("ready"))


def _reset(ctx: dict, run: dict) -> bool:
    life = ctx["life"]
    _close(ctx, run)
    record = life.reset(ctx)
    ctx["log"].append({"t": life.now(), "event": "reset", "record": record})
    print(f"  {ctx['lproj']}: reset the fixture and restarted the server")
    return _start(ctx)


def _gate(ctx: dict, baseline: dict, ready: bool, extra: dict) -> list:
    """The gate before a row: the lifecycle reads, the registry judges; both are logged."""
    life = ctx["life"]
    if not ready:
        dirty, reading = ["the fixture's surface is not ready"], None
    else:
        reading = normalize(life.gate_reading(ctx))
        dirty = setups.gate_problems(ctx["decl"], reading, baseline)
    ctx["log"].append({"t": life.now(), "at": ctx["row"], "gate": dirty, "reading": reading, **extra})
    return dirty


def run_locale(life: Lifecycle, entry: dict, lproj: str, reset_first: bool, baselines: dict):
    """(run, reading) for one entry in one locale; Logic is already switched to it. `baselines`
    holds each locale's fixture baseline, read once when the fixture was first opened there."""
    spec = entry["spec"]
    reading = normalize(life.reading(lproj))
    log = []
    run = {"date": life.today(), "host": normalize(life.host(lproj)), E.LOCALE_READING: reading,
           "rows": {}, "lifecycle": log, "transcripts": []}
    status, why = engine.run_locale_status(lproj, run)
    if status != engine.MEASURED:
        print(f"  {lproj}: the locale reading is {status}: {why}; nothing is driven")
        for row in spec["rows"]:
            run["rows"][row["id"]] = _unread_row(row, f"the locale reading does not show Logic in "
                                                      f"{lproj}: {why}")
        return run, reading
    ctx = {"life": life, "lproj": lproj, "decl": entry["decl"], "built": entry["built"],
           "session": None, "row": None, "step": None, "log": log}
    try:
        if reset_first:
            log.append({"t": life.now(), "event": "reset", "record": life.reset(ctx)})
        ready = _start(ctx)
        if lproj not in baselines:
            baselines[lproj] = normalize(life.gate_reading(ctx))
        baseline = baselines[lproj]
        log.append({"t": life.now(), "event": "baseline", "baseline": baseline})
        for row in spec["rows"]:
            ctx["row"], ctx["step"] = row["id"], None
            log.append({"t": life.now(), "at": row["id"], "settle": life.settle(ctx)})
            dirty = _gate(ctx, baseline, ready, {})
            if dirty:
                print(f"  {lproj}/{row['id']}: gate missed ({'; '.join(map(str, dirty))}); one reset")
                ready = _reset(ctx, run)
                dirty = _gate(ctx, baseline, ready, {"after_reset": True})
            if dirty:
                run["rows"][row["id"]] = _unread_row(row, f"fixture not as declared after one reset: "
                                                          f"{'; '.join(map(str, dirty))}")
            else:
                run["rows"][row["id"]] = run_row(ctx, row)
            _stored(lproj, row, run["rows"][row["id"]])
    finally:
        _close(ctx, run)
    return run, reading


# ---------------------------------------------------------------------------------------------
# the document, the one Attestation site, the verdict
# ---------------------------------------------------------------------------------------------

def _attest(built: Built, readings: dict, evidence_sha256: str):
    """The Attestation of this run: every field measured by this process, none read from a file."""
    return engine.Attestation(binary_sha256=built.sha256, head=built.head, locale_readings=readings,
                              evidence_sha256=evidence_sha256)


def _produce(spec: dict, spec_path: str, built: Built, runs: dict, readings: dict):
    """(data, parsed, attestation): the bytes written, those bytes parsed back, and the
    attestation over the digest of the parse, the same parse judge and record_attested make."""
    doc = E.new_document(spec, spec_path, built.block())
    doc["runs"] = runs
    doc["verdicts"] = {lproj: engine.evaluate_run(spec, run, lproj) for lproj, run in runs.items()}
    data = E.serialize(doc)
    parsed = E.loads(data.decode("utf-8"))
    return data, parsed, _attest(built, readings, E.sha256_of(parsed))


def _finish(entry: dict, record_dir) -> int:
    import verify
    data, parsed, att = _produce(entry["spec"], entry["spec_path"], entry["built"], entry["runs"],
                                entry["readings"])
    E.write_bytes_atomic(entry["out"], data)
    print(f"wrote {entry['out']} ({E.sha256_of_bytes(data)})")
    result = engine.judge(parsed, expected_spec=entry["spec"], attestation=att)
    code = verify.report(result, f"run: {entry['out']}")
    if record_dir is not None and result["exit"] != engine.EXIT_REFUSED:
        recorded = verify.record_attested(data, att, record_dir)
        if code == engine.EXIT_CLEAN and recorded != engine.EXIT_CLEAN:
            code = recorded
    return code


def worst(codes: list) -> int:
    """The worst exit of several: refused, then failed, then incomplete, then clean."""
    rank = {engine.EXIT_REFUSED: 0, engine.EXIT_FAILED: 1, engine.EXIT_INCOMPLETE: 2,
            engine.EXIT_CLEAN: 3}
    return min(codes, key=lambda c: rank[c]) if codes else engine.EXIT_REFUSED


def _drive(life: Lifecycle, entries: list, record_dir) -> int:
    """Admit, build, claim, drive every entry's locales with one switch per locale, rest, finish."""
    refused = []
    for n, entry in enumerate(entries):
        problems = admit(entry["spec"], entry["locales"])
        if not problems:
            entry["decl"] = declaration(entry["spec"])
            problems = life.fixture_problems(entry["decl"])
        refused += [f"entry {n} ({entry['spec_path']}): {p}" for p in problems]
    if refused:
        for line in refused:
            print(f"REFUSED {line}")
        print("run: refused before anything was built or driven (exit 2)")
        return engine.EXIT_REFUSED
    builds = {}
    for entry in entries:
        entry["locales"] = entry["locales"] or engine.required_locales(entry["spec"])
        try:
            if entry["head"] not in builds:
                builds[entry["head"]] = life.build(entry["head"])
        except BuildFailed as exc:
            print(f"REFUSED build of {entry['head']}: {exc}")
            print("run: the head did not build; no evidence is written (exit 2)")
            return engine.EXIT_REFUSED
        entry["built"] = builds[entry["head"]]
        entry["runs"], entry["readings"] = {}, {}
        print(f"run: built {entry['head']} -> {entry['built'].sha256} {entry['built'].path}")
    with life.claim(PURPOSE) as held:
        if not held.get("held"):
            print(f"REFUSED the live lane: {held.get('refused') or 'not held'}")
            print("run: the live lane was not claimed; nothing was driven (exit 2)")
            return engine.EXIT_REFUSED
        try:
            baselines = {}
            wanted = sorted({x for entry in entries for x in entry["locales"]})
            for lproj in order(wanted, life.current_locale()):
                switched = life.switch(lproj)
                print(f"run: {lproj}: {'switched' if switched.get('switched') else 'already there'}")
                reset_first = not switched.get("switched")
                for entry in entries:
                    if lproj not in entry["locales"]:
                        continue
                    run, reading = run_locale(life, entry, lproj, reset_first, baselines)
                    entry["runs"][lproj], entry["readings"][lproj] = run, reading
                    reset_first = False
        finally:
            rested = life.rest()
            print(f"run: rest in {RESTING}: {'confirmed' if rested.get('in_locale') else 'NOT confirmed'}")
    return worst([_finish(entry, record_dir) for entry in entries])


def run_spec(spec: dict, spec_path: str, head: str, locales, out_path: str, record_dir=None, *,
             _life=None) -> int:
    """Build `head`, drive `spec` in `locales` (default: the spec's), write the evidence to
    `out_path`, judge it with this run's attestation, and record it when `record_dir` is given.
    Without `_life` the world is the live one; `verify.py run` never passes it."""
    if _life is None:
        import runner_live
        _life = runner_live.LiveLifecycle()
    entry = {"spec": spec, "spec_path": spec_path, "head": head, "locales": locales, "out": out_path}
    return _drive(_life, [entry], record_dir)
