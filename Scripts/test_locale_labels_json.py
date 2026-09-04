#!/usr/bin/env python3
"""Prove `Scripts/check-locale-labels-json.py` can fail — on a claim, not only on a mismatch.

The guard's older job was "the JSON equals the Swift". Its job now is "every claim the JSON makes
about a string is backed by a record that SAW that string". Each case plants one way that backing
can be missing, wrong, or merely well-formed, and requires the guard to name it. The load-bearing
cases are 4 and 11: a provenance block whose record exists, matches the locale, has a real date,
and contains the variant in `observed` — and whose record never observed the string. That is the
shape an outside review showed the earlier guard accepting, and it is three strings with a fourth
string pointing at an unrelated object.
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


guard = load("locale_labels_guard", "check-locale-labels-json.py")
labels = load("locale_labels", "locale_labels.py")

LOCALES = ("en-US", "ko-KR", "ja-JP")
VALUES = ("measured", "identifier", "unmeasured")
D = "2026-09-05"


def _ledger(records):
    """A temp observations dir: {id: (locale, [observation strings])}."""
    d = Path(tempfile.mkdtemp())
    for rid, (locale, seen) in records.items():
        (d / f"{rid}.json").write_text(json.dumps({
            "id": rid, "date": D, "host": {"locale": locale},
            "observations": [{"what": "census", "seen": seen}]}, ensure_ascii=False), encoding="utf-8")
    return str(d)


def _entry(variants, provenance=None, coverage=None, cites=None, canonical="input slot"):
    e = {"canonical": canonical, "variants": variants, "rationale": "r"}
    if provenance is not None:
        e["provenance"] = provenance
    e["coverage"] = coverage if coverage is not None else {loc: "unmeasured" for loc in LOCALES}
    if cites:
        e["coverage_records"] = cites
    return e


def _prov(record="2026-09-05-ko", locale="ko-KR", observed="입력 슬롯. 채널 스트립", date=D):
    return {"record": record, "locale": locale, "observed": observed, "date": date}


def main():
    failures = []

    def case(name, condition, detail):
        if not condition:
            failures.append(f"{name}: {detail}")

    guard.OBS = _ledger({
        "2026-09-05-ko":      ("ko-KR", ["입력 슬롯. 채널 스트립 입력 소스", "출력 슬롯"]),
        "2026-09-05-ja":      ("ja-JP", ["入力スロット"]),
        "2026-09-05-ko-blind": ("ko-KR", ["something unrelated entirely"]),
        "2026-09-05-en":      ("en-US", ["input slot. Choose the channel strip input"]),
    })
    U = {loc: "unmeasured" for loc in LOCALES}
    ko_measured = dict(U, **{"ko-KR": "measured"})

    def prov_problems(e): return guard.provenance_problems("L", e)
    def cov_problems(e): return guard.coverage_problems("L", e, LOCALES, VALUES)

    # 1. A fully backed entry has no problems.
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov()}, ko_measured)
    case("clean entry", prov_problems(e) == [] and cov_problems(e) == [], prov_problems(e) + cov_problems(e))

    # 2. Provenance naming a record that is not in the ledger.
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov(record="2026-09-05-nope")}, ko_measured)
    case("missing record", any("not in docs/observations" in x for x in prov_problems(e)), prov_problems(e))

    # 3. Provenance whose record was measured in a different locale than it claims.
    e = _entry(["入力スロット"], {"入力スロット": _prov(record="2026-09-05-ja", observed="入力スロット")}, ko_measured)
    case("locale mismatch", any("measured in 'ja-JP'" in x for x in prov_problems(e)), prov_problems(e))

    # 4. THE LOAD-BEARING CASE. Record exists, locale matches, date is real, `observed` contains the
    #    variant — and the record never saw the string. Referential integrity passes; evidence does not.
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov(record="2026-09-05-ko-blind")}, ko_measured)
    p = prov_problems(e)
    case("record never saw it", any("never saw it" in x for x in p), p)

    # 5. A date that does not match the record's.
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov(date="2026-09-01")}, ko_measured)
    case("date mismatch", any("was measured" in x and "dated" in x for x in prov_problems(e)), prov_problems(e))

    # 6. `observed` that does not contain the variant.
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov(observed="something else")}, ko_measured)
    case("observed lacks variant", any("containing the variant" in x for x in prov_problems(e)), prov_problems(e))

    # 7. Provenance for a string that is not a variant at all.
    e = _entry(["입력 슬롯"], {"출력 슬롯": _prov(observed="출력 슬롯")}, ko_measured)
    case("stray provenance", any("not one of its variants" in x for x in prov_problems(e)), prov_problems(e))

    # 8. `unmeasured` declared where a variant with provenance exists — the projection derives
    #    `measured`, and a hand-written `unmeasured` there is a lie in the other direction.
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov()}, U)
    case("unmeasured with provenance", any("it is measured" in x for x in cov_problems(e)), cov_problems(e))

    # 9. `measured` with no variant provenance and no citation.
    e = _entry([], None, ko_measured)
    case("measured without record", any("claim of measurement" in x for x in cov_problems(e)), cov_problems(e))

    # 10. `measured` citing a record from the wrong locale.
    e = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-ja"})
    case("measured wrong locale", any("not ko-KR" in x for x in cov_problems(e)), cov_problems(e))

    # 11. `measured` citing a record that saw NONE of the label's strings.
    e = _entry([], None, ko_measured, cites={"ko-KR": "2026-09-05-ko-blind"})
    case("measured but record saw nothing", any("none of this label's strings" in x for x in cov_problems(e)), cov_problems(e))

    # 12. `measured` via the CANONICAL appearing in an en-US record — no variant needed.
    e = _entry([], None, dict(U, **{"en-US": "measured"}), cites={"en-US": "2026-09-05-en"})
    case("measured via canonical", cov_problems(e) == [], cov_problems(e))

    # 13. `identifier` needs a record in that locale too.
    e = _entry([], None, dict(U, **{"ko-KR": "identifier"}))
    case("identifier without record", any("claim of measurement" in x for x in cov_problems(e)), cov_problems(e))
    e = _entry([], None, dict(U, **{"ko-KR": "identifier"}), cites={"ko-KR": "2026-09-05-ko"})
    case("identifier backed", cov_problems(e) == [], cov_problems(e))

    # 14. Coverage that skips a locale, or uses a value outside the three.
    e = _entry([], None, {"en-US": "unmeasured", "ko-KR": "unmeasured"})
    case("missing locale", any("expected exactly" in x for x in cov_problems(e)), "")
    e = _entry([], None, dict(U, **{"ko-KR": "absent"}))
    case("retired value refused", any("not one of" in x for x in cov_problems(e)), "")

    # 15. Migration: a schema-1 `measured` block becomes `provenance` and derives `measured`.
    v1 = {"schema": 1, "labels": {"inputSlotHelpKeyword": {"measured": {"입력 슬롯": _prov()}}}}
    built = labels.build(existing=v1)
    entry = built["labels"].get("inputSlotHelpKeyword") or {}
    case("measured block migrates", "입력 슬롯" in (entry.get("provenance") or {}), json.dumps(entry, ensure_ascii=False)[:160])
    case("measured derived", (entry.get("coverage") or {}).get("ko-KR") == "measured", entry.get("coverage"))
    case("schema 2", built.get("schema") == 2, built.get("schema"))

    # 16. Migration: a cited `measured` survives regeneration; an uncited one does not.
    v2 = {"schema": 2, "labels": {"inputSlotHelpKeyword": {
        "coverage": {"en-US": "measured", "ko-KR": "measured", "ja-JP": "unmeasured"},
        "coverage_records": {"en-US": "2026-09-05-en"}}}}
    built = labels.build(existing=v2)
    entry = built["labels"].get("inputSlotHelpKeyword") or {}
    cov = entry.get("coverage") or {}
    case("cited measured survives", cov.get("en-US") == "measured" and
         (entry.get("coverage_records") or {}).get("en-US") == "2026-09-05-en", entry)
    case("uncited measured is dropped", cov.get("ko-KR") == "unmeasured", cov)

    # 17. The real document is clean.
    proc = subprocess.run([sys.executable, str(HERE / "check-locale-labels-json.py")], capture_output=True, text=True)
    case("repository is clean", proc.returncode == 0, proc.stdout.strip()[:200])

    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print("19 case(s) pass: a claim is refused unless a record in that locale SAW the string")
    return 0


if __name__ == "__main__":
    sys.exit(main())
