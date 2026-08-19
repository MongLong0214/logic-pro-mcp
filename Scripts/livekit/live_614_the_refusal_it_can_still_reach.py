"""Live proof that a save_as refusal is legible and leaves nothing blocking behind it.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_614_the_refusal_it_can_still_reach.py <worktree> <full-40-char-head-sha>

WHAT THIS RUN IS ABOUT
----------------------
`project.save_as` WORKS now (#606). That broke this file: it used to drive save_as at a writable path
and read the refusal, and there is no longer a refusal to read — run that way it failed 2 of 9 with
`hint=''` and a project sitting at the path it asserts was never written. A harness that cannot reach
its subject is not evidence, and one that fails for that reason trains everyone to ignore a red.

The refusal path did not go away; only this harness's route to it did. So the run is repointed at a
refusal it can still cause: a path under a **directory that does not exist**. `isValidProjectPath`
lets it through, the menu opens the panel, and the panel's Go-to-Folder sheet will not close on a path
that does not resolve.

That target is strictly better than the one it replaces. The old refusal happened BEFORE any panel
opened, so "no panel is left behind" was green because nothing had ever been there — the #606 harness
says as much in its own comments. This one opens a panel and clears it, so
`panels_before_dismissal: 1 -> panels_after_dismissal: 0` is the dismissal code running, observed,
with a mutation that flips it.

Measured 2026-08-19 against the shipped binary:

    error                     ax_write_failed
    hint                      The Save panel's "Go to Folder" sheet stayed open after
                              …/lpm-614-no-such-dir was entered, so the panel's directory is unknown
                              and the filename field cannot be told apart from the sheet's own field.
                              Escape cleared the 1 panel-shaped window(s) that were open.
    write_attempted           false
    panels_before_dismissal   1
    panels_after_dismissal    0
    escape_delivered          true
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
# A path under a directory that does NOT exist. `isValidProjectPath(requireExisting: false)` lets it
# through, the menu opens the panel, and the panel's Go-to-Folder sheet refuses to close on a path
# that does not resolve — which is a refusal this harness can actually reach.
#
# It has to be reachable, because the refusal this file used to watch is not. #606 made `save_as`
# WORK, so driving it at a writable path now succeeds and there is no refusal to read: run against
# that target, this harness failed 2 of 9 with `hint=''` and a project sitting at the path it asserts
# was never written.
MISSING_DIR = "/Users/isaac/Music/Logic/lpm-614-no-such-dir"
TARGET = f"{MISSING_DIR}/refusal-proof.logicx"


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_titles():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def document_titles():
    return [t for t in window_titles() if not any(c in t for c in CHOOSER_TITLES)]


def _control_bar_band():
    """(band, subject) for the control bar in window coordinates, or (None, None).

    Located by AXDescription through a raw-AX witness rather than System Events: twice this week a
    rule prototyped through System Events failed to hold through the API the product uses.
    """
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_control_bar_band.swift")
    out = os.path.join(os.path.dirname(src), ".ax_control_bar_band.bin")
    if subprocess.run(["swiftc", "-O", src, "-o", out],
                      capture_output=True, text=True).returncode != 0:
        return None, None, None
    # "Control Bar" is not a unique AXDescription in this window; the tool refuses ambiguity, so
    # the width discriminator is passed explicitly rather than relying on tree order.
    r = subprocess.run([out, "Control Bar", "--min-width", "1000"], capture_output=True, text=True)
    try:
        payload = json.loads(r.stdout or "{}")
    except ValueError:
        return None, None, None
    b = payload.get("band")
    if not (isinstance(b, list) and len(b) == 4):
        return None, None, None
    # The name comes back off the element that answered, so `subject` cannot drift from the band,
    # and the candidate count comes with it so "there was one" is recorded rather than assumed.
    return tuple(b), payload.get("description"), payload.get("candidates")


def save_panels():
    """Windows AND sheets that are the modal surface a failed Save As leaves behind.

    The first cut of this file compared `len(window_titles())` against `len(document_titles())`,
    which only ever says "no project chooser is visible" — a leftover window named Save sits in
    BOTH lists, so the mutation those checks named could not turn them red. This asks the
    question the checks were written to ask.
    """
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return (name of every window whose name is "Save") & '
              '(name of every sheet of every window)')
    return [t.strip() for t in raw.split(",") if t.strip() == "Save"]


def inner(result):
    return result if isinstance(result, dict) else {}


titles = document_titles()
ev.check("604/precondition-a-project-is-open", bool(titles),
         "Logic has a project window, so File > Save As has something to save",
         f"windows={window_titles()!r}", None)
if not titles:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

# The first document window is not necessarily the arrange window: a plugin window carries the TRACK
# name ("Absolute Zero" here), and picking it gave a title `logic_window` could not find a frame for.
# So the run picks the largest window it can actually locate on screen, which is the arrange window
# on any layout, and needs no knowledge of the title's language.
located = [(t, E.logic_window(t)) for t in titles]
located = [(t, w) for t, w in located if w]
located.sort(key=lambda pair: pair[1]["w"] * pair[1]["h"], reverse=True)
arrange_title, win = located[0] if located else (titles[0], None)
# The band is located by CONTENT, and it watches the CONTROL BAR — not the document.
#
# Three regions of the document view were tried and all three failed identically: quiet at rest,
# different after the run. The full-width top strip differed only in x 720-1200 (arrange content whose
# selection a modal legitimately moves). The leftmost 240 points passed twice then failed, because
# that column is the track-name list with the Mixer closed and MIXER STRIPS with it open. The
# track-header rail, located properly by AXDescription, differed in EVERY vertical slice — the arrange
# view scrolls when a modal takes and returns focus.
#
# So no region of the DOCUMENT is invariant across a refusal, and asserting otherwise produces a red
# that says nothing. What a refusal that writes nothing CAN be held to is that it did not touch the
# transport: the control bar is chrome, does not scroll with the arrange, and its clock only advances
# while playing — which the quiet probe below checks before this band is trusted.
#
# The locator emits nothing when the description is not found, which is a failed precondition rather
# than a licence to fall back to a rectangle.
band, band_subject, band_candidates = _control_bar_band()
ev.check("614/precondition-the-control-bar-was-located",
         band is not None and bool(band_subject) and band_candidates == 1,
         "the visual band is the control bar found by its AXDescription, so it watches the same thing "
         "whatever pane is open and wherever the arrange has scrolled to",
         f"band={band!r}", None)
if band is None:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)
ev.check("604/precondition-the-window-frame-is-known", win is not None,
         "the arrange window's own frame read, so a capture can be taken of it",
         f"window={win!r}", None)
if win is None:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

# This used `len(window_titles()) == len(document_titles())`, which `save_panels()` below already
# documents as saying only "no project chooser is visible" — a leftover window named Save sits in
# BOTH lists. The explanation moved into this file when the harness was repointed and the comparison
# it condemns did not. Ask the question directly.
ev.check("614/precondition-no-save-panel-is-up-before-the-run",
         not save_panels(),
         "no Save panel is up when the run starts, so one afterwards is this operation's doing rather "
         "than something it inherited",
         f"save_panels={save_panels()!r} windows={window_titles()!r}", None)

rec = ev.record_screen(seconds=150)

# The band is the top strip of the window's CONTENT — `screencapture -l` does not include the title
# bar, so despite what every harness in this directory calls it, this is not a title band. Measured
# today: on a window with the Mixer open it lands on track names, the Inspector's "Flex Mode" row and
# a column of plugin-slot buttons, and it carries a focus indicator that moves when a panel opens and
# closes. A negative visual assertion over a region that changes for legitimate reasons produces a
# red that means nothing, which is worse than no assertion.
#
# So the band has to prove it is quiet before it is used as a negative control: two captures at rest,
# nothing happening between them. If they differ, the window is not in a state where this assertion
# can say anything, and the run states that instead of producing an uninterpretable failure.
quiet_a = ev.shot("614/quiet-probe-a", settle_region=band, window_title=arrange_title)
time.sleep(2)
quiet_b = ev.shot("614/quiet-probe-b", settle_region=band, window_title=arrange_title)
band_is_quiet = (quiet_a.get("region_hash") is not None
                 and quiet_a.get("region_hash") == quiet_b.get("region_hash"))
ev.check("614/the-visual-band-is-quiet-at-rest",
         band_is_quiet,
         "two captures of the band with nothing happening between them are identical, so a difference "
         "after the run means the run caused it. Without this the negative control below cannot "
         "distinguish 'the refusal disturbed the window' from 'this part of the window animates'",
         f"a={str(quiet_a.get('region_hash'))[:16]} b={str(quiet_b.get('region_hash'))[:16]} "
         f"window={arrange_title!r}",
         None)

before = ev.shot("604/before", settle_region=band, window_title=arrange_title)

d = E.Driver()
time.sleep(5)

# Logic must own the keyboard or the menu press opens NO panel at all — measured four times on
# 2026-08-19: backgrounded 0/2 panels, frontmost 2/2. Without this the refusal under test would be
# refusing an absent panel, the dismissal would never run, and the checks below could not tell a
# working dismissal from a missing one.
osa('tell application "Logic Pro" to activate')
time.sleep(2)
front = osa('tell application "System Events" to return name of first process whose frontmost is true')
ev.check("604/precondition-logic-owns-the-keyboard",
         front == "Logic Pro",
         "the menu press lands in Logic, so a Save panel actually opens and there is something for "
         "the refusal to describe and the dismissal to clear",
         f"frontmost={front!r}",
         None)

saved = inner(d._send("tools/call", {"name": "logic_project", "arguments": {
    "command": "save_as", "params": {"path": TARGET, "confirmed": True}}}))
text = ((saved.get("result") or {}).get("content") or [{}])[0].get("text", "")
try:
    body = json.loads(text)
except ValueError:
    body = {"raw": text[:400]}
hint = str(body.get("hint") or body.get("raw") or "")
ev.note("604/save-as", {"error": body.get("error"), "hint": hint[:400]})

ev.check("614/the-refusal-names-the-directory-and-the-clause-that-failed",
         MISSING_DIR in hint and "Go to Folder" in hint,
         "the refusal says which directory it was asked for and which step could not complete, so a "
         "reader is not left to guess between a missing panel, an unrecognised panel and a path that "
         "does not resolve",
         f"hint={hint[:320]!r}",
         "replace the sheet-timeout refusal with a bare `.error(\"...\")`: the directory and the "
         "clause disappear from the message and this goes red")

ev.check("614/the-refusal-reports-what-the-dismissal-observed",
         body.get("panels_before_dismissal") is not None
         and body.get("panels_after_dismissal") is not None
         and body.get("escape_delivered") is not None,
         "the refusal carries counts taken before and after the dismissal rather than asserting that "
         "the panel is gone — the first cut of this said \"the panel, if one opened, has been "
         "dismissed\" without ever looking",
         f"before={body.get('panels_before_dismissal')!r} after={body.get('panels_after_dismissal')!r} "
         f"escape_delivered={body.get('escape_delivered')!r}",
         "restore the unconditional sentence in place of the observed counts: these keys vanish and "
         "this goes red")

ev.check("614/the-dismissal-actually-ran-and-cleared-a-real-panel",
         body.get("panels_before_dismissal", 0) >= 1
         and body.get("panels_after_dismissal") == 0,
         "a panel was open when the refusal fired and none is open after — which is the dismissal "
         "code doing its job, observed. The harness this replaces could never see that: it watched a "
         "refusal that happened BEFORE any panel opened, so its no-panel-left-behind check was green "
         "because nothing had ever been there",
         f"before={body.get('panels_before_dismissal')!r} after={body.get('panels_after_dismissal')!r}",
         "remove the `refuse()` call from the sheet-timeout path: a 'Save' window stays on screen, "
         "`panels_after_dismissal` is no longer 0, and this goes red")

ev.check("614/nothing-was-written",
         body.get("write_attempted") is False and not os.path.exists(TARGET)
         and not os.path.isdir(MISSING_DIR),
         "the refusal claims no write was attempted and the file system agrees — neither the project "
         "nor the directory it would have lived in exists",
         f"write_attempted={body.get('write_attempted')!r} target_exists={os.path.exists(TARGET)} "
         f"dir_exists={os.path.isdir(MISSING_DIR)}",
         None)

time.sleep(2)
after_titles = window_titles()
ev.note("604/windows-after", after_titles)

panels_left = save_panels()
ev.check("604/no-panel-is-left-blocking-the-next-operation",
         len(panels_left) == 0,
         "no Save panel remains after the refusal — the old timeout path returned before its "
         "dismissal helper was even defined, and the panel it left up refused every later operation",
         f"save_panels={panels_left!r} all_windows={after_titles!r}",
         "remove the `escapeAnyOpenPanel` call from the timeout path: the 'Save' window stays on "
         "screen, `save_panels()` returns it, and this check goes red")

# The decisive one: the NEXT operation must not be refused by something this run left behind.


# The window is re-resolved by frame area rather than by the title captured earlier. A save that
# succeeds RENAMES the document window, and the lookup then finds nothing while the visual compares a
# real image against a failed lookup and calls it unchanged — a green. This target does not rename
# anything, but the same fix belongs here: a harness that only works when the operation fails to do
# the thing is not a harness anyone can move.
relocated = [(t, E.logic_window(t)) for t in window_titles()]
relocated = [(t, w) for t, w in relocated if w]
relocated.sort(key=lambda pair: pair[1]["w"] * pair[1]["h"], reverse=True)
after_title = relocated[0][0] if relocated else arrange_title
ev.check("614/the-arrange-window-is-still-locatable",
         bool(relocated),
         "the document window can still be found by frame, so the visual below compares two real "
         "captures rather than one capture against a failed lookup",
         f"before_title={arrange_title!r} after_title={after_title!r}", None)
after = ev.shot("604/after", settle_region=band, window_title=after_title)
# This capture is `screencapture -l <arrange window id>`, so a top-level Save dialog is not in
# frame and its presence could never move this band. The assertion is therefore the narrower true
# one — the refusal disturbed nothing behind it. "The panel is gone" is claimed by
# `604/no-panel-is-left-blocking-the-next-operation`, which can see the panel.
# The claim does not bend to the window's state. If the band was not quiet, the precondition above is
# already red and this will be too — and that is the correct outcome: the run cannot produce clean
# evidence from a window whose content was moving on its own before it started. Flipping
# `expect_change` to match whatever happened would make the check pass by agreeing with the result,
# which is the defect this whole directory exists to refuse.
ev.visual("614/the-transport-is-undisturbed",
          before["file"], after["file"], band, expect_change=False, subject=band_subject,
          why="a refusal that writes nothing must leave the transport exactly as it found it. Aimed "
              "at the control bar on purpose: no region of the DOCUMENT is invariant across a "
              "refusal — the arrange scrolls when a modal takes and returns focus — and a control "
              "that reds on a legitimate change is not a control")

# `system.health` was the wrong witness: it builds its report from channel health, cache and
# permissions and never consults `blockingDialogInfo()`, so it cannot report a blocking dialog no
# matter what is on screen. `list_library` (which routes `library.list`) is read-only AND runs the same preflight the mutating
# operations do (TrackDispatcher: `blockingLogicDialogResult(operation: "library.list")`), so a
# leftover panel actually turns this red. It runs AFTER the visual comparison because listing
# the Library can open Logic's Library panel, which would move the very window the visual guards.
follow = d.tool("logic_tracks", "list_library", {})
follow_hint = str((follow or {}).get("hint") or "")
ev.check("604/the-next-operation-is-not-blocked-by-what-this-one-left",
         isinstance(follow, dict) and "preflight_blocking_dialog" not in str(follow),
         "a later operation that fails closed on blocking modals runs instead of refusing — which "
         "is what a leftover panel does to everything that follows it",
         f"error={(follow or {}).get('error')!r} hint={follow_hint[:160]!r}",
         "remove the dismissal: `list_library` refuses with `preflight_blocking_dialog`, and so "
         "would every mutating call after it")

d.close()
ev.restored("614/no-file-was-written-and-no-panel-remains",
            not os.path.exists(TARGET) and not os.path.isdir(MISSING_DIR) and not save_panels(),
            f"the save did not complete, so no project was written to {TARGET!r} and the directory "
            f"it would have needed was never created — that is the failure under study, not a side "
            f"effect — and no modal is left on screen. "
            f"Save panels: {save_panels()!r} Windows: {window_titles()!r}")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
