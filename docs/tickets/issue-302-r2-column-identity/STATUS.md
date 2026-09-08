# Pipeline Status: #302 R2 — WITHDRAWN as scoped; column identity was never the blocker

**ADR**: docs/adr/ADR-014-independent-midi-event-readback.md
**Predecessor**: docs/tickets/issue-302-r1-independence-guard/ (R1 shipped)
**Current Phase**: withdrawn at gate 3, before any code

## Why this is withdrawn rather than revised

The first draft of this ticket scoped R2 as "bind column identity from the header sort buttons
instead of from the columns", on the roadmap's reading that the live Event List exposes **6**
columns named `L, M, 위치, 이름, 트랙, 길이`.

Checked against the code before building on it, and the premise does not hold:

```swift
private static let regionLevelHeaderColumns: [AXLocalePolicy.LabelSet] = [
    eventListColumnL, eventListColumnM, eventListColumnPosition,
    eventListColumnName, eventListColumnTrack, eventListColumnLength,
]
```

That is the measurement, exactly — six columns, those six names. `AXLocalePolicy` labels three of
them "Region-level" in their own rationale strings. **The reading was taken while the Event List
was showing REGIONS**, not the selected region's events, and the collector already classifies that
state as `paneAtRegionLevel` — "a recoverable navigation failure, not a column-layout drift".

The note level, which is what this ADR reads, has **eight** columns:

```
["L", "M", "위치", "상태", "채널", "번호", "값", "길이/정보"]     measured, Korean Logic 12.3
```

## And identity is already bound, through the policy

`readHeaders` reads the header's `AXSortButton` children, refuses when they do not cover every
child (`headerSortButtonsUnavailable`), matches each title against `expectedHeaderColumns` — label
sets, not English literals — and throws `headerMismatch(expected:actual:)` naming the canonical
column and whatever Logic actually rendered. The comment above the table records why: comparing
against English literals "threw `headerMismatch` — the readback could not run at all outside
English".

Positions are used, but only after the order has been PROVEN: the loop asserts
`titles[i]` matches `expectedHeaderColumns[i]` for every `i`, and the count must match exactly.
That is not the positional pairing this repository refuses; it is an index used after identity has
been established at that index.

So the T1 that was drafted here would have re-implemented working code against a schema that
belongs to a different pane.

## What R2 actually is

From the R1 ticket, verbatim: *"R1 grants NO positive match in ANY configuration (incl. debug
seam), positive grant is future R2."* R2 is the **positive grant** — `verifyRegion` answering a
match rather than only rejecting.

Its blocker is not columns. It is the one recorded on ADR-010 and ADR-015: `IndependentExpectedSeam`
sits inside `#if QUALIFICATION_FAULT_SEAM`, `Package.swift` scopes that to debug, and the shipped
release binary carries **zero** seam symbols — so `independentPayload` is always nil there and
`verifyRegion` can only answer `incompleteCannotVerify`. A positive match is structurally
impossible in what ships.

A ticket for R2 therefore has to start from that seam, and it is shared with two other ADRs rather
than owned by this one.

## What this cost, and the rule it confirms

Nothing but the draft, because the premise was checked before code. The rule it confirms is the one
that says a document built on a wrong contract is withdrawn rather than resubmitted: revising the
acceptance criteria would have kept the misread measurement inside them.

## Not claimed

That the roadmap row's measurement was wrong — it was correct, and correctly transcribed. What was
wrong is what it was taken to be ABOUT. The row should say the reading was at region level.
