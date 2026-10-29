@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #448 — a sort is only State A when the post-write arrangement order is the
/// requested criterion's expected order. A changed order alone proves nothing:
/// another sort criterion also changes track order.

private actor TrackSortStateBChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    private(set) var calls: [(operation: String, params: [String: String])] = []
    private let result: ChannelResult
    private let runtime: AXLogicProElements.Runtime?

    init(result: ChannelResult = .success(HonestContract.encodeStateB(
        reason: .readbackMismatch,
        extras: ["operation": "track.sort_verified"]
    )), runtime: AXLogicProElements.Runtime? = nil) {
        self.result = result
        self.runtime = runtime
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        calls.append((operation, params))
        if let runtime, operation == "track.sort_verified" {
            return AccessibilityChannel.defaultSortTracks(params: params, runtime: runtime)
        }
        if let runtime, operation == "view.set_mixer_visibility" {
            return await AccessibilityChannel.defaultSetMixerVisibility(params: params, runtime: runtime)
        }
        return result
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "#448 track-sort State-B probe")
    }
}

private final class TrackSortActionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var postPressRailReadCount = 0
    private var enabledReadCallbacks = 0
    private var helpReads = 0
    var viewEvents: [String] = []
    var actionOrder: [String] = []
    var mixerShowing = false

    func recordHelpRead() { lock.lock(); helpReads += 1; lock.unlock() }
    var helpReadCount: Int { lock.lock(); defer { lock.unlock() }; return helpReads }

    func recordEnabledReadCallback() {
        lock.lock()
        enabledReadCallbacks += 1
        lock.unlock()
    }

    var enabledReadCallbackCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return enabledReadCallbacks
    }

    func recordPress() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var pressCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func nextPostPressRailRead() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = postPressRailReadCount
        postPressRailReadCount += 1
        return current
    }
}

private let trackNameActuation = TrackSortVerifier.ActuatedMenuItem(
    localizedLabel: "트랙 이름",
    criterion: .trackName
)

// Construction precedes child execution; parent reads follow await child.value. Counters use their own lock.
// Builder access is sequential in these tests; no production AX reference is captured here.
private struct TrackSortAXFixture: @unchecked Sendable {
    let builder: FakeAXRuntimeBuilder
    let app: AXUIElement
    let runtime: AXLogicProElements.Runtime
    let expectedOrderJSON: String
    let actionProbe: TrackSortActionProbe
    let arrangeWindow: AXUIElement
    let headerRail: AXUIElement
    let initialHeaders: [AXUIElement]
    let initialNames: [String]

    init(
        orderAfterPress: [Int],
        expectedReferenceOrder: [Int]? = nil,
        names: [String] = ["Kick", "Bass", "Piano"],
        observedNames: [String]? = nil,
        namesAfterPress: [String]? = nil,
        pressReturnsSuccess: Bool = true,
        collapsedStackAt: Int? = nil,
        railUnreadableAfterPress: Bool = false,
        postPressOrders: [[Int]]? = nil,
        windowsReadStatus: AXHelpers.AXStatusError? = nil,
        railRoleReadStatus: AXHelpers.AXStatusError? = nil,
        menuEnabledReadStatus: AXHelpers.AXStatusError? = nil,
        onMenuEnabledRead: (@Sendable () -> Void)? = nil,
        includingMixerView: Bool = false
    ) {
        precondition(!names.isEmpty)
        let builder = FakeAXRuntimeBuilder()
        self.builder = builder
        let probe = TrackSortActionProbe()
        actionProbe = probe
        let app = builder.element(448_000)
        self.app = app
        let arrange = builder.element(448_001)
        arrangeWindow = arrange
        let rail = builder.element(448_002)
        let menuBar = builder.element(448_003)
        let file = builder.element(448_004)
        let edit = builder.element(448_005)
        let track = builder.element(448_006)
        let sortBy = builder.element(448_007)
        let sortByName = builder.element(448_008)
        let sortByCreation = builder.element(448_009)
        let view = builder.element(448_010), mixerToggle = builder.element(448_011), mixer = builder.element(448_012)

        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXFocusedWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setChildren(arrange, [rail])
        builder.setAttribute(rail, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(rail, kAXDescriptionAttribute as String, "Track Headers")

        let headers = names.indices.map { offset -> AXUIElement in
            let header = builder.element(448_100 + offset)
            builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            builder.setAttribute(header, kAXTitleAttribute as String, observedNames?[offset] ?? names[offset])
            builder.setAttribute(header, kAXSelectedAttribute as String, false)
            if collapsedStackAt == offset {
                let disclosure = builder.element(448_200 + offset)
                builder.setAttribute(disclosure, kAXRoleAttribute as String, kAXDisclosureTriangleRole as String)
                builder.setAttribute(disclosure, kAXValueAttribute as String, 0)
                builder.setChildren(header, [disclosure])
            } else {
                builder.setChildren(header, [])
            }
            return header
        }
        builder.setChildren(rail, headers)
        headerRail = rail
        initialHeaders = headers
        initialNames = names

        builder.setAttribute(file, kAXTitleAttribute as String, "파일")
        builder.setAttribute(edit, kAXTitleAttribute as String, "편집")
        builder.setAttribute(track, kAXTitleAttribute as String, "트랙")
        builder.setAttribute(sortBy, kAXTitleAttribute as String, "트랙을 다음으로 정렬")
        builder.setAttribute(sortByName, kAXTitleAttribute as String, "트랙 이름")
        builder.setAttribute(sortByName, kAXEnabledAttribute as String, true)
        builder.setAttribute(sortByCreation, kAXTitleAttribute as String, TrackSortCriterion.creationDate.measuredLabel(for: "ko-KR")!)
        builder.setAttribute(sortByCreation, kAXEnabledAttribute as String, true)
        builder.setChildren(menuBar, [file, edit, track])
        builder.setChildren(track, [sortBy])
        builder.setChildren(sortBy, [sortByName, sortByCreation])
        if includingMixerView {
            builder.setAttribute(app, kAXFrontmostAttribute as String, true)
            builder.setRole(arrange, kAXWindowRole as String)
            for item in [file, edit, track] { builder.setRole(item, kAXMenuBarItemRole as String) }
            builder.setRole(view, kAXMenuBarItemRole as String)
            builder.setAttribute(view, kAXTitleAttribute as String, "보기")
            builder.setAttribute(view, kAXSelectedAttribute as String, false)
            builder.setActionNames(view, [kAXPressAction as String, kAXCancelAction as String])
            builder.setRole(mixerToggle, kAXMenuItemRole as String)
            builder.setAttribute(mixerToggle, kAXTitleAttribute as String, "믹서 보기")
            builder.setAttribute(mixerToggle, kAXEnabledAttribute as String, true)
            builder.setActionNames(mixerToggle, [kAXPressAction as String])
            builder.setChildren(view, [mixerToggle])
            builder.setChildren(menuBar, [file, edit, track, view])
            builder.setRole(mixer, kAXGroupRole as String)
            builder.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
            builder.setChildren(mixer, [])
        }

        let ax = builder.makeAXRuntime(
            appElement: app,
            attributeValueHandler: { _, attribute in
                if attribute == kAXHelpAttribute as String { probe.recordHelpRead() }
                return nil
            },
            attributeValueResultHandler: { element, attribute in
                if attribute == kAXHelpAttribute as String { probe.recordHelpRead() }
                if let windowsReadStatus,
                   builder.elementID(element) == builder.elementID(app),
                   attribute == (kAXWindowsAttribute as String) {
                    return .failure(windowsReadStatus)
                }
                if let railRoleReadStatus,
                   builder.elementID(element) == builder.elementID(rail),
                   attribute == (kAXRoleAttribute as String) {
                    return .failure(railRoleReadStatus)
                }
                if let menuEnabledReadStatus,
                   builder.elementID(element) == builder.elementID(sortByName),
                   attribute == (kAXEnabledAttribute as String) {
                    return .failure(menuEnabledReadStatus)
                }
                if let onMenuEnabledRead,
                   builder.elementID(element) == builder.elementID(sortByName),
                   attribute == (kAXEnabledAttribute as String) {
                    probe.recordEnabledReadCallback()
                    onMenuEnabledRead()
                }
                return nil
            },
            childrenResultHandler: { element in
                guard builder.elementID(element) == builder.elementID(rail),
                      probe.pressCount > 0 else {
                    return nil
                }
                if railUnreadableAfterPress {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                }
                if let postPressOrders, !postPressOrders.isEmpty {
                    // The strict rail scan reads the candidate and then its rows,
                    // so each observation consumes two rail-children reads.
                    let observation = min(
                        probe.nextPostPressRailRead() / 2,
                        postPressOrders.count - 1
                    )
                    return .success(postPressOrders[observation].map { headers[$0] })
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                if includingMixerView, CFEqual(element, view) {
                    if action == kAXPressAction as String {
                        probe.viewEvents.append("open_view")
                        builder.setAttribute(view, kAXSelectedAttribute as String, true)
                        return true
                    }
                    if action == kAXCancelAction as String {
                        probe.viewEvents.append("cancel_view")
                        builder.setAttribute(view, kAXSelectedAttribute as String, false)
                        return true
                    }
                }
                if includingMixerView, CFEqual(element, mixerToggle), action == kAXPressAction as String {
                    probe.mixerShowing.toggle()
                    probe.viewEvents.append(probe.mixerShowing ? "show_mixer" : "hide_mixer")
                    probe.actionOrder.append(probe.mixerShowing ? "show_mixer" : "hide_mixer")
                    let children = builder.makeAXRuntime(appElement: app).children(arrange)
                    builder.setChildren(arrange, children.filter { !CFEqual($0, mixer) } + (probe.mixerShowing ? [mixer] : []))
                    builder.setAttribute(mixerToggle, kAXTitleAttribute as String, probe.mixerShowing ? "믹서 가리기" : "믹서 보기")
                    builder.setAttribute(view, kAXSelectedAttribute as String, false)
                    return true
                }
                guard action == kAXPressAction as String,
                      [sortByName, sortByCreation].contains(where: { CFEqual($0, element) }) else {
                    return false
                }
                probe.recordPress()
                probe.actionOrder.append(CFEqual(element, sortByCreation) ? "sort_inverse" : "sort_forward")
                if let namesAfterPress {
                    let actualNames = CFEqual(element, sortByCreation) ? names : namesAfterPress
                    for (index, name) in actualNames.enumerated() {
                        builder.setAttribute(headers[index], kAXTitleAttribute as String, name)
                    }
                }
                builder.setChildren(rail, CFEqual(element, sortByCreation) ? headers : orderAfterPress.map { headers[$0] })
                return pressReturnsSuccess
            }, executeAppleScript: { _ in Issue.record("AppleScript forbidden in the injected sort fixture"); return .error("forbidden") }
        )
        runtime = AXLogicProElements.Runtime(
            logicProPID: { 4242 }, ax: ax,
            executeAppleScript: { _ in Issue.record("AppleScript forbidden in the injected sort fixture"); return .error("forbidden") },
            onScreenWindowList: { [] },
            postPopupMenuEscape: { Issue.record("global Escape forbidden in the injected sort fixture") },
            focusedApplicationPID: { 4242 }, observeFrontmost: nil
        )
        let expected = (expectedReferenceOrder ?? orderAfterPress).map {
            TrackSortExpectedTrack(
                reference: "trk_\($0)",
                beforeIndex: $0,
                beforeName: names[$0]
            )
        }
        expectedOrderJSON = String(
            data: try! JSONEncoder().encode(expected),
            encoding: .utf8
        )!
    }
}

@Suite("#448 verified track sort")
struct Issue448TrackSortVerifiedTests {
    @Test(arguments: ["sorted", "ineffective_press", "wrong_order", "unreadable", "stale_ref"])
    func thirtyTwoTrackDispatcherChecksTheEntireNativeOrder(mode: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let names = ["Audio 1"] + (3...31).map { "Audio \($0)" } + ["Aux 1", "Audio 2"]
            let expectedIndices = [0, 31] + Array(1...30)
            let desiredNames = expectedIndices.map { names[$0] }
            let observedNames: [String]
            switch mode {
            case "sorted": observedNames = desiredNames
            case "wrong_order": observedNames = Array(desiredNames.reversed())
            default: observedNames = names
            }
            // Model Logic's observed in-place header reuse, not an AX-handle
            // permutation that would accidentally certify the old row order.
            let fixture = TrackSortAXFixture(orderAfterPress: Array(names.indices),
                expectedReferenceOrder: expectedIndices, names: names,
                namesAfterPress: observedNames, railUnreadableAfterPress: mode == "unreadable")
            let registry = TargetRegistry()
            var references: [TargetReference] = []
            for (index, name) in names.enumerated() {
                let descriptor = TargetDescriptor(trackIndex: index, trackName: name)
                references.append(await registry.bind(kind: .track, descriptor: descriptor,
                    fingerprint: descriptor.fingerprint))
            }
            let expected = expectedIndices.map { references[$0].rawValue }
            var requested = expected
            if mode == "stale_ref" { requested[31] = "trk_00000000-0000-4000-8000-000000000971" }
            let generation = await registry.currentTopologyGeneration
            let channel = TrackSortStateBChannel(runtime: fixture.runtime)
            let router = ChannelRouter()
            await router.register(channel)
            let result = await TrackDispatcher.handle(command: "sort_verified", params: [
                "criterion": .string("track_name"),
                "expected_order": .array(requested.map(Value.string)), "confirmed": .bool(true)],
                router: router, cache: StateCache(), targetRegistry: registry)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let isError = try #require(result.isError)
            let writeAttempted = try #require(body["write_attempted"] as? Bool)
            if mode == "stale_ref" {
                #expect(isError)
                #expect(body["state"] as? String == "C")
                #expect(body["error"] as? String == "stale_target_reference")
                #expect(!writeAttempted)
                #expect(fixture.actionProbe.pressCount == 0)
                #expect(await channel.calls.isEmpty)
                #expect(await registry.currentTopologyGeneration == generation)
                return
            }
            #expect(fixture.actionProbe.pressCount == 1)
            #expect(await channel.calls.count == 1)
            #expect(writeAttempted)
            let menuPressReportedSuccess = try #require(body["menu_press_reported_success"] as? Bool)
            #expect(menuPressReportedSuccess)
            #expect(body["actuated_criterion"] as? String == "track_name")
            #expect(body["actuated_menu_item_label"] as? String == "트랙 이름")
            #expect(body["before_order"] as? [String] == references.map(\.rawValue))
            let before = try #require(body["before_tracks"] as? [[String: Any]])
            #expect(before.compactMap { $0["name"] as? String } == names)
            #expect(body["expected_order"] as? [String] == expected)
            #expect(body["before_track_count"] as? Int == names.count)
            let verified = try #require(body["verified"] as? Bool)
            if mode == "sorted" {
                #expect(!isError)
                #expect(body["state"] as? String == "A")
                #expect(verified)
                #expect(body["after_order"] as? [String] == expected)
            } else {
                #expect(isError)
                #expect(body["state"] as? String == "B")
                #expect(!verified)
                let safeToRetry = try #require(body["safe_to_retry"] as? Bool)
                #expect(!safeToRetry)
                #expect(body["reason"] as? String == (mode == "unreadable"
                    ? "readback_unavailable" : "readback_mismatch"))
            }
            if mode == "unreadable" {
                #expect(body["after_order"] is NSNull)
                #expect(body["after_tracks"] is NSNull)
            } else {
                #expect(body["after_track_count"] as? Int == names.count)
                let after = try #require(body["after_tracks"] as? [[String: Any]])
                #expect(after.compactMap { $0["name"] as? String } == observedNames)
                let referenceByName = Dictionary(uniqueKeysWithValues: zip(names, references.map(\.rawValue)))
                let observedOrder = try observedNames.map { try #require(referenceByName[$0]) }
                #expect(body["after_order"] as? [String] == observedOrder,
                    "A failed goal still has to report the complete actual reference permutation")
            }
            #expect(await registry.currentTopologyGeneration == generation + 1)
            #expect(await registry.resolve(references[0]) == nil)
        }
    }

    @Test(arguments: [false, true])
    func canonicalFlatNameSortUsesItsMeasuredLeafAndOwnedCreationDateInverse(cancelAfterSort: Bool) async throws {
        try await canonicalSort(cancelAfterSort: cancelAfterSort)
    }

    @Test("Canonical sort preserves a production-normalized Solo presentation",
          arguments: [false, true])
    func canonicalSortAcceptsNormalizedSoloPresentation(cancelAfterSort: Bool) async throws {
        try await canonicalSort(cancelAfterSort: cancelAfterSort, capturedSoloPresentation: true)
    }

    @Test(arguments: ["forward", "cancel_sort", "cancel_view", "view_refuses", "foreign_project", "unowned_name", "unsupported_focus"])
    func canonicalFlatSortAndMixerFinalViewUseTheirOwnedSteps(mode: String) async throws {
        try await canonicalSort(cancelAfterSort: mode == "cancel_sort", composedMode: mode)
    }

    @Test(arguments: ["clean", "order", "document", "transport", "recording", "hidden", "name", "selection", "window", "header"])
    func canonicalMatchingSortFreshlyVerifiesWithoutPressingAnyLeaf(mode: String) async throws {
        try await canonicalSort(cancelAfterSort: false, matchingMode: mode)
    }

    @Test
    func canonicalMatchingSortStillAppliesItsRequestedFinalMixerView() async throws {
        try await canonicalSort(cancelAfterSort: false, composedMode: "forward", matchingMode: "clean")
    }

    @Test(arguments: ["order", "document", "transport", "name"])
    func canonicalMatchingSortRefusesDriftBeforeItsFinalMixerView(mode: String) async throws {
        try await canonicalSort(cancelAfterSort: false, composedMode: "forward", matchingMode: mode)
    }

    private func canonicalSort(cancelAfterSort: Bool, composedMode: String? = nil,
                               matchingMode: String? = nil,
                               capturedSoloPresentation: Bool = false) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                // Logic's physical header CFs can stay at their rail indexes
                // while contents move. The existing unique-name tier must decide order.
                let f = TrackSortAXFixture(orderAfterPress: [0, 1, 2], expectedReferenceOrder: [1, 0, 2],
                    namesAfterPress: ["Bass", "Kick", "Piano"], includingMixerView: composedMode != nil)
                let project = ProjectInfo(name: "SortFixture", filePath: "/tmp/SortFixture.logicx")
                f.builder.setAttribute(f.arrangeWindow, kAXTitleAttribute as String, "SortFixture")
                f.builder.setAttribute(f.arrangeWindow, kAXDocumentAttribute as String, "file:///tmp/SortFixture.logicx")
                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.headerRail)
                f.builder.setAttribute(f.app, kAXWindowsAttribute as String, [f.arrangeWindow])
                for header in f.initialHeaders {
                    f.builder.setAttribute(header, kAXHelpAttribute as String, "audio track")
                }
                if capturedSoloPresentation {
                    for (index, header) in f.initialHeaders.enumerated() {
                        let mute = f.builder.element(989_000 + index * 2)
                        let solo = f.builder.element(989_001 + index * 2)
                        for (control, description, value) in [
                            (mute, AXLocalePolicy.trackMuteButton.canonical, 0),
                            (solo, AXLocalePolicy.trackSoloButton.canonical, 1),
                        ] {
                            f.builder.setRole(control, kAXCheckBoxRole as String)
                            f.builder.setAttribute(control, kAXDescriptionAttribute as String, description)
                            f.builder.setAttribute(control, kAXValueAttribute as String, value)
                            f.builder.setChildren(control, [])
                        }
                        f.builder.setChildren(header, [mute, solo])
                    }
                }
                let bar = f.builder.element(969_010), play = f.builder.element(969_011), record = f.builder.element(969_012)
                f.builder.setRole(bar, kAXGroupRole as String)
                f.builder.setAttribute(bar, kAXDescriptionAttribute as String, AXLocalePolicy.controlBarGroupLabel.canonical)
                for (control, label) in [(play, AXLocalePolicy.transportPlayControl.canonical),
                                         (record, AXLocalePolicy.transportRecordControl.canonical)] {
                    f.builder.setRole(control, kAXCheckBoxRole as String)
                    f.builder.setAttribute(control, kAXTitleAttribute as String, label)
                    f.builder.setAttribute(control, kAXValueAttribute as String, 0)
                    f.builder.setChildren(control, [])
                }
                f.builder.setChildren(bar, [play, record])
                let scroll = f.builder.element(969_020), headerSplit = f.builder.element(969_021)
                let split = f.builder.element(969_022), legendSplit = f.builder.element(969_023)
                let legend = f.builder.element(969_024), showHidden = f.builder.element(969_025)
                for (element, role) in [(scroll, kAXScrollAreaRole), (headerSplit, kAXSplitGroupRole),
                    (split, kAXSplitGroupRole), (legendSplit, kAXSplitGroupRole), (legend, kAXGroupRole),
                    (showHidden, kAXCheckBoxRole)] { f.builder.setRole(element, role as String) }
                f.builder.setChildren(scroll, [f.headerRail]); f.builder.setChildren(headerSplit, [scroll])
                f.builder.setChildren(split, [headerSplit, legendSplit]); f.builder.setChildren(legendSplit, [legend])
                f.builder.setChildren(legend, [showHidden]); f.builder.setChildren(showHidden, [])
                f.builder.setAttribute(showHidden, kAXDescriptionAttribute as String, AXLocalePolicy.trackHiddenViewControl.canonical)
                f.builder.setAttribute(showHidden, kAXWindowAttribute as String, f.arrangeWindow)
                f.builder.setAttribute(showHidden, kAXValueAttribute as String, 1)
                f.builder.setChildren(f.arrangeWindow, [split, bar])
                if composedMode == "unsupported_focus" {
                    let background = f.builder.element(969_040)
                    f.builder.setRole(background, kAXLayoutAreaRole as String)
                    f.builder.setChildren(background, [])
                    f.builder.setAttributeSettable(background, kAXFocusedAttribute as String, true)
                    f.builder.setChildren(f.arrangeWindow, [split, bar, background])
                    f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, background)
                }
                let transport = try #require(try AXLogicProElements.observedTransportActivity(
                    in: f.arrangeWindow, runtime: f.runtime, checking: {}))
                let cache = StateCache(), registry = TargetRegistry(), journal = SagaJournal(), router = ChannelRouter()
                await cache.updateProject(project)
                let legacy = try #require(AccessibilityChannel.defaultGetTrackStates(runtime: f.runtime))
                #expect(legacy.allSatisfy { $0.type == .audio })
                let rawTracks = try #require(AccessibilityChannel.readTrackStates(from: f.initialHeaders,
                    in: f.arrangeWindow, runtime: f.runtime, readingTypeHelp: false, stoppingWhen: { false }).states)
                let tracks = capturedSoloPresentation
                    ? try #require(AccessibilityChannel.soloPresentationSafeTrackStates(rawTracks))
                    : rawTracks
                #expect(tracks.allSatisfy { $0.type == .unknown })
                for row in tracks { #expect(row.physicalBinding?.currentIndex() == row.id) }
                await cache.updateTracks(tracks)
                var population = SessionPopulationObservation.FreshPopulation(project: project, tracks: tracks,
                    strips: nil, fileTrackCount: 3, beganAt: Date(), endedAt: Date(), stable: true)
                population.hiddenTracksShown = true
                population.populationEndSource = "ax_all_shown_single_page"
                population.presentationObservation = .init(mixerVisible: false, isPlaying: false, isRecording: false, uiLocale: "ko-KR")
                population.presentationBinding = .init(window: f.arrangeWindow, title: "SortFixture",
                    document: "file:///tmp/SortFixture.logicx", mixer: nil, transport: transport, runtime: f.runtime, uiLocale: "ko-KR")
                let boundary = await cache.captureBoundary(watching: SessionPopulationObservation.watchedSections)
                let capture = await SessionPopulationObservation.capture(cache: cache, targetRegistry: registry,
                    fileReader: .unavailable, accepted: .init(reading: .init(state: await cache.auditSnapshot(),
                        fileTrackCount: 3, projectFileNotBound: false), boundary: boundary, population: population))
                guard case .issued(let projectRef)? = capture.projectIssuance else {
                    Issue.record("the actual captured project must issue a reference"); return
                }
                let order = try capture.issued!.byRow.map { try #require($0) }
                let request = SessionPopulationObservation.Request(domains: [.tracks])
                let report = SessionPopulationObservation.build(request: request, capture: capture)
                #expect(report.tracks.coverage == .complete)
                #expect(await cache.retainSessionReport(id: capture.captureID,
                    json: String(decoding: try JSONEncoder().encode(report), as: UTF8.self),
                    capturedEpoch: capture.projectEpoch, capturedPath: project.filePath, capture: capture, request: request))
                var presentation: [String: Value] = ["sort": .object(["criterion": .string("track_name"),
                    "expected_order": .array((matchingMode == nil ? [order[1], order[0], order[2]] : order).map { .string($0.rawValue) }),
                    "inverse_criterion": .string("creation_date")])]
                if composedMode != nil { presentation["mixer_visible"] = .bool(true) }
                let raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(projectRef.rawValue), "targets": .array([]),
                    "presentation": .object(presentation)]
                guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
                    Issue.record("the supported flat sort policy must parse"); return
                }
                let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
                    names: [], capture: capture, request: request, snapshotCurrent: true)
                let executable = try #require(sharedJSONObject(plan.json)?["executable"] as? Bool)
                if composedMode == "unsupported_focus" {
                    #expect(!executable)
                    let reasons = try #require(sharedJSONObject(plan.json)?["reasons"] as? [String])
                    #expect(reasons.contains("workspace_focus_restoration_unavailable"))
                    #expect(f.actionProbe.actionOrder.isEmpty)
                    return
                }
                #expect(executable)
                if matchingMode != nil {
                    let planned = try #require(sharedJSONObject(plan.json))
                    #expect(planned["unchanged_tasks"] as? [String] == ["track_sort"])
                    #expect((planned["steps"] as? [[String: Any]])?.count == (composedMode == nil ? 0 : 1))
                }
                #expect(await cache.retainRepairPlan(plan, snapshotID: capture.captureID))
                let key = "canonical-flat-name-sort"
                let approval = try #require(await ApprovedSessionRepair.retained(id: plan.id, digest: plan.digest,
                    key: key, cache: cache, registry: registry, journal: journal))
                await router.register(TrackSortStateBChannel(runtime: f.runtime))
                let generation = await registry.currentTopologyGeneration
                let helpReads = f.actionProbe.helpReadCount
                switch matchingMode {
                case "order": f.builder.setChildren(f.headerRail, [f.initialHeaders[1], f.initialHeaders[0], f.initialHeaders[2]])
                case "document": f.builder.setAttribute(f.arrangeWindow, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                case "transport": f.builder.setAttribute(play, kAXValueAttribute as String, 1)
                case "recording": f.builder.setAttribute(record, kAXValueAttribute as String, 1)
                case "hidden": f.builder.setAttribute(showHidden, kAXValueAttribute as String, 0)
                case "name": f.builder.setAttribute(f.initialHeaders[2], kAXTitleAttribute as String, "Human")
                case "selection": f.builder.setAttribute(f.initialHeaders[2], kAXSelectedAttribute as String, true)
                case "window":
                    let other = f.builder.element(969_030)
                    f.builder.setAttribute(f.app, kAXMainWindowAttribute as String, other)
                    f.builder.setAttribute(f.app, kAXFocusedWindowAttribute as String, other)
                    f.builder.setAttribute(f.app, kAXWindowsAttribute as String, [other])
                    #expect(!CFEqual(try #require(AXLogicProElements.mainWindow(runtime: f.runtime)), f.arrangeWindow))
                case "header": f.builder.setChildren(f.headerRail, [f.initialHeaders[0], f.initialHeaders[1], f.builder.element(969_031)])
                default: break
                }
                let result = await SystemDispatcher.handle(command: "saga_execute", params: [:], router: router,
                    cache: cache, targetRegistry: registry, dialogPresent: { false }, sagaJournal: journal,
                    mutationGate: LogicMutationGate(), sagaRefreshAfterWrite: {
                        if cancelAfterSort, f.actionProbe.pressCount == 1 {
                            #expect(await journal.cancel(idempotencyKey: key) == .requested)
                        }
                        if composedMode == "cancel_view", f.actionProbe.mixerShowing {
                            #expect(await journal.cancel(idempotencyKey: key) == .requested)
                        }
                        if composedMode == "foreign_project", f.actionProbe.pressCount == 1 {
                            f.builder.setAttribute(f.arrangeWindow, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                        }
                        if composedMode == "unowned_name", f.actionProbe.pressCount == 1 {
                            f.builder.setAttribute(f.initialHeaders[2], kAXTitleAttribute as String, "Human")
                        }
                        if composedMode == "view_refuses", f.actionProbe.pressCount == 1 {
                            let menu = f.builder.element(448_003)
                            f.builder.setChildren(menu, [f.builder.element(448_004), f.builder.element(448_005), f.builder.element(448_006)])
                        }
                    }, sagaLiveReadback: .unavailable, approvedSessionRepair: approval)
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                if let matchingMode {
                    let succeeds = matchingMode == "clean"
                    #expect(body["state"] as? String == (succeeds ? "A" : "C"))
                    let verified = try #require(body["verified"] as? Bool)
                    if succeeds { #expect(verified) } else { #expect(!verified) }
                    #expect(f.actionProbe.pressCount == 0)
                    if composedMode == nil { #expect(f.actionProbe.helpReadCount == helpReads) }
                    #expect(await registry.currentTopologyGeneration == generation)
                    #expect(await registry.resolve(order[0]) != nil)
                    if composedMode != nil && succeeds { #expect(f.actionProbe.mixerShowing) }
                    else { #expect(!f.actionProbe.mixerShowing) }
                    if composedMode == nil {
                        let attempted = try #require(body["write_attempted"] as? Bool)
                        #expect(!attempted)
                        #expect(body["writes_performed"] as? Int == 0)
                        #expect(f.actionProbe.actionOrder.isEmpty)
                    } else {
                        #expect(f.actionProbe.actionOrder == (succeeds ? ["show_mixer"] : []))
                    }
                    if succeeds {
                        #expect(body["saga_state"] as? String == "completed")
                        if composedMode == nil {
                            let evidence = try #require(body["goal_evidence"] as? [[String: Any]])
                            let read = try #require(evidence.first?["read"] as? [String: Any])
                            #expect(read["read_source"] as? String == "ax_track_order")
                            #expect(read["provenance"] as? String == "live_independent")
                        }
                    }
                    let params: [String: Value] = ["plan_id": .string(plan.id), "digest": .string(plan.digest),
                        "confirmed": .bool(true), "idempotency_key": .string(key)]
                    let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                        poller: StatePoller(axChannel: AccessibilityChannel(), cache: cache, runtime: .init(hasVisibleWindow: { false })),
                        dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal, mutationGate: LogicMutationGate(),
                        projectFileReader: .unavailable)
                    if succeeds, composedMode == nil {
                        f.builder.setAttribute(f.initialHeaders[2], kAXTitleAttribute as String, "Later human edit")
                    }
                    let replay = await ApprovedSessionRepair.apply(request: try #require(.parse(params)), dependencies: dependencies)
                    let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
                    let duplicate = try #require(replayBody["duplicate"] as? Bool)
                    #expect(duplicate)
                    #expect(replayBody["state"] as? String == (succeeds ? "A" : "C"))
                    #expect(f.actionProbe.pressCount == 0)
                    #expect(await registry.currentTopologyGeneration == generation)
                    if succeeds, composedMode == nil {
                        var freshParams = params
                        freshParams["idempotency_key"] = .string(key + "-new-attempt")
                        let fresh = await ApprovedSessionRepair.apply(request: try #require(.parse(freshParams)), dependencies: dependencies)
                        let freshBody = try #require(sharedJSONObject(sharedToolText(fresh)))
                        #expect(freshBody["state"] as? String == "C")
                        let attempted = try #require(freshBody["write_attempted"] as? Bool)
                        #expect(!attempted)
                        #expect(f.actionProbe.pressCount == 0)
                    }
                    return
                }
                if ["foreign_project", "unowned_name"].contains(composedMode) {
                    let verified = try #require(body["verified"] as? Bool)
                    #expect(!verified)
                    #expect(!f.actionProbe.mixerShowing)
                    #expect(f.actionProbe.viewEvents.isEmpty)
                    #expect(f.actionProbe.pressCount == 1)
                    return
                }
                let compensates = cancelAfterSort || composedMode == "cancel_view" || composedMode == "view_refuses"
                if composedMode == nil {
                    #expect(f.actionProbe.helpReadCount == helpReads, "The public no-Help population footprint must not acquire focus-moving Help during approved sort")
                }
                #expect(body["saga_state"] as? String == (compensates ? "fullyCompensated" : "completed"))
                #expect(f.actionProbe.pressCount == (compensates ? 2 : 1))
                if composedMode != nil {
                    #expect(f.actionProbe.mixerShowing == !compensates)
                    #expect(f.actionProbe.viewEvents.filter { $0 != "open_view" && $0 != "cancel_view" }
                        == (cancelAfterSort || composedMode == "view_refuses" ? [] : compensates ? ["show_mixer", "hide_mixer"] : ["show_mixer"]))
                    #expect(f.actionProbe.actionOrder == (cancelAfterSort || composedMode == "view_refuses"
                        ? ["sort_forward", "sort_inverse"] : compensates
                        ? ["sort_forward", "show_mixer", "hide_mixer", "sort_inverse"] : ["sort_forward", "show_mixer"]))
                }
                let afterRows = try #require(AXLogicProElements.trackNames(runtime: f.runtime))
                let after = afterRows.keys.sorted().compactMap { afterRows[$0] }
                #expect(after == (compensates ? ["Kick", "Bass", "Piano"] : ["Bass", "Kick", "Piano"]))
                #expect(await registry.currentTopologyGeneration == generation + (compensates ? 2 : 1))
                #expect(await registry.resolve(order[0]) == nil, "Pre-sort references cannot authorize the inverse")
                let params: [String: Value] = ["plan_id": .string(plan.id), "digest": .string(plan.digest),
                    "confirmed": .bool(true), "idempotency_key": .string(key)]
                let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                    poller: StatePoller(axChannel: AccessibilityChannel(), cache: cache, runtime: .init(hasVisibleWindow: { false })),
                    dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal, mutationGate: LogicMutationGate(),
                    projectFileReader: .unavailable)
                let replay = await ApprovedSessionRepair.apply(request: try #require(.parse(params)), dependencies: dependencies)
                let duplicate = try #require(sharedJSONObject(sharedToolText(replay))?["duplicate"] as? Bool)
                #expect(duplicate)
                #expect(f.actionProbe.pressCount == (compensates ? 2 : 1))
            }
        }
    }

    @Test(arguments: ["e\u{0301}", "\u{00e9}"])
    func byteIdenticalNonASCIINameRetainsItsSortReference(name: String) throws {
        let fixture = TrackSortAXFixture(orderAfterPress: [1, 0, 2], names: [name, "Bass", "Piano"])
        let result = AccessibilityChannel.defaultSortTracks(params: [
            "criterion": "track_name", "expected_order_json": fixture.expectedOrderJSON,
        ], runtime: fixture.runtime)
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "A")
        #expect(body["after_order"] as? [String] == ["trk_1", "trk_0", "trk_2"])
        #expect(body["actuated_menu_item_label"] as? String == "트랙 이름")
        #expect(fixture.actionProbe.pressCount == 1)
        let afterName = try #require(AXHelpers.getTitle(fixture.initialHeaders[0], runtime: fixture.runtime.ax))
        #expect(afterName.utf8.elementsEqual(name.utf8))
    }

    @Test func canonicalEquivalentDuplicateNamesStillRefuseBeforePress() throws {
        let fixture = TrackSortAXFixture(orderAfterPress: [1, 0, 2], names: ["e\u{0301}", "\u{00e9}", "Piano"])
        let result = AccessibilityChannel.defaultSortTracks(params: [
            "criterion": "track_name", "expected_order_json": fixture.expectedOrderJSON,
        ], runtime: fixture.runtime)
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "C")
        #expect(body["reason"] as? String == "duplicate_name_reference_identity_unprovable")
        #expect(fixture.actionProbe.pressCount == 0)
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(!attempted)
        let order = AccessibilityChannel.trackSortAfterOrder(
            afterNames: ["\u{00e9}", "e\u{0301}"], beforeNames: ["e\u{0301}", "\u{00e9}"],
            beforeReferences: ["trk_0", "trk_1"])
        #expect(order == nil)
    }

    @Test(arguments: ["before", "after"])
    func canonicalEquivalentRawRenameCannotKeepAnIssuedSortIdentity(phase: String) throws {
        let issuedNames = ["e\u{0301}", "Bass", "Piano"]
        let changedNames = ["\u{00e9}", "Bass", "Piano"]
        let fixture = TrackSortAXFixture(orderAfterPress: [1, 0, 2], names: issuedNames,
            observedNames: phase == "before" ? changedNames : nil,
            namesAfterPress: phase == "after" ? changedNames : nil)
        let result = AccessibilityChannel.defaultSortTracks(params: [
            "criterion": "track_name", "expected_order_json": fixture.expectedOrderJSON,
        ], runtime: fixture.runtime)
        let body = try #require(sharedJSONObject(result.message))
        let observedName = try #require(AXHelpers.getTitle(fixture.initialHeaders[0], runtime: fixture.runtime.ax))
        #expect(Array(observedName.utf8) == Array(changedNames[0].utf8))
        #expect(Array(observedName.utf8) != Array(issuedNames[0].utf8))
        switch AXLogicProElements.logicUILocaleIdentifierRead(runtime: fixture.runtime) {
        case .locale(let locale): #expect(locale == "ko-KR")
        case .absent, .unreadable: Issue.record("the injected sort fixture must expose its measured Korean locale")
        }
        if phase == "before" {
            #expect(fixture.actionProbe.pressCount == 0)
            #expect(body["state"] as? String == "C")
            #expect(body["reason"] as? String == "expected_order_track_refs_not_in_before_order")
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(!attempted)
        } else {
            #expect(fixture.actionProbe.pressCount == 1)
            #expect(body["state"] as? String == "B")
            #expect(body["detail"] as? String == "after_order_unreadable")
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(attempted)
        }
    }

    @Test("an unknown sort criterion is rejected before any AX work")
    func unknownCriterionRefuses() {
        let criterion = TrackSortCriterion(rawValue: "not_a_sort_criterion")
        let isUnknown = criterion == nil

        #expect(isUnknown)
    }

    @Test("every measured Korean criterion resolves to its observed menu label")
    func everyCriterionResolvesMeasuredLabel() {
        let expected: [TrackSortCriterion: String] = [
            .midiChannel: "MIDI 채널",
            .audioChannel: "오디오 채널",
            .outputChannel: "출력 채널",
            .instrumentName: "악기 이름",
            .trackName: "트랙 이름",
            .used: "사용 여부",
            .creationDate: "생성일",
        ]

        let resolved = Dictionary(uniqueKeysWithValues: TrackSortCriterion.allCases.map {
            ($0, $0.measuredLabel(for: "ko_KR"))
        })
        let runtimeResolved = Dictionary(uniqueKeysWithValues: TrackSortCriterion.allCases.map {
            ($0, $0.measuredLabel(for: "ko-KR"))
        })
        let allResolved = expected.allSatisfy { criterion, label in
            resolved[criterion] == label && runtimeResolved[criterion] == label
        }

        #expect(allResolved)
    }

    @Test("every observed English sort leaf resolves to the exact measured criterion",
          arguments: TrackSortCriterion.allCases, ["en_US", "en-US"])
    func everyEnglishCriterionResolvesMeasuredLabel(criterion: TrackSortCriterion, locale: String) {
        let expected: [TrackSortCriterion: String] = [
            .midiChannel: "MIDI Channel",
            .audioChannel: "Audio Channel",
            .outputChannel: "Output Channel",
            .instrumentName: "Instrument Name",
            .trackName: "Track Name",
            .used: "Used, Unused",
            .creationDate: "Creation Date",
        ]
        let label = expected[criterion]!
        #expect(criterion.measuredLabel(for: locale) == label)
        #expect(TrackSortCriterion.measuredCriterion(forObservedMenuItemLabel: label,
            localeIdentifier: locale) == criterion)
        #expect(criterion.label.matches(label))
    }

    @Test("English measurement does not authorize translated, plural or malformed leaf titles",
          arguments: ["MIDI Channels", "Instrument Names", "Track Names", "Track Name ", "track name", "트랙 이름"])
    func englishMeasurementRejectsUnobservedLeafTitles(label: String) {
        let observed = TrackSortCriterion.measuredCriterion(forObservedMenuItemLabel: label,
            localeIdentifier: "en-US")
        #expect(observed == nil)
    }

    @Test("unmeasured locale identifiers remain unsupported",
          arguments: ["en", "en-GB", "ja-JP", "fr-FR", "unknown"])
    func unrelatedLocalesRemainUnmeasured(locale: String) {
        #expect(TrackSortCriterion.trackName.measuredLabel(for: locale) == nil)
    }

    @Test("an unmeasured locale names the missing sort-menu measurement")
    func unmeasuredLocaleRefuses() {
        let policyRefusesJapanese = TrackSortCriterion.trackName.measuredLabel(for: "ja-JP") == nil
        let outcome = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .read(["trk_kick", "trk_bass"]) },
            actuate: { .unmeasuredLocale("ja-JP") },
            after: { .read(["trk_bass", "trk_kick"]) }
        )

        let refusedForMissingMeasurement: Bool
        if case .refused(.unmeasuredLocale(let locale)) = outcome {
            refusedForMissingMeasurement = locale == "ja-JP"
        } else {
            refusedForMissingMeasurement = false
        }
        let bothLocaleGuardsHeld = policyRefusesJapanese && refusedForMissingMeasurement
        #expect(bothLocaleGuardsHeld)
    }

    @Test("a missing leaf in the measured locale has its own refusal")
    func measuredCriterionLabelAbsentRefuses() {
        let outcome = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .read(["trk_kick", "trk_bass"]) },
            actuate: { .criterionLabelMissing("트랙 이름") },
            after: { .read(["trk_bass", "trk_kick"]) }
        )

        let refusedForAbsentMeasuredLabel: Bool
        if case .refused(.criterionLabelMissing(let label)) = outcome {
            refusedForAbsentMeasuredLabel = label == "트랙 이름"
        } else {
            refusedForAbsentMeasuredLabel = false
        }
        #expect(refusedForAbsentMeasuredLabel)
    }

    @Test("an order matching expectation under the wrong actuated criterion is refused")
    func wrongActuatedCriterionRefuses() {
        let instrumentNameActuation = TrackSortVerifier.ActuatedMenuItem(
            localizedLabel: "악기 이름",
            criterion: .instrumentName
        )
        let outcome = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .read(["trk_kick", "trk_bass"]) },
            actuate: { .actuated(instrumentNameActuation) },
            // The wrong sort happens to produce the requested permutation. This
            // test fails if the production criterion-binding guard is removed.
            after: { .read(["trk_bass", "trk_kick"]) }
        )

        let rejectedWrongActuatedCriterion: Bool
        if case .refused(.criterionMismatch(let actual, let label)) = outcome {
            rejectedWrongActuatedCriterion = actual == .instrumentName && label == "악기 이름"
        } else {
            rejectedWrongActuatedCriterion = false
        }
        #expect(rejectedWrongActuatedCriterion)
    }

    @Test("an unreadable before or after order is never assumed")
    func unreadableOrdersRefuseOrRemainUncertain() {
        let beforeUnreadable = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .unavailable },
            actuate: { .actuated(trackNameActuation) },
            after: { .read(["trk_bass", "trk_kick"]) }
        )
        let afterUnreadable = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .read(["trk_kick", "trk_bass"]) },
            actuate: { .actuated(trackNameActuation) },
            after: { .unavailable }
        )

        let beforeRefused: Bool
        if case .refused(.beforeOrderUnreadable) = beforeUnreadable {
            beforeRefused = true
        } else {
            beforeRefused = false
        }
        let afterUncertain: Bool
        if case .uncertain(.afterOrderUnreadable) = afterUnreadable {
            afterUncertain = true
        } else {
            afterUncertain = false
        }

        #expect(beforeRefused)
        #expect(afterUncertain)
    }

    @Test("duplicate names refuse before AX work because no per-track identity was issued")
    func duplicateNamesRefuseBeforePress() throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [2, 1, 0],
            names: ["Studio Grand", "Studio Grand", "Studio Grand"]
        )
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let duplicateNamesWerePresent = Set(["Studio Grand", "Studio Grand", "Studio Grand"]).count == 1
        let refusedWithoutAXPress = result.isSuccess == false
            && body["reason"] as? String == "duplicate_name_reference_identity_unprovable"
            && fixture.actionProbe.pressCount == 0

        #expect(duplicateNamesWerePresent)
        #expect(refusedWithoutAXPress)
    }

    @Test("State A carries the exact pressed leaf and its measured criterion")
    func verifiedSortCarriesActuatedCriterionEvidence() throws {
        let fixture = TrackSortAXFixture(orderAfterPress: [2, 1, 0])
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let includesActualLeafEvidence = result.isSuccess
            && body["state"] as? String == "A"
            && body["criterion"] as? String == "track_name"
            && body["actuated_criterion"] as? String == "track_name"
            && body["actuated_menu_item_label"] as? String == "트랙 이름"
            && fixture.actionProbe.pressCount == 1

        #expect(includesActualLeafEvidence)
    }

    @Test("a collapsed stack refuses before its hidden tracks can be sorted")
    func collapsedStackRefusesBeforePress() throws {
        let fixture = TrackSortAXFixture(orderAfterPress: [2, 1, 0], collapsedStackAt: 1)
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let collapsedScopeWasRejected = result.isSuccess == false
            && body["reason"] as? String == "collapsed_track_stack"
            && (body["collapsed_stack"] as? [String: Any])?["index"] as? Int == 1
            && fixture.actionProbe.pressCount == 0

        #expect(collapsedScopeWasRejected)
    }

    @Test("#1403 sort preflight refusals terminate without human recovery instructions")
    func sortPreflightRefusalsTerminateWithoutHumanRecovery() throws {
        let collapsed = TrackSortAXFixture(orderAfterPress: [2, 1, 0], collapsedStackAt: 1)
        let collapsedResult = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": collapsed.expectedOrderJSON,
            ],
            runtime: collapsed.runtime
        )

        let duplicates = TrackSortAXFixture(
            orderAfterPress: [1, 0, 2], names: ["Studio Grand", "Studio Grand", "Piano"]
        )
        let duplicateResult = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": duplicates.expectedOrderJSON,
            ],
            runtime: duplicates.runtime
        )

        for result in [collapsedResult, duplicateResult] {
            let body = try #require(sharedJSONObject(result.message))
            let terminal = try #require(body["terminal"] as? Bool)
            let humanRequired = try #require(body["human_intervention_required"] as? Bool)
            let writeAttempted = try #require(body["write_attempted"] as? Bool)
            #expect(terminal)
            #expect(!humanRequired)
            #expect(!writeAttempted)

            let hint = try #require(body["hint"] as? String)
            for instruction in ["expand it", "rename duplicates", "re-read", "retry"] {
                #expect(!hint.localizedCaseInsensitiveContains(instruction))
            }
        }
        #expect(collapsed.actionProbe.pressCount == 0)
        #expect(duplicates.actionProbe.pressCount == 0)
    }

    @Test("a failed AXPress still reads back and reports a verified observed order")
    func failedPressStillReadsBack() throws {
        let fixture = TrackSortAXFixture(orderAfterPress: [2, 1, 0], pressReturnsSuccess: false)
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let failedReceiptDidNotEraseTheWrite = result.isSuccess
            && body["state"] as? String == "A"
            && body["menu_press_reported_success"] as? Bool == false
            && body["write_attempted"] as? Bool == true
            && body["after_order"] as? [String] == ["trk_2", "trk_1", "trk_0"]
            && fixture.actionProbe.pressCount == 1

        #expect(failedReceiptDidNotEraseTheWrite)
    }

    @Test("a failed AXPress with unreadable order marks project state unknown and invalidates refs")
    func failedPressUnreadableOrderInvalidatesReferences() async throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [2, 1, 0],
            pressReturnsSuccess: false,
            railUnreadableAfterPress: true
        )
        let channelResult = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let channelBody = try #require(sharedJSONObject(channelResult.message))

        let registry = TargetRegistry()
        let descriptor = TargetDescriptor(trackIndex: 0, trackName: "Kick")
        let reference = await registry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )
        let router = ChannelRouter()
        await router.register(TrackSortStateBChannel(result: channelResult))
        _ = await FeatureFlags.withAdr002TargetRefForTests(true) {
            await TrackDispatcher.handle(
                command: "sort_verified",
                params: [
                    "criterion": .string("track_name"),
                    "expected_order": .array([.string(reference.rawValue)]),
                    "confirmed": .bool(true),
                ],
                router: router,
                cache: StateCache(),
                targetRegistry: registry
            )
        }
        let referenceWasInvalidated = await registry.resolve(reference) == nil
        let unknownStateWasHonest = channelResult.isSuccess
            && channelBody["state"] as? String == "B"
            && channelBody["write_attempted"] as? Bool == true
            && channelBody["project_state"] as? String == "unknown"
            && channelBody["safe_to_retry"] as? Bool == false
            && fixture.actionProbe.pressCount == 1

        #expect(unknownStateWasHonest)
        #expect(referenceWasInvalidated)
    }

    @Test("a transient matching order cannot reach State A before the second matching observation")
    func transientOrderDoesNotPassSettleWitness() throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [2, 1, 0],
            postPressOrders: [[2, 1, 0], [1, 0, 2]]
        )
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let transientWasNotPromoted = result.isSuccess
            && body["state"] as? String == "B"
            && body["reason"] as? String == HonestContract.UncertainReason.readbackMismatch.rawValue
            && body["after_order"] as? [String] == ["trk_1", "trk_0", "trk_2"]

        #expect(transientWasNotPromoted)
    }

    @Test("an already-sorted reference order is State B with an observable reason")
    func alreadySortedIsStateB() throws {
        let fixture = TrackSortAXFixture(orderAfterPress: [0, 1, 2])
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        // `noop_unobservable`, not `readback_unavailable`: the arrangement WAS read and matched.
        // What cannot be observed is whether the command did anything, because a correct sort of
        // a sorted project changes nothing. The old reason said the readback failed.
        let stateBForUnobservableNoOp = result.isSuccess
            && body["state"] as? String == "B"
            && body["reason"] as? String == HonestContract.UncertainReason.noopUnobservable.rawValue
            && body["detail"] as? String == "already_sorted_command_unobservable"

        #expect(stateBForUnobservableNoOp)
    }

    @Test("a wrong post-sort reference order reaches State B and the tool surface refuses it")
    func postSortMismatchIsRefusedByToolSurface() async throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [1, 0, 2],
            expectedReferenceOrder: [2, 1, 0]
        )
        let channelResult = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let channelBody = try #require(sharedJSONObject(channelResult.message))

        let registry = TargetRegistry()
        let references = await FeatureFlags.withAdr002TargetRefForTests(true) {
            var references: [TargetReference] = []
            for index in 0..<3 {
                let descriptor = TargetDescriptor(trackIndex: index, trackName: "Studio Grand")
                references.append(await registry.bind(
                    kind: .track,
                    descriptor: descriptor,
                    fingerprint: descriptor.fingerprint
                ))
            }
            return references
        }
        let router = ChannelRouter()
        let stateBChannel = TrackSortStateBChannel()
        await router.register(stateBChannel)
        let toolResult = await FeatureFlags.withAdr002TargetRefForTests(true) {
            await TrackDispatcher.handle(
                command: "sort_verified",
                params: [
                    "criterion": .string("track_name"),
                    "expected_order": .array(references.reversed().map { .string($0.rawValue) }),
                    "confirmed": .bool(true),
                ],
                router: router,
                cache: StateCache(),
                targetRegistry: registry
            )
        }
        let toolBody = try #require(sharedJSONObject(sharedToolText(toolResult)))
        let mismatchWasStateB = channelResult.isSuccess
            && channelBody["state"] as? String == "B"
            && channelBody["reason"] as? String == HonestContract.UncertainReason.readbackMismatch.rawValue
        let toolRefusedMismatch = toolResult.isError == true
            && toolBody["state"] as? String == "B"
            && toolBody["reason"] as? String == HonestContract.UncertainReason.readbackMismatch.rawValue

        #expect(mismatchWasStateB)
        #expect(toolRefusedMismatch)
    }

    @Test("an expected order names an unavailable track reference before any write")
    func unavailableExpectedReferenceRefusesAndNamesIt() async throws {
        let registry = TargetRegistry()
        let descriptor = TargetDescriptor(trackIndex: 0, trackName: "Studio Grand")
        let liveReference = await registry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )
        let absentReference = "trk_\(UUID().uuidString)"
        let router = ChannelRouter()
        let stateBChannel = TrackSortStateBChannel()
        await router.register(stateBChannel)

        let result = await FeatureFlags.withAdr002TargetRefForTests(true) {
            await TrackDispatcher.handle(
                command: "sort_verified",
                params: [
                    "criterion": .string("track_name"),
                    "expected_order": .array([.string(liveReference.rawValue), .string(absentReference)]),
                    "confirmed": .bool(true),
                ],
                router: router,
                cache: StateCache(),
                targetRegistry: registry
            )
        }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let missingReferences = try #require(body["missing_track_refs"] as? [String])
        let noWriteWasRouted = await stateBChannel.calls.isEmpty
        let terminal = try #require(body["terminal"] as? Bool)
        let humanRequired = try #require(body["human_intervention_required"] as? Bool)
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        let namedAbsentReference = result.isError == true
            && body["reason"] as? String == "expected_order_unknown_track_refs"
            && missingReferences == [absentReference]
            && noWriteWasRouted

        #expect(namedAbsentReference)
        #expect(terminal)
        #expect(!humanRequired)
        #expect(!writeAttempted)
        let hint = try #require(body["hint"] as? String)
        #expect(!hint.localizedCaseInsensitiveContains("re-read"))
        #expect(!hint.localizedCaseInsensitiveContains("retry"))
    }

    @Test("an AXWindows read failure refuses instead of falling through a legacy empty list")
    func windowsReadFailureRefusesBeforePress() throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [2, 1, 0],
            windowsReadStatus: AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        )
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let failedWindowReadWasNotAnEmptyWindowList = result.isSuccess == false
            && body["reason"] as? String == "before_order_read_failed"
            && body["read_failure_stage"] as? String == "AXWindows"
            && body["read_failure_status"] as? String == String(AXError.cannotComplete.rawValue)
            && fixture.actionProbe.pressCount == 0

        #expect(failedWindowReadWasNotAnEmptyWindowList)
    }

    @Test("the two definitive-absence AX statuses still permit the direct arrange-window read")
    func windowsDefinitiveAbsenceIsNotAReadFailure() throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [2, 1, 0],
            windowsReadStatus: AXHelpers.AXStatusError(raw: AXError.noValue.rawValue)
        )
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let definitiveAbsenceWasHandledAsAbsence = result.isSuccess
            && body["state"] as? String == "A"
            && fixture.actionProbe.pressCount == 1

        #expect(definitiveAbsenceWasHandledAsAbsence)
    }

    @Test("an unreadable rail role refuses instead of being flattened to no rail")
    func railRoleReadFailureRefusesBeforePress() throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [2, 1, 0],
            railRoleReadStatus: AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        )
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let unreadableRoleWasNotReportedAsAbsentRail = result.isSuccess == false
            && body["reason"] as? String == "before_order_read_failed"
            && body["read_failure_stage"] as? String == "track_header_candidate_role"
            && body["read_failure_status"] as? String == String(AXError.cannotComplete.rawValue)
            && fixture.actionProbe.pressCount == 0

        #expect(unreadableRoleWasNotReportedAsAbsentRail)
    }

    @Test("an unreadable AXEnabled status is not misreported as a disabled menu item")
    func menuEnabledReadFailureRefusesBeforePress() throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [2, 1, 0],
            menuEnabledReadStatus: AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        )
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let enabledReadFailureWasNamed = result.isSuccess == false
            && body["reason"] as? String == "sort_menu_read_failed"
            && fixture.actionProbe.pressCount == 0

        #expect(enabledReadFailureWasNamed)
    }

    @Test("a disabled measured menu item is refused before it is pressed")
    func disabledMenuItemRefuses() {
        let outcome = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .read(["trk_kick", "trk_bass"]) },
            actuate: { .disabledMenuItem("트랙 이름") },
            after: { .read(["trk_bass", "trk_kick"]) }
        )

        let disabledWasRefused: Bool
        if case .refused(.disabledMenuItem(let label)) = outcome {
            disabledWasRefused = label == "트랙 이름"
        } else {
            disabledWasRefused = false
        }
        #expect(disabledWasRefused)
    }
}

@Suite("#969 cancelled sort must not dispatch the next criterion actuator")
struct Issue969TrackSortCancellationTests {
    private func assertRailOrder(_ fixture: TrackSortAXFixture, indices: [Int]) throws {
        let actualRail = try #require(AXLogicProElements.getTrackHeaders(runtime: fixture.runtime))
        #expect(CFEqual(actualRail, fixture.headerRail))
        let headers: [AXUIElement]
        switch AXLogicProElements.allTrackHeadersVerifiedRead(in: fixture.arrangeWindow, runtime: fixture.runtime) {
        case .read(let observed):
            headers = observed
        case .unavailable, .unreadable:
            Issue.record("The fake sort rail must remain fully readable")
            return
        }
        try #require(headers.count == indices.count)
        for (position, originalIndex) in indices.enumerated() {
            #expect(CFEqual(headers[position], fixture.initialHeaders[originalIndex]))
            let actualName = try #require(AXHelpers.getTitle(headers[position], runtime: fixture.runtime.ax))
            #expect(Array(actualName.utf8) == Array(fixture.initialNames[originalIndex].utf8))
        }
    }

    @Test("entry cancellation leaves the exact rail and names unchanged with no criterion press")
    func alreadyCancelledChildDoesNotPressSortCriterion() async throws {
        let fixture = TrackSortAXFixture(orderAfterPress: [1, 0, 2])
        let child = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            #expect(Task.isCancelled)
            return AccessibilityChannel.defaultSortTracks(
                params: ["criterion": "track_name", "expected_order_json": fixture.expectedOrderJSON],
                runtime: fixture.runtime
            )
        }
        let result = await child.value
        #expect(fixture.actionProbe.enabledReadCallbackCount == 0)
        #expect(fixture.actionProbe.pressCount == 0)
        #expect(!result.isSuccess, "\(result.message)")
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "C")
        let written = try #require(body["write_attempted"] as? Bool)
        #expect(!written)
        try assertRailOrder(fixture, indices: [0, 1, 2])
    }

    @Test("cancellation in the exact enabled read prevents the still-enabled leaf from being pressed")
    func cancellationDuringEnabledReadDoesNotPressSortCriterion() async throws {
        let fixture = TrackSortAXFixture(orderAfterPress: [1, 0, 2], onMenuEnabledRead: {
            withUnsafeCurrentTask { task in task?.cancel() }
            #expect(Task.isCancelled)
        })
        let child = Task {
            #expect(!Task.isCancelled)
            return AccessibilityChannel.defaultSortTracks(
                params: ["criterion": "track_name", "expected_order_json": fixture.expectedOrderJSON],
                runtime: fixture.runtime
            )
        }
        let result = await child.value
        #expect(fixture.actionProbe.enabledReadCallbackCount == 1)
        #expect(fixture.actionProbe.pressCount == 0)
        #expect(!result.isSuccess, "\(result.message)")
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "C")
        let written = try #require(body["write_attempted"] as? Bool)
        #expect(!written)
        try assertRailOrder(fixture, indices: [0, 1, 2])
    }

    @Test("uncancelled unique-name sort presses the measured leaf once and reads Bass Kick Piano")
    func uncancelledAlphabeticSortStillPressesAndReadsExactRail() async throws {
        let fixture = TrackSortAXFixture(orderAfterPress: [1, 0, 2])
        let child = Task {
            #expect(!Task.isCancelled)
            return AccessibilityChannel.defaultSortTracks(
                params: ["criterion": "track_name", "expected_order_json": fixture.expectedOrderJSON],
                runtime: fixture.runtime
            )
        }
        let result = await child.value
        #expect(fixture.actionProbe.enabledReadCallbackCount == 0)
        #expect(fixture.actionProbe.pressCount == 1)
        #expect(result.isSuccess, "\(result.message)")
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "A")
        #expect(body["actuated_criterion"] as? String == "track_name")
        #expect(body["actuated_menu_item_label"] as? String == "트랙 이름")
        #expect(body["after_order"] as? [String] == ["trk_1", "trk_0", "trk_2"])
        let written = try #require(body["write_attempted"] as? Bool)
        #expect(written)
        try assertRailOrder(fixture, indices: [1, 0, 2])
    }
}
