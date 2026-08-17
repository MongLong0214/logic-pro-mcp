#!/usr/bin/env python3
"""Live proof for #549's observability change: when the sheet scan gives up, the receipt says where.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_549_receipt_names_the_node.py <worktree> <full-40-char-head-sha>

This harness deliberately does NOT assert that `track.create` reaches State A. That is #549's open
defect, it does not reproduce on demand, and this change does not fix it. Asserting it here would make a
green run look like a repair. What this change claims is narrower and is what is checked:

  1. adding the field did not break create or delete
  2. any receipt that reports an unreadable sheet-scan reason also names the node
  3. the named node carries no user-authored content

Check 2 is a universal claim over the receipts this run actually collects. If the intermittent failure
does not occur, it is vacuously true — so the run records HOW MANY receipts carried a reason, and the
document states that count rather than letting a green tick imply the path was exercised. A check that
was never exercised is reported as never exercised.

Instrument conditions: every value asserted comes from the operation's own envelope; the sheet count is
read through System Events, which the product does not use. No sampling and no time budget affects any
assertion.
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
d = E.Driver()
rec = None

OPERATIONS = 4  # create/delete pairs; more attempts, more chances the intermittent failure appears


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def sheet_count():
    return osa('tell application "System Events" to tell process "Logic Pro" to '
               'get count of every sheet of (first window whose name ends with "Tracks")')


def tracks():
    d.tool("logic_tracks", "select", {"index": 0})
    return d.resource("logic://tracks").get("data", []) or []


win = E.logic_window()
if not win:
    ev.check("549/precondition-logic-window", False, "Logic's Tracks window is on screen",
             "no window found", "closed the Tracks window; this check went red")
    d.close(); print(json.dumps(ev.write(), indent=1)); sys.exit(1)

RAIL = (0, int(win["h"] * 0.10), int(win["w"] * 0.20), int(win["h"] * 0.80))

before = tracks()
ev.note("precondition", {"tracks": len(before), "sheets": sheet_count()})

rec = ev.record_screen(seconds=110)
pre = ev.shot("before-operations", settle_region=RAIL)

receipts = []
created = 0
deleted = 0
for i in range(OPERATIONS):
    n_before = len(tracks())
    body = d.tool("logic_tracks", "create_instrument")
    time.sleep(1.6)
    receipts.append(("create", body))
    if len(tracks()) == n_before + 1:
        created += 1

    t = tracks()
    if len(t) > 2:
        target = t[-1]
        unique = f"ZZ549obs {i}"
        d.tool("logic_tracks", "rename", {"index": target["id"], "name": unique})
        time.sleep(0.8)
        n_before = len(tracks())
        body = d.tool("logic_tracks", "delete", {"index": target["id"], "expected_name": unique})
        time.sleep(1.4)
        receipts.append(("delete", body))
        if len(tracks()) == n_before - 1:
            deleted += 1

# The operations above are balanced — each create is matched by a delete — so the header rail ends up
# pixel-identical to how it started and a "did the rail change" assertion is false against a run that
# plainly worked. Leave one extra track standing for the visual comparison, then remove it.
d.tool("logic_tracks", "create_instrument")
time.sleep(1.6)
post = ev.shot("after-operations", settle_region=RAIL)

# ---- 1. the field did not break the operations ----
ev.check("549/operations-still-work",
         created == OPERATIONS and deleted >= 1,
         "every create still adds a track and delete still removes one",
         f"creates_landed={created}/{OPERATIONS} deletes_landed={deleted}",
         "threaded the new detail through a code path that also carried a return value, and the "
         "operation stopped performing its write")

ev.check("549/no-blocker-left-behind",
         sheet_count() == "0",
         "System Events, a path the product does not use, reports no sheet remains",
         f"sheets_after={sheet_count()!r}",
         "left a sheet up; this independent read said 1 with Logic waiting on a human")

# ---- 2. every receipt that reports an unreadable reason names the node ----
#
# Universal over the receipts collected. Vacuous if the intermittent failure did not appear, so the
# observed string always states how many receipts actually carried a reason.
with_reason = [(op, b) for op, b in receipts
               if isinstance(b, dict) and b.get("reconciled_modal_unreadable_reason")]
# `unrecorded` is the marker for "a failure arrived with no node", so counting it as "named" would let
# the check pass on exactly the receipts it exists to catch.
def names_a_node(body):
    node = body.get("reconciled_modal_unreadable_node")
    return isinstance(node, dict) and node.get("site") != "unrecorded"


named = [(op, b) for op, b in with_reason if names_a_node(b)]
exercised = len(with_reason) > 0

ev.check("549/an-unreadable-reason-always-names-its-node",
         len(named) == len(with_reason),
         "no receipt reports an unreadable sheet scan without saying which node it gave up on",
         f"receipts={len(receipts)} with_reason={len(with_reason)} named={len(named)} "
         f"exercised={exercised}"
         + ("" if exercised else "  <- the intermittent failure did not occur; this run does not "
                                 "exercise the field, and says so"),
         "dropped the else-branch that marks a missing detail as unrecorded; a receipt reported a "
         "sheet-scan failure with no node and the omission was indistinguishable from 'no node'")

# ---- 3. the node names structure only ----
sentinel_sources = [t.get("name") for t in tracks() if t.get("name")]
leaked = []
for op, b in named:
    blob = json.dumps(b.get("reconciled_modal_unreadable_node"), ensure_ascii=False)
    for name in sentinel_sources:
        if name and name in blob:
            leaked.append((op, name))

ev.check("549/the-node-carries-no-user-content",
         not leaked,
         "the node names roles and ordinal indices only — no track name reaches the receipt",
         f"named_receipts={len(named)} candidate_strings={len(sentinel_sources)} leaked={leaked}",
         "published the node's AXDescription as its role; a live track name appeared in the receipt "
         "and the check caught it")

ev.visual("549/the-track-rail-changes",
          pre["file"], post["file"], RAIL, expect_change=True,
          why="one extra track is standing at this point, so the header rail must differ")

# remove the extra track left standing for the visual
t = tracks()
if len(t) > len(before):
    last = t[-1]
    d.tool("logic_tracks", "rename", {"index": last["id"], "name": "ZZ549obs visual"})
    time.sleep(0.8)
    d.tool("logic_tracks", "delete", {"index": last["id"], "expected_name": "ZZ549obs visual"})
    time.sleep(1.4)

after = tracks()
ev.restored("549/track-count-returned-to-start", len(after) == len(before),
            f"before={len(before)} after={len(after)}")

d.close()
ev.stop_recording(rec)
print(json.dumps(ev.write(), indent=1))
