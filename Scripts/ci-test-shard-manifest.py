#!/usr/bin/env python3
"""Partition and verify exact Swift Testing manifests for coverage shards."""

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


def partition_manifest(
    inventory_path: Path, selector: str, selected_path: Path, complement_path: Path
) -> None:
    inventory = _read(inventory_path, label="test inventory")
    try:
        pattern = re.compile(selector)
    except re.error as error:
        raise ManifestError(f"invalid shard selector {selector!r}: {error}") from error
    selected = sorted(entry for entry in inventory if pattern.search(entry))
    complement = sorted(entry for entry in inventory if not pattern.search(entry))
    if not selected:
        raise ManifestError("selected shard is empty")
    if not complement:
        raise ManifestError("complement shard is empty")
    _write_new(selected_path, selected)
    _write_new(complement_path, complement)
    verify_union(inventory_path, selected_path, complement_path)


def verify_union(inventory_path: Path, selected_path: Path, complement_path: Path) -> None:
    inventory = set(_read(inventory_path, label="test inventory"))
    selected = set(_read(selected_path, label="selected manifest", require_sorted=True))
    complement = set(_read(complement_path, label="complement manifest", require_sorted=True))
    overlap = selected & complement
    if overlap:
        raise ManifestError(f"shard manifests overlap: {sorted(overlap)[:3]}")
    union = selected | complement
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
    partition.add_argument("--selector", required=True)
    partition.add_argument("--selected", type=Path, required=True)
    partition.add_argument("--complement", type=Path, required=True)

    xunit = subparsers.add_parser("verify-xunit")
    xunit.add_argument("--expected", type=Path, required=True)
    xunit.add_argument("--xunit-directory", type=Path, required=True)
    xunit.add_argument("--actual", type=Path, required=True)

    union = subparsers.add_parser("verify-union")
    union.add_argument("--inventory", type=Path, required=True)
    union.add_argument("--selected", type=Path, required=True)
    union.add_argument("--complement", type=Path, required=True)
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.command == "partition":
            partition_manifest(args.inventory, args.selector, args.selected, args.complement)
        elif args.command == "verify-xunit":
            verify_xunit(args.expected, args.xunit_directory, args.actual)
        else:
            verify_union(args.inventory, args.selected, args.complement)
    except ManifestError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
