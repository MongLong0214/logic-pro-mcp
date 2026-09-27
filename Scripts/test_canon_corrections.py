#!/usr/bin/env python3
"""Regression cases for the canon corrections of ADR-027 (#1028), from audit B.

Every case here was written to FAIL on the code before the corrections (d81c7e5b) and pass after.
They build small fake Logic bundles in a temporary directory and point `logic_canon` at a
temporary canon directory, so nothing here needs Logic and nothing touches `docs/canon/`.

    D1   a file that IS the English file is `not_localized`, and resolves to that state
    ten  every source, and the bundle, is checked for a new or missing language folder
    D3   a value Apple stopped shipping fails; the value index is pruned; unconfirmed is enforced
    D4   `#ci` is `fold_case` and nothing else; a v2 index migrates and says what moved
    D6   `.strings` parsing agrees with CoreFoundation, or refuses
    D7   the CLI refuses an unknown source, an offline value citation and an unknown locale
    dict `.stringsdict` is extracted, including the UTF-16 files plistlib refuses
    drift `status` compares the extractor version and the set of sources with the pin

References are assembled from pieces so the repository's citation scan does not read them as
citations this tree makes.
"""
import contextlib
import importlib.util
import io
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEME = "logic-canon" + "://"


def _load():
    spec = importlib.util.spec_from_file_location("logic_canon_corrections",
                                                  os.path.join(HERE, "logic_canon.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


canon = _load()


def _strings(pairs) -> bytes:
    return "".join(f'"{k}" = "{v}";\n' for k, v in pairs).encode("utf-8")


def _quickhelp(entries) -> bytes:
    return plistlib.dumps({key: {"_LOCALIZABLE_": {"Title": title, "Text": text}}
                           for key, (title, text) in entries.items()})


class FakeLogic:
    """A bundle with the files given, and a canon directory of its own."""

    def __init__(self, tmp, files, version="12.3", build="6674", plugin_map=True):
        self.app = os.path.join(tmp, "Logic Pro.app")
        self.repo = os.path.join(tmp, "repo")
        # Every Logic carries the plug-in map, and a missing one stops the build (#1034 R1-01),
        # so a fake bundle carries an empty one unless the test is about its absence.
        plugin_rel = os.path.join(*canon.PLUGIN_NAMES_PATH)
        if plugin_map and plugin_rel not in files:
            files = {**files, plugin_rel: plistlib.dumps({})}
        os.makedirs(os.path.join(self.app, "Contents", "Resources"), exist_ok=True)
        with open(os.path.join(self.app, "Contents", "Info.plist"), "wb") as handle:
            plistlib.dump({"CFBundleName": "Logic Pro", "CFBundleShortVersionString": version,
                           "CFBundleVersion": build}, handle)
        for rel, data in files.items():
            path = os.path.join(self.app, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as handle:
                handle.write(data)
        os.makedirs(os.path.join(self.repo, "docs", "locale"), exist_ok=True)
        os.makedirs(os.path.join(self.repo, "docs", "observations"), exist_ok=True)
        with open(os.path.join(self.repo, "docs", "locale", "ui-labels.json"), "w") as handle:
            json.dump({"labels": {}}, handle)

    def rewrite(self, rel, data):
        path = os.path.join(self.app, rel)
        if data is None:
            os.remove(path)
            return
        with open(path, "wb") as handle:
            handle.write(data)

    def cite(self, *refs):
        with open(os.path.join(self.repo, "docs", "cites.md"), "w") as handle:
            handle.write("\n".join(refs) + "\n")

    def cite_value(self, ref, value):
        with open(os.path.join(self.repo, "docs", "observations", "v.json"), "w") as handle:
            json.dump({"canon": [{"ref": ref, "value": value}]}, handle)


@contextlib.contextmanager
def pointed_at(tmp, locales=("de", "en", "it"), aliases=None):
    """Every path `logic_canon` writes, redirected into `tmp`; the locale list narrowed.

    Only `strings`, `quickhelp` and `stringsdict` are held to the locale list here -- a fake bundle
    carries no nibs -- so a build over every source can run on one.
    """
    canon_dir = os.path.join(tmp, "canon")
    patch = {
        "CANON_DIR": canon_dir,
        "INDEX_DIR": os.path.join(canon_dir, "index"),
        "ABSENCE_DIR": os.path.join(canon_dir, "absence"),
        "MANIFEST_PATH": os.path.join(canon_dir, "MANIFEST.json"),
        "SOURCES_PATH": os.path.join(canon_dir, "SOURCES.json"),
        "LEDGER_DIR": os.path.join(canon_dir, "ledger"),
        "EXPECTED_LOCALES": tuple(locales),
        "QUICKHELP_LOCALE_ALIASES": {"it": "en"} if aliases is None else aliases,
        "SOURCE_LOCALES": {"quickhelp": ("ten", False), "strings": ("ten", True),
                           "stringsdict": ((), False), "niblabels": ((), True),
                           "nibstrings": ((), False), "madsp": ((), True), "nib": ((), True),
                           "plugin_names": ((), True)},
    }
    before = {name: getattr(canon, name) for name in patch if hasattr(canon, name)}
    for name, value in patch.items():
        setattr(canon, name, value)
    try:
        yield
    finally:
        for name, value in before.items():
            setattr(canon, name, value)


def _build(fake, sources):
    return canon.build(fake.app, sources=sources, refresh_citations=True, repo=fake.repo)


def _ref(source, unit, locale, key, field):
    return canon.citation_for(source, unit, locale, key, field)


# ---------------------------------------------------------------------------------------------
# D1 -- proof of translation
# ---------------------------------------------------------------------------------------------

ENGLISH_QH = {"K1": ("Toggle Track Record Enable", "Turns recording on."),
              "K2": ("Mute", "Silences the track.")}
GERMAN_QH = {"K1": ("Spur aufnahmebereit", "Schaltet die Aufnahme ein."),
             "K2": ("Mute", "Schaltet die Spur stumm.")}


def _qh_bundle():
    return {
        "Contents/Resources/en.lproj/QuickHelp.plist": _quickhelp(ENGLISH_QH),
        "Contents/Resources/it.lproj/QuickHelp.plist": _quickhelp(ENGLISH_QH),
        "Contents/Resources/de.lproj/QuickHelp.plist": _quickhelp(GERMAN_QH),
    }


class D1AnEnglishFileIsNotItalian(unittest.TestCase):
    def test_a_byte_identical_file_resolves_to_not_localized(self):
        with tempfile.TemporaryDirectory() as tmp, pointed_at(tmp):
            fake = FakeLogic(tmp, _qh_bundle())
            it_ref = _ref("quickhelp", "QuickHelp", "it", "K1", "Title")
            fake.cite(it_ref)
            _build(fake, ["quickhelp"])
            ref = canon.CanonRef.parse(it_ref)
            self.assertEqual(canon.resolve_offline(ref), canon.NOT_LOCALIZED,
                             "the Italian row of the English file resolved to a digest")
            with self.assertRaises(canon.CanonError):
                canon.check_citation(it_ref, "Toggle Track Record Enable")
            manifest = canon.load_manifest()
            self.assertEqual(manifest["sources"]["quickhelp"]["not_localized"], {"it": ["QuickHelp"]})

    def test_a_row_equal_to_english_inside_a_translated_file_is_credited(self):
        """`Mute` in the German file is German: the file as a whole is translated."""
        with tempfile.TemporaryDirectory() as tmp, pointed_at(tmp):
            fake = FakeLogic(tmp, _qh_bundle())
            de_ref = _ref("quickhelp", "QuickHelp", "de", "K2", "Title")
            fake.cite(de_ref)
            manifest = _build(fake, ["quickhelp"])
            canon.check_citation(de_ref, "Mute")
            self.assertEqual(
                manifest["sources"]["quickhelp"]["english_equal_rows_in_translated_units"],
                {"de": 1}, "the false-negative cost is counted: the one Title equal to English")

    def test_status_names_the_not_localized_units(self):
        with tempfile.TemporaryDirectory() as tmp, pointed_at(tmp):
            fake = FakeLogic(tmp, _qh_bundle())
            _build(fake, ["quickhelp"])
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                canon.main(["--app", os.path.join(tmp, "absent.app"), "status"])
            self.assertIn("NOT LOCALIZED", out.getvalue())

    def test_census_names_the_not_localized_units(self):
        with tempfile.TemporaryDirectory() as tmp, pointed_at(tmp):
            fake = FakeLogic(tmp, _qh_bundle())
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                canon.main(["--app", fake.app, "census"])
            census = json.loads(out.getvalue())
            self.assertEqual(census["quickhelp"]["not_localized_units"], {"it": 1})

    def test_the_casefold_ledger_does_not_credit_the_english_file(self):
        with tempfile.TemporaryDirectory() as tmp, pointed_at(tmp):
            fake = FakeLogic(tmp, _qh_bundle())
            with open(os.path.join(fake.repo, "docs", "locale", "ui-labels.json"), "w") as handle:
                json.dump({"labels": {"x": {"canonical": "Toggle Track Record Enable"}}}, handle)
            _build(fake, ["quickhelp"])
            self.assertFalse(canon.ships_up_to_case("quickhelp", "it", "Toggle Track Record Enable"))
            self.assertTrue(canon.ships_up_to_case("quickhelp", "en", "Toggle Track Record Enable"))


# ---------------------------------------------------------------------------------------------
# the ten-locale check covers every source and the whole bundle
# ---------------------------------------------------------------------------------------------

def _strings_bundle(locales=("de", "en", "it")):
    words = {"de": "Spur", "en": "Track", "it": "Traccia", "xx": "Trk"}
    return {f"Contents/Resources/{loc}.lproj/Main.strings": _strings([("track", words[loc])])
            for loc in locales}


class TenLocalesInEverySource(unittest.TestCase):
    def _refuses(self, files, sources=("strings",)):
        with tempfile.TemporaryDirectory() as tmp, pointed_at(tmp):
            fake = FakeLogic(tmp, files)
            with self.assertRaises(canon.CanonError) as caught:
                _build(fake, list(sources))
            self.assertFalse(os.path.exists(canon.MANIFEST_PATH), "something was written")
            self.assertFalse(os.path.isdir(canon.ABSENCE_DIR) and os.listdir(canon.ABSENCE_DIR),
                             "an absence set was written before the check")
            return str(caught.exception)

    def test_a_new_language_in_strings_fails(self):
        message = self._refuses(_strings_bundle(("de", "en", "it", "xx")))
        self.assertIn("xx", message)

    def test_a_missing_language_in_strings_fails(self):
        message = self._refuses(_strings_bundle(("de", "en")))
        self.assertIn("it", message)

    def test_a_language_folder_no_source_reads_fails(self):
        files = _strings_bundle()
        files["Contents/Resources/xx.lproj/picture.png"] = b"\x89PNG"
        self.assertIn("xx.lproj", self._refuses(files))

    def test_stringsdict_is_in_the_check(self):
        self.assertIn("stringsdict", canon.SOURCE_LOCALES)
        with pointed_at(tempfile.gettempdir(), locales=("en", "it")):
            with self.assertRaises(canon.CanonError):
                canon.check_source_locales("stringsdict", {"en"})


# ---------------------------------------------------------------------------------------------
# D3 -- a value Apple stops shipping stops being citable
# ---------------------------------------------------------------------------------------------

class D3TwoBuilds(unittest.TestCase):
    def test_a_removed_value_fails_and_is_pruned(self):
        with tempfile.TemporaryDirectory() as tmp, pointed_at(tmp):
            first = {f"Contents/Resources/{loc}.lproj/Main.strings":
                     _strings([("a", {"de": "Alt", "en": "Old Label", "it": "Vecchio"}[loc])])
                     for loc in ("de", "en", "it")}
            fake = FakeLogic(tmp, first)
            value_ref = SCHEME + "strings/en#value"
            fake.cite_value(value_ref, "Old Label")
            _build(fake, ["strings"])
            canon.check_citation(value_ref, "Old Label")

            # Build two: Apple renamed the string. The citation stays in the tree.
            for loc, word in (("de", "Neu"), ("en", "New Label"), ("it", "Nuovo")):
                fake.rewrite(f"Contents/Resources/{loc}.lproj/Main.strings",
                             _strings([("a", word)]))
            manifest = _build(fake, ["strings"])
            with self.assertRaises(canon.CanonError):
                canon.check_citation(value_ref, "Old Label")
            self.assertEqual(manifest["sources"]["strings"].get("unconfirmed_values"),
                             ["en: 'Old Label'"])
            self.assertTrue(canon.verify_citations_confirmed(manifest),
                            "an unconfirmed value is recorded and nothing reads it")


# ---------------------------------------------------------------------------------------------
# D4 -- one fold, and a versioned migration
# ---------------------------------------------------------------------------------------------

class D4OneFold(unittest.TestCase):
    def test_ci_is_fold_case_and_nothing_else(self):
        nbsp = "Setup …"
        self.assertNotEqual(canon.ci_digest(nbsp), canon.ci_digest("Setup …"),
                            "a no-break space folded to a space: no LabelSet does that")
        self.assertEqual(canon.ci_digest("MIXER"), canon.ci_digest("Mixer"))

    def test_the_index_pins_the_fold_the_matcher_performs(self):
        with tempfile.TemporaryDirectory() as tmp, pointed_at(tmp):
            files = {f"Contents/Resources/{loc}.lproj/Main.strings":
                     _strings([("s", {"de": "Setup …", "en": "Setup…",
                                      "it": "Configura…"}[loc])])
                     for loc in ("de", "en", "it")}
            fake = FakeLogic(tmp, files)
            unit = next(row[0] for row in canon.extract_strings(fake.app))
            fake.cite(_ref("strings", unit, "en", "s", "value"))
            _build(fake, ["strings"])
            index = canon.load_index("strings")
            pinned = index[(unit, "de", "s", "value" + canon.CASE_INSENSITIVE)]
            self.assertEqual(pinned, canon.ci_digest("Setup …"))
            self.assertNotEqual(pinned, canon.ci_digest("Setup …"))

            def lookup(suffix):
                return index.get((unit, "de", "s", "value" + suffix))

            self.assertEqual(canon.label_row_credit(lookup, ["Setup …"], strict=False)[0],
                             canon.UNCOVERED)
            self.assertEqual(canon.label_row_credit(lookup, ["setup …"], strict=False)[0],
                             canon.COVERED)

    def test_a_v2_index_is_migrated_not_silently_rekeyed(self):
        with tempfile.TemporaryDirectory() as tmp, pointed_at(tmp):
            fake = FakeLogic(tmp, {**_strings_bundle(), **_qh_bundle()})
            unit = next(row[0] for row in canon.extract_strings(fake.app))
            fake.cite(_ref("strings", unit, "en", "track", "value"))
            _build(fake, ["strings"])
            manifest = canon.load_manifest()
            manifest["extractor_version"] = 2
            with open(canon.MANIFEST_PATH, "w") as handle:
                json.dump(manifest, handle)
            with self.assertRaises(canon.CanonError):
                _build(fake, ["strings"])          # a partial rebuild across folds is refused
            migrated = _build(fake, sorted(canon.EXTRACTORS))
            self.assertEqual(migrated["migration"]["from_extractor"], 2)
            self.assertIn("ci_rows_rekeyed", migrated["migration"])


# ---------------------------------------------------------------------------------------------
# D6 -- CoreFoundation parity, with byte inputs
# ---------------------------------------------------------------------------------------------

class D6ParserParity(unittest.TestCase):
    def parse(self, data: bytes):
        return canon.parse_strings(data, path="fixture.strings")

    def test_a_high_octal_escape_is_refused_not_decoded_as_latin1(self):
        with self.assertRaises(canon.CanonDecodeError):
            self.parse(b'"a" = "\\351";')

    def test_a_low_octal_escape_is_its_character(self):
        self.assertEqual(self.parse(b'"a" = "\\101";'), {"a": "A"})

    def test_a_short_unicode_escape_takes_the_digits_it_has(self):
        self.assertEqual(self.parse(b'"a" = "\\U41";'), {"a": "A"})
        self.assertEqual(self.parse(b'"a" = "\\U00411";'), {"a": "A1"})

    def test_a_key_without_a_value_is_its_own_value(self):
        self.assertEqual(self.parse(b'"Cancel";'), {"Cancel": "Cancel"})

    def test_an_unquoted_key_may_carry_a_colon(self):
        self.assertEqual(self.parse(b'key:x = "v";'), {"key:x": "v"})

    def test_a_missing_semicolon_is_refused(self):
        with self.assertRaises(canon.CanonDecodeError):
            self.parse(b'"a" = "b"\n"c" = "d";')


# ---------------------------------------------------------------------------------------------
# D7 -- the CLI fails loudly
# ---------------------------------------------------------------------------------------------

class D7TheCommandLine(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, os.path.join(HERE, "logic_canon.py"), *args],
                              capture_output=True, text=True)

    def test_an_unknown_source_is_refused_with_a_message(self):
        with tempfile.TemporaryDirectory() as tmp:
            FakeLogic(tmp, {})
            proc = self.run_cli("--app", os.path.join(tmp, "Logic Pro.app"), "resolve",
                                SCHEME + "bogus/u/ko/k#value")
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn("Traceback", proc.stderr)
        self.assertIn("unknown source", proc.stderr)

    def test_an_offline_value_citation_is_refused(self):
        proc = self.run_cli("--app", "/nonexistent.app", "resolve", SCHEME + "strings/en#value")
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("names no row", proc.stderr)

    def test_an_unknown_locale_is_refused(self):
        proc = self.run_cli("--app", "/nonexistent.app", "resolve",
                            SCHEME + "strings/klingon#value")
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("not a locale Logic ships", proc.stderr)
        with self.assertRaises(canon.CanonError) as caught:
            canon.check_citation(SCHEME + "strings/klingon#value", "x")
        self.assertIn("not a locale Logic ships", str(caught.exception))


# ---------------------------------------------------------------------------------------------
# .stringsdict
# ---------------------------------------------------------------------------------------------

def _stringsdict(key, one, other) -> bytes:
    return plistlib.dumps({key: {
        "NSStringLocalizedFormatKey": "%#@n@",
        "n": {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
              "NSStringFormatValueTypeKey": "d", "one": one, "other": other}}})


class StringsDict(unittest.TestCase):
    def test_utf16_with_a_bom_declaring_utf8_is_read(self):
        """Five of Apple's files are exactly this, and plistlib refuses them."""
        data = _stringsdict("tracks", "%d track", "%d tracks").decode("utf-8")
        raw = b"\xff\xfe" + data.encode("utf-16-le")
        with self.assertRaises(Exception):
            plistlib.loads(raw)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "Localizable.stringsdict")
            with open(path, "wb") as handle:
                handle.write(raw)
            self.assertEqual(canon.load_stringsdict(path)["tracks"]["n"]["one"], "%d track")

    def test_plural_forms_are_extracted_per_locale(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = FakeLogic(tmp, {
                "Contents/Resources/en.lproj/L.stringsdict": _stringsdict("t", "%d track", "%d tracks"),
                "Contents/Resources/de.lproj/L.stringsdict": _stringsdict("t", "%d Spur", "%d Spuren"),
            })
            rows = {(r[1], r[2], r[3]): r[4] for r in canon.extract_stringsdict(fake.app)}
            self.assertEqual(rows[("de", "t/n", "other")], "%d Spuren")
            self.assertEqual(rows[("en", "t", "format")], "%#@n@")

    def test_a_shape_it_cannot_read_stops_naming_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = plistlib.dumps({"t": {"NSStringLocalizedFormatKey": "%#@n@",
                                        "n": {"NSStringFormatSpecTypeKey": "NSStringDeviceSpecificRuleType"}}})
            fake = FakeLogic(tmp, {"Contents/Resources/en.lproj/Bad.stringsdict": bad})
            with self.assertRaises(canon.CanonError) as caught:
                list(canon.extract_stringsdict(fake.app))
            self.assertIn("Bad.stringsdict", str(caught.exception))


class AStringsDictEntryIsCompleteOrItFails(unittest.TestCase):
    """Review of #1034 R1-02. Rows were yielded as each field was met and nothing was required, so
    an entry holding only a `one` form extracted as that one row, with no error. Each test removes
    one required field from a complete entry.

    Mutation killed, per test: deleting the one requirement it names from `_stringsdict_entry`."""

    def _refused(self, entry, *, needle):
        with tempfile.TemporaryDirectory() as tmp:
            fake = FakeLogic(tmp, {"Contents/Resources/en.lproj/Short.stringsdict":
                                   plistlib.dumps({"tracks": entry})})
            with self.assertRaises(canon.CanonDecodeError) as caught:
                list(canon.extract_stringsdict(fake.app))
        message = str(caught.exception)
        self.assertIn("Short.stringsdict", message)
        self.assertIn("'tracks'", message)
        self.assertIn(needle, message)

    @staticmethod
    def _complete():
        return {"NSStringLocalizedFormatKey": "%#@n@",
                "n": {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                      "NSStringFormatValueTypeKey": "d", "one": "%d track", "other": "%d tracks"}}

    def test_the_reviewers_entry_with_only_a_one_form_fails(self):
        self._refused({"NSStringLocalizedFormatKey": "%#@n@",
                       "n": {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                             "NSStringFormatValueTypeKey": "d", "one": "%d track"}},
                      needle="no `other` form")

    def test_no_format_key_fails(self):
        entry = self._complete()
        del entry["NSStringLocalizedFormatKey"]
        self._refused(entry, needle="no NSStringLocalizedFormatKey")

    def test_no_spec_type_key_fails(self):
        entry = self._complete()
        del entry["n"]["NSStringFormatSpecTypeKey"]
        self._refused(entry, needle="no NSStringFormatSpecTypeKey")

    def test_no_value_type_key_fails(self):
        entry = self._complete()
        del entry["n"]["NSStringFormatValueTypeKey"]
        self._refused(entry, needle="no NSStringFormatValueTypeKey")

    def test_no_other_form_fails(self):
        entry = self._complete()
        del entry["n"]["other"]
        self._refused(entry, needle="no `other` form")

    def test_the_complete_entry_extracts(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = FakeLogic(tmp, {"Contents/Resources/en.lproj/Short.stringsdict":
                                   plistlib.dumps({"tracks": self._complete()})})
            rows = sorted(r[2:] for r in canon.extract_stringsdict(fake.app))
        self.assertEqual(rows, [("tracks", "format", "%#@n@"), ("tracks/n", "one", "%d track"),
                                ("tracks/n", "other", "%d tracks")])


# ---------------------------------------------------------------------------------------------
# plugin_names -- DefaultPluginMapping.plist, the one file that names Channel EQ
# ---------------------------------------------------------------------------------------------

PLUGIN_MAP = os.path.join(*canon.PLUGIN_NAMES_PATH)


class PlugInNames(unittest.TestCase):
    def test_every_entry_is_a_row_in_no_locale(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = FakeLogic(tmp, {PLUGIN_MAP: plistlib.dumps(
                {"EMAG|0236|0000": "Channel EQ", "EMAG|0001|0000": "Gain"})})
            rows = sorted(canon.extract_plugin_names(fake.app))
        self.assertEqual(rows, [("EMAG|0001|0000", "-", "name", "value", "Gain"),
                                ("EMAG|0236|0000", "-", "name", "value", "Channel EQ")])

    def test_a_shape_it_cannot_read_stops_naming_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = FakeLogic(tmp, {PLUGIN_MAP: plistlib.dumps({"EMAG|0236|0000": 7})})
            with self.assertRaises(canon.CanonError) as caught:
                list(canon.extract_plugin_names(fake.app))
        self.assertIn("DefaultPluginMapping.plist", str(caught.exception))

    def test_no_language_folder_is_demanded_and_every_row_is_pinned(self):
        """Locale-independent: the ten-locale check asks it for no `.lproj`, and every row is
        pinned, so the name can be cited offline by the row it came from."""
        with tempfile.TemporaryDirectory() as tmp:
            files = _strings_bundle()
            files[PLUGIN_MAP] = plistlib.dumps({"EMAG|0236|0000": "Channel EQ",
                                                "EMAG|0001|0000": "Gain"})
            fake = FakeLogic(tmp, files)
            with pointed_at(tmp), contextlib.redirect_stdout(io.StringIO()):
                _build(fake, ["plugin_names", "strings"])
                manifest = canon.load_manifest()
                cited = canon.locale_independent_citations("Channel EQ")
                made_up = canon.locale_independent_citations("Channel EQX")
        self.assertEqual(manifest["sources"]["plugin_names"]["locales"], ["-"])
        self.assertEqual(manifest["sources"]["plugin_names"]["entries"], 2)
        self.assertEqual(cited, ["logic-canon://plugin_names/EMAG%7C0236%7C0000/-/name#value"])
        self.assertEqual(made_up, [])


class APinnedSourceIsRebuiltNotMerged(unittest.TestCase):
    """Review of #1034 R1-01. Two identities in Logic's map share `Vintage Mellotron`, so the
    value-presence check cannot tell a removed one from the one that stays. A rebuild used to merge
    the committed index back in, and the removed identity went on resolving.

    Mutation killed: `merged = {} if migrating else load_index(source)` (the merge as it was) in
    place of `retaken(...)`, and `return` in place of the raise for a missing map."""

    GONE, KEPT = "CLEM|1231968114|0001", "EMAG|0312|0002"

    def _two_builds(self, *, refresh_second=True):
        files = _strings_bundle()
        files[PLUGIN_MAP] = plistlib.dumps({self.GONE: "Vintage Mellotron",
                                            self.KEPT: "Vintage Mellotron"})
        with tempfile.TemporaryDirectory() as tmp, pointed_at(tmp), \
                contextlib.redirect_stdout(io.StringIO()):
            fake = FakeLogic(tmp, files)
            ref = _ref("plugin_names", self.GONE, "-", "name", "value")
            fake.cite_value(ref, "Vintage Mellotron")
            _build(fake, ["plugin_names", "strings"])
            canon.check_citation(ref, "Vintage Mellotron")
            fake.rewrite(PLUGIN_MAP, plistlib.dumps({self.KEPT: "Vintage Mellotron"}))
            manifest = canon.build(fake.app, sources=["plugin_names", "strings"],
                                   refresh_citations=refresh_second, repo=fake.repo)
            units = {row[0] for row in canon.load_index("plugin_names")}
            with self.assertRaises(canon.CanonError):
                canon.check_citation(ref, "Vintage Mellotron")
            return manifest, units, canon.verify_index_against_absence(), ref

    def test_a_removed_identity_is_not_carried_and_its_citation_fails(self):
        manifest, units, problems, ref = self._two_builds()
        self.assertEqual(units, {self.KEPT})
        self.assertEqual(manifest["sources"]["plugin_names"].get("unresolved_citations"), [ref])
        self.assertTrue(canon.verify_citations_confirmed(manifest))
        self.assertEqual(problems, [])

    def test_a_rebuild_without_citations_drops_it_too(self):
        _manifest, units, _problems, _ref_text = self._two_builds(refresh_second=False)
        self.assertEqual(units, {self.KEPT})

    def test_an_index_with_a_row_its_corpus_lacks_is_a_problem(self):
        files = _strings_bundle()
        files[PLUGIN_MAP] = plistlib.dumps({self.KEPT: "Vintage Mellotron"})
        with tempfile.TemporaryDirectory() as tmp, pointed_at(tmp), \
                contextlib.redirect_stdout(io.StringIO()):
            fake = FakeLogic(tmp, files)
            _build(fake, ["plugin_names", "strings"])
            index = canon.load_index("plugin_names")
            row = (self.GONE, "-", "name", "value")
            index[row] = index[(self.KEPT, "-", "name", "value")]
            canon.write_index("plugin_names", index)
            problems = canon.verify_index_against_absence()
        self.assertTrue(any("holds 2 rows and its corpus has 1" in p for p in problems), problems)

    def test_a_missing_map_fails_the_build(self):
        with tempfile.TemporaryDirectory() as tmp, pointed_at(tmp), \
                contextlib.redirect_stdout(io.StringIO()):
            fake = FakeLogic(tmp, _strings_bundle(), plugin_map=False)
            with self.assertRaises(canon.CanonError) as caught:
                _build(fake, ["plugin_names", "strings"])
            self.assertIn("DefaultPluginMapping.plist is missing", str(caught.exception))
            self.assertFalse(os.path.exists(canon.MANIFEST_PATH), "nothing is written")

    def test_a_cited_key_apple_dropped_leaves_the_key_index_too(self):
        """The same retention in every key index: `strings` carries a value under two keys, the
        cited key goes, the value stays under the other. Mutation killed: the old merge."""
        def bundle(keys):
            return {f"Contents/Resources/{loc}.lproj/Main.strings":
                    _strings([(k, {"de": "Spur", "en": "Track", "it": "Traccia"}[loc]) for k in keys])
                    for loc in ("de", "en", "it")}
        with tempfile.TemporaryDirectory() as tmp, pointed_at(tmp), \
                contextlib.redirect_stdout(io.StringIO()):
            fake = FakeLogic(tmp, bundle(["a", "b"]))
            ref = _ref("strings", "Contents/Resources/Main.strings", "en", "a", "value")
            fake.cite(ref)
            _build(fake, ["strings"])
            canon.check_citation(ref, "Track")
            for loc in ("de", "en", "it"):
                fake.rewrite(f"Contents/Resources/{loc}.lproj/Main.strings",
                             bundle(["b"])[f"Contents/Resources/{loc}.lproj/Main.strings"])
            manifest = _build(fake, ["strings"])
            keys = {row[2] for row in canon.load_index("strings")}
            with self.assertRaises(canon.CanonError):
                canon.check_citation(ref, "Track")
        self.assertNotIn("a", keys)
        self.assertEqual(manifest["sources"]["strings"].get("unresolved_citations"), [ref])


# ---------------------------------------------------------------------------------------------
# drift -- status compares the extractor and the sources, not only the build
# ---------------------------------------------------------------------------------------------

class DriftInStatus(unittest.TestCase):
    def test_an_index_from_another_extractor_is_drift(self):
        with tempfile.TemporaryDirectory() as tmp, pointed_at(tmp):
            fake = FakeLogic(tmp, {**_strings_bundle(), **_qh_bundle()})
            _build(fake, sorted(canon.EXTRACTORS))
            manifest = canon.load_manifest()
            manifest["extractor_version"] = canon.EXTRACTOR_VERSION - 1
            with open(canon.MANIFEST_PATH, "w") as handle:
                json.dump(manifest, handle)
            err = io.StringIO()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
                code = canon.main(["--app", fake.app, "status"])
            self.assertEqual(code, 1)
            self.assertIn("extractor", err.getvalue())


# ---------------------------------------------------------------------------------------------
# the generated table stops calling English Italian
# ---------------------------------------------------------------------------------------------

class TheGeneratedTableSaysNotLocalized(unittest.TestCase):
    """Against the committed canon, offline. `AXLocaleValues.swift` shipped the English
    `Toggle Track Record Enable` as it-IT, pt-BR and zh-TW; the generator now leaves those out and
    says why, and guesses nothing in their place."""

    def test_record_arm_is_not_english_in_italian(self):
        spec = importlib.util.spec_from_file_location("locale_labels_corrections",
                                                      os.path.join(HERE, "locale_labels.py"))
        labels = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(labels)
        swift = labels.render_swift({})
        block = swift[swift.index("static let recordArmKeyCommandName"):]
        block = block[: block.index("\n    ]")]
        for locale in ("it-IT", "pt-BR", "zh-TW"):
            with self.subTest(locale=locale):
                self.assertNotIn(f'"{locale}": "Toggle Track Record Enable"', block)
                self.assertIn(f'// "{locale}": not localized', block)
        self.assertIn('"en-US": "Toggle Track Record Enable"', block, "the control: English stays")


if __name__ == "__main__":
    unittest.main(verbosity=2)
