# Pipeline Status: Enterprise Review & Refactor Sweep (v3.8.0)

**PRD**: docs/prd/PRD-enterprise-review-refactor.md
**Findings**: docs/tickets/enterprise-refactor/REVIEW-FINDINGS.md (5 reviewers, ~78 findings, 1 P0)
**Size**: XL
**Baseline**: main 7bb8bf3, v3.7.4, 1980 tests green, 0 open issues
**Current Phase**: B (scope confirmation — boomer PRD convergence)
**Rule**: NO code implementation until PRD + tickets are boomer(codex gpt-5.5 xhigh)-converged (Isaac directive 2026-07-05).

## Workstreams (directory-disjoint, parallel-safe)

| WS | Owner dirs | Scope | Phase |
|----|-----------|-------|-------|
| A | Channels/AccessibilityChannel* | 8-ext split + dead lastBothScan + scanInProgress split + encoder merge + State-C helper port | 1 |
| B | Channels/{CoreMIDI,MCU,AppleScript,MIDIKeyCommands,Scripter,CGEvent,ChannelRouter} | MCU P0 race + fast-path race + CoreMIDI param Result + catch helpers + AppleScript dedup + RoutingTable split + CGEvent async | 1 |
| C | Accessibility/*, Plugins/*, Audio/* | AXLogicProElements 6-ext split + del findTrackOutline + LibraryNode hoist + AXLocalePolicy bypasses + PluginInspector→AXHelpers + AnalysisPolicy.default | 1 |
| D | Dispatchers/*, Resources/*, Server/*, State/* | ResourceHandlers split + record_sequence split + create_/toggle helpers + verified-parse helper + invalidParamsResult route + mutation-gate test + StatePoller generic | 1 |
| E | Utilities/*, Workflows/*, MIDI/* | FailureError String-enum + deterministicFindings decompose + requireBinary + remediation dedup + SMFWriter denominator + bespoke-error→FailureError | 1 |
| F | Scripts/*.sh | release.sh Formula-sha verify + validate_share_dir symmetry + no-op-commit guard | 1 |
| G | Tests/* | dead-assertion sweep ~172 (safety-first, 5 transforms) + FakeAX helper promotion + JSON clone removal + BoundedProcessRunnerTests | 2 (after Ph1) |
| H | *.md (README/CHANGELOG/CONTRIBUTING/SECURITY/docs) | doc staleness sync | 3 (overlap Ph2) |

## Review History
| Phase | Round | Verdict | Notes |
|-------|-------|---------|-------|
| B-PRD | 1 | (pending) | boomer codex gpt-5.5 xhigh |

## Correctness defects (must-fix, not just cleanup)
- P0 MCU Task{} feedback ordering race (MCUChannel:180) — probable MCU echo flake (PR #153) root cause. WS-B.
- P2-latent SMFWriter denominator ignored (6/8 → 2× offset); unreachable today (caller hardcodes 4/4). WS-E.
- ~172 dead assertions incl. safety-critical fail-closed/honesty guards passing unconditionally. WS-G.
- release.sh Formula sha256 rewrite unverified (#22-class silent brew breakage). WS-F.
- BoundedProcessRunner (SIGTERM→SIGKILL) zero direct tests. WS-G.
