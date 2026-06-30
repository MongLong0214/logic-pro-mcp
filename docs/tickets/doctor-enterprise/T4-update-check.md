# T4 — Opt-in Update Check (`--check-updates`)

**Size**: M
**Depends on**: T1 (model), T3 (flag plumbing)
**PRD ACs**: G2, US-6, AC-6.1–6.4, E6, E7, E11
**Files**: `Sources/LogicProMCP/Utilities/SetupDoctor.swift`, `Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift`

## Goal
Add `updates.latest_release` (category updates), emitted only under `--check-updates`, with a typed outcome
seam, bounded network, and enumerated-reason redaction.

## Design
- `enum UpdateOutcome { found(version: String), offline, sourceUnavailable, parseError, httpError, timeout }`.
- `Runtime.latestReleaseLookup: (() -> UpdateOutcome)?` — nil ⇒ check not emitted (AC-6.1).
- Production lookup (only constructed when `--check-updates` is passed):
  1. Primary: unauthenticated `curl -fsSL https://api.github.com/repos/MongLong0214/logic-pro-mcp/releases/latest`
     via `BoundedProcessRunner` (timeout 3.0s, **no** `-H Authorization`, no token). Parse `tag_name` from JSON.
  2. Fallback: `gh release view --repo MongLong0214/logic-pro-mcp --json tagName` (also bounded).
  3. Map: completed+parsed → `.found(tag)`; spawn-fail / no curl&gh → `.sourceUnavailable`;
     timeout → `.timeout`; network error / non-2xx → `.offline`/`.httpError`; bad JSON → `.parseError`.
  - Strip a leading `v` from tags before comparison; compare to `ServerConfig.serverVersion`.
- doctor check `updates.latest_release`:
  - `.found(latest)`: equal → pass (evidence `installed`,`latest`); installed < latest → warn (remediation:
    `brew upgrade logic-pro-mcp` / reinstall), evidence both versions.
  - any failure outcome → skipped, `evidence["reason"]` ∈ {offline, source_unavailable, parse_error, http_error,
    timeout}. **No** stderr/env/tokened-URL/headers in evidence (AC-6.4).
- Semantic version compare: reuse/extend existing version comparison if present; else a small numeric-3-part compare.
- A skipped update check degrades aggregate to `degraded` (documented AC-3.5; `aggregateStatus` untouched).

## TDD — Red first
1. `test_no_update_check_without_flag` (AC-6.1): runtime with `latestReleaseLookup == nil` → no
   `updates.latest_release` in checks.
2. `test_update_pass_when_current` (AC-6.2): lookup `.found(serverVersion)` → pass, evidence installed==latest.
3. `test_update_warn_when_behind` (AC-6.2): lookup `.found("99.0.0")` → warn + upgrade remediation + both versions.
4. `test_update_skipped_offline` (AC-6.3): `.offline` → skipped, `reason == "offline"`.
5. `test_update_skipped_parse` (E7): `.parseError` → skipped, `reason == "parse_error"`, never fail.
6. `test_update_skipped_timeout` (E11): `.timeout` → skipped, `reason == "timeout"`.
7. `test_update_evidence_redaction` (AC-6.4): for every failure outcome, evidence keys ⊆ {reason} (+ maybe a
   benign `checked` flag); assert no value contains "Authorization", "token", "http", "://?", or a raw stderr blob.
8. `test_update_skipped_degrades_aggregate` (AC-3.5): otherwise-ok report + skipped update → status degraded.
9. `test_update_version_compare`: 3.7.4 vs 3.7.4 equal; 3.7.4 vs 3.7.10 behind; leading-`v` stripped.

## Acceptance
- 15 checks with `--check-updates`; 14 without. All green `swift test --no-parallel`. No network in default run.
