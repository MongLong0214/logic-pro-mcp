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
            // Fail closed on content shape: a dispatch outcome must be
            // inspectable text — an empty or non-text response would
            // otherwise be a silent census pass.
            let first = try #require(
                result.content.first,
                Comment(rawValue: "\(spec.id.rawValue) returned empty content")
            )
            guard case .text(let text, _, _) = first else {
                #expect(
                    Bool(false),
                    Comment(rawValue: "\(spec.id.rawValue) returned non-text first content")
                )
                continue
            }
            // Typed contract, not prose matching: a registered command that
            // reaches a dispatcher without a matching switch case produces
            // the shared unhandled_registered_command State-C envelope.
            let body = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            let fellThrough = body?["error"] as? String
                == HonestContract.FailureError.unhandledRegisteredCommand.rawValue
            #expect(
                !fellThrough,
                Comment(rawValue: "\(spec.id.rawValue) fell through to the unhandled-command envelope: \(text.prefix(120))")
            )
        }
    }

    /// The typed fallthrough envelope itself is discriminating: an
    /// out-of-registry command through a dispatcher default arm produces
    /// exactly the unhandled_registered_command code the census scans for.
    @Test func fallthroughEnvelopeCarriesTypedCode() throws {
        let result = TransportDispatcher.unhandledCommandResult(
            "no_such_command", label: "transport"
        )
        guard case .text(let text, _, _) = result.content.first else {
            #expect(Bool(false), "fallthrough must be text")
            return
        }
        let body = try #require(
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        )
        #expect(body["error"] as? String == "unhandled_registered_command")
        let v1 = try #require(result.isError)
        #expect(v1)
        let hint = try #require(body["hint"] as? String)
        #expect(hint.contains("Unknown transport command: no_such_command"))
        #expect(hint.contains("play"))
    }

    /// PRD-014: trace-operation availability is GENERATED from the feature
    /// policy — both branches of the pure derivation, plus the registry's
    /// actual value matching this process's flag state (the flag is
    /// environment-derived and process-constant, so the static registry
    /// value is decided exactly once and must agree with it).
    @Test func traceAvailabilityIsGeneratedFromFeaturePolicy() {
        #expect(OperationRegistry.traceAvailability(traceEnabled: true) == .defaultInstall)
        #expect(OperationRegistry.traceAvailability(traceEnabled: false) == .experimental)
        let expected = OperationRegistry.traceAvailability(
            traceEnabled: OperationRegistry.traceEnabledAtRegistryBuild
        )
        for id in OperationRegistry.traceOperationIDs {
            let spec = OperationRegistry.specs.first { $0.id == id }
            #expect(spec?.availability == expected, Comment(rawValue: id.rawValue))
        }
        // Non-trace system ops stay unconditionally defaultInstall.
        let health = OperationRegistry.specs.first { $0.id == .systemHealth }
        #expect(health?.availability == .defaultInstall)
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

    /// Owner product decision (2026-07-17): the release qualification matrix is
    /// DESKTOP-ONLY (Creator Studio permanently out of scope, never installed).
    /// This pins the exact required-axis set so the matrix can only change by a
    /// deliberate ship-scope edit — a variant re-entering (e.g. Creator) or a
    /// desktop locale dropping fails here. Required matrix = ship claims; the
    /// LogicVariant enum stays a full world model and must NOT auto-populate it.
    @Test func requiredMatrixIsDesktopOnlyShipScope() {
        #expect(QualificationAxis.shipVariants == [.desktop])
        #expect(Set(QualificationAxis.shipLocales) == [.enUS, .koKR])
        let axes = Set(QualificationAxis.requiredCombinations.map { "\($0.variant.rawValue)/\($0.locale.rawValue)" })
        #expect(axes == ["desktop/en-US", "desktop/ko-KR"])
        #expect(QualificationAxis.requiredCombinations.count == 2)
        // Creator must not be a ship/required variant, but must remain in the
        // enum world model for honest "not installed" health reporting.
        #expect(!QualificationAxis.requiredCombinations.contains { $0.variant == .creatorStudio })
        #expect(LogicVariant.allCases.contains(.creatorStudio))
        // Every required axis is core/cold/empty.
        for axis in QualificationAxis.requiredCombinations {
            #expect(axis.profile == .core)
            #expect(axis.cache == .cold)
            #expect(axis.fixture == .empty)
        }
    }
}
