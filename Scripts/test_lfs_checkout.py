#!/usr/bin/env python3
"""Every CI job that reads census evidence checks out LFS content, and `.gitattributes` says what is LFS.

Raw census evidence lives in Git LFS. `actions/checkout` fetches LFS objects only when `lfs: true`; without
it the job gets a three-line pointer where the rows should be, and the guards that hash and read the evidence
fail -- or, worse, a guard that skips an unreadable file passes over a tree it never read. So this pins:

    L1  every `actions/checkout` step in a job that runs an evidence-reading script has `lfs: true`
    L2  `.gitattributes` stores `docs/observations/evidence/*.census.jsonl` in LFS and marks the
        machine-maintained files `linguist-generated`
    L3  the files on disk that match the LFS rule are real rows (not pointers) in this checkout

A MUTANT removes the `lfs: true` lines and must turn L1 red.
"""
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
WORKFLOWS = [REPO / ".github/workflows/ci.yml", REPO / ".github/workflows/release.yml"]
#: Scripts that read a record's evidence or hash it. A job running any of them needs the real bytes.
READERS = ("check-observation-", "check-canon-citations", "check-locale-labels-json", "check-variants-appear",
           "check-observations-cover", "locale_labels.py", "test_locale_", "test_observation_", "test_canon_",
           "test_logic_canon", "logic_canon.py", "check-labelsets", "check-policy-literals")
ran, failures = [0], []


def case(name, condition, detail=""):
    ran[0] += 1
    if not condition:
        failures.append(f"{name}: {detail}")


def jobs(text):
    """`{job name: its text}` for the top-level `jobs:` block, split on two-space-indented keys."""
    body = text.split("\njobs:\n", 1)[1]
    parts = re.split(r"\n(?=  [A-Za-z0-9_-]+:\n)", "\n" + body)
    return {p.strip().split(":", 1)[0]: p for p in parts if p.strip()}


def checkouts(job_text):
    """Each `actions/checkout` step's text (up to the next step)."""
    steps = re.split(r"\n(?=      - )", job_text)
    return [s for s in steps if "actions/checkout" in s]


def violations(texts):
    found = []
    for name, text in texts.items():
        for job, body in jobs(text).items():
            if not any(reader in body for reader in READERS):
                continue
            for step in checkouts(body):
                if not re.search(r"^\s+lfs:\s*true\s*$", step, re.M):
                    found.append(f"{name} job `{job}`: a checkout reads evidence without `lfs: true`")
    return found


texts = {p.name: p.read_text(encoding="utf-8") for p in WORKFLOWS}
case("L1 every evidence-reading job checks out LFS content", violations(texts) == [], violations(texts))
readers = [(n, j) for n, t in texts.items() for j, b in jobs(t).items() if any(r in b for r in READERS)]
case("L1 the scan finds the canon-locales job (it is not vacuous)", ("ci.yml", "canon-locales") in readers, readers)
stripped = {n: re.sub(r"^\s+lfs: true\n", "", t, flags=re.M) for n, t in texts.items()}
case("MUTANT: with `lfs: true` removed the guard goes red", len(violations(stripped)) >= 2, violations(stripped))
one = dict(texts)
start = texts["ci.yml"].index("\n  canon-locales:\n")
one["ci.yml"] = texts["ci.yml"][:start] + re.sub(r"^\s+lfs: true\n", "", texts["ci.yml"][start:], count=1, flags=re.M)
case("MUTANT: removing it from ONE checkout is enough to go red", violations(one) != [])

attrs = (REPO / ".gitattributes").read_text(encoding="utf-8")
case("L2 evidence is stored in LFS",
     re.search(r"^docs/observations/evidence/\*\.census\.jsonl\s+filter=lfs diff=lfs merge=lfs -text\s*$", attrs, re.M), attrs[:200])
for path in ("docs/locale/ui-labels.json", "docs/observations/RATCHETS.json", "docs/canon/index/**",
             "docs/canon/ledger/**", "docs/observations/20*-census.json"):
    case(f"L2 {path} is marked generated", re.search(rf"^{re.escape(path)}\s+linguist-generated=true\s*$", attrs, re.M))
done = subprocess.run(["git", "lfs", "ls-files", "--name-only"], cwd=REPO, capture_output=True, text=True)
tracked = [n for n in done.stdout.splitlines() if n.endswith(".census.jsonl")]
case("L3 git lfs tracks the census evidence", len(tracked) >= 1, done.stdout[:200] + done.stderr[:200])
for name in tracked:
    head = (REPO / name).read_text(encoding="utf-8")[:40]
    case(f"L3 {name} is real rows in this checkout, not a pointer", not head.startswith("version https://git-lfs"), head)

if failures:
    for line in failures:
        print(f"FAIL {line}")
    sys.exit(1)
print(f"{ran[0]} case(s) pass: every job that reads census evidence fetches it from LFS")
