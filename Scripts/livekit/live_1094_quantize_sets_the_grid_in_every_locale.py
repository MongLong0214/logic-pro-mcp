#!/usr/bin/env python3
"""#1094: logic_edit quantize sets the requested grid on the selected region, in every language.

For each language the fixture is put back from the copy taken before the run, Logic is relaunched in
that language, and one server is started with no route restriction (quantize routes to the
Accessibility rung alone). One MIDI region is selected (AXSelected, read back). Then for each grid in
GRIDS the harness calls `logic_edit quantize value=<grid>` and reads, in its own process, the Region
inspector's Quantize row: the AXRow whose AXPopUpButton shows Logic's `Quantize` row, and the other
pop-up beside it. A step passes when that pop-up showed something else before the call and shows
Logic's label for the grid after it (read from Logic.framework's Localizable.strings for the
language), and the reply is State A. The grids are 1/8 and 1/4, not 1/16: the key command the
merge-base binary sends applies the value Logic already holds, which in this fixture's piano roll
reads 1/16, so a 1/16 request could pass there by coincidence.

    LPM_LIVE_LOCK=<lock> LPM_EVIDENCE_ROOT=<dir> LPM_LOCALE_FIXTURE=<fixture> \\
        python3 live_1094_quantize_sets_the_grid_in_every_locale.py <worktree> <head> <binary> [--lprojs ...]

The fixture is restored before every launch and at the end, and Logic is left in Korean.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import evidence as E  # noqa: E402
import live_993_plugin_root_menu_in_every_locale as L993  # noqa: E402
import logic_live_ax as A  # noqa: E402

GRIDS = (("1/8", "1/8 Note"), ("1/4", "1/4 Note"))
STRINGS = ("/Applications/Logic Pro.app/Contents/Frameworks/Logic.framework/Versions/A/Resources/"
           "%s.lproj/Localizable.strings")


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("worktree")
    parser.add_argument("head")
    parser.add_argument("binary")
    parser.add_argument("--lprojs", nargs="+", default=list(L993.DEFAULT_LPROJS))
    return parser.parse_args()


def labels(logic_canon, lproj):
    table = logic_canon.parse_strings(open(STRINGS % lproj, "rb").read())
    return {"mode": table.get("Quantize"), **{grid: table.get(key) for grid, key in GRIDS}}


def region_items(ax, window):
    """The region layout items under the arrange window's track-content groups, as the #1029 harness
    reads them."""
    out = []
    if window is None:
        return out
    for group, _ in ax.walk(window, 7):
        description = ax.value(group, "AXDescription") or ""
        if ax.value(group, "AXRole") == "AXGroup" and (A.matches(description, "trackContentExplicit")
                                                       or A.matches(description, "trackContentGeneric")):
            for item, _ in ax.walk(group, 4):
                if ax.value(item, "AXRole") == "AXLayoutItem" and A.matches(ax.value(item, "AXHelp"), "regionHelpKeyword"):
                    out.append(item)
    return out


def select_first_region(ax):
    window = A.arrange_window(ax)
    items = region_items(ax, window)
    for item in items:
        if ax.value(item, "AXSelected") is True:
            ax.set(item, "AXSelected", False)
    if items:
        ax.set(items[0], "AXSelected", True)
    time.sleep(0.6)
    return sum(1 for item in region_items(ax, A.arrange_window(ax)) if ax.value(item, "AXSelected") is True)


def quantize_value(ax, mode_label):
    """The value pop-up of the one Quantize row, read by this process, or None when there is not
    exactly one row with one other pop-up."""
    window = A.arrange_window(ax)
    if window is None or not mode_label:
        return None
    rows = []
    for element, _ in ax.walk(window, 14):
        if ax.value(element, "AXRole") == "AXPopUpButton" and ax.value(element, "AXValue") == mode_label:
            parent = ax.value(element, "AXParent")
            others = [c for c in (ax.value(parent, "AXChildren") or [])
                      if ax.value(c, "AXRole") == "AXPopUpButton" and ax.value(c, "AXValue") != mode_label]
            rows.append(others)
    if len(rows) != 1 or len(rows[0]) != 1:
        return None
    value = ax.value(rows[0][0], "AXValue")
    return value if isinstance(value, str) else None


def set_grid(row):
    """The value read before differs from the grid's label, the value read after is that label, and
    the reply is State A."""
    return (isinstance(row.get("label"), str) and row.get("value_before") != row["label"]
            and row.get("value_after") == row["label"] and row.get("reply_state") == "A")


def unchanged(row):
    """The counterexample: the pop-up still shows what it showed before the call."""
    return dict(row, value_after=row.get("value_before"))


def restore_fixture(backup):
    """Put the fixture back from the copy, with Logic quit first and its process count read as 0."""
    census = L993.logic_census()
    if census["status"] != "gone":
        L993.quit_logic()
        census = L993.logic_census()
    if census["status"] != "gone":
        raise RuntimeError(f"Logic's process count read {census['raw']!r}, not 0; the fixture was not replaced")
    shutil.rmtree(L993.FIXTURE)
    subprocess.run(["/usr/bin/ditto", backup, L993.FIXTURE], check=True)


def sha256_of(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def main():
    args = arguments()
    E.REPO = args.worktree
    E.BIN = args.binary
    sys.path.insert(0, os.path.join(args.worktree, "Scripts"))
    import logic_canon  # noqa: E402
    setattr(L993, "logic_canon", logic_canon)
    for key in ("LOGIC_MCP_DEBUG_ONLY_CHANNEL", "LOGIC_MCP_DEBUG_ONLY_CHANNEL_PASS"):
        os.environ.pop(key, None)
    ev = E.Evidence(args.head, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")
    ev.note("1094/binary", {"binary": args.binary, "sha256": sha256_of(args.binary)})
    backup = os.path.join(os.environ["LPM_EVIDENCE_ROOT"], "fixture-before-the-run.logicx")
    if os.path.exists(backup):
        shutil.rmtree(backup)
    subprocess.run(["/usr/bin/ditto", L993.FIXTURE, backup], check=True)
    ax = A.AX()
    rows = []
    try:
        for lproj in args.lprojs:
            restore_fixture(backup)
            launch = L993.switch_to(lproj, force=True)
            ev.note(f"1094/{lproj}/launch", launch)
            if not launch.get("arrange_window"):
                rows.append({"lproj": lproj, "error": "launch"})
                continue
            A.ARRANGE["title"] = launch["arrange_window"]
            names = labels(logic_canon, lproj)
            driver = E.Driver(binary=args.binary)
            try:
                time.sleep(6)
                A.activate_logic()
                selected = select_first_region(ax)
                for grid, _ in GRIDS:
                    before = quantize_value(ax, names["mode"])
                    reply = driver.tool("logic_edit", "quantize", {"value": grid}) or {}
                    time.sleep(1.0)
                    after = quantize_value(ax, names["mode"])
                    row = {"lproj": lproj, "grid": grid, "label": names[grid], "regions_selected": selected,
                           "value_before": before, "value_after": after,
                           "reply_state": reply.get("state") if isinstance(reply, dict) else None,
                           "reply_method": reply.get("method") if isinstance(reply, dict) else None,
                           "reply_error": reply.get("error") if isinstance(reply, dict) else None}
                    rows.append(row)
                    ev.falsifiable(f"1094/{lproj}/{grid}", set_grid, row, unchanged(row),
                                   expected="the inspector's quantize value shows the grid's label after the call")
                    print(json.dumps(row, ensure_ascii=False), flush=True)
            finally:
                driver.close()
    finally:
        try:
            restore_fixture(backup)
            ev.note("1094/restore", L993.switch_to(L993.RESTORE, force=True))
        except Exception as exc:  # noqa: BLE001 - recorded as a failed restoration
            ev.note("1094/restore", {"error": repr(exc)})
    ev.note("1094/rows", rows)
    out = ev.write()
    print("written", out)
    failed = [f"{r['lproj']} {r.get('grid')}" for r in rows if not set_grid(r)]
    print(json.dumps({"rows": len(rows), "failed": failed}, ensure_ascii=False))
    return 0 if rows and not failed and len(rows) == len(args.lprojs) * len(GRIDS) else 1


if __name__ == "__main__":
    sys.exit(main())
