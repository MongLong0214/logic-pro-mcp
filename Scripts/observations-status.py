#!/usr/bin/env python3
"""What we know about the installed Logic, and what we no longer know.

A measurement is true of one build of one application. When Logic updates, every record measured on
the old build becomes a claim about a program that is no longer installed — and the code listed in
that record's `depends` is running on an assumption nobody has re-checked. This turns that from
something to remember into something to run.

    Scripts/observations-status.py            report
    Scripts/observations-status.py --stale    exit 1 if any current-host record has drifted
    Scripts/observations-status.py --json     machine-readable, for a post-update sweep

`--stale` is deliberately NOT wired into CI. A Logic update is not a reason to fail an unrelated
pull request; it is a reason to schedule re-measurement. Wiring it to the merge gate would make the
honest state of the world block work that has nothing to do with it, and the guard would be switched
off within a week. The CI guards beside this one check the records themselves; this one answers
"what should we go and re-run".
"""
import argparse
import glob
import json
import os
import plistlib
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OBS = os.path.join(REPO, "docs", "observations")
LOGIC_PLIST = "/Applications/Logic Pro.app/Contents/Info.plist"


def installed_host():
    """The Logic actually on this machine, or None when it is not installed."""
    try:
        with open(LOGIC_PLIST, "rb") as fh:
            info = plistlib.load(fh)
    except (OSError, plistlib.InvalidFileException):
        return None
    return {"app": "Logic Pro",
            "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion")}


def load():
    out = []
    for path in sorted(glob.glob(os.path.join(OBS, "*.json"))):
        try:
            out.append((path, json.load(open(path, encoding="utf-8"))))
        except ValueError:
            continue          # malformed records are the schema guard's business
    return out


def classify(records, host):
    """current | stale | superseded, plus why. `host is None` means we cannot tell."""
    superseded = {d.get("supersedes") for _, d in records if d.get("supersedes")}
    rows = []
    for path, doc in records:
        rid = doc.get("id") or os.path.basename(path)
        rec_host = doc.get("host") or {}
        if rid in superseded:
            rows.append((rid, "superseded", "a later record replaces it", doc))
            continue
        if host is None:
            rows.append((rid, "unknown", "Logic is not installed here, so drift cannot be computed", doc))
            continue
        drift = [f"{k}: recorded {rec_host.get(k)!r}, installed {host.get(k)!r}"
                 for k in ("version", "build")
                 if rec_host.get(k) != host.get(k)]
        if drift:
            rows.append((rid, "stale", "; ".join(drift), doc))
        else:
            rows.append((rid, "current", f"measured on the installed {host['version']} ({host['build']})", doc))
    return rows


SURFACES_DOC = os.path.join(REPO, "docs", "observations", "SURFACES.md")


def taxonomy():
    """Every surface the map declares, in the order the table lists them."""
    import re
    out = []
    for line in open(SURFACES_DOC, encoding="utf-8"):
        m = re.match(r"\|\s*`([a-z_]+\.[a-z_]+)`\s*\|\s*(.+?)\s*\|", line)
        if m:
            out.append((m.group(1), m.group(2)))
    return out


def coverage(records):
    """Measured per surface — and, the point of the report, the surfaces with nothing."""
    by = {}
    for _, doc in records:
        by.setdefault(doc.get("surface", "?"), []).append(doc)
    print("measured\n")
    empty = []
    for surface, what in taxonomy():
        docs = by.get(surface, [])
        if not docs:
            empty.append((surface, what))
            continue
        print(f"  {surface}")
        for d in sorted(docs, key=lambda x: x["id"]):
            print(f"      [{d['verdict']:12s}] {d['question']}")
    if empty:
        print("\nnot measured — nobody has looked at these, which is not the same as them working\n")
        for surface, what in empty:
            print(f"  {surface:26s} {what}")
    total = len(taxonomy())
    print(f"\n{total - len(empty)} of {total} surfaces have at least one record; "
          f"{len(records)} record(s) in total.")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--stale", action="store_true", help="exit 1 when any record has drifted")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--coverage", action="store_true",
                    help="what is measured per surface, and which surfaces nobody has looked at")
    args = ap.parse_args()

    host = installed_host()
    records = load()
    rows = classify(records, host)

    if args.coverage:
        return coverage(records)

    if args.json:
        json.dump({"installed_host": host,
                   "records": [{"id": r, "status": s, "reason": w,
                                "verdict": d.get("verdict"),
                                "issues": d.get("issues"),
                                "depends": d.get("depends") or [],
                                "reverify": d.get("reverify")}
                               for r, s, w, d in rows]},
                  sys.stdout, indent=2, ensure_ascii=False)
        print()
        return 1 if (args.stale and any(s == "stale" for _, s, _, _ in rows)) else 0

    if host is None:
        print("Logic Pro is not installed here; host drift cannot be computed.\n")
    else:
        print(f"installed: Logic Pro {host['version']} (build {host['build']})\n")

    order = {"stale": 0, "unknown": 1, "current": 2, "superseded": 3}
    for rid, status, why, doc in sorted(rows, key=lambda r: (order.get(r[1], 9), r[0])):
        print(f"[{status}] {rid}")
        print(f"    {why}")
        if status == "stale":
            deps = doc.get("depends") or []
            print(f"    verdict was {doc.get('verdict')!r}; issues {doc.get('issues')}")
            if deps:
                print("    code standing on this claim, now unverified:")
                for d in deps:
                    print(f"      - {d}")
            else:
                print("    no code declares a dependency on it")
            rv = doc.get("reverify") or {}
            if rv.get("command"):
                print(f"    re-run: {rv['command']}")

    stale = [r for r, s, _, _ in rows if s == "stale"]
    print(f"\n{len(rows)} record(s): "
          + ", ".join(f"{n} {s}" for s, n in
                      sorted({s: sum(1 for _, x, _, _ in rows if x == s) for _, s, _, _ in rows}.items())))
    if stale:
        print(f"\n{len(stale)} record(s) describe a Logic that is no longer installed.")
        print("Re-run their reverify commands and file fresh records with `supersedes` set.")
    return 1 if (args.stale and stale) else 0


if __name__ == "__main__":
    sys.exit(main())
