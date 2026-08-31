@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("ADR-018 Controls-view parameter enumerator")
struct ControlsViewParameterEnumeratorTests {
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
}

private enum PluginTextPlacement {
    case direct
    case nested
}

private func makeControlsFixture(
    pluginName: String = "Raum",
    trackName: String = "Audio 1",
    windowTitle: String? = nil,
    rows: [RowFixture] = measuredRows,
    exposesRowsAttribute: Bool = true,
    includesNonRowTableChild: Bool = false,
    cellBinding: CellBinding = .paired,
    pluginTextPlacement: PluginTextPlacement = .direct,
    unreadableLabelIndexes: Set<Int> = [],
    unreadableWindowTitle: Bool = false,
    unreadableControlValueIndexes: Set<Int> = [],
    unreadableAdditionalControlRoleIndexes: Set<Int> = [],
    unreadableCellChildIndexes: Set<Int> = [],
    unreadableDirectHeaderRole: Bool = false
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
    let rowElements = rows.enumerated().map { rowIndex, rowFixture -> AXUIElement in
        let base = 90_100 + rowIndex * 20
        let row = builder.element(base)
        let label = builder.element(base + 1)
        let control = builder.element(base + 2)
        labelElementIDs.append(builder.elementID(label))
        controlElementIDs.append(builder.elementID(control))
        builder.setRole(row, kAXRowRole as String)
        builder.setRole(label, kAXStaticTextRole as String)
        builder.setAttribute(label, kAXValueAttribute as String, rowFixture.label)
        configure(
            control,
            fixture: rowFixture,
            role: rowFixture.controlRole,
            builder: builder
        )

        var controls = [control]
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
            let cell = builder.element(base + 4)
            builder.setRole(cell, kAXCellRole as String)
            var cellChildren = [label] + controls
            if unreadableCellChildIndexes.contains(rowIndex) {
                let unreadableDescendant = builder.element(base + 6)
                builder.setRole(unreadableDescendant, kAXGroupRole as String)
                cellChildren.append(unreadableDescendant)
                unreadableCellChildElementIDs.append(builder.elementID(unreadableDescendant))
            }
            builder.setChildren(cell, cellChildren)
            builder.setChildren(row, [cell])
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
        case .separateLabelAndControl:
            let cell = builder.element(base + 4)
            builder.setRole(cell, kAXCellRole as String)
            builder.setChildren(cell, [label] + controls)
            builder.setChildren(row, [cell])
        }
        return row
    }
    var tableChildren = rowElements
    if includesNonRowTableChild {
        let unrelatedChild = builder.element(91_000)
        builder.setRole(unrelatedChild, kAXGroupRole as String)
        tableChildren.append(unrelatedChild)
    }
    builder.setChildren(table, tableChildren)
    if exposesRowsAttribute {
        builder.setAttribute(table, kAXRowsAttribute as String, rowElements)
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
    let windowID = builder.elementID(window)
    let headerDecorationID = builder.elementID(headerDecoration)
    let runtime: AXHelpers.Runtime
    if !unreadableLabelElementIDs.isEmpty
        || unreadableWindowTitle
        || !unreadableControlValueElementIDs.isEmpty
        || !unreadableAdditionalControlRoleElementIDs.isEmpty
        || !unreadableCellElementIDs.isEmpty
        || unreadableDirectHeaderRole {
        runtime = builder.makeAXRuntime(
            attributeValueResultHandler: { element, attribute in
                let elementID = builder.elementID(element)
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
                guard unreadableCellElementIDs.contains(builder.elementID(element)) else {
                    return nil
                }
                return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
    } else {
        runtime = builder.makeAXRuntime()
    }
    return ControlsFixture(builder: builder, window: window, runtime: runtime)
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
