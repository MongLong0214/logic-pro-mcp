#!/usr/bin/env python3
"""What a Logic update costs, before you pay it.

`AXLocalePolicy.currentLogicVersion`/`currentLogicBuild` (Swift, the one declaration) name the Logic
every reading in this repository is judged against. `check-observation-ratchets.py` counts readings that name a DIFFERENT build,
as sets that may only shrink — so bumping the declaration turns a Logic update into a refusal you
have to answer, one reading at a time, instead of a hundred records quietly describing a build
nobody runs.

This command is the other half: it compares the DECLARATION to the Logic actually installed on this
machine, and says what bumping would cost. It is a reading aid and exits 0 whether or not they
agree — the refusal lives in the ratchet, where CI can see it. Logic is not installed in CI, which
is why the declaration is declared rather than detected in the first place.

    Scripts/logic-build-drift.py            compare and report
    Scripts/logic-build-drift.py --json     the same, machine-readable

AND IT IS THE TRIGGER (`observations/drift_agent.py`): a launchd agent runs it, so a Logic update starts its
own answer instead of waiting for somebody to remember.

    Scripts/logic-build-drift.py --install      write and load the agent (hourly, and when Logic's Info.plist
                                                changes); --uninstall removes it
    Scripts/logic-build-drift.py --agent        what launchd runs: detect drift, take the live-run lock, and
                                                answer it on a new branch -- or HOLD if Logic is busy
    Scripts/logic-build-drift.py --agent --dry-run --fake-installed 13.1:7900
                                                the same against a FAKED installed Logic, running nothing
"""
import glob
import json
import os
import plistlib
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DECLARATION = os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
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
            prov = prov if isinstance(prov, dict) else {}
            if (str(prov.get("logic_version") or ""), str(prov.get("logic_build") or "")) != target:
                stale_labels.append(f"{label}→{variant}")
    return stale_records, stale_labels


def _agent_module():
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "observations", "drift_agent.py")
    spec = importlib.util.spec_from_file_location("drift_agent", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["drift_agent"] = module
    spec.loader.exec_module(module)
    return module


def main():
    args = sys.argv[1:]
    if {"--install", "--uninstall", "--bump", "--agent"} & set(args):
        agent = _agent_module()
        if "--install" in args:
            for command in agent.install():
                print("ran:", " ".join(command))
            print(f"installed {agent.AGENT_PLIST}")
            return 0
        if "--uninstall" in args:
            agent.uninstall()
            print(f"removed {agent.AGENT_PLIST}")
            return 0
        if "--bump" in args:
            version, build = args[args.index("--bump") + 1:args.index("--bump") + 3]
            with open(DECLARATION, encoding="utf-8") as handle:
                text = handle.read()
            with open(DECLARATION, "w", encoding="utf-8") as handle:
                handle.write(agent.bump_declaration(text, version, build))
            print(f"declared Logic {version} ({build})")
            return 0
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import locale_release
        declared = locale_release.declared_logic(DECLARATION)
        fake = agent.parse_fake(args[args.index("--fake-installed") + 1]) if "--fake-installed" in args else None
        return agent.agent(declared, fake or installed(), dry_run="--dry-run" in args)
    as_json = "--json" in sys.argv[1:]
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import locale_release
    try:
        declared = locale_release.declared_logic(DECLARATION)
    except ValueError as exc:
        print(f"cannot read the declaration: {exc}", file=sys.stderr)
        return 2
    if declared is None:
        print(f"{os.path.relpath(DECLARATION, REPO)} declares no current Logic", file=sys.stderr)
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

Bumping `AXLocalePolicy.currentLogicVersion`/`currentLogicBuild` to {here[0]} ({here[1]}) will move every reading taken
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
