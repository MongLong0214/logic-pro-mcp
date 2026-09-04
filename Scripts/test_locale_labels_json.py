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

# 2. Two numbers, not one. The first shape tracked `total - documented`, and an outside review
#    showed it could be held level while both halves moved: add an undocumented variant AND
#    document a different one, and the difference is unchanged.
total, documented = G.counts(live)
case("the recorded ceiling and floor equal the tree",
     total == G.TOTAL_VARIANT_CEILING and documented == G.DOCUMENTED_VARIANT_FLOOR,
     f"{documented} of {total}, recorded {G.DOCUMENTED_VARIANT_FLOOR} of {G.TOTAL_VARIANT_CEILING}")

# 3. The defeat the review described, run as a case: it now raises the total past the ceiling.
drifted = copy.deepcopy(live)
a = next(n for n, e in drifted["labels"].items() if e.get("variants") and not e.get("measured"))
b = next(n for n, e in drifted["labels"].items()
         if e.get("variants") and not e.get("measured") and n != a)
drifted["labels"][a]["variants"].append("キャンセル")
drifted["labels"][b]["measured"] = {drifted["labels"][b]["variants"][0]:
                                    {"locale": "ko-KR", "date": "2026-09-04", "observed": "x"}}
t2, d2 = G.counts(drifted)
case("adding an undocumented variant while documenting another still fails",
     t2 > G.TOTAL_VARIANT_CEILING, f"total={t2} ceiling={G.TOTAL_VARIANT_CEILING}")

# 4. An EMPTY provenance object counted as documentation while only its length was read, so a
#    variant could be marked measured without anything having been measured.
hollow = copy.deepcopy(live)
c = next(n for n, e in hollow["labels"].items() if e.get("variants") and not e.get("measured"))
hollow["labels"][c]["measured"] = {hollow["labels"][c]["variants"][0]: {}}
case("an empty provenance block is not a reading",
     G.counts(hollow)[1] == documented, f"documented={G.counts(hollow)[1]}")

real = copy.deepcopy(live)
rv = real["labels"][c]["variants"][0]
real["labels"][c]["measured"] = {rv: {"locale": "ko-KR", "date": "2026-09-04",
                                      "observed": f"{rv} 를 이 화면에서 읽었다"}}
case("a block whose observed string contains the variant is a reading",
     G.counts(real)[1] == documented + 1, f"documented={G.counts(real)[1]}")

# 4b. Three non-empty strings are not a reading. A second review attached
#     `{"locale":"x","date":"x","observed":"x"}` to a fabricated variant and the totals did not
#     move; `observed` must now contain the variant it documents, and the date must be a date.
junk = copy.deepcopy(live)
jl = next(n for n, e in junk["labels"].items() if e.get("variants") and not e.get("measured"))
jv = junk["labels"][jl]["variants"][0]
junk["labels"][jl]["measured"] = {jv: {"locale": "x", "date": "x", "observed": "x"}}
case("junk strings are not a reading", G.counts(junk)[1] == documented, f"{G.counts(junk)[1]}")

junk["labels"][jl]["measured"] = {jv: {"locale": "ko-KR", "date": "2026-09-04",
                                       "observed": "nothing like it"}}
case("an observed string that does not contain the variant is not a reading",
     G.counts(junk)[1] == documented, f"{G.counts(junk)[1]}")

# 4c. A triple-quoted rationale was recorded as an empty string, so a destructive button's entire
#     justification vanished from the projection while both sides agreed on the wrong value.
case("no label carries an empty rationale",
     all((e.get("rationale") or "").strip() for e in live["labels"].values()),
     f"{sum(1 for e in live['labels'].values() if not (e.get('rationale') or '').strip())} empty")

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
