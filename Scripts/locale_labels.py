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

`provenance` (schema 2; `measured` in schema 1) is where "the variants list grows when a locale is
observed, not when one is translated" stops being a comment and becomes data: each variant names
the observation record it was read in, the locale that record is true of, the date, and the exact
string that was read. `coverage` says, per supported locale, what is KNOWN about the label —
`measured` (a record in that locale saw one of its strings), `identifier` (addressed by a
locale-free AXIdentifier, and a record saw it), or `unmeasured`, the only one that is a gap. ADR-019.
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


SUPPORTED_LOCALES = ("en-US", "ko-KR", "ja-JP")
COVERAGE_VALUES = ("measured", "identifier", "unmeasured")


def build(existing=None):
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
    """
    existing = existing if existing is not None else load_json()
    previous = (existing.get("labels") or {})
    labels = {}
    for name, entry in sorted(from_swift().items()):
        prior = previous.get(name) or {}
        entry = dict(entry)
        provenance = prior.get("provenance") or prior.get("measured") or {}
        # Provenance survives regeneration, but only for variants that still exist.
        provenance = {k: v for k, v in provenance.items() if k in entry["variants"]}
        if provenance:
            entry["provenance"] = provenance
        carried = prior.get("coverage") or {}
        cited = prior.get("coverage_records") or {}
        present_in = {str((b or {}).get("locale")) for b in provenance.values()}
        coverage = {}
        for locale in SUPPORTED_LOCALES:
            if locale in present_in:
                coverage[locale] = "measured"
            elif carried.get(locale) in ("measured", "identifier") and cited.get(locale):
                # A claim of measurement is carried only with the record that showed it. One nobody
                # cited would otherwise ride through every regeneration as if it were evidence —
                # the guard would refuse it, but the projection should not emit it.
                coverage[locale] = carried[locale]
            else:
                coverage[locale] = "unmeasured"
        entry["coverage"] = coverage
        # A claim of absence, or of identifier addressing, names the record that showed it — and
        # that citation has to survive regeneration exactly as provenance does, or every --write
        # would turn a measured `absent` back into `unmeasured` by erasing its evidence.
        # All THREE citation maps travel together. Carrying only the record id was a data-loss bug:
        # the next `--write` stripped the role and the identifier, and the guard then rejected a
        # claim that had been valid — regeneration turning evidence into a failure.
        def carried(field):
            return {loc: v for loc, v in (prior.get(field) or {}).items()
                    if loc in SUPPORTED_LOCALES and coverage.get(loc) in ("measured", "identifier")
                    and loc not in present_in}

        for field in ("coverage_records", "coverage_roles", "coverage_identifiers"):
            kept = carried(field)
            if kept:
                entry[field] = kept
        labels[name] = entry
    return {
        "schema": 2,
        "generated_from": "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift",
        "how_to_regenerate": "Scripts/locale_labels.py --write",
        "note": (
            "Swift is the compiled source of truth; this is its projection for everything that "
            "cannot import Swift. `provenance` records where a variant was READ — the observation "
            "record, its locale, the date and the exact string — and `coverage` says per locale "
            "what is known about the label. `unmeasured` is the only value that is a gap. ADR-019."
        ),
        "supported_locales": list(SUPPORTED_LOCALES),
        "coverage_values": list(COVERAGE_VALUES),
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
