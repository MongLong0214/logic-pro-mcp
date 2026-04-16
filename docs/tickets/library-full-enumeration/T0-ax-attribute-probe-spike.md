# T0: AX Passive-Attribute Probe Spike (OQ-4)

**PRD Ref**: PRD-library-full-enumeration > §12 OQ-4 (promoted)
**Priority**: P0 (Blocker — result determines T2-T4 design)
**Size**: S (< 2h)
**Status**: Todo
**Depends On**: None

---

## 1. Objective
Determine whether Logic Pro's AXBrowser exposes the entire Library tree via a passive AX attribute (`kAXColumnsAttribute`, `kAXVisibleColumnsAttribute`, `kAXRowsAttribute`, or any other). If yes, T2's recursive click-walker is **replaced** with a single AX-attribute read (scan time 15-300 s → < 1 s, eliminates Input Monitoring dependency, eliminates cycle/visited-set complexity). If no, T2 proceeds as PRD-designed.

## 2. Acceptance Criteria
- [ ] **AC-0.1**: `Scripts/library-ax-probe.swift` exists, compiles via `swift -O`, and runs against a live Logic Pro 12 instance with Library panel open.
- [ ] **AC-0.2**: Script dumps **every AX attribute** of the AXBrowser element and its children (up to 6 levels deep), with values coerced to String where possible. Output is plain text to stdout.
- [ ] **AC-0.3**: Script produces a `docs/spikes/T0-ax-probe-result.md` report with findings: list of attributes that return non-empty arrays of row/column/cell data, plus a recommendation (GO-PASSIVE / GO-CLICK-BASED).
- [ ] **AC-0.4**: If GO-PASSIVE, the report includes a 30-line Swift sketch showing how `enumerateTree()` would be reimplemented via the passive attribute. If GO-CLICK-BASED, a brief justification (no attribute exposes children of unclicked columns).
- [ ] **AC-0.5**: Spike conclusion committed as `docs/spikes/T0-ax-probe-result.md`.

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases
Spike tickets are exempt from TDD (exploratory). Output = a **report file**, not production code.

| # | Verification | Type | Description | Expected |
|---|--------------|------|-------------|----------|
| 1 | `Scripts/library-ax-probe.swift` exists | Manual | ls -la | File exists |
| 2 | `swift Scripts/library-ax-probe.swift` runs clean | Manual | run with Logic open | Exits 0, stdout non-empty |
| 3 | `docs/spikes/T0-ax-probe-result.md` committed | Manual | git status | Untracked or committed |

### 3.2 Test File Location
N/A — spike.

### 3.3 Mock/Setup Required
- Logic Pro 12 running with a project open, a track selected, Library panel visible (⌘L).

## 4. Implementation Guide

### 4.1 Files to Create
| File | Change Type | Description |
|------|------------|-------------|
| `Scripts/library-ax-probe.swift` | Create | 100-line Swift standalone script using `ApplicationServices` framework to traverse AX tree and dump attributes |
| `docs/spikes/T0-ax-probe-result.md` | Create | Findings + recommendation |

### 4.2 Implementation Steps
1. Copy `AXLogicProElements.mainWindow` + `findLibraryBrowser` inline into the spike script.
2. For the browser element, loop over `AXUIElementCopyAttributeNames` and `AXUIElementCopyAttributeValue` for each.
3. For any attribute whose value is an array of AXUIElement, recurse one level and dump children attributes.
4. Print in indented tree form to stdout.
5. Run with Library panel open. Read output.
6. Write `docs/spikes/T0-ax-probe-result.md` with GO-PASSIVE or GO-CLICK-BASED conclusion.

### 4.3 Refactor Phase
N/A — spike script is disposable (kept for future reference but not production).

## 5. Edge Cases
- EC-1: Library panel closed → probe returns empty, conclusion must note this.
- EC-2: Logic Pro not running → probe exits with clear error.

## 6. Review Checklist
- [ ] Script compiles and runs with Logic open
- [ ] Report written to `docs/spikes/T0-ax-probe-result.md`
- [ ] Decision (GO-PASSIVE vs GO-CLICK-BASED) is explicit
- [ ] T2 scope adjusted based on outcome (noted in STATUS.md)

## 7. Escalation Protocol (addresses guardian P2)

If **GO-PASSIVE**: Orchestrator opens Phase 3 re-loop, invalidates T2 v1 scope (Status → `Invalidated`), drafts T2 v2 reducing scope to "read passive attribute → build LibraryRoot in one pass". T3 (selectByPath) kept unchanged — still needs CGEvent click for actually loading presets. T7 impact: becomes trivially click-free. Strategist re-approves before T2 v2 implementation.

If **GO-CLICK-BASED**: No escalation; T1-T11 proceed as written. T0 result noted in STATUS.md Review History row.

If **partial** (some attributes reveal partial tree): Classify as GO-CLICK-BASED but record the discovered attribute in `docs/spikes/T0-ax-probe-result.md` as a **future optimization** (F-series follow-up, out of scope for this PRD).
