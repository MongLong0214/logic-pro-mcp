"""Live proof that `project.save_as` writes a project at the path it was asked for.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_606_save_as_writes_the_file.py <worktree> <full-40-char-head-sha>

WHAT THIS RUN IS ABOUT
----------------------
`save_as` did not work, and the reasons were three separate lies the code told itself.

1. It pressed `File ▸ Save As…` without bringing Logic forward. Logic DISABLES its
   document-modifying File items while it is a background application — and an `AXPress` on a
   disabled item reports SUCCESS. Measured 2026-08-19, four trials: backgrounded, the press opens
   zero panels (0/2); frontmost, it opens one (2/2). `Open…` stays enabled either way, so this is a
   property of the item, not of AX menu presses.

2. It looked for the filename field by `AXDescription == "text field"` and found NOTHING. The rule
   came from an AppleScript probe, and System Events *synthesises* `description` from
   `AXRoleDescription` when `AXDescription` is nil. Through the API this code uses:

       field        SysEv description     AXDescription   AXRoleDescription     AXFocused
       search       "search text field"   nil             "search text field"   false
       FILENAME     "text field"          nil             "text field"          true
       tag editor   "tag editor"          "tag editor"    "text field"          false

   Focus selects exactly one, is not localised, and is the field a person types into.

3. It typed the whole POSIX path into that field. This panel does not navigate on a typed path —
   measured twice, by `AXConfirm` and by a real Return, and both times Logic saved a project
   literally NAMED `:Users:isaac:Music:Logic:x` into whatever folder the panel had open. It reported
   success. The old "no file appeared at the requested path" was therefore true and useless: the
   file existed, under a name made out of the path. The panel's own "Go to Folder" sheet is what
   moves it.

So this run does not check that `save_as` returns success — the broken version could do that. It
checks that a project exists at the exact path, that no path-named project was created, and that
Logic's own window title says it is that project.

The first call in a fresh process is separately refused as `blocking_dialog_present` on a screen
with no dialog (#608, filed, not fixed here). The run performs one read-only call first and records
that it had to.
"""

import json
import os
import shutil
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
DIRECTORY = "/Users/isaac/Music/Logic"
# Unique per run. The first cut used a fixed name and left Logic open under it, so on the SECOND run
# the window title already matched before save_as was called and `logic-says-it-is-now-that-project`
# was satisfied by the previous run rather than by this one. A check a prior run can satisfy is not
# a check.
NAME = f"lpm-606-live-proof-{HEAD[:8]}-{os.getpid()}"
TARGET = f"{DIRECTORY}/{NAME}.logicx"
# What the OLD code produced instead: the path itself as a filename, with "/" shown as ":".
PATH_AS_NAME = f"{DIRECTORY}/{TARGET.replace('/', ':')}"


def colon_named_bundles():
    """Every project in the target folder whose name is a mangled path.

    Probing one guessed path was not enough: the old failure wrote into whatever folder the panel
    happened to have open, so a single `os.path.exists` on a name built from DIRECTORY could be
    green while the artifact sat elsewhere. This at least sees the whole target folder, and the
    check below compares BEFORE against AFTER so absence-by-default cannot pass for evidence.
    """
    try:
        return sorted(n for n in os.listdir(DIRECTORY) if ":" in n)
    except OSError:
        return []


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_titles():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def any_sheets():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return (count of sheets of every window)')
    return [n for n in raw.split(",") if n.strip() not in ("", "0")]


def save_panels():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return (name of every window whose name is "Save")')
    return [t.strip() for t in raw.split(",") if t.strip() == "Save"]


for stale in (TARGET, PATH_AS_NAME):
    if os.path.isdir(stale):
        shutil.rmtree(stale)

titles = window_titles()
ev.check("606/precondition-a-project-is-open", bool(titles),
         "Logic has a project window, so File > Save As has something to save",
         f"windows={titles!r}", None)
if not titles:
    ev.write()
    sys.exit("no project open")

colon_before = colon_named_bundles()
ev.check("606/precondition-target-path-is-clear",
         not os.path.exists(TARGET) and not os.path.exists(PATH_AS_NAME),
         "neither the requested path nor the path-as-a-name variant exists before the run, so "
         "anything found afterwards was written by this run",
         f"target={os.path.exists(TARGET)} path_as_name={os.path.exists(PATH_AS_NAME)}", None)

# Pick the arrange window by AREA rather than by a title suffix: the title is localised and a
# plugin window can end in the same word. The band is the top strip of that window's own frame.
located = [(t, E.logic_window(t)) for t in titles]
located = [(t, w) for t, w in located if w]
located.sort(key=lambda pair: pair[1]["w"] * pair[1]["h"], reverse=True)
arrange_title, win = located[0] if located else (titles[0], None)
# The window's own title bar, and the subject says so. The band is derived from a frame this run
# measured — `logic_window` reads it from CoreGraphics — rather than from a layout somebody
# remembered, and 28 points is the strip that holds the document name.
band = (0, 0, win["w"], 28) if win else None
# Not the title it carried before: this run RENAMES the window, so naming the band after the old
# title would describe the after-capture as something it is not.
band_subject = "the document window's title bar" if win else None
ev.check("606/precondition-the-window-frame-is-known",
         band is not None and bool(band_subject),
         "the arrange window's own frame read, so the capture band is inside it and can be named",
         f"window={win!r} band={band!r} subject={band_subject!r}", None)
if band is None:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=150)
before = ev.shot("606/before", settle_region=band, window_title=arrange_title)

d = E.Driver()
time.sleep(3)

# #608: the first call in a fresh process is refused on a dialog that is not there. This one is
# read-only and is here to absorb that, not to prove anything — it is recorded so the receipt shows
# the run had to do it.
warm = d.tool("logic_tracks", "list_library", {})
ev.note("606/warmup-first-call-is-refused-see-608", {
    "error": (warm or {}).get("error"),
    "blocking_dialog_present": (warm or {}).get("blocking_dialog_present"),
})

titles_before_save = window_titles()
saved = d.tool("logic_project", "save_as", {"path": TARGET, "confirmed": True})
ev.note("606/save-as", {k: saved.get(k) for k in
                        ("state", "success", "error", "hint", "requested", "observed", "via")
                        if isinstance(saved, dict)})

time.sleep(3)

ev.check("606/a-project-exists-at-the-exact-requested-path",
         os.path.isdir(TARGET),
         "the operation wrote a project bundle at the path it was given — the thing the operation is "
         "for, and the thing that never happened before this change",
         f"exists={os.path.isdir(TARGET)} path={TARGET!r}",
         "remove the Go-to-Folder step from `saveAsViaAXDialog`: the panel stays in whatever folder "
         "it opened in, nothing is written here, and this goes red")

colon_after = colon_named_bundles()
ev.check("606/no-project-was-created-with-the-path-as-its-name",
         colon_after == colon_before and not os.path.exists(PATH_AS_NAME),
         "the old failure produced a project literally NAMED after the requested path — so what is "
         "proven is that the set of path-named projects in the target folder is UNCHANGED across "
         "the run, not merely that one guessed name is absent",
         f"before={colon_before!r} after={colon_after!r} probe_exists={os.path.exists(PATH_AS_NAME)}",
         "revert step 3b to setting the full path into the filename field: a ':Users:…' bundle "
         "appears in this folder, the two censuses differ, and this goes red")

ev.check("606/the-operation-reported-state-A",
         isinstance(saved, dict) and saved.get("state") == "A" and saved.get("success") is True,
         "the response claims a verified write, and the two checks above are what independently "
         "corroborate that claim rather than taking it",
         f"state={(saved or {}).get('state')!r} success={(saved or {}).get('success')!r} "
         f"error={(saved or {}).get('error')!r}",
         "revert the frontmost gate: the menu item is disabled from the background, the press "
         "reports success, no panel opens, and this reports element_not_found instead")

title_after = window_titles()
ev.check("606/logic-changed-its-title-to-this-runs-project",
         any(t.startswith(NAME) for t in title_after)
         and not any(t.startswith(NAME) for t in titles_before_save),
         "Logic's own window title now names this run's project and did NOT before the call — a "
         "readback through the UI, and one that a previous run cannot pre-satisfy because the name "
         "carries this run's head and pid",
         f"before={titles_before_save!r} after={title_after!r} name={NAME!r}",
         "revert the Go-to-Folder step: the title becomes the colon-mangled path, so the 'after' "
         "half fails and this goes red")

# `save_panels()` only asked for windows named "Save", so a leftover Go-to-Folder SHEET — which the
# new step 3a can open — would not have tripped it. And on a run where no panel ever opened this is
# green for the wrong reason, so it is recorded as a guard rather than as proof of the dismissal.
ev.check("606/no-panel-or-sheet-was-left-behind",
         not save_panels() and not any_sheets(),
         "neither the Save panel nor its Go-to-Folder sheet is on screen — a successful save must "
         "not leave a modal up any more than a refusal may. This is a guard, not a proof of the "
         "dismissal code: on a run where the panel never opened it is green for the wrong reason, "
         "and the run that exercises the dismissal is the refusal harness for #604",
         f"save_panels={save_panels()!r} sheets={any_sheets()!r}", None)

# The operation RENAMES the window, so capturing "after" by the title captured "before" can only
# ever miss — the first cut of this file did exactly that and recorded "no Logic window on screen",
# which then made the visual compare a real image against nothing and call it unchanged. Re-resolve
# the arrange window by area, the same way the "before" side chose it.
relocated = [(t, E.logic_window(t)) for t in window_titles()]
relocated = [(t, w) for t, w in relocated if w]
relocated.sort(key=lambda pair: pair[1]["w"] * pair[1]["h"], reverse=True)
after_title = relocated[0][0] if relocated else arrange_title
ev.check("606/the-arrange-window-is-still-locatable-after-the-save",
         bool(relocated),
         "the document window can still be found by frame after the save, so the visual below "
         "compares two real captures rather than one capture against a failed lookup",
         f"before_title={arrange_title!r} after_title={after_title!r}", None)
after = ev.shot("606/after", settle_region=band, window_title=after_title)
ev.visual("606/the-window-title-changed-to-the-new-project",
          before["file"], after["file"], band, subject=band_subject,
          expect_change=True,
          why="saving under a new name renames the document window, so the title band must differ; "
              "if it does not, the project on screen is still the old one whatever the file system "
              "says")

d.close()

removed = False
if os.path.isdir(TARGET):
    shutil.rmtree(TARGET)
    removed = not os.path.exists(TARGET)
ev.restored("606/the-project-this-run-created-was-removed",
            removed and not os.path.exists(PATH_AS_NAME),
            f"the run's own artifact at {TARGET!r} was deleted, and no path-named artifact remains. "
            f"Logic still has it open under that name — that is a live-session fact this run cannot "
            f"undo without closing the project, and it is stated rather than papered over.")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
