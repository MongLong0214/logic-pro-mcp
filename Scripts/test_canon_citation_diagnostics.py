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

    def test_a_declaration_in_any_code_block_is_the_same_diagnosis(self):
        """Every form GitHub renders as code, not only the closed backtick fence (review of #975)."""
        for body in hidden_forms(f"This change {NO_FACT}: packaging only."):
            with self.subTest(body):
                status, result = self.diagnose(body)
                self.assertEqual(status, 1)
                self.assertEqual([entry["code"] for entry in result["diagnostics"]],
                                 ["hidden_declaration"])

    def test_a_declaration_in_prose_beside_a_code_block_is_satisfied(self):
        """The control for the case above."""
        for body in visible_forms(f"that this change {NO_FACT}: packaging only"):
            with self.subTest(body):
                status, result = self.diagnose(body)
                self.assertEqual(status, 0)
                self.assertEqual(result["category"], "satisfied")

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


#: A reference that resolves in the committed index, with the value it resolves to. Both halves,
#: because a reference alone is a key anybody can type. Taken from `docs/canon/README.md`, which
#: is where a contributor is sent to copy it.
PINNED_REF = ("logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA"
              "%2FResources%2FLocalizable.strings/en/Trk#value")
PINNED_VALUE = "Trk"

#: The other citation shape, and the reason it is here: it resolves against `strings.values.tsv`
#: rather than `strings.tsv`, so it is the only way to reach the value branch of
#: `_require_readable_index`. A value citation is the reference AND the value, and the tree-wide
#: run holds this file to that rule too -- so the value it resolves to is written down here:
#: Count In
PINNED_VALUE_REF = "logic-canon://strings/en#value"
PINNED_VALUE_ONLY = "Count In"

#: A reference `find_refs` takes and `CanonRef.parse` refuses: three path segments where four are
#: required, and a field that is not `value`. Written in two pieces on purpose -- the tree-wide run
#: of this same checker scans every file in the repository for references and refuses the malformed
#: ones, so spelling it out here would fail this repository's own gate on this file.
MALFORMED_REF = "logic-canon:" + "//strings/a/b#title"


class WhoseFaultAnUnresolvedReferenceIs(unittest.TestCase):
    """The index being unreadable and the key being absent are two answers, not one.

    `load_index` returns an empty table for a MISSING index file, so `resolve_offline` reported
    every reference as "not in docs/canon/index/<source>.tsv" and `diagnose_text` filed that under
    `invalid_reference` -- a sentence addressed to the contributor about the citation they typed.
    On a checkout without the corpus built, every citation in every body became the author's fault,
    which is the exact confusion the structured diagnosis exists to remove.
    """

    def tree_with_index(self, mutate):
        """A repository root whose `docs/canon/index/` is whatever `mutate` leaves behind.

        Symlinked like `tree_without_the_manifest` above and for the same reason: `REPO` comes
        from `abspath(__file__)` without resolving symlinks, so the checker reads THIS tree's
        `docs/canon/` and the real `Scripts/`.
        """
        root = tempfile.mkdtemp(prefix="canon-index-")
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
            if entry != "index":
                os.symlink(os.path.join(REPO, "docs", "canon", entry),
                           os.path.join(root, "docs", "canon", entry))
        index = os.path.join(root, "docs", "canon", "index")
        os.makedirs(index)
        for entry in os.listdir(os.path.join(REPO, "docs", "canon", "index")):
            os.symlink(os.path.join(REPO, "docs", "canon", "index", entry),
                       os.path.join(index, entry))
        mutate(index)
        return root

    def cited_body(self):
        return BodyFixture(self, f"This rests on Logic's own data.\n\n{PINNED_REF}\n\n"
                                 f"{PINNED_VALUE}\n")

    def test_the_committed_index_resolves_the_reference(self):
        """The control. Everything below is "the same body, with the index broken", so without
        this the cases prove only that the checker dislikes something about the text."""
        fixture = self.cited_body()
        root = self.tree_with_index(lambda index: None)
        status, stdout, _ = run(["--text", fixture.body, "--format", "json"], root=root)
        self.assertEqual(status, 0, stdout)
        self.assertEqual(json.loads(stdout)["category"], "satisfied")

    def test_a_missing_index_is_this_repository_failing_not_the_author(self):
        fixture = self.cited_body()
        root = self.tree_with_index(lambda index: os.remove(os.path.join(index, "strings.tsv")))
        status, stdout, _ = run(["--text", fixture.body, "--format", "json"], root=root)
        result = json.loads(stdout)
        self.assertEqual(result["category"], "error", stdout)
        self.assertEqual(status, 2)
        self.assertEqual([entry["code"] for entry in result["diagnostics"]], ["checker_error"])
        self.assertIn("repository-side", result["diagnostics"][0]["message"])

    def test_a_malformed_index_row_is_the_same_failure(self):
        def wreck(index):
            path = os.path.join(index, "strings.tsv")
            os.remove(path)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("strings\ten\tTrk\n")  # three fields where five are required

        fixture = self.cited_body()
        status, stdout, _ = run(["--text", fixture.body, "--format", "json"],
                                root=self.tree_with_index(wreck))
        result = json.loads(stdout)
        self.assertEqual(result["category"], "error", stdout)
        self.assertEqual(status, 2)
        self.assertEqual([entry["code"] for entry in result["diagnostics"]], ["checker_error"])

    def value_cited_body(self):
        """A VALUE citation, which resolves against a DIFFERENT file: `<source>.values.tsv`.

        The reference above carries a key, so it takes the key branch of `_require_readable_index`
        and says nothing about the value branch. Both cases below need this shape.
        """
        return BodyFixture(self, f"This rests on Logic's own data.\n\n{PINNED_VALUE_REF}\n\n"
                                 f"{PINNED_VALUE_ONLY}\n")

    def test_a_value_citation_resolves_against_the_committed_value_index(self):
        """The value branch's control. Without it, the malformation case below cannot tell an
        unreadable index from a reference form the checker refuses for some other reason."""
        fixture = self.value_cited_body()
        root = self.tree_with_index(lambda index: None)
        status, stdout, _ = run(["--text", fixture.body, "--format", "json"], root=root)
        self.assertEqual(status, 0, stdout)
        self.assertEqual(json.loads(stdout)["category"], "satisfied")

    def test_a_malformed_VALUE_index_row_is_the_same_failure_too(self):
        """The value index is a second file asked a different question, and the round-3 review
        found only the key branch parsing what it found. Existence is not readability: a
        `.values.tsv` row with the wrong field count raised the base `CanonError` past
        `CanonIndexUnavailable`, so the two branches reached the same category by different routes
        and nothing here would have noticed if one of them stopped."""
        def wreck(index):
            path = os.path.join(index, "strings.values.tsv")
            os.remove(path)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("en\t9c434e85b363\tone-field-too-many\n")  # two fields are required

        fixture = self.value_cited_body()
        status, stdout, _ = run(["--text", fixture.body, "--format", "json"],
                                root=self.tree_with_index(wreck))
        result = json.loads(stdout)
        self.assertEqual(result["category"], "error", stdout)
        self.assertEqual(status, 2)
        self.assertEqual([entry["code"] for entry in result["diagnostics"]], ["checker_error"])
        self.assertIn("could not be read", result["diagnostics"][0]["message"])

    def test_a_key_the_intact_index_does_not_carry_is_still_the_author_to_fix(self):
        """The other side. Narrowing "unresolved" to a tooling failure would make an invented key
        a pass, and `invalid_reference` is the code the issue bot words for the contributor."""
        missing = PINNED_REF.replace("/en/Trk#value", "/en/NoSuchKeyAnywhere#value")
        fixture = BodyFixture(self, f"This rests on Logic's own data.\n\n{missing}\n\nTrk\n")
        status, stdout, _ = run(["--text", fixture.body, "--format", "json"])
        result = json.loads(stdout)
        self.assertEqual(result["category"], "actionable", stdout)
        self.assertEqual(status, 1)
        self.assertIn("invalid_reference", [entry["code"] for entry in result["diagnostics"]])

    def test_a_malformed_reference_string_is_the_author_without_reading_the_index(self):
        """A citation that does not parse is the author's whatever the corpus says, and this run
        must not need the index to tell them so."""
        fixture = BodyFixture(self, f"This rests on Logic's own data.\n\n{MALFORMED_REF}\n")
        status, stdout, _ = run(["--text", fixture.body, "--format", "json"])
        result = json.loads(stdout)
        self.assertEqual(result["category"], "actionable", stdout)
        self.assertIn("invalid_reference", [entry["code"] for entry in result["diagnostics"]])


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



#: A record on main that declares `canon_not_applicable`, and the one file its `depends` names.
BEHAVIOURAL_RECORD = ("docs/observations/2026-09-15-an-auxiliary-window-steals-the-track-menu-"
                      "and-that-is-the-sweep-only-failure.json")
BEHAVIOURAL_DEPENDS = "Sources/LogicProMCP/Channels/AccessibilityChannel+Tracks.swift"

#: A real schema-3 record that CITES instead. It is evidence about a label, not a behaviour.
CITING_RECORD = ("docs/observations/2026-09-14-a-korean-input-source-silently-breaks-every-key-"
                 "command-operation.json")

#: A string the pinned corpus holds, measured with `_citable_strings_in` on 2026-09-24.
CITABLE = "Metronome"


def hidden_forms(text):
    """Bodies in which GitHub renders `text` only as code or not at all.

    Each was rendered through GitHub's renderer (`gh api markdown`, mode gfm) on 2026-09-24, and
    so was each form in `visible_forms()`.
    """
    return (
        f"Evidence below.\n```\n{text}\n```\n",
        f"Evidence below.\n<!-- {text} -->\n",
        f"Evidence below.\n<!-- {text}\n",
        f"Evidence below.\n~~~\n{text}\n~~~\n",
        f"Evidence below.\n```\n{text}\n",
        f"Evidence below.\n````\n```\n{text}\n````\n",
        f"Evidence below.\n\n    {text}\n",
        f"Evidence below.\n\n\t{text}\n",
        f"## Evidence\n    {text}\n",
        f"Evidence below.\n> ~~~\n> {text}\n> ~~~\n",
        f"Evidence below.\n>     {text}\n",
        f"- evidence\n\n  ```\n  {text}\n  ```\n",
        f"- evidence\n    ```\n    {text}\n    ```\n",
        f"- evidence\n    ~~~\n    {text}\n    ~~~\n",
        f"Evidence below.\n```\n> ```\n{text}\n```\n",
        f"Evidence below.\n```\n    ```\n{text}\n```\n",
        # A fence opened on a list item's own line, which the first line parser missed and then
        # read the closer as an opener (review of #975, round 2).
        f"- ```\n  {text}\n  ```\n",
        f"- ~~~\n  {text}\n  ~~~\n",
        f"1. ```\n   {text}\n   ```\n",
        f"1. ~~~\n   {text}\n   ~~~\n",
        # Its closer on a line the list item does not reach: that line opens a new fence.
        f"- ```\n  example\n```\n{text}\n```\n",
        # Raw `<pre>`, closed, unclosed and inside a sentence (review of #975, round 2).
        f"Evidence below.\n<pre>{text}</pre>\n",
        f"Evidence below.\n\n<pre>\n{text}\n",
        f"Evidence: <pre>{text}</pre> here.\n",
        # A footnote nothing refers to, which GitHub drops.
        f"Evidence below.\n\n[^note]: {text}\n",
        # An HTML block holds a fence line, so the next fence line opens rather than closes.
        f"<div>\n```\n\n```\n{text}\n",
        # A line indented under a table is code, not a continuation.
        f"| a | b |\n|---|---|\n    {text}\n",
        # A comment an HTML block leaves open runs to the end of the page.
        f"<div>\n<!--\n</div>\n\n{text}\n",
        # A browser reads `<?` in raw HTML as a comment.
        f"<div>\n<?note {text} ?>\n</div>\n",
        # A tag alone on its line opens an HTML block where a quote's paragraph is not continued.
        f"> Evidence\n<span>\n```\n\n```\n{text}\n",
        # An HTML block interrupts a paragraph, and one whose end is on a later line ends there.
        f"Evidence below.\n<div>\n```\n\n```\n{text}\n",
        f"<!--\nnote\n-->\n```\n{text}\n```\n",
        # A list item that begins blank ends at the next blank line, and one whose marker is
        # followed by five spaces or more opens indented code.
        f"-\n\n    {text}\n",
        f"-     {text}\n",
        # A comment or a processing instruction inside a sentence.
        f"Evidence <!-- {text} --> below.\n",
        f"Evidence <?note {text} ?> below.\n",
        # A link definition at the start of a paragraph, as its target or its title, whether a link
        # uses it or not; its target or title may be on the next line and its label span two.
        f"[record]: <{text}>\n",
        f"Evidence below.\n\n[record]: /x \"{text}\"\n",
        f"[record]: /x\n'{text}'\n",
        f"[a]: /x\n[record]: /y ({text})\n",
        f"[the\nrecord]:\n<{text}>\n",
        f"> [record]: <{text}>  \n",
        f"- [record]: <{text}>\n",
        f"# Evidence\n[record]: <{text}>\n",
        f"[used]: <{text}>\n\nEvidence: [the record][used].\n",
        f"Evidence below.\n\n   [record]: <{text}>\n",
        f"[re\\]cord]: <{text}>\n",
        f'[record]: /x\u00a0y "{text}"\n',
        f'[record]: /x "a\\" {text}"\n',
        # A comment in a table row.
        f"| a |\n|---|\n| <!-- {text} --> |\n",
        # A table whose delimiter row starts with a dash, then code under it; and a delimiter row
        # indented four spaces, which is text, so what follows is not a table's row.
        f"Evidence: a | b\n---|---\n    {text}\n",
        f"Evidence:\n    ---\n<span>\n```\n{text}\n```\n",
        f"[record]: <{text}>\n    ---\n",
    )


def visible_forms(text):
    """Bodies in which GitHub renders `text` as prose, each next to a form above."""
    return (
        f"Evidence:\n```\nexample\n```\nThe record is {text}.\n",
        f"Evidence:\n~~~\nexample\n~~~\nThe record is {text}.\n",
        f"Evidence:\n<!-- note -->\nThe record is {text}.\n",
        f"The record is\n    {text}\nand it measures the menu.\n",
        f"- evidence\n    - the record is {text}\n",
        f"> The record is {text}.\n",
        f"```inline``` and the record is {text}.\n",
        # Hidden by the parser at 88b895f7, which did not follow a list item's or a quote's extent.
        f"- evidence\n\n    the record is {text}\n",
        f"- item\n  ```\n  code\nThe record is {text}.\n",
        f"> ```\n> code\nThe record is {text}.\n",
        f"- ```\n  example\n  ```\nThe record is {text}.\n",
        f"- ~~~\n  example\n  ~~~\nThe record is {text}.\n",
        f"<div>\n```\n</div>\n\nThe record is {text}.\n",
        f"| a | b |\n|---|---|\n\nThe record is {text}.\n",
        # A closed comment hides itself and nothing after it, inline and in an HTML block.
        f"Evidence <!-- note --> and the record is {text}.\n",
        f"<div>\n<!-- note -->\nThe record is {text}.\n</div>\n",
        # Neither an ordered item starting at 2 nor a table whose delimiter row counts other cells
        # interrupts a paragraph, and a line no quote marker opens continues the quoted paragraph.
        f"Evidence:\n2. ```\n   the record is {text}\n   ```\n",
        f"Evidence: a | b\n|---|\n    the record is {text}\n",
        f"> The record is\n    {text}\n",
        # An inline `<!--` nothing closes is text, and GitHub shows it.
        f"Evidence <!-- and the record is {text}.\n",
        # Not link definitions: a title with more text after it, a line after the definition, one
        # that would interrupt a paragraph, a space before the colon, a blank label, and any in a
        # table.
        f"[record]: /x \"t\" and the record is {text}.\n",
        f"[record]: /x\n\"t\" and the record is {text}.\n",
        f"[record]: /x\nThe record is {text}.\n",
        f"Evidence:\n[record]: the record is {text}\n",
        f"[record] : the record is {text}\n",
        f'[ ]: /x "the record is {text}"\n',
        f"[record]: /x \"{text}\"\n|---|\n",
        f"| a |\n|---|\n[record]: /x \"{text}\"\n",
        # Nor a label holding a bracket, a title not set apart from its target, a parenthesized
        # title holding a parenthesis, or an angle-bracketed target running over a line or
        # holding a `<`.
        f'[re[cord]: /x "the record is {text}"\n',
        f'[record]: x"t and the record is {text}"\n',
        f"[record]: /x (a(the record is {text})\n",
        f"[record]: <x\nthe record is {text}, see>\n",
        f'[record]: <x <y>\n"the record is {text}"\n',
        # A delimiter row indented four spaces, or one a list item starts, makes no table.
        f"Evidence: a | b\n    ---|---\n    the record is {text}\n",
        f"Evidence: a | b\n- | -\n    the record is {text}\n",
    )


class ABehaviouralRecordInPlaceOfACitation(unittest.TestCase):
    """A Logic-facing change whose evidence is behaviour may name the record that holds it.

    The label citation is not faked for this: a citation establishes what a label SAYS, and a
    change that rests on what an element DOES has no row to cite. The record category for that is
    rule 13's `canon_not_applicable`, and each case below pins one of the conditions under which a
    named record is allowed to stand in for the citation.
    """

    def diagnose(self, body, changed, root=REPO):
        fixture = BodyFixture(self, body, changed)
        status, stdout, _ = run(["--text", fixture.body, "--changed", fixture.changed,
                                 "--format", "json"], root=root)
        return status, json.loads(stdout)

    def assertRefused(self, status, result, because):
        self.assertEqual(status, 1)
        self.assertEqual(result["category"], "actionable")
        self.assertEqual(codes(json.dumps(result)), ["behavioural_record_refused"])
        self.assertIn(because, result["diagnostics"][0]["message"])
        self.assertEqual(result["records"], [])

    def test_a_record_this_change_writes_about_code_it_changes_satisfies_the_body(self):
        status, result = self.diagnose(
            f"The evidence is {BEHAVIOURAL_RECORD}, which measures what the menu does.\n",
            [BEHAVIOURAL_RECORD, BEHAVIOURAL_DEPENDS])
        self.assertEqual(status, 0)
        self.assertEqual(result["category"], "satisfied")
        self.assertEqual(result["diagnostics"], [])
        self.assertEqual(result["records"], [BEHAVIOURAL_RECORD])

    def test_inline_backticks_and_a_link_are_visible(self):
        for body in (f"Evidence: `{BEHAVIOURAL_RECORD}`.\n",
                     f"Evidence: [the record]({BEHAVIOURAL_RECORD}).\n"):
            with self.subTest(body):
                status, result = self.diagnose(body, [BEHAVIOURAL_RECORD, BEHAVIOURAL_DEPENDS])
                self.assertEqual(status, 0)
                self.assertEqual(result["records"], [BEHAVIOURAL_RECORD])

    def test_the_prose_rendering_names_the_record_and_not_the_opt_out(self):
        fixture = BodyFixture(self, f"Evidence: {BEHAVIOURAL_RECORD}.\n",
                              [BEHAVIOURAL_RECORD, BEHAVIOURAL_DEPENDS])
        status, stdout, _ = run(["--text", fixture.body, "--changed", fixture.changed])
        self.assertEqual(status, 0)
        self.assertIn("behavioural record", stdout)
        self.assertIn(BEHAVIOURAL_RECORD, stdout)
        self.assertNotIn(NO_FACT, stdout)

    def test_a_record_this_change_does_not_write_is_refused(self):
        status, result = self.diagnose(f"Evidence: {BEHAVIOURAL_RECORD}.\n",
                                       [BEHAVIOURAL_DEPENDS])
        self.assertRefused(status, result, "not in this change's file list")

    def test_a_record_about_code_this_change_does_not_touch_is_refused(self):
        status, result = self.diagnose(f"Evidence: {BEHAVIOURAL_RECORD}.\n",
                                       [BEHAVIOURAL_RECORD, LOGIC_FACING_SAMPLE])
        self.assertRefused(status, result, "none of its `depends`")

    def test_a_record_named_only_where_a_reader_does_not_see_it_is_not_named(self):
        for body in hidden_forms(BEHAVIOURAL_RECORD):
            with self.subTest(body):
                status, result = self.diagnose(body, [BEHAVIOURAL_RECORD, BEHAVIOURAL_DEPENDS])
                self.assertEqual(status, 1)
                self.assertEqual(codes(json.dumps(result)), ["logic_facing_opt_out"])

    def test_a_record_in_prose_around_those_forms_is_named(self):
        """The control. Without it the case above passes for a checker that reads nothing."""
        for body in visible_forms(BEHAVIOURAL_RECORD):
            with self.subTest(body):
                status, result = self.diagnose(body, [BEHAVIOURAL_RECORD, BEHAVIOURAL_DEPENDS])
                self.assertEqual(status, 0)
                self.assertEqual(result["records"], [BEHAVIOURAL_RECORD])

    def test_a_record_that_cites_instead_of_declaring_is_refused(self):
        status, result = self.diagnose(f"Evidence: {CITING_RECORD}.\n",
                                       [CITING_RECORD, BEHAVIOURAL_DEPENDS])
        self.assertRefused(status, result, "carries no `canon_not_applicable`")

    def test_a_record_that_does_not_exist_is_refused(self):
        missing = "docs/observations/2026-09-24-no-such-record.json"
        status, result = self.diagnose(f"Evidence: {missing}.\n",
                                       [missing, BEHAVIOURAL_DEPENDS])
        self.assertRefused(status, result, "no observation record exists")

    def test_a_body_quoting_a_string_logic_ships_is_refused(self):
        status, result = self.diagnose(
            f"Evidence: {BEHAVIOURAL_RECORD}. The `{CITABLE}` button moves.\n",
            [BEHAVIOURAL_RECORD, BEHAVIOURAL_DEPENDS])
        self.assertRefused(status, result, repr(CITABLE))

    def tree_with_record(self, name, record):
        """A root whose `docs/observations/` holds one more record, symlinked like the trees above.

        `REPO` comes from `abspath(__file__)` without resolving symlinks, so the checker reads this
        tree's observations and the real everything else.
        """
        root = tempfile.mkdtemp(prefix="canon-behavioural-")
        self.addCleanup(shutil.rmtree, root, True)
        for entry in os.listdir(REPO):
            if entry != "docs":
                os.symlink(os.path.join(REPO, entry), os.path.join(root, entry))
        os.makedirs(os.path.join(root, "docs", "observations"))
        for entry in os.listdir(os.path.join(REPO, "docs")):
            if entry != "observations":
                os.symlink(os.path.join(REPO, "docs", entry), os.path.join(root, "docs", entry))
        for entry in os.listdir(os.path.join(REPO, "docs", "observations")):
            os.symlink(os.path.join(REPO, "docs", "observations", entry),
                       os.path.join(root, "docs", "observations", entry))
        with open(os.path.join(root, "docs", "observations", name), "w",
                  encoding="utf-8") as handle:
            json.dump(record, handle)
        return root

    def fixture_record(self, reading, name="2026-09-24-fixture-behavioural-record.json"):
        """The real behavioural record with one reading added, under a new name.

        Built from a record the validator accepts, so a refusal below is the condition the case
        names. A hand-written record refused by the validator for a missing key would make every
        refusal pass and the control fail.
        """
        with open(os.path.join(REPO, BEHAVIOURAL_RECORD), encoding="utf-8") as handle:
            record = json.load(handle)
        record["id"] = name[: -len(".json")]
        record["date"] = name[:10]
        first, *rest = record["observations"]
        record["observations"] = [dict(first, reading=reading), *rest]
        return record

    def test_a_declaration_rule_13_refuses_is_refused(self):
        name = "2026-09-24-fixture-behavioural-record.json"
        rel = f"docs/observations/{name}"
        root = self.tree_with_record(name, self.fixture_record(CITABLE))
        status, result = self.diagnose(f"Evidence: {rel}.\n", [rel, BEHAVIOURAL_DEPENDS],
                                       root=root)
        self.assertRefused(status, result, "rule 13")

    def test_a_record_below_schema_3_is_refused(self):
        name = "2026-09-24-fixture-behavioural-record.json"
        rel = f"docs/observations/{name}"
        record = dict(self.fixture_record("the menu opened only after the window was closed"),
                      schema=2)
        root = self.tree_with_record(name, record)
        status, result = self.diagnose(f"Evidence: {rel}.\n", [rel, BEHAVIOURAL_DEPENDS],
                                       root=root)
        self.assertRefused(status, result, "schema 2")

    def test_a_record_that_depends_only_on_a_record_is_refused(self):
        """A record is not the code it is evidence for, even when this change writes both."""
        name = "2026-09-24-fixture-behavioural-record.json"
        rel = f"docs/observations/{name}"
        record = dict(self.fixture_record("the menu opened only after the window was closed"),
                      depends=[rel])
        root = self.tree_with_record(name, record)
        status, result = self.diagnose(f"Evidence: {rel}.\n", [rel, BEHAVIOURAL_DEPENDS],
                                       root=root)
        self.assertRefused(status, result, "none of its `depends`")

    def test_a_record_that_depends_only_on_a_document_is_refused(self):
        """A document is not code, even when this change writes it and edits code besides."""
        name = "2026-09-24-fixture-behavioural-record.json"
        rel = f"docs/observations/{name}"
        for document in ("docs/roadmap/README.md", LOGIC_FACING_SAMPLE):
            with self.subTest(document):
                record = dict(self.fixture_record("the menu opened only after the window was "
                                                  "closed"), depends=[document])
                root = self.tree_with_record(name, record)
                status, result = self.diagnose(f"Evidence: {rel}.\n",
                                               [rel, document, BEHAVIOURAL_DEPENDS], root=root)
                self.assertRefused(status, result, "none of its `depends`")

    def test_a_record_the_validator_refuses_is_refused(self):
        name = "2026-09-24-fixture-behavioural-record.json"
        rel = f"docs/observations/{name}"
        base = self.fixture_record("the menu opened only after the window was closed")
        for change, because in (({"schema": 4}, "schema is 4"),
                                ({"depends": [f"{BEHAVIOURAL_DEPENDS}:noSuchSymbolAnywhere"]},
                                 "noSuchSymbolAnywhere")):
            with self.subTest(change):
                root = self.tree_with_record(name, dict(base, **change))
                status, result = self.diagnose(f"Evidence: {rel}.\n", [rel, BEHAVIOURAL_DEPENDS],
                                               root=root)
                self.assertRefused(status, result, "check-observation-records.py refuses it")
                self.assertIn(because, result["diagnostics"][0]["message"])

    def test_the_same_fixture_without_the_citable_reading_is_satisfied(self):
        """The control. Without it the case above passes for any reason the fixture tree fails."""
        name = "2026-09-24-fixture-behavioural-record.json"
        rel = f"docs/observations/{name}"
        root = self.tree_with_record(
            name, self.fixture_record("the menu opened only after the window was closed"))
        status, result = self.diagnose(f"Evidence: {rel}.\n", [rel, BEHAVIOURAL_DEPENDS],
                                       root=root)
        self.assertEqual(status, 0)
        self.assertEqual(result["records"], [rel])


if __name__ == "__main__":
    unittest.main()
