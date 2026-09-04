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
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIVEKIT = os.path.join(REPO, "Scripts", "livekit")

# Sites that existed when this rule was written, keyed by (file, literal) rather than by line, so
# editing a file elsewhere does not silently re-arm or disarm an entry. This list may only shrink.
# Sites present when this rule was written, with HOW MANY matchers each carries. The count is the
# part an outside review found missing: keyed by `(file, literal)` alone, a file already listed for
# "View" could gain any number of further "View" matchers and still pass, because occurrences were
# deduplicated before the comparison. A list that hides unbounded new copies of a defect is not a
# ratchet. Counts may only fall; a site that gains one is reported.
KNOWN = {
    ("live_290_selectors_resolve_by_identity.py", "pan"): 1,
    ("live_290_shifted_strips_are_refused.py", "Mixer"): 1,
    ("live_290_shifted_strips_are_refused.py", "View"): 1,
    ("live_291_input_slot_is_read.py", "send"): 1,
    ("live_291_output_slot_is_read.py", "send"): 1,
    ("live_448_track_stack_readback.py", "Edit"): 1,
    ("live_448_track_stack_readback.py", "Tracks"): 1,
    ("live_519_region_op_on_a_localized_logic.py", "Edit"): 3,
    ("live_519_region_op_on_a_localized_logic.py", "Tracks"): 3,
    ("live_523_marker_delete.py", "Marker"): 2,
    ("live_523_marker_delete.py", "Number of Items"): 3,
    ("live_538_modal_reconcile.py", "Tracks"): 2,
    ("live_549_cell_does_not_veto.py", "Cancel"): 2,
    ("live_549_cell_does_not_veto.py", "Delete"): 1,
    ("live_549_cell_does_not_veto.py", "Navigate"): 1,
    ("live_549_cell_does_not_veto.py", "Open Marker List"): 1,
    ("live_549_cell_does_not_veto.py", "Tracks"): 3,
    ("live_549_receipt_names_the_node.py", "Tracks"): 2,
    ("live_572_record_sequence_first_call.py", "Tracks"): 1,
    ("live_575_move_to_playhead_identity.py", "Tracks"): 1,
    ("live_575_move_to_playhead_reachable.py", "Edit"): 2,
    ("live_575_region_stub_rows_retired.py", "Tracks"): 1,
    ("live_575_retired_routes_change_nothing.py", "Tracks"): 1,
    ("live_576_completeness_is_measured.py", "Tracks"): 3,
    ("live_576_viewport_limited_region_readback.py", "Tracks"): 1,
    ("live_590_project_new_from_cold_launch.py", "Cancel"): 1,
    ("live_590_project_new_from_cold_launch.py", "Save"): 1,
    ("live_590_project_new_from_cold_launch.py", "Tracks"): 4,
    ("live_592_stub_rows_retired.py", "Tracks"): 1,
    ("live_606_save_as_writes_the_file.py", "Save"): 3,
    ("live_608_first_call_is_not_refused.py", "Save"): 4,
    ("live_608_first_call_is_not_refused.py", "Save As…"): 1,
    ("live_614_the_refusal_it_can_still_reach.py", "Save"): 3,
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
PYTHON_PREDICATES = [
    re.compile(r'\.(?:startswith|endswith)\(\s*"([^"]+)"'),
    re.compile(r'(?:==|!=)\s*"([^"]+)"'),
    re.compile(r'"([^"]+)"\s*(?:==|!=)'),
    re.compile(r'"([^"]+)"\s+in\s+\w'),
]
ANY_LITERAL = re.compile(r'"([^"\\\n]{1,80})"')


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


def _hits(text, known_canonicals, patterns):
    """(literal, policy name) for every UI-matching literal in `text` the policy knows is localised."""
    found = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(("#", "//", "*")):
            continue
        for pattern in patterns:
            for literal in pattern.findall(line):
                name = known_canonicals.get(literal.strip().lower())
                if name:
                    found.append((literal, name))
    return found


def offenders(known_canonicals):
    found = []
    for path in sorted(glob.glob(os.path.join(LIVEKIT, "**", "*.py"), recursive=True)):
        base = os.path.basename(path)
        source = open(path, encoding="utf-8", errors="replace").read()
        try:
            tree = ast.parse(source)
        except SyntaxError:
            print(f"  {base}: does not parse — not scanned")
            continue
        skip = _docstring_nodes(tree)
        # Pass 1: AppleScript, which lives inside string constants.
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in skip:
                for literal, name in _hits(node.value, known_canonicals, APPLESCRIPT_PREDICATES):
                    found.append((base, literal, getattr(node, "lineno", 0), name))
        # Pass 2: Python comparisons, which live in the source. Docstrings are removed so a
        # paragraph quoting `help.startswith("Tracks")` is prose, not a matcher.
        prose = [n.value for n in ast.walk(tree)
                 if isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) in skip]
        code = source
        for doc in prose:
            code = code.replace(doc, "")
        for lineno, line in enumerate(code.splitlines(), 1):
            for literal, name in _hits(line, known_canonicals, PYTHON_PREDICATES):
                found.append((base, literal, lineno, name))
    # Swift drivers have no docstrings; a leading `//` is the only prose marker they use.
    for path in sorted(glob.glob(os.path.join(LIVEKIT, "*.swift"))):
        base = os.path.basename(path)
        for lineno, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
            for literal, name in _hits(line, known_canonicals,
                                       APPLESCRIPT_PREDICATES + PYTHON_PREDICATES):
                found.append((base, literal, lineno, name))
    # Every occurrence is returned. `main` aggregates by (file, literal) and compares the COUNT
    # against `KNOWN`, which is what stops an already-listed site from absorbing further copies.
    # Deduplicating here — the earlier shape — threw away exactly the number the ratchet needs.
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
