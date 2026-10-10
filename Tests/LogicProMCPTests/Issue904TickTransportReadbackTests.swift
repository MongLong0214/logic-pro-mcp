import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// The literals are independently read Logic.framework/Localizable.strings `tick` values
/// from Logic 12.3 (6674), not values obtained from the policy under test. The formatter's
/// source selects this bundle; the earlier MAApplication fixture attribution was incorrect.
/// No UI is driven and no native Japanese/French readback is claimed.
@Suite("#904 derived tick reaches real transport readback")
struct Issue904TickTransportReadbackTests {
    private func read(
        labels: [String], owner: String = "Playhead Position", malformedLastValue: Bool = false,
        numericReplacement: (index: Int, value: Double)? = nil
    ) async throws -> TransportState {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(90470), window = b.element(90471)
        let bar = b.element(90472), play = b.element(90473), position = b.element(90474)
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        b.setAttribute(app, kAXWindowsAttribute as String, [window])
        b.setChildren(window, [bar])
        b.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
        b.setAttribute(play, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(play, kAXDescriptionAttribute as String, "Play")
        b.setAttribute(play, kAXValueAttribute as String, 0)
        let record = b.element(90475)
        b.setAttribute(record, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(record, kAXDescriptionAttribute as String, "Record")
        b.setAttribute(record, kAXValueAttribute as String, 0)
        b.setAttribute(position, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(position, kAXDescriptionAttribute as String, owner)
        let values = [6, 2, 3, 120]
        let sliders = labels.enumerated().map { index, label in
            let slider = b.element(90480 + index)
            b.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
            b.setAttribute(slider, kAXDescriptionAttribute as String, label)
            if malformedLastValue && index == labels.count - 1 {
                b.setAttribute(slider, kAXValueAttribute as String, "not a number")
            } else if let replacement = numericReplacement, index == replacement.index {
                b.setAttribute(slider, kAXValueAttribute as String, NSNumber(value: replacement.value))
            } else {
                b.setAttribute(slider, kAXValueAttribute as String, values[index])
            }
            return slider
        }
        b.setChildren(position, sliders)
        b.setChildren(bar, [play, record, position])
        let logic = b.makeLogicRuntime(appElement: app, setAttributeHandler: { _, _, _ in
            Issue.record("readback attempted an AX write"); return false
        }, performActionHandler: { _, _ in
            Issue.record("readback attempted an AX action"); return false
        }, executeAppleScript: { _ in
            Issue.record("readback attempted AppleScript"); return .error("forbidden")
        })
        let inert: @Sendable () -> ChannelResult = { .error("unexpected route") }
        let channel = AccessibilityChannel(runtime: .init(
            isTrusted: { true }, isLogicProRunning: { true },
            appRoot: { AXLogicProElements.appRoot(runtime: logic) },
            transportState: { AccessibilityChannel.defaultGetTransportState(runtime: logic) },
            toggleTransportButton: { _ in inert() }, setTempo: { _ in inert() },
            setCycleRange: { _ in inert() }, tracks: inert, selectedTrack: inert,
            selectTrack: { _ in inert() }, setTrackToggle: { _, _ in inert() },
            renameTrack: { _ in inert() }, mixerState: inert, channelStrip: { _ in inert() },
            setMixerValue: { _, _ in inert() }, projectInfo: inert,
            confirmNewTrackDialog: { Issue.record("readback attempted a key") },
            canPostEvents: { false }, logicRuntime: logic
        ))
        let result = await channel.execute(operation: "transport.get_state", params: [:])
        guard case let .success(body) = result else {
            Issue.record("real transport route refused: \(result)")
            throw NSError(domain: "tick-readback", code: 1)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TransportState.self, from: Data(body.utf8))
    }

    @Test("Japanese, Spanish and French tick rows reach the fourth component", arguments: ["ja", "es", "fr"])
    func derivedTickReadback(locale: String) async throws {
        let tick = locale == "fr" ? "coche" : locale == "es" ? "tic" : "tick"
        let state = try await read(labels: ["Bar", "Beat", "Division", tick])
        #expect(state.position == "6.2.3.120")
        #expect(state.positionReadback?.observedComponents == [.bar, .beat, .subdivision, .tick])
    }

    @Test("English and Korean exact tick descriptions keep their existing readback", arguments: ["Tick", "틱"])
    func existingTickReadback(tick: String) async throws {
        let state = try await read(labels: ["Bar", "Beat", "Division", tick])
        #expect(state.position == "6.2.3.120")
        #expect(state.positionReadback?.observedComponents == [.bar, .beat, .subdivision, .tick])
    }

    @Test("whole tick descriptions preserve case and surrounding whitespace tolerance",
          arguments: [" tIcK \n", "\t틱 ", " \nTIC\t"])
    func exactTickKeepsCaseAndWhitespace(tick: String) async throws {
        let state = try await read(labels: ["Bar", "Beat", "Division", tick])
        #expect(state.position == "6.2.3.120")
        #expect(state.positionReadback?.observedComponents == [.bar, .beat, .subdivision, .tick])
    }

    @Test("unrelated substring descriptions never supply a tick", arguments: ["articulation", "vertical"])
    func unrelatedSliderIsNotTick(description: String) async throws {
        let state = try await read(labels: ["Bar", "Beat", "Division", description])
        #expect(state.position == "6.2.3")
        #expect(state.positionReadback?.observedComponents == [.bar, .beat, .subdivision])
    }

    @Test("two-component display remains two-component")
    func twoComponentMode() async throws {
        let state = try await read(labels: ["Bar", "Beat"])
        #expect(state.position == "6.2")
        #expect(state.positionReadback?.observedComponents == [.bar, .beat])
    }

    @Test("a gap before tick is not invented")
    func missingSubdivision() async throws {
        let state = try await read(labels: ["Bar", "Beat", "Tick"])
        #expect(state.position == "6.2")
        #expect(state.positionReadback?.observedComponents == [.bar, .beat])
    }

    @Test("another owner cannot supply playhead components")
    func wrongOwner() async throws {
        let state = try await read(labels: ["Bar", "Beat", "Division", "Tick"], owner: "Other Position")
        #expect(state.positionReadback == nil)
    }

    @Test("malformed tick value leaves only observed prefix")
    func malformedTick() async throws {
        let state = try await read(labels: ["Bar", "Beat", "Division", "Tick"], malformedLastValue: true)
        #expect(state.position == "6.2.3")
        #expect(state.positionReadback?.observedComponents == [.bar, .beat, .subdivision])
    }

    @Test("a numeric NaN tick preserves the readable contiguous prefix without trapping")
    func nonfiniteTickPreservesObservedPrefix() async throws {
        let state = try await read(
            labels: ["Bar", "Beat", "Division", "tic"],
            numericReplacement: (3, .nan)
        )
        #expect(state.position == "6.2.3")
        #expect(state.positionReadback?.observedComponents == [.bar, .beat, .subdivision])
    }

    @Test("nonfinite and out-of-Int-range components stop at the observed prefix",
          arguments: [0, 1, 2, 3], [
            Double.nan, .infinity, -.infinity, Double(Int.max),
            Double(Int.min).nextDown, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
          ])
    func invalidNumericComponent(component: Int, value: Double) async throws {
        let state = try await read(
            labels: ["Bar", "Beat", "Division", "tic"],
            numericReplacement: (component, value)
        )
        let components: [TransportPositionComponent] = [.bar, .beat, .subdivision, .tick]
        if component == 0 {
            #expect(state.positionReadback == nil)
            #expect(state.position == "1.1.1.1") // Legacy default is not an observed component.
        } else {
            let prefix = ["6", "2", "3"].prefix(component).joined(separator: ".")
            #expect(state.position == prefix)
            #expect(state.positionReadback?.observedComponents == Array(components.prefix(component)))
        }
    }

    @Test("finite fractional components retain toward-zero conversion",
          arguments: [0, 1, 2, 3], [
            (value: 6.9, expected: 6), (value: -6.9, expected: -6), (value: -0.9, expected: 0),
          ])
    func finiteFractionalComponent(component: Int, sample: (value: Double, expected: Int)) async throws {
        let state = try await read(
            labels: ["Bar", "Beat", "Division", "tic"],
            numericReplacement: (component, sample.value)
        )
        var expected = [6, 2, 3, 120]
        expected[component] = sample.expected
        #expect(state.position == expected.map(String.init).joined(separator: "."))
        #expect(state.positionReadback?.observedComponents == [.bar, .beat, .subdivision, .tick])
    }

    @Test("exactly representable Int boundaries remain observations without invented musical ranges",
          arguments: [0, 1, 2, 3], [
            (value: Double(Int.min), expected: Int.min),
            (value: Double(Int.max).nextDown, expected: Int.max - 1023),
          ])
    func representableIntegerBoundary(component: Int, sample: (value: Double, expected: Int)) async throws {
        let state = try await read(
            labels: ["Bar", "Beat", "Division", "tic"],
            numericReplacement: (component, sample.value)
        )
        var expected = [6, 2, 3, 120]
        expected[component] = sample.expected
        #expect(state.position == expected.map(String.init).joined(separator: "."))
        #expect(state.positionReadback?.observedComponents == [.bar, .beat, .subdivision, .tick])
    }

    @Test("the Logic formatter's French tick description reaches the fourth component")
    func logicFrameworkFrenchTickReadback() async throws {
        let state = try await read(labels: ["Bar", "Beat", "Division", "coche"])
        #expect(state.position == "6.2.3.120")
        #expect(state.positionReadback?.observedComponents == [.bar, .beat, .subdivision, .tick])
    }

    @Test("a different framework's Japanese tick description is not this formatter's component")
    func wrongFrameworkJapaneseTickIsNotObserved() async throws {
        let state = try await read(labels: ["Bar", "Beat", "Division", "ティック"])
        #expect(state.position == "6.2.3")
        #expect(state.positionReadback?.observedComponents == [.bar, .beat, .subdivision])
    }
}
