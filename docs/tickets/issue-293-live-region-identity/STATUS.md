# Issue 293 — Live region identity with observation-scoped proof

ADR: Five blocked ADRs; identifiers and individual acceptance criteria not supplied. No unblock decision recorded.  
PRD: [PRD-issue-293-live-region-identity.md](../../prd/PRD-issue-293-live-region-identity.md)  
Size: L  
Current Phase: Specification — DRAFT. Implementation and qualification results for this change are not recorded.

The size reflects production Accessibility observation, Swift proof provenance, observation lifetime, Event List ownership and consumer migration. Updating six test constructors is a small part of the work. The supplied measurements do not establish that the available AX evidence can support non-positional production binding.

## Gates

| Gate | Status | Evidence or outstanding requirement |
|---|---|---|
| ADR | DRAFT | Five dependencies are reported, but their references and individual requirements are unavailable. None is marked unblocked. |
| PRD | DRAFT | Linked specification records the measured baseline, proposed contract, refusals and limits. Acceptance is not recorded. |
| Dev ticket | DRAFT | Work and falsifiable acceptance criteria are defined below. |
| TDD | NOT STARTED | No failing-first, passing or mutation results are recorded for this change. |
| final exact-head | NOT STARTED | No tested commit identifier, release result or live qualification result is recorded. |

A document’s presence does not constitute a passing implementation gate. Final qualification must identify the commit actually tested. Results from an earlier commit do not qualify a later change.

## Tickets

| Ticket | Work | Status | Dependency |
|---|---|---|---|
| LRI-1 | Define the descriptor/proof boundary and migrate six test construction sites | NOT STARTED | PRD contract |
| LRI-2 | Implement complete, non-positional production observation and unique binding | NOT STARTED | LRI-1 |
| LRI-3 | Enforce observation lifetime and Event List ownership | NOT STARTED | LRI-2 |
| LRI-4 | Integrate assessment and independent-verification limits | NOT STARTED | LRI-1–3 |
| LRI-5 | Qualify the final implementation and record ADR hand-off limits | NOT STARTED | LRI-1–4 |

## LRI-1 — Descriptor and opaque proof contract

### What it must establish

`ResolvedRegionIdentity` represents a binding backed by `RegistryResolvedIdentityProof`, rather than authority supplied by a caller’s field values.

The four-tuple remains an observed descriptor. `startTick` and ordinal leave the identity contract. A proof cannot be attached to another descriptor or scope.

The relevant surfaces are:

- `Sources/LogicProMCP/MIDIReadback/RegionIdentityRegistry.swift`
- `Sources/LogicProMCP/MIDIReadback/EventListReadbackEvidence.swift`
- `Package.swift`

### Acceptance

- Preserve the proof’s `fileprivate` initializer.
- Release `.proven` requires the opaque proof; there is no descriptor-only equivalent.
- Keep debug minting under `QUALIFICATION_FAULT_SEAM`, with no release fallback.
- Prevent consumer construction or mutation of proof-bearing identity from raw fields.
- Migrate all six construction sites across `EventListReadbackCollectorTests`, `MIDIReadbackAssessmentTests`, `Issue293DesktopVariantTests` and `Issue293EventListProviderTests`.
- Make test scope and proof evidence explicit. Tests of the production observer must not substitute debug-minted proof for observer execution.
- Record debug test and release build results.

### Mutation tests that must go RED

- Add a descriptor-only resolved-identity initializer: the consumer compilation check expecting rejection must fail.
- Make the proof initializer accessible to consumer code: the provenance boundary check must fail.
- Remove the release exclusion around the debug mint: the release boundary check must fail.
- Permit pairing one proof with another descriptor or scope: the mismatched-binding regression must fail.

Compilation checks must include ordinary consumer access. `@testable` or a qualification helper must not stand in for the release API boundary.

### Not in scope

Persistent region IDs, timing conversion, new identity discriminators, or migration beyond the supplied identity construction sites and affected consumers.

## LRI-2 — Complete production observation and unique binding

### What it must establish

A same-file production observer validates evidence before minting `RegistryResolvedIdentityProof`.

`enumerateRegionItems` and `selectedRegionInfos` return useful summaries. Their `RegionInfo` fields alone do not prove traversal completeness, source correspondence or non-positional track association.

The observer must obtain those facts or refuse.

### Acceptance

- Define the relevant candidate set so that every possible descriptor match is included.
- Preserve candidate multiplicity. Identical descriptors must not be deduplicated before matching.
- Resolve exactly one candidate only when enumeration is complete, track association is independently observed and the source region is bound to that candidate.
- Refuse zero matches, multiple matches, incomplete or unknown completeness, missing required fields, unavailable source correspondence and contradictory evidence.
- Refuse order-derived track association.
- Keep `kind` and `rawHelp` as context; do not use them to break a four-tuple collision.
- Exercise a valid unique case, a same-track non-colliding case and a same-track collision in deterministic tests.
- Independently permute region and track enumeration order. Valid bindings must remain unchanged; order-only inputs must refuse.
- Keep every release proof constructor call inside the reviewed validating boundary.

### Mutation tests that must go RED

- Replace the exactly-one check with “take first”.
- Deduplicate candidates by descriptor before counting.
- Ignore incomplete enumeration after finding a match.
- Pair track and region arrays by index or sorted position.
- Mint proof from a supplied descriptor without source correspondence.
- Use `kind`, `rawHelp` or an ordinal to choose between colliding descriptors.

### Not in scope

Proving that the tuple is globally unique, changing `record_sequence` to create regions on an existing track, or treating the failed duplicate attempt as a completed collision test.

## LRI-3 — Observation lifetime and Event List ownership

### What it must establish

Proof is usable only in its issuing observation and readback operation. Event List evidence has a separately observed relationship to the bound region.

The measured Event List surface returns eight columns and a Position string. That establishes accessibility of displayed note data, not ownership or exact timing.

### Acceptance

- Record observation scope with the registry binding and validate it at consumption.
- Reject proofs from another, invalidated or completed observation, including when descriptor values are identical.
- Revalidate source correspondence, uniqueness and observable Event List context before and after row collection.
- Refuse on observed changes, unavailable revalidation or missing ownership evidence.
- Do not use elapsed time alone as freshness evidence.
- Refuse valid-looking Event List rows whose region context is missing or mismatched.
- Do not bind rows by their order or by expected note count.
- Preserve Position as the observed string.
- Keep “no matching region” distinct from “a bound region has no notes”; the latter still needs complete, bound Event List evidence.
- Record the limit that successful revalidation is not an atomic snapshot guarantee.

### Mutation tests that must go RED

- Remove the observation-scope comparison.
- Accept an old proof because its descriptor still matches.
- Skip required revalidation or ignore an observed invalidation.
- Treat an open Event List or selected region alone as row ownership.
- Accept rows with missing or mismatched region context.
- Pair expected notes and observed rows by order as evidence of ownership.

### Not in scope

An atomic snapshot of Logic Pro, detection of every unobserved intervening edit, persistent proof reuse, or exact tick conversion.

## LRI-4 — Assessment and independent-verification integration

### What it must establish

`MIDIReadbackAssessment` and `MIDINoteIndependentVerification` recognise the stronger identity evidence without widening unrelated claims.

A region proof establishes only its checked region binding. It does not supply Event List ownership, complete note evidence, measurement independence or exact timing.

### Acceptance

- Pass valid proof-bearing identity through the production readback path.
- Keep descriptor-only observations unproven.
- Propagate identity and row-binding refusals without promoting them to successful verification.
- Require the existing independent-verification conditions in addition to region identity.
- Refuse any exact tick claim based on descriptor bar bounds or the Position string.
- Preserve raw observed Position text and the distinction between an observation and a derived claim.
- Ensure command acknowledgement cannot substitute for confirming readback.
- Run affected collector, assessment, desktop-variant and Event List provider tests.

### Mutation tests that must go RED

- Treat a unique-looking descriptor as `.proven`.
- Treat a valid region proof as sufficient for independent note verification.
- Drop an Event List ownership refusal before assessment.
- Derive `startTick` from bar bounds or approve exact timing from the Position display.
- Upgrade an unconfirmed command acknowledgement into verified readback.

### Not in scope

Redesigning note verification, introducing a timing model, or declaring any downstream ADR satisfied merely because region identity is available.

## LRI-5 — Live qualification and downstream hand-off

### What it must establish

Qualification separates the supplied baseline, newly exercised production behaviour and scenarios that remain unproduced.

The baseline is:

- 9 regions, then 10; every name was `MIDI Region`.
- All 10 four-tuples were unique.
- No track contained more than one observed region.
- Duplicate returned state `B`, reason `readback_unavailable` and `success:true`, with no change in observed region count.
- `record_sequence` creates a new track on every call.

This baseline does not qualify same-track discrimination.

### Acceptance

- Record the tested commit, build configuration and fixture conditions for final results.
- Record required debug tests, release build and release provenance checks at that commit.
- Exercise the production observer live. Record completeness evidence, non-positional track association, source binding, candidate count and observation scope for any successful identity claim.
- Observe more than one region on a track before describing a same-track scenario as exercised.
- For a same-track non-colliding case, establish correct binding independently of region order.
- For a same-track collision, observe two regions with the same name and identical bar bounds before assessing refusal.
- If the collision cannot be constructed, record the scenario as inconclusive, including the attempted route and observed counts. Do not record a pass.
- Exercise stale scope and missing or mismatched Event List context in maintained tests; record live results only where actually measured.
- Record which exact tick claims were refused and retain the source strings.
- Obtain the actual references and requirements for the five blocked ADRs before recording individual unblock decisions. For each, state which identity requirement the evidence satisfies and which requirements remain unmet.
- Do not mark final exact-head PASS while required qualification evidence is missing. A safe refusal is valid behaviour, but does not establish successful production binding.

### Mutation tests that must go RED

At the final candidate commit, re-run representative mutations against the maintained tests:

- First-candidate selection in place of unique binding.
- Ignoring incomplete enumeration.
- Index-based track association.
- Cross-observation proof reuse.
- Accepting Event List rows without ownership evidence.
- Descriptor-only promotion in a release consumer.

Each mutant must fail its corresponding regression. A mutant that remains green leaves that requirement unverified.

### Not in scope

Repairing the duplicate command, changing region-creation behaviour, fabricating a same-track fixture result, assigning invented ADR identifiers, or adding a separate reporting framework.

## Not claimed

This ticket records a proposed change and its required evidence. It does not record completed implementation, passing tests or release qualification.

The supplied campaign measurement does not establish same-track collision behaviour, non-positional track provenance, enumeration completeness, persistent identity, Event List row ownership, exact ticks or independent note verification.

The five blocked ADRs remain individually unassessed until their actual requirements are available.
