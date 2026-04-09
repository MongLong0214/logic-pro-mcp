# T1: Signed Release Execution

**PRD Ref**: `PRD-production-hardening` > US-1  
**Priority**: P0  
**Size**: S  
**Status**: Blocked  
**Depends On**: None

---

## Objective

Execute the first real `v2.0.0` signed release and capture proof that the shipped artifact is codesigned, notarized, stapled, and Gatekeeper-valid.

## Current Blocker

- `gh auth status` is currently invalid for the configured default account in this environment
- No real GitHub tag push or workflow run can be executed until GitHub authentication is refreshed and the required release secrets remain configured
- Local `v2.0.0` already points to the current checked-in `HEAD`, while the latest release-readiness work is still local and uncommitted
- Before official release execution, the shipping tag/version for the current working tree must be decided explicitly instead of silently reusing the existing tag

## Acceptance Criteria

- [ ] Git tag `v2.0.0` is created and pushed
- [ ] `.github/workflows/release.yml` succeeds for that tag
- [ ] GitHub release assets include:
  - `LogicProMCP`
  - `LogicProMCP-macOS-universal.tar.gz`
  - `RELEASE-METADATA.json`
  - `SHA256SUMS.txt`
- [ ] Workflow logs show:
  - `codesign --verify` pass
  - notarization pass
  - stapling pass
  - `spctl --assess` pass
- [ ] Release evidence document references the real workflow run URL or artifact set

## Evidence

- Release workflow link
- Release assets list
- Updated `docs/release/RELEASE-EVIDENCE-*.md`

## Invalid Work To Avoid

- Do not ship an unsigned or locally copied binary as the official release
- Do not use mutable `latest` download paths as evidence
- Do not weaken signing/notarization checks to get a green workflow
