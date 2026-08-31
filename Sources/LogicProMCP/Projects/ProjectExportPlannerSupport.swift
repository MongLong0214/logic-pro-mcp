import Foundation
import MCP

extension ProjectExportPlanner {
    static func workflowSteps(
        for index: Int,
        artifactKinds: [String]
    ) -> [ProjectExportWorkflowStep] {
        var steps = [
            ProjectExportWorkflowStep(
                id: "project_\(index)_open",
                title: "Open project after confirming expected path",
                tool: "logic_project",
                command: "open",
                mutates: true,
                executed: false,
                requiresConfirmationLevel: confirmationLabel(for: "open"),
                stopConditions: ["wrong_project_observed", "open_failed", "ambiguous_save_state"]
            )
        ]
        if artifactKinds.contains(where: { $0 != "stem" }) {
            steps.append(ProjectExportWorkflowStep(
                id: "project_\(index)_bounce_export",
                title: "Trigger approved bounce/export operation",
                tool: "logic_project",
                command: "bounce",
                mutates: true,
                executed: false,
                requiresConfirmationLevel: confirmationLabel(for: "bounce"),
                stopConditions: ["missing_output", "stale_output", "overwrite_risk"]
            ))
        }
        if artifactKinds.contains("stem") {
            steps.append(ProjectExportWorkflowStep(
                id: "project_\(index)_stem_export",
                title: "Run the per-track export-panel phase inside export_run (no standalone stem command)",
                tool: "logic_project",
                command: nil,
                mutates: true,
                executed: false,
                requiresConfirmationLevel: confirmationLabel(for: "export_run"),
                stopConditions: [
                    "destination_not_visible_in_export_browser",
                    "missing_output",
                    "unbound_stem_subject_result",
                    "overwrite_risk",
                ]
            ))
        }
        return steps
    }

    static func confirmationLabel(for command: String) -> String {
        DestructivePolicy.level(for: command) == .l3 ? "L3" : "L2"
    }

    static func requiredConfirmations(artifactKinds: [String]) -> [ProjectExportConfirmation] {
        var boundaries = ["open"]
        if artifactKinds.contains(where: { $0 != "stem" }) {
            boundaries.append("bounce")
        }
        if artifactKinds.contains("stem") {
            // Per-track export is an internal phase of the registered
            // `logic_project export_run` command.  There is no public `stem`
            // command to advertise as an independently invocable step.
            boundaries.append("export_run")
        }
        return [ProjectExportConfirmation(
            level: "L2",
            requiredFor: boundaries,
            message: "Batch export execution must confirm every project open and each selected export boundary before mutation."
        )]
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
                // A late-bound stem path is its destination directory, not an
                // eventual filename. Two stems therefore cannot be diagnosed
                // as a same-path collision before Logic has named either file.
                guard art.filenamesLateBound != true else { return art }
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
                        issues: verification.issues + ["artifact_path_collides_in_plan"],
                        existingAudioFileCount: verification.existingAudioFileCount
                    ),
                    analysis: art.analysis,
                    destination: art.destination,
                    subjects: art.subjects,
                    filenamesLateBound: art.filenamesLateBound,
                    planningReason: art.planningReason
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

    static func unsupportedOrBlockedSteps(artifactKinds: [String]) -> [ProjectExportBlockedStep] {
        var steps = [
            ProjectExportBlockedStep(
                operation: "cloud_delivery",
                reason: "Cloud upload, email, and external sharing are explicitly out of scope.",
                safeAlternative: "Write artifacts only under the approved local output root."
            ),
        ]
        if artifactKinds.contains("stem") {
            steps.append(ProjectExportBlockedStep(
                operation: "export_resume",
                reason: "Stem filenames are assigned by Logic after export, so existing artifact identity cannot be established before a run.",
                safeAlternative: "Re-run stem export into a clean destination; partial stem export cannot be resumed."
            ))
        }
        return steps
    }

    /// #369: the bounce/export step's real execution dependencies, so the manifest
    /// is honest about what the run needs instead of only reporting
    /// `validation_status: valid`. The default export path drives Logic's Bounce
    /// dialog out-of-process (the bundled `logic_bounce.py` helper) — it is NOT
    /// gated on the MIDIKeyCommands MIDI-Learn binding, which the correction in
    /// the `automation_permission` detail spells out.
    static func executionPreconditions(artifactKinds: [String]) -> [ProjectExportPrecondition] {
        var preconditions: [ProjectExportPrecondition] = []
        if artifactKinds.contains(where: { $0 != "stem" }) {
            preconditions += [
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
            ProjectExportPrecondition(
                requirement: "input_source_available",
                appliesToCommands: ["bounce"],
                detail: "The export step types the destination filename into Logic's Bounce/save panel with "
                    + "synthetic keystrokes, so the helper first switches the active keyboard input source to an "
                    + "ABC or US layout (com.apple.keylayout.ABC or com.apple.keylayout.US); one of those must be "
                    + "enabled in System Settings > Keyboard > Input Sources. If neither is enabled the helper FAILS "
                    + "CLOSED with input_source_switch_failed instead of continuing (a Mac with only a French/AZERTY "
                    + "source enabled hits this once the project has opened). Failing closed is correct because "
                    + "keystroke automation on a non-ABC/US layout would type the wrong characters into the filename.",
                verifyWith: "LogicProMCP doctor (bundled logic_input_source.py helper)"
            ),
            ]
        }
        if artifactKinds.contains("stem") {
            preconditions.append(ProjectExportPrecondition(
                requirement: "accessibility_export_panel",
                appliesToCommands: ["export_run"],
                detail: "The stem phase is executed only inside logic_project export_run; there is no standalone stem command. It opens Logic's File > Export > All Tracks as Audio Files panel through Accessibility, selects an existing destination folder that is visible in the panel browser, requires the observed One File per Track value, and waits for the progress window to disappear. A dry plan validates only the filesystem directory: browser visibility is an execution-time precondition that can be observed only after the panel opens, where an unreachable folder is refused before Export is pressed. It does not use project.bounce or the keyboard-driven bounce helper. Eligible outputs are only top-level non-directory entries with suffix wav, wave, aif, aiff, aifc, m4a, or mp3; no output format is selected or promised by this driver.",
                verifyWith: "LogicProMCP --check-permissions"
            ))
        }
        return preconditions
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
