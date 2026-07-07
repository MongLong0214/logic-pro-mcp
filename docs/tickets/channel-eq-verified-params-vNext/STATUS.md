# Pipeline Status: Channel EQ Verified Params + rename_marker vNext

**PRD**: `docs/prd/PRD-channel-eq-verified-params-vNext.md`
**Status**: T0 factory-metadata harness ready; active-instance evidence gate pending
**Execution rule**: no registry activation and no marker rename implementation without live census/read-back evidence.

## Tickets

| Ticket | Title | Status | Gate |
|--------|-------|--------|------|
| T0 | AudioUnit parameter API census spike | Factory-metadata harness ready | active-instance or explicit factory-only verdict |
| T1 | Preset/project-state census spike | Todo | parameter values mapped to track/insert identity |
| T2 | Automation/control-surface feedback spike | Todo | write/read-back evidence or reject |
| T3 | Channel EQ registry activation | Blocked | T0/T1/T2 PASS |
| T4 | `rename_marker` live gate | Todo | marker write/read-back/rollback |

## Dependency Graph

```text
T0 ┐
T1 ├─> T3
T2 ┘

T4 independent, shares live scratch session
```

## Evidence Gate

Channel EQ State A requires census artifact + duplicate/scratch write/read-back. `rename_marker` State A requires marker identity + editable text path + post-write read-back + rollback.

## Verification

- `swift test --no-parallel` after implementation tickets.
- Live Logic 12.3 E2E evidence for any activated surface.
- Review gate checks no inferred registry entries.
- **TDD**: red tests written and FAIL-verified before implementation; no dead-`#expect` forms (repo footgun #92).
- **Cumulative review (CTO)**: each ticket completion reviews T(n-1)+T(n) diff together + full suite; a full cumulative review runs before T3 (registry activation) and before any T4 production change.
- **Spike safety**: all spikes run on scratch/duplicate projects only; census/spike scripts must never write user presets, user projects, or shared AU state.
