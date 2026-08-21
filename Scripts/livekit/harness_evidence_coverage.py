#!/usr/bin/env python3
"""Which live harnesses a branch changed, and whether each of them proved itself at this head.

Usage:  python3 harness_evidence_coverage.py <worktree> <head-sha> <evidence-root> [base-ref]

#612, item 2. The gate reads ONE document per head — `<root>/<head>/evidence.json`, whichever
harness wrote it last. On a branch carrying two harnesses that means it can only ever validate the
last one run, while reporting `ok`. It happened: running #606's harness on the #608 branch to check
for a regression overwrote #608's own evidence, and the gate then validated #608 against #606's
proof. Both were clean, so nothing looked wrong.

Items 1 and 3 are already in `evidence.py` — the per-harness filename and the rotation that keeps
an earlier document instead of replacing it. They make this possible; this is the part that changes
what the gate can CLAIM.

WHAT "TOUCHED" MEANS HERE, AND WHAT IT DOES NOT
-----------------------------------------------
A harness is required to have proved itself when the branch CHANGED it:

    git diff --name-only <base>...HEAD -- Scripts/livekit/live_*.py

That is decidable from the diff, and it is exactly the case that went wrong. What is NOT decidable,
and is not attempted here: which harnesses a `Sources/` change ought to have been proved against.
Nothing in the tree records that mapping, and inventing one would put a guess where this check's
whole value is that it does not guess. A branch that changes only `Sources/` therefore passes this
check with nothing required — the existing "live evidence for this head" step is what covers it.

So this is a coverage floor, not a coverage proof. Said plainly because a check named `coverage`
invites being read as more.
"""
import glob
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


def harness_stems(changed_paths):
    """The live-harness stems among a list of changed repo paths.

    Takes paths rather than running git, so the rule can be tested without a repository. Deletions
    are the caller's problem to filter — a path that no longer exists cannot be required to have
    run, and requiring it would make deleting a harness impossible.
    """
    stems = set()
    for path in changed_paths or []:
        name = os.path.basename(path)
        if not name.startswith("live_") or not name.endswith(".py"):
            continue
        if os.path.dirname(path).replace("\\", "/").endswith("Scripts/livekit"):
            stems.add(name[: -len(".py")])
    return stems


def documents_present(head_dir):
    """`{stem: path}` for every per-harness document in a head directory.

    `evidence.json` is deliberately not counted. It is the legacy single-file name — the last run at
    this head whatever produced it — and counting it would let one harness's document satisfy the
    requirement for another, which is the defect.
    """
    found = {}
    for path in sorted(glob.glob(os.path.join(head_dir, "*.evidence.json"))):
        stem = os.path.basename(path)[: -len(".evidence.json")]
        found[stem] = path
    return found


def verdict(required, present_paths, read_document=None):
    """`(missing, unclean)` — harnesses with no document, and ones whose document is not clean.

    `read_document` is injected so the rule can be exercised without files on disk. It takes a path
    and returns the parsed document, or None when it cannot be read; an unreadable document counts
    as unclean rather than as absent, because "it ran and produced something unusable" and "it never
    ran" are different facts and only one of them is a missing run.
    """
    read_document = read_document or _read_json
    missing = sorted(s for s in required if s not in present_paths)
    unclean = []
    for stem in sorted(required):
        if stem not in present_paths:
            continue
        doc = read_document(present_paths[stem])
        summary = E.summarize((doc or {}).get("records"))
        if not E.is_clean(summary):
            unclean.append(stem)
    return missing, unclean


def _read_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def changed_paths(worktree, base, head="HEAD"):
    """Paths the branch changed, excluding deletions.

    `head` is the commit the caller is asking ABOUT, not the worktree's current one. The first
    version hard-coded `HEAD` and took the head sha only to look up an evidence directory, so a
    gate invoked for one commit computed coverage from whatever the tree happened to be sitting on.
    In a pre-push hook those are the same and it would never have shown; anywhere else they are
    not, and the failure is a coverage verdict about the wrong commit reported as a verdict about
    this one.

    `--diff-filter=d` drops deletions. A harness that no longer exists cannot be required to have
    run, and requiring it would make deleting a harness impossible — the branch could never
    produce the evidence, because there is nothing left to produce it.
    """
    proc = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=d", f"{base}...{head}"],
        cwd=worktree, capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    return [p for p in proc.stdout.splitlines() if p.strip()]


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    worktree, head, root = argv[1], argv[2], argv[3]
    base = argv[4] if len(argv) > 4 else "origin/main"

    paths = changed_paths(worktree, base, head)
    if paths is None:
        print(f"-> COVERAGE FAIL: could not diff {base}...HEAD in {worktree}")
        return 2
    required = harness_stems(paths)
    if not required:
        print("n/a — this branch changes no live harness")
        return 0

    head_dir = os.path.join(root, head)
    present = documents_present(head_dir)
    missing, unclean = verdict(required, present)

    print(f"   harnesses changed by this branch: {len(required)}")
    for stem in sorted(required):
        state = "missing" if stem in missing else ("UNCLEAN" if stem in unclean else "ok")
        print(f"   {state:>7}  {stem}")
    if missing:
        print(f"-> COVERAGE FAIL: no evidence at {head_dir} for: {', '.join(missing)}")
    if unclean:
        print(f"-> COVERAGE FAIL: evidence present but not clean for: {', '.join(unclean)}")
    return 1 if (missing or unclean) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
