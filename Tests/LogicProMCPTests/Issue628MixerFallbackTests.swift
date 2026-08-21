@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #628: `findVolumeFader` and `findPanControl` fall back to **position** when no slider carries a
/// matching description — `sliders.first` and `sliders[1]`. `sliders[1]` is this issue's sentence
/// written as an index.
///
/// Measured 2026-08-21 on Logic 12.3 with the Mixer open: two sliders in a strip, and the
/// description matches exactly one, so **neither fallback is reached**. That is the difference
/// between a fallback existing and a fallback firing, and it is why this change instruments the
/// branch rather than removing it — a path nobody has seen fire is not a path known to be dead.
///
/// These cases pin the selection either way, so that instrumenting could not quietly move which
/// element comes back.
@Suite("Issue #628 — the mixer strip's positional fallbacks")
struct Issue628MixerFallbackTests {

    /// A strip with `count` sliders. `describedIndex` gets the description; -1 gives none, which is
    /// what sends both functions to their index.
    private func strip(
        _ b: FakeAXRuntimeBuilder, base: Int, count: Int, describedIndex: Int, description: String
    ) -> (AXUIElement, [AXUIElement]) {
        let node = b.element(base)
        var sliders: [AXUIElement] = []
        for i in 0..<count {
            let slider = b.element(base + 1 + i)
            b.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
            b.setAttribute(slider, kAXDescriptionAttribute as String,
                           i == describedIndex ? description : "")
            sliders.append(slider)
        }
        b.setChildren(node, sliders)
        return (node, sliders)
    }

    @Test("a described volume fader is returned, and the index is not consulted")
    func describedFaderWins() throws {
        let b = FakeAXRuntimeBuilder()
        let (node, sliders) = strip(b, base: 6280, count: 2, describedIndex: 1, description: "Volume")
        let found = try #require(AXLogicProElements.findVolumeFader(
            in: node, runtime: b.makeAXRuntime()))
        // Position 1, not position 0 — so the answer came from the description, not the index.
        #expect(CFEqual(found, sliders[1]))
    }

    /// The branch this change makes visible. With no description the answer is `sliders[0]`, chosen
    /// for no reason beyond tree order.
    @Test("no described fader falls back to position 0, and the element is unchanged by instrumenting it")
    func faderFallsBackToIndexZero() throws {
        let b = FakeAXRuntimeBuilder()
        let (node, sliders) = strip(b, base: 6290, count: 2, describedIndex: -1, description: "Volume")
        let found = try #require(AXLogicProElements.findVolumeFader(
            in: node, runtime: b.makeAXRuntime()))
        #expect(CFEqual(found, sliders[0]))
    }

    @Test("a described pan control is returned, and the index is not consulted")
    func describedPanWins() throws {
        let b = FakeAXRuntimeBuilder()
        // Described at position 0, which is NOT the index the fallback would pick — so a pass here
        // cannot be the fallback accidentally agreeing.
        let (node, sliders) = strip(b, base: 6300, count: 3, describedIndex: 0, description: "Pan")
        let found = try #require(AXLogicProElements.findPanControl(
            in: node, runtime: b.makeAXRuntime()))
        #expect(CFEqual(found, sliders[0]))
    }

    @Test("no described pan control falls back to position 1")
    func panFallsBackToIndexOne() throws {
        let b = FakeAXRuntimeBuilder()
        let (node, sliders) = strip(b, base: 6310, count: 3, describedIndex: -1, description: "Pan")
        let found = try #require(AXLogicProElements.findPanControl(
            in: node, runtime: b.makeAXRuntime()))
        #expect(CFEqual(found, sliders[1]))
    }

    /// One slider and no description: the pan fallback wants index 1 and there is none. Nil is the
    /// honest answer, and it must not become `sliders[0]` — a strip with a single slider has a
    /// volume fader, not a pan control.
    @Test("one slider and no description returns nil for pan rather than the only slider")
    func panRefusesWhenThereIsNoSecondSlider() throws {
        let b = FakeAXRuntimeBuilder()
        let (node, _) = strip(b, base: 6320, count: 1, describedIndex: -1, description: "Pan")
        #expect(AXLogicProElements.findPanControl(in: node, runtime: b.makeAXRuntime()) == nil)
    }

    @Test("no sliders at all is nil from both, not an index into an empty list")
    func emptyStrip() throws {
        let b = FakeAXRuntimeBuilder()
        let (node, _) = strip(b, base: 6330, count: 0, describedIndex: -1, description: "Volume")
        let runtime = b.makeAXRuntime()
        #expect(AXLogicProElements.findVolumeFader(in: node, runtime: runtime) == nil)
        #expect(AXLogicProElements.findPanControl(in: node, runtime: runtime) == nil)
    }
}
