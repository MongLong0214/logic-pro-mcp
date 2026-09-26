#!/usr/bin/env python3
"""Live proof that `logic_mixer bank` decides a bank move from the LCD upper row Logic redraws (#862).

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_862_bank_answers_from_the_redrawn_upper_row.py <worktree> <full-40-char-head-sha> [binary]

`binary` defaults to `<worktree>/.build/release/LogicProMCP`. Pass a copy at a fresh path when the
build directory may be serving a stale image.

WHAT THE PRODUCT CLAIMS
-----------------------
The MCU protocol carries no bank offset. What Logic does send after a bank press is the eight
six-character names of the strips now under the surface, on the LCD upper row. So `mixer.bank`
answers State A only when a NEW upper row arrived after the press, went quiet, and differs from the
row it held before; an identical redraw is State B `noop_unobservable`, no redraw is State B
`echo_timeout`, and a server that never received an upper row refuses before sending anything.

WHAT THIS MEASURES
------------------
Each reply is read whole. The claim a reader needs is that State A is never granted to a press
whose window did not change, and that the one move with no window to reach -- left at bank 0 --
is not State A. Both are properties of the REPLY, so the reading is the replies themselves.

The independent witness is the track list Logic answers through Accessibility, which is not the
path the bank decision reads: after a move from bank 0 to bank 1, the eight LCD names must be
abbreviations of tracks 9-16 (the first letter, then letters of the name in order), not of tracks
1-8. The comparison is recorded, not assumed: if Logic abbreviates a name some other way, the check
shows it.

It also watches the row after each reply. Measured 2026-09-26: a press sent without its release
leaves the button held in Logic, and held Bank Left and Bank Right auto-repeat against each other, so
the row kept flipping between two windows every ~30 ms for seconds after the reply. The poll that
decides the reply can land on either phase, so a flipping row has to be read directly.

WHAT THIS DOES NOT MEASURE
--------------------------
The count is checked once: count 2 from bank 0 must land on the window two single presses from bank
0 reached. Measured 2026-09-27: two presses sent back to back moved Logic one bank. Larger counts are
not driven. It does not bind a strip index to a channel; that is the rest of #862.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


COVERS = [
    "Sources/LogicProMCP/Channels/MCUChannel.swift",
    "Sources/LogicProMCP/Dispatchers/MixerDispatcher.swift",
    "Sources/LogicProMCP/State/StateCache.swift",
]

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = sys.argv[3] if len(sys.argv) > 3 else f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="non_ui")


def mcu_state(d):
    raw = d.resource("logic://mcu/state") or {}
    conn = raw.get("connection") or {}
    disp = raw.get("display") or {}
    return {
        "isConnected": conn.get("isConnected"),
        "registeredAsDevice": conn.get("registeredAsDevice"),
        "upperRow": disp.get("upperRow"),
    }


def bank(d, label, params):
    body = d.tool("logic_mixer", "bank", params) or {}
    ev.note(f"862/{label}", body)
    time.sleep(0.5)
    return body


def row_changes_after(d, seconds=1.5, interval=0.02):
    """Every distinct upper row seen in `seconds` after a reply, in order, starting with the first."""
    seen = []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        row = mcu_state(d)["upperRow"]
        if not seen or seen[-1] != row:
            seen.append(row)
        time.sleep(interval)
    return seen


def track_names(d):
    d.tool("logic_system", "refresh_cache")
    tracks = d.resource("logic://tracks") or {}
    rows = sorted((r for r in (tracks.get("data") or []) if isinstance(r.get("id"), int)),
                  key=lambda r: r["id"])
    return {"readable": tracks.get("readable"), "source": tracks.get("source"),
            "names": [r.get("name") or "" for r in rows]}


def squash(text):
    return "".join((text or "").split()).lower()


def abbreviates(cell, name):
    """Whether `cell` is `name` with letters dropped: same first letter, the rest in order.

    Measured 2026-09-27: Logic squeezes a name into six characters by dropping letters, not by
    cutting it -- "Deluxe Classic" is `DelCls`, "Studio Grand" is `StdGrn`. A prefix test misses
    every one of those.
    """
    c, n = squash(cell), squash(name)
    if not c or not n or c[0] != n[0]:
        return False
    rest = iter(n[1:])
    return all(ch in rest for ch in c[1:])


def lcd_names_abbreviate_tracks(lcd, names):
    """How many non-empty LCD cells abbreviate the track name at the same slot."""
    pairs = [(c, n) for c, n in zip(lcd, names) if c]
    hits = sum(1 for c, n in pairs if abbreviates(c, n))
    return {"cells": len(pairs), "abbrev_hits": hits}


d = E.Driver()
# Logic answers the device query within a second on a bound surface; the extra time is for the
# LCD, meter and fader burst that follows it.
time.sleep(8)

start = mcu_state(d)
ev.note("862/mcu-state-at-start", start)

# The refusal that must precede any byte can only be read on a server that has not received an
# upper row. On a host whose surface is already bound the row arrives during start-up, so this
# branch records that it could not be exercised rather than pretending it was.
pre = None
if not start["isConnected"] or not (start["upperRow"] or "").strip():
    pre = bank(d, "bank-right-before-any-upper-row", {"direction": "right"})
    ev.check("862/no-upper-row-refuses-before-sending",
             pre.get("state") == "C" and pre.get("bank_presses_sent") is None,
             "State C with no bank press sent, before the surface ever drew an upper row",
             {k: pre.get(k) for k in ("state", "error", "write_attempted", "bank_presses_sent")},
             "remove the `before.sequence > 0` guard in MCUChannel.executeBank")
    setup = d.tool("logic_system", "setup_control_surface", {"consent": True}) or {}
    ev.note("862/setup-control-surface", setup)
    time.sleep(8)
    start = mcu_state(d)
    ev.note("862/mcu-state-after-setup", start)
else:
    ev.note("862/pre-upper-row-refusal-not-exercisable", {
        "why": "the surface was already bound and the upper row arrived during start-up"})

census = track_names(d)
ev.note("862/track-census", {"readable": census["readable"], "source": census["source"],
                             "count": len(census["names"])})
names = census["names"]

# Walk to bank 0 first, bounded: the run's comparisons are against a known starting window.
walk = []
for _ in range(6):
    body = bank(d, f"walk-left-{len(walk)}", {"direction": "left"})
    walk.append(body.get("state"))
    if body.get("state") != "A":
        break
edge_left = bank(d, "left-at-bank-0", {"direction": "left"})
right1 = bank(d, "right-from-bank-0", {"direction": "right"})
held = row_changes_after(d)
ev.check("862/the-window-holds-still-after-the-reply",
         right1.get("state") == "A" and len(held) == 1 and held[0] == right1.get("window_after"),
         "after one bank right from bank 0 answered State A, the upper row reads the reply's window_after "
         "on every 20 ms poll for 1.5 s",
         {"state": right1.get("state"), "window_after": right1.get("window_after"),
          "rows_seen_in_order": held[:12], "distinct_changes": len(held) - 1},
         "send the bank press without its release in MCUChannel's press helper: Logic then holds "
         "both bank buttons and the row flips between two windows")
right2 = bank(d, "right-again", {"direction": "right"})
left1 = bank(d, "left-back", {"direction": "left"})
left0 = bank(d, "left-to-bank-0", {"direction": "left"})
count2 = bank(d, "right-count-2", {"direction": "right", "count": 2})

replies = {"left-at-bank-0": edge_left, "right-from-bank-0": right1, "right-again": right2,
           "left-back": left1, "left-to-bank-0": left0, "right-count-2": count2}


def summary(body):
    return {k: body.get(k) for k in ("state", "reason", "error", "window_before", "window_after",
                                     "strips", "bank_presses_sent", "upper_row_writes_observed",
                                     "bank_bookkeeping_before", "bank_bookkeeping_after")}


reading = {
    "walk_states": walk,
    "replies": {k: summary(v) for k, v in replies.items()},
    "a_replies_with_an_unchanged_window": sorted(
        k for k, v in replies.items()
        if v.get("state") == "A" and v.get("window_before") == v.get("window_after")),
    "a_replies_without_eight_strips": sorted(
        k for k, v in replies.items()
        if v.get("state") == "A" and len(v.get("strips") or []) != 8),
    "edge_left_state": edge_left.get("state"),
    "edge_left_reason": edge_left.get("reason"),
    "a_reply_count": sum(1 for v in replies.values() if v.get("state") == "A"),
}

ev.falsifiable(
    "862/state-a-only-when-the-redrawn-window-changed",
    lambda o: (o["a_reply_count"] >= 1
               and not o["a_replies_with_an_unchanged_window"]
               and not o["a_replies_without_eight_strips"]
               and o["edge_left_state"] == "B"),
    reading,
    {**reading, "a_replies_with_an_unchanged_window": ["left-at-bank-0"],
     "edge_left_state": "A", "edge_left_reason": None},
    "at least one move was State A; every State A reply carries a window_after that differs from "
    "window_before and eight strip names; and the one press with no window to reach -- left at bank "
    "0 -- is State B. THE COUNTEREXAMPLE is the press-is-success shape: left at bank 0 reported as "
    "State A with its window unchanged, which is what a receipt built from the press would say",
    mutation="drop the `after.row != before.row` guard in MCUChannel.executeBank",
)

# Count 2 from bank 0 must land where two single presses from bank 0 landed. Measured 2026-09-27 on
# a48a5cb5: two presses sent back to back moved Logic one bank, and the reply still said State A.
two_presses = {
    "count2_state": count2.get("state"),
    "count2_banks_moved": count2.get("banks_moved"),
    "count2_window_after": count2.get("window_after"),
    "window_two_single_presses_reached": right2.get("window_after"),
    "window_one_press_reached": right1.get("window_after"),
}
ev.falsifiable(
    "862/count-2-lands-where-two-single-presses-land",
    lambda o: (o["count2_state"] == "A"
               and o["count2_window_after"] == o["window_two_single_presses_reached"]
               and o["count2_window_after"] != o["window_one_press_reached"]),
    two_presses,
    {**two_presses, "count2_window_after": two_presses["window_one_press_reached"]},
    "count 2 from bank 0 answers State A only with the window two separate single presses from bank 0 "
    "reached, not the window one press reached. THE COUNTEREXAMPLE is the a48a5cb5 reading: State A "
    "with the one-press window",
    mutation="send all count presses back to back and poll once, as a48a5cb5 did",
)

# The independent witness: Logic's own track list through Accessibility, not the LCD path.
if right1.get("state") == "A" and len(names) > 8:
    lcd = right1.get("strips") or []
    at_bank1 = lcd_names_abbreviate_tracks(lcd, names[8:16])
    at_bank0 = lcd_names_abbreviate_tracks(lcd, names[0:8])
    ev.check("862/the-window-after-one-right-is-tracks-9-to-16",
             at_bank1["cells"] > 0 and at_bank1["abbrev_hits"] == at_bank1["cells"]
             and at_bank0["abbrev_hits"] < at_bank0["cells"],
             "every named LCD cell after one bank right abbreviates the name of the track in the same "
             "slot of tracks 9-16, and not every one abbreviates tracks 1-8",
             {"lcd": lcd, "tracks_9_16": names[8:16], "tracks_1_8": names[0:8],
              "against_bank1": at_bank1, "against_bank0": at_bank0},
             "have Logic's bank press ignored: the row stays on tracks 1-8")
else:
    ev.note("862/independent-witness-not-exercisable", {
        "right1_state": right1.get("state"), "track_count": len(names)})

# Put the window back at bank 0, bounded.
back = []
for _ in range(6):
    body = bank(d, f"restore-left-{len(back)}", {"direction": "left"})
    back.append(body.get("state"))
    if body.get("state") != "A":
        break
# Back at bank 0 means the row reads what it read at bank 0, not merely that the last press was refused:
# a press Logic ignored is State B too.
bank0_row = edge_left.get("window_after")
final_row = mcu_state(d)["upperRow"]
ev.restored("862/window-back-at-bank-0",
            bool(back) and back[-1] == "B" and bool(bank0_row) and final_row == bank0_row,
            json.dumps({"states": back, "bank0_row": bank0_row, "final_row": final_row}))

d.close()
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
