#!/usr/bin/env python3
"""Prove the ledger's version axis can fail, and that each rule is the thing failing.

`docs/locale/ui-labels.json` used to record WHAT was read and WHERE and never WHICH LOGIC, so a Logic
update left every reading standing as `measured`. The rules that close it are guards, and a guard that
nobody has seen fail is an assertion. Each section below states one rule, shows it catching the
violation, and then runs the SAME scenario against a MUTANT -- the guard's own source with exactly the
line that enforces the rule neutralised -- and requires the scenario to go undetected. A mutant that is
still caught means the test is not testing the rule; a replacement that does not match exactly once
fails the suite, so a refactor cannot leave a mutant that silently changed nothing.

    1. generated only      a single hand-edited byte of the projection is red
    2. declared once       the Swift constant is the only statement of the current Logic, and moving it
                           reclassifies every older reading
    3. bound to records    a measured cell names a record that exists, whose locale, version, build and
                           string match, bound by a digest; missing / edited / unreadable fails closed
    5. derived is named    a derived cell names its corpus, locale, rule and string and is never measured
    6. census gate         (in test_locale_census.py: records without a version, or on another release,
                           are refused)
    (4, the per-locale ratchet, is in test_observation_ratchets.py.)
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
LABELS_PY = HERE / "locale_labels.py"
RELEASE_PY = HERE / "locale_release.py"


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def mutant(path, old, new, name):
    """The module at `path` with `old` replaced by `new` exactly once, loaded under `name`."""
    source = Path(path).read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise SystemExit(f"mutant for {name}: {old[:60]!r} occurs {source.count(old)} time(s), not once")
    module = types.ModuleType(name)
    module.__file__ = str(path)
    sys.modules[name] = module
    exec(compile(source.replace(old, new), str(path), "exec"), module.__dict__)
    return module


labels = load(LABELS_PY, "locale_labels_under_test")
#: The release the repository really declares, read rather than typed: this file may not restate it
#: (`restatement_problems` would refuse it), and a fixture that names the real one would go stale on the
#: next Logic. Cases about MOVING the declaration use a fake release.
REAL = labels.current_logic()
ran = [0]
failures = []


def case(name, condition, detail=""):
    ran[0] += 1
    if not condition:
        failures.append(f"{name}: {detail}")


# --------------------------------------------------------------------------------------------------
# A throwaway observations directory: three records on three releases, one with evidence.
# --------------------------------------------------------------------------------------------------
STRING = "입력 슬롯. 채널 스트립 입력 소스"


def fixture():
    root = Path(tempfile.mkdtemp())
    (root / "evidence").mkdir()
    rows = {"census": [{"role": "AXButton", "title": None, "description": None, "help": STRING,
                        "value": None, "identifier": None, "path": "AXWindow/AXButton"}]}
    (root / "evidence" / "c.json").write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")

    def record(rid, host):
        doc = {"id": rid, "date": "2026-11-01", "surface": "mixer.channel_strips", "host": host,
               "evidence": ["evidence/c.json"], "observations": [{"what": "x"}]}
        (root / f"{rid}.json").write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")

    record("2026-11-01-ko-KR-old", {"locale": "ko-KR", "version": "12.3", "build": "6674"})
    record("2026-11-02-ko-KR-new", {"locale": "ko-KR", "version": REAL["version"], "build": REAL["build"]})
    record("2026-11-03-ko-KR-unversioned", {"locale": "ko-KR", "binding": "unknown",
                                            "reason": "history", "version": None, "build": None})
    return root


def cell(root, rid, locale="ko-KR", observed=STRING, **override):
    """A label entry whose ko-KR cell rests on `rid`, bound the way the generator binds it."""
    facts = labels.record_facts(rid, str(root))
    block = {"locale": locale, "date": "2026-11-01", "observed": observed, "record": rid,
             "role": "AXButton", "attribute": "help", "match": "contains",
             "logic_version": facts["version"], "logic_build": facts["build"],
             "record_sha256": facts["sha256"]}
    block.update(override)
    cov = {loc: "unmeasured" for loc in ("en-US", "ko-KR")}
    cov["ko-KR"] = "measured"
    return {"canonical": "input slot", "variants": [STRING], "rationale": "r", "match": "contains",
            "roles": ["AXButton"], "provenance": {STRING: block}, "coverage": cov}


def cls(entry, root, current, mod=None):
    return (mod or labels).classify_cell(entry, "ko-KR", current, str(root))


CURRENT_12 = {"app": "Logic Pro", "version": "12.3", "build": "6674"}
CURRENT_13 = dict(REAL)


def main():
    root = fixture()
    old, new, unversioned = "2026-11-01-ko-KR-old", "2026-11-02-ko-KR-new", "2026-11-03-ko-KR-unversioned"

    # ---- the version axis itself ---------------------------------------------------------------
    case("a reading on the declared release is current", cls(cell(root, new), root, CURRENT_13) == "current")
    case("a reading on an older release is superseded, not measured-on-current",
         cls(cell(root, old), root, CURRENT_13) == "superseded")
    case("a record that states no version is `unknown_version`, never guessed",
         cls(cell(root, unversioned), root, CURRENT_13) == "unknown_version",
         cls(cell(root, unversioned), root, CURRENT_13))
    case("the record's own host is where the version comes from",
         labels.record_facts(old, str(root))["version"] == "12.3"
         and labels.record_facts(unversioned, str(root))["version"] == "unknown")

    # ---- 2. DECLARED ONCE: moving the constant reclassifies every older reading -----------------
    swift = Path(tempfile.mkdtemp()) / "AXLocalePolicy.swift"

    def declare(version, build):
        swift.write_text(f'enum AXLocalePolicy {{\n    static let currentLogicVersion = "{version}"\n'
                         f'    static let currentLogicBuild = "{build}"\n}}\n', encoding="utf-8")
        return labels.declared_logic(str(swift))

    before = cls(cell(root, old), root, declare("12.3", "6674"))
    after = cls(cell(root, old), root, declare("98.7", "65432"))
    case("bumping the constant turns a current reading into a superseded one",
         (before, after) == ("current", "superseded"), (before, after))
    mutated = mutant(LABELS_PY, 'elif (version, build) == (current["version"], current["build"]):',
                     "elif True:", "locale_labels_mut_bump")
    case("MUTANT: a classifier that ignores the declared release leaves the old reading current",
         cls(cell(root, old), root, declare("98.7", "65432"), mutated) == "current")

    # one declaration, or none
    swift.write_text('static let currentLogicVersion = "1"\nstatic let currentLogicBuild = "2"\n'
                     'static let currentLogicVersion = "3"\n', encoding="utf-8")
    try:
        labels.declared_logic(str(swift))
        two = False
    except ValueError:
        two = True
    case("two declarations of the current Logic are refused", two)
    release_mut = mutant(RELEASE_PY, "len(versions) != 1 or len(builds) != 1 or",
                         "len(versions) < 1 or len(builds) < 1 or", "locale_release_mut")
    try:
        release_mut.declared_logic(str(swift))
        two_mutant = False
    except ValueError:
        two_mutant = True
    case("MUTANT: without the exactly-once rule a second declaration passes", not two_mutant)

    # no other file may restate it
    repo = Path(tempfile.mkdtemp())
    (repo / "Sources/LogicProMCP/Accessibility").mkdir(parents=True)
    (repo / "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift").write_text(
        'enum AXLocalePolicy {\n    static let currentLogicVersion = "98.7"\n'
        '    static let currentLogicBuild = "65432"\n}\n', encoding="utf-8")
    (repo / "Scripts").mkdir()
    (repo / "docs/observations").mkdir(parents=True)
    clean = labels.restatement_problems(str(repo))
    case("a tree that declares once is clean", clean == [], clean)
    for where, text, what in (
            ("Scripts/x.py", 'LOGIC_BUILD = "65432"\n', "a build constant"),
            ("Scripts/y.py", 'EXPECTED = {"logic_version": "98.7"}\n', "a version key"),
            ("docs/about.md", "Logic Pro 98.7 is the current target.\n", "a sentence calling it current"),
            ("docs/observations/LOGIC-BUILD.json", "{}\n", "the retired JSON declaration")):
        target = repo / where
        target.write_text(text, encoding="utf-8")
        found = labels.restatement_problems(str(repo))
        case(f"a restatement is refused: {what}", len(found) == 1 and where.split("/")[-1] in found[0],
             found)
        restated_bare = mutant(LABELS_PY, "hit = pattern.search(text)", "hit = None",
                               "locale_labels_mut_restate")
        mutated_found = restated_bare.restatement_problems(str(repo))
        if where.endswith("LOGIC-BUILD.json"):
            mutated_found = mutant(LABELS_PY, 'if os.path.exists(os.path.join(repo, "docs", "observations", "LOGIC-BUILD.json")):',
                                   "if False:", "locale_labels_mut_legacy").restatement_problems(str(repo))
        case(f"MUTANT: without the restatement scan, {what} goes unnoticed", mutated_found == [],
             mutated_found)
        target.unlink()
    (repo / "Tests").mkdir()
    (repo / "Tests/F.swift").write_text('let fixture = Doc(logicVersion: "98.7")\n', encoding="utf-8")
    case("a test fixture choosing a version string is not a declaration",
         labels.restatement_problems(str(repo)) == [])

    # ---- 3. BOUND TO A RECORD THAT EXISTS, by digest; fail closed -------------------------------
    good = cell(root, new)
    case("a cell bound to its record verifies",
         labels.binding_problems(new, "ko-KR", good["provenance"][STRING]["record_sha256"],
                                 REAL["version"], REAL["build"], str(root), STRING) == [])
    sha = good["provenance"][STRING]["record_sha256"]

    def problems(rid=new, locale="ko-KR", sha_=sha, version=REAL["version"], build=REAL["build"], observed=STRING,
                 mod=None):
        return (mod or labels).binding_problems(rid, locale, sha_, version, build, str(root), observed)

    case("a wrong locale is refused", problems(locale="ja-JP") != [])
    case("a wrong version is refused", problems(version="12.3") != [])
    case("a wrong build is refused", problems(build="1") != [])
    case("a string the record never carried is refused", problems(observed="입력 아님") != [])
    case("a cell with no digest is refused", problems(sha_=None) != [])

    digest_mut = mutant(LABELS_PY, 'elif sha != facts["sha256"]:', "elif False:", "locale_labels_mut_digest")
    version_mut = mutant(LABELS_PY, "if (version, build) != (facts[\"version\"], facts[\"build\"]):",
                         "if False:", "locale_labels_mut_version")
    string_mut = mutant(LABELS_PY, "if observed is not None and observed not in (record_strings(record_id, obs_dir) or ()):",
                        "if False:", "locale_labels_mut_string")
    missing_mut = mutant(LABELS_PY, "return [f\"record {record_id!r} is {facts['status']}\"]", "return []",
                         "locale_labels_mut_missing")
    locale_mut = mutant(LABELS_PY, 'if facts["locale"] != locale:', "if False:", "locale_labels_mut_locale")
    case("MUTANT: without the version comparison a wrong version passes",
         problems(version="12.3", mod=version_mut) == [])
    case("MUTANT: without the exact-string check an unread string passes",
         problems(observed="입력 아님", mod=string_mut) == [])
    case("MUTANT: without the locale comparison a wrong locale passes",
         problems(locale="ja-JP", mod=locale_mut) == [])

    # editing the evidence, editing the record, deleting the record, breaking the evidence
    evidence = root / "evidence" / "c.json"
    original = evidence.read_bytes()
    evidence.write_bytes(original.replace(b"AXButton/", b"AXButtoN/", 1) if b"AXButton/" in original
                         else original + b" ")
    case("editing ONE byte of the evidence turns the cell red", problems() != [], problems())
    case("MUTANT: without the digest comparison an edited evidence file passes",
         problems(mod=digest_mut) == [])
    evidence.write_bytes(original)
    case("restoring the byte turns it green again", problems() == [], problems())

    record_file = root / f"{new}.json"
    original_record = record_file.read_bytes()
    record_file.write_bytes(original_record.replace(b"2026-11-01", b"2026-11-09", 1))
    case("editing the record turns the cell red", problems() != [], problems())
    case("MUTANT: without the digest comparison an edited record passes", problems(mod=digest_mut) == [])
    record_file.write_bytes(original_record)

    record_file.unlink()
    case("deleting the record turns the cell red", problems() != [], problems())
    case("a cell whose record is missing never reads as measured",
         cls(good, root, CURRENT_13) == "unverified", cls(good, root, CURRENT_13))
    case("MUTANT: without the missing-record rule a deleted record still reads as current",
         cls(good, root, CURRENT_13, missing_mut) == "current")
    record_file.write_bytes(original_record)

    evidence.unlink()
    case("a record whose evidence file is gone is unreadable, and unreadable fails closed",
         labels.record_facts(new, str(root))["status"] == "unreadable"
         and cls(good, root, CURRENT_13) == "unverified", labels.record_facts(new, str(root)))
    evidence.write_bytes(original)
    garbled = root / f"{new}.json"
    garbled.write_text("{not json", encoding="utf-8")
    case("a record that does not parse is unreadable, not absent",
         labels.record_facts(new, str(root))["status"] == "unreadable")
    garbled.write_bytes(original_record)
    case("MUTANT: the missing/unreadable rule is the one that fails it closed",
         missing_mut.binding_problems("2026-11-99-gone", "ko-KR", "x", "1", "1", str(root)) == [])

    # build(): a claim whose record is gone does not come out `measured`, and `--write` is refused
    saved_obs_dir = labels.OBS_DIR
    labels.OBS_DIR = str(root)
    # the label must exist in the Swift; `inputSlotHelpKeyword` does and carries STRING as a variant
    swift_variants = labels.from_swift().get("inputSlotHelpKeyword", {}).get("variants", [])
    if STRING in swift_variants or "입력 슬롯" in swift_variants:
        key = STRING if STRING in swift_variants else "입력 슬롯"
        block = dict(cell(root, new)["provenance"][STRING], observed=STRING)
        base = {"schema": 3, "labels": {"inputSlotHelpKeyword": {"provenance": {key: block}}}}
        ok_unbound = []
        built = labels.build(existing=base, unbound=ok_unbound)
        entry = built["labels"]["inputSlotHelpKeyword"]
        case("a bound block makes its locale measured, on the declared release",
             entry["coverage"]["ko-KR"] == "measured" and entry.get("coverage_currency", {}).get("ko-KR")
             == "current" and not ok_unbound, (entry["coverage"]["ko-KR"], ok_unbound))
        (root / f"{new}.json").unlink()
        gone_unbound = []
        gone = labels.build(existing=base, unbound=gone_unbound)["labels"]["inputSlotHelpKeyword"]
        case("a bound block whose record was deleted is NOT measured and is reported",
             gone["coverage"]["ko-KR"] != "measured" and gone_unbound, (gone["coverage"]["ko-KR"], gone_unbound))
        weak = mutant(LABELS_PY, "        present_in = verified_locales\n",
                      '        present_in = {str((b or {}).get("locale")) for b in provenance.values()}\n',
                      "locale_labels_mut_present")
        weak.OBS_DIR = str(root)
        weak_cov = weak.build(existing=base, unbound=[])["labels"]["inputSlotHelpKeyword"]["coverage"]["ko-KR"]
        case("MUTANT: counting every block as present makes a deleted record read as measured",
             weak_cov == "measured", weak_cov)
        (root / f"{new}.json").write_bytes(original_record)

        # migration: a schema-2 document is bound by one run, from the record's own host
        old_block = {k: v for k, v in cell(root, old)["provenance"][STRING].items()
                     if k not in ("logic_version", "logic_build", "record_sha256")}
        migrated = labels.build(existing={"schema": 2, "labels": {"inputSlotHelpKeyword": {
            "provenance": {key: old_block}}}}, unbound=[])
        b = migrated["labels"]["inputSlotHelpKeyword"]["provenance"][key]
        case("schema 2 migrates: the version and build come from the record, and it is bound",
             migrated["schema"] == 3 and (b["logic_version"], b["logic_build"]) == ("12.3", "6674")
             and len(b["record_sha256"]) == 64, b)
        case("and the migrated reading is counted as superseded on the declared release",
             migrated["labels"]["inputSlotHelpKeyword"]["coverage_currency"]["ko-KR"] == "superseded")
        forged = dict(block, logic_version="99.0")
        forged_built = labels.build(existing={"schema": 3, "labels": {"inputSlotHelpKeyword": {
            "provenance": {key: forged}}}}, unbound=[])["labels"]["inputSlotHelpKeyword"]
        case("a hand-edited `logic_version` is re-derived from the record, so it cannot fake currency",
             forged_built["provenance"][key]["logic_version"] == REAL["version"]
             and labels.render({"x": forged_built}) != labels.render(
                 {"x": {"provenance": {key: forged}}}), forged_built["provenance"][key])
        # a NEW measured provenance with no digest in a schema-3 document is unbound, not bound by luck
        nodigest = {k: v for k, v in block.items() if k != "record_sha256"}
        nd_unbound = []
        nd = labels.build(existing={"schema": 3, "labels": {"inputSlotHelpKeyword": {
            "provenance": {key: nodigest}}}}, unbound=nd_unbound)["labels"]["inputSlotHelpKeyword"]
        case("a new measured block with no digest is refused, and does not read as measured",
             nd_unbound and nd["coverage"]["ko-KR"] != "measured", (nd_unbound, nd["coverage"]["ko-KR"]))
        # a block whose record states no version is `unknown`, and is not silently the current one
        unk = {k: v for k, v in cell(root, unversioned)["provenance"][STRING].items()
               if k not in ("record_sha256",)}
        um = labels.build(existing={"schema": 2, "labels": {"inputSlotHelpKeyword": {
            "provenance": {key: unk}}}}, unbound=[])["labels"]["inputSlotHelpKeyword"]
        case("a record without a version yields `unknown`, counted as not measured on the current one",
             um["provenance"][key]["logic_version"] == "unknown"
             and um["coverage_currency"]["ko-KR"] == "unknown_version", um.get("coverage_currency"))
    else:
        case("fixture label exists in the Swift", False, "inputSlotHelpKeyword has no variant to bind")
    labels.OBS_DIR = saved_obs_dir

    # ---- 5. DERIVED names its source and is never measured --------------------------------------
    derived = {"canonical": "x", "variants": ["y"], "rationale": "r", "match": "exact",
               "coverage": {"ko-KR": "derived"},
               "coverage_derived": {"ko-KR": "quickhelp:ko:ships_up_to_case:y"}}
    nameless = {k: v for k, v in derived.items() if k != "coverage_derived"}
    badrule = dict(derived, coverage_derived={"ko-KR": "quickhelp:ko:guessed:y"})
    case("a derived cell that names its corpus, locale, rule and string is clean",
         labels.derived_problems("x", derived) == [])
    case("a derived cell that names nothing is refused", labels.derived_problems("x", nameless) != [])
    case("a derived cell that names a rule nobody defined is refused",
         labels.derived_problems("x", badrule) != [])
    case("a derivation attached to a measured cell is refused",
         labels.derived_problems("x", dict(derived, coverage={"ko-KR": "measured"})) != [])
    d_mut = mutant(LABELS_PY, 'if len(parts) != 4 or not all(parts) or parts[2] not in DERIVED_RULES:',
                   "if False:", "locale_labels_mut_derived")
    case("MUTANT: without the naming rule a nameless derived cell passes",
         d_mut.derived_problems("x", nameless) == [] and d_mut.derived_problems("x", badrule) == [])
    case("a derived cell is never counted as measured on the current release",
         cls(derived, root, CURRENT_13) == "derived")
    count_mut = mutant(LABELS_PY, 'if state in ("retired", "derived", "unmeasured"):\n        return state',
                       'if state in ("retired", "unmeasured"):\n        return state\n'
                       '    if state == "derived":\n        return "current"', "locale_labels_mut_count")
    case("MUTANT: counting derived as measured is what the class check catches",
         cls(derived, root, CURRENT_13, count_mut) == "current")
    summary = labels.currency_summary({"a": derived}, ("ko-KR",), CURRENT_13, str(root))["ko-KR"]
    case("and the summary counts it as not measured on the current release",
         summary["not_measured_on_current"] == 1 and summary["current"] == 0, summary)

    # ---- 1. GENERATED ONLY: one hand-edited byte is red -----------------------------------------
    doc = labels.build(unbound=[])
    tmp = Path(tempfile.mkdtemp())
    for name, render in (("labels.json", labels.render(doc)),
                         ("labels.py", labels.render_python(doc)),
                         ("values.swift", labels.render_swift(doc))):
        (tmp / name).write_text(render, encoding="utf-8")
    paths = dict(json_path=str(tmp / "labels.json"), py_path=str(tmp / "labels.py"),
                 swift_path=str(tmp / "values.swift"))
    case("freshly generated artifacts are not stale", labels.stale_artifacts(doc, **paths) == [])
    # A byte in the PROSE `note`, which no label comparison sees -- the hole the old check had.
    text = (tmp / "labels.json").read_text(encoding="utf-8")
    needle = "unmeasured` is the only value that is a gap"
    assert needle in text
    (tmp / "labels.json").write_text(text.replace(needle, needle.replace("only", "onlY"), 1),
                                     encoding="utf-8")
    case("ONE hand-edited byte of the projection is stale", len(labels.stale_artifacts(doc, **paths)) == 1,
         labels.stale_artifacts(doc, **paths))
    labels_only = mutant(LABELS_PY, "        if on_disk != rendered:\n            stale.append",
                         "        if False:\n            stale.append", "locale_labels_mut_bytes")
    case("MUTANT: without the byte comparison the same edit goes unseen",
         labels_only.stale_artifacts(doc, **paths) == [])
    (tmp / "labels.json").write_text(text.rstrip("\n"), encoding="utf-8")
    case("a missing trailing newline is stale too", len(labels.stale_artifacts(doc, **paths)) == 1)
    (tmp / "labels.json").write_text(text, encoding="utf-8")

    # the repository itself, end to end: generated, bound, declared once
    import subprocess
    proc = subprocess.run([sys.executable, str(LABELS_PY), "--check"], capture_output=True, text=True)
    case("the repository's ledger passes its own --check", proc.returncode == 0,
         (proc.stdout + proc.stderr)[-300:])

    shutil.rmtree(root, ignore_errors=True)
    if failures:
        for line in failures:
            print(f"FAIL {line}")
        return 1
    print(f"{ran[0]} case(s) pass: each version-axis rule fails on its violation and is blind without "
          f"its guard")
    return 0


if __name__ == "__main__":
    sys.exit(main())
