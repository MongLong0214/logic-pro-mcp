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
      touching a Logic-facing path, and is not read from a code block or an HTML comment)

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


def _merge_base():
    """The commit this branch forked from, or None when it cannot be read.

    A waiver list that may only shrink has to be compared against something OUTSIDE the branch.
    Comparing it against its own file is what a same-commit edit defeats: add a record at schema 1
    AND add it to the waiver in one commit, and a file-only check sees a consistent tree. Same
    reasoning as `check-observation-ratchets.py`, and it fails outright under CI when the base is
    unreadable rather than degrading to the weaker comparison.
    """
    for ref in ("origin/main", "main"):
        found = subprocess.run(["git", "merge-base", "HEAD", ref],
                               cwd=REPO, capture_output=True, text=True)
        if found.returncode == 0 and found.stdout.strip():
            return found.stdout.strip()
    return None


def _git(*args):
    out = subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def _show_json(sha, path):
    out = subprocess.run(["git", "-C", REPO, "show", f"{sha}:{path}"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return None


def _at_base(base, path):
    """The ratcheted file as the branch departed from it, or (None, why) dressed as None + a note.

    The merge base not carrying the file is NOT the same as the file being new, and this returned
    None for both and the caller skipped. `check-observation-ratchets.py`, one directory over,
    already worked out why that is wrong, and this is the same walk:

      * A delete-then-restore pair reaches a branch too. Treating it as a bootstrap adopts whatever
        the restored file says as the permanent base.
      * `--full-history`, or `rev-list` simplifies through a TREESAME merge and follows one parent,
        so a delete on a side branch hides what the other parent did.
      * In a shallow clone `rev-list` exits 0 with no output, so "no ancestor carries it" is not a
        reading anyone can trust.

    The window this closes is not hypothetical: every ratchet introduced on this branch was
    invisible for exactly this reason, which is how rule 14 and rule 7 came to contradict each
    other without anything firing.
    """
    found = _show_json(base, path)
    if found is not None:
        return found
    history = _git("rev-list", "--full-history", "--max-count=200", base, "--", path)
    for sha in (history or "").split():
        prior = _show_json(sha, path)
        if prior is not None:
            _note(f"{path} is absent at the merge base {base[:8]}; ratcheted against "
                  f"{sha[:8]}, the last ancestor carrying it.")
            return prior
    if _git("rev-parse", "--is-shallow-repository") == "true":
        _note(f"{path}: history is truncated (shallow clone), so 'no ancestor carries it' is not "
              f"a reading anyone can trust. Check out with fetch-depth: 0.")
        return None
    _note(f"{path} is carried by neither the merge base {base[:8]} nor any ancestor, so this is "
          f"the commit that introduces it and its ratchet does not run here. It runs on the next "
          f"branch -- a contradiction introduced with a new list is invisible until then.")
    return None


_SAID = set()


def _note(message):
    """Said once. Two rules ratchet MANIFEST.json, and a note repeated per caller reads as two
    findings rather than one fact about the branch."""
    if message not in _SAID:
        _SAID.add(message)
        print(f"  note: {message}", file=sys.stderr)


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
    ("docs/canon/WITHOUT-CANON.json", "records", "shrink",
     "records predating the canon axis"),
    ("docs/canon/POLICY-LITERALS.json", "literals", "shrink",
     "literals classified as answered nowhere in Logic"),
    ("docs/canon/NOT-A-RECORD.json", "files", "shrink",
     "files in docs/observations that are declared not to be records"),
    ("docs/canon/LOGIC-FACING.json", "prefixes", "grow",
     "path prefixes whose changes may not use the opt-out"),
    ("docs/canon/CI-GATE.json", "required_commands", "grow",
     "commands the required CI gate must carry"),
    ("docs/canon/PROSE-NUMBERS.json", "numbers", "shrink",
     "numbers docs/canon/README.md may state with no artifact behind them", _key_members),
    ("docs/canon/CI-SKIPS.json", "allowed", "shrink",
     "cases guards are allowed to SKIP under CI", _skip_members),
    ("docs/canon/MANIFEST.json", "sources", "grow",
     "the (source, locale) corpora every absence proof searches", _corpus_members),
    ("docs/canon/LABELSETS-WITHOUT-A-ROW.json", "labelsets", "shrink",
     "LabelSets waived from naming the row they are Apple's values of",
     _labelset_waiver_members),
    #: `not_required` was NOT here, and `check-every-ci-job-is-required.py`'s own comment says the
    #: list was moved into a file "so the merge-base ratchet can see it". Only `required_commands`
    #: was listed, so it could not: a change could add a CI job that always fails, waive it in
    #: `not_required` in the same commit, and both guards passed. A waiver for "this job does not
    #: have to be required" is the most load-bearing waiver in the repository, because what it
    #: waives is the gate itself.
    ("docs/canon/CI-GATE.json", "not_required", "shrink",
     "CI jobs that are allowed not to gate a merge", _key_members),
    #: This file DOES NOT EXIST at the time of writing, and that was the hole: the guard reads it
    #: (`check-ax-comparisons-use-labelsets.py`) and skips whatever it names, so anyone could
    #: create it in the same change as the comparison it excuses and nothing compared it to
    #: anything. A ratchet entry on an absent file is not a mistake -- `_members` returns an empty
    #: set for a missing file, so the first version of it is measured against nothing and every
    #: entry in it is a growth that rule 7 refuses.
    ("docs/canon/AX-COMPARISON-WAIVERS.json", "waivers", "shrink",
     "AX comparisons waived from using a LabelSet", _key_members),
    #: Was a Python set literal in the guard that reads it, so "may only shrink" was a comment and
    #: a change could add a guard with no test and waive it in the same diff.
    ("docs/canon/GUARDS-WITHOUT-A-TEST.json", "guards", "shrink",
     "guards with no test that drives them", _key_members),
)


def check_waivers_only_shrink(failures: list) -> None:
    """Rule 7: a waiver list may only shrink, and a requirement list may only grow.

    Compared against `git merge-base`, not against the file itself, because a file-only check is
    what a same-commit edit defeats: add a record at schema 1 AND add it to the waiver in one
    commit, and the tree is internally consistent.
    """
    base = _merge_base()
    under_ci = os.environ.get("CI") == "true"
    if base is None:
        message = ("the merge base could not be read, so a ratcheted list can only be compared "
                   "against its own file -- which a same-commit edit defeats")
        if under_ci:
            failures.append(f"canon ratchets: {message}. A shallow clone has no base; "
                            f"CI must check out with fetch-depth: 0.")
        else:
            print(f"  note: {message}", file=sys.stderr)
        return

    for entry in RATCHETS:
        path, key, direction, what = entry[:4]
        members = entry[4] if len(entry) > 4 else _ratchet_members
        before = _at_base(base, path)
        if before is None:
            # A list no ancestor carries is unratcheted on the branch that introduces it. For a
            # `grow` list that is necessary -- rule 14 refuses a Logic-facing directory that is not
            # in LOGIC-FACING.json, so the commit adding the directory must be able to add the
            # prefix, and refusing it would make the first such change unmergeable.
            #
            # For a `shrink` list it is the abuse itself. A waiver list may only shrink, and a NEW
            # waiver list arriving pre-populated is a growth from nothing that nobody is asked
            # about. `docs/canon/AX-COMPARISON-WAIVERS.json` was exactly this: the AX-comparison
            # guard already read it and skipped whatever it named, the file did not exist, and it
            # was in no ratchet -- so creating it in the same change as the comparison it excuses
            # cost nothing. An empty base is the honest comparison for a waiver: every entry in the
            # first version is new, because before it there was no permission at all.
            if direction != "shrink":
                continue
            if not os.path.exists(os.path.join(REPO, path)):
                # Absent on both sides. A waiver list that does not exist is the good state, and
                # the shape check below would otherwise read "one side does not have the key" as a
                # renamed key. The comparison begins the moment somebody creates the file.
                continue
            # A list that MOVED is not a list that appeared. `KNOWN_BARE` lived as a Python set in
            # the guard that read it, where "may only shrink" was a comment and nothing compared
            # it; moving it into a file is what makes the ratchet possible, and refusing the move
            # would keep every such list in code forever.
            #
            # `migrated_from` is checked, not believed: the named path is read AT THE MERGE BASE
            # and every member of the new list must appear there as a quoted string. A member the
            # predecessor did not carry is still a growth from nothing. That is the difference
            # between a decision and a sentence -- the file cannot authorise itself.
            now_doc = _json(os.path.join(REPO, path), {})
            origin = now_doc.get("migrated_from")
            if origin:
                was_text = _git("show", f"{base}:{origin}") or ""
                if not was_text:
                    failures.append(
                        f"{path}: `migrated_from` names {origin!r}, which the merge base does not "
                        f"carry. A move has a place it moved FROM, and this one cannot be checked.")
                    continue
                strays = sorted(m for m in members(now_doc, key)
                                if f'"{m}"' not in was_text and f"'{m}'" not in was_text)
                if strays:
                    failures.append(
                        f"{path}: {len(strays)} member(s) are not in {origin} at the merge base, so "
                        f"they were not moved, they were added: {', '.join(strays[:6])}. A new "
                        f"exemption lands as a growth however the file it lands in was created.")
                    continue
                _note(f"{path} was migrated from {origin}; every member is one that file already "
                      f"carried at {base[:8]}, so the move is not a growth. The ratchet compares "
                      f"against this file from the next branch on.")
                continue
            before = {key: []}
            _note(f"{path} is carried by no ancestor of {base[:8]}. It is a waiver list, so its "
                  f"first version is compared against an EMPTY set: a new list of exemptions is a "
                  f"growth from nothing, not a bootstrap.")
        now = _json(os.path.join(REPO, path), {})
        if not isinstance(before.get(key), (list, dict)) or not isinstance(now.get(key), (list, dict)):
            failures.append(
                f"{path}: the list this ratchet compares lives under {key!r}, and one side does "
                f"not have it. A renamed key makes the comparison silently empty.")
            continue
        was, is_now = members(before, key), members(now, key)
        if not was and before.get(key):
            # The extractor reads a SHAPE. Change the shape and it returns nothing, the comparison
            # is empty, and the ratchet passes everything -- the failure mode this whole file is
            # about. An empty reading of a non-empty value is a broken extractor, not a clean run.
            failures.append(
                f"{path}: the ratchet read no members out of a non-empty {key!r}. Its extractor "
                f"no longer matches the file's shape, so the comparison would pass anything.")
            continue
        gained = sorted(is_now - was)
        lost = sorted(was - is_now)
        if direction == "shrink":
            for member in gained:
                failures.append(
                    f"{path}: {member!r} was added to the list of {what}. That list may only "
                    f"SHRINK. A change that breaks the rule and waives itself in the same commit "
                    f"passes every check that reads only the tree.")
        else:
            for member in lost:
                failures.append(
                    f"{path}: {member!r} was removed from the list of {what}. That list may only "
                    f"GROW -- it is a requirement, not a waiver, and dropping an entry quietly "
                    f"removes a rule.")


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

    Only six of the twenty-three corpora carry a committed index row, so `verify_index_against_absence`
    -- the one check that could have seen this -- is blind to the other seventeen by construction.

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

        for text in strings:
            # Absent from ALL of them, not from ANY of them. `any` let a claim stand on the one
            # corpus that happened not to hold the string.
            for source, corpus_locale in sorted(searched):
                try:
                    if not canon.is_absent(source, corpus_locale, text):
                        failures.append(
                            f"{where}: {text!r} is PRESENT in {source}/{corpus_locale}. It can be "
                            f"cited, so it must be, and a measurement is not the only route to it.")
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


def _visible(body: str) -> str:
    """The body with fenced code blocks and HTML comments removed.

    The opt-out sentence is a promise to a reader. Text a reader does not see cannot carry it, and
    both hiding places were used against this check before it did this.
    """
    without_comments = re.sub(r"<!--.*?-->", " ", body, flags=re.S)
    return re.sub(r"```.*?```", " ", without_comments, flags=re.S)


def logic_facing(changed):
    prefixes = logic_facing_prefixes()
    return sorted({path for path in (changed or [])
                   if any(path.startswith(prefix) for prefix in prefixes)})



def check_text(path: str, changed_paths=None, *, require_changed: bool = False) -> int:
    """Validate the canonical citations in a pull request or issue body.

    The tree-wide check cannot see this text -- a pull request body is not a file in the tree, and
    that is exactly where the rule was named and not enforced. `docs/canon/README.md` says every
    artefact this repository produces cites Logic or says it cannot; without this, "every artefact"
    meant "every file", and the two documents a change is actually reviewed through were exempt.
    """
    with open(path, "r", encoding="utf-8") as handle:
        body = handle.read()

    if require_changed and not changed_paths:
        print(f"{path}: the list of changed files is empty, so whether this change may opt out "
              f"cannot be derived.\n"
              f"  A pull request changes something. An empty list means the diff command failed, "
              f"and the CI step's\n"
              f"  `||` fallback turns that into a file with nothing in it -- which used to REOPEN "
              f"the opt-out for a\n"
              f"  change that edits Logic-facing paths. Fail closed instead.", file=sys.stderr)
        return 1

    touched = logic_facing(changed_paths)
    references = canon.find_refs(body)
    if not references:
        if touched:
            print(f"{path}: no canonical reference, and this change may not opt out: it edits "
                  f"{len(touched)} file(s)\n  whose contents are claims about Logic, first "
                  f"{touched[0]}.\n"
                  f"  Cite what those claims rest on. See docs/canon/README.md.", file=sys.stderr)
            return 1
        if NO_FACT_OPT_OUT in _visible(body):
            # ...unless the body QUOTES something citable. The opt-out says "this states no fact
            # about Logic", and a body carrying a string Logic ships is stating one. This is the
            # only check available for an issue, which changes no files and so has nothing to
            # derive the opt-out from -- and it tightens the pull request path for free.
            quoted = _citable_strings_in(body)
            if quoted:
                print(f"{path}: says {NO_FACT_OPT_OUT!r} and quotes {len(quoted)} string(s) the "
                      f"corpus holds, first {quoted[0][:50]!r}.\n"
                      f"  A body that quotes a string Logic ships is stating a fact about Logic. "
                      f"Cite it.", file=sys.stderr)
                return 1
            print(f"{path}: no citation, and it says so: {NO_FACT_OPT_OUT!r}")
            return 0
        print(f"{path}: no canonical reference, and no opt-out.\n"
              f"  Cite what this rests on, or write the sentence {NO_FACT_OPT_OUT!r} with the\n"
              f"  reason -- outside any code block or HTML comment. See docs/canon/README.md.",
              file=sys.stderr)
        return 1

    failures = []
    for ref_text in references:
        try:
            ref = canon.CanonRef.parse(ref_text)
            canon.resolve_offline(ref)
        except canon.CanonError as exc:
            failures.append(f"{path}: {exc}")

    # A reference is only half of a citation. The value it resolves to must be in the text too, or
    # the reader cannot tell what was claimed -- and the digest check has nothing to compare.
    folded = canon.normalize(body)
    for ref_text in references:
        try:
            ref = canon.CanonRef.parse(ref_text)
            committed = canon.resolve_offline(ref)
        except canon.CanonError:
            continue
        table = canon.load_index(ref.source)
        del table
        if not _quotes_the_value(folded, ref, committed):
            failures.append(
                f"{path}: {ref} appears without the value it resolves to. A reference alone is a "
                f"key anybody can type; the citation is the reference AND the value.")

    if failures:
        print(f"{path}: {len(failures)} failure(s)", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"{path}: {len(references)} citation(s) resolved")
    return 0


#: Shortest quoted run worth testing. Below this a fragment hits the corpus by coincidence.
CITABLE_QUOTE_MIN = 6


def _citable_strings_in(body: str) -> list:
    """Quoted or backticked runs in the body that the pinned corpus actually holds.

    Only text the author DELIMITED -- between quotes or backticks. Scanning whole sentences would
    hit every common word; scanning what somebody set apart as a string is scanning what they meant
    as one.
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
            except canon.CanonError:
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


def _changed_from_argv():
    """The changed-file list for the tree-wide run, or None when it was not given.

    None means "do not check which files the change touches", which is the behaviour every run
    before this had. It is not a default that weakens anything silently: `--changed` is what CI
    passes, and a local run without it says less rather than passing something wrong.
    """
    if "--changed" in sys.argv:
        index = sys.argv.index("--changed")
        if index + 1 < len(sys.argv):
            with open(sys.argv[index + 1], "r", encoding="utf-8") as handle:
                return [line.strip() for line in handle if line.strip()]
    return None


def main() -> int:
    if len(sys.argv) >= 3 and sys.argv[1] == "--text":
        changed, required = [], False
        if len(sys.argv) == 5 and sys.argv[3] == "--changed":
            required = True
            with open(sys.argv[4], "r", encoding="utf-8") as handle:
                changed = [line.strip() for line in handle if line.strip()]
        return check_text(sys.argv[2], changed, require_changed=required)

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
    changed = _changed_from_argv()
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
