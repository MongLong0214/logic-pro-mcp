#!/usr/bin/env python3
"""Live proof that logic://mixer's routing graph no longer depends on what the client read first (#291).

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_291_mixer_graph_does_not_depend_on_read_order.py <worktree> <full-40-char-head-sha> [binary]

`binary` defaults to `<worktree>/.build/release/LogicProMCP`. Pass a copy at a fresh path when the
build directory may be serving a stale image.

WHAT WAS WRONG
--------------
docs/observations/2026-09-14-the-routing-graph-publishes-nothing-or-23-nodes-depending-on-read-order.json:
from a freshly started server, the first logic://mixer read published 0 nodes, with "no issued trk_
reference" for every strip; after one logic://tracks read the same project published 23. Only the
tracks reader bound track references, and the graph only looked them up. The graph's project
reference had the same shape: it appeared only after a logic://project/info read.

WHAT THIS MEASURES
------------------
Two fresh servers against the same open project, each reading in a different order:

    session A   mixer, then tracks, then mixer again, then project/info
    session B   tracks, then mixer

Session A's mixer read before logic://tracks is the one that used to be empty (the reads that
open the Mixer pane are mixer reads too, and none of them reads tracks). It must publish the same
track nodes as the read after logic://tracks, under the same trk_ references logic://tracks hands
out, and the same graph shape as session B, whose order is the one that always worked. Its
project reference must be the prj_ that logic://project/info issues afterwards in the same server.

References are compared within one server only: every server mints its own.

WHAT THIS DOES NOT MEASURE
--------------------------
Output destinations and sends: the graph still leaves them unresolved (R1/#965 and the send-slot
limit in the 2026-09-14 record), so edges are recorded, not asserted.
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


COVERS = [
    "Sources/LogicProMCP/State/TrackReferenceIssuance.swift",
    "Sources/LogicProMCP/State/ProjectReferenceIssuance.swift",
    "Sources/LogicProMCP/Resources/ResourceHandlers+StateReaders.swift",
    "Sources/LogicProMCP/Routing/RoutingGraphPublication.swift",
]

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = sys.argv[3] if len(sys.argv) > 3 else f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="non_ui")

UNISSUED_SOURCE = "no issued trk_ reference"
# RoutingGraph.swift's own node-kind enum, serialised by this repository; not a Logic UI label.
TRACK_NODE_KIND = "track"


def refs_in(value, prefix):
    """Every reference string with `prefix` anywhere inside `value`, in order of appearance."""
    found = []
    if isinstance(value, dict):
        for v in value.values():
            found += refs_in(v, prefix)
    elif isinstance(value, list):
        for v in value:
            found += refs_in(v, prefix)
    elif isinstance(value, str) and value.startswith(prefix):
        found.append(value)
    return found


def graph_of(body):
    graph = body.get("routing_graph") or {}
    nodes = graph.get("nodes") or []
    tracks = [n for n in nodes if n.get("kind") == TRACK_NODE_KIND]
    return {
        "data_source": body.get("data_source"),
        "strips": len(body.get("strips") or []),
        "nodes": len(nodes),
        "track_nodes": len(tracks),
        "track_refs": [r for n in tracks for r in refs_in(n.get("targetRef"), "trk_")],
        "shape": sorted((n.get("kind") or "", n.get("displayName") or "") for n in nodes),
        "edges": len(graph.get("edges") or []),
        "complete": graph.get("complete"),
        "partial_reason": graph.get("partialReason"),
        "project_ref": next(iter(refs_in(graph.get("projectReference"), "prj_")), None),
    }


def mixer(d, label):
    body = d.resource("logic://mixer") or {}
    g = graph_of(body)
    ev.note(f"291/{label}", {k: v for k, v in g.items() if k != "shape"} | {"shape": g["shape"][:40]})
    return g


def track_refs(d, label):
    body = d.resource("logic://tracks") or {}
    rows = [r for r in (body.get("data") or []) if isinstance(r, dict)]
    refs = [r["track_ref"] for r in rows if isinstance(r.get("track_ref"), str)]
    ev.note(f"291/{label}", {"readable": body.get("readable"), "rows": len(rows), "track_refs": refs})
    return refs


def mixer_is_open(d):
    """The product's own answer: `data_source` is `ax_poll` only when its poll found the Mixer."""
    return (d.resource("logic://mixer") or {}).get("data_source") == "ax_poll"


def press_x():
    """Logic's Mixer toggle is the X key in every language; no menu name to translate."""
    subprocess.run(["osascript", "-e", 'tell application "Logic Pro" to activate', "-e", "delay 0.5",
                    "-e", 'tell application "System Events" to keystroke "x"'],
                   capture_output=True, text=True)


def open_mixer(d):
    presses = 0
    for _ in range(2):
        d.tool("logic_system", "refresh_cache")
        if mixer_is_open(d):
            break
        press_x()
        presses += 1
        for _ in range(6):
            d.tool("logic_system", "refresh_cache")
            time.sleep(1)
            if mixer_is_open(d):
                break
    return presses


# ---- Session A: mixer first, in a fresh server ------------------------------------------------
d = E.Driver()
time.sleep(5)
presses = open_mixer(d)
ev.check("291/precondition-the-product-can-see-the-mixer", mixer_is_open(d),
         "the mixer resource reports a fresh poll, so the reads below are real reads of a visible "
         "Mixer and not the cold-cache answer",
         {"x_presses": presses}, None)
# The Mixer poll that opened the pane did not read logic://tracks: only resources the client asks
# for issue references, and nothing above asked for tracks.
d.tool("logic_system", "refresh_cache")
a1 = mixer(d, "a-mixer-first")
a_tracks = track_refs(d, "a-tracks")
a2 = mixer(d, "a-mixer-after-tracks")
info = d.resource("logic://project/info") or {}
# The body sits under the cache envelope's `data`.
info_data = info.get("data") if isinstance(info.get("data"), dict) else info
a_project = info_data.get("project_ref")
ev.note("291/a-project-info", {"project_ref": a_project, "name": info_data.get("name"),
                               "envelope_keys": sorted(info)})
d.close()

# ---- Session B: tracks first, in another fresh server -----------------------------------------
d = E.Driver()
time.sleep(5)
d.tool("logic_system", "refresh_cache")
b_tracks = track_refs(d, "b-tracks-first")
b1 = mixer(d, "b-mixer-after-tracks")

order = {
    "first_mixer_track_nodes": a1["track_nodes"],
    "after_tracks_track_nodes": a2["track_nodes"],
    "first_read_names_unissued_sources": UNISSUED_SOURCE in (a1["partial_reason"] or ""),
}
ev.falsifiable(
    "291/a-mixer-read-before-any-tracks-read-publishes-the-track-nodes",
    lambda o: (o["first_mixer_track_nodes"] > 0
               and o["first_mixer_track_nodes"] == o["after_tracks_track_nodes"]
               and not o["first_read_names_unissued_sources"]),
    order,
    {"first_mixer_track_nodes": 0, "after_tracks_track_nodes": 23, "first_read_names_unissued_sources": True},
    "a logic://mixer read taken in a fresh server before any logic://tracks read publishes as many "
    "track nodes as the read after logic://tracks, and names no strip as lacking an issued trk_ "
    "reference. THE COUNTEREXAMPLE is "
    "the 2026-09-14 reading: 0 nodes first, 23 after a tracks read",
    mutation="make RoutingGraphPublication look track references up instead of receiving the issued "
             "map (3147d410's TargetRefResolver.issuedTrackReference)",
)

same_refs = {
    "first_mixer_refs": a1["track_refs"],
    "after_tracks_mixer_refs": a2["track_refs"],
    "tracks_refs": a_tracks,
}
ev.falsifiable(
    "291/the-mixer-and-tracks-name-each-track-by-one-reference",
    lambda o: (bool(o["first_mixer_refs"])
               and o["first_mixer_refs"] == o["after_tracks_mixer_refs"]
               and set(o["first_mixer_refs"]) <= set(o["tracks_refs"])),
    same_refs,
    {**same_refs, "tracks_refs": [r.replace("trk_", "trk_0") for r in a_tracks]},
    "in one server, the trk_ references the first mixer read published are the ones the mixer "
    "publishes after logic://tracks and are all among the ones logic://tracks hands out. THE "
    "COUNTEREXAMPLE is two issuers minting different references for the same rows",
    mutation="bind track references in readMixer with a descriptor that differs from readTracks'",
)

shapes = {"mixer_first": {"shape": a1["shape"], "edges": a1["edges"]},
          "tracks_first": {"shape": b1["shape"], "edges": b1["edges"]}}
ev.falsifiable(
    "291/tracks-first-and-mixer-first-publish-the-same-graph",
    lambda o: bool(o["mixer_first"]["shape"]) and o["mixer_first"] == o["tracks_first"],
    shapes,
    {**shapes, "mixer_first": {"shape": [], "edges": 0}},
    "the graph a mixer-first server publishes has the same nodes, by kind and display name, and the "
    "same edge count as the graph a tracks-first server publishes. THE COUNTEREXAMPLE is the empty "
    "mixer-first graph",
    mutation="make RoutingGraphPublication look track references up instead of receiving the issued map",
)

project = {"mixer_project_ref": a1["project_ref"], "project_info_ref": a_project,
           "tracks_first_mixer_project_ref": b1["project_ref"]}
ev.falsifiable(
    "291/the-mixer-carries-the-project-ref-project-info-issues",
    lambda o: (isinstance(o["mixer_project_ref"], str)
               and o["mixer_project_ref"] == o["project_info_ref"]
               and isinstance(o["tracks_first_mixer_project_ref"], str)),
    project,
    {**project, "mixer_project_ref": None},
    "the first mixer read's projectReference, taken before any logic://project/info read, is the prj_ "
    "that logic://project/info issues afterwards in the same server; the tracks-first server's mixer "
    "carries one too. THE COUNTEREXAMPLE is the pre-change shape: no project reference until "
    "project/info has been read",
    mutation="have readMixer look the project reference up instead of issuing it",
)

# ---- Put the Mixer back the way it was --------------------------------------------------------
if presses % 2:
    press_x()
    for _ in range(6):
        d.tool("logic_system", "refresh_cache")
        time.sleep(1)
        if not mixer_is_open(d):
            break
closed_again = not mixer_is_open(d) if presses % 2 else mixer_is_open(d)
ev.restored("291/the-mixer-pane-is-as-it-was", closed_again, json.dumps({"x_presses": presses}))

d.close()
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
