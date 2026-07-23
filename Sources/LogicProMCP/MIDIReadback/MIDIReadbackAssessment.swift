import Foundation

// The single pure chokepoint that decides whether an Event-List readback is
// complete enough to drive a State-A verification. It re-computes EVERY gate
// from the raw evidence or sealed proofs; it never trusts a caller conclusion.
//
// Mint discipline: a `complete` verdict wraps `CompleteProof`, whose
// initializer is fileprivate to THIS file, and `assessReadback` is its ONLY mint
// site. No other production file can construct completeness; Codable can never
// rehydrate it (see `CompletenessVerdict`'s decoder in MIDINoteReadback.swift).
// Because the live-only proofs (timing, header identity, harvest exhaustion,
// observed region, count semantics) have no production-constructible "proven"
// case, a release build cannot satisfy the predicate at all, so it emits no
// complete snapshot, so no false State-A can ship.

/// Closed set of reasons a readback is not complete — one per predicate, so each
/// fail-closed branch is individually testable.
enum PartialReason: Equatable, Sendable {
    case unboundIdentity
    case wrongRegion
    case invalidPPQ
    case filterEvidenceIncomplete
    case filterNotAllNotes
    case countIndependenceUnproven
    case countMismatch
    case harvestNotContiguous
    case harvestContentUnstable
    case harvestNotExhaustive
    case columnUnresolved
    case calibrationNotDistinct
    case rowParseFailed(RowKey)
    case timingUnproven
    case epochChanged
    case emptyNotProven
    case mapsUnpopulated
    case decodedNotReassessed
}

/// Sealed completeness token. `.complete`'s payload can only be minted by
/// `assessReadback` (fileprivate initializer, this file).
enum CompletenessVerdict: Equatable, Sendable {
    case complete(CompleteProof)
    case incomplete(PartialReason)

    // No case-only `isComplete`: completeness is meaningful only against the
    // payload it certifies, so it is checked exclusively by
    // `MIDIRegionNoteSnapshot.complete` (which recomputes the sealed binding). A
    // verdict-only boolean would bypass that binding and is deliberately absent.
    var partialReason: PartialReason? {
        if case let .incomplete(reason) = self { return reason }
        return nil
    }
}

struct CompleteProof: Equatable, Sendable {
    /// Binds this completeness proof to the exact notes+PPQ it certifies, so it
    /// cannot be re-paired with a foreign note payload.
    let contentBinding: String
    fileprivate init(contentBinding: String) { self.contentBinding = contentBinding }

    #if QUALIFICATION_FAULT_SEAM
    /// Test-only mint. Compiled solely under `QUALIFICATION_FAULT_SEAM`; a
    /// release binary has no path to this. A test seam, not a security boundary.
    static func makeForTesting(contentBinding: String) -> CompleteProof {
        CompleteProof(contentBinding: contentBinding)
    }
    #endif
}

// MARK: - Assessment

/// Pure assessment: interpret the evidence and produce a snapshot whose note
/// completeness is `.complete` only if every completeness predicate holds. On any failure
/// the snapshot is incomplete with an empty note list (never notes with
/// unproven ticks — a zero-duration note would canonicalize away and could
/// masquerade as a verified-empty match).
func assessReadback(_ evidence: EventListReadbackEvidence) -> MIDIRegionNoteSnapshot {
    let outcome = evaluate(evidence)
    // Identity the proof certifies. Computed once and used for BOTH the binding
    // and the snapshot's stored fields, so `complete`'s recomputation always
    // matches a genuine mint but never a proof transplanted onto a foreign
    // envelope.
    let region = evidence.requestedRegion
    let epoch = evidence.projectEpochAfter
    let provenance: MIDIReadbackProvenance = .eventListAX
    let pipelineID = MIDIRegionNoteSnapshot.eventListConversionID
    let verdict: CompletenessVerdict
    let notes: [MIDINoteEvent]
    switch outcome {
    case let .complete(parsedNotes):
        verdict = .complete(CompleteProof(
            contentBinding: midiSnapshotCompletenessBinding(
                regionReference: region,
                projectEpoch: epoch,
                provenance: provenance,
                conversionPipelineID: pipelineID,
                notes: parsedNotes,
                ppq: evidence.ppq
            )
        ))
        notes = parsedNotes
    case let .incomplete(reason):
        verdict = .incomplete(reason)
        notes = []
    }
    return MIDIRegionNoteSnapshot(
        regionReference: region,
        projectEpoch: epoch,
        noteCompleteness: verdict,
        provenance: provenance,
        ppq: evidence.ppq,
        notes: notes,
        tempoMap: [],
        timeSignatures: [],
        conversionPipelineID: pipelineID
    )
}

private enum AssessmentOutcome {
    case complete([MIDINoteEvent])
    case incomplete(PartialReason)
}

private func evaluate(_ e: EventListReadbackEvidence) -> AssessmentOutcome {
    // --- Common predicates (both notes-bearing and verified-empty) ---

    // Region identity: the proof must bind the SAME query, then its resolved
    // identity must field-match the independently observed identity.
    guard e.resolvedIdentity.boundRegion == e.requestedRegion else {
        return .incomplete(.unboundIdentity)
    }
    guard let observed = e.observedRegion.identity,
          observed == e.resolvedIdentity.identity else {
        return .incomplete(.wrongRegion)
    }

    guard e.ppq > 0 else {
        return .incomplete(.invalidPPQ)
    }

    switch filterCompleteness(e.filter) {
    case .incomplete:
        return .incomplete(.filterEvidenceIncomplete)
    case .filtered:
        return .incomplete(.filterNotAllNotes)
    case .allNotesVisible:
        break
    }
    guard e.itemCount.semanticsProof.isAllEventsInRegion else {
        return .incomplete(.countIndependenceUnproven)
    }
    guard e.projectEpochBefore == e.projectEpochAfter else {
        return .incomplete(.epochChanged)
    }
    guard harvestKeysContiguous(e.harvest) else {
        return .incomplete(.harvestNotContiguous)
    }
    if firstUnstableKey(e.harvest) != nil {
        return .incomplete(.harvestContentUnstable)
    }
    guard e.harvest.exhaustion.isProven else {
        return .incomplete(.harvestNotExhaustive)
    }

    // --- Branch: notes-bearing vs verified-empty ---
    if e.harvest.passA.isEmpty {
        // Verified-empty branch: full column identity (so the columns are proven
        // identifiable, not a degenerate empty proof) + parsed count == 0.
        guard let roles = e.columnBinding.headerRoles,
              fieldColumnsPresentAndDistinct(roles) else {
            return .incomplete(.emptyNotProven)
        }
        guard let count = parseCount(e.itemCount.rawCountText), count == 0 else {
            return .incomplete(.emptyNotProven)
        }
        return .complete([])
    }

    // Notes-bearing branch.
    guard let roles = e.columnBinding.headerRoles, let calibration = e.calibration else {
        return .incomplete(.columnUnresolved)
    }
    // The calibration triple must be mutually distinct so each value can pin a
    // different column; equal values would let one column satisfy two roles.
    guard calibration.pitch != calibration.velocity,
          calibration.pitch != calibration.startTickValue,
          calibration.velocity != calibration.startTickValue else {
        return .incomplete(.calibrationNotDistinct)
    }
    guard columnsUniquelyResolve(roles: roles, calibration: calibration, harvest: e.harvest) else {
        return .incomplete(.columnUnresolved)
    }
    guard e.timing.isProven else {
        return .incomplete(.timingUnproven)
    }

    // Parse every row; any failure fails the whole scan.
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
}

// MARK: - Pure helpers

private enum FilterAssessment {
    /// The control set is not a complete, unambiguous observation.
    case incomplete
    /// A scoping filter is active (or note events are hidden).
    case filtered
    /// All note events visible, no scoping filter active.
    case allNotesVisible
}

/// Assess filter state against the KNOWN complete control set. Fail-closed on an
/// incomplete observation: every `FilterControlID` must appear exactly once and
/// no unrecognized control ids are allowed, so an omitted (thus unseen) scope
/// control cannot be silently treated as "off". Derived purely from the raw
/// checkbox states — never a caller-supplied boolean.
private func filterCompleteness(_ filter: FilterEvidence) -> FilterAssessment {
    var seen: [FilterControlID: Bool] = [:]
    for box in filter.checkboxes {
        guard let control = FilterControlID(rawValue: box.id) else { return .incomplete }
        if seen[control] != nil { return .incomplete }
        seen[control] = box.checked
    }
    for control in FilterControlID.allCases where seen[control] == nil {
        return .incomplete
    }
    guard seen[.noteEvents] == true else { return .filtered }
    if seen[.channel] == true || seen[.scope] == true || seen[.takeFolder] == true {
        return .filtered
    }
    return .allNotesVisible
}

private func harvestKeysContiguous(_ harvest: RowHarvest) -> Bool {
    let keys = harvest.orderedRowKeys
    let keySet = Set(keys)
    guard keySet.count == keys.count else { return false }
    guard keySet == Set(harvest.passA.keys), keySet == Set(harvest.passB.keys) else { return false }
    guard keys == keys.sorted() else { return false }
    // The span must be anchored at the table's first row (index 0), so a
    // contiguous MID-window cannot pass as the full table.
    if let first = keys.first, first.index != 0 { return false }
    for i in 1..<max(keys.count, 1) where keys.count > 1 {
        if keys[i].index != keys[i - 1].index + 1 { return false }
    }
    return true
}

/// Returns the first key whose two harvested passes disagree (canonical digest =
/// structural equality), or nil if every row is stable.
private func firstUnstableKey(_ harvest: RowHarvest) -> RowKey? {
    for key in harvest.orderedRowKeys {
        if harvest.passA[key] != harvest.passB[key] { return key }
    }
    return nil
}

/// All five note-field columns must be present and bound to distinct columns.
private func fieldColumnsPresentAndDistinct(_ roles: [ColumnRole: AXColumnID]) -> Bool {
    guard let pitchCol = roles[.pitch],
          let velCol = roles[.velocity],
          let posCol = roles[.position],
          let chCol = roles[.channel],
          let lenCol = roles[.length] else { return false }
    return Set([pitchCol, velCol, posCol, chCol, lenCol]).count == 5
}

private func columnsUniquelyResolve(
    roles: [ColumnRole: AXColumnID],
    calibration: CalibrationTriple,
    harvest: RowHarvest
) -> Bool {
    // Every note field must be bound to a DISTINCT column (no role may alias
    // another — e.g. length aliased to position would yield systematically wrong
    // durations while still "resolving").
    guard fieldColumnsPresentAndDistinct(roles),
          let pitchCol = roles[.pitch],
          let velCol = roles[.velocity],
          let posCol = roles[.position] else { return false }
    // Each calibration value must resolve to exactly one column across the rows.
    func uniqueColumn(matching: (RawCell) -> Bool) -> AXColumnID? {
        var found: Set<AXColumnID> = []
        for row in harvest.passA.values {
            for (col, cell) in row where matching(cell) {
                found.insert(col)
            }
        }
        return found.count == 1 ? found.first : nil
    }
    let pitchResolved = uniqueColumn { $0.sliderValue == calibration.pitch }
    let velResolved = uniqueColumn { $0.valueDescription.flatMap(Double.init) == calibration.velocity }
    let startResolved = uniqueColumn { ($0.groupSliderValues?.first).map { $0 == calibration.startTickValue } ?? false }
    return pitchResolved == pitchCol && velResolved == velCol && startResolved == posCol
}

/// Parse a single row into a note. Pitch is the raw slider integer (locale
/// independent); velocity is parsed from the value description string; position
/// and length are bar:beat:div:tick slider groups converted to region-relative
/// ticks. Any out-of-range / non-numeric field fails (returns nil).
private func parseNote(
    row: RawEventRow,
    roles: [ColumnRole: AXColumnID],
    regionStartTick: Int64
) -> MIDINoteEvent? {
    // Cell-shape XOR: a cell carries EXACTLY the numeric shape its role family
    // uses — scalar roles (pitch/velocity/channel) a `sliderValue` and NO group;
    // group roles (position/length) a `groupSliderValues` and NO scalar. A cell
    // exposing both shapes is structurally ambiguous; rejecting it stops a
    // dual-populated cell from satisfying a swapped role with the wrong value
    // (channel and length are not calibration-pinned, so without this a
    // dual-populated channel↔length swap would parse silently to wrong data).
    // `valueDescription` is orthogonal (velocity reads it) and not constrained.

    // Pitch is the raw slider value: it must be a finite, exact integer in range
    // (a fractional, non-finite, or overflowing value fails rather than rounding
    // or trapping in the Double→Int conversion).
    guard let pitchCol = roles[.pitch], let pitchCell = row[pitchCol],
          pitchCell.groupSliderValues == nil,
          let pitchRaw = pitchCell.sliderValue,
          let pitchInt = exactIntInRange(pitchRaw, 0...127) else { return nil }

    // Velocity comes from the value-description string (strict integer parse).
    guard let velCol = roles[.velocity], let velCell = row[velCol],
          velCell.groupSliderValues == nil,
          let velString = velCell.valueDescription,
          let velInt = Int(velString), (1...127).contains(velInt) else { return nil }

    // Channel is required, never invented: a missing channel column or value
    // fails the row (fail-closed) rather than defaulting to a guessed channel.
    guard let chCol = roles[.channel], let chCell = row[chCol],
          chCell.groupSliderValues == nil, let chRaw = chCell.sliderValue,
          let channelInt = exactIntInRange(chRaw, 1...16) else { return nil }

    guard let posCol = roles[.position], let posCell = row[posCol],
          posCell.sliderValue == nil,
          let start = bbtToTicks(posCell.groupSliderValues) else { return nil }
    guard let lenCol = roles[.length], let lenCell = row[lenCol],
          lenCell.sliderValue == nil,
          let duration = bbtToTicks(lenCell.groupSliderValues) else { return nil }

    // Region-relative start; overflow-safe subtraction.
    let (relativeStart, overflow) = start.subtractingReportingOverflow(regionStartTick)
    guard !overflow, relativeStart >= 0, duration > 0 else { return nil }

    return MIDINoteEvent(
        pitch: UInt8(pitchInt),
        startTicks: relativeStart,
        durationTicks: duration,
        velocity: UInt8(velInt),
        channel: UInt8(channelInt)
    )
}

/// A finite, exact (non-fractional) integer within `range`. Rejects NaN/inf and
/// values outside the range's Double bounds before any Int conversion, so the
/// Double→Int conversion can never trap.
private func exactIntInRange(_ raw: Double, _ range: ClosedRange<Int>) -> Int? {
    guard raw.isFinite, raw == raw.rounded() else { return nil }
    guard raw >= Double(range.lowerBound), raw <= Double(range.upperBound) else { return nil }
    let value = Int(raw)
    return range.contains(value) ? value : nil
}

/// Placeholder BBT→tick conversion for this pure core. Only reachable when
/// `TimingEvidence` is proven, which cannot happen in a release build (the
/// validated conversion body lands later). Treats the four slider values as raw
/// tick contributions; each must be a finite exact integer and the total must
/// fit Int64 (no trap/overflow) — the real display-format-aware conversion is
/// deferred until then.
private func bbtToTicks(_ group: [Double]?) -> Int64? {
    guard let group, group.count == 4 else { return nil }
    // 2^53 is the largest integer every Double represents exactly; beyond it a
    // Double "integer" has lost precision, so reject per value (and bound the
    // total well within Int64 so the conversion cannot trap).
    let exactIntegerLimit = 9_007_199_254_740_992.0  // 2^53
    // Accumulate in Int64, not Double: each value is a finite exact integer within
    // ±2^53 (so Int64(value) is exact), and the running sum uses overflow-checked
    // Int64 addition — a Double sum would silently lose the low bits above 2^53
    // (e.g. 2^53 + 1 == 2^53 in Double).
    var total: Int64 = 0
    for value in group {
        guard value.isFinite, value == value.rounded(), abs(value) <= exactIntegerLimit else {
            return nil
        }
        let (next, overflow) = total.addingReportingOverflow(Int64(value))
        guard !overflow else { return nil }
        total = next
    }
    return total
}

private func parseCount(_ text: String) -> Int? {
    // The count token must be pure ASCII digits, cleanly delimited (end of string
    // or whitespace). Grouping separators and any other non-digit content are
    // rejected (fail-closed) so a malformed token like "1,,0", "10,", "1,00", or
    // "12abc" can never be coerced into a value that spuriously matches a count.
    guard let first = text.first, first.isNumber else { return nil }
    let leading = text.prefix { $0.isNumber }
    let rest = text[leading.endIndex...]
    guard rest.isEmpty || (rest.first?.isWhitespace ?? false) else { return nil }
    // Reject any further digits after the leading run: a space/NBSP-grouped value
    // like "1 234" must not be truncated to its leading group.
    guard !rest.contains(where: { $0.isNumber }) else { return nil }
    return Int(leading)
}

private extension ColumnBinding {
    var headerRoles: [ColumnRole: AXColumnID]? {
        if case let .headerIdentity(proof) = self { return proof.roles }
        return nil
    }
}
