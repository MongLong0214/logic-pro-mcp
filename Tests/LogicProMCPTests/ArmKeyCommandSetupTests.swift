@preconcurrency import ApplicationServices
import CoreGraphics
import Testing
@testable import LogicProMCP

/// The live Key-Commands GUI automation itself is validated live (mocks cannot
/// reproduce real Logic KC behavior). These pin the MOCKABLE safety contract:
/// consent MUST gate before any action; the chord is only sent once Learn is
/// OBSERVED engaged; an already-on Learn is never blind-toggled off; focus must
/// be established before typing; and the verify result maps to an honest Outcome.
@Suite struct ArmKeyCommandSetupTests {
    // MARK: - Consent gate

    /// A runtime whose every side-effecting hook trips a flag — so we can assert
    /// consent=false performs NONE of them.
    private static func trippingRuntime(_ trip: @escaping @Sendable () -> Void) -> ArmKeyCommandSetup.Runtime {
        ArmKeyCommandSetup.Runtime(
            activateLogic: { trip(); return true },
            logicIsFrontmost: { trip(); return true },
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

    // MARK: - Fake Key-Commands tree (the mockable slice of the GUI drive)

    private final class PostedChords: @unchecked Sendable {
        var codes: [CGKeyCode] = []
    }

    private struct Harness {
        let runtime: ArmKeyCommandSetup.Runtime
        let posted: PostedChords
        let builder: FakeAXRuntimeBuilder
        let learn: AXUIElement
    }

    private static let ctrlShiftE: (code: CGKeyCode, mods: CGEventFlags) = (14, [.maskControl, .maskShift])

    /// A minimal Key-Commands window tree every hard step can traverse: the
    /// window is found immediately (so Option+K is never posted — a clean signal
    /// that `posted` holds ONLY the arm chord), a search field, a selectable
    /// command row for the record-arm command, a "Learn by Key Label" checkbox,
    /// and a close button. `learnOn` seeds the checkbox; the fake's AXPress is a
    /// no-op on the value, so a Learn that starts off never reads on (modelling
    /// the "Learn did not engage" failure).
    private static func makeHarness(
        learnOn: Bool,
        frontmost: Bool = true,
        verifyArmFlip: Bool?
    ) -> Harness {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(0)
        let kcWindow = builder.element(1)
        let searchField = builder.element(2)
        let commandRow = builder.element(3)
        let commandCell = builder.element(4)
        let learn = builder.element(5)
        let closeButton = builder.element(6)

        builder.setAttribute(kcWindow, kAXTitleAttribute as String, "Key Commands")
        builder.setAttribute(kcWindow, "AXCloseButton", closeButton)
        builder.setRole(searchField, kAXTextFieldRole as String)
        builder.setAttribute(searchField, kAXValueAttribute as String, "")
        builder.setRole(commandRow, kAXRowRole as String)
        builder.setRole(commandCell, kAXStaticTextRole as String)
        builder.setAttribute(commandCell, kAXValueAttribute as String, ArmKeyCommandSetup.commandName)
        builder.setAttribute(commandCell, kAXParentAttribute as String, commandRow)
        builder.setRole(learn, kAXCheckBoxRole as String)
        builder.setAttribute(learn, kAXTitleAttribute as String, ArmKeyCommandSetup.learnCheckboxTitle)
        builder.setAttribute(learn, kAXValueAttribute as String, learnOn ? 1 : 0)

        builder.setAttribute(app, kAXWindowsAttribute as String, [kcWindow])
        builder.setChildren(kcWindow, [searchField, commandRow, learn])
        builder.setChildren(commandRow, [commandCell])

        let posted = PostedChords()
        let runtime = ArmKeyCommandSetup.Runtime(
            activateLogic: { true },
            logicIsFrontmost: { frontmost },
            postChord: { code, _ in posted.codes.append(code) },
            typeText: { _ in },
            sleep: { _ in },
            ax: builder.makeAXRuntime(appElement: app),
            elements: builder.makeLogicRuntime(appElement: app),
            verifyArmFlip: { verifyArmFlip }
        )
        return Harness(runtime: runtime, posted: posted, builder: builder, learn: learn)
    }

    private static func run(_ h: Harness) -> ArmKeyCommandSetup.Outcome {
        ArmKeyCommandSetup.run(
            consent: true,
            keyCode: Self.ctrlShiftE.code,
            modifiers: Self.ctrlShiftE.mods,
            runtime: h.runtime
        )
    }

    /// HIGH#1: a Learn that never reports on must FAIL CLOSED before the chord —
    /// no chord is posted, so nothing is bound to the wrong/empty focus.
    @Test func learnThatNeverEngagesFailsClosedWithoutSendingAnyChord() {
        let h = Self.makeHarness(learnOn: false, verifyArmFlip: true)
        let outcome = Self.run(h)
        guard case .failed(let stage, _) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(stage == "learn_engage")
        #expect(h.posted.codes.isEmpty)
    }

    /// HIGH#2: an already-on Learn must NOT be blind-toggled off; the chord is
    /// still sent exactly once and Learn is left on (its prior state).
    @Test func alreadyOnLearnIsNotToggledOffAndTheChordIsSentOnce() throws {
        let h = Self.makeHarness(learnOn: true, verifyArmFlip: true)
        let outcome = Self.run(h)
        #expect(outcome == ArmKeyCommandSetup.Outcome.configuredAndVerified)
        #expect(h.posted.codes == [Self.ctrlShiftE.code])
        let learnValue = try #require(
            h.builder.attributeValue(h.learn, kAXValueAttribute as String) as? Int
        )
        #expect(learnValue == 1)
    }

    /// Outcome mapping + HIGH#3: with the chord sent but no track to verify on,
    /// the outcome is `configuredUnverified` and its wording must NOT claim the
    /// key command was "assigned" (nothing observed the assignment).
    @Test func noSelectableTrackMapsToHonestUnverifiedOutcome() {
        let h = Self.makeHarness(learnOn: true, verifyArmFlip: nil)
        let outcome = Self.run(h)
        guard case .configuredUnverified(let why) = outcome else {
            Issue.record("expected .configuredUnverified, got \(outcome)")
            return
        }
        #expect(!why.lowercased().contains("assigned"))
        #expect(h.posted.codes == [Self.ctrlShiftE.code])
    }

    /// Outcome mapping: an observed NON-flip (verify drove an arm and it did not
    /// move) is a hard failure, never a success.
    @Test func observedNonFlipMapsToFailedVerify() {
        let h = Self.makeHarness(learnOn: true, verifyArmFlip: false)
        let outcome = Self.run(h)
        guard case .failed(let stage, _) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(stage == "verify")
    }

    /// HIGH#5: if Logic cannot be confirmed frontmost, typing is refused before it
    /// starts — no chord is posted.
    @Test func focusNotEstablishedFailsClosedBeforeTyping() {
        let h = Self.makeHarness(learnOn: true, frontmost: false, verifyArmFlip: true)
        let outcome = Self.run(h)
        guard case .failed(let stage, _) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(stage == "focus_search_field")
        #expect(h.posted.codes.isEmpty)
    }
}
