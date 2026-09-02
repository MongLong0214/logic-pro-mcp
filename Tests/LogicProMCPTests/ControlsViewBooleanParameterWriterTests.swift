@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("ADR-011 / ADR-018 Controls-view Boolean parameters")
struct ControlsViewBooleanParameterWriterTests {
    @Test func rowStaticTextLabelBindsToItsSingleCheckbox() {
        let fixture = fixture(label: "Limiter On", controlRoles: [kAXCheckBoxRole as String])
        let result = ControlsViewBooleanParameterWriter.locate(
            label: "Limiter On",
            in: fixture.window,
            runtime: fixture.runtime
        )

        let resolved: Bool
        if case .found(.checkBox) = result {
            resolved = true
        } else {
            resolved = false
        }
        #expect(resolved)
    }

    @Test func rowWithTwoCandidateControlsRefusesWithoutTraversalOrder() {
        let fixture = fixture(
            label: "Limiter On",
            controlRoles: [kAXCheckBoxRole as String, kAXSliderRole as String]
        )
        let result = ControlsViewBooleanParameterWriter.locate(
            label: "Limiter On",
            in: fixture.window,
            runtime: fixture.runtime
        )

        let refused: Bool
        if case .refused(.controlAmbiguous) = result {
            refused = true
        } else {
            refused = false
        }
        #expect(refused)
    }

    @Test func rowWithoutAXStaticTextLabelRefuses() {
        let fixture = fixture(label: nil, controlRoles: [kAXCheckBoxRole as String])
        let result = ControlsViewBooleanParameterWriter.locate(
            label: "Limiter On",
            in: fixture.window,
            runtime: fixture.runtime
        )

        let refused: Bool
        if case .refused(.rowLabelMissing) = result {
            refused = true
        } else {
            refused = false
        }
        #expect(refused)
    }

    @Test func rowWithTwoCellsRefusesRatherThanBindingTheRow() {
        let fixture = fixture(label: "Limiter On", controlRoles: [kAXCheckBoxRole as String])
        let labelCell = fixture.builder.element(103)
        let controlCell = fixture.builder.element(104)
        let label = fixture.builder.element(105)
        let checkbox = fixture.builder.element(110)
        fixture.builder.setRole(controlCell, kAXCellRole as String)
        fixture.builder.setChildren(labelCell, [label])
        fixture.builder.setChildren(controlCell, [checkbox])
        fixture.builder.setChildren(fixture.builder.element(102), [labelCell, controlCell])

        let result = ControlsViewBooleanParameterWriter.locate(
            label: "Limiter On",
            in: fixture.window,
            runtime: fixture.runtime
        )
        let refused: Bool
        if case .refused(.rowStructureInvalid) = result {
            refused = true
        } else {
            refused = false
        }
        #expect(refused)
    }

    @Test func rowWithTwoNonemptyStaticTextLabelsRefuses() {
        let fixture = fixture(label: "Limiter On", controlRoles: [kAXCheckBoxRole as String])
        let secondLabel = fixture.builder.element(106)
        let cell = fixture.builder.element(103)
        fixture.builder.setRole(secondLabel, kAXStaticTextRole as String)
        fixture.builder.setAttribute(secondLabel, kAXValueAttribute as String, "Auto Release")
        fixture.builder.setChildren(cell, [fixture.builder.element(105), secondLabel, fixture.builder.element(110)])

        let result = ControlsViewBooleanParameterWriter.locate(
            label: "Limiter On",
            in: fixture.window,
            runtime: fixture.runtime
        )

        let refused: Bool
        if case .refused(.rowLabelAmbiguous) = result {
            refused = true
        } else {
            refused = false
        }
        #expect(refused)
    }

    @Test func AXRowsUnsupportedFallsBackToAXChildrenForTheLabelledRow() {
        let fixture = fixture(
            label: "Limiter On",
            controlRoles: [kAXCheckBoxRole as String],
            axRowsReadStatus: AXError.attributeUnsupported.rawValue
        )
        let result = ControlsViewBooleanParameterWriter.locate(
            label: "Limiter On",
            in: fixture.window,
            runtime: fixture.runtime
        )
        let found: Bool
        if case .found(.checkBox) = result {
            found = true
        } else {
            found = false
        }
        #expect(found)
    }

    @Test func AXRowsNoValueFallsBackToAXChildrenForTheLabelledRow() {
        let fixture = fixture(
            label: "Limiter On",
            controlRoles: [kAXCheckBoxRole as String],
            axRowsReadStatus: AXError.noValue.rawValue
        )
        let result = ControlsViewBooleanParameterWriter.locate(
            label: "Limiter On",
            in: fixture.window,
            runtime: fixture.runtime
        )
        let found: Bool
        if case .found(.checkBox) = result {
            found = true
        } else {
            found = false
        }
        #expect(found)
    }

    @Test func AXRowsReadFailureOtherThanAbsenceRefusesInsteadOfUsingChildren() {
        let fixture = fixture(
            label: "Limiter On",
            controlRoles: [kAXCheckBoxRole as String],
            axRowsReadStatus: AXError.cannotComplete.rawValue
        )
        let result = ControlsViewBooleanParameterWriter.locate(
            label: "Limiter On",
            in: fixture.window,
            runtime: fixture.runtime
        )
        let refused: Bool
        if case .refused(.accessibilityReadFailed) = result {
            refused = true
        } else {
            refused = false
        }
        #expect(refused)
    }

    @Test func secondControlWhoseRoleReadFailsRefusesTheWholeBinding() {
        let fixture = fixture(
            label: "Limiter On",
            controlRoles: [kAXCheckBoxRole as String, kAXButtonRole as String],
            roleReadFailureElementIDs: [111]
        )
        let result = ControlsViewBooleanParameterWriter.locate(
            label: "Limiter On",
            in: fixture.window,
            runtime: fixture.runtime
        )
        let refusedForUnreadableCandidate: Bool
        if case .refused(.accessibilityReadFailed) = result {
            refusedForUnreadableCandidate = true
        } else {
            refusedForUnreadableCandidate = false
        }
        #expect(refusedForUnreadableCandidate)
    }

    @Test func unreadableRoleWhileFilteringFallbackRowsRefusesTheWholeBinding() {
        let fixture = fixture(
            label: "Limiter On",
            controlRoles: [kAXCheckBoxRole as String],
            axRowsReadStatus: AXError.attributeUnsupported.rawValue,
            roleReadFailureElementIDs: [112]
        )
        let table = fixture.builder.element(101)
        let unreadableNonRow = fixture.builder.element(112)
        fixture.builder.setChildren(table, [fixture.builder.element(102), unreadableNonRow])

        let result = ControlsViewBooleanParameterWriter.locate(
            label: "Limiter On",
            in: fixture.window,
            runtime: fixture.runtime
        )

        let refusedForUnreadableFallbackRow: Bool
        if case .refused(.accessibilityReadFailed) = result {
            refusedForUnreadableFallbackRow = true
        } else {
            refusedForUnreadableFallbackRow = false
        }
        #expect(refusedForUnreadableFallbackRow)
    }

    @Test func unreadableRoleWhileFilteringCellsRefusesTheWholeBinding() {
        let fixture = fixture(
            label: "Limiter On",
            controlRoles: [kAXCheckBoxRole as String],
            roleReadFailureElementIDs: [113]
        )
        let row = fixture.builder.element(102)
        let unreadableNonCell = fixture.builder.element(113)
        fixture.builder.setChildren(row, [fixture.builder.element(103), unreadableNonCell])

        let result = ControlsViewBooleanParameterWriter.locate(
            label: "Limiter On",
            in: fixture.window,
            runtime: fixture.runtime
        )

        let refusedForUnreadableCell: Bool
        if case .refused(.accessibilityReadFailed) = result {
            refusedForUnreadableCell = true
        } else {
            refusedForUnreadableCell = false
        }
        #expect(refusedForUnreadableCell)
    }

    @Test func unchangedReadbackRefusesAndAttemptsOneRestore() {
        let builder = FakeAXRuntimeBuilder()
        let checkbox = builder.element(10)
        builder.setRole(checkbox, kAXCheckBoxRole as String)
        builder.setAttribute(checkbox, kAXValueAttribute as String, false)
        let runtime = builder.makeAXRuntime(appElement: builder.element(1))

        let result = ControlsViewBooleanParameterWriter.pressAndVerify(
            checkbox,
            requested: true,
            runtime: runtime
        )

        let refused = !result.verified
        let restoreAttempted = result.restoreAttempted
        let actionCount = builder.actionCalls.filter {
            $0.elementID == builder.elementID(checkbox)
                && $0.action == (kAXPressAction as String)
        }.count
        let attemptedExactlyPressAndRestore = actionCount == 2
        #expect(refused)
        #expect(restoreAttempted)
        #expect(attemptedExactlyPressAndRestore)
    }

    @Test func statusZeroPressWithUnchangedReadbackNeverReportsSuccess() {
        final class PressCount: @unchecked Sendable { var value = 0 }
        let count = PressCount()
        let builder = FakeAXRuntimeBuilder()
        let checkbox = builder.element(20)
        builder.setRole(checkbox, kAXCheckBoxRole as String)
        builder.setAttribute(checkbox, kAXValueAttribute as String, false)
        let runtime = builder.makeAXRuntime(
            appElement: builder.element(2),
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard element == checkbox, action == (kAXPressAction as String) else { return false }
                count.value += 1
                // Models AX status 0: it is accepted, but AXValue never moves.
                return true
            }
        )

        let result = ControlsViewBooleanParameterWriter.pressAndVerify(
            checkbox,
            requested: true,
            runtime: runtime
        )

        let refused = !result.verified
        let attemptedRestore = count.value == 2
        #expect(refused)
        #expect(attemptedRestore)
    }

    @Test func unreadableCheckboxValueRefusesBeforeAnyPress() {
        let builder = FakeAXRuntimeBuilder()
        let checkbox = builder.element(21)
        builder.setRole(checkbox, kAXCheckBoxRole as String)
        builder.setAttribute(checkbox, kAXValueAttribute as String, false)
        let runtime = builder.makeAXRuntime(
            appElement: builder.element(2),
            attributeValueHandler: { element, attribute in
                if CFEqual(element, checkbox), attribute == (kAXValueAttribute as String) {
                    return .some(nil)
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let result = ControlsViewBooleanParameterWriter.pressAndVerify(
            checkbox,
            requested: true,
            runtime: runtime
        )

        let valueReadRefusedTheWrite = !result.verified && !result.pressAttempted
        let noCheckboxActionWasSent = builder.actionCalls.isEmpty
        #expect(valueReadRefusedTheWrite)
        #expect(noCheckboxActionWasSent)
    }

    @Test func controlsViewSliderIsRefusedWithTheMeasuredNonactuationReason() {
        let fixture = fixture(label: "Gain", controlRoles: [kAXSliderRole as String])
        let result = ControlsViewBooleanParameterWriter.locate(
            label: "Gain",
            in: fixture.window,
            runtime: fixture.runtime
        )

        let refused: Bool
        if case .found(let control) = result,
           control.failure == .sliderNotActuable {
            refused = true
        } else {
            refused = false
        }
        #expect(refused)
    }

    @Test func controlsViewPopupIsRefusedAsUnmeasuredWithoutAMenuAction() {
        let fixture = fixture(label: "Circuit Type", controlRoles: [kAXPopUpButtonRole as String])
        let result = ControlsViewBooleanParameterWriter.locate(
            label: "Circuit Type",
            in: fixture.window,
            runtime: fixture.runtime
        )

        let refused: Bool
        if case .found(let control) = result,
           control.failure == .popupUnmeasured {
            refused = true
        } else {
            refused = false
        }
        let tookNoAction = fixture.builder.actionCalls.isEmpty
        #expect(refused)
        #expect(tookNoAction)
    }

    @Test func describedSlidersConfirmNativeEditorDespiteContradictoryTitle() {
        let fixture = viewFixture(entry: .editor, title: "컨트롤", behavior: .switchesStructure)

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .editor,
            in: fixture.window,
            runtime: fixture.runtime
        )

        let confirmed: Bool
        if case .ready = result {
            confirmed = true
        } else {
            confirmed = false
        }
        let titleWasNotNeeded = fixture.builder.actionCalls.isEmpty
        #expect(confirmed)
        #expect(titleWasNotNeeded)
    }

    @Test func describedEditorSliderWinsOverTheStrongestLabelControlTableShape() {
        let builder = FakeAXRuntimeBuilder()
        let window = builder.element(29_910)
        let switcher = builder.element(29_911)
        let slider = builder.element(29_912)
        let browserTable = builder.element(29_913)
        let browserRow = builder.element(29_914)
        let browserCell = builder.element(29_915)
        let browserTitle = builder.element(29_916)
        let browserCheckbox = builder.element(29_917)
        builder.setRole(window, kAXWindowRole as String)
        builder.setRole(switcher, kAXMenuButtonRole as String)
        builder.setAttribute(switcher, kAXDescriptionAttribute as String, "보기")
        builder.setRole(slider, kAXSliderRole as String)
        builder.setAttribute(slider, kAXDescriptionAttribute as String, "Threshold")
        builder.setRole(browserTable, kAXTableRole as String)
        builder.setRole(browserRow, kAXRowRole as String)
        builder.setRole(browserCell, kAXCellRole as String)
        builder.setRole(browserTitle, kAXStaticTextRole as String)
        builder.setAttribute(browserTitle, kAXValueAttribute as String, "Limiter On")
        builder.setRole(browserCheckbox, kAXCheckBoxRole as String)
        builder.setAttribute(browserCheckbox, kAXValueAttribute as String, false)
        builder.setChildren(browserCell, [browserTitle, browserCheckbox])
        builder.setChildren(browserRow, [browserCell])
        builder.setChildren(browserTable, [browserRow])
        builder.setAttribute(browserTable, kAXRowsAttribute as String, [browserRow])
        builder.setChildren(window, [switcher, slider, browserTable])

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .editor,
            in: window,
            runtime: builder.makeAXRuntime(appElement: builder.element(29_900))
        )
        let confirmedEditor: Bool
        if case .ready = result {
            confirmedEditor = true
        } else {
            confirmedEditor = false
        }
        #expect(confirmedEditor)
    }

    @Test func failedSwitcherCensusRefusesBeforeItCanChooseASwitcherToPress() {
        let readFailure = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let fixture = viewFixture(
            entry: .editor,
            title: "편집기",
            behavior: .switchesStructure,
            readFailure: .switcherCensus
        )

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls,
            in: fixture.window,
            runtime: fixture.runtime
        )
        let refusedForCensusRead: Bool
        if case let .refused(.viewEvidenceReadFailed(.switcherCensus(observed)), restoration: nil) = result {
            refusedForCensusRead = observed == readFailure
        } else {
            refusedForCensusRead = false
        }
        #expect(refusedForCensusRead)
    }

    @Test func failedSwitcherDescriptionRefusesBeforeItCanChooseASwitcherToPress() {
        let readFailure = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let fixture = viewFixture(
            entry: .editor,
            title: "편집기",
            behavior: .switchesStructure,
            readFailure: .switcherDescription
        )

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls,
            in: fixture.window,
            runtime: fixture.runtime
        )
        let refusedForDescriptionRead: Bool
        if case let .refused(.viewEvidenceReadFailed(.switcherDescription(observed)), restoration: nil) = result {
            refusedForDescriptionRead = observed == readFailure
        } else {
            refusedForDescriptionRead = false
        }
        #expect(refusedForDescriptionRead)
    }

    @Test func failedSliderCensusDoesNotRefuseEditorConfirmedByNoTable() {
        let fixture = viewFixture(
            entry: .editor,
            title: "편집기",
            behavior: .switchesStructure,
            readFailure: .sliderCensus
        )

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .editor,
            in: fixture.window,
            runtime: fixture.runtime
        )
        let editorWasConfirmed: Bool
        if case .ready = result {
            editorWasConfirmed = true
        } else {
            editorWasConfirmed = false
        }
        #expect(editorWasConfirmed)
    }

    @Test func failedSliderDescriptionDoesNotRefuseControlsConfirmedByTable() {
        let fixture = viewFixture(
            entry: .editor,
            title: "편집기",
            behavior: .switchesStructure,
            readFailure: .sliderDescription,
            includeControlsTableBesideEditor: true
        )

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls,
            in: fixture.window,
            runtime: fixture.runtime
        )
        let controlsWereConfirmed: Bool
        if case .ready = result {
            controlsWereConfirmed = true
        } else {
            controlsWereConfirmed = false
        }
        let tableConfirmedTheAlreadySelectedView = fixture.builder.actionCalls.isEmpty
        #expect(controlsWereConfirmed)
        #expect(tableConfirmedTheAlreadySelectedView)
    }

    @Test func allDescriptionFailuresDoNotRefuseControlsConfirmedByTheTable() {
        let fixture = viewFixture(
            entry: .controls,
            title: "컨트롤",
            behavior: .switchesStructure,
            allDescriptionReadsFail: true
        )

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls,
            in: fixture.window,
            runtime: fixture.runtime
        )

        let controlsWereConfirmed: Bool
        if case .ready = result {
            controlsWereConfirmed = true
        } else {
            controlsWereConfirmed = false
        }
        let tableConfirmedTheAlreadySelectedView = fixture.builder.actionCalls.isEmpty
        #expect(controlsWereConfirmed)
        #expect(tableConfirmedTheAlreadySelectedView)
    }

    @Test func allDescriptionFailuresDoNotRefuseEditorConfirmedByNoTable() {
        let fixture = viewFixture(
            entry: .editor,
            title: "편집기",
            behavior: .switchesStructure,
            allDescriptionReadsFail: true
        )

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .editor,
            in: fixture.window,
            runtime: fixture.runtime
        )

        let editorWasConfirmed: Bool
        if case .ready = result {
            editorWasConfirmed = true
        } else {
            editorWasConfirmed = false
        }
        let missingTableConfirmedTheAlreadySelectedView = fixture.builder.actionCalls.isEmpty
        #expect(editorWasConfirmed)
        #expect(missingTableConfirmedTheAlreadySelectedView)
    }

    @Test func describedSliderConfirmsEditorAfterAnotherDescriptionReadFails() {
        let fixture = viewFixture(
            entry: .editor,
            title: "편집기",
            behavior: .switchesStructure,
            includeControlsTableBesideEditor: true,
            additionalSliderDescriptionFailure: true
        )

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .editor,
            in: fixture.window,
            runtime: fixture.runtime
        )

        let editorWasConfirmed: Bool
        if case .ready = result {
            editorWasConfirmed = true
        } else {
            editorWasConfirmed = false
        }
        let describedSliderConfirmedTheAlreadySelectedView = fixture.builder.actionCalls.isEmpty
        #expect(editorWasConfirmed)
        #expect(describedSliderConfirmedTheAlreadySelectedView)
    }

    @Test func failedViewMenuItemCensusRefusesInsteadOfReportingMissingItem() {
        let readFailure = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let fixture = viewFixture(
            entry: .editor,
            title: "편집기",
            behavior: .switchesStructure,
            readFailure: .menuItemCensus
        )

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls,
            in: fixture.window,
            runtime: fixture.runtime
        )
        let refusedForMenuItemCensusRead: Bool
        if case let .refused(.viewEvidenceReadFailed(.menuItemCensus(observed)), restoration: nil) = result {
            refusedForMenuItemCensusRead = observed == readFailure
        } else {
            refusedForMenuItemCensusRead = false
        }
        #expect(refusedForMenuItemCensusRead)
    }

    @Test func failedControlsTableCensusLeavesTheEntryViewUnconfirmed() {
        let fixture = viewFixture(
            entry: .controls,
            title: "컨트롤",
            behavior: .switchesStructure,
            readFailure: .tableCensus
        )

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls,
            in: fixture.window,
            runtime: fixture.runtime
        )
        let entryViewWasUnconfirmed: Bool
        if case .refused(.entryViewNotConfirmed, restoration: nil) = result {
            entryViewWasUnconfirmed = true
        } else {
            entryViewWasUnconfirmed = false
        }
        #expect(entryViewWasUnconfirmed)
    }

    @Test func failedControlsRowReadLeavesTheTableUnconfirmed() {
        let builder = FakeAXRuntimeBuilder()
        let window = builder.element(29_930)
        let switcher = builder.element(29_931)
        let table = builder.element(29_932)
        let unreadableRow = builder.element(29_933)
        let readFailure = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        builder.setRole(window, kAXWindowRole as String)
        builder.setRole(switcher, kAXMenuButtonRole as String)
        builder.setAttribute(switcher, kAXDescriptionAttribute as String, "보기")
        builder.setRole(table, kAXTableRole as String)
        // Keep the AXRows-only row outside AXChildren so the three preceding
        // censuses complete; this isolates the classifier's row loop.
        builder.setAttribute(table, kAXRowsAttribute as String, [unreadableRow])
        builder.setChildren(window, [switcher, table])
        let runtime = builder.makeAXRuntime(
            appElement: builder.element(29_900),
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, unreadableRow), attribute == (kAXRoleAttribute as String) {
                    return .failure(readFailure)
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls,
            in: window,
            runtime: runtime
        )
        let entryViewWasUnconfirmed: Bool
        if case .refused(.entryViewNotConfirmed, restoration: nil) = result {
            entryViewWasUnconfirmed = true
        } else {
            entryViewWasUnconfirmed = false
        }
        #expect(entryViewWasUnconfirmed)
    }

    @Test func tableWhoseRowsCarryNoLabelControlPairDoesNotConfirmControls() {
        let builder = FakeAXRuntimeBuilder()
        let window = builder.element(29_920)
        let switcher = builder.element(29_921)
        let table = builder.element(29_922)
        let row = builder.element(29_923)
        let cell = builder.element(29_924)
        let heading = builder.element(29_925)
        builder.setRole(window, kAXWindowRole as String)
        builder.setRole(switcher, kAXMenuButtonRole as String)
        builder.setAttribute(switcher, kAXDescriptionAttribute as String, "보기")
        builder.setRole(table, kAXTableRole as String)
        builder.setRole(row, kAXRowRole as String)
        builder.setRole(cell, kAXCellRole as String)
        builder.setRole(heading, kAXStaticTextRole as String)
        builder.setAttribute(heading, kAXValueAttribute as String, "Dynamics")
        builder.setChildren(cell, [heading])
        builder.setChildren(row, [cell])
        builder.setChildren(table, [row])
        builder.setAttribute(table, kAXRowsAttribute as String, [row])
        builder.setChildren(window, [switcher, table])

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls,
            in: window,
            runtime: builder.makeAXRuntime(appElement: builder.element(29_900))
        )
        let refusedBecauseTheTableCannotProveControls: Bool
        if case .refused(.entryViewNotConfirmed, restoration: nil) = result {
            refusedBecauseTheTableCannotProveControls = true
        } else {
            refusedBecauseTheTableCannotProveControls = false
        }
        #expect(refusedBecauseTheTableCannotProveControls)
    }

    @Test func controlsTableWithHeadingRowsAndParameterPairConfirmsControls() {
        let fixture = viewFixture(entry: .controls, title: "편집기", behavior: .switchesStructure)

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls,
            in: fixture.window,
            runtime: fixture.runtime
        )

        let confirmed: Bool
        if case .ready = result {
            confirmed = true
        } else {
            confirmed = false
        }
        let titleWasNotNeeded = fixture.builder.actionCalls.isEmpty
        #expect(confirmed)
        #expect(titleWasNotNeeded)
    }

    @Test func viewFixtureRequiresAXPressToRevealAndAXPickToSelect() {
        let fixture = viewFixture(entry: .editor, title: "편집기", behavior: .switchesStructure)
        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls,
            in: fixture.window,
            runtime: fixture.runtime
        )
        let confirmed: Bool
        if case .ready = result {
            confirmed = true
        } else {
            confirmed = false
        }
        let revealedWithPress = fixture.switcherActions.value == [kAXPressAction as String]
        let selectedWithPick = fixture.menuItemActions.value == [kAXPickAction as String]
        let menuWasPolledUntilVisible = fixture.menuCensusPolls.value > 1
        #expect(confirmed)
        #expect(revealedWithPress)
        #expect(selectedWithPick)
        #expect(menuWasPolledUntilVisible)
    }

    @Test func switchThatNeverChangesStructureRefusesWithinDeadlineAndLeavesEntryView() {
        let fixture = viewFixture(
            entry: .controls,
            title: "[100%]",
            behavior: .neverChanges,
            menuRevealAfterPolls: 3
        )
        let started = Date()

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .editor,
            in: fixture.window,
            confirmationTimeout: 0.025,
            runtime: fixture.runtime
        )

        let refused: Bool
        if case .refused(.viewStructureDidNotConfirm(.editor), restoration: _) = result {
            refused = true
        } else {
            refused = false
        }
        // Menu appearance is now the measured ~150 ms on both the attempted
        // switch and its compensating restoration; this remains a bounded
        // deadline test rather than an instant-fixture timing test.
        let completedWithinBoundedRestore = Date().timeIntervalSince(started) < 0.75
        let attemptedEditorSelection = fixture.editorSelections.value == 1
        let entryStructureRemainedControls = controlsStructureIsPresent(fixture)
        #expect(refused)
        #expect(completedWithinBoundedRestore)
        #expect(attemptedEditorSelection)
        #expect(entryStructureRemainedControls)
    }

    @Test func menuThatNeverAppearsRefusesWithTheAppearanceDeadline() {
        let fixture = viewFixture(
            entry: .editor,
            title: "[100%]",
            behavior: .switchesStructure,
            menuRevealAfterPolls: nil
        )

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls,
            in: fixture.window,
            menuAppearanceTimeout: 0.025,
            runtime: fixture.runtime
        )

        let refusedForAppearanceDeadline: Bool
        if case .refused(.viewMenuDidNotAppearBeforeDeadline, restoration: _) = result {
            refusedForAppearanceDeadline = true
        } else {
            refusedForAppearanceDeadline = false
        }
        #expect(refusedForAppearanceDeadline)
    }

    @Test func unreadableMenuRefusesWithTheReadFailureRatherThanTheDeadline() {
        let readFailure = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let fixture = viewFixture(
            entry: .editor,
            title: "[100%]",
            behavior: .switchesStructure,
            menuReadFailure: readFailure
        )

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls,
            in: fixture.window,
            menuAppearanceTimeout: 0.025,
            runtime: fixture.runtime
        )

        let refusedForTheObservedReadFailure: Bool
        if case let .refused(.viewMenuReadFailed(observed), restoration: _) = result {
            refusedForTheObservedReadFailure = observed == readFailure
        } else {
            refusedForTheObservedReadFailure = false
        }
        #expect(refusedForTheObservedReadFailure)
    }

    @Test func slowerThanConfirmationDeadlineRefusesAndRestoresTheEntryView() {
        let fixture = viewFixture(
            entry: .controls,
            title: "[100%]",
            behavior: .switchesStructure,
            // Intentionally instant: this test isolates the 150 ms structure
            // settle from the separate menu-appearance deadline.
            menuRevealAfterPolls: 0,
            viewSettleDelay: 0.15
        )

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .editor,
            in: fixture.window,
            menuAppearanceTimeout: 0.025,
            confirmationTimeout: 0.025,
            runtime: fixture.runtime
        )

        let refusedForSettleDeadline: Bool
        if case .refused(.viewStructureDidNotConfirm(.editor), restoration: _) = result {
            refusedForSettleDeadline = true
        } else {
            refusedForSettleDeadline = false
        }
        Thread.sleep(forTimeInterval: 0.175)
        let entryStructureWasRestored = controlsStructureIsPresent(fixture)
        let restorationWasExplicitlySelected = fixture.controlsSelections.value == 1
        #expect(refusedForSettleDeadline)
        #expect(entryStructureWasRestored)
        #expect(restorationWasExplicitlySelected)
    }

    @Test func confirmedSwitchRestoresTheStructuralEntryView() {
        let fixture = viewFixture(entry: .controls, title: "[100%]", behavior: .switchesStructure)
        let result = ControlsViewBooleanParameterWriter.prepareView(
            .editor,
            in: fixture.window,
            runtime: fixture.runtime
        )
        let session: ControlsViewBooleanParameterWriter.ViewSession?
        if case let .ready(ready) = result {
            session = ready
        } else {
            session = nil
        }
        let prepared = session != nil
        #expect(prepared)
        guard let session else { return }

        let restoration = session.restore()
        let restorationConfirmed = restoration.confirmed
        let restoredControlsStructure = controlsStructureIsPresent(fixture)
        let selectedEditor = fixture.editorSelections.value == 1
        let restoredControls = fixture.controlsSelections.value == 1
        #expect(restorationConfirmed)
        #expect(restoredControlsStructure)
        #expect(selectedEditor)
        #expect(restoredControls)
    }

    @Test func unconfirmedSwitchRestoresTheStructuralEntryView() {
        let fixture = viewFixture(
            entry: .controls,
            title: "[100%]",
            behavior: .becomesUnconfirmedThenControlsRestores
        )

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .editor,
            in: fixture.window,
            confirmationTimeout: 0.025,
            runtime: fixture.runtime
        )

        let refused: Bool
        if case .refused(.viewStructureDidNotConfirm(.editor), restoration: _) = result {
            refused = true
        } else {
            refused = false
        }
        let restoredControlsStructure = controlsStructureIsPresent(fixture)
        let attemptedCompensatingControlsSelection = fixture.controlsSelections.value == 1
        #expect(refused)
        #expect(restoredControlsStructure)
        #expect(attemptedCompensatingControlsSelection)
    }

    @Test func compressorCatalogExposesOnlyTheTwoMeasuredCheckboxWrites() {
        let compressor = try! #require(
            StockPluginCatalog.entry(id: "logic.stock.effect.compressor")
        )
        let booleans = compressor.parameters.filter {
            $0.writeMethod == "ax_controls_view_checkbox_press"
        }
        let names = Set(booleans.map(\.displayName))
        let measuredNames = names == ["Limiter On", "Auto Release"]
        let allHaveLiveEvidence = booleans.allSatisfy {
            $0.availabilityState == .verified
                && $0.provenance.observedAt?.hasPrefix("2026-09-02") == true
                && !$0.provenance.evidence.isEmpty
        }
        #expect(measuredNames)
        #expect(allHaveLiveEvidence)
    }

    private enum ViewFixtureBehavior {
        case switchesStructure
        case neverChanges
        case becomesUnconfirmedThenControlsRestores
    }

    private enum ViewFixtureReadFailure {
        case switcherCensus
        case switcherDescription
        case sliderCensus
        case sliderDescription
        case menuItemCensus
        case tableCensus
    }

    private struct ViewFixture {
        let builder: FakeAXRuntimeBuilder
        let window: AXUIElement
        let controlsTable: AXUIElement
        let controlsSelections: MutableBox<Int>
        let editorSelections: MutableBox<Int>
        let switcherActions: MutableBox<[String]>
        let menuItemActions: MutableBox<[String]>
        let menuCensusPolls: MutableBox<Int>
        let runtime: AXHelpers.Runtime
    }

    private func viewFixture(
        entry: ControlsViewBooleanParameterWriter.PluginWindowView,
        title: String,
        behavior: ViewFixtureBehavior,
        menuRevealAfterPolls: Int? = 3,
        menuReadFailure: AXHelpers.AXStatusError? = nil,
        readFailure: ViewFixtureReadFailure? = nil,
        includeControlsTableBesideEditor: Bool = false,
        additionalSliderDescriptionFailure: Bool = false,
        allDescriptionReadsFail: Bool = false,
        viewSettleDelay: TimeInterval = 0.5
    ) -> ViewFixture {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(900)
        let window = builder.element(901)
        let switcher = builder.element(902)
        let menu = builder.element(903)
        let controlsMenuItem = builder.element(904)
        let editorMenuItem = builder.element(905)
        let editorSlider = builder.element(906)
        let additionalSlider = builder.element(916)
        let controlsTable = builder.element(907)
        let controlsRow = builder.element(908)
        let controlsLabelCell = builder.element(909)
        let controlsLabel = builder.element(911)
        let controlsCheckbox = builder.element(912)
        let controlsHeadingRow = builder.element(913)
        let controlsHeadingCell = builder.element(914)
        let controlsHeadingLabel = builder.element(915)
        let controlsSelections = MutableBox(0)
        let editorSelections = MutableBox(0)
        let switcherActions = MutableBox<[String]>([])
        let menuItemActions = MutableBox<[String]>([])
        let menuCensusPolls = MutableBox(0)
        let menuOpen = MutableBox(false)
        let menuVisible = MutableBox(false)
        let pendingWindowChildren = MutableBox<(children: [AXUIElement], settlesAt: Date)?>(nil)
        let sliderChildrenReadCount = MutableBox(0)
        let tableChildrenReadCount = MutableBox(0)
        let windowChildrenReadCount = MutableBox(0)
        let statusFailure = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)

        builder.setRole(window, kAXWindowRole as String)
        builder.setRole(switcher, kAXMenuButtonRole as String)
        builder.setAttribute(switcher, kAXDescriptionAttribute as String, "보기")
        builder.setAttribute(switcher, kAXTitleAttribute as String, title)
        builder.setRole(menu, kAXMenuRole as String)
        builder.setRole(controlsMenuItem, kAXMenuItemRole as String)
        builder.setAttribute(controlsMenuItem, kAXTitleAttribute as String, "컨트롤")
        builder.setRole(editorMenuItem, kAXMenuItemRole as String)
        builder.setAttribute(editorMenuItem, kAXTitleAttribute as String, "편집기")
        builder.setChildren(menu, [controlsMenuItem, editorMenuItem])

        builder.setRole(editorSlider, kAXSliderRole as String)
        builder.setAttribute(editorSlider, kAXDescriptionAttribute as String, "Threshold")
        if additionalSliderDescriptionFailure || allDescriptionReadsFail {
            builder.setRole(additionalSlider, kAXSliderRole as String)
        }
        builder.setRole(controlsTable, kAXTableRole as String)
        builder.setRole(controlsRow, kAXRowRole as String)
        builder.setRole(controlsLabelCell, kAXCellRole as String)
        builder.setRole(controlsLabel, kAXStaticTextRole as String)
        builder.setRole(controlsCheckbox, kAXCheckBoxRole as String)
        builder.setAttribute(controlsLabel, kAXValueAttribute as String, "Limiter On")
        builder.setAttribute(controlsCheckbox, kAXValueAttribute as String, false)
        builder.setChildren(controlsLabelCell, [controlsLabel, controlsCheckbox])
        builder.setChildren(controlsRow, [controlsLabelCell])
        builder.setRole(controlsHeadingRow, kAXRowRole as String)
        builder.setRole(controlsHeadingCell, kAXCellRole as String)
        builder.setRole(controlsHeadingLabel, kAXStaticTextRole as String)
        builder.setAttribute(controlsHeadingLabel, kAXValueAttribute as String, "Dynamics")
        builder.setChildren(controlsHeadingCell, [controlsHeadingLabel])
        builder.setChildren(controlsHeadingRow, [controlsHeadingCell])
        builder.setChildren(controlsTable, [controlsHeadingRow, controlsRow])
        builder.setAttribute(controlsTable, kAXRowsAttribute as String, [controlsHeadingRow, controlsRow])

        let slidersBeforeEditor = additionalSliderDescriptionFailure || allDescriptionReadsFail
            ? [additionalSlider]
            : []
        let editorChildren = includeControlsTableBesideEditor
            ? [switcher] + slidersBeforeEditor + [editorSlider, controlsTable]
            : [switcher] + slidersBeforeEditor + [editorSlider]
        let controlsChildren = [switcher] + slidersBeforeEditor + [controlsTable]
        builder.setChildren(
            window,
            entry == .editor ? editorChildren : controlsChildren
        )

        let controlsKey = builder.elementID(controlsMenuItem)
        let editorKey = builder.elementID(editorMenuItem)
        let switcherKey = builder.elementID(switcher)
        let runtime = builder.makeAXRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                if allDescriptionReadsFail,
                   attribute == (kAXDescriptionAttribute as String) {
                    return .failure(statusFailure)
                }
                if readFailure == .switcherDescription,
                   CFEqual(element, switcher),
                   attribute == (kAXDescriptionAttribute as String) {
                    return .failure(statusFailure)
                }
                if additionalSliderDescriptionFailure,
                   CFEqual(element, additionalSlider),
                   attribute == (kAXDescriptionAttribute as String) {
                    return .failure(statusFailure)
                }
                if readFailure == .sliderDescription,
                   CFEqual(element, editorSlider),
                   attribute == (kAXDescriptionAttribute as String) {
                    return .failure(statusFailure)
                }
                if readFailure == .menuItemCensus,
                   (CFEqual(element, controlsMenuItem) || CFEqual(element, editorMenuItem)),
                   attribute == (kAXTitleAttribute as String) {
                    return .failure(statusFailure)
                }
                return nil
            },
            childrenHandler: { element in
                if CFEqual(element, window),
                   let pending = pendingWindowChildren.value,
                   Date() >= pending.settlesAt {
                    builder.setChildren(window, pending.children)
                    pendingWindowChildren.value = nil
                }
                if CFEqual(element, switcher), menuOpen.value, menuVisible.value {
                    return [menu]
                }
                return nil
            },
            childrenResultHandler: { element in
                if CFEqual(element, window),
                   let pending = pendingWindowChildren.value,
                   Date() >= pending.settlesAt {
                    builder.setChildren(window, pending.children)
                    pendingWindowChildren.value = nil
                }
                if readFailure == .switcherCensus, CFEqual(element, window) {
                    windowChildrenReadCount.value += 1
                    if windowChildrenReadCount.value == 2 {
                        return .failure(statusFailure)
                    }
                }
                if readFailure == .sliderCensus, CFEqual(element, editorSlider) {
                    sliderChildrenReadCount.value += 1
                    if sliderChildrenReadCount.value == 2 {
                        return .failure(statusFailure)
                    }
                }
                if readFailure == .tableCensus, CFEqual(element, controlsTable) {
                    tableChildrenReadCount.value += 1
                    if tableChildrenReadCount.value == 2 {
                        return .failure(statusFailure)
                    }
                }
                guard CFEqual(element, switcher), menuOpen.value else { return nil }
                if let menuReadFailure {
                    return .failure(menuReadFailure)
                }
                guard let revealAfterPolls = menuRevealAfterPolls else {
                    return .success([])
                }
                if menuCensusPolls.value < max(0, revealAfterPolls) {
                    menuCensusPolls.value += 1
                    return .success([])
                }
                menuVisible.value = true
                return .success([menu])
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                let key = builder.elementID(element)
                if key == switcherKey {
                    switcherActions.value.append(action)
                    guard action == (kAXPressAction as String) else { return false }
                    menuOpen.value = true
                    menuVisible.value = false
                    menuCensusPolls.value = 0
                    return true
                }
                guard key == editorKey || key == controlsKey else { return true }
                menuItemActions.value.append(action)
                guard action == (kAXPickAction as String) else { return false }
                menuOpen.value = false
                menuVisible.value = false
                switch key {
                case editorKey:
                    editorSelections.value += 1
                    switch behavior {
                    case .switchesStructure:
                        pendingWindowChildren.value = (
                            children: editorChildren,
                            settlesAt: Date().addingTimeInterval(max(0, viewSettleDelay))
                        )
                    case .neverChanges:
                        break
                    case .becomesUnconfirmedThenControlsRestores:
                        pendingWindowChildren.value = (
                            children: [switcher],
                            settlesAt: Date().addingTimeInterval(max(0, viewSettleDelay))
                        )
                    }
                case controlsKey:
                    controlsSelections.value += 1
                    switch behavior {
                    case .switchesStructure, .becomesUnconfirmedThenControlsRestores:
                        pendingWindowChildren.value = (
                            children: controlsChildren,
                            settlesAt: Date().addingTimeInterval(max(0, viewSettleDelay))
                        )
                    case .neverChanges:
                        break
                    }
                default:
                    break
                }
                return true
            }
        )
        return ViewFixture(
            builder: builder,
            window: window,
            controlsTable: controlsTable,
            controlsSelections: controlsSelections,
            editorSelections: editorSelections,
            switcherActions: switcherActions,
            menuItemActions: menuItemActions,
            menuCensusPolls: menuCensusPolls,
            runtime: runtime
        )
    }

    private func controlsStructureIsPresent(_ fixture: ViewFixture) -> Bool {
        let visibleTables = AXHelpers.censusDescendant(
            of: fixture.window,
            role: kAXTableRole,
            maxDepth: 8,
            runtime: fixture.runtime
        ).matches
        let describedSliders = AXHelpers.censusDescendant(
            of: fixture.window,
            role: kAXSliderRole,
            maxDepth: 8,
            runtime: fixture.runtime
        ).matches.filter { slider in
            let description = AXHelpers.getDescription(slider, runtime: fixture.runtime) ?? ""
            return !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return visibleTables.count == 1
            && visibleTables.first == fixture.controlsTable
            && describedSliders.isEmpty
    }

    private func fixture(
        label: String?,
        controlRoles: [String],
        axRowsReadStatus: Int32? = nil,
        roleReadFailureElementIDs: Set<Int> = []
    ) -> (builder: FakeAXRuntimeBuilder, window: AXUIElement, runtime: AXHelpers.Runtime) {
        let builder = FakeAXRuntimeBuilder()
        let window = builder.element(100)
        let table = builder.element(101)
        let row = builder.element(102)
        let labelCell = builder.element(103)

        builder.setRole(window, kAXWindowRole as String)
        builder.setRole(table, kAXTableRole as String)
        builder.setRole(row, kAXRowRole as String)
        builder.setRole(labelCell, kAXCellRole as String)
        if let label {
            let text = builder.element(105)
            builder.setRole(text, kAXStaticTextRole as String)
            builder.setAttribute(text, kAXValueAttribute as String, label)
        }
        let controls = controlRoles.enumerated().map { offset, role -> AXUIElement in
            let control = builder.element(110 + offset)
            builder.setRole(control, role)
            builder.setAttribute(control, kAXValueAttribute as String, 0)
            return control
        }
        let labelContents: [AXUIElement]
        if label == nil {
            labelContents = controls
        } else {
            labelContents = [builder.element(105)] + controls
        }
        builder.setChildren(labelCell, labelContents)
        builder.setChildren(row, [labelCell])
        builder.setChildren(table, [row])
        builder.setAttribute(table, kAXRowsAttribute as String, [row])
        builder.setChildren(window, [table])
        let runtime = builder.makeAXRuntime(
            appElement: builder.element(99),
            attributeValueResultHandler: { element, attribute in
                if attribute == (kAXRoleAttribute as String),
                   roleReadFailureElementIDs.contains(where: {
                       CFEqual(element, builder.element($0))
                   }) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                }
                guard let axRowsReadStatus,
                      builder.elementID(element) == builder.elementID(table),
                      attribute == (kAXRowsAttribute as String) else {
                    return nil
                }
                return .failure(AXHelpers.AXStatusError(raw: axRowsReadStatus))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        return (builder, window, runtime)
    }
}
