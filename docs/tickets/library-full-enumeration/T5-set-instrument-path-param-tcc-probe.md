# T5: set_instrument path param + TCC probe + E19 force-unwrap fix

**PRD Ref**: PRD-library-full-enumeration > US-2, US-3, §5 E10b, E19
**Priority**: P0
**Size**: M (2-4h)
**Status**: Todo
**Depends On**: T3 (resolvePath/selectByPath)

---

## 1. Objective
Extend `setTrackInstrument` to accept `path:` parameter (preferred) alongside legacy `{category, preset}`. Add `CGPreflightPostEventAccess()` probe for Input Monitoring/Post-Event capability. Replace `as!` force-unwraps on AXValue with guarded `as?`.

## 2. Acceptance Criteria
- [ ] AC-2.1 through AC-2.8 (PRD US-2)
- [ ] AC-3.1, AC-3.3 (US-3)
- [ ] E10b: First CGEvent run in session probes `CGPreflightPostEventAccess()`; denied → error
- [ ] E19: No `as!` on `AXValue` anywhere in LibraryAccessor.swift or AccessibilityChannel.swift
- [ ] **PRD §6.3 parity**: `system.permissions` MCP tool response extended with `postEventAccess: Bool` field (reading `CGPreflightPostEventAccess()` result), alongside existing Accessibility flag. Addresses boomer Round 2 P2-B — T9 test #12 depends on this work owned by T5.

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testSetInstrument_PathMode_LoadsPreset` | Integration | `{ index, path: "Bass/Sub" }` | Returns path+category+preset in JSON |
| 2 | `testSetInstrument_PathWins_LegacyIgnored` | Integration | Both `path` and `{category, preset}` | Path sequence executed; category/preset params ignored with debug log |
| 3 | `testSetInstrument_NoPath_NoCategoryPreset_Error` | Integration | `{ index }` only | isError, "Missing path or (category+preset)" |
| 4 | `testSetInstrument_PathResolvesToFolder_Error` | Integration | `path: "Orchestral"` (folder) | AC-2.8 error text |
| 5 | `testSetInstrument_IndexOutOfRange_NoMutation` | Integration | `index: 999` | Error, library.selectCategory NOT called |
| 6 | `testSetInstrument_PostEventDenied_Error` | Integration | Mock probe returns false | Error "Event-post permission required" |
| 7 | `testSetInstrument_PostEventGranted_Proceeds` | Integration | Probe true | Normal flow |
| 8 | `testAXValueGetValue_AsQuestionGuard_NilSafe` | Unit | Inject posValue as wrong type → no crash | Returns nil gracefully |
| 9 | `testSetInstrument_Track5PreviouslySelected_Track0Wins` | Integration | Previously-focused track=5, call index=0 | Track 0 clicked via CGEvent |
| 10 | `testSetInstrument_TrackHeaderNotFound_ErrorBeforeLibrary` | Integration | findTrackHeader→nil | Error, no library click |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/AccessibilityChannelSetInstrumentTests.swift` (NEW)

### 3.3 Mock/Setup Required
- Mock `LibraryAccessor.Runtime` with click recorder
- Mock `AXLogicProElements.Runtime` with findTrackHeader programmability
- Mock `postEventAccessProbe: @Sendable () -> Bool` injected into AccessibilityChannel runtime

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Channels/AccessibilityChannel.swift` | Modify | `setTrackInstrument`: add `path` branch, add TCC probe, fix force-unwraps |
| `Sources/LogicProMCP/Accessibility/LibraryAccessor.swift` | Modify | Replace `as! AXValue` → `as?` guards (2 sites) |
| `Tests/LogicProMCPTests/AccessibilityChannelSetInstrumentTests.swift` | Create | 10 tests per §3.1 |

### 4.2 Implementation Steps
1. Add `postEventAccessProbe` closure to `AccessibilityChannel.Runtime`. Default: `CGPreflightPostEventAccess`.
2. Refactor `setTrackInstrument` guard: accept `path` OR (`category` + `preset`); error otherwise.
3. Probe at start of function if CGEvent injection needed.
4. `path` branch: call `LibraryAccessor.resolvePath` → if folder, error; else `selectByPath`.
5. Replace `as! AXValue` in `LibraryAccessor.swift:250-251` with `guard let axPos = posRaw as? AXValue, let axSize = sizeRaw as? AXValue else { return nil }`.
6. Same in `AccessibilityChannel.swift:824-825`.
7. **Update `system.permissions` MCP tool**: find existing handler in `SystemDispatcher.swift`; extend response JSON to include `postEventAccess: Bool` (from `CGPreflightPostEventAccess()`). Do not remove or rename existing keys.
8. Tests pass (including T9 #12).

### 4.3 Refactor Phase
- Extract track-header-click helper if it's reused by T6.

## 5. Edge Cases
- EC-1: `path` contains escaped slash — handled via `parsePath`.
- EC-2: Track header present but `posValue` is nil — fallback to `kAXPressAction`.
- EC-3: Path is `""` → error.

## 6. Review Checklist
- [ ] 10 tests Red → Green
- [ ] Zero `as!` on AXValue in touched files
- [ ] Probe runs once per session (cached)
- [ ] Legacy `{category, preset}` still works
- [ ] Path mode verified via /tmp/load-8-instruments.py re-run post-merge
