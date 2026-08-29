#!/usr/bin/env python3
"""Every Python module in this repo that has consumers must still satisfy them.

THE CLASS OF DEFECT
-------------------
A module can be changed so that every caller breaks while nothing in the repository notices,
because the checks that exist look at the MODULE and the callers live somewhere else. It happened
here: `evidence.py` was rewritten from a stale base, three functions vanished, thirty-four
consumers kept calling them, and both branches were green — the Swift suite does not import Python,
and the module's own tests exercised what had changed rather than what depended on it.

Deleting a name is only the cheapest version. The same hole is open when a signature gains a
required argument, or when a return value changes shape, since the name is still there.

WHAT THIS CHECKS, AND HOW IT AVOIDS GOING STALE
-----------------------------------------------
The module list is DERIVED, never written down: every `.py` in the tree is a candidate, and a
module is in scope exactly when another file imports it. A hand-kept list is a second copy that
goes stale at the moment a new module acquires its first consumer — which is precisely when it
starts mattering.

For each consumer, under the alias it actually imported:

  * every `M.name` referenced must exist
  * every `M.name(...)` call must BIND against the real signature — this is what catches a new
    required parameter, which a name check cannot see
  * a variable assigned from `M.Class(...)` carries that class, so `var.attr` is checked too

WHAT IT DOES NOT CHECK, STATED SO NOBODY READS IT AS MORE
---------------------------------------------------------
Return SHAPE. `f()` changing from a list to a dict keeps its name and its signature, and no static
pass can see it in untyped Python. That gap is covered separately, by driving the API and asserting
what comes back — for `evidence.py` that is `Scripts/livekit/test_evidence.py`, which runs the
whole non-capture surface headlessly. Any module without such a drive has this square open, and
this script says which.
"""
import ast
import importlib
import inspect
import os
import subprocess
import sys

SKIP_DIRS = {".git", ".build", "node_modules", ".venv", "venv"}


def _ignored_top_level(root):
    """Directory names at the repo root that git ignores, asked of git rather than listed.

    The hand-written `SKIP_DIRS` cannot know what a `.gitignore` says, and the difference is not
    cosmetic: measured 2026-08-29, a vendored tool directory — gitignored, never committed,
    present only on one machine — carried a file that will not parse, so this guard failed locally
    and passed in CI, where that directory does not exist. A guard whose verdict depends on
    untracked scratch is a guard nobody can act on, and the direction of the error is the bad one:
    it fails where there is MORE, so whoever can reproduce it is least able to tell it from a real
    defect.

    Top level only, which is where a vendored tree lands. A nested ignored path stays in scope, and
    that is the safer direction: this errs toward scanning too much.
    """
    try:
        proc = subprocess.run(
            ["git", "-C", root, "status", "--porcelain", "--ignored=matching", "-z"],
            capture_output=True, text=True)
    except OSError:
        return set()
    if proc.returncode != 0:
        return set()
    out = set()
    for entry in proc.stdout.split("\0"):
        if not entry.startswith("!! "):
            continue
        path = entry[3:].strip("/")
        if path and "/" not in path:
            out.add(path)
    return out


def local_modules(root):
    out = {}
    skip = SKIP_DIRS | _ignored_top_level(root)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in skip]
        for f in filenames:
            if f.endswith(".py"):
                out.setdefault(f[:-3], os.path.join(dirpath, f))
    return out


def aliases(tree, known, selfname):
    """{alias: module} for every local module this file imports, under the name it uses."""
    found = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                if a.name in known and a.name != selfname:
                    found[a.asname or a.name] = a.name
    return found


def from_imports(tree, known, selfname):
    """[(module, name)] for `from M import name` — the name is bound directly, with no alias to
    hang attribute checks on, so it is verified at the import itself."""
    out = []
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module in known and node.module != selfname:
            for a in node.names:
                if a.name != "*":
                    out.append((node.module, a.name))
    return out


def declared_attrs(cls):
    """Attribute names a class assigns to `self`. `hasattr(Cls, "dir")` is False for a name plainly
    set in __init__, so reading them statically is the difference between a real finding and noise —
    and it beats constructing the class, which for Evidence would create directories."""
    try:
        src = inspect.getsource(cls)
    except (OSError, TypeError):
        return set()
    names = set()
    for node in ast.walk(ast.parse(src.lstrip())):
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \
                and node.value.id == "self" and isinstance(node.ctx, ast.Store):
            names.add(node.attr)
    return names


def instance_vars(tree, alias_map):
    """{var: (module, ClassName)} for `var = M.Class(...)`."""
    out = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call):
            fn = node.value.func
            if (isinstance(fn, ast.Attribute) and isinstance(fn.value, ast.Name)
                    and fn.value.id in alias_map and fn.attr[:1].isupper()):
                for t in node.targets:
                    if isinstance(t, ast.Name):
                        out[t.id] = (alias_map[fn.value.id], fn.attr)
    return out


def call_arity_ok(func, node):
    """Whether this call site binds against the real signature. (ok, message)."""
    try:
        sig = inspect.signature(func)
    except (TypeError, ValueError):
        return True, ""            # builtins and C functions expose none; not a finding
    if any(isinstance(a, ast.Starred) for a in node.args) or any(k.arg is None for k in node.keywords):
        return True, ""            # *args / **kwargs at the call site: arity is not decidable here
    args = [None] * len(node.args)
    kwargs = {k.arg: None for k in node.keywords}
    try:
        sig.bind(*args, **kwargs)
        return True, ""
    except TypeError as exc:
        return False, f"{exc} — signature is {sig}"


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    known = local_modules(root)
    loaded, offenders, checked, unimportable = {}, [], 0, []
    pulled_names = {}
    # DERIVED, not listed. The first version of this was a dict with one entry, which is the same
    # staleness this file exists to prevent: it would have kept saying "evidence only" after a
    # second module gained a drive. A module counts as driven when some `test_*.py` imports it AND
    # asserts something about what its calls return — importing alone is not a drive.
    covered_by_a_drive = {}
    for cand, cpath in known.items():
        if not os.path.basename(cpath).startswith("test_"):
            continue
        try:
            ctree = ast.parse(open(cpath).read())
        except SyntaxError:
            continue
        imported = set(aliases(ctree, known, cand).values()) | {m for m, _ in from_imports(ctree, known, cand)}
        asserts_shapes = "isinstance" in open(cpath).read()
        for mod in imported:
            if asserts_shapes:
                covered_by_a_drive[mod] = os.path.relpath(cpath, root)
    consumed = {}

    for path in sorted(known.values()):
        try:
            tree = ast.parse(open(path).read())
        except SyntaxError as exc:
            offenders.append(f"{os.path.relpath(path, root)}: will not parse ({exc})")
            continue
        selfname = os.path.basename(path)[:-3]
        alias_map = aliases(tree, known, selfname)
        pulled = from_imports(tree, known, selfname)
        if not alias_map and not pulled:
            continue
        for mod, _ in pulled:
            consumed.setdefault(mod, set()).add(path)
            if mod not in loaded:
                sys.path.insert(0, os.path.dirname(known[mod]))
                try:
                    loaded[mod] = importlib.import_module(mod)
                except Exception as exc:                       # noqa: BLE001
                    loaded[mod] = None
                    unimportable.append(f"{mod}: {type(exc).__name__}: {exc}")
                finally:
                    sys.path.pop(0)
        for mod, name in pulled:
            pulled_names.setdefault(mod, set()).add(name)
        for mod, name in pulled:
            if loaded.get(mod) is not None:
                checked += 1
                if not hasattr(loaded[mod], name):
                    offenders.append(
                        f"{os.path.relpath(path, root)}: `from {mod} import {name}` — no such name")
        for mod in alias_map.values():
            consumed.setdefault(mod, set()).add(path)
        for alias, mod in alias_map.items():
            if mod not in loaded:
                sys.path.insert(0, os.path.dirname(known[mod]))
                try:
                    loaded[mod] = importlib.import_module(mod)
                except Exception as exc:                       # noqa: BLE001
                    loaded[mod] = None
                    unimportable.append(f"{mod}: {type(exc).__name__}: {exc}")
                finally:
                    sys.path.pop(0)
        ivars = instance_vars(tree, alias_map)
        rel = os.path.relpath(path, root)

        for node in ast.walk(tree):
            if not isinstance(node, ast.Attribute) or not isinstance(node.value, ast.Name):
                continue
            base = node.value.id
            if base in alias_map:
                owner = loaded.get(alias_map[base])
                label = f"{alias_map[base]}.{node.attr}"
            elif base in ivars:
                mod, cls = ivars[base]
                owner = getattr(loaded.get(mod), cls, None)
                label = f"{mod}.{cls}.{node.attr}"
            else:
                continue
            if owner is None:
                continue
            checked += 1
            if inspect.isclass(owner) and node.attr in declared_attrs(owner):
                continue
            if not hasattr(owner, node.attr):
                offenders.append(f"{rel}: calls {label}, which does not exist")

        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
                continue
            fn = node.func
            if not isinstance(fn.value, ast.Name):
                continue
            base = fn.value.id
            if base in alias_map:
                owner, label = loaded.get(alias_map[base]), f"{alias_map[base]}.{fn.attr}"
                bound = False
            elif base in ivars:
                mod, cls = ivars[base]
                owner, label = getattr(loaded.get(mod), cls, None), f"{mod}.{cls}.{fn.attr}"
                bound = True                                   # `self` is already supplied
            else:
                continue
            target = getattr(owner, fn.attr, None) if owner is not None else None
            if target is None or not callable(target):
                continue
            call = node
            if bound and inspect.isfunction(target):
                args = [None] + [None] * len(call.args)
                try:
                    inspect.signature(target).bind(*args, **{k.arg: None for k in call.keywords
                                                             if k.arg is not None})
                    continue
                except TypeError as exc:
                    offenders.append(f"{rel}: {label}(...) does not bind — {exc}")
                    continue
            ok, why = call_arity_ok(target, call)
            if not ok:
                offenders.append(f"{rel}: {label}(...) does not bind — {why}")

    print(f"modules with consumers: {len(consumed)}   references checked: {checked}")
    # A module whose consumed surface is unittest.TestCase subclasses cannot have a "return-shape
    # drive" — there are no returns to shape. It is covered by being RUN. Counting those three as
    # gaps overstated the remaining work, the same way counting every locator call overstated #628.
    def consumed_surface_is_test_cases(mod):
        """Every name importers actually take from this module is a TestCase subclass.

        Not "every class in the file is a TestCase" — that was the first rule and it missed a
        module carrying one test-helper class beside its cases. What matters is the CONSUMED
        surface: if importers only take test classes, there are no returns to shape.
        """
        names = pulled_names.get(mod, set())
        if not names:
            return False
        try:
            tree = ast.parse(open(known[mod]).read())
        except SyntaxError:
            return False
        cases = {
            n.name for n in tree.body
            if isinstance(n, ast.ClassDef)
            and any(getattr(b, "attr", getattr(b, "id", "")) == "TestCase" for b in n.bases)
        }
        return bool(cases) and names <= cases

    gaps = 0
    for mod in sorted(consumed):
        drive = covered_by_a_drive.get(mod)
        if drive:
            note = f"return shapes driven by {drive}"
        elif consumed_surface_is_test_cases(mod):
            note = "test-case module — covered by running it, not by a shape drive"
        else:
            note = "NO return-shape drive"
            gaps += 1
        print(f"  {mod:30} {len(consumed[mod]):3} consumers   {note}")
    print(f"  {'':30}     modules still without a drive: {gaps}")
    for u in unimportable:
        print(f"  could not import {u}")
    if unimportable:
        offenders.append(f"{len(unimportable)} module(s) with consumers would not import")
    if offenders:
        print("\nOFFENDERS")
        for o in offenders:
            print("  " + o)
        return 1
    print("\nevery consumer's references and call arities bind")
    return 0


if __name__ == "__main__":
    sys.exit(main())
