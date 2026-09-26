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

import contextlib
import importlib.util
import io
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

#: One body the checker calls actionable and one it calls satisfied, so a case can move an issue
#: from the first to the second mid-run and see whether the verdict followed.
UNCITED = "Something is wrong with the mixer.\n"
REPAIRED = f"This issue {NO_FACT} -- packaging only.\n"


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
        self.bodies = list(bodies_in_order or [body])
        self.stored = list(comments)
        self.created = []
        self.updated = []
        self.pages_read = 0
        self.body_reads = 0
        self.fail_update_ids = set()

    def issue_body(self, number):
        """Each read takes the next body, and the LAST one stands for every read after it.

        It used to pop unconditionally from a two-element default, so a third read answered "".
        `main()` asks again before each write now -- that is what the freshness cases are about --
        and an empty string would have made every one of them look like an edited body. A case
        that wants a change supplies the sequence up to it and stops.
        """
        self.body_reads += 1
        if len(self.bodies) > 1:
            return self.bodies.pop(0)
        return self.bodies[0] if self.bodies else ""

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



#: The note the pre-#959 workflow posted on #944 (comment 5750564523), byte for byte. Written out
#: rather than built from the module's constants, so a constant that drifts from what GitHub
#: actually holds fails here instead of agreeing with itself.
LEGACY_944 = (
    "This issue states something about Logic without citing Logic's own data, or\n"
    "cites it in a form that does not resolve. See `docs/canon/README.md`.\n"
    "\n"
    "```\n"
    "/tmp/issue.md: no canonical reference, and no opt-out.\n"
    "  Cite what this rests on, or write the sentence 'states no fact about Logic' with the\n"
    "  reason -- outside any code block or HTML comment. See docs/canon/README.md.\n"
    "```\n"
    "\n"
    "Nothing is blocked -- an issue has no merge to stop. This is a note for whoever\n"
    "triages it.\n")


class ThePreviousWorkflowsNotes(unittest.TestCase):
    """#951: an old unmarked note is adopted only from the bot's account and in its exact format.

    Before this, `owned()` needed a marker the old workflow never wrote, so on #944 a repaired
    body left the old warning standing, and a failing edit added a managed note beside it.
    """

    setUp = EndToEndThroughTheRealChecker.setUp
    restore = EndToEndThroughTheRealChecker.restore
    drive = EndToEndThroughTheRealChecker.drive

    def test_the_real_944_note_is_recognised(self):
        self.assertTrue(bot.legacy(comment(1, LEGACY_944), BOT_LOGIN))
        self.assertFalse(bot.owned(comment(1, LEGACY_944), BOT_LOGIN))

    def test_a_contributor_quoting_it_keeps_their_comment(self):
        theirs = comment(1, LEGACY_944, login="a-contributor", kind="User")
        self.assertFalse(bot.legacy(theirs, BOT_LOGIN))
        _, fake = self.drive(REPAIRED, [theirs])
        self.assertEqual((fake.created, fake.updated), ([], []))
        _, fake = self.drive(UNCITED, [theirs])
        self.assertEqual(fake.updated, [])
        self.assertEqual(len(fake.created), 1)

    def test_another_shape_from_our_account_is_not_adopted(self):
        for body in (LEGACY_944.rstrip("\n"), LEGACY_944.replace("triages it.", "reads it."),
                     "Note: " + LEGACY_944, LEGACY_944 + "\nmore"):
            with self.subTest(body[-20:]):
                self.assertFalse(bot.legacy(comment(1, body), BOT_LOGIN))

    def test_a_repaired_body_resolves_the_old_note_instead_of_leaving_it(self):
        _, fake = self.drive(REPAIRED, [comment(7, LEGACY_944)])
        self.assertEqual(fake.created, [])
        self.assertEqual([cid for cid, _ in fake.updated], [7])
        self.assertEqual(bot.state_of(fake.updated[0][1]), bot.RESOLVED)

    def test_a_failing_body_reuses_the_old_note_and_the_next_run_is_quiet(self):
        _, first = self.drive(UNCITED, [comment(7, LEGACY_944)])
        self.assertEqual(first.created, [], "a second note beside the old one")
        self.assertEqual([cid for cid, _ in first.updated], [7])
        self.assertEqual(bot.state_of(first.updated[0][1]), bot.ACTIONABLE)
        _, second = self.drive(UNCITED, [comment(7, first.updated[0][1])])
        self.assertEqual((second.created, second.updated), ([], []))

    def test_a_tooling_failure_marks_the_old_note_unknown_not_resolved(self):
        rendered = bot.render("error", [])
        action, _ = bot.decide("error", rendered, comment(7, LEGACY_944))
        self.assertEqual(action, "edit")
        self.assertEqual(bot.state_of(rendered), bot.UNKNOWN)

    def test_two_old_notes_keep_the_oldest_and_supersede_the_other_once(self):
        _, fake = self.drive(REPAIRED, [comment(9, LEGACY_944), comment(4, LEGACY_944)])
        self.assertEqual(fake.created, [])
        edited = dict(fake.updated)
        self.assertEqual(bot.state_of(edited[4]), bot.RESOLVED)
        self.assertEqual(bot.state_of(edited[9]), bot.SUPERSEDED)
        _, again = self.drive(REPAIRED, [comment(4, edited[4]), comment(9, edited[9])])
        self.assertEqual((again.created, again.updated), ([], []))

    def test_a_managed_note_outranks_an_older_old_note(self):
        """#291 and #308 carry both: the managed note is the current one, whatever its id."""
        current = bot.render("actionable", [("missing_declaration", "a")])
        note, extra = bot.active_note([comment(3, LEGACY_944), comment(8, current)], BOT_LOGIN)
        self.assertEqual(note["id"], 8)
        self.assertEqual([c["id"] for c in extra], [3])


class Done:
    """One finished subprocess, as `evaluate` reads it: a status and two streams."""

    def __init__(self, returncode, stdout, stderr=""):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


class WhatCountsAsTheCheckerHavingAnswered(unittest.TestCase):
    """`evaluate` read `done.stdout` and never `done.returncode`.

    A status is what a killed or wedged process cannot fake; a category is what the note is worded
    from. Reading only the second meant a checker that died on a signal after printing `satisfied`
    was a pass, and driving `main()` that way RESOLVED a standing warning -- an evaluation that did
    not happen withdrawing one that did. `[]` as the whole result crashed on `.get`.
    """

    def run_with(self, done):
        original = bot.subprocess.run
        bot.subprocess.run = lambda *a, **k: done
        try:
            return bot.evaluate("anything")
        finally:
            bot.subprocess.run = original

    def test_the_status_and_the_category_have_to_agree(self):
        satisfied = json.dumps({"category": "satisfied", "diagnostics": []})
        self.assertEqual(self.run_with(Done(0, satisfied))["category"], "satisfied")
        for status in (1, 2):
            with self.subTest(status=status):
                result = self.run_with(Done(status, satisfied))
                self.assertEqual(result["category"], "error")
                self.assertIn("do not agree", result["diagnostics"][0]["message"])

    def test_a_process_killed_by_a_signal_is_not_a_verdict(self):
        result = self.run_with(Done(-9, json.dumps({"category": "satisfied",
                                                    "diagnostics": []})))
        self.assertEqual(result["category"], "error")
        self.assertIn("-9", result["diagnostics"][0]["message"])

    def test_a_status_outside_the_contract_is_not_a_verdict(self):
        result = self.run_with(Done(127, json.dumps({"category": "actionable",
                                                     "diagnostics": [{"code": "a",
                                                                      "message": "b"}]})))
        self.assertEqual(result["category"], "error")

    def test_a_result_that_is_not_an_object_is_refused_rather_than_raising(self):
        for stdout in ("[]", '"satisfied"', "null", "3"):
            with self.subTest(stdout):
                result = self.run_with(Done(0, stdout))
                self.assertEqual(result["category"], "error")
                self.assertIn("not an object", result["diagnostics"][0]["message"])

    def test_diagnostics_have_to_be_a_list_of_objects_with_string_fields(self):
        broken = [
            {"category": "satisfied", "diagnostics": "none"},
            {"category": "actionable", "diagnostics": ["missing_declaration"]},
            {"category": "actionable", "diagnostics": [{"code": 7, "message": "x"}]},
            {"category": "actionable", "diagnostics": [{"code": "x", "message": None}]},
            {"category": "satisfied"},
        ]
        for result in broken:
            with self.subTest(str(result)[:40]):
                self.assertEqual(self.run_with(Done(0 if result["category"] == "satisfied" else 1,
                                                    json.dumps(result)))["category"], "error")

    def test_an_actionable_verdict_with_nothing_behind_it_is_refused(self):
        """The heading falls back to "no usable citation" when there are no findings, so this
        shape would word an accusation with nothing behind it."""
        result = self.run_with(Done(1, json.dumps({"category": "actionable", "diagnostics": []})))
        self.assertEqual(result["category"], "error")
        self.assertIn("no diagnostics", result["diagnostics"][0]["message"])

    def test_a_checker_that_never_returns_is_given_up_on(self):
        def timeout(*args, **kwargs):
            self.assertEqual(kwargs.get("timeout"), bot.CHECKER_TIMEOUT_SECONDS)
            raise bot.subprocess.TimeoutExpired("cmd", kwargs.get("timeout"))

        original = bot.subprocess.run
        bot.subprocess.run = timeout
        try:
            result = bot.evaluate("anything")
        finally:
            bot.subprocess.run = original
        self.assertEqual(result["category"], "error")
        self.assertIn("did not finish", result["diagnostics"][0]["message"])

    def test_a_checker_that_cannot_be_launched_is_the_same_answer(self):
        original = bot.subprocess.run

        def refuse(*args, **kwargs):
            raise OSError(8, "Exec format error")
        bot.subprocess.run = refuse
        try:
            result = bot.evaluate("anything")
        finally:
            bot.subprocess.run = original
        self.assertEqual(result["category"], "error")
        self.assertIn("could not be run", result["diagnostics"][0]["message"])

    def test_the_agreeing_pairs_all_pass(self):
        """The control. Every case above is "the pair disagrees", so without this they prove only
        that `_validated` refuses things."""
        for status, category, diagnostics in (
                (0, "satisfied", []),
                (1, "actionable", [{"code": "missing_declaration", "message": "no citation"}]),
                (2, "error", [{"code": "checker_error", "message": "corpus unavailable"}])):
            with self.subTest(category):
                result = self.run_with(Done(status, json.dumps({"category": category,
                                                                "diagnostics": diagnostics})))
                self.assertEqual(result["category"], category)

    def test_the_maintainer_line_carries_the_cause_and_cannot_open_a_command(self):
        folded = bot.one_line("corpus unavailable\n::error::everything is fine")
        self.assertNotIn("\n", folded)
        self.assertNotIn("::", folded)
        self.assertIn("corpus unavailable", folded)


class TheVerdictMayNotOutrunTheBody(unittest.TestCase):
    """A repair that lands during the comment walk must not be published over.

    The freshness check ran ONCE, before the comment list was fetched -- and fetching it is the
    slowest thing this does. A body repaired during that walk still got the old actionable note.
    """

    def setUp(self):
        self.env = dict(os.environ)
        os.environ["GITHUB_REPOSITORY"] = "MongLong0214/logic-pro-mcp"
        os.environ["ISSUE_NUMBER"] = "1"
        os.environ["CANON_BOT_LOGIN"] = BOT_LOGIN
        self.original = bot.GitHub
        self.addCleanup(self.restore)

    def restore(self):
        bot.GitHub = self.original
        os.environ.clear()
        os.environ.update(self.env)

    def drive(self, comments=(), bodies_in_order=None):
        fake = FakeGitHub(UNCITED, comments, bodies_in_order)
        bot.GitHub = lambda repo: fake
        return bot.main(), fake

    def test_a_repair_during_the_comment_walk_is_not_written_over(self):
        status, fake = self.drive(bodies_in_order=[UNCITED, UNCITED, REPAIRED])
        self.assertEqual(status, 0)
        self.assertEqual(fake.created, [], "published a verdict about a body that had moved")
        self.assertEqual(fake.updated, [])

    def test_the_same_run_writes_when_the_body_holds_still(self):
        """The control. Three reads of the same body must still produce the note, or the case
        above passes because nothing was ever going to be written."""
        status, fake = self.drive(bodies_in_order=[UNCITED, UNCITED, UNCITED])
        self.assertEqual(status, 0)
        self.assertEqual(len(fake.created), 1)
        self.assertGreaterEqual(fake.body_reads, 3, "the pre-write check did not happen")

    def test_a_repair_during_the_stale_note_recovery_is_not_written_over(self):
        """The recovery re-lists the comments, which is another round trip. A verdict that was
        stale before the first write is no fresher on the second."""
        stale = comment(7, bot.render("actionable", [("missing_declaration", "a")]))
        fake = FakeGitHub(UNCITED, [stale],
                          [UNCITED, UNCITED, UNCITED, REPAIRED])
        fake.fail_update_ids = {7}
        bot.GitHub = lambda repo: fake
        self.assertEqual(bot.main(), 0)
        self.assertEqual(fake.updated, [], "retried a stale verdict over a repaired body")
        self.assertEqual(fake.created, [])

    def test_the_recovery_still_succeeds_when_the_body_holds_still(self):
        """The control for the case above."""
        stale = comment(7, bot.render("actionable", [("missing_declaration", "a")]))
        fake = FakeGitHub(UNCITED, [stale], [UNCITED])
        fake.fail_update_ids = {7}
        bot.GitHub = lambda repo: fake
        self.assertEqual(bot.main(), 0)
        self.assertEqual([cid for cid, _ in fake.updated], [7])


class TheCommentWalkIsTheRealOne(unittest.TestCase):
    """`GitHub.comments` driven through `_api`, not replaced by a list.

    Every other case here hands `main()` a fake whose `comments()` returns one list, so the paging
    loop itself -- the thing that makes the freshness window wide -- is never executed. A managed
    note on page two is the shape that loop exists for.
    """

    def api_over(self, pages):
        walk = bot.GitHub("owner/repo")
        walk.PER_PAGE = 2
        calls = []

        def fake_api(path, method="GET", fields=None):
            calls.append(path)
            page = int(path.rsplit("page=", 1)[1])
            return json.dumps(pages[page - 1] if page <= len(pages) else [])
        walk._api = fake_api
        return walk, calls

    def test_a_note_on_the_second_page_is_found(self):
        note = comment(9, bot.render("actionable", [("missing_declaration", "a")]))
        full = [comment(1, "one"), comment(2, "two")]
        walk, calls = self.api_over([full, [note]])
        found = walk.comments(5)
        self.assertEqual(len(calls), 2, "a full first page must not end the walk")
        active, extra = bot.active_note(found, BOT_LOGIN)
        self.assertIsNotNone(active, "the managed note on page two was not seen")
        self.assertEqual(active["id"], 9)
        self.assertEqual(extra, [])

    def test_a_short_first_page_ends_the_walk(self):
        """The control. Without it, "two pages were read" says nothing about when it stops."""
        walk, calls = self.api_over([[comment(1, "one")]])
        self.assertEqual(len(walk.comments(5)), 1)
        self.assertEqual(len(calls), 1)

    def test_an_endless_endpoint_refuses_rather_than_spinning(self):
        walk, calls = self.api_over([[comment(1, "one"), comment(2, "two")]] * 500)
        with self.assertRaises(RuntimeError):
            walk.comments(5)
        self.assertEqual(len(calls), walk.MAX_PAGES)


class TheCorpusIsNotTheAuthorsFault(unittest.TestCase):
    """R1's other half, through the bot: a tooling failure must reach nobody as an accusation."""

    def setUp(self):
        self.env = dict(os.environ)
        os.environ["GITHUB_REPOSITORY"] = "MongLong0214/logic-pro-mcp"
        os.environ["ISSUE_NUMBER"] = "1"
        os.environ["CANON_BOT_LOGIN"] = BOT_LOGIN
        self.original_github, self.original_evaluate = bot.GitHub, bot.evaluate
        self.addCleanup(self.restore)

    def restore(self):
        bot.GitHub, bot.evaluate = self.original_github, self.original_evaluate
        os.environ.clear()
        os.environ.update(self.env)

    def unreadable_index(self):
        bot.evaluate = lambda body: {
            "category": "error", "label": "",
            "diagnostics": [{"code": "checker_error", "message": (
                "docs/canon/index/strings.tsv does not exist, so no reference for strings can be "
                "resolved here. Nothing is being asserted about the citation.")}]}

    def test_no_note_is_created_for_an_index_this_run_could_not_read(self):
        self.unreadable_index()
        fake = FakeGitHub("Something is wrong with the mixer.\n", [])
        bot.GitHub = lambda repo: fake
        self.assertEqual(bot.main(), 0)
        self.assertEqual(fake.created, [])
        self.assertEqual(fake.updated, [])

    def test_the_maintainer_is_told_WHICH_failure_it_was(self):
        """The note says nothing about the body on purpose, so the log is the only place the run
        that failed can be told from the run that found nothing to say. "See the log above" alone
        does not distinguish them."""
        self.unreadable_index()
        fake = FakeGitHub("Something is wrong with the mixer.\n", [])
        bot.GitHub = lambda repo: fake
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            self.assertEqual(bot.main(), 0)
        warning = [line for line in printed.getvalue().splitlines()
                   if line.startswith("::warning::")]
        self.assertEqual(len(warning), 1, printed.getvalue())
        self.assertIn("strings.tsv does not exist", warning[0])

    def test_a_standing_warning_is_not_resolved_by_an_index_failure(self):
        self.unreadable_index()
        standing = comment(7, bot.render("actionable", [("missing_declaration", "a")]))
        fake = FakeGitHub("Something is wrong with the mixer.\n", [standing])
        bot.GitHub = lambda repo: fake
        self.assertEqual(bot.main(), 0)
        self.assertEqual(fake.created, [])
        self.assertEqual([cid for cid, _ in fake.updated], [7])
        self.assertEqual(bot.state_of(fake.updated[0][1]), bot.UNKNOWN,
                         "a run that could not evaluate withdrew a warning")


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
