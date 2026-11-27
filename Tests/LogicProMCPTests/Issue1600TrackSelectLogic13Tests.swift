@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// Models what was measured on Logic Pro 13.0 (7801), ko-KR: the track-header rail's
/// AXSelectedChildren setter returns success and the selection does not move; the main
/// Mixer's AXSelectedChildren, written with the strip that carries the track's name, does.
private final class Logic13SelectFixture: @unchecked Sendable {
    let b = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let window: AXUIElement
    let rail: AXUIElement
    let mixer: AXUIElement?
    var rows: [AXUIElement] = []
    var strips: [AXUIElement] = []
    private(set) var events: [String] = []

    init(names: [String], selected: Int, withMixer: Bool = true) {
        app = b.element(1_600_000)
        window = b.element(1_600_001)
        rail = b.element(1_600_002)
        mixer = withMixer ? b.element(1_600_003) : nil
        b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(rail, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(rail, kAXDescriptionAttribute as String, "Track Headers")
        for (i, name) in names.enumerated() {
            let row = b.element(1_600_100 + i)
            let field = b.element(1_600_200 + i)
            b.setAttribute(row, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            b.setAttribute(row, kAXSelectedAttribute as String, NSNumber(value: i == selected ? 1 : 0))
            b.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
            b.setAttribute(field, kAXDescriptionAttribute as String, name)
            b.setChildren(field, [])
            b.setChildren(row, [field])
            rows.append(row)
        }
        b.setAttribute(rail, kAXSelectedChildrenAttribute as String, [rows[selected]])
        b.setChildren(rail, rows)
        var windowChildren: [AXUIElement] = [rail]
        if let mixer {
            b.setAttribute(mixer, kAXRoleAttribute as String, kAXGroupRole as String)
            b.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
            for (i, name) in names.enumerated() {
                let strip = b.element(1_600_300 + i)
                b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
                b.setAttribute(strip, kAXDescriptionAttribute as String, name)
                b.setChildren(strip, [])
                strips.append(strip)
            }
            b.setAttribute(mixer, kAXSelectedChildrenAttribute as String, [strips[selected]])
            b.setChildren(mixer, strips)
            b.setAttributeSettable(mixer, kAXSelectedChildrenAttribute as String, true)
            windowChildren.append(mixer)
        }
        b.setChildren(window, windowChildren)
        b.setChildren(app, [window])
        b.setAttribute(app, kAXWindowsAttribute as String, [window])
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
    }

    private func moveSelection(to target: Int) {
        for (i, r) in rows.enumerated() {
            b.setAttribute(r, kAXSelectedAttribute as String, NSNumber(value: i == target ? 1 : 0))
        }
    }

    var runtime: AXLogicProElements.Runtime {
        b.makeLogicRuntime(
            pid: 1_600_900, appElement: app,
            setAttributeHandler: { [self] element, attribute, value in
                if CFEqual(element, rail), attribute == kAXSelectedChildrenAttribute as String {
                    events.append("rail_write")
                    return true // acknowledged, selection does not move
                }
                if let mixer, CFEqual(element, mixer), attribute == kAXSelectedChildrenAttribute as String,
                   let strip = (value as? [AXUIElement])?.first,
                   let i = strips.firstIndex(where: { CFEqual($0, strip) }) {
                    events.append("mixer_write:\(i)")
                    moveSelection(to: i)
                    return true
                }
                events.append("other_write:\(attribute)")
                return false
            },
            performActionHandler: { [self] _, action in
                events.append("action:\(action)")
                return false
            }
        )
    }
}

@Suite("Issue 1600: tracks.select on Logic 13")
struct Issue1600TrackSelectLogic13Tests {
    @Test func selectMovesSelectionThroughMixerStripWhenRailWriteIsAckedWithoutEffect() async {
        let f = Logic13SelectFixture(names: ["Audio 1", "Audio 2", "Deluxe Classic", "Studio Grand"], selected: 2)
        let rt = f.runtime
        #expect(AXLogicProElements.selectTrackViaAX(at: 0, runtime: rt))
        #expect(f.events == ["rail_write", "mixer_write:0"])
        #expect(await AccessibilityChannel.verifyTrackSelection(index: 0, runtime: rt) == .verified)
    }

    @Test func defaultSelectTrackReportsStateAAfterTheMixerRoute() async {
        let f = Logic13SelectFixture(names: ["Audio 1", "Audio 2", "Deluxe Classic", "Studio Grand"], selected: 2)
        let result = await AccessibilityChannel.defaultSelectTrack(params: ["index": "3"], runtime: f.runtime)
        guard case .success(let text) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(text.contains("\"state\":\"A\"") || text.contains("\"state\" : \"A\""))
        #expect(f.events.contains("mixer_write:3"))
    }

    @Test func duplicateNamesRefuseTheMixerWriteAndReadbackStaysHonest() async {
        let f = Logic13SelectFixture(names: ["Audio", "Audio", "Deluxe Classic"], selected: 2)
        let rt = f.runtime
        _ = AXLogicProElements.selectTrackViaAX(at: 0, runtime: rt)
        #expect(!f.events.contains { $0.hasPrefix("mixer_write") })
        #expect(await AccessibilityChannel.verifyTrackSelection(index: 0, runtime: rt) == .mismatch(selectedIndex: 2))
    }

    @Test func withoutAMixerTheNoOpIsReportedAsMismatchNotSelected() async {
        let f = Logic13SelectFixture(names: ["Audio 1", "Audio 2", "Deluxe Classic"], selected: 2, withMixer: false)
        let rt = f.runtime
        _ = AXLogicProElements.selectTrackViaAX(at: 1, runtime: rt)
        #expect(f.events == ["rail_write"])
        #expect(await AccessibilityChannel.verifyTrackSelection(index: 1, runtime: rt) == .mismatch(selectedIndex: 2))
    }
}
