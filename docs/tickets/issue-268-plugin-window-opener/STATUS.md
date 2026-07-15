# Pipeline Status: issue-268 plugin window opener

> **SUPERSEDED / REOPENED.** This board records a prior pipeline (PR #271) that
> did not land on the current Train-A head. Issue #268 is **OPEN** and, per the
> current CTO directive, is pulled forward into the #285 ADR-002-a acceptance and
> owned there. The active, binding work board is
> `docs/tickets/adr-002a-target-kinds/STATUS.md`. Do not treat the "Verified"
> rows below as current-head evidence.


**PRD**: `docs/prd/PRD-issue-268-plugin-window-opener.md`
**Issue**: https://github.com/MongLong0214/logic-pro-mcp/issues/268
**Branch**: `fix/issue-268-plugin-window-opener`
**Current Phase**: PR open

## Ticket Status

| Ticket | Title | Status | Gate |
|--------|-------|--------|------|
| T1 | Production plugin-window opener | Verified | Red-first tests + State A fixture |
| T2 | Failure diagnostics | Verified | Candidate window/control evidence in State C |
| T3 | Live E2E replay | Verified | Local Logic Pro 12.3 repro returns State A |
| T4 | Production readiness review + PR | Verified | Review, CI, issue/PR links |

## Verification Ledger

- Red-first: `testProductionOpenerOpensClosedTargetSlotWindow` failed on the
  pre-fix no-op opener with State C `window_open_failed`.
- Focused tests: `swift test --filter PluginSetParamVerifiedLiveTests` passed
  19/19 after the production opener and fail-closed wrong-slider fixture.
- Full suite: `swift test --no-parallel` passed 2214 tests.
- Build: `swift build -c release` passed.
- Live E2E: branch release binary changed the local Logic Pro 12.3 Compressor
  `threshold` replay from State C `window_open_failed` to State A verified via
  `ax_plugin_window`; a second explicit track 2 replay also returned State A.
- Manual QA bad input: release-binary MCP call with the wrong `threshold` unit
  returned State C `invalid_params` with `write_attempted:false`.
- CLI smoke: `.build/release/LogicProMCP --help` printed the expected usage.
- PR opened: https://github.com/MongLong0214/logic-pro-mcp/pull/271
- Issue status comment: https://github.com/MongLong0214/logic-pro-mcp/issues/268#issuecomment-4910876825
- Environment note: a stale ignored `Resources/library-inventory.json` artifact
  was moved out of the repo before full-suite verification; it was not tracked
  source and is not part of this branch.
