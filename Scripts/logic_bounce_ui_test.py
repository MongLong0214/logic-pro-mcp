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
    def test_trusted_cliclick_path_rejects_untrusted_override(self):
        self.assertIsNone(logic_bounce.trusted_cliclick_path("/tmp/cliclick"))

    def test_trusted_cliclick_path_accepts_trusted_executable(self):
        class StatResult:
            st_mode = 0o755

        with (
            mock.patch.object(logic_bounce.os.path, "isfile", return_value=True),
            mock.patch.object(logic_bounce.os, "access", return_value=True),
            mock.patch.object(logic_bounce.os, "stat", return_value=StatResult()),
        ):
            self.assertEqual(
                logic_bounce.trusted_cliclick_path("/opt/homebrew/bin/cliclick"),
                "/opt/homebrew/bin/cliclick",
            )

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


import contextlib  # noqa: E402

import logic_bounce_ui  # noqa: E402


class _FakeStat:
    def __init__(self, mode, uid):
        self.st_mode = mode
        self.st_uid = uid


@contextlib.contextmanager
def _patch_fs(*, files, dirs, realpath=None, executables=None, uid=501, sha256=None):
    """Hermetic filesystem for cliclick trust tests.

    files/dirs: {path: (mode, uid)}. executables: set (default = all files).
    realpath: {input: real} (default identity). sha256: {path: digest}.
    """
    realpath = realpath or {}
    executables = executables if executables is not None else set(files.keys())
    sha256 = sha256 or {}

    def fake_stat(path):
        if path in files:
            return _FakeStat(*files[path])
        if path in dirs:
            return _FakeStat(*dirs[path])
        raise OSError(f"no such path: {path}")

    with (
        mock.patch.object(logic_bounce_ui.os.path, "realpath", side_effect=lambda p: realpath.get(p, p)),
        mock.patch.object(logic_bounce_ui.os.path, "isfile", side_effect=lambda p: p in files),
        mock.patch.object(logic_bounce_ui.os, "access", side_effect=lambda p, _mode: p in executables),
        mock.patch.object(logic_bounce_ui.os, "stat", side_effect=fake_stat),
        mock.patch.object(logic_bounce_ui.os, "getuid", return_value=uid),
        mock.patch.object(logic_bounce_ui, "_sha256_of", side_effect=lambda p: sha256.get(p)),
    ):
        yield


# A clean approved tree: /approved/bin/cliclick, all 0o755, owned by self (501), incl. "/".
_APPROVED = {
    "files": {"/approved/bin/cliclick": (0o755, 501)},
    "dirs": {"/approved/bin": (0o755, 501), "/approved": (0o755, 501), "/": (0o755, 0)},
}


class CliclickTrustTests(unittest.TestCase):
    # --- canonical rule (NG1) ---
    def test_canonical_parent_writable(self):
        with _patch_fs(files={"/opt/homebrew/bin/cliclick": (0o755, 501)},
                       dirs={"/opt/homebrew/bin": (0o775, 501)}):
            self.assertEqual(logic_bounce_ui._evaluate_canonical("/opt/homebrew/bin/cliclick"),
                             logic_bounce_ui.R_PARENT_WRITABLE)

    def test_canonical_resolved(self):
        with _patch_fs(files={"/opt/homebrew/bin/cliclick": (0o755, 501)},
                       dirs={"/opt/homebrew/bin": (0o755, 501)}):
            self.assertEqual(logic_bounce_ui._evaluate_canonical("/opt/homebrew/bin/cliclick"),
                             logic_bounce_ui.R_RESOLVED)

    def test_canonical_not_found_and_not_executable(self):
        with _patch_fs(files={}, dirs={"/usr/local/bin": (0o755, 0)}):
            self.assertEqual(logic_bounce_ui._evaluate_canonical("/usr/local/bin/cliclick"),
                             logic_bounce_ui.R_NOT_FOUND)
        with _patch_fs(files={"/usr/local/bin/cliclick": (0o644, 0)},
                       dirs={"/usr/local/bin": (0o755, 0)}, executables=set()):
            self.assertEqual(logic_bounce_ui._evaluate_canonical("/usr/local/bin/cliclick"),
                             logic_bounce_ui.R_NOT_EXECUTABLE)

    # --- arbitrary rule (strict) ---
    def test_arbitrary_resolved(self):
        with _patch_fs(**_APPROVED):
            reason, real = logic_bounce_ui._evaluate_arbitrary("/approved/bin/cliclick", {})
            self.assertEqual(reason, logic_bounce_ui.R_RESOLVED)
            self.assertEqual(real, "/approved/bin/cliclick")

    def test_arbitrary_not_absolute(self):
        with _patch_fs(files={}, dirs={}):
            reason, _ = logic_bounce_ui._evaluate_arbitrary("relative/cliclick", {})
            self.assertEqual(reason, logic_bounce_ui.R_NOT_ABSOLUTE)

    def test_arbitrary_file_writable(self):
        files = {"/approved/bin/cliclick": (0o757, 501)}  # world-writable file
        with _patch_fs(files=files, dirs=_APPROVED["dirs"]):
            reason, _ = logic_bounce_ui._evaluate_arbitrary("/approved/bin/cliclick", {})
            self.assertEqual(reason, logic_bounce_ui.R_FILE_WRITABLE)

    def test_arbitrary_owner_untrusted(self):
        files = {"/approved/bin/cliclick": (0o755, 999)}  # owned by a different non-root user
        with _patch_fs(files=files, dirs=_APPROVED["dirs"]):
            reason, _ = logic_bounce_ui._evaluate_arbitrary("/approved/bin/cliclick", {})
            self.assertEqual(reason, logic_bounce_ui.R_OWNER_UNTRUSTED)

    def test_arbitrary_ancestor_writable(self):
        dirs = {"/approved/bin": (0o755, 501), "/approved": (0o775, 501), "/": (0o755, 0)}
        with _patch_fs(files=_APPROVED["files"], dirs=dirs):
            reason, _ = logic_bounce_ui._evaluate_arbitrary("/approved/bin/cliclick", {})
            self.assertEqual(reason, logic_bounce_ui.R_ANCESTOR_WRITABLE)

    def test_arbitrary_ancestor_hostile_owner(self):
        # ancestor non-writable but owned by a hostile non-root third user → reject (P2-E)
        dirs = {"/approved/bin": (0o755, 999), "/approved": (0o755, 0), "/": (0o755, 0)}
        with _patch_fs(files=_APPROVED["files"], dirs=dirs):
            reason, _ = logic_bounce_ui._evaluate_arbitrary("/approved/bin/cliclick", {})
            self.assertEqual(reason, logic_bounce_ui.R_ANCESTOR_WRITABLE)

    def test_arbitrary_symlink_real_ancestry_rejected(self):
        # override → symlink whose REAL target sits under a writable dir → ancestor_writable
        realpath = {"/opt/homebrew/bin/cliclick": "/opt/homebrew/Cellar/cliclick/5.1/bin/cliclick"}
        files = {"/opt/homebrew/Cellar/cliclick/5.1/bin/cliclick": (0o755, 501)}
        dirs = {
            "/opt/homebrew/Cellar/cliclick/5.1/bin": (0o755, 501),
            "/opt/homebrew/Cellar/cliclick/5.1": (0o755, 501),
            "/opt/homebrew/Cellar/cliclick": (0o755, 501),
            "/opt/homebrew/Cellar": (0o775, 501),  # the real-world writable ancestor
            "/opt/homebrew": (0o755, 501), "/opt": (0o755, 0), "/": (0o755, 0),
        }
        with _patch_fs(files=files, dirs=dirs, realpath=realpath):
            reason, _ = logic_bounce_ui._evaluate_arbitrary("/opt/homebrew/bin/cliclick", {})
            self.assertEqual(reason, logic_bounce_ui.R_ANCESTOR_WRITABLE)

    def test_arbitrary_sha256_match_and_mismatch(self):
        digest = "a" * 64
        with _patch_fs(**_APPROVED, sha256={"/approved/bin/cliclick": digest}):
            ok, _ = logic_bounce_ui._evaluate_arbitrary(
                "/approved/bin/cliclick", {"LOGIC_PRO_MCP_CLICLICK_SHA256": digest.upper()})
            self.assertEqual(ok, logic_bounce_ui.R_RESOLVED)
            bad, _ = logic_bounce_ui._evaluate_arbitrary(
                "/approved/bin/cliclick", {"LOGIC_PRO_MCP_CLICLICK_SHA256": "b" * 64})
            self.assertEqual(bad, logic_bounce_ui.R_SHA256_MISMATCH)

    def test_arbitrary_sha256_blank_or_malformed_rejected(self):
        with _patch_fs(**_APPROVED, sha256={"/approved/bin/cliclick": "a" * 64}):
            blank, _ = logic_bounce_ui._evaluate_arbitrary(
                "/approved/bin/cliclick", {"LOGIC_PRO_MCP_CLICLICK_SHA256": "   "})
            self.assertEqual(blank, logic_bounce_ui.R_SHA256_MISMATCH)
            nonhex, _ = logic_bounce_ui._evaluate_arbitrary(
                "/approved/bin/cliclick", {"LOGIC_PRO_MCP_CLICLICK_SHA256": "z" * 64})
            self.assertEqual(nonhex, logic_bounce_ui.R_SHA256_MISMATCH)

    # --- resolution + classification + diagnosis ---
    def test_resolution_override_arbitrary_then_canonical_fallthrough(self):
        # env override rejected (writable ancestor) must NOT suppress canonical fallthrough
        dirs = {"/approved/bin": (0o775, 501), "/approved": (0o755, 0), "/": (0o755, 0),
                "/opt/homebrew/bin": (0o755, 501)}
        files = {"/approved/bin/cliclick": (0o755, 501), "/opt/homebrew/bin/cliclick": (0o755, 501)}
        with _patch_fs(files=files, dirs=dirs):
            res = logic_bounce_ui.cliclick_resolution(
                environ={"LOGIC_PRO_MCP_CLICLICK": "/approved/bin/cliclick"})
            self.assertEqual(res.resolved_path, "/opt/homebrew/bin/cliclick")
            reasons = {c.path: c.reason for c in res.candidates}
            self.assertEqual(reasons["/approved/bin/cliclick"], logic_bounce_ui.R_ANCESTOR_WRITABLE)

    def test_resolution_diagnostic_summary_lists_reasons(self):
        with _patch_fs(files={}, dirs={"/opt/homebrew/bin": (0o775, 501)}):
            res = logic_bounce_ui.cliclick_resolution(environ={})
            self.assertIsNone(res.resolved_path)
            summary = res.diagnostic_summary()
            self.assertIn("parent_writable", summary)
            self.assertIn("chmod g-w /opt/homebrew/bin", summary)

    def test_classify_override_into_canonical_dir_uses_canonical_rule(self):
        # --cliclick-path = a canonical path (a symlink) must validate via canonical (no symlink follow)
        realpath = {"/opt/homebrew/bin/cliclick": "/opt/homebrew/Cellar/x/bin/cliclick"}
        with _patch_fs(files={"/opt/homebrew/bin/cliclick": (0o755, 501)},
                       dirs={"/opt/homebrew/bin": (0o755, 501)}, realpath=realpath):
            res = logic_bounce_ui.cliclick_resolution(
                override="/opt/homebrew/bin/cliclick", environ={})
            self.assertEqual(res.resolved_path, "/opt/homebrew/bin/cliclick")

    def test_override_arg_arbitrary_uses_injected_environ_for_sha256(self):
        digest = "a" * 64
        with _patch_fs(**_APPROVED, sha256={"/approved/bin/cliclick": digest}):
            res = logic_bounce_ui.cliclick_resolution(
                override="/approved/bin/cliclick",
                environ={"LOGIC_PRO_MCP_CLICLICK_SHA256": "b" * 64},
            )
            self.assertIsNone(res.resolved_path)
            self.assertEqual(res.candidates[0].reason, logic_bounce_ui.R_SHA256_MISMATCH)

    def test_set_resolved_cliclick_is_used_by_cliclick(self):
        captured = {}

        def fake_run(cmd, **kwargs):
            captured["exe"] = cmd[0]
            class R: returncode = 0
            return R()

        logic_bounce_ui.set_resolved_cliclick("/cached/cliclick")
        try:
            with mock.patch.object(logic_bounce_ui.subprocess, "run", side_effect=fake_run):
                self.assertTrue(logic_bounce_ui.cliclick("c:1,1"))
            self.assertEqual(captured["exe"], "/cached/cliclick")
        finally:
            logic_bounce_ui.set_resolved_cliclick(None)

    def test_canonical_directory_rejected(self):
        # boomer #1 parity: a directory at a canonical path must be rejected (isfile=False),
        # never accepted — matches the Swift isRegularFile fix.
        with _patch_fs(files={}, dirs={"/opt/homebrew/bin/cliclick": (0o755, 501),
                                       "/opt/homebrew/bin": (0o755, 501)},
                       executables={"/opt/homebrew/bin/cliclick"}):
            self.assertEqual(logic_bounce_ui._evaluate_canonical("/opt/homebrew/bin/cliclick"),
                             logic_bounce_ui.R_NOT_FOUND)
