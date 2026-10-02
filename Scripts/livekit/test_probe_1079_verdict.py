#!/usr/bin/env python3
"""Prove the #1079 probe's verdict cannot pass a run that did not exercise the candidate
(PR #1083 supplementary review S-02).

The probe's `--conditions` lets a search run some conditions only. The verdict used to judge only
the rows it was given, so a control-only run, or one with no baseline, returned no failure and the
probe exited 0 with no candidate witness. Each case builds rows the way the probe writes them and
calls the probe's own `verdict`. Nothing talks to Logic. The probe is loaded by path, as the other
harness tests load theirs.

    python3 test_probe_1079_verdict.py
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


def row(lproj, condition, sample):
    kept = condition != "control"
    return {"lproj": lproj, "condition": condition, "sample": sample,
            "outcome": "kept" if kept else "lost", "value_grew_by": 5 if kept else None}


def full(lprojs=("ko", "en"), samples=2):
    return [row(lproj, condition, n) for lproj in lprojs
            for condition in ("none", "candidate", "control") for n in range(samples)]


def main():
    probe = load("probe_1079_rename_keeps_focus")
    everything = full()
    without = lambda condition: [r for r in everything if r["condition"] != condition]  # noqa: E731
    lprojs, samples = ["ko", "en"], 2
    cases = [
        # The positive control: every language, condition and sample, each as it should be.
        ("every row present", everything, ["none", "candidate", "control"], True),
        ("the candidate condition not run", without("candidate"), ["none", "control"], False),
        ("the no-server baseline not run", without("none"), ["candidate", "control"], False),
        ("a control-only search", without("candidate") and [r for r in everything if r["condition"] == "control"],
         ["control"], False),
        ("one candidate sample missing", [r for r in everything if not (r["lproj"] == "en" and r["condition"] == "candidate" and r["sample"] == 1)],
         ["none", "candidate", "control"], False),
        ("a language missing", [r for r in everything if r["lproj"] != "en"], ["none", "candidate", "control"], False),
        ("a candidate sample lost", [dict(r, outcome="lost") if (r["lproj"], r["condition"], r["sample"]) == ("ko", "candidate", 0) else r for r in everything],
         ["none", "candidate", "control"], False),
    ]
    unexpected = 0
    # The context is required: a call without it cannot be made, so it cannot pass candidate-free
    # rows the way the first repair's default call did.
    for name, call in (("a call with rows alone", lambda: probe.verdict([r for r in everything if r["condition"] == "control"])),
                       ("a call without the sample count", lambda: probe.verdict(everything, lprojs, ["none", "candidate", "control"]))):
        try:
            call()
            print(f"FAIL {name} -> returned instead of refusing")
            unexpected += 1
        except TypeError:
            print(f"ok   {name} -> refused")
    # Supplementary review S-08: an empty context cannot pass either.
    control_only = [r for r in everything if r["condition"] == "control"]
    for name, args in (("no samples asked for", (control_only, lprojs, ["none", "candidate", "control"], 0)),
                       ("a negative sample count", (control_only, lprojs, ["none", "candidate", "control"], -1)),
                       ("no languages asked for", (control_only, [], ["none", "candidate", "control"], 2)),
                       ("an empty run with nothing asked for", ([], [], ["none", "candidate", "control"], 0))):
        failures = probe.verdict(*args)
        ok = bool(failures)
        unexpected += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name} -> {len(failures)} failure(s), expected some")
    for name, rows, conditions, passes in cases:
        failures = probe.verdict(rows, lprojs, conditions, samples)
        ok = (not failures) is passes
        unexpected += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name} -> {len(failures)} failure(s), expected {'none' if passes else 'some'}")
    print(f"{'all cases behaved' if not unexpected else 'FAILED'} ({unexpected} unexpected)")
    return 1 if unexpected else 0


if __name__ == "__main__":
    sys.exit(main())
