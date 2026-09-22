#!/usr/bin/env python3
"""The classifier's decisions, and the workflow wiring that makes them safe.

Two halves, and the second is the load-bearing one. The classifier is twelve lines and easy to get
right; what is easy to get WRONG is the workflow, because the obvious way to skip a job -- an `if:`
and nothing else -- publishes a `skipped` check run under the job's own name, and GitHub counts a
skipped required check as satisfied. That is a metadata edit silently supplying a passing `compile`
over a real failure on the same commit, and no assertion about `classify()` would notice it.

So these cases read `.github/workflows/ci.yml` and assert that every job whose name is a required
context, or which the required context depends on, carries BOTH the condition and a non-canonical
display name for the skipped case.

Since #960 there is a third half, and it is where the rule now BITES. `ci.yml` no longer subscribes
to `edited`, because a metadata-only run of it still creates a check suite and the ruleset reads
the newest suite for an app -- so a description edit made the three code contexts read as
`expected` and refused the merge. The retarget that subscription existed for is refused instead by
`review_edit()`, which `pr-policy.yml` runs as `--refuse-unvalidated-edit`. `RetargetRefusal` below
measures both sides of that: the decision, and the fact that the body gate actually calls it.

Comment lines are stripped before any of that is matched. A rule about what a workflow RUNS that a
comment can satisfy is a rule about prose.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import importlib.util

_spec = importlib.util.spec_from_file_location(
    "classify_pull_request_event",
    os.path.join(REPO, "Scripts", "classify-pull-request-event.py"))
classifier = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(classifier)

CI = os.path.join(REPO, ".github", "workflows", "ci.yml")

#: The jobs the branch ruleset requires, plus the ones the required aggregate depends on. Every one
#: of them must be unable to publish its canonical name for a metadata-only edit.
GATED_JOBS = ("guards", "compile", "test", "formula", "build")

#: The contexts the branch ruleset requires (re-read from the API 2026-09-21). A name a skipped job
#: could publish must never be one of these.
REQUIRED_CONTEXTS = ("build", "compile", "test", "pr-policy")

CONDITION = "needs.classify.outputs.code_validation_required == 'true'"


def executable_lines(text: str):
    """The file's lines with comment-only lines dropped."""
    return [line for line in text.splitlines() if not line.lstrip().startswith("#")]


def workflow_text() -> str:
    with open(CI, "r", encoding="utf-8") as handle:
        return handle.read()


def job_blocks(text: str) -> dict:
    """Each top-level job's own lines, by job name, read by indentation."""
    blocks, current, in_jobs = {}, None, False
    for line in executable_lines(text):
        if line.startswith("jobs:"):
            in_jobs = True
            continue
        if in_jobs and line and not line[0].isspace():
            in_jobs = False
        if not in_jobs:
            continue
        stripped = line.strip()
        if (line.startswith("  ") and not line.startswith("   ")
                and stripped.endswith(":") and stripped):
            current = stripped[:-1]
            blocks[current] = []
            continue
        if current is not None:
            blocks[current].append(line)
    return {name: "\n".join(lines) for name, lines in blocks.items()}


def run_classifier(event_name, payload, argv=()):
    """Drive the ENTRY POINT, not `classify()`, at a payload written to a real file.

    A case that only calls `classify()` leaves `main()` free to print anything; the workflow reads
    stdout and, for `--refuse-unvalidated-edit`, the EXIT STATUS, so both are what have to be
    measured. `argv` is the command line `pr-policy.yml` or `ci.yml` passes.
    """
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        if payload is not None:
            json.dump(payload, handle)
        path = handle.name
    try:
        environment = dict(os.environ, GITHUB_EVENT_NAME=event_name, GITHUB_EVENT_PATH=path)
        finished = subprocess.run(
            [sys.executable, os.path.join(REPO, "Scripts", "classify-pull-request-event.py"),
             *argv],
            capture_output=True, text=True, env=environment)
        return finished.returncode, finished.stdout.strip()
    finally:
        os.unlink(path)


class ClassifierDecisions(unittest.TestCase):
    """E01, E03, E06, E07, E08, E09 -- what each event shape decides."""

    def test_opened_synchronize_and_reopened_are_code(self):
        for action in ("opened", "synchronize", "reopened"):
            with self.subTest(action=action):
                self.assertEqual(
                    classifier.classify("pull_request", {"action": action}), classifier.CODE)

    def test_a_push_is_code_and_needs_no_pull_request_body(self):
        # E08. A push to main carries no pull request at all; the classifier must not need one.
        self.assertEqual(classifier.classify("push", {}), classifier.CODE)
        self.assertEqual(classifier.classify("push", None), classifier.CODE)

    def test_title_only_and_body_only_edits_are_metadata(self):
        # E03 and E02's trigger.
        for changes in ({"title": {"from": "x"}},
                        {"body": {"from": "x"}},
                        {"title": {"from": "x"}, "body": {"from": "y"}}):
            with self.subTest(changes=sorted(changes)):
                self.assertEqual(
                    classifier.classify("pull_request", {"action": "edited", "changes": changes}),
                    classifier.METADATA_ONLY)

    def test_a_retarget_is_code_even_when_the_title_changed_with_it(self):
        # E06. `base` is how a retarget arrives, and it arrives as `edited` like a typo fix does.
        for changes in ({"base": {"ref": {"from": "dev"}}},
                        {"base": {"ref": {"from": "dev"}}, "title": {"from": "x"}}):
            with self.subTest(changes=sorted(changes)):
                self.assertEqual(
                    classifier.classify("pull_request", {"action": "edited", "changes": changes}),
                    classifier.CODE)

    def test_an_unknown_changes_key_is_code(self):
        # E07, and the reason this is a set comparison rather than a `base` check. A key nobody has
        # taught this code about must not inherit the exemption by saying nothing.
        for changes in ({"milestone": {"from": None}},
                        {"title": {"from": "x"}, "milestone": {"from": None}}):
            with self.subTest(changes=sorted(changes)):
                self.assertEqual(
                    classifier.classify("pull_request", {"action": "edited", "changes": changes}),
                    classifier.CODE)

    def test_an_edited_with_no_changes_object_is_code(self):
        for event in ({"action": "edited"},
                      {"action": "edited", "changes": {}},
                      {"action": "edited", "changes": None},
                      {"action": "edited", "changes": []}):
            with self.subTest(event=event):
                self.assertEqual(classifier.classify("pull_request", event), classifier.CODE)

    def test_a_malformed_payload_is_code(self):
        for event in (None, [], "edited", 3):
            with self.subTest(event=event):
                self.assertEqual(classifier.classify("pull_request", event), classifier.CODE)


class ClassifierEntryPoint(unittest.TestCase):
    """What the workflow actually reads: stdout, from a real process, at a real file."""

    def test_stdout_is_the_token_and_nothing_else(self):
        code, out = run_classifier("pull_request", {"action": "edited",
                                                    "changes": {"title": {"from": "x"}}})
        self.assertEqual(code, 0)
        self.assertEqual(out, classifier.METADATA_ONLY)

    def test_a_hostile_title_does_not_reach_stdout(self):
        # P07. The body and title are attacker-controlled. Nothing here prints them, and the
        # workflow compares stdout against a literal rather than evaluating it.
        hostile = "$(touch /tmp/pwned); `id`; \"; rm -rf /; #"
        code, out = run_classifier("pull_request", {
            "action": "edited",
            "changes": {"title": {"from": hostile}},
            "pull_request": {"title": hostile, "body": hostile}})
        self.assertEqual(code, 0)
        self.assertEqual(out, classifier.METADATA_ONLY)
        self.assertNotIn("rm -rf", out)

    def test_an_unreadable_payload_prints_code_and_exits_zero(self):
        # Exiting non-zero here would fail the classify job, and the workflow's own fallback then
        # decides. Printing `code` is the answer that runs the full validation.
        environment = dict(os.environ, GITHUB_EVENT_NAME="pull_request",
                           GITHUB_EVENT_PATH="/nonexistent/event.json")
        finished = subprocess.run(
            [sys.executable, os.path.join(REPO, "Scripts", "classify-pull-request-event.py")],
            capture_output=True, text=True, env=environment)
        self.assertEqual(finished.returncode, 0)
        self.assertEqual(finished.stdout.strip(), classifier.CODE)


class WorkflowWiring(unittest.TestCase):
    """E04, E05, E10 -- the half a `classify()` assertion cannot see."""

    def setUp(self):
        self.text = workflow_text()
        self.executable = "\n".join(executable_lines(self.text))
        self.jobs = job_blocks(self.text)

    def test_every_gated_job_is_conditional_on_the_classifier(self):
        for job in GATED_JOBS:
            with self.subTest(job=job):
                self.assertIn(job, self.jobs, f"`{job}` is not a job in ci.yml")
                block = self.jobs[job]
                condition = re.search(r"^    if:(.*)$", block, re.M)
                self.assertIsNotNone(condition, f"`{job}` has no job-level `if:`")
                self.assertIn(CONDITION, condition.group(1),
                              f"`{job}`'s `if:` does not consult the classifier")

    def test_every_gated_job_publishes_a_non_canonical_name_when_it_skips(self):
        # This is the case that fails if somebody "simplifies" the workflow by deleting the `name:`
        # expressions: a skipped job would then publish `compile`, `test` or `build`, and GitHub
        # counts a skipped required check as satisfied.
        for job in GATED_JOBS:
            with self.subTest(job=job):
                block = self.jobs[job]
                name = re.search(r"^    name:(.*)$", block, re.M)
                self.assertIsNotNone(name, f"`{job}` has no job-level `name:`")
                value = name.group(1)
                self.assertIn(CONDITION, value,
                              f"`{job}`'s display name does not depend on the classifier")
                literals = re.findall(r"'([^']*)'", value)
                # `&& <a> || <b>`: the first literal after the condition is the canonical name and
                # the second is what a skipped job publishes.
                canonical = [lit for lit in literals if lit == job]
                self.assertEqual(len(canonical), 1,
                                 f"`{job}` does not name itself exactly once in its `name:`")
                others = [lit for lit in literals if lit != job and lit not in ("true", "false")]
                self.assertTrue(others, f"`{job}` has no non-canonical name for the skipped case")
                for other in others:
                    self.assertNotIn(other, REQUIRED_CONTEXTS,
                                     f"`{job}`'s skipped name `{other}` IS a required context")
                    self.assertIn("not a code gate", other,
                                  f"`{job}`'s skipped name `{other}` does not say it is not a gate")

    def test_the_aggregate_depends_on_the_classifier_and_checks_its_result(self):
        build = self.jobs["build"]
        needs = re.search(r"^    needs:\s*\[([^\]]*)\]", build, re.M)
        self.assertIsNotNone(needs)
        listed = [item.strip() for item in needs.group(1).split(",") if item.strip()]
        self.assertIn("classify", listed)
        for job in ("guards", "compile", "test", "formula"):
            self.assertIn(job, listed)
        # Every need is compared against `success` by name. A need the aggregate forgets is a job
        # that can go red while the only required context stays green.
        for job in listed:
            with self.subTest(job=job):
                self.assertRegex(build, rf'\[ "\${job.upper()}" = "success" \]')

    def test_the_aggregate_still_refuses_to_decide_a_cancelled_run(self):
        # A cancelled run has no verdict to give, and `!cancelled()` is what stops it publishing
        # one. Without it a superseded run leaves a red `build` on top of a healthy one.
        self.assertRegex(self.jobs["build"], r"(?m)^    if:.*!cancelled\(\)")

    def _concurrency_group(self):
        group = re.search(r"^concurrency:\n(?:.*\n)*?\s*group:(.*(?:\n\s{4,}.*)*)",
                          self.executable, re.M)
        self.assertIsNotNone(group, "ci.yml has no concurrency group")
        return " ".join(group.group(1).split())

    def test_the_body_check_is_no_longer_in_the_code_workflow(self):
        # It moved to the separately required `pr-policy` context. Leaving a copy here is what made
        # a description edit restart a macOS test job.
        self.assertNotIn("--text", self.executable)
        self.assertNotIn("canon-citations-in-the-pull-request", self.executable)

    def test_the_code_workflow_does_not_subscribe_to_edited(self):
        # The inverse of the case that stood here until 2026-09-22, and the reason is #960: a run
        # of this workflow on an `edited` publishes no check run under `build`, `compile` or
        # `test`, but it still creates a check SUITE, and the ruleset reads the newest suite for an
        # app -- so the three contexts read as `expected` again and the merge was refused until a
        # close-and-reopen. E06 did not go away with the subscription; it moved to `pr-policy.yml`,
        # and the two cases below are what hold it there.
        trigger = re.search(r"^\s*types:\s*\[([^\]]*)\]", self.executable, re.M)
        self.assertIsNotNone(trigger)
        listed = {item.strip() for item in trigger.group(1).split(",") if item.strip()}
        self.assertEqual(listed, {"opened", "synchronize", "reopened"})

    def test_the_concurrency_group_no_longer_carries_a_metadata_domain(self):
        # It carried `-metadata` and `-code` so that a description edit could not cancel a running
        # macOS job. With `edited` unsubscribed no run reaching this expression is a description
        # edit, so every run in the group is a code run and a newer one should supersede an older.
        # What this case refuses is the half-change: `edited` back in the trigger with the single
        # domain left here would restore the cancellation the two domains were built to stop.
        group = self._concurrency_group()
        self.assertNotIn("metadata", group)
        self.assertNotIn("github.event.changes", group)
        self.assertIn("github.workflow", group)
        self.assertIn("github.ref", group)


class RetargetRefusal(unittest.TestCase):
    """E06 after #960: the code gates do not hear an `edited`, so `pr-policy` refuses it."""

    POLICY = os.path.join(REPO, ".github", "workflows", "pr-policy.yml")

    def test_an_edit_that_is_only_title_or_body_is_allowed(self):
        for changes in ({"title": {"from": "x"}},
                        {"body": {"from": "x"}},
                        {"title": {"from": "x"}, "body": {"from": "y"}}):
            with self.subTest(changes=sorted(changes)):
                self.assertEqual(
                    classifier.review_edit("pull_request",
                                           {"action": "edited", "changes": changes}),
                    classifier.ALLOW)

    def test_a_retarget_is_refused(self):
        for changes in ({"base": {"ref": {"from": "dev"}}},
                        {"base": {"ref": {"from": "dev"}}, "title": {"from": "x"}}):
            with self.subTest(changes=sorted(changes)):
                self.assertEqual(
                    classifier.review_edit("pull_request",
                                           {"action": "edited", "changes": changes}),
                    classifier.REFUSE)

    def test_an_unknown_changes_key_is_refused_too(self):
        # The same reason the classifier refuses to exempt it. An editable field nobody has taught
        # this code about may change what the pull request MEANS, and with `edited` gone from
        # `ci.yml` nothing else will look at it.
        self.assertEqual(
            classifier.review_edit("pull_request",
                                   {"action": "edited", "changes": {"milestone": {"from": None}}}),
            classifier.REFUSE)

    def test_what_cannot_be_read_is_refused(self):
        for event_name, event in (("pull_request", None),
                                  ("pull_request", []),
                                  ("pull_request", "edited"),
                                  ("pull_request", {"action": "edited"}),
                                  ("pull_request", {"action": "edited", "changes": {}}),
                                  ("", {"action": "edited", "changes": {"base": {}}}),
                                  ("issues", {"action": "edited"})):
            with self.subTest(event_name=event_name, event=event):
                self.assertEqual(classifier.review_edit(event_name, event), classifier.REFUSE)

    def test_the_events_the_code_gates_do_hear_are_allowed(self):
        # `pr-policy.yml` runs on these too, and refusing them would make every pull request red.
        for action in ("opened", "synchronize", "reopened"):
            with self.subTest(action=action):
                self.assertEqual(
                    classifier.review_edit("pull_request", {"action": action}), classifier.ALLOW)

    def test_the_exit_status_is_what_the_workflow_reads(self):
        # A red required check is the whole mechanism: `review_edit` returning REFUSE with exit 0
        # would leave the retarget merging on a stale verdict, and no assertion about the string
        # would notice.
        allowed = run_classifier("pull_request", {"action": "edited",
                                                  "changes": {"title": {"from": "x"}}},
                                 argv=[classifier.REFUSE_FLAG])
        self.assertEqual(allowed[0], 0)
        self.assertEqual(allowed[1].splitlines()[0], classifier.ALLOW)
        refused = run_classifier("pull_request",
                                 {"action": "edited", "changes": {"base": {"ref": {"from": "d"}}}},
                                 argv=[classifier.REFUSE_FLAG])
        self.assertEqual(refused[0], 1)
        self.assertEqual(refused[1].splitlines()[0], classifier.REFUSE)
        self.assertIn("::error::", refused[1])
        self.assertIn("#960", refused[1])

    def test_the_refusal_echoes_no_part_of_the_title_or_the_body(self):
        # An annotation is a rendering surface and both strings are attacker-controlled.
        hostile = "$(touch /tmp/pwned); `id`; <script>alert(1)</script>"
        code, out = run_classifier("pull_request", {
            "action": "edited",
            "changes": {"base": {"ref": {"from": hostile}}, "title": {"from": hostile}},
            "pull_request": {"title": hostile, "body": hostile}},
            argv=[classifier.REFUSE_FLAG])
        self.assertEqual(code, 1)
        self.assertNotIn("pwned", out)
        self.assertNotIn("<script>", out)

    def test_an_unreadable_payload_refuses_rather_than_allowing(self):
        environment = dict(os.environ, GITHUB_EVENT_NAME="pull_request",
                           GITHUB_EVENT_PATH="/nonexistent/event.json")
        finished = subprocess.run(
            [sys.executable, os.path.join(REPO, "Scripts", "classify-pull-request-event.py"),
             classifier.REFUSE_FLAG],
            capture_output=True, text=True, env=environment)
        self.assertEqual(finished.returncode, 1)
        self.assertEqual(finished.stdout.splitlines()[0], classifier.REFUSE)

    def test_an_unknown_flag_is_a_usage_error_and_not_a_decision(self):
        # A typo in the workflow's command line must not become a step that passes. Exit 2 is not
        # 0, and `pr-policy.yml` runs this with no `continue-on-error`.
        code, out = run_classifier("pull_request", {"action": "edited"}, argv=["--refuse"])
        self.assertEqual(code, 2)
        self.assertNotIn(classifier.ALLOW, out)

    def setUp(self):
        with open(self.POLICY, "r", encoding="utf-8") as handle:
            self.policy = "\n".join(executable_lines(handle.read()))

    def test_the_body_gate_still_hears_edited(self):
        # The rule is only enforced where the event arrives, and after #960 this is the only gate
        # that receives one. Dropping `edited` HERE too would leave a retarget reaching no gate at
        # all, which is a worse defect than the one #960 reports and would break no other case.
        trigger = re.search(r"^\s*types:\s*\[([^\]]*)\]", self.policy, re.M)
        self.assertIsNotNone(trigger)
        listed = {item.strip() for item in trigger.group(1).split(",") if item.strip()}
        self.assertIn("edited", listed)

    def test_the_body_gate_runs_the_refusal_unconditionally(self):
        # The half a `review_edit()` assertion cannot see: the decision is worth nothing if no
        # workflow asks for it, and worth nothing if the step that asks cannot fail the job.
        steps = re.split(r"(?m)^      - ", self.policy)[1:]
        invocation = f"Scripts/classify-pull-request-event.py {classifier.REFUSE_FLAG}"
        running = [step for step in steps if invocation in step]
        self.assertEqual(len(running), 1, f"`pr-policy.yml` runs {invocation!r} {len(running)}x")
        step = running[0]
        # `continue-on-error` makes a failed step a green job, and an `if:` is a switch a later
        # edit can leave off. Either one turns the merge block back into a notice.
        self.assertNotIn("continue-on-error", step)
        self.assertNotRegex(step, r"(?m)^        if:")


if __name__ == "__main__":
    unittest.main()
