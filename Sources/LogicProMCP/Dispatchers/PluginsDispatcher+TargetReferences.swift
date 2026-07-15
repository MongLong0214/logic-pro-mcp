import Foundation
import MCP

extension PluginsDispatcher {
    static func addInventoryTargetReferences(
        to result: CallTool.Result,
        cache: StateCache,
        targetRegistry: TargetRegistry?
    ) async -> CallTool.Result {
        guard FeatureFlags.adr002TargetRef,
              let targetRegistry,
              case .text(let rawJSON, let annotations, let meta) = result.content.first,
              var object = decodedJSONObject(rawJSON),
              object["state"] as? String == "A",
              let track = object["track"] as? Int,
              track >= 0,
              var plugins = object["plugins"] as? [[String: Any]] else {
            return result
        }

        let tracks = await cache.getTracks()
        let trackName = tracks.first(where: { $0.id == track })?.name
            ?? "Track \(track + 1)"
        let descriptor = TargetDescriptor(trackIndex: track, trackName: trackName)
        var changed = false
        for index in plugins.indices {
            guard let insert = plugins[index]["insert"] as? Int, insert >= 0 else {
                continue
            }
            let pluginIdentity = (plugins[index]["plugin_id"] as? String)
                ?? (plugins[index]["name"] as? String)
            let fingerprint = TargetRefResolver.pluginInsertFingerprint(
                descriptor: descriptor,
                insert: insert,
                pluginIdentity: pluginIdentity
            )
            let reference = await targetRegistry.bind(
                kind: .pluginInsert,
                descriptor: descriptor,
                fingerprint: fingerprint,
                pluginInsertIndex: insert
            )
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
        guard let insert = binding.pluginInsertIndex else {
            return TargetRefResolver.staleTargetReferenceResult(
                params["target_ref"]?.stringValue,
                operation: operation
            )
        }
        if params["insert"] != nil || params["slot"] != nil {
            guard let requestedInsert = intParamOrNil(params, keys: ["insert", "slot"]),
                  requestedInsert >= 0,
                  requestedInsert == insert else {
                return TargetRefResolver.staleTargetReferenceResult(
                    params["target_ref"]?.stringValue,
                    operation: operation
                )
            }
        }
        writeParams["insert"] = String(insert)
        return nil
    }
}
