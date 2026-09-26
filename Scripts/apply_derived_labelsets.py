#!/usr/bin/env python3
"""Write the SAFE derivations into `AXLocalePolicy.swift`. Reporting lives next door.

`derive_label_variants.py` says which row each LabelSet is the values of. This applies the ones
where that is pure ADDITION -- the row already holds every string the label carries, so the edit
cannot lose a reading somebody took off a running Logic, and no judgement is involved.

Everything else is reported and not written. Measured over 159 LabelSets: 78 are safe, 34 carry a
member the row does not hold, 30 are ambiguous between rows that disagree, and 17 have no row. The
34 are not all one thing -- most are the lowercase fragments this product matches by containment
and which are not values of anything, but `pluginOpenOrListControl` matches `open` AND `list` and
`nonInsertButtonText` carries 25 members spanning a dozen controls. A compound label is not one
row's values and must not be made to look like one, so a person reads those.

    Scripts/apply_derived_labelsets.py --dry-run     what would change, and what would not
    Scripts/apply_derived_labelsets.py --write       change it

Needs Logic. The GUARD that checks the result needs nothing.
"""
import importlib.util
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT = os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")

_OPENING = re.compile(r"( {4}static let (?P<name>[A-Za-z0-9_]+) = LabelSet\()")
_VARIANTS = re.compile(r"variants: \[(.*?)\]", re.S)
_CANONICAL = re.compile(r'canonical: "((?:[^"\\]|\\.)*)"')
_STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
#: The rationale, in all three shapes this file uses: one literal, a `"""` block, or `+` pieces.
_RATIONALE = re.compile(
    r'rationale: (?:"""(?:.|\n)*?"""|"(?:[^"\\]|\\.)*"(?:\s*\+\s*"(?:[^"\\]|\\.)*")*)')

NOTE = (" Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this "
        "control{via}; the strings this label already carried are each one of that row's own "
        "values, so nothing measured was dropped and nothing was typed. Checked offline by "
        "Scripts/check-labelsets-are-derived.py.")


def _tool():
    spec = importlib.util.spec_from_file_location(
        "derive_label_variants", os.path.join(REPO, "Scripts", "derive_label_variants.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def block_end(source: str, start: int) -> int:
    """Index just past the `)` closing the call opened at `start`, skipping string literals.

    By parentheses rather than by shape, for the reason the guard next door records: the two
    declarations that defeated a shape-matching reader were ordinary Swift.
    """
    depth, index, length = 0, start, len(source)
    while index < length:
        char = source[index]
        if char == '"':
            if source.startswith('"""', index):
                end = source.find('"""', index + 3)
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
                return index + 1
        index += 1
    raise ValueError("unbalanced parentheses in a LabelSet declaration")


def _escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


def _swift_literals():
    spec = importlib.util.spec_from_file_location(
        "locale_labels_for_apply", os.path.join(REPO, "Scripts", "locale_labels.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The same reader check-labelsets-are-derived.py and ui-labels.json decode with; a copy that undid
# only `\"` and `\\` read `\u{00A0}` as eight characters (#993).
_unescape = _swift_literals()._unescape


def rewrite(source: str, canon, report) -> tuple:
    """(source, applied, skipped). `applied` is [(name, strings added)]."""
    applied, skipped = [], []
    for name, record in sorted(report.items()):
        if record.get("applicability") != "safe":
            skipped.append((name, record["verdict"], record.get("applicability") or "-"))
            continue
        match = next((m for m in _OPENING.finditer(source) if m.group("name") == name), None)
        if match is None:
            skipped.append((name, "not-a-static-let", "-"))
            continue
        end = block_end(source, match.end() - 1)
        block = source[match.start():end]
        if "derivedFrom:" in block:
            continue
        variants = _VARIANTS.search(block)
        canonical = _CANONICAL.search(block)
        rationale = _RATIONALE.search(block)
        if not (variants and canonical and rationale):
            skipped.append((name, "unreadable-declaration", "-"))
            continue
        existing = _STRING.findall(variants.group(1))
        # Case-FOLDED, unlike the corpus. `canon.normalize` deliberately does not fold case,
        # because "does Apple ship this string" is exact -- but the question here is "does adding
        # this give the product anything to match", and every `LabelSet.matches` mode is
        # case-insensitive. Without the fold the derivation put `Automation` beside the lowercase
        # `automation` this product carries for containment, and `Mixer` beside `mixer`, in eight
        # places. `check-probe-product-drift.py` refuses exactly that, and it is right to.
        def fold(text):
            return canon.normalize(text).casefold()

        folded = {fold(_unescape(canonical.group(1)))}
        folded |= {fold(_unescape(text)) for text in existing}
        added = []
        for locale in _tool_locales():
            value = record["values"][locale]
            if fold(value) not in folded:
                added.append(_escape(value))
                folded.add(fold(value))
        merged = existing + added
        body = ", ".join(f'"{text}"' for text in merged)
        block = block[:variants.start()] + f"variants: [{body}]" + block[variants.end():]
        rationale = _RATIONALE.search(block)
        if rationale is None:
            skipped.append((name, "rationale-vanished", "-"))
            continue
        via = f", keyed `{record['namespace']}` in Apple's own namespace" if record.get("namespace") else ""
        # Appended as a trailing `+ "..."` rather than edited INTO the literal, because the file
        # writes a rationale three ways -- one literal, a `\"\"\"` block, and pieces joined with
        # `+` -- and a reader that had to rewrite the inside of each would be a fourth thing that
        # can be wrong. Concatenation is valid Swift after all three.
        block = (block[:rationale.end()]
                 + '\n            + "' + NOTE.format(via=via) + '"'
                 + ',\n        derivedFrom: "' + record["ref"] + '"'
                 + block[rationale.end():])
        source = source[:match.start()] + block + source[end:]
        applied.append((name, len(added)))
    return source, applied, skipped


def _tool_locales():
    return _tool().LOCALES


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--write" not in argv and "--dry-run" not in argv:
        print(__doc__, file=sys.stderr)
        return 2
    tool = _tool()
    if not os.path.isdir(tool.APP):
        print(f"{tool.APP} is not installed; this reads Apple's bytes.", file=sys.stderr)
        return 2
    canon = tool._canon()
    rows = tool.corpus_rows(canon)
    index = tool.by_value(canon, rows)
    labels = tool.load_labels()
    report = tool._report(canon, rows, index, labels, [])
    with open(SWIFT, encoding="utf-8") as handle:
        source = handle.read()
    updated, applied, skipped = rewrite(source, canon, report)
    print(f"{len(applied)} LabelSet(s) derived, {sum(n for _, n in applied)} strings added; "
          f"{len(skipped)} left alone")
    by_reason = {}
    for _, verdict, why in skipped:
        by_reason[(verdict, why)] = by_reason.get((verdict, why), 0) + 1
    for (verdict, why), count in sorted(by_reason.items(), key=lambda pair: -pair[1]):
        print(f"    {count:4}  {verdict}/{why}")
    if "--write" in argv:
        with open(SWIFT, "w", encoding="utf-8") as handle:
            handle.write(updated)
        print(f"wrote {os.path.relpath(SWIFT, REPO)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
