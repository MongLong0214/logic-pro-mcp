"""`verify.py self-test`: the fixtures, then the mutants that prove the fixtures can fail.

Offline. Issue bodies come from `fixtures/issues/`, and repository quotes from `git show` of commits
on main.

CASES (`fixtures/cases.json`)
    Each case runs one `verify.py` command in this process and requires its exit code and a
    substring of its output. A case may first patch a fixture into a temporary file:
        {"set": [path...], "value": v}        set one key or index
        {"delete": [path...]}                 remove one key
        {"obs": [locale, row, step], "raw": v, "keep_bytes": bool}
                                              store v as that observation's raw text; with
                                              keep_bytes the stored byte count is left as it was
        "restamp": true                       recompute the stored verdicts with the engine, so the
                                              case judges the observations, not a verdict mismatch
    A case may name a guard to run afterwards (`then`), as a subprocess.

MUTANTS (`MUTANTS` below)
    Each mutant is one textual rewrite of one file, applied to a temporary copy of Scripts/verify.
    The copy's `self-test --cases-only` must then fail, naming at least one case: that case is the
    fixture that catches the mutant. A mutant that leaves every case passing SURVIVES, and one
    survivor fails the self-test. A mutant that makes the copy fail without naming a case is
    BROKEN (it tests the harness, not the engine) and also fails the self-test. The control
    mutant changes a docstring and must survive; if it is killed, the harness is what fails.
"""
from __future__ import annotations

import concurrent.futures
import contextlib
import copy
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
ROOT = os.path.dirname(SCRIPTS)
FIXTURES = os.path.join(HERE, "fixtures")
CASES = os.path.join(FIXTURES, "cases.json")

MUTANTS = [
    {"id": "eq-is-ne", "file": "predicates.py",
     "old": '"eq": (True, lambda a, b: same(a, b)),',
     "new": '"eq": (True, lambda a, b: not same(a, b)),'},
    {"id": "unreadable-is-pass", "file": "predicates.py",
     "old": "if isinstance(actual, Unreadable):\n        return UNREADABLE, actual.reason",
     "new": "if isinstance(actual, Unreadable):\n        return PASS, actual.reason"},
    {"id": "matches-canon-always", "file": "predicates.py",
     "old": '"matches_canon": (True, lambda a, b: isinstance(a, str)',
     "new": '"matches_canon": (True, lambda a, b: True or isinstance(a, str)'},
    {"id": "counterexamples-skipped", "file": "engine.py",
     "old": '    for k, cx in enumerate(row["counterexample"]):\n        swapped = dict(values)',
     "new": '    for k, cx in enumerate(row["counterexample"][:0]):\n        swapped = dict(values)'},
    {"id": "restore-skipped", "file": "engine.py",
     "old": 'restore = [_judge_one(e, lookup, locale, resolve_canon) for e in row["restore_expect"]]',
     "new": "restore = []"},
    {"id": "subset-reason-ignored", "file": "engine.py",
     "old": 'if not locales["reason"].strip():',
     "new": 'if False and not locales["reason"].strip():'},
    {"id": "independence-rule-off", "file": "engine.py",
     "old": 'if not any(_safe_root(expect[i]["path"]) in independent for i in proven):',
     "new": 'if False and not any(_safe_root(expect[i]["path"]) in independent for i in proven):'},
    {"id": "call-counts-as-independent", "file": "engine.py",
     "old": 'elif "call" in steps[name]:',
     "new": "elif False:"},
    {"id": "stored-verdicts-not-compared", "file": "engine.py",
     "old": 'result["mismatches"] = compare_verdicts(doc["verdicts"], recomputed)',
     "new": 'result["mismatches"] = []'},
    {"id": "binding-ignored", "file": "engine.py",
     "old": 'if binary.get("binding") != E.BOUND:',
     "new": "if False:"},
    {"id": "truncation-ignored", "file": "engine.py",
     "old": "if stored != size:",
     "new": "if False:"},
    {"id": "step-identity-ignored", "file": "engine.py",
     "old": 'elif not P.same(entry.get("step"), step):',
     "new": "elif False:"},
    {"id": "spec-digest-ignored", "file": "engine.py",
     "old": 'if E.sha256_of(doc["spec"]) != doc["spec_sha256"]:',
     "new": "if False:"},
    {"id": "canon-quote-unchecked", "file": "engine.py",
     "old": 'if logic_canon.short_digest(ref["quote"]) != pinned:',
     "new": "if False:"},
    {"id": "product-source-allowed", "file": "engine.py",
     "old": "        if PRODUCT_SOURCE.search(text):",
     "new": "        if False:"},
    {"id": "missing-locale-ignored", "file": "engine.py",
     "old": "for locale in required_locales(spec):",
     "new": 'for locale in [c for c in required_locales(spec) if c in doc["runs"]]:'},
    {"id": "incomplete-outranks-failed", "file": "engine.py",
     "old": ('    if result["failures"] or result["mismatches"]:\n        result["exit"] = EXIT_FAILED\n'
             '    elif result["incomplete"]:\n        result["exit"] = EXIT_INCOMPLETE'),
     "new": ('    if result["incomplete"]:\n        result["exit"] = EXIT_INCOMPLETE\n'
             '    elif result["failures"] or result["mismatches"]:\n        result["exit"] = EXIT_FAILED')},
    {"id": "quote-always-holds", "file": "engine.py",
     "old": "return bool(quote) and quote in text",
     "new": "return True"},
    {"id": "recheck-exits-clean", "file": "verify.py",
     "old": "(exit {result['exit']})\")\n    return result[\"exit\"]",
     "new": "(exit {result['exit']})\")\n    return 0"},
    {"id": "control", "file": "engine.py", "control": True,
     "old": '"""The verdict on one evidence document.',
     "new": '"""The verdict on one evidence document (control: a docstring edit, no behaviour).'},
]


# ---------------------------------------------------------------------------------------------
# cases
# ---------------------------------------------------------------------------------------------

def _fill(text: str, where: dict) -> str:
    for key, value in where.items():
        text = text.replace("{" + key + "}", value)
    return text


def _descend(node, path):
    for key in path[:-1]:
        node = node[key]
    return node, path[-1]


def _patched(case: dict, where: dict) -> str:
    import engine
    import evidence_doc as E
    patch = case["patch"]
    with open(_fill(patch["file"], where), encoding="utf-8") as handle:
        doc = json.load(handle)
    for op in patch["ops"]:
        if "set" in op:
            parent, key = _descend(doc, op["set"])
            parent[key] = copy.deepcopy(op["value"])
        elif "delete" in op:
            parent, key = _descend(doc, op["delete"])
            del parent[key]
        elif "obs" in op:
            locale, row, step = op["obs"]
            entry = doc["runs"][locale]["rows"][row]["observations"][step]
            entry["raw"] = json.dumps(op["raw"], ensure_ascii=False, sort_keys=True)
            if not op.get("keep_bytes"):
                entry["raw_bytes"] = len(entry["raw"].encode("utf-8"))
        else:
            raise ValueError(f"{case['name']}: unknown patch op {op}")
    if patch.get("restamp"):
        for locale, run in doc["runs"].items():
            doc["verdicts"][locale] = engine.evaluate_run(doc["spec"], run, locale)
    path = os.path.join(where["tmp"], f"{case['name']}.json")
    E.write_atomic(path, doc)
    return path


def run_case(case: dict, where: dict):
    """None when the case holds, else why not."""
    import verify
    where = dict(where)
    if "patch" in case:
        where["patched"] = _patched(case, where)
    argv = [_fill(a, where) for a in case["cmd"]]
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        try:
            code = verify.main(argv)
        except Exception as exc:  # a crash is a failed case, reported with its type
            code = f"crash {type(exc).__name__}: {exc}"
    text = out.getvalue()
    if code != case["exit"]:
        return f"exit {code}, wanted {case['exit']}; last line: {text.strip().splitlines()[-1:]}"
    if case["says"] not in text:
        return f"exit {code} as wanted, but the output does not say {case['says']!r}"
    then = case.get("then")
    if then:
        env = dict(os.environ, **{k: _fill(v, where) for k, v in then["env"].items()})
        proc = subprocess.run([sys.executable, os.path.join(SCRIPTS, then["script"])], env=env,
                              capture_output=True, text=True, timeout=120)
        if proc.returncode != then["exit"] or then["says"] not in proc.stdout:
            return (f"then {then['script']}: exit {proc.returncode}, wanted {then['exit']}; "
                    f"{(proc.stdout + proc.stderr).strip().splitlines()[-3:]}")
    return None


def run_cases() -> tuple:
    """(names passed, [(name, why)] failed)."""
    with open(CASES, encoding="utf-8") as handle:
        cases = json.load(handle)
    names = [c["name"] for c in cases]
    if len(set(names)) != len(names):
        raise SystemExit("fixtures/cases.json names a case twice")
    passed, failed = [], []
    saved = os.environ.get("LPM_VERIFY_ISSUE_BODIES")
    os.environ["LPM_VERIFY_ISSUE_BODIES"] = os.path.join(FIXTURES, "issues")
    try:
        with tempfile.TemporaryDirectory(prefix="lpm-verify-cases-") as tmp:
            where = {"fixtures": FIXTURES, "root": ROOT, "tmp": tmp}
            for case in cases:
                why = run_case(case, where)
                (failed.append((case["name"], why)) if why else passed.append(case["name"]))
    finally:
        if saved is None:
            os.environ.pop("LPM_VERIFY_ISSUE_BODIES", None)
        else:
            os.environ["LPM_VERIFY_ISSUE_BODIES"] = saved
    return passed, failed


# ---------------------------------------------------------------------------------------------
# mutants
# ---------------------------------------------------------------------------------------------

def _mutated_tree(mutant: dict, tmp: str) -> str:
    """A tree whose Scripts/verify is a mutated copy and whose everything else links to ROOT."""
    for entry in os.listdir(ROOT):
        if entry not in ("Scripts", ".git"):
            os.symlink(os.path.join(ROOT, entry), os.path.join(tmp, entry))
    scripts = os.path.join(tmp, "Scripts")
    os.mkdir(scripts)
    for entry in os.listdir(SCRIPTS):
        if entry not in ("verify", "__pycache__"):
            os.symlink(os.path.join(SCRIPTS, entry), os.path.join(scripts, entry))
    target = os.path.join(scripts, "verify")
    shutil.copytree(HERE, target, ignore=shutil.ignore_patterns("__pycache__"))
    path = os.path.join(target, mutant["file"])
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    hits = text.count(mutant["old"])
    if hits != 1:
        raise RuntimeError(f"mutant {mutant['id']}: its anchor occurs {hits} time(s) in "
                           f"{mutant['file']}, not once -- the engine moved; update the anchor")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text.replace(mutant["old"], mutant["new"]))
    return target


def run_mutant(mutant: dict) -> dict:
    with tempfile.TemporaryDirectory(prefix=f"lpm-verify-mutant-{mutant['id']}-") as tmp:
        try:
            target = _mutated_tree(mutant, tmp)
        except RuntimeError as exc:
            return {"id": mutant["id"], "state": "BROKEN", "by": [], "why": str(exc)}
        env = dict(os.environ, LPM_VERIFY_REPO=os.environ.get("LPM_VERIFY_REPO") or ROOT,
                   PYTHONDONTWRITEBYTECODE="1")
        proc = subprocess.run([sys.executable, os.path.join(target, "verify.py"), "self-test",
                               "--cases-only"], env=env, capture_output=True, text=True, timeout=600)
    by = [line.split()[1].rstrip(":") for line in proc.stdout.splitlines() if line.startswith("FAIL ")]
    if proc.returncode == 0:
        state = "SURVIVED"
    elif by:
        state = "killed"
    else:
        state = "BROKEN"
    tail = (proc.stdout + proc.stderr).strip().splitlines()[-2:]
    return {"id": mutant["id"], "state": state, "by": by, "why": "" if by or not tail else " | ".join(tail)}


# ---------------------------------------------------------------------------------------------
# entry
# ---------------------------------------------------------------------------------------------

def main(cases_only: bool = False) -> int:
    passed, failed = run_cases()
    for name, why in failed:
        print(f"FAIL {name}: {why}")
    if cases_only:
        print(f"cases: {len(passed)} passed, {len(failed)} failed")
        return 1 if failed else 0
    if failed:
        print(f"self-test: {len(failed)} of {len(passed) + len(failed)} case(s) FAILED; mutants not run (exit 1)")
        return 1
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(run_mutant, MUTANTS))
    real = [(m, r) for m, r in zip(MUTANTS, results) if not m.get("control")]
    controls = [(m, r) for m, r in zip(MUTANTS, results) if m.get("control")]
    for m, r in real:
        target = ", ".join(r["by"]) if r["by"] else r["why"]
        print(f"  {r['state']:<8} {m['id']:<30} {m['file']:<13} by {target}")
    for m, r in controls:
        verdict = "survived, as it must" if r["state"] == "SURVIVED" else f"{r['state']} -- the harness is wrong"
        print(f"  control  {m['id']:<30} {m['file']:<13} {verdict} {r['why'] if r['state'] != 'SURVIVED' else ''}".rstrip())
    killed = sum(r["state"] == "killed" for _, r in real)
    survived = sum(r["state"] == "SURVIVED" for _, r in real)
    broken = sum(r["state"] == "BROKEN" for _, r in real)
    control_ok = all(r["state"] == "SURVIVED" for _, r in controls)
    ok = killed == len(real) and control_ok
    tail = "" if not broken else f", {broken} broken"
    print(f"self-test: {len(passed)} case(s) passed; {killed} of {len(real)} mutant(s) killed, "
          f"{survived} survived{tail}; control {'survived' if control_ok else 'KILLED'} "
          f"(exit {0 if ok else 1})")
    return 0 if ok else 1
