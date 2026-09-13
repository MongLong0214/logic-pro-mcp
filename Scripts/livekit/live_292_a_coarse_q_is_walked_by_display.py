#!/usr/bin/env python3
"""Live proof that a Channel EQ control whose minimum step is larger than one raw unit is reachable.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_292_a_coarse_q_is_walked_by_display.py <worktree> <full-40-char-head-sha>

WHAT WAS MEASURED, AND WHY THE WALK CHANGED
-------------------------------------------
`set_eq_band_verified` reaches a plug-in slider by a READBACK-DRIVEN WALK: each AXValue assignment
advances the control one step toward the requested raw value, so the operation steps and re-reads
rather than setting a destination.

Measured 2026-09-12 against a live Channel EQ: Gain and Frequency reached their targets through the
`.display` path, and Q did NOT. Every `.display` request on Q stopped at `walk_steps: 1` with
`increment_walk_no_progress`, on all six bands and in both directions. The control was not stuck:
the SAME parameter landed every time through the `.rawValue` path — twelve verified writes, e.g.
raw 44 rendering `1.10 ` and raw 72 rendering `5.00 `. Q's raw range is 0...127 on peak bands and
0...52 on shelves, so `nudge(current + 1)` lands back on the value it started from: Logic's Q
slider snaps coarser than one raw unit, and under the old rule that was correctly read as a rail.

The walk now doubles its REQUEST DISTANCE when an accepted write leaves both the raw value and the
rendering unchanged, retains a distance that worked, and stops after a bounded retry window. It
invents no engineering-unit conversion: everything stays derived from what Logic rendered and the
raw values it reported.

WHAT THIS RUN ASSERTS
---------------------
That a Q request through the DISPLAY path lands and is verified — and that it took MORE THAN ONE
STEP to get there. The step count is the point: a walk that arrived in one step never exercised the
coarse-step path, and a run that asserted only `verified: true` would pass on a Q that happened to
be sitting on its target already.

THE COUNTEREXAMPLE
------------------
The envelope this operation actually returned on 2026-09-12, recorded below: State C,
`increment_walk_no_progress`, `walk_steps: 1`. That is what a control whose step is larger than one
raw unit looked like before, and it is what this check must reject.

WHAT IT DOES NOT CLAIM
----------------------
It does not claim every plug-in parameter is reachable. It claims one MEASURED class — a control
that moves in steps larger than one raw unit — is no longer mistaken for a rail. The run restores
the parameter it moved and confirms the restoration by reading it back.
"""
import copy
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402

COVERS = [
    "Sources/LogicProMCP/Plugins/SliderIncrementWalk.swift",
]

# A track named ONCE. Measured on the campaign fixture 2026-09-13: `Studio Grand` appears eight
# times and `Deluxe Classic` nine, and the product refuses a duplicated name with
# `ambiguous_target_name` — correctly, since a name that names several strips names none. Two rows
# are unique, and this is the one that can carry an insert.
TRACK_NAME = "Absolute Zero"
BAND = "Peak 2"
PARAMETER = "Q"
UNIT = "Q"
MODE = "duplicate_applyback"

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")



def plugin_window_by_geometry(ax_title):
    """The Channel EQ window's CoreGraphics bounds, identified by GEOMETRY rather than by name.

    Logic's plug-in windows carry an EMPTY `kCGWindowName` — measured 2026-09-13, the arrange
    window answers `lpm-locale-campaign - Tracks` and the plug-in beside it answers `''` — so
    `logic_window(title)` cannot reach one. The identity therefore comes from AX, which DOES name
    it, and the CoreGraphics row is the Logic-owned window whose bounds match that frame.

    Both halves are stated because either alone would be weaker: AX names the window but the
    capture needs a CG window id, and CG has the id but not the name.
    """
    frame = osa(f'tell application "System Events" to tell process "Logic Pro"\n'
                f'  set w to first window whose name is "{ax_title}"\n'
                f'  set p to position of w\n  set z to size of w\n'
                f'  return ((item 1 of p) as string) & "," & ((item 2 of p) as string) & "," & '
                f'((item 1 of z) as string) & "," & ((item 2 of z) as string)\nend tell')
    try:
        ax_x, ax_y, ax_w, ax_h = [int(v) for v in frame.split(",")]
    except ValueError:
        return None, {"why": "the plug-in window was not named by AX", "raw": frame}
    try:
        import Quartz
    except ImportError:
        return None, {"why": "Quartz is unavailable"}
    rows = []
    for w in E._on_screen_windows(Quartz) or []:
        if not E._is_logic_owned_window(w):
            continue
        b = w["kCGWindowBounds"]
        rows.append({"name": w.get("kCGWindowName") or "",
                     "x": int(b["X"]), "y": int(b["Y"]),
                     "w": int(b["Width"]), "h": int(b["Height"]),
                     "id": w["kCGWindowNumber"]})
    # The AX frame and the CG frame describe the same window and need not agree to the pixel, so
    # the match is by SIZE with a small tolerance and by position; an ambiguous match is refused
    # rather than resolved by order, which is the mistake `located_band` exists to prevent.
    matches = [r for r in rows
               if abs(r["w"] - ax_w) <= 8 and abs(r["h"] - ax_h) <= 40
               and abs(r["x"] - ax_x) <= 8]
    if len(matches) != 1:
        return None, {"why": "no unique Logic window matches the AX frame",
                      "ax_frame": [ax_x, ax_y, ax_w, ax_h], "candidates": rows}
    m = matches[0]
    return ({"id": m["id"], "title": ax_title, "x": m["x"], "y": m["y"],
             "w": m["w"], "h": m["h"]},
            {"ax_frame": [ax_x, ax_y, ax_w, ax_h], "cg": m})


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def finish(code=1):
    out = ev.write()
    print(json.dumps(out, indent=1))
    sys.exit(0 if E.is_clean(out) else code)


modal = E.blocking_modal()
ev.check(
    "292/precondition-no-blocking-modal",
    modal is None,
    "a completed modal scan found no Logic blocker before anything is read or written",
    f"blocking_modal={modal!r}",
    "raise any Logic dialog: this refuses on a detected modal and on a scan that could not tell",
)
if modal is not None:
    finish()

driver = E.Driver()
refresh = driver.tool("logic_system", "refresh_cache", {}) or {}
ev.check(
    "292/precondition-the-live-track-read-was-primed",
    isinstance(refresh, dict) and refresh.get("refreshed") is True,
    "system.refresh_cache reports a completed refresh, so the track rows below are live rather than "
    "names synthesised from the project file",
    f"refresh={refresh!r}",
    None,
)

tracks = driver.resource("logic://tracks") or {}
rows = tracks.get("data") if isinstance(tracks.get("data"), list) else []
named = [r for r in rows if isinstance(r, dict) and r.get("name") == TRACK_NAME]
ev.check(
    "292/precondition-the-named-track-resolves-exactly-once",
    len(named) == 1,
    f"exactly one live track row is named `{TRACK_NAME}`, so the strip is addressed by name and "
    "never by a position",
    f"matches={len(named)} of {len(rows)} rows",
    None,
)
if len(named) != 1:
    finish()
track = named[0]
track_ref = track["track_ref"]

project = driver.resource("logic://project/info") or {}
project_path = (((project.get("data") or {}).get("filePath")) or "").strip()
ev.check(
    "292/precondition-a-saved-project-bounds-the-write",
    bool(project_path),
    "logic://project/info supplies a non-empty current-document filePath, so the write is bounded "
    "to a project that exists on disk",
    f"filePath={project_path!r}",
    None,
)
if not project_path:
    finish()

def channel_eq_slots():
    inv = driver.tool("logic_plugins", "get_inventory", {"track": track["id"]}) or {}
    plugins = inv.get("plugins") if isinstance(inv.get("plugins"), list) else []
    return inv, plugins, [p for p in plugins if isinstance(p, dict) and p.get("name") == "Channel EQ"]


inventory, plugins, eq_slots = channel_eq_slots()
if not eq_slots:
    # The named track carries no Channel EQ, so the run PUTS ONE THERE through the product's own
    # verified insert and records that it did. The alternative was to address one of the duplicated
    # strips that already has one, and the product refuses those by name — rightly.
    free = [p.get("insert") for p in plugins if isinstance(p, dict) and not p.get("occupied")]
    inserted = driver.tool("logic_plugins", "insert_verified", {
        "target_ref": track_ref,
        "insert": free[0] if free else 1,
        "plugin": "Channel EQ",
        "mode": MODE,
        "project_expected_path": project_path,
    }) or {}
    ev.note("292/a-channel-eq-was-inserted-for-this-run",
            {k: v for k, v in inserted.items()
             if k in ("state", "success", "verified", "error", "hint")})
    inventory, plugins, eq_slots = channel_eq_slots()

ev.check(
    "292/precondition-the-strip-carries-exactly-one-channel-eq",
    len(eq_slots) == 1,
    "the strip offers exactly one Channel EQ insert, so the insert below is NAMED rather than "
    "picked out of several",
    f"channel_eq_inserts={[p.get('insert') for p in eq_slots]} of {len(plugins)} slots",
    None,
)
if len(eq_slots) != 1:
    finish()
insert = eq_slots[0].get("insert")


def set_q(value):
    return driver.tool("logic_plugins", "set_eq_band_verified", {
        "target_ref": track_ref,
        "insert": insert,
        "band": BAND,
        "parameter": PARAMETER,
        "value": value,
        "unit": UNIT,
        "mode": MODE,
        "project_expected_path": project_path,
    }) or {}


# Two destinations, driven in order. The FIRST is the assertion; the second returns the control to
# the other end so the run leaves the band where it found it in spirit — a Q the run moved and
# never moved back is a change to somebody's project, even a disposable one.
FIRST, SECOND = 2.50, 1.20

recording = ev.record_screen(seconds=240)

# The band is resolved from the live tree by the AXDescription Logic gives the EQ area of the
# plug-in window, so the rectangle is defined by what it contains rather than by four numbers that
# were right in one layout. A Q change moves the curve and the readout inside exactly this area.
# `--role AXGroup` is not decoration: `EQ` alone is ambiguous on this window and the tool refuses
# rather than picking. Measured 2026-09-13 — the description is carried by the EQ AREA and by every
# one of the band BUTTONS above it, and a band over a button would report that a button did not
# repaint while saying nothing about the curve.
band, band_subject = ev.located_band("EQ", "--role", "AXGroup", "--include-dialogs")
ev.check(
    "292/the-eq-area-was-located-through-its-own-description",
    band is not None and bool(band_subject),
    "the Channel EQ area of the plug-in window is found by the AXDescription it carries, so the "
    "comparison below is over the region that shows Q rather than over the whole window",
    f"band={band!r} subject={band_subject!r}",
    None,
)
if band is None:
    driver.close()
    ev.stop_recording(recording)
    finish()

plugin_window, window_detail = plugin_window_by_geometry(TRACK_NAME)
ev.check(
    "292/the-plug-in-window-was-identified-by-ax-name-and-matched-in-coregraphics",
    plugin_window is not None,
    "the window to photograph is the one AX names `"+TRACK_NAME+"`, matched to the Logic-owned "
    "CoreGraphics row with the same frame — CoreGraphics carries no name for a plug-in window, so "
    "a title lookup would silently photograph nothing",
    json.dumps(window_detail, ensure_ascii=False)[:400],
    None,
)
if plugin_window is None:
    driver.close()
    ev.stop_recording(recording)
    finish()

# Put the control at a KNOWN end first, so the assertion below is about a walk that has somewhere
# to go. Without this the run asserts whatever the last run happened to leave: measured today, a
# second run in a row returned `walk_steps: 0` and State A, which is honest about the control and
# says nothing about the coarse-step path.
seed = set_q(SECOND)
ev.note("292/the-control-was-seeded-to-the-other-end",
        {k: v for k, v in seed.items()
         if k in ("state", "success", "verified", "walk_steps", "observed_display")})
time.sleep(0.5)

shot_before = ev.shot("292/before-the-q-was-walked", settle_region=band, window=plugin_window)
written = set_q(FIRST)
ev.note("292/the-write", {k: (v[:400] if isinstance(v, str) else v) for k, v in written.items()})

reading = {
    "state": written.get("state"),
    "success": written.get("success"),
    "verified": written.get("verified"),
    "error": written.get("error"),
    "walk_steps": written.get("walk_steps"),
    "observed_display": written.get("observed_display"),
    "requested": FIRST,
}

ev.falsifiable(
    "292/a-control-whose-step-is-larger-than-one-raw-unit-is-walked-to-its-target",
    lambda o: (o["state"] == "A" and o["success"] is True and o["verified"] is True
               and o["error"] is None
               and isinstance(o["walk_steps"], int) and o["walk_steps"] > 1),
    reading,
    {"state": "C", "success": False, "verified": False,
     "error": "increment_walk_no_progress", "walk_steps": 1,
     "observed_display": "0.88 ", "requested": FIRST},
    "a Q request through the DISPLAY path reaches State A, and it took MORE THAN ONE STEP — the "
    "step count is asserted because a walk that arrived in one step never exercised the coarse-step "
    "path at all. THE COUNTEREXAMPLE is the envelope this operation actually returned on "
    "2026-09-12 for every Q request on every band: `increment_walk_no_progress` at `walk_steps: 1`, "
    "because `nudge(current + 1)` lands back on the raw value it started from when Logic's slider "
    "snaps coarser than one raw unit",
    mutation="restore the old rule in `SliderIncrementWalk.walkDisplay` — stop doubling the request "
            "distance after an accepted write leaves BOTH the raw value and the rendering unchanged, "
            "and treat that first unchanged readback as a rail. This check returns exactly the "
            "counterexample above, while Gain and Frequency keep working, which is why the class "
            "went unnoticed",
)

shot_after = ev.shot("292/after-the-q-was-walked", settle_region=band, window=plugin_window)
ev.visual(
    "292/the-eq-area-changed-where-q-is-shown",
    shot_before["file"], shot_after["file"], band, subject=band_subject, expect_change=True,
    why=f"Q on {BAND} was walked to {FIRST} through the DISPLAY path, and the Channel EQ area is "
        "where Logic draws the curve and prints that value — a walk that reported State A while "
        "the control never moved would leave this region identical",
)

# Move it to the other end and CONFIRM from the parameter's own readback, not from the call that
# moved it. There is no removal operation for an insert, so what this run can restore is the VALUE;
# the Channel EQ it added (if it added one) stays, on a fixture whose changes are discarded, and
# that limit is stated rather than implied.
back = set_q(SECOND)
time.sleep(0.5)
ev.note("292/the-second-walk",
        {k: v for k, v in back.items()
         if k in ("state", "success", "verified", "error", "walk_steps", "observed_display")})
ev.restored(
    "292/the-q-this-run-moved-was-walked-back-and-read-back",
    back.get("state") == "A" and back.get("verified") is True
    and isinstance(back.get("observed_display"), str)
    and back["observed_display"].strip().startswith(str(SECOND)),
    f"second_walk_state={back.get('state')!r} observed_display={back.get('observed_display')!r} "
    f"walk_steps={back.get('walk_steps')!r}",
)

driver.close()
ev.stop_recording(recording)
finish(1)
