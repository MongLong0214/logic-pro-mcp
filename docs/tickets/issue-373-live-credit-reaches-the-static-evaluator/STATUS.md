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

- [x] extract PromotionGate's pass predicate to a named function; PromotionGate uses it
- [x] `ProductionReadinessContracts.evaluate` gains `liveCreditedOperationIDs`, default empty
- [x] a producer that derives that set from an attestation via the named predicate
- [x] tests: empty default preserves today's finding; a credited operation leaves
      `missingSemantic`; a `.passed` case that fails any conjunct does NOT credit
- [x] duplicates counted where `evaluate` counts them — over RAW case ids, before filtering
- [x] a live harness proving a real run reaches the debt board

## What review added that the plan did not have

Sharing the predicate was not sufficient, and the plan said it would be. Two evaluators also have to
agree about which cases EXIST: counting duplicates after the canonical filter credits an operation
out of an attestation the release gate refuses. The plan's property 1 said "the pass predicate must
not be restated" and that was true but incomplete — the CASE SET is a second thing both authorities
read, and it was restated too.

## Measured, 2026-09-09, this branch

    credited                        21   of 113 registered
    missing without credit         113
    missing with credit             92
    drop equals the credited set   yes
    read-only short of passed        2   tracks.list_library, tracks.scan_plugin_presets

R-SEM stays open on a bare tree: the parameter defaults to empty and nothing in `Sources/` feeds it
yet. Making a real release reach it is #815's half of the chain, and #815 is blocked on #284 — see
the comment on #815 for why removing the workflow guards would break every release rather than close
the debt.
