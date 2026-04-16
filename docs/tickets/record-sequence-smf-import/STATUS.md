# Pipeline Status: record_sequence SMF-Import Redesign

**PRD**: docs/prd/PRD-record-sequence-smf-import.md
**Size**: XL
**Current Phase**: 5 (TDD Implementation — partially blocked)

## Tickets

| Ticket | Title | Size | Status | Review | Depends | Notes |
|--------|-------|------|--------|--------|---------|-------|
| T1 | SMFWriter — Type 0 MIDI file generator | M | Done | PASS | None | 11 unit tests |
| T2 | arm_only error propagation fix | S | Done | PASS | None | 2 unit tests |
| T3 | record_sequence fail-fast error chain | S | Done | PASS | None | 2 unit tests |
| T4 | midi.import_file AppleScript handler | M | Partial | - | OQ-1 | Routing + handler added, needs live probe |
| T5 | midi.import_file AX menu fallback | L | Blocked | - | T4, OQ-2 | Stub only |
| T6 | record_sequence SMF-import rewrite | M | Blocked | - | T1, T3, T4 | Needs T4 complete |
| T7 | Orphan .mid cleanup on startup | S | Blocked | - | T6 | |

## Blocking Items

- **OQ-1**: Does NSWorkspace.open with .mid file import into existing LP project or create new?
  - Must probe on live Logic Pro before T4 can complete
  - Determines whether AppleScript primary path is viable
- **OQ-2**: Exact AX menu path for File → Import → MIDI File in Logic Pro 12 (KR locale)
  - Needed for T5 AX fallback implementation

## Review History

| Phase | Round | Verdict | P0 | P1 | P2 | Notes |
|-------|-------|---------|----|----|-----|-------|
| 2     | 1     | RECONSIDER | 2 | 3 | 3 | P0-1, P0-2, P1-1 critical |
| 2     | 2     | PROCEED_WITH_CAUTION | 0 | 1 | 1 | N1 bar offset, N2 arm_only compat |
| 2     | 3     | PRD fixed v0.3 | 0 | 0 | 0 | All addressed |

## Test Count

- Before: 668
- After T1-T3: 683 (+15 tests)
- After T4 partial: 683 (no new tests for routing-only change)
