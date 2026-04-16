# T11: Unit Tests Bundle — Coverage Consolidation

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > §8.1, AC-6.1, AC-6.2
**Priority**: P1
**Size**: M
**Status**: Todo
**Depends On**: T2, T3, T4, T5

---

## 1. Objective
Consolidate unit tests added by T1-T5 + fill any coverage gaps to reach ≥ 90% line / ≥ 85% branch on `PluginInspector.swift`. Add any missing tests identified via coverage report. Target: ≥ 41 unit tests (per PRD §8.1 enumeration).

## 2. Acceptance Criteria
- [ ] **AC-1** (AC-6.1): `PluginInspector.swift` line coverage ≥ 90% via `xcrun llvm-cov report`.
- [ ] **AC-2** (AC-6.1): Branch coverage ≥ 85%.
- [ ] **AC-3** (AC-6.2): Count of PluginInspector* unit tests ≥ 41.
- [ ] **AC-4**: Every `public` function in `PluginInspector.swift` has ≥ 1 test naming it.

## 3. TDD Spec

### 3.1 Coverage Audit
Run coverage report; identify uncovered lines/branches. Add targeted tests for gaps. Typical gaps:
- Error-propagation paths not exercised
- Defensive guards against nil inputs
- Malformed input recovery paths

### 3.2 Test files consolidated
- `PluginInspectorTypesTests.swift` (T1)
- `PluginInspectorEnumerateTreeTests.swift` (T2)
- `PluginInspectorPathTests.swift` (T3)
- `PluginIdentityTests.swift` (T4)
- `PluginWindowLifecycleTests.swift` (T5)
- `PluginInspectorCoverageTests.swift` (T11 — gap-fill tests only)

## 4. Implementation Guide

### 4.1 Coverage Command
```
swift test --enable-code-coverage
xcrun llvm-cov report .build/*/debug/LogicProMCPPackageTests.xctest/Contents/MacOS/LogicProMCPPackageTests \
  -instr-profile=.build/*/debug/codecov/default.profdata \
  --ignore-filename-regex=".*Tests.*|.*\.build.*" | grep PluginInspector
```

### 4.2 Implementation Steps
1. Run initial coverage report
2. For each uncovered line/branch, add a targeted test in `PluginInspectorCoverageTests.swift`
3. Re-run coverage; confirm ≥ 90% line / ≥ 85% branch
4. Count total PluginInspector* tests; confirm ≥ 41

## 5. Edge Cases
- EC-1: Force-coverage anti-pattern — tests must exercise real behavior, not just invoke for coverage. Each gap-fill test has an assertion.

## 6. Review Checklist
- [ ] Coverage report shows ≥ 90% line on PluginInspector.swift
- [ ] Branch coverage ≥ 85%
- [ ] ≥ 41 unit tests
- [ ] No trivial tests (each has ≥ 1 #expect)
