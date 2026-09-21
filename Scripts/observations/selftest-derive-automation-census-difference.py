#!/usr/bin/env python3
"""In-memory mutation proof for derive-automation-census-difference.py."""

import copy
import importlib.util
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, "derive-automation-census-difference.py")
SPEC = importlib.util.spec_from_file_location("derive_automation_census_difference", TARGET)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def in_memory_resolver(record):
    values = {entry["ref"]: entry["value"] for entry in record["canon"]}
    return values.__getitem__


def run_case(name, censuses, record, actuation, expected):
    code = MODULE.derive(censuses, record, actuation, out=io.StringIO(),
                         resolve_canon=in_memory_resolver(record))
    assert code == expected, f"{name}: derive returned {code}, expected {expected}"
    print(f"PASS {name}: exit={code}")


def target_index(record):
    return MODULE.observation(record, "the one element that distinguishes the states")["census_index"]


def automation_value_description(record):
    values = MODULE.observation(record, "the 오토메이션 값 rows across the paired states")
    elements = MODULE.observation(
        record, "settability and actuation on the three automation elements of the affected track"
    )["elements"]
    matches = [element["description"] for element in elements if element["AXValue_reads"] == values["value"]]
    assert len(matches) == 1, "record does not identify the automation-value element"
    return matches[0]


def main():
    censuses, record, actuation = MODULE.load_snapshot()
    run_case("unmutated", censuses, record, actuation, 0)

    m1 = copy.deepcopy(censuses)
    for doc in m1.values():
        doc["rows"] = [row for row in doc["rows"] if row["i"] != 1]
    run_case("M1 delete row index 1 from every census", m1, record, actuation, 1)

    m2 = copy.deepcopy(censuses)
    description = automation_value_description(record)
    for doc in m2.values():
        rows = [row for row in doc["rows"] if row.get("AXDescription") == description]
        assert len(rows) == 2, "fixture must have the two published automation-value rows"
        for row in rows:
            row["AXValue"] = 0
    run_case("M2 zero both automation-value readings in every census", m2, record, actuation, 1)

    m3 = copy.deepcopy(censuses)
    applied, _, _ = MODULE.state_groups(record)
    index = target_index(record)
    for role in applied:
        row = next(row for row in m3[role]["rows"] if row["i"] == index)
        row["d"] += 1
    run_case("M3 increment d on the differing row in applied-state censuses", m3, record, actuation, 1)

    print("OK: unmutated data passes and all three in-memory mutants are rejected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
