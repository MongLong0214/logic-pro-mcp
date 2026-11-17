import Foundation
import Testing
@testable import LogicProMCP

// `nav.create_marker` puts back the Arrange region selection Logic's Create Marker clears. These
// drive the decision with a model Arrange area whose AXSelected write TOGGLES, as Logic's does.

private final class ModelArrange {
    var regions: [(id: String, info: RegionInfo, selected: Bool)]
    var scopeComplete = true
    var readable = true
    /// When false a write is accepted and changes nothing, as an ignored AX write does.
    var writesTakeEffect = true
    var writes: [String] = []

    init(_ regions: [(String, RegionInfo, Bool)]) {
        self.regions = regions.map { (id: $0.0, info: $0.1, selected: $0.2) }
    }

    func read() -> AccessibilityChannel.RegionSelectionReading<String>? {
        guard readable else { return nil }
        return .init(
            scopeComplete: scopeComplete,
            regions: regions.map { (item: $0.id, info: $0.info, selected: $0.selected) })
    }

    func select(_ id: String) -> Bool {
        writes.append(id)
        if writesTakeEffect, let index = regions.firstIndex(where: { $0.id == id }) {
            regions[index].selected.toggle()
        }
        return true
    }

    func setAll(selected: Bool) {
        for index in regions.indices { regions[index].selected = selected }
    }
}

private func region(_ name: String, track: Int = 2, start: Int = 1, end: Int = 2) -> RegionInfo {
    RegionInfo(name: name, trackIndex: track, startBar: start, endBar: end, kind: "midi", rawHelp: nil)
}

private func restore(
    _ arrange: ModelArrange,
    before: AccessibilityChannel.RegionSelectionReading<String>?,
    afterPress: () -> Void
) -> AccessibilityChannel.RegionSelectionRestoreOutcome {
    afterPress()
    return AccessibilityChannel.restoreRegionSelection(
        before: before, read: arrange.read, select: arrange.select, settle: {})
}

@Test func regionSelectionClearedByTheCreateIsWrittenBackOnce() {
    let arrange = ModelArrange([("a", region("MIDI"), true), ("b", region("Other", track: 3), false)])
    let before = arrange.read()
    let outcome = restore(arrange, before: before) { arrange.setAll(selected: false) }
    #expect(outcome == .restored)
    #expect(arrange.writes == ["a"])
    #expect(arrange.regions.map(\.selected) == [true, false])
}

@Test func anUnchangedSelectionIsNeverWritten() {
    // A write toggles, so writing to a region that is still selected would deselect it.
    let arrange = ModelArrange([("a", region("MIDI"), true)])
    let outcome = restore(arrange, before: arrange.read()) {}
    #expect(outcome == .unchanged)
    #expect(arrange.writes.isEmpty)
    #expect(arrange.regions[0].selected)
}

@Test func anEmptySelectionStaysEmptyWithNoWrite() {
    let arrange = ModelArrange([("a", region("MIDI"), false)])
    let outcome = restore(arrange, before: arrange.read()) {}
    #expect(outcome == .unchanged)
    #expect(arrange.writes.isEmpty)
}

@Test func anUnreadBeforeStateWritesNothing() {
    let arrange = ModelArrange([("a", region("MIDI"), true)])
    let outcome = restore(arrange, before: nil) { arrange.setAll(selected: false) }
    #expect(outcome == .beforeUnread)
    #expect(arrange.writes.isEmpty)
}

@Test func aDifferentSelectionAfterThePressIsNotToggledBack() {
    let arrange = ModelArrange([("a", region("MIDI"), true), ("b", region("Other", track: 3), false)])
    let before = arrange.read()
    let outcome = restore(arrange, before: before) {
        arrange.regions[0].selected = false
        arrange.regions[1].selected = true
    }
    #expect(outcome == .notRestored)
    #expect(arrange.writes.isEmpty)
}

@Test func anAmbiguousIdentityIsRefusedBeforeAnyWrite() {
    // Two regions read identically; which one was selected cannot be told after a redraw.
    let arrange = ModelArrange([("a", region("MIDI"), true), ("a2", region("MIDI"), false)])
    let before = arrange.read()
    let outcome = restore(arrange, before: before) { arrange.setAll(selected: false) }
    #expect(outcome == .notRestored)
    #expect(arrange.writes.isEmpty)
}

@Test func aRegionThatIsGoneIsRefusedBeforeAnyWrite() {
    let arrange = ModelArrange([("a", region("MIDI"), true), ("b", region("Other", track: 3), true)])
    let before = arrange.read()
    let outcome = restore(arrange, before: before) {
        arrange.setAll(selected: false)
        arrange.regions.removeLast()
    }
    #expect(outcome == .notRestored)
    #expect(arrange.writes.isEmpty)
}

@Test func aWriteThatTakesNoEffectIsNotReportedAsRestored() {
    let arrange = ModelArrange([("a", region("MIDI"), true)])
    arrange.writesTakeEffect = false
    let before = arrange.read()
    let outcome = restore(arrange, before: before) { arrange.setAll(selected: false) }
    #expect(outcome == .notRestored)
    #expect(arrange.writes == ["a"])
}

@Test func anUnreadableArrangeAfterThePressIsNotRestored() {
    let arrange = ModelArrange([("a", region("MIDI"), true)])
    let before = arrange.read()
    let outcome = restore(arrange, before: before) {
        arrange.setAll(selected: false)
        arrange.readable = false
    }
    #expect(outcome == .notRestored)
    #expect(arrange.writes.isEmpty)
}

@Test func aPartialScopeIsNamedEvenWhenTheVisibleSelectionReadsBack() {
    let arrange = ModelArrange([("a", region("MIDI"), true)])
    arrange.scopeComplete = false
    let before = arrange.read()
    let outcome = restore(arrange, before: before) { arrange.setAll(selected: false) }
    #expect(outcome == .scopeIncomplete)
    #expect(arrange.writes == ["a"])
    #expect(arrange.regions[0].selected)
}

@Test func everySelectedRegionIsWrittenBack() {
    let arrange = ModelArrange([
        ("a", region("One", track: 0), true),
        ("b", region("Two", track: 1), true),
        ("c", region("Three", track: 2), false),
    ])
    let before = arrange.read()
    let outcome = restore(arrange, before: before) { arrange.setAll(selected: false) }
    #expect(outcome == .restored)
    #expect(Set(arrange.writes) == ["a", "b"])
    #expect(arrange.regions.map(\.selected) == [true, true, false])
}
