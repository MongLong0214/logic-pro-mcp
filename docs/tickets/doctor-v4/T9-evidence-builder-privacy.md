# T9: Evidence Builder / Privacy Hardening

**Priority**: P0
**Status**: Todo
**Depends On**: T8

## Objective

Centralize evidence serialization to prevent raw paths, stderr, env values, tokens, and secrets from leaking into doctor JSON.

## Acceptance Criteria

- [ ] Evidence builder supports typed values: bool, int, enum, version, path, basename, sensitive.
- [ ] Path evidence uses home-relative, basename, or hidden policy.
- [ ] Raw stderr/stdout is summarized and truncated with metadata.
- [ ] Env keys and token-like values are rejected or redacted.
- [ ] Privacy scan test covers live-ish doctor JSON.

## Red Tests

- `evidenceBuilderRedactsHomePathWhenPolicyHidden`
- `evidenceBuilderHomeRelativizesAllowedPath`
- `evidenceBuilderRejectsSensitiveRawValue`
- `doctorJSONPrivacyScanRejectsTokensAndEnvSecrets`
- `stderrEvidenceIncludesTruncationMetadata`

## Implementation Boundary

Likely files: new evidence builder, all SetupDoctor check extensions, privacy tests.

## QA Gate

Run focused doctor privacy tests and scan local `doctor --json` output.
