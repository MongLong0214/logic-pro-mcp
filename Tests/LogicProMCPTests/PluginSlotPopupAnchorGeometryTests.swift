@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

struct PluginSlotPopupAnchorGeometryTests {
    private func anchored(menu: CGRect, slot: CGRect = CGRect(x: 1842, y: 527, width: 58, height: 18)) -> Bool {
        let builder = FakeAXRuntimeBuilder()
        let slotElement = builder.element(110710)
        let menuElement = builder.element(110711)
        builder.setAttribute(slotElement, kAXPositionAttribute as String, axPoint(slot.minX, slot.minY))
        builder.setAttribute(slotElement, kAXSizeAttribute as String, axSize(slot.width, slot.height))
        builder.setAttribute(menuElement, kAXPositionAttribute as String, axPoint(menu.minX, menu.minY))
        builder.setAttribute(menuElement, kAXSizeAttribute as String, axSize(menu.width, menu.height))
        let result = AccessibilityChannel.slotPopupMenuIsAnchored(
            menuElement, toSlot: slotElement, runtime: builder.makeAXRuntime()
        )
        #expect(builder.actionCalls.isEmpty && builder.setCalls.isEmpty)
        return result
    }

    @Test
    func measuredLeftOpeningPopupTouchesSlotAndIsAnchored() {
        // Measured on the owned native fixture: menu.right == slot.left.
        #expect(anchored(menu: CGRect(x: 1612, y: 530, width: 230, height: 527)))
    }

    @Test
    func popupOnePointShortOfLeftSlotEdgeIsNotAnchored() {
        #expect(!anchored(menu: CGRect(x: 1612, y: 530, width: 229, height: 527)))
    }

    @Test
    func touchingHorizontallyDoesNotExcuseRemoteVerticalPopup() {
        #expect(!anchored(menu: CGRect(x: 1612, y: 1000, width: 230, height: 527)))
    }

    @Test
    func legacyOriginBandRemainsAcceptedWithoutIntervalContact() {
        #expect(anchored(menu: CGRect(x: 2000, y: 530, width: 230, height: 527)))
    }

    @Test
    func degenerateMenuAndSlotSizesRemainRejected() {
        for menu in [
            CGRect(x: 1612, y: 530, width: 0, height: 527),
            CGRect(x: 1612, y: 530, width: 20, height: 527),
            CGRect(x: 1612, y: 530, width: 230, height: 0),
            CGRect(x: 1612, y: 530, width: 230, height: 20),
        ] {
            #expect(!anchored(menu: menu))
        }
        let menu = CGRect(x: 1612, y: 530, width: 230, height: 527)
        for slot in [
            CGRect(x: 1842, y: 527, width: 0, height: 18),
            CGRect(x: 1842, y: 527, width: 1, height: 18),
            CGRect(x: 1842, y: 527, width: 58, height: 0),
            CGRect(x: 1842, y: 527, width: 58, height: 1),
        ] {
            #expect(!anchored(menu: menu, slot: slot))
        }
    }
}
