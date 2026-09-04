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

    Scripts/locale_labels.py --write     regenerate the JSON from AXLocalePolicy.swift
    Scripts/locale_labels.py --check     exit 1 if they disagree

`measured` is where "the variants list grows when a locale is observed, not when one is translated"
stops being a comment and becomes data: each variant may name the date, the observation record and
the exact string that was read. `check-locale-labels-json.py` ratchets that coverage.
"""
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT = os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
JSON_PATH = os.path.join(REPO, "docs", "locale", "ui-labels.json")

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


def _unescape(text):
    return text.replace('\\"', '"').replace("\\\\", "\\")


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


def build(existing=None):
    """The JSON document: the Swift projection, with any `measured` blocks carried forward."""
    existing = existing if existing is not None else load_json()
    previous = (existing.get("labels") or {})
    labels = {}
    for name, entry in sorted(from_swift().items()):
        measured = (previous.get(name) or {}).get("measured")
        if measured:
            # Provenance survives regeneration, but only for variants that still exist.
            entry = dict(entry)
            entry["measured"] = {k: v for k, v in measured.items() if k in entry["variants"]}
        labels[name] = entry
    return {
        "schema": 1,
        "generated_from": "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift",
        "how_to_regenerate": "Scripts/locale_labels.py --write",
        "note": (
            "Swift is the compiled source of truth; this is its projection for everything that "
            "cannot import Swift. `measured` records where a variant was READ — the rule is that "
            "the list grows when a locale is observed, not when one is translated."
        ),
        "labels": labels,
    }


def main():
    args = sys.argv[1:]
    doc = build()
    if "--write" in args:
        os.makedirs(os.path.dirname(JSON_PATH), exist_ok=True)
        with open(JSON_PATH, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        print(f"wrote {len(doc['labels'])} labels to docs/locale/ui-labels.json")
        return 0
    if "--check" in args:
        on_disk = load_json()
        if (on_disk.get("labels") or {}) != doc["labels"]:
            print("docs/locale/ui-labels.json disagrees with AXLocalePolicy.swift")
            return 1
        print(f"{len(doc['labels'])} labels agree")
        return 0
    json.dump(doc, sys.stdout, indent=2, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
