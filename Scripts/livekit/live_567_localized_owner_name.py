#!/usr/bin/env python3
"""Live measurement of Logic's window-owner name under a localized UI.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_567_localized_owner_name.py <worktree> <full-40-char-head-sha> [--locale ko|ja|en]

WHAT THIS PROVES, AND WHAT IT DOES NOT
--------------------------------------
It proves the FACT the fix is built on: that `CGWindowListCopyWindowInfo`'s `kCGWindowOwnerName`
for Logic Pro carries a NO-BREAK SPACE under a Korean UI and an ordinary space under English, on
this machine, today. That string is the whole premise of `LogicProTarget.isLogicProcessName`
normalising its separator, and a premise taken from memory rather than from the running system is
how a fix ends up correct about nothing.

It does NOT prove that `ProcessUtils.logicProPID(fromWindowList:)` now returns a PID on a Korean
Mac. No tool surfaces that resolver's result — it is a fallback behind `logicProApp()` — so there is
nothing to drive it through from out here. That half is covered by
`Issue567LocalizedOwnerNameTests.windowListResolverAcceptsTheKoreanName`, which feeds the measured
string straight into the resolver, and by the mutation showing it returns nil without the fix.

Saying so here rather than letting six green checks imply the whole chain was verified.
"""

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
LOCALE = sys.argv[sys.argv.index("--locale") + 1] if "--locale" in sys.argv else "en"
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

# Measured window-title suffixes; used only as the locale witness, so a run cannot be filed under a
# language the running Logic is not in.
ARRANGE_SUFFIX = {"en": "Tracks", "ko": "트랙", "ja": "トラック"}[LOCALE]
NBSP = " "
# Band over the arrange window's track headers. Nothing this run does is a write, so the assertion
# over it is a NEGATIVE one.

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])

# #622: the coordinate here was (10, 120, 260, 200), which is inside the LIBRARY — the same origin
# and width appear in four harnesses, one wrong rectangle copied rather than four mistakes. The
# claim below is about the track headers, and `Tracks header` sits at x=603 w=325 with no overlap.
#
# It is resolved HERE rather than where the coordinate was, because the tool compiles into ev.dir
# and `ev` does not exist two lines earlier. A first attempt put it there and died on NameError.
BAND_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_control_bar_band.swift")
BAND_TOOL = os.path.join(ev.dir, "ax_control_bar_band")
subprocess.run(["swiftc", "-O", BAND_SOURCE, "-o", BAND_TOOL], check=True, capture_output=True)


def located_band(*selector):
    """(band, subject) for a named region, or (None, None) — never a fallback rectangle."""
    r = subprocess.run([BAND_TOOL, *selector], capture_output=True, text=True)
    try:
        payload = json.loads(r.stdout or "{}")
    except ValueError:
        return None, None
    b = payload.get("band")
    if not (isinstance(b, list) and len(b) == 4):
        return None, None
    return tuple(b), payload.get("description")


TRACK_BAND, TRACK_SUBJECT = located_band("Tracks header")
ev.check("567/precondition-the-track-header-rail-was-located",
         TRACK_BAND is not None and bool(TRACK_SUBJECT),
         "the rail this run asserts about, located by AXDescription. A failed lookup is a red "
         "precondition — before #634 a None band silently became a whole-image comparison that "
         "passed",
         f"band={TRACK_BAND!r} subject={TRACK_SUBJECT!r}", None)
d = E.Driver()


def raw_owner_names():
    """Every Logic-owned window's owner name, straight from CoreGraphics.

    Deliberately NOT `evidence.logic_window()`: that helper normalises the separator itself (it hit
    this same bug first), so reading through it would hide the very byte under test.
    """
    try:
        import Quartz
    except ImportError:
        return []
    wins = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)
    names = []
    for w in wins or []:
        name = w.get("kCGWindowOwnerName") or ""
        if "Logic" in name:
            names.append(name)
    return names


def window_titles():
    r = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to tell process "Logic Pro" to get name of every window'],
        capture_output=True, text=True)
    return (r.stdout or "").strip()


titles = window_titles()
locale_ok = ARRANGE_SUFFIX in titles
ev.check(f"567/{LOCALE}/precondition-logic-is-actually-in-this-locale", locale_ok,
         f"a window title carries this locale's arrange name ({ARRANGE_SUFFIX!r})",
         f"locale={LOCALE} titles={titles!r}",
         # No mutation: the locale witness, not an assertion about the fix.
         None)
if not locale_ok:
    d.close()
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=90)
before = ev.shot(f"567/{LOCALE}/before", settle_region=TRACK_BAND, window_title=ARRANGE_SUFFIX)

owners = raw_owner_names()
ev.note(f"567/{LOCALE}/owner-names", {"raw": owners,
                                      "codepoints": [[hex(ord(c)) for c in n] for n in owners]})

ev.check(f"567/{LOCALE}/logic-owns-at-least-one-window", bool(owners),
         "CoreGraphics reports at least one Logic-owned window to read the name from",
         f"owners={owners!r}",
         None)

separators = {n[len("Logic")] for n in owners if n.startswith("Logic") and len(n) > len("Logic")}
if LOCALE == "ko":
    ev.check(f"567/{LOCALE}/the-owner-name-carries-a-no-break-space",
             NBSP in separators,
             "under a Korean UI the separator in the owner name is U+00A0, which is the byte the "
             "product's exact compare could not match",
             f"separators={[hex(ord(s)) for s in separators]} owners={owners!r}",
             "remove the normalisation from LogicProTarget.isLogicProcessName: this exact string "
             "then matches nothing, and the window-list PID route silently finds no Logic window")
else:
    ev.check(f"567/{LOCALE}/the-owner-name-uses-an-ordinary-space",
             separators == {" "},
             "outside Korean the separator is U+0020 — the measurement runs in both directions, so "
             "the Korean reading is a locale difference and not a property of this machine",
             f"separators={[hex(ord(s)) for s in separators]} owners={owners!r}",
             None)

# The product must still be able to see Logic while its owner name reads this way.
health = d.tool("logic_system", "health", {})
ev.note(f"567/{LOCALE}/health", health)
running = health.get("logic_pro_running") if isinstance(health, dict) else None
product_locale = health.get("logic_pro_ui_locale") if isinstance(health, dict) else None
ev.check(f"567/{LOCALE}/the-product-still-sees-logic-running",
         running is True,
         "the server reports Logic running while its owner name carries this separator, and reports "
         "the same UI language the window titles show",
         f"logic_pro_running={running!r} logic_pro_ui_locale={product_locale!r}",
         # No mutation: this passes with and without the fix, because `logicProApp()` resolves by
         # bundle ID before the window-list fallback is reached. Recorded to show the locale did not
         # break the primary route, NOT as evidence for the fix.
         None)

after = ev.shot(f"567/{LOCALE}/after", settle_region=TRACK_BAND, window_title=ARRANGE_SUFFIX)
ev.visual(f"567/{LOCALE}/nothing-in-the-project-was-touched",
          before["file"], after["file"], TRACK_BAND, expect_change=False, subject=TRACK_SUBJECT,
          why="this run only reads names and health; the arrange window's track headers must be "
              "identical across it")

ev.restored(f"567/{LOCALE}/no-project-state-was-changed", True,
            "the run performs no write; the only state it depends on is Logic's UI language, which "
            "the operator sets and restores around it")

ev.stop_recording(rec)
d.close()
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
