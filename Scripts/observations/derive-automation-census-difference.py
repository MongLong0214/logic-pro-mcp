#!/usr/bin/env python3
"""Recompute every number the automation-point record publishes, from the committed censuses.

The record behind this script says that driving `Mix > 트랙 오토메이션 생성 > 리전 경계에 2개의
오토메이션 포인트 생성` changes exactly one AX reading in the arrange window. That is a claim about
a comparison, and a comparison nobody can redo is a summary. This script redoes it: it reads the
five state-tagged censuses in docs/observations/evidence/ and asserts the published counts against
what it finds, so a number that drifts from the readings fails here rather than being believed.

It also carries the CONTROL for the region precondition. The earlier precondition accepted any
selected AXLayoutItem whose AXHelp contained the canon `Region` value; MIDI notes satisfy that,
because Logic's note help says a note is edited the same way as a region. Asserting the naive
predicate's wrong answer beside the canon predicate's right one keeps that defect from coming back
silently -- a guard whose control is not committed is a guard that can rot into agreement.

Run: python3 Scripts/observations/derive-automation-census-difference.py
Exit 0 if every published number is reproduced, 1 otherwise.
"""

import collections
import json
import os
import subprocess
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
EVIDENCE = os.path.join(REPO, "docs", "observations", "evidence")

# Every attribute the census captured. The comparison runs over all of them, not over a chosen
# few: a key that names six fields can only ever report about six fields, and the difference this
# record is about lives in AXHelp, which an earlier six-field key did not include.
FIELDS = [
    "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXRoleDescription", "AXHelp",
    "AXIdentifier", "AXValue", "AXMinValue", "AXMaxValue", "AXEnabled", "AXSelected",
    "AXFocused", "AXPosition", "AXSize", "actions",
]

STATES = ["after-create", "after-undo", "after-redo", "cycle2-after-undo", "cycle2-after-redo"]

# What the record publishes. Each entry is checked below.
EXPECTED_ROWS = 719
EXPECTED_WINDOW = "무제 30 - 트랙"
EXPECTED_DIFFERING_ROW = 475
EXPECTED_CONTROL_ROW = 460
HELP_WITH_DATA = "오토메이션 파라미터 켬/끔. 해당 오토메이션 파라미터의 오토메이션 데이터를 켜거나 끕니다. "
HELP_WITHOUT_DATA = "오토메이션 파라미터 팝업 메뉴. 오토메이션할 채널 스트립, Smart Control 또는 플러그인 파라미터를 선택합니다. "
POINTS_PRESENT = ["after-create", "after-redo", "cycle2-after-redo"]
POINTS_ABSENT = ["after-undo", "cycle2-after-undo"]

EXPECTED_NAIVE_MATCHES = 4
EXPECTED_CANON_MATCHES = 1
# A citation is the reference AND the value it resolves to: a reference alone is a key anybody can
# type. Both are resolved from the pinned corpus at run time below and only quoted here.
# resolves to: 리전
REGION_REF = ("logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA"
              "%2FResources%2FLocalizable.strings/ko/Region#value")
# resolves to: MIDI 리전. MIDI 노트 및 컨트롤러 이벤트를 포함합니다. 가운데를 드래그하여 이동하고, 하단 가장자리를 드래그하여 크기를 조정하며, 상단 오른쪽 모서리를 드래그하여 루핑합니다. 도구를 사용하여 그 외의 편집을 수행합니다.
MIDI_REGION_REF = "logic-canon://quickhelp/QuickHelp/ko/ARR_021_MidiRegion#composed"

failures = []


def nfc(text):
    """Compare Korean AX strings under NFC.

    Logic does not vend one normalization. The arrange window's title reads back as
    `무제 30 - 트랙` where `무제` is four conjoining jamo (U+1106 U+116E U+110C U+1166) and `트랙`,
    four characters later in the same string, is two precomposed syllables (U+D2B8 U+B799) -- the
    string is neither NFC nor NFD. A typed literal is NFC, so byte equality reports a difference
    between two strings that are the same text and print identically. The AXHelp values measured
    here happen to be NFC, which is luck rather than a property to rely on: every comparison in
    this script normalizes both sides so that a normalization difference can neither pass as a
    match nor fail as one.
    """
    return unicodedata.normalize("NFC", text) if isinstance(text, str) else text


def check(condition, message):
    if not condition:
        failures.append(message)
    return condition


def load(state):
    path = os.path.join(EVIDENCE, f"2026-09-21-ko-KR-automation-census-{state}.json")
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def resolve(ref):
    """Resolve a canon reference against the PINNED corpus. Never type the value instead."""
    out = subprocess.run(
        [sys.executable, os.path.join(REPO, "Scripts", "logic_canon.py"), "resolve", ref],
        capture_output=True, text=True,
    )
    return out.stdout.splitlines()[0] if out.stdout.strip() else ""


def key(row):
    return tuple(json.dumps(row.get(f), ensure_ascii=False, sort_keys=True) for f in FIELDS)


def whole_row(row):
    return json.dumps({k: v for k, v in row.items() if k != "i"}, ensure_ascii=False, sort_keys=True)


def main():
    censuses = {}
    for state in STATES:
        doc = load(state)
        censuses[state] = doc
        check(doc["total"] == EXPECTED_ROWS,
              f"{state}: census has {doc['total']} rows, record says {EXPECTED_ROWS}")
        check(nfc(doc["window_title"]) == nfc(EXPECTED_WINDOW),
              f"{state}: censused window is {doc['window_title']!r}, record says {EXPECTED_WINDOW!r}")

    print(f"censuses: {len(censuses)} states, {EXPECTED_ROWS} rows each, window {EXPECTED_WINDOW!r}")
    print(f"fields compared per row: {len(FIELDS)} ({', '.join(FIELDS)})")
    print()

    # 1. Whole-row multiset, over every captured field including path and depth. Deliberately NOT
    #    normalized: both sides of this comparison come from AX, so a normalization difference
    #    between two states would be a real difference in the reading and must not be smoothed away.
    #    Only comparisons against a typed or canon literal go through nfc().
    print("whole-row multiset differences (every captured field):")
    for present in POINTS_PRESENT:
        for absent in POINTS_ABSENT:
            a = collections.Counter(whole_row(r) for r in censuses[present]["rows"])
            b = collections.Counter(whole_row(r) for r in censuses[absent]["rows"])
            only_a, only_b = sum((a - b).values()), sum((b - a).values())
            print(f"  {present:18s} vs {absent:18s}: {only_a} / {only_b}")
            check(only_a == 1 and only_b == 1,
                  f"{present} vs {absent}: expected exactly 1 row differing each way, got {only_a}/{only_b}")

    for pair in [("after-create", "after-redo"), ("after-create", "cycle2-after-redo"),
                 ("after-undo", "cycle2-after-undo")]:
        a = collections.Counter(whole_row(r) for r in censuses[pair[0]]["rows"])
        b = collections.Counter(whole_row(r) for r in censuses[pair[1]]["rows"])
        only_a, only_b = sum((a - b).values()), sum((b - a).values())
        print(f"  {pair[0]:18s} vs {pair[1]:18s}: {only_a} / {only_b}   (same-state pair)")
        check(only_a == 0 and only_b == 0,
              f"{pair[0]} vs {pair[1]}: two censuses of the SAME state should not differ, got {only_a}/{only_b}")
    print()

    # 2. Which row, and which field. Joined by census index, with the path checked to agree so the
    #    join is not silently comparing different elements.
    print("per-field differences, joined by census index:")
    for present in POINTS_PRESENT:
        for absent in POINTS_ABSENT:
            ra = {r["i"]: r for r in censuses[present]["rows"]}
            rb = {r["i"]: r for r in censuses[absent]["rows"]}
            mismatched_paths = sum(1 for i in ra if ra[i]["path"] != rb[i]["path"])
            check(mismatched_paths == 0,
                  f"{present} vs {absent}: {mismatched_paths} rows have different paths at the same "
                  f"index, so the join does not compare like with like")
            differing = collections.defaultdict(list)
            for i in ra:
                for f in FIELDS:
                    if json.dumps(ra[i].get(f), ensure_ascii=False, sort_keys=True) != \
                       json.dumps(rb[i].get(f), ensure_ascii=False, sort_keys=True):
                        differing[f].append(i)
            print(f"  {present:18s} vs {absent:18s}: {dict((f, v) for f, v in differing.items())}")
            check(list(differing) == ["AXHelp"],
                  f"{present} vs {absent}: expected AXHelp to be the only differing field, got {list(differing)}")
            check(differing.get("AXHelp") == [EXPECTED_DIFFERING_ROW],
                  f"{present} vs {absent}: expected row {EXPECTED_DIFFERING_ROW} to be the only one "
                  f"whose AXHelp differs, got {differing.get('AXHelp')}")
    print()

    # 3. The differing element's identity, and the two help variants, stated exactly.
    row = {r["i"]: r for r in censuses["after-create"]["rows"]}[EXPECTED_DIFFERING_ROW]
    print(f"differing element: i={EXPECTED_DIFFERING_ROW} role={row['AXRole']} "
          f"description={row['AXDescription']!r}")
    print(f"  path: {row['path']}")
    check(row["AXRole"] == "AXPopUpButton",
          f"differing element role is {row['AXRole']}, record says AXPopUpButton")
    check(nfc(row["AXDescription"]) == nfc("오토메이션 파라미터"),
          f"differing element description is {row['AXDescription']!r}, record says 오토메이션 파라미터")
    check("AXLayoutItem[1]" in row["path"],
          f"differing element is not under AXLayoutItem[1]: {row['path']}")

    for state in POINTS_PRESENT:
        got = {r["i"]: r for r in censuses[state]["rows"]}[EXPECTED_DIFFERING_ROW]["AXHelp"]
        check(nfc(got) == nfc(HELP_WITH_DATA), f"{state}: help is {got!r}, record says {HELP_WITH_DATA!r}")
    for state in POINTS_ABSENT:
        got = {r["i"]: r for r in censuses[state]["rows"]}[EXPECTED_DIFFERING_ROW]["AXHelp"]
        check(nfc(got) == nfc(HELP_WITHOUT_DATA), f"{state}: help is {got!r}, record says {HELP_WITHOUT_DATA!r}")
    print(f"  with automation data:    {HELP_WITH_DATA!r}")
    print(f"  without automation data: {HELP_WITHOUT_DATA!r}")
    print()

    # 4. The within-run control: the SAME control on the other track never moves. Without this, a
    #    global UI mode that happened to follow undo would read exactly like a per-track readback.
    control_helps = {
        state: {r["i"]: r for r in censuses[state]["rows"]}[EXPECTED_CONTROL_ROW]["AXHelp"]
        for state in STATES
    }
    control_row = {r["i"]: r for r in censuses["after-create"]["rows"]}[EXPECTED_CONTROL_ROW]
    print(f"control element: i={EXPECTED_CONTROL_ROW} description={control_row['AXDescription']!r} "
          f"path={control_row['path']}")
    check(nfc(control_row["AXDescription"]) == nfc("오토메이션 파라미터"),
          "the control element is not the same kind of control as the differing one")
    check("AXLayoutItem[0]" in control_row["path"],
          f"the control element is not on the other track: {control_row['path']}")
    check(len(set(control_helps.values())) == 1,
          f"the control element's help is not constant across states: {control_helps}")
    check({nfc(v) for v in control_helps.values()} == {nfc(HELP_WITHOUT_DATA)},
          "the control element does not read as the no-automation-data variant in every state")
    print(f"  constant across all {len(STATES)} states: {next(iter(set(control_helps.values())))!r}")
    print()

    # 5. The region precondition control, against the canon rather than a typed string.
    region = resolve(REGION_REF)
    midi_region = resolve(MIDI_REGION_REF)
    if not check(bool(region), "cannot resolve the canon Region value") or \
       not check(bool(midi_region), "cannot resolve the canon ARR_021_MidiRegion composed value"):
        return report()

    layout_items = [r for r in censuses["after-create"]["rows"] if r["AXRole"] == "AXLayoutItem"]
    naive = [r for r in layout_items if nfc(region) in nfc(r.get("AXHelp") or "")]
    canon = [r for r in layout_items if nfc(midi_region) in nfc(r.get("AXHelp") or "")]
    print(f"region precondition control, over {len(layout_items)} AXLayoutItem rows:")
    print(f"  naive  (AXHelp contains {region!r}): {len(naive)} -> "
          f"{[r['AXDescription'] for r in naive]}")
    print(f"  canon  (AXHelp contains ARR_021_MidiRegion composed): {len(canon)} -> "
          f"{[r['AXDescription'] for r in canon]}")
    check(len(naive) == EXPECTED_NAIVE_MATCHES,
          f"naive predicate matched {len(naive)} rows, record says {EXPECTED_NAIVE_MATCHES}")
    check(len(canon) == EXPECTED_CANON_MATCHES,
          f"canon predicate matched {len(canon)} rows, record says {EXPECTED_CANON_MATCHES}")
    # The point of the control is that the naive predicate admits things that are NOT regions.
    naive_only = [r for r in naive if r not in canon]
    check(len(naive_only) == EXPECTED_NAIVE_MATCHES - EXPECTED_CANON_MATCHES,
          "the naive predicate did not over-match, so this control proves nothing")
    check(all(str(r["AXDescription"]).startswith("Note at") for r in naive_only),
          f"the rows the naive predicate over-matched are not the MIDI notes: "
          f"{[r['AXDescription'] for r in naive_only]}")
    print(f"  over-matched by naive only: {[r['AXDescription'] for r in naive_only]}")
    print()

    return report()


def report():
    if failures:
        print(f"FAIL: {len(failures)} published number(s) not reproduced by the committed readings")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("OK: every published number is reproduced by the committed readings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
