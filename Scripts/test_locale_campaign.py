#!/usr/bin/env python3
"""Prove the campaign's offline half can fail — the proposer and the record filer.

The proposer is the step that turns a census into provenance, so a wrong rule here writes false
evidence into the ledger with a guard-passing shape. Each case plants one wrong shape and requires
the right refusal: a substring that is a different command, a string on an element of the wrong
role, a locale the census cannot prove, a surface with no record to cite.
"""
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name, filename):
    # The campaign tools live in Scripts/observations/ beside the other reverify runners; this test
    # sits at Scripts/ because that is where run-repo-guards.py discovers `test_*.py`.
    spec = importlib.util.spec_from_file_location(name, HERE / "observations" / filename)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


propose = load("locale_propose", "locale-propose.py")
_gspec = importlib.util.spec_from_file_location("locale_guard", HERE / "check-locale-labels-json.py")
guard = importlib.util.module_from_spec(_gspec); _gspec.loader.exec_module(guard)
records = load("locale_campaign_records", "locale_campaign_records.py")

HOST = {"app": "Logic Pro", "version": "12.3", "build": "6674", "locale": "ko-KR", "os": "macOS 26.3 (25D125)"}


def row(role, path, **strings):
    r = {"surface": "arrange.menus" if path.startswith("AXMenuBar") else "arrange.window",
         "path": path, "role": role, "title": None, "description": None, "help": None, "value": None, "identifier": None}
    r.update(strings); return r


def census(rows, locale="ko-KR"):
    return {"host": dict(HOST, locale=locale), "menu_bar": [], "census": rows}


def labels(**sets):
    return {"schema": 2, "supported_locales": ["en-US", "ko-KR", "ja-JP"], "labels": {
        k: {"canonical": v[0], "variants": v[1], "rationale": "r",
            "coverage": {"en-US": "unmeasured", "ko-KR": "unmeasured", "ja-JP": "unmeasured"}}
        for k, v in sets.items()}}


def write(tmp, doc):
    p = Path(tmp) / "ui-labels.json"; p.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8"); return str(p)


def main():
    failures = []
    ran = [0]

    def case(name, cond, detail):
        ran[0] += 1
        if not cond: failures.append(f"{name}: {detail}")
    tmp = tempfile.mkdtemp()
    cpath = str(Path(tmp) / "census.json")

    # 1. A menu item is matched EXACTLY: "끔" must not be backed by "사이클 끔", which is a different command.
    json.dump(census([row("AXMenuItem", "AXMenuBar/AXMenuBarItem[녹음]/AXMenu/AXMenuItem[사이클 끔]", title="사이클 끔")]), open(cpath, "w"))
    _, _, props, _ = propose.main(cpath, write(tmp, labels(automationModeOff=("off", ["끔"]))))
    case("substring of a different command is not proposed", "automationModeOff" not in props, props)

    # 2. ...but the exact item is.
    json.dump(census([row("AXMenuItem", "AXMenuBar/AXMenuBarItem[Mix]/AXMenu/AXMenuItem[끔]", title="끔")]), open(cpath, "w"))
    _, _, props, _ = propose.main(cpath, write(tmp, labels(automationModeOff=("off", ["끔"]))))
    case("exact item is proposed", "automationModeOff" in props, props)

    # 3. A help KEYWORD is matched by containment — that is how the product reads it.
    json.dump(census([row("AXButton", "AXWindow/AXGroup/AXButton", help="입력 슬롯. 채널 스트립 입력 소스를 선택합니다")]), open(cpath, "w"))
    _, _, props, _ = propose.main(cpath, write(tmp, labels(inputSlotHelpKeyword=("input slot", ["입력 슬롯"]))))
    case("help keyword matched by containment", "inputSlotHelpKeyword" in props, props)

    # 4. ROLE GATING: "Edit" on a menu-bar item backs editMenuBar and NOT markerListEditMenuButton.
    json.dump(census([row("AXMenuBarItem", "AXMenuBar/AXMenuBarItem[편집]", title="편집")]), open(cpath, "w"))
    _, _, props, unmatched = propose.main(cpath, write(tmp, labels(
        editMenuBar=("Edit", ["편집"]), markerListEditMenuButton=("Edit", ["편집"]))))
    case("menu-bar item backs the menu-bar label", "editMenuBar" in props, props)
    case("menu-bar item does not back a menu BUTTON label", "markerListEditMenuButton" not in props, props)
    case("the wrong-role match is reported, not silently dropped", "markerListEditMenuButton" in unmatched, unmatched)

    # 5. --apply writes provenance only where the surface has a record, and cites THAT record.
    json.dump(census([row("AXMenuItem", "AXMenuBar/AXMenuBarItem[파일]/AXMenu/AXMenuItem[내보내기]", title="내보내기")]), open(cpath, "w"))
    lp = write(tmp, labels(exportMenuItem=("Export", ["내보내기"])))
    _, _, props, _ = propose.main(cpath, lp)
    n_prov, n_cov = propose.apply(lp, json.load(open(cpath)), props, {"arrange.menus": "2026-09-05-ko-KR-arrange-menus-census"})
    doc = json.load(open(lp, encoding="utf-8"))
    block = (doc["labels"]["exportMenuItem"].get("provenance") or {}).get("내보내기") or {}
    case("apply wrote one block", n_prov == 1, (n_prov, n_cov))
    case("block cites the surface's record", block.get("record") == "2026-09-05-ko-KR-arrange-menus-census", block)
    case("block's observed contains the variant", "내보내기" in block.get("observed", ""), block)
    case("block's locale is the census locale", block.get("locale") == "ko-KR", block)

    # 5b. THE INTEGRATION. Everything above checks what the proposer writes; this checks that the
    #     GUARD accepts it. The two encode one contract in two places, and the moment they disagree
    #     a campaign fills the ledger with blocks that are refused on arrival.
    #
    #     This is not hypothetical. `match` was decided here from the label's NAME and there from the
    #     Swift call sites, and measured against each other the name rule was wrong for 23 of the 31
    #     sets the product reads with `containsAny` — every one proposed as `exact` and refused.
    for label_name, canonical, variant, text, mode, ax_role, ax_path in (
            ("exportMenuItem", "Export", "내보내기", "내보내기", "exact",
             "AXMenuItem", "AXMenuBar/AXMenuBarItem[F]/AXMenu/AXMenuItem[내보내기]"),
            # An AXButton, because the proposer gates `*Button` labels on button-shaped roles and
            # would rightly refuse this string on a menu item.
            ("cancelButton",   "Cancel", "취소",     "취소 하시겠습니까", "contains",
             "AXButton", "AXWindow/AXButton[취소]")):
        obs = Path(tempfile.mkdtemp())
        rid = "2026-09-05-ko-KR-arrange-menus-census"
        json.dump({"id": rid, "date": "2026-09-05", "host": dict(HOST, locale="ko-KR"),
                   "observations": [{"role": ax_role, "title": text}]},
                  open(obs / f"{rid}.json", "w", encoding="utf-8"), ensure_ascii=False)
        json.dump(census([row(ax_role, ax_path, title=text)]), open(cpath, "w"))
        lp = write(tmp, labels(**{label_name: (canonical, [variant])}))
        _, _, props, _ = propose.main(cpath, lp)
        surface = "arrange.menus" if ax_path.startswith("AXMenuBar") else "arrange.window"
        propose.apply(lp, json.load(open(cpath)), props, {surface: rid})
        entry = json.load(open(lp, encoding="utf-8"))["labels"][label_name]
        block = (entry.get("provenance") or {}).get(variant) or {}
        case(f"{label_name}: the proposer declares the match the product uses",
             block.get("match") == mode, block)
        case(f"{label_name}: `observed` is the whole value, not a clipped one",
             block.get("observed") == text, block)
        case(f"{label_name}: the label declares the role it was read on",
             entry.get("roles") == [ax_role], entry)
        saved, guard.OBS = guard.OBS, str(obs)
        try:
            problems = guard.provenance_problems(label_name, entry)
        finally:
            guard.OBS = saved
        case(f"{label_name}: the GUARD accepts what the proposer wrote", problems == [], problems)

    # 6. --apply writes NOTHING when the surface has no record — a citation to nothing is refused upstream.
    lp = write(tmp, labels(exportMenuItem=("Export", ["내보내기"])))
    n_prov, _ = propose.apply(lp, json.load(open(cpath)), props, {})
    case("no record, no provenance", n_prov == 0 and not json.load(open(lp))["labels"]["exportMenuItem"].get("provenance"), n_prov)

    # 7. A canonical-only match becomes a coverage citation, not a provenance block.
    json.dump(census([row("AXMenuItem", "AXMenuBar/AXMenuBarItem[File]/AXMenu/AXMenuItem[Export]", title="Export")], locale="en-US"), open(cpath, "w"))
    lp = write(tmp, labels(exportMenuItem=("Export", ["내보내기"])))
    _, _, props, _ = propose.main(cpath, lp)
    n_prov, n_cov = propose.apply(lp, json.load(open(cpath)), props, {"arrange.menus": "2026-09-05-en-US-arrange-menus-census"})
    e = json.load(open(lp))["labels"]["exportMenuItem"]
    case("canonical match cites coverage", n_cov == 1 and e["coverage"]["en-US"] == "measured"
         and e.get("coverage_records", {}).get("en-US") == "2026-09-05-en-US-arrange-menus-census", e)

    # 8. The record filer refuses a census whose locale it cannot prove.
    json.dump(census([], locale="unknown"), open(cpath, "w"))
    case("unknown locale refuses", records.main(cpath, tmp, False) == 2, "filed records for an unprovable locale")

    # 9. Classification: regions before headers, so a region under a track-labelled area is a region.
    r = row("AXLayoutItem", "AXWindow[x]/AXGroup[트랙 콘텐츠]/AXLayoutArea[34개의 ‘Studio Grand’ 트랙]/AXLayoutItem", help="리전은 1 마디")
    case("region under a track-labelled area is a region", records.classify(r) == "arrange.regions", records.classify(r))
    r = row("AXSlider", "AXWindow[x]/AXGroup[컨트롤 막대]/AXGroup[재생헤드 위치]/AXSlider[마디]", description="마디")
    case("control bar routes to transport", records.classify(r) == "arrange.transport", records.classify(r))
    r = row("AXButton", "AXWindow[x]/AXGroup/AXList/AXGroup/AXButton", description="chrome")
    case("unlabelled chrome stays unclassified", records.classify(r) is None, records.classify(r))

    if failures:
        for f in failures: print(f"FAIL {f}")
        return 1
    print(f"{ran[0]} case(s) pass: the proposer matches the way the product matches, gates on role, "
          f"and cites only records that exist")
    return 0


if __name__ == "__main__":
    sys.exit(main())
