# T1 — v2 Model Framework

**Size**: M-L
**Depends on**: none
**PRD ACs**: G3, G4, G6, AC-1.5, AC-3.1–3.5, AC-4.1, E10
**Files**: `Sources/LogicProMCP/Utilities/SetupDoctor.swift`, `Tests/LogicProMCPTests/SetupDoctorTests.swift` (+ new `SetupDoctorEnterpriseTests.swift`)

## Goal
Evolve the report to `logic_pro_mcp_doctor.v2` as a field-superset: add `Category`/`Severity` enums,
per-check `category`/`severity`/`duration_ms`, a `Summary` block, a `headline`, monotonic timing, the
monotonicity chokepoint, and explicit `Check` `CodingKeys`. **No new checks** here — instrument the existing 11.

## Design
- `enum Category: String, Codable { installation, configuration, permissions, dependencies, runtime, updates }`
- `enum Severity: String, Codable { error, warning, info }`
- `Check` gains `category`, `severity`, `durationMs` with an **explicit `CodingKeys`** enumerating ALL keys
  (`id, domain, status, summary, evidence, remediation, category, severity, durationMs="duration_ms"`).
- `severity(for: CheckStatus)`: total — fail→error, warn→warning, manual→warning, skipped→info, pass→info.
- `category(forDomain:)`: deterministic central map (binary/install/release→installation; mcp→configuration;
  permissions→permissions; logic→runtime; channels→configuration; [dependencies/updates added in T2/T4]).
- `struct Summary { total, passed, failed, warnings, manual, skipped: Int; durationMs (key "duration_ms") }`.
- `Report` gains `summary` and `headline`; `schema = "logic_pro_mcp_doctor.v2"`.
- Timing: `Runtime.monotonicNowMs: () -> Double` (production: `DispatchTime.now().uptimeNanoseconds`/1e6).
  Each check closure wrapped: capture `start`, run, `durationMs = now - start`. Sequential.
- Monotonicity chokepoint in `generate()`: `if !permissionStatus.allGranted && status == .ok { status = .degraded }`.
- `headline`: first non-pass check by (severity error→warning, then stable order) → its summary+remediation;
  else "Logic Pro MCP install is healthy.".
- `calculateSummary(checks, totalDurationMs)`: counts by status; durationMs = sum of per-check.

## TDD — Red first (write failing tests, then implement)
1. `test_schema_is_v2`: `report.schema == "logic_pro_mcp_doctor.v2"`.
2. `test_each_check_has_category_severity_duration`: every check has a non-empty category rawValue, a severity
   consistent with its status (force-unwrapped live assertions), and `durationMs >= 0`.
3. `test_severity_mapping_total`: construct checks of each status; assert fail→error, warn→warning,
   manual→warning, skipped→info, pass→info.
4. `test_summary_counts_invariant`: `passed+failed+warnings+manual+skipped == total == checks.count` across a
   mixed report; assert each count matches the actual per-status tally.
5. `test_summary_status_formula` (AC-3.5): a degraded report has `(warnings>0||skipped>0) && failed==0 && manual==0`;
   an ok report has all-zero non-pass counts.
6. `test_summary_duration_is_sum_ge_max`: with an injected monotonic clock that advances a fixed delta per call,
   `summary.durationMs == Σ per-check` and `>= max per-check` and `>= 0`.
7. `test_monotonicity_chokepoint` (AC-1.5): for each of the 3 `allGranted` inputs set false independently
   (accessibility, automationLogicPro, automationSystemEvents), `report.status != .ok`.
8. `test_headline_names_highest_severity` (AC-4.2/4.3): a report with a fail + a warn → headline references the
   fail's id; an all-pass report → healthy headline.
9. **E10(a)** `test_v2_json_contains_literal_v1_keys`: encode report, parse raw JSON; assert literal keys
   `"id","domain","status","summary","evidence","remediation"` exist on each check object and
   `"schema","status","version","install_source","checks"` at top level.
10. **E10(b)** `test_v2_decodes_with_frozen_v1_struct`: define a private frozen v1 `Codable` mirror
    (`FrozenV1Report`/`FrozenV1Check`/`FrozenV1Remediation`) and `decodeJSON` the v2 output into it without error;
    assert all v1 check ids present.
11. **E10(c)** already covered by #1 (schema exactly v2).
12. Update existing `SetupDoctorTests` v1 assertions: schema `v1`→`v2`; the `ids ==` list test stays (11 ids
    unchanged in T1; T2 extends it). Existing remediation/aggregation tests must still pass (regression).

## Acceptance
- All new + existing doctor tests green under `swift test --no-parallel`.
- No new check IDs (still 11). Schema is v2. v1 field names/values intact (E10 a+b+c).
