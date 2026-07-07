# T8: Typed Check Registry

**Priority**: P0
**Status**: Todo
**Depends On**: T2

## Objective

Replace stringly scattered check metadata with a typed registry while preserving wire ids.

## Acceptance Criteria

- [ ] Add `DoctorCheckID` enum for all check ids.
- [ ] Add `DoctorCheckDefinition` with dependencies, optionality, capability group, remediation anchor, and profile/client rules.
- [ ] Duplicate id test fails if two definitions share a wire id.
- [ ] Every remediation anchor has docs coverage.
- [ ] Existing check order remains stable unless deliberately changed.

## Red Tests

- `doctorCheckIDsAreUnique`
- `doctorDefinitionsCoverAllRenderedChecks`
- `doctorDefinitionsCoverAllRemediationAnchors`
- `doctorDefinitionOrderMatchesReportOrder`
- `doctorBlockedByTableDerivedFromDefinitions`

## Implementation Boundary

Likely files: new `SetupDoctor+CheckRegistry.swift`, `SetupDoctor.swift`, docs anchor tests.

## QA Gate

Full doctor focused tests plus anchor lint.
