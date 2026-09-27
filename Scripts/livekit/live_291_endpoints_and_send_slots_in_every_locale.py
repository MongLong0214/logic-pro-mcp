#!/usr/bin/env python3
"""Live proof that the mixer's typed endpoints and send-slot occupancy hold in every Logic language (#291 R1).

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        /usr/bin/python3 live_291_endpoints_and_send_slots_in_every_locale.py \
        [--worktree <path>] [--head <full-40-char-sha>] [--binary <LogicProMCP>] \
        [--locale <lproj>]... [--switch] [--record-seconds N]
        /usr/bin/python3 live_291_endpoints_and_send_slots_in_every_locale.py --self-test

`--locale` repeats; with none, every lproj in LOCALES is asked for. WITHOUT `--switch` nothing
changes Logic's language: a requested locale runs only when Logic is already in it on the
locale-campaign fixture (the AppleLanguages setting and the arrange window's title, whose suffix is
Apple's own `Tracks` row), and every other requested locale is recorded as NOT RUN, which fails the
run. The intended use is one locale per invocation after the caller has switched. `--switch` quits,
switches and relaunches Logic per locale the way live_993 does, and puts the starting language back.

`--self-test` runs offline: every predicate below against a positive fixture and against the
counterexample its builder derives from that fixture. It exits non-zero if any predicate rejects
its positive fixture or accepts its counterexample.

WHAT IS MEASURED, PER LOCALE
----------------------------
One server on the fixture. The Mixer is shown with X (the same key in every language) only when the
product's own read is not fresh, and put back afterwards. Three instruments are read side by side:

  the product   logic://tracks (trackIndex -> trk_), logic://mixer (strips[].output,
                strips[].send_slots, routing_graph) and logic_project.inspect_session with the
                routing domain requested
  the witness   an independent Accessibility walk of Logic's windows in this process (evidence.py's
                ctypes bridge), grouped into the Mixer's strips by AXLayoutItem. Slots are matched by
                the same `AXLocalePolicy` label sets the product carries (E.label_set), and nothing
                else: help contains the output / send slot set; a send slot is OCCUPIED when the
                element after its button in pre-order is an AXSlider whose help contains the send
                level knob set. The walk goes deeper than the product's (20 levels, not 4 below the
                strip), and its read failures inside the Mixer are counted: a witness that could
                not read is not a witness of absence.
  the actuator  Scripts/livekit/ax_routing_slot_menu_probe.swift, compiled once: it presses a slot
                chosen by help prefix and index, lists the enabled titles of the menu that opens,
                selects one BY TITLE (AXPress on the menu item, no coordinates), Escapes, and runs
                its own positive control (a track Mute pressed and pressed back). The help prefix
                passed is the help string the witness read off that very button, and the index is
                that button's position in the probe's own sweep order, computed from the same walk.

Mutations, each undone through Logic's Edit menu (Apple's per-language `Edit#mti` row, menu item 1)
and verified by re-reading both the product and the witness:

  send     a bus is selected in send slot 0 of one audio strip (an input slot that is not a bus,
           an output classified physical, a trk_ reference, and slot 0 empty to both instruments)
  output   the same bus is selected in that strip's output menu

The bus is a title in the opened menu that `busOutputLabelPrefix` + a number classifies; one some
strip's input already reads is preferred, so no aux strip has to be created by the assignment.

THE TEN CHECKS (tag `291e/<lproj>/<check>`), EACH ev.falsifiable WITH A DERIVED COUNTEREXAMPLE
----------------------------------------------------------------------------------------------
  output_readable_per_strip                    every witnessed output slot is published verbatim
      as strips[i].output, and every strip with an issued trk_ carries an output_classification.
      Counterexample: {output: null, output_classification: null} on a witnessed slot -- main at
      d1f3b810 in eight locales.
  send_slot_count_matches_witness              len(send_slots) == witnessed send-slot buttons on
      every strip, in every reading. Counterexample: send_slots absent (main has no such key).
  occupancy_matches_knob_witness               occupied_* exactly where the witness sees the knob
      follow the button, and every witnessed knob is right after a send button; at least one knob
      must have been seen in the run. Counterexample: {state: observed_empty, level_raw: -inf,
      knob_witnessed: true} -- occupancy derived from level.
  send_assignment_then_undo                    slot 0 goes observed_empty -> occupied_unknown_destination
      on the target alone, both instruments agree, no send edge is published, and the undo gives
      back every strip's states. Counterexample: the knob witnessed and the slot still empty.
  bus_output_then_undo                         the output classifies bus, a bus_<n> node and a
      mainOutput edge from the strip's trk_ appear, no edge ends at a track, and the undo removes
      the edge and gives the output back. Counterexample: {edges: [], output: 'Bus 3'} -- the
      2026-09-27 records.
  snapshot_id_parity                           inspect_session's snapshot_id and routing.snapshot_id
      equal a logic://mixer routing_graph.snapshot_id bracketed by two equal mixer reads, and its
      routing.graph equals the mixer graph's coverage. Counterexample: a report from another capture.
  coverage_never_complete_with_filters_unread  while inspect_session names mixer_filters_unread the
      graph is not complete, population is not complete, and the routing section is not complete.
      Counterexample: population complete with filters unread.
  positive_control_mute                        every probe run moved its Mute and moved it back.
      Counterexample: `control mute moved: 0`.
  menus_closed_and_modal_clean                 after every probe run and every undo no Logic menu is
      on screen (CoreGraphics, pop-up menu level and above) and blocking_modal() is clear.
      Counterexample: a menu left at layer 101 (2026-09-26 zh_TW).
  restored                                     each mutation changed the signature (product and
      witness), and the undo put it back exactly. Counterexample: an undo that changed nothing.

WHAT IS NOT JUDGED
------------------
Which destination a send goes to: the source slot does not say (2026-09-13), so no send edge is
expected and occupied_known_destination is never expected. Bus-to-aux input edges (not observed in
R1). Whether the strip is the track it is positioned against: association is positional and the
graph says so. U1-U8 of the plan are RECORDED under `291e/<lproj>/summary`, not asserted: the
output descriptions per classification (U2), the knob's AXValue and AXValueDescription (U4), knobs
not preceded by a send button (U3), strips with no output slot (U8).
"""

import argparse
import copy
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import evidence as E  # noqa: E402

COVERS = [
    "Sources/LogicProMCP/Accessibility/AXLogicProElements+Mixer.swift",
    "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift",
    "Sources/LogicProMCP/Routing/RoutingGraph.swift",
    "Sources/LogicProMCP/Routing/RoutingGraphPublication.swift",
    "Sources/LogicProMCP/Resources/ResourceHandlers+StateReaders.swift",
    "Sources/LogicProMCP/Workflows/SessionPopulationObservation.swift",
]

#: (bundle lproj, AppleLanguages code). The lproj names are the ten Logic ships.
LOCALES = [("en", "en"), ("ko", "ko"), ("ja", "ja"), ("de", "de"), ("es", "es"), ("fr", "fr"),
           ("it", "it"), ("pt", "pt-BR"), ("zh_CN", "zh-CN"), ("zh_TW", "zh-TW")]
CODES = dict(LOCALES)
APP = "/Applications/Logic Pro.app"
STRINGS = (APP + "/Contents/Frameworks/Logic.framework/Versions/A/Resources/%s.lproj/"
           "Localizable.strings")
FIXTURE = os.path.expanduser("~/Music/Logic/lpm-locale-campaign.logicx")
FIXTURE_NAME = os.path.splitext(os.path.basename(FIXTURE))[0]
PROBE_SOURCE = os.path.join(HERE, "ax_routing_slot_menu_probe.swift")
TAG = "291e"
READ_TIMEOUT = 20.0
LAUNCH_TIMEOUT = 150.0
#: ax_routing_slot_menu_probe.swift's sweep(): `if depth > 13 { return }` from each window.
PROBE_DEPTH = 13
#: The witness walks deeper than both the product (4 below a strip) and the probe.
WITNESS_DEPTH = 20
SNAPSHOT_ATTEMPTS = 5

# The product's own wire tokens (RoutingGraph.swift, StateModels.swift,
# SessionPopulationObservation.swift, ResourceHandlers.mixerDataSource). None is a Logic UI label;
# they are named here so no comparison below spells one inline.
FRESH = "ax_poll"
KIND_BUS = "bus"
EDGE_MAIN_OUTPUT = "mainOutput"
EDGE_SEND = "send"
CLASS_BUS = "bus"
CLASS_PHYSICAL = "physical_output"
OUTPUT_CLASSES = ("physical_output", "bus", "no_output", "unclassified")
SLOT_EMPTY = "observed_empty"
SLOT_OCCUPIED_UNKNOWN = "occupied_unknown_destination"
SLOT_OCCUPIED_KNOWN = "occupied_known_destination"
SLOT_READ_STATES = (SLOT_EMPTY, SLOT_OCCUPIED_UNKNOWN, SLOT_OCCUPIED_KNOWN)
OCCUPIED = (SLOT_OCCUPIED_UNKNOWN, SLOT_OCCUPIED_KNOWN)
COMPLETE = "complete"
COVERAGE_STATES = ("complete", "partial", "unavailable", "unstable", "not_observed")
DOMAINS = ("population", "strip_track_association", "main_output", "physical_output",
           "bus_to_aux_input", "sends")
FILTERS_UNREAD = "mixer_filters_unread"
SNAPSHOT_PREFIX = "snap_"
BUS_NODE_PREFIX = "bus_"
TRACK_REF_PREFIX = "trk_"
# Accessibility role constants, not Logic labels.
AX_BUTTON = "AXButton"
AX_SLIDER = "AXSlider"
AX_LAYOUT_ITEM = "AXLayoutItem"

#: The AXLocalePolicy LabelSets this harness reads. The product carries every member; nothing here
#: spells one.
LABEL_SETS = ("outputSlotHelpKeyword", "inputSlotHelpKeyword", "sendSlotHelpKeyword",
              "sendLevelKnobHelpKeyword", "busOutputLabelPrefix", "trackMuteButton", "editMenuBar")

CHECKS = ("output_readable_per_strip", "send_slot_count_matches_witness",
          "occupancy_matches_knob_witness", "send_assignment_then_undo", "bus_output_then_undo",
          "snapshot_id_parity", "coverage_never_complete_with_filters_unread",
          "positive_control_mute", "menus_closed_and_modal_clean", "restored")


# ---------------------------------------------------------------------------------------------
# Label matching (members from E.label_set only)
# ---------------------------------------------------------------------------------------------

def contains_any(text, members):
    """The product's `containsAny`: any member inside `text`, case folded."""
    folded = (text or "").casefold()
    return any(member and member.casefold() in folded for member in members or [])


def bus_number(label, members):
    """The number after a bus-prefix member, or None: `<member>` + optional spaces + digits, whole."""
    text = (label or "").strip()
    for member in members or []:
        match = re.match(re.escape(member) + r"\s*([0-9]+)$", text, re.IGNORECASE)
        if match and int(match.group(1)) > 0:
            return int(match.group(1))
    return None


# ---------------------------------------------------------------------------------------------
# The witness: an Accessibility walk this process makes itself
# ---------------------------------------------------------------------------------------------

def logic_pid():
    found = subprocess.run(["/usr/bin/pgrep", "-x", "Logic Pro"], capture_output=True, text=True)
    pids = [int(p) for p in (found.stdout or "").split() if p.isdigit()]
    return pids[0] if len(pids) == 1 else None


def ax_tree(pid, max_depth=WITNESS_DEPTH):
    """Every element under Logic's AXWindows to `max_depth`, pre-order, as the probe's sweep() walks.

    Each node keeps its path (window index, then child indices), depth, role, help and description.
    A read that failed with a status that is not an answer (-25205 / -25212 are answers) is counted
    at the node, and a children read that failed is listed: an unread subtree is unknown.
    """
    ax = E._AXRuntime()
    nodes, failures = [], []

    def answered_absent(exc):
        # -25205 / -25212 are answers; so is a successful read with no payload (status None).
        if exc.status is None:
            return str(exc.site).endswith("successful but empty payload")
        return ax.definitive_absence(exc.status)

    def text(element, name):
        try:
            return ax.text(ax.attribute(element, name, name), name), None
        except E._ModalReadError as exc:
            if answered_absent(exc):
                return "", None
            return "", f"{name}:{exc.status if exc.status is not None else exc.site}"

    def walk(element, depth, path):
        if depth > max_depth:
            return
        role, e1 = text(element, "AXRole")
        help_text, e2 = text(element, "AXHelp")
        description, e3 = text(element, "AXDescription")
        nodes.append({"path": path, "depth": depth, "role": role, "help": help_text,
                      "description": description, "read_errors": [e for e in (e1, e2, e3) if e]})
        try:
            kids = ax.elements(ax.attribute(element, "AXChildren", "AXChildren"), "AXChildren")
        except E._ModalReadError as exc:
            if not answered_absent(exc):
                failures.append({"path": path, "status": exc.status, "site": str(exc.site)})
            kids = []
        for index, kid in enumerate(kids):
            walk(kid, depth + 1, path + [index])

    try:
        application = ax.application(pid)
        windows = ax.elements(ax.attribute(application, "AXWindows", "AXWindows"), "AXWindows")
        for index, window in enumerate(windows):
            walk(window, 0, [index])
    except E._ModalReadError as exc:
        failures.append({"path": [], "status": exc.status, "site": exc.site})
    finally:
        ax.close()
    return {"nodes": nodes, "children_read_failures": failures}


def witness_of(tree, labels):
    """The Mixer's strips as the witness reads them, from one `ax_tree` walk.

    The Mixer is the container with the most AXLayoutItem children (the Inspector's area has two);
    every container that has any is listed so a reader can see the choice.
    """
    nodes = tree.get("nodes") or []
    by_parent = {}
    for index, node in enumerate(nodes):
        if node["role"] == AX_LAYOUT_ITEM:
            by_parent.setdefault(tuple(node["path"][:-1]), []).append(index)
    containers = sorted(((list(parent), len(items)) for parent, items in by_parent.items()),
                        key=lambda row: -row[1])
    if not by_parent:
        return {"mixer_found": False, "containers": [], "strips": [], "read_failures": None}
    parent, items = max(by_parent.items(), key=lambda row: len(row[1]))
    prefix = list(parent)
    failures = [f for f in tree.get("children_read_failures") or []
                if f.get("path", [])[:len(prefix)] == prefix or not f.get("path")]
    strips = [strip_witness(nodes, start, labels) for start in items]
    read_failures = len(failures) + sum(strip["read_errors"] for strip in strips)
    return {"mixer_found": True, "mixer_path": prefix, "containers": containers,
            "strips": strips, "read_failures": read_failures}


def strip_witness(nodes, start, labels):
    """One strip's slots, knobs and the order they come in, from its contiguous pre-order run."""
    path = nodes[start]["path"]
    depth = len(path)
    sub = []
    cursor = start + 1
    while cursor < len(nodes) and nodes[cursor]["path"][:depth] == path:
        sub.append((cursor, nodes[cursor]))
        cursor += 1
    outputs, inputs, sends = [], [], []
    knobs, knobs_after_a_send_button = 0, 0
    for position, (global_index, node) in enumerate(sub):
        is_button = node["role"] == AX_BUTTON
        if is_button and contains_any(node["help"], labels["outputSlotHelpKeyword"]):
            outputs.append({"description": node["description"], "help": node["help"],
                            "global_index": global_index})
        if is_button and contains_any(node["help"], labels["inputSlotHelpKeyword"]):
            inputs.append({"description": node["description"], "global_index": global_index})
        if node["role"] == AX_SLIDER and contains_any(node["help"], labels["sendLevelKnobHelpKeyword"]):
            knobs += 1
            before = sub[position - 1][1] if position > 0 else None
            if before is not None and before["role"] == AX_BUTTON \
                    and contains_any(before["help"], labels["sendSlotHelpKeyword"]):
                knobs_after_a_send_button += 1
        if is_button and contains_any(node["help"], labels["sendSlotHelpKeyword"]):
            following = sub[position + 1][1] if position + 1 < len(sub) else None
            sends.append({"knob_follows": bool(
                following is not None and following["role"] == AX_SLIDER
                and contains_any(following["help"], labels["sendLevelKnobHelpKeyword"])),
                "help": node["help"], "global_index": global_index})
    return {"path": path, "outputs": outputs, "inputs": inputs, "sends": sends, "knobs": knobs,
            "knobs_after_a_send_button": knobs_after_a_send_button,
            "read_errors": sum(len(node["read_errors"]) for _, node in sub)}


def probe_slot_index(nodes, global_index, prefix):
    """The `--slot-index` the probe needs to reach nodes[global_index] with `--slot-prefix prefix`.

    The probe filters its own sweep (every window, pre-order, depth <= 13) by help prefix and indexes
    the result; the same filter over the same walk, truncated at the same depth, gives the index.
    """
    matches = [index for index, node in enumerate(nodes)
               if node["depth"] <= PROBE_DEPTH and (node["help"] or "").startswith(prefix)]
    return matches.index(global_index) if global_index in matches else None


# ---------------------------------------------------------------------------------------------
# The product
# ---------------------------------------------------------------------------------------------

def rows_of(value):
    return [row for row in value if isinstance(row, dict)] if isinstance(value, list) else []


def product_strips(mixer):
    """logic://mixer strips keyed by trackIndex."""
    return {row["trackIndex"]: row for row in rows_of((mixer or {}).get("strips"))
            if isinstance(row.get("trackIndex"), int)}


def graph_of(mixer):
    graph = (mixer or {}).get("routing_graph")
    return graph if isinstance(graph, dict) else {}


def edges_of(graph):
    return [[edge.get("kind"), edge.get("source"), edge.get("destination")]
            for edge in rows_of(graph.get("edges"))]


def nodes_by_id(graph):
    return {node.get("id"): node for node in rows_of(graph.get("nodes"))
            if isinstance(node.get("id"), str)}


def track_refs_of(tracks):
    """logic://tracks: trackIndex (`id`) -> issued trk_ reference."""
    return {row["id"]: row["track_ref"] for row in rows_of((tracks or {}).get("data"))
            if isinstance(row.get("id"), int) and isinstance(row.get("track_ref"), str)}


def send_states(strip):
    slots = (strip or {}).get("send_slots")
    if not isinstance(slots, list):
        return None
    return [slot.get("state") if isinstance(slot, dict) else None for slot in slots]


def read_mixer_until(driver, predicate, timeout=READ_TIMEOUT):
    """Force a poll, then read until the strips answer the predicate or the bound expires."""
    deadline = time.monotonic() + timeout
    latest = {}
    while True:
        driver.tool("logic_system", "refresh_cache")
        latest = driver.resource("logic://mixer") or {}
        if latest.get("data_source") == FRESH and predicate(latest):
            return latest, True
        if time.monotonic() >= deadline:
            return latest, False
        time.sleep(0.5)


def take_reading(ev, driver, pid, labels, lproj, label, predicate=lambda mixer: True):
    """The product and the witness, read back to back after one forced poll."""
    tracks = driver.resource("logic://tracks") or {}
    mixer, answered = read_mixer_until(driver, predicate)
    tree = ax_tree(pid) if pid else {"nodes": [], "children_read_failures": [{"path": [], "status": "no pid"}]}
    witness = witness_of(tree, labels)
    age = mixer.get("cache_age_sec")
    ev.provenance(f"{TAG}/{lproj}/{label}/mixer", f"state_poller_cache_{mixer.get('data_source')}",
                  round(age, 2) if isinstance(age, (int, float)) else None,
                  mixer.get("data_source") == FRESH)
    reading = {"label": label, "mixer": mixer, "track_refs": track_refs_of(tracks),
               "witness": witness, "tree": tree, "answered": answered,
               "fresh": mixer.get("data_source") == FRESH}
    ev.note(f"{TAG}/{lproj}/{label}", condensed(reading))
    return reading


def condensed(reading):
    """What a reading's note keeps: everything asserted on, not the whole walk."""
    graph = graph_of(reading["mixer"])
    witness = reading["witness"]
    return {
        "fresh": reading["fresh"], "answered": reading["answered"],
        "data_source": reading["mixer"].get("data_source"),
        "strips": [{"trackIndex": index, "output": row.get("output"), "input": row.get("input"),
                    "send_slots": row.get("send_slots")}
                   for index, row in sorted(product_strips(reading["mixer"]).items())],
        "routing_graph": {"snapshot_id": graph.get("snapshot_id"), "complete": graph.get("complete"),
                          "coverage": graph.get("coverage"), "edges": edges_of(graph),
                          "nodes": [{key: node.get(key) for key in
                                     ("id", "kind", "busNumber", "observed_output_label",
                                      "output_classification")}
                                    for node in rows_of(graph.get("nodes"))]},
        "track_refs": {str(k): v for k, v in sorted(reading["track_refs"].items())},
        "witness": {"mixer_found": witness["mixer_found"], "containers": witness["containers"],
                    "read_failures": witness["read_failures"],
                    "tree_nodes": len(reading["tree"].get("nodes") or []),
                    "strips": [{"outputs": [o["description"] for o in strip["outputs"]],
                                "inputs": [i["description"] for i in strip["inputs"]],
                                "sends_knob_follows": [s["knob_follows"] for s in strip["sends"]],
                                "knobs": strip["knobs"],
                                "knobs_after_a_send_button": strip["knobs_after_a_send_button"]}
                               for strip in witness["strips"]]},
    }


# ---------------------------------------------------------------------------------------------
# Observations the predicates judge (pure functions of readings)
# ---------------------------------------------------------------------------------------------

def witness_complete(reading):
    witness = reading["witness"]
    return bool(witness["mixer_found"]) and witness["read_failures"] == 0


def output_observation(reading):
    strips = product_strips(reading["mixer"])
    nodes = nodes_by_id(graph_of(reading["mixer"]))
    rows = []
    for index, strip in enumerate(reading["witness"]["strips"]):
        product = strips.get(index) or {}
        reference = reading["track_refs"].get(index)
        node = nodes.get(reference) if reference else None
        rows.append({"index": index,
                     "witnessed_output": strip["outputs"][0]["description"] if strip["outputs"] else None,
                     "product_output": product.get("output"),
                     "has_track_ref": reference is not None,
                     "output_classification": (node or {}).get("output_classification")})
    return {"fresh": reading["fresh"], "witness_complete": witness_complete(reading), "strips": rows}


def slot_rows(reading):
    strips = product_strips(reading["mixer"])
    rows = []
    for index, strip in enumerate(reading["witness"]["strips"]):
        product = strips.get(index) or {}
        slots = product.get("send_slots")
        rows.append({"index": index,
                     "product_states": send_states(product),
                     "product_levels": [[slot.get("level_raw"), slot.get("level_description")]
                                        for slot in rows_of(slots)],
                     "witness_knob_follows": [send["knob_follows"] for send in strip["sends"]],
                     "witness_knobs": strip["knobs"],
                     "witness_knobs_after_a_send_button": strip["knobs_after_a_send_button"]})
    return rows


def slots_observation(readings):
    return {"readings": [{"label": reading["label"], "fresh": reading["fresh"],
                          "witness_complete": witness_complete(reading),
                          "product_strip_count": len(product_strips(reading["mixer"])),
                          "witness_strip_count": len(reading["witness"]["strips"]),
                          "strips": slot_rows(reading)}
                         for reading in readings if reading]}


def signature(reading):
    """What a mutation may change and its undo must give back, by both instruments."""
    if not reading:
        return None
    strips = product_strips(reading["mixer"])
    return {"product": [[index, strips[index].get("output"), send_states(strips[index])]
                        for index in sorted(strips)],
            "witness": [[[o["description"] for o in strip["outputs"]],
                         [send["knob_follows"] for send in strip["sends"]]]
                        for strip in reading["witness"]["strips"]]}


def states_by_strip(reading):
    return {str(row["index"]): row["product_states"] for row in slot_rows(reading)}


def follows_by_strip(reading):
    return {str(row["index"]): row["witness_knob_follows"] for row in slot_rows(reading)}


def send_mutation_observation(target, probe, before, after, after_undo):
    def phase(reading):
        if not reading:
            return None
        return {"fresh": reading["fresh"], "witness_complete": witness_complete(reading),
                "states": states_by_strip(reading), "follows": follows_by_strip(reading),
                "send_edges": sum(1 for edge in edges_of(graph_of(reading["mixer"]))
                                  if edge[0] == EDGE_SEND)}
    return {"target": target, "probe": probe, "before": phase(before), "after": phase(after),
            "after_undo": phase(after_undo)}


def output_mutation_observation(target, reference, number, probe, before, after, after_undo):
    def phase(reading):
        if not reading:
            return None
        graph = graph_of(reading["mixer"])
        node = nodes_by_id(graph).get(reference) or {}
        return {"fresh": reading["fresh"],
                "output": (product_strips(reading["mixer"]).get(target) or {}).get("output"),
                "classification": node.get("output_classification"),
                "bus_nodes": [[node_id, node.get("busNumber")]
                              for node_id, node in sorted(nodes_by_id(graph).items())
                              if node.get("kind") == KIND_BUS],
                "edges": edges_of(graph)}
    return {"target": target, "target_ref": reference, "bus_number": number, "probe": probe,
            "before": phase(before), "after": phase(after), "after_undo": phase(after_undo)}


# ---------------------------------------------------------------------------------------------
# The predicates. Each takes one observation and returns a bool; ev.falsifiable runs each against
# the live observation and against COUNTER[check](observation).
# ---------------------------------------------------------------------------------------------

def pred_output_readable_per_strip(o):
    rows = o["strips"]
    witnessed = [row for row in rows if row["witnessed_output"]]
    classified = [row for row in witnessed if row["has_track_ref"]]
    return (o["fresh"] and o["witness_complete"] and bool(witnessed) and bool(classified)
            and all(row["product_output"] == row["witnessed_output"] for row in witnessed)
            and all(row["output_classification"] in OUTPUT_CLASSES for row in classified))


def pred_send_slot_count_matches_witness(o):
    readings = o["readings"]
    return (bool(readings)
            and all(r["fresh"] and r["witness_complete"] and r["product_strip_count"] > 0
                    and r["product_strip_count"] == r["witness_strip_count"]
                    and all(isinstance(s["product_states"], list)
                            and len(s["product_states"]) == len(s["witness_knob_follows"])
                            for s in r["strips"])
                    for r in readings)
            and sum(len(s["witness_knob_follows"]) for r in readings for s in r["strips"]) > 0)


def pred_occupancy_matches_knob_witness(o):
    readings = o["readings"]

    def strip_ok(s):
        states, follows = s["product_states"], s["witness_knob_follows"]
        return (isinstance(states, list) and len(states) == len(follows)
                and all(state in SLOT_READ_STATES for state in states)
                and [state in OCCUPIED for state in states] == follows
                and s["witness_knobs"] == s["witness_knobs_after_a_send_button"] == sum(follows))
    return (bool(readings)
            and all(r["fresh"] and r["witness_complete"] and all(strip_ok(s) for s in r["strips"])
                    for r in readings)
            and sum(s["witness_knobs"] for r in readings for s in r["strips"]) > 0)


def pred_send_assignment_then_undo(o):
    target = str(o["target"])
    before, after, undone = o["before"], o["after"], o["after_undo"]
    phases = (before, after, undone)
    if o["probe"].get("exit") != 0 or not o["probe"].get("selected"):
        return False
    if not all(p and p["fresh"] and p["witness_complete"] for p in phases):
        return False
    others = [key for key in before["states"] if key != target]
    return (before["states"][target][0] == SLOT_EMPTY and before["follows"][target][0] is False
            and after["states"][target][0] == SLOT_OCCUPIED_UNKNOWN
            and after["follows"][target][0] is True
            and all(after["states"].get(key) == before["states"][key] for key in others)
            and set(after["states"]) == set(before["states"])
            and after["send_edges"] == 0
            and undone["states"] == before["states"] and undone["follows"] == before["follows"])


def pred_bus_output_then_undo(o):
    reference, number = o["target_ref"], o["bus_number"]
    before, after, undone = o["before"], o["after"], o["after_undo"]
    if o["probe"].get("exit") != 0 or not o["probe"].get("selected"):
        return False
    if not (isinstance(reference, str) and reference.startswith(TRACK_REF_PREFIX)
            and isinstance(number, int) and number > 0):
        return False
    if not all(p and p["fresh"] for p in (before, after, undone)):
        return False
    bus_id = BUS_NODE_PREFIX + str(number)
    edge = [EDGE_MAIN_OUTPUT, reference, bus_id]
    return (edge not in before["edges"]
            and after["classification"] == CLASS_BUS
            and [bus_id, number] in after["bus_nodes"]
            and edge in after["edges"]
            and all(isinstance(e[2], str) and e[2].startswith(BUS_NODE_PREFIX) for e in after["edges"])
            and all(e[0] != EDGE_SEND for e in after["edges"])
            and edge not in undone["edges"]
            and undone["output"] == before["output"]
            and undone["classification"] == before["classification"])


def pred_snapshot_id_parity(o):
    stable = [a for a in o["attempts"]
              if isinstance(a["mixer_before"], str) and a["mixer_before"].startswith(SNAPSHOT_PREFIX)
              and a["mixer_before"] == a["mixer_after"]]
    return (bool(stable)
            and all(a["inspect"] == a["mixer_before"] and a["inspect_routing"] == a["mixer_before"]
                    and isinstance(a["mixer_coverage"], dict) and bool(a["mixer_coverage"])
                    and a["mixer_coverage"] == a["inspect_graph"]
                    for a in stable))


def pred_coverage_never_complete_with_filters_unread(o):
    coverage = o["coverage"] if isinstance(o["coverage"], dict) else {}
    return (o["mixer_filters_unread"] is True
            and all(isinstance(coverage.get(d), dict) and coverage[d].get("state") in COVERAGE_STATES
                    for d in DOMAINS)
            and coverage["population"]["state"] != COMPLETE
            and o["graph_complete"] is False
            and o["inspect_routing_coverage"] in COVERAGE_STATES
            and o["inspect_routing_coverage"] != COMPLETE)


def pred_positive_control_mute(o):
    runs = o["probe_runs"]
    return bool(runs) and all(run["control_mute_moved"] == 1 for run in runs)


def pred_menus_closed_and_modal_clean(o):
    samples = o["samples"]
    return bool(samples) and all(s["open_menus"] == [] and s["modal"] is None for s in samples)


def pred_restored(o):
    mutations = o["mutations"]
    return bool(mutations) and all(
        m["undo_exit"] == 0 and m["before"] is not None and m["after"] != m["before"]
        and m["after_undo"] == m["before"] for m in mutations)


PREDICATES = {
    "output_readable_per_strip": pred_output_readable_per_strip,
    "send_slot_count_matches_witness": pred_send_slot_count_matches_witness,
    "occupancy_matches_knob_witness": pred_occupancy_matches_knob_witness,
    "send_assignment_then_undo": pred_send_assignment_then_undo,
    "bus_output_then_undo": pred_bus_output_then_undo,
    "snapshot_id_parity": pred_snapshot_id_parity,
    "coverage_never_complete_with_filters_unread": pred_coverage_never_complete_with_filters_unread,
    "positive_control_mute": pred_positive_control_mute,
    "menus_closed_and_modal_clean": pred_menus_closed_and_modal_clean,
    "restored": pred_restored,
}


# ---------------------------------------------------------------------------------------------
# Counterexamples: each is derived from the observation it is set against, with one defect put in
# -- the defect a real earlier shape had. Deriving rather than typing them keeps the counterexample
# the same size and shape as the observation, so a predicate rejects it for the defect alone.
# ---------------------------------------------------------------------------------------------

def counter_output(o):
    """main at d1f3b810: a witnessed slot published as {output: null, output_classification: null}."""
    c = copy.deepcopy(o)
    for row in c["strips"]:
        if row["witnessed_output"]:
            row["product_output"] = None
            row["output_classification"] = None
            break
    return c


def counter_send_counts(o):
    """main before t1: no send_slots key, so every strip's slots read as absent."""
    c = copy.deepcopy(o)
    for reading in c["readings"]:
        for row in reading["strips"]:
            row["product_states"] = None
    return c


def counter_occupancy(o):
    """Occupancy from level: a knob witnessed after the button, the slot filed empty at -inf."""
    c = copy.deepcopy(o)
    for reading in c["readings"]:
        for row in reading["strips"]:
            for ordinal, follows in enumerate(row["witness_knob_follows"]):
                if follows and isinstance(row["product_states"], list):
                    row["product_states"][ordinal] = SLOT_EMPTY
                    if ordinal < len(row["product_levels"]):
                        row["product_levels"][ordinal] = [float("-inf"), None]
                    return c
    return c


def counter_send_mutation(o):
    """The same, on the target after the assignment: the knob seen, the slot still empty."""
    c = copy.deepcopy(o)
    after = c.get("after")
    if after and str(c["target"]) in after["states"] and after["states"][str(c["target"])]:
        after["states"][str(c["target"])][0] = SLOT_EMPTY
        after["follows"][str(c["target"])][0] = True
    return c


def counter_bus_output(o):
    """The 2026-09-27 records: a strip reading `Bus N` and `edges: []`."""
    c = copy.deepcopy(o)
    if c.get("after"):
        c["after"]["edges"] = []
        c["after"]["bus_nodes"] = []
    return c


def counter_snapshot(o):
    """inspect_session answering from another capture than the bracketed mixer read."""
    c = copy.deepcopy(o)
    for attempt in c["attempts"]:
        if isinstance(attempt["inspect"], str):
            attempt["inspect"] = attempt["inspect"] + "_other"
            attempt["inspect_routing"] = attempt["inspect"]
    return c


def counter_coverage(o):
    """A graph claiming complete while the mixer's filters were never read."""
    c = copy.deepcopy(o)
    if isinstance(c.get("coverage"), dict):
        c["coverage"] = {domain: {"state": COMPLETE, "reasons": []} for domain in DOMAINS}
    c["graph_complete"] = True
    c["inspect_routing_coverage"] = COMPLETE
    return c


def counter_mute(o):
    """2026-09-09: an instrument aimed at nothing -- `control mute moved: 0`."""
    c = copy.deepcopy(o)
    c["probe_runs"] = (c["probe_runs"] or [{"label": "none"}])[:]
    c["probe_runs"][0] = dict(c["probe_runs"][0], control_mute_moved=0)
    return c


def counter_menus(o):
    """2026-09-26 zh_TW: a menu left open at layer 101 after a refused insert."""
    c = copy.deepcopy(o)
    c["samples"] = (c["samples"] or [{"label": "none", "modal": None}])[:]
    c["samples"][0] = dict(c["samples"][0], open_menus=[{"layer": 101}])
    return c


def counter_restored(o):
    """An undo that changed nothing: the after-undo signature is the mutated one."""
    c = copy.deepcopy(o)
    for mutation in c["mutations"]:
        mutation["after_undo"] = copy.deepcopy(mutation["after"])
    return c


COUNTER = {
    "output_readable_per_strip": counter_output,
    "send_slot_count_matches_witness": counter_send_counts,
    "occupancy_matches_knob_witness": counter_occupancy,
    "send_assignment_then_undo": counter_send_mutation,
    "bus_output_then_undo": counter_bus_output,
    "snapshot_id_parity": counter_snapshot,
    "coverage_never_complete_with_filters_unread": counter_coverage,
    "positive_control_mute": counter_mute,
    "menus_closed_and_modal_clean": counter_menus,
    "restored": counter_restored,
}

EXPECTED = {
    "output_readable_per_strip":
        "every output slot the witness reads is published verbatim as strips[i].output, and every "
        "strip carrying an issued trk_ carries a non-null output_classification on its node",
    "send_slot_count_matches_witness":
        "in every reading, strips[i].send_slots is a list as long as the witness's send-slot "
        "buttons on that strip, with as many strips as the witness found",
    "occupancy_matches_knob_witness":
        "a slot is occupied_* exactly where the witness sees the send level knob right after its "
        "button, every witnessed knob follows a send button, and at least one knob was seen",
    "send_assignment_then_undo":
        "selecting a bus in send slot 0 turns that slot alone observed_empty -> "
        "occupied_unknown_destination by both instruments, publishes no send edge, and the undo "
        "gives back every strip's states",
    "bus_output_then_undo":
        "selecting a bus as the strip's output publishes output_classification bus, a bus_<n> node "
        "and a mainOutput edge from its trk_, no edge ends at a track, and the undo removes it",
    "snapshot_id_parity":
        "inspect_session's snapshot_id and routing.snapshot_id equal the routing graph's snapshot_id "
        "of a mixer read whose snapshot did not move, and routing.graph equals its coverage",
    "coverage_never_complete_with_filters_unread":
        "while inspect_session names mixer_filters_unread, population is not complete, the graph is "
        "not complete and the routing section is not complete",
    "positive_control_mute":
        "every probe run moved its track Mute and moved it back, so a silence from it is a reading",
    "menus_closed_and_modal_clean":
        "after every probe run and every undo, no Logic menu is on screen and no modal blocks",
    "restored":
        "each mutation changed the product-and-witness signature and its undo gave it back exactly",
}

MUTATIONS = {
    "output_readable_per_strip":
        "drop the eight derived members of outputSlotHelpKeyword (main d1f3b810): output is null on "
        "every strip outside en/ko",
    "send_slot_count_matches_witness":
        "stop setting state.sendSlots in defaultGetMixerState: send_slots is absent on every strip",
    "occupancy_matches_knob_witness":
        "decide the slot state from levelRaw instead of the knob's presence",
    "send_assignment_then_undo":
        "attach the knob to the button before it by ordinal in the whole strip instead of by "
        "pre-order succession, or emit a send edge from an occupied slot",
    "bus_output_then_undo":
        "restore the track-name join in RoutingGraphPublication.publish: a bus label joins no track "
        "and edges stay [] (the 2026-09-27 records)",
    "snapshot_id_parity":
        "build the mixer's routing graph from a different read than SessionPopulationObservation.capture",
    "coverage_never_complete_with_filters_unread":
        "remove the mixerFiltersUnreadReason partial from population, or the coverage clause from "
        "RoutingGraph.isConsistent",
    "positive_control_mute": None,
    "menus_closed_and_modal_clean": None,
    "restored": None,
}


# ---------------------------------------------------------------------------------------------
# Logic, outside the product: menus, the Mixer, undo, the language
# ---------------------------------------------------------------------------------------------

def osa(script, timeout=20):
    try:
        result = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True,
                                text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    return (result.stdout or "").strip() if result.returncode == 0 else None


def open_logic_menus():
    """Logic's on-screen windows at or above the pop-up menu level; None when they cannot be read."""
    try:
        import Quartz
        level = Quartz.CGWindowLevelForKey(Quartz.kCGPopUpMenuWindowLevelKey)
        windows = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly,
                                                    Quartz.kCGNullWindowID) or []
        return [{"layer": int(window.get(Quartz.kCGWindowLayer))}
                for window in windows
                if E._is_logic_owned_window(window)
                and int(window.get(Quartz.kCGWindowLayer) or 0) >= int(level)]
    except Exception:  # noqa: BLE001 - an unread window list is not an empty one
        return None


def escape_open_menus():
    """Escape while a Logic menu is on screen, at most three times; what was open is returned."""
    found = open_logic_menus()
    for _ in range(3):
        if not open_logic_menus():
            break
        osa('tell application "System Events" to key code 53', timeout=5)
        time.sleep(0.5)
    return found


def menu_sample(label):
    """After a probe run or an undo: Escape what is open, then read menus and the modal scan."""
    escaped = escape_open_menus()
    return {"label": label, "open_before_escape": escaped, "open_menus": open_logic_menus(),
            "modal": E.blocking_modal()}


def press_x():
    """Logic's Mixer toggle is the X key in every language; no menu name to translate."""
    subprocess.run(["osascript", "-e", 'tell application "Logic Pro" to activate', "-e", "delay 0.5",
                    "-e", 'tell application "System Events" to keystroke "x"'],
                   capture_output=True, text=True)


def mixer_is_fresh(driver):
    driver.tool("logic_system", "refresh_cache")
    return (driver.resource("logic://mixer") or {}).get("data_source") == FRESH


def open_mixer(driver):
    presses = 0
    for _ in range(2):
        if mixer_is_fresh(driver):
            break
        press_x()
        presses += 1
        for _ in range(6):
            time.sleep(1)
            if mixer_is_fresh(driver):
                break
    return presses


def put_mixer_back(driver, presses):
    if presses % 2:
        press_x()
        for _ in range(6):
            time.sleep(1)
            if not mixer_is_fresh(driver):
                break
        return not mixer_is_fresh(driver)
    return mixer_is_fresh(driver)


def edit_menu_first_item(edit_name):
    quoted = '"' + edit_name.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return osa('tell application "System Events" to tell process "Logic Pro" to get name of '
               f'menu item 1 of menu 1 of menu bar item {quoted} of menu bar 1')


def undo_through_edit_menu(edit_name):
    """Logic's own Undo: menu item 1 of the Edit menu, whose title is Apple's `Edit#mti` row."""
    quoted = '"' + edit_name.replace("\\", "\\\\").replace('"', '\\"') + '"'
    item = edit_menu_first_item(edit_name)
    script = ('tell application "Logic Pro" to activate\n'
              'tell application "System Events" to tell process "Logic Pro"\n'
              f'  click menu item 1 of menu 1 of menu bar item {quoted} of menu bar 1\n'
              'end tell')
    try:
        action = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True,
                                text=True, timeout=60)
        return {"undo_item": item, "undo_exit": action.returncode, "stderr": action.stderr[-300:]}
    except subprocess.TimeoutExpired:
        return {"undo_item": item, "undo_exit": None, "stderr": "Edit-menu undo timed out"}


def apple_string(canon, lproj, key):
    with open(STRINGS % lproj, "rb") as handle:
        return canon.parse_strings(handle.read()).get(key)


def language_setting():
    result = subprocess.run(["defaults", "read", "com.apple.logic10", "AppleLanguages"],
                            capture_output=True, text=True)
    return re.findall(r"[\w-]+", result.stdout) if result.returncode == 0 else []


def window_names():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'get name of every window')
    return [] if not raw else [part.strip() for part in raw.split(", ")]


def logic_running():
    return osa('tell application "System Events" to return (count of (every process whose '
               'name is "Logic Pro"))') == "1"


def unidentified_documents():
    """Documents open in Logic other than the fixture, or None when the list cannot be read."""
    raw = osa('''tell application "System Events" to tell process "Logic Pro"
  set out to ""
  repeat with w in windows
    try
      set out to out & (value of attribute "AXDocument" of w as string) & linefeed
    end try
  end repeat
  return out & "lpm:end-of-documents"
end tell''')
    if raw is None or not raw.endswith("lpm:end-of-documents"):
        return None
    others = []
    for line in raw.splitlines()[:-1]:
        doc = line.strip()
        if not doc or doc == "missing value":
            continue
        path = urllib.parse.unquote(urllib.parse.urlparse(doc).path) if doc.startswith("file:") else doc
        if os.path.realpath(path.rstrip("/")) != os.path.realpath(FIXTURE):
            others.append(doc)
    return others


def press_non_default_non_cancel():
    """The save prompt's don't-save button: neither its default nor its cancel button."""
    return osa('''tell application "System Events" to tell process "Logic Pro"
  if (count of (windows whose subrole is "AXDialog")) is 0 then return ""
  set d to first window whose subrole is "AXDialog"
  set skip to {}
  try
    set end of skip to name of (value of attribute "AXDefaultButton" of d) as string
  end try
  try
    set end of skip to name of (value of attribute "AXCancelButton" of d) as string
  end try
  if (count of skip) is not 2 then return ""
  repeat with b in (every button of d)
    set n to name of b as string
    if n is not in skip then
      click b
      return n
    end if
  end repeat
  return ""
end tell''')


def quit_logic():
    """Quit Logic, answering its save prompt for the fixture only; False if another document is open."""
    if not logic_running():
        return True
    others = unidentified_documents()
    if others is None or others:
        return False
    escape_open_menus()
    for _ in range(4):
        osa('tell application "Logic Pro" to quit', timeout=8)
        deadline = time.monotonic() + 20
        while logic_running() and time.monotonic() < deadline:
            if press_non_default_non_cancel():
                break
            time.sleep(0.5)
        deadline = time.monotonic() + 20
        while logic_running() and time.monotonic() < deadline:
            time.sleep(0.5)
        if not logic_running():
            return True
    return not logic_running()


def arrange_title(canon, lproj):
    suffix = apple_string(canon, lproj, "Tracks")
    return f"{FIXTURE_NAME} - {suffix}" if suffix else None


def language_is(canon, lproj):
    """Whether Logic is in this language on the fixture, read two ways; never switches."""
    title = arrange_title(canon, lproj)
    setting, names = language_setting(), window_names()
    return {"active": bool(title) and setting[:1] == [CODES[lproj]] and title in names,
            "arrange_window": title, "language_setting": setting, "window_names": names}


def switch_to(canon, lproj):
    """Quit, write AppleLanguages, reopen the fixture and wait for the arrange window's title."""
    current = language_is(canon, lproj)
    if current["active"]:
        return dict(current, switched=False)
    title = current["arrange_window"]
    if not title:
        return dict(current, error="Apple's Tracks row did not resolve", switched=False)
    if not quit_logic():
        return dict(current, error="Logic did not quit, or another document is open", switched=False)
    written = subprocess.run(["defaults", "write", "com.apple.logic10", "AppleLanguages",
                              "-array", CODES[lproj]], capture_output=True, text=True)
    if written.returncode != 0:
        return dict(current, error="AppleLanguages write failed", switched=False)
    subprocess.run(["open", "-a", APP, FIXTURE], capture_output=True)
    deadline = time.monotonic() + LAUNCH_TIMEOUT
    while time.monotonic() < deadline and title not in window_names():
        time.sleep(0.5)
    return dict(language_is(canon, lproj), switched=True)


# ---------------------------------------------------------------------------------------------
# The actuator: ax_routing_slot_menu_probe.swift
# ---------------------------------------------------------------------------------------------

def build_probe(directory):
    binary = os.path.join(directory, "ax_routing_slot_menu_probe")
    if os.path.exists(binary):
        return binary, None
    built = subprocess.run(["swiftc", "-O", PROBE_SOURCE, "-o", binary], capture_output=True, text=True)
    if built.returncode != 0:
        return None, (built.stderr or "")[-400:]
    return binary, None


def parse_probe(stdout):
    """The probe's `key: value` lines, the menu titles it printed, and what it selected."""
    lines = (stdout or "").splitlines()
    fields, titles = {}, []
    for line in lines:
        if line.startswith("title: "):
            titles.append(line[len("title: "):])
        elif ": " in line:
            key, value = line.split(": ", 1)
            fields.setdefault(key, value)
    moved = fields.get("control mute moved")
    selected = fields.get("selected")
    return {"control_mute_moved": int(moved) if moved in ("0", "1") else None,
            "menus_opened": fields.get("menus opened"),
            "duplicated_titles": fields.get("titles appearing more than once"),
            "menus_after_escape": fields.get("menus after escape"),
            "slot_destination": fields.get("slot destination"),
            "destination_after_select": fields.get("destination after select"),
            "selected": selected if selected and not selected.startswith(("skipped", "refused")) else None,
            "refused": bool(selected and selected.startswith("refused")),
            "titles": titles}


def run_probe(binary, prefix, index, mute_labels, select=None):
    command = [binary, "--slot-prefix", prefix, "--slot-index", str(index), "--mute-labels",
               *mute_labels]
    command += ["--select", select] if select else ["--print-titles", "2000"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        parsed = parse_probe(result.stdout)
        parsed.update({"exit": result.returncode, "stderr": (result.stderr or "")[-300:]})
    except subprocess.TimeoutExpired:
        parsed = dict(parse_probe(""), exit=None, stderr="probe timed out")
    parsed["arguments"] = {"slot_index": index, "select": select, "prefix_chars": len(prefix)}
    return parsed


def choose_target(reading, labels):
    """The first strip that is an audio track's: input not a bus, output physical, slot 0 empty."""
    strips = product_strips(reading["mixer"])
    nodes = nodes_by_id(graph_of(reading["mixer"]))
    for index, strip in enumerate(reading["witness"]["strips"]):
        product = strips.get(index) or {}
        reference = reading["track_refs"].get(index)
        node = nodes.get(reference) if reference else None
        states = send_states(product)
        if not (node and strip["inputs"] and strip["outputs"] and strip["sends"] and states):
            continue
        if bus_number(strip["inputs"][0]["description"], labels["busOutputLabelPrefix"]):
            continue
        if node.get("output_classification") != CLASS_PHYSICAL:
            continue
        if states[0] != SLOT_EMPTY or strip["sends"][0]["knob_follows"]:
            continue
        return index, reference
    return None, None


def choose_bus(titles, reading, labels):
    """A bus title from the opened menu, preferring one an existing strip's input already reads."""
    offered = {}
    for title in titles:
        number = bus_number(title, labels["busOutputLabelPrefix"])
        if number and titles.count(title) == 1:
            offered.setdefault(number, title)
    if not offered:
        return None, None, "no bus title in the menu"
    received = set()
    for strip in reading["witness"]["strips"]:
        for source in strip["inputs"]:
            number = bus_number(source["description"], labels["busOutputLabelPrefix"])
            if number:
                received.add(number)
    shared = sorted(set(offered) & received)
    if shared:
        return shared[-1], offered[shared[-1]], "an existing strip's input already reads it"
    number = max(offered)
    return number, offered[number], "no strip's input reads a bus the menu offers; highest bus taken"


# ---------------------------------------------------------------------------------------------
# One locale
# ---------------------------------------------------------------------------------------------

def mutate_and_undo(ev, driver, pid, labels, lproj, name, probe_binary, prefix, index, title,
                    edit_name, before, changed, state):
    """Select `title` in one slot, read, undo through Logic's Edit menu, read again."""
    probe = run_probe(probe_binary, prefix, index, labels["trackMuteButton"], select=title)
    state["probe_runs"].append({"label": f"{name}-select", "control_mute_moved": probe["control_mute_moved"]})
    state["menu_samples"].append(menu_sample(f"{name}-select"))
    ev.note(f"{TAG}/{lproj}/{name}/probe", probe)
    after = take_reading(ev, driver, pid, labels, lproj, f"{name}-after", changed)
    undo, after_undo = None, None
    if signature(after) != signature(before):
        undo = undo_through_edit_menu(edit_name)
        state["menu_samples"].append(menu_sample(f"{name}-undo"))
        ev.note(f"{TAG}/{lproj}/{name}/undo", undo)
        after_undo = take_reading(ev, driver, pid, labels, lproj, f"{name}-after-undo",
                                  lambda mixer: signature_of_mixer(mixer) == signature_of_mixer(before["mixer"]))
    restored = after_undo is not None and signature(after_undo) == signature(before)
    ev.restored(f"{TAG}/{lproj}/{name}-undone", restored or signature(after) == signature(before),
                json.dumps({"undo": undo, "changed": signature(after) != signature(before)},
                           ensure_ascii=False)[:600])
    state["mutations"].append({"label": name, "undo_exit": (undo or {}).get("undo_exit"),
                               "before": signature(before), "after": signature(after),
                               "after_undo": signature(after_undo)})
    return probe, after, after_undo, restored


def signature_of_mixer(mixer):
    strips = product_strips(mixer)
    return [[index, strips[index].get("output"), send_states(strips[index])] for index in sorted(strips)]


def inspect_parity(ev, driver, lproj):
    """Mixer, inspect_session, mixer: kept only when the two mixer snapshots agree; retried otherwise."""
    attempts, last = [], {}
    for _ in range(SNAPSHOT_ATTEMPTS):
        driver.tool("logic_system", "refresh_cache")
        first = graph_of(driver.resource("logic://mixer") or {})
        report = driver.tool("logic_project", "inspect_session",
                             {"domains": ["tracks", "strips", "routing"]}) or {}
        second = graph_of(driver.resource("logic://mixer") or {})
        routing = report.get("routing") if isinstance(report.get("routing"), dict) else {}
        strips = report.get("strips") if isinstance(report.get("strips"), dict) else {}
        attempt = {"mixer_before": first.get("snapshot_id"), "inspect": report.get("snapshot_id"),
                   "inspect_routing": routing.get("snapshot_id"),
                   "mixer_after": second.get("snapshot_id"),
                   "mixer_coverage": first.get("coverage"), "inspect_graph": routing.get("graph")}
        attempts.append(attempt)
        last = {"graph": first, "routing": routing, "strips_reasons": strips.get("reasons"),
                "report_keys": sorted(report)}
        if attempt["mixer_before"] == attempt["mixer_after"]:
            break
    ev.note(f"{TAG}/{lproj}/inspect-session", {"attempts": attempts, "last": {
        "routing": last.get("routing"), "strips_reasons": last.get("strips_reasons"),
        "report_keys": last.get("report_keys")}})
    graph = last.get("graph") or {}
    coverage = {"mixer_filters_unread": FILTERS_UNREAD in (last.get("strips_reasons") or []),
                "graph_complete": graph.get("complete"), "coverage": graph.get("coverage"),
                "inspect_routing_coverage": (last.get("routing") or {}).get("coverage")}
    return {"attempts": attempts}, coverage


def summary_of(lproj, readings, target, bus, send_probe, output_probe, parity, coverage, state):
    """Every number a record states, taken here from the readings so a record never types one."""
    base = readings.get("before")

    def classes(reading):
        counts = {}
        for row in output_observation(reading)["strips"] if reading else []:
            if row["has_track_ref"]:
                key = row["output_classification"] or "null"
                counts[key] = counts.get(key, 0) + 1
        return counts

    def occupancy(reading):
        rows = slot_rows(reading) if reading else []
        return {"send_slots": sum(len(r["witness_knob_follows"]) for r in rows),
                "occupied_product": sum(1 for r in rows for s in (r["product_states"] or []) if s in OCCUPIED),
                "knobs_witnessed": sum(r["witness_knobs"] for r in rows),
                "knobs_not_after_a_send_button": sum(r["witness_knobs"] - r["witness_knobs_after_a_send_button"]
                                                     for r in rows)}

    new_knob = None
    after_send = readings.get("send-after")
    if after_send and target is not None:
        slots = rows_of((product_strips(after_send["mixer"]).get(target) or {}).get("send_slots"))
        new_knob = [{"level_raw": slot.get("level_raw"), "level_description": slot.get("level_description")}
                    for slot in slots if slot.get("state") in OCCUPIED]
    return {
        "lproj": lproj,
        "product_strips": len(product_strips(base["mixer"])) if base else None,
        "witness_strips": len(base["witness"]["strips"]) if base else None,
        "witness_read_failures": base["witness"]["read_failures"] if base else None,
        "witnessed_output_slots": sum(1 for s in base["witness"]["strips"] if s["outputs"]) if base else None,
        "strips_without_an_output_slot": sum(1 for s in base["witness"]["strips"] if not s["outputs"]) if base else None,
        "output_classification_counts": classes(base),
        "occupancy": {label: occupancy(reading) for label, reading in readings.items()},
        "target_strip": target, "bus_number": bus,
        "send_probe_exit": (send_probe or {}).get("exit"),
        "output_probe_exit": (output_probe or {}).get("exit"),
        "new_knob_levels": new_knob,
        "edges": {label: len(edges_of(graph_of(reading["mixer"]))) for label, reading in readings.items()},
        "snapshot_attempts": len(parity["attempts"]) if parity else None,
        "coverage_states": {d: ((coverage or {}).get("coverage") or {}).get(d, {}).get("state") for d in DOMAINS},
        "inspect_routing_coverage": (coverage or {}).get("inspect_routing_coverage"),
        "probe_runs": len(state["probe_runs"]),
        "menu_samples": len(state["menu_samples"]),
        "mutations": [{"label": m["label"], "undo_exit": m["undo_exit"],
                       "changed": m["after"] != m["before"], "restored": m["after_undo"] == m["before"]}
                      for m in state["mutations"]],
    }


def run_locale(ev, args, canon, labels, lproj, probe_binary, band, subject):
    """Every check for one active locale. Each of the ten is recorded whatever happens before it."""
    prefix = f"{TAG}/{lproj}"
    edit_name = apple_string(canon, lproj, "Edit#mti")
    if not edit_name or edit_name not in (labels["editMenuBar"] or []):
        ev.check(f"{prefix}/edit-menu-row-resolves", False,
                 "Apple's Edit#mti row resolves and is a member of editMenuBar",
                 {"edit": edit_name}, None)
    state = {"probe_runs": [], "menu_samples": [], "mutations": []}
    readings = {}
    observations = {}
    target = reference = number = None
    send_probe = output_probe = parity = coverage = None
    pid = logic_pid()
    driver = E.Driver(binary=args.binary)
    presses = 0
    try:
        presses = open_mixer(driver)
        before = take_reading(ev, driver, pid, labels, lproj, "before")
        readings["before"] = before
        title = arrange_title(canon, lproj)
        shot_before = ev.shot(f"{prefix}/mixer-before", settle_region=band, window_title=title) if band else None
        parity, coverage = inspect_parity(ev, driver, lproj)
        observations["snapshot_id_parity"] = parity
        observations["coverage_never_complete_with_filters_unread"] = coverage
        observations["output_readable_per_strip"] = output_observation(before)

        target, reference = choose_target(before, labels)
        ev.note(f"{prefix}/target", {"strip": target, "track_ref": reference})
        if target is not None and edit_name:
            tree_nodes = before["tree"]["nodes"]
            send_button = before["witness"]["strips"][target]["sends"][0]
            send_index = probe_slot_index(tree_nodes, send_button["global_index"], send_button["help"])
            listing = run_probe(probe_binary, send_button["help"], send_index, labels["trackMuteButton"]) \
                if send_index is not None else {"exit": None, "titles": [], "control_mute_moved": None}
            state["probe_runs"].append({"label": "send-titles", "control_mute_moved": listing["control_mute_moved"]})
            state["menu_samples"].append(menu_sample("send-titles"))
            number, bus_title, why = choose_bus(listing["titles"], before, labels)
            ev.note(f"{prefix}/send/menu", {"probe_exit": listing["exit"], "slot_index": send_index,
                                           "titles": len(listing["titles"]), "bus_number": number,
                                           "why": why})
            if number:
                send_probe, after, undone, send_restored = mutate_and_undo(
                    ev, driver, pid, labels, lproj, "send", probe_binary, send_button["help"],
                    send_index, bus_title, edit_name, before,
                    lambda mixer: (send_states(product_strips(mixer).get(target)) or [None])[0] in OCCUPIED,
                    state)
                readings["send-after"], readings["send-after-undo"] = after, undone
                if shot_before and after:
                    shot_after = ev.shot(f"{prefix}/mixer-after-send", settle_region=band, window_title=title)
                    ev.visual(f"{prefix}/the-send-grows-a-knob-in-the-mixer", shot_before["file"],
                              shot_after["file"], band, expect_change=True, subject=subject,
                              why="a send assigned in slot 0 of one strip adds its Send Level knob")
                observations["send_assignment_then_undo"] = send_mutation_observation(
                    target, send_probe, before, after, undone)

                output_button = before["witness"]["strips"][target]["outputs"][0]
                output_index = probe_slot_index(tree_nodes, output_button["global_index"], output_button["help"])
                if send_restored and output_index is not None:
                    out_listing = run_probe(probe_binary, output_button["help"], output_index,
                                            labels["trackMuteButton"])
                    state["probe_runs"].append({"label": "output-titles",
                                                "control_mute_moved": out_listing["control_mute_moved"]})
                    state["menu_samples"].append(menu_sample("output-titles"))
                    out_titles = [t for t in out_listing["titles"]
                                  if bus_number(t, labels["busOutputLabelPrefix"]) == number]
                    ev.note(f"{prefix}/output/menu", {"probe_exit": out_listing["exit"],
                                                      "slot_index": output_index,
                                                      "titles": len(out_listing["titles"]),
                                                      "bus_titles_for_number": len(out_titles)})
                    if len(out_titles) == 1:
                        output_probe, out_after, out_undone, _ = mutate_and_undo(
                            ev, driver, pid, labels, lproj, "output", probe_binary, output_button["help"],
                            output_index, out_titles[0], edit_name, before,
                            lambda mixer: bus_number((product_strips(mixer).get(target) or {}).get("output"),
                                                     labels["busOutputLabelPrefix"]) == number,
                            state)
                        readings["output-after"], readings["output-after-undo"] = out_after, out_undone
                        observations["bus_output_then_undo"] = output_mutation_observation(
                            target, reference, number, output_probe, before, out_after, out_undone)
        final = take_reading(ev, driver, pid, labels, lproj, "final")
        readings["final"] = final
        if shot_before:
            shot_final = ev.shot(f"{prefix}/mixer-final", settle_region=band, window_title=title)
            ev.visual(f"{prefix}/the-mixer-is-as-it-was", shot_before["file"], shot_final["file"], band,
                      expect_change=False, subject=subject,
                      why="every mutation was undone through Logic's Edit menu")
        observations["send_slot_count_matches_witness"] = slots_observation(list(readings.values()))
        observations["occupancy_matches_knob_witness"] = slots_observation(list(readings.values()))
        observations["positive_control_mute"] = {"probe_runs": state["probe_runs"]}
        observations["menus_closed_and_modal_clean"] = {"samples": [
            {"label": s["label"], "open_menus": s["open_menus"], "modal": s["modal"]}
            for s in state["menu_samples"]]}
        observations["restored"] = {"mutations": state["mutations"]}
    except Exception as exc:  # noqa: BLE001 - recorded; every check below still runs and fails
        ev.note(f"{prefix}/harness-exception", repr(exc))
    finally:
        ev.restored(f"{prefix}/the-mixer-pane-is-as-it-was", put_mixer_back(driver, presses),
                    json.dumps({"x_presses": presses}))
        driver.close()

    for check in CHECKS:
        observation = observations.get(check)
        if observation is None:
            observation = {"not_run": "an earlier step did not produce this observation"}
        ev.falsifiable(f"{prefix}/{check}", PREDICATES[check], observation,
                       COUNTER[check](observation) if "not_run" not in observation else observation,
                       EXPECTED[check], mutation=MUTATIONS[check])
    ev.note(f"{prefix}/summary", summary_of(lproj, readings, target, number, send_probe, output_probe,
                                             parity, coverage, state))


# ---------------------------------------------------------------------------------------------
# Self-test: every predicate against a positive fixture and its derived counterexample
# ---------------------------------------------------------------------------------------------

def _fixture_labels():
    return {"outputSlotHelpKeyword": ["output slot"], "inputSlotHelpKeyword": ["input slot"],
            "sendSlotHelpKeyword": ["Send slot"], "sendLevelKnobHelpKeyword": ["Send Level knob"],
            "busOutputLabelPrefix": ["bus", "バス"], "trackMuteButton": ["Mute"], "editMenuBar": ["Edit"]}


def _fixture_tree():
    """A window with an Inspector (two strips) and a Mixer (three), in pre-order."""
    rows = [
        ([0], "AXWindow", "", ""),
        ([0, 0], "AXGroup", "", ""),
        ([0, 0, 0], AX_LAYOUT_ITEM, "", ""),
        ([0, 0, 0, 0], AX_BUTTON, "Send slot. Route", "send button"),
        ([0, 0, 1], AX_LAYOUT_ITEM, "", ""),
        ([0, 1], "AXGroup", "", ""),
        ([0, 1, 0], AX_LAYOUT_ITEM, "", ""),
        ([0, 1, 0, 0], AX_BUTTON, "Input slot. Choose", "Input 1"),
        ([0, 1, 0, 1], AX_BUTTON, "Send slot. Route", "send button"),
        ([0, 1, 0, 2], AX_SLIDER, "Send Level knob. Set", "send knob"),
        ([0, 1, 0, 3], AX_BUTTON, "Send slot. Route", "send button"),
        ([0, 1, 0, 4], AX_BUTTON, "Output slot. Click", "Stereo Output"),
        ([0, 1, 1], AX_LAYOUT_ITEM, "", ""),
        ([0, 1, 1, 0], AX_BUTTON, "Send slot. Route", "send button"),
        ([0, 1, 1, 1], AX_BUTTON, "Output slot. Click", "Bus 3"),
        ([0, 1, 2], AX_LAYOUT_ITEM, "", ""),
        ([0, 1, 2, 0], AX_BUTTON, "Input slot. Choose", "Bus 3"),
        ([0, 1, 2, 1], AX_BUTTON, "Output slot. Click", "Stereo Output"),
    ]
    return {"nodes": [{"path": p, "depth": len(p) - 1, "role": r, "help": h, "description": d,
                       "read_errors": []} for p, r, h, d in rows], "children_read_failures": []}


def _fixture_reading(label="before", occupied_first=True):
    labels = _fixture_labels()
    tree = _fixture_tree()
    if not occupied_first:
        tree["nodes"] = [n for n in tree["nodes"] if n["role"] != AX_SLIDER]
    mixer = {"data_source": FRESH, "strips": [
        {"trackIndex": 0, "output": "Stereo Output", "input": "Input 1",
         "send_slots": [{"ordinal": 0, "state": SLOT_OCCUPIED_UNKNOWN if occupied_first else SLOT_EMPTY,
                         "level_raw": None, "level_description": None},
                        {"ordinal": 1, "state": SLOT_EMPTY}]},
        {"trackIndex": 1, "output": "Bus 3", "send_slots": [{"ordinal": 0, "state": SLOT_EMPTY}]},
        {"trackIndex": 2, "output": "Stereo Output", "input": "Bus 3", "send_slots": []}],
        "routing_graph": {"snapshot_id": "snap_1_t2_m3_p1", "complete": False, "edges": [
            {"kind": EDGE_MAIN_OUTPUT, "source": "trk_b", "destination": "bus_3"}], "nodes": [
            {"id": "trk_a", "kind": "track", "output_classification": CLASS_PHYSICAL},
            {"id": "trk_b", "kind": "track", "output_classification": CLASS_BUS},
            {"id": "bus_3", "kind": KIND_BUS, "busNumber": 3}]}}
    return {"label": label, "mixer": mixer, "track_refs": {0: "trk_a", 1: "trk_b"},
            "witness": witness_of(tree, labels), "tree": tree, "answered": True, "fresh": True}


def _fixture_observations():
    occupied = _fixture_reading("send-after")
    empty = _fixture_reading("before", occupied_first=False)
    probe = {"exit": 0, "selected": "Bus 3"}
    graph_coverage = {d: {"state": "partial", "reasons": ["x"]} for d in DOMAINS}
    graph_coverage["bus_to_aux_input"] = {"state": "not_observed", "reasons": ["x"]}
    out_before = {"fresh": True, "output": "Stereo Output", "classification": CLASS_PHYSICAL,
                  "bus_nodes": [], "edges": []}
    out_after = {"fresh": True, "output": "Bus 3", "classification": CLASS_BUS,
                 "bus_nodes": [["bus_3", 3]], "edges": [[EDGE_MAIN_OUTPUT, "trk_a", "bus_3"]]}
    sig_before, sig_after = signature(empty), signature(occupied)
    return {
        "output_readable_per_strip": output_observation(occupied),
        "send_slot_count_matches_witness": slots_observation([empty, occupied, empty]),
        "occupancy_matches_knob_witness": slots_observation([empty, occupied, empty]),
        "send_assignment_then_undo": send_mutation_observation(0, probe, empty, occupied, empty),
        "bus_output_then_undo": {"target": 0, "target_ref": "trk_a", "bus_number": 3, "probe": probe,
                                 "before": out_before, "after": out_after,
                                 "after_undo": copy.deepcopy(out_before)},
        "snapshot_id_parity": {"attempts": [
            {"mixer_before": "snap_1_t2_m3_p1", "inspect": "snap_1_t2_m3_p2",
             "inspect_routing": "snap_1_t2_m3_p2", "mixer_after": "snap_1_t2_m3_p2",
             "mixer_coverage": graph_coverage, "inspect_graph": graph_coverage},
            {"mixer_before": "snap_1_t2_m4_p2", "inspect": "snap_1_t2_m4_p2",
             "inspect_routing": "snap_1_t2_m4_p2", "mixer_after": "snap_1_t2_m4_p2",
             "mixer_coverage": graph_coverage, "inspect_graph": copy.deepcopy(graph_coverage)}]},
        "coverage_never_complete_with_filters_unread": {
            "mixer_filters_unread": True, "graph_complete": False, "coverage": graph_coverage,
            "inspect_routing_coverage": "partial"},
        "positive_control_mute": {"probe_runs": [{"label": "a", "control_mute_moved": 1},
                                                 {"label": "b", "control_mute_moved": 1}]},
        "menus_closed_and_modal_clean": {"samples": [{"label": "a", "open_menus": [], "modal": None}]},
        "restored": {"mutations": [{"label": "send", "undo_exit": 0, "before": sig_before,
                                    "after": sig_after, "after_undo": copy.deepcopy(sig_before)}]},
    }


def _helper_cases():
    """The pure helpers the live run leans on, each with a case that would expose a regression."""
    labels = _fixture_labels()
    witness = witness_of(_fixture_tree(), labels)
    nodes = _fixture_tree()["nodes"]
    stdout = "\n".join(["slot destination: send button", "control mute moved: 1", "menus opened: 3",
                        "title: Bus 3", "title: Bus 12", "selected: skipped"])
    parsed = parse_probe(stdout)
    reading = _fixture_reading(occupied_first=False)
    return [
        ("bus_number reads a spaced and an unspaced member", bus_number("Bus 12", labels["busOutputLabelPrefix"]) == 12
         and bus_number("バス4", labels["busOutputLabelPrefix"]) == 4),
        ("bus_number refuses a renamed or bare label", bus_number("Busy 3", labels["busOutputLabelPrefix"]) is None
         and bus_number("Bus", labels["busOutputLabelPrefix"]) is None),
        ("witness picks the three-strip container, not the Inspector's two", witness["mixer_found"]
         and len(witness["strips"]) == 3 and witness["containers"][0][1] == 3),
        ("witness sees the knob after send 0 only", [s["knob_follows"] for s in witness["strips"][0]["sends"]]
         == [True, False] and witness["strips"][0]["knobs_after_a_send_button"] == 1),
        ("witness reads outputs and inputs per strip", [o["description"] for o in witness["strips"][1]["outputs"]]
         == ["Bus 3"] and [i["description"] for i in witness["strips"][2]["inputs"]] == ["Bus 3"]),
        ("probe index counts the Inspector's slots first", probe_slot_index(nodes, 8, "Send slot.") == 1),
        ("probe index refuses an element deeper than the probe walks",
         probe_slot_index([dict(nodes[3], depth=PROBE_DEPTH + 1)], 0, "Send slot.") is None),
        ("parse_probe keeps titles and reads a skipped select as none", parsed["titles"] == ["Bus 3", "Bus 12"]
         and parsed["selected"] is None and parsed["control_mute_moved"] == 1),
        ("choose_bus prefers the bus an input already receives",
         choose_bus(["Bus 3", "Bus 12"], reading, labels)[0] == 3),
        ("choose_target takes the audio strip with an empty slot 0", choose_target(reading, labels) == (0, "trk_a")),
        ("every check has a predicate, a counterexample builder and an expectation",
         set(PREDICATES) == set(COUNTER) == set(EXPECTED) == set(MUTATIONS) == set(CHECKS)),
    ]


def self_test():
    rows, failed = [], 0
    fixtures = _fixture_observations()
    for check in CHECKS:
        positive = fixtures[check]
        counter = COUNTER[check](positive)
        try:
            accepts = bool(PREDICATES[check](positive))
        except Exception as exc:  # noqa: BLE001
            accepts = f"raised {exc!r}"
        try:
            rejects = not PREDICATES[check](counter)
        except Exception as exc:  # noqa: BLE001 - a crash is not a rejection
            rejects = f"raised {exc!r}"
        ok = accepts is True and rejects is True and counter != positive
        failed += 0 if ok else 1
        rows.append((check, accepts, rejects, ok))
    for name, ok in _helper_cases():
        failed += 0 if ok else 1
        rows.append((name, "-", "-", bool(ok)))
    width = max(len(row[0]) for row in rows)
    print(f"{'case'.ljust(width)}  accepts-positive  rejects-counterexample  ok")
    for name, accepts, rejects, ok in rows:
        print(f"{name.ljust(width)}  {str(accepts):16}  {str(rejects):22}  {'ok' if ok else 'FAIL'}")
    print(f"self-test: {len(rows) - failed}/{len(rows)} passed")
    return 0 if failed == 0 else 1


# ---------------------------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------------------------

def arguments():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--worktree", default=os.path.dirname(os.path.dirname(HERE)))
    parser.add_argument("--head")
    parser.add_argument("--binary")
    parser.add_argument("--locale", action="append", dest="locales", metavar="lproj")
    parser.add_argument("--switch", action="store_true")
    parser.add_argument("--record-seconds", type=int)
    args = parser.parse_args()
    if args.self_test:
        return args
    args.locales = args.locales or [lproj for lproj, _ in LOCALES]
    unknown = [name for name in args.locales if name not in CODES]
    if unknown:
        parser.error(f"unknown lproj(s): {', '.join(unknown)}")
    if not os.environ.get("LPM_EVIDENCE_ROOT"):
        parser.error("LPM_EVIDENCE_ROOT must be set by the caller")
    if not args.head:
        head = subprocess.run(["git", "-C", args.worktree, "rev-parse", "HEAD"], capture_output=True, text=True)
        args.head = (head.stdout or "").strip()
    if not re.fullmatch(r"[0-9a-f]{40}", args.head or ""):
        parser.error("head must be a full lowercase 40-character SHA")
    args.binary = args.binary or os.path.join(args.worktree, ".build", "release", "LogicProMCP")
    if not os.access(args.binary, os.X_OK):
        parser.error(f"binary is not executable: {args.binary}")
    return args


def main():
    args = arguments()
    if args.self_test:
        return self_test()
    sys.path.insert(0, os.path.join(args.worktree, "Scripts"))
    import logic_canon  # noqa: E402

    E.REPO, E.BIN = args.worktree, args.binary
    missing = E.have_tools()
    if missing:
        sys.exit(f"cannot run: missing {missing}")
    labels = {name: E.label_set(name, repo=args.worktree) or [] for name in LABEL_SETS}
    ev = E.Evidence(args.head, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")
    ev.note(f"{TAG}/label-sets", labels)
    probe_binary, build_error = build_probe(ev.dir)
    ev.note(f"{TAG}/probe-build", {"binary": probe_binary, "error": build_error})
    starting_language = language_setting()
    recording = ev.record_screen(seconds=args.record_seconds or (60 + 240 * len(args.locales)))
    switched_any = False
    try:
        for lproj in args.locales:
            language = switch_to(logic_canon, lproj) if args.switch else language_is(logic_canon, lproj)
            switched_any = switched_any or bool(language.get("switched"))
            ev.note(f"{TAG}/{lproj}/language", language)
            active = bool(language.get("active"))
            ev.check(f"{TAG}/{lproj}/locale-is-active", active,
                     "Logic is in this language on the fixture (AppleLanguages and the arrange window's "
                     "title, whose suffix is Apple's Tracks row); a locale that is not is NOT RUN",
                     {k: language.get(k) for k in ("active", "arrange_window", "language_setting", "switched")},
                     None)
            if not active or not probe_binary:
                continue
            band, subject = ev.located_band("Mixer", "--role", "AXLayoutArea", "--min-width", "600")
            run_locale(ev, args, logic_canon, labels, lproj, probe_binary, band, subject)
    except Exception as exc:  # noqa: BLE001 - recorded and failed, then the language is put back
        ev.note(f"{TAG}/harness-exception", repr(exc))
        ev.check(f"{TAG}/harness-completed", False, "every requested locale ran", repr(exc), None)
    finally:
        if args.switch and switched_any and starting_language:
            first = starting_language[0]
            back = next((lproj for lproj, code in LOCALES if code == first), None)
            restored = switch_to(logic_canon, back) if back else {"error": "starting language not in LOCALES"}
            ev.restored(f"{TAG}/logic-language-is-as-it-was", bool(restored.get("active")),
                        json.dumps(restored, ensure_ascii=False)[:600])
        ev.stop_recording(recording)
    out = ev.write()
    print(json.dumps(out, indent=1))
    return 0 if E.is_clean(out) else 1


if __name__ == "__main__":
    sys.exit(main())
