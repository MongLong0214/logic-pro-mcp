"""The verdict engine of the fixed verifier (ADR-027). The ONLY place a verdict is computed.

Given an acceptance document (`docs/acceptance/<issue>.json`, format `lpm-acceptance/1`) and a
run's raw observations, this computes each row's verdict, each locale's, and the exit code. The
runner (P0b) supplies observations; nothing it writes is read as a pass. There is no `passed`
field anywhere in the input, so an author cannot supply one.

WHAT IS REFUSED (exit 2) -- `validate_spec`, the one place these rules live
----------------------------------------------------------------------------
  * a document that does not match `acceptance_schema.json` (shape);
  * a repository source without a 40-hex commit, or an issue source with one;
  * any string in `fixture` or `rows` that points into product source (`Sources/`,
    `AXLocalePolicy`, `AXLocaleValues`), or a source document under `Sources/` (ADR-027 D3);
  * a locale subset naming anything outside the ten, or without a reason;
  * a path, operand or independence name that no earlier step of the row binds;
  * an operator given the wrong kind of operand (`changed` against a constant, `matches_canon`
    against anything but a canon reference, `is_null` with an operand);
  * a canon VALUE citation (`logic-canon://<source>/<locale>#value`): coincidental presence
    anywhere in a locale is not the row the UI uses (ADR-027 D6);
  * a probe the registry does not declare, or args that do not match its declaration;
  * a counterexample whose `must_fail` expectation does not read the observation it replaces
    (substituting it could not change the outcome, so it proves nothing);
  * THE INDEPENDENCE RULE: a row in which no expectation that reads an independent observation is
    listed in a counterexample's `must_fail`. An operation's own reply (a `call` step) is never
    independent. A row whose only falsifiable checks read the reply is self-report.

HOW A ROW IS JUDGED -- `evaluate_row`
-------------------------------------
Every expectation is PASS, FAIL or UNREADABLE (see predicates.py). Then, with the counterexample
observation substituted for the one it replaces, every `must_fail` expectation must FAIL; a PASS
there is `counterexample_accepted`. Every `restore_expect` must PASS; a FAIL is `restore_failed`.
An observation stored for a different step than the spec declares, or truncated, or not stored at
all, is UNREADABLE. The row is FAIL if anything failed, else UNREADABLE if anything was unreadable,
else PASS.

HOW EVIDENCE IS JUDGED -- `judge`
---------------------------------
    2  refused     the evidence or its embedded spec is malformed or breaks a rule above
    1  failed      a row FAILED in some locale, or a stored verdict differs from the recomputed one
    3  incomplete  nothing failed, but a row was UNREADABLE, a required locale was not run, or the
                   binary is not bound to its head by construction ("unbound" is never clean)
    0  clean       every row PASSES in every required locale, the stored verdicts equal the
                   recomputed ones, and the binary was built by the verifier from the head

A definite failure outranks an incomplete run: a FAIL in the one locale that ran is already an
answer, and reporting it as "incomplete" would hide it behind the locales that did not.
"""
from __future__ import annotations

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import evidence_doc as E  # noqa: E402
import logic_canon  # noqa: E402
import predicates as P  # noqa: E402
import probes  # noqa: E402

SPEC_FORMAT = "lpm-acceptance/1"
SCHEMA_PATH = os.path.join(HERE, "acceptance_schema.json")

#: "all" means these. Read from the canon module rather than typed here, so the verifier and the
#: canon agree on what the ten are.
ALL_LOCALES = tuple(logic_canon.EXPECTED_LOCALES)

#: An expectation must not be taken from the product it judges (ADR-027 D3).
PRODUCT_SOURCE = re.compile(r"Sources/|AXLocalePolicy|AXLocaleValues")

NO_OPERAND = ("is_null", "not_null")
OBS_OPERAND = ("changed", "unchanged")
CANON_OPERAND = ("matches_canon",)
LIST_OPERAND = ("in", "not_in", "subset", "superset")
COUNT_OPERAND = ("count_eq", "count_ge")

ISSUE_DOC = re.compile(r"^issue:([1-9][0-9]*)$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")

EXIT_CLEAN, EXIT_FAILED, EXIT_REFUSED, EXIT_INCOMPLETE = 0, 1, 2, 3

#: The only parts of a stored verdict compared on recheck. `reasons` is prose for people, and an
#: engine that words a reason better is not an engine that disagrees.
VERDICT_KEYS = ("verdict", "expect", "counterexample", "restore")


# ---------------------------------------------------------------------------------------------
# shape: a subset JSON Schema validator, because the verifier is stdlib-only
# ---------------------------------------------------------------------------------------------

_SCHEMA_KEYWORDS = {"$schema", "$id", "title", "description", "$defs", "$ref", "type", "enum",
                    "const", "properties", "required", "additionalProperties", "items", "minItems",
                    "minLength", "minimum", "maximum", "pattern", "oneOf"}
_TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}


def load_schema(path: str = SCHEMA_PATH) -> dict:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def shape_problems(value, schema: dict, root: dict = None, at: str = "$") -> list:
    """Where `value` departs from `schema`. A keyword this validator does not implement is an
    error in the SCHEMA, raised, so a constraint written there can never be silently ignored."""
    root = root if root is not None else schema
    unknown = set(schema) - _SCHEMA_KEYWORDS
    if unknown:
        raise ValueError(f"schema at {at} uses {sorted(unknown)}, which this validator does not implement")
    if "$ref" in schema:
        return shape_problems(value, root["$defs"][schema["$ref"].rsplit("/", 1)[-1]], root, at)
    if "oneOf" in schema:
        results = [shape_problems(value, alt, root, at) for alt in schema["oneOf"]]
        passing = [r for r in results if not r]
        if len(passing) == 1:
            return []
        if not passing:
            return min(results, key=len)
        return [f"{at}: matches {len(passing)} of the allowed shapes; it must match exactly one"]
    if "const" in schema and not P.same(value, schema["const"]):
        return [f"{at}: must be {json.dumps(schema['const'])}"]
    if "enum" in schema and not any(P.same(value, e) for e in schema["enum"]):
        return [f"{at}: {json.dumps(value, ensure_ascii=False)} is not one of {schema['enum']}"]
    if "type" in schema and not _TYPES[schema["type"]](value):
        return [f"{at}: must be {schema['type']}, not {P.kind_of(value)}"]
    out = []
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            out.append(f"{at}: shorter than {schema['minLength']} characters")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            out.append(f"{at}: {value!r} does not match {schema['pattern']}")
    if _TYPES["integer"](value):
        if "minimum" in schema and value < schema["minimum"]:
            out.append(f"{at}: below {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            out.append(f"{at}: above {schema['maximum']}")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            out.append(f"{at}: needs at least {schema['minItems']} item(s)")
        if "items" in schema:
            for i, item in enumerate(value):
                out += shape_problems(item, schema["items"], root, f"{at}[{i}]")
    if isinstance(value, dict):
        for key in schema.get("required", ()):
            if key not in value:
                out.append(f"{at}: missing {key!r}")
        props = schema.get("properties", {})
        for key, item in value.items():
            if key in props:
                out += shape_problems(item, props[key], root, f"{at}.{key}")
            elif schema.get("additionalProperties") is False:
                out.append(f"{at}: {key!r} is not a field of this format")
    return out


# ---------------------------------------------------------------------------------------------
# refusal rules: validate_spec is the one place they live
# ---------------------------------------------------------------------------------------------

def required_locales(spec: dict) -> list:
    return list(ALL_LOCALES) if spec["locales"] == "all" else list(spec["locales"]["subset"])


def root_of(path: str) -> str:
    return P.parse_path(path)[0]


def validate_spec(spec, schema: dict = None) -> list:
    """Every reason this acceptance document is refused. Empty means it may be run."""
    problems = shape_problems(spec, schema if schema is not None else load_schema())
    if problems:
        return problems
    out = []
    for i, source in enumerate(spec["sources"]):
        out += [f"sources[{i}]: {p}" for p in source_problems(source)]
    out += locale_problems(spec["locales"])
    ids = [row["id"] for row in spec["rows"]]
    out += [f"rows: id {i!r} appears twice" for i in sorted({i for i in ids if ids.count(i) > 1})]
    for row in spec["rows"]:
        out += [f"rows[{row['id']}]: {p}" for p in row_problems(row, len(spec["sources"]))]
    for where, text in _strings({"fixture": spec["fixture"], "rows": spec["rows"]}, "$"):
        if PRODUCT_SOURCE.search(text):
            out.append(f"{where}: {text!r} refers into product source. An expectation, step or "
                       f"fixture taken from the product cannot judge it (ADR-027 D3)")
    return out


def source_problems(source: dict) -> list:
    doc, sha = source["doc"], source["sha"]
    if ISSUE_DOC.match(doc):
        return [] if sha is None else [f"{doc} is an issue; its text is read from GitHub, so `sha` is null"]
    out = []
    if sha is None:
        out.append(f"{doc} is a repository document, so it names the 40-hex commit its quote is at")
    if doc.startswith("/") or ".." in doc.split("/"):
        out.append(f"{doc!r} is not a repository-relative path")
    if PRODUCT_SOURCE.search(doc):
        out.append(f"{doc!r} is product source; a criterion comes from an ADR, PRD or issue (ADR-027 D1)")
    return out


def locale_problems(locales) -> list:
    if locales == "all":
        return []
    subset, out = locales["subset"], []
    for code in subset:
        if code not in ALL_LOCALES:
            out.append(f"locales: {code!r} is not one of the ten ({' '.join(ALL_LOCALES)})")
    if len(set(subset)) != len(subset):
        out.append("locales: the subset names a locale twice")
    if not locales["reason"].strip():
        out.append("locales: a subset of the ten needs a reason; 'all' is the default scope")
    return out


def row_problems(row: dict, n_sources: int) -> list:
    out = []
    if row["criterion"] >= n_sources:
        out.append(f"criterion {row['criterion']} indexes past the {n_sources} source(s)")
    steps = {s["as"]: s for s in row["steps"]}
    after = {s["as"]: s for s in row["restore"]}
    names = [s["as"] for s in row["steps"] + row["restore"]]
    out += [f"step name {n!r} is bound twice" for n in sorted({n for n in names if names.count(n) > 1})]
    for step in row["steps"] + row["restore"]:
        out += [f"step {step['as']!r}: {p}" for p in step_problems(step)]
    expect = row["expect"]
    for i, e in enumerate(expect):
        out += [f"expect[{i}]: {p}" for p in expectation_problems(e, set(steps))]
    for j, e in enumerate(row["restore_expect"]):
        out += [f"restore_expect[{j}]: {p}" for p in expectation_problems(e, set(steps) | set(after))]
    for name in row["independence"]:
        if name not in steps:
            out.append(f"independence names {name!r}, which is not a step of this row")
        elif "call" in steps[name]:
            out.append(f"independence names {name!r}, which is an operation's own reply (a call)")
    independent = {n for n in row["independence"] if n in steps and "call" not in steps[n]}
    proven = set()
    for k, cx in enumerate(row["counterexample"]):
        for key in ("observation", "replaces"):
            if cx[key] not in steps:
                out.append(f"counterexample[{k}].{key} {cx[key]!r} is not a step of this row")
        if cx["observation"] == cx["replaces"]:
            out.append(f"counterexample[{k}] replaces {cx['replaces']!r} with itself")
        if len(set(cx["must_fail"])) != len(cx["must_fail"]):
            out.append(f"counterexample[{k}].must_fail names an expectation twice")
        for i in cx["must_fail"]:
            if i >= len(expect):
                out.append(f"counterexample[{k}].must_fail: expect[{i}] does not exist")
            elif _safe_root(expect[i]["path"]) != cx["replaces"]:
                out.append(f"counterexample[{k}].must_fail: expect[{i}] reads "
                           f"{_safe_root(expect[i]['path'])!r}, not {cx['replaces']!r}, so the "
                           f"substitution cannot change its outcome")
            else:
                proven.add(i)
    if not any(_safe_root(expect[i]["path"]) in independent for i in proven):
        out.append("no expectation that reads an independent observation is listed in a "
                   "counterexample's must_fail. A row whose only falsifiable checks read the "
                   "operation's own reply is self-report (ADR-027 D1, D4)")
    return out


def _safe_root(path: str):
    try:
        return root_of(path)
    except ValueError:
        return None


def step_problems(step: dict) -> list:
    if "probe" in step:
        return probes.arg_problems(step["probe"]["name"], step["probe"]["args"])
    if "wait" not in step:
        return []
    wait = step["wait"]
    out = probes.arg_problems(wait["probe"]["name"], wait["probe"]["args"])
    if wait["interval_ms"] > wait["timeout_ms"]:
        out.append("wait: interval_ms exceeds timeout_ms, so it would read once and call that waiting")
    until = wait["until"]
    joiner = "" if until["path"].startswith("[") else "."
    try:
        P.parse_path(step["as"] + joiner + until["path"])
    except ValueError as exc:
        out.append(f"wait.until: {exc}")
    op = until["op"]
    if op in NO_OPERAND and "value" in until:
        out.append(f"wait.until: {op} takes no operand")
    elif op in OBS_OPERAND + CANON_OPERAND:
        out.append(f"wait.until: {op} needs a ref, and a wait condition takes a constant")
    elif op not in NO_OPERAND and "value" not in until:
        out.append(f"wait.until: {op} needs a value")
    return out


def expectation_problems(e: dict, bound: set) -> list:
    out = []
    try:
        root = root_of(e["path"])
        if root not in bound:
            out.append(f"{e['path']!r} reads {root!r}, which no step before it binds")
    except ValueError as exc:
        out.append(str(exc))
    op, has_value, ref = e["op"], "value" in e, e.get("ref")
    if op in NO_OPERAND:
        if has_value or ref:
            out.append(f"{op} takes no operand")
    elif op in OBS_OPERAND:
        if has_value or not (ref and "obs" in ref):
            out.append(f"{op} compares against another observation: give ref.obs, not a value")
    elif op in CANON_OPERAND:
        if has_value or not (ref and "canon" in ref):
            out.append(f"{op} compares against a canon reference: give ref.canon")
    else:
        if has_value == bool(ref):
            out.append(f"{op} takes exactly one of value or ref")
        if ref and "canon" in ref:
            out.append(f"a canon reference resolves to a digest; only matches_canon compares one")
    if has_value and op in COUNT_OPERAND and not (P.is_int(e["value"]) and e["value"] >= 0):
        out.append(f"{op} counts against a non-negative integer")
    if has_value and op in LIST_OPERAND and not isinstance(e["value"], list):
        out.append(f"{op} compares against a list")
    if ref and "obs" in ref:
        try:
            ref_root = root_of(ref["obs"])
            if ref_root not in bound:
                out.append(f"ref {ref['obs']!r} reads {ref_root!r}, which no step before it binds")
        except ValueError as exc:
            out.append(f"ref: {exc}")
    if ref and "canon" in ref:
        out += canon_problems(ref)
    return out


def canon_problems(ref: dict) -> list:
    try:
        parsed = logic_canon.CanonRef.parse(ref["canon"])
    except logic_canon.CanonError as exc:
        return [str(exc).splitlines()[0]]
    out = []
    if parsed.is_value_citation:
        out.append("a canon value citation says Apple ships the string somewhere in the locale; a "
                   "row cites the key the UI element uses (ADR-027 D6: derivation is positional)")
    if ref["locale"] != "$locale" and ref["locale"] not in ALL_LOCALES:
        out.append(f"canon locale {ref['locale']!r} is neither $locale nor one of the ten")
    if not parsed.is_value_citation:
        # The reference text pins one locale; `quote` is the value there. check-canon-citations
        # asks the same of every reference in the repository (the reference AND the value), and
        # checking it here means a spec cannot cite one row while its author reads another.
        try:
            pinned = logic_canon.resolve_offline(parsed)
        except logic_canon.CanonError as exc:
            out.append(f"canon reference is not pinned: {str(exc).splitlines()[0]}")
        else:
            if logic_canon.short_digest(ref["quote"]) != pinned:
                out.append(f"canon quote {ref['quote']!r} is not the value {ref['canon']} pins "
                           f"in {parsed.locale}")
    return out


def _strings(node, at):
    """(where, text) for every string key and value under `node`."""
    if isinstance(node, str):
        yield at, node
    elif isinstance(node, dict):
        for key, value in node.items():
            yield f"{at}.{key}", key
            yield from _strings(value, f"{at}.{key}")
    elif isinstance(node, list):
        for i, value in enumerate(node):
            yield from _strings(value, f"{at}[{i}]")


def quote_holds(text: str, quote: str) -> bool:
    """Whether a source quote is verbatim in the document text: exact substring, no folding."""
    return bool(quote) and quote in text


# ---------------------------------------------------------------------------------------------
# judging
# ---------------------------------------------------------------------------------------------

def observation_value(entry) -> "P.Found | P.Unreadable":
    """The JSON value an observation holds, parsed from its raw text now, or why there is none."""
    if not isinstance(entry, dict):
        return P.Unreadable("the observation entry is not an object")
    if "unreadable" in entry:
        return P.Unreadable(f"the runner could not read it: {entry['unreadable']}")
    raw, size = entry.get("raw"), entry.get("raw_bytes")
    if not isinstance(raw, str) or not P.is_int(size):
        return P.Unreadable("the observation carries no raw text and raw_bytes")
    stored = len(raw.encode("utf-8"))
    if stored != size:
        return P.Unreadable(f"truncated or altered: {stored} bytes stored of the {size} received")
    try:
        return P.Found(json.loads(raw))
    except ValueError as exc:
        return P.Unreadable(f"the raw text is not JSON ({exc})")


def resolve_canon_offline(ref_text: str, locale_spec: str, run_locale: str):
    """The pinned digest a canon reference names in this run's locale, from docs/canon/index."""
    locale = run_locale if locale_spec == "$locale" else locale_spec
    try:
        parsed = logic_canon.CanonRef.parse(ref_text)
        ref = logic_canon.CanonRef(parsed.source, parsed.unit, locale, parsed.key, parsed.field)
        return P.Found(logic_canon.resolve_offline(ref))
    except logic_canon.CanonError as exc:
        return P.Unreadable(f"canon reference not pinned in {locale}: {str(exc).splitlines()[0]}")


def _lookup(bindings: dict):
    def lookup(path: str):
        root, segments = P.parse_path(path)
        value = bindings.get(root)
        if value is None:
            return P.Unreadable(f"{root}: not bound in this row")
        if isinstance(value, P.Unreadable):
            return P.Unreadable(f"{root}: {value.reason}")
        return P.walk(value.value, segments, root)
    return lookup


def _judge_one(e: dict, lookup, locale: str, resolve_canon):
    operand = None
    if "value" in e:
        operand = P.Found(e["value"])
    elif "ref" in e:
        ref = e["ref"]
        operand = lookup(ref["obs"]) if "obs" in ref else resolve_canon(ref["canon"], ref["locale"], locale)
    return P.check(e["op"], lookup(e["path"]), operand)


def evaluate_row(row: dict, run_row, locale: str, resolve_canon=resolve_canon_offline) -> dict:
    """One row's verdict in one locale, from the raw observations stored for it."""
    entries = run_row.get("observations") if isinstance(run_row, dict) else None
    entries = entries if isinstance(entries, dict) else {}
    values = {}
    for step in row["steps"] + row["restore"]:
        name, entry = step["as"], entries.get(step["as"])
        if entry is None:
            values[name] = P.Unreadable("no observation is stored for this step")
        elif not P.same(entry.get("step"), step):
            values[name] = P.Unreadable("the stored observation was taken for a different step "
                                        "than the spec declares")
        else:
            values[name] = observation_value(entry)
    lookup = _lookup(values)
    expect = [_judge_one(e, lookup, locale, resolve_canon) for e in row["expect"]]
    counter = []
    for k, cx in enumerate(row["counterexample"]):
        swapped = dict(values)
        swapped[cx["replaces"]] = values[cx["observation"]]
        cx_lookup = _lookup(swapped)
        for i in cx["must_fail"]:
            counter.append((k, i, _judge_one(row["expect"][i], cx_lookup, locale, resolve_canon)))
    restore = [_judge_one(e, lookup, locale, resolve_canon) for e in row["restore_expect"]]

    reasons, failed, unreadable = [], False, False
    for i, (outcome, detail) in enumerate(expect):
        if outcome != P.PASS:
            reasons.append(f"expect[{i}] {outcome}: {row['expect'][i]['path']} -- {detail}")
        failed |= outcome == P.FAIL
        unreadable |= outcome == P.UNREADABLE
    for k, i, (outcome, detail) in counter:
        cx = row["counterexample"][k]
        if outcome == P.PASS:
            reasons.append(f"counterexample_accepted: expect[{i}] PASSED with {cx['observation']!r} in "
                           f"place of {cx['replaces']!r} -- {detail}")
            failed = True
        elif outcome == P.UNREADABLE:
            reasons.append(f"counterexample UNREADABLE: expect[{i}] on {cx['observation']!r} -- {detail}")
            unreadable = True
    for j, (outcome, detail) in enumerate(restore):
        if outcome == P.FAIL:
            reasons.append(f"restore_failed: restore_expect[{j}] {row['restore_expect'][j]['path']} -- {detail}")
            failed = True
        elif outcome == P.UNREADABLE:
            reasons.append(f"restore UNREADABLE: restore_expect[{j}] -- {detail}")
            unreadable = True
    verdict = P.FAIL if failed else P.UNREADABLE if unreadable else P.PASS
    return {
        "verdict": verdict,
        "expect": [o for o, _ in expect],
        "counterexample": [o for _, _, (o, _) in counter],
        "restore": [o for o, _ in restore],
        "reasons": reasons,
    }


def evaluate_run(spec: dict, run: dict, locale: str, resolve_canon=resolve_canon_offline) -> dict:
    """{row id: verdict} for one locale's run. What a runner stores as `verdicts[locale]`."""
    rows = run.get("rows") if isinstance(run, dict) else None
    rows = rows if isinstance(rows, dict) else {}
    return {row["id"]: evaluate_row(row, rows.get(row["id"]), locale, resolve_canon)
            for row in spec["rows"]}


def evidence_problems(doc) -> list:
    """Why an evidence document cannot be judged at all (shape, not verdicts)."""
    if not isinstance(doc, dict):
        return ["the evidence is not a JSON object"]
    out = []
    if doc.get("format") != E.FORMAT:
        out.append(f"format is {doc.get('format')!r}, not {E.FORMAT!r}")
    for key, kind in (("spec", dict), ("spec_sha256", str), ("binary", dict), ("runs", dict),
                      ("verdicts", dict)):
        if not isinstance(doc.get(key), kind):
            out.append(f"{key} is missing or not a {kind.__name__}")
    if out:
        return out
    if E.sha256_of(doc["spec"]) != doc["spec_sha256"]:
        out.append("spec_sha256 is not the digest of the embedded spec: the rows judged are not "
                   "the rows the run recorded against")
    for locale, run in doc["runs"].items():
        if not isinstance(run, dict) or not isinstance(run.get("rows"), dict):
            out.append(f"runs.{locale} carries no rows object")
    return out


def compare_verdicts(stored: dict, recomputed: dict) -> list:
    """Every (locale, row) whose stored verdict is not the one this engine computes now."""
    out = []
    for locale in sorted(set(stored) | set(recomputed)):
        s = stored.get(locale) if isinstance(stored.get(locale), dict) else {}
        r = recomputed.get(locale) or {}
        for rid in sorted(set(s) | set(r)):
            left = {k: s[rid].get(k) for k in VERDICT_KEYS} if isinstance(s.get(rid), dict) else None
            right = {k: r[rid].get(k) for k in VERDICT_KEYS} if rid in r else None
            if not P.same(left, right):
                out.append(f"{locale}/{rid}: stored verdict {(left or {}).get('verdict')} "
                           f"{(left or {}).get('expect')} differs from the recomputed "
                           f"{(right or {}).get('verdict')} {(right or {}).get('expect')}")
    return out


def judge(doc, schema: dict = None, resolve_canon=resolve_canon_offline, expected_spec=None) -> dict:
    """The verdict on one evidence document. `exit` is the process exit code; everything else
    says why."""
    result = {"exit": EXIT_REFUSED, "refusals": [], "failures": [], "incomplete": [],
              "mismatches": [], "verdicts": {}}
    refusals = evidence_problems(doc)
    if not refusals and expected_spec is not None and not P.same(doc["spec"], expected_spec):
        refusals.append("the embedded spec is not the acceptance document given with --spec")
    if not refusals:
        refusals += [f"spec: {p}" for p in validate_spec(doc["spec"], schema)]
    if refusals:
        result["refusals"] = refusals
        return result
    spec = doc["spec"]
    recomputed = {}
    for locale in required_locales(spec):
        if locale not in doc["runs"]:
            result["incomplete"].append(f"{locale}: required by the spec and not run")
            continue
        recomputed[locale] = evaluate_run(spec, doc["runs"][locale], locale, resolve_canon)
        for rid, verdict in recomputed[locale].items():
            if verdict["verdict"] == P.FAIL:
                result["failures"].append(f"{locale}/{rid}: FAIL")
            elif verdict["verdict"] == P.UNREADABLE:
                result["incomplete"].append(f"{locale}/{rid}: UNREADABLE")
    result["verdicts"] = recomputed
    result["mismatches"] = compare_verdicts(doc["verdicts"], recomputed)
    binary = doc["binary"]
    if binary.get("binding") != E.BOUND:
        result["incomplete"].append(f"binary: binding is {binary.get('binding')!r}; only a binary "
                                    f"the verifier built from the head can be clean")
    elif not (HEX40.match(str(binary.get("head"))) and HEX64.match(str(binary.get("sha256")))):
        result["incomplete"].append("binary: head or sha256 is not a full hex digest")
    if result["failures"] or result["mismatches"]:
        result["exit"] = EXIT_FAILED
    elif result["incomplete"]:
        result["exit"] = EXIT_INCOMPLETE
    else:
        result["exit"] = EXIT_CLEAN
    return result
