#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import unittest
from unittest import mock

import logic_bounce
from logic_bounce import click_bounce_settings_confirm


def _completed_jxa_snapshot(snapshot) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(
        args=["osascript", "-l", "JavaScript"],
        returncode=0,
        stdout=json.dumps(snapshot),
        stderr="",
    )


class LogicBounceUITests(unittest.TestCase):
    def test_send_ui_events_drives_native_driver_without_external_click_tool(self):
        class FakeDriver:
            def __init__(self):
                self.calls = []

            def click(self, x, y):
                self.calls.append(("click", x, y))
                return True

            def key_down(self, key):
                self.calls.append(("key_down", key))
                return True

            def key_up(self, key):
                self.calls.append(("key_up", key))
                return True

            def key_press(self, key):
                self.calls.append(("key_press", key))
                return True

            def type_text(self, text):
                self.calls.append(("type_text", text))
                return True

            def reset_modifiers(self):
                self.calls.append(("reset_modifiers",))

        driver = FakeDriver()
        self.assertTrue(logic_bounce.send_ui_events("c:10,20", "kd:cmd", "t:a", "ku:cmd", "kp:delete", driver=driver))
        self.assertEqual(
            driver.calls,
            [
                ("click", 10, 20),
                ("key_down", "cmd"),
                ("type_text", "a"),
                ("key_up", "cmd"),
                ("key_press", "delete"),
                ("reset_modifiers",),
            ],
        )

    def test_send_ui_events_rejects_unknown_command(self):
        driver = mock.Mock()
        driver.reset_modifiers = mock.Mock()
        self.assertFalse(logic_bounce.send_ui_events("bad:1", driver=driver))
        driver.reset_modifiers.assert_called_once_with()

    def test_click_bounce_settings_confirm_accepts_korean_label(self):
        calls = []
        snapshot = {
            "status": "ok",
            "button_names": ["Cancel", "확인"],
            "text_field_names": [],
            "text_field_count": 0,
            "static_texts": ["PCM", "Realtime"],
        }

        def fake_osa(script, timeout=logic_bounce.OSA_TIMEOUT_SEC):
            calls.append(script)
            return "ok" if '"확인"' in script else ""

        self.assertTrue(
            click_bounce_settings_confirm(
                run_osa=fake_osa,
                run_jxa_fn=lambda source, **kwargs: _completed_jxa_snapshot(snapshot),
            )
        )
        self.assertEqual(len(calls), 2)

    def test_click_bounce_settings_confirm_returns_false_when_no_label_matches(self):
        snapshot = {
            "status": "ok",
            "button_names": ["Cancel", "OK"],
            "text_field_names": [],
            "text_field_count": 0,
            "static_texts": ["PCM", "Realtime"],
        }
        self.assertFalse(
            click_bounce_settings_confirm(
                run_osa=lambda script, timeout=0: "",
                run_jxa_fn=lambda source, **kwargs: _completed_jxa_snapshot(snapshot),
            )
        )

    def test_click_bounce_settings_confirm_rejects_bounce_titled_non_dialog(self):
        calls = []
        snapshot = {
            "status": "ok",
            "button_names": ["Cancel", "OK"],
            "text_field_names": [],
            "text_field_count": 0,
            "static_texts": ["Bounce", "Project Notes"],
        }

        def fake_osa(script, timeout=logic_bounce.OSA_TIMEOUT_SEC):
            calls.append(script)
            return "ok"

        self.assertFalse(
            click_bounce_settings_confirm(
                run_osa=fake_osa,
                run_jxa_fn=lambda source, **kwargs: _completed_jxa_snapshot(snapshot),
            )
        )
        self.assertEqual(calls, [])

    def test_bounce_dialog_present_only_accepts_front_container_titles(self):
        def fake_osa(script, timeout=logic_bounce.OSA_TIMEOUT_SEC):
            if "sheet 1 of front window" in script:
                return ""
            if "name of front window" in script:
                return "Tracks"
            return ""

        self.assertFalse(logic_bounce.bounce_dialog_present(run_osa=fake_osa))

    def test_open_bounce_dialog_falls_back_to_file_menu_when_cmd_b_misses(self):
        state = {"dialog_visible": False, "strategies": []}

        def fake_osa(script, timeout=logic_bounce.OSA_TIMEOUT_SEC):
            if "key code 11" in script:
                state["strategies"].append("key_command")
                return ""
            if 'menu item "바운스"' in script or 'menu item "Bounce"' in script:
                state["strategies"].append("file_menu")
                state["dialog_visible"] = True
                return "ok"
            if "sheet 1 of front window" in script:
                return "Bounce" if state["dialog_visible"] else ""
            if "name of front window" in script:
                return "Tracks"
            return ""

        opened, strategies = logic_bounce.open_bounce_dialog(run_osa=fake_osa, sleep_fn=lambda _: None)
        self.assertTrue(opened)
        self.assertEqual(strategies, ["key_command", "file_menu"])
        self.assertEqual(state["strategies"], ["key_command", "file_menu"])

    def test_save_panel_present_detects_bounce_save_panel_snapshot(self):
        snapshot = {
            "status": "ok",
            "button_names": ["Cancel", "Bounce"],
            "text_field_names": ["Save As:"],
            "text_field_count": 1,
            "static_texts": ["Save As:"],
        }

        self.assertTrue(logic_bounce.save_panel_present(run_jxa_fn=lambda source, **kwargs: _completed_jxa_snapshot(snapshot)))

    def test_save_panel_present_rejects_settings_dialog_snapshot(self):
        snapshot = {
            "status": "ok",
            "button_names": ["Cancel", "OK"],
            "text_field_names": [],
            "text_field_count": 0,
            "static_texts": ["PCM", "Realtime"],
        }

        self.assertFalse(logic_bounce.save_panel_present(run_jxa_fn=lambda source, **kwargs: _completed_jxa_snapshot(snapshot)))

    def test_bounce_settings_present_detects_structural_settings_dialog(self):
        snapshot = {
            "status": "ok",
            "button_names": ["Cancel", "OK"],
            "text_field_names": [],
            "text_field_count": 0,
            "static_texts": ["PCM", "Realtime", "Offline"],
        }

        self.assertTrue(logic_bounce.bounce_settings_present(run_jxa_fn=lambda source, **kwargs: _completed_jxa_snapshot(snapshot)))

    def test_save_panel_present_rejects_generic_save_panel_snapshot(self):
        snapshot = {
            "status": "ok",
            "button_names": ["Cancel", "Save"],
            "text_field_names": ["Save As:"],
            "text_field_count": 1,
            "static_texts": ["Save As:"],
        }

        self.assertFalse(logic_bounce.save_panel_present(run_jxa_fn=lambda source, **kwargs: _completed_jxa_snapshot(snapshot)))

    def test_save_panel_present_returns_false_when_jxa_times_out(self):
        def raising_run_jxa(source, **kwargs):
            raise subprocess.TimeoutExpired(cmd=["osascript", "-l", "JavaScript"], timeout=12.0)

        self.assertFalse(logic_bounce.save_panel_present(run_jxa_fn=raising_run_jxa))

    def test_bounce_focus_diagnostics_uses_injected_snapshot_runner(self):
        snapshot = {
            "status": "ok",
            "button_names": ["Cancel", "Bounce"],
            "text_field_names": ["Save As:"],
            "text_field_count": 1,
            "static_texts": ["Save As:"],
        }

        def fake_osa(script, timeout=logic_bounce.OSA_TIMEOUT_SEC):
            if "name of windows as text" in script:
                return "Bounce\nTracks"
            if "frontmost is true" in script:
                return "Logic Pro"
            if "name of sheet 1 of front window" in script:
                return "Bounce"
            if "name of front window" in script:
                return "Tracks"
            return ""

        diagnostics = logic_bounce.bounce_focus_diagnostics(
            run_osa=fake_osa,
            run_jxa_fn=lambda source, **kwargs: _completed_jxa_snapshot(snapshot),
        )
        self.assertEqual(diagnostics["frontmost_app"], "Logic Pro")
        self.assertEqual(diagnostics["logic_window_names"], ["Bounce", "Tracks"])
        self.assertEqual(diagnostics["save_panel_snapshot"]["status"], "ok")
