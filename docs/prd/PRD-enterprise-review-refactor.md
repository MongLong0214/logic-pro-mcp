# PRD: Enterprise-Grade Review & Refactor Sweep (v3.8.0)

**Version**: 0.1 (draft — pending boomer convergence)
**Author**: Fable 5 (scope/decisions) — implementation by Opus/Sonnet agents
**Date**: 2026-07-05
**Status**: Draft
**Size**: XL
**Baseline**: main `7bb8bf3`, v3.7.4, 1980 tests green (`swift test --no-parallel`), 0 open GitHub issues.

---

## 1. Problem Statement

### 1.1 Background
Full A→Z read-only review of the codebase (Sources 81 files/40.3k LOC, Tests 166 files/47.8k LOC, Scripts 48, docs 8) by 5 parallel Opus reviewers. The codebase is **mature and well-factored** — reviewers found essentially no production-broken code. But a decade-equivalent of incremental issue-driven growth has left: God-object files, a genuine concurrency bug, a large body of **dead test assertions** (false-green on safety behaviors), scattered duplication, locale-policy bypasses, one zero-coverage safety-critical utility, a release-script checksum gap, and stale user-facing docs. Full findings: `docs/tickets/enterprise-refactor/REVIEW-FINDINGS.md`.

### 1.2 Problem Definition
Bring the codebase to enterprise standard **without changing external behavior**: fix the real defects, split the God objects, kill duplication/dead code, make the test suite actually assert what it claims, harden the release path, and bring every user-facing doc into line with the shipped code — then release.

### 1.3 Impact of Not Solving
- **~172 dead test assertions** (empirically proven — the `#expect` macro treats `Bool == Bool` as always-pass) mean CI is green on assertions that test nothing, including the exact fail-closed/honesty guards the product's value rests on. Future regressions in those paths ship silently.
- The **MCU feedback `Task{}` ordering race** (P0) corrupts parser state and is the probable root of the historical "MCU echo flake" (PR #153).
- Two 5.4k/1.8k-line God objects raise every future change's cost and review risk.
- Stale docs (mixer "send"=MCU, test counts 1933/1846 vs ~1980) mislead users and contributors.

## 2. Goals & Non-Goals

### 2.1 Goals
- [ ] G1: Fix all reachable correctness/safety defects (MCU race, dead safety-guard assertions, BoundedProcessRunner coverage, release.sh checksum verify, SMFWriter denominator landmine).
- [ ] G2: Split the two God objects (`AccessibilityChannel` 5369→~800, `AXLogicProElements` 1799→~500) into behavior-preserving same-type extensions; split `ResourceHandlers` (1466) and `TrackDispatcher.record_sequence` (620).
- [ ] G3: Eliminate the reviewed low-risk duplication/dead-code/locale-bypass clusters (route stragglers through existing helpers; hoist triplicates; delete dead code; centralize labels into AXLocalePolicy).
- [ ] G4: Convert all ~172 dead assertions to live ones with the correct optionality-dependent transform; add the mutation-gate completeness test + BoundedProcessRunnerTests.
- [ ] G5: Bring every user-facing doc (README, CHANGELOG, CONTRIBUTING, SECURITY, docs/API·SETUP·TROUBLESHOOTING) into exact agreement with the shipped code.
- [ ] G6: **Zero external-behavior change** — MCP surface stays 10 tools/18 resources/11 templates; every wire shape and error envelope byte-identical; `swift test --no-parallel` green at every step; strict live E2E parity preserved.
- [ ] G7: Ship as **v3.8.0** (minor: substantial internal hardening + test-integrity + docs, no public surface change; bundles the already-merged #234).

### 2.2 Non-Goals (explicitly EXCLUDED — reviewer-unanimous HIGH RISK / out of scope)
- NG1: **HC-surface normalization** — CoreMIDI/MCU return free-form success strings while AppleScript wraps in HC envelopes; unifying is a wire change across dozens of ops. DEFER.
- NG2: **HC v1→v2 unification** — main file uses HC v1 (118×), +VerifiedPlugins uses v2 (36×); intentional & test-enforced; unifying is BREAKING. DEFER.
- NG3: **same-failure-two-codes** (`.axWriteFailed` vs `.portUnavailable` for the same keycmd throw) — wire change. DEFER.
- NG4: **AX-main blocking-sleep→async** — removing `Thread.sleep` on the synchronous AX Runtime closures needs an async-signature ripple across the actor; systemic H risk. Only the **CGEvent** blocking sleep (tractable, Runtime already injects no-op in tests) is in scope.
- NG5: **Monster-function internal phase-extraction** (`defaultInsertVerified` 465, `defaultImportMIDIFile` 418, `setTrackInstrument` 380) — this is logic re-arrangement, not a pure move; qualitatively higher regression risk than file-splitting. File-splitting solves the file-size problem; internal decomposition is a separate follow-up. DEFER (file-move only).
- NG6: **StockPluginCatalog externalization to JSON/plist** — reviewer-flagged as anti-pattern: it is ALREADY data-driven (Seed array + factories); externalizing trades compile-time safety + zero-dep deploy for runtime load risk with no gain. DO NOT.
- NG7: **Removing reserved wire fields** (`spectralCentroidHz`, `frequencyPeaks` always-nil) — they are a declared v1 schema contract, not dead code. Leave + document.
- NG8: Any new feature, tool, resource, or template.

## 3. Technical Design

### 3.1 Constraints
- `Package.swift` auto-globs `Sources/LogicProMCP` and `Tests/LogicProMCPTests` (no explicit `sources:` list) → adding/moving `.swift` files needs NO manifest edit; git-mv into subdirs is safe.
- **Actor private-visibility rule** (the hard constraint on splitting `AccessibilityChannel`): cross-file extensions cannot see an actor's `private` stored state. So the 13-14 stored props + the 4 private scan-orchestrators that mutate them stay in the CORE file; only ~21 of 89 private funcs need `private`→`internal`; ~40 handlers are already `internal` (0 change).
- Every refactor is behavior-preserving; `swift test --no-parallel` (authoritative, matches CI) must stay green after each ticket.

### 3.2 Workstream decomposition (file-owner-disjoint for parallel-safe merge)
Two phases; within each, agents own DISJOINT file sets so branches merge without conflict.

**Phase-1 (production source, parallel by directory owner):**
- WS-A `Channels/AccessibilityChannel*` — 8-extension split (+Transport/+Tracks/+Mixer/+Plugins/+Library/+Regions/+MIDIImport/+Project) + dead `lastBothScan` + `scanInProgress` split + JSON-encoder merge + State-C typed-helper port.
- WS-B `Channels/{CoreMIDI,MCU,AppleScript,MIDIKeyCommands,Scripter,CGEvent,ChannelRouter}` — **MCU P0 race fix** + MCU fast-path race + CoreMIDI param-parse Result + catch-block helpers + AppleScript static/instance dedup + ChannelRouter table→RoutingTable.swift + CGEvent async sleep.
- WS-C `Accessibility/* + Plugins/* + Audio/*` — AXLogicProElements 6-extension split + dead `findTrackOutline` delete + LibraryNode triplicate hoist + AXLocalePolicy bypass cluster (library/track-type/marker-tables/cancel) + PluginInspector→AXHelpers + AnalysisPolicy.default.
- WS-D `Dispatchers/* + Resources/* + Server/* + State/*` — ResourceHandlers split + TrackDispatcher record_sequence split + create_*/toggle helpers + inline verified-parse→helper + MIDIDispatcher.invalidParamsResult 50-site route + mutation-gate completeness test + StatePoller generic poll.
- WS-E `Utilities/* + Workflows/* + MIDI/*` — FailureError String-backed enum + deterministicFindings decompose + SetupDoctor requireBinary + remediation-infra dedup + **SMFWriter denominator fix** + P2-3 bespoke-error-string→FailureError.
- WS-F `Scripts/*.sh` — release.sh Formula-sha grep verify + validate_share_dir protected-path symmetry + release.sh no-op-commit guard.

**Phase-2 (tests, after Phase-1 merges — soures stable):**
- WS-G `Tests/*` dead-assertion sweep (~172, safety-critical first, optionality-dependent transforms) + FakeAXRuntimeBuilder helper promotion + JSON-helper clone removal + BoundedProcessRunnerTests. Runs after Phase-1 so it transforms the FINAL assertions (incl. any tests Phase-1 touched).

**Phase-3 (docs, WS-H, can overlap Phase-2):** all user-facing md — see Phase D.

### 3.3 Key Decisions
| # | Decision | Rationale |
|---|----------|-----------|
| D1 | Split God objects by pure file-move (extensions), NOT internal function decomposition | Pure moves are L-risk + compiler-verified; internal decomposition (NG5) is logic re-arrangement, deferred |
| D2 | Phase tests AFTER source (WS-G last) | Avoids two agents editing the same test file; WS-G sees the final assertion set |
| D3 | Directory-disjoint workstream ownership | Parallel branches merge conflict-free; only CHANGELOG is centrally merged (Phase D) |
| D4 | Dead-assertion transform is per-case (5 rules), NOT global sed | Optionality + nil-semantics differ; wrong transform (force-unwrap where nil is valid success) introduces crashes |
| D5 | Exclude all wire-shape changes (NG1-3) | The product's contract + 1980 tests + strict-live pins freeze the surface; enterprise ≠ rewrite |
| D6 | v3.8.0 minor | Substantial internal + test + docs, zero public-surface change, bundles #234 |

## 4. Edge Cases & Risk
| # | Scenario | Mitigation |
|---|----------|------------|
| E1 | God-object split breaks a test-pinned func by moving it | Funcs resolve by type not file; 29 test-pinned names verified file-agnostic; full suite after each split |
| E2 | Dead-assertion transform turns a silently-passing test RED (real latent bug surfaces) | That IS the goal — investigate each newly-red test; do not paper over |
| E3 | MCU race fix changes feedback timing → parser tests flake | Single-consumer AsyncStream preserves ordering; run MCUFeedbackParserTests + MCU echo tests repeatedly |
| E4 | Parallel branch merge conflict | Directory-disjoint ownership (D3); integrate sequentially with full-suite gate between merges |
| E5 | SMFWriter denominator fix breaks a test pinning the wrong value | Reviewer confirmed sole caller hardcodes 4/4; grep for tests asserting bar-offset before changing |
| E6 | private→internal promotion leaks encapsulation | Only ~21 promotions, all handler funcs (not state); stored props stay private in core |

## 5. Testing Strategy
- Every ticket: `swift test --no-parallel` green before commit (CI-authoritative).
- WS-G success = suite still green AND newly-live assertions verified meaningful (spot-check the safety-critical ones actually FAIL when the guarded behavior is broken — flip-test a sample).
- New tests: mutation-gate completeness (per-tool: every accepted command is gated or on read-only allowlist), BoundedProcessRunnerTests (SIGTERM→SIGKILL, >64KB no-deadlock, timeout, normal).
- Final: full suite + strict live E2E parity (369/370 baseline) + release validate-install.

## 6. Rollout
v3.8.0 via the standard choreography: prepare PR (version bump + CHANGELOG) → `release-stable.sh v3.8.0` (tag) → `release.yml` validate-install macos-14/15 → evidence-sync PR (README/docs/Formula sha256 = published tarball). Single-revert per workstream if needed.

## 7. Open Questions
- [ ] OQ1: Do WS-A and WS-C (both large God-object splits) merge cleanly given AccessibilityChannel calls AXLogicProElements? (Signatures unchanged → yes; confirm at integration.)
- [ ] OQ2: Exact dead-assertion count after Phase-1 (Phase-1 may add/touch assertions). WS-G recounts live.
- [ ] OQ3: Should the ~30 positional-magic-arg call sites (toolStep bare Bool/String?) get labels this sweep or defer? (Low value, wide; lean defer unless cheap.)
