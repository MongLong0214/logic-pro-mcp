# T4: Plugin Identity — findPluginWindow + identifyPlugin + findSettingDropdown

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > §4.1 PluginInspector, AC-5.3, AC-3.0, E4b, E26, §4.4 "Plugin window identity" + "Cache version source"
**Priority**: P0
**Size**: M
**Status**: Todo
**Depends On**: T1, T0 (needs AX format findings)

---

## 1. Objective
Implement 3 inspector methods: (a) `findPluginWindow(for trackIndex: Int, in app: AXUIElement) async -> AXUIElementSendable?`, (b) `identifyPlugin(in window: AXUIElementSendable) async -> (name: String, bundleID: String, version: String?)?`, (c) `findSettingDropdown(in window: AXUIElementSendable) async -> AXUIElementSendable?`. Identity uses AU bundle ID first (locale-invariant), AXDescription fallback only if bundle ID unavailable.

## 2. Acceptance Criteria
- [ ] **AC-1** (AC-5.3): `identifyPlugin` returns bundle ID via `AXIdentifier` AX attribute or AU registry lookup of the window's AU. Prefers bundle ID over AXDescription (which localizes).
- [ ] **AC-2** (§4.4 Cache version source): Version via `AudioComponentGetVersion(audioComponent, &version)` — a **free function** (NOT `AUPlugInGetVersionNumber` which requires an instance). Returns `UInt32` packed as `0xMMMMmmbb`; decoded to `"M.m.b"` string.
- [ ] **AC-3** (E4b): `findSettingDropdown` locates by `AXRole == "AXMenuButton"` + geometric region (top of plugin-window header), NOT by localized description.
- [ ] **AC-4** (E26): Multiple plugin windows for same track — `findPluginWindow` returns first window whose bundle ID matches the track's instrument slot AND has a Setting dropdown.
- [ ] **AC-5**: If no matching window found, returns nil (not an error — caller decides).
- [ ] **AC-6** (per PRD E31 + §4.4 Cache validity — Ralph Round 5 resolved): If AU registry lookup fails, prefer `AXIdentifier` (locale-invariant AX attribute) as fallback cache key. **`contentHash` is NEVER used as a cache key or skip-guard** (would mutate every scan + violate AC-2.3). `AXDescription` is NEVER used as a cache key (localizes). If neither `pluginIdentifier` (AU registry) nor `AXIdentifier` is available, `identifyPlugin` returns nil and caller produces E31 error: `"Plugin not in AU registry and has no stable AX identifier; cannot cache"`.
- [ ] **AC-7** (E31 error path): When both lookups fail, the caller (handler in T6/T7/T8) returns `isError: true` with the E31 text; `pluginVersion` is returned as nil to `skipAlreadyCached` callers per AC-2.3 (nil version → always rescan).

## 3. TDD Spec

### 3.1 Tests (Tests/LogicProMCPTests/PluginIdentityTests.swift)

Using injected `PluginWindowRuntime` closures for determinism:

| # | Test | Description |
|---|------|-------------|
| 1 | `testIdentifyPluginByBundleID` | Stub runtime returns bundle ID `"com.apple.audio.units.ES2"` → result name="ES2", bundleID correct |
| 2 | `testIdentifyPluginVersionDecoded` | Stub returns UInt32 `0x01030002` (1.3.2) → version="1.3.2" |
| 3 | `testIdentifyPluginVersionNil` | Stub returns `AudioComponentGetVersion` error → version is nil |
| 4 | `testIdentifyPluginLocaleInvariant` | Stub AXDescription="알케미" but bundle="com.apple.audio.units.Alchemy" → result bundleID correct (not localized) |
| 5 | `testFindSettingDropdownByRole` | Stub window has `AXMenuButton` child in header region → returns element |
| 6 | `testFindSettingDropdownMissingNilReturn` | Stub window has no AXMenuButton → nil |
| 7 | `testFindSettingDropdownLocalizedNotUsed` | Stub AXMenuButton has AXDescription="설정" → still found via role |
| 8 | `testFindPluginWindowMultipleMatches` | Stub app has 2 windows same bundle ID — first with Setting dropdown wins |
| 9 | `testFindPluginWindowNoMatch` | Stub no windows → nil |
| 10 | `testAURegistryLookupMissingReturnsNilVersion` | Stub registry returns nil for unknown bundle → version nil |

### 3.2 Mock Setup
- `PluginWindowRuntime` fully closure-driven; no live AX calls.
- AU registry wrapped in runtime closure `audioComponentVersion: (bundleID: String) -> UInt32?` for testability.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Type | Description |
|------|------|-------------|
| `Sources/LogicProMCP/Accessibility/PluginInspector.swift` | Modify | Add 3 methods + internal helpers `decodeAUVersion(_ raw: UInt32) -> String` |
| `Tests/LogicProMCPTests/PluginIdentityTests.swift` | Create | 10 tests |
| `Sources/LogicProMCP/Accessibility/PluginInspector.swift` | Modify | Extend `PluginWindowRuntime` with `audioComponentVersion` closure |

### 4.2 Implementation Steps
1. Add `audioComponentVersion: @Sendable (String) async -> UInt32?` to `PluginWindowRuntime`
2. `identifyPlugin` — read window's `AXIdentifier` (if available); else fall back to `AVAudioUnitComponentManager.shared().components(matching:)` keyed by description-derived name
3. `decodeAUVersion(_ raw: UInt32) -> String` — format `"M.m.b"` from bytes `((raw >> 16) & 0xFFFF).(raw >> 8 & 0xFF).(raw & 0xFF)`
4. `findSettingDropdown` — walk window's children, find first `AXMenuButton` whose `kAXPosition.y` is within top 50 px of window
5. `findPluginWindow(for trackIndex:)` — via runtime's `listOpenWindows`, filter by bundle ID match against track's current instrument slot (track inspection via existing `AccessibilityChannel` track-header logic)

### 4.3 Refactor
- Extract `isHeaderPosition(_:windowFrame:)` helper

## 5. Edge Cases
- EC-1 (E31): Third-party plugin — case (a) has `AXIdentifier` → use it as cache key, version nil, force rescan; case (b) no `AXIdentifier` AND no AU registry → E31 error (do NOT fall back to contentHash or AXDescription)
- EC-2 (E4b): Korean locale → AXDescription is Korean, but `AXIdentifier`/bundleID is locale-invariant; must use bundle-id path

## 6. Review Checklist
- [ ] Red: 10 tests FAIL
- [ ] Green: 10 tests PASS
- [ ] `decodeAUVersion` tested with: standard version, zero (invalid), max UInt32
- [ ] No AXDescription-based identity lookups in normal path
