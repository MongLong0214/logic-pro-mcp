#!/usr/bin/env python3
"""Print the `host` block for an observation record, measured from this machine.

Why this exists: the host block says what a claim is true OF, and drift against it is
the whole reason the records are kept. On 2026-09-04 all nine records in the tree carried
`macOS 26.6` on a machine running `macOS 26.3` — the first record's block was written by
hand and every later record inherited it by copy. A field that is copied is not a
measurement, and a wrong one silently widens the set of claims believed current.

So the block is generated. Paste the output, or:

    Scripts/observation_host.py --json | python3 -c "..."      # build a record
    Scripts/observation_host.py --check docs/observations/*.json   # audit existing ones

`--check` compares only what this machine can still witness: a record taken on another
host is not wrong, so it reports differences and exits 0. It is a reading aid, not a gate.

The module name uses an underscore so `observations-status.py` can import `host()` instead
of restating the format string. Two copies of `macOS {version} ({build})` that drift apart
would mark every record stale at once, which is the loudest possible way to be wrong.
"""
import glob
import os
import re
import json
import plistlib
import subprocess
import sys

LOGIC_PLIST = "/Applications/Logic Pro.app/Contents/Info.plist"
SYSTEM_PLIST = "/System/Library/CoreServices/SystemVersion.plist"


def _plist(path):
    try:
        with open(path, "rb") as fh:
            return plistlib.load(fh)
    except (OSError, plistlib.InvalidFileException):
        return {}


def measured_os():
    info = _plist(SYSTEM_PLIST)
    version, build = info.get("ProductVersion"), info.get("ProductBuildVersion")
    if not version:
        return None
    return f"macOS {version} ({build})" if build else f"macOS {version}"


def measured_locale():
    try:
        out = subprocess.run(["defaults", "read", "-g", "AppleLocale"],
                             capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    value = out.stdout.strip()
    # AppleLocale is `ko_KR`; records use BCP-47 `ko-KR`, and a bare `ko` stays bare.
    return value.replace("_", "-") or None if out.returncode == 0 else None


def host():
    """What this machine is. Keys absent rather than guessed when unreadable."""
    info = _plist(LOGIC_PLIST)
    block = {
        "app": "Logic Pro",
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "locale": measured_locale(),
        "os": measured_os(),
    }
    return {k: v for k, v in block.items() if v is not None}


def check(paths):
    here = host()
    axes = ("version", "build", "locale", "os")
    for path in paths:
        try:
            doc = json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError):
            print(f"{path}: unreadable")
            continue
        recorded = doc.get("host") or {}
        diff = [f"{k}: record {recorded.get(k)!r} vs machine {here.get(k)!r}"
                for k in axes if recorded.get(k) != here.get(k)]
        name = doc.get("id") or path
        print(f"{name}\n  " + ("\n  ".join(diff) if diff else "matches this machine"))
    return 0


def main():
    args = sys.argv[1:]
    if args and args[0] == "--check":
        # A record is a date-prefixed file, which is what the schema guard requires; RATCHETS.json
        # beside them has no host block and is not one.
        targets = args[1:] or sorted(p for p in glob.glob("docs/observations/*.json")
                                     if re.match(r"^\d{4}-\d{2}-\d{2}-", os.path.basename(p)))
        return check(targets)
    print(json.dumps(host(), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
