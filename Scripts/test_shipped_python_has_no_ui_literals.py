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

# ── The corpus rule: a Latin-script Logic label is a label, whatever script it is in ──────────
#
# The CJK rule catches Korean, Japanese and Chinese by their characters and is blind to the five
# languages Logic writes in Latin script. #919 was the Korean-and-English half of that defect; the
# limit recorded on it said the corpus was what closing the other half would take.
#
# The predicate had to be corrected once and the correction is the point: `is_translated` is keyed
# by the ENGLISH value, so it answers False for `Bouncen` -- the translation rather than the thing
# translated -- and a rule that cannot see a German label is no rule. What it asks now is whether
# the literal is a value Apple ships in ANY locale, proved against the committed absence sets.
import subprocess as _sp
import tempfile as _tf

_GUARD = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "check-shipped-python-has-no-ui-literals.py")


def _at(helper_source: str):
    """Run the guard's ENTRY POINT at a fixture tree, through the installer seam."""
    tmp = _tf.mkdtemp()
    os.makedirs(os.path.join(tmp, "s"), exist_ok=True)
    with open(os.path.join(tmp, "s", "logic_fixture.py"), "w", encoding="utf-8") as handle:
        handle.write(helper_source)
    with open(os.path.join(tmp, "install.sh"), "w", encoding="utf-8") as handle:
        handle.write("install logic_fixture.py\n")
    return _sp.run([sys.executable, _GUARD], capture_output=True, text=True,
                   env=dict(os.environ, LPM_INSTALL_SCRIPT=os.path.join(tmp, "install.sh"),
                            LPM_SCRIPTS_DIR=os.path.join(tmp, "s")))


_bad = _at('BOUNCE = "Bouncen"\n')
case("a German Logic label in a shipped helper is refused",
     _bad.returncode == 1 and "Bouncen" in _bad.stderr,
     (_bad.stdout + _bad.stderr).strip()[:200])
case("and the refusal names the locale whose corpus holds it",
     "strings/de" in _bad.stderr, _bad.stderr.strip()[:200])

# The control, and it must pass for the RIGHT reason: `pcm` is absent from every corpus, which is
# the same derivation `locale_labels.py` uses to exempt it. A control that passes because the rule
# refuses nothing proves nothing.
_ok = _at('MARKERS = ("pcm", "audio tail")\n')
case("a literal Apple ships in no locale is not a finding",
     _ok.returncode == 0, (_ok.stdout + _ok.stderr).strip()[:200])

# A dict KEY is a protocol key, not a label. Measured: aiming the rule at the real tree produced
# five findings and every one was `'name'` in key position, because Apple ships a string spelled
# `name` somewhere in 605,190 entries. Length cannot separate those -- `Save` is four characters
# and so is `name` -- but position can.
_key = _at('RESULT = {"name": 1, "text": 2}\n')
case("a literal in key position is not a label",
     _key.returncode == 0, (_key.stdout + _key.stderr).strip()[:200])

# An exemption covers its own literal in its own expression, never the line. Same shape as #891.
_both = _at('BOUNCE = "Bouncen"\nSTATE = {"status": "error"}\n')
case("an exempt protocol value does not silence a real label beside it",
     _both.returncode == 1 and "Bouncen" in _both.stderr,
     (_both.stdout + _both.stderr).strip()[:200])
