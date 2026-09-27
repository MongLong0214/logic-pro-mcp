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
                     enough (review of #1034 R1-04)
  unknown            anything else -- FAILS, unless `docs/canon/AX-COMPARISON-WAIVERS.json` gives
                     it a reason. That file is the ONE exemption list; an entry nothing matches
                     fails too, so it only shrinks.

`--classify` prints every literal with its class. Swift escapes are decoded first: `\\u{FF1A}` is
the full-width colon, not eight ASCII characters.

Exit: 0 = every AX comparison goes through a LabelSet or is declared · 1 = one does not
"""
import collections
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

_COMPARISONS = [
    re.compile(_AX_VAR + r"\w*\s*(?:==|!=)\s*\"((?:[^\"\\\n]|\\.)+)\"", re.I),
    re.compile(r"\"((?:[^\"\\\n]|\\.)+)\"\s*(?:==|!=)\s*" + _AX_VAR, re.I),
    re.compile(_AX_VAR + r"\w*(?:\?)?\.(?:contains|hasPrefix|hasSuffix"
               r"|localizedCaseInsensitiveContains)\(\s*\"((?:[^\"\\\n]|\\.)+)\"", re.I),
    #: The three shapes an outside review walked the same defect through with every guard green.
    #: Each is the SAME comparison wearing different syntax, and each was invisible:
    #:
    #:     title.lowercased() == "mixer"          a method call between the name and the operator
    #:     ["Mixer", "Show Library"].contains(title)   the literal on the collection's side
    #:     switch title { case "Mixer": }         no operator at all
    #:
    #: A rule that names one spelling of a thing is a rule about spelling.
    re.compile(_AX_VAR + r"\w*(?:\?)?\.(?:trimmingCharacters)\([^)]*\)\s*(?:==|!=)"
               r"\s*\"((?:[^\"\\\n]|\\.)+)\"", re.I),
    re.compile(_AX_VAR + r"\w*(?:\?)?\.(?:caseInsensitiveCompare|localizedStandardContains"
               r"|localizedCaseInsensitiveCompare)\(\s*\"((?:[^\"\\\n]|\\.)+)\"", re.I),
]

#: A comparison that CASE-FOLDS first. `title.lowercased() == "mixer"` compares the same label as
#: `title == "Mixer"`, but the literal it carries is lowercase and Apple ships `Mixer`, so the
#: corpus lookup in condition 2 misses it and the comparison passes. The literal must be folded
#: back before it is looked up, or case-folding is a way to spell your way out of the rule.
_CASE_FOLDED = re.compile(
    _AX_VAR + r"\w*(?:\?)?\.(?:lowercased|uppercased|localizedLowercase|localizedUppercase)"
    r"\([^)]*\)\s*(?:==|!=)\s*\"((?:[^\"\\\n]|\\.)+)\"", re.I)


def _folded_candidates(literal: str):
    """The spellings a case-folded comparison could have been written against."""
    seen, out = set(), []
    for candidate in (literal, literal.capitalize(), literal.title(), literal.upper()):
        if candidate and candidate not in seen:
            seen.add(candidate)
            out.append(candidate)
    return out


#: `["A", "B"].contains(axVar)` -- the literals sit in a collection and the AX reading is the
#: ARGUMENT, so every pattern above, which anchors on the variable, looks straight past it.
_COLLECTION_CONTAINS = re.compile(
    r"\[((?:\s*\"(?:[^\"\\\n]|\\.)*\"\s*,?)+)\]\s*\.contains\(\s*(" + _AX_VAR + r"\w*)", re.I)

#: `switch axVar { case "A", "B": }` -- no comparison operator exists to match on. The body is
#: taken non-greedily to the first closing brace at the switch's own indentation, which is coarse;
#: over-reading a nested block reports a literal the switch does not compare, and that is the safe
#: direction for a rule whose failure mode is silence.
_SWITCH = re.compile(r"switch\s+(" + _AX_VAR + r"\w*)\b[^{\n]*\{(.*?)\n\s*\}", re.I | re.S)
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

    for path in swift_sources():
        with open(path, "r", encoding="utf-8") as handle:
            source = handle.read()
        source = _LINE_COMMENT.sub("", _BLOCK_COMMENT.sub(" ", source))
        source = _LABELSET_BLOCK.sub(" ", source)
        backed = ax_backed_names(source)
        if not backed:
            continue
        for pattern in _COMPARISONS:
            for match in pattern.finditer(source):
                variable = re.match(r"[\w.]+", match.group(0).lstrip('"')).group(0).split(".")[0]
                if variable not in backed and match.group(0).lstrip()[0] != '"':
                    continue
                literal = _unescape(match.group(1))
                if keep(literal):
                    found[literal].add(os.path.relpath(path, REPO))
        for match in _CASE_FOLDED.finditer(source):
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
        for match in _COLLECTION_CONTAINS.finditer(source):
            if match.group(2).split(".")[0] not in backed:
                continue
            for raw in re.findall(r'"((?:[^"\\\n]|\\.)*)"', match.group(1)):
                literal = _unescape(raw)
                if keep(literal):
                    found[literal].add(os.path.relpath(path, REPO))
        for match in _SWITCH.finditer(source):
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
