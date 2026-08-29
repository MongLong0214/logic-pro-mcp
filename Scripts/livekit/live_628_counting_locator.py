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


def control_bar_description():
    """The description THIS Logic uses for the control bar, read off the element that was found."""
    band, subject = ev.located_band("Control Bar", "--min-width", "1000")
    return subject if band else None


def product_census_from(role, container):
    """The product's count taken from a NAMED container rather than from the window."""
    r = subprocess.run([E.BIN, "--probe-locator-census", role, "--probe-locator-from", container],
                       capture_output=True, text=True)
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


# `located_band` translates the name through `AX_REGION_LABELS`, so the English spelling reaches a
# Korean Logic's `트랙 헤더`. Before that table had the row, this returned None — and a band of None
# means the captures below have no settle region, which reads as `captures_unsettled` and
# `wholly_within: false` on a three-display machine. I called that an environmental wall and blamed
# blinking level meters; measured 2026-08-29, it was this lookup and nothing else.
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

# #628 states the refusal must NAME its candidates, not only count them. A count refuses; a name
# tells the person holding the refusal whether the tree is genuinely ambiguous or the selector is one
# word too broad. Measured on Logic 12.3: this is exactly where the issue started — TWO elements
# describe themselves "Control Bar", and until now nothing could say that from the outside.
named = button.get("candidateNames") or []
ev.check("628/an-ambiguous-census-names-its-candidates",
         isinstance(named, list) and len(named) == button.get("candidates"),
         "every candidate of the ambiguous lookup is named, so the refusal can be acted on — one "
         "name per candidate, counted against the census's own count rather than a fixed number",
         f"candidates={button.get('candidates')!r} names={len(named)} sample={named[:4]!r}",
         "drop `matches: hits` from the Census constructor: the list empties and this goes red")

# Emptiness is the failure mode the placeholder exists for. Aimed at GROUPS, not buttons: measured
# on Logic 12.3 the group census contains elements with no description at all, and the button one
# may not. A no-blank assertion over candidates that all happen to be named passes with the
# placeholder completely broken — it would be a check that cannot see its own subject.
group_census = product_census("AXGroup", depth=3)
group_named = group_census.get("candidateNames") or []
placeholder_fired = sum(1 for n in group_named if isinstance(n, str) and n.startswith("<unnamed"))

ev.check("628/the-unnamed-placeholder-is-exercised-on-this-tree",
         placeholder_fired > 0,
         "at least one live candidate has nothing to call itself, so the no-blank check below has a "
         "subject — without this it would pass on a tree where every element is named and say "
         "nothing about the fallback",
         f"candidates={group_census.get('candidates')!r} named={len(group_named)} "
         f"unnamed={placeholder_fired}", None)

ev.check("628/no-candidate-is-named-with-an-empty-string",
         bool(group_named) and all(isinstance(n, str) and n.strip() for n in group_named),
         "no name is blank on a census proven to contain unnamed elements: they report "
         "`<unnamed ROLE>`, which says what was found rather than looking like the reporter failed",
         f"blank={[i for i, n in enumerate(group_named) if not (isinstance(n, str) and n.strip())]!r} "
         f"unnamed={placeholder_fired} sample={group_named[:4]!r}",
         "return the raw description instead of the placeholder: unnamed elements become \"\" and "
         "this goes red")

absent = product_census("AXToolbar")
ev.check("628/zero-matches-are-not-identified-either",
         absent.get("candidates") == 0 and absent.get("identified") is False,
         "zero is reported as zero and is not mistaken for one — `getTransportBar` looks for a "
         "toolbar first and there is none on this Logic, so that branch is measured dead rather "
         "than assumed live",
         f"candidates={absent.get('candidates')!r} identified={absent.get('identified')!r}",
         "return `candidates: 1` for an empty hit list: this check goes red")

# ---- from a CONTAINER, because no call site searches the whole window ----------------------------
#
# The window-wide count answers a question nothing asks. `findTrackNameField` searches a track
# header; `getControlBar` searches the control bar. Deciding whether a site's candidate set has one
# member needs the count taken from ITS root, and a count from the wrong root is a confident number
# about a different question.
# The rail's description as THIS Logic renders it, read off the element the band lookup found.
# `--probe-locator-from` matches exactly, so the English spelling resolved no container and the
# probe reported zero candidates — which reads like a tree with nothing in it rather than like a
# lookup that missed.
scoped = product_census_from("AXTextField", RAIL_SUBJECT)
ev.check("628/a-count-can-be-taken-from-a-named-container",
         scoped.get("ok") is True and scoped.get("containerCandidates") == 1
         and isinstance(scoped.get("candidates"), int),
         "the probe resolves a container by description and counts inside it — the shape a call "
         "site actually has",
         f"from={scoped.get('from')!r} containerCandidates={scoped.get('containerCandidates')!r} "
         f"candidates={scoped.get('candidates')!r} identified={scoped.get('identified')!r}",
         "search from the window instead of the container: the count becomes the window-wide one "
         "and no longer describes the site")

# The container is resolved by the SAME counting rule, so an ambiguous container refuses instead of
# picking one and reporting a confident count taken from whichever it reached first. Measured:
# `Control Bar` matches two elements in the arrange window.
CONTROL_BAR_HERE = control_bar_description()
ambiguous = product_census_from("AXCheckBox", CONTROL_BAR_HERE)
ev.check("628/an-ambiguous-container-refuses-rather-than-choosing",
         ambiguous.get("ok") is False and ambiguous.get("containerCandidates", 0) > 1,
         "a container description matching more than one element produces a refusal naming the "
         "count, not a count taken from an arbitrary one of them",
         f"error={ambiguous.get('error')!r} containerCandidates={ambiguous.get('containerCandidates')!r}",
         "resolve the container with `findDescendant` instead of the census: the first match is "
         "taken, a count comes back, and this check goes red")

# `AXLocalePolicy.censusDescendant` is a SECOND producer of `Census` and nothing here covered its
# names. Dropping `matches: hits` from that function alone left every other check on this branch
# green — a second implementation of the same contract, uncovered.
container_named = ambiguous.get("containerCandidateNames") or []
ev.check("628/the-ambiguous-container-refusal-names-its-candidates",
         isinstance(container_named, list)
         and len(container_named) == ambiguous.get("containerCandidates")
         and all(isinstance(n, str) and n.strip() for n in container_named),
         "the container refusal says WHICH elements answered to that description, one name per "
         "candidate — the count alone cannot separate an ambiguous tree from too broad a selector",
         f"containerCandidates={ambiguous.get('containerCandidates')!r} "
         f"names={container_named!r}",
         "drop `matches: hits` from AXLocalePolicy.censusDescendant: the list empties and this "
         "goes red while every unit test stays green")

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

# ---- the survivor count of a real site's own predicate --------------------------------------------
#
# Counting by role answers "how many carry this role". The tail asks something else: how many
# survive the DISCRIMINATOR a call site applies. A site that gathers thirty-seven groups, narrows to
# four, and then takes the first has narrowed and still inherited tree order — which is this issue,
# at a real site, rather than in the abstract.
#
# The predicates are called by the product, not reimplemented here. A measurement that rewrites the
# rule can disagree with the code for a reason that has nothing to do with the tree.
selection = subprocess.run([E.BIN, "--probe-selection-census"], capture_output=True, text=True)
try:
    sites = json.loads(selection.stdout or "{}")
except ValueError:
    sites = {"ok": False, "raw": (selection.stdout or selection.stderr)[:200]}
ev.note("628/selection-census", sites)

all_rows = sites.get("sites") or []
# `unreachable` is a THIRD outcome, not a count of zero. A site whose input is not on screen has not
# been measured, and folding it in with the measured ones is how "we did not look" becomes "we
# looked and found none" — the failure this whole harness is built around. The first version of
# these checks did exactly that and went red the moment a site reported it, which is the check
# catching its own author.
rows = [r for r in all_rows if "survivors" in r]
unreachable = [r for r in all_rows if "unreachable" in r]
ev.note("628/unreachable-sites", unreachable)

ev.check("628/an-unmeasurable-site-says-so-instead-of-reporting-zero",
         all("gathered" not in r and "survivors" not in r and bool(r.get("unreachable"))
             for r in unreachable),
         "a site whose input is absent from this UI state carries a reason and NO counts — "
         "'no strip on screen' and 'the predicate left none' are different facts",
         f"unreachable={[r.get('unreachable') for r in unreachable]!r} measured={len(rows)}",
         "report `survivors: 0` for an unreachable site: it becomes indistinguishable from a "
         "discriminator that matched nothing, and this check goes red")

ev.check("628/a-site-predicate-reports-how-many-it-left",
         sites.get("ok") is True and len(rows) >= 2
         and all(isinstance(r.get("gathered"), int) and isinstance(r.get("survivors"), int)
                 for r in rows),
         "each site reports what it gathered and what its own discriminator left — the number the "
         "blind form never had",
         "; ".join(f"{r.get('site','?').split()[-1]}: {r.get('gathered')}->{r.get('survivors')}"
                   for r in rows),
         "have the probe report only the gathered count: `survivors` disappears and this goes red")

# A property of the REPORT, not of Logic: whatever the tree holds, `identified` has to mean exactly
# one. Asserting a specific survivor count would be asserting today's project, and it would go red
# when someone adds a track rather than when the code breaks.
ev.check("628/identified-means-exactly-one-whatever-the-tree-holds",
         bool(rows) and all(r.get("identified") == (r.get("survivors") == 1) for r in rows),
         "`identified` is true for a site if and only if its predicate left one candidate",
         "; ".join(f"{r.get('survivors')}->{r.get('identified')}" for r in rows),
         "report `identified: survivors > 0`: a site that narrowed to four claims identity and this "
         "check goes red")

# The narrowing itself has to be visible. A predicate that leaves everything it gathered is not a
# discriminator, and a run where that happened should say so rather than look the same as a good one.
ev.check("628/at-least-one-predicate-actually-narrows",
         any(r.get("survivors", 0) < r.get("gathered", 0) for r in rows),
         "at least one site's discriminator rejected something — otherwise the census is measuring "
         "a filter that filters nothing",
         "; ".join(f"{r.get('gathered')}->{r.get('survivors')}" for r in rows),
         "make both predicates return true for every element: nothing narrows and this goes red")

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
