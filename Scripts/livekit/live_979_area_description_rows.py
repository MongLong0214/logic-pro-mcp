#!/usr/bin/env python3
"""Live measurement for #979: which strings-table row does each main-window area's description equal?

Usage:  python3 live_979_area_description_rows.py <out.json>

Needs Logic running in the language under test on a project whose main window shows the Tracks area,
the Control Bar, the Inspector, the Library and the docked Mixer, and nobody using the Mac. Nothing is
pressed or written, so the project is left as it was.

`ax_979_area_rows_probe.swift` reads every element within two levels of each window. For each of the
five areas, four rows of the installed Logic.framework's Localizable.strings are candidates, one per
key shape Apple uses for these names: the `#acc` row, the plain key, `StrTabBtnLabel|||<area>` and
`StrViewBtns|||<area>`. A description is credited to an area when it equals one of that area's
candidates ignoring case, the comparison the product makes, and is then reported against each
candidate exactly. Every other key in the table carrying the same string is listed too, so a row
outside the four shapes is not hidden by the choice of candidates.

A key shape is REFUTED for a role in this locale when an element of that role was read for an area
the shape has a row for, and its description differs from that row's value exactly. Case is not
forgiven here: #979 is the case where a reading equals one row and another row only up to case.
Roles are judged apart, because the Control Bar's view buttons carry the same names as the areas.

Exit 0 when all five areas were read as containers (AXGroup or AXLayoutArea), so the container
verdicts rest on every area a shape has a row for. Exit 1 when one was not; its candidates and every
unexplained description are in the output.
"""

import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import logic_canon  # noqa: E402
import observation_host  # noqa: E402

if len(sys.argv) != 2:
    sys.exit(__doc__)
OUT = sys.argv[1]

AREAS = ("Control Bar", "Inspector", "Library", "Mixer", "Tracks")
SHAPES = {"#acc": "{}#acc", "plain": "{}", "StrTabBtnLabel": "StrTabBtnLabel|||{}",
          "StrViewBtns": "StrViewBtns|||{}"}
# The containers the question is about. An area counts as read only through one of these.
AREA_ROLES = ("AXGroup", "AXLayoutArea")
LPROJ = {"de-DE": "de", "en-US": "en", "es-ES": "es", "fr-FR": "fr", "it-IT": "it", "ja-JP": "ja",
         "ko-KR": "ko", "pt-BR": "pt", "zh-CN": "zh_CN", "zh-TW": "zh_TW"}
TABLE = os.path.join(logic_canon.DEFAULT_APP, "Contents", "Frameworks", "Logic.framework", "Versions",
                     "A", "Resources", "{}.lproj", "Localizable.strings")

host = observation_host.host()
lproj = LPROJ.get(host.get("locale"))
if lproj is None:
    sys.exit(f"Logic's interface language maps to no axis locale: {host.get('locale')!r}")
with open(TABLE.format(lproj), "rb") as handle:
    raw = handle.read()
rows = logic_canon.parse_strings(raw, path=TABLE.format(lproj))

PROBE = os.path.join(os.path.dirname(os.path.abspath(OUT)), "ax_979_area_rows_probe")
built = subprocess.run(["swiftc", "-O", os.path.join(HERE, "ax_979_area_rows_probe.swift"), "-o", PROBE],
                       capture_output=True, text=True)
if built.returncode != 0:
    sys.exit(f"cannot build the probe: {built.stderr[:400]}")
probe_run = subprocess.run([PROBE], capture_output=True, text=True, timeout=120)
try:
    probe = json.loads(probe_run.stdout)
except ValueError:
    sys.exit(f"the probe did not answer JSON: {(probe_run.stdout or probe_run.stderr)[:400]}")
if "windows" not in probe:
    sys.exit(f"the probe could not read Logic's windows: {probe}")

candidates = {area: {shape: {"key": pattern.format(area), "value": rows.get(pattern.format(area))}
                     for shape, pattern in SHAPES.items()} for area in AREAS}

readings, unexplained, errors = [], [], []
for window in probe["windows"]:
    for element in window.get("elements", []):
        if any(key.endswith("_error") for key in element):
            errors.append({"window": window.get("title"), **element})
        text = element.get("description")
        if not text:
            continue
        areas = [area for area in AREAS
                 if any(c["value"] is not None and c["value"].casefold() == text.casefold()
                        for c in candidates[area].values())]
        if not areas:
            if element.get("depth") == 1:
                unexplained.append({"window": window.get("title"), "path": element["path"],
                                    "role": element.get("role"), "description": text})
            continue
        for area in areas:
            readings.append({
                "area": area, "window": window.get("title"), "path": element["path"],
                "depth": element.get("depth"), "role": element.get("role"), "description": text,
                "equal": sorted(s for s, c in candidates[area].items() if c["value"] == text),
                "equal_ignoring_case_only": sorted(
                    s for s, c in candidates[area].items()
                    if c["value"] is not None and c["value"] != text
                    and c["value"].casefold() == text.casefold()),
                "every_key_with_this_value": sorted(k for k, v in rows.items() if v == text)[:20],
            })

read_areas = sorted({r["area"] for r in readings if r["role"] in AREA_ROLES})
# Judged per role: the area containers and the Control Bar's view buttons carry the same names, and
# nothing says one row feeds both, so a button's reading must not settle the container's row.
shapes = {}
for role in sorted({r["role"] for r in readings}):
    shapes[role] = {}
    of_role = [r for r in readings if r["role"] == role]
    for shape in SHAPES:
        refuted = [{"area": r["area"], "path": r["path"], "reading": r["description"],
                    "row": candidates[r["area"]][shape]["value"]}
                   for r in of_role
                   if candidates[r["area"]][shape]["value"] is not None and shape not in r["equal"]]
        shapes[role][shape] = {
            "verdict": "refuted" if refuted else "consistent",
            "areas_tested": sorted({r["area"] for r in of_role
                                    if candidates[r["area"]][shape]["value"] is not None}),
            "refuted_at": refuted,
        }

record = {
    "host": host,
    "table": {"lproj": lproj, "sha256": hashlib.sha256(raw).hexdigest(), "rows": len(rows)},
    "candidates": candidates,
    "readings": readings,
    "shapes": shapes,
    "unexplained_depth_1_descriptions": unexplained,
    "read_errors": errors,
    "window_titles": [w.get("title") for w in probe["windows"]],
    "areas_read": read_areas,
}
with open(OUT, "w", encoding="utf-8") as handle:
    json.dump(record, handle, ensure_ascii=False, indent=1)

print(f"locale {host.get('locale')}  table {lproj}  {len(readings)} readings  "
      f"{len(unexplained)} unexplained  {len(errors)} read errors")
for role, verdicts in shapes.items():
    for shape, verdict in verdicts.items():
        detail = "; ".join(f"{x['area']}: read {x['reading']!r}, row {x['row']!r}"
                           for x in verdict["refuted_at"][:3])
        print(f"{role:14} {shape:15} {verdict['verdict']:10} tested {verdict['areas_tested']}  {detail}")
missing = [a for a in AREAS if a not in read_areas]
if missing:
    print(f"FAIL not read: {missing}")
sys.exit(1 if missing else 0)
