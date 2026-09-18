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
    /// Verbatim from a de-DE Logic on 2026-09-13, read off the region `tracks.record_sequence` had
    /// just imported. The double space after `Takt` and the space before the comma are Logic's.
    /// The unit is inflected by the number — `1 Takt` singular, `2 Takte` plural — which is why the
    /// pattern anchors on `beginnt bei` / `endet bei` instead.
    static let german = "Region beginnt bei 1 Takt  und endet bei 2 Takte , MIDI-Region. "
        + "Enthält MIDI-Noten- und Controller-Events. Durch Bewegen der Mitte werden Regionen "
        + "verschoben, mit den unteren Rändern skaliert und mit dem oberen rechten Rand als Loop "
        + "gespielt. Verwende für andere Bearbeitungen die entsprechenden Werkzeuge. "

    @Test("the Japanese help string yields its bars")
    func japaneseParses() {
        let (start, end) = AccessibilityChannel.parseRegionBars(from: Self.japanese)
        #expect(start == 1)
        #expect(end == 2)
    }

    /// German was at `(-1, -1)` until 2026-09-13. The live run that exposed it had already got
    /// past the localized import panel and the localized tempo alert and found the region — the
    /// envelope carried `region_kind: midi`, `note_count: 1` and the help above, and still returned
    /// `unreadable_readback` with `start_bar: -1`. Recognising a region and being unable to read
    /// its bars is half a fix; that is the same sentence #778 wrote about Japanese.
    @Test("the German help string yields its bars")
    func germanParses() {
        let (start, end) = AccessibilityChannel.parseRegionBars(from: Self.german)
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
        // `Regionen beginnen bei …` is an INVENTED plural: Logic renders the singular `Region
        // beginnt bei 1 Takt`. It is kept here as the negative control for the German row — a
        // pattern loosened to `Region\w*\s+beginn\w+` to be tolerant would start reading numbers
        // out of a sentence Logic does not emit.
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
        #expect(!Self.german.lowercased().contains("region starts at"))
        #expect(!Self.german.contains("리전은"))
        #expect(!Self.german.contains("リージョン"))
    }
    // MARK: - The template the four patterns were instances of (#909)

    /// Every locale's template yields a pattern, or a language drops out in silence.
    ///
    /// `regionBarsPatterns()` returns nil for a template without exactly two placeholders and
    /// `compactMap` swallows it, so the only thing standing between "ten patterns" and "nine
    /// patterns and no message" is this count.
    @Test("every one of the ten templates produces a pattern")
    func everyTemplateProducesAPattern() {
        let labels = AXLocalePolicy.regionBarsSentence.labels
        #expect(labels.count == 10, "the row Apple ships has ten values")
        #expect(AXLocalePolicy.regionBarsPatterns().count == labels.count,
                "a template that yields no pattern is a locale that silently stopped parsing")
    }

    /// The four sentences this product has actually SEEN still parse -- the same strings the cases
    /// above use, read here through the derived patterns rather than the four they replaced.
    @Test("the four measured sentences parse through the derived patterns")
    func measuredSentencesStillParse() {
        let samples: [(String, String, (Int, Int))] = [
            ("korean", Self.korean, (1, 2)),
            ("english", Self.english, (128, 129)),
            ("japanese", Self.japanese, (1, 2)),
            ("german", Self.german, (1, 2)),
        ]
        for (name, help, expected) in samples {
            let got = AccessibilityChannel.parseRegionBars(from: help)
            #expect(got == expected, "\(name): got \(got)")
        }
    }

    /// The tolerances the hand-written English pattern carried, which the derived one must not
    /// lose: case-insensitive, runs of whitespace between words, no unit required, and the unit on
    /// EITHER side of the number.
    ///
    /// The last one is here because the first version of this derivation dropped it and narrowed
    /// English. The hand-written pattern had `(?:bar\s+)?` before the digits; `Region starts at
    /// bar 1` is a string this product reads, and without that the enumeration returned (-1, -1).
    /// `testAccessibilityChannelAXBackedRegionReadAcceptsPluralTracksContentsLabel` is what went
    /// red, so the tolerance list is now enumerated here rather than remembered.
    @Test("the English tolerances survive the derivation",
          arguments: [
            ("Region  starts   at 5 bars and ends at 6 bars.", 5, 6),
            ("region starts at 7 bars and ends at 8 bars.", 7, 8),
            ("Region starts at 9 and ends at 10", 9, 10),
            ("Region starts at bar 1 and ends at bar 2, MIDI region.", 1, 2),
            ("Region starts at 1 bar  and ends at 2 bars , MIDI region.", 1, 2),
            ("리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전.", 1, 3),
          ])
    func englishTolerancesSurvive(sample: (String, Int, Int)) {
        let got = AccessibilityChannel.parseRegionBars(from: sample.0)
        #expect(got == (sample.1, sample.2), "got \(got)")
    }

    /// `Chord group starts at %@ and ends at %@` is a DIFFERENT row with a near-identical shape.
    /// A pattern loose enough to read a chord group's bars as a region's is the failure this whole
    /// function is downstream of, so it is asserted rather than assumed.
    @Test("the chord-group sentence, a near twin with its own row, is refused",
          arguments: [
            "코드 그룹은 3 마디 에서 시작하여 4 마디, MIDI에서 끝납니다. x",
            "Chord group starts at 3 bars and ends at 4 bars, x. y",
            "Akkordgruppe beginnt bei 3 Takt und endet bei 4 Takte, x. y",
          ])
    func chordGroupIsNotARegion(sample: String) {
        let got = AccessibilityChannel.parseRegionBars(from: sample)
        #expect(got == (-1, -1), "got \(got)")
    }

    /// The middle literal is what makes the SECOND number the end bar.
    ///
    /// SYNTHETIC, and deliberately so. No sentence this product has read puts a number between
    /// the two bar numbers, so every measured sample parses identically with the `and ends at`
    /// anchor and without it -- which means none of them can tell whether the anchor is there.
    /// Deleting it from the transform leaves all four measured cases green. This is the case that
    /// goes red, and the shape is not far-fetched: the placeholder expands to a number and a unit
    /// inside a sentence Logic goes on writing after.
    @Test("a number between the two bars does not become the end bar")
    func theMiddleAnchorIsLoadBearing() {
        let got = AccessibilityChannel.parseRegionBars(
            from: "Region starts at 5 bars (take 2) and ends at 9 bars, MIDI region.")
        #expect(got == (5, 9), "got \(got); without the `and ends at` anchor this reads (5, 2)")
    }

    /// The locales with no live reading, driven through their own template.
    ///
    /// SYNTHETIC, and it proves the TRANSFORM rather than the sentence: it substitutes into the
    /// template Apple ships and checks the derived pattern reads the numbers back. That nobody has
    /// watched a Spanish Logic render this is a limit of the change, not something this closes.
    @Test("a sentence built from each template parses back through its own pattern")
    func everyTemplateRoundTrips() {
        let templates = AXLocalePolicy.regionBarsSentence.labels
        #expect(!templates.isEmpty, "if this is empty the case is asserting nothing")
        for template in templates {
            guard let first = template.range(of: "%@") else {
                #expect(Bool(false), "template \(template) has no placeholder")
                continue
            }
            let filled = template.replacingCharacters(in: first, with: "11 bars")
            guard let second = filled.range(of: "%@") else {
                #expect(Bool(false), "template \(template) lost its second placeholder")
                continue
            }
            let sentence = filled.replacingCharacters(in: second, with: "12 bars")
            let got = AccessibilityChannel.parseRegionBars(from: sentence)
            #expect(got == (11, 12), "template \(template) round-tripped to \(got)")
        }
    }

}
