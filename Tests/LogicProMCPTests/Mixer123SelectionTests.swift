@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// 12.3 / 12.2 mixer fixture builders live in Mixer123FixtureSupport.swift so the
// #234 honesty-gate tests (PluginGetInventoryTests) can reuse the same shapes.

@Suite("Mixer123SelectionTests")
struct Mixer123SelectionTests {
    @Test
    func test123MixerSelectsStripsContainerNotToolbar() {
        let fixture = make123MixerFixture(stripCount: 3)

        let mixer = AXLogicProElements.getMixerArea(runtime: fixture.runtime)

        #expect(mixer != nil)
        #expect(CFEqual(mixer!, fixture.layoutArea))
    }

    @Test(arguments: [1, 3, 8, 9, 12])
    func test123MixerSelectionIndependentOfStripCount(_ stripCount: Int) {
        let fixture = make123MixerFixture(stripCount: stripCount)

        let mixer = AXLogicProElements.getMixerArea(runtime: fixture.runtime)

        #expect(mixer != nil)
        #expect(CFEqual(mixer!, fixture.layoutArea), "strip count \(stripCount)")
    }

    @Test
    func test123ToolbarAloneYieldsNoMixer() {
        let fixture = make123MixerFixture(stripCount: 0, includeStripsContainer: false)

        #expect(AXLogicProElements.getMixerArea(runtime: fixture.runtime) == nil)
    }

    @Test
    func test122ShapeStillSelected() {
        let fixture = make122MixerFixture()

        let mixer = AXLogicProElements.getMixerArea(runtime: fixture.runtime)

        #expect(mixer != nil)
        #expect(CFEqual(mixer!, fixture.layoutArea))
    }

    @Test
    func test123KoreanLocaleSelection() {
        let fixture = make123MixerFixture(stripCount: 3, mixerDescription: "믹서")

        let mixer = AXLogicProElements.getMixerArea(runtime: fixture.runtime)

        #expect(mixer != nil)
        #expect(CFEqual(mixer!, fixture.layoutArea))
    }

    @Test
    func test123InspectorAreaStillExcluded() {
        let runtime = makeInspectorOnly123Runtime()

        #expect(AXLogicProElements.getMixerArea(runtime: runtime) == nil)
    }

    @Test
    func test123EnumerationEndToEnd() throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = makeLiveDumpStrip(builder, id: 500)
        let fixture = make123MixerFixture(stripCount: 3, firstStrip: strip, builder: builder)

        let mixer = try #require(AXLogicProElements.getMixerArea(runtime: fixture.runtime))
        let strips = try #require(AXLogicProElements.mixerChannelStrips(in: mixer, runtime: fixture.runtime.ax))
        #expect(strips.count == 3)
        let firstStrip = try #require(strips.first)
        #expect(CFEqual(firstStrip, strip))

        let slots = try #require(AXLogicProElements.audioPluginInsertSlots(in: firstStrip, runtime: fixture.runtime.ax))

        // The strip's one audio insert is the empty `audio plug-in` row; `E-Piano` above it is the
        // instrument slot (#234 NG2) and is not an insert.
        #expect(slots.count == 1)
        #expect(slots.map(\.index) == [0])
        let firstSlot = try #require(slots.first)
        #expect(firstSlot.readStatus == .empty)
        #expect(firstSlot.name == nil)
        #expect(!slots.contains { $0.name == "Gain" || $0.name == "E-Piano" })
    }
}
