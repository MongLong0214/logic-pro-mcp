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
        /// Inter-poll sleep. Injectable so tests can drive the loop at
        /// microsecond cadence instead of waiting out the production 3s
        /// interval — the original reason both lifecycle tests took
        /// ~2000 seconds to run.
        let sleep: @Sendable (UInt64) async throws -> Void

        /// Source-compatible init: if `sleep` isn't supplied, use
        /// `Task.sleep(nanoseconds:)` so existing callers (mostly tests that
        /// only override `hasVisibleWindow`) keep compiling without change.
        init(
            hasVisibleWindow: @Sendable @escaping () -> Bool,
            sleep: @Sendable @escaping (UInt64) async throws -> Void = { ns in
                try await Task.sleep(nanoseconds: ns)
            }
        ) {
            self.hasVisibleWindow = hasVisibleWindow
            self.sleep = sleep
        }

        static let production = Runtime(
            hasVisibleWindow: { ProcessUtils.hasVisibleWindow() }
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
        } else {
            consecutivePollMisses += 1
            if consecutivePollMisses >= Self.failureThreshold {
                await cache.updateDocumentState(false)
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
        let result = await axChannel.execute(operation: "project.get_info", params: [:])
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
