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
import unicodedata

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


# The removed chunk must be a whole word or two, not any substring. A ratio was the first attempt
# and it was wrong in both directions — raised by review 2026-09-05: it reported
# `createButton` -> `Create` against the unrelated menu command `Create Group`, which a reader
# could act on, and it suppressed the real short-tail shape `Show EQ` -> `EQ`.
#
# The shape this signal is for has a direction: the POLICY string is the longer one, because Logic
# dropped a word the policy still carries. `Create` against `Create Group` is the other way round
# and is not it.
AFFIX_MAX_WORDS = 2
# A space-less policy string cannot be split into words, so the chunk is measured in characters.
# `position` minus `on` leaves `positi`, six characters, which the budget already refuses — an
# earlier cut also demanded the RETAINED side be three characters or more, and that rejected a real
# Japanese shape: 「情報を表示」 -> 「情報」 drops three characters and keeps a valid two-character
# label. Raised by review 2026-09-06; character count is not a proxy for whether a label in a
# space-less language is a fragment, so it is asked only of the chunk, where it is a budget rather
# than a judgement about words.
AFFIX_MAX_CHARS = 4


def _dropped_chunk(policy, observed):
    """What `policy` has that `observed` does not, when one is an affix of the other. Else None.

    NFC on both sides, like `_carries` and for the same reason: the product compares with canonical
    equivalence, so a policy string in one normal form and a census string in the other are the
    same text. Without it this signal silently missed the cases it exists for.
    """
    # Trimmed as well as folded and normalised. `carries` trims the label in every mode and the
    # observed value in all but `exact_strict`, so a padded policy string was comparable there and
    # not here — the two disagreed about the same pair. Raised by review 2026-09-06: case and NFC
    # had been brought into line, trimming had not.
    p = unicodedata.normalize("NFC", policy.strip()).casefold()
    o = unicodedata.normalize("NFC", observed.strip()).casefold()
    if o == p or len(o) >= len(p):
        return None          # the policy must be the LONGER side — that is the dropped-word shape
    if p.startswith(o):
        return p[len(o):]
    if p.endswith(o):
        return p[:len(p) - len(o)]
    return None


def _chunk_is_a_dropped_word(policy, observed, chunk):
    """Whether what the policy has extra is a WORD, not a fragment of one."""
    if " " in policy.strip():
        # The boundary has to fall on a space, or the chunk is half a word: `position` minus `on`
        # leaves `positi`, which is not a word Logic dropped.
        if not (chunk.startswith(" ") or chunk.endswith(" ")):
            return False
        return 1 <= len(chunk.split()) <= AFFIX_MAX_WORDS
    # No spaces to split on — Japanese writes `ステップインプットキーボード` as one run. Budget the
    # chunk, and require what remains to be long enough to be a label rather than a fragment.
    return len(chunk.strip()) <= AFFIX_MAX_CHARS


def _carries(value, text, mode):
    """Whether an observed string counts as showing `text`, under the label's own mode.

    The same three shapes `check-locale-labels-json.py` uses, normalised the same way. Kept small
    rather than imported: this guard runs over every census and every label, and loading the other
    module for its comparison would make a reporting tool depend on a gating one.
    """
    label = unicodedata.normalize("NFC", text.strip()).casefold()
    subject = unicodedata.normalize("NFC", value).casefold()
    if mode == "contains":
        return label in subject
    if mode == "prefix":
        return subject.strip().startswith(label)
    if mode == "exact_strict":
        return subject == label
    return subject.strip() == label


def _affix_of(text, bag):
    """An observed string that is `text` minus a leading or trailing word, else None."""
    best = None
    for other in bag:
        chunk = _dropped_chunk(text, other)
        if chunk is None or not _chunk_is_a_dropped_word(text, other, chunk):
            continue
        if best is None or len(other) > len(best):
            best = other
    return best


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
            mode = entry.get("match") or "exact"
            if (entry.get("coverage") or {}).get(loc) in ("measured", "identifier", "retired"):
                # The ledger already knows this one was read in this locale. Two candidates were
                # dismissed by hand before this rule existed — `eventListColumnPosition` addresses
                # an Event List column header and `newTrackSheetDescription` a sheet, neither of
                # which the navigation-free census walks — and both would keep reappearing.
                continue
            bag = seen[loc]
            # ABSENT under the label's OWN mode. Testing equality regardless of it called a
            # containment label absent when Logic plainly shows it inside a longer string —
            # `nonInsertButtonText` carries `send` and the census has `send button`, which is a
            # MATCH for that label and was being reported as a gap. Measured 2026-09-05: the
            # affix signal below surfaced fifty such rows before this was fixed, and they were
            # all the guard misreading its own subject.
            if any(_carries(s, text, mode) for s in bag):
                continue
            key = f"{name}→{text}"
            absent.append(key)
            hit = difflib.get_close_matches(text, list(bag), n=1, cutoff=NEAR)
            if hit and hit[0].casefold() != text.casefold():
                near.append((key, hit[0], "near"))
                continue
            # AFFIX, a second signal the similarity score cannot see. `Show Mixer` against `Mixer`
            # scores 0.72 and never reached the list — measured 2026-09-05, and it was a real
            # defect found instead by a unit-test fixture failing on its neighbour. The shape is
            # specific and cheap to name: one string is the other plus a leading or trailing word.
            # Every Show/Hide verb Logic 12.3 dropped has it, and none of them scored high enough.
            # AFFIX applies only where the product compares by EQUALITY. For a containment label
            # an affix is a match, not a miss — which is why it is asked here and not above.
            if mode != "contains":
                affix = _affix_of(text, bag)
                if affix:
                    near.append((key, affix, "affix"))

    print(f"{len(absent)} variant(s) absent from a census in their own locale; "
          f"{len(near)} of them have a near miss")
    if "--list" in sys.argv:
        # The near-miss list is the useful half and the absent list is the honest one. A short
        # canonical cannot reach the near list at all — `difflib` scores `Ch` against `Chx` at 0.8,
        # under the cutoff — so a reader who wants everything has to be able to ask. Raised by
        # review, 2026-09-05.
        for key in absent:
            print(f"   absent  {key}")
    for key, hit, kind in near:
        print(f"   {kind.upper():5s} {key}   ~   {hit!r}")
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
