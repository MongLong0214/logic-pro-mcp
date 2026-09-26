@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// MARK: - #291 R1 — send-slot occupancy from the knob that follows the button
//
// Measured 2026-09-13 on Logic 12.3 (6674), en: an empty send slot is an `AXButton` whose help
// begins "Send slot." and names no destination anywhere; an assigned send adds an `AXSlider`
// described "send knob" whose help begins "Send Level knob.", immediately after its button in
// pre-order. The slot's own menu still marked "No Send" while the send existed, so the knob is the
// only evidence of occupancy the tree offers — and the destination is not in it.
//
// Every test names the mutation it kills.

/// One locale's four slot titles as Apple pins them in QuickHelp (`INS_014_OutputSlot`,
/// `INS_012_InputSlot`, `INS_010_SendSlot`, `INS_011_SendLevelKnob`, field `Title`), resolved on
/// 2026-09-27 with `Scripts/logic_canon.py resolve`. Carried here rather than read back out of the
/// policy so that dropping a member from the policy is a failure and not a smaller test.
private struct SlotTitles: Sendable {
    let locale: String
    let output: String
    let input: String
    let send: String
    let knob: String
}

private let slotTitlesByLocale: [SlotTitles] = [
    SlotTitles(locale: "en", output: "Output slot", input: "Input slot",
               send: "Send slot", knob: "Send Level knob"),
    SlotTitles(locale: "ko", output: "출력 슬롯", input: "입력 슬롯",
               send: "센드 슬롯", knob: "센드 레벨 노브"),
    SlotTitles(locale: "ja", output: "出力スロット", input: "入力スロット",
               send: "センドスロット", knob: "センドレベルノブ"),
    SlotTitles(locale: "de", output: "Output-Slot", input: "Input-Slot",
               send: "Send-Slot", knob: "Send-Drehregler"),
    SlotTitles(locale: "es", output: "Ranura de salida", input: "Ranura de entrada",
               send: "Ranura de envío", knob: "Botón “Nivel de envío”"),
    SlotTitles(locale: "fr", output: "Slot de sortie", input: "Slot d’entrée",
               send: "Slot d’envoi", knob: "Potentiomètre Niveau d’envoi"),
    // Apple ships the English titles for these three.
    SlotTitles(locale: "it", output: "Output slot", input: "Input slot",
               send: "Send slot", knob: "Send Level knob"),
    SlotTitles(locale: "pt", output: "Output slot", input: "Input slot",
               send: "Send slot", knob: "Send Level knob"),
    SlotTitles(locale: "zh_CN", output: "输出插槽", input: "输入插槽",
               send: "发送插槽", knob: "“发送电平”旋钮"),
    SlotTitles(locale: "zh_TW", output: "Output slot", input: "Input slot",
               send: "Send slot", knob: "Send Level knob"),
]

/// One locale's output-slot destinations as Logic composes them: `Stereo Output`, `No Output`,
/// and the `Bus %d` / `Output %d-%d` templates with a number in (Logic.framework
/// `Localizable.strings`, resolved 2026-09-27). The bus and physical samples are written the way
/// the TEMPLATE writes them — Japanese puts no space before the number — so the prefix sets are
/// tested against what a slot would draw and not against the bare word.
private struct DestinationSamples: Sendable {
    let locale: String
    let stereo: String
    let noOutput: String
    let bus: String
    let physical: String
}

private let destinationSamplesByLocale: [DestinationSamples] = [
    DestinationSamples(locale: "en", stereo: "Stereo Output", noOutput: "No Output",
                       bus: "Bus 3", physical: "Output 3-4"),
    DestinationSamples(locale: "ko", stereo: "Stereo Output", noOutput: "출력 없음",
                       bus: "버스 3", physical: "출력 3-4"),
    DestinationSamples(locale: "ja", stereo: "Stereo Output", noOutput: "出力なし",
                       bus: "バス3", physical: "出力3-4"),
    DestinationSamples(locale: "de", stereo: "Stereo-Ausgabe", noOutput: "Kein Ausgang",
                       bus: "Bus 3", physical: "Output 3-4"),
    DestinationSamples(locale: "es", stereo: "Salida estéreo", noOutput: "Sin salida",
                       bus: "Bus 3", physical: "Salida 3-4"),
    DestinationSamples(locale: "fr", stereo: "Sortie stéréo", noOutput: "Pas de sortie",
                       bus: "Bus 3", physical: "Sortie 3-4"),
    DestinationSamples(locale: "it", stereo: "Uscita stereo", noOutput: "Nessuna uscita",
                       bus: "Bus 3", physical: "Uscita 3-4"),
    DestinationSamples(locale: "pt", stereo: "Saída Estéreo", noOutput: "Sem Saída",
                       bus: "Bus 3", physical: "Saída 3-4"),
    DestinationSamples(locale: "zh_CN", stereo: "立体声输出", noOutput: "没有输出",
                       bus: "总线 3", physical: "输出 3-4"),
    DestinationSamples(locale: "zh_TW", stereo: "立體聲輸出", noOutput: "沒有輸出",
                       bus: "匯流排 3", physical: "輸出 3-4"),
]

private let readFailure = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)

@Suite("#291 R1 send slots are occupied by the knob that follows, and by nothing else")
struct Issue291SendSlotReadTests {
    private func layoutItem(_ builder: FakeAXRuntimeBuilder, id: Int) -> AXUIElement {
        let strip = builder.element(id)
        builder.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        return strip
    }

    /// Shaped like the real one: a button that names no destination anywhere.
    private func sendButton(
        _ builder: FakeAXRuntimeBuilder, id: Int, help: String = "Send slot. Route the signal to an aux channel strip."
    ) -> AXUIElement {
        let button = builder.element(id)
        builder.setAttribute(button, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(button, kAXHelpAttribute as String, help)
        builder.setAttribute(button, kAXDescriptionAttribute as String, "send button")
        return button
    }

    /// The element Logic grows beside an assigned send, as measured 2026-09-13.
    private func sendKnob(
        _ builder: FakeAXRuntimeBuilder, id: Int, value: Any? = 0.5, valueDescription: String? = "-6.0 dB",
        help: String = "Send Level knob. Set the level of the signal sent to the aux channel strip."
    ) -> AXUIElement {
        let knob = builder.element(id)
        builder.setAttribute(knob, kAXRoleAttribute as String, kAXSliderRole as String)
        builder.setAttribute(knob, kAXHelpAttribute as String, help)
        builder.setAttribute(knob, kAXDescriptionAttribute as String, "send knob")
        if let value { builder.setAttribute(knob, kAXValueAttribute as String, value) }
        if let valueDescription {
            builder.setAttribute(knob, kAXValueDescriptionAttribute as String, valueDescription)
        }
        return knob
    }

    private func outputButton(_ builder: FakeAXRuntimeBuilder, id: Int, help: String, description: String) -> AXUIElement {
        let button = builder.element(id)
        builder.setAttribute(button, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(button, kAXHelpAttribute as String, help)
        builder.setAttribute(button, kAXDescriptionAttribute as String, description)
        return button
    }

    /// The measured shape: button, knob, button reads as one occupied slot and one empty one, in
    /// that order, with the level carried on the occupied one.
    ///
    /// Kills: attaching any slider in the strip to any button (slot 1 would read occupied), and
    /// renumbering (the second slot must be ordinal 1).
    @Test("button, knob, button reads occupied then empty")
    func buttonKnobButtonReadsOccupiedThenEmpty() throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = layoutItem(builder, id: 31_000)
        builder.setChildren(strip, [
            sendButton(builder, id: 31_001),
            sendKnob(builder, id: 31_002),
            sendButton(builder, id: 31_003),
        ])
        let read = try #require(AXLogicProElements.sendSlotObservations(in: strip, runtime: builder.makeAXRuntime()))
        #expect(read == [
            SendSlotObservation(ordinal: 0, state: .occupiedUnknownDestination, levelRaw: 0.5, levelDescription: "-6.0 dB"),
            SendSlotObservation(ordinal: 1, state: .observedEmpty, levelRaw: nil, levelDescription: nil),
        ])
    }

    /// The knob has to FOLLOW its button. A slider before the first send button is somebody
    /// else's control, and a strip carries several sliders that are not send knobs.
    ///
    /// Kills: searching the strip for any matching slider instead of reading the successor.
    @Test("a knob that precedes the button does not occupy it")
    func knobBeforeTheButtonDoesNotOccupyIt() throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = layoutItem(builder, id: 31_100)
        builder.setChildren(strip, [
            sendKnob(builder, id: 31_101),
            sendButton(builder, id: 31_102),
        ])
        let read = try #require(AXLogicProElements.sendSlotObservations(in: strip, runtime: builder.makeAXRuntime()))
        #expect(read == [SendSlotObservation(ordinal: 0, state: .observedEmpty)])
    }

    /// Children that did not read are slots nobody saw. `nil`, not `[]` — at the strip and one
    /// level below it alike, because the walk goes four deep and a failure anywhere in it leaves
    /// the list unknown.
    ///
    /// Kills: returning `[]` on unread children.
    @Test("unread children yield nil, not an empty list")
    func unreadChildrenYieldNil() {
        let builder = FakeAXRuntimeBuilder()
        let strip = layoutItem(builder, id: 31_200)
        builder.setChildren(strip, [sendButton(builder, id: 31_201)])
        // Both seams fail, so a reader on either sees the same failed read.
        let runtime = builder.makeAXRuntime(
            childrenHandler: { element in CFEqual(element, strip) ? [] : nil },
            childrenResultHandler: { element in CFEqual(element, strip) ? .failure(readFailure) : nil },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        #expect(AXLogicProElements.sendSlotObservations(in: strip, runtime: runtime) == nil)

        let deeper = layoutItem(builder, id: 31_250)
        let group = builder.element(31_251)
        builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setChildren(deeper, [sendButton(builder, id: 31_252), group])
        builder.setChildren(group, [sendButton(builder, id: 31_253)])
        let deeperRuntime = builder.makeAXRuntime(
            childrenHandler: { element in CFEqual(element, group) ? [] : nil },
            childrenResultHandler: { element in CFEqual(element, group) ? .failure(readFailure) : nil },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        #expect(AXLogicProElements.sendSlotObservations(in: deeper, runtime: deeperRuntime) == nil)
    }

    /// -25212 is an ANSWER: the element has no children. So is a readable strip with no send
    /// button on it. Both are `[]`, which a consumer may read as "looked, and there are none".
    ///
    /// Kills: treating every failed read as unknown (the definitive one would become `nil`).
    @Test("a definitive absence yields an empty list")
    func definitiveAbsenceYieldsAnEmptyList() {
        let builder = FakeAXRuntimeBuilder()
        let childless = layoutItem(builder, id: 31_300)
        let noValue = AXHelpers.AXStatusError(raw: AXError.noValue.rawValue)
        let runtime = builder.makeAXRuntime(
            childrenHandler: { element in CFEqual(element, childless) ? [] : nil },
            childrenResultHandler: { element in CFEqual(element, childless) ? .failure(noValue) : nil },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        #expect(AXLogicProElements.sendSlotObservations(in: childless, runtime: runtime) == [])

        let noSends = layoutItem(builder, id: 31_350)
        builder.setChildren(noSends, [
            outputButton(builder, id: 31_351,
                         help: "Output slot. Click and hold to choose the channel strip output.",
                         description: "Stereo Output"),
        ])
        #expect(AXLogicProElements.sendSlotObservations(in: noSends, runtime: builder.makeAXRuntime()) == [])
    }

    /// A button was found and the element after it would not say what it is. That slot is
    /// `unreadable` — not empty, because "no knob seen" was never established — and it keeps its
    /// ordinal, so the readable slot after it is still ordinal 1.
    ///
    /// Kills: filing an unreadable successor as `observedEmpty`, and skipping unreadable slots
    /// (the list would then have one entry, at ordinal 0).
    @Test("an unreadable successor is unreadable and keeps its ordinal")
    func unreadableSuccessorIsUnreadableAndKeepsItsOrdinal() throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = layoutItem(builder, id: 31_400)
        let unreadable = builder.element(31_402)
        builder.setAttribute(unreadable, kAXRoleAttribute as String, kAXSliderRole as String)
        builder.setChildren(strip, [
            sendButton(builder, id: 31_401),
            unreadable,
            sendButton(builder, id: 31_403),
            sendKnob(builder, id: 31_404),
        ])
        let roleFails = builder.makeAXRuntime(
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, unreadable), attribute == (kAXRoleAttribute as String) {
                    return .failure(readFailure)
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        let read = try #require(AXLogicProElements.sendSlotObservations(in: strip, runtime: roleFails))
        #expect(read.map(\.ordinal) == [0, 1])
        #expect(read.map(\.state) == [.unreadable, .occupiedUnknownDestination])

        // The same when the role reads as a slider and the HELP is what will not read.
        let helpFails = builder.makeAXRuntime(
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, unreadable), attribute == (kAXHelpAttribute as String) {
                    return .failure(readFailure)
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        let helpRead = try #require(AXLogicProElements.sendSlotObservations(in: strip, runtime: helpFails))
        #expect(helpRead.map(\.state) == [.unreadable, .occupiedUnknownDestination])
    }

    /// ADR-008 §5 R1: "an automated level or minus infinity is not an absent send". The knob's
    /// value is carried when it is a finite number and decides nothing — a knob at -∞, a knob
    /// whose value is a string, and a knob whose value will not read are all occupied slots. And
    /// -∞ cannot be written as JSON, so the strip must still encode.
    ///
    /// Kills: deriving `state` from `levelRaw`.
    @Test("occupancy does not depend on the level")
    func occupancyDoesNotDependOnTheLevel() throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = layoutItem(builder, id: 31_500)
        let unreadableValue = sendKnob(builder, id: 31_506, value: 0.3, valueDescription: nil)
        builder.setChildren(strip, [
            sendButton(builder, id: 31_501),
            sendKnob(builder, id: 31_502, value: -Double.infinity, valueDescription: "-∞ dB"),
            sendButton(builder, id: 31_503),
            sendKnob(builder, id: 31_504, value: "−∞", valueDescription: nil),
            sendButton(builder, id: 31_505),
            unreadableValue,
        ])
        let runtime = builder.makeAXRuntime(
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, unreadableValue), attribute == (kAXValueAttribute as String) {
                    return .failure(readFailure)
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        let read = try #require(AXLogicProElements.sendSlotObservations(in: strip, runtime: runtime))
        #expect(read.map(\.state) == [
            .occupiedUnknownDestination, .occupiedUnknownDestination, .occupiedUnknownDestination,
        ])
        #expect(read.map(\.levelRaw) == [nil, nil, nil])
        #expect(read.map(\.levelDescription) == ["-∞ dB", nil, nil])

        var state = ChannelStripState(trackIndex: 0)
        state.sendSlots = read
        let wire = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(wire.contains("\"send_slots\""))
        #expect(!wire.contains("level_raw"))
    }

    /// Every locale Logic ships, from Apple's own titles: the output, input and send slots are
    /// found and the send reads occupied by its knob. Each locale is one case, so the failure
    /// names the language.
    ///
    /// Kills: dropping any one member from the four slot sets (that locale reads nil or empty).
    @Test("every locale's slot titles are read", arguments: slotTitlesByLocale)
    fileprivate func everyLocalesSlotTitlesAreRead(titles: SlotTitles) throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = layoutItem(builder, id: 31_600)
        // A description sentence follows the title, as the live help does; Japanese separates
        // them with `。` rather than `. ` and the match is a substring, so the separator is not
        // what is under test.
        builder.setChildren(strip, [
            outputButton(builder, id: 31_601, help: "\(titles.output). Choose where the signal goes.",
                         description: "Stereo Output"),
            outputButton(builder, id: 31_602, help: "\(titles.input). Choose the input source.",
                         description: "Input 1"),
            sendButton(builder, id: 31_603, help: "\(titles.send). Route the signal to an aux."),
            sendKnob(builder, id: 31_604, help: "\(titles.knob). Set the send level."),
        ])
        let runtime = builder.makeAXRuntime()
        #expect(AXLogicProElements.outputSlotDestination(in: strip, runtime: runtime) == "Stereo Output",
                "\(titles.locale): output slot not read")
        #expect(AXLogicProElements.inputSlotSource(in: strip, runtime: runtime) == "Input 1",
                "\(titles.locale): input slot not read")
        let sends = try #require(AXLogicProElements.sendSlotObservations(in: strip, runtime: runtime),
                                 "\(titles.locale): send slots unread")
        #expect(sends.map(\.state) == [.occupiedUnknownDestination], "\(titles.locale): send slot not read")
    }

    /// The wiring line itself, through `defaultGetMixerState`: the other tests call the reader
    /// directly, so only this one fails when `state.sendSlots = …` is deleted from the readback.
    /// The live-dump strip carries one empty send button followed by a group; a button-and-knob
    /// pair appended after it makes the second slot the occupied one.
    ///
    /// Kills: deleting the wiring line in `defaultGetMixerState`.
    @Test("the mixer readback carries the send slots it read")
    func mixerReadbackCarriesSendSlots() throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = makeLiveDumpStrip(builder, id: 31_700)
        builder.setChildren(strip, AXHelpers.getChildren(strip, runtime: builder.makeAXRuntime()) + [
            sendButton(builder, id: 31_790),
            sendKnob(builder, id: 31_791, value: 0.25, valueDescription: "-12.0 dB"),
        ])
        let fixture = make123MixerFixture(stripCount: 2, firstStrip: strip, builder: builder)
        let result = AccessibilityChannel.defaultGetMixerState(runtime: fixture.runtime)
        let strips = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [[String: Any]]
        )
        let slots = try #require(strips.first?["send_slots"] as? [[String: Any]])
        #expect(slots.map { $0["state"] as? String } == ["observed_empty", "occupied_unknown_destination"])
        #expect(slots.map { $0["ordinal"] as? Int } == [0, 1])
        #expect(slots[1]["level_raw"] as? Double == 0.25)
        #expect(slots[1]["level_description"] as? String == "-12.0 dB")
        // The plain simple strip has no send button at all: read, and none.
        #expect((strips[1]["send_slots"] as? [[String: Any]])?.isEmpty == true)
    }

    /// The single-strip readback takes the same per-strip pass, so it carries the field too.
    ///
    /// Kills: deleting the wiring line in `defaultGetChannelStrip`.
    @Test("the channel strip readback carries the send slots it read")
    func channelStripReadbackCarriesSendSlots() throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = makeLiveDumpStrip(builder, id: 31_800)
        let fixture = make123MixerFixture(stripCount: 1, firstStrip: strip, builder: builder)
        let result = AccessibilityChannel.defaultGetChannelStrip(params: ["index": "0"], runtime: fixture.runtime)
        let state = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let slots = try #require(state["send_slots"] as? [[String: Any]])
        #expect(slots.map { $0["state"] as? String } == ["observed_empty"])
    }
}

// MARK: - #291 R1 — the destination labels the classifier will read, in every locale

@Suite("#291 R1 destination labels are Apple's values in every locale")
struct Issue291DestinationLabelTests {
    /// Each locale's four destinations, as Logic composes them, are recognised by exactly the set
    /// meant for them: whole-string for the two fixed labels, prefix for the two composed ones.
    ///
    /// Kills: dropping any one variant from the four destination sets.
    @Test("every locale's destinations are classified", arguments: destinationSamplesByLocale)
    fileprivate func everyLocalesDestinationsAreClassified(samples: DestinationSamples) {
        #expect(AXLocalePolicy.stereoOutputLabel.matches(samples.stereo, mode: .exact),
                "\(samples.locale): stereo output")
        #expect(AXLocalePolicy.noOutputLabel.matches(samples.noOutput, mode: .exact),
                "\(samples.locale): no output")
        #expect(AXLocalePolicy.busOutputLabelPrefix.matches(samples.bus, mode: .prefix),
                "\(samples.locale): bus prefix")
        #expect(AXLocalePolicy.physicalOutputLabelPrefix.matches(samples.physical, mode: .prefix),
                "\(samples.locale): physical output prefix")
    }

    /// The sets do not classify each other's labels, and a label that is none of them is none of
    /// them. `Stereo Output` CONTAINS `output`, which is why the physical set is a prefix set and
    /// the stereo one is matched whole; a `.contains` match here would file the main output as a
    /// physical one.
    ///
    /// Kills: widening either prefix set to `.contains`, or classifying unknown labels as a bus.
    @Test("the destination sets do not cross-classify")
    func destinationSetsDoNotCrossClassify() {
        #expect(!AXLocalePolicy.physicalOutputLabelPrefix.matches("Stereo Output", mode: .prefix))
        #expect(!AXLocalePolicy.busOutputLabelPrefix.matches("Stereo Output", mode: .prefix))
        #expect(!AXLocalePolicy.noOutputLabel.matches("Stereo Output", mode: .exact))
        #expect(!AXLocalePolicy.physicalOutputLabelPrefix.matches("Bus 3", mode: .prefix))
        #expect(!AXLocalePolicy.busOutputLabelPrefix.matches("Output 3-4", mode: .prefix))
        #expect(!AXLocalePolicy.stereoOutputLabel.matches("Output 3-4", mode: .exact))
        for set in [AXLocalePolicy.stereoOutputLabel, AXLocalePolicy.noOutputLabel] {
            #expect(!set.matches("Rumpelstiltskin", mode: .exact))
        }
        for set in [AXLocalePolicy.busOutputLabelPrefix, AXLocalePolicy.physicalOutputLabelPrefix] {
            #expect(!set.matches("Rumpelstiltskin", mode: .prefix))
        }
        // Italian composes a single physical channel as `Output %d` and a pair as `Uscita %d-%d`.
        #expect(AXLocalePolicy.physicalOutputLabelPrefix.matches("Output 3", mode: .prefix))
        #expect(AXLocalePolicy.physicalOutputLabelPrefix.matches("Uscita 3-4", mode: .prefix))
    }

    /// `allLabelSets` is the allowlist an AX snapshot records labels verbatim under; a set missing
    /// from it is redacted to a shape and cannot be matched by a fixture.
    ///
    /// Kills: leaving any of the eight sets out of `allLabelSets`.
    @Test("the eight #291 R1 sets are in allLabelSets")
    func theEightSetsAreListed() {
        let all = AXLocalePolicy.allLabelSets
        for set in [
            AXLocalePolicy.outputSlotHelpKeyword, AXLocalePolicy.inputSlotHelpKeyword,
            AXLocalePolicy.sendSlotHelpKeyword, AXLocalePolicy.sendLevelKnobHelpKeyword,
            AXLocalePolicy.stereoOutputLabel, AXLocalePolicy.noOutputLabel,
            AXLocalePolicy.busOutputLabelPrefix, AXLocalePolicy.physicalOutputLabelPrefix,
        ] {
            #expect(all.contains(set), "\(set.canonical) is not in allLabelSets")
        }
    }
}
