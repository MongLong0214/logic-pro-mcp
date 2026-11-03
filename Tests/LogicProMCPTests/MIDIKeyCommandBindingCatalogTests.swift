import Testing
@testable import LogicProMCP

@Suite struct MIDIKeyCommandBindingCatalogTests {
    @Test func firstCatalogEntryMatchesTheExistingMIDITransportMapping() {
        #expect(MIDIKeyCommandBindingCatalog.entries == [
            .init(
                operation: "transport.toggle_metronome",
                commandName: "Toggle Metronome Click",
                cc: 98,
                channel: 16,
                value: 127
            )
        ])
        #expect(MIDIKeyCommandBindingCatalog.disagreements(
            with: MIDIKeyCommandsChannel.mappingTable
        ).isEmpty)
    }

    @Test func catalogAgreementReportsMissingAndChangedMappings() {
        var changed = MIDIKeyCommandsChannel.mappingTable
        changed["transport.toggle_metronome"] = 97
        #expect(MIDIKeyCommandBindingCatalog.disagreements(with: changed) == [
            "transport.toggle_metronome: catalog=98, mapping=97",
        ])

        changed.removeValue(forKey: "transport.toggle_metronome")
        #expect(MIDIKeyCommandBindingCatalog.disagreements(with: changed) == [
            "transport.toggle_metronome: catalog=98, mapping=missing",
        ])
    }

    @Test(arguments: [
        ("CC 0 (0)", UInt8(0), UInt8(0)),
        ("CC 98 (127)", UInt8(98), UInt8(127)),
        ("CC 127 (1)", UInt8(127), UInt8(1)),
    ])
    func exactAssignmentLabelsParse(_ raw: String, cc: UInt8, value: UInt8) throws {
        let assignment = try #require(MIDIKeyCommandAssignment.parse(raw))
        #expect(assignment == .init(cc: cc, value: value))
    }

    @Test(arguments: [
        "1",
        "CC 98",
        "CC 98 (127) extra",
        " CC 98 (127)",
        "CC 128 (127)",
        "CC 98 (128)",
        "CC -1 (127)",
    ])
    func provisionalMalformedAndOutOfRangeLabelsDoNotParse(_ raw: String) {
        #expect(MIDIKeyCommandAssignment.parse(raw) == nil)
    }

    @Test func AMatchingPreexistingLabelDoesNotProveTheOwnedPortOrBecomeReady() {
        let entry = MIDIKeyCommandBindingCatalog.entries[0]
        #expect(MIDIKeyCommandBindingCatalog.observe(
            rawLabel: "CC 98 (127)",
            expected: entry
        ) == .matchingLabelUnverifiedSource(.init(cc: 98, value: 127)))
    }

    @Test func EmptyProvisionalConflictingAndUnreadableRowsStayDistinct() {
        let entry = MIDIKeyCommandBindingCatalog.entries[0]
        #expect(MIDIKeyCommandBindingCatalog.observe(rawLabel: "", expected: entry) == .missing)
        #expect(MIDIKeyCommandBindingCatalog.observe(rawLabel: "1", expected: entry)
            == .provisional(raw: "1"))
        #expect(MIDIKeyCommandBindingCatalog.observe(rawLabel: "2", expected: entry)
            == .unreadable(raw: "2"))
        #expect(MIDIKeyCommandBindingCatalog.observe(rawLabel: "CC 99 (127)", expected: entry)
            == .conflicting(.init(cc: 99, value: 127)))
        #expect(MIDIKeyCommandBindingCatalog.observe(rawLabel: "CC 98 (126)", expected: entry)
            == .conflicting(.init(cc: 98, value: 126)))
        #expect(MIDIKeyCommandBindingCatalog.observe(rawLabel: "Other", expected: entry)
            == .unreadable(raw: "Other"))
        #expect(MIDIKeyCommandBindingCatalog.observe(rawLabel: nil, expected: entry)
            == .unreadable(raw: nil))
    }
}
