#!/usr/bin/env python3
"""A Python helper the installer SHIPS must not spell Logic's interface itself.

WHY THIS EXISTS
---------------
`Scripts/install.sh` installs five Python helpers into the share directory beside the binary. They
are product, not harness -- and every locale rule in this repository was written as though none of
them existed: `check-policy-literals-against-canon.py` and `check-ax-comparisons-use-labelsets.py`
scan `Sources/` and `Scripts/livekit/`, `check-livekit-ui-literals.py` scans `Scripts/livekit/`,
and `ci-forbid-hardcoded-menu-bar-item.sh` scans `Sources/`.

So `logic_bounce_ui.py` drove Logic's Bounce dialog through six hand-typed English-and-Korean
tables for as long as it has existed, and the bounce flow worked in two of the ten languages Logic
ships. Nothing could see it (#919).

WHAT IT REFUSES
---------------
A string literal containing Hangul, kana or Han in a file `install.sh` installs. The set of files
is DERIVED from the installer rather than listed here, because a list would go stale the first time
somebody ships a sixth helper -- which is the failure this guard is downstream of.

Escapes are resolved first: `"\\u{BBF9}서"` is `믹서`, and a rule that reads raw bytes does not know
that. Python spells them `\\uBBF9`, so both forms are folded.

WHAT IT DOES NOT REFUSE
-----------------------
Latin-script labels. `pcm` and `audio tail` are in a shipped table and are correct there: Apple
does not translate them, so matching them by literal is locale-independent -- the same condition
that exempts `MIDI` from the AX-comparison rule. Catching those needs the corpus, and that guard
already exists for the scopes it covers; widening it is a bigger change than this one.

The vocabulary belongs in `AXLocalePolicy` and reaches these helpers through
`Scripts/logic_ui_labels.py`, which `Scripts/locale_labels.py --write` generates and the installer
ships beside them.

Exit: 0 = no shipped helper spells a label - 1 = one does
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
#: A seam, so the self-test can drive main() at a tree that must fail.
INSTALLER = os.environ.get("LPM_INSTALL_SCRIPT") or os.path.join(REPO, "Scripts", "install.sh")
SCRIPTS = os.environ.get("LPM_SCRIPTS_DIR") or os.path.join(REPO, "Scripts")

_CJK = re.compile(r"[\uac00-\ud7a3\u3040-\u309f\u30a0-\u30ff\u4e00-\u9fff]")
_LITERAL = re.compile(r"""(?<!\\)(['"])((?:(?!\1)[^\\\n]|\\.)*)\1""")
_ESCAPE = re.compile(r"\\u\{?([0-9A-Fa-f]{1,8})\}?")
#: The generated module is the one shipped file that MUST carry them -- it is the vocabulary.
GENERATED = "logic_ui_labels.py"


def shipped_helpers() -> list:
    """The `logic_*.py` files `install.sh` installs, read from the installer itself."""
    try:
        with open(INSTALLER, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        print(f"cannot read {INSTALLER}: {exc}", file=sys.stderr)
        return []
    return sorted(set(re.findall(r"logic_[a-z0-9_]+\.py", text)))


def _resolved(raw: str) -> str:
    def one(match):
        try:
            return chr(int(match.group(1), 16))
        except (ValueError, OverflowError):
            return match.group(0)
    return _ESCAPE.sub(one, raw)


def offenders() -> list:
    problems = []
    for name in shipped_helpers():
        if name == GENERATED:
            continue
        path = os.path.join(SCRIPTS, name)
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        for number, line in enumerate(source.split("\n"), 1):
            if line.lstrip().startswith("#"):
                continue
            for match in _LITERAL.finditer(line):
                text = _resolved(match.group(2))
                if text.strip() and _CJK.search(text):
                    problems.append(f"{name}:{number}: {text!r}")
    return problems


def main() -> int:
    helpers = shipped_helpers()
    if not helpers:
        print("install.sh names no logic_*.py helper, so this guard has nothing to check and an "
              "empty expectation would pass against anything.", file=sys.stderr)
        return 1
    problems = offenders()
    if problems:
        print(f"{len(problems)} interface literal(s) in a helper the installer SHIPS:",
              file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"\nThese files are installed beside the binary, so a label spelled here works in "
              f"whatever language it is written in. Add it to AXLocalePolicy, export it through "
              f"Scripts/locale_labels.py's SHIPPED_LABELS, and import {GENERATED}.",
              file=sys.stderr)
        return 1
    print(f"none of the {len(helpers)} shipped Python helper(s) spells a Logic label; the "
          f"vocabulary reaches them through {GENERATED}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
