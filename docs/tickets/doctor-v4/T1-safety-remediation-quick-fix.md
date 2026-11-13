# T1: Safety / Remediation Quick Fix

**Priority**: P0
**Status**: Verified in working tree
**Depends On**: None

## Objective

Clean up immediately actionable v3 gaps before larger schema work: shell-quote command remediation, preserve `xattr` stdout/stderr evidence, source-aware remediation wording, unknown launch context not passing silently, and docs/renderer mismatch.

## Acceptance Criteria

- [ ] **Evidence-first rule (CTO)**: each of the five claimed v3 gaps is REPRODUCED against main with file:line + a failing red test before fixing; any item that cannot be reproduced is recorded as "claimed by review — not reproduced" and dropped from this ticket (no fixing phantom bugs).
- [x] Command remediation that includes paths is shell-quoted.
- [x] `xattr` command evidence preserves typed exit, stdout/stderr summary, and truncation metadata.
- [x] Source-build users do not receive Homebrew-only remediation.
- [x] Unknown launch context is not rendered as "fully known"; it remains honest and explanatory (render-level treatment — the check stays aggregate-neutral; no false-red for exotic hosts).
- [x] Human renderer and docs describe the same next action.

## Red Tests

- `doctorRemediationShellQuotesPaths`
- `doctorXattrEvidenceKeepsStdoutStderrSummary`
- `doctorSourceBuildDoesNotSuggestBrewUpgrade`
- `doctorUnknownLaunchContextIsNotSilentPass`
- `doctorRendererMatchesSetupDocsExample`

## Implementation Boundary

Likely files: `SetupDoctor+BinaryChecks.swift`, `SetupDoctor+InstallChecks.swift`, `SetupDoctor+LaunchContextSupport.swift`, `SetupDoctor+Rendering.swift`, `docs/SETUP.md`.

## QA Gate

Run focused doctor tests plus one local `doctor --json` smoke.

## Execution Notes

- Reproduced and fixed: path-bearing remediation quoting, source-aware stale binary inventory remediation, xattr command evidence stdout/stderr summaries and truncation metadata, explicit unknown-launch-context summary, and matching `docs/SETUP.md` remediation guidance.
- Already present and retained: source-build install-source classification precedence and `xattr` nonzero result handling.
- Process note: the implementation is covered by focused regression tests and full-suite verification, but strict red-before-green capture was not preserved for every original review claim; this gate is left unchecked for reviewer visibility.

## Verification

- `swift test --filter 'DoctorSourceBuild|DoctorRemediationShellQuotesPaths|DoctorXattrEvidenceKeepsStdoutStderrSummary|DoctorUnknownLaunchContext'`
- `swift test --no-parallel` (`2174` tests passed)
- `swift build -c release`
- `.build/release/LogicProMCP doctor --json`
- `git diff --check`
