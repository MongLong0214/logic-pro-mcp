"""The probe registry: named, independent readers of Logic, each with a positive control.

A probe is:
  name              the registry key;
  schema            its arguments, {name: {"type", "required", "doc"}};
  command           a Python function over the arguments that returns RAW output (here, an AX walk
                    this process makes itself -- never the product's reply);
  parse             raw -> a JSON observation that keeps the raw output under "raw";
  positive_control  a fixture state in which the probe must report a known reading: the fixture's
                    name, the state it must be in, and `known(fixture_spec, observation)`, the
                    predicate a self-test drives live.

Only what the two pilots need is registered:

  track_flags_ax    #1020. Every arrange track header's record-enable, mute and solo checkbox and
                    its AXValue, read from Logic's AX tree. The controls are located by Apple's rows
                    `Record Enable`, `Mute` and `Solo` of Logic.framework Localizable.strings, via
                    `locale.apple_row`, never by the product's AXLocalePolicy: German's track-header
                    Mute is `Stumm`, the plain `Mute` row, where the `Mute#acc` row the policy is
                    derived from says `Ton aus` (ADR-027, Context). The header rail is found by
                    structure (an element whose AXLayoutItem children each carry a record-enable
                    checkbox), as AXLogicProElements+Tracks.swift:56-66 describes it, not by its
                    localized description. Measured 2026-09-27 (ko): the rail is an AXGroup of 19
                    AXLayoutItems, each with AXCheckBox children in the order mute, solo, record
                    enable, input monitoring, and an AXTextField holding the track name.
  routing_slots_ax  #291. The Mixer witness ported from f291r1:Scripts/livekit/live_291_endpoints_
                    and_send_slots_in_every_locale.py (the harness scratchpad/live291.sh drives, at
                    3063d87b): `ax_tree` (:243-325), `witness_of` (:328-350), `strip_witness`
                    (:353-403), `contains_any` (:217-220). Its labels came from AXLocalePolicy
                    (E.label_set); here they are Apple's QuickHelp Title rows INS_014_OutputSlot,
                    INS_012_InputSlot, INS_010_SendSlot and INS_011_SendLevelKnob, the rows those
                    label sets name as their `derivedFrom` on that branch.

Walks are bounded twice: by depth, and by the AX messaging timeout `cfbridge.AX` sets.
"""

from . import cfbridge, obs, screen
from . import locale as live_locale

AX_LAYOUT_ITEM = "AXLayoutItem"
AX_CHECK_BOX = "AXCheckBox"
AX_BUTTON = "AXButton"
AX_SLIDER = "AXSlider"
AX_GROUP = "AXGroup"
AX_TEXT_FIELD = "AXTextField"

TRACK_WALK_DEPTH = 14
MIXER_WALK_DEPTH = 20  # f291r1 live_291:165 WITNESS_DEPTH

FLAG_ROWS = {"arm": "Record Enable", "mute": "Mute", "solo": "Solo"}
SLOT_ROWS = {"output": "INS_014_OutputSlot", "input": "INS_012_InputSlot",
             "send": "INS_010_SendSlot", "send_knob": "INS_011_SendLevelKnob"}


# ---------------------------------------------------------------------------------------------
# the walk (f291r1 live_291:243-325, generalised: which windows, which values)
# ---------------------------------------------------------------------------------------------

def ax_walk(pid, max_depth, window_title=None, valued=lambda node: False,
            attributes=("AXRole", "AXHelp", "AXDescription")):
    """Every element under Logic's AXWindows to `max_depth`, pre-order, raw.

    Each node keeps its path (window index, then child indices), depth and the text attributes
    asked for. A read that failed with a status that is not an answer (-25205/-25212 are answers)
    is kept in the node's `read_errors`; a children read that failed is listed in
    `children_read_failures`: an unread subtree is unknown, not empty. `valued(node)` selects the
    nodes whose AXValue is read too (`value`, or `value_error`).
    """
    try:
        ax = cfbridge.AX(pid)
    except Exception as exc:  # noqa: BLE001
        return obs.unreadable(f"AX session: {exc!r}", pid=pid)
    nodes, failures, windows_seen = [], [], []
    try:
        listed = ax.elements(ax.app, "AXWindows") if ax.app else {"status": None, "elements": None}
        if listed["elements"] is None:
            return obs.unreadable("AXWindows", status=listed["status"], pid=pid)

        def walk(element, depth, path):
            node = {"path": path, "depth": depth, "read_errors": []}
            for name in attributes:
                text, error = cfbridge.text_of(ax.value(element, name))
                node[name] = text
                if error is not None:
                    node["read_errors"].append(f"{name}:{error}")
            if valued(node):
                read = ax.value(element, "AXValue")
                if read["status"] == 0:
                    node["value"] = read["value"]
                else:
                    node["value"] = None
                    node["value_error"] = read["status"]
            nodes.append(node)
            if depth >= max_depth:
                return
            kids = ax.elements(element, "AXChildren")
            if kids["elements"] is None:
                if kids["status"] not in cfbridge.AX_ANSWERS:
                    failures.append({"path": path, "status": kids["status"]})
                return
            for index, kid in enumerate(kids["elements"]):
                walk(kid, depth + 1, path + [index])

        for index, window in enumerate(listed["elements"]):
            title, _ = cfbridge.text_of(ax.value(window, "AXTitle"))
            windows_seen.append({"index": index, "title": title})
            if window_title is not None and title != window_title:
                continue
            walk(window, 0, [index])
        return obs.readable({"nodes": nodes, "children_read_failures": failures},
                            pid=pid, windows=windows_seen, window_title=window_title,
                            max_depth=max_depth, messaging_timeout_status=ax.timeout_status)
    finally:
        ax.close()


def _single_logic_pid(pid):
    if pid is not None:
        return obs.readable(pid)
    pids = screen.logic_pids()
    if not pids["readable"]:
        return pids
    if len(pids["value"]) != 1:
        return obs.unreadable("not exactly one Logic process", pids=pids["value"])
    return obs.readable(pids["value"][0])


def _labels(lproj, rows, **kwargs):
    """{name: apple_row(...)} and, when every row resolved, {name: value}."""
    resolved = {name: live_locale.apple_row(lproj, key, **kwargs) for name, key in rows.items()}
    values = {name: r["value"] for name, r in resolved.items() if r["readable"]}
    return resolved, (values if len(values) == len(rows) else None)


# ---------------------------------------------------------------------------------------------
# track_flags_ax (#1020)
# ---------------------------------------------------------------------------------------------

def track_flags_command(args):
    lproj = args["lproj"]
    rows, labels = _labels(lproj, FLAG_ROWS)
    title = live_locale.expected_title(lproj, args.get("fixture") or live_locale.FIXTURE)
    if labels is None or not title["readable"]:
        return {"rows": rows, "title": title, "walk": None,
                "cause": "Apple's rows or the arrange title did not resolve"}
    pid = _single_logic_pid(args.get("pid"))
    if not pid["readable"]:
        return {"rows": rows, "title": title, "walk": None, "pid": pid}
    wanted = set(labels.values())
    walk = ax_walk(pid["value"], TRACK_WALK_DEPTH, window_title=title["value"],
                   valued=lambda n: n.get("AXRole") in (AX_CHECK_BOX, AX_TEXT_FIELD)
                   and (n.get("AXRole") == AX_TEXT_FIELD or n.get("AXDescription") in wanted),
                   attributes=("AXRole", "AXDescription"))
    return {"rows": rows, "labels": labels, "title": title, "pid": pid["value"], "walk": walk}


def track_flags_parse(raw):
    """Per track, in the rail's order: name, and each flag's AXValue with how many matched."""
    labels, walk = raw.get("labels"), raw.get("walk")
    if not labels or not walk or not walk.get("readable"):
        return {"readable": False, "cause": raw.get("cause") or (walk or {}).get("cause")
                or "no walk", "raw": raw}
    nodes = walk["value"]["nodes"]
    by_label = {value: name for name, value in labels.items()}
    children = {}
    for node in nodes:
        children.setdefault(tuple(node["path"][:-1]), []).append(node)
    rails = []
    for parent, kids in children.items():
        items = [k for k in kids if k.get("AXRole") == AX_LAYOUT_ITEM]
        if not items:
            continue
        armed_items = [k for k in items if any(
            c.get("AXRole") == AX_CHECK_BOX and c.get("AXDescription") == labels["arm"]
            for c in children.get(tuple(k["path"]), []))]
        if armed_items:
            rails.append({"path": list(parent), "items": len(items), "items_with_arm": len(armed_items)})
    rails.sort(key=lambda r: -r["items_with_arm"])
    if not rails:
        return {"readable": False, "cause": "no element's layout items carry a record-enable "
                "checkbox named by Apple's row", "rails": rails, "raw": raw}
    top = [r for r in rails if r["items_with_arm"] == rails[0]["items_with_arm"]]
    if len(top) != 1:
        return {"readable": False, "cause": "ambiguous track header rails: multiple candidates "
                "have the same highest record-enable count", "rails": rails, "raw": raw}
    rail = tuple(rails[0]["path"])
    tracks = []
    for position, item in enumerate(k for k in children.get(rail, [])
                                    if k.get("AXRole") == AX_LAYOUT_ITEM):
        row = {"index": position, "path": item["path"], "description": item.get("AXDescription"),
               "name": None, "arm": None, "mute": None, "solo": None,
               "matches": {"arm": 0, "mute": 0, "solo": 0}, "value_errors": {}}
        for child in children.get(tuple(item["path"]), []):
            if child.get("AXRole") == AX_TEXT_FIELD and row["name"] is None:
                row["name"] = child.get("value") if isinstance(child.get("value"), str) \
                    else child.get("AXDescription")
            flag = by_label.get(child.get("AXDescription")) if child.get("AXRole") == AX_CHECK_BOX else None
            if flag is None:
                continue
            row["matches"][flag] += 1
            if "value_error" in child:
                row["value_errors"][flag] = child["value_error"]
            elif row["matches"][flag] == 1:
                row[flag] = child.get("value")
        tracks.append(row)
    return {"readable": True, "rail": list(rail), "rails": rails, "track_count": len(tracks),
            "tracks": tracks,
            "children_read_failures": walk["value"]["children_read_failures"], "raw": raw}


FLAGS = ("arm", "mute", "solo")
#: The order the positive control sets them in, each alone (logic_tracks commands).
FLAG_COMMANDS = ("mute", "solo", "arm")


def flags_show(spec, run, flag=None):
    """True when `run` reads the fixture's tracks (count, names, every flag found once, no child
    failure) with `flag` set on spec["flag_track"] and nothing else set; `flag=None`: nothing set.

    Soloing a track makes Logic draw other tracks' Mute as -1 (the solo-implied mute), not all at
    once and not at once: in verify-live-selftest/c07f3f1c (2026-09-27) the reading right after
    Solo had none, and one taken seconds later had 4 of 18 (ko) and 18 of 18 (de); none after
    Solo was unset. So while `flag` is solo, 0 or -1 is accepted for another track's mute, and
    only there."""
    observation = (run or {}).get("observation") or {}
    if not observation.get("readable") or observation["children_read_failures"]:
        return False
    tracks, target = observation["tracks"], spec["flag_track"]
    if (observation["track_count"] != spec["track_count"]
            or [t["name"] for t in tracks] != spec["names"]
            or not all(t["matches"] == {"arm": 1, "mute": 1, "solo": 1} for t in tracks)):
        return False
    for track in tracks:
        for name in FLAGS:
            want = 1 if (name == flag and track["index"] == target) else 0
            implied = flag == "solo" and name == "mute" and track["index"] != target
            if track[name] != want and not (implied and track[name] == -1):
                return False
    return True


def track_flags_known(spec, control):
    """The positive control (controls.track_flags_control): before, every track found and at 0;
    then for Mute, Solo and Record Enable in turn, the fixture's flag_track with that flag alone set
    and no other track changed, then every track at 0 again. A probe returning zeros or nothing
    fails it at the first set."""
    cycles = control.get("cycles") or []
    return (flags_show(spec, control.get("pre"))
            and [c.get("flag") for c in cycles] == list(FLAG_COMMANDS)
            and all(flags_show(spec, c.get("post"), c["flag"])
                    and flags_show(spec, c.get("after")) for c in cycles))


# ---------------------------------------------------------------------------------------------
# routing_slots_ax (#291)
# ---------------------------------------------------------------------------------------------

def contains_any(text, members):
    """The product's `containsAny`: any member inside `text`, case folded (f291r1 live_291:217)."""
    folded = (text or "").casefold()
    return any(member and member.casefold() in folded for member in members or [])


def routing_slots_command(args):
    lproj = args["lproj"]
    rows, labels = _labels(lproj, SLOT_ROWS, source="quickhelp", field="Title")
    if labels is None:
        return {"rows": rows, "walk": None, "cause": "Apple's QuickHelp rows did not resolve"}
    pid = _single_logic_pid(args.get("pid"))
    if not pid["readable"]:
        return {"rows": rows, "walk": None, "pid": pid}
    walk = ax_walk(pid["value"], MIXER_WALK_DEPTH)
    return {"rows": rows, "labels": labels, "pid": pid["value"], "walk": walk}


def _strip_witness(nodes, start, labels):
    """One strip's slots and knobs, from its contiguous pre-order run (f291r1 live_291:353-403)."""
    path = nodes[start]["path"]
    depth = len(path)
    sub, cursor = [], start + 1
    while cursor < len(nodes) and nodes[cursor]["path"][:depth] == path:
        sub.append((cursor, nodes[cursor]))
        cursor += 1
    by_path = {tuple(node["path"]): (global_index, node) for global_index, node in sub}

    def is_knob(node):
        return (node is not None and node["AXRole"] == AX_SLIDER
                and contains_any(node["AXHelp"], [labels["send_knob"]]))

    outputs, inputs, sends = [], [], []
    knobs, attributed = 0, set()
    for position, (global_index, node) in enumerate(sub):
        is_button = node["AXRole"] == AX_BUTTON
        if is_button and contains_any(node["AXHelp"], [labels["output"]]):
            outputs.append({"description": node["AXDescription"], "help": node["AXHelp"],
                            "global_index": global_index})
        if is_button and contains_any(node["AXHelp"], [labels["input"]]):
            inputs.append({"description": node["AXDescription"], "global_index": global_index,
                           "path": node["path"]})
        if is_knob(node):
            knobs += 1
        if is_button and contains_any(node["AXHelp"], [labels["send"]]):
            following = sub[position + 1] if position + 1 < len(sub) else None
            occupied = following is not None and is_knob(following[1])
            if occupied:
                attributed.add(following[0])
            sends.append({"shape": "button", "occupied": occupied,
                          "description": node["AXDescription"], "help": node["AXHelp"],
                          "global_index": global_index, "path": node["path"]})
        elif node["AXRole"] == AX_GROUP:
            sibling = by_path.get(tuple(node["path"][:-1] + [node["path"][-1] + 1]))
            if sibling is not None and is_knob(sibling[1]):
                attributed.add(sibling[0])
                sends.append({"shape": "group", "occupied": True,
                              "description": node["AXDescription"], "help": node["AXHelp"],
                              "global_index": global_index, "path": node["path"]})
    return {"path": path, "description": nodes[start].get("AXDescription"), "outputs": outputs,
            "inputs": inputs, "sends": sends, "knobs": knobs, "knobs_attributed": len(attributed),
            "read_errors": sum(len(node["read_errors"]) for _, node in sub)}


def routing_slots_parse(raw):
    """The Mixer's strips as the witness reads them (f291r1 live_291:328-350).

    Ported with one addition: the container chosen is the one with the most AXLayoutItem children
    AMONG those whose items carry an output slot. The port's "most AXLayoutItem children" alone picks
    the 19-item track-header rail when the Mixer is hidden, and would report a Mixer that is not
    there (every container is still listed).
    """
    labels, walk = raw.get("labels"), raw.get("walk")
    if not labels or not walk or not walk.get("readable"):
        return {"readable": False, "cause": raw.get("cause") or (walk or {}).get("cause")
                or "no walk", "raw": raw}
    tree = walk["value"]
    nodes = tree["nodes"]
    by_parent = {}
    for index, node in enumerate(nodes):
        if node["AXRole"] == AX_LAYOUT_ITEM:
            by_parent.setdefault(tuple(node["path"][:-1]), []).append(index)
    containers = []
    for parent, items in by_parent.items():
        strips = [_strip_witness(nodes, start, labels) for start in items]
        containers.append({"path": list(parent), "items": len(items),
                           "items_with_output": sum(1 for s in strips if s["outputs"]),
                           "strips": strips})
    containers.sort(key=lambda c: (-c["items_with_output"], -c["items"]))
    summary = [{k: c[k] for k in ("path", "items", "items_with_output")} for c in containers]
    if not containers or not containers[0]["items_with_output"]:
        return {"readable": True, "mixer_found": False, "containers": summary, "strips": [],
                "raw": raw}
    mixer = containers[0]
    prefix = mixer["path"]
    failures = [f for f in tree["children_read_failures"]
                if f.get("path", [])[:len(prefix)] == prefix or not f.get("path")]
    return {"readable": True, "mixer_found": True, "mixer_path": prefix, "containers": summary,
            "strips": mixer["strips"],
            "read_failures": len(failures) + sum(s["read_errors"] for s in mixer["strips"]),
            "raw": raw}


def _mixer(run):
    observation = (run or {}).get("observation") or {}
    if not (observation.get("readable") and observation.get("mixer_found")):
        return None
    return observation


def routing_slots_known(spec, control):
    """The positive control (controls.routing_slots_control): on the reset fixture the Mixer has
    the declared strips, track_count of them with one output, exactly one strip with an input --
    the fixture's input_strip, reading Apple's `Input` row + " 1" -- and no occupied send; after a
    bus is chosen in that strip's send slot, that strip and only it has an occupied send; after the
    reset, none has. A probe returning no inputs or no occupied send fails it."""
    label = control.get("input_label") or {}
    readings = [_mixer(control.get(k)) for k in ("pre", "post", "after")]
    if not label.get("readable") or any(r is None for r in readings):
        return False
    pre, post, after = readings
    strip = spec["input_strip"]

    def occupied(reading):
        return [i for i, s in enumerate(reading["strips"]) if any(x["occupied"] for x in s["sends"])]

    inputs = [(i, [x["description"] for x in s["inputs"]])
              for i, s in enumerate(pre["strips"]) if s["inputs"]]
    return (len(pre["strips"]) == spec["mixer_strips"]
            and sum(1 for s in pre["strips"] if len(s["outputs"]) == 1) == spec["track_count"]
            and inputs == [(strip, [label["value"]])]
            and occupied(pre) == [] and occupied(post) == [strip] and occupied(after) == []
            and len(after["strips"]) == spec["mixer_strips"]
            and all(r["read_failures"] == 0 for r in readings))


# ---------------------------------------------------------------------------------------------
# the registry
# ---------------------------------------------------------------------------------------------

REGISTRY = {
    "track_flags_ax": {
        "name": "track_flags_ax",
        "schema": {"lproj": {"type": "str", "required": True, "doc": "one of locale.LOCALES"},
                   "fixture": {"type": "str", "required": False, "doc": "fixture path (title)"},
                   "pid": {"type": "int", "required": False, "doc": "Logic pid; else pgrep"}},
        "command": track_flags_command,
        "parse": track_flags_parse,
        "positive_control": {"fixture": "locale_campaign_19", "state": "reset, then changed",
                             "known": track_flags_known,
                             "reading": "every track found with each checkbox once; all 0, then "
                                        "flag_track alone 1/1/1 after the product sets it, then "
                                        "all 0 after it unsets it (controls.py)"},
        "pilot": "#1020",
    },
    "routing_slots_ax": {
        "name": "routing_slots_ax",
        "schema": {"lproj": {"type": "str", "required": True, "doc": "one of locale.LOCALES"},
                   "pid": {"type": "int", "required": False, "doc": "Logic pid; else pgrep"}},
        "command": routing_slots_command,
        "parse": routing_slots_parse,
        "positive_control": {"fixture": "locale_campaign_mixer", "state": "reset, then changed",
                             "known": routing_slots_known,
                             "reading": "the declared strips; input_strip alone with an input, "
                                        "reading Apple's Input row + ' 1'; no occupied send, then "
                                        "input_strip alone occupied after a bus is chosen in its "
                                        "send slot, then none after the reset (controls.py)"},
        "pilot": "#291",
    },
}


def validate(name, args):
    """Arguments against the probe's schema; a list of problems (empty is valid)."""
    probe = REGISTRY.get(name)
    if probe is None:
        return [f"no probe named {name!r}"]
    problems = []
    kinds = {"str": str, "int": int}
    for arg, rule in probe["schema"].items():
        if arg not in args:
            if rule["required"]:
                problems.append(f"missing {arg}")
            continue
        if args[arg] is not None and not isinstance(args[arg], kinds[rule["type"]]):
            problems.append(f"{arg} is not {rule['type']}")
    problems += [f"unknown argument {arg}" for arg in args if arg not in probe["schema"]]
    if "lproj" in args and args["lproj"] not in live_locale.LOCALES:
        problems.append("lproj is not one of the ten")
    return problems


def run(name, args):
    """Run one probe: {"probe", "args", "t", "elapsed_s", "observation"} (raw inside)."""
    problems = validate(name, args)
    started = obs.now()
    if problems:
        return {"probe": name, "args": args, "t": started, "refused": problems}
    probe = REGISTRY[name]
    raw = probe["command"](args)
    return {"probe": name, "args": args, "t": started, "elapsed_s": obs.now() - started,
            "observation": probe["parse"](raw)}
