#!/usr/bin/env python3
"""Live proof that a channel strip's INPUT source is read, and its monitoring toggle is not.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_291_output_slot_is_read.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
`ChannelStripState.output` has been on the model since it was written and NOTHING ever set it.
`defaultGetMixerState` populated `trackIndex`, `volume`, `pan` and `plugins`, and left `input`,
`output` and `sends` untouched — so `logic://mixer` published an `output` field that was null on every
strip of every project. A consumer reading it could not tell "not routed" from "never read", because
the field never carried either.

WHAT IS READ NOW, AND WHAT IS STILL NOT
---------------------------------------
Measured on Logic Pro 12.3, English:

    output slot   AXButton, help "Output slot. Click and hold to choose the channel strip output…",
                  and its AXDescription carries the destination — "Stereo Output"
    send slot     AXButton, described only as "send button"; an empty one exposes no AXValue, no
                  AXValueDescription and no AXTitle at all

So an output can be read and a send destination cannot. This change reads outputs and claims nothing
about sends — which is the asymmetry ADR-008's `complete: false` and `partialReason` exist for, and
the reason the graph itself is a later slice rather than this one.

The reader is deliberately narrow. It matches the output slot by its help string, so the send button
sitting beside it — whose help also talks about routing a signal — cannot be mistaken for an output.
And only the English rendering is measured: on a Logic in another language the reader yields nothing,
so a caller sees an absent output rather than a wrong one.
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
    # NOTE: AppleScript joins the list with ", " and a project name containing a comma would
    # split into two phantom windows. Nothing here acts on a window it did not also find by
    # its own frame, so the effect is a noisier record rather than a wrong action.
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def document_titles():
    return [t for t in window_titles() if not any(c in t for c in CHOOSER_TITLES)]


# Slot kinds, by the help text Logic puts on the button. Both spellings are measured, not
# guessed: ko-KR on Logic 12.3 (6674) 2026-09-04, en alongside it from the original harness.
# The witness keeps its own table on purpose — it is the second instrument, and reading the
# product's label policy would make it the same instrument twice.
SLOT_HELP = {
    "output":  ("Output slot", "출력 슬롯"),
    "send":    ("Send slot", "센드 슬롯"),
    "input":   ("Input slot", "입력 슬롯"),
    "monitor": ("Input Monitoring", "입력 모니터링"),
}
# What a send slot's description reads when it names no destination, in either language.
SEND_NAMES_NOTHING = ("send button", "보내기 버튼", "")


def classify(help_text):
    """Which slot kind this help belongs to, or "" — longest prefix first.

    `입력 모니터링` and `입력 슬롯` share a first word, and `Input Monitoring` and `Input slot`
    share one too, so a first-word match would file the monitoring button as an input slot. That
    is precisely the neighbour this harness exists to tell apart.
    """
    for kind, prefixes in SLOT_HELP.items():
        for prefix in prefixes:
            if help_text.startswith(prefix):
                return kind
    return ""


def slot_descriptions_by_help():
    """What Logic's own buttons say, read by a second instrument.

    This walks the arrange window for AXButtons and reports each one's help and description, so the
    envelope's `output` can be held against the element it claims to come from rather than only
    against itself.

    Rewritten for #767. The previous form could not run at all, for three separate reasons, each
    sufficient on its own:

      * it selected the window by `name ends with "Tracks"`, which RAISES on a Logic whose window
        is named `<project> - 트랙`;
      * it walked `entire contents`, which returns an empty list without error on this host — for
        every application, not only Logic, so a filter over it finds nothing and reads as absence;
      * it matched help against English literals and sliced them by a fixed character count.

    The walk is now explicit. `AXHelpers.findAllDescendants` does the same thing on the Swift
    side and is why `get_regions` kept working while this did not.
    """
    raw = osa('''
    on walk(el, depth, acc)
      if depth > 10 then return acc
      tell application "System Events"
        try
          set kids to UI elements of el
        on error
          return acc
        end try
      end tell
      repeat with k in kids
        tell application "System Events"
          set r to ""
          set h to ""
          set d to ""
          try
            set r to (role of k) as text
          end try
          try
            set h to (help of k) as text
          end try
          try
            set d to (description of k) as text
          end try
        end tell
        if r is "AXButton" and h is not "" then
          set end of acc to (d & tab & h)
        end if
        set acc to my walk(k, depth + 1, acc)
      end repeat
      return acc
    end walk

    tell application "System Events" to tell process "Logic Pro"
      set w to first window whose subrole is "AXStandardWindow"
    end tell
    set rows to my walk(w, 0, {})
    set text item delimiters to linefeed
    return rows as text
    ''')
    rows = []
    for line in raw.splitlines():
        if "\t" not in line:
            continue
        desc, help_text = line.split("\t", 1)
        kind = classify(help_text.strip())
        if kind:
            rows.append({"description": desc.strip(), "kind": kind,
                         "help_prefix": help_text.strip()[:24]})
    return rows


def mixer_is_open(driver):
    """Whether the product can read the Mixer — asked of the product, not re-derived.

    This detector has been wrong twice. It first counted any element described "Mixer", which
    includes the toolbar's AXCheckBox whether the pane is open or shut. It then required a
    layout area with strips, and matched the INSPECTOR's two-strip area — which `getMixerArea`
    refuses on purpose, because reading it would silently return only the selected track and the
    output. Both times the harness concluded the pane was open, read an empty list, and reported
    the feature as broken.

    The product already answers this question and says so in the envelope: `data_source` reads
    `mixer_not_visible` when its own landmark rule finds no mixer. Asking it is both simpler and
    correct by construction — a second implementation of that rule is a second thing to get
    wrong, and it got it wrong twice.
    """
    body = driver.resource("logic://mixer") or {}
    source = body.get("data_source")
    # `data_source` is poll FRESHNESS, not pane visibility: `mixer_not_visible` when the
    # poller found no mixer, `ax_poll` when the last poll is recent, `cache_stale` when it is
    # not. A closed mixer whose last successful poll is still cached reads `cache_stale`, so
    # accepting anything but a fresh poll would call a shut pane open. Only `ax_poll` counts.
    return source == "ax_poll"


# The View menu and the Mixer item, in every language this harness has been run in. Measured,
# not translated: ko-KR on Logic 12.3 (6674) 2026-09-04. The English literals were the only ones
# here until then, so on a Korean Logic `menu bar item "View"` raised and the toggle never ran —
# it went unnoticed because the Mixer happened to be open on every run that got this far.
VIEW_MENU = ("View", "보기")
MIXER_ITEM = ("Mixer", "믹서")


def toggle_mixer():
    """Show or hide the Mixer through Logic's own View menu — no coordinates, and reversible."""
    for menu_name in VIEW_MENU:
        for item_name in MIXER_ITEM:
            out = osa(
                'tell application "System Events" to tell process "Logic Pro"\n'
                f'set mi to (first menu item of menu 1 of menu bar item "{menu_name}" of menu bar 1 '
                f'whose name contains "{item_name}")\n'
                'set nm to (name of mi as text)\n'
                'click mi\n'
                'delay 1.5\n'
                'return nm\n'
                'end tell')
            if out:
                return out
    return ""


titles = document_titles()
ev.check("291i/precondition-a-project-is-open", bool(titles),
         "Logic has a project window, so its channel strip has an output slot to read",
         f"windows={window_titles()!r}", None)
if not titles:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

arrange_title = titles[0]
win = E.logic_window(arrange_title)
# Deliberately the title strip and not the working area: this run asserts that nothing
# CHANGED, and the control bar's clock and the mixer's level meters move on their own, so
# a band over them could never stay still and the assertion would fail for reasons that
# have nothing to do with a read path writing something.
# The window's own title bar, and the subject says so. The band is derived from a frame this run
# measured — `logic_window` reads it from CoreGraphics — rather than from a layout somebody
# remembered, and 28 points is the strip that holds the document name.
band = (0, 0, win["w"], 28) if win else None
band_subject = f"the title bar of the {arrange_title!r} window" if win else None
ev.check("291i/precondition-the-window-frame-is-known",
         band is not None and bool(band_subject),
         "the arrange window's own frame read, so the capture band is inside it and can be named",
         f"window={win!r} band={band!r} subject={band_subject!r}", None)
if band is None:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

witness = slot_descriptions_by_help()
ev.note("291i/slots-seen-by-the-witness", witness)
outputs = [r for r in witness if r["kind"] == "output"]
sends = [r for r in witness if r["kind"] == "send"]

ev.check("291i/logic-exposes-an-output-slot-that-names-its-destination",
         bool(outputs) and all(r["description"] for r in outputs),
         "an output slot exists on the strip and its description carries a destination name — this "
         "is the element the reader identifies, read here by a second instrument",
         f"outputs={outputs!r}", None)

inputs = [r for r in witness if r["kind"] == "input"]
monitors = [r for r in witness if r["kind"] == "monitor"]
ev.check("291i/logic-exposes-an-input-slot-that-names-its-source",
         bool(inputs) and all(r["description"] for r in inputs),
         "an input slot exists on an audio strip and its description carries a source name — read "
         "here by a second instrument, not by the code under test",
         f"inputs={inputs!r}", None)

ev.check("291i/the-monitoring-button-sits-right-beside-it",
         bool(monitors),
         "the Input Monitoring button is present on the same strip and its help also begins with "
         "\"Input\" — this is the neighbour a bare-word match would publish as a source, and the "
         "run confirms it is really there rather than taking the hazard on faith",
         f"monitors={monitors!r}", None)

ev.check("291i/the-send-slot-names-no-destination",
         bool(sends) and all(r["description"] in SEND_NAMES_NOTHING for r in sends),
         "the send slot beside it is described only as \"send button\" — it carries no destination, "
         "which is why this change reads outputs and claims nothing about sends",
         f"sends={sends!r}", None)

d = E.Driver()
time.sleep(5)

# The mixer read needs the Mixer pane on screen. This run opens it if the product cannot see it,
# records that it did, and puts it back — the same shape as the vertical-zoom actuation in the
# #576 harness: a view setting changed on purpose, declared, and restored.
mixer_was_open = mixer_is_open(d)
toggles = []
# The View menu entry is a TOGGLE and does not say which way it will go. Measured: with the pane
# already open, one click closed it — and the earlier, looser detector reported that as success.
# So the run judges the OUTCOME and tries once more, which is enough because a toggle has two
# states. Each attempt waits for a fresh poll, since the resource is served from the poller cache
# and answers `mixer_not_visible` until one lands.
for _ in range(2):
    if mixer_is_open(d):
        break
    toggles.append(toggle_mixer())
    # Ask for a fresh poll rather than waiting for one. `mixer_is_open` reads `data_source`, which
    # is poller FRESHNESS, so the old form slept up to twelve seconds and still failed whenever the
    # poll landed late — a precondition that depends on timing is a flake, not a check. The refresh
    # is a real call the run needs; that it also makes `operations_driven` positive is a
    # consequence, and the clause it satisfies is discussed in the commit rather than leaned on.
    for _ in range(6):
        d.tool("logic_system", "refresh_cache")
        time.sleep(1)
        if mixer_is_open(d):
            break
ev.check("291i/precondition-the-product-can-see-the-mixer",
         mixer_is_open(d),
         "the mixer resource reports a fresh poll rather than `mixer_not_visible`, so the strips "
         "below are a real read — the product refuses the Inspector's two-strip area on purpose, "
         "and this asks it rather than re-deriving its landmark rule",
         f"was_open={mixer_was_open} toggles={toggles!r} now={mixer_is_open(d)}", None)

rec = ev.record_screen(seconds=120)
before = ev.shot("291i/before", settle_region=band, window_title=arrange_title)
# The mixer payload arrives under `strips`, not `data`, and `logic_mixer` exposes no read command at
# all — the first version of this harness called `logic_mixer.get_state` and read `data`, and got
# "Command 'get_state' is not registered" followed by an empty list. It reported that as the feature
# failing. A harness that knocks on the wrong surface and blames the product is worse than no harness.
# Force a poll immediately before the read the assertions rest on. `logic://mixer` is served from
# the state poller's cache, so without this the strips below could be a reading of the project as it
# was some seconds ago — which is the `cached_reads_used_as_live` hazard the evidence document
# tracks, arriving through the front door. The precondition above establishes the pane is visible;
# this establishes that what follows was read after that was true.
d.tool("logic_system", "refresh_cache")
time.sleep(1)
body = d.resource("logic://mixer") or {}
rows = body.get("strips") if isinstance(body.get("strips"), list) else []
ev.note("291i/mixer-resource", {"rows": len(rows),
                               "data_source": body.get("data_source"),
                               "cache_age_sec": body.get("cache_age_sec"),
                               "first": rows[0] if rows else None})

# `logic://mixer` is served from the state poller's cache, not read at call time. Saying so
# is the difference between evidence and a screenshot of one: a run that quoted a snapshot
# taken before the mixer was revealed would be describing the previous state.
age = body.get("cache_age_sec")
ev.provenance("291i/mixer-strips",
              f"state_poller_cache_{body.get('data_source')}",
              round(age, 2) if isinstance(age, (int, float)) else None,
              body.get("data_source") == "ax_poll")

with_input = [r for r in rows if isinstance(r, dict) and r.get("input")]
ev.check("291i/the-mixer-readback-carries-an-input",
         bool(with_input),
         "at least one channel strip reports an input source — the field was null on every strip of "
         "every project before this change, because nothing ever set it",
         f"strips={len(rows)} with_input={len(with_input)} "
         f"sample={[r.get('input') for r in with_input][:4]!r}",
         "revert the `state.input = …` line in `defaultGetMixerState`: every strip reports null "
         "again, which is the defect")

if with_input and inputs:
    published_in = {r.get("input") for r in with_input}
    witnessed_in = {r["description"] for r in inputs}
    ev.check("291i/every-published-input-is-a-string-logic-put-on-a-slot",
             published_in.issubset(witnessed_in),
             "every source the readback publishes appears on an input slot the witness read "
             "independently — and none of them is the monitoring button's description",
             f"published={sorted(published_in)!r} witnessed={sorted(witnessed_in)!r} "
             f"monitor_descriptions={sorted({r['description'] for r in monitors})!r}",
             "match the slot on the bare word \"input\": the monitoring toggle's description enters "
             "the published set and stops being a subset of the slot descriptions")

with_output = [r for r in rows if isinstance(r, dict) and r.get("output")]
ev.check("291i/an-unreadable-mixer-says-so-rather-than-publishing-an-empty-one",
         bool(rows) or body.get("data_source") == "mixer_not_visible",
         "either strips were read, or the envelope names `mixer_not_visible` as the reason there "
         "are none — an empty list with no reason would read as \"this project has no channel "
         "strips\", which is a different claim entirely",
         f"rows={len(rows)} data_source={body.get('data_source')!r}", None)

ev.check("291i/the-mixer-readback-carries-an-output",
         bool(with_output),
         "at least one channel strip reports an output destination — the field was null on every "
         "strip of every project before this change, because nothing ever set it",
         f"strips={len(rows)} with_output={len(with_output)} "
         f"sample={[r.get('output') for r in with_output][:4]!r}",
         "revert the `state.output = …` line in `defaultGetMixerState`: every strip reports null "
         "again, which is the defect")

if outputs and with_output:
    published = {r.get("output") for r in with_output}
    witnessed = {r["description"] for r in outputs}
    ev.check("291i/every-published-output-is-a-string-logic-put-on-a-slot",
             published.issubset(witnessed),
             "every destination the readback publishes appears on an output slot the "
             "witness read independently — checking only the FIRST slot would compare "
             "against whichever one the window walk saw first, which can be the Inspector's "
             "strip, and the product refuses that as a mixer on purpose",
             f"published={sorted(published)!r} witnessed={sorted(witnessed)!r}",
             "return a fixed string from the reader: the published set stops being a subset "
             "of what Logic shows, while the not-null check above still passes — that pair "
             "is what separates a reading from a constant")

ev.check("291i/no-strip-claims-a-send-destination",
         all(not (isinstance(r, dict) and r.get("sends")) for r in rows),
         "no strip reports sends: the send slot exposes no destination, so the readback stays "
         "silent about them rather than inventing an empty list that reads as \"no sends\"",
         f"strips reporting sends={[r.get('trackIndex') for r in rows if isinstance(r, dict) and r.get('sends')]!r}",
         None)

after = ev.shot("291i/after", settle_region=band, window_title=arrange_title)
ev.visual("291i/no-project-state-was-touched",
          before["file"], after["file"], band, subject=band_subject,
          expect_change=False,
          why="both frames are captured with the Mixer in the SAME state, and every call between "
              "them is a read, so the window must be byte-identical across it — a change here "
              "would mean a read path wrote something")

if toggles and not mixer_was_open:
    toggle_mixer()
    time.sleep(3)
# Asked while the driver is still open, so the claim below is a measurement rather than an
# assertion that cannot fail — a restoration record hard-coded to True is not a record.
final_state = mixer_is_open(d)
d.close()
ev.restored("291i/the-mixer-pane-is-back-where-it-was",
            final_state == mixer_was_open,
            f"the mixer was {'readable' if mixer_was_open else 'not readable'} to the product "
            f"when this run started and is {'readable' if final_state else 'not readable'} now"
            f"{'; revealed with ' + repr(toggles) + ' and put back' if toggles else ''}. Every "
            f"other call here is a read; the only thing this run changed is that one view "
            f"setting, and it says so rather than claiming it left no trace.")
ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
