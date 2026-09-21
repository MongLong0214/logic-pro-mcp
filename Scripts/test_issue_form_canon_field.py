#!/usr/bin/env python3
"""The Canon field of an issue form must reach the issue body as prose the checker reads.

WHAT WENT WRONG. `feature_request.yml`, `bug_report.yml` and `live_qa_failure.yml` each told an
author to write the sentence `states no fact about Logic` into their `logic_canon` textarea, and
each declared that textarea `render: text`. GitHub wraps a rendered textarea in a fenced code
block, and `check-canon-citations.py` deliberately ignores a declaration that appears only inside
one -- `_visible()` strips fences and HTML comments before looking, because a declaration hidden
where a reader does not see it is how the opt-out was bypassed three ways before. So the form
instructed the author to produce a body the checker was built to reject, and the contributor in
#944 had to leave the form, find the fence and repair the rendered issue by hand.

The form was wrong, not the safety rule. This file holds that distinction open: it renders each
form the way GitHub does and runs the REAL checker over the result, so a future `render:` on a
Canon field fails here, and so does any attempt to make a fenced declaration count.

WHY A RENDERER RATHER THAN A YAML ASSERTION. Parsing the YAML and asserting `render` is absent
says nothing about what the author's text becomes. The bug lived in the gap between the form and
the body, so the test has to cross that gap: `render_form()` below is the documented rendering --
a `### <label>` heading, the answer beneath it, an unanswered optional field as `_No response_`,
and a `render: <lang>` field fenced. `test_the_old_rendering_is_what_broke` applies the old
setting to today's text and shows the checker refusing it, so the fix is witnessed by a failure
and not only by a pass.
"""
import os
import re
import subprocess
import sys
import tempfile
import unittest

#: Imported at module level and deliberately NOT guarded by a skip. `run-repo-guards.py` records
#: two drives that raised `SkipTest` when they could not find their input and were counted as
#: passes for it; a file that cannot read the forms has not checked them, and saying so as an
#: error is the only honest report. If a runner turns up without PyYAML, install it there rather
#: than letting this file go quiet.
import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATES = os.path.join(REPO, ".github", "ISSUE_TEMPLATE")
CHECKER = os.path.join(REPO, "Scripts", "check-canon-citations.py")

#: The field every Canon rule in an issue form hangs off. Named by id, not by label: the label is
#: rendered text somebody may reword, the id is what the form schema keys on.
CANON_FIELD = "logic_canon"

#: The sentence `check-canon-citations.py` looks for, spelled here so a rename of the constant
#: there fails this file rather than silently making every case below vacuous.
NO_FACT = "states no fact about Logic"


def forms():
    """{filename: parsed form} for every issue form that has a Canon field."""
    out = {}
    for name in sorted(os.listdir(TEMPLATES)):
        if not name.endswith((".yml", ".yaml")) or name == "config.yml":
            continue
        with open(os.path.join(TEMPLATES, name), encoding="utf-8") as handle:
            form = yaml.safe_load(handle)
        if any(field.get("id") == CANON_FIELD for field in form.get("body", [])):
            out[name] = form
    return out


def canon_field(form):
    for field in form.get("body", []):
        if field.get("id") == CANON_FIELD:
            return field
    raise AssertionError("no %s field" % CANON_FIELD)


def render_form(form, answers, force_render=None):
    """The issue body GitHub produces for these answers.

    https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/syntax-for-githubs-form-schema

    Only the parts that decide this file's question are modelled: a heading per input field, the
    answer beneath it, `_No response_` for an unanswered one, and the fence a `render:` adds.
    `force_render` overrides the Canon field's own setting so the old behaviour can be replayed
    against today's text.
    """
    chunks = []
    for field in form.get("body", []):
        if field.get("type") in (None, "markdown"):
            continue
        key = field.get("id")
        label = field.get("attributes", {}).get("label", key)
        answer = answers.get(key)
        if answer is None:
            chunks.append("### %s\n\n_No response_" % label)
            continue
        render = field.get("attributes", {}).get("render")
        if key == CANON_FIELD and force_render is not None:
            render = force_render
        if render:
            chunks.append("### %s\n\n```%s\n%s\n```" % (label, render, answer))
        else:
            chunks.append("### %s\n\n%s" % (label, answer))
    return "\n\n".join(chunks) + "\n"


def check(body):
    """(exit status, combined output) from the production checker over this body."""
    with tempfile.NamedTemporaryFile("w", suffix=".md", encoding="utf-8", delete=False) as handle:
        handle.write(body)
        path = handle.name
    try:
        done = subprocess.run(
            [sys.executable, CHECKER, "--text", path],
            cwd=REPO, capture_output=True, text=True,
        )
        return done.returncode, done.stdout + done.stderr
    finally:
        os.unlink(path)


#: An answer for every other field, so the rendered body is a realistic issue rather than one
#: heading. Deliberately free of anything the corpus holds: a body that quotes a string Logic
#: ships is stating a fact about Logic, and the checker says so even under the declaration -- that
#: rule is C08's and is not this file's to weaken.
FILLER = "A packaging change. No user-facing behaviour is described here."


def answers_for(form, canon_answer):
    out = {}
    for field in form.get("body", []):
        key = field.get("id")
        if key is None or field.get("type") == "markdown":
            continue
        if field.get("type") == "checkboxes":
            labels = [box["label"] for box in field.get("attributes", {}).get("options", [])]
            out[key] = "\n".join("- [X] %s" % label for label in labels)
        elif field.get("type") == "dropdown":
            out[key] = field.get("attributes", {}).get("options", ["other"])[0]
        else:
            out[key] = FILLER
    if canon_answer is None:
        out.pop(CANON_FIELD, None)
    else:
        out[CANON_FIELD] = canon_answer
    return out


DECLARATION = "%s -- this is a packaging request and describes no Logic behaviour." % NO_FACT


class TheFormsThemselves(unittest.TestCase):
    def setUp(self):
        self.forms = forms()

    def test_there_are_canon_forms_to_check(self):
        # An empty discovery agrees with every assertion below, which is not the same as passing.
        self.assertGreaterEqual(len(self.forms), 3, self.forms.keys())

    def test_no_canon_field_forces_a_code_block(self):
        for name, form in self.forms.items():
            with self.subTest(form=name):
                self.assertNotIn("render", canon_field(form).get("attributes", {}))

    def test_every_canon_field_is_optional_at_submission(self):
        # An issue is not a merge request. Requiring the corpus to file a bug report is the
        # barrier #944 met; the advisory bot may still ask for evidence afterwards.
        for name, form in self.forms.items():
            with self.subTest(form=name):
                self.assertFalse(canon_field(form).get("validations", {}).get("required", False))

    def test_the_field_id_is_unchanged(self):
        # The id is what every consumer keys on. Rewording the label is free; renaming this is not.
        for name, form in self.forms.items():
            with self.subTest(form=name):
                ids = [f.get("id") for f in form.get("body", [])]
                self.assertIn(CANON_FIELD, ids)

    def test_the_description_does_not_hand_over_a_ready_made_declaration(self):
        # A form whose PLACEHOLDER carries the opt-out sentence makes every untouched submission
        # pass the only check wired to it. The description explains the sentence; the placeholder
        # must not type it for the author.
        for name, form in self.forms.items():
            with self.subTest(form=name):
                placeholder = canon_field(form).get("attributes", {}).get("placeholder", "")
                self.assertNotIn(NO_FACT, placeholder)


class WhatTheCheckerSeesAfterRendering(unittest.TestCase):
    def setUp(self):
        self.forms = forms()

    def test_a_plain_declaration_is_read(self):
        """A01."""
        for name, form in self.forms.items():
            with self.subTest(form=name):
                body = render_form(form, answers_for(form, DECLARATION))
                status, output = check(body)
                self.assertEqual(status, 0, output)

    def test_the_old_rendering_is_what_broke(self):
        """A01, witnessed as a failure: the same text, fenced the way `render: text` fenced it."""
        for name, form in self.forms.items():
            with self.subTest(form=name):
                body = render_form(form, answers_for(form, DECLARATION), force_render="text")
                status, output = check(body)
                self.assertEqual(status, 1, output)
                self.assertIn(NO_FACT, output)

    def test_a_declaration_only_inside_a_fence_still_does_not_count(self):
        """A04. The rule is not what is being relaxed."""
        fenced = "```\n%s\n```" % DECLARATION
        for name, form in self.forms.items():
            with self.subTest(form=name):
                body = render_form(form, answers_for(form, fenced))
                self.assertEqual(check(body)[0], 1)

    def test_a_declaration_only_inside_an_html_comment_still_does_not_count(self):
        """A04."""
        hidden = "<!-- %s -->" % DECLARATION
        for name, form in self.forms.items():
            with self.subTest(form=name):
                body = render_form(form, answers_for(form, hidden))
                self.assertEqual(check(body)[0], 1)

    def test_an_unanswered_optional_field_is_not_a_pass(self):
        """A03. Submittable is not the same as verified: no answer means no evidence."""
        for name, form in self.forms.items():
            with self.subTest(form=name):
                body = render_form(form, answers_for(form, None))
                self.assertIn("_No response_", body)
                status, output = check(body)
                self.assertEqual(status, 1, output)

    def test_the_renderer_can_tell_the_two_apart(self):
        """The instrument, checked against itself: fencing has to change the rendered bytes."""
        form = self.forms["feature_request.yml"]
        plain = render_form(form, answers_for(form, DECLARATION))
        fenced = render_form(form, answers_for(form, DECLARATION), force_render="text")
        self.assertNotEqual(plain, fenced)
        self.assertRegex(fenced, re.compile(r"```text\n" + re.escape(NO_FACT)))
        self.assertNotIn("```text", plain)


if __name__ == "__main__":
    unittest.main(verbosity=2)
