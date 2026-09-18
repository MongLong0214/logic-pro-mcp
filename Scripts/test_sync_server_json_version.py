#!/usr/bin/env python3
"""Drive `Scripts/sync-server-json-version.py` through the half-write it exists to prevent.

The first case is the reason the script exists. The YAML this replaced wrote `.version` and left
`distribution.release` alone, and no test could have caught it because there was nothing to call:
the rewrite ran on a runner, against a file that was published and discarded. Every case here
writes a temporary `server.json` and reads back both fields.
"""
import importlib.util
import json
import os
import sys
import tempfile

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sync-server-json-version.py")
PUBLISHER = "io.modelcontextprotocol.registry/publisher-provided"

_spec = importlib.util.spec_from_file_location("sync_server_json_version", SCRIPT)
sync_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sync_mod)

failures = []


def check(name, condition, detail=""):
    if not condition:
        failures.append(f"{name}: {detail}")


def document(release="https://github.com/MongLong0214/logic-pro-mcp/releases/tag/v1.2.3",
             version="1.2.3", with_release=True):
    distribution = {"status": "metadata-only"}
    if with_release:
        distribution["release"] = release
    return {"name": "io.github.x/y", "version": version,
            "_meta": {PUBLISHER: {"distribution": distribution}}}


def run(doc, version):
    """Write `doc`, sync it to `version`, return (problems, the document on disk afterwards)."""
    with tempfile.TemporaryDirectory() as root:
        path = os.path.join(root, "server.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(doc, handle)
        problems = sync_mod.sync(path, version)
        with open(path, encoding="utf-8") as handle:
            return problems, json.load(handle)


def release_of(doc):
    return doc["_meta"][PUBLISHER]["distribution"].get("release")


def main() -> int:
    # THE CASE THIS SCRIPT EXISTS FOR. Both fields, or the registry advertises one version and
    # links to another.
    problems, doc = run(document(), "3.16.0")
    check("a sync is accepted", problems == [], str(problems))
    check("`.version` is written", doc["version"] == "3.16.0", doc["version"])
    check("the release URL is written too",
          release_of(doc).endswith("/tag/v3.16.0"),
          f"{release_of(doc)} -- this is the defect: version says 3.16.0, the link says something else")

    # The rest of the URL is not disturbed: only the tag segment moves.
    check("only the tag segment changes",
          release_of(doc) == "https://github.com/MongLong0214/logic-pro-mcp/releases/tag/v3.16.0",
          release_of(doc))

    # A leading `v` is what a tag name looks like, and that is where the version comes from.
    problems, doc = run(document(), "v3.16.0")
    check("a v-prefixed tag is accepted", problems == [], str(problems))
    check("the `v` does not reach `.version`", doc["version"] == "3.16.0", doc["version"])
    check("the `v` is not doubled in the URL", release_of(doc).endswith("/tag/v3.16.0"),
          release_of(doc))

    # Prerelease tags are real here: `release.yml` marks a tag containing `-` as a prerelease.
    problems, doc = run(document(), "3.17.0-rc.1")
    check("a prerelease version is accepted", problems == [], str(problems))
    check("a prerelease reaches both fields",
          doc["version"] == "3.17.0-rc.1" and release_of(doc).endswith("/tag/v3.17.0-rc.1"),
          f"{doc['version']} / {release_of(doc)}")

    # The publish job holds `id-token: write` and the version arrives from a tag name.
    for bad in ["3.16", "3.16.0.1", "v", "", "3.16.0 && curl evil", "../../etc/passwd", "01.2.3"]:
        problems, doc = run(document(), bad)
        check(f"{bad!r} is refused", problems != [], "accepted a version that is not SemVer")
        check(f"{bad!r} leaves the file untouched", doc["version"] == "1.2.3",
              f"the file was written anyway: {doc['version']}")

    # Half-writing is the whole defect, so a document with nowhere to put the URL is refused
    # rather than getting its `.version` bumped.
    problems, doc = run(document(with_release=False), "3.16.0")
    check("a document with no release URL is refused", problems != [],
          "wrote `.version` into a document that has no link to keep in step with it")
    check("and is left untouched", doc["version"] == "1.2.3", doc["version"])

    # Substituting a tag into a URL that is not a release URL would silently move the link.
    problems, doc = run(document(release="https://example.com/whatever"), "3.16.0")
    check("a non-release URL is refused", problems != [], "substituted into an arbitrary URL")
    check("and is left untouched", doc["version"] == "1.2.3", doc["version"])

    # A version that is already correct is not an error -- re-running a publish must be safe.
    problems, doc = run(document(version="3.16.0",
                                 release="https://github.com/MongLong0214/logic-pro-mcp/"
                                         "releases/tag/v3.16.0"), "3.16.0")
    check("syncing to the version already there is accepted", problems == [], str(problems))
    check("and is idempotent",
          doc["version"] == "3.16.0" and release_of(doc).endswith("/tag/v3.16.0"),
          f"{doc['version']} / {release_of(doc)}")

    # The real file, through the real entry point, into a copy -- so the case covers argv handling
    # and not only `sync()`.
    import subprocess
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    with tempfile.TemporaryDirectory() as root:
        path = os.path.join(root, "server.json")
        with open(os.path.join(repo, "server.json"), encoding="utf-8") as src:
            real = json.load(src)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(real, handle)
        proc = subprocess.run([sys.executable, SCRIPT, "9.9.9", path],
                              capture_output=True, text=True)
        check("the CLI syncs the repository's own server.json", proc.returncode == 0,
              f"exit {proc.returncode}: {proc.stderr.strip()[:200]}")
        with open(path, encoding="utf-8") as handle:
            after = json.load(handle)
        check("the CLI wrote both fields of the real document",
              after["version"] == "9.9.9" and release_of(after).endswith("/tag/v9.9.9"),
              f"{after['version']} / {release_of(after)}")
        # Everything else survives: this file carries discovery metadata the registry shows.
        real_copy = dict(real)
        real_copy["version"] = "9.9.9"
        real_copy["_meta"] = json.loads(json.dumps(real["_meta"]))
        real_copy["_meta"][PUBLISHER]["distribution"]["release"] = release_of(after)
        check("nothing else in the document changed", after == real_copy,
              "the sync altered a field other than the two it names")

    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1
    print(f"{22} case(s) pass: the sync writes both fields or writes nothing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
