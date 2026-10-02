#!/usr/bin/env python3
"""Prove the #1039 harness credits an operation only when its reading moved (PR #1085 R-1039-02).

`candidate_acted` decides whether one candidate operation counts toward #1039. Review R1 found it
accepted a key Logic leaves unbound when the switch went through and the reading was anything but
changed, an unchanged checkbox or a reading that did not read included, so all eight operations
could pass with nothing acting.

Each case takes the stored Korean metronome row of the committed run, completed the way `main`
completes it, and changes one thing. Nothing talks to Logic. The harness is loaded by path, not
imported by name: a `live_*.py` is an entry point, which check-dead-harness-helpers.py relies on.

    python3 test_live_1039_candidate_acted.py
"""
import copy
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # the harness imports `evidence` and live_993 beside it
RUN = os.path.join(HERE, "..", "..", "docs", "observations", "evidence", "2026-10-02-1039-plain-letters-run.json")
OP = "transport.toggle_metronome"


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stored_row(harness):
    with open(RUN, encoding="utf-8") as handle:
        records = json.load(handle)["records"]
    payload = next(r["payload"] for r in records if r.get("tag") == "1039/ko/candidate")
    return dict(copy.deepcopy(payload[OP]), op=OP, accessibility_first=OP in harness.ACCESSIBILITY_FIRST,
                key_bound=True)


def main():
    harness = load("live_1039_plain_letters_under_2set_korean")
    row = stored_row(harness)
    # What the tool reads on this host: Dvorak types t on the U.S. K key and a on the A key.
    keys = {"k": {"abc": "k", "dvorak": "t"}, "a": {"abc": "a", "dvorak": "a"}}
    dvorak = {"ok": True, "ascii_layout": harness.DVORAK, "current": harness.KOREAN_2SET, "us_letter_keys": keys}
    automation = "automation.toggle_view"
    a_row = dict(row, op=automation, accessibility_first=False)
    on_dvorak = [dict(r, input_source_switched_to=harness.DVORAK) for r in row["replies"]]
    cases = [
        # The positive control: the row as the run recorded it.
        ("the stored row, its key bound", row, True),
        ("its key unbound", dict(row, key_bound=False), False),
        ("its binding unread", dict(row, key_bound=None), False),
        ("its key unbound and the reading unchanged", dict(row, key_bound=False, changed=False), False),
        ("its key unbound and the reading unread", dict(row, key_bound=False, changed=None), False),
        ("its key bound and the reading unchanged", dict(row, changed=False), False),
        ("its key bound and the reading not back", dict(row, came_back=False), False),
        # Review R1, R-1039-01: the layout the key went out under, and the history it was offered.
        ("switched to ABC, as expected", dict(row, expect_switched_to="com.apple.keylayout.ABC"), True),
        ("switched to ABC where Dvorak was expected", dict(row, expect_switched_to=harness.DVORAK), False),
        ("a Dvorak history required and none recorded", dict(row, history_required=True), False),
        ("a Dvorak history required and held before both calls",
         dict(row, history_required=True, ascii_histories=[dvorak, dvorak]), True),
        ("a Dvorak history required and ABC offered before the second call",
         dict(row, history_required=True, ascii_histories=[dvorak, dict(dvorak, ascii_layout="com.apple.keylayout.ABC")]),
         False),
        ("a Dvorak history required and the tool failing",
         dict(row, history_required=True, ascii_histories=[dvorak, dict(dvorak, ok=False)]), False),
        ("K under a Dvorak history, gone out under Dvorak, which types t",
         dict(row, history_required=True, ascii_histories=[dvorak, dvorak], replies=on_dvorak), False),
        ("A under a Dvorak history, gone out under Dvorak, which types a",
         dict(a_row, history_required=True, ascii_histories=[dvorak, dvorak], replies=on_dvorak), True),
        ("A under a Dvorak history, gone out under ABC although Dvorak types a",
         dict(a_row, history_required=True, ascii_histories=[dvorak, dvorak]), False),
    ]
    unexpected = 0
    for name, case, want in cases:
        got = harness.candidate_acted(case)
        ok = got is want
        unexpected += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name} -> {got}, expected {want}")
    print(f"{'all cases behaved' if not unexpected else 'FAILED'} ({unexpected} unexpected)")
    return 1 if unexpected else 0


if __name__ == "__main__":
    sys.exit(main())
