#!/usr/bin/env python3
"""Classify an exact pull-request merge checkout for CI routing.

Only a regular-file modification to the canonical roadmap may take the
roadmap-docs-only path. Everything else retains full product validation.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROADMAP = b"docs/roadmap/README.md"
SHA = re.compile(r"[0-9a-f]{40}\Z")


class ClassificationError(Exception):
    """The workflow could not establish a trustworthy classification."""


def required_environment(name):
    value = os.environ.get(name)
    if not value:
        raise ClassificationError(f"missing {name}")
    return value


def git_output(git, *arguments):
    try:
        completed = subprocess.run(
            [git, *arguments], check=False, capture_output=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ClassificationError("cannot inspect checkout") from error
    if completed.returncode:
        raise ClassificationError("cannot inspect checkout")
    return completed.stdout


def event_identity(path):
    try:
        with open(path, encoding="utf-8") as handle:
            event = json.load(handle)
        pull_request = event["pull_request"]
        base = pull_request["base"]["sha"]
        head = pull_request["head"]["sha"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ClassificationError("checkout identity event is unusable") from error
    if not isinstance(base, str) or not isinstance(head, str):
        raise ClassificationError("checkout identity event is unusable")
    if not SHA.fullmatch(base) or not SHA.fullmatch(head):
        raise ClassificationError("checkout identity event is unusable")
    return base, head


def checkout_identity(git, expected_checkout, base, head):
    if not SHA.fullmatch(expected_checkout):
        raise ClassificationError("checkout identity SHA is unusable")
    revision = git_output(git, "rev-parse", "HEAD").decode("ascii", errors="strict").strip()
    parents = git_output(git, "rev-list", "--parents", "-n", "1", "HEAD").decode(
        "ascii", errors="strict"
    ).split()
    if revision != expected_checkout or parents != [expected_checkout, base, head]:
        raise ClassificationError("checkout identity does not match the pull request merge")


def diff_records(git, base, merge):
    payload = git_output(
        git, "diff", "--name-status", "-z", "--no-renames", base, merge,
    )
    fields = payload.split(b"\0")
    if not fields or fields[-1] != b"":
        raise ClassificationError("cannot parse merge diff")
    fields.pop()
    if len(fields) % 2:
        raise ClassificationError("cannot parse merge diff")
    return list(zip(fields[::2], fields[1::2]))


def regular_blob(git, revision, path):
    payload = git_output(git, "ls-tree", "-z", revision, "--", path.decode("ascii"))
    fields = [field for field in payload.split(b"\0") if field]
    if len(fields) != 1:
        return False
    metadata, separator, actual_path = fields[0].partition(b"\t")
    return separator == b"\t" and actual_path == path and metadata.split()[:2] == [b"100644", b"blob"]


def classify(git, base, merge):
    records = diff_records(git, base, merge)
    if records != [(b"M", ROADMAP)]:
        return "full", "true"
    if not regular_blob(git, base, ROADMAP) or not regular_blob(git, merge, ROADMAP):
        return "full", "true"
    return "roadmap-docs-only", "false"


def publish(mode, full_validation):
    output = Path(required_environment("GITHUB_OUTPUT"))
    summary = Path(required_environment("GITHUB_STEP_SUMMARY"))
    with output.open("a", encoding="utf-8") as handle:
        handle.write(f"mode={mode}\nfull-validation={full_validation}\n")
    with summary.open("a", encoding="utf-8") as handle:
        if mode == "roadmap-docs-only":
            handle.write("CI change scope: exact `docs/roadmap/README.md` regular-file modification.\n")
        else:
            handle.write("CI change scope: full product validation.\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--git", default="git")
    arguments = parser.parse_args()
    try:
        base, head = event_identity(required_environment("GITHUB_EVENT_PATH"))
        merge = required_environment("GITHUB_SHA")
        checkout_identity(arguments.git, merge, base, head)
        mode, full_validation = classify(arguments.git, base, merge)
        publish(mode, full_validation)
    except (ClassificationError, UnicodeDecodeError) as error:
        print(f"CI classification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
