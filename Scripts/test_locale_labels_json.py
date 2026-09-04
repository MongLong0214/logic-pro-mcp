#!/usr/bin/env python3
"""Prove `Scripts/check-locale-labels-json.py` can fail — on a claim, not only on a mismatch.

The guard's older job was "the JSON equals the Swift". Its job now is also "every claim the JSON
makes about a string is backed by a record in the ledger". Each case below plants one way that
backing can be missing or wrong and requires the guard to name it. The migration cases at the end
require `locale_labels.py` to carry evidence across regeneration, because a `--write` that erased
provenance would turn every measured label back into an unmeasured one in a single commit.
"""
import importlib.util
import json
import os
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
VALUES = ("present", "absent", "identifier", "unmeasured")


def _ledger(records):
    """A temp observations dir holding the given {id: locale} records; returns its path."""
    d = Path(tempfile.mkdtemp())
    for rid, locale in records.items():
        (d / f"{rid}.json").write_text(json.dumps({"id": rid, "host": {"locale": locale}}), encoding="utf-8")
    return str(d)


def _entry(variants, provenance=None, coverage=None, cites=None):
    e = {"canonical": "input slot", "variants": variants, "rationale": "r"}
    if provenance is not None:
        e["provenance"] = provenance
    e["coverage"] = coverage if coverage is not None else {loc: "unmeasured" for loc in LOCALES}
    if cites:
        e["coverage_records"] = cites
    return e


def _prov(record="2026-09-05-r", locale="ko-KR", observed="입력 슬롯. 채널 스트립", date="2026-09-05"):
    return {"record": record, "locale": locale, "observed": observed, "date": date}


def main():
    failures = []

    def case(name, condition, detail):
        if not condition:
            failures.append(f"{name}: {detail}")

    guard.OBS = _ledger({"2026-09-05-r": "ko-KR", "2026-09-05-ja": "ja-JP"})
    good_cov = {"en-US": "unmeasured", "ko-KR": "present", "ja-JP": "unmeasured"}

    # 1. A fully backed entry has no problems.
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov()}, good_cov)
    case("clean entry", guard.provenance_problems("L", e) == [] and
         guard.coverage_problems("L", e, LOCALES, VALUES) == [], "a backed entry was refused")

    # 2. Provenance naming a record that is not in the ledger.
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov(record="2026-09-05-nope")}, good_cov)
    p = guard.provenance_problems("L", e)
    case("missing record", any("not in docs/observations" in x for x in p), p)

    # 3. Provenance whose record was measured in a different locale than it claims.
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov(record="2026-09-05-ja")}, good_cov)
    p = guard.provenance_problems("L", e)
    case("locale mismatch", any("measured in 'ja-JP'" in x for x in p), p)

    # 4. `observed` that does not contain the variant is three strings, not a reading.
    e = _entry(["입력 슬롯"], {"입력 슬롯": _prov(observed="something else")}, good_cov)
    p = guard.provenance_problems("L", e)
    case("observed lacks variant", any("containing the variant" in x for x in p), p)

    # 5. Provenance for a string that is not a variant at all.
    e = _entry(["입력 슬롯"], {"출력 슬롯": _prov(observed="출력 슬롯")}, good_cov)
    p = guard.provenance_problems("L", e)
    case("stray provenance", any("not one of its variants" in x for x in p), p)

    # 6. `present` declared with no provenance in that locale — present is derived, never typed.
    e = _entry(["입력 슬롯"], None, good_cov)
    p = guard.coverage_problems("L", e, LOCALES, VALUES)
    case("present without provenance", any("derived from provenance" in x for x in p), p)

    # 7. `absent` with no record cited — a claim of absence needs a reading too.
    e = _entry([], None, {"en-US": "absent", "ko-KR": "unmeasured", "ja-JP": "unmeasured"})
    p = guard.coverage_problems("L", e, LOCALES, VALUES)
    case("absent without record", any("claim of absence" in x for x in p), p)

    # 8. `absent` citing a record from the wrong locale.
    e = _entry([], None, {"en-US": "absent", "ko-KR": "unmeasured", "ja-JP": "unmeasured"},
               cites={"en-US": "2026-09-05-r"})
    p = guard.coverage_problems("L", e, LOCALES, VALUES)
    case("absent wrong locale", any("not en-US" in x for x in p), p)

    # 9. `absent` correctly cited passes.
    e = _entry([], None, {"en-US": "unmeasured", "ko-KR": "absent", "ja-JP": "unmeasured"},
               cites={"ko-KR": "2026-09-05-r"})
    case("absent backed", guard.coverage_problems("L", e, LOCALES, VALUES) == [], "a backed absence was refused")

    # 10. Coverage that skips a locale, or uses a value outside the four.
    e = _entry([], None, {"en-US": "unmeasured", "ko-KR": "unmeasured"})
    case("missing locale", any("expected exactly" in x for x in guard.coverage_problems("L", e, LOCALES, VALUES)), "")
    e = _entry([], None, {"en-US": "unmeasured", "ko-KR": "maybe", "ja-JP": "unmeasured"})
    case("bad value", any("not one of" in x for x in guard.coverage_problems("L", e, LOCALES, VALUES)), "")

    # 11. Migration: a schema-1 `measured` block becomes `provenance` and derives `present`.
    v1 = {"schema": 1, "labels": {"inputSlotHelpKeyword": {
        "measured": {"입력 슬롯": _prov()}}}}
    built = labels.build(existing=v1)
    entry = built["labels"].get("inputSlotHelpKeyword") or {}
    case("measured migrates", "입력 슬롯" in (entry.get("provenance") or {}), json.dumps(entry, ensure_ascii=False)[:200])
    case("present derived", (entry.get("coverage") or {}).get("ko-KR") == "present", entry.get("coverage"))
    case("schema 2", built.get("schema") == 2, built.get("schema"))

    # 12. Migration: a cited absence survives regeneration; an uncited one does not become absent.
    v2 = {"schema": 2, "labels": {"inputSlotHelpKeyword": {
        "coverage": {"en-US": "absent", "ko-KR": "absent", "ja-JP": "unmeasured"},
        "coverage_records": {"en-US": "2026-09-05-en"}}}}
    built = labels.build(existing=v2)
    entry = built["labels"].get("inputSlotHelpKeyword") or {}
    cov = entry.get("coverage") or {}
    case("cited absence survives", cov.get("en-US") == "absent" and
         (entry.get("coverage_records") or {}).get("en-US") == "2026-09-05-en", entry)
    # ko-KR was carried as `absent` with NO citation: that is not evidence and must not survive.
    case("uncited absence is dropped", cov.get("ko-KR") == "unmeasured", cov)

    # 13. The real document is clean.
    import subprocess
    proc = subprocess.run([sys.executable, str(HERE / "check-locale-labels-json.py")],
                          capture_output=True, text=True)
    case("repository is clean", proc.returncode == 0, proc.stdout.strip()[:200])

    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print("13 case(s) pass: a claim without a record, in the wrong locale, or typed as `present` is refused")
    return 0


if __name__ == "__main__":
    sys.exit(main())
