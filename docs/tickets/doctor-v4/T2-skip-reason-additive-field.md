# T2: `skip_reason` Additive Field

**Priority**: P0
**Status**: Implemented
**Depends On**: T1

## Objective

Add a structured reason for every skipped check that is not already explained by `blocked_by`.

## Acceptance Criteria

- [ ] `Check` gains optional `skip_reason` (wire `skip_reason`, omit-when-nil via synthesized `encodeIfPresent` — the shipped `blocked_by` pattern, `Sources/LogicProMCP/Utilities/SetupDoctor.swift:66-70`).
- [ ] Every skipped check has either `blocked_by` or `skip_reason` (structural test over the full report).
- [ ] Optional-by-design skips do not degrade aggregate readiness — **optionality source at this stage is the shipped `Check.optional` flag** (`SetupDoctor+Rendering.swift:137` already exempts optional skips from degrading); T2 labels the *reason*, profile-driven optionality arrives in T4.
- [ ] **Schema string bumps to `logic_pro_mcp_doctor.v4` in this ticket** (PRD §3 decision — first wire-visible v4 field lands here; all later tickets are additive against v4).
- [ ] Frozen v3-style consumers still decode the report (**new `FrozenV3Report` decode test**, extending the shipped FrozenV1/V2 chain).
- [ ] Human renderer shows skip reason in verbose mode only.

## Risk (CTO)

Touches aggregate-adjacent semantics — regression risk on the shipped optional-skip rule (`SetupDoctor+Rendering.swift:130-140`); FrozenV3 decode + exact-id contract tests are the safety net.

## Red Tests

- `doctorSkippedChecksRequireBlockedByOrSkipReason`
- `doctorSkipReasonOmittedWhenNil`
- `doctorOptionalSkipDoesNotDegrade`
- `doctorFrozenV3ConsumerIgnoresSkipReason`
- `doctorVerboseRendererShowsSkipReason`

## Implementation Boundary

Likely files: `SetupDoctor.swift`, `SetupDoctor+Rendering.swift`, `SetupDoctorEnterpriseTests.swift`, `SetupDoctorTests.swift`.

## QA Gate

Focused doctor contract tests and JSON decode test.

## Implementation Evidence

- `SetupDoctor.Check` now emits optional `skip_reason`.
- Schema string is `logic_pro_mcp_doctor.v4`.
- Existing frozen v1/v2 shaped decoders still pass because v4 fields are additive.
- Focused verification: `swift test --filter SetupDoctor` passed.
