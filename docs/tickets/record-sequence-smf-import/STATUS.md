# Pipeline Status: record_sequence SMF-Import Redesign

**PRD**: docs/prd/PRD-record-sequence-smf-import.md (v0.4)
**Size**: XL
**Current Phase**: 7 (Done) — shipped in v2.3.0
**Live-verified**: 2026-04-18 on Logic Pro 12.0.1

## Tickets

| Ticket | Title | Status | Notes |
|--------|-------|--------|-------|
| T1 | SMFWriter — Type 0 MIDI file generator | Done | 13 unit tests (incl. Strategy D padding assertions) |
| T2 | arm_only error propagation fix | Done | 2 unit tests |
| T3 | record_sequence fail-fast error chain | Done | 2 unit tests (hasDocument guard + import error) |
| T4 | midi.import_file AppleScript handler | Abandoned | OQ-1 live probe: `NSWorkspace.open(.mid)` creates a new project |
| T5 | midi.import_file AX menu import | Done | osascript-driven full flow; dismisses 템포 dialog |
| T6 | record_sequence SMF-import rewrite | Done | 5 unit tests; old real-time path removed |
| T7 | Orphan .mid cleanup on startup | Done | 2 unit tests |

## Strategy D — why the final design looks this way

Logic Pro 12's MIDI File import silently strips any leading empty delta
time before the first MIDI channel event. A naive SMF with `note-on @
tick 17280` (bar 10) gets flattened to bar 1. The `bar` parameter would
be silently ignored.

**Solution**: `SMFWriter` emits a harmless `CC#110 value 0` on channel 0
at tick 0 whenever `bar > 1`. CC#110 is an undefined MIDI CC with no
documented side effect on standard instruments. Logic recognises it as
a real channel event and therefore preserves the full tick timeline.

**Result** (verified 2026-04-18):

| Request | Logic's AX Help (raw) |
|---------|-----------------------|
| `bar=1` | `리전은 1 마디에서 시작하여 2 마디에서 끝납니다` (quarter note only) |
| `bar=10` | `리전은 1 마디에서 시작하여 11 마디에서 끝납니다` |
| `bar=50` | `리전은 1 마디에서 시작하여 51 마디에서 끝납니다` |

Region spans bar 1 → `bar + 1`; the caller's notes sit at the trailing
edge at the requested bar with byte-exact timing.

## OQ Resolutions (live probe, 2026-04-18)

| Question | Resolution |
|----------|-----------|
| OQ-1: Does `NSWorkspace.open(.mid)` import or create new? | Creates NEW project (`무제 N` → `무제 N+1`). AppleScript primary path abandoned. |
| OQ-2: AX menu path for Import MIDI File (KR locale)? | `파일 → 가져오기 → MIDI 파일…` → `/` for path sheet → type path → Enter → `가져오기` button → `아니요` on tempo dialog. |
| OQ-3: Does Logic import into the selected track? | NO — always creates a new MIDI track. `index` parameter becomes informational; actual track is returned as `created_track`. |
| OQ-4 (emergent): Does Logic honour absolute ticks in the SMF? | NO — strips leading empty delta. Workaround: Strategy D padding CC. |

## Review History

| Phase | Round | Verdict | P0 | P1 | P2 | Notes |
|-------|-------|---------|----|----|-----|-------|
| 2     | 1     | RECONSIDER | 2 | 3 | 3 | OQ-1 blocking, midi.import_file unimplemented |
| 2     | 2     | PROCEED_WITH_CAUTION | 0 | 1 | 1 | N1 bar offset, N2 arm_only compat |
| 2     | 3     | PROCEED | 0 | 0 | 0 | PRD v0.3 addresses all findings |
| 6     | 1     | PROCEED_WITH_CAUTION | 0 | 0 | 1 | createdTrack fallback bug |
| 6     | 2     | PROCEED | 0 | 0 | 0 | Convergence |
| 6     | 3 (Strategy D) | PROCEED | 0 | 0 | 0 | Live verification confirms behavior |

## Test Count

- Before sprint: 668
- After T1-T3: 683 (+15)
- After T5-T7: 688 (+5)
- After Strategy D + live verification: 690 (+2)

## Shipped As

**v2.3.0** (2026-04-18). See `CHANGELOG.md` v2.3.0 entry.
