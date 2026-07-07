# T4: Profile-Aware Manual Channel Checks

**Priority**: P1
**Status**: Implemented
**Depends On**: T2

## Objective

Add `DoctorProfile` and use it to distinguish required, optional, and intentionally out-of-scope channel checks.

## Acceptance Criteria

- [ ] Profiles: `auto`, `core`, `mixer`, `keycmd`, `legacy-scripter`, `full`.
- [ ] Core profile does not require Scripter or MIDI Key Commands.
- [ ] Full profile preserves v3-style full setup readiness.
- [ ] Profile selection is visible in JSON and human output.
- [ ] Profile optionality never hides a failed required permission.

## Red Tests

- `coreProfileDoesNotRequireScripterOrKeycmd`
- `fullProfileRequiresManualChannels`
- `keycmdProfileRequiresKeycmdOnlyOps`
- `profileDoesNotHidePostEventFailure`
- `autoProfileRecordsInference`

## Implementation Boundary

Likely files: `SetupDoctor.swift`, `SetupDoctor+ChannelDependencyChecks.swift`, `MainEntrypoint.swift`, docs.

## QA Gate

Run `doctor --json --profile core` and `--profile full` fixtures.

## Implementation Evidence

- `DoctorProfile` supports `auto`, `core`, `mixer`, `keycmd`, `legacy-scripter`, `full`.
- Omitted profile keeps v3-compatible full-scope readiness.
- Explicit `--profile core` scopes manual channel checks out with `skip_reason:profile_not_required`.
- Focused verification: `testDoctorV4ExplicitCoreProfileScopesManualChannels`.
