# T8: E2E First-Song Journey Validation

**PRD Ref**: PRD-first-song-journey > US-6
**Priority**: P0
**Size**: S
**Status**: Todo
**Depends On**: T1-T7

## 1. Objective
Validate the complete first-song journey end-to-end: Logic Pro running → new project → create track → MIDI input → play/stop → save.

## 2. Acceptance Criteria
- [ ] AC-1: Cold start: `project.new` → document exists (verified by AX)
- [ ] AC-2: `tracks.create_instrument` → track count = 1 (verified by AX)
- [ ] AC-3: MIDI input via CoreMIDI → notes received (requires armed track + virtual port)
- [ ] AC-4: `transport.play` / `transport.stop` → state changes
- [ ] AC-5: `project.save_as` → .logicx file exists on disk
- [ ] AC-6: Full journey completes without manual intervention

## 3. Validation Procedure
1. Ensure Logic Pro is running with no open documents
2. Call `logic_project(new)` → verify document created
3. Call `logic_tracks(create_instrument)` → verify track count = 1
4. Arm track, send MIDI notes via CoreMIDI
5. Call `logic_transport(play)` → verify playing state
6. Call `logic_transport(stop)` → verify stopped state
7. Call `logic_project(save_as, path: "/tmp/test-e2e.logicx", confirmed: true)` → verify file exists
8. Record all evidence in release docs
