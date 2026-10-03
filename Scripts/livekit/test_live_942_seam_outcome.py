#!/usr/bin/env python3
"""Prove the #942 settlement harness checks the exact refusal classification (PR #1083
supplementary review S-06).

`reached_the_seam` accepted any `dialog_route_outcome` ending `_cleanup_closed_false`, so a stored
German `leaf_click_error` hold still passed with another site's valid classification put in. Each
case builds the hold phase the harness records and calls its own `reached_the_seam`. Nothing talks
to Logic. The harness is loaded by path, as the other harness tests load theirs.

    python3 test_live_942_seam_outcome.py
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def phase(name, result, outcome, appearance=False):
    return {"name": name, "entered": result, "expected_result": result, "reply_returned": True,
            "release_left": False, "appearance": appearance,
            "reply": {"fallback_unsafe": True, "safe_to_retry": False, "dialog_route_outcome": outcome}}


def main():
    harness = load("live_942_post_leaf_settlement_in_every_locale")
    actuation = "DIALOG_ACTUATION_ISSUED: dialog cleanup was not observed (OPEN)"
    input_stage = "DIALOG_INPUT_ISSUED: SELECT_ALL_ARMED: dialog cleanup was not observed (OPEN)"
    cases = [
        # The positive controls: each site's own classification.
        ("leaf_click_error with its own classification",
         phase("leaf_click_error", actuation, "dialog_actuation_issued_cleanup_closed_false"), True),
        ("select_all_error with its own classification",
         phase("select_all_error", input_stage, "dialog_input_issued_SELECT_ALL_ARMED_cleanup_closed_false"), True),
        # The review's reproduction: another valid classification sharing the suffix.
        ("leaf_click_error with the submission classification",
         phase("leaf_click_error", actuation, "dialog_submission_issued_cleanup_closed_false"), False),
        ("select_all_error with the next stage's classification",
         phase("select_all_error", input_stage, "dialog_input_issued_POSITION_INPUT_ARMED_cleanup_closed_false"), False),
        ("leaf_click_error with the cleanup observed closed",
         phase("leaf_click_error", actuation, "dialog_actuation_issued_cleanup_closed_true"), False),
        ("an appearance result named exactly",
         phase("dialog_unidentified_new_window", "DIALOG_UNIDENTIFIED_NEW_WINDOW",
               "dialog_unidentified_new_window", appearance=True), True),
    ]
    unexpected = 0
    for name, case, want in cases:
        got = harness.reached_the_seam(case)
        ok = got is want
        unexpected += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name} -> {got}, expected {want}")
    print(f"{'all cases behaved' if not unexpected else 'FAILED'} ({unexpected} unexpected)")
    return 1 if unexpected else 0


if __name__ == "__main__":
    sys.exit(main())
