#!/usr/bin/env python3
"""`docs/locale/ui-labels.json` must match the Swift, and measured provenance may only grow.

Two things, and the second is the one that changes behaviour over time.

**Agreement.** The JSON is a projection of `AXLocalePolicy.swift` for every reader that cannot
import Swift — the live harnesses, this repository's own guards, anything outside the build. A
projection nobody checks is just a fourth copy, and this repository already had three: the Swift,
the alias lists in `Scripts/livekit/evidence.py`, and inline literals in thirteen harnesses.
Regenerate with `Scripts/locale_labels.py --write`.

**The ratchet, in two numbers.** `AXLocalePolicy` says of its own variants list, in comment after
comment, that it "grows when a locale is actually observed, not when one is translated". That was
prose, and prose does not fail. `measured` makes it data.

The first shape of this rule tracked one number, `total - documented`, and an outside review
showed it could be held level while the situation got worse: add an undocumented variant AND
document a different one, and the difference is unchanged. So it tracks two — the total may not
rise and the documented count may not fall, and moving either is a reviewed edit. It also accepted
an EMPTY provenance object as documentation, because only the dictionary's length was read; a
block must now name the locale, the date and the string that was observed.

The floor is deliberately not zero. Turning 251 undocumented variants red in one step is how a
guard gets deleted rather than satisfied; `evidence.py` records the same reasoning for
`visual_assertions_without_a_subject`, counted for a release before it was gated. A ratchet that
only moves one way gets there without a flag day.
"""
import importlib.util
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Measured 2026-09-04. Two numbers, because one can be held level while both halves move: adding an
# undocumented variant and documenting a different one leaves `total - documented` unchanged.
TOTAL_VARIANT_CEILING = 257      # a variant may not appear without a reading behind it
DOCUMENTED_VARIANT_FLOOR = 2     # and a reading may not disappear


def _module():
    spec = importlib.util.spec_from_file_location(
        "locale_labels", os.path.join(REPO, "Scripts", "locale_labels.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


DOCUMENTED_KEYS = ("locale", "date", "observed")
_ISO_DATE = re.compile(r"^20\d\d-\d\d-\d\d$")


def _is_documented(block, variant=""):
    """A provenance block is a reading, not a placeholder.

    `{}` counted as documentation while only its length was read. Requiring three non-empty strings
    was the next shape, and an outside review showed `{"locale":"x","date":"x","observed":"x"}`
    satisfying it — a fabricated variant could be attached to junk and the totals would not move.

    So: the date has to be a date, and **`observed` has to contain the variant it documents**. That
    last one is the load-bearing part. A reading of a string you did not read cannot contain it,
    and it is the difference between provenance and three characters.

    What this still cannot check is whether the reading happened at all — someone determined to
    fake it can paste the variant into `observed`. The record it names is where a reviewer looks.
    """
    if not isinstance(block, dict):
        return False
    if not all(str(block.get(k) or "").strip() for k in DOCUMENTED_KEYS):
        return False
    if not _ISO_DATE.match(str(block.get("date", "")).strip()):
        return False
    return not variant or variant in str(block.get("observed", ""))


def counts(doc):
    total = sum(len(e.get("variants") or []) for e in (doc.get("labels") or {}).values())
    documented = sum(
        sum(1 for variant, block in (e.get("measured") or {}).items()
            if _is_documented(block, variant))
        for e in (doc.get("labels") or {}).values()
    )
    return total, documented


def main():
    labels = _module()
    on_disk = labels.load_json()
    if not on_disk.get("labels"):
        print("docs/locale/ui-labels.json is missing or unreadable — run Scripts/locale_labels.py --write")
        return 1

    expected = labels.build(existing=on_disk)["labels"]
    if on_disk["labels"] != expected:
        only_json = sorted(set(on_disk["labels"]) - set(expected))
        only_swift = sorted(set(expected) - set(on_disk["labels"]))
        changed = sorted(n for n in set(expected) & set(on_disk["labels"])
                         if on_disk["labels"][n] != expected[n])
        print("docs/locale/ui-labels.json disagrees with AXLocalePolicy.swift:")
        for name in only_swift[:8]:
            print(f"  in Swift, absent from the JSON:  {name}")
        for name in only_json[:8]:
            print(f"  in the JSON, absent from Swift:  {name}")
        for name in changed[:8]:
            print(f"  differs:                         {name}")
        print("\n  Regenerate: Scripts/locale_labels.py --write")
        return 1

    total, documented = counts(on_disk)
    if total > TOTAL_VARIANT_CEILING:
        print(f"{total} variants, above the ceiling of {TOTAL_VARIANT_CEILING}.")
        print("  A variant is a claim that Logic spells something that way. Record where it was")
        print("  read — locale, date, host, observation record, the string itself — under")
        print("  `measured`, then raise the ceiling and the floor together.")
        return 1
    if documented < DOCUMENTED_VARIANT_FLOOR:
        print(f"{documented} variants carry a reading, below the floor of "
              f"{DOCUMENTED_VARIANT_FLOOR} — a measurement was removed, or a `measured` block "
              "stopped naming its locale, date and observed string.")
        return 1
    if total < TOTAL_VARIANT_CEILING or documented > DOCUMENTED_VARIANT_FLOOR:
        print(f"{documented} of {total} variants documented, better than the recorded "
              f"{DOCUMENTED_VARIANT_FLOOR} of {TOTAL_VARIANT_CEILING} — move TOTAL_VARIANT_CEILING "
              f"to {total} and DOCUMENTED_VARIANT_FLOOR to {documented} so the next regression "
              "cannot fall back to the old numbers.")
        return 1

    print(f"{len(on_disk['labels'])} labels agree with the Swift; "
          f"{documented} of {total} variants carry a reading")
    return 0


if __name__ == "__main__":
    sys.exit(main())
