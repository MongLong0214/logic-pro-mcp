@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

// These tests prove the driver state machine against a semantic fake and the
// panel-label and destination-browser paths against synthetic AX trees. They
// do NOT exercise AXSurface.openFileMenu or progress discovery in a live Logic
// process; those production Accessibility interactions remain for the user's
// live acceptance. The fake is intentionally stateful so mutations to the
// driver's observations and transitions still turn these tests red.
private final class StemPanelSurfaceFake: ProjectStemExportPanelDriver.Surface, @unchecked Sendable {
    var events: [String] = []
    var fileMenuOpens = true
    var exportMenuAvailability: ProjectStemExportPanelDriver.MenuAvailability = .available
    var stemLeafAvailability: ProjectStemExportPanelDriver.MenuAvailability = .available
    var panelAppears = true
    /// `exportPanelPresence()` reports absence for this many initial reads,
    /// then reports the configured presence. This models a panel materializing
    /// after AXPick instead of encoding an instantaneous fake-only contract.
    var absentPanelReadsBeforePresent = 0
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

    func openExportMenu() -> ProjectStemExportPanelDriver.MenuAvailability {
        events.append("export_open")
        return events.contains("file_open")
            ? exportMenuAvailability
            : .unavailable("stem_export_export_menu_unavailable")
    }

    func resolveStemLeaf() -> ProjectStemExportPanelDriver.MenuAvailability {
        events.append("leaf_enabled_read")
        // Closed-menu enablement is deliberately false in this fake. The only
        // passing route is the one that opened both parent menus first.
        return events.starts(with: ["file_open", "export_open"])
            ? stemLeafAvailability
            : .unavailable("stem_export_menu_leaf_unavailable_after_open")
    }

    func pickStemLeaf() {
        events.append("leaf_axpick")
    }

    func exportPanelPresence() -> ProjectStemExportPanelDriver.PanelPresence {
        events.append("panel_read")
        if !panelAppears { return .absent }
        if panelPresence == .present, absentPanelReadsBeforePresent > 0 {
            absentPanelReadsBeforePresent -= 1
            return .absent
        }
        return panelPresence
    }

    func destinationPopupValue() -> String? {
        let afterSelection = events.contains("destination_browser_select")
        events.append("destination_popup_read")
        return afterSelection ? destinationAfter : destinationBefore
    }

    func selectDestinationBrowserElement(
        at path: String
    ) -> ProjectStemExportPanelDriver.DestinationSelection {
        events.append("destination_browser_select")
        return browserSelectionSucceeds && path.hasSuffix("Stem Exports")
            ? .selected
            : .refused("stem_destination_component_not_listed:Stem Exports")
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
    attempts: Int = 3,
    pollIntervalNanos: UInt64 = 250_000_000
) async -> ProjectStemExportPanelDriver.Outcome {
    await ProjectStemExportPanelDriver.drive(
        destination: "/private/tmp/Stem Exports",
        surface: surface,
        progressPollAttempts: attempts,
        sleep: { _ in surface.events.append("poll_sleep") },
        pollIntervalNanos: pollIntervalNanos
    )
}

private struct StemExportPanelAXFixture {
    let runtime: AXLogicProElements.Runtime

    init(
        popupValue: String,
        exportButtonTitle: String?,
        cancelButtonTitle: String?,
        isDialog: Bool = true
    ) {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let panel = builder.element(2)
        let popup = builder.element(3)

        builder.setRole(panel, kAXWindowRole as String)
        if isDialog {
            builder.setAttribute(panel, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        }

        builder.setRole(popup, kAXPopUpButtonRole as String)
        builder.setAttribute(popup, kAXValueAttribute as String, popupValue)
        var panelChildren = [popup]

        if let exportButtonTitle {
            let export = builder.element(4)
            builder.setButton(
                export,
                title: exportButtonTitle,
                x: 100,
                y: 100,
                width: 70,
                height: 24
            )
            panelChildren.append(export)
        }
        if let cancelButtonTitle {
            let cancel = builder.element(5)
            builder.setButton(
                cancel,
                title: cancelButtonTitle,
                x: 180,
                y: 100,
                width: 70,
                height: 24
            )
            panelChildren.append(cancel)
        }

        builder.setChildren(panel, panelChildren)
        builder.setAttribute(app, kAXWindowsAttribute as String, [panel])

        runtime = builder.makeLogicRuntime(appElement: app)
    }
}

/// A Logic app whose only window is the export progress dialog, titled exactly as
/// the live Korean UI titles it. Measured 2026-09-02, its scalars are
/// `U+004C U+006F U+0067 U+0069 U+0063 U+00A0 U+0050 U+0072 U+006F` — the
/// separator is a NO-BREAK SPACE, so the title prints as "Logic Pro" but is not
/// equal to it.
private struct ProgressWindowAXFixture {
    let runtime: AXLogicProElements.Runtime

    init(windowTitle: String?) {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        var windows: [AXUIElement] = []
        if let windowTitle {
            let window = builder.element(2)
            builder.setRole(window, kAXWindowRole as String)
            builder.setAttribute(window, kAXTitleAttribute as String, windowTitle)
            windows.append(window)
        }
        builder.setAttribute(app, kAXWindowsAttribute as String, windows)
        runtime = builder.makeLogicRuntime(appElement: app)
    }
}

/// Finder-column AX fixture for the measured destination route. Each URL entry
/// is `AXList -> AXGroup -> AXTextField(AXURL)`; selecting its group can
/// materialize the next column, exactly the readback the production code needs.
private final class DestinationBrowserFixtureState: @unchecked Sendable {
    let builder: FakeAXRuntimeBuilder
    let panel: AXUIElement
    private var nextElementID = 100
    private var panelChildren: [AXUIElement]
    private var pathByGroupID: [Int: String] = [:]
    private var listIDs: Set<Int> = []
    private let childrenByPath: [String: [String]]
    private let observesSelection: Bool
    private(set) var selectedChildrenWrites: [(listID: Int, selectedGroupID: Int)] = []
    private(set) var actions: [(elementID: Int, action: String)] = []

    init(
        builder: FakeAXRuntimeBuilder,
        panel: AXUIElement,
        initialEntries: [String],
        childrenByPath: [String: [String]],
        observesSelection: Bool
    ) {
        self.builder = builder
        self.panel = panel
        self.panelChildren = AXHelpers.getChildren(panel, runtime: builder.makeAXRuntime())
        self.childrenByPath = childrenByPath
        self.observesSelection = observesSelection
        appendColumn(entries: initialEntries)
    }

    func handleWrite(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        guard attribute == (kAXSelectedChildrenAttribute as String),
              listIDs.contains(builder.elementID(element)),
              let selected = value as? [AXUIElement],
              let group = selected.first,
              let path = pathByGroupID[builder.elementID(group)] else {
            builder.setAttribute(element, attribute, value)
            return true
        }
        selectedChildrenWrites.append((builder.elementID(element), builder.elementID(group)))
        // Deliberately return success in both states. The no-readback fixture
        // models an AX status 0 that had no observed effect at all: the write is
        // accepted and then leaves no trace, so neither the selection nor a child
        // column can be read back.
        //
        // It deliberately does NOT model "the selection is recorded but the panel
        // does not navigate". That intermediate state has never been observed on
        // the live panel — measured 2026-09-02, the selection readback and the
        // destination agreed on every hop — and a fixture asserting it would be
        // asserting behaviour we cannot show exists.
        if observesSelection {
            builder.setAttribute(element, attribute, value)
            if let children = childrenByPath[path] {
                appendColumn(entries: children)
            }
        }
        return true
    }

    func recordAction(_ element: AXUIElement, _ action: String) -> Bool {
        actions.append((builder.elementID(element), action))
        return false
    }

    private func appendColumn(entries: [String]) {
        let list = builder.element(nextElementID)
        nextElementID += 1
        builder.setRole(list, kAXListRole as String)
        listIDs.insert(builder.elementID(list))
        var groups: [AXUIElement] = []
        for path in entries {
            let group = builder.element(nextElementID)
            nextElementID += 1
            let field = builder.element(nextElementID)
            nextElementID += 1
            builder.setRole(group, kAXGroupRole as String)
            builder.setRole(field, kAXTextFieldRole as String)
            // AXURL is a CFURL, never a CFString. Measured on the live export
            // panel 2026-09-02: 4 of 4 URL-bearing entries read back as NSURL and
            // 0 as String. Supplying a String here is what let a production read
            // typed `String?` — which returns nil for every real entry — pass a
            // green suite while the destination stage could not work on any
            // machine. The fixture must hand back the type the API hands back.
            builder.setAttribute(field, kAXURLAttribute as String, URL(fileURLWithPath: path) as NSURL)
            builder.setAttribute(field, kAXFilenameAttribute as String, URL(fileURLWithPath: path).lastPathComponent)
            builder.setChildren(group, [field])
            groups.append(group)
            pathByGroupID[builder.elementID(group)] = path
        }
        builder.setChildren(list, groups)
        panelChildren.append(list)
        builder.setChildren(panel, panelChildren)
    }
}

private struct DestinationBrowserAXFixture {
    let runtime: AXLogicProElements.Runtime
    let state: DestinationBrowserFixtureState

    init(
        initialEntries: [String],
        childrenByPath: [String: [String]],
        observesSelection: Bool = true
    ) {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let panel = builder.element(2)
        let popup = builder.element(3)
        let export = builder.element(4)
        let cancel = builder.element(5)
        builder.setRole(panel, kAXWindowRole as String)
        builder.setAttribute(panel, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        builder.setRole(popup, kAXPopUpButtonRole as String)
        builder.setAttribute(popup, kAXValueAttribute as String, "Other Destination")
        builder.setButton(export, title: "Export", x: 100, y: 100, width: 70, height: 24)
        builder.setButton(cancel, title: "Cancel", x: 180, y: 100, width: 70, height: 24)
        builder.setChildren(panel, [popup, export, cancel])
        builder.setAttribute(app, kAXWindowsAttribute as String, [panel])

        let state = DestinationBrowserFixtureState(
            builder: builder,
            panel: panel,
            initialEntries: initialEntries,
            childrenByPath: childrenByPath,
            observesSelection: observesSelection
        )
        self.state = state
        runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: { element, attribute, value in
                state.handleWrite(element, attribute, value)
            },
            performActionHandler: { element, action in
                state.recordAction(element, action)
            }
        )
    }
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

    @Test("a late export panel is polled through to destination selection")
    func lateExportPanelReachesDestinationStage() async throws {
        let surface = StemPanelSurfaceFake()
        surface.absentPanelReadsBeforePresent = 2

        let outcome = await driveStemPanel(surface)

        let destinationIndex = try #require(
            surface.events.firstIndex(of: "destination_browser_select")
        )
        let eventsBeforeDestination = surface.events[..<destinationIndex]
        let panelReadsBeforeDestination = eventsBeforeDestination.filter { $0 == "panel_read" }
        let panelWasPolled = panelReadsBeforeDestination.count == 3
        #expect(panelWasPolled)
        let sleepsBeforeDestination = eventsBeforeDestination.filter { $0 == "poll_sleep" }
        let pollIntervalsWereUsed = sleepsBeforeDestination.count == 2
        #expect(pollIntervalsWereUsed)
        let completed = outcome == .completed
        #expect(completed)
        let didNotRefuseOnTheInitialRead = outcome != .refused(
            "stem_export_panel_not_observed_after_axpick"
        )
        #expect(didNotRefuseOnTheInitialRead)
    }

    @Test("a panel that never appears refuses after the bounded wait")
    func missingExportPanelRefusesWithinBoundedWait() async {
        let surface = StemPanelSurfaceFake()
        surface.panelAppears = false

        let outcome = await driveStemPanel(surface)

        let refusedAfterBoundedWait = outcome == .refused(
            "stem_export_panel_not_observed_after_bounded_wait_elapsed"
        )
        #expect(refusedAfterBoundedWait)
        let panelReadCount = surface.events.filter { $0 == "panel_read" }.count
        let expectedPanelReads = Int(
            ProjectStemExportPanelDriver.exportPanelObservationDeadlineNanos / 250_000_000
        ) + 2 // initial read, one read after every poll, then close readback
        let observationStayedBounded = panelReadCount == expectedPanelReads
        #expect(observationStayedBounded)
    }

    @Test("an unavailable panel readback refuses without becoming absence")
    func unavailableExportPanelReadbackRefusesDistinctly() async {
        let surface = StemPanelSurfaceFake()
        surface.panelPresence = .unavailable

        let outcome = await driveStemPanel(surface)

        let readbackUnavailable = outcome == .refused(
            "readback_unavailable: stem_export_panel_close_not_observed"
        )
        #expect(readbackUnavailable)
        let neverBecameBoundedAbsence = outcome != .refused(
            "stem_export_panel_not_observed_after_bounded_wait_elapsed"
        )
        #expect(neverBecameBoundedAbsence)
        let panelReadCount = surface.events.filter { $0 == "panel_read" }.count
        let unavailableWasNotRetried = panelReadCount == 2 // initial read plus close readback
        #expect(unavailableWasNotRetried)
    }

    @Test("stem Export submenu resolves its measured Korean title")
    func koreanExportMenuTitleResolves() {
        let resolves = ProjectStemExportPanelDriver.exportMenuTitleMatches("내보내기")
        #expect(resolves)
    }

    @Test("stem Export submenu still resolves its measured English title")
    func englishExportMenuTitleResolves() {
        let resolves = ProjectStemExportPanelDriver.exportMenuTitleMatches("Export")
        #expect(resolves)
    }

    @Test("English stem-export panel is recognised and its measured controls operate")
    func englishStemExportPanelIsRecognised() {
        let fixture = StemExportPanelAXFixture(
            popupValue: "One File per Track",
            exportButtonTitle: "Export",
            cancelButtonTitle: "Cancel"
        )
        let surface = AXSurface(runtime: fixture.runtime)

        let recognised = surface.exportPanelPresence() == .present
        #expect(recognised)
        let oneFilePerTrackIsActive = surface.oneFilePerTrackIsActive()
        #expect(oneFilePerTrackIsActive)
        let exportPressed = surface.pressExport()
        #expect(exportPressed)
        let cancelPressed = surface.closeExportPanel()
        #expect(cancelPressed)
    }

    @Test("Korean stem-export panel is recognised and its measured controls operate")
    func koreanStemExportPanelIsRecognised() {
        let fixture = StemExportPanelAXFixture(
            popupValue: "트랙당 하나의 파일",
            exportButtonTitle: "내보내기",
            cancelButtonTitle: "취소"
        )
        let surface = AXSurface(runtime: fixture.runtime)

        let recognised = surface.exportPanelPresence() == .present
        #expect(recognised)
        let oneFilePerTrackIsActive = surface.oneFilePerTrackIsActive()
        #expect(oneFilePerTrackIsActive)
        let exportPressed = surface.pressExport()
        #expect(exportPressed)
        let cancelPressed = surface.closeExportPanel()
        #expect(cancelPressed)
    }

    @Test("destination browser writes AXSelectedChildren for a URL-backed one-level entry")
    func destinationBrowserSelectsURLTextFieldThroughOwningList() {
        let destination = "/Users/fixture/Exports"
        let fixture = DestinationBrowserAXFixture(
            initialEntries: [destination],
            childrenByPath: [destination: ["\(destination)/Rendered"]]
        )
        let result = AXSurface(runtime: fixture.runtime)
            .selectDestinationBrowserElement(at: destination)

        let selected = result == .selected
        #expect(selected)
        let wroteOwningList = fixture.state.selectedChildrenWrites.count == 1
        #expect(wroteOwningList)
        let selectedEntryGroup = fixture.state.selectedChildrenWrites.first?.selectedGroupID != nil
        #expect(selectedEntryGroup)
        let neverPressedEntry = fixture.state.actions.isEmpty
        #expect(neverPressedEntry)
    }

    @Test("destination browser descends URL-backed components one at a time")
    func destinationBrowserDescendsMultipleComponents() {
        let first = "/Users/fixture/Exports"
        let destination = "\(first)/Mixes"
        let fixture = DestinationBrowserAXFixture(
            initialEntries: [first],
            childrenByPath: [
                first: [destination],
                destination: ["\(destination)/Rendered"],
            ]
        )
        let result = AXSurface(runtime: fixture.runtime)
            .selectDestinationBrowserElement(at: destination)

        let selected = result == .selected
        #expect(selected)
        let wroteEachComponent = fixture.state.selectedChildrenWrites.count == 2
        #expect(wroteEachComponent)
    }

    @Test("destination browser refuses with the component that is never listed")
    func destinationBrowserNamesUnresolvedComponent() {
        let fixture = DestinationBrowserAXFixture(
            initialEntries: ["/Users/fixture/Exports"],
            childrenByPath: [:]
        )
        let result = AXSurface(runtime: fixture.runtime)
            .selectDestinationBrowserElement(at: "/Users/fixture/Missing")

        guard case let .refused(reason) = result else {
            Issue.record("an unlisted destination component was accepted")
            return
        }
        let namesMissingComponent = reason.contains("Missing")
        #expect(namesMissingComponent)
    }

    @Test("destination browser refuses a status-zero write without navigation readback")
    func destinationBrowserRequiresObservedWriteEffect() {
        let destination = "/Users/fixture/Exports"
        let fixture = DestinationBrowserAXFixture(
            initialEntries: [destination],
            childrenByPath: [destination: ["\(destination)/Rendered"]],
            observesSelection: false
        )
        let result = AXSurface(runtime: fixture.runtime)
            .selectDestinationBrowserElement(at: destination)

        guard case let .refused(reason) = result else {
            Issue.record("a status-zero write with no readback was accepted")
            return
        }
        let writeWasAttempted = fixture.state.selectedChildrenWrites.count == 1
        #expect(writeWasAttempted)
        let refusalRequiresReadback = reason.contains("not_confirmed:Exports")
        #expect(refusalRequiresReadback)
    }

    @Test("the export progress dialog is recognised through its NO-BREAK SPACE title")
    func progressWindowTitleUsesNoBreakSpace() {
        // The exact live title, written as scalars so the NBSP cannot be lost to
        // an editor or a copy-paste that silently normalises it.
        let liveTitle = "Logic\u{00A0}Pro"
        let looksIdenticalButIsNotEqual = liveTitle != "Logic Pro"
        #expect(looksIdenticalButIsNotEqual)

        let observed = AXSurface(runtime: ProgressWindowAXFixture(windowTitle: liveTitle).runtime)
            .progressWindowPresent()
        #expect(observed)

        let ordinarySpace = AXSurface(runtime: ProgressWindowAXFixture(windowTitle: "Logic Pro").runtime)
            .progressWindowPresent()
        #expect(ordinarySpace)
    }

    @Test("a window that is not the progress dialog is not mistaken for it")
    func progressWindowRejectsOtherTitles() {
        // The separator may localise, but it must still BE a separator: a title
        // with the space removed is a different product string, not this dialog.
        let noSeparator = AXSurface(runtime: ProgressWindowAXFixture(windowTitle: "LogicPro").runtime)
            .progressWindowPresent()
        let rejectsRemovedSeparator = !noSeparator
        #expect(rejectsRemovedSeparator)

        let project = AXSurface(runtime: ProgressWindowAXFixture(windowTitle: "lpm-606-warm - 트랙").runtime)
            .progressWindowPresent()
        let rejectsProjectWindow = !project
        #expect(rejectsProjectWindow)

        let none = AXSurface(runtime: ProgressWindowAXFixture(windowTitle: nil).runtime)
            .progressWindowPresent()
        let rejectsNoWindows = !none
        #expect(rejectsNoWindows)
    }

    @Test("destination browser refuses duplicate URL entries rather than using traversal order")
    func destinationBrowserRefusesDuplicateURL() {
        let destination = "/Users/fixture/Exports"
        let fixture = DestinationBrowserAXFixture(
            initialEntries: [destination, destination],
            childrenByPath: [destination: ["\(destination)/Rendered"]]
        )
        let result = AXSurface(runtime: fixture.runtime)
            .selectDestinationBrowserElement(at: destination)

        guard case let .refused(reason) = result else {
            Issue.record("a duplicate URL entry was accepted using traversal order")
            return
        }
        let duplicateWasNamed = reason.contains("ambiguous:Exports")
        #expect(duplicateWasNamed)
        let wroteNothing = fixture.state.selectedChildrenWrites.isEmpty
        #expect(wroteNothing)
    }

    @Test("a Cancel-only decoy is not recognised as a stem-export panel")
    func cancelOnlyDecoyIsNotRecognised() {
        let fixture = StemExportPanelAXFixture(
            popupValue: "One File per Track",
            exportButtonTitle: nil,
            cancelButtonTitle: "Cancel"
        )
        let surface = AXSurface(runtime: fixture.runtime)

        let decoyIsAbsent = surface.exportPanelPresence() == .absent
        #expect(decoyIsAbsent)
        let exportWasNotPressed = !surface.pressExport()
        #expect(exportWasNotPressed)
    }

    @Test("an unmeasured stem-export panel refuses with the missing-measurement reason")
    func unmeasuredStemExportPanelRefuses() async {
        // Deliberately synthetic AX labels: neither is claimed as a Logic
        // translation, so the fixture models a locale awaiting measurement.
        let fixture = StemExportPanelAXFixture(
            popupValue: "未測定のトラック別ファイル",
            exportButtonTitle: "未測定の書き出し",
            cancelButtonTitle: "未測定の取り消し"
        )
        let panelPresence = AXSurface(runtime: fixture.runtime).exportPanelPresence()
        let namesMissingMeasurement = panelPresence == .unmeasured(
            ProjectStemExportPanelDriver.panelLabelNotMeasuredReason
        )
        #expect(namesMissingMeasurement)

        let surface = StemPanelSurfaceFake()
        surface.panelPresence = panelPresence
        let outcome = await driveStemPanel(surface)
        let refusedForMissingMeasurement = outcome == .refused(
            ProjectStemExportPanelDriver.panelLabelNotMeasuredReason
        )
        #expect(refusedForMissingMeasurement)
    }

    @Test("Korean all-tracks audio-file leaf resolves")
    func koreanAllTracksStemLeafResolves() {
        let resolves = ProjectStemExportPanelDriver.stemLeafTitleMatches("모든 트랙을 오디오 파일로…")
        #expect(resolves)
    }

    @Test("Korean selection-rewritten single-track audio-file leaf is rejected")
    func koreanSingleTrackStemLeafIsRejected() {
        let resolves = ProjectStemExportPanelDriver.stemLeafTitleMatches("1개의 트랙을 오디오 파일로…")
        #expect(!resolves)
    }

    @Test("Korean selection-range audio-file leaf is rejected")
    func koreanSelectionRangeStemLeafIsRejected() {
        let resolves = ProjectStemExportPanelDriver.stemLeafTitleMatches("선택 범위를 오디오 파일로…")
        #expect(!resolves)
    }

    @Test("unmeasured stem-export labels refuse instead of falling back to a guess")
    func unmeasuredLocaleStemMenuRefuses() async {
        // A synthetic Japanese-script AX title, deliberately NOT offered as a
        // Logic translation or a policy variant: this leaf has no Japanese
        // measurement, so it must remain an unrecognized title.
        let unmatchedTitle = "未測定ロケールのオーディオ書き出し"
        let titleMatches = ProjectStemExportPanelDriver.stemLeafTitleMatches(unmatchedTitle)
        #expect(!titleMatches)

        let surface = StemPanelSurfaceFake()
        surface.stemLeafAvailability = .unavailable(
            ProjectStemExportPanelDriver.stemLeafLabelNotMeasuredReason
        )
        let outcome = await driveStemPanel(surface)
        let refusalNamesMeasurement = outcome == .refused(
            ProjectStemExportPanelDriver.stemLeafLabelNotMeasuredReason
        )
        #expect(refusalNamesMeasurement)
        let leafWasNotPicked = !surface.events.contains("leaf_axpick")
        #expect(leafWasNotPicked)
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
