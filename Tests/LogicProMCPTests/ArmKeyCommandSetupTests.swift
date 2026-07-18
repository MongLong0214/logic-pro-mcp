import CoreGraphics
import Testing
@testable import LogicProMCP

/// The live Key-Commands GUI automation itself is validated live (mocks cannot
/// reproduce real Logic KC behavior). These pin the mockable safety contract:
/// consent MUST gate before any action, and the chord label is correct.
@Suite struct ArmKeyCommandSetupTests {
    /// A runtime whose every side-effecting hook trips a flag — so we can assert
    /// consent=false performs NONE of them.
    private static func trippingRuntime(_ trip: @escaping @Sendable () -> Void) -> ArmKeyCommandSetup.Runtime {
        ArmKeyCommandSetup.Runtime(
            activateLogic: { trip() },
            postChord: { _, _ in trip() },
            typeText: { _ in trip() },
            sleep: { _ in },
            ax: .production,      // unreached under consent=false (asserted below)
            elements: .production,
            verifyArmFlip: { trip(); return true }
        )
    }

    @Test func consentFalseRefusesBeforeAnyAction() {
        final class Box: @unchecked Sendable { var tripped = false }
        let box = Box()
        let runtime = Self.trippingRuntime { box.tripped = true }
        let outcome = ArmKeyCommandSetup.run(
            consent: false,
            keyCode: 14,
            modifiers: [.maskControl, .maskShift],
            runtime: runtime
        )
        #expect(outcome == ArmKeyCommandSetup.Outcome.consentRequired)
        // No activation, no keystroke, no verify may have happened without consent.
        #expect(box.tripped == false)
    }

    @Test func chordLabelRendersControlShiftE() {
        let label = ArmKeyCommandSetup.chordLabel(keyCode: 14, modifiers: [.maskControl, .maskShift])
        #expect(label == "⌃⇧E")
    }

    @Test func chordLabelRendersAllModifiers() {
        let label = ArmKeyCommandSetup.chordLabel(
            keyCode: 15,
            modifiers: [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        )
        #expect(label == "⌃⌥⇧⌘R")
    }
}
