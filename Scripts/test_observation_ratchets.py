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


def _tree(labels, records, allowed, raised=None, surfaces=("arrange.regions", "mixer.inserts"), git_init=False):
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
        "schema": 2, "allowed": allowed, "raised": raised or {}}), encoding="utf-8")
    if git_init:
        # A real repository, so `git merge-base` has something to compute. The seam is fine for the
        # set arithmetic; it cannot show that the git path works, and naming a case after an
        # integration it never runs is how a test comes to promise more than it checks.
        for cmd in (["init", "-q", "-b", "base"], ["add", "-A"], ["-c", "user.email=t@t", "-c", "user.name=t",
                                                    "commit", "-qm", "base"]):
            subprocess.run(["git", "-C", str(root), *cmd], capture_output=True)
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

    prov = {"a": {"locale": "ko-KR", "date": "2026-09-05", "observed": "a", "record": "2026-09-05-r1",
                  "role": "AXMenuItem", "attribute": "title"}}
    labels = {"L": _label(["a", "b"], prov, {"en-US": "unmeasured", "ko-KR": "measured", "ja-JP": "unmeasured"})}
    records = [_record("2026-09-05-r1", schema=2), _record("2026-09-05-r2", kind="manual")]
    exact = {
        "undocumented_variants": ["L\u2192b"],
        "unmeasured_coverage": {"en-US": ["L"], "ko-KR": [], "ja-JP": ["L"]},
        "schema_v1_records": ["2026-09-05-r2"],
        "manual_reverify": ["2026-09-05-r2"],
        "surfaces_without_records": sorted(
            f"{loc}\u2192{s_}" for loc in ("en-US", "ko-KR", "ja-JP")
            for s_ in ("arrange.regions", "mixer.inserts")
            if not (loc == "ko-KR" and s_ == "arrange.regions")),
    }

    # 1. Live equals the allowed sets: pass.
    root = _tree(labels, records, exact)
    check("equal passes", guard.main([str(root)]) == 0, "expected exit 0 at the seeded sets")

    # 2. The live sets are what the guard says they are.
    live = {k: (sorted(v) if not isinstance(v, dict) else {kk: sorted(vv) for kk, vv in v.items()})
            for k, v in guard.live_state(str(root)).items()}
    check("state", live == exact, f"live_state returned {live}")

    # 3. THE SWAP. One undocumented variant appears and a different one gains provenance, so the
    #    COUNT is unchanged. A count-based ratchet passes this; a set-based one names the newcomer.
    labels_swap = {"L": _label(["a", "b", "c"], dict(prov, b={"locale": "ko-KR", "date": "2026-09-05",
                                                             "observed": "b", "record": "2026-09-05-r1",
                                                             "role": "AXMenuItem", "attribute": "title"}),
                               labels["L"]["coverage"])}
    root = _tree(labels_swap, records, exact)
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    check("swap is caught", proc.returncode == 1, f"exit {proc.returncode}")
    check("swap names the newcomer", "L\u2192c" in proc.stdout, proc.stdout[:300])
    check("the count was unchanged", len(guard.live_state(str(root))["undocumented_variants"]) == 1,
          "the fixture did not actually keep the count equal")

    # 4. A plain growth fails and names what appeared.
    labels2 = {"L": _label(["a", "b", "c"], prov, labels["L"]["coverage"])}
    root = _tree(labels2, records, exact)
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    check("growth fails", proc.returncode == 1 and "L\u2192c" in proc.stdout, proc.stdout[:200])

    # 5. A growth WITH a dated reason lands — otherwise `raised` is unusable, because the base can
    #    never acquire the new member without merging a failing change.
    root = _tree(labels2, records, exact,
                 raised={"undocumented_variants": {"date": "2026-09-05", "reason": "three new leaves"}})
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    check("raised lands", proc.returncode == 0, f"exit {proc.returncode}: {proc.stdout[:200]}")
    check("raised names its reason", "three new leaves" in proc.stdout, proc.stdout[:200])

    # 6. A raise without a date is not a reason.
    root = _tree(labels2, records, exact, raised={"undocumented_variants": {"reason": "because"}})
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    check("undated raise is refused", proc.returncode == 1 and "record why" in proc.stdout, proc.stdout[:200])

    # 7. A gap that CLOSED fails too, with the member to remove — a list that lags reality lets the
    #    next regression hide inside it.
    root = _tree(labels, records, dict(exact, undocumented_variants=["L\u2192b", "L\u2192gone"]))
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    check("lag fails", proc.returncode == 1 and "L\u2192gone" in proc.stdout, proc.stdout[:200])

    # 8. A gap with no allowed set at all is reported, not ignored.
    root = _tree(labels, records, {k: v for k, v in exact.items() if k != "manual_reverify"})
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    check("missing set fails", proc.returncode == 1 and "no allowed set" in proc.stdout, proc.stdout[:200])

    # 9. THE MERGE BASE, over real git. The branch adds a member AND adds it to its own file — the
    #    shape a union would permit. The base does not have it, and the base is authoritative.
    root = _tree(labels, records, exact, git_init=True)
    (root / "docs" / "locale" / "ui-labels.json").write_text(json.dumps({
        "schema": 2, "supported_locales": LOCALES, "labels": labels2}), encoding="utf-8")
    (root / "docs" / "observations" / "RATCHETS.json").write_text(json.dumps({
        "schema": 2, "allowed": dict(exact, undocumented_variants=["L\u2192b", "L\u2192c"]),
        "raised": {}}), encoding="utf-8")
    for cmd in (["checkout", "-qb", "branch"], ["add", "-A"],
                ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "raise"]):
        subprocess.run(["git", "-C", str(root), *cmd], capture_output=True)
    env = dict(os.environ, LPM_RATCHET_BASE_REF="base")
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True, env=env)
    check("same-commit raise is caught against the real merge base",
          proc.returncode == 1 and "L\u2192c" in proc.stdout, f"exit {proc.returncode}: {proc.stdout[:300]}")
    check("the base was actually consulted, not skipped", "base sets unreadable" not in proc.stdout,
          f"the guard fell back to the file: {proc.stdout[:200]}")

    # 10. A member the BASE already allowed is not a growth — which is what lets a branch drop it
    #     from its own file on the way to closing it.
    root = _tree(labels2, records, dict(exact, undocumented_variants=["L\u2192b", "L\u2192c"]), git_init=True)
    (root / "docs" / "observations" / "RATCHETS.json").write_text(json.dumps({
        "schema": 2, "allowed": exact, "raised": {}}), encoding="utf-8")
    for cmd in (["checkout", "-qb", "branch"], ["add", "-A"],
                ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "drop"]):
        subprocess.run(["git", "-C", str(root), *cmd], capture_output=True)
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True, env=env)
    check("base membership is honoured", "did not know it did not know" not in proc.stdout,
          f"a base-allowed member was reported as growth: {proc.stdout[:300]}")

    # 11. An unreadable base is said out loud and is not itself fatal.
    root = _tree(labels, records, exact)
    env2 = dict(os.environ, LPM_RATCHET_BASE_JSON=str(root / "missing.json"))
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True, env=env2)
    check("unreadable base is loud, not fatal", proc.returncode == 0 and "base sets unreadable" in proc.stdout,
          f"exit {proc.returncode}: {proc.stdout[:200]}")

    # 12. RATCHETS.json beside the records is not itself counted as one.
    check("ratchets file is not a record", guard.live_state(str(root))["schema_v1_records"] == {"2026-09-05-r2"},
          guard.live_state(str(root))["schema_v1_records"])

    # 13. An unreadable ledger is exit 2, never a pass.
    (root / "docs" / "observations" / "RATCHETS.json").write_text("{not json", encoding="utf-8")
    check("unreadable is exit 2", guard.main([str(root)]) == 2, "expected exit 2")

    # 14. The real repository is within its sets right now.
    proc = subprocess.run([sys.executable, str(GUARD)], capture_output=True, text=True)
    check("repository is clean", proc.returncode == 0, proc.stdout.strip()[:300])

    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print("18 case(s) pass: a swap is caught by name, a raise lands with a reason, and the base is real git")
    return 0


if __name__ == "__main__":
    sys.exit(main())
