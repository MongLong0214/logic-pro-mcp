@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

@Suite("#291 output observations preserve absence versus unreadability")
struct Issue291OutputObservationTests {
    private struct Fixture {
        let builder = FakeAXRuntimeBuilder()
        let strip: AXUIElement
        let output: AXUIElement
        let runtime: AXHelpers.Runtime

        init(_ shape: String) {
            let b = builder
            strip = b.element(291_750)
            output = b.element(291_751)
            b.setRole(strip, kAXLayoutItemRole as String)
            b.setButton(output, description: "Stereo Output",
                        help: shape == "no_slot"
                            ? "Input slot. Choose the channel strip input source."
                            : "Output slot. Choose the channel strip output destination.",
                        x: 0, y: 0, width: 1, height: 1)
            b.setChildren(output, [])
            b.setChildren(strip, [output])
            let ownOutput = output
            runtime = b.makeAXRuntime(attributeValueResultHandler: { element, attribute in
                shape == "unreadable" && CFEqual(element, ownOutput)
                    && attribute == kAXDescriptionAttribute as String
                    ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : nil
            }, setAttributeHandler: nil, performActionHandler: nil)
        }
    }

    @Test(arguments: ["observed", "no_slot", "unreadable"])
    func statusPreservingReaderNeverTurnsAFailedOutputReadIntoAbsence(shape: String) {
        let fixture = Fixture(shape)
        let reading = AXLogicProElements.outputSlotReading(
            in: fixture.strip, runtime: fixture.runtime)
        switch shape {
        case "observed": #expect(reading == .destination("Stereo Output"))
        case "no_slot": #expect(reading == .noSlot)
        default: #expect(reading == .unreadable)
        }
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test(arguments: AXLocalePolicy.outputPopupOutputSubmenuTitle.labels)
    func localizedGenericOutputCaptionCannotEstablishAbsence(caption: String) {
        let builder = FakeAXRuntimeBuilder()
        let strip = builder.element(291_760)
        let output = builder.element(291_761)
        builder.setRole(strip, kAXLayoutItemRole as String)
        builder.setButton(
            output,
            description: caption,
            help: "Unmeasured routing control help.",
            x: 0, y: 0, width: 1, height: 1
        )
        builder.setChildren(output, [])
        builder.setChildren(strip, [output])

        #expect(AXLogicProElements.outputSlotReading(
            in: strip, runtime: builder.makeAXRuntime()
        ) == .unreadable)
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }

    @Test("an unmeasured bus-labelled button denies absence but not a sole measured output")
    func unmeasuredBusButtonDoesNotOverrideTheMeasuredOutput() {
        let builder = FakeAXRuntimeBuilder()
        let strip = builder.element(291_770)
        let unknown = builder.element(291_771)
        let output = builder.element(291_772)
        builder.setRole(strip, kAXLayoutItemRole as String)
        builder.setButton(
            unknown,
            description: "Bus 1",
            help: "Source selector. Choose what this channel strip hears.",
            x: 0, y: 0, width: 1, height: 1
        )
        builder.setButton(
            output,
            description: "Stereo Output",
            help: "Output slot. Choose the channel strip output destination.",
            x: 0, y: 1, width: 1, height: 1
        )
        builder.setChildren(unknown, [])
        builder.setChildren(output, [])
        builder.setChildren(strip, [unknown, output])

        #expect(AXLogicProElements.outputSlotReading(
            in: strip, runtime: builder.makeAXRuntime()
        ) == .destination("Stereo Output"))
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }
}
