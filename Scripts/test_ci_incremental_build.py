#!/usr/bin/env python3
"""The incremental test build: source mtimes, the cache key, the clean-build fallback, and the
workflow wiring that keeps the cache out of release-build and out of pull request saves."""
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESTORE = os.path.join(REPO, "Scripts", "ci-restore-source-mtimes.py")
BUILD = os.path.join(REPO, "Scripts", "ci-incremental-build.sh")
SECOND = 1_000_000_000


def read(path):
    with open(os.path.join(REPO, path), encoding="utf-8") as handle:
        return handle.read()


def job_body(workflow, name):
    match = re.search(rf"^  {re.escape(name)}:\n", workflow, re.M)
    tail = workflow[match.end():]
    following = re.search(r"^  [A-Za-z0-9_-]+:\n", tail, re.M)
    return tail[:following.start()] if following else tail


def command_of(workflow):
    found = re.findall(r"^      TEST_BUILD_COMMAND: (.+)$", workflow, re.M)
    assert len(found) == 1, found
    return found[0]


class Tree:
    """A throwaway git repository standing in for a checkout."""

    def __init__(self, test):
        self.directory = tempfile.TemporaryDirectory()
        test.addCleanup(self.directory.cleanup)
        self.root = self.directory.name
        self.git("init", "-q")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")

    def git(self, *args):
        subprocess.run(["git", "-C", self.root, *args], check=True, capture_output=True)

    def path(self, name):
        return os.path.join(self.root, name)

    def write(self, name, text):
        os.makedirs(os.path.dirname(self.path(name)), exist_ok=True)
        with open(self.path(name), "w", encoding="utf-8") as handle:
            handle.write(text)
        self.git("add", name)

    def mtime(self, name):
        return os.stat(self.path(name)).st_mtime_ns

    def set_mtime(self, name, ns):
        os.utime(self.path(name), ns=(ns, ns))

    def fresh_checkout(self, names):
        """What actions/checkout does to a tree: every file is rewritten, so every mtime is now."""
        for name in names:
            with open(self.path(name), "rb") as handle:
                data = handle.read()
            temporary = self.path(name) + ".new"
            with open(temporary, "wb") as handle:
                handle.write(data)
            os.replace(temporary, self.path(name))

    def sync(self):
        return subprocess.run([sys.executable, RESTORE, "--root", self.root,
                               "--state", self.path(".build/ci-source-state.tsv"),
                               "--build-directory", self.path(".build")],
                              check=True, capture_output=True, text=True).stdout


class SourceMtimes(unittest.TestCase):
    def setUp(self):
        self.tree = Tree(self)
        for name, text in (("Sources/a.swift", "a"), ("Sources/b.swift", "b"),
                           ("Tests/t.swift", "t")):
            self.tree.write(name, text)
        self.names = ["Sources/a.swift", "Sources/b.swift", "Tests/t.swift"]

    def seed(self):
        """A first build: a cold sync, then 'products' newer than every source."""
        self.tree.sync()
        recorded = {name: self.tree.mtime(name) for name in self.names}
        os.makedirs(self.tree.path(".build/debug"), exist_ok=True)
        product = self.tree.path(".build/debug/product.o")
        with open(product, "w", encoding="utf-8") as handle:
            handle.write("o")
        newest = max(recorded.values()) + 5 * SECOND
        os.utime(product, ns=(newest, newest))
        return recorded, newest

    def test_a_cold_tree_is_all_changed_and_leaves_a_state(self):
        out = self.tree.sync()
        self.assertIn("3 changed or new", out)
        self.assertIn("previous state absent", out)
        self.assertTrue(os.path.exists(self.tree.path(".build/ci-source-state.tsv")))

    def test_unchanged_files_get_their_recorded_mtime_back_after_a_fresh_checkout(self):
        recorded, _ = self.seed()
        self.tree.fresh_checkout(self.names)
        for name in self.names:
            self.assertNotEqual(self.tree.mtime(name), recorded[name])
        out = self.tree.sync()
        self.assertIn("3 kept", out)
        for name in self.names:
            self.assertEqual(self.tree.mtime(name), recorded[name], name)

    def test_a_changed_file_is_newer_than_every_recorded_mtime_and_every_product(self):
        recorded, newest_product = self.seed()
        self.tree.fresh_checkout(self.names)
        self.tree.write("Sources/b.swift", "b but different")
        out = self.tree.sync()
        self.assertIn("2 kept", out)
        self.assertIn("1 changed", out)
        self.assertGreater(self.tree.mtime("Sources/b.swift"), newest_product)
        self.assertGreater(self.tree.mtime("Sources/b.swift"), max(recorded.values()))
        self.assertEqual(self.tree.mtime("Sources/a.swift"), recorded["Sources/a.swift"])

    def test_a_change_is_seen_even_when_size_and_mtime_are_kept(self):
        recorded, _ = self.seed()
        self.tree.write("Sources/a.swift", "z")  # same size as "a"
        self.tree.set_mtime("Sources/a.swift", recorded["Sources/a.swift"])
        self.assertEqual(self.tree.mtime("Sources/a.swift"), recorded["Sources/a.swift"])
        self.tree.sync()
        self.assertGreater(self.tree.mtime("Sources/a.swift"), recorded["Sources/a.swift"])

    def test_a_file_changed_back_to_older_content_is_not_trusted_as_unchanged(self):
        recorded, _ = self.seed()
        self.tree.write("Sources/a.swift", "edited")
        self.tree.sync()
        edited = self.tree.mtime("Sources/a.swift")
        self.assertGreater(edited, recorded["Sources/a.swift"])
        self.tree.write("Sources/a.swift", "a")
        self.tree.sync()
        self.assertGreater(self.tree.mtime("Sources/a.swift"), edited)

    def test_a_new_file_is_stamped_and_a_deleted_one_is_counted(self):
        recorded, newest_product = self.seed()
        self.tree.write("Sources/c.swift", "c")
        os.remove(self.tree.path("Sources/b.swift"))
        self.tree.git("rm", "-q", "--cached", "Sources/b.swift")
        out = self.tree.sync()
        self.assertIn("1 gone", out)
        self.assertGreater(self.tree.mtime("Sources/c.swift"), newest_product)

    def test_a_corrupt_or_foreign_state_is_ignored_rather_than_trusted(self):
        recorded, _ = self.seed()
        with open(self.tree.path(".build/ci-source-state.tsv"), "w", encoding="utf-8") as handle:
            handle.write("not a state\n" + "0" * 64 + "\t1\t\"Sources/a.swift\"\n")
        self.tree.fresh_checkout(self.names)
        out = self.tree.sync()
        self.assertIn("previous state absent", out)
        for name in self.names:
            self.assertNotEqual(self.tree.mtime(name), recorded[name])


class BuildScript(unittest.TestCase):
    def setUp(self):
        self.tree = Tree(self)
        self.tree.write("Sources/a.swift", "a")
        self.bin = tempfile.TemporaryDirectory()
        self.addCleanup(self.bin.cleanup)
        self.count = os.path.join(self.bin.name, "count")
        self.env = {**os.environ, "COUNT": self.count, "RUNNER_OS": "macOS",
                    "RUNNER_ARCH": "ARM64", "ImageVersion": "20260101.1"}

    def fake_swift(self, version):
        path = os.path.join(self.bin.name, "swift")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(f"#!/bin/sh\necho '{version}'\n")
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
        self.env["PATH"] = self.bin.name + os.pathsep + os.environ["PATH"]

    def run_script(self, *args):
        return subprocess.run(["bash", BUILD, *args], cwd=self.tree.root, env=self.env,
                              capture_output=True, text=True)

    def runs(self):
        if not os.path.exists(self.count):
            return 0
        with open(self.count, encoding="utf-8") as handle:
            return len(handle.read().splitlines())

    def build_command(self):
        # Fails while .build/poison exists, and counts every attempt.
        return ["sh", "-c", 'echo x >> "$COUNT"; test ! -e .build/poison']

    def test_the_key_changes_with_the_toolchain_the_flags_and_the_image(self):
        self.fake_swift("Apple Swift version 6.2.4")
        base = self.run_script("key", "swift", "build", "--build-tests").stdout
        self.assertTrue(base.startswith("swift-build-macOS-ARM64-20260101.1-swift"), base)
        self.assertEqual(base, self.run_script("key", "swift", "build", "--build-tests").stdout)
        self.assertNotEqual(base, self.run_script(
            "key", "swift", "build", "--build-tests", "--enable-code-coverage").stdout)
        self.env["ImageVersion"] = "20260102.1"
        self.assertNotEqual(base, self.run_script("key", "swift", "build", "--build-tests").stdout)
        self.env["ImageVersion"] = "20260101.1"
        self.fake_swift("Apple Swift version 6.2.5")
        self.assertNotEqual(base, self.run_script("key", "swift", "build", "--build-tests").stdout)

    def test_a_cold_build_runs_once_and_a_failure_is_not_retried(self):
        failing = ["sh", "-c", 'echo x >> "$COUNT"; exit 3']
        result = self.run_script("build", *failing)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.runs(), 1)
        self.assertTrue(os.path.exists(self.tree.path(".build/ci-source-state.tsv")))

    def test_a_restored_build_that_fails_is_retried_from_a_clean_build_directory(self):
        os.makedirs(self.tree.path(".build"))
        open(self.tree.path(".build/poison"), "w").close()
        self.assertEqual(self.run_script("build", "true").returncode, 0)  # no state: discarded
        os.makedirs(self.tree.path(".build"), exist_ok=True)
        self.tree.sync()
        open(self.tree.path(".build/poison"), "w").close()
        result = self.run_script("build", *self.build_command())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.runs(), 2)
        self.assertFalse(os.path.exists(self.tree.path(".build/poison")))
        self.assertIn("retrying from a clean .build", result.stdout)
        self.assertTrue(os.path.exists(self.tree.path(".build/ci-source-state.tsv")))

    def test_a_restored_build_that_fails_twice_fails_the_job(self):
        self.tree.sync()
        result = self.run_script("build", "sh", "-c", 'echo x >> "$COUNT"; exit 1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.runs(), 2)

    def test_a_build_directory_without_a_state_is_not_reused(self):
        os.makedirs(self.tree.path(".build"))
        open(self.tree.path(".build/leftover"), "w").close()
        result = self.run_script("build", "sh", "-c", 'echo x >> "$COUNT"; test ! -e .build/leftover')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.runs(), 1)


class WorkflowWiring(unittest.TestCase):
    def setUp(self):
        self.ci = read(".github/workflows/ci.yml")
        self.seed = read(".github/workflows/test-build-cache.yml")
        self.test_build = job_body(self.ci, "test-build")

    def test_the_seed_builds_the_same_command_as_test_build(self):
        self.assertEqual(command_of(self.ci), command_of(self.seed))
        self.assertIn("--build-tests --enable-code-coverage", command_of(self.ci))
        for text in (self.test_build, self.seed):
            self.assertIn("bash Scripts/ci-incremental-build.sh build $TEST_BUILD_COMMAND", text)
            self.assertIn("bash Scripts/ci-incremental-build.sh key $TEST_BUILD_COMMAND", text)

    def test_the_key_names_the_toolchain_and_flags_through_the_script_and_the_lock_files(self):
        for text in (self.test_build, self.seed):
            self.assertIn(
                "key: ${{ steps.build-cache.outputs.prefix }}-"
                "${{ hashFiles('Package.resolved', 'Package.swift') }}-${{ github.sha }}", text)
            self.assertIn(
                "restore-keys: |\n            ${{ steps.build-cache.outputs.prefix }}-"
                "${{ hashFiles('Package.resolved', 'Package.swift') }}-\n", text)
        script = read("Scripts/ci-incremental-build.sh")
        for needle in ("swift --version", "ImageVersion", "RUNNER_OS", "RUNNER_ARCH", '"$*"'):
            self.assertIn(needle, script)

    def test_test_build_restores_but_never_saves_and_release_build_has_no_build_cache(self):
        self.assertIn("uses: actions/cache/restore@", self.test_build)
        self.assertNotIn("actions/cache/save", self.ci)
        self.assertEqual(self.ci.count("path: .build"), 1)
        self.assertNotIn("path: .build", job_body(self.ci, "release-build"))
        self.assertNotIn("ci-incremental-build", job_body(self.ci, "release-build"))
        self.assertIn("swift build -c release", job_body(self.ci, "release-build"))
        self.assertLess(self.test_build.index("actions/cache/restore@"),
                        self.test_build.index("ci-incremental-build.sh build"))

    def test_the_seed_runs_on_main_pushes_only_and_saves_only_after_a_successful_build(self):
        trigger = self.seed.split("permissions:", 1)[0]
        self.assertIn("push:\n    branches: [main]", trigger)
        self.assertNotIn("pull_request", trigger)
        build = self.seed.index("ci-incremental-build.sh build")
        save = self.seed.index("actions/cache/save@")
        self.assertLess(build, save)
        tail = self.seed[save:]
        self.assertNotIn("if:", tail)
        self.assertNotIn("always()", self.seed)
        self.assertIn("contents: read", self.seed)
        self.assertIn("cancel-in-progress: false", self.seed)

    def test_the_new_scripts_are_executed_by_ci(self):
        self.assertIn("Scripts/test_ci_incremental_build.py", self.ci)
        for name in ("Scripts/ci-incremental-build.sh", "Scripts/ci-restore-source-mtimes.py"):
            self.assertIn(name, self.seed)


if __name__ == "__main__":
    unittest.main()
