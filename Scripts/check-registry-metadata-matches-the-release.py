#!/usr/bin/env python3
"""Fails when `server.json` names a different release than the Homebrew Formula does.

WHAT WENT WRONG
---------------
`server.json` is the record published to the MCP registry. It carries a version in two places --
`.version` and the `distribution.release` URL -- and nothing maintained either. v3.14.0 and v3.15.0
were correct because somebody remembered; v3.16.0 shipped with both still saying 3.15.0:

    tag        server.json    distribution.release    Formula
    v3.14.0    3.14.0         v3.14.0                 3.14.0
    v3.15.0    3.15.0         v3.15.0                 3.15.0
    v3.16.0    3.15.0         v3.15.0                 3.16.0   <- nothing noticed

The Formula is the version that is already tied to a real published artifact:
`ci-verify-formula-sha.sh` compares its `sha256` against the tarball attached to that release and
fails if they disagree. So pinning `server.json` to the Formula chains it to the same artifact --
release -> Formula (hash verified) -> registry record -- and the registry stops being the one
public surface with a version nobody checks.

WHY BOTH FIELDS
---------------
`publish-mcp.yml` used to rewrite `.version` from the release tag and leave the URL alone, so a
publish of version N would have advertised N and linked to N-1. `sync-server-json-version.py` now
writes both, and this checks both, because a check that reads one of two copies is how the second
copy drifts.

WHAT THIS DOES NOT CHECK
------------------------
That the registry actually HOLDS this record. It does not: the registry is nine releases behind,
because releases here are created by `github-actions[bot]` and GitHub does not start workflow runs
from `GITHUB_TOKEN` events, so `on: release` in `publish-mcp.yml` has never fired. That is fixed by
invoking the publish from the tag-triggered workflow, not by this file. This one is offline and
answers a narrower question: does the record we would publish name the release we verified.

Exit: 0 = both fields name the Formula's version - 1 = they do not
"""
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
#: `LPM_SERVER_JSON` and `LPM_FORMULA_PATH` exist for the self-test, and specifically so it can
#: drive main() -- the ENTRY POINT -- at a tree that should fail. Without them every case could
#: only call `check()` with explicit paths, and a `main()` returning 0 unconditionally would have
#: been green. `Scripts/mutation-sweep-guard-tests.py` measured exactly that on 2026-09-18.
SERVER_JSON = os.environ.get("LPM_SERVER_JSON") or os.path.join(REPO, "server.json")
FORMULA = os.environ.get("LPM_FORMULA_PATH") or os.path.join(REPO, "Formula", "logic-pro-mcp.rb")
PUBLISHER = "io.modelcontextprotocol.registry/publisher-provided"


def formula_version(text: str):
    match = re.search(r'^\s*version\s+"([^"]+)"', text, re.M)
    return match.group(1) if match else None


def check(server_json_path: str = SERVER_JSON, formula_path: str = FORMULA) -> list:
    problems = []
    try:
        with open(formula_path, encoding="utf-8") as handle:
            formula_text = handle.read()
    except OSError as exc:
        return [f"could not read the Formula: {exc}"]
    expected = formula_version(formula_text)
    if expected is None:
        return [f"CANNOT DETERMINE: no `version \"...\"` line in {os.path.relpath(formula_path, REPO)}. "
                f"The Formula's shape changed, and an absent expectation would pass against anything."]

    try:
        with open(server_json_path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError) as exc:
        return [f"could not read server.json: {exc}"]

    declared = doc.get("version")
    if declared != expected:
        problems.append(f"server.json declares version {declared!r}; the Formula says {expected!r}. "
                        f"The Formula's version is the one tied to a published artifact by "
                        f"ci-verify-formula-sha.sh, so this record would advertise a release "
                        f"nobody verified.")

    distribution = (doc.get("_meta", {}).get(PUBLISHER, {}) or {}).get("distribution")
    if not isinstance(distribution, dict) or "release" not in distribution:
        problems.append(f"server.json has no `_meta.{PUBLISHER}.distribution.release`. That URL is "
                        f"where a reader of the registry goes to download the build; if the field "
                        f"moved, this check stops watching it and must be pointed at the new one.")
        return problems

    release = str(distribution["release"])
    tag = release.rsplit("/", 1)[-1]
    if tag != f"v{expected}":
        problems.append(f"`distribution.release` points at {tag!r}; the Formula says {expected!r}. "
                        f"A registry record that names one version and links to another sends "
                        f"every reader to the wrong build.")
    return problems


def main() -> int:
    problems = check()
    for problem in problems:
        print(f"registry metadata: {problem}", file=sys.stderr)
    if problems:
        print("\nRun `python3 Scripts/sync-server-json-version.py <version>` to write both fields.",
              file=sys.stderr)
        return 1
    with open(SERVER_JSON, encoding="utf-8") as handle:
        doc = json.load(handle)
    print(f"server.json and the Formula both name {doc['version']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
