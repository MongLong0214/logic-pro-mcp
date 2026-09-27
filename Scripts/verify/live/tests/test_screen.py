#!/usr/bin/env python3
"""Offline: clean-state classification from recorded samples, and settle_to_clean's one rule.

The samples in samples/ were taken by `screen.sample()` on 2026-09-27 against a Korean Logic on the
locale-campaign fixture, reduced to Logic's windows (and any at the modal, menu or help levels):

  base-2026-09-27-ko.json          nothing open; the Marker List floats at layer 3 and its sheet
                                   search answers -25200 (kAXErrorFailure), which is dirt
  menu-open-2026-09-27-ko.json     the app menu open by an AX click: a Logic window at layer 101
  modal-open-2026-09-27-ko.json    Go To Position open: a Logic window at layer 8, AXModal true
  tooltip-constructed-from-base.json  NOT recorded -- see its "constructed" field

Each test names the mutation of screen.py it kills.
"""

import copy
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

from live import screen  # noqa: E402

SAMPLES = os.path.join(HERE, "samples")


def load(name):
    with open(os.path.join(SAMPLES, name), encoding="utf-8") as handle:
        return json.load(handle)


def kinds(sample):
    return sorted(d["kind"] for d in screen.classify(sample))


class RecordedSamples(unittest.TestCase):

    def test_menu_at_101_is_an_open_menu(self):
        # Kills: the menu band `popup_menu <= layer < help` narrowed to `layer > popup_menu`
        # (101 itself missed), or the owner test dropped for a menu.
        self.assertIn("menu_open", kinds(load("menu-open-2026-09-27-ko.json")))

    def test_modal_at_8_is_a_modal_by_window_level_and_by_ax(self):
        # Kills: the modal-panel branch deleted from classify(), or AXModal True ignored.
        found = kinds(load("modal-open-2026-09-27-ko.json"))
        self.assertIn("modal_panel_level", found)
        self.assertIn("ax_modal", found)
        self.assertNotIn("menu_open", found)

    def test_a_tooltip_is_not_a_modal_and_not_a_menu(self):
        # Kills: -25205 dropped from the AXModal answers (the tooltip's answer then reads as
        # unreadable dirt), or the menu band's upper bound (help level) removed (layer 200 then
        # reads as a menu).
        base = kinds(load("base-2026-09-27-ko.json"))
        with_tooltip = kinds(load("tooltip-constructed-from-base.json"))
        self.assertEqual(with_tooltip, base)

    def test_an_unreadable_sheet_search_is_dirt_not_clean(self):
        # Kills: an unreadable sheet search folded into "no sheet".
        self.assertEqual(kinds(load("base-2026-09-27-ko.json")), ["ax_sheet_unreadable"])

    def test_another_apps_window_at_101_is_not_logic_dirt(self):
        # Kills: the owner test dropped (the NBSP-normalised Logic owner no longer required).
        sample = load("menu-open-2026-09-27-ko.json")
        for window in sample["windows"]["value"]:
            window["owner"] = "Finder"
        self.assertNotIn("menu_open", kinds(sample))

    def test_screen_locked_and_lock_unreadable_are_both_dirt(self):
        # Kills: the lock read ignored, or an unreadable lock folded into unlocked.
        sample = load("base-2026-09-27-ko.json")
        locked = copy.deepcopy(sample)
        locked["screen_locked"] = {"readable": True, "value": True}
        self.assertIn("screen_locked", kinds(locked))
        unread = copy.deepcopy(sample)
        unread["screen_locked"] = {"readable": False, "cause": "no dictionary"}
        self.assertIn("screen_lock_unreadable", kinds(unread))

    def test_an_unreadable_window_list_is_dirt(self):
        sample = load("base-2026-09-27-ko.json")
        sample["windows"] = {"readable": False, "cause": "CGWindowListCopyWindowInfo: NULL"}
        self.assertIn("window_list_unreadable", kinds(sample))


class SettleSendsEscapeOnlyForAMenu(unittest.TestCase):

    def run_settle(self, first, then):
        samples = [first] + [then] * 20
        sent = []

        def sampler():
            s = samples.pop(0) if len(samples) > 1 else samples[0]
            return {"observation": s, "dirt": screen.classify(s)}

        return screen.settle_to_clean(timeout_s=2.0, sampler=sampler,
                                      escaper=lambda: sent.append(1) or {"returncode": 0}), sent

    def test_a_measured_menu_gets_one_escape_and_is_recorded(self):
        # Kills: settle sending nothing (the menu branch removed).
        result, sent = self.run_settle(load("menu-open-2026-09-27-ko.json"),
                                       load("base-2026-09-27-ko.json"))
        self.assertEqual(len(sent), 1)
        self.assertEqual(result["escapes_sent"], 1)
        self.assertEqual(result["actions"][0]["because"][0]["kind"], "menu_open")

    def test_a_modal_with_no_menu_gets_no_escape(self):
        # Kills: Escape sent for any dirt (reference_escape_closes_menu_before_modal_dialog:
        # with no menu open, Escape cancels the dialog).
        modal = load("modal-open-2026-09-27-ko.json")
        result, sent = self.run_settle(modal, modal)
        self.assertEqual(sent, [])
        self.assertEqual(result["actions"], [])
        self.assertIn("ax_modal", [d["kind"] for d in result["final"]["dirt"]])


if __name__ == "__main__":
    unittest.main()
