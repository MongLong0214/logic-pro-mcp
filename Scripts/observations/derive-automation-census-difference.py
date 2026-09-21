#!/usr/bin/env python3
"""Recompute the automation-data observation from its committed evidence.

The observation record is the source of the published readings. This script loads that record, the
five state-tagged censuses it names, and its actuation evidence. Comparisons use the union of keys
the rows actually carry, so ``path``, ``d``, a new key, or a missing key cannot be ignored.
"""

import collections
import itertools
import json
import os
import re
import subprocess
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
OBSERVATIONS = os.path.join(REPO, "docs", "observations")
RECORD_PATH = os.path.join(
    OBSERVATIONS, "2026-09-21-the-parameter-popup-help-reports-automation-data.json"
)
CENSUS_NAME = re.compile(r".*-automation-census-(.+)\.json$")
ACTUATION_NAME = re.compile(r".*-automation-element-actuation\.json$")
MISSING = object()


def nfc(value):
    return unicodedata.normalize("NFC", value) if isinstance(value, str) else value


def stable(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


class Audit:
    def __init__(self, out):
        self.failures = []
        self.out = out

    def check(self, condition, message):
        if not condition:
            self.failures.append(message)
        return condition

    def line(self, message=""):
        print(message, file=self.out)


def observation(record, what):
    """Fetch one structured reading by its stable ``what`` identifier."""
    matches = [item for item in record.get("observations", []) if item.get("what") == what]
    if len(matches) != 1:
        raise ValueError(f"record has {len(matches)} observations named {what!r}; expected one")
    return matches[0]


def published_states(record):
    return observation(
        record, "the five state-tagged censuses, each labelled by Logic's own undo stack"
    )["states"]


def state_groups(record):
    """Derive state groups from the record's own undo-stack readings."""
    states = published_states(record)
    if len({item["state"] for item in states}) != len(states):
        raise ValueError("record repeats a census state role")
    create = [item for item in states if item["state"].endswith("_create")]
    if len(create) != 1:
        raise ValueError("record must identify exactly one *_create census state")
    applied_item = create[0]["undo_item_1"]
    applied = [item["state"] for item in states if item["undo_item_1"] == applied_item]
    undone = [item["state"] for item in states if item["undo_item_1"] != applied_item]
    by_undo_item = collections.defaultdict(list)
    for item in states:
        by_undo_item[item["undo_item_1"]].append(item["state"])
    # A spanning comparison is sufficient: equality of every state with the first state in its
    # undo-stack group establishes equality throughout that group without duplicating a pair.
    same_state_pairs = [(group[0], other) for group in by_undo_item.values() for other in group[1:]]
    return applied, undone, same_state_pairs


def row_index(doc, role, audit):
    """Validate raw census cardinality and its complete, unique index domain."""
    rows = doc.get("rows")
    if not audit.check(isinstance(rows, list), f"{role}: rows is not a list"):
        return {}
    total = doc.get("total")
    total_ok = isinstance(total, int) and not isinstance(total, bool) and total >= 0
    if not audit.check(total_ok, f"{role}: total is not a non-negative integer: {total!r}"):
        return {}
    audit.check(len(rows) == total,
                f"{role}: len(rows) is {len(rows)}, but census total is {total}")
    indices = [row.get("i", MISSING) if isinstance(row, dict) else MISSING for row in rows]
    valid_indices = all(isinstance(index, int) and not isinstance(index, bool) for index in indices)
    if not audit.check(valid_indices, f"{role}: every row must carry an integer i index"):
        return {}
    audit.check(len(indices) == len(set(indices)), f"{role}: row indices are not unique")
    expected = set(range(1, total + 1))
    actual = set(indices)
    audit.check(actual == expected,
                f"{role}: row indices are {sorted(actual)[:3]}...{sorted(actual)[-3:]}, "
                f"not the expected 1..{total}")
    return {row["i"]: row for row in rows}


def comparison_fields(left_rows, right_rows):
    """Every observed key except ``i``, which is the row identity used for the join."""
    fields = set()
    for row in itertools.chain(left_rows.values(), right_rows.values()):
        if isinstance(row, dict):
            fields.update(row)
    fields.discard("i")
    return sorted(fields)


def published_field_names(raw_fields):
    """Translate only the census format's compact depth key to the record's prose field name.

    The raw field set is still derived above; this is a presentation-name bridge for the record,
    which publishes ``depth`` while each census encodes that property as ``d``.
    """
    return {"depth" if field == "d" else field for field in raw_fields}


def field_differences(left_rows, right_rows, fields):
    """Missing is distinct from null: a key in only one counterpart is a difference."""
    differing = collections.defaultdict(list)
    for index in sorted(set(left_rows) & set(right_rows)):
        for field in fields:
            left = left_rows[index].get(field, MISSING)
            right = right_rows[index].get(field, MISSING)
            if left is MISSING or right is MISSING or stable(left) != stable(right):
                differing[field].append(index)
    return dict(differing)


def whole_rows(rows):
    """Whole raw rows, with only the index identity excluded."""
    return collections.Counter(
        stable({field: value for field, value in row.items() if field != "i"})
        for row in rows.values()
    )


def find_row(index, role, rows, audit):
    row = rows.get(index)
    audit.check(row is not None, f"{role}: no row at published census index {index}")
    return row or {}


def record_canon(record, used_for):
    matches = [item for item in record.get("canon", []) if item.get("used_for") == used_for]
    if len(matches) != 1:
        raise ValueError(f"record has {len(matches)} canon entries used for {used_for!r}; expected one")
    return matches[0]


def resolve(ref):
    """Resolve a record-supplied canon reference against the pinned corpus."""
    out = subprocess.run(
        [sys.executable, os.path.join(REPO, "Scripts", "logic_canon.py"), "resolve", ref],
        capture_output=True, text=True,
    )
    return out.stdout.splitlines()[0] if out.returncode == 0 and out.stdout.strip() else ""


def reconcile_actuation(record, actuation, audit):
    """Assert every structured actuation figure published from the actuation evidence."""
    published = observation(record, "settability and actuation on the three automation elements of the affected track")
    expected_elements = published["elements"]
    actual_elements = actuation.get("elements", [])
    actual_by_identity = {(item.get("description"), item.get("role")): item for item in actual_elements}
    expected_identities = {(item["description"], item["role"]) for item in expected_elements}
    audit.check(len(actual_elements) == len(actual_by_identity),
                "actuation evidence repeats an element description/role identity")
    audit.check(set(actual_by_identity) == expected_identities,
                "actuation evidence elements do not match the record's published elements")
    for expected in expected_elements:
        identity = (expected["description"], expected["role"])
        actual = actual_by_identity.get(identity)
        if actual is None:
            continue
        audit.check(actual.get("AXValue_attribute_present") == expected["AXValue_attribute_present"],
                    f"{identity[0]!r}: AXValue attribute-presence disagrees with record")
        audit.check(actual.get("AXValue_reads") == expected["AXValue_reads"],
                    f"{identity[0]!r}: AXValue reading disagrees with record")
        settable = actual.get("AXUIElementIsAttributeSettable_AXValue") or {}
        audit.check(settable.get("settable") == expected["AXValue_settable"],
                    f"{identity[0]!r}: AXValue settable reading disagrees with record")
        audit.check(settable.get("status") == expected["settable_status"],
                    f"{identity[0]!r}: AXValue settable status disagrees with record")
        actual_actions = {item.get("action"): item for item in actual.get("actuations", [])}
        expected_actions = {item["action"]: item for item in expected["actuations"]}
        audit.check(len(actual_actions) == len(actual.get("actuations", [])),
                    f"{identity[0]!r}: actuation evidence repeats an action")
        audit.check(set(actual_actions) == set(expected_actions),
                    f"{identity[0]!r}: published actions do not match actuation evidence")
        for action, published_action in expected_actions.items():
            measured = actual_actions.get(action)
            if measured is None:
                continue
            audit.check(measured.get("status") == published_action["status"],
                        f"{identity[0]!r} {action}: status disagrees with record")
            audit.check(measured.get("delta") == published_action["axmenu_delta"],
                        f"{identity[0]!r} {action}: AXMenu delta disagrees with record")
    return expected_elements


def reconcile_submenu(record, actuation, audit):
    """Reproduce the record's menu counts from the same committed actuation evidence."""
    published = observation(record, "the submenu structure and the leaf driven")
    measured = actuation.get("submenu_structure") or {}
    parent = measured.get("parent") or {}
    audit.check(parent.get("name") == published["parent"], "submenu parent name disagrees with record")
    audit.check(parent.get("enabled") == published["parent_enabled"],
                "submenu parent enabled reading disagrees with record")
    audit.check(parent.get("attribute_names_contains_AXIdentifier") ==
                published["parent_attribute_names_contains_AXIdentifier"],
                "submenu parent AXIdentifier-presence reading disagrees with record")
    items = measured.get("items", [])
    commands = [item for item in items if item.get("name") is not None]
    separators = [item for item in items if item.get("name") is None]
    with_identifier = [item for item in commands if item.get("AXIdentifier") == "globalMenuItemCall:"]
    audit.check(len(items) == published["menu_item_count"],
                f"submenu item count is {len(items)}, record says {published['menu_item_count']}")
    audit.check(len(commands) == published["command_items"],
                f"submenu command count is {len(commands)}, record says {published['command_items']}")
    audit.check(len(separators) == published["separators"],
                f"submenu separator count is {len(separators)}, record says {published['separators']}")
    audit.check(len(with_identifier) == published["command_items_carrying_globalMenuItemCall"],
                "submenu globalMenuItemCall count disagrees with record")
    audit.check(any(item.get("name") == published["leaf_driven"] for item in commands),
                "the record's driven submenu leaf is not in the actuation evidence")


def reconcile_region_control(record, censuses, state_role, audit, resolve_canon):
    """Reproduce the record's canon-backed region-control counts from the create census."""
    published = observation(
        record, "the region precondition control, evaluated offline against the committed after-create census"
    )
    region_entry = record_canon(record, "the naive region predicate whose over-matching is the committed control")
    midi_entry = record_canon(record, "the region predicate that separates a MIDI region from a MIDI note")
    region, midi_region = resolve_canon(region_entry["ref"]), resolve_canon(midi_entry["ref"])
    audit.check(bool(region), "cannot resolve the canon Region value")
    audit.check(bool(midi_region), "cannot resolve the canon MIDI-region composed value")
    audit.check(nfc(region) == nfc(region_entry["value"]), "resolved Region canon value disagrees with record")
    audit.check(nfc(midi_region) == nfc(midi_entry["value"]),
                "resolved MIDI-region canon value disagrees with record")
    rows = censuses[state_role]
    layout_items = [row for row in rows.values() if row.get("AXRole") == "AXLayoutItem"]
    naive = [row for row in layout_items if nfc(region) in nfc(row.get("AXHelp") or "")]
    canon = [row for row in layout_items if nfc(midi_region) in nfc(row.get("AXHelp") or "")]
    audit.check(len(layout_items) == published["axlayoutitem_rows"],
                f"AXLayoutItem count is {len(layout_items)}, record says {published['axlayoutitem_rows']}")
    audit.check(len(naive) == published["naive_matches"],
                f"naive predicate matched {len(naive)}, record says {published['naive_matches']}")
    audit.check([row.get("AXDescription") for row in naive] == published["naive_match_descriptions"],
                "naive predicate descriptions disagree with record")
    audit.check(len(canon) == published["canon_matches"],
                f"canon predicate matched {len(canon)}, record says {published['canon_matches']}")
    audit.check([row.get("AXDescription") for row in canon] == published["canon_match_descriptions"],
                "canon predicate descriptions disagree with record")
    return len(layout_items), len(naive), len(canon)


def derive(censuses, record, actuation, out=sys.stdout, resolve_canon=resolve):
    """Return zero only when in-memory evidence reproduces the record."""
    audit = Audit(out)
    census_reading = observation(record, "the five state-tagged censuses, each labelled by Logic's own undo stack")
    comparison = observation(record, "the paired census comparison, over every captured attribute")
    distinguishing = observation(record, "the one element that distinguishes the states")
    control = observation(record, "the within-run control: the same control on the other track")
    values = observation(record, "the 오토메이션 값 rows across the paired states")
    published_by_role = {item["state"]: item for item in census_reading["states"]}
    roles = list(published_by_role)
    audit.check(len(roles) == len(census_reading["states"]), "record repeats a published census state")
    audit.check(set(censuses) == set(roles),
                f"loaded census roles are {sorted(censuses)}, record names {sorted(roles)}")

    indexed = {}
    for role in roles:
        doc = censuses.get(role, {})
        audit.check(doc.get("state") == role,
                    f"{role}: census state tag is {doc.get('state')!r}, expected {role!r}")
        indexed[role] = row_index(doc, role, audit)
        audit.check(doc.get("total") == published_by_role[role]["total_elements"],
                    f"{role}: census total is {doc.get('total')}, "
                    f"record says {published_by_role[role]['total_elements']}")
        depths = [row.get("d", MISSING) for row in indexed[role].values()]
        depth_values_are_integers = all(isinstance(depth, int) and not isinstance(depth, bool)
                                        for depth in depths)
        audit.check(depth_values_are_integers, f"{role}: every indexed row must carry integer depth d")
        if depth_values_are_integers:
            audit.check(all(depth <= census_reading["depth_limit"] for depth in depths),
                        f"{role}: a raw depth exceeds the record's depth limit "
                        f"{census_reading['depth_limit']}")

    titles = {nfc(censuses[role].get("window_title")) for role in roles if role in censuses}
    audit.check(len(titles) == 1, f"census window titles are not constant: {sorted(titles)!r}")
    audit.check(titles == {nfc(actuation.get("window"))},
                "census window title does not match the actuation evidence window")
    title = next(iter(titles), None)
    published_totals = {published_by_role[role]["total_elements"] for role in roles}
    audit.check(len(published_totals) == 1,
                f"record publishes inconsistent census totals: {sorted(published_totals)}")
    audit.line(f"censuses: {len(roles)} states, {next(iter(published_totals), None)} rows each, "
               f"window {title!r}")

    applied, undone, same_state_pairs = state_groups(record)
    audit.check(len(applied) * len(undone) == comparison["pairs_compared_present_vs_absent"],
                "record's present-versus-undone pair count disagrees with its state readings")
    audit.check(len(same_state_pairs) == comparison["same_state_pairs_compared"],
                "record's same-state pair count disagrees with its state readings")
    expected_fields = set(comparison["compared_fields"]) | set(comparison["also_compared"])
    compared_pairs = []
    audit.line("whole-row multiset differences (every captured field):")
    for left_role in applied:
        for right_role in undone:
            left, right = indexed[left_role], indexed[right_role]
            fields = comparison_fields(left, right)
            audit.check(published_field_names(fields) == expected_fields,
                        f"{left_role} vs {right_role}: row-key union is {fields}, "
                        "not the record's published comparison fields")
            attribute_fields = [field for field in fields
                                if published_field_names([field]).isdisjoint(comparison["also_compared"])]
            audit.check(len(attribute_fields) == census_reading["attributes_per_row"],
                        f"{left_role} vs {right_role}: raw row-key union has {len(attribute_fields)} "
                        f"captured attributes, record says {census_reading['attributes_per_row']}")
            audit.check(set(left) == set(right), f"{left_role} vs {right_role}: census index sets differ")
            left_counter, right_counter = whole_rows(left), whole_rows(right)
            only_left, only_right = sum((left_counter - right_counter).values()), sum((right_counter - left_counter).values())
            audit.line(f"  {left_role:18s} vs {right_role:18s}: {only_left} / {only_right}")
            audit.check(only_left == comparison["whole_row_multiset_difference_present_vs_absent"] and
                        only_right == comparison["whole_row_multiset_difference_absent_vs_present"],
                        f"{left_role} vs {right_role}: whole-row differences are {only_left}/{only_right}, "
                        "not the record's published values")
            differing = field_differences(left, right, fields)
            path_count = len(differing.get("path", []))
            audit.check(path_count == comparison["rows_whose_path_disagrees_at_the_same_index"],
                        f"{left_role} vs {right_role}: {path_count} path differences, not the record's value")
            fields_that_differ = list(differing)
            rows_that_differ = sorted({index for indices in differing.values() for index in indices})
            audit.check(fields_that_differ == comparison["fields_that_differ"],
                        f"{left_role} vs {right_role}: differing fields are {fields_that_differ}, "
                        f"not {comparison['fields_that_differ']}")
            audit.check(rows_that_differ == comparison["rows_that_differ"],
                        f"{left_role} vs {right_role}: differing rows are {rows_that_differ}, "
                        f"not {comparison['rows_that_differ']}")
            compared_pairs.append(differing)

    for left_role, right_role in same_state_pairs:
        left_counter, right_counter = whole_rows(indexed[left_role]), whole_rows(indexed[right_role])
        only_left, only_right = sum((left_counter - right_counter).values()), sum((right_counter - left_counter).values())
        audit.line(f"  {left_role:18s} vs {right_role:18s}: {only_left} / {only_right}   (same-state pair)")
        audit.check(only_left == comparison["whole_row_multiset_difference_between_two_censuses_of_the_same_state"] and
                    only_right == comparison["whole_row_multiset_difference_between_two_censuses_of_the_same_state"],
                    f"{left_role} vs {right_role}: same-state whole-row differences are {only_left}/{only_right}, "
                    "not the record's published value")
    audit.line()

    published_difference_fields = set(comparison["fields_that_differ"])
    other_fields = sorted({field for differing in compared_pairs for field in differing
                           if field not in published_difference_fields})
    audit.check(other_fields == distinguishing["other_fields_of_this_row_that_moved"],
                f"other fields moving with the distinguishing row are {other_fields}, not the record's value")
    target_index, target_role = distinguishing["census_index"], applied[0]
    target_row = find_row(target_index, target_role, indexed[target_role], audit)
    audit.line(f"differing element: i={target_index} role={target_row.get('AXRole')} description={target_row.get('AXDescription')!r}")
    audit.line(f"  path: {target_row.get('path')}")
    audit.check(target_row.get("AXRole") == distinguishing["role"], "distinguishing element role disagrees with record")
    audit.check(target_row.get("AXRoleDescription") == distinguishing["role_description"],
                "distinguishing element role description disagrees with record")
    audit.check(nfc(target_row.get("AXDescription")) == nfc(distinguishing["description"]),
                "distinguishing element description disagrees with record")
    audit.check(target_row.get("path") == distinguishing["path"], "distinguishing element path disagrees with record")
    for role in applied:
        row = find_row(target_index, role, indexed[role], audit)
        audit.check(nfc(row.get("AXHelp")) == nfc(distinguishing["help_when_the_operation_is_on_the_undo_stack"]),
                    f"{role}: distinguishing help disagrees with record's applied-state reading")
    for role in undone:
        row = find_row(target_index, role, indexed[role], audit)
        audit.check(nfc(row.get("AXHelp")) == nfc(distinguishing["help_when_it_has_been_undone"]),
                    f"{role}: distinguishing help disagrees with record's undone-state reading")
    ordered_help = [find_row(target_index, role, indexed[role], audit).get("AXHelp") for role in roles]
    transitions = sum(left != right for left, right in zip(ordered_help, ordered_help[1:]))
    audit.check(transitions == distinguishing["transitions_observed"],
                f"distinguishing help moved {transitions} times, record says {distinguishing['transitions_observed']}")
    audit.check(transitions // 2 == distinguishing["cycles"],
                f"derived undo/redo cycles are {transitions // 2}, record says {distinguishing['cycles']}")
    audit.line()

    control_index = control["census_index"]
    control_row = find_row(control_index, target_role, indexed[target_role], audit)
    audit.line(f"control element: i={control_index} description={control_row.get('AXDescription')!r} path={control_row.get('path')}")
    audit.check(nfc(control_row.get("AXDescription")) == nfc(control["description"]),
                "control description disagrees with record")
    audit.check(control_row.get("path") == control["path"], "control path disagrees with record")
    control_helps = [find_row(control_index, role, indexed[role], audit).get("AXHelp") for role in roles]
    audit.check(len(set(control_helps)) == control["distinct_values_across_states"],
                "control distinct-help count disagrees with record")
    audit.check({nfc(help_text) for help_text in control_helps} == {nfc(control["help_in_all_five_states"])},
                "control help does not match the record in every state")
    audit.line()

    expected_elements = reconcile_actuation(record, actuation, audit)
    reconcile_submenu(record, actuation, audit)
    value_element = [element for element in expected_elements if element["AXValue_reads"] == values["value"]]
    audit.check(len(value_element) == 1,
                "record does not identify exactly one actuation element with the published value reading")
    value_description = value_element[0]["description"] if value_element else None
    audit.check(set(values["invariant_across"]) == set(roles),
                "record's automation-value invariant states do not name every loaded census")
    for role in values["invariant_across"]:
        if role not in indexed:
            audit.check(False, f"automation-value invariant names unloaded state {role!r}")
            continue
        rows = [row for row in indexed[role].values() if row.get("AXDescription") == value_description]
        audit.check(len(rows) == values["row_count"],
                    f"{role}: found {len(rows)} automation-value rows, record says {values['row_count']}")
        audit.check(all(row.get("AXRole") == values["role"] for row in rows),
                    f"{role}: an automation-value row has a role other than {values['role']}")
        audit.check(all(row.get("AXValue", MISSING) != MISSING and row.get("AXValue") == values["value"] for row in rows),
                    f"{role}: automation-value AXValue does not equal the published invariant")
    audit.line(f"automation-value rows: {values['row_count']} per state; AXValue invariant {values['value']!r}")
    audit.line()

    layout_count, naive_count, canon_count = reconcile_region_control(record, indexed, target_role, audit, resolve_canon)
    audit.line(f"region precondition control: {layout_count} AXLayoutItem rows; naive={naive_count}, canon={canon_count}")
    audit.line()
    if audit.failures:
        audit.line(f"FAIL: {len(audit.failures)} published number(s) not reproduced by the committed readings")
        for failure in audit.failures:
            audit.line(f"  - {failure}")
        return 1
    audit.line("OK: every published number is reproduced by the committed readings")
    return 0


def load_snapshot():
    """Load exactly the census and actuation evidence files declared by the observation record."""
    with open(RECORD_PATH, encoding="utf-8") as handle:
        record = json.load(handle)
    censuses, actuation = {}, None
    for relative in record.get("evidence", []):
        name, path = os.path.basename(relative), os.path.join(OBSERVATIONS, relative)
        census_match = CENSUS_NAME.fullmatch(name)
        if census_match:
            role = census_match.group(1).replace("-", "_")
            if role in censuses:
                raise ValueError(f"record names two census files for role {role!r}")
            with open(path, encoding="utf-8") as handle:
                censuses[role] = json.load(handle)
        elif ACTUATION_NAME.fullmatch(name):
            if actuation is not None:
                raise ValueError("record names more than one actuation evidence file")
            with open(path, encoding="utf-8") as handle:
                actuation = json.load(handle)
    if actuation is None:
        raise ValueError("record names no actuation evidence file")
    return censuses, record, actuation


def main():
    try:
        censuses, record, actuation = load_snapshot()
        return derive(censuses, record, actuation)
    except (OSError, ValueError, json.JSONDecodeError, KeyError, TypeError) as error:
        print(f"FAIL: cannot derive the observation from its declared evidence: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
