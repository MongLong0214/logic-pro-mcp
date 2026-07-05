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

    /// Whether Logic Pro has an open document with a visible window.
    /// Defaults to true (optimistic) — StatePoller sets to false when no document detected.
    private(set) var hasDocument: Bool = true

    /// v3.1.4 (#4) — true when the StatePoller's last cycle observed AX
    /// occlusion (modal dialog or plugin floating window holding focus). In
    /// this state the cache is intentionally NOT cleared even if the AX
    /// project/track polls failed, because the failures are caused by the
    /// occluding window — not by a closed document. Resource readers that
    /// want a stale-by-occlusion signal can read this alongside
    /// `cache_age_sec` to render an accurate freshness explanation rather
    /// than silently returning prior values.
    private(set) var axOccluded: Bool = false

    /// Timestamp of last tool call — drives adaptive poll intervals.
    private(set) var lastToolAccess: Date = .distantPast

    /// v3.1.0 (T7) — per-section "last fetched" timestamps so state resources
    /// can report an honest `cache_age_sec` / `fetched_at` to clients rather
    /// than silently serving stale data. All fields default to `.distantPast`
    /// so the envelope is `null` until the poller first writes.
    private(set) var tracksFetchedAt: Date = .distantPast
    private(set) var mixerFetchedAt: Date = .distantPast
    private(set) var projectFetchedAt: Date = .distantPast
    private(set) var markersFetchedAt: Date = .distantPast
    private(set) var regionsFetchedAt: Date = .distantPast

    /// v3.1.0 (Ralph-2 / C1 fix) — per-strip fader-echo write timestamp.
    /// Updated whenever `updateFader` ingests an MCU pitch-bend echo (or any
    /// other volume write). `MCUChannel.pollFaderEcho` compares this against
    /// its send-time stamp so a stale cache value from a previous `set_volume`
    /// cannot masquerade as a fresh echo and produce a false `verified:true`.
    private var faderUpdatedAt: [Int: Date] = [:]

    /// v3.1.3 (#1) — per-strip V-Pot LED-ring echo write timestamp. Mirrors
    /// `faderUpdatedAt` for the pan path. `MCUChannel.pollPanEcho` compares
    /// this to the send-time stamp so a previously-cached pan value cannot
    /// masquerade as a fresh Logic echo and false-positively flip a pan
    /// write to State A.
    private var panUpdatedAt: [Int: Date] = [:]

    /// v3.1.1 (P1-3) — consecutive empty-track polls observed while
    /// `hasDocument == true`. Logic Pro sporadically returns an empty track
    /// list when a modal dialog is over the arrange (file-open panel,
    /// Bounce, tempo alert, etc.) because `mainWindow` is briefly the
    /// dialog's window and the AX subtree carries no track headers. The P1-2
    /// dialog filter mitigates that, but a window-state race can still send
    /// `[]` through `updateTracks`. Without the guard the cache then reports
    /// "empty project" to clients for one poll cycle and every track tool
    /// silently degrades. We absorb the first two such polls (skip the
    /// update, keep the prior cache) and only commit `[]` once the count
    /// reaches 3 — at which point the empty state is treated as genuine
    /// (project really is empty / closed). Counter resets on any non-empty
    /// update.
    private var consecutiveEmptyPolls: Int = 0
    private static let emptyPollThreshold = 3

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
    func getHasDocument() -> Bool { hasDocument }

    /// v3.1.4 (#4) — current AX occlusion flag. See field comment for
    /// semantics; flips to true when StatePoller detects a dialog/plugin
    /// window suppressing AX project/track reads, false on the next clean
    /// poll or when the document is genuinely closed.
    func getAXOccluded() -> Bool { axOccluded }

    /// Atomic, single-hop read of every field the project audit consumes.
    /// `buildAudit` previously assembled its snapshot from ~13 separate `await`
    /// calls; each was individually actor-serialized but the sequence was not a
    /// single critical section, so a concurrent poller/dispatcher write could
    /// interleave and yield a torn snapshot (e.g. `regions` from a newer track
    /// set than `tracks`). This method runs synchronously inside the actor, so
    /// all returned fields belong to one consistent cache state.
    func auditSnapshot() -> (
        hasDocument: Bool,
        axOccluded: Bool,
        project: ProjectInfo,
        projectFetchedAt: Date,
        transport: TransportState,
        tracks: [TrackState],
        tracksFetchedAt: Date,
        regions: [RegionState],
        regionsFetchedAt: Date,
        markers: [MarkerState],
        markersFetchedAt: Date,
        channelStrips: [ChannelStripState],
        mixerFetchedAt: Date
    ) {
        (
            hasDocument: hasDocument,
            axOccluded: axOccluded,
            project: project,
            projectFetchedAt: projectFetchedAt,
            transport: transport,
            tracks: tracks,
            tracksFetchedAt: tracksFetchedAt,
            regions: regions,
            regionsFetchedAt: regionsFetchedAt,
            markers: markers,
            markersFetchedAt: markersFetchedAt,
            channelStrips: channelStrips,
            mixerFetchedAt: mixerFetchedAt
        )
    }

    // MARK: - Document state

    func updateDocumentState(_ hasDoc: Bool) {
        hasDocument = hasDoc
        if !hasDoc {
            clearProjectState()
        }
    }

    /// v3.1.4 (#4) — set the AX occlusion flag. Idempotent; called every
    /// poll cycle by `StatePoller.pollOnce`.
    func updateAXOccluded(_ occluded: Bool) {
        axOccluded = occluded
    }

    func clearProjectState() {
        project = ProjectInfo()
        tracks = []
        channelStrips = []
        regions = []
        markers = []
        // Re-initialising transport picks up its default `lastUpdated =
        // .distantPast`, which is how snapshot() signals "stale" to readers
        // (transport_age_sec becomes astronomically large). Clients can
        // combine hasDocument with transport_age_sec to distinguish
        // "no project open" from "project open, idle playback".
        transport = TransportState()
    }

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
        // v3.1.1 (P1-3) — debounce empty-list overwrites caused by a modal
        // dialog briefly occluding the arrange window. While `hasDocument`
        // is true and the prior cache was non-empty, the first two empty
        // polls are absorbed (cache preserved, fetchedAt left untouched so
        // `cache_age_sec` keeps growing — clients can still see staleness).
        // After `emptyPollThreshold` consecutive empties we commit `[]` so
        // a genuinely closed/empty project is eventually reflected.
        if newTracks.isEmpty && hasDocument && !tracks.isEmpty {
            consecutiveEmptyPolls += 1
            if consecutiveEmptyPolls < Self.emptyPollThreshold {
                return
            }
            // Threshold reached — let the empty update through and reset so
            // we don't permanently suppress the next empty/non-empty cycle.
            consecutiveEmptyPolls = 0
        } else if !newTracks.isEmpty {
            consecutiveEmptyPolls = 0
        }
        tracks = newTracks
        tracksFetchedAt = Date()
    }

    /// v3.1.1 (P1-3) — exposed for diagnostics and tests. Returns the number
    /// of consecutive empty `updateTracks([])` calls suppressed since the
    /// last non-empty update. Resets to 0 once any non-empty update lands or
    /// once an empty update finally commits at the threshold.
    func getConsecutiveEmptyPolls() -> Int { consecutiveEmptyPolls }

    func getTracksFetchedAt() -> Date { tracksFetchedAt }
    func getMixerFetchedAt() -> Date { mixerFetchedAt }
    func getProjectFetchedAt() -> Date { projectFetchedAt }
    func getMarkersFetchedAt() -> Date { markersFetchedAt }
    func getRegionsFetchedAt() -> Date { regionsFetchedAt }

    func updateTrack(at index: Int, mutator: (inout TrackState) -> Void) {
        ensureTrackExists(at: index)
        guard tracks.indices.contains(index) else { return }
        mutator(&tracks[index])
    }

    /// Mark exactly one track as selected, clearing the flag on every other
    /// track. Mirrors Logic Pro's single-selection model so the cache never
    /// reports two tracks selected at once.
    func selectOnly(trackAt index: Int) {
        ensureTrackExists(at: index)
        guard tracks.indices.contains(index) else { return }
        for i in tracks.indices {
            tracks[i].isSelected = (i == index)
        }
    }

    func updateChannelStrips(_ strips: [ChannelStripState]) {
        channelStrips = strips
        mixerFetchedAt = Date()
    }

    func updateRegions(_ newRegions: [RegionState]) {
        regions = newRegions
        regionsFetchedAt = Date()
    }

    func updateMarkers(_ newMarkers: [MarkerState]) {
        // v3.1.9 (Issue #8) — always advance `markersFetchedAt`, even when
        // the list is unchanged. Previously the equality short-circuit
        // skipped the timestamp update, so a poller that successfully
        // observed "still no markers" twice in a row left
        // `markersFetchedAt == .distantPast` — and the resource handler
        // reported `source: "default"` instead of `"ax_live"`, making
        // "honest empty" indistinguishable from "never polled". The data
        // assignment is still guarded so listeners that diff
        // `cache.markers` directly don't see redundant publishes.
        markersFetchedAt = Date()
        if markers != newMarkers {
            markers = newMarkers
        }
    }

    func updateProject(_ info: ProjectInfo) {
        project = info
        projectFetchedAt = Date()
    }

    // MARK: - MCU Feedback Write

    func updateFader(strip: Int, volume: Double) {
        ensureChannelStripExists(at: strip)
        guard channelStrips.indices.contains(strip) else { return }
        channelStrips[strip].volume = volume
        // v3.1.0 (Ralph-2 / C1) — stamp the write time so pollFaderEcho can
        // tell a fresh echo from a stale cache hit left over from a prior
        // identical-value set_volume call.
        faderUpdatedAt[strip] = Date()
    }

    /// v3.1.0 (Ralph-2 / C1) — last time an MCU echo (or any other caller)
    /// wrote a volume into this strip. Returns nil when no write has been
    /// observed on this strip this session.
    func getFaderUpdatedAt(strip: Int) -> Date? {
        faderUpdatedAt[strip]
    }

    /// v3.1.3 (#1) — write a pan value (-1.0..+1.0) for the given strip and
    /// stamp the moment the echo arrived. Decoded from MCU V-Pot LED-ring
    /// CC 0x30..0x37 frames by `MCUFeedbackParser`.
    func updatePan(strip: Int, value: Double) {
        ensureChannelStripExists(at: strip)
        guard channelStrips.indices.contains(strip) else { return }
        channelStrips[strip].pan = min(max(value, -1.0), 1.0)
        panUpdatedAt[strip] = Date()
    }

    /// v3.1.3 (#1) — last time a V-Pot LED-ring echo wrote a pan into this
    /// strip. Returns nil when no echo has been observed this session.
    func getPanUpdatedAt(strip: Int) -> Date? {
        panUpdatedAt[strip]
    }

    /// v3.1.3 (#1) — current cached pan for the strip, or nil when the
    /// strip hasn't been initialised. Convenience for `pollPanEcho`.
    func getPanValue(strip: Int) -> Double? {
        guard let cs = getChannelStrip(at: strip) else { return nil }
        return cs.pan
    }

    /// v3.4.5-rc5 (Boomer BOOMER-6 / B2 — TOCTOU race fix). Atomic snapshot
    /// of (volume, faderUpdatedAt) for a strip in a single actor turn.
    ///
    /// Background: `pollFaderEcho` previously read the volume and the
    /// timestamp in two separate `await cache.…` calls. Between those
    /// awaits a concurrent MCU feedback event could land via
    /// `updateFader`, pairing an old value from the first read with a new
    /// timestamp from the second — and a stale value could then pass the
    /// `writtenAt > sendAt` freshness guard and false-positive State A on
    /// a disconnected transport. Reading both in one actor turn closes the
    /// window. Returns `(nil, nil)` when the strip has no cached state.
    func getFaderEchoSnapshot(strip: Int) -> (volume: Double?, updatedAt: Date?) {
        return (channelStrips.indices.contains(strip) ? channelStrips[strip].volume : nil,
                faderUpdatedAt[strip])
    }

    /// v3.4.5-rc5 (Boomer BOOMER-6 / B2). Pan counterpart to
    /// `getFaderEchoSnapshot`. Same atomicity rationale.
    func getPanEchoSnapshot(strip: Int) -> (pan: Double?, updatedAt: Date?) {
        return (channelStrips.indices.contains(strip) ? channelStrips[strip].pan : nil,
                panUpdatedAt[strip])
    }

    func updateMCUConnection(_ state: MCUConnectionState) {
        mcuConnection = state
    }

    /// v3.8.0 (WS6 / AC3, audit #7) — atomic read-modify-write of the MCU
    /// connection state within a single actor turn. The MCU feedback parser
    /// and the channel's start()/stop() both touch this struct; a
    /// get→mutate→set split across `await` boundaries let a concurrent writer
    /// lose an update (e.g. a feedback event flipping `isConnected` between a
    /// stop()'s read and its write). Mutating in place on the actor closes
    /// that window structurally.
    func updateMCUConnection(mutator: (inout MCUConnectionState) -> Void) {
        mutator(&mcuConnection)
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
