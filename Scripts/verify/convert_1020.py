#!/usr/bin/env python3
"""Convert ONE livekit evidence file of `live_1020_mcu_set_arm_is_a_set` into `lpm-evidence/1`.

The P0a pilot (#1028): it shows the engine judging real observations against
`docs/acceptance/1020.json`, and it states exactly what an old evidence file can and cannot carry.

    python3 Scripts/verify/convert_1020.py <livekit evidence.json> <locale> <out.json>

WHAT THE CONVERSION CAN PROVE
-----------------------------
Every value it stores was in the livekit file, and each observation names where: the record index,
its tag, the field, and the transform. The transforms are field extractions only -- a reply payload
stored whole; a boolean or list taken out of a check's `observed` dict; a track's `isArmed` taken
out of the census rows -- and the value written is the value read.

WHAT IT CANNOT
--------------
  * BINDING. The livekit file says `built_from_is_measured: false`: the binary's head was inferred
    from file times, not measured from a build. The converted binary is "unbound", which the engine never
    judges clean. The best a conversion can reach is exit 3.
  * RAW READS OF logic://tracks. The livekit framework kept six envelope keys of every
    resources/read reply, so the track list after each operation is not in the file. The `post`
    readings here are the harness's own reduction of that list (`armed_in_track_list_after`, the
    census `after_arm`), which is the track's `isArmed` as the harness read it -- a second read of
    the same surface, not a raw one.
  * ROWS THE HARNESS NEVER DROVE. `arm-armed-writes-nothing` has no observation: the harness did
    not arm an armed track (its own record's limits say the Accessibility rung answers that no-op
    first). Its steps are stored as unreadable, and the row is UNREADABLE, not PASS.
  * A WITNESS THE HARNESS NEVER TOOK. The last row's unchanged-upper-row claim is an effect, so
    its counterexample needs an upper row that differs from the one before the arm (`off_home_row`,
    read with the MCU window banked away from home). The harness only read the row at home, before
    and after the arm. `off_home`, `off_home_row` and `home` are stored as unreadable, and that row
    is UNREADABLE, not PASS: nothing in the file shows the claim could have failed.
  * TRUNCATED FIELDS. A check's `observed.observation` / `counterexample` was `repr(...)[:400]`. A
    string that no longer parses is stored as unreadable with that reason; none of the fields this
    mapping reads was cut in the 4b036d93 run, and the code path exists for the ones that would be.
  * THE HOST BLOCK, DATE AND LOCALE READING. None is in the file, so all are null: the run's locale
    is "unverified" (exit 3 at best), and `verify.py record` refuses to write a record from it.
  * NINE LOCALES. One file is one locale; the spec requires ten, so nine are "not run".
"""
from __future__ import annotations

import ast
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import engine  # noqa: E402
import evidence_doc as E  # noqa: E402

SPEC_PATH = "docs/acceptance/1020.json"
TRUNCATION = "cut by Scripts/livekit/evidence.py's repr(...)[:400] and no longer parses"
NOT_DRIVEN = ("live_1020_mcu_set_arm_is_a_set did not drive this row: it never armed an already-armed "
              "track, because the Accessibility rung answers that no-op before the MCU rung")
NO_WITNESS = ("live_1020_mcu_set_arm_is_a_set never banked the MCU window away from home, so it read no "
              "upper row that differs from the one before the arm; nothing it stored can witness the "
              "unchanged-row claim failing")


class Source:
    """The livekit file's records, looked up by kind and tag."""

    def __init__(self, doc: dict):
        self.records = doc["records"]

    def find(self, kind: str, tag: str):
        hits = [(i, r) for i, r in enumerate(self.records) if r.get("kind") == kind and r.get("tag") == tag]
        if len(hits) != 1:
            raise SystemExit(f"expected one {kind} record tagged {tag!r}, found {len(hits)}")
        return hits[0]

    def payload(self, tag: str):
        """A whole reply payload (an `observation` record): (value, provenance)."""
        i, r = self.find("observation", tag)
        return r["payload"], {"record": i, "tag": tag, "field": "payload", "transform": "stored whole"}

    def check_field(self, tag: str, key: str):
        """One key of a check's observed.observation, a Python repr: (value or None, provenance, why)."""
        i, r = self.find("check", tag)
        text = r["observed"]["observation"]
        prov = {"record": i, "tag": tag, "field": f"observed.observation[{key!r}]",
                "transform": "ast.literal_eval of the repr, then one key"}
        try:
            parsed = ast.literal_eval(text)
        except (ValueError, SyntaxError):
            return None, prov, TRUNCATION
        return parsed[key], prov, None

    def census_armed(self, track: int):
        i, r = self.find("observation", "1020/track-census")
        rows = [row for row in r["payload"]["rows"] if row.get("id") == track]
        prov = {"record": i, "tag": "1020/track-census", "field": f"payload.rows[id={track}].isArmed",
                "transform": "one row's isArmed"}
        return rows[0]["isArmed"], prov


def _observation(step: dict, value, provenance: dict, why=None) -> dict:
    if why:
        entry = E.unreadable_observation(step, why)
    else:
        entry = E.make_observation(step, json.dumps(value, ensure_ascii=False, sort_keys=True))
    entry["converted_from"] = provenance
    return entry


def mapping(src: Source) -> dict:
    """{row id: {bound name: (value, provenance, why)}} -- where each spec step's reading comes from."""
    arm0, p_arm0 = src.payload("1020/arm-track-0")
    disarm0, p_disarm0 = src.payload("1020/disarm-track-0")
    arm15, p_arm15 = src.payload("1020/arm-track-15")
    disarm15, p_disarm15 = src.payload("1020/disarm-track-15")
    arm16, p_arm16 = src.payload("1020/arm-track-16")
    found0, p_found0 = src.census_armed(0)
    after_on, p_on, w_on = src.check_field("1020/arm-through-the-mcu-sets-and-confirms", "armed_in_track_list_after")
    after_off, p_off, w_off = src.check_field("1020/disarm-through-the-mcu-clears-the-arm", "armed_in_track_list_after")
    census = "1020/bank-1-census-armed-set-is-15-then-as-found"
    as_found, p_as, w_as = src.check_field(census, "as_found")
    after_arm, p_aa, w_aa = src.check_field(census, "after_arm")
    after_dis, p_ad, w_ad = src.check_field(census, "after_disarm")
    final = "1020/final-bank-arm-is-refused-with-nothing-armed"
    set_before, p_sb, w_sb = src.check_field(final, "armed_set_before")
    set_after, p_sa, w_sa = src.check_field(final, "armed_set_after")
    home = "1020/final-bank-leaves-the-mcu-window-home"
    row_before, p_rb, w_rb = src.check_field(home, "before")
    row_after, p_ra, w_ra = src.check_field(home, "after")

    def track(value):
        return {"track": 0, "armed": value}

    return {
        "arm-unarmed-sets": {
            "pre": (track(found0), p_found0, None),
            "reply": (arm0, p_arm0, None),
            "post": (track(after_on), p_on, w_on),
            "undo": (disarm0, p_disarm0, None),
            "restored": (track(after_off), p_off, w_off),
        },
        "arm-armed-writes-nothing": {},
        "disarm-clears": {
            "as_found": (track(found0), p_found0, None),
            "setup": (arm0, p_arm0, None),
            "pre": (track(after_on), p_on, w_on),
            "reply": (disarm0, p_disarm0, None),
            "post": (track(after_off), p_off, w_off),
        },
        "bank-1-only-the-target-changes": {
            "pre": ({"armed": as_found}, p_as, w_as),
            "reply": (arm15, p_arm15, None),
            "post": ({"armed": after_arm}, p_aa, w_aa),
            "undo": (disarm15, p_disarm15, None),
            "restored": ({"armed": after_dis}, p_ad, w_ad),
        },
        "clamped-last-bank-refused-unchanged": {
            "control": (arm15, p_arm15, None),
            "control_post": ({"armed": after_arm}, p_aa, w_aa),
            "control_undo": (disarm15, p_disarm15, None),
            "pre": ({"armed": set_before}, p_sb, w_sb),
            "pre_row": ({"upper_row": row_before}, p_rb, w_rb),
            "reply": (arm16, p_arm16, None),
            "post": ({"armed": set_after}, p_sa, w_sa),
            "post_row": ({"upper_row": row_after}, p_ra, w_ra),
            "off_home": (None, {"record": None}, NO_WITNESS),
            "off_home_row": (None, {"record": None}, NO_WITNESS),
            "home": (None, {"record": None}, NO_WITNESS),
        },
    }


def convert(src_path: str, locale: str, spec: dict) -> dict:
    with open(src_path, "rb") as handle:
        raw = handle.read()
    old = E.loads(raw.decode("utf-8"))  # the recorded run, read refusing a key given twice
    art = old["artifact"]
    binary = {
        E.BINARY_PATH: None,
        E.BINARY_SHA256: art["sha256"],
        E.HEAD: old["head"],
        E.BINDING: E.UNBOUND,
        "note": "converted from a livekit evidence file whose artifact.built_from_is_measured is "
                f"{art['built_from_is_measured']!r}: the head was inferred from file times, not "
                "measured from a build the verifier ran",
    }
    doc = E.new_document(spec, SPEC_PATH, binary)
    doc["converted_from"] = {
        "path": src_path,
        "sha256": hashlib.sha256(raw).hexdigest(),
        "harness": old["name"],
        "head": old["head"],
        "converter": "Scripts/verify/convert_1020.py",
    }
    readings = mapping(Source(old))
    run = {"date": None, "host": None, E.LOCALE_READING: None, "rows": {}}
    for row in spec["rows"]:
        observations = {}
        for step in row["steps"] + row["restore"]:
            found = readings[row["id"]].get(step["as"])
            if found is None:
                observations[step["as"]] = _observation(step, None, {"record": None}, NOT_DRIVEN)
            else:
                observations[step["as"]] = _observation(step, *found)
        run["rows"][row["id"]] = {"observations": observations}
    doc["runs"][locale] = run
    doc["verdicts"][locale] = engine.evaluate_run(spec, run, locale)
    return doc


def main(argv) -> int:
    if len(argv) != 3:
        print(__doc__.split("\n\n")[1])
        return 2
    src_path, locale, out = argv
    spec = E.load(os.path.join(os.path.dirname(os.path.dirname(HERE)), SPEC_PATH))
    E.write_atomic(out, convert(src_path, locale, spec))
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
