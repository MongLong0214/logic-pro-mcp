#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
# How to run:
# python3 Scripts/live-qualification-runner.py --artifact PATH --sha256 HEX --release-version VERSION
"""Emit a non-live ADR-001 qualification attestation skeleton.

Live execution and CI enforcement are deferred: full same-artifact live
qualification cannot be unattended. This script only concretizes the
attestation schema and matrix; it never calls Logic Pro or MCP.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import itertools
import json
from datetime import datetime, timezone
from pathlib import Path


def artifact_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as artifact:
        for chunk in iter(lambda: artifact.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--release-version", required=True)
    args = parser.parse_args()

    if not args.artifact.is_file():
        parser.error(f"artifact is not a file: {args.artifact}")
    digest = artifact_sha256(args.artifact)
    if not hmac.compare_digest(digest, args.sha256.lower()):
        parser.error(f"artifact SHA-256 mismatch: expected {args.sha256.lower()}, actual {digest}")

    cases = []
    matrix = itertools.product(
        ("desktop", "creator"),
        ("en-US", "ko-KR"),
        ("core", "full"),
        ("cold", "warm"),
        ("empty", "medium", "large"),
    )
    for variant, locale, profile, cache, fixture in matrix:
        case_id = f"{variant}/{locale}/{profile}/{cache}/{fixture}"
        cases.append(
            {
                "id": case_id,
                "status": "not_qualified",
                "tool": "",
                "command": "",
                "trace_id": "",
                "verified": False,
                "evidence_files": [],
            }
        )

    swift_reference_date = datetime(2001, 1, 1, tzinfo=timezone.utc)
    timestamp = (datetime.now(timezone.utc) - swift_reference_date).total_seconds()
    attestation = {
        "schema": "release-qualification-attestation/v1",
        "serverVersion": args.release_version,
        "commitSHA": "not_qualified",
        "binarySHA256": digest,
        "logicVariant": "desktop",
        "logicVersion": "not_qualified",
        "locale": "en-US",
        "profile": "core",
        "startedAt": timestamp,
        "completedAt": timestamp,
        "total": len(cases),
        "passed": 0,
        "failed": 0,
        "waived": 0,
        "cases": cases,
        "waivers": [],
        "evidenceManifestSHA256": "",
    }

    # Promotion policy remains single-sourced in Swift PromotionGate.
    # TODO(#284): replace placeholders only when the full live matrix can run on one artifact.
    print(json.dumps(attestation, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
