# Pipeline Status: Issue 369 Per-Track Stem Export

**Issue**: #369
**Size**: M
**Current Phase**: measured, ticket written, ready to implement

## Tickets

| Ticket | Title | Status | Review | Notes |
|--------|-------|--------|--------|-------|
| T1 | Drive Logic's per-track audio export from the export panel | Not started | — | mechanism measured live 2026-08-19; not blocked — the per-artifact State shape already exists in ProjectExportExecutor |

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

## Correction

The first revision of T1 declared the ticket blocked on "what State does a partially successful run
report", claiming this project's contract had no shape for it. It does: `ProjectExportExecutor`
already runs Honest Contract **per artifact** — State A on verified-on-disk, State B when the artifact
cannot be verified, State C on a hard failure — and it is the executor `export_run artifacts:[stem]`
flows through.

The claim was an absence asserted without reading the file the answer was in. Corrected in place
rather than left standing, because a ticket that says "blocked" is read as a reason not to start.

## Second correction

The first correction removed the "blocked" flag on the strength of `ProjectExportExecutor` carrying
per-artifact State. That finding is right and it stands.

It was also incomplete. `ProjectExportPlanner` computes one artifact as one known path
(`<project>-<kind>.wav`) with `exists`, the collision policy and containment all resolved at plan
time — and a stem run produces N files whose names Logic assigns after the fact. So `export_plan`,
which is a dry run whose job is to say what will be written, cannot enumerate a stem run.

T1 is therefore unblocked as an AX drive and can be built and proven on its own. Wiring it into
`export_run artifacts:[stem]` waits on one question that is a property of the published dry-run
contract: what an artifact plan promises when the names arrive late.

Two corrections in two revisions, both from the same habit — answering about a file without opening
it. Recorded rather than tidied away, because the shape of the mistake is the useful part.
