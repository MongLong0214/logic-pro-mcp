#!/usr/bin/env python3
"""The #942 live harness reads Logic's windows by the rules of the settlement it judges.

The ko pilot at f84c45e4 went red on two readings the server had taken correctly. A Logic-owned
window with no name, 89 x 19 points at layer 103, was on screen before the `nothing` hold and stayed
through it; the harness counted every Logic window at or above the pop-up menu level as a menu and
read one where `popupMenuCount` read none, because the server counts layer 101 exactly. And Logic
titles the Step Input Keyboard window `<project> - <title>`, which the product matches with
`.contains`; the harness compared the whole name, saw no keyboard window, and so neither judged
the unidentified hold nor closed the window afterwards.

These cases feed `classify` the raw entries from that run and pin each reading to the server's
rule: menus are layer 101 exactly (`popupMenuCount`), an appeared window is any Logic window not in
the baseline and not at the menu level (`appearedSince`), the dialog is named exactly
(`.exactStrict`) and the keyboard window by containment (`.contains`, case-insensitive). Names
Logic spells per language come from the label canon, not from this file.
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import probe_942_escape_over_goto_dialog as P  # noqa: E402


def load(name):
    """The harness from its file, as Scripts/test_live_904_labelset_rows.py loads its own: a
    `live_*.py` is an entry point, and check-dead-harness-helpers refuses one that is imported."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


H = load("live_942_post_leaf_settlement_in_every_locale")

#: kCGPopUpMenuWindowLevelKey as the pilot's macOS answered it; the server reads the same key.
MENU_LEVEL = 101
PROJECT = "lpm-locale-campaign"
DIALOG = P.names("goToPositionDialogTitle")
KEYBOARD = P.names("stepInputKeyboardWindowTitle")


def window(number, layer, name, x, y, w, h):
    return {"id": number, "layer": layer, "name": name,
            "bounds": {"X": x, "Y": y, "Width": w, "Height": h}}


# Logic's windows before the ko pilot's `nothing` hold. The two named ones carry labels Logic
# spells per language, so their names are withheld here; nothing below reads them.
OVERLAY = window(1460, 103, "", 827, 1019, 89, 19)
MARKER_LIST = window(1459, 3, None, 20, 50, 452, 746)
MAIN = window(1458, 0, None, 0, 30, 1920, 1050)
BASELINE = [OVERLAY, MARKER_LIST, MAIN]
BASELINE_IDS = {w["id"] for w in BASELINE}
#: The Navigate menu as the probe measured it on 2026-09-26 (docs/observations, menus_over_dialog).
MENU = window(2001, MENU_LEVEL, None, 250, 31, 348, 436)


def classify(windows, owner=True):
    return H.classify(windows, BASELINE_IDS, level=MENU_LEVEL, keyboard_owner=owner)


def main():
    failures = []
    counted = [0]

    def expect(name, compute, want):
        counted[0] += 1
        try:
            got = compute()
        except Exception as error:  # noqa: BLE001 -- an old shape raising is a red case, not a crash
            failures.append(f"{name}: raised {error!r}")
            return
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    expect("no window list: no reading", lambda: classify(None), None)
    expect("the layer-103 window in the baseline is not a menu",
           lambda: classify(BASELINE)["menus"], 0)
    expect("the baseline leaves nothing appeared",
           lambda: classify(BASELINE)["new_windows"], [])
    expect("a layer-101 window is the one menu", lambda: classify(BASELINE + [MENU])["menus"], 1)
    expect("the menu is not an appeared window",
           lambda: classify(BASELINE + [MENU])["new_windows"], [])
    expect("the helper counts the menu the same way",
           lambda: P.menus(BASELINE + [MENU], MENU_LEVEL), [MENU])
    expect("the helper counts no menu in the baseline", lambda: P.menus(BASELINE, MENU_LEVEL), [])

    for title in KEYBOARD:
        keyboard = window(1466, 3, f"{PROJECT} - {title}", 733, 402, 454, 246)
        expect(f"the keyboard window titled after the project is read as one ({title!r})",
               lambda: classify(BASELINE + [MENU, keyboard])["keyboard_windows"], [keyboard])
        expect(f"the keyboard window is not the dialog ({title!r})",
               lambda: classify(BASELINE + [MENU, keyboard])["dialogs"], [])
        expect(f"the keyboard window is an appeared window ({title!r})",
               lambda: classify(BASELINE + [MENU, keyboard])["new_windows"], [keyboard])
    shouted = window(1466, 3, f"{PROJECT} - {KEYBOARD[0].upper()}", 733, 402, 454, 246)
    expect("the keyboard title matches without regard to case",
           lambda: classify(BASELINE + [shouted])["keyboard_windows"], [shouted])

    dialog = window(1470, 8, DIALOG[0], 760, 255, 399, 155)
    expect("the dialog named exactly is the one dialog",
           lambda: classify(BASELINE + [dialog])["dialogs"], [dialog])
    prefixed = window(1470, 8, f"{PROJECT} - {DIALOG[0]}", 760, 255, 399, 155)
    expect("a window that merely contains the dialog title is not the dialog",
           lambda: classify(BASELINE + [prefixed])["dialogs"], [])
    expect("but it did appear", lambda: classify(BASELINE + [prefixed])["new_windows"], [prefixed])

    above = window(1490, 103, "", 827, 1019, 89, 19)
    expect("a new window above the menu level is an appeared window, as the server counts it",
           lambda: classify(BASELINE + [above])["new_windows"], [above])
    expect("and it is not a menu", lambda: classify(BASELINE + [above])["menus"], 0)
    expect("the keyboard owner is carried through unread",
           lambda: classify(BASELINE, owner=None)["keyboard_owner_is_logic"], None)

    if failures:
        print("FAIL (%d): " % len(failures) + "; ".join(failures))
        return 1
    print("OK: the #942 harness reads menus, appeared windows, the dialog and the keyboard window "
          "by the server's rules (%d cases)" % counted[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
