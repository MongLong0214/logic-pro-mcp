#!/usr/bin/env python3
"""One place to read Logic's UI vocabulary from, for everything that is not Swift.

The strings Logic shows exist in three copies in this repository: `AXLocalePolicy.swift`, the alias
lists inside `Scripts/livekit/evidence.py`, and inline literals in the harnesses themselves. Three
copies of a fact diverge — measured 2026-09-04, thirteen harnesses were still matching English-only
strings for labels the policy had carried a Korean spelling for since #519.

`docs/locale/ui-labels.json` is the machine-readable projection of the Swift, plus the one thing the
Swift cannot hold: **where each variant was measured**. Swift stays the compiled source of truth so
the build is unaffected; the JSON is generated from it and checked against it, and everything that
cannot import Swift reads the JSON instead of guessing.

    Scripts/locale_labels.py --write     regenerate the JSON from AXLocalePolicy.swift (refuses while a
                                         measurement is not bound to a record that exists and matches it)
    Scripts/locale_labels.py --write --rebind
                                         the reviewed act: re-bind digests to records as they are now,
                                         and drop readings whose record no longer exists
    Scripts/locale_labels.py --write --bind-record ID
                                         bind a block that has no digest yet to this record (the census
                                         records `locale-regenerate.py` has just cited)
    Scripts/locale_labels.py --check     exit 1 unless every generated artifact is BYTE-identical to what
                                         this would write, every measured cell is bound to its record, and
                                         the current Logic is declared once
    Scripts/locale_labels.py --report    per locale, how many cells are measured on the declared Logic

SCHEMA 3 adds the version axis: the Logic release is declared once, in Swift (`AXLocalePolicy.
currentLogicVersion`/`currentLogicBuild`, projected as `logic`), and each measurement carries the version
and build of the record that read it, bound by a digest. See the block headed THE VERSION AXIS below and
ADR-019 D9.

`provenance` (schema 2; `measured` in schema 1) is where "the variants list grows when a locale is
observed, not when one is translated" stops being a comment and becomes data: each variant names
the observation record it was read in, the locale that record is true of, the date, and the exact
string that was read. `coverage` says, per supported locale, what is KNOWN about the label —
`measured` (a record in that locale saw one of its strings), `identifier` (addressed by a
locale-free AXIdentifier, and a record saw it), or `unmeasured`, the only one that is a gap. ADR-019.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import textwrap

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT = os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
JSON_PATH = os.path.join(REPO, "docs", "locale", "ui-labels.json")
#: The SHIPPED projection. `docs/locale/ui-labels.json` is for this repository's own tools; the
#: Python helpers `Scripts/install.sh` installs beside the binary cannot read it, because it is not
#: in the release tarball and adding it there would ship a 400 KB ledger to answer six questions.
#:
#: So the labels those helpers need are generated INTO a module that ships, the way
#: `logic_variants.py` already does for a different shared concern. Generated, because the
#: alternative is a hand-maintained second copy -- and this repository measured what that costs
#: this week: `Scripts/livekit/evidence.py` carried a German label the policy lacked for six days
#: while the guard that noticed printed a warning and exited 0.
PY_PATH = os.path.join(REPO, "Scripts", "logic_ui_labels.py")

#: Which LabelSets the shipped helpers need, and under what name each is exported. Adding a row
#: here is what puts a label in the release tarball, so it is a short explicit list rather than a
#: dump of all 179 -- a helper that needs a label it did not ask for is a helper reading a table it
#: does not understand.
SHIPPED_LABELS = {
    "BOUNCE_CONFIRM_BUTTONS": ("okButton",),
    "BOUNCE_DIALOG_KEYWORDS": ("bounceMenuItem",),
    "BOUNCE_SETTINGS_MARKERS": ("bounceRealtimeSetting", "bounceOfflineSetting",
                                "bounceNormalizeSetting"),
    "SAVE_PANEL_CONFIRM_BUTTONS": ("bounceMenuItem",),
    "SAVE_PANEL_CANCEL_BUTTONS": ("cancelButton",),
    "FILE_MENU_BAR_ITEM": ("fileMenuBar",),
    "BOUNCE_PROJECT_OR_SECTION": ("projectOrSectionMenuItem",),
}


#: Literals Apple does NOT translate, kept beside the generated tables because matching them by
#: literal is locale-independent by construction -- the same condition that exempts `MIDI` and
#: `Audio Units` from `check-ax-comparisons-use-labelsets.py`. Verified 2026-09-19 with
#: `canon.is_translated`: both answer False.
#:
#: They are listed rather than dropped because the check that reads them is an ANY over the
#: sheet's static texts, so each one is a chance to recognise the sheet and none of them can be
#: wrong in a language.
UNTRANSLATED_EXTRAS = {
    "BOUNCE_SETTINGS_MARKERS": ("pcm", "audio tail"),
}


#: The Swift side of the same problem, and it is NOT the same shape. `logic_ui_labels.py` hands its
#: consumers a flat folded tuple because they MATCH against a reading; these consumers have to
#: CHOOSE one string to type, and a set cannot answer that. `ArmKeyCommandSetup.searchQuery` types
#: the command name into the Key Commands filter, and an English name typed into a Korean Logic
#: collapses the list to nothing -- so the pick has to be per locale.
#:
#: The mapping is DERIVED, never written down: for each locale the generator takes the LabelSet
#: member whose case-folded digest equals the digest Apple's row is pinned to there, which is the
#: same question `check-labelsets-are-derived.py` already answers. So it runs offline against
#: `docs/canon/index/` and a wrong entry is impossible rather than unlikely.
SWIFT_PATH = os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocaleValues.swift")

#: Which LabelSets need a locale-keyed table, and why each one does. Short and explicit for the
#: same reason `SHIPPED_LABELS` is: a label appears here only because some call site must PICK a
#: single spelling, and every entry is a call site somebody has to point at.
LOCALE_KEYED = {
    "recordArmKeyCommandName":
        "ArmKeyCommandSetup.searchQuery types this into the Key Commands filter, and the filter is "
        "a live search -- the wrong language collapses the list to nothing and the setup then "
        "reports `could not find the command` having never had a chance.",
}

#: Keyed by the identifiers `AXLogicProElements.logicUILocaleIdentifier` returns, so the Swift side
#: needs no mapping of its own. A second copy of `ko-KR -> ko` in another language is a second
#: thing to keep true.
def _load_canon():
    """The canon module and its manifest, cached. `None` on a tree without the canon axis."""
    if "canon" not in _CANON_CACHE:
        try:
            import importlib.util
            spec = importlib.util.spec_from_file_location(
                "logic_canon_for_labels", os.path.join(REPO, "Scripts", "logic_canon.py"))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            _CANON_CACHE["canon"] = module
            _CANON_CACHE["manifest"] = module.load_manifest()
        except Exception:
            _CANON_CACHE["canon"] = None
    return _CANON_CACHE.get("canon")


def _derived_declarations(source: str):
    """`(name, members, derivedFrom)` -- borrowed from the guard rather than parsed again here.

    Two parsers of one declaration syntax drift, and the one that drifts silently is the generator:
    a guard that cannot read a block SAYS so, while a generator just omits a table.
    """
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "labelsets_derived_for_labels",
        os.path.join(REPO, "Scripts", "check-labelsets-are-derived.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return list(module.declarations(source))


def _locale_values(members, ref_text: str, *, strict: bool = False, not_localized=None) -> dict:
    """`{"ko-KR": "키 레이블로 학습", ...}` for one derived LabelSet, resolved offline by digest.

    Empty for a locale the row is not pinned at, or one where no member matches -- both of which
    `check-labelsets-are-derived.py` already refuses, so an empty answer here means that guard is
    failing too and this generator is not the place to report it.

    Also empty for a locale where Apple ships the English file (#1028): `it.lproj/QuickHelp.plist`
    IS the English file, and the value taken from it was generated into this table as Italian.
    Those locales are added to `not_localized` when the caller passes a set, so the generated file
    can say so instead of leaving the gap unexplained. The comparison is `label_row_credit`, the
    same one the guard makes.
    """
    canon = _load_canon()
    if canon is None or not ref_text:
        return {}
    try:
        ref = canon.CanonRef.parse(ref_text)
    except Exception:
        return {}
    manifest = _CANON_CACHE.get("manifest") or {}
    namespace_of = {name: canon.TRANSLATION_NAMESPACE.get(name, name)
                    for name in (manifest.get("sources") or {})}
    peers = [name for name, space in namespace_of.items()
             if space == namespace_of.get(ref.source, ref.source)]
    indexes = {name: canon.load_index(name) for name in peers}
    out = {}
    for locale in SUPPORTED_LOCALES:
        code = _locale_code(locale)

        def pinned(suffix, code=code):
            row = (ref.unit, code, ref.key, ref.field + suffix)
            return next((indexes[name].get(row) for name in peers if indexes[name].get(row)), None)

        state, member = canon.label_row_credit(pinned, members, strict=strict)
        if state == canon.COVERED:
            out[locale] = member
        elif state == canon.NOT_LOCALIZED and not_localized is not None:
            not_localized.add(locale)
    # A bare language subtag too, but ONLY where it names one locale. `logicUILocaleIdentifier`
    # answers `ko-KR`, and callers that carry a language alone -- a test, a config, a host that
    # reports `de` -- would otherwise fall back to English for a language Apple translates. `zh`
    # is the reason this is derived rather than assumed: it names `zh-CN` AND `zh-TW`, and a table
    # that picked one would answer Simplified on a Traditional host and never say it guessed.
    # Counted over EVERY supported locale, not the ones that got a value: with zh-TW not localized,
    # counting only `out` made `zh` name zh-CN alone.
    subtags = {}
    for locale in SUPPORTED_LOCALES:
        subtags.setdefault(locale.split("-")[0], []).append(locale)
    for subtag, locales in subtags.items():
        if len(locales) == 1 and subtag not in out and locales[0] in out:
            out[subtag] = out[locales[0]]
    return out


def render_swift(doc: dict) -> str:
    """One `[String: String]` per name in `LOCALE_KEYED`, keyed by the identifier Logic reports."""
    with open(SWIFT, encoding="utf-8") as handle:
        source = handle.read()
    derived = {name: ref for name, _members, ref in _derived_declarations(source)}
    members_of = {name: members for name, members, _ref in _derived_declarations(source)}
    lines = [
        "// Logic label values, per control, keyed by the locale identifier Logic reports.",
        "//",
        "// GENERATED by Scripts/locale_labels.py --write from AXLocalePolicy.swift and",
        "// docs/canon/index/. Do not edit: the next --write overwrites it, and the policy is where",
        "// a label is added, cited and checked.",
        "//",
        "// A LabelSet answers \"does this reading match?\" and that is the right question almost",
        "// everywhere. It cannot answer \"which spelling do I TYPE on this host?\", because its",
        "// members carry no locale. These tables answer that one, and they are derived rather than",
        "// written: each value is the member whose case-folded digest equals the digest Apple's own",
        "// row is pinned to in that locale.",
        "enum AXLocaleValues {",
    ]
    missing = []
    for name, why in sorted(LOCALE_KEYED.items()):
        if name not in members_of:
            missing.append(name)
            continue
        not_localized = set()
        values = _locale_values(members_of[name], derived.get(name),
                                strict=name in _EXACT_STRICT, not_localized=not_localized)
        lines.append("")
        for chunk in textwrap.wrap(why, 94):
            lines.append(f"    /// {chunk}")
        lines.append(f"    /// Apple's row: {derived.get(name) or '(none)'}")
        lines.append(f"    static let {name}: [String: String] = [")
        # Full identifiers in the order Logic ships them, then the bare subtags, sorted. A
        # generated file that reorders itself turns every regeneration into a diff nobody reads.
        ordered = ([locale for locale in SUPPORTED_LOCALES if locale in values]
                   + sorted(key for key in values if key not in SUPPORTED_LOCALES))
        for key in ordered:
            escaped = values[key].replace("\\", "\\\\").replace('"', '\\"')
            lines.append(f'        "{key}": "{escaped}",')
        # No value, and no guess: Apple ships the English file for these (#1028). A caller that
        # falls back to English here types English into a translated UI.
        for locale in [locale for locale in SUPPORTED_LOCALES if locale in not_localized]:
            lines.append(f'        // "{locale}": not localized -- Apple ships the English file')
        lines.append("    ]")
    lines += ["}", ""]
    if missing:
        raise SystemExit(f"LOCALE_KEYED names {missing}, which AXLocalePolicy does not declare. "
                         f"A generated table cannot invent a label.")
    return "\n".join(lines)


def render_python(doc: dict) -> str:
    """The shipped module: one lowercase-folded tuple per name in `SHIPPED_LABELS`.

    Lowercased because every consumer compares against a lowercased AX reading, and folding here
    means a helper cannot forget to. Sorted and de-duplicated so the file is stable across runs --
    a generated file that reorders itself turns every regeneration into a diff nobody can read.

    THE FOLD IS LOAD-BEARING IN TWO PLACES AND ONLY ONE IS OBVIOUS. The Python side compares
    against `value.lower()`. The AppleScript side splices these into element specifiers --
    `menu bar item (barName as text)` -- and that works because AppleScript string comparison
    ignores case unless a script says `considering case`, which none of ours does. If that ever
    stops being true the menu drive silently stops finding anything, so it is written down here
    rather than left as a property somebody would have to rediscover.
    """
    labels = doc["labels"]
    lines = [
        '"""Logic label tables, per control, in every language Logic ships.',
        "",
        "GENERATED by Scripts/locale_labels.py --write from",
        "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift. Do not edit: the next --write",
        "overwrites it, and the policy is where a label is added, cited and checked.",
        "",
        "This module SHIPS -- Scripts/install.sh installs it beside the helpers that import it --",
        "because those helpers drove Logic's interface through hand-typed English-and-Korean",
        "tables, which is two of the ten languages Logic has.",
        '"""',
        "",
        "from typing import Final",
        "",
    ]
    missing = []
    for export, names in sorted(SHIPPED_LABELS.items()):
        values = []
        for name in names:
            entry = labels.get(name)
            if entry is None:
                missing.append(name)
                continue
            for value in [entry["canonical"]] + list(entry.get("variants") or []):
                folded = value.casefold()
                if folded not in values:
                    values.append(folded)
        for extra in UNTRANSLATED_EXTRAS.get(export, ()):
            if extra.casefold() not in values:
                values.append(extra.casefold())
        rendered = ", ".join(repr(v) for v in sorted(values))
        note = " + ".join(names)
        if UNTRANSLATED_EXTRAS.get(export):
            note += (" + literals Apple does not translate: "
                     + ", ".join(UNTRANSLATED_EXTRAS[export]))
        lines.append(f"#: {note}")
        lines.append(f"{export}: Final[tuple[str, ...]] = ({rendered},)")
        lines.append("")
    if missing:
        raise SystemExit(f"SHIPPED_LABELS names {missing}, which AXLocalePolicy does not declare. "
                         f"A generated table cannot invent a label.")
    return "\n".join(lines)

# canonical / variants / rationale, in the named `static let X = LabelSet(...)` shape.
DECL = re.compile(
    r'static let (\w+) = LabelSet\(\s*'
    r'canonical:\s*"((?:[^"\\]|\\.)*)",\s*'
    r'variants:\s*\[([^\]]*)\],\s*'
    r'rationale:\s*(?P<rationale>""".*?"""|"(?:[^"\\]|\\.)*")',
    re.S,
)

# ...and the same thing written inline inside an array, which the named pattern cannot see. An
# outside review found four of these in `pluginFormatLeafPriority`, each carrying a real Korean
# variant (`스테레오`, `모노`, …). They were absent from the projection AND from its declaration
# count, so editing one changed Swift behaviour while the guard stayed green — the exact drift the
# projection exists to stop, hiding in the shape the parser happened not to read.
INLINE = re.compile(
    r'(?<!= )LabelSet\(\s*'
    r'canonical:\s*"((?:[^"\\]|\\.)*)",\s*'
    r'variants:\s*\[([^\]]*)\],\s*'
    r'rationale:\s*(?P<rationale>""".*?"""|"(?:[^"\\]|\\.)*")',
    re.S,
)
# The denominator counts EVERY LabelSet, not every one this parser knows how to spell. A shape it
# cannot read has to make the export refuse, not vanish from both sides of the comparison.
ANY_LABELSET = re.compile(r'LabelSet\(')
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
# A `// comment` inside a variants array had its quoted text recorded as a variant. Swift line
# comments are stripped before the strings are read; found by a review with
# `variants: ["실제", // "disabled guess"\n]`.
LINE_COMMENT = re.compile(r"//[^\n]*")



_CANON_CACHE = {}


#: The ledger speaks BCP-47 and the corpus is keyed by Logic's `.lproj` names, which agree for
#: seven of the ten and do not for Chinese: Logic ships `zh_CN.lproj` and `zh_TW.lproj`, so
#: splitting on the hyphen yields `zh`, which is not a corpus Logic has.
#:
#: That mattered silently. `_apple_ships` swallowed the CanonError an unknown locale raises and
#: read it as "Apple does not ship this" -- so every Chinese label answered `unmeasured`, and
#: widening `supported_locales` to ten would have recorded 334 gaps that are not there.
_LPROJ = {"zh-CN": "zh_CN", "zh-TW": "zh_TW", "zh-Hans": "zh_CN", "zh-Hant": "zh_TW"}


def _locale_code(locale: str) -> str:
    """`ko-KR` -> `ko`, `zh-CN` -> `zh_CN`. The `.lproj` Logic actually ships."""
    return _LPROJ.get(locale) or locale.split("-")[0]


#: The rules a `derived` cell can name. A derived cell is not a measurement: it says Apple's own corpus
#: holds one of this label's strings in this locale, and `coverage_derived` names which corpus, which
#: locale file, which rule and which string, so the claim can be re-derived rather than believed.
DERIVED_RULES = ("ships_up_to_case", "composed_value")


def _apple_derivation(entry: dict, locale: str):
    """What Apple's own corpus says about this label in this locale, as `source:lproj:rule:string`.

    `None` when it says nothing. The answer names the corpus (`source`), the `.lproj` the string was
    found in, the rule that decided it counts, and the string itself -- so a `derived` cell can be
    audited and re-derived instead of being a bare word. First match in manifest order, so the answer
    is deterministic.

    Offline: `docs/canon/ledger/` is committed. A repository without the canon axis gets None for
    everything, which leaves the old behaviour exactly as it was.
    """
    if _load_canon() is None:
        return None
    canon = _CANON_CACHE.get("canon")
    code = _locale_code(locale)
    strings = [entry.get("canonical")] + list(entry.get("variants") or [])
    # A string Logic COMPOSES is Apple's too. `Show %@` with a noun means `Afficher Bibliothèque`
    # is in no corpus and is exactly what a French Logic's View menu says, so asking the absence
    # sets alone answers `unmeasured` for a label that reaches ten languages.
    # `check-policy-literals-against-canon.py` decides this and commits the answer; this reads that
    # decision rather than re-deriving it, because two readers of one fact drift.
    if "composed" not in _CANON_CACHE:
        try:
            with open(os.path.join(REPO, "docs", "canon", "POLICY-LITERALS.json"),
                      encoding="utf-8") as handle:
                literals = json.load(handle).get("literals") or {}
            _CANON_CACHE["composed"] = {text for text, where in literals.items()
                                        if where == "composed_value"}
        except (OSError, ValueError):
            _CANON_CACHE["composed"] = set()
    composed = _CANON_CACHE["composed"]
    for source, block in (_CANON_CACHE["manifest"].get("sources") or {}).items():
        if code not in (block.get("locales") or []):
            continue
        for text in strings:
            if not text:
                continue
            if text in composed:
                return f"{source}:{code}:composed_value:{text}"
            # Up to case, because that is how every match mode the ledger records compares. Asked
            # byte for byte, `mixer` read as unshipped in German, where Logic's row is `Mixer` and
            # the product matches it (#981). Decoration still counts: `Mixer:` is not `mixer`.
            # Not the absence set: that answers presence through a 32-bit prefix, and a collision
            # credited a string Apple does not ship. This is `build`'s string comparison, pinned.
            # A missing or malformed ledger file raises rather than reading as "Apple ships
            # nothing", the way a mistyped locale code once did here.
            if canon.ships_up_to_case(source, code, text):
                return f"{source}:{code}:ships_up_to_case:{text}"
    return None


def _apple_ships(entry: dict, locale: str) -> bool:
    """Whether Apple's own corpus holds one of this label's strings in this locale, up to case."""
    return _apple_derivation(entry, locale) is not None


# Swift string escapes this projection has to decode. `\\u{...}` matters more than it looks: the
# de-DE application menu-bar item is `Logic\\u{00A0}Pro` with a NON-BREAKING space, and a projection
# that copied the eight literal characters `\\u{00A0}` would disagree with what the compiled policy
# actually matches -- silently, because `--check` parses both sides the same way and would report
# agreement. A divergence a comparison cannot see is the worst kind this file can have.
_ESCAPE = re.compile(r'\\u\{([0-9A-Fa-f]{1,8})\}|\\(.)')
_SIMPLE = {'"': '"', "\\": "\\", "n": "\n", "t": "\t", "r": "\r", "0": "\0", "'": "'"}


def _unescape(text):
    """Decode Swift's escapes in one left-to-right pass.

    One pass, not a chain of `.replace()`: chained replacement decodes the OUTPUT of an earlier
    replacement, so `\\\\u{41}` -- an escaped backslash followed by literal `u{41}` -- would become a
    backslash and then be re-read as a unicode escape yielding `A`. Left to right, each escape is
    consumed exactly once.
    """
    def one(m):
        if m.group(1) is not None:
            return chr(int(m.group(1), 16))
        return _SIMPLE.get(m.group(2), m.group(2))
    return _ESCAPE.sub(one, text)


def _rationale(raw):
    """The rationale's text, whichever quoting Swift used.

    A triple-quoted rationale — `deleteTracksPrimaryButton` has one — matched the ordinary-string
    pattern as an EMPTY string between the first two quotes, so the projection recorded `""` for a
    destructive button's entire justification and the comparison was happy because both sides
    agreed on the wrong value. Found 2026-09-04 by an outside review.
    """
    if raw.startswith('"""') and raw.endswith('"""'):
        body = raw[3:-3]
        # Swift's multiline literals continue a line with a trailing backslash; join those.
        return _unescape(re.sub(r"\\\n\s*", "", body)).strip()
    return _unescape(raw[1:-1])


def from_swift(path=SWIFT):
    """Every LabelSet the policy declares, as {name: {canonical, variants, rationale}}.

    Inline sets have no name of their own, so they are keyed by their canonical with an `inline:`
    prefix — stable across edits that do not change the string, and obviously not a Swift symbol.
    """
    body = open(path, encoding="utf-8").read()
    declared = len(ANY_LABELSET.findall(body))
    out = {}
    for match in DECL.finditer(body):
        name, canonical, variants = match.group(1), match.group(2), match.group(3)
        out[name] = {
            "canonical": _unescape(canonical),
            "variants": [_unescape(v) for v in STRING.findall(LINE_COMMENT.sub("", variants))],
            "rationale": _rationale(match.group("rationale")),
        }
    named_canonicals = {e["canonical"] for e in out.values()}
    for match in INLINE.finditer(body):
        canonical, variants = _unescape(match.group(1)), match.group(2)
        rationale = match.group("rationale")
        key = f"inline:{canonical}"
        if canonical in named_canonicals and key not in out:
            # a named set the inline pattern also matched; the named entry already has it
            continue
        out[key] = {
            "canonical": canonical,
            "variants": [_unescape(v) for v in STRING.findall(LINE_COMMENT.sub("", variants))],
            "rationale": _rationale(rationale),
        }
    if len(out) != declared:
        # A declaration written in a shape this parser does not read would silently vanish from the
        # projection, and a missing label is exactly the failure mode the projection exists to stop.
        raise SystemExit(
            f"{path}: {declared} LabelSet declarations, {len(out)} parsed — "
            "the export would be short, so it is refused"
        )
    return out


def load_json(path=JSON_PATH):
    try:
        return json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def localised_canonicals(doc=None):
    """{canonical.lower(): label name} for labels the policy knows are spelled differently elsewhere.

    A canonical of two characters or fewer is skipped — `L` and `M` are Event List columns and would
    match almost any text.
    """
    doc = doc or load_json()
    out = {}
    for name, entry in (doc.get("labels") or {}).items():
        canonical = entry.get("canonical") or ""
        if entry.get("variants") and len(canonical) > 2:
            out[canonical.lower()] = name
    return out


# The ten Logic ships, as of 2026-09-18 (#892). de-DE joined on 2026-09-12 (#876, an external
# report that the product did not work on a German Logic — it did not, and the report's premise
# that Chinese worked was also wrong: zh appeared in exactly two arrays and in no LabelSet variant).
#
# The sentence that used to end this comment — "every label starts `unmeasured` in it and the
# campaign fills them in" — was true before the canon axis and is false now. Measured the day these
# six were added: 110 of 167 labels start `derived` in Spanish, 112 in French, 117 in Italian, 120
# in Portuguese, 105 in Simplified Chinese and 111 in Traditional. Apple ships those strings and
# the corpus pins them; nobody has to run a Spanish Logic to know what Logic calls the Mixer there.
#
# What the six DO add is six ratchet axes the base has never seen, and the ratchet treats every
# member of a new key as growth — deliberately, because "a branch adds an axis pre-populated with
# its own gaps and nothing asks" is the failure it exists to stop. The gaps were always there; the
# ledger simply was not asking about them. Each is raised once, by name, in RATCHETS.json.
SUPPORTED_LOCALES = ("en-US", "ko-KR", "ja-JP", "de-DE", "es-ES", "fr-FR",
                     "it-IT", "pt-BR", "zh-CN", "zh-TW")
#: `derived` is the state the axis added: Apple ships this label in this locale, and the canon
#: index pins it. It is not `measured` -- nobody ran a Spanish Logic -- and it is emphatically not
#: `unmeasured`, which means nobody knows. Before it existed, deriving `Compás de entrada` from
#: Apple's own table made the ledger count a new GAP, so the axis's output looked like its debt.
COVERAGE_VALUES = ("measured", "derived", "identifier", "unmeasured", "retired")


def swift_containment(repo=REPO):
    """LabelSet names the product demonstrably reads by CONTAINMENT, read from the Swift.

    Derived, not guessed. An earlier cut inferred the mode from the label's NAME — `*Keyword` and
    `*Hint` meant containment — and it was wrong against the real call sites. The current tree reads
    `trackSoloButton`, `audioPluginSlotLabel`, and `inputSlotHelpKeyword` with `containsAny`, while
    `cancelButton` is consumed through exact matching helpers. The call shape is authoritative.

    That direct-call rule is why this returns only what it can see. A name absent from this set is not
    known to be exact; it is not derivable here, and the caller says so rather than assuming.
    """
    names = set()
    for root, _, files in os.walk(os.path.join(repo, "Sources")):
        for f in files:
            if not f.endswith(".swift"):
                continue
            try:
                with open(os.path.join(root, f), encoding="utf-8", errors="replace") as handle:
                    body = handle.read()
            except OSError:
                continue
            names |= set(re.findall(r"AXLocalePolicy\s*\.\s*(\w+)\s*\.containsAny", body))
            # `[^)]*` stopped at the first `)`, so a call whose VALUE argument contains parentheses
            # — `.matches(AXHelpers.getTitle(window, runtime: runtime), mode: .contains)`, which is
            # how every window-title read is written — never reached `mode:` and the set was
            # silently short. Raised by review 2026-09-05 against `stepInputKeyboardWindowTitle`,
            # which the ledger therefore held to `exact` while the product read it by containment,
            # so a true sighting of `Untitled - Step Input Keyboard` would have been refused.
            names |= set(re.findall(
                r"AXLocalePolicy\s*\.\s*(\w+)\s*\.matches\((?:[^()]|\([^()]*\))*mode:\s*\.contains",
                body, re.S))
    return names


def swift_exact_strict(repo=REPO):
    """LabelSet names the product demonstrably reads with `.exactStrict`, read from the Swift.

    `.exactStrict` is not a stricter `.exact`; it is a DIFFERENT comparison. Both fold case, and
    `.exact` trims the observed text while `.exactStrict` compares it verbatim — its own comment
    says so, and it exists to preserve the `desc == label` semantics the structural locators were
    written with.

    A ledger that knows only `exact` therefore certifies claims the product refuses: a record whose
    AXGroup description is `" 再生ヘッドの位置 "` satisfies a trimming comparison and fails
    `.exactStrict`, which is what the element is actually read with. Found by review, 2026-09-05.

    Same shape and same limit as `swift_containment`: what cannot be seen at a call site is not
    claimed. A name absent from this set is not known to be non-strict.
    """
    names = set()
    for root, _, files in os.walk(os.path.join(repo, "Sources")):
        for f in files:
            if not f.endswith(".swift"):
                continue
            try:
                with open(os.path.join(root, f), encoding="utf-8", errors="replace") as handle:
                    body = handle.read()
            except OSError:
                continue
            # `matches(` may carry the value argument before `mode:`, and the call is often split
            # across lines — so the gap is matched permissively but bounded, and a `)` in it ends
            # the call rather than the argument.
            names |= set(re.findall(
                r"AXLocalePolicy\s*\.\s*(\w+)\s*\.matches\((?:[^()]|\([^()]*\))*mode:\s*\.exactStrict",
                body, re.S))
            # `anyOf: AXLocalePolicy.<name>.labels, mode: .exactStrict` — the helper form, which
            # takes the labels rather than the set and is otherwise invisible here.
            names |= set(re.findall(
                r"anyOf:\s*AXLocalePolicy\s*\.\s*(\w+)\s*\.labels\s*,\s*mode:\s*\.exactStrict",
                body, re.S))
    return names


def swift_prefix(repo=REPO):
    """LabelSet names the product demonstrably reads with `.prefix`, read from the Swift.

    The fourth mode, and the last one this file can see. `.prefix` is ANCHORED: Logic's string must
    START with the label. Containment is looser, so a label read with `.prefix` but declared
    `contains` lets the ledger certify a sighting in the middle of a value that the product would
    refuse — the same shape as the `.exactStrict` gap, found while fixing it.

    Only the `MenuPath(..., itemMode: .prefix)` form is derivable: it names the LabelSet.
    `AXLogicProElements+Tracks.swift` passes a local `labels` variable to a predicate with
    `mode: .prefix`, and no name is visible at that call site — the same limit `swift_containment`
    documents, and the reason both functions return only what they can see.
    """
    names = set()
    for root, _, files in os.walk(os.path.join(repo, "Sources")):
        for f in files:
            if not f.endswith(".swift"):
                continue
            try:
                with open(os.path.join(root, f), encoding="utf-8", errors="replace") as handle:
                    body = handle.read()
            except OSError:
                continue
            # `MenuPath(bar: <x>, item: <name>, itemMode: .prefix)` — the item is the label whose
            # mode this is. `bar` is matched with the default mode and is not implicated.
            names |= set(re.findall(
                r"MenuPath\((?:[^()]|\([^()]*\))*?item:\s*(\w+)"
                r"(?:[^()]|\([^()]*\))*?itemMode:\s*\.prefix",
                body, re.S))
            names |= set(re.findall(
                r"AXLocalePolicy\s*\.\s*(\w+)\s*\.matches\((?:[^()]|\([^()]*\))*mode:\s*\.prefix",
                body, re.S))
            # `AXLocalePolicy.<name>.hasPrefixAny(<help>)` — the third spelling of an ANCHORED read,
            # added 2026-09-09 with `inspectorChannelStripHelpPrefix`. Without this the generator saw
            # no prefix site, declared the label `exact`, and the guard then refused the label's own
            # provenance for declaring `prefix` — a label read one way and recorded another, which is
            # the drift this file exists to prevent.
            names |= set(re.findall(
                r"AXLocalePolicy\s*\.\s*(\w+)\s*\.hasPrefixAny", body))
    return names


def swift_template(repo=REPO):
    """LabelSet names the product reads with `.template` (#904), read from the Swift.

    `.template` matches a title against a label holding one `%@`: the text before it, the text
    after it, and something between. Only the `MenuPath(..., itemMode: .template)` form and the
    `AXLocalePolicy.<name>.matches(..., mode: .template)` form name the LabelSet.
    """
    names = set()
    for root, _, files in os.walk(os.path.join(repo, "Sources")):
        for f in files:
            if not f.endswith(".swift"):
                continue
            try:
                with open(os.path.join(root, f), encoding="utf-8", errors="replace") as handle:
                    body = handle.read()
            except OSError:
                continue
            names |= set(re.findall(
                r"MenuPath\((?:[^()]|\([^()]*\))*?item:\s*(\w+)"
                r"(?:[^()]|\([^()]*\))*?itemMode:\s*\.template",
                body, re.S))
            names |= set(re.findall(
                r"AXLocalePolicy\s*\.\s*(\w+)\s*\.matches\((?:[^()]|\([^()]*\))*mode:\s*\.template",
                body, re.S))
    return names


def swift_label_uses(repo=REPO):
    """Every LabelSet the product still reads, by name, from `AXLocalePolicy.<name>` in Sources/.

    Retirement is a fact about the CODE. Taken on trust it was an unaudited escape hatch: any
    nonempty reason marked all three locales `retired`, the ratchets count only literal
    `unmeasured`, and a label the product still reads could therefore be dropped from every ceiling
    by asserting it was gone. `cancelButton` is the reviewer's example and it is read at two call
    sites.
    """
    used = set()
    for root, _, files in os.walk(os.path.join(repo, "Sources")):
        for f in files:
            if not f.endswith(".swift"):
                continue
            try:
                body = open(os.path.join(root, f), encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            # Comments stripped first, and whitespace allowed around the dot. The regex was
            # `AXLocalePolicy\.(\w+)` against the raw text, which missed a use written as
            # `AXLocalePolicy\n    .cancelButton` — Swift's own formatting — and counted a label
            # named only in a historical comment as live, blocking an honest retirement.
            body = re.sub(r"/\*.*?\*/", " ", body, flags=re.S)
            body = re.sub(r"//[^\n]*", " ", body)
            used |= set(re.findall(r"AXLocalePolicy\s*\.\s*(\w+)", body))
    return used


_CONTAINMENT = swift_containment()
_EXACT_STRICT = swift_exact_strict()
_PREFIX = swift_prefix()
_TEMPLATE = swift_template()


# ---------------------------------------------------------------------------------------------------
# THE VERSION AXIS (schema 3)
#
# The ledger used to say WHAT was read and WHERE, and never WHICH LOGIC. A Logic update therefore left
# every reading still marked `measured`, and nothing could say that the string had been read on a
# release nobody runs any more. Three rules close that, and each is mechanical:
#
#   1. ONE declaration of the current release: `AXLocalePolicy.currentLogicVersion` / `...Build` in
#      Swift. The JSON projects it (`logic`); `restatement_problems` refuses a second statement.
#   2. Every `measured` / `identifier` cell is bound to the observation record that read it by the
#      record's version, its build and a SHA-256 over the record's bytes and the evidence files it
#      cites. Not by a path alone: editing or deleting the record changes the digest, and a cell whose
#      record is missing, unreadable or changed never reads as `measured`. Unreadable fails closed.
#   3. A cell's CURRENCY is computed, not written: `current` only when a verified reading names the
#      declared release; `superseded` when it names another; `unknown_version` when the record states
#      none (never guessed); `unverified` when no reading could be verified. `derived` and
#      `unmeasured` are not measurements and are never `current`.
# ---------------------------------------------------------------------------------------------------
SCHEMA = 3
OBS_DIR = os.environ.get("LPM_OBSERVATIONS_DIR") or os.path.join(REPO, "docs", "observations")
UNKNOWN = "unknown"
#: Cell classes, best first. Only `current` is a measurement on the declared Logic. `retired` is
#: excused and is neither a gap nor a reading; everything else is "not measured on the current version".
CURRENCY_CLASSES = ("current", "superseded", "unknown_version", "unverified", "derived",
                    "unmeasured", "retired")
def _release_module():
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "locale_release_for_labels", os.path.join(REPO, "Scripts", "locale_release.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def declared_logic(swift_path=SWIFT):
    """`{"app", "version", "build"}` the Swift declares as the current Logic, or None without one.

    The parser is `Scripts/locale_release.py`, shared with every other reader of the declaration.
    """
    return _release_module().declared_logic(swift_path)


def current_logic():
    """The declared release, or a refusal: a ledger with no declared Logic cannot be classified."""
    try:
        declared = declared_logic()
    except ValueError as exc:
        raise SystemExit(str(exc))
    if declared is None:
        raise SystemExit(f"{SWIFT} declares no `currentLogicVersion`/`currentLogicBuild`")
    return declared


_DIGEST_CACHE = {}


def record_facts(record_id, obs_dir=None):
    """What an observation record states and its digest, or why it cannot be read.

    `status` is `ok`, `missing` or `unreadable`; anything but `ok` carries nothing else. The digest
    covers the record's own bytes AND the bytes of every evidence file it cites, in the order it cites
    them: the rows a string is read from live in the evidence file, so a digest over the record alone
    would let the evidence be rewritten under an unchanged record. A cited file that is absent makes
    the record `unreadable` -- a record whose evidence is gone has nothing left to bind to.

    Version and build are the record's `host`; absent, or `host.binding == "unknown"`, they are
    `unknown` and are never inferred from the date, the filename or the neighbouring records.
    """
    obs_dir = obs_dir or OBS_DIR
    if (not record_id or not isinstance(record_id, str) or "/" in record_id
            or record_id in (".", "..")):
        return {"status": "missing"}
    path = os.path.join(obs_dir, f"{record_id}.json")
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError:
        return {"status": "missing"}
    try:
        doc = json.loads(raw)
    except ValueError:
        return {"status": "unreadable"}
    if not isinstance(doc, dict):
        return {"status": "unreadable"}
    evidence = doc.get("evidence") or []
    if not isinstance(evidence, list):
        return {"status": "unreadable"}
    signature = [hashlib.sha256(raw).hexdigest()]
    paths = []
    for rel in evidence:
        if not isinstance(rel, str) or not rel or os.path.isabs(rel):
            return {"status": "unreadable"}
        full = os.path.normpath(os.path.join(obs_dir, rel))
        if os.path.commonpath([full, os.path.normpath(obs_dir)]) != os.path.normpath(obs_dir):
            return {"status": "unreadable"}
        try:
            stat = os.stat(full)
        except OSError:
            return {"status": "unreadable"}
        paths.append((rel, full))
        signature.append((rel, stat.st_mtime_ns, stat.st_size))
    key = (path, tuple(map(str, signature)))
    digest = _DIGEST_CACHE.get(key)
    if digest is None:
        h = hashlib.sha256()
        h.update(raw)
        for rel, full in paths:
            try:
                with open(full, "rb") as handle:
                    body = handle.read()
            except OSError:
                return {"status": "unreadable"}
            h.update(b"\0" + rel.encode("utf-8") + b"\0" + body)
        digest = _DIGEST_CACHE[key] = h.hexdigest()
    host = doc.get("host") if isinstance(doc.get("host"), dict) else {}
    unbound = host.get("binding") == UNKNOWN
    version = "" if unbound else str(host.get("version") or "").strip()
    build = "" if unbound else str(host.get("build") or "").strip()
    return {"status": "ok", "sha256": digest, "locale": host.get("locale"),
            "version": version or UNKNOWN, "build": build or UNKNOWN}


_STRINGS_CACHE = {}


def _census_evidence():
    """`Scripts/census_evidence.py`: the reader for evidence that is JSON Lines as well as JSON."""
    if "census_evidence" not in _CANON_CACHE:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "census_evidence_for_labels", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                       "census_evidence.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _CANON_CACHE["census_evidence"] = module
    return _CANON_CACHE["census_evidence"]


def _walk_strings(node, into):
    if isinstance(node, str):
        into.add(node)
    elif isinstance(node, dict):
        for key, value in node.items():
            if isinstance(key, str):
                into.add(key)
            _walk_strings(value, into)
    elif isinstance(node, list):
        for value in node:
            _walk_strings(value, into)


def record_strings(record_id, obs_dir=None):
    """Every string value in a record and in the evidence files it cites, or None if unreadable.

    This is what lets a cell's `observed` be held to "the exact string": it has to be one of the values
    the record or its evidence actually carries, character for character.
    """
    obs_dir = obs_dir or OBS_DIR
    facts = record_facts(record_id, obs_dir)
    if facts["status"] != "ok":
        return None
    key = (os.path.join(obs_dir, f"{record_id}.json"), facts["sha256"])
    if key not in _STRINGS_CACHE:
        found = set()
        try:
            with open(key[0], encoding="utf-8") as handle:
                doc = json.load(handle)
            _walk_strings(doc, found)
            for rel in doc.get("evidence") or []:
                _walk_strings(_census_evidence().load(os.path.join(obs_dir, rel)), found)
        except (OSError, ValueError):
            return None
        _STRINGS_CACHE[key] = frozenset(found)
    return _STRINGS_CACHE[key]


def binding_problems(record_id, locale, sha, version, build, obs_dir=None, observed=None):
    """Why a reading's claim about its record is not true. Empty means it is bound and verified.

    Checked against the record AS IT IS NOW: it must exist and be readable, its bytes (and its
    evidence's) must hash to the digest the cell carries, it must have been taken in the locale the
    cell claims, and it must state the version and build the cell carries. With `observed`, the exact
    string the cell quotes must be a value the record or its evidence carries.
    """
    facts = record_facts(record_id, obs_dir)
    if facts["status"] != "ok":
        return [f"record {record_id!r} is {facts['status']}"]
    out = []
    if not sha:
        out.append(f"carries no record_sha256 for {record_id!r}")
    elif sha != facts["sha256"]:
        out.append(f"record_sha256 does not match {record_id!r}: the record or its evidence changed "
                   f"after the cell was bound")
    if facts["locale"] != locale:
        out.append(f"{record_id!r} was taken in {facts['locale']!r}, not {locale!r}")
    if (version, build) != (facts["version"], facts["build"]):
        out.append(f"cell says Logic {version} ({build}) but {record_id!r} says "
                   f"{facts['version']} ({facts['build']})")
    if observed is not None and observed not in (record_strings(record_id, obs_dir) or ()):
        out.append(f"{observed!r} is not a string {record_id!r} or its evidence carries")
    return out


def cell_evidence(entry, loc):
    """`[(record, sha, version, build)]` a cell's measurement rests on, as the JSON states them."""
    found = []
    variants = entry.get("variants") or []
    for variant, block in (entry.get("provenance") or {}).items():
        if isinstance(block, dict) and block.get("locale") == loc and variant in variants:
            found.append((block.get("record"), block.get("record_sha256"),
                          block.get("logic_version"), block.get("logic_build"),
                          block.get("observed")))
    cited = (entry.get("coverage_records") or {}).get(loc)
    if cited:
        found.append((cited, (entry.get("coverage_record_sha256") or {}).get(loc),
                      (entry.get("coverage_logic_version") or {}).get(loc),
                      (entry.get("coverage_logic_build") or {}).get(loc), None))
    return found


def classify_cell(entry, loc, current, obs_dir=None):
    """One cell's class, recomputed from the record NOW. Never trusts a stored class.

    A cell claiming `measured`/`identifier` is `current` only if some reading verifies against its
    record and names the declared release. A claim whose record is gone, unreadable or changed is
    `unverified`: it does not read as measured, and it is not silently demoted to `derived` either,
    because nobody has shown Apple's corpus holds the string.
    """
    state = (entry.get("coverage") or {}).get(loc, "unmeasured")
    if state in ("retired", "derived", "unmeasured"):
        return state
    if state not in ("measured", "identifier"):
        return "unverified"
    best = "unverified"
    rank = {"unverified": 0, "unknown_version": 1, "superseded": 2}
    for record, sha, version, build, observed in cell_evidence(entry, loc):
        if binding_problems(record, loc, sha, version, build, obs_dir, observed):
            continue
        if UNKNOWN in (version, build):
            kind = "unknown_version"
        elif (version, build) == (current["version"], current["build"]):
            return "current"
        else:
            kind = "superseded"
        if rank[kind] > rank[best]:
            best = kind
    return best


def currency_summary(labels, locales, current, obs_dir=None):
    """`{locale: {class: count, ..., "not_measured_on_current": n}}` over every label."""
    out = {}
    for loc in locales:
        counts = {cls: 0 for cls in CURRENCY_CLASSES}
        for entry in labels.values():
            counts[classify_cell(entry, loc, current, obs_dir)] += 1
        counts["not_measured_on_current"] = sum(
            n for cls, n in counts.items() if cls not in ("current", "retired"))
        out[loc] = counts
    return out


def not_current_cells(labels, locales, current, obs_dir=None):
    """`{locale: sorted label names}` whose cell is not measured on the declared Logic."""
    return {loc: sorted(name for name, entry in labels.items()
                        if classify_cell(entry, loc, current, obs_dir) not in ("current", "retired"))
            for loc in locales}


def derived_problems(name, entry):
    """A `derived` cell names what it was derived from and the rule, and is never a measurement.

    The names are `coverage_derived[locale] = "<corpus>:<lproj>:<rule>:<string>"`. A cell with no such
    name, an unknown rule, or a name on a cell that is not `derived` is refused. (Whether the corpus
    really holds the string is re-derived by `--check`, which compares the regenerated bytes.)
    """
    out = []
    named = entry.get("coverage_derived") or {}
    cov = entry.get("coverage") or {}
    for loc, state in cov.items():
        text = named.get(loc)
        if state == "derived":
            parts = str(text or "").split(":", 3)
            if len(parts) != 4 or not all(parts) or parts[2] not in DERIVED_RULES:
                out.append(f"{name}: coverage[{loc}] is 'derived' but names no corpus, locale, rule "
                           f"and string under coverage_derived[{loc}] (rules: {DERIVED_RULES})")
        elif loc in named:
            out.append(f"{name}: coverage_derived[{loc}] names a derivation for a cell that is "
                       f"{state!r}, not 'derived'")
    return out


#: Where the current Logic may be STATED. The declaration is Swift's; these are measurements or
#: projections of it, which describe a release rather than declare which one is current.
_RESTATEMENT_EXEMPT = ("docs/observations/", "docs/canon/", "docs/locale/ui-labels.json",
                       "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift", ".git/", ".build/",
                       "artifacts/", "CHANGELOG.md", "Scripts/demo/")


def _tracked_files(repo):
    try:
        out = subprocess.run(["git", "-C", repo, "ls-files", "-z"], capture_output=True, timeout=60)
        if out.returncode == 0 and out.stdout:
            return [p for p in out.stdout.decode("utf-8", "replace").split("\0") if p]
    except (OSError, subprocess.TimeoutExpired):
        pass
    found = []
    for root, dirs, files in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in (".git", ".build")]
        for f in files:
            found.append(os.path.relpath(os.path.join(root, f), repo))
    return found


def restatement_problems(repo=REPO):
    """Every place other than the Swift that states which Logic is current.

    One declaration is the point: a second one is where the ledger and the product disagree about
    what "current" means. So the legacy `docs/observations/LOGIC-BUILD.json` may not exist, the Swift
    must declare exactly once, and no other tracked file may carry the declared build number as a
    token or name the declared version after `Logic`. Records, evidence, the canon's pins and this
    file's own projection are measurements OF a release and are exempt.
    """
    out = []
    swift = os.path.join(repo, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
    try:
        declared = declared_logic(swift)
    except ValueError as exc:
        return [str(exc)]
    if os.path.exists(os.path.join(repo, "docs", "observations", "LOGIC-BUILD.json")):
        out.append("docs/observations/LOGIC-BUILD.json exists: it is a second declaration of the "
                   "current Logic. Delete it; the declaration is AXLocalePolicy.currentLogicVersion")
    if declared is None:
        return out + ["AXLocalePolicy.swift declares no currentLogicVersion/currentLogicBuild"]
    b, v = re.escape(declared["build"]), re.escape(declared["version"])
    # Three SHAPES of restatement, because a bare number is not one: `element(7801)` in a test is a
    # fixture id, and a measurement note saying "Logic 13.0 build 7801 exposes ..." is a true fact about
    # a release, not a declaration of which is current. What drifts is (1) a key or constant that
    # holds the build, (2) one that holds the version, (3) a sentence that calls the version current.
    shapes = (
        ("build", re.compile(r"(?i)\b(?:build|logic\w*|release)\w*[\"']?\s*[:=]\s*[\"']?" + b
                             + r"(?![\w.])")),
        ("version", re.compile(r"(?i)\b(?:version|logic\w*)[\"']?\s*[:=]\s*[\"']?" + v
                               + r"(?![\w.])")),
        ("version (as the current one)", re.compile(
            r"(?i)\b(?:current|supported|target|latest|declared)\b[^\n.|]{0,60}\b\*{0,2}" + v
            + r"\*{0,2}(?![\w.])|\bLogic(?: Pro)?\s+" + v + r"\*{0,2}\s+is\s+the\s+"
            + r"(?:current|supported|target)")),
    )
    for rel in sorted(_tracked_files(repo)):
        norm = rel.replace(os.sep, "/")
        if any(norm.startswith(p) or norm == p for p in _RESTATEMENT_EXEMPT):
            continue
        # Fixtures pick a version string to exercise code with; they do not declare the current one.
        # A sentence calling a version current is still refused there.
        fixture = norm.startswith("Tests/")
        full = os.path.join(repo, rel)
        try:
            if os.path.getsize(full) > 4_000_000:
                continue
            with open(full, encoding="utf-8") as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError):
            continue
        for kind, pattern in shapes:
            if fixture and kind in ("build", "version"):
                continue
            hit = pattern.search(text)
            if hit:
                line = text.count("\n", 0, hit.start()) + 1
                out.append(f"{norm}:{line} restates the current Logic {kind} "
                           f"({declared['version']} / {declared['build']}), which is declared only "
                           f"in AXLocalePolicy.swift")
    return out


def binding_report(doc, obs_dir=None):
    """Every claim in `doc` whose record is missing, changed or contradicts it. Empty is clean."""
    out = []
    for name, entry in sorted((doc.get("labels") or {}).items()):
        for variant, block in sorted((entry.get("provenance") or {}).items()):
            if not isinstance(block, dict):
                out.append(f"{name}→{variant}: provenance is not an object")
                continue
            for why in binding_problems(block.get("record"), block.get("locale"),
                                        block.get("record_sha256"), block.get("logic_version"),
                                        block.get("logic_build"), obs_dir, block.get("observed")):
                out.append(f"{name}→{variant}: {why}")
        for loc, record in sorted((entry.get("coverage_records") or {}).items()):
            if (entry.get("coverage") or {}).get(loc) not in ("measured", "identifier"):
                continue
            for why in binding_problems(record, loc,
                                        (entry.get("coverage_record_sha256") or {}).get(loc),
                                        (entry.get("coverage_logic_version") or {}).get(loc),
                                        (entry.get("coverage_logic_build") or {}).get(loc), obs_dir):
                out.append(f"{name}[{loc}]: {why}")
    return out


# Fields a person wrote by hand, which the Swift projection cannot regenerate.
CARRIED = ("roles", "retired", "evidence_scope")
# `match` is not carried by the loop below — it is derived from the Swift where the Swift can speak,
# and falls back to the prior value where it cannot. But that fallback is keyed by NAME too, so a
# rename loses an author's `contains` and silently reinstates the `exact` default. Round three of
# review found it live: `arrangeWindowTitleSuffix` declares `contains` while the product compares
# with `hasSuffix`, and under a reinstated `exact` a window titled `Untitled - Tracks` stops
# matching. So the loss ACCOUNTING covers it even though the carry-forward cannot.
AUTHOR_TYPED = CARRIED + ("match",)


def build(existing=None, dropped=None, unbound=None, rebind=False, bind_records=()):
    """The JSON document: the Swift projection, with `provenance` and `coverage` carried forward.

    Swift owns the strings. The JSON owns what is known ABOUT them, and that must survive every
    regeneration or the act of syncing the strings would erase the evidence for them. A schema-1
    document's `measured` is read as `provenance`, so the migration is the next `--write`.

    `coverage` defaults to `unmeasured` for every supported locale a label has no declaration for.
    That is the honest default: a label nobody has looked at in a locale is unmeasured there, and
    writing `measured` without a record is the fabrication this whole file exists to prevent.
    `measured` is DERIVED whenever a variant with provenance in that locale is in the list, so it
    cannot drift from the evidence; otherwise it, like `identifier`, is carried only together with
    the record under `coverage_records` that showed it.

    SCHEMA 3. Every measurement is also bound to the record that read it: `logic_version` and
    `logic_build` come from the record's own `host` on every run (never carried, so a hand edit is
    erased), and `record_sha256` is CARRIED -- it is the one thing that cannot be re-derived without
    defeating its purpose. A document older than schema 3 is bound once, by this run (the migration).
    From then on a cell with no digest, a changed record or a missing one does not read as `measured`;
    each such claim is appended to `unbound`, and `main()` refuses to write while any is open. With
    `rebind=True` (the explicit, reviewed act) digests are recomputed from the records as they are, and
    a block whose record no longer exists is dropped. `bind_records` names records whose digest MAY be
    bound where a cell has none: the census records a regeneration has just filed and cited, and nothing
    else, so a block that arrives without a digest is bound only to a record somebody named.
    """
    existing = existing if existing is not None else load_json()
    previous = (existing.get("labels") or {})
    try:
        was_schema = int(existing.get("schema") or 1)
    except (TypeError, ValueError):
        was_schema = 1
    bind_missing = rebind or was_schema < SCHEMA
    current = current_logic()
    unbound = unbound if unbound is not None else []

    def bound_sha(prior_sha, facts, record_id=None):
        if facts["status"] != "ok":
            return prior_sha
        if rebind:
            return facts["sha256"]
        return prior_sha or (facts["sha256"] if bind_missing or record_id in bind_records else None)
    labels = {}
    for name, entry in sorted(from_swift().items()):
        prior = previous.get(name) or {}
        entry = dict(entry)
        provenance = prior.get("provenance") or prior.get("measured") or {}
        # Provenance survives regeneration, but only for variants that still exist.
        provenance = {k: v for k, v in provenance.items() if k in entry["variants"]}
        verified_locales = set()
        bound = {}
        for variant, block in provenance.items():
            block = dict(block)
            facts = record_facts(block.get("record"))
            if facts["status"] != "ok" and rebind:
                unbound.append(f"{name}\u2192{variant}: record {block.get('record')!r} is "
                               f"{facts['status']}; --rebind drops this reading")
                continue
            if facts["status"] == "ok":
                block["logic_version"], block["logic_build"] = facts["version"], facts["build"]
            else:
                block.setdefault("logic_version", UNKNOWN)
                block.setdefault("logic_build", UNKNOWN)
            sha = bound_sha(block.get("record_sha256"), facts, block.get("record"))
            if sha:
                block["record_sha256"] = sha
            else:
                block.pop("record_sha256", None)
            block = dict(sorted(block.items()))
            problems = binding_problems(block.get("record"), block.get("locale"),
                                        block.get("record_sha256"), block.get("logic_version"),
                                        block.get("logic_build"), observed=block.get("observed"))
            if problems:
                unbound.extend(f"{name}\u2192{variant}: {why}" for why in problems)
            else:
                verified_locales.add(str(block.get("locale")))
            bound[variant] = block
        provenance = bound
        if provenance:
            entry["provenance"] = provenance
        prior_coverage = prior.get("coverage") or {}
        cited = prior.get("coverage_records") or {}
        # Only a block that VERIFIES makes its locale `measured`. A claim whose record is missing,
        # changed or contradicts it is reported in `unbound` and measures nothing.
        present_in = verified_locales
        # Author-typed constraints, carried verbatim. `roles` can only ever REFUSE evidence — a
        # wrong one costs a false RED that someone fixes, never a false GREEN — so it is safe for a
        # human to write where the AX role is not derivable from Swift. `retired` excuses a label
        # whose element Logic no longer ships, which otherwise sits in the ledger as permanent debt
        # nobody can ever close by measuring.
        # `evidence_scope` is the same kind of thing and carried the same way: it can only ever
        # REFUSE evidence, so a wrong one costs a false RED. It also has to survive regeneration
        # more than the others do — it is how a RETRACTION is recorded, and a retraction that a
        # `--write` erases is one the next campaign run silently undoes.
        #
        # THE LIMIT, and it is a real one: metadata is recovered by exact label NAME, so renaming
        # the Swift symbol drops the scope along with `roles` and `retired`, and the next campaign
        # run may then back the renamed label with the reading the scope existed to refuse. Named
        # by review 2026-09-07. Carrying it across a rename would need the generator to be told
        # which old name became which new one, and nothing in the projection knows that; the honest
        # form is to say so here rather than to imply the field is rename-proof. What CAN be done
        # is make the loss loud: `--write` reports every label whose author-typed metadata it is
        # about to drop, so a rename says what it costs at the moment somebody runs it, instead of
        # being discovered by a campaign that quietly re-proposes the reading a scope had refused.
        for field in CARRIED:
            if prior.get(field):
                entry[field] = prior[field]
        # The match mode is a property of the LABEL: whether Logic's string EQUALS it or CONTAINS it
        # is the same question in every locale. It used to live only on provenance blocks, so
        # coverage had nothing to read and derived its own answer — and the two halves of the guard
        # disagreed about the 9 labels the Swift cannot speak about.
        #
        # `exact` is the default because it is the STRICT one. Loosening a label to containment
        # admits coincidental substrings, so it is a decision that shows up in a diff rather than
        # something a regeneration can do quietly. Where the Swift says `containsAny`, it wins.
        #
        # `exact_strict` likewise comes from the Swift and not from a default. It is not a stricter
        # `exact`: both fold case, and `exact` trims the observed text while `exactStrict` compares
        # it verbatim. A ledger that knew only `exact` therefore certified claims the product
        # refuses — a description read back as `" 再生ヘッドの位置 "` satisfies a trimming comparison
        # and fails the one the element is actually read with. Found by review, 2026-09-05.
        # `prefix` is ANCHORED, so containment is looser than it: a label read with `.prefix` and
        # declared `contains` lets the ledger certify a sighting mid-value the product refuses.
        # Same shape as the `exact_strict` gap, and found while fixing that one.
        if name in _TEMPLATE and name not in _CONTAINMENT:
            entry["match"] = "template"
        elif name in _PREFIX and name not in _CONTAINMENT:
            entry["match"] = "prefix"
        elif name in _CONTAINMENT:
            entry["match"] = "contains"
        elif name in _EXACT_STRICT:
            entry["match"] = "exact_strict"
        else:
            entry["match"] = prior.get("match") or "exact"
        retired = bool((entry.get("retired") or {}).get("reason"))
        coverage = {}
        derived_from = {}
        cited_facts, cited_sha = {}, {}
        for locale in SUPPORTED_LOCALES:
            if retired:
                coverage[locale] = "retired"
            elif locale in present_in:
                coverage[locale] = "measured"
            elif prior_coverage.get(locale) in ("measured", "identifier") and cited.get(locale):
                # A claim of measurement is carried only with the record that showed it, and only
                # while that record still VERIFIES against the digest it was bound with. One nobody
                # cited -- or one that was edited or deleted -- would otherwise ride through every
                # regeneration as if it were evidence.
                facts = record_facts(cited[locale])
                sha = bound_sha((prior.get("coverage_record_sha256") or {}).get(locale), facts,
                                cited[locale])
                problems = binding_problems(
                    cited[locale], locale, sha,
                    facts.get("version"), facts.get("build"))
                if problems:
                    unbound.extend(f"{name}[{locale}]: {why}" for why in problems)
                    # NOT measured, whatever the stale JSON said. It falls to what is actually
                    # shown -- Apple's corpus, or nothing -- and `unbound` carries the complaint.
                    derivation = _apple_derivation(entry, locale)
                    coverage[locale] = "derived" if derivation else "unmeasured"
                    if derivation:
                        derived_from[locale] = derivation
                else:
                    coverage[locale] = prior_coverage[locale]
                    cited_facts[locale], cited_sha[locale] = facts, sha
            elif (derivation := _apple_derivation(entry, locale)) is not None:
                coverage[locale] = "derived"
                derived_from[locale] = derivation
            else:
                coverage[locale] = "unmeasured"
        entry["coverage"] = coverage
        # A claim of absence, or of identifier addressing, names the record that showed it — and
        # that citation has to survive regeneration exactly as provenance does, or every --write
        # would turn a measured `absent` back into `unmeasured` by erasing its evidence.
        # All THREE citation maps travel together. Carrying only the record id was a data-loss bug:
        # the next `--write` stripped the role and the identifier, and the guard then rejected a
        # claim that had been valid — regeneration turning evidence into a failure.
        # Named `carried_map` because `carried` was also the name of the prior-coverage dict a few
        # lines above. It worked only because the dict is rebound at the top of every iteration;
        # moving either line would have silently turned a dict lookup into a function object.
        def carried_map(field):
            return {loc: v for loc, v in (prior.get(field) or {}).items()
                    if loc in SUPPORTED_LOCALES and coverage.get(loc) in ("measured", "identifier")
                    and loc not in present_in}

        for field in ("coverage_records", "coverage_roles", "coverage_identifiers",
                      "coverage_attributes", "coverage_absent", "coverage_paths"):
            kept = carried_map(field)
            if kept:
                entry[field] = kept
        # What each cited coverage record said about the release, and the digest it is bound by.
        cited_versions = {loc: cited_facts[loc]["version"] for loc in cited_facts
                          if loc in (entry.get("coverage_records") or {})}
        if cited_versions:
            entry["coverage_logic_version"] = cited_versions
            entry["coverage_logic_build"] = {loc: cited_facts[loc]["build"] for loc in cited_versions}
            entry["coverage_record_sha256"] = {loc: cited_sha[loc] for loc in cited_versions
                                               if cited_sha.get(loc)}
        if derived_from:
            entry["coverage_derived"] = derived_from
        class_of = {loc: classify_cell(entry, loc, current) for loc in SUPPORTED_LOCALES}
        measured_class = {loc: cls for loc, cls in class_of.items()
                          if coverage[loc] in ("measured", "identifier")}
        if measured_class:
            entry["coverage_currency"] = measured_class
        labels[name] = entry
    # Every label that WAS in the document, carried author-typed metadata, and is no longer in the
    # Swift. Renaming a symbol lands here, and so does deleting one; either way the scope, the
    # declared roles, the retirement reason or the match mode is about to be lost and nothing else
    # would say so.
    #
    # An OUT-PARAMETER, not module state. `dropped` was a module global cleared at the top of this
    # function, so a second `build()` overwrote the first one's report and a caller holding the
    # first document could print the second's losses beside it. Round three reproduced exactly
    # that. The report now belongs to the call that produced it.
    #
    # And the VALUES, not just the field names. What a rename needs is the text to paste onto the
    # new name; `DROPPED old: evidence_scope, roles` names a loss the reader can no longer undo,
    # because the file has already been rewritten by the time they read it.
    if dropped is not None:
        for name, prior in previous.items():
            if name in labels:
                continue
            lost = {f: prior[f] for f in AUTHOR_TYPED if prior.get(f)}
            if lost:
                dropped[name] = lost
    canon_manifest = (_CANON_CACHE.get("manifest") or {}) if _load_canon() else {}
    pin = canon_manifest.get("logic") or {}
    return {
        "schema": SCHEMA,
        "generated_from": "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift",
        "how_to_regenerate": "Scripts/locale_labels.py --write",
        "note": (
            "Swift is the compiled source of truth; this is its projection for everything that "
            "cannot import Swift. `provenance` records where a variant was READ — the observation "
            "record, its locale, the date and the exact string — and `coverage` says per locale "
            "what is known about the label. `unmeasured` is the only value that is a gap. ADR-019. "
            "`logic` is the Logic release this ledger is judged against, projected from "
            "AXLocalePolicy.currentLogicVersion/Build (the one declaration). Each measured cell is "
            "bound to its observation record by `record_sha256` and carries the `logic_version` and "
            "`logic_build` that record states (`unknown` when it states none); `coverage_currency` "
            "says whether that is the declared release, and `currency` counts every cell per "
            "locale. `coverage_derived` names what a derived cell was derived from: "
            "`<corpus>:<lproj>:<rule>:<string>`, read from `canon_logic`'s corpus, never a measurement."
        ),
        "logic": current,
        "canon_logic": {"version": pin.get("version"), "build": pin.get("build")},
        "supported_locales": list(SUPPORTED_LOCALES),
        "coverage_values": list(COVERAGE_VALUES),
        "currency_classes": list(CURRENCY_CLASSES),
        "currency": currency_summary(labels, SUPPORTED_LOCALES, current),
        "labels": labels,
    }


def report_dropped(dropped, stream=sys.stderr):
    """Say what author-typed metadata this build is about to lose, with the values.

    On STDERR, and before anything is written. The report lived only in the `--write` branch and
    printed only field NAMES: a pipeline that generates to stdout and moves the file over the ledger
    lost the metadata in silence, and even `--write` overwrote the document before naming a loss the
    reader could then no longer undo. Both found by review, round three. stderr also keeps this out
    of the JSON when the document is being piped.
    """
    for name, lost in sorted(dropped.items()):
        print(f"DROPPED {name}: this label is no longer in AXLocalePolicy.swift, so the following "
              f"was written by a person and is about to be lost. If it was RENAMED, paste this onto "
              f"the new name — a lost `evidence_scope` is a retraction the next campaign silently "
              f"undoes:\n  " + json.dumps(lost, ensure_ascii=False), file=stream)

# The file on disk is indented with ONE space. Three separate `json.dump` calls used to decide that
# independently — here twice and once in `locale-propose.py --apply` — and all three said `indent=2`
# while the tree said one, so the command this file documents for regenerating the document
# rewrote all 2858 of its lines without changing a value (#798). The guard compares PARSED objects,
# so nothing in CI could see it, and a campaign adding two provenance blocks produced a diff those
# blocks were not findable in.
#
# One renderer, and `test_locale_labels_json.py` compares its output to the file's BYTES. Comparing
# parsed objects is what let this drift, so a test that compares parsed objects would not catch it.
INDENT = 1


def render(doc):
    """The document's exact text, including its trailing newline.

    Compact: a leaf (a provenance block, a coverage map, a list of variants) is one line and structure
    keeps one line per key, so the ledger's size is its number of facts and not its number of fields.
    """
    return _compact().dumps(doc, INDENT)


def _compact():
    if "compact_json" not in _CANON_CACHE:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "compact_json_for_labels", os.path.join(os.path.dirname(os.path.abspath(__file__)), "compact_json.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _CANON_CACHE["compact_json"] = module
    return _CANON_CACHE["compact_json"]


def stale_artifacts(doc, json_path=None, py_path=None, swift_path=None):
    """Repo-relative paths of generated artifacts whose BYTES differ from what the generator renders.

    BYTES, and the whole file. Until 2026-09-19 `--check` compared the JSON's parsed `labels` alone, so
    a hand edit anywhere else -- the declared `logic`, the per-locale `currency` counts, a note, a
    stray space -- was invisible. A generated file is exactly what its generator writes or it is stale.
    """
    stale = []
    for path, rendered in ((json_path or JSON_PATH, render(doc)),
                           (py_path or PY_PATH, render_python(doc)),
                           (swift_path or SWIFT_PATH, render_swift(doc))):
        try:
            with open(path, encoding="utf-8", newline="") as fh:
                on_disk = fh.read()
        except OSError:
            on_disk = None
        if on_disk != rendered:
            stale.append(os.path.relpath(path, REPO))
    return stale


def check_problems(doc, unbound, on_disk, repo=REPO, obs_dir=None):
    """Every claim the ledger makes that its records, its Swift or its own rules do not support.

    `unbound` is what `build()` could not bind; `on_disk` is the document as committed, whose digests
    are checked directly so a cell cannot pass by being regenerated into agreement with a changed
    record.
    """
    problems = [f"UNBOUND {line}" for line in unbound]
    problems += [f"RESTATED {line}" for line in restatement_problems(repo)]
    for name, entry in sorted(doc["labels"].items()):
        problems += [f"DERIVED {line}" for line in derived_problems(name, entry)]
    problems += [f"UNBOUND {line}" for line in binding_report(on_disk, obs_dir)]
    return sorted(set(problems))


def _report_currency(doc, stream=sys.stdout):
    """Per locale: how many cells are measured on the declared Logic, and what the rest are."""
    logic = doc.get("logic") or {}
    print(f"declared current Logic: {logic.get('version')} ({logic.get('build')}) "
          f"-- AXLocalePolicy.currentLogicVersion/Build; derived cells come from a canon pinned to "
          f"{(doc.get('canon_logic') or {}).get('version')} ({(doc.get('canon_logic') or {}).get('build')})",
          file=stream)
    head = ("locale", "current", "superseded", "unknown_version", "unverified", "derived",
            "unmeasured", "retired", "NOT_MEASURED_ON_CURRENT")
    print("  ".join(f"{h:>10}" if i else f"{h:<8}" for i, h in enumerate(head)), file=stream)
    totals = {k: 0 for k in head[1:-1]}
    not_current = 0
    for loc, counts in (doc.get("currency") or {}).items():
        print("  ".join([f"{loc:<8}"] + [f"{counts.get(k, 0):>10}" for k in head[1:-1]]
                        + [f"{counts.get('not_measured_on_current', 0):>10}"]), file=stream)
        for k in totals:
            totals[k] += counts.get(k, 0)
        not_current += counts.get("not_measured_on_current", 0)
    print("  ".join([f"{'total':<8}"] + [f"{totals[k]:>10}" for k in head[1:-1]]
                    + [f"{not_current:>10}"]), file=stream)


def main():
    args = sys.argv[1:]
    dropped = {}
    unbound = []
    rebind = "--rebind" in args
    bind_records = {args[i + 1] for i, a in enumerate(args[:-1]) if a == "--bind-record"}
    doc = build(dropped=dropped, unbound=unbound, rebind=rebind, bind_records=bind_records)
    report_dropped(dropped)
    if "--report" in args:
        _report_currency(doc)
        return 0
    if "--write" in args:
        if unbound and not rebind:
            for line in unbound:
                print(f"UNBOUND {line}", file=sys.stderr)
            print(f"{len(unbound)} measurement(s) are not bound to a record that exists and matches "
                  f"them, so nothing was written and none of them reads as measured. If the record "
                  f"was edited on purpose, review the change and run `Scripts/locale_labels.py "
                  f"--write --rebind`.", file=sys.stderr)
            return 1
        for line in unbound:
            print(f"REBIND {line}", file=sys.stderr)
        os.makedirs(os.path.dirname(JSON_PATH), exist_ok=True)
        with open(JSON_PATH, "w", encoding="utf-8") as fh:
            fh.write(render(doc))
        with open(PY_PATH, "w", encoding="utf-8") as fh:
            fh.write(render_python(doc))
        with open(SWIFT_PATH, "w", encoding="utf-8") as fh:
            fh.write(render_swift(doc))
        print(f"wrote {len(doc['labels'])} labels to docs/locale/ui-labels.json, "
              f"{len(SHIPPED_LABELS)} shipped table(s) to Scripts/logic_ui_labels.py and "
              f"{len(LOCALE_KEYED)} locale-keyed table(s) to "
              f"Sources/LogicProMCP/Accessibility/AXLocaleValues.swift")
        return 0
    if "--check" in args:
        stale = stale_artifacts(doc)
        problems = check_problems(doc, unbound, load_json())
        if stale:
            for path in stale:
                print(f"{path} disagrees with what AXLocalePolicy.swift and the records generate")
            print("Regenerate with `Scripts/locale_labels.py --write`.")
        for line in problems:
            print(line)
        if stale or problems:
            return 1
        print(f"{len(doc['labels'])} labels agree, and {len(SHIPPED_LABELS) + len(LOCALE_KEYED)} "
              f"generated table(s) match what this run would write; every measured cell is bound "
              f"to its record, and the current Logic is declared once")
        return 0
    sys.stdout.write(render(doc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
