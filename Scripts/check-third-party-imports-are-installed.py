#!/usr/bin/env python3
"""A guard CI cannot import has not run, and the only place that shows is CI.

WHAT WENT WRONG. `Scripts/test_issue_form_canon_field.py` imports PyYAML at module level, on
purpose: it renders the issue forms the way GitHub does and needs a real YAML parser, and its
docstring says outright that skipping instead would let the file go quiet. Every developer machine
in this project had PyYAML installed for some other reason. The macOS 15 runner image does not, so
the drive died on `ModuleNotFoundError` — after 37 minutes of `swift test`, in run 35587823299,
on a change that had passed the identical command locally minutes earlier.

The install was the fix. This file is the part that makes the NEXT one visible before CI: the gap
was never the missing package, it was that nothing in the repository related what a driven file
imports to what the workflow installs. A dependency that only the author's machine satisfies is
invisible to every check the author can run.

## What it compares

One side: the modules imported at MODULE LEVEL and UNCONDITIONALLY by the files
`Scripts/run-repo-guards.py` discovers, following imports into this repository's own modules,
because a discovered test that imports a local module dies exactly the same way when THAT module's
import is missing. An import inside a function, a `try`, or an `if` is not counted — that is how
`Scripts/livekit/evidence.py` reaches Quartz, and a harness that asks "is PyObjC here?" and
answers honestly is not making a demand on CI.

Other side: the modules `.github/workflows/ci.yml` proves it can import, written as a literal
`python3 -c "import <name>` in a step. Deliberately the PROOF and not the `pip install` line: a
package name is not a module name (`pyyaml` imports as `yaml`), and pip printing nothing is not
evidence the interpreter the runner launches can find the module. Requiring the readback means a
new dependency is added in both places or in neither.

## What this replaces

The older rule was "no third-party imports at all". `check-every-ci-job-is-required.py` parses
`ci.yml` by indentation rather than with PyYAML for exactly that reason, and the commit that wrote
it (`83a19d5`, #893) records the choice: "run-repo-guards.py's contract is plain Python with no
third-party imports". That contract is strictly more robust and it is not what the tree does any
more -- `test_issue_form_canon_field.py` needs a real YAML parser, because the alternative is a
hand-written YAML subset that would be a SECOND AUTHORITY on the thing the test exists to model.
So the rule becomes "third-party is allowed where CI proves it can import it", and the proof is
mechanical rather than remembered. A dependency that is installed and not proved, or proved and
not installed, fails here.

## The residual

Stdlib membership comes from `sys.stdlib_module_names`, which is the running interpreter's answer.
A module that is stdlib here and not on the runner would pass this and fail there; the two are the
same CPython series today, and this check is a floor rather than a proof of the runner's library.
"""
import ast
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(REPO, ".github", "workflows", "ci.yml")

#: The readback, not the install. See the docstring: `pyyaml` is the package and `yaml` is the
#: module, and only one of the two is what a driven file actually asks for.
PROVEN = re.compile(r'python3 -c "import ([A-Za-z_][A-Za-z0-9_]*)')


def discovered():
    """The files CI drives, asked of the runner rather than restated here."""
    import importlib.util

    path = os.path.join(REPO, "Scripts", "run-repo-guards.py")
    spec = importlib.util.spec_from_file_location("_run_repo_guards", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return [p for p in module.discovered() if p.endswith(".py")]


def _unconditional_imports(tree):
    """Module roots imported at module level, outside any function, class, `try` or `if`."""
    out = []
    for node in tree.body:
        if isinstance(node, ast.Import):
            out += [alias.name.split(".")[0] for alias in node.names]
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            out.append(node.module.split(".")[0])
    return out


def _local_module(name):
    """The file a repository-local import resolves to, or None."""
    for candidate in (os.path.join(REPO, "Scripts", name + ".py"),
                      os.path.join(REPO, "Scripts", name, "__init__.py"),
                      os.path.join(REPO, "Scripts", "livekit", name + ".py")):
        if os.path.exists(candidate):
            return candidate
    return None


def required(entry_points):
    """{module: [file that imports it]} for every third-party module CI has to be able to import."""
    stdlib = set(sys.stdlib_module_names)
    wanted, seen, queue = {}, set(), list(entry_points)
    while queue:
        path = queue.pop()
        if path in seen:
            continue
        seen.add(path)
        try:
            tree = ast.parse(open(path, encoding="utf-8").read())
        except (OSError, SyntaxError):
            # Unreadable is not clean. `check-python-contracts.py` owns syntax; what this one must
            # not do is treat a file it could not parse as one with no imports.
            wanted.setdefault("<unparsed>", []).append(path)
            continue
        for name in _unconditional_imports(tree):
            if name in stdlib:
                continue
            local = _local_module(name)
            if local:
                queue.append(local)
                continue
            wanted.setdefault(name, []).append(path)
    return wanted


def proven(text):
    return set(PROVEN.findall(text))


def main():
    if not os.path.exists(WORKFLOW):
        print("cannot read .github/workflows/ci.yml — refusing rather than passing")
        return 2
    entry_points = discovered()
    if not entry_points:
        print("run-repo-guards.py discovered no Python file — refusing rather than passing")
        return 2
    wanted = required(entry_points)
    installed = proven(open(WORKFLOW, encoding="utf-8").read())
    missing = {name: files for name, files in wanted.items() if name not in installed}
    if missing:
        print(f"{len(missing)} module(s) CI drives are not proved importable by ci.yml:\n")
        for name in sorted(missing):
            print(f"  {name}")
            for path in sorted(set(missing[name])):
                print(f"      {os.path.relpath(path, REPO)}")
        print(
            "\nAdd the install to the macOS `test` job AND a `python3 -c \"import <name>\"` "
            "readback beside it. The readback is what this reads: a package name is not a module "
            "name, and a silent `pip install` is not evidence the interpreter can find it. If the "
            "module is optional, import it where it is used and handle its absence — an import "
            "inside a function or a `try` is not counted here."
        )
        return 1
    print(f"ok — {len(entry_points)} driven file(s) scanned, "
          f"{len(wanted)} third-party module(s) required, all proved importable by ci.yml")
    return 0


if __name__ == "__main__":
    sys.exit(main())
