enum RegionMatchVerdict: Sendable {
    case exactMatch
    case mismatch(
        added: [MIDINoteEvent],
        removed: [MIDINoteEvent],
        changed: [(MIDINoteEvent, MIDINoteEvent)]
    )
    case incompleteCannotVerify(reason: String)
}

extension RegionMatchVerdict: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.exactMatch, .exactMatch):
            true
        case let (.incompleteCannotVerify(left), .incompleteCannotVerify(right)):
            left == right
        case let (
            .mismatch(leftAdded, leftRemoved, leftChanged),
            .mismatch(rightAdded, rightRemoved, rightChanged)
        ):
            leftAdded == rightAdded
                && leftRemoved == rightRemoved
                && leftChanged.count == rightChanged.count
                && zip(leftChanged, rightChanged).allSatisfy { left, right in
                    left.0 == right.0 && left.1 == right.1
                }
        default:
            false
        }
    }
}

/// Proof that an expected sequence was produced by ingesting an external artifact
/// INDEPENDENT of the observed readback conversion. The payload is OPAQUE — its
/// initializer is fileprivate to this file and the sole mint is
/// `ExternalArtifactIngestion`, which decodes the notes from the artifact's own
/// bytes — so a caller cannot fabricate one from observed notes plus a chosen
/// label. The proven case compiles only under the debug seam; a release build has
/// only `.unproven`.
///
/// This rollout builds the ingestion STRUCTURE only. Granting a positive match is
/// deferred (see `verifyRegion`): a pure core has no external root of trust to
/// prove that an expected sequence is genuinely independent of the observed
/// conversion, so no input — not even an ingested artifact — is reported as an
/// exact match until a real independent decode pipeline ships.
enum IndependentExpectedProof: Sendable {
    case unproven
    #if QUALIFICATION_FAULT_SEAM
    case provenExternalArtifact(ExternalArtifactProof)
    #endif

    /// The independent expected payload (artifact id + artifact-decoded notes +
    /// artifact-embedded PPQ), or nil when not proven — nil in every release build.
    var independentExpected: (artifactID: String, notes: [MIDINoteEvent], ppq: Int)? {
        #if QUALIFICATION_FAULT_SEAM
        if case let .provenExternalArtifact(proof) = self {
            return (proof.artifactID, proof.boundNotes, proof.ppq)
        }
        #endif
        return nil
    }
}

#if QUALIFICATION_FAULT_SEAM
/// Opaque, non-caller-constructible proof of an ingested external artifact. The
/// initializer is fileprivate to this file, so no other file (including a
/// `@testable` importer, which does not open `fileprivate`) can build one; the
/// notes and PPQ are decoded from the artifact bytes at ingestion, never supplied
/// directly.
struct ExternalArtifactProof: Sendable {
    let artifactID: String
    fileprivate let boundNotes: [MIDINoteEvent]
    fileprivate let ppq: Int
    fileprivate init(artifactID: String, boundNotes: [MIDINoteEvent], ppq: Int) {
        self.artifactID = artifactID
        self.boundNotes = boundNotes
        self.ppq = ppq
    }
}

/// The sole mint of a proven `IndependentExpectedProof` (debug seam). Notes and
/// PPQ are DECODED from a strict, fixed-width artifact byte stream — never taken
/// from the caller — so observed notes cannot be laundered into an independent
/// proof by choosing a label. Fails closed on an empty or known-pipeline artifact
/// id and on any malformed/truncated/trailing/overflowing byte stream.
enum ExternalArtifactIngestion {
    private static let headerSize = 12   // 8-byte PPQ + 4-byte note count
    private static let recordSize = 19   // pitch(1) velocity(1) channel(1) start(8) duration(8)

    /// Wire form for a test artifact (models an authored/imported file's bytes).
    static func encode(_ notes: [MIDINoteEvent], ppq: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        appendInt64(&bytes, Int64(ppq))
        appendUInt32(&bytes, UInt32(truncatingIfNeeded: notes.count))
        for note in notes {
            bytes.append(note.pitch)
            bytes.append(note.velocity)
            bytes.append(note.channel)
            appendInt64(&bytes, note.startTicks)
            appendInt64(&bytes, note.durationTicks)
        }
        return bytes
    }

    /// Ingest raw artifact bytes as the independent expected source. Returns nil
    /// (fail-closed) on an empty / known-pipeline id or malformed bytes. PPQ comes
    /// from the artifact, not the caller.
    static func ingest(artifactID: String, rawArtifact: [UInt8]) -> ExpectedSequence? {
        guard !artifactID.isEmpty,
              artifactID != MIDIRegionNoteSnapshot.eventListConversionID,
              let decoded = decode(rawArtifact),
              decoded.ppq > 0 else { return nil }
        return ExpectedSequence(_proof: ExternalArtifactProof(
            artifactID: artifactID, boundNotes: decoded.notes, ppq: decoded.ppq
        ))
    }

    /// Strict decode: exact total length (rejects BOTH trailing and truncated
    /// bytes), overflow-safe record count, fixed-width fields (no delimiter or
    /// injection surface). Any deviation returns nil.
    private static func decode(_ bytes: [UInt8]) -> (notes: [MIDINoteEvent], ppq: Int)? {
        guard bytes.count >= headerSize else { return nil }
        let ppq64 = readInt64(bytes, 0)
        let count = readUInt32(bytes, 8)
        guard let body = Int(exactly: UInt64(count) * UInt64(recordSize)),
              let total = Int(exactly: UInt64(headerSize) + UInt64(body)),
              bytes.count == total,
              let ppq = Int(exactly: ppq64) else { return nil }
        var notes: [MIDINoteEvent] = []
        notes.reserveCapacity(Int(count))
        var offset = headerSize
        for _ in 0 ..< count {
            notes.append(MIDINoteEvent(
                pitch: bytes[offset],
                startTicks: readInt64(bytes, offset + 3),
                durationTicks: readInt64(bytes, offset + 11),
                velocity: bytes[offset + 1],
                channel: bytes[offset + 2]
            ))
            offset += recordSize
        }
        return (notes, ppq)
    }

    private static func appendInt64(_ bytes: inout [UInt8], _ value: Int64) {
        let bits = UInt64(bitPattern: value)
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
    }
    private static func appendUInt32(_ bytes: inout [UInt8], _ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }
    private static func readInt64(_ bytes: [UInt8], _ offset: Int) -> Int64 {
        var bits: UInt64 = 0
        for i in 0 ..< 8 { bits = (bits << 8) | UInt64(bytes[offset + i]) }
        return Int64(bitPattern: bits)
    }
    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0 ..< 4 { value = (value << 8) | UInt32(bytes[offset + i]) }
        return value
    }
}
#endif

/// A caller's expected note sequence with its independent-provenance proof. The
/// public initializer is UNPROVEN-only: a proven sequence can be produced solely
/// by `ExternalArtifactIngestion`, so a caller cannot pair a proof with foreign
/// notes (there is no dual source of truth).
struct ExpectedSequence {
    let notes: [MIDINoteEvent]
    let ppq: Int
    let provenance: IndependentExpectedProof

    init(notes: [MIDINoteEvent], ppq: Int) {
        self.notes = notes
        self.ppq = ppq
        self.provenance = .unproven
    }

    #if QUALIFICATION_FAULT_SEAM
    fileprivate init(_proof proof: ExternalArtifactProof) {
        self.notes = proof.boundNotes
        self.ppq = proof.ppq
        self.provenance = .provenExternalArtifact(proof)
    }
    #endif
}

func verifyRegion(
    observed: MIDIRegionNoteSnapshot,
    expected: ExpectedSequence
) -> RegionMatchVerdict {
    guard observed.complete else {
        return .incompleteCannotVerify(
            reason: observed.partialReason ?? "MIDI note scan is incomplete"
        )
    }
    guard observed.provenance != .none else {
        return .incompleteCannotVerify(reason: "Independent readback provenance is required")
    }
    // Independence guard: the expected sequence must carry a PROVEN independent
    // provenance (an ingested external artifact, not a caller-fabricated label).
    // The payload — notes, PPQ, artifact id — comes from the opaque proof, never
    // from caller-supplied `expected.notes`, so a proof cannot be paired with
    // foreign notes. In a release build `independentExpected` is always nil, so
    // verification stops here.
    guard let independent = expected.provenance.independentExpected else {
        return .incompleteCannotVerify(
            reason: "Expected sequence must carry a proven independent provenance"
        )
    }
    // The artifact source must differ from the observed snapshot's conversion, so
    // a re-derivation sharing the observed conversion cannot pass as independent.
    guard observed.conversionPipelineID != independent.artifactID else {
        return .incompleteCannotVerify(
            reason: "Expected sequence must not share the observed conversion pipeline"
        )
    }
    guard observed.ppq > 0, independent.ppq > 0 else {
        return .incompleteCannotVerify(reason: "PPQ must be positive")
    }

    let actual = canonicalize(observed.notes, ppq: observed.ppq)
    guard let normalizedExpected = normalizePPQ(independent.notes, from: independent.ppq, to: observed.ppq) else {
        return .incompleteCannotVerify(reason: "PPQ normalization overflow")
    }
    let wanted = canonicalize(normalizedExpected, ppq: observed.ppq)
    guard actual != wanted else {
        // DEFERRED — never `.exactMatch` in this rollout. A pure core cannot prove
        // the expected sequence is genuinely independent of the observed conversion
        // (no external root of trust: no real second decode pipeline yet), so it
        // grants NO positive match — even an ingested artifact whose notes equal
        // the observed notes. Reporting a would-be match as verified would be the
        // caller-mintable independence the contract forbids. Activation waits for a
        // real independent decode pipeline. Negative results (below) stay safe.
        return .incompleteCannotVerify(
            reason: "Independent exact-match verification is deferred to a real external decode pipeline"
        )
    }

    let differences = noteDifferences(expected: wanted, observed: actual)
    return .mismatch(
        added: differences.added,
        removed: differences.removed,
        changed: differences.changed
    )
}

func diffRegions(
    before: MIDIRegionNoteSnapshot,
    after: MIDIRegionNoteSnapshot
) -> (added: [MIDINoteEvent], removed: [MIDINoteEvent])? {
    // Both sides must be complete (a decoded/incomplete payload keeps its notes
    // but must not drive added/removed claims) and must normalize without
    // overflow — else there is no trustworthy diff.
    guard before.complete, after.complete else { return nil }
    let comparisonPPQ = max(max(before.ppq, after.ppq), 1)
    guard let previousNotes = normalizePPQ(before.notes, from: before.ppq, to: comparisonPPQ),
          let currentNotes = normalizePPQ(after.notes, from: after.ppq, to: comparisonPPQ) else {
        return nil
    }
    let previous = canonicalize(previousNotes, ppq: comparisonPPQ)
    let current = canonicalize(currentNotes, ppq: comparisonPPQ)

    // ponytail: O(n²) preserves duplicate-note multiset semantics; index if qualified
    // providers make very large region diffs a measured hot path.
    var unmatchedPrevious = previous
    var added: [MIDINoteEvent] = []
    for note in current {
        if let index = unmatchedPrevious.firstIndex(of: note) {
            unmatchedPrevious.remove(at: index)
        } else {
            added.append(note)
        }
    }
    return (added: added, removed: unmatchedPrevious)
}

private func noteDifferences(
    expected: [MIDINoteEvent],
    observed: [MIDINoteEvent]
) -> (
    added: [MIDINoteEvent],
    removed: [MIDINoteEvent],
    changed: [(MIDINoteEvent, MIDINoteEvent)]
) {
    var remainingObserved = observed
    var remainingExpected: [MIDINoteEvent] = []
    for note in expected {
        if let index = remainingObserved.firstIndex(of: note) {
            remainingObserved.remove(at: index)
        } else {
            remainingExpected.append(note)
        }
    }

    var removed: [MIDINoteEvent] = []
    var changed: [(MIDINoteEvent, MIDINoteEvent)] = []
    for note in remainingExpected {
        if let index = remainingObserved.firstIndex(where: { sameIdentity($0, note) }) {
            changed.append((note, remainingObserved.remove(at: index)))
        } else {
            removed.append(note)
        }
    }
    return (added: remainingObserved, removed: removed, changed: changed)
}

private func sameIdentity(_ lhs: MIDINoteEvent, _ rhs: MIDINoteEvent) -> Bool {
    lhs.pitch == rhs.pitch
        && lhs.channel == rhs.channel
        && lhs.startTicks == rhs.startTicks
}
