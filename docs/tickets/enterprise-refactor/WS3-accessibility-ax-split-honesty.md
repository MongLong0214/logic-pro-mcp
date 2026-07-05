# WS3: Accessibility/Plugins/Audio — AXLogicProElements split + extractTrackState honesty (VALUE-ONLY) + dedup/dead/policy

**PRD**: G1/G2/G3/G6, §3.2 WS3, §4 E9
**Priority**: P1 (honesty) | **Size**: L | **Risk**: L-M
**Owns (EXCLUSIVE)**: `Accessibility/{AXLogicProElements, AXHelpers, AXValueExtractors, AXLocalePolicy, PluginInspector, LibraryAccessor, LibraryDiskScanner, AXMouseHelper}.swift` + `Resources/ResourceProvider.swift` (extractTrackState caller — WS3-exclusive, excluded from WS4) + `Plugins/{StockPluginCatalog, VerifiedPluginCatalog}.swift` + `Audio/AudioAnalyzer.swift` + new test files `Tests/LogicProMCPTests/{ExtractTrackStateHonestyTests,AXHelpersDowncastGuardTests}.swift` (WS3-created, excluded from WS8). MUST NOT touch other Resources/ (WS4), Channels, or existing test files.
**Parallel-safe with**: WS1/2/4/5/6/7.

## 1. Objective
Split the 1799-line AXLogicProElements, fix the `logic://tracks` fabricated-data honesty gap (VALUE-ONLY, no type change), centralize AXLocalePolicy bypasses, hoist triplicates, delete dead code.

## 2. Acceptance Criteria
- AC1: AXLogicProElements.swift (1799) → 6 same-type extensions (`+Transport, +Tracks, +Mixer, +PluginSlots, +Markers, +Menu` per round-1 #1). Pure move; signatures unchanged.
- **AC2 [honesty, G6 exception — VALUE-ONLY]**: `extractTrackState` (AXValueExtractors:257-322) reads REAL track-header volume/pan via `findTrackHeaderVolumeFader`/`findTrackHeaderPanControl` (already exist) + automationMode from the track-header automation group desc. **NO TYPE CHANGE**: volume/pan stay non-optional `Double`, automationMode stays its current enum (NO `.unknown`), NO nullable/sentinel/omitted-key/NaN. On rare AX-read failure RETAIN today's default (unchanged). `sampleRate` (project-level, fabricated 44100) left AS-IS this sweep + documented. Wire shape byte-identical except the 3 VALUES.
- AC3: AXHelpers:40 `unsafeDowncast(_, CFArray.self)` gains `guard CFGetTypeID(value)==CFArrayGetTypeID() else {return []}` (matches getPosition/getSize 4 lines away). AXValueExtractors slider-normalization fallbacks fail-closed to contract range (not raw) (audit #17). Track-type tokens (오디오/악기) → AXLocalePolicy LabelSet (round-1 #6).
- AC4: AXLocalePolicy bypasses centralized: library label (LibraryAccessor:1166/1182), marker tables (AXLogicProElements markerListWindowSuffixes/markerCellPlaceholders — 13-locale, relocate into policy), cancel markers (round-1 #7/#8). LibraryNode triplicate (`flattenPresetsByCategory`/`collectLeaves`/`countNodes` in LibraryAccessor + LibraryDiskScanner) → shared `extension LibraryNode` (round-1 #3).
- AC5: `productionMouseClick`/`postCliclick` (LibraryAccessor) prefer native AXMouseHelper.click over spawning cliclick (audit #16 — FD-leak-class); OR move to AXMouseHelper if native path proven equivalent (live-verify). L2 /tmp debug log (LibraryAccessor:1381) → mkdtemp dir. PluginInspector live-AX helpers (497-685) route through AXHelpers where injectable (round-1/audit #2 — M risk, thin coverage, careful).
- AC6: Delete dead: `findTrackOutline` (AXLogicProElements:543), `pressDelete` (AXMouseHelper:121), `setNormalizedSliderValue` (AXValueExtractors:46). AnalysisPolicy.default → `= AnalysisPolicy()` (round-1 #11). VerifiedPluginCatalog stale doc (audit #28 — Compressor.threshold is first writable, not "only Gain"). StockPluginCatalog: DO NOT externalize (NG6); optional +Types/+Validator/+Seeds/+Probe split only if cheap.
- AC7: `swift test --no-parallel` green + **live-verify extractTrackState on 12.3** (real volume/pan/automationMode, not 0.0). Golden-snapshot: logic://tracks allows VALUE drift on the 3 fields ONLY; type+key+enum-domain diff = 0; all other AX surfaces diff = 0.

## 3. TDD / Verification
- extractTrackState: unit test with a fake track-header exposing known volume/pan/automation → asserts real values flow through (RED on current 0.0 fabrication). Live-verify on Logic 12.3 (drive logic://tracks, confirm non-zero real values match the mixer).
- AXHelpers guard: test a non-CFArray attribute returns [] not UB.
- Split: pure move, existing suite green.

## 4. Constraints
- extractTrackState is the ONLY intended observable change — keep it value-only (boomer R4). If making a value honest would require a type change, STOP and report (do NOT introduce nullable/sentinel).
- Marker/label relocations to AXLocalePolicy must be diacritic-sensitive (per repo memory — all 3 match modes diacritic-sensitive; add sensitivity assertions on LabelSet migrations).
- Commit per unit (split / honesty / policy / dead-code separate).

## 5. Review Checklist
- [ ] AXLogicProElements 6-ext (pure move)
- [ ] extractTrackState value-only, non-optional preserved, live-verified on 12.3
- [ ] AXHelpers downcast guard + test; slider fail-closed
- [ ] AXLocalePolicy bypasses centralized (diacritic-sensitive); LibraryNode triplicate hoisted
- [ ] dead code deleted; full suite green; golden diff = 0 except the 3 track VALUES
