@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// Installed QuickHelp Title/Text inputs, not a ten-locale native AX qualification.
/// Archived EN/KO send-knob AXHelp corroborates this row at the actual control.
@Suite("#904 send slider hints use their own QuickHelp row")
struct Issue904SendHelpDerivedTests {
    struct HelpRow: Sendable {
        let locale: String
        let title: String
        let text: String
    }

    // logic-canon://quickhelp/QuickHelp/en/INS_011_SendLevelKnob#Text
    private static let englishText =
        "Drag vertically to control the amount of signal sent to an aux channel strip. Use sends to process or submix multiple track output signals."
    private static let rows: [HelpRow] = [
        // logic-canon://quickhelp/QuickHelp/en/INS_011_SendLevelKnob#Title
        HelpRow(locale: "en",
                title: "Send Level knob",
                text: englishText),
        // logic-canon://quickhelp/QuickHelp/ko/INS_011_SendLevelKnob#Title
        // logic-canon://quickhelp/QuickHelp/ko/INS_011_SendLevelKnob#Text
        HelpRow(locale: "ko",
                title: "센드 레벨 노브",
                text: "Aux 채널 스트립으로 전송되는 신호의 양을 제어하려면 수직으로 드래그합니다. 센드를 사용하여 여러 개의 트랙 출력 신호를 처리하거나 서브믹싱합니다."
        ),
        // logic-canon://quickhelp/QuickHelp/ja/INS_011_SendLevelKnob#Title
        // logic-canon://quickhelp/QuickHelp/ja/INS_011_SendLevelKnob#Text
        HelpRow(locale: "ja",
                title: "センドレベルノブ",
                text: "上下にドラッグして、Auxチャンネルストリップに送る信号の量を制御します。センドを使用すると、複数トラックの出力信号を処理またはサブミックスできます。"
        ),
        // logic-canon://quickhelp/QuickHelp/de/INS_011_SendLevelKnob#Title
        // logic-canon://quickhelp/QuickHelp/de/INS_011_SendLevelKnob#Text
        HelpRow(locale: "de",
                title: "Send-Drehregler",
                text: "Durch vertikales Ziehen kannst du festlegen, mit welcher Stärke das Signal an einen Aux-Channel-Strip gesendet wird. Mit Sends können Ausgabesignale mehrerer Spuren verarbeitet und abgemischt werden."
        ),
        // logic-canon://quickhelp/QuickHelp/es/INS_011_SendLevelKnob#Title
        // logic-canon://quickhelp/QuickHelp/es/INS_011_SendLevelKnob#Text
        HelpRow(locale: "es",
                title: "Botón “Nivel de envío”",
                text: "Arrastra verticalmente para controlar cantidad de señal enviada a un canal auxiliar. Utiliza los envíos para procesar o submezclar varias señales de salida de pista."
        ),
        // Preserve the installed trailing NBSP in this input.
        // logic-canon://quickhelp/QuickHelp/fr/INS_011_SendLevelKnob#Title
        // logic-canon://quickhelp/QuickHelp/fr/INS_011_SendLevelKnob#Text
        HelpRow(locale: "fr",
                title: "Potentiomètre Niveau d’envoi ",
                text: "faites glisser verticalement ce potentiomètre pour contrôler la quantité de signal envoyée à une tranche de console auxiliaire. Utiliser les envois pour traiter ou sous-mixer plusieurs signaux de sortie de piste."
        ),
        // These installed files are byte-identical to English, not translated readings.
        // English row above: the it file is not_localized, not an Italian Title.
        HelpRow(locale: "it",
                title: "Send Level knob",
                text: englishText),
        // English row above: the pt file is not_localized, not a Portuguese Title.
        HelpRow(locale: "pt",
                title: "Send Level knob",
                text: englishText),
        // logic-canon://quickhelp/QuickHelp/zh_CN/INS_011_SendLevelKnob#Title
        // logic-canon://quickhelp/QuickHelp/zh_CN/INS_011_SendLevelKnob#Text
        HelpRow(locale: "zh_CN",
                title: "“发送电平”旋钮",
                text: "垂直拖移以控制发送到辅助通道条的信号数量。使用发送以处理或副混音多个轨道输出信号。"
        ),
        // English row above: the zh_TW file is not_localized, not a translated Title.
        HelpRow(locale: "zh_TW",
                title: "Send Level knob",
                text: englishText),
    ]

    @Test(arguments: rows)
    func ownTitleMatchesTheSendHint(_ row: HelpRow) {
        #expect(AXLocalePolicy.sliderSendHint.containsAny(in: row.title), "locale: \(row.locale)")
    }

    private func slider(_ b: FakeAXRuntimeBuilder, id: Int, help: String) -> AXUIElement {
        let element = b.element(id)
        b.setAttribute(element, kAXRoleAttribute as String, kAXSliderRole as String)
        b.setAttribute(element, kAXHelpAttribute as String, help)
        b.setChildren(element, [])
        return element
    }

    /// Natural own-row help does not contain pan/volume hints, before OR after migration.
    /// This positive control is not a newly reproduced wrong-actuator defect.
    @Test(arguments: rows)
    func naturalHelpIsNotPanOrVolume(_ row: HelpRow) {
        let b = FakeAXRuntimeBuilder()
        let send = slider(b, id: 904_610, help: row.title + ". " + row.text)
        let reading = AXLogicProElements.sliderText(send, runtime: b.makeAXRuntime())
        #expect(!reading.isVolumeFader)
        #expect(!reading.isPanControl)
        #expect(b.setCalls.isEmpty)
        #expect(b.actionCalls.isEmpty)
    }

    @Test(arguments: rows)
    func describedPanStillWinsOverTheSendKnob(_ row: HelpRow) throws {
        let b = FakeAXRuntimeBuilder()
        let strip = b.element(904_620)
        let pan = slider(b, id: 904_621, help: "Pan")
        let send = slider(b, id: 904_622, help: row.title + ". " + row.text)
        b.setChildren(strip, [pan, send])
        let selected = try #require(AXLogicProElements.findPanControl(in: strip, runtime: b.makeAXRuntime()))
        #expect(CFEqual(selected, pan))
        #expect(!CFEqual(selected, send))
        #expect(b.setCalls.isEmpty)
        #expect(b.actionCalls.isEmpty)
    }

    @Test(arguments: [("send level", true), ("센드", true), ("sénd", false), ("Pan", false), ("Volume", false)])
    func fragmentsAndNegativeControlsRemain(_ input: (String, Bool)) {
        let matches = AXLocalePolicy.sliderSendHint.containsAny(in: input.0)
        if input.1 { #expect(matches) } else { #expect(!matches) }
    }

    @Test
    func hintNamesTheOwnKnobRow() {
        // logic-canon://quickhelp/QuickHelp/en/INS_011_SendLevelKnob#Title
        #expect(AXLocalePolicy.sliderSendHint.derivedFrom == "logic-canon://quickhelp/QuickHelp/en/INS_011_SendLevelKnob#Title")
    }
}
