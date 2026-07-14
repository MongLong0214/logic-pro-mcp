import Foundation
import Darwin

struct QualificationDriveRequest: Sendable {
    let executableURL: URL
    let environment: [String: String]
    let expectedOperationCount: Int
}

struct QualificationHandshake: Equatable, Sendable {
    let protocolVersion: String
    let serverName: String
    let serverVersion: String

    var isValid: Bool {
        !protocolVersion.isEmpty && !serverName.isEmpty && !serverVersion.isEmpty
    }
}

struct QualificationHealth: Equatable, Sendable {
    let logicProRunning: Bool
    let logicProVersion: String
    let logicProVariant: String
    let processMetadataResolved: Bool

    var isValid: Bool {
        !logicProVersion.isEmpty && !logicProVariant.isEmpty
    }

    var identifiesLiveLogic: Bool {
        logicProRunning && processMetadataResolved && logicProVersion != "unknown"
    }
}

struct QualificationTraceEntry: Equatable, Sendable {
    let traceID: String
    let operationID: String
    let phaseCount: Int
    let readbackState: String?
}

struct QualificationTraceList: Equatable, Sendable {
    let traces: [QualificationTraceEntry]
}

struct QualificationNegativeResult: Equatable, Sendable {
    let toolIsError: Bool
    let state: String
    let error: String
    let writeAttempted: Bool
    let healthBefore: Data
    let healthAfter: Data
    let catalogBefore: Data
    let catalogAfter: Data

    var healthReadStable: Bool { healthBefore == healthAfter }
    var catalogReadStable: Bool { catalogBefore == catalogAfter }

    var isFailClosedAndStable: Bool {
        // Health warms during cache polling and MCU registration; zero-write plus a stable catalog is dispositive.
        toolIsError
            && state == "C"
            && error == "invalid_params"
            && !writeAttempted
            && catalogReadStable
    }
}

struct QualificationDriveResult: Equatable, Sendable {
    let handshake: QualificationHandshake?
    let health: QualificationHealth?
    let catalog: OperationCatalogSnapshot?
    let expectedOperationCount: Int
    let traceList: QualificationTraceList?
    let negative: QualificationNegativeResult?
    let observedLocale: String
    let failureReason: String?

    var handshakeOK: Bool { handshake?.isValid == true }
    var healthOK: Bool { health?.isValid == true && health?.identifiesLiveLogic == true }
    var catalogCountMatch: Bool {
        guard let catalog else { return false }
        return catalog.operationCount == expectedOperationCount
            && catalog.operations.count == catalog.operationCount
    }
    var traceOK: Bool { traceList != nil }
    var negativeFailclosed: Bool { negative?.isFailClosedAndStable == true }
    var allChecksPass: Bool {
        handshakeOK && healthOK && catalogCountMatch && traceOK && negativeFailclosed
    }
    var observedVariant: String {
        guard let identifier = health?.logicProVariant else { return "unknown" }
        return identifier == LogicProVariant.creatorStudio.rawValue
            ? LogicVariant.creatorStudio.rawValue
            : identifier
    }
    var logicProVersion: String { health?.logicProVersion ?? "unknown" }
    var identifiesLiveLogic: Bool { health?.identifiesLiveLogic == true }
}

enum QualificationTransportError: Error, Equatable, CustomStringConvertible, Sendable {
    case requestTimeout(phase: String)
    case nonZeroExit(status: Int32, stderr: String)
    case malformedFrame(String)
    case closedPipe(phase: String)
    case launchFailed(String)
    case protocolViolation(String)
    case shutdownTimeout
    case unimplemented

    var description: String {
        switch self {
        case .requestTimeout(let phase): "qualification_transport_timeout:\(phase)"
        case .nonZeroExit(let status, let stderr):
            "qualification_transport_nonzero_exit:\(status):\(stderr)"
        case .malformedFrame(let detail): "qualification_transport_malformed_frame:\(detail)"
        case .closedPipe(let phase): "qualification_transport_closed_pipe:\(phase)"
        case .launchFailed(let detail): "qualification_transport_launch_failed:\(detail)"
        case .protocolViolation(let detail): "qualification_transport_protocol_violation:\(detail)"
        case .shutdownTimeout: "qualification_transport_shutdown_timeout"
        case .unimplemented: "qualification_transport_unimplemented"
        }
    }
}

struct QualificationTransport: Sendable {
    let handshakeTimeout: TimeInterval
    let requestTimeout: TimeInterval
    let shutdownGrace: TimeInterval

    init(
        handshakeTimeout: TimeInterval = 45,
        requestTimeout: TimeInterval = 10,
        shutdownGrace: TimeInterval = 1
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.requestTimeout = requestTimeout
        self.shutdownGrace = shutdownGrace
    }

    static func qualificationLocaleIdentifier(_ identifier: String) -> String {
        switch Locale(identifier: identifier).language.languageCode?.identifier.lowercased() {
        case "en": QualificationLocale.enUS.rawValue
        case "ko": QualificationLocale.koKR.rawValue
        default: identifier.replacingOccurrences(of: "_", with: "-")
        }
    }

    func drive(_ request: QualificationDriveRequest) throws -> QualificationDriveResult {
        let session = QualificationSubprocessSession(
            request: request,
            requestTimeout: requestTimeout,
            shutdownGrace: shutdownGrace
        )
        try session.start()

        do {
            let handshake = try initialize(session)
            let healthBefore = try health(session, id: 2, phase: "health_before")
            let catalogBefore = try catalog(session, id: 3, phase: "catalog_before")
            let traceList = try traces(session, id: 4)
            let negativeBody = try negative(session, id: 5)
            let healthAfter = try health(session, id: 6, phase: "health_after")
            let catalogAfter = try catalog(session, id: 7, phase: "catalog_after")
            let negative = QualificationNegativeResult(
                toolIsError: negativeBody.toolIsError,
                state: negativeBody.body.state,
                error: negativeBody.body.error,
                writeAttempted: negativeBody.body.writeAttempted,
                healthBefore: healthBefore.stableData,
                healthAfter: healthAfter.stableData,
                catalogBefore: catalogBefore.stableData,
                catalogAfter: catalogAfter.stableData
            )
            let outcome = try session.shutdown()
            guard !outcome.forced else {
                throw QualificationTransportError.shutdownTimeout
            }
            guard outcome.status == 0 else {
                throw QualificationTransportError.nonZeroExit(
                    status: outcome.status,
                    stderr: session.stderrTail
                )
            }
            return QualificationDriveResult(
                handshake: handshake,
                health: healthBefore.value,
                catalog: catalogBefore.value,
                expectedOperationCount: request.expectedOperationCount,
                traceList: traceList,
                negative: negative,
                observedLocale: Self.qualificationLocaleIdentifier(Locale.current.identifier),
                failureReason: nil
            )
        } catch {
            let outcome: QualificationSubprocessSession.ShutdownOutcome
            do {
                outcome = try session.shutdown()
            } catch {
                throw error
            }
            if !outcome.forced, outcome.status != 0 {
                throw QualificationTransportError.nonZeroExit(
                    status: outcome.status,
                    stderr: session.stderrTail
                )
            }
            throw error
        }
    }

    private func initialize(_ session: QualificationSubprocessSession) throws -> QualificationHandshake {
        let result: InitializeResult = try session.request(
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": "2025-11-25",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "adr001b-qualification", "version": "1.0"],
            ],
            phase: "handshake",
            timeout: handshakeTimeout
        )
        try session.notify(method: "notifications/initialized")
        return QualificationHandshake(
            protocolVersion: result.protocolVersion,
            serverName: result.serverInfo.name,
            serverVersion: result.serverInfo.version
        )
    }

    private func health(
        _ session: QualificationSubprocessSession,
        id: Int,
        phase: String
    ) throws -> (value: QualificationHealth, stableData: Data) {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_system",
                "arguments": ["command": "health", "params": [:] as [String: Any]],
            ],
            phase: phase
        )
        guard result.isError != true else {
            throw QualificationTransportError.protocolViolation("\(phase): tool returned isError")
        }
        let text = try result.text(phase: phase)
        let wire: HealthResult = try Self.decodeInner(text, phase: phase)
        return (
            QualificationHealth(
                logicProRunning: wire.logicProRunning,
                logicProVersion: wire.logicProVersion,
                logicProVariant: wire.logicProVariant,
                processMetadataResolved: wire.processMetadataResolved
            ),
            try Self.stableHealthData(text, phase: phase)
        )
    }

    private func catalog(
        _ session: QualificationSubprocessSession,
        id: Int,
        phase: String
    ) throws -> (value: OperationCatalogSnapshot, stableData: Data) {
        let result: ResourceReadResult = try session.request(
            id: id,
            method: "resources/read",
            params: ["uri": "logic://system/operations"],
            phase: phase
        )
        guard let content = result.contents.first,
              content.uri == "logic://system/operations",
              let text = content.text else {
            throw QualificationTransportError.protocolViolation("\(phase): missing operations content")
        }
        return (
            try Self.decodeInner(text, phase: phase),
            try Self.stableCatalogData(text, phase: phase)
        )
    }

    private func traces(
        _ session: QualificationSubprocessSession,
        id: Int
    ) throws -> QualificationTraceList {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_system",
                "arguments": [
                    "command": "list_recent_traces",
                    "params": ["limit": 10],
                ],
            ],
            phase: "trace_roundtrip"
        )
        guard result.isError != true else {
            throw QualificationTransportError.protocolViolation(
                "trace_roundtrip: \(try result.text(phase: "trace_roundtrip"))"
            )
        }
        let wire: TraceListResult = try Self.decodeInner(
            result.text(phase: "trace_roundtrip"),
            phase: "trace_roundtrip"
        )
        guard wire.traceDisabled != true else {
            throw QualificationTransportError.protocolViolation("trace_roundtrip: trace_disabled")
        }
        return QualificationTraceList(traces: wire.traces.map {
            QualificationTraceEntry(
                traceID: $0.traceID,
                operationID: $0.operationID,
                phaseCount: $0.phaseCount,
                readbackState: $0.readbackState
            )
        })
    }

    private func negative(
        _ session: QualificationSubprocessSession,
        id: Int
    ) throws -> (toolIsError: Bool, body: NegativeResult) {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_tracks",
                "arguments": [
                    "command": "rename",
                    "params": ["__adr001b_no_write_probe": true],
                ],
            ],
            phase: "negative_failclosed"
        )
        let body: NegativeResult = try Self.decodeInner(
            result.text(phase: "negative_failclosed"),
            phase: "negative_failclosed"
        )
        return (result.isError == true, body)
    }

    private static func decodeInner<Value: Decodable>(
        _ text: String,
        phase: String
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(text.utf8))
        } catch {
            throw QualificationTransportError.protocolViolation("\(phase): invalid typed JSON")
        }
    }

    private static func stableHealthData(_ text: String, phase: String) throws -> Data {
        guard var object = try jsonObject(text, phase: phase) as? [String: Any] else {
            throw QualificationTransportError.protocolViolation("\(phase): health is not an object")
        }
        object.removeValue(forKey: "process")
        if var cache = object["cache"] as? [String: Any] {
            cache.removeValue(forKey: "transport_age_sec")
            object["cache"] = cache
        }
        if var mcu = object["mcu"] as? [String: Any] {
            mcu.removeValue(forKey: "last_feedback_at")
            mcu.removeValue(forKey: "feedback_stale")
            object["mcu"] = mcu
        }
        if let channels = object["channels"] as? [[String: Any]] {
            object["channels"] = channels.map { channel in
                var stable = channel
                stable.removeValue(forKey: "latency_ms")
                return stable
            }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func stableCatalogData(_ text: String, phase: String) throws -> Data {
        guard var object = try jsonObject(text, phase: phase) as? [String: Any] else {
            throw QualificationTransportError.protocolViolation("\(phase): catalog is not an object")
        }
        object.removeValue(forKey: "generated_at")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func jsonObject(_ text: String, phase: String) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: Data(text.utf8))
        } catch {
            throw QualificationTransportError.protocolViolation("\(phase): invalid JSON")
        }
    }
}

private struct InitializeResult: Decodable {
    struct ServerInfo: Decodable {
        let name: String
        let version: String
    }

    let protocolVersion: String
    let serverInfo: ServerInfo
}

private struct ToolCallResult: Decodable {
    struct Content: Decodable {
        let type: String
        let text: String?
    }

    let content: [Content]
    let isError: Bool?

    func text(phase: String) throws -> String {
        guard let content = content.first(where: { $0.type == "text" }),
              let text = content.text else {
            throw QualificationTransportError.protocolViolation("\(phase): missing text content")
        }
        return text
    }
}

private struct ResourceReadResult: Decodable {
    struct Content: Decodable {
        let uri: String
        let text: String?
    }

    let contents: [Content]
}

private struct HealthResult: Decodable {
    let logicProRunning: Bool
    let logicProVersion: String
    let logicProVariant: String
    let processMetadataResolved: Bool

    enum CodingKeys: String, CodingKey {
        case logicProRunning = "logic_pro_running"
        case logicProVersion = "logic_pro_version"
        case logicProVariant = "logic_pro_variant"
        case processMetadataResolved = "process_metadata_resolved"
    }
}

private struct TraceListResult: Decodable {
    struct Trace: Decodable {
        let traceID: String
        let operationID: String
        let phaseCount: Int
        let readbackState: String?

        enum CodingKeys: String, CodingKey {
            case traceID = "trace_id"
            case operationID = "operation_id"
            case phaseCount = "phase_count"
            case readbackState = "readback_state"
        }
    }

    let traces: [Trace]
    let traceDisabled: Bool?

    enum CodingKeys: String, CodingKey {
        case traces
        case traceDisabled = "trace_disabled"
    }
}

private struct NegativeResult: Decodable {
    let state: String
    let error: String
    let writeAttempted: Bool

    enum CodingKeys: String, CodingKey {
        case state
        case error
        case writeAttempted = "write_attempted"
    }
}

private struct RPCResponse<Result: Decodable>: Decodable {
    struct RPCError: Decodable {
        let code: Int
        let message: String
    }

    let jsonrpc: String
    let id: Int
    let result: Result?
    let error: RPCError?
}

private final class QualificationSubprocessSession: @unchecked Sendable {
    struct ShutdownOutcome {
        let status: Int32
        let forced: Bool
    }

    private let request: QualificationDriveRequest
    private let requestTimeout: TimeInterval
    private let shutdownGrace: TimeInterval
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let frames = QualificationFrameQueue()
    private let stderr = QualificationStderrBuffer()
    private let readers = DispatchGroup()
    private let exit = QualificationProcessExit()
    private let stateLock = NSLock()
    private var started = false
    private var shutdownOutcome: ShutdownOutcome?

    init(
        request: QualificationDriveRequest,
        requestTimeout: TimeInterval,
        shutdownGrace: TimeInterval
    ) {
        self.request = request
        self.requestTimeout = requestTimeout
        self.shutdownGrace = shutdownGrace
    }

    var stderrTail: String { stderr.text }

    func start() throws {
        guard FileManager.default.isExecutableFile(atPath: request.executableURL.path) else {
            throw QualificationTransportError.launchFailed("not executable: \(request.executableURL.path)")
        }
        var environment = request.environment
        environment["LOGIC_MCP_ADR002_TARGET_REF"] = "0"
        environment["LOGIC_MCP_ADR003_STRICT_PARAMS"] = "1"
        environment["LOGIC_MCP_ADR005_OPERATION_TRACE"] = "1"
        process.executableURL = request.executableURL.standardizedFileURL
        process.currentDirectoryURL = request.executableURL.deletingLastPathComponent()
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        exit.start(process)
        do {
            try process.run()
        } catch {
            throw QualificationTransportError.launchFailed(String(describing: error))
        }
        stateLock.lock()
        started = true
        stateLock.unlock()
        startReaders()
    }

    func request<Result: Decodable>(
        id: Int,
        method: String,
        params: [String: Any],
        phase: String,
        timeout: TimeInterval? = nil
    ) throws -> Result {
        try writeJSON([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ])
        let data = try frames.response(id: id, phase: phase, timeout: timeout ?? requestTimeout)
        let response: RPCResponse<Result>
        do {
            response = try JSONDecoder().decode(RPCResponse<Result>.self, from: data)
        } catch {
            throw QualificationTransportError.protocolViolation("\(phase): invalid response shape")
        }
        guard response.jsonrpc == "2.0", response.id == id else {
            throw QualificationTransportError.protocolViolation("\(phase): mismatched JSON-RPC envelope")
        }
        if let error = response.error {
            throw QualificationTransportError.protocolViolation(
                "\(phase): rpc \(error.code) \(error.message)"
            )
        }
        guard let result = response.result else {
            throw QualificationTransportError.protocolViolation("\(phase): missing result")
        }
        return result
    }

    func notify(method: String) throws {
        try writeJSON(["jsonrpc": "2.0", "method": method])
    }

    func shutdown() throws -> ShutdownOutcome {
        stateLock.lock()
        if let shutdownOutcome {
            stateLock.unlock()
            return shutdownOutcome
        }
        let didStart = started
        stateLock.unlock()
        guard didStart else { return ShutdownOutcome(status: 0, forced: false) }

        try? inputPipe.fileHandleForWriting.close()
        var forced = false
        if !exit.wait(timeout: shutdownGrace) {
            forced = true
            process.terminate()
            if !exit.wait(timeout: shutdownGrace) {
                Darwin.kill(process.processIdentifier, SIGKILL)
                guard exit.wait(timeout: shutdownGrace) else {
                    throw QualificationTransportError.shutdownTimeout
                }
            }
        }
        if readers.wait(timeout: .now() + shutdownGrace) == .timedOut {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            guard readers.wait(timeout: .now() + shutdownGrace) == .success else {
                throw QualificationTransportError.shutdownTimeout
            }
        }
        let outcome = ShutdownOutcome(status: exit.status, forced: forced)
        stateLock.lock()
        shutdownOutcome = outcome
        stateLock.unlock()
        return outcome
    }

    private func writeJSON(_ object: [String: Any]) throws {
        let data: Data
        do {
            var encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            encoded.append(0x0A)
            data = encoded
        } catch {
            throw QualificationTransportError.protocolViolation("request encoding failed")
        }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw QualificationTransportError.closedPipe(phase: "write")
        }
    }

    private func startReaders() {
        let output = outputPipe.fileHandleForReading
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async { [frames, readers] in
            defer { readers.leave() }
            var pending = Data()
            do {
                while true {
                    let chunk = output.availableData
                    guard !chunk.isEmpty else { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        if !line.isEmpty {
                            try frames.append(line)
                        }
                    }
                    if pending.count > QualificationFrameQueue.maximumFrameBytes {
                        throw QualificationTransportError.malformedFrame("frame exceeds size limit")
                    }
                }
                if pending.isEmpty {
                    frames.finish()
                } else {
                    frames.fail(QualificationTransportError.malformedFrame("unterminated frame"))
                }
            } catch {
                frames.fail(error)
            }
        }

        let error = errorPipe.fileHandleForReading
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [stderr, readers] in
            defer { readers.leave() }
            while true {
                let chunk = error.availableData
                guard !chunk.isEmpty else { break }
                stderr.append(chunk)
            }
        }
    }
}

private final class QualificationFrameQueue: @unchecked Sendable {
    static let maximumFrameBytes = 8 * 1024 * 1024

    private let condition = NSCondition()
    private var responses: [Int: Data] = [:]
    private var terminalError: Error?
    private var finished = false

    func append(_ data: Data) throws {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw QualificationTransportError.malformedFrame("top-level frame is not an object")
            }
            object = decoded
        } catch let error as QualificationTransportError {
            fail(error)
            throw error
        } catch {
            let malformed = QualificationTransportError.malformedFrame("invalid JSON")
            fail(malformed)
            throw malformed
        }
        guard object["jsonrpc"] as? String == "2.0" else {
            let malformed = QualificationTransportError.malformedFrame("missing jsonrpc 2.0")
            fail(malformed)
            throw malformed
        }
        guard let number = object["id"] as? NSNumber else {
            return
        }
        condition.lock()
        responses[number.intValue] = data
        condition.broadcast()
        condition.unlock()
    }

    func response(id: Int, phase: String, timeout: TimeInterval) throws -> Data {
        let deadline = DispatchTime.now() + timeout
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let response = responses.removeValue(forKey: id) {
                return response
            }
            if let terminalError {
                throw terminalError
            }
            if finished {
                throw QualificationTransportError.closedPipe(phase: phase)
            }
            let now = DispatchTime.now()
            guard now < deadline else {
                throw QualificationTransportError.requestTimeout(phase: phase)
            }
            let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
            _ = condition.wait(until: Date().addingTimeInterval(remaining))
        }
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func fail(_ error: Error) {
        condition.lock()
        if terminalError == nil {
            terminalError = error
        }
        condition.broadcast()
        condition.unlock()
    }
}

private final class QualificationStderrBuffer: @unchecked Sendable {
    private static let maximumBytes = 64 * 1024
    private let lock = NSLock()
    private var data = Data()

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > Self.maximumBytes {
            data.removeFirst(data.count - Self.maximumBytes)
        }
        lock.unlock()
    }
}

private final class QualificationProcessExit: @unchecked Sendable {
    private let condition = NSCondition()
    private var exited = false
    private(set) var status: Int32 = 0

    func start(_ process: Process) {
        process.terminationHandler = { [self] process in
            condition.lock()
            status = process.terminationStatus
            exited = true
            condition.broadcast()
            condition.unlock()
        }
    }

    func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !exited {
            guard condition.wait(until: deadline) else { return exited }
        }
        return true
    }
}
