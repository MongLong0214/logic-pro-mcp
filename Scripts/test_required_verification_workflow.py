#!/usr/bin/env python3
"""The restored canon, locale and native gates are unconditional inputs to required `build`."""
import os
import re
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(path):
    with open(os.path.join(REPO, path), encoding="utf-8") as handle:
        return handle.read()


def job_body(workflow, name):
    match = re.search(rf"^  {re.escape(name)}:\n", workflow, re.M)
    if not match:
        return None
    tail = workflow[match.end():]
    next_job = re.search(r"^  [A-Za-z0-9_-]+:\n", tail, re.M)
    return tail[:next_job.start()] if next_job else tail


def workflow_problems(workflow):
    problems = []
    canon = job_body(workflow, "canon-locales") or ""
    native = job_body(workflow, "native-logic-e2e") or ""
    build = job_body(workflow, "build") or ""
    release = job_body(workflow, "release-build") or ""
    build_needs = re.search(r"^    needs:\s*(.*)$", build, re.M)
    build_dependencies = build_needs.group(1) if build_needs else ""
    if not canon:
        problems.append("missing canon-locales job")
    if re.search(r"^    if:.*(docs|full-validation|change-scope)", canon, re.M):
        problems.append("canon-locales is path-conditional")
    for command in (
        "Scripts/check-canon-drift.py",
        "Scripts/check-canon-citations.py",
        "Scripts/check-policy-literals-against-canon.py",
        "Scripts/check-labelsets-are-derived.py",
        "Scripts/locale_labels.py --check",
        "Scripts/test_canon_citations_guard.py",
        "Scripts/test_labelsets_are_derived.py",
        "Scripts/test_locale_detection_is_derived.py",
    ):
        if command not in canon:
            problems.append(f"canon-locales does not run {command}")
    if not native:
        problems.append("missing native-logic-e2e job")
    if "logic-native-e2e" not in native or "Native PASS a=" not in native:
        problems.append("native job does not consume the exact live status")
    for binding in ("EXPECTED_ATTEMPT", "release-runtime-{run_id}",
                    'artifact.get("digest")', 'artifact.get("id")'):
        if binding not in native:
            problems.append(f"native job does not bind {binding}")
    if re.search(r"^    if:.*(docs|full-validation|change-scope)", native, re.M):
        problems.append("native gate is path-conditional")
    if re.search(r"^    if:.*full-validation", release, re.M):
        problems.append("release artifact is skipped for documentation changes")
    for dependency in ("canon-locales", "native-logic-e2e"):
        if dependency not in build_dependencies:
            problems.append(f"required build does not depend on {dependency}")
    for result in ("CANON_LOCALES", "NATIVE_LOGIC"):
        if f'test "${result}" = success' not in build:
            problems.append(f"required build does not fail on {result}")
    return problems


class RequiredVerificationWorkflow(unittest.TestCase):
    def test_real_workflow_is_fail_closed(self):
        self.assertEqual(workflow_problems(read(".github/workflows/ci.yml")), [])

    def test_docs_only_condition_is_detected(self):
        workflow = read(".github/workflows/ci.yml").replace(
            "  canon-locales:\n", "  canon-locales:\n    if: needs.change-scope.outputs.full-validation == 'true'\n", 1)
        self.assertIn("canon-locales is path-conditional", workflow_problems(workflow))

    def test_detaching_native_from_required_build_is_detected(self):
        workflow = read(".github/workflows/ci.yml").replace(
            "needs: [change-scope, canon-locales, native-logic-e2e, product-validation]",
            "needs: [change-scope, canon-locales, product-validation]", 1)
        self.assertIn("required build does not depend on native-logic-e2e",
                      workflow_problems(workflow))

    def test_native_status_can_only_follow_the_real_gate(self):
        wrapper = read("Scripts/ci-native-qualify.sh")
        qualifier = wrapper.index('bash "$TRUSTED_ROOT/Scripts/release-qualify.sh"')
        success = wrapper.index('post_status success "$receipt"')
        self.assertLess(qualifier, success)
        self.assertIn('test "$(cat "$work/runtime/candidate-sha.txt")" = "$SHA"', wrapper)
        self.assertIn('post_status failure "Exact artifact failed native Logic qualification"', wrapper)
        self.assertNotIn("LOGIC_PRO_MCP_RUN_LIVE_QA=0", wrapper)

    def test_native_candidate_binds_the_run_base_and_head(self):
        wrapper = read("Scripts/ci-native-qualify.sh")
        self.assertIn('run.get("head_sha") != head_sha', wrapper)
        self.assertIn('parents != [base_sha, head_sha]', wrapper)
        self.assertNotIn('run.get("head_sha") != expected_sha', wrapper)

    def test_native_host_refuses_forks_and_separates_trust_from_candidate(self):
        wrapper = read("Scripts/ci-native-qualify.sh")
        self.assertIn('fork pull requests cannot execute on the trusted Logic host', wrapper)
        self.assertIn('require_release_origin "$TRUSTED_ROOT"', wrapper)
        self.assertIn('require_release_origin "$CANDIDATE_ROOT"', wrapper)
        self.assertIn('["git", "-C", sys.argv[6], "show"', wrapper)
        self.assertIn('rev-parse origin/main', wrapper)
        self.assertIn('"$TRUSTED_ROOT/Scripts/release-qualify.sh"', wrapper)
        self.assertIn('unset LOGIC_NATIVE_STATUS_TOKEN GH_TOKEN GITHUB_TOKEN', wrapper)
        self.assertIn('env -u GH_TOKEN -u GITHUB_TOKEN -u LOGIC_NATIVE_STATUS_TOKEN', wrapper)

    def test_required_job_accepts_only_the_trusted_status_publisher(self):
        workflow = read(".github/workflows/ci.yml")
        native = job_body(workflow, "native-logic-e2e") or ""
        self.assertIn("actions: read", native)
        self.assertIn('creator.get("login") != "MongLong0214"', native)
        self.assertIn('creator.get("id") != 97578200', native)

    def test_native_receipt_binds_run_attempt_and_current_artifact_bytes(self):
        wrapper = read("Scripts/ci-native-qualify.sh")
        workflow = read(".github/workflows/ci.yml")
        native = job_body(workflow, "native-logic-e2e") or ""
        for required in ("run_attempt", "artifact_id", "artifact_digest", "runtime.zip"):
            self.assertIn(required, wrapper)
        for required in ("EXPECTED_ATTEMPT", 'artifact.get("id")',
                         'artifact.get("digest")', "Native PASS a="):
            self.assertIn(required, native)

    def test_replaced_artifact_binding_cannot_be_removed_silently(self):
        workflow = read(".github/workflows/ci.yml").replace(
            'artifact.get("digest")', 'None', 1)
        self.assertIn('native job does not bind artifact.get("digest")',
                      workflow_problems(workflow))

    def test_release_gate_uses_real_logic_and_exact_bytes(self):
        gate = read("Scripts/release-qualify.sh")
        for required in (
            'pgrep -xq "Logic Pro"',
            ".build/release/LogicProMCP --check-permissions",
            "realReleaseBinaryExecutesEveryOperationWithIndependentReadback",
            "runnerRejectsPartialStateObservedFromRealServer",
            "verify_candidate_bytes",
            "Scripts/logic_canon.py status",
        ):
            self.assertIn(required, gate)
        self.assertNotIn("skip", gate.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
