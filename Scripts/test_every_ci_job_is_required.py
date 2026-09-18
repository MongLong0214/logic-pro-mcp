#!/usr/bin/env python3
"""Cases for check-every-ci-job-is-required.py, driven against fixtures rather than the real file.

The baseline case runs against the REAL workflow, because a guard that only ever sees fixtures is
a guard nobody has pointed at the thing it is for -- which is how `check-livekit-ui-literals.py`
came to scan `Sources/` while the defect lived in `Scripts/livekit`.
"""
import importlib.util
import json
import os
import shutil
import tempfile
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(REPO, "Scripts", "check-every-ci-job-is-required.py")
spec = importlib.util.spec_from_file_location("ci_jobs_required_under_test", GUARD)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

FLOW = """\
name: CI
on: [push]
jobs:
  alpha:
    runs-on: ubuntu-latest
  beta:
    runs-on: ubuntu-latest
  build:
    needs: [alpha, beta]
    runs-on: ubuntu-latest
"""

BLOCK = """\
name: CI
on: [push]
jobs:
  alpha:
    runs-on: ubuntu-latest
  build:
    needs:
      - alpha
    runs-on: ubuntu-latest
"""


class Parsing(unittest.TestCase):
    def test_a_flow_sequence_is_read(self):
        names, needs = guard.jobs_and_needs(FLOW)
        self.assertEqual(names, ["alpha", "beta", "build"])
        self.assertEqual(needs, ["alpha", "beta"])

    def test_a_block_sequence_is_read(self):
        names, needs = guard.jobs_and_needs(BLOCK)
        self.assertEqual(names, ["alpha", "build"])
        self.assertEqual(needs, ["alpha"])

    def test_a_needs_belonging_to_another_job_is_not_read_as_the_gates(self):
        """The parser must attribute `needs:` to its own job. Reading any `needs:` in the file
        would let a non-gate job's dependencies stand in for the gate's."""
        text = """\
name: CI
on: [push]
jobs:
  alpha:
    needs: [zulu]
    runs-on: ubuntu-latest
  build:
    needs: [alpha]
    runs-on: ubuntu-latest
"""
        names, needs = guard.jobs_and_needs(text)
        self.assertEqual(needs, ["alpha"])
        self.assertNotIn("zulu", needs)


class Refusals(unittest.TestCase):
    def setUp(self):
        """Point the guard at a policy of its own, so a fixture is judged by fixture rules.

        The real `CI-GATE.json` names commands the real workflow carries; a three-job fixture does
        not carry them, and judging the fixture by the repository's policy made every case fail on
        a missing command rather than on the defect it injected.
        """
        self.policy = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False,
                                                  encoding="utf-8")
        # A workflow DIRECTORY of its own too, for the same reason as the policy: `check_workflows`
        # reads every file in it, and pointing a fixture case at the repository's real directory
        # mixed the repository's answers into the fixture's.
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        with open(os.path.join(self.dir, "ci.yml"), "w", encoding="utf-8") as handle:
            handle.write(FLOW)
        json.dump({"not_required": {"build": "it IS the gate"}, "required_commands": [],
                   "workflows": {"ci.yml": {"gates_merges": True, "why": "the audited one",
                                            "required_commands": []}}},
                  self.policy)
        self.policy.close()
        self.addCleanup(os.remove, self.policy.name)
        self.saved, guard.POLICY_PATH = guard.POLICY_PATH, self.policy.name
        self.addCleanup(lambda: setattr(guard, "POLICY_PATH", self.saved))
        self.saved_dir, guard.WORKFLOW_DIR = guard.WORKFLOW_DIR, self.dir
        self.addCleanup(lambda: setattr(guard, "WORKFLOW_DIR", self.saved_dir))

    def _policy(self, **overrides):
        """Rewrite the fixture policy, so a case can change one key and keep the rest."""
        body = {"not_required": {"build": "it IS the gate"}, "required_commands": [],
                "workflows": {"ci.yml": {"gates_merges": True, "why": "the audited one",
                                         "required_commands": []}}}
        body.update(overrides)
        with open(self.policy.name, "w", encoding="utf-8") as handle:
            json.dump(body, handle)

    def _check(self, text):
        handle = tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False, encoding="utf-8")
        handle.write(text)
        handle.close()
        self.addCleanup(os.remove, handle.name)
        return guard.check(handle.name)

    def test_a_clean_workflow_passes(self):
        self.assertEqual(self._check(FLOW), [])

    def test_a_job_outside_the_gate_fails(self):
        """The defect this guard exists for, three times over."""
        text = FLOW.replace("needs: [alpha, beta]", "needs: [alpha]")
        problems = self._check(text)
        self.assertTrue(any("`beta` is in no required gate" in p for p in problems), problems)

    def test_a_gate_with_no_needs_fails(self):
        text = FLOW.replace("    needs: [alpha, beta]\n", "")
        problems = self._check(text)
        self.assertTrue(any("requires nothing" in p for p in problems), problems)

    def test_a_needs_naming_a_job_that_does_not_exist_fails(self):
        text = FLOW.replace("needs: [alpha, beta]", "needs: [alpha, beta, ghost]")
        problems = self._check(text)
        self.assertTrue(any("is not a job in this workflow" in p for p in problems), problems)

    def test_a_workflow_with_no_gate_fails(self):
        problems = self._check(FLOW.replace("  build:", "  assemble:"))
        self.assertTrue(any("no `build` job" in p for p in problems), problems)

    def test_a_waiver_for_a_job_that_is_gone_fails(self):
        self._policy(not_required={"build": "x", "ghost": "reason"})
        problems = self._check(FLOW)
        self.assertTrue(any("outlived its reason" in p for p in problems), problems)

    def test_check_actually_calls_the_workflow_rules(self):
        """Through `check()`, not by calling `check_workflows` directly.

        The class below drives `check_workflows` on its own, which proves the rules work and
        proves nothing about whether anything runs them: deleting the one call site left every
        case in that class green. A named site and an enforcement site being different things is
        this guard's entire subject, and its own suite had the defect.
        """
        with open(os.path.join(self.dir, "undeclared.yml"), "w", encoding="utf-8") as handle:
            handle.write("name: x\n")
        problems = self._check(FLOW)
        self.assertTrue(any("undeclared.yml" in p for p in problems), problems)

    def test_a_required_command_that_no_step_runs_fails(self):
        """A required JOB says nothing about its STEPS; deleting a step leaves the job green."""
        self._policy(required_commands=["python3 Scripts/nothing-runs-this.py"])
        problems = self._check(FLOW)
        self.assertTrue(any("no step runs" in p for p in problems), problems)


class TheBodyGateMustRerunWhenTheBodyChanges(unittest.TestCase):
    """`pull_request:` with no `types:` never fires on `edited`, and one job reads the BODY.

    So the gate saw the body as of the last PUSH and never again: open a compliant pull request,
    let it go green, edit the citations out, and nothing re-runs. Measured on this repository's own
    ruleset -- `build`, `compile` and `test` are the required contexts, and none of them would have
    looked at the body again.
    """

    def _flow(self, trigger, body_step=True):
        step = "python3 Scripts/check-canon-citations.py --text /tmp/b.md" if body_step else "true"
        return f"""on:
  pull_request:
    branches: [main]
{trigger}
jobs:
  reads-the-body:
    steps:
      - run: {step}
  build:
    needs: [reads-the-body]
    steps:
      - run: true
"""

    def _check(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False) as handle:
            handle.write(text)
            path = handle.name
        self.addCleanup(os.unlink, path)
        return guard.check(path)

    def test_the_default_types_are_refused_when_a_step_reads_the_body(self):
        problems = self._check(self._flow(""))
        self.assertTrue(any("does not list `edited`" in p for p in problems), problems)

    def test_listing_edited_passes(self):
        problems = self._check(self._flow("    types: [opened, synchronize, reopened, edited]"))
        self.assertFalse(any("edited" in p for p in problems), problems)

    def test_types_without_edited_is_refused(self):
        """An explicit list is not automatically a complete one."""
        problems = self._check(self._flow("    types: [opened, synchronize]"))
        self.assertTrue(any("does not list `edited`" in p for p in problems), problems)

    def test_a_workflow_that_reads_no_body_is_not_asked_for_edited(self):
        """The rule is about the body, not about triggers in general."""
        problems = self._check(self._flow("", body_step=False))
        self.assertFalse(any("edited" in p for p in problems), problems)


class AgainstTheRealWorkflow(unittest.TestCase):
    def test_the_repositorys_own_workflow_passes(self):
        self.assertEqual(guard.check(), [])

    def test_the_real_workflow_rebuilds_when_the_body_is_edited(self):
        text = open(guard.WORKFLOW, encoding="utf-8").read()
        self.assertIn("edited", text)
        self.assertIn("--text", text, "if the body step is gone this assertion is about nothing")

    def test_the_canon_citation_job_is_actually_required(self):
        """Named rather than left to the general rule, because this is the job that was omitted."""
        names, needs = guard.jobs_and_needs(open(guard.WORKFLOW, encoding="utf-8").read())
        self.assertIn("canon-citations-in-the-pull-request", names)
        self.assertIn("canon-citations-in-the-pull-request", needs)

    def test_the_guards_run_once_and_are_required(self):
        """The whole point of splitting them out: one job runs them, and `build` looks at it."""
        text = open(guard.WORKFLOW, encoding="utf-8").read()
        self.assertEqual(text.count("python3 Scripts/run-repo-guards.py"), 1,
                         "the runner is what used to be duplicated across compile and test")
        names, needs = guard.jobs_and_needs(text)
        self.assertIn("guards", names)
        self.assertIn("guards", needs)

    def test_every_workflow_file_is_declared(self):
        rules = guard.policy()
        on_disk = {n for n in os.listdir(guard.WORKFLOW_DIR) if n.endswith((".yml", ".yaml"))}
        self.assertEqual(on_disk - set(rules["workflows"]), set())

    def test_the_moved_roadmap_commands_are_in_the_workflow_that_now_owns_them(self):
        """The command follows the workflow, or the check was lost in the move."""
        declared = guard.policy()["workflows"]["maintenance.yml"]["required_commands"]
        self.assertIn("python3 Scripts/roadmap-table-matches-github.py", declared)
        body = open(os.path.join(guard.WORKFLOW_DIR, "maintenance.yml"), encoding="utf-8").read()
        for command in declared:
            self.assertIn(command, body)
        ci = open(guard.WORKFLOW, encoding="utf-8").read()
        self.assertNotIn("roadmap-table-matches-github.py", ci,
                         "it moved; a copy left behind is the duplicate run this split removes")


class WorkflowDeclarations(unittest.TestCase):
    """The file-level half: a workflow nobody declared is a gate nobody wired up."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.saved_dir, guard.WORKFLOW_DIR = guard.WORKFLOW_DIR, self.dir
        self.addCleanup(lambda: setattr(guard, "WORKFLOW_DIR", self.saved_dir))

    def _write(self, name, body=""):
        with open(os.path.join(self.dir, name), "w", encoding="utf-8") as handle:
            handle.write(body)

    def _run(self, workflows):
        problems = []
        guard.check_workflows({"workflows": workflows}, problems)
        return problems

    def test_an_undeclared_workflow_fails(self):
        self._write("surprise.yml")
        problems = self._run({})
        self.assertTrue(any("surprise.yml" in p and "no entry" in p for p in problems), problems)

    def test_a_declaration_with_no_reason_fails(self):
        self._write("thing.yml")
        problems = self._run({"thing.yml": {"gates_merges": False, "why": "  "}})
        self.assertTrue(any("needs `gates_merges` and a `why`" in p for p in problems), problems)

    def test_a_declaration_with_no_gates_merges_fails(self):
        self._write("thing.yml")
        problems = self._run({"thing.yml": {"why": "because"}})
        self.assertTrue(any("needs `gates_merges` and a `why`" in p for p in problems), problems)

    def test_a_second_workflow_claiming_to_gate_fails(self):
        """Only `ci.yml` is audited, so another file saying it gates is a claim nobody checks."""
        self._write("other.yml")
        problems = self._run({"other.yml": {"gates_merges": True, "why": "claims to"}})
        self.assertTrue(any("only audits ci.yml" in p for p in problems), problems)

    def test_a_declared_command_that_no_step_runs_fails(self):
        self._write("thing.yml", "jobs:\n  a:\n    steps: []\n")
        problems = self._run({"thing.yml": {"gates_merges": False, "why": "because",
                                            "required_commands": ["python3 Scripts/moved.py"]}})
        self.assertTrue(any("no step runs" in p for p in problems), problems)

    def test_a_declaration_for_a_file_that_is_gone_fails(self):
        problems = self._run({"deleted.yml": {"gates_merges": False, "why": "because"}})
        self.assertTrue(any("deleted.yml" in p and "not a file" in p for p in problems), problems)

    def test_a_declared_workflow_carrying_its_command_passes(self):
        self._write("thing.yml", "run: python3 Scripts/moved.py\n")
        self.assertEqual(self._run({"thing.yml": {"gates_merges": False, "why": "because",
                                                  "required_commands": ["python3 Scripts/moved.py"]}}),
                         [])


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))




class TheEntryPointRefuses(unittest.TestCase):
    """The cases above call the guard's helpers. A `main()` that returned 0 without ever calling
    them would pass every one, because the repository passes --
    `Scripts/mutation-sweep-guard-tests.py` measured exactly that on 2026-09-18. A guard is its
    entry point, so these drive it at an input that must fail, with a control that must pass.
    """

    def _run(self, script, **env):
        import subprocess
        return subprocess.run(
            [sys.executable, os.path.join(REPO_ROOT, "Scripts", script)],
            capture_output=True, text=True, env=dict(os.environ, **env))
    def test_a_job_outside_the_aggregate_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.join(REPO_ROOT, ".github", "workflows", "ci.yml")
            source = open(real, encoding="utf-8").read()
            assert source.count("  guards:\n") == 1
            path = os.path.join(tmp, "ci.yml")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(source.replace(
                    "  guards:\n",
                    "  decoy:\n    runs-on: ubuntu-latest\n    steps:\n      - run: exit 1\n\n  guards:\n", 1))
            proc = self._run("check-every-ci-job-is-required.py", LPM_CI_WORKFLOW=path)
            self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[:300])
            self.assertIn("decoy", proc.stdout + proc.stderr)

    def test_the_repositorys_own_workflow_is_accepted(self):
        """The control. Without it the case above passes on a guard that refuses every workflow."""
        proc = self._run("check-every-ci-job-is-required.py")
        self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[:300])


if __name__ == "__main__":
    unittest.main(verbosity=2)
