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
    "checks": 1, "passed": 1, "mutation_claimed": 1, "operations_driven": 1,
    "checks_recorded_under_blocking_modal": 0,
    "checks_missing_blocking_modal_snapshot": 0,
    "checks_with_blocking_modal_unknown": 0,
    "checks_with_a_counterexample": 0, "counterexamples_not_rejected": 0,
    "captures": 1, "captures_unsettled": 0, "captures_straddling_displays": 0,
    "restorations_failed": 0, "cached_reads_used_as_live": 0,
    "visual_assertions": 1, "visual_failed": 0, "visual_assertions_without_a_subject": 0,
    "declared_surface": None,
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
    (False, {**GOOD, "mutation_claimed": 0}, "no check names a mutation"),
    (False, {**GOOD, "counterexamples_not_rejected": 1},
     "a counterexample the assertion failed to reject"),
    (False, {**GOOD, "checks_recorded_under_blocking_modal": 1},
     "a check recorded while a blocking modal was present"),
    (False, {**GOOD, "checks_missing_blocking_modal_snapshot": 1},
     "a check whose modal snapshot field is absent"),
    (False, {**GOOD, "checks_with_blocking_modal_unknown": 1},
     "a check whose modal detector could not inspect its state"),
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
    # #754 — a declared non-UI surface earns its zeros by a different instrument, never by silence.
    (True, {**GOOD, "declared_surface": "non_ui", "captures": 0, "visual_assertions": 0,
            "recordings": 0, "checks_with_a_counterexample": 3},
     "non_ui: no captures, visuals or recordings, but a counterexample control"),
    (False, {**GOOD, "declared_surface": None, "captures": 0, "visual_assertions": 0,
             "recordings": 0, "checks_with_a_counterexample": 3},
     "the same zeros with NO declaration are still unclean — silence is not a class"),
    (False, {**GOOD, "declared_surface": "non_ui", "captures": 0, "visual_assertions": 0,
             "recordings": 0, "checks_with_a_counterexample": 0},
     "non_ui that asserted nothing: zeros unearned on this surface too"),
    (False, {**GOOD, "declared_surface": "non_ui", "captures": 0, "visual_assertions": 0,
             "recordings": 0, "checks_with_a_counterexample": 3, "counterexamples_not_rejected": 1},
     "non_ui whose counterexample was not rejected — the shared rule still applies"),
    (True, {**GOOD, "declared_surface": "ui"}, "an explicitly declared UI document is judged as before"),
    (False, {**GOOD, "declared_surface": "ui", "captures": 0},
     "declaring ui does not relax anything"),
]

failed = 0
for expected, summary, why in CASES:
    got = E.is_clean(summary)
    ok = got is expected
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} is_clean -> {got!s:<5} expected {expected!s:<5} {why}")

# --- modal detection needs both the screen level and AX modality/sheet signals ----------------
#
# These are synthetic CoreGraphics records; this test never asks a live Logic for windows. Today's
# measurement supplied the two level facts: the blocking audio-interface alert was at modal-panel
# level 8, and the "Studio Grand" plug-in was at floating level 3. The standard-level, non-Logic,
# and NO-BREAK-SPACE cases below are constructed probes. (The owner spelling itself is separately
# documented from the 2026-08-17 Korean measurement in `evidence.py`.)
class _ModalQuartz:
    kCGModalPanelWindowLevelKey = "modal-panel"
    kCGWindowLayer = "kCGWindowLayer"
    kCGWindowBounds = "kCGWindowBounds"
    kCGWindowNumber = "kCGWindowNumber"
    kCGWindowName = "kCGWindowName"

    @staticmethod
    def CGWindowLevelForKey(key):
        assert key == _ModalQuartz.kCGModalPanelWindowLevelKey
        return 8


class _NotADict:
    """Subscriptable, and not a `dict` — which is what CoreGraphics actually returns.

    Measured 2026-08-30: `kCGWindowBounds` comes back as an NSDictionary proxy, so a guard written
    as `isinstance(b, dict)` skipped a Logic alert that was on screen at layer 8 and had already
    been identified as a modal. Every case here passed while it did, because the fixtures below
    supplied real dicts — the fixture was more permissive than the thing it stood for, so it could
    not fail. This class exists so it can.
    """

    def __init__(self, values):
        self._values = values

    def __getitem__(self, key):
        return self._values[key]


def _synthetic_window(owner, title, layer, number=41, bounds_type=dict):
    return {
        "kCGWindowOwnerName": owner,
        "kCGWindowName": title,
        "kCGWindowLayer": layer,
        "kCGWindowNumber": number,
        "kCGWindowBounds": bounds_type({"X": 101, "Y": 202, "Width": 303, "Height": 404}),
    }


_old_quartz = sys.modules.get("Quartz")
sys.modules["Quartz"] = _ModalQuartz
try:
    clear_ax = {"modal_windows": [], "sheets": []}
    modal_cases = [
        ("modal_panel", [_synthetic_window("Logic Pro", "Audio Interface", 8)],
         {"modal_windows": [{"title": "Audio Interface", "pid": 99}], "sheets": []},
         "a modal-panel level is corroborated by AXModal rather than assumed modal"),
        (None, [_synthetic_window("Logic Pro", "Modeless panel", 8)], clear_ax,
         "a modeless panel assigned the modal level is not a false positive"),
        (None, [_synthetic_window("Logic Pro", "Studio Grand", 3)], clear_ax,
         "the measured plug-in floating level is not a modal"),
        (None, [_synthetic_window("Logic Pro", "Tracks", 0)], clear_ax,
         "a Logic standard-level window is not a modal"),
        (None, [_synthetic_window("Finder", "A dialog", 8)], clear_ax,
         "a non-Logic modal-panel window is not this application's modal"),
        ("modal_panel", [_synthetic_window("Logic Pro", "Korean alert", 8)],
         {"modal_windows": [{"title": "Korean alert"}], "sheets": []},
         "a Korean Logic owner name with a NO-BREAK SPACE is normalized"),
        ("modal_panel", [_synthetic_window("Logic Pro", "NSDictionary bounds", 8, bounds_type=_NotADict)],
         {"modal_windows": [{"title": "NSDictionary bounds"}], "sheets": []},
         "bounds that are subscriptable but not a dict are read, as CoreGraphics returns them"),
        ("modal_window", [], {"modal_windows": [{"title": "Go To Position", "pid": 99}], "sheets": []},
         "an AXModal window on another Space is still detected without an on-screen CG record"),
        ("sheet", [], {"modal_windows": [], "sheets": [{"host_title": "Tracks", "pid": 99}]},
         "an AXSheet is detected although its host itself is not AXModal"),
    ]
    for expected_kind, windows, signals, why in modal_cases:
        got = E.blocking_modal(
            lister=lambda windows=windows: windows,
            ax_lister=lambda signals=signals: signals,
        )
        ok = ((got is None) if expected_kind is None else
              (isinstance(got, dict) and got.get("state") == "detected"
               and got.get("kind") == expected_kind))
        failed += 0 if ok else 1
        print(f"{'ok  ' if ok else 'FAIL'} blocking_modal -> {got!r} {why}")

    for lister, ax_lister, why in [
        (lambda: None, lambda: clear_ax, "an unreadable CoreGraphics list is not a clear desktop"),
        (lambda: [], lambda: None, "an unreadable AX sheet/modal query is not an empty search"),
    ]:
        got = E.blocking_modal(lister=lister, ax_lister=ax_lister)
        ok = (isinstance(got, dict) and got.get("state") == E.MODAL_CANNOT_TELL
              and got.get("kind") == E.MODAL_CANNOT_TELL)
        failed += 0 if ok else 1
        print(f"{'ok  ' if ok else 'FAIL'} blocking_modal -> {got!r} {why}")
finally:
    if _old_quartz is None:
        del sys.modules["Quartz"]
    else:
        sys.modules["Quartz"] = _old_quartz

# A sheet enumerated directly through AXSheets need not also appear in AXChildren. Its unreadable
# role used to be skipped, leaving a completed `None` scan when its host reported AXModal=false.
# Drive `_first_ax_sheet` itself with that shape: the caller can turn this raised read error into
# `cannot_tell`, but it must never receive an empty result from this unreadable enumeration.
class _DirectSheetRoleUnreadableAX:
    window = object()
    candidate = object()

    def attribute(self, element, attribute, site):
        if element is self.window and attribute == "AXSheets":
            return [self.candidate]
        if element is self.window and attribute == "AXChildren":
            return []
        if element is self.candidate and attribute == "AXRole":
            raise E._ModalReadError("AXSheets candidate AXRole", -25205)
        raise AssertionError(f"unexpected AX read: {element!r} {attribute!r} at {site!r}")

    def elements(self, value, site):
        return value

    def text(self, value, site):
        raise AssertionError("the candidate AXRole read must fail before text conversion")

    def definitive_absence(self, status):
        return status in {-25205, -25212}


sheet_ax = _DirectSheetRoleUnreadableAX()
try:
    E._first_ax_sheet(sheet_ax, sheet_ax.window)
    unreadable_direct_sheet = False
except E._ModalReadError:
    unreadable_direct_sheet = True
failed += 0 if unreadable_direct_sheet else 1
print(f"{'ok  ' if unreadable_direct_sheet else 'FAIL'} an unreadable direct AXSheets role is cannot-tell, not clear")

# A caller's snapshot is from the observation instant. `check()` records it without sampling again;
# `falsifiable()` below has no snapshot and exercises the record-time fallback. The two receipts
# prove that recording one observation cannot smear its state over the next one.
import tempfile as _tempfile_for_modal

_modal_snapshot = {"state": "detected", "kind": "modal_panel", "signal": "test",
                   "id": 41, "title": "Audio Interface",
                   "x": 101, "y": 202, "w": 303, "h": 404, "layer": 8}
_original_blocking_modal = E.blocking_modal
_modal_reads = iter([None])
E.blocking_modal = lambda: next(_modal_reads)
try:
    modal_receipts = E.Evidence("d" * 40, _tempfile_for_modal.mkdtemp())
    modal_receipts.check("modal/ordinary", True, "expected", "observed", "a mutation",
                        modal_snapshot=_modal_snapshot)
    modal_receipts.falsifiable("modal/falsifiable", lambda value: value == 1, 1, 0, "expected")
    modal_summary = E.summarize(modal_receipts.records)
finally:
    E.blocking_modal = _original_blocking_modal

modal_records = [r for r in modal_receipts.records if r["kind"] == "check"]
ok = (modal_records[0]["blocking_modal"] == _modal_snapshot
      and modal_records[1]["blocking_modal"] is None
      and modal_summary["checks_recorded_under_blocking_modal"] == 1)
failed += 0 if ok else 1
print(f"{'ok  ' if ok else 'FAIL'} observation-time and fallback modal snapshots stay per-check")

# A schema omission and an explicit failed detector are both different from None, which is the only
# completed-clear answer. Drive summarize rather than copying its predicates so a future `.get()`
# simplification cannot make either defect green again.
unknown_snapshot = {"state": E.MODAL_CANNOT_TELL, "kind": E.MODAL_CANNOT_TELL,
                    "signal": "test", "reason": "AX read failed"}
modal_gap_summary = E.summarize([
    {"kind": "check", "passed": True},
    {"kind": "check", "passed": True, "blocking_modal": unknown_snapshot},
])
ok = (modal_gap_summary["checks_missing_blocking_modal_snapshot"] == 1
      and modal_gap_summary["checks_with_blocking_modal_unknown"] == 1
      and modal_gap_summary["checks_recorded_under_blocking_modal"] == 0
      and E.is_clean({**GOOD,
                      "checks_missing_blocking_modal_snapshot": 1}) is False
      and E.is_clean({**GOOD,
                      "checks_with_blocking_modal_unknown": 1}) is False)
failed += 0 if ok else 1
print(f"{'ok  ' if ok else 'FAIL'} absent and cannot-tell modal snapshots cannot count as clear")

# `_body(None)` retains the dead transport in a non-empty dictionary for the receipt. The shared
# predicate must reject that shape rather than let a caller's ordinary `if body:` call it answered.
dead_transport = E._body(None)
ok = (dead_transport == {"_transport_error": None}
      and E.artifact_answered(dead_transport) is False
      and E.artifact_answered({}) is True
      and E.artifact_answered(None) is False)
failed += 0 if ok else 1
print(f"{'ok  ' if ok else 'FAIL'} artifact_answered rejects a truthy transport-error body")

# The remaining contract drives exercise `check()` and `falsifiable()` for unrelated behavior. Keep
# them headless: their clear modal snapshots are fixtures, not a read of whichever desktop runs CI.
_headless_blocking_modal = E.blocking_modal
E.blocking_modal = lambda: None

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
# `declared_surface` is the one required key that is not a counter: it is what the harness said
# about its subject, so it is a surface name or None. Everything else is a count.
shapes.append(("counters are ints", all(isinstance(out[k], int)
                                        for k in E._REQUIRED_SUMMARY_KEYS if k != "declared_surface")))
shapes.append(("the declaration is a surface name or None",
               out["declared_surface"] is None or out["declared_surface"] in E.Evidence.SURFACES))
shapes.append(("is_clean() returns a bool", isinstance(E.is_clean(out), bool)))
shapes.append(("the driven visual named a subject", out["visual_assertions_without_a_subject"] == 0))
shapes.append(("have_tools() returns a list", isinstance(E.have_tools(), list)))
shapes.append(("_safe_name() returns a str", isinstance(E._safe_name("x"), str)))
# --- falsifiable(): the assertion is run against a state it must reject -------------------------
# The whole point is that a condition which cannot fail must not pass here. Each case below is a
# predicate defect that `check()` records as green, because `check()` only ever sees the author's
# own boolean.
fev = E.Evidence("f" * 40, tmp, name="falsifiable_cases")
FCASES = [
    ("a real condition passes",              lambda o: o["survivors"] == 1, True),
    ("a constant-true predicate fails",      lambda o: True,                False),
    ("a predicate that rejects the observation fails", lambda o: False,     False),
    ("a condition too weak to reject the counterexample fails",
     lambda o: "survivors" in o,                                            False),
    ("a predicate that raises on the counterexample fails",
     lambda o: o["survivors"] == 1 or o["missing"],                         False),
]
OBS = {"survivors": 1, "identified": True}
COUNTER = {"survivors": 0, "identified": False}
for why, pred, want in FCASES:
    got = fev.falsifiable(f"f/{why}", pred, OBS, COUNTER, "expected", mutation=None)
    shapes.append((f"falsifiable: {why}", got is want))

frecords = [r for r in fev.records if r["kind"] == "check"]
shapes.append(("falsifiable records a counterexample on every check",
               all(r.get("has_counterexample") for r in frecords)))
# The rejection is COMPUTED. There is no parameter for it, and the recorded value has to follow the
# predicate rather than anything the caller said — that is the difference from `mutation_claimed`.
shapes.append(("the constant-true case records the counterexample as NOT rejected",
               frecords[1]["counterexample_rejected"] is False))
shapes.append(("the real condition records it as rejected",
               frecords[0]["counterexample_rejected"] is True))
fsummary = fev.write()
shapes.append(("the summary counts them", fsummary["checks_with_a_counterexample"] == len(FCASES)))
# THREE of the five, not four. The always-false predicate DOES reject the counterexample — it
# rejects everything — and fails for the other reason, that it rejected the observation too. The two
# failure modes are separate and the counter must only see its own: a predicate that cannot accept
# anything is a broken check, but it is not a check that failed to discriminate.
shapes.append(("and counts only the ones that failed to reject",
               fsummary["counterexamples_not_rejected"] == 3))

# #754 — the declaration is read off the records by summarize, and only a valid one counts.
decl = E.summarize([{"kind": "declaration", "surface": "non_ui"}, {"kind": "check", "passed": True}])
shapes.append(("summarize reads a non_ui declaration", decl["declared_surface"] == "non_ui"))
shapes.append(("summarize reads no declaration as None",
               E.summarize([{"kind": "check", "passed": True}])["declared_surface"] is None))
shapes.append(("summarize ignores a declaration naming an unknown surface",
               E.summarize([{"kind": "declaration", "surface": "maybe"}])["declared_surface"] is None))
try:
    E.Evidence("0" * 40, "/tmp/lpm-test-754-unused", surface="maybe")
    shapes.append(("Evidence refuses an unknown surface", False))
except ValueError:
    shapes.append(("Evidence refuses an unknown surface", True))
for why, ok in shapes:
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} shape: {why}")

E.blocking_modal = _headless_blocking_modal
print(f"\n{'FAILED' if failed else 'all cases behaved'} ({failed} unexpected)")
sys.exit(1 if failed else 0)
