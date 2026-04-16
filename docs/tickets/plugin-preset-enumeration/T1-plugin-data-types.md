# T1: Plugin Preset Data Types

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > §4.2 Data Model
**Priority**: P0
**Size**: S
**Status**: Todo
**Depends On**: None (parallel to T0)

---

## 1. Objective
Introduce all Codable/Sendable types required by subsequent tickets: `PluginPresetNodeKind`, `PluginPresetNode`, `PluginPresetCache`, `PluginPresetInventory`, `MenuHop`, `PluginMenuItemInfo`, `PluginPresetProbe`, `PluginWindowRuntime`, `AXUIElementSendable`, `ScannerWindowRecord`. All types in one new file `Sources/LogicProMCP/Accessibility/PluginInspector.swift` (marker-only; actual logic in T2+).

## 2. Acceptance Criteria
- [ ] **AC-1**: `PluginPresetNodeKind` enum has 7 cases: `folder, leaf, separator, action, truncated, probeTimeout, cycle`. All `Codable`, `Sendable`, `Equatable`.
- [ ] **AC-2**: `PluginPresetNode` struct: `name, path, kind, children`. No screen coordinates.
- [ ] **AC-3**: `PluginPresetCache` struct has all 13 fields per PRD §4.2 including `schemaVersion: Int = 1`, `contentHash: String`, `cycleCount: Int`.
- [ ] **AC-4**: `PluginPresetInventory` struct: `schemaVersion`, `generatedAt`, `plugins: [String: PluginPresetCache]`. Round-trip decodes.
- [ ] **AC-5**: `AXUIElementSendable` is `public final class @unchecked Sendable` holding `let element: AXUIElement`; rationale comment explains actor-scoped safety.
- [ ] **AC-6**: `ScannerWindowRecord` struct: `cgWindowID: CGWindowID` (primary), `bundleID, windowTitle, element: AXUIElementSendable`.
- [ ] **AC-7**: `PluginPresetProbe` struct with 6 closures: `menuItemsAt, pressMenuItem, focusOK, mutationSinceLastCheck, sleep, visitedHash`. `PluginWindowRuntime` struct with the **canonical 6 closures** (`findWindow, openWindow, closeWindow, listOpenWindows, identifyPlugin, nowMs`). **Forward-declared extension closures for T4/T5/T6** (stub with `let ... ` placeholders; optional in T1, mandatory once T4/T5/T6 land): `audioComponentVersion: @Sendable (String) async -> UInt32?` (T4), `cgWindowList: @Sendable () async -> [[String: Any]]` (T5), `readInventory: @Sendable (URL) throws -> Data` + `writeInventory: @Sendable (Data, URL) throws -> Void` (T6), and `productionMouseClickDelegate: @Sendable (CGPoint) async -> Bool` (conditional on T0 CGEvent outcome).
- [ ] **AC-8**: All types compile. `swift build` green. `swift test` green (no new tests yet).

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases (Tests/LogicProMCPTests/PluginInspectorTypesTests.swift)

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testPluginPresetNodeKindRoundTrip` | Unit | Encode each enum case, decode, assert equality | All 7 cases survive round-trip |
| 2 | `testPluginPresetNodeCodable` | Unit | 3-level tree encode+decode | Decoded tree equals original |
| 3 | `testPluginPresetCacheCodable` | Unit | Full cache with all 13 fields | Round-trip equal |
| 4 | `testPluginPresetInventoryCodable` | Unit | Inventory wrapping 2 cache entries | Round-trip equal |
| 5 | `testSchemaVersionMismatchRejected` | Unit | Decode inventory JSON with `schemaVersion: 99` | Decoder throws or empty-cache fallback per AC-2.10 |
| 6 | `testAXUIElementSendableWraps` | Unit | Wrap a dummy AXUIElement; retrieve; identity preserved | `wrapper.element === original` |
| 7 | `testScannerWindowRecordFields` | Unit | Construct with CGWindowID + bundleID + windowTitle | Fields accessible |
| 8 | `testPluginPresetProbeClosures` | Unit | Inject stub closures; call each | Each closure invoked |
| 9 | `testPluginWindowRuntimeNowMsMonotonic` | Unit | Call `nowMs()` twice with 1ms interval | Second ≥ first |

### 3.2 Test File Location
`Tests/LogicProMCPTests/PluginInspectorTypesTests.swift` — new file.

### 3.3 Mock/Setup
- Use Swift Testing (`@Test`, `#expect`).
- `AXUIElement` stub via `AXUIElementCreateSystemWide()` is safe (returns process element).

## 4. Implementation Guide

### 4.1 Files to Create
| File | Type | Description |
|------|------|-------------|
| `Sources/LogicProMCP/Accessibility/PluginInspector.swift` | Create | Types only in this ticket; methods stubbed with `fatalError` in T2+ |
| `Tests/LogicProMCPTests/PluginInspectorTypesTests.swift` | Create | 9 Codable/type tests |

### 4.2 Implementation Steps (Green)
1. Copy type definitions from PRD §4.2 verbatim
2. Add `AXUIElementSendable` concrete class
3. Add `ScannerWindowRecord` with `CGWindowID` import
4. Declare all probe/runtime struct types with closure fields
5. Add `CoreGraphics` import for `CGWindowID`
6. Run `swift build` until green
7. Run `swift test` — all 9 tests PASS

### 4.3 Refactor
- If any type needs a computed property or convenience init, add now
- Add `public` modifiers on all types + fields

## 5. Edge Cases
- EC-1: Unicode preset names in `PluginPresetNode.name` — UTF-8 JSON round-trip verified in test 2.
- EC-2: Empty tree (`children: []`) — verified in tests.

## 6. Review Checklist
- [ ] Red: 9 tests FAIL before impl
- [ ] Green: 9 tests PASS
- [ ] Refactor: tests PASS
- [ ] `swift build` green; no warnings
- [ ] No existing tests broken (`swift test` all-green baseline + 9)
