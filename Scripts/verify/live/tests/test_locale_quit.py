#!/usr/bin/env python3
"""Offline: quitting Logic answers a save prompt only when every window's document was read and
every document is the fixture (PR #1033 review R1).

osascript, the process check, the discard press and the settle are replaced; nothing talks to
Logic. Each test names the mutation of locale.py it kills.
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

from live import locale as live_locale  # noqa: E402
from live import obs  # noqa: E402

FIXTURE = "/Users/me/Music/Logic/fixture.logicx"
FIXTURE_URL = "file:///Users/me/Music/Logic/fixture.logicx/"
END = "lpm:end-of-documents"


def listing(*rows):
    return "\n".join([f"lpm:windows {len(rows)}", *rows, END])


class Quit(unittest.TestCase):

    def setUp(self):
        self.saved = {name: getattr(live_locale, name) for name in
                      ("logic_running", "press_discard", "QUIT_TIMEOUT_S")}
        self.saved_osascript = obs.osascript
        self.saved_settle = live_locale.screen.settle_to_clean
        self.calls, self.discards, self.running = [], [], True
        live_locale.logic_running = lambda: obs.readable(self.running)
        live_locale.press_discard = self.discard
        live_locale.QUIT_TIMEOUT_S = 0.2
        live_locale.screen.settle_to_clean = lambda **kw: {"final": {"dirt": []}}

    def tearDown(self):
        for name, value in self.saved.items():
            setattr(live_locale, name, value)
        obs.osascript = self.saved_osascript
        live_locale.screen.settle_to_clean = self.saved_settle

    def discard(self):
        self.discards.append(True)
        return {"stdout": "Don't Save"}

    def answering(self, documents_stdout):
        def osascript(script, timeout_s=20):
            self.calls.append(script)
            if "AXDocument" in script:
                return {"returncode": 0, "stdout": documents_stdout, "stderr": ""}
            if "to quit" in script:
                self.running = False
            return {"returncode": 0, "stdout": "", "stderr": ""}
        obs.osascript = osascript

    def quit_sent(self):
        return any("to quit" in call for call in self.calls)

    def test_the_reviewers_failed_read_refuses_and_never_discards(self):
        # Kills: a failed AXDocument read folded into "no document" (the old silent `try`, whose
        # output was the terminator alone and read as an empty list).
        self.answering(END)
        record = live_locale.quit_logic(FIXTURE)
        self.assertFalse(record["quit"])
        self.assertFalse(self.quit_sent())
        self.assertEqual(self.discards, [])
        self.assertFalse(record["documents"]["readable"])

    def test_one_failed_window_read_refuses(self):
        # Kills: others_than ignoring rows whose outcome is unreadable.
        self.answering(listing(f"doc\tAXStandardWindow\t{FIXTURE_URL}",
                               "error\tAXFloatingWindow\t-1728\tCan't get attribute"))
        record = live_locale.quit_logic(FIXTURE)
        self.assertFalse(record["quit"])
        self.assertFalse(self.quit_sent())
        self.assertEqual(self.discards, [])
        self.assertEqual([r["outcome"] for r in record["documents"]["value"]],
                         ["document", "unreadable"])

    def test_an_untitled_project_window_refuses(self):
        # Kills: a project window with no AXDocument read as a palette.
        self.answering(listing(f"doc\tAXStandardWindow\t{FIXTURE_URL}", "none\tAXStandardWindow"))
        self.assertFalse(live_locale.quit_logic(FIXTURE)["quit"])
        self.assertFalse(self.quit_sent())

    def test_another_document_refuses(self):
        self.answering(listing(f"doc\tAXStandardWindow\t{FIXTURE_URL}",
                               "doc\tAXStandardWindow\tfile:///Users/me/Other.logicx/"))
        self.assertFalse(live_locale.quit_logic(FIXTURE)["quit"])
        self.assertFalse(self.quit_sent())

    def test_rows_that_are_not_the_counted_windows_refuse(self):
        # Kills: the header count not compared with the rows.
        self.answering("lpm:windows 2\n" + f"doc\tAXStandardWindow\t{FIXTURE_URL}\n" + END)
        self.assertFalse(live_locale.quit_logic(FIXTURE)["quit"])
        self.assertFalse(self.quit_sent())

    def test_the_fixture_and_a_palette_quit(self):
        self.answering(listing(f"doc\tAXStandardWindow\t{FIXTURE_URL}", "none\tAXFloatingWindow"))
        record = live_locale.quit_logic(FIXTURE)
        self.assertTrue(self.quit_sent())
        self.assertTrue(record["quit"])


if __name__ == "__main__":
    unittest.main()
