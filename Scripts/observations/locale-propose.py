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

def _read_census(path):
    """A census document from `path`: JSON Lines (current) or the older pretty-printed JSON."""
    spec = importlib.util.spec_from_file_location(
        "census_evidence_for_tool", os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                                 "census_evidence.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.load(path)


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


def _records():
    """`locale_campaign_records`, loaded once: the routing a census was filed with decides its citations."""
    if "records" not in _RECORDS:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "locale_campaign_records.py")
        spec = importlib.util.spec_from_file_location("locale_campaign_records_for_propose", path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        _RECORDS["records"] = module
    return _RECORDS["records"]


_RECORDS = {}


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
# The surface taxonomy, so a scope naming an unknown surface is refused here the same way the guard
# refuses it — one list, read from SURFACES.md, never a second copy.
_SURFACES = _GUARD._records_module().known_surfaces()
_CONTAINMENT = set(_GUARD.swift_containment())
_EXACT_STRICT = set(_GUARD.swift_exact_strict())
_PREFIX = set(_GUARD.swift_prefix())


def label_mode(name, entry):
    """The mode to read this label with: the Swift where it can speak, else what the LEDGER says.

    `match_mode` falls back to a guess from the label's NAME, and `apply` used to write that guess
    over whatever the document declared. Four labels disagree today — `automationModeContext`,
    `headerPanHint`, `markerContainerKeywords` and `transportSliderHints` all declare `exact` while
    the name fallback says `contains` — so a campaign run silently loosened them and then matched
    under the looser rule it had just installed. Round four of review reproduced it end to end:
    `automationModeContext` accepted `automation extended`, rewrote `exact` to `contains`, recorded
    measured coverage, and passed the guard, because the guard checks the mode the document now
    declared.

    An author's declaration outranks a guess. The Swift outranks both, because it is what the
    product actually does.
    """
    swift = swift_mode(name)
    if swift is not None:
        return swift
    declared = (entry or {}).get("match")
    if declared in _GUARD.MATCH_MODES:
        return declared
    # NO MODE. The guard refuses a label that declares none — "whether Logic's string EQUALS this
    # label or CONTAINS it decides what counts as having seen it" — so a proposal made under a guess
    # is a proposal under a rule nothing has agreed to. Worse, `apply` used to WRITE that guess, so
    # a run turned a guard-red ledger green by installing the very rule that legitimised its own
    # match: round five drove `automationModeContext` with no declaration, matched
    # `automation extended` by the name guess, wrote `contains`, recorded coverage, and the guard
    # then agreed. `main()` reports these; nothing is proposed for them.
    return None


def swift_mode(name):
    """The mode the product reads this set with, or None where the Swift cannot say."""
    if name in _CONTAINMENT:
        return "contains"
    if name in _PREFIX:
        return "prefix"
    if name in _EXACT_STRICT:
        return "exact_strict"
    return None


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


def in_scope(entry, row):
    """Whether this census row is somewhere this label's evidence may come from.

    Asked BEFORE the string is compared, because the whole failure this closes is a row that
    matches on every other axis. `markerListDeleteMenuItem` means the Delete in Logic's Marker List
    window; the ja-JP menus census carries `削除` as the Edit menu's Delete, with the same role and
    the same string, and a claim retracted for exactly that reason came back verbatim the next time
    this tool ran — with the ratchet reporting it as an improvement.

    Read from the guard, so the tool that proposes and the tool that judges cannot disagree about
    what a scope means.
    """
    scope = entry.get("evidence_scope")
    if scope is None:
        return True
    # FAIL CLOSED on a malformed scope. This used to read the fields straight out of the object, so
    # `evidence_scope: "AXWindow["` and `path_contains: 5` were silently ignored — a scope written
    # wrongly permitted everything — and `surfaces: 5` crashed the tool outright. Found by review
    # 2026-09-07. The guard reports the malformation; this side simply proposes nothing for a label
    # whose scope it cannot read, which is the safe direction for a tool that writes citations.
    if _GUARD.scope_problems("", entry, _SURFACES):
        return False
    scope = _GUARD.evidence_scope(entry)
    return _GUARD._row_in_scope(row, _GUARD._path_fragments(scope.get("path_contains")),
                                scope.get("surfaces"))


def roles_for(name):
    for frag, roles in ROLE_HINTS:
        if frag in name:
            return roles
    return None   # unknown shape — see `apply`, which refuses to write for these


def derive_roles(entry, rows):
    """`(roles, basis)` the census rows say this label's element has, or None when they say nothing.

    For a label whose NAME gives no role (`roles_for` is None) a person used to type `roles`, and that
    is a guess. The census holds the answer: the AX role of every element whose WHOLE text equals one
    of the label's strings (up to case and surrounding space). A substring hit is not evidence of which
    element the label addresses -- `play` is a substring of a hundred rows -- so only equality counts.

    The main window outranks the menus. A string that is the whole text of a window element is that
    element; the same word on a menu item is the shared-string collision this tool exists to refuse
    (`Mixer` is a View-menu row and a Control Bar button). Menu rows decide only when no window element
    carries the string whole, and `basis` says which it was so a person can see how it was decided.
    """
    wanted = {w.casefold().strip() for w in [entry.get("canonical")] + list(entry.get("variants") or []) if w}
    window, menus = set(), set()
    for row in rows:
        if not in_scope(entry, row):
            continue
        if any(text.casefold().strip() in wanted for _attr, text in strings_of(row)):
            (menus if row["surface"] == "arrange.menus" else window).add(row["role"])
    if window:
        return sorted(window), "window"
    if menus:
        return sorted(menus), "menus"
    return None


def declare_roles(labels_path, census, locale, sighted=None):
    """Declare `roles` for every label that has none and whose name cannot say, from this census.

    Returns `(declared, undeclared)`: `{label: {"roles", "basis", "census_locale"}}` written to the
    ledger, and `{label: reason}` for labels no element carries whole. Nothing is overwritten: a label
    that already declares roles keeps them, because a declaration can only ever be WIDENED by a later
    reading that a person reviews.
    """
    doc = json.load(open(labels_path, encoding="utf-8"))
    declared, undeclared = {}, {}
    rows = census["census"]
    for name, entry in sorted(doc["labels"].items()):
        if entry.get("roles") or roles_for(name) is not None or label_mode(name, entry) is None:
            continue
        if sighted is not None and name not in sighted:
            continue
        found = derive_roles(entry, rows)
        if found is None:
            undeclared[name] = ("no element in this census carries any of its strings as its whole text; "
                                "a substring hit does not say which element the label addresses")
            continue
        entry["roles"] = found[0]
        declared[name] = {"roles": found[0], "basis": found[1], "census_locale": locale}
    if declared:
        open(labels_path, "w", encoding="utf-8").write(_GUARD._module().render(doc))
    return declared, undeclared


def narrow_roles(labels_path, census, locale):
    """Narrow a CONTAINMENT label's roles to the elements whose whole text is the label, when that disagrees.

    `apply` used to widen a label's `roles` with the role of whatever element a census happened to hit,
    and a containment label hits menu items: `sliderPanHint` (the pan slider's label) carried
    `AXMenuItem` because the ja-JP Edit menu has `同じパンナータイプの…` and the Record menu has
    `クイックパンチインを許可`, both containing `パン`. A role that only a substring ever reached is not
    the element the label addresses; the elements that carry the string WHOLE are.

    Narrowing happens only when a MAIN-WINDOW element carries one of the label's strings whole, only for a
    `contains` label, and never to an empty set. The readings that rested on a dropped role are removed
    (their provenance blocks and any coverage citation), so the next apply writes them again from the
    right element instead of leaving a claim about the wrong one. Returns `{label: {...}}` of what moved.
    """
    doc = json.load(open(labels_path, encoding="utf-8"))
    moved = {}
    # `census` is one census or a list of them. A role is kept if ANY locale's main window carries a
    # string of the label whole under it: a translation can make a word a menu title in one language and
    # a button in another, and a role dropped on one locale's census would silently delete the readings
    # another locale's run had made on it -- so what one run narrows depended on which run came first.
    censuses = census if isinstance(census, list) else [census]
    for name, entry in sorted(doc["labels"].items()):
        roles = entry.get("roles") or []
        if len(roles) < 2 or label_mode(name, entry) != "contains":
            continue
        window_roles = set()
        for one in censuses:
            found = derive_roles(entry, one["census"])
            if found and found[1] == "window":
                window_roles |= set(found[0])
        if not window_roles:
            continue
        found = (sorted(window_roles), "window")
        keep = [r for r in roles if r in found[0]]
        drop = [r for r in roles if r not in found[0]]
        if not keep or not drop:
            continue
        entry["roles"] = keep
        removed = []
        for variant, block in list((entry.get("provenance") or {}).items()):
            if block.get("role") in drop:
                removed.append(f"{block.get('locale')}:{variant}")
                del entry["provenance"][variant]
        if not entry.get("provenance"):
            entry.pop("provenance", None)
        for loc, role in list((entry.get("coverage_roles") or {}).items()):
            if role in drop:
                removed.append(f"{loc}:coverage")
                entry["coverage"][loc] = "unmeasured"
                for key in ("coverage_records", "coverage_roles", "coverage_attributes", "coverage_paths",
                            "coverage_identifiers", "coverage_logic_version", "coverage_logic_build",
                            "coverage_record_sha256", "coverage_currency", "coverage_absent"):
                    (entry.get(key) or {}).pop(loc, None)
        moved[name] = {"was": roles, "now": keep, "dropped": drop, "readings_removed": sorted(removed),
                       "census_locale": locale}
    if moved:
        open(labels_path, "w", encoding="utf-8").write(_GUARD._module().render(doc))
    return moved


def matches(name, wanted, text, entry=None):
    # A label with no agreed mode matches nothing — see `label_mode`.
    """Whether this string counts as seen — under the SAME mode the block will declare.

    These were two rules: the hit was decided from the label's name and the `match` field was
    written from the Swift. For the 23 sets where they disagree the tool found nothing at all
    (matching exactly) while claiming it would have matched by containment, so the campaign
    silently under-delivered instead of failing. One rule, asked once.

    The comparison itself is the guard's, not a copy of it: `carries` folds case exactly as the
    product does, and this file used to hold a case-sensitive twin that could propose nothing for a
    label whose stored form differs from Logic's only in case.
    """
    mode = label_mode(name, entry)
    return mode is not None and _GUARD.carries(text, wanted, mode)


def strings_of(row):
    for attr in ("title", "description", "help", "value"):
        v = row.get(attr)
        if v:
            yield attr, v


def main(census_path, labels_path):
    census = _read_census(census_path)
    labels = json.load(open(labels_path, encoding="utf-8"))["labels"]
    host = census["host"]
    locale = host["locale"]
    rows = census["census"]
    proposals = {}
    unmatched_role = {}
    for name, entry in sorted(labels.items()):
        wanted = [entry["canonical"]] + list(entry.get("variants") or [])
        allowed = roles_for(name)
        # A label that DECLARES its roles is read only on those. The name-shape hint is silent for a
        # `...Hint` or `...Keyword`, which used to mean "any element", so a short word that is also a
        # prefix of an unrelated menu item matched it: ja-JP `パン` (pan) is the start of
        # `クイックパンチインを許可` (Allow Quick Punch-In), and the pan slider's label was read off that
        # Record-menu item instead of the slider. A declared role set is the author's statement of what
        # element the label addresses; ignoring it let a role the label never meant widen its evidence.
        if allowed is None and entry.get("roles"):
            allowed = set(entry["roles"])
        hits = []
        for row in rows:
            if not in_scope(entry, row):
                continue
            if allowed is not None and row["role"] not in allowed:
                # the string may appear here, but this element cannot be what the label addresses
                for _, text in strings_of(row):
                    if any(w and matches(name, w, text, entry) for w in wanted):
                        unmatched_role.setdefault(name, set()).add(row["role"])
                continue
            for attr, text in strings_of(row):
                for w in wanted:
                    if w and matches(name, w, text, entry):
                        # NOT truncated. `observed` is compared character for character against
                        # the value the record carried, so a clipped proposal is a claim the record
                        # cannot back — and clipping is exactly what produced the two overclaiming
                        # blocks the guard was tightened to refuse.
                        hits.append({"string": w, "attribute": attr, "observed": text,
                                     "role": row["role"], "path": row["path"][:100],
                                     # The surface the row was FILED under, not the probe's raw one:
                                     # the record that cites it is named by the former, and a main-window
                                     # row's raw surface (`arrange.window`) names no record at all, so
                                     # every window sighting was dropped before it could be cited.
                                     "surface": _records().classify(row, locale) or row["surface"],
                                     "match": label_mode(name, entry)})
        if hits:
            proposals[name] = hits
    return locale, host, proposals, unmatched_role


def apply(labels_path, census, proposals, records_by_surface):
    """Write provenance for every proposal into ui-labels.json, citing the census record for the
    surface the match sat on. A variant gets a `provenance` block; a canonical-only match gets
    `coverage_records[locale]` so `measured` can be derived. Nothing is written for a label whose
    surface has no record — a citation to nothing is the shape the guard refuses."""
    unbacked = {}
    mislocated = {}
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
        #
        # NEVER over an author's declaration. This wrote `match_mode(name)` — a guess from the
        # label's NAME — over whatever the document said, and four labels disagree today. Round
        # four reproduced the consequence: `automationModeContext` declares `exact`, the guess says
        # `contains`, and a run matched `automation extended`, rewrote the mode to `contains`,
        # recorded measured coverage, and then passed the guard, because by then the document
        # declared the looser rule it had just been given. The Swift still wins where it can speak,
        # because that is what the product does.
        swift = swift_mode(name)
        if swift is not None:
            entry["match"] = swift
        elif entry.get("match") not in _GUARD.MATCH_MODES:
            # No Swift, no declaration: there is nothing to write that is not a guess, and the hits
            # above are empty for exactly that reason.
            continue
        for h in hits:
            rid = records_by_surface.get(h["surface"])
            # RESOLVED, not merely named. Checking the id is truthy let a surface map pointing at a
            # record that does not exist write a block with an empty date and a dangling citation —
            # the guard then rejects the ledger AFTER it has been mutated, which is the wrong end of
            # the transaction.
            #
            # But resolution and DATE VALIDITY are two questions, and the first cut asked them as
            # one. Coverage needs a resolved record and carries no date at all, so a record without
            # one is perfectly good evidence for it and was being skipped; while a malformed but
            # non-empty date passed and wrote provenance the guard then refused. Both raised by
            # review, one round apart, and the second was introduced by the fix for the first.
            # A RECORD, not merely valid JSON. `_record` returns whatever the file parsed to, and a
            # list or a string is not None — so a malformed record file resolved, and then the two
            # branches below crashed on `.get`: provenance immediately in `record_date`, coverage
            # later inside the guard, after the ledger had already been written. Raised by review
            # 2026-09-06.
            if not rid or not isinstance(_GUARD._record(rid), dict):
                continue
            # The record's LOCALE, which the guard checks and this did not. Records are chosen by
            # FILENAME (`*-<locale>-*-census.json`) and nothing makes a record's name agree with its
            # `host.locale`, so a mis-named record produced a block claiming the census locale and
            # citing a reading taken in another — written, reported as success, and then refused by
            # the guard. Round five, 2026-09-07; same shape as the sighting check beside it.
            if ((_GUARD._record(rid).get("host") or {}).get("locale")) != locale:
                mislocated.setdefault(name, set()).add(rid)
                continue
            # And the record must actually CONTAIN the sighting. Records are found by SURFACE, so a
            # census whose `surface` field matches a record says nothing about whether THAT record
            # saw THIS row — the census supplied on the command line and the record cited for it are
            # two different files, matched on a label. The guard validates the record, so a
            # mismatch writes a block the guard then refuses, leaving the ledger invalid AFTER it
            # has been mutated. Raised by review 2026-09-06, which proved it by proposing from a
            # synthetic census and watching the block land and then be rejected.
            #
            # Asked with the guard's own `sighting_value`, so the two cannot disagree about what
            # counts as seen.
            # The value the GUARD will return, not the one this tool happened to match. `observed`
            # is held to being a QUOTE of what the cited record carried, and the guard re-derives it
            # by scanning that record and taking the FIRST row that matches. Under `contains` a
            # record ordered `취소` then `취소 하시겠습니까` gives the guard the short one while this
            # tool, iterating the census, may have found the long one — and the block is then
            # refused for an `observed` mismatch. Named by review 2026-09-06.
            # WITH the label's scope. Without it this validated the citation under a looser rule
            # than the guard applies, so `--apply` wrote a block and reported success for a claim
            # the guard then refused — leaving the ledger invalid AFTER it had been mutated, which
            # is the failure the surrounding comment already describes, reached a different way.
            # Round four, 2026-09-07: a window-row proposal paired with a record carrying the
            # string only on a menu-bar row.
            scope = _GUARD.evidence_scope(entry)
            fragments = _GUARD._path_fragments(scope.get("path_contains"))
            # `coverage_paths[locale]` too, when this hit will take the COVERAGE branch. It is a
            # constraint the document may already carry — legal to hold while a locale is
            # `unmeasured`, because the guard skips that state — and validating without it wrote a
            # `measured` the guard then refused. Round six, 2026-09-07: a dormant
            # `coverage_paths.ko-KR` of `AXWindow[Target]` against a record that saw the string
            # under `AXWindow[Other]`, applied clean and rejected afterwards.
            # The SAME predicate the branch below uses, not an approximation of it. A canonical may
            # also be listed as a variant — `LabelSet` stores both without objecting — and such a
            # hit takes the provenance branch while canonical equality said coverage, so the
            # coverage constraint was applied to a provenance write. Round seven, 2026-09-07.
            if (h["string"] not in (entry.get("variants") or [])
                    and h["string"] == entry.get("canonical")):
                fragments += _GUARD._path_fragments(
                    (entry.get("coverage_paths") or {}).get(locale))
            seen = _GUARD.sighting_value(_GUARD._record(rid), h["string"], h["role"],
                                         h["attribute"], h["match"], fragments,
                                         scope.get("surfaces"))
            if seen is None:
                unbacked.setdefault(name, set()).add((h["string"], rid))
                continue
            if h["string"] in (entry.get("variants") or []):
                # A provenance block must carry a REAL date matching its record's — the coverage
                # branch below has no date field and asks nothing of it.
                if not _GUARD._is_real_date(record_date(rid)):
                    continue
                prov = entry.setdefault("provenance", {})
                if h["string"] in prov:
                    continue
                prov[h["string"]] = {"locale": locale, "date": record_date(rid),
                                     "host": host_line, "record": rid,
                                     "observed": seen, "role": h["role"],
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
                if cov.get(locale) in ("unmeasured", "derived"):
                    # `derived` too: Apple's corpus holding the string is the REASON a cell was never
                    # asked, not a reason to ignore a reading of it. Only `unmeasured` was promoted, so
                    # a canonical the census SAW stayed `derived` on every locale and `plan_changes`
                    # reported it NEW run after run without anything ever being written.
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
    # The generator's renderer, not a second opinion about how this file is formatted. This call
    # site said `indent=2` while the tree was indented with one space, so every campaign left the
    # document in a shape `locale_labels.py --write` would immediately rewrite (#798).
    open(labels_path, "w", encoding="utf-8").write(_GUARD._module().render(doc))
    if skipped:
        print(f"  not written for {len(skipped)} label(s) whose role this tool cannot constrain "
              f"— declare `roles` for them first: {', '.join(sorted(skipped)[:6])}"
              + (" …" if len(skipped) > 6 else ""))
    if mislocated:
        print(f"  not written for {len(mislocated)} label(s) whose surface record was measured in "
              f"another locale than the census — records are chosen by FILENAME and nothing makes "
              f"that name agree with the record's `host.locale`: "
              + ", ".join(f"{k}→{sorted(v)[0]}" for k, v in sorted(mislocated.items())[:4])
              + (" …" if len(mislocated) > 4 else ""))
    if unbacked:
        n = sum(len(v) for v in unbacked.values())
        print(f"  not written for {n} sighting(s) whose cited record does not contain them — the "
              f"census and the record for that surface disagree, so the citation would be false: "
              + ", ".join(f"{k}→{sorted(v)[0][0]!r}" for k, v in sorted(unbacked.items())[:4])
              + (" …" if len(unbacked) > 4 else ""))
    return n_prov, n_cov


if __name__ == "__main__":
    locale, host, proposals, unmatched = main(sys.argv[1], sys.argv[2])
    if "--apply" in sys.argv:
        census = _read_census(sys.argv[1])
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
