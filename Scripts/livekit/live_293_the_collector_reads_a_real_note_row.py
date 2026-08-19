"""Live proof that the collector reads a real Event List note row — from the shipped binary.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_293_the_collector_reads_a_real_note_row.py <worktree> <full-40-char-head-sha>

WHY THIS EXISTS, AND WHY THE EARLIER ATTEMPT COULD NOT
------------------------------------------------------
The first harness for this fix proved only the PREMISE — that Logic leaves the Lock and Mute cells
empty — and scored ZERO mutation-backed checks, because Logic's cell-child counts do not change when
the product changes. The ship gate refused it, correctly: "a check that cannot fail is not evidence".

I read that as "this code has no caller, so live evidence is impossible". That was wrong twice.
`EventListMIDINoteReadbackProvider` does call `collect`. The real bind was narrower: `collect` needs a
`RegistryResolvedIdentityProof` whose only mint is compiled under a debug condition, so the RELEASE
binary — the one the gate hashes — contained the collector and could not construct its argument.

`--probe-event-list` closes exactly that gap. It is observation only: no identity mint, no
`assessReadback`, no MCP surface, `publicProvider()` still nil, the dark provider still dark. What it
does is run the same `readHeaders` / `readRows` / `readRow` path against live Logic, from the artifact
the gate hashes — so the checks below flip when the product changes, which is the whole point.

WHAT THE MUTATION IS
--------------------
Not Logic's tree. The product guard:

    restore `guard children.count == 1` in readRow, rebuild the same release binary

    with the fix:      {"ok": true, "rows": 2, "Num": {"sliderValue": 60}, "Val": {"…": "100"}}
    guard restored:    {"ok": false, "error": "Event List row 0, column L has 0 cell children;
                        expected 1."}

Both states were observed on this machine before this file was written.
"""

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])

GUARD_MUTATION = (
    "restore `guard children.count == 1` in EventListReadbackCollector.readRow and rebuild the "
    "release binary: the probe stops returning rows and returns "
    "`Event List row 0, column L has 0 cell children; expected 1.` — observed both ways on this "
    "machine"
)


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_titles():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def probe():
    """Run the collector through the SHIPPED binary and return its JSON.

    A subprocess of `E.BIN` on purpose: that is the file the gate hashes, so what this observes and
    what the evidence document is bound to are the same artifact. A second executable or a test
    bundle would be neither.
    """
    r = subprocess.run([E.BIN, "--probe-event-list"], capture_output=True, text=True)
    try:
        return json.loads(r.stdout or "{}")
    except ValueError:
        return {"ok": False, "error": f"unparseable probe output: {(r.stdout or r.stderr)[:200]}"}


titles = window_titles()
ev.check("293/precondition-a-project-is-open", bool(titles),
         "Logic has a project window, so there is somewhere to record a region",
         f"windows={titles!r}", None)
if not titles:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

located = [(t, E.logic_window(t)) for t in titles]
located = [(t, w) for t, w in located if w]
located.sort(key=lambda pair: pair[1]["w"] * pair[1]["h"], reverse=True)
arrange_title, win = located[0] if located else (titles[0], None)
band = (10, 24, min(1900, win["w"] - 20), 58) if win else None
ev.check("293/precondition-the-window-frame-is-known", band is not None,
         "the arrange window's own frame read, so the capture band is inside it",
         f"window={win!r} band={band!r}", None)
if band is None:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=150)
before = ev.shot("293/before", settle_region=band, window_title=arrange_title)

d = E.Driver()
time.sleep(3)
d.tool("logic_tracks", "list_library", {})   # absorbs the first-call refusal (#608)
made = d.tool("logic_tracks", "record_sequence",
              {"bar": 1, "notes": "60,0,500,100,1;64,500,500,100,1", "tempo": 120})
def track_delta(payload):
    """`observed_delta` out of record_sequence's detail, which arrives as a JSON string."""
    try:
        return json.loads((payload or {}).get("detail") or "{}").get("observed_delta")
    except (ValueError, AttributeError):
        return None


ev.check("293/setup-a-track-was-created",
         isinstance(made, dict) and (made.get("success") is True or track_delta(made) == 1),
         "the setup call created a track. `success` is allowed to be false here and this is NOT the "
         "check going soft: `record_sequence` confirms its own work through a readback that only "
         "covers the VISIBLE arrange area, and this project grows by one track per run, so a new "
         "track eventually lands outside it and the operation reports State B — attempted, "
         "unverifiable — which is the honest answer rather than a claim. What it cannot see, the "
         "Event List checks below do: two notes at the pitches this run asked for. If nothing was "
         "created, the delta is 0 here AND those checks go red",
         f"success={(made or {}).get('success')!r} observed_delta={track_delta(made)!r} "
         f"reason={json.loads((made or {}).get('detail') or '{}').get('reason')!r}", None)
d.close()

osa('tell application "Logic Pro" to activate')
time.sleep(1)


# --- The list tabs, read and driven by a tool that is NOT the product ------------------------
#
# System Events cannot see these tabs at all: a shallow `whose description is "Event"` count
# returns 0, a `whose` filter over `entire contents` is not a valid specifier (-1700), and an
# explicit walk of `entire contents` finds none — measured while the pane was open and the probe
# was reading its rows. The earlier precondition here therefore fell back to asking the SHIPPED
# BINARY whether the tab existed, which made `eventTabNotFound` — a product failure — indis-
# tinguishable from "the pane is closed", and fired the artifact before the measurement run.
TAB_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_event_tab.swift")
TAB = os.path.join(ev.dir, "ax_event_tab")
subprocess.run(["swiftc", "-O", TAB_SOURCE, "-o", TAB], check=True, capture_output=True)


def tabs(select=None):
    r = subprocess.run([TAB] + (["select", select] if select else []),
                       capture_output=True, text=True)
    try:
        return json.loads(r.stdout or "{}")
    except ValueError:
        return {"error": (r.stdout or r.stderr or "")[:200]}


def tab_state(payload):
    """{description: selected} for the four list tabs, ignoring the eleven "Has Focus" radios."""
    return {t["description"]: t["selected"] for t in payload.get("tabs", [])
            if t["description"] in ("Event", "Marker", "Tempo", "Signature")}


pane_was_open = bool(tab_state(tabs()))
if not pane_was_open:
    osa('tell application "System Events" to tell process "Logic Pro" to '
        'click menu item "List Editors" of menu 1 of menu bar item 9 of menu bar 1')
    time.sleep(3)
state_before = tab_state(tabs())
ev.check("293/precondition-the-list-editors-pane-is-open",
         bool(state_before),
         "the list tabs exist, read by a driver-side AX tool rather than by the product. The pane is "
         "a TOGGLE: pressing it blind closes it when it was already open, which is how three checks "
         "first went red for a reason that had nothing to do with the product",
         f"pane_was_open_before={pane_was_open!r} tabs={state_before!r}", None)
if not state_before:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

selected_before = next((k for k, v in state_before.items() if v), None)

# --- The refusal, driven live -----------------------------------------------------------------
#
# `observeNoteTable` observes and will not press. Proving that needs the pane pointed somewhere
# else, which only a driver can do.
marker_state = tab_state(tabs(select="Marker"))
refused = probe()
ev.check("293/the-probe-refuses-instead-of-selecting-the-tab",
         marker_state.get("Marker") is True
         and refused.get("ok") is False
         and "not selected" in str(refused.get("error", ""))
         and tab_state(tabs()).get("Marker") is True,
         "with the pane showing the Marker list, the shipped binary refuses and — read again "
         "afterwards — the Marker tab is STILL selected, so it did not press its way to the Event "
         "tab. This is the whole reason a release binary may reach this path at all",
         f"marker={marker_state!r} error={refused.get('error')!r} after={tab_state(tabs())!r}",
         "delete the `guard try checkedState(of: eventTab)` refusal in observeNoteTable and rebuild "
         "the release binary: the probe presses the tab and returns rows instead of refusing, and "
         "the Marker tab is no longer selected when this check reads it back")

event_state = tab_state(tabs(select="Event"))
ev.check("293/precondition-the-driver-selected-the-event-tab",
         event_state.get("Event") is True,
         "the Event tab is selected BEFORE the binary runs, by the driver. A red here means the "
         "driver could not reach the tab — not that the readback broke",
         f"tabs={event_state!r} selected_before_run={selected_before!r}", None)

# The playhead frame the visual is about. `before` was taken before `record_sequence`, which hard-
# resets the playhead to bar 1 — so before/after spans a known playhead move and could not isolate
# the probe. This one brackets the probe alone.
before_probe = ev.shot("293/before-probe", settle_region=band, window_title=arrange_title)

result = probe()
ev.note("293/probe", result)

ev.check("293/the-collector-reads-the-note-table-from-the-shipped-binary",
         result.get("ok") is True and result.get("rows") == 2,
         "the same readHeaders/readRows/readRow path the collector uses returns BOTH rows this run "
         "recorded, against live Logic, from the artifact the gate hashes — before this fix it threw "
         "on the first cell of the first row of every real note. This is NOT a run of `collect()`: "
         "harvestRows, the filter proof, the region path and the time-display refusal are not on "
         "this path and nothing here speaks for them",
         f"ok={result.get('ok')!r} rows={result.get('rows')!r} error={result.get('error')!r}",
         GUARD_MUTATION)

live_cols = result.get("live_columns") or []
ev.check("293/the-note-schema-binds",
         live_cols == ["L", "M", "Position", "Status", "Ch", "Num", "Val", "Length/Info"],
         "the eight column titles LOGIC rendered, in order — read from the header's sort buttons, "
         "not the canonical constants the row keys are minted from. The earlier form of this check "
         "compared those minted keys against the same English constants and so could not fail. "
         "Eight of them, not six, is also what says the pane is at note level and not region level",
         f"live_columns={live_cols!r}",
         # Deliberately NOT mutation-backed. There is no product mutation that makes these titles
         # wrong while the read still succeeds: if Logic rendered anything else, readHeaders throws
         # and every check here goes red together. Naming a mutation would be claiming an
         # independent demonstration that this check cannot give. It earns its place by putting the
         # titles Logic actually rendered into the record, where a reader can see them.
         None)

rows_out = result.get("all_rows") or []
first = rows_out[0] if rows_out else {}
second = rows_out[1] if len(rows_out) > 1 else {}
ev.check("293/both-recorded-notes-come-back",
         (first.get("Num", {}).get("sliderValue") == 60
          and first.get("Val", {}).get("valueDescription") == "100"
          and second.get("Num", {}).get("sliderValue") == 64
          and second.get("Val", {}).get("valueDescription") == "100"),
         "the two pitches this run recorded — 60 then 64 — both read back with their velocity. "
         "Asserting the SECOND note is what binds the table to the region this run created; a check "
         "on the first row alone passes against any leftover note table whose first row happens to "
         "be 60",
         f"first={first.get('Num')!r}/{first.get('Val')!r} second={second.get('Num')!r}/{second.get('Val')!r}",
         GUARD_MUTATION)

children = result.get("first_row_cell_children") or {}
ev.check("293/the-flag-cells-really-are-childless",
         (children.get("L") == 0 and children.get("M") == 0
          and children.get("Num") == 1 and children.get("Val") == 1
          and first.get("L", {}).get("sliderValue") is None
          and first.get("M", {}).get("sliderValue") is None),
         "Lock and Mute have ZERO cell children while Num and Val have one — the child counts "
         "measured off the row, not inferred from a null slider. A null could also mean the key was "
         "dropped or the child carried no slider; a zero here is the state `guard children.count "
         "== 1` used to reject on every real note row",
         f"children={children!r} L={first.get('L')!r} M={first.get('M')!r}",
         GUARD_MUTATION)

# Put the pane back the way it was found: the tab first, then the pane itself.
if selected_before and selected_before != "Event":
    tabs(select=selected_before)
if not pane_was_open:
    osa('tell application "System Events" to tell process "Logic Pro" to '
        'click menu item "List Editors" of menu 1 of menu bar item 9 of menu bar 1')
    time.sleep(2)

relocated = [(t, E.logic_window(t)) for t in window_titles()]
relocated = [(t, w) for t, w in relocated if w]
relocated.sort(key=lambda pair: pair[1]["w"] * pair[1]["h"], reverse=True)
after_title = relocated[0][0] if relocated else arrange_title
after = ev.shot("293/after", settle_region=band, window_title=after_title)
# OWED once #620 lands: `subject=` — what this band IS, not only where. It is the control bar strip
# at the top of the arrange window: chrome, so it does not scroll with the document. That matters
# because no region of the DOCUMENT is invariant across this run — recording a region changes it on
# purpose. The parameter does not exist on this branch's evidence.py yet, and passing it would break
# the run rather than document it.
ev.visual("293/the-transport-is-undisturbed-by-the-probe",
          before_probe["file"], after["file"], band, expect_change=False,
          why="bracketed around the PROBE, not around the whole run: `record_sequence` resets the "
              "playhead to bar 1, so a before/after spanning it could not tell a still transport "
              "from one that moved and came back. Between these two frames the only product call is "
              "the probe, which must only read")

final_state = tab_state(tabs())
ev.restored("293/the-list-editors-pane-is-as-it-was-found",
            bool(final_state) == pane_was_open
            and (not selected_before or final_state.get(selected_before) is True),
            f"the pane is back to open={pane_was_open!r} with {selected_before!r} selected again. "
            "The region it recorded is NOT undone: `record_sequence` creates a track and a region "
            "and nothing reverses it, so the project is one track larger than it was. Stated rather "
            "than claimed away.")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
