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

A line carrying a non-ASCII literal is exempt: that is an alias table, which is the fix.

Python files are parsed rather than scanned line by line, because these harnesses hold their
AppleScript in triple-quoted strings and a line-based reader cannot tell one from a docstring. The
first attempt skipped every triple-quoted block and lost two real sites; treating them all as code
would have flagged prose in three module headers. `ast` separates them exactly: a docstring is the
first statement of its module or function, and everything else is a payload.

## The known list only shrinks

Enforcing this outright would turn thirteen harnesses red at once, and the predictable next move is
that somebody deletes the guard — the reasoning `evidence.py` already records for
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
KNOWN = {
    ("live_290_shifted_strips_are_refused.py", "View"),
    ("live_290_shifted_strips_are_refused.py", "Mixer"),
    ("live_448_track_stack_readback.py", "Edit"),
    ("live_523_marker_delete.py", "Marker"),
    ("live_523_marker_delete.py", "Number of Items"),
    ("live_538_modal_reconcile.py", "Tracks"),
    ("live_542_track_create_retry.py", "Tracks"),
    ("live_549_cell_does_not_veto.py", "Tracks"),
    ("live_549_cell_does_not_veto.py", "Delete"),
    ("live_549_cell_does_not_veto.py", "Cancel"),
    ("live_549_cell_does_not_veto.py", "Open Marker List"),
    ("live_549_cell_does_not_veto.py", "Navigate"),
    ("live_549_receipt_names_the_node.py", "Tracks"),
    ("live_575_move_to_playhead_reachable.py", "Edit"),
    ("live_576_completeness_is_measured.py", "Tracks"),
    ("live_590_project_new_from_cold_launch.py", "Cancel"),
    ("live_606_save_as_writes_the_file.py", "Save"),
    ("live_608_first_call_is_not_refused.py", "Save"),
    ("live_614_the_refusal_it_can_still_reach.py", "Save"),
    ("live_628_mixer_fallback_is_visible.py", "View"),
    ("live_628_mixer_fallback_is_visible.py", "Mixer"),
}

_ELEMENT = r"menu bar item|menu item|checkbox|button|window|radio button|static text|group"
PREDICATES = [
    re.compile(rf'(?:{_ELEMENT})\s+"([^"]+)"'),
    re.compile(r'whose\s+(?:name|description|title|help)\s+(?:is|contains|starts with|ends with)\s+"([^"]+)"'),
    re.compile(r'\b(?:starts with|ends with)\s+"([^"]+)"'),
    # `(description of contents of k) is "Number of Items"` — an attribute compared directly, which
    # `whose … is` does not cover. Anchored on the attribute word so a bare `is "…"` stays out.
    re.compile(r'(?:description|name|title|help)\s+of\s+[^"\n]{0,60}?(?:is|contains)\s+"([^"]+)"'),
    re.compile(r'\.(?:startswith|endswith)\(\s*"([^"]+)"'),
    re.compile(r'(?:help|description|title|name)\w*\s*==\s*"([^"]+)"'),
]
ANY_LITERAL = re.compile(r'"([^"\\\n]{1,80})"')


def localised_canonicals():
    """Canonicals whose LabelSet carries at least one variant, read from the JSON projection.

    This guard used to re-parse `AXLocalePolicy.swift` itself, which made it a fourth reader of the
    same vocabulary — the exact shape of the defect it exists to catch. `docs/locale/ui-labels.json`
    is generated from the Swift and checked against it by `check-locale-labels-json.py`, so reading
    it here is reading the policy, once.
    """
    spec = importlib.util.spec_from_file_location(
        "locale_labels", os.path.join(REPO, "Scripts", "locale_labels.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.localised_canonicals()


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


def _hits(text, known_canonicals):
    """(literal, policy name) for every UI-matching literal in `text` the policy knows is localised."""
    found = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(("#", "//", "*")):
            continue
        literals = ANY_LITERAL.findall(line)
        if any(any(ord(ch) > 127 for ch in lit) for lit in literals):
            continue                          # an alias table: the English spelling has company
        for pattern in PREDICATES:
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
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in skip:
                for literal, name in _hits(node.value, known_canonicals):
                    found.append((base, literal, getattr(node, "lineno", 0), name))
    # Swift drivers have no docstrings; a leading `//` is the only prose marker they use.
    for path in sorted(glob.glob(os.path.join(LIVEKIT, "*.swift"))):
        base = os.path.basename(path)
        for lineno, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
            for literal, name in _hits(line, known_canonicals):
                found.append((base, literal, lineno, name))
    return found


def main():
    canonicals = localised_canonicals()
    if not canonicals:
        print("docs/locale/ui-labels.json carries no localised label — refusing to report a pass "
              "from an empty vocabulary; run Scripts/locale_labels.py --write")
        return 1
    found = offenders(canonicals)
    seen = {(base, literal) for base, literal, _, _ in found}

    new = [f for f in found if (f[0], f[1]) not in KNOWN]
    stale = sorted(KNOWN - seen)

    if new:
        print(f"{len(new)} live-harness UI literal(s) that only one language spells that way:")
        for base, literal, lineno, policy_name in new:
            print(f"  {base}:{lineno}  {literal!r} — AXLocalePolicy.{policy_name} carries variants")
        print("\n  Put the spellings in a table beside it, measured rather than translated, and match")
        print("  against every entry. A line carrying a non-ASCII literal is exempt.")
    if stale:
        print(f"\n{len(stale)} known-list entr(y|ies) no longer present — delete them, the list only shrinks:")
        for base, literal in stale:
            print(f"  ({base!r}, {literal!r})")
    if new or stale:
        return 1
    print(f"no new live-harness UI literals ({len(KNOWN)} known, awaiting a locale measurement)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
