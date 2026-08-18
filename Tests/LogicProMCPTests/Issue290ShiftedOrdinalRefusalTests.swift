@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// MARK: - #290 — an ordinal write refuses a list that was not read whole
//
// `stripEnumeration` has always counted the mixer children whose role would not read, and every
// caller threw that count away. Its own comment says what the count is for:
//
//     A child whose role is unreadable is dropped by the filter, and every later strip then moves
//     down one. Callers address strips by ORDINAL, so a request for track 0 would act on physical
//     strip 1 — a wrong-target write that no downstream readback can catch, because the readback
//     reads the same shifted list.
//
// `mixer.insert_plugin` is such a caller and it is a WRITE. This is ADR-007's rule at the one place
// it is already measurable: resolve exactly, or refuse.
@Suite("#290 a shifted strip list is refused rather than indexed")
struct Issue290ShiftedOrdinalRefusalTests {
    /// A mixer whose children include one element whose role will not read.
    private func mixerWithUnreadableChild(
        _ builder: FakeAXRuntimeBuilder,
        id: Int,
        readableStrips: Int
    ) -> (mixer: AXUIElement, runtime: AXHelpers.Runtime) {
        let mixer = builder.element(id)
        builder.setAttribute(mixer, kAXRoleAttribute as String, kAXGroupRole as String)
        var children: [AXUIElement] = []
        for offset in 0..<readableStrips {
            let strip = builder.element(id + 10 + offset)
            builder.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            children.append(strip)
        }
        let mystery = builder.element(id + 99)
        children.append(mystery)
        builder.setChildren(mixer, children)
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
        return (mixer, runtime)
    }

    @Test("the enumeration reports the child it could not read")
    func enumerationCountsTheUnreadableChild() {
        let builder = FakeAXRuntimeBuilder()
        let (mixer, runtime) = mixerWithUnreadableChild(builder, id: 29_000, readableStrips: 3)
        let enumeration = AXLogicProElements.stripEnumeration(in: mixer, runtime: runtime)
        #expect(enumeration.strips.count == 3)
        #expect(enumeration.unreadableChildren == 1)
    }

    /// The strict accessor is the whole point: a caller that indexes its result is indexing a list
    /// that was read whole, and it has no way to opt out of that by accident.
    @Test("the strict accessor yields nothing when a child would not read")
    func strictAccessorRefusesAnIncompleteRead() {
        let builder = FakeAXRuntimeBuilder()
        let (mixer, runtime) = mixerWithUnreadableChild(builder, id: 29_100, readableStrips: 4)
        #expect(AXLogicProElements.mixerChannelStripsIfCompletelyRead(
            in: mixer, runtime: runtime
        ) == nil)
    }

    @Test("a fully readable mixer still yields its strips")
    func strictAccessorPassesACompleteRead() throws {
        let builder = FakeAXRuntimeBuilder()
        let mixer = builder.element(29_200)
        builder.setAttribute(mixer, kAXRoleAttribute as String, kAXGroupRole as String)
        let strips = (0..<3).map { offset -> AXUIElement in
            let strip = builder.element(29_210 + offset)
            builder.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            return strip
        }
        builder.setChildren(mixer, strips)

        let result = try #require(AXLogicProElements.mixerChannelStripsIfCompletelyRead(
            in: mixer, runtime: builder.makeAXRuntime()
        ))
        #expect(result.strips.count == 3)
        #expect(result.unreadableChildren == 0)
    }
}
