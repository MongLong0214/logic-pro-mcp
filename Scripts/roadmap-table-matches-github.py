#!/usr/bin/env python3
"""Fails when `docs/roadmap/README.md` disagrees with GitHub about what is open.

`docs/roadmap/README.md` declares itself the source of truth for what is open and in what order.
Its own update rule says the same PR that opens or closes an issue updates its table, and then
admits what that is worth: "a convention is a claim", and the stronger form is a check that fails
when the table and GitHub disagree. This is that check.

WHAT IT ENFORCES, AND WHY EACH DIRECTION IS NEEDED
--------------------------------------------------
1. Every row in the table states the state GitHub reports. Catches a row that was never flipped
   when its issue closed.
2. Every issue GitHub reports OPEN appears in the table. Catches the drift the first direction
   cannot see: an issue nobody ever added. This was already true when the check was written —
   #683 was open and absent — so it is not a hypothetical.

The reverse of (2) is deliberately NOT enforced: the table is not required to list every closed
issue that has ever existed, only to be right about the ones it does list.

WHAT WOULD MAKE THIS VACUOUS, AND WHAT STOPS IT
------------------------------------------------
- **A truncated issue list.** `gh issue list` caps at `--limit`, and a capped result looks exactly
  like a complete one. Written against `--limit 200` this check would have compared against the
  newest 200 of 239 issues and reported clean. If the result count reaches the limit, this exits
  `CANNOT_DETERMINE` rather than passing on a list it cannot prove is whole.
- **An unparseable table.** Zero parsed rows compares nothing and passes trivially. That is
  `CANNOT_DETERMINE` too, not clean.

Both are distinguished from a clean run by exit code, so CI cannot read "I could not tell" as "no
drift". `Scripts/test-roadmap-table-guard.sh` drives each of these paths and asserts the codes.

Exit: 0 = table agrees · 1 = drift, listed on stdout · 2 = could not determine
"""
import argparse
import json
import os
import re
import subprocess
import sys

OK, DRIFT, CANNOT_DETERMINE = 0, 1, 2

# `Closes #12`, `fixes #12`, `Resolved: #12` — the forms GitHub itself acts on.
CLOSES = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b[:\s]*#(\d+)", re.I)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_ROADMAP = os.path.join(REPO_ROOT, "docs", "roadmap", "README.md")

# Matches both table shapes in the file: `| ADR-001 | #284 | OPEN | ... |` and `| #308 | OPEN | ... |`
ROW = re.compile(r"\|\s*#(\d+)\s*\|\s*(OPEN|closed)\s*\|")

ISSUE_LIMIT = 1000


def parse_table(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    return {int(number): state.upper() for number, state in ROW.findall(text)}


def fetch_issues(fixture):
    """Returns (issues, error). `issues` maps number -> OPEN/CLOSED."""
    if fixture:
        with open(fixture, encoding="utf-8") as handle:
            rows = json.load(handle)
    else:
        try:
            out = subprocess.run(
                ["gh", "issue", "list", "--state", "all",
                 "--limit", str(ISSUE_LIMIT), "--json", "number,state"],
                capture_output=True, text=True, check=True).stdout
        except (subprocess.CalledProcessError, FileNotFoundError) as exc:
            return None, f"could not ask GitHub for issue state: {exc}"
        rows = json.loads(out)

    if len(rows) >= ISSUE_LIMIT:
        return None, (
            f"`gh issue list` returned {len(rows)} rows against a --limit of {ISSUE_LIMIT}, so the "
            "list may be truncated. Comparing against a partial list would report clean while "
            "missing every issue past the cap. Raise the limit or paginate.")
    return {int(r["number"]): str(r["state"]).upper() for r in rows}, None


def pending_closes(pr, body=None):
    """Issues a pull request declares it closes, which the table may mark closed early.

    A PR that closes an issue cannot describe the result truthfully in its own diff: while it is
    open the issue is open, and the moment it merges the issue is closed and the table it just
    landed is stale. Enforcing both directions with no exception makes that window unavoidable —
    #684 shipped this guard, closed #678, and turned `main` red on the merge commit.

    So on a pull request the table is allowed to be AHEAD of GitHub, but only for the issues that
    pull request says it closes. That is not a general "closed rows are unchecked" hole: on a push
    to `main` no PR number is passed, no issue is exempt, and a row that claims an open issue is
    closed still fails — which is the direction that hides live work.
    """
    if body is None:
        if not pr:
            return set()
        try:
            out = subprocess.run(["gh", "pr", "view", str(pr), "--json", "body", "-q", ".body"],
                                 capture_output=True, text=True, check=True).stdout
        except (subprocess.CalledProcessError, FileNotFoundError):
            return None  # asked, could not tell — the caller refuses rather than guessing
        body = out
    return {int(n) for n in CLOSES.findall(body or "")}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--roadmap", default=DEFAULT_ROADMAP)
    ap.add_argument("--issues-json", default=None,
                    help="read issue state from this JSON file instead of calling gh (self-test)")
    ap.add_argument("--pr", default=None,
                    help="pull request number; its `Closes #N` issues may be marked closed early")
    ap.add_argument("--pr-body", default=None,
                    help="use this text as the pull request body instead of asking gh (self-test)")
    args = ap.parse_args()

    if not os.path.exists(args.roadmap):
        print(f"CANNOT DETERMINE: no roadmap at {args.roadmap}")
        return CANNOT_DETERMINE

    table = parse_table(args.roadmap)
    if not table:
        print(f"CANNOT DETERMINE: parsed 0 issue rows from {args.roadmap}. An empty table agrees "
              "with everything, which is not the same as being correct.")
        return CANNOT_DETERMINE

    issues, error = fetch_issues(args.issues_json)
    if error:
        print(f"CANNOT DETERMINE: {error}")
        return CANNOT_DETERMINE

    pending = pending_closes(args.pr, args.pr_body)
    if pending is None:
        print("CANNOT DETERMINE: a pull request number was given but its body could not be read, "
              "so which issues it closes is unknown. Guessing would either invent an exemption or "
              "fail a correct table.")
        return CANNOT_DETERMINE

    wrong_state = []
    not_an_issue = []
    for number, claimed in sorted(table.items()):
        actual = issues.get(number)
        if actual is None:
            not_an_issue.append(number)
        elif actual != claimed:
            # The one allowed disagreement: this PR closes it, and the table already says so.
            if claimed == "CLOSED" and actual == "OPEN" and number in pending:
                continue
            wrong_state.append((number, claimed, actual))

    # No exemption here, deliberately. A pull request that closes an issue still has to LIST it —
    # marked closed — and exempting it from this direction would let the closing PR delete the row
    # instead, which is the drift this half exists to catch.
    open_and_absent = sorted(n for n, s in issues.items() if s == "OPEN" and n not in table)

    if not (wrong_state or not_an_issue or open_and_absent):
        print(f"roadmap table agrees with GitHub: {len(table)} rows, "
              f"{sum(1 for s in issues.values() if s == 'OPEN')} open issues all listed")
        return OK

    print(f"roadmap table disagrees with GitHub ({args.roadmap}):")
    for number, claimed, actual in wrong_state:
        print(f"  #{number}: table says {claimed}, GitHub says {actual}")
    for number in not_an_issue:
        print(f"  #{number}: listed in the table, but GitHub has no such issue")
    for number in open_and_absent:
        print(f"  #{number}: open on GitHub, absent from the table")
    print("\nThe table is the source of truth for what is open. Update it in this PR.")
    return DRIFT


if __name__ == "__main__":
    sys.exit(main())
