# T12: Integration Tests Bundle — AccessibilityChannel Plugin Handlers

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > §8.2, AC-6.1 (100% branch on new handlers)
**Priority**: P1
**Size**: L
**Status**: Todo
**Depends On**: T6, T7, T8, T9, T10

---

## 1. Objective
Consolidate integration tests across T6-T9 handlers + fill branch coverage gaps to reach 100% on new `plugin.*` handler branches. Total target: ~33 integration tests per PRD §8.2.

## 2. Acceptance Criteria
- [ ] **AC-1**: 100% branch coverage on all new `case "plugin.*":` handler branches in `AccessibilityChannel.swift`.
- [ ] **AC-2**: Concurrency stress test — library scan + plugin scan_presets concurrent; `plugin.resolve_preset_path` during active scan < 100 ms.
- [ ] **AC-3**: Cache persistence integration test — channel init with (a) valid inventory file, (b) version-mismatch file, (c) corrupt JSON file (AC-2.10).
- [ ] **AC-4**: AC-6.4 verification — `TrackDispatcher.toolDescription` parseable JSON listing 4 commands.
- [ ] **AC-5**: ~~`.gitignore` grep test~~ **MOVED TO T14** (dep-order fix: T12 runs before T14's physical edit; gitignore verification co-located with the change).
- [ ] **AC-6**: T11/T12 scope discipline — this ticket's gap-fill tests MUST NOT repeat scenarios already asserted by T6/T7/T8/T9/T10 ACs. Verified by cross-check at review time.
- [ ] **AC-7** (from original AC-6): Post-batch no lingering scanner-opened windows (ledger assertion — T7 primary owner; T12 cross-checks at channel integration level).

## 3. TDD Spec

### 3.1 Test files consolidated
- `AccessibilityChannelScanPluginPresetsTests.swift` (T6)
- `AccessibilityChannelScanAllInstrumentsTests.swift` (T7)
- `AccessibilityChannelSetPluginPresetTests.swift` (T8)
- `AccessibilityChannelResolvePresetPathTests.swift` (T9)
- `TrackDispatcherPluginCommandsTests.swift` (T10)
- `AccessibilityChannelPluginBranchCoverageTests.swift` (T12 — gap-fill)
- `PluginToolDescriptionTests.swift` (T12 — AC-6.4 validation)
- `GitignorePluginInventoryTests.swift` (T12 — AC-6.4 rollout grep)

### 3.2 New gap-fill tests (T12-specific — NO duplication of T6/T7 scenarios)
| # | Test | Target branch |
|---|------|--------------|
| 1 | `testResolvePathDuringActiveScanAccessesNoFlag` | AC-1.9 exempt — SPY-based: wrap `axScanInProgress` access in observable closure; assert zero accesses during `resolvePluginPresetPath` (deterministic, NOT wall-clock) |
| 2 | `testToolDescriptionIsValidJSONSchema` | AC-6.4 dispatcher doc parseable |
| 3 | `testNonAXHandlerRunsDuringScan` | AC-1.8 — invoke `getTrackCount` while scanPluginPresets is mid-sleep in a detached Task; assert getTrackCount returns within 100ms |
| 4 | `testBackToBackScansDeterministic` | AC-1.3 — two sequential scans with identical probe state; decode both, strip volatile fields, `#expect` structural equality on name/path/kind/sibling-order/dup-suffixes |
| 5 | `testScanDurationWithinG8EnvelopeAtDefault` | AC-1.6 — mocked probe with 300ms per-submenu sleep + representative leaf count; assert `scanDurationMs` ≤ target when `measuredSubmenuOpenDelayMs ≤ 400ms` (G8 CI methodology) |
| 6 | `testLockErrorTextConsistent` | AC-1.9 lock-text contract — concurrent call returns text matching `"<operation>: AX scan already in progress"` (NOT library's legacy text) |

## 4. Implementation Guide

### 4.1 Files to Modify/Create
| File | Type | Description |
|------|------|-------------|
| `Tests/LogicProMCPTests/AccessibilityChannelPluginBranchCoverageTests.swift` | Create | Branch gap-fill |
| `Tests/LogicProMCPTests/PluginToolDescriptionTests.swift` | Create | AC-6.4 |
| `Tests/LogicProMCPTests/GitignorePluginInventoryTests.swift` | Create | AC-6.4 grep |

### 4.2 Coverage Command
Same as T11 but filter for `AccessibilityChannel.*plugin` branches.

### 4.3 Implementation Steps
1. Run initial coverage on AccessibilityChannel's plugin branches
2. Identify uncovered branches
3. Write targeted gap-fill tests
4. Add AC-6.4 rollout verification tests

## 5. Edge Cases
- EC-1: tool description could change encoding between Swift versions — use MCP protocol decoder to verify

## 6. Review Checklist
- [ ] 100% branch on new plugin handlers
- [ ] ~33 total plugin integration tests
- [ ] AC-6.4 grep tests green
