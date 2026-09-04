#!/usr/bin/env python3
"""Cases for `check-livekit-ui-literals.py` — the rule that a live harness must not aim at Logic's
UI with a string only one language spells that way.

These are the three controls that were run by hand when the guard was written, committed so they
run every time instead of once. A guard nobody has watched fail is a guard nobody knows the shape
of: six times on 2026-09-04 a rule in this repository turned out to enforce something narrower than
its own docstring claimed, and each was found by a defect slipping past rather than by a test.

The cases drive `offenders()` against a temporary directory, so they do not move when the
repository gains or loses a harness — that count is what `KNOWN` tracks, and a test that read it
too would drift with it.
"""
import importlib.util
import os
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "livekit_ui_literals", os.path.join(REPO, "Scripts", "check-livekit-ui-literals.py"))
G = importlib.util.module_from_spec(spec)
spec.loader.exec_module(G)

failed = 0
tmp = tempfile.mkdtemp()


def case(name, condition, detail):
    global failed
    failed += 0 if condition else 1
    print(f"{'ok  ' if condition else 'FAIL'} {name} -> {detail}")


def harness(filename, body):
    path = os.path.join(tmp, filename)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    return path


def scan(body, canonicals, filename="live_case.py"):
    harness(filename, body)
    original = G.LIVEKIT
    G.LIVEKIT = tmp
    try:
        return G.offenders(canonicals)
    finally:
        G.LIVEKIT = original
        os.remove(os.path.join(tmp, filename))


CANONICALS = {"mixer": "mixerNamedElement", "tracks": "arrangeWindowTitleSuffix"}

# 1. A bare English literal in a UI-matching position is the defect.
found = scan('CLICK = \'click menu bar item "Mixer" of menu bar 1\'\n', CANONICALS)
case("a bare UI literal the policy knows is localised is flagged",
     [f[1] for f in found] == ["Mixer"], f"found={[(f[1], f[3]) for f in found]!r}")

# 2. Interpolating the spelling from a table is the fix, and it leaves nothing to flag. There is no
#    exemption to test, because there is no exemption: two were tried, and the measured answer was
#    that the second changed nothing while the first accepted a HORIZONTAL ELLIPSIS as an alias
#    table — `click menu item "Save As…"` was exempt while being exactly the defect, since the
#    Korean menu reads 별도 저장….
found = scan('NAMES = ("Mixer", "믹서")\n'
             'SCRIPTS = [f\'click menu bar item "{n}" of menu bar 1\' for n in NAMES]\n',
             CANONICALS)
case("an interpolated predicate leaves nothing to flag", found == [], f"found={found!r}")

# 2a. And a typographic character does not buy an exemption, because none is on offer.
found = scan('CLICK = \'click menu bar item "Mixer…" of menu bar 1\'\n',
             {"mixer…": "mixerNamedElement"})
case("a literal with a typographic character is still a literal",
     [f[1] for f in found] == ["Mixer…"], f"found={found!r}")

# 3. Prose is not a matcher. These files explain themselves at length and quote predicates while
#    doing it; the first version of this guard skipped every triple-quoted block to cope and lost
#    two real sites, so docstrings are identified by position rather than by quoting style.
found = scan('"""The window is found with `first window whose name ends with "Tracks"`."""\n'
             'X = 1\n', CANONICALS)
case("a predicate quoted in a module docstring is not a site", found == [], f"found={found!r}")

# 4. ...and the same string in a payload IS one, which is what separates the two.
found = scan('SCRIPT = \'\'\'\ntell application "System Events"\n'
             '  set w to first window whose name ends with "Tracks"\n'
             'end tell\n\'\'\'\n', CANONICALS)
case("the same predicate in an AppleScript payload is a site",
     [f[1] for f in found] == ["Tracks"], f"found={found!r}")

# 4a. Two predicate patterns match `whose name ends with "…"`, and before results were deduplicated
#     the report listed the same site twice — 35 hits for 21 sites. A count that overstates is a
#     count nobody can act on.
case("a site matched by two patterns is reported once",
     len(found) == len({(f[0], f[1]) for f in found}), f"{len(found)} hit(s)")

# 5. A literal the policy has no variant for is not this guard's business: it may be invariant, or
#    nobody has looked. Flagging it would make the rule noisy enough to delete — 347 sites against
#    21 when it was measured.
found = scan('CLICK = \'click menu bar item "Zulu" of menu bar 1\'\n', CANONICALS)
case("a literal the policy does not know is localised is left alone", found == [], f"found={found!r}")

# 6. The vocabulary comes from the JSON projection, not from a second parse of the Swift.
canonicals = G.localised_canonicals()
case("the live vocabulary is non-empty and read from one place",
     isinstance(canonicals, dict) and len(canonicals) > 50, f"{len(canonicals)} localised canonicals")

# 7. The known list is content-keyed. Line numbers move whenever anything above them is edited, and
#    an allowlist that re-arms on an unrelated edit is worse than none.
case("the known list is keyed by (file, literal) and not by line",
     all(isinstance(k, tuple) and len(k) == 2 and all(isinstance(p, str) for p in k)
         for k in G.KNOWN),
     f"{len(G.KNOWN)} entries")

print()
print(f"FAILED ({failed} unexpected)" if failed else "all cases behaved (0 unexpected)")
sys.exit(1 if failed else 0)
