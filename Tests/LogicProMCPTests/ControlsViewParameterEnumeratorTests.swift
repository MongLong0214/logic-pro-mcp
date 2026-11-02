@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("ADR-018 Controls-view parameter enumerator")
struct ControlsViewParameterEnumeratorTests {
    @Test func duplicatePhysicalEmptyCellsAcrossRowsCannotMintSeparateObservations() {
        let fixture = makeControlsFixture(
            duplicateCellSourceIndex: 6,
            emptyCellIndexes: [6, 7]
        )

        #expect(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ) == nil)
    }

    @Test func duplicatePhysicalLabelsAcrossRowsCannotMintDistinctParameterReferences() {
        let fixture = makeControlsFixture(duplicateLabelSourceIndex: 6)

        #expect(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ) == nil)
    }

    @Test func duplicatePhysicalControlsAcrossRowsCannotMintDistinctParameterReferences() {
        let fixture = makeControlsFixture(duplicateControlSourceIndex: 6)

        #expect(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ) == nil)
    }

    @Test func duplicatePhysicalRowsCannotMintDistinctParameterReferences() {
        let fixture = makeControlsFixture(duplicateRowIndex: 7)

        #expect(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ) == nil)
    }

    @Test func changingPhysicalRowListCannotProduceACompleteManifest() {
        let fixture = makeControlsFixture(rowListMutation: .dropLast)

        #expect(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ) == nil)
        #expect(fixture.rowListReadCounter?.current == 2)
    }

    @Test func replacingAPhysicalRowDuringEnumerationCannotProduceACompleteManifest() {
        let fixture = makeControlsFixture(rowListMutation: .replace(index: 7))

        #expect(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ) == nil)
        #expect(fixture.rowListReadCounter?.current == 2)
    }

    @Test func reorderingPhysicalRowsDuringEnumerationCannotProduceACompleteManifest() {
        let fixture = makeControlsFixture(rowListMutation: .swap(6, 7))

        #expect(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ) == nil)
        #expect(fixture.rowListReadCounter?.current == 2)
    }

    @Test func replacingAPhysicalCellAfterTheRowScanCannotProduceACompleteManifest() {
        let fixture = makeControlsFixture(
            rowStructureMutation: .replaceCell(rowIndex: 7)
        )

        #expect(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ) == nil)
        #expect(fixture.rowStructureReadCounter?.current == 4)
    }

    @Test func replacingAPhysicalLabelInsideAStableCellCannotProduceACompleteManifest() {
        let fixture = makeControlsFixture(
            cellContentMutation: .replaceLabel(rowIndex: 7)
        )

        #expect(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ) == nil)
        #expect(fixture.cellContentReadCounter?.current == 7)
    }

    @Test func replacingAPhysicalControlInsideAStableCellCannotProduceACompleteManifest() {
        let fixture = makeControlsFixture(
            cellContentMutation: .replaceControl(rowIndex: 7)
        )

        #expect(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ) == nil)
        #expect(fixture.cellContentReadCounter?.current == 7)
    }

    @Test func traversalDepthBoundaryRefusesInsteadOfHidingANestedControl() {
        let fixture = makeControlsFixture(depthBoundaryIndex: 7)
        let result = ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        )

        #expect(result == nil)
    }

    @Test func emptyTraversalDepthBoundaryRemainsACompleteLeaf() throws {
        let fixture = makeControlsFixture(
            depthBoundaryIndex: 7,
            depthBoundaryChildren: .empty
        )

        #expect(try #require(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        )).manifest.parameters.count == 16)
    }

    @Test(arguments: [AXError.attributeUnsupported, AXError.noValue])
    func definitiveAbsenceAtTraversalDepthBoundaryRemainsACompleteLeaf(_ error: AXError) throws {
        let fixture = makeControlsFixture(
            depthBoundaryIndex: 7,
            depthBoundaryChildren: .readError(error)
        )

        #expect(try #require(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        )).manifest.parameters.count == 16)
    }

    @Test func unreadableTraversalDepthBoundaryRefusesTheManifest() {
        let fixture = makeControlsFixture(
            depthBoundaryIndex: 7,
            depthBoundaryChildren: .boundaryReadError(.failure)
        )

        #expect(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ) == nil)
        #expect(fixture.depthBoundaryReadFailure?.readCount == 2)
    }

    @Test func definitiveLeafChildAbsenceDoesNotMakeTheCompleteTreeUnreadable() {
        for error in [AXError.attributeUnsupported, AXError.noValue] {
            let fixture = makeControlsFixture(leafChildrenReadError: error)
            #expect(ControlsViewParameterEnumerator.enumerate(
                in: fixture.window,
                buildFingerprint: "Logic-12.x",
                runtime: fixture.runtime
            ) != nil, "AXChildren status \(error.rawValue)")
        }
    }

    @Test func manifestUsesTheMeasuredRaumRowsRolesAndReadbacks() throws {
        let fixture = makeControlsFixture()
        let result = try #require(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ))
        let manifest = result.manifest

        #expect(manifest.provider == .controlsViewAX)
        #expect(manifest.parameters.map(\.name) == [
            "Sync", "Predelay", "Feedback", "Low Cut", "High Cut", "Mix",
            "MixLock", "Mode", "Diffusion", "Size", "Decay", "Density",
            "Modulation", "Damp", "Reverb", "Freeze",
        ])
        #expect(manifest.parameters.map(\.index) == [
            0, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
        ])
        #expect(manifest.parameters.map(\.controlRole) == [
            .checkBox, .slider, .slider, .slider, .slider, .slider,
            .checkBox, .slider, .slider, .slider, .slider, .slider,
            .slider, .slider, .slider, .popUpButton,
        ])
        #expect(result.rowObservations.map(\.valueDescription) == measuredRows.map {
            $0.valueDescription.flatMap(trimmed)
        })
        #expect(result.rowObservations.map(\.valueIsSettable) == measuredRows.map(\.valueSettable))

        let allProducedParametersAreReadbackOnly = manifest.parameters.allSatisfy {
            $0.valueKind == .normalizedReadbackOnly
        }
        #expect(allProducedParametersAreReadbackOnly)
    }

    @Test func placeholderLabelsAreRefusedForTheirLabelsNotTheirSliders() throws {
        let fixture = makeControlsFixture()
        let result = try #require(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ))

        #expect(result.rowObservations[2].controlRoles == ["AXSlider"])
        #expect(result.rowObservations[3].controlRoles == ["AXSlider"])
        #expect(result.rowObservations[2].classification == .refusedPlaceholderLabel)
        #expect(result.rowObservations[3].classification == .refusedPlaceholderLabel)
        let emittedNames = result.manifest.parameters.map(\.name)
        let emitsPlaceholder = emittedNames.contains("-")
        #expect(!emitsPlaceholder)
        let feedback = try #require(result.manifest.parameters.first { $0.name == "Feedback" })
        #expect(feedback.index == 4)
    }

    @Test func checkboxPopupAndRadioRowsAreAddressableParametersWithTheirRoles() throws {
        var rows = measuredRows
        rows[0].controlRole = .radioButton
        let fixture = makeControlsFixture(rows: rows)
        let result = try #require(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ))

        let sync = try #require(result.manifest.parameters.first { $0.name == "Sync" })
        let mixLock = try #require(result.manifest.parameters.first { $0.name == "MixLock" })
        let freeze = try #require(result.manifest.parameters.first { $0.name == "Freeze" })
        #expect(sync.controlRole == .radioButton)
        #expect(mixLock.controlRole == .checkBox)
        #expect(freeze.controlRole == .popUpButton)
    }

    @Test func absentControlValueIsRecordedAsUnsupportedNotReadbackCapable() throws {
        var rows = measuredRows
        rows[1].value = nil
        rows[1].valueDescription = nil
        let fixture = makeControlsFixture(rows: rows)
        let result = try #require(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ))

        let predelay = try #require(result.manifest.parameters.first { $0.name == "Predelay" })
        #expect(predelay.controlRole == .slider)
        #expect(predelay.valueKind == .unsupported)
        #expect(result.rowObservations[1].classification == .parameter(
            controlRole: .slider,
            valueIsReadable: false
        ))
    }

    @Test func failedControlValueReadIsRecordedAsUnsupportedNotReadbackCapable() throws {
        let fixture = makeControlsFixture(unreadableControlValueIndexes: [1])
        let result = try #require(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ))

        let predelay = try #require(result.manifest.parameters.first { $0.name == "Predelay" })
        let isUnsupported = predelay.valueKind == .unsupported
        #expect(isUnsupported)
        let hasUnreadableValue = result.rowObservations[1].classification == .parameter(
            controlRole: .slider,
            valueIsReadable: false
        )
        #expect(hasUnreadableValue)
    }

    @Test func producedManifestIsUnapprovedAndPerformsNoAXWrite() throws {
        let fixture = makeControlsFixture()
        let manifest = try #require(ControlsViewParameterEnumerator.manifest(
            from: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ))

        let isApproved = manifest.approved
        let performedNoWrites = fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty
        #expect(!isApproved)
        #expect(performedNoWrites)
    }

    @Test func everyProducedParameterIsPresentBeforeRejectingExactWriteReadback() throws {
        let fixture = makeControlsFixture()
        let manifest = try #require(ControlsViewParameterEnumerator.manifest(
            from: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ))
        let hasProducedParameters = !manifest.parameters.isEmpty
        #expect(hasProducedParameters)

        let claimsExactWriteReadback = manifest.parameters.contains {
            $0.valueKind == .exactWriteReadback
        }
        #expect(!claimsExactWriteReadback)
    }

    @Test func controlRolesChangeTheUISignatureFingerprintWithoutChangingRefusalState() throws {
        let originalFixture = makeControlsFixture()
        var changedRows = measuredRows
        // A placeholder row remains refused for the same reason while its
        // observed (but unaddressable) control role changes.
        changedRows[2].controlRole = .checkBox
        let changedFixture = makeControlsFixture(rows: changedRows)

        let original = try #require(ControlsViewParameterEnumerator.enumerate(
            in: originalFixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: originalFixture.runtime
        ))
        let changed = try #require(ControlsViewParameterEnumerator.enumerate(
            in: changedFixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: changedFixture.runtime
        ))

        let signatureChanged = original.manifest.uiSignatureFingerprint
            != changed.manifest.uiSignatureFingerprint
        #expect(signatureChanged)
        let refusalStateStayedTheSame = original.rowObservations[2].classification
            == changed.rowObservations[2].classification
        #expect(refusalStateStayedTheSame)
    }

    @Test func refusalStateChangesTheUISignatureFingerprintWithoutChangingControlRoles() throws {
        let originalFixture = makeControlsFixture()
        let changedFixture = makeControlsFixture(
            cellBinding: .separateLabelAndControl(rowIndex: 7)
        )

        let original = try #require(ControlsViewParameterEnumerator.enumerate(
            in: originalFixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: originalFixture.runtime
        ))
        let changed = try #require(ControlsViewParameterEnumerator.enumerate(
            in: changedFixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: changedFixture.runtime
        ))

        let signatureChanged = original.manifest.uiSignatureFingerprint
            != changed.manifest.uiSignatureFingerprint
        #expect(signatureChanged)
        let controlRolesStayedTheSame = original.rowObservations[7].controlRoles
            == changed.rowObservations[7].controlRoles
        #expect(controlRolesStayedTheSame)
        let refusalStateChanged = original.rowObservations[7].classification
            != changed.rowObservations[7].classification
        #expect(refusalStateChanged)
    }

    @Test func unreadableRowLabelRefusesInsteadOfHashingAnUnstableNilLabel() {
        let fixture = makeControlsFixture(unreadableLabelIndexes: [7])
        let result = ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        )

        let refusedUnstableLabel = result == nil
        #expect(refusedUnstableLabel)
    }

    @Test func unreadableControlRoleRefusesInsteadOfSilentlyDroppingTheControl() {
        var rows = measuredRows
        rows[7].additionalControlRole = .checkBox
        let fixture = makeControlsFixture(
            rows: rows,
            unreadableAdditionalControlRoleIndexes: [7]
        )

        let result = ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        )

        let refusedIncompleteControlScan = result == nil
        #expect(refusedIncompleteControlScan)
    }

    @Test func aSupportedControlInAnotherCellRefusesTheOtherwisePairedRowAsAmbiguous() throws {
        var rows = measuredRows
        rows[7].additionalControlRole = .checkBox
        let fixture = makeControlsFixture(
            rows: rows,
            cellBinding: .pairedPrimaryAndSeparateAdditional(rowIndex: 7)
        )
        let result = try #require(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ))

        #expect(result.rowObservations[7].controlRoles == ["AXCheckBox", "AXSlider"])
        #expect(result.rowObservations[7].classification == .refusedAmbiguousControl(
            roles: ["AXCheckBox", "AXSlider"]
        ))
        #expect(!result.manifest.parameters.contains { $0.name == "Mix" })
    }

    @Test func unreadableCellDescendantsRefuseInsteadOfClassifyingAPartialCell() {
        let fixture = makeControlsFixture(unreadableCellChildIndexes: [7])
        let result = ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        )

        let refusedIncompleteCellScan = result == nil
        #expect(refusedIncompleteCellScan)
    }

    @Test func tableBindingRequiresWindowRowsCellsAndSharedCellPairing() throws {
        let nonWindowFixture = makeControlsFixture()
        nonWindowFixture.builder.setRole(nonWindowFixture.window, kAXGroupRole as String)
        let nonWindowResult = ControlsViewParameterEnumerator.enumerate(
            in: nonWindowFixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: nonWindowFixture.runtime
        )
        let refusedNonWindowRoot = nonWindowResult == nil
        #expect(refusedNonWindowRoot)

        let fallbackFixture = makeControlsFixture(
            exposesRowsAttribute: false,
            includesNonRowTableChild: true
        )
        let fallbackResult = ControlsViewParameterEnumerator.enumerate(
            in: fallbackFixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fallbackFixture.runtime
        )
        let refusedNonRowFallback = fallbackResult == nil
        #expect(refusedNonRowFallback)

        let celllessFixture = makeControlsFixture(cellBinding: .absent)
        let celllessResult = ControlsViewParameterEnumerator.enumerate(
            in: celllessFixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: celllessFixture.runtime
        )
        let refusedCelllessTable = celllessResult == nil
        #expect(refusedCelllessTable)

        let unpairedFixture = makeControlsFixture(
            cellBinding: .separateLabelAndControl(rowIndex: 7)
        )
        let unpairedResult = try #require(ControlsViewParameterEnumerator.enumerate(
            in: unpairedFixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: unpairedFixture.runtime
        ))
        #expect(unpairedResult.rowObservations[7].classification == .refusedUnpairedLabelAndControl)
        let emittedMix = unpairedResult.manifest.parameters.contains { $0.name == "Mix" }
        #expect(!emittedMix)
    }

    @Test func labelledSectionRowsAreRetainedWithoutWeakeningTableBinding() throws {
        var rows = measuredRows
        rows.insert(RowFixture(
            label: "Dynamics",
            controlRole: .slider,
            value: nil,
            valueDescription: nil,
            valueSettable: false,
            additionalControlRole: nil,
            includesControl: false
        ), at: 0)
        let fixture = makeControlsFixture(rows: rows)
        let result = try #require(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ))

        #expect(result.rowObservations[0].observedLabel == "Dynamics")
        #expect(result.rowObservations[0].classification == .refusedNoControl)

        var labelsOnly = rows
        for index in labelsOnly.indices {
            labelsOnly[index].includesControl = false
        }
        let labelsOnlyFixture = makeControlsFixture(rows: labelsOnly)
        #expect(ControlsViewParameterEnumerator.enumerate(
            in: labelsOnlyFixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: labelsOnlyFixture.runtime
        ) == nil)
    }

    @Test func missingOrUnreadableWindowTitleCannotAdmitTheTrackAsPluginName() {
        let emptyTitleFixture = makeControlsFixture(
            windowTitle: "",
            pluginTextPlacement: .nested
        )
        let emptyTitleResult = ControlsViewParameterEnumerator.enumerate(
            in: emptyTitleFixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: emptyTitleFixture.runtime
        )
        let refusedEmptyTitle = emptyTitleResult == nil
        #expect(refusedEmptyTitle)

        let unreadableTitleFixture = makeControlsFixture(
            pluginTextPlacement: .nested,
            unreadableWindowTitle: true
        )
        let unreadableTitleResult = ControlsViewParameterEnumerator.enumerate(
            in: unreadableTitleFixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: unreadableTitleFixture.runtime
        )
        let refusedUnreadableTitle = unreadableTitleResult == nil
        #expect(refusedUnreadableTitle)
    }

    @Test func pluginNameUsesDirectHeaderTextAndExcludesTheMeasuredTrackTitle() throws {
        let normalFixture = makeControlsFixture(pluginName: "Raum", trackName: "Compressor")
        let normal = try #require(ControlsViewParameterEnumerator.enumerate(
            in: normalFixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: normalFixture.runtime
        ))

        #expect(normal.manifest.pluginName == "Raum")
        #expect(normal.identityEvidence.windowTitle == "Compressor")
        #expect(normal.identityEvidence.directStaticTextValues == ["Raum", "Compressor"])
        #expect(normal.identityEvidence.canonicalPluginIdentifier == nil)
    }

    @Test func unsupportedOptionalWindowIdentifierIsDefinitiveAbsence() throws {
        let fixture = makeControlsFixture(windowIdentifierReadError: .attributeUnsupported)
        let result = try #require(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ))

        #expect(result.identityEvidence.observedWindowAXIdentifier == nil)
        #expect(!result.manifest.parameters.isEmpty)
    }

    @Test func noValueOptionalWindowIdentifierIsDefinitiveAbsence() throws {
        let fixture = makeControlsFixture(windowIdentifierReadError: .noValue)
        let result = try #require(ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        ))

        #expect(result.identityEvidence.observedWindowAXIdentifier == nil)
        #expect(!result.manifest.parameters.isEmpty)
    }

    @Test func failedOptionalWindowIdentifierReadStillRefusesIdentity() {
        let fixture = makeControlsFixture(windowIdentifierReadError: .failure)
        let result = ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        )

        #expect(result == nil)
    }

    @Test func unreadableDirectHeaderRoleRefusesIdentityInsteadOfIgnoringTheCandidate() {
        let fixture = makeControlsFixture(unreadableDirectHeaderRole: true)
        let result = ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        )

        let refusedIncompleteHeaderScan = result == nil
        #expect(refusedIncompleteHeaderScan)
    }

    @Test func exactPluginAndTrackNameCollisionRefusesIdentity() {
        let fixture = makeControlsFixture(pluginName: "Raum", trackName: "Raum")
        let result = ControlsViewParameterEnumerator.enumerate(
            in: fixture.window,
            buildFingerprint: "Logic-12.x",
            runtime: fixture.runtime
        )

        let refusedAmbiguousIdentity = result == nil
        #expect(refusedAmbiguousIdentity)
    }
}

private struct ControlsFixture {
    let builder: FakeAXRuntimeBuilder
    let window: AXUIElement
    let runtime: AXHelpers.Runtime
    let depthBoundaryReadFailure: DepthBoundaryReadFailure?
    let rowListReadCounter: LockedRowListReadCounter?
    let rowStructureReadCounter: LockedRowStructureReadCounter?
    let cellContentReadCounter: LockedRowStructureReadCounter?
}

private struct RowFixture {
    var label: String
    var controlRole: GenericParameterControlRole
    /// The fixture needs a readable AXValue for the enum's readback claim.
    /// The supplied re-measurement gives the user-facing strings below; it
    /// does not establish a normalized/raw conversion, so these are only
    /// non-empty AX-value witnesses and are never asserted as raw units.
    var value: String?
    var valueDescription: String?
    var valueSettable: Bool
    var additionalControlRole: GenericParameterControlRole?
    var includesControl: Bool = true
}

// The supplied re-measurement names 18 physical rows. Its aggregate says 14
// AXSlider rows, while the itemized labels include thirteen named sliders and
// two '-' slider rows (15); the fixture keeps every itemized row rather than
// silently deleting a measured label to make that aggregate add up.
private let measuredRows: [RowFixture] = [
    RowFixture(label: "Sync:", controlRole: .checkBox, value: "0", valueDescription: "", valueSettable: false, additionalControlRole: nil),
    RowFixture(label: "Predelay:", controlRole: .slider, value: "0.00 ms", valueDescription: "0.00 ms", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "-", controlRole: .slider, value: "-", valueDescription: "-", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "-", controlRole: .slider, value: "-", valueDescription: "-", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "Feedback:", controlRole: .slider, value: "0.0 %", valueDescription: "0.0 %", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "Low Cut:", controlRole: .slider, value: "Off", valueDescription: "Off", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "High Cut:", controlRole: .slider, value: "Off", valueDescription: "Off", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "Mix:", controlRole: .slider, value: "50.0 %", valueDescription: "50.0 %", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "MixLock:", controlRole: .checkBox, value: "0", valueDescription: "", valueSettable: false, additionalControlRole: nil),
    RowFixture(label: "Mode:", controlRole: .slider, value: "Airy", valueDescription: "Airy", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "Diffusion:", controlRole: .slider, value: "25.0 %", valueDescription: "25.0 %", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "Size:", controlRole: .slider, value: "50.0 %", valueDescription: "50.0 %", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "Decay:", controlRole: .slider, value: "4.8 s", valueDescription: "4.8 s", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "Density:", controlRole: .slider, value: "Dense", valueDescription: "Dense", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "Modulation:", controlRole: .slider, value: "25.0 %", valueDescription: "25.0 %", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "Damp:", controlRole: .slider, value: "25.0 %", valueDescription: "25.0 %", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "Reverb:", controlRole: .slider, value: "100.0 %", valueDescription: "100.0 %", valueSettable: true, additionalControlRole: nil),
    RowFixture(label: "Freeze:", controlRole: .popUpButton, value: "0", valueDescription: "", valueSettable: false, additionalControlRole: nil),
]

private enum CellBinding {
    case paired
    case absent
    case separateLabelAndControl(rowIndex: Int)
    case pairedPrimaryAndSeparateAdditional(rowIndex: Int)
}

private enum PluginTextPlacement {
    case direct
    case nested
}

private enum DepthBoundaryChildrenFixture {
    case empty
    case nonempty
    case readError(AXError)
    case boundaryReadError(AXError)
}

private enum RowListMutation: Sendable {
    case dropLast
    case replace(index: Int)
    case swap(Int, Int)
}

private enum RowStructureMutation: Sendable {
    case replaceCell(rowIndex: Int)
}

private enum CellContentMutation: Sendable {
    case replaceLabel(rowIndex: Int)
    case replaceControl(rowIndex: Int)
}

private final class LockedDepthBoundaryReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedRowListReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedRowStructureReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct DepthBoundaryReadFailure: @unchecked Sendable {
    let elementID: Int
    let error: AXError
    let failOnRead: Int?
    let reads = LockedDepthBoundaryReadCounter()

    var readCount: Int { reads.current }

    func shouldFailThisRead() -> Bool {
        let read = reads.next()
        return failOnRead == nil || failOnRead == read
    }
}

private func makeControlsFixture(
    pluginName: String = "Raum",
    trackName: String = "Audio 1",
    windowTitle: String? = nil,
    rows: [RowFixture] = measuredRows,
    exposesRowsAttribute: Bool = true,
    includesNonRowTableChild: Bool = false,
    duplicateRowIndex: Int? = nil,
    duplicateCellSourceIndex: Int? = nil,
    duplicateLabelSourceIndex: Int? = nil,
    duplicateControlSourceIndex: Int? = nil,
    cellBinding: CellBinding = .paired,
    pluginTextPlacement: PluginTextPlacement = .direct,
    unreadableLabelIndexes: Set<Int> = [],
    unreadableWindowTitle: Bool = false,
    unreadableControlValueIndexes: Set<Int> = [],
    unreadableAdditionalControlRoleIndexes: Set<Int> = [],
    unreadableCellChildIndexes: Set<Int> = [],
    emptyCellIndexes: Set<Int> = [],
    depthBoundaryIndex: Int? = nil,
    depthBoundaryChildren: DepthBoundaryChildrenFixture = .nonempty,
    leafChildrenReadError: AXError? = nil,
    unreadableDirectHeaderRole: Bool = false,
    windowIdentifierReadError: AXError? = nil,
    rowListMutation: RowListMutation? = nil,
    rowStructureMutation: RowStructureMutation? = nil,
    cellContentMutation: CellContentMutation? = nil
) -> ControlsFixture {
    let builder = FakeAXRuntimeBuilder()
    let window = builder.element(90_000)
    let table = builder.element(90_001)
    builder.setRole(window, kAXWindowRole as String)
    builder.setAttribute(window, kAXTitleAttribute as String, windowTitle ?? trackName)
    builder.setRole(table, kAXTableRole as String)

    var labelElementIDs: [Int] = []
    var controlElementIDs: [Int] = []
    var additionalControlElementIDs: [Int: Int] = [:]
    var unreadableCellChildElementIDs: [Int] = []
    var depthBoundaryReadFailure: DepthBoundaryReadFailure?
    var primaryControlElements: [AXUIElement] = []
    var primaryLabelElements: [AXUIElement] = []
    var primaryCellElements: [AXUIElement] = []
    let rowElements = rows.enumerated().map { rowIndex, rowFixture -> AXUIElement in
        let base = 90_100 + rowIndex * 20
        let row = builder.element(base)
        let label: AXUIElement
        if let duplicateLabelSourceIndex,
           rowIndex == duplicateLabelSourceIndex + 1,
           primaryLabelElements.indices.contains(duplicateLabelSourceIndex) {
            label = primaryLabelElements[duplicateLabelSourceIndex]
        } else {
            label = builder.element(base + 1)
        }
        let control: AXUIElement
        if let duplicateControlSourceIndex,
           rowIndex == duplicateControlSourceIndex + 1,
           primaryControlElements.indices.contains(duplicateControlSourceIndex) {
            control = primaryControlElements[duplicateControlSourceIndex]
        } else {
            control = builder.element(base + 2)
            configure(
                control,
                fixture: rowFixture,
                role: rowFixture.controlRole,
                builder: builder
            )
        }
        primaryControlElements.append(control)
        primaryLabelElements.append(label)
        labelElementIDs.append(builder.elementID(label))
        controlElementIDs.append(builder.elementID(control))
        builder.setRole(row, kAXRowRole as String)
        builder.setRole(label, kAXStaticTextRole as String)
        builder.setAttribute(label, kAXValueAttribute as String, rowFixture.label)

        var controls = rowFixture.includesControl ? [control] : []
        if let additionalControlRole = rowFixture.additionalControlRole {
            let additionalControl = builder.element(base + 3)
            configure(
                additionalControl,
                fixture: rowFixture,
                role: additionalControlRole,
                builder: builder
            )
            controls.append(additionalControl)
            additionalControlElementIDs[rowIndex] = builder.elementID(additionalControl)
        }

        switch cellBinding {
        case .paired:
            let cell: AXUIElement
            if let duplicateCellSourceIndex,
               rowIndex == duplicateCellSourceIndex + 1,
               primaryCellElements.indices.contains(duplicateCellSourceIndex) {
                cell = primaryCellElements[duplicateCellSourceIndex]
            } else {
                cell = builder.element(base + 4)
            }
            builder.setRole(cell, kAXCellRole as String)
            var cellChildren = [label] + controls
            if depthBoundaryIndex == rowIndex {
                let groups = (0..<4).map { builder.element(base + 7 + $0) }
                let hiddenControl = builder.element(base + 11)
                groups.forEach { builder.setRole($0, kAXGroupRole as String) }
                builder.setRole(hiddenControl, GenericParameterControlRole.slider.rawValue)
                builder.setChildren(groups[0], [groups[1]])
                switch depthBoundaryChildren {
                case .empty:
                    builder.setChildren(groups[1], [])
                case .nonempty:
                    builder.setChildren(groups[1], [groups[2]])
                    builder.setChildren(groups[2], [groups[3]])
                    builder.setChildren(groups[3], [hiddenControl])
                case .readError(let error):
                    builder.setChildren(groups[1], [])
                    depthBoundaryReadFailure = DepthBoundaryReadFailure(
                        elementID: builder.elementID(groups[1]),
                        error: error,
                        failOnRead: nil
                    )
                case .boundaryReadError(let error):
                    builder.setChildren(groups[1], [])
                    depthBoundaryReadFailure = DepthBoundaryReadFailure(
                        elementID: builder.elementID(groups[1]),
                        error: error,
                        failOnRead: 2
                    )
                }
                cellChildren.append(groups[0])
            }
            if unreadableCellChildIndexes.contains(rowIndex) {
                let unreadableDescendant = builder.element(base + 6)
                builder.setRole(unreadableDescendant, kAXGroupRole as String)
                cellChildren.append(unreadableDescendant)
                unreadableCellChildElementIDs.append(builder.elementID(unreadableDescendant))
            }
            builder.setChildren(cell, emptyCellIndexes.contains(rowIndex) ? [] : cellChildren)
            builder.setChildren(row, [cell])
            primaryCellElements.append(cell)
        case .absent:
            builder.setChildren(row, [label] + controls)
        case .separateLabelAndControl(let targetIndex) where targetIndex == rowIndex:
            let labelCell = builder.element(base + 4)
            let controlCell = builder.element(base + 5)
            builder.setRole(labelCell, kAXCellRole as String)
            builder.setRole(controlCell, kAXCellRole as String)
            builder.setChildren(labelCell, [label])
            builder.setChildren(controlCell, controls)
            builder.setChildren(row, [labelCell, controlCell])
        case .pairedPrimaryAndSeparateAdditional(let targetIndex) where targetIndex == rowIndex:
            let primaryCell = builder.element(base + 4)
            let additionalCell = builder.element(base + 5)
            builder.setRole(primaryCell, kAXCellRole as String)
            builder.setRole(additionalCell, kAXCellRole as String)
            builder.setChildren(primaryCell, [label] + Array(controls.prefix(1)))
            builder.setChildren(additionalCell, Array(controls.dropFirst()))
            builder.setChildren(row, [primaryCell, additionalCell])
        case .separateLabelAndControl, .pairedPrimaryAndSeparateAdditional:
            let cell = builder.element(base + 4)
            builder.setRole(cell, kAXCellRole as String)
            builder.setChildren(cell, [label] + controls)
            builder.setChildren(row, [cell])
        }
        return row
    }
    var tableChildren = rowElements
    if let duplicateRowIndex, rowElements.indices.contains(duplicateRowIndex) {
        tableChildren.insert(rowElements[duplicateRowIndex], at: duplicateRowIndex + 1)
    }
    if includesNonRowTableChild {
        let unrelatedChild = builder.element(91_000)
        builder.setRole(unrelatedChild, kAXGroupRole as String)
        tableChildren.append(unrelatedChild)
    }
    builder.setChildren(table, tableChildren)
    if exposesRowsAttribute {
        builder.setAttribute(table, kAXRowsAttribute as String, tableChildren)
    }

    let pluginText = builder.element(90_010)
    let trackText = builder.element(90_011)
    let headerDecoration = builder.element(90_013)
    builder.setRole(pluginText, kAXStaticTextRole as String)
    builder.setAttribute(pluginText, kAXValueAttribute as String, pluginName)
    builder.setRole(trackText, kAXStaticTextRole as String)
    builder.setAttribute(trackText, kAXValueAttribute as String, trackName)
    builder.setRole(headerDecoration, kAXGroupRole as String)
    switch pluginTextPlacement {
    case .direct:
        builder.setChildren(window, [pluginText, trackText, headerDecoration, table])
    case .nested:
        let pluginContainer = builder.element(90_012)
        builder.setRole(pluginContainer, kAXGroupRole as String)
        builder.setChildren(pluginContainer, [pluginText])
        builder.setChildren(window, [pluginContainer, trackText, headerDecoration, table])
    }

    let unreadableLabelElementIDs = Set(unreadableLabelIndexes.compactMap { index in
        labelElementIDs.indices.contains(index) ? labelElementIDs[index] : nil
    })
    let unreadableControlValueElementIDs = Set(unreadableControlValueIndexes.compactMap { index in
        controlElementIDs.indices.contains(index) ? controlElementIDs[index] : nil
    })
    let unreadableAdditionalControlRoleElementIDs = Set(
        unreadableAdditionalControlRoleIndexes.compactMap { additionalControlElementIDs[$0] }
    )
    let unreadableCellElementIDs = Set(unreadableCellChildElementIDs)
    let leafElementIDs = Set(
        labelElementIDs
            + controlElementIDs
            + Array(additionalControlElementIDs.values)
            + [
                builder.elementID(pluginText),
                builder.elementID(trackText),
                builder.elementID(headerDecoration),
            ]
    )
    let windowID = builder.elementID(window)
    let tableID = builder.elementID(table)
    let headerDecorationID = builder.elementID(headerDecoration)
    let depthBoundaryFailure = depthBoundaryReadFailure
    let observedTableChildren = tableChildren
    let replacementRow = builder.element(92_000)
    builder.setRole(replacementRow, kAXRowRole as String)
    let rowListReadCounter = rowListMutation == nil ? nil : LockedRowListReadCounter()
    let rowStructureMutationData: (rowID: Int, replacementCell: AXUIElement)?
    switch rowStructureMutation {
    case .replaceCell(let rowIndex)
        where rowElements.indices.contains(rowIndex)
            && primaryLabelElements.indices.contains(rowIndex)
            && primaryControlElements.indices.contains(rowIndex):
        let replacementCell = builder.element(93_000)
        builder.setRole(replacementCell, kAXCellRole as String)
        builder.setChildren(replacementCell, [
            primaryLabelElements[rowIndex],
            primaryControlElements[rowIndex],
        ])
        rowStructureMutationData = (
            rowID: builder.elementID(rowElements[rowIndex]),
            replacementCell: replacementCell
        )
    case .replaceCell, nil:
        rowStructureMutationData = nil
    }
    let rowStructureReadCounter = rowStructureMutationData == nil
        ? nil
        : LockedRowStructureReadCounter()
    let cellContentMutationData: (cellID: Int, children: [AXUIElement])?
    switch cellContentMutation {
    case .replaceLabel(let rowIndex)
        where primaryCellElements.indices.contains(rowIndex)
            && primaryControlElements.indices.contains(rowIndex)
            && rows.indices.contains(rowIndex):
        let replacementLabel = builder.element(94_000)
        builder.setRole(replacementLabel, kAXStaticTextRole as String)
        builder.setAttribute(
            replacementLabel,
            kAXValueAttribute as String,
            rows[rowIndex].label
        )
        cellContentMutationData = (
            cellID: builder.elementID(primaryCellElements[rowIndex]),
            children: [replacementLabel, primaryControlElements[rowIndex]]
        )
    case .replaceControl(let rowIndex)
        where primaryCellElements.indices.contains(rowIndex)
            && primaryLabelElements.indices.contains(rowIndex)
            && rows.indices.contains(rowIndex):
        let replacementControl = builder.element(94_001)
        configure(
            replacementControl,
            fixture: rows[rowIndex],
            role: rows[rowIndex].controlRole,
            builder: builder
        )
        cellContentMutationData = (
            cellID: builder.elementID(primaryCellElements[rowIndex]),
            children: [primaryLabelElements[rowIndex], replacementControl]
        )
    case .replaceLabel, .replaceControl, nil:
        cellContentMutationData = nil
    }
    let cellContentReadCounter = cellContentMutationData == nil
        ? nil
        : LockedRowStructureReadCounter()
    let runtime: AXHelpers.Runtime
    if !unreadableLabelElementIDs.isEmpty
        || unreadableWindowTitle
        || !unreadableControlValueElementIDs.isEmpty
        || !unreadableAdditionalControlRoleElementIDs.isEmpty
        || !unreadableCellElementIDs.isEmpty
        || depthBoundaryFailure != nil
        || leafChildrenReadError != nil
        || unreadableDirectHeaderRole
        || windowIdentifierReadError != nil
        || rowListMutation != nil
        || rowStructureMutationData != nil
        || cellContentMutationData != nil {
        runtime = builder.makeAXRuntime(
            attributeValueResultHandler: { element, attribute in
                let elementID = builder.elementID(element)
                if attribute == (kAXRowsAttribute as String), elementID == tableID,
                   let rowListReadCounter {
                    let read = rowListReadCounter.next()
                    var observedRows = observedTableChildren
                    if read > 1, let rowListMutation {
                        switch rowListMutation {
                        case .dropLast:
                            observedRows.removeLast()
                        case .replace(let index):
                            observedRows[index] = replacementRow
                        case .swap(let first, let second):
                            observedRows.swapAt(first, second)
                        }
                    }
                    return .success(observedRows as NSArray)
                }
                let unreadableLabel = attribute == (kAXValueAttribute as String)
                    && unreadableLabelElementIDs.contains(elementID)
                let unreadableTitle = unreadableWindowTitle
                    && attribute == (kAXTitleAttribute as String)
                    && elementID == windowID
                let unreadableControlValue = unreadableControlValueElementIDs.contains(elementID)
                    && (attribute == (kAXValueAttribute as String)
                        || attribute == (kAXValueDescriptionAttribute as String))
                let unreadableAdditionalControlRole = attribute == (kAXRoleAttribute as String)
                    && unreadableAdditionalControlRoleElementIDs.contains(elementID)
                let unreadableHeaderRole = unreadableDirectHeaderRole
                    && attribute == (kAXRoleAttribute as String)
                    && elementID == headerDecorationID
                if attribute == (kAXIdentifierAttribute as String), elementID == windowID,
                   let windowIdentifierReadError {
                    return .failure(AXHelpers.AXStatusError(raw: windowIdentifierReadError.rawValue))
                }
                guard unreadableLabel
                    || unreadableTitle
                    || unreadableControlValue
                    || unreadableAdditionalControlRole
                    || unreadableHeaderRole else {
                    return nil
                }
                return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
            },
            childrenResultHandler: { element in
                let elementID = builder.elementID(element)
                if let cellContentMutationData, let cellContentReadCounter,
                   elementID == cellContentMutationData.cellID {
                    let read = cellContentReadCounter.next()
                    if read >= 6 {
                        return .success(cellContentMutationData.children)
                    }
                }
                if let rowStructureMutationData, let rowStructureReadCounter,
                   elementID == rowStructureMutationData.rowID {
                    let read = rowStructureReadCounter.next()
                    if read >= 4 {
                        return .success([rowStructureMutationData.replacementCell])
                    }
                }
                if let depthBoundaryFailure,
                   elementID == depthBoundaryFailure.elementID,
                   depthBoundaryFailure.shouldFailThisRead() {
                    return .failure(AXHelpers.AXStatusError(
                        raw: depthBoundaryFailure.error.rawValue
                    ))
                }
                if unreadableCellElementIDs.contains(elementID) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if leafElementIDs.contains(elementID), let leafChildrenReadError {
                    return .failure(AXHelpers.AXStatusError(raw: leafChildrenReadError.rawValue))
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
    } else {
        runtime = builder.makeAXRuntime()
    }
    return ControlsFixture(
        builder: builder,
        window: window,
        runtime: runtime,
        depthBoundaryReadFailure: depthBoundaryFailure,
        rowListReadCounter: rowListReadCounter,
        rowStructureReadCounter: rowStructureReadCounter,
        cellContentReadCounter: cellContentReadCounter
    )
}

private func configure(
    _ control: AXUIElement,
    fixture: RowFixture,
    role: GenericParameterControlRole,
    builder: FakeAXRuntimeBuilder
) {
    builder.setRole(control, role.rawValue)
    if let value = fixture.value {
        builder.setAttribute(control, kAXValueAttribute as String, value)
    }
    if let valueDescription = fixture.valueDescription {
        builder.setAttribute(control, kAXValueDescriptionAttribute as String, valueDescription)
    }
    builder.setAttributeSettable(
        control,
        kAXValueAttribute as String,
        fixture.valueSettable
    )
}

private func trimmed(_ value: String) -> String? {
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
}
