#!/usr/bin/env python3
"""`AXLocalePolicy.MatchMode.template` has exactly one user: `editUndoMenuPath` (#904).

`.template` matches a title against a label holding one `%@` -- Apple's `Undo %@`, which ko, de and
zh_TW put the operation inside of. It is deliberately narrow (both fixed parts must match and the
part between must be non-empty), and it is narrow FOR ONE CONSUMER: the Edit-menu Undo entry, whose
title is a template Apple ships. A second set read with it would be a set matched by a shape nobody
derived for it, so the mode is refused anywhere else until someone argues for that in a change of
their own.

What counts as a use is an implicit `.template` outside a comment. Allowed:

  * `case .template:` -- a `switch` over MatchMode has to name every case, which is not a user;
  * the one declaration `static let editUndoMenuPath = MenuPath(bar: editMenuBar,
    item: undoMenuItemPrefix, itemMode: .template)`.

Anything else is refused, and so is the absence of that declaration: a mode with no user is dead
code that a later reader will assume is wired.

Limit: this reads Swift as text under Sources/. A `.template` reached through a variable of type
MatchMode (`let m = mode; m == ...`) is not seen; a spelling `AXLocalePolicy.MatchMode.template`
is, because the dot before `template` follows a word character and is matched separately below.
"""
import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.environ.get("LPM_TEMPLATE_SOURCES") or os.path.join(REPO, "Sources")

ALLOWED_DECLARATION = re.compile(
    r"static\s+let\s+editUndoMenuPath\s*=\s*MenuPath\(\s*bar:\s*editMenuBar,\s*"
    r"item:\s*undoMenuItemPrefix,\s*itemMode:\s*\.template\s*\)")
CASE_LABEL = re.compile(r"\bcase\s+\.template\b")
ANY_USE = re.compile(r"(?<![\w)\]])\.template\b|\bMatchMode\s*\.\s*template\b")


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", lambda m: " " * len(m.group(0)), text, flags=re.S)
    return re.sub(r"(?<!:)//[^\n]*", "", text)


def problems_in(sources):
    found, out = 0, []
    for path in sorted(glob.glob(os.path.join(sources, "**", "*.swift"), recursive=True)):
        with open(path, encoding="utf-8", errors="replace") as handle:
            body = strip_comments(handle.read())
        rel = os.path.relpath(path, sources)
        declared = ALLOWED_DECLARATION.findall(body)
        if declared and os.path.basename(path) != "AXLocalePolicy.swift":
            out.append(f"{rel}: declares editUndoMenuPath outside AXLocalePolicy.swift")
        found += len(declared)
        rest = CASE_LABEL.sub("", ALLOWED_DECLARATION.sub("", body))
        for match in ANY_USE.finditer(rest):
            line = rest.count("\n", 0, match.start()) + 1
            out.append(f"{rel}:{line}: uses MatchMode.template, whose only user is editUndoMenuPath")
    if found != 1:
        out.append(f"editUndoMenuPath is declared with `itemMode: .template` {found} time(s), not once")
    return out


def main():
    problems = problems_in(SOURCES)
    if problems:
        print(f"{len(problems)} problem(s) with MatchMode.template:")
        for problem in problems:
            print("  " + problem)
        return 1
    print("MatchMode.template has one user: editUndoMenuPath")
    return 0


if __name__ == "__main__":
    sys.exit(main())
