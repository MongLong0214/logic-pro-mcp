import Foundation
import MCP

extension PluginsDispatcher {
    /// Transient read-only diff. The outer dispatcher holds the existing UI lease;
    /// this does not retain a plan, authorize application, or claim an atomic snapshot.
    static func parameterPlan(changes: [Value], pluginID: String, readParams: [String: String],
                              router: ChannelRouter, contextIsCurrent: () async -> Bool) async -> ChannelResult {
        struct Entry {
            let index: Int
            let request: Value
            let param: String?
            let metadata: StockPluginParameterMetadata?
            let requested: Double?
            var status: String
            var before: Double?
            var receipts: [[String: Any]] = []
        }
        let catalog = VerifiedPluginCatalog.productionEntryLookup(pluginID)
        var entries: [Entry] = changes.enumerated().map { index, request in
            let fields = request.objectValue ?? [:]
            let param = fields["param"]?.stringValue.map {
                VerifiedPluginCatalog.canonicalParamKey(pluginID: pluginID, alias: $0)
                    ?? $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            let metadata = catalog?.parameters.first { $0.id == param }
            let requested: Double?
            switch fields["value"] {
            case .int(let value): requested = Double(value)
            case .double(let value) where value.isFinite: requested = value
            case .bool(let value) where metadata?.unit == "boolean": requested = value ? 1 : 0
            default: requested = nil
            }
            var status = "pending"
            if request.objectValue == nil || param == nil || param == "" { status = "invalid_request" }
            else if metadata == nil { status = "unknown_parameter" }
            else if let metadata {
                let directSlider = metadata.readbackMethod == "ax_slider_axvalue" && metadata.axDescription != nil
                let controlsViewSlider = metadata.readbackMethod == "ax_controls_view_slider_display"
                    && metadata.controlsViewControlRole == "AXSlider" && metadata.controlsViewRowLabel != nil
                let checkbox = metadata.readbackMethod == "ax_controls_view_checkbox_value"
                    && metadata.controlsViewControlRole == "AXCheckBox" && metadata.controlsViewRowLabel != nil
                // This operation is a read-only diff and always returns
                // `application_authorized:false`; a qualified reader does not
                // need a writer merely to compare the requested value.
                if !(directSlider || controlsViewSlider || checkbox) { status = "unsupported" }
                else {
                    let unit = fields["unit"]?.stringValue
                    // Only Compressor's declared percent aliases share the raw scale.
                    // Engineering EQ units need host conversion; they are not raw B1 targets.
                    let sameScaleAlias: Bool
                    if pluginID == "logic.stock.effect.compressor", param == "threshold", let unit,
                       let aliases = metadata.acceptedUnits { sameScaleAlias = aliases.contains(unit) }
                    else { sameScaleAlias = false }
                    if !Set(fields.keys).isSubset(of: ["param", "value", "unit"])
                        || requested == nil || unit == nil || (unit != metadata.unit && !sameScaleAlias) {
                        status = "invalid_request"
                    } else if let requested, let range = metadata.valueRange,
                              !(requested >= range.min && requested <= range.max) { status = "out_of_range" }
                    else if metadata.unit == "boolean", requested != 0 && requested != 1 { status = "out_of_range" }
                }
            }
            return Entry(index: index, request: request, param: param, metadata: metadata,
                         requested: requested, status: status)
        }
        let duplicates = Dictionary(grouping: entries.compactMap(\.param), by: { $0 })
            .filter { $0.value.count > 1 }.keys
        for index in entries.indices {
            if let param = entries[index].param, duplicates.contains(param) { entries[index].status = "duplicate_parameter" }
        }
        entries.sort { ($0.param ?? "", $0.index) < ($1.param ?? "", $1.index) }
        func envelope(error: HonestContract.FailureError? = nil) -> ChannelResult {
            let complete = entries.allSatisfy { $0.status == "change" || $0.status == "unchanged" }
            let rows: [[String: Any]] = entries.map { entry in
                var row: [String: Any] = ["request_index": entry.index,
                    "requested": ResourceHandlers.jsonObject(entry.request), "param": entry.param as Any? ?? NSNull(),
                    "status": entry.status == "pending" ? "not_observed" : entry.status, "read_observations": entry.receipts]
                if let unit = entry.metadata?.unit { row["raw_unit"] = unit }
                if let requested = entry.requested { row["requested_value"] = requested }
                if let before = entry.before, let requested = entry.requested {
                    row["observed_before"] = entry.metadata?.unit == "boolean" ? (before == 1) as Any : before as Any
                    row["delta"] = requested - before
                }
                return row
            }
            let extras: [String: Any] = ["operation": "logic_plugins.plan_parameter_changes", "complete": complete,
                "observation_scope": "requested_supported_subset", "atomic_snapshot": false,
                "application_authorized": false, "write_attempted": false,
                "target_identity": ["track_index": Int(readParams["track"] ?? "") as Any? ?? NSNull(),
                    "insert": Int(readParams["insert"] ?? "") as Any? ?? NSNull(), "plugin_id": pluginID], "entries": rows]
            if let error { return .error(HonestContract.encodeV2StateC(error: error, extras: extras)) }
            return .success(complete ? HonestContract.encodeV2StateA(extras: extras)
                : HonestContract.encodeV2StateB(reason: .readbackUnavailable, extras: extras))
        }
        guard entries.allSatisfy({ $0.status == "pending" }) else { return envelope(error: .invalidParams) }
        func contextLost() -> ChannelResult {
            for index in entries.indices { entries[index].status = "context_lost"; entries[index].before = nil }
            return envelope(error: Task.isCancelled ? .cancelled : .staleTargetReference)
        }
        for sweep in 0..<2 {
            for index in entries.indices {
                guard !Task.isCancelled, await contextIsCurrent() else { return contextLost() }
                guard let metadata = entries[index].metadata, let param = entries[index].param else {
                    return envelope(error: .invalidParams)
                }
                var params = readParams
                params["param"] = param; params["unit"] = metadata.unit
                let result = await router.route(operation: "plugin.get_param_verified", params: params)
                let object = decodedJSONObject(result.message) ?? [:]
                entries[index].receipts.append(["bookend": sweep == 0 ? "initial" : "final", "response": object])
                guard !Task.isCancelled, await contextIsCurrent() else { return contextLost() }
                let identity = object["target_identity"] as? [String: Any]
                let observed = object["observed_raw"].flatMap { raw -> Double? in
                    if metadata.unit == "boolean" {
                        guard JSONInspector.isBoolean(raw), let flag = raw as? Bool else { return nil }
                        return flag ? 1 : 0
                    }
                    return JSONInspector.number(of: raw)
                }
                guard result.isSuccess, object["state"] as? String == "A",
                      let success = object["success"], JSONInspector.isBoolean(success), (success as? Bool) == true,
                      let verified = object["verified"], JSONInspector.isBoolean(verified), (verified as? Bool) == true,
                      object["hc_schema"].flatMap(JSONInspector.number) == 2,
                      object["operation"] as? String == "logic_plugins.get_param_verified",
                      object["parameter_read_status"] as? String == "read",
                      object["observation_scope"] as? String == "current_insert_parameter",
                      object["verify_source"] as? String == "ax_plugin_window",
                      let write = object["write_attempted"], JSONInspector.isBoolean(write), (write as? Bool) == false,
                      identity?["plugin_id"] as? String == pluginID,
                      identity?["track_index"].flatMap(JSONInspector.number) == Double(readParams["track"] ?? ""),
                      identity?["insert"].flatMap(JSONInspector.number) == Double(readParams["insert"] ?? ""),
                      object["param"] as? String == param, object["raw_unit"] as? String == metadata.unit,
                      let observed, observed.isFinite else {
                    entries[index].status = object["parameter_read_status"] as? String ?? "unknown"
                    if entries[index].status == "read" { entries[index].status = "unknown" }
                    entries[index].before = nil
                    return envelope(error: .readbackUnavailable)
                }
                if sweep == 0 { entries[index].before = observed }
                else if entries[index].before != observed {
                    entries[index].status = "unstable"; entries[index].before = nil
                    return envelope(error: .readbackUnavailable)
                } else { entries[index].status = observed == entries[index].requested ? "unchanged" : "change" }
            }
        }
        guard await contextIsCurrent() else { return contextLost() }
        return envelope()
    }

    static func parameterPlanContextFailure(_ result: ChannelResult) -> ChannelResult {
        var extras = decodedJSONObject(result.message) ?? [:]
        for key in ["success", "verified", "state", "hc_schema", "error", "reason"] { extras.removeValue(forKey: key) }
        var entries = extras["entries"] as? [[String: Any]] ?? []
        for index in entries.indices {
            entries[index]["status"] = "context_lost"
            entries[index].removeValue(forKey: "observed_before")
            entries[index].removeValue(forKey: "delta")
        }
        extras["entries"] = entries
        extras["complete"] = false
        return .error(HonestContract.encodeV2StateC(error: .staleTargetReference, extras: extras))
    }
}
