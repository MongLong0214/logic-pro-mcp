@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#291 strict control-bar transport observations", .serialized)
struct Issue291StrictTransportReadTests {
    @Test(arguments: [-1.0, 2.0, 0.9, Double.nan, Double.infinity, -Double.infinity])
    func malformedCheckboxCannotEstablishTransport(_ value: Double) throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        let play = f.b.element(2_910_301)
        f.b.setAttribute(play, kAXValueAttribute as String, NSNumber(value: value))
        #expect(AXLogicProElements.readControlBarCheckboxValue(
            matching: AXLocalePolicy.transportPlayControl, runtime: f.logic) == nil)
        #expect(AXLogicProElements.readControlBarCheckboxValue(
            among: [play], matching: AXLocalePolicy.transportPlayControl, runtime: f.logic) == nil)
        #expect(f.mutations.isEmpty)
    }

    @Test(arguments: [0.0, 1.0])
    func exactCheckboxValuesRemainObserved(_ value: Double) throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        let play = f.b.element(2_910_301)
        f.b.setAttribute(play, kAXValueAttribute as String, NSNumber(value: value))
        let resolved = try #require(AXLogicProElements.readControlBarCheckboxValue(
            matching: AXLocalePolicy.transportPlayControl, runtime: f.logic))
        let collected = try #require(AXLogicProElements.readControlBarCheckboxValue(
            among: [play], matching: AXLocalePolicy.transportPlayControl, runtime: f.logic))
        if value == 1 {
            #expect(resolved)
            #expect(collected)
        } else {
            #expect(!resolved)
            #expect(!collected)
        }
        #expect(f.mutations.isEmpty)
    }
}
