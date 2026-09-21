#!/usr/bin/env python3
"""Cases for check-every-ci-job-is-required.py, driven against fixtures rather than the real file.

The baseline case runs against the REAL workflow, because a guard that only ever sees fixtures is
a guard nobody has pointed at the thing it is for -- which is how `check-livekit-ui-literals.py`
came to scan `Sources/` while the defect lived in `Scripts/livekit`.
"""
import importlib.util
import json
import os
import re
import shutil
import subprocess
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
        self.assertTrue(any("no step in any merge-gating workflow runs" in p for p in problems),
                        problems)

    def test_a_command_declared_as_one_workflows_own_that_it_does_not_run_fails(self):
        """The per-workflow half of the same rule. The top-level list may be satisfied by EITHER
        gate, so only this one says a named owner still carries what it declared."""
        self._policy(workflows={"ci.yml": {"gates_merges": True, "why": "the audited one",
                                           "required_commands": ["python3 Scripts/absent.py"]}})
        problems = self._check(FLOW)
        self.assertTrue(any("ci.yml: no step runs" in p for p in problems), problems)


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

    def test_whichever_workflow_reads_the_body_rebuilds_when_it_is_edited(self):
        """Aimed at the file that reads the body rather than at `ci.yml` by name.

        It used to assert `--text` was in `ci.yml`, with a message saying the assertion would be
        about nothing if the body step were gone. The step moved to `pr-policy.yml` on 2026-09-21
        and that message came true -- which is the whole subject of this guard, arriving in its
        own suite for the second time.
        """
        readers = []
        for name in sorted(guard.policy()["workflows"]):
            body = open(os.path.join(guard.WORKFLOW_DIR, name), encoding="utf-8").read()
            runnable = guard.executable(body)
            # `pull_request:` as well as `--text`: `canon-issue.yml` reads an ISSUE body on the
            # `issues` event, where there is no `edited` type to subscribe to and no merge to
            # block. The rule is about a body a merge waits on.
            if "--text" not in runnable or "pull_request:" not in runnable:
                continue
            readers.append(name)
            self.assertRegex(body, r"(?m)^\s*types:\s*\[[^\]]*\bedited\b", name)
        self.assertEqual(readers, ["pr-policy.yml"],
                         "no workflow reads the pull request body, so this case checks nothing")

    def test_the_body_check_lives_in_the_workflow_that_now_owns_it(self):
        """This job used to be `canon-citations-in-the-pull-request` in `ci.yml`, and this case
        used to assert it was in `build.needs`. It moved to `pr-policy.yml` on 2026-09-21 and
        became a required CONTEXT of its own, so asserting it is still a job here would fail --
        and repairing that by deleting the case would leave the move unchecked. The property is
        the same one: the body check exists somewhere the merge waits on."""
        ci = open(guard.WORKFLOW, encoding="utf-8").read()
        self.assertNotIn("canon-citations-in-the-pull-request", ci,
                         "a copy left behind is the duplicate run this split removes")
        entry = guard.policy()["workflows"]["pr-policy.yml"]
        self.assertTrue(entry["gates_merges"])
        self.assertEqual(entry["required_contexts"], ["pr-policy"])
        body = open(os.path.join(guard.WORKFLOW_DIR, "pr-policy.yml"), encoding="utf-8").read()
        names, _ = guard.jobs_and_needs(body)
        self.assertIn("pr-policy", names)

    def test_the_classifier_is_a_job_and_the_gate_waits_on_it(self):
        """`classify` decides whether this event needs code validation. `build` outside its
        `needs` is a gate that cannot see the decision it is conditioned on."""
        names, needs = guard.jobs_and_needs(open(guard.WORKFLOW, encoding="utf-8").read())
        self.assertIn("classify", names)
        self.assertIn("classify", needs)

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

    def test_a_second_workflow_claiming_to_gate_with_nothing_behind_it_fails(self):
        """A second gate has been allowed since 2026-09-21, when the body check became a required
        context of its own. What it may not be is a sentence: this file said it gated merges and
        the rule used to refuse it outright, which is not a rule that survives a real second gate.
        Now it must name the contexts the ruleset requires and own at least one command."""
        self._write("other.yml")
        problems = self._run({"other.yml": {"gates_merges": True, "why": "claims to"}})
        self.assertTrue(any("names no `required_contexts`" in p for p in problems), problems)
        self.assertTrue(any("owns no `required_commands`" in p for p in problems), problems)

    def test_a_second_gate_naming_a_context_no_job_publishes_fails(self):
        self._write("other.yml", "jobs:\n  real-job:\n    steps:\n      - run: python3 x.py\n")
        problems = self._run({"other.yml": {"gates_merges": True, "why": "it does",
                                            "required_contexts": ["typo-job"],
                                            "required_commands": ["python3 x.py"]}})
        self.assertTrue(any("is not a job in this workflow" in p for p in problems), problems)

    def test_a_second_gate_that_names_its_contexts_and_commands_passes(self):
        """The control for the three cases above: without it they pass on a rule that refuses
        every second gate, which is the rule they replaced."""
        self._write("other.yml", "jobs:\n  real-job:\n    steps:\n      - run: python3 x.py\n")
        self.assertEqual(self._run({"other.yml": {"gates_merges": True, "why": "it does",
                                                  "required_contexts": ["real-job"],
                                                  "required_commands": ["python3 x.py"]}}), [])

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


class SeamsAreDerivedNotListed(unittest.TestCase):
    """The seam set is read out of the scripts, so it cannot fall behind them.

    It was a hand-written tuple of twenty-one names and it HAD fallen behind: seams added since
    were missing, so a workflow could set one of those and the rule would not notice. A list of
    the things a rule protects is a second copy of the truth, and it goes stale in the direction
    where the protection is gone.
    """

    def _independent_scan(self):
        """Read the scripts here, so this compares two readers rather than asking one reader
        whether it agrees with itself."""
        found = set()
        for base, _dirs, files in os.walk(os.path.join(REPO, "Scripts")):
            for name in files:
                if not name.endswith((".py", ".sh")):
                    continue
                with open(os.path.join(base, name), encoding="utf-8") as handle:
                    for line in handle:
                        if line.strip().startswith("#"):
                            continue
                        found.update(re.findall(r'environ\.get\(["\'](LPM_[A-Z_]+)', line))
                        found.update(re.findall(r'\$\{(LPM_[A-Z_]+)', line))
        return found

    def test_every_seam_a_script_reads_is_protected(self):
        seams = guard.seam_names()
        self.assertTrue(seams, "an empty seam set would make the rule vacuous")
        missing = sorted(self._independent_scan() - seams)
        self.assertEqual(missing, [], f"seams a script reads but the rule does not protect: {missing}")

    def test_a_seam_added_after_the_list_was_written_is_protected(self):
        """The property the hand-written tuple did not have. These three did not exist when it was
        written; if the derivation regresses to a list they are the first to fall out of it."""
        seams = guard.seam_names()
        for recent in ("LPM_LABELSET_CENSUS", "LPM_APPLESCRIPT_ROOTS", "LPM_POLICY_SWIFT"):
            self.assertIn(recent, seams)

    def test_a_comment_naming_a_seam_is_not_a_read(self):
        """This guard's own explanation names a seam. Counting that would protect a variable no
        script asks for, and the rule would refuse a workflow over a word in a comment."""
        self.assertNotIn("LPM_X", guard.seam_names())

    def test_a_workflow_setting_a_recently_added_seam_is_refused(self):
        """End to end, at the seam the old list could not see."""
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.join(REPO, ".github", "workflows", "ci.yml")
            with open(real, encoding="utf-8") as handle:
                source = handle.read()
            assert source.count("  guards:\n") == 1
            path = os.path.join(tmp, "ci.yml")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(source.replace(
                    "  guards:\n",
                    "  guards:\n    env:\n      LPM_LABELSET_CENSUS: /dev/null\n", 1))
            proc = subprocess.run(
                [sys.executable, os.path.join(REPO, "Scripts", "check-every-ci-job-is-required.py")],
                capture_output=True, text=True,
                env=dict(os.environ, LPM_CI_WORKFLOW=path))
            self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[:300])
            self.assertIn("LPM_LABELSET_CENSUS", proc.stdout + proc.stderr)


class TheMigrationsOwnMutations(unittest.TestCase):
    """The 2026-09-21 split, driven at a COPY of the real tree with one thing broken at a time.

    The split moved the pull request body check out of `ci.yml` into `pr-policy.yml`, made
    `pr-policy` a required context beside build/compile/test, and made every code job wait on a
    classifier so a title edit stops restarting a macOS test run. Each of those moves has a way of
    being wrong that leaves every check green, and the sweep that proved this guard catches them
    was a throwaway script whose output lived only in a transcript. A control measured once and
    discarded is a control nobody has; these are that sweep, committed.

    They run against copies because the mutation is the point: the real files are never written.
    """

    REAL_WORKFLOWS = os.path.join(REPO, ".github", "workflows")
    REAL_POLICY = os.path.join(REPO, "docs", "canon", "CI-GATE.json")

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.workflows = os.path.join(self.dir, "workflows")
        shutil.copytree(self.REAL_WORKFLOWS, self.workflows)
        self.policy_path = os.path.join(self.dir, "CI-GATE.json")
        shutil.copy(self.REAL_POLICY, self.policy_path)
        self.saved = (guard.WORKFLOW_DIR, guard.POLICY_PATH)
        guard.WORKFLOW_DIR, guard.POLICY_PATH = self.workflows, self.policy_path

        def restore():
            guard.WORKFLOW_DIR, guard.POLICY_PATH = self.saved
        self.addCleanup(restore)

    def _path(self, name):
        return os.path.join(self.workflows, name)

    def _edit(self, name, old, new, count=1):
        """Rewrite one workflow, refusing a mutation that did not land.

        A `replace` whose needle has drifted is a no-op, and a no-op mutation makes the case pass
        for the reason the control passes -- the shape these cases exist to refuse.
        """
        with open(self._path(name), encoding="utf-8") as handle:
            text = handle.read()
        self.assertEqual(text.count(old), count,
                         f"{name}: the anchor for this mutation is not there {count} time(s)")
        with open(self._path(name), "w", encoding="utf-8") as handle:
            handle.write(text.replace(old, new))

    def _append_step(self, name, run):
        with open(self._path(name), "a", encoding="utf-8") as handle:
            handle.write(f"\n      - run: {run}\n")

    def _repolicy(self, mutate):
        with open(self.policy_path, encoding="utf-8") as handle:
            rules = json.load(handle)
        mutate(rules)
        with open(self.policy_path, "w", encoding="utf-8") as handle:
            json.dump(rules, handle)

    def _check(self):
        return guard.check(self._path("ci.yml"))

    def _refuses(self, needle):
        problems = self._check()
        self.assertTrue(any(needle in p for p in problems),
                        f"expected a problem mentioning {needle!r}; got {problems}")

    # ---- the control -------------------------------------------------------------------------
    def test_the_unmutated_copy_passes(self):
        """Without this every case below passes on a guard that refuses everything."""
        self.assertEqual(self._check(), [])

    # ---- the commands that moved ---------------------------------------------------------------
    def test_deleting_the_moved_changed_command_from_its_new_owner_fails(self):
        """G01. The destination, not the origin: after a move, deleting the check is an edit to
        `pr-policy.yml`, and a rule still aimed at `ci.yml` would call that clean."""
        self._edit("pr-policy.yml",
                   "run: python3 Scripts/check-canon-citations.py --changed pr-changed.txt",
                   "run: true")
        self._refuses("check-canon-citations.py --changed")

    def test_deleting_the_moved_body_command_from_its_new_owner_fails(self):
        """The `--text` invocation, pinned by its line continuation. The continuation is why the
        ratcheted entry survived the move instead of being dropped with the old job."""
        self._edit("pr-policy.yml",
                   "python3 Scripts/check-canon-citations.py \\\n            --text pr-body.md",
                   "true \\\n            --text pr-body.md")
        self._refuses("Scripts/check-canon-citations.py \\")

    def test_a_relocation_between_two_gates_passes(self):
        """G03a, and the reason the rule searches a UNION. Moving the coverage gate from `ci.yml`
        to `pr-policy.yml` changes which gate runs it and not whether a merge waits on it. A rule
        that failed here would be repaired by deleting the entry -- and the list may only grow,
        so that repair removes the requirement outright."""
        self._edit("ci.yml", "run: bash Scripts/ci-coverage-gate.sh", "run: true")
        self._append_step("pr-policy.yml", "bash Scripts/ci-coverage-gate.sh")
        self.assertEqual(self._check(), [])

    def test_deleting_the_coverage_gate_from_both_gates_fails(self):
        """G03b. The same edit as above without the destination: a move with nowhere to move to."""
        self._edit("ci.yml", "run: bash Scripts/ci-coverage-gate.sh", "run: true")
        self._refuses("bash Scripts/ci-coverage-gate.sh")

    def test_parking_a_gate_command_in_a_workflow_that_gates_nothing_fails(self):
        """G03c. `maintenance.yml` declares `gates_merges: false`; a check that runs there can go
        red with the merge permitted, so relocating into it is a deletion with a receipt."""
        self._edit("ci.yml", "run: bash Scripts/ci-coverage-gate.sh", "run: true")
        self._append_step("maintenance.yml", "bash Scripts/ci-coverage-gate.sh")
        self._refuses("bash Scripts/ci-coverage-gate.sh")

    def test_a_command_left_only_in_a_comment_fails(self):
        """The near-miss this guard's `executable()` exists for: the string is still in the file,
        and nothing runs it. A substring search over raw YAML reports the old owner as still
        running commands its comments merely describe."""
        self._edit("ci.yml",
                   "          python3 Scripts/run-repo-guards.py > guard-run.log 2>&1 || status=$?",
                   "          # python3 Scripts/run-repo-guards.py > guard-run.log 2>&1")
        self._refuses("python3 Scripts/run-repo-guards.py")

    def test_deleting_the_classifier_from_the_workflow_that_owns_it_fails(self):
        """The classifier is what keeps a metadata edit from restarting the code jobs. Deleting
        the step while the job-level conditions still read its output leaves those conditions
        reading an empty string -- which is not `'true'`, so the code gates never run."""
        self._edit("ci.yml",
                   "python3 Scripts/classify-pull-request-event.py",
                   "true #", count=1)
        self._refuses("classify-pull-request-event.py")

    # ---- the topology ---------------------------------------------------------------------------
    def test_a_code_job_dropped_from_the_aggregate_fails(self):
        """G02. The defect this whole guard exists for, at the job the migration touched most."""
        self._edit("ci.yml",
                   "needs: [classify, guards, compile, test, formula]",
                   "needs: [classify, guards, compile, formula]")
        self._refuses("`test` is in no required gate")

    # ---- the declaration itself -----------------------------------------------------------------
    def test_demoting_the_second_gate_fails(self):
        """`gates_merges: false` on `pr-policy.yml` is how the migration would be undone on paper
        while the file still sits there looking like a gate: its commands stop counting, because
        a workflow that gates nothing is not where a required check may live."""
        self._repolicy(lambda r: r["workflows"]["pr-policy.yml"].update({"gates_merges": False}))
        self._refuses("check-canon-citations.py --changed")

    def test_a_required_context_naming_no_job_fails(self):
        """A context nothing publishes is a merge that waits forever, or a rule aimed at nothing.
        Both look identical from inside this repository, which is why the name is checked against
        the file rather than against the ruleset."""
        self._repolicy(lambda r: r["workflows"]["pr-policy.yml"].update(
            {"required_contexts": ["pr-polcy"]}))
        self._refuses("is not a job in this workflow")

    def test_a_second_gate_naming_no_required_context_fails(self):
        self._repolicy(lambda r: r["workflows"]["pr-policy.yml"].update({"required_contexts": []}))
        self._refuses("names no `required_contexts`")

    def test_a_second_gate_owning_no_required_command_fails(self):
        """Without this an empty list is a gate that can be emptied one step at a time."""
        self._repolicy(lambda r: r["workflows"]["pr-policy.yml"].update({"required_commands": []}))
        self._refuses("owns no `required_commands`")

    def test_no_workflow_gating_at_all_fails(self):
        """The vacuity case. With an empty gating set the command search runs over an empty
        haystack and every entry is missing, so the guard must refuse the DECLARATION rather than
        report a clean repository with no gates."""
        def demote(rules):
            for entry in rules["workflows"].values():
                entry["gates_merges"] = False
        self._repolicy(demote)
        self._refuses("no workflow declares `gates_merges`")

    # ---- the events and the seams ---------------------------------------------------------------
    def test_the_body_gate_losing_edited_fails(self):
        """The body check moved, and so did the reason it needs `edited`: open a compliant pull
        request, let it go green, edit the citations out. Aiming this rule at `ci.yml` alone would
        now pass, because `ci.yml` no longer reads the body."""
        self._edit("pr-policy.yml",
                   "types: [opened, synchronize, reopened, edited]",
                   "types: [opened, synchronize, reopened]")
        self._refuses("does not list `edited`")

    def test_a_seam_set_in_the_second_gate_fails(self):
        """A pull request runs its own copy of `pr-policy.yml` too. Before the split this rule
        only looked at `ci.yml`, so the new gate was a place to lower a bar unwatched."""
        self._edit("pr-policy.yml",
                   "  pr-policy:\n    runs-on: ubuntu-latest\n",
                   "  pr-policy:\n    env:\n      LPM_COVERAGE_MIN_LINE: \"0\"\n"
                   "    runs-on: ubuntu-latest\n")
        self._refuses("LPM_COVERAGE_MIN_LINE")


if __name__ == "__main__":
    unittest.main(verbosity=2)
