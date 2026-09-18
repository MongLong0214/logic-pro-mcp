#!/usr/bin/env python3
"""The live kit's locale aliases must not drift from `AXLocalePolicy`.

`evidence.py` carries `CONTROL_BAR_NAMES` and `TRACK_HEADER_NAMES` because the harnesses cannot
import Swift. That makes them a SECOND COPY of a label list, and a second copy goes stale the day
someone adds a locale to the first — silently, because a missing alias does not look like a bug: the
band lookup answers "no element with that exact AXDescription", the harness fails a precondition
about a window frame, and nothing in that message says the word it wanted was spelled for another
language.

Measured 2026-08-29, which is why this exists: three harnesses passed `"Control Bar"` to the band
tool on a Logic running in Korean. Each failed at a precondition unrelated to its own subject, so
none of them could produce evidence at all on this machine — and under the source-coverage rule a
harness that cannot run leaves its subject unproven however good its checks are.

A copy with a check is a copy that cannot go stale. This is that check.

WHAT IT DOES NOT DO: it does not require the two lists to be EQUAL. The policy is normalised and
matched leniently by the product; the live kit compares exactly, so it legitimately carries the
cased spellings Logic actually emits (`Tracks header`) beside the lower-cased policy variants.

BUT THE OTHER DIRECTION IS NOT NOTHING, and "one-directional and that is the direction that matters"
hid a real gap for as long as the sentence stood. Measured 2026-09-15: the region table carries five
spellings that appear in an observation record — so they were READ off a live Logic — and that
`AXLocalePolicy` does not carry at all:

    トラックヘッダ                    ja-JP, Tracks header
    Position der Abspielposition    de-DE, Playhead Position
    ライブラリ / Bibliothek           ja-JP / de-DE, Library
    ミキサー                          ja-JP, Mixer

A harness can find those regions and the PRODUCT cannot. That is the opposite failure from the one
this file was written for, and it is worse: the first makes a harness fail loudly at a precondition,
the second makes the product quietly not work in a language somebody has already measured.

So the reverse direction is counted too. It is a WARNING rather than a failure, because closing it
means adding variants to the policy — a change to what the product matches, which belongs in a
change that can be live-verified rather than in a guard run. The count is what stops it growing.
"""
import ast
import glob
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POLICY = os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
KIT = os.path.join(REPO, "Scripts", "livekit", "evidence.py")

# `(python name, swift LabelSet name)` for flat alias lists the harnesses use.
PAIRS = [
    ("EVENT_LIST_TAB_NAMES", "eventListTab"),
]

# And the region table, which is what `located_band` ACTUALLY reads. Checking a list no caller uses
# is a guard aimed at nothing: the first version of this file checked `CONTROL_BAR_NAMES` and
# `TRACK_HEADER_NAMES`, two lists written for this guard, while the locator went on translating
# through `AX_REGION_LABELS`. Both are gone; the table is the copy.
REGION_PAIRS = [
    ("Control Bar", "controlBarGroupLabel"),
    ("Tracks header", "trackHeadersDescription"),
    # Four rows had no pair and so were checked in NEITHER direction -- `Tracks`, `Library`, `Mixer`
    # and `Inspector`, eleven spellings between them. Their absence read as "the product never looks
    # for these", which is what the note below says about the tab lists, but it was never true of
    # `Tracks`: `arrangeWindowTitleSuffix` has carried it all along. Paired now.
    ("Tracks", "arrangeWindowTitleSuffix"),
    ("Library", "libraryPanelLabel"),
    ("Mixer", "mixerNamedElement"),
    ("Inspector", "mixerInspectorContext"),
    # Both of these are names harnesses actually pass to `located_band` and both had a policy
    # counterpart the guard was not reading, so the drift this file exists to catch went on
    # uncaught: `Tracks contents` had no Japanese form while the policy learned one, and
    # `Playhead Position` had no row in the table at all. A guard that covers two of the four
    # selectors in use reports "no drift" about the two it looks at.
    ("Tracks contents", "trackContentExplicit"),
    ("Playhead Position", "playheadPositionGroupLabel"),
]

# `MARKER_LIST_TAB_NAMES` and `OTHER_LIST_TAB_NAMES` have no policy counterpart and are not listed.
# The product never looks for those tabs — only a harness does, to point the pane elsewhere and to
# recognise a state it must restore — so there is no second copy to drift from. Said here because
# an absent row in a table like this reads as an oversight otherwise.


def swift_label_set(text, name):
    """`[canonical] + variants` for one `static let <name> = LabelSet(...)`, or None."""
    match = re.search(
        r"static let " + re.escape(name) + r"\s*=\s*LabelSet\((.*?)\)\s*\n",
        text, re.S)
    if not match:
        return None
    body = match.group(1)
    canonical = re.search(r'canonical:\s*"((?:[^"\\]|\\.)*)"', body)
    variants = re.search(r"variants:\s*\[(.*?)\]", body, re.S)
    if not canonical:
        return None
    out = [canonical.group(1)]
    if variants:
        out += re.findall(r'"((?:[^"\\]|\\.)*)"', variants.group(1))
    return out


def python_list(text, name):
    """The literal list assigned to `name` in `evidence.py`, or None."""
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return None
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        if name not in [t.id for t in node.targets if isinstance(t, ast.Name)]:
            continue
        try:
            value = ast.literal_eval(node.value)
        except (ValueError, SyntaxError):
            return None
        return list(value) if isinstance(value, (list, tuple)) else None
    return None


def missing(policy_labels, kit_labels):
    """Policy spellings the live kit could not reach — exactly for a script, case-folded for ASCII.

    Two attempts got this wrong before the reason became clear.

    Case-folding EVERYTHING accepts `"CONTROL BAR"` as covering the policy's `"control bar"` while
    Logic renders `"Control Bar"` and the band tool — which compares
    `str(c, kAXDescription) == candidate` — matches neither.

    Comparing EVERYTHING exactly fails on today's tree, and that failure is informative rather than
    a bug to route around: the policy's variants are NORMALISATION INPUTS, not strings Logic emits.
    `trackHeadersDescription` lists `track headers`, `track header`, `tracks header`,
    `tracks headers` — four lower-cased spellings for one rendered `Tracks header`.

    So the rule splits on what the difference means. An ASCII variant differs from what Logic
    renders only in case, and the product folds case, so case-insensitive membership is the honest
    test. A non-ASCII variant is a DIFFERENT SCRIPT — a whole language the product claims to know —
    and nothing folds `컨트롤 막대` into `Control Bar`. That one has to be present verbatim.

    What this still cannot do, and a live run can: prove Logic renders exactly the string the table
    holds. Measured 2026-08-29 for Korean; Japanese is declared and unproven.
    """
    exact = set(kit_labels)
    folded = {label.lower() for label in kit_labels}
    out = []
    for label in policy_labels:
        if label.isascii():
            if label.lower() not in folded:
                out.append(label)
        elif label not in exact:
            out.append(label)
    return out


def python_dict(text, name):
    """The literal dict assigned to `name` in `evidence.py`, or None."""
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return None
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        if name not in [t.id for t in node.targets if isinstance(t, ast.Name)]:
            continue
        try:
            value = ast.literal_eval(node.value)
        except (ValueError, SyntaxError):
            return None
        return value if isinstance(value, dict) else None
    return None



def derived_policy_spellings(repo_dir):
    """Every policy string that came from Apple's corpus rather than from a live reading.

    `docs/locale/ui-labels.json` records `provenance` per variant: which observation record read
    that string off a running Logic. A variant with none, in a LabelSet that names a
    `derivedFrom` row, arrived by derivation -- it is a fact about Apple's bytes and not about what
    AX publishes, so a harness that locates elements by AXDescription is not required to carry it.
    """
    path = os.path.join(repo_dir, "docs", "locale", "ui-labels.json")
    try:
        with open(path, encoding="utf-8") as handle:
            labels = json.load(handle).get("labels") or {}
    except (OSError, ValueError):
        return set()
    out = set()
    for entry in labels.values():
        provenance = entry.get("provenance") or {}
        for variant in entry.get("variants") or []:
            if variant not in provenance:
                out.add(variant)
    return out


def measured_strings(repo_dir):
    """Every string that appears anywhere in an observation record.

    Crude on purpose. The question this answers is not "was this string read as THIS label" — that
    is what `provenance` is for — but the much weaker "did anyone ever see this string on a live
    Logic". A live-kit spelling that passes this and is absent from the policy was measured and the
    product still cannot match it; one that FAILS it is a string in a matcher that nobody has ever
    read, which is the worse of the two and has no business in a harness at all.
    """
    blob = []
    for path in sorted(glob.glob(os.path.join(repo_dir, "docs", "observations", "*.json"))):
        if not re.match(r"^\d{4}-\d{2}-\d{2}-.*\.json$", os.path.basename(path)):
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                blob.append(handle.read())
        except OSError:
            continue
    return "\n".join(blob)


def main():
    try:
        policy_text = open(POLICY, encoding="utf-8").read()
        kit_text = open(KIT, encoding="utf-8").read()
    except OSError as exc:
        print(f"-> FAIL: cannot read a source ({exc})")
        return 1

    failed = 0

    derived_spellings = derived_policy_spellings(REPO)
    region_table = python_dict(kit_text, "AX_REGION_LABELS")
    if region_table is None:
        print("-> FAIL: evidence.AX_REGION_LABELS not found or not a literal dict")
        failed = 1
    else:
        for key, swift_name in REGION_PAIRS:
            policy_labels = swift_label_set(policy_text, swift_name)
            if policy_labels is None:
                print(f"-> FAIL: AXLocalePolicy.{swift_name} not found — renamed?")
                failed = 1
                continue
            reachable = [key] + list(region_table.get(key, []))
            gap = missing(policy_labels, reachable)
            # A DERIVED spelling is not required here, and requiring it would break this file's own
            # rule. `AX_REGION_LABELS` is a claim about what Logic publishes as an AXDescription,
            # read off a running Logic; a derived spelling is a claim about what Apple ships in
            # `.strings`, read off the bundle. They are different measurements, and a `.strings`
            # value is not evidence that AX emits it. "ONLY measured pairs belong here" is written
            # at the top of `evidence.py` for exactly this reason, so the forward direction now
            # demands the spellings somebody READ and reports the rest.
            unmeasured = [spelling for spelling in gap if spelling not in derived_spellings]
            derived_gap = [spelling for spelling in gap if spelling in derived_spellings]
            state = "ok" if not unmeasured else "FAIL"
            print(f"   {state:>4}  AX_REGION_LABELS[{key!r}]: reaches "
                  f"{len(policy_labels) - len(gap)} of {len(policy_labels)} policy spelling(s)"
                  + (f", {len(derived_gap)} of them derived and not required"
                     if derived_gap else ""))
            if unmeasured:
                print(f"-> FAIL: {swift_name} declares {unmeasured} which the region table cannot "
                      f"reach, and which a live reading -- not the corpus -- put in the policy")
                failed = 1

    # THE REVERSE DIRECTION. A kit spelling the policy does not carry means the harness can find a
    # region the product cannot. Reported, not failed — closing it edits what the product matches,
    # which needs a live run behind it. What IS a failure is a kit spelling nobody ever measured.
    if region_table is not None:
        corpus = measured_strings(REPO)
        unknown_to_policy, never_measured = [], []
        for key, swift_name in REGION_PAIRS:
            policy_labels = swift_label_set(policy_text, swift_name) or []
            folded = {str(v).casefold() for v in policy_labels}
            for spelling in region_table.get(key, []):
                if str(spelling).casefold() in folded:
                    continue
                (unknown_to_policy if spelling in corpus else never_measured).append(
                    f"{key}\u2192{spelling}")
        if never_measured:
            print(f"-> FAIL: {len(never_measured)} live-kit spelling(s) appear in no observation "
                  f"record, so a harness matches on a string nobody has read: {never_measured}")
            failed = 1
        if unknown_to_policy:
            # A WARNING until 2026-09-18, and the cost of that is measurable. `Position der
            # Abspielposition` was recorded in the de-DE arrange-transport census on 2026-09-12,
            # carried by this harness, and reported here as a warning that exits 0 -- so the
            # product could not find the Playhead Position group on a German Logic for six days
            # with the measurement sitting in the repository. `Schlag` and `トラックヘッダ` were
            # the same shape.
            #
            # A spelling somebody READ that the product cannot match is a language the product
            # does not work in. That is the thing this campaign exists to end, so it fails.
            print(f"-> FAIL: {len(unknown_to_policy)} measured spelling(s) the POLICY does not "
                  f"carry, so the product cannot match what a harness can find:")
            for entry in unknown_to_policy:
                print(f"           {entry}")
            print("  Add each to its LabelSet. A measurement that does not reach the policy is a "
                  "language nobody can use, and a warning is how one sat unused for six days.")
            failed = 1

    derived = derived_policy_spellings(REPO)
    for py_name, swift_name in PAIRS:
        policy_labels = swift_label_set(policy_text, swift_name)
        kit_labels = python_list(kit_text, py_name)
        if policy_labels is None:
            print(f"-> FAIL: AXLocalePolicy.{swift_name} not found — renamed?")
            failed = 1
            continue
        if kit_labels is None:
            print(f"-> FAIL: evidence.{py_name} not found or not a literal list")
            failed = 1
            continue
        gap = missing(policy_labels, kit_labels)
        # Same rule as the region table below: a DERIVED spelling is a fact about Apple's
        # `.strings`, and these lists are claims about what a live Logic publishes. Required if
        # somebody read it; reported if the corpus supplied it.
        unmeasured = [spelling for spelling in gap if spelling not in derived]
        derived_gap = [spelling for spelling in gap if spelling in derived]
        state = "ok" if not unmeasured else "FAIL"
        print(f"   {state:>4}  {py_name}: {len(kit_labels)} alias(es) cover "
              f"{len(policy_labels) - len(gap)} of {len(policy_labels)} policy spelling(s)"
              + (f", {len(derived_gap)} of them derived and not required" if derived_gap else ""))
        if unmeasured:
            print(f"-> FAIL: {swift_name} declares {unmeasured} which no live-kit alias matches")
            print(f"   Add them to evidence.{py_name}, or a harness cannot find that element on a")
            print("   Logic running in that language and will fail a precondition instead.")
            failed = 1
    return failed


if __name__ == "__main__":
    sys.exit(main())
