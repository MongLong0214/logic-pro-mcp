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
     {f[1] for f in found} == {"Tracks"}, f"found={found!r}")

# 4a. Two predicate patterns match `whose name ends with "…"`, so the same matcher yields more than
#     one raw hit. That is fine and is now load-bearing — `main` aggregates by (file, literal) and
#     compares the COUNT against KNOWN — but the REPORT must still name a site once. Deduplicating
#     inside `offenders` was the earlier shape, and it threw away the number the ratchet needs.
sites = {(f[0], f[1]) for f in found}
case("however many patterns match, the report names one site",
     len(sites) == 1 and len(found) >= 1, f"{len(found)} hit(s) over {len(sites)} site(s)")

# 4b. THE ONE AN OUTSIDE REVIEW FOUND. The rule advertised Python `.startswith(...)` and
#     `help == "..."` and caught neither: `_hits` was handed the CONTENTS of a string constant
#     (`Tracks`), while the pattern demanded the surrounding source (`help.startswith("Tracks")`).
#     Three advertised shapes could never fire, and the first version of this test did not ask.
found = scan('def f(help):\n    return help.startswith("Tracks")\n', CANONICALS)
case("a Python .startswith comparison is a site",
     [f[1] for f in found] == ["Tracks"], f"found={found!r}")

found = scan('def f(help):\n    return help == "Tracks"\n', CANONICALS)
case("a Python == comparison is a site",
     [f[1] for f in found] == ["Tracks"], f"found={found!r}")

# 4c. ...and the same shape quoted in a docstring is still prose.
found = scan('"""Matched with help.startswith("Tracks") before #766."""\nX = 1\n', CANONICALS)
case("a Python comparison quoted in a docstring is not a site", found == [], f"found={found!r}")

# 5. A literal the policy has no variant for is not this guard's business: it may be invariant, or
#    nobody has looked. Flagging it would make the rule noisy enough to delete — 347 sites against
#    21 when it was measured.
found = scan('CLICK = \'click menu bar item "Zulu" of menu bar 1\'\n', CANONICALS)
case("a literal the policy does not know is localised is left alone", found == [], f"found={found!r}")

# 6. The vocabulary comes from the JSON projection, not from a second parse of the Swift.
canonicals = G.localised_canonicals()
case("the live vocabulary is non-empty and read from one place",
     isinstance(canonicals, dict) and len(canonicals) > 50, f"{len(canonicals)} localised canonicals")

# 7. The known list is content-keyed AND counts. Line numbers move whenever anything above them is
#    edited, so an allowlist keyed on them re-arms on an unrelated edit. Keyed on (file, literal)
#    ALONE it had the opposite fault, which an outside review found: a file already listed for
#    "View" could gain any number of further "View" matchers and pass, because occurrences were
#    deduplicated before the comparison.
case("the known list is keyed by (file, literal) and not by line",
     all(isinstance(k, tuple) and len(k) == 2 and all(isinstance(p, str) for p in k)
         for k in G.KNOWN),
     f"{len(G.KNOWN)} entries")

case("every known entry carries how many matchers the site has",
     all(isinstance(v, int) and v >= 1 for v in G.KNOWN.values()),
     f"{sum(G.KNOWN.values())} matchers across {len(G.KNOWN)} sites")

# 8. And occurrences reach the caller, because the count is what the ratchet compares. Returning a
#    deduplicated list here is what let a site absorb new copies silently.
found = scan('A = \'click menu bar item "Mixer" of menu bar 1\'\n'
             'B = \'click menu bar item "Mixer" of menu bar 1\'\n', CANONICALS)
case("two matchers for the same literal are both returned",
     len(found) == 2, f"{len(found)} occurrence(s)")

print()
print(f"FAILED ({failed} unexpected)" if failed else "all cases behaved (0 unexpected)")
sys.exit(1 if failed else 0)
