# The readback proofs cannot exist in what ships — the live ingestion boundary

Size: **M**, because the code change is small and localised but the decision it encodes is the
whole point: how a release build mints a proof that only a real observation can produce, without
reintroducing the forge-able path `#399` removed.

Unblocks **ADR-010 (#293)** and **ADR-014 (#302)**. All three of #293/#302/#303 name this seam as
their blocker, but §4 shows that is only true for two of them: ADR-015 (#303) is blocked by
something else that was being read as this, and naming it is part of this ticket's result.

## 1. The measurement, and its limits

Verified 2026-09-09 in this tree, not taken from the roadmap on trust:

    Package.swift:48   .define("QUALIFICATION_FAULT_SEAM", .when(configuration: .debug))
    nm on the shipped release binary   IndependentExpectedSeam symbols: 0
                                       QualificationFault      symbols: 0

And the types themselves, in `EventListReadbackEvidence.swift:63`:

    enum HeaderIdentityProof {
        case unproven
        #if QUALIFICATION_FAULT_SEAM
        case proven([ColumnRole: AXColumnID])
        #endif
    }

`ObservedRegionIdentityProof` (line ~104) has the same shape. So in a release build the `proven`
case **does not exist as a value at all**: `roles` returns nil unconditionally, column binding is
unsatisfiable, region match is unsatisfiable, and `verifyRegion` can only ever answer
`incompleteCannotVerify`. A positive note match is structurally impossible in what ships.

**This is not a bug in the ordinary sense.** It is the #399 CEO-audit property working exactly as
designed: no caller can forge a proof, because the constructor is not in the binary. The cost is
that the feature is also unreachable. Both halves are real and the ticket has to keep the first
while removing the second.

Limit: this establishes what the RELEASE binary can represent. It says nothing about whether the
live AX ingestion in front of these types reads Logic correctly — #293 re-measured that separately
on 2026-09-04 and found the reading half settled.

## 2. The decision

**Restricted construction, not conditional compilation.**

The pattern is already in this codebase, one file over. `RegionIdentityRegistry.swift:10` states its
mint discipline in a comment and enforces it at line 20 with a `fileprivate init`, so
`ResolvedRegionIdentity` cannot be forged by any caller while still existing in release. The proofs
here should be minted the same way: the `proven` case ships, and its payload is constructible only
by the live collector that observed it.

`QUALIFICATION_FAULT_SEAM` keeps its actual purpose — FAULT INJECTION for tests — and stops being
the thing that decides whether a genuine proof can exist.

The alternative, keeping the case debug-only and having the release path answer "cannot verify"
forever, is what ships today and is what the three ADRs are blocked on. It is not a resting state:
it publishes an operation that can never return its own success.

## 3. Exact changes

### 3a. `Sources/LogicProMCP/MIDIReadback/EventListReadbackEvidence.swift`

Before (line 63):

    enum HeaderIdentityProof: Sendable {
        case unproven
        #if QUALIFICATION_FAULT_SEAM
        case proven([ColumnRole: AXColumnID])
        #endif

        var roles: [ColumnRole: AXColumnID]? {
            #if QUALIFICATION_FAULT_SEAM
            if case let .proven(map) = self { return map }
            #endif
            return nil
        }
    }

After — the case ships; the PAYLOAD is what cannot be forged:

    enum HeaderIdentityProof: Sendable {
        case unproven
        case proven(ObservedColumnRoles)

        var roles: [ColumnRole: AXColumnID]? {
            if case let .proven(observed) = self { return observed.roles }
            return nil
        }
    }

    /// Minted ONLY by the live header reader in this module. The initializer is fileprivate to the
    /// file that observes the columns, so no caller can bind arbitrary roles to arbitrary ids —
    /// the same discipline `RegionIdentityRegistry` states and enforces for region identity.
    struct ObservedColumnRoles: Sendable { let roles: [ColumnRole: AXColumnID] }

`ObservedRegionIdentityProof` takes the identical shape, and its payload type
`ResolvedRegionIdentity` ALREADY has the mint discipline — so that one only needs the `#if` removed.

### 3b. The minting site

`readHeaders` is the only place that has observed the columns. It gains the fileprivate initializer
and is the single producer of `ObservedColumnRoles`.

## 4. Call sites this reaches — all 22, classified

`grep -rn "QUALIFICATION_FAULT_SEAM" Sources/LogicProMCP/MIDIReadback/` gives 22 sites. Most of the
define's 27 uses across `Sources/` are fault injection and must not be touched; these are the ones
in this module.

**PROOF — in scope, the `#if` comes off and the payload gains mint discipline (17):**

    EventListReadbackEvidence.swift   12, 65, 70, 107, 112, 170, 175, 191, 196, 218, 223
    MIDIReadbackAssessment.swift      63, 64
    MIDINoteIndependentVerification.swift  10, 39
    EventListReadbackCollector.swift  13   (comment only — update the statement, no code)

**TEST SEAM — leave alone, this is the define doing its job (4):**

    RegionIdentityRegistry.swift      26, 29
    MIDINoteIndependentVerification.swift  59
    MIDINoteReadback.swift            192, 194   `makeCompleteForTesting`, whose own comment says
                                      "A test seam, not a security boundary"

**CANNOT BE RESOLVED MECHANICALLY — and the ticket decides it (1):**

`MIDINoteIndependentVerification.swift:50`, `independentPayload`. Removing its guard does NOT make
it reachable, because the only value it can return comes from `case .testFixture`:

    #if QUALIFICATION_FAULT_SEAM
    if case let .testFixture(s) = self { return (s.root, s.rootID, …) }
    #endif

There is **no production producer of an independent expectation at all.** The seam is not what
stands between ADR-015 and a release build — the absence of a second, independent source of truth
is. An independent verification whose only independent source is a test fixture is not independent;
it is the same value twice, and shipping it with the guard removed would be exactly the
self-asserted authority this project rejects.

**So this ticket splits.** Everything above is the mint-discipline change and it unblocks ADR-010
and ADR-014. `independentPayload` is NOT in it. What ADR-015 needs is a real independent source —
the imported SMF, a recorded expectation, something Logic did not produce — and that is a separate
ticket that has to name the source before any guard is touched.

## 5. Acceptance criteria that can fail

- A release build contains the `proven` case: `nm` on the release binary finds the mint symbol,
  where today it finds zero.
- `verifyRegion` in a RELEASE build can answer a positive match for a region whose notes were
  actually read, and still answers `incompleteCannotVerify` when any gate is unmet.
- A caller outside the minting file cannot construct `ObservedColumnRoles` — asserted by a test that
  uses ordinary consumer access and must fail to compile if the initializer is widened.
- The release binary still contains **zero** fault-injection symbols. The seam's own property is
  preserved, not traded away.

## 6. Mutations that must turn a test RED

| edit | test that goes red |
|---|---|
| widen `ObservedColumnRoles.init` to internal | the consumer-access compile check |
| have `readHeaders` mint roles without checking every header child | the header-mismatch test |
| return `.proven` when the column set is incomplete | the completeness-gate test |
| leave `ObservedRegionIdentityProof.proven` debug-only | the release-build positive-match test |

## 7. Not in scope

- The live AX ingestion itself. The three verification modules exist and #293 measured the reading
  half as settled; this is the boundary in front of them.
- Fault injection. `QUALIFICATION_FAULT_SEAM` keeps that job.
- ADR-014's positive grant (R2) and ADR-015's editing, which sit on top of this and are separate.

## 8. What this ticket does NOT establish

That removing the compile-time guard is safe on its own — it is safe only because the payload type
carries the mint discipline, and that discipline is enforced by file scope, which a later edit can
widen without any test noticing unless the compile check in §5 exists.

Nor does it establish that a positive match will be CORRECT once reachable: it makes the answer
possible, and #302's R2 is what proves the answer right.
