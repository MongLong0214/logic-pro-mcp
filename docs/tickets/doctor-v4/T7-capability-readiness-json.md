# T7: Capability Readiness JSON

**Priority**: P0
**Status**: Implemented
**Depends On**: T2, T4, T6

## Objective

Add top-level capability readiness so the report can say which Logic Pro MCP feature families are ready under the selected profile/client.

## Acceptance Criteria

- [ ] Report includes `capabilities` object with nine named capability groups.
- [ ] Each capability lists contributing check ids and status using the **PRD §5.3 4-state vocabulary**: `ready` / `not_ready` / `unknown_live_verify_required` / `not_in_profile` — fail-closed derivation exactly per the PRD §5.3 table (which is the implementer contract; the table ships as **data**, not logic, so T8's registry absorbs it verbatim).
- [ ] `mixer_mcu` is **never `ready`** — hint-grade evidence (channels.mcu_wiring_hint is positive-only) caps it at `unknown_live_verify_required` with a pointer to `logic://system/health mcu.connected`.
- [ ] Capability status respects profile optionality (§5.1.1) and `blocked_by`.
- [ ] Human output leads with next actionable blocked capability.
- [ ] JSON output is independent from human renderer mode.

## Red Tests

- `capabilitiesContainAllNineGroups`
- `capabilityMapsChecksDeterministically`
- `capabilityReadyWhenAllRequiredChecksPass`
- `capabilityNotReadyOnRequiredCheckFail`
- `capabilityUnknownOnManualOrUnverifiedSkip`
- `capabilityMixerMCUNeverReady` (hint-grade cap — honesty)
- `capabilityNotInProfileWhenProfileExcludes`
- `capabilityBlockedByRootCause`

## Risk (CTO)

Derivation table hard-coded in logic → T8 rewrite risk (keep as data). Capability `ready` on hint-grade evidence → user-facing false-green (the exact class v3/v4 exists to kill).

## Implementation Boundary

Likely files: `SetupDoctor.swift`, new capability model extension, `SetupDoctor+Rendering.swift`, tests.

## QA Gate

JSON fixture snapshots for core, mixer, full, cursor.

## Implementation Evidence

- Report now includes a top-level `capabilities` object with all nine PRD groups.
- Status vocabulary is the PRD v4 four-state set.
- `mixer_mcu` remains hint-grade and cannot become `ready` from the wiring hint alone.
- Focused verification: `testDoctorV4DefaultKeepsV3CompatibleFullScope` and
  `testDoctorV4ExplicitCoreProfileScopesManualChannels`.
