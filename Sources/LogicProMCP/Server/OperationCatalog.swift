import Foundation

struct OperationCatalogSnapshot: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let generatedAt: String
    let operationCount: Int
    let operations: [OperationCatalogEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case operationCount = "operation_count"
        case operations
    }
}

struct OperationCatalogEntry: Codable, Sendable, Equatable {
    let id: String
    let tool: String
    let command: String
    let mutability: String
    let target: String
    let confirmation: String
    let verification: String
    let retry: String
    let deadline: String
    let availability: String
    let allowedParams: [String]
    let capability: String
    let dirtySections: [String]
    /// PRD-007: absent for ops with no target to mis-bind (see
    /// `OperationSpec.indexBinding`), so the wire distinguishes "not applicable"
    /// from any tier value rather than flattening both into a string.
    let indexBinding: String?
}

enum OperationCatalog {
    static func snapshot(now: Date = Date()) -> OperationCatalogSnapshot {
        let operations = OperationRegistry.specs
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map { spec in
                OperationCatalogEntry(
                    id: spec.id.rawValue,
                    tool: spec.tool.rawValue,
                    command: spec.command,
                    mutability: wire(spec.mutability),
                    target: wire(spec.target),
                    confirmation: wire(spec.confirmation),
                    verification: wire(spec.verification),
                    retry: wire(spec.retry),
                    deadline: wire(spec.deadline),
                    availability: wire(spec.availability),
                    allowedParams: spec.allowedParams.sorted(),
                    capability: spec.capability.rawValue,
                    dirtySections: spec.dirtySections.map(\.rawValue).sorted(),
                    indexBinding: spec.indexBinding.map(wire)
                )
            }
        return OperationCatalogSnapshot(
            schemaVersion: 1,
            generatedAt: ISO8601DateFormatter.cacheFormatter.string(from: now),
            operationCount: operations.count,
            operations: operations
        )
    }

    private static func wire(_ value: Mutability) -> String {
        switch value {
        case .mutating: "mutating"
        case .readOnly: "read_only"
        }
    }

    private static func wire(_ value: TargetPolicy) -> String {
        switch value {
        case .none: "none"
        case .acceptsStableTarget: "accepts_stable_target"
        }
    }

    private static func wire(_ value: IndexBindingPolicy) -> String {
        switch value {
        case .refRequired: "ref_required"
        case .corroborated: "corroborated"
        case .legacyIndexAllowed: "legacy_index_allowed"
        }
    }

    private static func wire(_ value: ConfirmationPolicy) -> String {
        switch value {
        case .none: "none"
        case .l1: "l1"
        case .l2: "l2"
        case .l3: "l3"
        }
    }

    private static func wire(_ value: VerificationPolicy) -> String {
        switch value {
        case .none: "none"
        case .readbackRequired: "readback_required"
        case .bestEffort: "best_effort"
        }
    }

    private static func wire(_ value: RetryPolicy) -> String {
        switch value {
        case .idempotent: "idempotent"
        case .beforeWriteBoundaryOnly: "before_write_boundary_only"
        case .neverAutomatic: "never_automatic"
        }
    }

    private static func wire(_ value: DeadlineClass) -> String {
        switch value {
        case .short: "short"
        case .medium: "medium"
        case .long: "long"
        }
    }

    private static func wire(_ value: AvailabilityPolicy) -> String {
        switch value {
        case .defaultInstall: "default_install"
        case .requiresProfile: "requires_profile"
        case .requiresKeyBinding: "requires_key_binding"
        case .experimental: "experimental"
        case .unsupported: "unsupported"
        }
    }
}
