#!/usr/bin/env python3
"""Regenerate the self-test's evidence fixtures from the spec fixtures (`fixtures/ev-*.json`).

    python3 Scripts/verify/fixtures_build.py

Run it when a spec fixture changes. Each evidence fixture pairs a spec fixture with hand-written
readings, stored through `evidence_doc.make_observation` and judged by `engine.evaluate_run`: the
fixtures carry what a runner would carry and nothing a runner could not.

WHAT THE FIXTURES DO NOT CLAIM
------------------------------
  * No binary. The committed binary block is `unbound` with `binary_path: null`, because no
    binary exists for them; `recheck` on a committed fixture exits 3. A self-test case that needs a
    bound binary writes a temporary file, hashes it and points the evidence at it (the `bind`
    patch op in selftest.py), so the provenance the engine verifies is real on the host running it.
  * No live reading. The locale readings have the shape Scripts/verify/live/locale.py reading()
    returns. Their titles are `lpm-locale-campaign - <Tracks>`, with Apple's `Tracks` row read
    from Logic Pro 12.3's Localizable.strings on 2026-09-27 (ko: 트랙, en: Tracks). No Logic window
    was observed to make them.
"""
from __future__ import annotations

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import engine  # noqa: E402
import evidence_doc as E  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")
DATE = "2026-09-27"
TRACKS = {"ko": "트랙", "en": "Tracks"}
AXIS = {"ko": "ko-KR", "en": "en-US"}
UNBOUND_BINARY = {
    E.BINARY_PATH: None, E.BINARY_SHA256: None, E.HEAD: "d81c7e5b0d4ba2c2531dc3432809bd3e8697c4ea",
    E.BINDING: E.UNBOUND,
    "note": "self-test fixture: no binary exists, so none is claimed; cases that need one bind a "
            "temporary file (selftest.py, the `bind` patch op)",
}

REPLY = {"state": "A", "success": True, "write_attempted": True, "write_source": "mcu", "observed": True}
READINGS = {
    "spec-base.json": {"arm-sets": {
        "pre": {"track": 0, "armed": False},
        "reply": REPLY,
        "post": {"track": 0, "armed": True},
        "undo": dict(REPLY, observed=False),
        "restored": {"track": 0, "armed": False}}},
    "spec-canon.json": {"label-is-apples": {
        "before": {"title": "Tracks"},
        "open": {"state": "A", "success": True},
        "after": {"title": "Smart Controls"}}},
    "spec-ops.json": {"every-operator": {
        "before": {"armed": [], "mode": "idle", "gone": None, "stable": 7, "title": "Tracks"},
        "op": {"state": "A", "success": True},
        "after": {"armed": [15], "mode": "armed", "gone": None, "stable": 7, "title": "Smart Controls"}}},
}
OUTPUTS = {"spec-base.json": "ev-base.json", "spec-canon.json": "ev-canon.json", "spec-ops.json": "ev-ops.json"}


def locale_reading(lproj: str) -> dict:
    code = E.LOCALE_CODES[lproj]
    title = f"lpm-locale-campaign - {TRACKS[lproj]}"
    return {"lproj": lproj, "code": code,
            "expected_title": {"readable": True, "value": title},
            "language_setting": {"readable": True, "value": [code]},
            "window_names": {"readable": True, "value": [title]}}


def host(lproj: str) -> dict:
    return {"app": "Logic Pro", "version": "12.3", "build": "6674", "locale": AXIS[lproj],
            "os": "macOS 26.3 (25D125)"}


def build(spec_name: str) -> dict:
    with open(os.path.join(FIXTURES, spec_name), encoding="utf-8") as handle:
        spec = json.load(handle)
    doc = E.new_document(spec, f"Scripts/verify/fixtures/{spec_name}", dict(UNBOUND_BINARY))
    for lproj in engine.required_locales(spec):
        run = {"date": DATE, "host": host(lproj), E.LOCALE_READING: locale_reading(lproj), "rows": {}}
        for row in spec["rows"]:
            values = READINGS[spec_name][row["id"]]
            run["rows"][row["id"]] = {"observations": {
                step["as"]: E.make_observation(step, json.dumps(values[step["as"]], ensure_ascii=False,
                                                                sort_keys=True))
                for step in row["steps"] + row["restore"]}}
        doc["runs"][lproj] = run
        doc["verdicts"][lproj] = engine.evaluate_run(spec, run, lproj)
    return doc


def main() -> int:
    for spec_name, out in OUTPUTS.items():
        E.write_atomic(os.path.join(FIXTURES, out), build(spec_name))
        print(f"wrote {os.path.join('Scripts/verify/fixtures', out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
