#!/usr/bin/env python3
"""The classifier's decisions and the narrow workflow wiring around them.

`ci.yml` deliberately does not subscribe to `edited`: metadata-only code-CI runs leave the branch
ruleset's newest suite without its required contexts. Retarget validation instead belongs to
`pr-policy.yml`, which runs `review_edit()` with `--refuse-unvalidated-edit`.

The code workflow has fixed check names and no event classifier job. Its macOS offline guards run
independently of Swift tests, and the aggregate reports either failure. Comment lines are stripped
before workflow assertions: comments must not satisfy a rule about executed configuration.
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

REQUIRED_CONTEXTS = ("build", "compile", "test")
AGGREGATE_JOBS = ("guards", "offline-guards", "compile", "test", "formula")
SETUP_PYTHON_SHA = "a26af69be951a213d495a4c3e4e4022e16d87065"


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
    """The fixed code-CI schedule and its aggregate."""

    def setUp(self):
        self.text = workflow_text()
        self.executable = "\n".join(executable_lines(self.text))
        self.jobs = job_blocks(self.text)

    def test_code_ci_has_fixed_jobs_without_event_classification(self):
        self.assertNotIn("classify", self.jobs)
        self.assertNotIn("code_validation_required", self.executable)
        for job in (*AGGREGATE_JOBS, "build"):
            with self.subTest(job=job):
                self.assertIn(job, self.jobs)
                self.assertRegex(self.jobs[job], rf"(?m)^    name: {job}$")

    def test_independent_offline_guards_use_pinned_python_and_stream_logs(self):
        guards = self.jobs["offline-guards"]
        self.assertRegex(guards, r"(?m)^    runs-on: macos-15$")
        self.assertIn(f"actions/setup-python@{SETUP_PYTHON_SHA}", guards)
        self.assertIn("python-version: '3.11'", guards)
        self.assertIn("cache-dependency-path: Scripts/requirements-ci.txt", guards)
        self.assertIn("python3 -m venv .venv-ci", guards)
        self.assertIn("source .venv-ci/bin/activate", guards)
        self.assertIn("python3 -m pip install", guards)
        self.assertIn("-r Scripts/requirements-ci.txt", guards)
        self.assertIn("set -o pipefail", guards)
        self.assertIn("python3 -u Scripts/run-repo-guards.py 2>&1 | tee guard-run.log", guards)
        self.assertNotIn("continue-on-error", guards)
        self.assertNotIn("run-repo-guards.py", self.jobs["test"])
        self.assertIn("run-helper-suites.py", guards)

    def test_swift_cache_excludes_build_products(self):
        for job in ("compile", "test"):
            with self.subTest(job=job):
                block = self.jobs[job]
                cache = re.search(r"(?ms)      - name: Cache SwiftPM downloads\n.*?(?=      - name:|\Z)", block)
                self.assertIsNotNone(cache)
                cache_block = cache.group(0)
                self.assertIn("~/Library/Caches/org.swift.swiftpm", cache_block)
                self.assertNotIn(".build", cache_block)
                self.assertIn("runner.arch", cache_block)
                self.assertIn("Package.resolved", cache_block)

    def test_the_aggregate_requires_every_gate_and_checks_success(self):
        build = self.jobs["build"]
        needs = re.search(r"^    needs:\s*\[([^\]]*)\]", build, re.M)
        self.assertIsNotNone(needs)
        listed = [item.strip() for item in needs.group(1).split(",") if item.strip()]
        self.assertEqual(set(listed), set(AGGREGATE_JOBS))
        self.assertNotIn("classify", listed)
        for job in listed:
            with self.subTest(job=job):
                self.assertRegex(build, rf'\[ "\${job.upper().replace("-", "_")}" = "success" \]')

    def test_the_aggregate_still_refuses_to_decide_a_cancelled_run(self):
        self.assertRegex(self.jobs["build"], r"(?m)^    if:.*!cancelled\(\)")

    def test_the_body_check_is_no_longer_in_the_code_workflow(self):
        self.assertNotIn("--text", self.executable)
        self.assertNotIn("canon-citations-in-the-pull-request", self.executable)

    def test_the_code_workflow_does_not_subscribe_to_edited(self):
        trigger = re.search(r"^\s*types:\s*\[([^\]]*)\]", self.executable, re.M)
        self.assertIsNotNone(trigger)
        listed = {item.strip() for item in trigger.group(1).split(",") if item.strip()}
        self.assertEqual(listed, {"opened", "synchronize", "reopened"})

    def test_the_concurrency_group_no_longer_carries_a_metadata_domain(self):
        group = re.search(r"^concurrency:\n(?:.*\n)*?\s*group:(.*(?:\n\s{4,}.*)*)",
                          self.executable, re.M)
        self.assertIsNotNone(group, "ci.yml has no concurrency group")
        group_text = " ".join(group.group(1).split())
        self.assertNotIn("metadata", group_text)
        self.assertNotIn("github.event.changes", group_text)
        self.assertIn("github.workflow", group_text)
        self.assertIn("github.ref", group_text)


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
