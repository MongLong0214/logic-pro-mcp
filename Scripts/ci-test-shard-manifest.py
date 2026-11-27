#!/usr/bin/env python3
"""Partition and verify exact Swift Testing manifests for N coverage shards."""

import argparse
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


class ManifestError(ValueError):
    pass


def _read(path: Path, *, label: str, require_sorted: bool = False) -> list[str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ManifestError(f"cannot read {label} {path}: {error}") from error
    if not lines:
        raise ManifestError(f"{label} is empty: {path}")
    if any(not line.strip() or line != line.strip() for line in lines):
        raise ManifestError(f"{label} contains a blank or padded entry: {path}")
    if len(lines) != len(set(lines)):
        raise ManifestError(f"{label} contains a duplicate entry: {path}")
    if require_sorted and lines != sorted(lines):
        raise ManifestError(f"{label} is not byte-sorted: {path}")
    return lines


def _write_new(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("x", encoding="utf-8", newline="\n") as handle:
            handle.write("\n".join(lines) + "\n")
    except FileExistsError as error:
        raise ManifestError(f"refusing to replace existing manifest: {path}") from error


# SwiftPM applies --filter as a regular expression to the module-qualified identifier that
# `swift test list` prints (measured with a local `swift test --skip-build --filter`: an anchored
# pattern ending in `$` selects nothing for Swift Testing, one ending in `(?:/|$)` selects exactly
# the test). The shard also checks its xUnit output against its own manifest, so a filter that
# selected the wrong tests fails verify-xunit instead of passing quietly.
_REGEX_METACHARACTERS = frozenset("\\.^$|?*+()[]{}")

# One command-line argument carries the whole filter. macOS allows about 1 MiB for arguments and
# environment together, so a shard that outgrows this fails the partition step (add shards)
# rather than failing later inside exec.
MAX_FILTER_BYTES = 400_000


def _literal(text: str) -> str:
    return "".join("\\" + char if char in _REGEX_METACHARACTERS else char for char in text)


def shard_manifest_path(directory: Path, index: int) -> Path:
    return directory / f"shard-{index}.txt"


def shard_filter_path(directory: Path, index: int) -> Path:
    return directory / f"shard-{index}.filter"


def shard_filter(entries: list[str]) -> str:
    """An anchored regular expression that matches exactly these identifiers.

    Entries are grouped by everything up to their last separator so the pattern names each suite
    once, which keeps it short and lets the matcher reject a non-member at the suite name.
    """
    groups: dict[str, list[str]] = {}
    for entry in entries:
        separator = "/" if "/" in entry else "."
        head, tail = entry.rsplit(separator, 1)
        groups.setdefault(head + separator, []).append(tail)
    branches = [
        _literal(head) + "(?:" + "|".join(_literal(tail) for tail in tails) + ")"
        for head, tails in groups.items()
    ]
    # SwiftPM matches Swift Testing against the identifier followed by "/<file>:<line>:<column>",
    # and XCTest against the bare identifier, so the identifier must end at a "/" or the end.
    return "^(?:" + "|".join(branches) + ")(?:/|$)"


def partition_manifest(inventory_path: Path, shard_count: int, output_directory: Path) -> None:
    """Deal the byte-sorted inventory round-robin into `shard_count` shards.

    Entry i of the sorted inventory goes to shard i mod N. Tests of one suite are adjacent in
    that order, so every suite, including a very long one, is spread over all the shards, and no
    list of suites or timings has to be maintained. A stale assumption can only cost balance:
    verify_union proves exactness against the inventory afterwards.
    """
    if shard_count < 1:
        raise ManifestError(f"shard count must be at least 1: {shard_count}")
    inventory = sorted(_read(inventory_path, label="test inventory"))
    if len(inventory) < shard_count:
        raise ManifestError(
            f"inventory has {len(inventory)} tests, fewer than {shard_count} shards")
    manifests = [shard_manifest_path(output_directory, index) for index in range(shard_count)]
    for index, path in enumerate(manifests):
        entries = inventory[index::shard_count]
        pattern = shard_filter(entries)
        if len(pattern.encode("utf-8")) > MAX_FILTER_BYTES:
            raise ManifestError(
                f"shard {index} filter exceeds {MAX_FILTER_BYTES} bytes; use more shards")
        try:
            re.compile(pattern)
        except re.error as error:
            raise ManifestError(f"shard {index} filter is not a regular expression: {error}") from error
        _write_new(path, entries)
        _write_new(shard_filter_path(output_directory, index), [pattern])
    verify_union(inventory_path, manifests)


def verify_union(inventory_path: Path, shard_paths: list[Path]) -> None:
    """Every inventory entry is in exactly one shard manifest, and nothing else is."""
    if not shard_paths:
        raise ManifestError("no shard manifests given")
    inventory = set(_read(inventory_path, label="test inventory"))
    owner: dict[str, Path] = {}
    for path in shard_paths:
        for entry in _read(path, label="shard manifest", require_sorted=True):
            if entry in owner:
                raise ManifestError(
                    f"shard manifests overlap: {entry!r} is in {owner[entry].name} and {path.name}")
            owner[entry] = path
    union = set(owner)
    if union != inventory:
        missing = sorted(inventory - union)[:3]
        extra = sorted(union - inventory)[:3]
        raise ManifestError(f"shard union differs from inventory; missing={missing} extra={extra}")


def _expected_xunit_index(expected: set[str]) -> dict[tuple[str, str], str]:
    index: dict[tuple[str, str], str] = {}
    for entry in expected:
        separator = "/" if "/" in entry else "."
        if separator not in entry:
            raise ManifestError(f"malformed expected manifest entry: {entry}")
        classname, name = entry.rsplit(separator, 1)
        if not classname or not name:
            raise ManifestError(f"malformed expected manifest entry: {entry}")
        key = (classname.replace("/", "."), name)
        previous = index.get(key)
        if previous is not None:
            raise ManifestError(
                f"canonical xUnit key collision: {previous!r} and {entry!r}")
        index[key] = entry
    return index


def verify_xunit(expected_path: Path, xunit_directory: Path, actual_path: Path) -> None:
    expected = set(_read(expected_path, label="expected shard manifest", require_sorted=True))
    expected_xunit_index = _expected_xunit_index(expected)
    try:
        xml_files = sorted(path for path in xunit_directory.iterdir()
                           if path.is_file() and path.suffix == ".xml")
    except OSError as error:
        raise ManifestError(f"cannot inspect xUnit directory {xunit_directory}: {error}") from error
    if len(xml_files) != 1:
        raise ManifestError(
            f"expected exactly one xUnit XML output; found {[path.name for path in xml_files]}")
    wanted = xml_files[0]
    try:
        root = ET.parse(wanted).getroot()
    except (OSError, ET.ParseError) as error:
        raise ManifestError(f"cannot parse xUnit output {wanted}: {error}") from error

    raw_cases: set[tuple[str, str]] = set()
    actual: set[str] = set()
    for testcase in root.iter("testcase"):
        classname = testcase.get("classname")
        name = testcase.get("name")
        if not classname or not name:
            raise ManifestError("xUnit testcase lacks classname or name")
        if testcase.find("failure") is not None or testcase.find("error") is not None:
            raise ManifestError(f"xUnit testcase failed: {classname}/{name}")
        raw_case = (classname, name)
        if raw_case in raw_cases:
            raise ManifestError(
                f"xUnit contains a duplicate xUnit testcase key: {classname}/{name}")
        raw_cases.add(raw_case)
        resolved = expected_xunit_index.get(raw_case)
        if resolved is None:
            raise ManifestError(f"unexpected xUnit testcase: {classname}/{name}")
        if resolved in actual:
            raise ManifestError(f"xUnit contains a canonical duplicate: {resolved}")
        actual.add(resolved)
    if not raw_cases:
        raise ManifestError("xUnit contains no testcases")
    if actual != expected:
        missing = sorted(expected - actual)[:3]
        extra = sorted(actual - expected)[:3]
        raise ManifestError(f"xUnit differs from expected manifest; missing={missing} extra={extra}")
    _write_new(actual_path, sorted(actual))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    partition = subparsers.add_parser("partition")
    partition.add_argument("--inventory", type=Path, required=True)
    partition.add_argument("--shards", type=int, required=True)
    partition.add_argument("--output-directory", type=Path, required=True)

    xunit = subparsers.add_parser("verify-xunit")
    xunit.add_argument("--expected", type=Path, required=True)
    xunit.add_argument("--xunit-directory", type=Path, required=True)
    xunit.add_argument("--actual", type=Path, required=True)

    union = subparsers.add_parser("verify-union")
    union.add_argument("--inventory", type=Path, required=True)
    union.add_argument("--shard", type=Path, action="append", required=True)
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.command == "partition":
            partition_manifest(args.inventory, args.shards, args.output_directory)
        elif args.command == "verify-xunit":
            verify_xunit(args.expected, args.xunit_directory, args.actual)
        else:
            verify_union(args.inventory, args.shard)
    except ManifestError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
