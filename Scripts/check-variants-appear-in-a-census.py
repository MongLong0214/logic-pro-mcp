#!/usr/bin/env python3
"""Every label variant should be a string some census actually saw — and the near ones are the tell.

The ledger already separates a variant nobody has measured (`undocumented_variants`) from one that
has been (`coverage`). What it could not see until 2026-09-05 is a variant that is PRESENT and
WRONG: `playheadPositionGroupLabel` carried `再生ヘッド位置` since it was written, Logic shows
`再生ヘッドの位置`, the set is read with `.exactStrict`, and one missing character made the element
unfindable on every Japanese Logic. Nothing failed. It read as coverage.

WHAT THIS IS NOT
----------------
It is not "every variant must appear in a census". The censuses are navigation-free — menus are
walked without being opened and the main window to depth 8 — so a label that lives on a dialog, a
sheet, the Marker List or the Step Input Keyboard is legitimately absent, and failing on absence
would make this guard wrong far more often than right. A guard that is usually wrong gets deleted.

So absence is a RATCHET: the set may not grow. A new member is either a new unmeasured surface
(raise it, with a reason) or a string somebody typed.

The NEAR-MISSES are printed for a person to read and are not gated. Measured on the day this was
written, at 0.86 similarity: three of five were real defects, one was a spelling the policy carries
on purpose, and one was a census artefact — the Mixer had focus, so the Edit menu that was captured
was the Mixer's. That ratio is why this prints rather than fails.
"""
import difflib
import glob
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OBS = os.path.join(REPO, "docs", "observations")
LABELS = os.path.join(REPO, "docs", "locale", "ui-labels.json")
NEAR = 0.86          # measured; below this the list is noise, above it every hit was worth reading

HANGUL = re.compile(r"[가-힣]")
KANA_CJK = re.compile(r"[぀-ヿ一-鿿]")
# At least one ASCII LETTER, not merely ASCII characters: `…` and `1.1.1.1` are ASCII
# and say nothing about which language a label belongs to. Caught by this guard's own
# self-test, which asked what `…` pins to and got `en-US`.
ASCII_ONLY = re.compile(r"^(?=[^A-Za-z]*[A-Za-z])[\x20-\x7e…]+$")


def locale_of(text):
    """Which locale column a variant belongs to, by script. None when there is no signal.

    Crude on purpose. A Japanese label may carry Latin words and an English one may not — this
    asks only "does the string contain script that pins it", and skips what it cannot pin rather
    than guessing. A guess here would file a variant under a census that was never about it.
    """
    if HANGUL.search(text):
        return "ko-KR"
    if KANA_CJK.search(text):
        return "ja-JP"
    if ASCII_ONLY.match(text or ""):
        return "en-US"
    return None


def census_strings():
    """{locale: {every string that locale's censuses carried}}."""
    out = {}
    for path in sorted(glob.glob(os.path.join(OBS, "evidence", "*.census.json"))):
        try:
            doc = json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError):
            continue
        loc = (doc.get("host") or {}).get("locale")
        rows = doc.get("census")
        if not loc or not isinstance(rows, list):
            continue
        bag = out.setdefault(loc, set())
        for row in rows:
            # ROW-SHAPED, the way `check-locale-labels-json.py` defines a sighting: a `role` and at
            # least one label-bearing attribute. Without it any JSON object with a `host.locale` and
            # a list called `census` counted as evidence, so a file holding
            # `{"census": [{"description": "再生ヘッド位置"}]}` would make a genuinely absent variant
            # look present and silence a real near miss. Raised by review, 2026-09-05.
            if not isinstance(row, dict) or not row.get("role"):
                continue
            for attr in ("title", "description", "help", "value"):
                v = row.get(attr)
                if isinstance(v, str) and v.strip():
                    bag.add(v.strip())
    return out


def main():
    labels = json.load(open(LABELS, encoding="utf-8"))["labels"]
    seen = census_strings()
    # No STRINGS, not merely no locales. A census file whose `census` array is empty produces a
    # locale key with an empty set, so `if not seen` was satisfied by a dictionary that answered
    # nothing — the guard would have reported "0 absent, 0 near" and exited clean about a
    # vocabulary it never had. Its own self-test asked, and that is what it got.
    if not any(seen.values()):
        print("no census evidence to compare against — refusing to report a pass from an empty "
              "vocabulary")
        return 1

    absent, near = [], []
    for name, entry in sorted(labels.items()):
        for text in [entry.get("canonical") or ""] + list(entry.get("variants") or []):
            if not text:
                continue
            loc = locale_of(text)
            if loc is None or loc not in seen:
                continue
            if (entry.get("coverage") or {}).get(loc) in ("measured", "identifier", "retired"):
                # The ledger already knows this one was read in this locale. Two candidates were
                # dismissed by hand before this rule existed — `eventListColumnPosition` addresses
                # an Event List column header and `newTrackSheetDescription` a sheet, neither of
                # which the navigation-free census walks — and both would keep reappearing.
                continue
            bag = seen[loc]
            if any(text.casefold() == s.casefold() for s in bag):
                continue
            key = f"{name}→{text}"
            absent.append(key)
            hit = difflib.get_close_matches(text, list(bag), n=1, cutoff=NEAR)
            if hit and hit[0].casefold() != text.casefold():
                near.append((key, hit[0]))

    print(f"{len(absent)} variant(s) absent from a census in their own locale; "
          f"{len(near)} of them have a near miss")
    if "--list" in sys.argv:
        # The near-miss list is the useful half and the absent list is the honest one. A short
        # canonical cannot reach the near list at all — `difflib` scores `Ch` against `Chx` at 0.8,
        # under the cutoff — so a reader who wants everything has to be able to ask. Raised by
        # review, 2026-09-05.
        for key in absent:
            print(f"   absent  {key}")
    for key, hit in near:
        print(f"   NEAR  {key}   ~   {hit!r}")
    if near:
        print("   A near miss is a string somebody may have typed instead of read. Check each "
              "against the census before dismissing it; the census is navigation-free, so a "
              "surface it does not walk is a legitimate absence.")
        print(f"   Two limits, said rather than hidden. The neighbour is found over ALL of that "
              f"locale's strings with no role or path filter, so an unrelated label can be "
              f"reported — `moveMenuItem` -> 'Move' is offered 'Movie', which is a File-menu item "
              f"and nothing to do with it. And a canonical of two or three characters cannot reach "
              f"this list at all: difflib scores 'Ch' against 'Chx' at 0.8, under the {NEAR} "
              f"cutoff. `--list` prints every absence, including those.")
    # COUNTED, NOT GATED — for now, and the condition for changing that is written down rather
    # than left to whoever reads this next.
    #
    # Gating absence today would mean seeding a ratchet with a hundred entries nobody has read,
    # which is a ceiling that records a number instead of a decision. `evidence.py` set this
    # precedent deliberately for `visual_assertions_without_a_subject`: count for one release,
    # convert the call sites, then gate — and it says so in its own words, "turning the whole
    # live suite red in one step invites someone to delete the clause".
    #
    # Gate it when the near-miss list has been read through once and each entry is either fixed or
    # explained. Three of the first five were real defects, so that reading is worth doing before
    # the number is frozen.
    return 0


if __name__ == "__main__":
    sys.exit(main())
