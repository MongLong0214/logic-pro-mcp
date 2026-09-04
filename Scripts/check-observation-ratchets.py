#!/usr/bin/env python3
"""What the ledger does not yet know may only shrink.

`docs/observations/RATCHETS.json` holds a ceiling for every kind of gap the observation system can
count. This guard computes each gap from the tree and compares:

    live > ceiling   -> fail, unless RATCHETS.json carries a dated reason under `raised`
    live < ceiling   -> fail, with the number to lower it to — a ceiling that lags reality lets the
                        next regression hide under it
    live == ceiling  -> pass

The numbers used to live as constants inside individual guards (`TOTAL_VARIANT_CEILING = 257`),
which is where a ratchet becomes invisible to the person deciding whether to move it. One file, one
diff, one place a reviewer looks. ADR-019 D8.

The gaps, and where each is read from:

    undocumented_variants      docs/locale/ui-labels.json  variants without a `provenance` block
    unmeasured_coverage[loc]   docs/locale/ui-labels.json  coverage[loc] == "unmeasured"
    schema_v1_records          docs/observations/*.json    records without "schema": 2
    manual_reverify            docs/observations/*.json    reverify.kind == "manual"
    surfaces_without_records   SURFACES.md vs records      surfaces no record names

Exit 0 when every count equals its ceiling, 1 otherwise, 2 if an input cannot be read.
"""
import glob
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RATCHETS = os.path.join(REPO, "docs", "observations", "RATCHETS.json")
LABELS = os.path.join(REPO, "docs", "locale", "ui-labels.json")
OBS = os.path.join(REPO, "docs", "observations")
SURFACES = os.path.join(OBS, "SURFACES.md")


def live_counts(repo=REPO):
    """Every gap the ledger can count, computed from the tree. Raises on unreadable input."""
    labels = json.load(open(os.path.join(repo, "docs", "locale", "ui-labels.json"), encoding="utf-8"))
    entries = labels.get("labels") or {}
    locales = tuple(labels.get("supported_locales") or ())
    undocumented = 0
    unmeasured = {loc: 0 for loc in locales}
    for entry in entries.values():
        prov = entry.get("provenance") or {}
        undocumented += sum(1 for v in (entry.get("variants") or []) if v not in prov)
        for loc in locales:
            if (entry.get("coverage") or {}).get(loc, "unmeasured") == "unmeasured":
                unmeasured[loc] += 1

    obs_dir = os.path.join(repo, "docs", "observations")
    # A record is a date-prefixed file, which is what the schema guard requires of one; that rule
    # rather than a name special-case, so a second non-record file beside them is not a regression.
    records = [json.load(open(path, encoding="utf-8"))
               for path in sorted(glob.glob(os.path.join(obs_dir, "*.json")))
               if re.match(r"^\d{4}-\d{2}-\d{2}-.*\.json$", os.path.basename(path))]
    schema_v1 = sum(1 for r in records if r.get("schema", 1) != 2)
    manual = sum(1 for r in records if (r.get("reverify") or {}).get("kind") == "manual")

    surfaces = re.findall(r"\|\s*`([a-z_]+\.[a-z_]+)`", open(os.path.join(obs_dir, "SURFACES.md"), encoding="utf-8").read())
    covered = {r.get("surface") for r in records}
    bare = sum(1 for s in surfaces if s not in covered)

    return {
        "undocumented_variants": undocumented,
        "unmeasured_coverage": unmeasured,
        "schema_v1_records": schema_v1,
        "manual_reverify": manual,
        "surfaces_without_records": bare,
    }


def _flatten(d, prefix=""):
    for k, v in d.items():
        if isinstance(v, dict):
            yield from _flatten(v, f"{prefix}{k}.")
        else:
            yield f"{prefix}{k}", v


def compare(live, ratchets):
    """(rises, lowerable, missing): each a list of (key, live, ceiling[, reason])."""
    ceilings = dict(_flatten(ratchets.get("ceilings") or {}))
    raised = ratchets.get("raised") or {}
    rises, lowerable, missing = [], [], []
    for key, value in _flatten(live):
        if key not in ceilings:
            missing.append((key, value))
            continue
        ceiling = ceilings[key]
        if value > ceiling:
            entry = raised.get(key) or {}
            ok = bool(str(entry.get("reason") or "").strip()) and \
                re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(entry.get("date") or "")) is not None
            rises.append((key, value, ceiling, entry if ok else None))
        elif value < ceiling:
            lowerable.append((key, value, ceiling))
    return rises, lowerable, missing


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    repo = os.path.abspath(argv[0]) if argv else REPO
    try:
        ratchets = json.load(open(os.path.join(repo, "docs", "observations", "RATCHETS.json"), encoding="utf-8"))
        live = live_counts(repo)
    except (OSError, ValueError) as exc:
        print(f"could not read the ledger, so the ratchets cannot be checked: {exc}")
        return 2

    rises, lowerable, missing = compare(live, ratchets)
    failed = False
    for key, value in missing:
        print(f"{key}: live count {value} has no ceiling in RATCHETS.json — add one, or the gap is uncounted")
        failed = True
    for key, value, ceiling, entry in rises:
        if entry is None:
            print(f"{key}: {value}, above the ceiling of {ceiling}. What the ledger does not know grew.")
            print(f"  Either close the gap, or record why under `raised.{key}` with a date and a reason.")
            failed = True
        else:
            print(f"{key}: {value} above {ceiling}, raised {entry['date']}: {entry['reason']}")
            print(f"  Move the ceiling to {value} and clear the `raised` entry in the same commit.")
            failed = True
    for key, value, ceiling in lowerable:
        print(f"{key}: {value}, better than the ceiling of {ceiling} — lower it to {value} so the "
              f"next regression cannot hide under the old number.")
        failed = True
    if failed:
        return 1
    print("every ledger gap equals its ceiling: " + ", ".join(f"{k}={v}" for k, v in _flatten(live)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
