#!/usr/bin/env python3
"""Prove `Scripts/check-observation-ratchets.py` can fail, in every direction it judges.

A ratchet that only ever passes is a number nobody reads. Each case below builds a small tree —
a labels JSON, a few records, a SURFACES table and a RATCHETS.json — and requires a specific
verdict. The cases that matter most are the two the guard must NOT confuse: a count that ROSE
(the ledger forgot something) and a count that FELL (the ceiling now lags reality). Both fail;
they fail for opposite reasons and the message has to say which.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

GUARD = Path(__file__).resolve().parent / "check-observation-ratchets.py"
spec = importlib.util.spec_from_file_location("ratchet_guard", GUARD)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

LOCALES = ["en-US", "ko-KR", "ja-JP"]


def _record(rid, locale="ko-KR", surface="arrange.regions", schema=None, kind="script"):
    d = {"id": rid, "surface": surface, "host": {"locale": locale},
         "reverify": {"kind": kind}, "verdict": "works"}
    if schema:
        d["schema"] = schema
    return d


def _tree(labels, records, ceilings, raised=None, surfaces=("arrange.regions", "mixer.inserts")):
    """Write a throwaway repo and return its root."""
    tmp = tempfile.mkdtemp()
    root = Path(tmp)
    (root / "docs" / "locale").mkdir(parents=True)
    (root / "docs" / "observations").mkdir(parents=True)
    (root / "docs" / "locale" / "ui-labels.json").write_text(json.dumps({
        "schema": 2, "supported_locales": LOCALES, "labels": labels}), encoding="utf-8")
    for r in records:
        (root / "docs" / "observations" / f"{r['id']}.json").write_text(json.dumps(r), encoding="utf-8")
    (root / "docs" / "observations" / "SURFACES.md").write_text(
        "| surface | what |\n|---|---|\n" + "".join(f"| `{s}` | x |\n" for s in surfaces), encoding="utf-8")
    (root / "docs" / "observations" / "RATCHETS.json").write_text(json.dumps({
        "schema": 1, "ceilings": ceilings, "raised": raised or {}}), encoding="utf-8")
    return root


def _label(variants, provenance=None, coverage=None):
    e = {"canonical": "x", "variants": variants, "rationale": "r"}
    if provenance:
        e["provenance"] = provenance
    e["coverage"] = coverage or {loc: "unmeasured" for loc in LOCALES}
    return e


def main():
    failures = []

    def check(name, cond, detail):
        if not cond:
            failures.append(f"{name}: {detail}")

    # A baseline tree: 2 variants, one documented; 2 records, one schema 2, one manual; 1 bare surface.
    prov = {"a": {"locale": "ko-KR", "date": "2026-09-05", "observed": "a", "record": "2026-09-05-r1"}}
    labels = {"L": _label(["a", "b"], prov, {"en-US": "unmeasured", "ko-KR": "present", "ja-JP": "unmeasured"})}
    records = [_record("2026-09-05-r1", schema=2), _record("2026-09-05-r2", kind="manual")]
    exact = {"undocumented_variants": 1,
             "unmeasured_coverage": {"en-US": 1, "ko-KR": 0, "ja-JP": 1},
             "schema_v1_records": 1, "manual_reverify": 1, "surfaces_without_records": 1}

    # 1. Live equals ceilings: pass.
    root = _tree(labels, records, exact)
    check("equal passes", guard.main([str(root)]) == 0, "expected exit 0 at exact ceilings")

    # 2. The live counts are what the guard says they are (its own arithmetic, checked once).
    live = guard.live_counts(str(root))
    check("counts", live == exact, f"live_counts returned {live}")

    # 3. A RISE fails and says so — a second undocumented variant appears.
    labels2 = {"L": _label(["a", "b", "c"], prov, labels["L"]["coverage"])}
    root = _tree(labels2, records, exact)
    check("rise fails", guard.main([str(root)]) == 1, "an undocumented variant was added and the guard passed")

    # 4. A rise with a dated reason under `raised` STILL fails, but names the reason and asks for
    #    the ceiling to be moved — a raise is a decision in the diff, not a silent pass.
    root = _tree(labels2, records, exact,
                 raised={"undocumented_variants": {"date": "2026-09-05", "reason": "three new leaves"}})
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    check("raised is not a pass", proc.returncode == 1, f"exit {proc.returncode}")
    check("raised names its reason", "three new leaves" in proc.stdout, proc.stdout[:200])

    # 5. A raise without a date is NOT a reason.
    root = _tree(labels2, records, exact,
                 raised={"undocumented_variants": {"reason": "because"}})
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    check("undated raise is refused", "record why" in proc.stdout, proc.stdout[:200])

    # 6. A count that FELL fails too, with the number to lower the ceiling to.
    better = dict(exact, undocumented_variants=5)
    root = _tree(labels, records, better)
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    check("lag fails", proc.returncode == 1, f"exit {proc.returncode}")
    check("lag names the number", "lower it to 1" in proc.stdout, proc.stdout[:200])

    # 7. A gap with no ceiling at all is reported, not ignored — an uncounted gap is the worst kind.
    partial = {k: v for k, v in exact.items() if k != "manual_reverify"}
    root = _tree(labels, records, partial)
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    check("missing ceiling fails", proc.returncode == 1 and "no ceiling" in proc.stdout, proc.stdout[:200])

    # 8. RATCHETS.json beside the records is not itself counted as a record. If it were, every
    #    tree would report one more schema-1 record than it has.
    check("ratchets file is not a record", live["schema_v1_records"] == 1,
          f"schema_v1_records={live['schema_v1_records']}, RATCHETS.json was counted")

    # 9. An unreadable ledger is exit 2, never a pass.
    root = _tree(labels, records, exact)
    (root / "docs" / "observations" / "RATCHETS.json").write_text("{not json", encoding="utf-8")
    check("unreadable is exit 2", guard.main([str(root)]) == 2, "expected exit 2")

    # 10. The real repository is at its ceilings right now.
    proc = subprocess.run([sys.executable, str(GUARD)], capture_output=True, text=True)
    check("repository is at its ceilings", proc.returncode == 0, proc.stdout.strip()[:200])

    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print("10 case(s) pass: the ratchet fails on a rise, on a lag, on a missing ceiling, and on what it cannot read")
    return 0


if __name__ == "__main__":
    sys.exit(main())
