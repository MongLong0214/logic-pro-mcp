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

        init(
            readVolume: @escaping @Sendable (Int) async -> Double?,
            readPan: @escaping @Sendable (Int) async -> Double?,
            readAutomationMode: @escaping @Sendable (Int) async -> AutomationMode? = { _ in nil },
            readSelectedTrack: @escaping @Sendable () async -> Int? = { nil }
        ) {
            self.readVolume = readVolume
            self.readPan = readPan
            self.readAutomationMode = readAutomationMode
            self.readSelectedTrack = readSelectedTrack
        }
    }

    private let transport: any MCUTransportProtocol
    private let cache: StateCache
    private let feedbackParser: MCUFeedbackParser
    private let axReadback: AXReadback?
    private(set) var currentBank: Int = 0
    private var bankingQueue: [CheckedContinuation<Void, Never>] = []
    private var isBanking: Bool = false

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
        axReadback: AXReadback? = nil
    ) {
        self.transport = transport
        self.cache = cache
        self.axReadback = axReadback
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
        let age = conn.lastFeedbackAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let stale = age > 5.0
        let registered = conn.registeredAsDevice ? "device registration confirmed" : "MIDI feedback active, device registration not confirmed"
        let detail = stale
            ? "MCU \(registered), feedback stale (\(Int(age))s)"
            : "MCU \(registered), feedback active"
        return .healthy(latencyMs: nil, detail: detail + workBudgetDetail)
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

        return await withBanking(targetTrack: track) { strip in
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

        return await withBanking(targetTrack: track) { strip in
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

    private func sendTransport(_ command: MCUProtocol.TransportCommand) async -> ChannelResult {
        let bytes = MCUProtocol.encodeTransport(command)
        await transport.send(bytes)
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

        return await withBanking(targetTrack: track) { strip in
            let bytes = MCUProtocol.encodeButton(function, strip: strip, on: enabled)
            await self.transport.send(bytes)
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

        return await withBanking(targetTrack: track) { strip in
            await self.transport.send(MCUProtocol.encodeButton(.select, strip: strip, on: true))
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

            await self.transport.send(MCUProtocol.encodeButton(function, on: true))
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

    // MARK: - Banking (Proper Queue)

    private func withBanking(targetTrack: Int, operation: @escaping (Int) async -> ChannelResult) async -> ChannelResult {
        // Sanity cap: real Logic projects rarely exceed 256 tracks (32 MCU banks).
        // A `track.select {index: 99999}` was seen to spend 25 s walking 12499
        // bank-right presses then restoring — far past any client timeout. Reject
        // up front rather than burning that time.
        guard (0...255).contains(targetTrack) else {
            return .error("MCU bank target track \(targetTrack) out of range (0..255)")
        }
        let targetBank = targetTrack / 8
        let strip = targetTrack % 8

        if targetBank == currentBank {
            return await operation(strip)
        }

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
        let originalBank = currentBank

        // Bank to target
        let bankDelta = targetBank - currentBank
        let bankButton: MCUProtocol.ButtonFunction = bankDelta > 0 ? .bankRight : .bankLeft
        for _ in 0..<abs(bankDelta) {
            await transport.send(MCUProtocol.encodeButton(bankButton, on: true))
            try? await Task.sleep(for: .milliseconds(1))
        }
        currentBank = targetBank

        // Execute on target bank
        let result = await operation(strip)

        // Restore original bank
        let restoreDelta = originalBank - currentBank
        let restoreButton: MCUProtocol.ButtonFunction = restoreDelta > 0 ? .bankRight : .bankLeft
        for _ in 0..<abs(restoreDelta) {
            await transport.send(MCUProtocol.encodeButton(restoreButton, on: true))
            try? await Task.sleep(for: .milliseconds(1))
        }
        currentBank = originalBank

        // defer handles: isBanking = false + queue wake
        return result
    }
}
