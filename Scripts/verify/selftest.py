"""`verify.py self-test`: the fixtures, then the mutants that prove the fixtures can fail.

Offline. Issue bodies come from `fixtures/issues/`, and repository quotes from `git show` of commits
on main.

CASES (`fixtures/cases.json`)
    Each case runs one `verify.py` command in this process and requires its exit code and a
    substring of its output. A case may first patch a fixture into a temporary file:
        {"set": [path...], "value": v}        set one key or index
        {"delete": [path...]}                 remove one key
        {"insert": [path...], "at": i, "value": v}   insert into a list
        {"move": [path...], "from": i, "to": j}      reorder a list
        {"copy": [path...], "to": [path...]}  copy one subtree over another
        {"obs": [locale, row, step], "raw": v, "keep_bytes": bool}
                                              store v as that observation's raw text; with
                                              keep_bytes the stored byte count is left as it was
        {"bind": true}                        write a temporary binary, hash it, and make the
                                              evidence built-by-verifier over it, so the
                                              provenance the engine verifies is real on this host
        "resha": true                         recompute spec_sha256 after editing the embedded spec
        "restamp": true                       recompute the stored verdicts with the engine, so the
                                              case judges the observations, not a verdict mismatch
    A case may name a guard to run afterwards (`then`), as a subprocess, or a built-in check
    (`check`) that needs more than one command.

MUTANTS
    Each mutant is one textual rewrite of one file, applied to a temporary copy of Scripts/verify.
    The copy's `self-test --cases-only` must then fail, naming at least one case: that case is the
    fixture that catches the mutant. A mutant that leaves every case passing SURVIVES, and one
    survivor fails the self-test. A mutant that makes the copy fail without naming a case is
    BROKEN (it tests the harness, not the engine) and also fails the self-test. The control
    mutant changes a docstring and must survive; if it is killed, the harness is what fails.

    Every operator of predicates.OPS gets two generated mutants: one that always passes and one
    that never does. `coverage_problems` fails the self-test when an operator lacks either, lacks
    a case named `op-<name>-fails`, is missing from `fixtures/spec-ops.json`, or when the schema's
    operator enum and predicates.OPS differ. A new operator therefore cannot ship untested.
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
    {"id": "unreadable-is-pass", "file": "predicates.py",
     "old": "if isinstance(actual, Unreadable):\n        return UNREADABLE, actual.reason",
     "new": "if isinstance(actual, Unreadable):\n        return PASS, actual.reason"},
    {"id": "counterexamples-skipped", "file": "engine.py",
     "old": '    for k, cx in enumerate(row["counterexample"]):\n        swapped = dict(values)',
     "new": '    for k, cx in enumerate(row["counterexample"][:0]):\n        swapped = dict(values)'},
    {"id": "restore-skipped", "file": "engine.py",
     "old": 'restore = [_judge_one(e, lookup, locale, resolve_canon) for e in row["restore_expect"]]',
     "new": "restore = []"},
    {"id": "subset-reason-ignored", "file": "engine.py",
     "old": 'if not locales["reason"].strip():',
     "new": 'if False and not locales["reason"].strip():'},
    {"id": "criterion-from-any-document", "file": "engine.py",
     "old": "    if not CRITERION_DOC.match(doc):",
     "new": "    if False:"},
    {"id": "effect-before-operation-allowed", "file": "engine.py",
     "old": "        if when(i) < at:",
     "new": "        if False:"},
    {"id": "counterexample-after-operation-allowed", "file": "engine.py",
     "old": 'if order.get(cx["observation"], -1) >= at:',
     "new": "if False:"},
    {"id": "invariant-credited-as-proof", "file": "engine.py",
     "old": 'elif expect[i].get("invariant"):',
     "new": "elif False:"},
    {"id": "unlisted-effect-allowed", "file": "engine.py",
     "old": '            else:\n                out.append(f"expect[{i}] is an effect over the independent',
     "new": '            elif False:\n                out.append(f"expect[{i}] is an effect over the independent'},
    {"id": "independence-rule-off", "file": "engine.py",
     "old": "    if not credited:",
     "new": "    if False:"},
    {"id": "call-counts-as-independent", "file": "engine.py",
     "old": 'elif "call" in steps[name]:',
     "new": "elif False:"},
    {"id": "stored-verdicts-not-compared", "file": "engine.py",
     "old": 'result["mismatches"] = compare_verdicts(counted, recomputed)',
     "new": 'result["mismatches"] = []'},
    {"id": "binding-ignored", "file": "engine.py",
     "old": "if binary.get(E.BINDING) != E.BOUND:",
     "new": "if False:"},
    {"id": "provenance-not-measured", "file": "engine.py",
     "old": "        verified, why = provenance(binary)",
     "new": '        verified, why = True, ""'},
    {"id": "provenance-file-unchecked", "file": "engine.py",
     "old": "    if not (isinstance(path, str) and os.path.isfile(path)):",
     "new": "    if False:"},
    {"id": "provenance-hash-unchecked", "file": "engine.py",
     "old": "    if measured != sha:",
     "new": "    if False:"},
    {"id": "provenance-head-unchecked", "file": "engine.py",
     "old": '    if proc.returncode != 0:\n        return False, f"head',
     "new": '    if False:\n        return False, f"head'},
    {"id": "locale-mismatch-ignored", "file": "engine.py",
     "old": "        if status == MISMATCHED:",
     "new": "        if False:"},
    {"id": "locale-unverified-ignored", "file": "engine.py",
     "old": "        if status == UNVERIFIED:",
     "new": "        if False:"},
    {"id": "locale-setting-unchecked", "file": "engine.py",
     "old": "    if leading != [code]:",
     "new": "    if False:"},
    {"id": "locale-title-unchecked", "file": "engine.py",
     "old": '    if not isinstance(names.get("value"), list) or title.get("value") not in names["value"]:',
     "new": "    if False:"},
    {"id": "entry-shape-unchecked", "file": "engine.py",
     "old": '                out += entry_problems(entry, f"{at}.rows.{rid}.observations.{name}")',
     "new": "                pass"},
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
     "old": ('    elif result["failures"] or result["mismatches"]:\n        result["exit"] = EXIT_FAILED\n'
             '    elif result["incomplete"]:\n        result["exit"] = EXIT_INCOMPLETE'),
     "new": ('    elif result["incomplete"]:\n        result["exit"] = EXIT_INCOMPLETE\n'
             '    elif result["failures"] or result["mismatches"]:\n        result["exit"] = EXIT_FAILED')},
    {"id": "quote-always-holds", "file": "engine.py",
     "old": "return bool(quote) and quote in text",
     "new": "return True"},
    {"id": "recheck-exits-clean", "file": "verify.py",
     "old": "(exit {result['exit']})\")\n    return result[\"exit\"]",
     "new": "(exit {result['exit']})\")\n    return 0"},
    {"id": "evidence-named-by-basename", "file": "verify.py",
     "old": 'name = E.publish_content_addressed(os.path.join(args.out, "evidence"), data)',
     "new": ('name = os.path.basename(args.evidence); '
             'E.write_bytes_atomic(os.path.join(args.out, "evidence", name), data)')},
    {"id": "count_eq-one-element-passes", "file": "predicates.py",
     "old": '"count_eq": (True, lambda a, b: _count(a, b) and len(a) == b),',
     "new": '"count_eq": (True, lambda a, b: _count(a, b) and len(a) >= 1),'},
    {"id": "operator-shipped-without-coverage", "file": "predicates.py",
     "old": '    "count_ge": (True, lambda a, b: _count(a, b) and len(a) >= b),',
     "new": ('    "count_ge": (True, lambda a, b: _count(a, b) and len(a) >= b),\n'
             '    "count_le": (True, lambda a, b: _count(a, b) and len(a) <= b),')},
    {"id": "control", "file": "engine.py", "control": True,
     "old": '"""The verdict on one evidence document.',
     "new": '"""The verdict on one evidence document (control: a docstring edit, no behaviour).'},
]


def operator_mutants() -> list:
    """Two per operator of predicates.OPS, generated from the table itself: always-passes and
    never-passes. Their anchor is the operator's own entry, so a renamed or reshaped entry is a
    BROKEN mutant (the self-test fails) rather than a silently skipped one."""
    import predicates as P
    out = []
    for op, (needs, _) in P.OPS.items():
        anchor = f'"{op}": ({needs}, lambda a, b: '
        out.append({"id": f"op-{op}-always-passes", "file": "predicates.py", "op": op,
                    "old": anchor, "new": anchor + "True or "})
        out.append({"id": f"op-{op}-never-passes", "file": "predicates.py", "op": op,
                    "old": anchor, "new": anchor + "False and "})
    return out


def coverage_problems(cases: list) -> list:
    """Why the operator set is not fully covered, mechanically. Empty when every op has both
    mutants, a case named op-<name>-fails, and a use in fixtures/spec-ops.json, and when the
    schema's operator enum is exactly predicates.OPS."""
    import engine
    import predicates as P
    ops = set(P.OPS)
    out = []
    kinds = {}
    for m in operator_mutants():
        kinds.setdefault(m["op"], set()).add(m["id"].rsplit("-", 2)[-2])
    for op in sorted(ops):
        if kinds.get(op) != {"always", "never"}:
            out.append(f"operator {op!r} lacks an always-passes and a never-passes mutant")
    names = {c["name"] for c in cases}
    out += [f"operator {op!r} has no case named 'op-{op}-fails'" for op in sorted(ops)
            if f"op-{op}-fails" not in names]
    with open(os.path.join(FIXTURES, "spec-ops.json"), encoding="utf-8") as handle:
        used = {e["op"] for row in json.load(handle)["rows"] for e in row["expect"]}
    out += [f"operator {op!r} is not used in fixtures/spec-ops.json" for op in sorted(ops - used)]
    enum = set(engine.load_schema()["$defs"]["op"]["enum"])
    if enum != ops:
        out.append(f"the schema's operator enum {sorted(enum)} is not predicates.OPS {sorted(ops)}")
    return out


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


def _bind(doc: dict, label: str, tmp: str) -> None:
    """A real file on this host, and a binary block that tells the truth about it."""
    import evidence_doc as E
    path = os.path.join(tmp, "bin", f"{label}.bin")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(f"self-test binary for {label}\n".encode("utf-8"))
    doc["binary"].update({E.BINARY_PATH: path, E.BINARY_SHA256: E.sha256_of_file(path),
                          E.BINDING: E.BOUND})


def _apply(doc, ops: list, label: str, where: dict) -> None:
    for op in ops:
        if "set" in op:
            parent, key = _descend(doc, op["set"])
            parent[key] = copy.deepcopy(op["value"])
        elif "delete" in op:
            parent, key = _descend(doc, op["delete"])
            del parent[key]
        elif "insert" in op:
            parent, key = _descend(doc, op["insert"])
            parent[key].insert(op["at"], copy.deepcopy(op["value"]))
        elif "move" in op:
            parent, key = _descend(doc, op["move"])
            parent[key].insert(op["to"], parent[key].pop(op["from"]))
        elif "obs" in op:
            locale, row, step = op["obs"]
            entry = doc["runs"][locale]["rows"][row]["observations"][step]
            entry["raw"] = json.dumps(op["raw"], ensure_ascii=False, sort_keys=True)
            if not op.get("keep_bytes"):
                entry["raw_bytes"] = len(entry["raw"].encode("utf-8"))
        elif "copy" in op:
            source, key = _descend(doc, op["copy"])
            parent, into = _descend(doc, op["to"])
            parent[into] = copy.deepcopy(source[key])
        elif "bind" in op:
            _bind(doc, label, where["tmp"])
        else:
            raise ValueError(f"{label}: unknown patch op {op}")


def _patched(case: dict, where: dict) -> str:
    import engine
    import evidence_doc as E
    patch = case["patch"]
    with open(_fill(patch["file"], where), encoding="utf-8") as handle:
        doc = json.load(handle)
    _apply(doc, patch["ops"], case["name"], where)
    if patch.get("resha"):
        doc["spec_sha256"] = E.sha256_of(doc["spec"])
    if patch.get("restamp"):
        for locale, run in doc["runs"].items():
            doc["verdicts"][locale] = engine.evaluate_run(doc["spec"], run, locale)
    path = os.path.join(where["tmp"], f"{case['name']}.json")
    E.write_atomic(path, doc)
    return path


def _verify(argv: list):
    """(exit, output) of one verify.py command run in this process."""
    import verify
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        try:
            code = verify.main(argv)
        except Exception as exc:  # a crash is a failed case, reported with its type
            code = f"crash {type(exc).__name__}: {exc}"
    return code, out.getvalue()


def _guard(script: str, env_extra: dict):
    env = dict(os.environ, **env_extra)
    proc = subprocess.run([sys.executable, os.path.join(SCRIPTS, script)], env=env,
                          capture_output=True, text=True, timeout=120)
    return proc.returncode, proc.stdout + proc.stderr


def check_records_cite_their_bytes(case: dict, where: dict):
    """RV-05: two runs recorded from files that share a basename. Each record must cite a file
    whose bytes hash to its name and judge to the verdict the record states, and the earlier
    records must still cite the earlier bytes."""
    import engine
    import evidence_doc as E
    import verify
    with open(os.path.join(FIXTURES, "ev-base.json"), encoding="utf-8") as handle:
        base = json.load(handle)
    out = os.path.join(where["tmp"], "record-twice")
    first_sha = None
    for sub, date, armed in (("a", "2026-09-27", True), ("b", "2026-09-28", False)):
        doc = copy.deepcopy(base)
        _apply(doc, [{"bind": True}, {"obs": ["ko", "arm-sets", "post"], "raw": {"armed": armed, "track": 0}}],
               f"record-twice-{sub}", where)
        for run in doc["runs"].values():
            run["date"] = date
        for locale, run in doc["runs"].items():
            doc["verdicts"][locale] = engine.evaluate_run(doc["spec"], run, locale)
        path = os.path.join(where["tmp"], f"record-twice-{sub}", "same.json")
        E.write_atomic(path, doc)
        with open(path, "rb") as handle:
            first_sha = first_sha or E.sha256_of_bytes(handle.read())
        code, text = _verify(["record", path, "--out", out])
        if code != 0:
            return f"record of run {sub}: exit {code}; {text.strip().splitlines()[-1:]}"
    files = sorted(os.listdir(os.path.join(out, "evidence")))
    if len(files) != 2:
        return f"{len(files)} evidence file(s) after recording two different runs, wanted 2: {files}"
    records = sorted(f for f in os.listdir(out) if f.endswith(".json"))
    if len(records) != 4:
        return f"{len(records)} record(s), wanted 4"
    for name in records:
        with open(os.path.join(out, name), encoding="utf-8") as handle:
            record = json.load(handle)
        cited = record["evidence"][0]
        with open(os.path.join(out, cited), "rb") as handle:
            data = handle.read()
        if E.sha256_of_bytes(data) != os.path.splitext(os.path.basename(cited))[0]:
            return f"{name} cites {cited}, whose bytes do not hash to its name"
        if record["date"] == "2026-09-27" and not cited.endswith(f"{first_sha}.json"):
            return f"{name}, from the earlier run, cites {cited}, not the earlier bytes"
        doc = json.loads(data.decode("utf-8"))
        locale = next(k for k, r in doc["runs"].items() if r["host"]["locale"] == record["host"]["locale"])
        judged = engine.judge(doc)["verdicts"][locale]
        again = verify.build_record(doc, locale, judged, cited)["verdict"]
        if again != record["verdict"]:
            return f"{name} says {record['verdict']!r}; the bytes it cites judge to {again!r}"
    code, text = _guard("check-observation-records.py", {"LPM_OBSERVATIONS_DIR": out})
    if code != 0:
        return f"check-observation-records on the two runs' records: exit {code}; {text.strip().splitlines()[-2:]}"
    return None


CHECKS = {"records_cite_their_bytes": check_records_cite_their_bytes}


def run_case(case: dict, where: dict):
    """None when the case holds, else why not."""
    if "check" in case:
        return CHECKS[case["check"]](case, where)
    where = dict(where)
    if "patch" in case:
        where["patched"] = _patched(case, where)
    code, text = _verify([_fill(a, where) for a in case["cmd"]])
    if code != case["exit"]:
        return f"exit {code}, wanted {case['exit']}; last line: {text.strip().splitlines()[-1:]}"
    if case["says"] not in text:
        return f"exit {code} as wanted, but the output does not say {case['says']!r}"
    then = case.get("then")
    if then:
        code, text = _guard(then["script"], {k: _fill(v, where) for k, v in then["env"].items()})
        if code != then["exit"] or then["says"] not in text:
            return f"then {then['script']}: exit {code}, wanted {then['exit']}; {text.strip().splitlines()[-3:]}"
    return None


def load_cases() -> list:
    with open(CASES, encoding="utf-8") as handle:
        cases = json.load(handle)
    names = [c["name"] for c in cases]
    if len(set(names)) != len(names):
        raise SystemExit("fixtures/cases.json names a case twice")
    return cases


def run_cases(cases: list) -> tuple:
    """(names passed, [(name, why)] failed)."""
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
    by = list(dict.fromkeys(line.split()[1].rstrip(":") for line in proc.stdout.splitlines()
                            if line.startswith("FAIL ")))
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
    cases = load_cases()
    passed, failed = run_cases(cases)
    failed += [("coverage", why) for why in coverage_problems(cases)]
    for name, why in failed:
        print(f"FAIL {name}: {why}")
    if cases_only:
        print(f"cases: {len(passed)} passed, {len(failed)} failed")
        return 1 if failed else 0
    if failed:
        print(f"self-test: {len(failed)} of {len(passed) + len(failed)} case(s) FAILED; mutants not run (exit 1)")
        return 1
    mutants = MUTANTS + operator_mutants()
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(run_mutant, mutants))
    real = [(m, r) for m, r in zip(mutants, results) if not m.get("control")]
    controls = [(m, r) for m, r in zip(mutants, results) if m.get("control")]
    for m, r in real:
        target = ", ".join(r["by"]) if r["by"] else r["why"]
        print(f"  {r['state']:<8} {m['id']:<38} {m['file']:<13} by {target}")
    for m, r in controls:
        verdict = "survived, as it must" if r["state"] == "SURVIVED" else f"{r['state']} -- the harness is wrong"
        print(f"  control  {m['id']:<38} {m['file']:<13} {verdict} {r['why'] if r['state'] != 'SURVIVED' else ''}".rstrip())
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
