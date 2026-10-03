#!/usr/bin/env python3
"""#1079: which read of the idle poll cycle ends an inline track rename? No server runs.

Usage: LPM_LIVE_LOCK=<held lock> /usr/bin/python3 Scripts/livekit/probe_1079_which_read_ends_the_rename.py \\
       <out.json> [--samples N] [--conditions name,...]
       (in the Logic that is open, with a track selected; default: every condition, three samples)

Per condition and sample, Track > Rename Track is opened the way probe_1079_rename_keeps_focus.py
opens it, and the rename field is recorded by its frame once the focus reads as a text field with a
string value. Then, once a second for up to eight seconds, the condition's reads are made from this
process and the focused element is read; lost means the focus is no longer that field at that frame.

  none           nothing
  osascript      count of documents, then path of front document, as LogicProjectFileReader asks
  header_values  the track headers' text fields, sliders and checkboxes: AXValue and AXDescription
  window_meta    the application's focused and main window and focused element, and every window's
                 title, document, sheets, modal flag, role, subrole, main and focused flags
  walk_roles     every element of every window to depth 12: AXRole and AXDescription
  walk_values    every element of every window to depth 12: AXValue and AXTitle
  walk_help      every element of every window to depth 12: AXHelp
  mixer_help     the elements under the group the canon names the mixer, to depth 6: AXHelp
  header_help    the track headers and their descendants to depth 4: AXHelp (inferTrackType)

A last pass, `help_one_by_one`, opens the rename and reads AXHelp of one element at a time across
Logic's windows, reading the focused element's role after each, and stops at the first read after
which it is no longer a text field; it records that element's role, depth and parent's role.

What it does not say: why Logic ends the edit on a help read.

Measured 2026-10-02, Korean Logic 12.3, the locale-campaign fixture: walk_help and header_help lost
the field in every sample and every other condition kept it; help_one_by_one stopped on a button in
the group beside the track headers.
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PR = _load("probe_1079_rename_keeps_focus")
HOLD_STEPS = 8


class AX:
    def __init__(self):
        import objc
        from Foundation import NSBundle
        bundle = NSBundle.bundleWithPath_(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework")
        self.f = {}
        objc.loadBundleFunctions(bundle, self.f, [("AXUIElementCreateApplication", b"@i"),
                                                  ("AXUIElementCopyAttributeValue", b"i@@o^@")])

    def value(self, element, name):
        status, found = self.f["AXUIElementCopyAttributeValue"](element, name, None)
        return found if status == 0 else None

    def walk(self, element, depth_left, depth=0):
        yield element, depth
        if depth_left == 0:
            return
        for child in self.value(element, "AXChildren") or []:
            yield from self.walk(child, depth_left - 1, depth + 1)

    def app(self):
        out = subprocess.run(["/usr/bin/pgrep", "-x", "Logic Pro"], capture_output=True, text=True).stdout.split()
        return self.f["AXUIElementCreateApplication"](int(out[0])) if out else None


def headers(ax):
    for window in ax.value(ax.app(), "AXWindows") or []:
        for element, _ in ax.walk(window, 12):
            if (ax.value(element, "AXDescription") or "").casefold() in \
                    {n.casefold() for n in PR.P.names("trackHeadersDescription")}:
                return list(ax.value(element, "AXChildren") or [])
    return []


def conditions(ax):
    def none():
        return 0

    def osascript():
        codes = []
        for line in ('tell application id "com.apple.logic10" to count of documents',
                     'tell application id "com.apple.logic10" to get path of front document'):
            codes.append(subprocess.run(["/usr/bin/osascript", "-e", line], capture_output=True,
                                        text=True, timeout=10).returncode)
        return codes

    def header_values():
        n = 0
        for header in headers(ax):
            for element, _ in ax.walk(header, 4):
                if ax.value(element, "AXRole") in ("AXTextField", "AXSlider", "AXCheckBox"):
                    ax.value(element, "AXValue")
                    ax.value(element, "AXDescription")
                    n += 1
        return n

    def window_meta():
        app = ax.app()
        for name in ("AXFocusedWindow", "AXMainWindow", "AXFocusedUIElement"):
            ax.value(app, name)
        for window in ax.value(app, "AXWindows") or []:
            for name in ("AXTitle", "AXDocument", "AXSheets", "AXModal", "AXRole", "AXSubrole", "AXMain", "AXFocused"):
                ax.value(window, name)
        return 1

    def walk(attributes):
        def action():
            n = 0
            for window in ax.value(ax.app(), "AXWindows") or []:
                for element, _ in ax.walk(window, 12):
                    for name in attributes:
                        ax.value(element, name)
                    n += 1
            return n
        return action

    def mixer_help():
        names = {n.casefold() for n in PR.P.names("mixerNamedElement")}
        for window in ax.value(ax.app(), "AXWindows") or []:
            for element, _ in ax.walk(window, 8):
                if (ax.value(element, "AXDescription") or "").casefold() in names \
                        and ax.value(element, "AXRole") in ("AXGroup", "AXLayoutArea", "AXScrollArea"):
                    n = 0
                    for inner, _ in ax.walk(element, 6):
                        ax.value(inner, "AXHelp")
                        n += 1
                    return n
        return 0

    def header_help():
        n = 0
        for header in headers(ax):
            for element, _ in ax.walk(header, 4):
                ax.value(element, "AXHelp")
                n += 1
        return n

    return {"none": none, "osascript": osascript, "header_values": header_values,
            "window_meta": window_meta, "walk_roles": walk(("AXRole", "AXDescription")),
            "walk_values": walk(("AXValue", "AXTitle")), "walk_help": walk(("AXHelp",)),
            "mixer_help": mixer_help, "header_help": header_help}


def open_field(helper):
    PR.open_rename(helper)
    return PR.wait_for_field(helper)


def cancel(helper):
    if PR.P.keyboard_owner_is_logic() is True:
        PR.P.post_escape()
        time.sleep(0.5)


def run_condition(helper, name, action, sample):
    row = {"condition": name, "sample": sample}
    opened, frame = open_field(helper)
    row["opened_after_s"] = opened
    if opened is None:
        row["outcome"] = "not_opened"
        return row
    row["reads"] = []
    lost = None
    for step in range(HOLD_STEPS):
        time.sleep(1.0)
        row["reads"].append(action())
        reading = PR.focus(helper)
        if not (PR.is_rename_field(reading) and reading.get("frame") == frame):
            lost = {"after_action": step + 1, "role": reading.get("role")}
            break
    row["outcome"] = "lost" if lost else "kept"
    row["lost"] = lost
    if lost is None:
        cancel(helper)
    return row


def help_one_by_one(ax, helper, sample):
    row = {"condition": "help_one_by_one", "sample": sample}
    opened, _ = open_field(helper)
    if opened is None:
        row["outcome"] = "not_opened"
        return row
    app = ax.app()

    def focused_role():
        element = ax.value(app, "AXFocusedUIElement")
        return ax.value(element, "AXRole") if element is not None else None

    count = 0
    for window in ax.value(app, "AXWindows") or []:
        for element, depth in ax.walk(window, 12):
            ax.value(element, "AXHelp")
            count += 1
            if focused_role() != "AXTextField":
                parent = ax.value(element, "AXParent")
                row.update(outcome="lost", elements_read=count, element_role=ax.value(element, "AXRole"),
                           element_depth=depth,
                           parent_role=ax.value(parent, "AXRole") if parent is not None else None,
                           focus_role_after=focused_role())
                return row
    row.update(outcome="kept", elements_read=count)
    cancel(helper)
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("out")
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--conditions", default="")
    args = parser.parse_args()
    if not os.environ.get("LPM_LIVE_LOCK") or not os.path.exists(os.environ["LPM_LIVE_LOCK"]):
        sys.exit("cannot run: LPM_LIVE_LOCK must name a held lock")
    if subprocess.run(["/usr/bin/pgrep", "-x", "LogicProMCP"], capture_output=True, text=True).stdout.strip():
        sys.exit("cannot run: a server is running, and this probe measures reads with none")
    helper = PR.build_helper()
    ax = AX()
    every = conditions(ax)
    chosen = [c for c in args.conditions.split(",") if c] or list(every)
    unknown = [c for c in chosen if c not in every]
    if unknown:
        sys.exit(f"unknown condition(s): {unknown}")
    rows = []
    for name in chosen:
        for sample in range(args.samples):
            rows.append(run_condition(helper, name, every[name], sample))
            print(json.dumps({k: rows[-1].get(k) for k in ("condition", "sample", "outcome", "lost", "opened_after_s")}),
                  flush=True)
            time.sleep(1.0)
    for sample in range(2):
        rows.append(help_one_by_one(ax, helper, sample))
        print(json.dumps(rows[-1]), flush=True)
        time.sleep(1.0)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(rows, handle, ensure_ascii=False, indent=1, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
