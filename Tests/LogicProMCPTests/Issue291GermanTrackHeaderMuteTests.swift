import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #291: a German Logic 12.3 describes the track header's Mute checkbox `Stumm`, the German value
/// of `Localizable.strings` key `Mute`. The Mixer strip's Mute is `Ton aus`, the value of
/// `Mute#acc`, and that row was the only one `trackMuteButton` was derived from. Read live on
/// 2026-09-27 with the four header checkboxes below on every track; with only `Ton aus` in the
/// set, the header-mute lookup found none of them.
///
/// Mutation that turns this suite red: remove `Stumm` from `AXLocalePolicy.trackMuteButton`'s
/// variants. Both the locator that writes a Mute and the extractor that reads `isMuted` then
/// match nothing in this header.
@Suite("Issue291 German track-header Mute")
struct Issue291GermanTrackHeaderMuteTests {
    private struct Header {
        let builder: FakeAXRuntimeBuilder
        let header: AXUIElement
        let mute: AXUIElement
    }

    /// A header shaped like the German one read live: four AXCheckBox children, described as
    /// Logic describes them, with the Mute ON so a read of it is distinguishable from no read.
    private func makeGermanHeader() -> Header {
        let b = FakeAXRuntimeBuilder()
        let header = b.element(1)
        b.setAttribute(header, kAXRoleAttribute, "AXLayoutItem")
        func checkbox(_ id: Int, _ desc: String, _ value: Int) -> AXUIElement {
            let e = b.element(id)
            b.setAttribute(e, kAXRoleAttribute, "AXCheckBox")
            b.setAttribute(e, kAXDescriptionAttribute, desc)
            b.setAttribute(e, kAXValueAttribute, value)
            return e
        }
        let mute = checkbox(2, "Stumm", 1)
        let solo = checkbox(3, "Solo", 0)
        let arm = checkbox(4, "Aufnahme aktivieren", 0)
        let input = checkbox(5, "Input-Monitoring", 0)
        b.setChildren(header, [mute, solo, arm, input])
        return Header(builder: b, header: header, mute: mute)
    }

    @Test("the header-mute lookup finds the checkbox described Stumm")
    func locatorFindsStumm() throws {
        let h = makeGermanHeader()
        let found = AXLogicProElements.findTrackToggleControl(
            in: h.header, labels: AXLocalePolicy.trackMuteButton.labels, legacyTitle: "M",
            runtime: h.builder.makeLogicRuntime())
        let mute = try #require(found)
        #expect(CFEqual(mute, h.mute))
    }

    @Test("the track read takes isMuted from the checkbox described Stumm")
    func extractorReadsStumm() throws {
        let h = makeGermanHeader()
        let track = AXValueExtractors.extractTrackState(
            from: h.header, index: 0, runtime: h.builder.makeAXRuntime())
        let trackMuted = try #require(track.isMuted)
        #expect(trackMuted)
    }
}
