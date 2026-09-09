# #766 second half — read the track type from the channel strip Logic built

Size: **M**, because the reading is already measured and the code sites are three, but the
locale coverage is one measured language out of the two this project supports live, and the
ticket has to decide what happens on the other one rather than leaving it to the implementer.

## 1. The measurement this rests on, and its limits

Logic Pro 12.3 build 6674, **en** interface, macOS 26.6, 2026-09-09, on the working fixture
project (20 tracks). Read with `Scripts/livekit/ax_inspector_strip_type_census.swift` and a
full-child-dump variant of it. Every row below is the LEFT INSPECTOR channel strip of the
selected track, direct children only.

| track | created by | distinguishing children | slot verdict |
|---|---|---|---|
| `Audio 1` | `create_audio` | `Input slot`, Record Enable, Input Monitoring, Channel Mode | audio |
| `Studio Grand` | `create_instrument` | `MIDI Effect slot`, instrument group `Piano` | instrument family |
| `SoCal` | `create_drummer` | `MIDI Effect slot`, instrument group `Drum Kit` | instrument family |
| `Off 1` | `create_external_midi` | **no** Output/Send/Audio Effect/EQ; `Assign control` rows | external MIDI |
| `Absolute Zero` | Drum Machine Designer patch | neither `Input slot` nor `MIDI Effect slot` | undetermined |

**The reading that changes the plan.** The roadmap row for #766 says an input slot marks an audio
strip and a MIDI effect slot marks an instrument one. The second half is false *as a track-type
reading*: a **drummer** track shows the same `MIDI Effect slot` as a software instrument. Narrowing
that case to `.softwareInstrument` would answer confidently and wrongly on every drummer track,
which is the failure the first half of #766 removed.

The instrument slot's group description does differ (`Drum Kit` vs `Piano`), and it is **not** a
type signal: it is the plug-in loaded, and a user may load Drum Kit Designer on an ordinary
instrument track.

**What would change if the reading were about something else.** The census identifies the strip by
its help prefix `Left inspector channel strip` and by waiting until the strip's own `AXDescription`
equals the header's name. If that element is not the selected track's strip, every row above is
about the wrong strip. Two tracks with the same name defeat the check and this is not detectable
here — the fixture had nine tracks named `Deluxe Classic`, and their rows agreed with each other,
which is consistent with both the check working and the check being vacuous for them.

**Not measured: ko-KR.** All four strings below were read on an **en** Logic only.

## 2. Exact changes

### 2a. `Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift`

`inputSlotHelpKeyword` (line 1402) already exists and already carries a measured ko variant.
Add three sets beside it, each carrying the **full phrase** rather than a word — the reason
`inputSlotHelpKeyword` is a phrase is that `Input Monitoring` shares its first word with
`Input slot`, and the same neighbour hazard is present here (`Audio Effect slot` vs
`MIDI Effect slot` share two of three words).

    static let midiEffectSlotHelpKeyword = LabelSet(
        canonical: "midi effect slot",
        variants: [],
        rationale: "Detects a channel strip's MIDI effect slot by its AXHelp string; read-only classifier."
    )

    static let inspectorChannelStripHelpPrefix = LabelSet(
        canonical: "left inspector channel strip",
        variants: [],
        rationale: "Identifies the inspector's channel strip for the selected track; read-only locator."
    )

    static let assignControlHelpKeyword = LabelSet(
        canonical: "assign control",
        variants: [],
        rationale: "Marks an external-MIDI strip's controller-assignment rows; read-only classifier."
    )

Each must also be added to the registry list that begins at line 1774, in the same order.

**Empty `variants` is the decision, not an omission.** On a locale whose phrase is not listed the
set does not match, the strip reads as undetermined, and the answer is `.unknown` — which is what
the operation answers today. A guessed ko string could match the wrong control and produce a
confident wrong type, which is strictly worse than the present behaviour. `inputSlotSource`
already documents exactly this refusal.

### 2b. `Sources/LogicProMCP/Accessibility/AXLogicProElements+Mixer.swift`

Add, beside `inputSlotSource` (line 393):

    /// The kinds of slot a channel strip exposes, as the leading sentence of each child's AXHelp.
    static func slotKinds(in strip: AXUIElement, runtime: AXHelpers.Runtime = .production) -> [String]?

Returns `nil` when the strip's child list cannot be read, and `nil` again when any child's LABEL could not
be read — a readable child list does not prove every label was read, and a present output slot whose
help failed would otherwise look like "no output slot". The census carries this same distinction in
`childrenReadable` and gained it from a review on 2026-09-08.

### 2c. `Sources/LogicProMCP/Channels/AccessibilityChannel+Tracks.swift`

At line 2059 the create path publishes:

    merged["observed_track_type"] = observedTrack.type.rawValue
    merged["track_type_verification_source"] = "observed_header"

After: when the strip read yields a type, it wins and names itself; otherwise the header answer
stands unchanged.

    if let stripType = inspectorStripTrackType(expectedName: observedTrack.name) {
        merged["observed_track_type"] = stripType.rawValue
        merged["track_type_verification_source"] = "inspector_channel_strip"
    } else {
        merged["observed_track_type"] = observedTrack.type.rawValue
        merged["track_type_verification_source"] = "observed_header"
    }

Classification, in this order:

    Input slot present                                     -> .audio
    MIDI Effect slot present                               -> nil   (instrument FAMILY; see below)
    no Output slot and no Audio Effect slot and
      an Assign control row present                        -> .externalMIDI
    anything else, or the child list unreadable            -> nil

**`.softwareInstrument` is deliberately not produced.** The strip cannot separate it from
`.drummer`, so the family answer is no answer, and the header's `.unknown` stands.

## 3. Call sites this reaches

Three, all enumerated:

1. `AccessibilityChannel+Tracks.swift:2059` — the `create_*` state-A path. **Mechanical**, the
   diff above.
2. `AccessibilityChannel+Library.swift:827` — also publishes `observed_track_type`. **Cannot be
   resolved mechanically**, and the ticket decides: leave it alone. It is reached from a library
   patch application whose selected track is not established by this measurement.
3. `AXValueExtractors.inferTrackType` — **unchanged**. The list read (`get_tracks`) enumerates every
   header and must not move the selection, so it keeps the header aggregate and its `.unknown`.

## 4. Acceptance criteria that can fail

- `create_audio` returns `observed_track_type:"audio"` with
  `track_type_verification_source:"inspector_channel_strip"`.
- `create_external_midi` returns `observed_track_type:"external_midi"` with the same source field.
- `create_drummer` and `create_instrument` return `observed_track_type:"unknown"` with
  `track_type_verification_source:"observed_header"`. **Asserting they do not claim a narrow type
  is part of the contract**, not a gap in the tests.
- A strip whose child list is unreadable produces `observed_header`, never `external_midi`.

## 5. Mutations that must turn a test RED

| edit to production code | test that must go red |
|---|---|
| `slotKinds` returns `[]` instead of `nil` on an unreadable child list | the unreadable-strip test, which otherwise sees `.externalMIDI` |
| drop the `no Audio Effect slot` clause from the external-MIDI rule | the instrument-strip fixture, which has `Assign control` absent but would need the clause to stay non-external |
| return `.softwareInstrument` for the MIDI-effect case | the drummer fixture |
| match `midiEffectSlotHelpKeyword` on `effect slot` instead of the full phrase | the audio fixture, whose `Audio Effect slot` would then match |
| drop the strip-name-agrees-with-expected wait | the wrong-strip fixture |

## 6. Not in scope

- Reading the type for tracks that are not selected, and anything that moves the selection.
- The Mixer. The read is from the inspector, which is already showing the selected track.
- `AccessibilityChannel+Library.swift:827`.
- Separating `.drummer` from `.softwareInstrument`. The measurement says the strip cannot, and
  a route through the Drummer editor or the region kind is a different ticket.
- Moving the oracle's per-op pin back from `requested_track_type` to `observed_track_type`.

## 7. What this ticket does NOT establish

- That the strip read works on any locale other than **en**. It is measured on en only, and on
  every other locale the sets do not match and the answer is the present `.unknown`.
- That `Absolute Zero`'s strip is undetermined *because* it is a Drum Machine Designer stack.
  That is the plausible reading of a strip with neither slot; it was not confirmed against the
  track's own kind.
- That the strip belongs to the track that was just created. It is identified by following the
  selection and by name agreement, and two tracks with one name defeat that.
- That drummer and software instrument are indistinguishable **anywhere** — only that the
  inspector channel strip does not distinguish them.

---

## What changed during implementation, and why

The ticket above is left as it was written. Three things came out differently, and the reasons are
recorded here rather than folded back into the specification, because a ticket edited to match its
implementation stops being able to disagree with it.

**1. The classifier returns three values, not an optional `TrackType`.**
The ticket said the MIDI-effect case returns `nil`. Implemented that way it returned exactly what
falling through returns, so the branch was behaviourally dead: mutating it changed nothing, and a
rule nothing can distinguish is not a rule. It answers `instrumentFamily` instead, and the create
path publishes `track_type_verification_source: "inspector_channel_strip_instrument_family"` — which
is also better information than the ticket asked for: "the strip was read and its answer is a family
this read cannot narrow" is not the same fact as "no strip answered".

**2. The phrase-precision mutation is asserted on the LABEL, not through the classifier.**
The ticket's mutation table said widening `midi effect slot` to the tail it shares with
`audio effect slot` must turn the audio-strip test red. Measured: it does not, and cannot. The
classifier answers from the input slot before it ever reaches the MIDI-effect branch, so the widened
phrase is invisible from there and a test written that way would be a check that cannot fail. The
assertion moved to `AXLocalePolicy.midiEffectSlotHelpKeyword` itself, where the mutation does go red.

**3. The `no Audio Effect slot` clause was dropped from the external-MIDI rule.**
Every strip that has a MIDI effect slot also has an audio effect one, so the clause could not change
any answer and could not be made to fail. The rule is `Assign control present AND no output slot`,
and the conjunction is witnessed by a fixture carrying both an assign control and an output slot.


---

## Corrections after review, 2026-09-09

Three claims above are wrong and are corrected here rather than edited away, because a ticket
rewritten to agree with its implementation stops being able to disagree with it.

**"Three call sites, all enumerated" is wrong — there are four.** The fourth is
`SemanticOracleTable.createTrackSemantics`, which pinned `track_type_verification_source` to the
literal `observed_header`. Live qualification would have rejected this feature's own successful
outputs. The enumeration was made by searching for callers of the functions being changed, which
cannot find a consumer that pins a VALUE those functions emit.

**The `nil` versus `[]` rationale overstated its consequence.** An empty slot list would not have
become external MIDI: that clause needs an assign-control row, which an empty list also lacks. The
distinction is still worth keeping — an unreadable list is not an empty strip — but the danger named
was the wrong one. The real one is an unreadable child LABEL, which is now refused.

**"The project supports two live locales" is wrong — the generated contract lists three**: en-US,
ko-KR and ja-JP. Worse for the ticket's central claim: the ko-KR and ja-JP inspector-strip strings
were ALREADY in this repository, in the 2026-09-05 censuses, so "measured on en only" was false for
the locator. They are measured now, with provenance. It remains true for the two slot labels.

**And the promised wrong-strip fixture was missing.** The ticket said a mutation dropping the
strip-name wait must turn a test red, and no locator test existed at all. There are three now: the
rebuild race, a duplicate name, and the right inspector strip — the last from the ko-KR census,
where the RIGHT strip's help contains the LEFT strip's phrase in a later sentence.
