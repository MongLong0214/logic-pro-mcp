import Dispatch
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Issue1565 mutation deadline boundary")
struct Issue1565MutationDeadlineBoundaryTests {
    private final class BlockingProbe: @unchecked Sendable {
        private let stateLock = NSLock()
        private var entered = false
        private let release = DispatchSemaphore(value: 0)

        func enterAndBlock() {
            stateLock.withLock { entered = true }
            release.wait()
        }

        var hasEntered: Bool { stateLock.withLock { entered } }
        func unblock() { release.signal() }
    }

    private actor BlockingExecuteChannel: Channel {
        nonisolated let id = ChannelID.accessibility
        private let probe: BlockingProbe

        init(probe: BlockingProbe) {
            self.probe = probe
        }

        func start() async throws {}
        func stop() async {}
        func healthCheck() async -> ChannelHealth { .healthy() }

        func execute(operation: String, params: [String: String]) async -> ChannelResult {
            probe.enterAndBlock()
            return .success("Mock: \(operation)")
        }
    }

    private actor BlockingFallbackChannel: Channel {
        nonisolated let id: ChannelID
        private let probe: BlockingProbe
        private let result: ChannelResult

        init(id: ChannelID, probe: BlockingProbe, result: ChannelResult) {
            self.id = id
            self.probe = probe
            self.result = result
        }

        func start() async throws {}
        func stop() async {}
        func healthCheck() async -> ChannelHealth { .healthy() }

        func execute(operation: String, params: [String: String]) async -> ChannelResult {
            probe.enterAndBlock()
            return result
        }
    }

    private final class CompletionProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func markCompleted() { lock.withLock { completed = true } }
        var isCompleted: Bool { lock.withLock { completed } }
    }

    private final class BooleanProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?

        func record(_ value: Bool) { lock.withLock { stored = value } }
        var value: Bool? { lock.withLock { stored } }
    }

    private final class InvocationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() { lock.withLock { count += 1 } }
        var invocationCount: Int { lock.withLock { count } }
    }

    private final class EffectAuthorizationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var allowed = true
        private var attempts = 0

        func claim() -> Bool {
            lock.withLock {
                attempts += 1
                return allowed
            }
        }

        func revoke() { lock.withLock { allowed = false } }
        var attemptCount: Int { lock.withLock { attempts } }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    private func json(_ result: CallTool.Result) -> [String: Any]? {
        sharedJSONObject(sharedToolText(result))
    }

    @Test("a deadline that wins before the first routed write prevents the late mutation")
    func deadlineBeforeBoundaryPreventsLateRoute() async throws {
        let preWrite = BlockingProbe()
        let completion = CompletionProbe()
        let router = ChannelRouter()
        let channel = StaticResultChannel(
            id: .accessibility,
            results: ["project.new": .success("unexpected late mutation")]
        )
        await router.register(channel)

        let resultTask = Task {
            await LogicProServer.runWithDeadline(
                tool: "logic_project",
                command: "new",
                deadlineOverride: 0.05,
                mutationGate: LogicMutationGate()
            ) {
                preWrite.enterAndBlock()
                let routed = await OperationTraceWriteBoundaryArm.armed(nil) {
                    await router.route(operation: "project.new")
                }
                completion.markCompleted()
                return routed.asToolResult
            }
        }

        #expect(try await waitUntil { preWrite.hasEntered })
        let result = await resultTask.value
        preWrite.unblock()
        #expect(try await waitUntil { completion.isCompleted })

        let body = try #require(json(result))
        #expect(body["error"] as? String == HonestContract.FailureError.operationTimeout.rawValue)
        #expect(!(try #require(body["write_attempted"] as? Bool)))
        #expect(try #require(body["future_writes_blocked"] as? Bool))
        #expect(await channel.executedOps.isEmpty)
    }

    @Test("a timeout after the routed write boundary reports an unknown effect")
    func timeoutAfterBoundaryReportsUnknownEffect() async throws {
        let executing = BlockingProbe()
        let router = ChannelRouter()
        await router.register(BlockingExecuteChannel(probe: executing))

        let resultTask = Task {
            await LogicProServer.runWithDeadline(
                tool: "logic_project",
                command: "new",
                deadlineOverride: 0.05,
                mutationGate: LogicMutationGate()
            ) {
                let routed = await OperationTraceWriteBoundaryArm.armed(nil) {
                    await router.route(operation: "project.new")
                }
                return routed.asToolResult
            }
        }

        #expect(try await waitUntil { executing.hasEntered })
        let result = await resultTask.value
        executing.unblock()

        let body = try #require(json(result))
        #expect(body["error"] as? String == HonestContract.FailureError.operationTimeout.rawValue)
        #expect(try #require(body["write_attempted"] as? Bool))
        #expect(try #require(body["future_writes_blocked"] as? Bool))
        #expect(!(try #require(body["safe_to_retry"] as? Bool)))
        #expect(!(try #require(body["underlying_operation_stopped"] as? Bool)))
        #expect(body["last_write_boundary"] as? String == "routed_write")
    }

    @Test("a fallback channel cannot start after the first write attempt times out")
    func timeoutPreventsLateFallbackChannel() async throws {
        let firstAttempt = BlockingProbe()
        let completion = CompletionProbe()
        let fallback = StaticResultChannel(
            id: .appleScript,
            results: ["transport.play": .success("unexpected late fallback")]
        )
        let router = ChannelRouter()
        await router.register(BlockingFallbackChannel(
            id: .accessibility,
            probe: firstAttempt,
            result: .error("pre-write accessibility miss")
        ))
        await router.register(fallback)

        let resultTask = Task {
            await LogicProServer.runWithDeadline(
                tool: "logic_transport",
                command: "play",
                deadlineOverride: 0.05,
                mutationGate: LogicMutationGate()
            ) {
                let routed = await OperationTraceWriteBoundaryArm.armed(nil) {
                    await router.route(operation: "transport.play")
                }
                completion.markCompleted()
                return routed.asToolResult
            }
        }

        #expect(try await waitUntil { firstAttempt.hasEntered })
        let result = await resultTask.value
        firstAttempt.unblock()
        #expect(try await waitUntil { completion.isCompleted })

        let body = try #require(json(result))
        #expect(body["error"] as? String == HonestContract.FailureError.operationTimeout.rawValue)
        #expect(try #require(body["write_attempted"] as? Bool))
        #expect(await fallback.executedOps.isEmpty)
    }

    @Test("an already-committed arm reclaims execution permission for a fallback")
    func committedArmReclaimsFallbackPermission() async {
        let authorization = EffectAuthorizationProbe()
        let context = OperationTraceContext(
            claimDeadlineEffect: { _ in authorization.claim() },
            allowRouteAfterDeadlineEffect: { true }
        )

        let result = await OperationTraceContext.$current.withValue(context) {
            await OperationTraceWriteBoundaryArm.armed(nil) {
                let first = await OperationTraceWriteBoundaryArm.commitIfArmed()
                let advisoryCheck = OperationTraceContext.routePermittedAfterDeadlineEffect()
                authorization.revoke()
                let fallback = await OperationTraceWriteBoundaryArm.commitIfArmed()
                return (first, advisoryCheck, fallback)
            }
        }

        #expect(result.0)
        #expect(result.1)
        #expect(!result.2)
        #expect(authorization.attemptCount == 2)
    }

    @Test("a direct lifecycle effect cannot begin after its request times out")
    func timeoutPreventsLateLifecycleEffect() async throws {
        let preWrite = BlockingProbe()
        let completion = CompletionProbe()
        let invocation = InvocationProbe()

        let resultTask = Task {
            await LogicProServer.runWithDeadline(
                tool: "logic_project",
                command: "launch",
                deadlineOverride: 0.05,
                mutationGate: LogicMutationGate()
            ) {
                preWrite.enterAndBlock()
                let result = await ProjectDispatcher.handle(
                    command: "launch",
                    params: [:],
                    router: ChannelRouter(),
                    cache: StateCache(),
                    isLogicProRunning: { false },
                    executeLifecycleScript: { _ in
                        invocation.record()
                        return .init(
                            executionError: nil,
                            timedOut: false,
                            terminationStatus: 0,
                            stderrOutput: ""
                        )
                    },
                    sleep: { _ in }
                )
                completion.markCompleted()
                return result
            }
        }

        #expect(try await waitUntil { preWrite.hasEntered })
        let result = await resultTask.value
        preWrite.unblock()
        #expect(try await waitUntil { completion.isCompleted })

        let body = try #require(json(result))
        #expect(body["error"] as? String == HonestContract.FailureError.operationTimeout.rawValue)
        #expect(!(try #require(body["write_attempted"] as? Bool)))
        #expect(invocation.invocationCount == 0)
    }

    @Test("the Compressor Saga child retains its deadline effect claim")
    func compressorSagaChildRetainsDeadlineClaim() async throws {
        let preWrite = BlockingProbe()
        let claim = BooleanProbe()

        let resultTask = Task {
            let parent = OperationTraceContext(
                mutationGateAcquired: true,
                ownsGate: { true }
            )
            return await OperationTraceContext.$current.withValue(parent) {
                await CompressorParameterSaga.$testStepSeconds.withValue(0.05) {
                    await CompressorParameterSaga.bounded(command: "set_param_verified") {
                        preWrite.enterAndBlock()
                        claim.record(OperationTraceContext.claimDeadlineEffect("nested_plugin_write"))
                        return toolTextResult("late worker finished")
                    }
                }
            }
        }

        #expect(try await waitUntil { preWrite.hasEntered })
        _ = await resultTask.value
        preWrite.unblock()
        #expect(try await waitUntil { claim.value != nil })
        let claimed = try #require(claim.value as Bool?)
        #expect(!claimed)
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
