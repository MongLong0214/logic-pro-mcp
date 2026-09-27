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
                                              store v as that observation's raw text (an
                                              unreadable one becomes readable); with keep_bytes
                                              the stored byte count is left as it was
        {"bind": true}                        write a temporary binary, hash it, and make the
                                              evidence built-by-verifier over it, so the file the
                                              host checks is real on this host
        {"bind_to": path}                     point the evidence at an existing file with its real
                                              sha256: what a forger can do (RV-02, round 2)
        "resha": true                         recompute spec_sha256 after editing the embedded spec
        "restamp": true                       recompute the stored verdicts with the engine, so the
                                              case judges the observations, not a verdict mismatch
    A case may name a guard to run afterwards (`then`), as a subprocess, or a built-in check
    (`check`) that needs more than one command.

ATTESTED CASES (`"attest": {...}`)
    A command-line `recheck` reads a file, and a file cannot attest to how it was made, so it is
    never clean (engine.Attestation). A case with `attest` plays the P0b runner instead: it keeps
    the patched document in this process, builds an `engine.Attestation` over it with `attest`,
    applies the `after` ops (a change made after the attestation was taken), then judges it in
    process: `"cmd": ["recheck"]` calls engine.judge and prints with verify.report, and
    `"cmd": ["record", out]` calls verify.record_attested. The attestation holds what this
    harness measured as the runner -- the binary `bind` wrote and hashed, the head it wrote, the
    locale readings fixtures_build generates -- and never the document's own claims:
        "builder_sha256": hex     the builder measured this sha256 instead of the bound file's
        "checked_out": hex        the verifier checked out this head instead of SELFTEST_HEAD
        "readings": {locale: lproj|null}   the runner's reading per locale (default: each run's own)
        "lookalike": true         pass an object with the same fields that is not an Attestation
        "after": [ops]            patch ops applied after the attestation was taken

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

import ast
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
import types

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
ROOT = os.path.dirname(SCRIPTS)
FIXTURES = os.path.join(HERE, "fixtures")
CASES = os.path.join(FIXTURES, "cases.json")
#: The head the self-test "checks out" when it plays the runner: a commit of main that the fixtures
#: already name (fixtures_build.UNBOUND_BINARY), so the host's head check can agree with it.
SELFTEST_HEAD = "d81c7e5b0d4ba2c2531dc3432809bd3e8697c4ea"

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
     "old": "        if order[root] < at:",
     "new": "        if False:"},
    {"id": "invariant-after-operation-allowed", "file": "engine.py",
     "old": "            if max(read) >= at:",
     "new": "            if False:"},
    {"id": "call-after-operation-allowed", "file": "engine.py",
     "old": '    for name in names[at + 1:]:\n        if "call" in steps[name]:',
     "new": '    for name in names[at + 1:]:\n        if False:'},
    {"id": "witness-of-another-kind-allowed", "file": "engine.py",
     "old": "            if witness != replaced:",
     "new": "            if False:"},
    {"id": "baseline-before-a-call-allowed", "file": "engine.py",
     "old": "                    if order[baseline] < last_call:",
     "new": "                    if False:"},
    {"id": "witness-before-a-call-allowed", "file": "engine.py",
     "old": "                elif calls_before and not any(order.get(w, -1) > last_call for w in witnesses.get(i, [])):",
     "new": "                elif False:"},
    {"id": "self-comparison-allowed", "file": "engine.py",
     "old": '            elif ref_root == _safe_root(e["path"]):',
     "new": "            elif False:"},
    {"id": "restore-reads-before-operation-allowed", "file": "engine.py",
     "old": "        if root in order and order[root] <= at:",
     "new": "        if False:"},
    {"id": "counterexample-after-operation-allowed", "file": "engine.py",
     "old": 'if order.get(cx["observation"], -1) >= at:',
     "new": "if False:"},
    {"id": "invariant-credited-as-proof", "file": "engine.py",
     "old": 'elif expect[i].get("invariant"):',
     "new": "elif False:"},
    {"id": "unlisted-effect-allowed", "file": "engine.py",
     "old": "            if i not in listed:",
     "new": "            if False:"},
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
     "old": "        consistent, why = provenance(binary)",
     "new": '        consistent, why = True, ""'},
    {"id": "host-provenance-grants-measured", "file": "engine.py",
     "old": "    unattested = attestation_problems(attestation, doc)",
     "new": "    unattested = []"},
    {"id": "attestation-type-unchecked", "file": "engine.py",
     "old": "    if not isinstance(attestation, Attestation):",
     "new": "    if False:"},
    {"id": "attestation-binary-unchecked", "file": "engine.py",
     "old": "    if attestation.binary_sha256 != binary.get(E.BINARY_SHA256):",
     "new": "    if False:"},
    {"id": "attestation-head-unchecked", "file": "engine.py",
     "old": "    if attestation.head != binary.get(E.HEAD):",
     "new": "    if False:"},
    {"id": "attestation-locale-unchecked", "file": "engine.py",
     "old": "        elif not P.same(attestation.locale_readings[locale], runs[locale].get(E.LOCALE_READING)):",
     "new": "        elif False:"},
    {"id": "attestation-digest-unchecked", "file": "engine.py",
     "old": "    if attestation.evidence_sha256 != digest:",
     "new": "    if False:"},
    {"id": "attestation-built-from-the-file", "file": "verify.py",
     "old": "    result = engine.judge(doc, expected_spec=expected, attestation=None)",
     "new": ('    result = engine.judge(doc, expected_spec=expected, attestation=engine.Attestation('
             '**doc["attestation"]) if isinstance(doc.get("attestation"), dict) else None)')},
    {"id": "attestation-reached-by-getattr", "file": "verify.py",
     "old": "    result = engine.judge(doc, expected_spec=expected, attestation=None)",
     "new": ('    made = getattr(engine, "Attest" "ation")\n'
             '    result = engine.judge(doc, expected_spec=expected, attestation=made('
             '**doc["attestation"]) if isinstance(doc.get("attestation"), dict) else None)')},
    {"id": "attestation-restamped-after-a-change", "file": "verify.py",
     "old": "    result = engine.judge(doc, attestation=attestation)",
     "new": ("    import dataclasses\n"
             "    attestation = dataclasses.replace(attestation, evidence_sha256=E.sha256_of(doc))\n"
             "    result = engine.judge(doc, attestation=attestation)")},
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
    {"id": "evidence-not-content-addressed", "file": "verify.py",
     "old": 'name = E.publish_content_addressed(os.path.join(out, "evidence"), data)',
     "new": ('name = "evidence.json"; '
             'E.write_bytes_atomic(os.path.join(out, "evidence", name), data)')},
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
        if isinstance(value, str):
            text = text.replace("{" + key + "}", value)
    return text


def _descend(node, path):
    for key in path[:-1]:
        node = node[key]
    return node, path[-1]


def _bind(doc: dict, label: str, where: dict) -> None:
    """A real file on this host, and a binary block that tells the truth about it. The sha256 is
    what this harness, as the builder, measured; `attest` takes it from `where["measured"]`, never
    from the document."""
    import evidence_doc as E
    path = os.path.join(where["tmp"], "bin", f"{label}.bin")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(f"self-test binary for {label}\n".encode("utf-8"))
    measured = E.sha256_of_file(path)
    where["measured"][label] = measured
    doc["binary"].update({E.BINARY_PATH: path, E.BINARY_SHA256: measured, E.HEAD: SELFTEST_HEAD,
                          E.BINDING: E.BOUND})


def _bind_to(doc: dict, path: str) -> None:
    """What a forger can write: any existing file, its real sha256, and the fixture's real commit."""
    import evidence_doc as E
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
            entry.pop("unreadable", None)
            entry["raw"] = json.dumps(op["raw"], ensure_ascii=False, sort_keys=True)
            if not op.get("keep_bytes"):
                entry["raw_bytes"] = len(entry["raw"].encode("utf-8"))
        elif "copy" in op:
            source, key = _descend(doc, op["copy"])
            parent, into = _descend(doc, op["to"])
            parent[into] = copy.deepcopy(source[key])
        elif "bind" in op:
            _bind(doc, label, where)
        elif "bind_to" in op:
            _bind_to(doc, _fill(op["bind_to"], where))
        else:
            raise ValueError(f"{label}: unknown patch op {op}")


def _patched_doc(case: dict, where: dict) -> dict:
    import engine
    import evidence_doc as E
    patch = case["patch"]
    with open(_fill(patch["file"], where), encoding="utf-8") as handle:
        doc = json.load(handle)
    _apply(doc, patch["ops"], case["name"], where)
    if patch.get("resha"):
        doc["spec_sha256"] = E.sha256_of(doc["spec"])
    if patch.get("restamp"):
        _restamp(doc)
    return doc


def _restamp(doc: dict) -> None:
    import engine
    for locale, run in doc["runs"].items():
        doc["verdicts"][locale] = engine.evaluate_run(doc["spec"], run, locale)


def _patched(case: dict, where: dict) -> str:
    import evidence_doc as E
    path = os.path.join(where["tmp"], f"{case['name']}.json")
    E.write_atomic(path, _patched_doc(case, where))
    return path


def attest(doc: dict, spec: dict, label: str, where: dict):
    """The ONE place outside P0b-2's `run` that builds an `engine.Attestation`, and it is in process.

    Here the self-test plays the runner. Every field is what the runner measured, not what the
    document says: the sha256 `_bind` measured when it wrote the binary, the head the harness
    uses, the locale readings fixtures_build generates for each locale it ran, and the digest of
    the document as the runner holds it at this moment. The self-test check
    `attestation-built-only-in-process` holds this function to that: it reads no file, parses no
    JSON and never reads the document's binary block or stored locale readings."""
    import engine
    import evidence_doc as E
    import fixtures_build
    readings = spec.get("readings", {locale: locale for locale in doc["runs"]})
    fields = {
        "binary_sha256": spec.get("builder_sha256") or where["measured"][label],
        "head": spec.get("checked_out") or SELFTEST_HEAD,
        "locale_readings": {locale: None if lproj is None else fixtures_build.locale_reading(lproj)
                            for locale, lproj in readings.items()},
        "evidence_sha256": E.sha256_of(doc),
    }
    if spec.get("lookalike"):
        return types.SimpleNamespace(**fields)
    return engine.Attestation(**fields)


def _run_attested(case: dict, where: dict):
    """(exit, output) of one case judged in this process with an attestation, as `run` will."""
    import engine
    import evidence_doc as E
    import verify
    doc = _patched_doc(case, where)
    attestation = attest(doc, case["attest"], case["name"], where)
    _apply(doc, case["attest"].get("after", []), case["name"], where)
    if case["attest"].get("after_restamp"):
        _restamp(doc)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        try:
            if case["cmd"][0] == "recheck":
                code = verify.report(engine.judge(doc, attestation=attestation),
                                     f"recheck in process, attested: {case['name']}")
            elif case["cmd"][0] == "record":
                code = verify.record_attested(E.serialize(doc), attestation, _fill(case["cmd"][1], where))
            else:
                raise ValueError(f"an attested case runs recheck or record, not {case['cmd'][0]!r}")
        except Exception as exc:  # a crash is a failed case, reported with its type
            code = f"crash {type(exc).__name__}: {exc}"
    return code, out.getvalue()


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
    """RV-05: two different runs recorded into one directory. Each record must cite a file whose
    bytes hash to its name and judge to the verdict the record states, and the earlier records
    must still cite the earlier bytes. The command line no longer records a file (RV-02, round 2),
    so both runs go through `verify.record_attested` in process, each with its own attestation."""
    import engine
    import evidence_doc as E
    import verify
    with open(os.path.join(FIXTURES, "ev-base.json"), encoding="utf-8") as handle:
        base = json.load(handle)
    out = os.path.join(where["tmp"], "record-twice")
    first_sha = None
    for sub, date, armed in (("a", "2026-09-27", True), ("b", "2026-09-28", False)):
        doc = copy.deepcopy(base)
        label = f"record-twice-{sub}"
        _apply(doc, [{"bind": True}, {"obs": ["ko", "arm-sets", "post"], "raw": {"armed": armed, "track": 0}}],
               label, where)
        for run in doc["runs"].values():
            run["date"] = date
        _restamp(doc)
        data = E.serialize(doc)
        first_sha = first_sha or E.sha256_of_bytes(data)
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            code = verify.record_attested(data, attest(doc, {}, label, where), out)
        if code != 0:
            return f"record of run {sub}: exit {code}; {printed.getvalue().strip().splitlines()[-1:]}"
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


#: Where an `engine.Attestation` may be named, as (file, top-level definition). The class itself,
#: the engine's type check, and the self-test's in-process `attest`. Nothing else: no command-line
#: path and nothing that reads a file.
ATTESTATION_SITES = {("engine.py", "Attestation"), ("engine.py", "attestation_problems"),
                     ("selftest.py", "attest")}
#: Modules that rebuild objects without a visible constructor call.
UNPICKLERS = {"pickle", "marshal", "shelve", "copyreg", "dill", "cloudpickle", "importlib"}
#: What `attest` may not do: read a file or parse JSON, or read the document's own binding claims.
FILE_READS = {"open", "load", "loads", "read", "read_text", "read_bytes", "sha256_of_file"}
CLAIM_KEYS = {"binary", "binary_path", "binary_sha256", "head", "binding", "locale_reading"}
CLAIM_ATTRS = {"BINARY_PATH", "BINARY_SHA256", "HEAD", "BINDING", "LOCALE_READING"}


def _top_level_sites(tree):
    """(top-level definition name or None, node) for every node of a module."""
    for top in tree.body:
        name = top.name if isinstance(top, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) else None
        for node in ast.walk(top):
            yield name, node


def attestation_construction_problems(root: str = HERE) -> list:
    """Why something other than the in-process sites could build, alias or forge an Attestation."""
    target = "Attest" + "ation"  # spelt apart so this checker does not name it as a string itself
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in ("__pycache__", "fixtures"))
        for fname in sorted(f for f in filenames if f.endswith(".py")):
            path = os.path.join(dirpath, fname)
            rel = os.path.relpath(path, root)
            with open(path, encoding="utf-8") as handle:
                tree = ast.parse(handle.read(), rel)
            for site, node in _top_level_sites(tree):
                here = f"{rel}:{getattr(node, 'lineno', '?')}"
                allowed = (rel, site) in ATTESTATION_SITES
                if isinstance(node, ast.Name) and node.id == target and not allowed:
                    out.append(f"{here} names {target} outside the in-process sites")
                elif isinstance(node, ast.Attribute) and node.attr == target and not allowed:
                    out.append(f"{here} reaches {target} as an attribute outside the in-process sites")
                elif isinstance(node, (ast.Import, ast.ImportFrom)):
                    module = getattr(node, "module", None) or ""
                    for alias in node.names:
                        if alias.name in (target, "*") or alias.name.split(".")[0] in UNPICKLERS \
                                or module.split(".")[0] in UNPICKLERS:
                            out.append(f"{here} imports {module + '.' if module else ''}{alias.name}")
                elif isinstance(node, ast.Call):
                    func = node.func
                    if isinstance(func, ast.Name) and func.id in ("getattr", "setattr", "hasattr",
                                                                    "delattr", "__import__"):
                        if func.id == "__import__" or any(
                                isinstance(a, ast.Constant) and a.value == target for a in node.args):
                            out.append(f"{here} looks {target} up by name with {func.id}")
                    elif isinstance(func, ast.Attribute) and func.attr == "replace" \
                            and isinstance(func.value, ast.Name) and func.value.id in ("dataclasses", "copy"):
                        out.append(f"{here} copies a dataclass with new fields ({func.value.id}.replace)")
                    elif isinstance(func, ast.Attribute) and func.attr in ("__setattr__", "__new__") \
                            and (rel, site) != ("engine.py", target):
                        out.append(f"{here} calls {func.attr}, which can set a frozen field or skip __init__")
                elif isinstance(node, ast.Subscript) and isinstance(node.slice, ast.Constant) \
                        and node.slice.value == target:
                    out.append(f"{here} looks {target} up by name with a subscript")
                if rel == "selftest.py" and site == "attest":
                    if isinstance(node, ast.Call):
                        called = node.func.attr if isinstance(node.func, ast.Attribute) else \
                            node.func.id if isinstance(node.func, ast.Name) else None
                        if called in FILE_READS:
                            out.append(f"{here}: attest calls {called}; the attestation is built in "
                                       f"process from what the runner measured, not from a file")
                    if isinstance(node, ast.Subscript) and isinstance(node.slice, ast.Constant) \
                            and node.slice.value in CLAIM_KEYS:
                        out.append(f"{here}: attest reads the document's {node.slice.value!r}; an "
                                   f"attestation that copies the document's claims attests nothing")
                    if isinstance(node, ast.Attribute) and node.attr in CLAIM_ATTRS:
                        out.append(f"{here}: attest reads the document's {node.attr}; an attestation "
                                   f"that copies the document's claims attests nothing")
            if rel != "selftest.py":
                for site, node in _top_level_sites(tree):
                    if (isinstance(node, ast.Attribute) and node.attr == "attest") or \
                            (isinstance(node, ast.Name) and node.id == "attest"):
                        out.append(f"{rel}:{node.lineno} calls the self-test's attest outside the self-test")
    return out


def check_attestation_built_only_in_process(case: dict, where: dict):
    """RV-02, round 2: nothing builds an Attestation from JSON or from a file. Parses every .py
    under Scripts/verify; a construction, alias, subclass, by-name lookup, dataclass copy with new
    fields, or unpickling anywhere but the in-process sites fails."""
    problems = attestation_construction_problems()
    return "; ".join(problems) if problems else None


CHECKS = {"records_cite_their_bytes": check_records_cite_their_bytes,
          "attestation_built_only_in_process": check_attestation_built_only_in_process}


def run_case(case: dict, where: dict):
    """None when the case holds, else why not."""
    if "check" in case:
        try:
            return CHECKS[case["check"]](case, where)
        except Exception as exc:  # a crash is a failed case, reported with its type
            return f"crash {type(exc).__name__}: {exc}"
    where = dict(where)
    if "attest" in case:
        code, text = _run_attested(case, where)
    else:
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
            where = {"fixtures": FIXTURES, "root": ROOT, "tmp": tmp, "measured": {}}
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
