enum EQBandRole: String, Codable, Sendable {
    case highPass
    case lowShelf
    case parametric1
    case parametric2
    case parametric3
    case parametric4
    case highShelf
    case lowPass
}

struct ChannelEQBandState: Codable, Equatable, Sendable {
    let band: Int
    let filterRole: EQBandRole
    let frequencyHz: Double
    let gainOrSlope: Double
    let q: Double
    let enabled: Bool
}

struct ChannelEQState: Codable, Equatable, Sendable {
    let insertRef: TargetReference?
    let present: Bool
    let bands: [ChannelEQBandState]
    let masterGainDb: Double?
    let complete: Bool
    let partialReason: String?

    init(
        insertRef: TargetReference?,
        present: Bool,
        bands: [ChannelEQBandState],
        masterGainDb: Double?,
        complete: Bool,
        partialReason: String?
    ) {
        self.insertRef = insertRef
        self.present = present && bands.count == 8
        self.bands = bands
        self.masterGainDb = masterGainDb
        self.complete = complete
        self.partialReason = complete ? nil : partialReason
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            insertRef: try values.decodeIfPresent(TargetReference.self, forKey: .insertRef),
            present: try values.decode(Bool.self, forKey: .present),
            bands: try values.decode([ChannelEQBandState].self, forKey: .bands),
            masterGainDb: try values.decodeIfPresent(Double.self, forKey: .masterGainDb),
            complete: try values.decode(Bool.self, forKey: .complete),
            partialReason: try values.decodeIfPresent(String.self, forKey: .partialReason)
        )
    }
}
