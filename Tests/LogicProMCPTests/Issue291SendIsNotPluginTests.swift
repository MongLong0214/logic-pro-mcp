@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#291 assigned sends do not occupy audio insert positions")
struct Issue291SendIsNotPluginTests {
    private func group(
        _ builder: FakeAXRuntimeBuilder, id: Int, name: String,
        bypass: String, control: String, y: CGFloat
    ) -> AXUIElement {
        let group = builder.element(id)
        let toggle = builder.element(id + 1)
        let button = builder.element(id + 2)
        builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(group, kAXDescriptionAttribute as String, name)
        builder.setAttribute(group, kAXPositionAttribute as String, axPoint(100, y))
        builder.setAttribute(group, kAXSizeAttribute as String, axSize(58, 18))
        builder.setAttribute(toggle, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(toggle, kAXDescriptionAttribute as String, bypass)
        builder.setAttribute(toggle, kAXValueAttribute as String, 0)
        builder.setAttribute(button, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(button, kAXDescriptionAttribute as String, control)
        builder.setChildren(group, [toggle, button])
        return group
    }

    // Logic 12.3 en-US: the assigned Bus 1 send contains bypass + list, not
    // the editor-opening button that an occupied insert carries. Its name is
    // display data; neither a Bus prefix nor a destination number excludes it.
    @Test("bypass plus list is not an occupied insert", arguments: [
        ("bypass", "list"), ("바이패스", "목록")
    ])
    func listOnlyGroupIsNotAnInsert(bypass: String, list: String) throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = builder.element(75_000)
        let send = group(builder, id: 75_010, name: "Bus 1", bypass: bypass, control: list, y: 400)
        builder.setChildren(strip, [send])
        let runtime = builder.makeAXRuntime()
        #expect(!AXLogicProElements.isOccupiedPluginSlotElement(send, runtime: runtime))
        let slots = try #require(AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: runtime))
        #expect(slots.isEmpty)
        let plugins = try #require(AXLogicProElements.pluginSlots(in: strip, runtime: runtime))
        #expect(plugins.isEmpty)
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }

    @Test("send group does not shift real insert indices or filter a plug-in named Bus 1")
    func realInsertNameIsNotADestinationDiscriminator() throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = builder.element(75_100)
        let send = group(builder, id: 75_110, name: "Bus 1", bypass: "bypass", control: "list", y: 500)
        let first = group(builder, id: 75_120, name: "Bus 1", bypass: "bypass", control: "open", y: 300)
        let second = group(builder, id: 75_130, name: "Gain", bypass: "bypass", control: "open", y: 320)
        builder.setChildren(strip, [send, second, first])
        let runtime = builder.makeAXRuntime()
        let slots = try #require(AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: runtime))
        #expect(slots.map(\.name) == ["Bus 1", "Gain"])
        #expect(slots.map(\.index) == [0, 1])
        #expect(slots.allSatisfy { $0.readStatus == .occupiedReadable && !$0.isEmpty })
        let plugins = try #require(AXLogicProElements.pluginSlots(in: strip, runtime: runtime))
        #expect(plugins.map(\.name) == ["Bus 1", "Gain"])
        #expect(plugins.map(\.index) == [0, 1])
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }
}
