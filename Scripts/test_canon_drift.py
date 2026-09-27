#!/usr/bin/env python3
"""Drives `check-canon-drift.py` (#1028): offline drift fails, host drift warns, CI says it skipped.

Each case points the guard at a manifest written into a temporary directory, so none of them
depends on the committed canon or on whether this machine has Logic.
"""
import contextlib
import importlib.util
import io
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "check-canon-drift.py")

_spec = importlib.util.spec_from_file_location("canon_drift_guard", GUARD)
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)
canon = guard._canon()


def _manifest(tmp, *, extractor=None, sources=None, version="12.3", build="6674"):
    path = os.path.join(tmp, "MANIFEST.json")
    with open(path, "w") as handle:
        json.dump({"schema": 1,
                   "extractor_version": canon.EXTRACTOR_VERSION if extractor is None else extractor,
                   "logic": {"app": "Logic Pro", "version": version, "build": build},
                   "sources": {name: {} for name in (sorted(canon.EXTRACTORS)
                                                     if sources is None else sources)}}, handle)
    return path


def _app(tmp, version, build):
    app = os.path.join(tmp, "Logic Pro.app")
    os.makedirs(os.path.join(app, "Contents"))
    with open(os.path.join(app, "Contents", "Info.plist"), "wb") as handle:
        plistlib.dump({"CFBundleName": "Logic Pro", "CFBundleShortVersionString": version,
                       "CFBundleVersion": build}, handle)
    return app


def _run(manifest_path, app, ci):
    before = canon.MANIFEST_PATH
    canon.MANIFEST_PATH = manifest_path
    out, err = io.StringIO(), io.StringIO()
    try:
        code = guard.run(canon, app, ci, out=out, err=err)
    finally:
        canon.MANIFEST_PATH = before
    return code, out.getvalue(), err.getvalue()


class OfflineDriftFails(unittest.TestCase):
    def test_another_extractor_version_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, _out, err = _run(_manifest(tmp, extractor=canon.EXTRACTOR_VERSION - 1),
                                   "/nonexistent.app", ci=True)
        self.assertEqual(code, 1)
        self.assertIn("extractor", err)

    def test_a_source_the_manifest_does_not_pin_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            pinned = [name for name in sorted(canon.EXTRACTORS) if name != "stringsdict"]
            code, _out, err = _run(_manifest(tmp, sources=pinned), "/nonexistent.app", ci=True)
        self.assertEqual(code, 1)
        self.assertIn("stringsdict", err)

    def test_a_current_manifest_passes(self):
        """The control: without it the cases above pass on a guard that always fails."""
        with tempfile.TemporaryDirectory() as tmp:
            code, out, _err = _run(_manifest(tmp), "/nonexistent.app", ci=True)
        self.assertEqual(code, 0)
        self.assertIn("offline ok", out)


class TheHostCheckNeverPassesSilently(unittest.TestCase):
    def test_ci_says_it_skipped_and_why(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = _app(tmp, "99.0", "1")
            code, out, _err = _run(_manifest(tmp), app, ci=True)
        self.assertEqual(code, 0)
        self.assertIn("host check SKIPPED: CI has no Logic", out)

    def test_a_different_host_logic_warns_loudly(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = _app(tmp, "12.4", "6700")
            code, _out, err = _run(_manifest(tmp), app, ci=False)
        self.assertEqual(code, 0)
        self.assertIn("WARNING", err)
        self.assertIn("12.4", err)

    def test_the_same_host_logic_says_it_matched(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = _app(tmp, "12.3", "6674")
            code, out, err = _run(_manifest(tmp), app, ci=False)
        self.assertEqual((code, err), (0, ""))
        self.assertIn("matches", out)

    def test_no_logic_says_it_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, out, _err = _run(_manifest(tmp), os.path.join(tmp, "absent.app"), ci=False)
        self.assertEqual(code, 0)
        self.assertIn("host check SKIPPED: no Logic", out)


class TheEntryPoint(unittest.TestCase):
    def test_main_runs_against_the_tree(self):
        proc = subprocess.run([sys.executable, GUARD], capture_output=True, text=True,
                              env=dict(os.environ, CI="1"))
        self.assertIn("check-canon-drift:", proc.stdout + proc.stderr)
        self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[-400:])


if __name__ == "__main__":
    unittest.main(verbosity=2)
