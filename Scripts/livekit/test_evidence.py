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
    # Gated as of #622, once all thirty-one call sites named a subject. Flipped from the deferred
    # contract this case used to assert.
    (False, {**GOOD, "visual_assertions_without_a_subject": 1},
     "a visual that names no subject"),
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

# --- a band larger than its window is CLIPPED, and the record says what was hashed -------------
#
# `Tracks contents` is 6162 points wide on a 1920-point window: the arrange canvas extends past the
# viewport that draws it. `CGImageCreateWithImageInRect` intersects an oversized crop against the
# image and reports nothing, so the record claimed the whole canvas while the hash covered the
# visible strip — the number in the evidence was not the number that was measured.
#
# The case that matters most is the last one. A band entirely outside the window used to crop to
# nothing in BOTH captures, and two empty crops are equal, which is a PASS for every
# `expect_change=False` assertion. Unreadable has to stay unreadable.
WINDOW = (1920, 1050)
for region, expected, why in [
    ((10, 20, 100, 50), (10, 20, 100, 50), "wholly inside — untouched"),
    ((928, 162, 6162, 873), (928, 162, 992, 873), "wider than the window — clipped to the viewport"),
    ((0, 0, 1920, 1050), (0, 0, 1920, 1050), "exactly the window — untouched"),
    ((-40, -10, 200, 100), (0, 0, 160, 90), "starts off the top-left — clipped to the origin"),
    ((2000, 20, 100, 50), None, "wholly outside — unreadable, not an empty crop"),
    ((10, 20, 100, 50), (10, 20, 100, 50), "no window points is not a licence to clip"),
]:
    wp = None if why.startswith("no window points") else WINDOW
    got = E._clip_to_window(region, wp)
    ok = (got is None and expected is None) or (got is not None and tuple(got) == expected)
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {str(region):<26} -> {str(got):<22} {why}")

# --- what `located_band` puts in the DOCUMENT --------------------------------------------------
#
# #628: refusing an ambiguous name is half the job; the other half is that "there was exactly one"
# survives into the record. A lookup silent on success leaves a result with no way to tell a
# discriminator from tree order.
#
# Driven through the REAL `located_band` against a STUB tool placed where it would compile one.
# Nothing here calls swiftc, and nothing reimplements the parsing — a test that rewrites the rule
# agrees with itself no matter what the code does.
import json as _json
import stat
import tempfile as _tempfile

def _with_stub_tool(stdout, selector=("Tracks header",)):
    """Run `located_band` with a tool that prints `stdout`. Returns (result, records)."""
    root = _tempfile.mkdtemp()
    ev = E.Evidence("b" * 40, root)
    tool = os.path.join(ev.dir, "ax_control_bar_band")
    with open(tool, "w") as fh:
        fh.write("#!/bin/sh\ncat <<'JSON'\n" + stdout + "\nJSON\n")
    os.chmod(tool, os.stat(tool).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return ev.located_band(*selector), ev.records

BAND = '{"band":[603,162,325,873],"description":"Tracks header","candidates":1}'
NO_COUNT = '{"band":[603,162,325,873],"description":"Tracks header"}'
AMBIGUOUS = '{"error":"AXDescription is ambiguous","matches":[{"role":"AXGroup"},{"role":"AXGroup"}]}'

for stdout, want_result, want_tag, want_payload, why in [
    (BAND, ((603, 162, 325, 873), "Tracks header"), "located_band/candidates",
     {"candidates": 1, "counted": True}, "one candidate is RECORDED as one"),
    (NO_COUNT, ((603, 162, 325, 873), "Tracks header"), "located_band/candidates",
     {"candidates": None, "counted": False},
     "an older tool that never counted is not silence — it says so"),
    (AMBIGUOUS, (None, None), "located_band/refused",
     {"why": "AXDescription is ambiguous"}, "ambiguity is refused and the reason recorded"),
    ("not json at all", (None, None), "located_band/refused",
     {"why": "the tool printed something that is not JSON"}, "unparseable output is a refusal"),
]:
    (result, records) = _with_stub_tool(stdout)
    notes = [r for r in records if r.get("kind") == "observation" and r.get("tag") == want_tag]
    payload = notes[0]["payload"] if notes else {}
    ok = (result == want_result
          and len(notes) == 1
          and all(payload.get(k) == v for k, v in want_payload.items()))
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {why:<52} -> {result} {payload if not ok else ''}")

# --- a localized AXDescription still resolves, and the record says which word matched ----------
#
# #519: `Tracks contents` is `트랙 콘텐츠` on a Korean Logic, so a lookup for the English name finds
# nothing — measured on the one run where the locale was the entire point. `Step Sequencer` is NOT
# translated, which is why the table is measured pairs rather than a rule.
#
# The stub answers only for the KOREAN name, so a version that tries the requested name alone fails
# these cases and a version that tries the table's entries passes them.
def _with_locale_stub(answers_for, selector=("Tracks contents",)):
    root = _tempfile.mkdtemp()
    ev = E.Evidence("c" * 40, root)
    tool = os.path.join(ev.dir, "ax_control_bar_band")
    with open(tool, "w") as fh:
        fh.write("#!/bin/sh\n"
                 f'if [ "$1" = "{answers_for}" ]; then\n'
                 f'  echo \'{{"band":[928,162,6162,391],"description":"{answers_for}","candidates":1}}\'\n'
                 "else\n"
                 "  echo '{\"error\":\"no element with that exact AXDescription\"}'\n"
                 "fi\n")
    os.chmod(tool, os.stat(tool).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return ev.located_band(*selector), ev.records

(result, records) = _with_locale_stub("트랙 콘텐츠")
matched = [r for r in records if r.get("tag") == "located_band/matched-a-localized-label"]
ok = (result[0] == (928, 162, 6162, 391) and result[1] == "트랙 콘텐츠"
      and len(matched) == 1 and matched[0]["payload"]["requested"] == "Tracks contents")
failed += 0 if ok else 1
print(f"{'ok  ' if ok else 'FAIL'} a Korean window resolves through the measured table -> {result}")

# The English name still wins when it is the one on screen, and nothing is noted.
(result, records) = _with_locale_stub("Tracks contents")
noted = [r for r in records if r.get("tag") == "located_band/matched-a-localized-label"]
ok = result[1] == "Tracks contents" and not noted
failed += 0 if ok else 1
print(f"{'ok  ' if ok else 'FAIL'} an English window needs no translation and notes none -> {result}")

# A name with no measured translation fails closed rather than being guessed at.
(result, records) = _with_locale_stub("트랙 콘텐츠", selector=("Step Sequencer",))
ok = result == (None, None)
failed += 0 if ok else 1
print(f"{'ok  ' if ok else 'FAIL'} an unmeasured name is refused, not guessed -> {result}")

# --- the API the harnesses actually call must exist -------------------------------------------
#
# #620 rewrote evidence.py from a base that predated three functions, and merging it deleted them
# while every call site stayed. Main could not run a single live harness. Both branches were green:
# the ship gate runs the Swift suite, #620 touched no Sources/ so it needed no live evidence, and
# the tests above never call shot(), visual(), or write().
#
# The required names are SCANNED from the harnesses rather than listed here. A hand-written list is
# a second copy that goes stale exactly when a harness starts using something new.
import glob
import inspect
import re

HERE = os.path.dirname(os.path.abspath(__file__))
module_calls, instance_calls = set(), set()
for path in sorted(glob.glob(os.path.join(HERE, "live_*.py")) + glob.glob(os.path.join(HERE, "session_*.py"))):
    src = open(path).read()
    module_calls |= set(re.findall(r"\bE\.([A-Za-z_]\w*)", src))
    instance_calls |= set(re.findall(r"\bev\.([A-Za-z_]\w*)", src))

for name in sorted(module_calls):
    ok = hasattr(E, name)
    failed += 0 if ok else 1
    if not ok:
        print(f"FAIL evidence.{name} is called by a harness and does not exist")
# Attributes assigned in __init__ are not class attributes, so `hasattr(Evidence, "dir")` is False
# for a name that plainly exists. Read those statically rather than constructing an Evidence, which
# would create directories as a side effect of a unit test.
init_attrs = set(re.findall(r"self\.([A-Za-z_]\w*)\s*=", inspect.getsource(E.Evidence)))
for name in sorted(instance_calls):
    ok = hasattr(E.Evidence, name) or name in init_attrs
    failed += 0 if ok else 1
    if not ok:
        print(f"FAIL Evidence.{name} is called by a harness and does not exist")
print(f"ok   harness API present: {len(module_calls)} module + {len(instance_calls)} instance names")

# --- the return SHAPES, driven ------------------------------------------------------------------
#
# The static contract check beside this (Scripts/check-python-contracts.py) proves every name a
# consumer references exists and every call binds. It cannot see a function that keeps its name and
# its signature and starts returning something else — nothing static can, in untyped Python. This
# drives the whole non-capture surface headlessly and asserts what comes back.
#
# Everything except shot() and record_screen() runs without Logic and without a display; visual()
# is fed two synthetic PNGs. That is what makes this runnable in CI, which is the only place it
# stops a merge.
import struct
import tempfile
import zlib


def _png(path, colour):
    raw = b"".join(b"\x00" + bytes(colour) * 4 for _ in range(4))

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    open(path, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b""))


tmp = tempfile.mkdtemp()
ev = E.Evidence(head="0" * 40, root=tmp, name="contract-drive")
shapes = []
shapes.append(("Evidence.dir is a str", isinstance(ev.dir, str)))
ev.check("t", True, "expected", "observed", "a mutation")
ev.note("n", {"a": 1})
ev.restored("r", True, "why")
a, b = os.path.join(tmp, "a.png"), os.path.join(tmp, "b.png")
_png(a, (1, 2, 3))
_png(b, (1, 2, 3))
ev.visual("v", a, b, (0, 0, 4, 4), expect_change=False, why="w", subject="a synthetic square")
# A visual with no region must NOT pass. It used to: `_region_hash` fell back to hashing the whole
# file, so the comparison silently became "did anything on screen change" and answered yes-or-no
# about a rectangle it never looked at. Measured in the wild when a band lookup returned None.
shapes.append(("a region-less visual does not pass",
               ev.visual("no-region", a, b, None, expect_change=False, why="w", subject="x") is False))
out = ev.write()
shapes.append(("write() returns a dict", isinstance(out, dict)))
shapes.append(("summary carries every required key",
               all(k in out for k in E._REQUIRED_SUMMARY_KEYS)))
shapes.append(("counters are ints", all(isinstance(out[k], int) for k in E._REQUIRED_SUMMARY_KEYS)))
shapes.append(("is_clean() returns a bool", isinstance(E.is_clean(out), bool)))
shapes.append(("the driven visual named a subject", out["visual_assertions_without_a_subject"] == 0))
shapes.append(("have_tools() returns a list", isinstance(E.have_tools(), list)))
shapes.append(("_safe_name() returns a str", isinstance(E._safe_name("x"), str)))
for why, ok in shapes:
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} shape: {why}")

print(f"\n{'FAILED' if failed else 'all cases behaved'} ({failed} unexpected)")
sys.exit(1 if failed else 0)
