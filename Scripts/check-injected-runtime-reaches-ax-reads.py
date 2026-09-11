#!/usr/bin/env python3
"""A function handed a runtime must not read AX through the default one.

#866. `AXLogicProElements` resolvers declare `runtime: Runtime = .production`, which is right for
production entry points and wrong everywhere a caller was given a runtime to use. One call site
omitted it — `inspectorStripReading` in the track-creation verifier — and the consequence was not a
missing seam in the abstract: a unit test that built a complete fake AX tree had its verdict decided
by the REAL Logic inspector, and produced a false GREEN in the ship gate. The same test passed the
full suite half an hour before it began failing, with no change to anything it touches; what
differed was which track the live session had selected. CI never saw it, because CI has no Logic.

So the rule this enforces is narrow and mechanical: inside a function whose own signature declares a
runtime parameter, a call to a defaulted-runtime `AXLogicProElements` resolver must pass one. It
deliberately does NOT flag the many production entry points that have no runtime to pass — those are
the default's reason for existing, and flagging them would make this a counter nobody reads.

Run:  python3 Scripts/check-injected-runtime-reaches-ax-reads.py
Test: python3 Scripts/test_injected_runtime_reaches_ax_reads.py
"""
import os
import re
import sys

ACCESSIBILITY_DIR = os.path.join("Sources", "LogicProMCP", "Accessibility")
SCAN_ROOT = os.path.join("Sources", "LogicProMCP")

# Sites that are known, named and argued in the source itself. An allowlist entry is a claim that
# somebody read the call and wrote down why; it is not a way to make this quiet.
ALLOWED = {
    # `getControlBar` resolves `mainWindow()` and takes its own runtime, so the window and runtime
    # given here are unused on that path. Named in the source by review, 2026-08-29.
    ("Sources/LogicProMCP/SelectorAtlas/AtlasCapture.swift", "getControlBar"),
}


def defaulted_runtime_functions(text):
    """Names of `static func`s declaring `runtime: Runtime = .production`."""
    found = set()
    for match in re.finditer(r"static func (\w+)\(([^)]*)\)", text, re.S):
        if "runtime: Runtime = .production" in match.group(2):
            found.add(match.group(1))
    return found


def balanced(text, open_index, opener="(", closer=")"):
    """The index of the bracket closing the one at `open_index`, or -1."""
    depth = 0
    index = open_index
    while index < len(text):
        if text[index] == opener:
            depth += 1
        elif text[index] == closer:
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return -1


def functions_with_a_runtime_parameter(text):
    """`(body_start, body_end)` for every function whose signature declares a runtime parameter.

    Ranges rather than "some earlier signature": a call sitting AFTER a runtime-bearing function but
    outside its body has no runtime in scope, and treating it as if it did is how a guard reports a
    defect that is not there. The first shape of this check did exactly that and named two sites in
    a file where only one was real.
    """
    ranges = []
    for match in re.finditer(r"\bfunc\s+\w+\s*(?:<[^>]*>)?\(", text):
        params_end = balanced(text, match.end() - 1)
        if params_end < 0:
            continue
        signature = text[match.start():params_end]
        if not re.search(r"runtime:\s*\w*\.?Runtime", signature):
            continue
        body_start = text.find("{", params_end)
        if body_start < 0:
            continue
        body_end = balanced(text, body_start, "{", "}")
        if body_end < 0:
            continue
        ranges.append((body_start, body_end))
    return ranges


def offenders(text, path, defaulted):
    out = []
    scopes = functions_with_a_runtime_parameter(text)
    for match in re.finditer(r"AXLogicProElements\.(\w+)\(", text):
        name = match.group(1)
        if name not in defaulted:
            continue
        call_end = balanced(text, match.end() - 1)
        if call_end < 0:
            continue
        if "runtime" in text[match.end() - 1:call_end + 1]:
            continue
        if not any(start < match.start() < end for start, end in scopes):
            continue
        if (path, name) in ALLOWED:
            continue
        out.append((text[:match.start()].count("\n") + 1, name))
    return out


def main():
    defaulted = set()
    for root, _dirs, files in os.walk(ACCESSIBILITY_DIR):
        for name in files:
            if name.endswith(".swift"):
                with open(os.path.join(root, name), encoding="utf-8") as handle:
                    defaulted |= defaulted_runtime_functions(handle.read())
    if not defaulted:
        print("-> FAIL: found no defaulted-runtime resolvers at all, so this check is aimed at nothing")
        return 2

    problems = []
    for root, _dirs, files in os.walk(SCAN_ROOT):
        if os.path.join("LogicProMCP", "Accessibility") in root:
            continue
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(root, name)
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            for line, fn in offenders(text, path, defaulted):
                problems.append(f"{path}:{line} calls {fn} without the runtime it was given")

    if problems:
        print(f"{len(problems)} AX read(s) inside a runtime-bearing function that use the default:")
        for problem in problems:
            print(f"  {problem}")
        print()
        print("  Pass the caller's runtime. A function handed a runtime and reading through")
        print("  `.production` makes an injected tree decide nothing — see #866, where that")
        print("  produced a passing test whose verdict came from the live Logic window.")
        return 1

    print(f"every AX read inside a runtime-bearing function passes it ({len(defaulted)} resolvers, "
          f"{len(ALLOWED)} named exception)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
