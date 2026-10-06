#!/usr/bin/env python3
"""A live harness must not aim at Logic's UI with a string only one language spells that way.

`Scripts/ci-forbid-hardcoded-menu-bar-item.sh` says its scope in its own header: **Sources/ only**.
That exemption is right for a unit fixture, which invents its own tree and never meets Logic. It is
wrong for `Scripts/livekit`, whose files drive the real application — a literal there is exactly as
load-bearing as one in the product, and it fails in a way that is worse to diagnose, because the
harness reports a precondition about a window frame rather than a word spelled for another language.

Measured 2026-09-04, which is why this exists. `live_291_input_slot_is_read` could not run at all on
a Korean Logic for three separate reasons, each sufficient on its own:

    first window whose name ends with "Tracks"      raises; the window is `<project> - 트랙`
    menu bar item "View"                            raises; the menu is `보기`
    h starts with "Output slot"                     never matches; the help is `출력 슬롯. …`

None of them were new. `AXLocalePolicy` already recorded `arrangeWindowTitleSuffix`,
`pluginWindowViewSwitcher` and (as of the same day) `outputSlotHelpKeyword`, each with the ko-KR
spelling beside the English one. The product knew; the harness did not; nothing compared them.

## The rule

A string literal inside a `Scripts/livekit` file is rejected when BOTH hold:

  1. it sits in a UI-matching position — an AppleScript element predicate, a `whose … is/contains/
     starts with/ends with`, or a Python `.startswith(...)` / `help ==` comparison; and
  2. `AXLocalePolicy` carries it as the `canonical` of a `LabelSet` that HAS variants — so the
     policy already knows another language spells it differently, and this site can only match one.

Clause 2 is what keeps the rule honest rather than noisy. Without it the same scan flags 347 sites,
most of them JSON keys and prose; with it, 28, and every one is a live harness that cannot run
outside English. It also means the guard grows by itself: measure a new locale into a LabelSet and
every harness hardcoding that string becomes an error the same day.

There is no exemption, and there were two attempts at one before that was the answer.

The first asked whether the line held any non-ASCII character. `click menu item "Save As…"`
satisfied it on the strength of a HORIZONTAL ELLIPSIS while being exactly the defect — the Korean
menu reads `별도 저장…` — and an em dash or a curly quote would have done the same.

The second asked the question that was actually meant: does a measured variant of THIS label appear
on the line? Precise, and measured to change nothing. Python here is parsed, so the text a rule sees
is the inside of a string constant, and a table declared beside it is not on that line at all.

So the rule is simply that the literal must not be there. The fix is to interpolate the spelling
from a table — `f'menu bar item "{name}"'` over every entry — which is what `live_291` does and
what leaves nothing to exempt. A clause that changes nothing is a clause that will be trusted to do
something.

Python files are parsed rather than scanned line by line, because these harnesses hold their
AppleScript in triple-quoted strings and a line-based reader cannot tell one from a docstring. The
first attempt skipped every triple-quoted block and lost two real sites; treating them all as code
would have flagged prose in three module headers. `ast` separates them exactly: a docstring is the
first statement of its module or function, and everything else is a payload.

## The known list only shrinks, and it counts

Each entry records how many matchers a site carries, so adding another copy of an
already-listed literal is reported rather than absorbed. Enforcing this outright would turn
thirteen harnesses red at once, and the predictable next move is that somebody deletes the guard — the reasoning `evidence.py` already records for
`visual_assertions_without_a_subject`, which was counted for a release before it was gated. So the
sites present when the rule was written are listed below and NEW ones are rejected. An entry that no
longer matches is also an error, so the list cannot rot: fix a site, delete its line, and the guard
holds you to it.
"""
import ast
import glob
import importlib.util
import os
import re
import symtable
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
#: A seam, so the self-test can drive main() -- the ENTRY POINT -- at a tree that must
#: fail. Without one every case can only reach the helpers, and a `main()` returning 0
#: unconditionally stays green; Scripts/mutation-sweep-guard-tests.py measured exactly
#: that for this guard on 2026-09-18.
LIVEKIT = os.environ.get("LPM_LIVEKIT_DIR") or os.path.join(REPO, "Scripts", "livekit")
#: A second root (ADR-027 P2 PR-1, #1028): `Scripts/verify` drives the real application exactly as
#: Scripts/livekit does, so the same rule applies to it. Keyed relative to this root rather than by
#: basename -- `Scripts/verify/probes.py` and `Scripts/verify/live/probes.py` would otherwise share
#: one KNOWN key.
VERIFY = os.environ.get("LPM_VERIFY_DIR") or os.path.join(REPO, "Scripts", "verify")

# Sites that existed when this rule was written, keyed by (file, literal) rather than by line, so
# editing a file elsewhere does not silently re-arm or disarm an entry. This list may only shrink.
# Sites present when this rule was written, with HOW MANY matchers each carries. The count is the
# part an outside review found missing: keyed by `(file, literal)` alone, a file already listed for
# "View" could gain any number of further "View" matchers and still pass, because occurrences were
# deduplicated before the comparison. A list that hides unbounded new copies of a defect is not a
# ratchet. Counts may only fall; a site that gains one is reported.
KNOWN = {
    ("live_290_shifted_strips_are_refused.py", "Mixer"): 1,
    ("live_290_shifted_strips_are_refused.py", "View"): 1,
    ("live_291_input_slot_is_read.py", "send"): 1,
    ("live_291_output_slot_is_read.py", "send"): 1,
    ("live_448_track_stack_readback.py", "Edit"): 1,
    ("live_519_region_op_on_a_localized_logic.py", "Edit"): 3,
    ("live_448_track_stack_readback.py", "Tracks"): 1,
    ("live_519_region_op_on_a_localized_logic.py", "Tracks"): 3,
    ("live_523_marker_delete.py", "Marker"): 2,
    ("live_523_marker_delete.py", "Number of Items"): 2,
    ("live_538_modal_reconcile.py", "Tracks"): 1,
    ("live_549_cell_does_not_veto.py", "Cancel"): 2,
    ("live_549_cell_does_not_veto.py", "Delete"): 1,
    ("live_549_cell_does_not_veto.py", "Navigate"): 1,
    ("live_549_cell_does_not_veto.py", "Open Marker List"): 1,
    ("live_549_cell_does_not_veto.py", "Tracks"): 2,
    ("live_549_receipt_names_the_node.py", "Tracks"): 1,
    ("live_575_move_to_playhead_reachable.py", "Edit"): 3,
    ("live_572_record_sequence_first_call.py", "Tracks"): 1,
    ("live_576_completeness_is_measured.py", "Tracks"): 2,
    ("live_576_viewport_limited_region_readback.py", "Tracks"): 1,
    ("live_590_project_new_from_cold_launch.py", "Cancel"): 1,
    ("live_590_project_new_from_cold_launch.py", "Save"): 1,
    ("live_590_project_new_from_cold_launch.py", "Tracks"): 4,
    ("live_606_save_as_writes_the_file.py", "Save"): 2,
    ("live_608_first_call_is_not_refused.py", "Save"): 3,
    ("live_608_first_call_is_not_refused.py", "Save As…"): 1,
    ("live_614_the_refusal_it_can_still_reach.py", "Save"): 2,
    ("live_628_mixer_fallback_is_visible.py", "Mixer"): 1,
    ("live_628_mixer_fallback_is_visible.py", "View"): 1,
    ("test_evidence.py", "트랙 콘텐츠"): 1,
}

_ELEMENT = r"menu bar item|menu item|checkbox|button|window|radio button|static text|group"

# AppleScript predicates live INSIDE a Python string, so these are matched against the contents of
# string constants.
APPLESCRIPT_PREDICATES = [
    re.compile(rf'(?:{_ELEMENT})\s+"([^"]+)"'),
    re.compile(r'whose\s+(?:name|description|title|help)\s+(?:is|contains|starts with|ends with)\s+"([^"]+)"'),
    re.compile(r'\b(?:starts with|ends with)\s+"([^"]+)"'),
    # `(description of contents of k) is "Number of Items"` — an attribute compared directly, which
    # `whose … is` does not cover. Anchored on the attribute word so a bare `is "…"` stays out.
    re.compile(r'(?:description|name|title|help)\s+of\s+[^"\n]{0,60}?(?:is|contains)\s+"([^"]+)"'),
]

# Python comparisons live in the SOURCE, and matching them against a string constant's contents —
# which is what this guard did until an outside review pointed it out — can never fire: the value
# handed to the regex is `Tracks`, and the pattern demands `.startswith("Tracks")`. The rule
# advertised these shapes and caught neither. They are a separate pass over the source for that
# reason, and `test_livekit_ui_literals.py` now has the case that would have caught it.
# The left-hand side is anything, not a bare identifier. An outside review found the narrow form
# missing `t.strip() == "Save"` and `blocked.get("dialog_title") == "Save"`, both live in
# `live_608`: a comparison against a localised UI string is the defect whatever the expression on
# the other side looks like.
# Both quote styles: `help.startswith('Tracks')` is ordinary Python and escaped the
# double-quote-only form. `(?P<q>["\'])` requires the same quote on both ends.
PYTHON_PREDICATES = [
    re.compile(r'\.(?:startswith|endswith)\(\s*(?P<q>["\'])(?P<lit>[^"\']+)(?P=q)'),
    re.compile(r'(?:==|!=)\s*(?P<q>["\'])(?P<lit>[^"\']+)(?P=q)'),
    re.compile(r'(?P<q>["\'])(?P<lit>[^"\']+)(?P=q)\s*(?:==|!=)'),
    re.compile(r'(?P<q>["\'])(?P<lit>[^"\']+)(?P=q)\s+in\s+\w'),
]

# Comparisons against a PROTOCOL name, not against Logic's UI, written where no parser reads them:
# inside an AppleScript string, or in a Swift file. Keyed by the literal AND the text it sits in, so
# the exemption cannot quietly cover a real UI comparison against the same word, and by the files it
# may apply in: `EVERY_HARNESS`, or a tuple of repository-relative paths.
#
# These are TEXT markers, found in the line. A marker that begins with a name does not match after a
# character that would continue that name. A Python comparison is read from the tree and exempted by
# PROTOCOL_EXPRESSIONS below; the three `control` forms and `["kind"]` that sat here were Python
# comparisons, matched as text and exempting whatever they were read from, and each is an entry
# there now (#1078, review R2), tied to the binding it was measured with.
EVERY_HARNESS = None
PROTOCOL_COMPARISONS = (
    # System Events' PROCESS name is not Logic's UI, and it is not the string the policy carries.
    # MEASURED 2026-09-15 on a Korean Logic 12.3 (6674), all three in the same minute:
    #
    #   every process whose name is "Logic Pro"            (U+0020)  -> 1
    #   every process whose name is "Logic\u00a0Pro"        (U+00A0)  -> 0
    #   name of every process whose bundle identifier ...  -> bytes `L o g i c   P r o`
    #
    # while the AXMenuBarItem title on the SAME host is the non-breaking spelling. Two different
    # strings that read alike; `applicationMenuBarItem` is about the second one. Without this the
    # guard would push five harnesses to "fix" a line that is already right, and the fix would
    # break them.
    ('every process whose ', "logic pro", EVERY_HARNESS),
    ('name is "Logic Pro"', "logic pro", EVERY_HARNESS),
    ('tell process "Logic Pro"', "logic pro", EVERY_HARNESS),
    ('tell application "Logic Pro"', "logic pro", EVERY_HARNESS),
)

# Whole Python comparisons, keyed and scoped as above but matched by what they ARE. A text marker
# bounds where it starts, and that is not the same expression: review R1 of #1078 found
# `"read" in step` exempting `"read" in step_title` and `"read" in step["automation_title"]` -- a
# localised title -- and `name == "mute"` exempting a name spelled `button`, U+0301, `name`, which
# Python reads as one identifier and `\w` does not. So each entry is parsed as one comparison, and
# a comparison in the source is exempt only when both its operands are the entry's: the same names
# and subscripts, nothing read from them, nothing longer, nothing joined by an operator. Quote style
# and redundant parentheses are not part of an expression, so `'read' in step` is the same one.
# Escapes, adjacent strings and line breaks inside a literal are not part of it either: the parser
# has joined them, so `"re\x61d" in (step)` is the entry `"read" in step`.
#
# The same expression is another comparison when its name holds something else. Review R2 of #1078
# found `step = step["automation_title"]` followed by `"read" in step` exempt: a localised title,
# compared under the entry's own spelling. So each entry also names the binding it was measured with
# -- the assignment, `def` header, `lambda` parameters or `for` clause that gives its one name a
# value -- and a comparison is exempt only where the scope that resolves that name binds it exactly
# once, by one of those. A second binding of any kind, a different one, a `global` or `nonlocal`
# declaration, or none at all (the name comes from elsewhere) is reported. What a binding reads in
# turn -- `witness` in `for r in witness` -- is not followed.
# They apply to Python source only; in an AppleScript string or a Swift file they exempt nothing.
PROTOCOL_EXPRESSIONS = (
    # Two comparisons against a name that was ALREADY normalised or already read as a process name.
    # `evidence.py` strips the non-breaking space on the line above its compare and says so in a
    # comment older than this guard; `live_614` compares `name of first process whose frontmost is
    # true`. Keyed by the variable and its binding so the exemption cannot spread to a window or
    # menu title.
    ('owner == "Logic Pro"', "logic pro", EVERY_HARNESS,
     'owner = (window.get("kCGWindowOwnerName") or "").replace("\\xa0", " ")'),
    ('front == "Logic Pro"', "logic pro", EVERY_HARNESS,
     'front = osa(\'tell application "System Events" to return name of first process whose '
     'frontmost is true\')'),
    # `target_identity.control == "pan"` reads a key this repository defines and ships in the
    # set_pan envelope; that the policy also carries `pan` as a slider hint does not make the
    # envelope localised. A review found this one already baked into KNOWN as a false positive.
    ('(envelope.get("target_identity") or {}).get("control") == "pan"', "pan",
     ("Scripts/livekit/live_290_selectors_resolve_by_identity.py",),
     'envelope = d.tool("logic_mixer", "set_pan", {"track": 0, "value": target})'),
    # `r["kind"] == "output"` in the #291 slot harnesses reads the harness's OWN witness key -- the
    # `SLOT` table's key for the row, written by the harness a few lines above the compare -- and
    # not a string Logic displays. The word became localisable on 2026-09-27 when
    # `physicalOutputLabelPrefix` (canonical `output`, Apple's `Output %d-%d` prefix in ten
    # locales) joined the policy; the compare did not change.
    ('r["kind"] == "output"', "output",
     ("Scripts/livekit/live_291_input_slot_is_read.py", "Scripts/livekit/live_291_output_slot_is_read.py"),
     "for r in witness"),
    # The same harness-owned witness key for an input slot, not the Mixer Input filter label.
    ('r["kind"] == "input"', "input", ("Scripts/livekit/live_291_input_slot_is_read.py",),
     "for r in witness"),
    # `observed_position_components` is the reply's list of position-component raw values
    # (TransportDispatcher), `bar` among them, not the localised bar slider. No line pattern saw this
    # one: the parenthesised operand kept `in` from being followed by a word character. Reading the
    # tree found it (#1078, review R2).
    ('"bar" in (o.get("observed_position_components") or [])', "bar",
     ("Scripts/livekit/live_778_japanese_ax_reads_resolve.py",), "lambda o"),
    # Scripts/verify protocol vocabulary (ADR-027 P2 PR-1, #1028): dict keys, a lifecycle event
    # name, a runner branch on the step shape, and the walk's own flag name -- not a string typed
    # at Logic. Measured 2026-09-30 at b2fb4ff4 by pointing the scan at Scripts/verify: 13 hits
    # across 8 files, all these ten words, none a UI matcher. Each is scoped to the files it was
    # measured in. `name == "mute"` is a flag name in live/probes.py and would be an AX title
    # compare in the next harness to write it; a review asked that the exemption not travel. The
    # bindings are the ones each compare had on 2026-10-02, one per name per site.
    ('flag == "solo"', "solo", ("Scripts/verify/live/probes.py",),
     "def flags_show(spec, run, flag=None)"),  # solo implies mute
    ('name == "mute"', "mute", ("Scripts/verify/live/probes.py",),
     "for name in FLAGS"),  # same line as the above
    ('"arm" in row["value_errors"]', "arm", ("Scripts/verify/live/spec_probes.py",),
     "def _armed(row: dict)"),  # which flag's read error
    ('"tracks" in observation', "tracks", ("Scripts/verify/live/tests/test_controls_known.py",),
     ("def zeroed(observation)", "def emptied(observation)")),  # probe shape switch
    ('e["dir"] == "send"', "send", ("Scripts/verify/live/tests/test_mcp.py",),
     "for e in self.server.transcript"),  # transcript message direction
    ('"read" in step', "read", ("Scripts/verify/engine.py", "Scripts/verify/runner.py"),
     ("def reading_of(step: dict) -> tuple", "def _take(ctx: dict, step: dict) -> str")),  # a step's kind
    ('locales == "all"', "all", ("Scripts/verify/engine.py",),
     "def locale_problems(locales) -> list"),  # the verify spec's locale-scope sentinel
    ('spec["locales"] == "all"', "all", ("Scripts/verify/engine.py",),
     "def required_locales(spec: dict) -> list"),  # the same sentinel when expanding that scope
    ('"delete" in op', "delete", ("Scripts/verify/selftest.py",),
     "for op in ops"),  # a fixture-mutation op's kind
    ('"move" in op', "move", ("Scripts/verify/selftest.py",),
     "for op in ops"),  # a fixture-mutation op's kind
    ('case["cmd"][0] == "record"', "record", ("Scripts/verify/selftest.py",),
     "def _run_attested(case: dict, where: dict)"),  # a self-test case's own command
    ('e[0] == "start"', "start", ("Scripts/verify/selftest.py",),
     "for e in life.events"),  # a lifecycle event's kind
)


def _string_value(node):
    """The one string `node` spells, however it is spelled; None when it is computed.

    A constant's escapes, adjacent parts and line breaks are already joined by the parser. An
    f-string with nothing interpolated, and `+` between strings, spell one string as well.
    """
    if isinstance(node, ast.Constant):
        return node.value if isinstance(node.value, str) else None
    if isinstance(node, ast.JoinedStr):
        parts = [_string_value(value) for value in node.values]
        return None if None in parts else "".join(parts)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left, right = _string_value(node.left), _string_value(node.right)
        return None if left is None or right is None else left + right
    return None


def _shape(compare):
    """`ast.dump` of a comparison with each operand that spells a string written as that string."""
    def folded(operand):
        value = _string_value(operand)
        return operand if value is None else ast.Constant(value=value, kind=None)
    return ast.dump(ast.Compare(left=folded(compare.left), ops=compare.ops,
                                comparators=[folded(c) for c in compare.comparators]))


def _comparison(expression, literal):
    """`(shape, side, name)`: the one comparison `expression` is, which operand is `literal`, and the
    one name the other operand reads.

    Read when the module loads, so an entry that is not one comparison of `literal` with one other
    operand reading one name stops the guard instead of becoming an exemption that never matches.
    """
    node = ast.parse(expression, mode="eval").body
    if not isinstance(node, ast.Compare) or len(node.ops) != 1:
        raise ValueError(f"PROTOCOL_EXPRESSIONS: {expression!r} is not one comparison")
    operands = (node.left, node.comparators[0])
    sides = [side for side, operand in enumerate(operands)
             if isinstance(operand, ast.Constant) and isinstance(operand.value, str)
             and operand.value.lower() == literal]
    if len(sides) != 1:
        raise ValueError(f"PROTOCOL_EXPRESSIONS: {expression!r} does not compare {literal!r} "
                         "with one other operand")
    names = {n.id for n in ast.walk(operands[1 - sides[0]]) if isinstance(n, ast.Name)}
    if len(names) != 1:
        raise ValueError(f"PROTOCOL_EXPRESSIONS: {expression!r} reads {sorted(names)!r}, "
                         "not one name")
    return _shape(node), sides[0], names.pop()


def _stored(target):
    return {n.id for n in ast.walk(target) if isinstance(n, ast.Name)}


def _def_key(function):
    return ("def", function.name, ast.dump(function.args),
            ast.dump(function.returns) if function.returns else None)


def _binding_key(source, name):
    """The key of the binding `source` writes for `name`: an assignment, a `def` header, `lambda`
    parameters, or a `for` clause, which is the same key in a statement and in a comprehension."""
    if source.startswith("for "):
        generator = ast.parse(f"[_ {source}]", mode="eval").body.generators[0]
        key, bound = ("for", ast.dump(generator.target), ast.dump(generator.iter)), \
            _stored(generator.target)
    elif source.startswith("def "):
        function = ast.parse(source + ": ...").body[0]
        args = function.args
        key, bound = _def_key(function), {a.arg for a in args.posonlyargs + args.args + args.kwonlyargs}
    elif source.startswith("lambda"):
        function = ast.parse(source + ": ...", mode="eval").body
        args = function.args
        key, bound = ("lambda", ast.dump(args)), {a.arg for a in args.posonlyargs + args.args + args.kwonlyargs}
    else:
        statement = ast.parse(source).body[0]
        if not isinstance(statement, ast.Assign) or len(statement.targets) != 1:
            raise ValueError(f"PROTOCOL_EXPRESSIONS: {source!r} is not one assignment")
        key = ("=", ast.dump(statement.targets[0]), ast.dump(statement.value))
        bound = {statement.targets[0].id} if isinstance(statement.targets[0], ast.Name) else set()
    if name not in bound:
        raise ValueError(f"PROTOCOL_EXPRESSIONS: {source!r} does not bind {name!r}")
    return key


def _expression(expression, literal, where, bindings):
    shape, side, name = _comparison(expression, literal)
    bindings = (bindings,) if isinstance(bindings, str) else bindings
    return shape, where, name, frozenset(_binding_key(b, name) for b in bindings)


_EXPRESSIONS = tuple(_expression(*entry) for entry in PROTOCOL_EXPRESSIONS)
ANY_LITERAL = re.compile(r'"([^"\\\n]{1,80})"')

_FUNCTIONS = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)
_COMPREHENSIONS = (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)
_MATCH_NAMES = tuple(getattr(ast, n) for n in ("MatchAs", "MatchStar") if hasattr(ast, n))
_MATCH_REST = getattr(ast, "MatchMapping", ())


def _evaluated_around(node):
    """The parts of a nested `def`, `lambda` or `class` that run in the scope around it, when the
    statement or expression does: defaults, annotations, decorators, class bases and keywords.
    Review R3 of #1078 found `def inner(x=(step := step["automation_title"])): pass` rebinding
    `step` in the function the entry was measured in, unseen, because the whole nested statement
    was skipped. Its body stays its own scope."""
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
        args = node.args
        parts = list(args.defaults) + [d for d in args.kw_defaults if d is not None]
        if not isinstance(node, ast.Lambda):
            every = args.posonlyargs + args.args + args.kwonlyargs + [a for a in (args.vararg, args.kwarg) if a]
            parts += [a.annotation for a in every if a.annotation is not None]
            parts += list(node.decorator_list) + ([node.returns] if node.returns is not None else [])
        return parts
    if isinstance(node, ast.ClassDef):
        return list(node.decorator_list) + list(node.bases) + [k.value for k in node.keywords]
    return []


def _comprehension_walrus_lines(node, name):
    """Lines of each walrus to `name` that a comprehension makes in the scope around it. A walrus in
    any comprehension binds outside it, so nested comprehensions are entered; a `def`, `lambda` or
    `class` inside it is its own scope, so only what `_evaluated_around` says runs here is entered.
    The review of a1b27a6f found an unrestricted walk counting `lambda: (step := "title")` -- the
    lambda's own local -- as a second binding of the measured name."""
    lines, stack = [], [node]
    while stack:
        current = stack.pop()
        if isinstance(current, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)):
            stack.extend(_evaluated_around(current))
            continue
        if isinstance(current, ast.NamedExpr) and current.target.id == name:
            lines.append(current.lineno)
        stack.extend(ast.iter_child_nodes(current))
    return lines


def _runs_around(scope, child, grandchild):
    """Whether `child` of `scope` (reached through `grandchild`) is evaluated in the scope around
    `scope` rather than in it: a header part of a `def`, `lambda` or `class`, or a comprehension's
    first iterable, which runs before the comprehension's own scope exists."""
    if isinstance(scope, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        return not any(child is statement for statement in scope.body)
    if isinstance(scope, ast.Lambda):
        return child is not scope.body
    if isinstance(scope, _COMPREHENSIONS):
        return child is scope.generators[0] and grandchild is scope.generators[0].iter
    return False


#: The compiler's symbol table of the file being scanned, set by `_scan_root` before it reads the
#: file's comparisons, so `_declared_writes` reads `nonlocal` and `global` the way Python does.
_SYMBOLS = None


def _table_for(root, scope):
    """The symbol table of the module, `def` or `class` statement `scope`, or None."""
    if isinstance(scope, ast.Module):
        return root
    stack = list(root.get_children())
    while stack:
        table = stack.pop()
        if table.get_name() == getattr(scope, "name", None) and table.get_lineno() == scope.lineno \
                and table.get_type() in ("function", "class"):
            return table
        stack.extend(table.get_children())
    return None


def _declared_writes(scope, name):
    """Lines of each nested `def` or `class` body that assigns `name` in `scope` through a
    declaration: `nonlocal` resolving to `scope`, or `global` when `scope` is the module. Review of
    1adc7aa1 (#1078): a class body declaring `nonlocal step` and assigning it rebinds the measured
    parameter, and the binding walk, which does not enter nested bodies, never saw it. A `nonlocal`
    resolves to the nearest enclosing function that binds the name itself, so a write meant for an
    intermediate function is not counted here."""
    if _SYMBOLS is None or not isinstance(scope, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef)):
        return []
    target = _table_for(_SYMBOLS, scope)
    if target is None:
        return []
    module = isinstance(scope, ast.Module)
    lines = []

    def visit(table, between):
        for child in table.get_children():
            if child.get_type() not in ("function", "class"):
                continue
            symbol = child.lookup(name) if name in child.get_identifiers() else None
            if symbol is not None and symbol.is_assigned():
                if module and symbol.is_declared_global():
                    lines.append(("other", child.get_lineno()))
                elif not module and symbol.is_nonlocal():
                    owner = next((t for t in reversed(between) if name in t.get_identifiers()
                                  and t.lookup(name).is_local()), target)
                    if owner is target:
                        lines.append(("other", child.get_lineno()))
            visit(child, between + ([child] if child.get_type() == "function" else []))

    visit(target, [])
    return lines


def _bindings(scope, name):
    """Every binding of `name` that `scope` itself makes, as keys. One no entry can be written as --
    `+=`, `del`, `with`, `except`, an import, a walrus, a `match` capture, a nested `def` or `class`,
    a `global` or `nonlocal` declaration, a second target -- is `("other", line)`. A nested `def`,
    `lambda` or `class` is entered only for what `_evaluated_around` says runs here."""
    keys = []
    if isinstance(scope, _FUNCTIONS):
        args = scope.args
        params = args.posonlyargs + args.args + args.kwonlyargs + [a for a in (args.vararg, args.kwarg) if a]
        if any(p.arg == name for p in params):
            keys.append(("lambda", ast.dump(args)) if isinstance(scope, ast.Lambda) else _def_key(scope))
        stack = list(scope.body) if isinstance(scope.body, list) else [scope.body]
    elif isinstance(scope, _COMPREHENSIONS):
        stack = []
        for index, generator in enumerate(scope.generators):
            if name in _stored(generator.target):
                keys.append(("for", ast.dump(generator.target), ast.dump(generator.iter)))
            stack += list(generator.ifs) + ([generator.iter] if index else [])
        stack += [scope.key, scope.value] if isinstance(scope, ast.DictComp) else [scope.elt]
    else:
        stack = list(scope.body)
    handled = set()
    while stack:
        node = stack.pop()
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if node.name == name:
                keys.append(("other", node.lineno))
            stack.extend(_evaluated_around(node))
            continue
        if isinstance(node, ast.Lambda):
            stack.extend(_evaluated_around(node))
            continue
        if isinstance(node, _COMPREHENSIONS):
            # Its own targets bind inside it; a walrus in it binds here.
            keys += [("other", line) for line in _comprehension_walrus_lines(node, name)]
            continue
        if isinstance(node, (ast.For, ast.AsyncFor)) and name in _stored(node.target):
            keys.append(("for", ast.dump(node.target), ast.dump(node.iter)))
            handled.update(id(n) for n in ast.walk(node.target))
        elif isinstance(node, ast.Assign) and len(node.targets) == 1 \
                and isinstance(node.targets[0], ast.Name) and node.targets[0].id == name:
            keys.append(("=", ast.dump(node.targets[0]), ast.dump(node.value)))
            handled.add(id(node.targets[0]))
        elif isinstance(node, ast.Name) and node.id == name and isinstance(node.ctx, (ast.Store, ast.Del)) \
                and id(node) not in handled:
            keys.append(("other", node.lineno))
        elif isinstance(node, (ast.Global, ast.Nonlocal)) and name in node.names:
            keys.append(("other", node.lineno))
        elif isinstance(node, ast.ExceptHandler) and node.name == name:
            keys.append(("other", node.lineno))
        elif isinstance(node, (ast.Import, ast.ImportFrom)) \
                and any((a.asname or a.name.split(".")[0]) == name for a in node.names):
            keys.append(("other", node.lineno))
        elif (isinstance(node, _MATCH_NAMES) and node.name == name) or \
                (_MATCH_REST and isinstance(node, _MATCH_REST) and node.rest == name):
            keys.append(("other", node.lineno))
        stack.extend(ast.iter_child_nodes(node))
    return keys + _declared_writes(scope, name)


def _resolved(node, name, parents):
    """The bindings of `name` in the scope that resolves it at `node`, or None when none binds it.
    A class body is a scope only for what sits in it directly, as Python reads it, and a scope's
    header is read in the scope around it: a comparison in a decorator is not resolved against the
    parameters of the function it decorates (review R3 of #1078)."""
    inside_function = False
    grandchild, child = None, node
    while child in parents:
        scope = parents[child]
        around = _runs_around(scope, child, grandchild)
        grandchild, child = child, scope
        if around or (isinstance(scope, ast.ClassDef) and inside_function):
            continue
        if isinstance(scope, (*_FUNCTIONS, *_COMPREHENSIONS, ast.ClassDef, ast.Module)):
            keys = _bindings(scope, name)
            if keys:
                return keys
            inside_function = inside_function or not isinstance(scope, ast.ClassDef)
    return None


def _exempt(compare, scope, parents):
    """Whether `compare` IS a PROTOCOL_EXPRESSIONS entry that applies in `scope`, its name bound
    once, by a binding the entry was measured with."""
    if len(compare.ops) != 1:
        return False
    shape = _shape(compare)
    for entry_shape, where, name, bindings in _EXPRESSIONS:
        if shape != entry_shape or (where is not EVERY_HARNESS and scope not in where):
            continue
        keys = _resolved(compare, name, parents)
        if keys is not None and len(keys) == 1 and keys[0] in bindings:
            return True
    return False


def _python_comparisons(tree):
    """`(comparison, operand, string)` for each string a Python comparison reads: either operand of
    `==` / `!=`, the left operand of `in` / `not in` and each element of a tuple, list or set on its
    right, and the first argument of `.startswith` / `.endswith` or each element of a tuple there."""
    for node in ast.walk(tree):
        candidates = []
        if isinstance(node, ast.Compare):
            operands = [node.left, *node.comparators]
            for index, op in enumerate(node.ops):
                left, right = operands[index], operands[index + 1]
                if isinstance(op, (ast.Eq, ast.NotEq)):
                    candidates += [left, right]
                elif isinstance(op, (ast.In, ast.NotIn)):
                    candidates.append(left)
                    if isinstance(right, (ast.Tuple, ast.List, ast.Set)):
                        candidates += right.elts
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
                and node.func.attr in ("startswith", "endswith") and node.args:
            first = node.args[0]
            candidates = list(first.elts) if isinstance(first, ast.Tuple) else [first]
        for operand in candidates:
            value = _string_value(operand)
            if value is not None:
                yield node, operand, value


_SWIFT_UNICODE_ESCAPE = re.compile(r'(?<!\\)\\u\{([0-9A-Fa-f]{1,8})\}')


def _swift_unescaped(line):
    """A Swift line with each `\\u{...}` escape written as its character, so `"re\\u{61}d"` reads as
    the word it spells. A quote, a backslash or a line break stays escaped: written out, it would
    move where the string ends."""
    def one(match):
        code = int(match.group(1), 16)
        if code > 0x10FFFF or chr(code) in '"\\\n\r':
            return match.group(0)
        return chr(code)
    return _SWIFT_UNICODE_ESCAPE.sub(one, line)


def _labels_module():
    spec = importlib.util.spec_from_file_location(
        "locale_labels", os.path.join(REPO, "Scripts", "locale_labels.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def localised_canonicals():
    """Canonicals whose LabelSet carries at least one variant, read from the JSON projection.

    This guard used to re-parse `AXLocalePolicy.swift` itself, which made it a fourth reader of the
    same vocabulary — the exact shape of the defect it exists to catch. `docs/locale/ui-labels.json`
    is generated from the Swift and checked against it by `check-locale-labels-json.py`, so reading
    it here is reading the policy, once.
    """
    return _labels_module().localised_canonicals()


def _docstring_nodes(tree):
    """Every string node that is a docstring — the first statement of a module, class or function."""
    out = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = getattr(node, "body", None) or []
            if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) \
               and isinstance(body[0].value.value, str):
                out.add(id(body[0].value))
    return out


def _continues_name(character):
    """Whether `character` can continue a Python identifier. A combining mark can and is not `\\w`."""
    return bool(character) and ("a" + character).isidentifier()


def _hits(text, known_canonicals, patterns, site=None):
    """(literal, policy name) once per OCCURRENCE, not once per pattern that matched it.

    `site` is the repository-relative path the text came from. A scoped PROTOCOL_COMPARISONS entry
    applies only there, so a text with no file behind it gets the unscoped entries alone.

    Two patterns both match `whose name ends with "Tracks"`, so one matcher scored two hits. A
    review turned that into an attack: replace it with a single `window "Tracks"` (one hit) and add
    a second `window "Tracks"` elsewhere (one more) — the file now carries two defects instead of
    one and the count is unchanged. Occurrences are deduplicated by their position in the text, so
    a matcher counts once however many patterns recognise it.
    """
    found = []
    seen_spans = set()
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith(("#", "//", "*")):
            continue
        # The exemption is keyed by the literal AND the expression, which is what the comment on
        # PROTOCOL_COMPARISONS has always said. The code used to `continue` on the whole LINE as
        # soon as any marker matched, so one exempt word silently exempted every OTHER localisable
        # string sharing that line. Found 2026-09-15 by adding a marker for `tell process "Logic
        # Pro"`: three real `'Save'` findings vanished with it. A line-wide skip is an exemption
        # that grows on its own.
        exempt_spans = set()
        for marker, lit, where in PROTOCOL_COMPARISONS:
            if where is not EVERY_HARNESS and site not in where:
                continue
            quoted = f'"{lit}"'
            literal_offset = marker.lower().rfind(quoted) + 1
            for marker_match in re.finditer(re.escape(marker), line):
                if _continues_name(marker[:1]) and \
                        _continues_name(line[marker_match.start() - 1:marker_match.start()]):
                    continue
                if literal_offset:
                    start = marker_match.start() + literal_offset
                    exempt_spans.add((start, start + len(lit)))
                elif marker == 'every process whose ':
                    # This marker ends before the process name. Only its name predicate is exempt.
                    process_name = re.match(
                        r'name\s+(?:is|contains|starts with|ends with)\s+"(Logic Pro)"',
                        line[marker_match.end():])
                    if process_name:
                        start = marker_match.end() + process_name.start(1)
                        exempt_spans.add((start, start + len(process_name.group(1))))
        for pattern in patterns:
            for match in pattern.finditer(line):
                literal = match.group("lit") if "lit" in (match.re.groupindex or {}) else match.group(1)
                literal_span = match.span("lit") if "lit" in (match.re.groupindex or {}) \
                    else match.span(1)
                if literal_span in exempt_spans:
                    continue
                name = known_canonicals.get(literal.strip().lower())
                if not name:
                    continue
                span = (lineno, literal_span[0], literal)
                if span in seen_spans:
                    continue
                seen_spans.add(span)
                found.append((literal, name))
    return found


def _scan_root(root, label, key, known_canonicals, swift_recursive=False):
    """found entries `(key(path), literal, lineno, policy_name)` for every `*.py` and `*.swift`
    file under `root`. `key` turns a path into the identity `KNOWN` is keyed on -- a basename for
    Scripts/livekit, a root-relative path for Scripts/verify, where two files can share a
    basename. `swift_recursive` defaults False so Scripts/livekit's swift scan is exactly the
    top-level-only glob it always was; Scripts/verify has no swift today, and the outcome this
    root was added for is `Scripts/verify/**`, so it opts into `**`. `label` is the root's
    repository-relative name, so a file's scope for PROTOCOL_COMPARISONS is the same whether the
    root is the real tree or a test's copy of it."""
    found = []
    for path in sorted(glob.glob(os.path.join(root, "**", "*.py"), recursive=True)):
        site = key(path)
        scope = f"{label}/{os.path.relpath(path, root)}"
        source = open(path, encoding="utf-8", errors="replace").read()
        try:
            tree = ast.parse(source)
        except SyntaxError:
            print(f"  {site}: does not parse — not scanned")
            continue
        global _SYMBOLS
        # The compiler can refuse what the parser accepts -- Python 3.14 refuses a walrus in an
        # annotation -- and such a file cannot run either. It is still scanned; only the
        # declaration check, which needs the symbol table, is left out.
        try:
            _SYMBOLS = symtable.symtable(source, path, "exec")
        except SyntaxError:
            _SYMBOLS = None
        skip = _docstring_nodes(tree)
        # Pass 1: AppleScript, which lives inside string constants.
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in skip:
                for literal, name in _hits(node.value, known_canonicals, APPLESCRIPT_PREDICATES,
                                           scope):
                    found.append((site, literal, getattr(node, "lineno", 0), name))
        # Pass 2: Python comparisons, read from the same tree (#1078, review R2). A line pattern read
        # a literal as its line spelled it, so an escape, adjacent strings, a string continued on the
        # next line or a parenthesised operand hid a UI comparison from it. The tree has the value.
        # A value computed any other way is not read: a name bound to a string, `.lower()`, `%`,
        # `.format`, `.join`, `re`, `str.startswith(title, ...)`. Measured 2026-10-02: eleven
        # operands in ten comparisons, in five files under the two roots, compare against a name
        # bound to a localised word (`EDGE_SEND`, `KIND_BUS` and the like), and none is reported.
        parents = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}
        read = set()
        for comparison, operand, value in _python_comparisons(tree):
            if id(operand) in read:
                continue
            read.add(id(operand))
            name = known_canonicals.get(value.strip().lower())
            if not name:
                continue
            if isinstance(comparison, ast.Compare) and _exempt(comparison, scope, parents):
                continue
            found.append((site, value, operand.lineno, name))
    # Swift drivers have no docstrings; a leading `//` is the only prose marker they use.
    swift_glob = os.path.join(root, "**", "*.swift") if swift_recursive else os.path.join(root, "*.swift")
    for path in sorted(glob.glob(swift_glob, recursive=swift_recursive)):
        site = key(path)
        scope = f"{label}/{os.path.relpath(path, root)}"
        for lineno, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
            for literal, name in _hits(_swift_unescaped(line), known_canonicals,
                                       APPLESCRIPT_PREDICATES + PYTHON_PREDICATES, scope):
                found.append((site, literal, lineno, name))
    return found


def offenders(known_canonicals):
    # Every occurrence is returned. `main` aggregates by (site, literal) and compares the COUNT
    # against `KNOWN`, which is what stops an already-listed site from absorbing further copies.
    # Deduplicating here — the earlier shape — threw away exactly the number the ratchet needs.
    found = _scan_root(LIVEKIT, "Scripts/livekit", os.path.basename, known_canonicals)
    found += _scan_root(VERIFY, "Scripts/verify", lambda path: os.path.relpath(path, VERIFY),
                        known_canonicals, swift_recursive=True)
    return found


def main():
    canonicals = localised_canonicals()
    if not canonicals:
        print("docs/locale/ui-labels.json carries no localised label — refusing to report a pass "
              "from an empty vocabulary; run Scripts/locale_labels.py --write")
        return 1
    found = offenders(canonicals)

    counts = {}
    first_line = {}
    for base, literal, lineno, policy_name in found:
        key = (base, literal)
        counts[key] = counts.get(key, 0) + 1
        first_line.setdefault(key, (lineno, policy_name))

    new = sorted(k for k in counts if k not in KNOWN)
    grew = sorted(k for k in counts if k in KNOWN and counts[k] > KNOWN[k])
    shrank = sorted(k for k in counts if k in KNOWN and counts[k] < KNOWN[k])
    gone = sorted(k for k in KNOWN if k not in counts)

    if new:
        print(f"{len(new)} live-harness UI literal(s) that only one language spells that way:")
        for base, literal in new:
            lineno, policy_name = first_line[(base, literal)]
            print(f"  {base}:{lineno}  {literal!r} — AXLocalePolicy.{policy_name} carries variants")
        print("\n  Interpolate the spelling from a table instead of writing it in:")
        print("    for name in NAMES:  osa(f\'... menu bar item \"{name}\" ...\')")
        print("  measured rather than translated, and tried in turn until one answers.")
    if grew:
        print(f"\n{len(grew)} known site(s) gained matchers — the list absorbs no new copies:")
        for key in grew:
            print(f"  {key[0]}  {key[1]!r}: {KNOWN[key]} -> {counts[key]}")
    if shrank or gone:
        print(f"\n{len(shrank) + len(gone)} known entr(y|ies) improved — update KNOWN so the next "
              "regression cannot fall back:")
        for key in shrank:
            print(f"  {key[0]}  {key[1]!r}: {KNOWN[key]} -> {counts[key]}")
        for key in gone:
            print(f"  {key[0]}  {key[1]!r}: gone, delete the entry")
    if new or grew or shrank or gone:
        return 1
    print(f"no new live-harness UI literals ({len(KNOWN)} sites, "
          f"{sum(KNOWN.values())} matchers, awaiting a locale measurement)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
