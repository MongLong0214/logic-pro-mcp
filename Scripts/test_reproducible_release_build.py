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
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RELEASE = os.path.join(HERE, "reproducible-release-build.sh")
PATCHER = os.path.join(HERE, "reproducible-build-uuid-patch.py")
RESOLVED = '{"pins": [], "version": 3}'
REWRITTEN = '{"pins": [{"identity": "other"}], "version": 3}'


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

    def test_a_lock_resolve_rewrote_is_fatal_and_kept(self):
        self.fake_swift(on_resolve=f"printf '%s' '{REWRITTEN}' > Package.resolved")
        result = self.run_release()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("resolve changed the tree", result.stderr)
        self.assertEqual(self.resolved(), REWRITTEN, "the rewritten lock was put back")
        self.assertIn("package resolve --force-resolved-versions", self.swift_calls())
        self.assertFalse(any(call.startswith("build") for call in self.swift_calls()), "it built after the lock moved")

    def test_a_lock_the_build_rewrote_is_fatal_and_kept(self):
        self.fake_swift(on_build=f"printf '%s' '{REWRITTEN}' > Package.resolved")
        result = self.run_release()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("the build changed the tree", result.stderr)
        self.assertEqual(self.resolved(), REWRITTEN, "the rewritten lock was put back")
        builds = [call for call in self.swift_calls() if call.startswith("build")]
        self.assertTrue(builds and all("--force-resolved-versions" in call for call in builds), builds)


if __name__ == "__main__":
    unittest.main()
