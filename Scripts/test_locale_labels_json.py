#!/usr/bin/env python3
"""Prove `Scripts/check-locale-labels-json.py` can fail — on a claim, not only on a mismatch.

The guard's older job was "the JSON equals the Swift". Its job now is "every claim the JSON makes
about a string is backed by a record that SAW that string". Each case plants one way that backing
can be missing, wrong, or merely well-formed, and requires the guard to name it. The load-bearing
cases are 4 and 11: a provenance block whose record exists, matches the locale, has a real date,
and contains the variant in `observed` — and whose record never observed the string. That is the
shape an outside review showed the earlier guard accepting, and it is three strings with a fourth
string pointing at an unrelated object.
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


guard = load("locale_labels_guard", "check-locale-labels-json.py")
labels = load("locale_labels", "locale_labels.py")

LOCALES = ("en-US", "ko-KR", "ja-JP")
VALUES = ("measured", "identifier", "unmeasured", "retired")
D = "2026-09-05"


def _ledger(records):
    """A temp observations dir. `records` is {id: (locale, [row dicts])} — rows are element-shaped
    readings, because a sighting is an element and an attribute, not a string in a blob."""
    d = Path(tempfile.mkdtemp())
    for rid, (locale, rows) in records.items():
        (d / f"{rid}.json").write_text(json.dumps({
            "id": rid, "date": D, "host": {"locale": locale},
            "observations": [{"what": "census", "rows": rows}]}, ensure_ascii=False), encoding="utf-8")
    return str(d)


def _row(role, **attrs):
    r = {"role": role, "title": None, "description": None, "help": None, "value": None,
         "identifier": None, "path": None}
    r.update(attrs)
    return r


def _entry(variants, provenance=None, coverage=None, cites=None, roles=None, idents=None,
           canonical="input slot", declared=("AXButton",), retired=None, attrs=None, absent=None,
           match="contains"):
    e = {"canonical": canonical, "variants": variants, "rationale": "r", "match": match}
    if declared:
        e["roles"] = list(declared)
    if retired:
        e["retired"] = retired
    if provenance is not None:
        e["provenance"] = provenance
    e["coverage"] = coverage if coverage is not None else {loc: "unmeasured" for loc in LOCALES}
    if cites:
        e["coverage_records"] = cites
    if roles:
        e["coverage_roles"] = roles
    if idents:
        e["coverage_identifiers"] = idents
    if attrs:
        e["coverage_attributes"] = attrs
    if absent:
        e["coverage_absent"] = absent
    return e


def _prov(record="2026-09-05-ko", locale="ko-KR", observed="입력 슬롯. 채널 스트립 입력 소스", date=D,
          role="AXButton", attribute="help", match="contains"):
    b = {"record": record, "locale": locale, "observed": observed, "date": date}
    if match:
        b["match"] = match
    if role:
        b["role"] = role
    if attribute:
        b["attribute"] = attribute
    return b


def main():
    failures = []

    ran = [0]

    def case(name, condition, detail):
        # Counted here rather than written into the closing line. The closing line used to carry a
        # literal, and it was wrong the first time a case was added without editing it — a self-test
        # whose own summary is unverified is the thing this file exists to argue against.
        ran[0] += 1
        if not condition:
            failures.append(f"{name}: {detail}")

    guard.OBS = _ledger({
        "2026-09-05-ko":       ("ko-KR", [_row("AXButton", help="입력 슬롯. 채널 스트립 입력 소스", description="입력 1"),
                                          _row("AXMenuBarItem", title="편집"),
                                          _row("AXMenuButton", title="편집", identifier="markerEdit:")]),
        "2026-09-05-ja":       ("ja-JP", [_row("AXButton", help="入力スロット")]),
        "2026-09-05-ko-blind": ("ko-KR", [_row("AXStaticText", value="something with_input and an L in it")]),
        "2026-09-05-en":       ("en-US", [_row("AXMenuItem", title="Export")]),
    })
    U = {loc: "unmeasured" for loc in LOCALES}
    ko_measured = dict(U, **{"ko-KR": "measured"})

    def pp(e): return guard.provenance_problems("inputSlotHelpKeyword", e)
    def cp(e, name="inputSlotHelpKeyword"): return guard.coverage_problems(name, e, LOCALES, VALUES)

    # 1. A fully backed entry: the record has an AXButton whose help carried the keyword.
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov()}, ko_measured,
               cites={"ko-KR": "2026-09-05-ko"}, roles={"ko-KR": "AXButton"})
    case("clean entry", pp(e) == [] and cp(e) == [], pp(e) + cp(e))

    # 2-4. Referential integrity: the record must exist, match the locale, and match the date.
    case("missing record", any("not in docs/observations" in x
         for x in pp(_entry(["입력 슬롯"], {"입력 슬롯": _prov(record="nope")}, ko_measured))), "")
    case("locale mismatch", any("measured in 'ja-JP'" in x
         for x in pp(_entry(["입력 슬롯"], {"입력 슬롯": _prov(record="2026-09-05-ja")}, ko_measured))), "")
    case("date mismatch", any("dated" in x
         for x in pp(_entry(["입력 슬롯"], {"입력 슬롯": _prov(date="2026-09-01")}, ko_measured))), "")

    # 5. THE BLOB ATTACK, in its two halves. The old rule searched json.dumps(observations), so a
    #    KEY name satisfied a variant and a letter inside a word satisfied a canonical. Keys are no
    #    longer searched at all, and an exact-matched label is not satisfied by a longer string.
    #
    #    What IS accepted, deliberately: a contains-matched label found inside a longer VALUE. The
    #    product reads those sets with `containsAny` and would match the same string, so refusing it
    #    here would make the guard stricter than the thing it documents.
    guard.OBS = _ledger({"2026-09-05-k": ("ko-KR", [_row("AXStaticText", with_input="x", value="unrelated")])})
    keyed = _entry(["input"], {"input": _prov(record="2026-09-05-k", observed="with_input",
                                              role="AXStaticText", attribute="value", match="contains")}, U,
                   declared=("AXStaticText",))
    case("a KEY is not a sighting",
         any("carried it" in x for x in guard.provenance_problems("nonInsertButtonText", keyed)),
         guard.provenance_problems("nonInsertButtonText", keyed))

    guard.OBS = _ledger({"2026-09-05-l": ("ko-KR", [_row("AXStaticText", value="an L in it")])})
    ell = _entry(["L"], {"L": _prov(record="2026-09-05-l", observed="an L in it",
                                    role="AXStaticText", attribute="value", match="exact")}, U,
                 declared=("AXStaticText",), match="exact")
    case("a letter inside a word is not an exact sighting",
         any("carried it" in x for x in guard.provenance_problems("eventListColumnL", ell)),
         guard.provenance_problems("eventListColumnL", ell))

    guard.OBS = _ledger({
        "2026-09-05-ko":       ("ko-KR", [_row("AXButton", help="입력 슬롯. 채널 스트립 입력 소스", description="입력 1"),
                                          _row("AXMenuBarItem", title="편집"),
                                          _row("AXMenuButton", title="편집", identifier="markerEdit:")]),
        "2026-09-05-ja":       ("ja-JP", [_row("AXButton", help="入力スロット")]),
        "2026-09-05-ko-blind": ("ko-KR", [_row("AXStaticText", value="something with_input and an L in it")]),
        "2026-09-05-en":       ("en-US", [_row("AXMenuItem", title="Export")]),
    })

    # 6. The MATCH MODE is data, not a guess from the label's name. An earlier cut inferred it from
    #    the name — `*Keyword` meant containment — and that was wrong in both directions against the
    #    real call sites. A block must declare it, and it must agree with how the product reads the
    #    set where the Swift can say.
    # The LABEL declares it, because coverage has no block to read one from and derived its own
    # when it was missing — so for the 9 sets the Swift cannot speak about, the two halves of this
    # guard checked the same claim under different rules.
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov()}, ko_measured, match=None)
    case("match mode is required on the label", any("declares no `match`" in x for x in pp(e)), pp(e))
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov(match="exact")}, ko_measured, match="contains")
    case("a block may not declare a mode the label contradicts",
         any("one label, one rule" in x for x in pp(e)), pp(e))

    # `cancelButton` IS read with containsAny at a call site, so the Swift can contradict the claim.
    # `inputSlotHelpKeyword` is passed to a helper and cannot be derived, which is why the block
    # declares the mode rather than the guard inferring it everywhere.
    guard.OBS = _ledger({"2026-09-05-c": ("ko-KR", [_row("AXButton", help="취소 하시겠습니까")])})
    cancel = _entry(["취소"], {"취소": _prov(record="2026-09-05-c", observed="취소 하시겠습니까",
                                            role="AXButton", attribute="help", match="exact")}, ko_measured,
                    declared=("AXButton",), match="exact")
    case("claiming exact for a containsAny set is refused",
         any("reads this set with `containsAny`" in x
             for x in guard.provenance_problems("cancelButton", cancel)),
         guard.provenance_problems("cancelButton", cancel))
    cancel["match"] = "contains"
    cancel["provenance"]["취소"]["match"] = "contains"
    case("...and declaring it correctly is accepted",
         guard.provenance_problems("cancelButton", cancel) == [],
         guard.provenance_problems("cancelButton", cancel))

    # ...and an exact-matched set really is checked exactly: a menu title that merely CONTAINS the
    # variant is a different command, which is the attack this mode exists to stop.
    guard.OBS = _ledger({"2026-09-05-m": ("ko-KR", [_row("AXMenuItem", title="사이클 끔")])})
    off = _entry(["끔"], {"끔": _prov(record="2026-09-05-m", observed="사이클 끔",
                                     role="AXMenuItem", attribute="title", match="exact")}, ko_measured,
                 declared=("AXMenuItem",), match="exact")
    case("a longer menu title does not satisfy an exact match",
         any("carried it" in x for x in guard.provenance_problems("automationModeOff", off)),
         guard.provenance_problems("automationModeOff", off))
    guard.OBS = _ledger({
        "2026-09-05-ko":       ("ko-KR", [_row("AXButton", help="입력 슬롯. 채널 스트립 입력 소스", description="입력 1"),
                                          _row("AXMenuBarItem", title="편집"),
                                          _row("AXMenuButton", title="편집", identifier="markerEdit:")]),
        "2026-09-05-ja":       ("ja-JP", [_row("AXButton", help="入力スロット")]),
        "2026-09-05-ko-blind": ("ko-KR", [_row("AXStaticText", value="something with_input and an L in it")]),
        "2026-09-05-en":       ("en-US", [_row("AXMenuItem", title="Export")]),
    })

    # 7. A provenance block with no role or attribute is not a sighting at all.
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov(role=None, attribute=None)}, ko_measured)
    case("role and attribute are required", any("is not a sighting" in x for x in pp(e)), pp(e))

    # 7. The right string on the WRONG role is refused.
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov(role="AXMenuItem")}, ko_measured,
               declared=("AXButton", "AXMenuItem"))
    case("wrong role refused", any("no AXMenuItem whose help carried it" in x for x in pp(e)), pp(e))

    # 8. `observed` that does not contain the variant, and provenance for a non-variant.
    case("observed lacks variant", any("containing the variant" in x
         for x in pp(_entry(["입력 슬롯"], {"입력 슬롯": _prov(observed="else")}, ko_measured))), "")
    case("stray provenance", any("not one of its variants" in x
         for x in pp(_entry(["입력 슬롯"], {"출력 슬롯": _prov(observed="출력 슬롯")}, ko_measured))), "")

    # 9. THE SHARED-STRING ATTACK. `editMenuBar` and `markerListEditMenuButton` both say 편집. A
    #    record showing the MENU BAR must not back the toolbar BUTTON, and the role is what says so.
    bar = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-ko"},
                 roles={"ko-KR": "AXMenuBarItem"}, canonical="편집", declared=("AXMenuBarItem",),
                 attrs={"ko-KR": "title"})
    case("menu-bar record backs the menu-bar label", cp(bar, "editMenuBar") == [], cp(bar, "editMenuBar"))
    btn = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-ko"},
                 roles={"ko-KR": "AXToolbarButton"}, canonical="편집", declared=("AXToolbarButton",),
                 attrs={"ko-KR": "title"})
    case("...and not a role the record never showed",
         any("no AXToolbarButton whose title carried" in x for x in cp(btn, "markerListEditMenuButton")),
         cp(btn, "markerListEditMenuButton"))

    # 10. Coverage bookkeeping: a claim needs a record, the right locale, and a role.
    case("measured without record", any("claim of measurement" in x for x in cp(_entry([], None, ko_measured))), "")
    case("measured wrong locale", any("not ko-KR" in x for x in
         cp(_entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-ja"}, roles={"ko-KR": "AXButton"},
                   attrs={"ko-KR": "help"}))), "")
    case("measured without a role", any("names no role" in x for x in
         cp(_entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-ko"}))), "")
    case("unmeasured with provenance", any("it is measured" in x for x in
         cp(_entry(["입력 슬롯"], {"입력 슬롯": _prov()}, U))), "")

    # 11. `identifier` names the identifier and the record must have SEEN it on that role. The
    #     earlier version of this case asserted only that an arbitrary same-locale record was
    #     accepted, and called that "backed".
    ok = _entry([], None, dict(U, **{"ko-KR": "identifier"}), cites={"ko-KR": "2026-09-05-ko"},
                roles={"ko-KR": "AXMenuButton"}, idents={"ko-KR": "markerEdit:"},
                declared=("AXMenuButton",))
    case("identifier backed by a sighting of that identifier", cp(ok) == [], cp(ok))
    no_id = _entry([], None, dict(U, **{"ko-KR": "identifier"}), cites={"ko-KR": "2026-09-05-ko"},
                   roles={"ko-KR": "AXMenuButton"}, declared=("AXMenuButton",))
    case("identifier without the identifier", any("names no AXIdentifier" in x for x in cp(no_id)), cp(no_id))
    wrong_id = _entry([], None, dict(U, **{"ko-KR": "identifier"}), cites={"ko-KR": "2026-09-05-ko"},
                      roles={"ko-KR": "AXMenuButton"}, idents={"ko-KR": "notThis:"},
                      declared=("AXMenuButton",))
    case("identifier the record never saw", any("whose identifier is" in x for x in cp(wrong_id)), cp(wrong_id))

    # 12. An AXIdentifier is not a label. A canonical that happens to equal some element's
    #     identifier must not make the label `measured` — identifiers are not localised, and the
    #     claim is about what Logic SHOWS.
    guard.OBS = _ledger({"2026-09-05-id": ("ko-KR", [_row("AXButton", identifier="편집", help="unrelated")])})
    ident_only = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-id"},
                        roles={"ko-KR": "AXButton"}, canonical="편집", declared=("AXButton",),
                        attrs={"ko-KR": "title"})
    case("an identifier is not a label sighting",
         any("carried any of this label" in x for x in cp(ident_only, "editMenuBar")),
         cp(ident_only, "editMenuBar"))
    guard.OBS = _ledger({
        "2026-09-05-ko":       ("ko-KR", [_row("AXButton", help="입력 슬롯. 채널 스트립 입력 소스", description="입력 1"),
                                          _row("AXMenuBarItem", title="편집"),
                                          _row("AXMenuButton", title="편집", identifier="markerEdit:")]),
        "2026-09-05-ja":       ("ja-JP", [_row("AXButton", help="入力スロット")]),
        "2026-09-05-ko-blind": ("ko-KR", [_row("AXStaticText", value="something with_input and an L in it")]),
        "2026-09-05-en":       ("en-US", [_row("AXMenuItem", title="Export")]),
    })

    # 13. Coverage that skips a locale, or uses a retired value.
    case("missing locale", any("expected exactly" in x for x in cp(_entry([], None, {"en-US": "unmeasured"}))), "")
    case("unknown coverage value refused",
         any("not one of" in x for x in cp(_entry([], None, dict(U, **{"ko-KR": "absent"})))), "")

    # 14. Evidence may not escape the evidence directory — a record could otherwise cite the very
    #     file whose claims it backs.
    #
    #     The earlier version of this case named `../locale/ui-labels.json`, which does not exist
    #     beside a temp ledger. `json.load` therefore failed and the sighting was refused for that
    #     reason — deleting the containment check entirely would not have failed the test. A control
    #     that cannot see the thing it controls for is not a control, so the escape target is now
    #     REAL and carries a row that would match if it were ever read.
    # `.resolve()` because macOS hands out `/var/folders/...`, which is itself a symlink to
    # `/private/var/...`. Left unresolved, a lexical containment check disagrees with a resolved one
    # about the ROOT, so it rejects legitimate evidence too — and the symlink case below then passes
    # under a broken implementation, for a reason that has nothing to do with symlinks.
    sandbox = Path(tempfile.mkdtemp()).resolve()
    (sandbox / "docs" / "observations" / "evidence").mkdir(parents=True)
    (sandbox / "elsewhere").mkdir()
    payload = json.dumps([_row("AXButton", help="입력 슬롯. 채널 스트립 입력 소스")], ensure_ascii=False)
    (sandbox / "elsewhere" / "planted.json").write_text(payload, encoding="utf-8")
    guard.OBS = str(sandbox / "docs" / "observations")

    # First prove the fixture is live: the same bytes UNDER evidence/ are read and do match.
    (sandbox / "docs" / "observations" / "evidence" / "real.json").write_text(payload, encoding="utf-8")
    inside = {"id": "i", "date": D, "host": {"locale": "ko-KR"}, "observations": [],
              "evidence": ["evidence/real.json"]}
    case("evidence under evidence/ IS read",
         guard.sighting(inside, "입력 슬롯", "AXButton", "help", "contains") is True,
         "the escape cases below would pass vacuously if this did not")

    outside = {"id": "x", "date": D, "host": {"locale": "ko-KR"}, "observations": [],
               "evidence": ["../../elsewhere/planted.json"]}
    case("evidence cannot escape by relative path",
         guard.sighting(outside, "입력 슬롯", "AXButton", "help", "contains") is False, "")

    # ...and not by a symlink either. `normpath` is lexical: `evidence/link.json` passed a
    # `startswith` test while resolving to the planted file, which is why this resolves realpath.
    try:
        (sandbox / "docs" / "observations" / "evidence" / "link.json").symlink_to(
            sandbox / "elsewhere" / "planted.json")
        linked = {"id": "s", "date": D, "host": {"locale": "ko-KR"}, "observations": [],
                  "evidence": ["evidence/link.json"]}
        case("evidence cannot escape by symlink",
             guard.sighting(linked, "입력 슬롯", "AXButton", "help", "contains") is False, "")
    except OSError:
        pass          # a filesystem without symlinks cannot host the attack either

    guard.OBS = _ledger({
        "2026-09-05-ko": ("ko-KR", [_row("AXButton", help="입력 슬롯. 채널 스트립 입력 소스"),
                                    _row("AXMenuBarItem", title="편집"),
                                    _row("AXMenuButton", title="편집", identifier="markerEdit:")]),
    })

    # 16. `observed` is a QUOTE of what the record carried, not a field the author fills in. A real
    #     record cited with invented extra text was accepted while only the variant was checked.
    ok_quote = _entry(["입력 슬롯"], {"입력 슬롯": _prov()}, ko_measured)
    case("an honest quote is accepted", pp(ok_quote) == [], pp(ok_quote))
    padded = _entry(["입력 슬롯"], {"입력 슬롯": _prov(observed="입력 슬롯. 채널 스트립 입력 소스 AND MORE")},
                    ko_measured)
    case("`observed` may not exceed what the record carried",
         any("actually carried" in x for x in pp(padded)), pp(padded))
    short = _entry(["입력 슬롯"], {"입력 슬롯": _prov(observed="입력 슬롯")}, ko_measured)
    case("...nor understate it", any("actually carried" in x for x in pp(short)), pp(short))
    # Compared RAW. Stripping both sides is not "character for character", and a padded quote
    # passed while the record held no such value — the documentation claimed the strict rule the
    # whole time this one was applied.
    padded = _entry(["입력 슬롯"],
                    {"입력 슬롯": _prov(observed="  입력 슬롯. 채널 스트립 입력 소스  ")}, ko_measured)
    case("...nor pad it with whitespace the record does not have",
         any("actually carried" in x for x in pp(padded)), pp(padded))

    # 17. The role must be one the LABEL declares. Without this, `editMenuBar` was backed by an
    #     AXMenuButton sighting belonging to a different label that shows the same string — the
    #     shared-string attack, arriving through provenance instead of through coverage.
    undeclared = _entry(["편집"], {"편집": _prov(role="AXMenuButton", attribute="title",
                                                observed="편집", match="exact")},
                        ko_measured, canonical="Edit", declared=("AXMenuBarItem",))
    case("provenance on an undeclared role is refused",
         any("not one of this label" in x for x in guard.provenance_problems("editMenuBar", undeclared)),
         guard.provenance_problems("editMenuBar", undeclared))
    nodecl = _entry(["편집"], {"편집": _prov(role="AXMenuBarItem", attribute="title",
                                            observed="편집", match="exact")},
                    ko_measured, canonical="Edit", declared=None)
    case("provenance with no declared roles at all is refused",
         any("declares no `roles`" in x for x in guard.provenance_problems("editMenuBar", nodecl)),
         guard.provenance_problems("editMenuBar", nodecl))

    # 18. A record's EXPECTATION is not a reading. These blocks are element-shaped on purpose, and
    #     that shape let a counterexample — "this is NOT what we see" — back a claim that we do.
    hyp = Path(tempfile.mkdtemp())
    (hyp / "h.json").write_text(json.dumps({
        "id": "h", "date": D, "host": {"locale": "ko-KR"},
        "observations": [{"what": "we predicted this and it was wrong",
                          "expected": _row("AXGroup", description="not 오토메이션 control")}]},
        ensure_ascii=False), encoding="utf-8")
    guard.OBS = str(hyp)
    fixture = _entry(["오토메이션"], {"오토메이션": _prov(record="h", role="AXGroup",
                                                       attribute="description", match="contains",
                                                       observed="not 오토메이션 control")},
                     ko_measured, declared=("AXGroup",))
    case("an `expected` block is not a sighting",
         any("carried it" in x for x in guard.provenance_problems("automationModeContext", fixture)),
         guard.provenance_problems("automationModeContext", fixture))
    # ...and the same bytes NOT under a hypothesis key are read, so the case above is not vacuous.
    (hyp / "h2.json").write_text(json.dumps({
        "id": "h2", "date": D, "host": {"locale": "ko-KR"},
        "observations": [{"what": "seen", "row": _row("AXGroup", description="not 오토메이션 control")}]},
        ensure_ascii=False), encoding="utf-8")
    seen = _entry(["오토메이션"], {"오토메이션": _prov(record="h2", role="AXGroup",
                                                    attribute="description", match="contains",
                                                    observed="not 오토메이션 control")},
                  ko_measured, declared=("AXGroup",))
    case("...but the same row outside one is",
         guard.provenance_problems("automationModeContext", seen) == [],
         guard.provenance_problems("automationModeContext", seen))

    # 18b. Coverage names the ATTRIBUTE it was read from, as provenance already does. Without it a
    #      string found in ANY attribute backed the claim, and some labels record in their own
    #      rationale which attribute is the readback and which is not.
    guard.OBS = _ledger({"2026-09-05-at": ("ko-KR", [_row("AXButton", help="입력 슬롯", title="전혀 다름")])})
    base_cov = dict(cites={"ko-KR": "2026-09-05-at"}, roles={"ko-KR": "AXButton"},
                    declared=("AXButton",), canonical="입력 슬롯")
    right = _entry([], None, ko_measured, attrs={"ko-KR": "help"}, **base_cov)
    case("coverage naming the attribute it was read from is accepted", cp(right) == [], cp(right))
    none_named = _entry([], None, ko_measured, **base_cov)
    case("coverage with no attribute is refused",
         any("no readable attribute" in x for x in cp(none_named)), cp(none_named))
    wrong = _entry([], None, ko_measured, attrs={"ko-KR": "title"}, **base_cov)
    case("coverage naming an attribute that did not carry it is refused",
         any("whose title carried" in x for x in cp(wrong)), cp(wrong))

    # 18c. MEASURED ABSENCE. "we looked and Logic shows none of these" was inexpressible: the ADR
    #      called it `measured`, and `measured` required a sighting CARRYING one of the strings —
    #      which a record proving absence can never produce. It collapsed into "nobody has looked".
    #     The claim also has to say WHICH element. `true` accepted any row of the declared role
    #     anywhere in the cited record, so an unrelated reading of some other button stood in for
    #     one nobody had looked at — the record was real, the role matched, and neither had
    #     anything to do with the label.
    P = "AXWindow/AXButton[target]"
    guard.OBS = _ledger({
        "2026-09-05-nil":  ("ko-KR", [_row("AXButton", help="전혀 다름", title="전혀 다름", path=P)]),
        "2026-09-05-gone": ("ko-KR", [_row("AXStaticText", value="전혀 다름", path=P)]),
        "2026-09-05-has":  ("ko-KR", [_row("AXButton", help="입력 슬롯", path=P)]),
        "2026-09-05-else": ("ko-KR", [_row("AXButton", help="전혀 다름", path="AXWindow/AXButton[other]")]),
    })
    absent = dict(roles={"ko-KR": "AXButton"}, declared=("AXButton",), canonical="입력 슬롯",
                  absent={"ko-KR": P})
    ok_absent = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-nil"}, **absent)
    case("an element seen carrying none of the strings is measured absence",
         cp(ok_absent) == [], cp(ok_absent))
    never_found = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-gone"}, **absent)
    case("absence about an element nobody located is refused",
         any("whose path carries" in x for x in cp(never_found)), cp(never_found))
    actually_there = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-has"}, **absent)
    case("absence contradicted by the record is refused",
         any("that is a presence" in x for x in cp(actually_there)), cp(actually_there))
    substring = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-nil"},
                       **dict(absent, absent={"ko-KR": "AX"}))
    case("a bare substring is not a locator",
         any("substring rather than a path" in x for x in cp(substring)), cp(substring))
    # ...and the comparison is the one a SIGHTING uses. These were two: `sighting` strips before an
    # exact test and the absence branch did not, so a padded value was a presence to one and an
    # absence to the other, about the same row.
    guard.OBS = _ledger({"2026-09-05-pad": ("ko-KR", [_row("AXButton", title="  입력 슬롯  ", path=P)])})
    # `match="exact"` on purpose: the two comparisons only ever disagreed on an exact test, because
    # containment gives the same answer whether or not the value was stripped.
    padded_row = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-pad"},
                        **dict(absent, absent={"ko-KR": P}, match="exact"))
    case("a padded value is a presence to both halves, not an absence to one",
         any("that is a presence" in x for x in cp(padded_row)), cp(padded_row))
    guard.OBS = _ledger({
        "2026-09-05-nil":  ("ko-KR", [_row("AXButton", help="전혀 다름", title="전혀 다름", path=P)]),
        "2026-09-05-gone": ("ko-KR", [_row("AXStaticText", value="전혀 다름", path=P)]),
        "2026-09-05-has":  ("ko-KR", [_row("AXButton", help="입력 슬롯", path=P)]),
        "2026-09-05-else": ("ko-KR", [_row("AXButton", help="전혀 다름", path="AXWindow/AXButton[other]")]),
    })
    untargeted = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-nil"},
                        **dict(absent, absent={"ko-KR": True}))
    case("absence that names no element is refused",
         any("must name the ELEMENT" in x for x in cp(untargeted)), cp(untargeted))
    wrong_element = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-else"}, **absent)
    case("absence backed by a DIFFERENT element of the same role is refused",
         any("whose path carries" in x for x in cp(wrong_element)), cp(wrong_element))

    guard.OBS = _ledger({
        "2026-09-05-ko": ("ko-KR", [_row("AXButton", help="입력 슬롯. 채널 스트립 입력 소스")]),
    })

    # 19. `retired` excuses a label whose element Logic no longer shows, and it must say why —
    #     otherwise it is just `unmeasured` with the debt hidden.
    r_ok = _entry(["팬"], None, {loc: "retired" for loc in LOCALES},
                  retired={"reason": "superseded by sliderPanHint", "since": D})
    case("retired with a reason is accepted", cp(r_ok, "headerPanHint") == [], cp(r_ok, "headerPanHint"))
    # ...and a label the product STILL READS cannot be retired. Any nonempty reason used to skip
    # every other check, and since the projection then marks all three locales `retired` and the
    # ratchets count only literal `unmeasured`, a live label could be dropped from every ceiling by
    # asserting it was gone. `cancelButton` is read at two call sites.
    # The audit reads Swift, so it must read it the way Swift is written: a use split across lines
    # was missed, and a label named only in a comment blocked an honest retirement.
    labels_mod = guard._module()
    import tempfile as _tf, os as _os
    src = Path(_tf.mkdtemp())
    (src / "Sources").mkdir()
    (src / "Sources" / "A.swift").write_text(
        "let a = AXLocalePolicy\n    .splitAcrossLines\n// AXLocalePolicy.onlyInAComment\n"
        "/* AXLocalePolicy.onlyInABlockComment */\n", encoding="utf-8")
    uses = labels_mod.swift_label_uses(str(src))
    case("a use split across lines counts", "splitAcrossLines" in uses, sorted(uses))
    case("a name in a line comment does not", "onlyInAComment" not in uses, sorted(uses))
    case("a name in a block comment does not", "onlyInABlockComment" not in uses, sorted(uses))

    live = sorted(guard._live_label_uses)[0] if guard._live_label_uses else None
    if live:
        r_live = _entry([], None, {loc: "retired" for loc in LOCALES},
                        retired={"reason": "claimed gone while the product still reads it"})
        case("a label the product still reads cannot be retired",
             any("still read in Sources/" in x for x in cp(r_live, live)), cp(r_live, live))
    r_bad = _entry(["팬"], None, {loc: "retired" for loc in LOCALES})
    case("retired without a reason is refused",
         any("names no `retired.reason`" in x for x in cp(r_bad, "headerPanHint")),
         cp(r_bad, "headerPanHint"))

    guard.OBS = _ledger({
        "2026-09-05-ko": ("ko-KR", [_row("AXButton", help="입력 슬롯. 채널 스트립 입력 소스")]),
    })

    # 15. Migration and carry-forward.
    v1 = {"schema": 1, "labels": {"inputSlotHelpKeyword": {"measured": {"입력 슬롯": _prov()}}}}
    built = labels.build(existing=v1)
    ent = built["labels"].get("inputSlotHelpKeyword") or {}
    case("measured block migrates", "입력 슬롯" in (ent.get("provenance") or {}), ent)
    case("measured derived", (ent.get("coverage") or {}).get("ko-KR") == "measured", ent.get("coverage"))
    case("schema 2", built.get("schema") == 2, built.get("schema"))
    v2 = {"schema": 2, "labels": {"inputSlotHelpKeyword": {
        "coverage": {"en-US": "measured", "ko-KR": "measured", "ja-JP": "unmeasured"},
        "coverage_records": {"en-US": "2026-09-05-en"}}}}
    cov = (labels.build(existing=v2)["labels"].get("inputSlotHelpKeyword") or {}).get("coverage") or {}
    case("cited measured survives", cov.get("en-US") == "measured", cov)
    case("uncited measured is dropped", cov.get("ko-KR") == "unmeasured", cov)

    # All three citation maps must travel together. Carrying only the record id meant the next
    # `--write` stripped the role and the identifier, and the guard then rejected a claim that had
    # been valid — regeneration turning evidence into a failure.
    v3 = {"schema": 2, "labels": {"inputSlotHelpKeyword": {
        "coverage": {"en-US": "identifier", "ko-KR": "unmeasured", "ja-JP": "unmeasured"},
        "coverage_records": {"en-US": "2026-09-05-en"},
        "coverage_roles": {"en-US": "AXMenuButton"},
        "coverage_identifiers": {"en-US": "markerEdit:"}}}}
    built3 = labels.build(existing=v3)["labels"].get("inputSlotHelpKeyword") or {}
    case("role survives regeneration", (built3.get("coverage_roles") or {}).get("en-US") == "AXMenuButton", built3)
    case("identifier survives regeneration",
         (built3.get("coverage_identifiers") or {}).get("en-US") == "markerEdit:", built3)

    # The product folds case in every mode (`caseInsensitiveCompare`, and `.caseInsensitive` on
    # `containsAny`), so the guard does too. Measured 2026-09-05: Logic shows the arrange canvas as
    # `Tracks contents` and `trackContentExplicit` stores `tracks contents`, because the classifier
    # lowercases before the lookup. Held case-sensitively this reading was unrecordable, and the
    # only way to satisfy the guard was to write a variant Logic does not show.
    #
    # The third case is the one that keeps the fold from being a hole: if absence were still judged
    # case-sensitively, changing the case of a string Logic really shows would turn a presence into
    # a claim that nobody shows it.
    guard.OBS = _ledger({"2026-09-05-case": ("en-US", [
        _row("AXGroup", description="Tracks contents",
             path="AXWindow[x]/AXScrollArea/AXGroup[Tracks contents]")])})
    en_measured = dict(U, **{"en-US": "measured"})
    folded = _entry(["tracks contents"], None, en_measured, canonical="트랙 콘텐츠", match="exact",
                    declared=("AXGroup",), cites={"en-US": "2026-09-05-case"},
                    roles={"en-US": "AXGroup"}, attrs={"en-US": "description"})
    case("case-differing reading is a sighting", cp(folded) == [], cp(folded))

    other = _entry(["track contents"], None, en_measured, canonical="트랙 콘텐츠", match="exact",
                   declared=("AXGroup",), cites={"en-US": "2026-09-05-case"},
                   roles={"en-US": "AXGroup"}, attrs={"en-US": "description"})
    case("a different string is still not a sighting",
         any("carried any of this label's strings" in x for x in cp(other)), cp(other))

    absent = _entry(["tracks contents"], None, en_measured, canonical="트랙 콘텐츠", match="exact",
                    declared=("AXGroup",), cites={"en-US": "2026-09-05-case"},
                    roles={"en-US": "AXGroup"}, absent={"en-US": "AXScrollArea/AXGroup["})
    case("case-differing presence defeats an absence claim",
         any("that is a presence" in x for x in cp(absent)), cp(absent))

    quoted = _entry(["tracks contents"], {"tracks contents": _prov(
        record="2026-09-05-case", locale="en-US", observed="Tracks contents", role="AXGroup",
        attribute="description", match="exact")}, en_measured, canonical="트랙 콘텐츠", match="exact",
        declared=("AXGroup",))
    case("a verbatim quote of a case-differing value is provenance",
         guard.provenance_problems("trackContentExplicit", quoted) == [],
         guard.provenance_problems("trackContentExplicit", quoted))

    lowered = _entry(["tracks contents"], {"tracks contents": _prov(
        record="2026-09-05-case", locale="en-US", observed="tracks contents", role="AXGroup",
        attribute="description", match="exact")}, en_measured, canonical="트랙 콘텐츠", match="exact",
        declared=("AXGroup",))
    case("the quote itself is still held raw",
         any("quotes observed" in x for x in guard.provenance_problems("trackContentExplicit", lowered)),
         guard.provenance_problems("trackContentExplicit", lowered))

    # `.exactStrict` is not a stricter `.exact`; it is a different comparison. Both fold case and
    # only `exact` trims the OBSERVED value, so a ledger holding one `exact` certifies a padded
    # reading the product refuses. Found by review 2026-09-05 with this exact shape: an AXGroup
    # whose description reads `" 再生ヘッドの位置 "`, cited for a label the product reads with
    # `.exactStrict`.
    guard.OBS = _ledger({"2026-09-05-pad": ("ja-JP", [
        _row("AXGroup", description=" 再生ヘッドの位置 ",
             path="AXWindow[x]/AXGroup[コントロールバー]/AXGroup[再生ヘッドの位置]")])})
    ja_measured = dict(U, **{"ja-JP": "measured"})

    def padded(match):
        return _entry(["再生ヘッドの位置"], None, ja_measured, canonical="playhead position",
                      match=match, declared=("AXGroup",), cites={"ja-JP": "2026-09-05-pad"},
                      roles={"ja-JP": "AXGroup"}, attrs={"ja-JP": "description"})

    case("a padded reading satisfies exact, which trims",
         cp(padded("exact"), "someTrimmingLabel") == [], cp(padded("exact"), "someTrimmingLabel"))
    case("a padded reading does NOT satisfy exact_strict, which does not",
         any("carried any of this label's strings" in x
             for x in cp(padded("exact_strict"), "someStrictLabel")),
         cp(padded("exact_strict"), "someStrictLabel"))

    # And the mode is not the author's to pick where the Swift can say. The label below is one the
    # product really does read with `.exactStrict`, so declaring anything else is refused.
    strict_name = sorted(guard._exact_strict)[0] if guard._exact_strict else None
    if strict_name:
        mislabelled = _entry(["x"], None, U, canonical="x", match="exact", declared=("AXGroup",))
        case("a set the Swift reads strictly may not declare a looser mode",
             any("`.exactStrict`" in x for x in guard.label_match(strict_name, mislabelled)[1]),
             guard.label_match(strict_name, mislabelled)[1])

    # The FOURTH mode. `.prefix` anchors, so containment — which the ledger used for the one label
    # read this way — accepts a sighting in the middle of a value that the product refuses. Found
    # while fixing the `.exactStrict` gap; same shape, opposite end of the same spectrum.
    guard.OBS = _ledger({"2026-09-05-pre": ("ko-KR", [
        _row("AXMenuItem", title="실행 취소 가져오기",
             path="AXMenuBar/AXMenuBarItem[편집]/AXMenu/AXMenuItem[실행 취소 가져오기]"),
        _row("AXMenuItem", title="마지막 실행 취소",
             path="AXMenuBar/AXMenuBarItem[편집]/AXMenu/AXMenuItem[마지막 실행 취소]")])})
    ko_pre = dict(U, **{"ko-KR": "measured"})

    def anchored(match, variant):
        return _entry([variant], None, ko_pre, canonical="Undo", match=match,
                      declared=("AXMenuItem",), cites={"ko-KR": "2026-09-05-pre"},
                      roles={"ko-KR": "AXMenuItem"}, attrs={"ko-KR": "title"})

    case("prefix accepts a value that STARTS with the label",
         cp(anchored("prefix", "실행 취소"), "anchoredHit") == [],
         cp(anchored("prefix", "실행 취소"), "anchoredHit"))
    # `취소` occurs inside both rows and starts neither — the one shape the two modes disagree
    # about. An earlier draft used `마지막 실행`, which IS a prefix of the second row, so it asserted
    # nothing and passed under both.
    case("prefix REFUSES a value that merely contains it",
         any("carried any of this label's strings" in x
             for x in cp(anchored("prefix", "취소"), "midValue")),
         cp(anchored("prefix", "취소"), "midValue"))
    case("contains would have accepted that same mid-value sighting",
         cp(anchored("contains", "취소"), "midValueLoose") == [],
         cp(anchored("contains", "취소"), "midValueLoose"))

    prefix_name = sorted(guard._prefix)[0] if guard._prefix else None
    if prefix_name:
        loose = _entry(["x"], None, U, canonical="x", match="contains", declared=("AXMenuItem",))
        case("a set the Swift reads with .prefix may not declare containment",
             any("`.prefix`" in x for x in guard.label_match(prefix_name, loose)[1]),
             guard.label_match(prefix_name, loose)[1])

    # 16. The real document is clean.
    proc = subprocess.run([sys.executable, str(HERE / "check-locale-labels-json.py")], capture_output=True, text=True)
    case("repository is clean", proc.returncode == 0, proc.stdout.strip()[:200])

    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print(f"{ran[0]} case(s) pass: a claim needs an element, an attribute and a role — a string in a blob is not a sighting")
    return 0


if __name__ == "__main__":
    sys.exit(main())
