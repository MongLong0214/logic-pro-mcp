@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

// An entirely owned AX surface: real CF element comparisons, no live window list, Escape or script.
final class QuantizeSafetyFixture: @unchecked Sendable {
    let b = FakeAXRuntimeBuilder()
    var runtime: AXLogicProElements.Runtime!
    var popupPresses = 0
    var leafPresses = 0
    var cleanups = 0
    var popupValueReads = 0
    var onBefore: (() -> Void)?
    var onOpen: (() -> Void)?
    var onChoice: (() -> Void)?
    var onCleanup: (() -> Void)?
    var failingAttribute: (AXUIElement, String)?
    var failingChildren: AXUIElement?
    var choiceLands = true
    var pressReturns = true
    var cleanupActuallyCloses = true
    var cleanupOutcome: AccessibilityChannel.PluginPopupMenuCleanupOutcome = .noPopupObserved
    let app: AXUIElement
    let window: AXUIElement
    let content: AXUIElement
    let area: AXUIElement
    let header: AXUIElement
    let row: AXUIElement
    let mode: AXUIElement
    let value: AXUIElement
    let menu: AXUIElement
    let items: [AXUIElement]
    let regions: [AXUIElement]

    init(selected: Int = 1, rows: Int = 1, titles: [String] = ["Off", "1/8 Note", "1/16 Note"]) {
        let b = self.b
        app = b.element(109_400); window = b.element(109_401)
        content = b.element(109_402); area = b.element(109_403); header = b.element(109_404)
        row = b.element(109_405); mode = b.element(109_406); value = b.element(109_407)
        menu = b.element(109_408)
        items = titles.indices.map { b.element(109_410 + $0) }
        regions = (0..<3).map { b.element(109_420 + $0) }
        let rail = b.element(109_430)
        for (element, role) in [(app, kAXApplicationRole), (window, kAXWindowRole),
                                (content, kAXGroupRole), (area, "AXLayoutArea"),
                                (header, kAXLayoutItemRole), (rail, kAXGroupRole),
                                (row, kAXRowRole), (mode, kAXPopUpButtonRole),
                                (value, kAXPopUpButtonRole), (menu, kAXMenuRole)] {
            b.setAttribute(element, kAXRoleAttribute as String, role as String)
        }
        b.setAttribute(app, kAXWindowsAttribute as String, [window])
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        b.setAttribute(window, kAXSubroleAttribute as String, "AXStandardWindow")
        b.setAttribute(window, kAXTitleAttribute as String, "Owned quantize fixture")
        b.setAttribute(content, kAXDescriptionAttribute as String, "Track Content")
        b.setAttribute(rail, kAXDescriptionAttribute as String, "Track Headers")
        b.setAttribute(header, kAXDescriptionAttribute as String, "1 track named Fixture")
        b.setAttribute(mode, kAXValueAttribute as String, "Quantize")
        b.setAttribute(value, kAXValueAttribute as String, "Off")
        b.setAttribute(value, kAXEnabledAttribute as String, true)
        b.setAttribute(mode, kAXEnabledAttribute as String, true)
        frame(window, x: 0, y: 0, width: 1000, height: 800)
        frame(header, x: 10, y: 100, width: 150, height: 50)
        for (index, region) in regions.enumerated() {
            b.setAttribute(region, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            b.setAttribute(region, kAXDescriptionAttribute as String, "MIDI fixture \(index)")
            b.setAttribute(region, kAXHelpAttribute as String, "Region, start at bar 1, end at bar 2")
            b.setAttribute(region, kAXSelectedAttribute as String, index < selected)
            frame(region, x: 200 + CGFloat(index) * 120, y: 100, width: 100, height: 40)
        }
        b.setAttribute(area, kAXSelectedChildrenAttribute as String, Array(regions.prefix(selected)))
        b.setChildren(rail, [header]); b.setChildren(area, regions); b.setChildren(content, [area])
        b.setChildren(row, [mode, value]); b.setChildren(value, [])
        var rowsInWindow = [row]
        if rows > 1 {
            let duplicate = b.element(109_440), duplicateMode = b.element(109_441), duplicateValue = b.element(109_442)
            b.setAttribute(duplicate, kAXRoleAttribute as String, kAXRowRole as String)
            for popup in [duplicateMode, duplicateValue] {
                b.setAttribute(popup, kAXRoleAttribute as String, kAXPopUpButtonRole as String)
                b.setAttribute(popup, kAXValueAttribute as String, CFEqual(popup, duplicateMode) ? "Quantize" : "Off")
            }
            b.setChildren(duplicate, [duplicateMode, duplicateValue]); rowsInWindow.append(duplicate)
        }
        b.setChildren(window, [rail, content] + rowsInWindow)
        for (item, title) in zip(items, titles) {
            b.setAttribute(item, kAXRoleAttribute as String, kAXMenuItemRole as String)
            b.setAttribute(item, kAXTitleAttribute as String, title)
            b.setAttribute(item, kAXEnabledAttribute as String, true)
        }
        b.setChildren(menu, items)
        let ax = b.makeAXRuntime(
            appElement: app,
            attributeValueResultHandler: { [self] element, attribute in
                if let (failed, name) = failingAttribute, CFEqual(failed, element), attribute == name {
                    return .failure(.init(raw: -25200))
                }
                if CFEqual(element, value), attribute == kAXValueAttribute as String {
                    popupValueReads += 1
                    if popupValueReads == 1 { onBefore?() }
                }
                return nil
            },
            childrenResultHandler: { [self] element in
                if let failed = failingChildren, CFEqual(failed, element) { return .failure(.init(raw: -25200)) }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: { [self] element, action in
                guard action == kAXPressAction as String else { Issue.record("unexpected AX action"); return false }
                if CFEqual(element, value) {
                    popupPresses += 1; b.setChildren(value, [menu]); onOpen?()
                } else if items.contains(where: { CFEqual($0, element) }) {
                    leafPresses += 1
                    if choiceLands, let title = b.attributeValue(element, kAXTitleAttribute as String) {
                        b.setAttribute(value, kAXValueAttribute as String, title)
                    }
                    b.setChildren(value, []); onChoice?()
                } else { Issue.record("unexpected AX target") }
                return pressReturns
            }
        )
        runtime = .init(logicProPID: { 4242 }, ax: ax,
                        executeAppleScript: { _ in Issue.record("no live script"); return .error("owned") },
                        onScreenWindowList: { [] }, postPopupMenuEscape: { Issue.record("no live Escape") },
                        focusedApplicationPID: { 4242 })
    }
    func frame(_ element: AXUIElement, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        var point = CGPoint(x: x, y: y), size = CGSize(width: width, height: height)
        b.setAttribute(element, kAXPositionAttribute as String, AXValueCreate(.cgPoint, &point)!)
        b.setAttribute(element, kAXSizeAttribute as String, AXValueCreate(.cgSize, &size)!)
    }
    func select(_ selected: [AXUIElement]) {
        for region in regions { b.setAttribute(region, kAXSelectedAttribute as String, selected.contains { CFEqual($0, region) }) }
        b.setAttribute(area, kAXSelectedChildrenAttribute as String, selected)
    }
    var currentValue: String? { b.attributeValue(value, kAXValueAttribute as String) as? String }
    func run(grid: String = "1/16") async -> ChannelResult {
        await AccessibilityChannel.quantizeSelectedRegions(
            params: ["value": grid], runtime: runtime, timing: .immediate,
            popupCleaner: { [self] _ in
                cleanups += 1; onCleanup?()
                if cleanupOutcome.isClean, cleanupActuallyCloses { b.setChildren(value, []) }
                return cleanupOutcome
            })
    }
}

private func expectQuantizeRefusal(_ result: ChannelResult, written: Bool, reason: String? = nil) throws {
    #expect(!result.isSuccess, "\(result.message)")
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    let attempted = try #require(object["write_attempted"] as? Bool)
    if written { #expect(attempted) } else { #expect(!attempted) }
    if let reason { #expect(object["quantize_refusal"] as? String == reason) }
}

@Suite("#1094 retained quantize target and fail-closed census")
struct Issue1094QuantizeSafetyRegressionTests {
    @Test func popupMenuAliasesAreNotArrangementCensusNodes() async throws {
        let f = QuantizeSafetyFixture()
        f.b.setChildren(f.menu, [f.items[0], f.items[0], f.items[1], f.items[2]])
        let result = await f.run()
        #expect(result.isSuccess, "\(result.message)")
        #expect(f.popupPresses == 1)
        #expect(f.leafPresses == 1)
        #expect(f.currentValue == "1/16 Note")
    }
    @Test func unreadSelectionAfterOpeningKeepsTheConcreteReadFailure() async throws {
        let f = QuantizeSafetyFixture()
        f.onOpen = { f.failingAttribute = (f.regions[1], kAXSelectedAttribute as String) }
        let result = await f.run()
        try expectQuantizeRefusal(result, written: true, reason: "target_changed")
        let object = try #require(sharedJSONObject(result.message))
        #expect(object["read_stage"] as? String == "region_selected")
        #expect(object["read_status"] as? String == "-25200")
        #expect(f.leafPresses == 0)
    }
    @Test func disjointTrackAreasRequireEachExactSelectionAggregate() async throws {
        let f = QuantizeSafetyFixture()
        let second = f.b.element(109_453)
        f.b.setAttribute(second, kAXRoleAttribute as String, "AXLayoutArea")
        f.b.setChildren(f.area, Array(f.regions.prefix(2)))
        f.b.setChildren(second, [f.regions[2]])
        f.b.setAttribute(second, kAXSelectedChildrenAttribute as String, [AXUIElement]())
        f.b.setChildren(f.content, [f.area, second])
        let result = await f.run()
        #expect(result.isSuccess, "\(result.message)")
        #expect(f.popupPresses == 1)
        #expect(f.leafPresses == 1)
    }
    @Test func anOfftreeSelectionInAnyTrackAreaRefusesBeforeOpening() async throws {
        let f = QuantizeSafetyFixture()
        let second = f.b.element(109_453)
        f.b.setAttribute(second, kAXRoleAttribute as String, "AXLayoutArea")
        f.b.setChildren(second, [])
        f.b.setAttribute(second, kAXSelectedChildrenAttribute as String, [f.b.element(109_454)])
        f.b.setChildren(f.content, [f.area, second])
        let result = await f.run()
        try expectQuantizeRefusal(result, written: false, reason: "selection_children_unavailable")
        #expect(f.popupPresses == 0)
        #expect(f.leafPresses == 0)
    }
    @Test func nestedTrackAreasUseTheOwningArrangementSelectionAggregate() async throws {
        let f = QuantizeSafetyFixture()
        let trackArea = f.b.element(109_451)
        f.b.setAttribute(trackArea, kAXRoleAttribute as String, "AXLayoutArea")
        f.b.setChildren(trackArea, f.regions)
        f.b.setChildren(f.area, [trackArea])
        let result = await f.run()
        #expect(result.isSuccess, "\(result.message)")
        #expect(f.popupPresses == 1)
        #expect(f.leafPresses == 1)
        #expect(f.currentValue == "1/16 Note")
    }
    @Test func replacingANestedTrackAreaStopsTheGridLeaf() async throws {
        let f = QuantizeSafetyFixture()
        let trackArea = f.b.element(109_451)
        let replacement = f.b.element(109_452)
        for area in [trackArea, replacement] {
            f.b.setAttribute(area, kAXRoleAttribute as String, "AXLayoutArea")
            f.b.setChildren(area, f.regions)
        }
        f.b.setChildren(f.area, [trackArea])
        f.onOpen = { f.b.setChildren(f.area, [replacement]) }
        let result = await f.run()
        try expectQuantizeRefusal(result, written: true, reason: "target_changed")
        #expect(f.popupPresses == 1)
        #expect(f.leafPresses == 0)
        #expect(f.currentValue == "Off")
    }
    @Test(arguments: [0, 2])
    func selectionAreaRefusalReportsObservedCandidateCount(_ count: Int) async throws {
        let f = QuantizeSafetyFixture()
        if count == 0 {
            f.b.setChildren(f.content, f.regions)
        } else {
            let extra = f.b.element(109_450)
            f.b.setAttribute(extra, kAXRoleAttribute as String, "AXLayoutArea")
            f.b.setChildren(extra, [])
            f.b.setChildren(f.content, [f.area, extra])
        }
        let result = await f.run()
        try expectQuantizeRefusal(result, written: false)
        let object = try #require(sharedJSONObject(result.message))
        #expect(object["read_stage"] as? String == (count == 0 ? "selection_area" : "selected_children"))
        #expect(object["read_status"] as? String == (count == 0 ? "candidate_count_0" : "malformed_or_absent"))
        #expect(f.popupPresses == 0)
        #expect(f.leafPresses == 0)
    }
    @Test func unreadBeforeRefusesWithoutOpening() async throws {
        let f = QuantizeSafetyFixture(); f.failingAttribute = (f.value, kAXValueAttribute as String)
        let result = await f.run()
        #expect(f.popupPresses == 0); #expect(f.leafPresses == 0); #expect(f.currentValue == "Off")
        try expectQuantizeRefusal(result, written: false)
    }
    @Test(arguments: ["absent", "malformed", "unread", "offtree", "disagrees"])
    func incompleteSelectedChildrenCannotAuthorizeQuantize(_ kind: String) async throws {
        let f = QuantizeSafetyFixture()
        switch kind {
        case "absent": f.b.setAttribute(f.area, kAXSelectedChildrenAttribute as String, NSNull())
        case "malformed": f.b.setAttribute(f.area, kAXSelectedChildrenAttribute as String, "one")
        case "unread": f.failingAttribute = (f.area, kAXSelectedChildrenAttribute as String)
        case "offtree": f.b.setAttribute(f.area, kAXSelectedChildrenAttribute as String, [f.b.element(109_499)])
        default: f.b.setAttribute(f.area, kAXSelectedChildrenAttribute as String, [])
        }
        let result = await f.run()
        #expect(f.popupPresses == 0); #expect(f.leafPresses == 0); #expect(f.currentValue == "Off")
        try expectQuantizeRefusal(result, written: false)
    }
    @Test(arguments: ["children", "selected", "help", "frame", "outside"])
    func partialOrUnreadRegionCensusCannotAuthorizeQuantize(_ kind: String) async throws {
        let f = QuantizeSafetyFixture()
        switch kind {
        case "children": f.failingChildren = f.area
        case "selected": f.failingAttribute = (f.regions[1], kAXSelectedAttribute as String)
        case "help": f.failingAttribute = (f.regions[1], kAXHelpAttribute as String)
        case "frame": f.failingAttribute = (f.header, kAXPositionAttribute as String)
        default: f.frame(f.regions[1], x: 2000, y: 100, width: 100, height: 40)
        }
        let result = await f.run()
        #expect(f.popupPresses == 0); #expect(f.leafPresses == 0); #expect(f.currentValue == "Off")
        try expectQuantizeRefusal(result, written: false)
    }
    @Test(arguments: ["before", "open", "choice", "cleanup"])
    func sameCountSelectionReplacementNeverCertifiesOriginalTarget(_ stage: String) async throws {
        let f = QuantizeSafetyFixture()
        let drift = { f.select([f.regions[1]]) }
        switch stage {
        case "before": f.onBefore = drift
        case "open": f.onOpen = drift
        case "choice": f.onChoice = drift
        default: f.onCleanup = drift
        }
        let result = await f.run()
        #expect(f.popupPresses == (stage == "before" ? 0 : 1))
        #expect(f.leafPresses == (["before", "open"].contains(stage) ? 0 : 1))
        #expect(f.currentValue == (["before", "open"].contains(stage) ? "Off" : "1/16 Note"))
        try expectQuantizeRefusal(result, written: stage != "before", reason: "target_changed")
    }
    @Test(arguments: ["disabled", "absent", "malformed", "unread"])
    func disabledOrUnreadGridItemNeverPressed(_ kind: String) async throws {
        let f = QuantizeSafetyFixture(); let item = f.items[2]
        if kind == "unread" { f.failingAttribute = (item, kAXEnabledAttribute as String) }
        else if kind == "disabled" { f.b.setAttribute(item, kAXEnabledAttribute as String, false) }
        else if kind == "absent" { f.b.setAttribute(item, kAXEnabledAttribute as String, NSNull()) }
        else { f.b.setAttribute(item, kAXEnabledAttribute as String, "true") }
        let result = await f.run()
        #expect(f.popupPresses == 1); #expect(f.leafPresses == 0); #expect(f.currentValue == "Off"); #expect(f.cleanups == 1)
        try expectQuantizeRefusal(result, written: true)
    }
    @Test(arguments: ["row", "menu", "item_role", "item_title"])
    func unreadRowOrMenuCensusNeverCertifiesUniqueChoice(_ kind: String) async throws {
        let f = QuantizeSafetyFixture()
        if kind == "row" { f.failingChildren = f.row }
        else { f.onOpen = {
            if kind == "menu" { f.failingChildren = f.menu }
            else { f.failingAttribute = (f.items[0], kind == "item_role" ? kAXRoleAttribute as String : kAXTitleAttribute as String) }
        } }
        let result = await f.run()
        #expect(f.popupPresses == (kind == "row" ? 0 : 1)); #expect(f.leafPresses == 0); #expect(f.currentValue == "Off")
        try expectQuantizeRefusal(result, written: kind != "row")
    }
    @Test(arguments: ["unread", "still_open"])
    func dirtyPopupCleanupCannotReturnA(_ kind: String) async throws {
        let f = QuantizeSafetyFixture()
        f.cleanupOutcome = kind == "unread" ? .popupCountUnavailable : .couldNotDismiss(initialPopupCount: 1, remainingPopupCount: 1)
        let result = await f.run()
        #expect(f.popupPresses == 1); #expect(f.leafPresses == 1); #expect(f.currentValue == "1/16 Note")
        try expectQuantizeRefusal(result, written: true, reason: "popup_cleanup_unconfirmed")
    }
    @Test(arguments: ["row", "window"])
    func rowOrWindowReplacementCannotReturnA(_ kind: String) async throws {
        let f = QuantizeSafetyFixture()
        f.onChoice = {
            if kind == "row" { f.b.setChildren(f.row, []) }
            else {
                let replacement = f.b.element(109_498)
                f.b.setAttribute(f.app, kAXWindowsAttribute as String, [replacement])
                f.b.setAttribute(f.app, kAXMainWindowAttribute as String, replacement)
            }
        }
        let result = await f.run()
        #expect(f.popupPresses == 1); #expect(f.leafPresses == 1); #expect(f.currentValue == "1/16 Note")
        try expectQuantizeRefusal(result, written: true, reason: "target_changed")
    }
    @Test func aCleanReportWithTheOwnedAXMenuStillOpenCannotReturnA() async throws {
        let f = QuantizeSafetyFixture(); f.cleanupActuallyCloses = false
        f.onChoice = { f.b.setChildren(f.value, [f.menu]) }
        let result = await f.run()
        #expect(f.popupPresses == 1); #expect(f.leafPresses == 1); #expect(f.currentValue == "1/16 Note")
        try expectQuantizeRefusal(result, written: true, reason: "popup_cleanup_unconfirmed")
    }
    @Test func preexistingMenuIsNotOpenedOrCleaned() async throws {
        let f = QuantizeSafetyFixture(); f.b.setChildren(f.value, [f.menu])
        let result = await f.run()
        #expect(f.popupPresses == 0); #expect(f.leafPresses == 0); #expect(f.cleanups == 0); #expect(f.currentValue == "Off")
        try expectQuantizeRefusal(result, written: false)
    }
    @Test func unchangedStableMultiRegionSelectionStillSetsRequestedGrid() async throws {
        let f = QuantizeSafetyFixture(selected: 2)
        let result = await f.run()
        #expect(f.popupPresses == 1); #expect(f.leafPresses == 1); #expect(f.currentValue == "1/16 Note")
        #expect(result.isSuccess, "\(result.message)")
        let object = try #require(sharedJSONObject(result.message))
        #expect(object["state"] as? String == "A"); #expect(object["regions_selected"] as? Int == 2)
    }
}
