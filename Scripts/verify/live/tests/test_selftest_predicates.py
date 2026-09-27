#!/usr/bin/env python3
"""Offline: the self-test's must-FAIL control is judged by what the probe read, and aimed.

The live run arms track 0 through the product and reads the #1020 arm probe before and after. These
cases are that probe's observation shape with the values changed. Each names the mutation of
selftest_live.py it kills.
"""

import contextlib
import copy
import io
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

from live import selftest_live as st  # noqa: E402


def reading(*arms):
    return {"observation": {"readable": True, "tracks": [
        {"arm": a, "mute": 0, "solo": 0} for a in arms]}}


def control(pre, post, after):
    return {"pre": reading(*pre), "post": reading(*post), "after": reading(*after)}


class MustFail(unittest.TestCase):

    def test_track_0_armed_then_restored_is_the_control_failing_as_it_must(self):
        o = control((0, 0, 0), (1, 0, 0), (0, 0, 0))
        self.assertIs(st.pred_arm_probe_agrees_with_pre_state(o), False)
        self.assertTrue(st.pred_must_fail(o))

    def test_a_probe_that_did_not_see_the_arm_does_not_pass(self):
        # Kills: pred_must_fail not requiring the control predicate to be False (a blind probe).
        self.assertFalse(st.pred_must_fail(control((0, 0, 0), (0, 0, 0), (0, 0, 0))))

    def test_a_probe_reading_another_row_does_not_pass(self):
        # Kills: the post reading compared on track 0 only (another track's change also disagrees).
        self.assertFalse(st.pred_must_fail(control((0, 0, 0), (1, 1, 0), (0, 0, 0))))

    def test_a_disarm_that_did_not_restore_does_not_pass(self):
        # Kills: the `after == pre` restore term dropped.
        self.assertFalse(st.pred_must_fail(control((0, 0, 0), (1, 0, 0), (1, 0, 0))))

    def test_an_unreadable_reading_is_not_a_pass(self):
        o = control((0, 0, 0), (1, 0, 0), (0, 0, 0))
        broken = copy.deepcopy(o)
        broken["post"] = {"observation": {"readable": False, "cause": "no rail"}}
        self.assertIsNone(st.pred_arm_probe_agrees_with_pre_state(broken))
        self.assertFalse(st.pred_must_fail(broken))


def step(name, lproj=None, passed=True):
    return {"step": name, "lproj": lproj, "passed": passed}


def complete_run(locales):
    steps = [step(name) for name in ("build", "exclusivity")]
    steps += [step(name, lproj) for lproj in locales for name in st.PER_LOCALE_STEPS]
    steps += [step("restore", "ko"), step("final")]
    return {"locales": list(locales), "steps": steps}


class LocaleCoverage(unittest.TestCase):
    """PR #1033 review R4: the verdict covers every requested locale, ko plus another."""

    def test_the_reviewers_single_korean_step_is_not_a_pass(self):
        # Kills: finish() passing a run whose recorded steps all passed, whatever is missing.
        run = st.Run("0" * 40)
        run.doc["locales"] = ["ko", "de"]
        run.step("switch", {"after": {}}, lambda o: True, "ko")
        with tempfile.TemporaryDirectory() as out, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(st.finish(run, out), 1)

    def test_a_complete_two_locale_run_passes_and_one_missing_step_fails(self):
        # Kills: a required step dropped from the per-locale list without failing the verdict.
        self.assertEqual(st.verdict(complete_run(["ko", "de"]))["exit"], 0)
        for index in range(len(complete_run(["ko", "de"])["steps"])):
            doc = complete_run(["ko", "de"])
            del doc["steps"][index]
            self.assertEqual(st.verdict(doc)["exit"], 1, doc)

    def test_one_failed_step_fails(self):
        doc = complete_run(["ko", "de"])
        doc["steps"][5]["passed"] = False
        self.assertEqual(st.verdict(doc)["exit"], 1)

    def test_a_run_naming_only_korean_or_korean_twice_is_not_a_pass(self):
        # Kills: the ko-plus-a-distinct-other rule dropped from the verdict.
        self.assertEqual(st.verdict(complete_run(["ko"]))["exit"], 1)
        self.assertEqual(st.verdict(complete_run(["ko", "ko"]))["exit"], 1)
        self.assertEqual(st.verdict(complete_run(["de", "fr"]))["exit"], 1)

    def test_main_refuses_such_locales_with_exit_2_before_building(self):
        # Kills: main() accepting --locales ko (or a repeat) and building and driving anyway.
        built = []
        saved_build, saved_argv = st.binary.build, sys.argv
        st.binary.build = lambda *a, **k: built.append(a) or {"binary_path": None, "stages": []}
        try:
            for locales in (["ko"], ["ko,ko"], ["ko", "ko"], ["de"]):
                with tempfile.TemporaryDirectory() as out:
                    sys.argv = ["selftest_live.py", "--head", "0" * 40, "--evidence-root", out,
                                "--locales", *locales]
                    with self.assertRaises(SystemExit) as raised, \
                            contextlib.redirect_stderr(io.StringIO()), \
                            contextlib.redirect_stdout(io.StringIO()):
                        st.main()
                    self.assertEqual(raised.exception.code, 2, locales)
        finally:
            st.binary.build, sys.argv = saved_build, saved_argv
        self.assertEqual(built, [])


class Provenance(unittest.TestCase):

    def test_a_record_read_back_from_disk_does_not_pass_the_build_step(self):
        # Kills: pred_build accepting a result with no swift-build stage of its own (the
        # reviewer's forged /bin/ls record, returned as `reused`).
        head = "1" * 40
        forged = {"head": head, "asked_head": head, "binary_path": "/bin/ls",
                  "binary_sha256": "ab", "rehash": "ab", "binding": "built-by-verifier",
                  "reused": True, "stages": [{"stage": "resolve", "returncode": 0}]}
        self.assertFalse(st.pred_build(forged))
        # Kills: the own swift-build stage no longer required (a record without `reused` passing).
        self.assertFalse(st.pred_build({k: v for k, v in forged.items() if k != "reused"}))
        built = dict(forged, reused=False,
                     stages=[{"stage": "resolve"}, {"stage": "swift-build", "returncode": 0}])
        self.assertTrue(st.pred_build(built))
        # Kills: the `reused` flag ignored when a build stage is present.
        self.assertFalse(st.pred_build(dict(built, reused=True)))


if __name__ == "__main__":
    unittest.main()
