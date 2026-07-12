import Foundation

struct FlexPitchNoteReference: Codable, Hashable, Sendable {
    let regionRef: TargetReference
    let analysisGeneration: UInt64
    let noteOrdinal: Int
    let startTick: Int64
    let durationTicks: Int64
    let coarsePitch: Int
    let pitchCurveFingerprint: String
}

struct FlexPitchNote: Codable, Equatable, Sendable {
    let reference: FlexPitchNoteReference
    let cents: Double
    let gainDb: Double
}

enum FlexProvenance: String, Codable, Equatable, Sendable {
    case midiTrackFromFlexPlusReadback
    case none
}

struct FlexPitchSnapshot: Codable, Equatable, Sendable {
    let regionRef: TargetReference
    let analysisGeneration: UInt64
    let monophonicConfidence: Double
    let notes: [FlexPitchNote]
    let provenance: FlexProvenance
    let complete: Bool
    let partialReason: String?

    init(
        regionRef: TargetReference,
        analysisGeneration: UInt64,
        monophonicConfidence: Double,
        notes: [FlexPitchNote],
        provenance: FlexProvenance,
        complete: Bool,
        partialReason: String?
    ) {
        self.regionRef = regionRef
        self.analysisGeneration = analysisGeneration
        self.monophonicConfidence = monophonicConfidence
        self.notes = notes
        self.provenance = provenance
        self.complete = complete
        self.partialReason = complete ? nil : partialReason
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            regionRef: try values.decode(TargetReference.self, forKey: .regionRef),
            analysisGeneration: try values.decode(UInt64.self, forKey: .analysisGeneration),
            monophonicConfidence: try values.decode(Double.self, forKey: .monophonicConfidence),
            notes: try values.decode([FlexPitchNote].self, forKey: .notes),
            provenance: try values.decode(FlexProvenance.self, forKey: .provenance),
            complete: try values.decode(Bool.self, forKey: .complete),
            partialReason: try values.decodeIfPresent(String.self, forKey: .partialReason)
        )
    }
}
