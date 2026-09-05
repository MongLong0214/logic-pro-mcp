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


def _swift_containment():
    """The label sets the PRODUCT reads with `containsAny`, from the guard that derives them.

    Not a second copy. `CONTAINS_SHAPES` is a guess from the label's NAME, and measured against the
    real call sites it was wrong for 23 of the 31 sets Swift actually reads with containment —
    every one of which this tool would have proposed as `exact` and the guard would have refused.
    The rule lives in check-locale-labels-json.py; both read that one.
    """
    guard = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         "check-locale-labels-json.py")
    spec = importlib.util.spec_from_file_location("locale_guard", guard)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return set(module.swift_containment())


_CONTAINMENT = _swift_containment()


def match_mode(name):
    """`contains` when the product reads this set with containment, else the name is the only hint.

    The Swift is authoritative and the name is a fallback for the sets it cannot speak about — a
    label passed to a helper has no `containsAny` at its call site to find.
    """
    if name in _CONTAINMENT:
        return "contains"
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
    """
    if match_mode(name) == "contains":
        return wanted in text
    return text.strip() == wanted.strip()


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
    date = datetime.date.today().isoformat()
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
            if not rid:
                continue
            if h["string"] in (entry.get("variants") or []):
                prov = entry.setdefault("provenance", {})
                if h["string"] in prov:
                    continue
                prov[h["string"]] = {"locale": locale, "date": date, "host": host_line, "record": rid,
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
