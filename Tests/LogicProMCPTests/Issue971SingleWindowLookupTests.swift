@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#971 single native window lookup", .serialized)
struct Issue971SingleWindowLookupTests {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func resolve(_ runtime: AXLogicProElements.Runtime, verified: Bool) -> AXUIElement? {
        if verified {
            if case .found(let window) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime) { return window }
        } else if case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime) { return window }
        return nil
    }

    @Test(arguments: [false, true], ["sole", "dialog", "system_dialog"])
    func aSoleNonDialogWindowNeedsNoDescendantSearch(verified: Bool, profile: String) throws {
        let b = FakeAXRuntimeBuilder(), reads = Reads()
        let app = b.element(971_510), window = b.element(971_511), dialog = b.element(971_512)
        let descendants = (0..<32).map { b.element(971_520 + $0) }
        for node in descendants { b.setRole(node, kAXGroupRole as String); b.setChildren(node, []) }
        b.setChildren(window, descendants)
        b.setAttribute(dialog, kAXSubroleAttribute as String,
            profile == "system_dialog" ? kAXSystemDialogSubrole as String : kAXDialogSubrole as String)
        b.setAttribute(app, kAXWindowsAttribute as String, profile == "sole" ? [window] : [dialog, window])
        b.setAttribute(app, kAXMainWindowAttribute as String, dialog)
        let runtime = b.makeLogicRuntime(appElement: app, childrenHandler: { _ in
            reads.record()
            return nil
        }, childrenResultHandler: { _ in
            reads.record()
            return nil
        }, setAttributeHandler: nil, performActionHandler: nil)
        let resolved = try #require(resolve(runtime, verified: verified))
        #expect(CFEqual(resolved, window))
        #expect(reads.count == 0, "The sole non-dialog is already the exact legacy fallback; its descendants cannot change that choice")
        #expect(b.actionCalls.isEmpty && b.setCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    func multipleNonDialogWindowsStillRequireTheExistingTrackRailPreference(verified: Bool) throws {
        let b = FakeAXRuntimeBuilder(), reads = Reads()
        let app = b.element(971_610), other = b.element(971_611), arrange = b.element(971_612), rail = b.element(971_613)
        b.setChildren(other, [])
        b.setChildren(arrange, [rail])
        b.setRole(rail, kAXGroupRole as String)
        b.setAttribute(rail, kAXDescriptionAttribute as String, "Tracks header")
        b.setChildren(rail, [])
        b.setAttribute(app, kAXWindowsAttribute as String, [other, arrange])
        let runtime = b.makeLogicRuntime(appElement: app, childrenHandler: { _ in
            reads.record()
            return nil
        }, childrenResultHandler: { _ in
            reads.record()
            return nil
        }, setAttributeHandler: nil, performActionHandler: nil)
        let resolved = try #require(resolve(runtime, verified: verified))
        #expect(CFEqual(resolved, arrange))
        #expect(reads.count > 0, "Do not select the first window when another owns the native rail")
    }

    @Test(arguments: [false, true])
    func localizedArrangeTitleOutranksMarkerListRowsThatMimicTheTrackRail(verified: Bool) throws {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(971_650), markerList = b.element(971_651)
        let arrange = b.element(971_652), markerRows = b.element(971_653)
        let markerRow = b.element(971_654)
        b.setAttribute(markerList, kAXTitleAttribute as String, "Fixture - Marker List")
        b.setAttribute(arrange, kAXTitleAttribute as String, "Fixture - Tracks")
        b.setRole(markerRows, kAXGroupRole as String)
        b.setRole(markerRow, kAXLayoutItemRole as String)
        b.setChildren(markerRows, [markerRow])
        b.setAttribute(markerRows, kAXSelectedChildrenAttribute as String, [markerRow])
        b.setChildren(markerList, [markerRows])
        b.setChildren(arrange, [])
        b.setAttribute(app, kAXWindowsAttribute as String, [markerList, arrange])

        let resolved = try #require(resolve(b.makeLogicRuntime(appElement: app), verified: verified))
        #expect(CFEqual(resolved, arrange))
        #expect(b.actionCalls.isEmpty && b.setCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    func dialogOnlyWindowsStillSupplyNoArrangeWindow(verified: Bool) {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(971_710), dialog = b.element(971_711)
        b.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        b.setAttribute(app, kAXWindowsAttribute as String, [dialog])
        #expect(resolve(b.makeLogicRuntime(appElement: app), verified: verified) == nil)
    }
}
