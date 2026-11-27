#!/usr/bin/env python3
"""A census campaign for one locale is small where a reviewer reads, and the rest is LFS or generated.

Pretty-printed, one locale's census was ten thousand lines of evidence and six hundred lines per record;
eleven of them made a pull request nobody could review. The standard answer, applied here:

    raw evidence             Git LFS (`.gitattributes`): one JSON line per row, exactly `rows + 1` lines, one
                             file per locale per kind per Logic build; checked out as real bytes, so the
                             digests that bind a record to it still hash what was measured
    machine-maintained files `linguist-generated=true`: records, the ledger, the canon index and ledger,
                             RATCHETS.json -- GitHub collapses them; each is deterministic and compact
    everything else          what a reviewer reads: the code, and `AXLocalePolicy.swift`, where a campaign
                             may append an accepted variant (one line each)

and this guard refuses anything that drifts from that:

    R1  a census evidence file of the declared release is exactly `rows + 1` lines, the header's `rows` is the
        number of rows, and it is not an LFS pointer in the checkout (the guards need the real bytes)
    R2  one evidence file per locale per kind per Logic build: a second is the same measurement twice
    R3  a census record of the declared release is in canonical compact form and at most RECORD_LINES long
    R4  every evidence file is stored in LFS and every machine-maintained file is `linguist-generated`
        (`git check-attr`), so none of it lands in a reviewer's diff
    R5  against the merge base, a change adds at most VARIANT_LINES_PER_LOCALE lines per locale to
        `AXLocalePolicy.swift`, the one reviewable file a campaign writes (skipped, and said so, where there
        is no merge base; CI checks out full history)

Only the declared release is judged: a record of an older build is history, written before the formats.

    check-observation-size.py [repo]
"""
import glob
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
#: A compact record is ~35 lines: its keys, the strings on one line, the citations in groups. Sixty leaves
#: room for the optional blocks (a `canon_absent` entry, a near-miss limit) without admitting a pretty-printed one.
RECORD_LINES = 60
#: A campaign appends accepted variants to the Swift policy, one line each, and only where the live string
#: equals the label's own canon value. The largest candidate list any census proposed was six; forty per
#: locale is far above that and far below a hand-written change.
VARIANT_LINES_PER_LOCALE = 40
LOCALES = 10
POLICY = os.path.join("Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
#: Machine-maintained paths (globs, repo-relative) that must be `linguist-generated`.
GENERATED = ("docs/observations/RATCHETS.json", "docs/locale/ui-labels.json", "docs/locale/holds.json",
             "docs/locale/census-areas.json", "docs/canon/MANIFEST.json", "Scripts/logic_ui_labels.py",
             "Sources/LogicProMCP/Accessibility/AXLocaleValues.swift")
GENERATED_DIRS = ("docs/canon/index", "docs/canon/ledger")
EVIDENCE_NAME = re.compile(r"^(\d{4}-\d{2}-\d{2})-(.+?)-(navigation-free|navigation)\.census\.json(l?)$")


def _load(name):
    spec = importlib.util.spec_from_file_location(f"size_{name}", os.path.join(HERE, f"{name}.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _lines(path):
    with open(path, encoding="utf-8") as handle:
        return sum(1 for _ in handle)


def _declared(repo):
    labels = _load("locale_labels")
    return labels.declared_logic(os.path.join(repo, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift"))


def _base(repo):
    for cmd in (["git", "merge-base", "HEAD", "origin/main"],):
        done = subprocess.run(cmd, cwd=repo, capture_output=True, text=True)
        if done.returncode == 0 and done.stdout.strip():
            return done.stdout.strip()
    return None


def _attr(repo, attribute, paths):
    """`{path: value}` of one git attribute for each path, as `git check-attr` reports it."""
    if not paths:
        return {}
    done = subprocess.run(["git", "check-attr", attribute, "--", *paths], cwd=repo, capture_output=True, text=True)
    found = {}
    for line in done.stdout.splitlines():
        path, _name, value = line.rsplit(": ", 2)
        found[path] = value
    return found


def _attribute_problems(repo, evidence_groups, records):
    out = []
    evidence = sorted(os.path.join("docs", "observations", "evidence", n)
                      for names in evidence_groups.values() for n in names)
    for path, value in _attr(repo, "filter", evidence).items():
        if value != "lfs":
            out.append(f"R4 {path}: raw census evidence must be stored in Git LFS (filter is {value!r}); add it "
                       f"to .gitattributes")
    generated = list(GENERATED) + [os.path.relpath(r, repo) for r in records]
    for directory in GENERATED_DIRS:
        base = os.path.join(repo, directory)
        for root, _dirs, files in os.walk(base):
            generated += [os.path.relpath(os.path.join(root, f), repo) for f in files]
    generated = [g for g in generated if os.path.exists(os.path.join(repo, g))]
    for path, value in _attr(repo, "linguist-generated", sorted(generated)).items():
        if value != "true":
            out.append(f"R4 {path}: a machine-maintained file must be `linguist-generated=true` in "
                       f".gitattributes, or GitHub shows it to a reviewer")
    return out


def problems(repo=REPO, base="auto"):
    """`(problems, notes)` for the tree at `repo`."""
    evidence_mod, compact = _load("census_evidence"), _load("compact_json")
    obs = os.path.join(repo, "docs", "observations")
    declared = _declared(repo)
    out, notes = [], []
    if not declared:
        return ["AXLocalePolicy.swift declares no current Logic"], notes
    budget, files_of = {}, {}
    groups = {}
    for path in sorted(glob.glob(os.path.join(obs, "evidence", "*.census.json*"))):
        match = EVIDENCE_NAME.match(os.path.basename(path))
        if not match:
            continue
        try:
            doc = evidence_mod.load(path)
        except (OSError, ValueError) as exc:
            out.append(f"R1 {os.path.basename(path)}: unreadable census evidence ({exc})")
            continue
        host = doc.get("host") or {}
        if (str(host.get("version")), str(host.get("build"))) != (declared["version"], declared["build"]):
            continue
        locale, kind = match.group(2), match.group(3)
        name = os.path.basename(path)
        lines = _lines(path)
        if not path.endswith(".jsonl"):
            out.append(f"{name}: census evidence of the declared release must be JSON Lines "
                       f"(`.census.jsonl`, one row per line), not a pretty-printed document")
        elif lines != len(doc["census"]) + 1:
            out.append(f"R1 {name}: {lines} lines for {len(doc['census'])} rows; the compact format is "
                       f"exactly rows + 1")
        groups.setdefault((locale, kind, str(host.get("build"))), []).append(name)
        budget[locale] = budget.get(locale, 0) + len(doc["census"]) + 1
        files_of.setdefault(locale, []).append(os.path.join("docs", "observations", "evidence", name))
    for key, names in sorted(groups.items()):
        if len(names) > 1:
            out.append(f"R2 {key[0]} {key[1]} on build {key[2]}: {len(names)} evidence files ({', '.join(names)}); "
                       f"keep the newest -- a second is the same measurement taken twice")
    for path in sorted(glob.glob(os.path.join(obs, "20*-census.json"))):
        try:
            with open(path, encoding="utf-8") as handle:
                raw = handle.read()
            rec = json.loads(raw)
        except (OSError, ValueError):
            continue
        host = rec.get("host") or {}
        if (str(host.get("version")), str(host.get("build"))) != (declared["version"], declared["build"]):
            continue
        name = os.path.basename(path)
        lines = raw.count("\n")
        if raw != compact.dumps(rec, 2):
            out.append(f"R3 {name}: not in the canonical compact form (compact_json.dumps(record, 2))")
        if lines > RECORD_LINES:
            out.append(f"R3 {name}: {lines} lines; a compact record is at most {RECORD_LINES}")
        locale = host.get("locale")
        budget[locale] = budget.get(locale, 0) + RECORD_LINES
        files_of.setdefault(locale, []).append(os.path.join("docs", "observations", name))
    out += _attribute_problems(repo, groups, glob.glob(os.path.join(obs, "20*-census.json")))
    if base == "auto":
        base = _base(repo)
    if not base:
        notes.append("no merge base with origin/main: R5 (variant lines added against the base) was not checked")
        return out, notes
    in_base = subprocess.run(["git", "cat-file", "-e", f"{base}:{POLICY}"], cwd=repo, capture_output=True).returncode == 0
    if in_base:
        done = subprocess.run(["git", "diff", "--numstat", base, "--", POLICY], cwd=repo, capture_output=True, text=True)
        first = done.stdout.split("\t")[0] if done.stdout else "0"
        added = int(first) if first.isdigit() else 0
        if added > VARIANT_LINES_PER_LOCALE * LOCALES:
            out.append(f"R5 {POLICY}: this change adds {added} lines; a campaign appends accepted variants, "
                       f"at most {VARIANT_LINES_PER_LOCALE} per locale ({VARIANT_LINES_PER_LOCALE * LOCALES} "
                       f"for {LOCALES} locales)")
    return out, notes


def main(argv):
    repo = os.path.abspath(argv[0]) if argv else REPO
    found, notes = problems(repo)
    for note in notes:
        print(f"note: {note}")
    if found:
        print("the census campaign is bigger than its format allows:")
        for line in found:
            print(f"  {line}")
        return 1
    print("check-observation-size: census evidence and records are within the compact format's budget")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
