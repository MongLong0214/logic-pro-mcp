#!/usr/bin/env python3
"""What the ledger does not yet know may only shrink.

`docs/observations/RATCHETS.json` holds a ceiling for every kind of gap the observation system can
count. This guard computes each gap from the tree and compares:

    live > ceiling   -> fail, unless RATCHETS.json carries a dated reason under `raised`
    live < ceiling   -> fail, with the number to lower it to — a ceiling that lags reality lets the
                        next regression hide under it
    live == ceiling  -> pass

The numbers used to live as constants inside individual guards (`TOTAL_VARIANT_CEILING = 257`),
which is where a ratchet becomes invisible to the person deciding whether to move it. One file, one
diff, one place a reviewer looks. ADR-019 D8.

The gaps, and where each is read from:

    undocumented_variants      docs/locale/ui-labels.json  variants without a `provenance` block
    unmeasured_coverage[loc]   docs/locale/ui-labels.json  coverage[loc] == "unmeasured"
    schema_v1_records          docs/observations/*.json    records without "schema": 2
    manual_reverify            docs/observations/*.json    reverify.kind == "manual"
    surfaces_without_records   SURFACES.md vs records      surfaces no record names

Exit 0 when every count equals its ceiling, 1 otherwise, 2 if an input cannot be read.
"""
import glob
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RATCHETS = os.path.join(REPO, "docs", "observations", "RATCHETS.json")
LABELS = os.path.join(REPO, "docs", "locale", "ui-labels.json")
OBS = os.path.join(REPO, "docs", "observations")
SURFACES = os.path.join(OBS, "SURFACES.md")


def live_state(repo=REPO):
    """What the ledger does not know, as SETS of identities — not counts.

    A count is defeated by a swap: add one undocumented variant, document a different one, and
    `variants - provenance` is unchanged. The thing that must not grow is the SET, so the ratchet
    holds identities and a new member fails even when the total falls. That also makes the diff say
    which claim appeared, which a number never could.
    """
    labels = json.load(open(os.path.join(repo, "docs", "locale", "ui-labels.json"), encoding="utf-8"))
    entries = labels.get("labels") or {}
    locales = tuple(labels.get("supported_locales") or ())
    undocumented = set()
    unmeasured = {loc: set() for loc in locales}
    for name, entry in entries.items():
        prov = entry.get("provenance") or {}
        for v in (entry.get("variants") or []):
            if v not in prov:
                undocumented.add(f"{name}\u2192{v}")
        for loc in locales:
            if (entry.get("coverage") or {}).get(loc, "unmeasured") == "unmeasured":
                unmeasured[loc].add(name)

    obs_dir = os.path.join(repo, "docs", "observations")
    records = [json.load(open(path, encoding="utf-8"))
               for path in sorted(glob.glob(os.path.join(obs_dir, "*.json")))
               if re.match(r"^\d{4}-\d{2}-\d{2}-.*\.json$", os.path.basename(path))]
    schema_v1 = {r.get("id") for r in records if r.get("schema", 1) != 2}
    manual = {r.get("id") for r in records if (r.get("reverify") or {}).get("kind") == "manual"}

    surfaces = re.findall(r"\|\s*`([a-z_]+\.[a-z_]+)`",
                          open(os.path.join(obs_dir, "SURFACES.md"), encoding="utf-8").read())
    # Per locale: a surface measured in ko-KR is not measured in ja-JP, and a global count said it was.
    bare = set()
    for loc in locales:
        seen = {r.get("surface") for r in records if (r.get("host") or {}).get("locale") == loc}
        bare |= {f"{loc}\u2192{s}" for s in surfaces if s not in seen}

    return {
        "undocumented_variants": undocumented,
        "unmeasured_coverage": unmeasured,
        "schema_v1_records": schema_v1,
        "manual_reverify": manual,
        "surfaces_without_records": bare,
    }


def _flatten(d, prefix=""):
    """`{"a": {"b": [...]}}` -> `("a.b", [...])`. Dicts nest; lists and sets are values."""
    for k, v in d.items():
        if isinstance(v, dict):
            yield from _flatten(v, f"{prefix}{k}.")
        else:
            yield f"{prefix}{k}", v


def base_allowed(repo):
    """The ceilings at the merge base, so a raise in the same commit as a regression cannot hide it.

    A file anyone can edit is an obvious "make CI green" knob: add ten undocumented variants,
    raise the ceiling by ten, and a guard that reads only the file passes. Against the base it
    cannot — the base ceiling is still the old number. `LPM_RATCHET_BASE_JSON` is a test seam
    naming a file to use instead of git; `LPM_RATCHET_BASE_REF` picks the ref (default
    origin/main). Returns (ceilings, description) or (None, why) when nothing base-like is readable.
    """
    seam = os.environ.get("LPM_RATCHET_BASE_JSON")
    if seam:
        try:
            return dict(_flatten(json.load(open(seam, encoding="utf-8")).get("allowed") or {})), seam
        except (OSError, ValueError) as exc:
            return None, f"{seam}: {exc}"
    ref = os.environ.get("LPM_RATCHET_BASE_REF", "origin/main")

    def git(*args):
        try:
            out = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return None, str(exc)
        return (out.stdout.strip(), None) if out.returncode == 0 else (None, out.stderr.strip()[:120])

    # The MERGE BASE, not the ref's tip. `git show origin/main:file` reads whatever main has now,
    # which a branch can outrun; the merge base is the state this branch actually departed from.
    merge_base, err = git("merge-base", "HEAD", ref)
    if not merge_base:
        return None, f"git merge-base HEAD {ref}: {err or 'not available'} (a shallow clone has no base)"
    blob, err = git("show", f"{merge_base}:docs/observations/RATCHETS.json")
    if blob is None:
        return None, f"{merge_base[:8]}:RATCHETS.json: {err or 'not present'}"
    try:
        return dict(_flatten(json.loads(blob).get("allowed") or {})), f"merge-base {merge_base[:8]}"
    except ValueError as exc:
        return None, f"{merge_base[:8]}: {exc}"


def compare(live, ratchets, base=None):
    """(grew, shrank, missing): each a list of (key, added|removed, allowed).

    For GROWTH the base is authoritative when it is readable, and the file is not consulted at all:
    unioning them is precisely what a same-commit raise exploits — add the member, add it to the
    file, and a union permits it. A member the base already allowed is therefore never a growth,
    which is what lets a branch drop one from its own file.

    For LAG the file alone is used: shrinking is the ordinary commit, and the file is where the
    closure gets recorded.
    """
    allowed = dict(_flatten(ratchets.get("allowed") or {}))
    base = base or {}
    grew, shrank, missing = [], [], []
    for key, values in _flatten(live):
        if key not in allowed:
            missing.append((key, values))
            continue
        permitted = set(base[key]) if key in base else set(allowed[key])
        added = sorted(set(values) - permitted)
        removed = sorted(set(allowed[key]) - set(values))
        if added:
            grew.append((key, added, allowed[key]))
        elif removed:
            shrank.append((key, removed, allowed[key]))
    return grew, shrank, missing


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    repo = os.path.abspath(argv[0]) if argv else REPO
    try:
        ratchets = json.load(open(os.path.join(repo, "docs", "observations", "RATCHETS.json"), encoding="utf-8"))
        live = live_state(repo)
    except (OSError, ValueError) as exc:
        print(f"could not read the ledger, so the ratchets cannot be checked: {exc}")
        return 2

    base, where = base_allowed(repo)
    if base is None:
        print(f"note: base sets unreadable ({where}); comparing against the file alone, which a "
              f"same-commit edit can defeat")
    grew, shrank, missing = compare(live, ratchets, base)
    raised = ratchets.get("raised") or {}
    failed = False

    for key, values in missing:
        print(f"{key}: {len(values)} item(s) with no allowed set in RATCHETS.json — add one, or the gap is uncounted")
        failed = True
    for key, added, allowed in grew:
        entry = raised.get(key) or {}
        ok = bool(str(entry.get("reason") or "").strip()) and \
            re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(entry.get("date") or "")) is not None
        if ok:
            # A raise with a dated reason is a DECISION, and it lands. The diff carries the reason
            # and the new members; refusing it outright made `raised` unusable, because the base
            # could never acquire a ceiling without merging a failing change.
            print(f"{key}: {len(added)} new item(s), raised {entry['date']}: {entry['reason']}")
            for v in added[:8]:
                print(f"    + {v}")
        else:
            print(f"{key}: {len(added)} item(s) the ledger did not know it did not know:")
            for v in added[:8]:
                print(f"    + {v}")
            if len(added) > 8:
                print(f"    … and {len(added) - 8} more")
            print(f"  Close them, or record why under `raised.{key}` with a date and a reason.")
            failed = True
    for key, removed, allowed in shrank:
        print(f"{key}: {len(removed)} item(s) closed — remove them from `allowed.{key}` so the next "
              f"regression cannot hide under the old list:")
        for v in removed[:8]:
            print(f"    - {v}")
        if len(removed) > 8:
            print(f"    … and {len(removed) - 8} more")
        failed = True

    if failed:
        return 1
    print("every ledger gap is within its allowed set: "
          + ", ".join(f"{k}={len(v)}" for k, v in _flatten(live)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
