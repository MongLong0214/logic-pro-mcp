# ADR-015 (#303) is not blocked by the seam — it has no independent source at all

Size: **L**, because the code is small and the contract is not: it has to decide what counts as an
independent root, and then decide what a legitimate difference between authored and stored notes is.
Neither is derivable from the tree.

## 1. The measurement, and its limits

Taken 2026-09-09 in this tree.

**The roadmap says #303 waits on `QUALIFICATION_FAULT_SEAM`. Checked, and that reading is wrong.**
The enum that carries an independent expectation has exactly one producer:

    Sources/.../MIDINoteIndependentVerification.swift:39
        enum IndependentExpectedProof {
            case unproven
            #if QUALIFICATION_FAULT_SEAM
            case testFixture(CallerTrustedFixture)
            #endif
        }

Removing that guard would not make `independentPayload` reachable, because the only value it can
carry comes from `case .testFixture`. `grep -rn IndependentExpectedRoot Sources/` outside that one
module returns **nothing**. There is no production producer of an independent expectation anywhere.

**The design already names what the roots should be** (`MIDINoteIndependentVerification.swift:20`):

    case authoredIntent    // write-oracle: pre-authored write intent (import / record_sequence)
    case controlledExport  // dual-observation: a distinct Logic→notes surface

**And `authoredIntent` demonstrably exists at the write site.**
`TrackDispatcher+RecordSequence.swift:93` holds `events: [SMFWriter.NoteEvent]`, parsed from the
caller's string BEFORE Logic is touched. Measured live today with the shipped binary: the sequence
`60,0,500,100;64,500,500,80;67,1000,500,127` at tempo 120 imported and returned
`success: true, verified: true`.

**What that `verified: true` means, measured rather than assumed.** It is REGION-level. The path
re-reads live track headers, confirms the import created a track, and verifies a region exists on
it. It does not read a single note back, and it does not compare anything to `events`. So the
authored notes are, today, written and never checked.

**NOT MEASURED, and it is the ticket's first step:** whether Logic stores those notes unchanged.
Quantization, tempo mapping, channel assignment and note-off rounding could all move a value
legitimately. Nobody has read the three notes back and diffed them against what was authored. Until
that reading exists, any tolerance rule in this ticket would be invented.

## 2. The decision this ticket must make

**What is an independent root, and what is a legitimate difference.**

`authoredIntent` is independent of Logic's READBACK — the SMF was written before Logic saw it — and
that is the property the verification needs. It is NOT independent of the caller: a caller who
authored the wrong notes gets a match against their own mistake. That is acceptable and must be
stated, because the ADR's word is "independent" and readers will assume more than it delivers.

`controlledExport` is the stronger root and needs a second Logic→notes surface that does not share
the Event List's conversion. Naming that surface is out of scope here; this ticket takes
`authoredIntent`.

## 3. Exact changes

- Mint at the WRITE site, not later. `TrackDispatcher+RecordSequence` holds the authored events; a
  proof reconstructed after the fact from anything Logic reported is derived from the observation
  and is not independent.
- Bind to the region identity `RegionIdentityRegistry` mints, which means the mint happens after the
  import creates the region and before any readback runs. That ordering is the correctness of the
  whole thing and belongs in an assertion, not a comment.
- Mint discipline as in `RegionIdentityRegistry.swift:20`: a `fileprivate init`, one producer.
- `IndependentExpectedProof` keeps `case .testFixture` under the seam for FAULT injection and gains
  a shipped `case authored(AuthoredExpectation)`.

## 4. Call sites

Three. `TrackDispatcher+RecordSequence.swift:93` (mint), `MIDINoteIndependentVerification.swift:50`
(`independentPayload` learns the new case), and `RegionIdentityRegistry` (ordering). No other module
references `IndependentExpectedRoot` — verified by grep.

## 5. Acceptance criteria that can fail

- A RELEASE build returns a positive `verifyRegion` match for a region written by `record_sequence`
  with notes that round-trip, and `incompleteCannotVerify` when the mint did not happen.
- The authored proof cannot be constructed outside its minting file — a compile check using
  ordinary consumer access.
- A region written by one call cannot be verified against another call's authored notes: the region
  identity binding refuses it.
- `record_sequence` reports a NOTE-level result, so that today's region-level `verified: true` stops
  being the strongest thing it can say.

## 6. Mutations that must turn a test RED

| edit | test |
|---|---|
| mint from the readback instead of from `events` | the independence test — same value twice must not match |
| drop the region-identity binding | the cross-region test |
| widen the mint initializer | the consumer-access compile check |
| mint before the region exists | the ordering assertion |

## 7. Not in scope

`controlledExport`. The `QUALIFICATION_FAULT_SEAM` mint-discipline change for ADR-010/014, which is
`docs/tickets/release-provable-readback/` and lands first. Any change to fault injection.

## 8. What this does NOT establish

That a match means Logic played the notes — it means Logic stored what was authored, as read through
one surface. And nothing here establishes the tolerance rule; §1 says why, and the first step is the
reading that would let anyone write one.
