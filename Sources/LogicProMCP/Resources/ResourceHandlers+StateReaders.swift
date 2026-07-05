import Foundation
import MCP

/// Live-state resource readers (transport, tracks, mixer, project,
/// MIDI ports, markers, MCU, system health) backed by StateCache.
extension ResourceHandlers {
    // MARK: - Individual resource handlers

    static func readTransportState(cache: StateCache, router: ChannelRouter, uri: String) async throws -> ReadResource.Result {
        let liveRefresh = await readLiveTransportState(router: router)
        if let liveState = liveRefresh.state {
            await cache.updateTransport(liveState)
        }

        let state = await cache.getTransport()
        let hasDocument = await cache.getHasDocument()
        let axOccluded = await cache.getAXOccluded()
        // v3.1.1 (T-9) — unified `{cache_age_sec, fetched_at, data}` envelope.
        // v3.1.4 — `ax_occluded` added so clients can detect when the
        // StatePoller is preserving cache through a modal-dialog or
        // plugin-window AX occlusion.
        let inner = encodeJSON(state)
        let body = """
            {"state":\(inner),"has_document":\(hasDocument)}
            """
        let json = wrapWithCacheEnvelope(
            bodyJSON: body,
            fetchedAt: state.lastUpdated,
            axOccluded: axOccluded,
            extras: transportStateEnvelopeExtras(liveRefresh: liveRefresh, cachedState: state)
        )
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    struct LiveTransportStateReadback: Sendable {
        let state: TransportState?
        let errorCode: String?
    }

    /// Live transport refresh shared by the `logic://transport/state`
    /// resource and post-write dispatcher verification.
    static func readLiveTransportState(router: ChannelRouter) async -> LiveTransportStateReadback {
        let result = await router.route(operation: "transport.get_state")
        guard result.isSuccess else {
            return LiveTransportStateReadback(
                state: nil,
                errorCode: HonestContract.stateCErrorCode(result.message) ?? "live_transport_read_failed"
            )
        }
        guard let state = decodeTransportState(result.message) else {
            return LiveTransportStateReadback(
                state: nil,
                errorCode: "undecodable_live_transport_state"
            )
        }
        return LiveTransportStateReadback(state: state, errorCode: nil)
    }

    private static func transportStateEnvelopeExtras(
        liveRefresh: LiveTransportStateReadback,
        cachedState: TransportState
    ) -> [String: Any] {
        if liveRefresh.state != nil {
            return ["source": "ax_live"]
        }

        let hasCachedState = cachedState.lastUpdated > .distantPast
        var extras: [String: Any] = [
            "source": hasCachedState ? "cache" : "default",
            "unverified": true,
            "stale": hasCachedState,
            "recovery_hint": "live transport refresh unavailable; focus Logic's Tracks window, dismiss modal or plugin dialogs, then retry or run logic_system refresh_cache."
        ]
        if let errorCode = liveRefresh.errorCode {
            extras["refresh_error"] = errorCode
        }
        return extras
    }

    private static func decodeTransportState(_ json: String) -> TransportState? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }

            let wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
            if let date = wholeSeconds.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid transport lastUpdated timestamp: \(value)"
            )
        }
        return try? decoder.decode(TransportState.self, from: data)
    }

    /// v3.1.8 (Issue #7) — tier-merged track list read.
    ///
    /// Tier order:
    ///   1. Cache (live AX poll). If non-empty AND not Inspector-contaminated,
    ///      surface as-is, source: "ax_live".
    ///   2. LogicProjectFileReader's `NumberOfTracks`. Synthesise placeholder
    ///      rows (`name: "Track 1".."Track \(N)"`, `placeholder: true`).
    ///      Source: "ax_live_with_file_count" if poller has run before but
    ///      came up empty; "project_file" if poller never ran.
    ///   3. Empty array. Source: "default".
    ///
    /// Inspector contamination guard (boomer P0 / E10): when AX traversal
    /// returns >= 3 entries whose names ALL end in `:`, treat the data as the
    /// Inspector subtree leaking through (Logic Pro 12.x failure mode where a
    /// non-arrange panel is focused). Drop those rows and fall to Tier 2/3.
    /// The threshold of 3 prevents a legitimate single track named "MyMix:"
    /// from triggering false-positive contamination detection.
    ///
    /// **Critical (G5)**: this function is read-only with respect to cache.
    /// Placeholder rows are NEVER written back via `cache.updateTracks(...)`.
    /// Doing so would poison name-routed write actions like
    /// `track.select { name: "Track 5" }` in `TrackDispatcher.swift:44`.
    static func readTracks(
        cache: StateCache,
        uri: String,
        fileReader: LogicProjectFileReader.Runtime
    ) async throws -> ReadResource.Result {
        var liveTracks = await cache.getTracks()
        let cacheFetchedAt = await cache.getTracksFetchedAt()
        let axOccluded = await cache.getAXOccluded()

        // Inspector contamination guard.
        if tracksAreInspectorContaminated(liveTracks) {
            liveTracks = []
        }

        var tracksOut: [TrackState] = []
        var source: String

        if !liveTracks.isEmpty {
            tracksOut = liveTracks
            source = "ax_live"
        } else {
            // Tier 2: synthesise placeholders from file count.
            let metadata = await LogicProjectFileReader.read(runtime: fileReader)
            if let count = metadata?.trackCount, count > 0 {
                tracksOut = (0..<count).map { idx in
                    TrackState(
                        id: idx,
                        name: "Track \(idx + 1)",
                        type: .unknown,
                        placeholder: true
                    )
                }
                source = cacheFetchedAt > .distantPast
                    ? "ax_live_with_file_count"
                    : "project_file"
            } else {
                source = "default"
            }
        }

        let body = encodeJSON(tracksOut)
        let json = wrapWithCacheEnvelope(
            bodyJSON: body,
            fetchedAt: cacheFetchedAt,
            axOccluded: axOccluded,
            extras: ["source": source]
        )
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    /// #200: an out-of-range / empty-state indexed-template read returns a typed,
    /// classifiable resource body (State C `index_out_of_range`) instead of a raw
    /// JSON-RPC `-32602`. `availableIndices` is the EXACT set of valid indices for
    /// the collection — `0..<count` for the positionally-indexed track list, but
    /// the actual `trackIndex` values for the mixer (whose strips are keyed by
    /// `trackIndex`, NOT array position, so a strip set can be non-contiguous,
    /// e.g. {0, 2, 4}). The hint therefore never asserts a contiguous `0..<N`
    /// range (which would mislead a client past a gap); it points at the parent
    /// collection and the body carries `available_indices` as the machine truth.
    static func indexOutOfRangeResult(
        uri: String,
        requestedIndex: Int,
        availableIndices: [Int],
        collection: String
    ) -> ReadResource.Result {
        let body = HonestContract.encodeStateC(
            error: .indexOutOfRange,
            hint: "No \(collection) at index \(requestedIndex); \(availableIndices.count) \(collection)(s) available. Read the parent collection resource for the current valid indices.",
            extras: [
                "uri": uri,
                "requested_index": requestedIndex,
                "available_count": availableIndices.count,
                "available_indices": availableIndices,
                "collection": collection,
            ]
        )
        return ReadResource.Result(
            contents: [.text(body, uri: uri, mimeType: "application/json")]
        )
    }

    static func readTrack(at index: Int, cache: StateCache, uri: String) async throws -> ReadResource.Result {
        if let track = await cache.getTrack(at: index) {
            let json = encodeJSON(track)
            return ReadResource.Result(
                contents: [.text(json, uri: uri, mimeType: "application/json")]
            )
        }
        // Tracks are positionally indexed (`getTrack(at:)` uses `tracks.indices`),
        // so the valid set is 0..<count.
        return indexOutOfRangeResult(
            uri: uri,
            requestedIndex: index,
            availableIndices: Array(0..<(await cache.getTracks().count)),
            collection: "track"
        )
    }

    /// B1 (#11) — `data_source` for `logic://mixer` strips. Strip volume/pan
    /// come from two writers: the AX poller (`updateChannelStrips`, which
    /// advances `mixerFetchedAt`) and MCU echo (`updateFader`/`updatePan`,
    /// which does NOT). So this labels the *poll* freshness — the canonical
    /// "is the AX-derived strip array current?" signal — while the separate
    /// `mcu_*` triplet lets a verification harness reason about the MCU echo
    /// path independently. `.distantPast` means no successful mixer poll has
    /// happened (the AX poll requires the Mixer panel to be visible), so the
    /// honest label is `mixer_not_visible` rather than a false freshness claim.
    /// Threshold mirrors `readProjectInfo`'s 5s `ax_live` window.
    static func mixerDataSource(fetchedAt: Date, now: Date = Date(), freshThreshold: Double = 5.0) -> String {
        guard fetchedAt > .distantPast else { return "mixer_not_visible" }
        return now.timeIntervalSince(fetchedAt) <= freshThreshold ? "ax_poll" : "cache_stale"
    }

    static func readMixer(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let strips = await cache.getChannelStrips()
        let conn = await cache.getMCUConnection()
        let fetchedAt = await cache.getMixerFetchedAt()
        let axOccluded = await cache.getAXOccluded()
        let stripsJSON = encodeJSON(strips)
        let (age, iso) = cacheEnvelope(fetchedAt: fetchedAt)
        let agePart = (age as? Double).map { "\($0)" } ?? "null"
        let isoPart = (iso as? String).map { "\"\($0)\"" } ?? "null"
        // B1 (#11): provenance + MCU triplet so a duplicate-and-readback harness
        // can decide whether to trust the strips. `registered` is kept as a
        // one-release alias of `mcu_registered` for existing parsers.
        let dataSource = mixerDataSource(fetchedAt: fetchedAt)
        let ageMsPart = conn.lastFeedbackAgeMs().map { "\($0)" } ?? "null"
        let json = """
            {"cache_age_sec":\(agePart),"data_source":"\(dataSource)","fetched_at":\(isoPart),"ax_occluded":\(axOccluded),"mcu_connected":\(conn.isConnected),"mcu_registered":\(conn.registeredAsDevice),"mcu_last_feedback_age_ms":\(ageMsPart),"registered":\(conn.registeredAsDevice),"strips":\(stripsJSON)}
            """
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    /// v3.1.8 (Issue #7) — tier-merged project info read.
    ///
    /// Tier order:
    ///   1. Cache (live AX poll) — preferred when `lastUpdated > .distantPast`
    ///      (poller has written real data). Source: "ax_live" if recent
    ///      (< 5s), else "cache".
    ///   2. Live track cache — fills `trackCount` from the same trusted
    ///      cache used by `logic://tracks` when ProjectInfo itself is name-only
    ///      and file metadata has no positive count.
    ///   3. LogicProjectFileReader — reads MetaData.plist for tempo / tsig /
    ///      trackCount when live cache is at struct defaults. Source:
    ///      "project_file" + last_saved_age_sec extra.
    ///   4. Struct defaults (ProjectInfo()). Source: "default".
    ///
    /// **Critical**: this function is read-only — it MUST NOT call
    /// `cache.updateProject(...)`. The poller is the sole writer to cache
    /// for project state. Mixing file values into cache would poison live
    /// reads from other resource paths (cache is a shared mutable surface).
    static func readProjectInfo(
        cache: StateCache,
        uri: String,
        fileReader: LogicProjectFileReader.Runtime
    ) async throws -> ReadResource.Result {
        let snapshot = await cache.auditSnapshot()
        let cached = snapshot.project
        let projectFetchedAt = snapshot.projectFetchedAt
        let cachedTransport = snapshot.transport
        let cachedTracks = snapshot.tracks
        let tracksFetchedAt = snapshot.tracksFetchedAt
        // Cache is "fresh" if either (a) the poller has timestamped a write,
        // or (b) ProjectInfo's own lastUpdated is non-default. Either signal
        // means downstream consumers wrote real data.
        let cacheFresh = projectFetchedAt > .distantPast || cached.lastUpdated > .distantPast
        let transportFresh = cachedTransport.lastUpdated > .distantPast

        // Per-field merge (boomer P0): the existing AX `defaultGetProjectInfo`
        // populates ONLY `name` + `lastUpdated`; tempo / timeSignature /
        // trackCount stay at struct defaults (120, "4/4", 0). A whole-record
        // "cache fresh wins" rule would therefore mask the file's correct
        // values whenever the poller has run at least once. Instead, we:
        //   1. Start with cached values (preserves the AX-only `name`).
        //   2. Fill tempo/sample-rate from live transport when available.
        //   3. Fill trackCount from the trusted live track cache when
        //      ProjectInfo itself is still at its default count.
        //   4. Fill any remaining defaults from file metadata.
        //   5. `source` is "ax_live"/"cache" if any non-default field came
        //      from cache; otherwise "project_file"; otherwise "default".
        let metadata = await LogicProjectFileReader.read(runtime: fileReader)

        var info = cacheFresh ? cached : ProjectInfo()

        var fileContributed = false
        var cacheContributedLive = false
        let cachedProjectReferenceDate = [cached.lastUpdated, projectFetchedAt]
            .filter { $0 > .distantPast }
            .max()
        var cacheContributionDates: [Date] = []

        // tempo
        if cacheFresh && cached.tempo != 120.0 {
            cacheContributedLive = true
            if let date = cachedProjectReferenceDate { cacheContributionDates.append(date) }
        } else if transportFresh {
            info.tempo = cachedTransport.tempo
            cacheContributedLive = true
            cacheContributionDates.append(cachedTransport.lastUpdated)
        } else if let tempo = metadata?.tempo {
            info.tempo = tempo
            fileContributed = true
        }
        if transportFresh {
            info.sampleRate = cachedTransport.sampleRate
        }
        // timeSignature
        if cacheFresh && cached.timeSignature != "4/4" {
            cacheContributedLive = true
            if let date = cachedProjectReferenceDate { cacheContributionDates.append(date) }
        } else if let tsig = metadata?.timeSignatureString {
            info.timeSignature = tsig
            fileContributed = true
        }
        // trackCount
        if cacheFresh && cached.trackCount != 0 {
            cacheContributedLive = true
            if let date = cachedProjectReferenceDate { cacheContributionDates.append(date) }
        } else if let trackCount = trustedLiveTrackCount(cachedTracks, fetchedAt: tracksFetchedAt) {
            info.trackCount = trackCount
            cacheContributedLive = true
            cacheContributionDates.append(tracksFetchedAt)
        } else if let count = metadata?.trackCount, count > 0 {
            info.trackCount = count
            fileContributed = true
        }
        // filePath / name from cache wins; if cache empty, file supplies
        if !cacheFresh, let bp = metadata?.bundlePath {
            info.filePath = bp.path
            info.lastUpdated = metadata?.metadataMTime ?? .distantPast
        }

        var source: String
        var lastSavedAgeSec: Double?
        if !cacheFresh && !fileContributed && !cacheContributedLive {
            source = "default"
        } else if cacheContributedLive {
            // Cache supplied at least one real value — promote to ax_live/cache.
            let referenceDate = cacheContributionDates.max()
                ?? cachedProjectReferenceDate
                ?? .distantPast
            let age = Date().timeIntervalSince(referenceDate)
            source = age < 5 ? "ax_live" : "cache"
        } else if fileContributed {
            source = "project_file"
            if let mt = metadata?.metadataMTime {
                lastSavedAgeSec = max(0, Date().timeIntervalSince(mt))
            }
        } else {
            // Edge: cache fresh but every field is at default (e.g. project just
            // opened, AX poller wrote name="Untitled" only, file unreadable).
            source = "ax_live"
        }
        info.source = source
        info.lastSavedAgeSec = lastSavedAgeSec

        var extras: [String: Any] = ["source": source]
        if let age = lastSavedAgeSec { extras["last_saved_age_sec"] = age }

        let body = encodeJSON(info)
        let cacheReferenceDate = cacheContributionDates.max() ?? cachedProjectReferenceDate
        let envelope = wrapWithCacheEnvelope(
            bodyJSON: body,
            fetchedAt: (source == "ax_live" || source == "cache") ? cacheReferenceDate : nil,
            axOccluded: snapshot.axOccluded,
            extras: extras
        )
        return ReadResource.Result(
            contents: [.text(envelope, uri: uri, mimeType: "application/json")]
        )
    }

    private static func tracksAreInspectorContaminated(_ tracks: [TrackState]) -> Bool {
        tracks.count >= 3 && tracks.allSatisfy { $0.name.hasSuffix(":") }
    }

    private static func trustedLiveTrackCount(_ tracks: [TrackState], fetchedAt: Date) -> Int? {
        guard fetchedAt > .distantPast,
              !tracks.isEmpty,
              !tracksAreInspectorContaminated(tracks),
              tracks.allSatisfy({ $0.placeholder != true }) else {
            return nil
        }
        return tracks.count
    }

    static func readMIDIPorts(router: ChannelRouter, uri: String) async throws -> ReadResource.Result {
        let result = await router.route(operation: "midi.list_ports")
        let payload: String
        if result.isSuccess,
           let data = result.message.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            payload = result.message
        } else if result.isSuccess {
            payload = encodeJSON(["message": result.message])
        } else {
            payload = encodeJSON(["error": result.message])
        }
        return ReadResource.Result(
            contents: [.text(payload, uri: uri, mimeType: "application/json")]
        )
    }

    static func readProjectAudit(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let report = await ProjectSessionAudit.buildAudit(cache: cache)
        // Honest Contract: never emit a success-shaped body that is missing the
        // schema/read_only contract fields. On encode failure, fail loud.
        do {
            let json = try encodeJSONStrict(report, compact: true)
            return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
        } catch {
            throw MCPError.internalError("audit encode failed: \(error.localizedDescription)")
        }
    }

    static func readProjectCleanupPlan(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let report = await ProjectSessionAudit.buildCleanupPlan(cache: cache)
        do {
            let json = try encodeJSONStrict(report, compact: true)
            return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
        } catch {
            throw MCPError.internalError("cleanup_plan encode failed: \(error.localizedDescription)")
        }
    }

    static func readTrackRegions(
        at index: Int,
        cache: StateCache,
        router: ChannelRouter,
        uri: String
    ) async throws -> ReadResource.Result {
        // The regions read returns an empty array for an index with no regions —
        // already a classifiable empty-state — and its live-route "no JSON-RPC
        // response" hang is bounded by the resource-read deadline (#199), NOT by a
        // track-count short-circuit: the cache can hold regions for a track whose
        // header isn't in the track array, so track_count is not a reliable
        // existence proxy here.
        if case .success(let payload) = await router.route(operation: "region.get_regions"),
           let liveRegions = try? RegionInfo.decodeToolPayload(payload) {
            await cache.updateRegions(liveRegions.map { $0.asRegionState() })
        }
        let regions = await cache.getRegions().filter { $0.trackIndex == index }
        let json = encodeJSON(regions)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    static func readMixerStrip(at index: Int, cache: StateCache, uri: String) async throws -> ReadResource.Result {
        guard let strip = await cache.getChannelStrip(at: index) else {
            // Mixer strips are keyed by `trackIndex` (not array position), so the
            // valid set is the actual trackIndex values — possibly non-contiguous.
            return indexOutOfRangeResult(
                uri: uri,
                requestedIndex: index,
                availableIndices: await cache.getChannelStrips().map(\.trackIndex).sorted(),
                collection: "channel strip"
            )
        }
        // B2 (#11): give the single-strip read the same envelope + provenance as
        // logic://mixer, so a harness reading an individual strip gets the same
        // freshness signal instead of a bare, undated object.
        let fetchedAt = await cache.getMixerFetchedAt()
        let (age, iso) = cacheEnvelope(fetchedAt: fetchedAt)
        let agePart = (age as? Double).map { "\($0)" } ?? "null"
        let isoPart = (iso as? String).map { "\"\($0)\"" } ?? "null"
        let dataSource = mixerDataSource(fetchedAt: fetchedAt)
        let stripJSON = encodeJSON(strip)
        let json = """
            {"cache_age_sec":\(agePart),"data_source":"\(dataSource)","fetched_at":\(isoPart),"strip":\(stripJSON)}
            """
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    /// v3.1.8 (Issue #7) — markers wrapped in cache envelope with source attribution.
    /// Markers come from cache (populated by StatePoller's hardened AX walker).
    /// Source: "ax_live" if cache populated, "default" if empty/unread.
    /// `ax_occluded` flag in the envelope flags untrusted-empty (Logic UI focus
    /// stole AX away from the arrange area mid-poll).
    /// v3.2 — wire 형식 DTO. 도메인 `MarkerState` 의 `positionSource` (camelCase) →
    /// JSON `position_source` (snake_case) 변환 + derived `is_canonical` 추가.
    /// SRP — 도메인 model 과 wire schema 책임 분리.
    private struct MarkerWireDTO: Encodable {
        let id: Int
        let name: String
        let position: String
        let positionSource: PositionSource
        let isCanonical: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, position
            case positionSource = "position_source"
            case isCanonical = "is_canonical"
        }
    }

    /// Marker 배열을 wire JSON (snake_case `position_source` + derived
    /// `is_canonical`) 으로 직렬화한다.
    static func encodeMarkersWire(_ markers: [MarkerState]) -> String {
        let dtos = markers.map { m in
            MarkerWireDTO(
                id: m.id,
                name: m.name,
                position: m.position,
                positionSource: m.positionSource,
                isCanonical: m.positionSource.isCanonical
            )
        }
        return encodeJSON(dtos)
    }

    static func readMarkers(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let markers = await cache.getMarkers()
        let fetchedAt = await cache.getMarkersFetchedAt()
        let axOccluded = await cache.getAXOccluded()
        let body = encodeMarkersWire(markers)
        let source: String
        if !markers.isEmpty {
            source = "ax_live"
        } else if fetchedAt > .distantPast {
            // Poller has run, came up empty — could be no markers OR occluded.
            source = axOccluded ? "cache" : "ax_live"
        } else {
            source = "default"
        }
        let envelope = wrapWithCacheEnvelope(
            bodyJSON: body,
            fetchedAt: fetchedAt,
            axOccluded: axOccluded,
            extras: ["source": source]
        )
        return ReadResource.Result(
            contents: [.text(envelope, uri: uri, mimeType: "application/json")]
        )
    }

    /// Wire-format wrapper for `logic://mcu/state`. MCU LCD bytes can carry raw
    /// control characters straight from hardware SysEx decode; routing the
    /// payload through `JSONEncoder` guarantees RFC 8259-valid escaping for
    /// `\n`, `\r`, `\t`, and U+0000-U+001F — which a hand-rolled emitter missed
    /// and which could have produced unparseable JSON. The members are the
    /// Codable StateModels structs directly (audit P2 #25 — no hand-mapping).
    /// `encodeJSON` sorts keys, so the wire shape is byte-identical to the prior
    /// hand-mapped DTO (same field set, same custom date strategy).
    private struct MCUStateDTO: Encodable {
        let connection: MCUConnectionState
        let display: MCUDisplayState
    }

    static func readMCUState(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let conn = await cache.getMCUConnection()
        let display = await cache.getMCUDisplay()
        let dto = MCUStateDTO(connection: conn, display: display)
        let json = encodeJSON(dto, compact: true)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    static func readSystemHealth(
        cache: StateCache,
        router: ChannelRouter,
        uri: String
    ) async throws -> ReadResource.Result {
        // Delegate to SystemDispatcher for canonical source (PRD §4.3.2, T8 fix)
        let toolResult = await SystemDispatcher.handle(
            command: "health", params: [:], router: router, cache: cache
        )
        // Extract text from tool result
        let json: String
        if case .text(let text, _, _) = toolResult.content.first {
            json = text
        } else {
            json = "{}"
        }
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }
}
