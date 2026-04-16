# T9: resolvePluginPresetPath Handler (cache-only dry-run)

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > US-4 AC-4.1-4.4, AC-1.9 (exempt)
**Priority**: P1
**Size**: S
**Status**: Todo
**Depends On**: T3, T6

---

## 1. Objective
Implement `AccessibilityChannel.resolvePluginPresetPath` — cache-only, zero AX clicks. Exempt from `axScanInProgress` flag. Returns `{ exists, kind, matchedPath?, children? }`.

## 2. Acceptance Criteria
- [ ] **AC-1** (AC-4.1): Cache present + path resolves → `{ exists:true, kind, matchedPath, children (for folder) or [] }`.
- [ ] **AC-2** (AC-4.2): No cache → `{ exists:false, reason:"no_cache", hint }`.
- [ ] **AC-3** (AC-4.3): Trailing slash stripped.
- [ ] **AC-4** (AC-4.4): Empty or `"/"` → root's children.
- [ ] **AC-5** (AC-1.9): During active scan, call returns within 100 ms (no blocking, flag-exempt).
- [ ] **AC-6**: `children` always present (empty array for leaf/action/separator) to avoid LLM ambiguity.

## 3. TDD Spec

### 3.1 Tests (Tests/LogicProMCPTests/AccessibilityChannelResolvePresetPathTests.swift)

| # | Test | Description |
|---|------|-------------|
| 1 | `testResolveLeafInCache` | Valid path → exists:true, kind:leaf, children:[] |
| 2 | `testResolveFolderInCache` | Folder path → exists:true, kind:folder, children populated |
| 3 | `testResolveMissingPath` | Path doesn't resolve → exists:false |
| 4 | `testNoCacheNoCacheReason` | No cache entry → reason:"no_cache" |
| 5 | `testTrailingSlashStripped` | `"Bass/"` → resolves as `"Bass"` |
| 6 | `testEmptyPathReturnsRootChildren` | `""` → returns matchedPath:"" + root's children |
| 7 | `testSlashOnlyReturnsRootChildren` | `"/"` → same as empty |
| 8 | `testResolveDuringActiveScanNotBlocked` | Injected scan in progress → method returns in < 100ms |
| 9 | `testResolveReturnsActionKind` | Action path → kind:"action", children:[] |
| 10 | `testResolveReturnsSeparatorKind` | Separator → kind:"separator" |

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Type | Description |
|------|------|-------------|
| `Sources/LogicProMCP/Channels/AccessibilityChannel.swift` | Modify | Add `case "plugin.resolve_preset_path"`; does NOT acquire axScanInProgress |
| `Tests/LogicProMCPTests/AccessibilityChannelResolvePresetPathTests.swift` | Create | 10 tests |

### 4.2 Implementation Steps
1. Validate params `{trackIndex, path}`
2. Look up track's cached plugin via **`trackPluginMapping[trackIndex]` actor state** (introduced in T6 AC-13). If no mapping → `no_cache` + hint "call scan_plugin_presets first".
3. Look up `pluginPresetCache[bundleID]`. Missing → `no_cache` response (defensive — should match mapping).
4. Parse path (handles empty, trailing slash, escapes via T3)
5. Resolve via `resolveMenuPath` (T3)
6. Encode response with `kind`, `matchedPath`, `children`

**Note on staleness** (boomer R4 P0 clarified): If the user swapped the plugin after the last scan but before `resolve_preset_path`, `trackPluginMapping` still points at the stale bundleID (zero-AX contract). `resolve_preset_path` returns the cache's view of the pre-swap plugin — this is documented behavior: the method is a *dry-run* of the cached state, not a live-state probe. Callers needing live state call `scan_plugin_presets` first.

### 4.3 Refactor
- Shared cache-lookup helper with T8

## 5. Edge Cases
- EC-1: Track has plugin but no prior scan → same as "no cache"
- EC-2: User swapped plugin — cache for old bundle ID exists; live is different → still dry-run against current live cache (may return exists:false) — note in docs

## 6. Review Checklist
- [ ] Red: 10 tests FAIL
- [ ] Green: 10 tests PASS
- [ ] Zero AX calls verified (spy count)
- [ ] Exempt from shared flag verified (test 8)
