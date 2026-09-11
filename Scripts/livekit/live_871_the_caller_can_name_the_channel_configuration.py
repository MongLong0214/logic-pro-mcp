#!/usr/bin/env python3
"""Live proof that naming a channel configuration reaches a strip that refuses without one.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_871_the_caller_can_name_the_channel_configuration.py <worktree> <full-40-char-head-sha>

WHAT WAS UNREACHABLE
--------------------
#855 established that the last segment of Logic's plug-in menu is the channel configuration, and
that it belongs to the STRIP rather than to the request. The spec's preference wins when the strip
offers it; a menu with one entry has no choice in it; several entries with none preferred are
REFUSED, because picking one would choose a channel layout on the operator's behalf.

That refusal is correct and it left a strip unreachable. On a mono strip Gain offers
`["Mono", "Mono->Stereo"]`, neither of which is the spec's preferred `Stereo`, so the operation
refused and the caller had no way to say which they wanted.

WHAT THIS RUN MEASURES
----------------------
Three requests against that same strip, differing only in the new parameter:

    no configuration              refused, and the refusal lists what the strip offers
    a configuration NOT offered   refused — not quietly replaced with the preference
    a configuration that IS       State A, the named one pressed, plug-in read back by name

The middle request is the one that matters most and is the easiest to get wrong. Falling back when
the caller names something the strip lacks would hand them a layout they did not ask for, which is
the same harm the refusal exists to prevent, arrived at from the opposite direction.

WHAT IT DOES NOT MEASURE, SAID FIRST
------------------------------------
It does not prove the parameter is unnecessary elsewhere. On a strip that offers the preference, or
exactly one entry, the configuration is ignored and #855's live run already covers those paths. This
run is only about the case that had no answer before.

Nor does it drive `Mono->Stereo`. That value would change the channel's OUTPUT CONFIGURATION, which
is a real edit to the operator's project and a much larger act than inserting a plug-in; the run
names `Mono` — the layout the strip already has — so the only thing it changes is the insert it then
undoes.

THE COUNTEREXAMPLE
------------------
A product that accepts the parameter and ignores it: the third request still reaches State A, and
`menu_leaf_chosen` comes back as something the caller did not ask for — or the second request
reaches State A too, because an unoffered value quietly fell back. Both satisfy "the insert worked"
and fail what this change is for.

The insert is undone through Logic's own Edit menu and the undo is confirmed by re-reading the strip.
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
    "Sources/LogicProMCP/Dispatchers/MixerDispatcher.swift",
]

PLUGIN = "Gain"
# Written out rather than read from the response: an oracle that took its expectation from the
# product's own reply would agree with whatever the product chose to press.
WANTED = "Mono"
NOT_OFFERED = "Stereo"

# Logic's Edit menu, spelled as measured rather than translated — see live_855.
EDIT_MENU_NAMES = ("Edit", "편집", "編集")
UNDO_MENU = """
tell application "Logic Pro" to activate
delay 0.5
tell application "System Events" to tell process "Logic Pro"
  click menu item 1 of menu 1 of menu bar item "{name}" of menu bar 1
end tell
"""

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
recording = ev.record_screen(seconds=140)

d = E.Driver()
d.tool("logic_system", "refresh_cache")

band, band_subject = ev.located_band("트랙 헤더")
if band is None:
    band, band_subject = ev.located_band("Tracks header")
ev.note("871/watched-band", {"region": band, "subject": band_subject})
before_shot = ev.shot("871/before", settle_region=band)


def strip_plugins(track):
    mixer = d.resource("logic://mixer") or {}
    for strip in mixer.get("strips") or []:
        if strip.get("trackIndex") == track:
            return [p.get("name") for p in (strip.get("plugins") or [])]
    return None


def undo_and_verify(track):
    for name in EDIT_MENU_NAMES:
        done = subprocess.run(
            ["/usr/bin/osascript", "-e", UNDO_MENU.format(name=name)],
            capture_output=True, text=True, timeout=60,
        )
        if done.returncode == 0:
            break
    time.sleep(1.5)
    d.tool("logic_system", "refresh_cache")
    return strip_plugins(track) == []


# The target is a strip whose slot 0 is free AND which refuses without a configuration — found by
# asking, not by assuming which tracks are mono. A project where no strip refuses cannot exercise
# this change, and the run says so rather than passing on a strip that never needed the parameter.
candidates = []
mixer = d.resource("logic://mixer") or {}
for strip in mixer.get("strips") or []:
    index = strip.get("trackIndex")
    if not isinstance(index, int):
        continue
    if 0 not in {p.get("index") for p in (strip.get("plugins") or [])}:
        candidates.append(index)
ev.note("871/candidate-strips", {"tracks": candidates})

target = None
refused = {}
for index in candidates[:6]:
    body = d.tool("logic_mixer", "insert_plugin", {
        "track": index, "slot": 0, "plugin_name": PLUGIN, "confirmed": True,
    }) or {}
    ev.note(f"871/probe-track-{index}", body)
    offered = body.get("menu_leaf_offered") or []
    if body.get("state") == "C" and WANTED in offered and NOT_OFFERED not in offered:
        target, refused = index, body
        break
    if body.get("state") == "A":
        # This strip did not need the parameter; put it back before moving on.
        undo_and_verify(index)

reading = {"target_found": target is not None}
if target is not None:
    wrong = d.tool("logic_mixer", "insert_plugin", {
        "track": target, "slot": 0, "plugin_name": PLUGIN, "confirmed": True,
        "configuration": NOT_OFFERED,
    }) or {}
    ev.note("871/a-configuration-the-strip-does-not-offer", wrong)

    named = d.tool("logic_mixer", "insert_plugin", {
        "track": target, "slot": 0, "plugin_name": PLUGIN, "confirmed": True,
        "configuration": WANTED,
    }) or {}
    ev.note("871/the-configuration-the-strip-offers", named)

    restored = undo_and_verify(target) if named.get("state") == "A" else strip_plugins(target) == []
    ev.restored("871/the-insert-is-undone", restored, f"track={target} plugins={strip_plugins(target)!r}")

    reading.update({
        "target_track": target,
        "offered_without_a_configuration": refused.get("menu_leaf_offered"),
        "refused_without_a_configuration": refused.get("state") == "C",
        "refusal_names_the_parameter": "configuration" in (refused.get("hint") or ""),
        "unoffered_configuration_refused": wrong.get("state") == "C",
        "unoffered_configuration_pressed_nothing": not (wrong.get("menu_leaf_chosen") or ""),
        "named_configuration_state": named.get("state"),
        "named_configuration_chosen": named.get("menu_leaf_chosen"),
        "named_configuration_is_the_one_asked_for": named.get("menu_leaf_chosen") == WANTED,
        "plugin_read_back": named.get("observed_plugin_name"),
        "plugin_read_back_matches": named.get("observed_plugin_name") == PLUGIN,
        "verified": named.get("verified"),
        "restored": restored,
    })

ev.falsifiable(
    "871/a-named-configuration-reaches-a-strip-that-refuses-without-one",
    lambda o: (o["target_found"]
               and o["refused_without_a_configuration"]
               and o["refusal_names_the_parameter"]
               and o["unoffered_configuration_refused"]
               and o["unoffered_configuration_pressed_nothing"]
               and o["named_configuration_state"] == "A"
               and o["named_configuration_is_the_one_asked_for"]
               and o["plugin_read_back_matches"]
               and o["verified"] is True
               and o["restored"]),
    reading,
    {"target_found": True, "target_track": 1,
     "offered_without_a_configuration": ["Mono", "Mono->Stereo"],
     "refused_without_a_configuration": True,
     "refusal_names_the_parameter": True,
     "unoffered_configuration_refused": False,
     "unoffered_configuration_pressed_nothing": False,
     "named_configuration_state": "A",
     "named_configuration_chosen": "Mono",
     "named_configuration_is_the_one_asked_for": True,
     "plugin_read_back": "Gain", "plugin_read_back_matches": True,
     "verified": True, "restored": True},
    "on a strip that refuses without one, naming a configuration the strip offers reaches State A "
    "pressing THAT configuration, with the plug-in read back by name; naming one the strip does not "
    "offer is refused and presses nothing; and the refusal without any configuration names the "
    "parameter that would resolve it. THE COUNTEREXAMPLE is a product that accepts the parameter and "
    "ignores it: the unoffered value quietly falls back and reaches State A too, which satisfies "
    "'the insert worked' and defeats the whole point — so that clause, not the happy path, is what "
    "this run is really about",
    mutation="`leafChoice` falls back to the preference when the requested configuration is absent, "
             "instead of returning nil. `unoffered_configuration_refused` goes false on its own "
             "while every other clause stays green — which is why it is written as its own clause "
             "rather than folded into the success. The weaker mutation of ignoring the parameter "
             "entirely is caught twice over, by that clause and by "
             "`named_configuration_is_the_one_asked_for`",
)

after_shot = ev.shot("871/after-the-insert-was-undone", settle_region=band)
ev.visual(
    "871/the-arrangement-band-is-back-where-it-started",
    before_shot["file"],
    after_shot["file"],
    band,
    subject=band_subject,
    expect_change=False,
    why="every insert this run made was undone and confirmed by re-reading the strip, so the band "
    "must look as it did before; a difference means a mutation was left behind",
)

d.close()
ev.stop_recording(recording)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
