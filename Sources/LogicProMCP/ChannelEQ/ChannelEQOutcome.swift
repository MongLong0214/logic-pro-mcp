func compareChannelEQ(
    before: ChannelEQState,
    after: ChannelEQState
) -> [(band: Int, field: String, before: Double, after: Double)] {
    guard before.insertRef == after.insertRef else { return [] }

    var changes: [(band: Int, field: String, before: Double, after: Double)] = []
    for oldBand in before.bands.sorted(by: { $0.band < $1.band }) {
        guard let newBand = after.bands.first(where: { $0.band == oldBand.band }) else {
            continue
        }
        if oldBand.frequencyHz != newBand.frequencyHz {
            changes.append((oldBand.band, "frequencyHz", oldBand.frequencyHz, newBand.frequencyHz))
        }
        if oldBand.gainOrSlope != newBand.gainOrSlope {
            changes.append((oldBand.band, "gainOrSlope", oldBand.gainOrSlope, newBand.gainOrSlope))
        }
        if oldBand.q != newBand.q {
            changes.append((oldBand.band, "q", oldBand.q, newBand.q))
        }
    }
    return changes
}

func sagaEligibility(
    beforeSnapshot: ChannelEQState?,
    restoreVerified: Bool
) -> (eligible: Bool, missing: [String]) {
    var missing: [String] = []
    if beforeSnapshot?.present != true
        || beforeSnapshot?.complete != true
        || beforeSnapshot?.bands.count != 8
    {
        missing.append("full_8_band_before_snapshot")
    }
    if !restoreVerified {
        missing.append("verified_restore")
    }
    return (eligible: missing.isEmpty, missing: missing)
}
