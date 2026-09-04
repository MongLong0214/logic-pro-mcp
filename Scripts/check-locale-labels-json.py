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
import datetime
import importlib.util
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Measured 2026-09-04. Two numbers, because one can be held level while both halves move: adding an
# undocumented variant and documenting a different one leaves `total - documented` unchanged.


def _module():
    spec = importlib.util.spec_from_file_location(
        "locale_labels", os.path.join(REPO, "Scripts", "locale_labels.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


DOCUMENTED_KEYS = ("locale", "date", "observed")
# A real calendar date, not a string shaped like one: `2099-99-99` satisfied the pattern.
def _is_real_date(text):
    try:
        datetime.date.fromisoformat(str(text).strip())
        return True
    except (ValueError, TypeError):
        return False


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
    if not _is_real_date(block.get("date", "")):
        return False
    return not variant or variant in str(block.get("observed", ""))


OBS = os.path.join(REPO, "docs", "observations")


def _record(record_id):
    """The observation record a provenance block names, or None."""
    if not record_id or "/" in str(record_id):
        return None
    path = os.path.join(OBS, f"{record_id}.json")
    try:
        return json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError):
        return None


# `LabelSet.matches` is exact for menus, buttons and titles; `containsAny` is how help keywords are
# read. The evidence rule follows the product: a keyword may be a substring of the help string it was
# read from, and a menu title may not be a substring of a different menu title.
CONTAINS_SHAPES = ("HelpKeyword", "Keyword", "Hint", "Suffix", "Prefix", "Context")


def _is_contains_shape(name):
    return any(frag in name for frag in CONTAINS_SHAPES)


def provenance_problems(name, entry):
    """Every way a provenance block can be three strings and a fourth string.

    `_is_documented` catches a block that does not contain the string it claims to document. What
    it cannot catch is a block whose `record` was typed rather than measured — so the record is
    RESOLVED: it must exist, and the locale the block claims must be the locale that record was
    measured in. A provenance that names a Korean record for a Japanese string is not a reading.
    """
    out = []
    for variant, block in (entry.get("provenance") or {}).items():
        if variant not in (entry.get("variants") or []):
            out.append(f"{name}: provenance for {variant!r}, which is not one of its variants")
            continue
        if not _is_documented(block, variant):
            out.append(f"{name}: provenance for {variant!r} lacks a real date, a locale, or an "
                       f"`observed` string containing the variant")
            continue
        rec = _record(block.get("record"))
        if rec is None:
            out.append(f"{name}: provenance for {variant!r} names record {block.get('record')!r}, "
                       f"which is not in docs/observations/")
            continue
        rec_locale = (rec.get("host") or {}).get("locale")
        if rec_locale != block.get("locale"):
            out.append(f"{name}: provenance for {variant!r} claims locale {block.get('locale')!r} "
                       f"but its record was measured in {rec_locale!r}")
            continue
        # The load-bearing check. Resolving the record and matching its locale is referential
        # integrity — a dangling id, a typo. It is not evidence: a fabricated variant could cite any
        # same-locale record and paste itself into `observed`. What makes this a READING is that the
        # record itself saw the string: it has to occur verbatim in the record's raw observations or
        # in a file the record lists as evidence. A record that never saw it cannot be cited for it.
        role = block.get("role")
        attribute = block.get("attribute")
        if not role or attribute not in SIGHTING_ATTRS:
            out.append(f"{name}: provenance for {variant!r} must name the `role` and the `attribute` "
                       f"it was read from — a string with no element is not a sighting")
        elif not sighting(rec, variant, role, attribute, exact=not _is_contains_shape(name)):
            out.append(f"{name}: provenance for {variant!r} cites {block.get('record')!r}, which has "
                       f"no {role} whose {attribute} carried it — a record that never saw it on that "
                       f"element cannot be cited for it")
        if str(block.get("date")) != str(rec.get("date")):
            out.append(f"{name}: provenance for {variant!r} is dated {block.get('date')!r} but its "
                       f"record was measured {rec.get('date')!r}")
    return out


SIGHTING_ATTRS = ("title", "description", "help", "value", "identifier")


def _rows(rec):
    """Every element-shaped reading in a record: its own observations, plus any evidence file.

    A "row" is an object carrying a `role` and at least one of the AX attributes. Records written by
    the census have thousands; a hand-written record has whatever its author put in `observations`.
    Anything that is not row-shaped is not a sighting and is not searched — which is the point.
    """
    def walk(node):
        if isinstance(node, dict):
            if node.get("role") and any(k in node for k in SIGHTING_ATTRS):
                yield node
            for v in node.values():
                yield from walk(v)
        elif isinstance(node, list):
            for v in node:
                yield from walk(v)

    yield from walk(rec.get("observations") or [])
    for rel in rec.get("evidence") or []:
        # Evidence must live under the evidence directory. `../locale/ui-labels.json` would let a
        # record cite the very file whose claims it is meant to back.
        path = os.path.normpath(os.path.join(OBS, rel))
        if not path.startswith(os.path.join(OBS, "evidence") + os.sep):
            continue
        try:
            yield from walk(json.load(open(path, encoding="utf-8")))
        except (OSError, ValueError):
            continue


def sighting(rec, text, role=None, attribute=None, exact=True):
    """Whether the record contains an element of `role` whose `attribute` carried `text`.

    This replaces a substring search over `json.dumps(observations)`, which matched KEY names and
    instrument vocabulary: the variant `input` was satisfied by the key `with_input`, and
    `eventListColumnL`'s canonical `L` by any capital L in any path in any reading. A sighting is a
    row, an attribute on that row, and the value that attribute carried — the same three things a
    caller needs to find the element again.
    """
    if not text:
        return False
    for row in _rows(rec):
        if role and row.get("role") != role:
            continue
        for attr in ([attribute] if attribute else SIGHTING_ATTRS):
            value = row.get(attr)
            if not isinstance(value, str):
                continue
            if (value.strip() == text.strip()) if exact else (text in value):
                return True
    return False


def coverage_problems(name, entry, locales, values):
    """`coverage` must name every supported locale, use only the three values, and be backed.

    `measured` means a record in that locale observed the surface this label lives on and its
    observations contain one of the label's strings — a variant with provenance, or the canonical.
    `identifier` means a record in that locale observed the identifier the label is addressed by.
    Both resolve `coverage_records[locale]`; a claim without a record that saw it is refused, so a
    `measured` cannot be typed any more than a variant's provenance can.
    """
    out = []
    cov = entry.get("coverage")
    if not isinstance(cov, dict):
        return [f"{name}: coverage is missing — every label declares what is known per locale"]
    if set(cov) != set(locales):
        out.append(f"{name}: coverage names {sorted(cov)}, expected exactly {sorted(locales)}")
    present_in = {str((b or {}).get("locale")) for b in (entry.get("provenance") or {}).values()}
    cites = entry.get("coverage_records") or {}
    strings = [entry.get("canonical") or ""] + list(entry.get("variants") or [])
    for loc, state in cov.items():
        if state not in values:
            out.append(f"{name}: coverage[{loc}] is {state!r}, not one of {values}")
            continue
        if state == "unmeasured":
            if loc in present_in:
                out.append(f"{name}: coverage[{loc}] is 'unmeasured' but a variant with provenance in "
                           f"{loc} exists — it is measured, and the projection derives that")
            continue
        if loc in present_in and state == "measured":
            continue          # derived from a variant's provenance, which was already checked
        rec = _record(cites.get(loc))
        if rec is None:
            out.append(f"{name}: coverage[{loc}] is {state!r} with no record under "
                       f"coverage_records[{loc}] — a claim of measurement needs the reading behind it")
            continue
        if (rec.get("host") or {}).get("locale") != loc:
            out.append(f"{name}: coverage_records[{loc}] names a record measured in "
                       f"{(rec.get('host') or {}).get('locale')!r}, not {loc}")
            continue
        role = (entry.get("coverage_roles") or {}).get(loc)
        if not role:
            out.append(f"{name}: coverage[{loc}] is {state!r} but names no role under "
                       f"coverage_roles[{loc}] — `Edit` on a menu bar is not `Edit` on a toolbar "
                       f"button, and without the role any record showing either backs both")
        elif state == "measured" and not any(
                sighting(rec, t, role, exact=not _is_contains_shape(name)) for t in strings if t):
            out.append(f"{name}: coverage[{loc}] is 'measured' citing {cites.get(loc)!r}, which has "
                       f"no {role} carrying any of this label's strings")
        elif state == "identifier":
            ident = (entry.get("coverage_identifiers") or {}).get(loc)
            if not ident:
                out.append(f"{name}: coverage[{loc}] is 'identifier' but names no AXIdentifier under "
                           f"coverage_identifiers[{loc}] — the claim is that an identifier was seen")
            elif not sighting(rec, ident, role, "identifier"):
                out.append(f"{name}: coverage[{loc}] is 'identifier' citing {cites.get(loc)!r}, "
                           f"which has no {role} whose identifier is {ident!r}")
    return out


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

    locales = tuple(on_disk.get("supported_locales") or ())
    values = tuple(on_disk.get("coverage_values") or ())
    problems = []
    if on_disk.get("schema") != 2:
        problems.append(f"schema is {on_disk.get('schema')!r}; this guard reads schema 2 — regenerate")
    if not locales or not values:
        problems.append("supported_locales / coverage_values missing — regenerate")
    for name, entry in sorted(on_disk["labels"].items()):
        problems += provenance_problems(name, entry)
        if locales and values:
            problems += coverage_problems(name, entry, locales, values)
    if problems:
        print("docs/locale/ui-labels.json carries claims its evidence does not support:")
        for line in problems[:20]:
            print(f"  {line}")
        if len(problems) > 20:
            print(f"  … and {len(problems) - 20} more")
        return 1

    documented = sum(len(e.get("provenance") or {}) for e in on_disk["labels"].values())
    total = sum(len(e.get("variants") or []) for e in on_disk["labels"].values())
    print(f"{len(on_disk['labels'])} labels agree with the Swift; {documented} of {total} variants "
          f"trace to a record; coverage declared for {len(locales)} locales "
          f"(ceilings: Scripts/check-observation-ratchets.py)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
