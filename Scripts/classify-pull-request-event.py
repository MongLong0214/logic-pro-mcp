#!/usr/bin/env python3
"""Does this webhook event need code validation, or did somebody only edit a description?

`ci.yml` used to subscribe to `edited` because RETARGETING a pull request arrives as `edited` --
there is no separate event for it -- and a change that merges into a different branch has not been
validated against the branch it now merges into. The cost of that subscription was a full macOS
compile and test run every time anybody fixed a typo in a title, and, because the two shared a
concurrency group, the cancellation of the run that was already going. `classify()` was written to
make that subscription cheap.

IT DID NOT MAKE IT SAFE, and #960 is the measurement. A metadata-only run publishes NO check run
under `build`, `compile` or `test` -- that is the point of the renaming described below -- but it
still creates a check SUITE, and the branch ruleset reads the newest suite for an app. So on #959
every tool reported the three contexts green while `PUT /pulls/959/merge` answered `3 of 4 required
status checks are expected`, and `gh run rerun` did not clear it because a rerun creates no newer
suite. The cost of a typo in a description had become a close-and-reopen, or a second 30-minute
macOS run.

So `edited` is no longer in `ci.yml`'s trigger, and the retarget that subscription existed for is
caught by `review_edit()` below, which `pr-policy.yml` calls -- required, subscribed to `edited`,
and about fifteen seconds long. An edit that is not metadata turns that required context RED, which
blocks the merge until a code event revalidates the pull request against what it now is. The rule
did not move; the enforcement site did, from a workflow that had to re-run the code to one that
only has to refuse.

WHY `classify()` IS STILL HERE
------------------------------
`ci.yml` receives `opened`, `synchronize`, `reopened` and `push`, and `classify()` answers `code`
for every one of them, so the condition and the renaming on its gated jobs cannot fire today. They
stay because they are what makes the trigger list safe to change: `edited` was removed from it once
and the reasoning for that removal is in one place, this file and the case that pins the list. If
somebody re-subscribes `edited`, the pieces that keep a skipped job from publishing a satisfied
required context are already in place rather than needing to be rediscovered.

WHY THIS IS NOT AN `if:` ON THE HEAVY JOBS ALONE
------------------------------------------------
A job skipped by an `if:` still publishes a check run under its own name, and GitHub counts a
`skipped` required check as satisfied. So the naive form of this optimisation -- keep the job,
skip its steps -- would let a title edit publish `compile: skipped` over a real `compile: failure`
on the same head commit and open the merge. The workflow answers that by changing the job's NAME
as well as its condition: on a metadata-only edit those jobs would be published under names that
are not the required contexts, so the canonical verdicts from the code run are left alone.

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

#: What `review_edit()` answers, and what `--refuse-unvalidated-edit` turns into an exit status.
#: `REFUSE` is not "this pull request is bad"; it is "the code gates have not seen this pull
#: request as it now is, and no event they subscribe to is going to arrive on its own".
ALLOW = "allow"
REFUSE = "refuse"


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


def review_edit(event_name: str, event: object) -> str:
    """May this `edited` stand on the code verdicts already on the commit?

    `ALLOW` only when this event positively cannot have changed what the pull request is: anything
    that is not an `edited` (the code workflow runs on those itself), and an `edited` that
    `classify()` calls metadata-only.

    Everything else is `REFUSE`, including every case where the answer is not knowable -- an
    unreadable payload, an event that is not a `pull_request`, an `edited` with no `changes`. Those
    are the same three shapes `classify()` sends to full code validation, and the reason is the
    same: not being able to tell is not evidence that nothing changed. The consequence here is a red
    required check on a pull request whose author can clear it by pushing or by reopening, which is
    the cheap direction to be wrong in.
    """
    if event_name != "pull_request" or not isinstance(event, dict):
        return REFUSE
    if event.get("action") != "edited":
        return ALLOW
    return ALLOW if classify(event_name, event) == METADATA_ONLY else REFUSE


def read_event(path: str) -> object:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        # Unreadable is not "nothing changed". The caller turns anything that is not the
        # metadata-only token into full code validation, and this returns a value that cannot be
        # mistaken for a classified payload.
        return None


#: The one flag, spelled out rather than parsed, because `.github/ci/CI-GATE.json` pins the whole
#: invocation and an option parser would let a typo become a step that decides nothing.
REFUSE_FLAG = "--refuse-unvalidated-edit"


def refuse_unvalidated_edit(event_name: str, event: object) -> int:
    """`pr-policy.yml`'s entry point. Exit 1 is the red required check that blocks the merge."""
    verdict = review_edit(event_name, event)
    print(verdict)
    if verdict == ALLOW:
        return 0
    # Workflow commands are read from stdout. Nothing from the payload is echoed: a title and a
    # body are attacker-controlled strings and an annotation is a rendering surface.
    print("::error::This pull request was edited in a way that is not a title or a body change --")
    print("::error::a retarget names `changes.base` -- or in a way this check could not read. The")
    print("::error::code gates (build, compile, test) run on opened, synchronize and reopened and")
    print("::error::NOT on `edited`, so nothing has validated this pull request as it now is.")
    print("::error::Push a commit, or close and reopen the pull request, and this check clears.")
    print("::error::Why the code gates do not subscribe to `edited`: issue #960. A run on `edited`")
    print("::error::creates a newer check suite that reports none of the three contexts, and the")
    print("::error::ruleset reads the newest suite -- so the merge was blocked by the edit itself.")
    return 1


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    path = os.environ.get("GITHUB_EVENT_PATH", "")
    event = read_event(path) if path else None
    if argv == [REFUSE_FLAG]:
        return refuse_unvalidated_edit(event_name, event)
    if argv:
        print(f"usage: {os.path.basename(sys.argv[0])} [{REFUSE_FLAG}]", file=sys.stderr)
        return 2
    decision = classify(event_name, event)
    print(decision)
    # The reason goes to stderr so the step log explains itself without the token on stdout ever
    # having to be parsed out of prose.
    print(f"event_name={event_name!r} decision={decision}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
