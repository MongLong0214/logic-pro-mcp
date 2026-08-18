@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// MARK: - #291 — a channel strip's output slot, read rather than left null
//
// `ChannelStripState.output` has existed since the model was written and nothing ever set it, so
// `logic://mixer` published a field that was always null. These pin what the reader does and, more
// importantly, what it refuses to do.
//
// Measured on Logic Pro 12.3: the output slot is an `AXButton` whose help reads "Output slot. Click
// and hold to choose the channel strip output…" and whose DESCRIPTION carries the destination
// ("Stereo Output"). The send slot beside it is described only as "send button" and, when empty,
// exposes no `AXValue`, `AXValueDescription` or `AXTitle` — which is why sends have no counterpart
// here and this change claims none.
@Suite("#291 the output slot is read, and nothing else is claimed")
struct Issue291OutputSlotReadTests {
    private func strip(
        _ builder: FakeAXRuntimeBuilder,
        id: Int,
        outputHelp: String?,
        outputDescription: String?,
        withSendButton: Bool = true
    ) -> AXUIElement {
        let strip = builder.element(id)
        builder.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        var children: [AXUIElement] = []
        if let outputHelp {
            let slot = builder.element(id + 1)
            builder.setAttribute(slot, kAXRoleAttribute as String, kAXButtonRole as String)
            builder.setAttribute(slot, kAXHelpAttribute as String, outputHelp)
            if let outputDescription {
                builder.setAttribute(slot, kAXDescriptionAttribute as String, outputDescription)
            }
            children.append(slot)
        }
        if withSendButton {
            // Deliberately shaped like the real one: a button that names no destination anywhere.
            let send = builder.element(id + 2)
            builder.setAttribute(send, kAXRoleAttribute as String, kAXButtonRole as String)
            builder.setAttribute(send, kAXHelpAttribute as String,
                                 "Send slot. Route the signal to an aux channel strip.")
            builder.setAttribute(send, kAXDescriptionAttribute as String, "send button")
            children.append(send)
        }
        builder.setChildren(strip, children)
        return strip
    }

    @Test("the destination comes from the output slot's description")
    func readsTheDestination() throws {
        let builder = FakeAXRuntimeBuilder()
        let element = strip(
            builder, id: 29_100,
            outputHelp: "Output slot. Click and hold to choose the channel strip output.",
            outputDescription: "Stereo Output"
        )
        let read = AXLogicProElements.outputSlotDestination(
            in: element, runtime: builder.makeAXRuntime()
        )
        #expect(try #require(read) == "Stereo Output")
    }

    /// The send button sits beside the output slot and its help mentions routing too. If the reader
    /// matched on anything looser than the output-slot phrase it would return "send button" as a
    /// destination — a wrong answer, which is worse than no answer.
    @Test("the send button is never mistaken for an output")
    func sendButtonIsNotAnOutput() {
        let builder = FakeAXRuntimeBuilder()
        let element = strip(builder, id: 29_200, outputHelp: nil, outputDescription: nil)
        let read = AXLogicProElements.outputSlotDestination(
            in: element, runtime: builder.makeAXRuntime()
        )
        #expect(read == nil)
    }

    /// A slot that was found but names nothing reads the same as no slot at all. "Found it and it is
    /// blank" is a gap in the read, not a track routed nowhere, and the two must not collapse.
    @Test("an output slot with no description reports nothing rather than an empty destination")
    func blankSlotIsNotAnEmptyRoute() {
        let builder = FakeAXRuntimeBuilder()
        let element = strip(
            builder, id: 29_300,
            outputHelp: "Output slot. Click and hold to choose the channel strip output.",
            outputDescription: ""
        )
        let read = AXLogicProElements.outputSlotDestination(
            in: element, runtime: builder.makeAXRuntime()
        )
        #expect(read == nil)
    }

    /// Only the English help string is measured. A Logic in another language must yield nothing —
    /// the caller then sees an absent output rather than a wrong one, and the variants list grows
    /// when a locale is observed, not when one is translated.
    @Test("an unmeasured locale yields no output rather than a guess")
    func unmeasuredLocaleYieldsNothing() {
        let builder = FakeAXRuntimeBuilder()
        let element = strip(
            builder, id: 29_400,
            outputHelp: "출력 슬롯. 클릭한 상태를 유지하여 채널 스트립 출력을 선택하십시오.",
            outputDescription: "스테레오 출력"
        )
        let read = AXLogicProElements.outputSlotDestination(
            in: element, runtime: builder.makeAXRuntime()
        )
        #expect(read == nil)
    }

    /// `sends` was `[SendState] = []`, so every strip of every project serialised `"sends": []` while
    /// nothing had ever populated it. A consumer read that as "this strip has no sends"; the truth
    /// was "nobody looked". An absent key is how the two are told apart.
    @Test("an unread send list is absent from the wire, not empty on it")
    func unreadSendsAreAbsent() throws {
        var state = ChannelStripState(trackIndex: 0)
        state.output = "Stereo Output"
        let wire = String(data: try JSONEncoder().encode(state), encoding: .utf8) ?? ""
        #expect(!wire.contains("\"sends\""))
        #expect(wire.contains("\"output\":\"Stereo Output\""))

        // And when a send list IS read, it must reach the wire — including an empty one, which then
        // genuinely means "looked, and there are none".
        var read = ChannelStripState(trackIndex: 1)
        read.sends = []
        let readWire = String(data: try JSONEncoder().encode(read), encoding: .utf8) ?? ""
        #expect(readWire.contains("\"sends\":[]"))
    }

    /// The wiring line itself, exercised through `defaultGetMixerState`.
    ///
    /// The other tests here call the reader directly, so deleting
    /// `state.output = AXLogicProElements.outputSlotDestination(…)` from the mixer readback left the
    /// whole suite green — the only thing pinning that line was a live run. Found by a blind review
    /// of this slice, which is exactly the hole such a review is for.
    @Test("the mixer readback itself carries the output it read")
    func defaultGetMixerStatePopulatesOutput() throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = makeLiveDumpStrip(builder, id: 29_600)
        let slot = builder.element(29_690)
        builder.setAttribute(slot, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(slot, kAXHelpAttribute as String,
                             "Output slot. Click and hold to choose the channel strip output.")
        builder.setAttribute(slot, kAXDescriptionAttribute as String, "Stereo Output")
        builder.setChildren(strip, AXHelpers.getChildren(strip, runtime: builder.makeAXRuntime()) + [slot])

        let fixture = make123MixerFixture(stripCount: 3, firstStrip: strip, builder: builder)
        let result = AccessibilityChannel.defaultGetMixerState(runtime: fixture.runtime)
        let json = result.message
        let strips = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        let first = try #require(strips.first)
        #expect(try #require(first["output"] as? String) == "Stereo Output")
    }

    /// The whole point of the change: the field stops being permanently null.
    @Test("the mixer readback carries the output it read")
    func mixerStateCarriesOutput() throws {
        let builder = FakeAXRuntimeBuilder()
        let element = strip(
            builder, id: 29_500,
            outputHelp: "Output slot. Click and hold to choose the channel strip output.",
            outputDescription: "Bus 3"
        )
        var state = ChannelStripState(trackIndex: 0)
        state.output = AXLogicProElements.outputSlotDestination(
            in: element, runtime: builder.makeAXRuntime()
        )
        let wire = String(data: try JSONEncoder().encode(state), encoding: .utf8) ?? ""
        #expect(try #require(state.output) == "Bus 3")
        #expect(wire.contains("\"output\":\"Bus 3\""))
    }
}
