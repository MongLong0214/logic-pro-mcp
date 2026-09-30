@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// Real selector/helper over a fake AX tree; no host or actuator is involved.
@Suite("Header pan elimination evidence")
struct Issue290HeaderPanEvidenceTests {
    private func header(_ descriptions: [String]) -> (AXUIElement, [AXUIElement], AXHelpers.Runtime) {
        let builder = FakeAXRuntimeBuilder()
        let header = builder.element(29080)
        var sliders: [AXUIElement] = []
        for (index, description) in descriptions.enumerated() {
            let slider = builder.element(29081 + index)
            builder.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
            builder.setAttribute(slider, kAXDescriptionAttribute as String, description)
            sliders.append(slider)
        }
        builder.setChildren(header, sliders)
        return (header, sliders, builder.makeAXRuntime())
    }

    @Test func absentVolumeIdentityCannotMakeTheFirstSliderPan() {
        let (header, _, runtime) = header(["", ""])
        #expect(AXLogicProElements.findVolumeFader(in: header, runtime: runtime) == nil)
        #expect(AXLogicProElements.findPanControlInHeader(header, runtime: runtime) == nil)
    }

    @Test func aSingleUnidentifiedSliderIsNotPanByPosition() {
        let (header, _, runtime) = header([""])
        #expect(AXLogicProElements.findPanControlInHeader(header, runtime: runtime) == nil)
    }

    @Test func extraUnidentifiedSlidersDoNotHaveAUniqueEliminationResult() throws {
        let (header, sliders, runtime) = header(["Volume", "", ""])
        let volume = try #require(AXLogicProElements.findVolumeFader(in: header, runtime: runtime))
        #expect(CFEqual(volume, sliders[0]))
        #expect(AXLogicProElements.findPanControlInHeader(header, runtime: runtime) == nil)
    }

    @Test func ambiguousVolumeIdentityCannotBeOverriddenByPanFallback() {
        let (header, _, runtime) = header(["Volume", "Volume"])
        #expect(AXLogicProElements.findVolumeFader(in: header, runtime: runtime) == nil)
        #expect(AXLogicProElements.findPanControlInHeader(header, runtime: runtime) == nil)
    }

    @Test func twoSlidersWithUniqueVolumeStillResolveTheOtherControl() throws {
        let (header, sliders, runtime) = header(["", "Volume"])
        let found = try #require(AXLogicProElements.findPanControlInHeader(header, runtime: runtime))
        #expect(CFEqual(found, sliders[0]))
        #expect(!CFEqual(found, sliders[1]))
    }

    @Test func aNamedPanStillWinsAmongExtraSliders() throws {
        let (header, sliders, runtime) = header(["", "Volume", "Pan"])
        let found = try #require(AXLogicProElements.findPanControlInHeader(header, runtime: runtime))
        #expect(CFEqual(found, sliders[2]))
    }

    /// A header holding volume slider A beside a group that holds slider B. With `flaky`, the
    /// group answers its children once and then answers empty, so a second walk of the header
    /// sees a different inventory than the first.
    private func nestedHeader(
        second description: String,
        flaky: Bool
    ) -> (header: AXUIElement, a: AXUIElement, b: AXUIElement, groupReads: GroupReadCounter, runtime: AXHelpers.Runtime) {
        let builder = FakeAXRuntimeBuilder()
        let header = builder.element(29090)
        let a = builder.element(29091)
        let group = builder.element(29092)
        let b = builder.element(29093)
        for (slider, label) in [(a, "Volume"), (b, description)] {
            builder.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
            builder.setAttribute(slider, kAXDescriptionAttribute as String, label)
        }
        builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setChildren(header, [a, group])
        builder.setChildren(group, [b])
        let groupReads = GroupReadCounter()
        let runtime = builder.makeAXRuntime(
            childrenHandler: { element in
                guard CFEqual(element, group) else { return nil }
                let read = groupReads.next()
                return (flaky && read > 1) ? [] : [b]
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        return (header, a, b, groupReads, runtime)
    }

    @Test func aSubtreeThatReadsEmptyTheSecondTimeCannotTurnAVolumeSliderIntoPan() {
        // Control, same fixture with the group stable: both sliders ARE volume identities, so the
        // header has no unique volume and elimination has nothing to eliminate against.
        let stable = nestedHeader(second: "Volume", flaky: false)
        #expect(AXLogicProElements.findVolumeFader(in: stable.header, runtime: stable.runtime) == nil)
        #expect(AXLogicProElements.findPanControlInHeader(stable.header, runtime: stable.runtime) == nil)

        let flaky = nestedHeader(second: "Volume", flaky: true)
        let found = AXLogicProElements.findPanControlInHeader(flaky.header, runtime: flaky.runtime)
        // The seam fired: the group was read, so the first walk saw B and any later walk saw none.
        #expect(flaky.groupReads.count >= 1)
        #expect(found == nil)
        if let found {
            #expect(!CFEqual(found, flaky.b), "a volume slider came back as pan")
            #expect(!CFEqual(found, flaky.a), "a volume slider came back as pan")
        }
    }

    @Test func aNestedUnnamedSliderIsStillPanByEliminationWhetherOrNotItsGroupRereads() throws {
        // Positive controls for the refusal above: the same nesting with B carrying no volume
        // identity is the two-slider elimination case, and it still resolves B, flaky group or not.
        for flakyGroup in [false, true] {
            let fixture = nestedHeader(second: "", flaky: flakyGroup)
            let found = try #require(
                AXLogicProElements.findPanControlInHeader(fixture.header, runtime: fixture.runtime))
            #expect(CFEqual(found, fixture.b))
            #expect(!CFEqual(found, fixture.a))
            #expect(fixture.groupReads.count >= 1)
        }
    }
}

private final class GroupReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    /// Records one read and answers its 1-based ordinal.
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return reads
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }
}
