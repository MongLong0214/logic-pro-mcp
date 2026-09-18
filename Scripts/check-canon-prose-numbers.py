#!/usr/bin/env python3
"""A number stated in `docs/canon/README.md` must come from an artifact or a record.

That file is where this repository writes down the rule that a fact about Logic is either cited to
Apple's bytes or proved uncitable. It carried a number the code had already retracted.
`Scripts/logic_canon.py` says in so many words that 295,050 was "arithmetic over three fields,
taken without running the extractor and omitting the `composed` field the index actually stores",
and gives 390,820. The README said 295,050 for as long as that retraction sat two files away.

WHERE THE OBVIOUS IMPLEMENTATION FAILS, and it was measured before this was written
------------------------------------------------------------------------------------
"The number appears somewhere in the tree" PASSES 295,050 -- because the sentence RETRACTING it
contains it. Presence in a retraction is presence, exactly as reasoning about why an alternative is
bad is not a record of turning it down. So the haystack here is generated artifacts and measured
records only, never source prose:

    docs/canon/SOURCES.json      docs/canon/MANIFEST.json      docs/observations/*.json

WHY ONLY THIS FILE, MEASURED RATHER THAN ASSUMED
-------------------------------------------------
Widening to every prose file in the tree was measured and is wrong. Fifty-six of them carry a
four-digit number no artifact backs, and a sample says what those are: source line numbers
(`TrackDispatcher:127,166`, which this file's own pattern reads as one number rather than as two
line numbers), hex colours in badge URLs, MIDI note bytes, Swift test counts. None is a claim about
Logic's data, and flagging them would train a reader to skip the output.

`docs/canon/README.md` is the scope because it is the only prose here whose numbers describe the
canonical corpus. Observation records are covered separately and more strictly:
`check-observation-records.py` already requires a number in a conclusion to appear in a reading.

WHY THIS IS NOT A RULE INSIDE check-canon-citations.py
------------------------------------------------------
It reads the whole observations directory, so it answers differently in a tree with fewer records.
Put inside that guard it failed seven unrelated cases whose fixture seeds two records -- a check
that fails for reasons that have nothing to do with the case under test is a check nobody can read.

Exit: 0 = every number is backed or declared · 1 = one is neither
"""
import glob
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
#: A seam, so the self-test can drive main() -- the ENTRY POINT -- at a tree that must fail.
#: Without one every case could only reach `problems()`, and a `main()` returning 0
#: unconditionally stayed green; Scripts/mutation-sweep-guard-tests.py measured that on
#: 2026-09-18.
#:
#: It is a ROOT rather than a README path, because `problems()` derives the README, the artifacts
#: and the records from one root -- pointing only the README elsewhere would check a fixture
#: against the real repository's numbers, which is a different question.
def _root() -> str:
    return os.environ.get("LPM_CANON_REPO") or REPO


README = os.path.join(REPO, "docs", "canon", "README.md")
WAIVER = os.path.join(REPO, "docs", "canon", "PROSE-NUMBERS.json")

#: `1,234` or `1234`. Three digits and below are counts a sentence carries on its own -- "three
#: fields", "ten locales" -- and each of those in the README already sits beside its artifact.
A_BIG_NUMBER = re.compile(r"\b\d{1,3}(?:,\d{3})+\b|\b\d{4,}\b")


def numbers_in(text: str) -> set:
    return {match.group(0).replace(",", "") for match in A_BIG_NUMBER.finditer(text)}


def _read(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return ""


def backed_numbers(repo: str = None) -> set:
    """Every number a generated artifact or a measured record carries."""
    root = repo or REPO
    text = _read(os.path.join(root, "docs", "canon", "SOURCES.json"))
    text += _read(os.path.join(root, "docs", "canon", "MANIFEST.json"))
    for path in sorted(glob.glob(os.path.join(root, "docs", "observations", "*.json"))):
        text += _read(path)
    return numbers_in(text)


def declared_numbers(repo: str = None) -> set:
    path = os.path.join(repo or REPO, "docs", "canon", "PROSE-NUMBERS.json")
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return {str(key).replace(",", "") for key in (json.load(handle).get("numbers") or {})}
    except (OSError, json.JSONDecodeError):
        return set()


def problems(repo: str = None) -> list:
    root = repo or REPO
    readme = os.path.join(root, "docs", "canon", "README.md")
    if not os.path.exists(readme):
        return ["docs/canon/README.md is missing, so this has nothing to check and the document "
                "that states the rules is gone."]
    backed = backed_numbers(root)
    if not backed:
        return ["no number was found in any artifact or record, so this check would accept "
                "anything. Either the artifacts are missing or its reader is broken."]
    found = []
    for number in sorted(numbers_in(_read(readme)) - backed - declared_numbers(root)):
        found.append(
            f"docs/canon/README.md states {number} and neither a generated artifact nor an "
            f"observation record carries it. Cite it, or declare it in "
            f"docs/canon/PROSE-NUMBERS.json with the commit that measured it.")
    return found


def main() -> int:
    root = _root()
    found = problems(root)
    if found:
        print(f"{len(found)} number(s) in docs/canon/README.md come from nowhere:", file=sys.stderr)
        for line in found:
            print(f"  {line}", file=sys.stderr)
        return 1
    readme_numbers = numbers_in(_read(os.path.join(root, "docs", "canon", "README.md")))
    print(f"every number in docs/canon/README.md comes from an artifact, a record, or "
          f"{os.path.relpath(WAIVER, REPO)} ({len(readme_numbers)} checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
