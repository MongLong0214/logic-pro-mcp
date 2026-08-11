import Testing
@testable import LogicProMCP

/// `MIDIProviderGate` requires "English and Korean locale coverage" of the Event List provider before
/// it can be qualified. The collector compared its column headers positionally against English
/// literals, so on a Korean Logic every read threw `headerMismatch` and the note readback could not
/// run at all.
///
/// The variants are read from a live Logic 12.3 in Korean, never translated — the same discipline
/// that caught `New = 신규` rather than the `새로 만들기` a translation produces.
@Suite("#293 Event List headers are locale-aware")
struct Issue293EventListLocaleTests {
    private static let koreanEventHeader = ["L", "M", "위치", "상태", "채널", "번호", "값", "길이/정보"]
    private static let koreanRegionHeader = ["L", "M", "위치", "이름", "트랙", "길이"]

    private static func binds(_ columns: [AXLocalePolicy.LabelSet], _ titles: [String]) -> Bool {
        guard titles.count == columns.count else { return false }
        for (index, column) in columns.enumerated() where !column.matches(titles[index]) {
            return false
        }
        return true
    }

    private static let eventColumns: [AXLocalePolicy.LabelSet] = [
        AXLocalePolicy.eventListColumnL, AXLocalePolicy.eventListColumnM, AXLocalePolicy.eventListColumnPosition, AXLocalePolicy.eventListColumnStatus,
        AXLocalePolicy.eventListColumnChannel, AXLocalePolicy.eventListColumnNumber, AXLocalePolicy.eventListColumnValue,
        AXLocalePolicy.eventListColumnLengthInfo,
    ]
    private static let regionColumns: [AXLocalePolicy.LabelSet] = [
        AXLocalePolicy.eventListColumnL, AXLocalePolicy.eventListColumnM, AXLocalePolicy.eventListColumnPosition, AXLocalePolicy.eventListColumnName,
        AXLocalePolicy.eventListColumnTrack, AXLocalePolicy.eventListColumnLength,
    ]

    @Test("both levels bind in English and in Korean")
    func bothLevelsBindInBothLanguages() {
        #expect(Self.binds(Self.eventColumns, Self.eventColumns.map(\.canonical)))
        #expect(Self.binds(Self.regionColumns, Self.regionColumns.map(\.canonical)))
        #expect(Self.binds(Self.eventColumns, Self.koreanEventHeader))
        #expect(Self.binds(Self.regionColumns, Self.koreanRegionHeader))
    }

    @Test("no header binds both levels, in either language")
    func levelsNeverCross() {
        // If a region header bound the event columns, "you are looking at the wrong level" would be
        // reported as "Logic changed its columns" — a recoverable condition turned unrecoverable.
        #expect(!Self.binds(Self.eventColumns, Self.koreanRegionHeader))
        #expect(!Self.binds(Self.regionColumns, Self.koreanEventHeader))
        #expect(!Self.binds(Self.eventColumns, Self.regionColumns.map(\.canonical)))
        #expect(!Self.binds(Self.regionColumns, Self.eventColumns.map(\.canonical)))
    }

    @Test("column identity stays canonical English across locales")
    func identityIsCanonical() {
        // A snapshot taken on a Korean Logic must be comparable with one taken on an English Logic,
        // so the column IDs are the canonical forms and only the accepted rendering widens.
        #expect(AXLocalePolicy.eventListColumnPosition.canonical == "Position")
        #expect(AXLocalePolicy.eventListColumnValue.canonical == "Val")
        #expect(AXLocalePolicy.eventListColumnPosition.labels.contains("위치"))
        #expect(AXLocalePolicy.eventListColumnValue.labels.contains("값"))
    }
}
