#!/usr/bin/env python3
"""Has the pinned canon drifted from this code, or from the Logic on this machine?

#1028 (ADR-027 D6, audit B). `logic_canon.py status` compared the installed Logic with the pin,
but nothing ran it: a corpus pinned to one build went on certifying labels after the host moved to
another, and an extractor change could land without a rebuild as long as nobody asked.

Two halves, and they are NOT equally strong:

  offline   the manifest's extractor version is this code's, and every source this code can
            extract is pinned (and none it cannot). Runs everywhere, CI included, and FAILS.
  host      the installed Logic's version and build are the pinned ones. Needs Logic, so under CI
            it is SKIPPED -- and says so, with the reason, on every run. Locally a difference is a
            loud WARNING and not a failure: a developer on a newer Logic must still be able to run
            the guards, and the rebuild that settles it needs `build`, not this. The corpus digest
            comparison is `logic_canon.py status`, which reads every file and is too slow for a
            guard.

`LPM_CANON_APP` names the Logic to compare with (default `/Applications/Logic Pro.app`).

Exit: 0 = offline part holds (host warned or skipped, and said which) · 1 = offline drift
"""
import importlib.util
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _canon():
    spec = importlib.util.spec_from_file_location(
        "logic_canon_for_drift", os.path.join(REPO, "Scripts", "logic_canon.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(canon, app: str, ci: bool, out=sys.stdout, err=sys.stderr) -> int:
    try:
        manifest = canon.load_manifest()
    except canon.CanonError as exc:
        print(f"FAIL {exc}", file=err)
        return 1
    problems = canon.drift_offline(manifest)
    if problems:
        print(f"check-canon-drift: {len(problems)} offline drift problem(s)", file=err)
        for problem in problems:
            print(f"  {problem}", file=err)
        return 1
    pinned = manifest["logic"]
    line = (f"check-canon-drift: offline ok (extractor v{canon.EXTRACTOR_VERSION}, "
            f"{len(manifest['sources'])} sources pinned to Logic {pinned['version']} "
            f"({pinned['build']}))")
    if ci:
        print(f"{line}; host check SKIPPED: CI has no Logic to compare with", file=out)
        return 0
    if not os.path.isdir(app):
        print(f"{line}; host check SKIPPED: no Logic at {app}", file=out)
        return 0
    here = canon.app_build(app)
    if (here.get("version"), here.get("build")) != (pinned.get("version"), pinned.get("build")):
        print(f"{line}", file=out)
        print(f"WARNING: THE INSTALLED LOGIC IS {here.get('version')} ({here.get('build')}) AND "
              f"THE CANON IS PINNED TO {pinned['version']} ({pinned['build']}). Every label "
              f"derived from the canon describes the pinned build, not this one. Rebuild with "
              f"Scripts/logic_canon.py build.", file=err)
        return 0
    print(f"{line}; host Logic {here['version']} ({here['build']}) matches", file=out)
    return 0


def main() -> int:
    app = os.environ.get("LPM_CANON_APP") or "/Applications/Logic Pro.app"
    return run(_canon(), app, ci=bool(os.environ.get("CI")))


if __name__ == "__main__":
    raise SystemExit(main())
