@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// T2 — drift-safe insert-slot enumeration (rev-4 D1/D4, AC12/AC21).
// audioPluginInsertSlots must preserve PHYSICAL slot positions and never drop
// an occupied-but-unreadable slot, and isEmpty (= write-safe) must be true
// ONLY for a verified-empty slot.

private func addEmptySlot(_ builder: FakeAXRuntimeBuilder, _ id: Int) -> AXUIElement {
    let el = builder.element(id)
    builder.setAttribute(el, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(el, kAXDescriptionAttribute as String, "오디오 플러그인")
    builder.setAttribute(el, kAXHelpAttribute as String, "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다.")
    return el
}

/// Occupied slot group: AXGroup + bypass + open children. `name == nil` makes
/// it occupied-unreadable; a non-nil name makes it occupied-readable.
private func addOccupiedSlot(_ builder: FakeAXRuntimeBuilder, _ id: Int, name: String?) -> AXUIElement {
    let group = builder.element(id)
    let bypass = builder.element(id * 10 + 1)
    let open = builder.element(id * 10 + 2)
    builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
    if let name { builder.setAttribute(group, kAXDescriptionAttribute as String, name) }
    builder.setChildren(group, [bypass, open])
    builder.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(bypass, kAXDescriptionAttribute as String, "바이패스")
    builder.setAttribute(bypass, kAXValueAttribute as String, 0)
    builder.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(open, kAXDescriptionAttribute as String, "열기")
    return group
}

private func addFader(_ builder: FakeAXRuntimeBuilder, _ id: Int) -> AXUIElement {
    let el = builder.element(id)
    builder.setAttribute(el, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(el, kAXDescriptionAttribute as String, "Volume Fader")
    return el
}

private func addFramedButton(
    _ builder: FakeAXRuntimeBuilder,
    _ id: Int,
    x: CGFloat = 100,
    y: CGFloat,
    width: CGFloat = 58,
    height: CGFloat = 18,
    description: String? = nil,
    help: String? = nil,
    subrole: String? = nil
) -> AXUIElement {
    let el = builder.element(id)
    builder.setAttribute(el, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(el, kAXPositionAttribute as String, axPoint(x, y))
    builder.setAttribute(el, kAXSizeAttribute as String, axSize(width, height))
    if let description { builder.setAttribute(el, kAXDescriptionAttribute as String, description) }
    if let help { builder.setAttribute(el, kAXHelpAttribute as String, help) }
    if let subrole { builder.setAttribute(el, kAXSubroleAttribute as String, subrole) }
    return el
}

// MARK: - AC12: physical index preserved across an unreadable occupied slot

@Test func testInsertSlotsPreservePhysicalIndexAcrossUnreadableOccupied() {
    let builder = FakeAXRuntimeBuilder()
    let strip = builder.element(500)
    let occ0 = addOccupiedSlot(builder, 501, name: "Gain")
    let unread1 = addOccupiedSlot(builder, 502, name: nil)       // occupied but name unreadable
    let occ2 = addOccupiedSlot(builder, 503, name: "Compressor")
    builder.setChildren(strip, [occ0, unread1, occ2])

    let slots = AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: builder.makeAXRuntime())

    #expect(slots.count == 3, "the unreadable occupied slot must NOT be dropped")
    #expect(slots[0].index == 0)
    #expect(slots[0].readStatus == .occupiedReadable)
    #expect(slots[0].name == "Gain")

    #expect(slots[1].index == 1, "physical index 1 must be preserved, not renumbered")
    #expect(slots[1].readStatus == .occupiedUnreadable)
    #expect(slots[1].name == nil)
    #expect(slots[1].occupied)
    #expect(!(slots[1].isEmpty), "AC21: occupied-unreadable is NOT write-safe")

    #expect(slots[2].index == 2, "the slot after an unreadable one keeps its physical index")
    #expect(slots[2].readStatus == .occupiedReadable)
    #expect(slots[2].name == "Compressor")
}

// MARK: - empty vs occupied classification

@Test func testEmptySlotIsWriteSafe() {
    let builder = FakeAXRuntimeBuilder()
    let strip = builder.element(520)
    let empty = addEmptySlot(builder, 521)
    builder.setChildren(strip, [empty])

    let slots = AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: builder.makeAXRuntime())
    #expect(slots.count == 1)
    #expect(slots[0].readStatus == .empty)
    #expect(slots[0].isEmpty)
    #expect(!(slots[0].occupied))
    #expect(slots[0].name == nil)
}

@Test func testNonSlotChildrenDoNotConsumeAnIndex() {
    // A fader/pan between recognised slots must not shift slot indices.
    let builder = FakeAXRuntimeBuilder()
    let strip = builder.element(540)
    let fader = addFader(builder, 541)
    let empty = addEmptySlot(builder, 542)
    let occ = addOccupiedSlot(builder, 543, name: "Channel EQ")
    builder.setChildren(strip, [fader, empty, occ])

    let slots = AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: builder.makeAXRuntime())
    #expect(slots.count == 2, "fader is not an insert slot")
    #expect(slots[0].readStatus == .empty && slots[0].index == 0)
    #expect(slots[1].readStatus == .occupiedReadable && slots[1].index == 1 && slots[1].name == "Channel EQ")
}

// MARK: - mixed inventory (AC12 full scenario)

@Test func testMixedReadableEmptyUnreadableSequence() {
    let builder = FakeAXRuntimeBuilder()
    let strip = builder.element(560)
    let occReadable = addOccupiedSlot(builder, 561, name: "Noise Gate")
    let empty = addEmptySlot(builder, 562)
    let occUnreadable = addOccupiedSlot(builder, 563, name: nil)
    builder.setChildren(strip, [occReadable, empty, occUnreadable])

    let slots = AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: builder.makeAXRuntime())
    #expect(slots.map(\.readStatus) == [.occupiedReadable, .empty, .occupiedUnreadable])
    #expect(slots.map(\.index) == [0, 1, 2])
    #expect(!(slots[2].isEmpty), "an unreadable slot is never treated as the empty slot")
}

@Test func testLanguageNeutralEmptySlotClusterIsRecognizedByGeometry() {
    let builder = FakeAXRuntimeBuilder()
    let strip = builder.element(580)
    let output = addFramedButton(builder, 581, y: 560, description: "Ausgang")
    let send = addFramedButton(builder, 582, y: 540, width: 40, description: "Send")
    let slot0 = addFramedButton(builder, 583, y: 500)
    let slot1 = addFramedButton(builder, 584, y: 483)
    let slot2 = addFramedButton(builder, 585, y: 466)
    let slot3 = addFramedButton(builder, 586, y: 449)
    let input = addFramedButton(builder, 587, y: 420, description: "Eingang")
    builder.setChildren(strip, [output, send, slot0, slot1, slot2, slot3, input])

    let slots = AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: builder.makeAXRuntime())

    #expect(slots.count == 4)
    #expect(slots.map(\.index) == [0, 1, 2, 3])
    #expect(slots.allSatisfy { $0.isEmpty })
}

@Test func testLanguageNeutralGeometryDoesNotPromoteSingleButtonOrPhantomStub() {
    let builder = FakeAXRuntimeBuilder()
    let strip = builder.element(590)
    let settings = addFramedButton(builder, 591, y: 500, description: "Einstellungen")
    let phantom = addFramedButton(builder, 592, y: 470, width: 58, height: 9)
    builder.setChildren(strip, [settings, phantom])

    let slots = AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: builder.makeAXRuntime())

    #expect(slots.isEmpty)
}
