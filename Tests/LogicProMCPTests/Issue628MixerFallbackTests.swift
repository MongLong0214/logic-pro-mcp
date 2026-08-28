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

    /// The branch this case was written to make visible, now closed.
    ///
    /// It used to assert `sliders[0]` — chosen for no reason beyond tree order — and that was the
    /// honest record of what the code did. #290's atlas adoption removes the positional fallback:
    /// a strip whose sliders name nothing is a tree this code has never been measured against, and
    /// answering with an index there is the wrong-target behaviour ADR-007 exists to stop.
    ///
    /// `--probe-selection-census` measures a real strip at two sliders with ONE surviving the
    /// discriminator, so this shape is not what Logic produces — which is why refusing costs
    /// nothing measured and buys the guarantee.
    @Test("no named fader is refused rather than answered with position 0")
    func faderWithNoNameIsRefused() {
        let b = FakeAXRuntimeBuilder()
        let (node, _) = strip(b, base: 6290, count: 2, describedIndex: -1, description: "Volume")
        #expect(AXLogicProElements.findVolumeFader(in: node, runtime: b.makeAXRuntime()) == nil)
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

    /// The duplicate-description branch this change added. Every other fixture here has exactly
    /// ONE described slider, which means `described.first` and `described.last` are the same
    /// element and no case could tell a tree-order choice from a forced one -- a reviewer noted
    /// that swapping to `.last` would have kept the suite green.
    /// Inverted with #290's atlas adoption. It asserted `sliders[0]` — the reviewer's point stands,
    /// and it was the honest record of a tree-order choice being made. The choice is gone: the
    /// selector's `AmbiguityPolicy` is `failClosed`, so two equally-qualified candidates are a
    /// refusal rather than a pick, which is what ADR-007 requires of anything a write depends on.
    @Test("two sliders described as the volume fader are refused, not resolved to the first")
    func twoDescribedFadersAreRefused() {
        let b = FakeAXRuntimeBuilder()
        let node = b.element(6400)
        var sliders: [AXUIElement] = []
        for i in 0..<2 {
            let slider = b.element(6401 + i)
            b.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
            b.setAttribute(slider, kAXDescriptionAttribute as String, "Volume")
            sliders.append(slider)
        }
        b.setChildren(node, sliders)
        #expect(AXLogicProElements.findVolumeFader(in: node, runtime: b.makeAXRuntime()) == nil)
    }

    /// Same for pan, and it is not the same assertion: pan's FALLBACK is `sliders[1]`, so a
    /// description-matched answer at index 0 is the only result that distinguishes the two paths.
    @Test("two sliders described as pan return the FIRST, not the fallback's index 1")
    func twoDescribedPansReturnTheFirst() throws {
        let b = FakeAXRuntimeBuilder()
        let node = b.element(6410)
        var sliders: [AXUIElement] = []
        for i in 0..<2 {
            let slider = b.element(6411 + i)
            b.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
            b.setAttribute(slider, kAXDescriptionAttribute as String, "Pan")
            sliders.append(slider)
        }
        b.setChildren(node, sliders)
        let found = try #require(AXLogicProElements.findPanControl(
            in: node, runtime: b.makeAXRuntime()))
        #expect(CFEqual(found, sliders[0]))
        #expect(!CFEqual(found, sliders[1]))
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
