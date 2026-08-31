import ApplicationServices
import CryptoKit
import Foundation

/// Reads Logic's host-provided Controls view. This is deliberately
/// observation-only: it never treats AX settable state as a successful
/// write/readback round trip.
///
/// No operation calls this producer yet. Wiring must attach to an owner that
/// already resolves one plug-in editor window, selects and confirms Controls
/// view, and can decide whether exposing an unapproved, display-name-only
/// manifest belongs on that operation's public contract. This component does
/// not make that reachability decision or add a public operation itself.
enum ControlsViewParameterEnumerator {
    enum PluginNameSource: String, Codable, Equatable, Sendable {
        case directWindowStaticText
    }

    /// Evidence retained beside the manifest because the display name is not a
    /// canonical plug-in identity. Controls view exposes these AX facts, but it
    /// exposes no measured canonical AU/component identifier.
    struct IdentityEvidence: Codable, Equatable, Sendable {
        let pluginName: String
        let pluginNameSource: PluginNameSource
        let windowTitle: String
        let directStaticTextValues: [String]
        let observedWindowAXIdentifier: String?
        let canonicalPluginIdentifier: String?
    }

    enum RowClassification: Equatable, Sendable {
        /// A labelled row whose AXCell contains exactly one supported control.
        /// The value readability is retained so an addressable control with no
        /// readable value is never misrepresented as readback-capable.
        case parameter(
            controlRole: GenericParameterControlRole,
            valueIsReadable: Bool
        )
        /// No supported control shares a cell with a row label.
        case refusedNoControl
        /// A row maps to more than one supported control, so selecting one
        /// would inherit AX traversal order rather than an address.
        case refusedAmbiguousControl(roles: [String])
        /// The label and the supported control occurred in different cells.
        case refusedUnpairedLabelAndControl
        /// An empty label cannot form a stable row address.
        case refusedEmptyLabel
        /// Logic's inactive placeholder label cannot form a stable row address.
        case refusedPlaceholderLabel
        /// Multiple label candidates make the row address ambiguous.
        case refusedAmbiguousLabel

        fileprivate var signatureState: String {
            switch self {
            case .parameter(let role, true):
                return "parameter_readable_\(role.rawValue)"
            case .parameter(let role, false):
                return "parameter_unreadable_\(role.rawValue)"
            case .refusedNoControl:
                return "refused_no_control"
            case .refusedAmbiguousControl(let roles):
                return "refused_ambiguous_control_\(roles.joined(separator: ","))"
            case .refusedUnpairedLabelAndControl:
                return "refused_unpaired_label_and_control"
            case .refusedEmptyLabel:
                return "refused_empty_label"
            case .refusedPlaceholderLabel:
                return "refused_placeholder_label"
            case .refusedAmbiguousLabel:
                return "refused_ambiguous_label"
            }
        }
    }

    struct RowObservation: Equatable, Sendable {
        let rowIndex: Int
        let observedLabel: String?
        /// Every supported role found in the row's AXCells, including roles
        /// on rows refused for their label. This makes the read observation
        /// auditable without pretending an unaddressable row is writable.
        let controlRoles: [String]
        let valueDescription: String?
        let valueIsSettable: Bool?
        let classification: RowClassification
    }

    struct Result: Equatable, Sendable {
        let manifest: PluginCapabilityManifest
        let rowObservations: [RowObservation]
        let identityEvidence: IdentityEvidence
    }

    /// Enumerate the measured Controls-view table in an already-open plug-in
    /// editor. The caller supplies the host/build fingerprint because the
    /// measured AX tree contains no trustworthy plug-in build identity.
    static func enumerate(
        in editorWindow: AXUIElement,
        buildFingerprint: String,
        runtime: AXHelpers.Runtime = .production
    ) -> Result? {
        let trimmedBuildFingerprint = buildFingerprint.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedBuildFingerprint.isEmpty,
              role(of: editorWindow, runtime: runtime) == (kAXWindowRole as String),
              let identityEvidence = identityEvidence(
                  for: editorWindow,
                  runtime: runtime
              ),
              let table = controlsTable(in: editorWindow, runtime: runtime),
              let rows = rows(in: table, runtime: runtime),
              controlsViewStateIsBound(rows: rows, runtime: runtime) else {
            return nil
        }

        var parameters: [GenericPluginParameter] = []
        var observations: [RowObservation] = []
        var rowSignatures: [RowSignature] = []

        for (rowIndex, row) in rows.enumerated() {
            // A failed AXValue read for a label has neither established an
            // empty label nor a stable UI signature. Refuse the whole
            // manifest: hashing `nil` would alias distinct unreadable labels.
            guard let rowRead = readRow(row, runtime: runtime) else {
                return nil
            }

            let classification: RowClassification
            let label: String?
            let parameterControl: ControlObservation?

            if rowRead.labels.count > 1 {
                label = nil
                parameterControl = nil
                classification = .refusedAmbiguousLabel
            } else if let candidate = rowRead.pairedCandidates.only {
                label = candidate.label
                parameterControl = candidate.control
                classification = classify(
                    for: candidate.label,
                    control: candidate.control
                )
            } else if let onlyLabel = rowRead.labels.only {
                label = onlyLabel
                parameterControl = nil
                classification = classificationForUnpairedRow(rowRead, label: onlyLabel)
            } else {
                label = nil
                parameterControl = nil
                classification = .refusedEmptyLabel
            }

            let observedRoleStrings = rowRead.controls.map { $0.role.rawValue }.sorted()
            let controlForObservation = parameterControl ?? rowRead.controls.only
            observations.append(RowObservation(
                rowIndex: rowIndex,
                observedLabel: label,
                controlRoles: observedRoleStrings,
                valueDescription: controlForObservation?.valueDescription,
                valueIsSettable: controlForObservation?.valueIsSettable,
                classification: classification
            ))
            rowSignatures.append(RowSignature(
                label: label,
                controlRoles: observedRoleStrings,
                refusalState: classification.signatureState
            ))

            guard case let .parameter(controlRole, valueIsReadable) = classification,
                  let label,
                  parameterControl != nil else {
                continue
            }

            let parameterName = colonStrippedParameterName(label)
            guard !parameterName.isEmpty else {
                // `classification(for:)` handles a blank direct label. This
                // protects the colon-only spelling without turning it into a
                // parameter after the fact.
                continue
            }
            parameters.append(GenericPluginParameter(
                parameterRef: TargetReference(rawValue: "controls_view_row_\(rowIndex)"),
                name: parameterName,
                // AX's settable claim is not a write/readback round trip. A
                // readable value supports only readback; unreadable values are
                // retained as addressable but unsupported observations.
                valueKind: valueIsReadable ? .normalizedReadbackOnly : .unsupported,
                controlRole: controlRole,
                page: 0,
                // Preserve the table's physical row offset. In particular,
                // refusing '-' rows must never renumber later parameters.
                index: rowIndex
            ))
        }

        // This covers row label changes AND every observed trait that changes
        // whether a row is a parameter: paired control roles, readable-value
        // state, and the explicit refusal state. Values themselves are not
        // hashed: they move during ordinary plug-in use.
        let uiSignatureFingerprint = fingerprint(UISignature(orderedRows: rowSignatures))
        let manifestFingerprint = fingerprint(ManifestFingerprintInput(
            provider: .controlsViewAX,
            pluginName: identityEvidence.pluginName,
            buildFingerprint: trimmedBuildFingerprint,
            uiSignatureFingerprint: uiSignatureFingerprint,
            parameters: parameters,
            approved: false,
            identityEvidence: identityEvidence
        ))
        let manifest = PluginCapabilityManifest(
            provider: .controlsViewAX,
            pluginName: identityEvidence.pluginName,
            buildFingerprint: trimmedBuildFingerprint,
            uiSignatureFingerprint: uiSignatureFingerprint,
            parameters: parameters,
            // A newly observed layout needs explicit human approval before the
            // existing gate can expose it to a host-verified write path.
            approved: false,
            manifestFingerprint: manifestFingerprint
        )
        return Result(
            manifest: manifest,
            rowObservations: observations,
            identityEvidence: identityEvidence
        )
    }

    /// The manifest-only producer for callers that do not need diagnostic row
    /// classifications or header-identity evidence.
    static func manifest(
        from editorWindow: AXUIElement,
        buildFingerprint: String,
        runtime: AXHelpers.Runtime = .production
    ) -> PluginCapabilityManifest? {
        enumerate(
            in: editorWindow,
            buildFingerprint: buildFingerprint,
            runtime: runtime
        )?.manifest
    }

    private static func controlsTable(
        in editorWindow: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        // The caller may pass only a plug-in AXWindow. A sole AXTable below an
        // arbitrary element could be a browser, marker list, or another
        // unrelated table and must not mint a plug-in manifest.
        guard role(of: editorWindow, runtime: runtime) == (kAXWindowRole as String)
        else {
            return nil
        }
        guard let scanned = descendants(
            of: editorWindow,
            maxDepth: 8,
            runtime: runtime
        ) else {
            return nil
        }
        return scanned.filter { $0.role == (kAXTableRole as String) }
            .map(\.element)
            .only
    }

    private static func rows(
        in table: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [AXUIElement]? {
        let candidates: [AXUIElement]
        switch AXHelpers.getAXUIElementArrayRead(
            table,
            kAXRowsAttribute as String,
            runtime: runtime
        ) {
        case .success(.elements(let rows)):
            candidates = rows
        case .success(.absent):
            // AXChildren is an alternate table representation only when every
            // direct child proves to be an AXRow. It is never a general child
            // fallback for an unrelated table.
            switch AXHelpers.childrenResult(table, runtime: runtime) {
            case .success(let children):
                candidates = children
            case .failure:
                return nil
            }
        case .success(.malformed), .failure:
            return nil
        }
        guard !candidates.isEmpty,
              candidates.allSatisfy({
                  role(of: $0, runtime: runtime) == (kAXRowRole as String)
              }) else {
            return nil
        }
        return candidates
    }

    /// The Controls-view state is structurally bound to the observed AX shape:
    /// each table row has AXCells and each row contains a supported control in
    /// one of those cells. The live evidence makes this a Controls-view fact;
    /// it prevents a bare AXTable with arbitrary children from qualifying.
    private static func controlsViewStateIsBound(
        rows: [AXUIElement],
        runtime: AXHelpers.Runtime
    ) -> Bool {
        rows.allSatisfy { row in
            guard let cells = rowCells(in: row, runtime: runtime), !cells.isEmpty else {
                return false
            }
            var hasControl = false
            for cell in cells {
                guard let contents = cellContents(in: cell, runtime: runtime) else {
                    return false
                }
                hasControl = hasControl || !contents.controls.isEmpty
            }
            return hasControl
        }
    }

    private static func readRow(
        _ row: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> RowRead? {
        var labelValues: [String] = []
        var controlsInRow: [ControlObservation] = []
        var pairedCandidates: [PairedCandidate] = []

        guard let cells = rowCells(in: row, runtime: runtime) else {
            return nil
        }
        for cell in cells {
            guard let contents = cellContents(in: cell, runtime: runtime) else {
                return nil
            }
            let cellLabels = contents.labels
            let cellControls = contents.controls
            labelValues.append(contentsOf: cellLabels)
            controlsInRow.append(contentsOf: cellControls)
            if let label = cellLabels.only, let control = cellControls.only {
                pairedCandidates.append(PairedCandidate(label: label, control: control))
            }
        }
        return RowRead(
            labels: labelValues,
            controls: controlsInRow,
            pairedCandidates: pairedCandidates
        )
    }

    private static func rowCells(
        in row: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [AXUIElement]? {
        descendants(
            of: row,
            maxDepth: 3,
            runtime: runtime
        )?.compactMap { $0.role == (kAXCellRole as String) ? $0.element : nil }
    }

    /// Scans the complete cell subtree once, retaining the status of every
    /// child and role read before either labels or controls can influence row
    /// classification and the UI signature.
    private static func cellContents(
        in cell: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> CellContents? {
        guard let scanned = descendants(
            of: cell,
            maxDepth: 4,
            runtime: runtime
        ), case .values(let labels) = labels(in: scanned, runtime: runtime) else {
            return nil
        }
        return CellContents(
            labels: labels,
            controls: controls(in: scanned, runtime: runtime)
        )
    }

    private static func labels(
        in descendants: [DescendantRead],
        runtime: AXHelpers.Runtime
    ) -> LabelRead {
        let textElements = descendants.filter {
            $0.role == (kAXStaticTextRole as String)
        }.map(\.element)
        var values: [String] = []
        for text in textElements {
            let valueRead: Swift.Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                text,
                kAXValueAttribute as String,
                runtime: runtime
            )
            switch valueRead {
            case .success(.some(let raw)):
                guard let value = raw as? String else {
                    return .unreadable
                }
                values.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
            case .success(.none), .failure:
                return .unreadable
            }
        }
        return .values(values)
    }

    private static func controls(
        in descendants: [DescendantRead],
        runtime: AXHelpers.Runtime
    ) -> [ControlObservation] {
        descendants.compactMap { descendant in
            guard let role = GenericParameterControlRole(rawValue: descendant.role) else {
                return nil
            }
            return ControlObservation(
                role: role,
                valueIsReadable: valueIsReadable(on: descendant.element, runtime: runtime),
                valueDescription: valueDescription(on: descendant.element, runtime: runtime),
                valueIsSettable: AXHelpers.isAttributeSettable(
                    descendant.element,
                    kAXValueAttribute as String,
                    runtime: runtime
                )
            )
        }
    }

    private static func valueIsReadable(
        on control: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let valueRead: Swift.Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            control,
            kAXValueAttribute as String,
            runtime: runtime
        )
        switch valueRead {
        case .success(.some):
            return true
        case .success(.none), .failure:
            return valueDescription(on: control, runtime: runtime) != nil
        }
    }

    private static func valueDescription(
        on control: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        let descriptionRead: Swift.Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            control,
            kAXValueDescriptionAttribute as String,
            runtime: runtime
        )
        switch descriptionRead {
        case .success(.some(let raw)):
            return trimmed(raw as? String)
        case .success(.none), .failure:
            return nil
        }
    }

    private static func classify(
        for label: String,
        control: ControlObservation
    ) -> RowClassification {
        if label.isEmpty || colonStrippedParameterName(label).isEmpty {
            return .refusedEmptyLabel
        }
        if label == "-" {
            return .refusedPlaceholderLabel
        }
        return .parameter(
            controlRole: control.role,
            valueIsReadable: control.valueIsReadable
        )
    }

    private static func classificationForUnpairedRow(
        _ row: RowRead,
        label: String
    ) -> RowClassification {
        if label.isEmpty || colonStrippedParameterName(label).isEmpty {
            return .refusedEmptyLabel
        }
        if label == "-" {
            return .refusedPlaceholderLabel
        }
        if row.controls.isEmpty {
            return .refusedNoControl
        }
        if row.controls.count > 1 {
            return .refusedAmbiguousControl(
                roles: row.controls.map { $0.role.rawValue }.sorted()
            )
        }
        return .refusedUnpairedLabelAndControl
    }

    private static func identityEvidence(
        for editorWindow: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> IdentityEvidence? {
        // A missing, empty, malformed, or unreadable title cannot establish
        // which direct header text is the track. Refuse rather than weakening
        // the exclusion and accidentally promoting the track name.
        let titleRead: Swift.Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            editorWindow,
            kAXTitleAttribute as String,
            runtime: runtime
        )
        guard case .success(.some(let rawTitle)) = titleRead,
              let windowTitle = trimmed(rawTitle as? String) else {
            return nil
        }
        guard case .success(let children) = AXHelpers.childrenResult(
            editorWindow,
            runtime: runtime
        ) else {
            return nil
        }
        var staticTextValues: [String] = []
        for child in children {
            guard let childRole = role(of: child, runtime: runtime) else {
                return nil
            }
            guard childRole == (kAXStaticTextRole as String) else {
                continue
            }
            let valueRead: Swift.Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                child,
                kAXValueAttribute as String,
                runtime: runtime
            )
            guard case .success(.some(let rawValue)) = valueRead,
                  let value = trimmed(rawValue as? String) else {
                return nil
            }
            staticTextValues.append(value)
        }
        // A view-menu label such as "보기:" is direct header text but not the
        // plug-in display name. It is recognized structurally by its trailing
        // colon; the actual name is still read from a direct AXStaticText.
        let pluginCandidates = staticTextValues.filter { value in
            value != windowTitle && !value.hasSuffix(":")
        }
        guard pluginCandidates.count == 1, let pluginName = pluginCandidates.first else {
            return nil
        }

        let identifierRead: Swift.Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            editorWindow,
            kAXIdentifierAttribute as String,
            runtime: runtime
        )
        let observedWindowAXIdentifier: String?
        switch identifierRead {
        case .success(.none):
            observedWindowAXIdentifier = nil
        case .success(.some(let rawIdentifier)):
            guard let identifier = rawIdentifier as? String else {
                return nil
            }
            observedWindowAXIdentifier = trimmed(identifier)
        case .failure:
            return nil
        }

        return IdentityEvidence(
            pluginName: pluginName,
            pluginNameSource: .directWindowStaticText,
            windowTitle: windowTitle,
            directStaticTextValues: staticTextValues,
            observedWindowAXIdentifier: observedWindowAXIdentifier,
            // The measured AX fields are display/header evidence only. Do not
            // turn an AX identifier or display string into canonical AU identity.
            canonicalPluginIdentifier: nil
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func colonStrippedParameterName(_ label: String) -> String {
        guard label.hasSuffix(":") else { return label }
        return String(label.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A role is a required part of every structural scan in this enumerator.
    /// Treat failed, absent, malformed, and empty reads alike: any of them
    /// leaves open the possibility that an unclassified node was a relevant
    /// table, cell, label, or control.
    private static func role(
        of element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        let roleRead: Swift.Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            element,
            kAXRoleAttribute as String,
            runtime: runtime
        )
        guard case .success(.some(let rawRole)) = roleRead,
              let role = rawRole as? String,
              !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return role
    }

    /// Unlike `findAllDescendants`, this scan preserves AXChildren and AXRole
    /// failures. A partial traversal cannot prove that a cell has exactly one
    /// control, nor can it safely contribute a UI signature.
    private static func descendants(
        of element: AXUIElement,
        maxDepth: Int,
        runtime: AXHelpers.Runtime
    ) -> [DescendantRead]? {
        var found: [DescendantRead] = []
        guard collectDescendants(
            of: element,
            maxDepth: maxDepth,
            runtime: runtime,
            into: &found
        ) else {
            return nil
        }
        return found
    }

    private static func collectDescendants(
        of element: AXUIElement,
        maxDepth: Int,
        runtime: AXHelpers.Runtime,
        into found: inout [DescendantRead]
    ) -> Bool {
        guard maxDepth > 0 else { return true }
        guard case .success(let children) = AXHelpers.childrenResult(
            element,
            runtime: runtime
        ) else {
            return false
        }
        for child in children {
            guard let childRole = role(of: child, runtime: runtime) else {
                return false
            }
            found.append(DescendantRead(element: child, role: childRole))
            guard collectDescendants(
                of: child,
                maxDepth: maxDepth - 1,
                runtime: runtime,
                into: &found
            ) else {
                return false
            }
        }
        return true
    }

    private static func fingerprint<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else {
            // Every current input is finite strings/integers and encodable. If
            // that invariant changes, fail closed rather than aliasing a valid
            // manifest fingerprint to an invented fallback value.
            return "unencodable:\(UUID().uuidString)"
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum LabelRead {
        case values([String])
        case unreadable
    }

    private struct DescendantRead {
        let element: AXUIElement
        let role: String
    }

    private struct CellContents {
        let labels: [String]
        let controls: [ControlObservation]
    }

    private struct ControlObservation {
        let role: GenericParameterControlRole
        let valueIsReadable: Bool
        let valueDescription: String?
        let valueIsSettable: Bool?
    }

    private struct PairedCandidate {
        let label: String
        let control: ControlObservation
    }

    private struct RowRead {
        let labels: [String]
        let controls: [ControlObservation]
        let pairedCandidates: [PairedCandidate]
    }

    private struct RowSignature: Encodable {
        let label: String?
        let controlRoles: [String]
        let refusalState: String
    }

    private struct UISignature: Encodable {
        let orderedRows: [RowSignature]
    }

    private struct ManifestFingerprintInput: Encodable {
        let provider: PluginParameterProvider
        let pluginName: String
        let buildFingerprint: String
        let uiSignatureFingerprint: String
        let parameters: [GenericPluginParameter]
        let approved: Bool
        let identityEvidence: IdentityEvidence
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}

/// Convenience entry point for the manifest-only producer.
func enumerateControlsViewManifest(
    from editorWindow: AXUIElement,
    buildFingerprint: String,
    runtime: AXHelpers.Runtime = .production
) -> PluginCapabilityManifest? {
    ControlsViewParameterEnumerator.manifest(
        from: editorWindow,
        buildFingerprint: buildFingerprint,
        runtime: runtime
    )
}
