#!/usr/bin/env python3
"""String concatenations big enough to time out the Swift type-checker, inside an argument literal.

THE DEFECT
----------
Swift type-checks one expression at a time, and a `+` chain of string literals mixed with
interpolation multiplies the solver's work. Put that chain inside a collection literal that is
itself an argument to a generic call with a trailing closure, and the whole construct is a single
expression. Whether it solves inside the limit then depends on the toolchain.

Reported by a contributor on 2026-09-02 while testing a merged fix: `main` would not build on their
machine at all. `AccessibilityChannel+MIDIImport.swift` had a five-way chain inside
`extras.merging([...]) { _, new in new }`, and their compiler gave up on it. It built here. A
timeout is not a diagnosable error in the reader's own code, so the cost lands entirely on whoever
pulls the repository cold (#749).

The fix is always the same and always behaviour-preserving: bind the string to a `let` before the
call, so the literal holds one identifier.

WHAT IS COUNTED
---------------
A flat collection literal in a call's first unlabeled argument, containing one value with
`THRESHOLD` or more string-concatenation `+` operators. Concatenations that are NOT inside a call
argument are left alone: a `let` with a long chain is exactly the shape this guard wants people to
write.

This intentionally does not parse labeled or non-first arguments, a chain after a nested call,
parenthesised pieces, or raw strings. It is a narrow regression guard for the reported flat shape,
not a Swift parser.

The threshold is deliberately below the reported five: the site that broke had five, and a guard
that only refuses what already broke cannot prevent the next one.
"""
import glob
import os
import re
import sys

THRESHOLD = 3
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# A collection literal that is an argument to a call: `name([ ... ])` or `name([ ... ]) { ... }`.
# Non-greedy to the first `])`, which is enough for the flat literals this repository writes.
ARGUMENT_LITERAL = re.compile(r"\w+\(\s*\[(.*?)\]\s*\)", re.S)


def skip_string(text, start, hashes=""):
    """Return the first index after the Swift string beginning at `start`."""
    if text.startswith('"""', start):
        delimiter = '"""' + hashes
        end = text.find(delimiter, start + 3)
        return len(text) if end == -1 else end + len(delimiter)

    index = start + 1
    while index < len(text):
        if not hashes and text[index] == "\\":
            index += 2
        elif text[index] == '"' and text.startswith(hashes, index + 1):
            return index + 1 + len(hashes)
        else:
            index += 1
    return len(text)


def string_end(text, start):
    """Return the first index after a string beginning at `start`, or None."""
    if text[start] == '"':
        return skip_string(text, start)
    if text[start] != "#":
        return None

    end_hashes = start
    while end_hashes < len(text) and text[end_hashes] == "#":
        end_hashes += 1
    if end_hashes < len(text) and text[end_hashes] == '"':
        return skip_string(text, end_hashes, text[start:end_hashes])
    return None


def strip_swift_comments(text):
    """Replace comments with spaces while preserving lines and quoted strings."""
    stripped = list(text)
    index = 0
    while index < len(text):
        end_string = string_end(text, index)
        if end_string is not None:
            index = end_string
            continue

        if text.startswith("//", index):
            end = text.find("\n", index)
            end = len(text) if end == -1 else end
            for comment_index in range(index, end):
                stripped[comment_index] = " "
            index = end
            continue

        if text.startswith("/*", index):
            start = index
            depth = 1
            index += 2
            while index < len(text) and depth:
                if text.startswith("/*", index):
                    depth += 1
                    index += 2
                elif text.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            for comment_index in range(start, index):
                if stripped[comment_index] != "\n":
                    stripped[comment_index] = " "
            continue

        index += 1
    return "".join(stripped)


def top_level_parts(text, separator):
    """Split `text` at separators outside strings and nested delimiters."""
    parts = []
    start = 0
    depth = 0
    index = 0
    while index < len(text):
        end_string = string_end(text, index)
        if end_string is not None:
            index = end_string
            continue

        if text[index] in "([{":
            depth += 1
        elif text[index] in ")]}":
            depth -= 1
        elif text[index] == separator and depth == 0:
            parts.append(text[start:index])
            start = index + 1
        index += 1
    parts.append(text[start:])
    return parts


def value_of(entry):
    """Return a dictionary entry's value, or an array entry itself."""
    return top_level_parts(entry, ":")[-1]


def string_concatenations(value):
    # Count `+` used next to string pieces, not arithmetic inside interpolation.
    plus = len(re.findall(r'"\s*\n?\s*\+', value)) + len(re.findall(r'\+\s*\n?\s*"', value))
    return (plus + 1) // 2


def offenders(repo=REPO):
    found = []
    for path in sorted(glob.glob(os.path.join(repo, "Sources", "**", "*.swift"), recursive=True)):
        text = open(path, encoding="utf-8").read()
        code = strip_swift_comments(text)
        for match in ARGUMENT_LITERAL.finditer(code):
            body = match.group(1)
            values = map(value_of, top_level_parts(body, ","))
            concatenations = max(map(string_concatenations, values), default=0)
            if concatenations >= THRESHOLD:
                line = text[: match.start()].count("\n") + 1
                found.append((os.path.relpath(path, repo), line, concatenations))
    return found


def main():
    repo = os.path.abspath(sys.argv[1]) if len(sys.argv) == 2 else REPO
    found = offenders(repo)
    if not found:
        print(f"no argument literal carries {THRESHOLD}+ string concatenations")
        return 0
    print(f"{len(found)} argument literal(s) carry {THRESHOLD}+ string concatenations:")
    for path, line, count in found:
        print(f"  {path}:{line}  concatenations={count}")
    print()
    print("Bind the string to a `let` before the call. The type-checker then sees an identifier,")
    print("and the build stops depending on which toolchain the reader happens to have (#749).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
