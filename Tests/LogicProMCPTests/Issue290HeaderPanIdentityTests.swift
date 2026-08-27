@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #290 — the track-header pan slider is selected by identity, not by elimination.
///
/// `--probe-selection-census` measured `findPanControlInHeader` at **zero survivors of two
/// sliders** on Logic 12.x (ko): its predicate searched the children's `AXDescription` for
/// `headerPanHint`, and the pan slider has no `AXDescription` at all — nor an `AXIdentifier`, which
/// is absent from the element entirely. So the site fell through to "the slider that is not the
/// volume fader" on every header.
///
/// The strings below are transcribed from that live tree, not invented. A fixture written from
/// memory would pass while describing a UI Logic does not produce, which is the failure the census
/// itself exists to catch.
@Suite("Issue290HeaderPanIdentity")
struct Issue290HeaderPanIdentityTests {

    private static let panHelp = "패닝 노브 및 밸런스 노브. 트랙 신호를 스테레오 필드에 위치하려면 수직으로 드래그합니다."
    private static let volumeHelp = "볼륨 페이더. 트랙의 재생 볼륨을 설정합니다."

    /// A header holding `sliders` in tree order. Each tuple is (description, help, maxValue).
    private static func header(
        _ sliders: [(description: String?, help: String?, maxValue: Double?)]
    ) -> (element: AXUIElement, sliders: [AXUIElement], runtime: AXHelpers.Runtime) {
        let builder = FakeAXRuntimeBuilder()
        let header = builder.element(1)
        builder.setAttribute(header, kAXRoleAttribute as String, kAXGroupRole as String)

        var elements: [AXUIElement] = []
        for (offset, spec) in sliders.enumerated() {
            let slider = builder.element(offset + 2)
            builder.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
            if let description = spec.description {
                builder.setAttribute(slider, kAXDescriptionAttribute as String, description)
            }
            if let help = spec.help {
                builder.setAttribute(slider, kAXHelpAttribute as String, help)
            }
            if let maxValue = spec.maxValue {
                builder.setAttribute(slider, kAXMaxValueAttribute as String, maxValue)
            }
            elements.append(slider)
        }
        builder.setChildren(header, elements)
        return (header, elements, builder.makeAXRuntime())
    }

    @Test("the pan slider is found by its own help text, not by being the one left over")
    func identityRatherThanElimination() {
        // A third, nameless slider placed FIRST. Elimination returns "the first slider that is not
        // the volume fader", which is this one — so on the previous code this header resolves to
        // the wrong control while reporting nothing. Identity has to reach past it.
        let tree = Self.header([
            (description: nil, help: nil, maxValue: nil),                        // decoy, first
            (description: nil, help: Self.panHelp, maxValue: 127),               // pan
            (description: "볼륨", help: Self.volumeHelp, maxValue: 233),          // volume
        ])

        let found = AXLogicProElements.findPanControlInHeader(tree.element, runtime: tree.runtime)

        #expect(found != nil, "the header did not resolve at all")
        if let pan = found {
            #expect(CFEqual(pan, tree.sliders[1]), "resolved to a slider that never named itself")
            #expect(!CFEqual(pan, tree.sliders[0]), "resolved to the decoy — this is elimination")
        }
    }

    @Test("the volume fader is not mistaken for the pan control")
    func volumeIsNotPan() {
        let tree = Self.header([
            (description: nil, help: Self.panHelp, maxValue: 127),
            (description: "볼륨", help: Self.volumeHelp, maxValue: 233),
        ])

        let candidates = AXLogicProElements.headerPanSliderCandidates(
            among: tree.sliders, runtime: tree.runtime)

        // One, not both: the separation is the point. Two candidates here would mean the hint
        // matches the volume fader's text as well, and the count below is what would catch it.
        #expect(candidates.count == 1, "\(candidates.count) sliders claimed to be the pan control")
        if let only = candidates.first {
            #expect(CFEqual(only, tree.sliders[0]))
        }
    }

    @Test("two sliders that both name themselves pan are refused, not resolved to the first")
    func ambiguityRefuses() {
        let tree = Self.header([
            (description: nil, help: Self.panHelp, maxValue: 127),
            (description: nil, help: Self.panHelp, maxValue: 127),
            (description: "볼륨", help: Self.volumeHelp, maxValue: 233),
        ])

        // Returning tree.sliders[0] here is exactly what the #628 census exists to find: a choice
        // among equals, made silently. There is nothing left to tell these two apart, so the honest
        // answer is that the header did not resolve.
        #expect(AXLogicProElements.findPanControlInHeader(tree.element, runtime: tree.runtime) == nil)
    }

    @Test("the value range separates two candidates when the help text cannot")
    func valueRangeNarrows() {
        // Same ambiguity as above, except one of the two carries the volume fader's range. The pan
        // slider's AXMaxValue was measured at 127 against the volume fader's 233, and unlike the
        // help string that signature does not depend on locale.
        let tree = Self.header([
            (description: nil, help: Self.panHelp, maxValue: 233),
            (description: nil, help: Self.panHelp, maxValue: 127),
        ])

        let found = AXLogicProElements.findPanControlInHeader(tree.element, runtime: tree.runtime)
        #expect(found != nil)
        if let found {
            #expect(CFEqual(found, tree.sliders[1]), "narrowed to the slider with the wrong range")
        }
    }

    @Test("a header where nothing names itself still resolves by elimination")
    func eliminationSurvivesForUnmeasuredTrees() {
        // Only the Korean help string is measured. A locale whose help text carries none of the
        // hint's variants must be no worse off than before this change — it falls through to
        // elimination exactly as it did, rather than losing the control entirely.
        let tree = Self.header([
            (description: "볼륨", help: nil, maxValue: 233),
            (description: nil, help: nil, maxValue: 127),
        ])

        let found = AXLogicProElements.findPanControlInHeader(tree.element, runtime: tree.runtime)
        #expect(found != nil)
        if let found {
            #expect(CFEqual(found, tree.sliders[1]), "elimination stopped working")
        }
    }
}
