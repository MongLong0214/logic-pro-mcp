#!/usr/bin/env python3
import copy
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

REPO = Path(__file__).resolve().parents[1]
VERIFIER = REPO / "Scripts" / "release-verify-candidate.py"
SOURCE = "a" * 40
VERSION = "v3.19.0"
RUN_ID = 12345
ATTEMPT = 2
ARTIFACT_ID = 9001
ARTIFACT_DIGEST = "sha256:" + "d" * 64


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class CandidateVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.temp)

    def write_json(self, name, value):
        path = self.temp / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def invoke(self, *arguments):
        return subprocess.run(
            [sys.executable, str(VERIFIER), *map(str, arguments)],
            cwd=REPO, text=True, capture_output=True, check=False,
        )

    def valid_run(self):
        workflow = {"id": 77, "path": ".github/workflows/release.yml"}
        run = {
            "id": RUN_ID, "event": "workflow_dispatch", "workflow_id": 77,
            "path": ".github/workflows/release.yml", "head_branch": "main",
            "head_sha": SOURCE, "status": "completed", "conclusion": "success",
            "run_attempt": ATTEMPT,
            "repository": {"full_name": "MongLong0214/logic-pro-mcp"},
        }
        artifacts = {"total_count": 1, "artifacts": [{
            "id": ARTIFACT_ID, "name": f"release-candidate-{RUN_ID}-{ATTEMPT}",
            "expired": False, "size_in_bytes": 4096, "digest": ARTIFACT_DIGEST,
        }]}
        jobs = {"total_count": 3, "jobs": [
            {"id": 1, "run_id": RUN_ID, "run_attempt": ATTEMPT, "head_sha": SOURCE,
             "name": "candidate-package", "status": "completed", "conclusion": "success"},
            {"id": 2, "run_id": RUN_ID, "run_attempt": ATTEMPT, "head_sha": SOURCE,
             "name": "candidate-install-macos-15-intel", "status": "completed", "conclusion": "success"},
            {"id": 3, "run_id": RUN_ID, "run_attempt": ATTEMPT, "head_sha": SOURCE,
             "name": "candidate-install-macos-26", "status": "completed", "conclusion": "success"},
        ]}
        return workflow, run, artifacts, jobs

    def run_args(self, workflow, run, artifacts, jobs):
        return [
            "run", "--workflow-json", self.write_json("workflow.json", workflow),
            "--run-json", self.write_json("run.json", run),
            "--artifacts-json", self.write_json("artifacts.json", artifacts),
            "--jobs-json", self.write_json("jobs.json", jobs),
            "--repository", "MongLong0214/logic-pro-mcp", "--source-sha", SOURCE,
            "--run-id", str(RUN_ID), "--expected-attempt", str(ATTEMPT),
        ]

    def test_run_contract_rejects_identity_state_attempt_and_artifact_ambiguity(self):
        workflow, run, artifacts, jobs = self.valid_run()
        self.assertEqual(self.invoke(*self.run_args(workflow, run, artifacts, jobs)).returncode, 0)
        with_similar = {"total_count": 2, "artifacts": artifacts["artifacts"] + [{
            **artifacts["artifacts"][0], "id": 9002,
            "name": f"release-candidate-{RUN_ID}-{ATTEMPT}-similar",
        }]}
        self.assertEqual(self.invoke(*self.run_args(workflow, run, with_similar, jobs)).returncode, 0)

        cases = []
        for field, value in [
            ("event", "push"), ("workflow_id", 99), ("path", ".github/workflows/other.yml"),
            ("head_branch", "feature"), ("head_sha", "b" * 40), ("status", "in_progress"),
            ("conclusion", "failure"), ("run_attempt", 3),
        ]:
            changed = copy.deepcopy(run)
            changed[field] = value
            cases.append((workflow, changed, artifacts, jobs))
        changed = copy.deepcopy(run)
        changed["repository"]["full_name"] = "other/repo"
        cases.append((workflow, changed, artifacts, jobs))
        changed_workflow = {"id": 77, "path": ".github/workflows/other.yml"}
        cases.append((changed_workflow, run, artifacts, jobs))
        for candidate_artifacts in [
            {"total_count": 0, "artifacts": []},
            {"total_count": 2, "artifacts": artifacts["artifacts"] * 2},
            [{"total_count": 2, "artifacts": artifacts["artifacts"]}],
            {"total_count": 1, "artifacts": [{**artifacts["artifacts"][0], "expired": True}]},
            {"total_count": 1, "artifacts": [{**artifacts["artifacts"][0], "size_in_bytes": 0}]},
            {"total_count": 1, "artifacts": [{**artifacts["artifacts"][0], "name": "wrong"}]},
            {"total_count": 1, "artifacts": [{**artifacts["artifacts"][0], "id": 0}]},
            {"total_count": 1, "artifacts": [{**artifacts["artifacts"][0], "digest": "sha256:bad"}]},
        ]:
            cases.append((workflow, run, candidate_artifacts, jobs))
        for job_change in ["missing", "skipped", "in_progress", "run", "head", "attempt",
                           "duplicate", "truncated"]:
            changed_jobs = copy.deepcopy(jobs)
            if job_change == "missing":
                changed_jobs["jobs"].pop(); changed_jobs["total_count"] = 2
            elif job_change == "skipped": changed_jobs["jobs"][1]["conclusion"] = "skipped"
            elif job_change == "in_progress": changed_jobs["jobs"][1]["status"] = "in_progress"
            elif job_change == "run": changed_jobs["jobs"][1]["run_id"] = RUN_ID - 1
            elif job_change == "head": changed_jobs["jobs"][1]["head_sha"] = "e" * 40
            elif job_change == "attempt": changed_jobs["jobs"][1]["run_attempt"] = ATTEMPT - 1
            elif job_change == "duplicate":
                changed_jobs["jobs"].append(copy.deepcopy(changed_jobs["jobs"][1])); changed_jobs["total_count"] = 4
            else: changed_jobs["total_count"] = 4
            cases.append((workflow, run, artifacts, changed_jobs))
        for index, values in enumerate(cases):
            with self.subTest(index=index):
                result = self.invoke(*self.run_args(*values))
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def valid_tag_text(self, manifest="b" * 64):
        return "\n\n".join([
            f"Release {VERSION}", f"Native-qualified: {SOURCE}",
            f"Candidate-run-id: {RUN_ID}", f"Candidate-run-attempt: {ATTEMPT}",
            f"Candidate-artifact-id: {ARTIFACT_ID}",
            f"Candidate-artifact-digest: {ARTIFACT_DIGEST}",
            f"Candidate-source: {SOURCE}", f"Candidate-manifest-sha256: {manifest}",
        ]) + "\n"

    def test_tag_contract_rejects_lightweight_wrong_target_missing_duplicate_and_malformed(self):
        message = self.temp / "tag.txt"
        valid_text = self.valid_tag_text()
        message.write_text(valid_text, encoding="utf-8")
        valid = ["tag", "--message-file", message, "--version", VERSION,
                 "--object-type", "tag", "--peeled-sha", SOURCE,
                 "--expected-run-id", str(RUN_ID),
                 "--expected-run-attempt", str(ATTEMPT),
                 "--expected-artifact-id", str(ARTIFACT_ID),
                 "--expected-artifact-digest", ARTIFACT_DIGEST,
                 "--expected-source-sha", SOURCE,
                 "--expected-manifest-sha256", "b" * 64]
        self.assertEqual(self.invoke(*valid).returncode, 0)
        cases = [
            ("object", "commit"), ("peeled", "c" * 40),
            ("text", valid_text.replace(f"Candidate-run-id: {RUN_ID}\n", "")),
            ("text", valid_text + f"\nCandidate-run-id: {RUN_ID}\n"),
            ("text", valid_text.replace(f"Candidate-run-attempt: {ATTEMPT}",
                                        "Candidate-run-attempt: 02")),
            ("text", valid_text.replace(f"Candidate-artifact-id: {ARTIFACT_ID}",
                                        "Candidate-artifact-id: 09001")),
            ("text", valid_text.replace(ARTIFACT_DIGEST, "sha256:bad")),
            ("text", valid_text.replace(f"Candidate-source: {SOURCE}",
                                        f" Candidate-source: {SOURCE}")),
        ]
        for index, (kind, value) in enumerate(cases):
            with self.subTest(index=index):
                args = list(valid)
                if kind == "object": args[args.index("--object-type") + 1] = value
                elif kind == "peeled": args[args.index("--peeled-sha") + 1] = value
                else: message.write_text(value, encoding="utf-8")
                self.assertNotEqual(self.invoke(*args).returncode, 0)
                message.write_text(valid_text, encoding="utf-8")
        for option, wrong in [
            ("--expected-run-id", str(RUN_ID + 1)),
            ("--expected-run-attempt", str(ATTEMPT + 1)),
            ("--expected-artifact-id", str(ARTIFACT_ID + 1)),
            ("--expected-artifact-digest", "sha256:" + "e" * 64),
            ("--expected-source-sha", "e" * 40),
            ("--expected-manifest-sha256", "e" * 64),
        ]:
            with self.subTest(option=option):
                args = list(valid)
                args[args.index(option) + 1] = wrong
                self.assertNotEqual(self.invoke(*args).returncode, 0)

    def members(self):
        output = subprocess.check_output(
            ["bash", "Scripts/release-package.sh", "--list-members"], cwd=REPO, text=True)
        return output.splitlines()

    def write_archive(self, path, binary=b"candidate-binary", unsafe=False, absolute=False,
                      link=False, duplicate=False):
        with tarfile.open(path, "w:gz") as archive:
            for member in self.members():
                name = member
                if unsafe and member == "docs/SETUP.md": name = "../escape"
                if absolute and member == "docs/SETUP.md": name = "/absolute"
                info = tarfile.TarInfo(name)
                if link and member == "docs/SETUP.md":
                    info.type = tarfile.SYMTYPE
                    info.linkname = "LogicProMCP"
                    archive.addfile(info)
                    continue
                data = binary if member == "LogicProMCP" else f"fixture:{member}".encode()
                info.size = len(data)
                info.mode = 0o755 if member == "LogicProMCP" else 0o644
                archive.addfile(info, io.BytesIO(data))
                if duplicate and member == "LogicProMCP":
                    duplicate_info = tarfile.TarInfo(member)
                    duplicate_info.size = len(data)
                    duplicate_info.mode = 0o755
                    archive.addfile(duplicate_info, io.BytesIO(data))

    def make_package(self):
        root = self.temp / "package"
        if root.exists(): shutil.rmtree(root)
        root.mkdir()
        (root / "LogicProMCP").write_bytes(b"candidate-binary")
        (root / "LogicProMCP").chmod(0o755)
        for name in ["LogicProMCP-macOS-universal.tar.gz", "LogicProMCP-macOS-arm64.tar.gz"]:
            self.write_archive(root / name)
        (root / "RELEASE-METADATA.json").write_text(json.dumps({
            "version": VERSION, "source_sha": SOURCE, "signing": "unsigned",
            "architectures": ["arm64", "x86_64"],
        }, separators=(",", ":")), encoding="utf-8")
        self.refresh(root)
        return root

    def refresh(self, root):
        inner = ["LogicProMCP-macOS-universal.tar.gz", "LogicProMCP-macOS-arm64.tar.gz", "LogicProMCP"]
        (root / "SHA256SUMS.txt").write_text(
            "".join(f"{sha256(root / name)}  {name}\n" for name in inner), encoding="utf-8")
        outer = ["LogicProMCP", "LogicProMCP-macOS-universal.tar.gz",
                 "LogicProMCP-macOS-arm64.tar.gz", "RELEASE-METADATA.json", "SHA256SUMS.txt"]
        (root / "release-artifacts.sha256").write_text(
            "".join(f"{sha256(root / name)}  {name}\n" for name in outer), encoding="utf-8")

    def package_args(self, root, expected):
        return ["package", "--directory", root, "--version", VERSION, "--source-sha", SOURCE,
                "--expected-manifest-sha", expected]

    def test_package_rejects_metadata_manifest_payload_unsafe_and_link_substitution(self):
        root = self.make_package()
        expected = sha256(root / "release-artifacts.sha256")
        self.assertEqual(self.invoke(*self.package_args(root, expected)).returncode, 0)
        for case in ["missing", "outer", "outer-extra", "manifest-duplicate", "manifest-hash",
                     "duplicate", "version", "source", "architectures", "substitute",
                     "arm-substitute", "unsafe", "absolute", "link", "archive-duplicate"]:
            with self.subTest(case=case):
                root = self.make_package()
                expected = sha256(root / "release-artifacts.sha256")
                if case == "missing":
                    (root / "release-artifacts.sha256").unlink()
                elif case == "outer":
                    (root / "release-artifacts.sha256").write_text("malformed\n")
                elif case == "outer-extra":
                    (root / "unexpected.txt").write_text("extra", encoding="utf-8")
                elif case == "manifest-duplicate":
                    manifest = root / "release-artifacts.sha256"
                    manifest.write_text(manifest.read_text() + manifest.read_text().splitlines()[0] + "\n")
                    expected = sha256(manifest)
                elif case == "manifest-hash":
                    manifest = root / "release-artifacts.sha256"
                    manifest.write_text("z" * 64 + manifest.read_text()[64:])
                    expected = sha256(manifest)
                elif case == "duplicate":
                    (root / "RELEASE-METADATA.json").write_text(
                        '{"version":"v3.19.0","source_sha":"' + SOURCE
                        + '","source_sha":"' + SOURCE + '","signing":"unsigned",'
                          '"architectures":["arm64","x86_64"]}', encoding="utf-8")
                    self.refresh(root); expected = sha256(root / "release-artifacts.sha256")
                elif case in {"version", "source", "architectures"}:
                    metadata = json.loads((root / "RELEASE-METADATA.json").read_text())
                    if case == "version": metadata["version"] = "v3.18.0"
                    if case == "source": metadata["source_sha"] = "c" * 40
                    if case == "architectures": metadata["architectures"] = ["arm64"]
                    (root / "RELEASE-METADATA.json").write_text(json.dumps(metadata), encoding="utf-8")
                    self.refresh(root); expected = sha256(root / "release-artifacts.sha256")
                else:
                    archive = root / ("LogicProMCP-macOS-arm64.tar.gz" if case == "arm-substitute"
                                      else "LogicProMCP-macOS-universal.tar.gz")
                    self.write_archive(archive, binary=b"substitute" if case == "substitute" else b"candidate-binary",
                                       unsafe=case == "unsafe", absolute=case == "absolute",
                                       link=case == "link", duplicate=case == "archive-duplicate")
                    if case == "arm-substitute":
                        self.write_archive(archive, binary=b"arm-substitute")
                    self.refresh(root); expected = sha256(root / "release-artifacts.sha256")
                result = self.invoke(*self.package_args(root, expected))
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_public_assets_require_the_exact_five_names_and_candidate_bytes(self):
        candidate = self.make_package()
        expected = self.temp / "expected"
        actual = self.temp / "actual"
        expected.mkdir(); actual.mkdir()
        assets = ["LogicProMCP", "LogicProMCP-macOS-universal.tar.gz",
                  "LogicProMCP-macOS-arm64.tar.gz", "RELEASE-METADATA.json", "SHA256SUMS.txt"]
        for name in assets:
            shutil.copy2(candidate / name, expected / name)
            shutil.copy2(candidate / name, actual / name)
        args = ["assets", "--expected-directory", expected, "--actual-directory", actual]
        self.assertEqual(self.invoke(*args).returncode, 0)
        for case in ["missing", "extra", "mismatch"]:
            shutil.rmtree(actual); actual.mkdir()
            for name in assets: shutil.copy2(candidate / name, actual / name)
            if case == "missing": (actual / assets[0]).unlink()
            if case == "extra": (actual / "unexpected").write_text("extra")
            if case == "mismatch": (actual / assets[0]).write_bytes(b"different")
            with self.subTest(case=case):
                self.assertNotEqual(self.invoke(*args).returncode, 0)

    def test_artifact_zip_digest_inventory_and_safe_extraction(self):
        package = self.make_package()
        archive = self.temp / "artifact.zip"
        with zipfile.ZipFile(archive, "w") as output:
            for name in ["LogicProMCP", "LogicProMCP-macOS-universal.tar.gz",
                         "LogicProMCP-macOS-arm64.tar.gz", "RELEASE-METADATA.json",
                         "SHA256SUMS.txt", "release-artifacts.sha256"]:
                output.write(package / name, name)
        destination = self.temp / "extracted"
        args = ["extract", "--zip", archive, "--directory", destination,
                "--expected-digest", "sha256:" + sha256(archive)]
        self.assertEqual(self.invoke(*args).returncode, 0)
        self.assertEqual(sorted(path.name for path in destination.iterdir()),
                         sorted(path.name for path in package.iterdir()))
        for case in ["digest", "extra", "absolute", "traversal", "duplicate", "symlink"]:
            bad = self.temp / f"{case}.zip"
            with zipfile.ZipFile(bad, "w") as output:
                for name in ["LogicProMCP", "LogicProMCP-macOS-universal.tar.gz",
                             "LogicProMCP-macOS-arm64.tar.gz", "RELEASE-METADATA.json",
                             "SHA256SUMS.txt", "release-artifacts.sha256"]:
                    output.write(package / name, name)
                if case == "extra": output.writestr("unexpected", b"extra")
                if case == "absolute": output.writestr("/absolute", b"bad")
                if case == "traversal": output.writestr("../escape", b"bad")
                if case == "duplicate": output.writestr("LogicProMCP", b"duplicate")
                if case == "symlink":
                    entry = zipfile.ZipInfo("link")
                    entry.create_system = 3
                    entry.external_attr = (0o120777 << 16)
                    output.writestr(entry, "LogicProMCP")
            destination = self.temp / f"extract-{case}"
            digest = "sha256:" + ("0" * 64 if case == "digest" else sha256(bad))
            result = self.invoke("extract", "--zip", bad, "--directory", destination,
                                 "--expected-digest", digest)
            with self.subTest(case=case):
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
