#!/usr/bin/env python3
"""Partition and verify exact Swift Testing manifests for N coverage shards."""

import argparse
import json
from pathlib import Path
import re
import sys
from typing import NamedTuple, Optional
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


# Every test the hosted shards are expected to report as not run, by full test ID, in
# Tests/not-run-on-hosted.json. The classes say where each one DOES execute:
#   logic_host  the Logic host's native qualification (Scripts/host-tests.sh), which must pass it
#   live        a live loop of Scripts/release-qualify.sh, named by the entry's `lane`
#   operator    nowhere automatic; it needs an operator-supplied project. This class exempts a test
#               from running, so the qualifier accepts an operator entry only when its own trusted
#               copy of this file has it too (verify_trusted_operator)
# The rule is enforced from what the test run reported, never from how a condition is spelled in
# the sources: a closure `.enabled { }`, a suite-level trait or a condition behind a constant all
# surface as a skipped testcase in the xUnit output.
NOT_RUN_CLASSES = ("logic_host", "live", "operator")
# The two live loops differ in the executable they stage: `release` runs against the release
# candidate, `debug` against the debug build (the fault-negative test). Every live entry names one.
LIVE_LANES = ("release", "debug")

# The one operator entry that exists before the first copy of this file reaches protected main.
# While the trusted checkout has no copy (the file's first appearance on main), exactly this ID is
# accepted as an operator entry, by ID and nothing else. Once the file is on main the trusted copy
# decides, and this set is never consulted.
BOOTSTRAP_OPERATOR_IDS = frozenset({
    "LogicProMCPTests.Issue965HeldSelectionAssociationTests/nativeMixerScrollToRetainsItsObservedOwners()",
})


class NotRunEntry(NamedTuple):
    kind: str
    reason: str
    lane: Optional[str]


def read_not_run(path: Path) -> dict[str, NotRunEntry]:
    """The not-run list as {full test ID: NotRunEntry}."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ManifestError(f"cannot read not-run list {path}: {error}") from error
    if not isinstance(document, dict) or set(document) != {"tests"} \
            or not isinstance(document["tests"], list):
        raise ManifestError(f'not-run list must be {{"tests": [...]}}: {path}')
    entries: dict[str, NotRunEntry] = {}
    for row in document["tests"]:
        if not isinstance(row, dict) or not {"id", "class", "reason"} <= set(row) \
                or not set(row) <= {"id", "class", "reason", "lane"} \
                or not all(isinstance(value, str) for value in row.values()):
            raise ManifestError(
                f"not-run entry needs string id, class and reason (and lane for live): {row!r}")
        test_id, kind, reason = row["id"], row["class"], row["reason"]
        if not test_id or test_id != test_id.strip() or "\n" in test_id:
            raise ManifestError(f"not-run entry has a blank or padded id: {test_id!r}")
        if kind not in NOT_RUN_CLASSES:
            raise ManifestError(f"not-run entry {test_id!r} has class {kind!r}; expected {NOT_RUN_CLASSES}")
        if not reason.strip() or "\n" in reason:
            raise ManifestError(f"not-run entry {test_id!r} needs a one-line reason")
        lane = row.get("lane")
        if kind == "live":
            if lane not in LIVE_LANES:
                raise ManifestError(
                    f"live entry {test_id!r} has no owning lane; lane must be one of {LIVE_LANES}")
        elif lane is not None:
            raise ManifestError(f"only live entries take a lane: {test_id!r} is {kind}")
        if test_id in entries:
            raise ManifestError(f"not-run list names {test_id!r} twice")
        entries[test_id] = NotRunEntry(kind, reason, lane)
    return entries


def _xunit_cases(xunit_directory: Path) -> list[tuple[str, str, bool, bool]]:
    """(classname, name, failed, skipped) of every testcase in the one xUnit file of a run."""
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
    cases = []
    for testcase in root.iter("testcase"):
        classname = testcase.get("classname")
        name = testcase.get("name")
        if not classname or not name:
            raise ManifestError("xUnit testcase lacks classname or name")
        failed = testcase.find("failure") is not None or testcase.find("error") is not None
        cases.append((classname, name, failed, testcase.find("skipped") is not None))
    return cases


def verify_xunit(expected_path: Path, xunit_directory: Path, actual_path: Path,
                 not_run_path: Path) -> None:
    expected = set(_read(expected_path, label="expected shard manifest", require_sorted=True))
    not_run = read_not_run(not_run_path)
    expected_xunit_index = _expected_xunit_index(expected)
    cases = _xunit_cases(xunit_directory)

    raw_cases: set[tuple[str, str]] = set()
    actual: set[str] = set()
    skipped: set[str] = set()
    for classname, name, failed, was_skipped in cases:
        if failed:
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
        if was_skipped:
            skipped.add(resolved)
    if not raw_cases:
        raise ManifestError("xUnit contains no testcases")
    if actual != expected:
        missing = sorted(expected - actual)[:3]
        extra = sorted(actual - expected)[:3]
        raise ManifestError(f"xUnit differs from expected manifest; missing={missing} extra={extra}")
    # A skip is a test that executed nowhere on this lane, so each one must be accounted for ...
    unlisted = sorted(skipped - set(not_run))
    if unlisted:
        raise ManifestError(
            f"xUnit testcase was skipped but is not in the not-run list; run it here or list it "
            f"with the lane that runs it: {unlisted[:3]}")
    # ... and a listed test that did run here is a stale entry that would let the list rot. This
    # holds for every class: an `operator` or `live` entry on a test that is not skipped is a
    # claim that it runs nowhere hosted when it does, or a label that exempts a test that was
    # never gated.
    stale = sorted(test_id for test_id, entry in not_run.items()
                   if test_id in expected and test_id not in skipped)
    if stale:
        raise ManifestError(
            f"not-run list entry was not skipped on the hosted run, so the entry is stale: {stale[:3]}")
    _write_new(actual_path, sorted(actual))


def listed_ids(not_run_path: Path, kind: str = "logic_host", lane: Optional[str] = None,
               only: Optional[str] = None) -> list[str]:
    """The IDs of one class (and live lane) from the list, or just `only` when it is one of them."""
    ids = sorted(test_id for test_id, entry in read_not_run(not_run_path).items()
                 if entry.kind == kind and (lane is None or entry.lane == lane))
    if only is not None:
        if only not in ids:
            raise ManifestError(f"{only!r} is not a {kind} test of the not-run list: {not_run_path}")
        ids = [only]
    return ids


def _required_ids(not_run_path: Path, kind: str, lane: Optional[str], only: Optional[str]) -> list[str]:
    ids = listed_ids(not_run_path, kind, lane, only)
    if not ids:
        raise ManifestError(f"not-run list names no {kind} test: {not_run_path}")
    return ids


def host_test_ids(not_run_path: Path) -> list[str]:
    return _required_ids(not_run_path, "logic_host", None, None)


def host_filter(not_run_path: Path, kind: str = "logic_host", lane: Optional[str] = None,
                only: Optional[str] = None) -> str:
    """The anchored, escaped `swift test --filter` regular expression for exactly those tests."""
    pattern = shard_filter(_required_ids(not_run_path, kind, lane, only))
    try:
        re.compile(pattern)
    except re.error as error:
        raise ManifestError(f"host filter is not a regular expression: {error}") from error
    return pattern


def verify_host(not_run_path: Path, xunit_directory: Path, kind: str = "logic_host",
                lane: Optional[str] = None, only: Optional[str] = None) -> None:
    """Every selected test is in the run's xUnit output, executed, and passed.

    The same judgement serves the Logic host's `logic_host` run and each `live` run (one test and
    one process at a time). A skip is a failure here: this is the one place the body of such a
    test runs, so a test that did not execute is absence reported as success. A testcase that is
    not selected also fails, which is how a filter that matched a similarly named test would show.
    """
    wanted = set(_required_ids(not_run_path, kind, lane, only))
    label = "host" if kind == "logic_host" else kind
    index = _expected_xunit_index(wanted)
    problems: list[str] = []
    seen: set[str] = set()
    for classname, name, failed, was_skipped in _xunit_cases(xunit_directory):
        resolved = index.get((classname, name))
        if resolved is None:
            problems.append(f"ran a test that is not a {label} test: {classname}/{name}")
        elif resolved in seen:
            problems.append(f"ran twice: {resolved}")
        else:
            seen.add(resolved)
            if failed:
                problems.append(f"failed: {resolved}")
            elif was_skipped:
                problems.append(f"skipped on the Logic host, which counts as a failure: {resolved}")
    for test_id in sorted(wanted - seen):
        problems.append(f"missing from the results: {test_id}")
    if problems:
        raise ManifestError(f"{label} tests did not all execute and pass: " + "; ".join(problems))


def verify_trusted_operator(not_run_path: Path, trusted_path: Path) -> None:
    """Every operator entry of the candidate's list is also an operator entry of the trusted copy.

    `operator` exempts a test from running anywhere, so it is not the candidate's to grant: a new
    exemption lands on protected main through a maintainer change first, like a change to this
    script. With no trusted copy (the file's first appearance on main) the rule fails closed
    except for BOOTSTRAP_OPERATOR_IDS.
    """
    candidate = {test_id for test_id, entry in read_not_run(not_run_path).items()
                 if entry.kind == "operator"}
    try:
        trusted_exists = trusted_path.exists()
    except OSError as error:
        raise ManifestError(f"cannot inspect the trusted not-run list {trusted_path}: {error}") from error
    if trusted_exists:
        allowed = {test_id for test_id, entry in read_not_run(trusted_path).items()
                   if entry.kind == "operator"}
    else:
        allowed = set(BOOTSTRAP_OPERATOR_IDS)
    unauthorized = sorted(candidate - allowed)
    if unauthorized:
        raise ManifestError(
            "operator entries the trusted not-run list does not have; an exemption from running "
            f"has to reach protected main first: {unauthorized[:3]}")


def verify_not_run_in_inventory(inventory_path: Path, not_run_path: Path) -> None:
    """Every not-run entry names a test that exists, so a misspelt ID cannot hide a test."""
    inventory = set(_read(inventory_path, label="test inventory"))
    unknown = sorted(set(read_not_run(not_run_path)) - inventory)
    if unknown:
        raise ManifestError(f"not-run list names tests absent from the inventory: {unknown[:3]}")


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
    xunit.add_argument("--not-run", type=Path, required=True)

    union = subparsers.add_parser("verify-union")
    union.add_argument("--inventory", type=Path, required=True)
    union.add_argument("--shard", type=Path, action="append", required=True)
    union.add_argument("--not-run", type=Path, required=True)

    def select(command: argparse.ArgumentParser) -> None:
        command.add_argument("--not-run", type=Path, required=True)
        command.add_argument("--class", dest="kind", choices=("logic_host", "live"),
                             default="logic_host")
        command.add_argument("--lane", choices=LIVE_LANES)
        command.add_argument("--id", dest="only")

    host_filter_command = subparsers.add_parser("host-filter")
    select(host_filter_command)

    host = subparsers.add_parser("verify-host")
    select(host)
    host.add_argument("--xunit-directory", type=Path, required=True)

    list_ids = subparsers.add_parser("list-ids")
    select(list_ids)

    inventory = subparsers.add_parser("verify-inventory")
    inventory.add_argument("--inventory", type=Path, required=True)
    inventory.add_argument("--not-run", type=Path, required=True)

    trusted = subparsers.add_parser("verify-trusted")
    trusted.add_argument("--not-run", type=Path, required=True)
    trusted.add_argument("--trusted", type=Path, required=True)
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.command == "partition":
            partition_manifest(args.inventory, args.shards, args.output_directory)
        elif args.command == "verify-xunit":
            verify_xunit(args.expected, args.xunit_directory, args.actual, args.not_run)
        elif args.command == "host-filter":
            print(host_filter(args.not_run, args.kind, args.lane, args.only))
        elif args.command == "verify-host":
            verify_host(args.not_run, args.xunit_directory, args.kind, args.lane, args.only)
        elif args.command == "list-ids":
            ids = listed_ids(args.not_run, args.kind, args.lane, args.only)
            if args.lane is None and not ids:
                raise ManifestError(f"not-run list names no {args.kind} test: {args.not_run}")
            for test_id in ids:
                print(test_id)
        elif args.command == "verify-inventory":
            verify_not_run_in_inventory(args.inventory, args.not_run)
        elif args.command == "verify-trusted":
            verify_trusted_operator(args.not_run, args.trusted)
        else:
            verify_union(args.inventory, args.shard)
            verify_not_run_in_inventory(args.inventory, args.not_run)
    except ManifestError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
