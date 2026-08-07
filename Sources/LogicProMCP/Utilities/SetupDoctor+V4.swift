import Foundation

extension SetupDoctor {
    enum DoctorProfile: String, Codable, Sendable, CaseIterable {
        case auto
        case core
        case mixer
        case keycmd
        case legacyScripter = "legacy-scripter"
        case full
    }

    enum ClientProfile: String, Codable, Sendable, CaseIterable {
        case auto
        case claudeCode = "claude-code"
        case claudeDesktop = "claude-desktop"
        case cursor
        case vscode
        case terminal
        case custom
    }

    enum CapabilityStatus: String, Codable, Sendable {
        case ready
        case notReady = "not_ready"
        case unknownLiveVerifyRequired = "unknown_live_verify_required"
        case notInProfile = "not_in_profile"
    }

    /// #461: per-operation readiness inside a capability group. Additive to the
    /// published schema — the group `status` keeps its existing four values, and
    /// this row carries the finer taxonomy the group verdict is derived FROM.
    struct OperationReadinessRow: Codable, Equatable, Sendable {
        let operation: String
        let readiness: String
        /// Channels that could actually run it under the current snapshot.
        let executableChannels: [String]
        /// The prerequisite that blocked the first-choice candidate, if any, so
        /// the output can name the setup action that would enable this operation.
        let blockedBy: String?

        enum CodingKeys: String, CodingKey {
            case operation
            case readiness
            case executableChannels = "executable_channels"
            case blockedBy = "blocked_by"
        }
    }

    struct CapabilityReadiness: Codable, Equatable, Sendable {
        let status: CapabilityStatus
        let checks: [String]
        let liveVerification: String?
        /// Empty for groups that declare no operations yet; those keep the
        /// pre-#461 check-only verdict rather than being silently claimed ready
        /// on the strength of an empty operation list.
        let operations: [OperationReadinessRow]

        init(
            status: CapabilityStatus,
            checks: [String],
            liveVerification: String?,
            operations: [OperationReadinessRow] = []
        ) {
            self.status = status
            self.checks = checks
            self.liveVerification = liveVerification
            self.operations = operations
        }

        enum CodingKeys: String, CodingKey {
            case status
            case checks
            case liveVerification = "live_verification"
            case operations
        }
    }

    enum PathEvidencePolicy: Sendable {
        case homeRelative
        case basenameOnly
        case hidden
    }

    enum EvidenceValue: Sendable {
        case bool(Bool)
        case int(Int)
        case enumValue(String)
        case version(String)
        case path(String, PathEvidencePolicy)
        case basename(String)
        case sensitive
    }

    struct SemanticVersion: Equatable, Comparable, Sendable {
        let major: Int
        let minor: Int
        let patch: Int
        let prerelease: String?
        let build: String?

        init?(_ raw: String) {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("v") || value.hasPrefix("V") {
                value.removeFirst()
            }
            let buildParts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
            let withoutBuild = String(buildParts[0])
            build = buildParts.count == 2 && !buildParts[1].isEmpty ? String(buildParts[1]) : nil
            let prereleaseParts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = prereleaseParts[0].split(separator: ".", omittingEmptySubsequences: false)
            guard core.count == 3,
                  let major = Int(core[0]), major >= 0,
                  let minor = Int(core[1]), minor >= 0,
                  let patch = Int(core[2]), patch >= 0,
                  core.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
                return nil
            }
            let prereleaseValue = prereleaseParts.count == 2 ? String(prereleaseParts[1]) : nil
            if prereleaseValue == "" { return nil }
            self.major = major
            self.minor = minor
            self.patch = patch
            prerelease = prereleaseValue
        }

        var normalizedCore: String {
            "\(major).\(minor).\(patch)"
        }

        static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
            switch (lhs.prerelease, rhs.prerelease) {
            case (nil, nil):
                return false
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case let (left?, right?):
                return left < right
            }
        }
    }

    static func selectedDoctorProfile(
        arguments: [String],
        runtime: Runtime,
        approvals: [ManualValidationChannel: ManualValidationApproval]
    ) -> (DoctorProfile, String) {
        if let raw = optionValue("--profile", in: arguments),
           let profile = DoctorProfile(rawValue: raw) {
            if profile == .auto {
                let inferred = inferredDoctorProfile(runtime: runtime, approvals: approvals)
                return (inferred.0, "explicit_auto_\(inferred.1)")
            }
            return (profile, "explicit_flag")
        }
        return inferredDoctorProfile(runtime: runtime, approvals: approvals)
    }

    private static func inferredDoctorProfile(
        runtime: Runtime,
        approvals: [ManualValidationChannel: ManualValidationApproval]
    ) -> (DoctorProfile, String) {
        let approvedChannels = Set(
            approvals.compactMap { channel, approval -> ManualValidationChannel? in
                switch approval.kind {
                case .approved, .intentionallySkipped:
                    return channel
                }
            }
        )
        if approvedChannels == Set(ManualValidationChannel.allCases) {
            return (.full, "manual_store_all_channels")
        }
        if approvedChannels == [.midiKeyCommands] {
            return (.keycmd, "manual_store_midi_key_commands")
        }
        if approvedChannels == [.scripter] {
            return (.legacyScripter, "manual_store_scripter")
        }
        let context = runtime.launchContext().context
        if context == "claude_code" || context == "claude_desktop" || context == "cursor" || context == "vscode" {
            return (.core, "launch_context_default_core")
        }
        return (.core, "default_core")
    }

    static func selectedClientProfile(
        arguments: [String],
        runtime: Runtime,
        claudeRegistration: ClaudeRegistration
    ) -> (ClientProfile, String) {
        if let raw = optionValue("--client", in: arguments),
           let profile = ClientProfile(rawValue: raw) {
            return profile == .auto ? inferredClientProfile(runtime: runtime, claudeRegistration: claudeRegistration) : (profile, "explicit_flag")
        }
        return inferredClientProfile(runtime: runtime, claudeRegistration: claudeRegistration)
    }

    private static func inferredClientProfile(
        runtime: Runtime,
        claudeRegistration: ClaudeRegistration
    ) -> (ClientProfile, String) {
        let context = runtime.launchContext().context
        switch context {
        case "claude_code": return (.claudeCode, "launch_context")
        case "claude_desktop": return (.claudeDesktop, "launch_context")
        case "cursor": return (.cursor, "launch_context")
        case "vscode": return (.vscode, "launch_context")
        default: break
        }
        switch claudeRegistration {
        case .registered, .nameOnly, .commandOnly:
            return (.claudeCode, "registration_config")
        case .notRegistered, .configUnavailable:
            break
        }
        switch runtime.readClaudeDesktopRegistration() {
        case .registered, .nameOnly, .commandOnly:
            return (.claudeDesktop, "registration_config")
        case .notRegistered, .configUnavailable:
            return (.claudeCode, "default_claude_code")
        }
    }

    static func optionValue(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    static func isProfileRequired(_ checkID: String, profile: DoctorProfile) -> Bool {
        guard let definition = checkDefinitionByID[checkID] else { return false }
        return !definition.optionalByDefault && profileRuleMatches(definition.profileRule, profile: profile)
    }

    static func profileRequiredCheckIDs(for profile: DoctorProfile) -> Set<String> {
        Set(orderedCheckIDs.filter { isProfileRequired($0, profile: profile) })
    }

    static func requiredCheckIDs(for profile: DoctorProfile, clientProfile: ClientProfile) -> Set<String> {
        Set(checkDefinitions.compactMap { definition in
            guard !definition.optionalByDefault,
                  profileRuleMatches(definition.profileRule, profile: profile),
                  clientRuleMatches(definition.clientRule, clientProfile: clientProfile) else {
                return nil
            }
            return definition.id.rawValue
        })
    }

    static func checksClosingRequiredGaps(
        _ checks: [Check],
        profile: DoctorProfile,
        clientProfile: ClientProfile
    ) -> [Check] {
        let requiredIDs = requiredCheckIDs(for: profile, clientProfile: clientProfile)
        let closed = checks.map { check in
            requiredIDs.contains(check.id) && check.optional
                ? requiredCheckFailure(id: check.id, reason: "required_check_marked_optional")
                : check
        }
        let emittedIDs = Set(closed.map(\.id))
        let missing = orderedCheckIDs.filter { requiredIDs.contains($0) && !emittedIDs.contains($0) }
        guard !missing.isEmpty else { return closed }
        return closed + missing.map { requiredCheckFailure(id: $0, reason: "required_check_missing") }
    }

    private static func requiredCheckFailure(id: String, reason: String) -> Check {
        let domain = id.split(separator: ".", maxSplits: 1).first.map(String.init) ?? "runtime"
        let summary = reason == "required_check_missing"
            ? "Required doctor check was not emitted; readiness cannot be claimed."
            : "Required doctor check was emitted as optional; readiness cannot be claimed."
        return check(
            id: id,
            domain: domain,
            status: .fail,
            summary: summary,
            evidence: ["reason": reason],
            remediationType: .manual,
            remediationValueOverride: "Report this doctor bug with the missing check id: \(id)"
        )
    }

    private static func profileRuleMatches(_ rule: String?, profile: DoctorProfile) -> Bool {
        let effectiveProfile = profile == .auto ? DoctorProfile.core : profile
        return ruleMatches(rule, value: effectiveProfile.rawValue)
    }

    private static func clientRuleMatches(_ rule: String?, clientProfile: ClientProfile) -> Bool {
        guard clientProfile != .auto else { return rule == nil }
        return ruleMatches(rule, value: clientProfile.rawValue)
    }

    private static func ruleMatches(_ rule: String?, value: String) -> Bool {
        guard let rule else { return true }
        return rule.split(separator: "|").contains { $0 == value }
    }

    static func capabilities(for checks: [Check], profile: DoctorProfile) -> [String: CapabilityReadiness] {
        let effectiveProfile = profile == .auto ? DoctorProfile.core : profile
        let byID = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: capabilityDefinitions.map { definition in
            let required = capabilityCheckIDs(for: definition.id)
            guard definition.profiles.contains(effectiveProfile) else {
                return (
                    definition.id,
                    CapabilityReadiness(
                        status: .notInProfile,
                        checks: required,
                        liveVerification: definition.liveVerification
                    )
                )
            }
            let statuses = required.compactMap { byID[$0]?.status }
            let missingRequired = statuses.count != required.count
            let checkStatus: CapabilityStatus
            if missingRequired || statuses.contains(.fail) || statuses.contains(.warn) {
                checkStatus = .notReady
            } else if statuses.contains(.manual) || statuses.contains(.skipped) {
                checkStatus = .unknownLiveVerifyRequired
            } else if definition.id == "mixer_mcu" {
                checkStatus = .unknownLiveVerifyRequired
            } else {
                checkStatus = .ready
            }

            // #461: the environment checks above say the SETUP looks fine. They
            // do not say every operation the group advertises has a runnable
            // route, and a group that passes its checks while one member
            // operation has no executable candidate was still reported ready.
            // The group verdict is now the weaker of the two, so a route gap can
            // only lower it — a passing check set can never manufacture
            // readiness the routes do not support.
            let plans = OperationCapabilityRegistry.plan(
                capability: definition.id,
                health: healthSnapshot(from: checks)
            )
            let status = plans.isEmpty
                ? checkStatus
                : weaker(checkStatus, capabilityStatus(for: OperationCapabilityRegistry.aggregate(plans)))

            return (
                definition.id,
                CapabilityReadiness(
                    status: status,
                    checks: required,
                    liveVerification: definition.liveVerification,
                    operations: plans.map { plan in
                        OperationReadinessRow(
                            operation: plan.operation,
                            readiness: plan.readiness.rawValue,
                            executableChannels: plan.executableChannels.map(\.rawValue),
                            blockedBy: plan.candidates.first(where: { !$0.isExecutable })?.blockingCheck
                        )
                    }
                )
            )
        })
    }

    /// #461: translate the doctor check set into the pure planner's input.
    ///
    /// `manual` and `skipped` become AWAITING rather than false. A held approval
    /// (#457) or an unstaged preset is not a broken environment — it is a step
    /// the operator has not taken — and reporting it as a hard failure would tell
    /// users something is wrong with their machine when nothing is.
    ///
    /// A check that did not run is absent from `satisfied` rather than recorded
    /// as false, so the planner can distinguish "we did not look" from "it does
    /// not work". Collapsing those is how an unverified claim becomes a verified
    /// one.
    static func healthSnapshot(from checks: [Check]) -> OperationCapabilityRegistry.HealthSnapshot {
        var satisfied: [String: Bool] = [:]
        var awaiting: Set<String> = []
        for check in checks {
            switch check.status {
            case .pass:
                satisfied[check.id] = true
            case .fail, .warn:
                satisfied[check.id] = false
            case .manual, .skipped:
                awaiting.insert(check.id)
            }
        }
        return OperationCapabilityRegistry.HealthSnapshot(satisfied: satisfied, awaitingManual: awaiting)
    }

    private static func capabilityStatus(
        for readiness: OperationCapabilityRegistry.OperationReadiness?
    ) -> CapabilityStatus {
        switch readiness {
        case .readyVerified:
            return .ready
        // Executable but unconfirmed. Publishing either as `ready` would promote
        // a send-only route to a verified claim, which is exactly what the
        // Honest Contract forbids elsewhere.
        case .readyDegraded, .unknownLiveVerifyRequired:
            return .unknownLiveVerifyRequired
        case .manualSetupRequired, .notReady:
            return .notReady
        case nil:
            return .notReady
        }
    }

    /// The more pessimistic of two verdicts. `notInProfile` is scoping, not
    /// readiness, so it is never weakened by a route plan.
    private static func weaker(_ lhs: CapabilityStatus, _ rhs: CapabilityStatus) -> CapabilityStatus {
        let rank: [CapabilityStatus: Int] = [
            .notReady: 0, .unknownLiveVerifyRequired: 1, .ready: 2, .notInProfile: 3,
        ]
        return (rank[lhs] ?? 0) <= (rank[rhs] ?? 0) ? lhs : rhs
    }

    static func buildEvidence(_ fields: [String: EvidenceValue]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fields.map { key, value in
            (key, renderEvidenceValue(value))
        })
    }

    static func renderEvidenceValue(_ value: EvidenceValue) -> String {
        switch value {
        case let .bool(raw):
            return String(raw)
        case let .int(raw):
            return String(raw)
        case let .enumValue(raw), let .version(raw):
            return raw
        case let .path(raw, policy):
            switch policy {
            case .homeRelative:
                return homeRelativePath(raw)
            case .basenameOnly:
                return URL(fileURLWithPath: raw).lastPathComponent
            case .hidden:
                return "hidden"
            }
        case let .basename(raw):
            return URL(fileURLWithPath: raw).lastPathComponent
        case .sensitive:
            return "redacted"
        }
    }

    static func homeRelativePath(_ value: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return value.replacingOccurrences(of: home, with: "~")
    }
}
