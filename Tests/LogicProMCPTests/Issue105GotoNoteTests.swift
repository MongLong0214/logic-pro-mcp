import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #105: a verified goto_position/goto_bar must not ship the stale
/// "resulting playhead not read back" note — `finalizeGotoPositionResult`
/// performs an authoritative transport-state read-back and gates `verified`
/// on it, so the note (from the dialog keystroke channel) would contradict the
/// verdict. Also locks the faithful verified-vs-mismatch behavior.
@Suite("Issue105 goto note + verification")
struct Issue105GotoNoteTests {
    private static func transportState(_ position: String) -> TransportState {
        // Encode a real TransportState with the SAME .iso8601 strategy the dispatcher decodes
        // with. A hand-written fractional-seconds (".000Z") date fails strict .iso8601 decoding
        // on the CI Foundation and would turn a readable fixture into a fake failed read.
        var state = TransportState()
        state.position = position
        state.positionReadback = TransportPositionReadback(
            value: position,
            observedComponents: TransportPositionComponent.allCases
        )
        state.lastUpdated = Date(timeIntervalSince1970: 0)
        return state
    }

    private static func encodedTransportState(_ position: String) -> ChannelResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return .success(String(decoding: (try? encoder.encode(transportState(position))) ?? Data(), as: UTF8.self))
    }

    private actor StubTransportChannel: Channel {
        nonisolated let id: ChannelID = .accessibility
        let gotoResult: ChannelResult
        let readbackPosition: String
        let readbackResult: ChannelResult?
        let readbackPositions: [String]?
        let readbackResults: [ChannelResult]?
        private var readbackIndex = 0
        private var gotoExecutions = 0
        init(
            gotoResult: ChannelResult,
            readbackPosition: String,
            readbackResult: ChannelResult? = nil,
            readbackPositions: [String]? = nil,
            readbackResults: [ChannelResult]? = nil
        ) {
            self.gotoResult = gotoResult
            self.readbackPosition = readbackPosition
            self.readbackResult = readbackResult
            self.readbackPositions = readbackPositions
            self.readbackResults = readbackResults
        }
        func start() async throws {}
        func stop() async {}
        func healthCheck() async -> ChannelHealth { .healthy(detail: "stub") }
        func execute(operation: String, params: [String: String]) async -> ChannelResult {
            switch operation {
            case "transport.goto_position":
                gotoExecutions += 1
                return gotoResult
            case "transport.get_state":
                let index = min(readbackIndex, max(0, (readbackResults?.count ?? readbackPositions?.count ?? 1) - 1))
                readbackIndex += 1
                if let readbackResults { return readbackResults[index] }
                if let readbackResult { return readbackResult }
                return Issue105GotoNoteTests.encodedTransportState(
                    readbackPositions?[index] ?? readbackPosition
                )
            default: return .error("unexpected: \(operation)")
            }
        }

        func gotoExecutionCount() -> Int { gotoExecutions }
    }

    private func text(_ r: CallTool.Result) -> String {
        sharedToolText(r)
    }
    private func obj(_ r: CallTool.Result) -> [String: Any]? {
        sharedJSONObject(text(r))
    }

    /// The dialog channel's real State B output, including the historical note.
    private func notedDialogStateB(bar: Int) -> ChannelResult {
        .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: [
                "requested": "\(bar).1.1.1",
                "via": "dialog",
                "note": "AppleScript dialog OK confirms keystroke send; resulting playhead not read back",
            ]
        ))
    }

    @Test("verified goto_position drops the contradictory readback note")
    func verifiedHasNoStaleNote() async throws {
        let router = ChannelRouter()
        await router.register(StubTransportChannel(
            gotoResult: notedDialogStateB(bar: 1),
            readbackPosition: "1.1.1.1",
            readbackPositions: ["2.1.1.1", "1.1.1.1"]
        ))
        let result = await TransportDispatcher.handle(
            command: "goto_position", params: ["bar": .int(1)], router: router, cache: StateCache()
        )
        let resultIsError = result.isError ?? false
        #expect(!resultIsError)
        let o = try #require(obj(result))
        #expect((o["verified"] as? Bool)!)
        #expect(o["verification_source"] as? String == "transport_state")
        #expect(o["observed"] as? String == "1.1.1.1")
        #expect(o["note"] == nil, "verified envelope must not carry a 'not read back' note")
        #expect(!text(result).contains("not read back"))
    }

    @Test("goto_bar shares the same verified, note-free contract")
    func gotoBarNoteFree() async throws {
        let router = ChannelRouter()
        await router.register(StubTransportChannel(
            gotoResult: notedDialogStateB(bar: 17),
            readbackPosition: "17.1.1.1",
            readbackPositions: ["1.1.1.1", "17.1.1.1"]
        ))
        let result = await NavigateDispatcher.handle(
            command: "goto_bar", params: ["bar": .int(17)], router: router, cache: StateCache()
        )
        let resultIsError = result.isError ?? false
        #expect(!resultIsError)
        let o = try #require(obj(result))
        #expect((o["verified"] as? Bool)!)
        #expect(!text(result).contains("not read back"))
    }

    @Test("mismatched readback fails closed as unverified State B")
    func mismatchFailsClosed() async throws {
        let router = ChannelRouter()
        // Requested bar 1 but the playhead landed at 1.2.1.1 (the #105 symptom).
        await router.register(StubTransportChannel(
            gotoResult: notedDialogStateB(bar: 1),
            readbackPosition: "1.2.1.1",
            readbackPositions: ["2.1.1.1", "1.2.1.1"]
        ))
        let result = await TransportDispatcher.handle(
            command: "goto_position", params: ["bar": .int(1)], router: router, cache: StateCache()
        )
        let o = try #require(obj(result))
        #expect(!((o["verified"] as? Bool)!))
        #expect(o["observed"] as? String == "1.2.1.1")
        let resultIsError = result.isError ?? false
        #expect(resultIsError)
    }

    @Test("an unreadable suffix from real AX extraction cannot verify a four-component request")
    func partialAXPositionReadbackCannotReachStateA() async throws {
        // Source mutations: restore the historical four-level slider scan, restore the bar/beat
        // synthesizer `"\(barValue).\(beatValue).1.1"`, or compare `TransportState.position`
        // without its observed components in finalizeGotoPositionResult. The first misses the
        // measured Logic 12.3 topology; either latter mutation turns this partial AX readback into
        // false State A.
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1050)
        let window = builder.element(1051)
        let controlBar = builder.element(1052)
        let positionOuter = builder.element(1053)
        let positionMiddle = builder.element(1054)
        let positionInner = builder.element(1055)
        let playheadPosition = builder.element(1056)
        let positionComponents = builder.element(1057)
        let barSlider = builder.element(1058)
        let beatSlider = builder.element(1059)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [controlBar])
        builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
        // This is the measured six-level Control Bar topology from the Logic 12.3 locator
        // fixture: Control Bar → outer → middle → inner → Playhead Position → components → slider.
        builder.setChildren(controlBar, [positionOuter])
        builder.setChildren(positionOuter, [positionMiddle])
        builder.setChildren(positionMiddle, [positionInner])
        builder.setChildren(positionInner, [playheadPosition])
        builder.setAttribute(playheadPosition, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(playheadPosition, kAXDescriptionAttribute as String, "Playhead Position")
        builder.setChildren(playheadPosition, [positionComponents])
        builder.setChildren(positionComponents, [barSlider, beatSlider])
        builder.setAttribute(barSlider, kAXRoleAttribute as String, kAXSliderRole as String)
        builder.setAttribute(barSlider, kAXDescriptionAttribute as String, "Bar")
        builder.setAttribute(barSlider, kAXValueAttribute as String, NSNumber(value: 37))
        builder.setAttribute(beatSlider, kAXRoleAttribute as String, kAXSliderRole as String)
        builder.setAttribute(beatSlider, kAXDescriptionAttribute as String, "Beat")
        builder.setAttribute(beatSlider, kAXValueAttribute as String, NSNumber(value: 3))
        let runtime = builder.makeLogicRuntime(appElement: app)
        let extracted = AccessibilityChannel.defaultGetTransportState(runtime: runtime)

        let router = ChannelRouter()
        await router.register(StubTransportChannel(
            gotoResult: notedDialogStateB(bar: 37),
            readbackPosition: "37.3.1.1",
            readbackResult: extracted
        ))
        let result = await TransportDispatcher.handle(
            command: "goto_position",
            params: ["position": .string("37.3.1.1")],
            router: router,
            cache: StateCache()
        )

        let envelope = try #require(obj(result))
        #expect(!(try #require(envelope["verified"] as? Bool)))
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(try #require(envelope["reason"] as? String) == "readback_unavailable")
        #expect(try #require(envelope["observed"] as? String) == "37.3")
        let observed = try #require(envelope["observed_position_components"] as? [String])
        let unobserved = try #require(envelope["unobserved_position_components"] as? [String])
        #expect(observed == ["bar", "beat"])
        #expect(unobserved == ["subdivision", "tick"])
    }

    @Test("unreadable six-level bar and beat sliders do not become observed zeroes")
    func unreadablePositionSlidersDoNotInventObservedComponents() throws {
        // Mutations this rejects, independently:
        // - restore `barValue = Int(extractSliderValue(slider, runtime: runtime) ?? 0)`: a missing
        //   Bar paired with a readable Beat would fabricate `0.3`.
        // - restore `beatValue = Int(extractSliderValue(slider, runtime: runtime) ?? 0)`: a
        //   readable Bar paired with an invalid Beat would fabricate `37.0`.
        func positionReadback(barValue: Any?, beatValue: Any?) throws -> TransportPositionReadback? {
            let builder = FakeAXRuntimeBuilder()
            let app = builder.element(1060)
            let window = builder.element(1061)
            let controlBar = builder.element(1062)
            let positionOuter = builder.element(1063)
            let positionMiddle = builder.element(1064)
            let positionInner = builder.element(1065)
            let playheadPosition = builder.element(1066)
            let positionComponents = builder.element(1067)
            let barSlider = builder.element(1068)
            let beatSlider = builder.element(1069)
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setChildren(window, [controlBar])
            builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
            builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
            builder.setChildren(controlBar, [positionOuter])
            builder.setChildren(positionOuter, [positionMiddle])
            builder.setChildren(positionMiddle, [positionInner])
            builder.setChildren(positionInner, [playheadPosition])
            builder.setAttribute(playheadPosition, kAXRoleAttribute as String, kAXGroupRole as String)
            builder.setAttribute(playheadPosition, kAXDescriptionAttribute as String, "Playhead Position")
            builder.setChildren(playheadPosition, [positionComponents])
            builder.setChildren(positionComponents, [barSlider, beatSlider])
            builder.setAttribute(barSlider, kAXRoleAttribute as String, kAXSliderRole as String)
            builder.setAttribute(barSlider, kAXDescriptionAttribute as String, "Bar")
            builder.setAttribute(beatSlider, kAXRoleAttribute as String, kAXSliderRole as String)
            builder.setAttribute(beatSlider, kAXDescriptionAttribute as String, "Beat")
            if let barValue {
                builder.setAttribute(barSlider, kAXValueAttribute as String, barValue)
            }
            if let beatValue {
                builder.setAttribute(beatSlider, kAXValueAttribute as String, beatValue)
            }

            let extracted = AccessibilityChannel.defaultGetTransportState(
                runtime: builder.makeLogicRuntime(appElement: app)
            )
            let payload: String
            if case let .success(value) = extracted {
                payload = value
            } else {
                Issue.record("expected transport state extraction to encode successfully")
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(
                TransportState.self,
                from: try #require(payload.data(using: .utf8))
            ).positionReadback
        }

        #expect(try positionReadback(barValue: nil, beatValue: NSNumber(value: 3)) == nil)
        let unreadableBeatReadback = try positionReadback(
            barValue: NSNumber(value: 37), beatValue: "not-a-number"
        )
        let readableBarOnly = try #require(unreadableBeatReadback)
        #expect(readableBarOnly.value == "37")
        #expect(readableBarOnly.observedComponents == [.bar])
    }

    @Test("an unknown-target write is never promoted to verified by a matching playhead")
    func unknownInputTargetCannotBeVerifiedByACoincidentPlayhead() async throws {
        // The channel is honest when a global key may have gone elsewhere: State B with
        // `dialog_input_target: "unknown"` and `fallback_unsafe: true`. Finalize must not treat that
        // as "the write landed, now read it back" — if the playhead ALREADY showed the requested
        // position, a matching read proves nothing about this call.
        //
        // Concrete state: the read changed from 4.1.1.1 to 5.1.1.1, but Cmd+A may have gone to
        // another application before the child was killed. That transition is still insufficient
        // while the channel says the global input target was unknown.
        let unknownTargetEnvelope = HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: [
                "operation": "transport.goto_position",
                "method": "dialog",
                "requested": "5.1.1.1",
                "dialog_input_target": "unknown",
                "dialog_input_attempted": true,
                "write_attempted": true,
                "fallback_unsafe": true,
                "safe_to_retry": false,
            ]
        )
        let router = ChannelRouter()
        await router.register(StubTransportChannel(
            gotoResult: .success(unknownTargetEnvelope),
            readbackPosition: "5.1.1.1",
            readbackPositions: ["4.1.1.1", "5.1.1.1"]
        ))
        let result = await TransportDispatcher.handle(
            command: "goto_position",
            params: ["position": .string("5.1.1.1")],
            router: router,
            cache: StateCache()
        )
        let envelope = try #require(obj(result))
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(!(try #require(envelope["verified"] as? Bool)))
        #expect(try #require(envelope["verification_withheld"] as? String) == "dialog_input_target")
        #expect(try #require(envelope["observed"] as? String) == "5.1.1.1")
    }

    // A post-Return title/reference loss is not an observed dialog closure. The channel carries
    // `fallback_unsafe`, and a matching playhead may predate this request, so finalization must
    // preserve State B rather than falsely certifying State A.
    @Test("an unidentified post-Return dialog is never verified by a coincident playhead")
    func postReturnUnidentifiedDialogCannotBeVerifiedByACoincidentPlayhead() async throws {
        let fallbackUnsafeEnvelope = HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: [
                "operation": "transport.goto_position",
                "method": "dialog",
                "requested": "5.1.1.1",
                "dialog_route_outcome": "dialog_submission_issued_cleanup_closed_false",
                "dialog_cleanup": "unobserved",
                "dialog_submission_attempted": true,
                "write_attempted": true,
                "fallback_unsafe": true,
                "safe_to_retry": false,
            ]
        )
        let router = ChannelRouter()
        await router.register(StubTransportChannel(
            gotoResult: .success(fallbackUnsafeEnvelope),
            readbackPosition: "5.1.1.1",
            readbackPositions: ["4.1.1.1", "5.1.1.1"]
        ))
        let result = await TransportDispatcher.handle(
            command: "goto_position",
            params: ["position": .string("5.1.1.1")],
            router: router,
            cache: StateCache()
        )
        let envelope = try #require(obj(result))
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(!(try #require(envelope["verified"] as? Bool)))
        #expect(try #require(envelope["verification_withheld"] as? String) == "fallback_unsafe")
    }

    // Locks the `write_attempted_indeterminate` arm: even a measured pre/post transition is not
    // proof this call performed the write when the durable boundary itself was indeterminate.
    @Test("an indeterminate write boundary is never promoted to verified by a matching playhead")
    func indeterminateWriteBoundaryCannotBeVerifiedByACoincidentPlayhead() async throws {
        let indeterminateWriteBoundaryEnvelope = HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: [
                "operation": "transport.goto_position",
                "method": "dialog",
                "requested": "5.1.1.1",
                "dialog_input_attempted": true,
                "write_attempted": true,
                "write_attempted_indeterminate": true,
                "safe_to_retry": false,
            ]
        )
        let router = ChannelRouter()
        await router.register(StubTransportChannel(
            gotoResult: .success(indeterminateWriteBoundaryEnvelope),
            readbackPosition: "5.1.1.1",
            readbackPositions: ["4.1.1.1", "5.1.1.1"]
        ))
        let result = await TransportDispatcher.handle(
            command: "goto_position",
            params: ["position": .string("5.1.1.1")],
            router: router,
            cache: StateCache()
        )
        let envelope = try #require(obj(result))
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(!(try #require(envelope["verified"] as? Bool)))
        #expect(try #require(envelope["verification_withheld"] as? String)
            == "write_attempted_indeterminate")
    }

    @Test("a complete pre/post playhead transition verifies an ordinary dialog envelope")
    func establishedInputTargetCanBeVerifiedByAnObservedPlayheadTransition() async throws {
        let establishedTargetEnvelope = HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: [
                "operation": "transport.goto_position",
                "method": "dialog",
                "requested": "5.1.1.1",
                "dialog_input_attempted": true,
                "write_attempted": true,
                "safe_to_retry": false,
            ]
        )
        let router = ChannelRouter()
        await router.register(StubTransportChannel(
            gotoResult: .success(establishedTargetEnvelope),
            readbackPosition: "5.1.1.1",
            readbackPositions: ["4.1.1.1", "5.1.1.1"]
        ))
        let result = await TransportDispatcher.handle(
            command: "goto_position",
            params: ["position": .string("5.1.1.1")],
            router: router,
            cache: StateCache()
        )

        let envelope = try #require(obj(result))
        #expect(try #require(envelope["state"] as? String) == "A")
        #expect(try #require(envelope["verified"] as? Bool))
        #expect(envelope["verification_withheld"] == nil)
        #expect(try #require(envelope["observed_before"] as? String) == "4.1.1.1")
    }

    @Test("a coincident complete pre/post reading is not a write-effect verification")
    func coincidentPreAndPostReadbacksCannotVerifyWriteEffect() async throws {
        // Exercise the finalization property below the explicit dispatcher no-op.  A caller may
        // reach finalization after issuing a write even when both authoritative readings happen to
        // equal the request; that coincidence does not establish that this call moved anything.
        let ordinaryDialogEnvelope = HonestContract.encodeStateA(
            extras: [
                "operation": "transport.goto_position",
                "requested": "5.1.1.1",
                "write_attempted": true,
            ]
        )
        let router = ChannelRouter()
        await router.register(StubTransportChannel(
            gotoResult: .success(ordinaryDialogEnvelope),
            readbackPosition: "5.1.1.1"
        ))

        let result = await TransportDispatcher.finalizeGotoPositionResult(
            .success(ordinaryDialogEnvelope),
            requestedPosition: "5.1.1.1",
            beforeTransport: Self.transportState("5.1.1.1"),
            router: router,
            cache: StateCache()
        )

        let envelope = try #require(obj(result))
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(!(try #require(envelope["verified"] as? Bool)))
        #expect(try #require(envelope["verification_withheld"] as? String)
            == "observed_effect_unavailable")
    }

    @Test("a matching post-read without a readable pre-write read never reaches State A")
    func missingPreWriteReadbackWithholdsEffectVerification() async throws {
        // Mutation this rejects: restore State A's old post-read equality condition. The post read
        // reaches 5.1.1.1, but the pre-write transport read failed, so the matching value could
        // have predated this invocation. The fixture's two distinct state replies prove the
        // pre-read did not silently become an answer of absence.
        let establishedTargetEnvelope = HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: [
                "operation": "transport.goto_position",
                "method": "dialog",
                "requested": "5.1.1.1",
                "dialog_input_attempted": true,
                "write_attempted": true,
                "safe_to_retry": false,
            ]
        )
        let channel = StubTransportChannel(
            gotoResult: .success(establishedTargetEnvelope),
            readbackPosition: "",
            readbackResults: [
                .error("pre-write transport read failed"),
                Self.encodedTransportState("5.1.1.1"),
            ]
        )
        let router = ChannelRouter()
        await router.register(channel)
        let result = await TransportDispatcher.handle(
            command: "goto_position",
            params: ["position": .string("5.1.1.1")],
            router: router,
            cache: StateCache()
        )

        let envelope = try #require(obj(result))
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(!(try #require(envelope["verified"] as? Bool)))
        #expect(try #require(envelope["verification_withheld"] as? String)
            == "observed_effect_unavailable")
        #expect(try #require(envelope["observed"] as? String) == "5.1.1.1")
        #expect(await channel.gotoExecutionCount() == 1, "the failed pre-read must not retire the operation")
    }

    @Test("an already-observed requested position is an explicit no-write result")
    func alreadyAtRequestedPositionReturnsUnchangedWithoutOpeningTheDialog() async throws {
        // Mutation this rejects: remove the complete pre-read no-op branch. A post-read matching
        // the target after a dialog write would be coincidental; the honest shape is instead an
        // explicit observed no-op with no route execution.
        let channel = StubTransportChannel(
            gotoResult: .error("the dialog route must not run for an observed no-op"),
            readbackPosition: "5.1.1.1"
        )
        let router = ChannelRouter()
        await router.register(channel)
        let result = await TransportDispatcher.handle(
            command: "goto_position",
            params: ["position": .string("5.1.1.1")],
            router: router,
            cache: StateCache()
        )

        let envelope = try #require(obj(result))
        #expect(try #require(envelope["state"] as? String) == "A")
        #expect(try #require(envelope["verified"] as? Bool))
        #expect(try #require(envelope["unchanged"] as? Bool))
        #expect(!(try #require(envelope["write_attempted"] as? Bool)))
        #expect(await channel.gotoExecutionCount() == 0, "the no-op branch must not open the dialog")
    }

    @Test("the TransportState display default is never a goto_position observation")
    func unreadablePositionDefaultCannotReachStateA() async throws {
        // Source mutation: restore finalizeGotoPositionResult's old display-string equality check.
        // The legacy `"1.1.1.1"` display default without any readable AX position control must
        // never certify State A.
        var unreadableState = TransportState()
        unreadableState.lastUpdated = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let unreadableResult = ChannelResult.success(
            String(decoding: try encoder.encode(unreadableState), as: UTF8.self)
        )
        let router = ChannelRouter()
        await router.register(StubTransportChannel(
            gotoResult: notedDialogStateB(bar: 1),
            readbackPosition: "",
            readbackResult: unreadableResult
        ))
        let result = await TransportDispatcher.handle(
            command: "goto_position",
            params: ["position": .string("1.1.1.1")],
            router: router,
            cache: StateCache()
        )

        let envelope = try #require(obj(result))
        #expect(!(try #require(envelope["verified"] as? Bool)))
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(try #require(envelope["reason"] as? String) == "readback_unavailable")
        #expect(envelope["observed"] == nil)
        #expect(envelope["observed_time_position"] == nil)
        let unobserved = try #require(envelope["unobserved_position_components"] as? [String])
        #expect(unobserved == ["bar", "beat", "subdivision", "tick"])
    }
}
