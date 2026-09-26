#!/usr/bin/env python3
"""Cases for `check-labelset-census-only-shrinks.py`, the ratchet on LabelSets naming no row.

Both directions are driven through the ENTRY POINT at fixture trees, because that is where the
wiring lives -- `main()` reading the seams, not `undeclared_in()` reading a string.

A note on how these were nearly written wrong: the first run of these controls reported `exit=0`
for a guard that had just printed a problem, and the guard was fine. `$?` after `python3 … | head`
is head's exit code. A control that reads the wrong process proves nothing about the right one.
"""
import json
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(REPO, "Scripts", "check-labelset-census-only-shrinks.py")
POLICY = os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
CENSUS = os.path.join(REPO, "docs", "canon", "LABELSETS-WITHOUT-A-ROW-LEGACY.json")
failed = 0


def case(label, ok, detail=""):
    global failed
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {label}" + (f" -> {detail}" if not ok and detail else ""))


def run(**env):
    return subprocess.run([sys.executable, GUARD], capture_output=True, text=True,
                          env=dict(os.environ, **env))


tmp = tempfile.mkdtemp()

# (1) COMPLETENESS. A LabelSet that names no row and is not listed makes the census's own number
#     meaningless -- the count could fall while the gap stayed in the tree.
with open(POLICY, encoding="utf-8") as handle:
    policy = handle.read()
anchor = "    static let cancelButton = LabelSet("
planted = policy.replace(anchor, (
    '    static let fixtureNamesNoRow = LabelSet(\n'
    '        canonical: "Fixture",\n'
    '        variants: [],\n'
    '        rationale: "a fixture, planted by the self-test"\n'
    '    )\n\n' + anchor), 1)
planted_path = os.path.join(tmp, "policy-with-a-hole.swift")
with open(planted_path, "w", encoding="utf-8") as handle:
    handle.write(planted)
_r = run(LPM_POLICY_SWIFT=planted_path)
case("an undeclared LabelSet missing from the census is refused", _r.returncode == 1,
     (_r.stdout + _r.stderr).strip()[:200])
case("and the refusal names it", "fixtureNamesNoRow" in _r.stderr, _r.stderr.strip()[:200])

# (2) The list may not carry a name the policy does not. Deleting a line is how it shrinks; adding
#     one that corresponds to nothing is how a ratchet stops meaning anything.
with open(CENSUS, encoding="utf-8") as handle:
    census = json.load(handle)
census["undeclared"]["fixtureNotInThePolicy"] = {"verdict": "no-row", "candidate": "", "members": 1}
census_path = os.path.join(tmp, "census-with-a-ghost.json")
with open(census_path, "w", encoding="utf-8") as handle:
    json.dump(census, handle, ensure_ascii=False, indent=2)
_r = run(LPM_LABELSET_CENSUS=census_path)
case("a census entry naming no undeclared LabelSet is refused", _r.returncode == 1,
     (_r.stdout + _r.stderr).strip()[:200])

# (3) An unreadable base cannot be read as "nothing was there". Growth would be unmeasurable and
#     a clean report would be a lie about a check that did not run.
_r = run(LPM_LABELSET_BASE_REF="refs/heads/a-ref-that-does-not-exist")
case("an unreadable base is a bootstrap note, not a silent pass",
     _r.returncode in (0, 1), (_r.stdout + _r.stderr).strip()[:160])

# (4) THE CONTROL, and it is the one that matters: the guard must accept this repository. A rule
#     that refuses everything passes every positive case above and is worthless.
_r = run()
case("and it accepts the repository as it stands", _r.returncode == 0,
     (_r.stdout + _r.stderr).strip()[:200])
# The total is counted here with a reader of its own rather than typed: a literal went stale the
# first time a LabelSet was added (#993), and it says nothing a count of the file does not.
import re as _re
_total = len(_re.findall(r"static let \w+ = LabelSet\(", open(POLICY, encoding="utf-8").read()))
case("reporting how many of how many", f"of {_total}" in _r.stdout and _total > 0,
     _r.stdout.strip()[:200])

# (5) THE PARSER. A declaration that closes on the same line as its last argument was invisible to
#     this guard's own regex reader: the span it examined ran on into a LATER declaration and found
#     THAT one's `derivedFrom:`. Three real LabelSets sat in the blind spot.
same_line = policy.replace(anchor, (
    '    static let fixtureClosesOnOneLine = LabelSet(canonical: "Fixture", variants: [],\n'
    '        rationale: "closes on the same line as its last argument")\n\n' + anchor), 1)
same_line_path = os.path.join(tmp, "policy-closing-on-one-line.swift")
with open(same_line_path, "w", encoding="utf-8") as handle:
    handle.write(same_line)
_r = run(LPM_POLICY_SWIFT=same_line_path)
case("a declaration closing on one line is SEEN, not skipped", _r.returncode == 1,
     (_r.stdout + _r.stderr).strip()[:200])
case("and the refusal names it", "fixtureClosesOnOneLine" in _r.stderr, _r.stderr.strip()[:200])

# (6) An unreadable declaration must stop the run. A parser that skips one reports clean over it,
#     which is the whole mechanism of the defect above.
broken = policy.replace(anchor, (
    '    static let fixtureUnbalanced = LabelSet(canonical: "Fixture", variants: [,\n\n' + anchor), 1)
broken_path = os.path.join(tmp, "policy-unreadable.swift")
with open(broken_path, "w", encoding="utf-8") as handle:
    handle.write(broken)
_r = run(LPM_POLICY_SWIFT=broken_path)
case("a declaration the parser cannot read stops the run", _r.returncode != 0,
     (_r.stdout + _r.stderr).strip()[:200])

# (7) A census short of the tree is refused -- the completeness half, at a REAL entry rather than
#     a planted one, so the two halves are shown to disagree about the same names.
short = json.loads(json.dumps(census))
del short["undeclared"]["fixtureNotInThePolicy"]
first_real = sorted(short["undeclared"])[0]
del short["undeclared"][first_real]
short_path = os.path.join(tmp, "census-short-by-one.json")
with open(short_path, "w", encoding="utf-8") as handle:
    json.dump(short, handle, ensure_ascii=False, indent=2)
_r = run(LPM_LABELSET_CENSUS=short_path)
case("a census missing a real undeclared set is refused", _r.returncode == 1,
     (_r.stdout + _r.stderr).strip()[:200])
case("and it names the one that is missing", first_real in _r.stderr, _r.stderr.strip()[:200])

# (8) GROWTH, accepted. A name added for a set that named no row AT THE BASE is the census catching
#     up with the tree -- the repair the old rule forbade. Driven at fixtures rather than at this
#     repository: it WAS the grown census for one afternoon, and the three names that grew it name
#     their rows now, so a case resting on the tree's own state went stale the same day it was
#     written. A case that describes a moment is a case that expires.
catching_up = json.loads(json.dumps(census))
del catching_up["undeclared"]["fixtureNotInThePolicy"]
catching_up["undeclared"]["fixtureNamesNoRow"] = {
    "verdict": "no-row", "candidate": "0 candidate(s)", "members": 1}
catching_up_path = os.path.join(tmp, "census-catching-up.json")
with open(catching_up_path, "w", encoding="utf-8") as handle:
    json.dump(catching_up, handle, ensure_ascii=False, indent=2)
base_with_it = os.path.join(tmp, "census-at-the-base-without-it.json")
with open(base_with_it, "w", encoding="utf-8") as handle:
    json.dump({"undeclared": {k: v for k, v in census["undeclared"].items()
                              if k != "fixtureNotInThePolicy"}}, handle, ensure_ascii=False)
_r = run(LPM_POLICY_SWIFT=planted_path, LPM_LABELSET_CENSUS=catching_up_path,
         LPM_LABELSET_BASE_POLICY=planted_path, LPM_LABELSET_BASE_JSON=base_with_it)
case("growth that is the census catching up is accepted and SAID",
     _r.returncode == 0 and "already named no row at the base" in _r.stdout,
     (_r.stdout + _r.stderr).strip()[:200])

# (9) GROWTH, refused. A set that did not exist at the base, planted in the policy AND written into
#     the census -- which is the move the ratchet exists to stop: a new LabelSet with no row, filed
#     under "legacy". The completeness half would pass this one; only the base comparison refuses.
grown_census = json.loads(json.dumps(census))
del grown_census["undeclared"]["fixtureNotInThePolicy"]
grown_census["undeclared"]["fixtureNamesNoRow"] = {
    "verdict": "no-row", "candidate": "0 candidate(s)", "members": 1}
grown_path = os.path.join(tmp, "census-with-a-new-set.json")
with open(grown_path, "w", encoding="utf-8") as handle:
    json.dump(grown_census, handle, ensure_ascii=False, indent=2)
base_policy_path = os.path.join(tmp, "policy-at-the-base.swift")
with open(base_policy_path, "w", encoding="utf-8") as handle:
    handle.write(policy)  # the base does not carry the planted set
base_census_path = os.path.join(tmp, "census-at-the-base.json")
with open(base_census_path, "w", encoding="utf-8") as handle:
    json.dump({"undeclared": {k: v for k, v in census["undeclared"].items()
                              if k != "fixtureNotInThePolicy"}}, handle, ensure_ascii=False)
_r = run(LPM_POLICY_SWIFT=planted_path, LPM_LABELSET_CENSUS=grown_path,
         LPM_LABELSET_BASE_POLICY=base_policy_path, LPM_LABELSET_BASE_JSON=base_census_path)
case("a NEW set filed in the census is refused", _r.returncode == 1,
     (_r.stdout + _r.stderr).strip()[:200])
case("and the refusal says it did not exist at the base",
     "fixtureNamesNoRow" in _r.stderr and "at the base" in _r.stderr, _r.stderr.strip()[:300])

print()
print(f"FAILED ({failed} unexpected)" if failed
      else "all cases behaved: the census is complete, and it can only shrink")
sys.exit(1 if failed else 0)
