#!/usr/bin/env python3
"""Which live harnesses a branch changed, and whether each of them proved itself at this head.

Usage:  python3 harness_evidence_coverage.py <worktree> <head-sha> <evidence-root> [base-ref]

#612, item 2. The gate reads ONE document per head — `<root>/<head>/evidence.json`, whichever
harness wrote it last. On a branch carrying two harnesses that means it can only ever validate the
last one run, while reporting `ok`. It happened: running #606's harness on the #608 branch to check
for a regression overwrote #608's own evidence, and the gate then validated #608 against #606's
proof. Both were clean, so nothing looked wrong.

Items 1 and 3 are already in `evidence.py` — the per-harness filename and the rotation that keeps
an earlier document instead of replacing it. They make this possible; this is the part that changes
what the gate can CLAIM.

WHAT "TOUCHED" MEANS HERE, AND WHAT IT DOES NOT
-----------------------------------------------
A harness is required to have proved itself when the branch CHANGED it:

    git diff --name-only <base>...HEAD -- Scripts/livekit/live_*.py

That is decidable from the diff, and it is exactly the case that went wrong. What is NOT decidable,
and is not attempted here: which harnesses a `Sources/` change ought to have been proved against.
Nothing in the tree records that mapping, and inventing one would put a guess where this check's
whole value is that it does not guess. A branch that changes only `Sources/` used to pass this check with
nothing required, and the ship gate's "live evidence for this head" step accepted ANY clean
document — so changing the spectral engine and running the selector-atlas harness passed, with a
document that was true and about something else.

That is closed as of 2026-08-29, and still without a guess: a harness DECLARES what it covers, in
a `COVERS = [...]` literal in its own file, read from a trusted ref so a branch cannot rewrite its
own obligations. A `Sources/` path some harness claims obliges that harness to have run clean. A
path nobody claims is printed as `unproven` rather than treated as proved.

So this is still a coverage floor, not a coverage proof — the unproven list is the size of the gap
and it is reported, not enforced. Said plainly because a check named `coverage` invites being read
as more.
"""
import ast
import glob
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


def harness_stems(changed_paths):
    """The live-harness stems among a list of changed repo paths.

    Takes paths rather than running git, so the rule can be tested without a repository. Deletions
    are the caller's problem to filter — a path that no longer exists cannot be required to have
    run, and requiring it would make deleting a harness impossible.
    """
    stems = set()
    for path in changed_paths or []:
        name = os.path.basename(path)
        if not name.startswith("live_") or not name.endswith(".py"):
            continue
        if os.path.dirname(path).replace("\\", "/").endswith("Scripts/livekit"):
            stems.add(name[: -len(".py")])
    return stems


def declared_coverage(text):
    """The repo paths a harness DECLARES it proves, from its `COVERS = [...]` literal.

    Parsed out of the source rather than imported, because importing a harness runs it — and the
    thing being judged does not get to execute inside its own judge. `ast.literal_eval` accepts a
    list of strings and nothing else, so a declaration cannot be computed, and a harness cannot
    widen its own claim at read time.
    """
    try:
        tree = ast.parse(text or "")
    except SyntaxError:
        return []
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        names = [t.id for t in node.targets if isinstance(t, ast.Name)]
        if "COVERS" not in names:
            continue
        try:
            value = ast.literal_eval(node.value)
        except (ValueError, SyntaxError):
            return []
        if isinstance(value, (list, tuple)) and all(isinstance(v, str) for v in value):
            return [v for v in value if v.strip()]
        return []
    return []


def required_by_sources(changed, declarations):
    """`(required, unproven)` — harnesses a `Sources/` change obliges, and the paths nobody claims.

    THE HOLE THIS CLOSES. Until 2026-08-29 a branch that changed only `Sources/` required no
    particular harness: the ship gate asked for *some* clean document bound to this head, and any
    harness supplied one. Change the spectral engine, run the selector-atlas harness, pass. The
    document was true and about something else.

    The old rule declined to invent a mapping, and that was right — a guess in a gate is worse than
    a gap. This does not guess. A harness SAYS what it covers, in its own file, reviewed like any
    other line, and the declarations are read from a trusted ref so a branch cannot rewrite its own
    obligations. What nobody claims is reported rather than assumed proved.

    Matching is by path COMPONENT, not by string prefix. `Sources/LogicProMCP/SelectorAtlas`
    written without its trailing slash would otherwise claim `SelectorAtlasExtras/` too — a
    declaration silently wider than the directory it names, and the widening happens in the
    direction that makes a harness look like it covers more.
    """
    required, unproven = set(), []
    for path in changed or []:
        if not path.startswith("Sources/"):
            continue
        claimants = sorted(
            stem for stem, covers in (declarations or {}).items()
            if any(path == prefix or path.startswith(prefix.rstrip("/") + "/")
                   for prefix in covers)
        )
        if claimants:
            required.update(claimants)
        else:
            unproven.append(path)
    return required, sorted(unproven)


def declarations_from_ref(worktree, ref):
    """`{stem: [paths]}` read from `ref`, not from the branch under test.

    Same principle the gate already applies to the rule itself: a branch that supplies its own
    judgement is not judged. A harness the branch ADDS therefore claims nothing here — which is
    safe, because the changed-harness rule already requires it to have run.
    """
    listing = subprocess.run(
        ["git", "ls-tree", "--name-only", f"{ref}:Scripts/livekit"],
        cwd=worktree, capture_output=True, text=True)
    if listing.returncode != 0:
        return None
    out = {}
    for name in listing.stdout.splitlines():
        if not (name.startswith("live_") and name.endswith(".py")):
            continue
        blob = subprocess.run(
            ["git", "show", f"{ref}:Scripts/livekit/{name}"],
            cwd=worktree, capture_output=True, text=True)
        if blob.returncode != 0:
            return None
        covers = declared_coverage(blob.stdout)
        if covers:
            out[name[: -len(".py")]] = covers
    return out


def documents_present(head_dir):
    """`{stem: path}` for every per-harness document in a head directory.

    `evidence.json` is deliberately not counted. It is the legacy single-file name — the last run at
    this head whatever produced it — and counting it would let one harness's document satisfy the
    requirement for another, which is the defect.
    """
    found = {}
    for path in sorted(glob.glob(os.path.join(head_dir, "*.evidence.json"))):
        stem = os.path.basename(path)[: -len(".evidence.json")]
        found[stem] = path
    return found


def verdict(required, present_paths, read_document=None):
    """`(missing, unclean)` — harnesses with no document, and ones whose document is not clean.

    `read_document` is injected so the rule can be exercised without files on disk. It takes a path
    and returns the parsed document, or None when it cannot be read; an unreadable document counts
    as unclean rather than as absent, because "it ran and produced something unusable" and "it never
    ran" are different facts and only one of them is a missing run.
    """
    read_document = read_document or _read_json
    missing = sorted(s for s in required if s not in present_paths)
    unclean = []
    for stem in sorted(required):
        if stem not in present_paths:
            continue
        doc = read_document(present_paths[stem])
        summary = E.summarize((doc or {}).get("records"))
        if not E.is_clean(summary):
            unclean.append(stem)
    return missing, unclean


def _read_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def changed_paths(worktree, base, head="HEAD", exclude_deletions=True):
    """Paths the branch changed; deletions excluded only when the caller asks.

    `head` is the commit the caller is asking ABOUT, not the worktree's current one. The first
    version hard-coded `HEAD` and took the head sha only to look up an evidence directory, so a
    gate invoked for one commit computed coverage from whatever the tree happened to be sitting on.
    In a pre-push hook those are the same and it would never have shown; anywhere else they are
    not, and the failure is a coverage verdict about the wrong commit reported as a verdict about
    this one.

    `--diff-filter=d` drops deletions, and that is right for HARNESSES: one that no longer exists
    cannot be required to have run, and requiring it would make deleting a harness impossible.

    It is wrong for `Sources/`, and applying it there was a way through the whole source-coverage
    rule — DELETE a file the atlas harness claims and the path never reached `required_by_sources`,
    so removing covered product code needed no proof at all. Deleting code is a change to what
    ships, and the harness that claims that area is exactly what should be run over it. Found by
    review, 2026-08-29.
    """
    cmd = ["git", "diff", "--name-only"]
    if exclude_deletions:
        cmd.append("--diff-filter=d")
    proc = subprocess.run(cmd + [f"{base}...{head}"],
        cwd=worktree, capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    return [p for p in proc.stdout.splitlines() if p.strip()]


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    worktree, head, root = argv[1], argv[2], argv[3]
    base = argv[4] if len(argv) > 4 else "origin/main"

    paths = changed_paths(worktree, base, head)
    if paths is None:
        print(f"-> COVERAGE FAIL: could not diff {base}...HEAD in {worktree}")
        return 2
    required = harness_stems(paths)

    # Deletions INCLUDED for the source question, excluded for the harness one. See `changed_paths`.
    all_paths = changed_paths(worktree, base, head, exclude_deletions=False)
    if all_paths is None:
        print(f"-> COVERAGE FAIL: could not diff {base}...HEAD in {worktree} (with deletions)")
        return 2

    # What the branch's `Sources/` changes oblige, from declarations on the TRUSTED ref.
    declarations = declarations_from_ref(worktree, base)
    if declarations is None:
        print(f"-> COVERAGE FAIL: could not read harness declarations from {base}")
        print("   The declarations are deliberately NOT read from the branch under test, so a")
        print("   missing ref is a refusal, not a fallback. Run: git fetch origin main")
        return 2
    by_sources, unproven = required_by_sources(all_paths, declarations)

    # A claimant the branch DELETED cannot be required to have run. The declarations are read from
    # the trusted ref on purpose — a branch must not be able to rewrite its own obligations — but
    # that also keeps a deleted harness's obligation alive, and nothing can satisfy it. This file
    # already says why that is wrong, one path over: "one that no longer exists cannot be required
    # to have run, and requiring it would make deleting a harness impossible." The reasoning was
    # never wired into the source-coverage path.
    #
    # This is not an escape hatch. The obligation is not dropped — the paths that harness claimed
    # move into `unproven` and are printed, so deleting a harness turns "claimed and proved" into
    # "named as nobody's", which is exactly what it is. And deleting a harness is loud in review
    # and independently ratcheted: `check-falsifiable-adoption.py` refuses a fall in the number
    # that carry a counterexample.
    deleted = {os.path.basename(p)[:-3] for p in
               changed_paths(worktree, base, head, exclude_deletions=False)
               if p.startswith("Scripts/livekit/live_") and p.endswith(".py")
               and not os.path.exists(os.path.join(worktree, p))}
    orphaned = sorted(stem for stem in by_sources if stem in deleted)
    for stem in orphaned:
        by_sources.discard(stem)
        claimed = set(declarations.get(stem, []))
        unproven.extend(sorted(p for p in all_paths
                               if p.startswith("Sources/") and p in claimed))
    if orphaned:
        print(f"   {len(orphaned)} claimant(s) deleted by this branch; what they claimed is "
              f"reported as unproven rather than required: {', '.join(orphaned)}")
    required |= by_sources

    if not required:
        # A livekit change that obliges no particular harness still has to point at a clean run.
        # Without this, editing `evidence.py` — which DEFINES `is_clean` — reached the gate and
        # then returned here before any document was judged by it: the branch could change what
        # passing means, run any harness, produce red records, and be asked nothing. The binding
        # step checks artifact metadata, not records.
        touched_kit = [p for p in paths
                       if p.startswith("Scripts/livekit/") and p.endswith(".py")
                       and not os.path.basename(p).startswith("test_")]
        if touched_kit:
            present = documents_present(os.path.join(root, head))
            clean = [stem for stem, path in present.items()
                     if E.is_clean(E.summarize((_read_json(path) or {}).get("records")))]
            print(f"   livekit changed ({len(touched_kit)} file(s)) and obliges no single harness;"
                  f" {len(clean)} of {len(present)} document(s) at this head are clean")
            if not clean:
                print("-> COVERAGE FAIL: a change to the live kit must point at a clean run,"
                      " and none of the documents at this head is one")
                return 1
        if unproven:
            print(f"n/a — no harness claims the {len(unproven)} changed Sources/ path(s):")
            for path in unproven[:8]:
                print(f"          unproven  {path}")
            if len(unproven) > 8:
                print(f"          unproven  … and {len(unproven) - 8} more")
        else:
            print("n/a — this branch changes no live harness")
        return 0

    head_dir = os.path.join(root, head)
    present = documents_present(head_dir)
    missing, unclean = verdict(required, present)

    print(f"   harnesses this branch must prove: {len(required)}"
          f" ({len(by_sources)} obliged by a Sources/ change)")
    for path in unproven[:8]:
        print(f"   unproven  {path}")
    if len(unproven) > 8:
        print(f"   unproven  … and {len(unproven) - 8} more")
    for stem in sorted(required):
        state = "missing" if stem in missing else ("UNCLEAN" if stem in unclean else "ok")
        print(f"   {state:>7}  {stem}")
    if missing:
        print(f"-> COVERAGE FAIL: no evidence at {head_dir} for: {', '.join(missing)}")
    if unclean:
        print(f"-> COVERAGE FAIL: evidence present but not clean for: {', '.join(unclean)}")
    return 1 if (missing or unclean) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
