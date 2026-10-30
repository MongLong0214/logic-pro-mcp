"""The probe registry of the fixed verifier (ADR-027 D2): declarations here, implementations in
live/spec_probes.py, loaded only when a probe runs, so the engine imports no live code.

A probe is the only feature-specific code the verifier allows: a named reader (or actuator) that
turns Logic's state into one JSON value. An acceptance row names a probe by `name` with `args`, and
`verify.py check-spec` refuses a name that is not declared here or args that do not match its
declaration. That is the whole plugin surface -- there is no discovery, no loading by path, and
no way for a row to bring its own code.

WHAT EACH ENTRY HAS
-------------------
    run(name, ctx, args) -> str   the probe's reading as JSON TEXT, exactly as produced. The runner
                                  stores that text untruncated through
                                  `evidence_doc.make_observation`; the engine parses it. A probe
                                  that cannot read returns nothing and raises `ProbeUnreadable`,
                                  which the runner stores with `evidence_doc.unreadable_observation`.
                                  It never returns a default in place of a reading.
    a positive control            a fixture state in which the probe must return a known value
    its own mutants               ADR-027 D4: a probe no mutant can flip is refused

`ctx` is the runner's per-locale context: the lproj (a row cannot pass it), the fixture's
declaration (setups.py), the MCP server handle (`session`: tool calls and resource reads) and the
lifecycle, which keeps sidecars. `unimplemented` names a declared probe live/spec_probes.py does
not implement; the runner refuses a spec that uses one.

The declarations below are the ones the pilot acceptance documents use. `args` maps an argument
name to its JSON type (`int`, `str`, `bool`); `returns` is the JSON shape the engine will read
paths from, and it is a contract P0b's implementation is tested against.
"""
from __future__ import annotations

#: name -> {"args": {arg: json type}, "returns": shape, "reads": what it observes}
PROBES = {
    "track_armed": {
        "args": {"index": "int"},
        "returns": '{"track": <int>, "armed": <bool | null>}',
        "reads": "the verifier's own AX walk (live/probes.py track_flags_ax, labels from Apple's "
                 "rows), not the product (D1): `armed` is the Record Enable checkbox of the index-th "
                 "track of the arrange rail. A walk that does not read the fixture's declared track "
                 "count, a track it does not carry, or a checkbox missing, doubled or unread is "
                 "UNREADABLE, never armed:false. The reading cites the walk by walk_sha256.",
    },
    "armed_set": {
        "args": {},
        "returns": '{"armed": [<int>, ...]}',
        "reads": "the same walk as track_armed: the sorted indices whose Record Enable is 1. "
                 "UNREADABLE unless every declared track's checkbox read, never [].",
    },
    "mcu_upper_row": {
        "args": {},
        "returns": '{"upper_row": <str>}',
        "reads": "logic://mcu/state, the PRODUCT's reading (nothing else reads the LCD): "
                 "display.upperRow, the Mackie Control LCD upper row as the server last received "
                 "it, with the resource text embedded whole.",
    },
    "undo_entry": {
        "args": {},
        "returns": '{"title": <str>, "enabled": <bool>, "shortcut": "cmd+z"}',
        "reads": "the verifier's own AX read of Logic's state-dependent Edit-menu Cmd-Z row, "
                 "identified by shortcut rather than localized title. The reader opens the "
                 "localized Edit menu because Logic populates the current Undo title only while "
                 "open, then requires screen.settle_to_clean to observe and close that menu.",
    },
    "routing_slots": {
        "args": {},
        "returns": '{"strip_count": <int>, "occupied_strips": [<int>, ...], '
                   '"send_counts": [<int>, ...], "inputs": [<assignment | null>, ...], '
                   '"outputs": [<assignment | null>, ...], "product_edges": [<edge>, ...], '
                   '"product_send_edges": []}',
        "reads": "the verifier's own routing_slots_ax walk of the Mixer. Output descriptions are "
                 "classified only with the installed Logic bundle's rows for this locale; unknown "
                 "text remains explicit. Send occupancy comes only from the independently witnessed "
                 "slot/knob shape, never from the product's send state. It also reads the product's "
                 "logic://mixer before and after a completed refresh_cache AX poll, requires the "
                 "Mixer timestamp to advance with fresh ax_poll provenance and its full routing "
                 "topology to equal the independent walk, and is UNREADABLE if that graph "
                 "publishes a Send source edge without an independently witnessed destination.",
    },
    "routing_send_assign": {
        "args": {"strip": "int"},
        "returns": '{"strip": <int>, "selected": <str>, "record_sha256": <str>}',
        "reads": "the registered #291 positive-control actuator: press the declared fixture "
                 "strip's sole empty Send and select the highest numbered Bus by its localized "
                 "Apple-row title. The full actuation/settlement record is kept as a sidecar. "
                 "The acceptance row restores it through the product's public undo command and "
                 "independently reads the restored Mixer.",
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


def _implementation(name: str):
    from live import spec_probes  # here, not at the top: the engine imports no live code
    return spec_probes, getattr(spec_probes, name, None)


def run(name: str, ctx: dict, args: dict) -> str:
    """A declared probe's reading as JSON text; ProbeUnreadable saying why when it cannot read."""
    spec_probes, probe = _implementation(name)
    if name not in PROBES or not callable(probe):
        raise ProbeUnreadable(f"probe {name!r} is not declared and implemented")
    try:
        return probe(ctx, **args)
    except spec_probes.Unreadable as exc:
        raise ProbeUnreadable(str(exc)) from exc


def used(spec: dict) -> list:
    """The probe names a spec's steps and waits read, sorted."""
    names = set()
    for row in spec["rows"]:
        for step in row["steps"] + row["restore"]:
            for holder in (step, step.get("wait") or {}):
                if "probe" in holder:
                    names.add(holder["probe"]["name"])
    return sorted(names)


def unimplemented(spec: dict) -> list:
    """Why the spec uses a probe live/spec_probes.py does not implement; empty when it does not."""
    return [f"probe {name!r} is declared but live/spec_probes.py does not implement it"
            for name in used(spec) if not callable(_implementation(name)[1])]
