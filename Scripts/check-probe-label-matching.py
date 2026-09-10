#!/usr/bin/env python3
"""The AX probe restates a matching rule the product owns. This fails when they can drift.

WHY THIS EXISTS
---------------
`Scripts/livekit/ax_plugin_menu_probe.swift` runs outside the product and cannot import it, so it
restates `AXLocalePolicy` matching. On 2026-09-10 the two had already drifted: the product lowercases
before comparing (`AXLogicProElements+Mixer.swift`), the probe trimmed whitespace only. The label set
spells the mixer `"mixer"`; Logic answers `AXDescription` with `"Mixer"`. The probe's mixer match
could therefore never succeed on an English Logic, and only a locale without case distinction
(`믹서`) passed — which is why the harness driving it was written against a Korean fixture and nobody
noticed for as long as nobody ran it in English.

A comment saying "keep these in sync" was not enough, so this is a check instead.

WHAT IT ENFORCES
----------------
1. The probe folds case when comparing against policy vocabulary, and does it in ONE place, so a
   caller cannot normalise one side and forget the other.
2. No policy label set contains two labels differing only by case. That is the property that makes
   folding safe: it can never merge two distinct members of one set.
3. User-supplied identifiers are NOT folded. A track called `Bass` must not match one called `bass`,
   so the exact comparisons that carry user data are listed here by name and required to stay exact.

    python3 Scripts/check-probe-label-matching.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = os.path.join(ROOT, "Scripts/livekit/ax_plugin_menu_probe.swift")
POLICY = os.path.join(ROOT, "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift")
PRODUCT = os.path.join(ROOT, "Sources/LogicProMCP/Accessibility/AXLogicProElements+Mixer.swift")

# Comparisons that carry the USER's data rather than policy vocabulary. These must stay exact, and
# they are named so that adding one is a deliberate act rather than a side effect.
EXACT_BY_DESIGN = [
    "titleText($0) == expectedTitle",          # a window the caller named
    'descriptionText($0) == name',             # a group the caller named
    "descriptionText(strip)) == target",       # a track the caller named
    'descriptionText($0) == "EQ"',             # a literal role marker, not vocabulary
]

problems = []


def read(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as exc:
        problems.append(f"cannot read {os.path.relpath(path, ROOT)}: {exc}")
        return ""


probe = read(PROBE)
policy = read(POLICY)
product = read(PRODUCT)

# 1. The product's rule is what the probe must mirror. If the product stops lowercasing, this check
#    is describing a rule that no longer exists and must be revisited rather than silently kept.
# Anchored on the SPECIFIC comparison, not on any occurrence of `.lowercased()` in the file. A
# mutation test showed the loose form: the file has several, so deleting the load-bearing one left
# the check green.
PRODUCT_RULE = re.compile(
    r"trimmingCharacters\(in:\s*\.whitespacesAndNewlines\)\.lowercased\(\)[\s\S]{0,200}?"
    r"AXLocalePolicy\.mixerNamedElement\.labels\.contains"
)
if product and not PRODUCT_RULE.search(product):
    problems.append(
        "AXLogicProElements+Mixer.swift no longer trims-then-lowercases before comparing against "
        "AXLocalePolicy.mixerNamedElement — the rule this probe mirrors has changed, so update both "
        "and this check together"
    )

# 2. The probe folds, in one place.
if probe:
    if not re.search(r"func normalizedPolicyLabel\s*\(", probe):
        problems.append("the probe has no normalizedPolicyLabel(): the folding rule has no single home")
    elif not re.search(r"func normalizedPolicyLabel\([^)]*\)\s*->\s*String\s*\{\s*\n\s*trimmed\([^)]*\)\.lowercased\(\)",
                       probe):
        problems.append(
            "normalizedPolicyLabel() no longer trims-then-lowercases; it must mirror the product's rule"
        )
    if not re.search(r"func matchesPolicyLabel\s*\(", probe):
        problems.append("the probe has no matchesPolicyLabel(): callers can fold one side and not the other")

    # 3. No bare == against a policy label, except the user-data comparisons named above.
    for line_number, line in enumerate(probe.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("///"):
            continue
        # Two spellings of the same mistake: `label == observed`, and `labels.contains(observed)`.
        # A mutation test caught the second slipping through when only the first was checked.
        bare_equality = re.search(r"(descriptionText|titleText|elementName)\([^)]*\)\s*==", line)
        bare_contains = re.search(r"\.contains\(\s*(descriptionText|titleText|elementName)\(", line)
        if not bare_equality and not bare_contains:
            continue
        if any(allowed in line for allowed in EXACT_BY_DESIGN):
            continue
        problems.append(
            f"ax_plugin_menu_probe.swift:{line_number}: a policy label compared without folding (bare `==` or `.contains`). "
            f"Use matchesPolicyLabel(), or add it to EXACT_BY_DESIGN if it carries user data: {stripped[:90]}"
        )

# 4. Folding is only safe while no set has case-only duplicates.
if policy:
    sets = re.findall(
        r'static let (\w+)\s*=\s*LabelSet\(\s*canonical:\s*"([^"]*)"\s*,\s*variants:\s*\[([^\]]*)\]',
        policy, re.S)
    if not sets:
        problems.append("no LabelSet declarations parsed from AXLocalePolicy.swift — this check went blind")
    for name, canonical, variants in sets:
        labels = [canonical] + re.findall(r'"((?:[^"\\]|\\.)*)"', variants)
        folded = {}
        for label in labels:
            key = label.strip().lower()
            if key in folded and folded[key] != label:
                problems.append(
                    f"AXLocalePolicy.{name}: {folded[key]!r} and {label!r} differ only by case, so "
                    f"case-folded matching would merge two distinct members"
                )
            folded[key] = label

if problems:
    print(f"{len(problems)} probe/policy label-matching problem(s):")
    for problem in problems:
        print(f"  {problem}")
    print("\nThe probe restates a rule the product owns. These must not drift.")
    sys.exit(1)

print("probe label matching mirrors the product, in one place, and folding is safe")
