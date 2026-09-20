#!/usr/bin/env python3
"""Drive check-policy-literals-against-canon.py, including the extraction bug it was born with.

The first version of the extractor also swept the `rationale` field and reported 185 unmatched
literals -- most of them whole sentences of documentation. That is not a stricter measurement, it
is a different one, and it would have buried the two real defects in a hundred false ones. So the
first case here is that prose is not a label.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(REPO, "Scripts", "check-policy-literals-against-canon.py")

spec = importlib.util.spec_from_file_location("policy_literals_under_test", GUARD)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

SAMPLE = '''
    static let thing = LabelSet(
        canonical: "Record",
        variants: ["\\u{00A0}녹음", "録音"],
        rationale: "A whole sentence of documentation that mentions Record and 녹음 and must not be counted."
    )
    static let other = LabelSet(
        canonical: "Play",
        variants: [],
        rationale: "Another sentence."
    )
'''


class Extraction(unittest.TestCase):
    def test_only_canonical_and_variants_are_labels(self):
        found = guard.policy_literals(SAMPLE)
        self.assertEqual(found, {"Record", "녹음", "録音", "Play"})

    def test_rationale_prose_is_not_counted(self):
        """The bug that made the first run report 185 instead of 40."""
        for literal in guard.policy_literals(SAMPLE):
            self.assertNotIn("documentation", literal)
            self.assertLess(len(literal), 20)

    def test_the_locales_field_is_harvested_and_its_keys_are_not(self):
        """`locales:` is a third field of Logic-facing strings, added by #882.

        Its VALUES are labels the product types into Logic's Key Commands filter; its keys are
        locale codes. A pattern that stopped at `variants:` would let the whole field into the tree
        unseen -- the blind spot this guard exists to be -- and one that took both halves would put
        `ko` and `ja` into the literal set, which is true and useless.
        """
        source = '''
    static let armToggle = LabelSet(
        canonical: "Toggle Track Record Enable",
        variants: [],
        locales: ["ko": "트랙 녹음 활성화 토글", "ja": "トラック録音可能トグル"],
        rationale: "typed into the Key Commands filter"
    )
'''
        found = guard.policy_literals(source)
        self.assertIn("트랙 녹음 활성화 토글", found)
        self.assertIn("トラック録音可能トグル", found)
        self.assertNotIn("ko", found)
        self.assertNotIn("ja", found)

    def test_a_labelset_without_a_locales_field_still_parses(self):
        self.assertEqual(guard.policy_literals(SAMPLE), {"Record", "녹음", "録音", "Play"})

    def test_cjk_literals_outside_a_labelset_are_harvested(self):
        """74 Logic labels were living outside `LabelSet(` and every part of this saw none of them."""
        source = '''
        if desc == "재생" || desc == "녹음" { return .transport }
        let menu = "파일"
'''
        found = guard.bare_literals(source)
        self.assertEqual(found, {"재생", "녹음", "파일"})

    def test_a_cjk_literal_inside_a_labelset_is_not_double_counted_as_bare(self):
        self.assertEqual(guard.bare_literals(SAMPLE), set())

    def test_a_cjk_literal_in_a_comment_is_not_harvested(self):
        self.assertEqual(guard.bare_literals('    // 재생 은 주석이다\n'), set())

    def test_livekit_harnesses_are_scanned(self):
        """Five CJK literals live in `Scripts/livekit` and the scan read only `Sources/`."""
        files = list(guard.swift_sources())
        self.assertTrue(any(os.path.join("Scripts", "livekit") in f for f in files),
                        "no livekit harness in the scan")

    def test_the_nbsp_in_a_variant_is_folded(self):
        self.assertIn("녹음", guard.policy_literals(SAMPLE))


class Ratchet(unittest.TestCase):
    """The guard is a ratchet on NAMES. It must fail on a gain and on a stale allowance."""

    def _run(self, allowed_literals, policy_source=None, extra=None):
        """Build a temp repo carrying EVERY Swift file that declares a LabelSet.

        Copying only `AXLocalePolicy.swift` made the fixture disagree with the guard the moment the
        guard learned to scan all of `Sources/` -- the four sites in other files then read as
        classifications for literals nobody used. The fixture derives its file list the same way
        the guard does, so it cannot fall behind again.
        """
        import shutil
        root = tempfile.mkdtemp(prefix="policy-canon-")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        os.makedirs(os.path.join(root, "Scripts"))
        os.makedirs(os.path.join(root, "docs"))
        # The WHOLE canon directory: the guard now verifies each classification against the
        # committed absence sets, which needs MANIFEST.json and absence/*.u32 beside it. Copying
        # only POLICY-LITERALS.json made every case fail on a missing manifest rather than on the
        # defect it injected -- a fixture that is a subset of what the guard reads tests nothing.
        shutil.copytree(os.path.join(REPO, "docs", "canon"),
                        os.path.join(root, "docs", "canon"))
        # `docs/observations/` and the two guards loaded by path are part of what this guard
        # reads since the composition-accountability rule landed. A fixture that is a subset of
        # what the guard reads tests nothing -- the comment above says so, and the rule's first
        # version proved it by abstaining here and going unmeasured.
        shutil.copytree(os.path.join(REPO, "docs", "observations"),
                        os.path.join(root, "docs", "observations"))
        for name in ("logic_canon.py", "nibarchive.py",
                     "check-policy-literals-against-canon.py",
                     "check-canon-citations.py", "check-labelsets-are-derived.py"):
            shutil.copy2(os.path.join(REPO, "Scripts", name), os.path.join(root, "Scripts", name))
        policy_rel = os.path.join("Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
        for path in guard.swift_sources():
            rel = os.path.relpath(path, REPO)
            target = os.path.join(root, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if rel == policy_rel and policy_source is not None:
                with open(target, "w", encoding="utf-8") as handle:
                    handle.write(policy_source)
            else:
                shutil.copy2(path, target)
        literals = dict(allowed_literals)
        for name in (extra or []):
            literals[name] = "nowhere"
        with open(os.path.join(root, "docs", "canon", "POLICY-LITERALS.json"), "w",
                  encoding="utf-8") as handle:
            json.dump({"literals": literals}, handle, ensure_ascii=False)
        return subprocess.run(
            [sys.executable, os.path.join(root, "Scripts",
                                          "check-policy-literals-against-canon.py")],
            capture_output=True, text=True)

    def _current_allowed(self):
        with open(os.path.join(REPO, "docs", "canon",
                               "POLICY-LITERALS.json"), encoding="utf-8") as handle:
            return json.load(handle)["literals"]

    def test_the_real_tree_passes(self):
        result = self._run(self._current_allowed())
        self.assertEqual(result.returncode, 0, result.stderr)


    def test_the_guard_refuses_a_composition_nobody_witnessed(self):
        """THE CASE THAT DRIVES THE GUARD, not the predicate.

        The first version of this rule was covered only by cases calling
        `_composition_is_accounted_for` directly, so deleting the guard's `elif` branch produced no
        failure at all -- the same defect this session spent the day removing, committed again by
        the change that removes it.

        `%@ 보기` and the noun `트랙` decompose `트랙 보기`, a menu item Logic composes nowhere.
        """
        real = os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
        with open(real, encoding="utf-8") as handle:
            policy = handle.read()
        anchor = "    static let regionHelpKeyword = LabelSet("
        self.assertEqual(policy.count(anchor), 1)
        fixture = (
            '    static let auditInventedComposition = LabelSet(\n'
            '        canonical: "트랙 보기",\n'
            '        variants: [],\n'
            '        rationale: "fixture"\n'
            '    )\n\n'
        )
        allowed = dict(self._current_allowed())
        allowed["트랙 보기"] = "composed_value"
        result = self._run(allowed, policy_source=policy.replace(anchor, fixture + anchor, 1))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("DECOMPOSABILITY alone", result.stderr)

    def test_a_literal_logic_does_not_ship_fails(self):
        with open(os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility",
                               "AXLocalePolicy.swift"), encoding="utf-8") as handle:
            source = handle.read()
        injected = source + '''
    static let injectedForTest = LabelSet(
        canonical: "a string no shipped application contains anywhere 91xq",
        variants: [],
        rationale: "injected by the guard's own test"
    )
'''
        result = self._run(self._current_allowed(), policy_source=injected)
        self.assertEqual(result.returncode, 1)
        self.assertIn("classified nowhere", result.stderr)

    def test_the_summary_line_names_every_root_the_guard_reads(self):
        """The one sentence a reader sees must not describe a narrower scan than the guard does.

        It said "across every LabelSet under Sources/" while `SWIFT_ROOTS` had held
        `Scripts/livekit` since the commit that added it -- and the comment on that constant
        records livekit being added BECAUSE it was not scanned. So the summary asserted exactly the
        gap the fix had closed, to anyone who read the output instead of the source.
        """
        out = subprocess.run([sys.executable, GUARD], capture_output=True, text=True)
        line = (out.stdout or "").strip().splitlines()[-1] if out.stdout.strip() else ""
        self.assertTrue(line, "the guard printed nothing, so there is no summary to check")
        for root in guard.SWIFT_ROOTS:
            self.assertIn(os.path.relpath(root, REPO), line,
                          f"the summary hides a root it reads: {line}")

    # -- the decoration table: which kind of control may add what ------------------------------
    def test_a_menu_item_may_carry_an_ellipsis(self):
        rules = guard.decoration_rules()
        self.assertEqual(guard.kind_of("setLocatorsMenuItem", rules), "menu_item")
        self.assertIn("…", rules["kinds"]["menu_item"]["allows_trailing"])

    def test_a_field_label_may_carry_a_colon(self):
        rules = guard.decoration_rules()
        self.assertEqual(guard.kind_of("controlSurfaceInputPortLabel", rules), "field_label")
        self.assertIn(":", rules["kinds"]["field_label"]["allows_trailing"])

    def test_a_name_declaring_no_kind_may_add_nothing(self):
        """The default is the whole point: punctuation costs you naming what draws it."""
        rules = guard.decoration_rules()
        self.assertEqual(guard.kind_of("someControl", rules), "default")
        self.assertEqual(rules["default"]["allows_trailing"], [])

    def test_the_longest_matching_suffix_wins(self):
        """`Menu` and `MenuItem` both match a name ending in MenuItem, and they are not the same
        kind. Shortest-first would classify every menu item as a menu."""
        rules = {"kinds": {"menu": {"name_suffixes": ["Menu"], "allows_trailing": []},
                           "menu_item": {"name_suffixes": ["MenuItem"], "allows_trailing": ["…"]}},
                 "default": {"allows_trailing": []}}
        self.assertEqual(guard.kind_of("fileMenuItem", rules), "menu_item")

    def test_every_rule_in_the_table_is_witnessed(self):
        """A convention somebody remembered is not a rule. Each kind names live evidence."""
        for kind, block in guard.decoration_rules()["kinds"].items():
            with self.subTest(kind=kind):
                seen = block.get("witnessed") or {}
                self.assertGreater(seen.get("occurrences", 0), 0, f"{kind} cites no reading")
                path = os.path.join(REPO, "docs", "observations", seen.get("in", ""))
                self.assertTrue(os.path.exists(path), f"{kind} cites {seen.get('in')!r}, missing")
                self.assertIn(seen["example"], open(path, encoding="utf-8").read(),
                              f"{kind}'s example is not in the evidence it names")

    def test_an_allowance_for_a_literal_that_is_gone_fails(self):
        result = self._run(self._current_allowed(), extra=["a literal nobody writes 77zz"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("outlived its reason", result.stderr)


class ComposedLiteralsAreNotNowhere(unittest.TestCase):
    """Logic BUILDS some labels. Answering `nowhere` for one is the classifier unable to ask.

    `Show Library` is in no corpus in any locale, and a running Korean Logic's View menu says the
    Korean form of it. Apple ships `Show %@` and the Library noun; the label is assembled. These
    cases drive the reverse-composition that closed that gap, and the one that matters most is the
    LAST: a template with no text of its own would explain every string ever written.
    """

    def test_a_template_decomposes_a_literal_it_explains(self):
        self.assertEqual(guard._decompose("Afficher Bibliothèque", "Afficher %@"), "Bibliothèque")

    def test_a_literal_the_template_does_not_fit_is_refused(self):
        self.assertIsNone(guard._decompose("Masquer Bibliothèque", "Afficher %@"))

    def test_a_suffix_template_decomposes_from_the_other_end(self):
        self.assertEqual(guard._decompose("라이브러리 보기", "%@ 보기"), "라이브러리")

    def test_a_bare_placeholder_explains_nothing(self):
        """Logic ships 8 rows whose value is exactly `%@`; one of those would fit any string."""
        self.assertIsNone(guard._decompose("anything at all", "%@"))

    def test_a_template_with_one_character_of_its_own_explains_nothing(self):
        self.assertIsNone(guard._decompose("xLibrary", "x%@"))

    def test_an_empty_noun_is_not_a_composition(self):
        self.assertIsNone(guard._decompose("Show ", "Show %@"))

    def test_the_committed_classification_agrees_with_the_offline_check(self):
        """Every `composed_value` in the tree must be re-derivable from the committed templates."""
        with open(guard.CLASSIFICATION, encoding="utf-8") as handle:
            committed = json.load(handle)["literals"]
        composed = [text for text, where in committed.items() if where == "composed_value"]
        self.assertTrue(composed, "no literal is classified composed, so this case checks nothing")
        unexplained = [text for text in composed if not guard._composed_offline(text)]
        self.assertEqual(unexplained, [])

    def test_every_composed_value_is_witnessed_or_declared(self):
        """Decomposability is not composition.

        `composed_value` is the one classification that exempts a literal from the `nowhere`
        ledger without any corpus holding it, so a wrong guess escapes counting entirely. A review
        walked `트랙 보기` through it -- `%@ 보기` plus the noun `트랙`, a menu item Logic composes
        nowhere -- and it classified cleanly.

        Two things account for a composition, and both already exist here: an observation record
        NAMES the literal, or a LabelSet DECLARES the composition in LABELSETS-WITHOUT-A-ROW.json,
        where every factor is re-proved against the row's digest per locale on every run.
        """
        with open(guard.CLASSIFICATION, encoding="utf-8") as handle:
            committed = json.load(handle)["literals"]
        composed = [text for text, where in committed.items() if where == "composed_value"]
        self.assertTrue(composed, "no literal is classified composed, so this case checks nothing")
        unaccounted = [t for t in composed if not guard._composition_is_accounted_for(t)]
        self.assertEqual(unaccounted, [])

    def test_a_decomposable_literal_nobody_witnessed_is_not_accounted_for(self):
        """The control, and the case the rule exists for. Without it the case above passes on a
        predicate that answers True for everything."""
        self.assertTrue(guard._composed_offline("트랙 보기"),
                        "the fixture must decompose, or it tests the wrong branch")
        self.assertFalse(guard._composition_is_accounted_for("트랙 보기"))


class MissingEvidenceIsRefused(unittest.TestCase):
    """A rule that cannot be applied must stop somebody, not print a note beside exit 0.

    The composition rule needs `docs/observations/`, `LABELSETS-WITHOUT-A-ROW.json` and two readers.
    When one was gone it printed a note to stderr and the run exited 0 with fifteen literals
    unchecked -- recorded as a limit and closed here.
    """

    def _tree(self, omit):
        import shutil
        root = tempfile.mkdtemp(prefix="policy-canon-missing-")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        os.makedirs(os.path.join(root, "Scripts"))
        os.makedirs(os.path.join(root, "docs"))
        shutil.copytree(os.path.join(REPO, "docs", "canon"), os.path.join(root, "docs", "canon"))
        shutil.copytree(os.path.join(REPO, "docs", "observations"),
                        os.path.join(root, "docs", "observations"))
        for name in ("logic_canon.py", "nibarchive.py",
                     "check-policy-literals-against-canon.py",
                     "check-canon-citations.py", "check-labelsets-are-derived.py"):
            shutil.copy2(os.path.join(REPO, "Scripts", name), os.path.join(root, "Scripts", name))
        for path in guard.swift_sources():
            target = os.path.join(root, os.path.relpath(path, REPO))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(path, target)
        if omit:
            victim = os.path.join(root, omit)
            shutil.rmtree(victim) if os.path.isdir(victim) else os.remove(victim)
        return subprocess.run(
            [sys.executable, os.path.join(root, "Scripts",
                                          "check-policy-literals-against-canon.py")],
            capture_output=True, text=True)

    def test_a_tree_carrying_everything_passes(self):
        """The control. Without it every case below passes on a guard that refuses every tree."""
        proc = self._tree(omit=None)
        self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[-400:])

    def test_losing_the_observations_is_refused(self):
        proc = self._tree(omit="docs/observations")
        self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[-400:])
        self.assertIn("NOT APPLIED", proc.stdout + proc.stderr)

    def test_losing_the_labelset_declarations_is_refused(self):
        proc = self._tree(omit="docs/canon/LABELSETS-WITHOUT-A-ROW.json")
        self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[-400:])
        self.assertIn("LABELSETS-WITHOUT-A-ROW.json", proc.stdout + proc.stderr)

    def test_losing_a_reader_is_refused(self):
        """"I could not read it" is not "it says no" -- but it is not "fine" either."""
        proc = self._tree(omit="Scripts/check-labelsets-are-derived.py")
        self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[-400:])
        self.assertIn("NOT APPLIED", proc.stdout + proc.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
