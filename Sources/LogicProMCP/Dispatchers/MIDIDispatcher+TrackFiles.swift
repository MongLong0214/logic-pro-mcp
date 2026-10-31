import Foundation
import MCP

extension MIDIDispatcher {
    static func handleTrackFileCommand(command: String, params: [String: Value],
        export: (@Sendable (
            String, String, String?, Bool
        ) async throws -> MIDITrackFileExport.Result)?) async -> CallTool.Result {
        let allowed: Set<String> = command == "export_track_midi"
            ? ["project_ref", "target_ref", "path", "allow_temporary_track_rename"]
            : ["project_ref", "target_ref", "allow_temporary_track_rename"]
        guard Set(params.keys).isSubset(of: allowed),
              let project = params["project_ref"]?.stringValue, validMIDIReference(project, prefix: "prj_"),
              let track = params["target_ref"]?.stringValue, validMIDIReference(track, prefix: "trk_") else {
            return toolInvalidParamsResult("\(command) requires explicit project_ref and track target_ref UUID references; selection, indices, port and unknown parameters are not supported")
        }
        let path: String?
        if command == "export_track_midi" {
            guard let value = params["path"]?.stringValue, value.hasPrefix("/"), !value.contains("\0"),
                  URL(fileURLWithPath: value).pathExtension.lowercased() == "mid" else {
                return toolInvalidParamsResult("export_track_midi requires an absolute new .mid path")
            }
            path = value
        } else { path = nil }
        let allowTemporaryRename: Bool
        if let value = params["allow_temporary_track_rename"] {
            guard let parsed = value.boolValue else {
                return toolInvalidParamsResult("allow_temporary_track_rename must be a boolean")
            }
            allowTemporaryRename = parsed
        } else { allowTemporaryRename = false }
        let traceID = await startTraceIfEnabled(command: command)
        guard let export else {
            return await finalizeTrace(midiFilePayload(["error": "native_export_unavailable", "success": false,
                "verified": false, "state": "C", "operation": "midi.\(command)",
                "hint": "This command requires the registered request-owned native export provider."], isError: true), traceID: traceID)
        }
        let result: CallTool.Result
        do {
            let exported = try await export(project, track, path, allowTemporaryRename)
            let document = exported.document
            var payload: [String: Any] = [
                "success": true, "state": "A", "operation": "midi.\(command)",
                "verified": true, "project_ref": project, "target_ref": track,
                "provider": "native_whole_project_smf_export",
                "verification_scope": "export_artifact_and_track_binding",
                "timing_origin": "smf_tick_zero", "project_timeline_mapping": "unproven",
                "import_comparison": "not_performed", "ppq": document.ticksPerQuarter,
                "smf_format": document.format, "smf_track_count": document.trackCount,
                "empty": document.notes.isEmpty,
                "notes": document.notes.map { ["pitch": Int($0.pitch), "velocity": Int($0.velocity),
                    "channel": $0.channel, "start_tick": $0.startTick,
                    "end_tick": $0.endTick, "duration_ticks": $0.durationTicks] },
                "tempo_changes": document.tempoChanges.map { ["tick": $0.tick, "microseconds_per_quarter": $0.microsecondsPerQuarter] },
                "time_signatures": document.timeSignatures.map { ["tick": $0.tick, "numerator": $0.signature.numerator, "denominator": $0.signature.denominator] },
                "ui_effects": ["export_panel": "closed", "selection_cycle": "not_changed_by_provider", "last_export_folder": "not_restored"],
            ]
            if let rename = exported.temporaryRename {
                payload["temporary_track_rename"] = [
                    "original_name": rename.originalName,
                    "temporary_name": rename.temporaryName,
                    "restoration": rename.restoration,
                ]
                payload["ui_effects"] = [
                    "export_panel": "closed", "selection_cycle": "not_changed_by_provider",
                    "last_export_folder": "not_restored", "temporary_track_name": rename.restoration,
                ]
            }
            if let path { payload["path"] = path }
            result = midiFilePayload(payload)
        } catch {
            let classifiedError: any Error
            let code: String
            var fields: [String: Any] = [:]
            var uiEffects: [String: Any] = ["restoration": "unconfirmed"]
            if let restored = error as? MIDITrackFileExport.RestoredTemporaryRenameFailure {
                classifiedError = restored.primary
                fields["temporary_original_name"] = restored.originalName
                fields["temporary_name"] = restored.temporaryName
                fields["observed_residual_name"] = restored.residualName
                fields["cleanup_status"] = "restored"
                uiEffects = ["temporary_track_name": "restored"]
            } else {
                classifiedError = error
            }
            switch classifiedError {
            case MIDITrackFileExport.Failure.invalidDestination: code = "invalid_destination"
            case MIDITrackFileExport.Failure.destinationExists: code = "destination_exists"
            case MIDITrackFileExport.Failure.unboundProject: code = "unbound_project"
            case MIDITrackFileExport.Failure.incompleteTrackPopulation: code = "incomplete_track_population"
            case MIDITrackFileExport.Failure.ambiguousTarget(let indices):
                code = "ambiguous_target"
                fields["colliding_track_indices"] = indices
                fields["temporary_rename_available"] = true
                uiEffects = ["temporary_track_name": "not_changed"]
            case MIDITrackFileExport.Failure.temporaryRenameUnavailable(let indices):
                code = "temporary_rename_unavailable"
                fields["colliding_track_indices"] = indices
                uiEffects = ["temporary_track_name": "not_changed"]
            case MIDITrackFileExport.Failure.temporaryRenamePreparationUnconfirmed(
                let original, let temporary, let residual, let cleanupStatus, let detail):
                code = "temporary_rename_preparation_unconfirmed"
                fields["temporary_original_name"] = original
                fields["temporary_name"] = temporary
                if let residual { fields["observed_residual_name"] = residual }
                fields["cleanup_status"] = cleanupStatus.rawValue
                fields["cleanup_detail"] = detail
                uiEffects = ["temporary_track_name": cleanupStatus.rawValue]
            case MIDITrackFileExport.Failure.temporaryRenameRestorationUnconfirmed(
                let original, let temporary, let residual, let detail, let primary):
                code = "temporary_rename_restoration_unconfirmed"
                fields["temporary_original_name"] = original
                fields["temporary_name"] = temporary
                if let residual { fields["observed_residual_name"] = residual }
                fields["cleanup_status"] = "unconfirmed"
                fields["cleanup_detail"] = detail
                if let primary { fields["primary_failure"] = primary }
                uiEffects = ["temporary_track_name": "unconfirmed"]
            case MIDITrackFileExport.Failure.staleTarget: code = "stale_target"
            case MIDITrackFileExport.Failure.exportCancelled, is CancellationError: code = "cancelled"
            case MIDITrackFileExport.Failure.unreadableArtifact, is SMFReaderError: code = "unreadable_midi_artifact"
            case SMFReader.TrackExtractionError.instrumentNotFound: code = "track_midi_not_exported"
            case SMFReader.TrackExtractionError.unsupportedFileLayout: code = "unsupported_midi_export_layout"
            case is MIDITrackExportPanel.Failure: code = "native_export_unverified"
            default: code = "midi_export_failed"
            }
            let terminalHint: String
            if path != nil {
                terminalHint = "No completed export is reported. The explicit destination and any "
                    + "unconfirmed native UI cleanup are preserved in this terminal result; no automatic continuation is authorized."
            } else {
                terminalHint = "No completed note observation is reported. Any unconfirmed native UI "
                    + "cleanup remains evidence in this terminal result; no automatic continuation is authorized."
            }
            var payload: [String: Any] = ["error": code, "verified": false, "success": false,
                "state": "C", "operation": "midi.\(command)",
                "terminal": true, "terminal_scope": "mcp_request_only",
                "human_intervention_required": false, "human_intervention_requests": 0,
                "human_dependent_transitions": 0, "safe_to_retry": false,
                "hint": terminalHint,
                "detail": String(describing: classifiedError), "ui_effects": uiEffects]
            if let path { payload["path"] = path }
            payload.merge(fields) { current, _ in current }
            result = midiFilePayload(payload, isError: true)
        }
        return await finalizeTrace(result, traceID: traceID)
    }

    private static func validMIDIReference(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix), value.count == prefix.count + 36 else { return false }
        return UUID(uuidString: String(value.dropFirst(prefix.count))) != nil
    }

    private static func midiFilePayload(_ payload: [String: Any], isError: Bool = false) -> CallTool.Result {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return .init(content: [.text("{\"error\":\"midi_result_encoding_failed\"}")], isError: true)
        }
        return .init(content: [.text(String(decoding: data, as: UTF8.self))], isError: isError)
    }
}
