# T4: Install-Chain — N7 binary_inventory (`strings` ranking), N8 share_dir (V2 ship-list + Formula drift test)

**PRD Ref**: PRD-doctor-v3 > §4.2 (V2 ship-list), §4.3 N7/N8, §4.4 D2/D3, §4.5 #3 (D10), US-2/AC-2.1/2.2, US-1/AC-1.2, E5/E7/E17/E16
**Priority**: P1 (High) — this is the single highest-leverage undiagnosed failure (silent stale install)
**Size**: M
**Status**: Todo
**Depends On**: T2

---

## 1. Objective

Diagnose stale/shadowing installs and incomplete keg contents without ever executing a candidate binary: `install.binary_inventory` (N7) enumerates fixed canonical paths, reads each candidate's arch (`lipo`) + **static** version (`strings` exec-array, Swift-side ranking algorithm), and warns on a determinate version mismatch; `install.share_dir` (N8) compares the resolved share dir against the V2 ship-list constant, backed by a Formula drift test.

## 2. Acceptance Criteria

- [ ] AC-1 (N7 candidates, D3/NG4): candidates from **fixed** paths only — `/opt/homebrew/bin/LogicProMCP`, `/usr/local/bin/LogicProMCP`, and the **absolute** registered `command` (deduped; self excluded from the "differs" comparison). No `$PATH` walk. Each candidate must be `isRegularFile` (a directory is not a binary, #211); a relative/PATH-dependent registered command is excluded (evidence carries it out, as in N5).
- [ ] AC-2 (`strings` ranking, R7/D2): per candidate, arch via `lipo -archs`, version via `strings -a <path>` **exec-array** (never a shell pipe). Ranking in **Swift**: (1) collect lines matching `^[0-9]+\.[0-9]+\.[0-9]+$`; (2) drop `major == 0`; (3) dedup; (4) exactly one ⇒ adopt; (5) ≥2 distinct ⇒ **indeterminate** (no mismatch warn, evidence lists survivors); (6) zero ⇒ indeterminate.
- [ ] AC-3 (N7 status): `warn` iff any candidate's **determinate** version ≠ running version (AC-2.1 live: 3.5.0 vs 3.8.0); `pass` if consistent, indeterminate, or zero candidates (source build — evidence notes it). Indeterminate never false-`warn`s (false-red 0). evidence `{running_version, candidates:"path:arch:version | …", stale?, indeterminate?}`; remediation `command` (`brew upgrade`/reinstall).
- [ ] AC-4 (never execute, C4/NG7/D10): `lipo`/`strings` run via `BoundedProcessRunner` (≤1.5s) and are metadata-only (`file` tool은 D10 allowlist 밖 — 아치 판별은 `lipo -archs` 전담, PRD v0.2 micro-fix). **No candidate is ever handed to `runCommand` as an executable** — enforced by T1's `DoctorTool` allowlist (LogicProMCP is not a tool ⇒ fail-closed nil).
- [ ] AC-5 (N8 ship-list + drift, V2): a `sharedShipList` constant = the 9 Formula basenames (`SETUP.md`, `install-keycmds.sh`, `uninstall-keycmds.sh`, `keycmd-preset.plist`, `LogicProMCP-Scripter.js`, `logic_bounce.py`, `logic_bounce_ui.py`, `logic_ui_jxa.py`, `logic_input_source.py`) colocated with the V1 constants. A drift test greps `Formula/logic-pro-mcp.rb` text so the constant can't diverge (reuses the release-verify grep idiom).
- [ ] AC-6 (N8 status, R4): resolution order registered-env `LOGIC_PRO_MCP_SHARE_DIR` → brew `pkgshare` (both prefixes). `warn` listing missing basenames (live: 4 python helpers); `pass` if complete; `skipped reason=share_dir_unresolved` if neither resolves (source build); `skipped reason=share_dir_invalid` if a resolved path exists but is **not a directory** (`isDirectory` forced). evidence `{resolved_dir?, source?, missing_files?, reason?}`; remediation `command` (`brew reinstall`). N8 must **not** imply the server won't start (it's a bounce-feature precondition).
- [ ] AC-7 (positions + array +2): `install.binary_inventory` + `install.share_dir` inserted **after** `install.source` and **before** `release.signature`. Array grows by 2; counts bumped.

## 3. TDD Spec (Red Phase)

> New fixture seams (extend `enterpriseRuntime`/`doctorRuntime`): a canonical-path enumerator + per-candidate `strings`/`lipo` outputs, and a share-dir reader (`(path) -> [String]?` directory listing, `nil` = unresolved, plus an `isDirectory` flag). Reuse the existing `commandHandler` (SetupDoctorTests.swift:21-33) pattern to fake `lipo`/`strings` stdout. Fixture defaults: one canonical candidate matching running version, share-dir complete.
> **dead-`#expect` 금지** (R6): assert concrete statuses / evidence substrings.

### 3.1 Test Cases

| # | Test Name | Type | Invariant fixed | Expected |
|---|-----------|------|-----------------|----------|
| 1 | `test_t4_n7_pass_consistent_version` | Unit | AC-3 pass | candidate `strings` yields running version ⇒ `.pass` |
| 2 | `test_t4_n7_warn_stale_shadow` | Unit | AC-2.1 live | candidate yields `3.5.0` while running `3.8.0` ⇒ `.warn`; evidence `candidates` names both; `stale=="true"` |
| 3 | `test_t4_n7_ranking_drops_zero_major` | Unit | AC-2 step 2 / E7 | `strings` stdout `["0.0.0","3.5.0"]` ⇒ adopt `3.5.0` (drop `0.0.0`); mismatch warn if ≠ running |
| 4 | `test_t4_n7_indeterminate_two_semvers` | Unit | AC-2 step 5 | stdout has two distinct non-zero semvers ⇒ indeterminate; `.pass`, no mismatch warn; evidence `indeterminate` lists both |
| 5 | `test_t4_n7_indeterminate_zero_semvers` | Unit | AC-2 step 6 / E17 | non-Mach-O / stripped (no semver) ⇒ indeterminate; `.pass` |
| 6 | `test_t4_n7_source_build_zero_candidates_pass` | Unit | E5 | no canonical candidate exists ⇒ `.pass`; evidence notes zero candidates |
| 7 | `test_t4_n7_excludes_relative_registered_command` | Unit | AC-1 / E15 | registered command is relative ⇒ excluded from inventory (no CWD-relative resolve) |
| 8 | `test_t4_n7_directory_candidate_ignored` | Unit | AC-1 #211 | a path that is a directory ⇒ not treated as a candidate |
| 9 | `test_t4_n7_never_executes_candidate` | Unit | AC-4 / D10 | assert the fake `runCommand` is **never** called with a LogicProMCP path as executable (spy the command handler) |
| 10 | `test_t4_strings_ranking_pure_fn` | Unit | AC-2 pure parser | table-test the ranking function directly: `["0.0.0"]`→indeterminate; `["3.5.0"]`→`3.5.0`; `["3.5.0","3.5.0"]`→`3.5.0`; `["3.5.0","1.2.3"]`→indeterminate; `[]`→indeterminate |
| 11 | `test_t4_n8_warn_missing_files` | Unit | AC-6 live | share-dir missing the 4 python helpers ⇒ `.warn`; evidence `missing_files` lists their basenames |
| 12 | `test_t4_n8_pass_complete` | Unit | AC-6 | share-dir has all 9 basenames ⇒ `.pass` |
| 13 | `test_t4_n8_skipped_unresolved` | Unit | E5 | neither env nor pkgshare resolves ⇒ `.skipped reason=share_dir_unresolved` |
| 14 | `test_t4_n8_skipped_invalid_when_file_not_dir` | Unit | E16 | resolved path is a file, not a dir ⇒ `.skipped reason=share_dir_invalid` (no "everything missing" warn) |
| 15 | `test_t4_shiplist_matches_formula` | Contract | AC-5 drift | every `sharedShipList` basename appears in `Formula/logic-pro-mcp.rb` `pkgshare.install` lines (readRepoFile grep) |
| 16 | `test_t4_array_grows_by_two_install_chain` | Contract | AC-7 order | exact-id array places `install.binary_inventory`,`install.share_dir` between `install.source` and `release.signature` |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift` — cases 1–9, 11–14, 16.
- `Tests/LogicProMCPTests/SetupDoctorTests.swift` — cases 10 (pure fn) + 15 (drift, readRepoFile idiom) + array update. (Place the pure-fn/drift tests where the repo-root helpers already live.)

### 3.3 Mock / Setup Required
- `SetupDoctor.Runtime` new seams (default-valued `var`): `canonicalBinaryCandidates: () -> [String]` (default: one path == resolved self), `isRegularFile: (String) -> Bool` (reuse/extend the existing `isExecutableFile` sibling), `shareDirListing: (String) -> [String]?`, `shareDirIsDirectory: (String) -> Bool`. `lipo`/`strings` reached via the existing `runCommand` seam + `commandHandler` fake (return canned stdout keyed by `/usr/bin/lipo`,`/usr/bin/strings`).
- Spy pattern for case 9: wrap `commandHandler` to record executables; assert no LogicProMCP path appears.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change | Description |
|------|--------|-------------|
| `Sources/LogicProMCP/Server/ServerConfig.swift` | Modify | add `sharedShipList: [String]` (the 9 basenames) next to `LogicProSupport` |
| `Sources/LogicProMCP/Utilities/SetupDoctor.swift` | Modify | `Runtime` +seams; `binaryInventoryCheck`, `shareDirCheck`; pure `rankStringsVersions(_ lines:[String]) -> String?` (nil = indeterminate); insert 2 `timed { }` appends after `installSourceCheck` (generate :246); +2 anchor entries |
| Tests (2 files) | Modify | N7/N8 + ranking + drift + array |

### 4.2 Implementation Steps (Green Phase)
1. Add `sharedShipList` constant (colocated with `LogicProSupport`, added in T3 — coordinate file region).
2. `rankStringsVersions`: Swift regex `^[0-9]+\.[0-9]+\.[0-9]+$` over lines → drop `major==0` → `Set` dedup → `count == 1` ? adopt : nil. Pure + table-tested (case 10).
3. `binaryInventoryCheck`: build candidate list (canonical paths + absolute registered command, deduped); filter `isRegularFile`; per candidate call `runCommand("/usr/bin/lipo",["-archs",path])` + `runCommand("/usr/bin/strings",["-a",path])`, rank. Compare determinate versions to `ServerConfig.serverVersion`. Status per AC-3. Serialize `candidates` as `"path:arch:version | …"` (delimited, C7 redaction: `~`-abbreviate `$HOME`).
4. `shareDirCheck`: resolve env→pkgshare; if unresolved ⇒ `skipped share_dir_unresolved`; if resolved but `!isDirectory` ⇒ `skipped share_dir_invalid`; else diff listing vs `sharedShipList` → `warn`(missing) / `pass`. Note in summary that it's a bounce-feature precondition (not startup-blocking).
5. Insert appends after `installSourceCheck` (generate :246), before `releaseSignatureCheck`. Add anchors, bump array + count.

### 4.3 Refactor Phase
- One-time real `strings -a` timing on the 3.5.0 universal binary during T4 to confirm the ≤1.5s ceiling is comfortable (PRD §7 strategist-P3-E) — a manual/live note, not a unit test.

## 5. Edge Cases
- E5 source build (case 6/13); E7 `0.0.0`-only (case 3); E16 file-not-dir share (case 14); E17 non-Mach-O (case 5); E15 relative command (case 7); #211 directory candidate (case 8).

## 6. Review Checklist
- [ ] Red → Green → Refactor green
- [ ] Indeterminate version ⇒ **never** a mismatch `warn` (false-red 0)
- [ ] No candidate binary ever spawned (case 9 + D10 allowlist)
- [ ] `strings`/`lipo` are exec-arrays, no shell pipe; all filtering in Swift
- [ ] `sharedShipList` cannot silently diverge from the Formula (case 15)
- [ ] array/count +2; no dead-`#expect`

## 7. Out of Scope (explicit)
- **`mcp.registration_target` static version sniff** (N5) is **T5** (it reuses the same "never-execute + static sniff" doctrine but is a distinct check).
- **`$PATH` walk / `.logikcs` / MCU parse** — NG4.
- **No server runtime / health change** (NG3/NG1).
- **`DoctorTool` allowlist + `Process`-lint** are **T1**; T4 relies on them for AC-4.
