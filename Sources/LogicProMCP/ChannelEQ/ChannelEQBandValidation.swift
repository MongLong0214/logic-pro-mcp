private let channelEQFrequencyRange = 20.0 ... 20_000.0
private let channelEQGainRange = -24.0 ... 24.0
private let channelEQSlopeRange = 6.0 ... 48.0
private let channelEQQRange = 0.1 ... 100.0

enum EQBandRejection: Equatable, Sendable {
    case eqAbsent
    case bandOutOfRange(Int)
    case frequencyOutOfRange(Double)
    case gainOutOfRange(Double)
    case qOutOfRange(Double)
    case coordinateOnlyPlaneNotPublic
    case staleTarget
}

func validateBandWrite(
    state: ChannelEQState,
    band: Int,
    frequencyHz: Double,
    gainOrSlope: Double,
    q: Double,
    plane: EQWritePlane,
    expectedEpoch: UInt64?,
    actualEpoch: UInt64?
) -> [EQBandRejection] {
    var rejections: [EQBandRejection] = []
    if !state.present {
        rejections.append(.eqAbsent)
    }
    if !(1 ... 8).contains(band) {
        rejections.append(.bandOutOfRange(band))
    }
    if !channelEQFrequencyRange.contains(frequencyHz) {
        rejections.append(.frequencyOutOfRange(frequencyHz))
    }
    if let range = gainOrSlopeRange(for: band), !range.contains(gainOrSlope) {
        rejections.append(.gainOutOfRange(gainOrSlope))
    }
    if !channelEQQRange.contains(q) {
        rejections.append(.qOutOfRange(q))
    }
    if !plane.isPublicVerifiedWritable {
        rejections.append(.coordinateOnlyPlaneNotPublic)
    }
    if let expectedEpoch, actualEpoch != expectedEpoch {
        rejections.append(.staleTarget)
    }
    return rejections
}

private func gainOrSlopeRange(for band: Int) -> ClosedRange<Double>? {
    switch band {
    case 1, 8:
        channelEQSlopeRange
    case 2 ... 7:
        channelEQGainRange
    default:
        nil
    }
}
