#!/usr/bin/env python3
"""Prove `Scripts/check-observation-ratchets.py` can fail, in every direction it judges.

A ratchet that only ever passes is a number nobody reads. Each case below builds a small tree —
a labels JSON, a few records, a SURFACES table and a RATCHETS.json — and requires a specific
verdict. The cases that matter most are the two the guard must NOT confuse: a count that ROSE
(the ledger forgot something) and a count that FELL (the ceiling now lags reality). Both fail;
they fail for opposite reasons and the message has to say which.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

GUARD = Path(__file__).resolve().parent / "check-observation-ratchets.py"
spec = importlib.util.spec_from_file_location("ratchet_guard", GUARD)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

LOCALES = ["en-US", "ko-KR", "ja-JP"]


def _record(rid, locale="ko-KR", surface="arrange.regions", schema=None, kind="script"):
    d = {"id": rid, "surface": surface, "host": {"locale": locale},
         "reverify": {"kind": kind}, "verdict": "works"}
    if schema:
        d["schema"] = schema
    return d


def _tree(labels, records, allowed, raised=None, surfaces=("arrange.regions", "mixer.inserts"), git_init=False):
    """Write a throwaway repo and return its root."""
    tmp = tempfile.mkdtemp()
    root = Path(tmp)
    (root / "docs" / "locale").mkdir(parents=True)
    (root / "docs" / "observations").mkdir(parents=True)
    (root / "docs" / "locale" / "ui-labels.json").write_text(json.dumps({
        "schema": 2, "supported_locales": LOCALES, "labels": labels}), encoding="utf-8")
    for r in records:
        (root / "docs" / "observations" / f"{r['id']}.json").write_text(json.dumps(r), encoding="utf-8")
    (root / "docs" / "observations" / "SURFACES.md").write_text(
        "| surface | what |\n|---|---|\n" + "".join(f"| `{s}` | x |\n" for s in surfaces), encoding="utf-8")
    (root / "docs" / "observations" / "RATCHETS.json").write_text(json.dumps({
        "schema": 2, "allowed": allowed, "raised": raised or {}}), encoding="utf-8")
    if git_init:
        # A real repository, so `git merge-base` has something to compute. The seam is fine for the
        # set arithmetic; it cannot show that the git path works, and naming a case after an
        # integration it never runs is how a test comes to promise more than it checks.
        for cmd in (["init", "-q", "-b", "base"], ["add", "-A"], ["-c", "user.email=t@t", "-c", "user.name=t",
                                                    "commit", "-qm", "base"]):
            subprocess.run(["git", "-C", str(root), *cmd], capture_output=True)
    return root


def _label(variants, provenance=None, coverage=None):
    e = {"canonical": "x", "variants": variants, "rationale": "r"}
    if provenance:
        e["provenance"] = provenance
    e["coverage"] = coverage or {loc: "unmeasured" for loc in LOCALES}
    return e


def _branch(root, labels, allowed, raised=None):
    """Commit `labels`/`allowed`/`raised` onto a branch off the fixture's base commit."""
    (root / "docs" / "locale" / "ui-labels.json").write_text(json.dumps({
        "schema": 2, "supported_locales": LOCALES, "labels": labels}), encoding="utf-8")
    (root / "docs" / "observations" / "RATCHETS.json").write_text(json.dumps({
        "schema": 2, "allowed": allowed, "raised": raised or {}}), encoding="utf-8")
    for cmd in (["checkout", "-qb", "branch"], ["add", "-A"],
                ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "x"]):
        subprocess.run(["git", "-C", str(root), *cmd], capture_output=True)
    return dict(os.environ, LPM_RATCHET_BASE_REF="base")


def main():
    failures = []

    # Most fixtures here are throwaway directories with no git at all, because the set arithmetic
    # does not need one. The guard fails closed under CI when it cannot read a merge base — that is
    # the point of it — so inheriting a CI signal turns every base-less fixture into a failure and
    # the suite reports a bug in itself. The two cases that are ABOUT that behaviour pass `CI`
    # explicitly in their own env; every other case gets a clean one.
    os.environ.pop("CI", None)

    ran = [0]

    def check(name, cond, detail):
        # Counted, not typed. The closing line carried a literal and was stale the first time a
        # case was added without editing it.
        ran[0] += 1
        if not cond:
            failures.append(f"{name}: {detail}")

    prov = {"a": {"locale": "ko-KR", "date": "2026-09-05", "observed": "a", "record": "2026-09-05-r1",
                  "role": "AXMenuItem", "attribute": "title"}}
    labels = {"L": _label(["a", "b"], prov, {"en-US": "unmeasured", "ko-KR": "measured", "ja-JP": "unmeasured"})}
    records = [_record("2026-09-05-r1", schema=2), _record("2026-09-05-r2", kind="manual")]
    exact = {
        "undocumented_variants": ["L\u2192b"],
        "unmeasured_coverage": {"en-US": ["L"], "ko-KR": [], "ja-JP": ["L"]},
        "schema_v1_records": ["2026-09-05-r2"],
        "manual_reverify": ["2026-09-05-r2"],
        "surfaces_without_records": sorted(
            f"{loc}\u2192{s_}" for loc in ("en-US", "ko-KR", "ja-JP")
            for s_ in ("arrange.regions", "mixer.inserts")
            if not (loc == "ko-KR" and s_ == "arrange.regions")),
    }

    # 1. Live equals the allowed sets: pass.
    root = _tree(labels, records, exact)
    check("equal passes", guard.main([str(root)]) == 0, "expected exit 0 at the seeded sets")

    # 2. The live sets are what the guard says they are.
    live = {k: (sorted(v) if not isinstance(v, dict) else {kk: sorted(vv) for kk, vv in v.items()})
            for k, v in guard.live_state(str(root)).items()}
    check("state", live == exact, f"live_state returned {live}")

    # 3. THE SWAP. One undocumented variant appears and a different one gains provenance, so the
    #    COUNT is unchanged. A count-based ratchet passes this; a set-based one names the newcomer.
    labels_swap = {"L": _label(["a", "b", "c"], dict(prov, b={"locale": "ko-KR", "date": "2026-09-05",
                                                             "observed": "b", "record": "2026-09-05-r1",
                                                             "role": "AXMenuItem", "attribute": "title"}),
                               labels["L"]["coverage"])}
    root = _tree(labels_swap, records, exact)
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    check("swap is caught", proc.returncode == 1, f"exit {proc.returncode}")
    check("swap names the newcomer", "L\u2192c" in proc.stdout, proc.stdout[:300])
    check("the count was unchanged", len(guard.live_state(str(root))["undocumented_variants"]) == 1,
          "the fixture did not actually keep the count equal")

    # 4. A plain growth fails and names what appeared.
    labels2 = {"L": _label(["a", "b", "c"], prov, labels["L"]["coverage"])}
    root = _tree(labels2, records, exact)
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    check("growth fails", proc.returncode == 1 and "L\u2192c" in proc.stdout, proc.stdout[:200])

    # 5. A growth WITH a dated reason lands — otherwise `raised` is unusable, because the base can
    #    never acquire the new member without merging a failing change.
    #
    #    Over REAL GIT, because without a base there is no growth to authorise: the file is the
    #    fallback ceiling, the file already lists the member, and the raise is never consulted. The
    #    earlier fixture had no repository, so it asserted exit 0 on a path where nothing was tested.
    grown = dict(exact, undocumented_variants=["L\u2192b", "L\u2192c"])
    root = _tree(labels, records, exact, git_init=True)
    env = _branch(root, labels2, grown,
                  raised={"undocumented_variants": {"date": "2026-09-05", "reason": "three new leaves",
                                                    "members": ["L\u2192c"]}})
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True, env=env)
    check("raised lands over a real merge base", proc.returncode == 0,
          f"exit {proc.returncode}: {proc.stdout[:300]}")
    check("raised names its reason", "three new leaves" in proc.stdout, proc.stdout[:200])
    check("the base was consulted for the raise", "base sets unreadable" not in proc.stdout, proc.stdout[:200])

    # 5b. A raise authorises the members it NAMES and nothing else. Without this, one raise recorded
    #     for one growth blessed every later, unrelated growth on the same key forever.
    root = _tree(labels, records, exact, git_init=True)
    env = _branch(root, labels2, grown,
                  raised={"undocumented_variants": {"date": "2026-09-05", "reason": "an older decision",
                                                    "members": ["L\u2192zzz"]}})
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True, env=env)
    check("a stale raise does not authorise a new member",
          proc.returncode == 1 and "outside the members it authorised" in proc.stdout,
          f"exit {proc.returncode}: {proc.stdout[:300]}")

    # 5c. ...and a raise that names no members at all authorises anything that ever appears.
    root = _tree(labels, records, exact, git_init=True)
    env = _branch(root, labels2, grown,
                  raised={"undocumented_variants": {"date": "2026-09-05", "reason": "a real sentence"}})
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True, env=env)
    check("a raise with no members is refused",
          proc.returncode == 1 and "names no `members`" in proc.stdout, proc.stdout[:300])

    # 6. A raise needs a REAL date and a reason with substance. `\u200b` survives strip(), and
    #    `2026-99-99` matches a date-shaped regex while being no date at all.
    for label, entry, want in (
            ("undated raise is refused",
             {"reason": "a real sentence about why", "members": ["L\u2192c"]}, "not a real calendar date"),
            ("an impossible date is refused",
             {"date": "2026-99-99", "reason": "a real sentence", "members": ["L\u2192c"]},
             "not a real calendar date"),
            ("an invisible reason is refused",
             {"date": "2026-09-05", "reason": "\u200b\u200b\u200b", "members": ["L\u2192c"]},
             "no substance")):
        root = _tree(labels, records, exact, git_init=True)
        env = _branch(root, labels2, grown, raised={"undocumented_variants": entry})
        proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True, env=env)
        check(label, proc.returncode == 1 and want in proc.stdout, f"exit {proc.returncode}: {proc.stdout[:300]}")

    # 7. A gap that CLOSED fails too, with the member to remove — a list that lags reality lets the
    #    next regression hide inside it.
    root = _tree(labels, records, dict(exact, undocumented_variants=["L\u2192b", "L\u2192gone"]))
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    check("lag fails", proc.returncode == 1 and "L\u2192gone" in proc.stdout, proc.stdout[:200])

    # 8. A gap with no allowed set at all is reported, not ignored.
    root = _tree(labels, records, {k: v for k, v in exact.items() if k != "manual_reverify"})
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    check("missing set fails", proc.returncode == 1 and "no allowed set" in proc.stdout, proc.stdout[:200])

    # 9. THE MERGE BASE, over real git. The branch adds a member AND adds it to its own file — the
    #    shape a union would permit. The base does not have it, and the base is authoritative.
    root = _tree(labels, records, exact, git_init=True)
    (root / "docs" / "locale" / "ui-labels.json").write_text(json.dumps({
        "schema": 2, "supported_locales": LOCALES, "labels": labels2}), encoding="utf-8")
    (root / "docs" / "observations" / "RATCHETS.json").write_text(json.dumps({
        "schema": 2, "allowed": dict(exact, undocumented_variants=["L\u2192b", "L\u2192c"]),
        "raised": {}}), encoding="utf-8")
    for cmd in (["checkout", "-qb", "branch"], ["add", "-A"],
                ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "raise"]):
        subprocess.run(["git", "-C", str(root), *cmd], capture_output=True)
    env = dict(os.environ, LPM_RATCHET_BASE_REF="base")
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True, env=env)
    check("same-commit raise is caught against the real merge base",
          proc.returncode == 1 and "L\u2192c" in proc.stdout, f"exit {proc.returncode}: {proc.stdout[:300]}")
    check("the base was actually consulted, not skipped", "base sets unreadable" not in proc.stdout,
          f"the guard fell back to the file: {proc.stdout[:200]}")

    # 10. A member the BASE already allowed is not a growth, so a branch that genuinely CLOSES it
    #     may drop it from its own file. `labels` has no L→c, so live no longer has it either.
    root = _tree(labels2, records, grown, git_init=True)
    env = _branch(root, labels, exact)
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True, env=env)
    check("a real closure passes", proc.returncode == 0,
          f"closing a base-allowed member should pass: exit {proc.returncode}: {proc.stdout[:300]}")

    # 10b. But dropping it from the file while it is STILL LIVE is not a closure — it is a ceiling
    #      that under-reports. Against the base there is no growth and against the file no lag, so
    #      this passed until understatement became a finding of its own. The previous version of
    #      this case asserted exactly this shape and called it correct.
    root = _tree(labels2, records, grown, git_init=True)
    env = _branch(root, labels2, exact)
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True, env=env)
    check("a ceiling that hides live debt is refused",
          proc.returncode == 1 and "under-reports the real gap" in proc.stdout,
          f"exit {proc.returncode}: {proc.stdout[:300]}")

    # 10c. A valid raise must not silence an unrelated closure recorded in the same commit. These
    #      were an if/elif, so the first finding on a key suppressed the second.
    live_both = {"k": {"kept", "added"}}
    both = guard.compare(live_both, {"allowed": {"k": ["kept", "added", "goneStale"]}},
                         {"k": ["kept", "goneStale"]})
    check("growth does not mask lag",
          both[0] and both[0][0][1] == ["added"] and both[1] and both[1][0][1] == ["goneStale"],
          f"grew={both[0]} shrank={both[1]}")

    # 11. A key the BASE has never seen is entirely new, and every member is a growth. Adding
    #     `unmeasured_coverage.fr-FR` pre-populated with its own gaps would otherwise pass in
    #     silence — the file permits them and the base is never asked about a key it lacks.
    live_new = {"unmeasured_coverage": {"ko-KR": {"a"}, "fr-FR": {"x", "y", "z"}}}
    ratch_new = {"allowed": {"unmeasured_coverage": {"ko-KR": ["a"], "fr-FR": ["x", "y", "z"]}}}
    grew, _, _, _ = guard.compare(live_new, ratch_new, {"unmeasured_coverage.ko-KR": ["a"]})
    check("a new axis is not free", grew and grew[0][0] == "unmeasured_coverage.fr-FR"
          and sorted(grew[0][1]) == ["x", "y", "z"], grew)

    # 12. ...but with no base at all, the file is the fallback and says so rather than inventing
    #     a growth out of every key.
    grew, _, _, _ = guard.compare(live_new, ratch_new, None)
    check("no base falls back to the file", grew == [], grew)

    # 13. An unreadable base is said out loud. Locally that is a note; in CI it is a failure,
    #     because CI is where the claim of enforcement is actually made and a shallow checkout
    #     silently degrades the guard to comparing the branch against its own file.
    root = _tree(labels, records, exact)
    env2 = dict(os.environ, LPM_RATCHET_BASE_JSON=str(root / "missing.json"))
    env2.pop("CI", None)
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True, env=env2)
    check("unreadable base is loud, not fatal locally",
          proc.returncode == 0 and "base sets unreadable" in proc.stdout,
          f"exit {proc.returncode}: {proc.stdout[:200]}")
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True,
                          env=dict(env2, CI="true"))
    check("...and fatal under CI",
          proc.returncode == 1 and "fetch-depth: 0" in proc.stdout,
          f"exit {proc.returncode}: {proc.stdout[:200]}")

    # 13b. A merge base that RESOLVES but predates the ledger is not a shallow clone: it is the
    #      commit introducing the file. Refusing it would make that commit unmergeable, so it is
    #      allowed and named — and the branch can never take this path again once it lands.
    root = _tree(labels, records, exact, git_init=True)
    subprocess.run(["git", "-C", str(root), "rm", "-q", "--cached",
                    "docs/observations/RATCHETS.json"], capture_output=True)
    subprocess.run(["git", "-C", str(root), "-c", "user.email=t@t", "-c", "user.name=t",
                    "commit", "-qm", "before the ledger"], capture_output=True)
    env3 = _branch(root, labels, exact)
    proc = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True,
                          env=dict(env3, CI="true"))
    check("the introducing commit is not treated as a shallow clone",
          proc.returncode == 0 and "bootstrap" in proc.stdout,
          f"exit {proc.returncode}: {proc.stdout[:300]}")

    # 14. RATCHETS.json beside the records is not itself counted as one.
    check("ratchets file is not a record", guard.live_state(str(root))["schema_v1_records"] == {"2026-09-05-r2"},
          guard.live_state(str(root))["schema_v1_records"])

    # 15. An unreadable ledger is exit 2, never a pass.
    (root / "docs" / "observations" / "RATCHETS.json").write_text("{not json", encoding="utf-8")
    check("unreadable is exit 2", guard.main([str(root)]) == 2, "expected exit 2")

    # 16. The REPORT and the RATCHET must never disagree about what a gap is. They read the same
    #     `live_state`, and this asserts it rather than trusting that two implementations agree —
    #     two definitions of a gap drifting apart is the failure this ledger exists to catch, one
    #     level up.
    out = subprocess.run([sys.executable, str(GUARD.parent / "observations-status.py"), "--unproven"],
                         capture_output=True, text=True).stdout
    real = guard.live_state()
    import re as _re
    for key, pat in (("undocumented_variants", r"(\d+) variant\(s\)"),
                     ("schema_v1_records", r"schema 1[^:]*: (\d+)"),
                     ("manual_reverify", r"manual prose rather than a command: (\d+)")):
        m = _re.search(pat, out)
        check(f"report agrees with the ratchet on {key}",
              m and int(m.group(1)) == len(real[key]),
              f"report {m.group(1) if m else '?'} vs ratchet {len(real[key])}")

    # 17. The real repository is within its sets right now.
    proc = subprocess.run([sys.executable, str(GUARD)], capture_output=True, text=True)
    check("repository is clean", proc.returncode == 0, proc.stdout.strip()[:300])

    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print(f"{ran[0]} case(s) pass: a swap is caught by name, a raise lands with a reason, "
          f"and the base is real git")
    return 0


if __name__ == "__main__":
    sys.exit(main())
