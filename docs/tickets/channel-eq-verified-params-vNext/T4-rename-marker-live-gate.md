# T4: `rename_marker` Live Gate

**PRD Ref**: `PRD-channel-eq-verified-params-vNext` §5.6
**Priority**: P1
**Status**: Todo
**Depends On**: None

## Objective

Prove or reject a marker rename path with read-back and rollback. If the gate fails, keep `rename_marker` as State C `not_implemented`.

## Acceptance Criteria

- [ ] Scratch project creates a marker with a unique name.
- [ ] Marker List/global Marker track is made visible.
- [ ] The spike captures marker identity before write.
- [ ] Rename writes through a deterministic editable text surface.
- [ ] Post-write marker list read-back matches the new name.
- [ ] Rollback restores the original marker name and verifies it.
- [ ] If any step is unproven, evidence records the failed surface and production remains unchanged.

## Red Tests

- `renameMarkerRequiresEditableSurface`
- `renameMarkerStateARequiresReadback`
- `renameMarkerRollsBackOriginalName`
- `renameMarkerRemainsNotImplementedWhenGateFails`

## Implementation Boundary

Spike first. Production changes, if any, are limited to `AXLogicProElements+Markers`, `AccessibilityChannel`, `NavigateDispatcher` tests, docs/API, and live E2E.

## Manual QA Gate

Happy path plus failure when Marker List is hidden or no marker exists.
