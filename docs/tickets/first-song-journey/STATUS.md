# Pipeline Status: First-Song Journey

**PRD**: docs/prd/PRD-first-song-journey.md
**Size**: XL
**Current Phase**: 4

## Tickets

| Ticket | Title | Priority | Size | Status | Depends | RC |
|--------|-------|----------|------|--------|---------|-----|
| T1 | CGEvent project.new + AX verify | P0 | M | Done | - | RC-1 |
| T2 | CGEvent save_as + AX dialog | P0 | L | Done | - | RC-1 |
| T3 | NSAppleScript in-process (save/close/probes) | P0 | M | Done | - | RC-2 |
| T4 | AX menu click create_instrument + verify | P0 | M | Done | - | RC-1,3 |
| T5 | project.open path normalization + AX verify | P0 | S | Done | T3 | RC-2,3 |
| T6 | Session state detection (hasVisibleWindow) | P1 | M | Done | - | RC-3 |
| T7 | State readback: expanded AX poll + invalidation | P1 | M | Done | T6 | RC-3 |
| T8 | E2E first-song journey validation | P0 | S | Todo | T1-T7 | All |

## Review History

| Phase | Round | Verdict | Notes |
|-------|-------|---------|-------|
| 2     | 1     | HAS ISSUE | Root cause corrected: 3 RCs, not 1 |
| 2     | 2     | ALL PASS | PRD v0.2 approved |
| 4     | 1     | - | Pending |
