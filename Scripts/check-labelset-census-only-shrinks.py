#!/usr/bin/env python3
"""The census of LabelSets naming no Apple row may only SHRINK, and it must stay complete.

Two directions, and the second is the one a ratchet usually forgets.

**It may not grow with a set that is NEW.** Compared against `git merge-base HEAD origin/main`, a
name added to `docs/canon/LABELSETS-WITHOUT-A-ROW-LEGACY.json` is refused unless that LabelSet
already named no row AT THE BASE -- read out of the base's own policy source, not out of the base's
census. `check-new-labelsets-name-a-row.py` already refuses a new set with no row; this stops the
census becoming the place such a set goes to be forgiven.

Comparing against the base CENSUS was the first rule and it was wrong in the direction that hurts:
it made the census unfixable. Three LabelSets -- `eventListColumnM`, `eventListColumnName`,
`eventListColumnPosition` -- name no row and were invisible to this guard's own parser, so they
were missing from a census the guard called complete. Adding them is not growth; it is the list
catching up with the tree, and a rule that cannot tell those apart forbids the repair.

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
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
#: Seams, so the self-test can drive main() at a tree that must fail.
POLICY = os.environ.get("LPM_POLICY_SWIFT") or os.path.join(
    REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
CENSUS = os.environ.get("LPM_LABELSET_CENSUS") or os.path.join(
    REPO, "docs", "canon", "LABELSETS-WITHOUT-A-ROW-LEGACY.json")
BASE_REF = os.environ.get("LPM_LABELSET_BASE_REF", "origin/main")
#: The base's two files, as CONTENT rather than as a ref. `git show <base>:<path>` can only reach a
#: path the base carries, so a case that points the seams above at a temporary tree cannot produce
#: a base for them -- the run degrades to the bootstrap note and the growth rule does not run,
#: which is how the refusing direction went untested. Same shape as LPM_RATCHET_BASE_JSON.
BASE_CENSUS_FILE = os.environ.get("LPM_LABELSET_BASE_JSON")
BASE_POLICY_FILE = os.environ.get("LPM_LABELSET_BASE_POLICY")

def _parser():
    """The reader `check-labelsets-are-derived.py` uses, rather than a second one written here.

    This guard had its own: a regex for the opening line and `source.find("\\n    )")` for the end.
    A declaration that closes on the same line as its last argument was not delimited by that
    search, so the span it examined ran on into a LATER declaration, found that one's
    `derivedFrom:`, and concluded the set named a row. Measured 2026-09-20: the regex parser saw 58
    undeclared LabelSets, the balanced one 61, and the three it could not see are exactly the ones
    a census of 58 called complete.

    A second copy of a parser is a second copy of the truth, and it went stale in the direction
    where the checking is missing. Loaded by path because the sibling is a script, not a module.
    """
    import importlib.util
    path = os.path.join(REPO, "Scripts", "check-labelsets-are-derived.py")
    spec = importlib.util.spec_from_file_location("labelsets_are_derived_for_census", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def undeclared_in(source: str) -> set:
    """Every LabelSet in a policy source that names no row.

    Raises whatever the shared parser raises on a declaration it cannot read. A guard that SKIPS
    one reports clean over it, which is how three of them went uncounted.
    """
    return {name for name, _members, derived in _parser().declarations(source) if not derived}


def declared_count(source: str) -> int:
    return sum(1 for _ in _parser().declarations(source))


def census_names(path: str) -> set:
    with open(path, encoding="utf-8") as handle:
        return set((json.load(handle).get("undeclared") or {}).keys())


def _at_base(rel: str) -> str:
    base = subprocess.run(["git", "merge-base", "HEAD", BASE_REF], cwd=REPO,
                          capture_output=True, text=True, check=True).stdout.strip()
    return subprocess.run(["git", "show", f"{base}:{rel}"], cwd=REPO,
                          capture_output=True, text=True, check=True).stdout


def _base_file(override: str, rel: str) -> str:
    if override:
        with open(override, encoding="utf-8") as handle:
            return handle.read()
    return _at_base(rel)


def base_undeclared() -> set:
    """Every LabelSet that named no row AT THE MERGE BASE, read from the base's policy source.

    This is what a census addition is checked against. The base CENSUS would answer a different
    question -- "was this name written down" -- and a name that was undeclared and unwritten is
    the one case the repair has to be able to add.
    """
    try:
        return undeclared_in(_base_file(BASE_POLICY_FILE, os.path.relpath(POLICY, REPO)))
    except subprocess.CalledProcessError:
        return "absent"
    except (ValueError, OSError):
        return None


def base_census() -> set:
    """The census as of the merge base, or None when it cannot be read.

    `None` is not an empty set. An unreadable base would make every entry look new, which is the
    direction that fails LOUD rather than the one that passes a grown list.
    """
    try:
        blob = _base_file(BASE_CENSUS_FILE, os.path.relpath(CENSUS, REPO))
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
    added = sorted(listed - base)
    if added:
        was_undeclared = base_undeclared()
        if was_undeclared is None:
            print(f"CANNOT DETERMINE: the policy at {BASE_REF} could not be read, so whether these "
                  f"names predate the branch cannot be answered: {', '.join(added)}",
                  file=sys.stderr)
            return 1
        if was_undeclared == "absent":
            was_undeclared = set(added)  # the bootstrap the note above already describes
        grown = [name for name in added if name not in was_undeclared]
        if grown:
            problems.append(
                f"{len(grown)} name(s) ADDED for LabelSet(s) that did not exist, or DID name a row, "
                f"at the base: {', '.join(grown)}. A LabelSet added today names its row or proves "
                f"there is none; the census is for the ones that predate the rule, not a place to "
                f"send new ones.")
        caught_up = [name for name in added if name in was_undeclared]
        if caught_up:
            # Not a problem: these named no row at the base either. The census was incomplete and
            # is being repaired, which is the direction the completeness half asks for.
            print(f"note: {len(caught_up)} name(s) added for LabelSet(s) that already named no row "
                  f"at the base ({', '.join(caught_up)}). The census was short of the tree.")

    if problems:
        print(f"{len(problems)} problem(s) with the LabelSet census:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    with open(POLICY, encoding="utf-8") as handle:
        total = declared_count(handle.read())
    print(f"the census is complete and gained no new set: {len(listed)} LabelSet(s) name no row, "
          f"of {total}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
