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
import subprocess
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

# 4b-ii. The left-hand side is not always a bare identifier. A second review found the narrow form
#        missing both of these, live in `live_608`.
found = scan('x = [t for t in raw if t.strip() == "Tracks"]\n', CANONICALS)
case("a comparison whose left side is a call is a site",
     [f[1] for f in found] == ["Tracks"], f"found={found!r}")

found = scan('ok = blocked.get("dialog_title") == "Tracks"\n', CANONICALS)
case("a comparison against a dict lookup is a site",
     [f[1] for f in found] == ["Tracks"], f"found={found!r}")

# 4b-iii. Single quotes are ordinary Python and escaped the double-quote-only form.
found = scan("ok = help.startswith('Tracks')\n", CANONICALS)
case("a single-quoted comparison is a site",
     [f[1] for f in found] == ["Tracks"], f"found={found!r}")

# 4b-iv. THE BALANCING ATTACK. Two patterns both match `whose name ends with "…"`, so one matcher
#        used to score two hits: replacing it with a single `window "Tracks"` and adding a second
#        elsewhere left the count unchanged while the file gained a defect. Occurrences are
#        counted by position now, so one matcher is one.
one = scan('S = \'first window whose name ends with "Tracks"\'\n', CANONICALS)
two = scan('A = \'window "Tracks"\'\nB = \'window "Tracks"\'\n', CANONICALS)
case("one matcher counts once however many patterns match it",
     len(one) == 1 and len(two) == 2, f"one={len(one)} two={len(two)}")

# 4b-v. A comparison against a protocol field this repository defines is not a UI matcher, even
#       when the policy happens to carry the same word. `control == "pan"` was a false positive
#       already baked into KNOWN.
found = scan('ok = (envelope.get("target_identity") or {}).get("control") == "pan"\n',
             {"pan": "sliderPanHint"})
case("a protocol-field comparison is not a UI matcher", found == [], f"found={found!r}")

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

# 9. THE ENTRY POINT, at a harness that must fail. Everything above drives `scan` and reads
#    `KNOWN`; nothing ran the guard. `Scripts/mutation-sweep-guard-tests.py` measured on
#    2026-09-18 that a `main()` returning 0 without calling anything left this suite green.
#    `LPM_LIVEKIT_DIR` is the seam that makes a positive input expressible.
with tempfile.TemporaryDirectory() as _tmp:
    with open(os.path.join(_tmp, "ui.py"), "w", encoding="utf-8") as _h:
        _h.write("X = 'click menu bar item \"Mixer\" of menu bar 1'\n")
    _bad = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                        "check-livekit-ui-literals.py")],
                          capture_output=True, text=True,
                          env=dict(os.environ, LPM_LIVEKIT_DIR=_tmp))
    case("the entry point refuses a hardcoded UI literal",
         _bad.returncode == 1, (_bad.stdout + _bad.stderr).strip()[:200])
    case("and names the literal and the LabelSet that carries it",
         "'Mixer'" in _bad.stdout + _bad.stderr and "AXLocalePolicy" in _bad.stdout + _bad.stderr,
         (_bad.stdout + _bad.stderr).strip()[:200])

# 10. The control, and it runs against the REAL harness directory rather than a fixture. The
#     `KNOWN` ratchet names 31 files under `Scripts/livekit/`, so pointing the scan at a temporary
#     directory makes every one of them read as "gone" and the guard fails for a reason that has
#     nothing to do with the case -- the first version of this control did exactly that. KNOWN is a
#     ratchet over the real harness set, and comparing it against a fixture compares two different
#     things. Case 9 shows the guard refuses; this shows it does not refuse everything.
_ok = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                   "check-livekit-ui-literals.py")],
                     capture_output=True, text=True)
case("and accepts the repository's own harnesses",
     _ok.returncode == 0, (_ok.stdout + _ok.stderr).strip()[:200])
# 11. An exemption covers its own LITERAL, never the rest of its line.
#    The table was always documented as keyed by "the literal AND the expression it sits in", and
#    the code skipped the whole line as soon as any marker matched. Found 2026-09-15: adding a
#    marker for `tell process "Logic Pro"` made three real `'Save'` findings disappear, because
#    they shared a line with it. The exempt word must go and everything beside it must stay.
#    Both strings must sit in ONE AppleScript constant, which is the shape the regression had:
#    `live_614` reaches a Save panel through `tell process "Logic Pro" to ... "Save" ...`, and the
#    process name and the button name share the line.
_line = ('A = \'tell application "System Events" to tell process "Logic Pro" to '
         'click menu bar item "Mixer" of menu bar 1\'\n')
_exempt_literal = "logic pro"
# The fixture has to USE a real table entry, or it proves something about a marker nobody ships.
case("the fixture exercises a marker the guard actually carries",
     any(m in _line and lit == _exempt_literal for m, lit, _where in G.PROTOCOL_COMPARISONS),
     _line.strip()[:70])
_found = scan(_line, dict(CANONICALS, **{_exempt_literal: "applicationMenuBarItem"}))
_lits = [lit for _base, lit, _line_no, _name in _found]
case("an exemption does not silence the other localisable strings on its line",
     _lits == ["Mixer"], f"found {_lits!r} — want only the non-exempt one")

case("and the exempt literal itself is still exempt",
     _exempt_literal not in {lit.lower() for lit in _lits}, f"found {_lits!r}")

_same_word = ('SCRIPT = \'tell process "Logic Pro" to click button "Logic Pro"\'\n')
_found = scan(_same_word, {"logic pro": "applicationMenuBarItem"})
case("a process name does not exempt a UI button with the same spelling",
     [f[1] for f in _found] == ["Logic Pro"], f"found={_found!r}")

_broad_process = ('SCRIPT = \'every process whose name contains "Logic Pro"; '
                  'button "Logic Pro"\'\n')
_found = scan(_broad_process, {"logic pro": "applicationMenuBarItem"})
case("a process-name predicate exempts only its own literal",
     [f[1] for f in _found] == ["Logic Pro"], f"found={_found!r}")

# 12. Scripts/verify (ADR-027 P2 PR-1, #1028): a second root, scanned the same way, but keyed
#     relative to itself rather than by basename -- Scripts/verify/probes.py and
#     Scripts/verify/live/probes.py would otherwise share one KNOWN key. Both roots are patched
#     to temporary directories so this case sees only what it wrote, not the real trees.
_empty_livekit = tempfile.mkdtemp()


def scan_verify(filename, body, canonicals):
    path = os.path.join(tmp, filename)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    original_livekit, original_verify = G.LIVEKIT, G.VERIFY
    G.LIVEKIT, G.VERIFY = _empty_livekit, tmp
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        return G.offenders(canonicals)
    finally:
        G.LIVEKIT, G.VERIFY = original_livekit, original_verify
        os.remove(path)


# The `name == "mute"` exemption is scoped to live/probes.py, where it was measured, so these
# cases write there. `found` must hold exactly the literals that are not the flag-name compare.
_MUTE = {"mute": "trackMuteButton"}
found = scan_verify("live/probes.py", 'if name == "mute": pass\n', _MUTE)
case("the flag-name compare is exempt in the file it is scoped to",
     found == [], f"found={found!r}")

found = scan_verify("live/probes.py",
                    'if name == "mute" and ui_title == "Mute": pass\n', _MUTE)
case("a verify protocol comparison does not exempt a same-word UI comparison",
     [f[1] for f in found] == ["Mute"], f"found={found!r}")

# The review's same-LITERAL witness: the UI compare is spelled exactly as the protocol one.
found = scan_verify("live/probes.py",
                    'if name == "mute" and ui_title == "mute": pass\n', _MUTE)
case("a same-literal UI comparison beside the protocol comparison is reported",
     [(f[0], f[1]) for f in found] == [("live/probes.py", "mute")], f"found={found!r}")

found = scan_verify("live/probes.py",
                    'if name == "mute" and ui_title == "Mute" and other_title == "Mute": pass\n',
                    _MUTE)
case("two same-word UI comparisons beside a protocol comparison both count",
     [f[1] for f in found] == ["Mute", "Mute"], f"found={found!r}")

# A review asked that the exemption not travel. The same text in any other file, or with the
# marker inside a longer name in its own file, is a UI compare until it is shown not to be.
found = scan_verify("live/other_probes.py", 'if name == "mute": pass\n', _MUTE)
case("the flag-name exemption does not apply outside its file",
     [(f[0], f[1]) for f in found] == [("live/other_probes.py", "mute")], f"found={found!r}")

found = scan_verify("live/probes.py", 'if button_name == "mute": pass\n', _MUTE)
case("a marker that begins with a name does not match inside a longer name",
     [f[1] for f in found] == ["mute"], f"found={found!r}")

_mute_scope = [where for m, lit, where in G.PROTOCOL_COMPARISONS if m == 'name == "mute"']
case("the fixture exercises the scope the guard actually carries",
     _mute_scope == [("Scripts/verify/live/probes.py",)], f"scopes={_mute_scope!r}")

_hit = G._hits('if name == "mute" and help == "Mute": pass', _MUTE, G.PYTHON_PREDICATES)
case("a text with no file behind it gets no scoped exemption",
     [lit for lit, _name in _hit] == ["mute", "Mute"], f"hits={_hit!r}")

found = scan_verify("live/case.py",
                    'CLICK = \'click menu bar item "Mixer" of menu bar 1\'\n', CANONICALS)
case("a Scripts/verify-root file carrying a real UI matcher is a site",
     [(f[0], f[1]) for f in found] == [("live/case.py", "Mixer")], f"found={found!r}")

# 12a. Scripts/verify/probes.py and Scripts/verify/live/probes.py share a basename; each must be
#      its own site, or one KNOWN entry would absorb the other's count.
_twin = os.path.join(tmp, "probes.py")
with open(_twin, "w", encoding="utf-8") as fh:
    fh.write('CLICK = \'click menu bar item "Mixer" of menu bar 1\'\n')
try:
    found = scan_verify("live/probes.py",
                        'CLICK = \'click menu bar item "Mixer" of menu bar 1\'\n', CANONICALS)
finally:
    os.remove(_twin)
case("two Scripts/verify files sharing a basename are two sites, keyed relative to Scripts/verify",
     sorted(f[0] for f in found) == ["live/probes.py", "probes.py"], f"found={found!r}")

# 12b. THE ENTRY POINT over the second root: `LPM_VERIFY_DIR` at a directory carrying a real UI
#      matcher, with Scripts/livekit left at the real tree so KNOWN is compared with what it
#      ratchets. The guard must refuse and name the verify-relative site.
with tempfile.TemporaryDirectory() as _vtmp:
    os.makedirs(os.path.join(_vtmp, "live"))
    with open(os.path.join(_vtmp, "live", "ui.py"), "w", encoding="utf-8") as _h:
        _h.write("X = 'click menu bar item \"Mixer\" of menu bar 1'\n")
    _vbad = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                         "check-livekit-ui-literals.py")],
                           capture_output=True, text=True,
                           env=dict(os.environ, LPM_VERIFY_DIR=_vtmp))
    case("the entry point refuses a UI literal under the Scripts/verify root",
         _vbad.returncode == 1 and "live/ui.py" in _vbad.stdout + _vbad.stderr,
         (_vbad.stdout + _vbad.stderr).strip()[:200])

os.rmdir(_empty_livekit)
print()
print(f"FAILED ({failed} unexpected)" if failed else "all cases behaved (0 unexpected)")
sys.exit(1 if failed else 0)
