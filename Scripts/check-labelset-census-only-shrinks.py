#!/usr/bin/env python3
"""The census of LabelSets naming no Apple row may only SHRINK, and it must stay complete.

Two directions, and the second is the one a ratchet usually forgets.

**It may not grow.** Compared against `git merge-base HEAD origin/main`, a name added to
`docs/canon/LABELSETS-WITHOUT-A-ROW-LEGACY.json` is a new undeclared LabelSet wearing a legacy
label. `check-new-labelsets-name-a-row.py` already refuses a new set with no row; this stops the
census becoming the place such a set goes to be forgiven.

**It must stay COMPLETE.** Every LabelSet in the policy that declares no `derivedFrom` has to be
in here. Without that half, deleting a line would "close" an entry while the gap stays in the
tree -- the count would fall and nothing would have improved, which is the failure mode a
shrink-only list invites. Completeness is what makes the number mean something.

The census carries what `derive_label_variants.py` said about each entry, so the remaining work is
sized rather than guessed. Those verdicts are NOT checked here: the tool needs Logic's bundle, and
a guard that cannot run on a machine without Logic is a guard CI cannot run. The name set is the
contract; the verdicts are a note to whoever picks one up.

Exit: 0 = complete and not grown · 1 = grown, or a policy set is missing from it
"""
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
#: Seams, so the self-test can drive main() at a tree that must fail.
POLICY = os.environ.get("LPM_POLICY_SWIFT") or os.path.join(
    REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
CENSUS = os.environ.get("LPM_LABELSET_CENSUS") or os.path.join(
    REPO, "docs", "canon", "LABELSETS-WITHOUT-A-ROW-LEGACY.json")
BASE_REF = os.environ.get("LPM_LABELSET_BASE_REF", "origin/main")

DECLARATION = re.compile(r"static let (\w+) = LabelSet\(")


def undeclared_in(source: str) -> set:
    """Every LabelSet in a policy source that names no row."""
    names = set()
    for match in DECLARATION.finditer(source):
        end = source.find("\n    )", match.start())
        if end == -1:
            continue
        if "derivedFrom:" not in source[match.start():end]:
            names.add(match.group(1))
    return names


def census_names(path: str) -> set:
    with open(path, encoding="utf-8") as handle:
        return set((json.load(handle).get("undeclared") or {}).keys())


def base_census() -> set:
    """The census as of the merge base, or None when it cannot be read.

    `None` is not an empty set. An unreadable base would make every entry look new, which is the
    direction that fails LOUD rather than the one that passes a grown list.
    """
    try:
        base = subprocess.run(["git", "merge-base", "HEAD", BASE_REF], cwd=REPO,
                              capture_output=True, text=True, check=True).stdout.strip()
        rel = os.path.relpath(CENSUS, REPO)
        blob = subprocess.run(["git", "show", f"{base}:{rel}"], cwd=REPO,
                              capture_output=True, text=True, check=True).stdout
        return set((json.loads(blob).get("undeclared") or {}).keys())
    except subprocess.CalledProcessError:
        # `git show` fails when the path does not exist at the base. That is the commit that
        # INTRODUCES the census, and its ratchet cannot run against a file that was not there --
        # the same bootstrap `check-canon-citations.py` prints a note for. Distinguished from
        # "unreadable" below so a corrupt census is never mistaken for a new one.
        return "absent"
    except (ValueError, OSError):
        return None


def main() -> int:
    with open(POLICY, encoding="utf-8") as handle:
        policy = undeclared_in(handle.read())
    try:
        listed = census_names(CENSUS)
    except (OSError, ValueError) as exc:
        print(f"cannot read the census at {CENSUS}: {exc}", file=sys.stderr)
        return 1

    problems = []
    missing = sorted(policy - listed)
    if missing:
        problems.append(
            f"{len(missing)} LabelSet(s) name no row and are not in the census, first "
            f"{missing[0]}. A census with a hole in it makes its own number meaningless.")
    stale = sorted(listed - policy)
    if stale:
        problems.append(
            f"{len(stale)} census entr(y/ies) name a LabelSet that now declares a row or no "
            f"longer exists, first {stale[0]}. Delete the line -- that is what shrinking is.")

    base = base_census()
    if base == "absent":
        print(f"note: the census is not carried by the merge base, so this is the commit that "
              f"introduces it and its growth ratchet does not run here. It runs on the next "
              f"branch -- a name added alongside the file itself is invisible until then.")
        base = listed
    if base is None:
        print(f"CANNOT DETERMINE: the census at {BASE_REF} could not be read, so growth cannot be "
              f"measured. Comparing against nothing would report clean.", file=sys.stderr)
        return 1
    grown = sorted(listed - base)
    if grown:
        problems.append(
            f"{len(grown)} name(s) ADDED to a list that may only shrink: {', '.join(grown)}. "
            f"A LabelSet added today names its row or proves there is none; the census is for the "
            f"ones that predate the rule, not a place to send new ones.")

    if problems:
        print(f"{len(problems)} problem(s) with the LabelSet census:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    print(f"the census is complete and has not grown: {len(listed)} LabelSet(s) name no row, "
          f"of {len(DECLARATION.findall(open(POLICY, encoding='utf-8').read()))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
