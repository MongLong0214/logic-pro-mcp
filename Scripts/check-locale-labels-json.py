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

    The containment folds case for the reason `carries` does: `observed` quotes what Logic showed,
    and the product matches a label to it case-insensitively. Held case-sensitively, a label whose
    stored form differs only in case from Logic's — `trackContentExplicit` carries `tracks
    contents`, Logic shows `Tracks contents` — could not be documented at all: the quote has to be
    verbatim (checked below, RAW, against what the record carried), and a verbatim quote does not
    contain the variant. Two rules in this file demanded opposite things about the same string.
    """
    if not isinstance(block, dict):
        return False
    if not all(str(block.get(k) or "").strip() for k in DOCUMENTED_KEYS):
        return False
    if not _is_real_date(block.get("date", "")):
        return False
    return not variant or variant.casefold() in str(block.get("observed", "")).casefold()


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


MATCH_MODES = ("exact", "exact_strict", "prefix", "contains")


def swift_prefix(repo=REPO):
    """Delegates to Scripts/locale_labels.py, for the same reason the other two do."""
    return _module().swift_prefix(repo)


def swift_exact_strict(repo=REPO):
    """Delegates to Scripts/locale_labels.py, for the same reason `swift_containment` does."""
    return _module().swift_exact_strict(repo)


def swift_containment(repo=REPO):
    """Delegates to Scripts/locale_labels.py, which is where the derivation lives.

    Both this guard and the generator need to know which sets the product reads with `containsAny`,
    and a rule with two implementations is a rule that drifts — measured 2026-09-05, when the
    campaign proposer kept its own name-based version and was wrong for 23 of the 31 sets.
    """
    return _module().swift_containment(repo)


_containment = swift_containment()
# The sets the product reads with `.exactStrict`, which does NOT trim the observed text. Derived
# from the Swift for the same reason containment is: a mode written from a guess was wrong for 23
# of 31 sets, and a mode the ledger does not know about is one it cannot hold a claim to.
_exact_strict = swift_exact_strict()
# Three of them are read BOTH ways, at different call sites — `barSliderLabel`, `beatSliderLabel`
# and `transportPlayControl` are matched with `containsAny` in `AXValueExtractors` and with
# `.exactStrict` in `AXLogicProElements+Transport`. So "the mode is a property of the LABEL", which
# this file says twice, is false for them, and it was only visible once the ledger learned the
# second mode.
#
# They declare `contains`, the mode that accepts more. A sighting says a string was on an element;
# seeing it inside a longer value is a real sighting for the containment call site, and demanding
# the stricter form would refuse evidence that is valid for one of the two. What that does NOT do
# is evidence the strict site, and the summary says so rather than leaving it implied — an
# unstated limit is the thing this ledger exists to end.
_both_modes = sorted(_exact_strict & _containment)
_exact_strict = _exact_strict - _containment
# The fourth mode. `.prefix` anchors, so it is STRICTER than containment — a set read both ways
# would have the same ambiguity the three above do, and none is, so the subtraction is a guard
# against a future one rather than a live case.
_prefix = swift_prefix() - _containment
# Which labels the product still reads, for auditing `retired`. Same derivation site as the
# containment sets, because a rule with two implementations is a rule that drifts.
_live_label_uses = _module().swift_label_uses()


def provenance_problems(name, entry):
    """Every way a provenance block can be three strings and a fourth string.

    `_is_documented` catches a block that does not contain the string it claims to document. What
    it cannot catch is a block whose `record` was typed rather than measured — so the record is
    RESOLVED: it must exist, and the locale the block claims must be the locale that record was
    measured in. A provenance that names a Korean record for a Japanese string is not a reading.
    """
    label_mode, out = label_match(name, entry)
    if label_mode is None and entry.get("provenance"):
        return out          # without a declared mode there is no rule to check a sighting under
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
        # The LABEL's mode, not the block's. A block may still carry one — `label_match` reports it
        # when the two disagree — but the sighting is checked under the label's, so the two halves
        # of this guard can never test the same claim under different rules.
        mode = label_mode
        declared = entry.get("roles") or []
        if not declared:
            out.append(f"{name}: has provenance but declares no `roles` — without the set of AX "
                       f"roles this label may be read on, a sighting of a DIFFERENT element that "
                       f"happens to carry the same string backs it (an `Edit` menu-bar item and an "
                       f"`Edit` menu button are not the same label)")
        elif role not in declared:
            out.append(f"{name}: provenance for {variant!r} was read on a {role}, which is not one "
                       f"of this label's declared roles {declared}")
        if not role or attribute not in SIGHTING_ATTRS:
            out.append(f"{name}: provenance for {variant!r} must name the `role` and the `attribute` "
                       f"it was read from — a string with no element is not a sighting")
        elif (seen := sighting_value(rec, variant, role, attribute, mode)) is None:
            out.append(f"{name}: provenance for {variant!r} cites {block.get('record')!r}, which has "
                       f"no {role} whose {attribute} carried it — a record that never saw it on that "
                       f"element cannot be cited for it")
        elif str(block.get("observed", "")) != seen:
            # `observed` is a QUOTE of the string Logic carried, and the guard now holds it to
            # that, RAW. Stripping both sides was the gap between the rule this file claims and the
            # rule it applied: a padded quote passed while the record held no such value, and the
            # documentation said "character for character" throughout.
            # Checking only that it CONTAINED the variant let the rest of the field be written
            # freely: a real truncated reading was cited while `observed` claimed the untruncated
            # text nobody had read. Whatever the record holds is what may be quoted.
            out.append(f"{name}: provenance for {variant!r} quotes observed "
                       f"{str(block.get('observed'))!r}, but the {attribute} the cited record "
                       f"actually carried on that {role} was {seen!r}")
        if str(block.get("date")) != str(rec.get("date")):
            out.append(f"{name}: provenance for {variant!r} is dated {block.get('date')!r} but its "
                       f"record was measured {rec.get('date')!r}")
    return out


# The attributes that carry a LABEL — what Logic shows a person, and what a LabelSet matches.
LABEL_ATTRS = ("title", "description", "help", "value")
# `identifier` is an AX identifier: not localised, not a label, and searched only when a block names
# it. Folding it into the label search let a canonical be "seen" because some element's identifier
# happened to equal it, which is a sighting of a different kind of thing.
SIGHTING_ATTRS = LABEL_ATTRS + ("identifier",)

# Subtrees a record uses to state what it EXPECTED, predicted or is arguing against. These are
# element-shaped on purpose — a counterexample has to name a role and an attribute to be legible —
# and that shape let them be cited as sightings. A record saying "this is NOT what we see" backed a
# claim that we do see it. Anything under one of these keys is not searched.
HYPOTHESIS_KEYS = {"expected", "expectation", "counterexample", "counter_example", "hypothesis",
                   "hypothetical", "predicted", "prediction", "proposed", "before", "example",
                   "would_be", "if_broken", "negative_control"}


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
            for key, v in node.items():
                if str(key).lower() in HYPOTHESIS_KEYS:
                    continue          # a prediction is not a reading — see HYPOTHESIS_KEYS
                yield from walk(v)
        elif isinstance(node, list):
            for v in node:
                yield from walk(v)

    yield from walk(rec.get("observations") or [])
    for rel in rec.get("evidence") or []:
        # Evidence must live under the evidence directory. `../locale/ui-labels.json` would let a
        # record cite the very file whose claims it is meant to back.
        # realpath, not normpath: `normpath` is lexical, so a symlink UNDER evidence/ pointing
        # anywhere on disk passed a `startswith` test while resolving outside the directory.
        root = os.path.realpath(os.path.join(OBS, "evidence"))
        path = os.path.realpath(os.path.join(OBS, rel))
        if not path.startswith(root + os.sep):
            continue
        try:
            yield from walk(json.load(open(path, encoding="utf-8")))
        except (OSError, ValueError):
            continue


def sighting(rec, text, role=None, attribute=None, mode="exact"):
    """Whether the record contains an element of `role` whose `attribute` carried `text`.

    With no `attribute` named, only the LABEL-bearing ones are searched — never `identifier`, which
    is not a localised label and whose accidental equality with a canonical is not a sighting of it.

    This replaces a substring search over `json.dumps(observations)`, which matched KEY names and
    instrument vocabulary: the variant `input` was satisfied by the key `with_input`, and
    `eventListColumnL`'s canonical `L` by any capital L in any path in any reading. A sighting is a
    row, an attribute on that row, and the value that attribute carried — the same three things a
    caller needs to find the element again.
    """
    return sighting_value(rec, text, role, attribute, mode) is not None


def carries(value, text, mode):
    """Whether an attribute value counts as carrying `text`, under the product's `mode`.

    THREE modes, because the product has three shapes and a ledger with two certifies claims the
    product refuses. `.exact` trims the observed text before comparing; `.exactStrict` does NOT —
    its own comment says it "preserves the raw `desc == label` semantics" the structural locators
    were written with. Held as one `exact`, a record whose AXGroup description reads
    `" 再生ヘッドの位置 "` satisfied the ledger and failed the comparison the element is actually
    read with. Found by review, 2026-09-05.

    The LABEL side is trimmed in every mode, because `LabelSet.labels` trims each stored string
    before any comparison happens — so a padded label never reaches the product either.

    It existed twice — `sighting` stripped before an exact test and the absence branch did not — so
    a value of `" Create "` was a presence to one and an absence to the other, about the same row.

    CASE-INSENSITIVE, because the product is. Every mode of `AXLocalePolicy.LabelSet` folds case:
    `.exact`/`.exactStrict` compare with `caseInsensitiveCompare`, and `containsAny` searches with
    `.caseInsensitive`. This comparison was case-SENSITIVE, so the guard was STRICTER than the
    thing it audits and refused honest readings — measured 2026-09-05: Logic shows the arrange
    canvas as `Tracks contents`, `trackContentExplicit` carries `tracks contents` (the classifier
    lowercases before looking it up), the product matches, and this returned False. A guard that
    refuses what the product accepts does not report a gap in Logic; it reports a gap in itself,
    and the only way to satisfy it was to write a variant Logic does not show.

    The rule is the one `label_match` already states: the evidence rule must be the product's.

    What this still does NOT fold is internal whitespace. `AccessibilityChannel+Regions` collapses
    runs of whitespace before the lookup, so a Logic string with a double space would match there
    and not here. No measured label needs it, and widening on a hypothetical is how a comparison
    stops describing anything.
    """
    label = text.strip().casefold()
    if mode == "exact":
        return value.strip().casefold() == label
    if mode == "exact_strict":
        return value.casefold() == label
    if mode == "prefix":
        # ANCHORED, and the candidate is trimmed — `.prefix` takes the same trimming path `.exact`
        # does in `LabelSet.matches`; only `.exactStrict` returns before it.
        return value.strip().casefold().startswith(label)
    return label in value.casefold()



def sighting_value(rec, text, role=None, attribute=None, mode="exact"):
    """The value the matching attribute actually carried, or None.

    Returning the value rather than a bool is what lets a caller check that a provenance block's
    `observed` is a QUOTE. Before this, `observed` was checked only for containing the variant, so
    a real record could be cited while `observed` carried arbitrary extra text nobody ever read.
    """
    if not text:
        return None
    for row in _rows(rec):
        if role and row.get("role") != role:
            continue
        for attr in ([attribute] if attribute else LABEL_ATTRS):
            value = row.get(attr)
            if not isinstance(value, str):
                continue
            if carries(value, text, mode):
                return value
    return None


def label_match(name, entry):
    """The match mode for a LABEL, as declared — and the problems with declaring it that way.

    The mode is a property of the label, not of one variant's block: whether Logic's string EQUALS
    this label or merely CONTAINS it is the same question for every locale. It lived only on
    provenance blocks, so `coverage_problems` had nothing to read and derived its own answer from
    the Swift — and for the 9 labels the Swift cannot speak about, the two halves of this guard
    disagreed about the same label. `undoMenuItemPrefix` is the clearest: Logic shows
    "Undo <action>", the proposer matched by containment and was right, and coverage demanded
    equality and refused it.

    Returns (mode, problems). `mode` is None when it cannot be trusted.
    """
    out = []
    mode = entry.get("match")
    if mode not in MATCH_MODES:
        return None, [f"{name}: declares no `match` — one of {MATCH_MODES}. Whether Logic's string "
                      f"EQUALS this label or CONTAINS it decides what counts as having seen it, and "
                      f"it is a property of the label rather than of one variant"]
    if name in _containment and mode != "contains":
        out.append(f"{name}: declares match {mode!r}, but the product reads this set with "
                   f"`containsAny` — the evidence rule must be the product's")
    if name in _prefix and mode != "prefix":
        out.append(f"{name}: declares match {mode!r}, but the product reads this set with "
                   f"`.prefix`, which ANCHORS — the evidence rule must be the product's, and "
                   f"`contains` accepts a sighting mid-value that it refuses")
    if name in _exact_strict and mode != "exact_strict":
        out.append(f"{name}: declares match {mode!r}, but the product reads this set with "
                   f"`.exactStrict`, which does not trim the observed text — the evidence rule "
                   f"must be the product's, and `exact` accepts padded readings it refuses")
    for variant, block in (entry.get("provenance") or {}).items():
        if block.get("match") not in (None, mode):
            out.append(f"{name}: provenance for {variant!r} declares match "
                       f"{block.get('match')!r} while the label declares {mode!r} — one label, one "
                       f"rule, or the two halves of this guard test different things")
    return mode, out


def coverage_problems(name, entry, locales, values):
    """`coverage` must name every supported locale, use only the three values, and be backed.

    `measured` means a record in that locale observed the surface this label lives on and its
    observations contain one of the label's strings — a variant with provenance, or the canonical.
    `identifier` means a record in that locale observed the identifier the label is addressed by.
    Both resolve `coverage_records[locale]`; a claim without a record that saw it is refused, so a
    `measured` cannot be typed any more than a variant's provenance can.
    """
    mode, out = label_match(name, entry)
    cov = entry.get("coverage")
    if not isinstance(cov, dict):
        return out + [f"{name}: coverage is missing — every label declares what is known per locale"]
    if mode is None and any(v in ("measured", "identifier") for v in cov.values()):
        return out
    if set(cov) != set(locales):
        out.append(f"{name}: coverage names {sorted(cov)}, expected exactly {sorted(locales)}")
    present_in = {str((b or {}).get("locale")) for b in (entry.get("provenance") or {}).values()}
    cites = entry.get("coverage_records") or {}
    strings = [entry.get("canonical") or ""] + list(entry.get("variants") or [])
    for loc, state in cov.items():
        if state not in values:
            out.append(f"{name}: coverage[{loc}] is {state!r}, not one of {values}")
            continue
        if state == "retired":
            reason = str(((entry.get("retired") or {}).get("reason")) or "").strip()
            if not reason:
                out.append(f"{name}: coverage[{loc}] is 'retired' but the label names no "
                           f"`retired.reason` — a label excused from measurement says why")
            elif name in _live_label_uses:
                out.append(f"{name}: coverage[{loc}] is 'retired', but `AXLocalePolicy.{name}` is "
                           f"still read in Sources/. A label the product uses is not retired, and "
                           f"retiring it drops a real gap out of every ceiling without a raise")
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
        declared = entry.get("roles") or []
        if not role:
            out.append(f"{name}: coverage[{loc}] is {state!r} but names no role under "
                       f"coverage_roles[{loc}] — `Edit` on a menu bar is not `Edit` on a toolbar "
                       f"button, and without the role any record showing either backs both")
        elif not declared:
            out.append(f"{name}: coverage[{loc}] is {state!r} but the label declares no `roles`")
        elif role not in declared:
            out.append(f"{name}: coverage[{loc}] cites a {role}, which is not one of this label's "
                       f"declared roles {declared}")
        elif state == "measured" and (entry.get("coverage_absent") or {}).get(loc) is not None:
            # MEASURED ABSENCE. The ADR always said "this element is unlabelled" was a `measured`
            # whose record says so, but the guard required a sighting CARRYING one of the label's
            # strings — a predicate a record proving absence can never satisfy. So the document
            # promised a state that could not be expressed, and "we looked and Logic shows none of
            # these" collapsed back into "nobody has looked".
            #
            # Both halves are mechanical: the element must have been SEEN (a row of the declared
            # role is in the record) and it must have shown NONE of the strings (no row of that role
            # carries one). Absence claimed about an element nobody found is still refused.
            # The element, not just its ROLE. `true` accepted any row of the declared role
            # anywhere in the cited record, so a mixer reading stood in for a Cancel button nobody
            # had looked at — the record was real, the role matched, and the claim was unrelated to
            # both. `coverage_absent[locale]` is now a fragment of the AX path, which makes the
            # claim something a reader can go and check.
            where = (entry.get("coverage_absent") or {}).get(loc)
            if not isinstance(where, str) or not where.strip():
                out.append(f"{name}: coverage_absent[{loc}] must name the ELEMENT the absence is "
                           f"about — a fragment of its AX path. `true` let any row of this role "
                           f"stand for one nobody looked at")
                continue
            if "/" not in where and "[" not in where:
                # A bare substring is not a locator. `"AX"` selects every row of the role and the
                # claim collapses back to the one this rule replaced. Requiring the shape of a path
                # — a separator or a named segment, both of which the census writes — refuses that
                # without capping how many rows a genuine path may select, which is what would make
                # an honest claim about identical siblings inexpressible.
                out.append(f"{name}: coverage_absent[{loc}] is {where!r}, which is a substring "
                           f"rather than a path — it must contain `/` or `[`, or it identifies "
                           f"nothing and any row of this role satisfies it")
                continue
            seen = [r for r in _rows(rec)
                    if r.get("role") == role and where in str(r.get("path") or "")]
            # Compared the way `sighting` compares, or the two disagree about the same pair:
            # positive sightings strip before an exact test, so `" Create "` counted as a presence
            # there and as an absence here. One rule.
            carrying = [v for t in strings if t
                        for r in seen
                        for v in (r.get(a) for a in LABEL_ATTRS)
                        if isinstance(v, str) and carries(v, t, mode)]
            if not seen:
                out.append(f"{name}: coverage[{loc}] claims measured ABSENCE citing "
                           f"{cites.get(loc)!r}, which contains no {role} whose path carries "
                           f"{where!r} — absence is a reading of an element that was found, not of "
                           f"one nobody located")
            elif carrying:
                out.append(f"{name}: coverage[{loc}] claims measured ABSENCE, but its record shows "
                           f"a {role} carrying {carrying[0]!r} — that is a presence")
        elif state == "measured":
            # The ATTRIBUTE too, exactly as provenance requires. Without it a string found in ANY
            # attribute backed the claim, and some labels say in their own rationale which attribute
            # is authoritative — `pluginWindowViewSwitcher` records that AXDescription is the
            # readback and AXTitle is not, then accepted a title match as measurement.
            attr = (entry.get("coverage_attributes") or {}).get(loc)
            if attr not in LABEL_ATTRS:
                out.append(f"{name}: coverage[{loc}] is 'measured' but names no readable attribute "
                           f"under coverage_attributes[{loc}] — one of {LABEL_ATTRS}. Which "
                           f"attribute carried the string is part of the reading, not a detail")
            elif not any(sighting(rec, t, role, attr, mode)
                         for t in strings if t):
                out.append(f"{name}: coverage[{loc}] is 'measured' citing {cites.get(loc)!r}, which "
                           f"has no {role} whose {attr} carried any of this label's strings")
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
    if _both_modes:
        # Said every run, not written once in a comment. These are the labels whose evidence is
        # weaker than one of their call sites requires, and the number is the size of that gap.
        print(f"   {len(_both_modes)} label(s) the product reads BOTH by containment and with "
              f"`.exactStrict`, so their evidence is held to the looser of the two and does not "
              f"establish the strict site: {', '.join(_both_modes)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
