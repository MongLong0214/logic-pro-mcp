# T13: Edge Case Tests — E1-E32 (37 rows incl. E4b/E6b/E9b/E11b/E11c)

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > §5 E1-E32, §8.3
**Priority**: P1
**Size**: L
**Status**: Todo
**Depends On**: T6, T7, T8, T9

---

## 1. Objective
Every row of PRD §5 edge table gets a dedicated test in `Tests/LogicProMCPTests/PluginInspectorEdgeCaseTests.swift`. PRD §5 has **37 rows** (E1-E32 + sub-variants E4b/E6b/E9b/E11b/E11c). Target: ≥ 37 tests.

## 2. Acceptance Criteria
- [ ] **AC-1**: Every row of §5 (37 total incl. sub-variants) has a dedicated test named `testE{N}[_sub]_<shortSlug>`.
- [ ] **AC-2**: Test assertions match the "Expected Behavior" column exactly.
- [ ] **AC-3**: All tests PASS.

## 3. TDD Spec

### 3.1 Test mapping

| E | Test name | Mechanism |
|---|-----------|-----------|
| E1 | testE1_NoFocusedWindowNoTrackIndex | Error |
| E2 | testE2_NoSettingDropdownThirdParty | Error |
| E3 | testE3_EmptyFactoryPresetsMenu | leafCount:0, no error |
| E4 | testE4_DuplicateSiblings | `[0]`/`[1]` suffix |
| E4b | testE4b_LocalizedSettingDropdown | role+region, not localized description |
| E5 | testE5_SlashInPresetNameEscaped | `\/` parse |
| E6 | testE6_ExternalMutationAborts | menuMutated error |
| E6b | testE6b_ScannerOwnPressSuppressed | Inject `mutationSinceLastCheck` returning `false` during guard window (AXPress + settleMs + children-read). Assert `enumerateMenuTree` completes without throwing `menuMutated` — the scanner's own press is NOT treated as external mutation. |
| E7 | testE7_UnicodePresetNamesPreserved | JSON round-trip |
| E8 | testE8_SubmenuProbeTimeout | probeTimeout kind |
| E9 | testE9_DepthGt10Truncated | truncated kind |
| E9b | testE9b_CycleDetected | cycle kind |
| E10 | testE10_LogicProNotRunning | error |
| E11 | testE11_AccessibilityPermMissing | early error |
| E11b | testE11b_PostEventPermMissingConditional | **T0-gated**: if T0 verdict = GO-AXPRESS, test body is `// SKIP: E11b is dead code on AXPress path` + `#expect(Bool(true))` with comment. If T0 = GO-CGEVENT, assert handler returns `isError: true` with text containing `Event-post permission required`. |
| E11c | testE11c_AutomationPermDenied | .apiDisabled wrapped |
| E12 | testE12_RejectsExtraParams | error |
| E13 | testE13_AudioTrackNoInstrument | error |
| E14 | testE14_EffectPluginNotInstrument | error single; skipped batch |
| E15 | testE15_SharedAXLockBlocksOthers | cross-surface error |
| E16 | testE16_AXErrorWrapped | no panic |
| E17 | testE17_AXValueForceUnwrapGuarded | nil guard |
| E18 | testE18_SetPresetMidNavigationError | structured error |
| E19 | testE19_OpenTimeout2000ms | openTimeout |
| E20 | testE20_BundleIDMismatchAbortCloseScannerWindow | cleanup then error |
| E21 | testE21_PerTrackErrorBatchContinues | entry.error set |
| E22 | testE22_NilVersionForcesRescan | no circular |
| E23 | testE23_CacheWriteFailTolerated | response returned |
| E24 | testE24_EmptySegmentPath | error |
| E25 | testE25_LogicClosedMidScanDeferClears | flag reset |
| E26 | testE26_MultipleWindowsSameTrack | first-match |
| E27 | testE27_WindowClosedMidScan | wrapped error |
| E28 | testE28_FullscreenMidScanAborts | error + cleanup |
| E29 | testE29_DMDOuterShellLimitationNote | limitationNote field |
| E30 | testE30_TrackStructureMutatesMidBatchGracefulDegradation | When user deletes track 3 during batch (simulated via track-resolver returning nil for index 3 mid-iteration), that track's entry gets `error: "Track 3 no longer exists"`; batch continues for tracks 4-5. (MCP does not detect — but the null-track-resolver branch IS testable.) |
| E31 | testE31_AURegistryLookupFailsFallbackAXIdentifier | no AXDescription in key |
| E32 | testE32_CacheMissOnLiveBundleID | AC-3.0 step (d) error |

## 4. Implementation Guide

### 4.1 Files to Create
| File | Type | Description |
|------|------|-------------|
| `Tests/LogicProMCPTests/PluginInspectorEdgeCaseTests.swift` | Create | 32+ tests (one per E# row) |

### 4.2 Implementation Steps
1. Create one `@Test` per E# row
2. Each test uses injected `PluginInspector.Runtime` + `PluginWindowRuntime` closures to simulate the edge condition
3. Assert exact error text or response shape per "Expected Behavior" column

### 4.3 Refactor
- Shared test helpers: `makeMockRuntime(...)`, `makeTree(depth:branching:)`

## 5. Edge Cases
- N/A (this ticket IS the edge-case test bundle)

## 6. Review Checklist
- [ ] 32+ edge tests PASS
- [ ] Every E# row has a matching test
- [ ] No test depends on live Logic Pro
