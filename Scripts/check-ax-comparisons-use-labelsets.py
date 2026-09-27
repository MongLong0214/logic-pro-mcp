#!/usr/bin/env python3
"""A string compared against an AX reading must come from a LabelSet, or it works in one language.

WHY THIS EXISTS
---------------
`AXLocalePolicy` carries every label this product matches Logic with, per locale. Anything that
compares an AX reading against a literal SOMEWHERE ELSE bypasses that, and works only in whatever
language the literal happens to be. Measured when this was written, over `Sources/` and
`Scripts/livekit/`:

    Stop         -> Stoppen / 停止 / 정지          transport stop, outside a LabelSet
    Input slot   -> Input-Slot / 入力スロット / 입력 슬롯   routing
    Region Path  -> Regionspfad: / リージョンパス / 리전 경로
    Cut          -> Schneiden / カット / 오려두기
    empty        -> Leer / 空 / 비어 있음

None of them is a bug anybody filed. They are bugs nobody has run into yet, because the languages
they break in are languages nobody has driven.

WHAT IT REFUSES, AND WHAT IT DELIBERATELY DOES NOT
---------------------------------------------------
Three conditions, all of them required, because each one alone is far too broad:

  1. the literal is compared against something that READS like an AX attribute
     (`title`, `description`, `value`, `label`, `role`, `ax*`, anything ending in `name`) — not
     every string in the tree. `name` was left out of the first version to avoid JSON keys, and it
     dropped `if name == "Stop"` and `parameter.bandName.hasSuffix("Cut")`, which are two of the
     realest findings here. Conditions 2 and 3 filter the keys instead.
  2. Apple ships it — a string absent from the corpus is not a label this rule can reason about
  3. Apple TRANSLATES it — the same key holds a different value in another locale

Condition 3 is what separates a real finding from noise. `Audio Units`, `Terminal`, `Alchemy`,
`ES1`, `4/4` and `MIDI` are all in the corpus and all identical in every locale: matching them by
literal is safe, and refusing them would make this guard wrong far more often than right. 192
candidates narrow to 11 under condition 3, and 11 to 7 once the untranslated ones drop out.

SINCE #1028 (ADR-027 D6, audit B D5) EVERY LITERAL IS CLASSIFIED, NOT ONLY APPLE'S
-----------------------------------------------------------------------------------
Conditions 2 and 3 used to be a pass: a literal Apple does not ship was "not Apple's at all: safe
to match" -- so a FRAGMENT of a translated label (`Input Port` of `Input Port:`), a plug-in name the
corpus does not hold, or this product's own prose all passed unexamined. Each literal is now one of

  apple_translated   Apple ships it and translates it: a LabelSet, or the separator rule
  apple_value        Apple ships it as a whole value and does not translate it: safe. First
                     by a pinned ROW in a source no locale translates (`plugin_names`, `madsp`,
                     `nib`): exact, by 48-bit digest, and `--classify` prints that row's
                     citation. `Channel EQ` is the row
                         logic-canon://plugin_names/EMAG%7C0236%7C0000/-/name#value
                         Channel EQ
                     Then by the 32-bit absence sets of the English and `-` corpora, which can
                     only err towards "ships".
  identifier         a shape no locale translates: an UPPER_SNAKE sentinel this product emits
                     (with an optional `: detail`), punctuation, a `.ext` extension, a reverse-DNS
                     prefix, or a literal that itself carries a sentinel code and its delimiter
                     (`... MENU_PICK_FAILED: ...`) -- this product's own words, which Logic never
                     draws. Being a fragment of such a message elsewhere in the file is not
                     enough (review of #1034 R1-04), and neither is being a constant the product
                     also writes into its own script or refusal (round 2). Or, asked only after
                     every Apple route, the accessibility API's own vocabulary: a role or
                     subrole name (`AXDialog`) or a boolean AX value read as text (`true`)
  unknown            anything else -- FAILS, unless `docs/canon/AX-COMPARISON-WAIVERS.json` gives
                     it a reason. That file is the ONE exemption list; an entry nothing matches
                     fails too, so it only shrinks.

`--classify` prints every literal with its class. Swift escapes are decoded first: `\\u{FF1A}` is
the full-width colon, not eight ASCII characters.

A literal is found where it is written inline, and -- since the review of #1034 -- where an operand
NAMES a String constant whose initializer is one literal (`static let`, `let`, or a computed `var`
returning one literal): a bare name declared in the same file, or `Type.name` / `Self.name` naming a
static one. What is NOT followed: a value that reaches the comparison through a function parameter,
an instance member, an interpolation or any other expression. Measured on this tree: 17 such
operands, none of them classified by this guard.

WHAT COUNTS AS AX TEXT, AND HOW COARSELY
----------------------------------------
The compared variable is AX text when THIS FILE assigns a variable of that NAME from an accessor
(`ax_backed_names`), anywhere in the file. Since round 2 of the review of #1034 every such name is
scanned, not only names that look like an attribute (`_variable_pattern`), so renaming a reading
is not a way out. The model is by name and per file, not by data flow, and it errs both ways:

  too wide    a parameter or binding that shares its name with a reading elsewhere in the file
              is taken for AX text. `postLeafCleanup(_ value:)` in
              AccessibilityChannel+Transport.swift was, because that file reads a `value` from
              AX; it holds the script's own result and is named `scriptResult` now.
  too narrow  AX text that reaches a comparison through a parameter, a derived value, a property
              or an accessor this pattern does not list is not seen at all.

Exit: 0 = every AX comparison goes through a LabelSet or is declared · 1 = one does not
"""
import collections
import functools
import importlib.util
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAIVER = os.path.join(REPO, "docs", "canon", "AX-COMPARISON-WAIVERS.json")

_spec = importlib.util.spec_from_file_location(
    "policy_literals", os.path.join(REPO, "Scripts", "check-policy-literals-against-canon.py"))
policy = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(policy)
canon = policy.canon

LOCALES = ["de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh_CN", "zh_TW"]

_ll_spec = importlib.util.spec_from_file_location(
    "locale_labels_for_ax_comparisons", os.path.join(REPO, "Scripts", "locale_labels.py"))
_ll = importlib.util.module_from_spec(_ll_spec)
_ll_spec.loader.exec_module(_ll)
#: Swift's escapes, decoded by the same reader that writes ui-labels.json (#993, #1028).
_unescape = _ll._unescape

#: Names that read like an AX attribute. Matching on the VARIABLE is what keeps this from firing on
#: every string comparison in the tree — a JSON key named `name` is not an AX reading.
_AX_VAR = (r"(?:ax\w*|title|titles|desc|description|label|value|roleDescription|help"
           r"|placeholder|windowTitle|menuTitle|\w*[Nn]ame)")



def _folded_candidates(literal: str):
    """The spellings a case-folded comparison could have been written against."""
    seen, out = set(), []
    for candidate in (literal, literal.capitalize(), literal.title(), literal.upper()):
        if candidate and candidate not in seen:
            seen.add(candidate)
            out.append(candidate)
    return out


_CASE_LITERAL = re.compile(r"case\s+((?:\"(?:[^\"\\\n]|\\.)*\"\s*,?\s*)+):")

_LINE_COMMENT = re.compile(r"//[^\n]*")
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
_LABELSET_BLOCK = re.compile(r"LabelSet\(.*?rationale:.*?\)", re.S)


#: The directories scanned. `LPM_AX_COMPARISON_ROOTS` (os.pathsep-separated absolute paths)
#: replaces them, and exists for one reason: until 2026-09-18 this guard's self-test could not hand
#: it a file. Every case drove the helper functions and the suite finished with "the repository
#: passes" -- so `check()` returning `[]` unconditionally was GREEN, and the guard had never been
#: watched refuse anything. A seam that lets a test build an offending file is the difference
#: between testing the algorithm and testing the rule.
def _roots():
    override = os.environ.get("LPM_AX_COMPARISON_ROOTS")
    if override:
        return [p for p in override.split(os.pathsep) if p]
    return [os.path.join(REPO, "Sources"), os.path.join(REPO, "Scripts", "livekit")]


def swift_sources():
    for base in _roots():
        for dirpath, dirs, names in os.walk(base):
            dirs[:] = [d for d in dirs if d != ".build"]
            for name in sorted(names):
                if name.endswith(".swift"):
                    yield os.path.join(dirpath, name)


#: A variable holds an AX reading only if something READ it. Matching on the name alone reported
#: `if name == "Stop"` -- where `name` is this product's own command name, not Logic's label -- and
#: `parameter.bandName.hasSuffix("Cut")`, where `bandName` comes from a catalogue constant. Both
#: look exactly like a real finding and neither is one. So the variable has to be traceable to an
#: accessor in the same file.
_AX_READ = re.compile(
    r"(?:let|var)\s+(\w+)\s*(?::[^=\n]+)?=\s*[^\n]*?"
    r"(?:AXHelpers\.get\w+|getTitle|getDescription|getValue|copyAttributeValue"
    r"|AXUIElementCopyAttributeValue|roleDescription|\.axValue)",
    re.I)


def ax_backed_names(source: str) -> set:
    """Variables in this file that are assigned from an AX accessor."""
    return {m.group(1) for m in _AX_READ.finditer(source)}


#: A String constant whose initializer is ONE literal: `static let N = "…"`, `let N: String = "…"`
#: at any scope, or a computed `var N: String { "…" }`. An interpolated literal is not one.
_LITERAL = r'"((?:[^"\\\n]|\\.)*)"'
_CONSTANT = re.compile(r'(?:\b(static|class)\s+)?\blet\s+(\w+)\s*(?::\s*String\s*)?=\s*' + _LITERAL
                       + r'[ \t]*(?=\n|;|\}|$)')
_COMPUTED_CONSTANT = re.compile(r'(?:\b(static|class)\s+)?\bvar\s+(\w+)\s*:\s*String\s*\{\s*'
                                r'(?:return\s+)?' + _LITERAL + r'\s*\}')
_NAME = r'((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*)'
_NOT_A_CONSTANT = {"nil", "true", "false", "self", "Self", "super"}



@functools.lru_cache(maxsize=None)
def _shapes(var: str) -> dict:
    """Every comparison shape, with `var` as the pattern a compared variable's name must match.

    Built per file with that file's AX-backed names added to `_AX_VAR` (review of #1034, round 2).
    A variable assigned from an accessor but named `scriptResult` or `raw` used to be invisible:
    every shape anchored on the NAME looking like an attribute, and the backed check ran only on
    names that already did. So renaming a variable was a way out of the rule, and renaming one
    that does not hold AX text could not be told apart from that.
    """
    v = var
    comparisons = [
        re.compile(v + r"\w*\s*(?:==|!=)\s*\"((?:[^\"\\\n]|\\.)+)\"", re.I),
        re.compile(r"\"((?:[^\"\\\n]|\\.)+)\"\s*(?:==|!=)\s*" + v, re.I),
        re.compile(v + r"\w*(?:\?)?\.(?:contains|hasPrefix|hasSuffix"
                   r"|localizedCaseInsensitiveContains)\(\s*\"((?:[^\"\\\n]|\\.)+)\"", re.I),
        #: The three shapes an outside review walked the same defect through with every guard green.
        #: Each is the SAME comparison wearing different syntax, and each was invisible:
        #:
        #:     title.lowercased() == "mixer"          a method call between name and operator
        #:     ["Mixer", "Show Library"].contains(title)   the literal on the collection's side
        #:     switch title { case "Mixer": }         no operator at all
        #:
        #: A rule that names one spelling of a thing is a rule about spelling.
        re.compile(v + r"\w*(?:\?)?\.(?:trimmingCharacters)\([^)]*\)\s*(?:==|!=)"
                   r"\s*\"((?:[^\"\\\n]|\\.)+)\"", re.I),
        re.compile(v + r"\w*(?:\?)?\.(?:caseInsensitiveCompare|localizedStandardContains"
                   r"|localizedCaseInsensitiveCompare)\(\s*\"((?:[^\"\\\n]|\\.)+)\"", re.I),
    ]

    #: A comparison that CASE-FOLDS first. `title.lowercased() == "mixer"` compares the same label
    #: as `title == "Mixer"`, but the literal it carries is lowercase and Apple ships `Mixer`, so
    #: the corpus lookup in condition 2 misses it and the comparison passes. The literal must be
    #: folded back before it is looked up, or case-folding is a way to spell your way out of the
    #: rule.
    case_folded = re.compile(
        v + r"\w*(?:\?)?\.(?:lowercased|uppercased|localizedLowercase|localizedUppercase)"
        r"\([^)]*\)\s*(?:==|!=)\s*\"((?:[^\"\\\n]|\\.)+)\"", re.I)

    #: `["A", "B"].contains(axVar)` -- the literals sit in a collection and the AX reading is the
    #: ARGUMENT, so every pattern above, which anchors on the variable, looks straight past it.
    collection = re.compile(
        r"\[((?:\s*\"(?:[^\"\\\n]|\\.)*\"\s*,?)+)\]\s*\.contains\(\s*(" + v + r"\w*)", re.I)

    #: `switch axVar { case "A", "B": }` -- no comparison operator exists to match on. The body is
    #: taken non-greedily to the first closing brace at the switch's own indentation, which is
    #: coarse; over-reading a nested block reports a literal the switch does not compare, and that
    #: is the safe direction for a rule whose failure mode is silence.
    switch = re.compile(r"switch\s+(" + v + r"\w*)\b[^{\n]*\{(.*?)\n\s*\}", re.I | re.S)

    #: The comparison shapes above, with a NAME where they have a literal. Review of #1034: a
    #: literal moved into a constant left every shape above, so `static let label = "Mixer"`
    #: compared with an AX value passed -- and moving a literal into a constant is what a refactor
    #: does. `(axvar, name)`.
    name_comparisons = [
        (1, 2, re.compile(r'\b(' + v + r'\w*)\s*(?:==|!=)\s*' + _NAME + r'(?![\w.(\["])', re.I)),
        (2, 1, re.compile(_NAME + r'\s*(?:==|!=)\s*(' + v + r'\w*)\b(?!\s*[.(])', re.I)),
        (1, 2, re.compile(r'\b(' + v + r'\w*)(?:\?)?\.(?:contains|hasPrefix|hasSuffix'
                          r'|localizedCaseInsensitiveContains|caseInsensitiveCompare'
                          r'|localizedStandardContains|localizedCaseInsensitiveCompare)\(\s*'
                          + _NAME + r'\s*\)', re.I)),
        (1, 2, re.compile(r'\b(' + v + r'\w*)(?:\?)?\.(?:lowercased|uppercased|localizedLowercase'
                          r'|localizedUppercase|trimmingCharacters)\([^)]*\)\s*(?:==|!=)\s*' + _NAME
                          + r'(?![\w.(\["])', re.I)),
    ]
    name_collection = re.compile(r'\[\s*(' + _NAME[1:-1] + r'(?:\s*,\s*' + _NAME[1:-1]
                                  + r')*)\s*,?\s*\]\s*\.contains\(\s*(' + v + r'\w*)', re.I)
    return {"comparisons": comparisons, "case_folded": case_folded, "collection": collection,
            "switch": switch, "name_comparisons": name_comparisons,
            "name_collection": name_collection}


def _variable_pattern(backed: set) -> str:
    """`_AX_VAR`, or any name this file assigned from an accessor as a whole word: a backed `i`
    must not turn every `items == "x"` into a candidate."""
    if not backed:
        return _AX_VAR
    names = sorted(backed, key=len, reverse=True)
    return r"(?:" + _AX_VAR + r"|\b(?:" + "|".join(re.escape(n) for n in names) + r")\b)"


def literal_constants(sources: dict) -> dict:
    """`{name: [(literal, path, is_static)]}` over `{path: comment-stripped source}`."""
    out = collections.defaultdict(list)
    for path, source in sources.items():
        for pattern in (_CONSTANT, _COMPUTED_CONSTANT):
            for match in pattern.finditer(source):
                if "\\(" not in match.group(3):
                    out[match.group(2)].append((_unescape(match.group(3)), path,
                                                bool(match.group(1))))
    return out


def resolve_constant(operand: str, path: str, constants: dict) -> list:
    """The literal constants a comparison operand names: a bare name declared in the same file,
    or `Type.name` / `Self.name` naming a static one. `value.name` is an instance member and names
    none. Every declaration that fits is returned, so an ambiguous name is judged by all of them."""
    if operand in _NOT_A_CONSTANT:
        return []
    parts = operand.split(".")
    declared = constants.get(parts[-1]) or []
    if len(parts) == 1:
        return [d for d in declared if d[1] == path]
    if parts[0] == "Self" or parts[0][:1].isupper():
        return [d for d in declared if d[2]]
    return []


def comparisons_outside_labelsets():
    """{literal: {paths}} for every AX comparison whose literal is not a LabelSet's.

    Only comparisons against a variable this file actually READ from the accessibility API. A
    literal compared against an internal identifier is not a localisation bug however much it
    looks like one.
    """
    # Keyed by the literal's RUNTIME bytes, Swift escapes decoded and nothing else (review of #1034
    # R1-03). Every branch below used to key by `canon.normalize`, which strips and folds U+00A0,
    # so `title == " Channel EQ "` was recorded as `Channel EQ`, cited, and passed -- a comparison
    # that never matches what Logic draws. `inside` is exact for the same reason: a padded copy of
    # a LabelSet member does not go through the LabelSet.
    inside = set(policy.all_policy_literals())
    found = collections.defaultdict(set)

    def keep(literal: str) -> bool:
        return bool(canon.normalize(literal)) and literal not in inside

    sources = {}
    for path in swift_sources():
        with open(path, "r", encoding="utf-8") as handle:
            source = handle.read()
        source = _LINE_COMMENT.sub("", _BLOCK_COMMENT.sub(" ", source))
        sources[path] = _LABELSET_BLOCK.sub(" ", source)
    constants = literal_constants(sources)

    for path, source in sources.items():
        backed = ax_backed_names(source)
        if not backed:
            continue
        shapes = _shapes(_variable_pattern(backed))

        def through_constant(variable: str, operand: str) -> None:
            if variable.split(".")[0] not in backed:
                return
            for literal, _declared_in, _static in resolve_constant(operand, path, constants):
                if keep(literal):
                    found[literal].add(os.path.relpath(path, REPO))

        for variable_group, operand_group, pattern in shapes["name_comparisons"]:
            for match in pattern.finditer(source):
                through_constant(match.group(variable_group), match.group(operand_group))
        for match in shapes["name_collection"].finditer(source):
            for operand in re.split(r"\s*,\s*", match.group(1).strip()):
                through_constant(match.group(match.lastindex), operand)
        for match in shapes["switch"].finditer(source):
            for case in re.finditer(r"case\s+([^:\n]+):", match.group(2)):
                for operand in re.split(r"\s*,\s*", case.group(1).strip()):
                    if re.fullmatch(_NAME, operand):
                        through_constant(match.group(1), operand)
        for pattern in shapes["comparisons"]:
            for match in pattern.finditer(source):
                variable = re.match(r"[\w.]+", match.group(0).lstrip('"')).group(0).split(".")[0]
                if variable not in backed and match.group(0).lstrip()[0] != '"':
                    continue
                literal = _unescape(match.group(1))
                if keep(literal):
                    found[literal].add(os.path.relpath(path, REPO))
        for match in shapes["case_folded"].finditer(source):
            variable = re.match(r"[\w.]+", match.group(0)).group(0).split(".")[0]
            if variable not in backed:
                continue
            raw = _unescape(match.group(1))
            if not keep(raw):
                continue
            # Report the spelling Apple ships, so the message names a label a reader can find.
            # And the literal itself otherwise: until #1028 a folded literal Apple does not
            # translate was dropped here, before anything could classify it.
            shipped = next((c for c in _folded_candidates(raw) if canon.is_translated(c)), None)
            found[shipped or raw].add(os.path.relpath(path, REPO))
        for match in shapes["collection"].finditer(source):
            if match.group(2).split(".")[0] not in backed:
                continue
            for raw in re.findall(r'"((?:[^"\\\n]|\\.)*)"', match.group(1)):
                literal = _unescape(raw)
                if keep(literal):
                    found[literal].add(os.path.relpath(path, REPO))
        for match in shapes["switch"].finditer(source):
            if match.group(1).split(".")[0] not in backed:
                continue
            for group in _CASE_LITERAL.findall(match.group(2)):
                for raw in re.findall(r'"((?:[^"\\\n]|\\.)*)"', group):
                    literal = _unescape(raw)
                    if keep(literal):
                        found[literal].add(os.path.relpath(path, REPO))
    return found


def waived() -> dict:
    """`{literal: reason}`. A file that exists and cannot be read is a failure, not an empty list."""
    if not os.path.exists(WAIVER):
        return {}
    with open(WAIVER, "r", encoding="utf-8") as handle:
        entries = json.load(handle).get("literals") or {}
    return {literal: (entry.get("reason") if isinstance(entry, dict) else entry)
            for literal, entry in entries.items()}


#: An error or state code this product emits: `DIALOG_PREEXISTING`, `MENU_PICK_FAILED: <detail>`.
#: At least one underscore, so `EQ` or `MIDI` -- which are words Apple ships -- are not codes.
_SENTINEL = re.compile(r"[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+(?::.*)?", re.S)
_EXTENSION = re.compile(r"\.[a-z0-9]+")
_REVERSE_DNS = re.compile(r"[a-z][a-z0-9-]*(?:\.[a-z][A-Za-z0-9-]*)+\.?")

APPLE_TRANSLATED, APPLE_VALUE, IDENTIFIER, UNKNOWN = (
    "apple_translated", "apple_value", "identifier", "unknown")


def _apple_ships(literal: str) -> bool:
    """Apple ships `literal` as a WHOLE value in some source, in English or in no `.lproj`.

    Over the 32-bit absence sets, whose collisions run one way: an absent string can look present
    (rate in MANIFEST.json, `absence_false_positive`), which would class an unknown literal as
    `apple_value`. A present one never looks absent.
    """
    for source, block in (canon.load_manifest().get("sources") or {}).items():
        if source in canon.PIN_EVERY_ROW:
            # Every row of it is in the key index, so `citation` answers exactly and names the
            # row. Asking its 32-bit set as well would only add the collisions.
            continue
        for locale in ("en", "-"):
            if locale in (block.get("locales") or []) and not canon.is_absent(source, locale, literal):
                return True
    return False


#: A sentinel code WITH its delimiter, anywhere in the literal: `MENU_PICK_FAILED:`. Review of
#: #1034 R1-04: a literal used to count as this product's own words when it was merely a SUBSTRING
#: of some sentinel-coded message spelled out elsewhere in the same file, so adding
#: `let error = "MENU_PICK_FAILED: Input Po"` beside `title.hasPrefix("Input Po")` turned a
#: fragment of Apple's `Input Port` into an identifier. Error text a file happens to hold says
#: nothing about where the reading compared against it comes from; the literal has to carry the
#: code itself.
_OWN_CODE = re.compile(r"(?<![A-Za-z0-9_])[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+:")

#: The accessibility API's own vocabulary: a role, subrole or attribute name (`AXDialog`,
#: `AXSearchField`, `AXLayoutArea`), and the two spellings a boolean AX value reads as when it
#: arrives as text. None of them is text Logic draws, and no locale translates them. They became
#: visible when the scan began following every name a file assigns from an accessor, not only the
#: names that look like an attribute (review of #1034, round 2): `role == "AXLayoutArea"` in
#: AXLogicProElements+Mixer.swift and `switch text.lowercased() { case "1", "true": }` in
#: ArmKeyCommandSetup.swift. Asked only after every Apple route, like `_OWN_CODE`.
_AX_API_NAME = re.compile(r"AX[A-Z][A-Za-z]+")
_BOOLEAN_TEXT = {"true", "false"}


def citation(literal: str):
    """The pinned row a locale-independent source holds `literal` in, or None. Exact value only."""
    found = canon.locale_independent_citations(literal)
    return found[0] if found else None


def classify(literal: str, paths=()) -> str:
    if literal != canon.normalize(literal) and any(ch.isalnum() for ch in literal):
        # Review of #1034 R1-03. Every digest the canon holds is taken over `normalize`, which
        # strips and folds U+00A0, so ` Channel EQ `, `Channel\u{00A0}EQ` and `Channel EQ\n` all
        # hash to Apple's `Channel EQ` -- and none of them equals what Logic draws. A literal whose
        # bytes the canon cannot vouch for exactly is not Apple's value, whichever route asks.
        return UNKNOWN
    if canon.is_translated(literal):
        return APPLE_TRANSLATED
    if not any(ch.isalnum() for ch in literal):
        return IDENTIFIER
    if any(pattern.fullmatch(literal) for pattern in (_SENTINEL, _EXTENSION, _REVERSE_DNS)):
        return IDENTIFIER
    if citation(literal):
        # Apple's data holds it in a file with no language: the same bytes in every locale.
        return APPLE_VALUE
    if _apple_ships(literal):
        return APPLE_VALUE
    if _OWN_CODE.search(literal):
        return IDENTIFIER
    if _AX_API_NAME.fullmatch(literal) or literal in _BOOLEAN_TEXT:
        return IDENTIFIER
    return UNKNOWN


#: Separator spellings Apple ships for the same mark, from docs/canon/DECORATION-RULES.json.
#: A literal made only of punctuation is not a LABEL and cannot go in a LabelSet -- `:` names no
#: control. What it must do instead is handle every spelling: a Chinese Logic writes the full-width
#: `\uff1a` where the others write `:`, so code that tests one and not the other reads a clock time
#: as a dotted position. So the rule for punctuation is different in shape and identical in intent.
def separator_groups() -> list:
    path = os.path.join(REPO, "docs", "canon", "DECORATION-RULES.json")
    try:
        with open(path, "r", encoding="utf-8") as handle:
            rules = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return []
    return [set(block.get("allows_trailing") or [])
            for block in (rules.get("kinds") or {}).values()
            if len(block.get("allows_trailing") or []) > 1]


def handles_every_spelling(literal: str, paths) -> bool:
    """True when the file testing this separator also tests its other spellings."""
    group = next((g for g in separator_groups() if literal in g), None)
    if group is None:
        return False
    for path in paths:
        with open(os.path.join(REPO, path), "r", encoding="utf-8") as handle:
            source = handle.read()
        # `source.upper()` uppercases the `u` in `\u{FF1A}` too, so compare case-insensitively
        # rather than upper-casing one side. The first version looked for a lowercase `\u` in an
        # upper-cased haystack and could never find it -- a check that cannot pass.
        escapes = {f"\\u{{{ord(alt):04x}}}" for alt in group}
        lowered = source.lower()
        missing = [alt for alt in group
                   if alt != literal
                   and alt not in source
                   and f"\\u{{{ord(alt):04x}}}" not in lowered]
        if missing:
            return False
    return True


def check(app: str = None) -> list:
    """Offline. `docs/canon/absence/translated.en.u32` carries the answer to condition 3.

    The first version read the bundle for it, so it could not run in CI -- the one place it has to.
    Every guard here is plain Python over committed artefacts for exactly that reason, and this one
    forgot it. `app` is kept for the self-test and ignored.
    """
    if not canon.load_translated():
        return ["docs/canon/absence/translated.en.u32 is missing or empty, so nothing can tell a "
                "translated label from an untranslated one. Run Scripts/logic_canon.py build on a "
                "machine with Logic."]
    try:
        allowed = waived()
    except (OSError, json.JSONDecodeError, AttributeError) as exc:
        return [f"{os.path.relpath(WAIVER, REPO)} cannot be read: {exc}"]
    problems = []
    used = set()
    for literal, reason in sorted(allowed.items()):
        if not (isinstance(reason, str) and reason.strip()):
            problems.append(f"{os.path.relpath(WAIVER, REPO)}: {literal!r} carries no reason. An "
                            f"exemption without one is a literal nobody checked.")
    for literal, paths in sorted(comparisons_outside_labelsets().items()):
        kind = classify(literal, paths)
        if kind in (APPLE_VALUE, IDENTIFIER):
            continue                      # shipped untranslated, or a shape no locale translates
        if literal in allowed:
            used.add(literal)
            continue
        if kind == UNKNOWN:
            where = ", ".join(sorted(os.path.basename(p) for p in paths))
            problems.append(
                f"{literal!r} is compared against an AX reading in {where}, and it is neither a "
                f"whole value Apple ships nor an identifier. A fragment of a translated label or a "
                f"string from somewhere else works in whatever language it happens to be in. Use "
                f"a LabelSet, or declare it in {os.path.relpath(WAIVER, REPO)} with the reason it "
                f"is safe.")
            continue
        if not literal.strip(policy.canon._DECORATION):
            # Punctuation, not a label. It passes when the file handles every spelling Apple ships.
            if handles_every_spelling(literal, paths):
                continue
            group = next((g for g in separator_groups() if literal in g), set())
            problems.append(
                f"{literal!r} is a SEPARATOR compared against an AX reading in "
                f"{', '.join(sorted(os.path.basename(p) for p in paths))}, and Apple ships it in "
                f"more than one spelling ({' '.join(sorted(group))}). It names no control, so it "
                f"cannot go in a LabelSet -- handle every spelling instead, in one place.")
            continue
        where = ", ".join(sorted(os.path.basename(p) for p in paths))
        problems.append(
            f"{literal!r} is compared against an AX reading in {where}, Apple ships it, and Apple "
            f"TRANSLATES it -- so this comparison works in English and fails in every other "
            f"language. Move it into an AXLocalePolicy LabelSet, or declare it in "
            f"{os.path.relpath(WAIVER, REPO)} with the reason it is safe.")
    # Only over the real tree: an exemption describes a comparison in `Sources/`, and a scan the
    # self-test pointed somewhere else cannot say whether that comparison still exists.
    stale = set() if os.environ.get("LPM_AX_COMPARISON_ROOTS") else set(allowed) - used
    for literal in sorted(stale):
        problems.append(
            f"{os.path.relpath(WAIVER, REPO)} exempts {literal!r}, and no comparison that needs an "
            f"exemption uses it. Delete the entry: the list only shrinks.")
    return problems


def main() -> int:
    if "--classify" in sys.argv[1:]:
        for literal, paths in sorted(comparisons_outside_labelsets().items()):
            where = ", ".join(sorted(os.path.basename(p) for p in paths))
            cited = citation(literal)
            print(f"{classify(literal, paths):17s} {literal!r}  ({where})"
                  + (f"  <- {cited}" if cited else ""))
        return 0
    problems = check()
    if problems:
        print(f"{len(problems)} AX comparison(s) bypass AXLocalePolicy:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    found = comparisons_outside_labelsets()
    kinds = collections.Counter(classify(literal, paths) for literal, paths in found.items())
    by_row = {literal: citation(literal) for literal in found}
    by_row = {literal: cited for literal, cited in sorted(by_row.items()) if cited}
    print(f"every AX comparison outside a LabelSet is classified: {len(found)} literal(s) -- "
          + ", ".join(f"{kind} {count}" for kind, count in sorted(kinds.items()))
          + f"; {len(waived())} exempted by reason"
          + "".join(f"; {literal!r} <- {cited}" for literal, cited in by_row.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
