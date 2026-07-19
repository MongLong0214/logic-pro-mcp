import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("HC global invariant")
struct HCGlobalInvariantTests {
    private enum Invariant {
        case minimumV1
        case midiStateB
    }

    private struct RouteCase {
        let tool: String
        let command: String
        let params: [String: Value]
        let operation: String
        let destinations: [ChannelID]
        let invariant: Invariant

        var id: String { "\(tool).\(command)" }
        var label: String { "\(id) -> \(operation)" }
    }

    private struct Fixtures {
        let existingProjectPath: String
        let saveAsProjectPath: String
        let supportBundlePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-support-bundle-\(UUID().uuidString)").path
    }

    private static let hcInvariantAllowlist: Set<String> = [
        "logic_tracks.record_sequence",
        "logic_midi.import_file",
        "logic_project.export_run",
        "logic_project.export_resume",
        "logic_project.launch",
        "logic_project.quit",
        "logic_system.setup_arm_key",
    ]

    // Ratchet: this may only shrink as live-only / legacy non-HC routes become headlessly HC-checkable.
    private static let hcInvariantAllowlistMaxCount = 7

    private static func makeLogicProjectPath(name: String = UUID().uuidString, create: Bool) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("logicx")
        if create {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let resources = path.appendingPathComponent("Resources", isDirectory: true)
            let alternative = path.appendingPathComponent("Alternatives/000", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)
            try Data("plist".utf8).write(to: resources.appendingPathComponent("ProjectInformation.plist"))
            try Data("project".utf8).write(to: alternative.appendingPathComponent("ProjectData"))
        }
        return path.path
    }

    private static func routeCases(fixtures: Fixtures) -> [RouteCase] {
        [
            RouteCase(tool: "logic_transport", command: "play", params: [:], operation: "transport.play", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_transport", command: "stop", params: [:], operation: "transport.stop", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_transport", command: "record", params: [:], operation: "transport.record", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_transport", command: "pause", params: [:], operation: "transport.pause", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_transport", command: "rewind", params: [:], operation: "transport.rewind", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_transport", command: "fast_forward", params: [:], operation: "transport.fast_forward", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_transport", command: "toggle_cycle", params: [:], operation: "transport.toggle_cycle", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_transport", command: "toggle_metronome", params: [:], operation: "transport.toggle_metronome", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_transport", command: "set_tempo", params: ["tempo": .double(120)], operation: "transport.set_tempo", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_transport", command: "goto_position", params: ["bar": .int(1)], operation: "transport.goto_position", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_transport", command: "set_cycle_range", params: ["start": .int(1), "end": .int(2)], operation: "transport.set_cycle_range", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_transport", command: "toggle_count_in", params: [:], operation: "transport.toggle_count_in", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_transport", command: "toggle_autopunch", params: [:], operation: "transport.toggle_autopunch", destinations: [], invariant: .minimumV1),

            RouteCase(tool: "logic_tracks", command: "select", params: ["index": .int(0)], operation: "track.select", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_tracks", command: "create_audio", params: [:], operation: "track.create_audio", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_tracks", command: "create_instrument", params: [:], operation: "track.create_instrument", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_tracks", command: "create_drummer", params: [:], operation: "track.create_drummer", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_tracks", command: "create_external_midi", params: [:], operation: "track.create_external_midi", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_tracks", command: "delete", params: ["index": .int(2), "expected_name": .string("Bass")], operation: "track.delete", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_tracks", command: "duplicate", params: ["index": .int(2), "expected_name": .string("Bass")], operation: "track.duplicate", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_tracks", command: "rename", params: ["index": .int(0), "name": .string("HC Renamed")], operation: "track.rename", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_tracks", command: "mute", params: ["index": .int(0), "enabled": .bool(true)], operation: "track.set_mute", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_tracks", command: "solo", params: ["index": .int(0), "enabled": .bool(true)], operation: "track.set_solo", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_tracks", command: "arm", params: ["index": .int(0), "enabled": .bool(true)], operation: "track.set_arm", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_tracks", command: "arm_only", params: ["index": .int(1)], operation: "track.arm_only", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_tracks", command: "set_automation", params: ["index": .int(0), "mode": .string("read")], operation: "track.set_automation", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_tracks", command: "set_instrument", params: ["index": .int(2), "path": .string("/Library/Application Support/Logic/Patches/Instrument/HC.patch"), "expected_name": .string("Bass")], operation: "track.set_instrument", destinations: [], invariant: .minimumV1),

            RouteCase(tool: "logic_mixer", command: "set_volume", params: ["track": .int(0), "value": .double(0.5)], operation: "mixer.set_volume", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_mixer", command: "set_pan", params: ["track": .int(0), "value": .double(0)], operation: "mixer.set_pan", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_mixer", command: "set_master_volume", params: ["value": .double(0.5)], operation: "mixer.set_master_volume", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_mixer", command: "set_plugin_param", params: ["track": .int(0), "insert": .int(0), "param": .int(0), "value": .double(0.5)], operation: "plugin.set_param", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_mixer", command: "insert_plugin", params: ["track": .int(0), "slot": .int(0), "plugin_name": .string("Gain"), "confirmed": .bool(true)], operation: "plugin.insert", destinations: [], invariant: .minimumV1),

            RouteCase(
                tool: "logic_midi",
                command: "send_note",
                params: ["note": .int(60), "velocity": .int(100), "duration_ms": .int(1)],
                operation: "midi.send_note",
                destinations: [.coreMIDI],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "send_note",
                params: ["note": .int(60), "velocity": .int(100), "duration_ms": .int(1), "port": .string("keycmd")],
                operation: "midi.send_note.keycmd",
                destinations: [.midiKeyCommands],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "send_chord",
                params: ["notes": .array([.int(60), .int(64), .int(67)]), "velocity": .int(100), "duration_ms": .int(1)],
                operation: "midi.send_chord",
                destinations: [.coreMIDI],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "send_chord",
                params: ["notes": .array([.int(60), .int(64), .int(67)]), "velocity": .int(100), "duration_ms": .int(1), "port": .string("keycmd")],
                operation: "midi.send_chord.keycmd",
                destinations: [.midiKeyCommands],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "send_cc",
                params: ["controller": .int(7), "value": .int(100)],
                operation: "midi.send_cc",
                destinations: [.coreMIDI],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "send_cc",
                params: ["controller": .int(7), "value": .int(100), "port": .string("keycmd")],
                operation: "midi.send_cc.keycmd",
                destinations: [.midiKeyCommands],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "send_program_change",
                params: ["program": .int(10)],
                operation: "midi.send_program_change",
                destinations: [.coreMIDI],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "send_program_change",
                params: ["program": .int(10), "port": .string("keycmd")],
                operation: "midi.send_program_change.keycmd",
                destinations: [.midiKeyCommands],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "send_pitch_bend",
                params: ["value": .int(8192)],
                operation: "midi.send_pitch_bend",
                destinations: [.coreMIDI],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "send_pitch_bend",
                params: ["value": .int(8192), "port": .string("keycmd")],
                operation: "midi.send_pitch_bend.keycmd",
                destinations: [.midiKeyCommands],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "send_aftertouch",
                params: ["value": .int(64)],
                operation: "midi.send_aftertouch",
                destinations: [.coreMIDI],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "send_aftertouch",
                params: ["value": .int(64), "port": .string("keycmd")],
                operation: "midi.send_aftertouch.keycmd",
                destinations: [.midiKeyCommands],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "send_sysex",
                params: ["bytes": .array([.int(0xF0), .int(0x7F), .int(0x7F), .int(0x06), .int(0x02), .int(0xF7)])],
                operation: "midi.send_sysex",
                destinations: [.coreMIDI],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "play_sequence",
                params: ["notes": .string("60,0,1,100,1")],
                operation: "midi.play_sequence",
                destinations: [.coreMIDI],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "play_sequence",
                params: ["notes": .string("60,0,1,100,1"), "port": .string("keycmd")],
                operation: "midi.play_sequence.keycmd",
                destinations: [.midiKeyCommands],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "create_virtual_port",
                params: ["name": .string("HC-Global-Port")],
                operation: "midi.create_virtual_port",
                destinations: [.coreMIDI],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "step_input",
                params: ["note": .int(60), "duration": .string("1")],
                operation: "midi.step_input",
                destinations: [.coreMIDI],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "mmc_play",
                params: [:],
                operation: "mmc.play",
                destinations: [.coreMIDI],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "mmc_stop",
                params: [:],
                operation: "mmc.stop",
                destinations: [.coreMIDI],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "mmc_record",
                params: [:],
                operation: "mmc.record_strobe",
                destinations: [.coreMIDI],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "mmc_locate",
                params: ["time": .string("01:02:03:04")],
                operation: "mmc.locate",
                destinations: [.coreMIDI],
                invariant: .midiStateB
            ),
            RouteCase(
                tool: "logic_midi",
                command: "mmc_locate",
                params: ["bar": .int(1)],
                operation: "transport.goto_position",
                destinations: [.accessibility, .mcu, .coreMIDI, .cgEvent],
                invariant: .minimumV1
            ),

            RouteCase(tool: "logic_edit", command: "undo", params: [:], operation: "edit.undo", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_edit", command: "redo", params: [:], operation: "edit.redo", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_edit", command: "cut", params: [:], operation: "edit.cut", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_edit", command: "copy", params: [:], operation: "edit.copy", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_edit", command: "paste", params: [:], operation: "edit.paste", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_edit", command: "delete", params: [:], operation: "edit.delete", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_edit", command: "select_all", params: [:], operation: "edit.select_all", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_edit", command: "split", params: [:], operation: "edit.split", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_edit", command: "join", params: [:], operation: "edit.join", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_edit", command: "quantize", params: ["value": .string("1/16")], operation: "edit.quantize", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_edit", command: "bounce_in_place", params: [:], operation: "edit.bounce_in_place", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_edit", command: "normalize", params: [:], operation: "edit.normalize", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_edit", command: "duplicate", params: [:], operation: "edit.duplicate", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_edit", command: "toggle_step_input", params: [:], operation: "edit.toggle_step_input", destinations: [], invariant: .minimumV1),

            RouteCase(tool: "logic_navigate", command: "goto_bar", params: ["bar": .int(1)], operation: "transport.goto_position", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_navigate", command: "goto_marker", params: ["index": .int(0)], operation: "transport.goto_position", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_navigate", command: "create_marker", params: ["name": .string("HC Marker")], operation: "nav.create_marker", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_navigate", command: "delete_marker", params: ["index": .int(0)], operation: "nav.delete_marker", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_navigate", command: "rename_marker", params: ["index": .int(0), "name": .string("HC Marker Renamed")], operation: "nav.rename_marker", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_navigate", command: "zoom_to_fit", params: [:], operation: "nav.zoom_to_fit", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_navigate", command: "set_zoom", params: ["level": .string("fit")], operation: "nav.zoom_to_fit", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_navigate", command: "toggle_view", params: ["view": .string("mixer")], operation: "view.toggle_mixer", destinations: [], invariant: .minimumV1),

            RouteCase(tool: "logic_project", command: "new", params: [:], operation: "project.new", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_project", command: "open", params: ["path": .string(fixtures.existingProjectPath), "confirmed": .bool(true)], operation: "project.open", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_project", command: "save", params: [:], operation: "project.save", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_project", command: "save_as", params: ["path": .string(fixtures.saveAsProjectPath), "confirmed": .bool(true)], operation: "project.save_as", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_project", command: "close", params: ["confirmed": .bool(true), "saving": .string("no")], operation: "project.close", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_project", command: "bounce", params: ["confirmed": .bool(true)], operation: "project.bounce", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_project", command: "cleanup_apply", params: ["step_id": .string("rename_duplicate_kick_0_1"), "confirmed": .bool(true), "names": .string("Kick L,Kick R")], operation: "project.cleanup_apply", destinations: [], invariant: .minimumV1),

            RouteCase(tool: "logic_system", command: "export_support_bundle", params: ["dir": .string(fixtures.supportBundlePath)], operation: "system.export_support_bundle", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_system", command: "saga_execute", params: [:], operation: "system.saga_execute", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_system", command: "saga_cancel", params: [:], operation: "system.saga_cancel", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_plugins", command: "set_param_verified", params: ["track": .int(0), "insert": .int(0), "plugin": .string("logic.stock.gain"), "param": .string("gain_db"), "value": .double(0), "unit": .string("dB"), "mode": .string("duplicate_applyback"), "project_expected_path": .string(fixtures.existingProjectPath)], operation: "plugin.set_param_verified", destinations: [], invariant: .minimumV1),
            RouteCase(tool: "logic_plugins", command: "insert_verified", params: ["track": .int(2), "insert": .int(0), "plugin": .string("Gain"), "mode": .string("duplicate_applyback"), "project_expected_path": .string(fixtures.existingProjectPath), "expected_name": .string("Bass")], operation: "plugin.insert_verified", destinations: [], invariant: .minimumV1),
        ]
    }

    @Test("registry mutating commands match invariant specs")
    func registryMutatingCommandsMatchSpecs() throws {
        let projectPath = try Self.makeLogicProjectPath(create: true)
        defer { try? FileManager.default.removeItem(atPath: projectPath) }
        let saveAsPath = try Self.makeLogicProjectPath(create: false)
        let fixtures = Fixtures(
            existingProjectPath: projectPath,
            saveAsProjectPath: saveAsPath
        )
        let casesByTool = Dictionary(grouping: Self.routeCases(fixtures: fixtures), by: \.tool)
            .mapValues { Set($0.map(\.command)) }
        let allowlistByTool: [String: Set<String>] = Dictionary(grouping: Self.hcInvariantAllowlist) { entry in
            String(entry.split(separator: ".", maxSplits: 1)[0])
        }.mapValues { entries in
            Set(entries.compactMap { $0.split(separator: ".", maxSplits: 1).last.map(String.init) })
        }
        let registryMutations = Dictionary(grouping: OperationRegistry.specs.filter {
            $0.mutability == Mutability.`mutating`
        }, by: { $0.tool.rawValue }).mapValues { Set($0.map(\.command)) }
        let representedTools = Set(casesByTool.keys).union(allowlistByTool.keys)
        #expect(representedTools == Set(registryMutations.keys))
        for (tool, commandSet) in registryMutations {
            let represented = (casesByTool[tool] ?? []).union(allowlistByTool[tool] ?? [])
            #expect(
                represented == commandSet,
                "\(tool) invariant coverage drifted; missing=\(commandSet.subtracting(represented).sorted()) extra=\(represented.subtracting(commandSet).sorted())"
            )
        }
    }

    @Test("logic_midi dispatcher route mapping matches RoutingTable destinations")
    func logicMIDIDispatcherRouteMappingMatchesRoutingTableDestinations() async throws {
        let projectPath = try Self.makeLogicProjectPath(create: true)
        defer { try? FileManager.default.removeItem(atPath: projectPath) }
        let fixtures = Fixtures(
            existingProjectPath: projectPath,
            saveAsProjectPath: try Self.makeLogicProjectPath(create: false)
        )
        for routeCase in Self.routeCases(fixtures: fixtures) where routeCase.tool == "logic_midi" {
            let destinations = try #require(ChannelRouter.routingTable[routeCase.operation])
            #expect(
                destinations == routeCase.destinations,
                "\(routeCase.command) -> \(routeCase.operation) destinations drifted: \(destinations)"
            )
            let router = ChannelRouter()
            let channels = Dictionary(uniqueKeysWithValues: ChannelID.allCases.map { id in
                (id, MockChannel(id: id))
            })
            for channel in channels.values {
                await router.register(channel)
            }
            let result = await MIDIDispatcher.handle(
                command: routeCase.command,
                params: routeCase.params,
                router: router,
                cache: StateCache()
            )
            let isError = try #require(result.isError as Bool?)
            #expect(!isError, "\(routeCase.command) failed before route assertion: \(sharedToolText(result))")
            let firstDestination = try #require(routeCase.destinations.first)
            let executedOps = await channels[firstDestination]?.executedOps ?? []
            #expect(executedOps.count == 1, "\(routeCase.command) should execute exactly one primary route")
            #expect(executedOps.first?.0 == routeCase.operation)
        }
    }

    @Test("HC invariant allowlist ratchet")
    func hcInvariantAllowlistRatchet() {
        #expect(Self.hcInvariantAllowlist.count <= Self.hcInvariantAllowlistMaxCount)
        #expect(Self.hcInvariantAllowlist == Set([
            "logic_tracks.record_sequence",
            "logic_midi.import_file",
            "logic_project.export_run",
            "logic_project.export_resume",
            "logic_project.launch",
            "logic_project.quit",
            "logic_system.setup_arm_key",
        ]))
    }

    @Test("all mock-executable mutating routes return HC JSON")
    func all_mutating_routes_return_hc_json() async throws {
        // PRD-011: the support-bundle route case uses a temp path; point the
        // bundle root at the temp tree so containment accepts it.
        let rootKey = "LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"
        let previousRoot = getenv(rootKey).map { String(cString: $0) }
        setenv(rootKey, FileManager.default.temporaryDirectory.path, 1)
        defer {
            if let previousRoot { setenv(rootKey, previousRoot, 1) } else { unsetenv(rootKey) }
        }
        let projectPath = try Self.makeLogicProjectPath(create: true)
        defer { try? FileManager.default.removeItem(atPath: projectPath) }
        let fixtures = Fixtures(
            existingProjectPath: projectPath,
            saveAsProjectPath: try Self.makeLogicProjectPath(create: false)
        )
        for routeCase in Self.routeCases(fixtures: fixtures) {
            #expect(!Self.hcInvariantAllowlist.contains(routeCase.id))
            let result = try await Self.execute(routeCase)
            let text = sharedToolText(result)
            let object = try #require(sharedJSONObject(text), "\(routeCase.label) response must be a JSON object: \(text)")
            _ = try #require(object["success"] as? Bool, "\(routeCase.label) response must include boolean success: \(text)")
            let verified = try #require(object["verified"] as? Bool, "\(routeCase.label) response must include boolean verified: \(text)")
            let state = try #require(object["state"] as? String, "\(routeCase.label) response must include string state: \(text)")
            guard routeCase.invariant == .midiStateB else { continue }
            let isError = try #require(result.isError as Bool?)
            let success = try #require(object["success"] as? Bool)
            #expect(!isError, "\(routeCase.label) returned error: \(text)")
            #expect(success, "\(routeCase.label) must be a successful HC envelope")
            #expect(!verified, "\(routeCase.label) send-only route must remain unverified")
            #expect(state == "B", "\(routeCase.label) must carry state B")
        }
    }

    private static func execute(_ routeCase: RouteCase) async throws -> CallTool.Result {
        let router = routeCase.invariant == .midiStateB
            ? try await Self.hcMIDIRouter()
            : await Self.hcEnvelopeRouter()
        let cache = StateCache()
        await seedCache(cache)
        switch routeCase.tool {
        case "logic_transport":
            return await TransportDispatcher.handle(
                command: routeCase.command,
                params: routeCase.params,
                router: router,
                cache: cache,
                sleep: { _ in }
            )
        case "logic_tracks":
            return await TrackDispatcher.handle(command: routeCase.command, params: routeCase.params, router: router, cache: cache, liveTrackNames: hcLiveTrackHeaders)
        case "logic_mixer":
            return await MixerDispatcher.handle(command: routeCase.command, params: routeCase.params, router: router, cache: cache)
        case "logic_midi":
            return await MIDIDispatcher.handle(command: routeCase.command, params: routeCase.params, router: router, cache: cache)
        case "logic_edit":
            return await EditDispatcher.handle(command: routeCase.command, params: routeCase.params, router: router, cache: cache)
        case "logic_navigate":
            return await NavigateDispatcher.handle(command: routeCase.command, params: routeCase.params, router: router, cache: cache)
        case "logic_project":
            return await ProjectDispatcher.handle(
                command: routeCase.command,
                params: routeCase.params,
                router: router,
                cache: cache,
                cleanupAuditFileReader: Self.headlessAuditFileReader
            )
        case "logic_system":
            return await SystemDispatcher.handle(
                command: routeCase.command,
                params: routeCase.params,
                router: router,
                cache: cache,
                supportBundleExporter: { directory, onFirstWrite in
                    await onFirstWrite()
                    return .init(directory: directory, files: [
                        .init(name: "manifest.json", sha256: String(repeating: "a", count: 64)),
                    ])
                }
            )
        case "logic_plugins":
            return await PluginsDispatcher.handle(command: routeCase.command, params: routeCase.params, router: router, cache: cache, liveTrackNames: hcLiveTrackHeaders)
        default:
            Issue.record("Unhandled HC invariant tool \(routeCase.tool)")
            return toolTextResult("Unhandled HC invariant tool \(routeCase.tool)", isError: true)
        }
    }

    /// PRD-007: LIVE header scan mirroring `seedCache`, including its duplicate
    /// "Kick" — the seed-set routes corroborate against this, not the cache.
    private static let hcLiveTrackHeaders: @Sendable () -> [Int: String]? = {
        [0: "Kick", 1: "Kick", 2: "Bass"]
    }

    private static func seedCache(_ cache: StateCache) async {
        await cache.updateDocumentState(true)
        await cache.updateTracks([
            TrackState(id: 0, name: "Kick", type: .audio, isArmed: true),
            TrackState(id: 1, name: "Kick", type: .audio),
            TrackState(id: 2, name: "Bass", type: .audio),
        ])
        await cache.updateMarkers([
            MarkerState(id: 0, name: "Intro", position: "1.1.1.1", positionSource: .parser),
        ])
        await cache.updateRegions([
            RegionState(
                id: "0:1:5:Kick",
                name: "Kick",
                trackIndex: 0,
                startPosition: "1 1 1 1",
                endPosition: "5 1 1 1",
                length: "4 0 0 0"
            ),
        ], complete: true)
    }

    private static func hcEnvelopeRouter() async -> ChannelRouter {
        let router = ChannelRouter()
        let transportJSON = """
        {"isPlaying":false,"isRecording":false,"isPaused":false,"tempo":120.0,"position":"1.1.1.1","timePosition":"00:00:00.000","sampleRate":44100,"isCycleEnabled":false,"isMetronomeEnabled":false,"lastUpdated":"2026-06-19T02:17:42.000Z"}
        """
        let markersJSON = """
        [{"id":0,"name":"Intro","position":"1.1.1.1","positionSource":"parser"}]
        """
        let verifiedResult = ChannelResult.success(HonestContract.encodeStateA())
        let defaultResult = ChannelResult.success(HonestContract.encodeStateB(reason: .readbackUnavailable))
        let results: [String: ChannelResult] = [
            "track.select": verifiedResult,
            "track.rename": verifiedResult,
            "track.set_arm": verifiedResult,
            "transport.get_state": .success(transportJSON),
            "nav.get_markers": .success(markersJSON),
        ]
        for id in ChannelID.allCases {
            await router.register(StaticResultChannel(id: id, results: results, defaultResult: defaultResult))
        }
        return router
    }

    private static func hcRouter() async throws -> ChannelRouter {
        try await hcMIDIRouter()
    }

    private static func hcMIDIRouter() async throws -> ChannelRouter {
        let router = ChannelRouter()
        await router.register(CoreMIDIChannel(
            engine: MockCoreMIDIEngine(),
            portManager: MockVirtualPortManager()
        ))
        let keycmd = MIDIKeyCommandsChannel(transport: MockKeyCmdTransport())
        try await keycmd.start()
        await router.register(keycmd)
        return router
    }

    private static let headlessAuditFileReader = LogicProjectFileReader.Runtime(
        currentDocumentPath: { nil },
        now: Date.init,
        readPlistData: { _ in nil },
        mtime: { _ in nil },
        sleep: { _ in }
    )
}
