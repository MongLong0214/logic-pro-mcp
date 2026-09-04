#!/usr/bin/env python3
"""Refuse `entire contents` inside a string literal.

`entire contents of <window>` returns an EMPTY list, without raising, for every application it was
tried on here — measured 2026-09-04 at 0 against 464 elements found by a manual descent of the same
Logic window, and at 0 for nine other foreground applications, each of which has direct children.
Ten applications is what was tested; it is not a statement about every installed one. #767.

That silence is the whole problem. A traversal built on it does not fail; it reports that the thing
it was looking for is absent, and every caller reads absence as a fact about the application. It
cost this repository a shipped operation that answered NO_REGION for projects that had regions, and
two documented AX-opacity conclusions that turned out to be conclusions about the instrument. One
of them said the Channel EQ exposes no per-band slider; a manual descent of the same window finds
twenty-six of them, each named and carrying a value.

**The rule is about string literals, not about the words.** A comment explaining why the instrument
is broken is exactly what a repository should keep, and there are eleven such occurrences across
six files under `Sources/` and `Scripts/`, outside this guard and its test. What must not
come back is the phrase in something that gets sent to AppleScript. Checking literals rather than
lines is what lets those two coexist without an allowlist — and an allowlist is what this guard
must not have, because a list of permitted uses is how a banned instrument returns.

## What this does NOT catch, said plainly

A literal rule sees literals. `"entire" + " contents"`, an f-string interpolating the phrase from a
variable, or a script read at run time from a file all reach AppleScript without any single literal
carrying the words, and this guard passes them. That hole cannot be closed by pattern-matching
harder — `"ent" + "ire contents"` defeats any pair rule — and it is not hypothetical: this guard's
own self-test assembles its fixtures exactly that way, for the good reason that a test for a banned
phrase should not contain it.

Docstrings are exempt because they are prose, and a docstring is also reachable at run time as
`__doc__` — so `subprocess.run(["osascript", "-e", payload.__doc__])` passes. That is left open on
purpose: closing it means flagging every paragraph in the tree that explains why this instrument is
broken, and those paragraphs are the reason anyone will understand a future failure.

So the boundary is: this stops the phrase from being TYPED back into a call, which is how it got
here the first time and how it would return. It does not stop someone who is deliberately routing
around it. That is the honest shape of the rule, and a guard that claimed more would be the second
instrument in this story that answered a question it could not see.

Exit 0 when clean, 1 with the offending sites otherwise.
"""
import ast
import re
import sys
from pathlib import Path

# Assembled, not written out. A literal here would either trip the rule or need an exemption,
# and an exemption keyed on the NAME `BANNED` was exactly the hole: any file in the tree could
# declare `BANNED = "…"` and then use it. Assembling costs one line and removes the rule.
BANNED = "entire" + " " + "contents"

# `docs/` is in scope too: the evidence runners under docs/tickets shell out to osascript, and a
# script is a script wherever it is filed.
ROOTS = ("Sources", "Scripts", "docs")

# Swift has no stdlib parser here, so the literals are found by pattern. Triple-quoted first, because
# a multi-line AppleScript block is the shape that actually carries this call, and matching `"..."`
# first would cut those blocks apart at the wrong quotes.
SWIFT_MULTILINE = re.compile(r'"""(.*?)"""', re.S)
SWIFT_SINGLELINE = re.compile(r'"((?:[^"\\\n]|\\.)*)"')

# Shell and JavaScript get a LINE rule rather than a literal rule. Neither can be parsed for string
# literals here, and both can reach osascript — `Scripts` carries 25 shell scripts and two of them
# already shell out to it. A line rule over-approximates, and over-approximating is the right
# direction: the cost is that prose has to live in a comment, which is where prose lives anyway.
SHELL_COMMENT = re.compile(r"^\s*#")
JS_COMMENT = re.compile(r"^\s*(//|/\*|\*)")


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
    """Every Constant that is a docstring, by identity.

    A docstring is a string literal to the parser and prose to everyone else, and the prose about
    this instrument is worth keeping — this file's own header is an example. Skipping them by
    identity rather than by position is what keeps `\"\"\"…\"\"\"` used as an actual AppleScript block
    from being skipped along with them.
    """
    out = set()
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
        if not isinstance(node, ast.Constant) or id(node) in skip:
            continue
        # bytes as well as str: `subprocess.run([b"osascript", b"-e", b"…"])` reaches osascript
        # exactly like the text form and contains no str constant at all, so a str-only rule reads
        # the file as clean while the phrase is right there in the source.
        if isinstance(node.value, str):
            out.append((node.lineno, node.value))
        elif isinstance(node.value, bytes):
            out.append((node.lineno, node.value.decode("utf-8", "replace")))
    return out


def violations(repo_root):
    found = []
    unparsed = []
    for root in ROOTS:
        base = repo_root / root
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if path.suffix not in (".swift", ".py", ".sh", ".js"):
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
            elif path.suffix == ".swift":
                literals = _swift_literals(source)
            else:
                comment = SHELL_COMMENT if path.suffix == ".sh" else JS_COMMENT
                literals = [(n, line) for n, line in enumerate(source.splitlines(), 1)
                            if not comment.match(line)]
            for lineno, text in literals:
                if BANNED in text:
                    found.append((path.relative_to(repo_root), lineno, text.strip()[:90]))
    return found, unparsed


def main(argv=None):
    # An optional root so the self-test can run this entry point — not just `violations` — over a
    # tree with a planted violation. Without it a `main` gutted to `return 0` would pass every test.
    argv = list(sys.argv[1:] if argv is None else argv)
    repo_root = Path(argv[0]).resolve() if argv else Path(__file__).resolve().parent.parent
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
