@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// New explicit-window API contract tests: no original-head behavioral RED is claimed.
/// Apply/run only after the extraction/wiring repair; the old Atlas Control Bar route calls
/// production AX even when given this fake runtime, so it MUST NOT be executed as a BEFORE.
@Suite("Issue290AtlasControlBarScope")
struct Issue290AtlasControlBarScopeTests {
    private func group(_ builder: FakeAXRuntimeBuilder, id: Int,
                       controls: Bool, description: String = "Control Bar") -> AXUIElement {
        let bar = builder.element(id)
        builder.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(bar, kAXDescriptionAttribute as String, description)
        if controls {
            let play = builder.element(id + 100)
            builder.setAttribute(play, kAXRoleAttribute as String, kAXCheckBoxRole as String)
            builder.setAttribute(play, kAXDescriptionAttribute as String, "Play")
            builder.setChildren(bar, [play])
        }
        return bar
    }

    @Test func atlasControlBarStaysInsideSuppliedWindowAndRuntime() throws {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(800)
        let supplied = b.element(801)
        let discoverable = b.element(802)
        let target = group(b, id: 803, controls: true)
        let decoy = group(b, id: 804, controls: true)
        b.setAttribute(app, kAXWindowsAttribute as String, [discoverable, supplied] as NSArray)
        b.setAttribute(app, kAXMainWindowAttribute as String, discoverable)
        b.setAttribute(supplied, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(discoverable, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setChildren(supplied, [target])
        b.setChildren(discoverable, [decoy])
        let elements = b.makeLogicRuntime(appElement: app)
        let global = try #require(AXLogicProElements.getControlBar(runtime: elements))
        #expect(CFEqual(global, decoy))
        let scoped = try #require(AtlasCapture.resolveScope("Control Bar", in: supplied, runtime: elements.ax))
        #expect(CFEqual(scoped, target))
        #expect(!CFEqual(scoped, decoy))
        #expect(b.setCalls.isEmpty)
        #expect(b.actionCalls.isEmpty)
    }

    @Test func explicitWindowRetainsCheckboxDiscriminationAndExactDescription() throws {
        let b = FakeAXRuntimeBuilder()
        let window = b.element(850)
        let empty = group(b, id: 851, controls: false)
        let falseFriend = group(b, id: 852, controls: true, description: "Hide Control Bar")
        let target = group(b, id: 853, controls: true)
        b.setChildren(window, [empty, falseFriend, target])
        let scoped = try #require(AXLogicProElements.getControlBar(in: window, runtime: b.makeAXRuntime()))
        #expect(CFEqual(scoped, target))
        #expect(b.setCalls.isEmpty)
        #expect(b.actionCalls.isEmpty)
    }

    @Test func explicitWindowStillRefusesIndistinguishableBars() {
        let b = FakeAXRuntimeBuilder()
        let window = b.element(880)
        b.setChildren(window, [group(b, id: 881, controls: true), group(b, id: 882, controls: true)])
        #expect(AXLogicProElements.getControlBar(in: window, runtime: b.makeAXRuntime()) == nil)
        #expect(b.setCalls.isEmpty)
        #expect(b.actionCalls.isEmpty)
    }

    @Test func explicitWindowPreservesLoneLabelledWithoutControlsFallback() throws {
        let b = FakeAXRuntimeBuilder()
        let window = b.element(890)
        let lone = group(b, id: 891, controls: false, description: "컨트롤 막대")
        b.setChildren(window, [lone])
        let scoped = try #require(AXLogicProElements.getControlBar(in: window, runtime: b.makeAXRuntime()))
        #expect(CFEqual(scoped, lone))
        #expect(b.setCalls.isEmpty)
        #expect(b.actionCalls.isEmpty)
    }
}
