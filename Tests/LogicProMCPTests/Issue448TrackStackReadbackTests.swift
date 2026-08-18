@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// Track stacks are readable from the header, which #448 assumed they were not.
///
/// Measured on Logic Pro 12.3, 2026-08-18. Every track header is an `AXLayoutItem` under
/// `AXGroup[Tracks header]`; exactly one of 21 carried an `AXDisclosureTriangle`, and Logic's own
/// help text on that element says what it is:
///
///     "Track stack disclosure arrow. Show or hide subtracks. Use the controls on the main track to
///      control all subtracks in the track stack."
///
/// Disclosed and re-collapsed through Logic's own Edit menu, the arrangement moved 21 -> 44 -> 21
/// headers with `AXValue` tracking 0 -> 1 -> 0 and both published fields following. So this is a
/// readback, not an inference.
///
/// The arrow itself cannot be driven. `AXPress` on it answers `.success` and moves nothing — both
/// through System Events and through a direct in-process `AXUIElementPerformAction` — and `AXValue`
/// reports `settable: false`. An earlier draft of this file asserted the opposite; it was wrong, and
/// the reason it survived a first reading is that the return code said the press had worked.
@Suite("#448 a track header says whether it is a stack, and whether it is collapsed")
struct Issue448TrackStackReadbackTests {
    /// `#expect(someBoolOptional == nil)` is a DEAD assertion in this toolchain — measured
    /// 2026-08-18: it passes for `.some(false)` and for `.some(true)` alike, while the same
    /// comparison on `String?` and `Int?` fails correctly. `Scripts/ci-forbid-dead-expect.sh` says
    /// so in prose and has no pattern for it, so nothing stopped the first version of this suite
    /// from using it — and two mutations of the code under test passed against it.
    ///
    /// Absence is therefore projected to a plain `Bool` before it is asserted.
    private func stackHeaderWasReported(_ state: (isStackHeader: Bool?, collapsed: Bool?)) -> Bool {
        state.isStackHeader != nil
    }

    private func collapsedWasReported(_ state: (isStackHeader: Bool?, collapsed: Bool?)) -> Bool {
        state.collapsed != nil
    }

    private func header(
        _ builder: FakeAXRuntimeBuilder,
        id: Int,
        disclosure: Int?
    ) -> AXUIElement {
        let head = builder.element(id)
        builder.setAttribute(head, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        var children: [AXUIElement] = []
        let mute = builder.element(id + 1)
        builder.setAttribute(mute, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(mute, kAXDescriptionAttribute as String, "Mute")
        children.append(mute)
        if let disclosure {
            let triangle = builder.element(id + 2)
            builder.setAttribute(triangle, kAXRoleAttribute as String, kAXDisclosureTriangleRole as String)
            builder.setAttribute(triangle, kAXValueAttribute as String, NSNumber(value: disclosure))
            children.append(triangle)
        }
        builder.setChildren(head, children)
        return head
    }

    @Test("a header with no disclosure arrow is not a stack")
    func plainHeaderIsNotAStack() throws {
        let builder = FakeAXRuntimeBuilder()
        let state = AXValueExtractors.extractTrackStackState(
            from: header(builder, id: 44_000, disclosure: nil),
            runtime: builder.makeAXRuntime()
        )
        let answered = try #require(state.isStackHeader)
        #expect(!answered)
        // Not a stack, so it has no collapsed state to report — `false` here would invent one.
        #expect(!collapsedWasReported(state))
    }

    @Test("a collapsed stack reads 0, an expanded one reads 1")
    func stackCollapsedStateIsRead() throws {
        let builder = FakeAXRuntimeBuilder()
        let collapsed = AXValueExtractors.extractTrackStackState(
            from: header(builder, id: 44_100, disclosure: 0),
            runtime: builder.makeAXRuntime()
        )
        #expect(try #require(collapsed.isStackHeader))
        #expect(try #require(collapsed.collapsed))

        let expanded = AXValueExtractors.extractTrackStackState(
            from: header(builder, id: 44_200, disclosure: 1),
            runtime: builder.makeAXRuntime()
        )
        #expect(try #require(expanded.isStackHeader))
        #expect(!(try #require(expanded.collapsed)))
    }

    /// A header that will not answer is not a header that said "no".
    ///
    /// Returning `false` for an unreadable children list would publish an absence as a claim, which
    /// is the defect class this repository spends most of its guards on.
    @Test("an unreadable header claims nothing")
    func unreadableHeaderClaimsNothing() {
        let builder = FakeAXRuntimeBuilder()
        let head = builder.element(44_300)
        builder.setAttribute(head, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        let runtime = AXHelpers.Runtime(
            axApp: { _ in head },
            attributeValue: { _, _ in nil },
            setAttributeValue: { _, _, _ in false },
            children: { _ in [] },
            performAction: { _, _ in false },
            childCount: { _ in nil },
            childrenResult: { _ in
                .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            }
        )
        let state = AXValueExtractors.extractTrackStackState(from: head, runtime: runtime)
        #expect(!stackHeaderWasReported(state))
        #expect(!collapsedWasReported(state))
    }

    /// A disclosure arrow present but whose value will not read: it IS a stack, and its collapsed
    /// state is unknown. Reporting `collapsed: false` there would be a guess dressed as a reading.
    @Test("a stack whose value is unreadable reports the half it knows")
    func unreadableValueKeepsTheHalfItKnows() throws {
        let builder = FakeAXRuntimeBuilder()
        let head = builder.element(44_400)
        builder.setAttribute(head, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        let triangle = builder.element(44_401)
        builder.setAttribute(triangle, kAXRoleAttribute as String, kAXDisclosureTriangleRole as String)
        builder.setChildren(head, [triangle])

        let state = AXValueExtractors.extractTrackStackState(
            from: head, runtime: builder.makeAXRuntime()
        )
        #expect(try #require(state.isStackHeader))
        #expect(!collapsedWasReported(state))
    }

    /// A child whose ROLE will not read is a child that has not been ruled out.
    ///
    /// Found by a blind review of the first version, which used `AXHelpers.getRole($0) ?? ""` here.
    /// That reader collapses every AX failure into `nil`, so a header whose children answered but
    /// whose children's identities did not went out as `is_stack_header: false` — an absence
    /// published as a claim, in the one function written to refuse exactly that one level up.
    @Test("a header with an unidentifiable child does not get called 'not a stack'")
    func unidentifiableChildBlocksTheNegativeClaim() {
        let builder = FakeAXRuntimeBuilder()
        let head = builder.element(44_500)
        builder.setAttribute(head, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        let mute = builder.element(44_501)
        builder.setAttribute(mute, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        let mystery = builder.element(44_502)
        builder.setChildren(head, [mute, mystery])
        let mysteryID = builder.elementID(mystery)

        let runtime = builder.makeAXRuntime(
            attributeValueResultHandler: { element, attribute in
                guard builder.elementID(element) == mysteryID,
                      attribute == (kAXRoleAttribute as String) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        let state = AXValueExtractors.extractTrackStackState(from: head, runtime: runtime)
        #expect(!stackHeaderWasReported(state))
        #expect(!collapsedWasReported(state))
    }

    /// The same unreadable child must NOT suppress a positive finding. An arrow that was seen is
    /// seen regardless of what else on the header would not answer — a guard that fired here too
    /// would trade one false claim for a different one.
    @Test("an unidentifiable child does not suppress an arrow that was found")
    func unidentifiableChildDoesNotHideTheArrow() throws {
        let builder = FakeAXRuntimeBuilder()
        let head = builder.element(44_600)
        builder.setAttribute(head, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        let triangle = builder.element(44_601)
        builder.setAttribute(triangle, kAXRoleAttribute as String, kAXDisclosureTriangleRole as String)
        builder.setAttribute(triangle, kAXValueAttribute as String, NSNumber(value: 0))
        let mystery = builder.element(44_602)
        builder.setChildren(head, [triangle, mystery])
        let mysteryID = builder.elementID(mystery)

        let runtime = builder.makeAXRuntime(
            attributeValueResultHandler: { element, attribute in
                guard builder.elementID(element) == mysteryID,
                      attribute == (kAXRoleAttribute as String) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        let state = AXValueExtractors.extractTrackStackState(from: head, runtime: runtime)
        #expect(try #require(state.isStackHeader))
        #expect(try #require(state.collapsed))
    }

    /// `AXValue` reads exactly 0 or exactly 1. Anything else is a value this reader has no
    /// interpretation for.
    ///
    /// The first version wrote `number.intValue == 0`, which publishes 2 and -1 as EXPANDED and
    /// truncates 0.9 to COLLAPSED. Neither is a reading; both are the arithmetic of a cast. Also
    /// found by blind review, which noticed the code disagreed with the comment above it.
    @Test("a disclosure value that is neither 0 nor 1 is not interpreted")
    func uninterpretableValueIsNotInterpreted() throws {
        let builder = FakeAXRuntimeBuilder()
        for (offset, raw) in [NSNumber(value: 2), NSNumber(value: -1), NSNumber(value: 0.9)].enumerated() {
            let head = builder.element(44_700 + offset * 10)
            builder.setAttribute(head, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            let triangle = builder.element(44_701 + offset * 10)
            builder.setAttribute(triangle, kAXRoleAttribute as String, kAXDisclosureTriangleRole as String)
            builder.setAttribute(triangle, kAXValueAttribute as String, raw)
            builder.setChildren(head, [triangle])

            let state = AXValueExtractors.extractTrackStackState(
                from: head, runtime: builder.makeAXRuntime()
            )
            #expect(try #require(state.isStackHeader))
            #expect(!collapsedWasReported(state))
        }
    }
}
