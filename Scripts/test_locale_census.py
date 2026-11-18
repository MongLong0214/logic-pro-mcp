#!/usr/bin/env python3
"""Prove the census tool and the regenerate path, against fixtures. Nothing here touches Logic.

    label-census.py       reads a running Logic (read-only) and files observation records that name the
                          Logic version and build; refuses a census that cannot, and one whose locale it
                          cannot prove
    locale-regenerate.py  feeds those records into the ledger as a diff; refuses a record with no
                          version/build or on another release; never overwrites a changed reading

Each refusal is shown with a MUTANT: the tool's own source with the line that refuses neutralised, run
through the same scenario, which must then go through. A replacement that does not match exactly once
fails the suite.
"""
import ast
import importlib.util
import json
import sys
import tempfile
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
OBS_TOOLS = HERE / "observations"
CENSUS_PY = OBS_TOOLS / "label-census.py"
REGEN_PY = OBS_TOOLS / "locale-regenerate.py"
RECORDS_PY = OBS_TOOLS / "locale_campaign_records.py"
PROBE = OBS_TOOLS / "locale-census.swift"


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def mutant(path, old, new, name):
    source = Path(path).read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise SystemExit(f"mutant {name}: {old[:60]!r} occurs {source.count(old)} time(s), not once")
    module = types.ModuleType(name)
    module.__file__ = str(path)
    sys.modules[name] = module
    exec(compile(source.replace(old, new), str(path), "exec"), module.__dict__)
    return module


census = load(CENSUS_PY, "label_census")
regen = load(REGEN_PY, "locale_regenerate")
records_mod = load(RECORDS_PY, "locale_campaign_records")
labels = census._labels()
ran, failures = [0], []


def case(name, condition, detail=""):
    ran[0] += 1
    if not condition:
        failures.append(f"{name}: {detail}")


DECLARED = {"app": "Logic Pro", "version": "98.7", "build": "65432"}


def census_doc(version="98.7", build="65432", locale="ko-KR", menu_bar=None, rows=None):
    host = {"app": "Logic Pro", "version": version, "build": build, "locale": locale,
            "os": "macOS 26.3 (25D125)"}
    return {"host": host, "menu_bar": menu_bar or ["Apple", "Logic Pro", "파일", "편집"],
            "census": rows if rows is not None else [
                {"surface": "arrange.menus", "path": "AXMenuBar/AXMenuBarItem[편집]", "role": "AXMenuBarItem",
                 "title": "편집", "description": None, "help": None, "value": None, "identifier": None}]}


def repo_with_swift():
    root = Path(tempfile.mkdtemp())
    swift = root / "Sources/LogicProMCP/Accessibility"
    swift.mkdir(parents=True)
    (swift / "AXLocalePolicy.swift").write_text(
        'enum AXLocalePolicy {\n    static let currentLogicVersion = "98.7"\n'
        '    static let currentLogicBuild = "65432"\n}\n', encoding="utf-8")
    (root / "docs/observations").mkdir(parents=True)
    return root


class UnconfirmedCanon:
    """A canon in which every string's 32-bit prefix matches and no string comparison is pinned."""
    SHIPS, ABSENT, UNCONFIRMED = "ships", "absent", "unconfirmed"

    @staticmethod
    def load_manifest():
        return {"sources": {"strings": {"locales": ["ko"]}}}

    @staticmethod
    def presence(_source, _locale, _text):
        return UnconfirmedCanon.UNCONFIRMED

    @staticmethod
    def differs_only_by_decoration(_source, _locale, _text):
        return False


#: Stands in for `Scripts/logic_canon.py` in a fixture repository: records what the printed confirm
#: command hands it, so the test runs that command without Logic and without touching docs/canon.
CONFIRM_STUB = (
    "import json, os, sys\n"
    "out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'confirmed.json')\n"
    "stdin = [line.rstrip('\\n') for line in sys.stdin if line.rstrip('\\n')] if '--stdin' in sys.argv else []\n"
    "json.dump({'argv': sys.argv[1:], 'stdin': stdin}, open(out, 'w', encoding='utf-8'), ensure_ascii=False)\n"
)


def refusal_problems(module):
    """Run the unconfirmed-string refusal through `module`; return what is wrong with it (empty: none).

    The defect this pins: the refusal told the runner to `confirm --stdin < strings.txt` and never
    wrote strings.txt, so a runner following the printed instruction could never get past it.
    """
    import contextlib
    import io
    import shlex
    import subprocess
    repo = repo_with_swift()
    (repo / "Scripts").mkdir()
    (repo / "Scripts/logic_canon.py").write_text(CONFIRM_STUB, encoding="utf-8")
    row = {"surface": "arrange.menus", "path": "AXMenuBar/AXMenuBarItem[편집]", "role": "AXMenuBarItem",
           "description": None, "help": None, "value": None, "identifier": None}
    unplaced = ["편집", "it's  two\tspaced ", "line one\nit's a \\ line two"]
    doc = census_doc(rows=[dict(row, title=t) for t in unplaced])
    path = repo / "census.json"
    path.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = module.main(str(path), str(repo), True, date="2026-11-17", canon=UnconfirmedCanon)
    text = out.getvalue()
    problems = []
    if rc != 2:
        problems.append(f"exit {rc}, not the refusal's 2: {text}")
    if list((repo / "docs/observations").glob("*.json")):
        problems.append("a refused census filed records")
    listed = repo / "docs/observations/evidence/2026-11-17-ko-KR-navigation-free.unconfirmed.txt"
    if not listed.exists():
        problems.append(f"the refusal wrote no strings file at {listed}")
        return problems
    commands = [line.strip() for line in text.splitlines() if line.strip().startswith("python3 ")]
    if len(commands) != 1:
        problems.append(f"the refusal prints {len(commands)} runnable command(s), not one: {text}")
        return problems
    if not commands[0].endswith("< " + shlex.quote(str(listed))):
        problems.append(f"the printed command does not read the strings file: {commands[0]}")
    ran_ = subprocess.run(commands[0], shell=True, cwd=tempfile.mkdtemp(), capture_output=True, text=True)
    if ran_.returncode != 0:
        problems.append(f"the printed command exits {ran_.returncode}: {ran_.stderr.strip()[:300]}")
        return problems
    got = json.loads((repo / "confirmed.json").read_text(encoding="utf-8"))
    handed = got["argv"][2:] + got["stdin"]
    if got["argv"][:2] != ["confirm", "--stdin"] or sorted(handed) != sorted(unplaced):
        problems.append(f"the printed command hands confirm {got}, not exactly the unplaced {unplaced}")
    return problems


def main():
    # ---- the census is READ-ONLY: no path to Logic but the probe, and the probe only reads ---------
    tree = ast.parse(CENSUS_PY.read_text(encoding="utf-8"))
    tree.body = [n for n in tree.body if not (isinstance(n, ast.Expr) and isinstance(n.value, ast.Constant))]
    literals = [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str)]
    forbidden = ("osascript", "System Events", "tell application", "defaults write", "AXPress", "open -a")

    def touches_logic(strings):
        return [s for s in strings if any(f.lower() in s.lower() for f in forbidden)]

    case("the census script has no osascript, System Events, defaults-write or press path",
         touches_logic(literals) == [], touches_logic(literals))
    case("MUTANT: the check does see an osascript call when one is added",
         touches_logic(literals + ["osascript -e 'tell application \"Logic Pro\" to quit'"]) != [])
    probe = PROBE.read_text(encoding="utf-8")
    writes = [w for w in ("AXUIElementPerformAction", "AXUIElementSetAttributeValue", "CGEventPost",
                          ".post(tap", "NSAppleScript", "Process()") if w in probe]
    case("the probe never presses, sets, posts an event or runs a process", writes == [], writes)

    # ---- what a read-only census can and cannot reach --------------------------------------------
    obs = Path(tempfile.mkdtemp())

    def record(rid, method):
        (obs / f"{rid}.json").write_text(json.dumps({"id": rid, "surface": "arrange.menus",
                                                      "method": method}), encoding="utf-8")

    record("2026-09-05-ko-KR-arrange-menus-census", "Read, never actuated. The menu bar was walked.")
    record("2026-09-15-setup-window", "The Setup window was opened through its menu and each route driven.")
    record("2026-09-16-quiet-reading", "Read the mixer's strip names from a saved snapshot.")
    doc = {"labels": {
        "SeenInCensus": {"provenance": {"x": {"record": "2026-09-05-ko-KR-arrange-menus-census"}}},
        "SeenAfterAnAction": {"coverage_records": {"ko-KR": "2026-09-15-setup-window"}},
        "SeenQuietly": {"coverage_records": {"ko-KR": "2026-09-16-quiet-reading"}},
        "savePanelWindowTitle": {},
        "arrangeWindowTitleSuffix": {},
        "outputPopupBusSubmenuTitle": {},
        "displayModePopupLabel": {},
        "sheetByRole": {"roles": ["AXSheet"]},
        "Gone": {"retired": {"reason": "Logic no longer ships it"}},
    }}
    got = census.reachability(doc, str(obs))
    klass = {n: v["class"] for n, v in got.items()}
    case("a label a navigation-free census sighted is read_only", klass["SeenInCensus"] == "read_only", klass)
    case("a label whose only record acted on Logic needs navigation, and says which record",
         klass["SeenAfterAnAction"] == "needs_navigation"
         and "2026-09-15-setup-window" in got["SeenAfterAnAction"]["reason"], got["SeenAfterAnAction"])
    case("a label whose record states no action stays a candidate for the census to decide",
         klass["SeenQuietly"] == "candidate", klass)
    case("a sheet/dialog/window title that nothing has sighted needs navigation, with the reason",
         klass["savePanelWindowTitle"] == "needs_navigation"
         and "write or a modal" in got["savePanelWindowTitle"]["reason"], got["savePanelWindowTitle"])
    case("a popup's inside needs it opened, but a popup button's own label is on the main window",
         (klass["outputPopupBusSubmenuTitle"], klass["displayModePopupLabel"])
         == ("needs_navigation", "candidate"), klass)
    case("the arrange window's own title is a main-window row, not a secondary window",
         klass["arrangeWindowTitleSuffix"] == "candidate", klass)
    case("a role that exists only inside something opened needs navigation",
         klass["sheetByRole"] == "needs_navigation", klass)
    case("a retired label is excused, with its reason", klass["Gone"] == "retired"
         and got["Gone"]["reason"] == "Logic no longer ships it")
    blind = mutant(CENSUS_PY, "hit = None if name.startswith(\"arrange\") else OPENED_BY_AN_ACTION.search(name)",
                   "hit = None", "label_census_mut_reach")
    case("MUTANT: without the name rule an unreachable label is offered to the census",
         blind.reachability(doc, str(obs))["savePanelWindowTitle"]["class"] == "candidate")

    real = labels.load_json()
    plan = census.plan(real, labels.OBS_DIR)
    names = [item["label"] for group in plan.values() for item in group]
    case("on the real ledger every label is in exactly one class",
         sorted(names) == sorted(real["labels"]) and len(names) == len(set(names)), len(names))
    case("and every label that needs navigation says why",
         all(item["reason"].strip() for item in plan["needs_navigation"]) and plan["needs_navigation"])

    # ---- filing: the record carries the Logic version and build, or nothing is filed --------------
    repo = repo_with_swift()
    rc = census.ingest("ko-KR", census_doc(), str(repo), True, date="2026-11-17", labels_mod=labels,
                       records_mod=records_mod)
    filed = sorted((repo / "docs/observations").glob("2026-11-17-ko-KR-*-census.json"))
    case("a census on a named release files records", rc == 0 and filed, (rc, filed))
    if filed:
        rec = json.loads(filed[0].read_text(encoding="utf-8"))
        case("each record names the Logic version and build the probe read",
             (rec["host"]["version"], rec["host"]["build"], rec["host"]["locale"]) == ("98.7", "65432", "ko-KR"),
             rec["host"])
        schema = load(HERE / "check-observation-records.py", "records_schema_under_test")
        schema.DIR = str(repo / "docs/observations")
        schema.SURFACES_DOC = str(HERE.parent / "docs/observations/SURFACES.md")
        problems = schema.check(str(filed[0]))
        case("and is in the existing observation-record format (the schema guard finds only the "
             "fixture's absent dependency files)",
             all("depends names" in p or "supersedes" in p or "does not exist" in p for p in problems),
             problems)
        case("and its evidence is the census it was filed from",
             rec["evidence"] and (repo / "docs/observations" / rec["evidence"][0]).exists(), rec["evidence"])
    for version, build in (("?", "65432"), ("98.7", "?"), ("", "65432"), (None, None)):
        empty = repo_with_swift()
        rc = census.ingest("ko-KR", census_doc(version=version, build=build), str(empty), True,
                           date="2026-11-17", labels_mod=labels, records_mod=records_mod)
        case(f"a census that cannot name its Logic ({version!r}, {build!r}) is refused and files nothing",
             rc == 2 and not list((empty / "docs/observations").glob("*.json")), rc)
    nogate = mutant(RECORDS_PY, "    why = missing_release(host)\n    if why:", "    why = None\n    if why:",
                    "locale_campaign_records_mut_gate")
    nogate_census = mutant(CENSUS_PY, "    why = records_mod.missing_release(host)\n    if why:",
                           "    why = None\n    if why:", "label_census_mut_gate")
    empty = repo_with_swift()
    rc = nogate_census.ingest("ko-KR", census_doc(version="?", build="?"), str(empty), True,
                              date="2026-11-17", labels_mod=labels, records_mod=nogate)
    case("MUTANT: without the version gate a census of an unknown Logic is filed",
         rc == 0 and list((empty / "docs/observations").glob("*.json")), rc)

    # the locale is proved, not assumed
    bar = {"es-ES": ["Apple", "Logic Pro", "Archivo", "Edición", "Pista", "Navegar", "Grabar", "Mezcla",
                     "Ver", "Ventana", "Ayuda"]}
    unknown = census_doc(locale="unknown", menu_bar=bar["es-ES"])
    ok, why = census.resolve_locale(unknown, "es-ES", labels)
    case("a Spanish menu bar proves es-ES when the probe cannot name it", ok == "es-ES", why)
    refused, why = census.resolve_locale(unknown, "pt-BR", labels)
    case("and does not prove pt-BR, whose corpus shares only some titles", refused is None, why)
    weak, why = census.resolve_locale(census_doc(locale="unknown", menu_bar=["Edit"]), "en-US", labels)
    case("a bar that matches too few titles proves nothing", weak is None, why)
    wrong, why = census.resolve_locale(census_doc(locale="ja-JP"), "ko-KR", labels)
    case("a Logic the probe reads as ja-JP is not accepted as ko-KR", wrong is None, why)
    loose = mutant(CENSUS_PY, "if leaders != [requested] or best < 3:", "if False:", "label_census_mut_locale")
    case("MUTANT: without the uniqueness rule a Portuguese request is accepted for a Spanish bar",
         loose.resolve_locale(unknown, "pt-BR", labels)[0] == "pt-BR")

    # ---- a census the committed canon cannot place leaves a runnable confirm behind ---------------
    problems = refusal_problems(records_mod)
    case("a refused census writes the unplaced strings and prints a confirm command that runs and "
         "hands confirm exactly those strings", problems == [], problems)
    for n, (name, old, new) in enumerate((
            ("no strings file (the defect)",
             "        path, command = write_unconfirmed(repo, date, locale, [t for _rid, texts in refused for t in texts])",
             "        path, command = unconfirmed_path(repo, date, locale), "
             "\"python3 Scripts/logic_canon.py confirm --stdin < strings.txt\""),
            ("an empty strings file",
             "        handle.writelines(f\"{t}\\n\" for t in one_line)",
             "        pass"),
    )):
        broken = mutant(RECORDS_PY, old, new, f"locale_campaign_records_mut_unconfirmed_{n}")
        case(f"MUTANT: with {name} the refusal test goes red", refusal_problems(broken) != [], name)

    # ---- the regenerate path ----------------------------------------------------------------------
    obs2 = Path(tempfile.mkdtemp())
    (obs2 / "evidence").mkdir()

    def rec(rid, host, evidence=True):
        d = {"id": rid, "host": host}
        if evidence:
            d["evidence"] = ["evidence/e.json"]
        (obs2 / f"{rid}.json").write_text(json.dumps(d), encoding="utf-8")

    rec("good", {"locale": "ko-KR", "version": "98.7", "build": "65432"})
    rec("old", {"locale": "ko-KR", "version": "12.3", "build": "6674"})
    rec("nover", {"locale": "ko-KR", "build": "65432"})
    rec("qmark", {"locale": "ko-KR", "version": "?", "build": "?"})
    rec("unbound", {"binding": "unknown", "reason": "history"})
    rec("other", {"locale": "ja-JP", "version": "98.7", "build": "65432"})
    rec("noev", {"locale": "ko-KR", "version": "98.7", "build": "65432"}, evidence=False)
    gate = lambda module, rid: module.gate_record(rid, "ko-KR", DECLARED, str(obs2))
    case("a record on the declared release is accepted", gate(regen, "good")[1] is None)
    for rid, what in (("old", "another release"), ("nover", "no version"), ("qmark", "an unreadable version"),
                      ("unbound", "an explicit unknown binding"), ("other", "another locale"),
                      ("noev", "no evidence census"), ("missing", "no file")):
        record, why = gate(regen, rid)
        case(f"a record with {what} is refused", record is None and why, why)
    for old, name in (('if str(host.get(axis) or "").strip() in ("", "?", "unknown"):', "version"),
                      ('if (host["version"], host["build"]) != (declared["version"], declared["build"]):',
                       "release")):
        weak_gate = mutant(REGEN_PY, old, "if False:", f"locale_regenerate_mut_{name}")
        bad = {"version": "nover", "release": "old"}[name]
        try:
            verdict = weak_gate.gate_record(bad, "ko-KR", DECLARED, str(obs2))[1]
        except KeyError:
            verdict = None          # the rule that named the missing axis is the only thing that did
        case(f"MUTANT: without the {name} check, {bad!r} is not refused for it",
             verdict is None or f"no Logic {name}" not in verdict, verdict)
    case("discovery offers only the records on the declared release",
         regen.discover("ko-KR", DECLARED, str(obs2)) == [], regen.discover("ko-KR", DECLARED, str(obs2)))
    (obs2 / "2026-11-17-ko-KR-arrange-menus-census.json").write_text(json.dumps({
        "id": "x", "host": {"locale": "ko-KR", "version": "98.7", "build": "65432"},
        "evidence": ["evidence/e.json"]}), encoding="utf-8")
    (obs2 / "2026-09-05-ko-KR-arrange-menus-census.json").write_text(json.dumps({
        "id": "y", "host": {"locale": "ko-KR", "version": "12.3", "build": "6674"},
        "evidence": ["evidence/e.json"]}), encoding="utf-8")
    case("discovery skips a census taken on another release",
         regen.discover("ko-KR", DECLARED, str(obs2)) == ["2026-11-17-ko-KR-arrange-menus-census"],
         regen.discover("ko-KR", DECLARED, str(obs2)))

    # a label that changed shows as a diff, and is not written without being named
    old_block = {"locale": "ko-KR", "observed": "열기", "logic_version": "12.3", "logic_build": "6674",
                 "record": "r"}
    gone_block = dict(old_block, observed="없어짐")
    labs = {
        "Same": {"canonical": "Open", "variants": ["열기"], "match": "exact",
                 "provenance": {"열기": old_block}, "coverage": {"ko-KR": "measured"}},
        "Moved": {"canonical": "Save", "variants": ["저장"], "match": "exact",
                  "provenance": {"저장": dict(old_block, observed="저장")}, "coverage": {"ko-KR": "measured"}},
        "Dropped": {"canonical": "Gone", "variants": ["없어짐"], "match": "exact",
                    "provenance": {"없어짐": gone_block}, "coverage": {"ko-KR": "measured"}},
        "First": {"canonical": "Close", "variants": ["닫기"], "match": "exact", "coverage": {"ko-KR": "derived"}},
        "Already": {"canonical": "Undo", "variants": ["실행 취소"], "match": "exact",
                    "provenance": {"실행 취소": dict(old_block, observed="실행 취소", logic_version="98.7",
                                                  logic_build="65432")}, "coverage": {"ko-KR": "measured"}},
        "Tmpl": {"canonical": "Undo %@", "variants": ["%@ 실행 취소"], "match": "template",
                 "coverage": {"ko-KR": "derived"}},
    }
    hits = {"Same": [{"string": "열기", "observed": "열기"}],
            "Moved": [{"string": "저장", "observed": "저장…"}],
            "First": [{"string": "닫기", "observed": "닫기"}],
            "Already": [{"string": "실행 취소", "observed": "실행 취소"}],
            "Tmpl": [{"string": "%@ 실행 취소", "observed": "무제 실행 취소"}]}
    result = regen.plan_changes(labs, "ko-KR", hits, DECLARED)
    got_ = {k: sorted(i["label"] for i in v) for k, v in result.items()}
    case("an unchanged reading is CONFIRMED, moved to the new record", got_["confirmed"] == ["Same"], got_)
    case("a reading whose quoted text changed is CHANGED, with both texts",
         got_["changed"] == ["Moved"] and result["changed"][0]["was"] == "저장"
         and result["changed"][0]["now"] == "저장…", result["changed"])
    case("a variant read before and not found now is UNCONFIRMED, never overwritten or dropped",
         got_["unconfirmed"] == ["Dropped"], got_)
    case("a first reading is NEW", got_["new"] == ["First"], got_)
    case("a reading already on the declared release is left alone", got_["already_current"] == ["Already"])
    case("a template reading is reported and never written", got_["template"] == ["Tmpl"], got_)
    todo, held = regen.writable(hits, result, accept_changed=[])
    case("the CHANGED reading is held back and the rest is written",
         "Moved" not in todo and "Same" in todo and "First" in todo and "Tmpl" not in todo
         and [h["label"] for h in held] == ["Moved"], (sorted(todo), held))
    todo, held = regen.writable(hits, result, accept_changed=["Moved"])
    case("naming the label takes it", "Moved" in todo and held == [])
    permissive = mutant(REGEN_PY, 'held_back = [i for i in plan["changed"] if i["label"] not in set(accept_changed)]',
                        "held_back = []", "locale_regenerate_mut_held")
    todo_m, _ = permissive.writable(hits, result, accept_changed=[])
    case("MUTANT: without the hold-back a changed label is silently overwritten", "Moved" in todo_m)
    diff = regen.render_diff(result, {"First": {"base": "Close", "target": "닫기", "scoped": True}},
                             "ko-KR", DECLARED)
    case("the diff shows old and new text and the aligned candidate",
         "- '저장'" in diff and "+ '저장…'" in diff and "? Dropped" in diff and "+ First" in diff, diff)

    # Swift: only an accepted variant is appended, in the file's own layout
    swift_text = ('enum AXLocalePolicy {\n    static let openItem = LabelSet(\n        canonical: "Open",\n'
                  '        variants: [\n            "열기",\n            "開く"\n        ],\n'
                  '        rationale: "r"\n    )\n    static let one = LabelSet(canonical: "A", '
                  'variants: ["a"], rationale: "r")\n}\n')
    out = regen.add_variant(swift_text, "openItem", 'Öffnen "x"')
    tmp = Path(tempfile.mkdtemp()) / "AXLocalePolicy.swift"
    tmp.write_text(out, encoding="utf-8")
    parsed = labels.from_swift(str(tmp))
    case("the accepted variant is appended and the policy still parses",
         parsed["openItem"]["variants"] == ["열기", "開く", 'Öffnen "x"'] and parsed["one"]["variants"] == ["a"],
         parsed["openItem"]["variants"])
    inline = regen.add_variant(swift_text, "one", "b")
    tmp.write_text(inline, encoding="utf-8")
    case("an inline variants array is extended in place", labels.from_swift(str(tmp))["one"]["variants"] == ["a", "b"])
    for label, variant in (("openItem", "열기"), ("nothing", "x")):
        try:
            regen.add_variant(swift_text, label, variant)
            refused_ = False
        except ValueError:
            refused_ = True
        case(f"add_variant refuses {label!r}/{variant!r}", refused_)

    if failures:
        for line in failures:
            print(f"FAIL {line}")
        return 1
    print(f"{ran[0]} case(s) pass: the census names its Logic or files nothing, and a changed label is "
          f"a diff, not an overwrite")
    return 0


if __name__ == "__main__":
    sys.exit(main())
