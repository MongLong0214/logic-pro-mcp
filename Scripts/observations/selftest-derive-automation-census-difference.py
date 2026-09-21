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


def run_case(name, censuses, record, actuation, expected, edits=None):
    if edits is not None:
        print(f"EDIT {name}: edits={edits}")
        assert edits > 0, f"{name}: mutation made zero edits"
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


def reconciled_state_groups(record, actuation):
    audit = MODULE.Audit(io.StringIO())
    pairs = MODULE.reconcile_undo_stack_boundaries(record, actuation, audit)
    assert not audit.failures, f"fixture undo-stack reconciliation failed: {audit.failures}"
    return MODULE.state_groups(pairs)


def main():
    censuses, record, actuation = MODULE.load_snapshot()
    run_case("unmutated", censuses, record, actuation, 0)

    m1 = copy.deepcopy(censuses)
    m1_edits = 0
    for doc in m1.values():
        original = doc["rows"]
        doc["rows"] = [row for row in original if row["i"] != 1]
        m1_edits += len(original) - len(doc["rows"])
    run_case("M1 delete row index 1 from every census", m1, record, actuation, 1, m1_edits)

    m2 = copy.deepcopy(censuses)
    m2_edits = 0
    description = automation_value_description(record)
    for doc in m2.values():
        rows = [row for row in doc["rows"] if row.get("AXDescription") == description]
        assert len(rows) == 2, "fixture must have the two published automation-value rows"
        for row in rows:
            if row["AXValue"] != 0:
                row["AXValue"] = 0
                m2_edits += 1
    run_case("M2 zero both automation-value readings in every census", m2, record, actuation, 1, m2_edits)

    m3 = copy.deepcopy(censuses)
    m3_edits = 0
    applied, _, _ = reconciled_state_groups(record, actuation)
    index = target_index(record)
    for role in applied:
        row = next(row for row in m3[role]["rows"] if row["i"] == index)
        row["d"] += 1
        m3_edits += 1
    run_case("M3 increment d on the differing row in applied-state censuses", m3, record, actuation, 1, m3_edits)

    m7 = copy.deepcopy(actuation)
    m7_edits = 0
    forged_label = "forged undo-stack label"
    for reading in m7["undo_stack_boundaries"]["readings"]:
        if reading["item_1"] != forged_label:
            reading["item_1"] = forged_label
            m7_edits += 1
    run_case("M7 forge item_1 on all boundary readings", censuses, record, m7, 1, m7_edits)

    m8 = copy.deepcopy(actuation)
    m8_edits = 0
    reading = m8["undo_stack_boundaries"]["readings"][0]
    if reading["item_1"] != forged_label:
        reading["item_1"] = forged_label
        m8_edits += 1
    run_case("M8 forge item_1 on one boundary reading", censuses, record, m8, 1, m8_edits)

    m9 = copy.deepcopy(actuation)
    m9_edits = 0
    readings = m9["undo_stack_boundaries"]["readings"]
    if readings:
        readings.pop()
        m9_edits += 1
    run_case("M9 drop one boundary reading", censuses, record, m9, 1, m9_edits)

    m10 = copy.deepcopy(actuation)
    m10_edits = 0
    readings = m10["undo_stack_boundaries"]["readings"]
    if readings:
        readings.append(copy.deepcopy(readings[0]))
        m10_edits += 1
    run_case("M10 duplicate one boundary reading", censuses, record, m10, 1, m10_edits)

    # M7 and M8 do not witness the reconciliation predicate they appear to test. Measured: with
    # `reading["item_1"] == published["undo_item_1"]` replaced by a constant `True`, both still
    # exit 1 -- they forge item_1 into a shape that collapses the undo-stack grouping, and the
    # grouping is what rejects them. M11 and M12 below forge a label that leaves every group's
    # membership count unchanged, so only the state-by-state comparison can see the disagreement.
    m11 = copy.deepcopy(actuation)
    m11_edits = 0
    readings_by_role = {r["state"]: r for r in m11["undo_stack_boundaries"]["readings"]}
    applied_label = readings_by_role["after_create"]["item_1"]
    forged_applied = applied_label + " (forged)"
    for reading in m11["undo_stack_boundaries"]["readings"]:
        if reading["item_1"] == applied_label:
            reading["item_1"] = forged_applied
            m11_edits += 1
    assert m11_edits > 1, "fixture must carry more than one applied-state boundary reading"
    run_case("M11 relabel every applied-state item_1 identically, preserving the grouping exactly",
             censuses, record, m11, 1, m11_edits)

    m12 = copy.deepcopy(actuation)
    m12_edits = 0
    readings_by_role = {r["state"]: r for r in m12["undo_stack_boundaries"]["readings"]}
    donor = readings_by_role["after_undo"]["item_2"]
    assert readings_by_role["after_create"]["item_2"] != donor, "fixture item_2 values must differ"
    readings_by_role["after_create"]["item_2"] = donor
    m12_edits += 1
    run_case("M12 forge one boundary item_2 without touching item_1",
             censuses, record, m12, 1, m12_edits)

    print("OK: unmutated data passes and all nine in-memory mutants are rejected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
