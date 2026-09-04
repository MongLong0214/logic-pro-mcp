#!/usr/bin/env python3
"""Refuse `entire contents` inside a string literal.

`entire contents of <window>` returns an EMPTY list, without raising, for every application on this
host — measured 2026-09-04 at 0 against 464 elements found by a manual descent of the same Logic
window, and at 0 for nine other foreground applications, each of which has direct children. #767.

That silence is the whole problem. A traversal built on it does not fail; it reports that the thing
it was looking for is absent, and every caller reads absence as a fact about the application. It
cost this repository a shipped operation that answered NO_REGION for projects that had regions, and
two documented AX-opacity conclusions that turned out to be conclusions about the instrument. One
of them said the Channel EQ exposes no per-band slider; a manual descent of the same window finds
twenty-six of them, each named and carrying a value.

**The rule is about string literals, not about the words.** A comment explaining why the instrument
is broken is exactly what a repository should keep, and there are eleven of those. What must not
come back is the phrase in something that gets sent to AppleScript. Checking literals rather than
lines is what lets those two coexist without an allowlist — and an allowlist is what this guard
must not have, because a list of permitted uses is how a banned instrument returns.

Exit 0 when clean, 1 with the offending sites otherwise.
"""
import ast
import re
import sys
from pathlib import Path

BANNED = "entire contents"

ROOTS = ("Sources", "Scripts")

# Swift has no stdlib parser here, so the literals are found by pattern. Triple-quoted first, because
# a multi-line AppleScript block is the shape that actually carries this call, and matching `"..."`
# first would cut those blocks apart at the wrong quotes.
SWIFT_MULTILINE = re.compile(r'"""(.*?)"""', re.S)
SWIFT_SINGLELINE = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def _swift_literals(source):
    """(line number, text) for every string literal in a Swift source."""
    out = []
    consumed = []
    for m in SWIFT_MULTILINE.finditer(source):
        out.append((source.count("\n", 0, m.start()) + 1, m.group(1)))
        consumed.append((m.start(), m.end()))
    def inside_multiline(pos):
        return any(a <= pos < b for a, b in consumed)
    for m in SWIFT_SINGLELINE.finditer(source):
        if inside_multiline(m.start()):
            continue
        out.append((source.count("\n", 0, m.start()) + 1, m.group(1)))
    return out


def _exempt_nodes(tree):
    """Every Constant that is prose or a definition rather than a call, by identity.

    A docstring is a string literal to the parser and prose to everyone else, and the prose about
    this instrument is worth keeping — this file's own header is an example. Skipping them by
    identity rather than by position is what keeps `\"\"\"…\"\"\"` used as an actual AppleScript block
    from being skipped along with them.
    """
    out = set()
    # The literal that DEFINES the banned phrase is not a use of it, and exempting it by rule beats
    # exempting this file by name: a path allowlist would clear every future use in this file too.
    for node in getattr(tree, "body", []):
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) \
                and any(isinstance(t, ast.Name) and t.id == "BANNED" for t in node.targets):
            out.add(id(node.value))
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        body = getattr(node, "body", None)
        if not body:
            continue
        first = body[0]
        if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \
                and isinstance(first.value.value, str):
            out.add(id(first.value))
    return out


def _python_literals(source, path):
    try:
        tree = ast.parse(source)
    except SyntaxError:
        # A file this guard cannot parse is not a file it can clear. Say so rather than pass it.
        return None
    skip = _exempt_nodes(tree)
    out = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in skip:
            out.append((node.lineno, node.value))
    return out


def violations(repo_root):
    found = []
    unparsed = []
    for root in ROOTS:
        base = repo_root / root
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if path.suffix not in (".swift", ".py"):
                continue
            try:
                source = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            if BANNED not in source:          # cheap reject before any parsing
                continue
            if path.suffix == ".py":
                literals = _python_literals(source, path)
                if literals is None:
                    unparsed.append(path.relative_to(repo_root))
                    continue
            else:
                literals = _swift_literals(source)
            for lineno, text in literals:
                if BANNED in text:
                    found.append((path.relative_to(repo_root), lineno, text.strip()[:90]))
    return found, unparsed


def main():
    repo_root = Path(__file__).resolve().parent.parent
    found, unparsed = violations(repo_root)
    if not found and not unparsed:
        print(f"no string literal sends `{BANNED}` to AppleScript")
        return 0
    for path, lineno, text in found:
        print(f"{path}:{lineno}: `{BANNED}` in a string literal -> {text}")
    for path in unparsed:
        print(f"{path}: contains `{BANNED}` and could not be parsed, so it is not cleared")
    print()
    print(f"{len(found) + len(unparsed)} site(s). `{BANNED}` returns an empty list without")
    print("raising on this host, so a traversal built on it reports absence instead of failing.")
    print("Walk the tree explicitly instead — AXHelpers.findAllDescendants on the Swift side, or a")
    print("recursion over `UI elements of` in AppleScript.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
