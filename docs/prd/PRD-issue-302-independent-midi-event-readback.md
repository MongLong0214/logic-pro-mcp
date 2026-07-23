# PRD — ADR-014 / #302: Independent MIDI Event Readback

## Problem
The MIDI note-readback completeness core (ADR-010 / #293, shipped in #445) proves an Event-List AX readback is *complete* but grants no positive `exactMatch`: a pure core has no external root of trust to prove an expected sequence is independent of the observed Event-List conversion. #302 will, **at R2 (live)**, supply the qualified provider + a sealed independent-expected source so a positive, non-tautological match becomes possible. **R1 (this PR) establishes only the dark type and the rejection guard — it grants no match, and its verdict type has no positive-match case at all.**

## Decision-B-STRICT (design decision, 2026-07-23) — supersedes the earlier plan
A pure/CI core **cannot verify note-independence**; any positive `exactMatch` it exposes is caller-trusted and spoofable (e.g. an O→E copy of the observed notes with a caller-chosen non-pipeline `rootID`). Therefore:
- **R1 grants no positive match — the `.exactMatch` case is DELETED from `RegionMatchVerdict` in R1** (verdict = `.mismatch` | `.incompleteCannotVerify` only). R2 reintroduces `.exactMatch` with the real live-ingestion boundary. No "compiled-but-unreachable" reservation.
- The seam construction path is an explicit **`testFixture`** (not `proven`, not a "proof") — a debug-only, caller-trusted fixture to exercise the rejection guard; it is not evidence of independence.
- The positive grant, temporal commitment, real mint, public API, and production caller are **all R2**.
- R1 boundary marker = **0 public API + 0 production caller + release dead-code-elimination** (no real ADR-014 runtime flag exists — do not claim "flag off").
- **#302 stays OPEN; R1 merge is not #302/ADR-014 completion and not canonical-order terminal credit.**

## Scope split
- **R1 (this PR — dark, CI-provable, no public API, no production caller, NO positive grant):** the non-forgeable-by-release `IndependentExpectedProof` TYPE + the rejection guard + the provenance taxonomy. Buildable/verifiable without Logic.
- **R2 (later, live-qualified):** the named live-ingestion boundary deriving `E`'s notes from an independent source (making O→E structurally impossible) + temporal commitment; reintroduces `.exactMatch` + positive grant + public API + production caller; gated on E1/E2/E2c/E3/E4/E5.

## Independence model
- **Observed** `O` = Event-List AX snapshot (`MIDIRegionNoteSnapshot`, from #445).
- **Independent expected** `E`, two classes: **dual-observation** (`E` from a *different* Logic→notes surface, e.g. a controlled export decoded by `SMFReader`, bound to the same region identity) and **write-oracle** (`E` = pre-authored write intent, sealed before the read, never re-encoded from observation).
- The decoder (`SMFReader`) is not the root of trust; the producing *surface* is. **Independence is unverifiable by a pure core, so R1 asserts none and makes positive verification impossible at the type level** — establishing independence is R2's live-ingestion boundary.

## R1 acceptance criteria (each RED-first — TDD; NONE grants a positive match)
1. **Fixture payload not constructible in release:** `IndependentExpectedProof` has `.unproven` (inhabited in release + seam) and, under the debug seam ONLY, `.testFixture(...)`. No public/internal **release/product** factory or decoder; the only fixture construction is via **debug-seam internal makers** (`makeTestFixture`/`makeCorruptedTestFixture`, `#if QUALIFICATION_FAULT_SEAM`). Those + the sealed payload type compile ONLY under the seam and are DCE'd from release: **0 seam-only construction symbols** in release — the sealed payload type (`CallerTrustedFixture`) and its debug-seam makers (`makeTestFixture`/`makeCorruptedTestFixture`) — with no `Codable`/`rawValue`/memberwise/`@testable` reconstruction. (The `IndependentExpectedProof` and `IndependentExpectedRoot` enums themselves are intentionally KEPT in release — the release `IndependentExpectedProof` compiles with ONLY `.unproven` and no payload type, so their surviving symbols do not enable any fixture-bearing proof.) A release/product build can hold only `.unproven`; it cannot construct a fixture-bearing proof. Does NOT assert the payload is independent.
2. **No positive-match case:** `RegionMatchVerdict` has no `.exactMatch` case in R1; `verifyRegion` returns only `.incompleteCannotVerify(reason:)` or `.mismatch(added:removed:)`. Positive match is impossible at the type level (not merely "unreachable").
3. **Rejection guard** (each → non-matching verdict): (a) `.unproven` expected; (b) `rootID` == observed conversion pipeline id (same-pipeline); (c) expected not bound to observed region identity; (d) incomplete observed snapshot; (e) content-binding integrity failure — stored digest ≠ digest over the fixture's OWN notes+PPQ (tested via a **seam-only corrupted-fixture maker** that injects a mismatched digest, since normal construction co-computes it and cannot mismatch); (f) non-positive or overflowing PPQ.
4. **O→E copy is not a match (load-bearing STRICT case):** a fixture whose notes equal the observed notes (note-identical O→E copy) with any non-pipeline `rootID` → `.incompleteCannotVerify` (never a match). The exact case the earlier impl wrongly granted — the primary new RED.
5. **Foreign notes → structured `.mismatch`,** never a false match.
6. **Provenance taxonomy:** `authoredIntent` / `controlledExport` / `eventListAX` distinct + non-interchangeable; manifest never in the observed slot.
7. **No production path:** 0 public API, 0 production caller, release DCE (product-level dup of criterion 1's release check).

## E0 (CI, no Logic) — rejection-only + non-forgeability + no-positive-type
Under the debug seam, build a `testFixture` and assert: all rejection cases (3a–f) + O→E-copy (4) + foreign-notes (5) yield non-matching verdicts (3e uses the seam-only corrupted-fixture maker; 3f is the PPQ guard); **plus** the type has no `.exactMatch` case (compile-level — positive match impossible); **plus** release DCE (0 seam symbols). **No positive-grant control** (removed by design — a note-identical fixture proves "the seam was called," not independence).

## R2 acceptance criteria (live, later) — where the positive grant lives
- **Named live-ingestion boundary** derives `E`'s notes from the independent source + a real temporal commitment (write-oracle: authored intent sealed before the AX read; dual-observation: distinct `C_alt` surface), making O→E structurally impossible; reintroduces `.exactMatch` and grants it only then, behind the qualified provider + public API.
- **`GO_dual = E0 ∧ E1 ∧ E2 ∧ E3 ∧ E5`:** coordinate-free managed-temp export exists + round-trips + observed acquisition completes + region-identity negative.
- **`GO_write_oracle = E0 ∧ E2c ∧ E3 ∧ E4 ∧ E5`** (no export needed): write-oracle fidelity + observed acquisition + manual-edit mismatch (non-tautology) + region-identity negative.
- Any "operator-delivered file" path counts only as **operator-assisted controlled export** (a human actuates the same `C_alt` surface, bound to registered export evidence) — never an arbitrary user `.mid`.
- On pass, promote the qualified provider + public API with the claim below.

## Public claim boundary
- **R1:** "a fixture-bearing `IndependentExpectedProof` cannot be constructed in a release/product build (only `.unproven` exists there; the fixture payload + makers are absent from release binaries — DCE), and R1 asserts no independence and makes positive verification impossible at the type level — the verify guard has no positive-match case and only rejects or reports a structured mismatch."
- **R2 (write-oracle):** "the server can independently verify that a region it authored (via MIDI import / `record_sequence`) reads back note-identical." Any-region independent verification requires the dual-observation export path.

## Transform interaction (#303 / #446)
Sharing #445 snapshot + canonical diff primitives is not transform-State-A independence. Transform State-A stays dark until a separate independence story ships. #446 is re-baselined onto this contract; it does not build independent infra ahead of #302.

## Non-goals
Any positive match in R1; a `.exactMatch` case in R1's verdict type; a temporal commitment or real mint in R1; arbitrary-region independent verification before the export path qualifies; putting a write manifest in the observed slot; framing a caller-trusted test fixture as an independence proof.

Toward #302 (stays open). Related: #293 (completeness core, shipped), #303/#446 (transform, dark). Design: ADR-014 (Decision B, strict).
