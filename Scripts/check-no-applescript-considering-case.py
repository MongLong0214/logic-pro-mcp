#!/usr/bin/env python3
"""Refuse `considering case` inside a string literal.

Every localized lookup this product makes is CASE-FOLDED, and that fold is load-bearing in two
places. The Python side compares against `value.lower()`. The AppleScript side splices the same
folded tables into element specifiers -- `menu bar item (barName as text)` -- and that works
because AppleScript string comparison ignores case by default.

`considering case` turns that default off for the block it encloses. Inside one, every spliced
comparison stops matching, in every language at once, and the failure is SILENT: the specifier
finds nothing, the drive reports the element is absent, and absence reads as a fact about Logic.
That is the shape #919's two-language tables had -- a wrong answer that looks like a measurement.

`Scripts/locale_labels.py` has said for a while that the fold holds "unless a script says
`considering case`, which none of ours does". That was prose, and prose does not fail. This is the
check.

**The rule is about string literals, not about the words.** A comment naming the phrase is exactly
what a repository should keep -- `locale_labels.py` carries one and so does this file. What must
not come back is the phrase in something that gets sent to AppleScript. Checking literals rather
than lines is what lets those coexist without an allowlist, and an allowlist is what this guard
must not have: a list of permitted uses is how a banned instrument returns.

## What this does NOT catch, said plainly

A literal rule sees literals. Assembling the phrase from pieces, interpolating it from a variable,
or reading a script from a file at run time all reach AppleScript without any single literal
carrying the words. That hole cannot be closed by pattern-matching harder, and it is not
hypothetical -- this guard's own self-test builds its fixtures exactly that way, for the good
reason that a test for a banned phrase should not contain it.
"""
import ast
import os
import re
import sys
from pathlib import Path

# Assembled, not written out. A literal here would either trip the rule or need an exemption,
# and an exemption keyed on the NAME `BANNED` was exactly the hole: any file in the tree could
# declare `BANNED = "…"` and then use it. Assembling costs one line and removes the rule.
BANNED = "considering" + " " + "case"

# `docs/` is in scope too: the evidence runners under docs/tickets shell out to osascript, and a
# script is a script wherever it is filed.
#: A seam, so the self-test can drive `main()` at a tree that MUST fail. Without one the
#: positive case is inexpressible and the suite can only prove the guard accepts this
#: repository -- which is what a guard that refuses nothing also does.
ROOTS = tuple(
    os.environ.get("LPM_APPLESCRIPT_ROOTS", "").split(os.pathsep)
) if os.environ.get("LPM_APPLESCRIPT_ROOTS") else ("Sources", "Scripts", "docs")

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


SWIFT_UNICODE_ESCAPE = re.compile(r"\\u\{([0-9A-Fa-f]{1,8})\}")


def _decode_swift(text):
    """Resolve the escapes Swift resolves, so the rule reads what the compiler emits.

    `"entire\\u{20}contents"` is the phrase; the source is not. Only the escapes that can hide a
    character inside a word are handled — a rule that tried to be a full Swift lexer would be a
    second thing to get wrong.
    """
    text = SWIFT_UNICODE_ESCAPE.sub(
        lambda m: chr(int(m.group(1), 16)) if int(m.group(1), 16) < 0x110000 else m.group(0), text)
    return text.replace("\\t", "\t").replace("\\n", "\n")


def _swift_literals(source):
    """(line number, decoded text) for every string literal in a Swift source."""
    out = []
    consumed = []
    for m in SWIFT_MULTILINE.finditer(source):
        out.append((source.count("\n", 0, m.start()) + 1, _decode_swift(m.group(1))))
        consumed.append((m.start(), m.end()))
    def inside_multiline(pos):
        return any(a <= pos < b for a, b in consumed)
    for m in SWIFT_SINGLELINE.finditer(source):
        if inside_multiline(m.start()):
            continue
        out.append((source.count("\n", 0, m.start()) + 1, _decode_swift(m.group(1))))
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


def _shown(path, repo_root):
    """Repo-relative where possible; absolute for a seam root outside the repository.

    `relative_to` RAISES for a path outside its argument, so the seam that makes the
    positive case expressible would have crashed the guard instead of reporting.
    """
    try:
        return path.relative_to(repo_root)
    except ValueError:
        return path


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
            # No cheap reject on the raw source. `"entire\x20contents"` contains the phrase after
            # Python decodes it and NOT before, so a substring test on the file text skips the file
            # before `ast` ever sees the constant — one literal, not the assembled form this rule
            # documents as out of scope. Swift's `\u{20}` is the same trick. Parsing every file is
            # the price of a rule that reads what the language reads.
            if path.suffix == ".py":
                literals = _python_literals(source, path)
                if literals is None:
                    unparsed.append(_shown(path, repo_root))
                    continue
            elif path.suffix == ".swift":
                literals = _swift_literals(source)
            else:
                comment = SHELL_COMMENT if path.suffix == ".sh" else JS_COMMENT
                literals = [(n, line) for n, line in enumerate(source.splitlines(), 1)
                            if not comment.match(line)]
            for lineno, text in literals:
                if BANNED in text:
                    found.append((_shown(path, repo_root), lineno, text.strip()[:90]))
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
    print(f"{len(found) + len(unparsed)} site(s). `{BANNED}` turns off the case-insensitive")
    print("comparison every localized element specifier in this product depends on. Inside one,")
    print("the folded tables in Scripts/logic_ui_labels.py stop matching -- in all ten languages")
    print("at once -- and the specifier reports the element is ABSENT rather than failing.")
    print("Compare case-insensitively, which is AppleScript's default, and leave the fold alone.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
