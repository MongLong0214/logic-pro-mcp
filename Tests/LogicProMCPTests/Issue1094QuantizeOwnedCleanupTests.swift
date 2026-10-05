@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

// The default production cleanup path, but every AX/CG/action/Escape boundary is explicitly fake.
private final class OwnedQuantizeCleanupFixture: @unchecked Sendable {
    let f = QuantizeSafetyFixture()
    var otherPresent = false
    var ownCancels = 0
    var otherCancels = 0
    var escapes = 0
    var injectDuringReadback = false
    var injectedDuringReadback = false
    var postChoiceWindowReads = 0
    let other: AXUIElement

    init() {
        other = f.b.element(109_490)
        f.b.setAttribute(other, kAXRoleAttribute as String, kAXMenuRole as String)
        f.b.setChildren(other, [])
        f.b.setActionNames(other, [kAXCancelAction as String])
        f.b.setActionNames(f.menu, [kAXCancelAction as String])
        let base = f.runtime.ax
        let ax = AXHelpers.Runtime(
            axApp: base.axApp, attributeValue: base.attributeValue,
            attributeIsSettable: base.attributeIsSettable, setAttributeValue: base.setAttributeValue,
            children: base.children,
            performAction: { [self] element, action in
                if action == kAXCancelAction as String {
                    if CFEqual(element, other) {
                        otherCancels += 1; otherPresent = false
                        f.b.setChildren(f.window, base.children(f.window).filter { !CFEqual($0, other) })
                    } else if CFEqual(element, f.menu) {
                        ownCancels += 1; f.b.setChildren(f.value, [])
                    } else { Issue.record("cancel targeted an unowned fixture element") }
                    return true
                }
                return base.performAction(element, action)
            },
            childCount: base.childCount, actionNames: base.actionNames,
            actionNamesResult: base.actionNamesResult, childrenResult: base.childrenResult,
            attributeValueResult: { [self] element, attribute in
                if injectDuringReadback, !injectedDuringReadback, f.leafPresses == 1,
                   postChoiceWindowReads >= 2, CFEqual(element, f.value), attribute == kAXValueAttribute as String {
                    injectedDuringReadback = true
                    exposeOtherMenu()
                }
                return base.attributeValueResult?(element, attribute) ?? .success(base.attributeValue(element, attribute))
            })
        f.runtime = .init(logicProPID: { 4242 }, ax: ax,
                          executeAppleScript: { _ in Issue.record("no native script"); return .error("owned") },
                          onScreenWindowList: { [self] in
                              if f.leafPresses > 0 { postChoiceWindowReads += 1 }
                              let ownPresent = base.children(f.value).contains { CFEqual($0, f.menu) }
                              return (0..<((ownPresent ? 1 : 0) + (otherPresent ? 1 : 0))).map { index in
                                  [kCGWindowOwnerPID as String: 4242,
                                   kCGWindowNumber as String: 109_494 + index,
                                   kCGWindowLayer as String: Int(CGWindowLevelForKey(.popUpMenuWindow))]
                              }
                          },
                          postPopupMenuEscape: { [self] in escapes += 1 }, focusedApplicationPID: { 4242 })
    }

    func exposeOtherMenu() {
        otherPresent = true
        f.b.setChildren(f.window, f.runtime.ax.children(f.window) + [other])
    }

    func run() async -> ChannelResult {
        await AccessibilityChannel.quantizeSelectedRegions(
            params: ["value": "1/16"], runtime: f.runtime, timing: .immediate)
    }
}

@Suite("#1094 quantize owns only its causally opened popup cleanup")
struct Issue1094QuantizeOwnedCleanupTests {
    @Test func aUserPopupAppearingDuringReadbackCannotInheritTheEarlierCleanCertificate() async throws {
        let fixture = OwnedQuantizeCleanupFixture()
        fixture.injectDuringReadback = true
        let result = await fixture.run()
        #expect(fixture.injectedDuringReadback); #expect(fixture.postChoiceWindowReads >= 2)
        #expect(fixture.f.popupPresses == 1); #expect(fixture.f.leafPresses == 1)
        #expect(fixture.f.currentValue == "1/16 Note")
        #expect(fixture.otherCancels == 0); #expect(fixture.ownCancels == 0); #expect(fixture.escapes == 0)
        #expect(fixture.otherPresent); #expect(!result.isSuccess, "\(result.message)")
        let object = try #require(sharedJSONObject(result.message))
        #expect(object["state"] as? String == "C")
        #expect(object["quantize_refusal"] as? String == "popup_cleanup_unconfirmed")
        let written = try #require(object["write_attempted"] as? Bool); #expect(written)
    }

    @Test func aDifferentUserPopupAfterTheChoiceIsNeverCancelledOrEscaped() async throws {
        let fixture = OwnedQuantizeCleanupFixture()
        fixture.f.onChoice = { fixture.exposeOtherMenu() }
        let result = await fixture.run()
        #expect(fixture.f.popupPresses == 1); #expect(fixture.f.leafPresses == 1)
        #expect(fixture.f.currentValue == "1/16 Note")
        #expect(fixture.otherCancels == 0); #expect(fixture.ownCancels == 0); #expect(fixture.escapes == 0)
        #expect(fixture.otherPresent); #expect(!result.isSuccess, "\(result.message)")
        let object = try #require(sharedJSONObject(result.message))
        #expect(object["state"] as? String == "C")
        let written = try #require(object["write_attempted"] as? Bool); #expect(written)
    }

    @Test func unreadOwnedPopupIdentityDoesNotCancelAnyUserMenu() async throws {
        let fixture = OwnedQuantizeCleanupFixture()
        fixture.f.onOpen = {
            fixture.f.failingChildren = fixture.f.value
            fixture.exposeOtherMenu()
        }
        let result = await fixture.run()
        #expect(fixture.f.popupPresses == 1); #expect(fixture.f.leafPresses == 0)
        #expect(fixture.f.currentValue == "Off")
        #expect(fixture.otherCancels == 0); #expect(fixture.ownCancels == 0); #expect(fixture.escapes == 0)
        #expect(fixture.otherPresent); #expect(!result.isSuccess, "\(result.message)")
        let object = try #require(sharedJSONObject(result.message))
        #expect(object["state"] as? String == "C")
        let written = try #require(object["write_attempted"] as? Bool); #expect(written)
    }

    @Test func theStillAttachedOwnedPopupCanBeCancelledAndItsRemovalCertified() async throws {
        let fixture = OwnedQuantizeCleanupFixture()
        fixture.f.onChoice = { fixture.f.b.setChildren(fixture.f.value, [fixture.f.menu]) }
        let result = await fixture.run()
        #expect(fixture.f.popupPresses == 1); #expect(fixture.f.leafPresses == 1)
        #expect(fixture.ownCancels == 1); #expect(fixture.otherCancels == 0); #expect(fixture.escapes == 0)
        #expect(fixture.f.runtime.ax.children(fixture.f.value).isEmpty)
        #expect(result.isSuccess, "\(result.message)")
    }
}
