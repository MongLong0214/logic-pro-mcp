#!/usr/bin/env python3
"""The #1016 probe's clean-up sends Escape only after a reading that counted a Logic menu.

Round 2 of #1017's review found the clean-up typing Escape into whatever owned the keyboard while
every window-list read came back unknown: four Escapes, none of them measured. These cases drive the
helper with stubbed readings and count the Escapes it sends.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import probe_1016_refusal_leaves_no_menu as probe  # noqa: E402

MENU = [{"id": 1, "layer": 101, "bounds": {}}]


def run(readings, owner=True):
    """`(result, escapes)` for `close_menus()` fed `readings` in order (the last one repeats)."""
    queue = list(readings)
    escapes = []
    probe.open_logic_menus = lambda: queue.pop(0) if len(queue) > 1 else queue[0]
    probe.logic_owns_keyboard = lambda: owner
    probe.osa = lambda script, timeout=10: escapes.append(script)
    probe.time.sleep = lambda seconds: None
    return probe.close_menus(), len(escapes)


def main():
    failures = []

    def expect(name, got, want):
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    expect("every read unknown: no Escape, unknown result", run([None]), (None, 0))
    expect("nothing counted: no Escape, clean result", run([[]]), ([], 0))
    expect("a counted menu that one Escape closes", run([MENU, []]), ([], 1))
    expect("a counted menu, then an unknown read: stops", run([MENU, None]), (None, 1))
    expect("a counted menu with another app in front: no Escape", run([MENU], owner=False), (None, 0))
    expect("a counted menu with an unread keyboard owner: no Escape", run([MENU], owner=None), (None, 0))
    expect("a menu that never closes: four Escapes, the menu reported", run([MENU]), (MENU, 4))

    if failures:
        print("FAIL: " + "; ".join(failures))
        return 1
    print("OK: the #1016 probe's clean-up sends Escape only after a counted Logic menu (7 cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
