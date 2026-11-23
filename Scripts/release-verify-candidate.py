#!/usr/bin/env python3
"""Fail-closed verifier for release candidate identity and bytes."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tarfile
import zipfile


WORKFLOW_PATH = ".github/workflows/release.yml"
PACKAGE_FILES = [
    "LogicProMCP",
    "LogicProMCP-macOS-universal.tar.gz",
    "LogicProMCP-macOS-arm64.tar.gz",
    "RELEASE-METADATA.json",
    "SHA256SUMS.txt",
    "release-artifacts.sha256",
]
PUBLIC_ASSETS = PACKAGE_FILES[:5]
INNER_FILES = [
    "LogicProMCP-macOS-universal.tar.gz",
    "LogicProMCP-macOS-arm64.tar.gz",
    "LogicProMCP",
]
ARCHIVE_MEMBERS = [
    "LogicProMCP",
    "docs/SETUP.md",
    "Scripts/install-keycmds.sh",
    "Scripts/uninstall-keycmds.sh",
    "Scripts/keycmd-preset.plist",
    "Scripts/LogicProMCP-Scripter.js",
    "Scripts/logic_bounce.py",
    "Scripts/logic_bounce_ui.py",
    "Scripts/logic_ui_jxa.py",
    "Scripts/logic_input_source.py",
    "Scripts/logic_variants.py",
    "Scripts/logic_ui_labels.py",
]
SHA = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
VERSION = re.compile(
    r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-((?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?"
)


class VerificationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise VerificationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"), object_pairs_hook=strict_object)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"invalid JSON {path}: {error}") from error


def positive_decimal(value, label):
    require(isinstance(value, int) and not isinstance(value, bool) and value > 0,
            f"{label} must be a positive integer")
    return value


def canonical_decimal(value, label):
    require(re.fullmatch(r"[1-9][0-9]*", value or "") is not None,
            f"{label} must be canonical positive decimal")
    return int(value)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def regular_file(path, label):
    try:
        mode = os.lstat(path).st_mode
    except OSError as error:
        raise VerificationError(f"missing {label}: {path}") from error
    require(stat.S_ISREG(mode), f"{label} must be a regular file: {path}")


def flatten_pages(document, list_key, label):
    pages = document if isinstance(document, list) else [document]
    require(pages, f"{label} pagination returned no pages")
    values = []
    totals = set()
    for page in pages:
        require(isinstance(page, dict), f"{label} page must be an object")
        total = page.get("total_count")
        require(isinstance(total, int) and not isinstance(total, bool) and total >= 0,
                f"{label} total_count must be a nonnegative integer")
        totals.add(total)
        page_values = page.get(list_key)
        require(isinstance(page_values, list), f"{label} page has no {list_key} list")
        values.extend(page_values)
    require(len(totals) == 1, f"{label} pages disagree on total_count")
    require(totals == {len(values)}, f"{label} pagination is incomplete or duplicated")
    return values


def command_run(args):
    workflow = read_json(args.workflow_json)
    run = read_json(args.run_json)
    artifacts_document = read_json(args.artifacts_json)
    jobs_document = read_json(args.jobs_json)
    require(isinstance(workflow, dict), "workflow response must be an object")
    workflow_id = positive_decimal(workflow.get("id"), "workflow id")
    require(workflow.get("path") == WORKFLOW_PATH, "workflow path mismatch")
    require(isinstance(run, dict), "run response must be an object")
    require(run.get("id") == args.run_id, "run id mismatch")
    require(run.get("event") == "workflow_dispatch", "candidate run event mismatch")
    require(run.get("workflow_id") == workflow_id, "candidate workflow id mismatch")
    require(run.get("path") == WORKFLOW_PATH, "candidate run workflow path mismatch")
    require(run.get("head_branch") == "main", "candidate branch is not main")
    require(run.get("head_sha") == args.source_sha, "candidate source SHA mismatch")
    require(run.get("status") == "completed", "candidate run is not completed")
    require(run.get("conclusion") == "success", "candidate run did not succeed")
    require(run.get("repository", {}).get("full_name") == args.repository,
            "candidate repository mismatch")
    attempt = positive_decimal(run.get("run_attempt"), "run attempt")
    if args.expected_attempt is not None:
        require(attempt == args.expected_attempt, "candidate run attempt mismatch")

    name = f"release-candidate-{args.run_id}-{attempt}"
    artifacts = flatten_pages(artifacts_document, "artifacts", "artifact")
    exact_artifacts = [artifact for artifact in artifacts
                       if isinstance(artifact, dict) and artifact.get("name") == name]
    require(len(exact_artifacts) == 1, "candidate run must contain exactly one exact-name artifact")
    artifact = exact_artifacts[0]
    artifact_id = positive_decimal(artifact.get("id"), "artifact id")
    require(artifact.get("expired") is False, "candidate artifact is expired")
    require(positive_decimal(artifact.get("size_in_bytes"), "artifact size") > 0,
            "candidate artifact is empty")
    digest = artifact.get("digest")
    require(isinstance(digest, str) and DIGEST.fullmatch(digest) is not None,
            "candidate artifact digest is missing or malformed")
    jobs = flatten_pages(jobs_document, "jobs", "job")
    required_jobs = {
        "candidate-package",
        "candidate-install-macos-15-intel",
        "candidate-install-macos-26",
    }
    selected_jobs = [job for job in jobs if isinstance(job, dict) and job.get("name") in required_jobs]
    require(len(selected_jobs) == len(required_jobs) and
            {job.get("name") for job in selected_jobs} == required_jobs,
            "candidate run is missing or duplicates a required package/install job")
    for job in selected_jobs:
        positive_decimal(job.get("id"), f"job id for {job.get('name')}")
        require(job.get("run_id") == args.run_id, f"candidate job run id mismatch: {job.get('name')}")
        require(job.get("head_sha") == args.source_sha,
                f"candidate job source SHA mismatch: {job.get('name')}")
        if "run_attempt" in job:
            require(job.get("run_attempt") == attempt,
                    f"candidate job attempt mismatch: {job.get('name')}")
        require(job.get("status") == "completed", f"candidate job is not completed: {job.get('name')}")
        require(job.get("conclusion") == "success", f"candidate job did not succeed: {job.get('name')}")
    print(json.dumps({
        "artifact_digest": digest,
        "artifact_id": artifact_id,
        "artifact_name": name,
        "run_attempt": attempt,
        "run_id": args.run_id,
        "source_sha": args.source_sha,
    }, sort_keys=True, separators=(",", ":")))


def command_tag(args):
    require(args.object_type == "tag", "release tag must be annotated")
    require(SHA.fullmatch(args.peeled_sha or "") is not None, "peeled tag target is malformed")
    try:
        text = Path(args.message_file).read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise VerificationError(f"cannot read tag message: {error}") from error
    require(text.endswith("\n"), "tag message must end with a newline")
    lines = text.splitlines()
    require(lines and lines[0] == f"Release {args.version}", "tag release heading mismatch")
    fields = {
        "Native-qualified": SHA,
        "Candidate-run-id": None,
        "Candidate-run-attempt": None,
        "Candidate-artifact-id": None,
        "Candidate-artifact-digest": DIGEST,
        "Candidate-source": SHA,
        "Candidate-manifest-sha256": SHA256,
    }
    values = {}
    for line in lines[1:]:
        if not line:
            continue
        require(": " in line, f"malformed tag binding line: {line}")
        key, value = line.split(": ", 1)
        require(key in fields, f"unexpected tag binding: {key}")
        require(key not in values, f"duplicate tag binding: {key}")
        matcher = fields[key]
        if matcher is not None:
            require(matcher.fullmatch(value) is not None, f"malformed tag binding: {key}")
        values[key] = value
    require(set(values) == set(fields), "tag is missing one or more canonical bindings")
    run_id = canonical_decimal(values["Candidate-run-id"], "candidate run id")
    attempt = canonical_decimal(values["Candidate-run-attempt"], "candidate run attempt")
    artifact_id = canonical_decimal(values["Candidate-artifact-id"], "candidate artifact id")
    require(values["Native-qualified"] == args.peeled_sha, "native-qualified SHA is not tag target")
    require(values["Candidate-source"] == args.peeled_sha, "candidate source is not tag target")
    result = {
        "artifact_digest": values["Candidate-artifact-digest"],
        "artifact_id": artifact_id,
        "manifest_sha256": values["Candidate-manifest-sha256"],
        "run_attempt": attempt,
        "run_id": run_id,
        "source_sha": args.peeled_sha,
        "version": args.version,
    }
    expected = {
        "artifact_digest": args.expected_artifact_digest,
        "artifact_id": args.expected_artifact_id,
        "manifest_sha256": args.expected_manifest_sha256,
        "run_attempt": args.expected_run_attempt,
        "run_id": args.expected_run_id,
        "source_sha": args.expected_source_sha,
    }
    supplied = [value is not None for value in expected.values()]
    require(not any(supplied) or all(supplied),
            "expected tag binding arguments must be supplied together")
    if all(supplied):
        require(expected["run_id"] > 0 and expected["run_attempt"] > 0 and
                expected["artifact_id"] > 0, "expected tag ids must be positive")
        require(DIGEST.fullmatch(expected["artifact_digest"]) is not None,
                "expected artifact digest is malformed")
        require(SHA.fullmatch(expected["source_sha"]) is not None,
                "expected source SHA is malformed")
        require(SHA256.fullmatch(expected["manifest_sha256"]) is not None,
                "expected manifest digest is malformed")
        require(all(result[key] == value for key, value in expected.items()),
                "tag binding does not match the reverified candidate")
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))


def parse_manifest(path, expected_names):
    regular_file(path, "manifest")
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise VerificationError(f"cannot read manifest {path}: {error}") from error
    require(len(lines) == len(expected_names), f"wrong manifest inventory: {path}")
    entries = []
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
        require(match is not None, f"malformed manifest line: {line}")
        entries.append((match.group(2), match.group(1)))
    names = [name for name, _ in entries]
    require(len(set(names)) == len(names), "manifest contains duplicate filenames")
    require(names == expected_names, "manifest filename inventory or order mismatch")
    return dict(entries)


def verify_archive(path, loose_binary):
    regular_file(path, "release archive")
    try:
        with tarfile.open(path, "r:gz") as archive:
            members = archive.getmembers()
            names = [member.name for member in members]
            require(len(names) == len(set(names)), "archive contains duplicate members")
            require(names == ARCHIVE_MEMBERS, "archive member inventory or order mismatch")
            for member in members:
                pure = PurePosixPath(member.name)
                require(not pure.is_absolute() and ".." not in pure.parts,
                        f"unsafe archive member: {member.name}")
                require(member.isfile(), f"archive member is not a regular file: {member.name}")
            binary = archive.extractfile("LogicProMCP")
            require(binary is not None, "archive has no LogicProMCP payload")
            require(binary.read() == loose_binary, "archive executable differs from candidate bytes")
    except (OSError, tarfile.TarError) as error:
        raise VerificationError(f"invalid release archive {path}: {error}") from error


def command_package(args):
    root = Path(args.directory)
    require(root.is_dir() and not root.is_symlink(), "candidate package directory is invalid")
    actual_names = sorted(entry.name for entry in root.iterdir())
    require(actual_names == sorted(PACKAGE_FILES), "candidate package outer inventory mismatch")
    for name in PACKAGE_FILES:
        regular_file(root / name, name)
    require(os.access(root / "LogicProMCP", os.X_OK), "candidate executable is not executable")
    require(VERSION.fullmatch(args.version or "") is not None, "expected version is not strict SemVer")
    require(SHA.fullmatch(args.source_sha or "") is not None, "expected source SHA is malformed")
    metadata = read_json(root / "RELEASE-METADATA.json")
    require(isinstance(metadata, dict), "release metadata must be an object")
    require(set(metadata) == {"version", "source_sha", "signing", "architectures"},
            "release metadata keys mismatch")
    require(metadata["version"] == args.version, "release metadata version mismatch")
    require(metadata["source_sha"] == args.source_sha, "release metadata source SHA mismatch")
    require(metadata["signing"] == "unsigned", "release metadata signing mode mismatch")
    architectures = metadata["architectures"]
    require(isinstance(architectures, list) and len(architectures) == 2 and
            set(architectures) == {"arm64", "x86_64"}, "release architectures mismatch")
    inner = parse_manifest(root / "SHA256SUMS.txt", INNER_FILES)
    outer = parse_manifest(root / "release-artifacts.sha256", PUBLIC_ASSETS)
    for name, digest in inner.items():
        require(sha256(root / name) == digest, f"inner manifest hash mismatch: {name}")
    for name, digest in outer.items():
        require(sha256(root / name) == digest, f"outer manifest hash mismatch: {name}")
    manifest_digest = sha256(root / "release-artifacts.sha256")
    if args.expected_manifest_sha:
        require(SHA256.fullmatch(args.expected_manifest_sha) is not None,
                "expected manifest digest is malformed")
        require(manifest_digest == args.expected_manifest_sha, "outer manifest digest mismatch")
    loose_binary = (root / "LogicProMCP").read_bytes()
    verify_archive(root / "LogicProMCP-macOS-universal.tar.gz", loose_binary)
    verify_archive(root / "LogicProMCP-macOS-arm64.tar.gz", loose_binary)
    print(json.dumps({
        "manifest_sha256": manifest_digest,
        "source_sha": args.source_sha,
        "version": args.version,
    }, sort_keys=True, separators=(",", ":")))


def command_assets(args):
    expected = Path(args.expected_directory)
    actual = Path(args.actual_directory)
    require(expected.is_dir() and not expected.is_symlink(), "expected assets directory is invalid")
    require(sorted(entry.name for entry in expected.iterdir()) == sorted(PUBLIC_ASSETS),
            "expected assets inventory mismatch")
    for name in PUBLIC_ASSETS:
        regular_file(expected / name, f"expected asset {name}")
    require(actual.is_dir() and not actual.is_symlink(), "actual assets directory is invalid")
    actual_names = sorted(entry.name for entry in actual.iterdir())
    if args.allow_missing_actual:
        require(set(actual_names).issubset(PUBLIC_ASSETS), "actual assets inventory mismatch")
    else:
        require(actual_names == sorted(PUBLIC_ASSETS), "actual assets inventory mismatch")
    for name in actual_names:
        regular_file(actual / name, f"actual asset {name}")
        require(sha256(expected / name) == sha256(actual / name),
                f"published asset differs from candidate: {name}")
    print(json.dumps({"assets": actual_names}, separators=(",", ":")))


def command_extract(args):
    archive_path = Path(args.zip)
    destination = Path(args.directory)
    regular_file(archive_path, "artifact ZIP")
    require(DIGEST.fullmatch(args.expected_digest or "") is not None,
            "expected artifact digest is malformed")
    require("sha256:" + sha256(archive_path) == args.expected_digest,
            "downloaded artifact ZIP digest mismatch")
    require(not destination.exists(), "artifact extraction destination already exists")
    try:
        with zipfile.ZipFile(archive_path) as archive:
            entries = archive.infolist()
            names = [entry.filename for entry in entries]
            require(len(names) == len(set(names)), "artifact ZIP contains duplicate members")
            require(sorted(names) == sorted(PACKAGE_FILES), "artifact ZIP inventory mismatch")
            total_size = 0
            for entry in entries:
                pure = PurePosixPath(entry.filename)
                require(not pure.is_absolute() and ".." not in pure.parts and len(pure.parts) == 1,
                        f"unsafe artifact ZIP member: {entry.filename}")
                unix_mode = entry.external_attr >> 16
                require(not stat.S_ISLNK(unix_mode), f"artifact ZIP member is a link: {entry.filename}")
                require(not entry.is_dir(), f"artifact ZIP member is not a file: {entry.filename}")
                total_size += entry.file_size
                require(entry.file_size <= 512 * 1024 * 1024,
                        f"artifact ZIP member is unreasonably large: {entry.filename}")
            require(total_size <= 1024 * 1024 * 1024, "artifact ZIP expands beyond the size limit")
            destination.mkdir(mode=0o700, parents=True)
            for entry in entries:
                target = destination / entry.filename
                with archive.open(entry) as source, target.open("xb") as output:
                    while True:
                        block = source.read(1024 * 1024)
                        if not block:
                            break
                        output.write(block)
    except (OSError, zipfile.BadZipFile) as error:
        raise VerificationError(f"invalid artifact ZIP: {error}") from error
    print(json.dumps({"files": PACKAGE_FILES}, separators=(",", ":")))


def parser():
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run")
    run.add_argument("--workflow-json", required=True)
    run.add_argument("--run-json", required=True)
    run.add_argument("--artifacts-json", required=True)
    run.add_argument("--jobs-json", required=True)
    run.add_argument("--repository", required=True)
    run.add_argument("--source-sha", required=True, type=lambda value: value if SHA.fullmatch(value) else root.error("invalid source SHA"))
    run.add_argument("--run-id", required=True, type=int)
    run.add_argument("--expected-attempt", type=int)
    run.set_defaults(handler=command_run)
    tag = commands.add_parser("tag")
    tag.add_argument("--message-file", required=True)
    tag.add_argument("--version", required=True, type=lambda value: value if VERSION.fullmatch(value) else root.error("invalid version"))
    tag.add_argument("--object-type", required=True)
    tag.add_argument("--peeled-sha", required=True)
    tag.add_argument("--expected-run-id", type=int)
    tag.add_argument("--expected-run-attempt", type=int)
    tag.add_argument("--expected-artifact-id", type=int)
    tag.add_argument("--expected-artifact-digest")
    tag.add_argument("--expected-source-sha")
    tag.add_argument("--expected-manifest-sha256")
    tag.set_defaults(handler=command_tag)
    package = commands.add_parser("package")
    package.add_argument("--directory", required=True)
    package.add_argument("--version", required=True)
    package.add_argument("--source-sha", required=True)
    package.add_argument("--expected-manifest-sha")
    package.set_defaults(handler=command_package)
    assets = commands.add_parser("assets")
    assets.add_argument("--expected-directory", required=True)
    assets.add_argument("--actual-directory", required=True)
    assets.add_argument("--allow-missing-actual", action="store_true")
    assets.set_defaults(handler=command_assets)
    extract = commands.add_parser("extract")
    extract.add_argument("--zip", required=True)
    extract.add_argument("--directory", required=True)
    extract.add_argument("--expected-digest", required=True)
    extract.set_defaults(handler=command_extract)
    return root


def main():
    try:
        args = parser().parse_args()
        require(args.command != "run" or args.run_id > 0, "run id must be positive")
        require(args.command != "run" or args.expected_attempt is None or args.expected_attempt > 0,
                "expected attempt must be positive")
        args.handler(args)
    except VerificationError as error:
        print(f"release candidate verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
