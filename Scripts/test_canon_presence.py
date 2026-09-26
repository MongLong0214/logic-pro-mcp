"""Cases for #992: a 32-bit prefix match is not a proof that Logic ships a string.

The absence sets answer ABSENT soundly -- every value the corpus holds put its own prefix there --
and cannot answer PRESENT, because a string Apple does not ship can share a prefix with one it
does. Eight guard sites read `not canon.is_absent(...)` as presence. Each case below builds a
corpus whose absence set holds a string's prefix while the pinned full comparison
(`ledger/presence.tsv`) says the string does not ship: a collision, as a fixture. On the old code
every site treats that string as shipped.

Also here: the two manifest counts `build` wrote and nothing compared, `translated_en_values` and
`sources.<source>.folded_entries`.

    python3 Scripts/test_canon_presence.py
"""
import contextlib
import importlib.util
import json
import os
import shutil
import struct
import sys
import tempfile
import unittest
from unittest import mock

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "Scripts"))

import logic_canon as canon  # noqa: E402


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(REPO, "Scripts", filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CITATIONS = _load("canon_citations_for_presence", "check-canon-citations.py")
POLICY = _load("policy_literals_for_presence", "check-policy-literals-against-canon.py")
SHIPPED = _load("shipped_python_for_presence", "check-shipped-python-has-no-ui-literals.py")
NEW_LABELSETS = _load("new_labelsets_for_presence", "check-new-labelsets-name-a-row.py")

#: The string whose prefix is in the set and which the full comparison says Logic does not ship.
COLLIDER = "Collider Label"
#: A string the fixture corpus really holds.
SHIPPED_VALUE = "Shipped Label"
MANIFEST = {"sources": {"strings": {"locales": ["en"]}, "nibstrings": {"locales": ["en"]}}}


class _Corpus:
    """Absence sets and a presence ledger under a temporary directory, for any loaded canon copy.

    Every guard loads its OWN copy of `logic_canon`, so a fixture has to point each copy at it.
    """

    def __init__(self, tmp):
        self.tmp = tmp
        self.absence = os.path.join(tmp, "absence")
        self.ledger = os.path.join(tmp, "ledger")

    def write(self, module, *, prefixes, rows):
        """`prefixes`: strings whose 32-bit prefix goes in strings/en and nibstrings/en.

        `rows`: `{text: (exact, near)}` pinned for both corpora, as a full comparison would.
        """
        with self.aimed(module):
            for source in ("strings", "nibstrings"):
                module.write_absence(source, "en", prefixes)
                module.write_absence(source, "en", prefixes, folded=True)
            module.write_ledger_presence({(source, "en", text): verdict
                                          for source in ("strings", "nibstrings")
                                          for text, verdict in rows.items()})

    @contextlib.contextmanager
    def aimed(self, module):
        with mock.patch.object(module, "ABSENCE_DIR", self.absence), \
                mock.patch.object(module, "LEDGER_DIR", self.ledger), \
                mock.patch.object(module, "load_manifest", lambda: MANIFEST):
            yield


class PresenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="canon-presence-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.corpus = _Corpus(self.tmp)

    def _collision(self, module, *, near=canon.FAR):
        """COLLIDER's prefix is in the set; the full comparison pinned it as not shipped."""
        self.corpus.write(module, prefixes=[SHIPPED_VALUE, COLLIDER],
                          rows={COLLIDER: (canon.ABSENT, near),
                                SHIPPED_VALUE: (canon.SHIPS, canon.NEAR)})

    def _unconfirmed(self, module):
        """COLLIDER's prefix is in the set and nobody compared it as a string."""
        self.corpus.write(module, prefixes=[SHIPPED_VALUE, COLLIDER],
                          rows={SHIPPED_VALUE: (canon.SHIPS, canon.NEAR)})

    # -- the lookup itself ------------------------------------------------------------------

    def test_presence_is_tri_state_and_only_a_pinned_row_says_ships(self):
        self._collision(canon)
        with self.corpus.aimed(canon):
            self.assertEqual(canon.presence("strings", "en", SHIPPED_VALUE), canon.SHIPS)
            self.assertEqual(canon.presence("strings", "en", COLLIDER), canon.ABSENT)
            self.assertEqual(canon.presence("strings", "en", "Never Written"), canon.ABSENT)
            # The set still says "not absent" for the collider -- which is the whole defect.
            self.assertFalse(canon.is_absent("strings", "en", COLLIDER))
        self._unconfirmed(canon)
        with self.corpus.aimed(canon):
            self.assertEqual(canon.presence("strings", "en", COLLIDER), canon.UNCONFIRMED)

    def test_a_ships_row_the_set_does_not_hold_does_not_make_a_string_ship(self):
        self.corpus.write(canon, prefixes=[SHIPPED_VALUE],
                          rows={COLLIDER: (canon.SHIPS, canon.NEAR)})
        with self.corpus.aimed(canon):
            self.assertEqual(canon.presence("strings", "en", COLLIDER), canon.ABSENT)
            problems = canon.verify_presence_ledger(
                {"ledger_presence_entries": {"nibstrings": {"en": 1}, "strings": {"en": 1}}})
        self.assertTrue(any("ships in strings/en and no 32-bit prefix" in p for p in problems),
                        problems)
        self.corpus.write(canon, prefixes=[SHIPPED_VALUE],
                          rows={COLLIDER: (canon.ABSENT, canon.NEAR)})
        with self.corpus.aimed(canon):
            problems = canon.verify_presence_ledger(
                {"ledger_presence_entries": {"nibstrings": {"en": 1}, "strings": {"en": 1}}})
        self.assertTrue(any("folds to" in p and "strings/en" in p for p in problems), problems)

    def test_presence_rows_compare_strings_and_keep_only_prefix_matches(self):
        # A hash where every seven-character string collides, so the comparison has one to find.
        with mock.patch.object(canon, "_u32", len):
            rows = canon.presence_rows({"strings": {"en": {"shipped", "Other:"}}},
                                       ["shipped", "collide", "Other", "a-longer-string"])
        self.assertEqual(rows[("strings", "en", "shipped")], (canon.SHIPS, canon.NEAR))
        self.assertEqual(rows[("strings", "en", "collide")], (canon.ABSENT, canon.FAR))
        self.assertEqual(rows[("strings", "en", "Other")], (canon.ABSENT, canon.NEAR))
        self.assertNotIn(("strings", "en", "a-longer-string"), rows)

    def test_a_confirmed_collision_reaches_the_near_miss_fold(self):
        self._collision(canon, near=canon.NEAR)
        with self.corpus.aimed(canon):
            self.assertTrue(canon.differs_only_by_decoration("strings", "en", COLLIDER))
        self._collision(canon, near=canon.FAR)
        with self.corpus.aimed(canon):
            self.assertFalse(canon.differs_only_by_decoration("strings", "en", COLLIDER))

    def test_the_ledger_round_trips_and_refuses_an_unknown_verdict(self):
        self._collision(canon)
        with self.corpus.aimed(canon):
            loaded = canon.load_presence_ledger()
            self.assertEqual(loaded[("strings", "en", COLLIDER)], (canon.ABSENT, canon.FAR))
            with open(canon.ledger_presence_path(), "a", encoding="utf-8") as handle:
                handle.write('strings\ten\tmaybe\tfar\t"x"\n')
            with self.assertRaises(canon.CanonError):
                canon.load_presence_ledger()

    def test_presence_counts_are_checked_against_the_manifest(self):
        self._collision(canon)
        with self.corpus.aimed(canon):
            counts = canon.presence_counts(canon.load_presence_ledger())
            self.assertEqual(counts, {"nibstrings": {"en": 2}, "strings": {"en": 2}})
            self.assertEqual(canon.verify_presence_ledger({"ledger_presence_entries": counts}), [])
            with open(canon.ledger_presence_path(), "a", encoding="utf-8") as handle:
                handle.write(f'strings\ten\tships\tnear\t{json.dumps(SHIPPED_VALUE + "!")}\n')
            problems = canon.verify_presence_ledger({"ledger_presence_entries": counts})
            self.assertTrue(any("3 row(s) for strings/en" in p for p in problems), problems)
            self.assertNotEqual(canon.verify_presence_ledger({}), [])

    def test_the_committed_presence_ledger_matches_its_manifest(self):
        with open(os.path.join(canon.CANON_DIR, "MANIFEST.json"), encoding="utf-8") as handle:
            manifest = json.load(handle)
        self.assertEqual(canon.verify_presence_ledger(manifest), [])

    # -- the manifest counts nothing compared -------------------------------------------------

    def _translated(self, values):
        with open(os.path.join(self.corpus.absence, "translated.en.u32"), "wb") as handle:
            handle.write(b"LCA1" + struct.pack(">I", len(values))
                         + b"".join(struct.pack(">I", v) for v in values))

    def test_translated_count_is_compared(self):
        os.makedirs(self.corpus.absence, exist_ok=True)
        self._translated([1, 2, 3])
        with self.corpus.aimed(canon):
            self.assertEqual(canon.verify_derived_counts({"translated_en_values": 3}), [])
            self._translated([1, 2])
            problems = canon.verify_derived_counts({"translated_en_values": 3})
            self.assertTrue(any("translated.en.u32 holds 2" in p for p in problems), problems)
            problems = canon.verify_derived_counts({})
            self.assertTrue(any("translated_en_values" in p for p in problems), problems)

    def test_folded_counts_are_compared_and_each_folded_set_needs_one(self):
        with self.corpus.aimed(canon), mock.patch.dict(canon.EXTRACTORS, {"t": None}):
            canon.write_absence("t", "de", ["a", "b"], folded=True)
            canon.write_absence("t", "ko", ["a"], folded=True)
            full = {"sources": {"t": {"locales": ["de", "ko"],
                                      "folded_entries": {"de": 2, "ko": 1}}}}
            self.assertEqual(canon.verify_derived_counts(full), [])
            canon.write_absence("t", "de", ["a"], folded=True)
            problems = canon.verify_derived_counts(full)
            self.assertTrue(any("t.de.folded.u32 holds 1" in p and "declares 2" in p
                                for p in problems), problems)
            missing = {"sources": {"t": {"locales": ["de", "ko"], "folded_entries": {"de": 1}}}}
            problems = canon.verify_derived_counts(missing)
            self.assertTrue(any("t.ko.folded.u32 has no count" in p for p in problems), problems)

    def test_the_committed_counts_match(self):
        with open(os.path.join(canon.CANON_DIR, "MANIFEST.json"), encoding="utf-8") as handle:
            manifest = json.load(handle)
        self.assertEqual(canon.verify_derived_counts(manifest), [])

    def test_the_guard_runs_the_new_comparisons(self):
        # The comparisons are only worth what calls them. `check-canon-citations.py` is the guard
        # that verifies the manifest; a copy that stops asking would pass a forged count.
        with open(os.path.join(REPO, "Scripts", "check-canon-citations.py"), encoding="utf-8") as h:
            body = h.read()
        for name in ("verify_derived_counts(manifest)", "verify_presence_ledger(manifest)"):
            self.assertIn(f"failures.extend(canon.{name})", body)

    # -- check-canon-citations.py: 590, 869, 1757 ---------------------------------------------

    def test_not_applicable_is_not_refused_for_a_confirmed_collision(self):
        self._collision(CITATIONS.canon)
        record = {"canon_not_applicable": {"reason": "behaviour"}, "observed": COLLIDER}
        with self.corpus.aimed(CITATIONS.canon), \
                mock.patch.object(CITATIONS, "NOT_APPLICABLE_FIELDS", ("observed",)):
            failures = []
            CITATIONS.check_not_applicable("r.json", record, MANIFEST, failures)
            self.assertEqual(failures, [])
        self._unconfirmed(CITATIONS.canon)
        with self.corpus.aimed(CITATIONS.canon), \
                mock.patch.object(CITATIONS, "NOT_APPLICABLE_FIELDS", ("observed",)):
            failures = []
            CITATIONS.check_not_applicable("r.json", record, MANIFEST, failures)
            self.assertEqual(len(failures), 1, failures)
            self.assertIn("confirm", failures[0])

    def _absence_record(self, text):
        path = os.path.join(self.tmp, "record.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"schema": 3, "canon_absent": [{
                "strings": [text], "why_runtime": "drawn at runtime",
                "searched": [{"source": s, "locale": "en"} for s in ("strings", "nibstrings")]}]},
                handle)
        return path

    def test_an_absence_claim_over_a_confirmed_collision_is_not_refused(self):
        self._collision(CITATIONS.canon)
        with self.corpus.aimed(CITATIONS.canon):
            failures = []
            CITATIONS.check_record(self._absence_record(COLLIDER), failures, set(), MANIFEST)
        self.assertFalse([f for f in failures if "PRESENT" in f or "confirm" in f], failures)
        self._unconfirmed(CITATIONS.canon)
        with self.corpus.aimed(CITATIONS.canon):
            failures = []
            CITATIONS.check_record(self._absence_record(COLLIDER), failures, set(), MANIFEST)
        self.assertTrue([f for f in failures if "confirm" in f], failures)
        with self.corpus.aimed(CITATIONS.canon):
            failures = []
            CITATIONS.check_record(self._absence_record(SHIPPED_VALUE), failures, set(), MANIFEST)
        self.assertTrue([f for f in failures if "PRESENT" in f], failures)

    def test_a_confirmed_collision_is_not_a_citable_quote(self):
        self._collision(CITATIONS.canon)
        body = f'quotes "{COLLIDER}" and "{SHIPPED_VALUE}"'
        with self.corpus.aimed(CITATIONS.canon):
            self.assertEqual(CITATIONS._citable_strings_in(body, strict=True), [SHIPPED_VALUE])
            self.assertEqual(CITATIONS._citable_strings_in(body), [SHIPPED_VALUE])

    # -- check-policy-literals-against-canon.py: 408, 567, 609 -------------------------------

    def _buckets(self, committed):
        with self.corpus.aimed(POLICY.canon), \
                mock.patch.object(POLICY, "_composition_evidence_missing", lambda: []):
            return POLICY.verify_buckets_offline(committed)

    def test_a_confirmed_collision_is_not_credited_as_a_strings_value(self):
        self._collision(POLICY.canon)
        problems = self._buckets({COLLIDER: "strings_value"})
        self.assertTrue(any("strings_value" in p for p in problems), problems)
        self.assertEqual(self._buckets({COLLIDER: "nowhere"}), [])
        self.assertEqual(self._buckets({SHIPPED_VALUE: "strings_value"}), [])

    def test_an_unconfirmed_prefix_is_not_credited_either(self):
        self._unconfirmed(POLICY.canon)
        problems = self._buckets({COLLIDER: "strings_value"})
        self.assertTrue(any("confirm" in p for p in problems), problems)
        problems = self._buckets({COLLIDER: "nowhere"})
        self.assertTrue(any("confirm" in p for p in problems), problems)

    def _templates(self):
        path = os.path.join(self.tmp, "TEMPLATES.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"templates": {"t": {"unit": "u", "values": {"en": "Open %@"}}}}, handle)
        return path

    def test_a_composition_over_a_colliding_noun_is_not_credited(self):
        templates = self._templates()
        with mock.patch.object(POLICY, "TEMPLATES", templates):
            self._collision(POLICY.canon)
            with self.corpus.aimed(POLICY.canon):
                self.assertFalse(POLICY._composed_offline(f"Open {COLLIDER}"))
                self.assertTrue(POLICY._composed_offline(f"Open {SHIPPED_VALUE}"))
            self._unconfirmed(POLICY.canon)
            with self.corpus.aimed(POLICY.canon):
                self.assertFalse(POLICY._composed_offline(f"Open {COLLIDER}"))

    def _near_misses(self, canonical):
        with self.corpus.aimed(POLICY.canon), \
                mock.patch.object(POLICY, "all_named_canonicals", lambda: {"someLabel": canonical}), \
                mock.patch.object(POLICY, "decoration_rules", lambda: {}):
            return POLICY.near_miss_canonicals(MANIFEST)

    def test_a_colliding_canonical_does_not_clear_its_near_miss(self):
        self._collision(POLICY.canon, near=canon.NEAR)
        found = self._near_misses(COLLIDER)
        self.assertEqual(len(found), 1, found)
        self.assertIn("differing from it only by decoration", found[0])
        self.assertEqual(self._near_misses(SHIPPED_VALUE), [])
        self._unconfirmed(POLICY.canon)
        found = self._near_misses(COLLIDER)
        self.assertEqual(len(found), 1, found)
        self.assertIn("confirm", found[0])

    # -- check-shipped-python-has-no-ui-literals.py: 165 -------------------------------------

    def test_a_confirmed_collision_is_not_a_value_apple_ships(self):
        self._collision(canon)
        with self.corpus.aimed(canon):
            self.assertIsNone(SHIPPED._apple_ships(canon, COLLIDER))
            self.assertEqual(SHIPPED._apple_ships(canon, SHIPPED_VALUE), "strings/en")
        self._unconfirmed(canon)
        with self.corpus.aimed(canon):
            self.assertIn("unconfirmed", SHIPPED._apple_ships(canon, COLLIDER))

    # -- check-new-labelsets-name-a-row.py: 189 ----------------------------------------------

    def test_a_waiver_over_a_confirmed_collision_is_not_refused(self):
        self._collision(canon)
        entry = {"why_no_row": "drawn at runtime"}
        with self.corpus.aimed(canon):
            failures = []
            NEW_LABELSETS.prove_absent("someLabel", entry, COLLIDER, canon, failures)
            self.assertEqual(failures, [])
            NEW_LABELSETS.prove_absent("someLabel", entry, SHIPPED_VALUE, canon, failures)
            self.assertTrue(any("IS a value" in f for f in failures), failures)
        self._unconfirmed(canon)
        with self.corpus.aimed(canon):
            failures = []
            NEW_LABELSETS.prove_absent("someLabel", entry, COLLIDER, canon, failures)
            self.assertTrue(any("confirm" in f for f in failures), failures)


if __name__ == "__main__":
    unittest.main()
