import Foundation

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
    case writeBoundaryCrossed = "write_boundary.crossed"
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
    let timestamp: ContinuousClock.Instant
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

    func clear() {
        traces.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        byteCounts.removeAll(keepingCapacity: true)
        totalBytes = 0
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
