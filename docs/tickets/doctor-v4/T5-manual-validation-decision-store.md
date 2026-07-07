# T5: Manual Validation Decision Store

**Priority**: P1
**Status**: Todo
**Depends On**: T4

## Objective

Separate "approved" from "intentionally skipped" for manual validation channels and add `--skip-channel`.

## Acceptance Criteria

- [ ] Manual decision model supports `approved` and `intentionally_skipped`.
- [ ] `--skip-channel` writes an intentional skip with timestamp and optional note.
- [ ] Corrupt/unreadable store surfaces a health warning, not silent empty state.
- [ ] Revocation works for both decision kinds.
- [ ] Existing approvals migrate without data loss.

## Red Tests

- `manualStorePersistsApprovedDecision`
- `manualStorePersistsIntentionalSkip`
- `manualStoreCorruptReadWarnsDoctor`
- `manualStoreRevokeRemovesBothKinds`
- `manualStoreMigratesLegacyApprovals`

## Implementation Boundary

Likely files: `ManualValidationStore.swift`, `MainEntrypoint.swift`, `SetupDoctor+ChannelDependencyChecks.swift`, manual store tests.

## QA Gate

CLI smoke for approve, skip, list, revoke using temp store.
