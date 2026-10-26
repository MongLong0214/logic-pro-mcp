#!/usr/bin/env python3
"""Behavioral tests for the PR policy input snapshot helper."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from typing import Optional

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(REPO, "Scripts", "read-pr-policy-inputs.py")


def pr(body: Optional[str] = "No Logic facts.", *, head="head-sha", base="base-sha", merge: Optional[str] = "merge-sha",
       head_ref="feature", base_ref="main", count=2):
    return {
        "number": 42, "body": body, "changed_files": count,
        "head": {"sha": head, "ref": head_ref,
                 "repo": {"full_name": "fork/repo"}},
        "base": {"sha": base, "ref": base_ref,
                 "repo": {"full_name": "owner/repo"}},
        "merge_commit_sha": merge,
    }


def event_for(value, action="opened"):
    return {"action": action, "pull_request": {
        key: value[key] for key in ("number", "head", "base", "merge_commit_sha")}}


class PRPolicyInputs(unittest.TestCase):
    def run_helper(self, metadata, pages, *, event=None, checkout="merge-sha",
                   parents="base-sha head-sha", tree="tree-sha", runs=None,
                   commits=None, jobs=None, logs="", gh_exit=0):
        with tempfile.TemporaryDirectory() as directory:
            metadata = list(metadata)
            event = event or event_for(metadata[0])
            event_path = os.path.join(directory, "event.json")
            Path(event_path).write_text(json.dumps(event), encoding="utf-8")
            state_path = os.path.join(directory, "state.json")
            Path(state_path).write_text(json.dumps({"metadata": metadata, "pages": pages,
                                                    "runs": runs or [], "commits": commits or {},
                                                    "jobs": jobs or [], "logs": logs,
                                                    "exit": gh_exit}),
                                        encoding="utf-8")
            gh_path = os.path.join(directory, "gh")
            Path(gh_path).write_text("""#!/usr/bin/env python3
import json, os, sys
state_path = os.environ['FAKE_GH_STATE']
state = json.load(open(state_path, encoding='utf-8'))
if state['exit']:
    raise SystemExit(state['exit'])
endpoint = sys.argv[-1]
if '/actions/workflows/ci.yml/runs' in endpoint:
    print(json.dumps({'workflow_runs': state['runs']}))
elif '/git/commits/' in endpoint:
    print(json.dumps(state['commits'].get(endpoint.rsplit('/', 1)[-1], {})))
elif endpoint.endswith('/logs'):
    print(state['logs'])
elif '/jobs' in endpoint:
    print(json.dumps({'jobs': state['jobs']}))
elif '/files' in endpoint:
    print(json.dumps(state['pages']))
else:
    item = state['metadata'].pop(0)
    json.dump(state, open(state_path, 'w', encoding='utf-8'))
    print(json.dumps(item))
""", encoding="utf-8")
            os.chmod(gh_path, stat.S_IRWXU)
            git_path = os.path.join(directory, "git")
            Path(git_path).write_text("""#!/bin/sh
if printf '%s\\n' "$@" | grep -qx -- 'HEAD^{tree}'; then
  printf '%s\\n' "$FAKE_TREE"
elif printf '%s\\n' "$@" | grep -qx -- '--format=%P'; then
  printf '%s\\n' "$FAKE_PARENTS"
else
  printf '%s\\n' "$FAKE_CHECKOUT"
fi
""", encoding="utf-8")
            os.chmod(git_path, stat.S_IRWXU)
            body_path, files_path = (os.path.join(directory, name)
                                     for name in ("body.md", "files.txt"))
            environment = dict(os.environ, GITHUB_EVENT_PATH=event_path,
                               GITHUB_REPOSITORY="owner/repo", GITHUB_SHA="merge-sha",
                               FAKE_GH_STATE=state_path, FAKE_CHECKOUT=checkout,
                               FAKE_PARENTS=parents, FAKE_TREE=tree)
            result = subprocess.run([sys.executable, HELPER, "--gh", gh_path, "--git", git_path,
                                     "--body", body_path, "--files", files_path], env=environment,
                                    capture_output=True, text=True)
            body = Path(body_path).read_bytes() if os.path.exists(body_path) else None
            files = Path(files_path).read_bytes() if os.path.exists(files_path) else None
            return result, body, files

    def assert_refused(self, result, body, files, message):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)
        self.assertIsNone(body)
        self.assertIsNone(files)

    def test_writes_stable_snapshot_as_exact_utf8_body_and_line_protocol(self):
        snapshot = pr("한국어\n\nNo Logic facts.")
        result, body, files = self.run_helper([snapshot, snapshot],
                                              [[{"filename": "a"}], [{"filename": "b"}]])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(body, "한국어\n\nNo Logic facts.".encode())
        self.assertEqual(files, b"a\nb\n")

    def test_null_event_merge_sha_does_not_replace_checkout_identity(self):
        snapshot = pr()
        event = event_for(pr(merge=None))
        result, body, files = self.run_helper([snapshot, snapshot],
            [[{"filename": "a"}], [{"filename": "b"}]], event=event)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files, b"a\nb\n")

    def test_null_api_merge_sha_is_bound_by_actual_checkout_parents(self):
        snapshot = pr(merge=None)
        result, body, files = self.run_helper([snapshot, snapshot],
            [[{"filename": "a"}], [{"filename": "b"}]])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files, b"a\nb\n")

    def test_nonnull_api_merge_sha_must_match_actual_checkout(self):
        snapshot = pr(merge="other-merge")
        result, body, files = self.run_helper([snapshot, snapshot],
            [[{"filename": "a"}], [{"filename": "b"}]])
        self.assert_refused(result, body, files, "checkout")

    def test_regenerated_api_merge_requires_identical_parents_and_tree(self):
        snapshot = pr(merge="regenerated-merge")
        good = {"sha": "regenerated-merge", "parents": [{"sha": "base-sha", "url": "https://api.github.com/base"},
                                                      {"sha": "head-sha", "html_url": "https://github.com/head"}],
                "tree": {"sha": "tree-sha"}}
        cases = [(good, True), (dict(good, tree={"sha": "other-tree"}), False),
                 (dict(good, parents=[{"sha": "head-sha"}, {"sha": "base-sha"}]), False),
                 (dict(good, sha="other-merge"), False)]
        for commit, accepted in cases:
            with self.subTest(commit=commit):
                result, body, files = self.run_helper([snapshot, snapshot],
                    [[{"filename": "a"}], [{"filename": "b"}]],
                    commits={"regenerated-merge": commit})
                if accepted:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assert_refused(result, body, files, "checkout")

    def test_equivalent_merge_regeneration_during_pagination_is_not_source_drift(self):
        before, after = pr(), pr(merge="regenerated-merge")
        commit = {"sha": "regenerated-merge", "parents": [{"sha": "base-sha"}, {"sha": "head-sha"}],
                  "tree": {"sha": "tree-sha"}}
        result, body, files = self.run_helper([before, after],
            [[{"filename": "a"}], [{"filename": "b"}]], commits={"regenerated-merge": commit})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files, b"a\nb\n")

    def test_empty_fork_run_association_requires_actual_compile_checkout_binding(self):
        snapshot = pr()
        revision = "c" * 40
        run = {"id": 17, "run_attempt": 1, "event": "pull_request", "status": "completed",
               "conclusion": "success", "head_sha": "head-sha", "head_branch": "feature",
               "repository": {"full_name": "owner/repo"},
               "head_repository": {"full_name": "fork/repo"}, "pull_requests": []}
        job = {"id": 23, "name": "compile", "conclusion": "success", "run_id": 17, "run_attempt": 1}
        commit = {"sha": revision, "parents": [{"sha": "base-sha"}, {"sha": "head-sha"}],
                  "tree": {"sha": "tree-sha"}}
        logs = ("2026-10-25T17:04:03Z ##[group]Run actions/checkout@" + "a" * 40 + "\n"
                "2026-10-25T17:04:04Z ##[endgroup]\n"
                "2026-10-25T17:04:12Z [command]/opt/homebrew/bin/git checkout --progress --force refs/remotes/pull/42/merge\n"
                "2026-10-25T17:04:13Z [command]/opt/homebrew/bin/git log -1 --format=%H\n"
                "2026-10-25T17:04:14Z " + revision + "\n"
                "2026-10-25T17:04:15Z ##[group]Run swift build -c release\n")
        cases = [(run, job, commit, logs, True),
                 (dict(run, conclusion="failure"), job, commit, logs, False),
                 (dict(run, status="in_progress"), job, commit, logs, False),
                 (dict(run, run_attempt=True), job, commit, logs, False),
                 (dict(run, head_repository={"full_name": "other/repo"}), job, commit, logs, False),
                 (dict(run, head_branch="other"), job, commit, logs, False),
                 (run, dict(job, conclusion="failure"), commit, logs, False),
                 (run, dict(job, run_id=99), commit, logs, False),
                 (run, dict(job, run_attempt=2), commit, logs, False),
                 (run, job, dict(commit, sha="d" * 40), logs, False),
                 (run, job, dict(commit, tree={"sha": "other-tree"}), logs, False),
                 (run, job, dict(commit, parents=[{"sha": "other-base"}, {"sha": "head-sha"}]), logs, False),
                 (run, job, commit, logs.replace('/pull/42/', '/pull/99/'), False),
                 (run, job, commit, logs.replace(revision, "unreadable"), False),
                 (run, job, commit, "", False),
                 (run, job, commit, "2026-10-25T17:04:01Z ##[group]Run swift build\n" + logs, False)]
        for current_run, current_job, current_commit, current_logs, accepted in cases:
            with self.subTest(run=current_run, job=current_job, commit=current_commit, logs=current_logs):
                result, body, files = self.run_helper([snapshot, snapshot],
                    [[{"filename": "a"}], [{"filename": "b"}]], event=event_for(snapshot, "edited"),
                    runs=[current_run], jobs=[current_job], commits={revision: current_commit}, logs=current_logs)
                if accepted:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assert_refused(result, body, files, "code validation")

    def test_null_body_is_valid_empty_body(self):
        snapshot = pr(None)
        result, body, files = self.run_helper([snapshot, snapshot],
                                              [[{"filename": "a"}], [{"filename": "b"}]])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(body, b"")
        self.assertEqual(files, b"a\nb\n")

    def test_refuses_revision_drift_even_when_count_is_unchanged(self):
        before, after = pr(), pr(head="other-head", merge="other-merge")
        result, body, files = self.run_helper([before, after],
                                              [[{"filename": "a"}], [{"filename": "b"}]])
        self.assert_refused(result, body, files, "drift")

    def test_refuses_base_ref_change_even_when_base_sha_is_unchanged(self):
        before, after = pr(), pr(base_ref="release")
        result, body, files = self.run_helper([before, after],
                                              [[{"filename": "a"}], [{"filename": "b"}]])
        self.assert_refused(result, body, files, "drift")

    def test_refuses_incomplete_or_duplicate_file_pages(self):
        snapshot = pr()
        for pages, message in (([[{"filename": "a"}]], "incomplete"),
                               ([[{"filename": "a"}, {"filename": "a"}]], "duplicate")):
            with self.subTest(message=message):
                result, body, files = self.run_helper([snapshot, snapshot], pages)
                self.assert_refused(result, body, files, message)

    def test_refuses_newline_filename_that_could_hide_a_targeted_path(self):
        snapshot = pr(count=1)
        result, body, files = self.run_helper([snapshot, snapshot],
                                              [[{"filename": "safe\ndocs/canon/secret"}]])
        self.assert_refused(result, body, files, "filename")

    def test_includes_prior_filename_for_rename_citation_checks(self):
        snapshot = pr(count=1)
        result, body, files = self.run_helper([snapshot, snapshot],
                                              [[{"filename": "new.txt", "previous_filename": "old.txt"}]])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files, b"new.txt\nold.txt\n")

    def test_refuses_checkout_that_is_not_the_exact_merge_of_source_and_base(self):
        snapshot = pr()
        result, body, files = self.run_helper([snapshot, snapshot], [[{"filename": "a"}], [{"filename": "b"}]],
                                              parents="head-sha base-sha")
        self.assert_refused(result, body, files, "checkout")

    def test_refuses_malformed_or_error_api_responses_without_outputs(self):
        snapshot = pr()
        result, body, files = self.run_helper([snapshot, snapshot], [], gh_exit=1)
        self.assert_refused(result, body, files, "API lookup failed")
        result, body, files = self.run_helper([[], []], [], event=event_for(snapshot))
        self.assert_refused(result, body, files, "metadata is not an object")

    def test_edited_accepts_only_source_head_run_for_exact_pr_base_ref_and_repository(self):
        snapshot = pr()
        good = {"event": "pull_request", "status": "completed", "conclusion": "success",
                "head_sha": "head-sha", "repository": {"full_name": "owner/repo"},
                "pull_requests": [{"number": 42, "head": {"sha": "head-sha"},
                                   "base": {"sha": "base-sha", "ref": "main"}}]}
        stale = dict(good, head_sha="merge-sha")
        wrong_number = dict(good, pull_requests=[{"number": 99, "head": {"sha": "head-sha"},
                                                  "base": {"sha": "base-sha", "ref": "main"}}])
        wrong_base = dict(good, pull_requests=[{"number": 42, "head": {"sha": "head-sha"},
                                                "base": {"sha": "other-base", "ref": "main"}}])
        wrong_ref = dict(good, pull_requests=[{"number": 42, "head": {"sha": "head-sha"},
                                               "base": {"sha": "base-sha", "ref": "release"}}])
        wrong_repository = dict(good, repository={"full_name": "other/repo"})
        event = event_for(snapshot, "edited")
        for run, accepted in ((stale, False), (wrong_number, False), (wrong_base, False),
                              (wrong_ref, False), (wrong_repository, False), (good, True)):
            with self.subTest(run=run):
                result, body, files = self.run_helper([snapshot, snapshot],
                    [[{"filename": "a"}], [{"filename": "b"}]], event=event, runs=[run])
                if accepted:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assert_refused(result, body, files, "code validation")


if __name__ == "__main__":
    unittest.main()
