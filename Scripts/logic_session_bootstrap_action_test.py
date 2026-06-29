#!/usr/bin/env python3
# noqa: SIZE_OK - Action-level bootstrap coverage keeps the focused fake MCP/JXA cases together.
import json
import unittest
from unittest import mock

import logic_session_bootstrap as bootstrap_module
from logic_session_bootstrap import bootstrap_fresh_logic_session

FORCE_NEW_ENV = {
    "LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "1",
    "LOGIC_PRO_MCP_BOOTSTRAP_ALLOW_NEW_PROJECT": "1",
    "LOGIC_PRO_MCP_BOOTSTRAP_TIMEOUT_SEC": "1",
    "LOGIC_PRO_MCP_BOOTSTRAP_POLL_SEC": "0.1",
}


def make_tool_response(text, is_error=False):
    return {"result": {"isError": is_error, "content": [{"type": "text", "text": text}]}}


def make_resource_response(text):
    return {"result": {"contents": [{"text": text}]}}


def tool_text(response):
    return response["result"]["content"][0]["text"]


def resource_text(response):
    return response["result"]["contents"][0]["text"]


def make_ui():
    return bootstrap_module.UISnapshot(
        frontmost_app="Logic Pro",
        logic_window_names=["Untitled 1 - Tracks"],
        logic_menu_items=["File", "Edit", "Track", "Navigate", "Record", "Mix", "View", "Window", "Help"],
        detected_language="en",
        system_events_error=None,
        project_picker_visible=False,
        new_track_dialog_visible=False,
        blocking_dialog_present=False,
    )


def make_health(has_document):
    return {
        "logic_pro_running": True,
        "logic_pro_has_window": True,
        "logic_pro_has_document": has_document,
        "permissions": {"accessibility": True, "post_event_access": True},
        "cache": {
            "project": "Untitled 1 - Tracks" if has_document else "",
            "track_count": 1 if has_document else 0,
        },
    }


def make_project_payload():
    return {
        "source": "ax_live",
        "data": {"name": "Untitled 1", "trackCount": 1, "source": "ax_live"},
    }


def make_tracks_payload():
    return {
        "source": "ax_live",
        "ax_occluded": False,
        "data": [{"id": 0, "name": "Track 1", "placeholder": False}],
    }


def default_read_resource(uri):
    if uri == "logic://project/info":
        return make_resource_response(json.dumps(make_project_payload()))
    if uri == "logic://tracks":
        return make_resource_response(json.dumps(make_tracks_payload()))
    if uri == "logic://tracks/0/regions":
        return make_resource_response("[]")
    return make_resource_response("{}")


def run_force_new_bootstrap(
    *,
    call_tool,
    document_probe,
    read_resource=default_read_resource,
    env_overrides=None,
    ui_snapshot_factory=make_ui,
    activate_logic=lambda: True,
    click_project_picker_choose_button=lambda: False,
):
    previous_collect_ui_snapshot = bootstrap_module.collect_ui_snapshot
    previous_activate_logic = bootstrap_module._activate_logic
    previous_document_probe = bootstrap_module._logic_document_open_probe
    previous_click_project_picker_choose_button = bootstrap_module._click_project_picker_choose_button
    env = dict(FORCE_NEW_ENV)
    if env_overrides:
        env.update(env_overrides)
    try:
        bootstrap_module.collect_ui_snapshot = ui_snapshot_factory
        bootstrap_module._activate_logic = activate_logic
        bootstrap_module._logic_document_open_probe = lambda timeout_sec=2.0: document_probe(timeout_sec)
        bootstrap_module._click_project_picker_choose_button = click_project_picker_choose_button
        return bootstrap_fresh_logic_session(
            call_tool=call_tool,
            read_resource=read_resource,
            tool_text=tool_text,
            resource_text=resource_text,
            strict_live=True,
            log=lambda _: None,
            env=env,
        )
    finally:
        bootstrap_module.collect_ui_snapshot = previous_collect_ui_snapshot
        bootstrap_module._activate_logic = previous_activate_logic
        bootstrap_module._logic_document_open_probe = previous_document_probe
        bootstrap_module._click_project_picker_choose_button = previous_click_project_picker_choose_button


class BootstrapFreshSessionActionTests(unittest.TestCase):
    def test_close_error_is_accepted_when_health_confirms_no_document(self):
        state = {"closed": False, "created": False}

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                has_document = state["created"] or not state["closed"]
                return make_tool_response(json.dumps(make_health(has_document)))
            if tool == "logic_project" and command == "close":
                state["closed"] = True
                return make_tool_response('{"success":true,"verified":false}', is_error=True)
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":false}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            return make_tool_response("{}")

        result = run_force_new_bootstrap(
            call_tool=call_tool,
            document_probe=lambda timeout_sec: (
                (None, "probe_unavailable") if state["closed"] and not state["created"] else (True, None)
            ),
        )

        self.assertTrue(result.ok, result.as_dict())
        self.assertIn("logic_project.close:saving=no", result.actions)
        self.assertIn("logic_project.new", result.actions)

    def test_direct_document_probe_unblocks_stale_close_health(self):
        state = {"closed": False, "created": False}

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(make_health(True)))
            if tool == "logic_project" and command == "close":
                state["closed"] = True
                return make_tool_response('{"success":true,"verified":false}')
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":false}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            return make_tool_response("{}")

        result = run_force_new_bootstrap(
            call_tool=call_tool,
            document_probe=lambda timeout_sec: (
                (False, None) if state["closed"] and not state["created"] else (True, None)
            ),
        )

        self.assertTrue(result.ok, result.as_dict())
        self.assertIn("logic_project.close:saving=no", result.actions)
        self.assertIn("logic_project.new", result.actions)

    def test_initial_false_health_still_closes_when_direct_probe_sees_document(self):
        state = {"closed": False, "created": False}

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(make_health(state["created"])))
            if tool == "logic_project" and command == "close":
                state["closed"] = True
                return make_tool_response('{"success":true,"verified":false}')
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":false}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            return make_tool_response("{}")

        result = run_force_new_bootstrap(
            call_tool=call_tool,
            document_probe=lambda timeout_sec: (
                (True, None) if not state["closed"] and not state["created"] else (False, None)
            ),
        )

        self.assertTrue(result.ok, result.as_dict())
        self.assertIn("logic_project.close:saving=no", result.actions)
        self.assertIn("logic_project.new", result.actions)

    def test_blocks_when_close_is_never_observed(self):
        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(make_health(True)))
            if tool == "logic_project" and command == "close":
                return make_tool_response('{"success":true,"verified":false}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            return make_tool_response("{}")

        result = run_force_new_bootstrap(
            call_tool=call_tool,
            document_probe=lambda timeout_sec: (True, None),
        )

        self.assertFalse(result.ok)
        self.assertEqual(result.reason, "fresh_project_close_timeout")
        self.assertIn("logic_project.close:saving=no", result.actions)
        self.assertNotIn("logic_project.new", result.actions)

    def test_force_new_blocks_when_initial_document_state_is_unconfirmed(self):
        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                partial_health = make_health(False)
                partial_health.pop("logic_pro_has_document", None)
                return make_tool_response(json.dumps(partial_health))
            return make_tool_response("{}")

        result = run_force_new_bootstrap(
            call_tool=call_tool,
            read_resource=lambda uri: make_resource_response("{}"),
            document_probe=lambda timeout_sec: (None, "probe_unavailable"),
            env_overrides={
                "LOGIC_PRO_MCP_BOOTSTRAP_TIMEOUT_SEC": FORCE_NEW_ENV["LOGIC_PRO_MCP_BOOTSTRAP_TIMEOUT_SEC"],
                "LOGIC_PRO_MCP_BOOTSTRAP_POLL_SEC": FORCE_NEW_ENV["LOGIC_PRO_MCP_BOOTSTRAP_POLL_SEC"],
            },
            ui_snapshot_factory=lambda: bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=["Logic Pro"],
                logic_menu_items=["File", "Edit", "Track", "Navigate", "Record", "Mix", "View", "Window", "Help"],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=False,
                blocking_dialog_present=False,
            ),
        )

        self.assertFalse(result.ok)
        self.assertEqual(result.reason, "fresh_project_state_unconfirmed")
        self.assertIn("probe_unavailable", result.hint or "")
        self.assertNotIn("logic_project.new", result.actions)

    def test_missing_health_flag_does_not_mask_open_document(self):
        state = {"closed": False}

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                if not state["closed"]:
                    return make_tool_response(json.dumps(make_health(True)))
                partial_health = make_health(True)
                partial_health.pop("logic_pro_has_document", None)
                return make_tool_response(json.dumps(partial_health))
            if tool == "logic_project" and command == "close":
                state["closed"] = True
                return make_tool_response('{"success":true,"verified":false}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            return make_tool_response("{}")

        result = run_force_new_bootstrap(
            call_tool=call_tool,
            document_probe=lambda timeout_sec: (True, None),
        )

        self.assertFalse(result.ok)
        self.assertEqual(result.reason, "fresh_project_close_timeout")
        self.assertIn("logic_project.close:saving=no", result.actions)
        self.assertNotIn("logic_project.new", result.actions)

    def test_health_false_does_not_mask_open_document_after_close(self):
        state = {"closed": False}

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                if not state["closed"]:
                    return make_tool_response(json.dumps(make_health(True)))
                return make_tool_response(json.dumps(make_health(False)))
            if tool == "logic_project" and command == "close":
                state["closed"] = True
                return make_tool_response('{"success":true,"verified":false}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            return make_tool_response("{}")

        result = run_force_new_bootstrap(
            call_tool=call_tool,
            document_probe=lambda timeout_sec: (True, None),
        )

        self.assertFalse(result.ok)
        self.assertEqual(result.reason, "fresh_project_close_timeout")
        self.assertIn("logic_project.close:saving=no", result.actions)
        self.assertNotIn("logic_project.new", result.actions)

    def test_close_observation_timeouts_are_clamped_to_remaining_deadline(self):
        recorded_health_timeouts = []
        recorded_probe_timeouts = []

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                if timeout is not None and len(recorded_health_timeouts) > 0:
                    recorded_health_timeouts.append(timeout)
                elif timeout is not None:
                    recorded_health_timeouts.append(timeout)
                return make_tool_response(json.dumps(make_health(True)))
            if tool == "logic_project" and command == "close":
                return make_tool_response('{"success":true,"verified":false}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            return make_tool_response("{}")

        def document_probe(timeout_sec):
            recorded_probe_timeouts.append(timeout_sec)
            return (True, None)

        result = run_force_new_bootstrap(
            call_tool=call_tool,
            document_probe=document_probe,
            env_overrides={
                "LOGIC_PRO_MCP_BOOTSTRAP_TIMEOUT_SEC": "1.0",
                "LOGIC_PRO_MCP_BOOTSTRAP_POLL_SEC": "0.1",
            },
        )

        self.assertFalse(result.ok)
        self.assertEqual(result.reason, "fresh_project_close_timeout")
        loop_health_timeouts = recorded_health_timeouts[1:]
        self.assertTrue(loop_health_timeouts, recorded_health_timeouts)
        self.assertTrue(all(timeout <= 1.0 for timeout in loop_health_timeouts), loop_health_timeouts)
        self.assertTrue(recorded_probe_timeouts, recorded_probe_timeouts)
        self.assertTrue(all(timeout <= 1.0 for timeout in recorded_probe_timeouts), recorded_probe_timeouts)

    def test_close_observation_uses_full_configured_health_budget(self):
        recorded_health_timeouts = []

        class FakeClock:
            def __init__(self):
                self.now = 0.0

            def time(self):
                current = self.now
                self.now += 1.0
                return current

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                recorded_health_timeouts.append(timeout)
                return make_tool_response(json.dumps(make_health(True)))
            if tool == "logic_project" and command == "close":
                return make_tool_response('{"success":true,"verified":false}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            return make_tool_response("{}")

        fake_clock = FakeClock()
        with (
            mock.patch("logic_session_bootstrap.time.sleep"),
            mock.patch("logic_session_bootstrap.time.time", side_effect=fake_clock.time),
        ):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (True, None),
                env_overrides={
                    "LOGIC_PRO_MCP_BOOTSTRAP_TIMEOUT_SEC": "8.0",
                    "LOGIC_PRO_MCP_BOOTSTRAP_POLL_SEC": "0.1",
                },
            )

        self.assertFalse(result.ok)
        self.assertEqual(result.reason, "fresh_project_close_timeout")
        loop_health_timeouts = recorded_health_timeouts[1:]
        self.assertTrue(loop_health_timeouts, recorded_health_timeouts)
        self.assertGreater(max(loop_health_timeouts), 5.0, loop_health_timeouts)

    def test_force_new_reactivates_logic_before_first_track_creation(self):
        state = {
            "closed": False,
            "created": False,
            "frontmost_app": "Logic Pro",
            "track_created": False,
            "activate_calls": 0,
        }

        def make_ui_snapshot():
            return bootstrap_module.UISnapshot(
                frontmost_app=state["frontmost_app"],
                logic_window_names=["Untitled - Tracks"],
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=False,
                blocking_dialog_present=False,
            )

        def activate_logic():
            state["activate_calls"] += 1
            state["frontmost_app"] = "Logic Pro"
            return True

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                has_document = (not state["closed"]) or state["created"] or state["track_created"]
                return make_tool_response(json.dumps(make_health(has_document)))
            if tool == "logic_project" and command == "close":
                state["closed"] = True
                return make_tool_response('{"success":true,"verified":false}')
            if tool == "logic_project" and command == "new":
                state["created"] = True
                state["frontmost_app"] = "UserNotificationCenter"
                return make_tool_response('{"success":true,"verified":false}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                if state["frontmost_app"] != "Logic Pro":
                    return make_tool_response(
                        '{"success":true,"verified":false,"reason":"readback_unavailable"}',
                        is_error=True,
                    )
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if state["created"] and not state["track_created"]:
                state["frontmost_app"] = "UserNotificationCenter"
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        result = run_force_new_bootstrap(
            call_tool=call_tool,
            document_probe=lambda timeout_sec: (
                (True, None)
                if (not state["closed"]) and (not state["created"]) and (not state["track_created"])
                else (False, None)
            ),
            read_resource=read_resource,
            ui_snapshot_factory=make_ui_snapshot,
            activate_logic=activate_logic,
        )

        self.assertTrue(result.ok, result.as_dict())
        self.assertGreaterEqual(state["activate_calls"], 2)
        self.assertIn("logic_tracks.create_instrument", result.actions)

    def test_force_new_waits_for_logic_focus_settle_before_first_track_creation(self):
        state = {
            "closed": False,
            "created": False,
            "frontmost_app": "Logic Pro",
            "track_created": False,
            "activate_calls": 0,
            "activation_pending": False,
        }

        def make_ui_snapshot():
            frontmost_app = (
                "UserNotificationCenter" if state["activation_pending"] else state["frontmost_app"]
            )
            return bootstrap_module.UISnapshot(
                frontmost_app=frontmost_app,
                logic_window_names=["Untitled - Tracks"],
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=False,
                blocking_dialog_present=False,
            )

        def activate_logic():
            state["activate_calls"] += 1
            state["activation_pending"] = True
            return True

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                has_document = (not state["closed"]) or state["created"] or state["track_created"]
                return make_tool_response(json.dumps(make_health(has_document)))
            if tool == "logic_project" and command == "close":
                state["closed"] = True
                return make_tool_response('{"success":true,"verified":false}')
            if tool == "logic_project" and command == "new":
                state["created"] = True
                state["frontmost_app"] = "UserNotificationCenter"
                return make_tool_response('{"success":true,"verified":false}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                if make_ui_snapshot().frontmost_app != "Logic Pro":
                    return make_tool_response(
                        '{"success":true,"verified":false,"reason":"readback_unavailable"}',
                        is_error=True,
                    )
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def fake_sleep(_duration):
            if state["activation_pending"]:
                state["activation_pending"] = False
                state["frontmost_app"] = "Logic Pro"

        previous_sleep = bootstrap_module.time.sleep
        try:
            bootstrap_module.time.sleep = fake_sleep
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (
                    (True, None)
                    if (not state["closed"]) and (not state["created"]) and (not state["track_created"])
                    else (False, None)
                ),
                read_resource=read_resource,
                ui_snapshot_factory=make_ui_snapshot,
                activate_logic=activate_logic,
            )
        finally:
            bootstrap_module.time.sleep = previous_sleep

        self.assertTrue(result.ok, result.as_dict())
        self.assertGreaterEqual(state["activate_calls"], 1)
        self.assertIn("logic_tracks.create_instrument", result.actions)

    def test_force_new_confirms_hidden_blocking_dialog_before_first_track_creation(self):
        state = {
            "created": False,
            "track_created": False,
            "blocking_dialog_present": False,
            "send_return_calls": 0,
        }

        def make_ui_snapshot():
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=["Untitled - Tracks"],
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=False,
                blocking_dialog_present=state["blocking_dialog_present"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(make_health(state["created"] or state["track_created"])))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                state["blocking_dialog_present"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                if state["blocking_dialog_present"]:
                    return make_tool_response(
                        '{"success":false,"error":"unsupported_state","failure_stage":"preflight_blocking_dialog","blocking_dialog_present":true}',
                        is_error=True,
                    )
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        with mock.patch(
            "logic_session_bootstrap._send_return_key",
            side_effect=lambda: state.update(
                blocking_dialog_present=False,
                send_return_calls=state["send_return_calls"] + 1,
            ) or True,
        ):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: ((False, None) if state["created"] or state["track_created"] else (True, None)),
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0"},
                read_resource=read_resource,
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertEqual(state["send_return_calls"], 1)
        self.assertTrue(state["track_created"])
        self.assertIn("confirm_hidden_blocking_dialog:return", result.actions)

    def test_force_new_clears_initial_hidden_blocking_dialog_before_close(self):
        state = {
            "closed": False,
            "created": False,
            "track_created": False,
            "blocking_dialog_present": True,
            "send_return_calls": 0,
        }

        def make_ui_snapshot():
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=["Untitled - Tracks"],
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=False,
                blocking_dialog_present=state["blocking_dialog_present"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(make_health((not state["closed"]) or state["created"] or state["track_created"])))
            if tool == "logic_project" and command == "close":
                if state["blocking_dialog_present"]:
                    return make_tool_response(
                        '{"success":false,"error":"unsupported_state","failure_stage":"preflight_blocking_dialog","blocking_dialog_present":true}',
                        is_error=True,
                    )
                state["closed"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        with mock.patch(
            "logic_session_bootstrap._send_return_key",
            side_effect=lambda: state.update(
                blocking_dialog_present=False,
                send_return_calls=state["send_return_calls"] + 1,
            ) or True,
        ):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (
                    (True, None)
                    if (not state["closed"]) and (not state["created"]) and (not state["track_created"])
                    else (False, None)
                ),
                ui_snapshot_factory=make_ui_snapshot,
                read_resource=read_resource,
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertEqual(state["send_return_calls"], 1)
        self.assertTrue(state["closed"])
        self.assertTrue(state["track_created"])
        self.assertIn("clear_initial_blocking_dialog:return", result.actions)
        self.assertIn("logic_project.close:saving=no", result.actions)

    def test_force_new_dismisses_initial_import_dialog_before_close(self):
        state = {
            "closed": False,
            "created": False,
            "track_created": False,
            "blocking_dialog_present": True,
            "import_dialog_visible": True,
            "cancel_button_clicks": 0,
        }

        def make_ui_snapshot():
            window_names = ["Untitled - Tracks"]
            if state["import_dialog_visible"]:
                window_names = ["Import", *window_names]
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=False,
                blocking_dialog_present=state["blocking_dialog_present"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(make_health((not state["closed"]) or state["created"] or state["track_created"])))
            if tool == "logic_project" and command == "close":
                if state["blocking_dialog_present"]:
                    return make_tool_response(
                        '{"success":false,"error":"unsupported_state","failure_stage":"preflight_blocking_dialog","blocking_dialog_present":true}',
                        is_error=True,
                    )
                state["closed"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def click_safe_dialog_cancel_button():
            state["cancel_button_clicks"] += 1
            state["import_dialog_visible"] = False
            state["blocking_dialog_present"] = False
            return True

        with mock.patch(
            "logic_session_bootstrap._click_safe_dialog_cancel_button",
            side_effect=click_safe_dialog_cancel_button,
        ), mock.patch("logic_session_bootstrap._send_escape_key", side_effect=AssertionError("Cancel button should be used before Escape")), mock.patch(
            "logic_session_bootstrap._send_return_key",
            side_effect=AssertionError("Import dialog must not be dismissed with Return"),
        ):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (
                    (True, None)
                    if (not state["closed"]) and (not state["created"]) and (not state["track_created"])
                    else (False, None)
                ),
                ui_snapshot_factory=make_ui_snapshot,
                read_resource=read_resource,
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertEqual(state["cancel_button_clicks"], 1)
        self.assertTrue(state["closed"])
        self.assertTrue(state["track_created"])
        self.assertIn("dismiss_safe_blocking_dialog:cancel_button", result.actions)
        self.assertIn("logic_project.close:saving=no", result.actions)

    def test_force_new_dismisses_visible_save_dialog_before_close(self):
        state = {
            "closed": False,
            "created": False,
            "track_created": False,
            "blocking_dialog_present": True,
            "save_dialog_visible": False,
            "send_return_calls": 0,
            "cancel_button_clicks": 0,
        }

        def make_ui_snapshot():
            window_names = ["Untitled - Tracks"]
            if state["save_dialog_visible"]:
                window_names = ["Save", *window_names]
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=False,
                blocking_dialog_present=state["blocking_dialog_present"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(make_health((not state["closed"]) or state["created"] or state["track_created"])))
            if tool == "logic_project" and command == "close":
                if state["blocking_dialog_present"]:
                    return make_tool_response(
                        '{"success":false,"error":"unsupported_state","failure_stage":"preflight_blocking_dialog","blocking_dialog_present":true}',
                        is_error=True,
                    )
                state["closed"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            state["save_dialog_visible"] = True
            state["blocking_dialog_present"] = True
            return True

        def click_save_dialog_cancel_button():
            state["cancel_button_clicks"] += 1
            state["save_dialog_visible"] = False
            state["blocking_dialog_present"] = False
            return True

        with (
            mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key),
            mock.patch(
                "logic_session_bootstrap._click_save_dialog_cancel_button",
                side_effect=click_save_dialog_cancel_button,
            ),
        ):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (
                    (True, None)
                    if (not state["closed"]) and (not state["created"]) and (not state["track_created"])
                    else (False, None)
                ),
                ui_snapshot_factory=make_ui_snapshot,
                read_resource=read_resource,
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertEqual(state["send_return_calls"], 1)
        self.assertEqual(state["cancel_button_clicks"], 1)
        self.assertTrue(state["closed"])
        self.assertTrue(state["track_created"])
        self.assertIn("dismiss_save_dialog:cancel_button", result.actions)

    def test_force_new_save_dialog_escape_fallback_when_cancel_button_unmatched(self):
        # #187: Logic's Save prompt sometimes exposes buttons with no AX name, so
        # the Cancel marker match is a no-op and the prompt stays visible. The
        # bootstrap must fall back to Escape (Cancel-before-Escape) and recover,
        # rather than dead-ending on save_dialog_dismiss_failed.
        state = {
            "closed": False,
            "created": False,
            "track_created": False,
            "blocking_dialog_present": True,
            "save_dialog_visible": False,
            "send_return_calls": 0,
            "cancel_button_clicks": 0,
            "escape_calls": 0,
        }

        def make_ui_snapshot():
            window_names = ["Untitled - Tracks"]
            if state["save_dialog_visible"]:
                window_names = ["Save", *window_names]
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple", "Logic Pro", "File", "Edit", "Track", "Navigate",
                    "Record", "Mix", "View", "Window", "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=False,
                blocking_dialog_present=state["blocking_dialog_present"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(make_health((not state["closed"]) or state["created"] or state["track_created"])))
            if tool == "logic_project" and command == "close":
                if state["blocking_dialog_present"]:
                    return make_tool_response(
                        '{"success":false,"error":"unsupported_state","failure_stage":"preflight_blocking_dialog","blocking_dialog_present":true}',
                        is_error=True,
                    )
                state["closed"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                return make_resource_response(json.dumps({
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }))
            if uri == "logic://tracks":
                return make_resource_response(json.dumps({
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"] else []
                    ),
                }))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            state["save_dialog_visible"] = True
            state["blocking_dialog_present"] = True
            return True

        def click_save_dialog_cancel_button():
            # Cancel "succeeds" (a button was pressed) but the prompt does NOT
            # clear — the real-world missing-value-button no-op.
            state["cancel_button_clicks"] += 1
            return True

        def send_escape_key():
            state["escape_calls"] += 1
            state["save_dialog_visible"] = False
            state["blocking_dialog_present"] = False
            return True

        with (
            mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key),
            mock.patch(
                "logic_session_bootstrap._click_save_dialog_cancel_button",
                side_effect=click_save_dialog_cancel_button,
            ),
            mock.patch("logic_session_bootstrap._send_escape_key", side_effect=send_escape_key),
        ):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (
                    (True, None)
                    if (not state["closed"]) and (not state["created"]) and (not state["track_created"])
                    else (False, None)
                ),
                ui_snapshot_factory=make_ui_snapshot,
                read_resource=read_resource,
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertEqual(state["cancel_button_clicks"], 1)
        self.assertEqual(state["escape_calls"], 1)
        self.assertTrue(state["closed"])
        self.assertTrue(state["track_created"])
        # Cancel was tried first, then Escape resolved it.
        self.assertIn("dismiss_save_dialog:cancel_button", result.actions)
        self.assertIn("dismiss_save_dialog:escape_fallback", result.actions)

    def test_force_new_closes_arrange_window_when_document_probe_reports_false(self):
        state = {
            "closed": False,
            "created": False,
            "track_created": False,
        }

        def make_ui_snapshot():
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=["Untitled - Tracks"],
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=False,
                blocking_dialog_present=False,
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(make_health((not state["closed"]) or state["created"] or state["track_created"])))
            if tool == "logic_project" and command == "close":
                state["closed"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        result = run_force_new_bootstrap(
            call_tool=call_tool,
            document_probe=lambda timeout_sec: (False, None),
            ui_snapshot_factory=make_ui_snapshot,
            read_resource=read_resource,
        )

        self.assertTrue(result.ok, result.as_dict())
        self.assertTrue(state["closed"])
        self.assertTrue(state["track_created"])
        self.assertIn("logic_project.close:saving=no", result.actions)

    def test_force_new_reconfirms_project_picker_after_save_dialog_dismissal(self):
        state = {
            "created": False,
            "track_created": False,
            "project_picker_visible": False,
            "save_dialog_visible": False,
            "blocking_dialog_present": False,
            "send_return_calls": 0,
            "cancel_button_clicks": 0,
        }

        def make_ui_snapshot():
            window_names = ["Untitled - Tracks"]
            if state["project_picker_visible"]:
                window_names.append("Choose a Project")
            if state["save_dialog_visible"]:
                window_names.insert(0, "Save")
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=state["project_picker_visible"],
                new_track_dialog_visible=False,
                blocking_dialog_present=state["blocking_dialog_present"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(make_health(state["created"] or state["track_created"])))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                state["project_picker_visible"] = True
                state["blocking_dialog_present"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                if state["project_picker_visible"] or state["save_dialog_visible"] or state["blocking_dialog_present"]:
                    return make_tool_response(
                        '{"success":false,"error":"unsupported_state","failure_stage":"preflight_blocking_dialog","blocking_dialog_present":true}',
                        is_error=True,
                    )
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            if state["send_return_calls"] == 1:
                state["save_dialog_visible"] = True
                state["blocking_dialog_present"] = True
            else:
                state["project_picker_visible"] = False
                state["blocking_dialog_present"] = False
            return True

        def click_save_dialog_cancel_button():
            state["cancel_button_clicks"] += 1
            state["save_dialog_visible"] = False
            state["blocking_dialog_present"] = state["project_picker_visible"]
            return True

        with (
            mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key),
            mock.patch(
                "logic_session_bootstrap._click_save_dialog_cancel_button",
                side_effect=click_save_dialog_cancel_button,
            ),
        ):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: ((False, None) if state["created"] or state["track_created"] else (True, None)),
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0"},
                read_resource=read_resource,
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertEqual(state["send_return_calls"], 2)
        self.assertEqual(state["cancel_button_clicks"], 1)
        self.assertTrue(state["track_created"])
        self.assertEqual(result.actions.count("confirm_project_picker:return"), 2)
        self.assertIn("dismiss_save_dialog:cancel_button", result.actions)

    def test_force_new_rechecks_project_picker_before_first_track_creation(self):
        state = {
            "created": False,
            "track_created": False,
            "project_picker_visible": False,
            "ready_window_seen": False,
            "send_return_calls": 0,
        }

        def make_ui_snapshot():
            if state["created"] and not state["track_created"]:
                if state["ready_window_seen"]:
                    state["project_picker_visible"] = state["send_return_calls"] == 0
                else:
                    state["ready_window_seen"] = True
                    state["project_picker_visible"] = False

            window_names = ["Untitled - Tracks"]
            if state["project_picker_visible"]:
                window_names.append("Choose a Project")

            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=state["project_picker_visible"],
                new_track_dialog_visible=False,
                blocking_dialog_present=state["project_picker_visible"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(make_health(state["created"] or state["track_created"])))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                if state["project_picker_visible"]:
                    return make_tool_response(
                        '{"success":false,"error":"unsupported_state","failure_stage":"preflight_blocking_dialog","blocking_dialog_present":true}',
                        is_error=True,
                    )
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            state["project_picker_visible"] = False
            return True

        with mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (False, None),
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0"},
                read_resource=read_resource,
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertTrue(state["track_created"])
        self.assertEqual(state["send_return_calls"], 1)
        self.assertIn("confirm_project_picker:return", result.actions)

    def test_force_new_waits_for_arrange_window_before_first_track_creation(self):
        state = {
            "created": False,
            "track_created": False,
            "project_picker_visible": False,
            "blank_shell_polls_remaining": 7,
            "send_return_calls": 0,
            "track_create_attempts": 0,
            "created_before_picker_handled": False,
        }

        def make_ui_snapshot():
            if state["created"] and not state["track_created"]:
                if state["send_return_calls"] > 0:
                    state["project_picker_visible"] = False
                    window_names = ["Untitled - Tracks"]
                elif state["blank_shell_polls_remaining"] > 0:
                    state["blank_shell_polls_remaining"] -= 1
                    state["project_picker_visible"] = False
                    window_names = []
                else:
                    state["project_picker_visible"] = True
                    window_names = ["Choose a Project"]
            else:
                window_names = ["Untitled - Tracks"]

            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=state["project_picker_visible"],
                new_track_dialog_visible=False,
                blocking_dialog_present=state["project_picker_visible"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                project_name = "Untitled - Tracks" if state["send_return_calls"] > 0 or state["track_created"] else ""
                payload = make_health(state["created"] or state["track_created"])
                payload["cache"] = {
                    "project": project_name,
                    "track_count": 1 if state["track_created"] else 0,
                }
                return make_tool_response(json.dumps(payload))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_create_attempts"] += 1
                if state["send_return_calls"] == 0:
                    state["created_before_picker_handled"] = True
                    return make_tool_response(
                        '{"success":false,"error":"unexpected_early_create"}',
                        is_error=True,
                    )
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks" if state["send_return_calls"] > 0 or state["track_created"] else "",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            state["project_picker_visible"] = False
            return True

        with mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (False, None),
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0"},
                read_resource=read_resource,
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertTrue(state["track_created"])
        self.assertFalse(state["created_before_picker_handled"])
        self.assertEqual(state["track_create_attempts"], 1)
        self.assertEqual(state["send_return_calls"], 1)
        self.assertIn("confirm_project_picker:return", result.actions)

    def test_force_new_allows_sustained_blank_shell_before_first_track_creation(self):
        state = {
            "created": False,
            "track_created": False,
            "track_create_attempts": 0,
            "track_create_time": None,
        }

        class FakeClock:
            def __init__(self):
                self.now = 0.0

            def time(self):
                return self.now

            def sleep(self, duration):
                self.now += duration

        def make_ui_snapshot():
            window_names = ["Untitled - Tracks"] if state["track_created"] else []
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=False,
                blocking_dialog_present=False,
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                payload = make_health(state["created"] or state["track_created"])
                payload["cache"] = {
                    "project": "Untitled - Tracks" if state["track_created"] else "",
                    "track_count": 1 if state["track_created"] else 0,
                }
                return make_tool_response(json.dumps(payload))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_create_attempts"] += 1
                state["track_create_time"] = fake_clock.now
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks" if state["track_created"] else "",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        fake_clock = FakeClock()
        with (
            mock.patch("logic_session_bootstrap.time.sleep", side_effect=fake_clock.sleep),
            mock.patch("logic_session_bootstrap.time.time", side_effect=fake_clock.time),
        ):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (False, None),
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={
                    "LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0",
                    "LOGIC_PRO_MCP_BOOTSTRAP_TIMEOUT_SEC": "3.0",
                    "LOGIC_PRO_MCP_BOOTSTRAP_POLL_SEC": "0.1",
                },
                read_resource=read_resource,
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertTrue(state["track_created"])
        self.assertEqual(state["track_create_attempts"], 1)
        self.assertGreaterEqual(state["track_create_time"], 2.2)
        self.assertNotIn("confirm_project_picker:return", result.actions)

    def test_force_new_reconfirms_project_picker_when_health_temporarily_disappears(self):
        state = {
            "created": False,
            "track_created": False,
            "project_picker_visible": False,
            "save_dialog_visible": False,
            "blocking_dialog_present": False,
            "send_return_calls": 0,
            "cancel_button_clicks": 0,
            "health_glitch_injected": False,
        }

        def make_ui_snapshot():
            window_names = ["Untitled - Tracks"]
            if state["project_picker_visible"]:
                window_names.append("Choose a Project")
            if state["save_dialog_visible"]:
                window_names.insert(0, "Save")
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=state["project_picker_visible"],
                new_track_dialog_visible=False,
                blocking_dialog_present=state["blocking_dialog_present"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                if (
                    state["cancel_button_clicks"] == 1
                    and state["project_picker_visible"]
                    and not state["save_dialog_visible"]
                    and not state["health_glitch_injected"]
                ):
                    state["health_glitch_injected"] = True
                    return make_tool_response("not-json")
                return make_tool_response(json.dumps(make_health(state["created"] or state["track_created"])))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                state["project_picker_visible"] = True
                state["blocking_dialog_present"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                if state["project_picker_visible"] or state["save_dialog_visible"] or state["blocking_dialog_present"]:
                    return make_tool_response(
                        '{"success":false,"error":"unsupported_state","failure_stage":"preflight_blocking_dialog","blocking_dialog_present":true}',
                        is_error=True,
                    )
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            if state["send_return_calls"] == 1:
                state["save_dialog_visible"] = True
                state["blocking_dialog_present"] = True
            else:
                state["project_picker_visible"] = False
                state["blocking_dialog_present"] = False
            return True

        def click_save_dialog_cancel_button():
            state["cancel_button_clicks"] += 1
            state["save_dialog_visible"] = False
            state["blocking_dialog_present"] = state["project_picker_visible"]
            return True

        with (
            mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key),
            mock.patch(
                "logic_session_bootstrap._click_save_dialog_cancel_button",
                side_effect=click_save_dialog_cancel_button,
            ),
        ):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (
                    (False, None) if state["created"] or state["track_created"] else (True, None)
                ),
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0"},
                read_resource=read_resource,
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertEqual(state["send_return_calls"], 2)
        self.assertEqual(state["cancel_button_clicks"], 1)
        self.assertTrue(state["health_glitch_injected"])
        self.assertIn("dismiss_save_dialog:cancel_button", result.actions)
        self.assertEqual(result.actions.count("confirm_project_picker:return"), 2)

    def test_force_new_retries_project_picker_until_it_clears(self):
        state = {
            "created": False,
            "track_created": False,
            "project_picker_visible": False,
            "save_dialog_visible": False,
            "blocking_dialog_present": False,
            "send_return_calls": 0,
            "cancel_button_clicks": 0,
        }

        def make_ui_snapshot():
            window_names = ["Untitled - Tracks"]
            if state["project_picker_visible"]:
                window_names.append("Choose a Project")
            if state["save_dialog_visible"]:
                window_names.insert(0, "Save")
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=state["project_picker_visible"],
                new_track_dialog_visible=False,
                blocking_dialog_present=state["blocking_dialog_present"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(make_health(state["created"] or state["track_created"])))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                state["project_picker_visible"] = True
                state["blocking_dialog_present"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                if state["project_picker_visible"] or state["save_dialog_visible"] or state["blocking_dialog_present"]:
                    return make_tool_response(
                        '{"success":false,"error":"unsupported_state","failure_stage":"preflight_blocking_dialog","blocking_dialog_present":true}',
                        is_error=True,
                    )
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            if state["send_return_calls"] == 1:
                state["save_dialog_visible"] = True
                state["blocking_dialog_present"] = True
            elif state["send_return_calls"] == 2:
                state["project_picker_visible"] = True
                state["blocking_dialog_present"] = False
            else:
                state["project_picker_visible"] = False
                state["blocking_dialog_present"] = False
            return True

        def click_save_dialog_cancel_button():
            state["cancel_button_clicks"] += 1
            state["save_dialog_visible"] = False
            state["blocking_dialog_present"] = state["project_picker_visible"]
            return True

        with (
            mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key),
            mock.patch(
                "logic_session_bootstrap._click_save_dialog_cancel_button",
                side_effect=click_save_dialog_cancel_button,
            ),
        ):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (
                    (False, None) if state["created"] or state["track_created"] else (True, None)
                ),
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0"},
                read_resource=read_resource,
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertEqual(state["send_return_calls"], 3)
        self.assertEqual(state["cancel_button_clicks"], 1)
        self.assertEqual(result.actions.count("confirm_project_picker:return"), 3)
        self.assertTrue(state["track_created"])

    def test_force_new_accepts_ready_arrange_window_after_save_dialog_cancel(self):
        state = {
            "created": False,
            "track_created": False,
            "save_dialog_visible": False,
            "blocking_dialog_present": False,
            "send_return_calls": 0,
            "cancel_button_clicks": 0,
        }

        def make_ui_snapshot():
            window_names = ["Untitled - Tracks"]
            if state["save_dialog_visible"]:
                window_names.insert(0, "Save")
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=False,
                blocking_dialog_present=state["blocking_dialog_present"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(make_health(state["created"] or state["track_created"])))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                state["blocking_dialog_present"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            state["save_dialog_visible"] = True
            state["blocking_dialog_present"] = True
            return True

        def click_save_dialog_cancel_button():
            state["cancel_button_clicks"] += 1
            state["save_dialog_visible"] = False
            state["blocking_dialog_present"] = False
            return True

        with (
            mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key),
            mock.patch(
                "logic_session_bootstrap._click_save_dialog_cancel_button",
                side_effect=click_save_dialog_cancel_button,
            ),
        ):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: ((False, None) if state["created"] or state["track_created"] else (True, None)),
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0"},
                read_resource=read_resource,
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertEqual(state["send_return_calls"], 1)
        self.assertEqual(state["cancel_button_clicks"], 1)
        self.assertTrue(state["track_created"])
        self.assertIn("confirm_hidden_blocking_dialog:return", result.actions)
        self.assertIn("dismiss_save_dialog:cancel_button", result.actions)

    def test_force_new_accepts_nonblocking_project_picker_after_auto_track_creation(self):
        state = {
            "closed": False,
            "created": False,
            "auto_track_created": False,
            "project_picker_visible": False,
            "blocking_dialog_present": False,
            "send_return_calls": 0,
            "create_instrument_calls": 0,
        }

        def make_ui_snapshot():
            window_names = ["Untitled - Tracks"]
            if state["project_picker_visible"]:
                window_names.append("Choose a Project")
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=state["project_picker_visible"],
                new_track_dialog_visible=False,
                blocking_dialog_present=state["blocking_dialog_present"],
            )

        def health_payload():
            return {
                "logic_pro_running": True,
                "logic_pro_has_window": True,
                "logic_pro_has_document": state["created"] or state["auto_track_created"],
                "permissions": {"accessibility": True, "post_event_access": True},
                "cache": {
                    "project": "Untitled - Tracks" if state["created"] or state["auto_track_created"] else "",
                    "track_count": 1 if state["auto_track_created"] else 0,
                },
            }

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(health_payload()))
            if tool == "logic_project" and command == "close":
                state["closed"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_project" and command == "new":
                state["created"] = True
                state["project_picker_visible"] = True
                state["blocking_dialog_present"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["create_instrument_calls"] += 1
                return make_tool_response(
                    '{"success":false,"error":"unexpected_create_instrument"}',
                    is_error=True,
                )
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["auto_track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["auto_track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            state["blocking_dialog_present"] = False
            state["project_picker_visible"] = True
            state["auto_track_created"] = True
            return True

        with mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (
                    (False, None) if state["closed"] and not state["created"] else (True, None)
                ),
                read_resource=read_resource,
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "1"},
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertEqual(state["send_return_calls"], 1)
        self.assertEqual(state["create_instrument_calls"], 0)
        self.assertTrue(result.ui["project_picker_visible"])
        self.assertIn("confirm_project_picker:return", result.actions)

    def test_force_new_retries_initial_hidden_blocking_dialog_before_close(self):
        state = {
            "closed": False,
            "created": False,
            "track_created": False,
            "blocking_dialog_present": True,
            "send_return_calls": 0,
            "close_called_while_blocked": False,
        }

        def make_ui_snapshot():
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=["Untitled - Tracks"],
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=False,
                blocking_dialog_present=state["blocking_dialog_present"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                return make_tool_response(json.dumps(make_health(state["created"] or state["track_created"])))
            if tool == "logic_project" and command == "close":
                state["close_called_while_blocked"] = state["blocking_dialog_present"]
                state["closed"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            if state["send_return_calls"] >= 2:
                state["blocking_dialog_present"] = False
            return True

        with mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (
                    (False, None) if state["closed"] and not state["created"] else (True, None)
                ),
                read_resource=read_resource,
                ui_snapshot_factory=make_ui_snapshot,
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertEqual(state["send_return_calls"], 2)
        self.assertFalse(state["close_called_while_blocked"])
        self.assertIn("clear_initial_blocking_dialog:return", result.actions)

    def test_force_new_fails_closed_when_track_creation_ui_never_settles(self):
        state = {
            "created": False,
            "track_create_attempts": 0,
            "project_picker_visible": False,
            "blocking_dialog_present": False,
            "send_return_calls": 0,
        }

        def make_ui_snapshot():
            window_names = ["Untitled - Tracks"]
            if state["project_picker_visible"]:
                window_names.append("Choose a Project")
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=state["project_picker_visible"],
                new_track_dialog_visible=False,
                blocking_dialog_present=state["blocking_dialog_present"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                payload = make_health(state["created"])
                payload["cache"] = {
                    "project": "Untitled - Tracks" if state["created"] else "",
                    "track_count": 0,
                }
                return make_tool_response(json.dumps(payload))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_create_attempts"] += 1
                state["project_picker_visible"] = True
                return make_tool_response(
                    '{"success":false,"error":"unsupported_state","failure_stage":"preflight_blocking_dialog"}',
                    is_error=True,
                )
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                return make_resource_response(
                    json.dumps({"source": "ax_live", "ax_occluded": False, "data": []})
                )
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            state["project_picker_visible"] = True
            return True

        with mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (False, None) if state["created"] else (True, None),
                read_resource=read_resource,
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0"},
            )

        self.assertFalse(result.ok)
        self.assertEqual(result.reason, "fresh_track_ui_not_ready")
        self.assertGreaterEqual(state["send_return_calls"], 1)
        self.assertEqual(state["track_create_attempts"], 1)

    def test_force_new_advances_from_nonblocking_picker_to_first_track_creation(self):
        state = {
            "created": False,
            "track_created": False,
            "project_picker_visible": False,
            "blocking_dialog_present": False,
            "send_return_calls": 0,
            "track_create_attempts": 0,
        }

        def make_ui_snapshot():
            window_names = ["Untitled - Tracks"]
            if state["project_picker_visible"]:
                window_names.append("Choose a Project")
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=state["project_picker_visible"],
                new_track_dialog_visible=False,
                blocking_dialog_present=state["blocking_dialog_present"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                payload = make_health(state["created"] or state["track_created"])
                payload["cache"] = {
                    "project": "Untitled - Tracks" if state["track_created"] else "",
                    "track_count": 1 if state["track_created"] else 0,
                }
                return make_tool_response(json.dumps(payload))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                state["project_picker_visible"] = True
                state["blocking_dialog_present"] = False
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_create_attempts"] += 1
                if state["project_picker_visible"]:
                    return make_tool_response(
                        '{"success":false,"error":"unsupported_state","failure_stage":"preflight_blocking_dialog","blocking_dialog_present":true}',
                        is_error=True,
                    )
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            state["project_picker_visible"] = False
            return True

        with mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (False, None) if state["created"] else (True, None),
                read_resource=read_resource,
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0"},
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertTrue(state["track_created"])
        self.assertEqual(state["send_return_calls"], 1)
        self.assertEqual(state["track_create_attempts"], 1)
        self.assertIn("confirm_project_picker:return", result.actions)

    def test_force_new_waits_for_picker_after_logic_not_running_track_create_error(self):
        state = {
            "created": False,
            "track_created": False,
            "track_create_attempts": 0,
            "project_picker_visible": False,
            "waiting_for_picker": False,
            "picker_confirmed": False,
            "refresh_polls_after_error": 0,
            "send_return_calls": 0,
        }

        def make_ui_snapshot():
            window_names: list[str] = []
            if state["project_picker_visible"]:
                window_names.append("Choose a Project")
            elif state["track_created"]:
                window_names.append("Untitled - Tracks")
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=state["project_picker_visible"],
                new_track_dialog_visible=False,
                blocking_dialog_present=state["project_picker_visible"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                payload = make_health(state["created"] or state["track_created"])
                payload["cache"] = {
                    "project": "Untitled - Tracks" if state["track_created"] else "",
                    "track_count": 1 if state["track_created"] else 0,
                }
                return make_tool_response(json.dumps(payload))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                if state["waiting_for_picker"] and not state["project_picker_visible"]:
                    state["refresh_polls_after_error"] += 1
                    if state["refresh_polls_after_error"] >= 2:
                        state["project_picker_visible"] = True
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_create_attempts"] += 1
                if state["track_create_attempts"] == 1:
                    state["waiting_for_picker"] = True
                    return make_tool_response(
                        '{"error":"channels_exhausted","hint":"Channel CGEvent: Logic Pro is not running","last_error":"Channel CGEvent: Logic Pro is not running","operation":"track.create_instrument","success":false}',
                        is_error=True,
                    )
                if not state["picker_confirmed"]:
                    return make_tool_response(
                        '{"success":false,"error":"retry_before_picker_confirmation"}',
                        is_error=True,
                    )
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            state["project_picker_visible"] = False
            state["waiting_for_picker"] = False
            state["picker_confirmed"] = True
            return True

        with mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (False, None) if state["created"] else (True, None),
                read_resource=read_resource,
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={
                    "LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0",
                    "LOGIC_PRO_MCP_BOOTSTRAP_TIMEOUT_SEC": "1.0",
                    "LOGIC_PRO_MCP_BOOTSTRAP_POLL_SEC": "0.1",
                },
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertTrue(state["track_created"])
        self.assertEqual(state["track_create_attempts"], 2)
        self.assertEqual(state["send_return_calls"], 1)
        self.assertGreaterEqual(state["refresh_polls_after_error"], 2)
        create_indices = [
            index
            for index, action in enumerate(result.actions)
            if action == "logic_tracks.create_instrument"
        ]
        self.assertEqual(len(create_indices), 2)
        confirm_index = result.actions.index("confirm_project_picker:return")
        self.assertLess(create_indices[0], confirm_index)
        self.assertLess(confirm_index, create_indices[1])

    def test_force_new_retries_after_single_picker_confirm_for_logic_not_running_error(self):
        state = {
            "created": False,
            "track_created": False,
            "track_create_attempts": 0,
            "project_picker_visible": False,
            "waiting_for_picker": False,
            "picker_confirmed": False,
            "refresh_polls_after_error": 0,
            "send_return_calls": 0,
        }

        def make_ui_snapshot():
            window_names: list[str] = []
            if state["project_picker_visible"]:
                window_names.append("Choose a Project")
            elif state["track_created"]:
                window_names.append("Untitled - Tracks")
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=state["project_picker_visible"],
                new_track_dialog_visible=False,
                blocking_dialog_present=state["project_picker_visible"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                payload = make_health(state["created"] or state["track_created"])
                payload["cache"] = {
                    "project": "Untitled - Tracks" if state["track_created"] else "",
                    "track_count": 1 if state["track_created"] else 0,
                }
                return make_tool_response(json.dumps(payload))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                if state["waiting_for_picker"] and not state["project_picker_visible"]:
                    state["refresh_polls_after_error"] += 1
                    if state["refresh_polls_after_error"] >= 2:
                        state["project_picker_visible"] = True
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_create_attempts"] += 1
                if state["track_create_attempts"] == 1:
                    state["waiting_for_picker"] = True
                    return make_tool_response(
                        '{"error":"channels_exhausted","hint":"Channel CGEvent: Logic Pro is not running","last_error":"Channel CGEvent: Logic Pro is not running","operation":"track.create_instrument","success":false}',
                        is_error=True,
                    )
                if not state["picker_confirmed"]:
                    return make_tool_response(
                        '{"success":false,"error":"retry_before_picker_confirmation"}',
                        is_error=True,
                    )
                state["project_picker_visible"] = False
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks" if state["track_created"] else "",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            state["waiting_for_picker"] = False
            state["picker_confirmed"] = True
            return True

        with mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (False, None) if state["created"] else (True, None),
                read_resource=read_resource,
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={
                    "LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0",
                    "LOGIC_PRO_MCP_BOOTSTRAP_TIMEOUT_SEC": "1.0",
                    "LOGIC_PRO_MCP_BOOTSTRAP_POLL_SEC": "0.1",
                },
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertTrue(state["track_created"])
        self.assertEqual(state["track_create_attempts"], 2)
        self.assertEqual(state["send_return_calls"], 1)
        create_indices = [
            index
            for index, action in enumerate(result.actions)
            if action == "logic_tracks.create_instrument"
        ]
        self.assertEqual(len(create_indices), 2)
        confirm_index = result.actions.index("confirm_project_picker:return")
        self.assertLess(create_indices[0], confirm_index)
        self.assertLess(confirm_index, create_indices[1])

    def test_force_new_retries_after_uncertain_second_create_when_no_track_materializes(self):
        state = {
            "created": False,
            "track_created": False,
            "track_create_attempts": 0,
            "project_picker_visible": False,
            "waiting_for_picker": False,
            "picker_confirmed": False,
            "refresh_polls_after_error": 0,
            "send_return_calls": 0,
        }

        def make_ui_snapshot():
            window_names: list[str] = []
            if state["project_picker_visible"]:
                window_names.append("Choose a Project")
            elif state["track_created"]:
                window_names.append("Untitled - Tracks")
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=state["project_picker_visible"],
                new_track_dialog_visible=False,
                blocking_dialog_present=state["project_picker_visible"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                payload = make_health(state["created"] or state["track_created"])
                payload["cache"] = {
                    "project": "Untitled - Tracks" if state["track_created"] else "",
                    "track_count": 1 if state["track_created"] else 0,
                }
                return make_tool_response(json.dumps(payload))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                if state["waiting_for_picker"] and not state["project_picker_visible"]:
                    state["refresh_polls_after_error"] += 1
                    if state["refresh_polls_after_error"] >= 2:
                        state["project_picker_visible"] = True
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_create_attempts"] += 1
                if state["track_create_attempts"] == 1:
                    state["waiting_for_picker"] = True
                    return make_tool_response(
                        '{"error":"channels_exhausted","hint":"Channel CGEvent: Logic Pro is not running","last_error":"Channel CGEvent: Logic Pro is not running","operation":"track.create_instrument","success":false}',
                        is_error=True,
                    )
                if state["track_create_attempts"] == 2:
                    state["project_picker_visible"] = True
                    return make_tool_response(
                        '{"method":"cgevent","operation":"track.create_instrument","reason":"readback_unavailable","sent":true,"success":true,"verified":false}',
                        is_error=True,
                    )
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks" if state["track_created"] else "",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            state["waiting_for_picker"] = False
            state["picker_confirmed"] = True
            state["project_picker_visible"] = False
            return True

        with mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (False, None) if state["created"] else (True, None),
                read_resource=read_resource,
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={
                    "LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0",
                    "LOGIC_PRO_MCP_BOOTSTRAP_TIMEOUT_SEC": "1.0",
                    "LOGIC_PRO_MCP_BOOTSTRAP_POLL_SEC": "0.1",
                },
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertTrue(state["track_created"])
        self.assertEqual(state["track_create_attempts"], 3)
        self.assertEqual(state["send_return_calls"], 2)
        create_indices = [
            index
            for index, action in enumerate(result.actions)
            if action == "logic_tracks.create_instrument"
        ]
        self.assertEqual(len(create_indices), 3)
        confirm_indices = [
            index
            for index, action in enumerate(result.actions)
            if action == "confirm_project_picker:return"
        ]
        self.assertEqual(len(confirm_indices), 2)
        self.assertLess(create_indices[0], confirm_indices[0])
        self.assertLess(confirm_indices[0], create_indices[1])
        self.assertLess(create_indices[1], confirm_indices[1])
        self.assertLess(confirm_indices[1], create_indices[2])

    def test_force_new_retries_track_creation_after_frontmost_error(self):
        state = {
            "created": False,
            "track_created": False,
            "track_create_attempts": 0,
        }

        def make_ui_snapshot():
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=["Untitled - Tracks"],
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=False,
                blocking_dialog_present=False,
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                payload = make_health(state["created"] or state["track_created"])
                payload["cache"] = {
                    "project": "Untitled - Tracks" if state["track_created"] else "",
                    "track_count": 1 if state["track_created"] else 0,
                }
                return make_tool_response(json.dumps(payload))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_create_attempts"] += 1
                if state["track_create_attempts"] == 1:
                    return make_tool_response(
                        '{"success":false,"error":"transient_create_failure"}',
                        is_error=True,
                    )
                state["track_created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        result = run_force_new_bootstrap(
            call_tool=call_tool,
            document_probe=lambda timeout_sec: (False, None) if state["created"] else (True, None),
            read_resource=read_resource,
            ui_snapshot_factory=make_ui_snapshot,
            env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0"},
        )

        self.assertTrue(result.ok, result.as_dict())
        self.assertTrue(state["track_created"])
        self.assertEqual(state["track_create_attempts"], 2)
        self.assertEqual(result.actions.count("logic_tracks.create_instrument"), 2)

    def test_force_new_accepts_unverified_track_creation_when_track_materializes(self):
        state = {
            "created": False,
            "track_created": False,
            "track_create_attempts": 0,
        }

        def make_ui_snapshot():
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=["Untitled - Tracks"],
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=False,
                blocking_dialog_present=False,
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                payload = make_health(state["created"] or state["track_created"])
                payload["cache"] = {
                    "project": "Untitled - Tracks" if state["created"] or state["track_created"] else "",
                    "track_count": 1 if state["track_created"] else 0,
                }
                return make_tool_response(json.dumps(payload))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_create_attempts"] += 1
                state["track_created"] = True
                return make_tool_response(
                    '{"success":true,"verified":false,"reason":"readback_unavailable","method":"cgevent","sent":true}',
                    is_error=True,
                )
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        result = run_force_new_bootstrap(
            call_tool=call_tool,
            document_probe=lambda timeout_sec: (False, None) if state["created"] else (True, None),
            read_resource=read_resource,
            ui_snapshot_factory=make_ui_snapshot,
            env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0"},
        )

        self.assertTrue(result.ok, result.as_dict())
        self.assertTrue(state["track_created"])
        self.assertEqual(state["track_create_attempts"], 1)
        self.assertEqual(result.actions.count("logic_tracks.create_instrument"), 1)

    def test_force_new_confirms_dialog_after_unverified_track_creation(self):
        state = {
            "created": False,
            "track_created": False,
            "new_track_dialog_visible": False,
            "track_create_attempts": 0,
            "send_return_calls": 0,
        }

        def make_ui_snapshot():
            window_names = ["Untitled - Tracks"]
            if state["new_track_dialog_visible"]:
                window_names.append("Create Tracks")
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=state["new_track_dialog_visible"],
                blocking_dialog_present=state["new_track_dialog_visible"],
            )

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                payload = make_health(state["created"] or state["track_created"])
                payload["cache"] = {
                    "project": "Untitled - Tracks" if state["created"] or state["track_created"] else "",
                    "track_count": 1 if state["track_created"] else 0,
                }
                return make_tool_response(json.dumps(payload))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_create_attempts"] += 1
                state["new_track_dialog_visible"] = True
                return make_tool_response(
                    '{"success":true,"verified":false,"reason":"readback_unavailable","method":"cgevent","sent":true}',
                    is_error=True,
                )
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            state["new_track_dialog_visible"] = False
            state["track_created"] = True
            return True

        with mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (False, None) if state["created"] else (True, None),
                read_resource=read_resource,
                ui_snapshot_factory=make_ui_snapshot,
                env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0"},
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertTrue(state["track_created"])
        self.assertEqual(state["track_create_attempts"], 1)
        self.assertEqual(state["send_return_calls"], 1)
        self.assertIn("confirm_new_track_dialog:return", result.actions)

    def test_force_new_restores_focus_before_confirming_dialog_after_unverified_track_creation(self):
        state = {
            "created": False,
            "track_created": False,
            "new_track_dialog_visible": False,
            "track_create_attempts": 0,
            "send_return_calls": 0,
            "activate_calls": 0,
            "activation_pending": False,
            "frontmost_app": "Logic Pro",
            "send_return_while_unfocused": False,
        }

        def make_ui_snapshot():
            frontmost_app = (
                "UserNotificationCenter" if state["activation_pending"] else state["frontmost_app"]
            )
            window_names = ["Untitled - Tracks"]
            if state["new_track_dialog_visible"]:
                window_names.append("Create Tracks")
            return bootstrap_module.UISnapshot(
                frontmost_app=frontmost_app,
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=False,
                new_track_dialog_visible=state["new_track_dialog_visible"],
                blocking_dialog_present=state["new_track_dialog_visible"],
            )

        def activate_logic():
            state["activate_calls"] += 1
            state["activation_pending"] = True
            return True

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                payload = make_health(state["created"] or state["track_created"])
                payload["cache"] = {
                    "project": "Untitled - Tracks" if state["created"] or state["track_created"] else "",
                    "track_count": 1 if state["track_created"] else 0,
                }
                return make_tool_response(json.dumps(payload))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_create_attempts"] += 1
                state["frontmost_app"] = "UserNotificationCenter"
                state["new_track_dialog_visible"] = True
                return make_tool_response(
                    '{"success":true,"verified":false,"reason":"readback_unavailable","method":"cgevent","sent":true}',
                    is_error=True,
                )
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            if make_ui_snapshot().frontmost_app != "Logic Pro":
                state["send_return_while_unfocused"] = True
                return False
            state["frontmost_app"] = "Logic Pro"
            state["new_track_dialog_visible"] = False
            state["track_created"] = True
            return True

        def fake_sleep(_duration):
            if state["activation_pending"]:
                state["activation_pending"] = False
                state["frontmost_app"] = "Logic Pro"

        previous_sleep = bootstrap_module.time.sleep
        try:
            bootstrap_module.time.sleep = fake_sleep
            with mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key):
                result = run_force_new_bootstrap(
                    call_tool=call_tool,
                    document_probe=lambda timeout_sec: (False, None) if state["created"] else (True, None),
                    read_resource=read_resource,
                    ui_snapshot_factory=make_ui_snapshot,
                    activate_logic=activate_logic,
                    env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0"},
                )
        finally:
            bootstrap_module.time.sleep = previous_sleep

        self.assertTrue(result.ok, result.as_dict())
        self.assertTrue(state["track_created"])
        self.assertEqual(state["track_create_attempts"], 1)
        self.assertEqual(state["send_return_calls"], 1)
        self.assertFalse(state["send_return_while_unfocused"])
        self.assertGreaterEqual(state["activate_calls"], 1)
        self.assertIn("activate:Logic Pro", result.actions)
        self.assertIn("confirm_new_track_dialog:return", result.actions)

    def test_force_new_reactivates_logic_before_confirming_project_picker_even_when_frontmost(self):
        state = {
            "created": False,
            "track_created": False,
            "project_picker_visible": False,
            "track_create_attempts": 0,
            "send_return_calls": 0,
            "activate_calls": 0,
            "activation_ready": False,
            "send_return_before_activation": False,
        }

        def make_ui_snapshot():
            window_names = ["Untitled - Tracks"]
            if state["project_picker_visible"]:
                window_names.append("Choose a Project")
            return bootstrap_module.UISnapshot(
                frontmost_app="Logic Pro",
                logic_window_names=window_names,
                logic_menu_items=[
                    "Apple",
                    "Logic Pro",
                    "File",
                    "Edit",
                    "Track",
                    "Navigate",
                    "Record",
                    "Mix",
                    "View",
                    "Window",
                    "Help",
                ],
                detected_language="en",
                system_events_error=None,
                project_picker_visible=state["project_picker_visible"],
                new_track_dialog_visible=False,
                blocking_dialog_present=state["project_picker_visible"],
            )

        def activate_logic():
            state["activate_calls"] += 1
            state["activation_ready"] = True
            return True

        def call_tool(tool, command, params=None, timeout=None):
            if tool == "logic_system" and command == "health":
                payload = make_health(state["created"] or state["track_created"])
                payload["cache"] = {
                    "project": "Untitled - Tracks" if state["track_created"] else "",
                    "track_count": 1 if state["track_created"] else 0,
                }
                return make_tool_response(json.dumps(payload))
            if tool == "logic_project" and command == "new":
                state["created"] = True
                return make_tool_response('{"success":true,"verified":true}')
            if tool == "logic_system" and command == "refresh_cache":
                return make_tool_response('{"ok":true}')
            if tool == "logic_tracks" and command == "create_instrument":
                state["track_create_attempts"] += 1
                state["project_picker_visible"] = True
                return make_tool_response(
                    '{"success":true,"verified":false,"reason":"readback_unavailable","method":"cgevent","sent":true}',
                    is_error=True,
                )
            return make_tool_response("{}")

        def read_resource(uri):
            if uri == "logic://project/info":
                payload = {
                    "source": "ax_live",
                    "data": {
                        "name": "Untitled - Tracks",
                        "trackCount": 1 if state["track_created"] else 0,
                        "source": "ax_live",
                    },
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks":
                payload = {
                    "source": "ax_live",
                    "ax_occluded": False,
                    "data": (
                        [{"id": 0, "name": "Track 1", "placeholder": False}]
                        if state["track_created"]
                        else []
                    ),
                }
                return make_resource_response(json.dumps(payload))
            if uri == "logic://tracks/0/regions":
                return make_resource_response("[]")
            return make_resource_response("{}")

        def send_return_key():
            state["send_return_calls"] += 1
            if not state["activation_ready"]:
                state["send_return_before_activation"] = True
                return False
            state["project_picker_visible"] = False
            state["track_created"] = True
            return True

        with mock.patch("logic_session_bootstrap._send_return_key", side_effect=send_return_key):
            result = run_force_new_bootstrap(
                call_tool=call_tool,
                document_probe=lambda timeout_sec: (False, None) if state["created"] else (True, None),
                read_resource=read_resource,
                ui_snapshot_factory=make_ui_snapshot,
                activate_logic=activate_logic,
                env_overrides={"LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW": "0"},
            )

        self.assertTrue(result.ok, result.as_dict())
        self.assertTrue(state["track_created"])
        self.assertEqual(state["track_create_attempts"], 1)
        self.assertEqual(state["send_return_calls"], 1)
        self.assertFalse(state["send_return_before_activation"])
        self.assertGreaterEqual(state["activate_calls"], 1)
        self.assertIn("activate:Logic Pro", result.actions)
        self.assertIn("confirm_project_picker:return", result.actions)


if __name__ == "__main__":
    unittest.main()
