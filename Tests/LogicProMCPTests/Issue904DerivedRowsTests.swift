import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// Captures the AppleScript a menu route generates, the way Issue519MenuLocaleGeneratorTests does.
private final class BounceScriptProbe: @unchecked Sendable {
    private(set) var script = ""
    func capture(_ script: String) { self.script = script }
}

/// #904: thirteen LabelSets whose Apple row is the control's own word now name that row in
/// `derivedFrom` and carry its ten-locale values beside the readings they already held.
///
/// `Scripts/check-labelsets-are-derived.py` proves, offline, that the members ARE the row's values.
/// What it cannot prove is that the row reaches the consumer: each set is matched in one of five
/// ways -- `.exactStrict` on a checkbox, `.exactStrict` on a lowercased slider description,
/// `containsAny` over a lowercased aggregate, a literal spliced into AppleScript, and `containsAny`
/// on an Undo title -- and a value can be Apple's and still never match if it lands in a set the
/// consumer reads differently. So every test here drives one consumer class with a value that ONLY
/// the derived row supplies, and names the mutation that turns it red.
@Suite("#904 thirteen LabelSets derive from the row that is the control's own word")
struct Issue904DerivedRowsTests {
    private static let logicStrings =
        "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/"

    // MARK: - The row each set names

    /// Mutation that turns this red: change `Tempo%23mti` to `Tempo%23par` in tempoFieldLabel's
    /// `derivedFrom`. The reference is compared whole, so a neighbouring row in the same
    /// namespace -- which the derived guard would also accept if its values happened to
    /// coincide -- fails here by name.
    @Test("each of the thirteen names exactly the row the plan chose")
    func derivedFromNamesTheRow() throws {
        let rows: [(String, AXLocalePolicy.LabelSet, String)] = [
            ("transportCycleControl", AXLocalePolicy.transportCycleControl,
             Self.logicStrings + "StrTransportBtns%7C%7C%7CCycle#value"),
            ("transportAutopunchControl", AXLocalePolicy.transportAutopunchControl,
             Self.logicStrings + "StrTransportBtns%7C%7C%7CAutopunch#value"),
            ("tempoFieldLabel", AXLocalePolicy.tempoFieldLabel,
             Self.logicStrings + "Tempo%23mti#value"),
            ("tempoSliderLabel", AXLocalePolicy.tempoSliderLabel,
             Self.logicStrings + "Tempo%23mti#value"),
            ("midiImportTempoAlertText", AXLocalePolicy.midiImportTempoAlertText,
             Self.logicStrings + "Tempo%23mti#value"),
            ("trackRecordButton", AXLocalePolicy.trackRecordButton,
             Self.logicStrings + "Record%23mti#value"),
            ("sliderVolumeHint", AXLocalePolicy.sliderVolumeHint,
             Self.logicStrings + "Volume%23acc#value"),
            ("sliderPanHint", AXLocalePolicy.sliderPanHint,
             Self.logicStrings + "Pan%23par#value"),
            ("headerPanHint", AXLocalePolicy.headerPanHint,
             Self.logicStrings + "Pan%23par#value"),
            // Not `Control Bar#acc`: #979 read a Portuguese Logic live and its control bar is
            // `Barra de Controles`, the value of this row, where `Control Bar#acc` says
            // `Barra de Controle`. controlBarGroupLabel cites the same row for the same reason.
            ("transportContainerMetadata", AXLocalePolicy.transportContainerMetadata,
             Self.logicStrings + "StrTabBtnLabel%7C%7C%7CControl%20Bar#value"),
            ("undoPluginInsertMenuItem", AXLocalePolicy.undoPluginInsertMenuItem,
             Self.logicStrings + "Insert%20Plug-in%20in%20Channel%20Strip%23und#value"),
            ("projectOrSectionMenuItem", AXLocalePolicy.projectOrSectionMenuItem,
             Self.logicStrings + "Project%20or%20Section%E2%80%A6#value"),
            // The one row outside Logic.framework is MAAudioUnitSupport's. Its English value: instrument
            ("trackTypeInstrument", AXLocalePolicy.trackTypeInstrument,
             "logic-canon://strings/Contents%2FFrameworks%2FMAAudioUnitSupport.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/instrument#value"),
        ]
        #expect(rows.count == 13)
        for (name, set, expected) in rows {
            let ref = try #require(set.derivedFrom, "\(name) names no row")
            #expect(ref == expected, "\(name) names \(ref)")
        }
    }

    // MARK: - Class 1: control-bar checkbox, `.exactStrict` on title then description

    /// Mutation that turns this red: remove `Ciclo` from transportCycleControl's variants, or
    /// `オートパンチ` from transportAutopunchControl's. `findControlBarCheckbox(matching:)` goes
    /// through `censusDescendant` and `readControlBarCheckboxValue` through the title-then-
    /// description `.exactStrict` pass, so only the whole value finds the box; the decoy carrying
    /// the value plus a suffix is what proves that nothing looser is at work.
    @Test("a control bar whose checkboxes are Spanish Cycle and Japanese Autopunch is found and read")
    func controlBarCheckboxClass() throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9040)
        let window = builder.element(9041)
        let controlBar = builder.element(9042)
        let cycle = builder.element(9043)
        let autopunch = builder.element(9044)
        let cycleDecoy = builder.element(9045)

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [controlBar])
        builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
        builder.setChildren(controlBar, [cycleDecoy, cycle, autopunch])
        builder.setAttribute(cycleDecoy, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(cycleDecoy, kAXDescriptionAttribute as String, "Ciclo activado")
        builder.setAttribute(cycleDecoy, kAXValueAttribute as String, NSNumber(value: false))
        builder.setAttribute(cycle, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(cycle, kAXDescriptionAttribute as String, "Ciclo")
        builder.setAttribute(cycle, kAXValueAttribute as String, NSNumber(value: true))
        builder.setAttribute(autopunch, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(autopunch, kAXDescriptionAttribute as String, "オートパンチ")
        builder.setAttribute(autopunch, kAXValueAttribute as String, NSNumber(value: false))

        let runtime = builder.makeLogicRuntime(appElement: app)

        #expect(AXLogicProElements.findControlBarCheckbox(
            matching: AXLocalePolicy.transportCycleControl, runtime: runtime
        ) == cycle)
        let cycleEnabled = try #require(AXLogicProElements.readControlBarCheckboxValue(
            matching: AXLocalePolicy.transportCycleControl, runtime: runtime
        ))
        #expect(cycleEnabled)

        #expect(AXLogicProElements.findControlBarCheckbox(
            matching: AXLocalePolicy.transportAutopunchControl, runtime: runtime
        ) == autopunch)
        let autopunchEnabled = try #require(AXLogicProElements.readControlBarCheckboxValue(
            matching: AXLocalePolicy.transportAutopunchControl, runtime: runtime
        ))
        #expect(!autopunchEnabled)
    }

    // MARK: - Class 2: tempo slider, `.exactStrict` on the lowercased description

    /// Mutation that turns this red: remove `速度` from tempoSliderLabel's variants. The finder at
    /// AXLogicProElements+Transport lowercases the slider's description and asks `.exactStrict`, so
    /// a derived value has to match whole -- the decoy with a suffix is skipped -- while `bpm`,
    /// the tolerance this set keeps, still matches and its `contains` sibling still rejects it.
    @Test("the tempo slider is found by a derived Chinese value whole, still by bpm, and not by a suffix")
    func exactStrictClass() {
        #expect(AXLocalePolicy.tempoSliderLabel.matches("速度", mode: .exactStrict))
        #expect(AXLocalePolicy.tempoSliderLabel.matches("bpm", mode: .exactStrict))
        #expect(!AXLocalePolicy.tempoSliderLabel.matches("速度 slider", mode: .exactStrict))
        #expect(!AXLocalePolicy.tempoSliderContainsLabel.containsAny(in: "bpm"))

        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9050)
        let window = builder.element(9051)
        let controlBar = builder.element(9052)
        let anchor = builder.element(9053)
        let decoy = builder.element(9054)
        let tempo = builder.element(9055)

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [controlBar])
        builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
        builder.setChildren(controlBar, [anchor, decoy, tempo])
        builder.setAttribute(anchor, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(anchor, kAXDescriptionAttribute as String, "循环")
        builder.setAttribute(decoy, kAXRoleAttribute as String, kAXSliderRole as String)
        builder.setAttribute(decoy, kAXDescriptionAttribute as String, "速度 slider")
        builder.setAttribute(tempo, kAXRoleAttribute as String, kAXSliderRole as String)
        builder.setAttribute(tempo, kAXDescriptionAttribute as String, "速度")

        let runtime = builder.makeLogicRuntime(appElement: app)
        #expect(AXLogicProElements.findTempoSlider(runtime: runtime) == tempo)
    }

    // MARK: - Class 3: containment over a lowercased aggregate

    /// Mutation that turns this red: remove `音源` from trackTypeInstrument's variants -- and each
    /// line below names its own: `Andamento` from tempoFieldLabel, `Grabar` from trackRecordButton,
    /// `音量` from sliderVolumeHint, `声像` from sliderPanHint, `相位` from headerPanHint,
    /// `Barra de controles` from transportContainerMetadata. Every consumer here lowercases an
    /// aggregate of attributes and asks `containsAny`, so each sentence carries the derived value
    /// inside other words and none of the members the set held before; the sibling control's word
    /// in the same locale must not match.
    @Test("containment consumers find one derived value inside a lowercased sentence and reject a sibling's word")
    func containmentClass() {
        // AXValueExtractors.extractTransportState: the tempo text field, Portuguese.
        #expect(AXLocalePolicy.tempoFieldLabel.containsAny(in: "campo de texto andamento"))
        #expect(!AXLocalePolicy.tempoFieldLabel.containsAny(in: "campo de texto posição"))
        // AXValueExtractors.readHeaderControlState: the track-header record button, Spanish.
        #expect(AXLocalePolicy.trackRecordButton.containsAny(in: "botón grabar de la pista"))
        #expect(!AXLocalePolicy.trackRecordButton.containsAny(in: "botón silenciar de la pista"))
        // AXLogicProElements.sliderText: volume and pan sliders, Simplified Chinese.
        #expect(AXLocalePolicy.sliderVolumeHint.containsAny(in: "轨道 音量 滑块"))
        #expect(!AXLocalePolicy.sliderVolumeHint.containsAny(in: "轨道 声像 滑块"))
        #expect(AXLocalePolicy.sliderPanHint.containsAny(in: "轨道 声像 滑块"))
        #expect(!AXLocalePolicy.sliderPanHint.containsAny(in: "轨道 音量 滑块"))
        // headerPanHint, Traditional Chinese.
        #expect(AXLocalePolicy.headerPanHint.containsAny(in: "軌道 相位 滑桿"))
        #expect(!AXLocalePolicy.headerPanHint.containsAny(in: "軌道 音量 滑桿"))
        // trackTypeInstrument, Japanese; `オーディオ` is trackTypeAudio's and must not match here.
        #expect(AXLocalePolicy.trackTypeInstrument.containsAny(in: "音源 トラック"))
        #expect(!AXLocalePolicy.trackTypeInstrument.containsAny(in: "オーディオ トラック"))
    }

    /// Mutation that turns this red: remove `Barra de controles` from transportContainerMetadata's
    /// variants. `looksLikeTransportContainer` lowercases identifier, title and description and
    /// asks whether any member is a substring; a bare group carrying only that description has no
    /// controls, sliders or fields to reach the classifier's other branches, so the row is the only
    /// thing that can say yes -- and the mixer's word says no.
    @Test("a group described in Spanish as the control bar classifies as the transport container")
    func containerMetadataClass() {
        let builder = FakeAXRuntimeBuilder()
        let bar = builder.element(9060)
        let mixer = builder.element(9061)
        builder.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(bar, kAXDescriptionAttribute as String, "Barra de controles")
        builder.setAttribute(mixer, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(mixer, kAXDescriptionAttribute as String, "Mezclador")

        let runtime = builder.makeAXRuntime()
        #expect(AXLogicProElements.looksLikeTransportContainer(bar, runtime: runtime))
        #expect(!AXLogicProElements.looksLikeTransportContainer(mixer, runtime: runtime))
    }

    /// Mutation that turns this red: remove `音源` from trackTypeInstrument's variants. The
    /// classifier at AXValueExtractors counts the candidate sets that match the header's aggregate
    /// and answers only when exactly one does, so the fixture carries the Japanese value on the
    /// icon and nothing any other track-type set holds.
    @Test("a header whose icon carries the Japanese instrument value classifies as a software instrument")
    func trackTypeClassifierClass() {
        let builder = FakeAXRuntimeBuilder()
        let header = builder.element(9070)
        let name = builder.element(9071)
        let icon = builder.element(9072)

        builder.setChildren(header, [name, icon])
        builder.setAttribute(header, kAXDescriptionAttribute as String, "1 ‘Sine Lead’ トラック")
        builder.setAttribute(name, kAXRoleAttribute as String, kAXStaticTextRole as String)
        builder.setAttribute(name, kAXValueAttribute as String, "Sine Lead")
        builder.setAttribute(icon, kAXDescriptionAttribute as String, "音源")

        let runtime = builder.makeAXRuntime()
        let track = AXValueExtractors.extractTrackState(from: header, index: 0, runtime: runtime)

        #expect(track.name == "Sine Lead")
        #expect(track.type == .softwareInstrument)
    }

    // MARK: - Class 4: literals spliced into AppleScript

    /// Mutation that turns this red: remove `Proyecto o sección…` from projectOrSectionMenuItem's
    /// variants. The Bounce route renders every label as a quoted AppleScript literal, so a value
    /// the set does not hold is a leaf the script never names.
    @Test("the Bounce script names the Spanish Project or Section leaf")
    func appleScriptSplicedClass() async {
        let probe = BounceScriptProbe()
        _ = await AccessibilityChannel.openBounceDialogViaMenu(
            systemEventsAuthorized: { true },
            executeScript: { script in
                probe.capture(script)
                return .success(#"{"result":"BOUNCE_MENU_ITEM_NOT_FOUND"}"#)
            }
        )
        #expect(probe.script.contains("\"Proyecto o sección…\""))
        #expect(probe.script.contains("\"项目或部分…\""))
        #expect(probe.script.contains("\"計畫案或段落⋯\""))
    }

    /// Mutation that turns this red: remove `テンポ` from midiImportTempoAlertText's variants. The
    /// MIDI-import route splices these labels into `contains` tests over the alert's body, which
    /// is a paragraph: the German sentence matches on `Tempo`, the row's own value, and the
    /// Japanese one only on the derived `テンポ`; the import panel's title matches nothing.
    @Test("the tempo alert is identified by the row's keyword inside its sentence, in German and Japanese")
    func tempoAlertKeywordClass() {
        #expect(AXLocalePolicy.midiImportTempoAlertText.containsAny(in: "Auch Tempo-Informationen importieren?"))
        #expect(AXLocalePolicy.midiImportTempoAlertText.containsAny(in: "テンポ情報も読み込みますか?"))
        #expect(AXLocalePolicy.midiImportTempoAlertText.containsAny(in: "Importar também as informações de andamento?"))
        #expect(!AXLocalePolicy.midiImportTempoAlertText.containsAny(in: "Importieren"))
        // Every member survives the splice filter: none carries a quote or a backslash.
        for label in AXLocalePolicy.midiImportTempoAlertText.labels {
            #expect(!label.contains("\"") && !label.contains("\\"), "\(label) would be dropped by the splice filter")
        }
    }

    // MARK: - Class 5: the Undo title

    /// Mutation that turns this red: remove `Plug-in in Channel-Strip einfügen` from
    /// undoPluginInsertMenuItem's variants. The rollback at AccessibilityChannel+VerifiedPlugins
    /// asks `containsAny` on whatever Undo entry the Edit menu offers, so the operation NAME has to
    /// be a member; a different operation's title, which the rollback must refuse, is not.
    @Test("the Undo title of a German or Japanese insert is ours, and another operation's is not")
    func undoTitleClass() {
        #expect(AXLocalePolicy.undoPluginInsertMenuItem.containsAny(in: "Undo Plug-in in Channel-Strip einfügen"))
        #expect(AXLocalePolicy.undoPluginInsertMenuItem.containsAny(in: "Undo チャンネルストリップにプラグインを挿入"))
        #expect(AXLocalePolicy.undoPluginInsertMenuItem.containsAny(in: "Undo Insert Plug-in in Channel Strip"))
        #expect(!AXLocalePolicy.undoPluginInsertMenuItem.containsAny(in: "Undo selected Channel Strips"))
        #expect(!AXLocalePolicy.undoPluginInsertMenuItem.containsAny(in: "Undo Channel-Strip einfügen"))
    }
}
