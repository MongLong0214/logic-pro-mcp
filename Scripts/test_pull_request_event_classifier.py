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

_TOKEN = re.compile(r"\s*(\(|\)|&&|\|\||==|!=|'(?:[^']|'')*'|[A-Za-z_][\w.\-]*)")


def _resolve(path, context):
    """`github.event.changes.base` against a context dict. A missing step is null, as on Actions."""
    value = context
    for step in path.split("."):
        if not isinstance(value, dict) or step not in value:
            return None
        value = value[step]
    return value


def evaluate_expression(text, context):
    """Evaluate the `${{ ... }}` segments of a workflow string the way Actions does.

    Deliberately small and deliberately not `eval`. It covers exactly the grammar `ci.yml`'s
    concurrency group uses -- `&&`, `||`, `==`, `!=`, parentheses, single-quoted strings, `null`,
    `true`/`false` and context paths -- and raises on anything else rather than guessing, because a
    silent mis-parse would make the case it serves pass for the wrong reason. `&&` and `||` return
    an OPERAND, not a boolean, which is what makes `cond && 'a' || 'b'` work at all; falsy is
    `null`, `false`, `''` and `0`.
    """
    def segment(expression):
        expression = expression.strip()
        tokens, position = [], 0
        while position < len(expression):
            match = _TOKEN.match(expression, position)
            if not match:
                raise ValueError(f"cannot tokenise at {expression[position:position + 20]!r}")
            tokens.append(match.group(1))
            position = match.end()
        tokens.append(None)
        index = [0]

        def peek():
            return tokens[index[0]]

        def take():
            token = tokens[index[0]]
            index[0] += 1
            return token

        def truthy(value):
            return value not in (None, False, "", 0)

        def primary():
            token = take()
            if token == "(":
                value = disjunction()
                if take() != ")":
                    raise ValueError("unbalanced parenthesis")
                return value
            if token is None:
                raise ValueError("expression ended early")
            if token.startswith("'"):
                return token[1:-1].replace("''", "'")
            if token == "null":
                return None
            if token in ("true", "false"):
                return token == "true"
            return _resolve(token, context)

        def comparison():
            left = primary()
            while peek() in ("==", "!="):
                operator = take()
                right = primary()
                left = (left == right) if operator == "==" else (left != right)
            return left

        def conjunction():
            left = comparison()
            while peek() == "&&":
                take()
                right = comparison()
                left = right if truthy(left) else left
            return left

        def disjunction():
            left = conjunction()
            while peek() == "||":
                take()
                right = conjunction()
                left = left if truthy(left) else right
            return left

        value = disjunction()
        if peek() is not None:
            raise ValueError(f"trailing tokens: {tokens[index[0]:]}")
        return "" if value is None else str(value)

    return re.sub(r"\$\{\{(.*?)\}\}", lambda m: segment(m.group(1)), text, flags=re.S)

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


def run_classifier(event_name, payload):
    """Drive the ENTRY POINT, not `classify()`, at a payload written to a real file.

    A case that only calls `classify()` leaves `main()` free to print anything; the workflow reads
    stdout, so stdout is what has to be measured.
    """
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        if payload is not None:
            json.dump(payload, handle)
        path = handle.name
    try:
        environment = dict(os.environ, GITHUB_EVENT_NAME=event_name, GITHUB_EVENT_PATH=path)
        finished = subprocess.run(
            [sys.executable, os.path.join(REPO, "Scripts", "classify-pull-request-event.py")],
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

    def _domain(self, context):
        """Which cancellation domain `ci.yml` puts this event in -- by evaluating its expression.

        The previous version of this case asserted that certain substrings appeared in the group.
        A substring is not a decision: the expression could compare `changes.base` against the
        wrong thing, or return the two domains the wrong way round, and every one of those
        assertions would still have held. `evaluate_expression` reads the same string GitHub reads.
        """
        rendered = evaluate_expression(self._concurrency_group(), context)
        self.assertTrue(rendered.endswith(("-metadata", "-code")),
                        f"the group did not resolve to a domain: {rendered!r}")
        return rendered.rsplit("-", 1)[1]

    @staticmethod
    def _context(payload, event_name="pull_request", ref="refs/pull/1/merge"):
        return {"github": {"workflow": "CI", "ref": ref,
                           "event_name": event_name, "event": payload}}

    def test_the_group_expression_and_the_classifier_agree_on_every_payload_github_sends(self):
        # E02 and E10. The workflow-level group cannot call the classifier -- it is evaluated
        # before any job runs -- so it states the same rule a second time, which is the shape that
        # drifts. `changes` on `edited` is documented to carry only `title`, `body` and `base`, so
        # these are the whole space, and the two authorities must not disagree anywhere in it.
        cases = [
            {"action": "edited", "changes": {"title": {"from": "a"}}},
            {"action": "edited", "changes": {"body": {"from": "a"}}},
            {"action": "edited", "changes": {"title": {"from": "a"}, "body": {"from": "b"}}},
            {"action": "edited", "changes": {"base": {"ref": {"from": "main"}}}},
            {"action": "edited",
             "changes": {"title": {"from": "a"}, "base": {"ref": {"from": "main"}}}},
            {"action": "edited", "changes": {}},
            {"action": "edited"},
            {"action": "synchronize"},
            {"action": "opened"},
        ]
        for payload in cases:
            label = ",".join(sorted(payload.get("changes") or {})) or payload["action"]
            with self.subTest(changes=label):
                decision = classifier.classify("pull_request", payload)
                expected = "metadata" if decision == classifier.METADATA_ONLY else "code"
                self.assertEqual(self._domain(self._context(payload)), expected,
                                 f"the classifier says {decision!r}")

    def test_a_push_is_a_code_run(self):
        # Not a `pull_request` at all. The group must not read `changes` off an event that has none
        # and land a push in the metadata domain, where a later description edit could cancel it.
        self.assertEqual(
            self._domain(self._context({}, event_name="push", ref="refs/heads/main")), "code")

    def test_an_event_that_is_not_a_pull_request_is_code_even_when_it_carries_changes(self):
        # This payload cannot reach `ci.yml` today -- it triggers on `push` and `pull_request` and
        # nothing else -- and that is exactly why the case exists. Without it, deleting
        # `github.event_name == 'pull_request'` from the group changes no outcome any other case
        # measures (measured: that mutation left the suite green), so the clause would be a guard
        # nothing can catch being removed. The clause is what keeps the rule correct for whatever
        # trigger is added next, and this is the payload that says so.
        carries_changes = {"action": "edited", "changes": {"title": {"from": "a"}}}
        self.assertEqual(
            self._domain(self._context(carries_changes, event_name="issues")), "code")

    def test_the_group_expression_names_every_key_the_classifier_knows(self):
        # The expression cannot ask "does `changes` contain ONLY these keys?" -- GitHub expressions
        # cannot enumerate an object's keys -- so it names them one at a time. That makes growing
        # `METADATA_KEYS` a change in two places, and this is what fails when somebody grows it in
        # one. The residue is stated in `ci.yml`: an `edited` carrying a key GitHub does not
        # document today is `code` to the classifier and `metadata` to the expression. That one
        # cannot be closed from inside an expression, only watched.
        expression = self._concurrency_group()
        for key in sorted(classifier.METADATA_KEYS) + ["base"]:
            with self.subTest(key=key):
                self.assertIn(f"github.event.changes.{key}", expression)

    def test_the_body_check_is_no_longer_in_the_code_workflow(self):
        # It moved to the separately required `pr-policy` context. Leaving a copy here is what made
        # a description edit restart a macOS test job.
        self.assertNotIn("--text", self.executable)
        self.assertNotIn("canon-citations-in-the-pull-request", self.executable)

    def test_edited_is_still_subscribed_because_a_retarget_arrives_that_way(self):
        # Deleting `edited` is the obvious "simplification" and it loses E06 outright: a pull
        # request retargeted onto main would keep the verdicts it earned against its old base.
        trigger = re.search(r"^\s*types:\s*\[([^\]]*)\]", self.executable, re.M)
        self.assertIsNotNone(trigger)
        listed = {item.strip() for item in trigger.group(1).split(",") if item.strip()}
        self.assertEqual(listed, {"opened", "synchronize", "reopened", "edited"})


if __name__ == "__main__":
    unittest.main()
