# PRD — ADR-014 / #302: Independent MIDI Event Readback

## Problem
The MIDI note-readback completeness core (ADR-010 / #293, shipped in #445) can prove an Event-List AX readback is *complete*, but deliberately grants no positive `exactMatch`: a pure core has no external root of trust to prove an expected sequence is independent of the observed Event-List conversion. #302 supplies the provider layer + a sealed independent-expected source so a positive, non-tautological match becomes possible.

## Scope split (R1 dark core / R2 live qualification)
- **R1 (this PR — dark, flag-off, CI-provable, no public API):** the sealed independence contract + guard, buildable and verifiable without Logic.
- **R2 (later, live-qualified):** the qualified provider + public API + positive-match claim, gated on real Logic experiments.

## Independence model
- **Observed** `O` = Event-List AX snapshot (`MIDIRegionNoteSnapshot`, from #445).
- **Independent expected** `E`, two classes:
  - **Dual-observation:** `E` from a *different* Logic→notes surface (e.g. a controlled MIDI export decoded by `SMFReader`), bound to the same region identity.
  - **Write-oracle:** `E` = pre-authored write intent (MIDI import / `record_sequence` manifest), sealed before the read, never re-encoded from observation.
- The decoder (`SMFReader`) is not the root of trust; the producing *surface* is.

## R1 acceptance criteria (enumerated; each gets a RED test first — TDD)
1. **Sealed `IndependentExpectedProof`:** no public/internal initializer, factory, or decoder; stored fields immutable.
2. **Bound to payload + identity:** the proof binds a root-of-trust id + region identity + a content digest of the expected notes/PPQ; a mismatch on any recomputes false.
3. **O→E derivation rejected:** an expected relabeled, re-encoded, or otherwise derived from the observed snapshot cannot mint a proof and cannot yield `exactMatch`.
4. **Label-only rejected:** a provenance string without a sealed proof cannot grant a match (fixes the legacy observed-only `provenance != .none` gate).
5. **Decoded-without-mint rejected:** a rehydrated/decoded expected with no live-minted proof is never complete/matchable.
6. **Provenance taxonomy:** `authoredIntent`, `controlledExport`, `eventListAX` are distinct and non-interchangeable; the manifest is never placed in the observed slot.
7. **Region-identity binding:** a match requires the expected and observed to bind the same region identity; a mismatch is rejected.
8. **Match still deferred at runtime:** with no live-qualified provider, no production path yields a positive match (release binary has no seam/proof mint; flag default off; 0 public API).
9. **Mint-site temporal binding:** the write-oracle proof is minted at author/import planning time from the write-intent bytes, BEFORE any AX read — never rehydrated from post-import success. There is exactly one mint site per class (write-intent/import manifest path; controlled-export path); the code names them.
10. **Independence-guard suite (E0) — rejections AND a positive control:** in CI, no Logic:
    - Rejections (4): O→E relabel / re-encode / provenance-spoof / decoded-without-mint → NO `exactMatch`.
    - **Positive control (1, seam-gated):** a genuinely sealed-minted proof with correct notes + matching region binding DOES grant `exactMatch` under the debug seam — proving the grant path is real, not vacuous "permanent darkness." Production (no seam) still grants none (criterion 8). Mirrors #445's `QUALIFICATION_FAULT_SEAM` positive/negative pattern.

## R2 acceptance criteria (live, later)
- Dual-observation GO: coordinate-free managed-temp export exists + round-trips + observed acquisition completes + **region-identity negative (wrong selection/binding → never silent match)**.
- Write-oracle GO (no export needed): write-oracle fidelity + observed acquisition + manual-edit mismatch (non-tautology) + region-identity negative.
- Any "operator-delivered file" path counts only as **operator-assisted controlled export** (a human actuates the same `C_alt` export surface, bound to registered export evidence) — never an arbitrary user `.mid`.
- On pass, promote the qualified provider + public API with the claim below.

## Public claim boundary
Write-oracle: "the server can independently verify that a region it authored (via MIDI import / record_sequence) reads back note-identical." Any-region independent verification requires the dual-observation export path.

## Transform interaction (#303 / #446)
Sharing #445 snapshot + canonical diff primitives is not transform-State-A independence. Transform State-A stays dark until a separate independence story ships. #446 is re-baselined onto this contract; it does not build independent infra ahead of #302.

## Non-goals
Any positive match without a sealed independent proof; arbitrary-region independent verification before the export path qualifies; putting a write manifest in the observed slot.

Toward #302 (stays open). Related: #293 (completeness core, shipped), #303/#446 (transform, dark).
