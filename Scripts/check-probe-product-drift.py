#!/usr/bin/env python3
"""The AX probe restates rules the product owns. This fails when they can drift.

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

TWO RESTATED RULES, NOT ONE
---------------------------
This began as a label-matching check and was widened on 2026-09-11, when a SECOND restated rule was
found to have drifted the same way: the probe decided what counts as a Controls-view control with a
three-role literal while the product's `interactiveControlRoles` names eleven. The missing
`AXCheckBox` is the only Controls-view role this repository has ever actuated, so the census was
blind to the one working path and reported a checkbox row as having no control at all.

A separate guard file for the role rule was rejected in favour of widening this one: the PROPERTY is
"the probe restates product rules", and a guard per instance is how the second one went unwatched
while the first was covered. The file was named `check-probe-label-matching.py` until that day.

Deriving the role set from one shared place was rejected too, and not on taste: the probe runs
outside the product and cannot import it, which #846's own record already settled. The rule is
necessarily restated; this is what keeps the two spellings together.

WHAT IT ENFORCES
----------------
1. The probe folds case when comparing against policy vocabulary, and does it in ONE place, so a
   caller cannot normalise one side and forget the other.
2. No policy label set contains two labels differing only by case. That is the property that makes
   folding safe: it can never merge two distinct members of one set.
3. The probe's Controls-view control-role set is exactly the product's, and the census reads it
   from one named constant rather than an inline literal.
4. User-supplied identifiers are NOT folded. A track called `Bass` must not match one called `bass`,
   so the exact comparisons that carry user data are listed here by name and required to stay exact.

    python3 Scripts/check-probe-product-drift.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = os.path.join(ROOT, "Scripts/livekit/ax_plugin_menu_probe.swift")
POLICY = os.path.join(ROOT, "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift")
PRODUCT = os.path.join(ROOT, "Sources/LogicProMCP/Accessibility/AXLogicProElements+Mixer.swift")
WRITER = os.path.join(ROOT, "Sources/LogicProMCP/HostParameters/ControlsViewBooleanParameterWriter.swift")

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
writer = read(WRITER)

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


# 5. The probe's Controls-view control roles are the product's, spelled out in one place.
#
# The probe cannot import the product -- that is settled, and it is why the label rule above is
# restated rather than shared. So this compares the two SPELLINGS and requires them equal. A
# superset is not accepted either: a probe that recognises a role the product refuses would report a
# control the product will not touch, which is the same lie pointing the other way.
def _roles_from_swift_set(text, declaration):
    """Every role name in a Swift Set<String> literal, whether written as a kAX… constant or a string."""
    # `declaration` must anchor past the NAME -- callers pass a trailing `\s*:` -- or a renamed set
    # matches as a prefix and this parses the very declaration the rename removed.
    match = re.search(declaration + r"[^=]*=\s*\[(.*?)\n\s*\]", text, re.S)
    if match is None:
        return None
    body = match.group(1)
    # `kAXCheckBoxRole as String` and `"AXCheckBox"` name the same role; compare the role, not the
    # spelling, or this check would fail on a difference that is only notation.
    roles = {f"AX{name}" for name in re.findall(r"kAX(\w+)Role", body)}
    roles |= set(re.findall(r'"(AX\w+)"', body))
    return roles

product_roles = _roles_from_swift_set(writer, r"interactiveControlRoles\s*:") if writer else None
probe_roles = _roles_from_swift_set(probe, r"let controlsViewControlRoles\s*:") if probe else None

if writer and product_roles is None:
    problems.append(
        "ControlsViewBooleanParameterWriter.interactiveControlRoles could not be parsed — this check "
        "went blind rather than passing"
    )
if probe and probe_roles is None:
    problems.append(
        "the probe has no controlsViewControlRoles set: the Controls-view role rule has no single "
        "home, so a census can inline its own list again"
    )
if product_roles and probe_roles is not None and product_roles != probe_roles:
    missing = sorted(product_roles - probe_roles)
    extra = sorted(probe_roles - product_roles)
    detail = []
    if missing:
        detail.append(f"the probe cannot see {', '.join(missing)}")
    if extra:
        detail.append(f"the probe accepts {', '.join(extra)}, which the product does not")
    problems.append(
        "the probe's Controls-view control roles and the product's interactiveControlRoles differ: "
        + "; ".join(detail)
    )

# The census must READ that constant. Without this, the set can be correct and unused -- which is
# exactly the state the role defect was in, with a literal list inline at the call site.
if probe and not re.search(r"controlsViewControlRoles\.contains\(roleText\(", probe):
    problems.append(
        "rowCensus does not filter with controlsViewControlRoles: the named set is not what decides, "
        "so it can be right and have no effect"
    )

if problems:
    print(f"{len(problems)} probe/product drift problem(s):")
    for problem in problems:
        print(f"  {problem}")
    print("\nThe probe restates rules the product owns. These must not drift.")
    sys.exit(1)

print("probe label matching and Controls-view roles mirror the product, each in one place, and folding is safe")
