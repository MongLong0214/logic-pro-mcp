#!/usr/bin/env python3
"""Cases for `check-locale-labels-json.py` — the projection must match the Swift, and a variant is
a claim that Logic spells something that way.

The four controls that were run by hand when the rule was written. The fourth is the one that
matters: a variant added to the policy with no reading behind it has to fail, because "the variants
list grows when a locale is actually observed, not when one is translated" was a comment in
`AXLocalePolicy` for months and a comment does not fail.

The cases build documents in memory rather than touching `docs/locale/ui-labels.json`, so a failing
case cannot leave the repository's own projection wrong.
"""
import copy
import importlib.util
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(REPO, "Scripts", filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


G = load("locale_labels_guard", "check-locale-labels-json.py")
L = load("locale_labels", "locale_labels.py")

failed = 0


def case(name, condition, detail):
    global failed
    failed += 0 if condition else 1
    print(f"{'ok  ' if condition else 'FAIL'} {name} -> {detail}")


live = L.load_json()

# 1. The projection agrees with the Swift as committed, or nothing below means anything.
case("the committed projection agrees with AXLocalePolicy",
     (live.get("labels") or {}) == L.build(existing=live)["labels"],
     f"{len(live.get('labels') or {})} labels")

# 2. The counters are what the floor is measured against.
total, documented = G.counts(live)
case("the floor equals the tree's undocumented variant count",
     total - documented == G.UNDOCUMENTED_VARIANT_FLOOR,
     f"{documented} of {total} documented, floor={G.UNDOCUMENTED_VARIANT_FLOOR}")

# 3. A variant arriving with no `measured` block raises the count above the floor. This is the
#    case the rule exists for: a translated string is not a measured one.
drifted = copy.deepcopy(live)
some_label = next(iter(drifted["labels"]))
drifted["labels"][some_label].setdefault("variants", []).append("キャンセル")
t2, d2 = G.counts(drifted)
case("a variant with no reading behind it raises the count above the floor",
     t2 - d2 == G.UNDOCUMENTED_VARIANT_FLOOR + 1, f"{t2 - d2} undocumented")

# 4. And the ratchet bites the other way: adding provenance without lowering the floor is also an
#    error, or the next regression is free to fall back to the old number.
improved = copy.deepcopy(live)
label = next(n for n, e in improved["labels"].items()
             if e.get("variants") and not e.get("measured"))
improved["labels"][label]["measured"] = {
    improved["labels"][label]["variants"][0]: {"locale": "ko-KR", "date": "2026-09-04"}}
t3, d3 = G.counts(improved)
case("adding provenance drops the count below the floor, which is also reported",
     t3 - d3 == G.UNDOCUMENTED_VARIANT_FLOOR - 1, f"{t3 - d3} undocumented")

# 5. The export refuses to write a short projection. A label the parser cannot read would vanish
#    silently, and a missing label is the failure the projection exists to stop.
case("the exporter counts declarations and parses all of them",
     len(L.from_swift()) == len(live.get("labels") or {}),
     f"{len(L.from_swift())} parsed")

# 6. `localised_canonicals` is what `check-livekit-ui-literals.py` aims with, and a canonical of two
#    characters or fewer is excluded — `L` and `M` are Event List columns and would match anything.
canonicals = L.localised_canonicals(live)
case("short canonicals are excluded from the matching vocabulary",
     all(len(c) > 2 for c in canonicals), f"{len(canonicals)} canonicals, shortest="
     f"{min((len(c) for c in canonicals), default=0)}")

print()
print(f"FAILED ({failed} unexpected)" if failed else "all cases behaved (0 unexpected)")
sys.exit(1 if failed else 0)
