import Testing
@testable import LogicProMCP

@Suite("Issue #533 Japanese New Track sheet")
struct Issue533JapaneseNewTrackSheetTests {
    private func sheetSignals(
        description: String,
        createTitle: String,
        cancelTitle: String,
        cancelEnabled: Bool
    ) -> ModalReconciliation.ModalSignals {
        ModalReconciliation.ModalSignals(
            sheetPresent: true,
            sheetDescription: description,
            createButtonPresent: true,
            cancelButtonPresent: true,
            cancelButtonEnabled: cancelEnabled,
            deleteConfirmButtonPresent: false,
            strayMenuOpen: false,
            topLevelAlertPresent: false,
            topLevelAlertButtonCount: 0,
            topLevelAlertPrimaryButton: "",
            createButtonTitle: createTitle,
            cancelButtonTitle: cancelTitle,
            deletePrimaryTitle: ""
        )
    }

    @Test("Issue533 classifies the measured Japanese sheet with an enabled Cancel")
    func measuredJapaneseSheetClassifiesViaDescription() {
        let signals = sheetSignals(
            description: "新規トラック",
            createTitle: "作成",
            cancelTitle: "キャンセル",
            cancelEnabled: true
        )

        #expect(ModalReconciliation.classify(signals) == .mandatoryNewTrack)
    }

    @Test("Issue533 retains English and Korean New Track classification")
    func existingLocalesStillClassifyViaDescription() {
        let english = sheetSignals(
            description: "New Track",
            createTitle: "Create",
            cancelTitle: "Cancel",
            cancelEnabled: true
        )
        let korean = sheetSignals(
            description: "새로운 트랙",
            createTitle: "생성",
            cancelTitle: "취소",
            cancelEnabled: true
        )

        #expect(ModalReconciliation.classify(english) == .mandatoryNewTrack)
        #expect(ModalReconciliation.classify(korean) == .mandatoryNewTrack)
    }

    @Test("Issue533 keeps an enabled-Cancel unrelated sheet fail-closed")
    func unrelatedEnabledCancelSheetIsUnknown() {
        let signals = sheetSignals(
            description: "Some Other Sheet",
            createTitle: "作成",
            cancelTitle: "キャンセル",
            cancelEnabled: true
        )

        #expect(ModalReconciliation.classify(signals) == .unknownSheet)
    }

    @Test("Issue533 stores only the measured Japanese New Track labels")
    func measuredJapaneseLabelsAreExact() {
        #expect(AXLocalePolicy.newTrackSheetDescription.variants.contains("新規トラック"))
        #expect(AXLocalePolicy.createButton.variants.contains("作成"))
        #expect(AXLocalePolicy.cancelButton.variants.contains("キャンセル"))
        #expect(!AXLocalePolicy.newTrackSheetDescription.variants.contains("新しいトラック"))
    }
}
