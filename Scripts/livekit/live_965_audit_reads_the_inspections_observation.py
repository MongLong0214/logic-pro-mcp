#!/usr/bin/env python3
"""#965 O3: the session audit and the inspection report the same file-bound track count.

`logic_project audit` and `logic_project inspect_session` both observe the session through
`SessionPopulationObservation.observe`: one cache read, and the project bundle's MetaData.plist
track count, kept only when the bundle Logic names is the cached project's. The unit tests drive
the case where it is not. This run drives the real fixture, where it is: for each language one
server refreshes its cache, then the inspection's `tracks.witnesses.expected_count` and the audit's
`track_readback_gap` evidence are read back to back.

A row passes when the inspection names an expected count and its tracks reasons carry
`track_readback_gap` exactly when the audit raises that finding, with `file_track_count` equal to
the inspection's expected count; or when neither names a gap and both counts agree.

    LPM_LIVE_LOCK=<lock> LPM_EVIDENCE_ROOT=<dir> LPM_LOCALE_FIXTURE=<fixture> \\
        python3 live_965_audit_reads_the_inspections_observation.py <worktree> <head> <binary> [--lprojs ...]

Reads only: no Logic state changes beyond the language relaunch. Leaves Logic in Korean.
"""
import argparse
import hashlib
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import evidence as E  # noqa: E402
import live_993_plugin_root_menu_in_every_locale as L993  # noqa: E402


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("worktree")
    parser.add_argument("head")
    parser.add_argument("binary")
    parser.add_argument("--lprojs", nargs="+", default=list(L993.DEFAULT_LPROJS))
    return parser.parse_args()


def gap_count(audit):
    """The audit's `track_readback_gap` file count, or None when it raised no such finding."""
    for finding in (audit or {}).get("findings") or []:
        if finding.get("id") == "track_readback_gap":
            for value in (finding.get("evidence") or {}).get("values") or []:
                if value.startswith("file_track_count="):
                    return int(value.split("=", 1)[1])
    return None


def agree(row):
    """The inspection names an expected count, and the audit's gap finding is present exactly when the
    inspection's tracks reasons carry `track_readback_gap`, with the same count."""
    expected = row.get("inspection_expected_count")
    if not isinstance(expected, int):
        return False
    if row.get("inspection_names_the_gap"):
        return row.get("audit_gap_file_count") == expected
    return row.get("audit_gap_file_count") is None


def disagreeing(row):
    """The counterexample: the audit counting a different bundle's tracks than the inspection kept."""
    expected = row.get("inspection_expected_count")
    return dict(row, audit_gap_file_count=(expected or 0) + 5, inspection_names_the_gap=True)


def read_language(driver):
    driver.tool("logic_system", "refresh_cache")
    time.sleep(1.0)
    report = driver.tool("logic_project", "inspect_session", {"domains": ["tracks"]}) or {}
    audit = driver.tool("logic_project", "audit") or {}
    tracks = report.get("tracks") or {}
    witnesses = tracks.get("witnesses") or {}
    return {
        "inspection_expected_count": witnesses.get("expected_count"),
        "inspection_expected_count_source": witnesses.get("expected_count_source"),
        "inspection_rows": witnesses.get("count"),
        "inspection_reasons": tracks.get("reasons"),
        "inspection_names_the_gap": "track_readback_gap" in (tracks.get("reasons") or []),
        "audit_gap_file_count": gap_count(audit),
        "audit_status": audit.get("status"),
        "audit_finding_ids": [f.get("id") for f in audit.get("findings") or []],
    }


def sha256_of(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def main():
    args = arguments()
    sys.path.insert(0, os.path.join(args.worktree, "Scripts"))
    import logic_canon  # noqa: E402
    setattr(L993, "logic_canon", logic_canon)
    ev = E.Evidence(args.head, os.environ["LPM_EVIDENCE_ROOT"], surface="non_ui")
    ev.note("965/binary", {"binary": args.binary, "sha256": sha256_of(args.binary)})
    rows = []
    try:
        for lproj in args.lprojs:
            launch = L993.switch_to(lproj, force=True)
            ev.note(f"965/{lproj}/launch", launch)
            if not launch.get("arrange_window"):
                rows.append({"lproj": lproj, "error": "launch"})
                continue
            driver = E.Driver(binary=args.binary)
            try:
                time.sleep(8)
                row = dict(read_language(driver), lproj=lproj)
            finally:
                driver.close()
            rows.append(row)
            ev.falsifiable(f"965/{lproj}/audit-and-inspection-agree", agree, row, disagreeing(row),
                           expected="the audit's gap finding matches the inspection's file-bound count")
            print(json.dumps(row, ensure_ascii=False), flush=True)
    finally:
        ev.note("965/restore", L993.switch_to(L993.RESTORE, force=True))
    ev.note("965/rows", rows)
    out = ev.write()
    print("written", out)
    failed = [r["lproj"] for r in rows if not agree(r)]
    print(json.dumps({"rows": len(rows), "failed": failed}))
    return 0 if rows and not failed and len(rows) == len(args.lprojs) else 1


if __name__ == "__main__":
    sys.exit(main())
