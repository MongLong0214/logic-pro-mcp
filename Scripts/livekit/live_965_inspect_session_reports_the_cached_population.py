#!/usr/bin/env python3
"""Live proof that `logic_project inspect_session` reports the population the product already read (#965).

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_965_inspect_session_reports_the_cached_population.py <worktree> <full-40-char-head-sha> [binary]

`binary` defaults to `<worktree>/.build/release/LogicProMCP`. Pass a copy at a fresh path when the
build directory may be serving a stale image.

WHAT IS UNDER TEST
------------------
`inspect_session` (operation `project.inspect_session`, schema `logic_pro_mcp_session_population.v1`)
builds its report from the state cache alone: `SessionPopulationObservation.capture` reads the cache
and the target registry once, and `build` turns that into per-domain `coverage` plus `reasons`. The
unit suite proves `build` against fixtures. Only a run against a real document can show that the
rows it reports are the rows the product's own resources hand out in the same server, that it does
not claim what the cache never saw, and that asking changes nothing in Logic.

WHAT THIS MEASURES
------------------
One fresh server. The Mixer is opened with X only when the product's own mixer read is not fresh
(the #291 harness's approach) and is put back the way it was at the end.

    the-report-lists-the-rows-logic-tracks-issues
        tracks.rows[].name and tracks.rows[].track_ref, in order, against logic://tracks data[].name
        and data[].track_ref read just before, with at least one trk_ reference among them;
        tracks.coverage `complete` with no reasons or `partial` with some
    strips-come-from-the-mixer-the-product-read
        strips.witnesses.count, len(strips.rows) and strips.rows[].strip_index against logic://mixer
        strips[] and strips[].trackIndex read just before, with that read fresh (data_source ax_poll);
        strips.coverage is not `complete` while strips.reasons names anything
    no-association-is-claimed-without-evidence
        associations.coverage is not `complete`, associations.reasons carries
        `no_observed_association_evidence`, overall.complete is false and overall.incomplete_domains
        names associations
    navigation-is-refused-before-anything-is-written
        allow_ui_navigation: true comes back isError with success false, state C, error
        not_implemented, write_attempted false and navigation_performed false
    inspecting-changes-nothing-in-logic
        Logic's window titles as System Events reads them off the AX tree (`name of windows`,
        through the shared `logic_variants.logic_window_names_probe`, read error kept) and
        logic://tracks row names, each read after a refresh_cache, are identical before and after
        three consecutive default calls, and all three calls returned a report (its `schema`)

A report whose coverage says `unstable` -- the cache or the registry moved while it was being read --
is asked for again, up to three times, and every attempt is recorded. That state is the report's own
"ask again", not a failure being retried around: the third answer still has to be something else.

Every 965/ predicate requires something only the command produces -- the report's `schema`, or for
the refusal its `not_implemented` error -- so a binary without the command (main before #965) fails
each of them with the unknown-command reply recorded, and only the precondition can pass.

WHAT THIS DOES NOT MEASURE
--------------------------
The `scope`, `domains` and `project_ref` parameters and the refusal of malformed ones (unit-tested);
whether any strip belongs to any track (the report claims no association, and that is what is
asserted); hidden tracks and collapsed stack children, which the cache cannot see and the report
names as reasons rather than rows.
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import evidence as E  # noqa: E402
import logic_variants  # noqa: E402


COVERS = [
    "Sources/LogicProMCP/Workflows/SessionPopulationObservation.swift",
    "Sources/LogicProMCP/Dispatchers/ProjectDispatcher.swift",
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

# The product's own wire tokens (SessionPopulationObservation.swift, HonestContract.swift,
# ResourceHandlers.mixerDataSource), serialised by this repository. None of them is a Logic UI label,
# and they are named here so no comparison below spells one inline.
SCHEMA = "logic_pro_mcp_session_population.v1"
COMPLETE, PARTIAL, UNSTABLE = "complete", "partial", "unstable"
COVERAGES = (COMPLETE, PARTIAL, "unavailable", UNSTABLE)
TRACKS, STRIPS, ASSOCIATIONS, HIERARCHY = "tracks", "strips", "associations", "hierarchy"
DOMAINS = (TRACKS, STRIPS, ASSOCIATIONS, HIERARCHY)
NO_ASSOCIATION_EVIDENCE = "no_observed_association_evidence"
STATE_C = "C"
NOT_IMPLEMENTED = "not_implemented"
FRESH_MIXER = "ax_poll"
TRACK_REF_PREFIX = "trk_"
INSPECT_ATTEMPTS = 3


def rows_of(value):
    """The dictionaries in a JSON array, or [] when the value is not one."""
    return [r for r in value if isinstance(r, dict)] if isinstance(value, list) else []


def section(report, domain):
    """One block of a report, or {} when the reply carries none (an error reply, an older binary)."""
    value = report.get(domain) if isinstance(report, dict) else None
    return value if isinstance(value, dict) else {}


def tracks_resource(d, label):
    """logic://tracks as the product hands it out: row names and trk_ references, in rail order."""
    body = d.resource("logic://tracks") or {}
    rows = rows_of(body.get("data"))
    read = {"readable": body.get("readable"), "source": body.get("source"),
            "complete": body.get("complete"), "reason": body.get("reason"),
            "names": [r.get("name") for r in rows],
            "track_refs": [r.get("track_ref") for r in rows]}
    ev.note(f"965/{label}", read)
    return read


def mixer_resource(d, label):
    """logic://mixer's strips, by the `trackIndex` each is keyed on, and the poll freshness it states."""
    body = d.resource("logic://mixer") or {}
    strips = rows_of(body.get("strips"))
    read = {"data_source": body.get("data_source"), "cache_age_sec": body.get("cache_age_sec"),
            "strip_count": len(strips), "strip_indices": [s.get("trackIndex") for s in strips]}
    ev.note(f"965/{label}", read)
    return read


def mixer_is_open(d):
    """The product's own answer: `data_source` is `ax_poll` only when its poll found the Mixer."""
    return (d.resource("logic://mixer") or {}).get("data_source") == FRESH_MIXER


def press_x():
    """Logic's Mixer toggle is the X key in every language; no menu name to translate."""
    subprocess.run(["osascript", "-e", 'tell application "Logic Pro" to activate', "-e", "delay 0.5",
                    "-e", 'tell application "System Events" to keystroke "x"'],
                   capture_output=True, text=True)


def open_mixer(d):
    """The #291 approach: press X only when the product's own mixer read is not fresh."""
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


def unstable(report):
    """Whether any domain says the cache or the registry moved while this report was read."""
    return any(section(report, domain).get("coverage") == UNSTABLE for domain in DOMAINS)


def inspect(d, label, params=None):
    """One report, asked again only while it says `unstable`; every attempt is recorded."""
    attempts = []
    report = {}
    for _ in range(INSPECT_ATTEMPTS):
        reply = d.tool("logic_project", "inspect_session", params)
        report = reply if isinstance(reply, dict) else {"_reply": reply}
        attempts.append({"schema": report.get("schema"),
                         "coverage": {domain: section(report, domain).get("coverage")
                                      for domain in DOMAINS}})
        if not unstable(report):
            break
    ev.note(f"965/{label}", {"attempts": attempts, "reply": report})
    return report


def window_titles():
    """Logic's windows by title through the shared System Events reader, its read error kept.

    `logic_variants.logic_window_names_probe` splits on line feeds rather than commas, so a project
    name with a comma is one window, and it returns the osascript error beside the names, so a read
    that failed twice is not two equal empty lists.
    """
    titles, error = logic_variants.logic_window_names_probe()
    return {"titles": list(titles), "error": error}


def logic_as_seen(d, label):
    """Window titles and logic://tracks row names, after a refresh so the rail read is current."""
    d.tool("logic_system", "refresh_cache")
    windows = window_titles()
    rail = tracks_resource(d, label)
    return windows, rail["names"]


def rows_are_the_issued_rows(o):
    refs = o["report_refs"]
    reasons = o["reasons"]
    coverage = o["coverage"]
    return (o["schema"] == SCHEMA
            and bool(o["report_names"])
            and o["report_names"] == o["resource_names"]
            and refs == o["resource_refs"]
            and any(isinstance(r, str) and r.startswith(TRACK_REF_PREFIX) for r in refs)
            and all(r is None or (isinstance(r, str) and r.startswith(TRACK_REF_PREFIX)) for r in refs)
            and isinstance(reasons, list)
            and ((coverage == PARTIAL and bool(reasons)) or (coverage == COMPLETE and not reasons)))


def strips_are_the_mixers(o):
    reasons = o["reasons"]
    return (o["schema"] == SCHEMA
            and o["mixer_data_source"] == FRESH_MIXER
            and o["mixer_strip_count"] > 0
            and o["report_strip_count"] == o["mixer_strip_count"]
            and o["report_strip_rows"] == o["mixer_strip_count"]
            and o["report_strip_indices"] == o["mixer_strip_indices"]
            and o["coverage"] in COVERAGES
            and isinstance(reasons, list)
            and not (o["coverage"] == COMPLETE and reasons))


def no_association_is_claimed(o):
    block = o["associations"] if isinstance(o["associations"], dict) else {}
    overall = o["overall"] if isinstance(o["overall"], dict) else {}
    return (o["schema"] == SCHEMA
            and block.get("coverage") in COVERAGES
            and block.get("coverage") != COMPLETE
            and NO_ASSOCIATION_EVIDENCE in (block.get("reasons") or [])
            and overall.get("complete") is False
            and ASSOCIATIONS in (overall.get("incomplete_domains") or []))


def refused_before_writing(o):
    payload = o["payload"] if isinstance(o["payload"], dict) else {}
    return (o["is_error"] is True
            and payload.get("success") is False
            and payload.get("state") == STATE_C
            and payload.get("error") == NOT_IMPLEMENTED
            and payload.get("write_attempted") is False
            and payload.get("navigation_performed") is False)


def nothing_moved(o):
    return (len(o["calls"]) == 3
            and all(call["schema"] == SCHEMA for call in o["calls"])
            and o["windows_before_error"] is None
            and o["windows_after_error"] is None
            and bool(o["windows_before"])
            and o["windows_after"] == o["windows_before"]
            and bool(o["tracks_before"])
            and o["tracks_after"] == o["tracks_before"])


# ---- One fresh server; the product must see a document and a fresh Mixer ------------------------
d = E.Driver()
time.sleep(5)
presses = open_mixer(d)
d.tool("logic_system", "refresh_cache")
seen = tracks_resource(d, "precondition-tracks")
mixer_fresh = mixer_is_open(d)
ev.check("965/precondition-the-product-can-see-the-document-and-the-mixer",
         seen["readable"] is True and bool(seen["names"]) and mixer_fresh,
         "logic://tracks reports a live read of a non-empty rail and logic://mixer a fresh poll, so "
         "the reports below are compared against a real document and a visible Mixer rather than "
         "the cold cache",
         {"x_presses": presses, "tracks_readable": seen["readable"], "tracks_source": seen["source"],
          "rows": len(seen["names"]), "mixer_fresh": mixer_fresh}, None)

# ---- 1. The report's rows are logic://tracks' rows, under the same references ------------------
issued = tracks_resource(d, "tracks-before-the-report")
first = inspect(d, "report-with-default-params")
first_tracks = section(first, TRACKS)
first_rows = rows_of(first_tracks.get("rows"))
rows = {
    "schema": first.get("schema"),
    "resource_names": issued["names"],
    "resource_refs": issued["track_refs"],
    "report_names": [r.get("name") for r in first_rows],
    "report_refs": [r.get("track_ref") for r in first_rows],
    "coverage": first_tracks.get("coverage"),
    "reasons": first_tracks.get("reasons"),
}
# In full here: `falsifiable` keeps only the first 400 characters of its observation.
ev.note("965/rows-compared", rows)
ev.falsifiable(
    "965/the-report-lists-the-rows-logic-tracks-issues",
    rows_are_the_issued_rows,
    rows,
    {**rows, "report_refs": [r.replace(TRACK_REF_PREFIX, TRACK_REF_PREFIX + "0", 1)
                             if isinstance(r, str) else r for r in rows["report_refs"]]},
    "a default inspect_session, taken right after a logic://tracks read in the same server, lists "
    "the same row names in the same order under the same trk_ references, and its tracks coverage "
    "is complete, or partial with its reasons named. THE COUNTEREXAMPLE is the same rows under "
    "references a second issuer minted",
    mutation="hand SessionPopulationObservation.capture a TargetRegistry of its own instead of the "
             "server's, so it mints references logic://tracks never issued",
)

# ---- 2. The report's strips are the strips logic://mixer published ----------------------------
presses += open_mixer(d)
mixer = mixer_resource(d, "mixer-before-the-report")
second = inspect(d, "report-with-a-fresh-mixer")
second_strips = section(second, STRIPS)
second_rows = rows_of(second_strips.get("rows"))
witnesses = second_strips.get("witnesses") if isinstance(second_strips.get("witnesses"), dict) else {}
strips = {
    "schema": second.get("schema"),
    "mixer_data_source": mixer["data_source"],
    "mixer_strip_count": mixer["strip_count"],
    "mixer_strip_indices": mixer["strip_indices"],
    "report_strip_count": witnesses.get("count"),
    "report_strip_rows": len(second_rows),
    "report_strip_indices": [r.get("strip_index") for r in second_rows],
    "report_strips_source": section(second, "sources").get(STRIPS),
    "coverage": second_strips.get("coverage"),
    "reasons": second_strips.get("reasons"),
}
ev.note("965/strips-compared", strips)
ev.falsifiable(
    "965/strips-come-from-the-mixer-the-product-read",
    strips_are_the_mixers,
    strips,
    {**strips, "report_strip_count": 0, "report_strip_rows": 0, "report_strip_indices": []},
    "with logic://mixer fresh (data_source ax_poll) and publishing strips, the report taken right "
    "after it counts the same strips, in rows keyed by the same trackIndex values, and its strips "
    "coverage is not complete while it names any reason. THE COUNTEREXAMPLE is a report that counted "
    "no strips beside a mixer resource that published them",
    mutation="build the report's strips from a second mixer read, or from none, instead of the "
             "snapshot.channelStrips the capture took from the cache logic://mixer reads",
)

# ---- 3. No strip is associated with a track the report did not observe together ----------------
associations = {"schema": first.get("schema"), "associations": first.get(ASSOCIATIONS),
                "overall": first.get("overall")}
ev.note("965/associations-and-overall", associations)
ev.falsifiable(
    "965/no-association-is-claimed-without-evidence",
    no_association_is_claimed,
    associations,
    {**associations, "associations": {"coverage": COMPLETE, "reasons": []}},
    "the default report's associations coverage is not complete and names "
    "no_observed_association_evidence, and overall.complete is false with associations among the "
    "incomplete domains. THE COUNTEREXAMPLE is an associations block claiming complete coverage, "
    "which only an ordinal strip-to-track join could have produced",
    mutation="have SessionPopulationObservation.build mark associations complete by joining "
             "strip.trackIndex to track.id",
)

# ---- 4. Navigation is refused, and says it wrote nothing --------------------------------------
raw = d._send("tools/call", {"name": "logic_project",
                             "arguments": {"command": "inspect_session",
                                           "params": {"allow_ui_navigation": True}}})
result = raw.get("result") if isinstance(raw, dict) else None
payload = E._body(raw)
refusal = {"is_error": result.get("isError") if isinstance(result, dict) else None,
           "payload": payload if isinstance(payload, dict) else {"_payload": payload}}
ev.note("965/navigation-refusal-raw-reply", {"raw": raw})
ev.falsifiable(
    "965/navigation-is-refused-before-anything-is-written",
    refused_before_writing,
    refusal,
    {**refusal, "payload": {**refusal["payload"], "write_attempted": True}},
    "inspect_session with allow_ui_navigation true comes back as an error result whose payload is "
    "State C not_implemented with write_attempted false and navigation_performed false. THE "
    "COUNTEREXAMPLE is the same refusal reporting that a write was attempted",
    mutation="drop the allow_ui_navigation guard in ProjectDispatcher's inspect_session case, so the "
             "flag is parsed and the cache-only report comes back as a success",
)

# ---- 5. Three inspections leave Logic's windows and rail as they were --------------------------
windows_before, tracks_before = logic_as_seen(d, "tracks-before-three-inspections")
calls = []
for _ in range(3):
    reply = d.tool("logic_project", "inspect_session")
    reply = reply if isinstance(reply, dict) else {"_reply": reply}
    calls.append({"schema": reply.get("schema"), "read_only": reply.get("read_only"),
                  "snapshot_id": reply.get("snapshot_id"), "ui_effects": reply.get("ui_effects"),
                  "state": reply.get("state"), "error": reply.get("error"), "hint": reply.get("hint")})
windows_after, tracks_after = logic_as_seen(d, "tracks-after-three-inspections")
unchanged = {
    "calls": calls,
    "windows_before": windows_before["titles"], "windows_before_error": windows_before["error"],
    "windows_after": windows_after["titles"], "windows_after_error": windows_after["error"],
    "tracks_before": tracks_before, "tracks_after": tracks_after,
}
ev.note("965/logic-before-and-after-three-inspections", unchanged)
ev.falsifiable(
    "965/inspecting-changes-nothing-in-logic",
    nothing_moved,
    unchanged,
    {**unchanged, "windows_after": unchanged["windows_before"] + unchanged["windows_before"][:1]},
    "three consecutive default inspect_session calls each return a report, and Logic's window "
    "titles and logic://tracks row names read after a refresh are identical before and after them. "
    "THE COUNTEREXAMPLE is one more window after the calls than before",
    mutation="let SessionPopulationObservation.capture refresh the tracks it reports by driving the "
             "UI (a poll that expands a collapsed stack, or opens the Mixer) instead of reading the cache",
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
ev.restored("965/the-mixer-pane-is-as-it-was", closed_again, json.dumps({"x_presses": presses}))

d.close()
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
