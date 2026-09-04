#!/usr/bin/env python3
"""Prove `Scripts/ci-verify-formula-sha.sh` can fail, without a network.

NOT covered here, stated rather than implied by silence: the network branch. Every case below hands
the rule a local sums file, which is the seam that makes an offline test possible and also means the
`gh release view` / `gh release download` path is never exercised. In particular the deliberate
exception — a version whose release is not published yet exits 0 with a loud line, so a release-prep
bump is not blocked — has no case here. It was verified by hand against the live repository
(2026-09-05: `version "9.99.0"` exits 0 and says so; the real version exits 0 and matches).

The guard exists because a hash was copied by hand and nothing compared the copy to the release it
named. A test that only ever sees the repository in its correct state would repeat that mistake one
level up, so every case below writes a Formula and a sums file and requires a specific exit code.
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

GUARD = Path(__file__).resolve().parent / "ci-verify-formula-sha.sh"
ASSET = "LogicProMCP-macOS-universal.tar.gz"
GOOD = "0776b0d257606460164b3e197f6542223c9d0657501f97e96f5f9a250b994788"
OTHER = "0a0e221cadb7f61b28b77c97ade70650d41ef09cee47394914030c2a66a1a45e"


def _formula(version, sha):
    return (f'class LogicProMcp < Formula\n'
            f'  version "{version}"\n'
            f'  on_macos do\n'
            f'    sha256 "{sha}"\n'
            f'  end\n'
            f'end\n')


def _run(formula_text, sums_text, sums_name="sums.txt"):
    """Run the guard over a written Formula and sums file; return (exit code, output)."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        formula = root / "logic-pro-mcp.rb"
        formula.write_text(formula_text, encoding="utf-8")
        sums = root / sums_name
        if sums_text is not None:
            sums.write_text(sums_text, encoding="utf-8")
        env = dict(os.environ, LPM_FORMULA_PATH=str(formula))
        proc = subprocess.run(["bash", str(GUARD), str(sums)],
                              capture_output=True, text=True, env=env)
        return proc.returncode, proc.stdout + proc.stderr


def main():
    failures = []

    def check(name, condition, detail):
        if not condition:
            failures.append(f"{name}: {detail}")

    sums = f"{GOOD}  {ASSET}\n"

    # 1. Agreement passes.
    rc, out = _run(_formula("3.15.0", GOOD), sums)
    check("agreement passes", rc == 0, f"exit {rc}: {out.strip()[:200]}")

    # 2. THE DEFECT: the previous release's hash left behind. This is #775 exactly.
    rc, out = _run(_formula("3.15.0", OTHER), sums)
    check("stale hash is caught", rc == 1, f"exit {rc}: {out.strip()[:200]}")
    check("stale hash names both hashes", OTHER in out and GOOD in out,
          f"the message must show what is pinned and what is published: {out.strip()[:200]}")

    # 3. The release publishes no such asset — the Formula names something that is not there.
    rc, out = _run(_formula("3.15.0", GOOD), f"{GOOD}  SomethingElse.tar.gz\n")
    check("missing asset is caught", rc == 1, f"exit {rc}: {out.strip()[:200]}")

    # 4. A Formula the rule cannot read is exit 2 — unparseable is not clean.
    rc, out = _run('class LogicProMcp < Formula\n  version "3.15.0"\nend\n', sums)
    check("no sha256 is exit 2", rc == 2, f"exit {rc}: {out.strip()[:200]}")

    rc, out = _run(f'class LogicProMcp < Formula\n  sha256 "{GOOD}"\nend\n', sums)
    check("no version is exit 2", rc == 2, f"exit {rc}: {out.strip()[:200]}")

    # 5. A sums file that is not there is exit 2, not a pass. "Could not ask" and "the answer was
    #    yes" being the same outcome is the shape of defect this guard exists to stop.
    rc, out = _run(_formula("3.15.0", GOOD), None)
    check("absent sums is not a pass", rc == 2, f"exit {rc}: {out.strip()[:200]}")

    # 6. A `*`-prefixed name, which shasum writes in binary mode, is the same asset.
    rc, out = _run(_formula("3.15.0", GOOD), f"{GOOD} *{ASSET}\n")
    check("binary-mode sums line is understood", rc == 0, f"exit {rc}: {out.strip()[:200]}")

    # 8. Two hashes means the rule would check one and ignore the other — refuse, do not half-check.
    two = (f'class LogicProMcp < Formula\n  version "3.15.0"\n'
           f'  on_macos do\n    sha256 "{GOOD}"\n  end\n'
           f'  on_arm do\n    sha256 "{OTHER}"\n  end\nend\n')
    rc, out = _run(two, sums)
    check("two hashes is exit 2", rc == 2, f"exit {rc}: {out.strip()[:200]}")

    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print("8 case(s) pass: the guard catches a stale hash and refuses what it cannot read")
    return 0


if __name__ == "__main__":
    sys.exit(main())
