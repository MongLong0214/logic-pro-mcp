#!/usr/bin/env python3
"""Live proof that `insert_plugin` presses the configuration the STRIP offers, not the one asked for.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_855_the_insert_leaf_is_the_strips_configuration.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
Every configured menu path ends in the channel configuration, hardcoded as `Stereo` / `스테레오`:
`["Dynamics", "Compressor", "Stereo"]` and three siblings. On a MONO strip the Compressor submenu
offers exactly `["Mono"]`, so all four paths missed the leaf and `insert_plugin` refused to insert a
plug-in that was sitting right there -- reporting only "plugin menu selection failed".

That sentence is why #855 took a replication to diagnose rather than a reading: the same words came
out of a root menu that never opened, a category name that did not match, and a configuration the
strip does not have. They call for three different fixes.

The last segment is a property of the STRIP. It cannot be named in advance and is now read off the
menu the run actually opened.

WHAT THIS DOES NOT MEASURE, SAID FIRST
--------------------------------------
It does not exercise the refusal branch. Producing a live strip whose Compressor submenu offers
several configurations and NONE of them `Stereo` is not something this harness can arrange, so
`leafChoice`'s "several unrequested configurations refuse rather than picking one" clause is carried
by `PluginInsertLeafConfigurationTests` and not by this run. Said plainly because that clause is the
one protecting the operator from a silently chosen channel layout.

THE MEASUREMENT, AND THE COUNTEREXAMPLE IT HAS TO SURVIVE
--------------------------------------------------------
"The insert succeeded" is satisfied by the product as it was, on any stereo strip -- which is exactly
how this defect survived. So the run requires BOTH configurations in one sweep:

    a mono strip      State A, and `menu_leaf_chosen` is NOT the configuration the spec prefers
    a stereo strip    State A, and `menu_leaf_chosen` IS that configuration

The first is the fix. The second is the guard against a fix that simply stopped honouring the
preference -- taking the first item of every leaf menu would pass the mono clause and fail here.
Both readings come from `menu_leaf_chosen`, which the product emits only because the choice is now
a decision worth reporting; before this change there was nothing on the wire that distinguished the
two strips.

Which strips are mono and which are stereo is MEASURED, not assumed: the run inserts on each
candidate and reads back what was pressed. A sweep that does not contain both answers is recorded
as a failure rather than as a weaker pass, because it cannot tell a rule from a constant.

Every insert is undone, and the undo is verified by re-reading the strip rather than claimed.
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


COVERS = [
    "Sources/LogicProMCP/Channels/AccessibilityChannel+Plugins.swift",
]

# The configuration the Compressor spec prefers. Written out here rather than imported: an oracle
# that read the product's own spec would agree with any preference the product chose, including one
# that had quietly become "Mono".
PREFERRED = ("Stereo", "스테레오")

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")
recording = ev.record_screen(seconds=150)

d = E.Driver()
d.tool("logic_system", "refresh_cache")

# The band this run watches. Resolved from the live tree rather than written as four numbers, so the
# receipt can say what the rectangle IS and not only where it was. The Korean spelling first because
# the host is a ko-KR machine; an unresolved band is a red precondition, not a whole-window compare.
band, band_subject = ev.located_band("트랙 헤더")
if band is None:
    band, band_subject = ev.located_band("Tracks header")
ev.note("855/watched-band", {"region": band, "subject": band_subject})
before_shot = ev.shot("855/before-any-insert", settle_region=band)


def strip_plugins(track):
    mixer = d.resource("logic://mixer") or {}
    for strip in mixer.get("strips") or []:
        if strip.get("trackIndex") == track:
            return [(p.get("index"), p.get("name")) for p in (strip.get("plugins") or [])]
    return None


# The Edit menu's own spelling, MEASURED rather than translated. Logic's menu-bar titles are
# localized independently of the host locale — this machine is ko-KR and answers `Edit` — so the
# restore tries each spelling in turn and uses whichever one the running Logic actually has.
EDIT_MENU_NAMES = ("Edit", "편집", "編集")

UNDO_MENU = """
tell application "Logic Pro" to activate
delay 0.5
tell application "System Events" to tell process "Logic Pro"
  click menu item 1 of menu 1 of menu bar item "{name}" of menu bar 1
end tell
"""


def undo_and_verify(track, expect_empty_slot):
    """Undo through Logic's own Edit menu and CONFIRM by re-reading.

    NOT `logic_edit undo`. Measured 2026-09-12: that command routes to `[.midiKeyCommands]` and
    answers State B `readback_unavailable` with `method: midi_key_command, cc: 30, channel: 16` --
    a send-only CC that depends on a controller assignment this project does not have. Driving it
    twice left both inserted plug-ins in place. A restore step that cannot be shown to have
    restored is worse than none, because it reads as cleanup in the receipt.
    """
    for name in EDIT_MENU_NAMES:
        done = subprocess.run(
            ["/usr/bin/osascript", "-e", UNDO_MENU.format(name=name)],
            capture_output=True, text=True, timeout=60,
        )
        if done.returncode == 0:
            break
    time.sleep(1.5)
    d.tool("logic_system", "refresh_cache")
    after = strip_plugins(track)
    return after is not None and all(i != expect_empty_slot for i, _ in after)


# Candidates: every track whose slot 0 is free, so the insert has somewhere to land. Taken from the
# live mixer rather than hardcoded, because a project edited between runs moves every ordinal.
mixer = d.resource("logic://mixer") or {}
candidates = []
for strip in mixer.get("strips") or []:
    idx = strip.get("trackIndex")
    if not isinstance(idx, int):
        continue
    occupied = {p.get("index") for p in (strip.get("plugins") or [])}
    if 0 not in occupied:
        candidates.append(idx)
ev.note("855/candidate-strips-with-a-free-slot-0", {"tracks": candidates})

attempts = []
for track in candidates:
    if len(attempts) >= 6:
        break
    body = d.tool("logic_mixer", "insert_plugin", {
        "track": track, "slot": 0, "plugin_name": "Compressor", "confirmed": True,
    }) or {}
    chosen = body.get("menu_leaf_chosen")
    reading = {
        "track": track,
        "state": body.get("state"),
        "verified": body.get("verified"),
        "observed_plugin_name": body.get("observed_plugin_name"),
        "menu_leaf_chosen": chosen,
        "menu_failure": body.get("menu_failure"),
        "menu_leaf_offered": body.get("menu_leaf_offered"),
        "chose_the_preferred_configuration": chosen in PREFERRED,
    }
    if body.get("state") == "A":
        reading["restored"] = undo_and_verify(track, expect_empty_slot=0)
        ev.restored(
            f"855/insert-on-track-{track}-is-undone",
            reading["restored"],
            f"track={track} chosen={chosen!r}",
        )
    attempts.append(reading)
    ev.note(f"855/insert-on-track-{track}", body)
    # Stop as soon as the sweep holds both answers; every extra insert is another mutation of the
    # operator's project for no additional evidence.
    got = {a.get("menu_leaf_chosen") for a in attempts if a.get("state") == "A"}
    if any(c in PREFERRED for c in got) and any(c and c not in PREFERRED for c in got):
        break

after_shot = ev.shot("855/after-every-insert-was-undone", settle_region=band)
ev.visual(
    "855/the-arrangement-band-is-back-where-it-started",
    before_shot["file"],
    after_shot["file"],
    band,
    subject=band_subject,
    expect_change=False,
    why="every insert this run made was undone and the undo was confirmed by re-reading the strip; "
    "the band must therefore look as it did before the run, and a difference here means a mutation "
    "was left behind",
)

succeeded = [a for a in attempts if a["state"] == "A"]
reading = {
    "candidates_offered": len(candidates),
    "inserts_attempted": len(attempts),
    "inserts_that_reached_state_a": len(succeeded),
    "all_successes_read_the_plugin_back": all(
        a["observed_plugin_name"] == "Compressor" and a["verified"] is True for a in succeeded
    ),
    "all_successes_name_a_configuration": all(a["menu_leaf_chosen"] for a in succeeded),
    "successes_on_the_preferred_configuration": sum(
        1 for a in succeeded if a["chose_the_preferred_configuration"]
    ),
    "successes_on_another_configuration": sum(
        1 for a in succeeded if not a["chose_the_preferred_configuration"]
    ),
    "configurations_seen": sorted({a["menu_leaf_chosen"] for a in succeeded if a["menu_leaf_chosen"]}),
    "restorations_confirmed": sum(1 for a in succeeded if a.get("restored")),
    "observed": attempts,
}

ev.falsifiable(
    "855/the-insert-presses-the-configuration-the-strip-offers",
    lambda o: (o["inserts_that_reached_state_a"] >= 2
               and o["all_successes_read_the_plugin_back"]
               and o["all_successes_name_a_configuration"]
               and o["successes_on_the_preferred_configuration"] > 0
               and o["successes_on_another_configuration"] > 0
               and o["restorations_confirmed"] == o["inserts_that_reached_state_a"]),
    reading,
    {"candidates_offered": 12, "inserts_attempted": 2, "inserts_that_reached_state_a": 2,
     "all_successes_read_the_plugin_back": True,
     "all_successes_name_a_configuration": True,
     "successes_on_the_preferred_configuration": 2,
     "successes_on_another_configuration": 0,
     "configurations_seen": ["Stereo"],
     "restorations_confirmed": 2,
     "observed": []},
    "the sweep reaches State A on strips of BOTH channel configurations, each with the plug-in read "
    "back by name, and `menu_leaf_chosen` reports a different configuration on each -- the preferred "
    "one where the strip offers it and the strip's own where it does not. THE COUNTEREXAMPLE is the "
    "product as it was: every insert lands on a strip that happens to offer `Stereo`, "
    "`successes_on_another_configuration` stays at zero, and a run that only looked at 'did the "
    "insert succeed' would report a clean pass while the mono path was still refusing. The mirror "
    "counterexample -- a fix that stopped honouring the preference and took the first item of every "
    "leaf menu -- is caught by the other side of the same pair",
    mutation="`leafChoice` returns nil when the preferred configuration is absent, which is the "
             "behaviour this change replaced. Every mono strip then answers State C with "
             "`menu_failure: leaf_not_offered_by_this_strip`, `successes_on_another_configuration` "
             "falls to zero, and the sweep can no longer contain both answers. The opposite "
             "mutation -- `offered.first` regardless of preference -- drives "
             "`successes_on_the_preferred_configuration` to zero on any strip offering more than "
             "one, so neither direction passes",
)

d.close()
ev.stop_recording(recording)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
