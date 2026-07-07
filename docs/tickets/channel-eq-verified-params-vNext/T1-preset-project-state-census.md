# T1: Preset / Project-State Census Spike

**PRD Ref**: `PRD-channel-eq-verified-params-vNext` §5.3
**Priority**: P1
**Status**: Todo
**Depends On**: None

## Objective

Test whether Channel EQ parameter state can be read from a saved preset, project package, or duplicate scratch project without relying on GUI AX controls.

## Acceptance Criteria

- [ ] Scratch project with Channel EQ inserted and known parameter changes.
- [ ] Save/export only within a controlled scratch path.
- [ ] Extract parameter values with canonical id, unit, range, and value mapping.
- [ ] Prove round-trip by changing a param and observing expected serialized delta.
- [ ] If any save panel is required and blocked, record an honest defer.

## Red Tests

- `presetCensusRejectsUnmappedSerializedValue`
- `presetCensusRequiresTrackInsertIdentity`
- `presetCensusDoesNotUseUncontrolledSavePath`

## Implementation Boundary

Read-only spike/parser prototype. Production activation waits for T3.

## Manual QA Gate

Evidence includes before/after preset or package delta and exact value comparison.
