#!/usr/bin/env python3
"""Live proof for navigate.delete_marker (#523) against the running Logic Pro.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_523_marker_delete.py <worktree> <full-40-char-head-sha>

The thing under test is not "did a marker disappear" — it is whether the receipt is entitled to say so.

`AXRows`, `AXChildren` and `AXSelectedRows` are three properties of one `AXTable`. When Logic rebuilds that
table after a delete they can all omit the same row for the same reason, so their agreement is not
corroboration and a bound row no longer matching the selection is satisfied by the rebuild rather than by
the deletion. A State A built on those alone was reachable with no marker deleted at all.

The independent witness is Logic's own count: an `AXStaticText` described "Number of Items" in the Marker
List, reading "2 Markers" / "1 Marker". It is not a projection of the table, so a false State A now needs
two unrelated surfaces to lie in the same direction at the same moment. This harness checks both halves,
and reads the witness itself through System Events — a path the product does not use — so the check is not
a mirror of the thing it is checking.
"""

import json
import os
import re
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


def logic_item_count():
    """Logic's own count, read independently of the product."""
    script = ('tell application "System Events" to tell process "Logic Pro"\n'
              'set g to (first group of (first window whose name ends with "Marker List") '
              'whose description is "Marker")\n'
              'repeat with k in (every UI element of g)\n'
              'try\n'
              'if (description of contents of k) is "Number of Items" then return '
              '(value of contents of k) as text\n'
              'end try\n'
              'end repeat\n'
              'return "ABSENT"\n'
              'end tell')
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def count_band(win):
    """`(band, subject)` for the witness element, in window points, measured rather than guessed.

    A region picked by eye is a guess about layout that silently stops being true — this one was
    guessed at the top of the window and the node is actually near the bottom, so the assertion
    compared two identical wrong crops and read as "nothing changed" on a run that plainly worked.
    Ask the element where it is.

    The subject comes back off the element that was found, not off the string this walk searched
    for. The two are the same today; they stop being the same the moment the walk matches
    something else, and only the read-back one would say so.
    """
    script = ('tell application "System Events" to tell process "Logic Pro"\n'
              'set w to (first window whose name ends with "Marker List")\n'
              'set wp to position of w\n'
              'set g to (first group of w whose description is "Marker")\n'
              'repeat with k in (every UI element of g)\n'
              'try\n'
              'if (description of contents of k) is "Number of Items" then\n'
              'set p to position of contents of k\n'
              'set sz to size of contents of k\n'
              'return (((item 1 of p) - (item 1 of wp)) as text) & "," '
              '& (((item 2 of p) - (item 2 of wp)) as text) & "," '
              '& ((item 1 of sz) as text) & "," & ((item 2 of sz) as text) & "," '
              '& (description of contents of k)\n'
              'end if\n'
              'end try\n'
              'end repeat\n'
              'return "ABSENT"\n'
              'end tell')
    # `as text` on every number, because `integer & ","` in AppleScript builds a LIST rather than a
    # string: osascript rendered `298, ,, 716, ,, 146, ,, 25` and the parser below saw ten fields,
    # not four. It returned None on every run and the caller quietly used its guessed rectangle —
    # a measurement that never once ran, wearing the shape of one that did.
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    parts = (r.stdout or "").strip().split(",")
    if len(parts) != 5:
        return None, None
    try:
        x, y, w, h = (int(v) for v in parts[:4])
    except ValueError:
        return None, None
    subject = parts[4].strip()
    if not subject:
        return None, None
    # A little margin so anti-aliasing at the edges cannot decide the verdict.
    return (max(0, x - 4), max(0, y - 4), w + 8, h + 8), subject


def count_of(text):
    m = re.match(r"\s*(\d+)", text or "")
    return int(m.group(1)) if m else None


ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])
d = E.Driver()

win = E.logic_window("Marker List")
if not win:
    ev.check("523/precondition-marker-list-window", False,
             "Logic's Marker List window is on screen", "no window found",
             "closed the Marker List; this check went red")
    d.close(); print(json.dumps(ev.write(), indent=1)); sys.exit(1)

# The witness element's own rectangle, so the visual assertion is about the thing the verdict rests on
# rather than about the window in general.
#
# The fallback that stood here — the bottom tenth of the window — was the failure mode this
# function exists to remove, reinstated for the case where the function fails. A rectangle nobody
# located cannot be named, and an unnamed band is what #622 is about. A failed lookup is red.
COUNT_BAND, COUNT_SUBJECT = count_band(win)
ev.check("523/precondition-the-count-readout-was-located",
         COUNT_BAND is not None and bool(COUNT_SUBJECT),
         "the Number of Items readout, located by asking the element where it is",
         f"band={COUNT_BAND!r} subject={COUNT_SUBJECT!r}", None)
if COUNT_BAND is None:
    d.close(); print(json.dumps(ev.write(), indent=1)); sys.exit(1)

# ---- precondition: at least two markers, so a delete leaves something behind ----
while (count_of(logic_item_count()) or 0) < 2:
    d.tool("logic_navigate", "create_marker")
    time.sleep(0.8)

before_text = logic_item_count()
before_n = count_of(before_text)
ev.note("precondition", {"item_count_text": before_text})

rec = ev.record_screen(seconds=45)
pre = ev.shot("before-delete", settle_region=COUNT_BAND, window_title="Marker List")

body = d.tool("logic_navigate", "delete_marker", {"index": 0})
time.sleep(1.5)
post = ev.shot("after-delete", settle_region=COUNT_BAND, window_title="Marker List")
after_text = logic_item_count()
after_n = count_of(after_text)
ev.note("response", {"body": body, "item_count_after": after_text})

ev.check("523/logic-own-count-drops-by-exactly-one",
         before_n is not None and after_n == before_n - 1,
         "Logic's own Number of Items readout drops by exactly one",
         f"before={before_text!r} after={after_text!r}",
         "made AXPick a no-op; this count did not move while the table's projections still claimed the "
         "row had gone")

ev.check("523/the-delete-is-verified-not-merely-attempted",
         body.get("state") == "A" and body.get("verified") is True,
         "the receipt reaches State A because two unrelated surfaces agree",
         f"state={body.get('state')!r} verified={body.get('verified')!r} "
         f"reason={body.get('reason')!r}",
         "required only the table's own projections; State A became reachable with nothing deleted")

ev.check("523/the-count-witness-was-actually-read",
         body.get("item_count_witness_state") == "readable"
         and body.get("observed_marker_count_before") is not None
         and body.get("observed_marker_count_after") is not None,
         "both count readings are published, not inferred",
         f"witness={body.get('item_count_witness_state')!r} "
         f"before={body.get('observed_marker_count_before')!r} "
         f"after={body.get('observed_marker_count_after')!r}",
         "let an unparseable witness stand in as zero; State A survived a witness nobody could read")

ev.check("523/the-product-and-an-independent-read-agree",
         body.get("observed_marker_count_after") == after_n,
         "the count the product reports matches the one read through System Events",
         f"product={body.get('observed_marker_count_after')!r} independent={after_n!r}",
         "reported the expected count instead of the observed one; the two reads diverged")

ev.visual("523/the-count-readout-changes",
          pre["file"], post["file"], COUNT_BAND, subject=COUNT_SUBJECT, expect_change=True,
          why=f"the marker count went {before_text!r} to {after_text!r}, so the readout must repaint")

ev.restored("523/markers-remain-for-the-next-run", (after_n or 0) >= 1,
            f"item_count_after={after_text!r}")

d.close()
ev.stop_recording(rec)
# #622: this harness printed its summary and exited 0 whatever the summary said. Twenty-three of
# its siblings already ended on `is_clean`, and nine did not, for no reason anyone had written
# down — so a clause added to `is_clean` was enforced for some runs and decorative for others.
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
