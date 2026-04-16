# PRD: record_sequence SMF-Import Redesign

**Version**: 0.3
**Author**: Claude (orchestrator) + Isaac (north star)
**Date**: 2026-04-17
**Status**: Draft
**Size**: XL

---

## 1. Problem Statement

### 1.1 Background
`logic_tracks.record_sequence` is a one-shot composition helper that selects a track, arms it, starts recording, plays a MIDI sequence in real-time via CoreMIDI, and stops. It was designed to let an LLM compose music on a Logic Pro track in a single tool call.

### 1.2 Problem Definition
The current implementation is structurally broken for multi-track composition:
1. **Timing jitter**: 200ms fixed sleep between "start recording" and "play sequence" doesn't account for Logic's variable record-arm latency (50-300ms+). First note lands at `bar + latency`, not `bar`.
2. **Multi-track drift**: Each call has independent latency, so tracks recorded separately drift relative to each other.
3. **Silent error swallowing**: 4 of 5 intermediate router calls discard their result with `_ = await router.route(...)`. A partial failure returns "success" (H-4 finding).
4. **No correctness verification**: No test asserts recorded region alignment, note count, or timing.

### 1.3 Impact of Not Solving
An LLM agent composing multi-track pieces via MCP produces audibly wrong results with no error signal. The user hears timing drift and missing notes but the tool reports success. This directly blocks Isaac's north star: "Logic Pro를 100% 자연어 프롬프트로 컨트롤."

## 2. Goals & Non-Goals

### 2.1 Goals
- [ ] G1: `record_sequence` produces note-perfect MIDI content at the exact specified bar position, with zero timing drift regardless of system load.
- [ ] G2: Multi-track composition (sequential `record_sequence` calls on different tracks) produces perfectly aligned content.
- [ ] G3: All intermediate errors propagate to the caller — no silent swallowing.
- [ ] G4: `arm_only` error propagation fixed (partial disarm failures visible).
- [ ] G5: Test coverage includes region-alignment assertions for recorded content.

### 2.2 Non-Goals
- NG1: Multi-track recording in a single call (parallel track writes). Out of scope — sequential calls are sufficient.
- NG2: Audio recording (WAV/AIFF). This is MIDI-only.
- NG3: Changing the `midi.play_sequence` real-time sequencer (kept as-is for live performance use cases).
- NG4: MIDI file parsing/reading (only generation).
- NG5: Exposing SMF generation as a standalone tool (internal implementation detail).

## 3. User Stories & Acceptance Criteria

### US-1: Note-perfect single-track recording
**As a** LLM agent, **I want** to record a MIDI sequence on a specific track at an exact bar position, **so that** the resulting region contains the correct notes at the correct timing.

**Acceptance Criteria:**
- [ ] AC-1.1: Given a track index, bar, and notes spec, when `record_sequence` is called, then a MIDI region appears on the target track starting at the specified bar with the exact notes.
- [ ] AC-1.2: Given notes `"60,0,480;64,480,480;67,960,480"` at bar 5 tempo 120, the region starts at 5.1.1.1 and contains C4-E4-G4 as quarter notes.
- [ ] AC-1.3: Given an invalid notes spec, the command returns an error before any side effects (no temp files left, no transport state changes).

### US-2: Multi-track alignment
**As a** LLM agent, **I want** to record sequences on multiple tracks sequentially, **so that** the tracks are perfectly aligned (zero drift).

**Acceptance Criteria:**
- [ ] AC-2.1: Given two `record_sequence` calls on tracks 0 and 1 at bar 1, the resulting regions start at the same position.
- [ ] AC-2.2: No timing depends on system load, sleep duration, or record-arm latency.

### US-3: Error propagation
**As a** LLM agent, **I want** to see the actual error when any step of `record_sequence` fails, **so that** I can diagnose and retry.

**Acceptance Criteria:**
- [ ] AC-3.1: If track selection fails, the error is returned immediately (no further steps attempted).
- [ ] AC-3.2: If MIDI file generation fails, the error includes the reason (e.g., invalid note spec).
- [ ] AC-3.3: If import fails, the error includes the channel and reason.
- [ ] AC-3.4: Temp files are cleaned up on both success and failure (via `defer`).

### US-4: arm_only error visibility
**As a** LLM agent, **I want** `arm_only` to report partial failures, **so that** I know if some tracks failed to disarm.

**Acceptance Criteria:**
- [ ] AC-4.1: If disarming track 2 fails but track 3 succeeds, the response includes both the failure and success.
- [ ] AC-4.2: The `armedSuccess` field reflects `armResult.isSuccess`; `armed` kept as track index for backward compat.

## 4. Technical Design

### 4.1 Architecture Overview

```
LLM → logic_tracks.record_sequence { index, bar, notes, tempo? }
        ↓
  TrackDispatcher.record_sequence (rewritten)
        ↓
  0. Guard: cache.getHasDocument() — return error if no project open
  1. Validate + parse notes spec → [NoteEvent]
  2. Get tempo/timeSig from StateCache (or params override)
  3. SMFWriter.generate(events, bar, tempo, timeSig) → Data
     - SMFWriter internally offsets all events by (bar-1) * ticksPerBar ticks
     - Tempo + time signature meta-events embedded
     - Caller passes raw ms-based events; all tick math lives in SMFWriter
  4. Write to /tmp/LogicProMCP/{uuid}.mid (defer cleanup)
  5. Select track (fail-fast on error)
  6. Import MIDI via midi.import_file route (AppleScript → AX fallback)
  7. Return result with track/bar/noteCount
```

### 4.2 New Module: SMFWriter

```swift
struct SMFWriter {
    struct NoteEvent {
        let pitch: UInt8       // 0-127
        let offsetTicks: Int   // from bar 1
        let durationTicks: Int // note length
        let velocity: UInt8    // 0-127
        let channel: UInt8     // 0-15
    }

    /// Generate a Type 0 Standard MIDI File.
    /// SMFWriter internally offsets all events by (bar - 1) * ticksPerBar
    /// so notes land at the correct absolute position in the MIDI file.
    /// Caller passes raw event offsets relative to the region start.
    static func generate(
        events: [NoteEvent],
        bar: Int,
        tempo: Double,
        timeSignature: (numerator: Int, denominator: Int),
        ticksPerQuarter: Int = 480
    ) throws -> Data

    /// Convert ms-based note spec to tick-based NoteEvents.
    /// Rounding: round-half-up to nearest tick.
    static func msToTicks(
        offsetMs: Int,
        durationMs: Int,
        tempo: Double,
        ticksPerQuarter: Int = 480
    ) -> (offsetTicks: Int, durationTicks: Int)
}
```

The SMF binary format:
- **Header**: `MThd` + length(6) + format(0) + ntrks(1) + division(480)
- **Track**: `MTrk` + length + events:
  - Tempo meta-event: `FF 51 03` + 24-bit microseconds-per-quarter
  - Time signature meta-event: `FF 58 04` + num + denomLog2 + clocksPerClick + 32ndsPerQuarter
  - Note-on/off events with delta-time in variable-length encoding
  - End-of-track: `FF 2F 00`

### 4.3 New Channel Handler: midi.import_file

This is a **new channel capability**, not just a routing table entry. Implementation required in both channels:

**AppleScriptChannel (primary):**
```swift
case "midi.import_file":
    guard let path = params["path"] else {
        return .error("midi.import_file requires 'path'")
    }
    // Use NSWorkspace.open (Launch Services) — same injection-safe path as project.open
    return AppleScriptSafety.openFile(at: path)
    // Post-import: verify the current project name hasn't changed
    // (if it changed, AppleScript opened a new project instead of importing)
```

**AccessibilityChannel (fallback):**
```swift
case "midi.import_file":
    guard let path = params["path"] else {
        return .error("midi.import_file requires 'path'")
    }
    // 1. Navigate menu: File → Import → MIDI File... (KR: 파일 → 가져오기 → MIDI 파일...)
    // 2. In open panel: Cmd+Shift+G → type path → Enter
    // 3. Select file → Enter/Import
    return importMIDIFileViaMenu(path: path, runtime: runtime.logicRuntime)
```

**Routing table addition:**
```swift
"midi.import_file": [.appleScript, .accessibility],
```

### 4.4 arm_only Fix

Current response:
```json
{"armed": INDEX, "disarmed": [...], "final": "..."}
```

New response (backward-compatible):
```json
{"armed": INDEX, "armedSuccess": true/false, "disarmed": [...], "failedDisarm": [...], "detail": "..."}
```

`armed` kept as int (track index) for backward compatibility with existing LLM agents. New fields: `armedSuccess` reflects `armResult.isSuccess`; `failedDisarm` lists track indices where disarm failed.

### 4.5 API Design

**Modified tool command** (same name, enhanced params):

| Command | Params | Returns | Channel |
|---------|--------|---------|---------|
| `record_sequence` | `{ index: Int, bar?: Int, notes: String, tempo?: Double }` | `{ recorded_to_track: Int, bar: Int, note_count: Int, method: "smf_import" }` | Internal (SMFWriter + midi.import_file) |

Notes format unchanged: `"pitch,offsetMs,durMs[,vel[,ch]];..."`

Response field `recorded_to_track` kept for backward compatibility (renamed from internal to match existing schema).

### 4.6 Key Technical Decisions

| Decision | Options Considered | Chosen | Rationale |
|----------|-------------------|--------|-----------|
| SMF Type | Type 0 (single track) vs Type 1 (multi-track) | Type 0 | One track per call; simplest format |
| Ticks per quarter | 96 / 240 / 480 / 960 | 480 | Industry standard, sufficient resolution |
| Import path | AppleScript open / AX menu + file dialog / Clipboard paste | AppleScript primary (NSWorkspace.open), AX menu fallback | Code-first per north star |
| Position control | Playhead-based vs embedded in MIDI | **Embedded**: SMFWriter offsets all events by `(bar-1) * ticksPerBar` ticks | Logic imports at file position, not playhead |
| Ms-to-tick rounding | Floor / round / ceil | Round half-up (`Int((ms * tempo * tpq) / 60000.0 + 0.5)`) | Minimizes sub-tick error |
| Temp file location | /tmp vs project dir vs in-memory | /tmp/LogicProMCP/ | No project pollution, auto-cleanup on reboot |
| Error handling | Silent swallow vs fail-fast chain | Fail-fast: each step returns error immediately | Fixes H-4 |
| Old real-time path | Remove vs keep as fallback | Remove | Old path is fundamentally broken; keeping it invites regression |
| Path injection | String interpolation vs Launch Services | Launch Services (NSWorkspace.open) | Same safe path as project.open |

## 5. Edge Cases & Error Handling

| # | Scenario | Expected Behavior | Severity |
|---|----------|-------------------|----------|
| E1 | Empty notes string | Return error before any state changes | P0 |
| E2 | Invalid note in sequence (pitch > 127) | Return error with specific invalid note | P0 |
| E3 | No project open (hasDocument = false) | Return error "No project open" — checked as step 0 | P1 |
| E4 | Track index out of range | Return error "Track {n} not found" | P1 |
| E5 | Tempo not in cache and not provided | Use default 120 BPM with warning in response | P2 |
| E6 | Import fails (both channels exhausted) | Return channel error, cleanup temp file via defer | P1 |
| E7 | Logic Pro not running | Return error from channel health check | P1 |
| E8 | Temp dir write fails (permissions) | Return error with path | P1 |
| E9 | Notes with overlapping pitches on same channel | Valid — MIDI allows overlapping notes | N/A |
| E10 | Very long sequence (>256 notes) | Accept up to 1024 notes for SMF (vs 256 for real-time) | P2 |
| E11 | AppleScript opens .mid as new project | Detect via project name change; return error with guidance | P1 |
| E12 | Process crash during import | Orphan .mid in /tmp/LogicProMCP/ — startup sweep cleans up | P3 |

## 6. Security & Permissions

### 6.1 Authentication
N/A — local process, no network.

### 6.2 Authorization
Uses existing macOS permissions: Accessibility (AX channel) and Automation (AppleScript).

### 6.3 Data Protection
- Temp .mid files written to `/tmp/LogicProMCP/` with restrictive permissions (0600)
- Files deleted immediately after import (or on error) via `defer`
- `midi.import_file` uses Launch Services (NSWorkspace.open), NOT string interpolation — same injection-safe path as `project.open`
- Startup sweep: server init deletes any .mid files in `/tmp/LogicProMCP/` older than 5 minutes (orphan cleanup)
- No user data leaves the machine

## 7. Performance & Monitoring

| Metric | Target | Measurement |
|--------|--------|-------------|
| SMF generation time | < 10ms for 256 notes | Unit test benchmark |
| Import latency (end-to-end) | < 3s including dialog | Live E2E test |
| Temp file cleanup | 100% within process lifetime | Test assertion |

### 7.1 Monitoring & Alerting
- Log.info on SMF generation with note count and file size
- Log.warn on import fallback (AppleScript → AX)
- Log.error on temp file cleanup failure

## 8. Testing Strategy

### 8.1 Unit Tests
- SMFWriter: binary output matches expected SMF bytes for known inputs
- SMFWriter: tempo/time-signature meta-events encoded correctly
- SMFWriter: ms-to-tick conversion with round-half-up (including irrational tick values)
- SMFWriter: bar-offset embedding (events at bar 5 = offset by 4 bars of ticks)
- SMFWriter: handles edge cases (empty, single note, 1024 notes, chords)
- TrackDispatcher: error propagation chain (mock router returns errors at each step)
- TrackDispatcher: hasDocument guard (step 0)
- arm_only: partial disarm failure visibility (`armed` reflects actual result, `failedDisarm` populated)

### 8.2 Integration Tests
- record_sequence dispatches SMF generation + import via mock channels
- Temp file created and cleaned up (success path)
- Temp file cleaned up on error (failure path)
- Full error chain from each failure point (select, arm, import)

### 8.3 Edge Case Tests
- All E1-E12 scenarios from Section 5

## 9. Rollout Plan

### 9.1 Migration Strategy
- record_sequence API is backward-compatible (same params, `recorded_to_track` field preserved)
- Old real-time recording path removed entirely
- No database or schema changes
- `arm_only` response schema changes: `armed` becomes boolean, `failedDisarm` added

### 9.2 Feature Flag
None — direct replacement.

### 9.3 Rollback Plan
Git revert of the commit. The old real-time path is preserved in git history.

## 10. Dependencies & Risks

### 10.1 Dependencies
| Dependency | Owner | Status | Risk if Delayed |
|-----------|-------|--------|-----------------|
| transport.goto_position (AX) | navigate-redesign T1 | Done | N/A |
| NSWorkspace.open for .mid files | Apple/macOS | Built-in | Low |
| AX File menu navigation | Apple/Logic Pro | Built-in | Medium (locale-dependent) |

### 10.2 Risks
| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| Logic Pro opens .mid as new project instead of importing | Medium | High | Detect via project name change; E11 handling |
| AX file dialog navigation fragile across LP versions | Medium | Medium | Cmd+Shift+G path entry; bilingual menu search |
| SMF format edge cases (running status, etc.) | Low | Medium | Comprehensive binary-level unit tests |
| Logic Pro changes "Import MIDI File" menu path | Low | Low | Bilingual keyword search (KR/EN) |

## 11. Success Metrics

| Metric | Baseline | Target | Measurement Method |
|--------|----------|--------|--------------------|
| Timing accuracy | ±300ms (real-time) | ±0ms (file-based) | Live E2E with region inspection |
| Multi-track alignment | Drift per track | Zero drift | Sequential record + compare |
| Error visibility | 1/5 errors reported | 5/5 errors reported | Unit test assertions |
| Test coverage | 0 correctness tests | 100% AC coverage | Test count |

## 12. Open Questions

- [ ] OQ-1: Does `NSWorkspace.open` with a .mid file import into current Logic Pro project or create new? **BLOCKING** — must probe before implementation. Determines whether AppleScript primary path is viable.
- [ ] OQ-2: What is the exact AX menu path for File → Import → MIDI File in Logic Pro 12 (KR locale)? → Probe during implementation.
- [ ] OQ-3: Should the note spec format change (ms-based → tick-based)? → Keep ms-based for LLM ergonomics; convert internally.
