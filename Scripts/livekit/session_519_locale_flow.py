#!/usr/bin/env python3
"""#519 acceptance as a real-usage SESSION scenario, run per locale.

    LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
    python3 session_519_locale_flow.py <worktree> <full-40-char-head-sha> [--locale ko|ja|en]

Run 2026-08-17. It was wrong in both directions on its first outings, which is what a scenario is for:

  * it reported 8/8 green while THREE of five operations had failed, because every check asked only
    whether a modal was left behind — which a failed operation satisfies trivially;
  * the fix for that then demanded State A from EVERY step, which `SemanticOracleTable` declares
    impossible for two of them. I filed both as product failures before checking the oracle. They
    were not failures.

Each step is now held to the best state the project itself says it can reach. A step that lands below
that still fails, so this is not a relaxation — it is the check finally aimed at the right thing.

WHY A SESSION SCENARIO AND NOT ANOTHER PER-ISSUE HARNESS
--------------------------------------------------------
The per-issue harnesses (`live_545_*`, `live_543_*`) each prove one fix, and they stay. This measures a
different property: what an operation LEAVES BEHIND.

#545's real cost was never the failed delete. The dialog was classified `unknown_sheet`, LEFT ON SCREEN,
and every later operation in every surface returned State C until a human clicked it. A harness that runs
`delete` alone and exits cannot see that — the damage is in the SEQUENCE. #549 (a marker row blocking
unrelated operations) and #552 (preflight inheriting prior state) are the same shape.

So the load-bearing assertion here is not "did this step succeed". It is **"does the NEXT step still get
State A"**.

RULES THIS FILE ENCODES ON PURPOSE
----------------------------------
1. DO NOT STOP AT THE FIRST FAILURE. The operations after a failure are the observation. A scenario that
   aborts on step 2 measures nothing about steps 3-7, which is exactly where residue shows up.
2. DO NOT TRIM THE SCENARIO UNTIL IT PASSES. Shrinking the target to manufacture green is the defect
   class this project spent 2026-08-17 removing. A red step is a finding; file it, do not delete it.
3. RECORD WHAT A PASS IS A STATEMENT ABOUT — Logic version, locale, project state. Without that, a later
   break cannot be attributed to anything.

LOCALE
------
`--locale` sets Logic's per-app override (`defaults write com.apple.logic10 AppleLanguages`) and requires
Logic to be RESTARTED by the operator before the run — this script does not restart it, because quitting
Logic can raise a save prompt that needs a human decision about unsaved work. It verifies the running
Logic actually matches the requested locale and refuses otherwise, so a run can never be silently
mislabelled as `ko` while driving an English UI.

Measured 2026-08-17, and the reason this scenario exists per-locale: the Japanese path had THREE stacked
gaps — the menu bar `トラック`, the item `トラックを削除`, and the dialog `キャンセル, 削除` — each
hiding the next. Only a full flow finds that shape; a single-operation probe stops at the first one.
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
LOCALE = "en"
if "--locale" in sys.argv:
    LOCALE = sys.argv[sys.argv.index("--locale") + 1]
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])
d = E.Driver()

# Window-title suffix per locale, measured 2026-08-17 on Logic 12.3. This is the locale WITNESS: it is
# read off the running application, so a run cannot claim a locale it is not actually exercising.
TRACKS_WINDOW_SUFFIX = {"en": "Tracks", "ko": "트랙", "ja": "トラック"}


def dialog_count():
    """Top-level modal dialogs, via System Events — a path the product does not use.

    COUNTS rather than enumerating names: Logic's auto-save recovery alert has an EMPTY name, so a
    name-based query returns an empty string and reads as "no dialogs" while a modal is plainly up.
    Returns None when the measurement itself failed; an unparseable answer is not a zero.
    """
    r = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to tell process "Logic Pro" to '
         'get count of (every window whose subrole is "AXDialog")'],
        capture_output=True, text=True)
    raw = (r.stdout or "").strip()
    return int(raw) if raw.isdigit() else None


def window_titles(tries=5):
    """Logic's window titles, retried.

    A single failed UI read is not an answer. Measured on this branch: one read came back empty
    while Logic plainly had two windows, and the locale precondition hard-exited the whole run on
    it. An empty result is still a real outcome — it just must not be a SINGLE read's outcome.
    """
    for attempt in range(tries):
        r = subprocess.run(
            ["osascript", "-e",
             'tell application "System Events" to tell process "Logic Pro" to '
             'get name of every window'],
            capture_output=True, text=True)
        titles = [t.strip() for t in (r.stdout or "").split(",") if t.strip()]
        if titles:
            return titles
        if attempt < tries - 1:
            time.sleep(0.8)
    return []


def state_of(body):
    """The Honest Contract state a response reports, however it spells it.

    Most envelopes carry `state` directly. `record_sequence`'s SUCCESS envelope does not — it reports
    `verified: true` with `verify_source`, and no `state` key at all. Reading only `state` scored it
    as unknown and counted a genuinely verified take as a shortfall, which is the scenario failing to
    understand the answer rather than the product failing to give one.

    `verified` is the same claim under another name: an independently corroborated write is State A,
    an uncorroborated one State B. Absent both, the state is unknown and stays unknown.
    """
    if not isinstance(body, dict):
        return None
    if isinstance(body.get("state"), str):
        return body["state"]
    if body.get("verified") is True:
        return "A"
    if body.get("verified") is False:
        return "B"
    return None


# ---------------------------------------------------------------------------
# The flow. Each entry is (label, callable) and runs REGARDLESS of what came before.
# ---------------------------------------------------------------------------

def step_project_close():
    # `project.new` refuses unless Logic has no document open — with one open, a newly created
    # project's window cannot be told apart from the ones already on screen (#570). So the flow
    # establishes that precondition instead of driving `new` into a correct refusal and calling it
    # a product failure. The confirmation is required: the bare close answers
    # `confirmation_required`, which is itself L3 gating working.
    return d.tool("logic_project", "close", {"confirmed": True})


def step_project_new():
    return d.tool("logic_project", "new", {})


def step_record_sequence():
    # The only supported route to a region: `midi.import_file` validates its path against an IN-PROCESS
    # registry of files the server itself created, so no external file can reach it.
    return d.tool("logic_tracks", "record_sequence",
                  {"notes": "60,0,500;64,500,500;67,1000,500"})


def step_marker_create():
    return d.tool("logic_navigate", "create_marker", {})


def step_region_select_last():
    # Suspected non-functional: it drives AppleScript `entire contents` on the arrange window, which was
    # measured returning 0 items on 2026-08-17 while `every group of window` returned 4. Its verification
    # compares "last region" against "selected region", which AGREE whenever Logic has already selected a
    # newly created region — so it may be certifying vacuously. This step is here to find out.
    return d.tool("logic_project", "get_regions", {})


def step_transport_goto():
    return d.tool("logic_transport", "goto_position", {"bar": "5"})


# Each step names the BEST state the project says it can reach, not the best state I would like it
# to reach. Asserting State A everywhere — which the first version of this file did — demands what
# `SemanticOracleTable` has formally declared impossible, and turns two by-design outcomes into
# reported product failures. I filed both as findings before checking the oracle; they were not.
#
#   project.new              `SemanticOracleTable.projectNew` lists it among the operations that
#                            "structurally cannot reach State A": the lifecycle write is wrapped as
#                            an honest State B `readback_unavailable`, and no verified-write envelope
#                            is ever emitted. It ALSO refuses outright unless Logic has no document
#                            open, so this step is driven last, after the project is closed.
#   transport.goto_position  Reaches State A only when the complete `bar.beat.subdivision.tick`
#                            request equals the readback. Measured on Logic 12.3: the Playhead
#                            Position group vends exactly TWO AXSliders, `bar` and `beat`. There is
#                            no subdivision or tick readout to compare against, and the reader
#                            deliberately refuses to fabricate `.1.1`. State B is the honest ceiling
#                            on this surface, and the receipt names the gap in
#                            `unobserved_position_components`.
#
# "B" here means an HONEST State B, and it is not a free pass: a step that degrades to State C still
# fails, which is the regression this scenario exists to catch.
FLOW = [
    ("tracks.record_sequence", step_record_sequence, "A"),
    ("navigate.create_marker", step_marker_create, "A"),
    # A READ, not a mutation: its payload carries no Honest Contract state, so holding it to one
    # would make it fail every run for having the shape a read has. `None` means "no state
    # expectation"; the residue and poisoning checks still cover it.
    ("project.get_regions", step_region_select_last, None),
    ("transport.goto_position", step_transport_goto, "B"),
    ("project.close", step_project_close, "B"),
    ("project.new", step_project_new, "B"),
]

# ---------------------------------------------------------------------------

titles = window_titles()
suffix = TRACKS_WINDOW_SUFFIX.get(LOCALE)
locale_ok = bool(suffix) and any(t.endswith(suffix) for t in titles)
ev.check(f"519/{LOCALE}/precondition-logic-is-actually-in-this-locale", locale_ok,
         f"a window title ends with {suffix!r}, so the run is exercising the locale it claims",
         f"locale={LOCALE} titles={titles}",
         "ran with Logic in a different language than --locale; the run would have been filed under a "
         "locale it never exercised, which is worse than not running it")
if not locale_ok:
    d.close()
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

# Reset before measuring. A scenario that runs against whatever the previous run left is measuring
# its own leftovers: earlier runs of this very file grew the project past the arrange viewport, at
# which point `record_sequence` cannot read back its own region (#576) and reports a failure that
# says nothing about the code under test. The close is confirmed because the bare form is L3-gated.
d.tool("logic_project", "close", {"confirmed": True})
time.sleep(6)
d.tool("logic_project", "new", {})
time.sleep(8)
reset_titles = window_titles()
ev.check(f"519/{LOCALE}/precondition-a-fresh-project-was-created-for-this-run",
         any(t.endswith(suffix) for t in reset_titles),
         "the flow runs against a project this run created, not against whatever the last one left "
         "behind — an arrangement grown past the viewport makes region readback fail for reasons "
         "that have nothing to do with the operations being measured",
         f"titles={reset_titles}",
         None)

pre = dialog_count()
ev.check(f"519/{LOCALE}/precondition-no-dialog-is-already-up", pre == 0,
         "the run starts with no modal dialog on screen",
         f"dialog_count={pre!r}",
         "started with a dialog up; every step would return State C for a reason unrelated to the code")

rec = ev.record_screen(seconds=180)
results = []

for index, (label, run, best_state) in enumerate(FLOW):
    body = run()
    time.sleep(1.5)
    after = dialog_count()
    results.append({"step": index, "op": label, "state": state_of(body), "best_state": best_state,
                    "dialogs_after": after,
                    "error": body.get("error") if isinstance(body, dict) else None})
    ev.note(f"519/{LOCALE}/step-{index}-{label}", {"body": body, "dialogs_after": after})

    # THE residue assertion. A step may legitimately fail; what it may never do is leave a modal behind
    # for the next one to trip over. This is the check #545 would have failed loudly.
    ev.check(f"519/{LOCALE}/{label}-leaves-no-modal-behind", after == 0,
             "no modal dialog remains after this step, so the next operation starts from a clean surface",
             f"state={state_of(body)!r} dialogs_after={after!r}",
             "removed the modal reconciler's route for this dialog; it was left on screen and every "
             "later step returned State C")

# The sequence-level claim: no step was poisoned by an earlier one. A step that fails on its own merits
# is a finding; a step that fails ONLY because a predecessor left residue is the defect this file exists
# to catch, and the two are told apart by whether a modal was standing when it ran.
poisoned = [r for i, r in enumerate(results)
            if i > 0 and results[i - 1]["dialogs_after"] not in (0, None) and r["state"] == "C"]
ev.check(f"519/{LOCALE}/no-step-was-poisoned-by-its-predecessor", not poisoned,
         "no step returned State C while a modal left by the previous step was still on screen",
         f"poisoned={poisoned}",
         "left a dialog standing mid-flow; the following steps failed for a reason that had nothing to "
         "do with them")

# FOUND ON THE FIRST RUN, 2026-08-17: without a check on the OUTCOMES this scenario reported 8/8
# green while THREE OF FIVE operations had failed. Every check above asks only "was a modal left
# behind", which a failed operation satisfies trivially — so a flow in which nothing worked at all
# passed cleanly. Residue is necessary and not sufficient: the flow must also DO something.
#
# The first attempt at that check demanded State A from every step. That was wrong in the other
# direction — it demanded what `SemanticOracleTable` declares impossible for two of them, and I
# reported both as product failures before checking. Each step is now held to the best state the
# project says it can reach, and a step that lands BELOW that still fails.
def rank(state):
    return {"A": 2, "B": 1}.get(state, 0)


shortfalls = [r for r in results
              if r["best_state"] is not None and rank(r["state"]) < rank(r["best_state"])]
ev.check(f"519/{LOCALE}/every-step-reached-the-best-state-it-can",
         not shortfalls,
         "each operation reached the state its own qualification allows — State A where a verified "
         "envelope exists, an honest State B where the project has declared none can, and State C "
         "nowhere",
         f"shortfalls={shortfalls} states={[(r['op'], r['state'], r['best_state']) for r in results]}",
         "let a failing operation count as a pass because it happened to leave no dialog behind — "
         "measured on the first run, where 3 of 5 failed and the suite still reported all-green")

ev.note(f"519/{LOCALE}/flow-summary", {"locale": LOCALE, "results": results})

ev.stop_recording(rec)
d.close()
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
