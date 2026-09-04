#!/usr/bin/env python3
"""Prove `Scripts/check-no-applescript-entire-contents.py` can fail.

A guard that only ever passes is indistinguishable from a guard that cannot see. Each case below
plants the thing the rule is about and requires the guard to catch it, or plants the thing the rule
deliberately allows and requires the guard to stay quiet — the two halves together are what say the
rule has a shape rather than a verdict.
"""
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

GUARD = Path(__file__).resolve().parent / "check-no-applescript-entire-contents.py"

spec = importlib.util.spec_from_file_location("entire_contents_guard", GUARD)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


# The fixtures are ASSEMBLED rather than written out, so this file contains no literal carrying the
# banned phrase and needs no exemption from the guard it tests. Taking the phrase from the guard's
# own constant also means a change there cannot leave these cases quietly testing the wrong string.
P = guard.BANNED


def _scan(files):
    """Run the guard's rule over a throwaway tree and return the paths it flagged."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "Sources").mkdir()
        (root / "Scripts").mkdir()
        for name, body in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body, encoding="utf-8")
        found, unparsed = guard.violations(root)
        return {str(p) for p, _, _ in found}, {str(p) for p in unparsed}


def main():
    failures = []

    def check(name, condition, detail):
        if not condition:
            failures.append(f"{name}: {detail}")

    # 1. The defect itself, in Python, is caught.
    found, _ = _scan({"Scripts/bad.py":
                      'S = "tell app X to count of (' + P + ' of window 1)"\n'})
    check("python literal", found == {"Scripts/bad.py"}, f"expected the file to be flagged, got {found}")

    # 2. The defect in a Swift multi-line AppleScript block is caught, and reported at its own line.
    swift = ('let s = """\n'
             'tell application "System Events"\n'
             '  count of (' + P + ' of window 1)\n'
             'end tell\n'
             '"""\n')
    found, _ = _scan({"Sources/Bad.swift": swift})
    check("swift literal", found == {"Sources/Bad.swift"}, f"expected the file to be flagged, got {found}")

    # 3. Prose about the defect is NOT caught — a comment in either language, and a docstring.
    quiet = {
        "Sources/Fine.swift": "// this used to walk " + P + ", which returns an empty list\n",
        "Scripts/fine.py": "# the old path walked " + P + " and read absence as a fact\n",
        "Scripts/fine_doc.py": '"""Explains why ' + P + ' is not used here."""\nX = 1\n',
    }
    found, _ = _scan(quiet)
    check("prose is allowed", found == set(), f"expected no flags, got {found}")

    # 4. A docstring exemption must not swallow a real block that merely comes first in a function.
    sneaky = ('def go():\n'
              '    """Doc."""\n'
              '    return "count of (' + P + ' of window 1)"\n')
    found, _ = _scan({"Scripts/sneaky.py": sneaky})
    check("docstring exemption is narrow", found == {"Scripts/sneaky.py"},
          f"expected the returned literal to be flagged, got {found}")

    # 5. A shell script reaching osascript is caught — `Scripts` has 25 of them and two evidence
    #    runners under docs/ already shell out to it, so leaving .sh unscanned would have been a
    #    hole the size of the ban.
    found, _ = _scan({"Scripts/run.sh":
                      "osascript -e 'tell app \"X\" to count of (" + P + " of window 1)'\n"})
    check("shell script", found == {"Scripts/run.sh"}, f"expected the shell script flagged, got {found}")

    # 6. ...and a shell COMMENT about it is not.
    found, _ = _scan({"Scripts/fine.sh": "# the old runner used " + P + ", which answers 0\n"})
    check("shell comment allowed", found == set(), f"expected no flags, got {found}")

    # 7. A file the parser cannot read is REPORTED, never cleared. Silence on an unreadable file is
    #    the same mistake the banned instrument makes.
    _, unparsed = _scan({"Scripts/broken.py": 'S = "' + P + '"\ndef (\n'})
    check("unparsable is not cleared", unparsed == {"Scripts/broken.py"},
          f"expected the file to be reported as unparsed, got {unparsed}")

    # 8. A KNOWN BOUNDARY, asserted so it stays known. Assembling the phrase defeats the rule, and
    #    the guard's docstring says so. If someone closes this, this case fails and sends them to
    #    that paragraph — which is the point of pinning a miss rather than leaving it unmentioned.
    found, _ = _scan({"Sources/Sneak.swift":
                      'let s = "count of (' + P[:6] + '" + "' + P[6:] + ' of window 1)"\n'})
    check("assembled phrase is a known miss", found == set(),
          f"the guard now catches an assembled phrase — good; update the boundary paragraph in "
          f"check-no-applescript-entire-contents.py and this case. got {found}")

    # 9. The guard passes over the real repository, and its own BANNED definition does not trip it.
    rc = subprocess.run([sys.executable, str(GUARD)], capture_output=True, text=True)
    check("repository is clean", rc.returncode == 0, f"guard exited {rc.returncode}: {rc.stdout.strip()}")

    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print(f"{9} case(s) pass: the guard catches the defect and leaves the prose alone")
    return 0


if __name__ == "__main__":
    sys.exit(main())
