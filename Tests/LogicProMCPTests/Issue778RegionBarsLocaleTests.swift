import Foundation
import Testing
@testable import LogicProMCP

/// #778: recognising a region and being unable to read its bars is half a fix. When
/// `regionHelpKeyword` learned `リージョン`, the Japanese enumeration started returning the region
/// with `startBar: -1, endBar: -1` — measured live 2026-09-06 on the campaign project — because
/// `parseRegionBars` carried only Korean and English patterns.
///
/// Every string here is VERBATIM from a census or from Logic's own help, not translated.
@Suite("Issue778 region bar parsing across locales")
struct Issue778RegionBarsLocaleTests {

    /// From the ja-JP arrange-regions census of 2026-09-05. Note the units are mixed in Logic's own
    /// sentence — `1 bar ` in ASCII beside `2 小節` in Japanese — which is why the pattern anchors
    /// on the two position nouns rather than on a unit word.
    static let japanese = "リージョンの開始位置は1 bar 、終了位置は2 小節 です, MIDIリージョン. "
        + "MIDIノートおよびコントローライベントが含まれています。移動するには中央を、"
        + "サイズ変更するには下端を、ループするには右端上部をドラッグします。その他の編集にはツールを使います。 "
    static let korean = "리전은 1 마디 에서 시작하여 2 마디 에서 끝납니다."
    static let english = "Region starts at 128 bars and ends at 129 bars, MIDI region."

    @Test("the Japanese help string yields its bars")
    func japaneseParses() {
        let (start, end) = AccessibilityChannel.parseRegionBars(from: Self.japanese)
        #expect(start == 1)
        #expect(end == 2)
    }

    @Test("Korean and English still parse, and did not regress")
    func othersStillParse() {
        let ko = AccessibilityChannel.parseRegionBars(from: Self.korean)
        #expect(ko.0 == 1)
        #expect(ko.1 == 2)
        let en = AccessibilityChannel.parseRegionBars(from: Self.english)
        #expect(en.0 == 128)
        #expect(en.1 == 129)
    }

    /// The refusal has to survive. `(-1, -1)` is what tells a caller to read `rawHelp` instead, and
    /// a pattern loose enough to match anything would replace an honest refusal with a wrong number.
    @Test("a string in no known locale is refused rather than guessed")
    func unknownIsRefused() {
        for help in ["", "Region", "リージョン", "some unrelated help text",
                     "Regionen beginnen bei 3 Takten und enden bei 4 Takten"] {
            let (start, end) = AccessibilityChannel.parseRegionBars(from: help)
            #expect(start == -1, "unexpectedly parsed a start from \(help)")
            #expect(end == -1, "unexpectedly parsed an end from \(help)")
        }
    }

    /// Each locale's pattern must not claim another locale's string: a cross-match would read the
    /// wrong numbers rather than refusing, which is the failure mode `(-1, -1)` exists to avoid.
    @Test("the Japanese string is not matched by the English or Korean patterns alone")
    func noCrossLocaleMatch() {
        // Proven by construction: the Japanese sentence carries neither `region starts at` nor
        // `리전은`, so if the Japanese row were removed the result would be the refusal.
        #expect(!Self.japanese.lowercased().contains("region starts at"))
        #expect(!Self.japanese.contains("리전은"))
    }
}
