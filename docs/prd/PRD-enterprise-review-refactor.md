# PRD: Enterprise-Grade Review & Refactor Sweep (v3.8.0)

**Version**: 0.4 (post boomer PRD R3 — value-only extractTrackState, no type change)
**Author**: Fable 5 (scope/decisions) — implementation by Opus/Sonnet agents
**Date**: 2026-07-05
**Status**: Approved (boomer CONVERGED R4, 2026-07-05)
**Size**: XL
**Baseline**: main `7bb8bf3`, v3.7.4, 1980 tests green (`swift test --no-parallel`), 0 open GitHub issues.
**Branch**: `chore/enterprise-review-refactor-v3.8.0` (worktree `logic-pro-mcp-refactor`).

---

## 1. Problem Statement

### 1.1 Background
Two review rounds, all read-only:
- **Round 1** (5 domain reviewers, capped): structure/dup/consistency across the whole tree.
- **Round 2** (3 cap-free deep audits): security (whole codebase + 11 scripts + Formula + 3 CI workflows), Swift-6 concurrency (every actor/Task/Sendable), and completeness+adversarial (100% of the files round 1 skipped + empirical re-verification of round-1 claims).

Verdict: the codebase is **mature, crash-hardened** (zero `fatalError`/`try!`/`print`; guarded downcasts; bounds-checked input) and **security-clean at the MCP boundary** (0 Critical/High reachable by an untrusted client). Findings: `docs/tickets/enterprise-refactor/REVIEW-FINDINGS.md` + `AUDIT-ROUND2.md`.

### 1.2 Problem Definition
Bring the codebase to enterprise standard **without changing external behavior**: fix the real defects (a P0 crash, a P1 concurrency race across 2 sites, honesty-contract gaps, a supply-chain CI injection), split the God objects, kill the reviewed duplication/dead code, make the test suite actually assert what it claims (~356 dead assertions), align every user-facing doc with the shipped code — then release v3.8.0.

### 1.3 Impact of Not Solving
- **P0 SIGPIPE**: a client disconnecting mid-write kills the server before the #220 EPIPE path runs (empirically proven fatal).
- **~356 dead test assertions** (2× the round-1 estimate; the `#expect` macro treats `Bool == Bool` as always-pass, incl. non-optional) — CI is green on assertions that test nothing, including the fail-closed/honesty guards the product sells.
- **MCU feedback race (2 sites)**: out-of-order parser state → false State A/B on MCU-verified ops.
- **`logic://tracks` fabricates volume/pan/automationMode** — an honesty-contract breach on a public resource.
- **CI `publish-mcp.yml` script injection** — a crafted release tag runs arbitrary code under the project's OIDC identity.
- Two God objects (5.4k/1.8k LOC) inflate every future change's risk; stale docs mislead users.

## 2. Goals & Non-Goals

### 2.1 Goals
- G1 [correctness/security] Fix: P0 SIGPIPE; MCU 2-site ordering race (+ bank-offset + conn-atomic + MIDIFeedback status-byte); PermissionChecker tri-state; `extractTrackState` fabricated data; AXHelpers unguarded downcast; NavigateDispatcher marker pre-poll; SMFWriter denominator+traps; release.sh Formula-sha verify; **CI M1 publish-mcp injection + M2 /private install bypass + CI least-privilege/pin**; L1 env-exec allowlist; L2 /tmp debug log.
- G2 [structure] Split God objects behavior-preservingly: `AccessibilityChannel` 5369→~800 (8 ext, ~24 private→internal), `AXLogicProElements` 1799→~500 (6 ext), `ResourceHandlers` 1466 (4 ext), `TrackDispatcher.record_sequence` 620 (1 ext).
- G3 [dedup/dead] Route stragglers through existing helpers; hoist triplicates; delete confirmed dead code (lastBothScan, findTrackOutline, unconsumed inbound stream, etc.); centralize AXLocalePolicy bypasses; FailureError String-backed enum; deterministicFindings decompose; shared AppleScript escape.
- G4 [test integrity] Convert all ~356 dead assertions to live (5 optionality-dependent transforms + a per-assertion ledger + flip/fault-injection proof on safety-critical files); add mutation-gate completeness test + BoundedProcessRunnerTests; promote FakeAXRuntimeBuilder AX helpers; remove JSON-helper clones.
- G5 [docs] README/CHANGELOG/CONTRIBUTING/SECURITY/docs(API·SETUP·TROUBLESHOOTING) exactly match shipped code (mixer "send" removal, fader/pan channel, test counts, E2E numbers, version anchors).
- G6 [safety gate] **Zero external-behavior change, with TWO documented honesty corrections** (boomer PRD-R2 #1, R3 #1, ticket-R1 #4). **Correction (a) — permission-probe tri-state (WS5)**: `runAutomationProbeViaShell` currently collapses `.timedOut`/`.spawnFailed` into a false "Automation NOT GRANTED"; the fix reports the honest `notVerifiable` tri-state (matching the #188 sibling), changing `--check-permissions`/`logic_system health`/doctor output ONLY for the probe-failure case (grant/deny unchanged); gated by a constrained doctor/health/permissions snapshot allowlist; documented in CHANGELOG + SECURITY/TROUBLESHOOTING. **Correction (b) — `logic://tracks` value-only**: the `logic://tracks` + `logic://tracks/{index}` honesty correction — `volume`/`pan`/`automationMode` currently report FABRICATED `0.0`/`0.0`/`.off`; the fix makes them report the REAL track-header values that already exist and are read elsewhere (`findTrackHeaderVolumeFader`/`findTrackHeaderPanControl` + the track-header automation group). **NO type/schema change**: the fields stay non-optional `Double`/`Double`/enum — NO nullable, NO sentinel, NO new enum case, NO omitted key, NO NaN. The struct is unchanged; only the *values* stop being fabricated. On the rare AX-read failure the existing default is retained (unchanged from today), and the resource's existing `source`/`ax_occluded` fields already signal a degraded read — so no NEW unreadable path is introduced. This is the only intended observable change. Proven by: `swift test --no-parallel` green after each ticket + **golden byte-snapshots** (tool descriptors, unknown-command/invalid-param errors, representative HC envelopes, route mappings, resource URIs) captured pre-refactor and diffed post — diff must be `0` EXCEPT a constrained value-only allowlist for those 3 track-resource fields (type/key/enum-domain diff must still be `0`) — + strict live E2E parity + a broad live-surface baseline↔post diff (§5).
- G7 Ship **v3.8.0** (minor: substantial internal hardening + test integrity + docs + security fixes; no public tool/resource/template surface change — the `extractTrackState` correction is VALUE-ONLY with the struct/schema/enum-domain unchanged, so it is a minor-appropriate honesty fix, NOT a schema/migration/type change; documented in CHANGELOG + API.md; bundles merged #234).

### 2.2 Non-Goals (EXCLUDED — HIGH RISK / low-value / out of scope; each with reason)
- NG1 HC-surface normalization (CoreMIDI/MCU free-form vs AppleScript envelopes) — wire change, dozens of ops. DEFER.
- NG2 HC v1→v2 unification — test-enforced (HonestContractV2Tests:151/157), BREAKING. DEFER.
- NG3 same-failure-two-codes (`.axWriteFailed` vs `.portUnavailable`) — wire change. DEFER.
- NG4 AX-main blocking-sleep→async — synchronous AX Runtime closures; async ripple = systemic H risk. DEFER.
- NG5 Monster-function internal phase-extraction (defaultInsertVerified 465, defaultImportMIDIFile 418, setTrackInstrument 380) — logic re-arrangement, not a pure move. File-split solves size; internals DEFER.
- NG6 StockPluginCatalog JSON externalization — already data-driven; externalizing loses compile-time safety + zero-dep deploy. DO NOT.
- NG7 Removing reserved wire fields (spectralCentroidHz/frequencyPeaks) — declared v1 schema. Leave + document.
- NG8 New feature/tool/resource/template.
- **NG9 [new] Cooperative-pool blocking sweep** (setTempo 370ms / runLiveScan 50s / AppleScript-on-pool) — MEDIUM risk, wide, NOT correctness (mitigated: mutation-gate serializes, reads don't sleep, stdio+deadline off-pool). Concurrency audit + boomer both flag as risky-wide. DEFER (follow-up issue).
- **NG10 [new] CGEvent async-sleep** (postShortcutSequence) — naive Task.sleep introduces actor reentrancy → concurrent goto_position keystroke interleave (boomer PRD #2). DEFER unless done as a serialized key-worker (out of scope this sweep).
- **NG11 [new] P2-3 bespoke-error-string→FailureError** — would edit HonestContract (WS5) AND Track/ProjectDispatcher (WS4) = cross-workstream coupling for a documented-terminal, non-bug consistency nit. DEFER.
- **NG12 [new] LogicProServer deadline-race dedup (round-1 #10)** — load-bearing #112/#199 concurrency backstop; boomer "own commit, last." DEFER.

## 3. Technical Design

### 3.1 Constraints (verified)
- `Package.swift` auto-globs `Sources/LogicProMCP` + `Tests/LogicProMCPTests` (no `sources:` list) → adding/moving/git-mv `.swift` needs NO manifest edit.
- **Actor private-visibility rule**: cross-file extensions can't see an actor's `private` stored state. AccessibilityChannel: keep 9 private stored props + 4 private instance scan-orchestrators + `execute()` in CORE; promote ~24 private statics to internal (21 execute-referenced + 3 cross-boundary: `encodeResult`, `menuItem`, `verifyTrackSelection`); ~40 already internal.
- **`#expect(Bool == Bool)` is DEAD** at the pinned toolchain (Swift 6.2.4) — empirically proven twice. Only bare `#expect(x)`/`#expect(!x)`/`#expect(x!)` assert.
- Every refactor behavior-preserving; `swift test --no-parallel` (CI-authoritative) green after each ticket.

### 3.2 Workstream decomposition (file-atomic ownership; verified conflict-free)
Round-2 confirmed the ONLY cross-directory extension is `extension LogicProServer` declared in `MainEntrypoint.swift` (root) → root entrypoints belong to the Server owner. MCU fix spans 3 files across dirs → made ONE atomic workstream. No file is edited by two workstreams.

**Phase 1 — production source (parallel, disjoint file sets):**
- **WS1** `Channels/AccessibilityChannel.swift` + new `AccessibilityChannel+{Transport,Tracks,Mixer,Plugins,Library,Regions,MIDIImport,Project}.swift` — 8-ext split (~24 promotions; `encodeResult`→`+Shared`/Core), dead `lastBothScan` delete, `scanInProgress`→two flags, `encodeOrError`/`encodeResult` merge, State-C typed-helper port. (Does NOT touch +VerifiedPlugins beyond compile.)
- **WS2** `Channels/{AppleScript,CoreMIDI,MIDIKeyCommands,Scripter,CGEventChannel,ChannelRouter,Channel}.swift` — CoreMIDI param→Result(.error not throw), catch-block helpers, AppleScript static/instance dedup + `iso8601String` static, ChannelRouter table→`RoutingTable.swift`, Scripter/MIDIKeyCommands shared keycmd protocol (preserve RoutingAuditInvariant log strings). (CGEvent: NG10, untouched.)
**Test-ownership rule (boomer ticket-R1 #2)**: each Phase-1 WS CREATES and owns its OWN NEW regression test file(s) (TDD, atomic with the feature) and MUST NOT edit any EXISTING test file. WS8 owns all EXISTING `Tests/*` (dead-assertion sweep) + WS8's own new safety files + the ledger, EXCLUDING the Phase-1-created files. This keeps every test file single-owner.

- **WS3** `Accessibility/{AXLogicProElements(6-ext split), AXHelpers(downcast guard), AXValueExtractors, AXLocalePolicy(library/marker/cancel labels), PluginInspector(→AXHelpers), LibraryAccessor(triplicate hoist + cliclick→native + L2 /tmp + library label), LibraryDiskScanner, AXMouseHelper}` + `Resources/ResourceProvider.swift` (extractTrackState caller) + `Plugins/{StockPluginCatalog optional +split, VerifiedPluginCatalog doc}` + `Audio/AudioAnalyzer(AnalysisPolicy.default)` + new test files `Tests/LogicProMCPTests/{ExtractTrackStateHonestyTests,AXHelpersDowncastGuardTests}.swift`. **extractTrackState honesty fix (G6 exception, VALUE-ONLY — boomer R3 #1)**: read REAL track-header volume/pan (findTrackHeaderVolumeFader/PanControl, already exist) + automationMode (track-header automation group desc). **DO NOT change the TrackState type**: volume/pan stay non-optional `Double`, automationMode stays its current enum with NO new `.unknown` case — no sentinel, no nullable, no omitted key. On the rare AX-read failure, RETAIN the existing default (same as today) rather than introducing any new unreadable representation; the resource's existing `source`/`ax_occluded` already flags degraded reads. `sampleRate` is project-level, currently fabricated 44100 at track layer — leave AS-IS this sweep (changing it would need a type/source decision); document the limitation. Live-verify real volume/pan/automationMode on 12.3. Also slider fail-closed + track-type LabelSet. LibraryNode triplicate → shared extension. Delete dead `findTrackOutline`, `pressDelete`, `setNormalizedSliderValue`. **NOTE: ResourceProvider.swift is owned ONLY by WS3 (extractTrackState wiring), excluded from WS4's Resources/*.**
- **WS4** `Dispatchers/*` (excl. LogicProServer) + `Resources/*` (EXCEPT ResourceProvider.swift → WS3) + `State/{StatePoller,StateModels}.swift` (**NOT StateCache.swift → WS6**, boomer ticket-R1 #1) + `Server/{ServerConfig,SerializedStdioTransport}` + `Projects/*` + `main.swift` + `MainEntrypoint.swift` + new test file `Tests/LogicProMCPTests/SIGPIPERegressionTests.swift` — **SIGPIPE fix** (SerializedStdioTransport+MainEntrypoint), ResourceHandlers 4-ext split, record_sequence→+ext, create_*/toggle helpers, inline verified-parse→`channelResultIsVerified` (resolves that dead helper), 50× `invalidParamsResult`→canonical, StatePoller generic poll, NavigateDispatcher marker pre-poll, PluginsDispatcher trim-fix, DispatcherSupport stringParam alias-guard, StateModels MCU structs→Codable, **`Projects/ProjectExport*` bounce-helper python3 PATH + BOUNCE_HELPER L1 ownership allowlist + export dialog preflight** (boomer PRD-R2 #2 — Projects/* now explicitly owned here, no other WS touches them). **Does NOT touch LogicProServer.swift (WS6) or ResourceProvider.swift (WS3).**
- **WS5** `Utilities/*` + `Workflows/*` + `MIDI/{SMFWriter,NoteSequenceParser,MIDIPortManager,MIDIEngine,MMCCommands,MCUTrace}` + new test files `Tests/LogicProMCPTests/{PermissionCheckerTriStateTests,SMFWriterDenominatorTests}.swift` — FailureError String-backed enum (P1-1), deterministicFindings decompose, SetupDoctor requireBinary + tri-state PermissionChecker + INSTALL_DIR L1 allowlist, remediation-infra dedup (SetupDoctor↔SetupLifecycle shared type), SMFWriter denominator + bpm/numerator trap guards, BoundedProcessRunner UTF8 decode + escalation logging, shared AppleScriptSafety escape, DestructivePolicy JSON via shared layer, delete unconsumed MIDIEngine.inboundMessages, dead MMC tier. **Does NOT touch MCUFeedbackParser/MIDIFeedback/MCUProtocol (WS6).**
- **WS6 [MCU pipeline — ATOMIC]** `Channels/MCUChannel.swift` + `Server/LogicProServer.swift` (MCU fan-out :1051) + `MIDI/{MCUFeedbackParser,MIDIFeedback,MCUProtocol}.swift` + `State/StateCache.swift` (boomer ticket-R1 #1 — AC3 adds `updateMCUConnection(mutator:)`; WS4 MUST NOT touch it) + new test files `Tests/LogicProMCPTests/{MCUFeedbackOrderingTests,MIDIFeedbackStatusByteTests}.swift` — replace BOTH per-event `Task{}` fan-outs with ONE ordered AsyncStream single-consumer (start/cancel lifecycle), bank-offset master-fader fix, conn atomic mutator, MIDIFeedback System-Common/RT status-byte handling, delete dead MCUProtocol handshake. Owns ALL of LogicProServer.swift so WS4 never touches it.
- **WS7** `Scripts/*.sh` + `.github/workflows/*` + `Formula/*` — release.sh Formula-sha `grep -Fq` verify + no-op-commit guard, install-common validate_share_dir symmetry + M2 /private realpath blocklist, **M1 publish-mcp.yml env-indirection**, CI least-privilege + SHA-pin checkout, release.yml env over ref_name.

**Phase 2 — tests (after Phase-1 fully merged + green). Owns EXISTING `Tests/*` + `docs/tickets/enterprise-refactor/DEAD-ASSERTION-LEDGER.md`, EXCLUDING the Phase-1-created files (SIGPIPERegressionTests, MCUFeedbackOrderingTests, MIDIFeedbackStatusByteTests, ExtractTrackStateHonestyTests, AXHelpersDowncastGuardTests, PermissionCheckerTriStateTests, SMFWriterDenominatorTests). Split into 3 sub-units run SEQUENTIALLY by one agent (boomer ticket-R1 #5 — split is for review units, NOT parallelism; test files cross-cut):**
- **WS8c** (FIRST) — FakeAXRuntimeBuilder AX-helper promotion (into AccessibilityTestSupport.swift) + JSON-helper clone removal (→ sharedToolText/sharedJSONObject). Done first so the shared helpers exist before the assertion sweep touches the same files.
- **WS8a** (SECOND) — ~356 dead-assertion sweep across existing files (per-assertion LEDGER: file/orig-expr/static-type/nil-rule/replacement) + flip/fault-injection proof on safety-critical files.
- **WS8b** (THIRD) — new safety coverage in NEW files: mutation-gate completeness test, BoundedProcessRunnerTests, StateModels Codable round-trip (+ SIGPIPE regression if WS4 didn't add it).

**Phase 3 — docs (overlaps Phase 2):** **WS9** all user-facing md (§ Goals G5).

### 3.3 Key Decisions
| # | Decision | Rationale |
|---|----------|-----------|
| D1 | God-object split = pure file-move only | L-risk, compiler-verified; internals = NG5 |
| D2 | Tests (WS8) after source merges | one agent per test file; WS8 sees final assertions (incl. Phase-1-touched) |
| D3 | MCU fix = one atomic workstream (WS6) owning all of LogicProServer.swift | fix spans 3 dirs; ordering pipeline must be coherent; prevents WS4/WS6 file collision |
| D4 | Dead-assertion: per-case transform + LEDGER + flip-test on safety-critical | boomer #3: wrong optional transform can pass while asserting wrong nil semantics |
| D5 | Golden byte-snapshots pre/post for wire-sensitive refactors | boomer #4: tests can pass while strings/envelopes/routes drift; also = the broad behavior-preservation E2E the user asked for |
| D6 | Exclude NG9-12 (cooperative-pool, CGEvent-async, P2-3, deadline-dedup) | MEDIUM-risk-wide or cross-workstream or load-bearing; enterprise ≠ risky rewrite |
| D7 | v3.8.0 minor | internal + test + docs + security, zero public surface change |

## 4. Edge Cases & Risk
| # | Scenario | Mitigation |
|---|----------|------------|
| E1 | Split moves a test-pinned func | 39 pinned names resolve by type not file; full suite per split |
| E2 | Dead-assertion transform turns a test RED (latent bug surfaces) | GOAL — investigate each; never paper over |
| E3 | Wrong optional transform passes but asserts wrong nil-semantics | D4 ledger + flip/fault-injection on safety-critical files |
| E4 | Wire drift passes existing tests | D5 golden snapshots diffed pre/post |
| E5 | MCU stream fix leaks task / drops echo / breaks lifecycle | tests: burst FIFO order, start-stop-start, post-stop ignored, no leak; `.unbounded` buffer |
| E5b | MIDIFeedback status-byte fix silently corrupts running-status / drops next event (boomer PRD-R2 #3) | WS6 adds parser tests BEFORE merge: realtime (0xF8/0xFA…) interleaved mid-message must not corrupt running status; System Common (0xF1-0xF6) consumed correctly; a status byte in-stream preserves the following channel-voice event (current tests only cover 0xF8 alone) |
| E9 | `logic://tracks` honesty fix changes observed output (G6 exception) | VALUE-ONLY: no type/schema/enum-domain change (non-optional Double + existing enum retained, no sentinel/null/new-case); golden-snapshot allowlist permits only VALUE drift on volume/pan/automationMode, asserts type+key+enum-domain diff = 0; rare AX-read failure retains today's default (no new unreadable path); live-verify on 12.3; CHANGELOG + API.md document it |
| E6 | Parallel branch merge conflict | file-atomic ownership (§3.2); integrate sequentially, full-suite gate between |
| E7 | SMFWriter denominator fix breaks a test pinning wrong value | grep tests for bar-offset assertions first; caller hardcodes 4/4 |
| E8 | CI workflow fix (M1) can't be unit-tested | actionlint + a dry `workflow_dispatch` on the branch; env-indirection is a known-safe pattern |

## 5. Testing Strategy (over-broad by design — user directive)
1. **Per-ticket**: `swift test --no-parallel` green before commit.
2. **Golden byte-snapshots (behavior-preservation harness)**: BEFORE Phase 1, capture from the v3.7.4 binary — every tool descriptor JSON, unknown-command + invalid-param error envelopes, a representative HC State A/B/C envelope per surface, the full ChannelRouter route table, and every resource URI + all 11 templates' output. AFTER each wire-sensitive workstream, re-capture and `diff` = 0. Committed as the refactor's proof.
3. **Dead-assertion integrity**: ledger for all ~356; for every safety-critical file (Issue136GotoDriftHonest, PluginInsertVerified, AXPluginInsertSlotsDrift, DispatcherTests success-guards), temporarily break the guarded behavior and confirm the NOW-live assertion FAILS (flip-test), then revert.
4. **New coverage**: mutation-gate completeness (per-tool: every accepted command gated or on read-only allowlist); BoundedProcessRunnerTests (SIGTERM-ignoring child→SIGKILL, >64KB no-deadlock, timeout→.timedOut, normal→.completed); StateModels Codable round-trip; SIGPIPE regression (broken-pipe write survives).
5. **Live E2E (over-broad)**: capture a **full-surface live baseline** on the v3.7.4 binary (drive all 10 tools' safe/read ops + all 18 resources + representative templates against real Logic 12.3, snapshot responses), then re-run against the refactored binary and diff (behavior-preserving proof on the real app). Plus strict `live-e2e-test.sh` (369/370 baseline) after integration, and the #234 verified-plugin live probes.
6. **Release gate**: full suite + strict live + `release.yml` validate-install macos-14/15.

## 6. Rollout
Sequential integration of WS1-7 into the branch (full-suite gate between each merge) → WS8 (tests) → WS9 (docs) → v3.8.0 choreography: prepare PR (version bump + CHANGELOG) → `release-stable.sh v3.8.0` (tag) → `release.yml` validate-install → evidence-sync PR (README/docs/Formula sha256 = published tarball). Per-workstream single-revert if a merge regresses. **M3 notarization**: ship via the existing notarized path OR document out-of-band-pin as the sole enterprise-grade install (Isaac decision at release).

## 7. Open Questions
- OQ1: WS1 (AccessibilityChannel split) + WS3 (AXLogicProElements split) both large — confirm clean at integration (signatures unchanged → expected yes).
- OQ2: Golden-snapshot harness — build as a committed test target or a throwaway script? (Lean: committed `ContractSnapshotTests` for durable regression value.)
- OQ3: M3 notarization is an Isaac/release decision (authenticity vs current ADHOC+out-of-band-pin). Surface at Phase E.

## Appendix — must-fix-before-release (ranked, from audits)
P0 SIGPIPE → P1 MCU 2-site race → P1 publish-mcp injection (M1) → P1 dead safety-guard assertions → P1 extractTrackState honesty → P1 PermissionChecker tri-state → M2 /private install bypass → release.sh Formula verify → the rest.
