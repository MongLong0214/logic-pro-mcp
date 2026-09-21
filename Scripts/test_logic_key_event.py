#!/usr/bin/env python3
"""Behavioral tests for Scripts/logic_key_event.swift (#186).

The demo capture harness aborted on `--return` ("Unknown option --return").
These tests pin the verified Return/Enter input primitive contract:

- A flag-style `--return` (and `--enter`) resolves to the Return key.
- `--check <key>` is a preflight that validates a key WITHOUT posting an event,
  so a capture harness can fail before recording if a flag is unsupported.
- Unknown keys fail closed (exit 64) and name the supported keys, so a local
  harness failure is distinguishable from a Logic Pro product failure.
- `--help` / `--list` lists the supported keys.

The post-event paths are not exercised here (they require Accessibility/CGEvent
permission and would inject real key presses); `--check` covers the resolution
contract deterministically.
"""

import os
import subprocess
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logic_key_event.swift")


def run_key_event(*args):
    return subprocess.run(
        ["swift", SCRIPT, *args],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


class LogicKeyEventContractTests(unittest.TestCase):
    def test_help_lists_supported_keys(self):
        result = run_key_event("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        for key in ("return", "enter", "escape", "space"):
            self.assertIn(key, result.stdout)

    def test_check_flag_return_resolves(self):
        # #186: a flag-style --return must resolve to the verified Return key.
        result = run_key_event("--check", "--return")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ok:return")

    def test_check_enter_aliases_return(self):
        result = run_key_event("--check", "enter")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ok:return")

    def test_check_bare_return_resolves(self):
        result = run_key_event("--check", "return")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ok:return")

    def test_check_escape_aliases(self):
        for token in ("escape", "esc", "--escape"):
            result = run_key_event("--check", token)
            self.assertEqual(result.returncode, 0, f"{token}: {result.stderr}")
            self.assertEqual(result.stdout.strip(), "ok:escape")

    def test_unknown_key_fails_closed_with_supported_list(self):
        result = run_key_event("--check", "--bogus")
        self.assertEqual(result.returncode, 64)
        self.assertIn("unknown_key", result.stderr)
        # Names the supported keys so a harness failure is self-explanatory.
        self.assertIn("return", result.stderr)

    def test_no_argument_is_usage_error(self):
        result = run_key_event()
        self.assertEqual(result.returncode, 64)
        self.assertIn("usage", result.stdout.lower())


if __name__ == "__main__":
    unittest.main()
