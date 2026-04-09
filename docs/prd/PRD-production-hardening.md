# PRD: Production Hardening — Final Release Readiness

**Version**: 1.0  
**Date**: 2026-04-06  
**Status**: Active  
**Supersedes**: `PRD-production-hardening` v0.2  
**Size**: M

---

## 1. Summary

The original production-hardening backlog was written as a code-fix epic. That is no longer the correct framing.

The current repository already contains the major code-level hardening work:
- build/test/coverage gates are in place
- channel readiness gating is implemented
- manual approval flow exists for `MIDIKeyCommands` and `Scripter`
- release workflow includes codesign/notarization/stapling steps
- install/uninstall and release runbooks already exist

The remaining valid work is not "more code hardening." It is **release execution, clean-machine validation, real Logic Pro E2E validation, and evidence closure**.

This PRD replaces the earlier backlog and removes obsolete or already-implemented fix work from active scope.

## 2. Product Decisions

- **Release tag target**: `v2.0.0`
- **Supported macOS**: `14+`
- **Supported Logic Pro**: `12.0.1+`
- **Supported architectures**: `arm64`, `x86_64`
- **Manual validation channels remain manual by design**:
  - `MIDIKeyCommands`
  - `Scripter`
- **MCU registration remains an operator-run Logic Pro setup step**. We do not treat brittle UI scripting of Logic Pro internal configuration as a shippable requirement.

## 3. Goals

- G1: Produce one real signed, notarized, stapled release for `v2.0.0`
- G2: Validate installer and uninstaller against the published release asset on both supported macOS runner families
- G3: Validate a real Logic Pro session end-to-end with required manual setup complete
- G4: Freeze release evidence, support matrix, and operator runbooks so launch status is auditable
- G5: Preserve existing green engineering gates:
  - `swift build -c release`
  - `swift test`
  - `swift test --enable-code-coverage --no-parallel`

## 4. Non-Goals

- NG1: Do not reopen previously completed code-hardening tickets unless a new reproducible release blocker is found
- NG2: Do not add new MCP tools or widen the public contract
- NG3: Do not attempt full automation of Logic Pro internal setup via brittle UI scripting
- NG4: Do not widen the support matrix beyond `macOS 14+`, `Logic Pro 12.0.1+`, `arm64/x86_64` without fresh validation evidence
- NG5: Do not create speculative refactors unrelated to release readiness

## 5. Baseline Already Achieved

These are no longer active backlog items:

- Source coverage gate is already above the required floor
- Router honors `ready` state and excludes `manual_validation_required` channels unless explicitly allowed
- Manual approval persistence exists for `MIDIKeyCommands` and `Scripter`
- Release workflow requires signing/notarization secrets
- Installer verifies pinned release artifacts, SHA256, code signature, and Gatekeeper
- Release, clean-machine, operator-approval, and E2E runbooks already exist

Because this baseline is already present, the old T1-T10 code-fix backlog is retired from active execution.

## 6. User Stories & Acceptance Criteria

### US-1: Signed Release Execution
**As a** release owner, **I want** one real `v2.0.0` signed release to complete successfully, **so that** the shipping artifact is provenance-backed rather than locally assumed.

**Acceptance Criteria**
- AC-1.1: GitHub Actions release workflow completes successfully for tag `v2.0.0`
- AC-1.2: Release assets include:
  - `LogicProMCP`
  - `LogicProMCP-macOS-universal.tar.gz`
  - `RELEASE-METADATA.json`
  - `SHA256SUMS.txt`
- AC-1.3: Workflow evidence shows:
  - codesign verification passed
  - notarization passed
  - stapling passed
  - `spctl` assessment passed
- AC-1.4: No mutable `latest` release path is used in release validation

### US-2: Clean-Machine Install Validation
**As a** release owner, **I want** install/uninstall validation on both supported runner families, **so that** the published installer is proven against real release assets.

**Acceptance Criteria**
- AC-2.1: Release workflow `validate-install` job passes on:
  - `macos-15`
  - `macos-13`
- AC-2.2: Validation logs demonstrate:
  - pinned release download
  - SHA256 verification
  - Team ID metadata lookup
  - `codesign` verification
  - `spctl` assessment
  - isolated install path
  - uninstall cleanup
- AC-2.3: At least one manual spot check is recorded on a fresh macOS machine, or explicitly waived with reason in release evidence

### US-3: Live Logic Pro E2E Validation
**As an** operator, **I want** one real Logic Pro session validated with the supported setup path, **so that** runtime claims match actual DAW behavior.

**Acceptance Criteria**
- AC-3.1: `LogicProMCP --check-permissions` reports:
  - `Accessibility: granted`
  - `Automation (Logic Pro): granted`
- AC-3.2: Logic Pro manual setup is completed:
  - MCU device registered with `LogicProMCP-MCU-Internal`
  - Scripter inserted on target track
  - Key Commands preset imported
- AC-3.3: Operator approvals are recorded:
  - `LogicProMCP --approve-channel MIDIKeyCommands`
  - `LogicProMCP --approve-channel Scripter`
  - `LogicProMCP --list-approvals`
- AC-3.4: `logic_system.health` confirms runtime-ready state for the expected channels, including MCU connected/registered
- AC-3.5: The following live operations are executed successfully and captured as evidence:
  - `logic_transport.play`
  - `logic_transport.stop`
  - `logic_transport.record`
  - `logic_tracks.select`
  - `logic_tracks.set_automation` with `trim`
  - `logic_mixer.set_volume`
  - `logic_mixer.set_pan`
  - `logic_mixer.set_plugin_param`
  - `logic_edit.undo`

### US-4: Evidence & Docs Freeze
**As a** maintainer, **I want** all release-facing docs to reflect the real validated state, **so that** commercial launch status is auditable and unambiguous.

**Acceptance Criteria**
- AC-4.1: `docs/release/RELEASE-EVIDENCE-*.md` is updated with the actual release tag, workflow result, and validation evidence
- AC-4.2: `docs/release/SUPPORT-MATRIX.md` matches the final supported scope:
  - macOS `14+`
  - Logic Pro `12.0.1+`
  - `arm64`, `x86_64`
- AC-4.3: `README.md` and release runbooks do not promise automation that the product cannot safely guarantee
- AC-4.4: Manual setup and operator-approval steps are documented once and referenced consistently

## 7. Invalid Work Explicitly Filtered Out

The following work items are not valid active backlog for this PRD:

- Reopening earlier AppleScript/MIDI/@MainActor/JSON/bounds tickets without a new repro
- Treating fully automatic Logic Pro internal setup as a requirement
- Adding new MCP features under the label of "hardening"
- Changing the support matrix without new validation evidence
- Replacing the operator-approval model for `MIDIKeyCommands` or `Scripter`

## 8. Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Release secrets unavailable or invalid | Medium | High | Fail fast in workflow and do not mark release ready without real run |
| Logic Pro UI/setup differs slightly across machines | Medium | Medium | Keep MCU/Key Commands/Scripter setup as manual operator workflow with evidence capture |
| Intel validation unavailable locally | High | Medium | Treat GitHub Actions `macos-13` run as required release evidence |
| Live E2E passes locally but evidence is not recorded | Medium | Medium | Make release-evidence update a blocking ticket |

## 9. Ticket Map

| Ticket | Title | Priority | Outcome |
|--------|-------|----------|---------|
| T1 | Signed Release Execution | P0 | Real signed/notarized `v2.0.0` release |
| T2 | Clean-Machine Validation | P0 | Installer/uninstaller validated on `macos-15` and `macos-13` |
| T3 | Live Logic Pro E2E Validation | P0 | Real session validated with MCU + approvals |
| T4 | Evidence & Docs Freeze | P1 | Final evidence pack and launch docs aligned |

## 10. Exit Criteria

This PRD is complete only when all of the following are true:

- `v2.0.0` signed release exists
- release workflow is green
- clean-machine validation is green on both runner families
- live Logic Pro E2E evidence exists
- MCU is validated in a real session
- `MIDIKeyCommands` and `Scripter` approvals are recorded after manual verification
- release evidence and support docs are updated to match reality

## 11. Open Questions

- None for scope. Remaining work is execution and evidence collection, not product definition.
