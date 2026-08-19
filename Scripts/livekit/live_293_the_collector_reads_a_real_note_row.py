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
ev.check("293/a-region-with-two-notes-was-created-and-left-selected",
         isinstance(made, dict) and made.get("success") is True,
         "the product created a region and left exactly one selected — that selection is what makes "
         "the Event pane show NOTES rather than regions, and without it the collector correctly "
         "refuses with `paneAtRegionLevel`",
         f"success={(made or {}).get('success')!r} error={(made or {}).get('error')!r}",
         None)
d.close()

osa('tell application "Logic Pro" to activate')
time.sleep(1)


def event_tab_present():
    """Whether the Event tab exists — i.e. the List Editors pane is OPEN.

    `View > List Editors` is a TOGGLE. The first cut of this file pressed it unconditionally and, on
    a run where the pane was already open, CLOSED it — the probe then failed with
    `Event List tab (AXDescription Event) was not found` and three checks went red for a reason that
    had nothing to do with the product. Establish the state; do not assume it.
    """
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return (count of (every radio button of window 1 whose description is "Event"))')
    if raw.strip().isdigit() and int(raw) > 0:
        return True
    # The tabs are nested, so a shallow count can miss them; fall back to asking the probe itself,
    # which reports this exact condition by name.
    return "was not found" not in json.dumps(probe())


pane_was_open = event_tab_present()
if not pane_was_open:
    osa('tell application "System Events" to tell process "Logic Pro" to '
        'click menu item "List Editors" of menu 1 of menu bar item 9 of menu bar 1')
    time.sleep(3)
ev.check("293/precondition-the-list-editors-pane-is-open",
         event_tab_present(),
         "the Event tab exists, so the collector's own `findEventTab` has something to find. The pane "
         "is a TOGGLE: pressing it blind closes it when it was already open, which is how three "
         "checks first went red for a reason that had nothing to do with the product",
         f"pane_was_open_before={pane_was_open!r}", None)

def event_tab_selected():
    """AXValue of the Event radio: 1 when the pane is showing events."""
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return (value of (first radio button of window 1 whose description is "Event"))')
    return raw.strip() in ("1", "true")


# The probe refuses when this tab is not already selected — it observes and will not press. That
# is the driver's job, and doing it HERE rather than inside the binary is the point: the shipped
# artifact performs no AX action on this path. Selected by description, never by position.
tab_was_selected = event_tab_selected()
if not tab_was_selected:
    osa('tell application "System Events" to tell process "Logic Pro" to '
        'click (first radio button of window 1 whose description is "Event")')
    time.sleep(2)
ev.check("293/precondition-the-driver-selected-the-event-tab",
         event_tab_selected(),
         "the Event tab is selected BEFORE the binary runs. The probe refuses instead of pressing "
         "it, so a red here means the driver could not reach the tab — not that the readback broke",
         f"tab_was_selected_before={tab_was_selected!r}", None)

result = probe()
ev.note("293/probe", result)

ev.check("293/the-collector-reads-the-note-table-from-the-shipped-binary",
         result.get("ok") is True and result.get("rows", 0) >= 2,
         "the SAME readHeaders/readRows/readRow path the collector uses returns rows when run "
         "against live Logic from the artifact the gate hashes — before this fix it threw on the "
         "first cell of the first row of every real note",
         f"ok={result.get('ok')!r} rows={result.get('rows')!r} error={result.get('error')!r}",
         GUARD_MUTATION)

cols = result.get("columns") or []
ev.check("293/the-note-schema-binds",
         sorted(cols) == sorted(["L", "M", "Position", "Status", "Ch", "Num", "Val", "Length/Info"]),
         "all eight note columns bound by name through the collector's own header binding, so the "
         "the rows are of the note level and not of the six-column region view",
         f"columns={cols!r}",
         GUARD_MUTATION)

row = result.get("first_row") or {}
ev.check("293/the-flag-cells-are-empty-and-the-data-cells-are-not",
         (row.get("L", {}).get("sliderValue") is None
          and row.get("M", {}).get("sliderValue") is None
          and row.get("Num", {}).get("sliderValue") == 60
          and row.get("Val", {}).get("valueDescription") == "100"),
         "Lock and Mute come back empty while Num carries the MIDI note number this run recorded "
         "(60) and Val its velocity (100) — the empty cells are a STATE the collector now reads, "
         "which is the whole change, and the populated ones prove it did not simply give up",
         f"L={row.get('L')!r} M={row.get('M')!r} Num={row.get('Num')!r} Val={row.get('Val')!r}",
         GUARD_MUTATION)

# Restore the pane to however it was found, not to closed.
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
ev.visual("293/the-transport-is-undisturbed",
          before["file"], after["file"], band, expect_change=False,
          why="this run records a region and then only READS; the transport must be where it was, "
              "and a difference here would mean the probe moved the playhead")

ev.restored("293/the-list-editors-pane-is-as-it-was-found",
            event_tab_present() == pane_was_open,
            f"the List Editors pane is back to how the run found it (open={pane_was_open!r}). The region it recorded is NOT undone: "
            "`record_sequence` creates a track and a region and nothing reverses it, so the project "
            "is one track larger than it was. Stated rather than claimed away.")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
