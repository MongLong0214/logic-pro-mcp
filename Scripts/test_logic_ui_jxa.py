#!/usr/bin/env python3
"""Unit coverage for shared Logic UI JXA helpers."""

from __future__ import annotations

import subprocess
import unittest

import logic_variants
from logic_ui_jxa import parse_jxa_json_result, save_panel_snapshot_source, ui_prelude


class LogicUIJXATests(unittest.TestCase):
    def test_parse_jxa_json_result_accepts_object(self):
        result = subprocess.CompletedProcess(
            args=["osascript"],
            returncode=0,
            stdout='{"status":"present"}',
            stderr="",
        )

        self.assertEqual(parse_jxa_json_result(result), {"status": "present"})

    def test_parse_jxa_json_result_reports_invalid_output(self):
        result = subprocess.CompletedProcess(
            args=["osascript"],
            returncode=0,
            stdout="not json",
            stderr="stderr text",
        )

        parsed = parse_jxa_json_result(result)
        self.assertEqual(parsed["status"], "error")
        self.assertEqual(parsed["reason"], "invalid_jxa_output")
        self.assertEqual(parsed["stderr"], "stderr text")

    def test_ui_prelude_optionally_includes_menu_items(self):
        without_menu = ui_prelude(marker_constant="MARKERS", markers=["A"])
        with_menu = ui_prelude(marker_constant="MARKERS", markers=["A"], include_menu_items=True)

        self.assertIn("const MARKERS", without_menu)
        self.assertNotIn("menuItems()", without_menu)
        self.assertIn("menuItems()", with_menu)

    def test_save_panel_snapshot_source_uses_variant_process_lookup(self):
        source = save_panel_snapshot_source()
        self.assertNotIn('byName("Logic Pro")', source)
        self.assertIn("processNames", source)
        self.assertIn("candidate.exists()", source)
        for process_name in logic_variants.logic_app_names():
            self.assertIn(process_name, source)


if __name__ == "__main__":
    unittest.main()
