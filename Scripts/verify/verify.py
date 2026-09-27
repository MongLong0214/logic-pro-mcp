#!/usr/bin/env python3
"""The fixed verifier's command line (ADR-027). Its exit code is the verdict.

    verify.py check-spec <spec>                  is this acceptance document admissible?
    verify.py recheck <evidence> [--spec <spec>] recompute every verdict from stored observations
    verify.py record <evidence> --out <dir>      generate observation records from evidence
    verify.py run ... / verify.py batch ...      P0b: the live lifecycle (stubs; exit 2)
    verify.py self-test                          fixtures and engine mutants, offline

EXIT CODES
----------
    0  clean       check-spec: admissible. recheck: every row PASSES in every required locale,
                   the stored verdicts equal the recomputed ones, and the binary is bound.
    1  failed      a row FAILED, a stored verdict disagrees with the engine, or self-test failed
    2  refused     usage error, malformed input, or a refusal rule (engine.validate_spec)
    3  incomplete  unreadable or incomplete: a row UNREADABLE, a locale not run, an unbound binary,
                   or a source whose text could not be fetched

This file does I/O and printing only. Every verdict comes from `engine.py`.

SEAMS, for the self-test and nothing else:
    LPM_VERIFY_REPO          the git repository quotes are read from and a head must be a commit
                             of (default: this checkout)
    LPM_VERIFY_ISSUE_BODIES  a directory of `<n>.md` issue bodies read instead of `gh`
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, HERE)

import engine  # noqa: E402
import evidence_doc as E  # noqa: E402
import predicates as P  # noqa: E402

GITHUB_REPO = "MongLong0214/logic-pro-mcp"
WORDS = {engine.EXIT_CLEAN: "clean", engine.EXIT_FAILED: "failed",
         engine.EXIT_REFUSED: "refused", engine.EXIT_INCOMPLETE: "incomplete"}


def repo() -> str:
    return engine.repo_root()


# ---------------------------------------------------------------------------------------------
# check-spec
# ---------------------------------------------------------------------------------------------

def fetch_source_text(source: dict):
    """(text, None) or (None, why it could not be read). Never an empty text in place of one."""
    issue = engine.ISSUE_DOC.match(source["doc"])
    if issue:
        bodies = os.environ.get("LPM_VERIFY_ISSUE_BODIES")
        if bodies:
            path = os.path.join(bodies, f"{issue.group(1)}.md")
            try:
                with open(path, encoding="utf-8") as handle:
                    return handle.read(), None
            except OSError as exc:
                return None, f"{path}: {exc}"
        cmd = ["gh", "issue", "view", issue.group(1), "--repo", GITHUB_REPO, "--json", "body"]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError) as exc:
            return None, f"gh: {exc}"
        if proc.returncode != 0:
            return None, f"gh issue view {issue.group(1)}: {proc.stderr.strip().splitlines()[:1]}"
        return json.loads(proc.stdout)["body"], None
    cmd = ["git", "-C", repo(), "show", f"{source['sha']}:{source['doc']}"]
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, f"git: {exc}"
    if proc.returncode != 0:
        return None, f"git show {source['sha'][:12]}:{source['doc']}: " \
                     f"{proc.stderr.decode('utf-8', 'replace').strip()}"
    return proc.stdout.decode("utf-8", "replace"), None


def cmd_check_spec(args) -> int:
    try:
        spec = E.load(args.spec)
    except (OSError, ValueError) as exc:
        print(f"REFUSED {args.spec}: {exc}")
        return engine.EXIT_REFUSED
    problems = engine.validate_spec(spec)
    unfetched = []
    if not engine.shape_problems(spec, engine.load_schema()):
        for i, source in enumerate(spec["sources"]):
            text, why = fetch_source_text(source)
            if text is None:
                unfetched.append(f"sources[{i}]: {why}")
            elif not engine.quote_holds(text, source["quote"]):
                at = "the issue body" if source["sha"] is None else f"{source['doc']} at {source['sha'][:12]}"
                problems.append(f"sources[{i}]: the quote is not verbatim in {at}")
    for line in problems:
        print(f"REFUSED {line}")
    for line in unfetched:
        print(f"UNREADABLE {line}")
    if problems:
        print(f"check-spec: {args.spec}: refused, {len(problems)} problem(s) (exit 2)")
        return engine.EXIT_REFUSED
    if unfetched:
        print(f"check-spec: {args.spec}: a source could not be read, so its quote is unchecked (exit 3)")
        return engine.EXIT_INCOMPLETE
    locales = engine.required_locales(spec)
    print(f"check-spec: {args.spec}: admissible -- {len(spec['rows'])} row(s), "
          f"{len(spec['sources'])} source quote(s) verbatim, {len(locales)} locale(s) (exit 0)")
    return engine.EXIT_CLEAN


# ---------------------------------------------------------------------------------------------
# recheck
# ---------------------------------------------------------------------------------------------

def _load_or_refuse(path: str):
    try:
        return E.load(path), None
    except (OSError, ValueError) as exc:
        return None, f"REFUSED {path}: {exc}"


def cmd_recheck(args) -> int:
    doc, why = _load_or_refuse(args.evidence)
    if doc is None:
        print(why)
        return engine.EXIT_REFUSED
    expected = None
    if args.spec:
        expected, why = _load_or_refuse(args.spec)
        if expected is None:
            print(why)
            return engine.EXIT_REFUSED
    result = engine.judge(doc, expected_spec=expected)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=1))
        return result["exit"]
    for locale in sorted(result["verdicts"]):
        for rid, verdict in result["verdicts"][locale].items():
            print(f"{verdict['verdict']:<10} {locale}/{rid}")
            for reason in verdict["reasons"]:
                print(f"           {reason}")
    for key, label in (("refusals", "REFUSED"), ("mismatches", "MISMATCH"),
                       ("failures", "FAILED"), ("incomplete", "INCOMPLETE")):
        for line in result[key]:
            print(f"{label} {line}")
    print(f"recheck: {args.evidence}: {WORDS[result['exit']]} (exit {result['exit']})")
    return result["exit"]


# ---------------------------------------------------------------------------------------------
# record
# ---------------------------------------------------------------------------------------------

def _axis_locale(code: str):
    """The observation axis spelling (`ko-KR`) of a canon locale code (`ko`), from the axis file."""
    import observation_host
    return observation_host.axis_locale(code.replace("_", "-"), observation_host.axis_locales())


def build_record(doc: dict, locale: str, verdicts: dict, evidence_rel: str) -> dict:
    """One observation record for one locale's run. Every value is read from the evidence."""
    spec, run, binary = doc["spec"], doc["runs"][locale], doc["binary"]
    evidence_sha = os.path.splitext(os.path.basename(evidence_rel))[0]
    host = dict(run["host"])
    rows = spec["rows"]
    by_verdict = {o: [r["id"] for r in rows if verdicts[r["id"]]["verdict"] == o] for o in P.OUTCOMES}
    if len(by_verdict[P.PASS]) == len(rows):
        word = "works"
    elif by_verdict[P.PASS]:
        word = "partial"
    else:
        word = "inconclusive"
    observations, citations = [], []
    for row in rows:
        entries = run["rows"].get(row["id"], {}).get("observations", {})
        readings = {}
        for name, entry in entries.items():
            value = engine.observation_value(entry)
            readings[name] = value.value if isinstance(value, P.Found) else {"unreadable": value.reason}
        observations.append({"row": row["id"], "verdict": verdicts[row["id"]]["verdict"],
                             "reasons": verdicts[row["id"]]["reasons"], "readings": readings})
        for i, e in enumerate(row["expect"]):
            ref = e.get("ref") or {}
            if "canon" in ref and verdicts[row["id"]]["expect"][i] == P.PASS:
                found = engine._lookup({k: engine.observation_value(v) for k, v in entries.items()})(e["path"])
                parsed = engine.logic_canon.CanonRef.parse(ref["canon"])
                code = locale if ref["locale"] == "$locale" else ref["locale"]
                cited = engine.logic_canon.CanonRef(parsed.source, parsed.unit, code, parsed.key, parsed.field)
                citations.append({"ref": str(cited), "value": found.value,
                                  "used_for": f"{row['id']}: expect[{i}] {e['path']} matches_canon"})
    listing = "; ".join(f"{o}: {', '.join(ids) if ids else 'none'}" for o, ids in by_verdict.items())
    record = {
        "id": f"{run['date']}-{host.get('locale')}-acceptance-{spec['issue']}-{evidence_sha[:12]}",
        "date": run["date"],
        "subject": f"the acceptance rows of #{spec['issue']} ({doc['spec_path']}), judged by the fixed verifier",
        "question": f"Does each acceptance row in {doc['spec_path']} pass in {locale}, against the "
                    f"binary built from {binary[E.HEAD]}?",
        "verdict": word,
        "issues": [spec["issue"]],
        "surface": spec["surface"],
        "schema": 3,
        "host": host,
        "reverify": {
            "kind": "script",
            "command": f"python3 Scripts/verify/verify.py recheck docs/observations/{evidence_rel}",
            "expected": "the verdicts listed in observations; exit 0 only when every row passes in "
                        "every locale the spec requires and the binary is bound",
            "cost": "offline: reads the stored observations and docs/canon/index",
        },
        "depends": [],
        "method": f"Generated by Scripts/verify/verify.py record from the evidence bytes it judged, "
                  f"published under their own sha256 as {evidence_rel}. The runner stored each "
                  f"step's raw text untruncated; Scripts/verify/engine.py parsed it and computed "
                  f"every verdict. Binary sha256 {binary[E.BINARY_SHA256]}, head {binary[E.HEAD]}, "
                  f"binding {binary[E.BINDING]}, provenance re-measured on the recording host.",
        "observations": observations,
        "conclusion": f"Row verdicts in {locale}. {listing}.",
        "limits": [
            "Generated, not written: it states the engine's verdicts over the stored observations "
            "and nothing the observations do not contain.",
            f"True of the binary named in method, in {locale} only; the other locales the spec "
            f"requires have their own records or none.",
        ],
        "supersedes": None,
        "evidence": [evidence_rel],
    }
    if citations:
        record["canon"] = citations
    else:
        record["canon_not_applicable"] = {
            "reason": "These rows compare reply fields and readings against constants and against "
                      "other readings; none of them cites a string Logic ships."}
    return record


def cmd_record(args) -> int:
    """Judge the evidence BYTES once, publish exactly those bytes under their sha256, then write
    records that cite that name. A later run can never take an earlier record's evidence."""
    try:
        with open(args.evidence, "rb") as handle:
            data = handle.read()
        doc = json.loads(data.decode("utf-8"))
    except (OSError, ValueError) as exc:
        print(f"REFUSED {args.evidence}: {exc}")
        return engine.EXIT_REFUSED
    result = engine.judge(doc)
    if result["exit"] == engine.EXIT_REFUSED:
        for line in result["refusals"]:
            print(f"REFUSED {line}")
        return engine.EXIT_REFUSED
    if result["provenance"] != engine.MEASURED:
        why = [line for line in result["incomplete"] if line.startswith("binary:")]
        print(f"record: refused to write -- provenance is {result['provenance']!r} "
              f"({'; '.join(why)}), so a record would claim a binary the evidence cannot prove (exit 3)")
        return engine.EXIT_INCOMPLETE
    ready, skipped = [], []
    for locale in sorted(result["verdicts"]):
        run = doc["runs"][locale]
        status, why = engine.run_locale_status(locale, run)
        if status != engine.MEASURED:
            skipped.append(f"{locale}: locale {status} -- {why}")
        elif not isinstance(run.get("host"), dict) or not run.get("date"):
            skipped.append(f"{locale}: the run stored no host block or date")
        else:
            ready.append(locale)
    written = []
    if ready:
        name = E.publish_content_addressed(os.path.join(args.out, "evidence"), data)
        evidence_rel = f"evidence/{name}"
        print(f"wrote {os.path.join(args.out, evidence_rel)}")
        for locale in ready:
            record = build_record(doc, locale, result["verdicts"][locale], evidence_rel)
            path = os.path.join(args.out, f"{record['id']}.json")
            E.write_atomic(path, record)
            written.append(path)
    for path in written:
        print(f"wrote {path}")
    for line in skipped:
        print(f"SKIPPED {line}")
    code = engine.EXIT_CLEAN if written and not skipped else engine.EXIT_INCOMPLETE
    print(f"record: {len(written)} record(s) written (exit {code})")
    return code


# ---------------------------------------------------------------------------------------------
# P0b stubs
# ---------------------------------------------------------------------------------------------

def cmd_p0b(args) -> int:
    print(f"verify.py {args.command}: P0b. The live lifecycle (build from a clean detached checkout, "
          f"locale switch, fixture reset, probes) is the next ticket; see Scripts/verify/runner.py "
          f"for the interfaces it implements. Nothing was run. (exit 2)")
    return engine.EXIT_REFUSED


def cmd_self_test(args) -> int:
    import selftest
    return selftest.main(cases_only=args.cases_only)


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser(prog="verify.py", description=__doc__.split("\n")[0])
    sub = top.add_subparsers(dest="command", required=True)
    p = sub.add_parser("check-spec", help="refuse an inadmissible acceptance document")
    p.add_argument("spec")
    p.set_defaults(func=cmd_check_spec)
    p = sub.add_parser("recheck", help="recompute every verdict from stored observations")
    p.add_argument("evidence")
    p.add_argument("--spec", help="also require the embedded spec to equal this document")
    p.add_argument("--json", action="store_true", help="print the engine's result as JSON")
    p.set_defaults(func=cmd_recheck)
    p = sub.add_parser("record", help="generate observation records from evidence")
    p.add_argument("evidence")
    p.add_argument("--out", required=True, help="the records directory, e.g. docs/observations")
    p.set_defaults(func=cmd_record)
    p = sub.add_parser("run", help="P0b: run one spec's rows against a head, in its locales")
    p.add_argument("spec")
    p.add_argument("--head", required=True, help="the full 40-hex commit to build and run")
    p.add_argument("--locales", help="comma-separated subset; default: the spec's locales")
    p.add_argument("--out", required=True, help="where to write the evidence document")
    p.set_defaults(func=cmd_p0b)
    p = sub.add_parser("batch", help="P0b: switch each locale once and run every queued head's rows")
    p.add_argument("--queue", default="docs/acceptance/QUEUE.json")
    p.add_argument("--out-dir", required=True)
    p.set_defaults(func=cmd_p0b)
    p = sub.add_parser("self-test", help="fixtures and engine mutants, offline")
    p.add_argument("--cases-only", action="store_true", help=argparse.SUPPRESS)
    p.set_defaults(func=cmd_self_test)
    return top


def main(argv=None) -> int:
    try:
        args = parser().parse_args(argv)
    except SystemExit as exc:
        return engine.EXIT_REFUSED if exc.code else engine.EXIT_CLEAN
    return args.func(args)


if __name__ == "__main__":
    with contextlib.suppress(BrokenPipeError):
        sys.exit(main())
