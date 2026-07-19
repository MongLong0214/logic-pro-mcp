@preconcurrency import ApplicationServices
import CoreGraphics
import MCP
import Testing
@testable import LogicProMCP

/// The live Key-Commands GUI automation itself is validated live (mocks cannot
/// reproduce real Logic KC behavior). These pin the mockable safety contract of
/// the LEAN flow: after the search filter is typed, the server DELIBERATELY does
/// NOT match the command element by its flat text and does NOT set AXSelected/
/// AXFocused on it, and it does NOT read the command's key-assignment back — live,
/// none of those are viable (the command element's text is doubled/elusive; the
/// only reliably readable text is the search field echoing the typed query).
/// Instead it trusts Logic to auto-select the single filtered result and proves
/// success FUNCTIONALLY via a real record-arm flip. The fake below models that:
/// an empty table shell plus flat command/assignment elements revealed by the
/// filter (present only so the RED-before assertions can show the OLD text-match /
/// selection / readback gates are gone), a search field that echoes the typed
/// query, Logic's modal reassignment alert for foreign chords, and an injected
/// arm-flip verifier that is the real success gate.
@Suite struct ArmKeyCommandSetupTests {
    private final class Probe: @unchecked Sendable {
        var chords: [(CGKeyCode, CGEventFlags)] = []
        var typed: [String] = []
        var verifyCalls = 0
        var frontmost = true
        var cancelled = false
        var learnPresses = 0
        var learnReadsAfterEnable = 0
    }

    private enum LearnPress {
        case toggle
        case stayUnknown
        case stickOn
        case unreadableAfterEnableThenRestore
    }

    private struct Fixture {
        let builder: FakeAXRuntimeBuilder
        let app: AXUIElement
        let window: AXUIElement
        let search: AXUIElement
        let learn: AXUIElement
        let commands: [AXUIElement]
        let probe: Probe
        let runtime: ArmKeyCommandSetup.Runtime
    }

    private static func fixture(
        commandValues: [String] = [ArmKeyCommandSetup.commandName],
        assignmentValues: [String] = [],
        learnValue: Int? = 0,
        learnPress: LearnPress = .toggle,
        focusSetSucceeds: Bool = true,
        frontmost: Bool = true,
        loseFrontmostAfterTyping: Bool = false,
        focusedKeyCommandsWindow: Bool = true,
        selectCommandSucceeds: Bool = true,
        postLearnAssignment: String? = "⌃⇧E",
        conflictAlertOnChord: Bool = false,
        cancelAfterLearnEnabled: Bool = false,
        closeRemovesWindow: Bool = true,
        verify: Bool? = nil
    ) -> Fixture {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(10_000)
        let window = builder.element(10_001)
        let search = builder.element(10_002)
        let learn = builder.element(10_003)
        let close = builder.element(10_004)
        // Live structure: flat command elements descend from an AXScrollArea; the
        // AXTable/AXColumn under it are EMPTY shells (ZERO rows) — present only to
        // prove the code never depends on an AXRow list.
        let scrollArea = builder.element(10_005)
        let table = builder.element(10_006)
        let column = builder.element(10_007)
        let otherWindow = builder.element(10_008)
        // Conflict/reassignment alert scaffolding (only attached to the window when
        // `conflictAlertOnChord` and the arm chord is posted).
        let alert = builder.element(10_009)
        let alertText = builder.element(10_010)
        let alertCancel = builder.element(10_011)
        let alertReassign = builder.element(10_012)
        let probe = Probe()
        probe.frontmost = frontmost

        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(
            app,
            kAXFocusedWindowAttribute as String,
            focusedKeyCommandsWindow ? window : otherWindow
        )
        builder.setAttribute(window, kAXTitleAttribute as String, "Key Commands")
        builder.setAttribute(window, "AXCloseButton", close)
        builder.setAttribute(scrollArea, kAXRoleAttribute as String, kAXScrollAreaRole as String)
        // Empty table shell — table.AXRows = 0, column.AXRows = 0 (matches live).
        builder.setAttribute(table, kAXRoleAttribute as String, kAXTableRole as String)
        builder.setAttribute(table, kAXRowsAttribute as String, [AXUIElement]())
        builder.setAttribute(column, kAXRoleAttribute as String, kAXColumnRole as String)
        builder.setAttribute(column, kAXRowsAttribute as String, [AXUIElement]())
        builder.setChildren(table, [column])
        builder.setChildren(column, [])
        builder.setAttribute(search, kAXRoleAttribute as String, kAXTextFieldRole as String)
        builder.setAttribute(search, kAXValueAttribute as String, "")
        builder.setAttribute(learn, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(learn, kAXTitleAttribute as String, ArmKeyCommandSetup.learnCheckboxTitle)
        if let learnValue {
            builder.setAttribute(learn, kAXValueAttribute as String, learnValue)
        }
        builder.setAttribute(alert, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(alertText, kAXRoleAttribute as String, kAXStaticTextRole as String)
        builder.setAttribute(alertCancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(alertCancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(alertReassign, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(alertReassign, kAXTitleAttribute as String, "Reassign")

        var commands: [AXUIElement] = []
        var assignments: [AXUIElement] = []
        for (offset, commandValue) in commandValues.enumerated() {
            let command = builder.element(10_100 + offset * 10)
            let assignment = builder.element(10_101 + offset * 10)
            // The command is a FLAT element (AXTextField), parent = scroll area,
            // NOT wrapped in an AXRow. Its assignment is a sibling flat element.
            builder.setAttribute(command, kAXRoleAttribute as String, kAXTextFieldRole as String)
            builder.setAttribute(command, kAXValueAttribute as String, commandValue)
            builder.setAttribute(command, kAXParentAttribute as String, scrollArea)
            builder.setAttribute(command, kAXSelectedAttribute as String, false)
            builder.setAttribute(assignment, kAXRoleAttribute as String, kAXStaticTextRole as String)
            builder.setAttribute(assignment, kAXParentAttribute as String, scrollArea)
            if assignmentValues.indices.contains(offset), !assignmentValues[offset].isEmpty {
                builder.setAttribute(assignment, kAXValueAttribute as String, assignmentValues[offset])
            }
            commands.append(command)
            assignments.append(assignment)
        }
        // Before typing: the flat command elements are NOT descendants (the
        // unfiltered ~2200-command list is not usefully readable), so only the
        // empty table shell is present. The search filter (typeText) reveals the
        // matching command + assignment AND makes the search field echo the typed
        // query — the cheap, live-readable "filter settled" signal the lean flow
        // relies on (in place of a flat text match / AXSelected readback).
        builder.setChildren(scrollArea, [table])
        builder.setChildren(window, [search, scrollArea, learn])
        let builtCommands = commands
        let builtAssignments = assignments

        let ax = builder.makeAXRuntime(
            appElement: app,
            attributeValueHandler: { element, attribute in
                if CFEqual(element, learn), attribute == (kAXValueAttribute as String),
                   cancelAfterLearnEnabled, probe.learnPresses == 1 {
                    probe.cancelled = true
                }
                guard CFEqual(element, learn), attribute == (kAXValueAttribute as String),
                      learnPress == .unreadableAfterEnableThenRestore,
                      probe.learnPresses == 1 else { return nil }
                probe.learnReadsAfterEnable += 1
                if probe.learnReadsAfterEnable == 1 {
                    return NSNumber(value: 1)
                }
                return .some(nil)
            },
            setAttributeHandler: { element, attribute, value in
                if CFEqual(element, search), attribute == (kAXFocusedAttribute as String),
                   !focusSetSucceeds {
                    return false
                }
                // Selection/focus of the flat command element can be forced to
                // fail. The lean flow NEVER sets these on the command element, so
                // this only trips the pre-rework code — the RED-before proof that
                // explicit selection is no longer required.
                if !selectCommandSucceeds,
                   builtCommands.contains(where: { CFEqual($0, element) }),
                   attribute == (kAXSelectedAttribute as String)
                       || attribute == (kAXFocusedAttribute as String) {
                    return false
                }
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
                    // Declining the reassignment dismisses the modal sheet.
                    builder.setAttribute(window, "AXSheets", [AXUIElement]())
                    return true
                }
                guard CFEqual(element, learn) else { return true }
                probe.learnPresses += 1
                switch learnPress {
                case .toggle:
                    let current = (builder.attributeValue(learn, kAXValueAttribute as String) as? Int) ?? 0
                    builder.setAttribute(learn, kAXValueAttribute as String, current == 0 ? 1 : 0)
                case .stayUnknown:
                    break
                case .stickOn:
                    builder.setAttribute(learn, kAXValueAttribute as String, 1)
                case .unreadableAfterEnableThenRestore:
                    builder.setAttribute(
                        learn,
                        kAXValueAttribute as String,
                        probe.learnPresses == 1 ? 1 : 0
                    )
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
                guard code == 14, flags == [.maskControl, .maskShift] else { return }
                if conflictAlertOnChord {
                    // Logic raises a modal reassignment alert because the chord is
                    // already owned by another command.
                    builder.setAttribute(
                        alertText, kAXValueAttribute as String,
                        "The key command ⌃⇧E is already assigned to another command. Reassign?"
                    )
                    builder.setChildren(alert, [alertText, alertCancel, alertReassign])
                    builder.setAttribute(window, "AXSheets", [alert])
                } else if let postLearnAssignment, let target = builtAssignments.first {
                    // Learn on a FREE chord makes the command's flat assignment
                    // element display the new chord. The lean flow does NOT read
                    // this back (the readback is not live-viable); it is modelled
                    // only so the RED-before proof can show the OLD readback gate
                    // is gone.
                    builder.setAttribute(target, kAXValueAttribute as String, postLearnAssignment)
                }
            },
            typeText: {
                probe.typed.append($0)
                if loseFrontmostAfterTyping { probe.frontmost = false }
                // Model Logic's live list filter: typing the command name (a) makes
                // the search field ECHO the query (the cheap "filter settled"
                // signal the lean flow polls for) and (b) collapses the window to
                // the matching FLAT command elements + assignments, revealed as
                // children of the scroll area — never as AXRows.
                builder.setAttribute(search, kAXValueAttribute as String, $0)
                let filter = $0
                var revealed: [AXUIElement] = [table]
                for (idx, commandValue) in commandValues.enumerated()
                where commandValue.range(of: filter, options: .caseInsensitive) != nil {
                    revealed.append(builtCommands[idx])
                    revealed.append(builtAssignments[idx])
                }
                builder.setChildren(scrollArea, revealed)
            },
            sleep: { _ in },
            isCancelled: { probe.cancelled },
            ax: ax,
            elements: elements,
            verifyArmFlip: { _, _ in probe.verifyCalls += 1; return verify }
        )
        return Fixture(
            builder: builder, app: app, window: window, search: search,
            learn: learn, commands: commands, probe: probe, runtime: runtime
        )
    }

    private static func failedStage(_ outcome: ArmKeyCommandSetup.Outcome) -> String? {
        guard case .failed(let stage, _, _) = outcome else { return nil }
        return stage
    }

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
            verifyArmFlip: { _, _ in trip(); return true }
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

    @Test func serverConsentGatePrecedesCacheMutationGateTraceAndSetup() async throws {
        let gate = LogicMutationGate()
        let held = try #require(gate.tryAcquire(operation: "test.foreign_write"))
        defer { gate.release(held) }
        let server = LogicProServer(mutationGate: gate)
        let cache = try #require(
            Mirror(reflecting: server).children.first(where: { $0.label == "cache" })?.value as? StateCache
        )
        let handlers = await server.makeHandlers()
        let beforeIdle = await cache.timeSinceLastToolAccess()
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

        #expect((object["error"] as? String)! == "consent_required")
        #expect(object["trace_id"] == nil)
        #expect(gate.currentOperation() == "test.foreign_write")
        #expect(await cache.timeSinceLastToolAccess() >= beforeIdle)
    }

    @Test func configuredUnverifiedNeverClaimsAssignment() async throws {
        let result = await SystemDispatcher.handle(
            command: "setup_arm_key",
            params: ["consent": .string("true")],
            router: ChannelRouter(),
            cache: StateCache(),
            armKeySetup: { _, _, _ in
                .configuredUnverified(why: "no observed arm flip")
            }
        )
        guard case .text(let raw, _, _) = result.content.first,
              let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("expected a JSON text result")
            return
        }

        #expect((object["state"] as? String)! == "B")
        #expect(!raw.lowercased().contains("assigned"))
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

    // MARK: - Success is gated on the functional arm-flip (not readback/selection)

    /// RED before the rework: the pre-rework code required the flat command to be
    /// found by an exact text match, so with NO command element revealed by the
    /// filter it failed closed at `command_identity` before any chord. The lean
    /// flow does not match the command by text — it trusts Logic to auto-select
    /// the single filtered result and proves success via the injected arm-flip.
    @Test func succeedsWithoutFlatCommandTextMatchViaFunctionalVerify() {
        let fixture = Self.fixture(commandValues: [], verify: true)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(outcome == .configuredAndVerified)
        #expect(fixture.probe.typed == [ArmKeyCommandSetup.commandName])
        #expect(fixture.probe.chords.contains { $0.0 == 14 && $0.1 == [.maskControl, .maskShift] })
        #expect(fixture.probe.verifyCalls == 1)
    }

    /// RED before the rework: the pre-rework code set AXSelected/AXFocused on the
    /// flat command element and failed closed at `command_selection` if neither
    /// took. The lean flow never selects the command explicitly, so a command that
    /// refuses selection still succeeds — the arm-flip is the real target gate.
    @Test func explicitCommandSelectionIsNoLongerRequired() {
        let fixture = Self.fixture(selectCommandSucceeds: false, verify: true)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(outcome == .configuredAndVerified)
        #expect(fixture.probe.chords.contains { $0.0 == 14 && $0.1 == [.maskControl, .maskShift] })
    }

    /// RED before the rework: the pre-rework code read the command's key-assignment
    /// back by text and required it to show the exact chord (`post_learn_ownership`)
    /// before claiming success. Live, that readback is not viable. The lean flow
    /// drops it: even when Logic surfaces NO readable assignment, the functional
    /// arm-flip alone proves (and gates) success.
    @Test func functionalArmFlipReplacesAssignmentReadback() {
        let fixture = Self.fixture(postLearnAssignment: nil, verify: true)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(outcome == .configuredAndVerified)
        #expect(fixture.probe.verifyCalls == 1)
    }

    /// RED before the rework: the pre-rework code read the target's existing
    /// assignment and refused to rebind a command that already showed a DIFFERENT
    /// chord (`assignment_conflict`). The lean flow does not read it back — Learn
    /// simply (re)binds the auto-selected command to our chord and the arm-flip
    /// confirms it. (Stealing another command's chord is still caught by the
    /// conflict alert; see `foreignChordConflictAlertIsDeclinedAndFailsClosed`.)
    @Test func previouslyAssignedCommandIsReboundAndVerified() {
        let fixture = Self.fixture(assignmentValues: ["⌘R"], verify: true)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(outcome == .configuredAndVerified)
        #expect(fixture.probe.chords.contains { $0.0 == 14 && $0.1 == [.maskControl, .maskShift] })
    }

    /// The filter is applied (the command name is typed) as a precondition of
    /// engaging Learn, and on a free chord (no conflict alert) the flow proceeds to
    /// the arm-flip verify and succeeds.
    @Test func searchFilterIsTypedThenAssignmentSucceeds() {
        let fixture = Self.fixture(verify: true)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(outcome == .configuredAndVerified)
        #expect(fixture.probe.typed == [ArmKeyCommandSetup.commandName])
        #expect(!fixture.probe.chords.isEmpty)
    }

    /// On a FREE chord Logic raises no modal, so the flow proceeds to the arm-flip
    /// verify → configuredAndVerified. No conflict alert is ever created.
    @Test func freeChordProceedsWhenNoConflictAlertAppears() {
        let fixture = Self.fixture(verify: true)   // conflictAlertOnChord defaults false
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(outcome == .configuredAndVerified)
        #expect(fixture.probe.chords.contains { $0.0 == 14 && $0.1 == [.maskControl, .maskShift] })
        #expect(fixture.probe.verifyCalls == 1)
        let sheets = fixture.builder.attributeValue(fixture.window, "AXSheets") as? [AXUIElement]
        #expect(sheets == nil || sheets!.isEmpty)
    }

    @Test func defaultVerifierCannotFabricateConfiguredSuccess() {
        let fixture = Self.fixture()
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        guard case .configuredUnverified = outcome else {
            Issue.record("the default fake verifier must not mechanically produce configuredAndVerified")
            return
        }
        #expect(fixture.probe.verifyCalls == 1)
    }

    // MARK: - Learn gate (the chord is never sent unless Learn is observed on)

    @Test func unreadableLearnStateFailsClosedBeforeChord() {
        let fixture = Self.fixture(learnValue: nil, learnPress: .stayUnknown)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(Self.failedStage(outcome) == "learn_state_unreadable")
        #expect(fixture.probe.chords.isEmpty)
    }

    @Test func learnMustBeObservedOnBeforeChord() {
        let fixture = Self.fixture(learnPress: .stayUnknown)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(Self.failedStage(outcome)! == "learn_enable")
        #expect(fixture.probe.chords.isEmpty)
    }

    @Test func learnRestoreMustBeObserved() {
        let fixture = Self.fixture(learnPress: .stickOn)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(Self.failedStage(outcome)! == "learn_restore")
        #expect((AXHelpers.getValue(fixture.learn, runtime: fixture.runtime.ax) as? NSNumber)!.boolValue)
        #expect(ArmKeyCommandSetup.keyCommandsWindow(runtime: fixture.runtime) == nil)
    }

    @Test func learnInitiallyOnIsRestoredOn() {
        let fixture = Self.fixture(learnValue: 1, verify: true)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(outcome == .configuredAndVerified)
        #expect((AXHelpers.getValue(fixture.learn, runtime: fixture.runtime.ax) as? NSNumber)!.boolValue)
    }

    @Test func learnEnabledBySetupIsRestoredWhenItBecomesUnreadable() {
        let fixture = Self.fixture(learnPress: .unreadableAfterEnableThenRestore)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(Self.failedStage(outcome)! == "learn_state_unreadable")
        #expect((fixture.builder.attributeValue(fixture.learn, kAXValueAttribute as String) as? NSNumber)?.boolValue == false)
        #expect(fixture.probe.chords.isEmpty)
        #expect(ArmKeyCommandSetup.keyCommandsWindow(runtime: fixture.runtime) == nil)
    }

    // MARK: - Focus / frontmost gates (never post a chord to the wrong surface)

    @Test func searchFocusMustBeObservedBeforeTyping() {
        let fixture = Self.fixture(focusSetSucceeds: false)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(Self.failedStage(outcome)! == "search_focus")
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.chords.isEmpty)
    }

    @Test func LogicMustBeFrontmostBeforeTyping() {
        let fixture = Self.fixture(frontmost: false)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(Self.failedStage(outcome)! == "logic_not_frontmost")
        #expect(fixture.probe.typed.isEmpty)
        #expect(fixture.probe.chords.isEmpty)
    }

    @Test func LogicMustRemainFrontmostBeforeAssignmentChord() {
        let fixture = Self.fixture(loseFrontmostAfterTyping: true)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(Self.failedStage(outcome)! == "logic_not_frontmost")
        #expect(fixture.probe.typed == [ArmKeyCommandSetup.commandName])
        #expect(fixture.probe.chords.isEmpty)
    }

    @Test func assignmentChordRequiresFocusedKeyCommandsWindow() {
        let fixture = Self.fixture(focusedKeyCommandsWindow: false)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(Self.failedStage(outcome) == "key_commands_not_focused")
        #expect(fixture.probe.chords.isEmpty)
    }

    @Test func keyCommandsWindowCloseMustBeObserved() {
        let fixture = Self.fixture(closeRemovesWindow: false)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(Self.failedStage(outcome)! == "close_key_commands")
        #expect(ArmKeyCommandSetup.keyCommandsWindow(runtime: fixture.runtime) != nil)
        #expect(fixture.probe.verifyCalls == 0)
        #expect((fixture.builder.attributeValue(fixture.learn, kAXValueAttribute as String) as? NSNumber)?.boolValue == false)
    }

    // MARK: - Foreign-chord conflict alert → fail closed (no steal)

    /// The chord is foreign-owned, so Logic raises a modal reassignment alert
    /// AFTER Learn posts the chord. The flow must DECLINE it (never confirm — that
    /// steals the chord), fail closed at `foreign_chord_owner`, restore Learn, and
    /// close the window. Because the chord WAS posted (that is how Logic surfaces
    /// the conflict) writeAttempted is true and the chord list is non-empty — but
    /// no ownership is claimed and no live verification runs.
    @Test func foreignChordConflictAlertIsDeclinedAndFailsClosed() {
        let fixture = Self.fixture(conflictAlertOnChord: true, verify: true)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        guard case .failed(let stage, _, let writeAttempted) = outcome else {
            Issue.record("expected a foreign-chord .failed; got \(outcome)")
            return
        }
        #expect(stage == "foreign_chord_owner")
        // The chord was posted (Logic surfaced the conflict), so the mutation was
        // attempted — but the reassignment was declined, not confirmed.
        #expect(!fixture.probe.chords.isEmpty)
        #expect(writeAttempted)
        #expect(fixture.probe.verifyCalls == 0)
        // Learn restored off, alert dismissed, window closed.
        #expect((fixture.builder.attributeValue(fixture.learn, kAXValueAttribute as String) as? NSNumber)!.boolValue == false)
        let sheets = fixture.builder.attributeValue(fixture.window, "AXSheets") as? [AXUIElement]
        #expect(sheets == nil || sheets!.isEmpty)
        #expect(ArmKeyCommandSetup.keyCommandsWindow(runtime: fixture.runtime) == nil)
    }

    // MARK: - Cancellation

    @Test func deadlineCancellationRestoresLearnAndClosesWindow() {
        let fixture = Self.fixture(cancelAfterLearnEnabled: true)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        #expect(Self.failedStage(outcome) == "deadline")
        #expect(fixture.probe.chords.isEmpty)
        #expect((fixture.builder.attributeValue(fixture.learn, kAXValueAttribute as String) as? NSNumber)?.boolValue == false)
        #expect(ArmKeyCommandSetup.keyCommandsWindow(runtime: fixture.runtime) == nil)
    }

    // MARK: - P1: no-steal hard gate for unmapped/custom keycodes

    @Test func knownSafeChordKeyCodeCoversDefaultButNotCustomCodes() {
        // The shipped default (Ctrl+Shift+E = 14) and the documented R override
        // (15) render to known glyphs; an arbitrary custom keycode does not.
        #expect(ArmKeyCommandSetup.isKnownSafeChordKeyCode(14))
        #expect(ArmKeyCommandSetup.isKnownSafeChordKeyCode(15))
        #expect(!ArmKeyCommandSetup.isKnownSafeChordKeyCode(40))
    }

    /// keyCode 40 ('K') is NOT in the known-safe glyph map, so a conflict with an
    /// existing command cannot be reasoned about; the no-steal hard gate must
    /// refuse up front with a typed config error and post NO chord — before opening
    /// the window.
    @Test func customUnmappedForeignOwnedChordRefusesBeforeAnyChord() {
        let fixture = Self.fixture(
            commandValues: [ArmKeyCommandSetup.commandName, "Open Recording Settings"],
            assignmentValues: ["", "⌃⇧K"]
        )
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 40, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        guard case .configInvalid = outcome else {
            Issue.record("expected .configInvalid for an unmapped keyCode; got \(outcome)")
            return
        }
        // The whole point of the gate: NOT ONE key was posted (no steal).
        #expect(fixture.probe.chords.isEmpty)
        #expect(fixture.probe.typed.isEmpty)
    }

    @Test func customUnmappedChordDispatchSurfacesArmKeyConfigInvalid() async throws {
        let result = await SystemDispatcher.handle(
            command: "setup_arm_key",
            params: ["consent": .string("true")],
            router: ChannelRouter(),
            cache: StateCache(),
            armKeySetup: { _, _, _ in
                .configInvalid(hint: "custom keycode is not in the known-safe glyph map")
            }
        )
        guard case .text(let raw, _, _) = result.content.first,
              let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("expected a JSON text result")
            return
        }

        #expect((object["state"] as? String)! == "C")
        #expect((object["error"] as? String)! == "arm_key_config_invalid")
        #expect(!((object["write_attempted"] as? Bool)!))
        #expect(result.isError!)
    }

    // MARK: - P3: write_attempted honesty

    /// A failure AFTER the assignment chord was posted must report
    /// writeAttempted=true so the State C envelope honestly says Logic's Key
    /// Commands surface was already mutated. Here the chord is sent (writeAttempted
    /// flips true) and the functional arm-flip then fails to flip → fail closed at
    /// `verify` with writeAttempted true (telemetry only — not a success).
    @Test func postMutationFailureReportsWriteAttemptedTrue() {
        let fixture = Self.fixture(verify: false)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        guard case .failed(let stage, _, let writeAttempted) = outcome else {
            Issue.record("expected a post-mutation .failed; got \(outcome)")
            return
        }
        #expect(stage == "verify")
        // The chord WAS posted before the failure — the mutation happened.
        #expect(!fixture.probe.chords.isEmpty)
        #expect(writeAttempted)
    }

    /// A failure BEFORE any Learn toggle / chord (here the search field never
    /// observes focus) must report writeAttempted=false — nothing was mutated.
    @Test func preMutationFailureReportsWriteAttemptedFalse() {
        let fixture = Self.fixture(focusSetSucceeds: false)
        let outcome = ArmKeyCommandSetup.run(
            consent: true, keyCode: 14, modifiers: [.maskControl, .maskShift], runtime: fixture.runtime
        )

        guard case .failed(let stage, _, let writeAttempted) = outcome else {
            Issue.record("expected a pre-mutation .failed; got \(outcome)")
            return
        }
        #expect(stage == "search_focus")
        #expect(fixture.probe.chords.isEmpty)
        #expect(!writeAttempted)
    }

    @Test func postMutationFailureDispatchSurfacesWriteAttemptedTrue() async throws {
        let result = await SystemDispatcher.handle(
            command: "setup_arm_key",
            params: ["consent": .string("true")],
            router: ChannelRouter(),
            cache: StateCache(),
            armKeySetup: { _, _, _ in
                .failed(
                    stage: "verify",
                    hint: "the configured chord did not produce and restore an observed record-arm flip",
                    writeAttempted: true
                )
            }
        )
        guard case .text(let raw, _, _) = result.content.first,
              let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("expected a JSON text result")
            return
        }

        #expect((object["state"] as? String)! == "C")
        #expect((object["error"] as? String)! == "ax_write_failed")
        #expect((object["write_attempted"] as? Bool)!)
    }
}
