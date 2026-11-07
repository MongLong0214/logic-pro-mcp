import Dispatch
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Issue1551 record_sequence timeout boundary")
struct Issue1551RecordSequenceTimeoutTests {
    private final class ScriptProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var entered = false
        private let release = DispatchSemaphore(value: 0)

        func callAndBlock() -> ChannelResult {
            lock.withLock {
                calls += 1
                entered = true
            }
            release.wait()
            return .success("OK")
        }

        func call() -> ChannelResult {
            lock.withLock { calls += 1 }
            return .success("OK")
        }

        func unblock() { release.signal() }
        var callCount: Int { lock.withLock { calls } }
        var hasEntered: Bool { lock.withLock { entered } }
    }

    private final class ReadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private let release = DispatchSemaphore(value: 0)

        func enterAndBlock() {
            lock.withLock { entered = true }
            release.wait()
        }

        func unblock() { release.signal() }
        var hasEntered: Bool { lock.withLock { entered } }
    }

    private func temporaryMIDIFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue1551-\(UUID().uuidString).mid")
        try Data([0x4D, 0x54, 0x68, 0x64]).write(to: url)
        return url
    }

    private func importMIDI(
        path: String,
        regionInfos: @escaping @Sendable () -> AccessibilityChannel.MIDIImportRegionReadback = {
            .success([], complete: true)
        },
        executeScript: @escaping @Sendable (String) async -> ChannelResult
    ) async -> ChannelResult {
        await AccessibilityChannel.defaultImportMIDIFile(
            systemEventsAuthorized: { true },
            path: path,
            executeScript: executeScript,
            trackCount: { 0 },
            trackNames: { [] },
            regionInfos: regionInfos,
            deltaPoll: {}
        )
    }

    private func json(_ result: CallTool.Result) -> [String: Any]? {
        sharedJSONObject(sharedToolText(result))
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    @Test("an already-cancelled import task never starts the script")
    func cancelledTaskStopsBeforeImportScript() async throws {
        let midiFile = try temporaryMIDIFile()
        defer { try? FileManager.default.removeItem(at: midiFile) }
        let script = ScriptProbe()

        let task = Task {
            await importMIDI(path: midiFile.path) { _ in script.call() }
        }
        task.cancel()
        let result = await task.value

        #expect(script.callCount == 0)
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["error"] as? String == HonestContract.FailureError.cancelled.rawValue)
        #expect(body["failure_stage"] as? String == "before_import_script")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        let importStarted = try #require(body["import_started"] as? Bool)
        let safeToRetry = try #require(body["safe_to_retry"] as? Bool)
        #expect(!writeAttempted)
        #expect(!importStarted)
        #expect(safeToRetry)
    }

    @Test("a deadline that wins during pre-import readback prevents the later script")
    func deadlineBeforeImportScriptPreventsLateWrite() async throws {
        let midiFile = try temporaryMIDIFile()
        defer { try? FileManager.default.removeItem(at: midiFile) }
        let script = ScriptProbe()
        let read = ReadProbe()

        let resultTask = Task {
            await LogicProServer.runWithDeadline(
                tool: "logic_tracks",
                command: "record_sequence",
                deadlineOverride: 0.25
            ) {
                await importMIDI(
                    path: midiFile.path,
                    regionInfos: {
                        read.enterAndBlock()
                        return .success([], complete: true)
                    },
                    executeScript: { _ in script.call() }
                ).asToolResult
            }
        }

        #expect(try await waitUntil { read.hasEntered })
        let result = await resultTask.value
        let body = try #require(json(result))
        #expect(body["error"] as? String == HonestContract.FailureError.operationTimeout.rawValue)
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        let importStarted = try #require(body["import_started"] as? Bool)
        let futureWritesBlocked = try #require(body["future_writes_blocked"] as? Bool)
        #expect(!writeAttempted)
        #expect(!importStarted)
        #expect(futureWritesBlocked)
        read.unblock()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(script.callCount == 0)
    }

    @Test("a deadline after import starts warns that a track and region may appear")
    func deadlineAfterImportStartIsTruthful() async throws {
        let midiFile = try temporaryMIDIFile()
        defer { try? FileManager.default.removeItem(at: midiFile) }
        let script = ScriptProbe()

        let resultTask = Task {
            await LogicProServer.runWithDeadline(
                tool: "logic_tracks",
                command: "record_sequence",
                deadlineOverride: 0.25
            ) {
                await importMIDI(path: midiFile.path) { _ in script.callAndBlock() }.asToolResult
            }
        }

        #expect(try await waitUntil { script.hasEntered })
        let result = await resultTask.value
        script.unblock()

        let body = try #require(json(result))
        #expect(body["error"] as? String == HonestContract.FailureError.operationTimeout.rawValue)
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        let importStarted = try #require(body["import_started"] as? Bool)
        let underlyingOperationStopped = try #require(body["underlying_operation_stopped"] as? Bool)
        let safeToRetry = try #require(body["safe_to_retry"] as? Bool)
        let futureWritesBlocked = try #require(body["future_writes_blocked"] as? Bool)
        #expect(writeAttempted)
        #expect(importStarted)
        #expect(!underlyingOperationStopped)
        #expect(!safeToRetry)
        #expect(futureWritesBlocked)
        let hint = try #require(body["hint"] as? String)
        #expect(hint.localizedCaseInsensitiveContains("track"))
        #expect(hint.localizedCaseInsensitiveContains("region"))
        #expect(!hint.localizedCaseInsensitiveContains("abandoned"))
    }

    @Test("a lost deadline boundary prevents a later routed write")
    func lostBoundaryPreventsRelocationWrite() async throws {
        let router = ChannelRouter()
        let channel = StaticResultChannel(
            id: .accessibility,
            results: ["transport.goto_position": .success("unexpected write")]
        )
        await router.register(channel)
        let context = OperationTraceContext(claimDeadlineEffect: { _ in false })

        let result = await OperationTraceContext.$current.withValue(context) {
            await OperationTraceWriteBoundaryArm.armed(
                nil,
                deadlineStage: "relocation_playhead"
            ) {
                await router.route(operation: "transport.goto_position", params: ["bar": "1"])
            }
        }

        #expect(!result.isSuccess)
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["error"] as? String == HonestContract.FailureError.cancelled.rawValue)
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(await channel.executedOps.isEmpty)
    }
}

private extension ChannelResult {
    var asToolResult: CallTool.Result {
        switch self {
        case .success(let message): toolTextResult(message)
        case .error(let message): toolTextResult(message, isError: true)
        }
    }
}
