import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #288 R2: in-process microbenchmark for ADR-005 operation-trace overhead.
///
/// This is deliberately NOT a live-AX loop — AX round-trip latency (tens of
/// milliseconds) swamps microsecond-scale tracing cost, so a live loop cannot
/// resolve the trace machinery's own overhead. Instead this drives the REAL
/// dispatch path — `TransportDispatcher.handle(command: "set_tempo", ...)` —
/// through a fake `.accessibility` channel that answers instantly, isolating
/// the cost of:
///   `startTraceIfEnabled` → `OperationTraceContext.record` (×N via
///   `router.route`) → `finalizeTrace` → `OperationTraceStore` actor hops.
///
/// Confirmed real (not a stub): `TransportDispatcher.handle` "set_tempo" calls
/// `startTraceIfEnabled` (DispatcherSupport.swift:242) which calls
/// `OperationTraceStore.shared.start`/`.record` (OperationTrace.swift:232,253);
/// `router.route` (ChannelRouter.swift:104) records `.routeEvaluated`,
/// `.channelStarted`, `.channelCompleted` via `OperationTraceContext.record`
/// (OperationTrace.swift:112), which forwards to the same
/// `OperationTraceStore.shared.record`; `OperationTraceWriteBoundaryArm
/// .commitIfArmed` (OperationTrace.swift:48) records `.writeBoundaryCrossed`;
/// `finalizeTrace` (DispatcherSupport.swift:309) records
/// `.verificationCompleted` + `.resultEmitted` and calls `.complete`. Every one
/// of those is the production `actor OperationTraceStore` — no mock/stub store
/// is substituted anywhere in this file.
private actor OperationTraceOverheadChannel: Channel {
    nonisolated let id: ChannelID

    init(id: ChannelID) {
        self.id = id
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        .success("ok")
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "operation trace overhead bench")
    }
}

extension OperationTraceTests {
    /// Deliverable: per-op trace overhead in µs = (tracedTotal - untracedTotal) / N.
    /// The `< 500µs` assertion is a SANITY CEILING for regression-guard purposes
    /// only — the absolute measured number below is the actual #288 R2 input,
    /// not this threshold. Do not tighten this into a flaky perf gate.
    @Test func OperationTraceOverheadMicrobench() async throws {
        let router = ChannelRouter()
        await router.register(OperationTraceOverheadChannel(id: .accessibility))
        let cache = StateCache()
        let iterations = 10_000
        let params: [String: Value] = ["tempo": .double(120)]

        // Every iteration goes through a real mutation-gate-shaped context
        // (mutationGateAcquired: true) so the traced run exercises the
        // mutationGateWaitStarted/Acquired phases too, not just the
        // unconditional request/route/channel/result phases.
        func runDispatch() async {
            let traceContext = OperationTraceContext(mutationGateAcquired: true)
            _ = await OperationTraceContext.$current.withValue(traceContext) {
                await TransportDispatcher.handle(
                    command: "set_tempo",
                    params: params,
                    router: router,
                    cache: cache,
                    sleep: { _ in }
                )
            }
        }

        // Warm up (JIT/allocator steady state) outside both timed windows.
        for _ in 0..<200 {
            await FeatureFlags.withAdr005OperationTraceForTests(false) {
                await runDispatch()
            }
        }

        let offStart = ContinuousClock.now
        for _ in 0..<iterations {
            await FeatureFlags.withAdr005OperationTraceForTests(false) {
                await runDispatch()
            }
        }
        let offElapsed = ContinuousClock.now - offStart

        for _ in 0..<200 {
            await FeatureFlags.withAdr005OperationTraceForTests(true) {
                await runDispatch()
            }
            await OperationTraceStore.shared.clear()
        }

        let onStart = ContinuousClock.now
        for _ in 0..<iterations {
            await FeatureFlags.withAdr005OperationTraceForTests(true) {
                await runDispatch()
            }
            // Keep the store from growing unbounded across 10k traced runs;
            // eviction would otherwise kick in mid-measurement and skew later
            // iterations relative to earlier ones.
            await OperationTraceStore.shared.clear()
        }
        let onElapsed = ContinuousClock.now - onStart

        let offMicros = Double(offElapsed.components.seconds) * 1_000_000
            + Double(offElapsed.components.attoseconds) / 1_000_000_000_000
        let onMicros = Double(onElapsed.components.seconds) * 1_000_000
            + Double(onElapsed.components.attoseconds) / 1_000_000_000_000
        let perOpOverheadMicros = (onMicros - offMicros) / Double(iterations)

        // The absolute number is the #288 R2 deliverable — printed so it shows
        // in test output; the #expect below is a loose anti-regression ceiling.
        print(
            "OperationTraceOverheadMicrobench: N=\(iterations) "
                + "off_total_us=\(String(format: "%.1f", offMicros)) "
                + "on_total_us=\(String(format: "%.1f", onMicros)) "
                + "per_op_overhead_us=\(String(format: "%.2f", perOpOverheadMicros))"
        )

        #expect(
            perOpOverheadMicros < 500,
            Comment(rawValue: "trace overhead regression: \(perOpOverheadMicros)µs/op exceeds 500µs sanity ceiling (off=\(offMicros)µs on=\(onMicros)µs, N=\(iterations))")
        )

        await OperationTraceStore.shared.clear()
    }
}
