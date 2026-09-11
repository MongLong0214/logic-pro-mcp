#!/usr/bin/env python3
"""Drive check-probe-product-drift.py against the defects it names.

Each case injects one defect into a COPY of the tree and asserts the guard reports it, then asserts
the unmodified tree passes. Three of these cases exist because they were holes: the first version of
the guard missed them, and a mutation run found them rather than a reading did.

The last five cases arrived with the role clause on 2026-09-11. The defect that clause exists to
catch -- the probe's three-role literal against the product's eleven -- is the FIRST of them, written
as the tree actually stood, so the clause is shown catching the real thing and not only a synthetic
neighbour of it.

    python3 Scripts/test_probe_product_drift.py
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = "Scripts/check-probe-product-drift.py"
PROBE = "Scripts/livekit/ax_plugin_menu_probe.swift"
POLICY = "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift"
PRODUCT = "Sources/LogicProMCP/Accessibility/AXLogicProElements+Mixer.swift"
WRITER = "Sources/LogicProMCP/HostParameters/ControlsViewBooleanParameterWriter.swift"

# (name, file, find, replace, a phrase the report must contain)
CASES = [
    ("the fold is dropped — the original defect, restored",
     PROBE, "trimmed(text).lowercased()", "trimmed(text)",
     "no longer trims-then-lowercases"),
    ("a caller compares a label set with .contains instead of folding",
     PROBE,
     "matchesPolicyLabel(descriptionText($0), anyOf: viewLabels)",
     "viewLabels.contains(descriptionText($0))",
     "without folding"),
    ("a caller compares a single label with a bare ==",
     PROBE,
     "matchesPolicyLabel(descriptionText($0), anyOf: [openLabel])",
     "descriptionText($0) == openLabel",
     "without folding"),
    ("the shared helper is renamed away",
     PROBE, "func matchesPolicyLabel", "func matchesPolicyLabelRenamed",
     "no matchesPolicyLabel"),
    ("a label set gains a member differing only by case",
     POLICY,
     'canonical: "mixer",\n        variants: ["믹서"]',
     'canonical: "mixer",\n        variants: ["믹서", "Mixer"]',
     "differ only by case"),
    ("the product stops folding, so the rule the probe mirrors is gone",
     PRODUCT, ".whitespacesAndNewlines).lowercased()", ".whitespacesAndNewlines)",
     "no longer trims-then-lowercases before comparing"),
    # --- the role clause, added 2026-09-11 with #852 ---------------------------------------------
    ("the probe cannot see AXCheckBox — #852 exactly as it stood",
     PROBE, '    "AXCheckBox",\n    "AXSlider",', '    "AXSlider",',
     "the probe cannot see AXCheckBox"),
    ("the probe accepts a role the product refuses",
     PROBE, '    "AXScrollBar",\n]', '    "AXScrollBar",\n    "AXOutline",\n]',
     "the probe accepts AXOutline"),
    ("the product gains a role and the probe is not moved with it",
     WRITER, '        "AXScrollBar",\n    ]', '        "AXScrollBar",\n        "AXDisclosureTriangle",\n    ]',
     "the probe cannot see AXDisclosureTriangle"),
    ("the named set is right but the census inlines its own list",
     PROBE, "controlsViewControlRoles.contains(roleText($0))",
     '["AXSlider"].contains(roleText($0))',
     "the named set is not what decides"),
    ("the probe's role set is renamed away",
     PROBE, "let controlsViewControlRoles", "let controlsViewControlRolesRenamed",
     "no controlsViewControlRoles set"),
]


def run_guard(tree):
    return subprocess.run([sys.executable, os.path.join(tree, GUARD)],
                          capture_output=True, text=True, cwd=tree)


def main():
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        tree = os.path.join(tmp, "tree")
        # Only the files the guard reads; copying the repository would be slow and would drag in
        # build products the guard never looks at.
        for relative in (GUARD, PROBE, POLICY, PRODUCT, WRITER):
            destination = os.path.join(tree, relative)
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            shutil.copy(os.path.join(ROOT, relative), destination)

        clean = run_guard(tree)
        ok = clean.returncode == 0
        failed += 0 if ok else 1
        print(f"{'ok  ' if ok else 'FAIL'} the unmodified tree passes"
              + ("" if ok else f" -> {clean.stdout.strip()[:200]}"))

        for name, relative, find, replace, expected in CASES:
            path = os.path.join(tree, relative)
            original = open(path, encoding="utf-8").read()
            if original.count(find) < 1:
                failed += 1
                print(f"FAIL {name} -> anchor absent, the defect was NEVER INJECTED")
                continue
            open(path, "w", encoding="utf-8").write(original.replace(find, replace, 1))
            result = run_guard(tree)
            open(path, "w", encoding="utf-8").write(original)

            caught = result.returncode != 0 and expected in result.stdout
            failed += 0 if caught else 1
            if caught:
                print(f"ok   {name}")
            else:
                print(f"FAIL {name} -> rc={result.returncode}, expected {expected!r} in the report")

        restored = run_guard(tree)
        ok = restored.returncode == 0
        failed += 0 if ok else 1
        print(f"{'ok  ' if ok else 'FAIL'} the tree passes again after every restore")

    print(f"\n{'FAILED' if failed else 'all cases behaved'} ({failed} unexpected)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
