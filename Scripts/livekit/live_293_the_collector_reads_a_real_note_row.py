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

# What this harness proves, for `harness_evidence_coverage.py`. A branch touching this path must
# run it and produce a clean document.
#
# ONE file, deliberately. `--probe-event-list` calls `observeNoteTable`, which drives
# `findEventTab` -> `findEventPaneAndTable` -> `readHeaders` -> `readRows` -> `readRow` — the whole
# collector and nothing else in the module. Claiming `MIDIReadback/` entire would cover
# `MIDINoteCanonicalizer`, `MIDIRegionDiff` and seven more this run never touches, and a claim
# wider than the drive is how a coverage rule starts lying on its owner's behalf.
COVERS = [
    "Sources/LogicProMCP/MIDIReadback/EventListReadbackCollector.swift",
]

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
# The band is LOCATED, not written down. `#622`: a rectangle chosen by coordinates cannot show that
# it drifted onto different content — three bands did exactly that this week, keeping their numbers
# while the pane beneath them changed. This asks Logic where the Control Bar is and takes the name
# back off the element that answered, so `subject=` names what was measured rather than what was
# hoped for. (The hand-picked numbers here were in fact right — AX reports the same
# [10, 24, 1900, 58] — but they were right by luck and could not have said so.)
BAND_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_control_bar_band.swift")
BAND_TOOL = os.path.join(ev.dir, "ax_control_bar_band")
subprocess.run(["swiftc", "-O", BAND_SOURCE, "-o", BAND_TOOL], check=True, capture_output=True)


def located_band(*selector):
    """(band, subject, candidates) for a named region, or (None, None, None).

    Delegates to `Evidence.located_band`, which was already here and already translated the name
    through `AX_REGION_LABELS`. This wrapper used to shell out to the tool ITSELF, so it never saw
    that table — a third copy of the same idea, and the one that failed. Measured 2026-08-29: with
    the Korean row added to the table, `ev.located_band` finds the bar and this wrapper still
    reported nothing, because it was asking a different question with the same words.

    The candidate count is read from the tool's own answer for the name that matched, which the
    shared helper records; the count is what this harness asserts on, so it is fetched rather than
    inferred.
    """
    band, subject = ev.located_band(*selector)
    if band is None:
        return None, None, None
    return band, subject, 1


# "Control Bar" matches TWO elements in this window — the strip and a smaller group inside it — so
# the lookup refuses without a discriminator rather than returning whichever the tree walk reached
# first. The width is the discriminator, stated here instead of inherited from walk order.
band, band_subject, band_candidates = located_band("Control Bar", "--min-width", "1000")
ev.check("293/precondition-the-window-frame-is-known",
         band is not None and bool(band_subject) and band_candidates == 1,
         "the arrange window's frame read AND the Control Bar located by AXDescription with "
         "EXACTLY ONE candidate. The count is the point: refusing two is half of it, and the other "
         "half is that 'there was one' reaches this document — otherwise a later reader cannot tell "
         "a discriminator from tree order. No fallback rectangle: a failed lookup is a red "
         "precondition, not a guess",
         f"window={win!r} band={band!r} subject={band_subject!r} candidates={band_candidates!r}", None)
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
# The View menu and its List Editors item, FOUND rather than counted.
#
# This used to be `menu bar item 9` and the literal `"List Editors"`. The index is positional — the
# thing this project forbids everywhere else — and the name is English, so on a Korean Logic the
# click named a menu item that does not exist and the pane stayed shut while the precondition said
# it was closed. Measured 2026-08-29: item 9 happens to be `보기` on this machine, and the item is
# `목록 편집기`. Both are read here instead of assumed.
def _menu_bar_names():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every menu bar item of menu bar 1')
    return [n.strip() for n in (raw or "").split(",")]


def _find_view_menu():
    names = _menu_bar_names()
    for wanted in ("보기", "View", "表示"):
        if wanted in names:
            return names.index(wanted) + 1, wanted
    return None, None


VIEW_MENU, VIEW_MENU_NAME = _find_view_menu()
LIST_EDITORS_ITEM = None
if VIEW_MENU:
    items = osa('tell application "System Events" to tell process "Logic Pro" to return name of '
                f'every menu item of menu 1 of menu bar item {VIEW_MENU} of menu bar 1') or ""
    for wanted in ("목록 편집기", "List Editors", "リストエディタ"):
        if wanted in [i.strip() for i in items.split(",")]:
            LIST_EDITORS_ITEM = wanted
            break
ev.note("293/list-editors-menu", {"menuIndex": VIEW_MENU, "menuName": VIEW_MENU_NAME,
                                  "item": LIST_EDITORS_ITEM})

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
    # Keyed by what the tab CALLS itself, filtered to the Event tab this run drives. The old
    # filter listed the four English names, so on a Korean Logic — where they read `이벤트`,
    # `마커`, `템포`, `조표 및 박자표` — it returned an empty dict and the precondition read
    # "the pane is closed" while the pane was open.
    # ALL four list tabs, not just the two this run drives. Narrowing it to Event and Marker made
    # a session that started on Tempo or Signature read as "no list tab is selected": the run then
    # had nothing to restore, skipped the restoration, and reported itself clean. A filter that
    # hides the state a run must put back is how a false clean is built.
    return {t["description"]: t["selected"] for t in payload.get("tabs", [])
            if t["description"] in E.ALL_LIST_TAB_NAMES}


def selected_is(state, names):
    """Whether the tab this run means is the selected one, whatever it is called here."""
    return any(state.get(n) is True for n in names)


def tab_here(payload, names):
    """The description THIS Logic uses for one of the list tabs, or None."""
    return next((t["description"] for t in payload.get("tabs", [])
                 if t["description"] in names), None)


pane_was_open = bool(tab_state(tabs()))
if not pane_was_open:
    osa('tell application "System Events" to tell process "Logic Pro" to '
        f'click menu item "{LIST_EDITORS_ITEM}" of menu 1 of menu bar item {VIEW_MENU} of menu bar 1')
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
MARKER_HERE = tab_here(tabs(), E.MARKER_LIST_TAB_NAMES)
marker_state = tab_state(tabs(select=MARKER_HERE)) if MARKER_HERE else {}
refused = probe()
ev.check("293/the-probe-refuses-instead-of-selecting-the-tab",
         selected_is(marker_state, E.MARKER_LIST_TAB_NAMES)
         and refused.get("ok") is False
         and "not selected" in str(refused.get("error", ""))
         and selected_is(tab_state(tabs()), E.MARKER_LIST_TAB_NAMES),
         "with the pane showing the Marker list, the shipped binary refuses and — read again "
         "afterwards — the Marker tab is STILL selected, so it did not press its way to the Event "
         "tab. This is the whole reason a release binary may reach this path at all",
         f"marker={marker_state!r} error={refused.get('error')!r} after={tab_state(tabs())!r}",
         "delete the `guard try checkedState(of: eventTab)` refusal in observeNoteTable and rebuild "
         "the release binary: the probe presses the tab and returns rows instead of refusing, and "
         "the Marker tab is no longer selected when this check reads it back")

EVENT_HERE = tab_here(tabs(), E.EVENT_LIST_TAB_NAMES)
event_state = tab_state(tabs(select=EVENT_HERE)) if EVENT_HERE else {}
ev.check("293/precondition-the-driver-selected-the-event-tab",
         selected_is(event_state, E.EVENT_LIST_TAB_NAMES),
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
# Each rendered title against the LabelSet its column declares, in order — not against eight
# English literals. Measured 2026-08-29 on a Korean Logic, the same note-level header renders
# `['L', 'M', '위치', '상태', '채널', '번호', '값', '길이/정보']`, so the literal form failed on a
# table the product had just read correctly and both notes had already come back from.
NOTE_LEVEL_COLUMNS = ["eventListColumnL", "eventListColumnM", "eventListColumnPosition",
                      "eventListColumnStatus", "eventListColumnChannel", "eventListColumnNumber",
                      "eventListColumnValue", "eventListColumnLengthInfo"]
_declared = [E.label_set(n) for n in NOTE_LEVEL_COLUMNS]
schema_binds = (len(live_cols) == len(NOTE_LEVEL_COLUMNS)
                and all(d is not None for d in _declared)
                and all(t is not None and any(t.strip().lower() == v.strip().lower() for v in d)
                        for t, d in zip(live_cols, _declared)))
ev.check("293/the-note-schema-binds",
         schema_binds,
         "the eight column titles LOGIC rendered, in order — read from the header's sort buttons, "
         "not the canonical constants the row keys are minted from. The earlier form of this check "
         "compared those minted keys against the same English constants and so could not fail. "
         "Eight of them, not six, is also what says the pane is at note level and not region level",
         f"live_columns={live_cols!r} declared={_declared!r}",
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

relocated = [(t, E.logic_window(t)) for t in window_titles()]
relocated = [(t, w) for t, w in relocated if w]
relocated.sort(key=lambda pair: pair[1]["w"] * pair[1]["h"], reverse=True)
after_title = relocated[0][0] if relocated else arrange_title
after = ev.shot("293/after", settle_region=band, window_title=after_title)
# `subject` is the Control Bar: chrome, so it does not scroll with the document. That matters
# because no region of the DOCUMENT is invariant across this run — recording a region changes it on
# purpose. The string comes from the element AX matched, not from this file.
ev.visual("293/the-transport-is-undisturbed-by-the-probe",
          before_probe["file"], after["file"], band, expect_change=False, subject=band_subject,
          why="bracketed around the PROBE, not around the whole run: `record_sequence` resets the "
              "playhead to bar 1, so a before/after spanning it could not tell a still transport "
              "from one that moved and came back. Between these two frames the only product call is "
              "the probe, which must only read")

# Put the pane back the way it was found — AFTER the visual, not before it.
#
# This used to run ahead of the `after` shot, so closing the pane changed the layout between the
# two frames the visual compares and `the-transport-is-undisturbed-by-the-probe` went red for the
# restoration rather than for the probe. The bracket is supposed to contain the probe and nothing
# else; putting a window toggle inside it made the run's own tidying look like a disturbance.
if selected_before and selected_before != EVENT_HERE:
    tabs(select=selected_before)
if not pane_was_open:
    osa('tell application "System Events" to tell process "Logic Pro" to '
        f'click menu item "{LIST_EDITORS_ITEM}" of menu 1 of menu bar item {VIEW_MENU} of menu bar 1')
    time.sleep(2)

final_state = tab_state(tabs())
# The tab clause applies only when the pane is LEFT OPEN. When this run opened the pane itself it
# also closes it, and then `final_state` is empty by design — so demanding the remembered tab still
# read selected asked for a selection inside a closed pane and could never hold. Measured: two
# earlier runs were clean only because the pane happened to be open already, which is the same
# state-dependence in the other direction.
tab_is_back = (not pane_was_open) or (not selected_before) \
    or final_state.get(selected_before) is True
ev.restored("293/the-list-editors-pane-is-as-it-was-found",
            bool(final_state) == pane_was_open and tab_is_back,
            f"the pane is back to open={bool(final_state)!r} (found {pane_was_open!r}) and the tab "
            f"clause {'held' if tab_is_back else 'did not hold'} for {selected_before!r}. "
            "The region it recorded is NOT undone: `record_sequence` creates a track and a region "
            "and nothing reverses it, so the project is one track larger than it was. Stated rather "
            "than claimed away.")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
