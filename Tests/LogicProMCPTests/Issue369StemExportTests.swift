import Foundation
import MCP
import Testing
@testable import LogicProMCP

// These tests prove the driver state machine against a semantic fake only.
// They do NOT exercise AXSurface.openFileMenu, AX browser traversal, AX
// progress discovery, or AX Cancel in a live Logic process; those production
// Accessibility interactions remain for the user's live acceptance. The fake
// is intentionally stateful so mutations to the driver's observations and
// transitions still turn these tests red.
private final class StemPanelSurfaceFake: ProjectStemExportPanelDriver.Surface, @unchecked Sendable {
    var events: [String] = []
    var fileMenuOpens = true
    var exportMenuOpens = true
    var leafResolves = true
    var panelAppears = true
    var browserSelectionSucceeds = true
    var destinationBefore: String? = "Old Exports"
    var destinationAfter: String? = "Stem Exports"
    var perTrackActive = true
    var exportPressSucceeds = true
    var progressStates: [Bool] = [true, false]
    var panelPresence: ProjectStemExportPanelDriver.PanelPresence = .present
    var closeChangesPanelPresence = true

    func openFileMenu() -> Bool {
        events.append("file_open")
        return fileMenuOpens
    }

    func openExportMenu() -> Bool {
        events.append("export_open")
        return exportMenuOpens && events.contains("file_open")
    }

    func resolveStemLeaf() -> Bool {
        events.append("leaf_enabled_read")
        // Closed-menu enablement is deliberately false in this fake. The only
        // passing route is the one that opened both parent menus first.
        return leafResolves && events.starts(with: ["file_open", "export_open"])
    }

    func pickStemLeaf() {
        events.append("leaf_axpick")
    }

    func exportPanelPresence() -> ProjectStemExportPanelDriver.PanelPresence {
        events.append("panel_read")
        if !panelAppears { return .absent }
        return panelPresence
    }

    func destinationPopupValue() -> String? {
        let afterSelection = events.contains("destination_browser_select")
        events.append("destination_popup_read")
        return afterSelection ? destinationAfter : destinationBefore
    }

    func selectDestinationBrowserElement(at path: String) -> Bool {
        events.append("destination_browser_select")
        return browserSelectionSucceeds && path.hasSuffix("Stem Exports")
    }

    func oneFilePerTrackIsActive() -> Bool {
        events.append("per_track_read")
        return perTrackActive
    }

    func pressExport() -> Bool {
        events.append("export_press")
        return exportPressSucceeds
    }

    func progressWindowPresent() -> Bool {
        events.append("progress_read")
        guard !progressStates.isEmpty else { return false }
        return progressStates.removeFirst()
    }

    func closeExportPanel() -> Bool {
        events.append("panel_close")
        if closeChangesPanelPresence, panelPresence == .present {
            panelPresence = .absent
        }
        return true
    }
}

private func driveStemPanel(
    _ surface: StemPanelSurfaceFake,
    attempts: Int = 3
) async -> ProjectStemExportPanelDriver.Outcome {
    await ProjectStemExportPanelDriver.drive(
        destination: "/private/tmp/Stem Exports",
        surface: surface,
        progressPollAttempts: attempts,
        sleep: { _ in },
        pollIntervalNanos: 1
    )
}

private func scannedStemSubjects(for project: URL) -> ProjectExportStemSubjectInventory {
    .scanned(
        projectPath: project.path,
        subjects: [
            ProjectExportStemSubject(index: 0, name: "Studio Grand"),
            ProjectExportStemSubject(index: 1, name: "Bass / DI"),
        ]
    )
}

private final class ReadableThenUnreadableStemDirectoryFileManager: FileManager {
    private let destination: String
    private let readableEnumerations: Int
    private var enumerationCount = 0

    init(destination: String, readableEnumerations: Int) {
        self.destination = destination
        self.readableEnumerations = readableEnumerations
        super.init()
    }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        guard path == destination else {
            return try super.contentsOfDirectory(atPath: path)
        }
        enumerationCount += 1
        guard enumerationCount <= readableEnumerations else {
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.contentsOfDirectory(atPath: path)
    }
}

@Suite("#369 late-bound stem plan and export-panel drive")
struct Issue369StemExportTests {
    // A fake whose leaf answers disabled until its menus are open. macOS validates
    // menu items on open, so a drive that reads before opening sees every export item
    // unavailable — measured live, the same items read false closed and true open.
    // proves the causal ordering rather than merely observing a success.
    @Test("opens parent menus before reading stem leaf enablement")
    func menuOpenPrecedesEnablementRead() async throws {
        let surface = StemPanelSurfaceFake()
        let outcome = await driveStemPanel(surface)

        let completed = outcome == .completed
        #expect(completed)
        let readIndex = try #require(surface.events.firstIndex(of: "leaf_enabled_read"))
        let fileIndex = try #require(surface.events.firstIndex(of: "file_open"))
        let exportIndex = try #require(surface.events.firstIndex(of: "export_open"))
        let openingPrecedesRead = [fileIndex, exportIndex].allSatisfy {
            $0 < readIndex
        }
        #expect(openingPrecedesRead)
    }

    // Logic REWRITES the leaf title with the selection — `Tracks as Audio Files…`
    // became `1 Track as Audio File…` live. Resolution must survive a title the app
    // edits, not only one it localizes, so it cannot key on the whole string. The structural
    // route predicate; exact canonical title matching would make this red.
    @Test("resolves Logic's selection-rewritten per-track export title")
    func rewrittenStemLeafTitleResolves() {
        let rewritten = ProjectStemExportPanelDriver.stemLeafTitleMatches("1 Track as Audio File…")
        #expect(rewritten)
        let unrelated = ProjectStemExportPanelDriver.stemLeafTitleMatches("Project as Audio File…")
        #expect(!unrelated)
    }

    // Typing a destination path DISMISSES the panel — reproduced twice live with
    // nothing written — so the folder is chosen as a browser element and the
    // destination popup re-read. No observed popup change means no Export press, State C with
    // write_attempted false, even though the browser action reported success.
    @Test("unchanged destination popup refuses before export")
    func unchangedDestinationRefusesWithoutWrite() async {
        let surface = StemPanelSurfaceFake()
        surface.destinationAfter = surface.destinationBefore
        let outcome = await driveStemPanel(surface)

        let refused = outcome == .refused("stem_destination_not_confirmed_after_browser_selection")
        #expect(refused)
        let exportWasNotPressed = !surface.events.contains("export_press")
        #expect(exportWasNotPressed)
        let panelClosed = surface.panelPresence == .absent
        #expect(panelClosed)
    }

    @Test("uses AXPick for the export-menu leaf")
    func leafUsesAXPick() async {
        let surface = StemPanelSurfaceFake()
        _ = await driveStemPanel(surface)

        let picked = surface.events.contains("leaf_axpick")
        #expect(picked)
        let usesAXPick = ProjectStemExportPanelDriver.stemLeafPickAction == "AXPick"
        #expect(usesAXPick)
    }

    @Test("confirmed browser destination precedes Export")
    func confirmedBrowserDestinationPrecedesExport() async throws {
        let surface = StemPanelSurfaceFake()
        _ = await driveStemPanel(surface)

        let selected = try #require(surface.events.firstIndex(of: "destination_browser_select"))
        let export = try #require(surface.events.firstIndex(of: "export_press"))
        let selectionPrecedesExport = selected < export
        #expect(selectionPrecedesExport)
    }

    @Test("missing One File per Track refuses before Export")
    func missingOneFilePerTrackRefuses() async {
        let surface = StemPanelSurfaceFake()
        surface.perTrackActive = false
        let outcome = await driveStemPanel(surface)

        let refused = outcome == .refused("stem_one_file_per_track_not_active")
        #expect(refused)
        let noExport = !surface.events.contains("export_press")
        #expect(noExport)
    }

    @Test("stuck progress window is State B, never successful completion")
    func stuckProgressIsUncertain() async {
        let surface = StemPanelSurfaceFake()
        surface.progressStates = [true, true, true]
        let outcome = await driveStemPanel(surface, attempts: 3)

        let uncertain = outcome == .uncertain("stem_progress_window_did_not_disappear_within_budget")
        #expect(uncertain)
    }

    @Test("unseen progress window is State B, not click-return success")
    func unseenProgressIsUncertain() async {
        let surface = StemPanelSurfaceFake()
        surface.progressStates = [false, false, false]
        let outcome = await driveStemPanel(surface, attempts: 3)

        let uncertain = outcome == .uncertain("readback_unavailable: stem_progress_window_not_observed")
        #expect(uncertain)
    }

    @Test("panel refusal becomes State C with write_attempted false")
    func panelRefusalMapsToStateC() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Stem Panel Refusal")
        let router = await makeExportRouter()
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _ in .refused("stem_destination_not_confirmed_after_browser_selection") }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: router,
            resume: false,
            options: options,
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifact = try #require(run.projects.first?.artifacts.first)
        let stateC = artifact.state == "C"
        #expect(stateC)
        let writeWasNotAttempted = !artifact.writeAttempted
        #expect(writeWasNotAttempted)
        #expect(artifact.error == "stem_destination_not_confirmed_after_browser_selection")
    }

    @Test("every panel refusal attempts to close the panel")
    func refusalClosesPanel() async {
        let surface = StemPanelSurfaceFake()
        surface.fileMenuOpens = false
        let outcome = await driveStemPanel(surface)

        let refused = outcome == .refused("stem_export_file_menu_unavailable")
        #expect(refused)
        let closed = surface.panelPresence == .absent
        #expect(closed)
    }

    @Test("a Cancel press that leaves the panel present refuses instead of claiming closure")
    func closeReadbackMustObserveAbsence() async {
        let surface = StemPanelSurfaceFake()
        surface.fileMenuOpens = false
        surface.closeChangesPanelPresence = false

        let outcome = await driveStemPanel(surface)

        let refused = outcome == .refused("stem_export_panel_remained_open_after_close_attempt")
        #expect(refused)
        let panelStillPresent = surface.panelPresence == .present
        #expect(panelStillPresent)
    }

    @Test("unavailable close readback refuses rather than assuming the panel closed")
    func closeReadbackUnavailableRefuses() async {
        let surface = StemPanelSurfaceFake()
        surface.fileMenuOpens = false
        surface.closeChangesPanelPresence = false
        surface.panelPresence = .unavailable

        let outcome = await driveStemPanel(surface)

        let refused = outcome == .refused("readback_unavailable: stem_export_panel_close_not_observed")
        #expect(refused)
    }

    @Test("silent late-bound stem is State B after analyzer verification")
    func silentStemFailsVerification() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Stem Silence")
        let output = outputRoot.appendingPathComponent("opaque-silent.wav")
        let router = await makeExportRouter()
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _ in
            _ = try? writeSilentWav(at: output)
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: router,
            resume: false,
            options: options,
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifacts = try #require(run.projects.first?.artifacts)
        let oneResultPerSubject = artifacts.count == 2
        #expect(oneResultPerSubject)
        let unverified = artifacts.allSatisfy { $0.state == "B" && !$0.verified }
        #expect(unverified)
        let observation = try #require(artifacts.first?.observedStemOutputs?.first)
        let silenceWasObserved = (observation.reason ?? "").contains("near_silent_output")
        #expect(silenceWasObserved)
        let countMismatch = try #require(artifacts.first?.reason).contains("observed=1 expected=2")
        #expect(countMismatch)
        let notCompleted = run.status != "completed"
        #expect(notCompleted)
    }

    @Test("an empty scanned subject list is refused before a stem plan is published")
    func emptyStemSubjectsAreRefused() throws {
        let project = try makeExportPlannerProject(named: "Empty Stem Subjects")
        let outputRoot = try makeExportPlannerDirectory()
        var failure: String?

        do {
            _ = try ProjectExportPlanner.plan(
                params: [
                    "project": .string(project.path),
                    "output_root": .string(outputRoot.path),
                    "artifact": .string("stem"),
                ],
                stemSubjects: .scanned(projectPath: project.path, subjects: [])
            )
        } catch {
            failure = String(describing: error)
        }

        let refusal = try #require(failure)
        let emptySubjectReason = refusal.contains("stem_subject_list_empty")
        #expect(emptySubjectReason)
    }

    @Test("an existing directory absent from the export browser is refused before writing")
    func browserUnreachableStemDestinationRefusesAtExecution() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Browser Unreachable")
        let subjects = scannedStemSubjects(for: project)
        let plan = try ProjectExportPlanner.plan(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
            ],
            stemSubjects: subjects
        )
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _ in .refused("stem_destination_browser_selection_failed") }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: options,
            stemSubjects: subjects
        )

        #expect(plan.status == "planned")
        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        let allRefusedBeforeWrite = artifacts.allSatisfy {
            $0.state == "C" && !$0.writeAttempted && $0.error == "stem_destination_browser_selection_failed"
        }
        #expect(allRefusedBeforeWrite)
    }

    @Test("the immediately-pre-export collision snapshot is authoritative")
    func stemCollisionAppearingAfterPreflightPreventsPanelDrive() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Concurrent Collision")
        let collision = outputRoot.appendingPathComponent("writer-race.wav")
        let panelReached = BoolFlag()
        let router = await makeExportRouter(openSideEffect: {
            try? Data("other writer".utf8).write(to: collision)
        })
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _ in
            panelReached.set()
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: router,
            resume: false,
            options: options,
            stemSubjects: scannedStemSubjects(for: project)
        )

        #expect(!panelReached.isSet)
        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        let authoritativeRefusal = artifacts.allSatisfy {
            $0.state == "C" && ($0.error ?? "").contains("authoritative immediately-pre-export")
        }
        #expect(authoritativeRefusal)
    }

    @Test("a post-snapshot destination entry remains an unattributed State B observation")
    func postSnapshotEntryIsNotClaimedAsProduced() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Concurrent Observation")
        let concurrentEntry = outputRoot.appendingPathComponent("concurrent.wav")
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _ in
            _ = try? writeToneWav(at: concurrentEntry)
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: options,
            stemSubjects: scannedStemSubjects(for: project)
        )

        #expect(run.status == "uncertain")
        let artifact = try #require(run.projects.first?.artifacts.first)
        #expect(artifact.state == "B")
        let concurrencyCaveat = try #require(artifact.reason).contains("may have been created concurrently")
        #expect(concurrencyCaveat)
        let observation = try #require(artifact.observedStemOutputs?.first)
        #expect(observation.path == concurrentEntry.path)
    }

    @Test("stem plan publishes late-bound destination and live subjects")
    func stemPlanIsLateBound() throws {
        let project = try makeExportPlannerProject(named: "Stem Plan")
        let outputRoot = try makeExportPlannerDirectory()
        let plan = try ProjectExportPlanner.plan(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
            ],
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifact = try #require(plan.projects.first?.expectedArtifacts.first)
        let lateBound = artifact.filenamesLateBound == true
        #expect(lateBound)
        #expect(artifact.destination == outputRoot.path)
        let subjects = try #require(artifact.subjects)
        #expect(subjects.map(\.index) == [0, 1])
        #expect(subjects.map(\.name) == ["Studio Grand", "Bass / DI"])
        let noFilenamePromise = !artifact.path.hasSuffix(".wav")
        #expect(noFilenamePromise)
    }

    @Test("fail_if_exists refuses a stem destination containing audio")
    func failIfExistsRefusesExistingDestinationAudio() throws {
        let project = try makeExportPlannerProject(named: "Stem Collision")
        let outputRoot = try makeExportPlannerDirectory()
        try Data("old audio".utf8).write(to: outputRoot.appendingPathComponent("old.aif"))
        let plan = try ProjectExportPlanner.plan(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
            ],
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifact = try #require(plan.projects.first?.expectedArtifacts.first)
        let degraded = plan.status == "degraded"
        #expect(degraded)
        let blocked = artifact.verification.issues.contains("stem_destination_contains_audio")
        #expect(blocked)
        let reason = try #require(artifact.planningReason)
        let reasonExplainsWhy = reason.contains("filenames are late-bound")
        #expect(reasonExplainsWhy)
    }

    @Test("stem collision rule is top-level suffix-qualified entries, not parsed audio")
    func stemCollisionRuleIsExplicitAndShared() throws {
        let project = try makeExportPlannerProject(named: "Stem Entry Rule")
        let outputRoot = try makeExportPlannerDirectory()
        try Data("plain text with wav suffix".utf8).write(to: outputRoot.appendingPathComponent("blocks.wav"))
        try Data("not eligible".utf8).write(to: outputRoot.appendingPathComponent("ignored.flac"))
        let nested = outputRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("nested should be ignored".utf8).write(to: nested.appendingPathComponent("nested.aif"))

        let plan = try ProjectExportPlanner.plan(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
            ],
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifact = try #require(plan.projects.first?.expectedArtifacts.first)
        let exactlyOneEligibleEntry = artifact.verification.existingAudioFileCount == 1
        #expect(exactlyOneEligibleEntry)
        let blocked = artifact.verification.issues.contains("stem_destination_contains_audio")
        #expect(blocked)
        let rule = artifact.analysis["eligible_output_rule"]
        let publishedRule = rule == "top-level non-directory entry with suffix wav|wave|aif|aiff|aifc|m4a|mp3"
        #expect(publishedRule)
    }

    @Test("unreadable stem destination is refused instead of treated as empty")
    func unreadableStemDestinationRefuses() throws {
        let project = try makeExportPlannerProject(named: "Stem Unreadable")
        let outputRoot = try makeExportPlannerDirectory()
        let fileManager = UnreadableDirectoryFileManager(unreadablePath: outputRoot.path)

        var failure: String?
        do {
            _ = try ProjectExportPlanner.plan(
                params: [
                    "project": .string(project.path),
                    "output_root": .string(outputRoot.path),
                    "artifact": .string("stem"),
                ],
                fileManager: fileManager,
                stemSubjects: scannedStemSubjects(for: project)
            )
        } catch {
            failure = String(describing: error)
        }

        let refusal = try #require(failure)
        let refusesUnreadableDestination = refusal.contains("stem_destination_unreadable")
        #expect(refusesUnreadableDestination)
    }

    @Test("stem plans refuse unavailable subjects and batch projects rather than degrading")
    func stemPlanRefusesUnsupportedReach() throws {
        let project = try makeExportPlannerProject(named: "Stem Reach")
        let secondProject = try makeExportPlannerProject(named: "Stem Reach Second")
        let outputRoot = try makeExportPlannerDirectory()

        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
            ])
        }
        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(
                params: [
                    "projects": .array([.string(project.path), .string(secondProject.path)]),
                    "output_root": .string(outputRoot.path),
                    "artifact": .string("stem"),
                ],
                stemSubjects: scannedStemSubjects(for: project)
            )
        }
    }

    @Test("stem results retain observed analyzer evidence without inventing track bindings")
    func stemResultsArePerSubjectAndUnbound() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Stem Unbound")
        let first = outputRoot.appendingPathComponent("opaque-first.wav")
        let second = outputRoot.appendingPathComponent("opaque-second.wav")
        let router = await makeExportRouter()
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _ in
            _ = try? writeToneWav(at: first)
            _ = try? writeToneWav(at: second)
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: router,
            resume: false,
            options: options,
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifacts = try #require(run.projects.first?.artifacts)
        let oneResultPerPopulatedTrack = artifacts.count == 2
        #expect(oneResultPerPopulatedTrack)
        let subjectsAreExplicit = artifacts.compactMap(\.subject).map(\.index) == [0, 1]
        #expect(subjectsAreExplicit)
        let allRemainUnbound = artifacts.allSatisfy {
            $0.state == "B" && ($0.reason ?? "").contains("file_binding_unestablished")
        }
        #expect(allRemainUnbound)
        let observations = try #require(artifacts.first?.observedStemOutputs)
        let bothOutputsObservedAfterExport = observations.map(\.path) == [first.path, second.path]
        #expect(bothOutputsObservedAfterExport)
        let observationsVerified = observations.allSatisfy(\.verified)
        #expect(observationsVerified)
        let runNeverClaimsCompleted = run.status != "completed"
        #expect(runNeverClaimsCompleted)
    }

    @Test("pre-existing stem audio produces one refusal per populated subject")
    func preexistingStemAudioRetainsSubjectCardinality() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Scoped Collision")
        try Data("old".utf8).write(to: outputRoot.appendingPathComponent("old.aif"))

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: fastOptions(identity: { project.path }),
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        let scopedFailures = artifacts.allSatisfy {
            $0.state == "C" && $0.subject != nil && ($0.error ?? "").contains("overwrite_blocked")
        }
        #expect(scopedFailures)
    }

    @Test("confirmation-required stem runs retain one result per populated subject")
    func confirmationRequiredStemRetainsSubjectCardinality() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Scoped Confirmation")

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: fastOptions(identity: { project.path }),
            stemSubjects: scannedStemSubjects(for: project)
        )

        #expect(run.status == "confirmation_required")
        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        let scopedConfirmation = artifacts.allSatisfy {
            $0.subject != nil && $0.error == "confirmation_required" && !$0.writeAttempted
        }
        #expect(scopedConfirmation)
    }

    @Test("a destination that becomes unreadable after planning refuses every subject")
    func stemReadabilityTransitionRetainsSubjectCardinality() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Readability Transition")
        let fileManager = ReadableThenUnreadableStemDirectoryFileManager(
            destination: outputRoot.path,
            readableEnumerations: 2
        )
        let panelReached = BoolFlag()
        var options = fastOptions(identity: { project.path })
        options.fileManager = fileManager
        options.driveStemExport = { _ in
            panelReached.set()
            return .completed
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            resume: false,
            options: options,
            stemSubjects: scannedStemSubjects(for: project)
        )

        #expect(!panelReached.isSet)
        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        let unreadableRefusals = artifacts.allSatisfy {
            $0.subject != nil && ($0.error ?? "").contains("overwrite_check_unavailable")
        }
        #expect(unreadableRefusals)
    }

    @Test("skip_existing refuses the stem plan instead of returning a degraded manifest")
    func skipExistingStemRefused() throws {
        let project = try makeExportPlannerProject(named: "Stem Skip")
        let outputRoot = try makeExportPlannerDirectory()
        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(
                params: [
                    "project": .string(project.path),
                    "output_root": .string(outputRoot.path),
                    "artifact": .string("stem"),
                    "collision_policy": .string("skip_existing"),
                ],
                stemSubjects: scannedStemSubjects(for: project)
            )
        }
    }

    @Test("export_resume refuses stems before opening a project")
    func stemResumeRefused() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Stem Resume")
        let router = await makeExportRouter()
        let run = await ProjectExportExecutor.run(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: router,
            resume: true,
            options: fastOptions(identity: { project.path }),
            stemSubjects: scannedStemSubjects(for: project)
        )

        let artifacts = try #require(run.projects.first?.artifacts)
        #expect(artifacts.count == 2)
        let allAreScopedRefusals = artifacts.allSatisfy {
            $0.state == "C" && $0.subject != nil && !$0.writeAttempted
                && ($0.error ?? "").contains("filenames only after export")
        }
        #expect(allAreScopedRefusals)
    }
}
