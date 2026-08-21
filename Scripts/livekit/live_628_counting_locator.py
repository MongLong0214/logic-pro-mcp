#!/usr/bin/env python3
"""Live proof that the counting locator counts Logic's real tree, not one a test built.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_628_counting_locator.py <worktree> <full-40-char-head-sha>

WHAT #628 IS ABOUT
------------------
`AXHelpers.findDescendant` returns the first match in traversal order and says nothing about the
rest. When it is right, nothing records that it was right for a reason rather than by luck — and
that silence is the defect, not the choosing. `censusDescendant` is the counting form: it returns an
element only when exactly one matched, and it reports how many there were either way.

WHY A UNIT TEST IS NOT ENOUGH, AND WHY THIS IS NOT SELF-ATTESTATION
-------------------------------------------------------------------
The unit tests build their own tree, so they prove the rule and nothing about Logic. The obvious
live check — run the product's census and assert it returns a number — cannot fail: any number
satisfies it, and the only thing that could contradict the product is the product.

So the count is checked against `ax_role_count.swift`, a separate walk that shares no code with the
product. Both are aimed at the SAME subtree (Logic's main window) at the same depth, matched on
ROLE alone. Role, because it is the one criterion an outside instrument can reproduce without
reading the product's locale tables — matching on a LabelSet would have the two agreeing about a
shared input, which is not corroboration.

WHAT THIS CANNOT RULE OUT
-------------------------
Both walkers call `AXUIElementCopyAttributeValue`. A defect in the AX API itself, or in how some
subtree answers `AXChildren`, moves both numbers together and this would not see it. What it does
rule out is a defect in either walk — depth handling, whether a match is descended into, filtering —
which is where the counting rule actually lives.

The depth check is the half that makes the agreement mean something. Two walks that both ignored
`maxDepth` would agree perfectly and be wrong together, so the run also requires the count to CHANGE
with depth, in the same direction, on both instruments.
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

# Roles chosen to span the shapes the walk can get wrong: many matches, few, nested containers, and
# one that is absent. AXToolbar is the absent one and it is not filler — `getTransportBar` looks for
# a toolbar first, and measuring zero is what says that branch is dead on this Logic rather than
# merely unexercised.
ROLES = ["AXButton", "AXTextField", "AXStaticText", "AXGroup", "AXToolbar"]

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])
rec = ev.record_screen(seconds=60)
d = E.Driver()

COUNTER_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_role_count.swift")
COUNTER = os.path.join(ev.dir, "ax_role_count")
built = subprocess.run(["swiftc", "-O", COUNTER_SOURCE, "-o", COUNTER], capture_output=True)
ev.check("628/precondition-the-independent-counter-built",
         built.returncode == 0,
         "the second opinion compiles — without it every comparison below is the product agreeing "
         "with itself",
         f"rc={built.returncode} stderr={(built.stderr or b'').decode()[:200]!r}", None)
if built.returncode != 0:
    d.close(); ev.stop_recording(rec)
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)


def product_census(role, depth=None):
    """The product's own count, from the release artifact the gate hashes."""
    args = [E.BIN, "--probe-locator-census", role]
    if depth is not None:
        args += ["--probe-locator-depth", str(depth)]
    r = subprocess.run(args, capture_output=True, text=True)
    try:
        return json.loads(r.stdout or "{}")
    except ValueError:
        return {"ok": False, "raw": (r.stdout or r.stderr)[:200]}


def independent_count(role, depth=None):
    args = [COUNTER, role]
    if depth is not None:
        args += ["--max-depth", str(depth)]
    r = subprocess.run(args, capture_output=True, text=True)
    try:
        return json.loads(r.stdout or "{}")
    except ValueError:
        return {"ok": False, "raw": (r.stdout or r.stderr)[:200]}


RAIL, RAIL_SUBJECT = ev.located_band("Tracks header")
ev.check("628/precondition-the-track-header-rail-was-located",
         RAIL is not None and bool(RAIL_SUBJECT),
         "the band this run asserts about, located by the AXDescription it carries",
         f"band={RAIL!r} subject={RAIL_SUBJECT!r}", None)

before = ev.shot("628/before-counting", settle_region=RAIL)

# One driven read, so the run is on record as having touched the product over the wire rather than
# only having run its own binary with a flag. `health` writes nothing.
health = d.tool("logic_system", "health", {})
ev.check("628/the-server-answers-over-the-wire",
         isinstance(health, dict) and bool(health),
         "an ordinary MCP read succeeds, so the artifact under test is the one serving requests",
         f"keys={sorted(health)[:6] if isinstance(health, dict) else health!r}",
         None)

# ---- the comparison ------------------------------------------------------------------------------
agreements = {}
for role in ROLES:
    mine = product_census(role)
    theirs = independent_count(role)
    ok = (mine.get("ok") and theirs.get("ok")
          and isinstance(mine.get("candidates"), int)
          and mine["candidates"] == theirs.get("count"))
    agreements[role] = {"product": mine.get("candidates"), "independent": theirs.get("count")}
    ev.check(f"628/{role}-count-agrees-with-an-instrument-that-is-not-the-product",
             bool(ok),
             f"`censusDescendant` and a separate walk of the same subtree report the same number of "
             f"{role} descendants",
             f"product={mine.get('candidates')!r} independent={theirs.get('count')!r} "
             f"raw={mine if not ok else ''}",
             "make `collectMatching` skip descending into a match (add `continue` after the "
             "append): nested matches stop being counted, the product's number falls below the "
             "independent walk's, and every role with nesting goes red")
ev.note("628/counts", agreements)

# `identified` is the fact the blind lookup cannot report. It must be true at exactly one match and
# false otherwise — including false at 50, where `findDescendant` would happily return something.
button = product_census("AXButton")
ev.check("628/many-matches-are-not-identified",
         button.get("candidates", 0) > 1 and button.get("identified") is False
         and button.get("returnedElement") is False,
         "with more than one match the census returns NO element and says so — the blind lookup "
         "returns one and reports the same thing it reports at a single match",
         f"candidates={button.get('candidates')!r} identified={button.get('identified')!r} "
         f"returnedElement={button.get('returnedElement')!r}",
         "restore `element: hits.first`: an element comes back for an ambiguous lookup and this "
         "check goes red")

absent = product_census("AXToolbar")
ev.check("628/zero-matches-are-not-identified-either",
         absent.get("candidates") == 0 and absent.get("identified") is False,
         "zero is reported as zero and is not mistaken for one — `getTransportBar` looks for a "
         "toolbar first and there is none on this Logic, so that branch is measured dead rather "
         "than assumed live",
         f"candidates={absent.get('candidates')!r} identified={absent.get('identified')!r}",
         "return `candidates: 1` for an empty hit list: this check goes red")

# ---- depth, so that agreeing is not the same as both ignoring the bound ---------------------------
shallow_p = product_census("AXGroup", depth=1)
shallow_i = independent_count("AXGroup", depth=1)
deep_p = product_census("AXGroup", depth=10)
ev.check("628/the-depth-bound-is-honoured-live-by-both-walks",
         (isinstance(shallow_p.get("candidates"), int)
          and shallow_p["candidates"] == shallow_i.get("count")
          and shallow_p["candidates"] < deep_p.get("candidates", 0)),
         "a shallower search finds strictly fewer, and both instruments report the same shallower "
         "number — two walks that ignored maxDepth would agree perfectly and be wrong together",
         f"depth1 product={shallow_p.get('candidates')!r} independent={shallow_i.get('count')!r} "
         f"depth10 product={deep_p.get('candidates')!r}",
         "drop the `guard maxDepth > 0` from `collectMatching`: the shallow count stops differing "
         "from the deep one and this check goes red")

after = ev.shot("628/after-counting", settle_region=RAIL)
ev.visual("628/counting-changed-nothing-on-screen",
          before["file"], after["file"], RAIL, subject=RAIL_SUBJECT, expect_change=False,
          why="every call in this run is a read — a census probe and one MCP health read — so the "
              "track-header rail must come back byte-identical. A probe that moved the UI would be "
              "an actuator wearing the word observe")

d.close()
ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
