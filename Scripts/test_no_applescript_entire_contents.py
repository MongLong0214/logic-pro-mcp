#!/usr/bin/env python3
"""Prove `Scripts/check-no-applescript-entire-contents.py` can fail.

If you MUTATION-TEST this — break the guard on purpose and check that a case reddens — clear the
bytecode cache between the mutation and the restore. Apple's python3 sets
`sys.pycache_prefix = ~/Library/Caches/com.apple.python`, so the `.pyc` lives outside the tree where
`find . -name __pycache__` will not show it, and the cache is keyed on (size, mtime). A mutation that
keeps the length — `contents` to `contentz`, say — restores to an identical size within the same
second, and the stale bytecode is reused: the restored guard keeps banning the mutated phrase and
the test keeps failing for a defect that is no longer in the source. Measured 2026-09-04; it cost a
confusing ten minutes.

    find ~/Library/Caches/com.apple.python -path '*<worktree>*' -name '*.pyc' -delete


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
# banned phrase and needs no exemption from the guard it tests.
#
# The phrase comes from the guard's own constant, and that is a trade rather than a free win: these
# cases follow `BANNED` wherever it goes, so they cannot catch the guard banning the WRONG phrase —
# change it to "hello" and every case below still passes. What they do catch is the guard failing to
# act on whatever it claims to ban, which is the failure that has actually happened here. The other
# half is covered by case 9, which runs the real entry point over the real repository, where the
# phrase is not parameterised.
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
        return ({str(p) for p, _, _ in found},
                {str(p) for p in unparsed},
                {(str(p), n) for p, n, _ in found})


def main():
    failures = []

    def check(name, condition, detail):
        if not condition:
            failures.append(f"{name}: {detail}")

    # 1. The defect itself, in Python, is caught.
    found, _, at = _scan({"Scripts/bad.py":
                      'S = "tell app X to count of (' + P + ' of window 1)"\n'})
    check("python literal", found == {"Scripts/bad.py"}, f"expected the file to be flagged, got {found}")

    # 2. The defect in a Swift multi-line AppleScript block is caught, and reported at the line the
    #    literal STARTS on — a multi-line block reported at its closing quotes would send a reader to
    #    the wrong place, which for a guard whose whole output is file:line is most of its value.
    swift = ('let s = """\n'
             'tell application "System Events"\n'
             '  count of (' + P + ' of window 1)\n'
             'end tell\n'
             '"""\n')
    found, _, at = _scan({"Sources/Bad.swift": swift})
    check("swift literal", found == {"Sources/Bad.swift"}, f"expected the file to be flagged, got {found}")
    check("swift line number", at == {("Sources/Bad.swift", 1)},
          f"expected the literal reported at line 1, got {at}")

    # 3. Prose about the defect is NOT caught — a comment in either language, and a docstring.
    quiet = {
        "Sources/Fine.swift": "// this used to walk " + P + ", which returns an empty list\n",
        "Scripts/fine.py": "# the old path walked " + P + " and read absence as a fact\n",
        "Scripts/fine_doc.py": '"""Explains why ' + P + ' is not used here."""\nX = 1\n',
    }
    found, _, at = _scan(quiet)
    check("prose is allowed", found == set(), f"expected no flags, got {found}")

    # 4. A docstring exemption must not swallow a real block that merely comes first in a function.
    sneaky = ('def go():\n'
              '    """Doc."""\n'
              '    return "count of (' + P + ' of window 1)"\n')
    found, _, at = _scan({"Scripts/sneaky.py": sneaky})
    check("docstring exemption is narrow", found == {"Scripts/sneaky.py"},
          f"expected the returned literal to be flagged, got {found}")

    # 5. A shell script reaching osascript is caught — `Scripts` has 25 of them and two evidence
    #    runners under docs/ already shell out to it, so leaving .sh unscanned would have been a
    #    hole the size of the ban.
    found, _, at = _scan({"Scripts/run.sh":
                      "osascript -e 'tell app \"X\" to count of (" + P + " of window 1)'\n"})
    check("shell script", found == {"Scripts/run.sh"}, f"expected the shell script flagged, got {found}")

    # 6. ...and a shell COMMENT about it is not.
    found, _, at = _scan({"Scripts/fine.sh": "# the old runner used " + P + ", which answers 0\n"})
    check("shell comment allowed", found == set(), f"expected no flags, got {found}")

    # 7. A file the parser cannot read is REPORTED, never cleared. Silence on an unreadable file is
    #    the same mistake the banned instrument makes.
    _, unparsed, _ = _scan({"Scripts/broken.py": 'S = "' + P + '"\ndef (\n'})
    check("unparsable is not cleared", unparsed == {"Scripts/broken.py"},
          f"expected the file to be reported as unparsed, got {unparsed}")

    # 8. A KNOWN BOUNDARY, asserted so it stays known. Assembling the phrase defeats the rule, and
    #    the guard's docstring says so. If someone closes this, this case fails and sends them to
    #    that paragraph — which is the point of pinning a miss rather than leaving it unmentioned.
    found, _, at = _scan({"Sources/Sneak.swift":
                      'let s = "count of (' + P[:6] + '" + "' + P[6:] + ' of window 1)"\n'})
    check("assembled phrase is a known miss", found == set(),
          f"the guard now catches an assembled phrase — good; update the boundary paragraph in "
          f"check-no-applescript-entire-contents.py and this case. got {found}")

    # 9. A bytes literal reaches osascript exactly like a text one and contains no str constant, so
    #    a str-only rule reads the file as clean with the phrase plainly in the source.
    found, _, _ = _scan({"Scripts/b.py":
                         'import subprocess\n'
                         'subprocess.run([b"osascript", b"-e", b"count of (' + P + ' of window 1)"])\n'})
    check("bytes literal", found == {"Scripts/b.py"}, f"expected the bytes payload flagged, got {found}")

    # 10. The guard bans the phrase it is supposed to ban. Every case above takes the phrase FROM the
    #     guard, so all of them would follow `BANNED` to a wrong value and stay green — this one is
    #     the independent statement of what the ban is for, assembled so it is not itself a use.
    check("bans the right phrase", guard.BANNED == "entire" + " " + "contents",
          f"the guard bans {guard.BANNED!r}, which is not the phrase this rule exists for")

    # 11. An escape that hides the space. `"entire\\x20contents"` carries the phrase only after the
    #     language decodes it, so a substring test on the file text skips the file before `ast` can
    #     see the constant — one literal, not the assembled form the rule documents as out of scope.
    #     Swift's `\\u{20}` is the same trick, and the Swift side has to decode to see it.
    found, _, _ = _scan({"Scripts/esc.py":
                         'subprocess.run(["osascript","-e","get ' + P[:6] + '\\x20' + P[7:] + ' of window 1"])\n'})
    check("python escaped space", found == {"Scripts/esc.py"}, f"expected the escape flagged, got {found}")

    found, _, _ = _scan({"Sources/Esc.swift":
                         'let s = "get ' + P[:6] + '\\u{20}' + P[7:] + ' of window 1"\n'})
    check("swift escaped space", found == {"Sources/Esc.swift"}, f"expected the escape flagged, got {found}")

    # 12. The real ENTRY POINT, not just `violations`, over the real repository. Every case above
    #    calls the rule directly, so a `main()` quietly changed to `return 0` would pass all of them.
    rc = subprocess.run([sys.executable, str(GUARD)], capture_output=True, text=True)
    check("repository is clean", rc.returncode == 0, f"guard exited {rc.returncode}: {rc.stdout.strip()}")

    # 13. ...and the same entry point over a tree with a planted violation must EXIT 1. This is the
    #     case that notices a gutted `main`; case 9 alone cannot tell "clean" from "always says yes".
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "Scripts").mkdir()
        (root / "Scripts" / "bad.py").write_text(
            'S = "count of (' + P + ' of window 1)"\n', encoding="utf-8")
        rc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
        check("entry point fails on a planted violation", rc.returncode == 1,
              f"guard exited {rc.returncode} over a tree containing the phrase: {rc.stdout.strip()[:200]}")

    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print(f"{15} case(s) pass: the guard catches the defect and leaves the prose alone")
    return 0


if __name__ == "__main__":
    sys.exit(main())
