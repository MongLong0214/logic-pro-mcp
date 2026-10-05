#!/usr/bin/env python3
"""R1084-01: later installed metadata cannot bind a historical structural probe.

Uses the actual retained record and its separately labelled metadata, with fake
installed-host reads. No native API, defaults read, probe or Swift process runs.
"""
import copy
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "Scripts"))


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, REPO / "Scripts" / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


STATUS = module("r1084_status", "observations-status.py")
RATCHET = module("r1084_ratchet", "check-observation-ratchets.py")
RECORDS = module("r1084_records", "check-observation-records.py")
HOST = module("r1084_host", "observation_host.py")
RID = "2026-10-05-1084-readonly-dialog-modality"
RECORD_PATH = REPO / "docs" / "observations" / (RID + ".json")
EVIDENCE_PATH = REPO / "docs" / "observations" / "evidence" / (RID + ".json")


class HistoricalHostBindingTests(unittest.TestCase):
    def setUp(self):
        self.record = json.loads(RECORD_PATH.read_text(encoding="utf-8"))
        self.evidence = json.loads(EVIDENCE_PATH.read_text(encoding="utf-8"))
        self.later = self.evidence["later_host_metadata"]["host"]

    def unknown(self):
        doc = copy.deepcopy(self.record)
        doc["host"] = {
            "app": "Logic Pro", "version": None, "build": None, "os": None,
            "locale": None, "binding": "unknown",
            "reason": "The historical probe did not bind its host.",
        }
        return doc

    def test_actual_record_is_unknown_with_matching_later_metadata(self):
        row = STATUS.classify([(str(RECORD_PATH), self.record)], self.later)[0]
        self.assertEqual(row[1], "unknown")
        self.assertNotIn("measured on the installed", row[2])

    def test_known_host_current_drift_and_supersession_controls(self):
        # Synthetic known-host control, not a new historical observation.
        known = copy.deepcopy(self.record)
        known["host"] = copy.deepcopy(self.later)
        rows = [(str(RECORD_PATH), known)]
        self.assertEqual(STATUS.classify(rows, self.later)[0][1], "current")
        different = dict(self.later, build="different")
        self.assertEqual(STATUS.classify(rows, different)[0][1], "stale")
        self.assertEqual(STATUS.classify(rows, None)[0][1], "unknown")
        replacement = dict(known, id="replacement", supersedes=RID)
        self.assertEqual(STATUS.classify(rows + [("replacement", replacement)],
                                         self.later)[0][1], "superseded")

    def test_explicit_unknown_marker_cannot_borrow_matching_metadata(self):
        # Invalid mixed header is refused by the schema; readers must not grant it credit either.
        mixed = copy.deepcopy(self.record)
        mixed["host"] = dict(self.later, binding="unknown", reason="Unbound history.")
        self.assertEqual(STATUS.classify([("record", mixed)], self.later)[0][1], "unknown")
        output = io.StringIO()
        with patch.object(STATUS, "taxonomy", return_value=[(self.record["surface"], "fixture")]), \
                patch.object(STATUS, "_gaps", return_value={"surfaces_without_records": set()}), \
                redirect_stdout(output):
            self.assertEqual(STATUS.coverage([("record", mixed)]), 0)
        self.assertNotIn("[ko-KR]", output.getvalue())
        self.assertIn("host binding unknown", output.getvalue())

    def test_json_entrypoint_preserves_actual_unknown_host(self):
        output = io.StringIO()
        with patch.object(STATUS, "installed_host", return_value=self.later), \
                patch.object(STATUS, "load", return_value=[(str(RECORD_PATH), self.record)]), \
                patch.object(sys, "argv", ["observations-status.py", "--json"]), \
                redirect_stdout(output):
            self.assertEqual(STATUS.main(), 0)
        result = json.loads(output.getvalue())
        self.assertEqual(result["installed_host"], self.later)
        row = result["records"][0]
        self.assertEqual(row["status"], "unknown")
        self.assertEqual(row["host"]["binding"], "unknown")
        self.assertTrue(row["host"]["reason"].strip())
        for axis in ("version", "build", "os", "locale"):
            self.assertIsNone(row["host"][axis])
        self.assertNotIn("measured on the installed", row["reason"])

    def test_build_and_locale_ratchets_withhold_unbound_record_credit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            obs = root / "docs" / "observations"
            labels = root / "docs" / "locale"
            obs.mkdir(parents=True)
            labels.mkdir(parents=True)
            (labels / "ui-labels.json").write_text(
                json.dumps({"labels": {}, "supported_locales": ["ko-KR"]}), encoding="utf-8")
            (obs / "SURFACES.md").write_text(
                "| `system.accessibility` | fixture |\n", encoding="utf-8")
            (obs / "LOGIC-BUILD.json").write_text(json.dumps(self.later), encoding="utf-8")
            path = obs / (RID + ".json")
            mixed = copy.deepcopy(self.record)
            mixed["host"] = dict(self.later, binding="unknown", reason="Unbound history.")
            for name, doc in (("actual", self.record), ("mixed", mixed)):
                with self.subTest(record=name):
                    path.write_text(json.dumps(doc), encoding="utf-8")
                    gaps = RATCHET.live_state(str(root))
                    self.assertIn(RID, gaps["records_from_a_superseded_build"])
                    self.assertIn("ko-KR→system.accessibility", gaps["surfaces_without_records"])
            known = copy.deepcopy(self.record)
            known["host"] = copy.deepcopy(self.later)
            path.write_text(json.dumps(known), encoding="utf-8")
            gaps = RATCHET.live_state(str(root))
            self.assertNotIn(RID, gaps["records_from_a_superseded_build"])
            self.assertNotIn("ko-KR→system.accessibility", gaps["surfaces_without_records"])

    def test_schema_entrypoint_accepts_explicit_unknown_not_missing_or_fabricated_axes(self):
        with tempfile.TemporaryDirectory() as directory:
            obs = Path(directory)
            (obs / "evidence").mkdir()
            (obs / "evidence" / (RID + ".json")).write_bytes(EVIDENCE_PATH.read_bytes())
            path = obs / (RID + ".json")
            with patch.object(RECORDS, "DIR", str(obs)):
                path.write_text(json.dumps(self.unknown()), encoding="utf-8")
                self.assertEqual(RECORDS.check(str(path)), [])
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(RECORDS.main(), 0)
                for defect in ("missing_axis", "copied_axis", "missing_reason", "invalid_binding"):
                    with self.subTest(defect=defect):
                        invalid = self.unknown()
                        if defect == "missing_axis":
                            del invalid["host"]["locale"]
                        elif defect == "copied_axis":
                            invalid["host"]["version"] = self.later["version"]
                        elif defect == "missing_reason":
                            invalid["host"]["reason"] = ""
                        else:
                            invalid["host"]["binding"] = "maybe"
                        path.write_text(json.dumps(invalid), encoding="utf-8")
                        self.assertTrue(RECORDS.check(str(path)))
                        with redirect_stdout(io.StringIO()):
                            self.assertEqual(RECORDS.main(), 1)
                known = copy.deepcopy(self.record)
                known["host"] = copy.deepcopy(self.later)
                path.write_text(json.dumps(known), encoding="utf-8")
                self.assertEqual(RECORDS.check(str(path)), [])

    def test_host_check_does_not_match_explicit_unknown_to_later_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / (RID + ".json")
            mixed = copy.deepcopy(self.record)
            mixed["host"] = dict(self.later, binding="unknown", reason="Unbound history.")
            path.write_text(json.dumps(mixed), encoding="utf-8")
            output = io.StringIO()
            with patch.object(HOST, "host", return_value=self.later), redirect_stdout(output):
                self.assertEqual(HOST.check([str(path)]), 0)
            self.assertNotIn("matches this machine", output.getvalue())
            self.assertIn("historical host binding was not established", output.getvalue())


if __name__ == "__main__":
    unittest.main()
