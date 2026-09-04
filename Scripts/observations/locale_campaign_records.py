#!/usr/bin/env python3
"""The offline half of a locale campaign: census -> evidence file -> one record per surface.

    python3 locale-campaign-records.py <census.json> <repo> [--write]

Reads a census produced by locale-census, classifies its rows into the surfaces SURFACES.md names,
writes the census under docs/observations/evidence/ and one observation record per surface that
cites it. The records are shaped to satisfy check-observation-records.py: a generated host block,
a runnable reverify command, non-empty observations and limits, and a conclusion whose numbers are
all present in the observations. Without --write it prints what it would write.

What is deliberately NOT here: switching Logic's language, relaunching it, or the fixture check.
Those are live steps in locale-campaign.sh; this half can be dry-run on any census.
"""
import datetime
import json
import os
import re
import sys

# Which window rows belong to which taxonomy surface, decided by what the path passes through.
# Everything else is reported as unclassified in the menus record's limits rather than filed.
SURFACE_RULES = [
    ("arrange.track_headers", re.compile(r"AXGroup.*AXList.*AXLayoutArea.*AXLayoutItem(?!.*AXLayoutArea)")),
    ("arrange.transport",     re.compile(r"Transport|트랜스포트|LCD")),
]


# Ancestor labels the census writes into the path, in the locales measured so far. A row is filed
# under the FIRST surface whose marker appears in its path; unmatched rows stay unclassified and are
# counted in limits. Adding a locale means adding its spellings here — from a census, not a guess.
ANCESTRY = [
    ("arrange.transport",     ("{Transport}", "[컨트롤 막대", "[Control Bar", "[LCD")),
    ("mixer.channel_strips",  ("[왼쪽 인스펙터 채널 스트립", "[오른쪽 인스펙터 채널 스트립", "[Left Inspector", "[Right Inspector", "[믹서", "[Mixer")),
    ("library.patches",       ("[라이브러리", "[Library")),
    # Regions BEFORE headers: a region's path passes through a layout area described "N개의 ‘name’ 트랙",
    # which the headers marker would otherwise claim. First match wins, so the more specific goes first.
    ("arrange.regions",       ("[트랙 콘텐츠", "[Track Content", "[Tracks contents")),
    ("arrange.track_headers", ("[트랙 헤더", "[Track Header", "[트랙 헤더 목록", "’ 트랙]", "' Track]")),
]


def classify(row):
    if row["surface"] == "arrange.menus":
        return "arrange.menus"
    path = row["path"]
    for surface, markers in ANCESTRY:
        if any(m in path for m in markers):
            return surface
    help_ = row.get("help") or ""
    if "리전" in help_ or "region" in help_.lower():
        return "arrange.regions"
    if "트랙 헤더" in help_ or "track header" in help_.lower():
        return "arrange.track_headers"
    return None


def main(census_path, repo, write):
    census = json.load(open(census_path, encoding="utf-8"))
    host = census["host"]
    locale = host["locale"]
    if locale == "unknown":
        print("census locale is unknown — refusing to file records that cannot say what they are true of")
        return 2
    date = datetime.date.today().isoformat()
    obs_dir = os.path.join(repo, "docs", "observations")
    ev_rel = f"evidence/{date}-{locale}-navigation-free.census.json"
    ev_path = os.path.join(obs_dir, ev_rel)

    buckets, unclassified = {}, 0
    for row in census["census"]:
        s = classify(row)
        if s is None:
            unclassified += 1
            continue
        buckets.setdefault(s, []).append(row)

    records = {}
    for surface, rows in sorted(buckets.items()):
        rid = f"{date}-{locale}-{surface.replace('.', '-')}-census"
        strings = sorted({v for r in rows for k in ("title", "description", "help", "value") if (v := r.get(k))})
        idents = sorted({r["identifier"] for r in rows if r.get("identifier")})
        records[rid] = {
            "id": rid, "date": date, "schema": 2,
            "subject": f"Every string the {surface} surface exposes to AX in {locale}",
            "question": f"What labels does Logic show on {surface} in {locale}, and on which elements?",
            "verdict": "works",
            "issues": [768, 778],
            "surface": surface,
            "host": host,
            "reverify": {
                "kind": "script",
                "command": f"Scripts/observations/locale-census.sh {locale}",
                "expected": f"a census in {locale} whose {surface} rows carry the same {len(strings)} distinct strings; a differing set means Logic's labels moved and every provenance citing this record wants re-reading",
                "cost": "~1 min with Logic open on the fixture project in that locale",
            },
            "depends": ["Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift"],
            "evidence": [ev_rel],
            "method": (
                "Read, never actuated. The menu bar and every menu were walked without opening them; "
                "the main window was walked to depth 8. Each element with any string became one row of "
                "the evidence file; rows were assigned to this surface by what their path or help text "
                "passes through, and rows no rule could place are counted in limits rather than filed."
            ),
            "observations": [
                {"what": f"rows on {surface}", "rows": len(rows),
                 "distinct_strings": len(strings), "distinct_identifiers": len(idents)},
                {"what": "the strings, verbatim", "strings": strings},
                {"what": "identifiers seen", "identifiers": idents},
            ],
            "conclusion": (
                f"On this host in {locale}, {surface} exposes {len(rows)} elements carrying "
                f"{len(strings)} distinct strings. Every string is in the evidence file verbatim, which "
                f"is what lets a label variant cite this record: the guard requires the string to occur "
                f"in the observations or evidence, and here it does or it does not."
            ),
            "limits": [
                "Navigation-free surfaces only: nothing behind a menu press or a button was opened, so "
                "this says nothing about the mixer, plug-in editors or the editors.",
                f"{unclassified} window rows matched no surface rule and are not filed under any record; "
                "they are in the evidence file and can be re-classified when a rule exists.",
                "One project, one host, one build. A label that depends on project content — a track "
                "name, a region name — is a reading of this fixture, not of Logic.",
            ],
            "supersedes": None,
        }

    print(f"census {locale} {host['version']} ({host['build']}): {sum(len(v) for v in buckets.values())} rows "
          f"in {len(buckets)} surfaces, {unclassified} unclassified")
    for rid, rec in records.items():
        print(f"  {rid}: {rec['observations'][0]['rows']} rows, {rec['observations'][0]['distinct_strings']} strings")
    if not write:
        return 0
    os.makedirs(os.path.dirname(ev_path), exist_ok=True)
    json.dump(census, open(ev_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    for rid, rec in records.items():
        json.dump(rec, open(os.path.join(obs_dir, f"{rid}.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)
        open(os.path.join(obs_dir, f"{rid}.json"), "a", encoding="utf-8").write("\n")
    print(f"wrote {ev_rel} and {len(records)} record(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2], "--write" in sys.argv))
