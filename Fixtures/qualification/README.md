# Managed qualification fixtures

These files are the managed, reproducible input **descriptors** for the
LPMCP-PRD-001 / ADR-001 qualification matrix. They close the repository-content
half of the `R-MATRIX` production-readiness debt ("managed fixture matrix
unbound"): the matrix descriptors now exist as byte-stable content that is
SHA-256-bound in `fixture-manifest.json`, rather than being named only by a
workflow marker. A consumer that drives them through a live Logic Pro session
does not exist yet (see "Scope and limitation").

## What these are

Each `desktop-<locale>-<size>.json` file is a **canonical descriptor** of the
project state a same-artifact qualification run is expected to establish for one
axis. A descriptor pins the deterministic project content (tempo, time
signature, sample rate, track layout) for its fixture size and records the axis
it belongs to (`variant / locale / profile / cache / fixture`).

They are honest content, not opaque labels:

- **Reproducible** — regenerated deterministically by `generate-fixtures.py`, so
  a clean tree is byte-identical.
- **SHA-bound** — `fixture-manifest.json` records the SHA-256 of every fixture's
  exact bytes. `ManagedQualificationFixtureTests` recomputes each SHA from disk
  and fails closed on any drift, so the identity is verified, not asserted.

## Ship matrix coverage

Owner decision (2026-07-17, ADR-001): Desktop Logic Pro is the only ship surface;
Creator Studio is permanently out of scope. The required same-artifact matrix is
therefore `desktop x {en-US, ko-KR}` with the `empty` project fixture — both
required axes are present here. The `medium` and `large` sizes are additional
managed inputs for broader reproducible coverage.

| variant | locale | empty | medium | large |
| ------- | ------ | ----- | ------ | ----- |
| desktop | en-US  | yes   | yes    | yes   |
| desktop | ko-KR  | yes   | yes    | yes   |

## Scope and limitation

These descriptors satisfy the repository `R-MATRIX` contract: the closer
`ProductionReadinessContractEvaluator.managedFixturesPresent` recomputes each
fixture's SHA-256, requires digest equality, and requires every ship-required
axis to be covered by a fixture whose SHA-bound descriptor declares that axis.
They are the canonical spec of each axis input; they do not themselves drive
Logic Pro, and no consumer of them exists yet. Automatically loading a descriptor
into a live Logic Pro session and consuming it end-to-end in the qualification
harness is a live step that belongs to the ADR-001 live-matrix program, not to
this repository-content debt.

## Regenerating

```
python3 Fixtures/qualification/generate-fixtures.py
```

The script rewrites every descriptor and `fixture-manifest.json` deterministically
and prints each fixture's SHA-256. A clean regeneration must leave the tree
unchanged.
