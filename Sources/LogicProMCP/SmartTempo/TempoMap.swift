enum ProjectTempoMode: String, Codable, CaseIterable, Equatable, Sendable {
    case keep
    case adapt
    case autoMatch
}

struct TempoMapEvent: Codable, Equatable, Sendable {
    let tick: Int64
    let bpm: Double
}

struct TempoMapSnapshot: Codable, Equatable, Sendable {
    let events: [TempoMapEvent]
    let timeSignatures: [TimeSignatureEvent]
    let ppq: Int
    let complete: Bool
    let partialReason: String?

    init(
        events: [TempoMapEvent],
        timeSignatures: [TimeSignatureEvent],
        ppq: Int,
        complete: Bool,
        partialReason: String?
    ) {
        self.events = events
        self.timeSignatures = timeSignatures
        self.ppq = ppq
        self.complete = complete
        self.partialReason = complete ? nil : partialReason
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            events: try values.decode([TempoMapEvent].self, forKey: .events),
            timeSignatures: try values.decode([TimeSignatureEvent].self, forKey: .timeSignatures),
            ppq: try values.decode(Int.self, forKey: .ppq),
            complete: try values.decode(Bool.self, forKey: .complete),
            partialReason: try values.decodeIfPresent(String.self, forKey: .partialReason)
        )
    }
}

struct SmartTempoState: Codable, Equatable, Sendable {
    let mode: ProjectTempoMode
    let analysisAvailable: Bool
    let mapPresent: Bool
    let complete: Bool
    let partialReason: String?
}
