#!/usr/bin/env python3
"""Live proof that the mixer strip's positional fallback is observable, and that it did not fire.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_628_mixer_fallback_is_visible.py <worktree> <full-40-char-head-sha>

WHAT #628 IS ABOUT HERE
-----------------------
`findVolumeFader` ends `return sliders.first` and `findPanControl` ends `return sliders[1]`. Those
indices are identity taken from tree order. When the description matches they are never reached, and
nothing distinguished "the description matched" from "position 1 happened to be pan" -- the two look
identical from outside, and only one of them is a fact about the strip.

WHY THIS HARNESS HAD TO CHANGE THE LIBRARY FIRST
------------------------------------------------
The branch says the fallback now announces itself with `Log.info`. `Log.info` writes to stderr
(`Logger.swift:60`) and the driver launched the server with `stderr=subprocess.DEVNULL`, so that
announcement went to a discarded stream. **A log nothing can read is not observability**, and a
harness asserting on it would have been asserting on a channel that carries nothing -- passing for
the same reason a broken one would. The driver now captures stderr to a file, which is what makes
the assertion below mean anything.

WHY THE ABSENCE ASSERTION IS NOT VACUOUS
----------------------------------------
This run asserts the fallback line is ABSENT, and an empty log satisfies that trivially. So absence
is only claimed alongside a control: the server's startup banner must be in the same captured stream.
A dead channel fails the control and the run fails with it, rather than passing quietly.

The mutation named on the absence check was RUN, not reasoned about: `isVolumeFader` forced to
`false` makes the description match nothing, the fallback becomes the only path, and the line
appears. That is the check being watched to fail.

WHAT THIS CANNOT RULE OUT
-------------------------
That some other Logic layout reaches the fallback. It says this one does not, on a strip whose
sliders carry descriptions, which is the configuration the product is actually used in.
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

FADER_FALLBACK = "findVolumeFader: no slider described as a volume fader"
PAN_FALLBACK = "findPanControl: no slider described as a pan control"

# Named where it is used rather than left as a bare string in the check: this is the mutation that
# was applied to the product, rebuilt, and watched to make the absent line appear.
MUTATION = ("AXLogicProElements+PluginSlots.swift `sliderText`: BOTH `isVolume` and `isPan` "
            "forced false, so no description matches and the positional fallback becomes the only "
            "path for either locator")


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_titles():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def document_titles():
    return [t for t in window_titles() if not any(c in t for c in CHOOSER_TITLES)]


def mixer_is_open(driver):
    """Asked of the product, not re-derived -- see the #291 harness for why re-deriving got it
    wrong twice. Only a FRESH poll counts: a shut pane with a warm cache reads `cache_stale`."""
    body = driver.resource("logic://mixer") or {}
    return body.get("data_source") == "ax_poll"


def toggle_mixer():
    """Logic's own View menu. No coordinates, and reversible."""
    return osa(
        'tell application "System Events" to tell process "Logic Pro"\n'
        'set mi to (first menu item of menu 1 of menu bar item "View" of menu bar 1 '
        'whose name contains "Mixer")\n'
        'set nm to (name of mi as text)\n'
        'click mi\n'
        'delay 1.5\n'
        'return nm\n'
        'end tell')


titles = document_titles()
ev.check("628/precondition-a-project-is-open", bool(titles),
         "Logic has a project window, so there is a channel strip whose sliders can be located",
         f"windows={window_titles()!r}", None)
if not titles:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

arrange_title = titles[0]
rec = ev.record_screen(seconds=150)

d = E.Driver()
time.sleep(5)

mixer_was_open = mixer_is_open(d)
toggles = []
for _ in range(2):
    if mixer_is_open(d):
        break
    toggles.append(toggle_mixer())
    for _ in range(6):
        time.sleep(2)
        if mixer_is_open(d):
            break

ev.check("628/precondition-the-product-can-see-the-mixer",
         mixer_is_open(d),
         "the mixer resource reports a fresh poll rather than `mixer_not_visible`, so the locator "
         "below ran against real strips",
         f"was_open={mixer_was_open} toggles={toggles!r} now={mixer_is_open(d)}", None)

body = d.resource("logic://mixer") or {}
rows = body.get("strips") if isinstance(body.get("strips"), list) else []
ev.note("628/mixer-resource", {"rows": len(rows),
                               "data_source": body.get("data_source"),
                               "first": rows[0] if rows else None})

# A row alone is too weak. `findVolumeFader` returning nil yields `volume: 0.0` via `?? 0.0`, and
# a strip with NO sliders logs nothing at all (`AXLogicProElements+Mixer.swift:323`) -- so "rows > 0"
# is satisfied by exactly the state that would make the absence assertions vacuous. A non-default
# volume means the locator returned an element AND the extractor read it.
located = [r for r in rows if isinstance(r.get("volume"), (int, float)) and r["volume"] > 0.0]
ev.check("628/the-locator-found-a-described-slider", len(located) > 0,
         "at least one strip reports a non-default volume, so `findVolumeFader` returned a real "
         "slider rather than nil -- a strip with no sliders logs nothing and would satisfy the "
         "absence checks below without the locator ever having had anything to choose between",
         f"rows={len(rows)} with_located_fader={len(located)} "
         f"volumes={[r.get('volume') for r in rows][:5]}", None)

# THE CONTROL. Absence of a line in an empty file is not evidence of anything, so the run proves the
# stream carries before it reads anything into the silence.
fader_present, channel_live = d.server_logged(FADER_FALLBACK)
pan_present, _ = d.server_logged(PAN_FALLBACK)
log_text = d.server_log()

ev.check("628/control-the-server-log-channel-carries", channel_live,
         "the captured stderr holds the server's own startup lines, so this run can tell "
         "\"the fallback did not fire\" from \"nothing could ever have been read\"",
         f"captured_bytes={len(log_text)} first_line={log_text.splitlines()[0][:110] if log_text.strip() else None!r}",
         "capturing stderr to DEVNULL again, as the driver did before this change, empties the "
         "stream and fails this control")

ev.check("628/the-volume-fader-fallback-did-not-fire", channel_live and not fader_present,
         "no `findVolumeFader ... falling back to position 0` line, on a channel proven to carry -- "
         "the description matched, so the index was never identity",
         f"fader_fallback_present={fader_present} channel_live={channel_live}", MUTATION)

ev.check("628/the-pan-fallback-did-not-fire", channel_live and not pan_present,
         "no `findPanControl ... falling back to position 1` line, on the same proven channel",
         f"pan_fallback_present={pan_present} channel_live={channel_live}", MUTATION)

# ---------------------------------------------------------------------------
# The WRITE path calls the same two locators (`AccessibilityChannel+Mixer.swift:56`), so the run
# drives one rather than claiming the read path speaks for both.
# ---------------------------------------------------------------------------
band, subject = ev.located_band("Tracks contents")
ev.check("628/precondition-the-band-resolved-to-a-named-region",
         band is not None and subject is not None,
         "the capture region came back off a live element with the name it was found under, so the "
         "assertion below has a subject rather than four numbers",
         f"band={band!r} subject={subject!r}", None)

# The write names its target by REFERENCE, not by ordinal: `track` and `index` are both index keys
# on this operation (`MixerDispatcher.swift:57`), and steering by ordinal would make the run depend
# on the very tree order this issue is about.
tracks_body = d.resource("logic://tracks") or {}
# `logic://tracks` keys its rows under `data`; the mixer resource uses `strips`. Reading the wrong
# key returns [] and reads as "no tracks", which is how this precondition first failed.
track_rows = tracks_body.get("data") if isinstance(tracks_body.get("data"), list) else []
target_ref = (track_rows[0] or {}).get("track_ref") if track_rows else None
original_volume = (rows[0] or {}).get("volume") if rows else None

ev.check("628/precondition-a-track-is-addressable-by-reference",
         bool(target_ref) and original_volume is not None,
         "the write below steers by `target_ref` rather than an ordinal, and the starting volume is "
         "known so it can be put back",
         f"target_ref={target_ref!r} volume={original_volume!r}", None)

wrote = None
restored_write = None
# Defined before the branch: the post-write check below reads it unconditionally, and a skipped
# write would otherwise raise NameError inside the harness rather than fail a check.
log_mark = len(d.server_log())
if band is not None and target_ref and original_volume is not None:
    before = ev.shot("628/before-the-write", settle_region=band, window_title=arrange_title)
    # Far enough from the current value that a detented fader must visibly move: the fader snaps in
    # raw steps of 10, about 0.053 normalized, so a smaller delta could round to a no-op.
    target_volume = 0.25 if original_volume > 0.5 else 0.85
    log_mark = len(d.server_log())
    wrote = d.tool("logic_mixer", "set_volume", {"target_ref": target_ref, "value": target_volume})
    time.sleep(2)
    after = ev.shot("628/after-the-write", settle_region=band, window_title=arrange_title)

    # The write must have LANDED. Without this the visual assertion below is vacuous -- a refused
    # write disturbs nothing, and "the arrangement did not move" would pass because nothing
    # happened at all. Measured: the first version of this harness passed exactly that way.
    # Compared against the operation's OWN `observed_before`, not against the cached mixer value:
    # `logic://mixer` is served from the poller and can be seconds stale, so a no-op write can look
    # like a move purely because the cache had not caught up. The response carries both endpoints.
    ob = (wrote or {}).get("observed_before")
    oa = (wrote or {}).get("observed_after")
    moved = (isinstance(wrote, dict) and not wrote.get("error")
             and ob is not None and oa is not None
             and abs(float(oa) - float(ob)) > 0.05)
    ev.check("628/the-write-actually-moved-the-fader", moved,
             "the operation's own before/after readback shows the fader at a new value -- a refused "
             "or zero-step write would make the visual assertion below true for no reason",
             f"observed_before={ob!r} observed_after={oa!r} "
             f"nudge_steps={(wrote or {}).get('nudge_steps')!r} error={(wrote or {}).get('error')!r}",
             None)

    ev.visual("628/a-mixer-write-does-not-disturb-the-arrangement",
              before["file"], after["file"], band, False,
              "a channel-strip volume write changes the mixer, not the regions -- if this band "
              "moved, the write reached something it does not name",
              subject=subject)

    restored_write = d.tool("logic_mixer", "set_volume",
                            {"target_ref": target_ref, "value": original_volume})
    # The fader is detented, so it lands on the nearest step rather than the exact float it started
    # at. Requiring equality here would report a correct restore as a failure.
    back = (isinstance(restored_write, dict) and restored_write.get("observed_after") is not None
            and abs(float(restored_write["observed_after"]) - float(original_volume)) <= 0.06)
    ev.restored("628/volume-put-back", back,
                f"asked for {original_volume!r}, fader settled at "
                f"{(restored_write or {}).get('observed_after')!r} (detent step ~0.053)")

ev.note("628/the-write", {"target_ref": target_ref, "wrote": wrote, "restored": restored_write})

# `mixer.set_volume` reaches `findTrackHeaderVolumeFader` -> `findVolumeFader`
# (`AXLogicProElements+Mixer.swift:49`). It does NOT reach `findPanControl`: header pan goes through
# `findPanControlInHeader`, a different function this branch does not change. An earlier version of
# this check claimed both, which was simply false.
#
# Scoped to the bytes written AFTER the write began. Searching the whole log would let the earlier
# read's silence stand in for the write's, and the check would read as scoped while proving nothing
# about the operation it names.
fader_after, channel_still_live = d.server_logged(FADER_FALLBACK, since=log_mark)
ev.check("628/the-volume-fallback-stayed-silent-through-the-write",
         channel_still_live and not fader_after,
         "driving `mixer.set_volume` calls `findVolumeFader` again and it announced no fallback in "
         "the log written since the write started, on a channel still proven to carry INFO",
         f"fader_since_write={fader_after} channel_live={channel_still_live} "
         f"bytes_since_write={len(d.server_log()) - log_mark}", MUTATION)

log_text = d.server_log()
ev.note("628/server-log-tail", {"bytes": len(log_text), "tail": log_text[-1500:]})

# The mutation named on the three checks above was APPLIED, BUILT, AND RUN on 2026-08-21 rather
# than reasoned about. `evidence.py` is explicit that a `mutation` string is normally the author's
# claim and the reviewer's job to judge; this records the measurement so it is neither.
ev.note("628/the-mutation-was-run", {
    "mutation": MUTATION,
    "applied_to": "AXLogicProElements+PluginSlots.swift sliderText -- isVolume AND isPan forced false",
    "clean_run": "11 checks, 11 passed",
    "mutated_run": "11 checks, 7 passed",
    "checks_that_flipped": [
        "628/the-volume-fader-fallback-did-not-fire",
        "628/the-pan-fallback-did-not-fire",
        "628/the-volume-fallback-stayed-silent-through-the-write",
        "628/no-fallback-fired-anywhere-in-the-run",
    ],
    "scoped_window_is_load_bearing": "under mutation the write-scoped check reported "
                                     "bytes_since_write=1666 with the fallback INSIDE that window, "
                                     "so the offset catches a line the write itself emitted rather "
                                     "than inheriting the earlier read's",
    "observed_under_mutation": "fader_fallback_present=True pan_fallback_present=True "
                              "channel_live=True -- the lines this run asserts are absent appeared",
    "note": "only the four checks the mutation is named on flipped; the other seven held",
})

# `stop_recording` waits out the remaining recording seconds while the server's AX poller keeps
# cycling (`StatePoller.swift:152`). Reading the log BEFORE that wait leaves those cycles outside
# every assertion -- a fallback fired during the tail would never be seen and the run would still
# be green. So the recorder is stopped first and the last word on absence is taken after it.
ev.stop_recording(rec)

tail_fader, tail_channel_live = d.server_logged(FADER_FALLBACK)
tail_pan, _ = d.server_logged(PAN_FALLBACK)
ev.check("628/no-fallback-fired-anywhere-in-the-run",
         tail_channel_live and not tail_fader and not tail_pan,
         "read after the recording was stopped, so the poller cycles that ran during the tail are "
         "inside this window rather than after every assertion -- the whole run, not a prefix of it",
         f"fader={tail_fader} pan={tail_pan} channel_live={tail_channel_live} "
         f"total_bytes={len(d.server_log())}", MUTATION)

log_text = d.server_log()
ev.note("628/server-log-tail", {"bytes": len(log_text), "tail": log_text[-1500:]})

d.close()

# Put the Mixer back the way it was found.
if not mixer_was_open:
    restored = toggle_mixer()
    ev.note("628/mixer-restored", {"toggled": restored, "was_open": mixer_was_open})

print(json.dumps(ev.write(), indent=1))
