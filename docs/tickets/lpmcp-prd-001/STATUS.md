# LPMCP-PRD-001 production-readiness remediation

## Scope

- Program: #308
- Owning ADR issue: #284
- Historical foundation PR: #367
- Remediation branch: `fix/adr001-production-readiness-20260716`
- Exact base: `cc5922e5c5c2786c401713fd80b1bd40d1e15f14`
- Blocked successor: #286

This slice closes the remaining release-qualification debt before the roadmap advances.

## Acceptance

The candidate is production-terminal only after all of the following are bound to one immutable commit:

1. The seven production-readiness contracts are proven RED on the exact base and GREEN on the candidate.
2. Current-source focused tests pass.
3. The exact candidate full suite passes.
4. A universal release artifact is built and its SHA-256 is recorded.
5. The exact artifact passes Logic Pro Desktop en-US and ko-KR qualification.
6. Mutation, independent readback, restore, wrong-target, ambiguity, timeout, and partial-state boundaries are verified.
7. Creator axes have live evidence or a bounded environment waiver.
8. Security, privacy, fail-closed, and evidence-integrity review passes.
9. Independent technical review and CEO exact-head review pass.
10. Exact-head PR CI passes.
11. Merge commit, post-merge main CI, and the completion receipt are verified.

Any missing or stale lane yields `QA_PENDING` and blocks merge and #286.

## Production-readiness contracts

- R-REL: release publication is blocked on independent qualification.
- R-SEM: each registered operation has semantic evidence or a governed release-visible waiver.
- R-MATRIX: Desktop and Creator en-US/ko-KR axes are explicit.
- R-MUT: mutation, readback, restore, and compensation evidence is required.
- R-PROV: trusted independent provenance is verified.
- R-PUB: immutable qualification evidence is published with the release.
- R-AUTH: this board binds the authority base and execution order.

## Current gate

The working candidate has passed focused tests, the full suite, universal build, Desktop/ko live mutation and fail-closed checks, and promotion verification. Those results must be rerun after the candidate is committed because commit identity is part of the qualification evidence.

No merge or successor work is allowed until the committed exact-head gate is complete.
