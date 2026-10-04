import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #957: every claim in `OperationRegistry.parameterContracts` is driven against the dispatcher it
/// describes. Every channel is a `MockChannel`. "Refused" means the reply is an error and no channel
/// ran. "Accepted" means a channel ran, or the reply is not an invalid_params refusal.
///
/// The claims:
/// - every command with parameters has a contract, and it names exactly the command's allowed
///   parameters;
/// - an enforced parameter given a value outside its kind is refused, alone with the required groups
///   and again beside every other enforced parameter's sample;
/// - a request missing one required group is refused;
/// - a request with every required group filled from samples is accepted.
@Suite("#957 parameter contracts against the dispatchers")
struct Issue957ParameterContractCensusTests {
    /// A temporary Logic project package, as `isValidExistingProjectPackage` reads one.
    private static func temporaryProject() -> String {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("lpm-957-\(UUID().uuidString).logicx")
        let resources = project.appendingPathComponent("Resources", isDirectory: true)
        let alternative = project.appendingPathComponent("Alternatives/000", isDirectory: true)
        try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)
        try? Data("plist".utf8).write(to: resources.appendingPathComponent("ProjectInformation.plist"))
        try? Data("project".utf8).write(to: alternative.appendingPathComponent("ProjectData"))
        return project.path
    }

    /// Samples that must exist on disk, made when a request carries the contract's placeholder:
    /// open and the export commands take an existing project, import_file a server-managed .mid.
    private static func materialize(_ spec: OperationSpec, _ params: [String: Value]) -> [String: Value] {
        var params = params
        let placeholder = OperationRegistry.parameterContracts[spec.id]?.params["path"]?.sample
        switch spec.id.rawValue {
        case "project.open":
            if params["path"] == placeholder { params["path"] = .string(temporaryProject()) }
        case "project.export_plan", "project.export_run", "project.export_resume":
            if params["path"] == nil { params["path"] = .string(temporaryProject()) }
            if params["output_root"] == nil {
                params["output_root"] = .string(FileManager.default.temporaryDirectory
                    .appendingPathComponent("lpm-957-out-\(UUID().uuidString)").path)
            }
        case "midi.import_file":
            if params["path"] == placeholder, let file = try? SMFWriter.temporaryMIDIFile() {
                try? Data([0x4D, 0x54, 0x68, 0x64]).write(to: file.fileURL)
                params["path"] = .string(file.fileURL.path)
            }
        default:
            break
        }
        return params
    }

    private static func dispatch(_ spec: OperationSpec, _ given: [String: Value]) async -> (result: CallTool.Result, channelRan: Bool) {
        let params = materialize(spec, given)
        let router = ChannelRouter()
        var channels: [MockChannel] = []
        for id in ChannelID.allCases {
            let channel = MockChannel(id: id)
            await router.register(channel)
            channels.append(channel)
        }
        // Two tracks, so an index-bound write can be corroborated by the name expected there.
        let cache = StateCache()
        await cache.updateTracks([TrackState(id: 0, name: "Track 1", type: .audio),
                                  TrackState(id: 1, name: "Track 2", type: .audio)])
        let names: @Sendable () -> [Int: String]? = { [0: "Track 1", 1: "Track 2"] }
        let command = spec.command
        let result: CallTool.Result
        switch spec.tool {
        case .logicTransport:
            result = await TransportDispatcher.handle(command: command, params: params, router: router, cache: cache, sleep: { _ in })
        case .logicMixer:
            result = await MixerDispatcher.handle(command: command, params: params, router: router, cache: cache)
        case .logicNavigate:
            result = await NavigateDispatcher.handle(command: command, params: params, router: router, cache: cache)
        case .logicAudio:
            result = await AudioDispatcher.handle(command: command, params: params)
        case .logicSystem:
            result = await SystemDispatcher.handle(command: command, params: params, router: router, cache: cache)
        case .logicPlugins:
            result = await PluginsDispatcher.handle(command: command, params: params, router: router, cache: cache)
        case .logicEdit:
            result = await EditDispatcher.handle(command: command, params: params, router: router, cache: cache)
        case .logicProject:
            result = await ProjectDispatcher.handle(command: command, params: params, router: router, cache: cache)
        case .logicMidi:
            result = await MIDIDispatcher.handle(command: command, params: params, router: router, cache: cache)
        case .logicTracks:
            result = await TrackDispatcher.handle(command: command, params: params, router: router, cache: cache,
                                                  liveTrackNames: names)
        }
        var ran = false
        for channel in channels where !(await channel.executedOps.isEmpty) {
            ran = true
        }
        return (result, ran)
    }

    private static func refused(_ outcome: (result: CallTool.Result, channelRan: Bool)) -> Bool {
        (outcome.result.isError ?? false) && !outcome.channelRan
    }

    /// Whether `outside` was refused because of what differs from `control`: the control reached a
    /// channel and the request did not, or the control answered without an error and the request
    /// with one, or only the request's error is invalid_params. A request refused for a reason the
    /// control shares (a marker that is not there) is not attributed to the parameter.
    private static func attributable(control: (result: CallTool.Result, channelRan: Bool),
                                     outside: (result: CallTool.Result, channelRan: Bool)) -> Bool {
        guard refused(outside) else { return false }
        if control.channelRan { return true }
        if !(control.result.isError ?? false) { return true }
        return !sharedToolText(control.result).contains("invalid_params")
            && sharedToolText(outside.result).contains("invalid_params")
    }

    /// Past parameter validation: a channel ran, or the reply is not an invalid_params refusal. A
    /// command that answers in the server (a trace that is not there, an audio path that does not
    /// open) is past validation when it says so.
    private static func accepted(_ outcome: (result: CallTool.Result, channelRan: Bool)) -> Bool {
        outcome.channelRan || !sharedToolText(outcome.result).contains("invalid_params")
    }

    private static func describe(_ outcome: (result: CallTool.Result, channelRan: Bool)) -> String {
        "isError=\(outcome.result.isError ?? false) channelRan=\(outcome.channelRan) "
            + String(sharedToolText(outcome.result).prefix(160))
    }

    /// One key with a sample from each required group, preferring `prefer` when a group holds it.
    private static func filling(_ contract: OperationParameterContract, prefer: String? = nil,
                                skipping skipped: Int? = nil) -> [String: Value]? {
        var params: [String: Value] = [:]
        for (offset, group) in contract.required.enumerated() where offset != skipped {
            if let prefer, group.contains(prefer) { continue }
            guard let key = group.first(where: { contract.params[$0]?.sample != nil }),
                  let sample = contract.params[key]?.sample else { return nil }
            params[key] = sample
        }
        return params
    }

    @Test("every command with parameters has a contract naming exactly its parameters")
    func contractsCoverTheRegistry() {
        var problems: [String] = []
        for spec in OperationRegistry.specs where !spec.allowedParams.isEmpty {
            guard let contract = OperationRegistry.parameterContracts[spec.id] else {
                problems.append("\(spec.id.rawValue): no contract")
                continue
            }
            let named = Set(contract.params.keys)
            if named != spec.allowedParams {
                problems.append("\(spec.id.rawValue): contract \(named.sorted()) vs allowed \(spec.allowedParams.sorted())")
            }
            for group in contract.required where group.isEmpty || !Set(group).isSubset(of: spec.allowedParams) {
                problems.append("\(spec.id.rawValue): required group \(group) names an unknown key")
            }
            for (key, rule) in contract.params where (rule.kind == nil) == (rule.reason == nil) {
                problems.append("\(spec.id.rawValue).\(key): a rule is enforced with a kind or unconstrained with a reason")
            }
        }
        for id in OperationRegistry.parameterContracts.keys where OperationRegistry.specs.first(where: { $0.id == id })?.allowedParams.isEmpty ?? true {
            problems.append("\(id.rawValue): a contract for a command with no parameters")
        }
        let complete = problems.isEmpty
        #expect(complete, "\(problems.joined(separator: "\n"))")
    }

    @Test("an enforced parameter given a value outside its kind is refused before any channel runs")
    func enforcedKindsAreRefused() async {
        var problems: [String] = []
        for spec in OperationRegistry.specs {
            guard let contract = OperationRegistry.parameterContracts[spec.id] else { continue }
            for (key, rule) in contract.params.sorted(by: { $0.key < $1.key }) {
                guard let kind = rule.kind else { continue }
                guard let alone = Self.filling(contract, prefer: key) else {
                    problems.append("\(spec.id.rawValue).\(key): a required group has no sample")
                    continue
                }
                var beside = alone
                for (other, otherRule) in contract.params where other != key && otherRule.kind != nil {
                    beside[other] = otherRule.sample
                }
                for (label, context) in [("alone", alone), ("beside the others", beside)] {
                    var control = context
                    control[key] = rule.sample
                    var outside = context
                    outside[key] = kind.outsideValue
                    let controlled = await Self.dispatch(spec, control)
                    let refusedOutside = await Self.dispatch(spec, outside)
                    if !Self.attributable(control: controlled, outside: refusedOutside) {
                        problems.append("\(spec.id.rawValue).\(key)=\(kind.rawValue) \(label): control "
                            + "\(Self.describe(controlled)) / outside \(Self.describe(refusedOutside))")
                    }
                }
            }
        }
        let held = problems.isEmpty
        #expect(held, "\(problems.joined(separator: "\n"))")
    }

    @Test("each allowed value is taken, and a value outside the list is refused for that reason")
    func allowedValuesAreTheDispatchers() async {
        var problems: [String] = []
        for spec in OperationRegistry.specs {
            guard let contract = OperationRegistry.parameterContracts[spec.id] else { continue }
            for (key, rule) in contract.params.sorted(by: { $0.key < $1.key }) {
                guard let allowed = rule.allowed, let base = Self.filling(contract, prefer: key) else { continue }
                var control = base
                control[key] = rule.sample
                let controlled = await Self.dispatch(spec, control)
                for value in allowed {
                    var request = base
                    request[key] = .string(value)
                    let outcome = await Self.dispatch(spec, request)
                    if !Self.accepted(outcome) {
                        problems.append("\(spec.id.rawValue).\(key)=\(value) refused: \(Self.describe(outcome))")
                    }
                }
                var outside = base
                outside[key] = .string("lpm-957-not-a-listed-value")
                let refusedOutside = await Self.dispatch(spec, outside)
                if !Self.attributable(control: controlled, outside: refusedOutside) {
                    problems.append("\(spec.id.rawValue).\(key): an unlisted value was not refused for itself: "
                        + Self.describe(refusedOutside))
                }
            }
        }
        let held = problems.isEmpty
        #expect(held, "\(problems.joined(separator: "\n"))")
    }

    @Test("a request missing a required group is refused, and one with every group filled is accepted")
    func requiredGroupsAreRequired() async {
        var problems: [String] = []
        for spec in OperationRegistry.specs {
            guard let contract = OperationRegistry.parameterContracts[spec.id], !contract.required.isEmpty else { continue }
            guard var full = Self.filling(contract) else {
                problems.append("\(spec.id.rawValue): a required group has no sample")
                continue
            }
            let accepted = await Self.dispatch(spec, full)
            if !Self.accepted(accepted) {
                problems.append("\(spec.id.rawValue) with \(full.keys.sorted()): refused: \(Self.describe(accepted))")
            }
            for (offset, group) in contract.required.enumerated() {
                guard var missing = Self.filling(contract, skipping: offset) else { continue }
                for (key, value) in full where !group.contains(key) { missing[key] = value }
                let outcome = await Self.dispatch(spec, missing)
                if !Self.attributable(control: accepted, outside: outcome) {
                    problems.append("\(spec.id.rawValue) without \(group): \(Self.describe(outcome))")
                }
            }
        }
        let held = problems.isEmpty
        #expect(held, "\(problems.joined(separator: "\n"))")
    }

    /// The `type` / `anyOf` subset of JSON Schema the kinds use.
    private static func admits(_ schema: Value, _ value: Value) -> Bool {
        let object = schema.objectValue ?? [:]
        if let anyOf = object["anyOf"]?.arrayValue {
            return anyOf.contains { admits($0, value) }
        }
        let types = object["type"]?.arrayValue?.compactMap(\.stringValue) ?? object["type"]?.stringValue.map { [$0] } ?? []
        return types.contains { type in
            switch (type, value) {
            case ("integer", .int): return true
            case ("integer", .double(let d)): return d.rounded() == d
            case ("number", .int), ("number", .double): return true
            case ("string", .string), ("boolean", .bool), ("object", .object), ("array", .array): return true
            default: return false
            }
        }
    }

    @Test("each kind's schema admits every shape its reader accepts, and each enforced sample")
    func schemasAdmitWhatTheReadersAccept() {
        // The shapes each helper reads (DispatcherSupport and the MIDI dispatcher's strictInt).
        let accepted: [ParamKind: [Value]] = [
            .integer: [.int(5), .double(5.0), .string("5")],
            .number: [.double(0.5), .int(1), .string("0.5")],
            .scalar: [.string("x"), .int(1), .double(1.5), .bool(true)],
            .string: [.string("x")],
            .boolean: [.bool(true), .bool(false)],
            .booleanLike: [.bool(true), .string("yes"), .int(1)],
            .object: [.object(["a": .int(1)])],
            .listOrString: [.array([.int(1)]), .string("1,2")],
            .array: [.array([])],
            .stringOrInteger: [.string("1/8"), .int(200)],
        ]
        var problems: [String] = []
        for (kind, values) in accepted {
            for value in values where !Self.admits(kind.schema, value) {
                problems.append("\(kind.rawValue) does not admit \(value)")
            }
            if Self.admits(kind.schema, kind.outsideValue) {
                problems.append("\(kind.rawValue) admits its own outside value \(kind.outsideValue)")
            }
        }
        for (id, contract) in OperationRegistry.parameterContracts {
            for (key, rule) in contract.params {
                if let kind = rule.kind, let sample = rule.sample, !Self.admits(kind.schema, sample) {
                    problems.append("\(id.rawValue).\(key): sample \(sample) is outside \(kind.rawValue)")
                }
            }
        }
        let held = problems.isEmpty
        #expect(held, "\(problems.joined(separator: "\n"))")
    }

    @Test("the rich schema carries each enforced kind and each required group")
    func theSchemaCarriesTheContract() {
        let entries = OperationCatalog.snapshot().operations
        var problems: [String] = []
        for entry in entries {
            guard let id = OperationID(rawValue: entry.id), let contract = OperationRegistry.parameterContracts[id] else { continue }
            let branch = CommandSchemaProjection.branch(for: entry, strictParams: true)
            let params = branch.objectValue?["properties"]?.objectValue?["params"]?.objectValue
            let properties = params?["properties"]?.objectValue ?? [:]
            for (key, rule) in contract.params {
                let expected = rule.schema
                if properties[key] != expected {
                    problems.append("\(entry.id).\(key): schema \(String(describing: properties[key]))")
                }
            }
            let groups = params?["allOf"]?.arrayValue ?? []
            if groups.count != contract.required.count {
                problems.append("\(entry.id): \(groups.count) required groups in the schema, \(contract.required.count) in the contract")
            }
        }
        let held = problems.isEmpty
        #expect(held, "\(problems.joined(separator: "\n"))")
    }
}
