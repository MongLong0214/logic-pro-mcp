import Testing
@testable import LogicProMCP

/// Two titles as a running Logic 12.3 drew them on 2026-09-26, where the space differs from the
/// one Apple's row carries (#993, #1004).
///
/// Written with escapes because the space is the point: a fixture typed from Apple's row, or
/// retyped in an editor that swaps U+00A0 for U+0020, would agree with the old sets. `matches`
/// trims the ends and ignores case but compares interior characters exactly, so U+0020 and
/// U+00A0 are different strings to it.
@Suite("#993 / #1004 — a LabelSet holds the space the running Logic draws")
struct AXLocalePolicyNoBreakSpaceAsDrawnTests {

    /// The first item of the German Control Surfaces Setup window's `New` menu. Apple's row has
    /// U+00A0 before the ellipsis; the menu drew U+0020.
    @Test("the German Install item as drawn, with U+0020 before the ellipsis")
    func germanInstallItemAsDrawn() {
        let drawn = "Installieren\u{0020}\u{2026}"
        #expect(AXLocalePolicy.controlSurfaceInstallMenuItem.matches(drawn))
    }

    /// The stem-export progress window. Its title drew U+00A0 in de-DE, es-ES, fr-FR and ko-KR,
    /// while the row is `Logic Pro` with U+0020. The set must hold that spelling itself, not only
    /// through `progressWindowTitleMatches`, which folds whitespace first.
    @Test("the stem-export progress window title as drawn, with U+00A0")
    func progressWindowTitleAsDrawn() {
        let drawn = "Logic\u{00A0}Pro"
        #expect(AXLocalePolicy.stemExportProgressWindowTitle.matches(drawn))
    }
}
