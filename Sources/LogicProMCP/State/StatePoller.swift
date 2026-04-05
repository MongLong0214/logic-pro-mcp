import Foundation

/// AX Supplementary Poller — reads Region/Marker/ProjectInfo via Accessibility channel.
/// MCU feedback handles transport/tracks/mixer state (event-driven).
/// This poller runs at a fixed 5-second interval for data MCU doesn't cover.
actor StatePoller {
    // Note: Kept as "StatePoller" for backward compatibility with LogicProServer.
    // Internally operates as AX supplementary poller only.
    private let axChannel: AccessibilityChannel
    private let cache: StateCache
    private var pollingTask: Task<Void, Never>?

    init(axChannel: AccessibilityChannel, cache: StateCache) {
        self.axChannel = axChannel
        self.cache = cache
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

    /// Stop the polling loop.
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        Log.info("StatePoller stopped", subsystem: "poller")
    }

    /// Whether the poller is currently running.
    var isRunning: Bool {
        pollingTask != nil && pollingTask?.isCancelled == false
    }

    // MARK: - Poll loop

    private func pollLoop(axChannel: AccessibilityChannel, cache: StateCache) async {
        // AX Supplementary Poller: fixed 5-second interval.
        // Transport/tracks/mixer state is handled by MCU feedback (event-driven).
        // This poller only reads data MCU doesn't cover: regions, markers, project info.
        let intervalNs: UInt64 = 5_000_000_000 // 5 seconds

        while !Task.isCancelled {
            // Poll supplementary data only (regions, markers, project info)
            await pollProjectInfo(axChannel: axChannel, cache: cache)

            do {
                try await Task.sleep(nanoseconds: intervalNs)
            } catch {
                break
            }
        }

        Log.info("AX Supplementary Poller loop exited", subsystem: "poller")
    }

    private func pollProjectInfo(axChannel: AccessibilityChannel, cache: StateCache) async {
        let result = await axChannel.execute(operation: "project.get_info", params: [:])
        guard case .success(let json) = result else { return }
        guard let data = json.data(using: .utf8) else { return }
        do {
            let info = try JSONDecoder().decode(ProjectInfo.self, from: data)
            await cache.updateProject(info)
        } catch {
            Log.debug("ProjectInfo poll failed: \(error)", subsystem: "poller")
        }
    }

}
