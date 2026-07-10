enum OperationID: String, CaseIterable, Codable, Sendable, Hashable {
    case transportPlay = "transport.play"
    case transportStop = "transport.stop"
    case transportRecord = "transport.record"
    case transportPause = "transport.pause"
    case transportRewind = "transport.rewind"
    case transportFastForward = "transport.fast_forward"
    case transportToggleCycle = "transport.toggle_cycle"
    case transportToggleMetronome = "transport.toggle_metronome"
    case transportSetTempo = "transport.set_tempo"
    case transportGotoPosition = "transport.goto_position"
    case transportSetCycleRange = "transport.set_cycle_range"
    case transportToggleCountIn = "transport.toggle_count_in"
    case transportToggleAutopunch = "transport.toggle_autopunch"
}

enum ToolID: String, Sendable, Equatable {
    case logicTransport = "logic_transport"
}

enum Mutability: Sendable, Equatable {
    case `mutating`
    case readOnly
}

enum ConfirmationPolicy: Sendable, Equatable {
    case none
    case l1
    case l2
    case l3
}

enum TargetPolicy: Sendable, Equatable {
    case none
    case requiresStableTarget
}

enum VerificationPolicy: Sendable, Equatable {
    case none
    case readbackRequired
    case bestEffort
}

enum RetryPolicy: Sendable, Equatable {
    case idempotent
    case beforeWriteBoundaryOnly
    case neverAutomatic
}

enum DeadlineClass: Sendable, Equatable {
    case short
    case medium
    case long

    var seconds: Double {
        switch self {
        case .short: 25
        case .medium: 90
        case .long: 300
        }
    }
}

enum AvailabilityPolicy: Sendable, Equatable {
    case defaultInstall
    case requiresProfile
    case requiresKeyBinding
    case experimental
    case unsupported
}

struct CapabilityID: RawRepresentable, Sendable, Hashable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

struct OperationSpec: Sendable {
    let id: OperationID
    let tool: ToolID
    let command: String
    let mutability: Mutability
    let confirmation: ConfirmationPolicy
    let target: TargetPolicy
    let verification: VerificationPolicy
    let retry: RetryPolicy
    let deadline: DeadlineClass
    let availability: AvailabilityPolicy
    let capability: CapabilityID
}

enum OperationRegistry {
    struct ValidationEntry: Sendable {
        let operationID: String
        let tool: String
        let command: String
    }

    private static let allowedOperationIDs: Set<String> = [
        "transport.play", "transport.stop", "transport.record", "transport.pause",
        "transport.rewind", "transport.fast_forward", "transport.toggle_cycle",
        "transport.toggle_metronome", "transport.set_tempo", "transport.goto_position",
        "transport.set_cycle_range", "transport.toggle_count_in", "transport.toggle_autopunch",
    ]

    private static let allowedCommands: Set<String> = [
        "play", "stop", "record", "pause", "rewind", "fast_forward", "toggle_cycle",
        "toggle_metronome", "set_tempo", "goto_position", "set_cycle_range", "toggle_count_in",
        "toggle_autopunch",
    ]

    static let specs: [OperationSpec] = ([
        (.transportPlay, "play", .readbackRequired, .defaultInstall),
        (.transportStop, "stop", .readbackRequired, .defaultInstall),
        (.transportRecord, "record", .readbackRequired, .defaultInstall),
        (.transportPause, "pause", .readbackRequired, .defaultInstall),
        (.transportRewind, "rewind", .none, .defaultInstall),
        (.transportFastForward, "fast_forward", .none, .defaultInstall),
        (.transportToggleCycle, "toggle_cycle", .none, .defaultInstall),
        (.transportToggleMetronome, "toggle_metronome", .readbackRequired, .defaultInstall),
        (.transportSetTempo, "set_tempo", .none, .defaultInstall),
        (.transportGotoPosition, "goto_position", .readbackRequired, .defaultInstall),
        (.transportSetCycleRange, "set_cycle_range", .none, .unsupported),
        (.transportToggleCountIn, "toggle_count_in", .none, .defaultInstall),
        (.transportToggleAutopunch, "toggle_autopunch", .none, .defaultInstall),
    ] as [(OperationID, String, VerificationPolicy, AvailabilityPolicy)]).map { entry in
        OperationSpec(
            id: entry.0,
            tool: .logicTransport,
            command: entry.1,
            mutability: Mutability.`mutating`,
            confirmation: .none,
            target: .none,
            verification: entry.2,
            retry: .neverAutomatic,
            deadline: .short,
            availability: entry.3,
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    }

    static func spec(tool: String, command: String) -> OperationSpec? {
        specs.first { $0.tool.rawValue == tool && $0.command == command }
    }

    static var mutatingCommands: Set<String> {
        Set(specs.filter { $0.mutability == Mutability.`mutating` }.map(\.command))
    }

    static func deadlineSeconds(tool: String, command: String) -> Double? {
        spec(tool: tool, command: command)?.deadline.seconds
    }

    static func validationErrors(for candidateSpecs: [OperationSpec] = specs) -> [String] {
        validationErrors(for: candidateSpecs.map {
            ValidationEntry(operationID: $0.id.rawValue, tool: $0.tool.rawValue, command: $0.command)
        })
    }

    static func validationErrors(for entries: [ValidationEntry]) -> [String] {
        var errors: [String] = []

        if entries.count != allowedOperationIDs.count {
            errors.append("entry count: expected \(allowedOperationIDs.count), got \(entries.count)")
        }

        let duplicateIDs = Dictionary(grouping: entries.map(\.operationID), by: { $0 })
            .filter { $0.value.count > 1 }
            .keys.sorted()
        if !duplicateIDs.isEmpty {
            errors.append("duplicate operation IDs: \(duplicateIDs.joined(separator: ", "))")
        }

        let duplicateCommands = Dictionary(grouping: entries.map(\.command), by: { $0 })
            .filter { $0.value.count > 1 }
            .keys.sorted()
        if !duplicateCommands.isEmpty {
            errors.append("duplicate commands: \(duplicateCommands.joined(separator: ", "))")
        }

        let actualIDs = Set(entries.map(\.operationID))
        let missingIDs = allowedOperationIDs.subtracting(actualIDs).sorted()
        if !missingIDs.isEmpty {
            errors.append("missing operation IDs: \(missingIDs.joined(separator: ", "))")
        }
        let unexpectedIDs = actualIDs.subtracting(allowedOperationIDs).sorted()
        if !unexpectedIDs.isEmpty {
            errors.append("unexpected operation IDs: \(unexpectedIDs.joined(separator: ", "))")
        }

        let actualCommands = Set(entries.map(\.command))
        let missingCommands = allowedCommands.subtracting(actualCommands).sorted()
        if !missingCommands.isEmpty {
            errors.append("missing commands: \(missingCommands.joined(separator: ", "))")
        }
        let unexpectedCommands = actualCommands.subtracting(allowedCommands).sorted()
        if !unexpectedCommands.isEmpty {
            errors.append("unexpected commands: \(unexpectedCommands.joined(separator: ", "))")
        }

        let incorrectTools = entries
            .filter { $0.tool != ToolID.logicTransport.rawValue }
            .map { "\($0.command)=\($0.tool)" }
            .sorted()
        if !incorrectTools.isEmpty {
            errors.append("incorrect tools: \(incorrectTools.joined(separator: ", "))")
        }

        let mismatches = entries
            .filter { $0.operationID != "transport.\($0.command)" }
            .map { "\($0.operationID)=\($0.command)" }
            .sorted()
        if !mismatches.isEmpty {
            errors.append("ID/command mismatches: \(mismatches.joined(separator: ", "))")
        }

        return errors
    }
}
