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
    private actor StubTransportChannel: Channel {
        nonisolated let id: ChannelID = .accessibility
        let gotoResult: ChannelResult
        let readbackPosition: String
        let readbackResult: ChannelResult?
        init(
            gotoResult: ChannelResult,
            readbackPosition: String,
            readbackResult: ChannelResult? = nil
        ) {
            self.gotoResult = gotoResult
            self.readbackPosition = readbackPosition
            self.readbackResult = readbackResult
        }
        func start() async throws {}
        func stop() async {}
        func healthCheck() async -> ChannelHealth { .healthy(detail: "stub") }
        func execute(operation: String, params: [String: String]) async -> ChannelResult {
            switch operation {
            case "transport.goto_position": return gotoResult
            case "transport.get_state":
                if let readbackResult { return readbackResult }
                // Encode a real TransportState with the SAME .iso8601 strategy
                // the dispatcher decodes with. A hand-written date carrying
                // fractional seconds (".000Z") fails strict .iso8601 decoding on
                // the CI Foundation, which made `liveTransportState` return nil
                // and the verdict fall back to the un-stripped State B.
                var state = TransportState()
                state.position = readbackPosition
                state.positionReadback = TransportPositionReadback(
                    value: readbackPosition,
                    observedComponents: TransportPositionComponent.allCases
                )
                state.lastUpdated = Date(timeIntervalSince1970: 0)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return .success(String(decoding: (try? encoder.encode(state)) ?? Data(), as: UTF8.self))
            default: return .error("unexpected: \(operation)")
            }
        }
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
        await router.register(StubTransportChannel(gotoResult: notedDialogStateB(bar: 1), readbackPosition: "1.1.1.1"))
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
        await router.register(StubTransportChannel(gotoResult: notedDialogStateB(bar: 17), readbackPosition: "17.1.1.1"))
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
        await router.register(StubTransportChannel(gotoResult: notedDialogStateB(bar: 1), readbackPosition: "1.2.1.1"))
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
        // Source mutation: restore `extractSliderValue(slider, runtime: runtime) ?? 0` for either
        // component. The missing Bar value and unparseable Beat value would then fabricate `0.0`
        // and falsely mark both components observed.
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
        builder.setAttribute(beatSlider, kAXValueAttribute as String, "not-a-number")

        let extracted = AccessibilityChannel.defaultGetTransportState(
            runtime: builder.makeLogicRuntime(appElement: app)
        )
        let payload: String
        if case let .success(value) = extracted {
            payload = value
        } else {
            Issue.record("expected transport state extraction to encode successfully")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(TransportState.self, from: try #require(payload.data(using: .utf8)))

        #expect(state.positionReadback == nil)
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
        #expect(try #require(envelope["observed"] as? String) == "1.1.1.1")
        let unobserved = try #require(envelope["unobserved_position_components"] as? [String])
        #expect(unobserved == ["bar", "beat", "subdivision", "tick"])
    }
}
