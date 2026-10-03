import Foundation

// #1094: the Region inspector's Quantize row. Measured in Korean on 2026-10-03 with one MIDI region
// selected (lpm-evidence/1094/explore2-ko.json): one AXRow holds two AXPopUpButtons with no AXTitle or
// AXDescription -- the quantize-mode pop-up, whose AXValue is the row `Quantize` (its menu: Classic and
// Smart Quantize), and to its right the value pop-up, whose AXValue and menu items are the grid rows below
// (Off before a grid is chosen). Each set's variants are that row's values in Logic's other nine languages.
extension AXLocalePolicy {
    static let quantizeModePopupValue = LabelSet(
        canonical: "Quantize",
        variants: ["퀀타이즈", "クオンタイズ", "Quantisieren", "Cuantizar", "Quantifier", "Quantizza", "Quantizar", "量化"],
        rationale: "The Region inspector's quantize-mode pop-up shows this row as its value while Classic Quantize is chosen; it carries no AXTitle or AXDescription, so its value names it. Read off a Korean Logic on 2026-10-03 (lpm-evidence/1094/explore2-ko.json); the other languages are this row's values in Logic.framework.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Quantize#value"
    )

    static let quantizeGridWholeNote = LabelSet(
        canonical: "1/1 Note",
        variants: ["온음표", "1/1 - 音符", "Redonda", "Nota da 1/1", "Semibreve", "全音符", "1 分音符"],
        rationale: "The Region inspector's quantize value pop-up offers this row as a menu item and shows it as its value once chosen; the edit.quantize grid 1/1. The Korean item was read on 2026-10-03 (lpm-evidence/1094/explore2-ko.json); the other languages are this row's values in Logic.framework.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/1%2F1%20Note#value"
    )

    static let quantizeGridHalfNote = LabelSet(
        canonical: "1/2 Note",
        variants: ["2분음표", "1/2 - 音符", "Blanca", "Nota da 1/2", "Mínima", "2 分音符"],
        rationale: "The Region inspector's quantize value pop-up offers this row as a menu item and shows it as its value once chosen; the edit.quantize grid 1/2. The Korean item was read on 2026-10-03 (lpm-evidence/1094/explore2-ko.json); the other languages are this row's values in Logic.framework.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/1%2F2%20Note#value"
    )

    static let quantizeGridQuarterNote = LabelSet(
        canonical: "1/4 Note",
        variants: ["4분음표", "1/4 - 音符", "Negra", "Nota da 1/4", "Semínima", "1/4 音符", "4 分音符"],
        rationale: "The Region inspector's quantize value pop-up offers this row as a menu item and shows it as its value once chosen; the edit.quantize grid 1/4. The Korean item was read on 2026-10-03 (lpm-evidence/1094/explore2-ko.json); the other languages are this row's values in Logic.framework.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/1%2F4%20Note#value"
    )

    static let quantizeGridEighthNote = LabelSet(
        canonical: "1/8 Note",
        variants: ["8분음표", "1/8 -音符", "Corchea", "Nota da 1/8", "Colcheia", "1/8 音符", "8 分音符"],
        rationale: "The Region inspector's quantize value pop-up offers this row as a menu item and shows it as its value once chosen; the edit.quantize grid 1/8. The Korean item was read on 2026-10-03 (lpm-evidence/1094/explore2-ko.json); the other languages are this row's values in Logic.framework.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/1%2F8%20Note#value"
    )

    static let quantizeGridSixteenthNote = LabelSet(
        canonical: "1/16 Note",
        variants: ["16분음표", "1/16 -音符", "Semicorchea", "Nota da 1/16", "Semicolcheia", "1/16 音符", "16 分音符"],
        rationale: "The Region inspector's quantize value pop-up offers this row as a menu item and shows it as its value once chosen; the edit.quantize grid 1/16. The Korean item was read on 2026-10-03 (lpm-evidence/1094/explore2-ko.json); the other languages are this row's values in Logic.framework.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/1%2F16%20Note#value"
    )

    static let quantizeGridThirtySecondNote = LabelSet(
        canonical: "1/32 Note",
        variants: ["32분음표", "1/32 -音符", "Fusa", "Nota da 1/32", "1/32 音符", "32 分音符"],
        rationale: "The Region inspector's quantize value pop-up offers this row as a menu item and shows it as its value once chosen; the edit.quantize grid 1/32. The Korean item was read on 2026-10-03 (lpm-evidence/1094/explore2-ko.json); the other languages are this row's values in Logic.framework.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/1%2F32%20Note#value"
    )

    static let quantizeGridSixtyFourthNote = LabelSet(
        canonical: "1/64 Note",
        variants: ["64분음표", "1/64 - 音符", "Semifusa", "Nota da 1/64", "1/64 音符", "64 分音符"],
        rationale: "The Region inspector's quantize value pop-up offers this row as a menu item and shows it as its value once chosen; the edit.quantize grid 1/64. The Korean item was read on 2026-10-03 (lpm-evidence/1094/explore2-ko.json); the other languages are this row's values in Logic.framework.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/1%2F64%20Note#value"
    )

    static let quantizeGridQuarterTriplet = LabelSet(
        canonical: "1/4 Triplet (1/6)",
        variants: ["셋잇단 4분음표(1/6)", "1/4 - 3連符（1/6）", "1/4 Triole (1/6)", "Tresillo de negras", "Triolet 1/4 (1/6)", "Terzina da 1/4 (1/6)", "Tercina de Semínimas (1/6)", "4 分三连音符 (1/6)", "1/4 三連音（1/6）"],
        rationale: "The Region inspector's quantize value pop-up offers this row as a menu item and shows it as its value once chosen; the edit.quantize grid 1/4T. The Korean item was read on 2026-10-03 (lpm-evidence/1094/explore2-ko.json); the other languages are this row's values in Logic.framework.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/1%2F4%20Triplet%20%281%2F6%29#value"
    )

    static let quantizeGridEighthTriplet = LabelSet(
        canonical: "1/8 Triplet (1/12)",
        variants: ["셋잇단 8분음표(1/12)", "1/8 - 3連符（1/12）", "1/8 Triole (1/12)", "Tresillo de corcheas", "Triolet 1/8 (1/12)", "Terzina da 1/8 (1/12)", "Tercina de Colcheias (1/12)", "8 分三连音符 (1/12)", "1/8 三連音（1/12）"],
        rationale: "The Region inspector's quantize value pop-up offers this row as a menu item and shows it as its value once chosen; the edit.quantize grid 1/8T. The Korean item was read on 2026-10-03 (lpm-evidence/1094/explore2-ko.json); the other languages are this row's values in Logic.framework.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/1%2F8%20Triplet%20%281%2F12%29#value"
    )

    static let quantizeGridSixteenthTriplet = LabelSet(
        canonical: "1/16 Triplet (1/24)",
        variants: ["셋잇단 16분음표(1/24)", "1/16 - 3連符（1/24）", "1/16 Triole (1/24)", "Tresillo de semicorcheas", "Triolet 1/16 (1/24)", "Terzina da 1/16 (1/24)", "Tercina de Semicolcheias (1/24)", "16 分三连音符 (1/24)", "1/16 三連音（1/24）"],
        rationale: "The Region inspector's quantize value pop-up offers this row as a menu item and shows it as its value once chosen; the edit.quantize grid 1/16T. The Korean item was read on 2026-10-03 (lpm-evidence/1094/explore2-ko.json); the other languages are this row's values in Logic.framework.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/1%2F16%20Triplet%20%281%2F24%29#value"
    )

    /// The tool's grid value -> the Region inspector's label for it.
    static let quantizeGridLabels: [String: LabelSet] = [
        "1/1": quantizeGridWholeNote,
        "1/2": quantizeGridHalfNote,
        "1/4": quantizeGridQuarterNote,
        "1/8": quantizeGridEighthNote,
        "1/16": quantizeGridSixteenthNote,
        "1/32": quantizeGridThirtySecondNote,
        "1/64": quantizeGridSixtyFourthNote,
        "1/4T": quantizeGridQuarterTriplet,
        "1/8T": quantizeGridEighthTriplet,
        "1/16T": quantizeGridSixteenthTriplet,
    ]
}
