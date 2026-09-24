#!/usr/bin/env python3
"""A statement about Logic must cite Logic, and a statement that cannot must prove it cannot.

WHY THIS EXISTS
---------------
This repository's failures about Logic have all had one shape: a string somebody typed, standing
where a string Logic ships should have been. `playheadPositionGroupLabel` carried `再生ヘッド位置`
against Logic's `再生ヘッドの位置` and the element was unfindable on every Japanese Logic while the
ledger counted it as coverage. Nothing was lying; nothing had a way to check.

Measured on 2026-09-15, the shape is not rare. `AXLocalePolicy` holds 379 distinct literals the
product matches Logic's interface with. 113 of them are a QuickHelp Title. 226 more are somewhere
in the bundle's 605,190 `.strings` entries. **40 are in no file of the app bundle.** Roughly half
of those 40 are deliberate lowercase fragments for `.contains` matching and were never whole
labels; the rest are labels Logic composes at runtime, labels from a framework outside this corpus,
or labels somebody typed -- and the repository had no way to tell which, because it had no notion
of a citation. The live counts come from `Scripts/check-policy-literals-against-canon.py`; an
earlier revision of this docstring carried 120/222/37, taken before the extractor stopped counting
`rationale` prose as labels.

So: every fact this repository states about Logic is either CITED to bytes inside Logic, or
declared uncitable with a proof that the corpus does not contain it. This guard is the mechanical
half of that rule. It runs offline, against `docs/canon/`, because CI has no Logic installed --
which is exactly why a rule enforced only on a developer's machine would be advice.

WHAT IT REFUSES
---------------
  1  a canonical reference anywhere in the tree that does not parse
  2  a reference that parses but is not in the committed index -- nobody resolved it against Logic
  3  a quoted value whose digest differs from the digest taken from Apple's bytes
  4  an absence claim over a corpus with no absence set, or over a string that is present
  5  an observation record at schema 3 with no citation, no absence proof and no
      declaration that the axis does not apply
 13  a `canon_not_applicable` from a record whose readings quote a string the corpus
      holds -- a citation was available, so the declaration is false
  6  a record joining the tree at schema 2 or lower -- the known set below may only shrink
  7  a waiver list that GAINED a member relative to the merge base
  8  a canon index pinning a different Logic than docs/observations/LOGIC-BUILD.json declares
  9  a citation with no binding, or whose binding target does not contain the cited value
 10  an index or absence file whose bytes are not the bytes `build` wrote, or an index row whose
      value is in no absence set -- a row whose value is not in the corpus was not taken from it
 11  a pull request body that neither cites nor may opt out (the opt-out is refused for a change
      touching a Logic-facing path, and is not read from a code block or an HTML comment); such
      a change may instead name a `canon_not_applicable` record it writes, bound to Logic-facing
      code it changes

WHAT IT DOES NOT CHECK, STATED RATHER THAN IMPLIED
--------------------------------------------------
That a citation is the RIGHT one. `logic-canon://quickhelp/QuickHelp/ko/KCE_024_Record#composed`
resolving with the right digest proves the quote is Apple's text under that key; it does not prove
that key describes the control the change is about. That is the same trust boundary
`docs/observations/SCHEMA.md` already names for sightings, and moving it would need the citation to
say what the value is used FOR in a form a machine can check against the code. `used_for` is
required and read by a person.
"""
import glob
import importlib.util
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_canon():
    path = os.path.join(REPO, "Scripts", "logic_canon.py")
    spec = importlib.util.spec_from_file_location("logic_canon_for_guard", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


canon = _load_canon()


def _load_ratchet():
    """The merge-base comparison, shared with `check-every-ci-job-is-required.py`.

    Loaded the same way `logic_canon` is, because `Scripts/` is not a package and
    these guards run as scripts from the repository root. It knows nothing about
    Logic: the CI-integrity owner uses it without loading the corpus.
    """
    path = os.path.join(REPO, "Scripts", "ratchet.py")
    spec = importlib.util.spec_from_file_location("ratchet_for_guard", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ratchet = _load_ratchet()

#: Records that predate the canon axis. This set may only SHRINK -- a new record joining it is
#: refused. Written as identities rather than a count because a count hides a swap, which is the
#: same reasoning `docs/observations/RATCHETS.json` is built on.
#:
#: It is deliberately seeded with every record in the tree on the day the rule landed. Turning 107
#: records red at once is how a rule gets deleted instead of satisfied; letting the 108th in
#: quietly is how it becomes decorative.
WITHOUT_CANON_PATH = os.path.join(REPO, "docs", "canon", "WITHOUT-CANON.json")


class CanonWaiverError(Exception):
    """A waiver file this guard cannot compare. Raised rather than degrading to an empty set."""


class CanonIndexUnavailable(Exception):
    """The committed index a citation would be judged against could not be read here.

    `load_index` returns an empty table for a MISSING index file, so `resolve_offline` says the
    reference "is not in docs/canon/index/<source>.tsv" -- true, and indistinguishable from the
    author citing a key that does not exist. `diagnose_text` filed both as INVALID_REFERENCE,
    which is a sentence addressed to the contributor about their citation. On a checkout without
    the corpus built, every citation in every body became the author's fault.

    That is the exact confusion this whole axis was rebuilt to remove: a corpus that would not
    load must not reach a first-time contributor as an accusation. Raised instead, so `check_text`
    renders ERROR and exits 2 -- nonzero, because a check that could not evaluate has not passed,
    and saying nothing about the body.
    """


def _json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return default


def _waiver(path: str, key: str) -> set:
    """Read a waiver list, refusing a file whose key is not the one this guard compares.

    Renaming `records` to anything else made `check_waivers_only_shrink`'s comparison degrade to
    `set() - set()` and report nothing gained, whatever had changed. It was saved only by an
    unrelated hard index raising KeyError elsewhere -- a control that worked by accident.
    """
    if not os.path.exists(path):
        return set()
    loaded = _json(path, None)
    if not isinstance(loaded, dict) or not isinstance(loaded.get(key), list):
        raise CanonWaiverError(
            f"{os.path.relpath(path, REPO)} has no list under {key!r}. That is the key the ratchet "
            f"compares, so a file without it is a ratchet that compares nothing.")
    return set(loaded[key])


def load_without_canon() -> set:
    return _waiver(WITHOUT_CANON_PATH, "records")


POLICY_CLASSIFICATION = os.path.join(REPO, "docs", "canon", "POLICY-LITERALS.json")


#: One reader of this repository's history, shared with the CI-integrity owner. Its `note()` says
#: a thing once: two rules ratchet MANIFEST.json, and a note repeated per caller reads as two
#: findings rather than one fact about the branch.
_HISTORY = ratchet.History(REPO)
R = ratchet.Ratchet


def _merge_base():
    return _HISTORY.merge_base()


def _at_base(base, path):
    return _HISTORY.at_base(base, path)


def _note(message):
    _HISTORY.note(message)


def _corpus_members(blob, key):
    """Every (source, locale) the manifest declares -- the set `required_corpora` searches.

    Not a list in a file like the other four: the corpus is DERIVED from what the build found, so
    the thing to ratchet is the derivation's output. It is ratcheted at all because the corpus is
    the denominator of every absence proof in the repository, and nothing watched it: deleting two
    of the four sources and re-running the build leaves a manifest that is internally consistent,
    an index and absence directory that match their own digests, and a gate that reports clean.
    Measured, not reasoned -- `madsp` and `nib` were removed and all 48 guards passed.
    """
    return {f"{source}/{locale}"
            for source, block in (blob.get(key) or {}).items()
            for locale in (block.get("locales") or [])}


def _key_members(blob, key):
    """The KEYS of a map, for a waiver whose values are prose rather than a classification.

    `_ratchet_members` reads any dict as POLICY-LITERALS -- literal -> where it is answered -- and
    returns only those answered "nowhere". Over a map of number -> why, that is the empty set, and
    an empty comparison passes everything. Caught by the shape check rather than by review, twice.
    """
    return set((blob.get(key) or {}))


def _skip_members(blob, key):
    """One member per ALLOWED SKIP, not one per guard, so the number moves in the right direction.

    A dict of guard -> {"skips": n} cannot be compared by membership alone: raising 4 to 5 and
    lowering 5 to 4 both look like one member lost and one gained, and a single direction refuses
    whichever of the two it was not written for -- the contradiction rule 7 already walked into
    once. Emitting `path:0 … path:n-1` makes an allowance that GROWS gain a member, which shrink
    refuses, and an allowance that falls only lose members, which shrink permits.
    """
    members = set()
    for path, row in (blob.get(key) or {}).items():
        for index in range(int((row or {}).get("skips") or 0)):
            members.add(f"{path}:{index}")
    return members


def _literals_named_in_records() -> set:
    """Every string an observation record's readings quote.

    A literal answered NOWHERE is debt only while nobody has said what it is. Once a record carries
    it as a reading, it is the other half of this axis working: Apple does not ship the string, so
    somebody measured it, and that is the SSOT the ledger exists to be. Counting those as debt
    makes the axis refuse its own output -- which it did, on `Utility`, a label Apple ships no key
    for and whose Korean was read off a live plug-in menu. Before it was a LabelSet it sat in a
    hard-coded `titles.contains("유틸리티")`, uncounted and unmeasurable.
    """
    named = set()
    root = os.path.join(REPO, "docs", "observations")
    if not os.path.isdir(root):
        return named
    for name in sorted(os.listdir(root)):
        if not name.endswith(".json"):
            continue
        record = _json(os.path.join(root, name), None)
        if not isinstance(record, dict):
            continue
        # NOT `_observation_strings`: that applies `NOT_APPLICABLE_MIN`, an eight-character floor
        # written for rule 13, where a short fragment is too weak to REFUSE a declaration on. Here
        # the question is the opposite one -- has somebody measured this literal -- and `Utility`
        # is seven characters, `유틸리티` four. A floor built to avoid false refusals became a
        # floor that caused one.
        for text in _every_string_in(record):
            named.add(canon.normalize(text))
    return named


def _ratchet_members(blob, key):
    value = blob.get(key)
    if isinstance(value, dict):
        # POLICY-LITERALS.json is a map literal -> where it is answered. Only the ones answered
        # NOWHERE are the debt; the other two buckets are the work succeeding -- and neither is a
        # literal a record has measured, which is the axis's other half rather than a shortfall.
        measured = _literals_named_in_records()
        return {name for name, where in value.items()
                if where == "nowhere" and canon.normalize(name) not in measured}
    return set(value or [])


def _labelset_waiver_members(blob, key):
    """The LabelSet names waived from naming a row.

    A dict keyed by name, so the default extractor's `set(value or [])` would read the KEYS and be
    right by accident. Spelling it out means a later shape change -- a list of objects, say -- makes
    this return nothing and trips the empty-reading guard instead of passing everything.
    """
    value = blob.get(key)
    if not isinstance(value, dict):
        return set()
    return set(value)


#: Each ratcheted list, and the direction it may move in. Two directions, because two kinds of list
#: got mixed:
#:
#:   shrink   a WAIVER -- debt, an exemption, something not yet done. Growth admits more debt.
#:   grow     a REQUIREMENT -- a path that must be cited, a command CI must run. Shrinkage
#:            quietly removes a rule.
#:
#: They were all "shrink" first, and that put two of my own rules in direct contradiction: rule 14
#: refuses a Swift file declaring a LabelSet outside `LOGIC-FACING.json`, so a new Logic-facing
#: directory MUST add a prefix -- and rule 7 refused the addition. The first change that needed it
#: would have had nowhere to go. It had not fired only because those two files do not exist at the
#: merge base of the branch that introduces them; it fires on the next one.
RATCHETS = (
    R("docs/canon/WITHOUT-CANON.json", "records", "shrink",
      "records predating the canon axis", _ratchet_members),
    R("docs/canon/POLICY-LITERALS.json", "literals", "shrink",
      "literals classified as answered nowhere in Logic", _ratchet_members),
    R("docs/canon/NOT-A-RECORD.json", "files", "shrink",
      "files in docs/observations that are declared not to be records", _ratchet_members),
    R("docs/canon/LOGIC-FACING.json", "prefixes", "grow",
      "path prefixes whose changes may not use the opt-out", _ratchet_members),
    R("docs/canon/PROSE-NUMBERS.json", "numbers", "shrink",
      "numbers docs/canon/README.md may state with no artifact behind them", ratchet.key_members),
    R("docs/canon/MANIFEST.json", "sources", "grow",
      "the (source, locale) corpora every absence proof searches", _corpus_members),
    #: `LOGIC-FACING.json`'s `exceptions` is NOT here, and neither is `LABELSETS-WITHOUT-A-ROW`:
    #: their entries are re-proved on every run. Rule 15 reads each excepted file and refuses it
    #: if it carries a `logic-canon://` reference or quotes a value the pinned corpus holds, and
    #: `check-new-labelsets-name-a-row.py:225` re-proves EVERY waiver against Apple's own data --
    #: `prove_absent` searches every ENGLISH corpus the manifest pins, `prove_composition` verifies
    #: each factor against the row's committed digest per locale. The bar an added entry clears is
    #: a property of the file, not a sentence about it. A monotonic ratchet on top of that would
    #: forbid the repair and buy nothing -- and `LABELSETS-WITHOUT-A-ROW.json` WAS here as a
    #: `shrink` list, which made the repository's own documented path unreachable: the guard
    #: offered a new LabelSet two answers and rule 7 refused the second in the same run that
    #: accepted it.
    #:
    #: The ratchet stays on every other waiver list, where the entries ARE taken on trust.
    #:
    #: The file below DOES NOT EXIST at the time of writing, and that was the hole: the guard
    #: reads it (`check-ax-comparisons-use-labelsets.py`) and skips whatever it names, so anyone
    #: could create it in the same change as the comparison it excuses and nothing compared it to
    #: anything. A ratchet entry on an absent file is not a mistake -- the comparison begins the
    #: moment somebody creates it, and every entry in the first version is a growth rule 7 refuses.
    #: The key is `literals` because that is what `check-ax-comparisons-use-labelsets.py::waived`
    #: reads. A ratchet aimed at a key the consumer does not use guards a list nothing obeys.
    R("docs/canon/AX-COMPARISON-WAIVERS.json", "literals", "shrink",
      "AX comparisons waived from using a LabelSet", ratchet.key_members),
)

#: THE CI-ONLY LISTS ARE NOT HERE ANY MORE. `CI-GATE.json`, `CI-SKIPS.json`,
#: `GUARDS-WITHOUT-A-TEST.json` and `GUARD-TESTS-BLIND-TO-THEIR-GUARD.json` say nothing about
#: Logic: they are the CI gate's own topology and debt, and they were ratcheted here only because
#: this is where the comparison happened to live. They moved to `.github/ci/` with their owner,
#: `check-every-ci-job-is-required.py`, which declares the same ratchets over the new paths and
#: names the old ones as `legacy` so the relocation is compared rather than bootstrapped (#951).


def check_waivers_only_shrink(failures: list) -> None:
    """Rule 7: a waiver list may only shrink, and a requirement list may only grow.

    Compared against `git merge-base`, not against the file itself, because a file-only check is
    what a same-commit edit defeats: add a record at schema 1 AND add it to the waiver in one
    commit, and the tree is internally consistent.

    The comparison itself is `Scripts/ratchet.py`, shared with the CI-integrity owner. What stays
    here is WHICH Logic-facing lists are ratcheted and how their members are read.
    """
    ratchet.check(REPO, RATCHETS, failures, history=_HISTORY,
                  owner=os.path.basename(__file__))


#: Numbers under `sources.*.shape` and `sources.*.round_trip` that may move DOWN without the
#: claim getting weaker. Everything else there is ratcheted, so a structural number added later is
#: covered by default rather than by somebody remembering to add it.
NOT_A_STRENGTH = ("median_length", "shortest")


def _measured_counts(manifest: dict) -> dict:
    """Every number in the manifest whose decrease makes a claim in this repository cheaper."""
    counts = {}
    for source, block in (manifest.get("sources") or {}).items():
        for locale, entries in (block.get("absence_entries") or {}).items():
            if isinstance(entries, int):
                counts[f"absence/{source}.{locale}.u32"] = entries
        for group in ("shape", "round_trip"):
            for locale, row in (block.get(group) or {}).items():
                for field, value in (row or {}).items():
                    if isinstance(value, int) and field not in NOT_A_STRENGTH:
                        counts[f"{source}.{group}.{locale}.{field}"] = value
    return counts


def check_no_measured_count_shrinks(failures: list) -> None:
    """Rule 16: a measured number may not shrink while the Logic it was read from is the same.

    Rule 7 ratchets WHICH corpora are searched. This ratchets HOW MANY -- of anything the manifest
    counts -- and it is a separate rule because the comparison is numeric rather than set
    membership.

    Two populations, found one after the other and the same underneath. The absence sets are the
    denominator of every absence proof. `sources.quickhelp.shape` is the denominator of the only
    proof that the parser works which CI can run: `TheAlgorithmAgainstASurrogateCorpus` builds its
    fixture FROM those numbers, so shrinking them shrinks the test. Measured: setting
    `suffix_pairs` to 1, `most_keys_on_one_composition` to 1 and `compositions` to 210 left a
    surrogate with one suffix pair and no shared composition at all -- the property 3,766 real ko
    keys have -- and all 62 cases reported OK. The case written to catch exactly that,
    `test_the_surrogate_is_shaped_like_the_real_corpus`, cannot: every assertion in it compares the
    surrogate against the same numbers that built the surrogate.

    `verify_absence_counts` already reads the counts, and its own docstring says what that is worth:
    it "makes the forgery need three consistent edits -- the binary set, its digest, and a number a
    reviewer reads -- instead of two." A rebuild makes all three consistently, so within one tree
    nothing distinguishes a corpus from a corpus with most of it thrown away.

    Measured: twelve absence sets truncated to 50 entries each, with the manifest's counts and
    digests rewritten to match, discarded 410,771 values and left `check-canon-citations` at exit 0
    and 46 of 48 repo guards green. `Scripts/logic_canon.py absent strings es 'Pista'` then answered
    ABSENT for a string Logic ships. What caught the other two guards was three policy literals that
    happen to be answered only in a shrunken locale -- incidental, and gone as soon as those three
    are answered elsewhere.

    `verify_index_against_absence` is the one check that could have seen this, and what it can see
    is bounded by CITATION rather than by corpus count. It checks every committed index row against
    its corpus's absence set; a value nobody has cited has no row, so nothing offline can notice it
    being removed. This paragraph used to put a number on that -- "only six of the twenty-three
    corpora carry a committed index row … blind to the other seventeen" -- and the number went
    stale without anything noticing: measured 2026-09-19, the manifest carries TWENTY-FOUR corpora
    and TWENTY-THREE of them carry at least one row (only `strings/-` carries none). The conclusion
    drawn from it was false too. Number words escape `check-canon-prose-numbers.py`, which reads
    digits, so the sentence is stated as a property now and the count is recomputed by whoever
    needs it rather than written down here to rot.

    A DIFFERENT Logic legitimately holds different strings, so the rule steps aside when the
    manifest's `logic` block changes, and says so rather than passing quietly. That escape is not
    free: `check_build_agrees_with_the_ledger` makes the same change disagree with every record's
    host block until those are updated too.
    """
    base = _merge_base()
    if base is None:
        return                      # rule 7 reports an unreadable base; one voice is enough
    before = _at_base(base, "docs/canon/MANIFEST.json")
    if before is None:
        return
    now = _json(os.path.join(REPO, "docs", "canon", "MANIFEST.json"), {})
    was_counts, now_counts = _measured_counts(before), _measured_counts(now)
    if was_counts and not now_counts:
        failures.append(
            "docs/canon/MANIFEST.json: the merge base declared measured counts and this tree "
            "declares none. A block that disappears takes its ratchet with it, and the surrogate "
            "corpus tests skip rather than fail when the shape is gone.")
        return
    shrunk = [(name, was, now_counts[name]) for name, was in sorted(was_counts.items())
              if name in now_counts and now_counts[name] < was]
    if not shrunk:
        return
    if (before.get("logic") or {}) != (now.get("logic") or {}):
        # Stated, not swallowed. A reviewer should see which corpora moved and by how much.
        for name, was, is_now in shrunk:
            print(f"  note: {name} is {is_now} and was {was} at the merge base. The manifest names "
                  f"a different Logic, so this is allowed here.", file=sys.stderr)
        return
    for name, was, is_now in shrunk:
        failures.append(
            f"{name} is {is_now} and was {was} at the merge base, over the same Logic. A measured "
            f"number that falls makes something here cheaper to claim -- an absence set that lost "
            f"values proves strings absent that Logic ships, and a shape that lost structure "
            f"shrinks the surrogate corpus the parser is tested against. If Logic really changed, "
            f"the Logic in MANIFEST.json changed with it.")


def check_build_agrees_with_the_ledger(manifest: dict, failures: list) -> None:
    """Rule 8: the canon index and the observation ledger must describe the same Logic.

    Two declarations of the installed build is two places for it to be wrong. Before this, the
    index could be taken over Logic 12.4 while every record in `docs/observations/` claimed 12.3,
    and each file would be internally consistent.
    """
    path = os.path.join(REPO, "docs", "observations", "LOGIC-BUILD.json")
    if not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as handle:
        declared = json.load(handle)
    pinned = manifest.get("logic") or {}
    for field in ("version", "build"):
        if str(declared.get(field)) != str(pinned.get(field)):
            failures.append(
                f"docs/canon/MANIFEST.json pins Logic {pinned.get('version')} "
                f"({pinned.get('build')}) and docs/observations/LOGIC-BUILD.json declares "
                f"{declared.get('version')} ({declared.get('build')}). The canon index and the "
                f"observation ledger must describe the same application.")
            return


def required_corpora(manifest: dict):
    """Every (source, locale) an absence claim must search. Derived from the manifest, from nothing else.

    Three revisions, and the first two moved the choice rather than removing it:

        v1  `searched` was author-chosen                 -> a claim searched only where it was safe
        v2  derived from `host.locale`                   -> `host.locale` is author-chosen too, so a
                                                            Korean string was "proved uncitable" by
                                                            searching English. Measured by review.
        v3  every locale of every source                 -> nothing an author writes changes it

    The cost is real and it is the right cost: a string absent from Logic is absent from all ten
    locales, so proving it in all ten is what the claim actually means. A string present in one is
    citable from that one, and a record saying nobody can cite it would be false.
    """
    wanted = set()
    for source, block in (manifest.get("sources") or {}).items():
        for locale in (block.get("locales") or []):
            wanted.add((source, locale))
    return wanted


#: The files in `docs/observations/` that are deliberately not records.
#: Read from a FILE, not held as a module constant, so `check_waivers_only_shrink` can compare it
#: against the merge base. A constant is edited in the same commit as the thing it excuses, which
#: is the hole rule 7 exists to close -- and it was open here and in
#: `check-every-ci-job-is-required.py` while rule 7 guarded two other lists.
NOT_A_RECORD_PATH = os.path.join(REPO, "docs", "canon", "NOT-A-RECORD.json")


def not_a_record() -> set:
    return _waiver(NOT_A_RECORD_PATH, "files")


BINDING_KINDS = ("code", "record")

#: Fields a `record` binding may NOT be satisfied by. `limits` is narrative and a value pasted
#: there proves nothing about how the record used the citation; review 2026-09-15 confirmed that
#: exact paste passes. The substantive fields are where a citation that is load-bearing shows up.
BINDING_RECORD_FIELDS = ("observations", "conclusion", "method", "question", "subject",
                         "canon_absent", "evidence")


#: The shortest observation string worth testing for citability. Below this a value is a role name,
#: a number or a fragment, and a corpus hit means nothing.
NOT_APPLICABLE_MIN = 8


#: The fields rule 13's bound reads. `observations` alone was not enough: moving the citable
#: string into `conclusion`, `method` or `limits` defeated the bound entirely, which makes the
#: declaration available to any record willing to phrase itself differently. Prose is included
#: deliberately -- the test is an EXACT corpus match on a run of eight characters or more, which an
#: English sentence does not produce by accident, and a record whose conclusion quotes a string
#: Logic ships had a citation available wherever it put it.
NOT_APPLICABLE_FIELDS = ("observations", "conclusion", "method", "question", "subject", "limits")


def _every_string_in(record: dict) -> list:
    """Every string in the record's substantive fields, at any length."""
    out = []

    def walk(node):
        if isinstance(node, dict):
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
        elif isinstance(node, str) and node.strip():
            out.append(node)

    for field in NOT_APPLICABLE_FIELDS:
        walk(record.get(field))
    for citation in record.get("canon") or []:
        if isinstance(citation, dict) and isinstance(citation.get("value"), str):
            out.append(citation["value"])
    return out


def _observation_strings(record: dict) -> list:
    """Every string in the record's substantive fields, flattened."""
    out = []

    def walk(node):
        if isinstance(node, dict):
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
        elif isinstance(node, str) and len(node) >= NOT_APPLICABLE_MIN:
            out.append(node)

    for field in NOT_APPLICABLE_FIELDS:
        walk(record.get(field))
    return out


def check_not_applicable(rel: str, record: dict, manifest: dict, failures: list) -> None:
    """Rule 13: a record may declare the canon axis does not apply, and the claim is checked.

    Several records state facts about Logic's BEHAVIOUR rather than its strings -- "the routing
    graph publishes nothing or 23 nodes depending on read order", "the marker list settles in
    seconds". There is no key to cite and nothing to prove absent, and rule 5 as first written
    forced a citation anyway. A forced citation is a perfunctory one, which is the failure this
    axis exists to end arriving through the front door.

    So a record may say so, and the saying is bounded: if any of its READINGS resolves in the
    corpus then a citation was available and the declaration is false. Measured against the
    thirteen records of #882 -- eight quote nothing citable and may decline; five quote strings
    Logic ships (`Neue Spur`, `Erzeugen`, `컨트롤러 할당…`) and are named by this check.
    """
    declared = record.get("canon_not_applicable")
    if not isinstance(declared, dict):
        failures.append(f"{rel}: `canon_not_applicable` must be an object carrying a `reason`")
        return
    if not declared.get("reason"):
        failures.append(
            f"{rel}: `canon_not_applicable.reason` is required -- say what KIND of claim this "
            f"record makes, since it is not a claim about a string Logic ships")
        return
    corpora = sorted(required_corpora(manifest))
    for text in _observation_strings(record):
        for source, locale in corpora:
            try:
                if not canon.is_absent(source, locale, text):
                    failures.append(
                        f"{rel}: declares the canon axis does not apply, and its readings contain "
                        f"{text[:60]!r}, which resolves in {source}/{locale}. A citation was "
                        f"available, so the declaration is false.")
                    return
                if canon.differs_only_by_decoration(source, locale, text):
                    # Same reason as the `canon_absent` rule below: exact absence is not absence
                    # when a shipped label folds to the reading. A declaration that the axis does
                    # not apply is strongest exactly where the reading is a near miss of a real
                    # label, because that is where the author typed rather than read.
                    failures.append(
                        f"{rel}: declares the canon axis does not apply, and its readings contain "
                        f"{text[:60]!r}, which is absent from {source}/{locale} only as BYTES -- a "
                        f"string Logic ships folds to it. Quote it the way the corpus holds it; "
                        f"the declaration is false for a label that differs by a colon or a case.")
                    return
            except canon.CanonError:
                continue


#: Comment syntaxes for the file types a binding can name. A value sitting only in a comment used
#: to satisfy a `code` binding -- the docstring said so, and review confirmed it by putting one in
#: a `//` line of an otherwise empty file and watching it pass. It was written up as a limitation
#: whose fix "needs the binding to name a symbol AND the build to confirm the symbol carries it".
#: That is the strong form. This is the cheap one, and it closes the case that was demonstrated:
#: strip the comments, and a value living only in one is gone.
_COMMENT_SYNTAX = {
    ".swift": [(r"//[^\n]*", ""), (r"/\*.*?\*/", " ")],
    ".py": [(r"#[^\n]*", "")],
    ".sh": [(r"#[^\n]*", "")],
    ".yml": [(r"#[^\n]*", "")],
    ".yaml": [(r"#[^\n]*", "")],
    ".c": [(r"//[^\n]*", ""), (r"/\*.*?\*/", " ")],
    ".h": [(r"//[^\n]*", ""), (r"/\*.*?\*/", " ")],
    ".m": [(r"//[^\n]*", ""), (r"/\*.*?\*/", " ")],
    ".js": [(r"//[^\n]*", ""), (r"/\*.*?\*/", " ")],
    ".ts": [(r"//[^\n]*", ""), (r"/\*.*?\*/", " ")],
}


def _without_comments(text: str, path: str) -> str:
    """The file with its comments removed, for the suffixes whose syntax is known.

    A suffix nobody listed is returned whole, which is the honest failure: JSON has no comments, so
    a `code` binding onto a `.json` file is checked against every byte of it, and that is what the
    file means.

    The LIMIT that remains: a `//` inside a Swift string literal takes the rest of that line with
    it, so a citation whose value contains `//` and is bound to Swift would be reported missing.
    Nothing in the tree does that, and a false refusal a person can see beats a false pass nobody
    can.
    """
    rules = _COMMENT_SYNTAX.get(os.path.splitext(path)[1])
    if not rules:
        return text
    for pattern, replacement in rules:
        text = re.sub(pattern, replacement, text, flags=re.S)
    return text


def check_binding(where: str, citation: dict, record: dict, failures: list,
                  changed_paths=None) -> None:
    """Rule 9: a citation must be LOAD-BEARING, not decorative.

    Citing is not using. Before this, a record could carry a reference that resolved with the right
    digest and rest on nothing: the quote was Apple's text, the check passed, and no line of code or
    reading in the record had anything to do with it. That is the gap Isaac named -- whether the
    canonical source "was actually used as the SSOT in this change" -- and a reference alone cannot
    answer it.

    So a binding names WHERE the value lands, and the value (or its key) must literally be there:

        {"kind": "code",   "path": "Sources/.../X.swift"}   the file must contain it
        {"kind": "record"}                                   this record must contain it, in one of
                                                             BINDING_RECORD_FIELDS

    What it does NOT prove, stated rather than implied: that the occurrence is the one that matters.
    A value appearing in a comment satisfies the `code` kind -- confirmed by review, which put one
    in a `//` comment in an otherwise empty file and watched it pass. Closing that needs the binding
    to name a symbol AND the build to confirm the symbol carries it, which is a different and much
    heavier rule.
    """
    binding = citation.get("binding")
    if not isinstance(binding, dict):
        failures.append(
            f"{where}: `binding` is required. A reference that resolves proves the quote is "
            f"Apple's text; it does not prove anything in this change rests on it.")
        return
    kind = binding.get("kind")
    if kind not in BINDING_KINDS:
        failures.append(f"{where}: binding.kind must be one of {list(BINDING_KINDS)}, got {kind!r}")
        return

    try:
        ref = canon.CanonRef.parse(citation.get("ref", ""))
    except canon.CanonRefError:
        return  # already reported by the reference check
    needles = [n for n in (canon.normalize(citation.get("value", "")), ref.key) if n]

    if kind == "code":
        path = binding.get("path")
        if not path:
            failures.append(f"{where}: binding.kind 'code' needs a `path`")
            return
        full = os.path.join(REPO, path)
        if not os.path.exists(full):
            failures.append(f"{where}: binding.path {path!r} does not exist")
            return
        with open(full, "r", encoding="utf-8", errors="replace") as handle:
            body = canon.normalize(_without_comments(handle.read(), path))
        if not any(needle in body for needle in needles):
            failures.append(
                f"{where}: neither the cited value nor the key {ref.key!r} appears in {path}. "
                f"The citation says that file rests on this canonical value and the file does not "
                f"contain it.")
            return
        # ...and the file must be one THIS CHANGE touches. Without the list, a binding proved only
        # that the REPOSITORY contains the value somewhere -- a citation could point at a file the
        # change never opened and pass. The requirement was that the canonical source be used as
        # the source of truth IN THIS CHANGE, and "somewhere in the tree" is not that.
        if changed_paths is not None and path not in changed_paths:
            failures.append(
                f"{where}: binding.path {path!r} is not a file this change touches. A citation "
                f"bound to code the change never opened says the repository holds the value, not "
                f"that this change rests on it. Bind to a file in the diff, or use "
                f"{{\"kind\": \"record\"}} if the citation backs a reading rather than code.")
        return

    substantive = canon.normalize(json.dumps(
        {k: v for k, v in record.items() if k in BINDING_RECORD_FIELDS}, ensure_ascii=False))
    if not any(needle in substantive for needle in needles):
        failures.append(
            f"{where}: neither the cited value nor the key {ref.key!r} appears in any of this "
            f"record's substantive fields {list(BINDING_RECORD_FIELDS)}. A citation nothing refers "
            f"to is decorative, and `limits` is deliberately not one of them -- a value pasted "
            f"there says nothing about how the record used it.")


def observation_records() -> list:
    """Every record file. A record is date-prefixed; RATCHETS.json and LOGIC-BUILD.json are not."""
    out = []
    for path in sorted(glob.glob(os.path.join(REPO, "docs", "observations", "*.json"))):
        name = os.path.basename(path)
        if len(name) > 10 and name[:4].isdigit() and name[4] == "-":
            out.append(path)
    return out


def check_every_json_is_a_record_or_declared(failures: list) -> None:
    """Rule 12: a JSON file in `docs/observations/` is a record, or is named as not one.

    Record discovery is by filename convention and nothing enforced the convention, so
    `note-on-automation.json` at schema 1 was invisible to this guard, to
    `check-observation-records.py` and to `check-observation-ratchets.py` -- all three use the same
    date-prefix filter. Renaming a file was a complete bypass of rules 5, 6 and 9 with no defence
    in depth. Measured by review 2026-09-15.
    """
    for path in sorted(glob.glob(os.path.join(REPO, "docs", "observations", "*.json"))):
        name = os.path.basename(path)
        if name in not_a_record():
            continue
        if not (len(name) > 10 and name[:4].isdigit() and name[4] == "-"):
            failures.append(
                f"docs/observations/{name} is neither date-prefixed nor declared as not a record. "
                f"Every guard over this directory finds records by that prefix, so a file without "
                f"it is a record nothing checks.")


def check_references(failures: list) -> int:
    """Rules 1, 2 and 3 over every file in the tree: a reference parses, is pinned, and is QUOTED.

    The quote requirement used to apply only to pull request bodies and to observation records, so
    an ADR, a roadmap row or a README could name a real key beside a value Apple does not ship --
    which is the original failure one directory over. Measured by review 2026-09-15: the same bytes
    passed the tree-wide scan and failed `--text`.
    """
    found = canon.scan_repo_citations(REPO)
    bodies = {}
    for ref_text, where in sorted(found.items()):
        try:
            ref = canon.CanonRef.parse(ref_text)
        except canon.CanonRefError as exc:
            failures.append(f"{where[0]}: {exc}")
            continue
        try:
            committed = canon.resolve_offline(ref)
        except canon.CanonResolveError as exc:
            failures.append(f"{where[0]}: {exc}")
            continue
        for rel in where:
            if rel.endswith(".json") and rel.startswith("docs/observations/"):
                continue  # checked against its own `canon` block, with the binding as well
            if _is_derived_from(rel, ref_text):
                # A `derivedFrom:` reference is checked by `check-labelsets-are-derived.py`, and
                # checked HARDER: not that the English appears near it, but that for every one of
                # the ten locales Logic ships some member of the LabelSet is the value Apple pins
                # at that row. Demanding the English verbatim as well would force the row's exact
                # spelling into `variants` beside the lowercase fragment this product matches by
                # containment -- `Mixer` beside `mixer` -- which `check-probe-product-drift.py`
                # refuses, and rightly: case-folded matching would merge them.
                continue
            if rel not in bodies:
                with open(os.path.join(REPO, rel), "r", encoding="utf-8", errors="replace") as fh:
                    bodies[rel] = canon.normalize(fh.read())
            if not _quotes_the_value(bodies[rel], ref, committed):
                failures.append(
                    f"{rel}: {ref} appears without the value it resolves to. A reference alone is a "
                    f"key anybody can type; the citation is the reference AND the value.")
    return len(found)


def check_record(path: str, failures: list, without_canon: set, manifest: dict,
                 changed_paths=None) -> None:
    rel = os.path.relpath(path, REPO)
    with open(path, "r", encoding="utf-8") as handle:
        record = json.load(handle)
    schema = record.get("schema", 1)

    if schema < 3:
        if rel not in without_canon:
            failures.append(
                f"{rel}: schema {schema}. A record joining the tree states facts about Logic, so it "
                f"carries `canon` citations or a `canon_absent` proof. Records written before the "
                f"rule are listed in docs/canon/WITHOUT-CANON.json and that list may only shrink.")
        return

    citations = record.get("canon", [])
    absences = record.get("canon_absent", [])
    if "canon_not_applicable" in record:
        check_not_applicable(rel, record, manifest, failures)
    elif not citations and not absences:
        failures.append(
            f"{rel}: schema 3 with none of `canon`, `canon_absent` or `canon_not_applicable`. A "
            f"record that cites nothing, claims nothing is uncitable and does not say the axis is "
            f"inapplicable is a record whose relationship to Logic's own data was never stated.")

    for index, citation in enumerate(citations):
        where = f"{rel}: canon[{index}]"
        for field in ("ref", "value", "used_for"):
            if not citation.get(field):
                failures.append(f"{where}: `{field}` is required and empty")
        if not citation.get("ref") or not citation.get("value"):
            continue
        try:
            canon.check_citation(citation["ref"], citation["value"])
        except canon.CanonError as exc:
            failures.append(f"{where}: {exc}")
        check_binding(where, citation, record, failures, changed_paths)

    wanted = required_corpora(manifest)
    for index, absence in enumerate(absences):
        where = f"{rel}: canon_absent[{index}]"
        strings = absence.get("strings") or []
        searched = {(c.get("source"), c.get("locale")) for c in (absence.get("searched") or [])}
        if not strings:
            failures.append(f"{where}: `strings` is required -- an absence claim names what is absent")
        if not absence.get("why_runtime"):
            failures.append(f"{where}: `why_runtime` is required -- say why a measurement is the only route")

        missing = sorted(wanted - searched)
        if missing:
            failures.append(
                f"{where}: did not search {missing}. An absence claim must search EVERY corpus "
                f"this build pins, in every locale. A string absent from Logic is absent from all "
                f"of them, so proving it in all of them is what the claim means -- and deriving "
                f"the set from `host.locale` only moved the author's choice, it did not remove it.")

        #: The values this record cites, folded the way a near miss is folded. A `canon_absent`
        #: entry whose folded form is among them has already named the spelling Logic ships.
        cited_folded = {canon.fold_for_near_miss(c["value"])
                        for c in citations if c.get("value")}

        for text in strings:
            folded_is_cited = canon.fold_for_near_miss(text) in cited_folded
            # Absent from ALL of them, not from ANY of them. `any` let a claim stand on the one
            # corpus that happened not to hold the string.
            for source, corpus_locale in sorted(searched):
                try:
                    if not canon.is_absent(source, corpus_locale, text):
                        failures.append(
                            f"{where}: {text!r} is PRESENT in {source}/{corpus_locale}. It can be "
                            f"cited, so it must be, and a measurement is not the only route to it.")
                    elif (canon.differs_only_by_decoration(source, corpus_locale, text)
                          and not folded_is_cited):
                        # Absent AS BYTES, and a shipped label folds to it -- a colon, an ellipsis,
                        # a capital, a space. `is_absent` is exact and this rule used to ask
                        # nothing else, so a truncated or decorated reading proved "uncitable" for
                        # a label Logic ships. `Input Port:`, `Output Port:` and `Model:` were each
                        # proved absent from all 24 corpora while Logic ships them without the
                        # colon, and none had been read off a screen. The CLI has answered NOT
                        # PROVEN for this since it was written; the rule that gates a RECORD did
                        # not ask, which is two definitions of "in the corpus" in one system.
                        #
                        # `folded_is_cited` is what keeps the rule from refusing the honest case.
                        # Sometimes the decoration IS the finding -- `Set Locators…` is absent
                        # everywhere and Apple ships `Set Locators`, and saying so is the point of
                        # the record. A record that has read the shipped spelling can CITE it, and
                        # one that has not is guessing. So the near miss is allowed exactly when
                        # the record also carries a citation whose value folds to the same thing.
                        failures.append(
                            f"{where}: {text!r} is absent from {source}/{corpus_locale} as bytes, "
                            f"but a string Logic ships folds to it -- they differ only by case or "
                            f"decoration, and this record cites no value that folds to it. Either "
                            f"the reading was typed rather than read, or the shipped spelling is "
                            f"the finding; if it is the finding, cite it in `canon` so the record "
                            f"says which spelling Logic actually has.")
                except canon.CanonError as exc:
                    failures.append(f"{where}: {exc}")


#: The one sentence a pull request or issue may write instead of a citation. Deliberately a fixed
#: phrase rather than a checkbox: a checkbox is ticked without reading, and a sentence somebody has
#: to type is a sentence somebody has to mean.
NO_FACT_OPT_OUT = "states no fact about Logic"

#: Paths whose contents ARE claims about Logic. A change touching one of these may not use the
#: opt-out, whatever its description says.
#:
#: This exists because the opt-out was a substring search over the whole body, and review
#: 2026-09-15 walked straight through it: a description that asserted Logic's Korean AXHelp for the
#: tuner button and then ended with the sentence passed -- as did the same text with the sentence
#: hidden in an HTML comment, and in a fenced code block. Worse than any single bypass was the
#: shape: writing a `logic-canon://` reference by hand is work and typing one sentence is not, so
#: the cheapest honest-looking path led away from the rule.
#:
#: Whether a change states a fact about Logic is therefore derived from WHAT IT TOUCHES.
#: Read from a FILE so the merge-base ratchet can see it, and so a new Logic-facing directory
#: cannot appear without the list learning about it. Held as a tuple first, and two directories
#: that declare LabelSets were not in it -- `SelectorAtlas/` and the package root -- so a change
#: touching only those could say it states no fact about Logic while editing code that matches
#: Logic's interface.
LOGIC_FACING_PATH = os.path.join(REPO, "docs", "canon", "LOGIC-FACING.json")

#: Directories holding Swift that matches Logic's interface. `Scripts/livekit` was not scanned for
#: LabelSets: five CJK literals live in those harnesses and nothing saw them.
SWIFT_ROOTS = ("Sources", os.path.join("Scripts", "livekit"))


def logic_facing_prefixes() -> list:
    """The prefixes, refusing an absent or empty file rather than returning nothing.

    `_waiver` returns an empty set for a file that does not exist, which is right for a waiver --
    nothing is waived -- and catastrophic here: no prefixes means nothing is Logic-facing means
    every change may use the opt-out. The one place the same helper has to fail the other way.
    """
    if not os.path.exists(LOGIC_FACING_PATH):
        raise CanonWaiverError(
            f"{os.path.relpath(LOGIC_FACING_PATH, REPO)} is missing. Without it no path is "
            f"Logic-facing and every change may use the opt-out, so this refuses rather than "
            f"quietly allowing everything.")
    prefixes = sorted(_waiver(LOGIC_FACING_PATH, "prefixes"))
    if not prefixes:
        raise CanonWaiverError(
            f"{os.path.relpath(LOGIC_FACING_PATH, REPO)} lists no prefixes, which would make "
            f"every change eligible for the opt-out.")
    return prefixes


def check_labelsets_are_logic_facing(failures: list) -> None:
    """Rule 14: a file that declares a LabelSet is Logic-facing, and must be declared one.

    The list decides whether a change may use the opt-out, so a file matching Logic's interface
    from outside it is a file whose change can say it states no fact about Logic. Two did. This
    makes the list self-maintaining: declare a LabelSet somewhere new and the list must learn
    about it in the same change.
    """
    try:
        prefixes = logic_facing_prefixes()
    except CanonWaiverError as exc:
        failures.append(str(exc))
        return
    for root in SWIFT_ROOTS:
        base_dir = os.path.join(REPO, root)
        if not os.path.isdir(base_dir):
            continue
        for base, dirs, files in os.walk(base_dir):
            dirs[:] = [d for d in dirs if d != ".build"]
            for name in sorted(files):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(base, name)
                with open(path, "r", encoding="utf-8", errors="replace") as handle:
                    if "LabelSet(" not in handle.read():
                        continue
                rel = os.path.relpath(path, REPO)
                if not any(rel.startswith(prefix) for prefix in prefixes):
                    failures.append(
                        f"{rel} declares a LabelSet and is under no prefix in "
                        f"{os.path.relpath(LOGIC_FACING_PATH, REPO)}. A file that matches Logic's "
                        f"interface is Logic-facing, and a change touching only such files could "
                        f"otherwise use the opt-out.")


#: A fence as GitHub opens one. A backtick fence's info string cannot hold a backtick: "```x```" on
#: one line is an inline span, not a fence.
_FENCE_OPEN = re.compile(r"(`{3,}|~{3,})(.*)$")
_QUOTE_MARKER = re.compile(r" {0,3}> ?")
#: Lines after which an indented line cannot be a paragraph's continuation, so it opens code.
_ENDS_A_BLOCK = re.compile(r"#{1,6}(?:\s|$)|(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,}|=+\s*)$")


def _without_code_blocks(text: str) -> str:
    """`text` with every line GitHub renders as a code block blanked.

    Only closed triple-backtick fences used to be removed, so a record named in a `~~~` fence, an
    unclosed fence or an indented block counted as named in prose (review of #975). Every doubt
    resolves toward hiding, because a line hidden wrongly costs a refusal the contributor can read
    and a line shown wrongly is a way past the check. Three places are hidden that GitHub shows as
    prose, measured through its renderer (`gh api markdown`, gfm) on 2026-09-24: text indented four
    or more columns after a blank line inside a list item, and text after a fence that GitHub
    closes where its list item or its quote ends.
    """
    kept = []
    fence = None
    block_start, in_indented, last_depth = True, False, 0
    for raw in text.expandtabs(4).split("\n"):
        depth, line = 0, raw
        while (marker := _QUOTE_MARKER.match(line)):
            depth, line = depth + 1, line[marker.end():]
        if depth != last_depth:
            block_start, last_depth = True, depth
        indent = len(line) - len(line.lstrip(" "))
        stripped = line.strip()
        if fence is not None:
            depth_open, char, length, indent_open = fence
            if (depth == depth_open and indent <= max(3, indent_open)
                    and re.fullmatch(re.escape(char) + "{%d,}" % length, stripped)):
                fence, block_start = None, True
            kept.append("")
            continue
        opened = _FENCE_OPEN.match(line.lstrip(" "))
        if opened and not (opened.group(1)[0] == "`" and "`" in opened.group(2)):
            # Opened at any indentation, although GitHub opens one at three columns at most: a
            # deeper one is either code already or a fence inside a list item.
            fence = (depth, opened.group(1)[0], len(opened.group(1)), indent)
            kept.append("")
            continue
        if not stripped:
            block_start = True
            kept.append("")
            continue
        if indent >= 4 and (block_start or in_indented):
            in_indented = True
            kept.append("")
            continue
        in_indented = False
        block_start = indent < 4 and bool(_ENDS_A_BLOCK.match(stripped))
        kept.append(raw)
    return "\n".join(kept)


def _visible(body: str) -> str:
    """The body with code blocks and HTML comments removed.

    The opt-out sentence is a promise to a reader, and a named record is a claim to one. Text a
    reader does not see, or sees as an example, cannot carry either, and both hiding places were
    used against this check before it did this. An unclosed comment hides everything after it.
    Raw HTML elements such as `<pre>` are not parsed.
    """
    text = re.sub(r"<!--.*?-->", " ", body.replace("\r\n", "\n").replace("\r", "\n"), flags=re.S)
    unclosed = text.find("<!--")
    if unclosed != -1:
        text = text[:unclosed]
    return re.sub(r"```.*?```", " ", _without_code_blocks(text), flags=re.S)


def logic_facing_exceptions() -> set:
    """Files under a Logic-facing prefix that state no fact about Logic.

    `docs/canon/` is a prefix, and two files under it hold the numbers a document may state and the
    paths that are not observation records. A change touching only those has no row of Apple's data
    to cite and could not opt out either, so the only way through was to paste a citation that
    resolves and quote its value in the diff -- manufacturing evidence, which is the failure the
    citation rule exists to prevent. Measured twice on 2026-09-20 (#937): a four-line correction to
    `GUARD-TESTS-BLIND-TO-THEIR-GUARD.json` could not be made, and a new ratchet file was moved out
    of `docs/canon` for no reason but this rule.

    The list was six entries until #951. The other four governed CI rather than Logic and moved to
    `.github/ci/`, which is under no prefix here, so they need no exemption -- a file in the right
    place beats a file with a note saying it is an exception, because the exemption is one rename
    away from lapsing and the location is not.

    An empty or absent list is the STRICT direction -- everything under a prefix stays Logic-facing
    -- so it is read leniently here and the entries are proved below instead.
    """
    try:
        return set(_waiver(LOGIC_FACING_PATH, "exceptions"))
    except CanonWaiverError:
        return set()


def check_exceptions_state_no_fact(failures: list) -> None:
    """Rule 15: an exception must be a file that cites nothing and quotes nothing citable.

    The list says "this file states no fact about Logic", and that is checkable rather than
    promised: a file carrying a `logic-canon://` reference is citing Logic, and one quoting a
    string the corpus holds is stating a fact about it. Either way the exemption is wrong and the
    file is Logic-facing after all.
    """
    for rel in sorted(logic_facing_exceptions()):
        path = os.path.join(REPO, rel)
        if not os.path.exists(path):
            failures.append(
                f"docs/canon/LOGIC-FACING.json excepts {rel}, which does not exist. An exemption "
                f"for a file that is gone is a line nobody can check -- delete it; the list may "
                f"shrink.")
            continue
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            body = handle.read()
        references = canon.find_refs(body)
        if references:
            failures.append(
                f"{rel} is excepted from the Logic-facing prefixes and carries "
                f"{len(references)} canonical reference(s), first {sorted(references)[0]}. A file "
                f"that cites Logic is not a file that states no fact about it.")
        try:
            quoted = _citable_strings_in(body, strict=True)
        except CitableScanFailed as exc:
            failures.append(
                f"{rel} is excepted from the Logic-facing prefixes and whether it quotes a value "
                f"Logic ships could not be answered: {exc}. An exemption resting on a corpus "
                f"nobody could read is an exemption nobody checked.")
            continue
        if quoted:
            failures.append(
                f"{rel} is excepted from the Logic-facing prefixes and quotes "
                f"{len(quoted)} string(s) the pinned corpus holds, first {quoted[0][:40]!r}. "
                f"Quoting a value Logic ships is stating a fact about Logic.")


def logic_facing(changed):
    """The changed paths whose contents are claims about Logic.

    A path under a prefix is Logic-facing UNLESS it is named in `exceptions`, and those entries are
    proved by `check_exceptions_state_no_fact` on every run rather than taken on trust.
    """
    prefixes = logic_facing_prefixes()
    excepted = logic_facing_exceptions()
    return sorted({path for path in (changed or [])
                   if any(path.startswith(prefix) for prefix in prefixes)
                   and path not in excepted})



#: STABLE DIAGNOSTIC CODES, emitted by `--format json` and keyed on by the advisory issue bot.
#:
#: There is ONE evaluation and two renderings of it. The bot does not parse this file's stderr --
#: that was the shape the old `canon-issue.yml` had, and it is why a corpus failure and a missing
#: citation reached a contributor as the same sentence accusing them of an uncited claim. Adding a
#: code is additive. Changing what an existing one MEANS is a breaking change for that workflow.
MISSING_DECLARATION = "missing_declaration"
HIDDEN_DECLARATION = "hidden_declaration"
DECLARATION_QUOTES_CORPUS = "declaration_quotes_corpus"
LOGIC_FACING_OPT_OUT = "logic_facing_opt_out"
INVALID_REFERENCE = "invalid_reference"
MISSING_QUOTED_VALUE = "missing_quoted_value"
UNRELATED_BINDING = "unrelated_binding"
UNPROVED_EXCEPTIONS = "unproved_exceptions"
BEHAVIOURAL_RECORD_REFUSED = "behavioural_record_refused"
EMPTY_CHANGED_LIST = "empty_changed_list"
INPUT_UNREADABLE = "input_unreadable"
CHECKER_ERROR = "checker_error"

#: SATISFIED means the evidence-format requirements are met, not that anything about Logic was
#: verified. ACTIONABLE means the author can fix a named problem. ERROR means the evaluation did
#: not finish -- a corpus, a file or the checker itself -- and says nothing about the author.
SATISFIED = "satisfied"
ACTIONABLE = "actionable"
ERROR = "error"

#: 0 and 1 are what every caller before this saw and are unchanged. ERROR is 2, and it is still
#: NONZERO on purpose: `pr-policy.yml` runs this as a required check, and a check that could not
#: evaluate has not passed. Advisory issue intake is the only place the distinction softens
#: anything, and that softening is in the bot's wording, not in an exit code.
EXIT_FOR = {SATISFIED: 0, ACTIONABLE: 1, ERROR: 2}


class Diagnosis:
    """What one evaluation of a body found: a category, and findings that carry a stable code."""

    def __init__(self, category: str, findings=None, references: int = 0, records=None):
        self.category = category
        self.findings = list(findings or [])
        self.references = references
        #: The behavioural records that satisfied a Logic-facing body with no citation. Empty for
        #: every other outcome, including every issue body.
        self.records = list(records or [])

    def as_dict(self) -> dict:
        return {
            "category": self.category,
            "references": self.references,
            "records": list(self.records),
            "diagnostics": [{"code": code, "message": message}
                            for code, message in self.findings],
        }


def _require_readable_index(ref) -> None:
    """Refuse to judge a citation against an index this run could not read.

    Three failures wore the same word before this. A missing index file made `load_index` return
    an empty table, so every reference "is not in docs/canon/index/<source>.tsv". A malformed row
    made it raise the base `CanonError`, which the caller filed as the reference being invalid. A
    missing value index made `resolve_offline` say no value citation for the source is pinned. All
    three are this repository's corpus, and all three arrived at the contributor as a claim about
    the reference THEY typed.

    A reference that does not resolve against an index this run CAN read is still the author's --
    that is the ordinary unknown-key case and it stays actionable.
    """
    if ref.is_value_citation:
        path = canon.value_index_path(ref.source)
        if not os.path.exists(path):
            raise CanonIndexUnavailable(
                f"{path} does not exist, so no value citation for {ref.source} can be checked "
                f"here. Run Scripts/logic_canon.py build on a machine with Logic. Nothing is "
                f"being asserted about the citation.")
        # The same second question the key branch asks below. Existence is not readability: a
        # `.values.tsv` row with the wrong field count raises the base `CanonError` out of
        # `load_value_index`, and without this the two branches would answer differently about
        # the same repository-side fault -- which is the asymmetry this function exists to close.
        try:
            canon.load_value_index(ref.source)
        except canon.CanonError as exc:
            raise CanonIndexUnavailable(f"{path} could not be read: {exc}") from exc
        return
    path = canon.index_path(ref.source)
    if not os.path.exists(path):
        raise CanonIndexUnavailable(
            f"{path} does not exist, so no reference for {ref.source} can be resolved here. Run "
            f"Scripts/logic_canon.py build on a machine with Logic. Nothing is being asserted "
            f"about the citation.")
    try:
        canon.load_index(ref.source)
    except canon.CanonError as exc:
        raise CanonIndexUnavailable(f"{path} could not be read: {exc}") from exc


#: A record path as a body names it: in prose, in inline backticks, or as a link target. Read only
#: from `_visible(body)` -- a record named in a fence or an HTML comment is an example, not a claim.
_RECORD_NAMED = re.compile(r"(?<![\w.-])docs/observations/[\w.-]+\.json")

OBSERVATIONS_PREFIX = "docs/observations/"


def _observation_validator():
    """`check-observation-records.py`, loaded from this tree the way `logic_canon` is.

    Loaded when a body names a record rather than at import, so a checker run that never reaches
    the record route does not depend on it. Without it this route restated the record schema and
    passed records the validator refuses, a schema 4 one and one whose `depends` symbol does not
    exist (review of #975).
    """
    path = os.path.join(REPO, "Scripts", "check-observation-records.py")
    spec = importlib.util.spec_from_file_location("observation_records_for_guard", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _why_record_refused(rel: str, changed: set, touched: set, quoted: list):
    """The first condition a named behavioural record fails, or None when it accepts the body.

    A change whose evidence is BEHAVIOURAL -- what an element does, not what a string says -- has
    no row of Apple's data to cite, and faking a label citation for it is the perfunctory evidence
    this axis exists to end. The record category for that claim already exists (rule 13), so the
    body may rest on one. Each condition closes a way to borrow somebody else's evidence: a record
    this change does not write, a record that is not the category, a declaration rule 13 refuses,
    a record about code this change does not touch, and a body that quotes a string Logic ships
    while claiming nothing it says is a label.

    The code has to be a Logic-facing file outside `docs/`, because the record stands in for the
    citation that file's change owes. Any changed path used to count, so a record depending on the
    roadmap let a change that edits no code through (review of #975).
    """
    if rel not in changed:
        return ("it is not in this change's file list. The record has to be written or edited by "
                "the change it is evidence for.")
    path = os.path.join(REPO, rel)
    if path not in observation_records():
        return (f"no observation record exists at that path in this tree. Records are "
                f"date-prefixed files under {OBSERVATIONS_PREFIX}.")
    refusals = _observation_validator().check(path)
    if refusals:
        return f"check-observation-records.py refuses it: {refusals[0]}"
    try:
        with open(path, "r", encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, ValueError) as exc:
        return f"it does not parse as JSON: {exc}"
    if not isinstance(record, dict):
        return "it is not a JSON object."
    schema = record.get("schema", 1)
    if not isinstance(schema, int) or schema < 3:
        return f"it is at schema {schema!r}; a behavioural record is schema 3."
    if "canon_not_applicable" not in record:
        return ("it carries no `canon_not_applicable`. A record that cites or proves absence is "
                "evidence about a label; cite that label here instead.")
    failures: list = []
    check_not_applicable(rel, record, canon.load_manifest(), failures)
    if failures:
        return f"rule 13 refuses its declaration: {failures[0]}"
    depends = record.get("depends")
    code_paths = [entry.split(":", 1)[0] for entry in (depends if isinstance(depends, list) else [])
                  if isinstance(entry, str)]
    if not any(path_ in touched and not path_.startswith("docs/") for path_ in code_paths):
        return (f"none of its `depends` {code_paths} is Logic-facing code this change edits, "
                f"outside docs/. A behavioural record is evidence for the code it depends on, "
                f"and this change touches none of it.")
    if quoted:
        return (f"the body quotes {len(quoted)} string(s) the corpus holds, first "
                f"{quoted[0][:50]!r}. A body quoting a string Logic ships is stating a label fact, "
                f"and a label fact is cited, not carried by a behavioural record.")
    return None


def _behavioural_records(body: str, changed_paths, touched: list, label: str):
    """A Diagnosis when the visible body names observation records, else None."""
    named = sorted(set(_RECORD_NAMED.findall(_visible(body))))
    if not named:
        return None
    changed = set(changed_paths or [])
    quoted = _citable_strings_in(body)
    accepted, refused = [], []
    for rel in named:
        why = _why_record_refused(rel, changed, set(touched), quoted)
        if why is None:
            accepted.append(rel)
        else:
            refused.append(f"  {rel}: {why}")
    if accepted:
        return Diagnosis(SATISFIED, records=accepted)
    detail = "\n".join(refused)
    return Diagnosis(ACTIONABLE, [(BEHAVIOURAL_RECORD_REFUSED, (
        f"{label}: no canonical reference, and none of the {len(named)} behavioural record(s) "
        f"this body names carries it. This change edits {len(touched)} Logic-facing file(s), "
        f"first {touched[0]}.\n{detail}\n"
        f"  See docs/canon/README.md."))])


def diagnose_text(body: str, changed_paths=None, *, require_changed: bool = False,
                  label: str = "<body>") -> Diagnosis:
    """Evaluate a pull request or issue body and return what was found.

    The tree-wide check cannot see this text -- a pull request body is not a file in the tree, and
    that is exactly where the rule was named and not enforced. `docs/canon/README.md` says every
    artefact this repository produces cites Logic or says it cannot; without this, "every artefact"
    meant "every file", and the two documents a change is actually reviewed through were exempt.

    Raising is how this reports that it could not evaluate. `check_text` turns that into ERROR;
    nothing here returns SATISFIED for a lookup that did not happen.
    """
    if require_changed and not changed_paths:
        return Diagnosis(ACTIONABLE, [(EMPTY_CHANGED_LIST, (
            f"{label}: the list of changed files is empty, so whether this change may opt out "
            f"cannot be derived.\n"
            f"  A pull request changes something. An empty list means the diff command failed, "
            f"and the CI step's\n"
            f"  `||` fallback turns that into a file with nothing in it -- which used to REOPEN "
            f"the opt-out for a\n"
            f"  change that edits Logic-facing paths. Fail closed instead."))])

    touched = logic_facing(changed_paths)
    # The exceptions NARROW that set, so the opt-out below can rest on them -- and rule 15 is what
    # proves an exception. It runs in the tree check, which is a different invocation: a co-reader
    # pointed out that `--text` returns before it, so this path was trusting a list the run had not
    # checked. In CI the tree check is a required command and does run, but a rule that is only
    # sound because another step happened is a rule with an undeclared dependency.
    #
    # `changed_paths and` is the SCOPE of that proof, and it is deliberate. With no changed paths
    # -- an issue body, or `--text` without `--changed-paths` -- `logic_facing()` returns the empty
    # set whatever the exceptions say, so nothing here rests on the list and there is nothing to
    # prove. Read the proof as covering the pull-request path, which is the only one where the list
    # narrows anything; a bare `--text` run still does not check it.
    if changed_paths and logic_facing_exceptions():
        proof: list = []
        check_exceptions_state_no_fact(proof)
        if proof:
            detail = "\n".join(f"  {line}" for line in proof)
            return Diagnosis(ACTIONABLE, [(UNPROVED_EXCEPTIONS, (
                f"{label}: the Logic-facing exceptions are not proved, so nothing here may narrow "
                f"what counts as a claim about Logic:\n{detail}"))])

    references = canon.find_refs(body)
    if not references:
        if touched:
            behavioural = _behavioural_records(body, changed_paths, touched, label)
            if behavioural is not None:
                return behavioural
            return Diagnosis(ACTIONABLE, [(LOGIC_FACING_OPT_OUT, (
                f"{label}: no canonical reference, and this change may not opt out: it edits "
                f"{len(touched)} file(s)\n  whose contents are claims about Logic, first "
                f"{touched[0]}.\n"
                f"  Cite what those claims rest on. See docs/canon/README.md. A change whose "
                f"evidence is behaviour, not a string, may instead name the schema-3 "
                f"`canon_not_applicable` record it adds."))])
        if NO_FACT_OPT_OUT in _visible(body):
            # ...unless the body QUOTES something citable. The opt-out says "this states no fact
            # about Logic", and a body carrying a string Logic ships is stating one. This is the
            # only check available for an issue, which changes no files and so has nothing to
            # derive the opt-out from -- and it tightens the pull request path for free.
            quoted = _citable_strings_in(body)
            if quoted:
                return Diagnosis(ACTIONABLE, [(DECLARATION_QUOTES_CORPUS, (
                    f"{label}: says {NO_FACT_OPT_OUT!r} and quotes {len(quoted)} string(s) the "
                    f"corpus holds, first {quoted[0][:50]!r}.\n"
                    f"  A body that quotes a string Logic ships is stating a fact about Logic. "
                    f"Cite it."))])
            return Diagnosis(SATISFIED)
        # WHICH of the two is wrong decides what to say. A declaration typed into a code fence or
        # an HTML comment is a contributor who followed the instruction and got the rendering
        # wrong, and telling them "no opt-out" sends them to write a sentence they already wrote.
        # `_visible()` is NOT relaxed to accept it -- three earlier bypasses came out of that -- so
        # the repair is to name the place it is hiding.
        if NO_FACT_OPT_OUT in body:
            return Diagnosis(ACTIONABLE, [(HIDDEN_DECLARATION, (
                f"{label}: the sentence {NO_FACT_OPT_OUT!r} is in this text, but only inside a "
                f"code block or an\n"
                f"  HTML comment, and those are deliberately not read -- a declaration that "
                f"renders as an example\n"
                f"  is not a declaration. A fence of backticks or tildes, closed or not, and text "
                f"indented four\n"
                f"  columns after a blank line are code blocks. Move it into ordinary visible "
                f"prose, with the reason.")
            )])
        return Diagnosis(ACTIONABLE, [(MISSING_DECLARATION, (
            f"{label}: no canonical reference, and no opt-out.\n"
            f"  Cite what this rests on, or write the sentence {NO_FACT_OPT_OUT!r} with the\n"
            f"  reason -- outside any code block or HTML comment. See docs/canon/README.md."))])

    findings = []
    for ref_text in references:
        try:
            ref = canon.CanonRef.parse(ref_text)
        except canon.CanonRefError as exc:
            # The citation STRING is malformed. That is the author's to fix and nothing else here
            # was consulted to say so.
            findings.append((INVALID_REFERENCE, f"{label}: {exc}"))
            continue
        _require_readable_index(ref)
        try:
            canon.resolve_offline(ref)
        except canon.CanonResolveError as exc:
            # A well-formed reference against an index this run could read: the key is not there.
            findings.append((INVALID_REFERENCE, f"{label}: {exc}"))

    # A reference is only half of a citation. The value it resolves to must be in the text too, or
    # the reader cannot tell what was claimed -- and the digest check has nothing to compare.
    folded = canon.normalize(body)
    for ref_text in references:
        try:
            ref = canon.CanonRef.parse(ref_text)
        except canon.CanonRefError:
            continue
        # No `_require_readable_index` here. The loop above already ran it for every reference
        # that parses, over the same references and the same sources, and raised if any index was
        # unreadable -- so reaching this line means they all were. A second call would be a second
        # place deciding the same thing, and the mutation that deleted one of them survived.
        try:
            committed = canon.resolve_offline(ref)
        except canon.CanonResolveError:
            continue
        if not _quotes_the_value(folded, ref, committed):
            findings.append((MISSING_QUOTED_VALUE, (
                f"{label}: {ref} appears without the value it resolves to. A reference alone is a "
                f"key anybody can type; the citation is the reference AND the value.")))

    # A CITATION MUST BEAR ON WHAT CHANGED. Until 2026-09-19 any resolving reference satisfied this
    # rule: paste the Install.strings reference and `설치` on its own line, change two Logic-facing
    # files that have nothing to do with either, and the body printed "1 citation(s) resolved".
    # The rule said "cite what those claims rest on" and enforced "cite something".
    #
    # The binding is deliberately loose: ONE reference has to be relevant to ONE changed file,
    # where relevant means the reference string or the quoted value appears in that file's
    # post-change contents. A `derivedFrom` satisfies it by construction, which is the common case;
    # a document that quotes a value it is writing about satisfies it too. Both pull request bodies
    # this branch descends from bind 2 of 2 references under it, measured before it was written.
    if touched and references and not findings:
        relevant = _citation_bears_on(references, body, changed_paths)
        if not relevant:
            findings.append((UNRELATED_BINDING, (
                f"{label}: cites {len(references)} reference(s) and none of them bears on anything "
                f"this change touches. A citation that could sit on any pull request is not "
                f"evidence for THIS one -- cite the row the change rests on, or say what the "
                f"cited row has to do with the files being changed by quoting its value where "
                f"they use it.")))

    if findings:
        return Diagnosis(ACTIONABLE, findings, references=len(references))
    return Diagnosis(SATISFIED, references=len(references))


def check_text(path: str, changed_paths=None, *, require_changed: bool = False,
               as_json: bool = False) -> int:
    """Render one evaluation of a body, as prose or as JSON, and return its exit status.

    ONE evaluation, two renderings. `canon-issue.yml` used to read this function's stderr and turn
    whatever it found into a sentence addressed to the author -- so a corpus that would not load
    reached a first-time contributor as an accusation that they had cited nothing. The bot now
    reads `--format json` and keys on the stable codes above; nothing downstream parses prose.
    """
    try:
        with open(path, "r", encoding="utf-8") as handle:
            body = handle.read()
    except OSError as exc:
        diagnosis = Diagnosis(ERROR, [(INPUT_UNREADABLE, f"{path}: {exc}")])
    else:
        try:
            diagnosis = diagnose_text(body, changed_paths,
                                      require_changed=require_changed, label=path)
        except (canon.CanonError, CanonWaiverError, CanonIndexUnavailable,
                CitableScanFailed, OSError) as exc:
            # The evaluation did not finish. That is not the author's doing and must not be
            # reported as though it were -- but it is not a pass either, so the status is nonzero.
            diagnosis = Diagnosis(ERROR, [(CHECKER_ERROR, (
                f"{path}: this check could not evaluate the text: {type(exc).__name__}: {exc}\n"
                f"  Nothing about the body is being asserted. This is a repository-side "
                f"failure."))])

    if as_json:
        json.dump(diagnosis.as_dict(), sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return EXIT_FOR[diagnosis.category]

    if diagnosis.category == SATISFIED:
        if diagnosis.references:
            print(f"{path}: {diagnosis.references} citation(s) resolved")
        elif diagnosis.records:
            print(f"{path}: no citation; satisfied by the behavioural record(s) "
                  f"{', '.join(diagnosis.records)}")
        else:
            print(f"{path}: no citation, and it says so: {NO_FACT_OPT_OUT!r}")
        return EXIT_FOR[SATISFIED]

    if len(diagnosis.findings) > 1:
        print(f"{path}: {len(diagnosis.findings)} failure(s)", file=sys.stderr)
    for _code, message in diagnosis.findings:
        print(message, file=sys.stderr)
    return EXIT_FOR[diagnosis.category]


#: Shortest quoted run worth testing. Below this a fragment hits the corpus by coincidence.
CITABLE_QUOTE_MIN = 6


class CitableScanFailed(Exception):
    """A corpus lookup failed, so "quotes nothing citable" is UNKNOWN rather than true."""


def _citable_strings_in(body: str, strict: bool = False) -> list:
    """Quoted or backticked runs in the body that the pinned corpus actually holds.

    Only text the author DELIMITED -- between quotes or backticks. Scanning whole sentences would
    hit every common word; scanning what somebody set apart as a string is scanning what they meant
    as one.

    `strict` decides what a failed lookup means. Reading a pull request body, an unreadable corpus
    makes this scan advisory and the citation rules around it still apply, so the failure is
    skipped. As EVIDENCE FOR AN EXEMPTION it is the opposite: "this file quotes nothing Logic
    ships" would be answered from a corpus nobody could read, which is the shape of every silent
    pass this repository removes. A co-reader found it by simulating a failure of every lookup --
    `"Audio Units"` then came back clean.
    """
    manifest = canon.load_manifest()
    corpora = sorted(required_corpora(manifest))
    found = []
    for candidate in re.findall(r'[`"\u201c\u2018]([^`"\u201d\u2019\n]{%d,120})[`"\u201d\u2019]'
                                % CITABLE_QUOTE_MIN, body):
        text = canon.normalize(candidate)
        if not text:
            continue
        for source, locale in corpora:
            try:
                if not canon.is_absent(source, locale, text):
                    found.append(text)
                    break
            except canon.CanonError as exc:
                if strict:
                    raise CitableScanFailed(f"{source}/{locale}: {exc}") from exc
                continue
    return found


_DERIVED_FROM_SITE = {}


def _is_derived_from(rel: str, ref_text: str) -> bool:
    """Whether this reference appears in that file only as the value of a `derivedFrom:` field."""
    if rel not in _DERIVED_FROM_SITE:
        try:
            with open(os.path.join(REPO, rel), encoding="utf-8", errors="replace") as handle:
                body = handle.read()
        except OSError:
            body = ""
        _DERIVED_FROM_SITE[rel] = set(
            re.findall(r'derivedFrom:\s*"([^"]*)"', body))
    return ref_text in _DERIVED_FROM_SITE[rel]


def _citation_bears_on(references, body: str, changed_paths) -> bool:
    """Whether any cited reference is relevant to any changed file.

    Relevant = the reference STRING appears in the file (what `derivedFrom` gives, and the common
    case), or a value the body quotes for it appears there (what a document writing about a label
    gives). Read from the working tree, which in CI is the pull request's own checkout.

    A file this cannot read is skipped rather than counted against the change: a deleted path is in
    the changed list and has no contents, and refusing for that would fail a change for the shape
    of its diff rather than for what it claims.
    """
    quoted = [line.strip() for line in body.splitlines() if line.strip()]
    for path in (changed_paths or []):
        try:
            with open(os.path.join(REPO, path), encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError:
            continue
        for ref_text in references:
            if ref_text in text:
                return True
        # A quoted value is only evidence if the body actually quoted it for a reference, which
        # `_quotes_the_value` has already established for every reference that got this far.
        for line in quoted:
            if len(line) >= CITABLE_QUOTE_MIN and line in text and canon.find_refs(line) == []:
                for ref_text in references:
                    try:
                        ref = canon.CanonRef.parse(ref_text)
                    except canon.CanonError:
                        continue
                    if _quotes_the_value(canon.normalize(line), ref,
                                         canon.resolve_offline(ref) if ref.key else ""):
                        return True
    return False


def _quotes_the_value(folded_body: str, ref, committed: str) -> bool:
    """Whether some line of the body hashes to the digest the index pins for this reference.

    Line by line, and by DIGEST rather than by substring, because the body is prose: a value that
    happens to appear inside a sentence is not the same as a value somebody wrote down as the
    quote, and a substring test would accept the former.
    """
    # A VALUE citation has no row and therefore no single `committed` digest: the reference names
    # a corpus and a locale, and WHICH string is the citation's own quote. One reference can
    # legitimately appear twice in a body with two different values -- `Count In` and
    # `Audio Units` are both `logic-canon://strings/en#value`. So the test is that some line is a
    # value `build` pinned for that source and locale, which is the same proof by a different
    # index.
    if ref.is_value_citation:
        pinned = canon.load_value_index(ref.source)
        for line in folded_body.splitlines():
            for candidate in _quote_candidates(line):
                if (ref.locale, canon.short_digest(candidate)) in pinned:
                    return True
        return False
    for line in folded_body.splitlines():
        for candidate in _quote_candidates(line):
            if canon.short_digest(candidate) == committed:
                return True
    return False


def _quote_candidates(line: str):
    """The strings on one line that could be somebody writing the value down as the quote.

    The whole line, and what follows the first colon -- and then the same again with a surrounding
    pair of double quotes and a trailing comma removed, because the places a citation now lives
    include Swift and JSON, where a value is written `canonical: "File",` and never bare. Without
    that, a `logic-canon://` reference can only be quoted in prose, which pushes it out of the
    source file it is about and into a document that drifts from it.

    Still by DIGEST and still per line: a value that happens to appear inside a sentence is not a
    value somebody wrote down, and the candidate has to BE the value, not contain it.
    """
    text = line.strip()
    seen = set()
    for candidate in (text, text.split(":", 1)[-1].strip()):
        for form in (candidate, _unquoted(candidate)):
            if form and form not in seen:
                seen.add(form)
                yield form


def _unquoted(text: str) -> str:
    stripped = text.rstrip(",").strip()
    if len(stripped) >= 2 and stripped[0] == '"' and stripped[-1] == '"':
        return stripped[1:-1]
    return ""


USAGE = ("usage: check-canon-citations.py [--changed <file>]\n"
         "       check-canon-citations.py --text <file> [--changed <file>] [--format text|json]")


class UsageError(Exception):
    """The command line did not say what it meant, so nothing is evaluated."""


def _usage(message: str) -> int:
    """Refuse, loudly, with the ERROR status.

    EVERY argument form below used to be POSITIONAL: `--text` had to be argv[1], `--changed` had
    to be argv[3], and the whole `--changed` clause was ignored unless argc was exactly 5. Adding
    `--format` to that shape would have made `--text b.md --format json --changed c.txt` run with
    NO file list -- which is the mode where a change that edits Logic-facing paths may opt out.
    A dropped flag has to be an error rather than a quieter check.
    """
    print(f"check-canon-citations: {message}\n{USAGE}", file=sys.stderr)
    return EXIT_FOR[ERROR]


def _read_list(path: str) -> list:
    with open(path, "r", encoding="utf-8") as handle:
        return [line.strip() for line in handle if line.strip()]


def _parse_argv(argv: list) -> dict:
    """The options in `argv`, or `UsageError`. No option is consumed by position."""
    options = {"text": None, "changed": None, "format": "text"}
    rest = list(argv)
    positional = []
    while rest:
        token = rest.pop(0)
        if token in ("--text", "--changed", "--format"):
            key = token[2:]
            if not rest:
                raise UsageError(f"{token} needs a value")
            if options[key] is not None and key != "format":
                raise UsageError(f"{token} given twice")
            options[key] = rest.pop(0)
        elif token.startswith("-"):
            raise UsageError(f"unknown option {token}")
        else:
            positional.append(token)
    if positional:
        raise UsageError(f"unexpected argument {positional[0]!r}")
    if options["format"] not in ("text", "json"):
        raise UsageError(f"--format takes text or json, not {options['format']!r}")
    if options["format"] == "json" and options["text"] is None:
        raise UsageError("--format applies to --text; the tree-wide run has no JSON rendering")
    return options


def main() -> int:
    try:
        options = _parse_argv(sys.argv[1:])
    except UsageError as exc:
        return _usage(str(exc))
    except OSError as exc:
        return _usage(f"cannot read the changed-file list: {exc}")

    if options["text"] is not None:
        changed, required = [], False
        if options["changed"] is not None:
            required = True
            try:
                changed = _read_list(options["changed"])
            except OSError as exc:
                return _usage(f"cannot read the changed-file list: {exc}")
        return check_text(options["text"], changed, require_changed=required,
                          as_json=options["format"] == "json")

    failures: list = []

    try:
        manifest = canon.load_manifest()
    except canon.CanonError as exc:
        print(f"FAIL {exc}", file=sys.stderr)
        return 1
    if manifest.get("extractor_version") != canon.EXTRACTOR_VERSION:
        failures.append(
            f"docs/canon/MANIFEST.json was built by extractor v{manifest.get('extractor_version')} "
            f"and this code is v{canon.EXTRACTOR_VERSION}. Digests taken by different extractors "
            f"were never comparable, so they are not compared. Rebuild on a machine with Logic.")

    failures.extend(canon.verify_artifacts(manifest))
    failures.extend(canon.verify_absence_counts(manifest))
    failures.extend(canon.verify_index_against_absence())
    check_build_agrees_with_the_ledger(manifest, failures)
    check_waivers_only_shrink(failures)
    check_no_measured_count_shrinks(failures)
    check_every_json_is_a_record_or_declared(failures)
    check_labelsets_are_logic_facing(failures)
    check_exceptions_state_no_fact(failures)
    # None means "do not check which files the change touches", which is the behaviour every run
    # before `--changed` existed had. It is not a default that weakens anything silently: CI passes
    # the list, and a local run without it says less rather than passing something wrong. What is
    # forbidden is reaching that weaker mode BY ACCIDENT, which is why `_parse_argv` refuses a
    # `--changed` with nothing after it instead of behaving like a run that never asked.
    changed = None if options["changed"] is None else _read_list(options["changed"])
    references = check_references(failures)
    without_canon = load_without_canon()
    records = observation_records()
    for path in records:
        # A record this change does not touch keeps whatever bindings it already had. Rule 9 asks
        # whether a citation is load-bearing IN THIS CHANGE, and for an untouched record the
        # honest answer is that this change says nothing about it. Passing `changed` regardless
        # made every record's binding a requirement on every branch: this one edits Swift and not
        # `Scripts/test_logic_canon.py`, so a 2026-09-15 record bound to that file was refused for
        # a file the branch has no reason to open. It had been invisible only because that file
        # happened to change on every previous branch.
        touched = changed is None or os.path.relpath(path, REPO) in changed
        check_record(path, failures, without_canon, manifest, changed if touched else None)

    stale = sorted(without_canon - {os.path.relpath(p, REPO) for p in records})
    for entry in stale:
        failures.append(
            f"docs/canon/WITHOUT-CANON.json lists {entry}, which is not in the tree. A waiver "
            f"naming a file nobody can open is bookkeeping that outlived its reason.")

    if failures:
        print(f"check-canon-citations: {len(failures)} failure(s)\n", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1

    print(f"check-canon-citations: {references} reference(s) resolved, {len(records)} record(s), "
          f"{len(without_canon)} predating the rule "
          f"(Logic {manifest['logic']['version']} build {manifest['logic']['build']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
