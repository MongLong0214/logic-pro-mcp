@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// Pure injected shapes, not a qualification of any native channel-strip type.
@Suite("#291 input observations survive the existing producers", .serialized)
struct Issue291InputObservationTests {
    private final class Failure: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        func fail() { lock.withLock { failed = true } }
        var isFailed: Bool { lock.withLock { failed } }
    }

    private struct Fixture {
        let builder = FakeAXRuntimeBuilder()
        let failure = Failure()
        let strip: AXUIElement
        let input: AXUIElement
        let later: AXUIElement
        let runtime: AXLogicProElements.Runtime

        init(_ shape: String) {
            let b = builder
            strip = b.element(291_700)
            input = b.element(291_701)
            later = b.element(291_702)
            b.setRole(strip, kAXLayoutItemRole as String)
            let monitoring = b.element(291_703)
            b.setButton(monitoring, description: "monitoring",
                        help: "Input Monitoring button. Hear incoming signal while recording.",
                        x: 0, y: 0, width: 1, height: 1)
            b.setChildren(monitoring, [])
            var children = [monitoring]
            if shape != "instrument" && shape != "deep" {
                b.setButton(input, description: shape == "blank" ? "" : (shape == "aux" ? "Bus 1" : "Input 1"),
                            help: "Input slot. Choose the channel strip input source.",
                            x: 0, y: 0, width: 1, height: 1)
                // Logic 12.3 en-US: an offscreen physical strip retains a button described
                // "input" but has not populated its help or source description. Scrolling
                // the same strip into view exposes Input 1, so this is not an absent slot.
                if shape == "placeholder" {
                    b.removeAttribute(input, kAXHelpAttribute as String)
                    b.setAttribute(input, kAXDescriptionAttribute as String, "input")
                }
                b.setChildren(input, [])
                children.append(input)
            }
            if ["duplicate", "late_role", "unknown_bus"].contains(shape) {
                b.setButton(later, description: "Bus 2",
                            help: shape == "unknown_bus" ? "Source selector. Choose what this strip hears."
                                : "Input slot. Choose the channel strip input source.",
                            x: 0, y: 0, width: 1, height: 1)
                b.setChildren(later, [])
                children.append(later)
            }
            if shape == "deep" {
                b.setButton(input, description: "Bus 1", help: "Input slot. Choose the channel strip input source.",
                            x: 0, y: 0, width: 1, height: 1)
                b.setChildren(input, [])
                var descendant = input
                for offset in (0..<4).reversed() {
                    let group = b.element(291_710 + offset)
                    b.setRole(group, kAXGroupRole as String)
                    b.setChildren(group, [descendant])
                    descendant = group
                }
                children.append(descendant)
            }
            b.setChildren(strip, children)
            _ = make123MixerFixture(stripCount: 1, firstStrip: strip, builder: b)
            b.setAttribute(b.element(11), kAXTitleAttribute as String, "Session - Tracks")
            let failing = failure
            let ownInput = input
            let ownLater = later
            let ownStrip = strip
            runtime = b.makeLogicRuntime(
                appElement: b.element(10),
                attributeValueResultHandler: { element, attribute in
                    if (shape == "late_role" && CFEqual(element, ownLater) && attribute == kAXRoleAttribute as String)
                        || (failing.isFailed && CFEqual(element, ownInput) && attribute == kAXDescriptionAttribute as String) {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    return nil
                },
                childrenResultHandler: { element in
                    shape == "children" && CFEqual(element, ownStrip)
                        ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : nil
                }, setAttributeHandler: nil, performActionHandler: nil,
                executeAppleScript: { _ in .error("fixture forbids AppleScript") }
            )
        }
    }

    private func ordinaryRows(_ fixture: Fixture, single: Bool) throws -> [[String: Any]] {
        let result = single
            ? AccessibilityChannel.defaultGetChannelStrip(params: ["index": "0"], runtime: fixture.runtime)
            : AccessibilityChannel.defaultGetMixerState(runtime: fixture.runtime)
        #expect(result.isSuccess)
        let object = try JSONSerialization.jsonObject(with: Data(result.message.utf8))
        if single { return [try #require(object as? [String: Any])] }
        return try #require(object as? [[String: Any]])
    }

    private func inspect(_ fixture: Fixture, cache: StateCache = StateCache()) async throws -> [String: Any] {
        let gate = LogicMutationGate()
        let channel = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: fixture.runtime
        ))
        let dependencies = HandlerDependencies(
            router: ChannelRouter(), cache: cache, targetRegistry: TargetRegistry(),
            poller: StatePoller(axChannel: channel, cache: cache,
                               runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable)),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: .unavailable
        )
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
        let params: [String: Value] = ["domains": .array([.string("strips"), .string("routing")])]
        let result = await LogicProServer.runWithDeadline(
            tool: "logic_project", command: "inspect_session", commandParams: params, mutationGate: gate
        ) { await handler(dependencies, params) }
        let isError = result.isError ?? false
        #expect(!isError)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        return try #require(sharedJSONObject(sharedToolText(result)))
    }

    @Test(arguments: ["audio", "aux", "instrument", "blank", "children", "placeholder"], [false, true])
    func bothOrdinaryProducersCarryActualInputStatus(shape: String, single: Bool) throws {
        let fixture = Fixture(shape)
        let row = try #require(ordinaryRows(fixture, single: single).first)
        let expectedSource = shape == "audio" ? "Input 1" : (shape == "aux" ? "Bus 1" : nil)
        #expect(row["input"] as? String == expectedSource)
        let observation = try #require(row["input_observation"] as? [String: Any])
        #expect(observation["state"] as? String == (expectedSource != nil ? "observed_source" : (shape == "instrument" ? "no_slot" : "unreadable")))
        #expect(observation["source"] as? String == expectedSource)
        let decoded = try JSONDecoder().decode(ChannelStripState.self, from: JSONSerialization.data(withJSONObject: row))
        let roundTrip = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect((roundTrip["input_observation"] as? NSDictionary) == (observation as NSDictionary))
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test(arguments: ["audio", "aux", "instrument", "blank", "placeholder"])
    func registeredInspectionCarriesInputStatusWithoutInventingRouting(shape: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture(shape)
            let cache = StateCache()
            let body = try await inspect(fixture, cache: cache)
            let strips = try #require(body["strips"] as? [String: Any])
            let row = try #require((strips["rows"] as? [[String: Any]])?.first)
            let expected = ["audio", "aux"].contains(shape) ? "observed_source" : (shape == "instrument" ? "no_slot" : "unreadable")
            #expect(row["input_status"] as? String == expected)
            #expect((row["input_observation"] as? [String: Any])?["state"] as? String == expected)
            #expect(strips["coverage"] as? String == "partial")
            let routing = try #require(body["routing"] as? [String: Any])
            #expect(routing["coverage"] as? String != "complete")
            let graph = try #require(routing["graph"] as? [String: Any])
            #expect((graph["bus_to_aux_input"] as? [String: Any])?["state"] as? String != "complete")
            #expect(row["type"] == nil && row["track_ref"] == nil && row["aux_ref"] == nil && row["input_ref"] == nil)
            let capture = await SessionPopulationObservation.capture(cache: cache, targetRegistry: nil, fileReader: .unavailable)
            let published = SessionPopulationObservation.routingGraph(capture: capture)
            #expect(published.edges.isEmpty && !published.complete,
                    "an observed bus input label alone supplies neither an edge nor an aux/port identity")
        }
    }

    @Test func failedInputRefreshClearsPreviouslyObservedSource() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture("audio")
            let cache = StateCache()
            let first = try await inspect(fixture, cache: cache)
            let old = try #require(((first["strips"] as? [String: Any])?["rows"] as? [[String: Any]])?.first)
            #expect(old["input"] as? String == "Input 1")
            fixture.failure.fail()
            let second = try await inspect(fixture, cache: cache)
            let current = try #require(((second["strips"] as? [String: Any])?["rows"] as? [[String: Any]])?.first)
            #expect(current["input"] == nil)
            #expect(current["input_status"] as? String == "unreadable")
            let cached = try #require(await cache.getChannelStrips().first)
            let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cached)) as? [String: Any])
            #expect(wire["input"] == nil)
            #expect((wire["input_observation"] as? [String: Any])?["state"] as? String == "unreadable")
            let resource = try await ResourceHandlers.read(
                uri: "logic://mixer", cache: cache, router: ChannelRouter(), targetRegistry: nil, fileReader: .unavailable
            )
            let resourceBody = try #require(sharedJSONObject(sharedResourceText(resource)))
            let resourceRow = try #require((resourceBody["strips"] as? [[String: Any]])?.first)
            #expect(resourceRow["input"] == nil)
            #expect((resourceRow["input_observation"] as? [String: Any])?["state"] as? String == "unreadable")
        }
    }

    @Test(arguments: ["duplicate", "late_role", "unknown_bus", "deep"])
    func ambiguousOrUnseenInputCannotBecomeKnownOrAbsent(shape: String) {
        let fixture = Fixture(shape)
        #expect(AXLogicProElements.inputSlotReading(in: fixture.strip, runtime: fixture.runtime.ax) == .unreadable)
    }

    @Test func unknownBusBesideRecognizedPhysicalInputCannotClearTheExistingCycleCheck() {
        let fixture = Fixture("unknown_bus")
        #expect(AccessibilityChannel.busLoop(into: 2, from: 0, strips: [fixture.strip], inputs: [:],
                                           runtime: fixture.runtime.ax) == .unknown(ordinal: 0, part: "input"))
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test func offscreenInputPlaceholderCannotClearTheExistingCycleCheck() {
        let fixture = Fixture("placeholder")
        #expect(AXLogicProElements.inputSlotReading(in: fixture.strip, runtime: fixture.runtime.ax) == .unreadable)
        #expect(AccessibilityChannel.busLoop(into: 2, from: 0, strips: [fixture.strip], inputs: [:],
                                           runtime: fixture.runtime.ax) == .unknown(ordinal: 0, part: "input"))
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test func inputPlaceholderCannotBeIgnoredBesideAnObservedSource() {
        let fixture = Fixture("placeholder")
        fixture.builder.setButton(fixture.later, description: "Input 2",
                                  help: "Input slot. Choose the channel strip input source.",
                                  x: 0, y: 0, width: 1, height: 1)
        fixture.builder.setChildren(fixture.later, [])
        fixture.builder.setChildren(fixture.strip, [fixture.input, fixture.later])
        let read = AXLogicProElements.inputSlotRead(in: fixture.strip, runtime: fixture.runtime.ax)
        #expect(read.reading == .unreadable)
        #expect(read.control == nil)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test func malformedPlaceholderDescriptionCannotEstablishAbsence() {
        let fixture = Fixture("placeholder")
        fixture.builder.setAttribute(fixture.input, kAXDescriptionAttribute as String, NSNumber(value: 42))
        let read = AXLogicProElements.inputSlotRead(in: fixture.strip, runtime: fixture.runtime.ax)
        #expect(read.reading == .unreadable)
        #expect(read.control == nil)
        #expect(AccessibilityChannel.busLoop(into: 2, from: 0, strips: [fixture.strip], inputs: [:],
                                           runtime: fixture.runtime.ax) == .unknown(ordinal: 0, part: "input"))
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test func legacyCodableInputIsRetainedWithoutInventingObservation() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let data = Data(#"{"trackIndex":0,"input":"Input 3","volume":0,"pan":0,"eqEnabled":false,"plugins":[]}"#.utf8)
            let legacy = try JSONDecoder().decode(ChannelStripState.self, from: data)
            #expect(legacy.input == "Input 3")
            let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
            #expect(wire["input_observation"] == nil)
            let cache = StateCache()
            await cache.updateChannelStrips([legacy])
            let capture = await SessionPopulationObservation.capture(cache: cache, targetRegistry: nil, fileReader: .unavailable)
            let report = SessionPopulationObservation.build(request: .init(domains: [.strips]), capture: capture)
            let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
            let row = try #require(((body["strips"] as? [String: Any])?["rows"] as? [[String: Any]])?.first)
            #expect(row["input"] as? String == "Input 3")
            #expect(row["input_status"] as? String == "not_read")
            #expect(row["input_observation"] == nil)
        }
    }
}
