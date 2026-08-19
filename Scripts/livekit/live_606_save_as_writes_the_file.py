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
NAME = "lpm-606-live-proof"
TARGET = f"{DIRECTORY}/{NAME}.logicx"
# What the OLD code produced instead: the path itself as a filename, with "/" shown as ":".
PATH_AS_NAME = f"{DIRECTORY}/{TARGET.replace('/', ':')}"


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_titles():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


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
band = (0, 0, win["w"], 28) if win else None
ev.check("606/precondition-the-window-frame-is-known", band is not None,
         "the arrange window's own frame read, so the capture band is inside it",
         f"window={win!r} band={band!r}", None)
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

ev.check("606/no-project-was-created-with-the-path-as-its-name",
         not os.path.exists(PATH_AS_NAME),
         "the old failure produced a project literally NAMED after the requested path, in the wrong "
         "folder, while reporting success — so its absence is the specific thing being proven",
         f"path_as_name_exists={os.path.exists(PATH_AS_NAME)} probe={PATH_AS_NAME!r}",
         "revert step 3b to setting the full path into the filename field: this folder appears and "
         "this goes red")

ev.check("606/the-operation-reported-state-A",
         isinstance(saved, dict) and saved.get("state") == "A" and saved.get("success") is True,
         "the response claims a verified write, and the two checks above are what independently "
         "corroborate that claim rather than taking it",
         f"state={(saved or {}).get('state')!r} success={(saved or {}).get('success')!r} "
         f"error={(saved or {}).get('error')!r}",
         "revert the frontmost gate: the menu item is disabled from the background, the press "
         "reports success, no panel opens, and this reports element_not_found instead")

title_after = window_titles()
ev.check("606/logic-says-it-is-now-that-project",
         any(t.startswith(NAME) for t in title_after),
         "Logic's own window title names the saved project — a readback through the UI rather than "
         "through the file system, so a stale directory listing cannot carry this check",
         f"windows={title_after!r}",
         "revert the Go-to-Folder step: the title becomes the colon-mangled path and this goes red")

ev.check("606/no-panel-was-left-behind",
         not save_panels(),
         "the Save panel is gone — a successful save must not leave its own modal up any more than a "
         "refusal may",
         f"save_panels={save_panels()!r}", None)

after = ev.shot("606/after", settle_region=band, window_title=arrange_title)
ev.visual("606/the-window-title-changed-to-the-new-project",
          before["file"], after["file"], band, expect_change=True,
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
