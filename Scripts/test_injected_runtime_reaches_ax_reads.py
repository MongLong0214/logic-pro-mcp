#!/usr/bin/env python3
"""Self-test for check-injected-runtime-reaches-ax-reads.

Every case injects a defect or a near-miss into synthetic source and asserts what the rule says
about it. The rule exists because of one real site (#866), and the cases that matter most are the
ones that are NOT defects: a guard that flags every production entry point is a guard somebody
switches off, and the file it would flag most is the CLI.
"""
import os
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import importlib

rule = importlib.import_module("check-injected-runtime-reaches-ax-reads")

DEFAULTED = {"inspectorStripReading", "mainWindow", "getControlBar"}

CASES = []


def case(name, source, expected_lines, path="Sources/LogicProMCP/Channels/X.swift"):
    CASES.append((name, source, expected_lines, path))


case(
    "the real #866 shape: a runtime-bearing function reading through the default",
    """
    static func verify(runtime: AXLogicProElements.Runtime) -> Bool {
        let reading = AXLogicProElements.inspectorStripReading(expectedName: "x")
        return reading != nil
    }
    """,
    1,
)

case(
    "the same call, passing the runtime it was given",
    """
    static func verify(runtime: AXLogicProElements.Runtime) -> Bool {
        let reading = AXLogicProElements.inspectorStripReading(expectedName: "x", runtime: runtime)
        return reading != nil
    }
    """,
    0,
)

case(
    "a production entry point with no runtime to pass is NOT a defect",
    """
    static func run() -> Bool {
        return AXLogicProElements.mainWindow() != nil
    }
    """,
    0,
)

# The bug the first shape of the rule had: it looked for "some earlier signature" instead of a body
# range, so a call AFTER a runtime-bearing function was reported as if it were inside one.
case(
    "a call after a runtime-bearing function, but outside its body",
    """
    static func verify(runtime: AXLogicProElements.Runtime) -> Bool {
        return AXLogicProElements.mainWindow(runtime: runtime) != nil
    }

    static func later() -> Bool {
        return AXLogicProElements.mainWindow() != nil
    }
    """,
    0,
)

case(
    "a nested call deep inside the body still counts",
    """
    static func verify(runtime: AXLogicProElements.Runtime) -> Bool {
        if true {
            for _ in 0..<2 {
                _ = AXLogicProElements.getControlBar()
            }
        }
        return true
    }
    """,
    1,
)

case(
    "a resolver that does NOT default its runtime is out of scope",
    """
    static func verify(runtime: AXLogicProElements.Runtime) -> Bool {
        return AXLogicProElements.somethingElse() != nil
    }
    """,
    0,
)

# An allowlist entry is a claim somebody read the site. It must be keyed to BOTH the file and the
# function, or one exception would silence the rule everywhere that name appears.
case(
    "the allowlisted site is silent in its own file",
    """
    static func verify(runtime: AXLogicProElements.Runtime) -> Bool {
        return AXLogicProElements.getControlBar() != nil
    }
    """,
    0,
    path="Sources/LogicProMCP/SelectorAtlas/AtlasCapture.swift",
)

case(
    "and the same function name is still flagged in a different file",
    """
    static func verify(runtime: AXLogicProElements.Runtime) -> Bool {
        return AXLogicProElements.getControlBar() != nil
    }
    """,
    1,
    path="Sources/LogicProMCP/Channels/Other.swift",
)

case(
    "a multi-line call whose runtime argument is on its own line still passes",
    """
    static func verify(runtime: AXLogicProElements.Runtime) -> Bool {
        let reading = AXLogicProElements.inspectorStripReading(
            expectedName: "x",
            runtime: runtime
        )
        return reading != nil
    }
    """,
    0,
)


def drive_the_guard_end_to_end():
    """Run `check-injected-runtime-reaches-ax-reads.py` as a process, twice, over a synthetic tree.

    The unit cases above exercise `offenders` precisely; this exercises the GUARD -- its walk, its
    allowlist, its exit codes and the fact that it is aimed at anything at all. A rule whose
    resolver scan stopped recognising the declaration shape would report a clean tree forever, and
    no amount of testing one function would notice.
    """
    import subprocess
    import tempfile

    guard = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "check-injected-runtime-reaches-ax-reads.py")
    results = []
    for label, body in (
        ("clean", "AXLogicProElements.mainWindow(runtime: runtime)"),
        ("defect", "AXLogicProElements.mainWindow()"),
    ):
        root = tempfile.mkdtemp()
        ax = os.path.join(root, "Sources", "LogicProMCP", "Accessibility")
        ch = os.path.join(root, "Sources", "LogicProMCP", "Channels")
        os.makedirs(ax)
        os.makedirs(ch)
        with open(os.path.join(ax, "AXLogicProElements.swift"), "w", encoding="utf-8") as handle:
            handle.write(
                "enum AXLogicProElements {\n"
                "    static func mainWindow(runtime: Runtime = .production) -> Int? { nil }\n"
                "}\n"
            )
        with open(os.path.join(ch, "Thing.swift"), "w", encoding="utf-8") as handle:
            handle.write(
                "enum Thing {\n"
                "    static func verify(runtime: AXLogicProElements.Runtime) -> Bool {\n"
                f"        return {body} != nil\n"
                "    }\n"
                "}\n"
            )
        done = subprocess.run(["python3", guard], cwd=root, capture_output=True, text=True)
        results.append((label, done.returncode, done.stdout))
    return results


def main():
    failures = 0
    for name, source, expected, path in CASES:
        found = rule.offenders(source, path, DEFAULTED)
        ok = len(found) == expected
        print(f"{'ok  ' if ok else 'FAIL'} {name} -> {len(found)} of {expected}")
        if not ok:
            failures += 1
            print(f"       found: {found}")

    # The defaulted-resolver scan itself: if it stopped recognising the declaration shape, the rule
    # would aim at nothing and report a clean tree forever.
    declared = rule.defaulted_runtime_functions(
        "static func inspectorStripReading(expectedName: String, runtime: Runtime = .production) -> X {"
    )
    ok = declared == {"inspectorStripReading"}
    print(f"{'ok  ' if ok else 'FAIL'} the declaration scan still recognises a defaulted runtime -> {declared}")
    if not ok:
        failures += 1

    for label, code, output in drive_the_guard_end_to_end():
        want = 1 if label == "defect" else 0
        ok = code == want
        print(f"{'ok  ' if ok else 'FAIL'} the guard itself, run over a {label} tree -> exit {code} of {want}")
        if not ok:
            failures += 1
            print(f"       output: {output.strip()[:300]}")

    print()
    print("all cases behaved (0 unexpected)" if failures == 0 else f"FAILED ({failures} unexpected)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
