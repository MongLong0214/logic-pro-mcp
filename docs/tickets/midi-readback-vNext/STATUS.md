# Pipeline Status: MIDI Read-Back vNext

**PRD**: `docs/prd/PRD-midi-readback-vNext.md`
**Status**: T0 harness ready; live evidence gate pending
**Execution rule**: no implementation ticket may start until one evidence gate proves a controlled selected-region read-back path.

## Tickets

| Ticket | Title | Status | Gate |
|--------|-------|--------|------|
| T0 | Region drag-to-Finder export spike | Harness ready | Live controlled export evidence |
| T1 | Logic project/package event-reader spike | Todo | Saved scratch project note equality |
| T2 | Operator-assisted export contract | Todo | Explicit non-default profile decision + exact-path proof |
| T3 | `logic_midi.read_selection_notes` implementation | Blocked | T0 or T1 or T2 PASS |
| T4 | `record_sequence verify_notes` integration | Blocked | T3 PASS |

## Dependency Graph

```text
T0 ┐
T1 ├─> T3 -> T4
T2 ┘
```

## Evidence Gate

State A requires:

- registered controlled `.mid` path
- newly created file with positive size and fresh mtime
- `SMFReader.parse` success
- sentinel/requested notes equality
- selected-region or created-region identity captured
- no leftover Logic modal/menu

## Verification

- Unit: Red tests named in each ticket; FAIL-verified before implementation; no dead-`#expect` forms (repo footgun #92).
- Integration: scratch-project spike scripts.
- Manual QA: live Logic 12.3 happy path plus deliberate failure path.
- Review: **cumulative review on every ticket completion (T(n-1)+T(n) diff + full `swift test --no-parallel`)**; full cumulative review before T3; final QA review before public docs/API claim.
- Safety: all spikes scratch-project-only; T0 drag additionally requires in-Logic rollback assertion (ticket AC) — never a user project.
