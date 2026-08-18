#!/usr/bin/env python3
"""Live proof that the FIRST import into a freshly created project succeeds.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_594_first_import_after_project_new.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
`record_sequence` imports a Standard MIDI File through Logic's Open panel. After the go-to-folder
field accepted the path, the code polled the Import button into an enabled state for 20 x 200ms and
then gave up:

    IMPORT_BTN_ERROR: Import button never became enabled (file not selected)

Four seconds is enough for a WARM panel and not for the first one in a freshly created document.
Measured five times across two locales: every failure was the first import after `project.new`, and
every retry seconds later reached State A. That is the opening move an agent makes — create a
project, record something — so the operation was failing at first contact and working for anyone who
ignored its error.

The message was the second half of the defect. "(file not selected)" is a cause this code never
checked; it is what the code inferred from the button not enabling. A caller told a cause nobody
measured cannot tell a slow panel from a wrong path.

WHY THIS RUN CREATES A PROJECT
------------------------------
The defect exists only on the first import into a new document. A run against a project that had
already imported once would exercise a warm panel and pass while measuring nothing, so this one makes
the project and imports immediately, with no warm-up call in between. It says so here rather than
leaving a reader to wonder why Logic restarted.
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
CHOOSER_TITLES = ("Choose a Project", "프로젝트 선택")


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_titles():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def escape_blocking_dialog():
    """Dismiss a modal that has no AX-reachable buttons, and say whether it went.

    Logic's save prompt appears as its own `AXDialog` window and, measured here, exposes NO buttons
    to Accessibility at all — `dialog_buttons: []`. Worse, `first window whose name is "Save"` fails
    with an invalid-index error while the same name is in the window list, so the window cannot even
    be addressed by name. Escape dismisses it; nothing else this run can do will.

    An earlier version of this harness tried to close it as if it were a document, six times.
    """
    before = window_titles()
    osa('tell application "Logic Pro" to activate')
    time.sleep(1)
    osa('tell application "System Events" to key code 53')
    time.sleep(2)
    after = window_titles()
    return {"before": before, "after": after, "dismissed": len(after) < len(before)}


def document_titles():
    return [t for t in window_titles() if not any(c in t for c in CHOOSER_TITLES)]


def close_open_documents():
    """Leave Logic with no document open, using the product where it can and Escape where it cannot.

    `project.close` is the right instrument and it refuses while a blocking dialog is present, so an
    Escape pass runs first and again between attempts. `saving: "no"` discards — this run only ever
    creates untitled scratch projects, and it verifies that before asking.
    """
    steps = []
    for _ in range(4):
        docs = document_titles()
        if not docs:
            break
        named = [t for t in docs if not (t.startswith("Untitled") or t.startswith("무제"))]
        if named:
            steps.append({"refused": named,
                          "why": "a named project is the operator's; this run does not discard it"})
            return {"steps": steps, "refused_named_projects": named}
        result = driver_close()
        steps.append({"close": str(result)[:160]})
        time.sleep(3)
        if document_titles():
            steps.append({"escape": escape_blocking_dialog()})
    return {"steps": steps, "refused_named_projects": []}


def inner(result):
    """The channel envelope `record_sequence` carries verbatim under `detail`."""
    raw = result.get("detail") if isinstance(result, dict) else None
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except ValueError:
        return {}


titles = window_titles()
ev.check("594/precondition-logic-is-up", bool(titles) or E.logic_window(None) is not None,
         "Logic is running with at least one window, so a project can be created into it",
         f"titles={titles!r}", None)

d = E.Driver()
time.sleep(4)


def driver_close():
    return d._send("tools/call", {"name": "logic_project",
                                  "arguments": {"command": "close",
                                                "params": {"confirmed": True, "saving": "no"}}})


closed = close_open_documents()
ev.note("594/closed-documents", closed)
ev.check("594/precondition-no-document-is-open",
         not document_titles() and not closed["refused_named_projects"],
         "no document window remains, so the project this run creates is genuinely new — and no "
         "named project of the operator's was discarded to get there",
         f"remaining={document_titles()!r} refused={closed['refused_named_projects']!r} "
         f"steps={json.dumps(closed['steps'], ensure_ascii=False)[:200]}", None)

if document_titles() or closed["refused_named_projects"]:
    d.close()
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=180)
created = d.tool("logic_project", "new", {})
time.sleep(8)
ev.note("594/project-new", {k: v for k, v in created.items() if k != "raw_help"}
        if isinstance(created, dict) else {"raw": str(created)[:200]})
ev.check("594/a-new-project-exists",
         bool(document_titles()),
         "a document window appeared, so what follows is the FIRST import into a project that did "
         "not exist a moment ago — the only state this defect lives in",
         f"windows={window_titles()!r}", None)

if not document_titles():
    d.close(); ev.stop_recording(rec)
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

# No warm-up call. The whole point is the first one.
first = d.tool("logic_tracks", "record_sequence", {"notes": "60,0,480"})
body = inner(first) or (first if isinstance(first, dict) else {})
ev.note("594/first-import", {k: v for k, v in (first or {}).items() if k != "raw_help"}
        if isinstance(first, dict) else {"raw": str(first)[:300]})

ev.check("594/the-first-import-into-a-new-project-succeeds",
         isinstance(first, dict) and first.get("verified") is True,
         "the very first `record_sequence` after `project.new` reaches State A, with no retry and no "
         "warm-up call before it",
         f"verified={first.get('verified') if isinstance(first, dict) else None!r} "
         f"error={(first or {}).get('error')!r} "
         f"detail={str((first or {}).get('detail'))[:200]!r}",
         # Measured honestly, and it is not the tidy mutation the fix suggests. Restoring the
         # original 20 x 200ms budget did NOT reproduce the failure on this attempt — the panel was
         # warm enough by then. Cutting the poll to a single iteration DOES redden this check and
         # only this one, which is what establishes that the check is sensitive to the poll rather
         # than passing for some unrelated reason.
         #
         # So the case for widening the budget rests on the five recorded failures with the old one
         # and none with the new, not on a reproduction under mutation. An intermittent defect is
         # not made deterministic by wanting it to be.
         "cut the poll to `repeat 1 times`: this check goes red and reports the Import button "
         "staying disabled, while every other check here stays green")

ev.check("594/it-reports-what-it-observed-rather-than-a-cause-it-inferred",
         "file not selected" not in str((first or {}).get("detail", "")),
         "the old message asserted \"(file not selected)\" — a cause the code never checked, inferred "
         "from the button not enabling. Whatever this run reports, it is not that sentence",
         f"detail={str((first or {}).get('detail'))[:200]!r}",
         "restore the old failure string: it names a cause nobody measured, and a caller cannot tell "
         "a slow panel from a wrong path from it")

ev.check("594/the-region-it-made-is-real",
         isinstance(first, dict)
         and isinstance(first.get("start_bar"), int)
         and isinstance(first.get("end_bar"), int)
         and first["end_bar"] > first["start_bar"],
         "the import produced a region with a read-back extent, so success here is a region Logic "
         "confirms rather than an operation that merely stopped erroring",
         f"start={first.get('start_bar') if isinstance(first, dict) else None!r} "
         f"end={first.get('end_bar') if isinstance(first, dict) else None!r} "
         f"name={(first or {}).get('region_name')!r} "
         f"verify_source={(first or {}).get('verify_source')!r}",
         "return State A without the readback: `verify_source` stops being `ax_region_delta` and the "
         "bars stop being present, which is what separates a verified import from a quiet one")

d.close()
ev.restored("594/the-created-project-is-left-open",
            bool(document_titles()),
            f"this run creates a project on purpose — that is the state under test — and leaves it "
            f"open rather than discarding it, so Logic is usable afterwards. Windows: "
            f"{window_titles()!r}. Documents closed to reach a clean start: "
            f"{json.dumps(closed, ensure_ascii=False)[:200]}")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
