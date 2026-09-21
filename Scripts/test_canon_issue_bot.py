#!/usr/bin/env python3
"""What the advisory issue bot writes, when it writes nothing, and whose comment it may edit.

The predecessor was a shell block, and a shell block has no seam: the only way to find out what
it said to a contributor was for it to say it to them. Every case here is about something that
reached somebody, or could have:

  * A corpus that would not load arrived as an accusation that the author had cited nothing.
  * Each edit took the create-comment path, so a conversation collected warnings.
  * A body that was repaired kept an old warning standing under it.

`FakeGitHub` stands in for the API. It is not a mock of what this script does -- it records the
calls and answers from a list of comments -- so a case that expects no write fails if a write
happens, which is the property most of these are about.
"""

import importlib.util
import json
import os
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load():
    path = os.path.join(REPO, "Scripts", "canon_issue_bot.py")
    spec = importlib.util.spec_from_file_location("canon_issue_bot_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bot = _load()

BOT_LOGIN = "github-actions[bot]"
NO_FACT = "states no fact about Logic"


def comment(cid, body, login=BOT_LOGIN, kind="Bot"):
    return {"id": cid, "body": body, "user": {"login": login, "type": kind}}


def managed(cid, state, text="Canon guidance: something."):
    return comment(cid, "\n".join([bot.MARKER, f"<!-- logic-pro-mcp:canon-guidance-state:{state}"
                                               f" -->", "", text]))


class WhoseCommentIsIt(unittest.TestCase):
    """A marker is a string anybody can paste. Ownership needs the identity as well."""

    def test_our_own_marked_comment_is_ours(self):
        self.assertTrue(bot.owned(managed(1, bot.ACTIONABLE), BOT_LOGIN))

    def test_a_contributor_who_pastes_the_marker_keeps_their_comment(self):
        """The case the marker alone gets wrong.

        Someone quoting a bot note in their own reply -- which is ordinary -- would otherwise hand
        this workflow permission to overwrite what they wrote.
        """
        theirs = comment(2, managed(1, bot.ACTIONABLE)["body"], login="a-contributor",
                         kind="User")
        self.assertFalse(bot.owned(theirs, BOT_LOGIN))

    def test_another_bot_with_the_same_marker_is_not_ours(self):
        self.assertFalse(bot.owned(comment(3, managed(1, bot.ACTIONABLE)["body"],
                                           login="other-app[bot]"), BOT_LOGIN))

    def test_our_account_writing_an_ordinary_comment_is_not_a_managed_note(self):
        self.assertFalse(bot.owned(comment(4, "Thanks for the report."), BOT_LOGIN))

    def test_the_marker_without_a_state_is_not_a_managed_note(self):
        """Half a marker is an unknown shape, and an unknown shape is not adopted."""
        self.assertFalse(bot.owned(comment(5, bot.MARKER + "\n\nhello"), BOT_LOGIN))


class WhichNoteIsActive(unittest.TestCase):
    """One active note per issue, chosen the same way by two runs that race."""

    def test_no_owned_comments_means_no_note(self):
        note, extra = bot.active_note([comment(1, "hi", login="someone", kind="User")], BOT_LOGIN)
        self.assertIsNone(note)
        self.assertEqual(extra, [])

    def test_the_lowest_id_wins_and_the_rest_are_named(self):
        notes = [managed(9, bot.ACTIONABLE), managed(3, bot.ACTIONABLE)]
        note, extra = bot.active_note(notes, BOT_LOGIN)
        self.assertEqual(note["id"], 3)
        self.assertEqual([c["id"] for c in extra], [9])

    def test_a_superseded_note_is_not_a_candidate(self):
        """Otherwise marking the losers would be a write this bot repeats on every run."""
        note, extra = bot.active_note([managed(3, bot.SUPERSEDED), managed(9, bot.RESOLVED)],
                                      BOT_LOGIN)
        self.assertEqual(note["id"], 9)
        self.assertEqual(extra, [])

    def test_an_unowned_comment_is_never_a_candidate(self):
        note, _ = bot.active_note([comment(1, managed(1, bot.ACTIONABLE)["body"],
                                           login="someone", kind="User")], BOT_LOGIN)
        self.assertIsNone(note)


class WhatItDecidesToDo(unittest.TestCase):
    """#951's state table, case by case. Each row is a separate thing that can go wrong."""

    def act(self, category, note, findings=None):
        rendered = bot.render(category, findings or [])
        return bot.decide(category, rendered, note)[0], rendered

    def test_satisfied_with_no_note_says_nothing_at_all(self):
        self.assertEqual(self.act("satisfied", None)[0], "none")

    def test_an_actionable_result_with_no_note_creates_one(self):
        action, _ = self.act("actionable", None, [("missing_declaration", "x")])
        self.assertEqual(action, "create")

    def test_the_same_actionable_result_writes_nothing(self):
        """The defect that filled conversations. Identical input must render identically."""
        findings = [("missing_declaration", "x")]
        rendered = bot.render("actionable", findings)
        note = comment(1, rendered)
        self.assertEqual(bot.decide("actionable", rendered, note)[0], "none")

    def test_a_different_actionable_result_edits_the_same_note(self):
        note = comment(1, bot.render("actionable", [("missing_declaration", "x")]))
        action, _ = self.act("actionable", note, [("hidden_declaration", "y")])
        self.assertEqual(action, "edit")

    def test_a_repaired_body_edits_the_note_to_resolved(self):
        note = comment(1, bot.render("actionable", [("missing_declaration", "x")]))
        action, rendered = self.act("satisfied", note)
        self.assertEqual(action, "edit")
        self.assertEqual(bot.state_of(rendered), bot.RESOLVED)

    def test_a_regression_reuses_the_resolved_note(self):
        note = comment(1, bot.render("satisfied", []))
        action, rendered = self.act("actionable", note, [("missing_declaration", "x")])
        self.assertEqual(action, "edit")
        self.assertEqual(bot.state_of(rendered), bot.ACTIONABLE)

    def test_a_tooling_failure_with_no_note_stays_silent(self):
        """The one that mattered most: the bot's own failure is not an accusation."""
        action, _ = self.act("error", None, [("checker_error", "corpus unavailable")])
        self.assertEqual(action, "none")

    def test_a_tooling_failure_moves_an_existing_note_to_unknown_not_resolved(self):
        note = comment(1, bot.render("actionable", [("missing_declaration", "x")]))
        action, rendered = self.act("error", note, [("checker_error", "corpus unavailable")])
        self.assertEqual(action, "edit")
        self.assertEqual(bot.state_of(rendered), bot.UNKNOWN)
        self.assertNotEqual(bot.state_of(rendered), bot.RESOLVED)


class WhatTheNoteSays(unittest.TestCase):
    """Wording is the subject of workstream C, so it is asserted rather than left to review."""

    def test_a_tooling_failure_says_it_is_this_repository_s_problem(self):
        text = bot.render("error", [("checker_error", "boom")])
        self.assertIn("could not evaluate", text)
        for accusation in ("without citing", "you did not", "unsupported claim"):
            self.assertNotIn(accusation, text)

    def test_a_missing_declaration_does_not_assert_what_the_issue_claims(self):
        text = bot.render("actionable", [("missing_declaration", "x")])
        self.assertIn("does not yet carry a usable citation", text)
        self.assertIn("nothing is blocked", text.lower())
        self.assertNotIn("states something about Logic without", text)

    def test_a_hidden_declaration_names_the_fence(self):
        text = bot.render("actionable", [("hidden_declaration", "x")])
        self.assertIn("code block or an HTML comment", text)

    def test_the_resolved_note_claims_nothing_about_the_product(self):
        """A resolved evidence-format note is not a statement that anything works."""
        text = bot.render("satisfied", [])
        self.assertIn("evidence-format note is resolved", text)
        for overclaim in ("verified", "confirmed", "fixed", "reproduced and"):
            self.assertNotIn(overclaim, text)

    def test_one_documentation_link_and_no_more(self):
        text = bot.render("actionable", [("missing_declaration", "x")])
        self.assertEqual(text.count("https://"), 1)

    def test_the_documentation_link_resolves(self):
        """A link into a heading that was renamed is a contributor sent to the top of a file.

        The slug is derived the way GitHub derives it -- lower case, apostrophes dropped, spaces
        to hyphens -- from the headings actually in the file, so a rename fails here.
        """
        with open(os.path.join(REPO, bot.DOC_PATH), encoding="utf-8") as handle:
            headings = [line.lstrip("# ").strip() for line in handle
                        if line.startswith("#")]
        slugs = {"#" + "".join(c for c in text.lower().replace(" ", "-")
                               if c.isalnum() or c == "-")
                 for text in headings}
        self.assertIn(bot.DOC_ANCHOR, slugs)

    def test_the_detail_is_collapsed_rather_than_pasted_into_the_conversation(self):
        text = bot.render("actionable", [("missing_declaration", "x" * 50)])
        self.assertIn("<details><summary>", text)

    def test_at_most_five_diagnostics_are_rendered(self):
        findings = [("invalid_reference", f"problem {n}") for n in range(12)]
        text = bot.render("actionable", findings)
        self.assertEqual(text.count("problem "), 5)


class WhatItRefusesToRepeat(unittest.TestCase):
    """The body is attacker-controlled and a comment is a rendering surface."""

    def test_a_handle_copied_out_of_the_body_cannot_notify_anybody(self):
        text = bot.render("actionable", [("invalid_reference", "saw @someone/@some-org here")])
        self.assertNotIn("@someone", text)
        self.assertIn("＠someone", text)

    def test_a_backtick_cannot_close_the_fence_it_is_rendered_in(self):
        text = bot.render("actionable", [("invalid_reference", "```\nnot the end\n```")])
        self.assertEqual(text.count("```"), 2, "the fence this bot opened and closed, and no more")

    def test_a_long_diagnostic_is_bounded(self):
        text = bot.render("actionable", [("invalid_reference", "z" * 5000)])
        self.assertIn("[...]", text)
        self.assertLess(len(text), 2000)

    def test_the_runner_s_temporary_path_does_not_appear(self):
        text = bot.render("actionable",
                          [("missing_declaration", "/tmp/canon-issue-abc/issue-body.md: no "
                                                   "canonical reference")],
                          body_label="/tmp/canon-issue-abc/issue-body.md")
        self.assertNotIn("/tmp/canon-issue-abc", text)
        self.assertIn("issue body: no canonical reference", text)


class FakeGitHub:
    """Records every write. A case that expects silence fails if anything is written."""

    def __init__(self, body, comments, bodies_in_order=None):
        self.bodies = list(bodies_in_order or [body, body])
        self.stored = list(comments)
        self.created = []
        self.updated = []
        self.pages_read = 0
        self.fail_update_ids = set()

    def issue_body(self, number):
        return self.bodies.pop(0) if self.bodies else ""

    def comments(self, number):
        self.pages_read += 1
        return list(self.stored)

    def create_comment(self, number, body):
        self.created.append(body)
        return {"id": 999, "body": body}

    def update_comment(self, comment_id, body):
        if comment_id in self.fail_update_ids:
            self.fail_update_ids.discard(comment_id)
            raise RuntimeError("gh api failed: 404")
        self.updated.append((comment_id, body))
        return {"id": comment_id, "body": body}


class EndToEndThroughTheRealChecker(unittest.TestCase):
    """`main()` with the API replaced and the actual Canon checker running underneath."""

    def setUp(self):
        self.env = dict(os.environ)
        os.environ["GITHUB_REPOSITORY"] = "MongLong0214/logic-pro-mcp"
        os.environ["ISSUE_NUMBER"] = "1"
        os.environ["CANON_BOT_LOGIN"] = BOT_LOGIN
        self.made = []
        self.addCleanup(self.restore)
        self.original = bot.GitHub

    def restore(self):
        bot.GitHub = self.original
        os.environ.clear()
        os.environ.update(self.env)

    def drive(self, body, comments=(), bodies_in_order=None):
        fake = FakeGitHub(body, comments, bodies_in_order)
        bot.GitHub = lambda repo: fake
        status = bot.main()
        return status, fake

    def test_a_declared_body_with_no_note_writes_nothing(self):
        status, fake = self.drive(f"This issue {NO_FACT} -- it is a packaging request.\n")
        self.assertEqual(status, 0)
        self.assertEqual(fake.created, [])
        self.assertEqual(fake.updated, [])

    def test_a_body_with_no_evidence_gets_exactly_one_note(self):
        status, fake = self.drive("Something is wrong with the mixer.\n")
        self.assertEqual(status, 0)
        self.assertEqual(len(fake.created), 1)
        self.assertIn(bot.MARKER, fake.created[0])
        self.assertEqual(bot.state_of(fake.created[0]), bot.ACTIONABLE)

    def test_the_second_identical_run_writes_nothing(self):
        """Run it, feed its own output back, and it must be quiet. This is the duplicate defect."""
        _, first = self.drive("Something is wrong with the mixer.\n")
        _, second = self.drive("Something is wrong with the mixer.\n",
                               [comment(7, first.created[0])])
        self.assertEqual(second.created, [])
        self.assertEqual(second.updated, [])

    def test_a_repaired_body_resolves_the_note_it_left_standing(self):
        _, first = self.drive("Something is wrong with the mixer.\n")
        _, second = self.drive(f"This issue {NO_FACT} -- packaging only.\n",
                               [comment(7, first.created[0])])
        self.assertEqual(second.created, [])
        self.assertEqual([cid for cid, _ in second.updated], [7])
        self.assertEqual(bot.state_of(second.updated[0][1]), bot.RESOLVED)

    def test_a_body_edited_while_the_check_ran_is_left_to_its_own_run(self):
        """Publishing here would put an old warning over a body somebody already repaired."""
        status, fake = self.drive(
            "Something is wrong with the mixer.\n", [],
            bodies_in_order=["Something is wrong with the mixer.\n",
                             f"This issue {NO_FACT} -- packaging only.\n"])
        self.assertEqual(status, 0)
        self.assertEqual(fake.created, [])
        self.assertEqual(fake.updated, [])

    def test_a_contributor_s_copy_of_the_marker_is_not_edited(self):
        theirs = comment(5, f"I saw this note:\n\n{bot.MARKER}\n"
                            f"<!-- logic-pro-mcp:canon-guidance-state:actionable -->\n",
                         login="a-contributor", kind="User")
        _, fake = self.drive("Something is wrong with the mixer.\n", [theirs])
        self.assertEqual(fake.updated, [])
        self.assertEqual(len(fake.created), 1)

    def test_a_race_leaves_one_active_note_and_marks_the_loser_once(self):
        first = bot.render("actionable", [("missing_declaration", "a")])
        second = bot.render("actionable", [("missing_declaration", "b")])
        _, fake = self.drive("Something is wrong with the mixer.\n",
                             [comment(4, first), comment(8, second)])
        self.assertEqual(fake.created, [])
        edited = dict(fake.updated)
        self.assertEqual(bot.state_of(edited[8]), bot.SUPERSEDED)
        self.assertIn(4, edited)

    def test_a_failed_edit_is_retried_once_and_never_becomes_a_new_comment(self):
        stale = comment(7, bot.render("actionable", [("missing_declaration", "a")]))
        fake = FakeGitHub("Something is wrong with the mixer.\n", [stale])
        fake.fail_update_ids = {7}
        bot.GitHub = lambda repo: fake
        status = bot.main()
        self.assertEqual(status, 0)
        self.assertEqual(fake.created, [], "a failed edit must not append another note")
        self.assertEqual([cid for cid, _ in fake.updated], [7])

    def test_a_broken_checker_writes_no_accusation(self):
        """The whole reason this rewrite exists, driven through `main()`."""
        original = bot.evaluate
        bot.evaluate = lambda body: {"category": "error", "label": "",
                                     "diagnostics": [{"code": "checker_error",
                                                      "message": "corpus unavailable"}]}
        self.addCleanup(lambda: setattr(bot, "evaluate", original))
        status, fake = self.drive("Something is wrong with the mixer.\n")
        self.assertEqual(status, 0)
        self.assertEqual(fake.created, [])
        self.assertEqual(fake.updated, [])

    def test_a_checker_that_prints_nonsense_is_an_error_not_a_pass(self):
        """Malformed output, an unknown category and a crash are all "did not finish"."""
        for stdout in ("", "not json", json.dumps({"category": "fine", "diagnostics": []})):
            with self.subTest(stdout[:12]):
                original = bot.subprocess.run

                def fake_run(*args, **kwargs):
                    class Done:
                        returncode = 0
                    Done.stdout, Done.stderr = stdout, ""
                    return Done
                bot.subprocess.run = fake_run
                try:
                    result = bot.evaluate("anything")
                finally:
                    bot.subprocess.run = original
                self.assertEqual(result["category"], "error")
                self.assertEqual(result["diagnostics"][0]["code"], "checker_error")


class TheWorkflowStillWiresItUp(unittest.TestCase):
    """A script nothing runs is a script that cannot be wrong in production."""

    WORKFLOW = os.path.join(REPO, ".github", "workflows", "canon-issue.yml")

    def workflow(self):
        with open(self.WORKFLOW, encoding="utf-8") as handle:
            return handle.read()

    def executable(self):
        """The workflow without its comments.

        The absence cases below are about what this file DOES. Its header explains what it stopped
        doing, in the words it stopped doing it in, and a case that read those words would refuse
        the explanation along with the behaviour.
        """
        return "\n".join(line for line in self.workflow().splitlines()
                         if not line.lstrip().startswith("#"))

    def test_the_workflow_runs_this_script(self):
        self.assertIn("python3 Scripts/canon_issue_bot.py", self.executable())

    def test_it_no_longer_pastes_the_checker_output_itself(self):
        self.assertNotIn("gh issue comment", self.executable())

    def test_the_bot_identity_is_supplied_and_is_not_the_actor(self):
        runnable = self.executable()
        self.assertIn("CANON_BOT_LOGIN", runnable)
        self.assertNotIn("github.actor", runnable)

    def test_it_still_reacts_to_an_edited_body(self):
        self.assertRegex(self.executable(), r"(?m)^\s*types:\s*\[[^\]]*\bedited\b")


if __name__ == "__main__":
    unittest.main()
