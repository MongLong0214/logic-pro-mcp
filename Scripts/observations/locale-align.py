#!/usr/bin/env python3
"""Read a label's translation out of two censuses of the same walk. ADR-019 D4, step 6.

`locale-propose.py` can only CONFIRM a variant that is already declared: it looks for a string it
was given. The strings that are missing are the ones nobody has written down, so a census full of
them cannot deliver one, and #778 has moved a label at a time because of it.

Two censuses of the SAME surfaces in the same order are more than two lists of strings. Strip the
bracketed titles out of each row's `path` and the remaining skeleton — roles and structure — does
not depend on the UI language, so the two walks can be aligned and each pair read as
`<the en-US string> is <the target string> here`. That is a translation read out of Logic rather
than one somebody produced.

What makes this safe is what it refuses:

  * ALIGNMENT IS A SEQUENCE MATCH, never an index. Measured 2026-09-06 on the 2026-09-05 pair:
    1039 en-US rows against 1031 ja-JP, 886 of which share a skeleton at the same index and 1005 of
    which align as matching blocks. A single inserted row shifts every index after it, and every
    later pair is then wrong while still looking plausible.
  * A PAIR OUTSIDE A MATCHING BLOCK IS DROPPED, never approximated. The 26 unaligned rows are a
    named hole (the Library pane, whose tree differed between the runs), not a rounding error.
  * THE APPLE MENU IS EXCLUDED. Its rows carry the SYSTEM locale, not Logic's, so they say nothing
    about Logic's UI language and would silently certify an unchanged string as a translation.
  * AMBIGUITY IS REPORTED, NEVER RESOLVED. A canonical that appears on several aligned rows whose
    targets disagree has no answer here, and picking the first would write a real record, the right
    role and the right attribute about the wrong element — the defect retracted on 2026-09-05 and
    resurrected on 2026-09-06 (#793).

The BASE census should be the one whose language the labels are named in. A label is matched by its
`canonical`, which is English, so a Korean base finds only the labels Logic leaves untranslated in
Korean — measured 2026-09-06: 29 candidates from en-US against ja-JP, 11 from ko-KR against the
same target. Matching the base against a label's declared VARIANTS as well would lift that, and is
deliberately not done here: it would make the tool's answer depend on evidence the ledger already
holds, and the point of this one is to find strings nothing in the ledger knows.

Nothing is written to the tree, and nothing here edits Swift. It prints candidates; a person adds
the variant to `AXLocalePolicy.swift` and the campaign then backs it with provenance the ordinary
way.
"""
import argparse
import difflib
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

# Every rule this tool shares with the proposer is READ from it. A second implementation of
# "does this string count as seen" is a second answer, which is how the containment sets were
# wrong for 23 of 31 label sets before they were derived rather than guessed.
_spec = importlib.util.spec_from_file_location("locale_propose", os.path.join(HERE, "locale-propose.py"))
_PROPOSE = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_PROPOSE)
_GUARD = _PROPOSE._GUARD

# The Apple menu is macOS's, not Logic's. On this host `시스템 설정…` appears identically in the
# Korean and the English census, because the machine's system language never changed — so a pair
# taken from here reads as "this label is not translated", which is a claim about the wrong
# application.
SYSTEM_OWNED = "AXMenuBarItem[Apple]"


def skeleton(row):
    """The row's shape with every displayed string removed: role plus the bracket-stripped path.

    This is the whole premise — what survives a language change is the STRUCTURE. Titles inside
    `[...]` are exactly what does not, so they come out.
    """
    return row["role"] + "|" + re.sub(r"\[[^\]]*\]", "[]", str(row.get("path") or ""))


def aligned(base_rows, target_rows):
    """Pairs from the matching blocks only, and the count of rows each side could not place.

    `autojunk=False` is set explicitly, and the honest note is that it changes NOTHING on the data
    this was built against: measured 2026-09-06 on the 2026-09-05 en-US/ja-JP pair, both settings
    align 1005 of 1031 rows. It is pinned because the heuristic it disables discards elements
    appearing in more than 1% of a sequence of 200 or more, and a census is mostly repeated
    skeletons — so whether it fires depends on the shape of the walk rather than on anything this
    tool controls. An alignment that silently changes with the census size is not one a provenance
    claim should rest on.
    """
    b = [skeleton(r) for r in base_rows]
    t = [skeleton(r) for r in target_rows]
    blocks = difflib.SequenceMatcher(None, b, t, autojunk=False).get_matching_blocks()
    pairs = [(base_rows[m.a + k], target_rows[m.b + k]) for m in blocks for k in range(m.size)]
    placed = sum(m.size for m in blocks)
    return pairs, len(base_rows) - placed, len(target_rows) - placed


def reading(row):
    """The (attribute, string) this row displays, under the proposer's own attribute order."""
    for attr, text in _PROPOSE.strings_of(row):
        return attr, text
    return None, None


def candidates(base_census, target_census, labels):
    """For each label, the target-locale string sitting where its canonical sits. And the refusals.

    Returns (proposals, ambiguous, containing, stats). A proposal is only made when every aligned
    occurrence of the canonical agrees about the target string; when they disagree the label goes
    to `ambiguous` with all of them, because there is no evidence here for choosing.

    And the base row has to BE the canonical, not merely contain it. An aligned pair gives back the
    whole target string, so for a label matched by containment the answer is the translation of the
    CONTAINING string — `regionHelpKeyword` is `region`, the row it matched reads `cycle region`,
    and the aligned Japanese is `サイクルリージョン`, which is the translation of `cycle region`.
    Taken as a variant that is a different label. Found 2026-09-06 by reading this tool's own
    output against what each label says it addresses: 2 of the first 18 candidates were this, and
    `arrangeWindowTitleSuffix` would have taken a project name into the ledger with it.
    """
    pairs, unplaced_base, unplaced_target = aligned(base_census["census"], target_census["census"])
    usable = [(b, t) for b, t in pairs if SYSTEM_OWNED not in str(b.get("path") or "")]
    stats = {"pairs": len(pairs), "system_owned": len(pairs) - len(usable),
             "unplaced_base": unplaced_base, "unplaced_target": unplaced_target}

    proposals, ambiguous, containing = {}, {}, {}
    for name, entry in sorted(labels.items()):
        canonical = entry.get("canonical")
        if not canonical:
            continue
        allowed = _PROPOSE.roles_for(name)
        declared = entry.get("roles") or []
        found = {}
        for b, t in usable:
            # The same three gates the proposer applies, asked of the BASE row: the label's scope,
            # its role shape, and the roles it declares. A label that may only be read in a window
            # may not learn its translation from the menu bar either.
            if not _PROPOSE.in_scope(entry, b):
                continue
            if allowed is not None and b["role"] not in allowed:
                continue
            if declared and b["role"] not in declared:
                continue
            b_attr, b_text = reading(b)
            t_attr, t_text = reading(t)
            if not b_text or not t_text or b_attr != t_attr:
                continue
            # The ENTRY, so the mode comes from what the ledger declares rather than from a guess
            # about the label's name — and so a label with no agreed mode matches nothing here
            # either, which is what the proposer and the guard both do.
            if not _PROPOSE.matches(name, canonical, b_text, entry):
                continue
            # EQUALS, not merely matches. Asked with the guard's own comparison under `exact`, which
            # folds case and trims exactly as the product does, so this cannot drift from it.
            if not _GUARD.carries(b_text, canonical, "exact"):
                containing.setdefault(name, []).append({"base": b_text, "target": t_text})
                continue
            if t_text == b_text:
                # Not a translation. Logic ships plenty of strings identical across locales, and a
                # variant equal to the canonical is one `LabelSet` already matches.
                continue
            # Recorded, not judged. A label with no `evidence_scope` accepted this row on its role
            # alone, and a role is a KIND of element — which is precisely how `markerListDeleteMenuItem`
            # came to be backed by the Edit menu's Delete (#793). The tool cannot tell which of
            # those is the label's element, so it says which proposals rest on nothing narrower
            # than a role instead of presenting all of them as equally solid.
            found.setdefault(t_text, []).append(
                {"base": b_text, "target": t_text, "role": b["role"], "attribute": b_attr,
                 "path": t.get("path"), "base_path": b.get("path"), "surface": t.get("surface")})
        if not found:
            continue
        if len(found) > 1:
            ambiguous[name] = {k: v[0] for k, v in sorted(found.items())}
            continue
        target_text = next(iter(found))
        if target_text in (entry.get("variants") or []):
            continue
        c = dict(found[target_text][0])
        c["scoped"] = bool(_GUARD.evidence_scope(entry))
        proposals[name] = c
    return proposals, ambiguous, containing, stats


def _census(path):
    doc = json.load(open(path, encoding="utf-8"))
    if "census" not in doc or "host" not in doc:
        raise SystemExit(f"{path}: not a census — expected `host` and `census`")
    return doc


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("base_census")
    ap.add_argument("target_census")
    ap.add_argument("labels", nargs="?",
                    default=os.path.join(REPO, "docs", "locale", "ui-labels.json"))
    ap.add_argument("--json", dest="out", help="write the candidates to this path for review")
    ap.add_argument("--show", type=int, default=0, help="print this many candidates")
    args = ap.parse_args(argv)

    base, target = _census(args.base_census), _census(args.target_census)
    base_locale = base["host"]["locale"]
    target_locale = target["host"]["locale"]
    if base_locale == target_locale:
        raise SystemExit(f"both censuses are {base_locale} — an alignment needs two languages")
    labels = json.load(open(args.labels, encoding="utf-8"))["labels"]

    proposals, ambiguous, containing, stats = candidates(base, target, labels)
    missing = {n for n, e in labels.items()
               if (e.get("coverage") or {}).get(target_locale) == "unmeasured"}

    print(f"{base_locale} -> {target_locale}: {stats['pairs']} aligned pair(s); "
          f"{stats['system_owned']} dropped as system-owned ({SYSTEM_OWNED}); "
          f"{stats['unplaced_base']} base and {stats['unplaced_target']} target row(s) unplaced")
    unscoped = sorted(n for n, c in proposals.items() if not c["scoped"])
    print(f"{len(proposals)} label(s) have an unambiguous {target_locale} string read from the "
          f"aligned walk, {len(set(proposals) & missing)} of them currently unmeasured there")
    print(f"{len(ambiguous)} label(s) matched aligned rows whose targets DISAGREE — not proposed")
    print(f"{len(containing)} label(s) matched only INSIDE a longer string, so the aligned target "
          f"is the translation of that longer string and not of the label — not proposed")
    # Said every run rather than left for a reader to work out. These are the candidates admitted
    # by a ROLE and nothing narrower, so each is a place the #793 shape can happen: a real reading
    # of the right kind of element, about the wrong one.
    print(f"{len(unscoped)} of the {len(proposals)} rest on the label's role alone — it declares no "
          f"`evidence_scope`, so a same-role element carrying the same string would have matched "
          f"identically. Check these against where the label's element actually lives before "
          f"adding the variant.")
    if args.show:
        for name, c in list(sorted(proposals.items()))[:args.show]:
            mark = " " if c["scoped"] else "?"
            print(f" {mark}{name:38s} {c['base']!r} -> {c['target']!r}  [{c['role']} {c['attribute']}]")
        for name, alts in list(sorted(ambiguous.items()))[:args.show]:
            print(f"  AMBIGUOUS {name}: " + ", ".join(repr(k) for k in alts))
    if args.out:
        json.dump({"base_locale": base_locale, "target_locale": target_locale,
                   "base_record": base.get("id"), "target_record": target.get("id"),
                   "stats": stats, "proposals": proposals, "ambiguous": ambiguous,
                   "containing": containing},
                  open(args.out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
        print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
