@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#291 strict control-bar transport observations", .serialized)
struct Issue291StrictTransportReadTests {
    @Test(arguments: [-1.0, 2.0, 0.9, Double.nan, Double.infinity, -Double.infinity], ["play", "record"])
    func malformedTransportCannotPublishVerifiedNoOp(value: Double, control: String) async throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        f.b.setAttribute(f.b.element(control == "play" ? 2_910_301 : 2_910_302),
                         kAXValueAttribute as String, NSNumber(value: value))
        let reading = AccessibilityChannel.defaultGetTransportState(runtime: f.logic)
        #expect(!reading.isSuccess, "the actual getter must not encode unknown transport as stopped")
        let noMouse = AXMouseHelper.Runtime(postMouseEvent: { _, _, _ in false },
            postKeyEvent: { _ in false }, postUnicodeScalar: { _ in false }, sleepMicros: { _ in })
        let channel = AccessibilityChannel(runtime: .axBacked(isTrusted: { true },
            isLogicProRunning: { true }, logicRuntime: f.logic, controlBarMouseRuntime: noMouse))
        let router = ChannelRouter()
        await router.register(channel)
        for command in ["stop", "pause"] {
            let result = await TransportDispatcher.handle(command: command, params: [:],
                router: router, cache: StateCache(), sleep: { _ in })
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["state"] as? String == "C", "unknown transport must not verify a no-op")
            #expect(body["unchanged"] == nil)
            #expect(body["not_playing"] == nil)
            #expect(body["observed_after"] == nil)
        }
        #expect(f.mutations.isEmpty)
    }

    @Test(arguments: [0.0, 1.0])
    func actualTransportGetterPreservesKnownValues(_ value: Double) throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        f.b.setAttribute(f.b.element(2_910_301), kAXValueAttribute as String, NSNumber(value: value))
        let result = AccessibilityChannel.defaultGetTransportState(runtime: f.logic)
        #expect(result.isSuccess)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(TransportState.self, from: Data(result.message.utf8))
        if value == 1 { #expect(state.isPlaying) }
        else { #expect(!state.isPlaying) }
        #expect(!state.isRecording)
        #expect(f.mutations.isEmpty)
    }

    @Test(arguments: [-1.0, 2.0, 0.9, Double.nan, Double.infinity, -Double.infinity])
    func malformedCheckboxCannotEstablishTransport(_ value: Double) throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        let play = f.b.element(2_910_301)
        f.b.setAttribute(play, kAXValueAttribute as String, NSNumber(value: value))
        #expect(AXLogicProElements.readControlBarCheckboxValue(
            matching: AXLocalePolicy.transportPlayControl, runtime: f.logic) == nil)
        #expect(AXLogicProElements.readControlBarCheckboxValue(
            among: [play], matching: AXLocalePolicy.transportPlayControl, runtime: f.logic) == nil)
        #expect(f.mutations.isEmpty)
    }

    @Test(arguments: [0.0, 1.0])
    func exactCheckboxValuesRemainObserved(_ value: Double) throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        let play = f.b.element(2_910_301)
        f.b.setAttribute(play, kAXValueAttribute as String, NSNumber(value: value))
        let resolved = try #require(AXLogicProElements.readControlBarCheckboxValue(
            matching: AXLocalePolicy.transportPlayControl, runtime: f.logic))
        let collected = try #require(AXLogicProElements.readControlBarCheckboxValue(
            among: [play], matching: AXLocalePolicy.transportPlayControl, runtime: f.logic))
        if value == 1 {
            #expect(resolved)
            #expect(collected)
        } else {
            #expect(!resolved)
            #expect(!collected)
        }
        #expect(f.mutations.isEmpty)
    }
}
