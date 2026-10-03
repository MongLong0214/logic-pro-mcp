#!/usr/bin/env python3
"""Drive build_attested_binary.sh and reproducible-release-build.sh against a scratch repository.

#1095 supplementary review: R1095-S01 (the builder put Package.resolved back before reading whether
the tree was clean, so the caller's edit was erased and the tree passed) and R1095-S02 (a `git status`
that failed answered nothing on stdout, and nothing read as clean). `swift` is a script on PATH that
records that it ran; nothing is built and nothing talks to Logic.

    python3 test_build_attested_binary.py
"""
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BUILDER = os.path.join(HERE, "build_attested_binary.sh")
RELEASE = os.path.join(os.path.dirname(HERE), "reproducible-release-build.sh")
RESOLVED = '{"pins": [], "version": 2}\n'


def git(repo, *args, env=None):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, env=env)


class ScratchRepo(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.repo = os.path.join(self.root, "repo")
        os.makedirs(self.repo)
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "t@example.invalid")
        git(self.repo, "config", "user.name", "t")
        with open(os.path.join(self.repo, "Package.resolved"), "w") as handle:
            handle.write(RESOLVED)
        with open(os.path.join(self.repo, "Source.swift"), "w") as handle:
            handle.write("// source\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "scratch")
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.bin)
        self.ran = os.path.join(self.root, "swift-ran")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def fake_swift(self, body=""):
        """A `swift` that records its arguments, then runs `body` in the repository."""
        path = os.path.join(self.bin, "swift")
        with open(path, "w") as handle:
            handle.write(f'#!/bin/bash\necho "$@" >> {self.ran!r}\n{body}\nexit 0\n')
        os.chmod(path, 0o755)

    def env(self, **extra):
        env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"])
        env.update(extra)
        return env

    def resolved(self):
        with open(os.path.join(self.repo, "Package.resolved")) as handle:
            return handle.read()

    def not_an_index(self):
        path = os.path.join(self.root, "not-an-index")
        with open(path, "w") as handle:
            handle.write("this is not a git index\n")
        return path


class Builder(ScratchRepo):
    def run_builder(self, **extra):
        return subprocess.run(["bash", BUILDER, self.repo, os.path.join(self.root, "out")],
                              capture_output=True, text=True, env=self.env(**extra))

    def test_an_edit_to_package_resolved_is_refused_and_kept(self):
        self.fake_swift()
        edited = RESOLVED.replace("2", "3")
        with open(os.path.join(self.repo, "Package.resolved"), "w") as handle:
            handle.write(edited)
        result = self.run_builder()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("not clean", result.stderr)
        self.assertEqual(self.resolved(), edited, "the caller's edit was erased")
        self.assertFalse(os.path.exists(self.ran), "swift ran on a tree that was not clean")

    def test_a_status_that_does_not_read_is_refused(self):
        self.fake_swift()
        bad = self.not_an_index()
        self.assertNotEqual(git(self.repo, "status", "--porcelain", env=dict(os.environ, GIT_INDEX_FILE=bad)).returncode, 0,
                            "the scratch condition did not make git status fail")
        result = self.run_builder(GIT_INDEX_FILE=bad)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("did not read", result.stderr)
        self.assertFalse(os.path.exists(self.ran), "swift ran with cleanliness unknown")

    def ignore_build_products(self):
        with open(os.path.join(self.repo, ".gitignore"), "w") as handle:
            handle.write(".build/\n")
        git(self.repo, "add", ".gitignore")
        git(self.repo, "commit", "-q", "-m", "ignore build")

    def test_a_build_that_leaves_the_tree_clean_reaches_the_section_read(self):
        # The fake build leaves a binary with no commit section, so the script passes both
        # cleanliness reads and stops at the section read-back. The build was told to use the
        # committed lock as it is.
        self.ignore_build_products()
        self.fake_swift("mkdir -p .build/debug; echo x > .build/debug/LogicProMCP")
        result = self.run_builder()
        self.assertIn("does not read back as the head", result.stderr, result.stdout + result.stderr)
        with open(self.ran) as handle:
            self.assertIn("--force-resolved-versions", handle.read())

    def test_a_lock_the_build_rewrote_is_refused_and_kept(self):
        # Second supplementary review, R1095-S01: a rewritten lock may name other dependency
        # versions; it is neither put back nor accepted.
        self.ignore_build_products()
        rewritten = '{"pins": [{"identity": "other"}], "version": 2}'
        self.fake_swift(f"printf '%s' {rewritten!r} > Package.resolved; mkdir -p .build/debug; echo x > .build/debug/LogicProMCP")
        result = self.run_builder()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed during the build", result.stderr, result.stdout + result.stderr)
        self.assertEqual(self.resolved(), rewritten, "the rewritten lock was put back")
        self.assertFalse(os.path.isdir(os.path.join(self.root, "out")), "a binary was published")

    def test_any_other_change_during_the_build_is_refused(self):
        self.fake_swift('echo "// changed" >> Source.swift')
        result = self.run_builder()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed during the build", result.stderr, result.stdout + result.stderr)


class ReleaseBuilder(ScratchRepo):
    """The release builder reads the tree it sits in, so a copy of it is placed in the scratch
    repository's Scripts directory. Both cases stop before anything is removed or built."""

    def run_release(self, **extra):
        scripts = os.path.join(self.repo, "Scripts")
        os.makedirs(scripts, exist_ok=True)
        shutil.copy(RELEASE, scripts)
        git(self.repo, "add", "Scripts")
        git(self.repo, "commit", "-q", "-m", "release builder")
        return subprocess.run(["bash", os.path.join(scripts, os.path.basename(RELEASE))],
                              capture_output=True, text=True, env=self.env(**extra))

    def test_a_status_that_does_not_read_is_fatal(self):
        self.fake_swift()
        bad = self.not_an_index()
        result = self.run_release(GIT_INDEX_FILE=bad)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("git status did not read before the build", result.stderr)
        self.assertFalse(os.path.exists(self.ran))

    def test_a_dirty_tree_is_fatal(self):
        self.fake_swift()
        with open(os.path.join(self.repo, "Source.swift"), "a") as handle:
            handle.write("// edit\n")
        result = self.run_release()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("dirty tree before build", result.stderr)
        self.assertFalse(os.path.exists(self.ran))


if __name__ == "__main__":
    unittest.main()
