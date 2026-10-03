@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// #1094: edit.quantize sets the requested grid through the Region inspector's value pop-up and reads it
// back. The fake inspector is the shape read off Logic in Korean (lpm-evidence/1094/explore2-ko.json): an
// AXRow holding the mode pop-up (value: the `Quantize` row) and a value pop-up; a press on the value pop-up
// adds an AXMenu of grid items under it, and a press on an item makes it the pop-up's value and removes
// the menu. Labels are the English rows; the matching is the same LabelSet in every language.

private final class Presses: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int] = []
    func record(_ id: Int) { lock.lock(); ids.append(id); lock.unlock() }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return ids }
}

private final class Cleanups: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private struct FakeInspector {
    static let valueID = 10_903
    static let menuID = 10_904
    static let itemBase = 10_910

    let builder = FakeAXRuntimeBuilder()
    let presses = Presses()
    let runtime: AXLogicProElements.Runtime
    let value: AXUIElement

    /// `items` are the menu's titles; `takesChoice` false leaves the value unchanged after an item press.
    init(start: String = "Off", items: [String] = ["Off", "1/8 Note", "1/16 Note"], rows: Int = 1,
         takesChoice: Bool = true, modeValue: String = "Quantize") {
        let builder = self.builder
        let presses = self.presses
        let app = builder.element(10_900)
        let window = builder.element(10_901)
        var rowElements: [AXUIElement] = []
        var valuePopup: AXUIElement?
        for index in 0..<rows {
            let row = builder.element(10_920 + index * 10)
            let mode = builder.element(10_921 + index * 10)
            let value = index == 0 ? builder.element(Self.valueID) : builder.element(10_923 + index * 10)
            builder.setAttribute(row, kAXRoleAttribute as String, kAXRowRole as String)
            for popup in [mode, value] {
                builder.setAttribute(popup, kAXRoleAttribute as String, kAXPopUpButtonRole as String)
            }
            builder.setAttribute(mode, kAXValueAttribute as String, modeValue)
            builder.setAttribute(value, kAXValueAttribute as String, start)
            builder.setChildren(row, [mode, value])
            rowElements.append(row)
            if index == 0 { valuePopup = value }
        }
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setChildren(window, rowElements)
        let value = valuePopup!
        let menu = builder.element(Self.menuID)
        builder.setAttribute(menu, kAXRoleAttribute as String, kAXMenuRole as String)
        let itemElements = items.enumerated().map { offset, title -> AXUIElement in
            let item = builder.element(Self.itemBase + offset)
            builder.setAttribute(item, kAXRoleAttribute as String, kAXMenuItemRole as String)
            builder.setAttribute(item, kAXTitleAttribute as String, title)
            return item
        }
        builder.setChildren(menu, itemElements)

        self.value = value
        self.runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard action == kAXPressAction as String else { return false }
                let id = CFEqual(element, value) ? Self.valueID
                    : itemElements.firstIndex(where: { CFEqual($0, element) }).map { Self.itemBase + $0 } ?? -1
                presses.record(id)
                if id == Self.valueID {
                    builder.setChildren(value, [menu])
                } else if id >= Self.itemBase {
                    if takesChoice, let title = builder.attributeValue(element, kAXTitleAttribute as String) {
                        builder.setAttribute(value, kAXValueAttribute as String, title)
                    }
                    builder.setChildren(value, [])
                }
                return true
            }
        )
    }

    var valueNow: String? { builder.attributeValue(value, kAXValueAttribute as String) as? String }
}

private func quantize(_ inspector: FakeInspector, grid: String, selected: Int? = 1,
                      cleanups: Cleanups = Cleanups()) async -> (ChannelResult, [String: Any]) {
    let regions: [RegionInfo]? = selected.map { count in
        (0..<count).map { RegionInfo(name: "MIDI \($0)", trackIndex: $0, startBar: 1, endBar: 2, kind: "midi", rawHelp: nil) }
    }
    let result = await AccessibilityChannel.quantizeSelectedRegions(
        params: ["value": grid],
        runtime: inspector.runtime,
        timing: .immediate,
        selection: { _ in regions },
        popupCleaner: { _ in cleanups.record(); return .noPopupObserved }
    )
    let object = (try? JSONSerialization.jsonObject(with: Data(result.message.utf8))) as? [String: Any] ?? [:]
    return (result, object)
}

@Suite("#1094 edit.quantize through the Region inspector")
struct Issue1094QuantizeThroughTheRegionInspectorTests {
    @Test func theRequestedGridIsChosenAndReadBack() async {
        let inspector = FakeInspector()
        let (result, object) = await quantize(inspector, grid: "1/16")
        #expect(result.isSuccess, "\(result.message)")
        #expect(object["state"] as? String == "A")
        #expect(object["before"] as? String == "Off")
        #expect(object["after"] as? String == "1/16 Note")
        #expect(inspector.valueNow == "1/16 Note")
        #expect(inspector.presses.all == [FakeInspector.valueID, FakeInspector.itemBase + 2],
                "one press on the value pop-up, one on the 1/16 item")
    }

    @Test func noSelectedRegionPressesNothing() async {
        // Mutation killed: the empty-selection guard removed (the defaults for new regions get the grid).
        for selected in [0, nil] as [Int?] {
            let inspector = FakeInspector()
            let (result, object) = await quantize(inspector, grid: "1/16", selected: selected)
            #expect(!result.isSuccess, "\(String(describing: selected))")
            #expect(object["write_attempted"] as? Bool == false)
            #expect(inspector.presses.all.isEmpty, "\(String(describing: selected))")
            #expect(inspector.valueNow == "Off")
        }
    }

    @Test func aGridTheMenuDoesNotOfferIsRefusedAndTheMenuClosed() async {
        // Mutation killed: the first menu item pressed when none matches.
        let inspector = FakeInspector(items: ["Off", "1/8 Note"])
        let cleanups = Cleanups()
        let (result, object) = await quantize(inspector, grid: "1/16", cleanups: cleanups)
        #expect(!result.isSuccess)
        #expect(object["matching_items"] as? Int == 0)
        #expect(inspector.presses.all == [FakeInspector.valueID], "only the pop-up was pressed")
        #expect(cleanups.total == 1, "the open menu is closed")
        #expect(inspector.valueNow == "Off")
    }

    @Test func aChoiceThatDidNotLandIsAMismatch() async {
        // Mutation killed: the press's return taken as the result (State A with the old value).
        let inspector = FakeInspector(takesChoice: false)
        let (result, object) = await quantize(inspector, grid: "1/16")
        #expect(!result.isSuccess)
        #expect(object["error"] as? String == "readback_mismatch")
        #expect(object["after"] as? String == "Off")
    }

    @Test func theGridAlreadyShownIsUnchangedWithoutAPress() async {
        let inspector = FakeInspector(start: "1/16 Note")
        let (result, object) = await quantize(inspector, grid: "1/16")
        #expect(result.isSuccess)
        #expect(object["changed"] as? Bool == false)
        #expect(inspector.presses.all.isEmpty)
    }

    @Test func noRowOrTwoRowsPressNothing() async {
        // Mutation killed: the first of several Quantize rows used.
        for (rows, mode) in [(1, "Q-Swing"), (2, "Quantize")] {
            let inspector = FakeInspector(rows: rows, modeValue: mode)
            let (result, object) = await quantize(inspector, grid: "1/16")
            #expect(!result.isSuccess, "\(rows) \(mode)")
            #expect(object["write_attempted"] as? Bool == false)
            #expect(inspector.presses.all.isEmpty, "\(rows) \(mode)")
        }
    }

    @Test func aGridOutsideTheToolsListIsRefused() async {
        let inspector = FakeInspector()
        let (result, object) = await quantize(inspector, grid: "1/3")
        #expect(!result.isSuccess)
        #expect(object["error"] as? String == "invalid_params")
        #expect(inspector.presses.all.isEmpty)
    }

    @Test func everyToolGridHasALabel() {
        // The dispatcher's list and the inspector's labels are one set: a grid the tool accepts and
        // the inspector cannot name would reach the channel only to be refused.
        #expect(Set(AXLocalePolicy.quantizeGridLabels.keys) == Set(EditDispatcher.validQuantizeGrids))
    }

    @Test func quantizeRoutesThroughAccessibilityAlone() {
        // Mutation killed: the MIDI key-command or CGEvent rung put back, which applies Logic's held
        // value instead of the requested grid.
        #expect(ChannelRouter.v2RoutingTable["edit.quantize"] == [.accessibility])
    }
}
