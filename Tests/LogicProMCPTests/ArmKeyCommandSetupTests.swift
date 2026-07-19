@preconcurrency import ApplicationServices
import CoreGraphics
import MCP
import Testing
@testable import LogicProMCP

/// The live Key-Commands GUI automation itself is validated live (mocks cannot
/// reproduce real Logic KC behavior). These pin the mockable safety contract of
/// the engine (#413): a verify-first idempotent fast path, an IDENTITY+SELECTED
/// command match against the FLAT command surface (the KC list holds no AXRows —
/// commands are flat AXTextFields whose value carries the name, and the search
/// field echoes the typed query and must be excluded), a Learn-ensured-on gate,
/// any-unexpected-modal conflict decline (Cancel only, never a steal), cleanup on
/// every exit path, honest per-phase evidence, and a functional arm-flip as the
/// only success gate. The fake below models that surface and its refusal paths.
@Suite struct ArmKeyCommandSetupTests {
    private final class Probe: @unchecked Sendable {
        var chords: [(CGKeyCode, CGEventFlags)] = []
        var typed: [String] = []
        var verifyCalls = 0
        var frontmost = true
        var learnPresses = 0
        var reassignPressed = false
        var cancelled = false
        // Whether this operation still owns the server mutation gate. Flipped false
        // (independently of `cancelled`) to model a successor reclaiming the gate.
        var ownsGate = true
    }

    private enum LearnPress {
        case toggle
        case stayOff
        case stickOn
    }

    private struct Fixture {
        let builder: FakeAXRuntimeBuilder
        let window: AXUIElement
        let search: AXUIElement
        let learn: AXUIElement
        let commands: [AXUIElement]
        let probe: Probe
        let runtime: ArmKeyCommandSetup.Runtime
    }

    /// `firstVerify` is the verify-first fast-path result (false ⇒ not already
    /// mapped, drive the GUI); `verify` is the post-assignment functional result.
    private static func fixture(
        commandValues: [String] = [ArmKeyCommandSetup.commandName],
        learnValue: Int = 0,
        // Make Learn's INITIAL AX value unreadable (non-numeric) — the engine must
        // fail closed rather than invent a prior state.
        learnValueUnreadable: Bool = false,
        // Make Learn's value unreadable when the assignment chord posts — cleanup
        // must then report restored=false honestly.
        learnUnreadableOnChord: Bool = false,
        learnPress: LearnPress = .toggle,
        // Whether the search field's focus SET takes. When false the field never
        // reads a positive AXFocused, so the engine fails closed before typing.
        focusSetSucceeds: Bool = true,
        // Whether the search field carries the AXSearchField subrole. When false it
        // is an unidentified text field and must be rejected.
        searchFieldHasSearchSubrole: Bool = true,
        // Whether the KC window is Logic's focused window before the chord.
        kcFocusedBeforeChord: Bool = true,
        // Whether the assignment-chord CGEvent post succeeds.
        assignmentPostSucceeds: Bool = true,
        // Whether the KC window is already open at run() start. When false the engine
        // must post Option+K and poll for it to appear.
        windowInitiallyOpen: Bool = true,
        // Whether the Option+K post to open the KC window succeeds. When false the
        // engine must fail closed at open_key_commands, carrying the post result.
        optionKPostSucceeds: Bool = true,
        // Whether pressing the conflict dialog's Cancel button actually dismisses it.
        // When false the decline is reported as not-dismissed (never a steal).
        declineButtonFails: Bool = false,
        // Flip the injected cancellation flag true after typing, so the before-Learn
        // deadline checkpoint fires before the assignment chord.
        cancelBeforeAssignmentChord: Bool = false,
        // The command deadline has ALREADY fired at run() entry (isCancelled true
        // from the start), so even verify-first must post nothing.
        cancelledFromStart: Bool = false,
        // typeText reports a mid-string cancellation (returns false) — models the
        // deadline firing between code units, so the caller must fail closed.
        typeTextCancelsMidString: Bool = false,
        // Flip gate OWNERSHIP false after typing (WITHOUT setting cancelled), so the
        // before-Learn ownership checkpoint stops the drive — modelling a successor
        // that reclaimed the mutation gate mid-run.
        loseGateOwnershipAfterFilter: Bool = false,
        frontmost: Bool = true,
        loseFrontmostAfterFilter: Bool = false,
        selectCommandSucceeds: Bool = true,
        // Flip the matched command's AXSelected OFF when Learn is pressed, modelling
        // a selection that drifts between the confirmed select and the chord.
        driftSelectionOnLearnPress: Bool = false,
        conflictAlertOnChord: Bool = false,
        // A dialog-subrole window already open BEFORE the chord (e.g. a settings
        // window) — it must NEVER be mistaken for the reassignment alert.
        preExistingDialogWindow: Bool = false,
        // A NEW dialog-subrole window that appears only AFTER the chord — this IS
        // the reassignment alert and must be detected + declined.
        newDialogWindowOnChord: Bool = false,
        closeRemovesWindow: Bool = true,
        firstVerify: ArmKeyCommandSetup.VerifyResult = .unmapped,
        verify: ArmKeyCommandSetup.VerifyResult = .environmentUnavailable
    ) -> Fixture {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(10_000)
        let window = builder.element(10_001)
        let search = builder.element(10_002)
        let learn = builder.element(10_003)
        let close = builder.element(10_004)
        let scrollArea = builder.element(10_005)
        let table = builder.element(10_006)
        let alert = builder.element(10_009)
        let alertText = builder.element(10_010)
        let alertCancel = builder.element(10_011)
        let alertReassign = builder.element(10_012)
        // A standalone dialog WINDOW (subrole, not a sheet) with a Cancel button.
        let dialogWin = builder.element(10_013)
        let dialogCancel = builder.element(10_014)
        let probe = Probe()
        probe.frontmost = frontmost
        probe.cancelled = cancelledFromStart

        builder.setAttribute(dialogWin, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        builder.setAttribute(dialogWin, kAXTitleAttribute as String, "Project Settings")
        builder.setAttribute(dialogCancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(dialogCancel, kAXTitleAttribute as String, "Cancel")
        builder.setChildren(dialogWin, [dialogCancel])
        let openWindows: [AXUIElement] = windowInitiallyOpen ? [window] : []
        let initialWindows: [AXUIElement] = preExistingDialogWindow ? (openWindows + [dialogWin]) : openWindows
        builder.setAttribute(app, kAXWindowsAttribute as String, initialWindows)
        // The KC window owns focus by default; kcFocusedBeforeChord:false points the
        // app's focused window elsewhere so the pre-chord focus-ownership gate trips.
        builder.setAttribute(app, kAXFocusedWindowAttribute as String, kcFocusedBeforeChord ? window : close)
        builder.setAttribute(window, kAXTitleAttribute as String, "Key Commands")
        builder.setAttribute(window, "AXCloseButton", close)
        builder.setAttribute(scrollArea, kAXRoleAttribute as String, kAXScrollAreaRole as String)
        // Empty table shell (ZERO AXRows) — matches the live flat surface.
        builder.setAttribute(table, kAXRoleAttribute as String, kAXTableRole as String)
        builder.setChildren(table, [])
        // The search field is a structurally-identified AXSearchField (via subrole)
        // unless the test models an unidentified plain text field.
        builder.setAttribute(search, kAXRoleAttribute as String, kAXTextFieldRole as String)
        if searchFieldHasSearchSubrole {
            builder.setAttribute(search, kAXSubroleAttribute as String, kAXSearchFieldSubrole as String)
        }
        builder.setAttribute(search, kAXValueAttribute as String, "")
        // AXFocused is left UNSET (reads nil/unreadable) until the engine's focus
        // set takes. The engine requires a definitive AXFocused == true before
        // typing, so a refused set (focusSetSucceeds == false) leaves focus nil and
        // fails closed with zero keystrokes.
        builder.setAttribute(learn, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(learn, kAXTitleAttribute as String, ArmKeyCommandSetup.learnCheckboxTitle)
        // An unreadable Learn value is a non-numeric string (checkboxState → nil).
        if learnValueUnreadable {
            builder.setAttribute(learn, kAXValueAttribute as String, "unavailable")
        } else {
            builder.setAttribute(learn, kAXValueAttribute as String, learnValue)
        }
        builder.setAttribute(alert, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(alertText, kAXRoleAttribute as String, kAXStaticTextRole as String)
        builder.setAttribute(alertCancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(alertCancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(alertReassign, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(alertReassign, kAXTitleAttribute as String, "Reassign")

        var commands: [AXUIElement] = []
        for (offset, value) in commandValues.enumerated() {
            let command = builder.element(10_100 + offset)
            builder.setAttribute(command, kAXRoleAttribute as String, kAXTextFieldRole as String)
            builder.setAttribute(command, kAXValueAttribute as String, value)
            builder.setAttribute(command, kAXParentAttribute as String, scrollArea)
            builder.setAttribute(command, kAXSelectedAttribute as String, false)
            builder.setChildren(command, [])
            commands.append(command)
        }
        // Before typing, only the empty table shell is present.
        builder.setChildren(scrollArea, [table])
        builder.setChildren(window, [search, scrollArea, learn])
        builder.setChildren(learn, [])
        let builtCommands = commands

        let ax = builder.makeAXRuntime(
            appElement: app,
            attributeValueHandler: nil,
            setAttributeHandler: { element, attribute, value in
                if CFEqual(element, search), attribute == (kAXFocusedAttribute as String),
                   !focusSetSucceeds {
                    return false
                }
                if !selectCommandSucceeds,
                   builtCommands.contains(where: { CFEqual($0, element) }),
                   attribute == (kAXSelectedAttribute as String) {
                    return false
                }
                // A direct search value SET stores the field text but does NOT
                // collapse the filter (matches live Logic 12.3) — only typed input
                // reveals the command cells (see typeText below).
                builder.setAttribute(element, attribute, value)
                return true
            },
            performActionHandler: { element, _ in
                if CFEqual(element, close) {
                    if closeRemovesWindow {
                        builder.setAttribute(app, kAXWindowsAttribute as String, [AXUIElement]())
                    }
                    return true
                }
                if CFEqual(element, alertCancel) {
                    // A decline whose press does not clear the sheet models Logic
                    // failing to dismiss — reported as not-dismissed, never a steal.
                    if !declineButtonFails {
                        builder.setAttribute(window, "AXSheets", [AXUIElement]())
                    }
                    return true
                }
                if CFEqual(element, alertReassign) {
                    // A steal — the decline path must NEVER press this.
                    probe.reassignPressed = true
                    return true
                }
                if CFEqual(element, dialogCancel) {
                    // Declining the standalone dialog dismisses that window.
                    builder.setAttribute(app, kAXWindowsAttribute as String, [window])
                    return true
                }
                guard CFEqual(element, learn) else { return true }
                probe.learnPresses += 1
                if driftSelectionOnLearnPress, let firstCommand = builtCommands.first {
                    builder.setAttribute(firstCommand, kAXSelectedAttribute as String, false)
                }
                switch learnPress {
                case .toggle:
                    let current = (builder.attributeValue(learn, kAXValueAttribute as String) as? Int) ?? 0
                    builder.setAttribute(learn, kAXValueAttribute as String, current == 0 ? 1 : 0)
                case .stayOff:
                    break
                case .stickOn:
                    builder.setAttribute(learn, kAXValueAttribute as String, 1)
                }
                return true
            }
        )
        let elements = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax)
        let runtime = ArmKeyCommandSetup.Runtime(
            activateLogic: {},
            logicIsFrontmost: { probe.frontmost },
            postChord: { code, flags in
                probe.chords.append((code, flags))
                // Option+K opens the Key Commands window (when it was not already
                // open). A failed post is reported so the engine fails closed.
                if flags.contains(.maskAlternate) {
                    guard optionKPostSucceeds else { return false }
                    if !windowInitiallyOpen {
                        let opened: [AXUIElement] = preExistingDialogWindow ? [window, dialogWin] : [window]
                        builder.setAttribute(app, kAXWindowsAttribute as String, opened)
                    }
                    return true
                }
                // Non-assignment posts (Escape decline) always succeed.
                guard code == 14, flags == [.maskControl, .maskShift] else { return true }
                if conflictAlertOnChord {
                    builder.setAttribute(
                        alertText, kAXValueAttribute as String,
                        "The key command ⌃⇧E is already assigned to another command. Reassign?"
                    )
                    builder.setChildren(alert, [alertText, alertCancel, alertReassign])
                    builder.setAttribute(window, "AXSheets", [alert])
                }
                if newDialogWindowOnChord {
                    // A dialog window that did NOT exist before the chord appears now.
                    builder.setAttribute(app, kAXWindowsAttribute as String, [window, dialogWin])
                }
                if learnUnreadableOnChord {
                    // Learn's value becomes unreadable coincident with the chord, so
                    // cleanup cannot confirm a restore.
                    builder.setAttribute(learn, kAXValueAttribute as String, "unavailable")
                }
                // Assignment-chord post honesty: report the injected post result.
                return assignmentPostSucceeds
            },
            typeText: { text -> Bool in
                // A mid-string cancellation stops posting part-way: report false and
                // reveal nothing, so the caller fails closed.
                if typeTextCancelsMidString { return false }
                // The primary filter drive: after positive focus, typing reveals the
                // matching FLAT command cells as children of the scroll area (a
                // direct value set does not collapse the list).
                probe.typed.append(text)
                if cancelBeforeAssignmentChord {
                    // The command deadline fires after typing — the next
                    // cancellation checkpoint (before the Learn press) must stop the
                    // drive, so neither Learn nor the assignment chord is posted.
                    probe.cancelled = true
                }
                if loseGateOwnershipAfterFilter {
                    // A successor reclaimed the gate — ownership is lost but the
                    // deadline has NOT fired (cancelled stays false), so ONLY the
                    // ownership checkpoint can stop the drive.
                    probe.ownsGate = false
                }
                if loseFrontmostAfterFilter { probe.frontmost = false }
                builder.setAttribute(search, kAXValueAttribute as String, text)
                var revealed: [AXUIElement] = [table]
                for (idx, value) in commandValues.enumerated()
                where value.range(of: text, options: .caseInsensitive) != nil {
                    revealed.append(builtCommands[idx])
                }
                builder.setChildren(scrollArea, revealed)
                return true
            },
            sleep: { _ in },
            isCancelled: { probe.cancelled },
            ownsGate: { probe.ownsGate },
            ax: ax,
            elements: elements,
            verifyArmFlip: { _, _ in
                probe.verifyCalls += 1
                return probe.verifyCalls == 1 ? firstVerify : verify
            }
        )
        return Fixture(
            builder: builder, window: window, search: search,
            learn: learn, commands: commands, probe: probe, runtime: runtime
        )
    }

    private static func run(_ fixture: Fixture) -> ArmKeyCommandSetup.Outcome {
        ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )
    }

    private static func failure(
        _ outcome: ArmKeyCommandSetup.Outcome
    ) -> (stage: String, evidence: ArmKeyCommandSetup.Evidence)? {
        guard case .failed(let stage, _, let evidence) = outcome else { return nil }
        return (stage, evidence)
    }

    /// A runtime whose every side-effecting hook trips a flag — so we can assert
    /// consent=false performs NONE of them.
    private static func trippingRuntime(_ trip: @escaping @Sendable () -> Void) -> ArmKeyCommandSetup.Runtime {
        ArmKeyCommandSetup.Runtime(
            activateLogic: { trip() },
            postChord: { _, _ in trip(); return true },
            typeText: { _ in trip(); return true },
            sleep: { _ in },
            ax: .production,
            elements: .production,
            verifyArmFlip: { _, _ in trip(); return .verified }
        )
    }

    // MARK: - Consent + config gates (before any side effect)

    @Test func consentFalseRefusesBeforeAnyAction() {
        final class Box: @unchecked Sendable { var tripped = false }
        let box = Box()
        let runtime = Self.trippingRuntime { box.tripped = true }
        let outcome = ArmKeyCommandSetup.run(
            consent: false, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: runtime
        )
        #expect(outcome == ArmKeyCommandSetup.Outcome.consentRequired)
        #expect(!box.tripped)
    }

    /// keyCode 40 ('K') is NOT in the known-safe glyph map, so it is refused up
    /// front — before any GUI work, verification mutation, or key post.
    @Test func unmappedKeyCodeRefusesBeforeAnyChord() {
        let fixture = Self.fixture()
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 40, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )
        guard case .configInvalid = outcome else {
            Issue.record("expected .configInvalid for an unmapped keyCode; got \(outcome)")
            return
        }
        #expect(fixture.probe.chords.isEmpty)
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.verifyCalls == 0)
    }

    @Test func knownSafeChordKeyCodeCoversDefaultButNotCustomCodes() {
        #expect(ArmKeyCommandSetup.isKnownSafeChordKeyCode(14))
        #expect(ArmKeyCommandSetup.isKnownSafeChordKeyCode(15))
        #expect(!ArmKeyCommandSetup.isKnownSafeChordKeyCode(40))
    }

    /// A bare chord (empty modifiers) — e.g. keyCode 15 = 'R' = transport Record —
    /// is hard-refused BEFORE verify-first, so no key is ever posted and no
    /// verification mutation runs. This is the no-steal / no-record safety gate.
    @Test func bareChordModifiersRefusedBeforeAnyPost() {
        final class Box: @unchecked Sendable { var tripped = false }
        let box = Box()
        let runtime = Self.trippingRuntime { box.tripped = true }
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 15, modifiers: [], runtime: runtime
        )
        guard case .configInvalid = outcome else {
            Issue.record("expected .configInvalid for a bare chord; got \(outcome)")
            return
        }
        // No activation, no key post, no typing, no verification mutation.
        #expect(!box.tripped)
    }

    // MARK: - Verify-first idempotent fast path

    @Test func verifyFirstFastPathReturnsAlreadyConfiguredWithoutGUIWork() {
        let fixture = Self.fixture(firstVerify: .verified)
        let outcome = Self.run(fixture)
        guard case .alreadyConfigured(let evidence) = outcome else {
            Issue.record("expected .alreadyConfigured; got \(outcome)")
            return
        }
        #expect(evidence.writeSource == .existingMappingVerify)
        #expect(!evidence.configurationWriteAttempted)
        #expect(evidence.verificationMutationAttempted)
        #expect(evidence.restored)
        // No GUI drive: nothing typed, no chord, exactly one (fast-path) verify.
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.chords.isEmpty)
        #expect(fixture.probe.verifyCalls == 1)
    }

    /// A verify-first PARTIAL restore (the verification flip mutated the host and a
    /// restore failed) must FAIL CLOSED — never pile GUI mutations onto a host we
    /// already left dirty.
    @Test func verifyFirstPartialRestoreFailsClosedWithoutGUI() throws {
        let fixture = Self.fixture(firstVerify: .partialRestore(detail: "record-enable could not be restored"))
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "verify_partial_restore")
        #expect(!failure.evidence.restored)
        // No GUI assignment followed: no filter typed, no chord posted.
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.chords.isEmpty)
        #expect(fixture.probe.verifyCalls == 1)
    }

    /// A verify-first that could not post the chord fails closed (never silently
    /// proceeds to GUI as if unmapped).
    @Test func verifyFirstCouldNotPostFailsClosedWithoutGUI() throws {
        let fixture = Self.fixture(firstVerify: .couldNotPost)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "verify_post_failed")
        #expect(fixture.probe.chords.isEmpty)
        #expect(fixture.probe.verifyCalls == 1)
    }

    /// A verify-first that cannot prepare a functional target (no selectable track)
    /// does NOT proceed to the GUI assignment — State A is impossible without a
    /// flip, and a GUI mutation that could not be verified must never run. It fails
    /// closed with zero GUI work.
    @Test func environmentUnavailableDoesNotProceedToGUI() throws {
        let fixture = Self.fixture(firstVerify: .environmentUnavailable)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "verify_environment_unavailable")
        // No Key Commands GUI was driven: window never opened, nothing typed/posted.
        #expect(!failure.evidence.windowOpened)
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.chords.isEmpty)
        #expect(fixture.probe.verifyCalls == 1)
        // Nothing mutated → the response is safe to retry once a track is armed.
        #expect(failure.evidence.safeToRetry)
    }

    // MARK: - GUI assignment success (functional arm-flip is the only gate)

    @Test func guiAssignmentSucceedsViaFunctionalVerify() throws {
        let fixture = Self.fixture(firstVerify: .unmapped, verify: .verified)
        let outcome = Self.run(fixture)
        guard case .configuredAndVerified(let evidence) = outcome else {
            Issue.record("expected .configuredAndVerified; got \(outcome)")
            return
        }
        #expect(evidence.writeSource == .guiAssignment)
        #expect(evidence.configurationWriteAttempted)
        #expect(evidence.selectionReadback)
        #expect(evidence.matchCount == 1)
        let armFlipObserved = try #require(evidence.armFlipObserved)
        #expect(armFlipObserved)
        // Split cleanup flags: Learn restored, window closed, verify's own restore.
        #expect(evidence.learnRestored)
        #expect(evidence.closeConfirmed)
        let verifyRestored = try #require(evidence.verifyRestored)
        #expect(verifyRestored)
        #expect(evidence.restored)
        // The filter was driven by typing after positive focus.
        #expect(fixture.probe.typed == [ArmKeyCommandSetup.commandName])
        #expect(fixture.probe.chords.contains { $0.0 == 14 && $0.1 == [.maskControl, .maskShift] })
        // fast-path verify + post-assignment verify.
        #expect(fixture.probe.verifyCalls == 2)
    }

    @Test func defaultVerifierCannotFabricateConfiguredSuccess() {
        let fixture = Self.fixture()   // verify defaults nil
        let outcome = Self.run(fixture)
        guard case .configuredUnverified(_, let evidence) = outcome else {
            Issue.record("expected .configuredUnverified; got \(outcome)")
            return
        }
        #expect(evidence.writeSource == .guiAssignment)
        #expect(fixture.probe.verifyCalls == 2)
    }

    /// A failed Option+K post (the window was not already open and Logic did not
    /// accept the key) fails closed at open_key_commands, carrying the post result
    /// — never proceeding to type or Learn onto an unopened surface.
    @Test func failedOptionKPostFailsClosedAtOpenKeyCommands() throws {
        let fixture = Self.fixture(windowInitiallyOpen: false, optionKPostSucceeds: false)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "open_key_commands")
        #expect(!failure.evidence.windowOpened)
        // The Option+K chord was attempted, but nothing downstream ran.
        #expect(fixture.probe.chords.contains { $0.1.contains(.maskAlternate) })
        let assignmentChordPosted = fixture.probe.chords.contains { $0.0 == 14 }
        #expect(!assignmentChordPosted)
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.learnPresses == 0)
    }

    /// The happy path also exercises Option+K when the window is not pre-open: the
    /// engine posts it, the window appears, and assignment proceeds to State A.
    @Test func optionKOpensWindowWhenNotAlreadyOpen() throws {
        let fixture = Self.fixture(windowInitiallyOpen: false, firstVerify: .unmapped, verify: .verified)
        let outcome = Self.run(fixture)
        guard case .configuredAndVerified = outcome else {
            Issue.record("expected .configuredAndVerified; got \(outcome)")
            return
        }
        #expect(fixture.probe.chords.contains { $0.1.contains(.maskAlternate) })
    }

    // MARK: - IDENTITY + SELECTED gate (locked refusal paths)

    /// The search field echoes the typed command name, but it is NOT a command —
    /// with no command cell revealed the identity gate excludes the search echo
    /// and fails closed at command_not_found (no chord).
    @Test func searchEchoOnlyMatchFailsCommandNotFound() {
        let fixture = Self.fixture(commandValues: [])
        let outcome = Self.run(fixture)
        #expect(Self.failure(outcome)?.stage == "command_not_found")
        #expect(fixture.probe.chords.isEmpty)
    }

    /// A non-unique filter (two cells reading exactly the command name) is refused
    /// rather than Learn binding onto an ambiguous match.
    @Test func ambiguousMultiMatchFailsClosed() {
        let fixture = Self.fixture(
            commandValues: [ArmKeyCommandSetup.commandName, ArmKeyCommandSetup.commandName]
        )
        let outcome = Self.run(fixture)
        let failure = Self.failure(outcome)
        #expect(failure?.stage == "command_ambiguous")
        #expect(failure?.evidence.matchCount == 2)
        #expect(fixture.probe.chords.isEmpty)
    }

    /// A command whose row selection is never confirmed (AXSelected set is refused)
    /// fails closed before Learn — never bind onto an unconfirmed selection.
    @Test func unconfirmedSelectionFailsClosed() {
        let fixture = Self.fixture(selectCommandSucceeds: false)
        let outcome = Self.run(fixture)
        #expect(Self.failure(outcome)?.stage == "select_command")
        #expect(fixture.probe.chords.isEmpty)
    }

    /// Selection-identity TOCTOU: if the confirmed selection drifts off the target
    /// command between the select and the chord, setup fails closed and posts NO
    /// chord (it must never assign the chord to the wrong command).
    @Test func selectionDriftBeforeChordFailsClosed() throws {
        let fixture = Self.fixture(driftSelectionOnLearnPress: true, verify: .verified)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "selection_drifted")
        #expect(fixture.probe.chords.isEmpty)
    }

    // MARK: - Learn gate (never post the chord unless Learn is observed on)

    @Test func learnNotEngageableFailsBeforeChord() {
        let fixture = Self.fixture(learnPress: .stayOff)
        let outcome = Self.run(fixture)
        #expect(Self.failure(outcome)?.stage == "learn_engage")
        #expect(fixture.probe.chords.isEmpty)
    }

    @Test func learnInitiallyOnIsRestoredOn() {
        let fixture = Self.fixture(learnValue: 1, verify: .verified)
        let outcome = Self.run(fixture)
        guard case .configuredAndVerified = outcome else {
            Issue.record("expected success; got \(outcome)")
            return
        }
        let value = fixture.builder.attributeValue(fixture.learn, kAXValueAttribute as String) as? Int
        let restoredOn = try? #require(value)
        #expect(restoredOn == 1)
    }

    /// An UNREADABLE initial Learn state must fail closed — never invent a prior
    /// value nor press a checkbox whose state can't be read.
    @Test func initialLearnUnreadableFailsClosedNoPost() throws {
        let fixture = Self.fixture(learnValueUnreadable: true)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "learn_state_unreadable")
        #expect(fixture.probe.chords.isEmpty)
        #expect(fixture.probe.learnPresses == 0)
    }

    /// When Learn becomes UNREADABLE during cleanup, restore is not claimed — the
    /// run reports restored=false and does not claim State A.
    @Test func cleanupLearnUnreadableReportsNotRestored() throws {
        let fixture = Self.fixture(learnUnreadableOnChord: true, verify: .verified)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "cleanup_incomplete")
        #expect(!failure.evidence.learnRestored)
        #expect(!failure.evidence.restored)
    }

    // MARK: - Focus gate: positive focus required before typing the filter

    /// The filter is driven by TYPING after a definitive positive focus readback;
    /// the typed query collapses the list to the exact single match, which the
    /// engine then assigns and verifies.
    @Test func focusThenTypedDrivesFilter() throws {
        let fixture = Self.fixture(verify: .verified)
        let outcome = Self.run(fixture)
        guard case .configuredAndVerified(let evidence) = outcome else {
            Issue.record("expected .configuredAndVerified; got \(outcome)")
            return
        }
        #expect(evidence.matchCount == 1)
        #expect(fixture.probe.typed == [ArmKeyCommandSetup.commandName])
    }

    /// When the search field never reads a positive AXFocused (nil/unreadable), the
    /// engine fails closed BEFORE any keystroke — a key must never reach the wrong
    /// Logic surface.
    @Test func focusUnreadableFailsClosedNoKeys() throws {
        let fixture = Self.fixture(focusSetSucceeds: false)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "search_focus")
        // Pre-mutation failure: ZERO typed keys, no chord, no write attempted.
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.chords.isEmpty)
        #expect(!failure.evidence.configurationWriteAttempted)
    }

    @Test func logicMustRemainFrontmostBeforeAssignmentChord() {
        let fixture = Self.fixture(loseFrontmostAfterFilter: true)
        let outcome = Self.run(fixture)
        #expect(Self.failure(outcome)?.stage == "logic_not_frontmost")
        #expect(fixture.probe.chords.isEmpty)
    }

    // MARK: - Wrong-target identity / focus ownership

    /// The search field must be a structurally-identified AXSearchField; a plain
    /// unidentified text field is rejected (never cleared/typed into).
    @Test func nonKCSearchFieldRejected() throws {
        let fixture = Self.fixture(searchFieldHasSearchSubrole: false)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "search_field")
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.chords.isEmpty)
    }

    /// Immediately before the assignment chord, the Key Commands window must own
    /// focus (be Logic's key window). If it does not, fail closed — a key could be
    /// interpreted by the main window as a random command.
    @Test func assignmentChordRequiresKCFocusOwnership() throws {
        let fixture = Self.fixture(kcFocusedBeforeChord: false, verify: .verified)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "key_commands_not_focused")
        let assignmentChordPosted = fixture.probe.chords.contains { $0.0 == 14 }
        #expect(!assignmentChordPosted)
    }

    // MARK: - Deadline / cancellation: no late mutation after timeout

    /// Once the command deadline fires (isCancelled flips true) before the
    /// assignment chord, NO further key is posted and NO further Key Commands
    /// mutation is issued; the run fails closed and runs best-effort cleanup.
    @Test func cancellationBeforeChordPostsNoKeyFailsClosed() throws {
        let fixture = Self.fixture(cancelBeforeAssignmentChord: true, verify: .verified)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "deadline")
        // No assignment chord was posted, and Learn was never pressed after the
        // deadline fired.
        let assignmentChordPosted = fixture.probe.chords.contains { $0.0 == 14 }
        #expect(!assignmentChordPosted)
        #expect(fixture.probe.learnPresses == 0)
        // Best-effort cleanup ran: the KC window was closed.
        #expect(ArmKeyCommandSetup.keyCommandsWindow(runtime: fixture.runtime) == nil)
    }

    /// The VERIFY-FIRST probe posts a real chord, so a deadline already fired at
    /// entry must skip it entirely: no verify call, no key, no GUI, fail closed.
    @Test func verifyFirstProbeDoesNotPostAfterCancellation() throws {
        let fixture = Self.fixture(cancelledFromStart: true, firstVerify: .verified, verify: .verified)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "deadline")
        // Verify-first was never invoked, and nothing was posted or typed.
        #expect(fixture.probe.verifyCalls == 0)
        #expect(fixture.probe.chords.isEmpty)
        #expect(fixture.probe.typed.isEmpty)
    }

    /// A mid-string typeText cancellation (the deadline fires between code units)
    /// is reported by typeText returning false; the run fails closed before Learn
    /// or the chord.
    @Test func typeTextCancelledMidStringFailsClosed() throws {
        let fixture = Self.fixture(typeTextCancelsMidString: true)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "deadline")
        #expect(fixture.probe.learnPresses == 0)
        let assignmentChordPosted = fixture.probe.chords.contains { $0.0 == 14 }
        #expect(!assignmentChordPosted)
    }

    /// The cancellation cleanup path reports OBSERVED restore/close results and does
    /// NOT claim full restoration when a step failed.
    @Test func cancelPathReportsHonestCleanupWhenCloseFails() throws {
        let fixture = Self.fixture(cancelBeforeAssignmentChord: true, closeRemovesWindow: false)
        let outcome = Self.run(fixture)
        guard case .failed(let stage, let hint, let evidence) = outcome else {
            Issue.record("expected .failed; got \(outcome)")
            return
        }
        #expect(stage == "deadline")
        // The window did NOT close — reported honestly, not claimed restored.
        #expect(!evidence.closeConfirmed)
        #expect(!evidence.restored)
        #expect(!hint.lowercased().contains("all captured ui state was restored"))
        #expect(hint.contains("Key Commands window closed: false"))
    }

    /// Gate-ownership invariant: if a successor reclaims the mutation gate
    /// mid-run (ownsGate → false) while the deadline has NOT fired (isCancelled
    /// stays false), the ownership check ALONE must stop every forward mutation —
    /// no Learn press, no assignment chord. Proves the ownership seam is independent
    /// of cancellation, not masked by it.
    @Test func staleOwnerAfterSuccessorAcquisitionPostsNothing() throws {
        let fixture = Self.fixture(loseGateOwnershipAfterFilter: true)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "deadline")
        // The deadline never fired — ownership loss alone stopped the drive.
        #expect(!fixture.probe.cancelled)
        #expect(fixture.probe.learnPresses == 0)
        let assignmentChordPosted = fixture.probe.chords.contains { $0.0 == 14 }
        #expect(!assignmentChordPosted)
    }

    // MARK: - Conflict modal → decline only, fail closed (no steal)

    @Test func conflictModalIsDeclinedAndFailsClosed() throws {
        let fixture = Self.fixture(conflictAlertOnChord: true, verify: .verified)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "chord_conflict")
        let conflictObserved = try #require(failure.evidence.conflictObserved)
        #expect(conflictObserved)
        // The chord WAS posted (that is how Logic surfaces the conflict) but the
        // reassignment was declined, never confirmed, and no post-verify ran.
        #expect(fixture.probe.chords.contains { $0.0 == 14 })
        #expect(failure.evidence.configurationWriteAttempted)
        #expect(fixture.probe.verifyCalls == 1)
        // Learn restored off, alert dismissed, window closed.
        let learnValue = fixture.builder.attributeValue(fixture.learn, kAXValueAttribute as String) as? Int
        #expect(learnValue == 0)
        let sheets = fixture.builder.attributeValue(fixture.window, "AXSheets") as? [AXUIElement]
        #expect(sheets == nil || sheets!.isEmpty)
        #expect(ArmKeyCommandSetup.keyCommandsWindow(runtime: fixture.runtime) == nil)
    }

    /// A clean conflict decline reports its cleanup HONESTLY: Learn was restored and
    /// the window closed, and the reassignment control was never pressed.
    @Test func conflictWithCleanDeclineReportsRestoredAndClosed() throws {
        let fixture = Self.fixture(conflictAlertOnChord: true, verify: .verified)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "chord_conflict")
        // Split cleanup flags reported honestly, and the top-level AND.
        #expect(failure.evidence.learnRestored)
        #expect(failure.evidence.closeConfirmed)
        #expect(failure.evidence.restored)
        // Cancel only — the reassignment control was NEVER pressed (no steal).
        #expect(!fixture.probe.reassignPressed)
    }

    /// When Learn cannot be turned back off, the conflict path reports restored ==
    /// false rather than hiding the stuck-Learn cleanup failure.
    @Test func restoreLearnFailureIsReportedNotHidden() throws {
        let fixture = Self.fixture(learnPress: .stickOn, conflictAlertOnChord: true, verify: .verified)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "chord_conflict")
        // Learn stuck on → learn_restored false → top-level restored false. The
        // window still closed, so that split flag stays honest.
        #expect(!failure.evidence.learnRestored)
        #expect(!failure.evidence.restored)
        #expect(failure.evidence.closeConfirmed)
    }

    /// When the conflict dialog's Cancel button press does NOT dismiss it, the
    /// failure is reported as not-dismissed — and CRITICALLY the reassignment
    /// control is never pressed (no steal even on a dismissal failure).
    @Test func conflictDeclineButtonFailureReportedNotDismissedNoSteal() throws {
        let fixture = Self.fixture(declineButtonFails: true, conflictAlertOnChord: true, verify: .verified)
        let outcome = Self.run(fixture)
        guard case .failed(let stage, let hint, let evidence) = outcome else {
            Issue.record("expected .failed; got \(outcome)")
            return
        }
        #expect(stage == "chord_conflict")
        let conflictObserved = try #require(evidence.conflictObserved)
        #expect(conflictObserved)
        // The dismissal failed — reported honestly, NEVER escalated to a steal.
        #expect(hint.contains("could not be dismissed"))
        #expect(!fixture.probe.reassignPressed)
    }

    /// A dialog window that was already open BEFORE the chord is not the
    /// reassignment alert, so setup proceeds to the functional verify (no false
    /// conflict).
    @Test func preExistingDialogWindowIsNotAConflict() throws {
        let fixture = Self.fixture(preExistingDialogWindow: true, verify: .verified)
        let outcome = Self.run(fixture)
        guard case .configuredAndVerified(let evidence) = outcome else {
            Issue.record("expected .configuredAndVerified; got \(outcome)")
            return
        }
        let observed = try #require(evidence.conflictObserved)
        #expect(!observed)
    }

    /// A dialog window that appears only AFTER the chord IS the reassignment alert
    /// and is detected + declined (Cancel), failing closed.
    @Test func newDialogWindowAfterChordIsAConflict() throws {
        let fixture = Self.fixture(newDialogWindowOnChord: true, verify: .verified)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "chord_conflict")
        let observed = try #require(failure.evidence.conflictObserved)
        #expect(observed)
        #expect(!fixture.probe.reassignPressed)
        // No post-verify ran — the conflict fails closed before verification.
        #expect(fixture.probe.verifyCalls == 1)
    }

    // MARK: - Verification outcomes

    /// A FAILED assignment-chord post is reported honestly (chord_posted:false) and
    /// fails closed — never claimed as posted, never proceeds to verify/State A.
    @Test func assignmentPostFailsIsReportedNotClaimed() throws {
        let fixture = Self.fixture(assignmentPostSucceeds: false, verify: .verified)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "assignment_post_failed")
        #expect(!failure.evidence.chordPosted)
        // No verification ran after a failed assignment post.
        #expect(fixture.probe.verifyCalls == 1)
    }

    @Test func postAssignmentNoFlipFailsVerifyWithWriteAttempted() throws {
        let fixture = Self.fixture(verify: .unmapped)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "verify")
        #expect(fixture.probe.chords.contains { $0.0 == 14 })
        #expect(failure.evidence.configurationWriteAttempted)
        let armFlipObserved = try #require(failure.evidence.armFlipObserved)
        #expect(!armFlipObserved)
    }

    /// After a successful GUI assignment, no selectable track to run the FINAL
    /// functional verify yields State B (assignment unproven) — NOT State A, and
    /// NOT a fail. (A verify-FIRST environment-unavailable instead fails closed
    /// before the GUI; see environmentUnavailableDoesNotProceedToGUI.)
    @Test func noSelectableTrackAtFinalVerifyYieldsConfiguredUnverified() {
        let fixture = Self.fixture(firstVerify: .unmapped, verify: .environmentUnavailable)
        let outcome = Self.run(fixture)
        guard case .configuredUnverified = outcome else {
            Issue.record("expected .configuredUnverified; got \(outcome)")
            return
        }
    }

    /// A post-assignment PARTIAL restore (verify flip mutated the host, restore
    /// failed) fails closed and never claims State A.
    @Test func postAssignmentPartialRestoreFailsClosed() throws {
        let fixture = Self.fixture(verify: .partialRestore(detail: "the transport recording state could not be restored"))
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "verify_partial_restore")
        #expect(!failure.evidence.restored)
        let verifyRestored = try #require(failure.evidence.verifyRestored)
        #expect(!verifyRestored)
    }

    // MARK: - Honesty truth table (evidence fields ↔ observations)

    /// A failure BEFORE any Learn press or chord (command_not_found) provably
    /// mutated nothing persistent, so it records the observed window-close result
    /// and reports safe_to_retry:true.
    @Test func cleanPreLearnFailureIsSafeToRetryAndRecordsClose() throws {
        let fixture = Self.fixture(commandValues: [])
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "command_not_found")
        // The window-only cleanup was OBSERVED, not discarded.
        #expect(failure.evidence.closeConfirmed)
        #expect(failure.evidence.restored)
        #expect(failure.evidence.safeToRetry)
        let safeToRetry = try #require(failure.evidence.extras["safe_to_retry"] as? Bool)
        #expect(safeToRetry)
    }

    /// A run that left the host dirty (post-assignment partial restore) reports
    /// safe_to_retry:false — the caller must NOT blindly re-run onto dirty state.
    @Test func dirtyHostIsNotSafeToRetry() throws {
        let fixture = Self.fixture(verify: .partialRestore(detail: "the transport recording state could not be restored"))
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(!failure.evidence.restored)
        #expect(!failure.evidence.safeToRetry)
        let safeToRetry = try #require(failure.evidence.extras["safe_to_retry"] as? Bool)
        #expect(!safeToRetry)
    }

    /// A post-Learn failure records the OBSERVED restore/close results instead of
    /// discarding them: a stuck close leaves restored:false and window_closed:false.
    @Test func postLearnFailureRecordsObservedCleanup() throws {
        let fixture = Self.fixture(kcFocusedBeforeChord: false, closeRemovesWindow: false)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "key_commands_not_focused")
        #expect(!failure.evidence.closeConfirmed)
        #expect(!failure.evidence.restored)
        // window_closed and close_confirmed always agree.
        let extras = failure.evidence.extras
        let windowClosed = try #require(extras["window_closed"] as? Bool)
        let closeConfirmed = try #require(extras["close_confirmed"] as? Bool)
        #expect(windowClosed == closeConfirmed)
        #expect(!windowClosed)
    }

    /// conflict_observed is OMITTED (not false) when the conflict poll never ran,
    /// and verify_restored is OMITTED when no verification mutation happened.
    @Test func omittedFieldsDistinguishUnknownFromObservedFalse() throws {
        let fixture = Self.fixture(assignmentPostSucceeds: false, verify: .verified)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "assignment_post_failed")
        let extras = failure.evidence.extras
        // The assignment post failed BEFORE the conflict poll and BEFORE any final
        // verify mutation — both fields are absent, never a misleading `false`.
        #expect(extras["conflict_observed"] == nil)
        #expect(extras["verify_restored"] == nil)
    }

    // MARK: - Cleanup-incomplete gate: State A requires clean cleanup

    /// A verified arm flip is NOT State A when Learn could not be restored — the
    /// host would be left dirty, so it fails closed naming the stuck cleanup.
    @Test func verifiedButLearnStuckIsNotStateA() throws {
        let fixture = Self.fixture(learnPress: .stickOn, verify: .verified)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "cleanup_incomplete")
        #expect(!failure.evidence.learnRestored)
        #expect(!failure.evidence.restored)
    }

    /// A verified arm flip is NOT State A when the Key Commands window could not be
    /// closed.
    @Test func verifiedButWindowStuckIsNotStateA() throws {
        let fixture = Self.fixture(closeRemovesWindow: false, verify: .verified)
        let outcome = Self.run(fixture)
        let failure = try #require(Self.failure(outcome))
        #expect(failure.stage == "cleanup_incomplete")
        #expect(!failure.evidence.closeConfirmed)
        #expect(!failure.evidence.restored)
    }

    // MARK: - Chord label rendering

    @Test func chordLabelRendersControlShiftE() {
        #expect(ArmKeyCommandSetup.chordLabel(keyCode: 14, modifiers: [.maskControl, .maskShift]) == "⌃⇧E")
    }

    @Test func chordLabelRendersAllModifiers() {
        let label = ArmKeyCommandSetup.chordLabel(
            keyCode: 15, modifiers: [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        )
        #expect(label == "⌃⌥⇧⌘R")
    }

    // MARK: - Dispatcher / server envelope mapping

    @Test func serverConsentGateReturnsConsentRequiredWithoutTrace() async throws {
        let server = LogicProServer()
        let handlers = await server.makeHandlers()
        let result = await handlers.callTool(.init(
            name: "logic_system",
            arguments: [
                "command": .string("setup_arm_key"),
                "params": .object(["consent": .string("false")]),
            ]
        ))
        guard case .text(let raw, _, _) = result.content.first,
              let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("expected a JSON text result")
            return
        }
        let error = try #require(object["error"] as? String)
        #expect(error == "consent_required")
        #expect(object["trace_id"] == nil)
    }

    @Test func dispatchAlreadyConfiguredEmitsStateAWithExistingMappingSource() async throws {
        let evidence = ArmKeyCommandSetup.Evidence(
            writeSource: .existingMappingVerify,
            verificationMutationAttempted: true,
            restored: true,
            armFlipObserved: true
        )
        let result = await SystemDispatcher.handle(
            command: "setup_arm_key",
            params: ["consent": .string("true")],
            router: ChannelRouter(),
            cache: StateCache(),
            armKeySetup: { _, _, _ in .alreadyConfigured(evidence: evidence) }
        )
        let object = try Self.jsonObject(result)
        #expect((object["state"] as? String) == "A")
        #expect((object["write_source"] as? String) == "existing_mapping_verify")
        let writeAttempted = try #require(object["configuration_write_attempted"] as? Bool)
        #expect(!writeAttempted)
        let isError = result.isError ?? false
        #expect(!isError)
    }

    @Test func dispatchConfiguredUnverifiedNeverClaimsAssigned() async throws {
        let result = await SystemDispatcher.handle(
            command: "setup_arm_key",
            params: ["consent": .string("true")],
            router: ChannelRouter(),
            cache: StateCache(),
            armKeySetup: { _, _, _ in
                .configuredUnverified(why: "no observed arm flip", evidence: ArmKeyCommandSetup.Evidence())
            }
        )
        let raw = try Self.jsonText(result)
        let object = try Self.jsonObject(result)
        #expect((object["state"] as? String) == "B")
        #expect(!raw.lowercased().contains("assigned;"))
    }

    @Test func dispatchConfigInvalidSurfacesArmKeyConfigInvalid() async throws {
        let result = await SystemDispatcher.handle(
            command: "setup_arm_key",
            params: ["consent": .string("true")],
            router: ChannelRouter(),
            cache: StateCache(),
            armKeySetup: { _, _, _ in .configInvalid(hint: "custom keycode is not in the known-safe glyph map") }
        )
        let object = try Self.jsonObject(result)
        #expect((object["state"] as? String) == "C")
        #expect((object["error"] as? String) == "arm_key_config_invalid")
        let writeAttempted = try #require(object["configuration_write_attempted"] as? Bool)
        #expect(!writeAttempted)
        let isError = try #require(result.isError)
        #expect(isError)
    }

    @Test func dispatchFailedSurfacesWriteAttempted() async throws {
        let evidence = ArmKeyCommandSetup.Evidence(
            writeSource: .guiAssignment,
            configurationWriteAttempted: true
        )
        let result = await SystemDispatcher.handle(
            command: "setup_arm_key",
            params: ["consent": .string("true")],
            router: ChannelRouter(),
            cache: StateCache(),
            armKeySetup: { _, _, _ in
                .failed(stage: "verify", hint: "the configured chord did not flip record-enable", evidence: evidence)
            }
        )
        let object = try Self.jsonObject(result)
        #expect((object["state"] as? String) == "C")
        #expect((object["error"] as? String) == "ax_write_failed")
        let writeAttempted = try #require(object["write_attempted"] as? Bool)
        #expect(writeAttempted)
    }

    // MARK: - Deadline override (LOGIC_PRO_MCP_SETUP_DEADLINE_MS)

    /// A valid positive-integer millisecond override parses to seconds; unset/empty
    /// falls back to the default deadline (never invalid).
    @Test func deadlineMsOverrideParsedAndApplied() {
        #expect(SystemDispatcher.parseSetupDeadlineOverride("8000") == .seconds(8.0))
        #expect(SystemDispatcher.parseSetupDeadlineOverride("  1500 ") == .seconds(1.5))
        #expect(SystemDispatcher.parseSetupDeadlineOverride(nil) == .unset)
        #expect(SystemDispatcher.parseSetupDeadlineOverride("") == .unset)
    }

    /// A malformed override (zero, negative, non-numeric, fractional, or overflow)
    /// is rejected — never a silent fallback — and the config-invalid envelope is a
    /// fail-closed State C with zero write attempted.
    @Test func deadlineMsMalformedFailsClosed() throws {
        for bad in ["0", "-5", "abc", "12.5", "99999999999999999999999999"] {
            #expect(SystemDispatcher.parseSetupDeadlineOverride(bad) == .invalid(bad))
        }
        let result = SystemDispatcher.setupArmDeadlineConfigInvalidResult(raw: "abc")
        let object = try Self.jsonObject(result)
        #expect((object["state"] as? String) == "C")
        #expect((object["stage"] as? String) == "setup_deadline_config_invalid")
        #expect((object["write_source"] as? String) == "none")
        let writeAttempted = try #require(object["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        let configWriteAttempted = try #require(object["configuration_write_attempted"] as? Bool)
        #expect(!configWriteAttempted)
    }

    private static func jsonText(_ result: CallTool.Result) throws -> String {
        guard case .text(let raw, _, _) = result.content.first else {
            throw NSError(domain: "arm-setup-test", code: 1)
        }
        return raw
    }

    private static func jsonObject(_ result: CallTool.Result) throws -> [String: Any] {
        let raw = try jsonText(result)
        let data = try #require(raw.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
