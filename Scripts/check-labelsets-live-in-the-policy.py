#!/usr/bin/env python3
"""A LabelSet built from string LITERALS must be declared in `AXLocalePolicy.swift`, not elsewhere.

`docs/locale/ui-labels.json` is generated from that one file. A LabelSet declared anywhere else
matches exactly the same at runtime and is invisible to everything that counts: the coverage
census, the variant ratchets, `undocumented_variants`, and every number this repository publishes
about how many of the ten languages Logic ships it can reach.

The failure this closes was silent for as long as it existed. `showLibraryMenuItem` sat inline in
`AccessibilityChannel+Library.swift` carrying `Show Library` and two Korean spellings, while
`check-policy-literals-against-canon.py` -- which sweeps the TREE rather than the policy file --
classified `Show Library` as `nowhere` the whole time. Two checks disagreed about whether that
label existed, and the quiet one was the ledger.

Building a LabelSet from VARIABLES is a different thing and stays allowed: `MainEntrypoint` wraps a
probe argument, `SemanticSelector` wraps a caller's predicate, `AtlasCapture` wraps a scope name.
Those carry no vocabulary -- they are a shape the matcher takes, and there is nothing for a ledger
to count. What is refused is a literal: a string somebody typed as a thing Logic says.
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
#: A seam, so the self-test can drive main() -- the ENTRY POINT -- at a tree that must
#: fail. Without one every case reaches the helpers only, and a `main()` returning 0
#: unconditionally stays green; Scripts/mutation-sweep-guard-tests.py measured that for
#: this guard on 2026-09-18.
POLICY = os.environ.get("LPM_POLICY_SWIFT") or os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
ROOTS = tuple(os.environ["LPM_POLICY_ROOTS"].split(os.pathsep)) if os.environ.get("LPM_POLICY_ROOTS") else (os.path.join(REPO, "Sources"),)

_CALL = re.compile(r"LabelSet\(")
#: How far past the opening token to look for a literal. A declaration's `canonical:` and
#: `variants:` are the next two fields in every shape this file uses; the window is generous
#: enough to cross a line break and a comment and short enough not to reach the NEXT call.
_WINDOW = 400
_LITERAL_CANONICAL = re.compile(r'canonical:\s*"')
_LITERAL_VARIANT = re.compile(r'variants:\s*\[\s*"')


def offenders(root: str, policy: str) -> list:
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".build"]
        for name in sorted(filenames):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            if os.path.abspath(path) == os.path.abspath(policy):
                continue
            with open(path, encoding="utf-8", errors="replace") as handle:
                source = handle.read()
            for match in _CALL.finditer(source):
                window = source[match.start():match.start() + _WINDOW]
                if _LITERAL_CANONICAL.search(window) or _LITERAL_VARIANT.search(window):
                    line = source[:match.start()].count("\n") + 1
                    found.append((os.path.relpath(path, REPO), line))
    return found


def main() -> int:
    if not os.path.exists(POLICY):
        print(f"{os.path.relpath(POLICY, REPO)} is missing, so this guard has no policy to compare "
              f"against and cannot answer.", file=sys.stderr)
        return 2
    found = []
    for root in ROOTS:
        found.extend(offenders(root, POLICY))
    if found:
        print(f"{len(found)} LabelSet(s) built from literals outside the policy file:",
              file=sys.stderr)
        for path, line in found:
            print(f"  {path}:{line}", file=sys.stderr)
        print(f"\n  Move the declaration into "
              f"{os.path.relpath(POLICY, REPO)}. `docs/locale/ui-labels.json` is generated from "
              f"that file alone, so a LabelSet declared anywhere else is counted by nothing -- not "
              f"its coverage, not its variants, not how many languages it reaches -- while its "
              f"literals are classified all the same. Wrapping a VARIABLE is still fine; it "
              f"carries no vocabulary.", file=sys.stderr)
        return 1
    print("every LabelSet built from literals is declared in AXLocalePolicy.swift, where the "
          "ledger can count it")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
