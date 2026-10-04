#!/usr/bin/env python3
"""#1097: select is not State A, and rename renames nothing else, while another track stays selected.

The condition is the one measured in Korean on 2026-10-04 (lpm-evidence/1029/probe-kc-ko.json):
Option-Command-S posted with its flags on the key events and no flagsChanged after them leaves
Logic's own modifier state held. Logic then adds the next selection to the one it has. This harness
posts that chord itself, from its own process, so the condition does not depend on which build of
the CGEvent rung is installed. For each language, with the fixture put back and Logic relaunched in
that language, and one server with no route restriction:

1. select. The chord creates an instrument track, which Logic selects. Then `logic_tracks select
   index 0`. The row passes when the header rows read with another row selected beside row 0 (the
   condition was reproduced), the reply is not State A, and its `also_selected` names those rows.
2. rename. The chord again, then this process sets the header rail's AXSelectedChildren to row 0,
   which Logic adds to the selection. Then `logic_tracks rename index 0` to a unique name. The row
   passes when the condition was reproduced and no row other than 0 changed name: either row 0 alone
   was renamed with State A, or the call was refused as selection_not_exclusive and nothing was
   renamed.

After each trial one flagsChanged with no flags is posted to Logic, which ended the held state in
the probe. The binary must carry the head it is run as in `__TEXT,__lpm_commit`.

    LPM_LIVE_LOCK=<lock> LPM_EVIDENCE_ROOT=<dir> LPM_LOCALE_FIXTURE=<fixture> \\
        python3 live_1097_select_and_rename_need_the_target_alone.py <worktree> <head> <binary> [--lprojs ...]
"""
import argparse
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
import live_1029_cgevent_fallback_in_every_locale as P  # noqa: E402
import logic_live_ax as A  # noqa: E402

OPTION_COMMAND_S = (1, "command+option")


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("worktree")
    parser.add_argument("head")
    parser.add_argument("binary")
    parser.add_argument("--lprojs", nargs="+", default=list(L993.DEFAULT_LPROJS))
    return parser.parse_args()


def others(selected, target=0):
    return sorted(i for i in selected or [] if i != target)


def select_honest(row):
    """The condition was reproduced (row 0 selected with others), and the reply did not call that a
    verified selection: not State A, with `also_selected` naming the other rows."""
    selected = row.get("selected_after") or []
    reproduced = 0 in selected and bool(others(selected))
    named = sorted(row.get("also_selected") or []) == others(selected)
    return reproduced and row.get("reply_state") not in (None, "A") and named


def select_as_base(row):
    """The counterexample: what the merge-base binary answered, State A with nothing named."""
    return dict(row, reply_state="A", also_selected=None)


def renamed_rows(row):
    before, after = row.get("names_before") or [], row.get("names_after") or []
    if len(before) != len(after):
        return None
    return [i for i, (b, a) in enumerate(zip(before, after)) if b != a]


def names_read(row):
    """Every header row's name read, before and after, with the same row count and covering every
    selected row. A name that did not read is not an unchanged name (#1091 review R3, R1091-10)."""
    before, after = row.get("names_before"), row.get("names_after")
    selected = row.get("selected_before") or []
    return isinstance(before, list) and isinstance(after, list) and len(before) == len(after) \
        and bool(before) and all(isinstance(n, str) and n for n in before + after) \
        and max(selected, default=0) < len(before)


def rename_honest(row):
    """The condition was reproduced before the call, every name read, and no row but 0 changed
    name: row 0 alone renamed to the requested name with State A, or a State C
    selection_not_exclusive refusal with nothing renamed."""
    reproduced = 0 in (row.get("selected_before") or []) and bool(others(row.get("selected_before")))
    if not reproduced or not names_read(row):
        return False
    changed = renamed_rows(row)
    if row.get("reply_state") == "A":
        return changed == [0] and row["names_after"][0] == row.get("requested")
    return row.get("reply_state") == "C" and changed == [] and row.get("reply_error") == "selection_not_exclusive"


def rename_as_base(row):
    """The counterexample: row 0 renamed and every other selected row renamed with it, as Logic did
    for the merge-base binary (LPM-KDUP 55348 and 55349), answered State A."""
    after = list(row.get("names_after") or row.get("names_before") or [])
    for offset, index in enumerate([0] + others(row.get("selected_before"))):
        if index < len(after):
            after[index] = f"{row.get('requested')}" + ("" if offset == 0 else f" {offset + 1}")
    return dict(row, names_after=after, reply_state="A", reply_error=None)


def rail(ax):
    window = A.arrange_window(ax)
    if window is None:
        return None
    return next((e for e, _ in ax.walk(window, 12)
                 if A.matches(ax.value(e, "AXDescription"), "trackHeadersDescription")), None)


def name_of(ax, row):
    """The track name in the header's description, through the #1029 harness's reader, which knows
    each language's quotes (French « … » with spaces, Traditional Chinese 「」); None when it does not
    read (#1091 review R3, R1091-10)."""
    return P.quoted_name(ax.value(row, "AXDescription"))


def headers(ax):
    rows = A.track_header_rows(ax) or []
    return {"selected": [i for i, r in enumerate(rows) if ax.value(r, "AXSelected") is True],
            "names": [name_of(ax, r) for r in rows]}


def post_chord(keycode, flags):
    import Quartz
    mask = {"command": Quartz.kCGEventFlagMaskCommand, "option": Quartz.kCGEventFlagMaskAlternate}
    value = 0
    for part in flags.split("+"):
        value |= mask[part]
    pid = A.logic_pid()
    source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for down in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(source, keycode, down)
        Quartz.CGEventSetFlags(event, value)
        Quartz.CGEventPostToPid(pid, event)


def release_modifiers():
    import Quartz
    event = Quartz.CGEventCreate(None)
    Quartz.CGEventSetType(event, Quartz.kCGEventFlagsChanged)
    Quartz.CGEventSetFlags(event, 0)
    Quartz.CGEventPostToPid(A.logic_pid(), event)


def latch(ax):
    """Option-Command-S with no flagsChanged after it; returns the header reading after it."""
    A.activate_logic()
    A.focus_tracks(ax)
    post_chord(*OPTION_COMMAND_S)
    time.sleep(1.5)
    return headers(ax)


def select_trial(driver, ax, lproj):
    row = {"lproj": lproj, "trial": "select", "before": headers(ax)}
    row["after_chord"] = latch(ax)
    try:
        A.activate_logic()
        reply = driver.tool("logic_tracks", "select", {"index": 0}) or {}
        time.sleep(0.8)
        after = headers(ax)
        row.update({"selected_after": after["selected"], "reply": A.reply_summary(reply),
                    "reply_state": reply.get("state") if isinstance(reply, dict) else None,
                    "also_selected": reply.get("also_selected") if isinstance(reply, dict) else None})
    finally:
        release_modifiers()
        time.sleep(0.5)
    return row


def rename_trial(driver, ax, lproj):
    row = {"lproj": lproj, "trial": "rename", "requested": f"LPM1097 {int(time.time()) % 100000}"}
    row["after_chord"] = latch(ax)
    try:
        group = rail(ax)
        first = ax.children(group)[0] if group is not None else None
        row["set_selected_children"] = ax.set(group, "AXSelectedChildren", [first]) if first is not None else None
        time.sleep(0.6)
        before = headers(ax)
        row.update({"selected_before": before["selected"], "names_before": before["names"]})
        reply = driver.tool("logic_tracks", "rename", {"index": 0, "name": row["requested"]}) or {}
        time.sleep(1.0)
        after = headers(ax)
        row.update({"names_after": after["names"], "selected_after": after["selected"],
                    "reply": A.reply_summary(reply),
                    "reply_state": reply.get("state") if isinstance(reply, dict) else None,
                    "reply_error": reply.get("error") if isinstance(reply, dict) else None})
    finally:
        release_modifiers()
        time.sleep(0.5)
    return row


def restore_fixture(backup):
    census = L993.logic_census()
    if census["status"] != "gone":
        L993.quit_logic()
        census = L993.logic_census()
    if census["status"] != "gone":
        raise RuntimeError(f"Logic's process count read {census['raw']!r}, not 0; the fixture was not replaced")
    shutil.rmtree(L993.FIXTURE)
    subprocess.run(["/usr/bin/ditto", backup, L993.FIXTURE], check=True)


def main():
    args = arguments()
    E.REPO, E.BIN = args.worktree, args.binary
    sys.path.insert(0, os.path.join(args.worktree, "Scripts"))
    import logic_canon  # noqa: E402
    setattr(L993, "logic_canon", logic_canon)
    for key in ("LOGIC_MCP_DEBUG_ONLY_CHANNEL", "LOGIC_MCP_DEBUG_ONLY_CHANNEL_PASS"):
        os.environ.pop(key, None)
    ev = E.Evidence(args.head, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")
    carried = P.embedded_commit(args.binary)
    refusal = None if carried == args.head else (
        f"the binary carries {carried!r} in __TEXT,__lpm_commit, not the head {args.head}; nothing was driven")
    ev.note("1097/binary", {"binary": args.binary, "sha256": P.sha256_of(args.binary),
                            "embedded_commit": carried, "embedded_commit_is_head": refusal is None})
    if refusal is not None:
        sys.exit(refusal)
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
            ev.note(f"1097/{lproj}/launch", launch)
            if not launch.get("arrange_window"):
                rows.append({"lproj": lproj, "error": "launch"})
                continue
            A.ARRANGE["title"] = launch["arrange_window"]
            driver = E.Driver(binary=args.binary)
            try:
                time.sleep(5)
                for trial, check, base in ((select_trial, select_honest, select_as_base),
                                           (rename_trial, rename_honest, rename_as_base)):
                    row = trial(driver, ax, lproj)
                    rows.append(row)
                    ev.falsifiable(f"1097/{lproj}/{row['trial']}", check, row, base(row),
                                   expected="with another track still selected, no State A for select and no "
                                            "other track renamed")
                    print(json.dumps({k: row.get(k) for k in ("lproj", "trial", "selected_before", "selected_after",
                                                              "reply_state", "also_selected", "reply_error")},
                                     ensure_ascii=False), flush=True)
            finally:
                driver.close()
    finally:
        restored = False
        try:
            restore_fixture(backup)
            launch = L993.switch_to(L993.RESTORE, force=True)
            ev.note("1097/restore", launch)
            restored = bool(launch.get("arrange_window"))
        except Exception as exc:  # noqa: BLE001 - recorded as a failed restoration
            ev.note("1097/restore", {"error": repr(exc)})
        # A failed restoration counts against the run, not only as a note (#1091 review R3, R1091-11).
        ev.restored("1097/fixture-and-language", restored,
                    "the fixture put back from the copy and Logic relaunched in the restore language")
    ev.note("1097/rows", rows)
    out = ev.write()
    failed = [f"{r['lproj']} {r.get('trial')}" for r in rows
              if not (select_honest(r) if r.get("trial") == "select" else rename_honest(r))]
    print(json.dumps({"written": out, "rows": len(rows), "failed": failed, "restored": restored}, ensure_ascii=False))
    return 0 if restored and rows and not failed and len(rows) == 2 * len(args.lprojs) else 1


if __name__ == "__main__":
    sys.exit(main())
