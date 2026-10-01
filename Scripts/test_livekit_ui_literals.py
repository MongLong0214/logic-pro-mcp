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
import ast
import importlib.util
import os
import shutil
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
#       already baked into KNOWN. It is exempt in the harness it was measured in, where `envelope`
#       is the set_pan reply; with nothing binding `envelope` it is a comparison of something else.
_PAN_FILE = "live_290_selectors_resolve_by_identity.py"
_PAN_READ = 'ok = (envelope.get("target_identity") or {}).get("control") == "pan"\n'
found = scan('envelope = d.tool("logic_mixer", "set_pan", {"track": 0, "value": target})\n' + _PAN_READ,
             {"pan": "sliderPanHint"}, _PAN_FILE)
case("a protocol-field comparison is not a UI matcher", found == [], f"found={found!r}")
found = scan(_PAN_READ, {"pan": "sliderPanHint"}, _PAN_FILE)
case("the same comparison with nothing binding its name is reported", [f[1] for f in found] == ["pan"],
     f"found={found!r}")

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


# The `name == "mute"` exemption is scoped to live/probes.py, where it was measured, and to the
# loop over FLAGS that binds `name` there, so these cases write that loop in that file. `found` must
# hold exactly the literals that are not the flag-name compare.
_MUTE = {"mute": "trackMuteButton"}


def _in_flags(line):
    return f"for name in FLAGS:\n    {line}\n"


found = scan_verify("live/probes.py", _in_flags('if name == "mute": pass'), _MUTE)
case("the flag-name compare is exempt in the file it is scoped to",
     found == [], f"found={found!r}")

found = scan_verify("live/probes.py",
                    _in_flags('if name == "mute" and ui_title == "Mute": pass'), _MUTE)
case("a verify protocol comparison does not exempt a same-word UI comparison",
     [f[1] for f in found] == ["Mute"], f"found={found!r}")

# The review's same-LITERAL witness: the UI compare is spelled exactly as the protocol one.
found = scan_verify("live/probes.py",
                    _in_flags('if name == "mute" and ui_title == "mute": pass'), _MUTE)
case("a same-literal UI comparison beside the protocol comparison is reported",
     [(f[0], f[1]) for f in found] == [("live/probes.py", "mute")], f"found={found!r}")

found = scan_verify("live/probes.py",
                    _in_flags('if name == "mute" and ui_title == "Mute" and other_title == "Mute": pass'),
                    _MUTE)
case("two same-word UI comparisons beside a protocol comparison both count",
     [f[1] for f in found] == ["Mute", "Mute"], f"found={found!r}")

# A review asked that the exemption not travel. The same text in any other file, or with the
# marker inside a longer name in its own file, is a UI compare until it is shown not to be.
found = scan_verify("live/other_probes.py", _in_flags('if name == "mute": pass'), _MUTE)
case("the flag-name exemption does not apply outside its file",
     [(f[0], f[1]) for f in found] == [("live/other_probes.py", "mute")], f"found={found!r}")

found = scan_verify("live/probes.py", _in_flags('if button_name == "mute": pass'), _MUTE)
case("a marker that begins with a name does not match inside a longer name",
     [f[1] for f in found] == ["mute"], f"found={found!r}")

_mute_scope = [where for m, lit, where, _bound in G.PROTOCOL_EXPRESSIONS if m == 'name == "mute"']
case("the fixture exercises the scope the guard actually carries",
     _mute_scope == [("Scripts/verify/live/probes.py",)], f"scopes={_mute_scope!r}")

_hit = G._hits('if name == "mute" and help == "Mute": pass', _MUTE, G.PYTHON_PREDICATES)
case("a text with no file behind it gets no scoped exemption",
     [lit for lit, _name in _hit] == ["mute", "Mute"], f"hits={_hit!r}")

# 12c. An expression exemption is the whole comparison (#1078, review R1). The text marker it
#      replaced bounded only where it began, so `"read" in step` also exempted
#      `"read" in step_title` and `"read" in step["automation_title"]` -- a localised title -- and
#      `name == "mute"` a name spelled `button`, U+0301, `name`, which Python reads as one
#      identifier and `\w` does not. Every entry is scanned in every file it may apply in: its own
#      comparison exempt however it is quoted, and the same comparison with its other operand
#      longer, read from something, reading something, joined by an operator or continued by a
#      combining mark, reported once. Each variant must parse and must be a different comparison,
#      so a witness the scan cannot read, or one that is the entry again, cannot pass.
def _files_of(where):
    if where is G.EVERY_HARNESS:
        return [("live_case.py", lambda name, body, known: scan(body, known, name))]
    return [(os.path.relpath(path, "Scripts/livekit"), lambda name, body, known: scan(body, known, name))
            if path.startswith("Scripts/livekit/") else (os.path.relpath(path, "Scripts/verify"), scan_verify)
            for path in where]


def _bound(binding, line):
    """`v = line` where the entry's name has the binding it was measured with, and no other."""
    if binding.startswith(("def ", "for ")):
        return f"{binding}:\n    v = {line}\n"
    if binding.startswith("lambda"):
        return f"v = {binding}: {line}\n"
    return f"{binding}\nv = {line}\n"


def _bindings_of(bindings):
    return (bindings,) if isinstance(bindings, str) else bindings


def _variants(expression, literal):
    """The entry with its name longer, continued by a combining mark or read from something, and
    with its operand reading something, joined by an operator or read further. The name is changed
    where it stands, so an operand that opens with a parenthesis still parses."""
    node = ast.parse(expression, mode="eval").body
    other = (node.left, node.comparators[0])[1 - G._comparison(expression, literal)[1]]
    start, end = other.col_offset, other.end_col_offset
    text = expression[start:end]
    root = next(n for n in ast.walk(other) if isinstance(n, ast.Name))
    name = expression[root.col_offset:root.end_col_offset]
    at_name = [expression[:root.col_offset] + shape + expression[root.end_col_offset:]
               for shape in ("x" + name, "x́" + name, "obj." + name, name + "_x", name + "́x")]
    at_operand = [expression[:start] + shape + expression[end:]
                  for shape in ("x + " + text, text + ".x", text + '["x"]', text + " + x")]
    return at_name + at_operand


for _expression, _literal, _where, _bindings in G.PROTOCOL_EXPRESSIONS:
    _known = {_literal: "protocolWitness"}
    _shape = ast.dump(ast.parse(_expression, mode="eval").body)
    _variant_list = _variants(_expression, _literal)
    _unreadable = [v for v in _variant_list
                   if ast.dump(ast.parse(v, mode="eval").body) == _shape]
    case(f"every variant of {_expression} is a different comparison",
         _unreadable == [], f"same as the entry: {_unreadable!r}")
    _name_read = G._comparison(_expression, _literal)[2]
    _exempt, _escaped, _rebound = [], [], []
    for _name, _scan in _files_of(_where):
        for _binding in _bindings_of(_bindings):
            for _spelling in (_expression, _expression.replace('"', "'")):
                _found = _scan(_name, _bound(_binding, _spelling), _known)
                if _found:
                    _exempt.append((_name, _binding, _spelling, _found))
            for _variant in _variant_list:
                _found = _scan(_name, _bound(_binding, _variant), _known)
                if [f[1].lower() for f in _found] != [_literal]:
                    _escaped.append((_name, _variant, [f[1] for f in _found]))
            # Review R2's alias, on every entry: the measured binding, then the name rebound to
            # something read from it. A lambda cannot assign, so its rebinding is a walrus.
            if _binding.startswith("lambda"):
                _alias = f'v = {_binding}: [{_name_read} := {_name_read}["automation_title"], {_expression}][1]\n'
            elif _binding.startswith(("def ", "for ")):
                _alias = (f'{_binding}:\n    {_name_read} = {_name_read}["automation_title"]\n'
                          f"    v = {_expression}\n")
            else:
                _alias = f'{_binding}\n{_name_read} = {_name_read}["automation_title"]\nv = {_expression}\n'
            for _label, _body in (("rebound after its binding", _alias),
                                  ("bound to something else", f"{_name_read} = ui_title\nv = {_expression}\n"),
                                  ("not bound at all", f"v = {_expression}\n"),
                                  ("bound by another function", f"def other({_name_read}):\n    v = {_expression}\n")):
                _found = _scan(_name, _body, _known)
                if [f[1].lower() for f in _found] != [_literal]:
                    _rebound.append((_name, _label, [f[1] for f in _found]))
    case(f"{_expression} is exempt under its binding in each file it applies in, however quoted",
         _exempt == [], f"reported: {_exempt!r}")
    case(f"{_expression} exempts no other operand", _escaped == [],
         f"{len(_variant_list)} variants; not reported once: {_escaped!r}")
    case(f"{_expression} is reported once wherever its name is not bound as measured", _rebound == [],
         f"not reported once: {_rebound!r}")
    if _where is not G.EVERY_HARNESS:
        _found = scan_verify("live/elsewhere.py", _bound(_bindings_of(_bindings)[0], _expression), _known)
        case(f"{_expression} is reported outside its files, under its own binding",
             [f[1].lower() for f in _found] == [_literal], f"found={_found!r}")

# Every way of binding a name that no entry is written as, in the function `"read" in step` was
# measured in, after the parameter that is its binding. Each is a second binding, so the comparison
# is a read of something else and is reported, once. The control is the function alone.
_READ = {"read": "protocolWitness"}
_TAKE = "def _take(ctx: dict, step: dict) -> str:\n"
_found = scan_verify("runner.py", _TAKE + '    return "read" in step\n', _READ)
case("the control: under its measured binding `\"read\" in step` is exempt", _found == [], f"found={_found!r}")
for _label, _lines in (
        ("an assignment from what it read (review R2)", ['step = step["automation_title"]']),
        ("an augmented assignment", ['step += ""']),
        ("an annotated assignment", ["step: str = title"]),
        ("a walrus", ['(step := step["automation_title"])']),
        ("a walrus inside a comprehension", ["[step := t for t in titles]"]),
        ("a for loop", ["for step in titles:", "    pass"]),
        ("a with", ["with open(p) as step:", "    pass"]),
        ("an except", ["try:", "    pass", "except OSError as step:", "    pass"]),
        ("an import", ["import step"]),
        ("a nested def", ["def step():", "    pass"]),
        ("a nested class", ["class step:", "    pass"]),
        ("a del", ["del step"]),
        ("a tuple target", ["step, other = title, 1"]),
        ("a match capture", ["match title:", "    case {\"t\": step}:", "        pass"])):
    _body = _TAKE + "".join(f"    {line}\n" for line in _lines) + '    return "read" in step\n'
    _found = scan_verify("runner.py", _body, _READ)
    case(f"`\"read\" in step` after {_label} is reported once", [f[1] for f in _found] == ["read"],
         f"found={_found!r}")
_found = scan_verify("runner.py", _TAKE + '    def inner(step):\n        return "read" in step\n', _READ)
case("a nested function's own parameter is another binding, and is reported",
     [f[1] for f in _found] == ["read"], f"found={_found!r}")
_found = scan_verify("runner.py", _TAKE + '    def inner():\n        return "read" in step\n', _READ)
case("a nested function that reads the measured parameter is the same comparison, and exempt",
     _found == [], f"found={_found!r}")
_found = scan_verify("selftest.py", 'def f():\n    global op\n    for op in ops:\n'
                     '        v = "delete" in op\n', {"delete": "protocolWitness"})
case("a global declaration beside the measured binding is reported",
     [f[1] for f in _found] == ["delete"], f"found={_found!r}")

# A chained comparison compares the literal with a second operand, so it is no entry, under the
# binding or not; and an entry spelled with an escape, or continued onto the next line, is the same
# comparison and stays exempt beside a UI read on the same line.
_found = scan_verify("runner.py", _TAKE + '    return title == "read" in step\n', _READ)
case("a chained comparison through an entry's literal is reported once",
     [f[1] for f in _found] == ["read"], f"found={_found!r}")
_found = scan_verify("runner.py", _TAKE + '    return "re\\x61d" in step and ui == "read"\n', _READ)
case("an escaped entry is exempt and the UI comparison beside it is counted once",
     [f[1] for f in _found] == ["read"], f"found={_found!r}")
_found = scan_verify("runner.py", _TAKE + '    return ("read"  # 가\n            "") in step\n', _READ)
case("an entry continued onto the next line is the same comparison, and exempt",
     _found == [], f"found={_found!r}")
for _folded in ('f"read"', '"re" + "ad"'):
    _found = scan_verify("runner.py", _TAKE + f"    return {_folded} in step\n", _READ)
    case(f"the entry spelled {_folded} is the same comparison, and exempt", _found == [], f"found={_found!r}")
_found = scan_verify("runner.py", _TAKE + "    class C:\n        step = title\n\n"
                     '        def m(self):\n            return "read" in step\n', _READ)
case("a class body between a method and the parameter it reads is not a scope for it",
     _found == [], f"found={_found!r}")
_found = scan_verify("runner.py", _TAKE + "    class C:\n        step = title\n"
                     '        v = "read" in step\n', _READ)
case("a class body is the scope of a comparison written in it directly",
     [f[1] for f in _found] == ["read"], f"found={_found!r}")

# Review R2's sweep: every position, in both Python roots, spelled every way the parser joins into
# one string or the language folds into one value. Each must be reported exactly once, with the
# plain spelling as the control in the same run. Before #1078 R2 only the plain one was.
_SPELLINGS = ('"read"', '"re\\x61d"', '"\\u0072ead"', '"re" "ad"', '("re"\n     "ad")', 'f"read"',
              '"re" + "ad"', 'r"read"')
_POSITIONS = ("title == {s}", "{s} == title", "title != {s}", "{s} != title", "{s} in title", "{s} not in title", "{s} in (title)",
              "{s} in (step['automation_title'])", "title in ({s},)", "title in [{s}]", "title in {{{s}}}",
              "title.startswith({s})", "title.endswith({s})", "title.startswith(({s}, 'x'))")
_swept = []
for _root, _scan_one in (("Scripts/livekit", lambda body: scan(body, _READ)),
                         ("Scripts/verify", lambda body: scan_verify("runner.py", body, _READ))):
    for _position in _POSITIONS:
        for _spelling in _SPELLINGS:
            _line = "v = " + _position.format(s=_spelling) + "\n"
            ast.parse(_line)
            _found = _scan_one(_line)
            if [f[1] for f in _found] != ["read"]:
                _swept.append((_root, _line.strip(), [f[1] for f in _found]))
case(f"each of {len(_SPELLINGS)} spellings at each of {len(_POSITIONS)} positions in both roots is "
     "reported once", _swept == [], f"not reported once: {_swept[:6]!r} ({len(_swept)})")
_found = scan('v = f"{prefix}read" == title\n', _READ)
case("an f-string that interpolates is computed, and not read as a word", _found == [], f"found={_found!r}")
_found = scan('"""The step title == "read" is prose."""\n# title == "read"\nv = 1\n', _READ)
case("a docstring and a comment are not comparisons", _found == [], f"found={_found!r}")

# Swift is read by line; a `\u{...}` escape is written out first, so it spells its word there too.
for _swift, _want in (('if title == "read" { }', ["read"]), ('if title == "re\\u{61}d" { }', ["read"]),
                      ('if title.hasPrefix("\\u{72}ead") { }', []),
                      ('let s = "x\\u{22} == \\u{22}read"', [])):
    _found = scan_verify("live/Probe.swift", _swift + "\n", _READ)
    case(f"Swift {_swift!r} is reported {len(_want)} time(s)", [f[1] for f in _found] == _want,
         f"found={_found!r}")

# The review's own witness, through the entry point over a copy of the real Scripts/verify, with
# the copy unmodified in the same run as the control: the copy passes, then fails with one
# function appended to runner.py, and names that file.
with tempfile.TemporaryDirectory() as _vcopy:
    _copy = os.path.join(_vcopy, "verify")
    shutil.copytree(os.path.join(REPO, "Scripts", "verify"), _copy,
                    ignore=shutil.ignore_patterns("__pycache__"))
    _entry = [sys.executable, os.path.join(REPO, "Scripts", "check-livekit-ui-literals.py")]
    _clean = subprocess.run(_entry, capture_output=True, text=True,
                            env=dict(os.environ, LPM_VERIFY_DIR=_copy))
    with open(os.path.join(_copy, "runner.py"), encoding="utf-8") as _h:
        _runner = _h.read()
    _witness_runs = {}
    for _label, _function in (
            ("titled", 'def _titled(step):\n    return "read" in step["automation_title"]\n'),
            ("aliased", 'def _aliased(step):\n    step = step["automation_title"]\n    return "read" in step\n'),
            ("escaped", 'def _escaped(step):\n    return "re\\x61d" in (step["automation_title"])\n')):
        with open(os.path.join(_copy, "runner.py"), "w", encoding="utf-8") as _h:
            _h.write(_runner + "\n\n" + _function)
        _witness_runs[_label] = subprocess.run(_entry, capture_output=True, text=True,
                                               env=dict(os.environ, LPM_VERIFY_DIR=_copy))
    _dirty = _witness_runs["titled"]
case("a copy of the real Scripts/verify passes the entry point",
     _clean.returncode == 0, (_clean.stdout + _clean.stderr).strip()[-200:])
case("and the same copy with a title read beside `step` fails it, naming runner.py",
     _dirty.returncode == 1 and "runner.py" in _dirty.stdout and "'read'" in _dirty.stdout,
     (_dirty.stdout + _dirty.stderr).strip()[:200])
for _label in ("aliased", "escaped"):
    _run = _witness_runs[_label]
    case(f"and with review R2's {_label} witness appended it fails, naming runner.py",
         _run.returncode == 1 and "runner.py" in _run.stdout and "'read'" in _run.stdout,
         (_run.stdout + _run.stderr).strip()[:200])

# The table checks itself: an entry that is not one comparison of its literal with one other
# operand stops the module instead of exempting nothing.
for _bad in (('flag', "solo"), ('"a" == "a"', "a"), ('x == "y" == z', "y"), ('x == "y"', "z"),
             ('x + y == "s"', "s"), ('"s" == 1', "s")):
    try:
        G._comparison(*_bad)
        _refused = False
    except ValueError:
        _refused = True
    case(f"the table refuses {_bad[0]!r} as an entry for {_bad[1]!r}", _refused, "")
for _bad_binding in (("for x in y", "step"), ("a = b = c", "a"), ("step += 1", "step"), ("def f(x)", "step"),
                     ("lambda o", "step")):
    try:
        G._binding_key(*_bad_binding)
        _refused = False
    except (ValueError, SyntaxError):
        _refused = True
    case(f"the table refuses {_bad_binding[0]!r} as the binding of {_bad_binding[1]!r}", _refused, "")

# A TEXT marker keeps what it was written for -- exempting whatever its expression is read from --
# but one that begins with a name no longer matches after a character that continues that name.
_saved = G.PROTOCOL_COMPARISONS
G.PROTOCOL_COMPARISONS = (('get("k") == "mute"', "mute", G.EVERY_HARNESS),)
try:
    _through = G._hits('v = d.get("k") == "mute"', _MUTE, G.PYTHON_PREDICATES)
    _joined = G._hits('v = x́get("k") == "mute"', _MUTE, G.PYTHON_PREDICATES)
finally:
    G.PROTOCOL_COMPARISONS = _saved
case("a text marker still exempts what it is read from", _through == [], f"hits={_through!r}")
ast.parse('v = x́get("k") == "mute"')
case("a text marker that begins with a name does not match after a combining mark",
     [lit for lit, _name in _joined] == ["mute"], f"hits={_joined!r}")

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
