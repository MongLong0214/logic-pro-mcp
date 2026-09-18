#!/usr/bin/env python3
"""Drive `Scripts/check-registry-metadata-matches-the-release.py` at each disagreement it must find.

Both fields are checked separately, because the drift that prompted this froze BOTH of them at
3.15.0 while the Formula moved to 3.16.0 -- and a guard that reads one of two copies is how the
other copy keeps drifting. Each case moves exactly one field and expects exactly that complaint,
so neither check can be standing in for the other.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "check-registry-metadata-matches-the-release.py")
PUBLISHER = "io.modelcontextprotocol.registry/publisher-provided"

_spec = importlib.util.spec_from_file_location("check_registry_metadata", GUARD)
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)

failures = []


def check(name, condition, detail=""):
    if not condition:
        failures.append(f"{name}: {detail}")


def run(version="3.16.0", release_tag="v3.16.0", formula='  version "3.16.0"',
        with_release=True, server_json=None):
    """Write a server.json and a Formula into a temp dir and return the guard's problems."""
    with tempfile.TemporaryDirectory() as root:
        sj = os.path.join(root, "server.json")
        fm = os.path.join(root, "logic-pro-mcp.rb")
        if server_json is None:
            distribution = {"status": "metadata-only"}
            if with_release:
                distribution["release"] = ("https://github.com/MongLong0214/logic-pro-mcp/"
                                           f"releases/tag/{release_tag}")
            server_json = {"name": "io.github.x/y", "version": version,
                           "_meta": {PUBLISHER: {"distribution": distribution}}}
        with open(sj, "w", encoding="utf-8") as handle:
            json.dump(server_json, handle)
        with open(fm, "w", encoding="utf-8") as handle:
            handle.write(f'class LogicProMcp < Formula\n{formula}\n  sha256 "aa"\nend\n')
        return guard.check(sj, fm)


def main() -> int:
    check("agreement passes", run() == [], str(run()))

    # Each field alone. v3.16.0 shipped with both stale; if one check were doing the work of
    # both, one of these two cases would be green.
    problems = run(version="3.15.0")
    check("a stale `.version` is caught", len(problems) == 1, str(problems))
    check("and is named as the version", problems and "declares version" in problems[0],
          str(problems))

    problems = run(release_tag="v3.15.0")
    check("a stale release URL is caught", len(problems) == 1, str(problems))
    check("and is named as the URL", problems and "distribution.release" in problems[0],
          str(problems))

    # Both, which is what actually happened.
    problems = run(version="3.15.0", release_tag="v3.15.0")
    check("the real v3.16.0 drift is caught as two problems", len(problems) == 2, str(problems))

    # A near miss: the tag segment must match exactly, not merely start the same way.
    check("v3.16.0-rc.1 is not accepted as v3.16.0", run(release_tag="v3.16.0-rc.1") != [],
          "a prerelease tag passed as the release tag")
    check("v3.16.01 is not accepted as v3.16.0", run(release_tag="v3.16.01") != [],
          "a longer tag with the same prefix passed")

    # The guard must refuse to judge rather than pass when it cannot read its expectation. A
    # Formula whose shape changed yields no version, and comparing against None would make
    # every server.json wrong rather than making the guard honest.
    problems = run(formula="  # no version line here")
    check("a Formula with no version line is CANNOT DETERMINE", len(problems) == 1, str(problems))
    check("and says so rather than blaming server.json",
          problems and "CANNOT DETERMINE" in problems[0], str(problems))

    # The field this guard watches could move. If it does, the guard must say it stopped
    # watching rather than quietly checking one field.
    problems = run(with_release=False)
    check("a missing distribution.release is caught", problems != [],
          "the guard passed a document with no release URL at all")
    check("and names the field it can no longer see",
          problems and "distribution.release" in problems[0], str(problems))

    # Prereleases are real: `release.yml` marks a tag containing `-` as a prerelease.
    check("a matching prerelease passes",
          run(version="3.17.0-rc.1", release_tag="v3.17.0-rc.1",
              formula='  version "3.17.0-rc.1"') == [], "a consistent prerelease was refused")

    # Through the real entry point, against the repository's own files. This is the case that
    # would have been red on `main` before this change.
    proc = subprocess.run([sys.executable, GUARD], capture_output=True, text=True)
    check("the repository's own server.json and Formula agree", proc.returncode == 0,
          f"exit {proc.returncode}: {proc.stderr.strip()[:300]}")

    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1
    print("14 case(s) pass: the registry record cannot name a release the Formula does not")
    return 0


if __name__ == "__main__":
    sys.exit(main())
