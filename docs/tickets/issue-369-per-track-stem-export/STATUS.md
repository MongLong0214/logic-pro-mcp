# Pipeline Status: Issue 369 Per-Track Stem Export

**Issue**: #369
**Size**: M
**Current Phase**: measured, ticket written, blocked on one contract decision

## Tickets

| Ticket | Title | Status | Review | Notes |
|--------|-------|--------|--------|-------|
| T1 | Drive Logic's per-track audio export from the export panel | Not started | — | mechanism measured live 2026-08-19; blocked on the partial-success State question in T1 §5 |

## What changed the plan

The roadmap expected this issue to close with a measurement showing the surface cannot do per-track
export. Driven live, it can: one populated track produced `Studio Grand_1.aif`, 2.048 s, 0.744 s
non-silent, analyzer `status: pass`. So the issue is implementable work rather than a scope decision,
and the measurements are written into T1 as the mechanism.

## Measurement log

| Date | What was established |
|------|----------------------|
| 2026-08-19 | `One File per Track` is a popup ON the export panel, not behind it |
| 2026-08-19 | menu enablement must be read with the menu open; the leaf title is rewritten by Logic |
| 2026-08-19 | typing a destination path dismisses the panel — select the folder as a browser element |
| 2026-08-19 | the post-Export `Logic Pro` window is the progress dialog; its disappearance is completion |
| 2026-08-19 | a real export completes and the output verifies through `logic_audio.analyze_file` |
