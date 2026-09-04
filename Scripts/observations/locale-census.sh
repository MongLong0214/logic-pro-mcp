#!/bin/bash
# Re-run the census behind a locale's navigation-free records and say whether Logic still shows
# the same strings. ADR-019 D7 contract: exit 0 the records still hold, 1 they do not, 2 a
# precondition was not met (Logic not running, wrong locale, no record to compare against).
#
#   Scripts/observations/locale-census.sh <locale>            # e.g. ko-KR
#   Scripts/observations/locale-census.sh <locale> --dump     # also print the fresh census path
#
# It reads and never actuates. Disagreement is reported per surface with the strings that appeared
# and disappeared, because "the labels moved" is only actionable if it says which.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
LOCALE="${1:-}"
[ -n "$LOCALE" ] || { echo "usage: $0 <locale> [--dump]"; exit 2; }
BIN="${TMPDIR:-/tmp}/lpm-locale-census-$$"
FRESH="${TMPDIR:-/tmp}/lpm-locale-census-$$.json"
trap 'rm -f "$BIN" "$FRESH"' EXIT

swiftc -O "$HERE/locale-census.swift" -o "$BIN" 2>/dev/null || { echo "cannot compile the census probe"; exit 2; }
"$BIN" > "$FRESH" 2>/dev/null || { echo "census failed — is Logic Pro running?"; exit 2; }

python3 - "$REPO" "$LOCALE" "$FRESH" "${2:-}" <<'PY'
import json, glob, os, sys
repo, want, fresh_path, flag = sys.argv[1:5]
fresh = json.load(open(fresh_path, encoding="utf-8"))
got = fresh["host"]["locale"]
if got != want:
    print(f"PRECONDITION: the running Logic is in {got!r}, not {want!r} — switch it and relaunch first")
    sys.exit(2)
if flag == "--dump":
    print(f"fresh census: {fresh_path}")
obs = os.path.join(repo, "docs", "observations")
# The newest census record per surface for this locale, and the evidence file each cites.
records = {}
for p in sorted(glob.glob(os.path.join(obs, "*-census.json"))):
    d = json.load(open(p, encoding="utf-8"))
    if (d.get("host") or {}).get("locale") == want and d.get("evidence"):
        records[d["surface"]] = d
if not records:
    print(f"PRECONDITION: no census record for {want} to compare against — run the campaign first")
    sys.exit(2)

sys.path.insert(0, os.path.join(repo, "Scripts", "observations"))
from locale_campaign_records import classify  # the same routing the records were filed with

def strings(rows):
    return {v for r in rows for k in ("title", "description", "help", "value") if (v := r.get(k))}

fresh_by = {}
for row in fresh["census"]:
    s = classify(row)
    if s:
        fresh_by.setdefault(s, []).append(row)

disagree = 0
for surface, rec in sorted(records.items()):
    ev = json.load(open(os.path.join(obs, rec["evidence"][0]), encoding="utf-8"))
    then = strings(r for r in ev["census"] if classify(r) == surface)
    now = strings(fresh_by.get(surface, []))
    gone, new = sorted(then - now), sorted(now - then)
    if gone or new:
        disagree += 1
        print(f"DISAGREES {surface}: {len(gone)} string(s) gone, {len(new)} new")
        for s_ in gone[:6]: print(f"    - {s_[:80]}")
        for s_ in new[:6]:  print(f"    + {s_[:80]}")
    else:
        print(f"agrees   {surface}: {len(now)} strings unchanged")
sys.exit(1 if disagree else 0)
PY
