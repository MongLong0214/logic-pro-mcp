# T11: Cleanup — Gitignore Inventory, Remove Stale JSON, Docs Update

**PRD Ref**: PRD-library-full-enumeration > §9.1, Non-Goal NG6
**Priority**: P2
**Size**: S (< 2h)
**Status**: Todo
**Depends On**: T4 (scanLibraryAll)

---

## 1. Objective
Operationalize the "inventory is a per-user artifact, never shipped" policy. Add `.gitignore` entry, delete committed stale JSON, update README/TROUBLESHOOTING with new `scan_library` and path-mode workflow.

## 2. Acceptance Criteria
- [ ] `Resources/library-inventory.json` added to `.gitignore`
- [ ] Existing `Resources/library-inventory.json` removed from git index (kept on disk)
- [ ] `README.md` section on `scan_library` + `set_instrument { path }` with an example
- [ ] `docs/TROUBLESHOOTING.md` adds Input Monitoring / CGPreflightPostEventAccess permission guidance

## 3. TDD Spec (Red Phase)
Documentation/gitignore ticket — exempt from TDD per pipeline rule 3 ("순수 스타일/텍스트/설정 변경은 snapshot 또는 visual verification으로 대체 가능").

Verification steps:
1. `git check-ignore -v Resources/library-inventory.json` → match line in .gitignore
2. `git ls-files Resources/library-inventory.json` → empty (not tracked)
3. `grep -l 'scan_library' README.md` → match
4. `grep -l 'CGPreflightPostEventAccess\|Input Monitoring' docs/TROUBLESHOOTING.md` → match

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `.gitignore` | Modify | Add `Resources/library-inventory.json` |
| `Resources/library-inventory.json` | git rm --cached | Remove from tracking |
| `README.md` | Modify | Add usage section for scan + path |
| `docs/TROUBLESHOOTING.md` | Modify | Add TCC permission guidance |

### 4.2 Steps
1. Edit `.gitignore`.
2. `git rm --cached Resources/library-inventory.json`.
3. Append README section.
4. Append TROUBLESHOOTING section.

### 4.3 Refactor Phase
None.

## 5. Edge Cases
- EC-1: File already absent from disk — keep gitignore rule anyway.

## 6. Review Checklist
- [ ] .gitignore entry present
- [ ] File not tracked
- [ ] README has scan_library example
- [ ] TROUBLESHOOTING has permission guidance
