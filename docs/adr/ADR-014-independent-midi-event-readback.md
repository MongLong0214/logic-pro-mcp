# ADR-014 — Independent MIDI Event Readback (#302)

**Status:** Proposed (R1 dark core planned)
**Related:** #293 / ADR-010 (completeness core, shipped in #445); #303/#446 (transform State-A, dark)
**Date:** 2026-07-23

## Context
The MIDI note-readback completeness core (ADR-010 / #293, shipped in #445) can prove an Event-List AX readback is *complete*, but it deliberately grants no positive `exactMatch`. The reason is fundamental: a pure, in-process core has no external root of trust with which to prove that an "expected" note sequence is *independent* of the observed Event-List conversion. Any "expected" the core is handed could simply be a copy of the observed output (O→E), or carry a caller-chosen provenance label — neither establishes independence. #302 introduces the provider layer and a sealed independent-expected source so that, eventually, a positive non-tautological match becomes possible.

## Decision
Split #302 into a dark R1 core (CI-provable, no Logic) and a live-qualified R2, under a strict independence rule:

**A pure/CI core cannot verify note-independence. Therefore R1 grants no positive match at all — the verdict type has no `exactMatch` case.** Independence, the positive grant, and the real proof mint are established only at R2 by a live-ingestion boundary that mechanically derives the expected notes from an independent source (making an O→E copy structurally impossible).

### R1 (this stage — dark)
- A sealed proof TYPE whose fixture-bearing payload **cannot be constructed in a release/product build**. Only an `.unproven` value exists in release; the fixture payload and its makers compile only under a debug test seam and are dead-code-eliminated from release binaries. There is no public/internal release factory or decoder. The type guarantees *no release fixture-bearing/proof-bearing construction* (only `.unproven` exists in a release build); it does **not** assert the payload is independent.
- A verify guard `verifyRegion(observed:expected:)` that returns only `incompleteCannotVerify(reason:)` or a structured `mismatch(added:removed:)` — **never a positive match**. It rejects: unproven expected; an expected whose root id equals the observed conversion pipeline id; an expected not bound to the observed region identity; an incomplete observed snapshot; a content-binding integrity failure; a non-positive/overflowing PPQ. A note-identical O→E copy is rejected (returns `incompleteCannotVerify`), not matched.
- A provenance taxonomy (`authoredIntent` write-oracle / `controlledExport` dual-observation), distinct and non-interchangeable, and distinct from the observed `eventListAX`.
- Boundary: 0 public API, 0 production caller, release dead-code-elimination.

### R2 (later — live-qualified)
- A named live-ingestion boundary that derives the expected notes from an independent source with a temporal commitment (write-oracle: pre-authored intent sealed before the read; or dual-observation: a distinct Logic→notes surface). Only R2 reintroduces the positive-match case and grants it, behind a qualified provider + public API, gated on live experiments.

## Alternatives considered
- **A debug "positive control" that grants a match under the seam.** Rejected: a caller-trusted seam fixture with matching notes proves only that the seam was invoked, not that the expected is independent — an O→E copy with a non-pipeline root id would pass. It would contradict the independence rule, so R1 exposes no positive path in any build configuration.
- **Rely on pipeline-id inequality or a provenance label alone.** Rejected: a caller-chosen id/label is not a root of trust.

## Consequences
- R1 is safely mergeable independent of the live export/ingestion work, but **#302 remains open** and R1 is **not** completion of #302/ADR-014.
- The decoder (`SMFReader`) is not the root of trust; the producing surface is. Transform State-A (#303/#446) stays dark; it does not build independent infrastructure ahead of #302.
- Public claim after R1: "a fixture-bearing/proof-bearing independent-expected state cannot be constructed in a release build (only `.unproven` exists), and the readback verify guard asserts no independence and exposes no positive-match path." Independent positive verification is an R2 (live) claim only.
