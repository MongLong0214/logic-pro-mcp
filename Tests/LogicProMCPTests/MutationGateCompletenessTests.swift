import Foundation
import Testing
@testable import LogicProMCP

// WS8b (AC5) — mutation-gate completeness. Every command each dispatcher's
// `switch command { case "…" }` (plus EditDispatcher's route table) accepts must
// be CONSCIOUSLY classified as exactly one of:
//   • mutating  → present in LogicProServer.mutatingCommandsByTool (serialized by
//                 LogicMutationGate), checked via `isMutatingCommand`;
//   • read-only → on the explicit allowlist below (a query: cache/disk/AX read);
//   • not-exposed stub → an error-only "not in the production MCP contract" label;
//   • alias → a second `case "canonical", "alias":` label routing to a censused one.
// A newly-added command that lands in none of these fails the suite — forcing the
// author to gate it or allowlist it rather than shipping an un-serialized mutation.
// Read-only test: it parses the dispatcher sources and consults production maps;
// it never edits Sources. The allowlist is kept in lockstep by this test the same
// way SystemDispatcher.validHelpCategories is (audit AC5).
@Suite("Mutation-gate completeness")
struct MutationGateCompletenessTests {
    private static let dispatcherFiles: [String: String] = [
        "logic_transport": "TransportDispatcher.swift",
        "logic_tracks": "TrackDispatcher.swift",
        "logic_mixer": "MixerDispatcher.swift",
        "logic_midi": "MIDIDispatcher.swift",
        "logic_edit": "EditDispatcher.swift",
        "logic_navigate": "NavigateDispatcher.swift",
        "logic_project": "ProjectDispatcher.swift",
        "logic_system": "SystemDispatcher.swift",
        "logic_audio": "AudioDispatcher.swift",
        "logic_plugins": "PluginsDispatcher.swift",
    ]

    /// Non-mutating query commands. Each transiently reads (cache/disk/AX) but
    /// changes no project state, so it stays OUT of the mutation gate on purpose.
    private static let readOnlyAllowlist: [String: Set<String>] = [
        "logic_tracks": ["list_library", "resolve_path", "scan_library", "scan_plugin_presets"],
        "logic_midi": ["list_ports"],
        "logic_project": ["audit", "cleanup_plan", "export_plan", "get_regions", "is_running"],
        "logic_system": ["health", "help", "permissions", "refresh_cache"],
        "logic_audio": ["analyze_file"],
        "logic_plugins": ["get_inventory"],
    ]

    /// Error-only labels that exist as switch cases but return a "not exposed in
    /// the production MCP contract" State C — neither mutating nor a real query.
    private static let notExposedStubs: [String: Set<String>] = [
        "logic_tracks": ["set_color"],
        "logic_mixer": ["set_send", "set_output", "set_input", "toggle_eq", "reset_strip", "bypass_plugin"],
    ]

    /// Convenience aliases that share a `case "canonical", "alias":` label.
    private static let aliases: [String: Set<String>] = [
        "logic_tracks": ["library"],  // alias of list_library
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func executableLabels(_ tool: String) throws -> Set<String> {
        let file = try #require(dispatcherFiles[tool], "no dispatcher source mapped for \(tool)")
        let url = repoRoot.appendingPathComponent("Sources/LogicProMCP/Dispatchers").appendingPathComponent(file)
        let source = try String(contentsOf: url, encoding: .utf8)
        return switchLabels(source).union(routeTableLabels(source))
    }

    /// Labels of the top-level `switch command { … }`, isolated by indentation
    /// (nested switches sit deeper and are excluded).
    private static func switchLabels(_ source: String) -> Set<String> {
        let lines = source.components(separatedBy: "\n")
        func indent(_ l: String) -> Int { l.prefix { $0 == " " }.count }
        guard let si = lines.firstIndex(where: { $0.contains("switch command {") }) else { return [] }
        let swi = indent(lines[si])
        var labels: Set<String> = []
        var i = si + 1
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "}" && indent(line) == swi { break }
            if indent(line) == swi && trimmed.hasPrefix("case ") {
                var rest = Substring(trimmed)
                while let open = rest.firstIndex(of: "\"") {
                    let after = rest.index(after: open)
                    guard let close = rest[after...].firstIndex(of: "\"") else { break }
                    labels.insert(String(rest[after..<close]))
                    rest = rest[rest.index(after: close)...]
                }
            }
            i += 1
        }
        return labels
    }

    private static func routeTableLabels(_ source: String) -> Set<String> {
        let lines = source.components(separatedBy: "\n")
        func indent(_ l: String) -> Int { l.prefix { $0 == " " }.count }
        guard let ti = lines.firstIndex(where: { $0.contains("routedCommands") && $0.contains("[") }) else { return [] }
        let tab = indent(lines[ti])
        var labels: Set<String> = []
        var i = ti + 1
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "]" && indent(lines[i]) == tab { break }
            if trimmed.hasPrefix("\""), let colon = trimmed.firstIndex(of: ":") {
                let prefix = trimmed[..<colon]
                if let close = prefix.dropFirst().firstIndex(of: "\"") {
                    labels.insert(String(prefix[prefix.index(after: prefix.startIndex)..<close]))
                }
            }
            i += 1
        }
        return labels
    }

    @Test("every accepted dispatcher command is gated, read-only-allowlisted, a stub, or an alias")
    func everyCommandClassified() throws {
        for tool in Self.dispatcherFiles.keys.sorted() {
            let labels = try Self.executableLabels(tool)
            #expect(!labels.isEmpty, "\(tool): no switch labels parsed — parser drift?")
            for command in labels.sorted() {
                let gated = LogicProServer.isMutatingCommand(tool: tool, command: command)
                let readOnly = Self.readOnlyAllowlist[tool]?.contains(command) ?? false
                let stub = Self.notExposedStubs[tool]?.contains(command) ?? false
                let alias = Self.aliases[tool]?.contains(command) ?? false
                #expect(
                    gated || readOnly || stub || alias,
                    "\(tool).\(command) is UNCLASSIFIED — gate it in LogicProServer.mutatingCommandsByTool if it mutates, else add it to the read-only allowlist / stub list."
                )
                // A command may not be BOTH gated and read-only — that would be a
                // contradiction in intent.
                #expect(!(gated && readOnly), "\(tool).\(command) is both mutation-gated and read-only-allowlisted")
            }
        }
    }

    @Test("read-only allowlist and stub lists contain no phantom (non-existent) commands")
    func allowlistsAreGrounded() throws {
        for (tool, allow) in Self.readOnlyAllowlist {
            let labels = try Self.executableLabels(tool)
            for command in allow.sorted() {
                #expect(labels.contains(command), "read-only allowlist entry \(tool).\(command) is not a real dispatcher label")
                #expect(!LogicProServer.isMutatingCommand(tool: tool, command: command), "\(tool).\(command) is allowlisted read-only but IS gated")
            }
        }
        for (tool, stubs) in Self.notExposedStubs {
            let labels = try Self.executableLabels(tool)
            for command in stubs.sorted() {
                #expect(labels.contains(command), "not-exposed stub \(tool).\(command) is not a real dispatcher label")
            }
        }
    }

    @Test("every dispatcher tool is mapped for the completeness audit")
    func everyToolMapped() {
        // Lockstep with the mutation-gate map keys: the same 10 tools LogicProServer
        // enumerates must be audited here (a new tool must be added to both).
        let mapped = Set(Self.dispatcherFiles.keys)
        for tool in ["logic_transport", "logic_tracks", "logic_mixer", "logic_midi", "logic_edit",
                     "logic_navigate", "logic_project", "logic_system", "logic_audio", "logic_plugins"] {
            #expect(mapped.contains(tool), "dispatcher \(tool) is not mapped for the mutation-gate completeness audit")
        }
    }
}
