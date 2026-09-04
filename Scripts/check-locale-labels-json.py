#!/usr/bin/env python3
"""`docs/locale/ui-labels.json` must match the Swift, and measured provenance may only grow.

Two things, and the second is the one that changes behaviour over time.

**Agreement.** The JSON is a projection of `AXLocalePolicy.swift` for every reader that cannot
import Swift — the live harnesses, this repository's own guards, anything outside the build. A
projection nobody checks is just a fourth copy, and this repository already had three: the Swift,
the alias lists in `Scripts/livekit/evidence.py`, and inline literals in thirteen harnesses.
Regenerate with `Scripts/locale_labels.py --write`.

**The ratchet.** `AXLocalePolicy` says of its own variants list, in comment after comment, that it
"grows when a locale is actually observed, not when one is translated". That was prose, and prose
does not fail. `measured` makes it data: a variant may name the date it was read, the host, the
observation record, and the exact string. On 2026-09-04, 2 of 253 variants carried that. The
number without it may only go down — a new variant arriving with no reading behind it raises the
count and fails here.

The floor is deliberately not zero. Turning 251 undocumented variants red in one step is how a
guard gets deleted rather than satisfied; `evidence.py` records the same reasoning for
`visual_assertions_without_a_subject`, counted for a release before it was gated. A ratchet that
only moves one way gets there without a flag day.
"""
import importlib.util
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Measured 2026-09-04. Lower this when provenance is added; it may never rise.
UNDOCUMENTED_VARIANT_FLOOR = 251


def _module():
    spec = importlib.util.spec_from_file_location(
        "locale_labels", os.path.join(REPO, "Scripts", "locale_labels.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def counts(doc):
    total = sum(len(e.get("variants") or []) for e in (doc.get("labels") or {}).values())
    documented = sum(len(e.get("measured") or {}) for e in (doc.get("labels") or {}).values())
    return total, documented


def main():
    labels = _module()
    on_disk = labels.load_json()
    if not on_disk.get("labels"):
        print("docs/locale/ui-labels.json is missing or unreadable — run Scripts/locale_labels.py --write")
        return 1

    expected = labels.build(existing=on_disk)["labels"]
    if on_disk["labels"] != expected:
        only_json = sorted(set(on_disk["labels"]) - set(expected))
        only_swift = sorted(set(expected) - set(on_disk["labels"]))
        changed = sorted(n for n in set(expected) & set(on_disk["labels"])
                         if on_disk["labels"][n] != expected[n])
        print("docs/locale/ui-labels.json disagrees with AXLocalePolicy.swift:")
        for name in only_swift[:8]:
            print(f"  in Swift, absent from the JSON:  {name}")
        for name in only_json[:8]:
            print(f"  in the JSON, absent from Swift:  {name}")
        for name in changed[:8]:
            print(f"  differs:                         {name}")
        print("\n  Regenerate: Scripts/locale_labels.py --write")
        return 1

    total, documented = counts(on_disk)
    undocumented = total - documented
    if undocumented > UNDOCUMENTED_VARIANT_FLOOR:
        print(f"{undocumented} variants carry no measurement, above the floor of "
              f"{UNDOCUMENTED_VARIANT_FLOOR}.")
        print("  A variant is a claim that Logic spells something that way. Record where it was")
        print("  read — date, host, observation record, the string itself — under `measured`.")
        return 1
    if undocumented < UNDOCUMENTED_VARIANT_FLOOR:
        print(f"{undocumented} variants carry no measurement, below the floor of "
              f"{UNDOCUMENTED_VARIANT_FLOOR} — lower UNDOCUMENTED_VARIANT_FLOOR to {undocumented} "
              "so the next regression cannot fall back to the old number.")
        return 1

    print(f"{len(on_disk['labels'])} labels agree with the Swift; "
          f"{documented} of {total} variants carry a measurement")
    return 0


if __name__ == "__main__":
    sys.exit(main())
