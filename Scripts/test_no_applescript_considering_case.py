#!/usr/bin/env python3
"""Cases for `check-no-applescript-considering-case.py`.

The fixtures ASSEMBLE the banned phrase from pieces rather than spelling it, for the same reason
the sibling guard's suite does: a test for a banned phrase that contains the phrase is a finding.
That is also this guard's own blind spot, said out loud in its docstring — a literal rule sees
literals, and nothing here can see `"consider" + "ing case"`.
"""
import os
import subprocess
import sys
import tempfile

GUARD = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "check-no-applescript-considering-case.py")
PHRASE = "consider" + "ing " + "case"
failed = 0


def case(label, ok, detail=""):
    global failed
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {label}" + (f" -> {detail}" if not ok and detail else ""))


def at(source: str, name: str = "Fixture.swift"):
    tmp = tempfile.mkdtemp()
    root = os.path.join(tmp, "fx")
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, name), "w", encoding="utf-8") as handle:
        handle.write(source)
    return subprocess.run([sys.executable, GUARD], capture_output=True, text=True,
                          env=dict(os.environ, LPM_APPLESCRIPT_ROOTS=root))


bad = at(f'let s = "tell app to {PHRASE} end"\n')
case("a string literal carrying the phrase is refused", bad.returncode == 1,
     (bad.stdout + bad.stderr).strip()[:200])
case("and the refusal says what it costs — every language at once",
     "ten languages" in bad.stdout, bad.stdout.strip()[:200])

# The coexistence this guard exists to allow. `Scripts/locale_labels.py` carries the phrase in a
# comment explaining why the fold holds; refusing that would delete the explanation along with the
# defect, which is how a banned instrument comes back with nobody able to say why it was banned.
comment = at(f'// the fold holds unless a script says {PHRASE}\nlet s = "tell app"\n')
case("a comment naming the phrase is not a finding", comment.returncode == 0,
     (comment.stdout + comment.stderr).strip()[:200])

# The control that matters most: the guard must accept THIS repository. A rule that refuses
# everything passes the positive case and is useless.
real = subprocess.run([sys.executable, GUARD], capture_output=True, text=True)
case("and it accepts the repository as it stands", real.returncode == 0,
     (real.stdout + real.stderr).strip()[:200])

print()
print(f"FAILED ({failed} unexpected)" if failed else f"all cases behaved — {PHRASE!r} cannot reach "
      "AppleScript through a literal")
sys.exit(1 if failed else 0)
