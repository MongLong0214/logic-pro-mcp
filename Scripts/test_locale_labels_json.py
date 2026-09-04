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
VALUES = ("measured", "identifier", "unmeasured")
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
    r = {"role": role, "title": None, "description": None, "help": None, "value": None, "identifier": None}
    r.update(attrs)
    return r


def _entry(variants, provenance=None, coverage=None, cites=None, roles=None, idents=None,
           canonical="input slot"):
    e = {"canonical": canonical, "variants": variants, "rationale": "r"}
    if provenance is not None:
        e["provenance"] = provenance
    e["coverage"] = coverage if coverage is not None else {loc: "unmeasured" for loc in LOCALES}
    if cites:
        e["coverage_records"] = cites
    if roles:
        e["coverage_roles"] = roles
    if idents:
        e["coverage_identifiers"] = idents
    return e


def _prov(record="2026-09-05-ko", locale="ko-KR", observed="입력 슬롯. 채널 스트립", date=D,
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

    def case(name, condition, detail):
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
                                              role="AXStaticText", attribute="value", match="contains")}, U)
    case("a KEY is not a sighting",
         any("carried it" in x for x in guard.provenance_problems("nonInsertButtonText", keyed)),
         guard.provenance_problems("nonInsertButtonText", keyed))

    guard.OBS = _ledger({"2026-09-05-l": ("ko-KR", [_row("AXStaticText", value="an L in it")])})
    ell = _entry(["L"], {"L": _prov(record="2026-09-05-l", observed="an L in it",
                                    role="AXStaticText", attribute="value", match="exact")}, U)
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
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov(match=None)}, ko_measured)
    case("match mode is required", any("must name `match`" in x for x in pp(e)), pp(e))

    # `cancelButton` IS read with containsAny at a call site, so the Swift can contradict the claim.
    # `inputSlotHelpKeyword` is passed to a helper and cannot be derived, which is why the block
    # declares the mode rather than the guard inferring it everywhere.
    guard.OBS = _ledger({"2026-09-05-c": ("ko-KR", [_row("AXButton", help="취소 하시겠습니까")])})
    cancel = _entry(["취소"], {"취소": _prov(record="2026-09-05-c", observed="취소 하시겠습니까",
                                            role="AXButton", attribute="help", match="exact")}, ko_measured)
    case("claiming exact for a containsAny set is refused",
         any("reads this set with `containsAny`" in x
             for x in guard.provenance_problems("cancelButton", cancel)),
         guard.provenance_problems("cancelButton", cancel))
    cancel["provenance"]["취소"]["match"] = "contains"
    case("...and declaring it correctly is accepted",
         guard.provenance_problems("cancelButton", cancel) == [],
         guard.provenance_problems("cancelButton", cancel))

    # ...and an exact-matched set really is checked exactly: a menu title that merely CONTAINS the
    # variant is a different command, which is the attack this mode exists to stop.
    guard.OBS = _ledger({"2026-09-05-m": ("ko-KR", [_row("AXMenuItem", title="사이클 끔")])})
    off = _entry(["끔"], {"끔": _prov(record="2026-09-05-m", observed="사이클 끔",
                                     role="AXMenuItem", attribute="title", match="exact")}, ko_measured)
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
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov(role="AXMenuItem")}, ko_measured)
    case("wrong role refused", any("no AXMenuItem whose help carried it" in x for x in pp(e)), pp(e))

    # 8. `observed` that does not contain the variant, and provenance for a non-variant.
    case("observed lacks variant", any("containing the variant" in x
         for x in pp(_entry(["입력 슬롯"], {"입력 슬롯": _prov(observed="else")}, ko_measured))), "")
    case("stray provenance", any("not one of its variants" in x
         for x in pp(_entry(["입력 슬롯"], {"출력 슬롯": _prov(observed="출력 슬롯")}, ko_measured))), "")

    # 9. THE SHARED-STRING ATTACK. `editMenuBar` and `markerListEditMenuButton` both say 편집. A
    #    record showing the MENU BAR must not back the toolbar BUTTON, and the role is what says so.
    bar = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-ko"},
                 roles={"ko-KR": "AXMenuBarItem"}, canonical="편집")
    case("menu-bar record backs the menu-bar label", cp(bar, "editMenuBar") == [], cp(bar, "editMenuBar"))
    btn = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-ko"},
                 roles={"ko-KR": "AXToolbarButton"}, canonical="편집")
    case("...and not a role the record never showed",
         any("no AXToolbarButton carrying" in x for x in cp(btn, "markerListEditMenuButton")),
         cp(btn, "markerListEditMenuButton"))

    # 10. Coverage bookkeeping: a claim needs a record, the right locale, and a role.
    case("measured without record", any("claim of measurement" in x for x in cp(_entry([], None, ko_measured))), "")
    case("measured wrong locale", any("not ko-KR" in x for x in
         cp(_entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-ja"}, roles={"ko-KR": "AXButton"}))), "")
    case("measured without a role", any("names no role" in x for x in
         cp(_entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-ko"}))), "")
    case("unmeasured with provenance", any("it is measured" in x for x in
         cp(_entry(["입력 슬롯"], {"입력 슬롯": _prov()}, U))), "")

    # 11. `identifier` names the identifier and the record must have SEEN it on that role. The
    #     earlier version of this case asserted only that an arbitrary same-locale record was
    #     accepted, and called that "backed".
    ok = _entry([], None, dict(U, **{"ko-KR": "identifier"}), cites={"ko-KR": "2026-09-05-ko"},
                roles={"ko-KR": "AXMenuButton"}, idents={"ko-KR": "markerEdit:"})
    case("identifier backed by a sighting of that identifier", cp(ok) == [], cp(ok))
    no_id = _entry([], None, dict(U, **{"ko-KR": "identifier"}), cites={"ko-KR": "2026-09-05-ko"},
                   roles={"ko-KR": "AXMenuButton"})
    case("identifier without the identifier", any("names no AXIdentifier" in x for x in cp(no_id)), cp(no_id))
    wrong_id = _entry([], None, dict(U, **{"ko-KR": "identifier"}), cites={"ko-KR": "2026-09-05-ko"},
                      roles={"ko-KR": "AXMenuButton"}, idents={"ko-KR": "notThis:"})
    case("identifier the record never saw", any("whose identifier is" in x for x in cp(wrong_id)), cp(wrong_id))

    # 12. An AXIdentifier is not a label. A canonical that happens to equal some element's
    #     identifier must not make the label `measured` — identifiers are not localised, and the
    #     claim is about what Logic SHOWS.
    guard.OBS = _ledger({"2026-09-05-id": ("ko-KR", [_row("AXButton", identifier="편집", help="unrelated")])})
    ident_only = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-id"},
                        roles={"ko-KR": "AXButton"}, canonical="편집")
    case("an identifier is not a label sighting",
         any("carrying any of this label" in x for x in cp(ident_only, "editMenuBar")),
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
    case("retired value refused", any("not one of" in x for x in cp(_entry([], None, dict(U, **{"ko-KR": "absent"})))), "")

    # 14. Evidence may not escape the evidence directory — a record could otherwise cite the very
    #     file whose claims it backs.
    outside = {"id": "x", "date": D, "host": {"locale": "ko-KR"}, "observations": [],
               "evidence": ["../locale/ui-labels.json"]}
    case("evidence cannot escape", guard.sighting(outside, "입력 슬롯", "AXButton", "help") is False, "")

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

    # 16. The real document is clean.
    proc = subprocess.run([sys.executable, str(HERE / "check-locale-labels-json.py")], capture_output=True, text=True)
    case("repository is clean", proc.returncode == 0, proc.stdout.strip()[:200])

    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print("35 case(s) pass: a claim needs an element, an attribute and a role — a string in a blob is not a sighting")
    return 0


if __name__ == "__main__":
    sys.exit(main())
