import Foundation

enum OperationTraceParentBoundary {
    @TaskLocal static var onWriteBoundary: (@Sendable () async -> Void)?
}

/// #389: arm/commit carrier for `write_boundary.crossed`.
///
/// The phase used to be recorded by the dispatcher *before* it routed, which
/// made it a claim of intent rather than an observation: a route that resolved
/// no channel (unknown op, empty chain, unregistered/unhealthy channel, or a
/// preflight skip) still stamped a boundary it never crossed. The dispatcher now
/// only ARMS the boundary; the router COMMITS it at the first channel that is
/// actually dispatched, so the phase can only appear when a channel executed.
///
/// The arm is deliberately scoped to exactly ONE `router.route` call (see
/// `withWriteBoundaryArmed`) and is cleared on scope exit whether or not the
/// commit fired. A sticky, op-lifetime arm is FORBIDDEN: dispatchers that read
/// before they write (the `toggle_metronome` read-then-write class) would commit
/// the boundary onto the *pre-read's* channel.started — a false boundary earlier
/// than the write. TaskLocal scoping makes that structurally impossible instead
/// of relying on call-site ordering staying as it is today.
final class OperationTraceWriteBoundaryArm: @unchecked Sendable {
    /// Sibling TaskLocal, never state on `ChannelRouter` (a shared actor would
    /// leak arms across concurrent ops) nor on `OperationTraceStore`.
    @TaskLocal static var current: OperationTraceWriteBoundaryArm?

    private let lock = NSLock()
    private let traceID: TraceID?
    private var committed = false

    init(traceID: TraceID?) {
        self.traceID = traceID
    }

    /// Once-commit bit: true for the first armed channel.started only, so a
    /// fallback chain that retries on a second channel records one boundary.
    private func claimCommit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if committed { return false }
        committed = true
        return true
    }

    /// Called by `ChannelRouter` at each channel.started. No arm (read route,
    /// or a write route outside an arm scope) means no-op.
    static func commitIfArmed() async {
        guard let arm = current, arm.claimCommit() else { return }
        // Saga parents inherit the corrected timing through the same hook the
        // pre-route emit used, so a child's first real write moves the parent
        // boundary too.
        if let onWriteBoundary = OperationTraceParentBoundary.onWriteBoundary {
            await onWriteBoundary()
        }
        // Explicit ID: `OperationTraceContext.record` no-ops when the op's
        // trace is not registered in this task's context (dispatcher-scoped
        // tests, saga children), but the boundary is still honest there.
        guard let traceID = arm.traceID else { return }
        await OperationTraceStore.shared.record(traceID, phase: .writeBoundaryCrossed)
    }

    /// Arm the boundary for the duration of `route` only.
    static func armed<T>(_ traceID: TraceID?, _ route: () async -> T) async -> T {
        await $current.withValue(OperationTraceWriteBoundaryArm(traceID: traceID)) {
            await route()
        }
    }
}

/// ADR-005: task-scoped carrier that lets deep seams (router, channels,
/// verification polls, saga) record onto the active operation trace without
/// threading a TraceID through every signature. The server opens one scope
/// per tool call (inside the deadline task — `Task.detached` severs TaskLocal
/// inheritance, so the scope must live within the detached work); the
/// dispatcher's trace start registers into it. Saga child dispatches open a
/// nested scope with a fresh box carrying the parent's trace ID so child
/// traces correlate instead of clobbering the parent registration.
final class OperationTraceContext: @unchecked Sendable {
    @TaskLocal static var current: OperationTraceContext?

    private let lock = NSLock()
    private var registeredTraceID: TraceID?

    /// Parent saga trace, set when this box scopes a saga child dispatch.
    let parentTraceID: TraceID?
    /// The server's mutation gate is try-acquire (no queueing wait); true when
    /// a claim was held for this call, letting the trace record the gate
    /// phases with honest zero-wait semantics.
    let mutationGateAcquired: Bool

    /// Whether THIS operation still owns the mutation gate. Flows to deep mutating
    /// seams (e.g. the record-arm key-command setup, #413) so they can re-check
    /// ownership immediately before each forward mutation and stop if a successor
    /// reclaimed the gate. Defaults to `{ true }` when no gate is held (read-only
    /// ops, tests) so those paths are unaffected.
    let ownsGate: @Sendable () -> Bool

    init(
        parentTraceID: TraceID? = nil,
        mutationGateAcquired: Bool = false,
        ownsGate: @escaping @Sendable () -> Bool = { true }
    ) {
        self.parentTraceID = parentTraceID
        self.mutationGateAcquired = mutationGateAcquired
        self.ownsGate = ownsGate
    }

    var traceID: TraceID? {
        lock.lock()
        defer { lock.unlock() }
        return registeredTraceID
    }

    func register(_ id: TraceID) {
        lock.lock()
        defer { lock.unlock() }
        registeredTraceID = id
    }

    /// Record a phase on the active trace, if one is registered in the current
    /// task's context. Deep seams call this without knowing whether tracing is
    /// enabled — no registered trace (flag off / read-only op) means no-op.
    static func record(
        _ phase: TracePhase,
        attributes: [String: String] = [:]
    ) async {
        guard let id = current?.traceID else { return }
        await OperationTraceStore.shared.record(id, phase: phase, attributes: attributes)
    }
}

/// #452: render a monotonic interval as integer milliseconds for a trace
/// attribute. `ContinuousClock` is used rather than a `Date` difference because
/// wall-clock can step backwards across an NTP correction, which would report a
/// segment as negative or absurdly long — and a timing number that a clock
/// adjustment can invent is not evidence.
///
/// Clamped at zero: the clock is non-decreasing, so a negative reading means the
/// measurement is unusable, not that the work was fast, and emitting it as a
/// duration would let a consumer average it into nonsense.
func elapsedMilliseconds(since start: ContinuousClock.Instant) -> String {
    let components = (ContinuousClock.now - start).components
    let milliseconds = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    return String(max(0, milliseconds))
}

struct TraceID: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init() {
        rawValue = "lpmcp_\(UUID().uuidString)"
    }

    var description: String { rawValue }

    static func isValid(_ value: String) -> Bool {
        value.hasPrefix("lpmcp_")
            && UUID(uuidString: String(value.dropFirst("lpmcp_".count))) != nil
    }
}

enum TracePhase: String, Codable, Sendable, CaseIterable {
    case requestReceived = "request.received"
    case inputValidated = "input.validated"
    case targetResolved = "target.resolved"
    case mutationGateWaitStarted = "mutation_gate.wait_started"
    case mutationGateAcquired = "mutation_gate.acquired"
    case routeEvaluated = "route.evaluated"
    case channelStarted = "channel.started"
    /// #389 — diagnostic only. Means: the first channel-execute entry under an
    /// armed write route (or, for the non-router writers, the genuine first
    /// external effect: support-bundle/export materialization and the project
    /// lifecycle AppleScript). It is NOT the HC `write_attempted` flag and NOT
    /// saga compensation input — both of those stay envelope-driven via
    /// `StepResult.writeBoundaryCrossed`, which this phase never feeds.
    ///
    /// Known residual (accepted): when an armed route's first channel fails
    /// before its effect lands and a fallback channel then succeeds, the
    /// boundary sits at the first attempt, not the channel that wrote. Moving
    /// it would need commit-inside-the-channel, which is out of scope; the
    /// phase's contract is "a channel began executing this write", not "this
    /// exact channel wrote".
    case writeBoundaryCrossed = "write_boundary.crossed"
    /// #452 — a bounded AppleScript execution finished inside a channel, carrying
    /// how long it actually took. `channel.started`/`channel.completed` bracket
    /// the whole channel call, so the segment governed by the osascript timeout
    /// was not separable from the surrounding Swift AX work; #449 could be
    /// argued about but not measured. This phase is diagnostic and additive:
    /// nothing gates on it, and it never replaces the channel bracket.
    case scriptSegmentCompleted = "script_segment.completed"
    case channelCompleted = "channel.completed"
    case verificationPoll = "verification.poll"
    case verificationCompleted = "verification.completed"
    case compensationStarted = "compensation.started"
    case resultEmitted = "result.emitted"
}

enum TracePrivacyClass: String, Codable, Sendable {
    case publicDiagnostic
    case hashed
    case presenceOnly
    case secret
}

struct TraceEvent: Sendable {
    let phase: TracePhase
    /// Monotonic capture, kept internal for deterministic ordering.
    let timestamp: ContinuousClock.Instant
    /// Wall-clock capture at record time. #388: the public `timestamp` field is
    /// serialized from THIS as ISO-8601 UTC (matching the trace-clear
    /// `cleared_at` and saga `sampled_at` receipts) — never the monotonic
    /// `Instant`, whose debug string ("Instant(_value: …)") leaked to callers.
    let wallClock: Date
    let attributes: [String: String]
    let privacyClasses: [String: TracePrivacyClass]
}

struct OperationTrace: Sendable {
    let traceID: TraceID
    let operationID: String
    let startedAt: ContinuousClock.Instant
    var events: [TraceEvent]
    var completedAt: ContinuousClock.Instant?
}

actor OperationTraceStore {
    static let shared = OperationTraceStore()
    static let defaultMaximumTraceCount = 128
    static let defaultMaximumBytes = 8 * 1024 * 1024
    static let attributePrivacyClasses: [String: TracePrivacyClass] = [
        "operation_id": .publicDiagnostic,
        "command": .publicDiagnostic,
        "target_ref": .publicDiagnostic,
        "project_path_hash": .hashed,
        "readback_state": .publicDiagnostic,
        "error_code": .publicDiagnostic,
        // ADR-005 phase wiring — all runtime-structural, never user content.
        "channel": .publicDiagnostic,
        "chain": .publicDiagnostic,
        "outcome": .publicDiagnostic,
        "parent_trace_id": .publicDiagnostic,
        "gate_mode": .publicDiagnostic,
        // #452 — measured elapsed time of a bounded AppleScript segment.
        // Undeclared keys are DROPPED by `filteredAttributes`, so an emission
        // without this row would record nothing and expose nothing. The bound it
        // ran under is deliberately NOT emitted here: the executor is injected,
        // so the call site cannot attest to a timeout it does not own.
        "applescript_duration_ms": .publicDiagnostic,
    ]

    let maximumTraceCount: Int
    let maximumBytes: Int

    private var traces: [TraceID: OperationTrace] = [:]
    private var order: [TraceID] = []
    private var byteCounts: [TraceID: Int] = [:]
    private var totalBytes = 0

    init(
        maximumTraceCount: Int = OperationTraceStore.defaultMaximumTraceCount,
        maximumBytes: Int = OperationTraceStore.defaultMaximumBytes
    ) {
        self.maximumTraceCount = max(0, maximumTraceCount)
        self.maximumBytes = max(0, maximumBytes)
    }

    func start(operationID: String) -> TraceID {
        let id = TraceID()
        let trace = OperationTrace(
            traceID: id,
            operationID: operationID,
            startedAt: .now,
            events: [],
            completedAt: nil
        )
        traces[id] = trace
        order.append(id)
        let byteCount = estimatedBytes(for: trace)
        byteCounts[id] = byteCount
        totalBytes += byteCount
        evictIfNeeded()
        if traces[id] == nil, byteCount > maximumBytes {
            Log.warn("Operation trace rejected because it exceeds the byte budget", subsystem: .server)
        }
        return id
    }

    func record(
        _ id: TraceID,
        phase: TracePhase,
        attributes: [String: String] = [:]
    ) {
        guard var trace = traces[id] else { return }
        let filtered = Self.filteredAttributes(attributes)
        trace.events.append(TraceEvent(
            phase: phase,
            timestamp: .now,
            wallClock: Date(),
            attributes: filtered.values,
            privacyClasses: filtered.privacyClasses
        ))
        replace(trace)
        evictIfNeeded()
        if traces[id] == nil {
            Log.warn("Operation trace evicted after exceeding the byte budget", subsystem: .server)
        }
    }

    func complete(_ id: TraceID) {
        guard var trace = traces[id] else { return }
        trace.completedAt = .now
        replace(trace)
        evictIfNeeded()
    }

    func trace(_ id: TraceID) -> OperationTrace? {
        traces[id]
    }

    func recent(limit: Int = OperationTraceStore.defaultMaximumTraceCount) -> [OperationTrace] {
        let count = min(max(0, limit), maximumTraceCount)
        return order.reversed().prefix(count).compactMap { traces[$0] }
    }

    /// Number of traces currently retained. `recent()` materializes the whole
    /// trace list just to count it; callers that only need the size take this.
    var traceCount: Int {
        traces.count
    }

    /// PRD-015: atomically drain every retained trace and report how many were
    /// ACTUALLY removed. A count sampled in one actor call and a `clear()` in
    /// another straddle a suspension point, so a trace started in between makes
    /// the separately-sampled number a lie. Draining and counting in a SINGLE
    /// actor call closes that window: the returned number is exactly what this
    /// call destroyed, and nothing else can interleave.
    func clearReturningCount() -> Int {
        let removed = traces.count
        traces.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        byteCounts.removeAll(keepingCapacity: true)
        totalBytes = 0
        return removed
    }

    func clear() {
        _ = clearReturningCount()
    }

    private func replace(_ trace: OperationTrace) {
        let id = trace.traceID
        totalBytes -= byteCounts[id] ?? 0
        traces[id] = trace
        let byteCount = estimatedBytes(for: trace)
        byteCounts[id] = byteCount
        totalBytes += byteCount
    }

    private func evictIfNeeded() {
        while order.count > maximumTraceCount || totalBytes > maximumBytes {
            guard let oldest = order.first else { break }
            order.removeFirst()
            traces.removeValue(forKey: oldest)
            totalBytes -= byteCounts.removeValue(forKey: oldest) ?? 0
        }
    }

    private func estimatedBytes(for trace: OperationTrace) -> Int {
        var count = trace.traceID.rawValue.utf8.count + trace.operationID.utf8.count + 64
        for event in trace.events {
            count += event.phase.rawValue.utf8.count + 96
            for (key, value) in event.attributes {
                count += key.utf8.count + value.utf8.count
                count += event.privacyClasses[key]?.rawValue.utf8.count ?? 0
            }
        }
        if trace.completedAt != nil { count += 16 }
        return count
    }

    private static func filteredAttributes(
        _ attributes: [String: String]
    ) -> (values: [String: String], privacyClasses: [String: TracePrivacyClass]) {
        var values: [String: String] = [:]
        var privacyClasses: [String: TracePrivacyClass] = [:]
        for (key, value) in attributes {
            guard let privacyClass = attributePrivacyClasses[key] else { continue }
            values[key] = value
            privacyClasses[key] = privacyClass
        }
        return (values, privacyClasses)
    }
}
