"""The probe registry of the fixed verifier (ADR-027 D2). Declarations now; implementations in P0b.

A probe is the only feature-specific code the verifier allows: a named reader (or actuator) that
turns Logic's state into one JSON value. An acceptance row names a probe by `name` with `args`, and
`verify.py check-spec` refuses a name that is not declared here or args that do not match its
declaration. That is the whole plugin surface -- there is no discovery, no loading by path, and
no way for a row to bring its own code.

WHAT P0b MUST SUPPLY FOR EACH ENTRY
-----------------------------------
    run(session, args) -> str     the probe's reading as JSON TEXT, exactly as produced. The runner
                                  stores that text untruncated through
                                  `evidence_doc.make_observation`; the engine parses it. A probe
                                  that cannot read returns nothing and raises `ProbeUnreadable`,
                                  which the runner stores with `evidence_doc.unreadable_observation`.
                                  It never returns a default in place of a reading.
    a positive control            a fixture state in which the probe must return a known value
    its own mutants               ADR-027 D4: a probe no mutant can flip is refused

`session` is the P0b runner's handle on one MCP server process (tool calls and resource reads);
its type is defined in P0b, and nothing here depends on it.

The declarations below are the ones `docs/acceptance/1020.json` uses. `args` maps an argument
name to its JSON type (`int`, `str`, `bool`); `returns` is the JSON shape the engine will read
paths from, and it is a contract P0b's implementation is tested against.
"""
from __future__ import annotations

#: name -> {"args": {arg: json type}, "returns": shape, "reads": what it observes}
PROBES = {
    "track_armed": {
        "args": {"index": "int"},
        "returns": '{"track": <int>, "armed": <bool | null>}',
        "reads": "logic_system refresh_cache, then logic://tracks; `armed` is data[id=index].isArmed. "
                 "A track the list does not carry is UNREADABLE, never armed:false.",
    },
    "armed_set": {
        "args": {},
        "returns": '{"armed": [<int>, ...]}',
        "reads": "logic_system refresh_cache, then logic://tracks; the sorted ids whose isArmed is "
                 "true. An unreadable list is UNREADABLE, never [].",
    },
    "mcu_upper_row": {
        "args": {},
        "returns": '{"upper_row": <str>}',
        "reads": "logic://mcu/state; the Mackie Control LCD upper row as the server last received it.",
    },
}

#: The JSON types an argument declaration may name, and the Python types they admit.
ARG_TYPES = {"int": (int,), "str": (str,), "bool": (bool,)}


class ProbeUnreadable(Exception):
    """A probe could not read. The message is stored as the observation's `unreadable` reason."""


def arg_problems(name: str, args) -> list:
    """Why these args do not match the declaration of `name`; empty when they do."""
    if name not in PROBES:
        return [f"probe {name!r} is not declared in Scripts/verify/probes.py"]
    declared = PROBES[name]["args"]
    if not isinstance(args, dict):
        return [f"probe {name!r}: args must be an object"]
    out = []
    if set(args) != set(declared):
        out.append(f"probe {name!r} takes {sorted(declared)}, the row passes {sorted(args)}")
    for key, kind in declared.items():
        if key in args:
            value = args[key]
            ok = isinstance(value, ARG_TYPES[kind]) and not (kind == "int" and isinstance(value, bool))
            if not ok:
                out.append(f"probe {name!r}: {key} must be {kind}, not {type(value).__name__}")
    return out


def run(name: str, session, args: dict) -> str:
    """P0b: execute a declared probe against a live server and return its JSON text."""
    raise NotImplementedError("P0b: probes are declared in this commit set and implemented in P0b")
