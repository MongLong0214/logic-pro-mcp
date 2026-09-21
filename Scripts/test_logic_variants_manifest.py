"""Contract tests for Scripts/logic_variants.py (manifest-driven bundle/process names)."""

from __future__ import annotations

import os
import unittest

import logic_variants


class LogicVariantsPolicyTests(unittest.TestCase):
    def test_manifest_bundle_ids_desktop_before_creator_studio(self):
        bundle_ids = logic_variants.manifest_bundle_ids_in_order()
        self.assertEqual(bundle_ids[0], "com.apple.logic10")
        self.assertEqual(bundle_ids[1], "com.apple.mobilelogic")

    def test_manifest_process_names_and_install_paths_present(self):
        variants = logic_variants.manifest_variants()
        self.assertEqual(variants[0]["process_name"], "Logic Pro")
        self.assertEqual(variants[1]["process_name"], "Logic Pro Creator Studio")
        self.assertTrue(all(v["default_install_path"].endswith(".app") for v in variants))

    def test_process_name_map_keys_match_manifest(self):
        self.assertEqual(
            set(logic_variants.process_name_by_bundle_id()),
            set(logic_variants.manifest_bundle_ids_in_order()),
        )

    def test_default_priority_matches_manifest(self):
        previous = os.environ.pop("LOGIC_PRO_BUNDLE_ID", None)
        try:
            self.assertEqual(
                logic_variants.bundle_ids_in_priority_order(),
                logic_variants.manifest_bundle_ids_in_order(),
            )
        finally:
            if previous is not None:
                os.environ["LOGIC_PRO_BUNDLE_ID"] = previous

    def test_forced_bundle_id_overrides_priority(self):
        previous = os.environ.get("LOGIC_PRO_BUNDLE_ID")
        os.environ["LOGIC_PRO_BUNDLE_ID"] = "com.example.custom"
        try:
            self.assertEqual(logic_variants.bundle_ids_in_priority_order(), ("com.example.custom",))
        finally:
            if previous is None:
                os.environ.pop("LOGIC_PRO_BUNDLE_ID", None)
            else:
                os.environ["LOGIC_PRO_BUNDLE_ID"] = previous

    def test_jxa_find_process_snippet_includes_all_manifest_process_names(self):
        snippet = logic_variants.jxa_find_process_snippet()
        for process_name in logic_variants.logic_app_names():
            self.assertIn(process_name, snippet)

    def test_jxa_find_process_snippet_gates_on_exists(self):
        snippet = logic_variants.jxa_find_process_snippet()
        self.assertIn("candidate.exists()", snippet)
        self.assertNotIn("candidate !== null", snippet)

    def test_jxa_selects_creator_studio_when_desktop_process_missing(self):
        selected = logic_variants.select_jxa_process_name(
            ["Logic Pro", "Logic Pro Creator Studio"],
            exists=lambda name: name == "Logic Pro Creator Studio",
        )
        self.assertEqual(selected, "Logic Pro Creator Studio")

    def test_process_name_for_unknown_bundle_returns_bundle_id(self):
        self.assertEqual(
            logic_variants.process_name_for_bundle_id("com.example.custom"),
            "com.example.custom",
        )

    def test_resolve_prefers_frontmost_creator_studio_when_both_running(self):
        selected = logic_variants.resolve_bundle_id(
            forced_bundle_id=None,
            frontmost_bundle_id="com.apple.mobilelogic",
            is_running=lambda bundle_id: bundle_id
            in {"com.apple.logic10", "com.apple.mobilelogic"},
            is_installed=lambda _bundle_id: True,
        )
        self.assertEqual(selected, "com.apple.mobilelogic")

    def test_resolve_forced_bundle_id_wins_over_frontmost(self):
        selected = logic_variants.resolve_bundle_id(
            forced_bundle_id="com.apple.logic10",
            frontmost_bundle_id="com.apple.mobilelogic",
            is_running=lambda _bundle_id: True,
            is_installed=lambda _bundle_id: True,
        )
        self.assertEqual(selected, "com.apple.logic10")

    def test_resolve_falls_back_to_running_then_installed(self):
        selected_running = logic_variants.resolve_bundle_id(
            forced_bundle_id=None,
            frontmost_bundle_id="com.apple.Safari",
            is_running=lambda bundle_id: bundle_id == "com.apple.mobilelogic",
            is_installed=lambda bundle_id: bundle_id == "com.apple.logic10",
        )
        self.assertEqual(selected_running, "com.apple.mobilelogic")

        selected_installed = logic_variants.resolve_bundle_id(
            forced_bundle_id=None,
            frontmost_bundle_id=None,
            is_running=lambda _bundle_id: False,
            is_installed=lambda bundle_id: bundle_id == "com.apple.mobilelogic",
        )
        self.assertEqual(selected_installed, "com.apple.mobilelogic")

    def test_action_helper_empty_stdout_does_not_try_second_variant(self):
        calls: list[str] = []

        def run_osa(script: str, _timeout: float) -> str:
            calls.append(script)
            return ""

        def resolve_target() -> logic_variants.ResolvedLogicTarget:
            return logic_variants.ResolvedLogicTarget(
                bundle_id="com.apple.logic10",
                process_name="Logic Pro",
            )

        result = logic_variants.logic_process_osa_action_with_runner(
            "key code 11 using {command down}",
            run_osa,
            resolve_target=resolve_target,
        )
        self.assertEqual(result, "")
        self.assertEqual(len(calls), 1)
        self.assertIn('tell application process "Logic Pro"', calls[0])
        self.assertNotIn("Logic Pro Creator Studio", calls[0])

    def test_query_helper_empty_stdout_does_not_try_second_variant(self):
        calls: list[str] = []

        def run_osa(script: str, _timeout: float) -> str:
            calls.append(script)
            return ""

        def resolve_target() -> logic_variants.ResolvedLogicTarget:
            return logic_variants.ResolvedLogicTarget(
                bundle_id="com.apple.mobilelogic",
                process_name="Logic Pro Creator Studio",
            )

        result = logic_variants.logic_process_osa_with_runner(
            "get position of front window",
            run_osa,
            resolve_target=resolve_target,
        )
        self.assertEqual(result, "")
        self.assertEqual(len(calls), 1)
        self.assertIn('tell application process "Logic Pro Creator Studio"', calls[0])
        self.assertNotIn('tell application process "Logic Pro"\n', calls[0])


if __name__ == "__main__":
    unittest.main()
