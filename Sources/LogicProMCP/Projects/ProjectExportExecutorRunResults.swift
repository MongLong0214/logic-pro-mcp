import Foundation

extension ProjectExportExecutor {
    static func aggregate(
        plan: ProjectExportPlan,
        resume: Bool,
        projects: [RunProject]
    ) -> RunResult {
        let allArtifacts = projects.flatMap(\.artifacts)
        let verified = allArtifacts.filter { $0.state == "A" && $0.bounceFired }.count
        let skipped = allArtifacts.filter { $0.state == "A" && !$0.bounceFired }.count
        let uncertain = allArtifacts.filter { $0.state == "B" }.count
        let failed = allArtifacts.filter { $0.state == "C" }.count
        let succeededCount = verified + skipped

        let status: String
        if failed == 0 && uncertain == 0 {
            status = "completed"
        } else if succeededCount > 0 {
            status = "partial"
        } else if failed == 0 {
            // A late-bound stem whose panel completed but whose files cannot be
            // attributed to individual subjects is State B, not a hard failure.
            // Preserve that distinction on the public run envelope.
            status = "uncertain"
        } else {
            status = "failed"
        }

        let hasLateBoundStem = plan.projects.contains { project in
            project.expectedArtifacts.contains { $0.filenamesLateBound == true }
        }
        let nextSafeAction: String
        if status == "completed" {
            nextSafeAction = "verify_artifacts_with_logic_audio"
        } else if hasLateBoundStem {
            nextSafeAction = "review_then_rerun_stem_export_into_clean_destination"
        } else {
            nextSafeAction = "review_then_export_resume"
        }

        return RunResult(
            schema: schema,
            runID: plan.runID,
            mode: resume ? "resume" : "run",
            confirmed: true,
            status: status,
            outputRoot: plan.outputRoot,
            collisionPolicy: plan.collisionPolicy,
            projectCount: projects.count,
            artifactsTotal: allArtifacts.count,
            artifactsVerified: verified,
            artifactsSkipped: skipped,
            artifactsUncertain: uncertain,
            artifactsFailed: failed,
            projects: projects,
            nextSafeAction: nextSafeAction
        )
    }

    static func confirmationRequiredRun(plan: ProjectExportPlan, resume: Bool) -> RunResult {
        let arts = plan.projects.map { project in
            RunProject(
                index: project.index,
                projectPath: project.projectPath,
                displayName: project.displayName,
                observedProjectPath: nil,
                identityVerified: false,
                opened: false,
                artifacts: project.expectedArtifacts.flatMap { artifact in
                    subjectScopedArtifacts(
                        RunArtifact(
                            kind: artifact.kind,
                            path: artifact.path,
                            state: "C",
                            verified: false,
                            bounceFired: false,
                            writeAttempted: false,
                            error: "confirmation_required",
                            reason: nil,
                            evidence: nil
                        ),
                        for: artifact
                    )
                }
            )
        }
        let total = arts.flatMap(\.artifacts).count
        return RunResult(
            schema: schema,
            runID: plan.runID,
            mode: resume ? "resume" : "run",
            confirmed: false,
            status: "confirmation_required",
            outputRoot: plan.outputRoot,
            collisionPolicy: plan.collisionPolicy,
            projectCount: plan.projects.count,
            artifactsTotal: total,
            artifactsVerified: 0,
            artifactsSkipped: 0,
            artifactsUncertain: 0,
            artifactsFailed: total,
            projects: arts,
            nextSafeAction: "retry_with_confirmed_true"
        )
    }

    /// `export_resume` needs a stable before-run artifact identity. Stem names
    /// are assigned by Logic after the panel export, so claiming to resume them
    /// would silently skip nothing. Refuse the whole batch before project.open
    /// so a caller cannot read a partial non-stem run as a successful resume.
    static func unsupportedStemResumeRun(plan: ProjectExportPlan) -> RunResult {
        let reason = "export_resume_unsupported_for_stem: Logic assigns stem filenames only after export, so existing artifact identity cannot be established before the run. Re-run into a clean destination."
        let projects = plan.projects.map { project in
            RunProject(
                index: project.index,
                projectPath: project.projectPath,
                displayName: project.displayName,
                observedProjectPath: nil,
                identityVerified: false,
                opened: false,
                artifacts: project.expectedArtifacts.flatMap { artifact in
                    subjectScopedArtifacts(
                        RunArtifact(
                            kind: artifact.kind,
                            path: artifact.path,
                            state: "C",
                            verified: false,
                            bounceFired: false,
                            writeAttempted: false,
                            error: reason,
                            reason: nil,
                            evidence: nil
                        ),
                        for: artifact
                    )
                }
            )
        }
        let failed = projects.flatMap(\.artifacts).count
        return RunResult(
            schema: schema,
            runID: plan.runID,
            mode: "resume",
            confirmed: true,
            status: "failed",
            outputRoot: plan.outputRoot,
            collisionPolicy: plan.collisionPolicy,
            projectCount: projects.count,
            artifactsTotal: failed,
            artifactsVerified: 0,
            artifactsSkipped: 0,
            artifactsUncertain: 0,
            artifactsFailed: failed,
            projects: projects,
            nextSafeAction: "rerun_stem_export_into_clean_destination"
        )
    }

    static func failedRun(
        runID: String,
        mode: String,
        confirmed: Bool,
        outputRoot: String,
        collisionPolicy: String,
        reason: String
    ) -> RunResult {
        RunResult(
            schema: schema,
            runID: runID,
            mode: mode,
            confirmed: confirmed,
            status: "failed",
            outputRoot: outputRoot,
            collisionPolicy: collisionPolicy,
            projectCount: 0,
            artifactsTotal: 0,
            artifactsVerified: 0,
            artifactsSkipped: 0,
            artifactsUncertain: 0,
            artifactsFailed: 0,
            projects: [],
            nextSafeAction: "fix_inputs_then_retry: \(reason)"
        )
    }
}
