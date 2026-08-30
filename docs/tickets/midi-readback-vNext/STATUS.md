# Pipeline Status: MIDI Read-Back vNext

**PRD**: `docs/prd/PRD-midi-readback-vNext.md`
**Status**: Gate harness added; live State-A proof failed in current launch context
**Execution rule (narrowed 2026-08-30)**: no ticket whose expected sequence must come from a
*dual-observation* source may start until one evidence gate proves a controlled selected-region
read-back path. **T4 is not such a ticket** — see "Two independence classes" below.

## Tickets

| Ticket | Title | Status | Gate |
|--------|-------|--------|------|
| T0 | Region drag-to-Finder export spike | Harness dry-run verified | Live controlled export evidence |
| T1 | Logic project/package event-reader spike | Todo | Saved scratch project note equality |
| T2 | Operator-assisted export contract | Todo | Explicit non-default profile decision + exact-path proof |
| T3 | `logic_midi.read_selection_notes` implementation | Blocked | T0 or T1 or T2 PASS |
| T4 | `record_sequence verify_notes` integration | Todo | a release-constructible `authoredIntent` proof; NOT T3 |

## Two independence classes, and why T4 is not behind T3

The PRD names two classes of independent expected `E`, and the code carries both:

```swift
enum IndependentExpectedRoot {
    case authoredIntent    // write-oracle: pre-authored write intent (import / record_sequence)
    case controlledExport  // dual-observation: a distinct Logic→notes surface
}
```

`O` is always the Event-List AX snapshot. T0/T1/T2 exist to supply `controlledExport` — a surface
DIFFERENT from `O` — because a comparison of `O` against `O` proves nothing.

T3 and T4 do not need the same class:

| ticket | where `E` comes from | needs |
|--------|----------------------|-------|
| T3 `read_selection_notes` | notes nobody just wrote — there is **no authored intent** | `controlledExport`, i.e. T0 or T1 or T2 |
| T4 `record_sequence verify_notes` | the notes the caller just asked for — **authored intent exists** | nothing further; it is already in hand |

`record_sequence` parses the caller's `notes` into `[SMFWriter.NoteEvent]` before it writes
anything. That value is fixed before the read and never re-encoded from observation, which is the
write-oracle definition verbatim.

**What blocks T4 is code, not evidence.** `IndependentExpectedSeam` sits inside
`#if QUALIFICATION_FAULT_SEAM`, so a release build's `independentPayload` is always nil. For
`authoredIntent`, R2's "live-ingestion boundary" is not a file route — it is a release-reachable
constructor plus the guards that already exist.

### The asymmetry that makes the write-oracle worth having

Suppose `SMFWriter` encodes note 60 as 61.

- **dual-observation** — Logic holds 61, the export says 61, `SMFReader` reads 61. They agree.
  **The bug is invisible.**
- **write-oracle** — expected is the authored 60, observed is 61. **Mismatch.**

A file route looks more independent because the artifact is visible. It is not more independent
against our own encoder, which is the component both the write and a `SMFReader`-based check share.

## Dependency Graph

```text
T0 ┐
T1 ├─> T3          (dual-observation)
T2 ┘

T4                 (write-oracle — independent of the three above)
```

## Evidence Gate

State A requires:

- registered controlled `.mid` path
- newly created file with positive size and fresh mtime
- `SMFReader.parse` success
- sentinel/requested notes equality
- selected-region or created-region identity captured
- no leftover Logic modal/menu

## Current Evidence

- `Scripts/spike-midi-region-drag-export.swift` refuses hazardous live mouse drag unless `LOGIC_PRO_MCP_ARM_REGION_DRAG=1` is set.
- Dry run verified on 2026-07-07: unarmed execution emits `record_type:"region_drag_preflight"`, `status:"blocked"` and exits `2`.
- Live rerun on 2026-07-07: `Scripts/spike-midi-export.py` initialized the MCP server and read `logic://tracks`, but `record_sequence` failed before sentinel import because this harness launch context cannot send Apple events to `System Events` (`-1743`). Export menu enumeration failed for the same reason, so no controlled `.mid` artifact was created.
- No live controlled `.mid` export evidence has been captured yet, so T3/T4 remain blocked.

## Verification

- Unit: Red tests named in each ticket; FAIL-verified before implementation; no dead-`#expect` forms (repo footgun #92).
- Integration: scratch-project spike scripts.
- Manual QA: live Logic 12.3 happy path plus deliberate failure path.
- Review: **cumulative review on every ticket completion (T(n-1)+T(n) diff + full `swift test --no-parallel`)**; full cumulative review before T3; final QA review before public docs/API claim.
- Safety: all spikes scratch-project-only; T0 drag additionally requires in-Logic rollback assertion (ticket AC) — never a user project.
