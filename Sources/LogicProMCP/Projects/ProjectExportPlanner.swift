import Foundation
import MCP

enum ProjectExportPlanner {
    static let schema = "logic_pro_mcp_export_manifest.v1"
    static let supportedArtifactKinds: Set<String> = ["bounce", "stem", "preview", "variant"]

    static func plan(params: [String: Value], fileManager: FileManager = .default) throws -> ProjectExportPlan {
        let projects = try projectPaths(from: params)
        let outputRoot = try outputRoot(from: params, fileManager: fileManager)
        let artifacts = try artifactKinds(from: params)
        let collisionPolicy = stringParam(params, "collision_policy", default: "fail_if_exists")
        guard ["fail_if_exists", "skip_existing"].contains(collisionPolicy) else {
            throw ExportPlanError.invalid("collision_policy must be fail_if_exists or skip_existing")
        }
        let namingPolicy = try namingPolicy(from: params)

        let rootURL = URL(fileURLWithPath: outputRoot).standardizedFileURL
        let projectPlans = projects.enumerated().map { index, path in
            projectPlan(
                index: index,
                path: path,
                outputRoot: rootURL,
                artifactKinds: artifacts,
                collisionPolicy: collisionPolicy,
                fileManager: fileManager
            )
        }

        // PR99-C1 / PR99-edge-2 / PR99-edge-3: aggregate every resolved artifact
        // path across ALL projects and flag any path produced by 2+ artifacts so
        // batch exports cannot silently overwrite each other (defeating
        // no_silent_overwrite). Comparison is case-insensitive because the default
        // macOS volumes (APFS/HFS+) are case-insensitive, so 'Song' and 'song'
        // collide on disk too. Each colliding artifact gets a forced issue, which
        // flips the plan to "degraded" via the existing non-empty-issues predicate.
        let resolvedProjectPlans = flagIntraPlanCollisions(projectPlans)

        let surfacedConstraints = unsupportedOrBlockedSteps()
        let status = resolvedProjectPlans.contains { project in
            project.validationStatus != "valid" ||
                project.expectedArtifacts.contains { !$0.verification.issues.isEmpty }
        }
            ? "degraded"
            : "planned"

        return ProjectExportPlan(
            schema: schema,
            runID: deterministicRunID(projects: projects, outputRoot: outputRoot, artifacts: artifacts),
            // C3: real run-window anchor so the advertised mtime_within_run_window
            // gate is evaluable — an executor bounds post-export mtime to >= this.
            generatedAt: ISO8601DateFormatter.cacheFormatter.string(from: Date()),
            status: status,
            executionMode: "dry_run_only",
            outputRoot: outputRoot,
            collisionPolicy: collisionPolicy,
            namingPolicy: namingPolicy,
            projectCount: resolvedProjectPlans.count,
            projects: resolvedProjectPlans,
            requiredConfirmations: [
                ProjectExportConfirmation(
                    level: "L2",
                    requiredFor: ["open", "bounce"],
                    message: "Batch export execution must confirm every project open and export/bounce boundary before mutation."
                ),
            ],
            unsupportedOrBlockedSteps: surfacedConstraints,
            executionPreconditions: executionPreconditions(),
            baselineVerification: [
                "artifact_exists",
                "file_size_non_zero",
                "mtime_within_run_window",
                "path_under_output_root",
                "no_silent_overwrite",
            ],
            enhancementPath: [
                "After a real bounce/export, verify each produced artifact with logic_audio.analyze_file (logic_pro_mcp_audio_analysis.v1) for duration, non-silence, peak/clipping, sample-rate, channels, and honest loudness estimates.",
            ],
            nextSafeAction: "review_export_plan"
        )
    }

    private static func projectPlan(
        index: Int,
        path: String,
        outputRoot: URL,
        artifactKinds: [String],
        collisionPolicy: String,
        fileManager: FileManager
    ) -> ProjectExportPlanProject {
        var issues: [String] = []
        if !AppleScriptSafety.isValidProjectPath(path, requireExisting: false) {
            issues.append("project_path_must_be_absolute_logicx")
        }
        if !fileManager.fileExists(atPath: path) {
            issues.append("project_path_not_found")
        }

        let projectURL = URL(fileURLWithPath: path).standardizedFileURL
        let displayName = projectURL.deletingPathExtension().lastPathComponent
        let artifactPlans = artifactKinds.map { kind in
            artifact(
                kind: kind,
                displayName: displayName,
                outputRoot: outputRoot,
                collisionPolicy: collisionPolicy,
                fileManager: fileManager
            )
        }

        return ProjectExportPlanProject(
            index: index,
            projectPath: path,
            displayName: displayName,
            validationStatus: issues.isEmpty ? "valid" : "invalid",
            validationIssues: issues,
            expectedArtifacts: artifactPlans,
            workflowSteps: workflowSteps(for: index),
            manifestStatus: "pending"
        )
    }

    private static func artifact(
        kind: String,
        displayName: String,
        outputRoot: URL,
        collisionPolicy: String,
        fileManager: FileManager
    ) -> ProjectExportPlanArtifact {
        // PR99-C2: validate containment against the PRE-sanitization candidate so
        // the check is non-vacuous. A raw displayName containing ".." or a path
        // separator can resolve outside outputRoot once standardized; the sanitized
        // url below can never express that, so it alone could only ever be true.
        let rawComponent = "\(displayName)-\(kind).wav"
        let candidate = outputRoot.appendingPathComponent(rawComponent).standardizedFileURL
        let underRoot = candidate.path == outputRoot.path || candidate.path.hasPrefix(outputRoot.path + "/")

        let safeProject = sanitizeFileComponent(displayName)
        let url = outputRoot.appendingPathComponent("\(safeProject)-\(kind).wav").standardizedFileURL
        let existingPath = ProjectExportArtifactPathPolicy.preferredExistingVariant(
            for: url.path,
            fileManager: fileManager
        )
        let exists = existingPath != nil
        let attrs = existingPath.flatMap { try? fileManager.attributesOfItem(atPath: $0) }
        let size = (attrs?[.size] as? NSNumber)?.int64Value
        let mtime = (attrs?[.modificationDate] as? Date).map {
            ISO8601DateFormatter.cacheFormatter.string(from: $0)
        }
        var issues: [String] = []
        if !underRoot {
            issues.append("artifact_path_outside_output_root")
        }
        if exists && collisionPolicy == "fail_if_exists" {
            issues.append("artifact_would_overwrite")
        }
        // PR99-C3: only assert a definite zero-byte artifact when the size is a
        // concrete value. A vanished/unreadable file (TOCTOU, permissions, or a
        // directory/special file at the path) yields a nil size — that is
        // "unknown", not "zero", so emit a distinct token instead of lying.
        if exists, let size, size == 0 {
            issues.append("artifact_zero_bytes")
        } else if exists, size == nil {
            issues.append("artifact_size_unreadable")
        }

        return ProjectExportPlanArtifact(
            kind: kind,
            path: url.path,
            status: exists ? "existing" : "pending",
            verification: ProjectExportArtifactVerification(
                exists: exists,
                fileSizeBytes: size,
                mtime: mtime,
                pathUnderOutputRoot: underRoot,
                wouldOverwrite: exists && collisionPolicy == "fail_if_exists",
                issues: issues
            ),
            analysis: ["issue_29": "not_run_in_dry_run"]
        )
    }

}

enum ExportPlanError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}
