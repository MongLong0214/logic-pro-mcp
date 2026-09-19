#!/usr/bin/env python3
"""Deterministically (re)generate the managed qualification fixtures and their
SHA-256 manifest for the LPMCP-PRD-001 / ADR-001 R-MATRIX debt.

The fixtures are canonical, reproducible *descriptors* of the qualification
matrix inputs. Each descriptor pins the project state a qualification run is
expected to establish for one axis of the ship matrix. They are content —
byte-stable and SHA-bound in `fixture-manifest.json` — not opaque labels.

Ship matrix (owner decision 2026-07-17, ADR-001): Desktop Logic Pro only,
UI locales en-US and ko-KR. Creator Studio is permanently out of scope. The
required same-artifact matrix is therefore `desktop x {en-US, ko-KR}` with the
`empty` project fixture. The `medium` and `large` project sizes are additional
managed inputs for broader reproducible coverage.

Regenerate with `python3 Fixtures/qualification/generate-fixtures.py`; the
output is deterministic, so a clean tree stays byte-identical and the manifest
SHA-256 values keep binding the fixtures. `ManagedQualificationFixtureTests`
recomputes every SHA from the file bytes and fails closed on any drift.
"""

import hashlib
import json
import pathlib

FIXTURES_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = FIXTURES_DIR.parent.parent

VARIANT = "desktop"
LOCALES = ["en-US", "ko-KR"]
PROFILE = "core"
CACHE = "cold"

# Deterministic project track counts per fixture size.
TRACK_COUNTS = {"empty": 0, "medium": 8, "large": 32}


def track(index: int) -> dict:
    """A deterministic track definition; identical inputs yield identical bytes."""
    kind = "software_instrument" if index % 2 == 0 else "audio"
    return {
        "index": index,
        "name": f"Track {index + 1:02d}",
        "kind": kind,
        "muted": False,
        "soloed": False,
        "region_count": (index % 3) + 1,
    }


def descriptor(locale: str, fixture: str) -> dict:
    key = f"{VARIANT}/{locale}/{PROFILE}/{CACHE}/{fixture}"
    track_count = TRACK_COUNTS[fixture]
    return {
        "schema": "qualification-managed-fixture/v1",
        "key": key,
        "axis": {
            "variant": VARIANT,
            "locale": locale,
            "profile": PROFILE,
            "cache": CACHE,
            "fixture": fixture,
        },
        "description": (
            f"Canonical {fixture} project qualification input for Logic Pro "
            f"Desktop under the {locale} UI locale. Reproducible descriptor of "
            "the project state a same-artifact qualification run establishes for "
            "this axis; project content depends on the fixture size only, while "
            "the locale identifies the UI the run drives."
        ),
        "project": {
            "tempo_bpm": 120,
            "time_signature": "4/4",
            "sample_rate_hz": 48000,
            "track_count": track_count,
            "tracks": [track(i) for i in range(track_count)],
        },
    }


def encode(obj: dict) -> bytes:
    return (json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def main() -> None:
    entries = []
    for locale in LOCALES:
        for fixture in TRACK_COUNTS:
            data = encode(descriptor(locale, fixture))
            filename = f"{VARIANT}-{locale}-{fixture}.json"
            (FIXTURES_DIR / filename).write_bytes(data)
            entries.append(
                {
                    "path": f"Fixtures/qualification/{filename}",
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "axis": f"{VARIANT}/{locale}/{PROFILE}/{CACHE}/{fixture}",
                }
            )
    entries.sort(key=lambda entry: entry["path"])
    manifest = encode(entries)
    (FIXTURES_DIR / "fixture-manifest.json").write_bytes(manifest)
    for entry in entries:
        print(f"{entry['sha256']}  {entry['path']}")


if __name__ == "__main__":
    main()
