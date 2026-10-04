#!/usr/bin/env python3
"""Drive reproducible-release-build.sh against a scratch repository (#1098).

The builder put Package.resolved back after `swift package resolve`, after the build and at
completion, without looking at what changed, and a failed `git status` answered nothing, which read
as a clean tree (#1095's supplementary reviews, R1095-S01 and S02). A copy of the builder sits in
the scratch repository's Scripts directory, because it builds the tree it sits in. `swift` is a
script on PATH that records its arguments and can rewrite the lock during resolve or the build;
nothing is built.

    python3 test_reproducible_release_build.py
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RELEASE = os.path.join(HERE, "reproducible-release-build.sh")
PATCHER = os.path.join(HERE, "reproducible-build-uuid-patch.py")
PIN_LOG = {"identity": "swift-log", "kind": "remoteSourceControl", "location": "https://github.com/apple/swift-log.git",
           "state": {"revision": "aaaa000000000000000000000000000000000000", "version": "1.6.0"}}
PIN_NIO = {"identity": "swift-nio", "kind": "remoteSourceControl", "location": "https://github.com/apple/swift-nio.git",
           "state": {"revision": "bbbb000000000000000000000000000000000000", "version": "2.97.1"}}
PIN_CRYPTO = {"identity": "swift-crypto", "kind": "remoteSourceControl", "location": "https://github.com/apple/swift-crypto.git",
              "state": {"revision": "cccc000000000000000000000000000000000000", "version": "4.5.1"}}


def lock(pins):
    return json.dumps({"originHash": "0957", "pins": pins, "version": 3}, indent=2) + "\n"


RESOLVED = lock([PIN_LOG, PIN_NIO])
#: The four ways #1098 names a lock can change: a platform pin pruned, a retained pin moved, a pin
#: added, and a file that does not parse. None of them may be put back or built from.
CHANGES = {
    "pruned": lock([PIN_LOG]),
    "retained pin moved": lock([dict(PIN_LOG, state={"revision": "dddd000000000000000000000000000000000000",
                                                      "version": "1.6.1"}), PIN_NIO]),
    "pin added": lock([PIN_LOG, PIN_NIO, PIN_CRYPTO]),
    "malformed": '{"pins": [ {"identity": "swift-log", ',
}


def git(repo, *args, env=None):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, env=env)


class ReleaseBuilder(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.repo = os.path.join(self.root, "repo")
        scripts = os.path.join(self.repo, "Scripts")
        os.makedirs(scripts)
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "t@example.invalid")
        git(self.repo, "config", "user.name", "t")
        for name, text in (("Package.resolved", RESOLVED), ("Source.swift", "// source\n"), (".gitignore", ".build/\n")):
            with open(os.path.join(self.repo, name), "w") as handle:
                handle.write(text)
        shutil.copy(RELEASE, scripts)
        shutil.copy(PATCHER, scripts)
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "scratch")
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.bin)
        self.ran = os.path.join(self.root, "swift-ran")

    def reset(self):
        """Put the scratch tree back to its commit and forget the swift calls, between sub-cases."""
        git(self.repo, "checkout", "--", ".")
        git(self.repo, "clean", "-fdq")
        if os.path.exists(self.ran):
            os.remove(self.ran)

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def fake_swift(self, on_resolve="", on_build=""):
        """A `swift` that records its arguments; `package resolve` runs `on_resolve`, and `build` runs
        `on_build` and leaves an executable where the builder looks for the release binary."""
        path = os.path.join(self.bin, "swift")
        with open(path, "w") as handle:
            handle.write(f"""#!/bin/bash
echo "$@" >> {self.ran!r}
case "$1" in
  --version) echo "Swift version 0 (fake)" ;;
  package) [ "$2" = resolve ] && {{ {on_resolve or ':'}; }} ;;
  build) {on_build or ':'}; mkdir -p .build/release; printf x > .build/release/LogicProMCP; chmod +x .build/release/LogicProMCP ;;
esac
exit 0
""")
        os.chmod(path, 0o755)

    def run_release(self, **extra):
        env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"])
        env.update(extra)
        return subprocess.run(["bash", os.path.join(self.repo, "Scripts", os.path.basename(RELEASE))],
                              capture_output=True, text=True, env=env)

    def resolved(self):
        with open(os.path.join(self.repo, "Package.resolved")) as handle:
            return handle.read()

    def swift_calls(self):
        if not os.path.exists(self.ran):
            return []
        with open(self.ran) as handle:
            return handle.read().splitlines()

    def test_a_status_that_does_not_read_is_fatal_before_swift_runs(self):
        self.fake_swift()
        bad = os.path.join(self.root, "not-an-index")
        with open(bad, "w") as handle:
            handle.write("this is not a git index\n")
        result = self.run_release(GIT_INDEX_FILE=bad)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("git status did not read before the build", result.stderr)
        self.assertEqual(self.swift_calls(), [])

    def test_a_dirty_tree_is_fatal_before_swift_runs(self):
        self.fake_swift()
        with open(os.path.join(self.repo, "Source.swift"), "a") as handle:
            handle.write("// edit\n")
        result = self.run_release()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("dirty tree before build", result.stderr)
        self.assertEqual(self.swift_calls(), [])

    def rewrite(self, text):
        """A shell command that writes `text` to Package.resolved exactly."""
        path = os.path.join(self.root, "rewrite.txt")
        with open(path, "w") as handle:
            handle.write(text)
        return f"cp {path!r} Package.resolved"

    def test_every_lock_change_at_resolve_is_fatal_kept_and_not_built(self):
        for shape, text in CHANGES.items():
            with self.subTest(shape=shape):
                self.reset()
                self.fake_swift(on_resolve=self.rewrite(text))
                result = self.run_release()
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("resolve changed the tree", result.stderr)
                self.assertEqual(self.resolved(), text, "the changed lock was not kept byte for byte")
                self.assertIn("package resolve --force-resolved-versions", self.swift_calls())
                self.assertFalse(any(call.startswith("build") for call in self.swift_calls()), "it built after the lock moved")

    def test_every_lock_change_at_build_is_fatal_and_kept(self):
        for shape, text in CHANGES.items():
            with self.subTest(shape=shape):
                self.reset()
                self.fake_swift(on_build=self.rewrite(text))
                result = self.run_release()
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("the build changed the tree", result.stderr)
                self.assertEqual(self.resolved(), text, "the changed lock was not kept byte for byte")
                builds = [call for call in self.swift_calls() if call.startswith("build")]
                self.assertTrue(builds and all("--force-resolved-versions" in call for call in builds), builds)

    def test_an_unchanged_lock_passes_both_reads(self):
        # The control: with nothing rewritten the builder gets past both lock reads and goes on to
        # the post-build steps, which this scratch binary cannot satisfy.
        self.fake_swift()
        result = self.run_release()
        self.assertNotIn("changed the tree", result.stderr, result.stdout + result.stderr)
        # pre_strip_sha256 is printed after the post-build status read, so its presence shows that
        # read passed; build_exit is printed before it (review round 3, R1099-03).
        self.assertIn("pre_strip_sha256:", result.stdout, result.stdout + result.stderr)
        self.assertEqual(self.resolved(), RESOLVED)


if __name__ == "__main__":
    unittest.main()
