import Foundation
import MCP
import Testing
@testable import LogicProMCP

private let midiCommandProject = "prj_00000000-0000-0000-0000-000000000001"
private let midiCommandTrack = "trk_00000000-0000-0000-0000-000000000002"
private let midiCommandSMF = Data([0x4D,0x54,0x68,0x64,0,0,0,6,0,0,0,1,1,0xE0,
    0x4D,0x54,0x72,0x6B,0,0,0,12,0,0x90,60,100,1,0x80,60,0,0,0xFF,0x2F,0])

private actor MIDIExportCallRecorder {
    var calls: [(String, String, String?, Bool)] = []
    func record(_ project: String, _ track: String, _ path: String?, _ allowRename: Bool) {
        calls.append((project, track, path, allowRename))
    }
}

// These commands write the shared trace store. Use the existing serialized
// trace suite rather than racing tests that clear or count that store.
extension OperationTraceTests {
@Suite struct MIDITrackCommandsTests {
@Test(arguments: ["export_track_midi", "read_track_notes"])
func midiTrackCommandsWireExactReferencesAndReturnFileTimelineFacts(command: String) async throws {
    let recorder = MIDIExportCallRecorder()
    var params: [String: Value] = ["project_ref": .string(midiCommandProject), "target_ref": .string(midiCommandTrack)]
    if command == "export_track_midi" { params["path"] = .string("/tmp/target.mid") }
    let result = await MIDIDispatcher.handle(command: command, params: params, router: ChannelRouter(), cache: StateCache(),
        trackFileExport: { project, track, path, allowRename in
            await recorder.record(project, track, path, allowRename)
            return .init(document: try SMFReader.parseDocument(midiCommandSMF))
        })
    let failed = try #require(result.isError)
    #expect(!failed)
    let body = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(body["state"] as? String == "A")
    #expect(body["timing_origin"] as? String == "smf_tick_zero")
    #expect(body["project_timeline_mapping"] as? String == "unproven")
    #expect(body["import_comparison"] as? String == "not_performed")
    #expect(body["ppq"] as? Int == 480)
    let notes = try #require(body["notes"] as? [[String: Any]])
    #expect(notes.count == 1 && notes.first?["pitch"] as? Int == 60)
    #expect(notes.first?["start_tick"] as? Int == 0 && notes.first?["duration_ticks"] as? Int == 1)
    let calls = await recorder.calls
    #expect(calls.count == 1 && calls.first?.0 == midiCommandProject && calls.first?.1 == midiCommandTrack)
    #expect(calls.first?.2 == (command == "export_track_midi" ? "/tmp/target.mid" : nil))
    let allowedRename = try #require(calls.first?.3 as Bool?)
    #expect(!allowedRename)
}

@Test(arguments: ["export_track_midi", "read_track_notes"])
func midiTrackCommandsForwardExplicitTemporaryRenameConsent(command: String) async throws {
    let recorder = MIDIExportCallRecorder()
    var params: [String: Value] = [
        "project_ref": .string(midiCommandProject), "target_ref": .string(midiCommandTrack),
        "allow_temporary_track_rename": .bool(true),
    ]
    if command == "export_track_midi" { params["path"] = .string("/tmp/target.mid") }
    let result = await MIDIDispatcher.handle(
        command: command, params: params, router: ChannelRouter(), cache: StateCache(),
        trackFileExport: { project, track, path, allowRename in
            await recorder.record(project, track, path, allowRename)
            return .init(document: try SMFReader.parseDocument(midiCommandSMF))
        })
    let failed = try #require(result.isError)
    #expect(!failed)
    let allowedRename = try #require(await recorder.calls.first?.3 as Bool?)
    #expect(allowedRename)
}

@Test(arguments: ["missing_project", "wrong_kind", "malformed_track", "read_path", "export_missing_path", "relative_path", "port", "unknown"])
func midiTrackCommandsRejectMalformedRequestsBeforeTheProvider(fault: String) async throws {
    let recorder = MIDIExportCallRecorder()
    var command = "read_track_notes"
    var params: [String: Value] = ["project_ref": .string(midiCommandProject), "target_ref": .string(midiCommandTrack)]
    switch fault {
    case "missing_project": params.removeValue(forKey: "project_ref")
    case "wrong_kind": params["target_ref"] = .string(midiCommandProject)
    case "malformed_track": params["target_ref"] = .string("trk_not-a-reference")
    case "read_path": params["path"] = .string("/tmp/target.mid")
    case "export_missing_path": command = "export_track_midi"
    case "relative_path": command = "export_track_midi"; params["path"] = .string("target.mid")
    case "port": params["port"] = .string("midi")
    default: params["caller_selected_regions"] = .bool(true)
    }
    let result = await MIDIDispatcher.handle(command: command, params: params, router: ChannelRouter(), cache: StateCache(),
        trackFileExport: { project, track, path, allowRename in
            await recorder.record(project, track, path, allowRename)
            return .init(document: try SMFReader.parseDocument(midiCommandSMF))
        })
    let failed = try #require(result.isError)
    #expect(failed)
    #expect(await recorder.calls.isEmpty)
}

@Test func midiTrackCommandsPreserveProviderRefusalWithoutPublishingSuccess() async throws {
    let result = await MIDIDispatcher.handle(command: "read_track_notes",
        params: ["project_ref": .string(midiCommandProject), "target_ref": .string(midiCommandTrack)],
        router: ChannelRouter(), cache: StateCache(), trackFileExport: { _, _, _, _ in
            throw MIDITrackFileExport.Failure.incompleteTrackPopulation
        })
    let failed = try #require(result.isError)
    #expect(failed)
    let body = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(body["error"] as? String == "incomplete_track_population")
    #expect(body["state"] as? String == "C")
    let verified = try #require(body["verified"] as? Bool)
    #expect(!verified)
    #expect(try #require(body["terminal"] as? Bool))
    #expect(!(try #require(body["human_intervention_required"] as? Bool)))
    #expect(!(try #require(body["safe_to_retry"] as? Bool)))
    let hint = try #require(body["hint"] as? String)
    for request in ["inspect", "retry", "manual"] {
        #expect(!hint.localizedCaseInsensitiveContains(request))
    }
}

@Test func midiTrackCommandsReportCollidingIndicesAndTheExplicitRecoveryOption() async throws {
    let result = await MIDIDispatcher.handle(command: "read_track_notes",
        params: ["project_ref": .string(midiCommandProject), "target_ref": .string(midiCommandTrack)],
        router: ChannelRouter(), cache: StateCache(), trackFileExport: { _, _, _, _ in
            throw MIDITrackFileExport.Failure.ambiguousTarget(indices: [4, 5])
        })
    let failed = try #require(result.isError)
    #expect(failed)
    let body = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(body["error"] as? String == "ambiguous_target")
    #expect(body["colliding_track_indices"] as? [Int] == [4, 5])
    let available = try #require(body["temporary_rename_available"] as? Bool)
    #expect(available)
    let effects = try #require(body["ui_effects"] as? [String: Any])
    #expect(effects["temporary_track_name"] as? String == "not_changed")
}

@Test func midiTrackCommandsReportUnconfirmedTemporaryRenameCleanup() async throws {
    let result = await MIDIDispatcher.handle(command: "read_track_notes",
        params: [
            "project_ref": .string(midiCommandProject), "target_ref": .string(midiCommandTrack),
            "allow_temporary_track_rename": .bool(true),
        ], router: ChannelRouter(), cache: StateCache(), trackFileExport: { _, _, _, _ in
            throw MIDITrackFileExport.Failure.temporaryRenameRestorationUnconfirmed(
                originalName: "Repeated", temporaryName: "LPMCP-owned",
                residualName: "User Edit", detail: "owned temporary name changed", primary: nil)
        })
    let failed = try #require(result.isError)
    #expect(failed)
    let body = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(body["error"] as? String == "temporary_rename_restoration_unconfirmed")
    #expect(body["temporary_original_name"] as? String == "Repeated")
    #expect(body["temporary_name"] as? String == "LPMCP-owned")
    #expect(body["observed_residual_name"] as? String == "User Edit")
    #expect(body["cleanup_status"] as? String == "unconfirmed")
    #expect(try #require(body["terminal"] as? Bool))
    #expect(!(try #require(body["human_intervention_required"] as? Bool)))
    #expect(!(try #require(body["safe_to_retry"] as? Bool)))
}

@Test func midiTrackCommandsPreservePrimaryCancellationAfterVerifiedTemporaryRenameCleanup() async throws {
    let result = await MIDIDispatcher.handle(command: "read_track_notes",
        params: [
            "project_ref": .string(midiCommandProject), "target_ref": .string(midiCommandTrack),
            "allow_temporary_track_rename": .bool(true),
        ], router: ChannelRouter(), cache: StateCache(), trackFileExport: { _, _, _, _ in
            throw MIDITrackFileExport.RestoredTemporaryRenameFailure(
                originalName: "Repeated", temporaryName: "LPMCP-owned",
                residualName: "Repeated", primary: CancellationError())
        })
    let failed = try #require(result.isError)
    #expect(failed)
    let body = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(body["error"] as? String == "cancelled")
    #expect(body["observed_residual_name"] as? String == "Repeated")
    #expect(body["cleanup_status"] as? String == "restored")
    let effects = try #require(body["ui_effects"] as? [String: Any])
    #expect(effects["temporary_track_name"] as? String == "restored")
}

@Test func midiTrackCommandsMissingNativeProviderIsATracedRefusal() async throws {
    let context = OperationTraceContext()
    let result = await OperationTraceContext.$current.withValue(context) {
        await MIDIDispatcher.handle(command: "read_track_notes",
            params: ["project_ref": .string(midiCommandProject), "target_ref": .string(midiCommandTrack)],
            router: ChannelRouter(), cache: StateCache())
    }
    let body = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(body["error"] as? String == "native_export_unavailable")
    #expect(body["state"] as? String == "C")
    #expect(context.traceID != nil)
}

@Test func midiTrackCommandsDeclareExclusiveRefRequiredNeverRetryOperations() throws {
    for command in ["export_track_midi", "read_track_notes"] {
        let spec = try #require(OperationRegistry.specs.first { $0.tool == .logicMidi && $0.command == command })
        #expect(spec.mutability == .mutating && spec.retry == .neverAutomatic)
        #expect(spec.target == .acceptsStableTarget && spec.indexBinding == .refRequired)
        #expect(spec.verification == .readbackRequired)
    }
}
}
}
