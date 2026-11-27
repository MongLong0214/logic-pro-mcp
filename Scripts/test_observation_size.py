#!/usr/bin/env python3
"""The compact census formats, the digest that binds their bytes, and the size ratchet, each with a mutant.

    compact_json      a leaf is one line, the text parses back to the same document, the output is stable
    census_evidence   one row per line, a truncated file is refused, a legacy `.json` still reads
    canon_groups      grouped citations expand to exactly the flat citations they replace
    record_sha256     binds the BYTES of the evidence: change one row and the reading stops verifying
    check-observation-size.py
                      refuses a pretty-printed evidence file, a second evidence file for one locale and
                      build, a record that is not compact, and a locale that adds more than its budget

Every guard is shown with a MUTANT -- the source with the line that enforces it neutralised -- run through
the same scenario, which must then go wrong. A replacement that does not match exactly once fails the suite.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ran, failures = [0], []


def case(name, condition, detail=""):
    ran[0] += 1
    if not condition:
        failures.append(f"{name}: {detail}")


def load(path, name, source=None):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    if source is None:
        spec.loader.exec_module(module)
    else:
        module.__file__ = str(path)
        exec(compile(source, str(path), "exec"), module.__dict__)
    return module


def mutated(path, old, new, name):
    source = Path(path).read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise SystemExit(f"mutant {name}: {old[:70]!r} occurs {source.count(old)} time(s), not once")
    return load(path, name, source.replace(old, new))


compact = load(HERE / "compact_json.py", "t_compact")
evidence = load(HERE / "census_evidence.py", "t_evidence")
groups = load(HERE / "canon_groups.py", "t_groups")
size = load(HERE / "check-observation-size.py", "t_size")
labels = load(HERE / "locale_labels.py", "t_labels")

# ---- compact_json ------------------------------------------------------------------------------------
doc = {"id": "r", "strings": ["a", "b", "c"], "host": {"v": 1, "locale": "ko-KR"},
       "canon_groups": [{"ref": "x", "binding": {"kind": "record"}, "values": ["p", "q"]}],
       "nested": {"inner": {"deep": [1, 2, {"k": "v", "w": 1, "z": 2, "y": 3}]}},
       "searched": [{"source": "s", "locale": "en"}, {"source": "s", "locale": "de"}]}
text = compact.dumps(doc, 2)
case("compact json parses back to the same document", json.loads(text) == doc)
case("compact json is stable", compact.dumps(json.loads(text), 2) == text)
case("a list of scalars is one line", '"strings": ["a", "b", "c"]' in text, text)
case("a flat object is one line", '"host": {"v": 1, "locale": "ko-KR"}' in text)
case("a citation group is one line", any(line.strip().startswith('{"ref": "x"') for line in text.splitlines()))
case("a list of tiny pairs is one line", '"searched": [{"source": "s", "locale": "en"}, ' in text)
big = {"strings": [f"s{i}" for i in range(600)], "meta": {"a": 1}}
case("six hundred strings cost one line, not six hundred", len(compact.dumps(big, 2).splitlines()) <= 6)
m = mutated(HERE / "compact_json.py",
            "    return isinstance(node, list) and all(isinstance(v, _SCALARS) or _tiny(v) for v in node)\n",
            "    return False\n", "mut_compact_leaf")
case("MUTANT: a list that is not a leaf costs a line per element", len(m.dumps(big, 2).splitlines()) > 600)

# ---- census_evidence ---------------------------------------------------------------------------------
census = {"host": {"app": "Logic Pro", "version": "98.7", "build": "65432", "locale": "ko-KR"},
          "menu_bar": ["파일"],
          "census": [{"surface": "arrange.menus", "path": f"AXMenuBar/AXMenuBarItem[{i}]", "role": "AXMenuItem",
                      "title": f"항목 {i}"} for i in range(5)]}
body = evidence.dumps(census)
case("evidence is a header and one line per row", len(body.splitlines()) == 6, len(body.splitlines()))
case("evidence reads back to the same rows and host",
     evidence.loads(body)["census"] == census["census"] and evidence.loads(body)["host"] == census["host"])
try:
    evidence.loads("\n".join(body.splitlines()[:-1]) + "\n")
    refused = False
except ValueError:
    refused = True
case("a truncated evidence file is refused, not read short", refused)
m = mutated(HERE / "census_evidence.py", '    if header.get("rows") != len(rows):\n', "    if False:\n", "mut_evidence_rows")
try:
    got = m.loads("\n".join(body.splitlines()[:-1]) + "\n")
    case("MUTANT: without the row count a truncated file reads short", len(got["census"]) == 4)
except ValueError:
    case("MUTANT: without the row count a truncated file reads short", False)
with tempfile.TemporaryDirectory() as tmp:
    legacy = Path(tmp) / "e.census.json"
    legacy.write_text(json.dumps(census), encoding="utf-8")
    case("a legacy `.json` evidence file still reads", evidence.load(str(legacy))["census"] == census["census"])

# ---- canon_groups ------------------------------------------------------------------------------------
flat = [{"ref": "r1", "value": "a", "used_for": "u", "binding": {"kind": "record"}},
        {"ref": "r2", "value": "b", "used_for": "u", "binding": {"kind": "record"}},
        {"ref": "r1", "value": "c", "used_for": "u", "binding": {"kind": "record"}}]
grouped = groups.group(flat)
case("three citations on two references are two groups", len(grouped) == 2, grouped)
case("expanding the groups gives the same citations, as a set",
     sorted(map(json.dumps, groups.expand({"canon_groups": grouped}))) == sorted(map(json.dumps, flat)))
case("a record's flat `canon` still reads", groups.expand({"canon": flat}) == flat)
case("both forms together are both read",
     len(groups.expand({"canon": flat, "canon_groups": grouped})) == 6)

# ---- the digest binds the evidence's bytes ----------------------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    obs = Path(tmp)
    (obs / "evidence").mkdir()
    (obs / "evidence/e.census.jsonl").write_text(body, encoding="utf-8")
    rec = {"id": "2026-11-18-ko-KR-x-census", "host": census["host"], "evidence": ["evidence/e.census.jsonl"]}
    (obs / "2026-11-18-ko-KR-x-census.json").write_text(compact.dumps(rec, 2), encoding="utf-8")
    before = labels.record_facts("2026-11-18-ko-KR-x-census", str(obs))
    case("a record with JSON Lines evidence has a digest", before["status"] == "ok" and before.get("sha256"), before)
    case("its strings are read out of the rows", "항목 3" in (labels.record_strings("2026-11-18-ko-KR-x-census", str(obs)) or ()))
    tampered = body.replace("항목 3", "항목 9")
    (obs / "evidence/e.census.jsonl").write_text(tampered, encoding="utf-8")
    labels._DIGEST_CACHE.clear()
    after = labels.record_facts("2026-11-18-ko-KR-x-census", str(obs))
    case("TAMPER: changing one row of the evidence changes the digest", after["sha256"] != before["sha256"])
    problems = labels.binding_problems("2026-11-18-ko-KR-x-census", "ko-KR", before["sha256"], "98.7", "65432",
                                       str(obs), "항목 3")
    case("TAMPER: a reading bound to the old digest stops verifying", any("record_sha256" in p for p in problems), problems)
    # MUTANT: a digest that covers only the record would let the evidence be rewritten under it.
    src = (HERE / "locale_labels.py").read_text(encoding="utf-8")
    old = '            h.update(b"\\0" + rel.encode("utf-8") + b"\\0" + body)\n'
    case("mutant premise: the evidence is folded into the digest on one line", src.count(old) == 1)
    mut = load(HERE / "locale_labels.py", "mut_labels_digest", src.replace(old, "            pass\n"))
    (obs / "evidence/e.census.jsonl").write_text(body, encoding="utf-8")
    mut._DIGEST_CACHE.clear()
    one = mut.record_facts("2026-11-18-ko-KR-x-census", str(obs))["sha256"]
    (obs / "evidence/e.census.jsonl").write_text(tampered, encoding="utf-8")
    mut._DIGEST_CACHE.clear()
    two = mut.record_facts("2026-11-18-ko-KR-x-census", str(obs))["sha256"]
    case("MUTANT: a digest over the record alone cannot see the evidence tampered", one == two)


# ---- the size ratchet --------------------------------------------------------------------------------
ATTRIBUTES = (HERE.parent / ".gitattributes").read_text(encoding="utf-8")


def tree(rows=5, extra_evidence=False, pretty_evidence=False, pretty_record=False, padded=0, attributes=True):
    root = Path(tempfile.mkdtemp())
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    swift = root / "Sources/LogicProMCP/Accessibility"
    swift.mkdir(parents=True)
    (swift / "AXLocalePolicy.swift").write_text(
        'enum AXLocalePolicy {\n    static let currentLogicVersion = "98.7"\n    static let currentLogicBuild = "65432"\n}\n',
        encoding="utf-8")
    if attributes:
        (root / ".gitattributes").write_text(ATTRIBUTES, encoding="utf-8")
    obs = root / "docs/observations"
    (obs / "evidence").mkdir(parents=True)
    doc = dict(census, census=census["census"][:1] * rows)
    name = "evidence/2026-11-18-ko-KR-navigation-free.census.jsonl"
    text = evidence.dumps(doc)
    if pretty_evidence:
        name = "evidence/2026-11-18-ko-KR-navigation-free.census.json"
        text = json.dumps(doc, indent=1, ensure_ascii=False)
    (obs / name).write_text(text, encoding="utf-8")
    if padded:
        with open(obs / name, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(doc["census"][0]) + "\n" * padded)   # rows the header does not count
    if extra_evidence:
        (obs / "evidence/2026-11-17-ko-KR-navigation-free.census.jsonl").write_text(evidence.dumps(doc), encoding="utf-8")
    rec = {"id": "2026-11-18-ko-KR-arrange-menus-census", "host": doc["host"], "evidence": [name],
           "strings": [f"s{i}" for i in range(300)]}
    (obs / "2026-11-18-ko-KR-arrange-menus-census.json").write_text(
        json.dumps(rec, indent=2, ensure_ascii=False) + "\n" if pretty_record else compact.dumps(rec, 2), encoding="utf-8")
    return root


def codes(found):
    return {p.split(" ")[0] for p in found}


found, _notes = size.problems(str(tree()), base=None)
case("a compact, LFS-stored, generated-marked campaign is within budget", found == [], found)
found, _ = size.problems(str(tree(pretty_evidence=True)), base=None)
case("a pretty-printed evidence file is refused", any("JSON Lines" in p for p in found), found)
found, _ = size.problems(str(tree(padded=40)), base=None)
case("R1 an evidence file padded beyond rows + 1 is refused", "R1" in codes(found), found)
found, _ = size.problems(str(tree(extra_evidence=True)), base=None)
case("R2 a second evidence file for one locale and build is refused", "R2" in codes(found), found)
found, _ = size.problems(str(tree(pretty_record=True)), base=None)
case("R3 a pretty-printed record is refused", "R3" in codes(found), found)
found, _ = size.problems(str(tree(attributes=False)), base=None)
case("R4 evidence outside LFS and generated files not marked are refused",
     "R4" in codes(found) and any("Git LFS" in p for p in found) and any("linguist-generated" in p for p in found), found)
pointer = tree()
(pointer / "docs/observations/evidence/2026-11-18-ko-KR-navigation-free.census.jsonl").write_text(
    "version https://git-lfs.github.com/spec/v1\noid sha256:" + "0" * 64 + "\nsize 10\n", encoding="utf-8")
found, _ = size.problems(str(pointer), base=None)
case("R1 a checkout that did not fetch LFS says so", any("LFS pointer" in p for p in found), found)

m = mutated(HERE / "check-observation-size.py",
            '            out.append(f"R1 {os.path.basename(path)}: unreadable census evidence ({exc})")\n', "            pass\n",
            "mut_size_r1")
case("MUTANT: without R1 a padded evidence file passes", "R1" not in codes(m.problems(str(tree(padded=40)), base=None)[0]))
m = mutated(HERE / "check-observation-size.py", "        if len(names) > 1:\n", "        if False:\n", "mut_size_r2")
case("MUTANT: without R2 a duplicate census passes", "R2" not in codes(m.problems(str(tree(extra_evidence=True)), base=None)[0]))
m = mutated(HERE / "check-observation-size.py", "        if raw != compact.dumps(rec, 2):\n", "        if False:\n", "mut_size_r3")
case("MUTANT: without R3's form check a pretty-printed record passes the form test",
     not any("canonical compact form" in p for p in m.problems(str(tree(pretty_record=True)), base=None)[0]))
m = mutated(HERE / "check-observation-size.py", '        if value != "lfs":\n', "        if False:\n", "mut_size_r4_lfs")
case("MUTANT: without the LFS check evidence can sit in plain git", not any("Git LFS" in p for p in m.problems(str(tree(attributes=False)), base=None)[0]))
m = mutated(HERE / "check-observation-size.py", '        if value != "true":\n', "        if False:\n", "mut_size_r4_gen")
case("MUTANT: without the generated check a machine file shows in the diff",
     not any("linguist-generated" in p for p in m.problems(str(tree(attributes=False)), base=None)[0]))

# R5: against a real base, a campaign that writes more than its variants into the policy is refused.
root = tree()
subprocess.run(["git", "add", "-A"], cwd=root, check=True)
subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "base"], cwd=root, check=True)
base = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True).stdout.strip()
policy = root / size.POLICY
found, _ = size.problems(str(root), base=base)
case("R5 an unchanged policy is within budget", found == [], found)
policy.write_text(policy.read_text(encoding="utf-8") + "".join(f"    static let v{i} = 1\n" for i in range(399)), encoding="utf-8")
found, _ = size.problems(str(root), base=base)
case("R5 forty variant lines per locale is the limit", found == [], found)
policy.write_text(policy.read_text(encoding="utf-8") + "".join(f"    static let w{i} = 1\n" for i in range(5)), encoding="utf-8")
found, _ = size.problems(str(root), base=base)
case("R5 a change beyond it is refused", "R5" in codes(found), found)
m = mutated(HERE / "check-observation-size.py", "        if added > VARIANT_LINES_PER_LOCALE * LOCALES:\n", "        if False:\n", "mut_size_r5")
case("MUTANT: without R5 a hand-written policy change passes", "R5" not in codes(m.problems(str(root), base=base)[0]))
case("R5's budget is derived from the variants a campaign appends, not typed per run",
     "VARIANT_LINES_PER_LOCALE * LOCALES" in (HERE / "check-observation-size.py").read_text(encoding="utf-8"))
real = size.problems(str(HERE.parent), base="auto")[0]
case("this repository is within budget", real == [], real)

if failures:
    for line in failures:
        print(f"FAIL {line}")
    sys.exit(1)
print(f"{ran[0]} case(s) pass: the census formats are compact, their bytes are bound, and a campaign cannot outgrow them")
