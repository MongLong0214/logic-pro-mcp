#!/usr/bin/env python3
"""Cases for `check-acceptance-specs.py`, driven through its entry point at fixture directories.

Each failing case copies the pilot spec and its issue body into a scratch directory, breaks one
thing, and runs the guard with `LPM_ACCEPTANCE_DIR` pointed there. Every failing case asserts on
the rule that names the break, so a case cannot pass on a different refusal. The controls -- the
real tree, and an unbroken copy -- are what keep a guard that refuses everything from passing.

    python3 Scripts/test_acceptance_specs.py
"""
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(REPO, "Scripts", "check-acceptance-specs.py")
SPECS = os.path.join(REPO, "docs", "acceptance")
PILOT = "1020.json"
sys.path.insert(0, os.path.join(REPO, "Scripts"))

import locale_labels  # noqa: E402


def _pilot() -> dict:
    with open(os.path.join(SPECS, PILOT), encoding="utf-8") as handle:
        return json.load(handle)


def _a_localised_canonical() -> str:
    """A label the policy knows another language spells differently, in its canonical spelling.

    Taken from the canon export rather than written here, so the case follows the vocabulary.
    """
    canonicals = locale_labels.localised_canonicals()
    name = canonicals[sorted(canonicals)[0]]
    return locale_labels.load_json()["labels"][name]["canonical"]


class Guard(unittest.TestCase):
    def _tree(self, specs: dict, bodies=True) -> str:
        root = tempfile.mkdtemp(prefix="acceptance-specs-")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        for name, spec in specs.items():
            with open(os.path.join(root, name), "w", encoding="utf-8") as handle:
                json.dump(spec, handle, indent=1)
        if bodies:
            shutil.copytree(os.path.join(SPECS, "issues"), os.path.join(root, "issues"))
        return root

    def _run(self, root=None):
        env = dict(os.environ)
        env.pop("LPM_ACCEPTANCE_DIR", None)
        if root is not None:
            env["LPM_ACCEPTANCE_DIR"] = root
        proc = subprocess.run([sys.executable, GUARD], capture_output=True, text=True, env=env,
                              timeout=600)
        return proc.returncode, proc.stdout + proc.stderr

    def _refused(self, root, *needles):
        code, out = self._run(root)
        self.assertEqual(code, 1, out[-1500:])
        for needle in needles:
            self.assertIn(needle, out, out[-1500:])
        return out

    # controls ---------------------------------------------------------------------------------

    def test_the_real_tree_passes(self):
        code, out = self._run()
        self.assertEqual(code, 0, out[-1500:])
        self.assertIn("admitted offline by check-spec", out)

    def test_an_unbroken_copy_passes(self):
        """The control for every case below: the copy itself is not what they refuse."""
        code, out = self._run(self._tree({PILOT: _pilot()}))
        self.assertEqual(code, 0, out[-1500:])

    def test_a_label_outside_the_scoped_positions_passes(self):
        spec = _pilot()
        label = _a_localised_canonical()
        spec["fixture"]["note"] += " " + label
        code, out = self._run(self._tree({PILOT: spec}))
        self.assertEqual(code, 0, out[-1500:])

    def test_evidence_is_not_read_as_a_spec(self):
        root = self._tree({PILOT: _pilot()})
        os.makedirs(os.path.join(root, "evidence"))
        with open(os.path.join(root, "evidence", "broken.json"), "w", encoding="utf-8") as handle:
            handle.write("{ not json")
        code, out = self._run(root)
        self.assertEqual(code, 0, out[-1500:])

    # check-spec -------------------------------------------------------------------------------

    def test_a_quote_not_verbatim_in_the_issue_body_is_refused(self):
        spec = _pilot()
        spec["sources"][0]["quote"] += " and this clause was never written"
        self._refused(self._tree({PILOT: spec}), "check-spec refused",
                      "sources[0]: the quote is not verbatim")

    def test_a_missing_issue_body_fails_rather_than_passing_unchecked(self):
        self._refused(self._tree({PILOT: _pilot()}, bodies=False), "(exit 3)")

    def test_an_unknown_fixture_id_is_refused(self):
        spec = _pilot()
        spec["fixture"]["id"] = spec["fixture"]["id"] + "-undeclared"
        self._refused(self._tree({PILOT: spec}), "check-spec refused",
                      "not in the fixture registry")

    # undecided sources ------------------------------------------------------------------------

    def test_a_source_no_row_decides_is_refused(self):
        spec = _pilot()
        spec["sources"].append({"doc": "issue:1020", "sha": None,
                                "quote": "Neither branch reads the current state first."})
        index = len(spec["sources"]) - 1
        self._refused(self._tree({PILOT: spec}), f"sources[{index}] is decided by no row")

    def test_an_exemption_whose_source_is_now_decided_is_reported(self):
        spec = _pilot()
        row = copy.deepcopy(spec["rows"][0])
        row["id"] = row["id"] + "-decides-source-2"
        row["criterion"] = 2
        spec["rows"].append(row)
        self._refused(self._tree({PILOT: spec}), "UNDECIDED[('1020.json', 2)]", "delete the entry")

    def test_an_exemption_whose_spec_is_gone_is_reported(self):
        spec = _pilot()
        self._refused(self._tree({"other.json": spec}), "UNDECIDED[('1020.json', 2)]",
                      "1020.json is gone")

    # label literals ---------------------------------------------------------------------------

    def test_a_label_literal_in_call_params_is_refused(self):
        spec = _pilot()
        label = _a_localised_canonical()
        spec["rows"][0]["steps"][1]["call"]["params"]["title"] = "  " + label + " "
        self._refused(self._tree({PILOT: spec}), "call.params.title",
                      "as a literal")

    def test_a_label_literal_in_a_restore_call_is_refused(self):
        spec = _pilot()
        label = _a_localised_canonical()
        spec["rows"][0]["restore"][0]["call"]["params"]["title"] = label.lower()
        self._refused(self._tree({PILOT: spec}), "restore[0].call.params.title", "as a literal")

    def test_a_label_literal_as_an_expected_value_is_refused(self):
        spec = _pilot()
        label = _a_localised_canonical()
        spec["rows"][0]["expect"][0]["value"] = label
        self._refused(self._tree({PILOT: spec}), "expect[0].value", "as a literal")

    def test_a_label_literal_as_a_wait_constant_is_refused(self):
        spec = _pilot()
        label = _a_localised_canonical()
        steps = spec["rows"][0]["steps"]
        probe = copy.deepcopy(steps[-1]["probe"])
        steps.append({"as": "settled", "wait": {
            "probe": probe, "until": {"path": "armed", "op": "eq", "value": label},
            "timeout_ms": 1000, "interval_ms": 100}})
        self._refused(self._tree({PILOT: spec}), "wait.until.value", "as a literal")

    def test_a_label_literal_in_an_expectation_selector_is_refused(self):
        spec = _pilot()
        spec["rows"][0]["expect"][3]["path"] = 'post.rows[name="Mixer"].isArmed'
        self._refused(self._tree({PILOT: spec}), "expect[3].path", "'Mixer'",
                      "as a literal")

    def test_a_label_literal_nested_in_a_selector_value_is_refused(self):
        spec = _pilot()
        spec["rows"][0]["expect"][3]["path"] = \
            'post.rows[meta={"label":"Mixer"}].isArmed'
        self._refused(self._tree({PILOT: spec}), "expect[3].path.meta.label", "'Mixer'",
                      "as a literal")

    def test_a_label_literal_in_a_restore_expectation_selector_is_refused(self):
        spec = _pilot()
        spec["rows"][0]["restore_expect"][0]["path"] = \
            'restored.rows[name="Mixer"].isArmed'
        self._refused(self._tree({PILOT: spec}), "restore_expect[0].path", "'Mixer'",
                      "as a literal")

    def test_a_label_literal_in_a_wait_selector_is_refused(self):
        spec = _pilot()
        steps = spec["rows"][0]["steps"]
        probe = copy.deepcopy(steps[-1]["probe"])
        steps.append({"as": "settled", "wait": {
            "probe": probe, "until": {"path": 'rows[name="Mixer"].isArmed',
                              "op": "eq", "value": True},
            "timeout_ms": 1000, "interval_ms": 100}})
        self._refused(self._tree({PILOT: spec}), "wait.until.path", "'Mixer'",
                      "as a literal")

    def test_a_label_literal_in_an_observation_reference_selector_is_refused(self):
        spec = _pilot()
        spec["rows"][0]["restore_expect"][0]["ref"]["obs"] = \
            'pre.rows[name="Mixer"].isArmed'
        self._refused(self._tree({PILOT: spec}), "restore_expect[0].ref.obs", "'Mixer'",
                      "as a literal")

    def test_path_keys_and_non_label_selectors_pass(self):
        spec = _pilot()
        spec["rows"][0]["expect"][3]["path"] = \
            'post.Mixer.rows[id=15][meta={"Mixer":{"inner":"neutral"}}].isArmed'
        code, out = self._run(self._tree({PILOT: spec}))
        self.assertEqual(code, 0, out[-1500:])


if __name__ == "__main__":
    unittest.main(verbosity=1)
