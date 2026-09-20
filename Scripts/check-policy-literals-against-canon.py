#!/usr/bin/env python3
"""Count, by name, the strings this product matches Logic with that Logic does not ship.

`AXLocalePolicy` matches Logic's interface by comparing whole strings. Every one of those strings
was typed by somebody, and a typed string can be wrong in a way nothing sees: `再生ヘッド位置`
against Logic's `再生ヘッドの位置` made an element unfindable on every Japanese Logic while the
ledger counted it as coverage.

This is the counted version of that question. It does not fail on an unmatched literal -- it
cannot, and pretending otherwise would make it wrong far more often than right:

  * roughly half the unmatched literals are lowercase fragments for CONTAINMENT matching
    (`audio effect`, `track contents`, `stereo out`). They were never whole labels.
  * a label Logic composes at runtime is absent from every file and entirely correct.
  * the corpus is the app bundle's 2,537 `.strings` files. Strings compiled into nibs, into the
    binary, or into a framework outside the bundle are not in it, so `absent` means `not in this
    corpus`, never `not in Logic`.

## It runs in CI, which has no Logic

The first version returned 0 when Logic was absent -- which is every CI runner -- so the one guard
pointed at Swift was a no-op exactly where it needed to bite. The enforcement was inverted: adding
a wrong literal AND waiving it was caught, because the waiver ratchet runs offline; adding a wrong
literal and NOT waiving it was invisible. The honest author was blocked and the careless one went
green. Found by review 2026-09-15.

So the classification is COMMITTED. `docs/canon/POLICY-LITERALS.json` maps every literal to the
corpus that answers for it, and the offline check is set equality: the literals in the Swift must
be exactly the literals in the map. A literal nobody classified fails in CI, and classifying it
needs Logic -- which is the right place for that work and the wrong place for the gate. With Logic
present the map is re-derived and must agree.

## Scope

Every `LabelSet(` site under `Sources/` AND `Scripts/livekit/`, not just `AXLocalePolicy.swift`. Measured: 156 of 160
sites are in that file and the other four were invisible to this check, one of them declaring
`Show Library` and `라이브러리 보기` -- neither of which is in any corpus.

First run, 2026-09-15: 379 distinct literals, 113 a QuickHelp Title, 226 elsewhere in the corpus,
40 in no file of the bundle.

What those 40 are NOT, corrected after review: they are not forty typos. `AXLocalePolicy` carries
Apple's spelling as the CANONICAL member of each set -- `Project or Section…` with U+2026,
`Autopunch` as one word -- and matching is variant-inclusive, so the element is found. Four of the
40 are the tolerance VARIANTS beside those two canonicals (`Project or Section...`, its Korean
twin, `Auto Punch`, `Auto-Punch`), which Logic ships nowhere in this corpus and which cost nothing
to keep. An earlier version of this docstring called them "demonstrably wrong", which was an
overclaim of exactly the kind this axis exists to stop.

What the list is for is the distinction nothing could draw before: a tolerance variant and a typo
look identical in a `LabelSet`, and now one of them is named.
"""
import importlib.util
import functools
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "/Applications/Logic Pro.app"
CLASSIFICATION = os.path.join(REPO, "docs", "canon", "POLICY-LITERALS.json")
#: Both directories that hold Swift matching Logic's interface. `Scripts/livekit` was not scanned,
#: and five CJK literals live in those harnesses -- the same blind spot as reading only `LabelSet(`,
#: one directory over.
SWIFT_ROOTS = (os.path.join(REPO, "Sources"), os.path.join(REPO, "Scripts", "livekit"))

_spec = importlib.util.spec_from_file_location(
    "logic_canon_for_policy", os.path.join(REPO, "Scripts", "logic_canon.py"))
canon = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(canon)

#: `canonical:`, `variants: [...]`, and an OPTIONAL `locales: [...]` between them and `rationale:`.
#:
#: The `locales:` field does not exist on this branch yet -- #882 adds it, and its values are
#: labels the product TYPES into Logic's Key Commands filter (`"ko": "트랙 녹음 활성화 토글"`).
#: A pattern that stopped at `variants:` would have let a whole third field of Logic-facing strings
#: into the tree unseen, which is the blind spot this guard exists to be. Written now rather than
#: when that branch lands, because a gate learned about after the fact has already missed once.
#: Every character `fold_for_near_miss` removes, so a trailing one can be named.
_ALL_DECORATION = canon._DECORATION

_LABELSET = re.compile(
    r'LabelSet\(\s*canonical:\s*("(?:[^"\\]|\\.)*")\s*,'
    r'\s*variants:\s*\[(.*?)\]\s*,'
    r'(?:\s*locales:\s*\[(.*?)\]\s*,)?'
    # `rationale:` is OPTIONAL in this pattern, and it was required. A LabelSet written without one
    # compiles -- the initializer has no default, but a future one might, and a hand-written
    # `LabelSet(canonical:variants:)` in a test or a helper already does -- and it was invisible to
    # this scan. A guard that only sees the well-formed cases is a guard that misses the one
    # somebody wrote in a hurry.
    r'(?:\s*rationale:|\s*\))', re.S)
_STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
_LINE_COMMENT = re.compile(r"^\s*//.*$", re.M)
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)


def swift_sources(roots=None):
    for root in (roots or SWIFT_ROOTS):
        if not os.path.isdir(root):
            continue
        for base, _dirs, files in os.walk(root):
            for name in sorted(files):
                if name.endswith(".swift"):
                    yield os.path.join(base, name)


def policy_literals(source: str) -> set:
    """Every `canonical` and `variants` literal, with comments removed first.

    Only those two fields. A first version also swept `rationale`, which is documentation, and
    reported 185 unmatched -- most of them sentences. Comments are stripped because the pattern
    otherwise harvests a `LabelSet(` written inside a `//` line, and because the non-greedy
    bracket match can run past a site's own `]` into prose. Neither fires on the current tree;
    both were demonstrated on a fixture by review 2026-09-15.
    """
    text = _LINE_COMMENT.sub("", _BLOCK_COMMENT.sub(" ", source))
    out = set()
    for match in _LABELSET.finditer(text):
        found = _STRING.findall(match.group(1)) + _STRING.findall(match.group(2))
        if match.group(3):
            # `["ko": "…", "ja": "…"]` -- the VALUES are labels, the keys are locale codes. Taking
            # both would put `ko` and `ja` into the literal set and they would classify as nowhere,
            # which is true and useless.
            found += _STRING.findall(match.group(3))[1::2]
        for value in found:
            value = value.replace("\\u{00A0}", "\u00a0").replace('\\"', '"')
            if value.strip():
                out.add(canon.normalize(value))
    return out


#: A string literal carrying Hangul, kana or CJK ideographs. Outside a `LabelSet` that is a
#: localized interface label the product compares against Logic, and 74 of them were living there
#: unseen -- `재생`, `녹음`, `사이클`, `파일`, `편집`, `새로운 오디오 트랙` -- because every part of
#: this machinery read `LabelSet(` and nothing else. Measured 2026-09-15.
#:
#: CJK is the signal because it is reliable: a Korean or Japanese literal in this codebase is a
#: label read off Logic. The LIMIT, stated rather than hidden: a German or English label matched
#: the same way is indistinguishable from any other string in the file, so this finds the ones it
#: can and does not claim to find all of them.
#: `[^"\\\n]` on both sides meant any literal CONTAINING A BACKSLASH was skipped, and a Swift
#: unicode escape is a backslash: `"\\u{BBF9}서"` compiles to `믹서` and was invisible to this
#: harvester. An outside review used exactly that to put a hardcoded Korean label into the tree
#: with every guard green. Escapes are now part of the literal and are RESOLVED before
#: classification, so a label spelled in escapes is the same label.
_STRING_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
_CJK = re.compile(r'[\uac00-\ud7a3\u3040-\u309f\u30a0-\u30ff\u4e00-\u9fff]')
_SWIFT_UNICODE_ESCAPE = re.compile(r'\\u\{([0-9A-Fa-f]{1,8})\}')


def _resolve_escapes(raw: str) -> str:
    """A Swift literal's text, with `\\u{...}` resolved and the ordinary escapes unwrapped.

    A malformed or out-of-range scalar is left as written rather than raised: this runs over every
    string in the tree, and refusing to read one is not this rule's job.
    """
    def one(match):
        try:
            return chr(int(match.group(1), 16))
        except (ValueError, OverflowError):
            return match.group(0)
    text = _SWIFT_UNICODE_ESCAPE.sub(one, raw)
    for escape, literal in (("\\\\", "\\"), ('\\"', '"'), ("\\n", "\n"), ("\\t", "\t")):
        text = text.replace(escape, literal)
    return text


def bare_literals(source: str) -> set:
    """CJK string literals OUTSIDE any LabelSet, with comments removed first."""
    text = _LINE_COMMENT.sub("", _BLOCK_COMMENT.sub(" ", source))
    text = re.sub(r'LabelSet\(.*?\)\s*\n', " ", text, flags=re.S)
    out = set()
    for match in _STRING_LITERAL.finditer(text):
        resolved = _resolve_escapes(match.group(1))
        if resolved.strip() and _CJK.search(resolved):
            out.add(canon.normalize(resolved))
    return out


def all_policy_literals() -> set:
    out = set()
    for path in swift_sources():
        with open(path, "r", encoding="utf-8") as handle:
            source = handle.read()
        out |= policy_literals(source)
        out |= bare_literals(source)
    return out


DECORATION_RULES = os.path.join(REPO, "docs", "canon", "DECORATION-RULES.json")


def decoration_rules() -> dict:
    with open(DECORATION_RULES, "r", encoding="utf-8") as handle:
        return json.load(handle)


def kind_of(name: str, rules: dict) -> str:
    """Which kind of control a LabelSet names, from its own name. Longest suffix wins.

    `setLocatorsMenuItem` is a menu item and `controlSurfaceInputPortLabel` is a field label, and
    both say so. A set whose name declares nothing gets the default, which allows no decoration --
    so the cost of adding punctuation is naming what draws it.
    """
    best, best_len = "default", 0
    for kind, block in (rules.get("kinds") or {}).items():
        for suffix in block.get("name_suffixes") or []:
            if name.endswith(suffix) and len(suffix) > best_len:
                best, best_len = kind, len(suffix)
    return best


def named_canonicals(source: str) -> dict:
    """{LabelSet name: its canonical}, raw. The name is what says which kind of control it is."""
    text = _LINE_COMMENT.sub("", _BLOCK_COMMENT.sub(" ", source))
    out = {}
    for match in re.finditer(r"static let (\w+)\s*=\s*LabelSet\(\s*canonical:\s*"
                             r'("(?:[^"\\]|\\.)*")', text):
        for value in _STRING.findall(match.group(2)):
            value = value.replace("\\u{00A0}", "\u00a0").replace('\\"', '"')
            if value.strip():
                out[match.group(1)] = value
    return out


def all_named_canonicals() -> dict:
    out = {}
    for path in swift_sources():
        with open(path, "r", encoding="utf-8") as handle:
            out.update(named_canonicals(handle.read()))
    return out


def canonical_literals(source: str) -> set:
    """Only the `canonical:` member of each LabelSet, raw.

    The distinction the near-miss rule turns on. `variants` are DELIBERATE tolerance -- Logic ships
    `Autopunch` and the set carries `Auto Punch` and `Auto-Punch` so a differently-spelled reading
    still matches, and those being absent from Apple's data is the point of them. A `canonical`
    that is absent is a different thing: it is the spelling this repository claims Logic uses.
    Measured on the control-surface branch: `Input Port:`, `Output Port:` and `Model:` are
    canonical, are absent from all 24 corpora, and Logic ships all three without the colon -- and
    the observation record names `Input Port` zero times, so none was ever read off a screen.
    """
    text = _LINE_COMMENT.sub("", _BLOCK_COMMENT.sub(" ", source))
    out = set()
    for match in _LABELSET.finditer(text):
        for value in _STRING.findall(match.group(1)):
            value = value.replace("\\u{00A0}", "\u00a0").replace('\\"', '"')
            if value.strip():
                out.add(value)
    return out


def all_canonicals() -> set:
    out = set()
    for path in swift_sources():
        with open(path, "r", encoding="utf-8") as handle:
            out |= canonical_literals(handle.read())
    return out


#: Templates whose composition explains a literal, and the only Apple strings this file commits
#: in full. Written by `--reclassify`, read by the offline check, and deliberately NOT the whole
#: template table: Logic ships 500 single-placeholder templates and committing all ten locales of
#: each is 278 KB of artefact nobody would read. This holds the ones a classification RESTS on,
#: which is the same rule `docs/canon/index/` follows for rows.
TEMPLATES = os.path.join(REPO, "docs", "canon", "TEMPLATES.json")

#: A template contributes nothing if it is bare. Logic ships 8 rows whose value in some locale is
#: exactly `%@`, and reverse-composing against one of those would explain EVERY string as composed.
MIN_TEMPLATE_TEXT = 2


def _template_rows(app, canon):
    """Every row that is a single-placeholder template in every locale it carries."""
    out = {}
    for unit, locale, key, field, value in canon.extract_strings(app):
        if field != "value" or "%@" not in value or value.count("%@") != 1:
            continue
        out.setdefault((unit, key), {})[locale] = value
    return out


def _decompose(literal, template_value):
    """The noun a literal would have to carry to BE this template, or None.

    `Afficher Bibliothèque` against `Afficher %@` yields `Bibliothèque`. A template with fewer than
    `MIN_TEMPLATE_TEXT` characters of its own explains nothing and is refused here rather than
    producing an explanation that fits everything.
    """
    prefix, suffix = template_value.split("%@", 1)
    if len(prefix) + len(suffix) < MIN_TEMPLATE_TEXT:
        return None
    if not literal.startswith(prefix) or not literal.endswith(suffix):
        return None
    middle = literal[len(prefix):len(literal) - len(suffix)] if suffix else literal[len(prefix):]
    return middle or None


def _composed_by(literal, templates, values_by_locale, canon):
    """(unit, key, locale) of a template that explains this literal, or None.

    Logic BUILDS some labels rather than shipping them: `Show %@` with a noun. `Show Library` is in
    no corpus in any locale and the View menu says it, which is not a contradiction once the
    composition is visible. Answering `nowhere` for such a string is the classifier being unable to
    ask the right question, not Apple failing to ship it.
    """
    folded = canon.normalize(literal)
    for (unit, key), per_locale in templates.items():
        for locale, template_value in per_locale.items():
            noun = _decompose(folded, canon.normalize(template_value))
            if noun and noun in values_by_locale.get(locale, ()):
                return (unit, key, locale)
    return None


def classify(app: str, literals: set) -> dict:
    """Where each literal is answered. Needs Logic; the committed map is what CI reads.

    EXACT, not case-folded. The first version folded case because the product folds case when it
    MATCHES -- but that is a different question. "Does Logic ship this string" is exact: Logic
    ships `Trim`, and `trim` is a lowercase fragment this product carries for containment matching.
    Folding made 20-odd such fragments classify as though Apple shipped them, and it put the
    classification at odds with the absence sets, which are exact -- two notions of "in the corpus"
    inside one system. Surfaced by `verify_buckets_offline`, which could not agree with either.
    """
    titles = set()
    for locale in canon.EXPECTED_LOCALES:
        path = os.path.join(app, "Contents", "Resources", f"{locale}.lproj", "QuickHelp.plist")
        if not os.path.exists(path):
            continue
        for entry in canon.load_plist(path).values():
            if isinstance(entry, dict):
                title = (entry.get("_LOCALIZABLE_") or {}).get("Title")
                if title:
                    titles.add(canon.normalize(title))
    values = {canon.normalize(value) for _u, _l, _k, _f, value in canon.extract_strings(app)}
    # The English column `.strings` does not have. Apple compiles it into `Base.lproj/<table>.nib`
    # and ships no `en.lproj/<table>.strings` beside it -- measured: zero of the 162 such tables
    # have both. Without this bucket an English label Apple ships classified `nowhere`, and the
    # author who cited the Korean for the same control succeeded while the author who cited the
    # English was sent to prove the uncitable. Four of this repo's own literals were in that state.
    nib_values = {canon.normalize(value)
                  for _u, _l, _k, _f, value in canon.extract_nibstrings(app)}
    # Per-locale value sets, for the composition check below. A noun has to be a value in the SAME
    # locale as the template that would carry it; `Bibliothek` explains a German label and nothing
    # about a French one.
    values_by_locale = {}
    for _unit, locale, _key, field, value in canon.extract_strings(app):
        if field == "value":
            values_by_locale.setdefault(locale, set()).add(canon.normalize(value))
    templates = _template_rows(app, canon)

    out, used = {}, {}
    for literal in sorted(literals):
        if literal in titles:
            out[literal] = "quickhelp_title"
        elif literal in values:
            out[literal] = "strings_value"
        elif literal in nib_values:
            out[literal] = "nibstrings_value"
        else:
            hit = _composed_by(literal, templates, values_by_locale, canon)
            if hit:
                out[literal] = "composed_value"
                used[(hit[0], hit[1])] = templates[(hit[0], hit[1])]
            else:
                out[literal] = "nowhere"
    classify.templates_used = used
    return out


def verify_buckets_offline(committed: dict) -> list:
    """Check every classification against the committed absence sets. No Logic needed.

    Without this the offline check was set equality on KEYS only, so a literal could be relabelled
    `nowhere` -> `strings_value` and pass in CI -- the bucket is the whole content of the file and
    nothing read it. Measured: flipping `Auto Punch` produced zero complaints.

    The absence sets answer it exactly. `strings_value` means the literal is NOT absent from the
    strings corpus in some locale; `quickhelp_title` means the same of QuickHelp; `nowhere` means
    absent from every corpus. A 32-bit collision can only make an absent string look present, so
    the one direction this can be wrong in is refusing a true `nowhere` -- which sends a person to
    a machine with Logic, the safe direction.
    """
    manifest = canon.load_manifest()
    corpora = [(source, locale)
               for source, block in (manifest.get("sources") or {}).items()
               for locale in (block.get("locales") or [])]
    problems = []
    # Once, not per literal: the composition rule below is switched off when its evidence cannot be
    # read, and a rule that is not applied has to say so where somebody is stopped -- in the exit
    # code -- rather than on stderr beside a zero.
    absent_evidence = _composition_evidence_missing()
    if absent_evidence and any(where == "composed_value" for where in committed.values()):
        problems.append(
            f"{', '.join(absent_evidence)} absent, so whether a `composed_value` is witnessed or "
            f"declared cannot be answered. That rule covers "
            f"{sum(1 for where in committed.values() if where == 'composed_value')} literal(s) "
            f"here and is NOT APPLIED -- which is a broken tree, not a clean one. Restore what is "
            f"missing, or this guard is passing them unchecked.")
    for literal, where in sorted(committed.items()):
        present = set()
        for source, locale in corpora:
            try:
                if not canon.is_absent(source, locale, literal):
                    present.add(source)
            except canon.CanonError:
                continue
        if where == "nowhere" and present:
            problems.append(f"{literal!r} is classified `nowhere` and the pinned corpus holds it "
                            f"in {sorted(present)}. The classification is false.")
        elif where == "strings_value" and "strings" not in present:
            problems.append(f"{literal!r} is classified `strings_value` and no .strings corpus "
                            f"holds it. The classification is false.")
        elif where == "quickhelp_title" and "quickhelp" not in present:
            problems.append(f"{literal!r} is classified `quickhelp_title` and no QuickHelp corpus "
                            f"holds it. The classification is false.")
        elif where == "nibstrings_value" and "nibstrings" not in present:
            problems.append(f"{literal!r} is classified `nibstrings_value` and no Base.lproj nib "
                            f"holds it. The classification is false.")
        elif where == "composed_value" and not _composed_offline(literal):
            problems.append(
                f"{literal!r} is classified `composed_value` and no committed template composes "
                f"it from a string Apple ships. The classification is false.")
        elif (where == "composed_value" and not _composition_evidence_missing()
              and not _composition_is_accounted_for(literal)):
            problems.append(
                f"{literal!r} is classified `composed_value` on DECOMPOSABILITY alone: a committed "
                f"template plus a noun Apple ships somewhere produce it, and nothing says Logic "
                f"does. No observation record names it and no LabelSet declares a `composed_from` "
                f"covering it.\n"
                f"  Decomposability is not composition. `%@ 보기` and the noun `트랙` produce "
                f"`트랙 보기`, which Logic composes nowhere -- a review used exactly that shape to "
                f"classify an invented literal and leave it out of the `nowhere` ledger, which is "
                f"the only list that counts a literal nobody can explain.\n"
                f"  Either record a reading that names it, or declare the composition on the "
                f"LabelSet so `check-new-labelsets-name-a-row.py` verifies each factor against the "
                f"row's digest per locale.")
    return problems


@functools.lru_cache(maxsize=1)
def _composition_evidence_missing() -> tuple:
    """What the composition rule needs to read and cannot find. Empty means it can be applied.

    This ABSTAINED until 2026-09-20 -- it printed a note to stderr, returned False, and the run
    exited 0 with one rule silently not applied. The reasoning was a fixture: the self-test used to
    build a tree of Scripts and a classification and nothing else, and reporting its fifteen
    legitimate literals as unaccounted would have been refusing for lack of evidence rather than
    because of it.

    That fixture no longer exists. The self-test copies the whole of `docs/canon`, the whole of
    `docs/observations` and both readers, "because a fixture that is a subset of what the guard
    reads tests nothing" -- its own words. So the only tree that reaches this now is one where an
    artifact this repository ships has GONE, and a note on stderr beside exit 0 is how that goes
    unnoticed. The note was the only thing that would have told anybody; it is a refusal now.
    """
    missing = []
    if not os.path.isdir(os.path.join(REPO, "docs", "observations")):
        missing.append("docs/observations/")
    if not os.path.exists(os.path.join(REPO, "docs", "canon", "LABELSETS-WITHOUT-A-ROW.json")):
        missing.append("docs/canon/LABELSETS-WITHOUT-A-ROW.json")
    # And the READERS, not only the files. Both answers come from other guards loaded by path, and
    # a tree that does not carry them cannot answer either question. "I could not read it" is not
    # "it says no" -- the same distinction this repository makes for `history: unavailable`, and
    # the first version of this rule got it wrong: it turned a fixture missing two Scripts into
    # fifteen accusations against literals that are fine.
    for name in ("check-canon-citations.py", "check-labelsets-are-derived.py"):
        if not os.path.exists(os.path.join(REPO, "Scripts", name)):
            missing.append(f"Scripts/{name}")
    return tuple(missing)


def _composition_is_accounted_for(literal: str) -> bool:
    """Whether something beyond the decomposition itself says Logic composes this.

    `composed_value` is the one classification that EXEMPTS a literal from the `nowhere` ledger
    without any corpus holding it, so it is the one a wrong guess escapes through. Two things
    count, and they are the two this repository already keeps:

      * an observation record NAMES the literal -- somebody read it off a screen
      * a LabelSet DECLARES the composition in `LABELSETS-WITHOUT-A-ROW.json`, where
        `check-new-labelsets-name-a-row.py` re-proves every factor against the row's committed
        digest per locale on every run

    Measured 2026-09-19 over the fifteen `composed_value` literals: six are witnessed by a record
    and the other nine are the `Show Library` compositions, all covered by `showLibraryMenuItem`'s
    declaration. Nothing in the tree relies on decomposability alone.
    """
    if canon.normalize(literal) in _literals_in_observation_records():
        return True
    return canon.normalize(literal) in _declared_composition_members()


@functools.lru_cache(maxsize=1)
def _literals_in_observation_records() -> frozenset:
    """Every string any observation record writes, normalized. Reuses the canon guard's reader so
    the two rules agree about what "a record names it" means."""
    try:
        spec = importlib.util.spec_from_file_location(
            "canon_citations", os.path.join(REPO, "Scripts", "check-canon-citations.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return frozenset(module._literals_named_in_records())
    except Exception:
        # A reader that cannot run must not silently widen the rule. An empty set means every
        # `composed_value` literal falls through to the declaration check, which is the strict
        # direction.
        return frozenset()


@functools.lru_cache(maxsize=1)
def _declared_composition_members() -> frozenset:
    """Every member of every LabelSet that declares a `composed_from` in the waiver file."""
    path = os.path.join(REPO, "docs", "canon", "LABELSETS-WITHOUT-A-ROW.json")
    try:
        with open(path, encoding="utf-8") as handle:
            waived = json.load(handle).get("labelsets") or {}
    except (OSError, ValueError):
        return frozenset()
    declared = {name for name, entry in waived.items()
                if isinstance(entry, dict) and entry.get("composed_from")}
    if not declared:
        return frozenset()
    try:
        spec = importlib.util.spec_from_file_location(
            "labelsets_are_derived", os.path.join(REPO, "Scripts", "check-labelsets-are-derived.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with open(module.SWIFT, encoding="utf-8") as handle:
            source = handle.read()
        members = set()
        for name, values, _ref in module.declarations(source):
            if name in declared:
                members.update(canon.normalize(v) for v in values)
        return frozenset(members)
    except Exception:
        # Same direction as the record reader: a reader that cannot run must not widen the rule.
        return frozenset()


def _composed_offline(literal: str) -> bool:
    """Re-derive a `composed_value` classification with no Logic, from the committed templates.

    The noun is checked against the ABSENCE sets rather than against a value list, because that is
    what CI has. A 32-bit collision can only make an absent noun look present, so the direction
    this can be wrong in is accepting a composition that is not real -- which leaves the literal
    unexplained rather than refusing a true one, and the tree still has to name where it came from.
    """
    try:
        with open(TEMPLATES, encoding="utf-8") as handle:
            templates = json.load(handle).get("templates") or {}
    except (OSError, ValueError):
        return False
    folded = canon.normalize(literal)
    for entry in templates.values():
        unit = entry.get("unit") or ""
        for locale, template_value in (entry.get("values") or {}).items():
            noun = _decompose(folded, canon.normalize(template_value))
            if not noun:
                continue
            for source in ("strings", "nibstrings"):
                try:
                    if not canon.is_absent(source, locale, noun):
                        return True
                except canon.CanonError:
                    continue
    del unit
    return False


def near_miss_canonicals(manifest: dict) -> list:
    """A `canonical` absent from every corpus, whose only difference is decoration its kind may
    not carry. REFUSED, not advised.

    `absent` proves a byte string is not in the corpus, which is exactly true and half an answer:
    `Input Port:` is absent from all 24 corpora and Logic ships `Input Port`, so a colon proves
    any label uncitable. What separates that from a real one is not judgement, it is a table.

    `docs/canon/DECORATION-RULES.json` says which trailing punctuation each KIND of control may
    carry that Logic's tables do not, and each rule is witnessed in live AX evidence rather than
    remembered: an ellipsis on a menu item that opens a dialog (522 readings), a colon after a
    field name (2,631). A LabelSet's own name says which kind it is -- `setLocatorsMenuItem`,
    `controlSurfaceInputPortLabel` -- and a name that declares nothing gets the default, which
    allows none. So the cost of adding punctuation is naming what draws it.

    `variants` are exempt throughout: they are deliberate tolerance and being absent from Apple's
    data is the point of them. Refusing them was this rule's first mistake, on seven records.
    """
    rules = decoration_rules()
    default_allows = set((rules.get("default") or {}).get("allows_trailing") or [])
    corpora = [(source, locale)
               for source, block in (manifest.get("sources") or {}).items()
               for locale in (block.get("locales") or [])]
    found = []
    for name, literal in sorted(all_named_canonicals().items()):
        if not literal:
            continue
        kind = kind_of(name, rules)
        allowed = set(((rules.get("kinds") or {}).get(kind) or {}).get("allows_trailing")
                      or default_allows)
        trailing = literal[-1] if literal[-1] in _ALL_DECORATION else None
        near = []
        for source, locale in corpora:
            try:
                if not canon.is_absent(source, locale, literal):
                    near = []
                    break
                if canon.differs_only_by_decoration(source, locale, literal):
                    near.append(f"{source}/{locale}")
            except canon.CanonError:
                continue
        if not near:
            continue
        if trailing and trailing in allowed:
            continue                      # the table says this kind draws it
        where = f"kind {kind!r}" if kind != "default" else "no kind (its name declares none)"
        permitted = " ".join(sorted(allowed)) or "nothing"
        found.append(
            f"{name}: canonical {literal!r} is absent from every corpus and {near[0]} holds a "
            f"label differing from it only by decoration. It is {where}, which may add "
            f"{permitted}. Either use the bytes Logic ships -- run "
            f"`Scripts/logic_canon.py locate` -- or, if the interface really draws this, name the "
            f"kind in the LabelSet's name and give docs/canon/DECORATION-RULES.json a witnessed "
            f"rule for it.")
    return found


def check() -> list:
    literals = all_policy_literals()
    with open(CLASSIFICATION, "r", encoding="utf-8") as handle:
        committed = json.load(handle)["literals"]
    problems = list(near_miss_canonicals(canon.load_manifest()))
    for literal in sorted(literals - set(committed)):
        problems.append(
            f"{literal!r} is matched against Logic's interface and is classified nowhere. Run "
            f"`Scripts/check-policy-literals-against-canon.py --reclassify` on a machine with "
            f"Logic and read what it says the literal is.")
    for literal in sorted(set(committed) - literals):
        problems.append(f"{literal!r} is classified and appears in no LabelSet. A classification "
                        f"for a literal nobody uses is bookkeeping that outlived its reason.")
    problems += verify_buckets_offline(
        {k: v for k, v in committed.items() if k in literals})
    if os.path.isdir(APP):
        live = classify(APP, literals)
        for literal in sorted(literals & set(committed)):
            if live[literal] != committed[literal]:
                problems.append(f"{literal!r} is committed as {committed[literal]!r} and this "
                                f"Logic answers it as {live[literal]!r}. The map is stale.")
    return problems


def main() -> int:
    problems = check()
    if problems:
        print(f"{len(problems)} problem(s) with the policy literals:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    with open(CLASSIFICATION, "r", encoding="utf-8") as handle:
        committed = json.load(handle)["literals"]
    buckets = {}
    for value in committed.values():
        buckets[value] = buckets.get(value, 0) + 1
    # The scope is NAMED from the constant, not typed. This line said "under Sources/" while
    # SWIFT_ROOTS had held `Scripts/livekit` since the commit that added it -- and the comment on
    # that constant records livekit being added BECAUSE it was not scanned. So the one sentence a
    # reader sees asserted exactly the gap the fix closed.
    where = " and ".join(os.path.relpath(root, REPO) + "/" for root in SWIFT_ROOTS)
    print(f"{len(committed)} literals -- every LabelSet and every bare CJK literal under "
          f"{where}: "
          + ", ".join(f"{k} {v}" for k, v in sorted(buckets.items()))
          + ("" if os.path.isdir(APP) else "  (Logic absent: set equality only)"))
    return 0


def reclassify() -> int:
    if not os.path.isdir(APP):
        print("--reclassify needs Logic installed", file=sys.stderr)
        return 2
    mapping = classify(APP, all_policy_literals())
    used = getattr(classify, "templates_used", {}) or {}
    with open(TEMPLATES, "w", encoding="utf-8") as handle:
        json.dump({"note": "Apple's `%@` templates that a `composed_value` classification rests "
                           "on, written by --reclassify. Logic BUILDS some labels rather than "
                           "shipping them -- `Show %@` with a noun -- so a string can be absent "
                           "from every corpus and still be what the menu says. Only the templates "
                           "an answer depends on are here; the bundle carries 500 of them and all "
                           "ten locales of each is 278 KB nobody would read.",
                   "templates": {key: {"unit": unit, "values": values}
                                 for (unit, key), values in sorted(used.items())}},
                  handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    with open(CLASSIFICATION, "w", encoding="utf-8") as handle:
        json.dump({"note": "Where each string a LabelSet matches Logic with is answered. Written "
                           "by Scripts/check-policy-literals-against-canon.py --reclassify on a "
                           "machine with Logic; the offline check is set equality against it, so a "
                           "literal nobody classified fails in CI. `nowhere` is not `wrong`: "
                           "roughly half are lowercase fragments for containment matching and were "
                           "never whole labels.",
                   "literals": mapping}, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"classified {len(mapping)} literals")
    return 0


if __name__ == "__main__":
    raise SystemExit(reclassify() if "--reclassify" in sys.argv else main())
