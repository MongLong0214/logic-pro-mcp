# T0: AudioUnit Parameter API Census Spike

**PRD Ref**: `PRD-channel-eq-verified-params-vNext` §5.1
**Priority**: P0
**Status**: Factory-metadata harness ready; active-instance proof pending
**Depends On**: None

## Objective

Determine whether public AudioUnit APIs can enumerate and read/write the active Channel EQ instance inside Logic, or only provide factory metadata.

## Acceptance Criteria

- [ ] Enumerate Channel EQ parameter ids/names/ranges through public APIs if possible.
- [ ] Explicitly classify whether the handle is an active Logic insert or factory metadata only.
- [ ] **Factory-metadata role pinned (CTO)**: factory metadata may SEED candidate canonical ids/units/ranges for the census artifact, but is NEVER activation evidence — every activated param requires active-instance write/read-back proof from some surface (this or another spike). The census artifact must label each field's provenance (`factory_metadata` vs `active_instance`).
- [ ] **Isolation (CTO)**: if the spike instantiates Channel EQ in-process for metadata, it must not write any shared AU preset/state that Logic reads (no default-preset mutation, no user `~/Library/Audio/Presets` writes) — read-only instantiation, discard on exit.
- [ ] If active instance access is possible, perform scratch duplicate write/read-back on at least one safe param.
- [ ] If not possible, record the process-boundary blocker and do not activate registry entries.

## Red Tests

- `audioUnitCensusRejectsFactoryOnlyAsStateA`
- `audioUnitCensusRequiresActiveInsertIdentity`
- `audioUnitCensusRequiresUnitRangeTolerance`

## Implementation Boundary

Spike code only. No production registry changes in this ticket.

Added harness: `Scripts/spike-channel-eq-au-census.swift`. It emits
`provenance:"factory_metadata"` and `activation_evidence:false` for every
parameter so factory metadata cannot be mistaken for active Logic insert proof.

## Manual QA Gate

Run with Channel EQ inserted on a scratch track; evidence must distinguish active-instance proof from static metadata.
