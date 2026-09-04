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
import importlib.util
import json
import os
import plistlib
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OBS = os.path.join(REPO, "docs", "observations")
LOGIC_PLIST = "/Applications/Logic Pro.app/Contents/Info.plist"


def installed_host():
    """This machine, or None when Logic is not installed here.

    Delegates to `observation_host.host()` so the one place that formats a host block is
    the one place records are generated from. Restating `macOS {version} ({build})` here
    would mark every record stale the moment the two spellings drifted apart.
    """
    spec = importlib.util.spec_from_file_location(
        "observation_host", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                         "observation_host.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    block = module.host()
    return block if block.get("version") else None


RECORD_NAME = re.compile(r"^\d{4}-\d{2}-\d{2}-.*\.json$")


def is_record(path):
    """A record is a date-prefixed JSON file, which is what the schema guard already requires of
    one. RATCHETS.json lives beside the records and is not one; a loader that globs `*.json`
    counted it as a schema-1 record and reported 25 where the ratchet guard reported 24."""
    return RECORD_NAME.match(os.path.basename(path)) is not None


def load():
    out = []
    for path in sorted(p for p in glob.glob(os.path.join(OBS, "*.json")) if is_record(p)):
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
                 for k in ("version", "build", "os")
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
            loc = (d.get("host") or {}).get("locale") or "?"
            print(f"      [{d['verdict']:12s}] [{loc}] {d['question']}")
    if empty:
        print("\nnot measured — nobody has looked at these, which is not the same as them working\n")
        for surface, what in empty:
            print(f"  {surface:26s} {what}")
    total = len(taxonomy())
    print(f"\n{total - len(empty)} of {total} surfaces have at least one record; "
          f"{len(records)} record(s) in total.")

    # Per LOCALE, because that is the gap the ratchet counts and the reason the ledger exists: a
    # surface measured only in Korean is unmeasured in Japanese, and a summary that says "has a
    # record" hides exactly the drift a Logic release introduces one language at a time. Read from
    # the ratchet guard's `live_state` so the report and the enforcement cannot disagree about what
    # a gap is — two implementations of one definition agree until they do not.
    per_locale = _gaps()["surfaces_without_records"]
    if per_locale:
        by_locale = {}
        for item in per_locale:
            loc, _, surface = str(item).partition("\u2192")
            by_locale.setdefault(loc, []).append(surface)
        print("\nby locale — a surface seen only in one language is unmeasured in the others\n")
        for loc in sorted(by_locale):
            missing = sorted(by_locale[loc])
            print(f"  {loc:8s} {total - len(missing)} of {total} measured; missing "
                  f"{', '.join(missing[:4])}" + (f" and {len(missing) - 4} more" if len(missing) > 4 else ""))
    return 0


LABELS = os.path.join(REPO, "docs", "locale", "ui-labels.json")


def _gaps():
    """The ledger's gaps, from the ONE place that defines them.

    `check-observation-ratchets.py` decides what counts as an undocumented variant, an unmeasured
    locale, a bare surface. Recomputing that here would be a second definition of the same thing,
    and two definitions of a gap drift — which is the failure this whole ledger exists to catch,
    one level up. The ratchet enforces; this reports; both read the same function.
    """
    spec = importlib.util.spec_from_file_location(
        "ratchets", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "check-observation-ratchets.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.live_state(REPO)


def unproven(records):
    """Every gap the ledger can name, as things a person can go and do. ADR-019 D6.

    The same sets the ratchet holds, printed as names. A ceiling of 255 is 255 named strings rather
    than a number nobody can act on — and because both read `live_state`, the list and the count
    cannot disagree about what a gap is.
    """
    gaps = _gaps()
    try:
        labels = json.load(open(LABELS, encoding="utf-8"))
    except (OSError, ValueError):
        labels = {}
    entries = labels.get("labels") or {}
    locales = tuple(labels.get("supported_locales") or ())
    docs = [d for _, d in records]
    surfaces = [s for s, _ in taxonomy()]

    print("variants with no provenance — strings the product matches that nobody has recorded reading\n")
    by_label = {}
    for item in sorted(gaps["undocumented_variants"]):
        label, _, variant = item.partition("\u2192")
        by_label.setdefault(label, []).append(variant)
    for label, variants in sorted(by_label.items()):
        print(f"  {label:40s} {', '.join(repr(v) for v in variants)}")
    print(f"\n  {len(gaps['undocumented_variants'])} variant(s)\n")

    # NAMES, never counts. A count is not a thing anyone can go and do, and every line of this
    # report claims to be one. Nothing is truncated either: a list that hides its tail is the same
    # failure one step smaller.
    print("label sets unmeasured per locale — nobody has looked, which is not `measured`\n")
    for loc in locales:
        names = sorted(gaps["unmeasured_coverage"].get(loc, ()))
        print(f"  {loc}: {len(names)} of {len(entries)}")
        for i in range(0, len(names), 3):
            print("      " + "  ".join(f"{n:36s}" for n in names[i:i + 3]).rstrip())
    print()

    print("surfaces with no record, per locale\n")
    for loc in locales:
        bare = sorted(x.partition("\u2192")[2] for x in gaps["surfaces_without_records"]
                      if x.startswith(f"{loc}\u2192"))
        print(f"  {loc}: {len(bare)} of {len(surfaces)}")
        for s_ in bare:
            print(f"      {s_}")
    print()

    v1 = sorted(gaps["schema_v1_records"])
    print(f"records at schema 1 — no `evidence`, no `schema`: {len(v1)}")
    for r in v1:
        print(f"      {r}")
    manual = sorted(gaps["manual_reverify"])
    print(f"\nrecords whose reverify is manual prose rather than a command: {len(manual)}")
    for r in manual:
        print(f"      {r}")
    # Which claims rest on a machine-produced census, and which on a row the record's author typed.
    # Both are legitimate — a record carries readings, and a person writing down what they saw is
    # how most of this ledger was built. But the guard cannot tell them apart, and neither could a
    # reader until now: it is the one thing the evidence rule explicitly does NOT check, so it is
    # worth being able to see rather than only being written down in the ADR.
    by_id = {d.get("id"): d for d in docs}
    machine = author = 0
    for entry in entries.values():
        for block in (entry.get("provenance") or {}).values():
            rec = by_id.get((block or {}).get("record"))
            if rec and rec.get("evidence"):
                machine += 1
            else:
                author += 1
    print(f"\nprovenance resting on a record with an evidence FILE: {machine}")
    print(f"provenance resting on a row the record's author wrote:  {author}")
    print("  Neither is refused. The guard checks that the record SAW the string, not how the")
    print("  record came to say so — the campaign produces the first kind, and a person the second.")

    broken = []
    for d in docs:
        for dep in d.get("depends") or []:
            rel, _, symbol = dep.partition(":")
            path = os.path.join(REPO, rel)
            if not os.path.exists(path):
                broken.append((d.get("id"), dep, "file missing"))
            elif symbol:
                body = open(path, encoding="utf-8", errors="replace").read()
                gone = [c for c in symbol.split(".") if c and c not in body]
                if gone:
                    broken.append((d.get("id"), dep, f"symbol {gone[0]!r} gone"))
    print(f"depends entries that no longer resolve: {len(broken)}")
    for rid, dep, why in broken:
        print(f"  {rid}: {dep} — {why}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--stale", action="store_true", help="exit 1 when any record has drifted")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--coverage", action="store_true",
                    help="what is measured per surface, and which surfaces nobody has looked at")
    ap.add_argument("--unproven", action="store_true",
                    help="everything the ledger does not know, as a list a person can act on")
    args = ap.parse_args()

    host = installed_host()
    records = load()
    rows = classify(records, host)

    if args.unproven:
        return unproven(records)
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
        # Name every drift axis, not just Logic's: an OS bump moves the AX surface too,
        # and a header that hides the axis it judges on cannot be checked by the reader.
        print(f"installed: Logic Pro {host['version']} (build {host['build']})"
              f" on {host.get('os', 'unknown OS')}\n")

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
