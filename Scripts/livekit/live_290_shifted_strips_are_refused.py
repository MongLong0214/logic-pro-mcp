#!/usr/bin/env python3
"""Live proof that the ordinal-write guard did not break the path it guards.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_290_shifted_strips_are_refused.py <worktree> <full-40-char-head-sha>

WHAT CHANGED
------------
`stripEnumeration` has always counted the mixer children whose role would not read, and every caller
threw that count away. Its own comment says what the count is for:

    A child whose role is unreadable is dropped by the filter, and every later strip then moves down
    one. Callers address strips by ORDINAL, so a request for track 0 would act on physical strip 1 —
    a wrong-target write that no downstream readback can catch, because the readback reads the same
    shifted list.

`mixer.insert_plugin` is such a caller and it is a WRITE. It now refuses, State C with
`write_attempted: false`, when any mixer child would not report a role. That is ADR-007's rule at the
one place it is already measurable: resolve exactly, or refuse.

WHAT THIS RUN CAN AND CANNOT SHOW
---------------------------------
The refusal branch cannot be reached live. It fires when Logic's Accessibility tree fails to report a
role for a mixer child — a transient the run cannot induce without corrupting the very tree it is
measuring, and inducing it would prove the fake, not the guard. That branch is covered by unit tests
with an injected AX failure, and by a mutation that removes the guard and reddens only its own test.

What this run shows is the half a unit test cannot: that on a mixer Logic reads completely, the guard
lets everything through. A guard is only as good as its false-positive rate, and the cheapest way for
this one to be wrong is to refuse a mixer that is perfectly fine.
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
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])
CHOOSER_TITLES = ("Choose a Project", "프로젝트 선택")


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_titles():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def document_titles():
    return [t for t in window_titles() if not any(c in t for c in CHOOSER_TITLES)]


def toggle_mixer():
    return osa('tell application "System Events" to tell process "Logic Pro" to '
               'click (first menu item of menu 1 of menu bar item "View" of menu bar 1 '
               'whose name contains "Mixer")')


titles = document_titles()
ev.check("290/precondition-a-project-is-open", bool(titles),
         "Logic has a project window, so there is a mixer to read",
         f"windows={window_titles()!r}", None)
if not titles:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

arrange_title = titles[0]
win = E.logic_window(arrange_title)
# The window's own title bar, and the subject says so. The band is derived from a frame this run
# measured — `logic_window` reads it from CoreGraphics — rather than from a layout somebody
# remembered, and 28 points is the strip that holds the document name.
band = (0, 0, win["w"], 28) if win else None
band_subject = f"the title bar of the {arrange_title!r} window" if win else None
ev.check("290/precondition-the-window-frame-is-known",
         band is not None and bool(band_subject),
         "the arrange window's own frame read, so the capture band is inside it and can be named",
         f"window={win!r} band={band!r} subject={band_subject!r}", None)
if band is None:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

d = E.Driver()
time.sleep(5)


def mixer_readable():
    """Asked of the product: `data_source` is `mixer_not_visible` when its landmark finds no mixer,
    and only a FRESH poll (`ax_poll`) means the strips below are a real read."""
    return ((d.resource("logic://mixer") or {}).get("data_source")) == "ax_poll"


toggles = []
for _ in range(2):
    if mixer_readable():
        break
    toggles.append(toggle_mixer())
    for _ in range(6):
        time.sleep(2)
        if mixer_readable():
            break

was_readable_at_start = not toggles
ev.check("290/precondition-the-product-can-read-the-mixer",
         mixer_readable(),
         "the mixer resource reports a fresh poll, so a strip list exists for the guard to pass or "
         "refuse — asked of the product rather than re-derived from its landmark rule",
         f"toggles={toggles!r} readable={mixer_readable()}", None)

rec = ev.record_screen(seconds=150)
before = ev.shot("290/before", settle_region=band, window_title=arrange_title)

body = d.resource("logic://mixer") or {}
strips = body.get("strips") if isinstance(body.get("strips"), list) else []
age = body.get("cache_age_sec")
ev.provenance("290/mixer-strips", f"state_poller_cache_{body.get('data_source')}",
              round(age, 2) if isinstance(age, (int, float)) else None,
              body.get("data_source") == "ax_poll")
ev.note("290/strips", {"count": len(strips), "data_source": body.get("data_source")})

ev.check("290/the-mixer-reads-completely-on-this-host",
         bool(strips),
         "Logic reports every mixer child's role here, so this run exercises the guard's PASS side — "
         "the refusal side cannot be induced live without corrupting the tree being measured, and is "
         "covered by unit tests with an injected AX failure",
         f"strips={len(strips)} data_source={body.get('data_source')!r}", None)

# The guard sits in front of a write. Probe it with a parameter it rejects rather than actually
# inserting a plugin into the operator's project: what matters is that the call still reaches its
# validation instead of being refused by the new guard.
probe = d.tool("logic_mixer", "insert_plugin", {"nope": "1"})
hint = (probe.get("hint") or "") if isinstance(probe, dict) else ""
ev.note("290/insert-probe", probe if isinstance(probe, dict) else {"raw": str(probe)[:200]})

ev.check("290/the-guard-does-not-refuse-a-mixer-that-reads-fine",
         "unreadable_mixer_children" not in str(probe),
         "the new refusal does not fire on a healthy mixer — a guard's cheapest way to be wrong is "
         "to reject something that was never broken, and that is the half a unit test cannot show",
         f"hint={hint[:160]!r}",
         "invert the guard to refuse when the count is ZERO: this check goes red on every healthy "
         "mixer, which is the false-positive direction that matters")

ev.check("290/the-write-path-still-validates-its-input",
         isinstance(probe, dict)
         and ("Allowed parameters" in hint or "Unknown parameters" in hint
              or probe.get("error") == "invalid_params"),
         "insert_plugin still reaches its own parameter validation, so the guard was added in front "
         "of the path rather than in place of it",
         f"error={probe.get('error') if isinstance(probe, dict) else None!r} hint={hint[:140]!r}",
         None)

after = ev.shot("290/after", settle_region=band, window_title=arrange_title)
ev.visual("290/no-project-state-was-touched",
          before["file"], after["file"], band, subject=band_subject,
          expect_change=False,
          why="every call in this run is a read or a rejected parameter, so the window must be "
              "byte-identical across it — a change here would mean something wrote")

if toggles and not was_readable_at_start:
    toggle_mixer()
    # The resource is served from the poller's cache, so closing the pane does not change the answer
    # until a poll lands on the new state. Measuring immediately reads the world as it was and
    # reports a restore that did happen as one that did not.
    for _ in range(8):
        time.sleep(2)
        if not mixer_readable():
            break
final_readable = mixer_readable()
d.close()
ev.restored("290/the-mixer-pane-is-back-where-it-was",
            final_readable == was_readable_at_start,
            f"the mixer was {'readable' if was_readable_at_start else 'not readable'} to the product "
            f"when this run started and is {'readable' if final_readable else 'not readable'} now"
            f"{'; revealed with ' + repr(toggles) + ' and put back' if toggles else ''}.")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
