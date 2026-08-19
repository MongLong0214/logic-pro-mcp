"""Live proof of the PREMISE behind the #293 fix: Logic leaves the flag cells empty.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_293_flag_cells_are_empty.py <worktree> <full-40-char-head-sha>

WHAT THIS RUN CAN AND CANNOT PROVE
----------------------------------
It cannot prove the fix. `EventListReadbackCollector` has no caller: no MCP tool reaches it, and
`FeatureFlags.adr010MidiReadback` is named only in a comment, so no product behaviour changes when the
guard changes. There is therefore NO mutation to the product that a live run could observe, and every
check below is a precondition-style observation with `mutation=None` rather than a mutation-backed
proof. Saying otherwise would be the defect this directory exists to refuse.

What it does prove is the PREMISE the fix and its fixture rest on: that Logic's note-level Event List
puts nothing in the Lock and Mute cells. That premise is the whole argument — the collector was
written against a fixture that gave every cell a child, and the fixture was wrong about Logic.

So this run drives Logic to the note level through the product (`record_sequence` leaves exactly one
region selected, which is what makes the Event pane show notes), reads the table the collector reads,
and records the shape.
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
WITNESS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_event_pane_shape.swift")


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_titles():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def read_pane_shape():
    """Ask raw AX for the Event pane's table, the way the collector does.

    Deliberately NOT System Events: twice this week a rule prototyped through it failed to hold
    through the API the product uses — once because `description` is synthesised from
    `AXRoleDescription`, once because `entire contents` could not reach an element a Swift walk found
    at depth 14.
    """
    out = os.path.join(os.path.dirname(WITNESS), ".ax_event_pane_shape.bin")
    build = subprocess.run(["swiftc", "-O", WITNESS, "-o", out], capture_output=True, text=True)
    if build.returncode != 0:
        return {"error": build.stderr[:300]}
    r = subprocess.run([out], capture_output=True, text=True)
    try:
        return json.loads(r.stdout or "{}")
    except ValueError:
        return {"error": (r.stdout or r.stderr)[:300]}


titles = window_titles()
ev.check("293/precondition-a-project-is-open", bool(titles),
         "Logic has a project window to put a region in",
         f"windows={titles!r}", None)
if not titles:
    ev.write()
    sys.exit("no project open")

located = [(t, E.logic_window(t)) for t in titles]
located = [(t, w) for t, w in located if w]
located.sort(key=lambda pair: pair[1]["w"] * pair[1]["h"], reverse=True)
arrange_title, win = located[0] if located else (titles[0], None)
band = (0, 0, win["w"], 28) if win else None
ev.check("293/precondition-the-window-frame-is-known", band is not None,
         "the arrange window's own frame read, so the capture band is inside it",
         f"window={win!r} band={band!r}", None)
if band is None:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=120)
before = ev.shot("293/before", settle_region=band, window_title=arrange_title)

d = E.Driver()
time.sleep(3)
d.tool("logic_tracks", "list_library", {})  # absorb the first-call refusal (#608, unfixed on main)
made = d.tool("logic_tracks", "record_sequence",
              {"bar": 1, "notes": "60,0,500,100,1;64,500,500,100,1;67,1000,500,100,1", "tempo": 120})
ev.note("293/record-sequence", {k: (made or {}).get(k) for k in
                                ("success", "error", "note_count", "region_name", "created_track")})
ev.check("293/a-region-with-three-notes-exists-and-is-selected",
         isinstance(made, dict) and made.get("success") is True and made.get("note_count") == 3,
         "the product created a region and left it selected — that selection is what makes the Event "
         "pane show NOTES instead of regions, and it is the navigation step that was missing from "
         "every earlier attempt to reach this level",
         f"success={(made or {}).get('success')!r} note_count={(made or {}).get('note_count')!r} "
         f"error={(made or {}).get('error')!r}",
         None)
d.close()

osa('tell application "Logic Pro" to activate')
time.sleep(1)
osa('tell application "System Events" to tell process "Logic Pro" to '
    'click menu item "List Editors" of menu 1 of menu bar item 9 of menu bar 1')
time.sleep(3)

shape = read_pane_shape()
ev.note("293/event-pane-shape", shape)

ev.check("293/the-collectors-event-tab-predicate-matches-exactly-one",
         shape.get("eventTabMatches") == 1,
         "`findEventTab` looks for an AXRadioButton with AXDescription \"Event\" and an empty title; "
         "exactly one element in the main window answers that, so the lookup is unambiguous",
         f"eventTabMatches={shape.get('eventTabMatches')!r}", None)

ev.check("293/the-note-level-table-has-the-eight-column-schema",
         shape.get("columns") == 8
         and shape.get("sortTitles") == ["L", "M", "Position", "Status", "Ch", "Num", "Val",
                                         "Length/Info"],
         "the pane is at the NOTE level, not the region level — eight columns with the note schema, "
         "which is what the collector's header binding expects",
         f"columns={shape.get('columns')!r} sortTitles={shape.get('sortTitles')!r}", None)

counts = shape.get("cellChildCounts") or []
ev.check("293/logic-puts-nothing-in-the-lock-and-mute-cells",
         bool(counts) and all(c == [0, 0, 1, 1, 1, 1, 1, 1] for c in counts),
         "every row reads [0, 0, 1, 1, 1, 1, 1, 1] — the flag columns are EMPTY on an ordinary note. "
         "This is the premise the fix rests on and the shape the corrected fixture now models; the "
         "old fixture gave those two cells a child, which is a shape Logic does not produce",
         f"cellChildCounts={counts!r}", None)

ev.check("293/the-flag-cells-have-nowhere-else-to-hold-a-value",
         shape.get("flagCellHasValueAttribute") is False,
         "the L and M cells expose no value-bearing attribute either, so an empty cell cannot mean "
         "\"the flag is set and stored elsewhere\" — it can only mean the flag is off",
         f"flagCellHasValueAttribute={shape.get('flagCellHasValueAttribute')!r}", None)

osa('tell application "System Events" to tell process "Logic Pro" to '
    'click menu item "List Editors" of menu 1 of menu bar item 9 of menu bar 1')
time.sleep(2)

relocated = [(t, E.logic_window(t)) for t in window_titles()]
relocated = [(t, w) for t, w in relocated if w]
relocated.sort(key=lambda pair: pair[1]["w"] * pair[1]["h"], reverse=True)
after_title = relocated[0][0] if relocated else arrange_title
after = ev.shot("293/after", settle_region=band, window_title=after_title)
ev.visual("293/the-title-band-is-undisturbed",
          before["file"], after["file"], band, expect_change=False,
          why="this run reads; the only thing it writes is a region, which does not rename the "
              "document — so the title band must look exactly as it did")

ev.restored("293/the-list-editors-pane-was-closed-again",
            True,
            "the List Editors pane this run opened was closed. The region it recorded is NOT undone — "
            "`record_sequence` creates a track and a region and there is no product operation that "
            "reverses it, so this run leaves the project one track larger than it found it. Stated "
            "rather than claimed away.")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
