# Pipeline Status: Enterprise Review & Refactor Sweep (v3.8.0)

**PRD**: docs/prd/PRD-enterprise-review-refactor.md v0.4 — APPROVED (boomer CONVERGED R4, 2026-07-05)
**Findings**: REVIEW-FINDINGS.md (round 1, 5 reviewers) + AUDIT-ROUND2.md (round 2, security/concurrency/completeness)
**Size**: XL | **Baseline**: main 7bb8bf3, v3.7.4, 1980 tests green, 0 open issues
**Branch**: chore/enterprise-review-refactor-v3.8.0 (worktree logic-pro-mcp-refactor)
**Current Phase**: C→2 (Phase-1 source COMPLETE 7/7 integrated 2052 green; entering WS8 test-integrity)
**Rule**: NO implementation until PRD + tickets boomer(codex gpt-5.5 xhigh)-converged (Isaac). No main/default merge or direct push (Isaac) — PR only.

## Workstreams / Tickets (file-atomic, disjoint)
| WS | File | Phase | Priority | Owns |
|----|------|-------|----------|------|
| WS1 | WS1-accessibilitychannel-split.md | 1 | P1 | Channels/AccessibilityChannel* |
| WS2 | WS2-other-channels-dedup.md | 1 | P2 | Channels/{AppleScript,CoreMIDI,MIDIKeyCommands,Scripter,CGEvent,ChannelRouter,Channel}+RoutingTable |
| WS3 | WS3-accessibility-ax-split-honesty.md | 1 | P1 | Accessibility/* + Resources/ResourceProvider + Plugins/* + Audio/* |
| WS4 | WS4-dispatchers-server-sigpipe.md | 1 | P0 | Dispatchers/* + Resources/*(excl ResourceProvider) + State/{StatePoller,StateModels} (NOT StateCache) + Projects/* + Server/{ServerConfig,SerializedStdio} + entrypoints + SIGPIPERegressionTests |
| WS5 | WS5-utilities-workflows-midi.md | 1 | P1 | Utilities/* + Workflows/* + MIDI/(excl MCU 3 files) |
| WS6 | WS6-mcu-pipeline-atomic.md | 1 | P1 | Channels/MCUChannel + Server/LogicProServer + MIDI/{MCUFeedbackParser,MIDIFeedback,MCUProtocol} + State/StateCache + MCU/MIDIFeedback test files |
| WS7 | WS7-scripts-ci-security.md | 1 | P1 | Scripts/*.sh + .github/workflows/* + Formula/* |
| WS8 | WS8-tests-dead-assertions.md | 2 (after Ph1) | P1 | existing Tests/* (excl 7 Phase-1 files) + ledger; sub-units 8c→8a→8b sequential |
| WS9 | WS9-docs.md | 3 (after Ph2) | P2 | *.md docs |

## Cross-WS sequencing notes (from boomer PRD reviews)
- WS5 adds `AppleScriptSafety.escapeForScript`; WS2 defers its escape-dedup (avoid cross-edit).
- No file owned by two WS (verified round-2). LogicProServer→WS6 only; ResourceProvider→WS3 only; entrypoints→WS4.
- Golden-snapshot harness captured from v3.7.4 binary BEFORE Phase-1; diff=0 gate per wire-sensitive WS (WS4/WS6/WS2/WS5). logic://tracks value-only allowlist (WS3).

## Review History
| Phase | Round | Verdict | Notes |
|-------|-------|---------|-------|
| B-PRD | 1 | HAS_ISSUES (5) | boomer; all folded → v0.2 |
| B-PRD | 2 | HAS_ISSUES (3) | extractTrackState exception + Projects ownership + MIDIFeedback tests → v0.3 |
| B-PRD | 3 | HAS_ISSUES (1) | sentinel = wire change → v0.4 value-only |
| B-PRD | 4 | **CONVERGED** | value-only confirmed; ready for tickets |
| B-tickets | 1 | HAS_ISSUES (5) | ownership collisions; folded: StateCache→WS6, per-WS test files, ledger→WS8, permission-tristate G6-a, WS8→8a/b/c |
| B-tickets | 2 | HAS_ISSUES (1) | WS9 permission-tristate SECURITY/TROUBLESHOOTING doc AC missing → added |
| B-tickets | 3 | **CONVERGED** | boomer final sign-off: PRD + WS1-9 ready for implementation |

## Phase C integration log
- Base test count: 2014 (fix-branch base; ws1 pure-move confirmed).
- golden-baseline REFRESHED from pristine base binary (stale 18:39 build predated #234 merge → logic_tracks desc); now 0-diff vs base.
- Integrated (sequential, full-suite gate each): ws1 (2014✓) → ws2+ws6 batch (2024✓) → ws5 (2042✓, golden diff=0 FailureError rawValue-preserved). All merges conflict-0.
- Integrated: +ws7 (2042), +ws3 (AXLogicProElements 6-ext + extractTrackState value-only + policy, 2051 green, golden static identical). 6/7 done (ws1/2/3/5/6/7). Remaining: ws4 (SIGPIPE+splits+dedup+AC5 done, AC6 finishing).
- WS6 AC5 follow-up → WS8: full HandshakeResult/parseDeviceResponse deletion + MCUProtocolTests removal (WS6 deleted only unconstructable .timeout; existing test blocks the rest).
- audit adversarial finding: MIDIEngine.inboundMessages + MMC strict tier are production-dead but TEST-covered (audit missed test refs) → RETAINED (ws5 verified).

## Cross-owner exception (adjudicated 2026-07-05)
- WS4 AC5 (create_marker pre-poll) unavoidably changes testNavigateDispatcherRoutesMarkerAndZoomCommands's expected axOps (7→8, adds nav.get_markers). Approved option (a): WS4 updates ONLY that one expected-op-list entry (intended consequence of an approved P1 fix; scenario unchanged; count-delta tests already cover it). Not a dead-assertion edit → WS8 later touches OTHER lines of DispatcherTests for the assertion sweep (different lines/purpose, sequential Phase-2, no collision).

- **PHASE-1 COMPLETE: 7/7 integrated** (ws1/2/3/4/5/6/7), fix branch 2052 green, all merges conflict-0. Final WS4 (SIGPIPE P0 + ResourceHandlers/record_sequence splits + AC5 marker pre-poll).
- Next: WS8 (test integrity, sequential 8c→8a→8b) + WS6 follow-up (HandshakeResult/parseDeviceResponse + MCUProtocolTests deletion). Then WS9 docs → boomer final full-diff review → v3.8.0 release.

## LIVE E2E (fix-branch binary, all 7 WS integrated, Logic 12.3) — 2026-07-05
- strict live suite (Scripts/live-e2e-test.sh, LOGIC_PRO_MCP_STRICT_LIVE=1): **372 passed, 1 skipped, 373 total — ALL PASS** (baseline 369/370; 0 regression). First run hit an environmental fresh-bootstrap transient (stale blocking dialog); clean re-run all-green.
- extractTrackState honesty (WS3 AC2 live-verify, was deferred): logic://tracks track 0 reports REAL header values volume=0.758, pan=0.0079, automationMode=off (NOT fabricated 0.0/0.0/off — pan≠0 proves live AX read). Value-only, TrackState shape unchanged.
- permission tri-state (WS5 G6-a): host is genuinely granted → granted shown; notVerifiable/notGranted paths unit-pinned (PermissionCheckerTriStateTests). No false NOT-GRANTED.
- Conclusion: behavior-preserving proven live (strict suite parity) + both intended honesty corrections verified on the real app.

## Phase-2 WS8 COMPLETE (2026-07-05)
- WS8c 70d7936 (FakeAX helpers + JSON clone .resource fix).
- WS8a 30d6188: **386 dead #expect(Bool==Bool) → live** (rules: 233 non-opt-bare, 26 as?Bool force-unwrap, 103 Bool?-must-fail, 18 isError nil-valid bind, 6 tautology). LEDGER + 4 safety-critical flip-tests (all FAIL-when-broken). **5 assertions went RED when made live — all ground-truthed as LATENT TEST DEFECTS (0 production bugs): logic://tracks envelope parse, HC-v1 verified omission, list_ports env-dependent, MCU async ordered-consumer race, export-guardrail substring. None papered over.**
- WS8b 0890c80: MutationGateCompleteness + BoundedProcessRunner (SIGTERM→SIGKILL/64KB/timeout) + StateModelsCodable (new files, dead-pattern-free live forms).
- WS6-followup 47504b8: HandshakeResult/parseDeviceResponse + 4 tests deleted (repo refs=0).
- **2070 tests green.** RECONCILED: the "missing stash" was a false alarm — ws8 had `git stash pop`'d successfully (pop deletes the entry; stash list is worktree-shared, so it vanished from my main worktree view) then fixed the dead form + COMMITTED (0890c80/47504b8) in the refactor worktree. My independent `git stash apply 1ecad30` (the PRE-FIX snapshot) landed the same content because HEAD already carried ws8's fix. VERIFIED HEAD ce3b653: BoundedProcessRunnerTests uses the LIVE form (`guard case .completed(let out)` → `#expect(!out.stdoutTruncated)`, out non-optional) — NOT 1ecad30's dead `out?.stdoutTruncated == false`. 0 dead forms in the 3 new files (MutationGate's `?? false` are local-var unwraps, then asserted live). Zero work lost, no dead regression.

## WS8 independent review (ws8b) — PASS, changed nothing (2026-07-05)
- Ledger 573 rows CLEAN: R3-vs-R4 split principled (all 18 .isError→R4 bind; nil-must-fail→R3 force-unwrap; 0 misclassified). Optionality COMPILER-PROVEN (R1 #expect(x) fails if optional; R3 x! fails if non-optional; green suite ⇒ every label machine-correct). R2 26 response-contract force-unwraps, R5 6 tautologies→real/smoke.
- Flip-test REPRODUCED: broke AXLogicProElements+PluginSlots.swift:50 isEmpty → AXPluginInsertSlotsDriftTests:85 (AC21 occupied-unreadable NOT write-safe) went RED; pre-sweep dead form would have missed it. Reverted.
- Residual dead forms: 0 (4 grep hits all legitimately LIVE — .allSatisfy/.first closure predicates, != .none enum check).
- WS8b 3 new files live-only; MCUProtocol deletion complete (0 live refs, 2 documentary comments). 2070 green re-confirmed.
- Cosmetic-only (NOT a defect, deferred): CleanupExecutionTests redundant extra `!` on a #require result — compiles clean, live, intent preserved.
- **WS8 FULLY VERIFIED. Phase C (source refactor) + Phase 2 (test integrity) COMPLETE.**

## RELEASE GATE — boomer NO-GO (P1 MCU restart regression, 2026-07-05)
- boomer (narrowed-scope codex, after 1 context-death) found a REAL WS6-introduced regression: production MCU restart drops all feedback.
- Root cause CONFIRMED vs main: main's ProductionMCUTransport stored `private var onReceive` + CoreMIDI callback used `[weak self] → self?.onReceive?(event)` (INDIRECT ref, so start() updating the property kept the reused port's callback pointing at the live sink = restart-safe). WS6 replaced this with the onReceive VALUE captured directly in the callback (`onReceive(event)`) + removed the stored property → on stop()/start(), createBidirectionalPort reuses the existing dest (ports[name] guard) WITHOUT re-registering the callback → old callback yields into the finished first AsyncStream continuation → silent drop.
- Test gap: MockMCUTransport.start overwrites onReceive each call (MCUChannelTests:408), so it never exercises the production callback-reuse-on-restart path.
- Severity: P1 NO-GO. MCU-control-surface users lose verified feedback after a restart.
- FIX (keep WS6's FIFO synchronous delivery AND restore main's restart-safety): reintroduce a thread-safe current-sink the callback dereferences (or update/recreate the bidirectional destination when the callback changes), + a production-style restart test with a fake VirtualPortManaging that reuses the first installed callback.
- SIGPIPE / extractTrackState value-only / FailureError rawValues / split pure-moves / M1-M2 security = all PASS (no other blocker).
