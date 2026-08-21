@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #628: `getTransportBar` gathers groups, narrows with `looksLikeTransportContainer`, and returns
/// the first survivor. Measured on Logic 12.3 — one project, one track — **thirty-seven gathered,
/// four survive**, and two of the four are the arrange area: the predicate accepts any container
/// holding two or more transport-keyword controls, and a track header holds a record-arm checkbox.
///
/// The element returned is unchanged by this work. What changed is that the count exists as a value
/// instead of only inside an `if let`, so a tree-order choice among several can say so.
///
/// These cases assert the SPLIT, not the predicate: that the candidate list is the same selection
/// the old `first(where:)` made, and that its size is what a caller would have to look at to know
/// whether the choice was forced or free.
@Suite("Issue #628 — the transport scan's candidate list is a value")
struct Issue628TransportAmbiguityTests {

    /// Two containers that both satisfy the predicate by the control-keyword path: each holds a
    /// `record` and a `play` control, which is the two-hit rule the live tree also trips.
    private func transportish(_ b: FakeAXRuntimeBuilder, _ id: Int, labels: [String]) -> AXUIElement {
        let group = b.element(id)
        b.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        var kids: [AXUIElement] = []
        for (i, label) in labels.enumerated() {
            let control = b.element(id * 10 + i + 1)
            b.setAttribute(control, kAXRoleAttribute as String, kAXButtonRole as String)
            b.setAttribute(control, kAXDescriptionAttribute as String, label)
            kids.append(control)
        }
        b.setChildren(group, kids)
        return group
    }

    @Test("two containers that both satisfy the predicate are both candidates")
    func twoSurvivorsAreBothListed() throws {
        let b = FakeAXRuntimeBuilder()
        let first = transportish(b, 6281, labels: ["Play", "Record"])
        let second = transportish(b, 6282, labels: ["Play", "Record"])
        let runtime = b.makeLogicRuntime()

        let candidates = AXLogicProElements.transportContainerCandidates(
            among: [first, second], runtime: runtime)
        #expect(candidates.count == 2)

        // The chosen element is the first survivor — unchanged from `groups.first(where:)`.
        let chosen = try #require(candidates.first)
        #expect(CFEqual(chosen, first))
    }

    /// The count is what distinguishes a forced choice from a free one. A single survivor and four
    /// survivors both return something; only the count says which happened, and that is the whole
    /// sentence of this issue.
    @Test("one survivor and several survivors are told apart by the count, not by the result")
    func theCountIsWhatDistinguishes() throws {
        let b = FakeAXRuntimeBuilder()
        let transport = transportish(b, 6283, labels: ["Play", "Record"])
        let unrelated = b.element(6284)
        b.setAttribute(unrelated, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setChildren(unrelated, [])
        let runtime = b.makeLogicRuntime()

        let one = AXLogicProElements.transportContainerCandidates(
            among: [transport, unrelated], runtime: runtime)
        #expect(one.count == 1)

        let several = AXLogicProElements.transportContainerCandidates(
            among: [transport, transportish(b, 6285, labels: ["Play", "Record"])], runtime: runtime)
        #expect(several.count == 2)

        // Both return a non-nil first element. Without the count they are indistinguishable, which
        // is exactly the state this site was in.
        #expect(one.first != nil)
        #expect(several.first != nil)
    }

    @Test("no survivor is an empty list, not a nil element hiding a count of zero")
    func noSurvivor() throws {
        let b = FakeAXRuntimeBuilder()
        let empty = b.element(6286)
        b.setAttribute(empty, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setChildren(empty, [])

        let candidates = AXLogicProElements.transportContainerCandidates(
            among: [empty], runtime: b.makeLogicRuntime())
        #expect(candidates.isEmpty)
        #expect(candidates.first == nil)
    }

    /// The extraction must not change the selection. If `transportContainerCandidates(among:).first`
    /// ever differs from what `first(where: looksLikeTransportContainer)` returned, this refactor
    /// moved an element rather than exposing a number.
    @Test("the split preserves which element is chosen")
    func splitPreservesTheChoice() throws {
        let b = FakeAXRuntimeBuilder()
        let notTransport = b.element(6287)
        b.setAttribute(notTransport, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setChildren(notTransport, [])
        let transport = transportish(b, 6288, labels: ["Play", "Record"])
        let runtime = b.makeLogicRuntime()
        let groups = [notTransport, transport]

        let viaSplit = AXLogicProElements.transportContainerCandidates(
            among: groups, runtime: runtime).first
        let viaOriginal = groups.first {
            AXLogicProElements.looksLikeTransportContainer($0, runtime: runtime.ax)
        }
        let a = try #require(viaSplit)
        let c = try #require(viaOriginal)
        #expect(CFEqual(a, c))
    }
}
