#!/usr/bin/env python3
"""Live proof that the track header's selectors resolve by IDENTITY, not by position.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_290_header_selectors_resolve_by_identity.py <worktree> <full-40-char-head-sha>

WHAT THIS PROVES
----------------
`--probe-selection-census` is the product's own instrument for "how many candidates survive the
discriminator a site applies". It measured `findPanControlInHeader` at ZERO survivors of two
sliders, which by that probe's own rule means the site was selecting by index — it fell through to
"the slider that is not the volume fader" on every header. This run asks the same instrument the
same question at this head and records the answer.

It also drives the control the identity now names, and shows the write lands on the track it was
aimed at and no other. A selector that resolves confidently to the wrong element is worse than one
that refuses, so "it resolved" is not on its own the property worth having.

The mute, solo and record-arm locators are measured in the same pass. They were absent from that
probe until their callers were enumerated — the predicate closes over a `labels:` parameter, and a
survivor count taken with one label set says as much about the argument as about the tree. There
are exactly three callers and each passes a fixed `AXLocalePolicy` set, so these rows carry the
product's own arguments.

WHAT IT DOES NOT PROVE
----------------------
Only the Korean help string is measured. `AXHelp` is what carries the pan slider's name here, and
this host runs one locale — so nothing in this run says the same is true of an English or Japanese
Logic. On a locale whose help text carries none of the hint's variants the predicate yields
nothing and the site falls through to elimination exactly as it did before, which is why that
fallback was kept rather than deleted.

It does not exercise the ambiguity refusal either. Inducing two sliders that both name themselves
pan would mean editing the tree being measured; that half is covered by
`Issue290HeaderPanIdentityTests.ambiguityRefuses` and by the mutation showing the pre-fix predicate
returns the first in tree order instead of refusing.
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
SITE = "AXLogicProElements.findPanControlInHeader"


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_titles():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


titles = [t for t in window_titles() if not any(c in t for c in CHOOSER_TITLES)]
ev.check("290/precondition-a-project-is-open", bool(titles),
         "Logic has a project window, so track headers exist to resolve a pan slider in",
         f"windows={window_titles()!r}", None)
if not titles:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

arrange_title = titles[0]

# The rail's own AXDescription is localized — `트랙 헤더` on this host — so the English selector the
# other harnesses use finds nothing here. Both are tried, and which one answered is recorded, so a
# run cannot be filed under a layout it did not measure.
RAIL, RAIL_SUBJECT = ev.located_band("트랙 헤더")
rail_selector = "트랙 헤더"
if RAIL is None:
    RAIL, RAIL_SUBJECT = ev.located_band("Tracks header")
    rail_selector = "Tracks header"
ev.check("290/precondition-the-track-header-rail-is-located",
         RAIL is not None and bool(RAIL_SUBJECT),
         "the capture band is resolved from the live tree, so what the pixels below show is the rail "
         "that was actually found rather than a rectangle someone remembered",
         f"selector={rail_selector!r} band={RAIL!r} subject={RAIL_SUBJECT!r}", None)
if RAIL is None:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

# ---- the census, asked of the product at this head -------------------------------------------
census = subprocess.run([E.BIN, "--probe-selection-census"], capture_output=True, text=True)
try:
    sites = json.loads(census.stdout or "{}").get("sites", [])
except json.JSONDecodeError:
    sites = []
row = next((s for s in sites if isinstance(s, dict) and s.get("site", "").startswith(SITE)), None)
ev.note("290/selection-census", {"row": row, "sites": len(sites)})

def one_unambiguous_survivor(r):
    return isinstance(r, dict) and r.get("survivors") == 1 and r.get("identified") is True


# The counterexample is not invented: it is the row this census actually printed before the fix, on
# this machine, transcribed. `falsifiable` runs the same predicate against both, so a condition that
# would also accept the pre-fix state fails here rather than passing live and proving nothing.
PRE_FIX_ROW = {"site": SITE + " (header pan slider)",
               "gathered": 2, "survivors": 0, "identified": False}

ev.falsifiable(
    "290/the-pan-slider-names-itself",
    one_unambiguous_survivor,
    row,
    PRE_FIX_ROW,
    "exactly one slider on the header survives the pan discriminator, and the census calls the "
    "answer unambiguous — measured at ZERO survivors before this change, which by the probe's own "
    "rule is the site selecting by index",
    mutation="revert headerPanSliderCandidates to matching headerPanHint against the children's "
             "AXDescription: survivors returns to 0 and this check goes red")

# The three toggle locators, measured with the label sets the product itself passes. Their
# counterexample is the shape that made them worth measuring: a header where the discriminator
# accepts more than one checkbox, which is the wrong-target failure ADR-007 exists to stop. A
# predicate that only asks "did something survive" accepts it, and this rejects that predicate.
TOGGLE_SITES = ["AXLogicProElements.findTrackMuteButton",
                "AXLogicProElements.findTrackSoloButton",
                "AXLogicProElements.findTrackArmButton"]
for site in TOGGLE_SITES:
    trow = next((s for s in sites if isinstance(s, dict) and s.get("site", "").startswith(site)), None)
    ev.falsifiable(
        f"290/{site.rsplit('.', 1)[-1]}-resolves-to-exactly-one",
        one_unambiguous_survivor,
        trow,
        {"site": site, "gathered": 4, "survivors": 2, "identified": False},
        f"{site} leaves exactly one candidate on the header and the census calls it unambiguous",
        mutation="widen the toggle predicate to any checkbox carrying a description: several "
                 "survive and the census stops calling the answer unambiguous")

d = E.Driver()
time.sleep(3)


def pans():
    d.tool("logic_system", "refresh_cache", {})
    time.sleep(1.2)
    body = d.resource("logic://tracks") or {}
    rows = body.get("data") if isinstance(body.get("data"), list) else []
    return body, [r.get("pan") for r in rows]


body, before_pans = pans()
age = body.get("cache_age_sec")
ev.provenance("290/track-pans", f"state_poller_cache_{body.get('data_source')}",
              round(age, 2) if isinstance(age, (int, float)) else None,
              bool(body.get("readable")))
ev.check("290/precondition-the-poller-reads-this-project",
         bool(body.get("readable")) and len(before_pans) >= 2,
         "the track list is readable and has at least two tracks, so 'only the aimed track moved' is "
         "a claim this run can actually test rather than a vacuous one",
         f"readable={body.get('readable')!r} reason={body.get('reason')!r} pans={before_pans!r}",
         None)
if not body.get("readable") or len(before_pans) < 2:
    d.close(); print(json.dumps(ev.write(), indent=1)); sys.exit(1)

# The visual below asserts that track 0's pan knob moved IN THE PIXELS, which silently requires
# track 0's header to be on screen. It is not, on a project with enough tracks to fill the rail and
# the mixer open — measured: at six tracks the rail showed 오디오 3-5 and the write to track 0
# changed nothing inside the band, so a correct write produced a red visual for a reason that had
# nothing to do with the code.
#
# The precondition is established through the product rather than assumed: selecting the track
# scrolls its header into the rail. `tracks.select` addresses by index, not by position on screen,
# so this does not reintroduce a coordinate.
select = d.tool("logic_tracks", "select", {"index": 0})
ev.note("290/scroll-target-into-view", select if isinstance(select, dict) else {"raw": str(select)[:200]})
time.sleep(1.5)

rec = ev.record_screen(seconds=120)
before = ev.shot("290/before", settle_region=RAIL, window_title=arrange_title)

# Aim away from wherever it currently sits, so the assertion cannot pass by the knob already being
# where it was asked to go.
target = -0.7 if (before_pans[0] or 0) > -0.3 else 0.7
envelope = d.tool("logic_mixer", "set_pan", {"track": 0, "value": target})
time.sleep(1.5)
ev.note("290/set-pan", envelope if isinstance(envelope, dict) else {"raw": str(envelope)[:200]})

_, after_pans = pans()
moved = [i for i, (b, a) in enumerate(zip(before_pans, after_pans)) if b != a]

ev.check("290/the-write-lands-on-the-track-it-was-aimed-at",
         moved == [0],
         "track 0's pan changed and no other track's did — a selector that resolves confidently to "
         "the wrong element is worse than one that refuses, so resolving is not on its own the "
         "property worth having",
         f"target={target} before={before_pans!r} after={after_pans!r} moved={moved!r}",
         "resolve the header by tree order instead of identity: on a header whose first slider is "
         "not the pan control the write lands elsewhere and `moved` stops being [0]")

ev.check("290/the-envelope-names-the-control-it-drove",
         isinstance(envelope, dict)
         and (envelope.get("target_identity") or {}).get("control") == "pan"
         and (envelope.get("target_identity") or {}).get("track_index") == 0,
         "the receipt names the control and the track, so the claim above is checkable against what "
         "the product says it did rather than only against what moved",
         f"target_identity={envelope.get('target_identity') if isinstance(envelope, dict) else None!r} "
         f"state={envelope.get('state') if isinstance(envelope, dict) else None!r}",
         None)

after = ev.shot("290/after", settle_region=RAIL, window_title=arrange_title)
ev.visual("290/the-pan-knob-moved-in-the-pixels",
          before["file"], after["file"], RAIL, subject=RAIL_SUBJECT,
          expect_change=True,
          why="the rail is where the pan knob lives; if AX reported a new value while these pixels "
              "were identical, the write would have been recorded somewhere the user cannot see")

# ---- put it back --------------------------------------------------------------------------
restore = d.tool("logic_mixer", "set_pan", {"track": 0, "value": before_pans[0]})
time.sleep(1.5)
_, final_pans = pans()
ev.note("290/restore", {"envelope": restore if isinstance(restore, dict) else str(restore)[:200],
                        "final": final_pans})
d.close()

# One detent is ~10 raw units of 127, i.e. ~0.157 in contract units; the fader is not continuous,
# so "back where it was" is the nearest representable level and not the exact float.
back = (before_pans[0] is not None and final_pans and final_pans[0] is not None
        and abs(final_pans[0] - before_pans[0]) <= 0.16)
ev.restored("290/the-pan-is-back-where-it-started",
            back,
            f"track 0's pan was {before_pans[0]!r} at the start and is {final_pans[0] if final_pans else None!r} "
            "now, within one AX detent")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
