import Foundation
import MCP

/// #957 (ADR-003 remainder): a per-command input schema derived from the operation registry, so a
/// client can see each command's parameters without a handwritten copy of them.
///
/// The default tool schema stays the `{command, params}` shape every client already consumes. A
/// server started with `LOGIC_MCP_TOOL_SCHEMA=rich` lists the richer form instead: `command` gains
/// an `enum`, and the schema gains a top-level `oneOf` with one branch per command. Each branch
/// binds `command` to its value with `const` and describes that command's `params`, so exactly one
/// branch applies to a request. Some clients refuse a top-level combinator; the mode is opt-in, and
/// docs/API.md names the client it was shown to work with.
///
/// A branch closes its parameters (`additionalProperties: false`) only where the runtime refuses
/// an unknown one: strict validation on, and the operation not opted out. Elsewhere the branch lists
/// the parameters and leaves them open, so the schema never states an enforcement the server lacks.
enum CommandSchemaProjection {
    enum Mode: Equatable, Sendable {
        case legacy
        case rich
    }

    static let environmentKey = "LOGIC_MCP_TOOL_SCHEMA"

    /// Unset, or anything but `rich`, lists the legacy shape: an unrecognised value cannot switch a
    /// client onto a schema it was not tested with.
    static func mode(from environment: [String: String]) -> Mode {
        environment[environmentKey] == "rich" ? .rich : .legacy
    }

    static let launchMode: Mode = mode(from: ProcessInfo.processInfo.environment)

    /// The tools `tools/list` answers with under `mode`.
    static func listedTools(
        _ tools: [Tool], mode: Mode, strictParams: Bool,
        entries: [OperationCatalogEntry] = OperationCatalog.snapshot().operations
    ) -> [Tool] {
        guard mode == .rich else { return tools }
        return tools.map { tool in
            let toolEntries = entries.filter { $0.tool == tool.name }
            guard !toolEntries.isEmpty else { return tool }
            return Tool(
                name: tool.name,
                title: tool.title,
                description: tool.description,
                inputSchema: inputSchema(legacy: tool.inputSchema, entries: toolEntries, strictParams: strictParams),
                annotations: tool.annotations,
                outputSchema: tool.outputSchema,
                icons: tool.icons,
                _meta: tool._meta
            )
        }
    }

    /// Whether the runtime refuses a parameter `entry` does not list. Mirrors
    /// `LogicProServer.strictValidationSpec`.
    static func closesParameters(_ entry: OperationCatalogEntry, strictParams: Bool) -> Bool {
        guard strictParams, let id = OperationID(rawValue: entry.id) else { return false }
        return !OperationRegistry.strictParamValidationOptOuts.contains(id)
    }

    static func inputSchema(legacy: Value, entries: [OperationCatalogEntry], strictParams: Bool) -> Value {
        let sorted = entries.sorted { $0.command < $1.command }
        let legacyProperties = legacy.objectValue?["properties"]?.objectValue ?? [:]
        var command = legacyProperties["command"]?.objectValue ?? ["type": .string("string")]
        command["enum"] = .array(sorted.map { .string($0.command) })
        var schema = legacy.objectValue ?? [:]
        var properties = legacyProperties
        properties["command"] = .object(command)
        schema["type"] = .string("object")
        schema["properties"] = .object(properties)
        schema["required"] = .array([.string("command")])
        schema["oneOf"] = .array(sorted.map { branch(for: $0, strictParams: strictParams) })
        return .object(schema)
    }

    /// The registry's parameter contract for `entry` (#957), or nil for a command with none.
    static func contract(for entry: OperationCatalogEntry) -> OperationParameterContract? {
        OperationID(rawValue: entry.id).flatMap { OperationRegistry.parameterContracts[$0] }
    }

    /// One command's branch: `command` fixed to the command, and `params` naming its parameters.
    /// A parameter whose contract rule is enforced carries its kind's schema; an unconstrained one
    /// carries none. The required groups become `allOf` over `required` (one key) or `anyOf` of
    /// `required` (aliases or alternatives), and `params` itself is then required.
    static func branch(for entry: OperationCatalogEntry, strictParams: Bool) -> Value {
        let rules = contract(for: entry)?.params ?? [:]
        var params: [String: Value] = [
            "type": .string("object"),
            "properties": .object(Dictionary(uniqueKeysWithValues: entry.allowedParams.map {
                ($0, rules[$0]?.schema ?? Value.object([:]))
            })),
        ]
        if closesParameters(entry, strictParams: strictParams) {
            params["additionalProperties"] = .bool(false)
        }
        let groups = contract(for: entry)?.required ?? []
        if !groups.isEmpty {
            params["allOf"] = .array(groups.map { group in
                let alternatives: [Value] = group.map { alternative in
                    .object(["required": .array(OperationParameterContract.keys(of: alternative).map { .string($0) })])
                }
                return alternatives.count == 1 ? alternatives[0] : .object(["anyOf": .array(alternatives)])
            })
        }
        return .object([
            "title": .string(entry.command),
            "description": .string(policySummary(entry)),
            "properties": .object([
                "command": .object(["const": .string(entry.command)]),
                "params": .object(params),
            ]),
            "required": .array(groups.isEmpty ? [.string("command")] : [.string("command"), .string("params")]),
        ])
    }

    /// The registry's policy words for `entry`, as the operation catalog writes them.
    static func policySummary(_ entry: OperationCatalogEntry) -> String {
        var parts = [
            entry.id, entry.mutability, "confirmation \(entry.confirmation)", "target \(entry.target)",
            "verification \(entry.verification)", "retry \(entry.retry)", "availability \(entry.availability)",
        ]
        if let binding = entry.indexBinding { parts.append("index binding \(binding)") }
        return parts.joined(separator: "; ")
    }

    // MARK: - Generated parameter table (#957 requirement 3)

    static let generatedTablePath = "docs/COMMAND-PARAMETERS.md"

    /// The parameter table `docs/COMMAND-PARAMETERS.md` holds, rendered from the same entries the
    /// rich schema reads. It is a view of the registry, not another source: a test compares the
    /// committed file with this rendering.
    /// The catalog the committed table is rendered from: the live catalog with every
    /// process-dependent policy set to its default. Only the trace commands' availability depends on
    /// the process today (`LOGIC_MCP_ADR005_OPERATION_TRACE`, read when the registry is built), and
    /// the table states it as tracing's default, on (#1093 review R2, R3). The rich schema a running
    /// server lists keeps the process's own value.
    static func documentationEntries(
        _ entries: [OperationCatalogEntry] = OperationCatalog.snapshot().operations
    ) -> [OperationCatalogEntry] {
        let traced = OperationCatalog.wire(OperationRegistry.traceAvailability(traceEnabled: true))
        return entries.map { entry in
            guard let id = OperationID(rawValue: entry.id), OperationRegistry.traceOperationIDs.contains(id) else {
                return entry
            }
            return OperationCatalogEntry(
                id: entry.id, tool: entry.tool, command: entry.command, mutability: entry.mutability,
                target: entry.target, confirmation: entry.confirmation, verification: entry.verification,
                retry: entry.retry, deadline: entry.deadline, availability: traced,
                allowedParams: entry.allowedParams, capability: entry.capability,
                dirtySections: entry.dirtySections, indexBinding: entry.indexBinding)
        }
    }

    /// One parameter in the table: its name, its kind when the rule is enforced, and its allowed
    /// values when the dispatcher keeps a list.
    static func parameterCell(_ key: String, _ rule: ParamRule?) -> String {
        var cell = "`\(key)`"
        if let kind = rule?.kind {
            cell += ": " + kind.rawValue
        }
        if let allowed = rule?.allowed {
            cell += " (" + allowed.joined(separator: ", ") + ")"
        }
        return cell
    }

    static func parameterTable(
        entries: [OperationCatalogEntry] = documentationEntries(), strictParams: Bool = true
    ) -> String {
        var lines = [
            "# Command parameters",
            "",
            "<!-- Generated from the operation registry by CommandSchemaProjection.parameterTable. "
                + "Do not edit; run `LPM_WRITE_GENERATED_DOCS=1 swift test --filter Issue957` to regenerate. -->",
            "",
            "Each command's accepted parameters and the registry's policy words for it. "
                + "\"Closed\" means a key the row does not list is refused: by the server's generic strict-parameter "
                + "gate, or, for the keys a dispatcher answers with its own error (such as `port` on `logic_midi` "
                + "`list_ports`), which that gate forwards, by the dispatcher; "
                + "\"open\" means that gate does not run for the row, and the command's dispatcher still validates "
                + "its parameters. The table assumes strict parameter checking, the default; "
                + "`LOGIC_MCP_ADR003_STRICT_PARAMS=0` turns the gate off and opens every row. "
                + "A parameter followed by a kind (`bar: integer`) is one whose value of another type the dispatcher "
                + "refuses before any channel runs; a parameter with no kind is one the dispatcher coerces, defaults or "
                + "ignores, and the registry gives the reason. \"Required\" lists the groups of which one key must be "
                + "present. Both come from `OperationRegistry.parameterContracts`, which a census drives against every "
                + "dispatcher. A list in parentheses is the only values the dispatcher takes, read from the dispatcher's own "
                + "constant. "
                + "This is a projection of `OperationRegistry`, not a second source, and not qualification evidence.",
            "",
        ]
        let byTool = Dictionary(grouping: entries, by: \.tool)
        for tool in byTool.keys.sorted() {
            lines.append("## `\(tool)`")
            lines.append("")
            lines.append("| Command | Parameters | Required | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |")
            lines.append("|---|---|---|---|---|---|---|---|---|---|")
            for entry in (byTool[tool] ?? []).sorted(by: { $0.command < $1.command }) {
                let rules = contract(for: entry)?.params ?? [:]
                let params = entry.allowedParams.isEmpty ? "none" : entry.allowedParams.map { key in
                    parameterCell(key, rules[key])
                }.joined(separator: ", ")
                let groups = contract(for: entry)?.required ?? []
                let required = groups.isEmpty ? "none" : groups.map { group in
                    group.map { OperationParameterContract.keys(of: $0).map { "`\($0)`" }.joined(separator: " and ") }
                        .joined(separator: " or ")
                }.joined(separator: "; ")
                let unknown = closesParameters(entry, strictParams: strictParams) ? "closed" : "open"
                lines.append("| `\(entry.command)` | \(params) | \(required) | \(unknown) | \(entry.mutability) | \(entry.confirmation) | "
                    + "\(entry.target) | \(entry.verification) | \(entry.retry) | \(entry.availability) |")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
