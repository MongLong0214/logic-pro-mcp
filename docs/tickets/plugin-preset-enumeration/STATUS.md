# Pipeline Status: Plugin Preset Enumeration (F2)

**PRD**: docs/prd/PRD-plugin-preset-enumeration.md (v0.5, Approved)
**Size**: XL
**Current Phase**: 7 Done (Foundation complete; T6-T14 deferred to follow-up PR)
**Completion report**: [COMPLETION-REPORT.md](./COMPLETION-REPORT.md)
**Total new tests**: 54 (593 baseline → 647 pass, 0 regressions)
**Scope reality check**: XL feature requires 10-14 days post-approval per PRD estimate. 10h autonomous session delivered: PRD v0.5 (Ralph converged after 5 rounds) + 15 tickets + foundation code (PluginInspector.swift ~380 lines, 54 tests) + T0 spike infrastructure. Handler tier (T6-T10) + full test bundles (T12-T14) require follow-up.

## Ticket Status Definitions
- **Todo**: 미착수
- **In Progress**: 구현 중
- **In Review**: 리뷰 진행 중
- **Done**: 완료 (AC 충족 + 테스트 PASS)
- **Invalidated**: 역행으로 무효화됨

## Tickets (15 total — T0 spike + T1-T14)

| Ticket | Title | Size | Status | Review | Notes |
|--------|-------|------|--------|--------|-------|
| T0  | Plugin Menu AX Probe Spike | M | **Done** (script + result template; live-run deferred) | SELF | Probe script `Scripts/plugin-menu-ax-probe.swift` written + chmod +x; result doc `docs/spikes/F2-T0-plugin-menu-probe-result.md` as template — to be filled when Isaac runs against live Logic Pro |
| T1  | Plugin Preset Data Types | S | **Done** | SELF PASS (9 tests) | |
| T2  | enumerateMenuTree Recursive Walker | M | **Done** | SELF PASS (11 tests) | |
| T3  | resolveMenuPath + selectMenuPath | M | **Done** | SELF PASS (19 tests — parse/encode/resolve/select) | |
| T4  | Plugin Identity (identifyPlugin + findPluginWindow + decodeAUVersion) | M | **Done** (findSettingDropdown deferred to T6) | SELF PASS (8 tests) | findSettingDropdown requires live AX-tree walk; deferred to T6 where PluginWindowRuntime extension closures provide the seam |
| T5  | Plugin Window Lifecycle (open/close + timeout via monotonic clock) | M | **Done** (CGWindowID capture via runtime closure — stub for T6) | SELF PASS (6 tests) | |
| T6  | scanPluginPresets Handler + Actor State + Cache Persistence | L | **Deferred to follow-up PR** | - | Requires AccessibilityChannel actor state additions + cache file I/O + trackPluginMapping — out of 10h budget scope |
| T7  | scanAllInstruments Batch Handler + Reconciliation Ledger | L | **Deferred** | - | Depends: T6 |
| T8  | setPluginPreset Handler + AC-3.0 Identity Gate | M | **Deferred** | - | Depends: T3, T4, T5, T6 |
| T9  | resolvePluginPresetPath Handler (cache-only) | S | **Deferred** | - | Depends: T6 |
| T10 | TrackDispatcher MCP Command Wiring | S | **Deferred** | - | Depends: T6-T9 |
| T11 | Unit Tests Bundle + Coverage ≥ 90% | M | **Partial** — T1-T5 ships 54 unit tests | - | Coverage audit against PluginInspector.swift deferred |
| T12 | Integration Tests Bundle + 100% Branch | L | **Deferred** | - | Depends: T6-T10 |
| T13 | Edge Case Tests E1-E32 | L | **Deferred** | - | Depends: T6-T9 |
| T14 | Rollout — .gitignore + Docs + E2E + Test-Count Gate | M | **Deferred** | - | Depends: T10, T12, T13 |

## Dependency Order (TDD execution)

```
T0 (spike) ──┐
             ├──▶ T4 ──┬──▶ T5 ──┐
T1 (types) ──┼──▶ T2 ──┤         │
             │        ↓         │
             └──▶ T3 ─┴───▶ T6 ◀─┘
                            ├──▶ T7 ──┐
                            ├──▶ T8 ──┤
                            └──▶ T9 ──┤
                                      ├──▶ T10 ──┐
                                      │          │
                     T11 (coverage) ◀─┤          │
                                      │          │
                     T13 (edges) ◀────┘          │
                                                 │
                     T12 (int coverage) ◀────────┤
                                                 │
                     T14 (rollout) ◀─────────────┘
```

## Review History

| Phase | Round | Verdict | P0 | P1 | P2 | Notes |
|-------|-------|---------|----|----|-----|-------|
| 2 | 1 | REQUEST CHANGES | 2 | ~20 | ~15 | strategist + guardian + boomer; PRD → v0.2 |
| 2 | 2 | REQUEST CHANGES | 0 | 3 | 5 | boomer HAS ISSUES; PRD → v0.3 |
| 2 | 3 | MIXED | 1 | 1 | 2 | strategist PASS, guardian REQUEST CHANGES (P0 AudioComponentCopyName API error), boomer HAS ISSUES; PRD → v0.4 |
| 2 | 4 | MIXED | 0 | 0 | 2 | guardian PASS, boomer 2 PARTIAL + 2 NEW P2; PRD → v0.5 |
| 2 | 5 | PASS (Ralph converged) | 0 | 0 | 1 | boomer residual P2 in §4.4 + §10.2 — resolved in-place |
| 4 | 1 | REQUEST CHANGES | 1 | ~8 | ~15 | 4-reviewer Round 1: T4 stale contentHash (P1), T12↔T14 gitignore race (P1), AC-1.3/1.6/1.8/6.3 orphans (P1 × 4), trackPluginMapping missing (P0), T14 under-scoped (P0). All fixed in-place. |
| 4 | 2 | PASS (pending verification) | 0 | 0 | 0 | v2 tickets after Round 1 fixes applied to T1/T4/T6/T9/T12/T13/T14 + STATUS.md. |
| 5 | Incremental | PASS | 0 | 0 | 0 | Per-ticket self-review after each of T1-T5 Green phase. Full suite: 647/647 PASS. |
| 6 | 1 | PASS (with 3 fixes applied) | 1 | 0 | 2 | guardian PASS (94.41% line cov); boomer HAS ISSUES (P0 negative dupIdx crash, P2 escaped trailing slash, P2 timeout `>` vs `>=`). All 3 fixed + regression tests added. 650/650 PASS post-fix. |

## Notable Decisions (from Phase 2 convergence)

- **T0 is a hard gate**: AXPress-vs-CGEvent determination before T2/T3/T6 lock
- **CGEvent fallback delegates to `LibraryAccessor.productionMouseClick`** — no re-implementation
- **`axScanInProgress` rename** (from `scanInProgress`): shared mutex across library + plugin scans + `set_plugin_preset`; `resolve_preset_path` exempt
- **AU version via `AudioComponentGetVersion`** (free function, not `AUPlugInGetVersionNumber`)
- **`AXUIElementSendable` is NEW** (no F1 predecessor): concrete `final class @unchecked Sendable`
- **`ScannerWindowRecord` keyed by `CGWindowID`** (stable integer, survives AX GC); `(bundleID, windowTitle)` fallback
- **contentHash used only post-rescan** — NEVER as cache skip-guard (would be circular)
- **`AXIdentifier` is fallback key** when AU registry lookup fails (NOT `AXDescription` — localizes)
