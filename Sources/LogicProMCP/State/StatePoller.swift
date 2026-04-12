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

        static let production = Runtime(
            hasVisibleWindow: { ProcessUtils.hasVisibleWindow() }
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
                try await Task.sleep(nanoseconds: intervalNs)
            } catch {
                break
            }
        }

        Log.info("AX Supplementary Poller loop exited", subsystem: "poller")
    }

    private func pollOnce(axChannel: AccessibilityChannel, cache: StateCache) async {
        guard runtime.hasVisibleWindow() else {
            await cache.updateDocumentState(false)
            return
        }

        let projectReady = await pollProjectInfo(axChannel: axChannel, cache: cache)
        let tracksReady = await pollTracks(axChannel: axChannel, cache: cache)
        let hasDocument = projectReady || tracksReady
        await cache.updateDocumentState(hasDocument)

        guard hasDocument else { return }

        await pollTransport(axChannel: axChannel, cache: cache)
        await pollMixer(axChannel: axChannel, cache: cache)
    }

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

}
