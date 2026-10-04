@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// Insert slots are numbered in screen order, and a software instrument's instrument slot is not an
// insert. Every fixture here is the Mixer strip of a software-instrument track as Logic 12.3.1
// (German) drew it: from the top Piano in the instrument slot, then Channel EQ, Compressor and
// ChromaVerb, then the 9 px "Audio-Plug-in" button. Logic lists that strip's children bottom-up,
// ChromaVerb first and the instrument slot after the inserts, and puts a 1 px button directly
// above each insert. No AX element is read from a running Logic.

private let stripX: CGFloat = 738
private let stripWidth: CGFloat = 58

private func framed(_ b: FakeAXRuntimeBuilder, _ el: AXUIElement, y: CGFloat, height: CGFloat) {
    b.setAttribute(el, kAXPositionAttribute as String, axPoint(stripX, y))
    b.setAttribute(el, kAXSizeAttribute as String, axSize(stripWidth, height))
}

private func button(
    _ b: FakeAXRuntimeBuilder, _ id: Int, y: CGFloat, height: CGFloat,
    description: String, help: String? = nil
) -> AXUIElement {
    let el = b.element(id)
    b.setAttribute(el, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(el, kAXDescriptionAttribute as String, description)
    if let help { b.setAttribute(el, kAXHelpAttribute as String, help) }
    framed(b, el, y: y, height: height)
    return el
}

/// An occupied slot as the strip draws it: an AXGroup named by its plug-in, holding the bypass
/// checkbox and the open and list buttons. `y: nil` leaves its frame unreadable.
private func occupied(
    _ b: FakeAXRuntimeBuilder, _ id: Int, _ name: String, y: CGFloat?, height: CGFloat = 16
) -> AXUIElement {
    let group = b.element(id)
    let bypass = b.element(id * 10 + 1)
    let open = b.element(id * 10 + 2)
    let list = b.element(id * 10 + 3)
    b.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
    b.setAttribute(group, kAXDescriptionAttribute as String, name)
    if let y { framed(b, group, y: y, height: height) }
    b.setChildren(group, [bypass, open, list])
    b.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    b.setAttribute(bypass, kAXDescriptionAttribute as String, "Umgehen")
    b.setAttribute(bypass, kAXValueAttribute as String, 0)
    b.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(open, kAXDescriptionAttribute as String, "geöffnet")
    b.setAttribute(list, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(list, kAXDescriptionAttribute as String, "Liste")
    return group
}

private func separator(_ b: FakeAXRuntimeBuilder, _ id: Int, y: CGFloat) -> AXUIElement {
    button(b, id, y: y, height: 1, description: "Takt einfügen")
}

private let midiEffectHelp = "MIDI-Effekt-Slot. Hiermit fügst du einen MIDI-Effekt ein. "
    + "Klicke auf einen belegten Slot, um das Plug-in zu öffnen. "
private let audioEffectHelp = "Audioeffekt-Slot. Füge einen Audioeffekt ein. Klicke auf einen belegten Slot, "
    + "um das Plug-in zu öffnen. Mit Effekten können Signale in Echtzeit verändert werden. "

/// The parts of the measured strip, keyed so a test can reorder, drop or alter one.
private struct MeasuredStrip {
    var send, appendButton, separatorChroma, chroma, separatorComp, comp, separatorEQ, channelEQ,
        piano, midiSlot, eqDisplay: AXUIElement

    init(_ b: FakeAXRuntimeBuilder, pianoY: CGFloat? = 627, midiHelp: String? = midiEffectHelp) {
        send = button(b, 810, y: 739, height: 18, description: "Taste „Send“",
                      help: "Send-Slot. Das Signal wird an einen Aux-Channel-Strip gesendet. ")
        appendButton = button(b, 811, y: 704, height: 9, description: "Audio-Plug-in", help: audioEffectHelp)
        separatorChroma = separator(b, 812, y: 687)
        chroma = occupied(b, 813, "ChromaVerb", y: 688)
        separatorComp = separator(b, 814, y: 670)
        comp = occupied(b, 815, "Compressor", y: 671)
        separatorEQ = separator(b, 816, y: 653)
        channelEQ = occupied(b, 817, "Channel EQ", y: 654)
        piano = occupied(b, 818, "Piano", y: pianoY, height: 18)
        midiSlot = button(b, 819, y: 601, height: 18, description: "MIDI-Plug-in", help: midiHelp)
        eqDisplay = button(b, 820, y: 567, height: 29, description: "EQ",
                           help: "EQ-Darstellung. Füge Channel-EQs durch Klicken hinzu. ")
    }

    /// Logic's own child order for this strip: bottom-up, the instrument slot after the inserts.
    var axOrder: [AXUIElement] {
        [send, appendButton, separatorChroma, chroma, separatorComp, comp, separatorEQ, channelEQ,
         piano, midiSlot, eqDisplay]
    }
}

private func slots(_ children: [AXUIElement], _ b: FakeAXRuntimeBuilder) -> [AXLogicProElements.PluginInsertSlot] {
    AXLogicProElements.audioPluginInsertSlots(children: children, runtime: b.makeAXRuntime())
}

private func mixerRuntime(
    _ b: FakeAXRuntimeBuilder, stripChildren: [AXUIElement]
) -> AXLogicProElements.Runtime {
    let app = b.element(700)
    let window = b.element(701)
    let mixer = b.element(702)
    let strip = b.element(703)
    b.setAttribute(app, kAXMainWindowAttribute as String, window)
    b.setChildren(window, [mixer])
    b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
    b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
    b.setChildren(mixer, [strip])
    b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    b.setChildren(strip, stripChildren)
    addPluginTrackAssociation(b, window: window, strip: strip)
    return b.makeLogicRuntime(appElement: app)
}

private func decode(_ message: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any] ?? [:]
}

// MARK: - Screen order and the instrument slot

@Test func insertSlotsFollowTheScreenNotTheBottomUpChildOrder() {
    let b = FakeAXRuntimeBuilder()
    let strip = MeasuredStrip(b)

    let read = slots(strip.axOrder, b)

    #expect(read.map(\.name) == ["Channel EQ", "Compressor", "ChromaVerb"])
    #expect(read.map(\.index) == [0, 1, 2])
    #expect(read.allSatisfy { $0.readStatus == .occupiedReadable })
}

@Test func theInstrumentSlotIsNeverAnInsert() {
    let b = FakeAXRuntimeBuilder()
    let strip = MeasuredStrip(b)

    let read = slots(strip.axOrder, b)

    #expect(!read.contains { $0.name == "Piano" })
    #expect(!read.contains { CFEqual($0.element, strip.piano) })
    #expect(read.count == 3)
}

@Test func theInstrumentSlotDoesNotShiftTheInsertIndicesWhereverItSitsInTheChildList() {
    let b = FakeAXRuntimeBuilder()
    let strip = MeasuredStrip(b)
    var instrumentFirst = strip.axOrder
    instrumentFirst.removeAll { CFEqual($0, strip.piano) }
    instrumentFirst.insert(strip.piano, at: 0)

    let read = slots(instrumentFirst, b)

    #expect(read.map(\.name) == ["Channel EQ", "Compressor", "ChromaVerb"])
    #expect(read.map(\.index) == [0, 1, 2])
}

@Test func theNinePixelAudioPlugInButtonIsNotAnEmptyInsert() {
    let b = FakeAXRuntimeBuilder()
    let strip = MeasuredStrip(b)

    let read = slots(strip.axOrder, b)

    #expect(!read.contains { CFEqual($0.element, strip.appendButton) })
    #expect(!read.contains { $0.isEmpty })
    #expect(read.count == 3, "no insert 3 is made out of the append button")
}

// MARK: - What the rule cannot account for is unclassified

@Test func anInstrumentSlotWithASeparatorAboveItLeavesTheStripUnclassified() {
    let b = FakeAXRuntimeBuilder()
    let strip = MeasuredStrip(b)
    let extra = separator(b, 830, y: 626)

    let read = slots(strip.axOrder + [extra], b)

    #expect(!read.isEmpty)
    #expect(read.allSatisfy { $0.readStatus == .unclassified })
    #expect(!read.contains { $0.isEmpty })
}

@Test func twoBareGroupsOnAnInstrumentStripLeaveItUnclassified() {
    let b = FakeAXRuntimeBuilder()
    let strip = MeasuredStrip(b)
    let second = occupied(b, 831, "Arpeggiator", y: 580, height: 18)

    let read = slots(strip.axOrder + [second], b)

    #expect(read.allSatisfy { $0.readStatus == .unclassified })
}

@Test func anInsertAboveTheInstrumentSlotLeavesTheStripUnclassified() {
    let b = FakeAXRuntimeBuilder()
    let strip = MeasuredStrip(b, pianoY: 690)

    let read = slots(strip.axOrder, b)

    #expect(read.allSatisfy { $0.readStatus == .unclassified })
}

@Test func anUnreadableFrameLeavesTheStripUnclassified() {
    let b = FakeAXRuntimeBuilder()
    let strip = MeasuredStrip(b, pianoY: nil)

    let read = slots(strip.axOrder, b)

    #expect(read.allSatisfy { $0.readStatus == .unclassified })
}

@Test func anInstrumentStripWithoutAReadableMidiSlotFrameIsUnclassified() {
    let b = FakeAXRuntimeBuilder()
    let strip = MeasuredStrip(b)
    let unframedMidiSlot = b.element(832)
    b.setAttribute(unframedMidiSlot, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(unframedMidiSlot, kAXHelpAttribute as String, midiEffectHelp)
    let children = strip.axOrder.map { CFEqual($0, strip.midiSlot) ? unframedMidiSlot : $0 }

    let read = slots(children, b)

    #expect(read.allSatisfy { $0.readStatus == .unclassified })
}

@Test(arguments: [AXError.failure.rawValue, AXError.cannotComplete.rawValue])
func aFailedMidiHelpReadDoesNotTurnAnInstrumentIntoAnAudioInsert(_ status: Int32) {
    let b = FakeAXRuntimeBuilder()
    let strip = MeasuredStrip(b)
    let runtime = b.makeAXRuntime(
        attributeValueHandler: { element, attribute in
            if CFEqual(element, strip.midiSlot), attribute == kAXHelpAttribute as String {
                return .some(nil)
            }
            return nil
        },
        attributeValueResultHandler: { element, attribute in
            if CFEqual(element, strip.midiSlot), attribute == kAXHelpAttribute as String {
                return .failure(AXHelpers.AXStatusError(raw: status))
            }
            return nil
        },
        setAttributeHandler: nil, performActionHandler: nil
    )
    let read = AXLogicProElements.audioPluginInsertSlots(children: strip.axOrder, runtime: runtime)
    #expect(!read.isEmpty)
    #expect(read.allSatisfy { $0.readStatus == .unclassified })
    #expect(!AccessibilityChannel.pluginInventoryItems(for: read).complete)
}

@Test func malformedMidiHelpDoesNotTurnAnInstrumentIntoAnAudioInsert() {
    let b = FakeAXRuntimeBuilder()
    let strip = MeasuredStrip(b)
    b.setAttribute(strip.midiSlot, kAXHelpAttribute as String, NSNumber(value: 0))
    let read = slots(strip.axOrder, b)
    #expect(read.allSatisfy { $0.readStatus == .unclassified })
    #expect(!AccessibilityChannel.pluginInventoryItems(for: read).complete)
}

@Test(arguments: [AXError.attributeUnsupported.rawValue, AXError.noValue.rawValue])
func definitiveHelpAbsenceDoesNotRefuseAnAudioStrip(_ status: Int32) {
    let b = FakeAXRuntimeBuilder()
    let lower = occupied(b, 890, "Compressor", y: 420)
    let upper = occupied(b, 891, "Channel EQ", y: 400)
    let runtime = b.makeAXRuntime(
        attributeValueResultHandler: { _, attribute in
            attribute == kAXHelpAttribute as String ? .failure(AXHelpers.AXStatusError(raw: status)) : nil
        },
        setAttributeHandler: nil, performActionHandler: nil
    )
    let read = AXLogicProElements.audioPluginInsertSlots(children: [lower, upper], runtime: runtime)
    #expect(read.map(\.name) == ["Channel EQ", "Compressor"])
    #expect(read.allSatisfy { $0.readStatus == .occupiedReadable })
}

@Test func twoSlotsAtTheSameHeightLeaveTheStripUnclassified() {
    let b = FakeAXRuntimeBuilder()
    let first = occupied(b, 840, "Gain", y: 400)
    let second = occupied(b, 841, "Compressor", y: 400)

    let read = slots([first, second], b)

    #expect(read.allSatisfy { $0.readStatus == .unclassified })
}

@Test(arguments: ["nan-position", "infinite-position", "zero-width", "negative-height"])
func invalidMultiSlotGeometryIsNotAnAddressableOrder(_ caseName: String) {
    let b = FakeAXRuntimeBuilder()
    let upper = occupied(b, 842, "Gain", y: 400)
    let lower = occupied(b, 843, "Compressor", y: 420)
    switch caseName {
    case "nan-position": b.setAttribute(lower, kAXPositionAttribute as String, axPoint(.nan, 420))
    case "infinite-position": b.setAttribute(lower, kAXPositionAttribute as String, axPoint(738, .infinity))
    case "zero-width": b.setAttribute(lower, kAXSizeAttribute as String, axSize(0, 16))
    default: b.setAttribute(lower, kAXSizeAttribute as String, axSize(58, -16))
    }
    let read = slots([lower, upper], b)
    #expect(!read.isEmpty)
    #expect(read.allSatisfy { $0.readStatus == .unclassified })
    #expect(!AccessibilityChannel.pluginInventoryItems(for: read).complete)
}

@Test func aStripWithoutAMidiSlotIsOnlySortedByScreenPosition() {
    let b = FakeAXRuntimeBuilder()
    let lower = occupied(b, 850, "Compressor", y: 420)
    let upper = occupied(b, 851, "Channel EQ", y: 400)

    let read = slots([lower, upper], b)

    #expect(read.map(\.name) == ["Channel EQ", "Compressor"])
    #expect(read.map(\.index) == [0, 1])
    #expect(read.allSatisfy { $0.readStatus == .occupiedReadable })
}

// MARK: - get_inventory, logic://mixer and the write paths

@Test func getInventoryNumbersTheMeasuredStripTopDownAndIsComplete() async throws {
    let b = FakeAXRuntimeBuilder()
    let runtime = mixerRuntime(b, stripChildren: MeasuredStrip(b).axOrder)

    // The mixer is in the fixture; a reveal that would actuate records an issue instead of reaching Logic.
    let result = await AccessibilityChannel.defaultGetPluginInventory(
        params: ["track": "0"], runtime: runtime,
        revealMixer: Issue982UnreadChildrenTests.revealWithoutActuating)
    let obj = decode(result.message)
    let plugins = obj["plugins"] as? [[String: Any]] ?? []

    let complete = try #require(obj["complete"] as? Bool)
    #expect(complete)
    #expect(obj["track_name"] as? String == "Fixture Track")
    #expect(plugins.map { $0["insert"] as? Int } == [0, 1, 2])
    #expect(plugins.map { $0["name"] as? String } == ["Channel EQ", "Compressor", "ChromaVerb"])
    #expect(plugins.map { $0["plugin_id"] as? String }
        == ["logic.stock.effect.channel_eq", "logic.stock.effect.compressor", nil])
    #expect(!plugins.contains { $0["read_status"] as? String == "empty" })
}

@Test func getInventoryOfAnUnclassifiedStripIsIncomplete() async throws {
    let b = FakeAXRuntimeBuilder()
    let strip = MeasuredStrip(b)
    let runtime = mixerRuntime(b, stripChildren: strip.axOrder + [separator(b, 860, y: 626)])

    // The mixer is in the fixture; a reveal that would actuate records an issue instead of reaching Logic.
    let result = await AccessibilityChannel.defaultGetPluginInventory(
        params: ["track": "0"], runtime: runtime,
        revealMixer: Issue982UnreadChildrenTests.revealWithoutActuating)
    let obj = decode(result.message)
    let plugins = obj["plugins"] as? [[String: Any]] ?? []

    let complete = try #require(obj["complete"] as? Bool)
    #expect(!complete)
    #expect(!plugins.isEmpty)
    #expect(plugins.allSatisfy { $0["read_status"] as? String == "unclassified" })
    #expect(plugins.allSatisfy { $0["plugin_id"] is NSNull })
}

@Test func theMixerResourceListsTheSameInsertsAsGetInventory() {
    let b = FakeAXRuntimeBuilder()
    let strip = b.element(870)
    b.setChildren(strip, MeasuredStrip(b).axOrder)

    let plugins = AXLogicProElements.pluginSlots(in: strip, runtime: b.makeAXRuntime())

    #expect(plugins?.map(\.name) == ["Channel EQ", "Compressor", "ChromaVerb"])
    #expect(plugins?.map(\.index) == [0, 1, 2])
}

@Test func theMixerResourcePublishesNoListForAnUnclassifiedStrip() {
    let b = FakeAXRuntimeBuilder()
    let strip = b.element(871)
    let measured = MeasuredStrip(b)
    b.setChildren(strip, measured.axOrder + [separator(b, 872, y: 626)])

    #expect(AXLogicProElements.pluginSlots(in: strip, runtime: b.makeAXRuntime()) == nil)
}

@Test func insertVerifiedRefusesAnUnclassifiedStripBeforeAnyWrite() async throws {
    let b = FakeAXRuntimeBuilder()
    let measured = MeasuredStrip(b)
    let runtime = mixerRuntime(b, stripChildren: measured.axOrder + [separator(b, 880, y: 626)])
    let path = "/Users/test/Music/Logic/Test.logicx"
    let driver: AccessibilityChannel.PluginInsertDriver = { _, _, _, _, _ in
        Issue.record("the insert driver must not run on an unclassified strip")
        return (.mountMismatch(observedName: nil), [:])
    }

    let result = await AccessibilityChannel.defaultInsertVerified(
        params: ["track": "0", "insert": "0", "plugin": "Gain", "mode": "duplicate_applyback",
                 "project_expected_path": path],
        runtime: runtime, frontDocumentPath: { path }, insertDriver: driver,
        rollback: { _, _, _, _ in
            Issue.record("nothing was written, so nothing is rolled back")
            return AccessibilityChannel.RollbackResult(
                attempted: false, succeeded: false, retries: 0, lastClickResult: "missing")
        }
    )
    let obj = decode(result.message)

    #expect(!result.isSuccess)
    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "incomplete_inventory")
    #expect(obj["what_was_observed"] as? String
        == "one or more insert slots are unreadable (complete:false)")
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect(b.actionCalls.isEmpty)
}
