#!/usr/bin/env python3
"""Point `server.json` at one release: the version string AND the release URL, together.

WHY THIS IS A SCRIPT AND NOT FOUR LINES OF YAML
-----------------------------------------------
It was four lines of YAML, inside `publish-mcp.yml`:

    jq --arg version "$VERSION" '.version = $version' server.json > server.json.tmp

That rewrites `.version` and leaves `distribution.release` alone, so a publish of version N
advertises version N and links to release N-1. Nothing could see it: the rewrite happened on a
runner, against a file the workflow then published and threw away, so the wrong record existed
only in the registry. A refusal nobody can drive is a refusal nobody has watched, and this one had
never been watched at all.

Here it has `test_sync_server_json_version.py` beside it, and the both-fields case is the first one.

WHAT IT REFUSES
---------------
* a version that is not strict SemVer -- the registry publish holds `id-token: write`, so the
  version reaches this from a tag name, which is attacker-controllable in the general case. The
  workflow checks this too; this is the enforcement site rather than a second copy of the rule.
* a `server.json` with no `distribution.release` -- the shape changed, and writing only `.version`
  into it is exactly the defect above. Refuse rather than half-write.
* a `distribution.release` that is not a release-tag URL -- rewriting the tag inside a URL that
  points somewhere else would silently move the link.

Exit: 0 = both fields now name `version` - 1 = refused, and nothing was written
"""
import json
import os
import re
import sys

SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
                    r"(-((0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
                    r"(\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?$")
PUBLISHER = "io.modelcontextprotocol.registry/publisher-provided"
RELEASE_URL = re.compile(r"^https://github\.com/[^/]+/[^/]+/releases/tag/v.+$")


def sync(path: str, version: str) -> list:
    """Rewrite `path` in place. Returns the problems; on any problem nothing is written."""
    version = version[1:] if version.startswith("v") else version
    if not SEMVER.match(version):
        return [f"{version!r} is not strict SemVer (MAJOR.MINOR.PATCH[-prerelease])"]
    try:
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError) as exc:
        return [f"{path} could not be read as JSON: {exc}"]

    distribution = (doc.get("_meta", {}).get(PUBLISHER, {}) or {}).get("distribution")
    if not isinstance(distribution, dict) or "release" not in distribution:
        return [f"{path} has no `_meta.{PUBLISHER}.distribution.release`. The shape changed; "
                f"writing only `.version` would publish a version that links to another release, "
                f"which is the defect this script exists to make impossible."]
    if not RELEASE_URL.match(str(distribution["release"])):
        return [f"`distribution.release` is {distribution['release']!r}, which is not a GitHub "
                f"release-tag URL. Refusing to substitute a tag into it."]

    doc["version"] = version
    distribution["release"] = re.sub(r"/tag/v[^/]+$", f"/tag/v{version}", distribution["release"])
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    return []


def main(argv) -> int:
    if len(argv) not in (2, 3):
        print(f"usage: {os.path.basename(argv[0])} <version> [server.json]", file=sys.stderr)
        return 1
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = argv[2] if len(argv) == 3 else os.path.join(repo, "server.json")
    problems = sync(path, argv[1])
    for problem in problems:
        print(f"sync-server-json-version: {problem}", file=sys.stderr)
    if problems:
        return 1
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
    release = doc["_meta"][PUBLISHER]["distribution"]["release"]
    print(f"server.json version {doc['version']} -> {release}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
