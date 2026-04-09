# T2: Clean-Machine Validation

**PRD Ref**: `PRD-production-hardening` > US-2  
**Priority**: P0  
**Size**: M  
**Status**: Blocked  
**Depends On**: T1

---

## Objective

Validate `Scripts/install.sh` and `Scripts/uninstall.sh` against the published `v2.0.0` release asset on both supported macOS runner families.

## Current Blocker

- `T1` has not yet produced the real signed/notarized/stapled `v2.0.0` release artifact
- This validation ticket remains intentionally blocked until the published release asset exists

## Acceptance Criteria

- [ ] Release workflow `validate-install` job passes on `macos-15`
- [ ] Release workflow `validate-install` job passes on `macos-13`
- [ ] Validation logs show:
  - pinned release download
  - SHA256 verification
  - Team ID metadata lookup
  - `codesign` verification
  - `spctl` assessment
  - isolated install path
  - uninstall cleanup
- [ ] At least one manual spot check is recorded on a fresh macOS machine, or a waiver with reason is documented in release evidence

## Evidence

- GitHub Actions install-validation logs
- Manual install/uninstall log capture if performed
- Updated release evidence document

## Invalid Work To Avoid

- Do not validate against a locally built binary when the goal is release-asset validation
- Do not widen support claims beyond `macos-15` and `macos-13` evidence without new runs
