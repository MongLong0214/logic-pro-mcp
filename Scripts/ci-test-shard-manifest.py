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


# Weight assumed for a test the weights file does not list. The measured median is far below a
# second; only the long tail is worth listing.
DEFAULT_WEIGHT = 0.2


def _read_weights(path: Path) -> dict[str, float]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ManifestError(f"cannot read shard weights {path}: {error}") from error
    weights: dict[str, float] = {}
    for number, line in enumerate(lines, 1):
        if not line.strip() or line.startswith("#"):
            continue
        seconds, separator, entry = line.partition("\t")
        if not separator or not entry or entry != entry.strip():
            raise ManifestError(f"malformed shard weight at {path}:{number}")
        try:
            value = float(seconds)
        except ValueError as error:
            raise ManifestError(f"malformed shard weight at {path}:{number}") from error
        if not value >= 0 or value == float("inf"):
            raise ManifestError(f"shard weight is not a finite non-negative number at {path}:{number}")
        if entry in weights:
            raise ManifestError(f"duplicate shard weight for {entry}")
        weights[entry] = value
    return weights


def assign_shards(inventory: list[str], weights: dict[str, float], count: int) -> list[list[str]]:
    """Longest-weight-first onto the lightest shard. Depends only on its inputs, never on order."""
    if count < 1:
        raise ManifestError(f"shard count must be positive, got {count}")
    loads = [0.0] * count
    shards: list[list[str]] = [[] for _ in range(count)]
    ordered = sorted(set(inventory), key=lambda entry: (-weights.get(entry, DEFAULT_WEIGHT), entry))
    for entry in ordered:
        index = min(range(count), key=lambda shard: (loads[shard], shard))
        loads[index] += weights.get(entry, DEFAULT_WEIGHT)
        shards[index].append(entry)
    return [sorted(shard) for shard in shards]


def shard_path(directory: Path, index: int) -> Path:
    return directory / f"shard-{index}.txt"


def partition_manifest(inventory_path: Path, weights_path: Path, count: int, output_directory: Path) -> None:
    inventory = _read(inventory_path, label="test inventory")
    weights = _read_weights(weights_path)
    stale = sorted(set(weights) - set(inventory))
    if stale:
        # A renamed or deleted slow test only costs balance, never coverage: every test is still
        # assigned exactly once below.
        print(f"note: {len(stale)} shard weight(s) name no current test, e.g. {stale[0]}",
              file=sys.stderr)
    shards = assign_shards(inventory, weights, count)
    for index, shard in enumerate(shards, 1):
        if not shard:
            raise ManifestError(f"shard {index} of {count} is empty")
    paths = [shard_path(output_directory, index) for index in range(1, count + 1)]
    for path, shard in zip(paths, shards):
        _write_new(path, shard)
    verify_union(inventory_path, paths, count)


def verify_union(inventory_path: Path, shard_paths: list[Path], count: int) -> None:
    if len(shard_paths) != count:
        raise ManifestError(f"expected {count} shard manifests, got {len(shard_paths)}")
    if len({path.resolve() for path in shard_paths}) != len(shard_paths):
        raise ManifestError("the same shard manifest was given twice")
    inventory = set(_read(inventory_path, label="test inventory"))
    owner: dict[str, Path] = {}
    for path in shard_paths:
        for entry in _read(path, label="shard manifest", require_sorted=True):
            previous = owner.get(entry)
            if previous is not None:
                raise ManifestError(
                    f"shard manifests overlap: {entry} is in {previous} and {path}")
            owner[entry] = path
    union = set(owner)
    if union != inventory:
        missing = sorted(inventory - union)[:3]
        extra = sorted(union - inventory)[:3]
        raise ManifestError(f"shard union differs from inventory; missing={missing} extra={extra}")


_SWIFT_REGEX_META = set("\\.^$|?*+()[]{}")


def _swift_regex_literal(text: str) -> str:
    return "".join("\\" + char if char in _SWIFT_REGEX_META else char for char in text)


def filter_pattern(manifest_path: Path) -> str:
    """One `swift test --filter` expression selecting exactly the manifest's tests.

    Swift Testing matches the expression against each test's ID, which is the listed name
    followed by `/<file>:<line>:<column>`, and against each suite's ID. Anchoring both ends of
    every listed name keeps a name from selecting a longer one or its whole suite; the xUnit
    check still proves the selection against the manifest afterwards.
    """
    entries = _read(manifest_path, label="shard manifest", require_sorted=True)
    groups: dict[str, list[str]] = {}
    for entry in entries:
        head, separator, rest = entry.partition("/")
        if not separator:
            head, rest = entry, ""
        groups.setdefault(head, []).append(rest)
    alternatives = []
    for head, rests in groups.items():
        if rests == [""]:
            alternatives.append(_swift_regex_literal(head))
            continue
        if "" in rests:
            raise ManifestError(f"{head} is listed both as a test and as a suite")
        inner = "|".join(_swift_regex_literal(rest) for rest in rests)
        alternatives.append(f"{_swift_regex_literal(head)}/(?:{inner})")
    return "^(?:" + "|".join(alternatives) + ")(?:/|$)"


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
    partition.add_argument("--weights", type=Path, required=True)
    partition.add_argument("--count", type=int, required=True)
    partition.add_argument("--output-directory", type=Path, required=True)

    pattern = subparsers.add_parser("filter-pattern")
    pattern.add_argument("--manifest", type=Path, required=True)

    xunit = subparsers.add_parser("verify-xunit")
    xunit.add_argument("--expected", type=Path, required=True)
    xunit.add_argument("--xunit-directory", type=Path, required=True)
    xunit.add_argument("--actual", type=Path, required=True)

    union = subparsers.add_parser("verify-union")
    union.add_argument("--inventory", type=Path, required=True)
    union.add_argument("--count", type=int, required=True)
    union.add_argument("shards", type=Path, nargs="+")
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.command == "partition":
            partition_manifest(args.inventory, args.weights, args.count, args.output_directory)
        elif args.command == "filter-pattern":
            print(filter_pattern(args.manifest))
        elif args.command == "verify-xunit":
            verify_xunit(args.expected, args.xunit_directory, args.actual)
        else:
            verify_union(args.inventory, args.shards, args.count)
    except ManifestError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
