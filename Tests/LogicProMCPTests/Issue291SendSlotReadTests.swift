@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// MARK: - #291 — send-slot occupancy from the knob that follows the button
//
// Measured 2026-09-13 on Logic 12.3 (6674), en: an empty send slot is an `AXButton` whose help
// begins "Send slot." and names no destination anywhere; an assigned send adds an `AXSlider`
// described "send knob" whose help begins "Send Level knob.", immediately after its button in
// pre-order. The slot's own menu still marked "No Send" while the send existed, so the knob is the
// only evidence of occupancy the tree offers — and the destination is not in it.
//
// The 2026-09-27 dumps at the end of this file did not reproduce that shape: an assigned send is an
// `AXGroup` whose next sibling is the knob, and the button before it is a new empty slot. The tests
// here keep the button-then-knob shape because the reader still reads it; the ones at the end are
// the shape a running Logic draws.
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

    /// ADR-008 section 5's endpoint-and-edge-observations requirement: "an automated level or minus infinity is not an absent send". The knob's
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
        let plainStripSendSlots = try #require(strips[1]["send_slots"] as? [[String: Any]])
        #expect(plainStripSendSlots.isEmpty)
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

// MARK: - #291 — the destination labels the classifier will read, in every locale

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

// MARK: - #291 — the assigned send as a running Logic draws it (2026-09-27)
//
// Three strips dumped off Logic 12.3 (6674) on 2026-09-27 by Scripts/livekit/ax_mixer_strip_dump.swift
// and kept in docs/observations/evidence/2026-09-27-send-slot-strip-dumps-ko-KR-en-US.json. The rows
// below are generated from that file, every element below the strip with the attributes the reader
// could consult, so the fake tree has the live tree's shape and no convenient one: the assigned send
// is an `AXGroup` described by its destination with a bypass checkbox and a list button inside, its
// knob is the group's next SIBLING, and the empty send button Logic adds comes BEFORE it in the walk.
// The automation control is an `AXGroup` with the same two kinds of children, so a reader that took
// every group for a send would count it.

/// One element of a dumped strip. `path` is the child-index path below the strip.
private struct DumpRow {
    enum Value {
        case text(String)
        case number(Double)
    }

    let path: String
    let role: String
    let description: String?
    let help: String?
    let value: Value?
    let valueDescription: String?
}

/// `strip1-occupied-ko.txt` in the evidence file, every element below the strip, verbatim.
private let assignedSendStripKo: [DumpRow] = [
    DumpRow(path: "0", role: "AXTextField", description: "이름",
            help: "이름 필드. 채널 스트립의 이름을 변경하려면 두 번 클릭합니다. ", value: .text("Audio 1"), valueDescription: nil),
    DumpRow(path: "1", role: "AXButton", description: "음소거",
            help: "음소거 버튼. 더 이상 들리지 않도록 채널 스트립을 음소거합니다. Aux 채널 스트립 또는 출력 채널 스트립에서 믹스의 해당 파트 볼륨을 음소거하거나 마스터 채널 스트립에서 프로젝트를 음소거합니다. ", value: .text("끔"), valueDescription: nil),
    DumpRow(path: "2", role: "AXButton", description: "솔로",
            help: "솔로 버튼. 채널 스트립의 신호를 단독으로 들을 수 있도록 분리합니다. Aux 채널 스트립 또는 출력 채널 스트립에 사용하여 믹스의 해당 부분을 분리합니다. ", value: .text("끔"), valueDescription: nil),
    DumpRow(path: "3", role: "AXButton", description: "녹음",
            help: "녹음 활성화 버튼. 녹음을 위해 트랙을 준비하거나 녹음 준비된 트랙을 비활성화합니다. 버튼이 변경되어 트랙이 비활성 상태인지, 녹음 활성화 상태인지, 현재 녹음 중인지 나타냅니다. ", value: .text("끔"), valueDescription: nil),
    DumpRow(path: "4", role: "AXButton", description: "모니터링",
            help: "입력 모니터링 버튼. 녹음 활성화가 되지 않은 오디오 또는 소프트웨어 악기 트랙에서 수신 신호를 들을 수 있습니다. 녹음 전에 레벨을 설정하거나 파트를 연습할 때 유용합니다. ", value: .text("끔"), valueDescription: nil),
    DumpRow(path: "5", role: "AXSlider", description: "볼륨 페이더",
            help: "볼륨 페이더. 트랙의 재생 볼륨을 설정합니다. Aux 채널 스트립 또는 출력 채널 스트립에 사용하여 믹스의 해당 파트 볼륨을 조절합니다. 대부분의 경우 마스터 채널 스트립의 볼륨 페이더를 0dB로 둘 수 있습니다. ", value: .number(176), valueDescription: "0.3 dB"),
    DumpRow(path: "5.0", role: "AXValueIndicator", description: "fader knob",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "6", role: "AXTextField", description: "볼륨 페이더 레벨",
            help: "볼륨 디스플레이. 믹서의 왼쪽에 dB 크기를 기준으로 볼륨 페이더의 위치를 표시합니다. 양수 값은 신호 레벨을 올리고, 음수 값은 신호 레벨을 내리며, 0dB은 신호 레벨을 변경하지 않습니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "7", role: "AXButton", description: "피크 레벨 측정기",
            help: "피크 레벨 디스플레이. 재생 중 신호 피크를 표시합니다. 0dB 이상의 값은 빨간색으로 변하여 신호 클리핑을 표시합니다. 0dB 이상의 주황색 값은 내부 부동 소수점 계산으로 인해 클리핑되지 않습니다. ", value: .text("신호 클리핑 끔"), valueDescription: nil),
    DumpRow(path: "8", role: "AXSlider", description: "패닝",
            help: "패닝 노브 및 밸런스 노브. 채널 스트립 신호를 스테레오 필드에 배치하려면 수직으로 드래그합니다. ", value: .number(0), valueDescription: "0"),
    DumpRow(path: "8.0", role: "AXStaticText", description: "knob readout",
            help: nil, value: .text(""), valueDescription: nil),
    DumpRow(path: "9", role: "AXGroup", description: "읽기, 오토메이션이 활성화됨",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "9.0", role: "AXCheckBox", description: "오토메이션",
            help: nil, value: .number(1), valueDescription: nil),
    DumpRow(path: "9.1", role: "AXButton", description: "목록",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "10", role: "AXPopUpButton", description: "그룹",
            help: "그룹 슬롯. 채널 스트립을 그룹에 추가합니다. 전체 그룹에 대해 동시에 편집할 수 있는 채널 스트립 컨트롤을 정의할 수도 있습니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "11", role: "AXButton", description: "Stereo Output",
            help: "출력 슬롯. 채널 스트립 신호가 전송되는 채널 스트립 출력 대상을 선택하려면 길게 클릭합니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "12", role: "AXButton", description: "보내기 버튼",
            help: "센드 슬롯. 신호를 Aux 채널 스트립으로 라우팅합니다. 센드를 사용하여 여러 개의 트랙 출력 신호를 처리하거나 서브믹싱합니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "13", role: "AXGroup", description: "버스 256",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "13.0", role: "AXCheckBox", description: "바이패스",
            help: nil, value: .number(0), valueDescription: nil),
    DumpRow(path: "13.1", role: "AXButton", description: "목록",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "14", role: "AXSlider", description: "센드 노브",
            help: "센드 레벨 노브. Aux 채널 스트립으로 전송되는 신호의 양을 제어하려면 수직으로 드래그합니다. 센드를 사용하여 여러 개의 트랙 출력 신호를 처리하거나 서브믹싱합니다. ", value: .number(0), valueDescription: "-∞"),
    DumpRow(path: "15", role: "AXButton", description: "오디오 플러그인",
            help: "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다. 사용 중인 슬롯을 클릭하여 플러그인을 엽니다. 이펙트를 사용하여 실시간으로 신호를 변경합니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "16", role: "AXButton", description: "오디오 플러그인",
            help: "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다. 사용 중인 슬롯을 클릭하여 플러그인을 엽니다. 이펙트를 사용하여 실시간으로 신호를 변경합니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "17", role: "AXButton", description: "오디오 플러그인",
            help: "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다. 사용 중인 슬롯을 클릭하여 플러그인을 엽니다. 이펙트를 사용하여 실시간으로 신호를 변경합니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "18", role: "AXButton", description: "오디오 플러그인",
            help: "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다. 사용 중인 슬롯을 클릭하여 플러그인을 엽니다. 이펙트를 사용하여 실시간으로 신호를 변경합니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "19", role: "AXButton", description: "채널 모드",
            help: "채널 모드 버튼. 채널 스트립 입력 포맷을 모노 및 스테레오 사이에 전환하려면 클릭합니다. 길게 클릭한 다음 팝업 메뉴에서 모노, 스테레오, 왼쪽, 오른쪽 또는 서라운드를 선택합니다. ", value: .text("모노"), valueDescription: nil),
    DumpRow(path: "20", role: "AXButton", description: "입력 1",
            help: "입력 슬롯. 채널 스트립 입력 소스를 선택합니다. 오디오 기기(마이크 또는 악기의 연결 대상)의 입력 또는 내장 버스(다른 채널 스트립의 신호 수신)일 수 있습니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "21", role: "AXButton", description: "EQ",
            help: "EQ 디스플레이. 채널 EQ를 추가하거나 삽입된 채널 또는 리니어 페이즈 EQ를 열려면 클릭합니다. Shift-클릭하여 리니어 페이즈 EQ를 추가합니다. EQ를 사용하여 특정 주파수 범위의 레벨을 조절하여 오디오 신호를 형성합니다. ", value: .text("끔"), valueDescription: nil),
    DumpRow(path: "22", role: "AXButton", description: "게인 축소 측정기",
            help: "게인 감소 측정기. 첫 Compressor 플러그인의 게인 감소를 봅니다. Compressor가 삽입되지 않았다면, 삽입된 Limiter 또는 어댑티브 Limiter의 게인 감소를 나타냅니다. ", value: .text("끔"), valueDescription: nil),
    DumpRow(path: "23", role: "AXButton", description: "설정",
            help: "설정 버튼. 플러그인을 포함한 채널 스트립에 대한 설정 정보가 포함된 채널 스트립 설정을 로드하고 저장합니다. ", value: nil, valueDescription: nil),
]

/// `strip1-occupied-en.txt` in the evidence file, every element below the strip, verbatim.
private let assignedSendStripEn: [DumpRow] = [
    DumpRow(path: "0", role: "AXTextField", description: "name",
            help: "Name field. Double-click to rename the channel strip. ", value: .text("Audio 1"), valueDescription: nil),
    DumpRow(path: "1", role: "AXButton", description: "mute",
            help: "Mute button. Silence a channel strip so it’s no longer audible. Use on an aux or output channel strip to silence that part of the mix, or on the master channel strip to mute the project. ", value: .text("off"), valueDescription: nil),
    DumpRow(path: "2", role: "AXButton", description: "solo",
            help: "Solo button. Isolate a channel strip’s signal so that it can be heard alone. Use on an aux or output channel strip to isolate that part of the mix. ", value: .text("off"), valueDescription: nil),
    DumpRow(path: "3", role: "AXButton", description: "record",
            help: "Record Enable button. Prepare the track for recording, or deactivate a record-ready track. The button changes to indicate whether the track is inactive, record enabled, or currently recording. ", value: .text("off"), valueDescription: nil),
    DumpRow(path: "4", role: "AXButton", description: "monitoring",
            help: "Input Monitoring button. Hear incoming signals on audio or software instrument tracks that aren’t record enabled. This is useful when setting levels or practicing parts before recording. ", value: .text("off"), valueDescription: nil),
    DumpRow(path: "5", role: "AXSlider", description: "volume fader",
            help: "Volume fader. Set a track’s playback volume. Use on an aux or output channel strip to adjust the volume of that part of the mix. You can leave the Volume fader of the master channel strip at 0 dB in most cases. ", value: .number(176), valueDescription: "0.3 dB"),
    DumpRow(path: "5.0", role: "AXValueIndicator", description: "fader knob",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "6", role: "AXTextField", description: "volume fader level",
            help: "Volume display. Shows the position of the Volume fader referenced to the dB scale to the left of the Mixer. Positive values increase the signal level, negative values decrease it, and 0 dB leaves it unchanged. ", value: nil, valueDescription: nil),
    DumpRow(path: "7", role: "AXButton", description: "peak level meter",
            help: "Peak Level display. Shows the signal peak during playback. Values above 0 dB turn red to indicate signal clipping. Orange values above 0 dB do not clip due to internal floating point calculations. ", value: .text("signal clipping off"), valueDescription: nil),
    DumpRow(path: "8", role: "AXSlider", description: "pan",
            help: "Pan/Balance knob. Drag vertically to position the channel strip signal in the stereo field. ", value: .number(0), valueDescription: "0"),
    DumpRow(path: "8.0", role: "AXStaticText", description: "knob readout",
            help: nil, value: .text(""), valueDescription: nil),
    DumpRow(path: "9", role: "AXGroup", description: "Read, automation enabled",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "9.0", role: "AXCheckBox", description: "automation",
            help: nil, value: .number(1), valueDescription: nil),
    DumpRow(path: "9.1", role: "AXButton", description: "list",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "10", role: "AXPopUpButton", description: "group",
            help: "Group slot. Add the channel strip to a group. You can also define which channel strip controls can be edited for the entire group at the same time. ", value: nil, valueDescription: nil),
    DumpRow(path: "11", role: "AXButton", description: "Stereo Output",
            help: "Output slot. Click and hold to choose the channel strip output destination—where the channel strip signal is sent. ", value: nil, valueDescription: nil),
    DumpRow(path: "12", role: "AXButton", description: "send button",
            help: "Send slot. Route the signal to an aux channel strip. Use sends to process or submix multiple track output signals. ", value: nil, valueDescription: nil),
    DumpRow(path: "13", role: "AXGroup", description: "B256",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "13.0", role: "AXCheckBox", description: "bypass",
            help: nil, value: .number(0), valueDescription: nil),
    DumpRow(path: "13.1", role: "AXButton", description: "list",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "14", role: "AXSlider", description: "send knob",
            help: "Send Level knob. Drag vertically to control the amount of signal sent to an aux channel strip. Use sends to process or submix multiple track output signals. ", value: .number(0), valueDescription: "-∞"),
    DumpRow(path: "15", role: "AXButton", description: "audio plug-in",
            help: "Audio Effect slot. Insert an audio effect. Click an occupied slot to open the plug-in. Use effects to alter signals in real time. ", value: nil, valueDescription: nil),
    DumpRow(path: "16", role: "AXButton", description: "audio plug-in",
            help: "Audio Effect slot. Insert an audio effect. Click an occupied slot to open the plug-in. Use effects to alter signals in real time. ", value: nil, valueDescription: nil),
    DumpRow(path: "17", role: "AXButton", description: "audio plug-in",
            help: "Audio Effect slot. Insert an audio effect. Click an occupied slot to open the plug-in. Use effects to alter signals in real time. ", value: nil, valueDescription: nil),
    DumpRow(path: "18", role: "AXButton", description: "audio plug-in",
            help: "Audio Effect slot. Insert an audio effect. Click an occupied slot to open the plug-in. Use effects to alter signals in real time. ", value: nil, valueDescription: nil),
    DumpRow(path: "19", role: "AXButton", description: "channel mode",
            help: "Channel Mode button. Click to switch the channel strip input format between Mono and Stereo. Long-click, then choose Mono, Stereo, Left, Right, or Surround from the pop-up menu. ", value: .text("Mono"), valueDescription: nil),
    DumpRow(path: "20", role: "AXButton", description: "Input 1",
            help: "Input slot. Choose the channel strip input source. This can be an input of your audio device (your microphone or instrument is connected to) or an internal bus (to receive a signal from another channel strip). ", value: nil, valueDescription: nil),
    DumpRow(path: "21", role: "AXButton", description: "EQ",
            help: "EQ display. Click to add a Channel EQ or open an inserted Channel or Linear Phase EQ. Shift-click to add a Linear Phase EQ. Use EQ to shape an audio signal by adjusting the levels of specific frequency ranges. ", value: .text("off"), valueDescription: nil),
    DumpRow(path: "22", role: "AXButton", description: "gain reduction meter",
            help: "Gain reduction meter. Shows the gain reduction of the first Compressor plug-in. If no Compressor is inserted, it shows the gain reduction of an inserted Limiter or Adaptive Limiter plug-in. ", value: .text("off"), valueDescription: nil),
    DumpRow(path: "23", role: "AXButton", description: "setting",
            help: "Setting button. Load and save channel strip settings, which contain setup information for a channel strip, including plug-ins. ", value: nil, valueDescription: nil),
]

/// `strip2-after-send-ko.txt` in the evidence file, every element below the strip, verbatim.
private let stripBesideTheAssignmentKo: [DumpRow] = [
    DumpRow(path: "0", role: "AXTextField", description: "이름",
            help: "이름 필드. 채널 스트립의 이름을 변경하려면 두 번 클릭합니다. ", value: .text("Deluxe Classic"), valueDescription: nil),
    DumpRow(path: "1", role: "AXButton", description: "음소거",
            help: "음소거 버튼. 더 이상 들리지 않도록 채널 스트립을 음소거합니다. Aux 채널 스트립 또는 출력 채널 스트립에서 믹스의 해당 파트 볼륨을 음소거하거나 마스터 채널 스트립에서 프로젝트를 음소거합니다. ", value: .text("끔"), valueDescription: nil),
    DumpRow(path: "2", role: "AXButton", description: "솔로",
            help: "솔로 버튼. 채널 스트립의 신호를 단독으로 들을 수 있도록 분리합니다. Aux 채널 스트립 또는 출력 채널 스트립에 사용하여 믹스의 해당 부분을 분리합니다. ", value: .text("끔"), valueDescription: nil),
    DumpRow(path: "3", role: "AXSlider", description: "볼륨 페이더",
            help: "볼륨 페이더. 트랙의 재생 볼륨을 설정합니다. Aux 채널 스트립 또는 출력 채널 스트립에 사용하여 믹스의 해당 파트 볼륨을 조절합니다. 대부분의 경우 마스터 채널 스트립의 볼륨 페이더를 0dB로 둘 수 있습니다. ", value: .number(173), valueDescription: "0.0 dB"),
    DumpRow(path: "3.0", role: "AXValueIndicator", description: "fader knob",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "4", role: "AXTextField", description: "볼륨 페이더 레벨",
            help: "볼륨 디스플레이. 믹서의 왼쪽에 dB 크기를 기준으로 볼륨 페이더의 위치를 표시합니다. 양수 값은 신호 레벨을 올리고, 음수 값은 신호 레벨을 내리며, 0dB은 신호 레벨을 변경하지 않습니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "5", role: "AXButton", description: "피크 레벨 측정기",
            help: "피크 레벨 디스플레이. 재생 중 신호 피크를 표시합니다. 0dB 이상의 값은 빨간색으로 변하여 신호 클리핑을 표시합니다. 0dB 이상의 주황색 값은 내부 부동 소수점 계산으로 인해 클리핑되지 않습니다. ", value: .text("신호 클리핑 끔"), valueDescription: nil),
    DumpRow(path: "6", role: "AXSlider", description: "패닝",
            help: "패닝 노브 및 밸런스 노브. 채널 스트립 신호를 스테레오 필드에 배치하려면 수직으로 드래그합니다. ", value: .number(0), valueDescription: "0"),
    DumpRow(path: "6.0", role: "AXStaticText", description: "knob readout",
            help: nil, value: .text(""), valueDescription: nil),
    DumpRow(path: "7", role: "AXGroup", description: "읽기, 오토메이션이 활성화됨",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "7.0", role: "AXCheckBox", description: "오토메이션",
            help: nil, value: .number(1), valueDescription: nil),
    DumpRow(path: "7.1", role: "AXButton", description: "목록",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "8", role: "AXPopUpButton", description: "그룹",
            help: "그룹 슬롯. 채널 스트립을 그룹에 추가합니다. 전체 그룹에 대해 동시에 편집할 수 있는 채널 스트립 컨트롤을 정의할 수도 있습니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "9", role: "AXButton", description: "Stereo Output",
            help: "출력 슬롯. 채널 스트립 신호가 전송되는 채널 스트립 출력 대상을 선택하려면 길게 클릭합니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "10", role: "AXButton", description: "보내기 버튼",
            help: "센드 슬롯. 신호를 Aux 채널 스트립으로 라우팅합니다. 센드를 사용하여 여러 개의 트랙 출력 신호를 처리하거나 서브믹싱합니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "11", role: "AXButton", description: "보내기 버튼",
            help: "센드 슬롯. 신호를 Aux 채널 스트립으로 라우팅합니다. 센드를 사용하여 여러 개의 트랙 출력 신호를 처리하거나 서브믹싱합니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "12", role: "AXButton", description: "오디오 플러그인",
            help: "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다. 사용 중인 슬롯을 클릭하여 플러그인을 엽니다. 이펙트를 사용하여 실시간으로 신호를 변경합니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "13", role: "AXButton", description: "오디오 플러그인",
            help: "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다. 사용 중인 슬롯을 클릭하여 플러그인을 엽니다. 이펙트를 사용하여 실시간으로 신호를 변경합니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "14", role: "AXButton", description: "오디오 플러그인",
            help: "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다. 사용 중인 슬롯을 클릭하여 플러그인을 엽니다. 이펙트를 사용하여 실시간으로 신호를 변경합니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "15", role: "AXButton", description: "오디오 플러그인",
            help: "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다. 사용 중인 슬롯을 클릭하여 플러그인을 엽니다. 이펙트를 사용하여 실시간으로 신호를 변경합니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "16", role: "AXGroup", description: "E-Piano",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "16.0", role: "AXCheckBox", description: "바이패스",
            help: nil, value: .number(0), valueDescription: nil),
    DumpRow(path: "16.1", role: "AXButton", description: "열기",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "16.2", role: "AXButton", description: "목록",
            help: nil, value: nil, valueDescription: nil),
    DumpRow(path: "17", role: "AXButton", description: "MIDI 플러그인",
            help: "MIDI 이펙트 슬롯. MIDI 이펙트를 삽입합니다. 사용 중인 슬롯을 클릭하여 플러그인을 엽니다. ", value: nil, valueDescription: nil),
    DumpRow(path: "18", role: "AXButton", description: "EQ",
            help: "EQ 디스플레이. 채널 EQ를 추가하거나 삽입된 채널 또는 리니어 페이즈 EQ를 열려면 클릭합니다. Shift-클릭하여 리니어 페이즈 EQ를 추가합니다. EQ를 사용하여 특정 주파수 범위의 레벨을 조절하여 오디오 신호를 형성합니다. ", value: .text("끔"), valueDescription: nil),
    DumpRow(path: "19", role: "AXButton", description: "게인 축소 측정기",
            help: "게인 감소 측정기. 첫 Compressor 플러그인의 게인 감소를 봅니다. Compressor가 삽입되지 않았다면, 삽입된 Limiter 또는 어댑티브 Limiter의 게인 감소를 나타냅니다. ", value: .text("끔"), valueDescription: nil),
    DumpRow(path: "20", role: "AXButton", description: "Deluxe Classic",
            help: "설정 버튼. 플러그인을 포함한 채널 스트립에 대한 설정 정보가 포함된 채널 스트립 설정을 로드하고 저장합니다. ", value: nil, valueDescription: nil),
]


@Suite("#291 R1 an assigned send is the group beside its knob, as dumped live")
struct Issue291AssignedSendAsDumpedTests {
    /// Builds the strip from dump rows: every row becomes an element with exactly the attributes
    /// the dump read, and each is attached to the parent its path names, in dump order.
    private func strip(_ rows: [DumpRow], builder: FakeAXRuntimeBuilder, id: Int) -> AXUIElement {
        let strip = builder.element(id)
        builder.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        var byPath: [String: AXUIElement] = ["": strip]
        var children: [String: [AXUIElement]] = [:]
        for (offset, row) in rows.enumerated() {
            let element = builder.element(id + 1 + offset)
            builder.setAttribute(element, kAXRoleAttribute as String, row.role)
            if let description = row.description {
                builder.setAttribute(element, kAXDescriptionAttribute as String, description)
            }
            if let help = row.help { builder.setAttribute(element, kAXHelpAttribute as String, help) }
            switch row.value {
            case let .text(text): builder.setAttribute(element, kAXValueAttribute as String, text)
            case let .number(number): builder.setAttribute(element, kAXValueAttribute as String, number)
            case nil: break
            }
            if let valueDescription = row.valueDescription {
                builder.setAttribute(element, kAXValueDescriptionAttribute as String, valueDescription)
            }
            byPath[row.path] = element
            let parent = row.path.split(separator: ".").dropLast().joined(separator: ".")
            children[parent, default: []].append(element)
        }
        for (parent, list) in children {
            if let element = byPath[parent] { builder.setChildren(element, list) }
        }
        return strip
    }

    /// The Korean strip after `버스 256` was chosen in its send slot: the new empty button, then
    /// the group, then the knob at -∞. It reads as two slots, the empty one first because the walk
    /// runs bottom to top, and the second occupied with the level the knob carries.
    ///
    /// Kills: dropping the group branch — the reader at a139be44, which read this strip as the
    /// single empty slot and so never reported an occupied send live; and pairing the group with
    /// its pre-order successor instead of its next sibling (that successor is the bypass checkbox,
    /// so the slot disappears again).
    @Test("the Korean strip with a send reads one empty slot and one occupied")
    func koreanAssignedStripReadsEmptyThenOccupied() throws {
        let builder = FakeAXRuntimeBuilder()
        let dumped = strip(assignedSendStripKo, builder: builder, id: 32_000)
        let read = try #require(
            AXLogicProElements.sendSlotObservations(in: dumped, runtime: builder.makeAXRuntime())
        )
        #expect(read == [
            SendSlotObservation(ordinal: 0, state: .observedEmpty),
            SendSlotObservation(ordinal: 1, state: .occupiedUnknownDestination, levelRaw: 0, levelDescription: "-∞"),
        ])
    }

    /// The same assignment on an English Logic, where the group is described `B256` and every help
    /// string is English: the shape is the same, and so is the reading.
    ///
    /// Kills: the same two mutations as the Korean case, on the language whose help strings the
    /// canonical members carry.
    @Test("the English strip with a send reads one empty slot and one occupied")
    func englishAssignedStripReadsEmptyThenOccupied() throws {
        let builder = FakeAXRuntimeBuilder()
        let dumped = strip(assignedSendStripEn, builder: builder, id: 32_100)
        let read = try #require(
            AXLogicProElements.sendSlotObservations(in: dumped, runtime: builder.makeAXRuntime())
        )
        #expect(read == [
            SendSlotObservation(ordinal: 0, state: .observedEmpty),
            SendSlotObservation(ordinal: 1, state: .occupiedUnknownDestination, levelRaw: 0, levelDescription: "-∞"),
        ])
    }

    /// Strip 2 at the same moment: no send of its own, and two empty send buttons, because the
    /// assignment on strip 1 gave every strip a second row. Its automation `AXGroup` — a checkbox
    /// and a list button inside, like a send group — is followed by the group pop-up, not by a
    /// knob, so it is not a slot.
    ///
    /// Kills: taking every `AXGroup` for an occupied slot without the knob beside it (the
    /// automation group would read as a third, occupied, slot).
    @Test("a strip beside the assignment reads two empty slots and no group")
    func stripBesideTheAssignmentReadsTwoEmptySlots() throws {
        let builder = FakeAXRuntimeBuilder()
        let dumped = strip(stripBesideTheAssignmentKo, builder: builder, id: 32_200)
        let read = try #require(
            AXLogicProElements.sendSlotObservations(in: dumped, runtime: builder.makeAXRuntime())
        )
        #expect(read == [
            SendSlotObservation(ordinal: 0, state: .observedEmpty),
            SendSlotObservation(ordinal: 1, state: .observedEmpty),
        ])
    }
}
