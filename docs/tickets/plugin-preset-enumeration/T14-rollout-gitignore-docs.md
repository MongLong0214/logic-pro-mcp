# T14: Rollout — .gitignore + Docs + E2E + Test-Count Gate

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > §9.1, §8.5, AC-6.3, AC-6.4
**Priority**: P1
**Size**: M (upgraded from S after Phase 4 finding — test-live.md is CREATE not Modify, plus README/TROUBLESHOOTING/API docs required)
**Status**: Todo
**Depends On**: T10, T12, T13

---

## 1. Objective
Finish rollout: (a) `.gitignore` wildcard (covers F1 + F2 inventories), (b) CREATE `docs/test-live.md` with §F2 manual QA, (c) `Scripts/plugin-live-e2e.sh` E2E smoke script, (d) update `README.md` / `docs/TROUBLESHOOTING.md` / `docs/API.md` for 4 new commands, (e) verify baseline+50 test-count gate (AC-6.3), (f) verify gitignore grep (moved from T12 to fix ordering).

## 2. Acceptance Criteria
- [ ] **AC-1** (gitignore wildcard): `.gitignore` replaces specific line `Resources/library-inventory.json` with `Resources/*-inventory.json`. Post-swap: `git check-ignore -v Resources/library-inventory.json` matches the new wildcard rule; `git check-ignore -v Resources/plugin-inventory.json` also matches (new F2 artifact covered).
- [ ] **AC-2** (test-live.md CREATE): `docs/test-live.md` is **created new** (file does not exist today). Top-level includes `## F2 — Plugin Preset Enumeration` section listing ground-truth leaf counts: ES2 ≥ 300, Alchemy ≥ 1 500, Sculpture ≥ 250, Retro Synth ≥ 200. Also includes placeholder sections for F1 live verification (stub lines; not required to be complete in F2 work).
- [ ] **AC-3** (E2E script): `Scripts/plugin-live-e2e.sh` executable (+x bit); performs 3 JSON-RPC calls via MCP stdio: `scan_plugin_presets { trackIndex: 0 }`, `set_plugin_preset { trackIndex: 0, path: "Factory Presets/Bass/Sub Bass" }` (ES2), `scan_all_instruments { }`. Exits non-zero on any failure response. Runs graceful on Logic-not-running (prints "Logic Pro not running — skipping", exit 0).
- [ ] **AC-4** (README): `README.md` updated with a new section listing the 4 MCP commands (`scan_plugin_presets`, `scan_all_instruments`, `set_plugin_preset`, `resolve_preset_path`) with param schemas + 1-sentence description each. Mirrors existing library-scan section.
- [ ] **AC-5** (TROUBLESHOOTING): `docs/TROUBLESHOOTING.md` adds §"Plugin Preset — macOS Automation Permission" entry: first run triggers native prompt; if denied, commands fail with clear error; recovery via System Settings → Privacy & Security → Automation.
- [ ] **AC-6** (API.md): `docs/API.md` adds 4 command entries in existing format with JSON-schema for params + response shape.
- [ ] **AC-7** (AC-6.3 test-count gate): `Scripts/verify-test-count.sh` runs `swift test --list-tests | wc -l`, compares against baseline captured in `docs/tickets/plugin-preset-enumeration/TEST-BASELINE.txt` (created at T14 kickoff before merging). Asserts delta ≥ 50. Exits non-zero if not met. CI calls this script.
- [ ] **AC-8** (gitignore grep — moved from T12): Rollout test asserts `grep 'Resources/\*-inventory.json' .gitignore` matches.

## 3. TDD Spec

### 3.1 Tests (Tests/LogicProMCPTests/PluginRolloutTests.swift)
| # | Test | Description |
|---|------|-------------|
| 1 | `testE2EScriptExecutable` | `Scripts/plugin-live-e2e.sh` has execute bit |
| 2 | `testTestLiveDocContainsF2Section` | File exists AND grep for `## F2 — Plugin Preset Enumeration` matches |
| 3 | `testTestLiveDocContainsGroundTruthCounts` | Grep for "ES2 ≥ 300", "Alchemy ≥ 1 500" succeeds |
| 4 | `testGitignoreWildcardPresent` | `grep 'Resources/\*-inventory.json' .gitignore` succeeds (moved from T12) |
| 5 | `testReadmeListsPluginCommands` | README.md grep for all 4 command names |
| 6 | `testTroubleshootingAutomationSection` | TROUBLESHOOTING.md grep for "Automation Permission" |
| 7 | `testApiDocListsPluginCommands` | API.md grep for 4 commands |
| 8 | `testVerifyTestCountScriptExecutable` | Scripts/verify-test-count.sh +x bit |
| 9 | `testBaselineFileCreated` | TEST-BASELINE.txt exists with integer |

## 4. Implementation Guide

### 4.1 Files to Modify / Create
| File | Type | Description |
|------|------|-------------|
| `.gitignore` | Modify | Replace `Resources/library-inventory.json` line with `Resources/*-inventory.json` wildcard |
| `docs/test-live.md` | **Create** | New file; §F2 with ground-truth counts |
| `Scripts/plugin-live-e2e.sh` | Create | Executable bash + `chmod +x` |
| `Scripts/verify-test-count.sh` | Create | Baseline comparison script |
| `docs/tickets/plugin-preset-enumeration/TEST-BASELINE.txt` | Create | `swift test --list-tests | wc -l` captured at merge-base |
| `README.md` | Modify | Add plugin commands section |
| `docs/TROUBLESHOOTING.md` | Modify | Add Automation permission entry |
| `docs/API.md` | Modify | Add 4 command entries |
| `Tests/LogicProMCPTests/PluginRolloutTests.swift` | Create | 9 rollout tests |

### 4.2 Implementation Steps
1. Capture baseline: `swift test --list-tests | wc -l > docs/tickets/plugin-preset-enumeration/TEST-BASELINE.txt` (BEFORE making any code changes in this ticket)
2. Edit `.gitignore`: swap F1 specific line for wildcard
3. Verify `git check-ignore` covers both files
4. Create `docs/test-live.md` with templated structure
5. Write `Scripts/plugin-live-e2e.sh` using existing MCP stdio pattern (mirror `Scripts/live-e2e-test.sh` if present; this repo has `live-e2e-test.sh`)
6. Write `Scripts/verify-test-count.sh` comparing `swift test --list-tests | wc -l` vs baseline file
7. Update README.md + TROUBLESHOOTING.md + API.md sections
8. Run rollout tests locally

### 4.3 Refactor
- None

## 5. Edge Cases
- EC-1: E2E script run without Logic Pro → graceful skip message, exit 0 (not a CI failure)
- EC-2: `docs/API.md` already has library commands — new entries appended at existing format boundaries
- EC-3: Test baseline drift — if developer bumps baseline mid-feature, gate still valid (baseline + 50 check is absolute; monotonically increasing)

## 6. Review Checklist
- [ ] `.gitignore` wildcard covers BOTH library-inventory.json AND plugin-inventory.json (git check-ignore verification)
- [ ] `docs/test-live.md` created (previously non-existent)
- [ ] E2E script +x
- [ ] README + TROUBLESHOOTING + API.md all updated
- [ ] `Scripts/verify-test-count.sh` returns 0 with `baseline_count + 50` assertion
- [ ] 9 rollout tests PASS
