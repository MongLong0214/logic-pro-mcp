# Pipeline Status: record_sequence SMF-Import Redesign

**PRD**: docs/prd/PRD-record-sequence-smf-import.md (v0.4)
**Size**: XL
**Current Phase**: 7 (Done — pending live verification)

## Tickets

| Ticket | Title | Size | Status | Review | Notes |
|--------|-------|------|--------|--------|-------|
| T1 | SMFWriter — Type 0 MIDI file generator | M | Done | PASS | 11 unit tests |
| T2 | arm_only error propagation fix | S | Done | PASS | 2 unit tests |
| T3 | record_sequence fail-fast error chain | S | Done | PASS | 2 unit tests (pre-rewrite) |
| T4 | midi.import_file AppleScript handler | — | Abandoned | — | OQ-1 live probe: creates new project. Path removed. |
| T5 | midi.import_file AX menu import | L | Done | PASS | osascript-based AX sequence |
| T6 | record_sequence SMF-import rewrite | M | Done | PASS | 5 unit tests; old real-time path removed |
| T7 | Orphan .mid cleanup on startup | S | Done | PASS | 2 unit tests |

## Live Probes (2026-04-18)

- **OQ-1 Resolved**: `open -a "Logic Pro" x.mid` creates a NEW project (무제 N → 무제 N+1). AppleScript primary path abandoned.
- **OQ-2 Resolved**: AX menu path `파일 → 가져오기 → MIDI 파일…` works. Full sequence: menu click → `/` keystroke opens path sheet → type path → Enter → click `가져오기` button in splitter group → dismiss tempo dialog with `아니요` button.
- **OQ-3 Resolved**: Logic always creates a NEW MIDI track on import regardless of selection. `index` parameter semantics changed to "informational only"; actual track reported as `created_track` in response.

## Review History

| Phase | Round | Verdict | P0 | P1 | P2 | P3 | Notes |
|-------|-------|---------|----|----|-----|-----|-------|
| 2     | 1     | RECONSIDER | 2 | 3 | 3 | — | OQ-1 blocking, midi.import_file unimplemented |
| 2     | 2     | PROCEED_WITH_CAUTION | 0 | 1 | 1 | — | Bar offset, arm_only compat |
| 2     | 3     | PRD v0.3 fixed | 0 | 0 | 0 | — | |
| 6     | 1     | PROCEED_WITH_CAUTION | 0 | 0 | 1 | 2 | createdTrack fallback bug |
| 6     | 2     | PROCEED | 0 | 0 | 0 | 0 | Convergence |

## Test Count

- Before sprint: 668
- After T1-T3: 683 (+15)
- After T5-T7: 688 (+5)
- Ralph loop: 688 (fixes only, no new tests)

## Pending Live Verification

The running MCP server process uses the old binary. Live T5 verification requires:
1. Isaac restarts Claude Code (or the MCP server)
2. New `/Users/isaac/bin/LogicProMCP` binary (deployed 2026-04-18) is picked up
3. Test: `logic_tracks record_sequence { notes: "60,0,480", tempo: 120 }` should import a C4 quarter note to a new track
