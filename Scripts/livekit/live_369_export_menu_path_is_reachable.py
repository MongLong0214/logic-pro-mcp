#!/usr/bin/env python3
"""Live proof that Logic exposes the two audio-export menu leaves before any panel is opened.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_369_export_menu_path_is_reachable.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
An AX menu item can exist and still read disabled because Logic is blocked by a modal. That makes a
failed export lookup ambiguous: it might describe the export path, or it might merely describe an
unavailable application. The same condition disables File > Open…, so Open is the necessary control
for this measurement rather than an unrelated extra assertion.

WHAT IS MEASURED NOW, AND WHAT IS STILL NOT
-------------------------------------------
With no modal and Logic frontmost on Korean Logic 12.x, the raw AX tree exposes both
`파일 > 내보내기 > 모든 트랙을 오디오 파일로…` and
`파일 > 내보내기 > 1개의 트랙을 오디오 파일로…` as
AXMenuBarItem > AXMenu > AXMenuItem > AXMenu > AXMenuItem. Both leaves, and File > Open…, report
AXEnabled=true while all menus remain closed.

The export panel is deliberately UNMEASURED. This harness stops at the menu tree and does not press
either export item, so it says nothing about panel fields, export settings, or an audio file landing.
"""

import json
import os
import subprocess
import sys

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

# The File menu itself is policy-owned; use that exact measured candidate family rather than a
# harness-local English/Korean list.
FILE_LABELS = E.label_set("fileMenuBar")
# These leaf labels were measured on Korean Logic 12.x only. They intentionally have no translated
# fallback, so another locale reports an absent element instead of claiming a guessed menu path.
EXPORT = "내보내기"
ALL_TRACKS = "모든 트랙을 오디오 파일로…"
ONE_TRACK = "1개의 트랙을 오디오 파일로…"
OPEN = "열기…"
EXPECTED_EXPORT_ROLES = ["AXMenuBarItem", "AXMenu", "AXMenuItem", "AXMenu", "AXMenuItem"]
EXPECTED_OPEN_ROLES = ["AXMenuBarItem", "AXMenu", "AXMenuItem"]


def finish(code=1):
    out = ev.write()
    print(json.dumps(out, indent=1))
    sys.exit(code)


def osa(script):
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (result.stdout or "").strip()


def frontmost_bundle_id():
    return osa('tell application "System Events" to return bundle identifier of first process whose frontmost is true')


def compile_probe():
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_plugin_menu_probe.swift")
    tool = os.path.join(ev.dir, "ax_plugin_menu_probe")
    result = subprocess.run(["swiftc", "-O", source, "-o", tool], capture_output=True)
    return tool, result


def probe(tool):
    config = {
        "file_labels": FILE_LABELS,
        "export_label": EXPORT,
        "all_tracks_label": ALL_TRACKS,
        "one_track_label": ONE_TRACK,
        "open_label": OPEN,
    }
    result = subprocess.run([tool, "export-menu", json.dumps(config, ensure_ascii=False)],
                            capture_output=True, text=True)
    try:
        body = json.loads(result.stdout or "{}")
    except ValueError:
        body = {"_raw": (result.stdout or result.stderr)[:400]}
    body["_returncode"] = result.returncode
    return body


def path_name(node):
    if not isinstance(node, dict):
        return ""
    return node.get("title") or node.get("description") or ""


def export_path_resolves(path, leaf):
    return (
        isinstance(path, list)
        and [node.get("role") if isinstance(node, dict) else None for node in path] == EXPECTED_EXPORT_ROLES
        and len(path) == 5
        and path_name(path[0]) in FILE_LABELS
        and path_name(path[2]) == EXPORT
        and path_name(path[4]) == leaf
    )


# Do this check before compiling a witness or querying AX. `check()` will record the modal state too,
# but that receipt alone is not a precondition: it would let this run continue after taking readings
# through the audio-hardware alert that makes every menu item look unavailable.
modal = E.blocking_modal()
ev.check("369/precondition-no-blocking-modal",
         modal is None,
         "no CoreGraphics modal-panel window belongs to Logic before this menu-only read",
         f"blocking_modal={modal!r}",
         "put up Logic's audio-hardware alert: the precondition goes red and no export path is read")
if modal is not None:
    finish()

frontmost = frontmost_bundle_id()
ev.check("369/precondition-logic-is-frontmost",
         frontmost == "com.apple.logic10",
         "Logic Pro is the frontmost application, so AXEnabled describes its available menu state",
         f"frontmost_bundle_id={frontmost!r}",
         "background Logic: its File menu items can read disabled and this run refuses that confound")
if frontmost != "com.apple.logic10":
    finish()

policy_ready = isinstance(FILE_LABELS, list) and bool(FILE_LABELS)
ev.check("369/precondition-the-file-menu-label-policy-is-readable",
         policy_ready,
         "AXLocalePolicy supplies the File menu's measured candidate labels",
         f"file_labels={FILE_LABELS!r}",
         "remove the File LabelSet: the harness refuses instead of guessing a top-level menu name")
if not policy_ready:
    finish()

tool, built = compile_probe()
ev.check("369/precondition-the-raw-ax-witness-built",
         built.returncode == 0,
         "the raw-AX witness compiled, so the asserted roles and AXEnabled values are not a System "
         "Events rendering",
         f"rc={built.returncode} stderr={(built.stderr or b'').decode('utf-8', 'replace')[:300]!r}",
         "break the witness source: the menu path cannot be measured and this goes red")
if built.returncode != 0:
    finish()

arrange = E.logic_window()
band = (0, 0, arrange["w"], 28) if arrange else None
band_subject = f"the title bar of the {arrange['title']!r} document window" if arrange else None
ev.check("369/precondition-a-project-window-is-available-for-the-unchanged-menu-capture",
         arrange is not None and band is not None and bool(band_subject),
         "a Logic document window is on screen for the before/after capture; this harness does not "
         "need to modify that project",
         f"arrange={arrange!r} band={band!r}",
         "close the document window: the menu may still exist, but the required unchanged-state "
         "capture cannot and this goes red")
if band is None:
    finish()

rec = ev.record_screen(seconds=75)
before = ev.shot("369/before", settle_region=band, window_title=arrange["title"])

driver = E.Driver()
health = driver.tool("logic_system", "health", {})
ev.falsifiable("369/the-release-artifact-answers-a-read-only-wire-request",
               lambda body: isinstance(body, dict) and bool(body), health, {},
               "the built server answered a read-only health request during this evidence run",
               "start an artifact that cannot answer MCP: the empty/error response goes red")

# `export-menu` only walks existing AXChildren. It does not perform AXPress or AXShowMenu, so neither
# the File menu nor the export panel is opened by this harness.
result = probe(tool)
ev.note("369/export-menu-raw-ax", result)

all_tracks_path = result.get("all_tracks_path")
one_track_path = result.get("one_track_path")
all_tracks_resolves = export_path_resolves(all_tracks_path, ALL_TRACKS)
one_track_resolves = export_path_resolves(one_track_path, ONE_TRACK)
ev.falsifiable(
    "369/all-tracks-export-resolves-through-the-three-level-menu-path",
    lambda observation: observation["ok"],
    {"ok": all_tracks_resolves},
    {"ok": False},
    "the named all-tracks export leaf resolves as AXMenuBarItem > AXMenu > AXMenuItem > AXMenu > AXMenuItem",
    "remove or re-parent the leaf: its role/name path no longer matches and this goes red",
)
ev.falsifiable(
    "369/one-track-export-resolves-through-the-three-level-menu-path",
    lambda observation: observation["ok"],
    {"ok": one_track_resolves},
    {"ok": False},
    "the named one-track export leaf resolves through the same five-node AX menu path",
    "remove or re-parent the leaf: its role/name path no longer matches and this goes red",
)

export_leaves_enabled = (all_tracks_resolves and one_track_resolves
                         and all_tracks_path[-1].get("enabled") is True
                         and one_track_path[-1].get("enabled") is True)
ev.falsifiable(
    "369/both-export-leaves-read-axenabled-true-with-no-menu-opened",
    lambda observation: observation["ok"],
    {"ok": export_leaves_enabled},
    {"ok": False},
    "both resolved export leaves report raw AXEnabled=true while this run has opened no menu or panel",
    "make either leaf disabled: the combined availability assertion goes red",
)

open_path = result.get("open_path")
open_is_enabled = (
    isinstance(open_path, list)
    and [node.get("role") if isinstance(node, dict) else None for node in open_path] == EXPECTED_OPEN_ROLES
    and len(open_path) == 3
    and path_name(open_path[0]) in FILE_LABELS
    and path_name(open_path[-1]) == OPEN
    and open_path[-1].get("enabled") is True
)
ev.falsifiable(
    "369/control-file-open-is-enabled-too",
    lambda observation: observation["ok"],
    {"ok": open_is_enabled},
    {"ok": False},
    "File > Open… also reports AXEnabled=true. If Open is false, this run is measuring a blocked "
    "application, not the export items",
    "put Logic behind a blocking modal: Open reads false and this control rejects the confounded run",
)

after = ev.shot("369/after", settle_region=band, window_title=arrange["title"])
ev.visual("369/menu-path-inspection-leaves-the-project-unchanged",
          before["file"], after["file"], band, subject=band_subject, expect_change=False,
          why="this harness stops at AX menu children and only makes read-only requests; it opens no "
              "export panel and writes no project state")

driver.close()
ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
