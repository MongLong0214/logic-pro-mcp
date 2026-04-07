import Foundation

/// Thread-safe in-memory cache for Logic Pro project state.
/// Read by tools for instant response; written by the StatePoller.
actor StateCache {
    private(set) var transport = TransportState()
    private(set) var tracks: [TrackState] = []
    private(set) var channelStrips: [ChannelStripState] = []
    private(set) var regions: [RegionState] = []
    private(set) var markers: [MarkerState] = []
    private(set) var project = ProjectInfo()
    private(set) var mcuConnection = MCUConnectionState()
    private(set) var mcuDisplay = MCUDisplayState()

    /// Timestamp of last tool call — drives adaptive poll intervals.
    private(set) var lastToolAccess: Date = .distantPast

    // MARK: - Read access (tools call these)

    func getTransport() -> TransportState { transport }
    func getTracks() -> [TrackState] { tracks }
    func getTrack(at index: Int) -> TrackState? {
        guard tracks.indices.contains(index) else { return nil }
        return tracks[index]
    }
    func getSelectedTrack() -> TrackState? {
        tracks.first(where: { $0.isSelected })
    }
    func getChannelStrips() -> [ChannelStripState] { channelStrips }
    func getChannelStrip(at index: Int) -> ChannelStripState? {
        channelStrips.first(where: { $0.trackIndex == index })
    }
    func getRegions() -> [RegionState] { regions }
    func getMarkers() -> [MarkerState] { markers }
    func getProject() -> ProjectInfo { project }
    func getMCUConnection() -> MCUConnectionState { mcuConnection }
    func getMCUDisplay() -> MCUDisplayState { mcuDisplay }

    // MARK: - Write access (poller calls these)

    private func ensureTrackExists(at index: Int) {
        guard index >= 0 else { return }
        while tracks.count <= index {
            let nextIndex = tracks.count
            tracks.append(
                TrackState(
                    id: nextIndex,
                    name: "Track \(nextIndex + 1)",
                    type: .unknown
                )
            )
        }
    }

    private func ensureChannelStripExists(at index: Int) {
        guard index >= 0 else { return }
        while channelStrips.count <= index {
            channelStrips.append(ChannelStripState(trackIndex: channelStrips.count))
        }
    }

    func updateTransport(_ state: TransportState) {
        transport = state
    }

    func updateTracks(_ newTracks: [TrackState]) {
        tracks = newTracks
    }

    func updateTrack(at index: Int, mutator: (inout TrackState) -> Void) {
        ensureTrackExists(at: index)
        guard tracks.indices.contains(index) else { return }
        mutator(&tracks[index])
    }

    func updateChannelStrips(_ strips: [ChannelStripState]) {
        channelStrips = strips
    }

    func updateRegions(_ newRegions: [RegionState]) {
        regions = newRegions
    }

    func updateMarkers(_ newMarkers: [MarkerState]) {
        markers = newMarkers
    }

    func updateProject(_ info: ProjectInfo) {
        project = info
    }

    // MARK: - MCU Feedback Write

    func updateFader(strip: Int, volume: Double) {
        ensureChannelStripExists(at: strip)
        guard channelStrips.indices.contains(strip) else { return }
        channelStrips[strip].volume = volume
    }

    func updateMCUConnection(_ state: MCUConnectionState) {
        mcuConnection = state
    }

    func updateMCUDisplay(_ display: MCUDisplayState) {
        mcuDisplay = display
    }

    func updateMCUDisplayRow(upper: Bool, text: String, offset: Int) {
        if upper {
            var row = Array(mcuDisplay.upperRow)
            for (i, ch) in text.enumerated() {
                let pos = offset + i
                if pos < row.count { row[pos] = ch }
            }
            mcuDisplay.upperRow = String(row)
        } else {
            var row = Array(mcuDisplay.lowerRow)
            for (i, ch) in text.enumerated() {
                let pos = (offset - 0x38) + i
                if pos >= 0 && pos < row.count { row[pos] = ch }
            }
            mcuDisplay.lowerRow = String(row)
        }
    }

    // MARK: - Tool access tracking

    func recordToolAccess() {
        lastToolAccess = Date()
    }

    func timeSinceLastToolAccess() -> TimeInterval {
        Date().timeIntervalSince(lastToolAccess)
    }

    // MARK: - Bulk state for diagnostics

    struct CacheSnapshot: Sendable {
        let transportAge: TimeInterval
        let trackCount: Int
        let regionCount: Int
        let markerCount: Int
        let projectName: String
        let pollMode: String
    }

    func snapshot() -> CacheSnapshot {
        let idle = timeSinceLastToolAccess()
        let mode = idle < 5 ? "active" : "idle"
        return CacheSnapshot(
            transportAge: Date().timeIntervalSince(transport.lastUpdated),
            trackCount: tracks.count,
            regionCount: regions.count,
            markerCount: markers.count,
            projectName: project.name,
            pollMode: mode
        )
    }
}
