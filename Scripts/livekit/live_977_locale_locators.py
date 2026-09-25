#!/usr/bin/env python3
"""Live measurement for #977: the plug-in editor, an insert slot's bypass and the docked Mixer are
located in whatever language Logic is in.

Usage:  python3 live_977_locale_locators.py <new-binary> <out.json> [<control-binary>]

Needs Logic in the language under test (`defaults write com.apple.logic10 AppleLanguages -array <id>`
and a relaunch), a disposable project whose first track has a Compressor on insert 0, the Mixer
docked, no plug-in editor open, and nobody using the Mac. The project is saved and one Compressor
parameter is written.

The raw readings come from `ax_977_locator_probe.swift`, which finds every element STRUCTURALLY, so a
label the product gets wrong cannot hide the element it names. The product is then driven through
the three paths the locators gate: `get_inventory` (Mixer area and occupied slots), `project.save`
with an editor open (the editor must not read as a blocking modal), and `set_param_verified` (which
needs both). A control binary, when given, is driven the same way in the same run.

Exit 0 when the product's own path agrees with the raw readings: every new-binary call is State A,
the Compressor is found by its plug-in id, and the probe saw one open editor, one occupied slot and
a Mixer area holding strips.
"""

import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import evidence as E  # noqa: E402
import observation_host  # noqa: E402

if len(sys.argv) < 3:
    sys.exit(__doc__)
NEW, OUT = sys.argv[1], sys.argv[2]
CONTROL = sys.argv[3] if len(sys.argv) > 3 else None

# Addressed by id, because the name the inventory reports is localized.
COMPRESSOR_ID = "logic.stock.effect.compressor"
KEEP = ("state", "success", "verified", "error", "what_was_observed", "hint", "plugins",
        "plugins_unknown_reason", "complete", "dialog_title", "observed_value", "observed_normalized",
        "write_method", "reason", "message")

PROBE = os.path.join(os.path.dirname(os.path.abspath(OUT)), "ax_977_locator_probe")
built = subprocess.run(["swiftc", "-O", os.path.join(HERE, "ax_977_locator_probe.swift"), "-o", PROBE],
                       capture_output=True, text=True)
if built.returncode != 0:
    sys.exit(f"cannot build the probe: {built.stderr[:400]}")


def probe(action=""):
    out = subprocess.run([PROBE] + ([action] if action else []), capture_output=True, text=True,
                         timeout=60)
    try:
        return json.loads(out.stdout)
    except ValueError:
        return {"_raw": (out.stdout or out.stderr)[:400]}


def trim(result):
    if not isinstance(result, dict):
        return {"_raw": str(result)[:400]}
    return {k: result[k] for k in KEEP if k in result}


record = {"host": observation_host.host(), "new_binary": os.path.basename(NEW),
          "control_binary": os.path.basename(CONTROL) if CONTROL else None, "steps": []}


def step(name, value):
    record["steps"].append({"step": name, "result": value})
    print(name, json.dumps(value, ensure_ascii=False)[:300], flush=True)
    return value


step("probe/close-leftover-editors", probe("close-editors").get("acted"))
time.sleep(1.5)
before = step("probe/initial", probe())

drivers = {"new": E.Driver(binary=NEW)}
if CONTROL:
    drivers["control"] = E.Driver(binary=CONTROL)
for driver in drivers.values():
    driver.tool("logic_system", "refresh_cache", {})
tracks = (drivers["new"].resource("logic://tracks") or {}).get("data") or []
info = (drivers["new"].resource("logic://project/info") or {}).get("data") or {}
path = (info.get("filePath") or "").strip()
step("tracks", {"tracks": [(t.get("name"), t.get("id")) for t in tracks], "project": path})
track = tracks[0]["id"] if tracks else 0

inventory = {label: step(f"get_inventory/{label}", trim(
    driver.tool("logic_plugins", "get_inventory", {"track": track}) or {}))
    for label, driver in drivers.items()}
compressor = next((p.get("insert") for p in inventory["new"].get("plugins") or []
                   if p.get("plugin_id") == COMPRESSOR_ID), None)
step("compressor_insert", {"insert": compressor})

step("probe/press-open", probe("press-open").get("acted"))
time.sleep(2.5)
editor = step("probe/editor-open", probe())
saves = {}
for label in reversed(list(drivers)):
    saves[label] = step(f"save_with_editor_open/{label}",
                        trim(drivers[label].tool("logic_project", "save", {}) or {}))
step("probe/close-editors", probe("close-editors").get("acted"))
time.sleep(1.5)

writes = {}
if compressor is not None and path:
    for label, value in (("new", "0.5"), ("control", "0.45")):
        if label not in drivers:
            continue
        writes[label] = step(f"set_param_verified/{label}", trim(drivers[label].tool(
            "logic_plugins", "set_param_verified", {
                "track": track, "insert": compressor, "plugin": "compressor", "param": "threshold",
                "value": value, "unit": "normalized", "mode": "duplicate_applyback",
                "project_expected_path": path}) or {}))
        time.sleep(1.5)
        leftover = probe()
        step(f"probe/after-set_param/{label}", {"dialogs": [d.get("title") for d in
                                                           leftover.get("dialogs") or []]})
        if leftover.get("dialogs"):
            step(f"probe/cleanup/{label}", probe("close-editors").get("acted"))
            time.sleep(1.5)

step("probe/final", probe())
for driver in drivers.values():
    driver.close()

checks = {
    "compressor found by plugin id": compressor is not None,
    "inventory State A": inventory["new"].get("state") == "A",
    "save with an editor open State A": saves["new"].get("state") == "A",
    "set_param_verified State A": (writes.get("new") or {}).get("state") == "A",
    "probe saw one open editor": len(editor.get("dialogs") or []) == 1,
    "probe saw an occupied slot": bool(before.get("occupied_slots")),
    "probe saw a Mixer area holding strips": bool(before.get("mixer_areas")),
}
record["checks"] = checks
with open(OUT, "w", encoding="utf-8") as handle:
    json.dump(record, handle, ensure_ascii=False, indent=1)
for name, ok in checks.items():
    print(("PASS " if ok else "FAIL ") + name)
sys.exit(0 if all(checks.values()) else 1)
