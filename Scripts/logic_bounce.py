#!/usr/bin/env python3
"""Drive Logic Pro 12.2's Bounce dialog to produce an audio file at a target path.

Logic exposes no AppleScript bounce verb and its save panel's filename field is not
Accessibility-exposed, so this drives the dialog with native CGEvent posts. Coordinates
are computed from the save-panel window frame (AX-readable) for portability. The bounce
is written to a staging folder (a sidebar Favorite, default Downloads) and moved to the
requested output_dir afterwards, because Cmd+Shift+G "Go to Folder" cannot be confirmed
via automation.

CRITICAL: the input source MUST be ABC before typing or a Korean IME mangles the name.

Usage:
  logic_bounce.py --target-path PATH [--staging ~/Downloads]
  logic_bounce.py --name NAME --output-dir DIR [--staging ~/Downloads]
Prints a one-line JSON result.
"""
import argparse
import glob
import json
import os
import shutil
import sys
import time
import uuid
from typing import Optional

from logic_input_source import TARGET_INPUT_SOURCE_IDS, TISRuntime, select_input_source, set_input_abc
from logic_bounce_ui import (
    OSA_TIMEOUT_SEC,
    bounce_dialog_present,
    bounce_focus_diagnostics,
    bounce_settings_present,
    click_bounce_settings_confirm,
    open_bounce_dialog,
    osa,
    save_panel_present,
    send_ui_events,
)

_select_input_source = select_input_source


def unique_staging_name(name: str) -> str:
    return f"{name}--lpmcp-{uuid.uuid4().hex[:8]}"


def fresh_staged_file(path: str, staging_dir: str, min_mtime: float) -> bool:
    try:
        staged_dir = os.path.abspath(staging_dir)
        path_dir = os.path.abspath(os.path.dirname(path))
        path_mtime = os.path.getmtime(path)
    except OSError:
        return False
    if path_dir != staged_dir or os.path.islink(path) or not os.path.isfile(path):
        return False
    return path_mtime >= min_mtime


def find_staged_artifact(staging_dir: str, staged_name: str, min_mtime: float) -> Optional[str]:
    scored = []
    for path in glob.glob(os.path.join(staging_dir, f"{staged_name}.*")):
        if not fresh_staged_file(path, staging_dir, min_mtime):
            continue
        try:
            scored.append((os.path.getmtime(path), path))
        except OSError:
            # Candidate vanished/renamed in the race window between the filter and
            # this stat. Skip it instead of letting getmtime raise out of sorted()
            # and print a Python traceback where the Swift caller expects one-line
            # JSON (which would surface as a generic parse failure).
            continue
    scored.sort(reverse=True)
    return scored[0][1] if scored else None


def move_staged_artifact_no_overwrite(staged_path: str, final_path: str) -> Optional[str]:
    try:
        source = open(staged_path, "rb")
    except OSError as exc:
        return f"artifact_stage_unreadable: {exc}"

    output_dir = os.path.dirname(final_path)
    final_name = os.path.basename(final_path)
    dir_flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        dir_flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        dir_flags |= os.O_NOFOLLOW

    try:
        dir_fd = os.open(output_dir, dir_flags)
    except OSError:
        source.close()
        return "artifact_output_dir_unsafe"

    create_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        create_flags |= os.O_NOFOLLOW

    try:
        fd = os.open(final_name, create_flags, 0o644, dir_fd=dir_fd)
    except FileExistsError:
        os.close(dir_fd)
        source.close()
        return "artifact_already_exists"
    except OSError as exc:
        os.close(dir_fd)
        source.close()
        return f"artifact_move_failed: {exc}"

    try:
        with source, os.fdopen(fd, "wb") as destination:
            shutil.copyfileobj(source, destination)
        os.unlink(staged_path)
    except OSError as exc:
        try:
            os.unlink(final_name, dir_fd=dir_fd)
        except OSError:
            pass
        return f"artifact_move_failed: {exc}"
    finally:
        os.close(dir_fd)
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target-path", help="planned destination path (extension may be replaced with the actual bounce format)")
    ap.add_argument("--name", help="legacy filename without extension")
    ap.add_argument("--output-dir", help="legacy final destination dir (absolute)")
    ap.add_argument("--staging", default=os.path.expanduser("~/Downloads"))
    args = ap.parse_args()

    if args.target_path:
        target_path = os.path.abspath(args.target_path)
        output_dir = os.path.dirname(target_path)
        target_stem_path, _ = os.path.splitext(target_path)
        target_name = os.path.basename(target_stem_path)
    elif args.name and args.output_dir:
        output_dir = os.path.abspath(args.output_dir)
        target_name = args.name
        target_stem_path = os.path.join(output_dir, target_name)
        target_path = target_stem_path
    else:
        ap.error("provide --target-path or the legacy --name + --output-dir pair")

    result = {"name": target_name, "output_dir": output_dir, "target_path": target_path}
    result["bounce_fired"] = False

    # 1. deterministic input-source switch (avoid Korean IME mangling the filename)
    if not set_input_abc():
        result["success"] = False
        result["error"] = "input_source_switch_failed"
        print(json.dumps(result)); return 1
    time.sleep(0.4)

    dialog_up, dialog_open_strategies = open_bounce_dialog()
    result["dialog_open_strategies"] = dialog_open_strategies
    if not dialog_up:
        result["success"] = False
        result["error"] = "bounce_dialog_did_not_appear"
        result.update(bounce_focus_diagnostics())
        print(json.dumps(result)); return 1

    # 3. OK on the (AX-accessible) settings dialog -> save panel
    if not click_bounce_settings_confirm():
        result["success"] = False
        result["error"] = "bounce_confirm_button_not_found"
        print(json.dumps(result)); return 1
    time.sleep(2.5)
    result["save_panel_present"] = save_panel_present()
    if not result["save_panel_present"]:
        result["success"] = False
        result["error"] = "bounce_save_panel_did_not_appear"
        result.update(bounce_focus_diagnostics())
        print(json.dumps(result)); return 1

    # 4. read the save-panel window frame
    pos = osa('tell application "System Events" to tell process "Logic Pro" to get position of front window')
    size = osa('tell application "System Events" to tell process "Logic Pro" to get size of front window')
    try:
        ox, oy = [int(v.strip()) for v in pos.split(",")]
        w, h = [int(v.strip()) for v in size.split(",")]
    except (TypeError, ValueError):
        result["success"] = False
        result["error"] = f"could_not_read_save_panel_frame pos={pos!r} size={size!r}"
        print(json.dumps(result)); return 1
    result["panel_frame"] = [ox, oy, w, h]

    staged_name = unique_staging_name(target_name)

    # 5. set a clean Save As name (offsets calibrated live against the standard
    # Logic 12.2 bounce save panel: frame [520,142,880,604] -> field (1040,196))
    saveas = (ox + int(0.591 * w), oy + 54)
    if not send_ui_events(f"c:{saveas[0]},{saveas[1]}"):
        result["success"] = False
        result["error"] = "save_panel_name_click_failed"
        print(json.dumps(result)); return 1
    time.sleep(0.4)
    if not send_ui_events("kd:cmd", "t:a", "ku:cmd"):
        result["success"] = False
        result["error"] = "save_panel_name_select_failed"
        print(json.dumps(result)); return 1
    time.sleep(0.2)
    if not send_ui_events("kp:delete"):
        result["success"] = False
        result["error"] = "save_panel_name_clear_failed"
        print(json.dumps(result)); return 1
    time.sleep(0.2)
    if not send_ui_events(f"t:{staged_name}"):
        result["success"] = False
        result["error"] = "save_panel_name_type_failed"
        print(json.dumps(result)); return 1
    time.sleep(0.4)

    # 6. navigate to the staging Favorite (sidebar Downloads); go-to-folder is unusable.
    # Sidebar is a fixed-width left column: Downloads row at frame +(86,184).
    downloads = (ox + 86, oy + 184)
    if not send_ui_events(f"c:{downloads[0]},{downloads[1]}"):
        result["success"] = False
        result["error"] = "save_panel_staging_sidebar_click_failed"
        print(json.dumps(result)); return 1
    time.sleep(1.0)

    # 7. clear any prior staged artifact, then click the Bounce default button
    # (bottom-right corner of the panel: frame +(w-60, h-32) -> (1340,714)).
    staged = os.path.join(args.staging, f"{staged_name}.aif")
    if os.path.exists(staged):
        os.remove(staged)
    bounce_btn = (ox + w - 60, oy + h - 32)
    bounce_started_at = time.time()
    if not send_ui_events(f"c:{bounce_btn[0]},{bounce_btn[1]}"):
        result["success"] = False
        result["error"] = "bounce_button_click_failed"
        print(json.dumps(result)); return 1
    result["bounce_fired"] = True

    # 8. poll the staging folder for the produced artifact. Use the
    # extension-agnostic finder so any operator-configured Bounce format
    # (WAV/CAF/MP3/AAC, not only AIFF) is detected as soon as it lands, instead
    # of waiting out the full 25s budget before an .aif-only check fails over.
    appeared = None
    for _ in range(25):
        appeared = find_staged_artifact(args.staging, staged_name, bounce_started_at)
        if appeared:
            break
        time.sleep(1.0)
    if not appeared:
        result["success"] = False
        result["error"] = "artifact_not_produced_in_staging"
        print(json.dumps(result)); return 1

    # 9. move to the requested output_dir (locate-and-move)
    if os.path.lexists(output_dir):
        if os.path.islink(output_dir) or not os.path.isdir(output_dir):
            result["success"] = False
            result["error"] = "artifact_output_dir_unsafe"
            print(json.dumps(result)); return 1
    else:
        try:
            os.makedirs(output_dir, exist_ok=False)
        except OSError as exc:
            result["success"] = False
            result["error"] = f"artifact_move_failed: {exc}"
            print(json.dumps(result)); return 1
    _, ext = os.path.splitext(appeared)
    final = f"{target_stem_path}{ext}"
    move_error = move_staged_artifact_no_overwrite(appeared, final)
    if move_error:
        result["success"] = False
        result["error"] = move_error
        result["artifact"] = final
        print(json.dumps(result)); return 1
    result["success"] = True
    result["artifact"] = final
    result["size_bytes"] = os.path.getsize(final)
    print(json.dumps(result)); return 0


if __name__ == "__main__":
    sys.exit(main())
