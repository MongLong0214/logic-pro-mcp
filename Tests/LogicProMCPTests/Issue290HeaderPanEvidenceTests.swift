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
}
