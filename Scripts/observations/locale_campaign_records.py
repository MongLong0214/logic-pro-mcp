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
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

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
    ("arrange.transport",     ("{Transport}", "[컨트롤 막대", "[Control Bar", "[LCD", "[コントロールバー",
                               "[Steuerungsleiste")),
    ("mixer.channel_strips",  ("[왼쪽 인스펙터 채널 스트립", "[오른쪽 인스펙터 채널 스트립", "[Left Inspector", "[Right Inspector", "[믹서", "[Mixer", "[ミキサー")),
    ("library.patches",       ("[라이브러리", "[Library", "[ライブラリ", "[Bibliothek")),
    # Regions BEFORE headers: a region's path passes through a layout area described "N개의 ‘name’ 트랙",
    # which the headers marker would otherwise claim. First match wins, so the more specific goes first.
    ("arrange.regions",       ("[트랙 콘텐츠", "[Track Content", "[Tracks contents", "[トラックコンテンツ",
                               "[Spuren enthält")),
    ("arrange.track_headers", ("[트랙 헤더", "[Track Header", "[트랙 헤더 목록", "’ 트랙]", "' Track]",
                               "[トラックヘッダ")),
]

# The ja-JP spellings above were read out of a ja-JP census, not translated: `[コントロールバー`,
# `[ミキサー`, `[ライブラリ`, `[トラックコンテンツ`, `[トラックヘッダ`, each with the same row counts
# as its en-US counterpart. Without them every window row in Japanese fell through — 414 of 617 —
# so a locale campaign produced ONE surface in Japanese and six in English, and the ledger recorded
# that asymmetry as if it were something about Logic rather than about this list.
#
# The de-DE spellings were read the same way, off the census of 2026-09-12 (#876): `[Steuerungsleiste`,
# `[Bibliothek`, `[Spuren enthält`. `[Mixer` needed nothing — German keeps the English word there.
#
# `[Spuren Titel` was tried here and REMOVED. It is the counterpart of `[Tracks header`, which
# appears 230 times in both censuses and is deliberately not a marker on either side — English
# reaches those 38 rows through the help text instead. Adding it in German only would have filed
# 230 German rows against 38 English ones and made the per-locale counts incomparable, which is the
# same trap `[インスペクタ` is held out of below. Without them a German campaign produced THREE surfaces against English's six, with 447
# rows unclassified, and the ledger would have recorded that as a fact about German Logic rather than
# about this list — exactly the asymmetry the Japanese note below describes.
#
# `[インスペクタ` is deliberately absent. It is the exact counterpart of `[Inspector` (99 rows in
# both censuses), and `[Inspector` is not here either — adding it on one side only would make the
# Japanese taxonomy richer than the English one and the per-locale counts incomparable.


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
    # German spells the same help string `Spur-Header.`, which contains neither of the two above.
    # Read off the de-DE census of 2026-09-12: 38 rows carry it, the same count as the en-US
    # `Track Header` rows, which is what makes the two locales' taxonomies comparable.
    if ("트랙 헤더" in help_ or "track header" in help_.lower()
            or "spur-header" in help_.lower()):
        return "arrange.track_headers"
    return None


def missing_release(host):
    """Why this host block cannot say which Logic the census was read on, or None when it can.

    A record that does not name its Logic version AND build is a reading of an unknown release, and the
    ledger counts a reading by the release it describes. Refused here, at the source, rather than filed
    and caught later: `?` is what the probe writes when it cannot read the application's Info.plist.
    """
    for axis in ("version", "build"):
        value = str((host or {}).get(axis) or "").strip()
        if value in ("", "?", "unknown"):
            return f"the census host carries no Logic {axis} ({value or 'empty'!r})"
    return None


# --------------------------------------------------------------------------------------------------
# THE CANON AXIS
# --------------------------------------------------------------------------------------------------
# A record joining the tree states facts about Logic, so `check-canon-citations.py` wants each of them
# CITED to Apple's bytes or PROVED absent from them (docs/canon/README.md). A census record states
# nothing but strings, so the generator accounts for every distinct string it files:
#
#   ships        a whole value of some pinned corpus      -> a `logic-canon://<source>/<locale>#value`
#                                                            citation carrying the string verbatim
#   absent       a value of no corpus and no near miss    -> one `canon_absent` proof over every corpus
#                                                            the manifest pins (project content, numbers)
#   near miss    absent as bytes, but a shipped label     -> filed under neither: a proof would be
#                folds to it (a colon, an ellipsis)          refused, and the shipped spelling is not
#                                                            something this census read. Named in `limits`
#   unconfirmed  its 32-bit prefix is in a corpus and no  -> REFUSED. Whether it ships is a string
#                string comparison is pinned                 comparison on a machine with Logic, and the
#                                                            generator does not guess it
#
# The citations are pinned by `Scripts/logic_canon.py build`, which reads the citations out of the
# records, and the unconfirmed ones are settled by `logic_canon.py confirm --stdin`. Neither runs here.

def _load_canon():
    path = os.path.join(os.path.dirname(os.path.dirname(HERE)), "Scripts", "logic_canon.py")
    spec = importlib.util.spec_from_file_location("logic_canon_for_census_records", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclass-style modules want to find themselves
    spec.loader.exec_module(module)
    return module


def _locale_preference(host_locale):
    """Corpus locales to cite from, best first, for a census taken in `host_locale`."""
    full = host_locale.replace("-", "_")
    return [full, full.split("_")[0], "en", "-"]


def account_for_strings(strings, host_locale, canon):
    """Sort every string into citations, absences, near misses and unconfirmed ones.

    Returns `(citations, absent, near, unconfirmed, corpora)`. `citations` is `[(ref, string)]` in
    string order. Everything is decided from the committed canon (`canon.presence`), so it runs with
    no Logic; a string the committed canon cannot decide comes back in `unconfirmed`.
    """
    manifest = canon.load_manifest()
    corpora = sorted((source, locale) for source, block in (manifest.get("sources") or {}).items()
                     for locale in (block.get("locales") or []))
    prefer = _locale_preference(host_locale)
    citations, absent, near, unconfirmed = [], [], [], []
    for text in strings:
        # An ASCII string is cited from English: the host locale's file may hold it only as the
        # untranslated English copy, which `check-canon-citations` refuses as "not localized".
        order = (["en"] + [p for p in prefer if p != "en"]) if text.isascii() else prefer
        rank = {locale: i for i, locale in enumerate(order)}
        verdicts = [(source, locale, canon.presence(source, locale, text)) for source, locale in corpora]
        shipped = [(rank.get(locale, len(order)), locale, source)
                   for source, locale, verdict in verdicts if verdict == canon.SHIPS]
        if shipped:
            _rank, locale, source = min(shipped)
            # Joined, not one f-string: `build` scans every file under Scripts/ for the scheme, and a
            # braced scheme literal here is read as a malformed citation.
            citations.append(("logic-canon://" + f"{source}/{locale}#value", text))
        elif any(verdict == canon.UNCONFIRMED for _s, _l, verdict in verdicts):
            unconfirmed.append(text)
        elif any(canon.differs_only_by_decoration(source, locale, text) for source, locale in corpora):
            near.append(text)
        else:
            absent.append(text)
    return citations, absent, near, unconfirmed, corpora


def canon_blocks(strings, host_locale, canon):
    """`(fields, near, unconfirmed)`: the record keys that carry the canon axis, ready to merge."""
    citations, absent, near, unconfirmed, corpora = account_for_strings(strings, host_locale, canon)
    fields = {"canon": [
        {"ref": ref, "value": text,
         "used_for": "a label this surface exposes to AX, read verbatim from the census; cited so the "
                     "string is Apple's and not one that was typed",
         "binding": {"kind": "record"}}
        for ref, text in citations]}
    if absent:
        fields["canon_absent"] = [{
            "claim": f"{len(absent)} strings this surface exposes are a whole value of no corpus the "
                     f"canon pins, and no shipped label folds to them",
            "strings": absent,
            "searched": [{"source": source, "locale": locale} for source, locale in corpora],
            "why_runtime": "Apple's bytes hold none of them, so the only route to each is the census "
                           "reading itself: they are project content, numbers and runtime text",
        }]
    return fields, near, unconfirmed


def main(census_path, repo, write, date=None, canon=None):
    census = json.load(open(census_path, encoding="utf-8"))
    host = census["host"]
    locale = host["locale"]
    if locale == "unknown":
        print("census locale is unknown — refusing to file records that cannot say what they are true of")
        return 2
    why = missing_release(host)
    if why:
        print(f"{why} — refusing to file records that cannot say which Logic they are true of")
        return 2
    date = date or datetime.date.today().isoformat()
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

    canon = canon or _load_canon()
    records = {}
    refused = []
    for surface, rows in sorted(buckets.items()):
        rid = f"{date}-{locale}-{surface.replace('.', '-')}-census"
        strings = sorted({v for r in rows for k in ("title", "description", "help", "value") if (v := r.get(k))})
        idents = sorted({r["identifier"] for r in rows if r.get("identifier")})
        canon_fields, near, unconfirmed = canon_blocks(strings, locale, canon)
        if unconfirmed:
            refused.append((rid, unconfirmed))
        records[rid] = {
            "id": rid, "date": date, "schema": 3,
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
            **canon_fields,
        }
        if near:
            records[rid]["limits"].append(
                f"{len(near)} strings are neither cited nor proved absent: each is absent from Apple's "
                f"corpora as bytes and a shipped label folds to it (a colon, an ellipsis, a case), so "
                f"the spelling Logic ships is not something this census read: "
                + "; ".join(near))

    if refused:
        for rid, texts in refused:
            print(f"{rid}: {len(texts)} string(s) the committed canon cannot place")
        print("REFUSED: a string whose 32-bit prefix is in a corpus is neither shipped nor absent until a "
              "string comparison is pinned. On a machine with Logic, read-only:\n"
              "  python3 Scripts/logic_canon.py confirm --stdin < strings.txt\n"
              "then file the records again. Nothing was written.")
        return 2
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
