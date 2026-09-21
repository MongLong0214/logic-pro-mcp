#!/usr/bin/env python3
"""Does this webhook event need code validation, or did somebody only edit a description?

`ci.yml` subscribes to `edited` because RETARGETING a pull request arrives as `edited` -- there is
no separate event for it -- and a change that merges into a different branch has not been validated
against the branch it now merges into. The cost of that subscription used to be a full macOS
compile and test run every time anybody fixed a typo in a title, and, because the two shared a
concurrency group, the cancellation of the run that was already going.

WHY THIS IS NOT AN `if:` ON THE HEAVY JOBS ALONE
------------------------------------------------
A job skipped by an `if:` still publishes a check run under its own name, and GitHub counts a
`skipped` required check as satisfied. So the naive form of this optimisation -- keep the job,
skip its steps -- would let a title edit publish `compile: skipped` over a real `compile: failure`
on the same head commit and open the merge. The workflow answers that by changing the job's NAME
as well as its condition: on a metadata-only edit those jobs are published under names that are
not the required contexts, so the canonical verdicts from the code run are left alone.

WHAT COUNTS AS METADATA-ONLY
----------------------------
Only a `pull_request` `edited` whose `changes` object says title and/or body and says nothing
else. Everything else is code validation: a push, an `opened`/`synchronize`/`reopened`, an
`edited` carrying `changes.base`, an `edited` whose `changes` is absent or empty, and an `edited`
naming any key this code has not been taught. The last one matters most -- a future editable field
that changes what the pull request MEANS would otherwise inherit the exemption by being unknown,
which is the same shape as a fallback-safe enum case, and this repository has paid for that twice.

The payload is read from the file GitHub writes (`GITHUB_EVENT_PATH`). A title and a body are
attacker-controlled strings; they are never interpolated into a shell command, and nothing here
prints any part of them.
"""
import json
import os
import sys

#: The `changes` keys that describe a pull request's PROSE. `base` is deliberately absent: a
#: retarget changes what the change merges into, so it is code validation.
METADATA_KEYS = frozenset({"title", "body"})

CODE = "code"
METADATA_ONLY = "metadata-only"


def classify(event_name: str, event: object) -> str:
    """`metadata-only` only when the payload positively says so; `code` for everything else."""
    if event_name != "pull_request":
        return CODE
    if not isinstance(event, dict):
        return CODE
    if event.get("action") != "edited":
        return CODE
    changes = event.get("changes")
    # An `edited` that does not say what changed has not told us it is safe to skip.
    if not isinstance(changes, dict) or not changes:
        return CODE
    if not set(changes) <= METADATA_KEYS:
        return CODE
    return METADATA_ONLY


def read_event(path: str) -> object:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        # Unreadable is not "nothing changed". The caller turns anything that is not the
        # metadata-only token into full code validation, and this returns a value that cannot be
        # mistaken for a classified payload.
        return None


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    path = os.environ.get("GITHUB_EVENT_PATH", "")
    event = read_event(path) if path else None
    decision = classify(event_name, event)
    print(decision)
    # The reason goes to stderr so the step log explains itself without the token on stdout ever
    # having to be parsed out of prose.
    print(f"event_name={event_name!r} decision={decision}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
