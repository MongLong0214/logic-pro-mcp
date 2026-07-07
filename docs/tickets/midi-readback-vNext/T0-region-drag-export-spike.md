# T0: Region Drag-to-Finder Export Spike

**PRD Ref**: `PRD-midi-readback-vNext` §6.1
**Priority**: P0
**Status**: Harness ready; live run pending
**Depends On**: None

## Objective

Prove or reject the mouse-only region drag export path as a way to bypass the blocked NSSavePanel. The prior T0 proved the save panel cannot be driven by AX or synthetic keyboard input (`docs/spikes/midi-export-t0-evidence.md:18`, `docs/spikes/midi-export-t0-evidence.md:21`).

## Acceptance Criteria

- [ ] A scratch project creates a sentinel MIDI region through `record_sequence`.
- [ ] A controlled temp Finder folder is opened from a registered `ExportTemporaryFiles` directory.
- [ ] Dragging the selected MIDI region into Finder creates exactly one new `.mid` file under that directory.
- [ ] `SMFReader.parse` returns notes equal to the sentinel.
- [ ] Failure leaves no open Logic menu/dialog and does not modify user projects.
- [ ] **In-Logic errant-drag rollback (CTO)**: if the drag terminates inside the arrange area (region MOVED — destructive mutation), the spike asserts Cmd+Z rollback until the region's original position/identity reads back, and the scratch project is closed WITHOUT saving. Evidence records the rollback assertion outcome.
- [ ] **Preconditions verified before any drag**: Accessibility + PostEvent granted (`doctor` pass), Logic frontmost, scratch project confirmed as the active document (never a user project — assert window title/document identity).
- [ ] Evidence file records screen geometry, pre/post directory listing, parsed notes, and recovery outcome.

## Risk (CTO)

Mouse-drag is the only candidate that can mutate the arrange timeline on failure — treat every non-Finder drop as destructive until rollback is proven. Scratch-only forever (PRD §6.1).

## Red Tests

- `regionDragRejectsUnregisteredDestination`
- `regionDragStateCWhenNoNewFile`
- `regionDragStateCWhenParsedNotesMismatch`
- `regionDragRecoverySendsEscapeOnOpenMenu`

## Implementation Boundary

Spike script only: `Scripts/spike-midi-region-drag-export.swift`, plus evidence under `docs/spikes/`.
No production `Sources/` changes.

The harness is deliberately unarmed by default. A live drag requires
`LOGIC_PRO_MCP_ARM_REGION_DRAG=1` and explicit `--source x,y --destination x,y`
coordinates so an unattended run cannot mutate the Logic timeline.

## Manual QA Gate

Run against a fresh scratch project. Capture a success or explicit gate-failed transcript.
