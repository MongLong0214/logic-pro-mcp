# WS5: Utilities/Workflows/MIDI — FailureError enum + tri-state + SMFWriter + dedup

**PRD**: G1/G3, §3.2 WS5
**Priority**: P1 (tri-state honesty) | **Size**: M | **Risk**: L-M
**Owns (EXCLUSIVE)**: `Utilities/*` + `Workflows/*` + `MIDI/{SMFWriter, SMFWriter+TemporaryFiles, NoteSequenceParser, MIDIEngine, MIDIPortManager, MMCCommands, MCUTrace}.swift` + new test files `Tests/LogicProMCPTests/{PermissionCheckerTriStateTests,SMFWriterDenominatorTests}.swift` (WS5-created, excluded from WS8). MUST NOT touch `MIDI/{MCUFeedbackParser, MIDIFeedback, MCUProtocol}` (WS6), HonestContract callers in dispatchers, or existing test files.
**Parallel-safe with**: WS1/2/3/4/6/7.

## 1. Objective
String-back the 45-case FailureError, fix the PermissionChecker tri-state honesty gap and SMFWriter denominator landmine, decompose the 300-line audit method, dedup remediation infra — behavior-preserving.

## 2. Acceptance Criteria
- AC1: `HonestContract.FailureError` (~45 assoc-value-free cases + 45-line manual `rawValue` switch) → String-backed enum (`case axWriteFailed = "ax_write_failed"`, delete switch, add `init?(rawValue:)`). **Literals byte-identical** (HonestContractTests pins). Keep `UncertainReason` manual (has `echoTimeout(ms:)`). This is P1-1 — no dispatcher edits (NG11 defers P2-3).
- **AC2 [P1 honesty]**: PermissionChecker `runAutomationProbeViaShell` (:187-203) returns tri-state `CheckState` (not Bool) — currently collapses `.timedOut`/`.spawnFailed`/denial → false "Automation NOT GRANTED"; sibling :205-227 already does it right (#188). Match the sibling.
- **AC3 [latent correctness]**: SMFWriter denominator (:31) — `ticksPerBeat = ticksPerQuarter*4/denominator; barOffsetTicks=(bar-1)*numerator*ticksPerBeat` (was assuming denom=4; 6/8 → 2× off). Unreachable today (caller hardcodes 4/4) — grep tests for a pinned wrong bar-offset value FIRST. Also guard `Int(60M/bpm)` (bpm≤0/NaN trap, :126) + `UInt8(numerator)` (>255 trap, :153) defensively (audit #23).
- AC4: ProjectSessionAudit `deterministicFindings` (:433-732, ~300 lines) → extract systemFindings/trackFindings/exportFindings/markerFindings/mixerFindings → concat → existing id-sort:382. Pure extraction (order-normalized by id-sort).
- AC5: SetupDoctor `requireBinary()` helper (dedup the ×4 binary-resolve guard :402/423/474/509). SetupDoctor↔SetupLifecycle remediation infra (RemediationType/Remediation/anchors) → shared type (SetupDoctor has extra `systemSettings` case — preserve both JSON shapes). INSTALL_DIR env L1 ownership+location allowlist (SetupLifecycle:599, matching library-inventory pattern).
- AC6: BoundedProcessRunner `String(data:.utf8)` → `String(decoding:as:UTF8.self)` (:108, was nilling whole buffer on mid-multibyte cut → dropped Korean). Add escalation logging (:90-101, SIGTERM→SIGKILL currently silent). Shared `AppleScriptSafety.escapeForScript` (dedup the `\`/`"` escape at ProcessUtils:194/PermissionChecker:188/AppleScriptChannel:765/794 — WS5 defines it in Utilities; AppleScriptChannel is WS2 — **coordinate: WS5 adds the shared fn, WS2 call-sites reference it → sequence WS5 before WS2's escape dedup, OR WS2 leaves its escape as-is this sweep**). DestructivePolicy raw-JSON → shared layer. Delete unconsumed MIDIEngine.inboundMessages (audit concurrency #3) or wire it; delete dead MMC strict-locate tier if truly unreachable (audit #22 — verify).
- AC7: `swift test --no-parallel` green; golden-snapshot diff = 0 for FailureError rawValues + HC envelopes (String-enum produces identical tokens). **EXCEPTION (boomer ticket-R1 #4, G6-a)**: the PermissionChecker tri-state fix (AC2) is an intended observable honesty correction to `--check-permissions`/`logic_system health`/doctor output for the probe-FAILURE case only (grant/deny unchanged) — a constrained doctor/health/permissions snapshot allowlist permits that field's change; grant/deny paths must still diff = 0. Documented by WS9 in CHANGELOG + SECURITY/TROUBLESHOOTING.

## 3. TDD / Verification
- FailureError: HonestContractTests must stay green (they pin every rawValue string); golden HC State C envelopes diff = 0.
- PermissionChecker tri-state: test `.timedOut`/`.spawnFailed` → NOT "granted" AND NOT a false "NOT GRANTED" denial (returns the honest notVerifiable state).
- SMFWriter denominator: unit test 6/8 bar offset = correct (RED on current); confirm no existing test pinned the wrong value.

## 4. Constraints
- FailureError rawValues MUST match the current switch exactly (any drift = wire change). Diff the generated strings.
- Shared-escape cross-WS coordination (AC6): to stay conflict-free, WS5 ADDS `escapeForScript` to AppleScriptSafety (Utilities/, WS5-owned); WS2 either references it (sequence WS5→WS2) or defers its escape dedup. Default: **WS5 adds it, WS2 defers escape-dedup to avoid the cross-edit** — record which.
- Commit per unit.

## 5. Review Checklist
- [ ] FailureError String-enum, rawValues byte-identical (HonestContractTests green, HC golden diff = 0)
- [ ] PermissionChecker tri-state + test
- [ ] SMFWriter denominator + trap guards + test (no pinned-wrong-value)
- [ ] deterministicFindings decomposed; requireBinary + remediation dedup; INSTALL_DIR allowlist
- [ ] BoundedProcessRunner UTF8 + logging; dead code resolved
- [ ] Full suite green; MCU MIDI files + dispatchers untouched
