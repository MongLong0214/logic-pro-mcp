import Foundation
import MCP

extension PluginsDispatcher {
    static func addInventoryTargetReferences(
        to result: CallTool.Result,
        cache: StateCache,
        targetRegistry: TargetRegistry?,
        targetSnapshot: TargetRegistrySnapshot? = nil
    ) async -> CallTool.Result {
        guard FeatureFlags.adr002TargetRef,
              let targetRegistry,
              case .text(let rawJSON, let annotations, let meta) = result.content.first,
              var object = decodedJSONObject(rawJSON),
              object["state"] as? String == "A",
              object["complete"] as? Bool == true,
              let track = object["track"] as? Int,
              track >= 0,
              let trackName = object["track_name"] as? String,
              !trackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let mixerStripIndex = object["mixer_strip_index"] as? Int,
              mixerStripIndex >= 0,
              var plugins = object["plugins"] as? [[String: Any]] else {
            return result
        }

        let snapshot: TargetRegistrySnapshot
        if let targetSnapshot {
            snapshot = targetSnapshot
        } else {
            snapshot = await targetRegistry.currentSnapshot
        }
        let tracks = await cache.getTracks()
        // Inventory's independently observed Arrange identity owns the binding.
        // The cache may corroborate it, but cannot manufacture a name or turn a
        // Mixer ordinal into an Arrange index.
        let cachedTracks = tracks.filter { $0.id == track }
        guard cachedTracks.count <= 1,
              cachedTracks.allSatisfy({ $0.name == trackName }) else { return result }
        let descriptor = TargetDescriptor(trackIndex: track, trackName: trackName)
        var changed = false
        for index in plugins.indices {
            guard let insert = plugins[index]["insert"] as? Int, insert >= 0,
                  plugins.filter({ $0["insert"] as? Int == insert }).count == 1 else {
                continue
            }
            let pluginIdentity: String
            switch plugins[index]["read_status"] as? String {
            case "ok":
                guard plugins[index]["occupied"] as? Bool == true,
                      let name = plugins[index]["name"] as? String,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let observedID = VerifiedPluginCatalog.pluginID(forObservedName: name)
                if let reportedID = plugins[index]["plugin_id"] as? String {
                    guard !reportedID.isEmpty, reportedID == observedID else { continue }
                    pluginIdentity = reportedID
                } else {
                    pluginIdentity = observedID ?? name
                }
            case "empty":
                guard plugins[index]["occupied"] as? Bool == false,
                      !(plugins[index]["name"] is String),
                      !(plugins[index]["plugin_id"] is String) else { continue }
                pluginIdentity = ""
            default:
                continue
            }
            let fingerprint = TargetRefResolver.pluginInsertFingerprint(
                descriptor: descriptor,
                insert: insert,
                pluginIdentity: pluginIdentity
            )
            guard let reference = await targetRegistry.bind(
                kind: .pluginInsert,
                descriptor: descriptor,
                fingerprint: fingerprint,
                snapshot: snapshot
            ) else {
                continue
            }
            plugins[index]["plugin_insert_ref"] = reference.rawValue
            changed = true
        }
        guard changed else { return result }
        object["plugins"] = plugins
        let echoed = ResourceHandlers.encodeJSONObject(object)
        guard echoed != rawJSON else { return result }

        var content = result.content
        content[0] = .text(text: echoed, annotations: annotations, _meta: meta)
        return CallTool.Result(
            content: content,
            structuredContent: structuredContentValue(fromToolText: echoed),
            isError: result.isError,
            _meta: result._meta
        )
    }

    static func applyPluginInsertBinding(
        _ resolved: TargetRefResolver.Resolved,
        params: [String: Value],
        writeParams: inout [String: String],
        operation: String
    ) -> CallTool.Result? {
        guard let binding = resolved.binding, binding.kind == .pluginInsert else {
            return nil
        }
        guard let insert = binding.pluginInsertIndex,
              let pluginIdentity = TargetRefResolver.pluginInsertIdentity(from: binding) else {
            return TargetRefResolver.staleTargetReferenceResult(
                params["target_ref"]?.stringValue,
                operation: operation
            )
        }
        for key in ["insert", "slot"] where params[key] != nil {
            guard let requestedInsert = intParamOrNil(params, keys: [key]),
                  requestedInsert >= 0,
                  requestedInsert == insert else {
                return TargetRefResolver.staleTargetReferenceResult(
                    params["target_ref"]?.stringValue,
                    operation: operation
                )
            }
        }
        let inserting = operation == "logic_plugins.insert_verified"
        guard inserting ? pluginIdentity.isEmpty : !pluginIdentity.isEmpty else {
            return TargetRefResolver.staleTargetReferenceResult(
                params["target_ref"]?.stringValue, operation: operation
            )
        }
        if !inserting {
            let requestedIdentity: String?
            if operation == "logic_plugins.set_eq_band_verified" {
                requestedIdentity = "logic.stock.effect.channel_eq"
            } else {
                requestedIdentity = writeParams["plugin"]
            }
            guard let requestedIdentity,
                  (VerifiedPluginCatalog.canonicalPluginID(from: requestedIdentity) ?? requestedIdentity)
                    == (VerifiedPluginCatalog.canonicalPluginID(from: pluginIdentity) ?? pluginIdentity) else {
                return TargetRefResolver.staleTargetReferenceResult(
                    params["target_ref"]?.stringValue, operation: operation
                )
            }
        }
        writeParams["insert"] = String(insert)
        writeParams["expected_slot_read_status"] = pluginIdentity.isEmpty ? "empty" : "ok"
        writeParams["expected_plugin_identity"] = pluginIdentity
        return nil
    }
}
