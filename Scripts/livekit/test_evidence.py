#!/usr/bin/env python3
"""Prove `is_clean` and `_safe_name` against the things they are supposed to refuse.

`is_clean` decides whether a live run may be reported as passing, and nothing exercised it. Its
whole failure mode is the quiet one: a clause that looks strict and is satisfied by a run that
never did the thing. So the cases below are mostly runs that DID NOTHING, in the several shapes
that used to come back clean.

    python3 test_evidence.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402

# A complete, honest summary: one check that names a mutation, one driven operation, one capture,
# one visual with a subject, one recording, nothing gone wrong.
GOOD = {
    "checks": 1, "passed": 1, "mutation_backed": 1, "operations_driven": 1,
    "captures": 1, "captures_unsettled": 0, "captures_straddling_displays": 0,
    "restorations_failed": 0, "cached_reads_used_as_live": 0,
    "visual_assertions": 1, "visual_failed": 0, "visual_assertions_without_a_subject": 0,
    "recordings": 1,
}

CASES = [
    (True, GOOD, "a complete run with nothing wrong"),
    # The vacuous zeros. Each of these satisfies every `== 0` clause by never doing the thing.
    (False, {**GOOD, "visual_assertions": 0},
     "no visual at all — the cheapest way to have no subjectless visual"),
    (False, {**GOOD, "captures": 0}, "no capture — nothing was unsettled because nothing was shot"),
    (False, {**GOOD, "recordings": 0}, "no screen recording"),
    (False, {**GOOD, "operations_driven": 0}, "never called the product"),
    (False, {**GOOD, "mutation_backed": 0}, "no check names a mutation"),
    (False, {**GOOD, "checks": 0, "passed": 0}, "no checks"),
    # Absence must never be clean, for EVERY key — the polarity used to depend on which one.
    *[(False, {k: v for k, v in GOOD.items() if k != key}, f"summary missing {key!r}")
      for key in E._REQUIRED_SUMMARY_KEYS],
    # And the ordinary failures.
    (False, {**GOOD, "checks": 2, "passed": 1}, "a red check"),
    (False, {**GOOD, "visual_failed": 1}, "a failed visual assertion"),
    (False, {**GOOD, "captures_unsettled": 1}, "an unsettled capture"),
    (False, {**GOOD, "captures_straddling_displays": 1}, "a capture across two displays"),
    (False, {**GOOD, "restorations_failed": 1}, "a restoration that did not happen"),
    (False, {**GOOD, "cached_reads_used_as_live": 1}, "a cached read presented as live"),
    # Counted, not gated — see is_clean's docstring. This case asserts the CURRENT contract, so it
    # is the one to flip when the harnesses have adopted `subject=`.
    (True, {**GOOD, "visual_assertions_without_a_subject": 1},
     "a visual that names no subject: counted, not yet refused"),
    (False, None, "not a summary at all"),
]

failed = 0
for expected, summary, why in CASES:
    got = E.is_clean(summary)
    ok = got is expected
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} is_clean -> {got!s:<5} expected {expected!s:<5} {why}")

# A subject has to be a non-empty STRING; truthy is not a name.
#
# Through the REAL `_summary`, not a copy of its predicate. The first version of this block
# reimplemented the rule inline and so agreed with itself no matter what evidence.py said — loosening
# the real one back to `not v.get("subject")` left this passing.
class _Records:
    def __init__(self, records):
        self.records = records


def subjectless(value):
    vis = [{"kind": "visual", "passed": True, "region": (0, 0, 1, 1), "subject": value}]
    return E.Evidence._summary(_Records(vis), "x")["visual_assertions_without_a_subject"]


for value, should_count in [("the control bar strip", 0), ("", 1), ("   ", 1),
                            (True, 1), ({"a": 1}, 1), (None, 1)]:
    n = subjectless(value)
    ok = n == should_count
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} subject={value!r:<24} counted-as-missing={n} expected {should_count}")

# --- #619: the document name is a PATH COMPONENT -----------------------------------------------
#
# `name` used to live only inside the JSON. Once it became part of a filename, an unconstrained
# value escaped the head directory: Evidence(..., name="../escaped") wrote into the evidence ROOT,
# where the gate never looks and nothing notices. The reason is in `_safe_name`'s docstring; this is
# the part that fails when someone simplifies it away.
#
# What this DOES and DOES NOT demonstrate, measured by mutating evidence.py and re-running:
#
#   remove `os.path.basename`          NOT caught — the regex already rewrites "/" to "_"
#   let the regex keep "/"             NOT caught — basename already strips the directory
#   remove BOTH                        caught, six cases: "../escaped" lands outside the head dir
#
# So neither sanitiser is individually load-bearing; they cover each other completely, and no test
# can show either one earning its place. That is worth saying rather than leaving as an implied
# "both are guarded". What is asserted below is the PROPERTY — whatever a caller passes, the
# document is a single component inside the head directory — which is the thing #619 is about.
HEAD_DIR = "/evidence/abc123"
for raw, why in [
    ("../escaped", "parent traversal"),
    ("../../../../etc/passwd", "deep traversal"),
    ("/etc/passwd", "absolute path"),
    ("a/b/c", "nested path"),
    ("..", "bare parent"),
    ("...", "leading dots only"),
    (".hidden", "leading dot"),
    ("", "empty"),
    ("   ", "whitespace only"),
    (None, "not a string"),
    ("x" * 500, "absurdly long"),
    ("na/me;rm -rf$(x)`y`", "shell metacharacters"),
]:
    stem = E._safe_name(raw)
    landed = os.path.normpath(os.path.join(HEAD_DIR, f"{stem}.evidence.json"))
    inside = os.path.dirname(landed) == HEAD_DIR
    single = stem and os.path.basename(stem) == stem and stem not in (".", "..")
    bounded = len(stem) <= 80
    ok = bool(inside and single and bounded)
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} name={str(raw)[:28]!r:<32} -> {stem[:28]!r:<30} {why}")

print(f"\n{'FAILED' if failed else 'all cases behaved'} ({failed} unexpected)")
sys.exit(1 if failed else 0)
