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
        /// #432 — authoritative blocking-dialog signal: the post-classifier
        /// `AXLogicProElements.blockingDialogInfo()` (excludes plugin-editor /
        /// Smart-Controls / keyboard-layout overlay windows) that the transport
        /// preflight and the #431 tool audit fail closed on. Sampled once per
        /// visible-window poll and written to `StateCache.blockingDialogButtons`
        /// so the cache-only `logic://project/audit` resource surfaces the export
        /// blocker (`export_blocked_by_modal_dialog`) from the same source the
        /// tool uses — instead of a false green. Distinct from `dialogPresent`,
        /// which drives the coarser occlusion (`axOccluded`) lifecycle.
        let blockingDialogInfo: @Sendable () -> AXLogicProElements.BlockingDialogInfo?
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
        /// `blockingDialogInfo` defaults to `{ nil }` so existing tests (which
        /// only override `hasVisibleWindow` / `dialogPresent`) behave exactly as
        /// before — they exercise the no-blocking-dialog path.
        init(
            hasVisibleWindow: @Sendable @escaping () -> Bool,
            dialogPresent: @Sendable @escaping () -> Bool = { false },
            sleep: @Sendable @escaping (UInt64) async throws -> Void = { ns in
                try await Task.sleep(nanoseconds: ns)
            },
            blockingDialogInfo: @Sendable @escaping () -> AXLogicProElements.BlockingDialogInfo? = { nil }
        ) {
            self.hasVisibleWindow = hasVisibleWindow
            self.dialogPresent = dialogPresent
            self.sleep = sleep
            self.blockingDialogInfo = blockingDialogInfo
        }

        static let production = Runtime(
            hasVisibleWindow: { ProcessUtils.hasVisibleWindow() },
            dialogPresent: { AXLogicProElements.dialogPresent() },
            blockingDialogInfo: { AXLogicProElements.blockingDialogInfo() }
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
    private let postPoll: @Sendable ([ResourceCacheKey]) async -> Void
    private var pollingTask: Task<Void, Never>?

    init(
        axChannel: AccessibilityChannel,
        cache: StateCache,
        runtime: Runtime = .production,
        postPoll: @escaping @Sendable ([ResourceCacheKey]) async -> Void = { _ in }
    ) {
        self.axChannel = axChannel
        self.cache = cache
        self.runtime = runtime
        self.postPoll = postPoll
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

    func stopImmediately() {
        guard let task = pollingTask else { return }
        task.cancel()
        pollingTask = nil
        Log.info("StatePoller stop requested without awaiting current AX poll", subsystem: "poller")
    }

    /// Whether the poller is currently running.
    var isRunning: Bool {
        pollingTask != nil && pollingTask?.isCancelled == false
    }

    // MARK: - Poll loop

    /// Runs one poll cycle and reports whether the cache actually advanced —
    /// i.e. at least one section was written and `postPoll` fired for it — not
    /// merely whether this function returned. A poll that finds no visible
    /// window (below the miss threshold) or that backs off under an occluding
    /// dialog writes nothing and returns `false`; every caller that needs to
    /// know "did state move" (not "did I call refreshNow") must read this
    /// return value rather than assume a completed call means a write landed
    /// (#544 review).
    @discardableResult
    func refreshNow() async -> Bool {
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

    /// What one section's poll answers. #668 — a single `Bool` could not distinguish "the value
    /// was readable" from "the write landed", and the refresh receipt was built from the first
    /// while claiming the second.
    struct PollOutcome: Sendable {
        /// The section produced a usable value. Drives `hasDocument` and occlusion logic, and
        /// stays true when the conditional write is refused.
        let readable: Bool
        /// The conditional write was accepted. Drives what the caller is told was refreshed.
        let applied: Bool

        static let unreadable = PollOutcome(readable: false, applied: false)
    }

    /// Emits `postPoll` iff this cycle touched at least one cache section, and
    /// reports that as the honest "did the cache advance" signal. A poll that
    /// returns having written nothing (window not visible below threshold,
    /// backing off under an occluding dialog) must report `false`, not merely
    /// "the function returned" (#544 review).
    @discardableResult
    private func finishPoll(_ cacheKeys: [ResourceCacheKey]) async -> Bool {
        guard !cacheKeys.isEmpty else { return false }
        await postPoll(cacheKeys)
        return true
    }

    @discardableResult
    private func pollOnce(axChannel: AccessibilityChannel, cache: StateCache) async -> Bool {
        var cacheKeys: [ResourceCacheKey] = []
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
                // #432: no Logic window ⇒ no blocking dialog can own it. This
                // branch returns before the per-cycle sample above runs, so clear
                // explicitly to avoid a stale positive after the window vanishes.
                await cache.updateBlockingDialogButtons(nil)
                cacheKeys.append(.document)
            }
            return await finishPoll(cacheKeys)
        }
        consecutiveWindowMisses = 0
        // #432: sample the authoritative blocking-dialog signal once per
        // visible-window cycle and cache it, so the cache-only audit resource can
        // surface `export_blocked_by_modal_dialog`. A blocking modal is exactly
        // what makes the project/track polls below fail (they occlude the arrange
        // subtree), so we capture it here — before those polls — regardless of
        // their outcome. `nil` when no blocking dialog owns the Logic window.
        await cache.updateBlockingDialogButtons(runtime.blockingDialogInfo()?.buttonTitles)

        let projectReady = await poll(
            operation: "project.get_info", label: "ProjectInfo",
            section: .project,
            axChannel: axChannel, cache: cache, as: ProjectInfo.self
        ) { cache, info, observed in
            await cache.updateProject(info, ifCurrent: observed)
        }
        // #668: readability drives `hasDocument`; only an APPLIED write is reported as refreshed.
        if projectReady.applied { cacheKeys.append(.project) }
        let tracksReady: PollOutcome
        let tracksVersion = await cache.currentVersion(for: .tracks)
        if let tracks = await axChannel.readTrackStates() {
            // Same reasoning as `poll`: the read succeeded, so tracks are readable. Whether this
            // particular value was applied or dropped in favour of a newer one does not change that.
            _ = await cache.updateTracks(tracks, ifCurrent: tracksVersion)
            tracksReady = PollOutcome(readable: true, applied: true)
        } else {
            tracksReady = await poll(
                operation: "track.get_tracks", label: "Track",
                section: .tracks,
                axChannel: axChannel, cache: cache, as: [TrackState].self
            ) { cache, tracks, observed in
                await cache.updateTracks(tracks, ifCurrent: observed)
            }
        }
        if tracksReady.applied { cacheKeys.append(.tracks) }
        // Deliberately `readable`, not `applied`: a refused write means the cache already holds
        // something newer, so the document is open. Using `applied` here would let lost races
        // make the poller declare the document closed — the bug the old comment guarded against.
        let hasDocument = projectReady.readable || tracksReady.readable
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
                return await finishPoll(cacheKeys)
            }
            consecutivePollMisses += 1
            if consecutivePollMisses >= Self.failureThreshold {
                await cache.updateDocumentState(false)
                await cache.updateAXOccluded(false)
                // #432: document confirmed closed ⇒ no blocking dialog owns it.
                await cache.updateBlockingDialogButtons(nil)
                cacheKeys.append(.document)
            }
        }

        guard hasDocument else {
            return await finishPoll(cacheKeys)
        }

        let transportReady = await poll(
            operation: "transport.get_state", label: "Transport",
            section: .transport,
            axChannel: axChannel, cache: cache, as: TransportState.self
        ) { cache, state, observed in
            await cache.updateTransport(state, ifCurrent: observed)
        }
        if transportReady.applied { cacheKeys.append(.transport) }
        let mixerReady = await poll(
            operation: "mixer.get_state", label: "Mixer",
            section: .mixer,
            axChannel: axChannel, cache: cache, as: [ChannelStripState].self
        ) { cache, strips, observed in
            await cache.updateChannelStrips(strips, ifCurrent: observed)
        }
        if mixerReady.applied { cacheKeys.append(.mixer) }
        markerPollTick += 1
        if markerPollTick >= Self.markerPollInterval {
            markerPollTick = 0
            let markersReady = await pollUnversioned(
                operation: "nav.get_markers", label: "Marker",
                axChannel: axChannel, cache: cache, as: [MarkerState].self
            ) { cache, markers in
                await cache.updateMarkers(markers)
            }
            if markersReady {
                cacheKeys.append(.markers)
            } else {
                await cache.markMarkersUnreadable()
            }
        }
        return await finishPoll(cacheKeys)
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

    /// Generic AX poll (replaces 5 near-identical poll* helpers). Executes
    /// `operation`, decodes the success payload as `T`, and hands it to
    /// `update` for caching. Returns true when a fresh value was decoded and
    /// cached; false on any AX failure or decode error (logged under `label`).
    /// `@discardableResult` so the transport/mixer/markers callers can ignore
    /// the readiness flag while project/tracks consume it.
    ///
    /// project.get_info note (v3.1.8, Issue #7): the AX path returns name-only
    /// ProjectInfo; the tempo / time-signature / track-count merge happens in
    /// `ResourceHandlers.readProjectInfo` against `MetaData.plist`.
    @discardableResult
    private func poll<T: Decodable & Sendable>(
        operation: String,
        label: String,
        section: CacheSectionID,
        axChannel: AccessibilityChannel,
        cache: StateCache,
        as type: T.Type,
        update: (StateCache, T, StateCache.SectionVersion) async -> Bool
    ) async -> PollOutcome {
        // This must happen before `execute`: observing after the AX read
        // returns would make a stale result look current and reintroduce the
        // overwrite race this guard is meant to prevent.
        let observed = await cache.currentVersion(for: section)
        let result = await axChannel.execute(operation: operation, params: [:])
        guard case .success(let json) = result else { return .unreadable }
        guard let data = json.data(using: .utf8) else { return .unreadable }
        do {
            let value = try Self.iso8601Decoder.decode(T.self, from: data)
            // Two different questions, and collapsing them into one Bool is #668.
            //
            // `readable` answers "does this section have a usable value". It must stay true when a
            // conditional write is REJECTED: a dropped write means the cache already holds
            // something newer, so the section is if anything more current than if we had applied
            // ours. Feeding the write outcome into `hasDocument` would let a few lost races make
            // the poller declare the document closed — a worse bug than the race it prevents.
            //
            // `applied` answers "did this write land", and that is what a refresh RECEIPT owes its
            // caller. Before this split, `refresh_cache` answered `refreshed: true` for a section
            // whose write had been refused, because the receipt was built from the readability
            // answer. The cache recorded the rejection all along — `droppedStaleWriteCount` — and
            // nothing on the receipt path consulted it.
            let applied = await update(cache, value, observed)
            return PollOutcome(readable: true, applied: applied)
        } catch {
            Log.debug("\(label) poll failed: \(error)", subsystem: "poller")
            return .unreadable
        }
    }

    /// Poll helper for cache values that do not have a `CacheSectionID` and
    /// therefore cannot participate in section-version rejection yet.
    @discardableResult
    private func pollUnversioned<T: Decodable & Sendable>(
        operation: String,
        label: String,
        axChannel: AccessibilityChannel,
        cache: StateCache,
        as type: T.Type,
        update: (StateCache, T) async -> Void
    ) async -> Bool {
        let result = await axChannel.execute(operation: operation, params: [:])
        guard case .success(let json) = result else { return false }
        guard let data = json.data(using: .utf8) else { return false }
        do {
            let value = try Self.iso8601Decoder.decode(T.self, from: data)
            await update(cache, value)
            return true
        } catch {
            Log.debug("\(label) poll failed: \(error)", subsystem: "poller")
            return false
        }
    }

}
