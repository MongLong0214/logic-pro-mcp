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
        {"obs": [locale, row, step], "text": s}   store s itself as the raw text: text no value
                                              serializes to, such as a key given twice
        {"bind": true}                        write a temporary binary, hash it, and make the
                                              evidence built-by-verifier over it, so the file the
                                              host checks is real on this host
        {"bind_to": path}                     point the evidence at an existing file with its real
                                              sha256: what a forger can do (RV-02, round 2)
        "resha": true                         recompute spec_sha256 after editing the embedded spec
        "restamp": true                       recompute the stored verdicts with the engine, so the
                                              case judges the observations, not a verdict mismatch
        "edit_text": [old, new]               after the ops, replace the one occurrence of old in the
                                              written file's text with new: a document no value
                                              serializes to, such as one with a key given twice
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

RUN CASES (`"run": {...}`)
    The runner (runner.py) driven in this process over `FakeLifecycle`, a scripted world on a fake
    clock: the case names a spec fixture (`spec`), patch ops for it (`spec_ops`), the locales, and
    a `script` of what the world answers. `runner.run_spec(..., _life=FakeLifecycle(...))` builds
    a temporary binary, "switches", drives every step, writes the evidence, attests it in process
    and judges it; the case requires its exit code and a substring of its output. `events` counts
    what the lifecycle was asked to do ({"switch": 0}); `start_env` requires every server start to
    carry those variables; `recheck` then rechecks the written file from the command line;
    `"record": true` passes a records directory, as `run --record` does, `"record_readings":
    {row: [name, ...]}` requires every record's readings for that row to be exactly those step
    names, and `"records_written": n` requires exactly n records in that directory afterwards.
    `"entries": [{"spec",
    "spec_ops"?, "head"?, "locales"?}, ...]` in place of `spec` runs them as one
    `runner.run_batch`. The script:
        "answers": {"[<lproj>/]<row>/<as>": answer | [answer, ...]}   a list answers successive
                  reads in turn and repeats its last; an answer is {"value": v} (stored as its JSON
                  text), {"text": s}, {"unreadable": why} or {"timeout": true}. Unscripted steps
                  answer fixtures_build.READINGS for the spec.
        "dirt":   {"before:<row>/<as>" | "after:<row>/<as>": [dirt, ...]}
        "gate":   {lproj: [[op, ...], ...]}   successive fixture readings in that locale, each as
                  patch ops over a clean one (FAKE_TRACKS, every flag 0, upper row FAKE_HOME_ROW, the
                  passing message FAKE_PASSING); the first is the locale's baseline; after the
                  list, clean. {"times": n, "ops": [op, ...]} in the list stands for n readings
        "readings": {lproj: {key: value}}   merged over fixtures_build.locale_reading(lproj)
        "reset":  {lproj: [record, ...]}    successive reset() results in that locale; after the
                                            list, {"confirmed": true}
        "rest":   record                    what rest() returns; unscripted {"in_locale": true}
        "tuple_in_reading": true            the window names come back as a tuple
        "current": lproj                    the locale Logic is in when the run starts
        "poll_limit": n                     the fake raises after n reads of one step, so a wait
                                            that ignores its bound ends
    `"replay": {"evidence": path, "lproj": lproj}` in place of `spec` replays a committed evidence
    document in that one locale: the spec is the one it embeds, run in [lproj] only (so the
    locales it does not run leave the exit at 3 at best); `"spec": path` there judges it against
    that spec file instead, and `"rows": {old: new}` renames the evidence's rows to that spec's ids;
    every unscripted step answers the text the evidence stored for it (an unreadable one its
    reason); the locale reading and host block are the ones it stored; and every gate reading
    starts from the baseline its lifecycle log holds, passing message included, before the
    script's gate ops.

GATE CASES (`"check": "gate"`)
    The gate (setups.gate_problems) over readings recorded live, in live/tests/samples/: a
    track_flags_ax probe output (`walk`) and an MCU upper row (`row`, a key of
    mcu-upper-rows-ko.json), made a reading by runner_live.gate_reading_of against the #1020
    fixture's declaration, and a `baseline` [walk, row] made the same way. The gate must name
    exactly as many problems as `problems` lists, each containing its string; [] must pass.

PROBE CASES (`"check": "probe"`)
    A declared probe run through probes.run as the runner runs it, with live/probes.py's walker
    replaced by a walk recorded live (`walk`, a file of live/tests/samples/, after `walk_ops` patch
    ops on it), or with a server whose logic://mcu/state is `resource_text`. The fixture is the
    #1020 one, as setups.py declares it. The reading must equal `reads` once its `walk_sha256` is
    checked against the walk the probe kept as a sidecar, or the probe must be unreadable saying
    `unreadable`.

REPLY CASES (`"check": "reply"`)
    What a `call` or `read` step stores (D2), over a real stdio server: live/tests/
    fake_mcp_server.py is started through runner_live.McpSession, one step goes through
    runner.execute_step, and the stored entry must hold exactly `stores` (text, compared as str)
    or be unreadable saying `unreadable`. `reply` names the fake's command and params, or a `uri`
    to read; `script` is the file its `scripted` command answers from; `timeout_s` bounds the step.

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
import re
import shutil
import subprocess
import sys
import tempfile
import types

import runner

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
ROOT = os.path.dirname(SCRIPTS)
FIXTURES = os.path.join(HERE, "fixtures")
FAKE_SERVER = os.path.join(HERE, "live", "tests", "fake_mcp_server.py")
#: fake_mcp_server.SCRIPT_ENV. The two are not shared code; a mismatch fails every scripted case.
FAKE_SCRIPT_ENV = "LPM_FAKE_MCP_SCRIPT"
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
     "old": '    for name in names[at + 1:]:\n        if is_call(steps[name]):',
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
     "old": '            elif name in order and what == "reads":',
     "new": "            elif False:"},
    {"id": "restore-reads-after-operation-allowed", "file": "engine.py",
     "old": "            if name in order and order[name] >= at:",
     "new": "            if False:"},
    {"id": "restore-without-a-call-allowed", "file": "engine.py",
     "old": 'restore check to read. {BEFORE_RESTORE}"] if n else []',
     "new": 'restore check to read. {BEFORE_RESTORE}"] if False else []'},
    {"id": "restore-step-before-the-call-counts", "file": "engine.py",
     "old": "    call, left = restore[last], set(restore[last + 1:])",
     "new": "    call, left = restore[last], set(restore)"},
    {"id": "changed-alone-allowed", "file": "engine.py",
     "old": """            for i, e in enumerate(checks) if e["op"] == "changed" and e["path"] not in pinned]""",
     "new": """            for i, e in enumerate(checks) if False]"""},
    {"id": "any-check-pins", "file": "engine.py",
     "old": """              if e["op"] in PIN_OPS and ("value" in e or "canon" in (e.get("ref") or {}))}""",
     "new": """              if e["op"] != "changed"}"""},
    {"id": "canon-does-not-pin", "file": "engine.py",
     "old": """              if e["op"] in PIN_OPS and ("value" in e or "canon" in (e.get("ref") or {}))}""",
     "new": """              if e["op"] in PIN_OPS and "value" in e}"""},
    {"id": "pin-op-unchecked", "file": "engine.py",
     "old": """              if e["op"] in PIN_OPS and ("value" in e or "canon" in (e.get("ref") or {}))}""",
     "new": """              if "value" in e or "canon" in (e.get("ref") or {})}"""},
    {"id": "ne-pins", "file": "engine.py",
     "old": 'PIN_OPS = ("eq", "in", "matches_canon")',
     "new": 'PIN_OPS = ("eq", "in", "matches_canon", "ne")'},
    {"id": "in-does-not-pin", "file": "engine.py",
     "old": 'PIN_OPS = ("eq", "in", "matches_canon")',
     "new": 'PIN_OPS = ("eq", "matches_canon")'},
    {"id": "first-restore-call-only", "file": "engine.py",
     "old": '    last = max((k for k, s in enumerate(row["restore"]) if is_call(s)), default=None)',
     "new": '    last = next((k for k, s in enumerate(row["restore"]) if is_call(s)), None)'},
    {"id": "restore-call-reply-counts", "file": "engine.py",
     "old": "            elif name == call:",
     "new": "            elif False:"},
    {"id": "restore-baseline-before-operation-refused", "file": "engine.py",
     "old": '            elif name in order and what == "reads":',
     "new": "            elif name in order:"},
    {"id": "step-name-reuse-allowed", "file": "engine.py",
     "old": '    out += [f"step name {n!r} is bound twice" for n in sorted({n for n in names if names.count(n) > 1})]',
     "new": "    pass"},
    {"id": "restore-rule-reverted", "file": "engine.py",
     "old": "    out += restore_problems(row, order, at)\n",
     "new": ('    for j, e in enumerate(row["restore_expect"]):\n'
             '        root = _safe_root(e["path"])\n'
             '        if root in order and order[root] <= at:\n'
             '            out.append(f"restore_expect[{j}] reads {root!r}, which is not bound after the operation")\n')},
    {"id": "effect-ref-to-a-call-allowed", "file": "engine.py",
     "old": "        if baseline in order and (is_call(steps[baseline]) or order[baseline] >= at):",
     "new": "        if baseline in order and order[baseline] >= at:"},
    {"id": "effect-ref-after-operation-allowed", "file": "engine.py",
     "old": "        if baseline in order and (is_call(steps[baseline]) or order[baseline] >= at):",
     "new": "        if baseline in order and is_call(steps[baseline]):"},
    {"id": "witness-compared-with-itself-allowed", "file": "engine.py",
     "old": '            elif ref_obs_root(expect[i]) == cx["observation"]:',
     "new": "            elif False:"},
    {"id": "null-difference-passes", "file": "predicates.py",
     "old": 'NULL_IS_UNREADABLE = ("changed", "ne", "not_in")',
     "new": "NULL_IS_UNREADABLE = ()"},
    {"id": "null-rule-top-level-only", "file": "predicates.py",
     "old": "    if op in NULL_IS_UNREADABLE:\n",
     "new": ("    if op in NULL_IS_UNREADABLE:\n"
             '        return (f"a null cannot show a difference; {op} does not pass on absence"\n'
             "                if a is None or b is None else None)\n")},
    {"id": "unchanged-null-passes", "file": "predicates.py",
     "old": '    elif op == "unchanged" and same(a, b):',
     "new": "    elif False:"},
    {"id": "restore-call-without-a-check-allowed", "file": "engine.py",
     "old": '    if not row["restore_expect"]:',
     "new": "    if False:"},
    {"id": "restore-check-reads-any-reply-allowed", "file": "engine.py",
     "old": "            elif name in calls:",
     "new": "            elif False:"},
    {"id": "duplicate-keys-kept-silently", "file": "evidence_doc.py",
     "old": "        if key in out:",
     "new": "        if False:"},
    {"id": "nan-accepted", "file": "evidence_doc.py",
     "old": ", parse_constant=_refuse_constant,",
     "new": ","},
    {"id": "overflow-accepted", "file": "evidence_doc.py",
     "old": "parse_float=_finite_float)",
     "new": "parse_float=float)"},
    {"id": "large-finite-refused", "file": "evidence_doc.py",
     "old": "    if math.isinf(value):",
     "new": "    if math.isinf(value * 10):"},
    {"id": "nan-written", "file": "evidence_doc.py",
     "old": "sort_keys=False, allow_nan=False)",
     "new": "sort_keys=False)"},
    {"id": "closed-stdout-changes-the-exit", "file": "verify.py",
     "old": "    sys.stdout = _StdoutWithoutReader(sys.stdout)\n",
     "new": ""},
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
     "old": "elif is_call(steps[name]):",
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
    {"id": "attestation-check-scoped-to-verify", "file": "selftest.py",
     "old": '    files = sorted(f for f in proc.stdout.decode("utf-8").split("\\0") if f)',
     "new": ('    files = sorted(f for f in proc.stdout.decode("utf-8").split("\\0") '
             'if f.startswith(VERIFY_DIR))')},
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
    {"id": "record-refusal-names-no-producer", "file": "verify.py",
     "old": 'f"`verify.py run` (P0b-2), which records the evidence it produced when given --record. "',
     "new": 'f"a later command, which records the evidence it produced when given --record. "'},
    {"id": "evidence-not-content-addressed", "file": "verify.py",
     "old": 'name = E.content_name(data)',
     "new": 'name = "evidence.json"'},
    {"id": "count_eq-one-element-passes", "file": "predicates.py",
     "old": '"count_eq": (True, lambda a, b: _count(a, b) and len(a) == b),',
     "new": '"count_eq": (True, lambda a, b: _count(a, b) and len(a) >= 1),'},
    {"id": "operator-shipped-without-coverage", "file": "predicates.py",
     "old": '    "count_ge": (True, lambda a, b: _count(a, b) and len(a) >= b),',
     "new": ('    "count_ge": (True, lambda a, b: _count(a, b) and len(a) >= b),\n'
             '    "count_le": (True, lambda a, b: _count(a, b) and len(a) <= b),')},
    {"id": "store-default-on-unreadable", "file": "runner.py",
     "old": "        return E.unreadable_observation(step, str(exc) or type(exc).__name__)",
     "new": '        return E.make_observation(step, "{}")'},
    {"id": "lifecycle-ignored", "file": "runner.py",
     "old": '    if dirt:\n        return E.unreadable_observation(step, f"the machine was not clean before',
     "new": '    if False:\n        return E.unreadable_observation(step, f"the machine was not clean before'},
    {"id": "dirt-kind-only", "file": "runner.py",
     "old": '        return str(d.get("kind")) + (f" ({\', \'.join(said)})" if said else "")\n',
     "new": '        return str(d.get("kind"))\n'},
    {"id": "switch-failure-already-there", "file": "runner.py",
     "old": '    if switched.get("cause"):\n        return f"NOT switched: {switched[\'cause\']}"\n',
     "new": ""},
    {"id": "restore-skipped-after-failure", "file": "runner.py",
     "old": '        for step in row["restore"]:\n            entries[step["as"]] = execute_step(ctx, step)',
     "new": ('        for step in (row["restore"] if all("raw" in e for e in entries.values()) else []):\n'
             '            entries[step["as"]] = execute_step(ctx, step)')},
    {"id": "digest-before-verdicts", "file": "runner.py",
     "old": "    return data, parsed, _attest(built, readings, E.sha256_of(parsed), rest)",
     "new": "    return data, parsed, _attest(built, readings, E.sha256_of(dict(parsed, verdicts={})), rest)"},
    {"id": "reading-not-normalized", "file": "runner.py",
     "old": "    reading = normalize(life.reading(lproj))",
     "new": "    reading = life.reading(lproj)"},
    {"id": "wait-reads-once", "file": "runner.py",
     "old": "        if life.now() >= bound:\n            break",
     "new": "        if True:\n            break"},
    {"id": "wait-ignores-bound", "file": "runner.py",
     "old": "        if life.now() >= bound:\n            break",
     "new": "        if False:\n            break"},
    {"id": "gate-skipped", "file": "runner.py",
     "old": '        dirty = setups.gate_problems(ctx["decl"], reading, baseline)\n',
     "new": '        dirty = []\n'},
    {"id": "gate-ignores-upper-row", "file": "setups.py",
     "old": ('    if "mcu_upper_row_is_baseline" in decl["gate"]:\n'
             '        out += _upper_row_problems(decl, reading, baseline)\n'),
     "new": ('    if False:\n'
             '        out += _upper_row_problems(decl, reading, baseline)\n')},
    {"id": "gate-ignores-flags", "file": "setups.py",
     "old": ('            elif value != 0:\n'
             '                out.append(f"track {i} {word}")\n'),
     "new": ('            elif False:\n'
             '                out.append(f"track {i} {word}")\n')},
    {"id": "reset-record-inline", "file": "runner_live.py",
     "old": '        out = {"fixture": name, "lproj": ctx["lproj"], "record_sha256": self._kept(record)}\n',
     "new": '        out = {"fixture": name, "lproj": ctx["lproj"], "record_sha256": self._kept(record), "record": record}\n'},
    {"id": "rest-record-inline", "file": "runner_live.py",
     "old": '        return {"in_locale": live_locale.in_locale(after), "reading": after,\n',
     "new": '        return {"in_locale": live_locale.in_locale(after), "reading": after, "record": record,\n'},
    {"id": "live-reset-confirmed-unjudged", "file": "runner_live.py",
     "old": '        out["confirmed"] = not cause\n',
     "new": '        out["confirmed"] = True\n'},
    {"id": "live-reset-fingerprint-unread", "file": "runner_live.py",
     "old": "            if not fixture.fingerprint_matches(fixture.FIXTURES[name], fingerprint):\n",
     "new": "            if False:\n"},
    {"id": "settle-samples-inline", "file": "runner_live.py",
     "old": '"timed_out": record.get("timed_out"), "record_sha256": self._kept(record)}\n',
     "new": '"timed_out": record.get("timed_out"), "record_sha256": self._kept(record), "record": record}\n'},
    {"id": "switch-per-entry", "file": "runner.py",
     "old": ("            for lproj in order(wanted, life.current_locale()):\n"
             "                switched = life.switch(lproj)\n"),
     "new": ("            for lproj in order(wanted, life.current_locale()):\n"
             "                switched = [life.switch(lproj) for entry in entries\n"
             "                            if lproj in entry[\"locales\"]][-1]\n")},
    {"id": "record-without-attestation", "file": "runner.py",
     "old": "        recorded = verify.record_attested(data, att, record_dir)\n",
     "new": "        recorded = verify.record_attested(data, None, record_dir)\n"},
    {"id": "gate-reads-once-over-the-passing-message", "file": "runner.py",
     "old": "                                        setups.shows_passing_message)\n",
     "new": "                                        lambda reading: False)\n"},
    # The wait itself reverted, for the gate and the row probes at once (they share it).
    {"id": "passing-wait-reads-once", "file": "runner.py",
     "old": "    while shows(reading) and life.now() < bound:\n",
     "new": "    while False and shows(reading) and life.now() < bound:\n"},
    {"id": "passing-wait-unbounded", "file": "runner.py",
     "old": "    while shows(reading) and life.now() < bound:\n",
     "new": "    while shows(reading):\n"},
    # The row probes' wait reverted alone: a probe reads once over the passing message.
    {"id": "row-probe-reads-once-over-the-passing-message", "file": "runner.py",
     "old": "                                     lambda t: _probe_shows_passing(ctx, t))\n",
     "new": "                                     lambda t: False)\n"},
    {"id": "row-probe-ignores-the-baseline-message", "file": "runner.py",
     "old": '"passing_message": (ctx.get("baseline") or {}).get("passing_message")})\n',
     "new": '"passing_message": None})\n'},
    {"id": "baseline-read-once-over-the-passing-message", "file": "runner.py",
     "old": "            baselines[lproj] = _gate_reading(ctx)[0]\n",
     "new": "            baselines[lproj] = normalize(life.gate_reading(ctx))\n"},
    {"id": "passing-message-outlasting-the-wait-passes", "file": "setups.py",
     "old": ('        return [f"the MCU upper row still shows Logic\'s passing message "\n'
             '                f"{passing_message(reading)!r}: {row.get(\'value\')!r}"]\n'),
     "new": "        return []\n"},
    {"id": "baseline-showing-the-passing-message-unchecked", "file": "setups.py",
     "old": "    if shows_passing_message(baseline):\n",
     "new": "    if False and shows_passing_message(baseline):\n"},
    {"id": "passing-message-keeps-its-accents", "file": "setups.py",
     "old": '    return "".join(c for c in unicodedata.normalize("NFKD", text) if not unicodedata.combining(c))\n',
     "new": "    return text\n"},
    {"id": "reset-record-not-read", "file": "runner.py",
     "old": '    if isinstance(record, dict) and record.get("confirmed") is True:\n',
     "new": "    if True:\n"},
    {"id": "initial-reset-unchecked", "file": "runner.py",
     "old": "            cause = _fixture_reset(ctx)\n            if cause:\n",
     "new": "            cause = _fixture_reset(ctx)\n            if False:\n"},
    {"id": "retry-reset-unchecked", "file": "runner.py",
     "old": "    cause = _fixture_reset(ctx)\n    if cause:\n",
     "new": "    cause = _fixture_reset(ctx)\n    if False:\n"},
    {"id": "baseline-home-unchecked", "file": "setups.py",
     "old": "    return home_problems(baseline)\n",
     "new": "    return []\n"},
    {"id": "lcd-cell-matched-on-its-first-letter", "file": "setups.py",
     "old": "    return all(ch in rest for ch in c[1:])\n",
     "new": "    return True\n"},
    {"id": "rest-unconfirmed-passes", "file": "engine.py",
     "old": '    result["incomplete"] += rest_problems(doc)\n',
     "new": ""},
    {"id": "attestation-rest-unchecked", "file": "engine.py",
     "old": "    if not P.same(dict(attestation.rest), doc.get(E.REST)):\n",
     "new": "    if False:\n"},
    {"id": "rest-dropped-from-evidence", "file": "runner.py",
     "old": "    doc[E.REST] = rest\n",
     "new": ""},
    {"id": "record-written-past-the-canon-guard", "file": "verify.py",
     "old": "        refused = canon_record_guard.refusals(record)\n",
     "new": "        refused = []\n"},
    {"id": "record-keeps-only-the-steps-its-checks-read", "file": "verify.py",
     "old": ("        for name, entry in entries.items():\n"
             "            value = engine.observation_value(entry)\n"),
     "new": ("        for name, entry in entries.items():\n"
             "            if not any(e[\"path\"].split(\".\")[0] == name for e in row[\"expect\"]):\n"
             "                continue\n"
             "            value = engine.observation_value(entry)\n")},
    {"id": "record-drops-the-fields-no-check-reads", "file": "verify.py",
     "old": "            readings[name] = value.value if isinstance(value, P.Found) else",
     "new": ("            if isinstance(value, P.Found) and isinstance(value.value, dict):\n"
             "                value = P.Found({k: v for k, v in value.value.items()\n"
             "                                 if not k.startswith(\"fallback_from\")})\n"
             "            readings[name] = value.value if isinstance(value, P.Found) else")},
    {"id": "armed-false-when-unread", "file": "live/spec_probes.py",
     "old": '        raise Unreadable(f"track_armed: {why}")\n',
     "new": '        return {"track": index, "armed": False, "name": None}\n'},
    {"id": "armed-set-empty-when-unread", "file": "live/spec_probes.py",
     "old": '        raise Unreadable(f"armed_set: {why}")\n',
     "new": '        return {"armed": []}\n'},
    {"id": "index-off-by-one", "file": "live/spec_probes.py",
     "old": "else _armed(rows[index])",
     "new": "else _armed(rows[index - 1])"},
    {"id": "live-fixture-unchecked", "file": "runner_live.py",
     "old": '            return [f"fixture {decl[\'id\']!r} has no live declaration',
     "new": '            return [] and [f"fixture {decl[\'id\']!r} has no live declaration'},
    {"id": "server-env-dropped", "file": "runner.py",
     "old": '    life, env = ctx["life"], dict(ctx["decl"]["server_env"])\n',
     "new": '    life, env = ctx["life"], {}\n'},
    {"id": "unknown-fixture-admitted", "file": "engine.py",
     "old": '    out += [f"fixture: {p}" for p in setups.setup_problems(spec["fixture"])]\n',
     "new": ''},
    {"id": "attest-reads-document", "file": "runner.py",
     "old": "locale_readings=readings,",
     "new": "locale_readings=E.loads(json.dumps(readings)),"},
    {"id": "life-guard-off", "file": "selftest.py",
     # Split in two, so the anchor occurs once in selftest.py: here it is two strings.
     "old": ('    if rel != SELFTEST_FILE and isinstance(node, ast.keyword)'
             ' and node.arg == "_life":'),
     "new": "    if False:"},
    {"id": "runner-private-guard-off", "file": "selftest.py",
     "old": "    if rel != RUNNER_FILE and named in RUNNER_" + "PRIVATE:",
     "new": "    if False:"},
    {"id": "body-reserialized", "file": "runner_live.py",
     "old": '    return first["text"]',
     "new": '    return json.dumps(json.loads(first["text"]))'},
    {"id": "timeout-as-empty-object", "file": "runner_live.py",
     "old": """        raise runner.StepUnreadable(f"no reply within {call.get('elapsed_s') or 0:.1f} s")""",
     "new": '        return "{}"'},
    {"id": "structured-preferred", "file": "runner_live.py",
     "old": '    if structured is not None and not _same_json(first["text"], structured):',
     "new": ("    if structured is not None:\n"
             "        return json.dumps(structured, ensure_ascii=False, sort_keys=True)\n"
             "    if False:")},
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
            entry["raw"] = op["text"] if "text" in op else json.dumps(op["raw"], ensure_ascii=False, sort_keys=True)
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
    data = E.serialize(_patched_doc(case, where))
    if "edit_text" in case["patch"]:
        old, new = case["patch"]["edit_text"]
        text = data.decode("utf-8")
        if text.count(old) != 1:
            raise ValueError(f"{case['name']}: edit_text's old text occurs {text.count(old)} time(s), not once")
        data = text.replace(old, new).encode("utf-8")
    E.write_bytes_atomic(path, data)
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
        "rest": spec.get("rest", fixtures_build.RESTED),
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


class FakeSession(runner.Session):
    """A server that answers what the script says for the step the runner is on."""

    def __init__(self, life, ctx: dict, env: dict):
        self.life, self.ctx, self.env = life, ctx, env

    def call(self, tool, command, params, timeout_s):
        return self.life.answer(self.ctx, runner.StepUnreadable)

    def read(self, uri, timeout_s):
        return self.life.answer(self.ctx, runner.StepUnreadable)

    def close(self):
        return {"fake": True, "env": self.env}


#: The fake fixture's tracks: a gate reading of FakeLifecycle declares these and, unscripted, reads them.
FAKE_TRACKS = ("Self-test one", "Self-test two")
#: The passing message every fake gate reading carries (setups.py): made up, with an accent the LCD
#: drops, so a case's upper row shows it as "Self-test pass message".
FAKE_PASSING = "Self-test pass m\u00e9ssage"
#: The upper row a fake gate reading shows unscripted: the first bank of FAKE_TRACKS as the LCD
#: squeezes their names, so setups.home_problems finds the baseline home.
FAKE_HOME_ROW = "SlfOne SlfTwo"


class FakeLifecycle(runner.Lifecycle):
    """The world, scripted (see RUN CASES). Its clock moves only when the runner sleeps, in whole
    microseconds, so a wait's poll count is exact. Every request is kept in `events`."""

    def __init__(self, script: dict, where: dict, label: str, defaults: dict, replay: dict = None):
        self.script, self.where, self.label, self.defaults = script, where, label, defaults
        self.replay = replay or {}
        self.micros, self.events, self.reads, self.gates = 0, [], {}, {}
        self.locale = script.get("current", "ko")

    def count(self, kind: str) -> int:
        return sum(1 for e in self.events if e[0] == kind)

    def now(self):
        return self.micros / 1e6

    def sleep(self, seconds):
        self.micros += int(round(seconds * 1e6))

    def today(self):
        import fixtures_build
        return fixtures_build.DATE

    def build(self, head):
        import evidence_doc as E
        self.events.append(("build", head))
        path = os.path.join(self.where["tmp"], "bin", f"{self.label}.bin")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(f"self-test binary for {self.label}\n".encode("utf-8"))
        return runner.Built(head=head, sha256=E.sha256_of_file(path), path=path, record={"fake": True})

    @contextlib.contextmanager
    def claim(self, purpose):
        self.events.append(("claim", purpose))
        yield {"held": True}

    def current_locale(self):
        return self.locale

    def switch(self, lproj):
        self.events.append(("switch", lproj))
        cause = self.script.get("switch_refused", {}).get(lproj)
        if cause:
            return {"switched": False, "cause": cause}
        switched, self.locale = lproj != self.locale, lproj
        return {"switched": switched}

    def reading(self, lproj):
        import fixtures_build
        replayed = self.replay.get("readings", {})
        reading = copy.deepcopy(replayed[lproj]) if lproj in replayed else fixtures_build.locale_reading(lproj)
        reading.update(copy.deepcopy(self.script.get("readings", {}).get(lproj, {})))
        if self.script.get("tuple_in_reading"):
            reading["window_names"]["value"] = tuple(reading["window_names"]["value"])
        return reading

    def host(self, lproj):
        import fixtures_build
        replayed = self.replay.get("hosts", {})
        return copy.deepcopy(replayed[lproj]) if lproj in replayed else fixtures_build.host(lproj)

    def start(self, ctx, env):
        self.events.append(("start", env))
        return FakeSession(self, ctx, env)

    def ready(self, ctx):
        return {"ready": True}

    def fixture_problems(self, decl):
        return []

    def gate_reading(self, ctx):
        n = self.gates[ctx["lproj"]] = self.gates.get(ctx["lproj"], 0) + 1
        clear = [{"arm": 0, "mute": 0, "solo": 0} for _ in FAKE_TRACKS]
        reading = copy.deepcopy(self.replay["baseline"]) if self.replay else {
            "declared": {"track_count": len(FAKE_TRACKS), "names": list(FAKE_TRACKS)},
            "fingerprint": {"track_count": len(FAKE_TRACKS), "names": list(FAKE_TRACKS),
                            "flags": clear},
            "upper_row": {"readable": True, "value": FAKE_HOME_ROW},
            "passing_message": {"readable": True, "value": FAKE_PASSING}}
        scripted = []
        for item in self.script.get("gate", {}).get(ctx["lproj"], []):
            scripted += [item["ops"]] * item["times"] if isinstance(item, dict) else [item]
        if n <= len(scripted):
            _apply(reading, scripted[n - 1], self.label, self.where)
        return reading

    def reset(self, ctx):
        self.events.append(("reset", ctx["lproj"]))
        n = sum(1 for e in self.events if e == ("reset", ctx["lproj"]))
        scripted = self.script.get("reset", {}).get(ctx["lproj"], [])
        return scripted[n - 1] if n <= len(scripted) else {"fake": True, "confirmed": True}

    def settle(self, ctx):
        return {"fake": True}

    def problems(self, ctx, when):
        return list(self.script.get("dirt", {}).get(f"{when}:{ctx['row']}/{ctx['step']['as']}", []))

    def probe(self, name, ctx, args):
        import probes
        return self.answer(ctx, probes.ProbeUnreadable)

    def rest(self):
        self.events.append(("rest",))
        return self.script.get("rest", {"in_locale": True})

    def sidecar(self, data):
        import evidence_doc as E
        return E.sha256_of_bytes(data)

    def answer(self, ctx: dict, unreadable) -> str:
        key = f"{ctx['row']}/{ctx['step']['as']}"
        answers = self.script.get("answers", {})
        scripted = answers.get(f"{ctx['lproj']}/{key}", answers.get(key))
        n = self.reads[(ctx["lproj"], key)] = self.reads.get((ctx["lproj"], key), 0) + 1
        if n > self.script.get("poll_limit", 1000):
            raise RuntimeError(f"the fake stopped reading {key} after {n - 1} reads")
        if scripted is None:
            scripted = self.defaults[ctx["row"]][ctx["step"]["as"]]
        if isinstance(scripted, list):
            scripted = scripted[min(n, len(scripted)) - 1]
        if "unreadable" in scripted:
            raise unreadable(scripted["unreadable"])
        if scripted.get("timeout"):
            raise runner.StepUnreadable(f"no reply within {runner.CALL_TIMEOUT_S:g} s")
        if "text" in scripted:
            return scripted["text"]
        return json.dumps(scripted["value"], ensure_ascii=False, sort_keys=True)


def _run_fake(case: dict, where: dict):
    """(exit, output) of the runner driven over FakeLifecycle, as a run case asks."""
    import fixtures_build
    run = case["run"]
    if "replay" in run:
        try:
            entries, defaults, replay = _replayed(run, where, case["name"])
        except (OSError, ValueError, KeyError) as exc:  # a replay that cannot load fails its case
            return f"crash {type(exc).__name__}: {exc}", ""
    else:
        items = run.get("entries") or [{"spec": run["spec"], "spec_ops": run.get("spec_ops", []),
                                        "locales": run.get("locales")}]
        entries = []
        for item in items:
            path = _fill(item["spec"], where)
            with open(path, encoding="utf-8") as handle:
                spec = json.load(handle)
            _apply(spec, item.get("spec_ops", []), case["name"], where)
            entries.append({"spec": spec, "spec_path": os.path.relpath(path, ROOT),
                            "head": item.get("head", SELFTEST_HEAD), "locales": item.get("locales")})
        readings = fixtures_build.READINGS[os.path.basename(_fill(items[0]["spec"], where))]
        defaults = {row: {name: {"value": value} for name, value in steps.items()}
                    for row, steps in readings.items()}
        replay = None
    life = FakeLifecycle(run.get("script", {}), where, case["name"], defaults, replay)
    out = os.path.join(where["tmp"], f"{case['name']}.evidence.json")
    records = os.path.join(where["tmp"], f"{case['name']}.records") if run.get("record") else None
    printed = io.StringIO()
    with contextlib.redirect_stdout(printed):
        try:
            if "entries" in run:
                code = runner.run_batch(entries, os.path.join(where["tmp"], f"{case['name']}.batch"),
                                        records, _life=life)
            else:
                one = entries[0]
                code = runner.run_spec(one["spec"], one["spec_path"], one["head"], one["locales"],
                                       out, records, _life=life)
        except Exception as exc:  # a crash is a failed case, reported with its type
            code = f"crash {type(exc).__name__}: {exc}"
    text = printed.getvalue()
    for kind, wanted in run.get("events", {}).items():
        if life.count(kind) != wanted:
            return f"the lifecycle was asked to {kind} {life.count(kind)} time(s), not {wanted}", text
    if "start_env" in run:
        envs = [e[1] for e in life.events if e[0] == "start"]
        short = [env for env in envs if any(env.get(k) != v for k, v in run["start_env"].items())]
        if not envs or short:
            return f"the servers were started with {envs}, each wanted to carry {run['start_env']}", text
    if "records_written" in run:
        kept = sorted(n for n in os.listdir(records) if n.endswith(".json")) if os.path.isdir(records) else []
        if len(kept) != run["records_written"]:
            return f"{len(kept)} record(s) written ({kept}), wanted {run['records_written']}", text
    for row_id, wanted in run.get("record_readings", {}).items():
        kept = []
        for name in sorted(os.listdir(records)) if records and os.path.isdir(records) else []:
            if not name.endswith(".json"):
                continue
            with open(os.path.join(records, name), encoding="utf-8") as handle:
                kept += [sorted(o["readings"]) for o in json.load(handle)["observations"]
                         if o["row"] == row_id]
        if not kept or any(keys != sorted(wanted) for keys in kept):
            return f"the records keep readings {kept} for {row_id}, each wanted {sorted(wanted)}", text
    if "recheck" in case and code == case["exit"]:
        again, said = _verify(["recheck", out])
        if again != case["recheck"]["exit"] or case["recheck"]["says"] not in said:
            return f"recheck of the run's evidence: exit {again}; {said.strip().splitlines()[-1:]}", text
    return code, text


def _replayed(run: dict, where: dict, label: str):
    """([entry], answers, replay) for a `replay` run case (see RUN CASES): replay holds the
    locale's logged baseline, its locale reading and its host block, as the evidence stored them."""
    import evidence_doc as E
    replay = run["replay"]
    doc = E.load(_fill(replay["evidence"], where))
    lproj = replay["lproj"]
    spec = copy.deepcopy(doc["spec"])
    if "spec" in replay:
        with open(_fill(replay["spec"], where), encoding="utf-8") as fh:
            spec = json.load(fh)
    renamed = replay.get("rows", {})
    _apply(spec, run.get("spec_ops", []), label, where)
    answers = {}
    for row_id, stored in doc["runs"][lproj]["rows"].items():
        answers[renamed.get(row_id, row_id)] = {name: ({"text": entry["raw"]} if "raw" in entry
                                  else {"unreadable": entry.get("unreadable") or "unreadable in the evidence"})
                           for name, entry in stored["observations"].items()}
    base = [e["baseline"] for e in doc["runs"][lproj]["lifecycle"] if e.get("event") == "baseline"]
    if len(base) != 1:
        raise ValueError(f"{replay['evidence']}: {len(base)} baselines logged in {lproj}, not one")
    entry = {"spec": spec, "spec_path": doc["spec_path"], "head": SELFTEST_HEAD, "locales": [lproj]}
    stored = doc["runs"][lproj]
    return [entry], answers, {"baseline": base[0], "readings": {lproj: stored[E.LOCALE_READING]},
                              "hosts": {lproj: stored["host"]}}


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
    import canon_record_guard
    for name in records:
        with open(os.path.join(out, name), encoding="utf-8") as handle:
            refused = canon_record_guard.refusals(json.load(handle))
        if refused:
            return f"check-canon-citations refuses {name}: {refused[0]}"
    return None


#: The checked-in #1020 pilot evidence (P0a). Its arm-unarmed-sets reply names the rung it fell back
#: from, a string Logic ships, in a field no check of the row reads.
PILOT_EVIDENCE = "docs/acceptance/evidence/1020-ko-4b036d93.json"


def check_pilot_full_record_is_declined(case: dict, where: dict):
    """#1052 REG-02: a record built from the pilot evidence keeps every reading whole, the reply's
    fallback rung included, and check-canon-citations refuses it, so `record_attested` would
    decline it rather than write a trimmed one. The pilot stores no host block or date
    (convert_1020.py says why); the fixtures' ko host and date stand in, since neither is a
    reading. The control: the stored reply does carry that field."""
    import canon_record_guard
    import engine
    import fixtures_build
    import verify
    with open(os.path.join(ROOT, PILOT_EVIDENCE), encoding="utf-8") as handle:
        doc = json.load(handle)
    reply = doc["runs"]["ko"]["rows"]["arm-unarmed-sets"]["observations"]["reply"]
    if "fallback_from_channel" not in json.dumps(reply, ensure_ascii=False):
        return "control: the pilot's arm-unarmed-sets reply no longer names a fallback rung"
    doc["runs"]["ko"]["host"], doc["runs"]["ko"]["date"] = fixtures_build.host("ko"), fixtures_build.DATE
    record = verify.build_record(doc, "ko", engine.judge(doc)["verdicts"]["ko"], "evidence/pilot.json")
    kept = next(o for o in record["observations"] if o["row"] == "arm-unarmed-sets")["readings"]
    if kept.get("reply", {}).get("fallback_from_channel") != "Accessibility":
        return f"the pilot's record does not keep the reply whole: its reply reading is {kept.get('reply')!r}"
    refused = canon_record_guard.refusals(record)
    if not refused:
        return "check-canon-citations accepts the pilot's full record, so this case no longer shows a decline"
    return None if "Accessibility" in refused[0] else f"refused, but not for the fallback rung: {refused[0]}"


#: Where an `engine.Attestation` may be named, as (repo-relative file, top-level definition): the
#: class itself, the engine's type check, the self-test's in-process `attest`, and the one
#: constructor ADR-027 D7 allows, `verify.py run`'s: runner.py `_attest`.
ATTESTATION_SITES = {("Scripts/verify/engine.py", "Attestation"),
                     ("Scripts/verify/engine.py", "attestation_problems"),
                     ("Scripts/verify/selftest.py", "attest"),
                     ("Scripts/verify/runner.py", "_attest")}
SELFTEST_FILE = "Scripts/verify/selftest.py"
#: The runner. Its names that reach an Attestation (`_attest`, `_produce`) or drive a lifecycle
#: given positionally and record what it produced (`_drive`, `_finish`) are referenced only inside
#: it; `_attest`'s body is held to what the self-test's `attest` is held to.
RUNNER_FILE = "Scripts/verify/runner.py"
RUNNER_PRIVATE = ("_attest", "_produce", "_drive", "_finish")
#: The verifier's own code. The rules that catch an Attestation built without naming it (unpickling,
#: importlib, `__import__`, `__new__`, a dataclass copy) apply here only: elsewhere in the repository
#: the same calls are ordinary code (guards load their helpers with importlib). Hiding a construction
#: behind them outside the verifier is editing code on purpose, the insider class ADR-027 D7 leaves
#: to review and CI (#816). Naming it -- a call, an import, an attribute, a lookup by its name --
#: is refused in every tracked file.
VERIFY_DIR = "Scripts/verify/"
#: Modules that rebuild objects without a visible constructor call.
UNPICKLERS = {"pickle", "marshal", "shelve", "copyreg", "dill", "cloudpickle", "importlib"}
#: What `attest` may not do: read a file or parse JSON, or read the document's own binding claims.
FILE_READS = {"open", "load", "loads", "read", "read_text", "read_bytes", "sha256_of_file"}
CLAIM_KEYS = {"binary", "binary_path", "binary_sha256", "head", "binding", "locale_reading", "rest"}
CLAIM_ATTRS = {"BINARY_PATH", "BINARY_SHA256", "HEAD", "BINDING", "LOCALE_READING", "REST"}


def _top_level_sites(tree):
    """(top-level definition name or None, node) for every node of a module."""
    for top in tree.body:
        name = top.name if isinstance(top, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) else None
        for node in ast.walk(top):
            yield name, node


def tracked_python(repo: str) -> tuple:
    """(every tracked .py file of `repo`, repo-relative; None) or ([], why the listing failed).
    A listing that fails is a problem, never an empty list: a check that read nothing must not
    report that it found nothing."""
    proc = subprocess.run(["git", "-C", repo, "ls-files", "-z", "--", "*.py"], capture_output=True)
    if proc.returncode != 0:
        return [], (f"git ls-files in {repo}: exit {proc.returncode}; "
                    f"{proc.stderr.decode('utf-8', 'replace').strip()}")
    files = sorted(f for f in proc.stdout.decode("utf-8").split("\0") if f)
    if not files:
        return [], f"git ls-files in {repo} listed no .py file"
    return files, None


def _naming_problems(here: str, node, allowed: bool, target: str) -> list:
    """A construction that names the class: refused in every tracked file."""
    if allowed:
        return []
    if isinstance(node, ast.Name) and node.id == target:
        return [f"{here} names {target} outside the in-process sites"]
    if isinstance(node, ast.Attribute) and node.attr == target:
        return [f"{here} reaches {target} as an attribute outside the in-process sites"]
    if isinstance(node, ast.ImportFrom) and any(a.name == target for a in node.names):
        return [f"{here} imports {node.module or ''}.{target}"]
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) \
            and node.func.id in ("getattr", "setattr", "hasattr", "delattr") \
            and any(isinstance(a, ast.Constant) and a.value == target for a in node.args):
        return [f"{here} looks {target} up by name with {node.func.id}"]
    if isinstance(node, ast.Subscript) and isinstance(node.slice, ast.Constant) \
            and node.slice.value == target:
        return [f"{here} looks {target} up by name with a subscript"]
    return []


def _indirect_problems(here: str, node, rel: str, site, target: str) -> list:
    """A construction that does not name the class: refused in the verifier's own code."""
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        module = getattr(node, "module", None) or ""
        return [f"{here} imports {module + '.' if module else ''}{alias.name}" for alias in node.names
                if alias.name == "*" or alias.name.split(".")[0] in UNPICKLERS
                or module.split(".")[0] in UNPICKLERS]
    if not isinstance(node, ast.Call):
        return []
    func = node.func
    if isinstance(func, ast.Name) and func.id == "__import__":
        return [f"{here} looks {target} up by name with __import__"]
    if isinstance(func, ast.Attribute) and func.attr == "replace" \
            and isinstance(func.value, ast.Name) and func.value.id in ("dataclasses", "copy"):
        return [f"{here} copies a dataclass with new fields ({func.value.id}.replace)"]
    if isinstance(func, ast.Attribute) and func.attr in ("__setattr__", "__new__") \
            and (rel, site) != ("Scripts/verify/engine.py", target):
        return [f"{here} calls {func.attr}, which can set a frozen field or skip __init__"]
    return []


def _attest_body_problems(here: str, node) -> list:
    """What the self-test's `attest` may not do: read a file, or copy the document's claims."""
    if isinstance(node, ast.Call):
        called = node.func.attr if isinstance(node.func, ast.Attribute) else \
            node.func.id if isinstance(node.func, ast.Name) else None
        if called in FILE_READS:
            return [f"{here}: attest calls {called}; the attestation is built in "
                    f"process from what the runner measured, not from a file"]
    if isinstance(node, ast.Subscript) and isinstance(node.slice, ast.Constant) \
            and node.slice.value in CLAIM_KEYS:
        return [f"{here}: attest reads the document's {node.slice.value!r}; an "
                f"attestation that copies the document's claims attests nothing"]
    if isinstance(node, ast.Attribute) and node.attr in CLAIM_ATTRS:
        return [f"{here}: attest reads the document's {node.attr}; an attestation "
                f"that copies the document's claims attests nothing"]
    return []


def _seam_problems(here: str, node, rel: str) -> list:
    """The runner's seams, refused outside their files in every tracked file: a reference to a
    name of RUNNER_PRIVATE outside runner.py, and a `_life=` keyword -- a lifecycle other than
    the live one -- outside the self-test. A fake lifecycle reaches clean only where the self-test
    runs it."""
    out = []
    named = None
    if isinstance(node, ast.Attribute):
        named = node.attr
    elif isinstance(node, ast.Name):
        named = node.id
    elif isinstance(node, ast.ImportFrom):
        named = next((a.name for a in node.names if a.name in RUNNER_PRIVATE), None)
    if rel != RUNNER_FILE and named in RUNNER_PRIVATE:
        out.append(f"{here} reaches the runner's {named} outside runner.py")
    if rel != SELFTEST_FILE and isinstance(node, ast.keyword) and node.arg == "_life":
        out.append(f"{here} passes _life= outside the self-test: a lifecycle other than the live "
                   f"one reaches clean only there")
    return out


def attestation_construction_problems(root: str = ROOT, repo: str = None) -> list:
    """Why something other than the in-process sites could build, alias or forge an Attestation.

    Parses every tracked .py file of the repository: the list from `git ls-files` in `repo`
    (default engine.repo_root(), which a mutant's tree points at the real checkout), the bytes from
    `root`, the tree under test. A file it cannot read or parse is a problem, not a skip."""
    import engine
    target = "Attest" + "ation"  # spelt apart so this checker does not name it as a string itself
    files, why = tracked_python(repo or engine.repo_root())
    if why:
        return [why]
    out = []
    for rel in files:
        try:
            with open(os.path.join(root, rel), encoding="utf-8") as handle:
                tree = ast.parse(handle.read(), rel)
        except (OSError, UnicodeDecodeError, SyntaxError, ValueError) as exc:
            out.append(f"{rel}: not read ({type(exc).__name__}: {exc}); a file this check could not "
                       f"read is not a file without a construction")
            continue
        inside = rel.startswith(VERIFY_DIR)
        for site, node in _top_level_sites(tree):
            here = f"{rel}:{getattr(node, 'lineno', '?')}"
            out += _naming_problems(here, node, (rel, site) in ATTESTATION_SITES, target)
            if inside:
                out += _indirect_problems(here, node, rel, site, target)
            if (rel, site) in ((SELFTEST_FILE, "attest"), (RUNNER_FILE, "_attest")):
                out += _attest_body_problems(here, node)
            out += _seam_problems(here, node, rel)
            if rel != SELFTEST_FILE and ((isinstance(node, ast.Attribute) and node.attr == "attest")
                                         or (isinstance(node, ast.Name) and node.id == "attest")):
                out.append(f"{here} calls the self-test's attest outside the self-test")
    return out


def check_attestation_built_only_in_process(case: dict, where: dict):
    """RV-02: nothing builds an Attestation but the in-process sites. Parses every tracked .py file
    of the repository; see attestation_construction_problems for what each file is held to."""
    problems = attestation_construction_problems()
    return "; ".join(problems) if problems else None


def check_attestation_check_sees_the_whole_repository(case: dict, where: dict):
    """RV-02, round 3: the check is red on a construction planted outside Scripts/verify. A scratch
    repository tracks three files that build an Attestation three ways and one that uses the engine
    honestly, importlib included; each forger must be named and the honest file must not be."""
    target = "Attest" + "ation"
    planted = {
        "Scripts/elsewhere/forge_call.py": f"import engine\nmade = engine.{target}(binary_sha256='0' * 64)\n",
        "Scripts/elsewhere/forge_import.py": f"from engine import {target} as Made\nmade = Made()\n",
        "Scripts/elsewhere/forge_getattr.py": f"import engine\nmade = getattr(engine, '{target}')()\n",
        "Scripts/elsewhere/honest.py": "import importlib.util\nimport engine\n"
                                       "result = engine.judge({}, attestation=None)\n",
    }
    repo = os.path.join(where["tmp"], "planted-repo")
    for rel, text in planted.items():
        os.makedirs(os.path.dirname(os.path.join(repo, rel)), exist_ok=True)
        with open(os.path.join(repo, rel), "w", encoding="utf-8") as handle:
            handle.write(text)
    for argv in (["init", "-q"], ["add", "--", "Scripts"]):
        proc = subprocess.run(["git", "-C", repo] + argv, capture_output=True, text=True)
        if proc.returncode != 0:
            return f"git {argv[0]} in the scratch repository: exit {proc.returncode}; {proc.stderr.strip()}"
    problems = attestation_construction_problems(root=repo, repo=repo)
    missed = [rel for rel in planted if "forge" in rel and not any(p.startswith(rel + ":") for p in problems)]
    honest = [p for p in problems if p.startswith("Scripts/elsewhere/honest.py")]
    if missed or honest:
        return f"forgers not named: {missed}; honest file named: {honest}; problems: {problems}"
    return None


#: A head no repository has: a CLI run over it is refused at the build at the latest, so no case
#: here can start a real build even when a mutant breaks the refusal before it.
ABSENT_HEAD = "0123456789abcdef0123456789abcdef01234567"
RUN_OPTIONS = {"-h", "--help", "--head", "--locales", "--out", "--record"}
BATCH_OPTIONS = {"-h", "--help", "--queue", "--out-dir", "--record"}
SEAM_VARIABLES = {"LPM_VERIFY_REPO", "LPM_VERIFY_ISSUE_BODIES"}


def check_live_records_go_to_sidecars(case: dict, where: dict):
    """The live lifecycle keeps a reset's record (its whole fixture walk), a settle's samples and
    a rest's record (its quit and relaunch) in sidecars (D5): what it returns names the sidecar by
    sha256 and holds none of the record, and the sidecar holds all of it. fixture.reset,
    screen.settle_to_clean and locale.restore_locale are stood in for, in process, by records
    carrying a marker the evidence must never contain."""
    import fixtures_build
    import runner_live
    marker = "a-row-of-the-walk-" * 40
    records = {"reset": {"read": {"track_flags": {"tracks": [marker]}}, "quit": {"steps": []}},
               "settle": {"initial": {"observation": marker, "dirt": []}, "actions": [],
                          "final": {"observation": marker, "dirt": []}, "timed_out": False,
                          "escapes_sent": 0},
               "rest": {"quit": {"steps": [marker]}, "after": fixtures_build.locale_reading("ko")}}
    sidecars = os.path.join(where["tmp"], "live-sidecars")
    lifecycle = runner_live.LiveLifecycle(repo=ROOT, sidecars=sidecars)
    ctx = {"decl": {"live": "locale_campaign_19"}, "lproj": "ko"}
    saved = (runner_live.fixture.reset, runner_live.screen.settle_to_clean,
             runner_live.live_locale.restore_locale)
    runner_live.fixture.reset = lambda name, lproj: records["reset"]
    runner_live.screen.settle_to_clean = lambda **kw: records["settle"]
    runner_live.live_locale.restore_locale = lambda: records["rest"]
    try:
        got = {"reset": lifecycle.reset(ctx), "settle": lifecycle.settle(ctx), "rest": lifecycle.rest()}
    finally:
        (runner_live.fixture.reset, runner_live.screen.settle_to_clean,
         runner_live.live_locale.restore_locale) = saved
    for kind, kept in got.items():
        if marker in json.dumps(kept, default=repr):
            return f"{kind}: the evidence would hold the record itself"
        path = os.path.join(sidecars, f"{kept.get('record_sha256')}.json")
        if not os.path.isfile(path):
            return f"{kind}: no sidecar named {kept.get('record_sha256')!r}"
        with open(path, encoding="utf-8") as handle:
            if json.load(handle) != records[kind]:
                return f"{kind}: the sidecar does not hold the whole record"
    if got["settle"].get("dirt") != {"initial": [], "final": []} or got["settle"].get("timed_out") is not False:
        return f"settle keeps {got['settle']}, not its dirt and timed_out"
    if got["rest"].get("in_locale") is not True or got["rest"].get("reading") != records["rest"]["after"]:
        return f"rest keeps {got['rest']}, not in_locale true and the reading after it"
    return None


def check_live_reset_is_judged(case: dict, where: dict):
    """#1052 VFY-01: the live lifecycle's reset says "confirmed" only when fixture.reset's record
    has no cause (Logic quit, the build ran) and the fingerprint read after it is the fixture's
    declaration (fixture.fingerprint_matches). fixture.reset is stood in for, in process, by the
    record shapes it returns: the quit refusal kept live in de, and a reopened file that reads as
    declared, with one track armed, and short a track."""
    import runner_live
    decl = runner_live.fixture.FIXTURES["locale_campaign_19"]
    clean = {"track_count": decl["track_count"], "names": list(decl["names"]),
             "flags": [{"arm": 0, "mute": 0, "solo": 0} for _ in decl["names"]]}
    armed = copy.deepcopy(clean)
    armed["flags"][2]["arm"] = 1
    short = dict(clean, track_count=decl["track_count"] - 1, names=list(decl["names"][:-1]))
    wanted = [({"quit": {"quit": False}, "cause": "Logic did not quit"}, False, "Logic did not quit"),
              ({"quit": {"quit": True}, "build": {"cause": "the fixture file is missing"}},
               False, "the fixture file is missing"),
              ({"quit": {"quit": True}, "build": {}, "read": {"fingerprint": clean}}, True, None),
              ({"quit": {"quit": True}, "build": {}, "read": {"fingerprint": armed}},
               False, "is not its declaration"),
              ({"quit": {"quit": True}, "build": {}, "read": {"fingerprint": short}},
               False, "is not its declaration")]
    lifecycle = runner_live.LiveLifecycle(repo=ROOT, sidecars=os.path.join(where["tmp"], "reset-sidecars"))
    ctx = {"decl": {"live": "locale_campaign_19"}, "lproj": "de"}
    saved = runner_live.fixture.reset
    try:
        for n, (record, confirmed, says) in enumerate(wanted):
            runner_live.fixture.reset = lambda name, lproj, record=record: record
            got = lifecycle.reset(ctx)
            if got.get("confirmed") is not confirmed:
                return f"reset {n}: confirmed is {got.get('confirmed')!r}, wanted {confirmed}: {got}"
            if says is not None and says not in str(got.get("cause")):
                return f"reset {n}: its cause {got.get('cause')!r} does not say {says!r}"
    finally:
        runner_live.fixture.reset = saved
    return None


def check_run_cli_has_no_life_seam(case: dict, where: dict):
    """`verify.py run` and `batch` reach the live lifecycle and nothing else. Their options are
    exactly the documented ones, so no flag can select another world; verify.py, runner.py and engine.py name
    no environment variable but the two SEAMS verify.py documents, neither of which picks a
    lifecycle; and the command line over the self-test's own spec is refused by
    runner_live.LiveLifecycle, which alone says a self-test fixture is the self-test's to drive."""
    import engine
    import verify
    commands = verify.parser()._subparsers._group_actions[0].choices
    for name, wanted, args in (("run", RUN_OPTIONS, ["spec"]), ("batch", BATCH_OPTIONS, [])):
        options = {s for action in commands[name]._actions for s in action.option_strings}
        positionals = [action.dest for action in commands[name]._actions if not action.option_strings]
        if options != wanted or positionals != args:
            return f"{name} takes {sorted(options)} and {positionals}, not {sorted(wanted)} and {args}"
    named = set()
    for name in ("verify.py", "runner.py", "engine.py"):
        with open(os.path.join(HERE, name), encoding="utf-8") as handle:
            named |= set(re.findall(r"[\"']((?:LPM|LOGIC_PRO_MCP)_[A-Z0-9_]+)[\"']", handle.read()))
    if named - SEAM_VARIABLES:
        return f"the command line's modules name environment variables {sorted(named - SEAM_VARIABLES)}"
    code, text = _verify(["run", os.path.join(FIXTURES, "spec-base.json"), "--head", ABSENT_HEAD,
                          "--out", os.path.join(where["tmp"], "cli-run.json")])
    if code != engine.EXIT_REFUSED or "only the self-test drives it" not in text:
        return f"verify.py run over the self-test spec: exit {code}; {text.strip().splitlines()[-2:]}"
    return None


def check_life_seam_named_outside_selftest(case: dict, where: dict):
    """The runner's seams are refused outside their files: a scratch repository tracks a file that
    passes `_life=` to the runner, one that calls `_attest`, one that imports `_drive` to hand it a
    lifecycle positionally, and one that runs the runner honestly. Every seam user must be named
    and the honest file must not be."""
    planted = {
        "Scripts/elsewhere/fake_world.py": "import runner\n"
                                           "code = runner.run_spec({}, 's', 'h', None, 'o', _life=object())\n",
        "Scripts/elsewhere/own_attest.py": "import runner\nmade = runner._attest(None, {}, '0' * 64)\n",
        "Scripts/elsewhere/own_drive.py": "from runner import _drive\ncode = _drive(object(), [], 'docs/observations')\n",
        "Scripts/elsewhere/honest.py": "import runner\ncode = runner.run_spec({}, 's', 'h', None, 'o')\n",
    }
    repo = os.path.join(where["tmp"], "planted-seams")
    for rel, text in planted.items():
        os.makedirs(os.path.dirname(os.path.join(repo, rel)), exist_ok=True)
        with open(os.path.join(repo, rel), "w", encoding="utf-8") as handle:
            handle.write(text)
    for argv in (["init", "-q"], ["add", "--", "Scripts"]):
        proc = subprocess.run(["git", "-C", repo] + argv, capture_output=True, text=True)
        if proc.returncode != 0:
            return f"git {argv[0]} in the scratch repository: exit {proc.returncode}; {proc.stderr.strip()}"
    problems = attestation_construction_problems(root=repo, repo=repo)
    missed = [rel for rel in planted if "honest" not in rel and not any(p.startswith(rel + ":") for p in problems)]
    honest = [p for p in problems if p.startswith("Scripts/elsewhere/honest.py")]
    if missed or honest:
        return f"seam users not named: {missed}; honest file named: {honest}; problems: {problems}"
    return None


def check_reply(case: dict, where: dict):
    """D2: a `call` step stores its reply's content[0].text exactly, and a `read` step its
    contents[0].text; anything else is unreadable with why. One step, over the fake stdio server,
    through runner.execute_step, so the check covers the storing as well as the reading."""
    import runner_live
    from live import mcp
    reply = case["reply"]
    script = os.path.join(where["tmp"], f"{case['name']}.script.json")
    with open(script, "w", encoding="utf-8") as handle:
        json.dump(reply.get("script", {}), handle, ensure_ascii=False)
    if "uri" in reply:
        step = {"as": "reply", "read": {"uri": reply["uri"]}}
    else:
        step = {"as": "reply", "call": {"tool": "fake", "command": reply["command"],
                                        "params": reply.get("params", {})}}
    session = runner_live.McpSession(mcp.Server(FAKE_SERVER, env={FAKE_SCRIPT_ENV: script},
                                                stderr_dir=where["tmp"],
                                                argv=[sys.executable, FAKE_SERVER]), init_timeout_s=30.0)
    ctx = {"life": FakeLifecycle({}, where, case["name"], {}), "lproj": "ko", "decl": {}, "built": None,
           "session": session, "row": "reply", "step": None, "log": []}
    saved = runner.CALL_TIMEOUT_S, runner.READ_TIMEOUT_S
    runner.CALL_TIMEOUT_S = runner.READ_TIMEOUT_S = float(reply.get("timeout_s", 10.0))
    try:
        entry = runner.execute_step(ctx, step)
    finally:
        runner.CALL_TIMEOUT_S, runner.READ_TIMEOUT_S = saved
        session.close()
    got = f"stored {entry.get('raw')!r}; unreadable {entry.get('unreadable')!r}"
    if "stores" in case:
        exact = entry.get("raw") == case["stores"] and \
            entry.get("raw_bytes") == len(case["stores"].encode("utf-8"))
        return None if exact else f"{got}; wanted exactly {case['stores']!r}"
    if "raw" in entry or case["unreadable"] not in (entry.get("unreadable") or ""):
        return f"{got}; wanted unreadable saying {case['unreadable']!r}"
    return None


def check_closed_stdout_keeps_the_exit(case: dict, where: dict):
    """N5 (round 4): the exit code is the verdict, so a reader that closes the pipe early must not
    change it. Each command runs twice as a subprocess of this tree's verify.py: once with stdout
    read, once with stdout a pipe whose read end is already closed. The exits must match, and the
    first must be the one wanted, so the check aims at a real verdict. `recheck` of ev-base prints
    little (Python's final flush fails: exit 120 without the fix); `check-spec` of a spec with 2000
    refused rows prints far more than a pipe holds (a write fails mid-run: a traceback)."""
    import evidence_doc as E
    with open(os.path.join(FIXTURES, "spec-base.json"), encoding="utf-8") as handle:
        spec = json.load(handle)
    row = dict(spec["rows"][0], operation="no-such-step")
    spec["rows"] = [dict(row, id=f"row-{n}") for n in range(2000)]
    big = os.path.join(where["tmp"], "closed-stdout-many-refusals.json")
    E.write_atomic(big, spec)
    env = dict(os.environ, LPM_VERIFY_ISSUE_BODIES=os.path.join(FIXTURES, "issues"),
               PYTHONDONTWRITEBYTECODE="1")
    for argv, wanted in ((["recheck", os.path.join(FIXTURES, "ev-base.json")], 3),
                         (["check-spec", big], 2)):
        cmd = [sys.executable, os.path.join(HERE, "verify.py")] + argv
        read = subprocess.run(cmd, env=env, capture_output=True, timeout=120)
        if read.returncode != wanted:
            return f"{argv[0]} with stdout read: exit {read.returncode}, wanted {wanted}"
        if argv[0] == "check-spec" and len(read.stdout) < 1 << 17:
            return f"check-spec printed {len(read.stdout)} bytes, too few to fill a pipe mid-run"
        r, w = os.pipe()
        os.close(r)
        try:
            closed = subprocess.run(cmd, env=env, stdout=w, stderr=subprocess.PIPE, timeout=120)
        finally:
            os.close(w)
        if closed.returncode != wanted:
            tail = closed.stderr.decode("utf-8", "replace").strip().splitlines()[-1:]
            return f"{argv[0]} with stdout closed by the reader: exit {closed.returncode}, not the verdict's {wanted}; {tail}"
    return None


def check_nan_not_written(case: dict, where: dict):
    """W02: the writer refuses a float that is not JSON rather than writing text the reader then
    refuses. NaN, Infinity and -Infinity must each raise ValueError from `serialize`."""
    import evidence_doc as E
    for value in (float("nan"), float("inf"), float("-inf")):
        try:
            E.serialize({"reading": value})
        except ValueError:
            continue
        return f"serialize wrote {value!r}, which is not JSON and which loads refuses"
    return None


def _sample(name: str) -> dict:
    with open(os.path.join(HERE, "live", "tests", "samples", name), encoding="utf-8") as handle:
        return json.load(handle)


def check_gate(case: dict, where: dict):
    """The fixture gate over recorded readings (see GATE CASES)."""
    import runner_live
    import setups
    from live import fixture
    gate = case["gate"]
    decl = setups.declaration("lpm-locale-campaign-19")
    rows = _sample("mcu-upper-rows-ko.json")

    def reading(walk: str, row: str) -> dict:
        return runner_live.gate_reading_of(fixture.FIXTURES[decl["live"]], _sample(walk)["probe_output"],
                                           {"readable": True, "value": rows[row]})

    got = setups.gate_problems(decl, reading(gate["walk"], gate["row"]), reading(*gate["baseline"]))
    wanted = case["problems"]
    if len(got) != len(wanted) or any(w not in g for w, g in zip(wanted, got)):
        return f"the gate named {got}; wanted {len(wanted)} problem(s) saying {wanted}"
    return None


class _ResourceSession:
    """A server whose only resource is one text, for the mcu_upper_row probe cases."""

    def __init__(self, text: str):
        self.text = text

    def read(self, uri, timeout_s):
        if uri != "logic://mcu/state":
            raise runner.StepUnreadable(f"no resource {uri}")
        return self.text


def check_probe(case: dict, where: dict):
    """A declared probe over a recorded walk or a resource text (see PROBE CASES)."""
    import evidence_doc as E
    import probes
    import setups
    from live import spec_probes
    probe = case["probe"]
    walk, asked, kept = None, [], []
    if "walk" in probe:
        sample = _sample(probe["walk"])
        _apply(sample, probe.get("walk_ops", []), case["name"], where)
        walk = sample["probe_output"]
    life = FakeLifecycle({}, where, case["name"], {})
    life.sidecar = lambda data: kept.append(data) or E.sha256_of_bytes(data)
    ctx = {"life": life, "lproj": "ko", "decl": setups.declaration("lpm-locale-campaign-19"),
           "session": _ResourceSession(probe["resource_text"]) if "resource_text" in probe else None}
    saved = spec_probes.live_probes.run
    spec_probes.live_probes.run = lambda name, args: asked.append((name, args)) or copy.deepcopy(walk)
    try:
        text = probes.run(probe["name"], ctx, probe.get("args", {}))
    except probes.ProbeUnreadable as exc:
        if "unreadable" in case and case["unreadable"] in str(exc):
            return None
        return f"unreadable: {exc}; wanted {case.get('reads', case.get('unreadable'))!r}"
    finally:
        spec_probes.live_probes.run = saved
    got = E.loads(text)
    if walk is not None:
        if asked != [("track_flags_ax", {"lproj": "ko", "fixture": probes_fixture_path()})]:
            return f"the probe asked the walker for {asked}"
        if not kept or got.pop("walk_sha256", None) != E.sha256_of_bytes(kept[-1]) \
                or json.loads(kept[-1]) != walk:
            return f"the reading does not cite the walk it was read from as a sidecar: {text[:200]}"
    if "reads" in case and got == case["reads"]:
        return None
    wanted = f"exactly {case['reads']!r}" if "reads" in case else f"unreadable saying {case['unreadable']!r}"
    return f"read {got!r}; wanted {wanted}"


def probes_fixture_path() -> str:
    import setups
    from live import fixture
    return fixture.FIXTURES[setups.declaration("lpm-locale-campaign-19")["live"]]["path"]


def check_probes_implemented(case: dict, where: dict):
    """Every declared probe has an implementation in live/spec_probes.py taking the runner's ctx
    and exactly the declared args, and the #1020 spec uses none that lacks one."""
    import inspect
    import probes
    from live import spec_probes
    for name, declared in sorted(probes.PROBES.items()):
        fn = getattr(spec_probes, name, None)
        if not callable(fn):
            return f"probe {name!r} is declared and not implemented in live/spec_probes.py"
        params = list(inspect.signature(fn).parameters)
        if params != ["ctx"] + list(declared["args"]):
            return f"probe {name!r} takes {params}, not ctx and its declared args {list(declared['args'])}"
    with open(os.path.join(ROOT, "docs", "acceptance", "1020.json"), encoding="utf-8") as handle:
        missing = probes.unimplemented(json.load(handle))
    return f"docs/acceptance/1020.json: {missing}" if missing else None


def check_live_fixtures(case: dict, where: dict):
    """The live lifecycle accepts every registered fixture that has a live declaration and refuses
    every other one before anything is built. Nothing is driven: fixture_problems reads only the
    declarations."""
    import runner_live
    import setups
    lifecycle = runner_live.LiveLifecycle()
    for ident, entry in sorted(setups.SETUPS.items()):
        got = lifecycle.fixture_problems(setups.declaration(ident))
        if entry["live"] is not None and got:
            return f"{ident}: refused: {got}"
        if entry["live"] is None and not any("only the self-test drives it" in p for p in got):
            return f"{ident} has no live declaration, and the live lifecycle said {got}"
    return None


CHECKS = {"records_cite_their_bytes": check_records_cite_their_bytes,
          "pilot_full_record_is_declined": check_pilot_full_record_is_declined,
          "run_cli_has_no_life_seam": check_run_cli_has_no_life_seam,
          "live_records_go_to_sidecars": check_live_records_go_to_sidecars,
          "live_reset_is_judged": check_live_reset_is_judged,
          "nan_not_written": check_nan_not_written,
          "closed_stdout_keeps_the_exit": check_closed_stdout_keeps_the_exit,
          "attestation_built_only_in_process": check_attestation_built_only_in_process,
          "attestation_check_sees_the_whole_repository": check_attestation_check_sees_the_whole_repository,
          "life_seam_named_outside_selftest": check_life_seam_named_outside_selftest,
          "reply": check_reply,
          "gate": check_gate,
          "live_fixtures": check_live_fixtures,
          "probe": check_probe,
          "probes_implemented": check_probes_implemented}


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
    elif "run" in case:
        code, text = _run_fake(case, where)
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


def run_cases(cases: list, first_failure: bool = False) -> tuple:
    """(names passed, [(name, why)] failed). With first_failure, stop after the first failed case:
    a caller that only wants to know whether the copy is killed does not need the rest named."""
    passed, failed = [], []
    saved = os.environ.get("LPM_VERIFY_ISSUE_BODIES")
    os.environ["LPM_VERIFY_ISSUE_BODIES"] = os.path.join(FIXTURES, "issues")
    try:
        with tempfile.TemporaryDirectory(prefix="lpm-verify-cases-") as tmp:
            where = {"fixtures": FIXTURES, "root": ROOT, "tmp": tmp, "measured": {}}
            for case in cases:
                why = run_case(case, where)
                (failed.append((case["name"], why)) if why else passed.append(case["name"]))
                if why and first_failure:
                    break
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
    # A mutant is killed by its first failing case, so running the remaining cases only named more
    # cases. On a 3-core CI runner that took this guard past its 600 s deadline. Measured: 157
    # mutants reached their first failure after 46% of the cases on average.
    with tempfile.TemporaryDirectory(prefix=f"lpm-verify-mutant-{mutant['id']}-") as tmp:
        try:
            target = _mutated_tree(mutant, tmp)
        except RuntimeError as exc:
            return {"id": mutant["id"], "state": "BROKEN", "by": [], "why": str(exc)}
        env = dict(os.environ, LPM_VERIFY_REPO=os.environ.get("LPM_VERIFY_REPO") or ROOT,
                   PYTHONDONTWRITEBYTECODE="1")
        proc = subprocess.run([sys.executable, os.path.join(target, "verify.py"), "self-test",
                               "--cases-only", "--first-failure"], env=env, capture_output=True,
                              text=True, timeout=600)
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

def main(cases_only: bool = False, first_failure: bool = False) -> int:
    cases = load_cases()
    passed, failed = run_cases(cases, first_failure=first_failure)
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
