# livekit — live evidence against the running Logic Pro

A green unit suite says the code does what its fixtures say. Only a run against the real application says
it does what the user needs. On 2026-08-14 three changes here passed every unit test and the ship gate
while being dead or wrong live: `transport.goto_position` refused every call because a window property it
serialized cannot be read on Logic's windows, the modal reconciler stopped recognising the sheet it exists
to press, and a marker delete could not verify a deletion that had happened. Nothing but a live run found
any of them.

This directory is the instrument for those runs. It lives in the repo rather than a scratch directory
because the previous copy was deleted by a `/tmp` sweep mid-investigation.

## Running one

```sh
LPM_EVIDENCE_ROOT=/abs/path/outside/every/worktree \
  python3 Scripts/livekit/live_538_modal_reconcile.py <worktree> <full-40-char-head-sha>
```

Requires Logic Pro running, a release binary at `<worktree>/.build/release/LogicProMCP`, and a terminal
with Accessibility + Automation permission. `Scripts/livekit/evidence.py` refuses to start if any of that
is missing rather than producing a document that looks like evidence.

`~/.claude/scripts/lpm-ship.sh` reads the document this writes and refuses to push without it. The evidence
root must be outside every worktree of the repository: evidence living inside the tree can be rewritten by
the thing it is judging.

## What `evidence.py` will not let you record

Each of these exists because that exact false evidence was produced without it.

| refused | why |
|---|---|
| an unsettled capture | a screenshot taken mid-redraw shows a state nobody was in; `shot()` waits for two identical frames |
| a capture straddling displays | on a multi-monitor desk a window can span screens; the image then matches nothing the user saw |
| a region-less visual assertion | a whole-window diff changes when the clock ticks and proves nothing specific |
| a check with no named mutation | a check nobody has watched fail is decoration, not evidence |
| a cached read presented as live | `provenance()` records the source and age and marks it unusable |

Two hardware facts are baked in because guessing them cost hours: a window capture is in backing PIXELS
(3840x2100 for a 1920x1050 window), so regions given in window points are scaled; and `screencapture -v`
only finalises its file when its own `-V` timer elapses — SIGINT, SIGTERM, closing stdin and a
process-group SIGINT all leave NO file at all.

## Writing a new harness

Copy the closest existing one. Then:

- **Derive regions from the element, not from a guess.** `live_523_marker_delete.py` asks the witness node
  where it is. An earlier version guessed the top of the window; the node is near the bottom, so the
  assertion compared two identical wrong crops and read as "nothing changed" on a run that plainly worked.
- **Read the independent witness through a path the product does not use.** The 523 harness reads Logic's
  marker count through System Events. A check that reads what the product reads is a mirror, not a witness.
- **Bound every precondition loop and fail loudly.** A reduction loop with no attempt cap ran against a
  refusal it could never satisfy until it was killed. A precondition that cannot converge must say so.
- **Follow the product's own contract in preconditions.** `track.delete` refuses an ambiguous
  `expected_name` and its hint says to rename by index first. The harness ignored that twice — once with a
  name, once by guessing `target_ref` would help — and both times the answer was already in the envelope.
- **Record the operation, not the setup.** Start the recording after the precondition.
- **Cover the call site you changed, not a neighbouring one.** `live_538_modal_reconcile.py` drives the
  mandatory New Track sheet through `track.delete`; the create route reaches the same sheet through
  different code. A green 538 run said nothing about the create fix, and writing
  `live_542_track_create_retry.py` for that call site is what surfaced #549 on its first run.
- **Assert what you can make happen, and record what you cannot.** `live_289_stale_write_guard_fires.py`
  was written to prove that driving mutations makes `dropped_stale_writes` rise, because a single run had
  shown exactly that. Three repeats refuted it: the counter moved in 2 of 5 runs, in different phases, and
  never in the contended window. A start-up explanation died the same way against a 0.4s sample. The
  harness now asserts the four things that are observable — the key exists, the poller advances, the
  counter neither runs away nor decreases — and its evidence document carries
  `counter_reachable_on_demand: false` so the next person does not re-measure the same wall. Tuning the
  original assertion until it passed would have produced a green harness certifying a mechanism nobody
  has ever seen fire.
- **A missing key reads as a falsy value.** That harness first queried `cache_age_ms` against an envelope
  that emits `cache_age_sec`. The absent key came back `None`, which compares like "empty", and the wrong
  conclusion — "the field is declared but never populated" — happened to agree with a true fact about an
  unwired struct. Agreement between a real fact and a measurement error is not corroboration. Assert the
  key is PRESENT before asserting anything about its value.
- **When a check goes red, measure the baseline before calling it a regression.** Re-run the same harness
  against the pre-change binary in the same worktree and session. #549's receipt was byte-for-byte
  identical at `HEAD~1`, which is the difference between a blocker and a separate pre-existing issue.
- **Leave a true red check red.** A harness edited until it agrees with the product is no longer an
  instrument. Name the open issue in the docstring instead.

## `check_review_integrity.sh`

Blind reviews arrive as text over a transport that has been observed to interleave two of its own streams
into one output. Run this over a review before treating it as a verdict. Exit codes are distinct because
"damaged" and "cannot be checked" are different answers: `0` intact, `1` damage detected, `2` integrity
undetermined — and undetermined is not a pass.

The envelope and the contents fail separately. "These are all the findings" belongs to the envelope and
dies with it. An individual finding carrying file:line and a reproduction path verifies against the repo on
its own terms and survives the transport that damaged it.
