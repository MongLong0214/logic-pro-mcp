import Foundation
import MCP

extension ProjectExportPlanner {
    static func workflowSteps(for index: Int) -> [ProjectExportWorkflowStep] {
        [
            ProjectExportWorkflowStep(
                id: "project_\(index)_open",
                title: "Open project after confirming expected path",
                tool: "logic_project",
                command: "open",
                mutates: true,
                executed: false,
                requiresConfirmationLevel: confirmationLabel(for: "open"),
                stopConditions: ["wrong_project_observed", "open_failed", "ambiguous_save_state"]
            ),
            ProjectExportWorkflowStep(
                id: "project_\(index)_export",
                title: "Trigger approved bounce/export operation",
                tool: "logic_project",
                command: "bounce",
                mutates: true,
                executed: false,
                requiresConfirmationLevel: confirmationLabel(for: "bounce"),
                stopConditions: ["missing_output", "stale_output", "overwrite_risk"]
            ),
        ]
    }

    static func confirmationLabel(for command: String) -> String {
        DestructivePolicy.level(for: command) == .l3 ? "L3" : "L2"
    }

    static func flagIntraPlanCollisions(
        _ plans: [ProjectExportPlanProject]
    ) -> [ProjectExportPlanProject] {
        var pathCounts: [String: Int] = [:]
        for project in plans {
            for art in project.expectedArtifacts {
                pathCounts[art.path.lowercased(), default: 0] += 1
            }
        }
        let collidingPaths = Set(pathCounts.filter { $0.value > 1 }.keys)
        guard !collidingPaths.isEmpty else { return plans }

        return plans.map { project in
            let arts = project.expectedArtifacts.map { art -> ProjectExportPlanArtifact in
                guard collidingPaths.contains(art.path.lowercased()) else { return art }
                let verification = art.verification
                return ProjectExportPlanArtifact(
                    kind: art.kind,
                    path: art.path,
                    status: art.status,
                    verification: ProjectExportArtifactVerification(
                        exists: verification.exists,
                        fileSizeBytes: verification.fileSizeBytes,
                        mtime: verification.mtime,
                        pathUnderOutputRoot: verification.pathUnderOutputRoot,
                        wouldOverwrite: verification.wouldOverwrite,
                        issues: verification.issues + ["artifact_path_collides_in_plan"]
                    ),
                    analysis: art.analysis
                )
            }
            return ProjectExportPlanProject(
                index: project.index,
                projectPath: project.projectPath,
                displayName: project.displayName,
                validationStatus: project.validationStatus,
                validationIssues: project.validationIssues,
                expectedArtifacts: arts,
                workflowSteps: project.workflowSteps,
                manifestStatus: project.manifestStatus
            )
        }
    }

    static func unsupportedOrBlockedSteps() -> [ProjectExportBlockedStep] {
        [
            ProjectExportBlockedStep(
                operation: "cloud_delivery",
                reason: "Cloud upload, email, and external sharing are explicitly out of scope.",
                safeAlternative: "Write artifacts only under the approved local output root."
            ),
        ]
    }

    /// #369: the bounce/export step's real execution dependencies, so the manifest
    /// is honest about what the run needs instead of only reporting
    /// `validation_status: valid`. The default export path drives Logic's Bounce
    /// dialog out-of-process (the bundled `logic_bounce.py` helper) — it is NOT
    /// gated on the MIDIKeyCommands MIDI-Learn binding, which the correction in
    /// the `automation_permission` detail spells out.
    static func executionPreconditions() -> [ProjectExportPrecondition] {
        [
            ProjectExportPrecondition(
                requirement: "automation_permission",
                appliesToCommands: ["bounce"],
                detail: "The bounce/export step drives Logic Pro's Bounce dialog out-of-process: it issues "
                    + "Logic's default Bounce command (Cmd+B, or File > Bounce > Project or Section) and confirms "
                    + "the settings and save panel through System Events, so Automation approval for BOTH System "
                    + "Events and Logic Pro is required or the run fails at the bounce step. This does NOT require "
                    + "the MIDIKeyCommands manual MIDI-Learn binding: that channel is only a fallback route for the "
                    + "standalone project.bounce operation reported by logic_system health (whose primary route is "
                    + "also System Events), not this dialog-driven export path.",
                verifyWith: "LogicProMCP --check-permissions"
            ),
            ProjectExportPrecondition(
                requirement: "post_event_access",
                appliesToCommands: ["bounce"],
                detail: "The Bounce settings and save panel (filename entry, destination navigation, and the "
                    + "confirm button) is driven with native CGEvent, which requires trusted PostEvent access "
                    + "(granted through the launcher app's Accessibility entry).",
                verifyWith: "LogicProMCP doctor (permissions.post_event_access)"
            ),
            ProjectExportPrecondition(
                requirement: "bounce_helper_available",
                appliesToCommands: ["bounce"],
                detail: "The export step runs the bundled logic_bounce.py helper; it must resolve on the install "
                    + "share path, pass the ownership-trust check, and have a python3 interpreter available.",
                verifyWith: "LogicProMCP doctor"
            ),
        ]
    }

    static func projectPaths(from params: [String: Value]) throws -> [String] {
        if let array = params["projects"]?.arrayValue {
            let paths = array.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard paths.count == array.count, !paths.isEmpty else {
                throw ExportPlanError.invalid("projects must be a non-empty array of absolute .logicx paths")
            }
            return paths
        }
        let path = stringParam(params, "project", "path")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw ExportPlanError.invalid("export_plan requires projects or project/path")
        }
        return [path]
    }

    static func outputRoot(from params: [String: Value], fileManager: FileManager = .default) throws -> String {
        let root = stringParam(params, "output_root", "outputRoot")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard root.hasPrefix("/") else {
            throw ExportPlanError.invalid("output_root must be an absolute local path")
        }
        let standardized = URL(fileURLWithPath: root)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard standardized != "/" else {
            throw ExportPlanError.invalid("output_root must not be the filesystem root")
        }
        let blockedPrefixes = ["/dev/", "/System/", "/private/var/db/", "/etc/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/"]
        guard !blockedPrefixes.contains(where: { standardized == String($0.dropLast()) || standardized.hasPrefix($0) }) else {
            throw ExportPlanError.invalid("output_root must not resolve to a system location: \(standardized)")
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw ExportPlanError.invalid("output_root must be a directory path, not an existing file: \(standardized)")
        }
        return standardized
    }

    static func artifactKinds(from params: [String: Value]) throws -> [String] {
        let raw: [String]
        if let array = params["artifacts"]?.arrayValue {
            raw = array.compactMap { $0.stringValue?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            guard raw.count == array.count else {
                throw ExportPlanError.invalid("artifacts must be an array of strings")
            }
        } else {
            raw = [stringParam(params, "artifact", "kind", default: "bounce").lowercased()]
        }
        let cleaned = raw.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            throw ExportPlanError.invalid("at least one artifact kind is required")
        }
        let unsupported = cleaned.filter { !supportedArtifactKinds.contains($0) }
        guard unsupported.isEmpty else {
            throw ExportPlanError.invalid("unsupported artifact kind(s): \(unsupported.joined(separator: ","))")
        }
        return Array(Set(cleaned)).sorted()
    }

    static func namingPolicy(from params: [String: Value]) throws -> String {
        let policy = stringParam(params, "naming_policy", default: "project-name-kind")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard policy == "project-name-kind" else {
            throw ExportPlanError.invalid("naming_policy must be project-name-kind")
        }
        return policy
    }

    static func deterministicRunID(projects: [String], outputRoot: String, artifacts: [String]) -> String {
        let seed = ([outputRoot] + projects + artifacts).joined(separator: "|")
        let hash = seed.utf8.reduce(UInt64(14695981039346656037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1099511628211
        }
        return "export-" + String(format: "%016llx", hash)
    }

    static func sanitizeFileComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : Character("-")
        }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? "project" : value
    }
}
