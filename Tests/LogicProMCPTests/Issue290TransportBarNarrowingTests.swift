@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #290 — `getTransportBar`'s keyword scan narrows instead of taking the first in tree order.
///
/// The scan over-accepts: it takes any container holding two or more transport-keyword controls,
/// and the arrange area qualifies on substrings of labels that are not transport controls — "play"
/// inside "Catch Playhead", "loop" inside "Show/Hide Live Loops Grid". Measured at five survivors
/// on this machine. The site used to return `survivors.first`.
///
/// Which one it SHOULD return was recorded as a contract question, and the evidence answers it:
/// `getControlBar()` is tried first, every caller writes one or the other, the census measures both
/// paths returning the same element, and Logic labels the group `Control Bar` / `컨트롤 막대`. So
/// the scan narrows by the discriminators the control-bar route already uses, and refuses when they
/// leave more than one.
@Suite("Issue290TransportBarNarrowing")
struct Issue290TransportBarNarrowingTests {

    /// `groups` is (description, holdsACheckbox).
    private static func tree(
        _ groups: [(description: String?, holdsCheckbox: Bool)]
    ) -> (elements: [AXUIElement], runtime: AXHelpers.Runtime) {
        let builder = FakeAXRuntimeBuilder()
        var out: [AXUIElement] = []
        var next = 100
        for (offset, spec) in groups.enumerated() {
            let group = builder.element(offset + 1)
            builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
            if let description = spec.description {
                builder.setAttribute(group, kAXDescriptionAttribute as String, description)
            }
            if spec.holdsCheckbox {
                // Named `Play`, because capability here is `transportControlKeywordHits` and a
                // nameless checkbox is not a transport control. The first version of this fixture
                // set only the role, and the group it built held a control by the letter of the
                // helper's parameter and by nothing the product would recognise.
                let box = builder.element(next); next += 1
                builder.setAttribute(box, kAXRoleAttribute as String, kAXCheckBoxRole as String)
                builder.setAttribute(box, kAXDescriptionAttribute as String, "Play")
                builder.setChildren(group, [box])
            }
            out.append(group)
        }
        return (out, builder.makeAXRuntime())
    }

    private static func finalists(
        _ groups: [(description: String?, holdsCheckbox: Bool)]
    ) -> (count: Int, index: Int?, elements: [AXUIElement]) {
        let t = Self.tree(groups)
        let picked = AXLogicProElements.transportContainerFinalists(among: t.elements, runtime: t.runtime)
        let index = picked.count == 1 ? t.elements.firstIndex(where: { CFEqual($0, picked[0]) }) : nil
        return (picked.count, index, picked)
    }

    @Test("a single survivor is returned untouched")
    func singleSurvivorUnchanged() {
        #expect(Self.finalists([(nil, false)]).count == 1)
    }

    @Test("the labelled bar that holds a control wins over unlabelled look-alikes")
    func labelAndControlWin() {
        // The measured shape: the arrange area qualifies on false friends and carries no
        // control-bar label; the real bar carries both.
        let r = Self.finalists([
            (description: "Tracks contents", holdsCheckbox: true),   // false friend, first in order
            (description: "Control Bar", holdsCheckbox: true),       // the real one
            (description: nil, holdsCheckbox: false),
        ])
        #expect(r.count == 1)
        #expect(r.index == 1, "took something other than the labelled bar")
    }

    @Test("the Korean label resolves the same way")
    func koreanLabel() {
        let r = Self.finalists([
            (description: "트랙 콘텐츠", holdsCheckbox: true),
            (description: "컨트롤 막대", holdsCheckbox: true),
        ])
        #expect(r.count == 1)
        #expect(r.index == 1)
    }

    @Test("with two labelled bars, holding a control separates them")
    func holdingAControlSeparatesTwoLabelled() {
        // The measured #628 shape: two groups both described "Control Bar", one with twenty direct
        // checkboxes and one with none.
        let r = Self.finalists([
            (description: "Control Bar", holdsCheckbox: false),
            (description: "Control Bar", holdsCheckbox: true),
        ])
        #expect(r.count == 1)
        #expect(r.index == 1, "took the bar that holds no control")
    }

    @Test("a lone labelled bar holding no control still beats tree order")
    func loneLabelledWithoutControls() {
        let r = Self.finalists([
            (description: nil, holdsCheckbox: false),
            (description: "Control Bar", holdsCheckbox: false),
        ])
        #expect(r.count == 1)
        #expect(r.index == 1)
    }

    @Test("two indistinguishable candidates are refused, not resolved to the first")
    func indistinguishableIsRefused() {
        // This is the assertion the change is about. Returning index 0 here is what the site did,
        // and it is the wrong-target behaviour ADR-007's version policy names.
        #expect(Self.finalists([
            (description: "Control Bar", holdsCheckbox: true),
            (description: "Control Bar", holdsCheckbox: true),
        ]).count != 1)
    }

    @Test("the label must match the whole description, not appear inside one")
    func labelIsNotASubstringMatch() {
        // `.exactStrict`, the mode `getControlBar` uses. A containment match would let a group
        // called "Hide Control Bar" be taken for the bar — the same false-friend class the keyword
        // scan already fails on, and the reason this narrowing exists.
        let r = Self.finalists([
            (description: "Hide Control Bar", holdsCheckbox: true),
            (description: "Control Bar", holdsCheckbox: true),
        ])
        #expect(r.count == 1)
        #expect(r.index == 1, "a description merely containing the label was accepted")
    }
}
