import Foundation

/// Protocol for MCU MIDI transport — abstracted for testing.
protocol MCUTransportProtocol: Actor {
    func send(_ bytes: [UInt8]) async
    func start(onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void) async throws
    func start(
        onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void,
        onIngressDrop: @escaping @Sendable (UInt64) -> Void
    ) async throws
    func start(
        onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void,
        onIngressDrop: @escaping @Sendable (UInt64) -> Void,
        onCallbackWorkBudgetDrop: @escaping @Sendable (UInt64) -> Void
    ) async throws
    func endpointCensus() async -> VirtualMIDIEndpointCensus
    func stop() async
}

extension MCUTransportProtocol {
    /// Test and non-CoreMIDI transports do not need a packet-structure budget;
    /// they retain the original receive-only contract. Production overrides this
    /// to report a CoreMIDI callback budget violation without awaiting an actor.
    func start(
        onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void,
        onIngressDrop: @escaping @Sendable (UInt64) -> Void
    ) async throws {
        _ = onIngressDrop
        try await start(onReceive: onReceive)
    }

    /// A valid event list can exceed one callback's bounded work budget. That
    /// is lossy and must be reported, but unlike malformed packet structure it
    /// must not finish the MCU ingress. Test transports retain their original
    /// two-sink implementation unless they need to model this distinction.
    func start(
        onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void,
        onIngressDrop: @escaping @Sendable (UInt64) -> Void,
        onCallbackWorkBudgetDrop: @escaping @Sendable (UInt64) -> Void
    ) async throws {
        _ = onCallbackWorkBudgetDrop
        try await start(onReceive: onReceive, onIngressDrop: onIngressDrop)
    }

    /// Non-CoreMIDI test transports have no endpoint catalog to inspect.
    func endpointCensus() async -> VirtualMIDIEndpointCensus { .none }
}

/// Snapshot of the MCU callback-to-actor hand-off.
///
/// The value is intentionally small and independent of `StateCache`: the
/// CoreMIDI callback must be able to reject an overload without awaiting an
/// actor or touching a JSON-RPC-owned queue.
struct MCUFeedbackIngressSnapshot: Sendable, Equatable {
    /// Every parsed or declared event that could not reach the ingress.
    let droppedEventCount: UInt64
    /// Subset of `droppedEventCount` omitted solely to keep one CoreMIDI
    /// callback bounded. This is observable but not fatal to the channel.
    let callbackWorkBudgetDroppedEventCount: UInt64
    let overflowed: Bool

    static let empty = MCUFeedbackIngressSnapshot(
        droppedEventCount: 0,
        callbackWorkBudgetDroppedEventCount: 0,
        overflowed: false
    )
}

/// Bounded, callback-safe ingress for MCU feedback.
///
/// `AsyncStream.Continuation.yield` is thread safe and returns immediately.
/// That makes this safe to call from CoreMIDI's receive thread, unlike awaiting
/// an actor or dispatching synchronously back to one.  The stream is bounded:
/// after its first overflow it is finished, making the MCU channel fail closed
/// rather than letting a malformed or runaway feedback source grow memory
/// without limit.  The drop count is surfaced by `MCUChannel.healthCheck()`.
final class MCUFeedbackIngress: @unchecked Sendable {
    private enum State {
        case active
        case overflowed
        case stopped
    }

    let stream: AsyncStream<MIDIFeedback.Event>
    private let continuation: AsyncStream<MIDIFeedback.Event>.Continuation
    private let lock = NSLock()
    private var state: State = .active
    private var droppedEventCount: UInt64 = 0
    private var callbackWorkBudgetDroppedEventCount: UInt64 = 0

    init(capacity: Int = 256) {
        let (stream, continuation) = AsyncStream<MIDIFeedback.Event>.makeStream(
            bufferingPolicy: .bufferingNewest(capacity)
        )
        self.stream = stream
        self.continuation = continuation
    }

    /// Enqueue one parsed event without suspension. Once full, finish the
    /// ingress so the MCU channel cannot continue from a lossy state.
    func yield(_ event: MIDIFeedback.Event) {
        switch continuation.yield(event) {
        case .enqueued:
            break
        case .dropped:
            recordDrop(count: 1)
        case .terminated:
            // A stream terminated by its first overflow has already rejected
            // this event. Count it too; otherwise every later callback event
            // disappears from the health total.
            recordDrop(count: 1)
        @unknown default:
            recordDrop(count: 1)
        }
    }

    /// Called for malformed ingress or a bounded-stream overflow. These are
    /// fatal because continuing would either traverse untrusted packet memory
    /// or silently run a lossy feedback channel.
    func recordDrop(count: UInt64) {
        guard count > 0 else { return }
        lock.lock()
        let shouldFinish = state == .active
        if shouldFinish {
            state = .overflowed
        }
        if state == .overflowed {
            droppedEventCount &+= count
        }
        lock.unlock()
        if shouldFinish {
            continuation.finish()
        }
    }

    /// Record events omitted only because a valid CoreMIDI list exceeded this
    /// callback's work allowance. The callback still processes its bounded
    /// prefix and the ingress stays active for later callbacks.
    func recordCallbackWorkBudgetDrop(count: UInt64) {
        guard count > 0 else { return }
        lock.lock()
        if state != .stopped {
            droppedEventCount &+= count
            callbackWorkBudgetDroppedEventCount &+= count
        }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        if state == .active {
            state = .stopped
        }
        lock.unlock()
        continuation.finish()
    }

    func snapshot() -> MCUFeedbackIngressSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return MCUFeedbackIngressSnapshot(
            droppedEventCount: droppedEventCount,
            callbackWorkBudgetDroppedEventCount: callbackWorkBudgetDroppedEventCount,
            overflowed: state == .overflowed
        )
    }
}

/// MCU (Mackie Control Universal) channel for bidirectional Logic Pro control.
actor MCUChannel: Channel {
    nonisolated let id = ChannelID.mcu

    private struct ValidationFailure: Error {
        let hint: String
    }

    struct AXReadback: Sendable {
        let readVolume: @Sendable (Int) async -> Double?
        let readPan: @Sendable (Int) async -> Double?
        let readAutomationMode: @Sendable (Int) async -> AutomationMode?
        let readSelectedTrack: @Sendable () async -> Int?
        /// Whether a track's Mute / Solo / Record button reads as on in its AX track header
        /// (#1020). The MCU strip buttons toggle, so `track.set_mute` / `set_solo` / `set_arm`
        /// compare against these before pressing. `nil` is "could not read" and is never taken
        /// for `false`: a press on an unread state is a write in an unknown direction.
        let readMuted: @Sendable (Int) async -> Bool?
        let readSoloed: @Sendable (Int) async -> Bool?
        let readArmed: @Sendable (Int) async -> Bool?

        init(
            readVolume: @escaping @Sendable (Int) async -> Double?,
            readPan: @escaping @Sendable (Int) async -> Double?,
            readAutomationMode: @escaping @Sendable (Int) async -> AutomationMode? = { _ in nil },
            readSelectedTrack: @escaping @Sendable () async -> Int? = { nil },
            readMuted: @escaping @Sendable (Int) async -> Bool? = { _ in nil },
            readSoloed: @escaping @Sendable (Int) async -> Bool? = { _ in nil },
            readArmed: @escaping @Sendable (Int) async -> Bool? = { _ in nil }
        ) {
            self.readVolume = readVolume
            self.readPan = readPan
            self.readAutomationMode = readAutomationMode
            self.readSelectedTrack = readSelectedTrack
            self.readMuted = readMuted
            self.readSoloed = readSoloed
            self.readArmed = readArmed
        }
    }

    private let transport: any MCUTransportProtocol
    private let cache: StateCache
    private let feedbackParser: MCUFeedbackParser
    private let axReadback: AXReadback?
    /// Every wait the bank-window path takes goes through here (#862). Production sleeps; a
    /// test injects a sleeper that returns at once and COUNTS the waits, because a bound on
    /// elapsed time measures the machine and a count of polls measures the code (#804).
    private let sleep: @Sendable (Duration) async -> Void
    private(set) var currentBank: Int = 0
    private var bankingQueue: [CheckedContinuation<Void, Never>] = []
    private var isBanking: Bool = false
    /// Set when a bank step moved the window but may have moved it fewer than eight strips — Logic
    /// stops the last bank at the last strip (#1020) — no probe proved it full
    /// (`probeAmbiguousRightStep`), and nothing has put it back on a multiple of
    /// eight since. While it is set and `currentBank` is not 0, no strip index can be trusted and
    /// `withBanking` refuses before sending anything. Cleared only by a `mixer.bank` left walk that
    /// ends on an unchanged redraw (Logic at its left end) with `currentBank` at 0.
    private var windowOffsetUnaligned = false

    // The CoreMIDI callback only calls `MCUFeedbackIngress.yield`, which is a
    // non-suspending bounded hand-off. A single task drains it in arrival order;
    // it never shares the stdio transport or the MCP Server actor.
    private var feedbackIngress: MCUFeedbackIngress?
    private var feedbackTask: Task<Void, Never>?

    // v3.1.0 (T4) — configurable echo-timeout for fader/V-Pot read-back.
    // MCU feedback timing varies by project load + Logic build; 500ms is
    // the empirical default. Override via `MCU_ECHO_TIMEOUT_MS` (250/500/1000).
    static var echoTimeoutMs: Int {
        if let s = ProcessInfo.processInfo.environment["MCU_ECHO_TIMEOUT_MS"],
           let n = Int(s), [250, 500, 1000].contains(n) {
            return n
        }
        return 500
    }

    // Note: verify-after-write was simplified to avoid actor deadlock.
    // Instead of blocking on feedback, we rely on MCUFeedbackParser updating
    // StateCache asynchronously. Callers check StateCache after a short delay if needed.

    init(
        transport: any MCUTransportProtocol,
        cache: StateCache,
        axReadback: AXReadback? = nil,
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.transport = transport
        self.cache = cache
        self.axReadback = axReadback
        self.sleep = sleep
        self.feedbackParser = MCUFeedbackParser(cache: cache)
    }

    /// v3.1.0 (T4) — poll StateCache for a matching fader echo. The MCU
    /// feedback parser writes to `cache.channelStrips[strip].volume` as
    /// pitch-bend events arrive. We poll every 25ms and accept the value if
    /// it lands within `tolerance` of `target` before `timeoutMs` elapses.
    /// The 14-bit MCU resolution tolerance is 2/16383 (±2 LSB) as the default.
    ///
    /// v3.1.0 (Ralph-2 / C1) — `requireFreshAfter`, when non-nil, requires
    /// the echo's write-timestamp (`cache.getFaderUpdatedAt(strip:)`) to be
    /// strictly newer than that deadline. This prevents a stale cache value
    /// left over from a previous confirmed `set_volume 0.5` from
    /// false-positively acknowledging a later `set_volume 0.5` against a
    /// disconnected transport.
    ///
    /// Returns the observed volume if a matching, fresh echo arrived, or nil
    /// on timeout / stale-only.
    func pollFaderEcho(
        strip: Int,
        target: Double,
        timeoutMs: Int,
        tolerance: Double = 2.0 / 16383.0,
        requireFreshAfter: Date? = nil
    ) async -> Double? {
        let pollIntervalNs: UInt64 = 25_000_000
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            // v3.4.5-rc5: read volume + timestamp
            // in a single actor turn. Two separate awaits left a TOCTOU
            // window where a concurrent `updateFader` could pair an old
            // value with a new timestamp and false-positive State A.
            let snapshot = await cache.getFaderEchoSnapshot(strip: strip)
            if let observed = snapshot.volume, abs(observed - target) <= tolerance {
                if let sendAt = requireFreshAfter {
                    if let writtenAt = snapshot.updatedAt, writtenAt > sendAt {
                        return observed
                    }
                    // Value matches but stale — keep polling until either a
                    // new echo arrives or the deadline elapses.
                } else {
                    return observed
                }
            }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }
        // Deadline hit. Re-snapshot atomically before deciding.
        let finalSnap = await cache.getFaderEchoSnapshot(strip: strip)
        if let sendAt = requireFreshAfter {
            if let writtenAt = finalSnap.updatedAt, writtenAt > sendAt {
                return finalSnap.volume
            }
            return nil
        }
        return finalSnap.volume
    }

    /// v3.1.3 (#1) — poll StateCache for a matching V-Pot pan echo. Mirrors
    /// `pollFaderEcho` but reads the LED-ring-derived pan written by
    /// `MCUFeedbackParser` on CC 0x30..0x37.
    ///
    /// `tolerance` is normalised to the [-1, +1] pan range. The MCU LED ring
    /// has 11 discrete positions across the full range (asymmetric: 6 left,
    /// 5 right). A single LED step is ~0.167 units on the left and ~0.2 on
    /// the right; we default to ±0.1 (≈ ±0.5 LED) which is tight enough to
    /// reject obvious mismatches but tolerant of the LED-ring quantisation.
    ///
    /// `requireFreshAfter`, when non-nil, demands the cache write timestamp
    /// (`cache.getPanUpdatedAt(strip:)`) be strictly newer than that deadline,
    /// so a previously-cached pan value cannot masquerade as a fresh echo on
    /// an identical-target re-send (same anti-stale guard as Ralph-2 / C1
    /// applied to `set_volume`).
    ///
    /// Returns the observed pan if a fresh matching echo arrived, or nil on
    /// timeout / stale-only.
    func pollPanEcho(
        strip: Int,
        target: Double,
        timeoutMs: Int,
        tolerance: Double = 0.1,
        requireFreshAfter: Date? = nil
    ) async -> Double? {
        let pollIntervalNs: UInt64 = 25_000_000
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            // v3.4.5-rc5: atomic (pan, updatedAt)
            // snapshot — same TOCTOU rationale as pollFaderEcho.
            let snapshot = await cache.getPanEchoSnapshot(strip: strip)
            if let observed = snapshot.pan, abs(observed - target) <= tolerance {
                if let sendAt = requireFreshAfter {
                    if let writtenAt = snapshot.updatedAt, writtenAt > sendAt {
                        return observed
                    }
                } else {
                    return observed
                }
            }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }
        // Deadline hit: re-snapshot atomically before deciding.
        let finalSnap = await cache.getPanEchoSnapshot(strip: strip)
        if let sendAt = requireFreshAfter {
            if let writtenAt = finalSnap.updatedAt, writtenAt > sendAt {
                return finalSnap.pan
            }
            return nil
        }
        return finalSnap.pan
    }

    func start() async throws {
        // Defensively tear down any prior session so start-stop-start (and an
        // accidental double-start) always runs on a fresh ordered stream.
        feedbackIngress?.finish()
        feedbackTask?.cancel()

        // Pass bank offset getter to feedback parser
        await feedbackParser.setBankOffsetProvider { [weak self] in
            await self?.currentBank ?? 0
        }

        let ingress = MCUFeedbackIngress()
        feedbackIngress = ingress
        feedbackTask = Task { [weak self] in
            for await event in ingress.stream {
                await self?.receiveFeedback(event)
            }
        }

        // The transport invokes this sink synchronously on its CoreMIDI receive
        // thread. `yield` neither awaits an actor nor waits for the consumer;
        // a malformed packet or ingress overflow records a fatal drop and
        // finishes the bounded ingress. A valid callback that exceeds its
        // work budget records the omitted suffix without killing MCU.
        do {
            try await transport.start(
                onReceive: { event in ingress.yield(event) },
                onIngressDrop: { count in ingress.recordDrop(count: count) },
                onCallbackWorkBudgetDrop: { count in ingress.recordCallbackWorkBudgetDrop(count: count) }
            )
        } catch {
            let census = await transport.endpointCensus()
            await cache.updateMCUConnection { conn in
                conn.isConnected = false
                conn.registeredAsDevice = false
                conn.lastFeedbackAt = nil
                conn.portName = "LogicProMCP-MCU-Internal"
                conn.portCensus = census
            }
            throw error
        }

        // Handshake: send Device Query
        let query = MCUProtocol.encodeDeviceQuery()
        await transport.send(query)

        let census = await transport.endpointCensus()
        await cache.updateMCUConnection { conn in
            conn.isConnected = false
            conn.registeredAsDevice = false
            conn.lastFeedbackAt = nil
            conn.portName = "LogicProMCP-MCU-Internal"
            conn.portCensus = census
        }

        Log.info("MCU Channel started, handshake query sent; waiting for feedback", subsystem: "mcu")
    }

    func stop() async {
        await transport.stop()
        // Tear down the ordered consumer. Finishing the continuation ends the
        // drain loop once its buffer empties; cancel() stops it promptly and
        // guarantees any feedback arriving after stop() is dropped, not
        // applied to the cache.
        feedbackIngress?.finish()
        feedbackTask?.cancel()
        feedbackIngress = nil
        feedbackTask = nil
        await cache.updateMCUConnection { conn in
            conn.isConnected = false
        }
        Log.info("MCU Channel stopped", subsystem: "mcu")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        switch operation {
        case "mixer.set_volume":
            return await executeSetVolume(params)
        case "mixer.set_pan":
            return await executeSetPan(params)
        case "mixer.set_master_volume":
            return await executeSetMasterVolume(params)
        case "mixer.bank":
            return await executeBank(params)
        case "mixer.set_send":
            return .error("MCU send targeting is not deterministic enough for the production MCP contract")
        case "transport.play":
            return await sendTransport(.play)
        case "transport.stop":
            return await sendTransport(.stop)
        case "transport.record":
            return await sendTransport(.record)
        case "transport.rewind":
            return await sendTransport(.rewind)
        case "transport.fast_forward":
            return await sendTransport(.fastForward)
        case "transport.toggle_cycle":
            return await sendTransport(.cycle)
        case "track.set_mute":
            return await executeStripButton(.mute, operation: operation, params: params)
        case "track.set_solo":
            return await executeStripButton(.solo, operation: operation, params: params)
        case "track.set_arm":
            return await executeStripButton(.recArm, operation: operation, params: params)
        case "track.select":
            return await executeStripButton(.select, operation: operation, params: params)
        case "mixer.set_plugin_param":
            return .error("Use plugin.set_param via the Scripter channel for deterministic plugin parameter control")
        case "track.set_automation":
            return await executeAutomation(params)
        default:
            return .error("Unknown MCU operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        // Health is a read-time CoreMIDI observation. Do not republish the
        // startup census as though it still described current endpoint state.
        let census = await transport.endpointCensus()
        await cache.updateMCUConnection { conn in
            conn.portCensus = census
        }
        let ingress = feedbackIngress?.snapshot() ?? .empty
        if ingress.overflowed {
            return .unavailable(
                "MCU feedback overflow: dropped \(ingress.droppedEventCount) event(s); "
                    + "MCU is unavailable until the server restarts"
            )
        }
        let workBudgetDetail = ingress.callbackWorkBudgetDroppedEventCount > 0
            ? "; callback work budget dropped \(ingress.callbackWorkBudgetDroppedEventCount) event(s)"
            : ""
        let conn = await cache.getMCUConnection()
        if !conn.isConnected {
            let portName = conn.portName.isEmpty ? "LogicProMCP-MCU-Internal" : conn.portName
            guard census.isObserved,
                  let endpointCount = census.endpointCount,
                  census.hasForeignEndpoint != nil else {
                return .unavailable(
                    "MCU feedback not detected: CoreMIDI endpoint census for '\(portName)' is unknown; "
                        + "this server refused to infer port ownership or publish a duplicate (\(census.reason ?? "no reason supplied"))."
                        + workBudgetDetail
                )
            }
            if census.hasForeignConflict {
                return .unavailable(
                    "MCU feedback not detected: \(endpointCount) endpoint(s) named "
                        + "'\(portName)' include one this server did not create. Another server instance "
                        + "or a stale endpoint owns this name; this server did not publish a duplicate."
                        + workBudgetDetail
                )
            }
            return .unavailable(
                "MCU feedback not detected: no feedback has been received on '\(portName)' (\(endpointCount) "
                    + "endpoint(s) visible, all owned by this server). Check the Logic Pro > Control "
                    + "Surfaces > Setup binding."
                    + workBudgetDetail
            )
        }
        let registered = conn.registeredAsDevice ? "device registration confirmed" : "MIDI feedback active, device registration not confirmed"
        // THE AGE, AND NOW THE WORD, STAY OUT OF THE PROSE.
        //
        // The age went first: `last_feedback_at` already carries it as a machine field, and
        // rendering it here made the same fact live in two places with only one of them projected
        // away — `stableHealthData` strips `feedback_stale` and `last_feedback_at`, then compares a
        // payload whose `detail` was still counting seconds. Measured 2026-09-11 on a warm server,
        // `channels[].detail` was the only field that kept moving after that projection: "feedback
        // stale (8s)" then "feedback stale (13s)" four seconds apart.
        //
        // #851 takes the WORD as well, and for a sharper reason than tidiness. `healthCheck` reads
        // the cache here; `SystemDispatcher` reads it AGAIN to build the `mcu` block. Feedback
        // arriving between those two reads put `detail: "…feedback stale"` in the same payload as
        // `mcu.feedback_stale: false` — one document contradicting itself, and neither field wrong
        // at the instant it was taken. `live_849` refused to compare the two fields for exactly
        // this reason and filed it rather than writing a check that would be green by luck.
        //
        // So staleness is rendered ONCE, by the dispatcher, from the single snapshot that also
        // produces `mcu.feedback_stale` — see `SystemDispatcher.mcuStalenessClause`. This channel
        // reports what it can answer from its own read without a clock: whether the port carries and
        // whether Logic registered the device.
        return .healthy(latencyMs: nil, detail: "MCU \(registered)" + workBudgetDetail)
    }

    /// Handle incoming feedback event (called from tests or transport callback).
    func handleFeedback(_ event: MIDIFeedback.Event) async {
        await receiveFeedback(event)
    }

    /// Test-only observation of the callback ingress. Production callers get
    /// the same count in `logic_system.health`'s MCU channel detail.
    func feedbackIngressSnapshot() -> MCUFeedbackIngressSnapshot {
        feedbackIngress?.snapshot() ?? .empty
    }

    // MARK: - Feedback Reception

    private func receiveFeedback(_ event: MIDIFeedback.Event) async {
        await feedbackParser.handle(event)
    }

    // MARK: - Send with optional verify delay

    /// Send bytes. For operations that need verification, caller checks StateCache after a short delay.
    /// This avoids actor deadlock from continuation-based verify-after-write.
    private func sendCommand(_ bytes: [UInt8]) async {
        await transport.send(bytes)
    }

    // MARK: - Diagnostic snapshot

    /// v3.4.5-rc5 (Issues #10 / #11) — snapshot the MCU connection state into
    /// HC envelope extras. Surfacing `mcu_connected` / `mcu_registered` /
    /// `mcu_last_feedback_age_ms` on every mixer write lets a safety harness
    /// distinguish the three echo-timeout root causes without an extra
    /// round-trip to `logic://mixer` or `logic_system`:
    ///   - `mcu_connected:false` → control surface not registered or the
    ///     virtual port is unbridged on this Logic install.
    ///   - `mcu_connected:true, mcu_last_feedback_age_ms` large → connection
    ///     went stale mid-session (Logic dropped MCU).
    ///   - `mcu_connected:true, age small, verified:false` → this specific
    ///     fader/V-Pot echo didn't land (Logic 12.2 regression, bank-offset
    ///     mismatch, etc.) — the only shape that points at a code issue.
    private func mcuConnectionExtras(snapshotNow: Date = Date()) async -> [String: Any] {
        let conn = await cache.getMCUConnection()
        // Clamp + nil handling live in MCUConnectionState.lastFeedbackAgeMs so
        // the write envelope and logic://mixer (B1) share one definition.
        return [
            "mcu_connected": conn.isConnected,
            "mcu_registered": conn.registeredAsDevice,
            "mcu_last_feedback_age_ms": conn.lastFeedbackAgeMs(now: snapshotNow) ?? NSNull(),
        ]
    }

    // MARK: - Command Implementations

    private func executeSetVolume(_ params: [String: String]) async -> ChannelResult {
        let operation = "mixer.set_volume"
        let track: Int
        let value: Double
        do {
            track = try Self.requiredTrackIndex(params["index"], operation: operation)
            value = try Self.requiredUnitValue(params["volume"], field: "volume", operation: operation)
        } catch let failure as ValidationFailure {
            return Self.invalidParams(failure.hint, operation: operation)
        } catch {
            return Self.invalidParams("Invalid MCU parameters for \(operation)", operation: operation)
        }
        let timeoutMs = Self.echoTimeoutMs

        return await withBanking(targetTrack: track, operation: operation) { strip in
            // v3.1.0 (Ralph-2 / C1) — stamp the send moment *before* the
            // write so pollFaderEcho can reject stale cache values that
            // pre-date this call. Without the stamp, an identical-value
            // re-send (set_volume 0.5 twice in a row) could return State A
            // on the stale echo from the first call even when the transport
            // is disconnected.
            let sendAt = Date()
            let bytes = MCUProtocol.encodeFader(track: strip, value: value)
            await self.sendCommand(bytes)
            // Poll the feedback parser's echo write into StateCache. Confirmed
            // fresh echo → State A. Timeout / stale-only → State B
            // `echo_timeout_<ms>ms`.
            let observed = await self.pollFaderEcho(
                strip: track, target: value, timeoutMs: timeoutMs,
                requireFreshAfter: sendAt
            )
            var extras: [String: Any] = [
                "requested": value,
                "observed": observed ?? NSNull(),
                "observed_mcu": observed ?? NSNull(),
                "observed_ax": NSNull(),
                "track": track
            ]
            for (k, v) in await self.mcuConnectionExtras(snapshotNow: sendAt) { extras[k] = v }
            if let observed, abs(observed - value) <= 2.0 / 16383.0 {
                extras["verify_source"] = "mcu_echo"
                return .success(HonestContract.encodeStateA(extras: extras))
            }

            if let observedAX = await self.axReadback?.readVolume(track) {
                extras["observed"] = observedAX
                extras["observed_ax"] = observedAX
                extras["verify_source"] = "ax_readback"
                if abs(observedAX - value) <= 0.03 {
                    return .success(HonestContract.encodeStateA(extras: extras))
                }
                return .success(HonestContract.encodeStateB(
                    reason: .readbackMismatch, extras: extras
                ))
            }

            return .success(HonestContract.encodeStateB(
                reason: .echoTimeout(ms: timeoutMs), extras: extras
            ))
        }
    }

    private func executeSetPan(_ params: [String: String]) async -> ChannelResult {
        let operation = "mixer.set_pan"
        let track: Int
        let value: Double
        do {
            track = try Self.requiredTrackIndex(params["index"], operation: operation)
            value = try Self.requiredPanValue(params["pan"], operation: operation)
        } catch let failure as ValidationFailure {
            return Self.invalidParams(failure.hint, operation: operation)
        } catch {
            return Self.invalidParams("Invalid MCU parameters for \(operation)", operation: operation)
        }
        let timeoutMs = Self.echoTimeoutMs

        return await withBanking(targetTrack: track, operation: operation) { strip in
            // v3.1.3 (#1) — stamp the send moment *before* the write so
            // pollPanEcho can reject stale cache values that pre-date this
            // call. Same anti-stale guard as set_volume's Ralph-2 / C1 fix.
            let sendAt = Date()
            let speed: UInt8 = max(1, min(15, UInt8(abs(value) * 15)))
            let direction: MCUProtocol.VPotDirection = value >= 0 ? .clockwise : .counterClockwise
            let bytes = MCUProtocol.encodeVPot(strip: strip, direction: direction, speed: speed)
            await self.sendCommand(bytes)
            // v3.1.3 (#1) — V-Pot LED-ring CC 0x30..0x37 echoes the absolute
            // pan position back from Logic. MCUFeedbackParser writes the
            // decoded pan into StateCache; pollPanEcho polls until a fresh
            // matching value arrives or the timeout elapses. Confirmed
            // fresh echo → State A. Timeout / stale-only → State B
            // `echo_timeout_<ms>ms`.
            let observed = await self.pollPanEcho(
                strip: track, target: value, timeoutMs: timeoutMs,
                requireFreshAfter: sendAt
            )
            // v3.4.5 (A4 / P1-5 / R8): set_pan transmits a *relative* V-Pot
            // rotation (MCUProtocol.encodeVPot), not an absolute pan set —
            // the MCU protocol has no absolute-position command. Disclose
            // this on the wire so a duplicate-and-readback harness does not
            // treat set_pan as an idempotent absolute target (an idempotent
            // absolute pan needs the AX write path, F2). `observed` reflects
            // the LED-ring echo when present; absent it stays null (State B).
            var extras: [String: Any] = [
                "requested": value,
                "observed": observed ?? NSNull(),
                "track": track,
                "pan_write_mode": "relative_vpot"
            ]
            for (k, v) in await self.mcuConnectionExtras(snapshotNow: sendAt) { extras[k] = v }
            if let observed, abs(observed - value) <= 0.1 {
                return .success(HonestContract.encodeStateA(extras: extras))
            }
            return .success(HonestContract.encodeStateB(
                reason: .echoTimeout(ms: timeoutMs), extras: extras
            ))
        }
    }

    private func executeSetMasterVolume(_ params: [String: String]) async -> ChannelResult {
        let operation = "mixer.set_master_volume"
        let value: Double
        do {
            value = try Self.requiredUnitValue(params["volume"], field: "volume", operation: operation)
        } catch let failure as ValidationFailure {
            return Self.invalidParams(failure.hint, operation: operation)
        } catch {
            return Self.invalidParams("Invalid MCU parameters for \(operation)", operation: operation)
        }
        let timeoutMs = Self.echoTimeoutMs
        // v3.1.0 (Ralph-2 / C1) — same send-time freshness check as per-strip
        // set_volume so a cached master value can't mascarade as a fresh
        // echo on a re-send with the same target.
        let sendAt = Date()
        let bytes = MCUProtocol.encodeFader(track: 8, value: value)
        await transport.send(bytes)
        // Master fader echoes on strip index 8 (channel 8 of the pitch-bend
        // stream, per MCU spec).
        let observed = await pollFaderEcho(
            strip: 8, target: value, timeoutMs: timeoutMs,
            requireFreshAfter: sendAt
        )
        // #142 — the master fader has NO AX track-header equivalent (per-track
        // set_volume/set_pan verify via findTrackHeaderVolumeFader, which the
        // master strip does not expose), so MCU echo on strip 8 is the ONLY
        // readback path and it is non-deterministic. Disclose the readback
        // source on EVERY outcome, and on echo timeout attach an explicit
        // surface_limitation note so a caller never mistakes the State B for a
        // recoverable failure on a verifiable surface. The op stays honest:
        // verified:true is claimed ONLY when a fresh matching echo lands.
        var extras: [String: Any] = [
            "requested": value,
            "observed": observed ?? NSNull(),
            "track": "master",
            "readback_source": "mcu_echo",
        ]
        for (k, v) in await mcuConnectionExtras(snapshotNow: sendAt) { extras[k] = v }
        if let observed, abs(observed - value) <= 2.0 / 16383.0 {
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        extras["surface_limitation"] =
            "master fader has no AX track-header equivalent; MCU echo is the only readback and is non-deterministic"
        return .success(HonestContract.encodeStateB(
            reason: .echoTimeout(ms: timeoutMs), extras: extras
        ))
    }

    /// The only way a momentary MCU button press is sent: Note On velocity 127, then velocity 0.
    /// A press with no release is a HELD button to Logic — measured 2026-09-26 (#862): after a
    /// bank-left walk and one bank-right, Logic auto-repeated both held bank buttons and redrew the
    /// LCD upper row between two windows every ~30 ms (443 SysEx frames in 3 s) from one TX triple
    /// per press; sending the release gave one redraw per press.
    private func pressButton(_ function: MCUProtocol.ButtonFunction, strip: Int = 0) async {
        await transport.send(MCUProtocol.encodeButton(function, strip: strip, on: true))
        await transport.send(MCUProtocol.encodeButton(function, strip: strip, on: false))
    }

    private func sendTransport(_ command: MCUProtocol.TransportCommand) async -> ChannelResult {
        await pressButton(MCUProtocol.transportButton(command))
        // v3.1.2 (P0-1) — MCU transport buttons are press-only triggers; Logic
        // does not echo a transport state back over the same MIDI surface, so
        // every send is honestly `readback_unavailable`. Wrap in HC envelope
        // so downstream agents stop seeing free-form `"Transport: ..."`
        // strings (the last raw-string responder identified in the v3.1.1
        // post-release audit alongside `track.select` and `track.set_automation`).
        return .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: ["function": "transport", "command": "\(command)"]
        ))
    }

    private func executeStripButton(
        _ function: MCUProtocol.ButtonFunction,
        operation: String,
        params: [String: String]
    ) async -> ChannelResult {
        let track: Int
        // `track.select` is not a toggle — callers always mean "make this track
        // the selected one." Forcing on=true avoids the previous bug where an
        // absent `enabled` param silently deselected (→ Drummer stayed focused).
        let enabled: Bool
        do {
            track = try Self.requiredTrackIndex(params["index"], operation: operation)
            if function == .select {
                enabled = true
            } else {
                enabled = try Self.requiredBool(params["enabled"], field: "enabled", operation: operation)
            }
        } catch let failure as ValidationFailure {
            return Self.invalidParams(failure.hint, operation: operation)
        } catch {
            return Self.invalidParams("Invalid MCU parameters for \(operation)", operation: operation)
        }

        guard function != .select else {
            return await withBanking(targetTrack: track, operation: operation) { strip in
                await self.pressButton(function, strip: strip)
                // v3.1.2 (P0-1) — MCU button echo is LED-only, no AX-side mirror
                // wired into StateCache yet. The press lands but cannot be read
                // back, so honestly: State B `readback_unavailable`. Wrapping
                // here also closes the only remaining raw-string responder on
                // mute / solo / arm / select that v3.1.1's audit caught.
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "function": "\(function)",
                        "track": track,
                        "enabled": enabled,
                        "write_source": "mcu",
                        "verification_source": "mcu_led_echo"
                    ]
                ))
            }
        }
        return await executeStripButtonSet(function, operation: operation, track: track, enabled: enabled)
    }

    // MARK: - Strip buttons as a set (#1020)

    /// How many AX reads a strip-button press is given to show the new state, and the wait between
    /// them. A COUNT through the injected sleeper, as the bank window's polls are, so a test counts
    /// the waits instead of timing them (#804).
    static let stripButtonReadbackPollBudget = 10
    static let stripButtonReadbackPollMilliseconds = 50

    /// What confirms a strip-button set: the track-header button `AXValue` that the Accessibility
    /// channel reads for its own `track.set_mute` / `set_solo` / `set_arm`, and names the same way.
    /// The MCU LED echo is wired into no track state and cannot say which way a toggle went.
    static let stripButtonVerifySource = "ax_value"

    /// The AX read that answers whether a strip button's track state is on, or nil for a button
    /// this channel has no reading for. `.select` is not a toggle and has no state to compare.
    private func stripButtonStateReader(
        _ function: MCUProtocol.ButtonFunction
    ) -> (@Sendable (Int) async -> Bool?)? {
        guard let axReadback else { return nil }
        switch function {
        case .mute: return axReadback.readMuted
        case .solo: return axReadback.readSoloed
        case .recArm: return axReadback.readArmed
        default: return nil
        }
    }

    /// Mute, Solo and Record are TOGGLE buttons on the MCU: a press flips whatever Logic holds, and
    /// a release on its own is not a press (#1020, following the #862 measurement of how Logic
    /// handles a button). `enabled` therefore cannot be sent, only compared: read the track's state
    /// from its AX header, press once only when it differs, and confirm by reading again. Before
    /// this, `enabled: true` on an already-muted track unmuted it, and `enabled: false` sent a bare
    /// velocity-0 note that Logic ignored.
    ///
    /// With no reading before the press there is no way to know which way a press would move the
    /// track, so nothing is sent and the refusal carries a NON-terminal code: `ChannelRouter` walks
    /// past it to the next channel, where a terminal one would end the walk with nothing done.
    /// After a press the readback did not confirm, nothing is pressed again — a second press on a
    /// toggle is the opposite write — and the answer is State B with `write_attempted: true`.
    ///
    /// The read, the decision, the press and the readback run under ONE `withBankExclusion`. Read
    /// outside it, two concurrent `enabled: true` requests on a disarmed track both read "off", the
    /// lock then serialises their presses, and the second press disarms what the first armed: the
    /// actor re-enters at every `await`, so being an actor does not order them. Under the lock a
    /// request reads the state the previous one left. The read still comes before any bank press,
    /// so a request that already matches sends nothing at all, bank bytes included.
    private func executeStripButtonSet(
        _ function: MCUProtocol.ButtonFunction,
        operation: String,
        track: Int,
        enabled: Bool
    ) async -> ChannelResult {
        var extras: [String: Any] = [
            "function": "\(function)",
            "track": track,
            "enabled": enabled,
            "write_source": "mcu",
            "verification_source": Self.stripButtonVerifySource,
        ]
        let read = stripButtonStateReader(function)
        return await withBankExclusion {
            guard let read, let before = await read(track) else {
                extras["write_attempted"] = false
                extras["observed"] = NSNull()
                extras["operation"] = operation
                extras["channel"] = "MCU"
                return .error(HonestContract.encodeStateC(
                    error: .trackStateUnreadable,
                    hint: "\(operation) sent nothing: the MCU \(function) button toggles, and track \(track)'s "
                        + "\(function) state could not be read from its track header, so one press could set "
                        + "it or clear it. Another channel may still set it.",
                    extras: extras
                ))
            }
            if before == enabled {
                extras["observed"] = before
                extras["write_attempted"] = false
                return .success(HonestContract.encodeStateA(extras: extras))
            }

            return await bankedStripWrite(targetTrack: track, operation: operation) { strip in
                await self.pressButton(function, strip: strip)
                extras["write_attempted"] = true
                var observed: Bool?
                for attempt in 0..<Self.stripButtonReadbackPollBudget {
                    observed = await read(track)
                    // ADR-005: every verification poll attempt is a traced phase (no-op without an
                    // active mutation trace).
                    await OperationTraceContext.record(.verificationPoll, attributes: [
                        "outcome": observed == enabled ? "matched" : "pending",
                    ])
                    if observed == enabled { break }
                    if attempt < Self.stripButtonReadbackPollBudget - 1 {
                        await self.sleep(.milliseconds(Self.stripButtonReadbackPollMilliseconds))
                    }
                }
                if let observed {
                    extras["observed"] = observed
                } else {
                    extras["observed"] = NSNull()
                }
                guard observed == enabled else {
                    return .success(HonestContract.encodeStateB(
                        reason: observed == nil ? .readbackUnavailable : .readbackMismatch,
                        extras: extras
                    ))
                }
                return .success(HonestContract.encodeStateA(extras: extras))
            }
        }
    }

    private func executeAutomation(_ params: [String: String]) async -> ChannelResult {
        let operation = "track.set_automation"
        let track: Int
        let mode: String
        let function: MCUProtocol.ButtonFunction
        do {
            (mode, function) = try Self.requiredAutomationMode(params["mode"], operation: operation)
            track = try Self.requiredTrackIndex(params["index"], operation: operation)
        } catch let failure as ValidationFailure {
            return Self.invalidParams(failure.hint, operation: operation)
        } catch {
            return Self.invalidParams("Invalid MCU parameters for \(operation)", operation: operation)
        }
        let requestedMode = AutomationMode(rawValue: mode)
        var extras: [String: Any] = [
            "function": "set_automation",
            "track": track,
            "mode": mode,
        ]
        var observedMode = await axReadback?.readAutomationMode(track)
        if observedMode == requestedMode {
            extras["observed_mode"] = observedMode?.rawValue
            extras["write_attempted"] = false
            return .success(HonestContract.encodeStateA(extras: extras))
        }

        return await withBanking(targetTrack: track, operation: operation) { strip in
            await self.pressButton(.select, strip: strip)
            var observedSelectedTrack: Int?
            if let axReadback = self.axReadback {
                for attempt in 0..<10 {
                    observedSelectedTrack = await axReadback.readSelectedTrack()
                    if observedSelectedTrack == track { break }
                    if attempt < 9 { try? await Task.sleep(nanoseconds: 50_000_000) }
                }
            }
            extras["write_attempted"] = true
            extras["automation_write_attempted"] = false
            if let observedSelectedTrack {
                extras["observed_selected_track"] = observedSelectedTrack
            }
            guard observedSelectedTrack == track else {
                return .success(HonestContract.encodeStateB(
                    reason: observedSelectedTrack == nil ? .readbackUnavailable : .readbackMismatch,
                    extras: extras
                ))
            }

            await self.pressButton(function)
            extras["automation_write_attempted"] = true
            if let axReadback = self.axReadback {
                for attempt in 0..<10 {
                    observedMode = await axReadback.readAutomationMode(track)
                    // ADR-005: every verification poll attempt is a traced
                    // phase (no-op without an active mutation trace).
                    await OperationTraceContext.record(.verificationPoll, attributes: [
                        "outcome": observedMode == requestedMode ? "matched" : "pending",
                    ])
                    if observedMode == requestedMode { break }
                    if attempt < 9 { try? await Task.sleep(nanoseconds: 50_000_000) }
                }
            }
            if let observedMode { extras["observed_mode"] = observedMode.rawValue }
            guard observedMode == requestedMode else {
                return .success(HonestContract.encodeStateB(
                    reason: observedMode == nil ? .readbackUnavailable : .readbackMismatch,
                    extras: extras
                ))
            }
            return .success(HonestContract.encodeStateA(extras: extras))
        }
    }

    // MARK: - Validation

    private static func invalidParams(_ hint: String, operation: String) -> ChannelResult {
        .error(HonestContract.encodeStateC(
            error: .invalidParams,
            hint: hint,
            extras: ["operation": operation, "channel": "MCU"]
        ))
    }

    private static func requiredTrackIndex(_ raw: String?, operation: String) throws -> Int {
        try requiredInt(
            raw,
            field: "index",
            range: 0...255,
            operation: operation,
            rangeDescription: "0...255"
        )
    }

    private static func requiredInt(
        _ raw: String?,
        field: String,
        range: ClosedRange<Int>,
        operation: String,
        rangeDescription: String
    ) throws -> Int {
        guard let rawValue = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            throw ValidationFailure(hint: "\(operation) requires '\(field)' as an integer in \(rangeDescription)")
        }
        guard let value = Int(rawValue), range.contains(value) else {
            throw ValidationFailure(hint: "\(operation) requires '\(field)' as an integer in \(rangeDescription)")
        }
        return value
    }

    private static func requiredUnitValue(_ raw: String?, field: String, operation: String) throws -> Double {
        try requiredDouble(
            raw,
            field: field,
            range: 0.0...1.0,
            operation: operation,
            rangeDescription: "0.0 and 1.0"
        )
    }

    private static func requiredPanValue(_ raw: String?, operation: String) throws -> Double {
        try requiredDouble(
            raw,
            field: "pan",
            range: -1.0...1.0,
            operation: operation,
            rangeDescription: "-1.0 and 1.0"
        )
    }

    private static func requiredDouble(
        _ raw: String?,
        field: String,
        range: ClosedRange<Double>,
        operation: String,
        rangeDescription: String
    ) throws -> Double {
        guard let rawValue = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            throw ValidationFailure(hint: "\(operation) requires '\(field)' as a finite number between \(rangeDescription)")
        }
        guard let value = Double(rawValue), value.isFinite, range.contains(value) else {
            throw ValidationFailure(hint: "\(operation) requires '\(field)' as a finite number between \(rangeDescription)")
        }
        return value
    }

    private static func requiredBool(_ raw: String?, field: String, operation: String) throws -> Bool {
        guard let rawValue = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            throw ValidationFailure(hint: "\(operation) requires '\(field)' as true/false or 1/0")
        }
        switch rawValue.lowercased() {
        case "true", "1":
            return true
        case "false", "0":
            return false
        default:
            throw ValidationFailure(hint: "\(operation) requires '\(field)' as true/false or 1/0")
        }
    }

    private static func requiredAutomationMode(
        _ raw: String?,
        operation: String
    ) throws -> (String, MCUProtocol.ButtonFunction) {
        guard let mode = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !mode.isEmpty else {
            throw ValidationFailure(
                hint: "\(operation) requires 'mode' as one of read, write, touch, latch, trim"
            )
        }
        switch mode {
        case "read":
            return (mode, .automationRead)
        case "write":
            return (mode, .automationWrite)
        case "touch":
            return (mode, .automationTouch)
        case "latch":
            return (mode, .automationLatch)
        case "trim":
            return (mode, .automationTrim)
        default:
            throw ValidationFailure(
                hint: "Unknown automation mode: \(mode). \(operation) requires 'mode' as one of read, write, touch, latch, trim"
            )
        }
    }

    // MARK: - Bank window (#862)

    /// One poll of the LCD upper row while a bank move is awaited.
    static let bankWindowPollMilliseconds = 25

    /// How many upper-row polls a bank move is given. A COUNT, not a deadline: the wait is
    /// `echoTimeoutMs` worth of 25 ms polls, so a test that injects a sleeper returning at once
    /// can count the polls instead of timing them (#804), and a loaded machine can only make the
    /// loop turn slower, never more often.
    static var bankWindowPollBudget: Int { max(1, echoTimeoutMs / bankWindowPollMilliseconds) }

    /// The only readback a bank move has. Nothing in the MCU protocol reports the bank offset;
    /// what Logic does report, after every bank move, is the eight six-character names of the
    /// strips now under the surface, as the LCD upper row (measured 2026-09-13, #862).
    static let bankWindowVerifySource = "mcu_lcd_upper_row"

    /// Bank bookkeeping is clamped to the 32 banks of a 256-track project.
    static let bankIndexRange = 0...31

    /// `mixer.bank`: move the MCU window `count` banks left or right, one press at a time, and
    /// say how many of those presses Logic moved the window for.
    ///
    /// The press being sent proves nothing — `withBanking` sends the same bytes and measured a
    /// miss (#862, 2026-09-11), and two presses sent back to back moved Logic 12.3 ONE bank
    /// (#862, 2026-09-27). So every step is its own press and its own readback: snapshot the LCD
    /// upper row, press once, then poll. A step MOVED when the row was WRITTEN after that step's
    /// snapshot (`mcuUpperRowWriteSequence` advanced), stopped moving (the sequence unchanged
    /// across two consecutive polls — Logic may redraw a row in several partial SysEx writes, and
    /// the first of them is not the window), and READS differently from that step's snapshot. A
    /// step whose redraw left the bytes identical is UNCHANGED: at bank 0 pressing left, at the
    /// last bank pressing right, or eight neighbours whose six-char truncations coincide all look
    /// like that, and six characters cannot tell them apart. A step with no quiescent redraw
    /// inside the poll budget had NO REDRAW. The walk stops at the first step that did not move,
    /// and no further press is sent.
    ///
    /// State A means every one of the `count` presses produced its own quiescent redraw to a row
    /// different from the one before it. It still cannot say WHICH bank is showing — six-char
    /// names are not an index — only that each step moved. No step moved is the single-press
    /// answer: State B `noop_unobservable` for an unchanged row, State B echo timeout for no
    /// redraw. Some but not all steps moved is State B too: `readback_mismatch` when the stopping
    /// step redrew unchanged (the end of the mixer in that direction), echo timeout when it did
    /// not redraw. `banks_moved` never exceeds the steps witnessed. A row that was never received
    /// at all is refused BEFORE anything is sent, because with nothing to compare against there
    /// is no way to know whether Logic moved and no honest answer to give afterwards.
    ///
    /// `currentBank` is bookkeeping this file keeps about itself, never read back from Logic; it
    /// moves by the witnessed `banks_moved` only, and both values are reported so drift is visible.
    private func executeBank(_ params: [String: String]) async -> ChannelResult {
        let operation = "mixer.bank"
        let direction: String
        let count: Int
        do {
            direction = try Self.requiredBankDirection(params["direction"], operation: operation)
            count = try Self.optionalBankCount(params["count"], operation: operation)
        } catch {
            let hint = (error as? ValidationFailure)?.hint ?? "Invalid MCU parameters for \(operation)"
            // Every reply this handler gives says how far it got; a refused parameter got nowhere.
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: hint,
                extras: [
                    "operation": operation, "channel": "MCU",
                    "bank_presses_sent": 0, "banks_moved": 0, "step_windows": [String](),
                ]
            ))
        }
        let button: MCUProtocol.ButtonFunction = direction == "right" ? .bankRight : .bankLeft
        let sign = direction == "right" ? 1 : -1

        return await withBankExclusion {
            let bookkeepingBefore = currentBank
            var extras: [String: Any] = [
                "operation": operation,
                "channel": "MCU",
                "direction": direction,
                "bank_bookkeeping_before": bookkeepingBefore,
            ]

            // Snapshot BEFORE the first byte goes out: the comparison is against what the row
            // held when the caller asked, not against whatever a poll happens to read first.
            let before = await cache.mcuUpperRowSnapshot()
            guard before.sequence > 0 else {
                extras["write_attempted"] = false
                extras["bank_presses_sent"] = 0
                extras["banks_moved"] = 0
                extras["banks_requested"] = count
                extras["step_windows"] = [String]()
                extras["verify_source"] = Self.bankWindowVerifySource
                for (k, v) in await mcuConnectionExtras() { extras[k] = v }
                let hint = "\(operation) sent nothing: the MCU LCD upper row has never been received on this "
                    + "server, so there is no bank window to compare a move against. Install the Mackie "
                    + "Control surface with both ports bound to LogicProMCP-MCU-Internal "
                    + "(logic_system setup_control_surface), confirm logic://mcu/state shows "
                    + "display.upperRow, then retry."
                return .error(HonestContract.encodeStateC(
                    error: .readbackUnavailable, hint: hint, extras: extras
                ))
            }
            extras["window_before"] = before.row

            var banksMoved = 0
            var pressesSent = 0
            var writesObserved = 0
            var stepWindows: [String] = []
            var lastWindow = before.row
            // nil while every step so far moved; otherwise how the stopping step ended.
            var stoppedQuiescent: Bool?
            var stoppedUnchanged = false
            var stepsDisambiguated = 0
            var probeUnresolved = false
            var probeWindowMoves = 0
            for step in 0..<count {
                var stepBefore = before
                if step > 0 { stepBefore = await cache.mcuUpperRowSnapshot() }
                let reading = await bankStep(button, from: stepBefore)
                pressesSent += 1
                writesObserved += reading.writes
                stepWindows.append(reading.window)
                lastWindow = reading.window

                guard reading.redrew else {
                    stoppedQuiescent = reading.quiescent
                    break
                }
                guard !reading.unchanged else {
                    stoppedQuiescent = true
                    stoppedUnchanged = true
                    break
                }
                banksMoved += 1
                guard !reading.fullShift else { continue }
                // The flag is what a later strip write reads. A bank-left step is never probed.
                guard button == .bankRight else {
                    windowOffsetUnaligned = true
                    continue
                }
                let probe = await probeAmbiguousRightStep(after: reading.window)
                pressesSent += probe.windows.count
                writesObserved += probe.writes
                stepWindows += probe.windows
                lastWindow = probe.windows.last ?? lastWindow
                if probe.verdict == .fullShift {
                    stepsDisambiguated += 1
                    continue
                }
                windowOffsetUnaligned = true
                if probe.verdict == .unresolved {
                    probeUnresolved = true
                    probeWindowMoves = probe.extraWindowMoves
                    break
                }
                // The probe was the next step's press, and it redrew the same row: Logic's last
                // bank. A further press would only say so again.
                if step + 1 < count {
                    stoppedQuiescent = true
                    stoppedUnchanged = true
                    break
                }
            }

            extras["bank_presses_sent"] = pressesSent
            extras["banks_moved"] = banksMoved
            extras["bank_steps_disambiguated"] = stepsDisambiguated
            extras["bank_probe_unresolved"] = probeUnresolved
            extras["banks_requested"] = count
            extras["step_windows"] = stepWindows
            extras["upper_row_writes_observed"] = writesObserved
            extras["window_after"] = lastWindow
            for (k, v) in await mcuConnectionExtras() { extras[k] = v }

            if banksMoved + probeWindowMoves > 0 {
                currentBank = min(
                    max(currentBank + sign * (banksMoved + probeWindowMoves), Self.bankIndexRange.lowerBound),
                    Self.bankIndexRange.upperBound
                )
            }
            extras["bank_bookkeeping_after"] = currentBank
            // The one reading that re-establishes the offset: bank left redrew unchanged, which is
            // Logic at its left end, and the bookkeeping agrees it is bank 0.
            if stoppedUnchanged, sign < 0, currentBank == Self.bankIndexRange.lowerBound {
                windowOffsetUnaligned = false
            }

            if probeUnresolved {
                extras["readback_source"] = Self.bankWindowVerifySource
                extras["surface_limitation"] = "bank step \(banksMoved) redrew the LCD upper row to one that may "
                    + "be the old row slid by fewer than eight strips, and the probe that settles it (one more "
                    + "Bank Right, then a Bank Left back to the same row) did not read back as either answer; "
                    + "the walk stopped there and strip-relative writes refuse until the bank is walked left "
                    + "to its end"
                return .success(HonestContract.encodeStateB(
                    reason: .readbackMismatch, extras: extras
                ))
            }

            guard let quiescent = stoppedQuiescent else {
                extras["verify_source"] = Self.bankWindowVerifySource
                extras["strips"] = Self.bankWindowStrips(lastWindow)
                return .success(HonestContract.encodeStateA(extras: extras))
            }

            guard stoppedUnchanged else {
                extras["readback_source"] = Self.bankWindowVerifySource
                extras["row_quiescent"] = quiescent
                return .success(HonestContract.encodeStateB(
                    reason: .echoTimeout(ms: Self.echoTimeoutMs), extras: extras
                ))
            }

            extras["verify_source"] = Self.bankWindowVerifySource
            guard banksMoved > 0 else {
                let limitation = "the LCD upper row redrew with the same six-character names it held before "
                    + "the press; an identical redraw cannot confirm a bank move (bank 0 pressed left, the "
                    + "last bank pressed right, or eight neighbours whose truncated names coincide)"
                extras["surface_limitation"] = limitation
                return .success(HonestContract.encodeStateB(
                    reason: .noopUnobservable, extras: extras
                ))
            }
            let limitation = "the LCD upper row moved \(banksMoved) of \(count) requested banks, then redrew "
                + "unchanged on the next press; an identical redraw is what the end of the mixer in that "
                + "direction looks like (or eight neighbours whose truncated names coincide), so no further "
                + "press was sent"
            extras["surface_limitation"] = limitation
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch, extras: extras
            ))
        }
    }

    /// What one bank press did to the LCD upper row, measured against the snapshot taken before it.
    private struct BankStepReading {
        /// Upper-row writes that arrived after the press.
        let writes: Int
        /// The row as it stood when the polling stopped.
        let window: String
        /// The write count held still for one more poll after the last fresh write.
        let quiescent: Bool
        /// The row reads exactly as it did before the press.
        let unchanged: Bool
        /// The new row cannot be the old one slid by fewer than eight strips (see
        /// `mayBeShortShift`). False for a step that did not move.
        let fullShift: Bool

        /// A fresh write arrived and the row then held still.
        var redrew: Bool { writes > 0 && quiescent }
        /// The one thing a bank step can be witnessed doing: a quiescent redraw to a different row.
        var moved: Bool { redrew && !unchanged }
    }

    /// ONE bank step, the only measurement a bank move has (#862, #1020): press the button once
    /// (with its release), then poll the upper row through the injected sleeper for at most
    /// `bankWindowPollBudget` polls. Fresh means WRITTEN after `stepBefore`, strictly. Quiescent
    /// means the write count held still for one more poll after the last fresh write. `mixer.bank`
    /// and `withBanking` both step through here, so there is one definition of a bank step moving.
    private func bankStep(
        _ button: MCUProtocol.ButtonFunction,
        from stepBefore: (row: String, sequence: UInt64)
    ) async -> BankStepReading {
        await pressButton(button)
        var after = stepBefore
        var quiescent = false
        for _ in 0..<Self.bankWindowPollBudget {
            await sleep(.milliseconds(Self.bankWindowPollMilliseconds))
            let snapshot = await cache.mcuUpperRowSnapshot()
            guard snapshot.sequence > stepBefore.sequence else { continue }
            if snapshot.sequence == after.sequence {
                quiescent = true
                break
            }
            after = snapshot
        }
        let unchanged = after.row == stepBefore.row
        return BankStepReading(
            writes: Int(clamping: after.sequence - stepBefore.sequence),
            window: after.row,
            quiescent: quiescent,
            unchanged: unchanged,
            fullShift: !unchanged && !Self.mayBeShortShift(
                before: stepBefore.row, after: after.row, rightward: button == .bankRight
            )
        )
    }

    /// Whether a changed upper row could be the old one slid by k < 8 strips. Logic stops the last
    /// bank at the last strip: measured 2026-09-27 on a 21-strip project, bank right from strips
    /// 8-15 showed strips 13-20, a shift of five, and strip 0 then named track 13 (#1020). So a
    /// bank-right step is suspect when, for some k in 1...7, `after[i] == before[i + k]` for every
    /// i in 0..<8-k (bank left: `after[i + k] == before[i]`). A real short shift always satisfies
    /// that; repeated names can only make it true more often, so the answer errs toward refusing.
    /// A row longer than 56 characters has no provable cell boundaries and counts as suspect.
    static func mayBeShortShift(before: String, after: String, rightward: Bool) -> Bool {
        guard before.count <= 56, after.count <= 56 else { return true }
        let old = bankWindowStrips(before)
        let new = bankWindowStrips(after)
        for k in 1...7 {
            var slid = true
            for i in 0..<(8 - k) {
                let same: Bool = rightward ? (new[i] == old[i + k]) : (new[i + k] == old[i])
                if !same {
                    slid = false
                    break
                }
            }
            if slid { return true }
        }
        return false
    }

    /// The eight seven-character cells of a 56-character LCD row — six characters of name and
    /// one separator — with trailing spaces trimmed. A row that is not 56 characters long is
    /// padded or cut to 56 first so the cell boundaries stay where the surface draws them.
    static func bankWindowStrips(_ row: String) -> [String] {
        let chars = Array(row.padding(toLength: 56, withPad: " ", startingAt: 0))
        return stride(from: 0, to: chars.count, by: 7).map { start in
            var cell = String(chars[start..<start + 7])
            while cell.hasSuffix(" ") { cell.removeLast() }
            return cell
        }
    }

    private static func requiredBankDirection(_ raw: String?, operation: String) throws -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value == "left" || value == "right" else {
            throw ValidationFailure(hint: "\(operation) requires 'direction' as left or right")
        }
        return value
    }

    private static func optionalBankCount(_ raw: String?, operation: String) throws -> Int {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 1 }
        return try requiredInt(
            raw,
            field: "count",
            range: 1...31,
            operation: operation,
            rangeDescription: "1...31"
        )
    }

    // MARK: - Banking (Proper Queue)

    /// Serialises everything that moves the bank AND everything that addresses a strip. `withBanking`
    /// moves it and moves it back; `executeBank` moves it and leaves it. Interleaving the two would
    /// restore a bank neither asked for. A strip index names a channel only relative to the bank
    /// Logic is showing, and `executeBank` updates `currentBank` only after its walk, so a strip
    /// write that read `currentBank` while a walk was suspended in a poll would land in whatever
    /// bank the walk had already drawn (#862). Every strip-relative operation therefore holds this
    /// lock too, including the one whose track is in the bank the bookkeeping holds.
    ///
    /// Not re-entrant: nothing running under it may call `withBanking`, `withBankExclusion` or
    /// `executeBank`, or it waits for itself.
    private func withBankExclusion(_ body: () async -> ChannelResult) async -> ChannelResult {
        // Wait if another banking operation is in progress (loop to handle spurious wakeups)
        while isBanking {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                bankingQueue.append(continuation)
            }
        }

        isBanking = true
        defer {
            isBanking = false
            if !bankingQueue.isEmpty {
                bankingQueue.removeFirst().resume()
            }
        }
        return await body()
    }

    /// Test-only observation: how many callers are parked waiting for `withBankExclusion`. A test
    /// that holds the lock open needs to know a second caller reached it without reading a clock.
    var bankExclusionWaiterCount: Int { bankingQueue.count }

    /// One leg of a bank walk: the presses sent, how many of them moved, and the upper row after
    /// each press. On the outward leg `banksMoved` counts only full eight-strip steps, and
    /// `shortStepMoved` says the stopping step did move the window, possibly by fewer than eight.
    private struct BankWalkLeg {
        var pressesSent = 0
        var banksMoved = 0
        var shortStepMoved = false
        var stepWindows: [String] = []
        /// Ambiguous bank-right steps a probe proved moved a full eight (`probeAmbiguousRightStep`).
        var stepsDisambiguated = 0
        /// The probe after the stopping step settled nothing; the window may be where it left it.
        var probeUnresolved = false
        /// Probe presses that changed the row and were not undone (0 or 1).
        var probeWindowMoves = 0

        /// Steps the walk home owes: every step that moved the window, full or not, and a probe
        /// press that moved it and was not walked back.
        var windowMoves: Int { banksMoved + (shortStepMoved ? 1 : 0) + probeWindowMoves }
    }

    /// What one probe settled about an ambiguous bank-right step.
    private struct BankProbe {
        enum Verdict { case lastBank, fullShift, unresolved }
        let verdict: Verdict
        /// The row after each probe press, in order (one or two).
        let windows: [String]
        let writes: Int
        /// Probe presses that changed the row and were not undone (0 or 1).
        let extraWindowMoves: Int
    }

    /// Settle a bank-right step whose new row may be the old one slid by fewer than eight strips
    /// (#1020). Logic clamps only the LAST right step (offset becomes min(offset + 8, N - 8)), so
    /// one more Bank Right answers the question:
    /// - it redraws the same row: the window is at Logic's last bank and the step may have been
    ///   clamped (`lastBank`, one press sent);
    /// - it moves: the step was not the last one, so it moved a full eight. One Bank Left then has
    ///   to redraw the ambiguous step's row byte for byte — measured live, left from the clamped
    ///   offset 13 lands on 8, the previous multiple of eight — before the walk continues
    ///   (`fullShift`, two presses sent);
    /// - anything else settles nothing (`unresolved`).
    /// The caller holds `withBankExclusion`.
    private func probeAmbiguousRightStep(after row: String) async -> BankProbe {
        let probeBefore = await cache.mcuUpperRowSnapshot()
        let probe = await bankStep(.bankRight, from: probeBefore)
        if probe.redrew, probe.window == row {
            return BankProbe(verdict: .lastBank, windows: [probe.window], writes: probe.writes, extraWindowMoves: 0)
        }
        guard probe.moved else {
            let changed = probe.writes > 0 && probe.window != row
            return BankProbe(
                verdict: .unresolved, windows: [probe.window], writes: probe.writes,
                extraWindowMoves: changed ? 1 : 0
            )
        }
        let returnBefore = await cache.mcuUpperRowSnapshot()
        let back = await bankStep(.bankLeft, from: returnBefore)
        let windows = [probe.window, back.window]
        if back.redrew, back.window == row {
            return BankProbe(verdict: .fullShift, windows: windows, writes: probe.writes + back.writes, extraWindowMoves: 0)
        }
        let returned = back.writes > 0 && back.window != probe.window
        return BankProbe(
            verdict: .unresolved, windows: windows, writes: probe.writes + back.writes,
            extraWindowMoves: returned ? 0 : 1
        )
    }

    /// Walk the bank up to `steps` presses in one direction, one `bankStep` at a time, stopping
    /// at the first press that did not move — and, with `requireFullShift`, at the first press
    /// that moved but may have moved fewer than eight strips and that a probe could not prove
    /// full (`probeAmbiguousRightStep`; a bank-left step is never probed). The caller holds
    /// `withBankExclusion` and settles `currentBank` from the legs (`settleBankBookkeeping`).
    private func walkBank(
        _ button: MCUProtocol.ButtonFunction, steps: Int, requireFullShift: Bool
    ) async -> BankWalkLeg {
        var leg = BankWalkLeg()
        for _ in 0..<steps {
            let stepBefore = await cache.mcuUpperRowSnapshot()
            let reading = await bankStep(button, from: stepBefore)
            leg.pressesSent += 1
            leg.stepWindows.append(reading.window)
            guard reading.moved else { break }
            if requireFullShift, !reading.fullShift {
                guard button == .bankRight else {
                    leg.shortStepMoved = true
                    break
                }
                let probe = await probeAmbiguousRightStep(after: reading.window)
                leg.pressesSent += probe.windows.count
                leg.stepWindows += probe.windows
                if probe.verdict == .fullShift {
                    leg.banksMoved += 1
                    leg.stepsDisambiguated += 1
                    continue
                }
                leg.shortStepMoved = true
                leg.probeUnresolved = probe.verdict == .unresolved
                leg.probeWindowMoves = probe.extraWindowMoves
                break
            }
            leg.banksMoved += 1
        }
        return leg
    }

    /// `currentBank` after a walk: moved by every outward step that moved the window (a short step
    /// counts, as `mixer.bank` counts it) and back by every homeward step that moved, never by a
    /// step that did not. A short step the walk home could not undo leaves the window off a
    /// multiple of eight, which `windowOffsetUnaligned` records.
    private func settleBankBookkeeping(origin: Int, sign: Int, out: BankWalkLeg, back: BankWalkLeg) {
        if out.shortStepMoved, back.banksMoved == 0 { windowOffsetUnaligned = true }
        currentBank = min(
            max(origin + sign * (out.windowMoves - back.banksMoved), Self.bankIndexRange.lowerBound),
            Self.bankIndexRange.upperBound
        )
    }

    /// The fields every reply behind a bank walk carries: how far out it got and whether it got
    /// home. `banks_moved` counts the outward steps verified to move a full eight strips;
    /// `bank_restored` is whether the walk back moved as many steps as the walk out moved the window.
    private func bankWalkExtras(requested: Int, out: BankWalkLeg, back: BankWalkLeg) -> [String: Any] {
        [
            "bank_presses_sent": out.pressesSent + back.pressesSent,
            "banks_moved": out.banksMoved,
            "banks_requested": requested,
            "bank_restored": back.banksMoved == out.windowMoves,
            "bank_step_short_of_eight": out.shortStepMoved,
            "bank_steps_disambiguated": out.stepsDisambiguated,
            "bank_probe_unresolved": out.probeUnresolved,
            "bank_window_unaligned": windowOffsetUnaligned,
            "step_windows": out.stepWindows + back.stepWindows,
            "bank_bookkeeping_after": currentBank,
        ]
    }

    /// Every strip-relative MCU write addresses a strip INDEX, which names a channel only relative
    /// to the bank Logic is showing. So the bank is moved one `bankStep` at a time, the write runs
    /// only when every step toward its bank was witnessed moving a FULL eight strips, and the walk
    /// home is stepped the same way (#1020). Two presses sent back to back moved Logic 12.3 ONE bank
    /// (docs/observations/2026-09-27-*-a-bank-step-answers-from-the-redrawn-upper-row.json), so
    /// `enabled: false` for armed track 16 pressed strip 0 on bank 1 and armed track 8. And Logic
    /// stops the last bank at the last strip: on a 21-strip project bank 2 showed strips 13-20, the
    /// step redrew a different row, and strip 0 armed track 13 where 16 was asked (measured
    /// 2026-09-27). A fixed settle between presses was ruled out (#862): a delay is a guess about
    /// Logic's rate, the per-step quiescent redraw is a reading.
    ///
    /// While `windowOffsetUnaligned` is set and `currentBank` is not 0, nothing is sent and the
    /// write refuses. When the bank is already `currentBank` the write runs as before, on the
    /// bookkeeping alone: nothing is pressed, and nothing in the MCU protocol reads the bank offset
    /// back (#862). Otherwise:
    /// - an upper row never received refuses with nothing sent;
    /// - a bank-right step that may have moved fewer than eight strips is probed
    ///   (`probeAmbiguousRightStep`) and the walk continues only when the probe proves it full;
    /// - a step that did not move, or moved but may have moved fewer than eight strips and was not
    ///   proved full, stops the walk, the strip is NOT pressed, every step that moved the window is walked back, and the
    ///   answer is State C `bank_walk_unverified`, which is not terminal, so the router moves on;
    /// - after the write, a walk-home step that did not move stops the walk home; the write's own
    ///   reply stands and carries `bank_restored: false`.
    private func withBanking(
        targetTrack: Int,
        operation: String,
        stripWrite: @escaping (Int) async -> ChannelResult
    ) async -> ChannelResult {
        if let refusal = Self.bankTargetOutOfRange(targetTrack) { return refusal }
        return await withBankExclusion {
            await bankedStripWrite(targetTrack: targetTrack, operation: operation, stripWrite: stripWrite)
        }
    }

    /// Sanity cap: real Logic projects rarely exceed 256 tracks (32 MCU banks). A
    /// `track.select {index: 99999}` was seen to spend 25 s walking 12499 bank-right presses then
    /// restoring — far past any client timeout. Reject up front rather than burning that time.
    private static func bankTargetOutOfRange(_ targetTrack: Int) -> ChannelResult? {
        guard (0...255).contains(targetTrack) else {
            return .error("MCU bank target track \(targetTrack) out of range (0..255)")
        }
        return nil
    }

    /// `withBanking`'s walk, write and walk home, for a caller that already holds
    /// `withBankExclusion` — `executeStripButtonSet` takes the lock itself so its state read and
    /// no-op decision sit under the same acquisition as its press (#1020). Acquiring nothing, it
    /// cannot wait for itself.
    private func bankedStripWrite(
        targetTrack: Int,
        operation: String,
        stripWrite: (Int) async -> ChannelResult
    ) async -> ChannelResult {
        if let refusal = Self.bankTargetOutOfRange(targetTrack) { return refusal }
        let targetBank = targetTrack / 8
        let strip = targetTrack % 8

        // Decided under the lock: read outside it, `currentBank` can be the bank a suspended
        // `executeBank` walk has already left.
        if windowOffsetUnaligned, currentBank != Self.bankIndexRange.lowerBound {
            return await bankWalkRefusal(
                operation: operation, track: targetTrack, strip: strip,
                requested: abs(targetBank - currentBank), out: BankWalkLeg(), back: BankWalkLeg(),
                reason: "an earlier bank move left the MCU window where Logic stopped the last bank "
                    + "at the last strip, so its offset is not a multiple of eight and no strip index "
                    + "names a known track; nothing was sent. Move the bank left to its end with "
                    + "mixer.bank (the step that redraws unchanged) to clear this"
            )
        }
        if targetBank == currentBank {
            return await stripWrite(strip)
        }

        let origin = currentBank
        let requested = abs(targetBank - origin)
        let sign = targetBank > origin ? 1 : -1
        let outward: MCUProtocol.ButtonFunction = sign > 0 ? .bankRight : .bankLeft
        let homeward: MCUProtocol.ButtonFunction = sign > 0 ? .bankLeft : .bankRight

        guard await cache.mcuUpperRowSnapshot().sequence > 0 else {
            return await bankWalkRefusal(
                operation: operation, track: targetTrack, strip: strip, requested: requested,
                out: BankWalkLeg(), back: BankWalkLeg(),
                reason: "the MCU LCD upper row has never been received on this server, so no bank "
                    + "step could be verified and no bank press was sent"
            )
        }

        let out = await walkBank(outward, steps: requested, requireFullShift: true)
        guard out.banksMoved == requested else {
            let back = await walkBank(homeward, steps: out.windowMoves, requireFullShift: false)
            settleBankBookkeeping(origin: origin, sign: sign, out: out, back: back)
            let stopped = "bank step \(out.banksMoved + 1) of \(requested) toward track \(targetTrack)'s bank "
            let short = stopped + "redrew the MCU LCD upper row, but the new row may be the old one slid by "
                + "fewer than eight strips: Logic stops the last bank at the last strip, so strip "
                + "\(strip) could name an earlier track"
            let reason: String
            if out.probeUnresolved {
                reason = short + "; the probe that settles it (one more Bank Right, then a Bank Left back "
                    + "to the same row) did not read back as either answer"
            } else if out.shortStepMoved {
                reason = short + "; one more Bank Right redrew the same row, so this is Logic's last bank"
            } else {
                reason = stopped + "produced no quiescent redraw of the MCU LCD upper row to a different row, "
                    + "so Logic cannot be shown to be on the bank the strip index would name (two "
                    + "presses sent back to back were measured moving Logic 12.3 one bank)"
            }
            return await bankWalkRefusal(
                operation: operation, track: targetTrack, strip: strip, requested: requested,
                out: out, back: back, reason: reason
            )
        }

        let result = await stripWrite(strip)

        let back = await walkBank(homeward, steps: requested, requireFullShift: false)
        settleBankBookkeeping(origin: origin, sign: sign, out: out, back: back)
        // `addExtras` is the merge the router already uses on success envelopes; it leaves a
        // refusal untouched, so a State C from the write is returned as the write gave it.
        guard case .success(let message) = result else { return result }
        return .success(HonestContract.addExtras(
            bankWalkExtras(requested: requested, out: out, back: back), into: message
        ))
    }

    /// State C `bank_walk_unverified`: the strip was not pressed because the bank could not be
    /// shown to be the one the strip index names. `write_attempted: false` is about the strip
    /// write; the bank presses sent are counted separately in `bank_presses_sent`.
    private func bankWalkRefusal(
        operation: String,
        track: Int,
        strip: Int,
        requested: Int,
        out: BankWalkLeg,
        back: BankWalkLeg,
        reason: String
    ) async -> ChannelResult {
        var extras = bankWalkExtras(requested: requested, out: out, back: back)
        extras["write_attempted"] = false
        extras["operation"] = operation
        extras["channel"] = "MCU"
        extras["track"] = track
        extras["readback_source"] = Self.bankWindowVerifySource
        for (k, v) in await mcuConnectionExtras() { extras[k] = v }
        let home: String
        if out.windowMoves == 0 {
            home = "No bank step moved, so there was nothing to walk back."
        } else if back.banksMoved == out.windowMoves {
            home = "The \(out.windowMoves) bank step(s) that moved were walked back."
        } else {
            home = "Walking back, \(back.banksMoved) of \(out.windowMoves) step(s) moved, so the MCU window "
                + "may not be where it was; bank_bookkeeping_after is the bank the verified steps reached."
        }
        let hint = "\(operation): strip \(strip) was not pressed for track \(track): \(reason). \(home) "
            + "Another channel may still do it."
        return .error(HonestContract.encodeStateC(error: .bankWalkUnverified, hint: hint, extras: extras))
    }
}
