import Foundation

/// AX fallback poller.
///
/// Even when MCU feedback is unavailable, the MCP resources must still expose truthful
/// transport / project / track / mixer snapshots for single-machine use. This poller keeps
/// those cache surfaces warm from Accessibility so resources and name-based routing do not
/// degrade to empty state on non-MCU setups.
actor StatePoller {
    struct Runtime: Sendable {
        let hasVisibleWindow: @Sendable () -> Bool
        /// v3.1.4 (#4) — true when Logic currently has a modal dialog/sheet
        /// over the arrange (Bounce, file-open panel, tempo alert, save sheet)
        /// or when AX focus has been pulled away from the arrange window
        /// (typically by a plugin window grabbing focus). When this returns
        /// true the AX-driven `project.get_info` / `track.get_tracks` walks
        /// can transiently fail even though Logic's document is still open;
        /// the poll cycle treats those failures as occlusion (preserve cache,
        /// don't tick toward `hasDocument=false`) instead of as document
        /// closure. Production wires this to `AXLogicProElements.dialogPresent`,
        /// which already covers AXDialog/AXSystemDialog subroles. Plugin
        /// floating windows are observationally equivalent: while focused,
        /// the arrange-window AX subtree can return empty, so `pollOnce`
        /// also flags the corresponding cache state via `axOccluded`.
        let dialogPresent: @Sendable () -> Bool
        /// Inter-poll sleep. Injectable so tests can drive the loop at
        /// microsecond cadence instead of waiting out the production 3s
        /// interval — the original reason both lifecycle tests took
        /// ~2000 seconds to run.
        let sleep: @Sendable (UInt64) async throws -> Void

        /// Source-compatible init: if `sleep` isn't supplied, use
        /// `Task.sleep(nanoseconds:)` so existing callers (mostly tests that
        /// only override `hasVisibleWindow`) keep compiling without change.
        /// `dialogPresent` defaults to `{ false }` so existing tests behave
        /// identically to pre-v3.1.4 — they exercise the non-occluded path.
        init(
            hasVisibleWindow: @Sendable @escaping () -> Bool,
            dialogPresent: @Sendable @escaping () -> Bool = { false },
            sleep: @Sendable @escaping (UInt64) async throws -> Void = { ns in
                try await Task.sleep(nanoseconds: ns)
            }
        ) {
            self.hasVisibleWindow = hasVisibleWindow
            self.dialogPresent = dialogPresent
            self.sleep = sleep
        }

        static let production = Runtime(
            hasVisibleWindow: { ProcessUtils.hasVisibleWindow() },
            dialogPresent: { AXLogicProElements.dialogPresent() }
        )

        /// Test-friendly runtime for lifecycle-only coverage. Short-circuits
        /// the poll cycle by reporting no visible window — the real
        /// `AccessibilityChannel.execute(...)` calls hang in a CLI test
        /// without a running NSRunLoop, so tests that only verify start/stop
        /// state-machine behavior use this runtime to skip AX entirely.
        /// Combined with a 1 µs `sleep`, the loop cycles at microsecond
        /// cadence while touching no AX surface.
        static let fastTest = Runtime(
            hasVisibleWindow: { false },
            dialogPresent: { false },
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000) }  // 1 µs
        )
    }

    // Note: Kept as "StatePoller" for backward compatibility with LogicProServer.
    private let axChannel: AccessibilityChannel
    private let cache: StateCache
    private let runtime: Runtime
    private var pollingTask: Task<Void, Never>?

    init(axChannel: AccessibilityChannel, cache: StateCache, runtime: Runtime = .production) {
        self.axChannel = axChannel
        self.cache = cache
        self.runtime = runtime
    }

    /// Start the background polling loop.
    func start() {
        guard pollingTask == nil else {
            Log.warn("StatePoller already running", subsystem: "poller")
            return
        }
        pollingTask = Task { [axChannel, cache] in
            Log.info("StatePoller started", subsystem: "poller")
            await pollLoop(axChannel: axChannel, cache: cache)
        }
    }

    /// Stop the polling loop and wait for the current poll cycle to finish.
    func stop() async {
        guard let task = pollingTask else { return }
        task.cancel()
        pollingTask = nil
        // Wait for the cancelled task to complete its current cycle
        await task.value
        Log.info("StatePoller stopped", subsystem: "poller")
    }

    /// Whether the poller is currently running.
    var isRunning: Bool {
        pollingTask != nil && pollingTask?.isCancelled == false
    }

    // MARK: - Poll loop

    func refreshNow() async {
        await pollOnce(axChannel: axChannel, cache: cache)
    }

    private func pollLoop(axChannel: AccessibilityChannel, cache: StateCache) async {
        let intervalNs = ServerConfig.statePollingIntervalNs

        while !Task.isCancelled {
            await pollOnce(axChannel: axChannel, cache: cache)

            do {
                // Route through runtime.sleep so tests can drive this loop at
                // sub-millisecond cadence. CancellationError breaks the loop
                // identically to the direct Task.sleep path.
                try await runtime.sleep(intervalNs)
            } catch {
                break
            }
        }

        Log.info("AX Supplementary Poller loop exited", subsystem: "poller")
    }

    private func pollOnce(axChannel: AccessibilityChannel, cache: StateCache) async {
        guard runtime.hasVisibleWindow() else {
            // Be conservative: a single missed window check is often a transient
            // AX query glitch (Logic mid-paint, plugin window briefly grabbing
            // focus). Only flip hasDocument=false after `failureThreshold`
            // consecutive misses so resource reads don't error during the
            // transient window.
            consecutiveWindowMisses += 1
            if consecutiveWindowMisses >= Self.failureThreshold {
                await cache.updateDocumentState(false)
                await cache.updateAXOccluded(false)
            }
            return
        }
        consecutiveWindowMisses = 0

        let projectReady = await pollProjectInfo(axChannel: axChannel, cache: cache)
        let tracksReady = await pollTracks(axChannel: axChannel, cache: cache)
        let hasDocument = projectReady || tracksReady
        if hasDocument {
            consecutivePollMisses = 0
            await cache.updateDocumentState(true)
            await cache.updateAXOccluded(false)
        } else {
            // v3.1.4 (#4) — silent-failure mode. When both `project.get_info`
            // and `track.get_tracks` fail while a Logic window is still
            // on-screen, distinguish "document genuinely closed" from
            // "AX subtree transiently occluded by a plugin window / modal
            // dialog grabbing focus". In the occluded case the StatePoller
            // used to hold `hasDocument=true` but tick `consecutivePollMisses`
            // toward 3, so resource reads served stale data for ~9s before
            // the cache was wrongly cleared. With `dialogPresent()==true`
            // we now: (a) skip the miss-counter increment so the cache is
            // never cleared mid-occlusion, and (b) tag the cache with
            // `axOccluded=true` so downstream readers (resource envelope
            // wiring tracked separately) can surface a stale-by-occlusion
            // signal instead of silently returning prior values.
            if runtime.dialogPresent() {
                await cache.updateAXOccluded(true)
                // Preserve cache: do NOT increment consecutivePollMisses,
                // do NOT clear hasDocument. fetchedAt timestamps continue
                // ageing so `cache_age_sec` keeps growing — clients that
                // treat freshness as a contract still see staleness.
                return
            }
            consecutivePollMisses += 1
            if consecutivePollMisses >= Self.failureThreshold {
                await cache.updateDocumentState(false)
                await cache.updateAXOccluded(false)
            }
        }

        guard hasDocument else { return }

        await pollTransport(axChannel: axChannel, cache: cache)
        await pollMixer(axChannel: axChannel, cache: cache)
        markerPollTick += 1
        if markerPollTick >= Self.markerPollInterval {
            markerPollTick = 0
            await pollMarkers(axChannel: axChannel, cache: cache)
        }
    }

    /// 3 consecutive misses (~9s at the 3s poll interval) before declaring
    /// the document closed. Anything shorter caused resource reads to flap
    /// "no document open" during normal Logic UI transitions.
    private static let failureThreshold = 3
    private static let markerPollInterval = 5
    private var consecutiveWindowMisses = 0
    private var consecutivePollMisses = 0
    private var markerPollTick = 4

    private static let iso8601Decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func pollProjectInfo(axChannel: AccessibilityChannel, cache: StateCache) async -> Bool {
        // v3.1.5 (Issue #4) — pass cached transport tempo and track count
        // as a defensive fallback for older Logic builds whose AppleScript
        // dictionary may not expose `tempo` / `time signature` reliably.
        let transport = await cache.getTransport()
        let trackCount = await cache.getTracks().count
        let result = await axChannel.execute(operation: "project.get_info", params: [
            "cached_tempo": String(transport.tempo),
            "cached_track_count": String(trackCount),
        ])
        guard case .success(let json) = result else { return false }
        guard let data = json.data(using: .utf8) else { return false }
        do {
            let info = try Self.iso8601Decoder.decode(ProjectInfo.self, from: data)
            await cache.updateProject(info)
            return true
        } catch {
            Log.debug("ProjectInfo poll failed: \(error)", subsystem: "poller")
            return false
        }
    }

    private func pollTransport(axChannel: AccessibilityChannel, cache: StateCache) async {
        let result = await axChannel.execute(operation: "transport.get_state", params: [:])
        guard case .success(let json) = result else { return }
        guard let data = json.data(using: .utf8) else { return }
        do {
            let state = try Self.iso8601Decoder.decode(TransportState.self, from: data)
            await cache.updateTransport(state)
        } catch {
            Log.debug("Transport poll failed: \(error)", subsystem: "poller")
        }
    }

    private func pollTracks(axChannel: AccessibilityChannel, cache: StateCache) async -> Bool {
        let result = await axChannel.execute(operation: "track.get_tracks", params: [:])
        guard case .success(let json) = result else { return false }
        guard let data = json.data(using: .utf8) else { return false }
        do {
            let tracks = try Self.iso8601Decoder.decode([TrackState].self, from: data)
            await cache.updateTracks(tracks)
            return true
        } catch {
            Log.debug("Track poll failed: \(error)", subsystem: "poller")
            return false
        }
    }

    private func pollMixer(axChannel: AccessibilityChannel, cache: StateCache) async {
        let result = await axChannel.execute(operation: "mixer.get_state", params: [:])
        guard case .success(let json) = result else { return }
        guard let data = json.data(using: .utf8) else { return }
        do {
            let strips = try Self.iso8601Decoder.decode([ChannelStripState].self, from: data)
            await cache.updateChannelStrips(strips)
        } catch {
            Log.debug("Mixer poll failed: \(error)", subsystem: "poller")
        }
    }

    private func pollMarkers(axChannel: AccessibilityChannel, cache: StateCache) async {
        let result = await axChannel.execute(operation: "nav.get_markers", params: [:])
        guard case .success(let json) = result else { return }
        guard let data = json.data(using: .utf8) else { return }
        do {
            let markers = try Self.iso8601Decoder.decode([MarkerState].self, from: data)
            await cache.updateMarkers(markers)
        } catch {
            Log.debug("Marker poll failed: \(error)", subsystem: "poller")
        }
    }

}
