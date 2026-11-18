#!/usr/bin/env python3
"""Keep census evidence small: one JSON Lines file per locale per kind per Logic build, records compact.

    census_pack.py repack          rewrite every census record on the DECLARED release in the compact form,
                                   and its evidence as JSON Lines (`census_evidence`); the old file goes
    census_pack.py prune [--repoint] [--dry-run]
                                   delete the evidence a newer census of the same locale, kind and build
                                   supersedes, and the records that cite only it -- unless a ledger cell
                                   still cites the record, which is reported and kept
    census_pack.py status          what is on disk, by locale

A census is a measurement of ONE Logic build in ONE locale; a second file for the same triple is the same
measurement taken twice, and each costs a thousand lines to review. `repack` and `prune` are mechanical and
change no fact: every string, row and citation is the one that was there. The digest a reading carries
(`record_sha256`) covers the BYTES of the record and of its evidence, so after either one the ledger is
re-bound with `locale_labels.py --write --rebind`, the documented path; `locale_campaign.py` does that.

Only the declared release is touched. A record of an older build is history, and is left as written.
"""
import glob
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
REPO = os.path.dirname(SCRIPTS)


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(SCRIPTS, filename))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _tools():
    return (_load("census_pack_evidence", "census_evidence.py"), _load("census_pack_compact", "compact_json.py"),
            _load("census_pack_labels", "locale_labels.py"))


EVIDENCE_NAME = re.compile(r"^(\d{4}-\d{2}-\d{2})-(.+?)-(navigation-free|navigation)\.census\.json(l?)$")


def _records(obs_dir):
    for path in sorted(glob.glob(os.path.join(obs_dir, "20*.json"))):
        try:
            with open(path, encoding="utf-8") as handle:
                yield path, json.load(handle)
        except (OSError, ValueError):
            continue


def _on_declared(doc, declared):
    host = doc.get("host") or {}
    return (str(host.get("version")), str(host.get("build"))) == (declared["version"], declared["build"])


def repack(repo=REPO):
    """Rewrite the declared release's census evidence as JSONL and its records compactly. Returns counts."""
    census_evidence, compact, labels = _tools()
    obs_dir = os.path.join(repo, "docs", "observations")
    declared = labels.declared_logic(os.path.join(repo, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift"))
    moved = rewritten = 0
    renames = {}
    for path in sorted(glob.glob(os.path.join(obs_dir, "evidence", "*.census.json"))):
        match = EVIDENCE_NAME.match(os.path.basename(path))
        if not match:
            continue
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
        if not _on_declared(doc, declared):
            continue
        kind = match.group(3)
        target = path + "l"
        with open(target, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(census_evidence.dumps(dict(doc, kind=kind)))
        os.remove(path)
        renames[f"evidence/{os.path.basename(path)}"] = f"evidence/{os.path.basename(target)}"
        moved += 1
    for path, rec in _records(obs_dir):
        if not rec.get("id", "").endswith("-census") or not _on_declared(rec, declared):
            continue
        rec["evidence"] = [renames.get(rel, rel) for rel in rec.get("evidence") or []]
        if rec.get("canon"):
            # Same citations, the three repeated fields stated once per reference (`canon_groups`).
            groups = _load("census_pack_groups", "canon_groups.py").group(rec.pop("canon"))
            rec["canon_groups"] = groups + (rec.get("canon_groups") or [])
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(compact.dumps(rec, 2))
        rewritten += 1
    return {"evidence_files": moved, "records": rewritten}


def _cited_records(repo):
    with open(os.path.join(repo, "docs", "locale", "ui-labels.json"), encoding="utf-8") as handle:
        doc = json.load(handle)
    cited = set()
    for entry in (doc.get("labels") or {}).values():
        for block in (entry.get("provenance") or {}).values():
            if isinstance(block, dict) and block.get("record"):
                cited.add(block["record"])
        cited |= {r for r in (entry.get("coverage_records") or {}).values() if r}
        cited |= {r for r in (entry.get("coverage_absent") or {}).values() if isinstance(r, str)}
    return cited


def _release_readings(repo, doomed):
    """Drop every ledger reading that cites a record in `doomed`; the next apply re-makes it from the newer
    census of the same locale. Returns how many readings were released."""
    _ev, _compact, labels = _tools()
    path = os.path.join(repo, "docs", "locale", "ui-labels.json")
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
    released = 0
    for entry in (doc.get("labels") or {}).values():
        for variant, block in list((entry.get("provenance") or {}).items()):
            if isinstance(block, dict) and block.get("record") in doomed:
                del entry["provenance"][variant]
                released += 1
        if not entry.get("provenance"):
            entry.pop("provenance", None)
        for loc, rid in list((entry.get("coverage_records") or {}).items()):
            if rid in doomed:
                entry["coverage"][loc] = "unmeasured"
                for key in ("coverage_records", "coverage_roles", "coverage_attributes", "coverage_paths",
                            "coverage_identifiers", "coverage_logic_version", "coverage_logic_build",
                            "coverage_record_sha256", "coverage_currency", "coverage_absent"):
                    (entry.get(key) or {}).pop(loc, None)
                released += 1
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(labels.render(doc))
    return released


def prune(repo=REPO, dry_run=False, repoint=False):
    """Delete superseded evidence of the declared release. Returns `(deleted files, kept-because-cited)`.

    A record a ledger cell still cites is KEPT, unless `repoint`: then the readings that cite it are
    released first, so that the next `locale-regenerate.py --apply` writes them again against the newer
    record. The facts are the same strings from the same locale and build; only the file they cite moves.
    """
    _ev, _compact, labels = _tools()
    obs_dir = os.path.join(repo, "docs", "observations")
    declared = labels.declared_logic(os.path.join(repo, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift"))
    groups = {}
    for path in glob.glob(os.path.join(obs_dir, "evidence", "*.census.json*")):
        match = EVIDENCE_NAME.match(os.path.basename(path))
        if not match:
            continue
        census = _ev.load(path)
        if not _on_declared(census, declared):
            continue
        key = (match.group(2), match.group(3))
        groups.setdefault(key, []).append((match.group(1), path))
    superseded = set()
    for files in groups.values():
        files.sort()
        superseded |= {path for _date, path in files[:-1]}
    by_evidence = {}
    for rec_path, rec in _records(obs_dir):
        for rel in rec.get("evidence") or []:
            by_evidence.setdefault(os.path.normpath(os.path.join(obs_dir, rel)), []).append((rec_path, rec))
    cited = _cited_records(repo)
    deleted, kept = [], []
    if repoint and not dry_run:
        doomed = {r["id"] for path in superseded for _p, r in by_evidence.get(os.path.normpath(path), [])}
        _release_readings(repo, doomed & cited)
        cited = _cited_records(repo)
    for path in sorted(superseded):
        owners = by_evidence.get(os.path.normpath(path), [])
        blocked = [r["id"] for _p, r in owners if r["id"] in cited]
        if blocked:
            kept.append((os.path.relpath(path, repo), blocked))
            continue
        if not dry_run:
            for rec_path, _r in owners:
                os.remove(rec_path)
            os.remove(path)
        deleted.append(os.path.relpath(path, repo))
        deleted += [os.path.relpath(p, repo) for p, _r in owners]
    return deleted, kept


def main(argv):
    cmd = argv[0] if argv else "status"
    if cmd == "repack":
        print(json.dumps(repack(), sort_keys=True))
        return 0
    if cmd == "prune":
        deleted, kept = prune(dry_run="--dry-run" in argv, repoint="--repoint" in argv)
        for name in deleted:
            print(f"deleted {name}")
        for name, why in kept:
            print(f"KEPT {name}: still cited by {', '.join(why)}")
        return 0
    obs_dir = os.path.join(REPO, "docs", "observations", "evidence")
    for path in sorted(glob.glob(os.path.join(obs_dir, "*.census.json*"))):
        print(f"{sum(1 for _ in open(path, encoding='utf-8')):7d} lines  {os.path.basename(path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
