#!/usr/bin/env python3
"""A list that may only move one way, compared against the branch's merge base.

WHY THIS IS A MODULE AND NOT A FRAMEWORK

It exists because two owners need the same comparison, not because a third might. Rule 7 lived in
`check-canon-citations.py` and ratcheted five lists that have nothing to do with Logic: which
commands the required CI gate carries, which jobs may skip it, which guards have no test, which
guard tests are blind to their guard. Those moved to `check-every-ci-job-is-required.py` with the
files they read, and the comparison came here so that neither owner imports the other. The Canon
checker must not load CI topology to decide whether a citation resolves, and the CI checker must
not drag the corpus into every run to decide whether a waiver grew.

Nothing here knows what a corpus, a workflow or a guard is. It reads JSON, it reads git, and it
compares two sets.

WHAT THE COMPARISON IS FOR

Against the MERGE BASE, never against the file itself. A file-only check is what a same-commit
edit defeats: break the rule and waive yourself in the same commit, and the tree is internally
consistent. Two directions, because two kinds of list were mixed:

    shrink   a WAIVER -- debt, an exemption, something not yet done. Growth admits more debt.
    grow     a REQUIREMENT -- a path that must be cited, a command CI must run. Shrinkage
             quietly removes a rule.
"""

import glob
import json
import os
import subprocess
import sys


class Ratchet:
    """One list, where it lives, which way it may move, and where it used to live.

    `legacy` is the owner's own mapping for a file this change RELOCATED, and it is deliberately
    not read out of the moved file. A policy that names its own predecessor decides what it is
    compared against, and a relocation that drops a required command would then pass by pointing
    somewhere convenient. The owner declares the move; the file does not get a say.
    """

    def __init__(self, path, key, direction, what, members=None, legacy=None):
        assert direction in ("grow", "shrink"), direction
        self.path = path
        self.key = key
        self.direction = direction
        self.what = what
        self.members = members or default_members
        self.legacy = legacy


def default_members(blob, key):
    return set(blob.get(key) or [])


def key_members(blob, key):
    """The KEYS of a map, for a waiver whose values are prose rather than a classification."""
    return set((blob.get(key) or {}))


def skip_members(blob, key):
    """One member per ALLOWED SKIP, not one per guard, so the number moves in the right direction.

    A dict of guard -> {"skips": n} cannot be compared by membership alone: raising 4 to 5 and
    lowering 5 to 4 both look like one member lost and one gained, and a single direction refuses
    whichever of the two it was not written for. Emitting `path:0 ... path:n-1` makes an allowance
    that GROWS gain a member, which shrink refuses, and one that falls only lose members.
    """
    members = set()
    for path, row in (blob.get(key) or {}).items():
        for index in range(int((row or {}).get("skips") or 0)):
            members.add(f"{path}:{index}")
    return members


def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return default


class History:
    """Reading one repository's git history. One object so a test can point it at a fixture."""

    def __init__(self, repo: str):
        self.repo = repo
        self._said = set()

    def note(self, message):
        """Said once. Two rules ratchet the same file, and a note repeated per caller reads as two
        findings rather than one fact about the branch."""
        if message not in self._said:
            self._said.add(message)
            print(f"  note: {message}", file=sys.stderr)

    def git(self, *args):
        out = subprocess.run(["git", "-C", self.repo, *args], capture_output=True, text=True)
        return out.stdout.strip() if out.returncode == 0 else None

    def merge_base(self):
        """The commit this branch forked from, or None when it cannot be read."""
        for ref in ("origin/main", "main"):
            found = subprocess.run(["git", "merge-base", "HEAD", ref],
                                   cwd=self.repo, capture_output=True, text=True)
            if found.returncode == 0 and found.stdout.strip():
                return found.stdout.strip()
        return None

    def show_json(self, sha, path):
        out = subprocess.run(["git", "-C", self.repo, "show", f"{sha}:{path}"],
                             capture_output=True, text=True)
        if out.returncode != 0:
            return None
        try:
            return json.loads(out.stdout)
        except json.JSONDecodeError:
            return None

    def at_base(self, base, path, quiet: bool = False):
        """The ratcheted file as the branch departed from it, or None with a note saying why.

        The merge base not carrying the file is NOT the same as the file being new:

          * A delete-then-restore pair reaches a branch too. Treating it as a bootstrap adopts
            whatever the restored file says as the permanent base.
          * `rev-list` simplifies through a TREESAME merge and follows one parent, so a delete on
            a side branch hides what the other parent did. `--full-history` is why.
          * In a shallow clone `rev-list` exits 0 with no output, so "no ancestor carries it" is
            not a reading anyone can trust.

        `quiet` suppresses the last note only -- the one saying this commit INTRODUCES the file.
        A caller with a legacy path still to try does not know that yet, and saying it before
        looking leaves two notes contradicting each other about the same file.
        """
        found = self.show_json(base, path)
        if found is not None:
            return found
        history = self.git("rev-list", "--full-history", "--max-count=200", base, "--", path)
        for sha in (history or "").split():
            prior = self.show_json(sha, path)
            if prior is not None:
                self.note(f"{path} is absent at the merge base {base[:8]}; ratcheted against "
                          f"{sha[:8]}, the last ancestor carrying it.")
                return prior
        if self.git("rev-parse", "--is-shallow-repository") == "true":
            self.note(f"{path}: history is truncated (shallow clone), so 'no ancestor carries it' "
                      f"is not a reading anyone can trust. Check out with fetch-depth: 0.")
            return None
        if not quiet:
            self.note(f"{path} is carried by neither the merge base {base[:8]} nor any ancestor, "
                      f"so this is the commit that introduces it and its ratchet does not run "
                      f"here. It runs on the next branch -- a contradiction introduced with a new "
                      f"list is invisible until then.")
        return None


def base_or_refuse(history: History, failures: list) -> str:
    """The merge base, or None after recording why the ratchets cannot run.

    Under CI an unreadable base is a FAILURE, not a weaker comparison: a shallow clone has no
    base, and the shape of the whole rule is that the comparison happens outside the branch.
    """
    base = history.merge_base()
    if base is not None:
        return base
    message = ("the merge base could not be read, so a ratcheted list can only be compared "
               "against its own file -- which a same-commit edit defeats")
    if os.environ.get("CI") == "true":
        failures.append(f"ratchets: {message}. A shallow clone has no base; "
                        f"CI must check out with fetch-depth: 0.")
    else:
        history.note(message)
    return None


def check(repo: str, ratchets, failures: list, history: History = None, owner: str = "") -> None:
    """Compare each list against the merge base and record every move in the wrong direction."""
    history = history or History(repo)
    base = base_or_refuse(history, failures)
    if base is None:
        return

    for entry in ratchets:
        before = _before(repo, entry, base, failures, history, owner)
        if before is None:
            continue
        now = load_json(os.path.join(repo, entry.path), {})
        if not isinstance(before.get(entry.key), (list, dict)) \
                or not isinstance(now.get(entry.key), (list, dict)):
            failures.append(
                f"{entry.path}: the list this ratchet compares lives under {entry.key!r}, and one "
                f"side does not have it. A renamed key makes the comparison silently empty.")
            continue
        was, is_now = entry.members(before, entry.key), entry.members(now, entry.key)
        if not was and before.get(entry.key):
            # The extractor reads a SHAPE. Change the shape and it returns nothing, the comparison
            # is empty, and the ratchet passes everything -- the failure mode this whole rule is
            # about. An empty reading of a non-empty value is a broken extractor, not a clean run.
            failures.append(
                f"{entry.path}: the ratchet read no members out of a non-empty {entry.key!r}. Its "
                f"extractor no longer matches the file's shape, so the comparison would pass "
                f"anything.")
            continue
        if entry.direction == "shrink":
            for member in sorted(is_now - was):
                failures.append(
                    f"{entry.path}: {member!r} was added to the list of {entry.what}. That list "
                    f"may only SHRINK. A change that breaks the rule and waives itself in the "
                    f"same commit passes every check that reads only the tree.")
        else:
            for member in sorted(was - is_now):
                failures.append(
                    f"{entry.path}: {member!r} was removed from the list of {entry.what}. That "
                    f"list may only GROW -- it is a requirement, not a waiver, and dropping an "
                    f"entry quietly removes a rule.")


def _before(repo: str, entry: Ratchet, base: str, failures: list, history: History, owner: str):
    """What this list looked like outside the branch, or None when there is nothing to compare."""
    found = history.at_base(base, entry.path, quiet=bool(entry.legacy))
    if found is not None:
        return found

    # THE FILE MOVED. The owner said where from, so the comparison follows it: a relocation that
    # drops a required command or adds a waiver is the same change it would have been in place.
    # Without this, a `grow` list that moved would be unratcheted on the branch that moves it,
    # which is exactly the branch where a requirement is easiest to lose.
    if entry.legacy:
        legacy = history.at_base(base, entry.legacy)
        if legacy is not None:
            history.note(f"{entry.path} is absent at {base[:8]}; compared against {entry.legacy}, "
                         f"which this owner declares it was moved from.")
            return legacy
        if os.path.exists(os.path.join(repo, entry.legacy)):
            failures.append(
                f"{entry.path}: {entry.legacy} is declared as the path this moved from, the merge "
                f"base does not carry it, and it is still in the tree. Two copies of one policy "
                f"is the state this migration exists to leave.")
            return None
        history.note(f"{entry.path}: neither it nor {entry.legacy} is carried by {base[:8]}, so "
                     f"this is a genuine first introduction rather than a move.")

    # A list no ancestor carries is unratcheted on the branch that introduces it. For a `grow`
    # list that is necessary -- the commit adding a Logic-facing directory must be able to add its
    # prefix, and refusing it would make the first such change unmergeable.
    if entry.direction != "shrink":
        return None
    if not os.path.exists(os.path.join(repo, entry.path)):
        # Absent on both sides. A waiver list that does not exist is the good state, and the shape
        # check would otherwise read "one side does not have the key" as a renamed key.
        return None

    # A `shrink` list arriving pre-populated is a growth from nothing that nobody is asked about
    # -- UNLESS it is a CENSUS rather than a set of permissions. What separates them is not what
    # the file says about itself: it is whether any guard READS it to skip something. A file no
    # guard reads records what somebody measured, and refusing a census is refusing somebody for
    # writing down what is already true. Checked by looking, not by asking the file.
    readers = sorted(
        os.path.basename(g) for g in glob.glob(os.path.join(repo, "Scripts", "check-*.py"))
        if os.path.basename(g) != owner
        and os.path.basename(entry.path) in open(g, encoding="utf-8", errors="replace").read())
    if not readers:
        history.note(f"{entry.path} is new and no guard reads it to exempt anything, so it is a "
                     f"census rather than a set of permissions. Its first version is the "
                     f"measurement; the ratchet holds it to shrinking from the next branch on.")
        return None

    # `migrated_from` inside the file is the weaker, older form of `legacy` above: it is checked,
    # not believed. The named path is read AT THE MERGE BASE and every member of the new list must
    # appear there as a quoted string, so a member the predecessor did not carry is still a growth.
    now_doc = load_json(os.path.join(repo, entry.path), {})
    origin = now_doc.get("migrated_from")
    if origin:
        was_text = history.git("show", f"{base}:{origin}") or ""
        if not was_text:
            failures.append(
                f"{entry.path}: `migrated_from` names {origin!r}, which the merge base does not "
                f"carry. A move has a place it moved FROM, and this one cannot be checked.")
            return None
        strays = sorted(m for m in entry.members(now_doc, entry.key)
                        if f'"{m}"' not in was_text and f"'{m}'" not in was_text)
        if strays:
            failures.append(
                f"{entry.path}: {len(strays)} member(s) are not in {origin} at the merge base, so "
                f"they were not moved, they were added: {', '.join(strays[:6])}. A new exemption "
                f"lands as a growth however the file it lands in was created.")
            return None
        history.note(f"{entry.path} was migrated from {origin}; every member is one that file "
                     f"already carried at {base[:8]}, so the move is not a growth.")
        return None

    history.note(f"{entry.path} is carried by no ancestor of {base[:8]}. It is a waiver list, so "
                 f"its first version is compared against an EMPTY set: a new list of exemptions "
                 f"is a growth from nothing, not a bootstrap.")
    return {entry.key: []}
