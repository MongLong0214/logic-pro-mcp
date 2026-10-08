import ApplicationServices
import Foundation

/// Observation inside an editor whose occupied-instance custody is held by the caller.
/// This component owns no UI actions or public reference resolution.
enum ChannelEQControlsStateReader {
    private static let bands: [(name: String, role: EQBandRole)] = [
        ("Low Cut", .highPass), ("Low Shelf", .lowShelf),
        ("Peak 1", .parametric1), ("Peak 2", .parametric2),
        ("Peak 3", .parametric3), ("Peak 4", .parametric4),
        ("High Shelf", .highShelf), ("High Cut", .lowPass),
    ]

    private struct ObservationFailure: Error { let status: String }
    private struct Sample {
        let field: [String: Any]
        let controls: [AXUIElement]
    }

    static func collect(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime,
        contextIsCurrent: () -> Bool
    ) -> [String: Any] {
        // Two full collections detect observed changes across fields. Stable
        // bookends are not an atomic host snapshot or a lock on external UI.
        let before = snapshot(in: window, runtime: runtime, contextIsCurrent: contextIsCurrent)
        let after = snapshot(in: window, runtime: runtime, contextIsCurrent: contextIsCurrent)
        let current = contextIsCurrent() && !Task.isCancelled
        var reasons: [String] = current ? [] : ["context_ended"]
        func reconciled(_ label: String) -> [String: Any] {
            guard current else { return unavailable("context_ended") }
            guard let first = before[label], let last = after[label] else { return unavailable("unknown") }
            guard NSDictionary(dictionary: first.field).isEqual(to: last.field),
                  first.controls.count == last.controls.count,
                  zip(first.controls, last.controls).allSatisfy({ CFEqual($0.0, $0.1) }) else {
                return unavailable("unstable")
            }
            return last.field
        }
        let output: [[String: Any]] = bands.enumerated().map { index, band in
            let cut = band.role == .highPass || band.role == .lowPass
            let fields: [(String, String)] = [
                ("frequency", "Frequency"), (cut ? "slope" : "gain", cut ? "Slope" : "Gain"),
                ("q", "Q-Factor"), ("enabled", "On/Off"),
            ]
            var result: [String: Any] = ["band": index + 1, "name": band.name, "filter_role": band.role.rawValue]
            result[cut ? "gain" : "slope"] = unavailable("not_applicable")
            for (key, suffix) in fields {
                let value = reconciled("\(band.name) \(suffix)")
                result[key] = value
                if value["read_status"] as? String != "read" {
                    reasons.append("\(band.name).\(key):\(value["read_status"] as? String ?? "unknown")")
                }
            }
            return result
        }
        let enabled = reconciled("plugin_enabled")
        var bypass = enabled
        if enabled["read_status"] as? String == "read", let value = enabled["observed_raw"] as? Bool {
            bypass["observed_raw"] = !value
            bypass["derived_from"] = "host_plugin_enabled"
        }
        return [
            "bands": output, "complete": reasons.isEmpty, "partial_reasons": reasons,
            "plugin_enabled": enabled, "plugin_bypass": bypass,
            "observation_scope": "current_insert_eight_band_raw_and_host_display",
            "snapshot_atomic": false,
        ]
    }

    private static func unavailable(_ status: String) -> [String: Any] {
        ["read_status": status, "observed_raw": NSNull(), "raw_unit": NSNull(),
         "observed_display": NSNull(), "display_read_status": status]
    }

    private static func attribute(_ element: AXUIElement, _ name: String, runtime: AXHelpers.Runtime) throws -> AnyObject? {
        switch AXHelpers.getAttributeResult(element, name, runtime: runtime) as Result<AnyObject?, AXHelpers.AXStatusError> {
        case .success(let value): return value
        case .failure(let error) where error.isDefinitiveAbsence: return nil
        case .failure: throw ObservationFailure(status: "unreadable")
        }
    }

    private static func role(_ element: AXUIElement, runtime: AXHelpers.Runtime) throws -> String {
        guard let value = try attribute(element, kAXRoleAttribute as String, runtime: runtime) as? String else {
            throw ObservationFailure(status: "malformed")
        }
        return value
    }

    private static func children(_ element: AXUIElement, runtime: AXHelpers.Runtime) throws -> [AXUIElement] {
        guard case .success(let value) = AXHelpers.childrenResult(element, runtime: runtime) else {
            throw ObservationFailure(status: "unreadable")
        }
        return value
    }

    private static func number(_ element: AXUIElement, runtime: AXHelpers.Runtime) throws -> Double {
        guard let raw = try attribute(element, kAXValueAttribute as String, runtime: runtime) else {
            throw ObservationFailure(status: "absent")
        }
        let value: Double?
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { value = number.doubleValue }
        else if let text = raw as? String { value = Double(text) }
        else { value = nil }
        guard let value, value.isFinite else { throw ObservationFailure(status: "malformed") }
        return value
    }

    private static func sample(cell: AXUIElement, kind: String, runtime: AXHelpers.Runtime) throws -> Sample {
        let candidates = try children(cell, runtime: runtime).filter {
            let value = try role($0, runtime: runtime)
            return [kAXSliderRole as String, kAXCheckBoxRole as String, kAXPopUpButtonRole as String].contains(value)
        }
        guard candidates.count == 1, let control = candidates.first else {
            throw ObservationFailure(status: candidates.isEmpty ? "absent" : "ambiguous")
        }
        let observedRole = try role(control, runtime: runtime)
        let raw: Any
        let rawUnit: String
        var display: String?
        var displayStatus = "absent"
        var held = [control]
        if kind == "On/Off" {
            guard observedRole == (kAXCheckBoxRole as String) else { throw ObservationFailure(status: "unsupported") }
            switch AXValueExtractors.extractButtonStateResult(control, runtime: runtime) {
            case .success(.some(let value)): raw = value
            case .success(.none): throw ObservationFailure(status: "malformed")
            case .failure: throw ObservationFailure(status: "unreadable")
            }
            rawUnit = "boolean"
        } else if kind == "Slope" {
            guard observedRole == (kAXPopUpButtonRole as String) else { throw ObservationFailure(status: "unsupported") }
            guard let value = try attribute(control, kAXValueAttribute as String, runtime: runtime) as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ObservationFailure(status: "malformed")
            }
            raw = value
            rawUnit = "host_choice_text"
            display = value
            displayStatus = "read"
        } else {
            guard observedRole == (kAXSliderRole as String) else { throw ObservationFailure(status: "unsupported") }
            let value = try number(control, runtime: runtime)
            raw = value
            rawUnit = "raw_ax_value"
            guard case .success(let census) = AXHelpers.censusDescendantResult(
                of: cell, role: kAXSliderRole, maxDepth: 5, runtime: runtime
            ) else { throw ObservationFailure(status: "unreadable") }
            // Logic's measured Controls cell has a direct slider plus a nested
            // inline display slider. Both must agree; no arbitrary first match.
            guard (1...2).contains(census.matches.count),
                  census.matches.contains(where: { CFEqual($0, control) }) else {
                throw ObservationFailure(status: "ambiguous")
            }
            held = [control] + census.matches.filter { !CFEqual($0, control) }
            for candidate in held {
                guard try number(candidate, runtime: runtime) == value else { throw ObservationFailure(status: "unstable") }
                let description = try attribute(candidate, kAXValueDescriptionAttribute as String, runtime: runtime)
                if let description {
                    guard let text = description as? String else { throw ObservationFailure(status: "malformed") }
                    if let display, display != text { throw ObservationFailure(status: "unstable") }
                    display = text
                    displayStatus = "read"
                }
            }
        }
        if rawUnit == "raw_ax_value", let display, display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayStatus = "malformed"
        }
        let status = rawUnit == "raw_ax_value" && displayStatus != "read" ? "display_\(displayStatus)" : "read"
        return Sample(field: ["read_status": status, "observed_raw": raw, "raw_unit": rawUnit,
                              "observed_display": display ?? NSNull(), "display_read_status": displayStatus], controls: held)
    }

    private static func snapshot(
        in window: AXUIElement, runtime: AXHelpers.Runtime, contextIsCurrent: () -> Bool
    ) -> [String: Sample] {
        var result: [String: Sample] = [:]
        func refused(_ status: String) -> Sample { Sample(field: unavailable(status), controls: []) }
        var cellsByLabel: [String: [AXUIElement]] = [:]
        var globalFailure: String?
        do {
            guard contextIsCurrent(), !Task.isCancelled else { throw ObservationFailure(status: "context_ended") }
            guard case .success(let census) = AXHelpers.censusDescendantResult(
                of: window, role: kAXTableRole, maxDepth: 8, runtime: runtime
            ) else { throw ObservationFailure(status: "unreadable") }
            guard census.matches.count == 1, let table = census.matches.first else {
                throw ObservationFailure(status: census.matches.isEmpty ? "absent" : "ambiguous")
            }
            let rows: [AXUIElement]
            switch AXHelpers.getAXUIElementArrayRead(table, kAXRowsAttribute as String, runtime: runtime) {
            case .success(.elements(let observed)): rows = observed
            case .success(.absent): rows = try children(table, runtime: runtime)
            case .failure(let error) where error.isDefinitiveAbsence: rows = try children(table, runtime: runtime)
            case .success(.malformed): throw ObservationFailure(status: "malformed")
            case .failure: throw ObservationFailure(status: "unreadable")
            }
            for row in rows {
                guard try role(row, runtime: runtime) == (kAXRowRole as String) else { throw ObservationFailure(status: "malformed") }
                let cells = try children(row, runtime: runtime)
                guard cells.count == 1, let cell = cells.first,
                      try role(cell, runtime: runtime) == (kAXCellRole as String) else { throw ObservationFailure(status: "malformed") }
                let labels = try children(cell, runtime: runtime).filter { try role($0, runtime: runtime) == (kAXStaticTextRole as String) }
                guard labels.count == 1, let label = labels.first,
                      let text = try attribute(label, kAXValueAttribute as String, runtime: runtime) as? String else {
                    throw ObservationFailure(status: "malformed")
                }
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
                cellsByLabel[name, default: []].append(cell)
            }
        } catch let error as ObservationFailure { globalFailure = error.status }
        catch { globalFailure = "unreadable" }
        for band in bands {
            let contextEnded = !contextIsCurrent() || Task.isCancelled
            let cut = band.role == .highPass || band.role == .lowPass
            for kind in ["Frequency", cut ? "Slope" : "Gain", "Q-Factor", "On/Off"] {
                let label = "\(band.name) \(kind)"
                if contextEnded { result[label] = refused("context_ended"); continue }
                if let globalFailure { result[label] = refused(globalFailure); continue }
                guard let cells = cellsByLabel[label], cells.count == 1, let cell = cells.first else {
                    result[label] = refused(cellsByLabel[label] == nil ? "absent" : "ambiguous")
                    continue
                }
                do { result[label] = try sample(cell: cell, kind: kind, runtime: runtime) }
                catch let error as ObservationFailure { result[label] = refused(error.status) }
                catch { result[label] = refused("unreadable") }
            }
        }
        do {
            guard contextIsCurrent(), !Task.isCancelled else { throw ObservationFailure(status: "context_ended") }
            let candidates = try children(window, runtime: runtime).filter {
                guard try role($0, runtime: runtime) == (kAXCheckBoxRole as String) else { return false }
                return try attribute($0, kAXDescriptionAttribute as String, runtime: runtime) as? String == "bypass"
            }
            guard candidates.count == 1, let control = candidates.first else { throw ObservationFailure(status: "ambiguous") }
            guard case .success(.some(let enabled)) = AXValueExtractors.extractButtonStateResult(control, runtime: runtime) else {
                throw ObservationFailure(status: "unreadable")
            }
            result["plugin_enabled"] = Sample(field: ["read_status": "read", "observed_raw": enabled,
                "raw_unit": "boolean", "observed_display": NSNull(), "display_read_status": "absent"], controls: [control])
        } catch let error as ObservationFailure { result["plugin_enabled"] = refused(error.status) }
        catch { result["plugin_enabled"] = refused("unreadable") }
        return result
    }
}
