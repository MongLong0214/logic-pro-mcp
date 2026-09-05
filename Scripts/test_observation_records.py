#!/usr/bin/env python3
"""Cases for `check-observation-records.py`, the schema behind `docs/observations/`.

Every case here is a control that was run by hand while the guard was being written, and every one
of them found something at the time: two records asserted a number no reading supported, all nine
claimed an OS the machine had never run, a renamed symbol left a `depends` entry pointing at a name
the file no longer contained, and the `reverify` rule rejected a correct record because it demanded
an exec bit 41 of the 42 harnesses here do not carry.

They are cases now rather than a memory because the guard was edited four times in one day and each
edit was checked once. A rule verified at one instant is a rule that drifts — the reason
`check-guards-have-self-tests.py` exists.

`check(path)` is driven directly against temporary files, so the cases neither read nor disturb the
real records.
"""
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "observation_records", os.path.join(REPO, "Scripts", "check-observation-records.py"))
G = importlib.util.module_from_spec(spec)
spec.loader.exec_module(G)

failed = 0
tmp = tempfile.mkdtemp()


def case(name, condition, detail):
    global failed
    failed += 0 if condition else 1
    print(f"{'ok  ' if condition else 'FAIL'} {name} -> {detail}")


def record(**overrides):
    """A record that passes, so each case can break exactly one thing."""
    doc = {
        "id": "2026-09-04-a-case",
        "date": "2026-09-04",
        "subject": "a subject",
        "question": "a question?",
        "verdict": "works",
        "issues": [1],
        "surface": "arrange.track_headers",
        "host": {"app": "Logic Pro", "version": "12.3", "build": "6674",
                 "locale": "ko-KR", "os": "macOS 26.3 (25D125)"},
        "reverify": {"kind": "manual", "command": "look at it", "expected": "a thing", "cost": "1 min"},
        "depends": [],
        "method": "looked",
        "observations": [{"what": "a reading", "count": 3}],
        "conclusion": "There were 3 of them.",
        "limits": ["one machine"],
        "supersedes": None,
    }
    doc.update(overrides)
    return doc


def problems(doc, name="2026-09-04-a-case.json"):
    path = os.path.join(tmp, name)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False)
    try:
        return G.check(path)
    finally:
        os.remove(path)


# 0. The baseline has to pass, or every case below proves nothing.
case("a well-formed record is accepted", problems(record()) == [], f"{problems(record())!r}")

# 1. The host block says what the claim is true OF, and drift is computed from it. All nine records
#    once claimed `macOS 26.6` on a machine that has run 26.3 since February — one block written by
#    hand and inherited by copy, which is why `os` is required and why it is generated.
bad = problems(record(host={"app": "Logic Pro", "version": "12.3", "build": "6674"}))
case("a host block with no os is rejected", any("host.os" in b for b in bad), f"{bad!r}")

# 2. THE ONE THAT KEEPS CATCHING ME. A number in a conclusion must come from a reading; three of my
#    own records asserted one that did not — a poll interval, a PR number, a count of sites.
bad = problems(record(conclusion="There were 7 of them."))
case("a number in the conclusion with no reading behind it is rejected",
     any("appears in no observation" in b for b in bad), f"{bad!r}")

# 2b. What the number check does NOT do, pinned so nobody reads more into it. An outside review
#     put it exactly: an observation `{"retry_count": 3}` lets the unrelated conclusion "Latency
#     was 3 seconds" pass. Tying a numeral to its meaning is not something a static check can do,
#     and this case exists so the limit is visible rather than discovered later.
good = problems(record(observations=[{"retry_count": 3}], conclusion="Latency was 3 seconds."))
case("an unrelated numeral satisfies the check — a known limit, not a claim",
     good == [], f"{good!r}")

# 3. `limits` is where a record says what it does not cover. Empty is not a limit, it is a claim of
#    completeness nothing here can support.
bad = problems(record(limits=[]))
case("an empty limits list is rejected", any("limits" in b for b in bad), f"{bad!r}")

# 4. `depends` names the code a claim binds to, and the symbol is the part that moves. Renaming
#    `LocatorFailure.popupUnmeasured` left the path resolving, the build passing and the record
#    pointing at a name the file no longer contained.
bad = problems(record(depends=["Scripts/check-observation-records.py:NoSuchSymbolHere"]))
case("a depends entry naming a symbol the file lacks is rejected",
     any("does not appear" in b for b in bad), f"{bad!r}")

# 5. ...and the same entry naming a symbol that IS there passes, so case 4 is about the symbol and
#    not about the syntax.
good = problems(record(depends=["Scripts/check-observation-records.py:REVERIFY_KINDS"]))
case("a depends entry naming a real symbol is accepted", good == [], f"{good!r}")

# 6. `reverify` must run AS WRITTEN. Demanding an exec bit rejected a correct record whose command
#    was `python3 <harness>`, and its only escape was to relabel the record `manual` — a rule that
#    pushes work into the category it does not check.
good = problems(record(reverify={"kind": "harness",
                                 "command": "python3 Scripts/check-observation-records.py",
                                 "expected": "it runs", "cost": "1 min"}))
case("an interpreter-led command needs no exec bit", good == [], f"{good!r}")

# 7. A command invoked directly still does, because that one cannot run without it.
bad = problems(record(reverify={"kind": "harness", "command": "docs/observations/SCHEMA.md",
                                "expected": "x", "cost": "1 min"}))
case("a directly-invoked command that is not executable is rejected",
     any("not executable" in b for b in bad), f"{bad!r}")

# 8. And a command naming nothing that exists is rejected whichever way it is invoked.
bad = problems(record(reverify={"kind": "script", "command": "python3 Scripts/nope-not-here.py",
                                "expected": "x", "cost": "1 min"}))
case("a command naming a file that does not exist is rejected",
     any("names no file" in b for b in bad), f"{bad!r}")

# 9. The surface has to be one the taxonomy declares, or the coverage report counts a category
#    nobody defined.
bad = problems(record(surface="arrange.invented"))
case("an undeclared surface is rejected", any("surface" in b for b in bad), f"{bad!r}")

# --- schema 2: `schema` and `evidence` (ADR-019 D5) -------------------------------------------
# Both are optional, because a schema-1 record is still valid and is counted as a burn-down. A
# record that DECLARES them has to mean them: a citation to a file that is missing, or that sits
# outside the evidence directory, is a claim nobody can check. The escape case matters most —
# `../locale/ui-labels.json` would let a record cite the very file whose claims it backs.
case("a record without schema or evidence is still valid",
     problems(record()) == [], f"{problems(record())!r}")

bad = problems(record(schema=3))
case("an unknown schema is rejected", any("schema" in b for b in bad), f"{bad!r}")

bad = problems(record(evidence=["evidence/does-not-exist.json"]))
case("evidence that does not exist is rejected", any("does not exist" in b for b in bad), f"{bad!r}")

bad = problems(record(evidence=["../locale/ui-labels.json"]))
case("evidence outside the evidence directory is rejected",
     any("outside" in b for b in bad), f"{bad!r}")

bad = problems(record(evidence="evidence/one.json"))
case("evidence that is not a list is rejected", any("must be a list" in b for b in bad), f"{bad!r}")

case("an empty evidence list is fine — it claims nothing",
     problems(record(schema=2, evidence=[])) == [], f"{problems(record(schema=2, evidence=[]))!r}")

# ...and not by a symlink. A lexical containment check passes `evidence/link.json` while it resolves
# anywhere on disk. Driven against a temporary DIR so the real tree is never written to, and with a
# positive control first — an escape case that cannot see legitimate evidence would pass under a
# broken implementation for a reason that has nothing to do with escaping.
_saved_dir = G.DIR
_sandbox = Path(tempfile.mkdtemp()).resolve()
(_sandbox / "evidence").mkdir()
(_sandbox / "outside").mkdir()
(_sandbox / "evidence" / "real.json").write_text("[]", encoding="utf-8")
(_sandbox / "outside" / "planted.json").write_text("[]", encoding="utf-8")
G.DIR = str(_sandbox)
try:
    ok = problems(record(schema=2, evidence=["evidence/real.json"]))
    case("evidence under evidence/ is accepted", ok == [],
         f"the escape case below would pass vacuously otherwise: {ok!r}")
    try:
        (_sandbox / "evidence" / "link.json").symlink_to(_sandbox / "outside" / "planted.json")
        bad = problems(record(schema=2, evidence=["evidence/link.json"]))
        case("evidence cannot escape by symlink", any("outside" in b for b in bad), f"{bad!r}")
    except OSError:
        pass          # a filesystem without symlinks cannot host the attack either
finally:
    G.DIR = _saved_dir

print()
print(f"FAILED ({failed} unexpected)" if failed else "all cases behaved (0 unexpected)")
sys.exit(1 if failed else 0)
