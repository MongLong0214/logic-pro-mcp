#!/usr/bin/env python3
"""What a Logic update costs, before you pay it.

`docs/observations/LOGIC-BUILD.json` declares the Logic build every reading in this repository is
understood to describe. `check-observation-ratchets.py` counts readings that name a DIFFERENT build,
as sets that may only shrink — so bumping the declaration turns a Logic update into a refusal you
have to answer, one reading at a time, instead of a hundred records quietly describing a build
nobody runs.

This command is the other half: it compares the DECLARATION to the Logic actually installed on this
machine, and says what bumping would cost. It is a reading aid and exits 0 whether or not they
agree — the refusal lives in the ratchet, where CI can see it. Logic is not installed in CI, which
is why the declaration is declared rather than detected in the first place.

    Scripts/logic-build-drift.py            compare and report
    Scripts/logic-build-drift.py --json     the same, machine-readable
"""
import glob
import json
import os
import plistlib
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DECLARATION = os.path.join(REPO, "docs", "observations", "LOGIC-BUILD.json")
LOGIC_PLIST = "/Applications/Logic Pro.app/Contents/Info.plist"
OBS = os.path.join(REPO, "docs", "observations")
LABELS = os.path.join(REPO, "docs", "locale", "ui-labels.json")


def installed():
    """(version, build) of the Logic on this machine, or None when there is none."""
    if not os.path.exists(LOGIC_PLIST):
        return None
    try:
        with open(LOGIC_PLIST, "rb") as handle:
            plist = plistlib.load(handle)
    except (OSError, ValueError):
        return None
    version = str(plist.get("CFBundleShortVersionString") or "").strip()
    build = str(plist.get("CFBundleVersion") or "").strip()
    return (version, build) if version and build else None


def readings(target):
    """(records, label readings) that name a build other than `target`."""
    stale_records = []
    for path in sorted(glob.glob(os.path.join(OBS, "*.json"))):
        name = os.path.basename(path)
        if not re.match(r"^\d{4}-\d{2}-\d{2}-.*\.json$", name):
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                host = json.load(handle).get("host") or {}
        except (OSError, ValueError):
            continue
        if (str(host.get("version") or ""), str(host.get("build") or "")) != target:
            stale_records.append(name[:-5])

    stale_labels = []
    try:
        with open(LABELS, encoding="utf-8") as handle:
            entries = (json.load(handle).get("labels") or {})
    except (OSError, ValueError):
        entries = {}
    for label, entry in entries.items():
        for variant, prov in (entry.get("provenance") or {}).items():
            host = prov.get("host") if isinstance(prov, dict) else None
            seen = re.match(r"^\s*Logic Pro\s+([0-9][0-9.]*)\s+\(([^)]+)\)", str(host or ""))
            if not seen or (seen.group(1), seen.group(2)) != target:
                stale_labels.append(f"{label}→{variant}")
    return stale_records, stale_labels


def main():
    as_json = "--json" in sys.argv[1:]
    try:
        with open(DECLARATION, encoding="utf-8") as handle:
            declared = json.load(handle)
    except (OSError, ValueError) as exc:
        print(f"cannot read {os.path.relpath(DECLARATION, REPO)}: {exc}", file=sys.stderr)
        return 2

    target = (str(declared.get("version") or ""), str(declared.get("build") or ""))
    here = installed()
    stale_records, stale_labels = readings(target)

    if as_json:
        json.dump({
            "declared": {"version": target[0], "build": target[1]},
            "installed": None if here is None else {"version": here[0], "build": here[1]},
            "agree": here == target,
            "records_naming_another_build": stale_records,
            "label_readings_naming_another_build": stale_labels,
        }, sys.stdout, ensure_ascii=False, indent=1)
        print()
        return 0

    print(f"declared   Logic Pro {target[0]} ({target[1]})")
    if here is None:
        print("installed  no Logic Pro on this machine — nothing to compare")
    else:
        print(f"installed  Logic Pro {here[0]} ({here[1]})")

    # Against the DECLARATION, which is what the ratchet counts. Non-zero here means readings are
    # already carried as drift; it does not depend on which Logic is installed.
    print(f"\nagainst the declaration: {len(stale_records)} record(s) and "
          f"{len(stale_labels)} label reading(s) name another build")
    for name in stale_records[:5]:
        print(f"    record  {name}")
    for name in stale_labels[:5]:
        print(f"    label   {name}")
    if len(stale_records) + len(stale_labels) > 10:
        print(f"    … and {len(stale_records) + len(stale_labels) - 10} more")

    if here is None or here == target:
        print("\nThe declaration matches what is installed. Nothing to do.")
        return 0

    total = len([1 for _ in glob.glob(os.path.join(OBS, "*.json"))])
    print(f"""
THE DECLARATION IS BEHIND THE INSTALLED LOGIC.

Bumping `docs/observations/LOGIC-BUILD.json` to {here[0]} ({here[1]}) will move every reading taken
on {target[0]} ({target[1]}) into the ratchet's drift sets — roughly {total} records and the label
readings above. The ratchet then REFUSES until each is either

    re-measured on the new Logic     (which shrinks the set, and is the point), or
    carried by a dated `raised` entry naming it exactly and saying why.

That refusal is the feature: a Logic update changes what the UI says, and a reading taken before it
is a claim about a program that no longer exists. Bump the declaration when you are ready to answer
for each reading, not before — and nothing silently becomes true in the meantime, because the
ratchet is comparing against the declaration rather than against this machine.""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
