#!/usr/bin/env python3
"""Prove the #612 coverage rule against the cases it exists to refuse.

The defect it answers is a quiet one: a branch carrying two harnesses, one document on disk, and a
gate that reports `ok`. So the cases below are mostly runs where SOMETHING is present — the failure
never looked like an absence.

    python3 test_harness_evidence_coverage.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness_evidence_coverage as C  # noqa: E402

failed = 0

# --- which paths count as a changed harness ----------------------------------------------------
#
# `Scripts/livekit/` and nothing else. A `live_*.py` elsewhere in the tree is not a live harness,
# and `evidence.py` beside them is not one either — the rule is the directory plus the prefix, and
# both halves are asserted so neither can be dropped without a case going red.
for paths, expected, why in [
    (["Scripts/livekit/live_544_output_schema.py"], {"live_544_output_schema"}, "one harness"),
    (["Scripts/livekit/live_a.py", "Scripts/livekit/live_b.py"], {"live_a", "live_b"}, "two"),
    (["Scripts/livekit/evidence.py"], set(), "the library beside them is not a harness"),
    (["Scripts/livekit/session_519_locale_flow.py"], set(), "a session script is not a harness"),
    (["Tests/live_thing.py"], set(), "live_ prefix outside the directory"),
    (["Scripts/live_544.py"], set(), "one directory up is not the directory"),
    (["Sources/LogicProMCP/Server/LogicProTarget.swift"], set(), "product code names no harness"),
    ([], set(), "nothing changed"),
    (None, set(), "no diff at all"),
]:
    got = C.harness_stems(paths)
    ok = got == expected
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {str(paths)[:52]:<54} -> {sorted(got)} {why}")

# --- the verdict --------------------------------------------------------------------------------
#
# Through the REAL `E.summarize` and `E.is_clean`, not a copy of the predicate: a test that
# reimplements the rule agrees with itself no matter what the code says.
CLEAN = {"records": [
    {"kind": "check", "passed": True, "mutation_flips": True},
    {"kind": "capture", "settled": True, "display": {"wholly_within": True}},
    {"kind": "visual", "passed": True, "subject": "Tracks header", "region": [0, 0, 1, 1]},
    {"kind": "recording"},
    {"kind": "operation"},
]}
# A visual that FAILED, which `is_clean` has always refused. Deliberately not a subject-less one:
# that clause is newer, and a case here that depends on it would make this file's verdict a
# statement about which other change has landed rather than about this rule.
UNCLEAN = {"records": [dict(r) for r in CLEAN["records"]]}
UNCLEAN["records"][2] = {"kind": "visual", "passed": False, "subject": "Tracks header",
                         "region": [0, 0, 1, 1]}

DOCS = {
    "/e/live_a.evidence.json": CLEAN,
    "/e/live_b.evidence.json": UNCLEAN,
    "/e/live_broken.evidence.json": None,      # on disk, unreadable
}
PRESENT = {
    "live_a": "/e/live_a.evidence.json",
    "live_b": "/e/live_b.evidence.json",
    "live_broken": "/e/live_broken.evidence.json",
}

for required, present, exp_missing, exp_unclean, why in [
    ({"live_a"}, PRESENT, [], [], "one harness, its own clean document"),
    ({"live_a", "live_b"}, PRESENT, [], ["live_b"], "the second document is not clean"),
    # THE defect: two harnesses changed, one document on disk. Before #612 the gate read a single
    # file per head and called this covered.
    ({"live_a", "live_c"}, {"live_a": "/e/live_a.evidence.json"}, ["live_c"], [],
     "two changed, one proved — the case this check exists for"),
    ({"live_broken"}, PRESENT, [], ["live_broken"],
     "unreadable is UNCLEAN, not missing — it ran and produced something unusable"),
    ({"live_a"}, {}, ["live_a"], [], "nothing on disk at all"),
    (set(), PRESENT, [], [], "no harness changed, nothing required"),
]:
    missing, unclean = C.verdict(required, present, read_document=lambda p: DOCS.get(p))
    ok = missing == exp_missing and unclean == exp_unclean
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} required={sorted(required)!s:<28} "
          f"missing={missing} unclean={unclean}  {why}")

# --- `evidence.json` must not satisfy anything --------------------------------------------------
#
# The legacy single-file name is the last run at this head whatever wrote it. Counting it would let
# one harness's document stand in for another's, which is the whole defect wearing a new name.
#
# Against a REAL directory. The first version of this block asserted on `documents_present`'s
# DOCSTRING and then drove `verdict` with a hand-built dict — so widening the glob to `*.json` left
# the whole suite green, which is the mutation this case exists to catch. A test that never calls
# the function cannot see what the function does.
import tempfile

with tempfile.TemporaryDirectory() as head_dir:
    for name in ["live_a.evidence.json",       # a harness document
                 "evidence.json",              # the legacy last-run-wins name
                 "live_a.evidence.1.json",     # a ROTATED earlier run of live_a
                 "notes.json"]:                # something else entirely
        open(os.path.join(head_dir, name), "w").write("{}")
    found = C.documents_present(head_dir)
    ok = set(found) == {"live_a"}
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} a real directory yields {sorted(found)} "
          f"— not the legacy name, not a rotated run, not an unrelated file")

got = C.verdict({"live_a"}, {"evidence": "/e/evidence.json"}, read_document=lambda p: CLEAN)
ok = got == (["live_a"], [])
failed += 0 if ok else 1
print(f"{'ok  ' if ok else 'FAIL'} a document named `evidence` satisfies no harness -> {got}")

print()
print(f"FAILED ({failed} unexpected)" if failed else "all cases behaved (0 unexpected)")
sys.exit(1 if failed else 0)
