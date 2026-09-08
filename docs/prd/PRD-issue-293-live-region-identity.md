# Issue 293: observation-scoped live region identity

Status: DRAFT  
Dev ticket: [STATUS.md](../tickets/issue-293-live-region-identity/STATUS.md)

## Problem and measured baseline

MIDI readback needs evidence that the region being assessed is the region observed in Logic Pro. A name or a caller-constructed value does not establish that relationship.

The campaign fixture produced these measurements:

| Observation | Result | Limit |
|---|---|---|
| Region enumeration before and after creation | 9 regions, then 10 | These counts do not establish that the enumeration implementation detects every incomplete traversal. |
| Region names | Every observed region was named `MIDI Region` | Name alone collided 9 ways, then 10. |
| Descriptor `(name, trackIndex, startBar, endBar)` | Unique across all 10 observed regions; zero collisions | Uniqueness was established only for this observation. |
| Regions per track | No `trackIndex` had a count greater than 1 | The fixture did not exercise discrimination between regions on the same track. |
| Attempted duplication | `logic_edit duplicate` returned `{"state":"B","reason":"readback_unavailable","success":true,"method":"midi_key_command"}`; the region count did not change | No second region on the track was observed. The response does not establish successful duplication. |
| Region creation contract | `logic_tracks record_sequence` creates a new track on every call | Repeating this operation does not construct the required same-track test case. |
| Event List access | The note level was reachable and returned 8 columns; Position was a `bar beat division tick` string | Reachability and column content do not establish row ownership or exact tick values. |

The measurement establishes name collisions and descriptor uniqueness in a fixture with one region per track. It does not support calling tuple collisions the likeliest observed failure. Same-track collisions remain an unexercised risk.

The duplicate attempt did not produce the collision case. It did not establish that such a case is impossible.

## Required contract

### Descriptor

The four observed fields form a descriptor:

`(name, trackIndex, startBar, endBar)`

The descriptor reports what an observation says about a region. It is caller-constructible data and carries no authority by itself.

`kind` and `rawHelp` remain available as observed context or diagnostics. They must not silently break a four-tuple collision. Adding another identity discriminator would require its own measurement and contract change.

Remove `startTick` and `ordinal` from the region identity contract:

- Bar bounds must not be converted into an exact start tick.
- An ordinal, AX position, enumeration index or relative ordering must not identify a region.
- `trackIndex` is usable only with evidence that its association with the region was established without positional pairing. Its presence in `RegionInfo` does not prove that condition.

Descriptor uniqueness is necessary for this binding scheme, but is insufficient on its own.

### Resolved identity

`ResolvedRegionIdentity` becomes an immutable, observation-scoped binding backed by `RegistryResolvedIdentityProof`.

Its descriptor must be derived from, or checked against, the binding recorded by that proof. A caller must not attach a valid proof to a different descriptor or observation.

Promotion from descriptor to identity requires all of the following:

1. A production observation supplies region candidates and reports whether the relevant candidate enumeration completed.
2. The observation establishes each candidate’s track association without AX position or order.
3. The requested or selected source region is connected to the candidate evidence without positional pairing.
4. Exactly one candidate matches the descriptor in the complete relevant candidate set.
5. The registry records that binding in the current observation scope.
6. The binding remains valid when consumed under the freshness checks below.

The relevant candidate set must cover every region that could satisfy the descriptor. Enumerating only the selected item and finding one match does not establish uniqueness.

A resolved identity is not a persistent project identifier. The same descriptor in a later observation requires a new binding.

## Swift provenance boundary

The existing boundary is in [RegionIdentityRegistry.swift](../../Sources/LogicProMCP/MIDIReadback/RegionIdentityRegistry.swift): `RegistryResolvedIdentityProof` has a `fileprivate` initializer and a debug-only mint.

The production design must preserve that boundary:

- Keep proof construction `fileprivate`.
- Put the production observer or validating factory in the same Swift source file as the proof constructor.
- Make that production path validate observation evidence before minting a proof. It must not accept a caller’s descriptor and assertion of uniqueness as sufficient evidence.
- Keep proof contents opaque to callers. Do not introduce a caller-accessible initializer, writable binding fields, unchecked decoding path or descriptor-to-proof convenience conversion.
- Keep the debug mint behind `QUALIFICATION_FAULT_SEAM`, which [Package.swift](../../Package.swift) scopes to debug.
- Make release `.proven` require `RegistryResolvedIdentityProof`. A descriptor-only `.proven` path must not exist.

[EventListReadbackEvidence.swift](../../Sources/LogicProMCP/MIDIReadback/EventListReadbackEvidence.swift) currently contains `ResolvedRegionIdentity` and `ObservedRegionIdentityProof`, with `.proven` behind `QUALIFICATION_FAULT_SEAM`. The change makes a proof-bearing production path available in release; it must not expose the existing qualification shortcut as production authority.

`fileprivate` permits construction elsewhere in the same source file. That file is therefore the trusted minting boundary, and every constructor call in it must be accounted for. An opaque token alone is not enough: the registry must validate its recorded binding and scope at consumption.

This is a Swift API provenance guarantee for ordinary callers. It is not a claim of protection against arbitrary memory corruption or modification of the running process.

## Observation and Event List binding

[AccessibilityChannel+Regions.swift](../../Sources/LogicProMCP/Channels/AccessibilityChannel+Regions.swift) supplies `enumerateRegionItems` and `selectedRegionInfos`, returning `RegionInfo{name,trackIndex,startBar,endBar,kind,rawHelp}`.

Those summary fields do not by themselves establish enumeration completeness, non-positional track association or correspondence with the selected source object. The production observer must retain or obtain the evidence needed for those checks. The available facts do not establish that the existing summaries provide it.

An observation scope must:

- Belong to one binding and readback operation.
- Retain the independently observed source association needed for revalidation.
- Become unusable after completion or invalidation.
- Reject proof reuse in another observation, including when descriptor values are unchanged.

Before accepting Event List evidence, revalidate the region binding, candidate uniqueness and observable Event List context. Revalidate again after collecting the rows. Observed changes, failed revalidation or unavailable context require refusal.

Elapsed time alone cannot establish freshness. These checks establish that the required observations agreed; they do not establish an atomic Logic Pro snapshot or exclude every unobserved change between reads.

Event List ownership is a separate requirement from region identity. The collector must establish that the returned rows belong to the bound region using observed context or a directly observed relationship. Row order, matching note counts, the fact that the Event List is open, and the fact that one region appears selected are not substitutes for that relationship.

A region proof alone must not approve Event List evidence. Preserve Position as the observed string. This work does not turn it into an exact tick measurement.

## Refusal contract

Refusal means that the affected identity or readback claim is not reported as proven or independently verified. Preserve the observed evidence and a reason that distinguishes the failed condition. The labels below describe required semantics, not existing reason-code names.

| Condition | Required behaviour |
|---|---|
| Zero matching candidates | Refuse the identity binding. |
| Multiple matching candidates | Refuse; do not choose the first, nearest, selected-looking or otherwise preferred candidate. |
| Duplicate candidates collapsed before counting | Prohibited. Count matching source candidates, not distinct descriptor values. |
| Incomplete enumeration or unknown completeness | Refuse, even if the returned subset has one match. Traversal failures or truncation must not become success-shaped empty or partial results. |
| Track association derived from position or order | Refuse, including index-based pairing of separate region and track arrays. |
| Missing required descriptor fields or unavailable source correspondence | Refuse; do not supply defaults or infer identity from the tuple alone. |
| Contradictory observed selection, region or track evidence | Refuse; do not choose whichever source permits success. |
| Stale, invalidated, consumed or different observation scope | Refuse and require a fresh observation. Identical descriptor values do not renew a proof. |
| Unbindable Event List rows | Refuse the readback claim, even if region identity was established separately. |
| Exact tick claim requested or required | Refuse that claim. Neither bar bounds nor the Position display string establish it here. |
| Descriptor-only, mismatched or invalid proof | Reject construction where possible; otherwise refuse at consumption. |
| Command acknowledgement without confirming observation | Do not promote the command result into region identity, creation success or readback verification. |

An empty note list is not the same condition as zero region candidates. Any assertion that a bound region contains no notes still requires valid Event List ownership and a complete relevant read.

## Downstream consumers and the five blocked ADRs

[MIDIReadbackAssessment.swift](../../Sources/LogicProMCP/MIDIReadback/MIDIReadbackAssessment.swift) and [MIDINoteIndependentVerification.swift](../../Sources/LogicProMCP/MIDIReadback/MIDINoteIndependentVerification.swift) may consume a valid region proof as evidence of observation-scoped region identity. They must continue to assess row ownership, evidence completeness and independence separately.

The five blocked ADRs were not identified, and their individual requirements were not supplied. This PRD therefore defines a common hand-off without inventing ADR numbers, titles or component assignments.

The hand-off consists of:

- The measured descriptor and its limits.
- A release-capable opaque proof, conditional on the binding checks.
- Explicit refusal semantics.
- Evidence of which binding checks and live scenarios were exercised.

| Blocked dependency | What it gets from this change | What it still does not get |
|---|---|---|
| ADR A — identifier not supplied | The common hand-off above | Exact timing, automatic Event List ownership, independent note verification, or an established unblock decision |
| ADR B — identifier not supplied | The common hand-off above | Exact timing, automatic Event List ownership, independent note verification, or an established unblock decision |
| ADR C — identifier not supplied | The common hand-off above | Exact timing, automatic Event List ownership, independent note verification, or an established unblock decision |
| ADR D — identifier not supplied | The common hand-off above | Exact timing, automatic Event List ownership, independent note verification, or an established unblock decision |
| ADR E — identifier not supplied | The common hand-off above | Exact timing, automatic Event List ownership, independent note verification, or an established unblock decision |

A–E are document placeholders, not inferred ADR identities. Individual delivery and unblock claims require the actual ADR references and acceptance criteria. None of the five is declared unblocked by this PRD.

## Migration

There are six existing `ResolvedRegionIdentity` construction sites across these four test files. Their distribution between files was not supplied.

| Test file | Required migration |
|---|---|
| `EventListReadbackCollectorTests` | Construct resolved identities through the debug proof fixture; supply explicit observation scope and separate row-binding evidence. |
| `MIDIReadbackAssessmentTests` | Separate descriptor-only evidence from proof-bearing identity evidence. Ensure the former cannot satisfy the latter’s requirement. |
| `Issue293DesktopVariantTests` | Supply explicit candidate and track-association evidence for qualifying variants. Refuse variants without sufficient evidence. |
| `Issue293EventListProviderTests` | Exercise proof-bearing identity and independently bound Event List context; preserve raw Position strings. |

Migrate all six sites. Remove any `startTick` or ordinal arguments used to construct identity; do not replace them with default values.

A debug helper may mint fixture proofs through the existing fault seam. It must make the intended scope and binding explicit. Tests of production observation must exercise the validating production path rather than using a debug proof as evidence that the observer works.

No compatibility initializer may keep descriptor-only construction working in release.

## Acceptance criteria

The change is accepted only when the corresponding evidence is recorded:

1. **Release provenance:** release code can obtain `.proven` through a successful production observation. A consumer cannot create it from a descriptor or directly initialise the opaque proof.
2. **Descriptor distinction:** one matching candidate with complete, non-positional evidence can resolve; the same descriptor without that evidence cannot.
3. **Cardinality:** zero and two matching source candidates refuse. Two candidates with identical descriptors remain two candidates.
4. **Enumeration:** a partial candidate set refuses even when its visible descriptors are unique.
5. **Order independence:** permuting region and track enumeration order independently does not alter valid bindings. Inputs that provide only positional associations refuse.
6. **Lifetime:** a proof from another, invalidated or completed observation refuses, including when all four descriptor fields match.
7. **Event List ownership:** reachable rows with eight columns and a Position string remain insufficient without an observed link to the bound region.
8. **Claim limits:** identity proof alone cannot produce independent note verification or an exact tick claim.
9. **Migration:** all six construction sites use the revised contract; debug qualification facilities remain unavailable in release.
10. **Live qualification:** qualifying success requires recorded evidence for the production binding checks. A same-track case counts as exercised only after more than one region is observed on that track. A collision case counts as exercised only after two matching descriptors are observed there.

Deterministic tests must cover collisions even if the live fixture cannot produce one. An unsuccessful fixture construction is inconclusive for live collision handling and cannot be recorded as a pass.

## Risks and exposing measurements

| Risk | Measurement that exposes it |
|---|---|
| The fixture’s one-region-per-track layout conceals a defective discriminator | Observe at least two regions on one track, first with different bounds, then with the same name and identical bar bounds. Record actual counts before testing binding. |
| Real same-track descriptors collide | Enumerate the successfully constructed collision fixture and require refusal for the shared descriptor. |
| `trackIndex` was obtained through order | Inspect the observer’s association evidence and independently permute region and track sequences in deterministic tests. Live track reordering provides an additional check. |
| Enumeration silently omits candidates | Inject a traversal failure or truncation after one visible match; resolution must refuse. |
| Selection or region state changes during readback | Change selection or a relevant region attribute between binding and consumption; revalidation must refuse. |
| Equal descriptors conceal a different observation | Recreate or reobserve the same descriptor in a new scope and attempt to reuse the old proof; consumption must refuse. This does not establish detection of every unobserved replacement within one scope. |
| Event List rows belong to another region | Present valid-looking rows with missing or mismatched region context; the readback claim must refuse. |
| A debug mint or convenience initializer leaks authority into release | Build the release configuration and exercise compile-time boundary checks from consumer code. Descriptor-only and fault-seam construction must be unavailable. |
| Display text becomes an unsupported timing claim | Feed a valid Position string and bar bounds through assessment; an exact tick claim must remain refused. |
| Existing AX evidence cannot support production binding | Attempt a live observation with complete enumeration and direct source/track correspondence. If those facts cannot be observed, record the missing evidence and refuse. |

## Not claimed

- Global or persistent uniqueness of the four-tuple.
- A measured same-track collision or evidence that one is impossible.
- Successful duplication from the reported command response.
- Non-positional track association or complete enumeration merely because `RegionInfo` contains four populated fields.
- An already functioning release production observer.
- Event List ownership from reachability, selection alone or column shape.
- Exact ticks, exact region duration or exact MIDI timing.
- Independent note verification from region identity alone.
- Atomic observation of Logic Pro or detection of every intervening edit.
- Individual satisfaction or unblocking of any of the five unidentified ADRs.
- Implementation, test or release qualification results from this specification.
