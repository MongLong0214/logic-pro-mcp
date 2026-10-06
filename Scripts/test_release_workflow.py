#!/usr/bin/env python3
"""Regression checks for release rerun provenance and safe signing modes."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/release.yml"
APPLE_CREDENTIALS = (
    "MACOS_CERT_BASE64",
    "MACOS_CERT_PASSWORD",
    "MACOS_SIGNING_IDENTITY",
    "MACOS_KEYCHAIN_PASSWORD",
    "APPLE_NOTARY_APPLE_ID",
    "APPLE_NOTARY_TEAM_ID",
    "APPLE_NOTARY_APP_PASSWORD",
)


class ReleaseWorkflowReliabilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.safe_load(WORKFLOW.read_text())
        cls.build_steps = cls.workflow["jobs"]["build-release"]["steps"]

    @classmethod
    def step(cls, name):
        return next(step for step in cls.build_steps if step.get("name") == name)

    def run_mode(self, credentials=()):
        mode = self.step("Detect release mode")
        environment = os.environ.copy()
        for name in APPLE_CREDENTIALS:
            environment.pop(name, None)
        environment.update(credentials)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "github-output"
            output.write_text("")
            environment["GITHUB_OUTPUT"] = str(output)
            result = subprocess.run(
                ["bash", "-o", "pipefail", "-c", mode["run"]],
                capture_output=True,
                text=True,
                env=environment,
                check=False,
            )
            return result, output.read_text()

    def test_artifact_producer_output_is_used_by_each_consumer(self):
        build = self.workflow["jobs"]["build-release"]
        self.assertEqual(
            build["outputs"]["verified_artifact_name"],
            "${{ steps.artifact-name.outputs.name }}",
        )
        self.assertEqual(
            self.step("Name verified release artifacts")["run"].strip(),
            'echo "name=verified-release-artifacts-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" >> "$GITHUB_OUTPUT"',
        )
        self.assertEqual(
            self.step("Upload verified release artifacts")["with"]["name"],
            "${{ steps.artifact-name.outputs.name }}",
        )
        for job_name, step_name in (
            ("publish", "Download verified release artifacts"),
            ("validate-install", "Download verified release artifacts"),
            ("verify-published", "Download the artifact this run verified"),
        ):
            steps = self.workflow["jobs"][job_name]["steps"]
            step = next(step for step in steps if step.get("name") == step_name)
            self.assertEqual(
                step["with"]["name"],
                "${{ needs.build-release.outputs.verified_artifact_name }}",
            )

    def test_install_diagnostic_artifact_always_runs_without_masking_install_failure(self):
        steps = self.workflow["jobs"]["validate-install"]["steps"]
        diagnostic = next(
            step for step in steps if step.get("name") == "Upload install validation evidence"
        )
        self.assertEqual(diagnostic["if"], "${{ always() }}")
        self.assertEqual(diagnostic["with"]["if-no-files-found"], "ignore")
        self.assertEqual(
            diagnostic["with"]["name"],
            "install-validation-${{ github.run_id }}-${{ github.run_attempt }}-${{ matrix.os }}",
        )

    def test_no_credentials_selects_adhoc_mode(self):
        result, output = self.run_mode()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "mode=adhoc\n")

    def test_any_apple_credential_rejects_unvalidated_notarization_before_build(self):
        mode = self.step("Detect release mode")
        self.assertEqual(set(mode["env"]), set(APPLE_CREDENTIALS))
        for credential in APPLE_CREDENTIALS:
            with self.subTest(credential=credential):
                result, output = self.run_mode({credential: "configured"})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, "")
                self.assertIn("Notarized releases are disabled until privately validated", result.stdout)

        mode_index = self.build_steps.index(self.step("Detect release mode"))
        for name in (
            "Build universal binary",
            "Codesign binary (ADHOC)",
            "Package",
            "Upload verified release artifacts",
        ):
            self.assertGreater(self.build_steps.index(self.step(name)), mode_index)
        mode_script = self.step("Detect release mode")["run"]
        self.assertNotIn("codesign --force", mode_script)
        self.assertNotIn("notarytool", mode_script)
        self.assertNotIn("gh release", mode_script)

    def test_notarization_and_native_signing_steps_are_absent(self):
        step_names = {step.get("name") for step in self.build_steps}
        self.assertNotIn("Codesign binary (Developer ID)", step_names)
        self.assertNotIn("Notarize binary", step_names)
        self.assertNotIn("Verify notarized artifact", step_names)

    def test_same_tag_release_runs_queue_without_cancelling_an_active_publish(self):
        concurrency = self.workflow["concurrency"]
        self.assertEqual(concurrency["group"], "release-${{ github.ref }}")
        self.assertEqual(concurrency["queue"], "max")
        self.assertFalse(concurrency["cancel-in-progress"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
