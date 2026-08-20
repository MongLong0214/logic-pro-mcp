#!/usr/bin/env python3
"""Live proof that `is_stack_header` / `stack_collapsed` are read from Logic, not assumed.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_448_track_stack_readback.py <worktree> <full-40-char-head-sha>

WHAT #448 ASSUMED, AND WHAT IS ACTUALLY THERE
---------------------------------------------
The roadmap parks #448 as an expected scope decision on the reading that track-stack hierarchy is
not exposed to Accessibility. Half of that is wrong. Logic puts an `AXDisclosureTriangle` on the
main track of a track stack — exactly one of the 46 layout items in this arrange window carries one
— and its help text says what it is:

    "Track stack disclosure arrow. Show or hide subtracks. Use the controls on the main track to
     control all subtracks in the track stack."

So `logic://tracks` now carries two fields. This run has to show they are READINGS.

WHY ONE OBSERVATION WOULD PROVE NOTHING
---------------------------------------
A field that always says `collapsed: true` looks identical to a correct field on a project whose
stack happens to be collapsed. The run therefore discloses the stack and requires BOTH answers out
of the same project, with Logic's own corroboration that something happened: the arrangement gains
track headers because the subtracks appear, and the arrow's own `AXValue` moves with them.

WHY THE ARROW IS NOT PRESSED
----------------------------
`AXPress` on that arrow is inert. Measured 2026-08-18, through System Events and through a direct
in-process `AXUIElementPerformAction` alike: the call answers `.success` and the value does not
move — and the same press on the Mute checkbox beside it also moves nothing, so this is the control
and not the caller. `AXValue` is `settable: false`. What does actuate it is Logic's own Edit menu
entry, "Undo/Redo Close/Disclose Track Stack", which names the operation it performs; the run reads
that name before clicking, so the actuator states its own effect. No coordinates are involved
anywhere: menu items and AX elements only.

That name is not enough on its own. "Undo Create Track Stack" also contains the words "Track Stack",
and clicking it DELETES the stack this run exists to read — which is a live possibility, because the
first run after someone creates the probe stack finds exactly that at the top of the undo history.
So a candidate is rejected if its action name matches one of Logic's own structural stack commands,
read from the live Track menu at run time rather than listed here, which keeps the guard working on
a Logic in any language. And the click is judged on the arrow still EXISTING and its value having
flipped: a vanished arrow also "differs" from its old value, which is precisely what a mis-aimed
undo would produce.

The actuator is deliberately NOT the code under test, and it is not the reader either: the arrow is
read by a separate `swiftc`-built tool (`ax_stack_arrow.swift`) that binds the arrow to the name of
the track whose header carries it, so "the arrow" and "the row" are the same track by identity
rather than by both happening to be first in their list.

WHY A FRESH READ HAS TO BE PROVEN FRESH
---------------------------------------
`logic://tracks` is served from the state poller's cache, not from a read at call time — measured
earlier on this branch, a read seconds after server start reported `track_count=0` on a 21-track
project. Every reading below is taken by polling until the document's own `cache_age_sec` proves the
snapshot was written AFTER the actuation finished, and the snapshot's age is recorded as provenance.
The floor is stamped after the menu click returns, not before it, so a poll cycle that overlapped
the click cannot satisfy it. The pre-actuation reading additionally has to REPEAT before it is used,
because a poller still filling its first inventory would otherwise supply a short "before" count
that any later complete read would beat.
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

# The band the visual assertion watches: the EMPTY area of the track-header rail below the last
# collapsed header. Measured — the rail is the AXScrollArea two levels above the arrow, screen frame
# 603,192 325x406 against a window at 0,30, and the 21 collapsed headers end around 300 points down.
#
# Deliberately not the whole rail. The rail carries level meters, selection highlights and the arrow
# glyph itself, all of which change on their own, so `expect_change=True` over it would be close to
# an assertion that cannot fail. This band is flat grey while the stack is closed and fills with
# subtrack headers when it opens, so it can stay still — which is what makes its changing mean
# something.
#
# So the band is a SLICE of the rail, and the rail is located rather than written down. The whole
# rail would be the wrong subject here for the reason just given; a fixed rectangle was the wrong
# subject for a different one — measured 2026-08-20 the rail sits at y=162 h=873, not the 192/406
# the numbers above were taken from, because it moves with the panes around it. The offset into the
# rail is what this harness actually knows: 308 points down, past the collapsed headers.
_RAIL, _RAIL_SUBJECT = ev.located_band("Tracks header")
QUIET_BAND = (_RAIL[0], _RAIL[1] + 308, _RAIL[2], 90) if _RAIL else None
QUIET_BAND_SUBJECT = f"{_RAIL_SUBJECT} — the empty area below the collapsed headers" if _RAIL else None
ev.check("448/precondition-the-track-header-rail-was-located",
         QUIET_BAND is not None and bool(QUIET_BAND_SUBJECT),
         "the empty slice of the track-header rail, offset into a rail located by AXDescription",
         f"rail={_RAIL!r} band={QUIET_BAND!r} subject={QUIET_BAND_SUBJECT!r}", None)
CACHE_REFRESH_TIMEOUT = 40.0
POLL = 0.5
ARROW_TOOL_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_stack_arrow.swift")
ARROW_TOOL = os.path.join(ev.dir, "ax_stack_arrow")


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip(), (r.stderr or "").strip()


def arrow_state():
    """`{arrows, value, owner}` — the disclosure arrow read by an instrument that is not the product."""
    r = subprocess.run([ARROW_TOOL, "read"], capture_output=True, text=True)
    try:
        return json.loads(r.stdout or "{}")
    except ValueError:
        return {"error": (r.stdout or r.stderr or "")[:200]}


def press_arrow_and_watch():
    """Record what `AXPress` on the arrow does. It is measured, not relied upon."""
    r = subprocess.run([ARROW_TOOL, "press"], capture_output=True, text=True)
    try:
        return json.loads(r.stdout or "{}")
    except ValueError:
        return {"error": (r.stdout or r.stderr or "")[:200]}


_MENU_NAMES = '''
tell application "System Events" to tell process "Logic Pro"
  set out to ""
  repeat with mi in (every menu item of menu 1 of menu bar item "%s" of menu bar 1)
    try
      set out to out & (name of mi as text) & linefeed
    end try
  end repeat
  return out
end tell
'''

_CLICK_EXACT = '''
tell application "System Events" to tell process "Logic Pro"
  click (first menu item of menu 1 of menu bar item "Edit" of menu bar 1 whose name is "%s")
  delay 2.5
  return "clicked"
end tell
'''


def menu_item_names(bar):
    out, _ = osa(_MENU_NAMES % bar)
    return [line.strip() for line in out.splitlines() if line.strip()]


def structural_stack_commands():
    """Logic's OWN stack commands, read from the Track menu at run time.

    These are the entries whose undo must never be mistaken for a disclosure: undoing
    "Create Track Stack" DELETES the stack this run exists to read. Reading them from the live menu
    rather than listing them here keeps the guard working on a Logic in any language, because both
    sides of the comparison come from the same localized menu bar.
    """
    return [name.rstrip("\u2026.").strip() for name in menu_item_names("Track")]


def disclosure_candidates():
    """Edit-menu Undo/Redo entries that are safe to click, with the reason any rejected one failed.

    An entry qualifies only if it names a track-stack action AND is not the undo of one of Logic's
    structural stack commands. The earlier version of this harness filtered on `name contains "Track
    Stack"` alone; `Undo Create Track Stack` satisfies that, and clicking it destroys the stack. The
    predicate now says what the check claims.
    """
    banned = [name for name in structural_stack_commands() if name]
    out = {"accepted": {}, "rejected": {}}
    for verb in ("Undo", "Redo"):
        for title in menu_item_names("Edit"):
            if not title.startswith(verb) or "Track Stack" not in title:
                continue
            action = title[len(verb):].strip().rstrip("\u2026.").strip()
            hit = next((b for b in banned if action == b or action.endswith(b)), None)
            if hit:
                out["rejected"][title] = f"names Logic's own {hit!r} command, not a disclosure"
            else:
                out["accepted"][verb] = title
            break
    return out


def toggle_disclosure():
    """Flip the stack open or closed through Logic's own menu, and say which entry did it.

    Success is judged on the arrow still EXISTING and its value having flipped — never on the click
    returning, and never on the value merely differing. A vanished arrow also "differs" from its old
    value, and that is exactly what a mis-aimed undo would produce.
    """
    before = arrow_state()
    candidates = disclosure_candidates()
    for verb in ("Undo", "Redo"):
        title = candidates["accepted"].get(verb)
        if not title:
            continue
        osa(_CLICK_EXACT % title.replace('"', '\\"'))
        after = arrow_state()
        if after.get("arrows") != 1:
            return {"verb": verb, "title": title, "moved": False,
                    "catastrophic": f"the arrow is gone after this click (arrows="
                                    f"{after.get('arrows')!r}) — the stack itself may have been "
                                    f"changed, not disclosed",
                    "candidates": candidates}
        if isinstance(after.get("value"), int) and after["value"] != before.get("value"):
            return {"verb": verb, "title": title, "moved": True, "candidates": candidates}
    return {"verb": None, "title": None, "moved": False, "candidates": candidates}


def read_tracks_after(driver, floor_ts, tag):
    """A `logic://tracks` document whose cache snapshot was written strictly after `floor_ts`.

    Freshness is decided on `cache_age_sec`, not on the envelope's `fetched_at` timestamp. The
    server recomputes that age at the moment the resource is read, so comparing it against this
    process's own elapsed time is a comparison of two DURATIONS — immune to any offset between the
    two processes' clocks and to any misreading of the timestamp's timezone. The age that decided it
    is what goes into the provenance record.
    """
    started = time.time()
    body = {}
    while time.time() - started < CACHE_REFRESH_TIMEOUT:
        asked_at = time.time()
        body = driver.resource("logic://tracks") or {}
        age = body.get("cache_age_sec")
        if isinstance(age, (int, float)) and (asked_at - age) > floor_ts:
            ev.provenance(tag, f"state_poller_snapshot_written_{round(age, 2)}s_ago_after_the_event",
                          round(age, 2), True)
            return body, True
        time.sleep(POLL)
    ev.provenance(tag, "state_poller_cache_never_refreshed_after_the_event",
                  round(time.time() - started, 2), False)
    return body, False


def read_tracks_settled(driver, tag):
    """A document the poller has repeated, so a still-filling first inventory is not used as 'before'.

    `allTrackHeaders` reports the whole rail rather than the viewport, so the count does not drift
    with scrolling — but it IS empty until the first poll lands, and a short first inventory would
    make any later complete read look like growth.
    """
    started, previous = time.time(), None
    while time.time() - started < CACHE_REFRESH_TIMEOUT:
        body = driver.resource("logic://tracks") or {}
        rows = body.get("data") or []
        signature = (body.get("source"), len(rows))
        if signature == previous and signature[0] == "ax_live" and signature[1] > 0:
            ev.provenance(tag, f"state_poller_reported_{signature[1]}_rows_twice_running",
                          round(body.get("cache_age_sec") or 0, 2), True)
            return body, True
        previous = signature
        time.sleep(1.5)
    ev.provenance(tag, "state_poller_never_repeated_an_inventory", None, False)
    return {}, False


def partition(body):
    rows = body.get("data") or []
    return (
        [r for r in rows if r.get("is_stack_header") is True],
        [r for r in rows if r.get("is_stack_header") is False],
        [r for r in rows if r.get("is_stack_header") is None],
        len(rows),
    )


# ---- preconditions ---------------------------------------------------------------------------

build = subprocess.run(["swiftc", "-O", ARROW_TOOL_SOURCE, "-o", ARROW_TOOL],
                       capture_output=True, text=True)
ev.check("448/precondition-the-independent-arrow-reader-builds",
         build.returncode == 0 and os.path.exists(ARROW_TOOL),
         "the harness's own AX reader compiles, so the arrow is observed by something other than "
         "the code under test",
         f"swiftc rc={build.returncode} {build.stderr.strip()[:200]}", None)

titles, _ = (osa('tell application "System Events" to tell process "Logic Pro" to '
                 'return name of every window'))
ev.check("448/precondition-an-arrange-window-is-open", "Tracks" in titles,
         "Logic has an arrange window whose track headers can be read",
         f"titles={titles!r}", None)

start = arrow_state() if os.path.exists(ARROW_TOOL) else {}
ev.check("448/precondition-the-project-has-exactly-one-track-stack",
         start.get("arrows") == 1 and isinstance(start.get("value"), int) and start.get("owner"),
         "exactly one disclosure arrow sits on a track header, and the track carrying it can be "
         "named — with two stacks the row-to-arrow binding below would be ambiguous, and this run "
         "cannot create or remove one without a write this change does not expose",
         f"{start!r}", None)

ev.check("448/precondition-the-stack-starts-closed",
         start.get("value") == 0,
         "the run begins with the stack collapsed, which is what makes 'headers went up' and "
         "'collapsed went false' the expected directions below — a leftover open stack from an "
         "earlier run would invert both and is refused here rather than misread there",
         f"arrow value={start.get('value')!r}", None)

candidates = disclosure_candidates()
ev.check("448/precondition-logic-offers-a-disclosure-command-that-is-not-a-structural-one",
         bool(candidates["accepted"]),
         "at least one Edit-menu Undo/Redo entry names a track-stack action that is NOT the undo of "
         "one of Logic's own structural stack commands, read from the live Track menu. Undoing "
         "'Create Track Stack' also contains the words 'Track Stack' and would DELETE the stack "
         "this run reads, so accepting it would destroy the subject rather than actuate it",
         f"accepted={candidates['accepted']!r} rejected={candidates['rejected']!r} "
         f"structural={structural_stack_commands()!r}", None)

if not (start.get("arrows") == 1 and start.get("value") == 0 and candidates["accepted"]):
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

inert = press_arrow_and_watch()
ev.check("448/the-arrows-own-press-is-inert-which-is-why-the-menu-drives-it",
         inert.get("press_status") == 0 and inert.get("value_after") == inert.get("value"),
         "AXPress on the arrow reports success and moves nothing — recorded here so the choice of "
         "actuator below is a measurement rather than a preference",
         f"{inert!r}",
         None)

d = E.Driver()
time.sleep(4)
before_body, before_ok = read_tracks_settled(d, "448/before-read-settled")
first_stacks, first_plain, first_unread, first_total = partition(before_body)

ev.check("448/precondition-the-tracks-resource-is-a-live-read",
         before_ok and before_body.get("source") == "ax_live",
         "the document under test came from the Accessibility scrape, not from placeholder rows "
         "synthesised out of the project file's track count",
         f"source={before_body.get('source')!r} rows={first_total} settled={before_ok}", None)

ev.check("448/precondition-the-arrangement-has-rows-that-are-not-the-stack",
         len(first_plain) > 0,
         "at least one ordinary track exists, so the checks about what a NON-stack row reports "
         "have something to look at — `all()` over an empty list is true and would pass silently",
         f"plain rows={len(first_plain)} of {first_total}", None)

if not before_ok or not first_stacks or not first_plain:
    d.close(); print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=240)
before_shot = ev.shot("448/closed", settle_region=QUIET_BAND)
# Named before the try so the restoration record can quote them even if the body dies early.
toggle, back, restored_state = {}, {}, {}

try:
    # ---- the reading, before anything is touched ---------------------------------------------

    ev.check("448/exactly-one-row-is-called-a-stack-header",
             len(first_stacks) == 1 and len(first_unread) == 0
             and len(first_plain) == first_total - 1,
             "one row of the arrangement is reported as a stack main track and every other row is "
             "reported as examined-and-not-one — the window carries other disclosure triangles "
             "(inspector and browser lists) and none of them is mistaken for a track stack",
             f"stack={[r.get('name') for r in first_stacks]} plain={len(first_plain)} "
             f"unexamined={len(first_unread)} of {first_total}",
             "widen the extractor from the header's own children to the window subtree: the count "
             "goes to the number of triangles anywhere on screen and rows that are not stacks are "
             "labelled as ones")

    ev.check("448/the-row-and-the-arrow-are-the-same-track",
             first_stacks[0].get("name") == start.get("owner"),
             "the row the product calls a stack header is the track whose header physically "
             "carries the arrow, matched by name — not merely the first row of one list against "
             "the first element of another",
             f"published={first_stacks[0].get('name')!r} arrow owner={start.get('owner')!r}",
             "report the stack flag against a fixed index instead of the header it was read from: "
             "the two names then disagree on any project where the stack is not track 0")

    ev.check("448/a-row-that-is-not-a-stack-reports-no-collapsed-state",
             all(r.get("stack_collapsed") is None for r in first_plain),
             "no ordinary track carries a collapsed flag at all — `false` there would be a state "
             "that does not exist, and a consumer could not tell it from an expanded stack",
             f"rows checked={len(first_plain)} · offenders="
             f"{[r.get('name') for r in first_plain if r.get('stack_collapsed') is not None]}",
             "default `stack_collapsed` to false for non-stack rows: every ordinary track then "
             "claims to be an expanded stack")

    ev.check("448/the-collapsed-flag-agrees-with-the-arrow-logic-draws",
             first_stacks[0].get("stack_collapsed") == (start.get("value") == 0),
             "the published flag matches the arrow's own AXValue, read from that same track's "
             "header by a separately built tool, so this is a readback of the application rather "
             "than of the server's own idea",
             f"published={first_stacks[0].get('stack_collapsed')!r} "
             f"arrow AXValue={start.get('value')!r} on {start.get('owner')!r}",
             "invert the 0/1 mapping: the two instruments then disagree here AND the follow check "
             "below goes red in the other direction")

    # ---- disclose the stack and require the flag to follow -------------------------------------

    toggle = toggle_disclosure()
    disclosed_at = time.time()
    after_body, after_fresh = read_tracks_after(d, disclosed_at, "448/read-after-disclosure")
    after_stacks, after_plain, after_unread, after_total = partition(after_body)
    after_arrow = arrow_state()
    after_shot = ev.shot("448/open", settle_region=QUIET_BAND)
    ev.note("448/actuation", {"menu": toggle, "arrow": [start.get("value"), after_arrow.get("value")],
                              "arrows": [start.get("arrows"), after_arrow.get("arrows")],
                              "rows": [first_total, after_total], "fresh": after_fresh})

    ev.check("448/logic-itself-disclosed-the-stack",
             toggle.get("moved") is True
             and isinstance(after_arrow.get("value"), int)
             and after_arrow.get("value") != start.get("value")
             and after_arrow.get("arrows") == 1
             and after_total > first_total,
             "the menu entry Logic named actually ran: the arrow's value flipped and the "
             "arrangement now has more track headers, because the subtracks appeared. Without this "
             "the next check could pass on a field that moved for some other reason",
             f"menu={toggle.get('title')!r} arrow {start.get('value')!r} -> "
             f"{after_arrow.get('value')!r} · headers {first_total} -> {after_total}",
             None)

    ev.check("448/the-published-flag-follows-the-ui",
             len(after_stacks) == 1
             and after_stacks[0].get("stack_collapsed") is False
             and after_stacks[0].get("name") == start.get("owner"),
             "the same named stack now reads as expanded, from a cache snapshot written after the "
             "disclosure — the field produces both answers on one project, which a constant cannot",
             f"{first_stacks[0].get('name')!r} collapsed "
             f"{first_stacks[0].get('stack_collapsed')!r} -> "
             f"{after_stacks[0].get('stack_collapsed')!r} (fresh={after_fresh})",
             "hardcode `collapsed: true` in the extractor: this check goes red while the pre-"
             "disclosure reading above stays green — that pair is what tells a reading from a "
             "constant")

    ev.check("448/the-subtracks-that-appeared-claim-nothing",
             len(after_stacks) == 1 and len(after_unread) == 0
             and all(r.get("stack_collapsed") is None for r in after_plain),
             "the rows Logic revealed inside the stack are each reported as examined-and-not-a-"
             "stack, and none of them carries a collapsed flag — the rows this run itself created "
             "are held to the same rule as the ones that were already there",
             f"rows {first_total} -> {after_total} · stack rows="
             f"{[r.get('name') for r in after_stacks]} · unexamined={len(after_unread)} · "
             f"subtrack offenders="
             f"{[r.get('name') for r in after_plain if r.get('stack_collapsed') is not None]}",
             "default `stack_collapsed` to false for non-stack rows: the 23 rows that appear here "
             "carry the default and the check goes red, which the pre-disclosure reading alone "
             "would not have caught")

    ev.visual("448/the-arrangement-visibly-opened",
              before_shot["file"], after_shot["file"], QUIET_BAND, subject=QUIET_BAND_SUBJECT,
              expect_change=True,
              why="the subtracks Logic revealed are drawn into the empty part of the track-header "
                  "rail, so a band that was flat grey while the stack was closed must not be flat "
                  "grey now — a flag that flipped while the screen stayed still would be "
                  "describing something other than what the user sees")

finally:
    # The stack is put back whatever happened above. Without this a run that dies mid-way leaves the
    # user's arrangement open and writes no restoration record at all — an absent claim rather than
    # a false one, but the arrangement is changed either way.
    back = toggle_disclosure()
    restored_state = arrow_state()

final_body, final_fresh = read_tracks_after(d, time.time() - 1, "448/read-after-restore")
final_stacks, _, _, final_total = partition(final_body)

ev.check("448/the-flag-comes-back-too",
         restored_state.get("value") == start.get("value")
         and final_stacks
         and final_stacks[0].get("stack_collapsed") == first_stacks[0].get("stack_collapsed"),
         "closing the stack again returns both the arrow and the published flag to where they "
         "started, so the field tracks the state in both directions rather than latching once",
         f"arrow -> {restored_state.get('value')!r} (started {start.get('value')!r}) · collapsed "
         f"-> {(final_stacks[0].get('stack_collapsed') if final_stacks else None)!r} "
         f"(started {first_stacks[0].get('stack_collapsed')!r}, fresh={final_fresh})",
         "latch the flag after the first read: the value stays at the disclosed reading and this "
         "check goes red on its own")

d.close()
# The restoration claim is decided by the ARROW, read live, and not by the cached row count: a
# snapshot can be provably post-restore and still be counted while Logic redraws, which would
# report a restored project as unrestored.
ev.restored("448/the-stack-is-closed-again",
            restored_state.get("value") == start.get("value"),
            f"the stack was disclosed through {toggle.get('title')!r} and closed again through "
            f"{back.get('title')!r}; the arrow reads {restored_state.get('value')!r} and started at "
            f"{start.get('value')!r}, with the arrangement back to {final_total} headers "
            f"(started {first_total}). Nothing else in the project was touched.")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
