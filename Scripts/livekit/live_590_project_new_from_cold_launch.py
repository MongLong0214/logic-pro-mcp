#!/usr/bin/env python3
"""Live proof that `project.new` works from the state Logic lands in at launch.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_590_project_new_from_cold_launch.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
A freshly launched Logic shows "Choose a Project". `project.new`'s open-document precondition counted
raw AX windows, so that chooser was an open document and the operation refused:

    {"error":"unsupported_state","failure_stage":"precondition_open_document",
     "observed_window_count":1,
     "hint":"project.new requires Logic to have no open document; 1 window(s) are open. …"}

There was no open document. This is the state every first-time caller is in, and it needs no unusual
configuration — only a Logic that was launched and not yet given a project. Measured in English and
in Korean; it is not a locale defect.

The precondition's reasoning is untouched and still right: with a real document open, a newly created
project's window cannot be told apart from the ones already on screen. A chooser does not create that
ambiguity, and driving File > New with the chooser still on screen was measured to create the project
anyway. So the count now excludes chooser windows, using the classifier `getTrackHeaders` already
uses for the same purpose.

WHY THIS RUN RELAUNCHES LOGIC
-----------------------------
The defect exists only at a cold launch. A harness that started from an already-open project would
exercise a different branch and pass while measuring nothing, so this one quits Logic and waits for
the chooser before it begins. It says so here rather than leaving a reader to infer why Logic
restarted.

A fresh launch also raises Logic's own single-button audio-interface alert on this host. That is
acknowledged before the test — it is Logic's, informational, and its own preflight refusal
(`preflight_blocking_dialog`) is a separate and defensible one that would otherwise mask the branch
under test.
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
LAUNCH_TIMEOUT = 90.0
CHOOSER_TITLES = ("Choose a Project", "프로젝트 선택")


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_titles():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",")] if raw else []


def logic_running():
    return osa('tell application "System Events" to return (count of (every process whose '
               'name is "Logic Pro"))') == "1"


def dismiss_single_button_alert():
    """Acknowledge Logic's own informational alert, but ONLY when it has exactly one button.

    The count is the gate, not the text: measured, the same audio-interface alert read its static
    texts on one launch and returned nothing on the next, and an earlier version of this function
    keyed the click on the text being readable — so it silently declined to dismiss anything and the
    run failed at a later stage for a reason that was not the one under test.

    One button means there is no choice to make and nothing this run could decide on the operator's
    behalf. Two or more, and it declines and says so, which is the same rule the product's own modal
    reconciler follows.
    """
    # The alert does not appear the instant the chooser does. An earlier version looked once, saw
    # nothing, and declined — and the operation then refused on the alert that arrived a moment
    # later, failing the run for a reason that was not the one under test. So this waits for it.
    #
    # The count comes from `count of every button`, not from reading their names: measured, the same
    # dialog reported ["OK"] to the product while `name of every button` came back empty through
    # System Events, so a name-based count would have declined on a dialog that was plainly there.
    deadline = time.time() + 15
    count = 0
    while time.time() < deadline:
        raw = osa('tell application "System Events" to tell process "Logic Pro" to '
                  'return (count of (every button of (first window whose subrole is "AXDialog")))')
        count = int(raw) if raw.isdigit() else 0
        if count:
            break
        time.sleep(2)
    if count != 1:
        return {"dismissed": False, "button_count": count,
                "why": "no dialog" if not count else "more than one button — not this run's choice"}
    text = osa('tell application "System Events" to tell process "Logic Pro" to '
               'return value of every static text of (first window whose subrole is "AXDialog")')
    osa('tell application "System Events" to tell process "Logic Pro" to '
        'click button 1 of (first window whose subrole is "AXDialog")')
    time.sleep(2)
    return {"dismissed": True, "button_count": count, "text": text[:200]}


# ---- reach a cold launch -------------------------------------------------------------------------

def close_open_documents():
    """Close document windows before quitting, so the next launch lands on the chooser.

    The run cannot ASSUME a cold launch shows "Choose a Project": Logic reopens the document that was
    open when it quit. Measured — a relaunch after quitting with a project open came back straight to
    `Untitled 56 - Tracks`, and the branch under test was never reached. The state has to be
    established, not hoped for.

    Only an UNTITLED document is discarded at the save prompt. A named project is the operator's, and
    this run has no business deciding not to save it: it stops instead, and the precondition below
    reports why.
    """
    closed, refused = [], []
    for _ in range(6):
        titles = [t for t in window_titles()
                  if t and not any(c in t for c in CHOOSER_TITLES)]
        if not titles:
            break
        target = titles[0]
        osa(f'tell application "System Events" to tell process "Logic Pro" to click '
            f'(first button of (first window whose name is "{target}") whose description is "close button")')
        time.sleep(2)
        # A save prompt is three buttons — a real choice — so it is answered only for a scratch
        # document this run can identify as untitled.
        buttons = osa('tell application "System Events" to tell process "Logic Pro" to '
                      'return name of every button of window 1')
        if "Save" in buttons or "저장" in buttons:
            if target.startswith("Untitled") or target.startswith("무제"):
                discard = "Don’t Save" if "Don’t Save" in buttons else (
                    "Don't Save" if "Don't Save" in buttons else "저장 안 함")
                osa('tell application "System Events" to tell process "Logic Pro" to '
                    f'click button "{discard}" of window 1')
                time.sleep(2)
                closed.append(f"{target} (discarded)")
            else:
                refused.append(target)
                osa('tell application "System Events" to tell process "Logic Pro" to '
                    'click button "Cancel" of window 1')
                break
        else:
            closed.append(target)
    return {"closed": closed, "refused_named_projects": refused}


# Quitting can be refused by a sheet Logic has open — measured, a freshly created project leaves its
# "New Track" chooser up, and `quit` then does nothing while the process stays alive. So the shutdown
# escapes any sheet once and asks again, and the precondition below judges the OUTCOME rather than
# the fact that a quit was sent.
closed_documents = {"closed": [], "refused_named_projects": []}
if logic_running():
    closed_documents = close_open_documents()
    for attempt in range(3):
        osa('tell application "Logic Pro" to quit')
        deadline = time.time() + 20
        while logic_running() and time.time() < deadline:
            time.sleep(2)
        if not logic_running():
            break
        osa('tell application "Logic Pro" to activate')
        time.sleep(1)
        osa('tell application "System Events" to key code 53')
        time.sleep(2)

ev.check("590/precondition-logic-was-shut-down",
         not logic_running(),
         "Logic is not running, so the launch below is a genuine cold start rather than a reuse of "
         "whatever state an earlier run left behind",
         f"running={logic_running()}", None)

subprocess.run(["open", "-a", "Logic Pro"], capture_output=True)
deadline = time.time() + LAUNCH_TIMEOUT
titles = []
while time.time() < deadline:
    titles = window_titles()
    if any(any(c in t for c in CHOOSER_TITLES) for t in titles):
        break
    time.sleep(3)

alert = dismiss_single_button_alert()
time.sleep(2)
titles = window_titles()
ev.note("590/launch", {"titles": titles, "dismissed_alert": alert,
                       "documents_closed_before_quit": closed_documents})

ev.check("590/precondition-the-launch-lands-on-the-project-chooser",
         any(any(c in t for c in CHOOSER_TITLES) for t in titles),
         "Logic came up showing its project chooser and no document — the exact state this defect "
         "is about, and the one a first-time caller is in",
         f"titles={titles!r} · alert={json.dumps(alert)[:120]} · "
         f"closed before quit={json.dumps(closed_documents, ensure_ascii=False)[:160]}", None)

ev.check("590/precondition-no-document-window-is-open",
         not any("Tracks" in t or "트랙" in t for t in titles),
         "no arrange window is on screen, so nothing that follows can be explained by a project "
         "that was already open",
         f"titles={titles!r}", None)

if not any(any(c in t for c in CHOOSER_TITLES) for t in titles):
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

chooser_title = next(t for t in titles if any(c in t for c in CHOOSER_TITLES))
rec = ev.record_screen(seconds=150)
# A band over the chooser window itself: it is what is on screen before, and a created project puts
# its arrange window over the same area.
before = ev.shot("590/chooser", settle_region=None, window_title=chooser_title)

# ---- the operation -------------------------------------------------------------------------------

d = E.Driver()
time.sleep(4)
created = d.tool("logic_project", "new", {})
time.sleep(8)
after_titles = window_titles()
ev.note("590/new", {"result": created if isinstance(created, dict) else str(created)[:300],
                    "titles_after": after_titles})

body = created if isinstance(created, dict) else {}
ev.check("590/the-chooser-is-no-longer-treated-as-an-open-document",
         body.get("failure_stage") != "precondition_open_document",
         "`project.new` is not refused for having a document open, because the only window on "
         "screen was the chooser and a chooser is not a document",
         f"failure_stage={body.get('failure_stage')!r} error={body.get('error')!r} "
         f"all_windows={body.get('observed_all_window_count')!r} "
         f"documents={body.get('observed_window_count')!r}",
         "count raw windows again in `documentWindowCount`: the call comes back "
         "`precondition_open_document` with the chooser as the one window, which is the defect")

ev.check("590/a-project-was-actually-created",
         any("Tracks" in t or "트랙" in t for t in after_titles),
         "an arrange window exists that did not exist before the call — read from the window list "
         "rather than from the operation's own report of itself",
         f"before={titles!r} after={after_titles!r}",
         "return early from `createEmptyProjectFromQualifiedState` without driving the menu: the "
         "envelope can still claim a phase, and this check — which never reads it — goes red")

ev.check("590/the-operation-does-not-overclaim-what-it-verified",
         body.get("success") is True and body.get("state") in ("A", "B"),
         "the envelope is an Honest Contract state rather than a bare error, and it does not claim "
         "more than the readback it had — State B here is the honest answer when the created "
         "window cannot be independently confirmed by the handler",
         f"state={body.get('state')!r} success={body.get('success')!r} "
         f"reason={body.get('reason')!r} phase={body.get('phase')!r}",
         None)

created_title = next((t for t in after_titles if "Tracks" in t or "트랙" in t), chooser_title)
after = ev.shot("590/created", settle_region=None, window_title=created_title)
ev.visual("590/the-screen-shows-a-project-where-it-showed-a-chooser",
          before["file"], after["file"], (0, 0, 400, 200), expect_change=True,
          why="the capture before the call is the chooser window and the one after is the new "
              "arrange window, so the top-left corner of what was captured must differ — an "
              "envelope claiming a project that nobody can see would not move it")

d.close()
ev.restored("590/an-empty-project-is-left-open",
            any("Tracks" in t or "트칙" in t or "트랙" in t for t in after_titles),
            f"this run restarts Logic and creates an empty project on purpose — that is the state "
            f"under test — and leaves it open rather than quitting, so the application is usable "
            f"afterwards. Windows now: {after_titles!r}. Logic's own audio-interface alert was "
            f"acknowledged during the launch: {json.dumps(alert)[:200]}")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
