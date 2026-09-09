# #373 — the static evaluator cannot see live coverage, so R-SEM can never close

## What is actually blocking

`#373`'s exit criterion is that every registered operation reaches `passed` with
semantic-readback evidence **or** carries a governed waiver, and that
`productionReadinessContractsAreSatisfiedOnCurrentTree` then asserts zero open debts.

Two evaluators decide that, and only one of them can ever say yes.

| evaluator | input | credits an operation when |
|---|---|---|
| `PromotionGate.evaluate` (release time) | a `ReleaseQualificationAttestation` from a live run | `status == .passed && verified && verificationKind == .semanticReadback && readback.verified` — `PromotionGate.swift:144-148` |
| `ProductionReadinessContracts.evaluate` (repo tree) | the repo tree | **a governed waiver, and nothing else** — `ProductionReadinessContracts.swift:545-556` |

The second one takes no live input at all. Its own comment says so:

> This static repo-tree evaluator has no live `.passed` data (that matrix is #284),
> so an operation counts as missing unless a qualifying governed waiver covers it.

So R-SEM is not open because coverage is short. It is open because **the evaluator that
reports it has no channel through which coverage could arrive**. Running the live matrix
to completion would not move it by one operation. That is the blocker, and it is a
different blocker from the one #284 carries.

## What closing it means

Give `ProductionReadinessContracts.evaluate` a live-credited operation set, and make the
*only* producer of that set a function that applies **PromotionGate's own predicate** to a
real attestation. Two properties decide whether this is honest:

1. **One authority.** The pass predicate must not be restated. Today it lives inline in
   `PromotionGate.evaluate`; it gets a name, and both callers use the named one. A second
   spelling of "what counts as passed" is the defect this whole issue exists to avoid.
2. **Fail-closed and not self-attesting.** The parameter defaults to empty, so nothing
   closes by accident and today's behaviour is unchanged. A hand-written list of operation
   IDs must not be able to feed it — the credit is computed from an attestation, and the
   attestation's binary identity is already checked by the gate that produced it.

## Explicitly not in scope

- The live matrix itself (#284). This ticket makes its result *legible*; it does not run it.
- The B1-B4 `phase*MutatingOperationIDs` sets. Those record what was pinned when, and
  back-dating an operation into one falsifies that record (CommitLore `d8b7440f`).
- Flipping `productionReadinessContractsAreSatisfiedOnCurrentTree` to zero debts. R-SEM
  stays open on this tree, because on this tree the live-credited set is empty. The flip is
  earned by evidence, not by this change.

## Status

- [ ] extract PromotionGate's pass predicate to a named function; PromotionGate uses it
- [ ] `ProductionReadinessContracts.evaluate` gains `liveCreditedOperationIDs`, default empty
- [ ] a producer that derives that set from an attestation via the named predicate
- [ ] tests: empty default preserves today's finding; a credited operation leaves
      `missingSemantic`; a `.passed` case that fails any conjunct does NOT credit
