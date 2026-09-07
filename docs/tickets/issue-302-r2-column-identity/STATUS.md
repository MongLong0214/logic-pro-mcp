# Pipeline Status: #302 R2 — Event List column identity

**ADR**: docs/adr/ADR-014-independent-midi-event-readback.md
**Predecessor**: docs/tickets/issue-302-r1-independence-guard/ (R1 shipped)
**Size**: S
**Current Phase**: 3 (dev ticket) — this document

## Why this is small, and why it was thought large

Two statements of the blocker were carried in the roadmap and **both were wrong**. Re-measured
2026-09-04 on the live Event List:

| claim carried | measured |
|---|---|
| `AXColumns` is absent (issue header) | present, and resolves — status 0 |
| `AXColumns` returns 8 columns (roadmap row) | **6** |

So the blocker is not that columns cannot be read. It is that **identity does not live on them**:
every column's `AXTitle` and `AXDescription` is empty. The names are on the `AXHeader` sort
buttons — `L`, `M`, `위치`, `이름`, `트랙`, `길이` — which is the route
`EventListReadbackCollector.sortButtonTitles` **already takes** today, filtering children by
`AXSubrole == AXSortButton` and reading their titles verbatim.

R2 is therefore wiring and proof, not discovery.

## Gates
| Gate | Artifact | Status |
|------|----------|--------|
| 1 | ADR (ADR-014) | PASS (R1) |
| 2 | PRD | PASS (R1) — R2 adds no new contract |
| 3 | Dev ticket (this) | DRAFT |
| 4 | TDD | NOT STARTED |
| final | exact-head | NOT STARTED |

## Tickets
| Ticket | Status | Notes |
|--------|--------|-------|
| T1 — column identity from the header, not the columns | DRAFT | see below |

## T1 — column identity from the header, not the columns

**What it must establish.** That a column's identity is bound to the sort-button title observed on
the same read, and that a column whose identity cannot be established **refuses** rather than being
positioned by index.

**Why the refusal is the point.** Pairing a column with a name by ORDER is exactly the positional
binding this repository refuses everywhere else, and the Event List is where it would be most
tempting: six columns, six buttons, an obvious zip. The header is a separate subtree from the
columns, and nothing observed says the two orders must agree — that they did on one host, in one
locale, is not a rule.

**Localisation is load-bearing, not a footnote.** Four of the six titles measured are Korean
(`위치`, `이름`, `트랙`, `길이`) and two are not (`L`, `M`). Any literal comparison against English
column names is a one-language table of the kind #803 was opened for, so identity has to resolve
through `AXLocalePolicy` label sets rather than through string equality.

## Acceptance

1. Column identity is derived from the header sort buttons and **carries the observed title**, so a
   readback can say which rendered string it bound to.
2. A column with no resolvable identity refuses, with a typed reason naming the column index and
   what was read there. It does not fall back to position.
3. The count is read rather than assumed: 6 on the measured host, and a different count is a
   reported observation rather than a crash or a silent truncation.
4. Mutation-tested: forcing the header read to return `[]`, returning one fewer button than there
   are columns, and returning the buttons in a different order must each turn a test RED.
5. A live run on a Japanese Logic is recorded before this closes, because the measured titles are
   ko-KR only and #803's lesson is that a set measured in one language is a claim about that
   language.

## Not in scope

- The 90 mutating operations' `.passed` branch. It deliberately does not exist (the runner probes
  with parameters that must be refused and asserts `writeAttempted == false`), and adding one would
  be moving the grader.
- The release-build seam. `IndependentExpectedSeam` sits inside `#if QUALIFICATION_FAULT_SEAM` and
  the shipped binary carries zero seam symbols; that is one fact shared with ADR-010/015/017 and
  belongs to its own issue, not here.

## Open, and honest about it

Whether the header's button order and the column order ever disagree was **not** measured — the
refusal above exists because it is unknown, not because a disagreement was observed.
