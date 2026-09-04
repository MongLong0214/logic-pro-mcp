#!/usr/bin/env python3
"""Every observation record under `docs/observations/` obeys its own schema.

Discovered automatically by `run-repo-guards.py` (top-level `Scripts/check-*.py`), so it runs in
both CI jobs that gate a merge.

The rule this enforces is the one the records exist for: a measurement that cannot be searched,
compared, or checked for still being true decays into a sentence in an issue comment. Three
properties keep it usable, and each is a real failure this repository has had:

  * `limits` may not be empty. A measurement with no stated boundary is claiming there is none,
    which is nearly always false — and "silence from an unaimed instrument is not absence" was
    learned by asserting coverage a probe never had.
  * numbers in `conclusion` must appear in `observations`. A conclusion that carries a figure its
    own readings do not is the receipt-exceeding-the-code failure, in a new place.
  * `id` must equal the filename stem, so a record can be cited and then found.
"""
import glob
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIR = os.path.join(REPO, "docs", "observations")

REQUIRED = ("id", "date", "subject", "question", "verdict", "issues", "surface",
            "host", "reverify", "depends",
            "method", "observations", "conclusion", "limits", "supersedes")
# version AND build: Logic ships updates that keep the marketing version and move the build, so
# version alone cannot detect drift. `os` is here for the same reason and was added after all
# nine records in the tree were found carrying an OS the machine had never run — a value typed
# once and inherited by copy. Generate the block with `Scripts/observation_host.py` instead of
# writing it: a copied field is not a measurement.
HOST_KEYS = ("app", "version", "build", "os")
REVERIFY_KINDS = ("script", "harness", "manual")
SURFACES_DOC = os.path.join(REPO, "docs", "observations", "SURFACES.md")


def known_surfaces():
    """The taxonomy, read from its own table so the two cannot drift apart."""
    out = set()
    if not os.path.exists(SURFACES_DOC):
        return out
    for line in open(SURFACES_DOC, encoding="utf-8"):
        m = re.match(r"\|\s*`([a-z_]+\.[a-z_]+)`\s*\|", line)
        if m:
            out.add(m.group(1))
    return out
VERDICTS = ("works", "wall", "partial", "inconclusive")


def numbers(text):
    """Integers and decimals appearing as standalone tokens, not inside identifiers or dates."""
    return {m.group(0) for m in re.finditer(r"(?<![\w.\-])\d+(?:\.\d+)?(?![\w.\-])", text)}


def check(path):
    stem = os.path.basename(path)[: -len(".json")]
    bad = []
    try:
        doc = json.load(open(path, encoding="utf-8"))
    except ValueError as exc:
        return [f"{stem}: not valid JSON ({exc})"]

    for key in REQUIRED:
        if key not in doc:
            bad.append(f"{stem}: missing required key {key!r}")
    if bad:
        return bad

    if doc["id"] != stem:
        bad.append(f"{stem}: id is {doc['id']!r}; it must equal the filename stem so a citation resolves")
    surfaces = known_surfaces()
    if surfaces and doc["surface"] not in surfaces:
        bad.append(f"{stem}: surface {doc['surface']!r} is not in docs/observations/SURFACES.md — "
                   f"add a row there before using it, or the taxonomy is just a list of strings")
    if doc["verdict"] not in VERDICTS:
        bad.append(f"{stem}: verdict {doc['verdict']!r} is not one of {VERDICTS}")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(doc["date"])):
        bad.append(f"{stem}: date {doc['date']!r} is not YYYY-MM-DD")
    if not stem.startswith(str(doc["date"])):
        bad.append(f"{stem}: filename must start with the measurement date {doc['date']}")

    if not isinstance(doc["observations"], list) or not doc["observations"]:
        bad.append(f"{stem}: observations is empty — a record with no readings is not an observation")
    if not isinstance(doc["limits"], list) or not doc["limits"]:
        bad.append(f"{stem}: limits is empty. Every measurement has a boundary; state it rather than "
                   f"implying there is none")

    # A figure in the conclusion has to be traceable to a reading.
    obs_text = json.dumps(doc["observations"], ensure_ascii=False)
    for n in numbers(doc["conclusion"]) - numbers(obs_text):
        bad.append(f"{stem}: conclusion contains {n!r}, which appears in no observation — "
                   f"a number in a conclusion must be derivable from the readings")

    host = doc["host"]
    if not isinstance(host, dict):
        bad.append(f"{stem}: host must be an object")
    else:
        for k in HOST_KEYS:
            if not host.get(k):
                bad.append(f"{stem}: host.{k} is required — drift is computed from it")

    # A claim nobody can re-run is a claim nobody can retire.
    rv = doc["reverify"]
    if not isinstance(rv, dict):
        bad.append(f"{stem}: reverify must be an object")
    else:
        if rv.get("kind") not in REVERIFY_KINDS:
            bad.append(f"{stem}: reverify.kind {rv.get('kind')!r} is not one of {REVERIFY_KINDS}")
        if not rv.get("command"):
            bad.append(f"{stem}: reverify.command is required — manual steps count, absence does not")
        elif rv.get("kind") in ("script", "harness"):
            target = os.path.join(REPO, rv["command"])
            if not os.path.exists(target):
                bad.append(f"{stem}: reverify.command {rv['command']!r} does not exist")
            elif not os.access(target, os.X_OK):
                bad.append(f"{stem}: reverify.command {rv['command']!r} is not executable")
        if not rv.get("expected"):
            bad.append(f"{stem}: reverify.expected is required — a re-run with no expected reading "
                       f"cannot disagree with the record")

    # `depends` may be empty; each entry must name a file that exists, because a stale record
    # reports these as unverified and a path that has moved makes that report wrong.
    if not isinstance(doc["depends"], list):
        bad.append(f"{stem}: depends must be a list")
    else:
        for dep in doc["depends"]:
            rel = dep.split(":", 1)[0]
            if not os.path.exists(os.path.join(REPO, rel)):
                bad.append(f"{stem}: depends names {rel!r}, which does not exist")

    if doc["supersedes"] is not None:
        target = os.path.join(DIR, f"{doc['supersedes']}.json")
        if not os.path.exists(target):
            bad.append(f"{stem}: supersedes {doc['supersedes']!r}, which is not a record here")
    return bad


def main():
    if not os.path.isdir(DIR):
        print("no docs/observations directory; nothing to check")
        return 0
    paths = sorted(p for p in glob.glob(os.path.join(DIR, "*.json")))
    problems = []
    for p in paths:
        problems += check(p)
    if problems:
        print(f"{len(problems)} observation-record problem(s):")
        for line in problems:
            print(f"  {line}")
        return 1
    print(f"{len(paths)} observation record(s) obey the schema")
    return 0


if __name__ == "__main__":
    sys.exit(main())
