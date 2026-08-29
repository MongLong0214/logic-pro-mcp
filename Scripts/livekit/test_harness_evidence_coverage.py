#!/usr/bin/env python3
"""Prove the #612 coverage rule against the cases it exists to refuse.

The defect it answers is a quiet one: a branch carrying two harnesses, one document on disk, and a
gate that reports `ok`. So the cases below are mostly runs where SOMETHING is present — the failure
never looked like an absence.

    python3 test_harness_evidence_coverage.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness_evidence_coverage as C  # noqa: E402

failed = 0

# --- which paths count as a changed harness ----------------------------------------------------
#
# `Scripts/livekit/` and nothing else. A `live_*.py` elsewhere in the tree is not a live harness,
# and `evidence.py` beside them is not one either — the rule is the directory plus the prefix, and
# both halves are asserted so neither can be dropped without a case going red.
for paths, expected, why in [
    (["Scripts/livekit/live_544_output_schema.py"], {"live_544_output_schema"}, "one harness"),
    (["Scripts/livekit/live_a.py", "Scripts/livekit/live_b.py"], {"live_a", "live_b"}, "two"),
    (["Scripts/livekit/evidence.py"], set(), "the library beside them is not a harness"),
    (["Scripts/livekit/session_519_locale_flow.py"], set(), "a session script is not a harness"),
    (["Tests/live_thing.py"], set(), "live_ prefix outside the directory"),
    (["Scripts/live_544.py"], set(), "one directory up is not the directory"),
    (["Sources/LogicProMCP/Server/LogicProTarget.swift"], set(), "product code names no harness"),
    ([], set(), "nothing changed"),
    (None, set(), "no diff at all"),
]:
    got = C.harness_stems(paths)
    ok = got == expected
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {str(paths)[:52]:<54} -> {sorted(got)} {why}")

# --- the verdict --------------------------------------------------------------------------------
#
# Through the REAL `E.summarize` and `E.is_clean`, not a copy of the predicate: a test that
# reimplements the rule agrees with itself no matter what the code says.
CLEAN = {"records": [
    {"kind": "check", "passed": True, "mutation_claimed": True},
    {"kind": "capture", "settled": True, "display": {"wholly_within": True}},
    {"kind": "visual", "passed": True, "subject": "Tracks header", "region": [0, 0, 1, 1]},
    {"kind": "recording"},
    {"kind": "operation"},
]}
# A visual that FAILED, which `is_clean` has always refused. Deliberately not a subject-less one:
# that clause is newer, and a case here that depends on it would make this file's verdict a
# statement about which other change has landed rather than about this rule.
UNCLEAN = {"records": [dict(r) for r in CLEAN["records"]]}
UNCLEAN["records"][2] = {"kind": "visual", "passed": False, "subject": "Tracks header",
                         "region": [0, 0, 1, 1]}

DOCS = {
    "/e/live_a.evidence.json": CLEAN,
    "/e/live_b.evidence.json": UNCLEAN,
    "/e/live_broken.evidence.json": None,      # on disk, unreadable
}
PRESENT = {
    "live_a": "/e/live_a.evidence.json",
    "live_b": "/e/live_b.evidence.json",
    "live_broken": "/e/live_broken.evidence.json",
}

for required, present, exp_missing, exp_unclean, why in [
    ({"live_a"}, PRESENT, [], [], "one harness, its own clean document"),
    ({"live_a", "live_b"}, PRESENT, [], ["live_b"], "the second document is not clean"),
    # THE defect: two harnesses changed, one document on disk. Before #612 the gate read a single
    # file per head and called this covered.
    ({"live_a", "live_c"}, {"live_a": "/e/live_a.evidence.json"}, ["live_c"], [],
     "two changed, one proved — the case this check exists for"),
    ({"live_broken"}, PRESENT, [], ["live_broken"],
     "unreadable is UNCLEAN, not missing — it ran and produced something unusable"),
    ({"live_a"}, {}, ["live_a"], [], "nothing on disk at all"),
    (set(), PRESENT, [], [], "no harness changed, nothing required"),
]:
    missing, unclean = C.verdict(required, present, read_document=lambda p: DOCS.get(p))
    ok = missing == exp_missing and unclean == exp_unclean
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} required={sorted(required)!s:<28} "
          f"missing={missing} unclean={unclean}  {why}")

# --- `evidence.json` must not satisfy anything --------------------------------------------------
#
# The legacy single-file name is the last run at this head whatever wrote it. Counting it would let
# one harness's document stand in for another's, which is the whole defect wearing a new name.
#
# Against a REAL directory. The first version of this block asserted on `documents_present`'s
# DOCSTRING and then drove `verdict` with a hand-built dict — so widening the glob to `*.json` left
# the whole suite green, which is the mutation this case exists to catch. A test that never calls
# the function cannot see what the function does.
import tempfile

with tempfile.TemporaryDirectory() as head_dir:
    for name in ["live_a.evidence.json",       # a harness document
                 "evidence.json",              # the legacy last-run-wins name
                 "live_a.evidence.1.json",     # a ROTATED earlier run of live_a
                 "notes.json"]:                # something else entirely
        open(os.path.join(head_dir, name), "w").write("{}")
    found = C.documents_present(head_dir)
    ok = set(found) == {"live_a"}
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} a real directory yields {sorted(found)} "
          f"— not the legacy name, not a rotated run, not an unrelated file")

got = C.verdict({"live_a"}, {"evidence": "/e/evidence.json"}, read_document=lambda p: CLEAN)
ok = got == (["live_a"], [])
failed += 0 if ok else 1
print(f"{'ok  ' if ok else 'FAIL'} a document named `evidence` satisfies no harness -> {got}")

# --- `changed_paths` against a REAL repository -------------------------------------------------
#
# Two contracts were written in a docstring and tested nowhere, which is the same shape as the
# defect this whole file is about — a rule named in one place and enforced in another.
#
#   1. deletions are excluded. A harness that no longer exists cannot be required to have run, and
#      requiring it would make deleting a harness impossible: the branch can never produce the
#      evidence, because there is nothing left to produce it.
#   2. the commit asked about is the `head` ARGUMENT, not the worktree's HEAD. The first version
#      hard-coded HEAD and took the sha only to find an evidence directory. In a pre-push hook the
#      two agree and it would never have shown.
import subprocess

def _git(repo, *args):
    return subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)

with tempfile.TemporaryDirectory() as repo:
    os.makedirs(os.path.join(repo, "Scripts", "livekit"))
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "t@example.invalid")
    _git(repo, "config", "user.name", "t")

    def write(rel, text):
        with open(os.path.join(repo, rel), "w") as fh:
            fh.write(text)

    write("Scripts/livekit/live_kept.py", "# kept\n")
    write("Scripts/livekit/live_doomed.py", "# doomed\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "base")
    base_sha = _git(repo, "rev-parse", "HEAD").stdout.strip()

    write("Scripts/livekit/live_added.py", "# added\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "add one harness")
    mid_sha = _git(repo, "rev-parse", "HEAD").stdout.strip()

    os.remove(os.path.join(repo, "Scripts/livekit/live_doomed.py"))
    write("Scripts/livekit/live_kept.py", "# kept, edited\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "delete one harness, edit another")
    tip_sha = _git(repo, "rev-parse", "HEAD").stdout.strip()

    at_tip = C.harness_stems(C.changed_paths(repo, base_sha, tip_sha))
    ok = at_tip == {"live_added", "live_kept"}
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} a deleted harness is not required to have run -> {sorted(at_tip)}")

    # The worktree is sitting on `tip`. Asking about `mid` must answer about `mid`.
    at_mid = C.harness_stems(C.changed_paths(repo, base_sha, mid_sha))
    ok = at_mid == {"live_added"}
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} the head ARGUMENT decides, not the worktree's HEAD -> {sorted(at_mid)}")

    ok = C.changed_paths(repo, "no/such/ref", tip_sha) is None
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} an unreadable base is None, not an empty change set")

# --- declarations: which harness a Sources/ change obliges ------------------------------------
#
# The hole these close: before 2026-08-29 a `Sources/` change required NO particular harness, so
# any clean document satisfied any change.

DECL = {"live_atlas": ["Sources/LogicProMCP/SelectorAtlas/"],
        "live_eq": ["Sources/LogicProMCP/SpectralEQ/"]}
# The same claim written without its trailing slash. It must mean the same thing, or a typo
# silently widens a harness's claim into every sibling whose name starts the same way.
DECL_NO_SLASH = {"live_atlas": ["Sources/LogicProMCP/SelectorAtlas"]}

for label, changed, want_required, want_unproven in [
    ("a claimed path obliges its claimant",
     ["Sources/LogicProMCP/SelectorAtlas/AtlasDiff.swift"], {"live_atlas"}, []),
    ("a path nobody claims is unproven, not proved",
     ["Sources/LogicProMCP/Channels/AccessibilityChannel.swift"], set(),
     ["Sources/LogicProMCP/Channels/AccessibilityChannel.swift"]),
    ("two subsystems oblige two harnesses",
     ["Sources/LogicProMCP/SelectorAtlas/A.swift", "Sources/LogicProMCP/SpectralEQ/B.swift"],
     {"live_atlas", "live_eq"}, []),
    ("non-Sources paths oblige nothing and are not unproven",
     ["docs/roadmap/README.md", "Tests/X.swift"], set(), []),
    ("a prefix must not match a sibling directory by string alone",
     ["Sources/LogicProMCP/SelectorAtlasExtras/C.swift"], set(),
     ["Sources/LogicProMCP/SelectorAtlasExtras/C.swift"]),
]:
    required, unproven = C.required_by_sources(changed, DECL)
    ok = required == want_required and unproven == want_unproven
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {label} -> required={sorted(required)} unproven={unproven}")

for label, decl, changed, want_required in [
    ("a slashless declaration still claims its own directory", DECL_NO_SLASH,
     ["Sources/LogicProMCP/SelectorAtlas/AtlasDiff.swift"], {"live_atlas"}),
    ("a slashless declaration does NOT claim a sibling that starts the same", DECL_NO_SLASH,
     ["Sources/LogicProMCP/SelectorAtlasExtras/C.swift"], set()),
    ("a declaration naming one file claims exactly it", {"live_x": ["Sources/A/B.swift"]},
     ["Sources/A/B.swift"], {"live_x"}),
    ("and not a file whose name extends it", {"live_x": ["Sources/A/B.swift"]},
     ["Sources/A/B.swift.orig"], set()),
]:
    required, _ = C.required_by_sources(changed, decl)
    ok = required == want_required
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {label} -> {sorted(required)}")

for label, text, want in [
    ("a literal list is read", "COVERS = ['Sources/A/']\n", ["Sources/A/"]),
    ("a computed declaration is refused", "P='Sources/'\nCOVERS = [P + 'A/']\n", []),
    ("a non-string member voids the whole claim", "COVERS = ['Sources/A/', 3]\n", []),
    ("no declaration is no claim", "x = 1\n", []),
    ("a file that does not parse claims nothing", "def (\n", []),
]:
    got = C.declared_coverage(text)
    ok = got == want
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {label} -> {got}")

print()
print(f"FAILED ({failed} unexpected)" if failed else "all cases behaved (0 unexpected)")
sys.exit(1 if failed else 0)
