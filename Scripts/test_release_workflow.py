#!/usr/bin/env python3
"""Regression checks for release rerun provenance and safe signing modes."""

import os
import hashlib
import io
import json
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile
import tarfile
import unittest
import zipfile

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


def run_bounded(arguments, *, cwd=None, env=None, timeout=30):
    """Reap the entire owned command group even if an input read wedges."""
    process = subprocess.Popen(arguments, cwd=cwd, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, start_new_session=True)
    timed_out = False
    try:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                stdout, stderr = process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                stdout, stderr = process.communicate()
        result = subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
        result.timed_out = timed_out
        return result
    finally:
        # The group is exclusively this test's child and its descendants.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


class FinalConsumerInputTypeTests(unittest.TestCase):
    def test_candidate_fifo_is_rejected_before_copy_or_verifier(self):
        with tempfile.TemporaryDirectory(prefix="final-input-type-") as directory:
            root = Path(directory)
            candidate = root / "candidate"
            os.mkfifo(candidate)
            result, invoked = self.invoke(root, candidate)
            self.assertFalse(result.timed_out, "Consumer blocked opening the FIFO before verification")
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(invoked)

    def test_regular_mode644_candidate_reaches_verifier_without_execution(self):
        with tempfile.TemporaryDirectory(prefix="final-input-type-") as directory:
            root = Path(directory)
            candidate = root / "candidate"
            candidate.write_bytes(b"opaque candidate, never executed")
            candidate.chmod(0o644)
            result, invoked = self.invoke(root, candidate)
            self.assertFalse(result.timed_out)
            self.assertNotEqual(result.returncode, 0)  # The spy always rejects; no trust credit.
            self.assertTrue(invoked)

    def invoke(self, root, candidate):
        bundle = root / "bundle"
        bundle.mkdir()
        invoked = root / "verifier-invoked"
        verifier = root / "verifier"
        verifier.write_text('#!/bin/bash\ntouch "$VERIFIER_INVOKED"\nexit 78\n')
        verifier.chmod(0o755)
        result = run_bounded(
            ["bash", str(WORKFLOW.parents[2] / "Scripts/release-consume-final.sh"),
             "verify", "1.2.3", "a" * 40, str(candidate), str(bundle), str(verifier),
             str(root / "public")], timeout=2, env={
                "PATH": "/usr/bin:/bin", "VERIFIER_INVOKED": str(invoked),
                "LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY": "test-only-nonempty-anchor",
            })
        return result, invoked.exists()


class QualifiedInputPrivacyTests(unittest.TestCase):
    def test_qualified_zip_is_checked_before_any_member_is_written(self):
        for shape in ("valid", "traversal", "symlink", "fifo", "duplicate"):
            with self.subTest(shape=shape), tempfile.TemporaryDirectory(prefix="qualified-zip-") as directory:
                root = Path(directory)
                destination = root / "private"
                destination.mkdir()
                source = root / "bundle.zip"
                with zipfile.ZipFile(source, "w") as archive:
                    archive.writestr("safe-first.json", "first")
                    member = zipfile.ZipInfo("second.json")
                    if shape == "traversal":
                        member.filename = "../../escaped.json"
                    elif shape == "symlink":
                        member.external_attr = (stat.S_IFLNK | 0o777) << 16
                    elif shape == "fifo":
                        member.external_attr = (stat.S_IFIFO | 0o600) << 16
                    elif shape == "duplicate":
                        member.filename = "safe-first.json"
                    archive.writestr(member, "second")
                executable = root / "curl"
                executable.write_text('''#!/bin/bash
while [ "$#" -gt 0 ]; do
  case "$1" in --output) output="$2"; shift 2;; *) shift;; esac
done
cp "$FETCH_SOURCE" "$output"
''')
                executable.chmod(0o755)
                result = subprocess.run(
                    ["bash", str(WORKFLOW.parents[2] / "Scripts/release-fetch-qualified-inputs.sh"),
                     "verify", str(destination)], env={
                        "PATH": str(root) + ":/usr/bin:/bin", "FETCH_SOURCE": str(source),
                        "QUALIFICATION_EVIDENCE_URL": "https://owner.invalid/private-bundle",
                        "QUALIFICATION_EVIDENCE_SHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
                    }, capture_output=True, text=True, timeout=10, check=False)
                if shape == "valid":
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((destination / "bundle/safe-first.json").read_text(), "first")
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(list((destination / "bundle").rglob("*")), [])
                    self.assertFalse((root / "escaped.json").exists())

    def test_private_fetch_failure_details_are_not_public(self):
        for fault in ("curl", "crc"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory(prefix="qualified-input-") as directory:
                root = Path(directory)
                destination = root / "private"
                destination.mkdir()
                source = root / "bundle.zip"
                sentinel = "private-owner-sentinel.invalid"
                with zipfile.ZipFile(source, "w", compression=zipfile.ZIP_STORED) as archive:
                    archive.writestr(sentinel + "/raw-transcript.json", b"private-payload")
                if fault == "crc":
                    # Authenticate corrupt transport bytes, then reach ZIP's actual
                    # member CRC failure, whose traceback names private data.
                    source.write_bytes(source.read_bytes().replace(b"private-payload", b"damaged-payload"))
                executable = root / "curl"
                executable.write_text('''#!/bin/bash
if [ "$FETCH_FAULT" = curl ]; then
  echo "curl: rejected https://private-owner-sentinel.invalid/private-evidence" >&2
  exit 22
fi
while [ "$#" -gt 0 ]; do
  case "$1" in --output) output="$2"; shift 2;; *) shift;; esac
done
cp "$FETCH_SOURCE" "$output"
''')
                executable.chmod(0o755)
                environment = {
                    "PATH": str(root) + ":/usr/bin:/bin", "FETCH_FAULT": fault,
                    "FETCH_SOURCE": str(source),
                    "QUALIFICATION_EVIDENCE_URL": "https://" + sentinel + "/private-evidence",
                    "QUALIFICATION_EVIDENCE_SHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
                }
                result = subprocess.run(
                    ["bash", str(WORKFLOW.parents[2] / "Scripts/release-fetch-qualified-inputs.sh"),
                     "verify", str(destination)], env=environment, capture_output=True,
                    text=True, timeout=10, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(sentinel, result.stdout + result.stderr)


class ReleaseFinalArtifactConsumerTests(unittest.TestCase):
    """Drive the real release entrypoint without Git/network/build/signing effects.

    These stubs establish refusal/propagation only, not a valid qualification.
    Valid trust is exercised separately with the actual trusted-verifier.
    """

    def run_consumer(self, bundle_kind, *, candidate=None, bundle_path=None,
                     verifier=None, trusted_key=None, commit=None,
                     mutate_original_bundle=False, entrypoint="local",
                     archive_mutation=None, public_input_shape=None, reverify_timeout=30):
        with tempfile.TemporaryDirectory(prefix="release-final-consumer-") as directory:
            root = Path(directory)
            repo = root / "repo"
            scripts = repo / "Scripts"
            scripts.mkdir(parents=True)
            source = WORKFLOW.parents[2]
            for name in ("release.sh", "release-stable.sh", "release-qualify.sh", "release-package.sh",
                         "release-consume-final.sh", "release-verify-formula-install-paths.sh",
                         "release-fetch-qualified-inputs.sh",
                         "install-keycmds.sh", "uninstall-keycmds.sh", "keycmd-preset.plist",
                         "LogicProMCP-Scripter.js", "logic_bounce.py", "logic_bounce_ui.py",
                         "logic_ui_jxa.py", "logic_input_source.py", "logic_variants.py",
                         "logic_ui_labels.py"):
                shutil.copy2(source / "Scripts" / name, scripts / name)
            (repo / "docs").mkdir()
            shutil.copy2(source / "docs/SETUP.md", repo / "docs/SETUP.md")
            shutil.copytree(source / "Formula", repo / "Formula")
            (repo / "Package.resolved").write_text("unchanged test pin\n")
            (root / "bin").mkdir()
            calls = root / "calls"
            sha = commit or "a" * 40
            stubs = {
                "git": f'''case "$*" in
  "-C "*" show "*) path="${{!#}}"; cat "${{2}}/${{path#*:}}" ;;
  "branch --show-current") echo main ;;
  "rev-parse HEAD"|"rev-parse origin/main") echo {sha} ;;
  "rev-parse refs/tags/"*) exit 1 ;;
  "for-each-ref"*) printf 'Final-candidate-SHA256: %s\\nQualification-manifest-SHA256: %s\\n' "$OWNER_BINARY_SHA" "$OWNER_MANIFEST_SHA" ;;
esac
''',
                "gh": '''case "$*" in
  "release create"*)
    for artifact in "$@"; do
      if [ "${artifact##*/}" = LogicProMCP ] && [ -f "$artifact" ]; then
        printf 'published-binary ' >> "$CONSUMER_CALLS"
        shasum -a 256 "$artifact" | awk '{print $1}' >> "$CONSUMER_CALLS"
      fi
    done ;;
  "issue view"*) echo CLOSED ;;
  "release view"*) exit 1 ;;
esac
''',
                "swift": '''if [ "$1" = build ]; then
  mkdir -p .build/release
  printf '#!/bin/bash\\nexit 0\\n' > .build/release/LogicProMCP
  chmod 0755 .build/release/LogicProMCP
fi
''',
                "codesign": ":\n",
                "swiftc": ":\n",
                "pgrep": ":\n",
                "lipo": 'echo "Non-fat file: test is architecture: arm64"\n',
                "tar": 'exec /usr/bin/tar "$@"\n',
            }
            for name, body in stubs.items():
                path = root / "bin" / name
                path.write_text('#!/bin/bash\nprintf "%s\\n" "' + name
                                + ' $*" >> "$CONSUMER_CALLS"\n' + body + "exit 0\n")
                path.chmod(0o755)
            bundle = root / "owner-bundle"
            if bundle_kind == "invalid":
                bundle.mkdir()
                (bundle / "release-qualification-attestation.json").write_text("not JSON\n")
            if bundle_path is not None:
                bundle = Path(bundle_path)
            if verifier is not None:
                tool = repo / "trusted-verifier-src/.build/release/trusted-verifier"
                tool.parent.mkdir(parents=True)
                # The actual verifier stays outside the candidate bundle; this wrapper only
                # records invocation, then forwards to that real debug product.
                import shlex
                mutation = ('if [ ! -f "$CONSUMER_MUTATED" ]; then\n'
                            '  printf "\\n" >> "$CONSUMER_ORIGINAL_BUNDLE/evidence-manifest.json"\n'
                            '  touch "$CONSUMER_MUTATED"\n'
                            '  echo original-bundle-changed >> "$CONSUMER_CALLS"\nfi\n'
                            if mutate_original_bundle else '')
                tool.write_text('#!/bin/bash\necho trusted-verifier >> "$CONSUMER_CALLS"\n'
                                + 'printf "verifier-build " >> "$CONSUMER_CALLS"\n'
                                + 'shasum -a 256 ' + shlex.quote(str(verifier))
                                + ' | awk \'{print $1}\' >> "$CONSUMER_CALLS"\n'
                                + 'printf "trusted-candidate %s " "$3" >> "$CONSUMER_CALLS"\n'
                                + 'shasum -a 256 "$3" | awk \'{print $1}\' >> "$CONSUMER_CALLS"\n'
                                + mutation + 'exec '
                                + shlex.quote(str(verifier)) + ' "$@"\n')
                tool.chmod(0o755)
            environment = {
                "PATH": str(root / "bin") + ":/usr/bin:/bin",
                "CONSUMER_CALLS": str(calls),
                "LOGIC_PRO_MCP_QUALIFICATION_BUNDLE": str(bundle),
                "DRY_RUN": "0",
                "CONSUMER_ORIGINAL_BUNDLE": str(bundle),
                "CONSUMER_MUTATED": str(root / "original-mutated"),
            }
            if trusted_key is not None:
                environment["LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY"] = trusted_key
            arguments = ["bash", str(scripts / "release.sh"), "v1.2.3"]
            if candidate is not None:
                arguments.extend((str(candidate), str(bundle), str(tool)))
            def run(arguments, timeout=30):
                return run_bounded(arguments, cwd=repo, env=environment, timeout=timeout)

            if entrypoint == "stable":
                arguments[1] = str(scripts / "release-stable.sh")
                # Pre-existing Python/typecheck gates remain inert in this legacy-path test.
                (root / "bin/python3").write_text("#!/bin/bash\nexit 0\n")
                (root / "bin/python3").chmod(0o755)
                result = run(arguments)
            elif entrypoint in ("hosted", "direct", "install"):
                shutil.copy2(candidate, repo / "LogicProMCP")
                bundle_zip = root / "private-owner-bundle.zip"
                with zipfile.ZipFile(bundle_zip, "w") as archive:
                    for path in bundle.rglob("*"):
                        if path.is_file():
                            archive.write(path, path.relative_to(bundle))
                curl = root / "bin/curl"
                curl.write_text('''#!/bin/bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output) output="$2"; shift 2 ;;
    owner-candidate) input="$TEST_OWNER_CANDIDATE"; shift ;;
    owner-bundle) input="$TEST_OWNER_BUNDLE"; shift ;;
    *) shift ;;
  esac
done
test -n "${input:-}" && test -n "${output:-}" || exit 1
cp "$input" "$output"
''')
                curl.chmod(0o755)
                environment.update({
                    "GITHUB_REF_NAME": "v1.2.3", "GITHUB_SHA": sha,
                    "RUNNER_TEMP": str(root), "RELEASE_MODE": "adhoc",
                    "QUALIFICATION_CANDIDATE_URL": "owner-candidate",
                    "QUALIFICATION_CANDIDATE_SHA256": hashlib.sha256(Path(candidate).read_bytes()).hexdigest(),
                    "QUALIFICATION_EVIDENCE_URL": "owner-bundle",
                    "QUALIFICATION_EVIDENCE_SHA256": hashlib.sha256(bundle_zip.read_bytes()).hexdigest(),
                    "TRUSTED_QUALIFICATION_PUBLIC_KEY": trusted_key,
                    "TEST_OWNER_CANDIDATE": str(candidate), "TEST_OWNER_BUNDLE": str(bundle_zip),
                    "OWNER_BINARY_SHA": hashlib.sha256(Path(candidate).read_bytes()).hexdigest(),
                    "OWNER_MANIFEST_SHA": hashlib.sha256((bundle / "evidence-manifest.json").read_bytes()).hexdigest(),
                })
                workflow = yaml.safe_load(WORKFLOW.read_text())
                stage_step = next(step for step in workflow["jobs"]["build-release"]["steps"]
                                  if step.get("name") == "Package")
                result = run(["bash", "-e", "-o", "pipefail", "-c", stage_step["run"]])
                if result.returncode == 0:
                    files = ("LogicProMCP", "LogicProMCP-macOS-universal.tar.gz",
                             "LogicProMCP-macOS-arm64.tar.gz", "RELEASE-METADATA.json", "SHA256SUMS.txt")
                    # Model a coherent artifact replacement, not just a bad adjacent checksum.
                    if archive_mutation in ("bytes", "duplicate", "nonexec", "script"):
                        archive_path = repo / "LogicProMCP-macOS-universal.tar.gz"
                        with tarfile.open(archive_path, "r:gz") as archive:
                            members = [(info, archive.extractfile(info).read() if info.isfile() else None)
                                       for info in archive.getmembers()]
                        with tarfile.open(archive_path, "w:gz") as archive:
                            for info, data in members:
                                if archive_mutation == "script" and info.name == "Scripts/logic_bounce.py":
                                    data = b"# substituted shipped helper\n"
                                    info.size = len(data)
                                if info.name == "LogicProMCP":
                                    if archive_mutation == "bytes":
                                        data = b"substituted-only-inside-archive"
                                        info.size = len(data)
                                    elif archive_mutation == "nonexec":
                                        info.mode = 0o644
                                    elif archive_mutation == "duplicate":
                                        archive.addfile(info, io.BytesIO(data))
                                archive.addfile(info, io.BytesIO(data) if data is not None else None)
                        with calls.open("a") as log:
                            log.write("archive-member-replaced\n")
                        sums = "".join(hashlib.sha256((repo / name).read_bytes()).hexdigest()
                                       + "  " + name + "\n" for name in files[:3])
                        (repo / "SHA256SUMS.txt").write_text(sums)
                    if archive_mutation == "mode644":
                        binary = repo / "LogicProMCP"
                        before = hashlib.sha256(binary.read_bytes()).hexdigest()
                        binary.chmod(0o644)
                        with calls.open("a") as log:
                            log.write("downloaded-mode644 " + before + " "
                                      + hashlib.sha256(binary.read_bytes()).hexdigest() + "\n")
                    (repo / "release-artifacts.sha256").write_text("".join(
                        hashlib.sha256((repo / name).read_bytes()).hexdigest() + "  " + name + "\n"
                        for name in files))
                    if public_input_shape is not None:
                        target = repo / public_input_shape
                        target.unlink()
                        os.mkfifo(target)
                        with calls.open("a") as log:
                            log.write("public-input-fifo " + public_input_shape + "\n")
                    else:
                        with calls.open("a") as log:
                            log.write("public-input-healthy\n")
                    reverify = next(step for step in workflow["jobs"]["validate-install" if entrypoint == "install" else "publish"]["steps"]
                                    if step.get("name") == "Reverify downloaded release artifact")
                    arguments = (["bash", str(scripts / "release-consume-final.sh"), "verify", "1.2.3",
                                  sha, str(candidate), str(bundle), str(tool), str(repo)]
                                 if entrypoint == "direct" else
                                 ["bash", "-e", "-o", "pipefail", "-c", reverify["run"]])
                    result = run(arguments, timeout=reverify_timeout)
                    if result.returncode == 0:
                        with calls.open("a") as log:
                            log.write("hosted-release-action\n")
            else:
                result = run(arguments)
            return result, calls.read_text().splitlines() if calls.exists() else []

    def test_missing_or_invalid_trusted_bundle_never_reaches_publication(self):
        for bundle_kind in ("missing", "invalid"):
            with self.subTest(bundle=bundle_kind):
                result, calls = self.run_consumer(bundle_kind)
                published = [call for call in calls if call.startswith(("git tag ",
                             "git push ", "gh release create "))]
                self.assertEqual(published, [], result.stdout + result.stderr)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


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
