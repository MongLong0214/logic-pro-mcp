"""The canon guard's per-record check, callable before a record is written.

`refusals(record)` runs `check_record` of Scripts/check-canon-citations.py -- the check CI runs over
every file in docs/observations, rule 13 among its rules -- on `record` as it would be written, and
returns what that check refuses. It loads the guard; it copies none of its rules. The fixed
verifier's record writer (Scripts/verify/verify.py `record_attested`) calls it, so `--record` never
writes a record the repository's guard would refuse.

It sits outside Scripts/verify because loading a file by path takes importlib, which the
verifier's own modules may not import (Scripts/verify/selftest.py, UNPICKLERS).
"""
from __future__ import annotations

import importlib.util
import json
import os
import tempfile

GUARD_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-canon-citations.py")


def _guard():
    spec = importlib.util.spec_from_file_location("check_canon_citations_for_records", GUARD_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def refusals(record: dict) -> list:
    """What check-canon-citations would refuse in `record`, each naming the record by its id;
    empty when it would accept it."""
    guard = _guard()
    failures: list = []
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, f"{record['id']}.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(record, handle, ensure_ascii=False, indent=1)
        guard.check_record(path, failures, set(), guard.canon.load_manifest())
        shown = os.path.relpath(path, guard.REPO)
    return [line.replace(shown, record["id"]) for line in failures]
