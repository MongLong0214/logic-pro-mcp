import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// Records every routed operation and answers State A so no census call can
/// reach a real channel or produce a side effect.
private actor CensusProbeChannel: Channel {
    nonisolated let id: ChannelID

    init(id: ChannelID) {
        self.id = id
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        .success(HonestContract.encodeStateA(extras: ["operation": operation]))
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "dispatch census probe")
    }
}

@Suite("Executable dispatch census", .serialized)
struct OperationDispatchCensusTests {
    /// PRD-002: every registered operation must reach a REAL dispatcher
    /// switch case. Set comparisons cannot prove that — a hand-written or
    /// derived command set can claim commands the switch never handles, and
    /// the strict-parameter census rejects at the server layer BEFORE
    /// dispatch, so it cannot catch a missing case either. This census
    /// invokes the actual bound handler for every spec and fails if any
    /// command falls through to a dispatcher's unknown-command envelope
    /// ("Unknown <tool> command: …"). Side-effect safety: every channel is a
    /// probe, the project lifecycle executor is stubbed through the
    /// dependencies seam, and the support-bundle exporter throws.
    @Test func everyRegisteredOperationReachesARealDispatchCase() async throws {
        let router = ChannelRouter()
        for id in ChannelID.allCases {
            await router.register(CensusProbeChannel(id: id))
        }
        let cache = StateCache()
        let dependencies = HandlerDependencies(
            router: router,
            cache: cache,
            targetRegistry: TargetRegistry(),
            poller: StatePoller(
                axChannel: AccessibilityChannel(),
                cache: cache,
                runtime: .fastTest
            ),
            dialogPresent: { false },
            supportBundleExporter: { _, _ in
                throw NSError(domain: "dispatch-census", code: 1)
            },
            projectLifecycleExecute: { _ in
                ProjectDispatcher.LifecycleExecution(
                    executionError: nil,
                    timedOut: false,
                    terminationStatus: 0,
                    stderrOutput: ""
                )
            }
        )

        for spec in OperationRegistry.specs {
            let handler = try #require(
                OperationHandlerRegistry.handler(for: spec.id),
                Comment(rawValue: "\(spec.id.rawValue) has no bound handler")
            )
            let result = await handler(dependencies, [:])
            guard case .text(let text, _, _) = result.content.first else {
                continue
            }
            let fellThrough = text.contains("Unknown ") && text.contains(" command: ")
            #expect(
                !fellThrough,
                Comment(rawValue: "\(spec.id.rawValue) fell through to the unknown-command envelope: \(text.prefix(120))")
            )
        }
    }

    /// The derived handled-command sets are definitionally registry-equal —
    /// pinned so a future hand-written override reintroducing drift fails.
    @Test func handledCommandSetsAreRegistryDerived() {
        let expectations: [(ToolID, Set<String>)] = [
            (.logicTransport, TransportDispatcher.handledCommands),
            (.logicMixer, MixerDispatcher.handledCommands),
            (.logicNavigate, NavigateDispatcher.handledCommands),
            (.logicAudio, AudioDispatcher.handledCommands),
            (.logicSystem, SystemDispatcher.handledCommands),
            (.logicPlugins, PluginsDispatcher.handledCommands),
            (.logicEdit, EditDispatcher.handledCommands),
            (.logicProject, ProjectDispatcher.handledCommands),
            (.logicMidi, MIDIDispatcher.handledCommands),
            (.logicTracks, TrackDispatcher.handledCommands),
        ]
        for (tool, handled) in expectations {
            #expect(
                handled == OperationRegistry.commands(for: tool),
                Comment(rawValue: tool.rawValue)
            )
        }
    }
}
