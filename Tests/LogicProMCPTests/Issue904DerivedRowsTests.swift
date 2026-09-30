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
        // trackRecordButton, Spanish. No production reader consults it since #1020; the arm is read from
        // the record-enable checkbox (AXLogicProElements.trackArmControl).
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

/// #904, second pass: twelve more LabelSets from the census name the row that is the control's own
/// word. Every locale string below was written into this file by a script from the value
/// `Scripts/logic_canon.py resolve` returns for the row named -- none is typed -- and each test
/// drives the consumer the set actually has, with a value only the derived row supplies.
@Suite("#904 twelve legacy LabelSets derive from their row")
struct Issue904LegacyDerivedRowsTests {
    private static let logicStrings =
        "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/"
    private static let mixerStrings =
        "logic-canon://strings/Contents%2FFrameworks%2FMAMixer.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/"

    // MARK: - The row each set names

    /// Mutation that turns this red: change `Off#value` to `MixerSendOff#value` in
    /// automationModeOff's `derivedFrom`. MAMixer carries both rows with the same ten values, so
    /// the derived guard accepts either; only this comparison tells the plain row from the send's.
    @Test("each of the twelve names exactly the row the census review chose")
    func derivedFromNamesTheRow() throws {
        let rows: [(String, AXLocalePolicy.LabelSet, String)] = [
            ("automationModeWrite", AXLocalePolicy.automationModeWrite, Self.mixerStrings + "Write#value"),
            ("automationModeTouch", AXLocalePolicy.automationModeTouch, Self.mixerStrings + "Touch#value"),
            ("automationModeRead", AXLocalePolicy.automationModeRead, Self.mixerStrings + "Read#value"),
            ("automationModeOff", AXLocalePolicy.automationModeOff, Self.mixerStrings + "Off#value"),
            // English value: Controls
            ("pluginWindowControlsViewMenuItem", AXLocalePolicy.pluginWindowControlsViewMenuItem,
             "logic-canon://strings/Contents%2FFrameworks%2FMAToolKit.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/PluginWindow_Controls#value"),
            ("pluginWindowSmartControlsControl", AXLocalePolicy.pluginWindowSmartControlsControl,
             Self.logicStrings + "Smart%20Controls%23acc#value"),
            ("trackTypeExternalMIDI", AXLocalePolicy.trackTypeExternalMIDI, Self.logicStrings + "External%20MIDI#value"),
            ("trackTypeGMDevice", AXLocalePolicy.trackTypeGMDevice, Self.logicStrings + "GM%20Device#value"),
            ("regionKindMidi", AXLocalePolicy.regionKindMidi, Self.logicStrings + "MIDI#value"),
            // English value: MIDI Effect slot
            ("midiEffectSlotHelpKeyword", AXLocalePolicy.midiEffectSlotHelpKeyword,
             "logic-canon://quickhelp/QuickHelp/en/INS_086_MidiSlot#Title"),
            // English value: Left inspector channel strip
            ("inspectorChannelStripHelpPrefix", AXLocalePolicy.inspectorChannelStripHelpPrefix,
             "logic-canon://quickhelp/QuickHelp/en/INS_005_LeftArrangeCS#Title"),
            // English value: Delete Tracks and Content
            ("deleteTracksPrimaryButton", AXLocalePolicy.deleteTracksPrimaryButton,
             "logic-canon://nibstrings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FDeleteChannelStrips.strings/en/30.title#value"),
        ]
        #expect(rows.count == 12)
        for (name, set, expected) in rows {
            let ref = try #require(set.derivedFrom, "\(name) names no row")
            #expect(ref == expected, "\(name) names \(ref)")
        }
        #expect(AXLocalePolicy.deleteTracksPrimaryButton.alsoDerivedFrom == [Self.logicStrings + "Delete#value"])
    }

    // MARK: - Automation mode: whole tokens of the gated header group

    private func automationMode(value: String) -> AutomationMode? {
        let builder = FakeAXRuntimeBuilder()
        let header = builder.element(9800)
        let group = builder.element(9801)
        builder.setChildren(header, [group])
        builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(group, kAXDescriptionAttribute as String, "Automation")
        builder.setAttribute(group, kAXValueAttribute as String, value)
        return AXValueExtractors.extractTrackAutomationModeIfReadable(from: header, runtime: builder.makeAXRuntime())
    }

    /// Mutation that turns this red: remove the German value of MAMixer's `Off` row from
    /// automationModeOff's variants. The reader splits the gated group's value into tokens and
    /// asks for a whole-token match, and `nil` -- not `.off` -- is what it returns when no mode
    /// matches, so the German case cannot pass by falling back to the default. The Italian value
    /// is two words and reaches the reader through its first, which is also the French value; the
    /// mutation that turns that line red is removing the French value.
    @Test("a header whose automation group reads Off in German, Italian or Traditional Chinese reads .off")
    func automationOffTokenClass() {
        #expect(automationMode(value: "Aus") == .off)
        #expect(automationMode(value: "Non attiva") == .off)
        #expect(automationMode(value: "關閉") == .off)
        #expect(automationMode(value: "Automation") == nil)
    }

    // MARK: - Track type: containment over the header aggregate

    /// Mutation that turns this red: remove the German value of Logic's `GM Device` row from
    /// trackTypeGMDevice's variants. The German value carries no `MIDI`, so no other track-type
    /// set can claim the header and the answer without it is `.unknown`, not a different type.
    @Test("a header whose icon carries the German GM Device value classifies as external MIDI")
    func gmDeviceHeaderClass() {
        let builder = FakeAXRuntimeBuilder()
        let header = builder.element(9810)
        let name = builder.element(9811)
        let icon = builder.element(9812)
        builder.setChildren(header, [name, icon])
        builder.setAttribute(header, kAXDescriptionAttribute as String, "1 ‘Piano’")
        builder.setAttribute(name, kAXRoleAttribute as String, kAXStaticTextRole as String)
        builder.setAttribute(name, kAXValueAttribute as String, "Piano")
        builder.setAttribute(icon, kAXDescriptionAttribute as String, "GM-Gerät")

        let track = AXValueExtractors.extractTrackState(from: header, index: 0, runtime: builder.makeAXRuntime())
        #expect(track.type == .externalMIDI)
    }

    // MARK: - Mixer strip: the help strings of its slots

    /// Mutation that turns this red: remove the German value of the `INS_086_MidiSlot` QuickHelp
    /// title from midiEffectSlotHelpKeyword's variants. The strip reading counts its signals and
    /// answers only when exactly one fires, so without the member the German strip is
    /// `.undetermined`. The French line feeds Apple's title as it ships, trailing no-break space
    /// and all, and the trimmed member is found inside it.
    @Test("a strip whose MIDI effect slot help is German or French reads as the instrument family")
    func midiEffectSlotClass() {
        #expect(AXLogicProElements.reading(fromSlotKinds: ["MIDI-Effekt-Slot"]) == .instrumentFamily)
        #expect(AXLogicProElements.reading(fromSlotKinds: ["Slot d’effet MIDI\u{00A0}"]) == .instrumentFamily)
        #expect(AXLogicProElements.reading(fromSlotKinds: ["MIDI 效果插槽"]) == .instrumentFamily)
    }

    /// Mutation that turns this red: remove the Spanish value of the `INS_005_LeftArrangeCS`
    /// QuickHelp title from inspectorChannelStripHelpPrefix's variants. The finder asks
    /// `hasPrefixAny` of each layout item's help and refuses unless exactly one item with the
    /// expected name qualifies, so the decoy -- the same name, the value later in its help --
    /// proves the match is a prefix and not containment.
    @Test("the inspector strip is found by a Spanish help that begins with the row's title")
    func inspectorStripPrefixClass() {
        let builder = FakeAXRuntimeBuilder()
        let window = builder.element(9820)
        let strip = builder.element(9821)
        let decoy = builder.element(9822)
        builder.setChildren(window, [decoy, strip])
        for item in [strip, decoy] {
            builder.setAttribute(item, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            builder.setAttribute(item, kAXDescriptionAttribute as String, "Audio 1")
        }
        builder.setAttribute(strip, kAXHelpAttribute as String, "Canal de inspector izquierdo. …")
        builder.setAttribute(decoy, kAXHelpAttribute as String, "… Canal de inspector izquierdo")

        let found = AXLogicProElements.inspectorChannelStrip(
            named: "Audio 1", in: window, settleAttempts: 1, runtime: builder.makeAXRuntime()
        )
        #expect(found == strip)
    }

    // MARK: - Exact labels: Smart Controls, the plug-in window's View menu, the delete sheet

    private func smartControlsPane(toggle: String) -> Bool {
        let builder = FakeAXRuntimeBuilder()
        let window = builder.element(9830)
        let checkbox = builder.element(9831)
        builder.setAttribute(window, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        builder.setAttribute(window, kAXTitleAttribute as String, "")
        builder.setChildren(window, [checkbox])
        builder.setAttribute(checkbox, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(checkbox, kAXTitleAttribute as String, toggle)
        return AXLogicProElements.isSmartControlsWindow(window, runtime: builder.makeAXRuntime())
    }

    /// Mutation that turns this red: remove the Simplified Chinese value of `Smart Controls#acc`
    /// from pluginWindowSmartControlsControl's variants, or the Korean one. Korean ships the
    /// English name with a no-break space between the words, which `.exact` does not fold into the
    /// canonical's space, so it matches only through the member that carries it.
    @Test("a docked pane whose toggle is Chinese or Korean Smart Controls is the non-blocking pane")
    func smartControlsExactClass() {
        #expect(smartControlsPane(toggle: "智能控制"))
        #expect(smartControlsPane(toggle: "Smart\u{00A0}Controls"))
        #expect(smartControlsPane(toggle: "Smart Control"))
        #expect(!smartControlsPane(toggle: "智能控制 1"))
    }

    /// Mutation that turns this red: remove the German value of MAToolKit's
    /// `PluginWindow_Controls` from pluginWindowControlsViewMenuItem's variants. The writer takes
    /// the scoped View menu's items through `censusDescendantResult` and acts only on exactly one
    /// match; the Editor item beside it must not be that match.
    @Test("the plug-in window's German View menu yields exactly the Controls item")
    func controlsViewMenuItemClass() throws {
        let builder = FakeAXRuntimeBuilder()
        let menu = builder.element(9840)
        let controls = builder.element(9841)
        let editor = builder.element(9842)
        builder.setChildren(menu, [controls, editor])
        builder.setAttribute(controls, kAXRoleAttribute as String, kAXMenuItemRole as String)
        builder.setAttribute(controls, kAXTitleAttribute as String, "Regler")
        builder.setAttribute(editor, kAXRoleAttribute as String, kAXMenuItemRole as String)
        builder.setAttribute(editor, kAXTitleAttribute as String, "Editor")

        let result = AXLocalePolicy.censusDescendantResult(
            of: menu, role: kAXMenuItemRole, matching: AXLocalePolicy.pluginWindowControlsViewMenuItem,
            maxDepth: 3, runtime: builder.makeAXRuntime()
        )
        guard case let .success(census) = result else {
            Issue.record("the census could not read the menu: \(result)")
            return
        }
        #expect(census.matches == [controls])
    }

    private func deleteSheetKind(primaryButtonTitle: String) -> ModalReconciliation.BlockingModalKind {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9850)
        let window = builder.element(9851)
        let sheet = builder.element(9852)
        let deleteButton = builder.element(9853)
        let cancelButton = builder.element(9854)

        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setAttribute(window, "AXSheets", [sheet])
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "Delete Track and Regions?")
        builder.setChildren(sheet, [deleteButton, cancelButton])
        builder.setAttribute(deleteButton, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(deleteButton, kAXTitleAttribute as String, primaryButtonTitle)
        builder.setAttribute(cancelButton, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancelButton, kAXTitleAttribute as String, "Cancel")

        let runtime = builder.makeLogicRuntime(appElement: app, setAttributeHandler: nil, performActionHandler: nil)
        return ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))
    }

    /// Mutation that turns this red: remove the German value of Logic's plain `Delete` row from
    /// deleteTracksPrimaryButton's variants, or the Traditional Chinese value of
    /// DeleteChannelStrips.strings 30.title. Both drive the reader #545 fixed, `readModalSignals`,
    /// on the sheet shape #545 measured; `classify` is what decides, and without the member the
    /// German sheet is an unknown sheet that is left on screen.
    @Test("a German bare Delete and a Traditional Chinese channel-strip Delete classify as a delete confirmation")
    func deleteSheetExactClass() {
        #expect(deleteSheetKind(primaryButtonTitle: "Löschen") == .deleteConfirm)
        #expect(deleteSheetKind(primaryButtonTitle: "刪除音軌和內容") == .deleteConfirm)
        #expect(deleteSheetKind(primaryButtonTitle: "Löschen 刪除音軌和內容") != .deleteConfirm)
    }
}

/// #904, the two compositions. Neither set names a row: Logic assembles each description from
/// Apple's `%@ header` or `%@ contents` template and the `Tracks` noun, and
/// docs/canon/LABELSETS-WITHOUT-A-ROW.json records both factors. Every locale string below was
/// written by a script from the values `Scripts/logic_canon.py resolve` returned for them.
@Suite("#904 the track-header and track-content compositions reach their consumers")
struct Issue904ComposedLabelSetsTests {
    private func isHeaderRail(_ description: String) -> Bool {
        let builder = FakeAXRuntimeBuilder()
        let group = builder.element(9860)
        builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(group, kAXDescriptionAttribute as String, description)
        return AXLogicProElements.isTrackHeadersGroup(group, runtime: builder.makeAXRuntime())
    }

    /// Mutation that turns this red: remove the Spanish composition from trackHeadersDescription's
    /// variants. The group has no selection structure, so the description is the only way in;
    /// the bare noun proves the match is the composition and not the word inside it.
    @Test("a group described by the Spanish or Traditional Chinese track-header composition is the rail")
    func headerRailComposition() {
        #expect(isHeaderRail("Cabecera de Pistas"))
        #expect(isHeaderRail("音軌 標題"))
        #expect(!isHeaderRail("Pistas"))
    }

    private func enumeratesRegions(contentDescription: String) -> Bool {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9870)
        let window = builder.element(9871)
        let content = builder.element(9872)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [content])
        builder.setAttribute(content, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(content, kAXDescriptionAttribute as String, contentDescription)
        let runtime = builder.makeLogicRuntime(appElement: app)
        if case .success = AccessibilityChannel.enumerateRegionItems(runtime: runtime) { return true }
        return false
    }

    /// Mutation that turns this red: remove the French composition from trackContentExplicit's
    /// variants. `enumerateRegionItems` refuses with "Track Content group not found" when no group
    /// is the canvas, so an empty project and an unreadable one stay apart.
    @Test("a window whose canvas carries the French track-content composition enumerates its regions")
    func trackContentComposition() {
        #expect(enumeratesRegions(contentDescription: "Pistes contenus"))
        #expect(enumeratesRegions(contentDescription: "“轨道”内容"))
        #expect(!enumeratesRegions(contentDescription: "Pistes"))
    }
}

/// #904: the Edit menu's Undo entry is matched through Apple's `Undo %@` template, in all ten locales.
///
/// The (locale, template, operation) rows below were written into this file by a script from the
/// values `Scripts/logic_canon.py resolve` returns for `Undo %@` and for
/// `Insert Plug-in in Channel Strip#und`; none is typed. `.template` reads only what the template
/// says: the text before the `%@`, the text after it, and something between.
/// The English value of the row the set names: Undo %@
@Suite("#904 the Undo menu title matches through Apple's template in every locale")
struct Issue904UndoTemplateTests {
    private static let rows: [(locale: String, template: String, operation: String)] = [
            ("en", "Undo %@", "Insert Plug-in in Channel Strip"),
            ("ko", "%@ 실행 취소", "채널 스트립의 플러그인 삽입"),
            ("ja", "取り消す- %@", "チャンネルストリップにプラグインを挿入"),
            ("de", "„%@“ widerrufen", "Plug-in in Channel-Strip einfügen"),
            ("es", "Deshacer %@", "inserción del módulo del canal"),
            ("fr", "Annuler %@", "Insérer le module dans la tranche de console"),
            ("it", "Annulla %@", "Inserisci plugin nella channel strip"),
            ("pt", "Desfazer %@", "Inserir Plug-in no Canal"),
            ("zh_CN", "撤销%@", "在通道条中插入插件"),
            ("zh_TW", "還原「%@」", "在聲道控制排中插入外掛模組"),
    ]

    private static func parts(_ template: String) throws -> (head: String, tail: String) {
        let pieces = template.components(separatedBy: "%@")
        let two = try #require(pieces.count == 2 ? pieces : nil, "\(template) has not one %@")
        return (two[0], two[1])
    }

    private static func title(_ row: (locale: String, template: String, operation: String)) -> String {
        row.template.replacingOccurrences(of: "%@", with: row.operation)
    }

    /// Mutation that turns this red: change `Undo%20%25%40#value` to `Mixer%20Undo%20%25%40#value`
    /// in undoMenuItemPrefix's `derivedFrom`, or drop a locale's template from its variants.
    @Test("the set names the Undo template row and carries each locale's template")
    func namesTheRow() {
        #expect(AXLocalePolicy.undoMenuItemPrefix.derivedFrom
            == "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Undo%20%25%40#value")
        #expect(Self.rows.count == 10)
        for row in Self.rows {
            #expect(AXLocalePolicy.undoMenuItemPrefix.labels.contains(row.template), "\(row.locale) template missing")
            #expect(AXLocalePolicy.undoPluginInsertMenuItem.labels.contains(row.operation), "\(row.locale) operation missing")
        }
    }

    /// Mutation that turns this red (M4): put `editUndoMenuPath` back on `.prefix`. A label holding
    /// a `%@` is never a prefix of a title, so no locale's entry is found.
    @Test("the Edit-menu route reads the Undo entry with .template")
    func routeUsesTemplate() {
        #expect(AXLocalePolicy.editUndoMenuPath.itemMode == .template)
    }

    /// Mutations that turn this red: drop the suffix check (M1), drop the prefix check (M2).
    @Test("the real Undo title for our insert matches in each of the ten locales")
    func realTitleMatches() {
        for row in Self.rows {
            #expect(
                AXLocalePolicy.undoMenuItemPrefix.matches(Self.title(row), mode: .template),
                "\(row.locale): \(Self.title(row))")
        }
    }

    @Test("a menu holding that title is found through the route's own mode")
    func menuLookup() {
        for (index, row) in Self.rows.enumerated() {
            let builder = FakeAXRuntimeBuilder()
            let item = builder.element(9900 + index * 3)
            let other = builder.element(9901 + index * 3)
            let menu = builder.element(9902 + index * 3)
            builder.setAttribute(item, kAXRoleAttribute as String, kAXMenuItemRole as String)
            builder.setAttribute(item, kAXTitleAttribute as String, Self.title(row))
            builder.setAttribute(other, kAXRoleAttribute as String, kAXMenuItemRole as String)
            builder.setAttribute(other, kAXTitleAttribute as String, "Redo")
            builder.setChildren(menu, [other, item])
            let found = AXLocalePolicy.findMenuItem(
                under: menu, matching: AXLocalePolicy.editUndoMenuPath.item,
                mode: AXLocalePolicy.editUndoMenuPath.itemMode, runtime: builder.makeAXRuntime())
            #expect(found == item, "\(row.locale)")
        }
    }

    /// Mutation that turns this red (M1): drop the suffix check. Only locales whose template has text
    /// after the `%@` can show it.
    @Test("a title with only the prefix does not match")
    func prefixOnly() throws {
        var exercised = 0
        for row in Self.rows {
            let p = try Self.parts(row.template)
            guard !p.tail.isEmpty else { continue }
            exercised += 1
            #expect(!AXLocalePolicy.undoMenuItemPrefix.matches(p.head + row.operation, mode: .template), "\(row.locale)")
        }
        #expect(exercised >= 3)
    }

    /// Mutation that turns this red (M2): drop the prefix check.
    @Test("a title with only the suffix does not match")
    func suffixOnly() throws {
        var exercised = 0
        for row in Self.rows {
            let p = try Self.parts(row.template)
            guard !p.head.isEmpty else { continue }
            exercised += 1
            #expect(!AXLocalePolicy.undoMenuItemPrefix.matches(row.operation + p.tail, mode: .template), "\(row.locale)")
        }
        #expect(exercised >= 3)
    }

    /// Mutation that turns this red (M3): accept an empty middle.
    @Test("a title with nothing between the two fixed parts does not match")
    func emptyMiddle() throws {
        for row in Self.rows {
            let p = try Self.parts(row.template)
            #expect(!AXLocalePolicy.undoMenuItemPrefix.matches(p.head + p.tail, mode: .template), "\(row.locale)")
            #expect(!AXLocalePolicy.undoMenuItemPrefix.matches(p.head + " " + p.tail, mode: .template), "\(row.locale) blank")
        }
    }

    /// Mutation that turns this red (M4): drop the overlap check, so the head and the tail may share
    /// characters and the middle is cut with a negative length.
    @Test("a title where the two fixed parts would overlap does not match")
    func overlappingParts() {
        #expect(AXLocalePolicy.LabelSet.templateMatches("aba", template: "a%@a"))
        #expect(!AXLocalePolicy.LabelSet.templateMatches("a", template: "a%@a"))
    }

    @Test("fr Annuler and it Annulla alone, the Cancel word, do not match")
    func cancelWordAlone() {
        #expect(!AXLocalePolicy.undoMenuItemPrefix.matches("Annuler", mode: .template))
        #expect(!AXLocalePolicy.undoMenuItemPrefix.matches("Annulla", mode: .template))
        #expect(!AXLocalePolicy.undoMenuItemPrefix.matches("Deshacer", mode: .template))
        #expect(!AXLocalePolicy.undoMenuItemPrefix.matches("Redo Insert Plug-in", mode: .template))
    }
}

/// #904, the plug-in window's View switcher. `pluginWindowViewSwitcher` was derived on 2026-09-16
/// from the menu bar's `View#mti` row, whose French `Présentation` and Portuguese `Visualizar` are
/// not what the plug-in window's AXMenuButton carries: on 2026-09-29 a French and a Portuguese
/// Logic described it as `affichage` and `visualização`, the values of MAToolKit's `view` row, and
/// the writer refused both as an unmeasured locale. The writer matches the button's AXDescription
/// with `.exact` (`ControlsViewBooleanParameterWriter.measuredViewSwitcherOnce`), so that is the
/// mode every test here uses. Every locale string below was written into this file by a script from
/// the value `Scripts/logic_canon.py resolve` returns for the row named -- none is typed.
@Suite("#904 the plug-in window's View switcher is MAToolKit's view row, not the menu bar's")
struct Issue904PluginViewSwitcherRowTests {
    // MAToolKit's row, the plug-in window's own namespace. Its English value: view
    private static let toolKitView =
        "logic-canon://strings/Contents%2FFrameworks%2FMAToolKit.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/view#value"

    /// MAToolKit's `view` row in each of the ten locales Logic ships.
    private static let toolKitViewValues: [(String, String)] = [
        ("en", "view"),
        ("ko", "보기"),
        ("ja", "表示"),
        ("de", "Ansicht"),
        ("es", "visualización"),
        ("fr", "affichage"),
        ("it", "vista"),
        ("pt", "visualização"),
        ("zh_CN", "显示"),
        ("zh_TW", "顯示方式"),
    ]

    /// The menu bar's `View#mti` in the two locales where it and MAToolKit's `view` differ by more
    /// than case.
    private static let menuBarOnly: [(String, String)] = [
        ("fr", "Présentation"),
        ("pt", "Visualizar"),
    ]

    /// Mutation that turns this red: put the menu bar's `Logic.framework ... View%23mti#value`
    /// back in pluginWindowViewSwitcher's `derivedFrom`. The derived guard compares members with
    /// the row case-folded; only this comparison says which row was chosen.
    @Test("the switcher names MAToolKit's view row")
    func derivedFromNamesTheRow() throws {
        let ref = try #require(AXLocalePolicy.pluginWindowViewSwitcher.derivedFrom)
        #expect(ref == Self.toolKitView)
    }

    /// Mutation that turns this red: put `Présentation` back in place of `affichage`, or
    /// `Visualizar` in place of `visualização`, in pluginWindowViewSwitcher's variants. The
    /// lowercase `view`, `visualización` and `vista` match the capitalised members because
    /// `.exact` compares with `caseInsensitiveCompare`; the French and Portuguese values differ
    /// from the menu bar's by more than case, so they match only through their own members.
    @Test("each of the row's ten values is the switcher, matched as the writer matches it")
    func everyRowValueMatches() {
        #expect(Self.toolKitViewValues.count == 10)
        for (locale, value) in Self.toolKitViewValues {
            #expect(AXLocalePolicy.pluginWindowViewSwitcher.matches(value, mode: .exact),
                    "\(locale) \(value) is MAToolKit's view and must be the switcher")
        }
    }

    /// Mutation that turns this red: add `Présentation` or `Visualizar` to pluginWindowViewSwitcher's
    /// variants beside the new members. A menu button that carries the menu bar's word is not the
    /// switcher this control was read as, and must still refuse.
    @Test("the menu bar's French and Portuguese View are not the switcher")
    func menuBarSpellingsAreNotTheSwitcher() {
        for (locale, value) in Self.menuBarOnly {
            #expect(!AXLocalePolicy.pluginWindowViewSwitcher.matches(value, mode: .exact),
                    "\(locale) \(value) is the menu bar's View, not the plug-in window's")
        }
    }

    /// Mutation that turns this red: replace `Présentation` or `Visualizar` in viewMenuBar's
    /// variants. The menu bar reads its own row; correcting the plug-in switcher must not move it.
    @Test("the menu bar's View still carries French and Portuguese from its own row")
    func viewMenuBarKeepsItsRow() {
        for (locale, value) in Self.menuBarOnly {
            #expect(AXLocalePolicy.viewMenuBar.matches(value, mode: .exact),
                    "\(locale) \(value) is the menu bar's View")
        }
    }
}
