# Pipeline Status: Enterprise Review & Refactor Sweep (v3.8.0)

**PRD**: docs/prd/PRD-enterprise-review-refactor.md v0.4 — APPROVED (boomer CONVERGED R4, 2026-07-05)
**Findings**: REVIEW-FINDINGS.md (round 1, 5 reviewers) + AUDIT-ROUND2.md (round 2, security/concurrency/completeness)
**Size**: XL | **Baseline**: main 7bb8bf3, v3.7.4, 1980 tests green, 0 open issues
**Branch**: chore/enterprise-review-refactor-v3.8.0 (worktree logic-pro-mcp-refactor)
**Current Phase**: C (implementation — PRD+tickets CONVERGED, boomer signed off)
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
