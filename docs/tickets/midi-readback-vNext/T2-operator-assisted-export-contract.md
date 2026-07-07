# T2: Operator-Assisted Export Contract

**PRD Ref**: `PRD-midi-readback-vNext` §6.3
**Priority**: P2
**Status**: Todo
**Depends On**: None

## Objective

Design and prove an explicitly non-default flow where a human operator saves Logic's export panel to a server-registered target path while the server verifies the resulting file.

## Acceptance Criteria

- [ ] The flow is disabled by default and requires an explicit profile/flag.
- [ ] The server pre-registers the exact output path and rejects stale files.
- [ ] Timeout, wrong path, wrong region, and parse failure return State B/C, never State A.
- [ ] Human-facing instructions are concise and do not expose unrelated local paths.
- [ ] The flow does not become part of normal autonomous agent readiness.

## Red Tests

- `operatorExportRequiresExplicitProfile`
- `operatorExportRejectsStaleFile`
- `operatorExportStateCOnWrongPath`
- `operatorExportStateBWhenSelectionIdentityMissing`

## Implementation Boundary

Contract design plus spike harness. Production surface must wait for an explicit product decision because this introduces human-in-the-loop behavior.

## Manual QA Gate

One success with exact path and one failure with wrong path.
