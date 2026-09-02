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

    @Test func controlsRowsWithoutDescribedSlidersConfirmControlsDespiteContradictoryTitle() {
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

    @Test func switchThatNeverChangesStructureRefusesWithinDeadlineAndLeavesEntryView() {
        let fixture = viewFixture(entry: .controls, title: "[100%]", behavior: .neverChanges)
        let started = Date()

        let result = ControlsViewBooleanParameterWriter.prepareView(
            .editor,
            in: fixture.window,
            confirmationTimeout: 0.025,
            runtime: fixture.runtime
        )

        let refused: Bool
        if case .refused(.viewStructureDidNotConfirm(.editor)) = result {
            refused = true
        } else {
            refused = false
        }
        let completedWithinDeadline = Date().timeIntervalSince(started) < 0.25
        let attemptedEditorSelection = fixture.editorSelections.value == 1
        let entryStructureRemainedControls = controlsStructureIsPresent(fixture)
        #expect(refused)
        #expect(completedWithinDeadline)
        #expect(attemptedEditorSelection)
        #expect(entryStructureRemainedControls)
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
        if case .refused(.viewStructureDidNotConfirm(.editor)) = result {
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

    private struct ViewFixture {
        let builder: FakeAXRuntimeBuilder
        let window: AXUIElement
        let controlsTable: AXUIElement
        let controlsSelections: MutableBox<Int>
        let editorSelections: MutableBox<Int>
        let runtime: AXHelpers.Runtime
    }

    private func viewFixture(
        entry: ControlsViewBooleanParameterWriter.PluginWindowView,
        title: String,
        behavior: ViewFixtureBehavior
    ) -> ViewFixture {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(900)
        let window = builder.element(901)
        let switcher = builder.element(902)
        let menu = builder.element(903)
        let controlsMenuItem = builder.element(904)
        let editorMenuItem = builder.element(905)
        let editorSlider = builder.element(906)
        let controlsTable = builder.element(907)
        let controlsRow = builder.element(908)
        let controlsSelections = MutableBox(0)
        let editorSelections = MutableBox(0)

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
        builder.setChildren(switcher, [menu])

        builder.setRole(editorSlider, kAXSliderRole as String)
        builder.setAttribute(editorSlider, kAXDescriptionAttribute as String, "Threshold")
        builder.setRole(controlsTable, kAXTableRole as String)
        builder.setRole(controlsRow, kAXRowRole as String)
        builder.setChildren(controlsTable, [controlsRow])
        builder.setAttribute(controlsTable, kAXRowsAttribute as String, [controlsRow])

        let editorChildren = [switcher, editorSlider]
        let controlsChildren = [switcher, controlsTable]
        builder.setChildren(
            window,
            entry == .editor ? editorChildren : controlsChildren
        )

        let controlsKey = builder.elementID(controlsMenuItem)
        let editorKey = builder.elementID(editorMenuItem)
        let runtime = builder.makeAXRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard action == (kAXPressAction as String) else { return true }
                switch builder.elementID(element) {
                case editorKey:
                    editorSelections.value += 1
                    switch behavior {
                    case .switchesStructure:
                        builder.setChildren(window, editorChildren)
                    case .neverChanges:
                        break
                    case .becomesUnconfirmedThenControlsRestores:
                        builder.setChildren(window, [switcher])
                    }
                case controlsKey:
                    controlsSelections.value += 1
                    switch behavior {
                    case .switchesStructure, .becomesUnconfirmedThenControlsRestores:
                        builder.setChildren(window, controlsChildren)
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
        controlRoles: [String]
    ) -> (builder: FakeAXRuntimeBuilder, window: AXUIElement, runtime: AXHelpers.Runtime) {
        let builder = FakeAXRuntimeBuilder()
        let window = builder.element(100)
        let table = builder.element(101)
        let row = builder.element(102)
        let labelCell = builder.element(103)
        let controlCell = builder.element(104)

        builder.setRole(window, kAXWindowRole as String)
        builder.setRole(table, kAXTableRole as String)
        builder.setRole(row, kAXRowRole as String)
        builder.setRole(labelCell, kAXCellRole as String)
        builder.setRole(controlCell, kAXCellRole as String)
        if let label {
            let text = builder.element(105)
            builder.setRole(text, kAXStaticTextRole as String)
            builder.setAttribute(text, kAXValueAttribute as String, label)
            builder.setChildren(labelCell, [text])
        } else {
            builder.setChildren(labelCell, [])
        }
        let controls = controlRoles.enumerated().map { offset, role -> AXUIElement in
            let control = builder.element(110 + offset)
            builder.setRole(control, role)
            builder.setAttribute(control, kAXValueAttribute as String, 0)
            return control
        }
        builder.setChildren(controlCell, controls)
        builder.setChildren(row, [labelCell, controlCell])
        builder.setChildren(table, [row])
        builder.setAttribute(table, kAXRowsAttribute as String, [row])
        builder.setChildren(window, [table])
        return (builder, window, builder.makeAXRuntime(appElement: builder.element(99)))
    }
}
