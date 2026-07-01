#!/usr/bin/env python3
# noqa: SIZE_OK - bootstrap helper coverage keeps focused fake MCP/bootstrap cases in one test module.
import json
import logic_session_bootstrap as bootstrap_module
import unittest
from unittest import mock

from logic_session_bootstrap import (
    BootstrapConfig,
    FreshSessionAssessment,
    UISnapshot,
    bootstrap_fresh_logic_session,
    detect_language,
    evaluate_fresh_session,
    _ui_snapshot_from_native_payload,
)


def make_config(expected_language="en", max_tracks=1):
    return BootstrapConfig(
        expected_language=expected_language,
        hide_apps=(),
        max_tracks=max_tracks,
        allow_launch=True,
        allow_new_project=True,
        force_new_project=False,
        confirm_new_track_dialog=True,
        timeout_sec=8.0,
        poll_interval_sec=0.35,
    )


def make_ui(**overrides):
    base = UISnapshot(
        frontmost_app="Logic Pro",
        logic_window_names=["Untitled 1 - Tracks"],
        logic_menu_items=["File", "Edit", "Track", "Navigate", "Record", "Mix", "View", "Window", "Help"],
        detected_language="en",
        system_events_error=None,
        project_picker_visible=False,
        new_track_dialog_visible=False,
        blocking_dialog_present=False,
    )
    values = base.__dict__.copy()
    values.update(overrides)
    return UISnapshot(**values)


def make_health(**overrides):
    health = {
        "logic_pro_running": True,
        "logic_pro_has_window": True,
        "logic_pro_has_document": True,
        "permissions": {
            "accessibility": True,
            "post_event_access": True,
        },
    }
    health.update(overrides)
    return health


def make_project(track_count=1, source="ax_live", name="Untitled 1"):
    return {
        "source": source,
        "data": {
            "name": name,
            "trackCount": track_count,
            "source": source,
        },
    }


def make_tracks(count=1, placeholder_count=0, ax_occluded=False):
    rows = []
    for index in range(count):
        rows.append(
            {
                "id": index,
                "name": f"Track {index + 1}",
                "placeholder": index < placeholder_count,
            }
        )
    return {
        "source": "ax_live",
        "ax_occluded": ax_occluded,
        "data": rows,
    }


class DetectLanguageTests(unittest.TestCase):
    def test_detects_english_menu(self):
        self.assertEqual(detect_language(["File", "Edit", "Track"]), "en")

    def test_detects_korean_menu(self):
        self.assertEqual(detect_language(["파일", "편집", "트랙"]), "ko")

    def test_returns_none_for_unknown_menu(self):
        self.assertIsNone(detect_language(["Archivo", "Editar", "Pista"]))


class BootstrapConfigTests(unittest.TestCase):
    def test_force_new_project_env_flag_defaults_off(self):
        config = BootstrapConfig.from_env(strict_live=True, env={})
        self.assertFalse(config.force_new_project)

    def test_force_new_project_env_flag_can_be_enabled(self):
        config = BootstrapConfig.from_env(
            strict_live=True,
            env={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "1"},
        )
        self.assertTrue(config.force_new_project)


class EvaluateFreshSessionTests(unittest.TestCase):
    def assert_reason(self, assessment: FreshSessionAssessment, reason: str):
        self.assertFalse(assessment.ok)
        self.assertEqual(assessment.reason, reason)

    def test_accepts_fresh_single_track_project(self):
        assessment = evaluate_fresh_session(
            ui=make_ui(),
            health=make_health(),
            project_payload=make_project(track_count=1),
            tracks_payload=make_tracks(count=1),
            region_count=0,
            config=make_config(),
        )
        self.assertTrue(assessment.ok)
        self.assertEqual(assessment.inferred_track_count, 1)

    def test_blocks_language_mismatch(self):
        assessment = evaluate_fresh_session(
            ui=make_ui(detected_language="ko"),
            health=make_health(),
            project_payload=make_project(track_count=1),
            tracks_payload=make_tracks(count=1),
            region_count=0,
            config=make_config(expected_language="en"),
        )
        self.assert_reason(assessment, "language_mismatch")

    def test_blocks_modal_project_picker(self):
        assessment = evaluate_fresh_session(
            ui=make_ui(
                project_picker_visible=True,
                blocking_dialog_present=True,
                logic_window_names=["Untitled 1 - Tracks", "Choose a Project"],
            ),
            health=make_health(),
            project_payload=make_project(track_count=1),
            tracks_payload=make_tracks(count=1),
            region_count=0,
            config=make_config(),
        )
        self.assert_reason(assessment, "blocking_dialog_present")

    def test_accepts_nonblocking_project_picker_after_live_track_materializes(self):
        assessment = evaluate_fresh_session(
            ui=make_ui(
                project_picker_visible=True,
                logic_window_names=["Untitled 1 - Tracks", "Choose a Project"],
            ),
            health=make_health(
                cache={"project": "Untitled 1 - Tracks", "track_count": 1},
            ),
            project_payload=make_project(track_count=1),
            tracks_payload=make_tracks(count=1),
            region_count=0,
            config=make_config(),
        )
        self.assertTrue(assessment.ok)
        self.assertEqual(assessment.inferred_track_count, 1)

    def test_blocks_nonblocking_project_picker_without_live_track_evidence(self):
        assessment = evaluate_fresh_session(
            ui=make_ui(
                project_picker_visible=True,
                logic_window_names=["Untitled 1 - Tracks", "Choose a Project"],
            ),
            health=make_health(
                cache={"project": "Untitled 1 - Tracks", "track_count": 0},
            ),
            project_payload=make_project(track_count=0),
            tracks_payload=make_tracks(count=0),
            region_count=0,
            config=make_config(),
        )
        self.assert_reason(assessment, "project_picker_visible")

    def test_blocks_hidden_blocking_dialog(self):
        assessment = evaluate_fresh_session(
            ui=make_ui(blocking_dialog_present=True),
            health=make_health(),
            project_payload=make_project(track_count=1),
            tracks_payload=make_tracks(count=1),
            region_count=0,
            config=make_config(),
        )
        self.assert_reason(assessment, "blocking_dialog_present")

    def test_blocks_placeholder_tracks(self):
        assessment = evaluate_fresh_session(
            ui=make_ui(),
            health=make_health(),
            project_payload=make_project(track_count=1),
            tracks_payload=make_tracks(count=1, placeholder_count=1),
            region_count=0,
            config=make_config(),
        )
        self.assert_reason(assessment, "tracks_not_live")

    def test_blocks_occluded_tracks(self):
        assessment = evaluate_fresh_session(
            ui=make_ui(),
            health=make_health(),
            project_payload=make_project(track_count=1),
            tracks_payload=make_tracks(count=1, ax_occluded=True),
            region_count=0,
            config=make_config(),
        )
        self.assert_reason(assessment, "ax_occluded")

    def test_blocks_polluted_session_when_track_count_exceeds_budget(self):
        assessment = evaluate_fresh_session(
            ui=make_ui(),
            health=make_health(),
            project_payload=make_project(track_count=3),
            tracks_payload=make_tracks(count=3),
            region_count=0,
            config=make_config(max_tracks=1),
        )
        self.assert_reason(assessment, "polluted_session")

    def test_blocks_existing_regions(self):
        assessment = evaluate_fresh_session(
            ui=make_ui(),
            health=make_health(),
            project_payload=make_project(track_count=1),
            tracks_payload=make_tracks(count=1),
            region_count=2,
            config=make_config(),
        )
        self.assert_reason(assessment, "existing_regions_present")

    def test_blocks_system_events_probe_failure_before_frontmost(self):
        assessment = evaluate_fresh_session(
            ui=make_ui(
                frontmost_app=None,
                logic_window_names=[],
                logic_menu_items=[],
                detected_language=None,
                system_events_error="osascript_exit_1: Not authorized to send Apple events to System Events. (-1743)",
            ),
            health=make_health(),
            project_payload=make_project(track_count=1),
            tracks_payload=make_tracks(count=1),
            region_count=0,
            config=make_config(),
        )
        self.assert_reason(assessment, "system_events_unavailable")
        self.assertIn("System Events", assessment.hint or "")

    def test_native_ui_snapshot_payload_maps_language_and_modal_markers(self):
        snapshot = _ui_snapshot_from_native_payload(
            {
                "frontmost_app": "Logic Pro",
                "frontmost_bundle_id": "com.apple.logic10",
                "logic_window_names": ["Untitled 1 - Tracks", "New Tracks"],
                "logic_menu_items": ["Apple", "Logic Pro", "File", "Edit", "Track", "Navigate"],
                "blocking_dialog_present": True,
                "error": None,
            }
        )
        self.assertIsNotNone(snapshot)
        assert snapshot is not None
        self.assertEqual(snapshot.detected_language, "en")
        self.assertTrue(snapshot.new_track_dialog_visible)
        self.assertTrue(snapshot.blocking_dialog_present)
        self.assertFalse(snapshot.project_picker_visible)
        self.assertIsNone(snapshot.system_events_error)

    def test_native_ui_snapshot_payload_preserves_hidden_blocking_dialog_flag(self):
        snapshot = _ui_snapshot_from_native_payload(
            {
                "frontmost_app": "Logic Pro",
                "frontmost_bundle_id": "com.apple.logic10",
                "logic_window_names": ["Untitled 1 - Tracks"],
                "logic_menu_items": ["Apple", "Logic Pro", "File", "Edit", "Track", "Navigate"],
                "blocking_dialog_present": True,
                "error": None,
            }
        )
        self.assertIsNotNone(snapshot)
        assert snapshot is not None
        self.assertFalse(snapshot.new_track_dialog_visible)
        self.assertTrue(snapshot.blocking_dialog_present)

    def test_native_ui_snapshot_payload_surfaces_ax_error(self):
        snapshot = _ui_snapshot_from_native_payload(
            {
                "frontmost_app": "Logic Pro",
                "frontmost_bundle_id": "com.apple.logic10",
                "logic_window_names": [],
                "logic_menu_items": [],
                "error": "accessibility_not_trusted",
            }
        )
        self.assertIsNotNone(snapshot)
        assert snapshot is not None
        self.assertEqual(snapshot.system_events_error, "accessibility_not_trusted")

    def test_native_ui_snapshot_payload_normalizes_logic_bundle_frontmost_name(self):
        snapshot = _ui_snapshot_from_native_payload(
            {
                "frontmost_app": "Logic\u00a0Pro",
                "frontmost_bundle_id": "com.apple.logic10",
                "logic_window_names": ["프로젝트 선택"],
                "logic_menu_items": ["Apple", "Logic\u00a0Pro", "파일", "편집", "트랙"],
                "error": None,
            }
        )
        self.assertIsNotNone(snapshot)
        assert snapshot is not None
        self.assertEqual(snapshot.frontmost_app, "Logic Pro")
        self.assertEqual(snapshot.detected_language, "ko")


class ActivationHelperTests(unittest.TestCase):
    def test_activate_logic_falls_back_to_open_when_osascript_fails(self):
        fallback_result = mock.Mock(returncode=0)
        with (
            mock.patch("logic_session_bootstrap._run_osascript", return_value=None) as run_osascript,
            mock.patch("logic_session_bootstrap.subprocess.run", return_value=fallback_result) as run_process,
        ):
            self.assertTrue(bootstrap_module._activate_logic())

        run_osascript.assert_called_once_with(
            [f'tell application "{bootstrap_module.LOGIC_APP_NAME}" to activate'],
            timeout_sec=2.0,
        )
        run_process.assert_called_once_with(
            ["/usr/bin/open", "-a", bootstrap_module.LOGIC_APP_NAME],
            capture_output=True,
            text=True,
            timeout=2.0,
            check=False,
        )


class DialogButtonHelperTests(unittest.TestCase):
    def test_click_dialog_button_uses_native_ax_helper(self):
        native_result = mock.Mock(returncode=0, stdout='{"ok":true}\n')
        with (
            mock.patch("logic_session_bootstrap.subprocess.run", return_value=native_result) as run_process,
            mock.patch("logic_session_bootstrap.time.sleep") as sleep,
        ):
            clicked = bootstrap_module._click_dialog_button(("Choose a Project",), ("Choose",))

        self.assertTrue(clicked)
        args, kwargs = run_process.call_args
        self.assertEqual(args[0][0], "/usr/bin/swift")
        self.assertTrue(args[0][1].endswith("logic_ax_button_press.swift"))
        self.assertEqual(
            json.loads(kwargs["input"]),
            {"windowMarkers": ["Choose a Project"], "buttonLabels": ["Choose"]},
        )
        sleep.assert_called_once_with(0.5)


class BootstrapFreshSessionTests(unittest.TestCase):
    def test_uses_configured_timeout_for_health_probe(self):
        health_timeouts: list[float | None] = []

        def encode_tool(payload):
            return {
                "result": {
                    "content": [{"type": "text", "text": json.dumps(payload)}],
                    "isError": False,
                }
            }

        def call_tool(tool, command, params, timeout):
            if tool == "logic_system" and command == "health":
                health_timeouts.append(timeout)
                if timeout is None or timeout < 8.0:
                    return None
                return encode_tool(make_health())
            if tool == "logic_system" and command == "refresh_cache":
                return encode_tool({"status": "ok"})
            self.fail(f"unexpected tool call: {tool}.{command}")

        def read_resource(uri):
            resources = {
                "logic://project/info": make_project(),
                "logic://tracks": make_tracks(),
                "logic://tracks/0/regions": [],
            }
            return {"result": {"contents": [{"text": json.dumps(resources[uri])}]}}

        def tool_text(response):
            if response is None:
                return ""
            return response["result"]["content"][0]["text"]

        def resource_text(response):
            return response["result"]["contents"][0]["text"]

        with (
            mock.patch("logic_session_bootstrap._activate_logic", return_value=True),
            mock.patch("logic_session_bootstrap.collect_ui_snapshot", return_value=make_ui()),
            mock.patch("logic_session_bootstrap.time.sleep"),
        ):
            result = bootstrap_fresh_logic_session(
                call_tool=call_tool,
                read_resource=read_resource,
                tool_text=tool_text,
                resource_text=resource_text,
                strict_live=True,
                log=lambda _: None,
                env={"LOGIC_PRO_MCP_BOOTSTRAP_TIMEOUT_SEC": "8.0"},
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertGreaterEqual(len(health_timeouts), 2)
        self.assertEqual(health_timeouts[0], 8.0)

    def test_launch_observation_timeouts_are_clamped_to_remaining_deadline(self):
        health_timeouts: list[float | None] = []

        class FakeClock:
            def __init__(self):
                self.now = 0.0

            def time(self):
                current = self.now
                self.now += 1.0
                return current

        def encode_tool(payload):
            return {
                "result": {
                    "content": [{"type": "text", "text": json.dumps(payload)}],
                    "isError": False,
                }
            }

        def call_tool(tool, command, params, timeout):
            if tool == "logic_system" and command == "health":
                health_timeouts.append(timeout)
                return encode_tool(
                    make_health(
                        logic_pro_running=False,
                        logic_pro_has_window=False,
                        logic_pro_has_document=False,
                    )
                )
            if tool == "logic_project" and command == "launch":
                return encode_tool({"success": True})
            self.fail(f"unexpected tool call: {tool}.{command}")

        def tool_text(response):
            return response["result"]["content"][0]["text"]

        fake_clock = FakeClock()
        with (
            mock.patch("logic_session_bootstrap.time.sleep"),
            mock.patch("logic_session_bootstrap.time.time", side_effect=fake_clock.time),
        ):
            result = bootstrap_fresh_logic_session(
                call_tool=call_tool,
                read_resource=lambda uri: self.fail(f"unexpected read_resource: {uri}"),
                tool_text=tool_text,
                resource_text=lambda response: "",
                strict_live=True,
                log=lambda _: None,
                env={"LOGIC_PRO_MCP_BOOTSTRAP_TIMEOUT_SEC": "8.0"},
            )

        self.assertFalse(result.ok)
        self.assertEqual(result.reason, "logic_launch_timeout")
        loop_health_timeouts = health_timeouts[1:-1]
        self.assertTrue(loop_health_timeouts, health_timeouts)
        self.assertTrue(all(timeout is not None and timeout < 8.0 for timeout in loop_health_timeouts))


if __name__ == "__main__":
    unittest.main()
