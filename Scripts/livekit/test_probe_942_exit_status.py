#!/usr/bin/env python3
"""The #942 probe's exit fails on everything `is_clean` fails on, except the server clause it waives.

Round 1 of #1019's review fed the probe's exit two passing checks and one failed visual and got 0:
the exit compared `passed` with `checks` and never read the visual count `ev.write()` keeps beside
them. These cases drive `exit_status` with summaries built from a clean one.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import evidence as E  # noqa: E402
import probe_942_escape_over_goto_dialog as probe  # noqa: E402

CLEAN = {key: 0 for key in E._REQUIRED_SUMMARY_KEYS}
CLEAN.update({
    "checks": 2, "passed": 2, "mutation_claimed": 2, "captures": 3, "visual_assertions": 3,
    "recordings": 1, "declared_surface": "ui", "screen_locked": False,
})


def main():
    failures = []

    def expect(name, got, want):
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    expect("the clean control passes, with no server operation driven",
           probe.exit_status(True, CLEAN), 0)
    expect("the control is not clean under is_clean itself, which is the one waived clause",
           E.is_clean(CLEAN), False)
    expect("a failed visual fails the command",
           probe.exit_status(True, {**CLEAN, "visual_failed": 1}), 1)
    expect("a failed check fails the command",
           probe.exit_status(True, {**CLEAN, "passed": 1}), 1)
    expect("a failed restoration fails the command",
           probe.exit_status(True, {**CLEAN, "restorations_failed": 1}), 1)
    expect("an incomplete sample set fails the command", probe.exit_status(False, CLEAN), 1)
    expect("no summary fails the command", probe.exit_status(True, None), 1)

    if failures:
        print("\n".join(failures))
        return 1
    print("ok: 7 cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
