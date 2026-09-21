#!/usr/bin/env python3
"""What `check-canon-citations.py --text` tells a caller, and how it reads its own flags.

Two things are under test and they fail for different reasons.

THE STRUCTURED RESULT. `canon-issue.yml` used to read this checker's stderr and turn whatever it
found into a sentence addressed to the author, so a corpus that would not load reached a
first-time contributor as an accusation that they had cited nothing. The repair is a computed
diagnosis with stable codes, rendered two ways. These cases pin the codes, the three categories,
and the rule that the two renderings never disagree about the outcome.

THE FLAGS. Before this the option parser was positional -- `--text` had to be argv[1], `--changed`
argv[3], and the whole `--changed` clause was skipped unless there were exactly five arguments.
`test_the_file_list_survives_a_flag_before_it` is the witness: with one more flag in the line the
old parser dropped the file list and let a change that edits Logic-facing paths opt out of citing
Logic. That is the defect, not the tidiness.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKER = os.path.join(REPO, "Scripts", "check-canon-citations.py")
NO_FACT = "states no fact about Logic"

#: Any path under one of these is a claim about Logic by its contents, so it may not opt out.
#: Read from the ledger rather than written here: a second copy of that list is a second authority.
LOGIC_FACING_SAMPLE = "docs/locale/ui-labels.json"


def run(args, root=REPO):
    """The checker's (exit status, stdout, stderr) for one command line.

    `root` is the repository the checker reads, and it is expressed as the PATH IT IS INVOKED BY,
    not as a working directory: this script derives its repository from `abspath(__file__)` and
    ignores the cwd entirely. A case that changed only the cwd would have run the real tree and
    passed for the wrong reason.
    """
    checker = os.path.join(root, "Scripts", "check-canon-citations.py")
    done = subprocess.run([sys.executable, checker] + args, cwd=root,
                          capture_output=True, text=True)
    return done.returncode, done.stdout, done.stderr


class BodyFixture:
    """A body on disk, and a changed-file list when the case needs one."""

    def __init__(self, case, body, changed=None):
        self.dir = tempfile.mkdtemp(prefix="canon-diag-")
        case.addCleanup(shutil.rmtree, self.dir, True)
        self.body = os.path.join(self.dir, "body.md")
        with open(self.body, "w", encoding="utf-8") as handle:
            handle.write(body)
        self.changed = None
        if changed is not None:
            self.changed = os.path.join(self.dir, "changed.txt")
            with open(self.changed, "w", encoding="utf-8") as handle:
                handle.write("".join(f"{line}\n" for line in changed))


def codes(stdout):
    """The diagnostic codes in a `--format json` result, in the order given."""
    return [entry["code"] for entry in json.loads(stdout)["diagnostics"]]


class WhatTheStructuredResultSays(unittest.TestCase):
    """One evaluation, rendered as JSON. The codes are the contract the issue bot reads."""

    def diagnose(self, body, changed=None):
        fixture = BodyFixture(self, body, changed)
        args = ["--text", fixture.body, "--format", "json"]
        if fixture.changed is not None:
            args += ["--changed", fixture.changed]
        status, stdout, _ = run(args)
        return status, json.loads(stdout)

    def test_a_visible_declaration_is_satisfied_and_names_no_diagnostic(self):
        status, result = self.diagnose(f"This change {NO_FACT} -- it only moves CI files.\n")
        self.assertEqual(status, 0)
        self.assertEqual(result["category"], "satisfied")
        self.assertEqual(result["diagnostics"], [])

    def test_a_body_with_neither_citation_nor_declaration(self):
        status, result = self.diagnose("Nothing here about anything.\n")
        self.assertEqual(status, 1)
        self.assertEqual(result["category"], "actionable")
        self.assertEqual([entry["code"] for entry in result["diagnostics"]],
                         ["missing_declaration"])

    def test_a_declaration_inside_a_fence_is_its_own_diagnosis(self):
        """The distinction the old single message could not make.

        A contributor who typed the sentence into a code fence did what the instruction said and
        got the rendering wrong. `missing_declaration` sends them to write a sentence they already
        wrote; this code sends them to move it. `_visible()` is deliberately NOT relaxed to accept
        the fenced form -- three earlier opt-out bypasses came out of exactly that relaxation.
        """
        status, result = self.diagnose(f"```\n{NO_FACT}\n```\nreason: packaging only\n")
        self.assertEqual(status, 1)
        self.assertEqual([entry["code"] for entry in result["diagnostics"]],
                         ["hidden_declaration"])

    def test_a_declaration_inside_an_html_comment_is_the_same_diagnosis(self):
        status, result = self.diagnose(f"<!-- {NO_FACT}: packaging only -->\n")
        self.assertEqual(status, 1)
        self.assertEqual([entry["code"] for entry in result["diagnostics"]],
                         ["hidden_declaration"])

    def test_a_logic_facing_change_may_not_declare_its_way_out(self):
        status, result = self.diagnose(f"This change {NO_FACT}.\n", [LOGIC_FACING_SAMPLE])
        self.assertEqual(status, 1)
        self.assertEqual([entry["code"] for entry in result["diagnostics"]],
                         ["logic_facing_opt_out"])

    def test_an_empty_file_list_fails_closed_rather_than_reopening_the_opt_out(self):
        status, result = self.diagnose(f"This change {NO_FACT}.\n", [])
        self.assertEqual(status, 1)
        self.assertEqual([entry["code"] for entry in result["diagnostics"]],
                         ["empty_changed_list"])

    def test_an_unreadable_body_is_an_error_not_a_verdict_about_the_author(self):
        status, stdout, _ = run(["--text", os.path.join(REPO, "no", "such.md"),
                                 "--format", "json"])
        result = json.loads(stdout)
        self.assertEqual(result["category"], "error")
        self.assertEqual([entry["code"] for entry in result["diagnostics"]],
                         ["input_unreadable"])
        self.assertEqual(status, 2)

    def test_the_error_status_is_still_nonzero(self):
        """An evaluation that did not happen is not a pass.

        The softening `error` buys is in the issue bot's WORDING. `pr-policy.yml` runs this as a
        required check, and a required check that could not read its corpus must not report green
        -- that is the shape of every silent pass this repository has removed.
        """
        status, _, _ = run(["--text", os.path.join(REPO, "no", "such.md")])
        self.assertNotEqual(status, 0)


class WhenTheCheckerItselfCannotAnswer(unittest.TestCase):
    """A corpus that will not load is a repository-side failure, reported as one."""

    def tree_without_the_manifest(self):
        """A repository root whose `docs/canon/MANIFEST.json` is absent and nothing else is.

        `REPO` is taken from `abspath(__file__)`, which does not resolve symlinks, so a root of
        symlinks is a root: the checker reads this tree's `docs/canon/` and the real Scripts.
        """
        root = tempfile.mkdtemp(prefix="canon-nomanifest-")
        self.addCleanup(shutil.rmtree, root, True)
        for entry in os.listdir(REPO):
            if entry != "docs":
                os.symlink(os.path.join(REPO, entry), os.path.join(root, entry))
        os.makedirs(os.path.join(root, "docs", "canon"))
        for entry in os.listdir(os.path.join(REPO, "docs")):
            if entry != "canon":
                os.symlink(os.path.join(REPO, "docs", entry),
                           os.path.join(root, "docs", entry))
        for entry in os.listdir(os.path.join(REPO, "docs", "canon")):
            if entry != "MANIFEST.json":
                os.symlink(os.path.join(REPO, "docs", "canon", entry),
                           os.path.join(root, "docs", "canon", entry))
        return root

    def test_a_corpus_that_will_not_load_is_an_error_and_blames_nobody(self):
        root = self.tree_without_the_manifest()
        fixture = BodyFixture(self, f"This change {NO_FACT} -- packaging only.\n")
        status, stdout, _ = run([], root=root)  # the tree-wide run agrees it is broken
        self.assertNotEqual(status, 0)
        status, stdout, _ = run(["--text", fixture.body, "--format", "json"],
                                root=root)
        result = json.loads(stdout)
        self.assertEqual(result["category"], "error")
        self.assertEqual([entry["code"] for entry in result["diagnostics"]], ["checker_error"])
        self.assertEqual(status, 2)
        # The sentence a contributor would see says whose failure it is.
        self.assertIn("repository-side", result["diagnostics"][0]["message"])

    def test_the_same_tree_answers_normally_with_its_manifest(self):
        """The control. Without it the case above passes for any reason the subprocess fails."""
        fixture = BodyFixture(self, f"This change {NO_FACT} -- packaging only.\n")
        status, stdout, _ = run(["--text", fixture.body, "--format", "json"])
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(stdout)["category"], "satisfied")


class HowItReadsItsOwnCommandLine(unittest.TestCase):
    """A flag that is dropped instead of refused is a check running in a weaker mode."""

    def test_the_file_list_survives_a_flag_before_it(self):
        """MEASURED against the previous revision of this file, which failed it.

        `--text <body> --format json --changed <list>` is seven arguments. The old parser asked
        for exactly five with `--changed` at index three, found neither, and ran with NO file
        list -- so the body's declaration was accepted although the change edits a Logic-facing
        path. Run against `git show HEAD~1:Scripts/check-canon-citations.py` it exits 0 here.
        """
        fixture = BodyFixture(self, f"This change {NO_FACT}.\n", [LOGIC_FACING_SAMPLE])
        status, stdout, _ = run(["--text", fixture.body,
                                 "--format", "json",
                                 "--changed", fixture.changed])
        self.assertEqual(codes(stdout), ["logic_facing_opt_out"])
        self.assertEqual(status, 1)

    def test_the_order_of_the_flags_does_not_change_the_answer(self):
        fixture = BodyFixture(self, f"This change {NO_FACT}.\n", [LOGIC_FACING_SAMPLE])
        first = run(["--text", fixture.body, "--changed", fixture.changed, "--format", "json"])
        second = run(["--format", "json", "--changed", fixture.changed, "--text", fixture.body])
        self.assertEqual(first[0], second[0])
        self.assertEqual(codes(first[1]), codes(second[1]))

    def test_an_unknown_flag_is_refused_and_nothing_is_evaluated(self):
        fixture = BodyFixture(self, f"This change {NO_FACT}.\n")
        status, stdout, stderr = run(["--text", fixture.body, "--bogus"])
        self.assertEqual(status, 2)
        self.assertEqual(stdout, "")
        self.assertIn("--bogus", stderr)

    def test_a_flag_with_no_value_is_refused(self):
        fixture = BodyFixture(self, f"This change {NO_FACT}.\n")
        status, _, stderr = run(["--text", fixture.body, "--changed"])
        self.assertEqual(status, 2)
        self.assertIn("needs a value", stderr)

    def test_an_unknown_format_is_refused(self):
        fixture = BodyFixture(self, f"This change {NO_FACT}.\n")
        status, _, stderr = run(["--text", fixture.body, "--format", "yaml"])
        self.assertEqual(status, 2)
        self.assertIn("text or json", stderr)

    def test_a_stray_positional_argument_is_refused(self):
        """The shape that used to mean something: `--text` once took its file by position."""
        fixture = BodyFixture(self, f"This change {NO_FACT}.\n")
        status, _, stderr = run([fixture.body])
        self.assertEqual(status, 2)
        self.assertIn("unexpected argument", stderr)


class TheTwoRenderingsAgree(unittest.TestCase):
    """Same evaluation, two ways of printing it. A divergence here is a second authority."""

    CASES = [
        ("declared", f"This change {NO_FACT}.\n", None),
        ("nothing", "Nothing here.\n", None),
        ("fenced", f"```\n{NO_FACT}\n```\n", None),
        ("logic facing", f"This change {NO_FACT}.\n", [LOGIC_FACING_SAMPLE]),
        ("empty list", f"This change {NO_FACT}.\n", []),
    ]

    def test_the_status_is_the_same_in_both_renderings(self):
        for name, body, changed in self.CASES:
            with self.subTest(name):
                fixture = BodyFixture(self, body, changed)
                args = ["--text", fixture.body]
                if fixture.changed is not None:
                    args += ["--changed", fixture.changed]
                prose = run(args)
                structured = run(args + ["--format", "json"])
                self.assertEqual(prose[0], structured[0])

    def test_prose_stays_on_stderr_and_json_stays_on_stdout(self):
        """The issue bot parses stdout. A diagnostic leaking there would be read as the result."""
        fixture = BodyFixture(self, "Nothing here.\n")
        _, stdout, stderr = run(["--text", fixture.body, "--format", "json"])
        json.loads(stdout)
        self.assertEqual(stderr, "")

    def test_the_tree_wide_run_has_no_json_rendering_and_says_so(self):
        """Rather than accepting the flag and printing prose, which reads as an empty result."""
        status, stdout, stderr = run(["--format", "json"])
        self.assertEqual(status, 2)
        self.assertEqual(stdout, "")
        self.assertIn("--format applies to --text", stderr)


if __name__ == "__main__":
    unittest.main()
