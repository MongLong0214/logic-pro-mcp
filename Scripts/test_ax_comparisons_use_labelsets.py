#!/usr/bin/env python3
"""Cases for `check-ax-comparisons-use-labelsets.py`.

Every one of these was run by hand while the guard was written, and two of them are defects the
guard had. It reported 11 findings of which 9 were internal identifiers — `if name == "Stop"`,
where `name` is this product's own command name — and its separator rule could never pass, because
it upper-cased the haystack and then looked for a lowercase `\\u` escape in it.
"""
import importlib.util
import os
import tempfile
import json
import subprocess
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "ax_comparisons", os.path.join(REPO, "Scripts", "check-ax-comparisons-use-labelsets.py"))
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)


class TracingAReadingToTheAccessibilityAPI(unittest.TestCase):
    """Condition 1: the variable must actually hold something AX returned."""

    def test_a_variable_read_from_ax_is_traced(self):
        source = 'let title = AXHelpers.getTitle(cb, runtime: r)\nif title == "Stop" { }'
        self.assertIn("title", guard.ax_backed_names(source))

    def test_a_parameter_named_name_is_not_an_ax_reading(self):
        """The defect that produced 9 of 11 findings. `name` here is a command name."""
        source = 'static func toggle(named name: String) {\n  if name == "Stop" { }\n}'
        self.assertNotIn("name", guard.ax_backed_names(source))

    def test_a_catalogue_constant_is_not_an_ax_reading(self):
        source = 'let bandName = band.displayName\nif bandName.hasSuffix("Cut") { }'
        self.assertNotIn("bandName", guard.ax_backed_names(source))


class SeparatorsAreNotLabels(unittest.TestCase):
    """A literal made only of punctuation names no control, so a LabelSet is the wrong home.

    What it must do is handle every spelling Apple ships: a Chinese Logic writes the full-width
    `\uff1a` where the others write `:`.
    """

    def _file(self, text):
        handle = tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False,
                                             dir=REPO, encoding="utf-8")
        handle.write(text)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return os.path.relpath(handle.name, REPO)

    def test_the_table_supplies_more_than_one_spelling(self):
        groups = guard.separator_groups()
        self.assertTrue(any(":" in g and "\uff1a" in g for g in groups),
                        "DECORATION-RULES.json must carry both colons or this rule is inert")

    def test_handling_only_the_ascii_spelling_fails(self):
        path = self._file('if value.contains(":") { }\n')
        self.assertFalse(guard.handles_every_spelling(":", [path]))

    def test_handling_both_spellings_passes(self):
        path = self._file('if value.contains(":") || value.contains("\\u{FF1A}") { }\n')
        self.assertTrue(guard.handles_every_spelling(":", [path]))

    def test_the_escape_is_matched_case_insensitively(self):
        """THE CHECK THAT COULD NOT PASS.

        The first version upper-cased the source and then looked for a lowercase `\\u{ffff}`
        escape in it, so a file spelling the character correctly still failed. Swift writes
        `\\u{FF1A}`; the test is that either case is accepted.
        """
        for spelling in ("\\u{FF1A}", "\\u{ff1a}"):
            with self.subTest(spelling=spelling):
                path = self._file(f'if value.contains(":") || value.contains("{spelling}") {{ }}\n')
                self.assertTrue(guard.handles_every_spelling(":", [path]))

    def test_the_literal_character_also_counts(self):
        path = self._file('if value.contains(":") || value.contains("\uff1a") { }\n')
        self.assertTrue(guard.handles_every_spelling(":", [path]))


class TheGuardActuallyRefusesSomething(unittest.TestCase):
    """THE CASES THIS SUITE DID NOT HAVE.

    Every case above drove a helper, and the only whole-guard assertion was "the repository
    passes" -- which a guard that returns `[]` unconditionally satisfies. An outside review made
    `check()` return `[]` and this suite stayed green: the rule had never been watched refuse
    anything, which is the definition of a decorative guard.

    `LPM_AX_COMPARISON_ROOTS` points the scan at a directory the case builds, so a positive input
    exists at all. The waiver cases use a temporary file, so a
    `docs/canon/AX-COMPARISON-WAIVERS.json` in the tree -- there is none since `plugin_names` cites
    `Channel EQ` (#1028) -- is never what makes a case pass.
    """

    def _scan(self, source, waiver=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "Sources")
            os.makedirs(root)
            with open(os.path.join(root, "Offender.swift"), "w", encoding="utf-8") as handle:
                handle.write(source)
            before_root = os.environ.get("LPM_AX_COMPARISON_ROOTS")
            before_waiver = guard.WAIVER
            os.environ["LPM_AX_COMPARISON_ROOTS"] = root
            if waiver is not None:
                path = os.path.join(tmp, "waivers.json")
                with open(path, "w", encoding="utf-8") as handle:
                    json.dump({"literals": waiver}, handle)
                guard.WAIVER = path
            try:
                return guard.check()
            finally:
                guard.WAIVER = before_waiver
                if before_root is None:
                    os.environ.pop("LPM_AX_COMPARISON_ROOTS", None)
                else:
                    os.environ["LPM_AX_COMPARISON_ROOTS"] = before_root

    #: `Mixer` is shipped by Apple and translated by Apple, so it satisfies conditions 2 and 3.
    _READ = 'let title = AXHelpers.getTitle(element) ?? ""\n'

    def test_the_plain_comparison_is_refused(self):
        problems = self._scan(self._READ + 'if title == "Mixer" { }\n')
        self.assertTrue(problems, "a translated label compared against an AX reading must fail")
        self.assertIn("Mixer", problems[0])

    def test_a_waiver_excuses_it(self):
        self.assertEqual(self._scan(self._READ + 'if title == "Mixer" { }\n',
                                    waiver={"Mixer": "declared safe by the case"}), [])

    def test_a_comparison_against_a_non_ax_variable_is_not_refused(self):
        """The control. Without it the cases above would pass on a rule that fires on everything."""
        self.assertEqual(self._scan('let commandName = "x"\nif commandName == "Mixer" { }\n'), [])

    def test_an_untranslated_literal_is_not_refused(self):
        """`MIDI` is in the corpus and identical in every locale — matching it by literal is safe,
        and condition 3 is what keeps this guard from being wrong more often than right."""
        self.assertEqual(self._scan(self._READ + 'if title == "MIDI" { }\n'), [])

    def test_the_evasive_shapes_are_refused(self):
        """The three spellings an outside review walked the same defect through, each of which had
        been invisible because the patterns anchored on the variable and on `==`."""
        for label, source in [
            # `copy`, not `mixer`: `mixer` IS a policy literal (a lowercase containment fragment),
            # so a comparison against it is correctly not a finding -- the first version of this
            # case chose it and failed for the right reason, which is what a positive case is for.
            ("lowercased", self._READ + 'if title.lowercased() == "copy" { }\n'),
            ("collection", self._READ + 'return ["Mixer", "Cut"].contains(title)\n'),
            ("switch", self._READ + 'switch title {\ncase "Mixer":\n    break\ndefault:\n    break\n}\n'),
        ]:
            with self.subTest(shape=label):
                self.assertTrue(self._scan(source), f"{label} must be refused like `==` is")


class EveryLiteralIsClassified(unittest.TestCase):
    """#1028 (ADR-027 D6, audit B D5). A literal Apple does not ship used to pass as "not Apple's
    at all: safe to match" -- a fragment of a translated label, a plug-in name the corpus does not
    hold and this product's own prose all went through unexamined."""

    _READ = TheGuardActuallyRefusesSomething._READ

    def _scan(self, source, waiver=None):
        return TheGuardActuallyRefusesSomething._scan(self, source, waiver)

    def test_an_unknown_literal_is_refused(self):
        problems = self._scan(self._READ + 'if title == "Zqxv Frobnicator" { }\n')
        self.assertTrue(problems, "a literal that is neither Apple's nor an identifier passed")
        self.assertIn("Zqxv Frobnicator", problems[0])

    def test_a_fragment_of_a_translated_label_is_refused(self):
        """`Input Port` is Apple's; `Input Po` is nobody's, and matches only in English."""
        self.assertTrue(self._scan(self._READ + 'if title.hasPrefix("Input Po") { }\n'))

    def test_a_reasoned_exemption_excuses_an_unknown_literal(self):
        self.assertEqual(self._scan(self._READ + 'if title == "Zqxv Frobnicator" { }\n',
                                    waiver={"Zqxv Frobnicator": {"reason": "declared by the case"}}),
                         [])

    def test_an_exemption_without_a_reason_is_refused(self):
        self.assertTrue(self._scan(self._READ + 'if title == "Zqxv Frobnicator" { }\n',
                                   waiver={"Zqxv Frobnicator": {"reason": "  "}}))

    def test_identifiers_are_not_refused(self):
        """The control: a sentinel code, a file extension, a reverse-DNS prefix, punctuation."""
        for literal in ("DIALOG_PREEXISTING", "MENU_PICK_FAILED: detail", ".logicx",
                        "com.apple.keylayout.", "/"):
            with self.subTest(literal=literal):
                self.assertEqual(self._scan(self._READ + f'if title == "{literal}" {{ }}\n'), [])

    def test_a_fragment_of_a_message_elsewhere_in_the_file_is_not_an_identifier(self):
        """Review of #1034 R1-04: this case used to assert acceptance. Error text in the same file
        says nothing about where the reading comes from. Mutation killed: restoring the
        same-file substring rule in `classify`."""
        source = (self._READ + 'let refusal = "MENU_PICK_FAILED: menu cleanup was not seen"\n'
                  + 'if title.contains("cleanup was not seen") { }\n')
        problems = self._scan(source)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("'cleanup was not seen'", problems[0])

    def test_an_error_string_does_not_authorize_a_fragment_of_apples_label(self):
        """The reviewer's case: `Input Po` is a fragment of Apple's `Input Port`."""
        source = (self._READ + 'let error = "MENU_PICK_FAILED: Input Po"\n'
                  + 'if title.hasPrefix("Input Po") { }\n')
        problems = self._scan(source)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("'Input Po'", problems[0])

    def test_a_literal_carrying_its_own_code_is_an_identifier(self):
        """The control: the code and its delimiter inside the literal itself."""
        self.assertEqual(guard.classify("result MENU_PICK_FAILED: x"), guard.IDENTIFIER)
        self.assertEqual(guard.classify("MENU_PICK_FAILED"), guard.IDENTIFIER, "bare sentinel")
        self.assertEqual(guard.classify("cleanup MENU_PICK_FAILED"), guard.UNKNOWN,
                         "a code with no delimiter inside prose is not the code")

    def test_swift_escapes_are_decoded_before_classifying(self):
        """`\\u{FF1A}` is the full-width colon, not eight ASCII characters."""
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "Sources")
            os.makedirs(root)
            with open(os.path.join(root, "Offender.swift"), "w", encoding="utf-8") as handle:
                handle.write(self._READ + 'if title.contains("\\u{FF1A}") { }\n')
            before = os.environ.get("LPM_AX_COMPARISON_ROOTS")
            os.environ["LPM_AX_COMPARISON_ROOTS"] = root
            try:
                found = guard.comparisons_outside_labelsets()
            finally:
                if before is None:
                    os.environ.pop("LPM_AX_COMPARISON_ROOTS", None)
                else:
                    os.environ["LPM_AX_COMPARISON_ROOTS"] = before
        self.assertIn("\uff1a", found)


class APlugInNameIsCitedFromApplesMap(unittest.TestCase):
    """#1028 (ADR-027 D5). `Channel EQ` was "in no corpus" only because the canon had not pinned
    `DefaultPluginMapping.plist`. Pinned as `plugin_names`, a name Logic maps is an Apple value with
    the row it came from, and a name it does not map is still nobody's."""

    _READ = TheGuardActuallyRefusesSomething._READ

    def _scan(self, source):
        return TheGuardActuallyRefusesSomething._scan(self, source, None)

    CHANNEL_EQ = {
        "ref": "logic-canon://plugin_names/EMAG%7C0236%7C0000/-/name#value",
        "value": "Channel EQ",
    }

    def test_a_plugin_name_logic_maps_is_an_apple_value_with_its_row(self):
        self.assertEqual(guard.classify(self.CHANNEL_EQ["value"]), guard.APPLE_VALUE)
        self.assertEqual(guard.citation(self.CHANNEL_EQ["value"]), self.CHANNEL_EQ["ref"])
        self.assertEqual(self._scan(self._READ + 'if title == "Channel EQ" { }\n'), [])

    def test_a_made_up_plugin_name_stays_unknown_and_fails(self):
        """The control: without it the case above passes on a classifier that calls anything a
        plug-in name. One character off a real name is not that name."""
        self.assertEqual(guard.citation("Channel EQX"), None)
        self.assertEqual(guard.classify("Channel EQX"), guard.UNKNOWN)
        problems = self._scan(self._READ + 'if title == "Channel EQX" { }\n')
        self.assertTrue(problems, "a plug-in name Apple's map does not hold passed")
        self.assertIn("Channel EQX", problems[0])

    def test_only_the_exact_value_is_cited(self):
        """A case-folded match is a different claim, and the row is pinned by its exact digest."""
        self.assertEqual(guard.citation("channel eq"), None)


class TheLiteralIsClassifiedByItsRuntimeBytes(unittest.TestCase):
    """Review of #1034 R1-03. Every canon digest is taken over `normalize`, which strips and folds
    U+00A0, and the scanner normalized each literal before classifying it -- so a comparison
    against ` Channel EQ ` was cited as Apple's `Channel EQ` and passed, though it never matches
    what Logic draws. Each spelling below differs from Apple's value by bytes a comparison sees.

    Mutation killed: deleting the not-in-normal-form branch at the top of `classify`, or keying any
    scanner branch by `canon.normalize(...)` again."""

    _READ = TheGuardActuallyRefusesSomething._READ

    def _scan(self, source):
        return TheGuardActuallyRefusesSomething._scan(self, source, None)

    #: (the literal at runtime, the same literal as Swift source spells it)
    SPELLINGS = ((" Channel EQ ", '" Channel EQ "'),
                 ("Channel\u00a0EQ", '"Channel\\u{00A0}EQ"'),
                 ("Channel EQ\n", '"Channel EQ\\n"'))

    def test_each_spelling_classifies_as_unknown_and_is_not_cited_as_a_row(self):
        for literal, _swift in self.SPELLINGS:
            with self.subTest(literal=literal):
                self.assertEqual(guard.classify(literal), guard.UNKNOWN)
        self.assertEqual(guard.classify("Channel EQ"), guard.APPLE_VALUE, "the control")

    def test_each_spelling_is_refused_in_every_scanner_branch(self):
        for literal, swift in self.SPELLINGS:
            branches = {
                "equality": f"if title == {swift} {{ }}\n",
                "method": f"if title.hasPrefix({swift}) {{ }}\n",
                "collection": f"if [{swift}].contains(title) {{ }}\n",
                "switch": f"switch title {{\ncase {swift}: break\ndefault: break\n}}\n",
            }
            for branch, code in branches.items():
                with self.subTest(literal=literal, branch=branch):
                    problems = self._scan(self._READ + code)
                    self.assertEqual(len(problems), 1, problems)
                    self.assertIn(repr(literal), problems[0])

    def test_a_padded_literal_in_the_folded_branch_is_refused(self):
        """`MIDI` is an untranslated Apple value, so the unpadded control passes."""
        self.assertEqual(self._scan(self._READ + 'if title.uppercased() == "MIDI" { }\n'), [])
        problems = self._scan(self._READ + 'if title.uppercased() == " MIDI " { }\n')
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("' MIDI '", problems[0])


class AConstantIsClassifiedByItsLiteral(unittest.TestCase):
    """Review of #1034 (after R1-04). The scanner saw only literals written inline, so a Logic label
    moved into a constant -- `static let` or a local `let` -- and compared with an AX value passed.
    Measured: `Mixer` planted that way through `==`, `contains` and `hasPrefix` gave 0 literals and
    exit 0 while the same comparison inline was refused. A comparison operand that names a
    literal-initialized String constant is now classified by that literal's bytes.

    Mutation killed: constant resolution disabled (`resolve_constant` returning `[]`) turns the
    three planted cases green, and this class red."""

    _READ = 'let value = AXHelpers.getValue(element) ?? ""\n'

    def _scan(self, source):
        return TheGuardActuallyRefusesSomething._scan(self, source, None)

    PLANTED = {
        "static let, ==": 'enum Planted { static let mixerLabel = "Mixer" }\n'
                          'if value == Planted.mixerLabel { }\n',
        "local let, contains": 'let localLabel = "Mixer"\nif value.contains(localLabel) { }\n',
        "static let, hasPrefix": 'enum Planted { static let mixerLabel = "Mixer" }\n'
                                 'if value.hasPrefix(Planted.mixerLabel) { }\n',
    }

    def test_a_label_in_a_constant_is_refused(self):
        for shape, code in self.PLANTED.items():
            with self.subTest(shape=shape):
                problems = self._scan(self._READ + code)
                self.assertEqual(len(problems), 1, problems)
                self.assertIn("'Mixer'", problems[0])
                self.assertIn("TRANSLATES", problems[0])

    def test_the_inline_control_stays_refused(self):
        problems = self._scan(self._READ + 'if value == "Mixer" { }\n')
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("'Mixer'", problems[0])

    def test_an_instance_member_is_not_a_constant(self):
        source = (self._READ + 'enum K { static let title = "Mixer" }\n'
                  + 'if value == before.title { }\n')
        self.assertEqual(self._scan(source), [])


class AnOperandIsAxTextOnlyIfSomethingReadIt(unittest.TestCase):
    """Review of #1034, round 2. `emitting_constants` passed a constant because the product ALSO
    wrote it into its own script or refusal, and that is authority by co-location again: with an
    AX-backed `title`, `fragment = "Input Po"`, `"MENU_PICK_FAILED: " + fragment` interpolated into
    a string, and `title.hasPrefix(fragment)`, the guard reported nothing. The rule is gone, and
    `PostLeafCleanupSite.notObservedMarker` passes for the true reason: the operand it is compared
    with holds the script's own output, so the parameter is named `scriptResult`, not `value`.

    A rename is only honest if a rename cannot also hide AX text, so the scan now follows every
    name a file assigns from an accessor (`_variable_pattern`), not only names that look like an
    attribute. The taint is still by NAME and per FILE -- see the Limit in the docstring."""

    def _scan(self, source):
        return TheGuardActuallyRefusesSomething._scan(self, source, None)

    def _scan_files(self, files):
        """`{file name: source}` under one `Sources/`, so a declaration can live in another file."""
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "Sources")
            os.makedirs(root)
            for name, source in files.items():
                with open(os.path.join(root, name), "w", encoding="utf-8") as handle:
                    handle.write(source)
            before = os.environ.get("LPM_AX_COMPARISON_ROOTS")
            os.environ["LPM_AX_COMPARISON_ROOTS"] = root
            try:
                return guard.check()
            finally:
                if before is None:
                    os.environ.pop("LPM_AX_COMPARISON_ROOTS", None)
                else:
                    os.environ["LPM_AX_COMPARISON_ROOTS"] = before

    _READ = 'let title = AXHelpers.getTitle(element) ?? ""\n'

    def _refused(self, problems, literal):
        self.assertEqual(len(problems), 1, problems)
        self.assertIn(repr(literal), problems[0])

    def test_the_reviewers_emitted_fragment_is_refused(self):
        """The reviewer's case, through `hasPrefix`, `contains` and `==`. Red at 435de2ee (0
        problems each). Mutation killed: reinstating `emitting_constants` and its branch in
        `classify`."""
        emitted = ('let fragment = "Input Po"\n'
                   'let error = "MENU_PICK_FAILED: " + fragment\n'
                   'let message = "refused: \\(error)"\n')
        for shape in ("title.hasPrefix(fragment)", "title.contains(fragment)", "title == fragment"):
            with self.subTest(shape=shape):
                self._refused(self._scan(self._READ + emitted + f"if {shape} {{ }}\n"), "Input Po")

    #: The shape of `AccessibilityChannel.PostLeafCleanupSite` and its parser: the phrase is one
    #: constant, a refusal is built from it and interpolated into the script, and `value` is read
    #: from AX ELSEWHERE in the file -- which is what made the parser's `value` look like AX text.
    _SITE = ('struct Site {\n'
             '    static let notObservedMarker = "cleanup was not observed"\n'
             '    static let dialogRefusal = ": dialog " + notObservedMarker\n'
             '    var appleScript: String { "return \\"X\\(Self.dialogRefusal)\\"" }\n'
             '}\n'
             'func read(field: AXUIElement) {\n'
             '    let value: String? = AXHelpers.getAttribute(field, kAXValueAttribute)\n'
             '}\n')

    def test_a_script_result_compared_with_the_products_marker_passes(self):
        """The positive. Green at 435de2ee too, where `scriptResult` was not scanned at all; after,
        it would be scanned if anything read it from AX, and nothing does. Mutation killed:
        `ax_backed_names` counting every name in a file that reads AX at all."""
        source = (self._SITE + 'func cleanup(_ scriptResult: String) -> Bool {\n'
                  '    scriptResult.contains(Site.notObservedMarker)\n}\n')
        self.assertEqual(self._scan(source), [])

    def test_the_marker_compared_with_the_name_ax_backs_is_refused(self):
        """The same comparison through `value`, which this file reads from AX: an emitted phrase
        buys nothing. Red at 435de2ee (the emitter rule passed it)."""
        source = (self._SITE + 'func cleanup(_ value: String) -> Bool {\n'
                  '    value.contains(Site.notObservedMarker)\n}\n')
        self._refused(self._scan(source), "cleanup was not observed")

    def test_the_renamed_name_read_from_ax_is_refused(self):
        """`scriptResult` assigned from an AX read in the same function: a name that does not look
        like an attribute is no way out. Red at 435de2ee (0 problems). Mutation killed:
        `_variable_pattern` returning `_AX_VAR` alone."""
        source = (self._SITE + 'func cleanup(element: AXUIElement) -> Bool {\n'
                  '    let scriptResult = AXHelpers.getValue(element) ?? ""\n'
                  '    return scriptResult.contains(Site.notObservedMarker)\n}\n')
        self._refused(self._scan(source), "cleanup was not observed")

    def test_a_code_in_another_literal_on_the_line_authorizes_nothing(self):
        """Self-attack (a). Mutation killed: restoring the pre-R1-04 rule that excused a literal
        found inside a sentinel-coded message elsewhere in the file."""
        source = (self._READ + 'if title.hasPrefix("Input Po") || title == "MENU_PICK_FAILED: '
                  'Input Po" { }\n')
        self._refused(self._scan(source), "Input Po")

    def test_a_same_named_constant_in_another_file_authorizes_nothing(self):
        """Self-attack (b): a coded constant of the same name, declared in another file, bare and
        as a static member. Mutation killed: `resolve_constant` answering with the first
        declaration of the name in any file."""
        other = ('let fragment = "MENU_PICK_FAILED: ok"\n'
                 'enum Site { static let fragment = "MENU_PICK_FAILED: ok" }\n')
        cases = {
            "bare": 'let fragment = "Input Po"\nif title.hasPrefix(fragment) { }\n',
            "static": 'enum Site { static let fragment = "Input Po" }\n'
                      'if title.hasPrefix(Site.fragment) { }\n',
        }
        for shape, code in cases.items():
            with self.subTest(shape=shape):
                problems = self._scan_files({"Another.swift": other,
                                             "Offender.swift": self._READ + code})
                self._refused(problems, "Input Po")

    def test_a_fragment_interpolated_into_a_coded_literal_is_still_refused(self):
        """Self-attack (c). The coded literal is not indexed as a constant (it interpolates), and
        the fragment it interpolates is classified on its own bytes. Mutation killed: a rule that
        excuses a constant a sentinel-coded literal interpolates."""
        source = (self._READ + 'let fragment = "Input Po"\n'
                  'let error = "MENU_PICK_FAILED: \\(fragment)"\n'
                  'if title.hasPrefix(fragment) { }\n')
        self._refused(self._scan(source), "Input Po")

    def test_the_accessibility_apis_own_vocabulary_is_an_identifier(self):
        """What the wider scan found on this tree: `role == "AXLayoutArea"`, `subrole ==
        "AXDialog"`, and a boolean AX value read as text. Mutation killed: dropping
        `_AX_API_NAME` or `_BOOLEAN_TEXT` from `classify` (the real tree fails too)."""
        for literal in ("AXDialog", "AXFloatingWindow", "AXLayoutArea", "AXSearchField",
                        "true", "false"):
            with self.subTest(literal=literal):
                self.assertEqual(guard.classify(literal), guard.IDENTIFIER)
        for literal in ("AX", "AX Dialog", "AXDialog: x", "TRUE"):
            with self.subTest(control=literal):
                self.assertEqual(guard.classify(literal), guard.UNKNOWN)

class TheEntryPointRefuses(unittest.TestCase):
    """The cases above call `check()`. A `main()` that returned 0 without ever calling it would
    pass every one of them, because the repository passes -- `Scripts/mutation-sweep-guard-tests.py`
    measured that on 2026-09-18. A guard is its entry point, so one case drives it at a tree that
    must fail."""

    def test_main_refuses_an_offending_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "Sources")
            os.makedirs(root)
            with open(os.path.join(root, "Offender.swift"), "w", encoding="utf-8") as handle:
                handle.write('let title = AXHelpers.getTitle(element) ?? ""\n'
                             'if title == "Mixer" { }\n')
            proc = subprocess.run(
                [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                              "check-ax-comparisons-use-labelsets.py")],
                capture_output=True, text=True,
                env=dict(os.environ, LPM_AX_COMPARISON_ROOTS=root))
            self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[:300])
            self.assertIn("Mixer", proc.stdout + proc.stderr)

    def test_main_accepts_a_clean_tree(self):
        """The control: without it the case above passes on an entry point that always fails."""
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "Sources")
            os.makedirs(root)
            with open(os.path.join(root, "Fine.swift"), "w", encoding="utf-8") as handle:
                handle.write('let commandName = "x"\nif commandName == "Mixer" { }\n')
            proc = subprocess.run(
                [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                              "check-ax-comparisons-use-labelsets.py")],
                capture_output=True, text=True,
                env=dict(os.environ, LPM_AX_COMPARISON_ROOTS=root))
            self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[:300])


class AgainstTheRealTree(unittest.TestCase):
    def test_the_repository_passes(self):
        self.assertEqual(guard.check(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
