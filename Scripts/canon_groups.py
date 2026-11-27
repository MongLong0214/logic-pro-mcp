#!/usr/bin/env python3
"""A record's citations, written once per reference and read as one citation per value.

A census record cites hundreds of strings, and every citation used to be an object of four fields of which
three (`ref`, `used_for`, `binding`) were the same text again. `canon_groups` states those three once and
lists the values:

    "canon_groups": [{"ref": "<scheme>://strings/en#value", "used_for": "...", "binding": {...},
                      "values": ["Cancel", "Mixer", ...]}]

`expand(record)` is the ONE reading: the flat `canon` list a record may still carry, followed by one
`{"ref", "value", "used_for", "binding"}` per grouped value, in order. Every consumer of a record's
citations (the citation guard, the pin builder) goes through it, so a grouped citation is held to exactly
what a flat one was: the same `check_citation(ref, value)`, the same binding, the same pin. Grouping
removes repetition; it does not remove a claim.
"""


def expand(record):
    """Every citation of `record`, flat: its `canon` list, then each `canon_groups` value one by one."""
    out = [c for c in (record.get("canon") or []) if isinstance(c, dict)]
    for group in record.get("canon_groups") or []:
        if not isinstance(group, dict):
            continue
        for value in group.get("values") or []:
            out.append({"ref": group.get("ref"), "value": value, "used_for": group.get("used_for"),
                        "binding": group.get("binding")})
    return out


def group(citations):
    """Flat citations as `canon_groups`: one group per (ref, used_for, binding), values in first-seen order."""
    groups = {}
    for c in citations:
        key = (c["ref"], c.get("used_for"), repr(c.get("binding")))
        groups.setdefault(key, {"ref": c["ref"], "used_for": c.get("used_for"), "binding": c.get("binding"),
                                "values": []})["values"].append(c["value"])
    return list(groups.values())
