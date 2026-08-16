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

## `check_review_integrity.sh`

Blind reviews arrive as text over a transport that has been observed to interleave two of its own streams
into one output. Run this over a review before treating it as a verdict. Exit codes are distinct because
"damaged" and "cannot be checked" are different answers: `0` intact, `1` damage detected, `2` integrity
undetermined — and undetermined is not a pass.

The envelope and the contents fail separately. "These are all the findings" belongs to the envelope and
dies with it. An individual finding carrying file:line and a reproduction path verifies against the repo on
its own terms and survives the transport that damaged it.
