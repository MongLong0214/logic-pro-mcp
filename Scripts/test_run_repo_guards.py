#!/usr/bin/env python3
"""Cases for `run-repo-guards.py`, the file that decides whether every other guard passed.

It is the one file no guard checks: it excludes itself from discovery, so
`check-guards-have-self-tests.py` never sees it. That was survivable while it only read an exit
code. It now decides what counts as having RUN, and that decision is what let two guards report
`ok` having asserted nothing -- so it needs cases of its own.

The helpers are driven directly against text rather than by spawning 48 children, so these cases
are fast and say exactly which rule they are about. The cases for `main` are the exception: what
they are about IS the child process -- that a hang is killed, that a killed child's own children go
with it, that the temporary tree is deleted -- and none of that is observable without one.
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "run_repo_guards", os.path.join(REPO, "Scripts", "run-repo-guards.py"))
runner = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(runner)


class EvidenceOfWork(unittest.TestCase):
    def test_a_unittest_run_that_asserted_nothing_does_not_count(self):
        """The shape `setUpModule` raising SkipTest produces: exit 0, zero cases."""
        skips, why = runner.evidence_of_work("Ran 0 tests in 0.000s\n\nOK (skipped=1)\n")
        self.assertEqual(why, "ran 0 tests")
        self.assertEqual(skips, 1)

    def test_a_unittest_run_with_cases_counts(self):
        skips, why = runner.evidence_of_work("Ran 60 tests in 13.1s\n\nOK\n")
        self.assertIsNone(why)
        self.assertEqual(skips, 0)

    def test_skips_are_counted_even_when_the_run_is_real(self):
        """A run with cases AND skips is a run -- the skips are a budget question, not a veto."""
        skips, why = runner.evidence_of_work("Ran 62 tests in 1.5s\n\nOK (skipped=4)\n")
        self.assertIsNone(why)
        self.assertEqual(skips, 4)

    def test_silence_does_not_count(self):
        self.assertEqual(runner.evidence_of_work("")[1], "produced no output")
        self.assertEqual(runner.evidence_of_work("   \n\n")[1], "produced no output")

    def test_a_plain_script_that_printed_something_counts(self):
        """Weaker than a case count, and the only evidence a non-unittest guard offers.

        It is a floor rather than a guess: all 48 files discovered today print something, so
        nothing in the tree has to be exempted from it.
        """
        self.assertIsNone(runner.evidence_of_work("all 14 literals resolve\n")[1])

    def test_a_count_in_prose_is_not_read_as_a_case_count(self):
        """`Ran N tests` is anchored to the start of a line and followed by ` in `.

        A guard printing "Ran 0 tests worth of setup" in a sentence would otherwise be called
        vacuous, and a guard whose prose happened to contain the phrase would be trusted for it.
        """
        self.assertIsNone(runner.evidence_of_work("we Ran 0 tests worth of setup by hand\n")[1])


class ThePythonFloor(unittest.TestCase):
    """#1056: the runner must refuse below 3.10 BEFORE discovering anything, in one place."""

    def test_below_the_floor_is_refused_and_the_message_names_everything(self):
        message = runner.python_floor_refusal((3, 9, 6), "/usr/bin/python3")
        self.assertIsNotNone(message)
        self.assertIn("3.10", message)
        self.assertIn("/usr/bin/python3", message)
        self.assertIn("sys.stdlib_module_names", message)
        self.assertIn("3.9.6", message, "the running interpreter's own version, not just the floor")

    def test_at_the_floor_is_accepted(self):
        self.assertIsNone(runner.python_floor_refusal((3, 10, 0), "/usr/bin/python3"))

    def test_the_running_interpreter_is_accepted(self):
        """This suite itself runs on a 3.10+ interpreter -- see the end-to-end case below for 3.9."""
        self.assertIsNone(runner.python_floor_refusal(sys.version_info, sys.executable))


class TheSkipBudget(unittest.TestCase):
    def test_the_declared_guard_has_a_budget_and_a_reason(self):
        budget, why = runner.allowed_skips("Scripts/test_logic_canon.py")
        self.assertEqual(budget, 4, "measured with HAVE_LOGIC forced false: OK (skipped=4)")
        self.assertIn("Logic", why)

    def test_an_undeclared_guard_may_not_skip(self):
        budget, why = runner.allowed_skips("Scripts/check-canon-citations.py")
        self.assertEqual(budget, 0)

    def test_an_unreadable_declaration_allows_nothing(self):
        """Fails the safe way. A missing file must not read as "everything may skip"."""
        saved = runner.REPO
        runner.REPO = os.path.join(REPO, "no", "such", "tree")
        try:
            budget, why = runner.allowed_skips("Scripts/test_logic_canon.py")
        finally:
            runner.REPO = saved
        self.assertEqual(budget, 0)
        self.assertIn("nothing is allowed to skip", why)


class TheDeadline(unittest.TestCase):
    def test_a_hanging_child_is_killed_and_reported_as_a_failure(self):
        """Not a wait. Before this, a blocked guard spent the JOB's 60 minutes and named nobody."""
        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "hangs.py")
            with open(script, "w", encoding="utf-8") as handle:
                handle.write("import time\nprint('starting', flush=True)\ntime.sleep(600)\n")
            started = time.monotonic()
            code, out, seconds, timed_out = runner._run(script, dict(os.environ), 2)
            elapsed = time.monotonic() - started
        self.assertTrue(timed_out)
        self.assertIsNone(code)
        self.assertLess(elapsed, 30, "it must not have waited for the child's own sleep")
        self.assertGreaterEqual(seconds, 2)

    def test_a_grandchild_is_killed_with_its_parent(self):
        """`start_new_session` + `killpg`, or the grandchild holds the pipe after the kill."""
        with tempfile.TemporaryDirectory() as tmp:
            marker = os.path.join(tmp, "still-alive")
            script = os.path.join(tmp, "spawns.py")
            body = (
                "import subprocess, sys, time\n"
                "subprocess.Popen([sys.executable, '-c',\n"
                "    \"import time; time.sleep(8); open(%r,'w').write('x')\"])\n"
                "print('spawned', flush=True)\n"
                "time.sleep(600)\n" % marker)
            with open(script, "w", encoding="utf-8") as handle:
                handle.write(body)
            started = time.monotonic()
            _, _, _, timed_out = runner._run(script, dict(os.environ), 2)
            self.assertTrue(timed_out)
            self.assertLess(time.monotonic() - started, 30)
            time.sleep(10)
            self.assertFalse(os.path.exists(marker),
                             "the grandchild outlived the kill, so killpg did not reach it")

    def test_a_child_that_finishes_is_not_reported_as_timed_out(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "quick.py")
            with open(script, "w", encoding="utf-8") as handle:
                handle.write("print('done')\n")
            code, out, seconds, timed_out = runner._run(script, dict(os.environ), 30)
        self.assertFalse(timed_out)
        self.assertEqual(code, 0)
        self.assertIn("done", out)

    def test_the_deadline_is_read_from_the_environment_and_refuses_nonsense(self):
        saved = os.environ.get("LPM_GUARD_TIMEOUT")
        try:
            os.environ.pop("LPM_GUARD_TIMEOUT", None)
            self.assertEqual(runner._timeout(), runner.DEFAULT_TIMEOUT)
            os.environ["LPM_GUARD_TIMEOUT"] = "45"
            self.assertEqual(runner._timeout(), 45)
            for bad in ("0", "-1", "soon"):
                os.environ["LPM_GUARD_TIMEOUT"] = bad
                with self.assertRaises(SystemExit):
                    runner._timeout()
        finally:
            os.environ.pop("LPM_GUARD_TIMEOUT", None)
            if saved is not None:
                os.environ["LPM_GUARD_TIMEOUT"] = saved


def _main_over(bodies, env=None):
    """Run the runner's `main` over scripts written for this case, in a child process.

    Discovery is monkeypatched in the CHILD: `main` is about the whole loop, and the loop's
    effects -- the temporary tree, the killed children, the exit code -- are not observable from
    inside the process running the case.
    """
    tmp = tempfile.mkdtemp(prefix="runner-case-")
    paths = []
    for index, body in enumerate(bodies):
        path = os.path.join(tmp, "check-case%d.py" % index)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(body)
        paths.append(path)
    driver = os.path.join(tmp, "driver.py")
    runner_path = os.path.join(REPO, "Scripts", "run-repo-guards.py")
    with open(driver, "w", encoding="utf-8") as handle:
        handle.write(
            "import importlib.util, sys\n"
            "spec = importlib.util.spec_from_file_location('r', %r)\n"
            "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
            "m.discovered = lambda: %r\n"
            "sys.exit(m.main())\n" % (runner_path, paths))
    return subprocess.run([sys.executable, driver], capture_output=True, text=True,
                          env=dict(os.environ, **(env or {})))


class TheTemporaryTree(unittest.TestCase):
    def test_each_child_gets_its_own_bytecode_prefix(self):
        """Sharing one would undo the isolation that caught a guard running stale bytecode."""
        with tempfile.TemporaryDirectory() as root:
            first = runner._isolated_env(root, 0)["PYTHONPYCACHEPREFIX"]
            second = runner._isolated_env(root, 1)["PYTHONPYCACHEPREFIX"]
            self.assertNotEqual(first, second)
            self.assertTrue(first.startswith(root) and second.startswith(root))

    def test_a_whole_run_leaves_nothing_behind(self):
        """mkdtemp per child leaked one directory per guard, per run, for the life of the box."""
        before = set(os.listdir(tempfile.gettempdir()))
        proc = _main_over(["print('ok')\n"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        leaked = [n for n in set(os.listdir(tempfile.gettempdir())) - before
                  if n.startswith(("lpm-guards-", "lpm-pyc-"))]
        self.assertEqual(leaked, [])


class TheLoop(unittest.TestCase):
    def test_a_failing_child_fails_the_run_and_its_output_survives(self):
        proc = _main_over(["import sys\nprint('the reason', file=sys.stderr)\nsys.exit(1)\n"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("the reason", proc.stdout)
        self.assertIn("1 of 1 failed", proc.stdout)

    def test_a_silent_child_is_not_a_pass(self):
        proc = _main_over(["pass\n"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("produced no output", proc.stdout)

    def test_a_hanging_child_names_itself_rather_than_the_job(self):
        proc = _main_over(["import time\nprint('x', flush=True)\ntime.sleep(600)\n"],
                          env={"LPM_GUARD_TIMEOUT": "2"})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("did not finish within 2s", proc.stdout)
        self.assertIn("check-case0.py", proc.stdout)

    def test_every_child_runs_even_after_one_fails(self):
        """"which guards are broken" is more useful than "the first one"."""
        proc = _main_over(["import sys\nprint('first failed')\nsys.exit(1)\n",
                           "print('second ran')\n"])
        self.assertEqual(proc.returncode, 1)
        # The second one's OWN output is in its log file rather than the console -- that is the
        # point of the per-run log directory. What the console must show is that it ran at all.
        self.assertRegex(proc.stdout, r"ok\s+\S*check-case1\.py")
        self.assertIn("1 of 2 failed", proc.stdout)
        self.assertIn("first failed", proc.stdout, "a FAILING child's output is still printed")

    def test_each_child_reports_its_own_wall_time(self):
        proc = _main_over(["print('a')\n", "print('b')\n"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("s total; slowest:", proc.stdout)
        self.assertEqual(proc.stdout.count("check-case"), 6,
                         "two announcements, two results, two in the slowest list")

    def test_discovering_nothing_is_not_a_pass(self):
        proc = _main_over([])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("that is not a pass", proc.stdout)


class TheEndToEndPythonFloor(unittest.TestCase):
    """Runs the REAL file under the machine's real Apple `/usr/bin/python3` -- nothing patched.

    GitHub's macOS runners usually ship Apple's /usr/bin/python3 at 3.9, which is exactly the
    interpreter #1056 is about, so this case may well run under CI too rather than skip there --
    it does not assume either way. It skips, with a reason, only when THIS machine's
    `/usr/bin/python3` is missing or already at the floor; both are real states of the machine,
    not a failure of the check.
    """

    def test_apple_python3_is_refused_before_any_guard_runs(self):
        apple_python3 = "/usr/bin/python3"
        if not os.path.exists(apple_python3):
            self.skipTest(f"{apple_python3} does not exist on this machine")
        probe = subprocess.run(
            [apple_python3, "-c", "import sys; print('%d.%d' % sys.version_info[:2])"],
            capture_output=True, text=True, timeout=10)
        if probe.returncode != 0:
            self.skipTest(f"{apple_python3} could not report its own version: {probe.stderr!r}")
        major, minor = (int(part) for part in probe.stdout.strip().split("."))
        if (major, minor) >= runner.PYTHON_FLOOR:
            self.skipTest(f"{apple_python3} reports {major}.{minor}, already at or above "
                          f"the {'.'.join(str(p) for p in runner.PYTHON_FLOOR)} floor")
        proc = subprocess.run(
            [apple_python3, os.path.join("Scripts", "run-repo-guards.py")],
            cwd=REPO, capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("3.10", proc.stdout)
        self.assertIn("sys.stdlib_module_names", proc.stdout)
        self.assertNotIn("→   ", proc.stdout, "a guard was announced -- discovery must not run")
        self.assertNotIn("discovered", proc.stdout, "discovery ran before the floor was checked")


if __name__ == "__main__":
    unittest.main(verbosity=2)
