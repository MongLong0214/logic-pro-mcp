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
case("reporting how many of how many", "of 195" in _r.stdout, _r.stdout.strip()[:200])

print()
print(f"FAILED ({failed} unexpected)" if failed
      else "all cases behaved: the census is complete, and it can only shrink")
sys.exit(1 if failed else 0)
