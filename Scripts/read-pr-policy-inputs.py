#!/usr/bin/env python3
"""Read one immutable pull-request snapshot for the PR policy workflow."""
import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NoReturn


class InputError(Exception):
    """The workflow could not establish one coherent PR input snapshot."""


def fail(message) -> NoReturn:
    raise InputError(message)


def required_string(value, name):
    if not isinstance(value, str) or not value:
        fail(f"PR metadata has no usable {name}")
    return value


def repository_name(value, name):
    if not isinstance(value, dict):
        fail(f"PR metadata has no usable {name} repository")
    return required_string(value.get("full_name"), f"{name} repository")


def branch(value, name):
    if not isinstance(value, dict):
        fail(f"PR metadata has no usable {name}")
    return (required_string(value.get("sha"), f"{name} sha"),
            required_string(value.get("ref"), f"{name} ref"),
            repository_name(value.get("repo"), name))


def snapshot(value):
    """Return data whose change can alter a policy decision or its identity."""
    if not isinstance(value, dict):
        fail("PR metadata is not an object")
    number, changed_files, body = value.get("number"), value.get("changed_files"), value.get("body")
    if not isinstance(number, int) or number <= 0:
        fail("PR metadata has no usable number")
    if not isinstance(changed_files, int) or changed_files <= 0:
        fail("PR metadata has no usable changed_files count")
    if body is None:
        body = ""
    if not isinstance(body, str):
        fail("PR metadata body is not text")
    head_sha, head_ref, head_repo = branch(value.get("head"), "head")
    base_sha, base_ref, base_repo = branch(value.get("base"), "base")
    return (number, head_sha, head_ref, head_repo, base_sha, base_ref, base_repo,
            required_string(value.get("merge_commit_sha"), "merge_commit_sha"), changed_files, body)


def event_snapshot(path):
    try:
        with open(path, encoding="utf-8") as handle:
            event = json.load(handle)
    except (OSError, ValueError):
        fail("cannot read pull request event")
    if not isinstance(event, dict) or not isinstance(event.get("pull_request"), dict):
        fail("pull request event has no pull_request object")
    data = snapshot({**event["pull_request"], "changed_files": 1, "body": ""})
    return event.get("action"), data[:8]


def command_json(command):
    try:
        completed = subprocess.run(command, capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        fail("GitHub API lookup failed")
    if completed.returncode:
        fail("GitHub API lookup failed")
    try:
        return json.loads(completed.stdout)
    except (UnicodeDecodeError, ValueError):
        fail("GitHub API returned invalid JSON")


def metadata(gh, endpoint):
    return snapshot(command_json([gh, "api", "--method", "GET", endpoint]))


def valid_filename(value):
    return isinstance(value, str) and value and "\n" not in value and "\r" not in value and "\x00" not in value


def files(gh, endpoint):
    pages = command_json([gh, "api", "--paginate", "--slurp", f"{endpoint}/files"])
    if not isinstance(pages, list):
        fail("GitHub file pagination did not return pages")
    names, seen, records = [], set(), 0
    for page in pages:
        if not isinstance(page, list):
            fail("GitHub file pagination returned a non-list page")
        for item in page:
            if not isinstance(item, dict) or not valid_filename(item.get("filename")):
                fail("GitHub file pagination returned an unusable filename")
            records += 1
            candidates = [item["filename"]]
            previous = item.get("previous_filename")
            if previous is not None:
                if not valid_filename(previous):
                    fail("GitHub file pagination returned an unusable filename")
                candidates.append(previous)
            for name in candidates:
                if name in seen:
                    fail("GitHub file pagination returned a duplicate filename")
                seen.add(name)
                names.append(name)
    return records, names


def checkout_identity(git):
    try:
        revision = subprocess.run([git, "rev-parse", "HEAD"], capture_output=True, text=True, timeout=15)
        parents = subprocess.run([git, "show", "-s", "--format=%P", "HEAD"], capture_output=True,
                                 text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        fail("cannot identify checked out revision")
    if revision.returncode or parents.returncode:
        fail("cannot identify checked out revision")
    result, parent_list = revision.stdout.strip(), parents.stdout.split()
    if not result or len(parent_list) != 2:
        fail("checkout is not a pull request merge commit")
    return result, tuple(parent_list)


def has_validated_current_merge(gh, repository, identity):
    """Accept a completed CI run for exactly this source head and PR base."""
    number, head, _head_ref, _head_repo, base, base_ref, _base_repo, _merge = identity
    response = command_json([gh, "api", "--method", "GET",
        f"repos/{repository}/actions/workflows/ci.yml/runs?event=pull_request&head_sha={head}&per_page=100"])
    runs = response.get("workflow_runs") if isinstance(response, dict) else None
    if not isinstance(runs, list):
        return False
    for run in runs:
        if not isinstance(run, dict) or run.get("event") != "pull_request":
            continue
        if run.get("status") != "completed" or run.get("conclusion") != "success":
            continue
        if run.get("head_sha") != head:
            continue
        repository_data = run.get("repository")
        if not isinstance(repository_data, dict) or repository_data.get("full_name") != repository:
            continue
        pull_requests = run.get("pull_requests")
        if not isinstance(pull_requests, list):
            continue
        for run_pr in pull_requests:
            if not isinstance(run_pr, dict) or run_pr.get("number") != number:
                continue
            run_head, run_base = run_pr.get("head"), run_pr.get("base")
            if (isinstance(run_head, dict) and isinstance(run_base, dict)
                    and run_head.get("sha") == head and run_base.get("sha") == base
                    and run_base.get("ref") == base_ref):
                return True
    return False


def write_atomic(path, data):
    destination = Path(path)
    with tempfile.NamedTemporaryFile("wb", dir=destination.parent, prefix=f".{destination.name}.",
                                     delete=False) as handle:
        handle.write(data)
        temporary = handle.name
    os.replace(temporary, destination)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--body", required=True)
    parser.add_argument("--files", required=True)
    parser.add_argument("--gh", default="gh")
    parser.add_argument("--git", default="git")
    arguments = parser.parse_args(argv)
    repository, event_path, expected_checkout = (os.environ.get(name) for name in
        ("GITHUB_REPOSITORY", "GITHUB_EVENT_PATH", "GITHUB_SHA"))
    if not repository or not event_path or not expected_checkout:
        fail("GITHUB_REPOSITORY, GITHUB_EVENT_PATH, and GITHUB_SHA are required")

    action, event = event_snapshot(event_path)
    endpoint = f"repos/{repository}/pulls/{event[0]}"
    before = metadata(arguments.gh, endpoint)
    if before[:8] != event or before[6] != repository:
        fail("event and API pull request identity differ")
    revision, parents = checkout_identity(arguments.git)
    if revision != expected_checkout or expected_checkout != before[7] or parents != (before[1], before[4]):
        fail("checkout identity does not match the pull request merge")
    if action == "edited" and not has_validated_current_merge(arguments.gh, repository, before[:8]):
        fail("no completed code validation matches this edited pull request merge")

    records, names = files(arguments.gh, endpoint)
    if records != before[8]:
        fail("incomplete changed-file pagination")
    after = metadata(arguments.gh, endpoint)
    if after != before:
        fail("pull request inputs drifted while files were read")
    write_atomic(arguments.body, before[9].encode("utf-8"))
    write_atomic(arguments.files, "".join(f"{name}\n" for name in names).encode("utf-8"))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except InputError as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1)
