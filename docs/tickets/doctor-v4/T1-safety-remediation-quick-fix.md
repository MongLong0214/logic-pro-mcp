# T1: Safety / Remediation Quick Fix

**Priority**: P0
**Status**: Todo
**Depends On**: None

## Objective

Clean up immediately actionable v3 gaps before larger schema work: shell-quote command remediation, preserve `xattr` stdout/stderr evidence, source-aware remediation wording, unknown launch context not passing silently, and docs/renderer mismatch.

## Acceptance Criteria

- [ ] **Evidence-first rule (CTO)**: each of the five claimed v3 gaps is REPRODUCED against main with file:line + a failing red test before fixing; any item that cannot be reproduced is recorded as "claimed by review — not reproduced" and dropped from this ticket (no fixing phantom bugs).
- [ ] Command remediation that includes paths is shell-quoted.
- [ ] `xattr`/codesign-style command evidence preserves typed exit, stdout/stderr summary, and truncation metadata.
- [ ] Source-build users do not receive Homebrew-only remediation.
- [ ] Unknown launch context is not rendered as "fully known"; it remains honest and explanatory (render-level treatment — the check stays aggregate-neutral; no false-red for exotic hosts).
- [ ] Human renderer and docs describe the same next action.

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
