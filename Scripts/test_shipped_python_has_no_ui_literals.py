#!/usr/bin/env python3
"""Drive `Scripts/check-shipped-python-has-no-ui-literals.py` at a helper that spells a label.

The guard exists because `logic_bounce_ui.py` carried six hand-typed English-and-Korean tables in
a file the installer SHIPS, and every locale rule in this repository scanned somewhere else. These
cases drive the ENTRY POINT, because a guard is its entry point -- and because the first thing this
guard did when it was pointed at the real tree was find four literals the author had missed.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "check-shipped-python-has-no-ui-literals.py")
INSTALLER = ('#!/bin/bash\n'
             'install_optional_release_asset 0755 "$X" "$SHARE_DIR/logic_fixture.py"\n')

failures = []


def check(name, condition, detail=""):
    if not condition:
        failures.append(f"{name}: {detail}")


def run(helper_source, installer=INSTALLER):
    """Write an installer that names one helper, write that helper, run the guard over both."""
    with tempfile.TemporaryDirectory() as root:
        scripts = os.path.join(root, "Scripts")
        os.makedirs(scripts)
        install = os.path.join(scripts, "install.sh")
        with open(install, "w", encoding="utf-8") as handle:
            handle.write(installer)
        if helper_source is not None:
            with open(os.path.join(scripts, "logic_fixture.py"), "w", encoding="utf-8") as handle:
                handle.write(helper_source)
        proc = subprocess.run([sys.executable, GUARD], capture_output=True, text=True,
                              env=dict(os.environ, LPM_INSTALL_SCRIPT=install,
                                       LPM_SCRIPTS_DIR=scripts))
        return proc.returncode, proc.stdout + proc.stderr


def main() -> int:
    # A shipped helper spelling a Korean label is the whole defect.
    rc, out = run('LABELS = ("바운스",)\n')
    check("a Hangul literal in a shipped helper is refused", rc == 1, f"exit {rc}: {out[:200]}")
    check("and the literal is named", "바운스" in out, out[:200])

    for script, name in (("カナ", "kana"), ("音楽", "Han")):
        rc, out = run(f'LABELS = ("{script}",)\n')
        check(f"a {name} literal is refused", rc == 1, f"exit {rc}: {out[:200]}")

    # AN ESCAPE IS THE SAME LABEL. A rule that reads raw bytes does not know that, and an outside
    # review used exactly that spelling to put a hardcoded Korean label past a different guard.
    rc, out = run('LABELS = ("\\uBBF9\\uC11C",)\n')
    check("a label written as escapes is refused", rc == 1, f"exit {rc}: {out[:200]}")
    check("and is reported as the label it is", "믹서" in out, out[:200])

    # The control. Without it every case above passes on a guard that refuses everything.
    rc, out = run('from logic_ui_labels import BOUNCE_CONFIRM_BUTTONS\nLABELS = BOUNCE_CONFIRM_BUTTONS\n')
    check("a helper that imports its labels passes", rc == 0, f"exit {rc}: {out[:200]}")

    # Latin text is not this guard's business: `pcm` and `audio tail` are correct in a shipped
    # table because Apple does not translate them.
    rc, out = run('MARKERS = ("pcm", "audio tail")\n')
    check("an untranslated Latin literal is left alone", rc == 0, f"exit {rc}: {out[:200]}")

    # A comment is not code.
    rc, out = run('# the Korean label is 바운스\nLABELS = ()\n')
    check("a label in a comment is not a finding", rc == 0, f"exit {rc}: {out[:200]}")

    # THE GENERATED MODULE IS THE ONE FILE THAT MUST CARRY THEM.
    rc, out = run('LABELS = ("바운스",)\n',
                  installer='install_optional_release_asset "$X" "$S/logic_ui_labels.py"\n')
    check("the generated module is exempt", rc == 0, f"exit {rc}: {out[:200]}")

    # An installer naming no helper cannot be checked, and must say so rather than pass.
    rc, out = run(None, installer="#!/bin/bash\necho nothing\n")
    check("an installer that ships no helper is refused", rc == 1, f"exit {rc}: {out[:200]}")
    check("and says the expectation would be empty", "nothing to check" in out, out[:200])

    # The real tree.
    proc = subprocess.run([sys.executable, GUARD], capture_output=True, text=True)
    check("the repository's own shipped helpers pass", proc.returncode == 0,
          (proc.stdout + proc.stderr)[:300])

    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1
    print("13 case(s) pass: a helper the installer ships cannot spell Logic's interface itself")
    return 0


if __name__ == "__main__":
    sys.exit(main())
