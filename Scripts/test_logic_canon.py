#!/usr/bin/env python3
"""Drive Scripts/logic_canon.py, including the failure it was written to make impossible.

The decoding test is the one that matters. A parser that reads a UTF-8 `.strings` file as UTF-16
raises nothing, produces mojibake, and parses to zero entries -- and zero entries looks exactly
like a file with nothing in it. That is not hypothetical: `Carlton.strings` was reported empty this
way and holds 940 entries. So the test here does not check that the good path works; it feeds the
parser the exact bytes that fooled the earlier one and requires the right answer.

The round trip over the real corpus is the other half. It composes an AXHelp the way Logic does,
with and without a runtime prefix, and requires the parser to name the key it started from. Run
against every key rather than a sample, because the interesting cases are the rare ones.
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "/Applications/Logic Pro.app"


def _load():
    path = os.path.join(REPO, "Scripts", "logic_canon.py")
    spec = importlib.util.spec_from_file_location("logic_canon_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


canon = _load()
sys.path.insert(0, os.path.join(REPO, "Scripts"))
import nibarchive  # noqa: E402  -- after REPO is on the path
HAVE_LOGIC = os.path.isdir(APP)


class Decoding(unittest.TestCase):
    def test_utf8_without_a_bom_is_not_read_as_utf16(self):
        raw = '"key" = "값";\n'.encode("utf-8")
        self.assertEqual(canon.parse_strings(raw), {"key": "값"})

    def test_utf16_with_a_bom_round_trips(self):
        raw = '"key" = "값";\n'.encode("utf-16")
        self.assertEqual(canon.parse_strings(raw), {"key": "값"})

    def test_undecodable_bytes_raise_instead_of_parsing_to_nothing(self):
        with self.assertRaises(canon.CanonDecodeError):
            canon.parse_strings(b"\xff\xfe\x00")

    def test_binary_plist_strings_are_parsed(self):
        import plistlib
        raw = plistlib.dumps({"k": "v"}, fmt=plistlib.FMT_BINARY)
        self.assertTrue(canon.looks_binary_plist(raw))
        self.assertEqual(canon.parse_strings(raw), {"k": "v"})

    def test_comments_and_escapes(self):
        raw = ('/* a comment */\n'
               '// another\n'
               '"a\\"b" = "line\\nbreak \\U00A0 end";\n').encode("utf-8")
        table = canon.parse_strings(raw)
        self.assertEqual(list(table), ['a"b'])
        self.assertIn("\n", table['a"b'])

    def test_an_unterminated_string_is_refused(self):
        with self.assertRaises(canon.CanonDecodeError):
            canon.parse_strings(b'"key" = "value;\n')


class Normalization(unittest.TestCase):
    def test_nbsp_folds_to_a_space(self):
        self.assertEqual(canon.normalize("Logic Pro"), "Logic Pro")

    def test_digests_agree_across_the_nbsp(self):
        self.assertEqual(canon.digest("Smart Controls"), canon.digest("Smart Controls"))

    def test_none_is_refused_rather_than_treated_as_empty(self):
        with self.assertRaises(canon.CanonError):
            canon.normalize(None)


class References(unittest.TestCase):
    def test_round_trip(self):
        ref = canon.CanonRef("quickhelp", "QuickHelp", "ko", "KCE_024_Record", "composed")
        self.assertEqual(canon.CanonRef.parse(str(ref)), ref)

    def test_a_key_holding_a_slash_and_a_hash_survives(self):
        ref = canon.CanonRef("strings", "A.framework/Resources/Localizable.strings", "ko",
                             "a/b#c = %@", "value")
        self.assertEqual(canon.CanonRef.parse(str(ref)), ref)

    def test_a_reference_never_contains_whitespace(self):
        """The bug that made every `strings` citation unresolvable, kept so it cannot return.

        `find_refs` scans prose with a non-whitespace pattern. A space inside a reference truncates
        the scan, and the shorter string still PARSES -- so it resolved to nothing and reported a
        missing key rather than a malformed reference. Real keys carry spaces constantly:
        `Show/Hide Automation`, `Display %@ Channel Strips`.
        """
        ref = canon.CanonRef("strings", "A/B.strings", "ko", "Display %@ Channel Strips", "value")
        self.assertNotIn(" ", str(ref))
        body = f"we cite {ref} in the middle of a sentence"
        self.assertEqual(canon.find_refs(body), [str(ref)])
        self.assertEqual(canon.CanonRef.parse(canon.find_refs(body)[0]), ref)

    def test_malformed_references_are_refused(self):
        for bad in ("quickhelp/ko/K#Title", "logic-canon://quickhelp/ko/K", "logic-canon://"):
            with self.assertRaises(canon.CanonRefError):
                canon.CanonRef.parse(bad)

    def test_find_refs_picks_references_out_of_prose(self):
        body = ("We rely on logic-canon://quickhelp/QuickHelp/en/KCE_024_Record#Title and also\n"
                "on logic-canon://madsp/Compressor/-/1#name for the threshold.")
        self.assertEqual(len(canon.find_refs(body)), 2)


class AbsenceSet(unittest.TestCase):
    def test_a_present_value_is_never_reported_absent(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            saved = canon.ABSENCE_DIR
            canon.ABSENCE_DIR = tmp
            try:
                canon.write_absence("t", "ko", ["alpha", "beta", "gamma"])
                for present in ("alpha", "beta", "gamma"):
                    self.assertFalse(canon.is_absent("t", "ko", present), present)
                # Absence can be wrong only in the safe direction, so this asserts the direction
                # rather than the outcome for one arbitrary string.
                self.assertTrue(canon.is_absent("t", "ko", "a string nothing wrote"))
            finally:
                canon.ABSENCE_DIR = saved

    def test_the_ledger_index_forgives_case_and_nothing_else(self):
        # #981: the question a LabelSet asks. `Straße`/`STRASSE` is Unicode case folding, which is
        # what Foundation's `caseInsensitiveCompare` does; the colon and the dropped letter are not.
        import tempfile
        corpus = {"t": {"de": {canon.normalize(v) for v in ("Mixer", "Straße")}}}
        wanted = {"mixer", "MIXER", "strasse", "STRASSE", "Mixer", "Mixer:", "mixr", "Mix er"}
        with tempfile.TemporaryDirectory() as tmp:
            saved = canon.LEDGER_DIR
            canon.LEDGER_DIR = tmp
            try:
                canon.write_ledger_casefold(canon.ledger_casefold_rows(corpus, wanted))
                for same in ("Mixer", "mixer", "MIXER", "strasse", "STRASSE"):
                    self.assertTrue(canon.ships_up_to_case("t", "de", same), same)
                for other in ("Mixer:", "mixr", "Mix er"):
                    self.assertFalse(canon.ships_up_to_case("t", "de", other), other)
                self.assertFalse(canon.ships_up_to_case("t", "fr", "mixer"))
                self.assertFalse(canon.ships_up_to_case("u", "de", "mixer"))
            finally:
                canon.LEDGER_DIR = saved

    def test_a_string_whose_prefix_collides_with_a_shipped_one_is_not_credited(self):
        # The review of #991 found these two: different strings, one 32-bit prefix. The absence
        # set cannot tell them apart, which is safe for an absence claim and wrong for a credit.
        shipped, colliding = "sample8454", "sample21529"
        self.assertEqual(canon._u32(canon.fold_case(shipped)), canon._u32(canon.fold_case(colliding)))
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            saved_ledger, saved_absence = canon.LEDGER_DIR, canon.ABSENCE_DIR
            canon.LEDGER_DIR = canon.ABSENCE_DIR = tmp
            try:
                canon.write_absence("t", "de", [shipped])
                self.assertFalse(canon.is_absent("t", "de", colliding))   # the set is fooled
                canon.write_ledger_casefold(canon.ledger_casefold_rows(
                    {"t": {"de": {shipped}}}, {shipped, colliding}))
                self.assertTrue(canon.ships_up_to_case("t", "de", shipped))
                self.assertFalse(canon.ships_up_to_case("t", "de", colliding))
            finally:
                canon.LEDGER_DIR, canon.ABSENCE_DIR = saved_ledger, saved_absence

    def test_a_missing_or_malformed_ledger_index_raises_rather_than_answering(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            saved = canon.LEDGER_DIR
            canon.LEDGER_DIR = tmp
            try:
                with self.assertRaises(canon.CanonError):
                    canon.ships_up_to_case("t", "de", "mixer")
                with open(canon.ledger_casefold_path(), "w", encoding="utf-8") as handle:
                    handle.write("t\tde\n")
                with self.assertRaises(canon.CanonError):
                    canon.ships_up_to_case("t", "de", "mixer")
            finally:
                canon.LEDGER_DIR = saved

    def test_an_absence_set_that_does_not_exist_refuses_rather_than_answering(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            saved = canon.ABSENCE_DIR
            canon.ABSENCE_DIR = tmp
            try:
                with self.assertRaises(canon.CanonError):
                    canon.is_absent("nothing", "ko", "x")
            finally:
                canon.ABSENCE_DIR = saved


class AXHelpParser(unittest.TestCase):
    """The parser must anchor on the QuickHelp suffix and must not split on punctuation."""

    def _index(self, compositions, min_anchor=canon.DEFAULT_MIN_ANCHOR):
        by_composed = {}
        for composed, key in compositions:
            by_composed.setdefault(canon.normalize(composed), []).append(key)
        return canon.QuickHelpIndex("ko", by_composed, min_anchor=min_anchor)

    def test_a_whole_value_is_exact(self):
        index = self._index([("녹음 버튼. 선택한 트랙에 녹음합니다.", "KCE_024_Record")])
        match = index.parse_axhelp("녹음 버튼. 선택한 트랙에 녹음합니다.")
        self.assertEqual((match.tier, match.key, match.prefix), ("exact", "KCE_024_Record", ""))

    def test_a_runtime_prefix_is_separated_and_the_key_still_resolves(self):
        index = self._index([("녹음 버튼. 선택한 트랙에 녹음합니다.", "KCE_024_Record")])
        match = index.parse_axhelp("녹음   R, 녹음 버튼. 선택한 트랙에 녹음합니다.")
        self.assertEqual(match.tier, "suffix")
        self.assertEqual(match.key, "KCE_024_Record")
        self.assertEqual(match.prefix, "녹음   R")

    def test_a_prefix_containing_commas_and_full_stops_does_not_break_the_parse(self):
        """The reading that makes splitting on the comma indefensible."""
        composed = "튜너 버튼. 시스템에 연결된 악기를 조정합니다."
        index = self._index([(composed, "TRA_073_TunerButton")])
        value = ("이 컨트롤을 사용할 수 없습니다. 원인: 오디오 트랙이 선택되지 않았습니다., " + composed)
        match = index.parse_axhelp(value)
        self.assertEqual(match.key, "TRA_073_TunerButton")
        self.assertEqual(match.prefix, "이 컨트롤을 사용할 수 없습니다. 원인: 오디오 트랙이 선택되지 않았습니다.")

    def test_a_shared_composition_yields_no_single_key(self):
        index = self._index([("같은 문구입니다. 정말로 같습니다.", "A"),
                             ("같은 문구입니다. 정말로 같습니다.", "B")])
        match = index.parse_axhelp("같은 문구입니다. 정말로 같습니다.")
        self.assertIsNone(match.key)
        self.assertEqual(sorted(match.keys), ["A", "B"])

    def test_the_longest_composition_wins_when_one_is_a_suffix_of_another(self):
        short, long = "짧은 설명입니다. 끝.", "긴 설명입니다. 짧은 설명입니다. 끝."
        index = self._index([(short, "SHORT"), (long, "LONG")])
        self.assertEqual(index.parse_axhelp(long).key, "LONG")

    def test_a_truncated_reading_is_labelled_rather_than_passed_off_as_whole(self):
        composed = "메트로놈 버튼. 재생 또는 녹음 중에 클릭을 재생합니다."
        index = self._index([(composed, "TRA_052_MetronomeButton")])
        match = index.parse_axhelp(composed[:24])
        self.assertEqual(match.tier, "truncated")
        self.assertEqual(match.key, "TRA_052_MetronomeButton")

    def test_an_ambiguous_truncation_resolves_to_nothing(self):
        index = self._index([("공통 접두입니다. 그리고 갑니다.", "A"),
                             ("공통 접두입니다. 그러나 옵니다.", "B")])
        self.assertIsNone(index.parse_axhelp("공통 접두입니다."))

    def test_a_string_shorter_than_the_anchor_floor_never_matches(self):
        index = self._index([("짧다", "SHORT")], min_anchor=12)
        self.assertIsNone(index.parse_axhelp("짧다"))


class Templates(unittest.TestCase):
    def test_a_string_with_no_conversion_is_not_a_template(self):
        self.assertIsNone(canon.template_to_regex("plain text"))

    def test_an_all_wildcard_template_is_refused(self):
        """The defect this floor was added for, kept as a test so it cannot come back.

        `%1$@ %2$@` matches any string containing a space. Compiled, it claimed the one live AXHelp
        value an exhaustive scan of the bundle could not find, and turned 113 of 114 into a false
        114 of 114.
        """
        self.assertIsNone(canon.template_to_regex("%1$@ %2$@"))
        self.assertIsNone(canon.template_to_regex("%@"))
        self.assertIsNone(canon.template_to_regex("%@ - %@"))

    def test_a_template_with_real_literal_text_compiles_and_captures(self):
        pattern = canon.template_to_regex("%@ 채널 스트립 표시")
        self.assertIsNotNone(pattern)
        self.assertEqual(pattern.match("Aux 채널 스트립 표시").groups(), ("Aux",))

    def test_a_value_two_templates_could_render_resolves_to_neither(self):
        """The same refusal `AXHelpMatch.key` makes when a composition is shared.

        `templates` is sorted by length and the first hit used to win, which is an arbitrary choice
        between two templates of similar specificity. Measured in ko: 27 templates render another
        canonical value outright, and no live value matches two -- so this refuses a hazard rather
        than a known failure.
        """
        index = canon.StringsIndex("ko", {}, [
            (canon.template_to_regex("Channel strip %@ here"), "u", "A", "Channel strip %@ here"),
            (canon.template_to_regex("Channel %@ here"), "u", "B", "Channel %@ here"),
        ])
        self.assertIsNone(index.lookup("Channel strip seven here"))

    def test_a_value_only_one_template_renders_resolves(self):
        index = canon.StringsIndex("ko", {}, [
            (canon.template_to_regex("Channel strip %@ here"), "u", "A", "Channel strip %@ here"),
        ])
        found = index.lookup("Channel strip seven here")
        self.assertEqual((found.key, found.tier, found.arguments), ("A", "template", ("seven",)))

    def test_a_template_does_not_match_a_value_it_cannot_render(self):
        pattern = canon.template_to_regex("%@ 채널 스트립 표시")
        self.assertIsNone(pattern.match("전혀 다른 문자열입니다"))

    def test_a_literal_percent_is_not_a_wildcard(self):
        pattern = canon.template_to_regex("Gain %@ of 100%%")
        self.assertIsNotNone(pattern)
        self.assertIsNone(pattern.match("Gain 3 of 100"))


class Layering(unittest.TestCase):
    """The resolver tries QuickHelp first because it names a control, strings second because a
    string is reused. Order is policy, so it is asserted rather than left to reading."""

    def _resolver(self, composed, strings_table):
        resolver = canon.AXStringResolver.__new__(canon.AXStringResolver)
        resolver.locale = "ko"
        by_composed = {canon.normalize(k): [v] for k, v in composed.items()}
        resolver.quickhelp = canon.QuickHelpIndex("ko", by_composed)
        by_value, templates = {}, []
        for key, value in strings_table.items():
            folded = canon.normalize(value)
            by_value.setdefault(folded, []).append(("unit", key))
            pattern = canon.template_to_regex(folded)
            if pattern is not None:
                templates.append((pattern, "unit", key, folded))
        templates.sort(key=lambda row: -len(row[3]))
        resolver.strings = canon.StringsIndex("ko", by_value, templates)
        return resolver

    def test_quickhelp_wins_when_both_could_answer(self):
        shared = "같은 문자열입니다. 정말로."
        resolver = self._resolver({shared: "QH_KEY"}, {"STR_KEY": shared})
        self.assertEqual(resolver.resolve(shared).source, "quickhelp")

    def test_a_shortcut_suffix_falls_through_to_strings(self):
        resolver = self._resolver({}, {"Show/Hide Flex": "Flex 보기/가리기"})
        found = resolver.resolve("Flex 보기/가리기   ⌘F")
        self.assertEqual((found.source, found.tier, found.key, found.suffix),
                         ("strings", "shortcut", "Show/Hide Flex", "⌘F"))

    def test_a_value_no_source_explains_resolves_to_nothing(self):
        resolver = self._resolver({}, {"k": "something else entirely"})
        self.assertIsNone(resolver.resolve("이 버튼을 누르면 윈도우를 확대/축소합니다."))


class TheLoadBearingComparisons(unittest.TestCase):
    """Cases for the functions a mutation run found nothing was watching.

    Review 2026-09-15 mutated eighteen behaviours in `logic_canon.py` and ten survived this suite --
    including `check_citation`'s digest comparison, which the module docstring calls the whole point
    of the citation format, and `_u32`'s width, which the absence set's collision argument rests on.
    Each case below kills one of those mutants.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="canon-widths-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_short_digest_is_twelve_hex(self):
        """The index's digest width. The collision argument is stated over 48 bits."""
        self.assertEqual(len(canon.short_digest("anything")), 12)
        self.assertTrue(canon.digest("anything").startswith(canon.short_digest("anything")))

    def test_the_absence_element_is_the_first_32_bits_of_the_same_digest(self):
        """`verify_index_against_absence` joins the two structures on this identity."""
        text = "a value"
        self.assertEqual(canon._u32(text), int(canon.short_digest(text)[:8], 16))
        self.assertLess(canon._u32(text), 2 ** 32)

    def test_the_published_false_positive_rate_is_over_the_32_bit_space(self):
        self.assertAlmostEqual(canon.absence_false_positive(2 ** 32), 1.0)
        self.assertAlmostEqual(canon.absence_false_positive(4294), 1e-6, places=9)
        self.assertEqual(canon.absence_false_positive(0), 0.0)

    def test_normalize_composes_decomposed_korean(self):
        """The NBSP fold was tested and the NFC fold was not. Hangul reaches us both ways."""
        decomposed = "\u1100\u1161"          # ᄀ + ᅡ
        self.assertEqual(canon.normalize(decomposed), "\uac00")   # 가
        self.assertEqual(canon.digest(decomposed), canon.digest("\uac00"))

    def test_a_reference_with_an_empty_key_is_refused(self):
        with self.assertRaises(canon.CanonRefError):
            canon.CanonRef.parse("logic-canon://quickhelp/QuickHelp/ko/#composed")

    def test_decoding_is_injective(self):
        """`100%` and `100%25` both decoded to `100%`, so two references named one key."""
        with self.assertRaises(canon.CanonRefError):
            canon._pct_decode("100%")
        self.assertEqual(canon._pct_decode("100%25"), "100%")

    def test_absence_counts_are_checked_against_the_manifest(self):
        import struct
        saved, canon.ABSENCE_DIR = canon.ABSENCE_DIR, self.tmp
        try:
            canon.write_absence("t", "ko", ["a-value", "b-value", "c-value"])
            manifest = {"sources": {"t": {"absence_entries": {"ko": 3}}}}
            self.assertEqual(canon.verify_absence_counts(manifest), [])
            table = canon.load_absence("t", "ko")[:-1]
            with open(canon.absence_path("t", "ko"), "wb") as handle:
                handle.write(b"LCA1" + struct.pack(">I", len(table))
                             + b"".join(struct.pack(">I", x) for x in table))
            problems = canon.verify_absence_counts(manifest)
            self.assertTrue(any("lost entries" in p for p in problems), problems)
        finally:
            canon.ABSENCE_DIR = saved

    def test_the_ledger_index_is_pinned_like_the_index_and_absence_sets(self):
        # Read for PRESENCE, so an added row is the forgery that matters: it would make a string
        # Apple does not ship read as `derived`. The artifact digests are what catch that edit.
        saved, canon.LEDGER_DIR = canon.LEDGER_DIR, self.tmp
        try:
            canon.write_ledger_casefold({("t", "ko", canon.short_digest("a-value"))})
            pinned = canon.artifact_digests()
            path = os.path.relpath(canon.ledger_casefold_path(), canon.CANON_DIR)
            self.assertIn(path, pinned)
            with open(canon.ledger_casefold_path(), "a", encoding="utf-8") as handle:
                handle.write(f"t\tko\t{canon.short_digest('forged')}\n")
            problems = canon.verify_artifacts({"artifacts": pinned})
            self.assertTrue(any(path in p and "does not match" in p for p in problems), problems)
        finally:
            canon.LEDGER_DIR = saved

    def test_a_malformed_percent_escape_raises_rather_than_decoding_to_something(self):
        with self.assertRaises(canon.CanonRefError):
            canon._pct_decode("%ZZ")

    def test_an_absence_set_without_its_magic_is_refused(self):
        path = os.path.join(self.tmp, "t.ko.u32")
        with open(path, "wb") as handle:
            handle.write(b"XXXX" + (0).to_bytes(4, "big"))
        saved, canon.ABSENCE_DIR = canon.ABSENCE_DIR, self.tmp
        try:
            with self.assertRaises(canon.CanonError):
                canon.load_absence("t", "ko")
        finally:
            canon.ABSENCE_DIR = saved

    def test_an_absence_set_whose_length_disagrees_with_its_header_is_refused(self):
        path = os.path.join(self.tmp, "t.ko.u32")
        with open(path, "wb") as handle:
            handle.write(b"LCA1" + (5).to_bytes(4, "big") + b"\x00" * 4)
        saved, canon.ABSENCE_DIR = canon.ABSENCE_DIR, self.tmp
        try:
            with self.assertRaises(canon.CanonError):
                canon.load_absence("t", "ko")
        finally:
            canon.ABSENCE_DIR = saved

    def test_decode_refuses_bytes_that_only_decode_with_a_nul_in_them(self):
        """The cheapest signal that a UTF-16 guess was wrong on UTF-8 input."""
        self.assertIsNone(canon.decode_bytes(b"a\x00b\x00c"))

    def test_an_index_row_with_the_wrong_field_count_is_refused(self):
        os.makedirs(os.path.join(self.tmp, "index"), exist_ok=True)
        path = os.path.join(self.tmp, "index", "t.tsv")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("a\tb\tc\n")
        saved, canon.INDEX_DIR = canon.INDEX_DIR, os.path.join(self.tmp, "index")
        try:
            with self.assertRaises(canon.CanonError):
                canon.load_index("t")
        finally:
            canon.INDEX_DIR = saved


class CitationAndArtifactChecks(unittest.TestCase):
    """`check_citation` and `verify_artifacts` driven directly, against a scratch canon directory."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="canon-check-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.saved = (canon.INDEX_DIR, canon.ABSENCE_DIR, canon.CANON_DIR)
        canon.CANON_DIR = self.tmp
        canon.INDEX_DIR = os.path.join(self.tmp, "index")
        canon.ABSENCE_DIR = os.path.join(self.tmp, "absence")
        self.addCleanup(self._restore)
        canon.write_index("t", {("U", "ko", "K", "value"): canon.short_digest("REAL VALUE")})
        canon.write_absence("t", "ko", ["REAL VALUE"])

    def _restore(self):
        canon.INDEX_DIR, canon.ABSENCE_DIR, canon.CANON_DIR = self.saved

    def test_the_right_value_passes(self):
        canon.check_citation("logic-canon://t/U/ko/K#value", "REAL VALUE")

    def test_one_character_wrong_fails(self):
        with self.assertRaises(canon.CanonResolveError) as caught:
            canon.check_citation("logic-canon://t/U/ko/K#value", "REAL VALUEx")
        self.assertIn("Logic's value hashes to", str(caught.exception))

    def test_a_reference_nobody_pinned_fails(self):
        with self.assertRaises(canon.CanonResolveError):
            canon.check_citation("logic-canon://t/U/ko/OTHER#value", "REAL VALUE")

    def test_verify_artifacts_notices_an_edited_index(self):
        manifest = {"artifacts": canon.artifact_digests()}
        self.assertEqual(canon.verify_artifacts(manifest), [])
        with open(os.path.join(canon.INDEX_DIR, "t.tsv"), "a", encoding="utf-8") as handle:
            handle.write("U\tko\tINVENTED\tvalue\t000000000000\n")
        problems = canon.verify_artifacts(manifest)
        self.assertTrue(any("does not match the digest" in p for p in problems), problems)

    def test_verify_artifacts_refuses_a_manifest_with_no_claim(self):
        problems = canon.verify_artifacts({})
        self.assertTrue(any("carries no `artifacts` block" in p for p in problems), problems)

    def test_verify_artifacts_notices_a_file_nobody_pinned(self):
        manifest = {"artifacts": canon.artifact_digests()}
        canon.write_index("extra", {("U", "ko", "K", "value"): "000000000000"})
        problems = canon.verify_artifacts(manifest)
        self.assertTrue(any("is on disk and is not declared" in p for p in problems), problems)

    def test_an_index_row_whose_value_is_in_no_absence_set_is_refused(self):
        """The one external check an offline run has: a row not in the corpus was not taken from it."""
        self.assertEqual(canon.verify_index_against_absence(), [])
        canon.write_index("t", {("U", "ko", "K", "value"): canon.short_digest("REAL VALUE"),
                                ("U", "ko", "FORGED", "value"): canon.short_digest("NEVER SHIPPED")})
        problems = canon.verify_index_against_absence()
        self.assertTrue(any("FORGED" in p for p in problems), problems)



class ACitationWithoutAKey(unittest.TestCase):
    """The key was where the last human judgement lived, and the code never needed it.

    `추가` is the value of `Add` and of `Label_For_Drummer_Editor_GhostNotes_Slider|||More`. Both
    resolve, both pass every check, and only one MEANS what a change is about — so a key citation
    asked somebody to choose, 164 times out of 227, with nothing mechanical to check the choice.

    A `LabelSet` matches Logic at runtime BY VALUE. It never sees a key. So a value citation
    asserts exactly what the code relies on, and the part that needed judgement is simply not in
    the claim any more.
    """

    def test_a_value_reference_parses_and_round_trips(self):
        ref = canon.CanonRef.parse("logic-canon://strings/ko#value")
        self.assertTrue(ref.is_value_citation)
        self.assertEqual((ref.source, ref.locale, ref.field), ("strings", "ko", "value"))
        self.assertEqual(str(ref), "logic-canon://strings/ko#value")

    def test_a_key_reference_is_not_a_value_citation(self):
        ref = canon.CanonRef.parse(
            "logic-canon://quickhelp/QuickHelp/ko/KCE_024_Record#composed")
        self.assertFalse(ref.is_value_citation)

    def test_a_value_reference_survives_find_refs(self):
        """It has fewer segments than a key reference; the scanner must still take it whole."""
        ref = "logic-canon://strings/ko#value"
        self.assertEqual(canon.find_refs(f"as pinned in {ref} and nowhere else.\n"), [ref])

    def test_prose_may_show_the_shape_without_stating_a_citation(self):
        """A pull request body explaining the format was refused for stating a malformed reference.

        `find_refs` is greedy on purpose — a malformed reference must surface as an error rather
        than vanish from a scan — and `<source>/<locale>` is the one shape that is not one.
        `_pct_encode` escapes `<` and `>`, so a real reference cannot contain either.
        """
        prose = ("the form is logic-canon://<source>/<locale>#value, and this change cites "
                 "logic-canon://strings/ko#value\n")
        self.assertEqual(canon.find_refs(prose), ["logic-canon://strings/ko#value"])

    def test_a_malformed_reference_without_brackets_is_still_returned(self):
        """The exemption is angle brackets only; everything else must still surface."""
        self.assertEqual(canon.find_refs("logic-canon://NOTASOURCE/x#value\n"),
                         ["logic-canon://NOTASOURCE/x#value"])

    def test_only_value_is_accepted_as_the_field(self):
        """`#composed` without a key would be a claim nothing can check."""
        with self.assertRaises(canon.CanonRefError):
            canon.CanonRef.parse("logic-canon://quickhelp/ko#composed")

    def test_the_value_index_round_trips(self):
        saved = canon.load_value_index("strings")
        try:
            canon.write_value_index("strings", {("ko", canon.short_digest("추가"))})
            self.assertIn(("ko", canon.short_digest("추가")), canon.load_value_index("strings"))
            canon.check_citation("logic-canon://strings/ko#value", "추가")
            with self.assertRaises(canon.CanonError):
                canon.check_citation("logic-canon://strings/ko#value", "존재하지않는값 zz91")
        finally:
            canon.write_value_index("strings", saved)

    def test_an_unbuilt_source_refuses_rather_than_passing(self):
        saved = canon.load_value_index("strings")
        try:
            canon.write_value_index("strings", set())
            with self.assertRaises(canon.CanonError):
                canon.check_citation("logic-canon://strings/ko#value", "추가")
        finally:
            canon.write_value_index("strings", saved)


class TellingAbsenceFromATypo(unittest.TestCase):
    """`absent` proves a BYTE STRING is not in the corpus, which is exactly true and half an answer.

    `Input Port:` is absent from all 24 corpora and Logic ships `Input Port`, so adding a colon
    proves anything uncitable. Three literals on the control-surface branch were proved absent
    that way. The fold answers the other half, offline, from digest sets committed beside the
    absence sets.
    """

    def test_decoration_is_folded(self):
        for typed, shipped in (("Input Port:", "Input Port"),
                               ("Set Locators…", "Set Locators"),
                               ("Project or Section...", "Project or Section…"),
                               ("Einstellungen\u00a0…", "Einstellungen …")):
            with self.subTest(typed=typed):
                self.assertEqual(canon.fold_for_near_miss(typed),
                                 canon.fold_for_near_miss(shipped))

    def test_invisible_format_characters_are_folded(self):
        """A character with no width cannot be part of a label somebody read off a screen.

        `Mix\u200ber` renders as `Mixer` and hashes as something else, so it proved ABSENT for a
        string Logic ships -- a review passed an absence claim through exactly that spelling. The
        fold drops Unicode category Cf rather than naming each one, because naming them is the
        shape that misses the next one.
        """
        for invisible in ("\u200b", "\u200c", "\u200d", "\u2060", "\ufeff", "\u00ad"):
            with self.subTest(codepoint=hex(ord(invisible))):
                self.assertEqual(canon.fold_for_near_miss(f"Mix{invisible}er"),
                                 canon.fold_for_near_miss("Mixer"))

    def test_a_visible_character_is_not_folded_as_invisible(self):
        """The control: the rule is about WIDTH, not about being unusual."""
        self.assertNotEqual(canon.fold_for_near_miss("Mixér"), canon.fold_for_near_miss("Mixer"))
        self.assertNotEqual(canon.fold_for_near_miss("Mix3r"), canon.fold_for_near_miss("Mixer"))

    def test_case_is_NOT_folded(self):
        """Runtime matching is case-insensitive, so a capital is not the defect this looks for.

        Folding case here fired on `Go To Position` against Logic's `Go to Position` -- which
        matches on screen -- and on every lowercase containment fragment: 33 findings, 3 real.
        """
        self.assertNotEqual(canon.fold_for_near_miss("Go To Position"),
                            canon.fold_for_near_miss("Go to Position"))
        self.assertNotEqual(canon.fold_for_near_miss("arm"), canon.fold_for_near_miss("Arm"))

    def test_a_genuinely_different_string_does_not_fold_together(self):
        self.assertNotEqual(canon.fold_for_near_miss("Track"), canon.fold_for_near_miss("Tracks"))

    def test_the_fold_is_not_a_canon_comparison(self):
        """Pinned so nobody reuses it as one. Two different labels can fold together -- Logic's
        `Set Locators` is a TOOLBAR item and `Set Locators…` is the Navigate menu entry."""
        self.assertNotEqual(canon.normalize("Input Port:"), canon.normalize("Input Port"))


class LocatingAStringForCitation(unittest.TestCase):
    """`locate_in` issues citations; `AXStringResolver.resolve` reverses live readings.

    They are separate because their corpora are. `resolve` reads `StringsIndex` -- 10,395
    (unit, key) pairs for ko -- while `extract_strings` yields 60,048, so 83% of the corpus is
    invisible to it and it answers None for strings Apple ships. Measured while preparing two
    pull requests: `설치` and `키 레이블로 학습` both resolve to None and both are citable, at
    `Install.strings/164.title` and `KeyCommands.strings/300557.title`. An author reading None
    as "uncitable" would have declared a shipped string absent.

    Driven over ROWS rather than over Logic, deliberately. A case needing Logic could not run in
    CI, and `.github/ci/CI-SKIPS.json` is shrink-only -- adding a fifth skip is admitting debt,
    which is the ratchet working rather than a wall to route around.
    """

    ROWS = [
        ("Contents/.../Localizable.strings", "ko", "Install…", "value", "설치…"),
        ("Contents/.../Install.strings", "ko", "164.title", "value", "설치"),
        ("Contents/.../MAContentDownload.strings", "ko", "73.title", "value", "설치"),
        ("Contents/.../Localizable.strings", "en", "Install…", "value", "Install…"),
        ("Contents/.../Elsewhere.strings", "ko", "9.title", "value", "설치 완료"),
    ]

    def test_a_whole_value_is_found_everywhere_it_occurs(self):
        hits = canon.locate_in(self.ROWS, "설치", source="strings")
        self.assertEqual([(u, k) for _, u, _, k, _ in hits],
                         [("Contents/.../Install.strings", "164.title"),
                          ("Contents/.../MAContentDownload.strings", "73.title")])

    def test_a_substring_is_not_a_hit(self):
        """`설치` occurs inside `설치 완료`, and a citation to that row would be false."""
        hits = canon.locate_in(self.ROWS, "설치", source="strings")
        self.assertNotIn("9.title", [k for _, _, _, k, _ in hits])

    def test_the_comparison_is_normalized_on_both_sides(self):
        rows = [("u", "ko", "k", "value", "\u00a0설치\u00a0")]
        self.assertEqual(len(canon.locate_in(rows, " 설치 ", source="strings")), 1)

    def test_a_string_in_no_row_yields_nothing(self):
        self.assertEqual(canon.locate_in(self.ROWS, "결코 없는 문자열 91xq", source="strings"), [])

    def test_a_hit_becomes_a_reference_that_parses_and_carries_no_whitespace(self):
        """A reference with a space is truncated by `find_refs`, which scans prose for
        non-whitespace -- the defect that once made every `strings` citation resolve to nothing."""
        source, unit, locale, key, field = canon.locate_in(
            self.ROWS, "설치…", source="strings")[0]
        ref = canon.citation_for(source, unit, locale, key, field)
        self.assertNotIn(" ", ref)
        parsed = canon.CanonRef.parse(ref)
        self.assertEqual(parsed.index_row(), (unit, locale, key, field))

    #: One row shaped like each source actually yields, taken from a real extraction rather than
    #: invented. `madsp` units carry SPACES ("Adaptive Limiter"), `strings` units carry SLASHES and
    #: a dot, `nib` values are whole paths and `quickhelp` keys are bare. A reference with a space
    #: in it is truncated by `find_refs`, which scans prose for non-whitespace -- the defect that
    #: once made every `strings` citation resolve to nothing.
    SHAPES = [
        ("quickhelp", "QuickHelp", "en", "CSM_004_OpenInstall", "Title", "Install"),
        ("strings", "Contents/Frameworks/Logic.framework/Versions/A/Resources/Install.strings",
         "ko", "164.title", "value", "설치"),
        ("madsp", "Adaptive Limiter", "-", "2", "name", "Gain"),
        ("nib", "qhid", "-", "ART_03_NameField", "nibs",
         "Contents/Frameworks/Logic.framework/Versions/A/Resources/Base.lproj/"
         "ArticulationSettingsWindow.nib"),
    ]

    def test_one_key_across_ten_locales_is_one_row(self):
        """The answer a person can act on. Ungrouped, `Smart Controls` printed forty-odd lines --
        ten of them one QuickHelp key repeated once per locale -- and nobody chooses from that."""
        hits = [("quickhelp", "QuickHelp", loc, "DMD_022_PadSmartControls", "Title")
                for loc in ("de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh_CN", "zh_TW")]
        grouped = canon.group_by_key(hits)
        self.assertEqual(len(grouped), 1)
        source, unit, key, field, locales = grouped[0]
        self.assertEqual(key, "DMD_022_PadSmartControls")
        self.assertEqual(len(locales), 10)

    def test_different_keys_stay_separate(self):
        """Grouping must not merge candidates: choosing between them is the decision."""
        hits = [("strings", "u", "de", "NewTrackSheetButton", "value"),
                ("quickhelp", "QuickHelp", "de", "LLP_090_CopyTakeNewTrack", "Title")]
        self.assertEqual(len(canon.group_by_key(hits)), 2)

    def test_locales_are_deduplicated_and_ordered(self):
        hits = [("strings", "u", "ko", "k", "value"),
                ("strings", "u", "de", "k", "value"),
                ("strings", "u", "ko", "k", "value")]
        self.assertEqual(canon.group_by_key(hits)[0][4], ["de", "ko"])

    def test_every_source_shape_round_trips_through_a_reference(self):
        for source, unit, locale, key, field, value in self.SHAPES:
            with self.subTest(source=source):
                hit = canon.locate_in([(unit, locale, key, field, value)], value, source=source)
                self.assertEqual(len(hit), 1, f"{source}: the row did not match its own value")
                ref = canon.citation_for(*hit[0])
                self.assertNotIn(" ", ref, f"{source}: a space truncates the reference")
                self.assertEqual(canon.CanonRef.parse(ref).index_row(),
                                 (unit, locale, key, field), f"{source}: did not round trip")

    def test_a_reference_survives_find_refs_on_surrounding_prose(self):
        """Building a valid reference is not enough; the scanner has to get it back WHOLE.

        `_pct_encode` once allowed spaces, every reference parsed, and `find_refs` truncated each
        one mid-string — so they resolved to nothing and reported a missing key rather than a
        malformed one. `madsp` is the shape that would catch it: its units are plug-in names.
        """
        for source, unit, locale, key, field, value in self.SHAPES:
            with self.subTest(source=source):
                ref = canon.citation_for(*canon.locate_in(
                    [(unit, locale, key, field, value)], value, source=source)[0])
                prose = f"as recorded in {ref} and nowhere else.\n"
                self.assertEqual(canon.find_refs(prose), [ref], f"{source}: scanned back wrong")

    def test_it_sees_rows_the_resolver_cannot(self):
        """The whole reason this exists, stated as a case rather than as a comment.

        `StringsIndex` is built from a narrower walk, so a row in an IB-keyed table is invisible
        to `resolve`. `locate_in` is given the rows directly and therefore cannot have that gap.
        """
        ib_keyed = [("Contents/.../Install.strings", "ko", "164.title", "value", "설치")]
        self.assertEqual(len(canon.locate_in(ib_keyed, "설치", source="strings")), 1)


class TheAlgorithmAgainstASurrogateCorpus(unittest.TestCase):
    """The round trip, run in CI, over a corpus SHAPED like Apple's but written by us.

    The strongest assertion in this file -- compose every entry, parse it back, require the same
    keys -- can only run where the corpus is, and the corpus is inside Logic, which no CI runner
    has. So it moved to `build`, which refuses to write an index over a corpus it cannot reverse.

    That leaves nothing running in CI, and a check that runs nowhere the merge is gated is the
    shape this whole change exists to refuse. So: a surrogate.

    The TEXT is ours. The SHAPE is read from `docs/canon/MANIFEST.json` -- the minimum composition
    length, how many compositions share their string, and how many are suffixes of another -- which
    are numbers the repository already publishes. Every structural case the real corpus has is
    built here, so the code paths a real defect would take are the paths this exercises.

    What it does NOT do, said plainly: it cannot catch a defect that depends on the CONTENT of
    Apple's strings rather than their shape -- a normalization edge in Hangul, say. That one is
    caught at build time or not at all, and the manifest records that it was.
    """

    def _shape(self):
        """The manifest, or a SKIP -- except under CI, where a skip is a silent pass.

        These five cases are the only proof CI can run that the parser is right; the corpus they
        stand for is inside Logic and no runner has it. So when the shape is missing they run
        nothing, and `unittest` exits 0 with "skipped=4" while `run-repo-guards.py` prints ok.
        Measured: deleting the `shape` and `round_trip` blocks skipped four of these five.

        A developer without a built manifest should still be able to run the suite, so the skip
        stays locally. CI always has the committed manifest, so there it is a failure.
        """
        path = os.path.join(REPO, "docs", "canon", "MANIFEST.json")
        if not os.path.exists(path):
            self._no_shape("no manifest to read the corpus shape from")
        with open(path, encoding="utf-8") as handle:
            manifest = json.load(handle)
        return manifest["sources"]["quickhelp"]

    def _no_shape(self, why):
        if os.environ.get("CI") == "true":
            self.fail(f"{why}. Under CI this is a failure, not a skip: the manifest is committed, "
                      f"so its absence means the only corpus proof CI can run ran nothing.")
        self.skipTest(why)

    def _surrogate(self, locale="ko"):
        """A composition table with every structural case, in text nobody else wrote.

        The parameters are READ from `MANIFEST.json`'s `shape` block, not typed here. An earlier
        version typed them and said it read them, which is the same defect as a number typed into
        prose -- and the one this whole change is about. The real corpus is scaled down by a
        constant so the fixture stays fast; the RATIOS and the extremes are preserved.
        """
        shape = self._shape().get("shape", {}).get(locale)
        if not shape:
            self._no_shape(f"the manifest carries no shape for {locale}")
        scale = max(1, shape["compositions"] // 200)
        shortest = shape["shortest"]
        shared = shape["most_keys_on_one_composition"]
        shared_count = max(1, shape["shared_by_more_than_one_key"] // scale)
        suffix_pairs = max(1, shape["suffix_pairs"])
        plain = max(1, shape["compositions"] // scale) - shared_count - suffix_pairs * 2 - 5
        by_composed = {}
        # Plain entries, one key each, at and above the anchor floor.
        for n in range(max(1, plain)):
            by_composed[f"Widget {n} control. It does the thing numbered {n}."] = [f"PLAIN_{n}"]
        # Compositions at exactly the corpus minimum length.
        for n in range(5):
            by_composed[("s" * shortest) + str(n)] = [f"SHORT_{n}"]
        # Shared compositions: several keys behind one string, which the real corpus has 3,766 of.
        for n in range(shared_count):
            by_composed[f"Shared surface {n}. Two controls read identically here."] = [
                f"SHARED_{n}_{k}" for k in range(shared)]
        # Suffix-containment pairs: a shorter composition that is the tail of a longer one, which
        # is where longest-match is the only thing keeping the answer right.
        for n in range(suffix_pairs):
            tail = f"Gain knob {n}. Amplifies or attenuates the signal."
            by_composed[tail] = [f"TAIL_{n}"]
            by_composed[f"Filter {tail}"] = [f"HEAD_{n}"]
        # Floors that are NOT read from the manifest, so flattening the manifest cannot flatten
        # them. Measured: setting `suffix_pairs` to 1 and `most_keys_on_one_composition` to 1 left
        # a surrogate with no shared composition at all, and all 62 cases still reported OK.
        self.assertGreaterEqual(sum(1 for v in by_composed.values() if v[0].startswith("HEAD_")), 2,
                                "a surrogate with fewer than two suffix pairs cannot exercise "
                                "longest-match, which is the property the parser rests on")
        self.assertGreaterEqual(max(len(v) for v in by_composed.values()), 2,
                                "a surrogate where no composition carries two keys has dropped the "
                                "property 3,766 ko keys in the real corpus have")
        return canon.QuickHelpIndex("xx", {canon.normalize(k): v for k, v in by_composed.items()})

    def test_every_composition_round_trips_whole(self):
        index = self._surrogate()
        wrong = [c for c, keys in index.by_composed.items()
                 if (index.parse_axhelp(c) or type("x", (), {"keys": []})).keys != keys]
        self.assertEqual(wrong[:3], [], f"{len(wrong)} of {len(index.by_composed)} did not round trip")

    def test_a_runtime_prefix_never_changes_the_answer(self):
        index = self._surrogate()
        prefixes = ["Off", "Play   \u2305", "This control is unavailable. Reason: no track."]
        wrong = []
        for position, (composed, keys) in enumerate(sorted(index.by_composed.items())):
            prefix = prefixes[position % len(prefixes)]
            match = index.parse_axhelp(f"{prefix}, {composed}")
            if match is None or match.keys != keys or match.prefix != prefix:
                wrong.append(composed)
        self.assertEqual(wrong[:3], [], f"{len(wrong)} prefixed compositions did not round trip")

    def test_longest_match_wins_on_every_suffix_pair(self):
        """The property the real corpus's 65 suffix pairs rest on, exercised on 40 built ones."""
        index = self._surrogate()
        for composed, keys in index.by_composed.items():
            if keys[0].startswith("HEAD_"):
                self.assertEqual(index.parse_axhelp(composed).keys, keys, composed)

    def test_the_surrogate_is_shaped_like_the_real_corpus(self):
        """Read the shape rather than assume it -- and know what this case can and cannot see.

        Every assertion below compares the surrogate against the numbers that BUILT the surrogate,
        so it cannot notice those numbers falling. It was written as if it could. What actually
        holds them up is rule 16 in `check-canon-citations.py`, which refuses a measured count that
        shrinks while `MANIFEST.json` names the same Logic, and the two floors in `_surrogate`,
        which are typed here rather than read.
        """
        shape = self._shape()
        self.assertIn("round_trip", shape)
        self.assertIn("shape", shape)
        for locale, row in shape["shape"].items():
            index = self._surrogate(locale) if locale == "ko" else None
            if index is None:
                continue
            self.assertGreaterEqual(min(len(c) for c in index.by_composed), row["shortest"] - 1)
            self.assertEqual(max(len(k) for k in index.by_composed.values()),
                             row["most_keys_on_one_composition"])
        for locale, row in shape["round_trip"].items():
            self.assertEqual(row["whole"], row["compositions"], locale)
            self.assertEqual(row["with_a_runtime_prefix"], row["compositions"], locale)

    def test_the_surrogate_would_catch_a_shortest_match_parser(self):
        """A control that cannot fail is not a control.

        Asserts the property directly rather than mutating the module: on a suffix pair, the
        answer must be the LONGER composition's key. A parser that took the shortest match would
        return the tail's key here, and this is the assertion that would then fail.
        """
        index = self._surrogate()
        head = next(c for c, k in sorted(index.by_composed.items()) if k[0] == "HEAD_0")
        tail = next(c for c, k in sorted(index.by_composed.items()) if k[0] == "TAIL_0")
        self.assertTrue(head.endswith(tail), "the fixture must actually contain a suffix pair")
        self.assertEqual(index.parse_axhelp(head).keys, ["HEAD_0"])
        self.assertEqual(index.parse_axhelp(tail).keys, ["TAIL_0"])


def _archive(objects):
    """Build the dict `nibarchive.parse` returns, from [(class_name, {key: value}), ...].

    A seam, not a fixture: every case below is about a SHAPE the reader may meet, and a shape that
    only exists inside a real nib cannot be written down as a test.
    """
    classes, keys, values, out = [], [], [], []
    for name, fields in objects:
        if name not in classes:
            classes.append(name)
        first = len(values)
        for key, value in fields.items():
            if key not in keys:
                keys.append(key)
            values.append({"key": keys.index(key),
                           "type": nibarchive.T_DATA if isinstance(value, bytes) else 10,
                           "value": value})
        out.append({"class": classes.index(name), "first_value": first,
                    "value_count": len(values) - first})
    return {"objects": out, "keys": keys, "values": values, "classes": classes}


class ANibLabelIsPairedByClassNotByGuess(unittest.TestCase):
    """`extract_nibstrings` is the only route to English for 162 tables, so its pairing is load-bearing."""

    def test_the_object_after_a_localizable_string_is_its_key(self):
        archive = _archive([("NSLocalizableString", {"NS.bytes": "Learn by Key Label".encode()}),
                            ("NSString", {"NS.bytes": b"300557.title"})])
        self.assertEqual(list(canon._nib_localizable_pairs(archive, "x.nib")),
                         [("300557.title", "Learn by Key Label")])

    def test_a_shape_it_cannot_pair_stops_the_build_instead_of_becoming_an_absence(self):
        """Skipping would drop English Apple ships, and the corpus would then PROVE it absent."""
        archive = _archive([("NSLocalizableString", {"NS.bytes": b"Bounce"}),
                            ("NSImage", {"NSName": b"NSMenuCheckmark"})])
        with self.assertRaises(canon.CanonDecodeError):
            list(canon._nib_localizable_pairs(archive, "x.nib"))

    def test_a_localizable_string_with_no_object_after_it_stops_the_build(self):
        archive = _archive([("NSLocalizableString", {"NS.bytes": b"Bounce"})])
        with self.assertRaises(canon.CanonDecodeError):
            list(canon._nib_localizable_pairs(archive, "x.nib"))

    def test_a_multi_line_label_is_text_and_survives_the_reader(self):
        """`str.isprintable()` says a line break is not printable. 47 of Logic's longest labels are
        multi-line paragraphs, and reading it as the test returned them as English that is not
        there -- an absence, in the one direction this module may not be wrong about."""
        paragraph = "This function applies the tempo\nof the selected region."
        archive = _archive([("NSLocalizableString", {"NS.bytes": paragraph.encode()}),
                            ("NSString", {"NS.bytes": b"100013.title"})])
        self.assertEqual(list(canon._nib_localizable_pairs(archive, "x.nib")),
                         [("100013.title", paragraph)])

    def test_a_real_control_byte_is_still_not_text(self):
        archive = _archive([("NSString", {"NS.bytes": b"bell\x07here"})])
        self.assertEqual(nibarchive.strings_by_object(archive), {})


class ACorpusMustKnowWhichBytesItIsMadeOf(unittest.TestCase):
    """Over an EMPTY bundle, not over the installed Logic.

    The first version of `test_every_extractor_has_one` passed `/Applications/Logic Pro.app` and
    therefore tested nothing on the one machine that matters: CI has no Logic, and `quickhelp`'s
    branch does a bare `os.listdir` on `Contents/Resources`, so the case died with a
    FileNotFoundError instead of answering whether every extractor has a branch. The property is
    about this module's own dispatch, so the fixture is a directory shaped like a bundle and empty.
    """

    def setUp(self):
        self.bundle = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.bundle, "Contents", "Resources"))
        self.addCleanup(shutil.rmtree, self.bundle, True)

    def test_a_source_with_no_file_list_is_refused_rather_than_pinned_against_nothing(self):
        """An empty list recorded `files: 0` and a digest over nothing, and `status` would then
        call the corpus current against any Logic at all."""
        with self.assertRaises(canon.CanonError):
            canon.corpus_files(self.bundle, "a-source-nobody-added-a-branch-for")

    def test_every_extractor_has_one(self):
        for source in canon.EXTRACTORS:
            self.assertEqual(canon.corpus_files(self.bundle, source), [],
                             f"{source} found files in an empty bundle")


class EnglishAndItsTranslationsMustMeet(unittest.TestCase):
    """The join `TRANSLATION_NAMESPACE` exists for, tested where it can fail rather than asserted."""

    @staticmethod
    def _sources():
        def english(_app):
            yield ("Resources/Bounce.strings", "en", "3.title", "value", "Bounce")
            yield ("Resources/Bounce.strings", "en", "4.title", "value", "Stereo")
        def translations(_app):
            yield ("Resources/Bounce.strings", "ko", "3.title", "value", "바운스")
            yield ("Resources/Bounce.strings", "ko", "4.title", "value", "Stereo")
        return {"nibstrings": english, "strings": translations}

    def test_english_from_one_source_joins_translations_in_another(self):
        digests = canon.derive_translated_english(APP, self._sources())
        self.assertIn(canon._u32(canon.normalize("Bounce")), digests)

    def test_a_label_apple_ships_untranslated_is_not_called_translated(self):
        digests = canon.derive_translated_english(APP, self._sources())
        self.assertNotIn(canon._u32(canon.normalize("Stereo")), digests)

    def test_without_the_namespace_the_two_sources_never_meet(self):
        """The failure this guards is silent and permissive: every base-internationalised English
        label would read as one Apple does not translate, which EXEMPTS a literal comparison from
        needing a LabelSet. So the test is that removing the mapping changes the answer."""
        saved = dict(canon.TRANSLATION_NAMESPACE)
        try:
            canon.TRANSLATION_NAMESPACE.clear()
            digests = canon.derive_translated_english(APP, self._sources())
        finally:
            canon.TRANSLATION_NAMESPACE.clear()
            canon.TRANSLATION_NAMESPACE.update(saved)
        self.assertNotIn(canon._u32(canon.normalize("Bounce")), digests)

    #: Two DIFFERENT strings whose SHA-256 truncates to the same 32 bits, found by search rather
    #: than assumed: `_u32('s2330') == _u32('s130636') == 0xb07b8ed5`. Two of the same string would
    #: dedupe at the string level and the case would pass over a list that was never a set.
    COLLIDING = ("s2330", "s130636")

    def test_two_english_values_colliding_to_one_digest_are_written_once(self):
        first, second = self.COLLIDING
        self.assertEqual(canon._u32(first), canon._u32(second),
                         "these two no longer collide; find a new pair rather than deleting the case")
        def english(_app):
            yield ("u", "en", "a", "value", first)
            yield ("u", "en", "b", "value", second)
        def translations(_app):
            yield ("u", "ko", "a", "value", "하나")
            yield ("u", "ko", "b", "value", "둘")
        digests = canon.derive_translated_english(APP, {"nibstrings": english,
                                                        "strings": translations})
        self.assertEqual(digests, sorted(set(digests)),
                         "the file is a SET of digests; a duplicate entry is a count that is wrong "
                         "and an artefact that will not reproduce from a different walk order")


@unittest.skipUnless(HAVE_LOGIC, "needs Logic installed")
class AgainstTheRealCorpus(unittest.TestCase):
    def test_every_key_round_trips_from_a_composed_axhelp(self):
        """Compose an AXHelp the way Logic does, then require the key back. Every key, not a sample."""
        index = canon.QuickHelpIndex.from_app(APP, "ko")
        wrong = []
        for composed, keys in index.by_composed.items():
            if len(composed) < canon.DEFAULT_MIN_ANCHOR:
                continue
            match = index.parse_axhelp(composed)
            if match is None or set(match.keys) != set(keys):
                wrong.append(composed)
        self.assertEqual(wrong[:5], [], f"{len(wrong)} compositions did not round trip")

    def test_a_runtime_prefix_never_changes_which_key_comes_back(self):
        index = canon.QuickHelpIndex.from_app(APP, "ko")
        prefixes = ["끔", "재생   ⌅", "리전은 1 마디 에서 시작하여 2 마디 에서 끝납니다.",
                    "이 컨트롤을 사용할 수 없습니다. 원인: 오디오 트랙이 선택되지 않았습니다."]
        wrong = []
        for position, (composed, keys) in enumerate(index.by_composed.items()):
            if len(composed) < canon.DEFAULT_MIN_ANCHOR:
                continue
            prefix = prefixes[position % len(prefixes)]
            match = index.parse_axhelp(f"{prefix}, {composed}")
            if match is None or set(match.keys) != set(keys) or match.prefix != prefix:
                wrong.append((prefix, composed))
        self.assertEqual(wrong[:3], [], f"{len(wrong)} prefixed compositions did not round trip")

    def _live_axhelp_values(self):
        """The distinct AXHelp values read off a running Logic, as committed evidence."""
        path = os.path.join(REPO, "docs", "observations", "evidence",
                            "2026-09-15-axhelp-live-values.txt")
        if not os.path.exists(path):
            self.fail(f"{os.path.relpath(path, REPO)} is missing. It is the input this assertion "
                      f"is over; without it the case proves nothing, and skipping would report ok.")
        with open(path, encoding="utf-8") as handle:
            return sorted({canon.normalize(line) for line in handle if line.strip()})

    def test_the_live_axhelp_corpus_is_explained_by_canonical_data(self):
        """113 of 114, and the one left over is left over rather than explained away.

        This is the measurement the whole canon axis rests on, so it runs as a test: if a Logic
        update or an extractor change moves it, the number moves here rather than in a document.
        """
        # The readings live in the repository, not in /tmp. They were read from `/tmp/axlive2.tsv`
        # on the machine that ran Logic, and that is where this test looked -- so on any other
        # machine, and on this one after any reboot, it skipped. macOS rebuilds /private/tmp at
        # boot. So the case written because "the measurement the whole canon axis rests on" should
        # move when Logic moves could not run for anybody, including its author tomorrow.
        values = self._live_axhelp_values()
        resolver = canon.AXStringResolver(APP, "ko")
        unresolved = [value for value in values if resolver.resolve(value) is None]
        self.assertEqual(len(values), 114)
        self.assertEqual(unresolved, ["이 버튼을 누르면 윈도우를 확대/축소합니다."])

    def test_the_ten_locales_carry_the_same_keys(self):
        sets = {}
        for locale in canon.EXPECTED_LOCALES:
            index = canon.QuickHelpIndex.from_app(APP, locale)
            sets[locale] = {key for keys in index.by_composed.values() for key in keys}
        reference = sets["en"]
        for locale, keys in sets.items():
            self.assertEqual(keys, reference, f"{locale} key set differs from en")


if __name__ == "__main__":
    unittest.main(verbosity=2)
