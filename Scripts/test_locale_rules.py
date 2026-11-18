#!/usr/bin/env python3
"""The rules a locale campaign applies without a person, each pinned by a case and a mutant.

    census areas         a census row is filed by the AREA its path passes through, and the area names
                         are Apple's strings per locale (docs/locale/census-areas.json), not typed
    role derivation      a label whose name cannot say what element it addresses declares the AX role of
                         the elements whose WHOLE text is its string -- the main window before the menus
    role narrowing       a containment label is read only on the roles it declares, and a role that only
                         a substring ever reached is dropped (ja-JP `パン` and `クイックパンチインを許可`)
    the one rule         a CHANGED reading or a NEW VARIANT is taken only where the live string EXACTLY
                         equals the label's own canon value; everything else is a recorded HOLD
    promotion            a `derived` cell the census sighted becomes `measured`

Nothing here touches Logic. Each rule is shown with a MUTANT: the source with the line that enforces
it neutralised, run through the same scenario, which must then fail. A replacement that does not match
exactly once fails the suite.
"""
import importlib.util
import json
import sys
import tempfile
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
OBS = HERE / "observations"
ran, failures = [0], []


def case(name, condition, detail=""):
    ran[0] += 1
    if not condition:
        failures.append(f"{name}: {detail}")


def load(path, name, source=None):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    if source is None:
        spec.loader.exec_module(module)
    else:
        module.__file__ = str(path)
        exec(compile(source, str(path), "exec"), module.__dict__)
    return module


def mutated(path, old, new, name):
    source = Path(path).read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise SystemExit(f"mutant {name}: {old[:70]!r} occurs {source.count(old)} time(s), not once")
    return load(path, name, source.replace(old, new))


records = load(OBS / "locale_campaign_records.py", "rules_records")
areas = load(OBS / "census_areas.py", "rules_areas")
propose = load(OBS / "locale-propose.py", "rules_propose")
regen = load(OBS / "locale-regenerate.py", "rules_regen")
cvalue = load(OBS / "locale_canon_value.py", "rules_cvalue")
holds_mod = load(OBS / "locale_holds.py", "rules_holds")
SLIDER = {"surface": "arrange.window", "role": "AXSlider", "title": None, "help": None, "value": None,
          "identifier": None, "description": "パン",
          "path": "AXWindow[X - トラック]/AXGroup[ミキサー]/AXLayoutArea[ミキサー]/AXSlider[パン]"}
PUNCH = {"surface": "arrange.menus", "role": "AXMenuItem", "title": "クイックパンチインを許可",
         "description": None, "help": None, "value": None, "identifier": None,
         "path": "AXMenuBar/AXMenuBarItem[録音]/AXMenu/AXMenuItem[クイックパンチインを許可]"}


# ---------------------------------------------------------------------------------------------------
# 1. CENSUS AREAS
# ---------------------------------------------------------------------------------------------------
LOCALES = ("en-US", "ko-KR", "ja-JP", "de-DE", "es-ES", "fr-FR", "it-IT", "pt-BR", "zh-CN", "zh-TW")
EVIDENCE = REPO / "docs" / "observations" / "evidence"
CORE = ("tracks", "control_bar", "mixer", "event", "inspector", "header", "contents", "legend", "time_ruler")


def newest_census(locale):
    found = sorted(EVIDENCE.glob(f"2026-11-1*-{locale}-navigation-free.census.json"))
    return json.loads(found[-1].read_text(encoding="utf-8")) if found else None


def segments(row):
    return set(records._segments(row["path"]))


per_locale = {}
for loc in LOCALES:
    census = newest_census(loc)
    case(f"{loc}: a Logic 13.0 census is committed", census is not None)
    if census is None:
        continue
    table = areas.names(loc)
    named = {a: [records._fold(n) for n in names] for a, names in table.items()}
    seen = set()
    for row in census["census"]:
        seen |= segments(row)
    for area in CORE:
        # The probe cuts a description to 28 characters, so a long name is compared on its first 28.
        ok = any(n[:records.PROBE_NAME_LIMIT] in seen for n in named.get(area, ()))
        case(f"{loc}: the derived name of `{area}` is a segment of its own census", ok,
             f"{named.get(area)} not in the census paths")
    counts = {}
    for row in census["census"]:
        s = records.classify(row, loc)
        if s is None:
            s = "window-level" if records.is_window_frame(row) else "UNPLACED"
        counts[s] = counts.get(s, 0) + 1
    per_locale[loc] = counts
    case(f"{loc}: no row a rule should place is left unplaced", counts.get("UNPLACED", 0) == 0,
         f"{counts.get('UNPLACED')} unplaced")
    case(f"{loc}: the control bar, mixer, tracks and event list are all filed",
         all(counts.get(k, 0) > 0 for k in ("arrange.transport", "mixer.channel_strips",
                                             "arrange.track_headers", "arrange.regions",
                                             "editor.event_list")), counts)

# The tree has one SHAPE in every locale: the same surfaces hold the same number of rows (to within the
# few elements a locale's fixture state or string length adds), which is what makes the locales' records
# comparable and is the property the hand-typed markers could not give.
for surface in ("arrange.transport", "arrange.track_headers", "mixer.channel_strips", "editor.event_list"):
    values = {loc: per_locale[loc].get(surface, 0) for loc in per_locale}
    spread = max(values.values()) - min(values.values())
    case(f"{surface} holds nearly the same rows in all ten locales", spread <= 12, values)

# Six locales were left with 526 to 537 unfiled rows.
for loc in ("es-ES", "fr-FR", "zh-CN", "zh-TW", "it-IT", "pt-BR"):
    if loc in per_locale:
        case(f"{loc}: far fewer than the 526 rows the hand-typed markers left unfiled",
             per_locale[loc].get("UNPLACED", 0) + per_locale[loc].get("window-level", 0) <= 12,
             per_locale[loc])

# MUTANT: the Tracks header/legend rule neutralised -> es-ES track-header rows are no longer filed there.
m = mutated(OBS / "locale_campaign_records.py",
            '    ("arrange.track_headers", ("header", "legend")),\n',
            '    ("arrange.track_headers", ("header_never",)),\n', "mut_area_header")
census = newest_census("es-ES")
good = sum(1 for r in census["census"] if records.classify(r, "es-ES") == "arrange.track_headers")
bad = sum(1 for r in census["census"] if m.classify(r, "es-ES") == "arrange.track_headers")
case("MUTANT: without the header rule es-ES files no track-header rows", good > 0 and bad == 0, (good, bad))

# A name from the wrong locale files nothing: German names do not place a Spanish tree.
case("an es-ES row is not placed by German area names",
     records.classify(next(r for r in census["census"] if "Mezclador" in r["path"]), "de-DE") != "mixer.channel_strips")

# PORTUGUESE draws the control bar from `Control Bar#acc` (`Barra de Controle`), not from the tab label.
pt = newest_census("pt-BR")
if pt:
    case("pt-BR: `Barra de Controle` (the #acc row) is a derived name of its control bar",
         "Barra de Controle" in areas.names("pt-BR")["control_bar"], areas.names("pt-BR")["control_bar"])


# ---------------------------------------------------------------------------------------------------
# 2. ROLE DERIVATION
# ---------------------------------------------------------------------------------------------------
entry = {"canonical": "pan", "variants": ["パン"], "match": "contains"}
case("derive_roles: the whole-text element wins over a substring hit",
     propose.derive_roles(entry, [PUNCH, SLIDER]) == (["AXSlider"], "window"),
     propose.derive_roles(entry, [PUNCH, SLIDER]))
case("derive_roles: a substring is not evidence", propose.derive_roles(entry, [PUNCH]) is None)
menu_only = dict(PUNCH, title="パン")
case("derive_roles: the menus decide only when no window element carries the string whole",
     propose.derive_roles(entry, [menu_only]) == (["AXMenuItem"], "menus"))
m = mutated(OBS / "locale-propose.py",
            "if any(text.casefold().strip() in wanted for _attr, text in strings_of(row)):",
            "if any(w in text.casefold() for w in wanted for _attr, text in strings_of(row)):",
            "mut_derive_substring")
case("MUTANT: derivation by substring takes the punch-in menu item as evidence",
     m.derive_roles(entry, [PUNCH]) is not None)


def ledger(tmp, labels):
    path = Path(tmp) / "ui-labels.json"
    path.write_text(json.dumps({"schema": 3, "labels": labels}, ensure_ascii=False), encoding="utf-8")
    return str(path)


with tempfile.TemporaryDirectory() as tmp:
    census = {"census": [PUNCH, SLIDER], "host": {"locale": "ja-JP"}}
    path = ledger(tmp, {
        "sliderPanHint": {"canonical": "pan", "variants": ["パン"], "match": "contains",
                          "roles": ["AXMenuItem", "AXSlider"],
                          "provenance": {"パン": {"locale": "ja-JP", "role": "AXMenuItem", "record": "r",
                                                 "observed": "同じパンナータイプの"}}},
        "keeps": {"canonical": "pan", "variants": ["パン"], "match": "contains", "roles": ["AXButton"]},
        "fooHint": {"canonical": "パン", "variants": [], "match": "contains"}})
    declared, undeclared = propose.declare_roles(path, census, "ja-JP")
    after = json.loads(Path(path).read_text(encoding="utf-8"))["labels"]
    case("declare_roles writes the observed role", after["fooHint"].get("roles") == ["AXSlider"], after["fooHint"])
    case("declare_roles never overwrites a declaration", after["keeps"]["roles"] == ["AXButton"])
    narrowed = propose.narrow_roles(path, census, "ja-JP")
    after = json.loads(Path(path).read_text(encoding="utf-8"))["labels"]["sliderPanHint"]
    case("narrow_roles drops the role only a substring reached", after["roles"] == ["AXSlider"], after["roles"])
    case("narrow_roles removes the reading that rested on the dropped role", "provenance" not in after, after)
    case("narrow_roles says what it moved", narrowed["sliderPanHint"]["dropped"] == ["AXMenuItem"], narrowed)
    again = propose.narrow_roles(path, census, "ja-JP")
    case("narrow_roles is idempotent", again == {}, again)

    # An EXACT label is never narrowed: equality is its own evidence.
    path2 = ledger(tmp, {"exactLabel": {"canonical": "パン", "variants": [], "match": "exact",
                                        "roles": ["AXMenuItem", "AXSlider"]}})
    case("narrow_roles leaves an exact label alone", propose.narrow_roles(path2, census, "ja-JP") == {})

    # sliderPanHint, end to end through `main`: with the declared role the Record-menu item is not a hit.
    path3 = ledger(tmp, {"sliderPanHint": {"canonical": "pan", "variants": ["パン"], "match": "contains",
                                           "roles": ["AXSlider"]}})
    cpath = Path(tmp) / "census.json"
    cpath.write_text(json.dumps({"census": [PUNCH, SLIDER],
                                 "host": {"app": "Logic Pro", "version": "98.7", "build": "65432",
                                          "locale": "ja-JP", "os": "x"}}, ensure_ascii=False), encoding="utf-8")
    _loc, _host, hits, _un = propose.main(str(cpath), path3)
    observed = sorted({h["observed"] for h in hits.get("sliderPanHint", [])})
    case("REGRESSION sliderPanHint is read from the pan slider, not the Quick Punch-In menu item",
         observed == ["パン"], observed)
    roles_hit = {h["role"] for h in hits.get("sliderPanHint", [])}
    case("REGRESSION ...and only on its declared role", roles_hit == {"AXSlider"}, roles_hit)
    m = mutated(OBS / "locale-propose.py",
                '        if allowed is None and entry.get("roles"):\n            allowed = set(entry["roles"])\n',
                '', "mut_declared_roles_ignored")
    _l, _h, bad_hits, _u = m.main(str(cpath), path3)
    case("MUTANT: ignoring declared roles reads the pan label off the Record menu again",
         "クイックパンチインを許可" in {h["observed"] for h in bad_hits.get("sliderPanHint", [])},
         sorted({h["observed"] for h in bad_hits.get("sliderPanHint", [])}))


# ---------------------------------------------------------------------------------------------------
# 3. THE ONE RULE: exact equality with the label's own canon value
# ---------------------------------------------------------------------------------------------------
class StubCorpus:
    def __init__(self, table):
        self.table = table

    def values_for(self, label, locale):
        found = self.table.get((label, locale))
        return (set(found), "") if found else (set(), "the label names no canon row (no derivedFrom) to compare against")


corpus = StubCorpus({("sliderPanHint", "ja-JP"): {"パン"}, ("playLabel", "ja-JP"): {"再生"}})
case("verdict ACCEPT: the live string is exactly the canon value",
     cvalue.verdict(corpus, "playLabel", "ja-JP", "再生")[0] == "ACCEPT")
v = cvalue.verdict(corpus, "sliderPanHint", "ja-JP", "クイックパンチインを許可")
case("verdict HOLD: a containment hit on another menu item is not the canon value",
     v[0] == "HOLD" and "パン" in v[1], v)
case("verdict HOLD: a label with no canon row has nothing to be equal to",
     cvalue.verdict(corpus, "orphan", "ja-JP", "x")[0] == "HOLD")
case("verdict HOLD: nothing live", cvalue.verdict(corpus, "playLabel", "ja-JP", "")[0] == "HOLD")
case("verdict HOLD: equality is exact, not up to a trailing space",
     cvalue.verdict(corpus, "playLabel", "ja-JP", "再生 ")[0] == "HOLD")
m = mutated(OBS / "locale_canon_value.py", "    if live in values:\n", "    if any(v in live for v in values):\n",
            "mut_canon_contains")
case("MUTANT: containment would accept the Quick Punch-In menu item as the pan label",
     m.verdict(corpus, "sliderPanHint", "ja-JP", "クイックパンチインを許可")[0] == "ACCEPT")

plan = {"changed": [{"label": "sliderPanHint", "was": "x", "now": "クイックパンチインを許可"},
                    {"label": "playLabel", "was": "x", "now": "再生"}]}
new_variants = {"playLabel": {"base": "Play", "target": "再生"},
                "sliderPanHint": {"base": "pan", "target": "ラベル"}}
take_changed, take_new, holds = regen.rule_only(cvalue, corpus, "ja-JP", plan, new_variants)
case("rule_only takes exactly the exact matches",
     take_changed == ["playLabel"] and take_new == ["playLabel"], (take_changed, take_new))
case("rule_only holds the rest with a reason",
     set(holds["changed"]) == {"sliderPanHint"} and set(holds["new_variant"]) == {"sliderPanHint"}
     and all(h["reason"] for kind in holds.values() for h in kind.values()), holds)
m = mutated(OBS / "locale-regenerate.py", '        if verdict == "ACCEPT":\n            take_new.append(name)',
            '        if True:\n            take_new.append(name)', "mut_rule_only_takes_all")
_c, mut_new, _h = m.rule_only(cvalue, corpus, "ja-JP", plan, new_variants)
case("MUTANT: taking every candidate accepts the unmatched one", "sliderPanHint" in mut_new, mut_new)


class OtherBuild:
    DEFAULT_APP = "/nonexistent"
    TRANSLATION_NAMESPACE = {}

    @staticmethod
    def load_manifest():
        return {"logic": {"version": "98.7", "build": "65432"}, "sources": {}}

    @staticmethod
    def app_build(_app):
        return {"version": "12.3", "build": "6674"}


try:
    cvalue.Corpus(REPO, canon=OtherBuild, derived=types.SimpleNamespace(derivations=lambda _s: []), swift_text="")
    refused = False
except cvalue.CorpusUnavailable:
    refused = True
case("a Corpus refuses an installed Logic that is not the pinned build", refused)


# ---------------------------------------------------------------------------------------------------
# 4. THE HOLD REPORT
# ---------------------------------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    holds_mod.record(tmp, "ja-JP", {"changed": {"b": {"reason": "r"}, "a": {"reason": "r"}}},
                     {"x": {"roles": ["AXButton"]}})
    holds_mod.record(tmp, "de-DE", {"new_variant": {"c": {"reason": "r"}}})
    holds_mod.record(tmp, "ja-JP", {"changed": {"a": {"reason": "r2"}}})
    doc = json.loads(Path(tmp, "docs/locale/holds.json").read_text(encoding="utf-8"))
    case("a re-run REPLACES the locale's section", list(doc["holds"]["ja-JP"]["changed"]) == ["a"], doc["holds"])
    case("another locale's section is untouched", "c" in doc["holds"]["de-DE"]["new_variant"])
    case("declared roles accumulate", doc["roles"]["x"]["roles"] == ["AXButton"])
    holds_mod.record(tmp, "ja-JP", {})
    doc = json.loads(Path(tmp, "docs/locale/holds.json").read_text(encoding="utf-8"))
    case("a locale with nothing held has no section", "ja-JP" not in doc["holds"])
    try:
        holds_mod.record(tmp, "ja-JP", {"nonsense": {"a": 1}})
        bad = False
    except ValueError:
        bad = True
    case("an unknown hold kind is refused", bad)


# ---------------------------------------------------------------------------------------------------
# 5. A SIGHTED DERIVED CELL BECOMES MEASURED
# ---------------------------------------------------------------------------------------------------
def promoted(module):
    """Run `apply` on a copy of the real ledger in which one sighted label is `derived`; return its cell."""
    real = json.loads((REPO / "docs/locale/ui-labels.json").read_text(encoding="utf-8"))
    name = next(n for n, e in sorted(real["labels"].items())
                if (e.get("coverage") or {}).get("en-US") == "measured" and e.get("coverage_records", {}).get("en-US")
                and not any(b.get("locale") == "en-US" for b in (e.get("provenance") or {}).values()))
    entry = real["labels"][name]
    entry["coverage"]["en-US"] = "derived"
    for key in [k for k in entry if k.startswith("coverage_") and k != "coverage_derived"]:
        (entry[key] or {}).pop("en-US", None)
    entry["coverage_derived"] = {"en-US": "strings:en:ships_up_to_case:x"}
    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / "ui-labels.json"
        copy.write_text(json.dumps(real, ensure_ascii=False), encoding="utf-8")
        census_path = EVIDENCE / "2026-11-18-en-US-navigation-free.census.json"
        _loc, _host, found, _un = module.main(str(census_path), str(copy))
        census_doc = json.loads(census_path.read_text(encoding="utf-8"))
        by_surface = {}
        for rec in (REPO / "docs/observations").glob("2026-11-18-en-US-*-census.json"):
            d = json.loads(rec.read_text(encoding="utf-8"))
            by_surface[d["surface"]] = d["id"]
        module.apply(str(copy), census_doc, {name: found[name]}, by_surface)
        return name, json.loads(copy.read_text(encoding="utf-8"))["labels"][name]["coverage"]["en-US"]


label_name, cell = promoted(propose)
case(f"apply promotes a sighted `derived` cell to `measured` ({label_name})", cell == "measured", cell)
m = mutated(OBS / "locale-propose.py", 'if cov.get(locale) in ("unmeasured", "derived"):',
            'if cov.get(locale) == "unmeasured":', "mut_derived_not_promoted")
_name, cell = promoted(m)
case("MUTANT: promoting only `unmeasured` leaves the sighted cell `derived`", cell == "derived", cell)

if failures:
    for line in failures:
        print(f"FAIL {line}")
    sys.exit(1)
print(f"{ran[0]} case(s) pass: census areas are Apple's names, roles come from the census, and an unattended "
      f"run takes only an exact canon match")
