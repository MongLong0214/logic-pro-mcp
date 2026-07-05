# WS1: Split AccessibilityChannel God-object (5369 → ~800) into 8 extensions

**PRD**: PRD-enterprise-review-refactor > G2, §3.1, §3.2 WS1
**Priority**: P1 | **Size**: L | **Risk**: L (pure file-move, compiler-verified)
**Owns (EXCLUSIVE)**: `Sources/LogicProMCP/Channels/AccessibilityChannel.swift` + new `AccessibilityChannel+*.swift`. MUST NOT touch `AccessibilityChannel+VerifiedPlugins.swift` (beyond it still compiling), any other dir, or `LogicProServer.swift`.
**Parallel-safe with**: WS2/3/4/5/6/7 (disjoint files).

## 1. Objective
Behavior-preserving split of the 5369-line actor into same-type cross-file extensions, so no logic changes and every test stays green. Core file keeps the actor shell, stored state, `execute()` dispatch, the 4 private instance scan-orchestrators, and shared encoders.

## 2. Acceptance Criteria
- AC1: New files `AccessibilityChannel+{Transport,Tracks,Mixer,Plugins,Library,Regions,MIDIImport,Project}.swift`, each `extension AccessibilityChannel`. Core `AccessibilityChannel.swift` ≤ ~900 lines.
- AC2: Moved per the PRD §3.2 WS1 MARK map (Transport 603-990/992-1280/3633-3760/3849-4078; Tracks 1282-1710/1830-2074; Mixer 2075-2131/4079-4217; Plugins 2132-2418; Library 2419-3630; Regions 4218-4482/5024-5277; MIDIImport 4495-5023; Project 4482/5278-5318).
- AC3: STAY IN CORE (hard constraint — actor private stored state): the 9 private stored props (runtime/lastScan/… L10-24), `execute()` (236-604), the 4 private instance methods `runLiveScan`/`runDiskScan`/`runBothScan`/`setLastScan` (+`seedLastScanForTest`), `AccessibilityError`.
- AC4: Exactly the ~24 promotions `private`→`internal`: the ~21 execute/Runtime.axBacked/healthCheck-referenced statics + the 3 cross-boundary statics `encodeResult` (→ move to a `+Shared.swift` or keep in Core), `menuItem`, `verifyTrackSelection`. NO stored prop promoted. NO other visibility widened.
- AC5: `encodeOrError`/`encodeResult` merged (round-1 Channels #9 — 0 tests assert their strings; verify with grep before merging). Dead `lastBothScan` (L21, written L2511 never read) deleted. `scanInProgress` split into two flags (library.scan_all vs plugin.scan_presets — round-1 #12).
- AC6: `swift test --no-parallel` fully green (baseline 1980). No behavior change; the 29-39 test-pinned symbols resolve by type regardless of file.
- AC7: Golden-snapshot diff = 0 for every AccessibilityChannel-reachable surface (this WS changes NO wire output).

## 3. TDD / Verification
No new product behavior → no new unit tests. Verification = existing suite green + a per-move compile. Method: move one MARK cluster at a time, `swift build` after each (surfaces the exact private→internal the compiler needs — do NOT pre-guess beyond AC4), full suite at the end. If the compiler demands a promotion NOT in AC4's list, STOP and report (it means a cross-boundary helper the PRD's ~24 estimate missed — orchestrator adjudicates).

## 4. Files
| File | Change |
|------|--------|
| AccessibilityChannel.swift | shrink to core; delete lastBothScan; split scanInProgress; merge encoders |
| AccessibilityChannel+{8}.swift | Create (moved funcs) |

## 5. Constraints
- Comments/annotations move verbatim with their funcs. No reformatting of moved bodies (keep diff a pure move — reviewers must see move-not-rewrite).
- Do NOT touch HC v1 encoders' output. Do NOT alter any string literal.
- Commit message: `refactor(#WS1): split AccessibilityChannel into 8 extensions (pure move, no behavior change)`.

## 6. Review Checklist
- [ ] Each new file compiles as `extension AccessibilityChannel`
- [ ] Core ≤ ~900 LOC; stored state + execute + scan-orchestrators retained
- [ ] Exactly AC4 promotions (git diff shows only those `private`→(nothing)); no stored-prop promotion
- [ ] Full suite green (1980); golden diff = 0
- [ ] `git show --stat` = moves + 8 new files + 3 deletions (lastBothScan/encoder merge/scanInProgress)
