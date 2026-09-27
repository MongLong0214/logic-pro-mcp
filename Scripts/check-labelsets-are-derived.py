#!/usr/bin/env python3
"""A LabelSet that names a row must actually be that row's values, in every locale Logic ships.

`derivedFrom` says "these strings are Apple's own, at this `(unit, key)`". Saying it is free; this
makes it true. For each of the ten locales the corpus carries, one of the LabelSet's strings must
be the value pinned for that row -- by digest, offline, so it runs in CI where there is no Logic.

Two directions, and both matter:

- a locale with NO member is a language the product cannot match at that site. That is #892: a
  LabelSet with three variants covers three of the ten languages Logic ships, and nothing said so.
- a `derivedFrom` whose row nobody pinned is a claim nothing checked. `logic_canon.py build` pins a
  cited row in every locale, so an unpinned one means the reference was typed and never resolved.

A set may name more rows in `alsoDerivedFrom`, and each is held to the same rule (#291). One Mute is
two rows in German: the track header draws `Stumm` (`Mute`) and the Mixer strip `Ton aus`
(`Mute#acc`), and a set checked against only the second passed while the header lookup failed.

What it deliberately does NOT do is require the members to be ONLY the row's values. `variants`
carries tolerance Apple's data does not contain on purpose -- `Auto Punch` beside `Autopunch` --
and a check that forbade the extra would refuse the thing the field exists for.
"""
import importlib.util
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
#: A seam, so the self-test can drive main() -- the ENTRY POINT -- at a tree that must
#: fail. Without one every case reaches the helpers only, and a `main()` returning 0
#: unconditionally stays green; Scripts/mutation-sweep-guard-tests.py measured that for
#: this guard on 2026-09-18.
SWIFT = os.environ.get("LPM_POLICY_SWIFT") or os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")

_OPENING = re.compile(r'static let (?P<name>[A-Za-z0-9_]+) = LabelSet\(')
_CANONICAL = re.compile(r'canonical: "(?P<canonical>(?:[^"\\]|\\.)*)"')
_VARIANTS = re.compile(r'variants: \[(?P<variants>.*?)\]', re.S)
_DERIVED = re.compile(r'derivedFrom: "(?P<ref>[^"]*)"')
#: #291 -- a second row the same strings are ALSO the values of. The header and the Mixer strip name
#: one Mute with two rows that part in German (`Stumm` / `Ton aus`), so one `derivedFrom` could
#: prove only one of the two lookups the set serves.
_ALSO = re.compile(r'alsoDerivedFrom: \[(?P<refs>[^\]]*)\]', re.S)
_ALSO_OPENING = re.compile(r'alsoDerivedFrom:')


class UnreadableDeclaration(Exception):
    """A LabelSet this reader cannot parse. Raised, never skipped.

    A declaration the guard cannot read is a declaration the guard does not check, and a check that
    silently covers 153 of 155 reports clean over a tree it never examined. The two it first missed
    were ordinary Swift -- a `\"\"\"` multi-line rationale and one built with `+` -- so the shapes
    that defeat a reader are not exotic.
    """


def _block(source: str, start: int) -> str:
    """The text of one `LabelSet( ... )` call, found by matching parentheses rather than by shape.

    String literals are skipped so a `(` inside a rationale cannot close the call early.
    """
    depth, index, length = 0, start, len(source)
    while index < length:
        char = source[index]
        if char == '"':
            if source.startswith('\"\"\"', index):
                end = source.find('\"\"\"', index + 3)
                index = length if end == -1 else end + 3
                continue
            index += 1
            while index < length and source[index] != '"':
                index += 2 if source[index] == "\\" else 1
            index += 1
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
        index += 1
    raise UnreadableDeclaration("unbalanced parentheses")


def _canon():
    spec = importlib.util.spec_from_file_location(
        "logic_canon_for_labelsets", os.path.join(REPO, "Scripts", "logic_canon.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _swift_literals():
    spec = importlib.util.spec_from_file_location(
        "locale_labels_for_labelsets", os.path.join(REPO, "Scripts", "locale_labels.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# #993 -- Swift's escapes are decoded by locale_labels.py's reader, the one that writes
# ui-labels.json. This file used to undo only `\"` and `\\`, so a member written
# `Audio Units\u{00A0}:` reached the digest as the eight characters `\u{00A0}` and the one
# language whose row it is (fr) was reported as a language the product cannot work in.
_unescape = _swift_literals()._unescape


def declarations(source: str):
    """(name, members, derivedFrom) for every `static let ... = LabelSet(...)` in the file.

    Raises `UnreadableDeclaration` rather than skipping one it cannot parse.
    """
    for name, members, derived, _also in _parsed(source):
        yield name, members, derived


def derivations(source: str):
    """(name, members, every row it names) -- `derivedFrom` first, then each `alsoDerivedFrom`."""
    for name, members, derived, also in _parsed(source):
        yield name, members, ([derived] if derived else []) + also, derived is None and bool(also)


def _parsed(source: str):
    for opening in _OPENING.finditer(source):
        name = opening.group("name")
        try:
            block = _block(source, opening.end() - 1)
        except UnreadableDeclaration as exc:
            raise UnreadableDeclaration(f"{name}: {exc}") from exc
        canonical = _CANONICAL.search(block)
        variants = _VARIANTS.search(block)
        if canonical is None or variants is None:
            raise UnreadableDeclaration(
                f"{name}: no `canonical:` or no `variants:` this reader can read. A LabelSet it "
                f"cannot parse is one it does not check, and a guard that skips reports clean.")
        found = [_unescape(part.strip().strip('"'))
                 for part in re.findall(r'"((?:[^"\\]|\\.)*)"', variants.group("variants"))]
        members = [_unescape(canonical.group("canonical"))] + found
        derived = _DERIVED.search(block)
        also = []
        if _ALSO_OPENING.search(block):
            listed = _ALSO.search(block)
            if listed is None:
                raise UnreadableDeclaration(
                    f"{name}: an `alsoDerivedFrom:` this reader cannot read. A row it cannot see is "
                    f"a row it does not check.")
            also = re.findall(r'"([^"]*)"', listed.group("refs"))
            if not also:
                raise UnreadableDeclaration(f"{name}: `alsoDerivedFrom:` names no row")
        yield (name, [member for member in members if member],
               derived.group("ref") if derived else None, also)


def check(source: str, canon) -> tuple:
    failures, checked = [], 0
    manifest = canon.load_manifest()
    # One row can span two SOURCES: Apple compiles the English of 162 tables into `Base.lproj` nibs
    # and ships the nine translations as `.strings`, so `GotoPosition.strings 5.title` is
    # `nibstrings` in English and `strings` in every other language. The reference names whichever
    # source holds the locale it cites, and the CHECK has to read both or it reports a language as
    # missing that Apple ships -- the false absence #895 exists to stop, arriving by a new route.
    namespace_of = {name: canon.TRANSLATION_NAMESPACE.get(name, name)
                    for name in (manifest.get("sources") or {})}
    indexes = {name: canon.load_index(name) for name in namespace_of}
    for name, members, refs, orphaned in derivations(source):
        if orphaned:
            failures.append(
                f"{name}: `alsoDerivedFrom` with no `derivedFrom`. The first row is the one every "
                f"other reader of this file takes as the set's row; name it there.")
        if not refs:
            continue
        checked += 1
        for ref_text in refs:
            _check_row(name, members, ref_text, canon, manifest, namespace_of, indexes, failures)
    return failures, checked


def _check_row(name, members, ref_text, canon, manifest, namespace_of, indexes, failures):
    """One row a LabelSet names: it parses, it is pinned in every locale, and a member covers each."""
    try:
        ref = canon.CanonRef.parse(ref_text)
    except canon.CanonError as exc:
        failures.append(f"{name}: {exc}")
        return
    if ref.is_value_citation or not ref.key:
        failures.append(
            f"{name}: `derivedFrom` must name a ROW -- a unit, a locale and a key. "
            f"{ref_text!r} names no key, so there is nothing to read ten locales from.")
        return
    peers = [source for source, space in namespace_of.items()
             if space == namespace_of.get(ref.source, ref.source)]
    locales = sorted({locale
                      for source in peers
                      for locale in (manifest["sources"][source].get("locales") or [])
                      if locale != "-"})
    if not locales:
        failures.append(f"{name}: source {ref.source!r} pins no locales")
        return
    # Case-FOLDED, because that is the question the product asks. Every `LabelSet.matches`
    # mode is case-insensitive, so the lowercase `mixer` this product carries for containment
    # DOES match Apple's `Mixer`; comparing exact digests called that a language the product
    # cannot work in. `build` pins a `#ci` digest beside each cited row for exactly this.
    digests = {canon.short_digest(canon.normalize(member).casefold())
               for member in members}
    uncovered, unpinned = [], []
    for locale in sorted(locales):
        row = (ref.unit, locale, ref.key, ref.field + canon.CASE_INSENSITIVE)
        pinned = next((indexes[source].get(row) for source in peers
                       if indexes[source].get(row)), None)
        if pinned is None:
            unpinned.append(locale)
        elif pinned not in digests:
            uncovered.append(locale)
    if unpinned:
        failures.append(
            f"{name}: {ref.unit.split('/')[-1]} {ref.key} is not pinned for {unpinned}. "
            f"`Scripts/logic_canon.py build` pins a cited row in every locale, so an unpinned "
            f"one means this reference was typed and never resolved against Logic.")
    if uncovered:
        failures.append(
            f"{name}: no member of this LabelSet is what Apple ships in {uncovered} at "
            f"{ref.unit.split('/')[-1]} {ref.key}. The row says one thing there and this label "
            f"cannot match it, which is a language the product does not work in at this site.")


def main() -> int:
    with open(SWIFT, encoding="utf-8") as handle:
        source = handle.read()
    total = sum(1 for _ in declarations(source))
    failures, checked = check(source, _canon())
    if failures:
        print(f"{len(failures)} problem(s) with derived LabelSets:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"{checked} of {total} LabelSets name a row, and every one of them is that row's own "
          f"values in every locale the corpus carries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
