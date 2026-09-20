#!/usr/bin/env python3
"""Every `check-*.py` must be ABLE to exit non-zero, or say in one line that it only counts.

WHY THIS EXISTS
---------------
`run-repo-guards.py` runs what it discovers and prints `ok` for exit 0. A guard whose every exit
path is a literal `0` prints `ok` for the same reason a passing one does, and the log reads as
coverage. One file in this repository counts rather than refuses -- `check-variants-appear-in-a-
census.py` -- and it says so with `#: NOT A GATE`, which the runner prints as `rept` instead of
`ok`. The marker is a DECLARATION, and the limit recorded against it said the quiet part: "a guard
that cannot fail and does NOT carry it still prints `ok`; nothing detects that, and nothing can."

Something can. Whether a Python file has any path that leaves non-zero is a question about its
syntax tree, not about its behaviour: a `return` of anything but a literal 0, a `sys.exit` with
anything but 0, or a `raise`. This asks that question of every `check-*.py` and requires either an
answer of yes or the marker.

WHAT IT DOES NOT CLAIM
----------------------
That the non-zero path is REACHABLE. `return 1` inside `if False:` satisfies this, and so does a
gate whose condition is never true -- which is the defect `Scripts/mutation-sweep-guard-tests.py`
measures, by removing the gate and watching the covering tests go red. This is the cheaper
question underneath it: not "would anybody notice", but "can this file refuse at all".

Exit: 0 = every guard can refuse or declares that it counts - 1 = one can do neither
"""
import ast
import glob
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
#: A seam, so the self-test can drive main() at a directory whose guards must fail.
GUARDS = os.environ.get("LPM_GUARD_DIR") or os.path.join(REPO, "Scripts")
#: The same sentence `run-repo-guards.py` reads, and it is assembled rather than written out.
#: `run-repo-guards.py` looks for the marker ANYWHERE in a file's text, so spelling it whole here
#: -- even inside a string, even to check for it -- would make the runner classify THIS file as a
#: counter and print `rept` for it. Measured 2026-09-20: written whole, this guard exempted itself
#: from its own rule and the runner reported two declared counters instead of one.
NOT_A_GATE = "#: NOT A" + " GATE"


def declares_it_counts(source: str) -> bool:
    """Whether the marker is a COMMENT LINE of its own, not a mention inside code.

    `NOT_A_GATE in source` is what the runner asks, and it is the looser question: a file that
    merely names the marker satisfies it. Requiring the line to BE the marker is what keeps this
    rule from being switched off by a docstring quoting it.
    """
    return any(line.strip() == NOT_A_GATE for line in source.splitlines())


def can_refuse(tree: ast.AST) -> bool:
    """Whether any path in this module leaves non-zero.

    Conservative on purpose: anything that is not a literal `0` counts as "can refuse", because
    `return 1 if problems else 0` is the shape nearly every guard here uses and reading its
    condition is not this rule's job.
    """
    for node in ast.walk(tree):
        if isinstance(node, ast.Raise):
            return True
        if isinstance(node, ast.Return) and node.value is not None:
            if not (isinstance(node.value, ast.Constant) and node.value.value in (0, None)):
                return True
        if isinstance(node, ast.Call):
            name = node.func.attr if isinstance(node.func, ast.Attribute) else getattr(
                node.func, "id", None)
            if name != "exit":
                continue
            if not node.args:
                continue
            first = node.args[0]
            # `sys.exit(main())` is DELEGATION, not a refusal. Nearly every guard here ends with
            # that line, so counting it as a non-zero path made the rule answer yes for a file
            # whose `main` is `return 0` -- which is exactly the file it exists to catch. Only a
            # literal non-zero counts; what `main` does is decided by its own returns above.
            if isinstance(first, ast.Constant) and first.value not in (0, None):
                return True
    return False


def problems(directory: str = None) -> list:
    root = directory or GUARDS
    found = sorted(glob.glob(os.path.join(root, "check-*.py")))
    if not found:
        return [f"no check-*.py under {root}, so this rule is checking nothing. That is a wrong "
                f"directory or an empty tree, not a repository without guards."]
    out = []
    for path in found:
        rel = os.path.relpath(path, REPO)
        try:
            with open(path, encoding="utf-8") as handle:
                source = handle.read()
            tree = ast.parse(source, filename=path)
        except (OSError, SyntaxError) as exc:
            out.append(f"{rel}: cannot be read as Python ({exc}), so whether it can refuse is "
                       f"unknown. Unknown is not clean.")
            continue
        if can_refuse(tree):
            continue
        if declares_it_counts(source):
            continue
        out.append(
            f"{rel}: every exit path is a literal 0, so it can only ever print `ok` -- and "
            f"`run-repo-guards.py` counts that as a guard passing. Give it a path that refuses, or "
            f"declare that it counts rather than gates with the line `{NOT_A_GATE}`.")
    return out


def main() -> int:
    found = problems()
    if found:
        print(f"{len(found)} guard(s) cannot refuse and do not say so:", file=sys.stderr)
        for line in found:
            print(f"  {line}", file=sys.stderr)
        return 1
    total = len(glob.glob(os.path.join(GUARDS, "check-*.py")))
    counters = sum(1 for path in glob.glob(os.path.join(GUARDS, "check-*.py"))
                   if declares_it_counts(open(path, encoding="utf-8").read()))
    print(f"every one of {total} check-*.py can exit non-zero, or declares that it counts "
          f"({counters} declared)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
