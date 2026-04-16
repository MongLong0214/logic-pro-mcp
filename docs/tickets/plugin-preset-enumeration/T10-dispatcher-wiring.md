# T10: TrackDispatcher MCP Command Wiring

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > §4.1 canonical table, §4.3 API, AC-6.4
**Priority**: P0
**Size**: S
**Status**: Todo
**Depends On**: T6, T7, T8, T9

---

## 1. Objective
Wire the 4 new MCP tool commands into `TrackDispatcher.swift`. Each command → router operation per §4.1 canonical table. Update tool description to list all 4 with param schemas (AC-6.4).

## 2. Acceptance Criteria
- [ ] **AC-1**: MCP command `scan_plugin_presets` dispatches to router op `plugin.scan_presets` with params `{ trackIndex?: Int, submenuOpenDelayMs?: Int }`.
- [ ] **AC-2**: `scan_all_instruments` → `plugin.scan_all_instruments` with params `{ onlyTracks?: [Int], skipAlreadyCached?: Bool, submenuOpenDelayMs?: Int }`.
- [ ] **AC-3**: `set_plugin_preset` → `plugin.set_preset` with params `{ trackIndex: Int, path: String }`.
- [ ] **AC-4**: `resolve_preset_path` → `plugin.resolve_preset_path` with params `{ trackIndex: Int, path: String }`.
- [ ] **AC-5**: `TrackDispatcher.tool.description` includes all 4 new commands' names + param schemas.
- [ ] **AC-6**: Unknown command name → structured error `"Unknown command: <name>"` (existing pattern).

## 3. TDD Spec

### 3.1 Tests (Tests/LogicProMCPTests/TrackDispatcherPluginCommandsTests.swift)

| # | Test | Description |
|---|------|-------------|
| 1 | `testScanPluginPresetsDispatches` | Input `"scan_plugin_presets"` → router called with `"plugin.scan_presets"` |
| 2 | `testScanAllInstrumentsDispatches` | `"scan_all_instruments"` → `"plugin.scan_all_instruments"` |
| 3 | `testSetPluginPresetDispatches` | `"set_plugin_preset"` → `"plugin.set_preset"` |
| 4 | `testResolvePresetPathDispatches` | `"resolve_preset_path"` → `"plugin.resolve_preset_path"` |
| 5 | `testUnknownCommandError` | Unknown name → error |
| 6 | `testToolDescriptionListsAllFour` | `tool.description` contains all 4 command names |
| 7 | `testSetPluginPresetMissingTrackIndexError` | Missing required param → error |
| 8 | `testSetPluginPresetMissingPathError` | Missing path → error |

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Type | Description |
|------|------|-------------|
| `Sources/LogicProMCP/Dispatchers/TrackDispatcher.swift` | Modify | Add 4 `case` branches; extend `toolDescription` |
| `Sources/LogicProMCP/Channels/ChannelRouter.swift` | Modify | Add `plugin.*` route entries (they are placeholders today) |
| `Tests/LogicProMCPTests/TrackDispatcherPluginCommandsTests.swift` | Create | 8 tests |

### 4.2 Implementation Steps
1. In `TrackDispatcher` switch-on-command, add 4 cases
2. Extract params from CallToolParameters JSON
3. Call `router.route(operation:, arguments:)`
4. Extend tool description schema
5. Ensure ChannelRouter routes `plugin.*` to `.accessibility` channel

### 4.3 Refactor
- Shared param-extract helpers for `trackIndex`, `path`

## 5. Edge Cases
- EC-1: `trackIndex` is negative → pass through; handler (T6-T9) returns error
- EC-2: `path` is empty string → pass through (handlers accept per AC-4.4)

## 6. Review Checklist
- [ ] Red: 8 tests FAIL
- [ ] Green: 8 tests PASS
- [ ] Existing dispatcher tests unaffected
- [ ] `swift build` green; tool description parses as valid JSON schema
