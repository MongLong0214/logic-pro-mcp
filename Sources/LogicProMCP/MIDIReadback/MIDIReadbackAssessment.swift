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
    case columnUnresolved
    case filterNotAllNotes
    case countIndependenceUnproven
    case countMismatch
    case harvestNotContiguous
    case harvestContentUnstable
    case harvestNotExhaustive
    case rowParseFailed(RowKey)
    case timingUnproven
    case epochChanged
    case emptyNotProven
    case decodedNotReassessed
}

/// Sealed completeness token. `.complete`'s payload can only be minted by
/// `assessReadback` (fileprivate initializer, this file).
enum CompletenessVerdict: Equatable, Sendable {
    case complete(CompleteProof)
    case incomplete(PartialReason)

    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }

    var partialReason: PartialReason? {
        if case let .incomplete(reason) = self { return reason }
        return nil
    }
}

struct CompleteProof: Equatable, Sendable {
    fileprivate init() {}

    static func == (_: CompleteProof, _: CompleteProof) -> Bool { true }

    #if QUALIFICATION_FAULT_SEAM
    /// Test-only mint. Compiled solely under `QUALIFICATION_FAULT_SEAM`; a
    /// release binary has no path to this. A test seam, not a security boundary.
    static func makeForTesting() -> CompleteProof { CompleteProof() }
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
    let verdict: CompletenessVerdict
    let notes: [MIDINoteEvent]
    switch outcome {
    case let .complete(parsedNotes):
        verdict = .complete(CompleteProof())
        notes = parsedNotes
    case let .incomplete(reason):
        verdict = .incomplete(reason)
        notes = []
    }
    return MIDIRegionNoteSnapshot(
        regionReference: evidence.requestedRegion,
        projectEpoch: evidence.projectEpochAfter,
        noteCompleteness: verdict,
        provenance: .eventListAX,
        ppq: evidence.ppq,
        notes: notes,
        tempoMap: [],
        timeSignatures: []
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

    guard deriveAllNoteEventsVisible(e.filter) else {
        return .incomplete(.filterNotAllNotes)
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
    guard let roles = e.columnBinding.headerRoles,
          let calibration = e.calibration,
          columnsUniquelyResolve(roles: roles, calibration: calibration, harvest: e.harvest) else {
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

/// All note events visible AND no channel/scope/take filter active. Derived from
/// the raw checkbox states, never a caller flag. (Exact default spec is pinned
/// by the live probe; this conservative model requires the note-events checkbox
/// on and every scoping checkbox off.)
private func deriveAllNoteEventsVisible(_ filter: FilterEvidence) -> Bool {
    var noteVisible = false
    for box in filter.checkboxes {
        let id = box.id.lowercased()
        if id.contains("note") {
            if !box.checked { return false }
            noteVisible = true
        }
        if id.contains("scope") || id.contains("channel") || id.contains("take") {
            if box.checked { return false }
        }
    }
    return noteVisible
}

private func harvestKeysContiguous(_ harvest: RowHarvest) -> Bool {
    let keys = harvest.orderedRowKeys
    let keySet = Set(keys)
    guard keySet.count == keys.count else { return false }
    guard keySet == Set(harvest.passA.keys), keySet == Set(harvest.passB.keys) else { return false }
    guard keys == keys.sorted() else { return false }
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
    guard let pitchCol = roles[.pitch], let pitchCell = row[pitchCol],
          let pitchRaw = pitchCell.sliderValue else { return nil }
    let pitchInt = Int(pitchRaw.rounded())
    guard (0...127).contains(pitchInt) else { return nil }

    guard let velCol = roles[.velocity], let velCell = row[velCol],
          let velString = velCell.valueDescription,
          let velInt = Int(velString), (1...127).contains(velInt) else { return nil }

    // Channel is required, never invented: a missing channel column or value
    // fails the row (fail-closed) rather than defaulting to a guessed channel.
    guard let chCol = roles[.channel], let chCell = row[chCol], let chRaw = chCell.sliderValue else {
        return nil
    }
    let channelInt = Int(chRaw.rounded())
    guard (1...16).contains(channelInt) else { return nil }

    guard let posCol = roles[.position], let posCell = row[posCol],
          let start = bbtToTicks(posCell.groupSliderValues) else { return nil }
    guard let lenCol = roles[.length], let lenCell = row[lenCol],
          let duration = bbtToTicks(lenCell.groupSliderValues) else { return nil }

    let relativeStart = start - regionStartTick
    guard relativeStart >= 0, duration > 0 else { return nil }

    return MIDINoteEvent(
        pitch: UInt8(pitchInt),
        startTicks: relativeStart,
        durationTicks: duration,
        velocity: UInt8(velInt),
        channel: UInt8(channelInt)
    )
}

/// Placeholder BBT→tick conversion for this pure core. Only reachable
/// when `TimingEvidence` is proven, which cannot happen in a release build (the
/// validated conversion body lands later). Treats the four slider values
/// as raw tick contributions of a region-relative absolute-tick position; the
/// real display-format-aware conversion is deferred until then.
private func bbtToTicks(_ group: [Double]?) -> Int64? {
    guard let group, group.count == 4 else { return nil }
    let total = group.reduce(0.0, +)
    guard total.isFinite else { return nil }
    return Int64(total.rounded())
}

private func parseCount(_ text: String) -> Int? {
    // Parse the leading count token, allowing thousands separators. The token
    // must be cleanly delimited (end of string or whitespace) so a malformed or
    // grouped value like "1,234" or "12abc" is parsed correctly or rejected —
    // never truncated to a leading digit that could spuriously match a partial
    // harvest count (fail-closed on ambiguity).
    guard let first = text.first, first.isNumber else { return nil }
    let leading = text.prefix { $0.isNumber || $0 == "," }
    let rest = text[leading.endIndex...]
    guard rest.isEmpty || (rest.first?.isWhitespace ?? false) else { return nil }
    let digits = leading.filter { $0.isNumber }
    guard !digits.isEmpty else { return nil }
    return Int(digits)
}

private extension ColumnBinding {
    var headerRoles: [ColumnRole: AXColumnID]? {
        if case let .headerIdentity(proof) = self { return proof.roles }
        return nil
    }
}
