#!/usr/bin/env python3
"""Propose provenance from a census, only where the role agrees. ADR-019 D4 step 5.

Input: a census JSON from locale-census (rows with surface/path/role/title/description/help/
value/identifier) and docs/locale/ui-labels.json. Output: for each label set, the census rows on
which one of its strings appears — restricted to rows whose AX role is compatible with what the
label set's NAME says it addresses. `editMenuBar` and `markerListEditMenuButton` both say "Edit";
only a menu-bar item may back the first and only a menu button the second.

Nothing here is written to the tree. It prints proposals; a person confirms them.
"""
import datetime
import glob
import importlib.util
import json
import os
import re
import sys

ROLE_HINTS = [
    # (name suffix / fragment, allowed AX roles)
    ("MenuBar",        {"AXMenuBarItem"}),
    ("MenuItem",       {"AXMenuItem"}),
    ("MenuButton",     {"AXMenuButton", "AXPopUpButton"}),
    ("Button",         {"AXButton", "AXCheckBox", "AXRadioButton", "AXMenuButton"}),
    ("HelpKeyword",    {"AXButton", "AXPopUpButton", "AXGroup", "AXLayoutItem", "AXSlider", "AXCheckBox"}),
    ("WindowTitle",    {"AXWindow", "AXDialog", "AXSheet"}),
    ("Title",          {"AXWindow", "AXDialog", "AXSheet", "AXStaticText"}),
    ("Column",         {"AXColumn", "AXStaticText", "AXButton"}),
    ("Keyword",        None),   # a keyword can appear on anything; role is not evidence for it
    ("Hint",           None),
]


# The product matches menus, buttons and titles EXACTLY (`LabelSet.matches`, mode .exact) and
# only help keywords by containment (`containsAny`). A proposer that matched everything by
# substring would back `automationModeOff` = "끔" with the menu item "사이클 끔", which is a
# different command — exactly the false provenance the guard was rebuilt to refuse.
CONTAINS_SHAPES = ("HelpKeyword", "Keyword", "Hint", "Suffix", "Prefix", "Context")


def _guard():
    """The guard module itself, loaded once.

    This tool proposes what that guard will later judge, so every rule they share is read from
    there rather than reimplemented here — measured 2026-09-05, twice: the containment sets (a
    name-based guess, wrong for 23 of 31) and the string comparison (case-sensitive here, folded in
    the product, so a proposal this tool could make was one the guard refused).
    """
    guard = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         "check-locale-labels-json.py")
    spec = importlib.util.spec_from_file_location("locale_guard", guard)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_GUARD = _guard()
_CONTAINMENT = set(_GUARD.swift_containment())
_EXACT_STRICT = set(_GUARD.swift_exact_strict())
_PREFIX = set(_GUARD.swift_prefix())


def match_mode(name):
    """The mode the product reads this set with, from the Swift; the name is the only fallback.

    The Swift is authoritative and the name is a fallback for the sets it cannot speak about — a
    label passed to a helper has no `containsAny` at its call site to find. `exact_strict` is a
    third answer, not a stricter `exact`: it does not trim the observed text, so a proposal made
    under `exact` can be one the guard refuses.
    """
    if name in _CONTAINMENT:
        return "contains"
    if name in _PREFIX:
        return "prefix"
    if name in _EXACT_STRICT:
        return "exact_strict"
    return "contains" if any(f in name for f in CONTAINS_SHAPES) else "exact"


def roles_for(name):
    for frag, roles in ROLE_HINTS:
        if frag in name:
            return roles
    return None   # unknown shape — see `apply`, which refuses to write for these


def matches(name, wanted, text):
    """Whether this string counts as seen — under the SAME mode the block will declare.

    These were two rules: the hit was decided from the label's name and the `match` field was
    written from the Swift. For the 23 sets where they disagree the tool found nothing at all
    (matching exactly) while claiming it would have matched by containment, so the campaign
    silently under-delivered instead of failing. One rule, asked once.

    The comparison itself is the guard's, not a copy of it: `carries` folds case exactly as the
    product does, and this file used to hold a case-sensitive twin that could propose nothing for a
    label whose stored form differs from Logic's only in case.
    """
    return _GUARD.carries(text, wanted, match_mode(name))


def strings_of(row):
    for attr in ("title", "description", "help", "value"):
        v = row.get(attr)
        if v:
            yield attr, v


def main(census_path, labels_path):
    census = json.load(open(census_path, encoding="utf-8"))
    labels = json.load(open(labels_path, encoding="utf-8"))["labels"]
    host = census["host"]
    locale = host["locale"]
    rows = census["census"]
    proposals = {}
    unmatched_role = {}
    for name, entry in sorted(labels.items()):
        wanted = [entry["canonical"]] + list(entry.get("variants") or [])
        allowed = roles_for(name)
        hits = []
        for row in rows:
            if allowed is not None and row["role"] not in allowed:
                # the string may appear here, but this element cannot be what the label addresses
                for _, text in strings_of(row):
                    if any(w and matches(name, w, text) for w in wanted):
                        unmatched_role.setdefault(name, set()).add(row["role"])
                continue
            for attr, text in strings_of(row):
                for w in wanted:
                    if w and matches(name, w, text):
                        # NOT truncated. `observed` is compared character for character against
                        # the value the record carried, so a clipped proposal is a claim the record
                        # cannot back — and clipping is exactly what produced the two overclaiming
                        # blocks the guard was tightened to refuse.
                        hits.append({"string": w, "attribute": attr, "observed": text,
                                     "role": row["role"], "path": row["path"][:100],
                                     "surface": row["surface"],
                                     "match": match_mode(name)})
        if hits:
            proposals[name] = hits
    return locale, host, proposals, unmatched_role


def apply(labels_path, census, proposals, records_by_surface):
    """Write provenance for every proposal into ui-labels.json, citing the census record for the
    surface the match sat on. A variant gets a `provenance` block; a canonical-only match gets
    `coverage_records[locale]` so `measured` can be derived. Nothing is written for a label whose
    surface has no record — a citation to nothing is the shape the guard refuses."""
    doc = json.load(open(labels_path, encoding="utf-8"))
    host = census["host"]; locale = host["locale"]
    host_line = f"{host['app']} {host['version']} ({host['build']}) on {host['os']}"
    # The RECORD's date, not today's. A provenance block says a string was observed, and the
    # observation happened when the census was taken — the guard enforces exactly that
    # ("provenance for X is dated D but its record was measured E"). Stamping `today` worked only
    # while a campaign was applied on the same day its census was written; the clock rolled past
    # midnight during one, and every block the proposer would write from then on was one the guard
    # refuses. Read per record, because a campaign can cite several.
    # Read through the GUARD's resolver, not a path this file works out for itself — the same
    # reason the containment sets and the string comparison come from there. Two ways of finding a
    # record are two ways of disagreeing about which one was cited.
    def record_date(record_id):
        rec = _GUARD._record(record_id)
        return (rec or {}).get("date") or ""
    n_prov = n_cov = 0
    skipped = []
    for name, hits in proposals.items():
        entry = doc["labels"].get(name)
        if not entry:
            continue
        # An unknown name shape means EVERY role was accepted for this label, so the match says
        # nothing about which element carries the string — and `apply` used to promote whatever the
        # census happened to hit into the label's `roles`. Measured on the first real campaign, that
        # produced 11 citations and the list is its own indictment: `barSliderLabel` backed by an
        # AXMenuItem, `trackRecordEnableCheckbox` by an AXMenuBarItem, the transport controls by menu
        # items. Logic's menus carry the same words, which is the shared-string collision this whole
        # design exists to refuse — walked into by the tool that fills the design in.
        #
        # So: propose, never write. A role this tool cannot constrain is a declaration a person
        # makes, and `main()` already reports these for review.
        if roles_for(name) is None and not entry.get("roles"):
            skipped.append(name)
            continue
        # The label declares the mode once. Coverage has no per-variant block to read one from, and
        # when it derived its own the two halves of the guard disagreed for every label the Swift
        # cannot speak about. This is the mode the hits above were actually found under.
        entry["match"] = match_mode(name)
        for h in hits:
            rid = records_by_surface.get(h["surface"])
            # RESOLVED, not merely named. Checking the id is truthy let a surface map pointing at a
            # record that does not exist write a block with an empty date and a dangling citation —
            # the guard then rejects the ledger AFTER it has been mutated, which is the wrong end of
            # the transaction. Raised by review 2026-09-06, and introduced by taking the date from
            # the record: before that the date was always well-formed and the id was the only thing
            # that could be wrong.
            if not rid or not record_date(rid):
                continue
            if h["string"] in (entry.get("variants") or []):
                prov = entry.setdefault("provenance", {})
                if h["string"] in prov:
                    continue
                prov[h["string"]] = {"locale": locale, "date": record_date(rid),
                                     "host": host_line, "record": rid,
                                     "observed": h["observed"], "role": h["role"],
                                     "attribute": h["attribute"], "match": h["match"]}
                # The label must DECLARE the roles it may be read on, and the citation must name one
                # of them. Seeded from the role actually observed — the first measurement is what
                # establishes the shape — and only ever widened, never silently replaced, so a later
                # census that finds the string on a different element is a proposal to review rather
                # than a fact that overwrites the constraint.
                declared = entry.setdefault("roles", [])
                if h["role"] not in declared:
                    declared.append(h["role"])
                    declared.sort()
                n_prov += 1
            elif h["string"] == entry.get("canonical"):
                cov = entry.setdefault("coverage", {})
                if cov.get(locale) == "unmeasured":
                    cov[locale] = "measured"
                    # The record AND the role. A record alone backs any element that shows the
                    # string, which is the shared-string hole: `editMenuBar` and
                    # `markerListEditMenuButton` both carry `Edit`. The role must also be one the
                    # label declares, so seed that here too.
                    entry.setdefault("coverage_records", {})[locale] = rid
                    entry.setdefault("coverage_roles", {})[locale] = h["role"]
                    # ...and the attribute. Coverage names the same three things provenance does;
                    # leaving this out produced a claim the guard refused on arrival, which is the
                    # failure the integration cases exist to catch before a campaign does.
                    entry.setdefault("coverage_attributes", {})[locale] = h["attribute"]
                    declared = entry.setdefault("roles", [])
                    if h["role"] not in declared:
                        declared.append(h["role"])
                        declared.sort()
                    n_cov += 1
    json.dump(doc, open(labels_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    open(labels_path, "a", encoding="utf-8").write("\n")
    if skipped:
        print(f"  not written for {len(skipped)} label(s) whose role this tool cannot constrain "
              f"— declare `roles` for them first: {', '.join(sorted(skipped)[:6])}"
              + (" …" if len(skipped) > 6 else ""))
    return n_prov, n_cov


if __name__ == "__main__":
    locale, host, proposals, unmatched = main(sys.argv[1], sys.argv[2])
    if "--apply" in sys.argv:
        census = json.load(open(sys.argv[1], encoding="utf-8"))
        obs = os.path.join(os.path.dirname(os.path.dirname(sys.argv[2])), "observations")
        by_surface = {}
        for p in sorted(glob.glob(os.path.join(obs, f"*-{locale}-*-census.json"))):
            d = json.load(open(p, encoding="utf-8")); by_surface[d["surface"]] = d["id"]
        n_prov, n_cov = apply(sys.argv[2], census, proposals, by_surface)
        print(f"applied: {n_prov} provenance block(s), {n_cov} coverage citation(s); regenerate with locale_labels.py --write and run the guards")
    labels = json.load(open(sys.argv[2], encoding="utf-8"))["labels"]
    n_label = len(proposals)
    n_strings = sum(len({h["string"] for h in hs}) for hs in proposals.values())
    print(f"census locale {locale}, host {host['version']} ({host['build']})")
    print(f"{n_label} of {len(labels)} label sets have at least one string on a navigation-free surface")
    print(f"{n_strings} distinct strings matched on a role-compatible element")
    print(f"{len(unmatched)} label sets matched ONLY on an incompatible role (not proposed)")
    if "--show" in sys.argv:
        i = sys.argv.index("--show")
        limit = int(sys.argv[i + 1]) if i + 1 < len(sys.argv) and sys.argv[i + 1].isdigit() else 10
        for name, hs in list(proposals.items())[:limit]:
            seen = {}
            for h in hs:
                seen.setdefault(h["string"], h)
            print(f"\n  {name}")
            for s_, h in seen.items():
                print(f"     {s_!r:28s} {h['role']:16s} {h['attribute']:11s} {h['path']}")
