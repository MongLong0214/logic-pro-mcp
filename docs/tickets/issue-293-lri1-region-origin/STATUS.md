# Issue 293 / LRI-1 — the region origin left the identity contract and note readback still needs it

Issue: [#293](https://github.com/MongLong0214/logic-pro-mcp/issues/293) — ADR-010
Branch under repair: `feat/293-lri1-descriptor-proof` in `~/lpm-wt-815`
Size: **M, because the refusal itself is three lines and the cost is the type that makes it structural — without that, one reverted line ships absolute ticks as region-relative.**

Status: **specified, not implemented.**

## 1. The measurements this rests on

**The wall (live, 2026-09-08).** A live region publishes `name`, `trackIndex`, `startBar`, `endBar`
plus `kind` and `rawHelp`. No tick, no ordinal. Finest granularity is a bar, as localised prose.
Recorded in `2026-09-08-the-region-surface-has-no-ticks`.

**The bridge (source reading, same day).** `parseNote` reads Position as ABSOLUTE bar/beat/division/
tick and returns region-relative ticks. The bridge is one subtraction:

```swift
let (relativeStart, overflow) = start.subtractingReportingOverflow(regionStartTick)
```

Recorded in `2026-09-08-the-region-origin-is-the-bridge-not-a-label`, whose conclusion was rescoped
after review: the origin is absent **from that surface**, and the tempo/signature maps were never
looked for.

**The cost (counted, not estimated).** Against `MIDIReadbackAssessmentTests` (63 tests):

```
#expect(snap.complete)                   4 expectations
partialReason == .countMismatch          9 expectations   <- all AFTER the parse loop
partialReason == .harvestNotContiguous   2
```

**What would change if a reading were wrong.** If a tempo-map read can supply an exact origin, this
ticket is the wrong shape and should be withdrawn rather than adjusted — the refusal would be
premature. Nobody has looked; that is stated, not assumed away.

## 2. The decisions, and why the alternatives are worse

**Reason name: reuse `.timingUnproven`. Do not add a `PartialReason` case.** A missing region origin
IS the timing required to place a note being unproven, and `e.timing.isProven` being true does not
supply it. A second case for the same fact would let a caller believe the two are distinguishable
when they are not.

**Placement: after the count oracle, not before the parse loop.** Refusing right after the
`timing.isProven` guard is the obvious spot and it is worse: it makes the parse loop and the count
oracle unreachable, re-points 13 expectations, and retires the check that derived note count equals
the independent AX count — a check that does not depend on the origin at all. The count oracle
survives because counting rows needs no coordinate space.

**Rejected — carry a sentinel origin (0) and refuse at the end.** Invents a value to make code
compile. Forbidden here by name, and it would make every parsed `startTicks` silently absolute while
looking region-relative.

**Rejected — report absolute ticks and let the caller convert.** Moves the blast radius onto every
consumer of `MIDINoteEvent.startTicks` and changes the meaning of a shipped field without a way for
a caller to notice.

**The refusal must be structural, not a line someone can delete.** If `parseNote` keeps returning
`MIDINoteEvent` with an absolute `startTicks`, then deleting the refusal ships absolute ticks in a
field documented as region-relative, and nothing fails. So the parse loop stops producing
`MIDINoteEvent` at all: it produces a reading that cannot become one without an origin, and
`.complete([MIDINoteEvent])` becomes unreachable **by construction**. The compiler enforces the
refusal; a reverted line does not compile.

## 3. The change, exact

### 3.1 New type, in `MIDIReadbackAssessment.swift` beside `PartialReason`

```swift
/// One note read from an Event List row, in the coordinate space the Event List actually supplies.
///
/// `startTicks` is deliberately ABSENT. The Event List reports Position as absolute bar/beat/
/// division/tick; a caller asks for region-relative; and the only bridge is `start - regionOrigin`,
/// which the region surface does not supply (measured 2026-09-08 — name, trackIndex, startBar,
/// endBar, and no tick). A reading that cannot state where the region begins cannot state where a
/// note begins inside it, so it does not carry a field claiming to.
///
/// This exists so the refusal below cannot be deleted. While `parseNote` returned `MIDINoteEvent`,
/// removing the refusal shipped absolute ticks in a field documented as region-relative and nothing
/// failed. There is no initialiser from this to `MIDINoteEvent`; supplying one requires an origin,
/// and finding an origin is the work this ticket does not do.
struct AbsoluteNoteReading: Equatable, Sendable {
    let pitch: UInt8
    let absoluteStartTicks: Int64
    let durationTicks: Int64
    let velocity: UInt8
    let channel: UInt8
}
```

### 3.2 `parseNote` loses its origin parameter

**Before** (`MIDIReadbackAssessment.swift:322-326`):

```swift
private func parseNote(
    row: RawEventRow,
    roles: [ColumnRole: AXColumnID],
    regionStartTick: Int64
) -> MIDINoteEvent? {
```

**After:**

```swift
private func parseNote(
    row: RawEventRow,
    roles: [ColumnRole: AXColumnID]
) -> AbsoluteNoteReading? {
```

**Before** (the subtraction, `:364`):

```swift
    // Region-relative start; overflow-safe subtraction.
    let (relativeStart, overflow) = start.subtractingReportingOverflow(regionStartTick)
    guard !overflow, relativeStart >= 0, duration > 0 else { return nil }
    return MIDINoteEvent(pitch: ..., startTicks: relativeStart, durationTicks: duration, ...)
```

**After:**

```swift
    // No subtraction: there is no origin to subtract. `start` is what the Event List reported.
    guard start >= 0, duration > 0 else { return nil }
    return AbsoluteNoteReading(pitch: ..., absoluteStartTicks: start, durationTicks: duration, ...)
```

The overflow check goes with the subtraction that could overflow. `start >= 0` replaces
`relativeStart >= 0` and keeps the row-level rejection of a negative position.

### 3.3 The parse loop and the outcome

**Before** (`:203-215`, then `:218`):

```swift
    var parsed: [MIDINoteEvent] = []
    for key in e.harvest.orderedRowKeys {
        guard let row = e.harvest.passA[key] else {
            return .incomplete(.harvestNotContiguous)
        }
        switch parseNote(row: row, roles: roles, regionStartTick: observed.startTick) {
        case let .some(note):
            parsed.append(note)
        case .none:
            return .incomplete(.rowParseFailed(key))
        }
    }

    // Count oracle: derived note count must equal the independent AX count.
    guard let count = parseCount(e.itemCount.rawCountText), count == parsed.count else {
        return .incomplete(.countMismatch)
    }

    return .complete(parsed)
```

**After:**

```swift
    var parsed: [AbsoluteNoteReading] = []
    for key in e.harvest.orderedRowKeys {
        guard let row = e.harvest.passA[key] else {
            return .incomplete(.harvestNotContiguous)
        }
        switch parseNote(row: row, roles: roles) {
        case let .some(note):
            parsed.append(note)
        case .none:
            return .incomplete(.rowParseFailed(key))
        }
    }

    // The count oracle still runs, and it is why the refusal is HERE rather than before the loop:
    // whether the derived note count equals the independent AX count is a property of the row set,
    // not of any coordinate space. Refusing earlier would retire this check for a reason unrelated
    // to it.
    guard let count = parseCount(e.itemCount.rawCountText), count == parsed.count else {
        return .incomplete(.countMismatch)
    }

    // Every row parsed and the count agrees — and the readback still cannot be completed, because
    // the notes are in absolute coordinates and the caller's contract is region-relative. The
    // region surface supplies no origin (measured 2026-09-08). `.timingUnproven` is the existing
    // and correct name: the timing needed to place these notes is not proven.
    //
    // This return cannot be deleted into a working `.complete`: `parsed` is `[AbsoluteNoteReading]`
    // and `.complete` takes `[MIDINoteEvent]`, with no conversion that does not require an origin.
    return .incomplete(.timingUnproven)
```

## 4. Every call site, enumerated and classified

| site | classification |
|---|---|
| `MIDIReadbackAssessment.swift:205` parse loop | the change above |
| `MIDIReadbackAssessment.swift:218` `.complete(parsed)` | replaced by the refusal |
| `parseNote` — one definition, one caller | signature change, mechanical |
| `MIDINoteEvent` (`MIDINoteReadback.swift:26`) | **unchanged.** Still the public shape, still region-relative. Nothing constructs it on this path any more. |
| `MIDINoteReadback.swift:230` `reason: PartialReason = .timingUnproven` | unchanged; the default already is this reason |
| exhaustive `switch` over `PartialReason` in `Sources/` | **none exist** — verified by search, so no case updates |

## 5. The 13 expectations, each classified

| expectation | count | disposition |
|---|---|---|
| `partialReason == .countMismatch` | 9 | **unchanged.** The count oracle still runs and still fails first for these fixtures. |
| `partialReason == .harvestNotContiguous` | 2 | **unchanged.** Both precede the loop or fire inside it. |
| `#expect(snap.complete)` — `verifiedEmptyIsComplete` | 1 | **unchanged.** The proven-empty branch returns `.complete([])` and never needed an origin. |
| `#expect(snap.complete)` — `fullyProvenEvidenceIsComplete` | 1 | **converted.** Becomes `notesBearingEvidenceRefusesForWantOfARegionOrigin`, asserting `!snap.complete` and `partialReason == .timingUnproven`, and keeping the existing assertions about pitch/velocity/channel **deleted** — they asserted on `snap.notes`, which is now empty by contract. |
| `mapDimensionsAreUnpopulated` (`:337`) | 1 | **converted.** Uses `Self.evidence()`, the notes-bearing default, so it reaches the parse loop. Replace `#expect(snap.complete)` with `#expect(!snap.complete)` and `#expect(snap.noteCompleteness.partialReason == .timingUnproven)`. Its other two assertions — `tempoMapCompleteness` and `timeSignatureCompleteness` both `.incomplete(.mapsUnpopulated)` — are about a different dimension and stay **unchanged**; the test's subject is the tempo/signature maps, not note completeness. |
| `tickPrecisionPreservedNear2p53` (`:600`) | 1 | **deleted, and its subject re-tested elsewhere.** It asserts `snap.notes.first?.startTicks == 2^53 + 1`, which is a claim about the SUBTRACTION this ticket removes — with no origin there is no region-relative start to preserve precision in. Deleting it silently would drop the Int64-vs-Double coverage it exists for, so replace it with `parseNote` asserting `AbsoluteNoteReading.absoluteStartTicks == 9_007_199_254_740_993` for the same `[2^53, 1, 0, 0]` position group. The precision property survives; the coordinate space it was asserted in does not. |

Nothing is left open. An earlier draft deferred the last two rows to "the implementer, against the
fixture each uses" — which a merge-gate inventory flagged against this repository's own ticket
standard, and correctly: *"every judgement left in a ticket is a decision made by whoever picks it
up, at the moment they are least equipped to make it, and it will not be recorded anywhere."* Both
were decidable by reading the two fixtures, which took one command. Deferring them was not caution;
it was moving my work into someone else's round.

One consequence to carry into implementation: the overflow test at `:600` is the only place the
Int64 accumulator is exercised near 2^53, so it must be re-pointed rather than dropped, and its
replacement asserts the same numeral in the coordinate space that still exists.

## 6. Acceptance criteria that can fail

1. `fullyProvenEvidenceIsComplete`'s successor asserts `!snap.complete` and
   `partialReason == .timingUnproven`, and the suite compiles with no reference to `observed.startTick`.
2. `verifiedEmptyIsComplete` passes **unchanged** — a bound region with no notes is still a complete
   answer.
3. All 9 `.countMismatch` expectations pass unchanged, proving the count oracle still executes.
4. Neither `regionStartTick` nor `observed.startTick` appears anywhere in
   `Sources/LogicProMCP/MIDIReadback/MIDIReadbackAssessment.swift`:

   ```
   grep -c 'regionStartTick\|observed\.startTick' …/MIDIReadbackAssessment.swift   -> 0
   ```

   **Not `grep -c startTick`.** That was the criterion until a merge-gate inventory showed it is
   unsatisfiable: `calibration.startTickValue` contains the substring and is untouched by this
   ticket — three occurrences at `:188`, `:189` and `:314` survive by design, and the prescribed
   comments add more. A criterion an implementer cannot satisfy by doing the work correctly is a
   criterion that teaches them to edit the check.
5. A consumer that writes `MIDINoteEvent(pitch:startTicks:...)` from an `AbsoluteNoteReading` does
   not compile, using ordinary access rather than `@testable`.
6. `swift build -c release` succeeds and the release binary exports no `AbsoluteNoteReading ->
   MIDINoteEvent` conversion.

## 7. Mutations that must turn a named test RED

| mutation | test |
|---|---|
| change the final `return .incomplete(.timingUnproven)` to `.complete([])` | criterion 1 — it would report complete with no notes |
| move the refusal to just after the `timing.isProven` guard | criterion 3 — the 9 count-mismatch expectations get `.timingUnproven` instead |
| give `AbsoluteNoteReading` a `startTicks` alias and construct `MIDINoteEvent` from it | criterion 5 |
| drop the `start >= 0` guard in `parseNote` | a row with a negative position parses instead of failing |
| make the empty branch return `.incomplete(.timingUnproven)` too | criterion 2 |

## 8. Not in scope

- **Finding an origin.** Tempo map, signature map, project file, a new AX read — none of it. If one
  works, this ticket is superseded rather than extended.
- **LRI-2..LRI-5.** Production observation and minting, observation lifetime, assessment
  integration, live qualification.
- **`MIDINoteEvent`'s shape.** It stays region-relative and stays public.
- **The release seam.** `RegistryResolvedIdentityProof` having no release mint is #293's other half
  and is untouched here.

## 9. What this ticket does NOT establish

- That region-relative note readback is impossible. It establishes that it is impossible **from the
  region surface alone**, which is the only surface examined.
- That refusing is the right product answer. It is the honest one given the evidence; a caller who
  needs note timing gets nothing from this path afterwards, and that cost is real.
- That the two unclassified `#expect(snap.complete)` sites convert cleanly. They are named, the
  question is binary, and the implementer is told to stop rather than guess.
- Anything about ADR-010's acceptance. A refusal that ships is not a feature that works.
