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

        /// True while a mutating operation holds the server's mutation gate.
        ///
        /// `var` rather than `let` so the server can attach the live gate to whichever runtime it
        /// was handed, without every test that builds a runtime having to know the gate exists.
        /// Defaults to "no mutation in flight", which is the pre-existing behaviour.
        var mutationInFlight: @Sendable () -> Bool = { false }

        /// #1079 — what Logic's keyboard focus is right now, read through the same rule that keeps
        /// a synthetic key out of a text field (`AccessibilityChannel.readLogicKeyboardFocus`).
        /// The background loop yields its tick while this answers `.textEditing`; see
        /// `backgroundTickYields(to:)`. Defaults to "no text editing", the pre-existing behaviour,
        /// so a test runtime never reaches the live AX API by omission.
        let keyboardFocus: @Sendable () -> AccessibilityChannel.LogicKeyboardFocus

        /// Source-compatible init: if `sleep` isn't supplied, use
        /// `Task.sleep(nanoseconds:)` so existing callers (mostly tests that
        /// only override `hasVisibleWindow`) keep compiling without change.
        /// `dialogPresent` defaults to `{ false }` so existing tests behave
        /// identically to pre-v3.1.4 — they exercise the non-occluded path.
        /// `blockingDialogInfo` defaults to `{ nil }` so existing tests (which
        /// only override `hasVisibleWindow` / `dialogPresent`) behave exactly as
        /// before — they exercise the no-blocking-dialog path.
        /// `projectFileReader` is inert by default for the same reason: only
        /// the production poller should ask Logic for a live document path.
        init(
            hasVisibleWindow: @Sendable @escaping () -> Bool,
            dialogPresent: @Sendable @escaping () -> Bool = { false },
            sleep: @Sendable @escaping (UInt64) async throws -> Void = { ns in
                try await Task.sleep(nanoseconds: ns)
            },
            blockingDialogInfo: @Sendable @escaping () -> AXLogicProElements.BlockingDialogInfo? = { nil },
            projectFileReader: LogicProjectFileReader.Runtime = .unavailable,
            keyboardFocus: @Sendable @escaping () -> AccessibilityChannel.LogicKeyboardFocus = { .notTextEditing }
        ) {
            self.hasVisibleWindow = hasVisibleWindow
            self.dialogPresent = dialogPresent
            self.sleep = sleep
            self.blockingDialogInfo = blockingDialogInfo
            self.projectFileReader = projectFileReader
            self.keyboardFocus = keyboardFocus
        }

        /// The AX project reader supplies a title but cannot provide a trusted
        /// absolute bundle path.  This reader is the same validated
        /// current-document source used by `logic://project/info`; unlike the
        /// resource, the poller is allowed to persist it in the cache.
        let projectFileReader: LogicProjectFileReader.Runtime

        static let production = Runtime(
            hasVisibleWindow: { ProcessUtils.hasVisibleWindow() },
            dialogPresent: { AXLogicProElements.dialogPresent() },
            blockingDialogInfo: { AXLogicProElements.blockingDialogInfo() },
            projectFileReader: .production,
            keyboardFocus: { AccessibilityChannel.readLogicKeyboardFocus(runtime: .production) }
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
    /// Publishes the sections a cycle wrote. The closure it is given answers whether to stop before
    /// the next resource read; it answers false outside a background cycle. Returns false when it
    /// stopped before publishing everything (#1079 review R3).
    typealias PostPoll = @Sendable (
        _ cacheKeys: [ResourceCacheKey], _ stopBeforeNextRead: @escaping @Sendable () -> Bool
    ) async -> Bool
    private let postPoll: PostPoll
    private var pollingTask: Task<Void, Never>?
    /// #668 coalescing state. `cycleInProgress` is the mutual exclusion the `actor` keyword does
    /// not give across `await`; `waitingForNextCycle` holds callers that arrived mid-cycle and are
    /// owed reads taken after their own request.
    private var cycleInProgress = false
    private var waitingForNextCycle: [CheckedContinuation<Bool, Never>] = []
    /// Fresh acquisitions keep their request task/context; they are not a shared refresh Bool.
    private var populationWaiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    /// The handed-off drain, tracked rather than detached so `stop()` still means what it says.
    private var drainTask: Task<Void, Never>?
    /// Set the moment a stop begins. Cancelling the loop is not enough: a cycle owned by an
    /// external `refreshNow` keeps running, and when it ends it would hand off a fresh, uncancelled
    /// drain — starting AX work after `stop()` had already returned. This refuses new cycles and
    /// new drains instead of trying to chase them.
    private var stopped = false
    /// Parked `stop()` calls, waiting for a cycle they do not own to finish.
    private var quiesceWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        axChannel: AccessibilityChannel,
        cache: StateCache,
        runtime: Runtime = .production,
        postPoll: @escaping PostPoll = { _, _ in true }
    ) {
        self.axChannel = axChannel
        self.cache = cache
        self.runtime = runtime
        self.postPoll = postPoll
    }

    /// A publisher that cannot stop partway: it is given no stop check and always reports that it
    /// published everything. Kept for callers that only observe the call.
    init(
        axChannel: AccessibilityChannel,
        cache: StateCache,
        runtime: Runtime = .production,
        postPoll: @escaping @Sendable ([ResourceCacheKey]) async -> Void
    ) {
        self.init(axChannel: axChannel, cache: cache, runtime: runtime, postPoll: { keys, _ in
            await postPoll(keys)
            return true
        })
    }

    /// Start the background polling loop.
    func start() {
        stopped = false
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
        let task = pollingTask
        // Before anything else: no new cycle and no new drain may start from here on. Cancelling
        // the loop does not cover a cycle owned by an external `refreshNow`, and that cycle would
        // otherwise hand off a fresh drain -- uncancelled, because it did not exist when stop ran.
        stopped = true
        task?.cancel()
        pollingTask = nil
        // Wait for the cancelled task to complete its current cycle
        await task?.value
        // The drain runs as its own task so the caller that starts a cycle is not billed for
        // everyone else's; without awaiting it, AX polling outlives a `stop()` that documents
        // itself as waiting for the current cycle. Cancel first, or a steady stream of nudges
        // keeps the drain accepting batches and this await never returns.
        drainTask?.cancel()
        await drainTask?.value
        drainTask = nil
        // A cycle this poller does not own may still be in flight. `stopped` guarantees nothing
        // follows it, so this waits at most that one cycle -- which is exactly what this function
        // documents itself as waiting for.
        if cycleInProgress {
            await withCheckedContinuation { quiesceWaiters.append($0) }
        }
        Log.info("StatePoller stopped", subsystem: "poller")
    }

    func stopImmediately() {
        stopped = true
        pollingTask?.cancel()
        pollingTask = nil
        drainTask?.cancel()
        Log.info("StatePoller stop requested without awaiting current AX poll", subsystem: "poller")
    }

    /// Whether the poller is currently running.
    var isRunning: Bool {
        pollingTask != nil && pollingTask?.isCancelled == false
    }

    // MARK: - Poll loop

    /// Runs a poll cycle — or shares one — and reports whether the cache
    /// actually advanced: i.e. at least one section was written and `postPoll`
    /// fired for it, not merely whether this function returned. A poll that
    /// finds no visible window (below the miss threshold) or that backs off
    /// under an occluding dialog writes nothing and returns `false`; every
    /// caller that needs to know "did state move" (not "did I call
    /// refreshNow") must read this return value rather than assume a completed
    /// call means a write landed (#544 review).
    ///
    /// "or shares one" is #668 and is not a detail: a call arriving while a
    /// cycle is under way waits for the NEXT one and is served its result
    /// alongside everyone else who arrived in that window, so the returned
    /// answer may describe a cycle this call did not itself start. What it
    /// never describes is a cycle whose AX reads predate this call — see
    /// `runCoalescedCycle` for why that distinction is load-bearing.
    @discardableResult
    func refreshNow() async -> Bool {
        await runCoalescedCycle()
    }

    func acquireSessionPopulation(
        request: SessionPopulationObservation.Request, targetRegistry: TargetRegistry?
    ) async throws -> SessionPopulationObservation.Capture {
        try SessionPopulationObservation.requireOwnedAcquisition()
        guard await beginPopulationCycle() else {
            try SessionPopulationObservation.requireOwnedAcquisition()
            throw SessionPopulationObservation.AcquisitionError.pollerStopped
        }
        defer { handOffCycle() }
        let stop: @Sendable () -> Bool = {
            (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil
        }
        try SessionPopulationObservation.requireOwnedAcquisition()
        let before = await cache.captureBoundary(watching: SessionPopulationObservation.watchedSections)
        let navigationProject: TargetDescriptor?
        if request.allowUINavigation, let reference = request.projectRef, let targetRegistry {
            navigationProject = await targetRegistry.resolveCurrentProject(TargetReference(rawValue: reference))?.descriptor
        } else { navigationProject = nil }
        let population: SessionPopulationObservation.FreshPopulation
        if runtime.hasVisibleWindow() {
            let focus = runtime.keyboardFocus
            let guardian = AXHelpers.HelpReadGuard(stop: { stop() || Self.backgroundTickYields(to: focus()) })
            population = try await AXHelpers.HelpReadGuard.$current.withValue(guardian) {
                try await axChannel.readFreshSessionPopulation(
                    request: request, fileReader: runtime.projectFileReader,
                    navigationProject: navigationProject,
                    navigationReferenceIsCurrent: {
                        guard let reference = request.projectRef else { return true }
                        guard let navigationProject, let targetRegistry else { return false }
                        return await targetRegistry.resolveCurrentProject(TargetReference(rawValue: reference))?.descriptor == navigationProject
                    },
                    stoppingBeforeAXRead: { stop() || guardian.stopped },
                    stoppingWhen: { stop() || guardian.stopped || Self.backgroundTickYields(to: focus()) }
                )
            }
        } else {
            let now = Date()
            population = .init(project: nil, tracks: nil, strips: nil, fileTrackCount: nil,
                               beganAt: now, endedAt: now, stable: true)
        }
        do {
            try SessionPopulationObservation.requireOwnedAcquisition()
            guard let accepted = await cache.acceptFreshPopulation(population, ifCurrent: before, stoppingWhen: stop) else {
                try SessionPopulationObservation.requireOwnedAcquisition()
                throw SessionPopulationObservation.AcquisitionError.ownershipLost
            }
            let capture = await SessionPopulationObservation.capture(
                cache: cache, targetRegistry: targetRegistry, fileReader: runtime.projectFileReader,
                requestedProjectRef: request.projectRef, accepted: accepted, stoppingWhen: stop
            )
            try SessionPopulationObservation.requireOwnedAcquisition()
            return capture
        } catch {
            // Acquisition has already returned a UI receipt. Later refusal must retain
            // that observation, even when no capture can be accepted or published.
            throw SessionPopulationObservation.NavigationAcquisitionError(cause: error, effects: population.uiEffects)
        }
    }

    private func beginPopulationCycle() async -> Bool {
        if stopped || Task.isCancelled { return false }
        if !cycleInProgress { cycleInProgress = true; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if stopped || Task.isCancelled { continuation.resume(returning: false) }
                else { populationWaiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelPopulationWaiter(id) }
        }
    }

    private func cancelPopulationWaiter(_ id: UUID) {
        guard let index = populationWaiters.firstIndex(where: { $0.0 == id }) else { return }
        populationWaiters.remove(at: index).1.resume(returning: false)
    }

    /// Give a request-owned acquisition the next cycle before starting another refresh batch.
    private func handOffCycle() {
        if stopped {
            strandWaiters()
            let population = populationWaiters
            populationWaiters = []
            for waiter in population { waiter.1.resume(returning: false) }
            releaseCycle()
        } else if !populationWaiters.isEmpty {
            populationWaiters.removeFirst().1.resume(returning: true)
        } else if !waitingForNextCycle.isEmpty {
            drainTask = Task { await self.drainWaiters() }
        } else {
            releaseCycle()
        }
    }

    /// #668 — one poll cycle at a time, and callers that arrive during one share a single fresh
    /// cycle rather than each starting their own.
    ///
    /// `actor` does not provide this. Actors are re-entrant across `await`, and the poll body
    /// suspends on every AX read, so concurrent callers used to enter it together, all capture the
    /// same section version, and race their conditional writes. Measured: four concurrent nudges
    /// produced three refused writes and three wasted AX walks, deterministically.
    ///
    /// The subtle part is what a late caller is owed. It must NOT be served the in-flight cycle's
    /// result: that cycle's AX reads may predate the caller's request, so a caller that just wrote
    /// something — `refreshAfterWrite` on the saga path does exactly this — would be handed state
    /// from before its own write. Joining the in-flight cycle would reintroduce the staleness the
    /// compare-and-swap exists to prevent, only without the counter noticing.
    ///
    /// So arrivals queue for the NEXT cycle and share it. N concurrent callers cost at most two
    /// cycles instead of N, every caller's reads begin after its own request, and no two cycles
    /// overlap — which is also why poller-vs-poller `dropped_stale_writes` becomes unreachable
    /// here, this time by construction rather than by my assuming it.
    /// `yieldingToTextEditing` is the background loop's: its cycle stops at the next read once
    /// Logic's keyboard focus reads as text editing (`pollOnce`). A caller that queues behind a
    /// cycle is served by a cycle of its own, which never yields.
    private func runCoalescedCycle(yieldingToTextEditing: Bool = false) async -> Bool {
        // A stop is under way; starting a cycle now is the AX work that stop exists to end.
        if stopped { return false }
        if cycleInProgress {
            return await withCheckedContinuation { waitingForNextCycle.append($0) }
        }
        cycleInProgress = true
        let mine = await pollOnce(axChannel: axChannel, cache: cache, yieldingToTextEditing: yieldingToTextEditing)
        handOffCycle()
        return mine
    }

    /// Serves queued callers in batches: everyone who arrived during one cycle shares the next.
    /// Anyone arriving during THAT cycle forms the following batch, so arrivals never extend a
    /// cycle already under way, and the loop ends the moment a cycle finishes with nobody waiting.
    private func drainWaiters() async {
        // On every exit, not just the loop's: leaving `cycleInProgress` true would make every
        // later nudge queue behind a drain that is gone, and no suspension separates the loop's
        // emptiness check from this, so no arrival can be stranded by observing it true and then
        // finding nobody left to serve it.
        defer {
            if Task.isCancelled { strandWaiters() }
            handOffCycle()
        }
        while !waitingForNextCycle.isEmpty && populationWaiters.isEmpty {
            if stopped { break }
            // Cooperative cancellation, because without it this loop has no upper bound: it keeps
            // accepting new batches, and `refreshNow` stays callable after the loop task is gone,
            // so one nudge per cycle from any caller kept `stop()` awaiting this task forever.
            // Reproduced with fire-and-forget timed nudges -- the shape the 15 bootstrap callers
            // actually have -- where stop() had not returned after 20s and only returned once the
            // nudges ceased.
            if Task.isCancelled { break }
            let batch = waitingForNextCycle
            waitingForNextCycle = []
            let shared = await pollOnce(axChannel: axChannel, cache: cache, yieldingToTextEditing: false)
            for waiter in batch { waiter.resume(returning: shared) }
        }
    }

    /// Whoever is still queued is owed an answer, and the honest one is that the cache did not
    /// advance for them. Leaving them suspended would be the lost continuation this design is
    /// otherwise free of. Synchronous by construction: no arrival can slip between the snapshot
    /// and the resumes.
    private func strandWaiters() {
        let stranded = waitingForNextCycle
        waitingForNextCycle = []
        for waiter in stranded { waiter.resume(returning: false) }
    }

    /// Releases the cycle and wakes any `stop()` parked on it. Ordering matters: waiters are
    /// stranded first, so nobody is left queued against a flag that has just been released.
    private func releaseCycle() {
        cycleInProgress = false
        let parked = quiesceWaiters
        quiesceWaiters = []
        for waiter in parked { waiter.resume() }
    }

    private func pollLoop(axChannel: AccessibilityChannel, cache: StateCache) async {
        let intervalNs = ServerConfig.statePollingIntervalNs

        while !Task.isCancelled {
            // Through the same gate as `refreshNow` -- the scheduled cycle is what a nudge most
            // often collides with, since at the measured 12.6s median on a 74-track project the
            // loop is mid-cycle roughly 80% of the time -- but NEVER as a queued waiter.
            //
            // A waiter suspends in a continuation that cancellation cannot wake, so a queued loop
            // made `stopImmediately()` return and THEN have a whole AX cycle start, run purely to
            // service a loop that was already cancelled. The loop has no use for the
            // fresh-after-request guarantee anyway: it is a periodic refresh, not a caller with a
            // pending write. If a cycle is already under way, this tick is redundant -- skip it.
            //
            // No suspension separates this check from `runCoalescedCycle`'s own, so the loop
            // always takes the initiator path and can never become a waiter.
            // A foreground mutation is driving Logic's accessibility surface right now. That
            // surface answers one request at a time, so a poll cycle here does not merely delay
            // itself — it starves the operation the user is waiting on, and the operations carry
            // deadlines. Skip the tick; the next one is `intervalNs` away and the cache is
            // invalidated after the mutation regardless.
            //
            // #1079: the user is typing into a Logic text field (an inline track rename). With the
            // server connected and idle, the rename lost keyboard focus partway through and the
            // rest of the keystrokes reached Logic as key commands; with the process killed it did
            // not. Which read takes the focus is not measured; a cycle is AX walks plus an
            // `osascript` Apple Event, and none of it runs while the focus reads as text editing.
            // An explicit `refreshNow` is not gated: a caller asking is not the background loop.
            // Read last: it is itself an AX read, and while a mutation holds the surface even that
            // is one too many. Synchronous, so the invariant above — no suspension between this
            // check and `runCoalescedCycle`'s — still holds.
            if !cycleInProgress, !runtime.mutationInFlight(),
               !Self.backgroundTickYields(to: runtime.keyboardFocus()) {
                _ = await runCoalescedCycle(yieldingToTextEditing: true)
            }

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

    /// #1079 — whether the background loop gives up its tick for what Logic's keyboard focus is.
    ///
    /// Only text editing yields. `syntheticKeyFocusRefusal` also refuses on a modal dialog, but the
    /// poller must keep running under one: its cycle is what records the occlusion (`axOccluded`)
    /// and the blocking dialog's buttons that `logic://project/audit` reports. A text field inside
    /// a dialog that reads as the focused element yields like any other text field.
    ///
    /// An unreadable focus polls. That is not a claim that no text field is focused — a reading
    /// that failed says nothing either way. It is the cheaper wrong answer: polling is exactly the
    /// behaviour before #1079, while yielding would stop the loop for as long as the focus does not
    /// read, and it never reads while Logic is not running (no application root). The cycle that
    /// counts window misses and eventually reports the document closed would never run, so the
    /// cache would keep serving a document that is gone, with nothing to say it stopped.
    static func backgroundTickYields(to focus: AccessibilityChannel.LogicKeyboardFocus) -> Bool {
        switch focus {
        case .textEditing:
            return true
        case .notTextEditing, .unreadable:
            return false
        }
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
    ///
    /// It also publishes the sections a yielded cycle wrote (`yieldCycle`), which were held back.
    /// #1079 review R3: publishing reads resources back, so a background cycle asks the focus once
    /// more before it publishes and before each resource read. Editing at either point holds every
    /// key for the next whole cycle; a resource already published is not notified twice, since the
    /// notifier compares content. A refresh's cycle publishes whatever the focus reads.
    @discardableResult
    private func finishPoll(_ cacheKeys: [ResourceCacheKey], yieldingToTextEditing: Bool = false) async -> Bool {
        var publishing = keysHeldByAYield
        keysHeldByAYield = []
        for key in cacheKeys where !publishing.contains(key) { publishing.append(key) }
        guard !publishing.isEmpty else { return !cacheKeys.isEmpty }
        if backgroundCycleYields(yieldingToTextEditing) {
            keysHeldByAYield = publishing
            return !cacheKeys.isEmpty
        }
        let focus = runtime.keyboardFocus
        // Supplementary review S-01: a help read the guard refused stays refused. A focus that
        // reads as editing once and then does not read at all must not let a resource whose help
        // was refused be published, so the guard's latch counts as well as the latest reading.
        let guardian = AXHelpers.HelpReadGuard.current
        let stop: @Sendable () -> Bool
        if yieldingToTextEditing {
            stop = { guardian?.stopped == true || Self.backgroundTickYields(to: focus()) }
        } else {
            stop = { false }
        }
        let completed = await postPoll(publishing, stop)
        if !completed {
            for key in publishing where !keysHeldByAYield.contains(key) { keysHeldByAYield.append(key) }
        }
        return !cacheKeys.isEmpty
    }

    /// #1079 review R2: how a background cycle ends when it yields to text editing. Its sections
    /// are not published now, because publishing reads resources back -- the project path query,
    /// a live transport read -- and those are the reads the yield exists to hold off. They are
    /// held and published by the next cycle that reaches `finishPoll`. Whether the cache advanced
    /// is answered as `finishPoll` answers it.
    private func yieldCycle(_ cacheKeys: [ResourceCacheKey]) -> Bool {
        for key in cacheKeys where !keysHeldByAYield.contains(key) { keysHeldByAYield.append(key) }
        return !cacheKeys.isEmpty
    }

    /// #1079 review R1: the focus read at the top of a tick does not cover a user who starts an
    /// inline edit while a background cycle is already running, and a 74-track project's cycle was
    /// measured at a 12.6 s median. So a background cycle reads the focus again before each of its
    /// reads -- the project read, the document-path query, the track read, transport, mixer and
    /// markers -- and stops there, leaving the rest unread, once it reads as text editing. A read
    /// already under way runs to its end: the track walk is one AX call chain with no point to stop
    /// it at, so a rename opened during it waits for that one read, not for the cycle.
    private func backgroundCycleYields(_ yieldingToTextEditing: Bool) -> Bool {
        yieldingToTextEditing && Self.backgroundTickYields(to: runtime.keyboardFocus())
    }

    @discardableResult
    private func pollOnce(
        axChannel: AccessibilityChannel, cache: StateCache, yieldingToTextEditing: Bool
    ) async -> Bool {
        // #1079 after review R3: the checks between reads do not reach inside one. A background
        // cycle runs under a help-read guard, so an AXHelp read anywhere in it asks the focus
        // first, and a section whose read the guard cut short is discarded, not written.
        guard yieldingToTextEditing else {
            return await pollOnceReading(axChannel: axChannel, cache: cache, yieldingToTextEditing: false)
        }
        let focus = runtime.keyboardFocus
        let guardian = AXHelpers.HelpReadGuard(stop: { Self.backgroundTickYields(to: focus()) })
        return await AXHelpers.HelpReadGuard.$current.withValue(guardian) {
            await pollOnceReading(axChannel: axChannel, cache: cache, yieldingToTextEditing: true)
        }
    }

    /// A help read in this cycle was refused because text editing began: the section being read
    /// is missing some of its help, and the cycle ends without writing it.
    private static var helpReadsStopped: Bool { AXHelpers.HelpReadGuard.current?.stopped == true }

    private func pollOnceReading(
        axChannel: AccessibilityChannel, cache: StateCache, yieldingToTextEditing: Bool
    ) async -> Bool {
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
            return await finishPoll(cacheKeys, yieldingToTextEditing: yieldingToTextEditing)
        }
        consecutiveWindowMisses = 0
        // #432: sample the authoritative blocking-dialog signal once per
        // visible-window cycle and cache it, so the cache-only audit resource can
        // surface `export_blocked_by_modal_dialog`. A blocking modal is exactly
        // what makes the project/track polls below fail (they occlude the arrange
        // subtree), so we capture it here — before those polls — regardless of
        // their outcome. `nil` when no blocking dialog owns the Logic window.
        let blockingDialog = runtime.blockingDialogInfo()
        if Self.helpReadsStopped { return yieldCycle(cacheKeys) }
        await cache.updateBlockingDialogButtons(blockingDialog?.buttonTitles)

        if backgroundCycleYields(yieldingToTextEditing) { return yieldCycle(cacheKeys) }
        // #1079 review R3: set when the path query yields. The update returning false says only
        // that nothing was written, so the cycle reads this to end where the yield was decided
        // rather than asking the focus again, which may not read.
        var yieldedAtPathQuery = false
        let projectReady = await poll(
            operation: "project.get_info", label: "ProjectInfo",
            section: .project,
            axChannel: axChannel, cache: cache, as: ProjectInfo.self
        ) { cache, info, observed in
            var identityBacked = info
            if (identityBacked.filePath ?? "").isEmpty {
                // #1079 review R2: a yield here must not write the pathless info. The cache reads a
                // path that went missing as a different project and clears every section, so the
                // write is skipped and the cycle ends at the next check.
                if yieldingToTextEditing && Self.backgroundTickYields(to: runtime.keyboardFocus()) {
                    yieldedAtPathQuery = true
                    return false
                }
                if let metadata = await LogicProjectFileReader.read(runtime: runtime.projectFileReader) {
                    identityBacked.filePath = metadata.bundlePath.path
                }
            }
            return await cache.updateProject(identityBacked, ifCurrent: observed)
        }
        // #668: readability drives `hasDocument`; only an APPLIED write is reported as refreshed.
        if projectReady.applied { cacheKeys.append(.project) }
        if yieldedAtPathQuery || Self.helpReadsStopped { return yieldCycle(cacheKeys) }
        if backgroundCycleYields(yieldingToTextEditing) { return yieldCycle(cacheKeys) }
        let tracksReady: PollOutcome
        let tracksVersion = await cache.currentVersion(for: .tracks)
        // #1079: the track walk reads AXHelp of every header's elements, and that read ends an
        // inline rename (measured 2026-10-02). The background cycle's walk asks before each header.
        let trackRead: (states: [TrackState]?, yielded: Bool)
        if yieldingToTextEditing {
            let focus = runtime.keyboardFocus
            trackRead = await axChannel.readTrackStates(stoppingWhen: {
                Self.backgroundTickYields(to: focus())
            })
        } else {
            trackRead = (await axChannel.readTrackStates(), false)
        }
        if trackRead.yielded || Self.helpReadsStopped { return yieldCycle(cacheKeys) }
        if let tracks = trackRead.states {
            // The read succeeded, so tracks are readable regardless of what the write does. The
            // write outcome is a separate answer and has to come from the CAS, not be assumed:
            // this fast path bypasses `poll`, so it is the one place the old `_ =` discard could
            // survive the split, and it is the section most likely to lose a race on a large
            // project — exactly where a receipt claiming `refreshed: true` would be wrong.
            // `applyTracks`, not `updateTracks`: the answer must come from inside the cache.
            // Comparing revisions out here needs a second actor call, and another writer to this
            // section can advance it in that window and be credited to this poll.
            let applied = await cache.applyTracks(tracks, ifCurrent: tracksVersion)
            tracksReady = PollOutcome(readable: true, applied: applied)
        } else {
            tracksReady = await poll(
                operation: "track.get_tracks", label: "Track",
                section: .tracks,
                axChannel: axChannel, cache: cache, as: [TrackState].self
            ) { cache, tracks, observed in
                await cache.applyTracks(tracks, ifCurrent: observed)
            }
            if Self.helpReadsStopped { return yieldCycle(cacheKeys) }
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
                return await finishPoll(cacheKeys, yieldingToTextEditing: yieldingToTextEditing)
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
            return await finishPoll(cacheKeys, yieldingToTextEditing: yieldingToTextEditing)
        }

        if backgroundCycleYields(yieldingToTextEditing) { return yieldCycle(cacheKeys) }
        let transportReady = await poll(
            operation: "transport.get_state", label: "Transport",
            section: .transport,
            axChannel: axChannel, cache: cache, as: TransportState.self
        ) { cache, state, observed in
            await cache.updateTransport(state, ifCurrent: observed)
        }
        if Self.helpReadsStopped { return yieldCycle(cacheKeys) }
        if transportReady.applied { cacheKeys.append(.transport) }
        if backgroundCycleYields(yieldingToTextEditing) { return yieldCycle(cacheKeys) }
        let mixerVersion = await cache.currentVersion(for: .mixer)
        let focus = runtime.keyboardFocus
        let mixerRead = await axChannel.readMixerStates(stoppingWhen: {
            yieldingToTextEditing && Self.backgroundTickYields(to: focus())
        })
        if mixerRead.yielded || Self.helpReadsStopped { return yieldCycle(cacheKeys) }
        let mixerReady: PollOutcome
        if mixerRead.provided {
            if let states = mixerRead.states {
                mixerReady = PollOutcome(readable: true, applied: await cache.updateChannelStrips(states, ifCurrent: mixerVersion))
            } else { mixerReady = PollOutcome(readable: false, applied: false) }
        } else {
            mixerReady = await poll(
                operation: "mixer.get_state", label: "Mixer", section: .mixer,
                axChannel: axChannel, cache: cache, as: [ChannelStripState].self
            ) { cache, strips, observed in
                await cache.updateChannelStrips(strips, ifCurrent: observed)
            }
        }
        if Self.helpReadsStopped { return yieldCycle(cacheKeys) }
        if mixerReady.applied { cacheKeys.append(.mixer) }
        markerPollTick += 1
        if markerPollTick >= Self.markerPollInterval {
            if backgroundCycleYields(yieldingToTextEditing) { return yieldCycle(cacheKeys) }
            markerPollTick = 0
            let markersReady = await pollUnversioned(
                operation: "nav.get_markers", label: "Marker",
                axChannel: axChannel, cache: cache, as: [MarkerState].self
            ) { cache, markers in
                await cache.updateMarkers(markers)
            }
            if Self.helpReadsStopped { return yieldCycle(cacheKeys) }
            if markersReady {
                cacheKeys.append(.markers)
            } else {
                await cache.markMarkersUnreadable()
            }
        }
        return await finishPoll(cacheKeys, yieldingToTextEditing: yieldingToTextEditing)
    }

    /// 3 consecutive misses (~9s at the 3s poll interval) before declaring
    /// the document closed. Anything shorter caused resource reads to flap
    /// "no document open" during normal Logic UI transitions.
    private static let failureThreshold = 3
    private static let markerPollInterval = 5
    private var consecutiveWindowMisses = 0
    private var consecutivePollMisses = 0
    private var markerPollTick = 4
    /// Sections a yielded cycle wrote and has not yet published (`yieldCycle`).
    private var keysHeldByAYield: [ResourceCacheKey] = []

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
        // A read the help-read guard cut short is not written (`pollOnce`).
        if Self.helpReadsStopped { return .unreadable }
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
            // "The CAS accepted" is not "the cache advanced", and the receipt claims the second.
            // `updateTracks` absorbs the first two empty reads under an occluding dialog and
            // returns without touching tracks, timestamp, or revision -- while the conditional
            // wrapper still reports true. That `true` reached `refresh_cache`'s `refreshed`.
            //
            // Comparing the revision closes it: acceptance means the section was still at
            // `observed`, so any advance from there is ours, and no advance means nothing landed.
            // The closure is what knows whether the cache advanced, and it answers atomically
            // inside the cache actor. Reading the revision here instead would leave a window for
            // another writer to advance the section and be credited to this poll.
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
        if Self.helpReadsStopped { return false }
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
