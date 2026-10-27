"""The probes Scripts/verify/probes.py declares, implemented (ADR-027 P0b-2).

    track_armed(ctx, index)  the verifier's own AX walk, live/probes.py track_flags_ax, whose labels
    armed_set(ctx)           come from Apple's rows (D1), not the product's logic://tracks: a product
                             label defect would read wrong on both sides. The walk is kept as a
                             sidecar and the reading cites it by `walk_sha256`.
    mcu_upper_row(ctx)       logic://mcu/state, the PRODUCT's reading of the Mackie Control LCD:
                             nothing else reads the LCD. The resource text is embedded whole.

Each is a pure function of what was read (`*_of`) behind a live reader, so the self-test judges the
pure part over walks recorded live (live/tests/samples/). A probe that cannot read raises
`Unreadable` saying why, which probes.run turns into probes.ProbeUnreadable; it never returns a
default in place of a reading. From Scripts/verify it imports only evidence_doc, whose `loads` is
the one parse every reading goes through (a stdlib-only module, so loading this from the engine's
registry loads no more of the verifier).

AX row order is taken as the track index (R5). It holds on the declared fixture, so a walk that
reads another track count than the fixture declares (a folder, a hidden track, a half-drawn rail) is
unreadable, never read as the tracks it happens to show.
"""

import json
import re

import evidence_doc as E

from . import controls, fixture
from . import locale as live_locale
from . import probes as live_probes

MCU_STATE = "logic://mcu/state"
#: How long mcu_upper_row waits for the resource.
READ_S = 10.0


class Unreadable(Exception):
    """The probe could not read; the message says why."""


def _text(value) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


# ---------------------------------------------------------------------------------------------
# what a walk and a resource text say
# ---------------------------------------------------------------------------------------------

def _rows(flags: dict, declared: int):
    """(rows, why): one track_flags_ax output's per-track rows, and why they cannot be taken as
    the declared fixture's tracks (None when they can)."""
    if flags.get("refused"):
        return None, f"track_flags_ax refused its args: {flags['refused']}"
    observation = flags.get("observation") or {}
    if not observation.get("readable"):
        return None, f"track_flags_ax did not read: {observation.get('cause') or 'no cause given'}"
    if observation.get("track_count") != declared:
        return None, (f"the walk read {observation.get('track_count')} tracks and the fixture "
                      f"declares {declared}, so its row order is not the track index")
    return observation["tracks"], None


def _armed(row: dict):
    """(armed, why) for one track row: its one Record Enable checkbox read 0 or 1, or why not."""
    matched = row["matches"]["arm"]
    if matched != 1 or "arm" in row["value_errors"] or row["arm"] not in (0, 1):
        return None, (f"track {row['index']}: Record Enable matched {matched} checkbox(es), "
                      f"value {row['arm']!r}, read error {row['value_errors'].get('arm')!r}")
    return row["arm"] == 1, None


def track_armed_of(flags: dict, declared: int, index: int) -> dict:
    rows, why = _rows(flags, declared)
    if why is None and not 0 <= index < len(rows):
        why = f"track {index} is not among the {len(rows)} tracks read"
    armed, why = (None, why) if why else _armed(rows[index])
    if why:
        raise Unreadable(f"track_armed: {why}")
    return {"track": index, "armed": armed, "name": rows[index]["name"]}


def armed_set_of(flags: dict, declared: int) -> dict:
    rows, why = _rows(flags, declared)
    read = [] if why else [_armed(row) for row in rows]
    why = why or next((w for _, w in read if w), None)
    if why:
        raise Unreadable(f"armed_set: {why}")
    return {"armed": [row["index"] for row, (armed, _) in zip(rows, read) if armed]}


def upper_row_of(text: str) -> dict:
    """display.upperRow of one logic://mcu/state text: {"readable": True, "value": row}, or
    {"readable": False, "cause": why}. The fixture gate reads the row through this too."""
    try:
        state = E.loads(text)
    except ValueError as exc:
        return {"readable": False, "cause": f"{MCU_STATE} is not JSON: {exc}"}
    display = state.get("display") if isinstance(state, dict) else None
    row = display.get("upperRow") if isinstance(display, dict) else None
    if not isinstance(row, str):
        return {"readable": False, "cause": f"{MCU_STATE} has no display.upperRow string"}
    return {"readable": True, "value": row}


def mcu_upper_row_of(text: str) -> dict:
    row = upper_row_of(text)
    if not row["readable"]:
        raise Unreadable(f"mcu_upper_row: {row['cause']}")
    return {"upper_row": row["value"], "resource_text": text}


# ---------------------------------------------------------------------------------------------
# the live readers: ctx is the runner's (lproj, decl, session, life)
# ---------------------------------------------------------------------------------------------

def _walk(ctx: dict):
    """(one track_flags_ax output, its sidecar's sha256, the fixture's declared track count)."""
    fx = fixture.FIXTURES[ctx["decl"]["live"]]
    flags = live_probes.run("track_flags_ax", {"lproj": ctx["lproj"], "fixture": fx["path"]})
    data = json.dumps(flags, ensure_ascii=False, sort_keys=True, default=repr).encode("utf-8")
    return flags, ctx["life"].sidecar(data), fx["track_count"]


def track_armed(ctx: dict, index: int) -> str:
    flags, sha, declared = _walk(ctx)
    return _text({**track_armed_of(flags, declared, index), "walk_sha256": sha})


def armed_set(ctx: dict) -> str:
    flags, sha, declared = _walk(ctx)
    return _text({**armed_set_of(flags, declared), "walk_sha256": sha})


def mcu_upper_row(ctx: dict) -> str:
    session = ctx.get("session")
    if session is None:
        raise Unreadable(f"mcu_upper_row: no server is running to read {MCU_STATE}")
    try:
        text = session.read(MCU_STATE, READ_S)
    except Exception as exc:  # noqa: BLE001 - any failed read is this probe's unreadable
        raise Unreadable(f"mcu_upper_row: {exc}") from exc
    return _text(mcu_upper_row_of(text))


# ---------------------------------------------------------------------------------------------
# #291 routing pilot
# ---------------------------------------------------------------------------------------------

ROUTING_ROWS = {
    "stereo_output": ("Stereo Output", "strings:Logic"),
    "no_output": ("No Output", "strings:MAMixer"),
    "bus": ("Bus", "strings:Logic"),
    # The runtime physical pair is built from the Mixer's Output row. In German this is
    # `Ausgang`; Logic.framework's historical Output#mix row is `Output` and is not substituted.
    "physical_output": ("Output", "strings:MAMixer"),
}


def _routing_rows(lproj: str) -> dict:
    rows = {name: live_locale.apple_row(lproj, key, source=source)
            for name, (key, source) in ROUTING_ROWS.items()}
    unread = [name for name, row in rows.items() if not row.get("readable")]
    if unread:
        raise Unreadable(f"routing_slots: Apple's rows did not read: {', '.join(unread)}")
    return {name: row["value"] for name, row in rows.items()}


def _assignment(label: str, rows: dict) -> dict:
    if label == rows["stereo_output"]:
        return {"kind": "stereo_output"}
    if label == rows["no_output"]:
        return {"kind": "no_output"}
    bus = re.fullmatch(re.escape(rows["bus"]) + r"\s*([0-9]+)", label, re.IGNORECASE)
    if bus and int(bus.group(1)) > 0:
        return {"kind": "bus", "number": int(bus.group(1))}
    physical = re.fullmatch(
        re.escape(rows["physical_output"]) + r"\s*([0-9]+)\s*-\s*([0-9]+)",
        label, re.IGNORECASE)
    if physical:
        first, last = int(physical.group(1)), int(physical.group(2))
        if first > 0 and last > first:
            return {"kind": "physical", "ports": [first, last]}
    return {"kind": "unknown", "label": label}


def routing_slots_of(run: dict, rows: dict) -> dict:
    """The compact independent value acceptance rows consume from one routing_slots_ax walk."""
    observation = (run or {}).get("observation") or {}
    if not observation.get("readable") or not observation.get("mixer_found"):
        raise Unreadable("routing_slots: the Mixer was not read")
    failures = observation.get("read_failures")
    if failures != 0:
        raise Unreadable(f"routing_slots: the Mixer walk has {failures!r} read failure(s)")
    strips = observation.get("strips")
    if not isinstance(strips, list) or not strips:
        raise Unreadable("routing_slots: the Mixer walk has no strip list")
    outputs, send_counts, occupied = [], [], []
    for index, strip in enumerate(strips):
        if not isinstance(strip, dict):
            raise Unreadable(f"routing_slots: strip {index} is not an object")
        slots = strip.get("sends")
        if not isinstance(slots, list) or any(not isinstance(slot, dict)
                                               or not isinstance(slot.get("occupied"), bool)
                                               for slot in slots):
            raise Unreadable(f"routing_slots: strip {index}'s Send occupancy did not read")
        send_counts.append(len(slots))
        if any(slot["occupied"] for slot in slots):
            occupied.append(index)
        found = strip.get("outputs")
        if not isinstance(found, list) or len(found) > 1:
            raise Unreadable(f"routing_slots: strip {index} has no exact output-slot cardinality")
        if not found:
            outputs.append(None)
            continue
        label = found[0].get("description") if isinstance(found[0], dict) else None
        if not isinstance(label, str) or not label:
            raise Unreadable(f"routing_slots: strip {index}'s output description did not read")
        outputs.append(_assignment(label, rows))
    return {"strip_count": len(strips), "occupied_strips": occupied,
            "send_counts": send_counts, "outputs": outputs}


def routing_slots(ctx: dict) -> str:
    run = live_probes.run("routing_slots_ax", {"lproj": ctx["lproj"]})
    data = json.dumps(run, ensure_ascii=False, sort_keys=True, default=repr).encode("utf-8")
    return _text({**routing_slots_of(run, _routing_rows(ctx["lproj"])),
                  "walk_sha256": ctx["life"].sidecar(data)})


def routing_send_assign(ctx: dict, strip: int) -> str:
    fx = fixture.FIXTURES[ctx["decl"]["live"]]
    if strip != fx.get("input_strip"):
        raise Unreadable(f"routing_send_assign: strip {strip} is not the fixture's declared input strip")
    record = controls.select_send_bus(ctx["lproj"], strip)
    selected = record.get("selected")
    # AXPress may answer kAXErrorCannotComplete even though the menu/effect appears. The raw
    # statuses stay in the sidecar; the next independent routing_slots wait is effect authority.
    if not isinstance(selected, str) or not selected or record.get("cause") is not None:
        raise Unreadable(f"routing_send_assign: the Send was not selected: {record.get('cause') or record!r}")
    data = json.dumps(record, ensure_ascii=False, sort_keys=True, default=repr).encode("utf-8")
    return _text({"strip": strip, "selected": selected,
                  "record_sha256": ctx["life"].sidecar(data)})
