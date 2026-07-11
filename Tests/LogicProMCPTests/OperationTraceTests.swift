import Foundation
import Testing
@testable import LogicProMCP

private let operationTraceFlagKey = "LOGIC_MCP_ADR005_OPERATION_TRACE"

private func replaceOperationTraceFlag(with value: String?) -> String? {
    let previous: String?
    if let current = getenv(operationTraceFlagKey) {
        previous = String(cString: current)
    } else {
        previous = nil
    }
    if let value {
        setenv(operationTraceFlagKey, value, 1)
    } else {
        unsetenv(operationTraceFlagKey)
    }
    return previous
}

private actor OperationTraceTransportChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    private var states: [String]
    private(set) var executedOperations: [String] = []

    init(states: [String]) {
        self.states = states
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOperations.append(operation)
        guard operation == "transport.get_state" else {
            return .success("Mock: \(operation)")
        }
        guard !states.isEmpty else { return .error("state unavailable") }
        return .success(states.count > 1 ? states.removeFirst() : states[0])
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "operation trace transport test")
    }
}

@Suite(.serialized)
struct OperationTraceTests {
    @Test func OperationTraceTransportFlagOff() async {
        let previous = replaceOperationTraceFlag(with: nil)
        defer { _ = replaceOperationTraceFlag(with: previous) }

        let router = ChannelRouter()
        await router.register(MockChannel(id: .accessibility))

        let result = await TransportDispatcher.handle(
            command: "play",
            params: [:],
            router: router,
            cache: StateCache(),
            sleep: { _ in }
        )

        let expected = #"{"operation":"transport.play","poll_attempts":12,"reason":"readback_unavailable","state":"B","success":true,"verified":false,"verify_source":"transport_state","write_attempted":true,"write_result":"Mock: transport.play"}"#
        #expect(sharedToolText(result) == expected)
        #expect(result.isError == true)
        #expect(!expected.contains("trace_id"))
    }

    @Test func OperationTraceStoreFIFO() async {
        let store = OperationTraceStore(maximumTraceCount: 128, maximumBytes: 8 * 1024 * 1024)
        var ids: [TraceID] = []
        for _ in 0..<129 {
            let id = await store.start(operationID: OperationID.transportPlay.rawValue)
            ids.append(id)
            await store.complete(id)
        }

        let recent = await store.recent(limit: 200)
        #expect(recent.count == 128)
        #expect(recent.first?.traceID == ids.last)
        #expect(recent.last?.traceID == ids[1])
        #expect(await store.trace(ids[0]) == nil)
        #expect(ids.allSatisfy {
            $0.rawValue.hasPrefix("lpmcp_")
                && UUID(uuidString: String($0.rawValue.dropFirst("lpmcp_".count))) != nil
        })
    }

    @Test func OperationTraceStorePrivacy() async throws {
        let store = OperationTraceStore(maximumTraceCount: 2, maximumBytes: 8 * 1024)
        let id = await store.start(operationID: OperationID.transportPlay.rawValue)
        await store.record(id, phase: .requestReceived, attributes: [
            "operation_id": OperationID.transportPlay.rawValue,
            "command": "play",
            "target_ref": "opaque-sentinel",
            "project_path_hash": "hash-sentinel",
            "readback_state": "A",
            "error_code": "none",
            "unknown_key": "sentinel",
            "project_path": "sentinel",
            "prompt": "sentinel",
            "token": "sentinel",
            "environment": "sentinel",
        ])

        let trace = try #require(await store.trace(id))
        let event = try #require(trace.events.first)
        #expect(Set(event.attributes.keys) == [
            "operation_id", "command", "target_ref", "project_path_hash",
            "readback_state", "error_code",
        ])
        #expect(event.privacyClasses["project_path_hash"] == .hashed)
        #expect(event.attributes["unknown_key"] == nil)
        #expect(event.attributes["project_path"] == nil)
        #expect(event.attributes["prompt"] == nil)
        #expect(event.attributes["token"] == nil)
        #expect(event.attributes["environment"] == nil)
    }

    @Test func OperationTraceStoreByteBudget() async {
        let store = OperationTraceStore(maximumTraceCount: 128, maximumBytes: 512)
        let first = await store.start(operationID: OperationID.transportPlay.rawValue)
        await store.record(first, phase: .requestReceived, attributes: ["command": "play"])
        await store.complete(first)

        let oversized = await store.start(operationID: OperationID.transportRecord.rawValue)
        await store.record(
            oversized,
            phase: .requestReceived,
            attributes: ["command": String(repeating: "x", count: 1_024)]
        )
        await store.complete(oversized)

        #expect(await store.recent(limit: 128).count <= 1)
        #expect(await store.trace(oversized) == nil)
    }

    @Test func OperationTraceTransportEnabled() async throws {
        let previous = replaceOperationTraceFlag(with: "1")
        defer { _ = replaceOperationTraceFlag(with: previous) }
        await OperationTraceStore.shared.clear()

        let channel = OperationTraceTransportChannel(states: [
            #"{"isPlaying":false,"isRecording":false,"position":"1.1.1.1","tempo":120}"#,
            #"{"isPlaying":true,"isRecording":false,"position":"1.1.1.1","tempo":120}"#,
        ])
        let router = ChannelRouter()
        await router.register(channel)

        let result = await TransportDispatcher.handle(
            command: "play",
            params: [:],
            router: router,
            cache: StateCache(),
            sleep: { _ in }
        )

        let resultObject = try #require(sharedJSONObject(sharedToolText(result)))
        let rawID = try #require(resultObject["trace_id"] as? String)
        let trace = try #require(await OperationTraceStore.shared.trace(TraceID(rawValue: rawID)))
        #expect(result.isError == false)
        #expect(trace.operationID == OperationID.transportPlay.rawValue)
        #expect(trace.events.map(\.phase) == [
            .requestReceived, .writeBoundaryCrossed, .verificationCompleted, .resultEmitted,
        ])
        #expect(trace.events[2].attributes["readback_state"] == "A")
        #expect(trace.completedAt != nil)
        #expect(await channel.executedOperations == [
            "transport.get_state", "transport.play", "transport.get_state",
        ])
    }

    @Test func OperationTraceTransportNoWrite() async throws {
        let previous = replaceOperationTraceFlag(with: "1")
        defer { _ = replaceOperationTraceFlag(with: previous) }
        await OperationTraceStore.shared.clear()

        let channel = OperationTraceTransportChannel(states: [
            #"{"isPlaying":false,"isRecording":false,"position":"1.1.1.1","tempo":120}"#,
        ])
        let router = ChannelRouter()
        await router.register(channel)

        let result = await TransportDispatcher.handle(
            command: "stop",
            params: [:],
            router: router,
            cache: StateCache(),
            sleep: { _ in }
        )

        let resultObject = try #require(sharedJSONObject(sharedToolText(result)))
        let rawID = try #require(resultObject["trace_id"] as? String)
        let trace = try #require(await OperationTraceStore.shared.trace(TraceID(rawValue: rawID)))
        #expect(!trace.events.map(\.phase).contains(.writeBoundaryCrossed))
        #expect(trace.events.map(\.phase) == [
            .requestReceived, .verificationCompleted, .resultEmitted,
        ])
        #expect(trace.events[1].attributes["readback_state"] == "A")
        #expect(await channel.executedOperations == ["transport.get_state"])
    }

    @Test func OperationTraceSystemLifecycle() async throws {
        let previous = replaceOperationTraceFlag(with: "1")
        defer { _ = replaceOperationTraceFlag(with: previous) }
        await OperationTraceStore.shared.clear()

        let id = await OperationTraceStore.shared.start(operationID: OperationID.transportPlay.rawValue)
        await OperationTraceStore.shared.record(id, phase: .requestReceived, attributes: [
            "operation_id": OperationID.transportPlay.rawValue,
            "command": "play",
            "unknown_key": "sentinel",
        ])
        await OperationTraceStore.shared.record(id, phase: .verificationCompleted, attributes: [
            "readback_state": "A",
        ])
        await OperationTraceStore.shared.record(id, phase: .resultEmitted)
        await OperationTraceStore.shared.complete(id)

        let router = ChannelRouter()
        let cache = StateCache()
        let listResult = await SystemDispatcher.handle(
            command: "list_recent_traces",
            params: ["limit": .int(999)],
            router: router,
            cache: cache
        )
        let list = try #require(sharedJSONObject(sharedToolText(listResult)))
        let summaries = try #require(list["traces"] as? [[String: Any]])
        #expect(summaries.count == 1)
        #expect(summaries[0]["trace_id"] as? String == id.rawValue)
        #expect(summaries[0]["operation_id"] as? String == OperationID.transportPlay.rawValue)
        #expect(summaries[0]["phase_count"] as? Int == 3)
        #expect(summaries[0]["readback_state"] as? String == "A")

        let zeroResult = await SystemDispatcher.handle(
            command: "list_recent_traces",
            params: ["limit": .int(-4)],
            router: router,
            cache: cache
        )
        #expect((sharedJSONObject(sharedToolText(zeroResult))?["traces"] as? [Any])?.isEmpty == true)

        let getResult = await SystemDispatcher.handle(
            command: "get_trace",
            params: ["trace_id": .string(id.rawValue)],
            router: router,
            cache: cache
        )
        let get = try #require(sharedJSONObject(sharedToolText(getResult)))
        let events = try #require(get["events"] as? [[String: Any]])
        #expect(events.map { $0["phase"] as? String } == [
            "request.received", "verification.completed", "result.emitted",
        ])
        #expect(events.allSatisfy { $0["timestamp"] is String })
        #expect((events[0]["attributes"] as? [String: String])?["unknown_key"] == nil)

        let clearResult = await SystemDispatcher.handle(
            command: "clear_traces",
            params: [:],
            router: router,
            cache: cache
        )
        #expect(sharedJSONObject(sharedToolText(clearResult))?["success"] as? Bool == true)
        #expect(await OperationTraceStore.shared.recent(limit: 128).isEmpty)
    }

    @Test func OperationTraceSystemErrors() async {
        let previous = replaceOperationTraceFlag(with: "1")
        defer { _ = replaceOperationTraceFlag(with: previous) }
        await OperationTraceStore.shared.clear()
        let router = ChannelRouter()
        let cache = StateCache()

        let missing = await SystemDispatcher.handle(
            command: "get_trace", params: [:], router: router, cache: cache
        )
        let malformed = await SystemDispatcher.handle(
            command: "get_trace",
            params: ["trace_id": .string("not-a-trace-id")],
            router: router,
            cache: cache
        )
        let unknown = await SystemDispatcher.handle(
            command: "get_trace",
            params: ["trace_id": .string("lpmcp_00000000-0000-0000-0000-000000000000")],
            router: router,
            cache: cache
        )

        #expect(missing.isError == true)
        #expect(sharedJSONObject(sharedToolText(missing))?["error"] as? String == "invalid_params")
        #expect(malformed.isError == true)
        #expect(sharedJSONObject(sharedToolText(malformed))?["error"] as? String == "invalid_params")
        #expect(unknown.isError == true)
        #expect(sharedJSONObject(sharedToolText(unknown))?["error"] as? String == "element_not_found")
    }

    @Test func OperationTraceSystemFlagOff() async {
        let previous = replaceOperationTraceFlag(with: nil)
        defer { _ = replaceOperationTraceFlag(with: previous) }
        let router = ChannelRouter()
        let cache = StateCache()

        for command in ["list_recent_traces", "get_trace", "clear_traces"] {
            let result = await SystemDispatcher.handle(
                command: command, params: [:], router: router, cache: cache
            )
            #expect(result.isError == true)
            #expect(
                sharedToolText(result)
                    == "Unknown system command: \(command). Available: health, permissions, refresh_cache, help"
            )
        }
    }
}

private actor OperationTraceMixerChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    private(set) var executedOperations: [String] = []

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOperations.append(operation)
        switch operation {
        case OperationID.mixerSetVolume.rawValue:
            return .success(
                #"{"operation":"mixer.set_volume","state":"A","success":true,"verified":true}"#
            )
        case OperationID.mixerSetPan.rawValue:
            return .success(
                #"{"operation":"mixer.set_pan","state":"A","success":true,"verified":true}"#
            )
        default:
            return .error("Unexpected mixer operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "operation trace mixer test")
    }
}

extension OperationTraceTests {
    @Test(arguments: ["set_volume", "set_pan"])
    func OperationTraceMixerFlagOff(command: String) async {
        let previous = replaceOperationTraceFlag(with: nil)
        defer { _ = replaceOperationTraceFlag(with: previous) }
        await OperationTraceStore.shared.clear()

        let channel = OperationTraceMixerChannel()
        let router = ChannelRouter()
        await router.register(channel)

        let result = await MixerDispatcher.handle(
            command: command,
            params: command == "set_volume"
                ? ["track": .int(2), "value": .double(0.5)]
                : ["track": .int(2), "value": .double(-0.25)],
            router: router,
            cache: StateCache()
        )

        let operationID = command == "set_volume"
            ? OperationID.mixerSetVolume
            : OperationID.mixerSetPan
        let expected = command == "set_volume"
            ? #"{"operation":"mixer.set_volume","state":"A","success":true,"verified":true}"#
            : #"{"operation":"mixer.set_pan","state":"A","success":true,"verified":true}"#
        #expect(sharedToolText(result) == expected)
        #expect(!expected.contains("trace_id"))
        #expect(await channel.executedOperations == [operationID.rawValue])
        #expect(await OperationTraceStore.shared.recent().isEmpty)
    }

    @Test(arguments: ["set_volume", "set_pan"])
    func OperationTraceMixerEnabled(command: String) async throws {
        let previous = replaceOperationTraceFlag(with: "1")
        defer { _ = replaceOperationTraceFlag(with: previous) }
        await OperationTraceStore.shared.clear()

        let channel = OperationTraceMixerChannel()
        let router = ChannelRouter()
        await router.register(channel)

        let result = await MixerDispatcher.handle(
            command: command,
            params: command == "set_volume"
                ? ["track": .int(2), "value": .double(0.5)]
                : ["track": .int(2), "value": .double(-0.25)],
            router: router,
            cache: StateCache()
        )

        let operationID = command == "set_volume"
            ? OperationID.mixerSetVolume
            : OperationID.mixerSetPan
        let resultObject = try #require(sharedJSONObject(sharedToolText(result)))
        let rawID = try #require(resultObject["trace_id"] as? String)
        let trace = try #require(
            await OperationTraceStore.shared.trace(TraceID(rawValue: rawID))
        )
        #expect(result.isError == false)
        #expect(trace.operationID == operationID.rawValue)
        #expect(trace.events.map(\.phase) == [
            .requestReceived, .writeBoundaryCrossed, .verificationCompleted, .resultEmitted,
        ])
        #expect(trace.events[2].attributes["readback_state"] == "A")
        #expect(trace.completedAt != nil)
        #expect(await channel.executedOperations == [operationID.rawValue])

        let allowedAttributeKeys: Set<String> = [
            "operation_id", "command", "target_ref", "project_path_hash",
            "readback_state", "error_code",
        ]
        #expect(trace.events.allSatisfy {
            Set($0.attributes.keys).isSubset(of: allowedAttributeKeys)
        })
    }

    @Test(arguments: ["set_volume", "set_pan"])
    func OperationTraceMixerInvalidParamsDoNotTrace(command: String) async {
        let previous = replaceOperationTraceFlag(with: "1")
        defer { _ = replaceOperationTraceFlag(with: previous) }
        await OperationTraceStore.shared.clear()

        let channel = OperationTraceMixerChannel()
        let router = ChannelRouter()
        await router.register(channel)

        let result = await MixerDispatcher.handle(
            command: command,
            params: ["value": .double(0.5)],
            router: router,
            cache: StateCache()
        )

        #expect(result.isError == true)
        #expect(await channel.executedOperations.isEmpty)
        #expect(await OperationTraceStore.shared.recent().isEmpty)
    }
}
