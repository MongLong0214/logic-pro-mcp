# Legacy Code-Hardening Backlog (Retired)

This file preserves the intent of the previous `PRD-production-hardening` v0.2 ticket set while making clear that it is **not** the active production-hardening backlog anymore.

The earlier active tickets were:

1. AppleScript injection fix
2. MIDI duration safety and cancellation cleanup
3. `@MainActor` / concurrency migration
4. JSON output safety and API consistency
5. CGEvent key code and AX parameter fixes
6. StateCache bounds and MIDI port limits
7. MCU send-path consistency
8. Install script Team ID hardening
9. Defense-in-depth startup/routing safety
10. Banking verification

## Why They Were Retired

They were retired from the active backlog because, by the time this final PRD was written:

- the repository already contained the corresponding hardening work, or
- the issue had been superseded by the current launch-readiness workflow, or
- the work no longer represented a valid active production blocker

## What Replaced Them

The active backlog now tracks only the remaining commercial launch blockers:

- real signed release execution
- clean-machine validation
- live Logic Pro E2E validation
- release evidence and docs freeze

See:
- [PRD-production-hardening.md](/Users/isaac/projects/logic-pro-mcp/docs/prd/PRD-production-hardening.md)
- [STATUS.md](/Users/isaac/projects/logic-pro-mcp/docs/tickets/production-hardening/STATUS.md)
