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


#: `all 23 corpora`, `TWENTY-FOUR corpora`. A COUNT OF CORPORA is the one quantity in this file
#: that describes the corpus set itself, and the rule above cannot see it: three digits and below
#: are invisible to `A_BIG_NUMBER`, and number WORDS are invisible to any digit pattern. Both holes
#: were live. README line 139 says so in its own words -- "Number WORDS are invisible to
#: `check-canon-prose-numbers.py`, which reads digits, which is how it rotted unnoticed" -- and
#: naming a gap in prose is not closing it. Measured 2026-09-20, line 159 said `Input Port:` is
#: "absent from all 23 corpora" while the manifest carries 24 and the string is absent from all
#: 24; the sentence was written when there were 23 and `nibstrings` (#895) made it 24.
#:
#: Plural only. "one corpus" is generic English in this file ("One corpus holds 47,115 values"),
#: and reading it as a count would fire on every such sentence.
A_CORPUS_COUNT = re.compile(r"\b(all\s+)?([A-Za-z]+(?:-[A-Za-z]+)?|\d{1,3})\s+corpora\b", re.I)

#: Enough to read what this document writes. A word outside it is not a number word, and the
#: phrase is left alone -- "the corpora", "those corpora".
_WORD_VALUE = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
               "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
               "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
               "nineteen": 19, "twenty": 20, "thirty": 30}


def _as_count(word: str):
    """`23`, `twenty-three`, `TWENTY-FOUR` -> an int. Anything else -> None."""
    if word.isdigit():
        return int(word)
    parts = word.lower().split("-")
    if len(parts) == 1:
        return _WORD_VALUE.get(parts[0])
    if len(parts) == 2 and parts[0] in ("twenty", "thirty") and parts[1] in _WORD_VALUE:
        tens, unit = _WORD_VALUE[parts[0]], _WORD_VALUE[parts[1]]
        return tens + unit if unit < 10 else None
    return None


def corpora_measured(repo: str = None) -> tuple:
    """(how many corpora the manifest pins, how many of them carry at least one index row).

    A corpus is a (source, locale) pair with an absence set. Derived from `MANIFEST.json` rather
    than named here, and restricted to the sources the manifest declares -- `absence/translated.en`
    is a map of which English values are translations, not a corpus of Logic's bytes, and counting
    it would put this rule one above the document it checks.
    """
    root = repo or REPO
    try:
        with open(os.path.join(root, "docs", "canon", "MANIFEST.json"), encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return (0, 0)
    sources = set(manifest.get("sources") or {})
    corpora = set()
    for name in manifest.get("artifacts") or {}:
        match = re.fullmatch(r"absence/([a-z]+)\.([^.]+)\.u32", name)
        if match and match.group(1) in sources:
            corpora.add((match.group(1), match.group(2)))
    with_rows = set()
    index = os.path.join(root, "docs", "canon", "index")
    for name in sorted(os.listdir(index)) if os.path.isdir(index) else []:
        if not name.endswith(".tsv") or name.endswith(".values.tsv"):
            continue
        source = name[: -len(".tsv")]
        try:
            with open(os.path.join(index, name), encoding="utf-8") as handle:
                header = handle.readline().rstrip("\n").split("\t")
                if "locale" not in header:
                    continue
                column = header.index("locale")
                for line in handle:
                    fields = line.rstrip("\n").split("\t")
                    if len(fields) > column and (source, fields[column]) in corpora:
                        with_rows.add((source, fields[column]))
        except OSError:
            continue
    return (len(corpora), len(with_rows))


def corpus_count_problems(repo: str = None) -> list:
    """Every `N corpora` in the README, against the manifest.

    Two quantities are legitimate and the document uses both: how many corpora exist, and how many
    carry an index row. `ALL N corpora` is the first of those by the meaning of the word, which is
    what makes line 159 a defect rather than a choice of denominator.
    """
    root = repo or REPO
    text = _read(os.path.join(root, "docs", "canon", "README.md"))
    phrases = [(match.group(1), match.group(2)) for match in A_CORPUS_COUNT.finditer(text)
               if _as_count(match.group(2)) is not None]
    if not phrases:
        return []
    total, with_rows = corpora_measured(root)
    if not total:
        return ["docs/canon/README.md counts corpora and MANIFEST.json names none, so the "
                "sentence is checked against nothing. That is an unreadable manifest, not a "
                "repository without corpora."]
    declared = declared_numbers(root)
    found = []
    for scope, word in phrases:
        count = _as_count(word)
        if str(count) in declared:
            # The same escape the rule above has, and a quoted sentence needs it: this file
            # QUOTES the counts it has retracted, and a retraction is not a claim.
            continue
        if scope and count != total:
            found.append(
                f"docs/canon/README.md says `all {word} corpora` and the manifest pins {total}. "
                f"`all` names every corpus, so the only number that can follow it is {total} "
                f"({with_rows} carry an index row, which is a different sentence).")
        elif not scope and count not in (total, with_rows):
            found.append(
                f"docs/canon/README.md says `{word} corpora` and the manifest pins {total}, of "
                f"which {with_rows} carry an index row. A count of corpora must be one of those.")
    return found


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
    found.extend(corpus_count_problems(root))
    return found


def main() -> int:
    root = _root()
    found = problems(root)
    if found:
        # "come from nowhere" was the whole message when the only rule was the digit one. A count
        # of corpora that disagrees with the manifest does not come from nowhere -- it came from a
        # tree with fewer corpora -- and a header that misdescribes its own finding is the kind of
        # output a reader learns to skim.
        print(f"{len(found)} statement(s) in docs/canon/README.md are not backed by an artifact "
              f"or a record:", file=sys.stderr)
        for line in found:
            print(f"  {line}", file=sys.stderr)
        return 1
    readme_text = _read(os.path.join(root, "docs", "canon", "README.md"))
    readme_numbers = numbers_in(readme_text)
    counts = [m.group(2) for m in A_CORPUS_COUNT.finditer(readme_text) if _as_count(m.group(2)) is not None]
    total, with_rows = corpora_measured(root)
    print(f"every number in docs/canon/README.md comes from an artifact, a record, or "
          f"{os.path.relpath(WAIVER, REPO)} ({len(readme_numbers)} checked), and "
          f"{len(counts)} count(s) of corpora agree with the manifest's {total} "
          f"({with_rows} carrying an index row)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
