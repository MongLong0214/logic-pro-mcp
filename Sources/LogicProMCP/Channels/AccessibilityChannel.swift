import ApplicationServices
import AppKit
import Foundation

/// Channel that reads and mutates Logic Pro state via the macOS Accessibility API.
/// Primary channel for state queries (transport, tracks, mixer) and UI mutations
/// (clicking mute/solo buttons, reading fader values, etc.)
actor AccessibilityChannel: Channel {
    let id: ChannelID = .accessibility
    private let runtime: Runtime

    // T4: actor state for scanLibraryAll orchestration
    private var libraryScanInProgress: Bool = false
    private var pluginScanInProgress: Bool = false
    // v3.1.0 (T6) — split the single `lastScan` into three source-keyed caches.
    // Panel scans certify Panel presence; disk scans provide the full local
    // candidate catalog; `lastScan` remains populated for legacy callers that
    // only ask for "any recent scan".
    private var lastScan: LibraryRoot? = nil
    private var lastPanelScan: LibraryRoot? = nil
    private var lastDiskScan: LibraryRoot? = nil
    private var lastScanSource: String? = nil
    private var lastRoutedCategory: String? = nil
    private var lastRoutedPreset: String? = nil

    enum MixerTarget {
        case volume
        case pan
    }

    struct PluginInsertSpec: Sendable {
        let canonicalName: String
        let aliases: [String]
        let menuPaths: [[String]]

        func matches(_ observed: String) -> Bool {
            let normalizedObserved = Self.normalize(observed)
            return aliases.map(Self.normalize).contains(normalizedObserved)
        }

        private static func normalize(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    /// v3.0.6 — testable scan-mode dispatch. Centralizes the
    /// "params["mode"] → which scanner" decision so router tests can
    /// assert it without actually running an AX probe or disk walk.
    enum ScanMode: String {
        case ax
        case disk
        case both
    }

    /// Parse the `mode` param for `library.scan_all`. Nil/empty/unknown values
    /// default to `.disk`, the only unattended scanner that does not click
    /// through Logic's live Library panel. Explicit `ax` preserves the legacy
    /// Panel-authoritative scan for callers that can tolerate UI mutation.
    static func parseScanMode(_ raw: String?) -> ScanMode {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return .disk }
        return ScanMode(rawValue: raw) ?? .disk
    }

    static func managedMIDIImportDirectoryPrefixes() -> [String] {
        [SMFWriter.temporaryDirectoryPrefix()]
    }

    static func validatedMIDIImportPath(_ path: String) -> String? {
        guard path.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }

        let requestedURL = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard requestedURL.pathExtension.lowercased() == "mid" else { return nil }

        guard SMFWriter.isManagedTemporaryMIDIFile(requestedURL.path) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: requestedURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return requestedURL.path
    }

    struct Runtime: @unchecked Sendable {
        let isTrusted: @Sendable () -> Bool
        let isLogicProRunning: @Sendable () -> Bool
        let hasVisibleWindow: @Sendable () -> Bool
        let appRoot: @Sendable () -> AXUIElement?
        let transportState: @Sendable () -> ChannelResult
        let toggleTransportButton: @Sendable (String) -> ChannelResult
        let toggleStepInputKeyboard: @Sendable () -> ChannelResult
        let setTempo: @Sendable ([String: String]) -> ChannelResult
        let setCycleRange: @Sendable ([String: String]) -> ChannelResult
        let tracks: @Sendable () -> ChannelResult
        let trackStates: @Sendable () -> [TrackState]?
        /// #1079: the track-state read the background poll makes. It asks `stop` before each
        /// header and, once `stop` says so, gives up the rest of the walk (`yielded`, no states).
        /// Measured 2026-10-02: reading AXHelp of a track header's elements, as `inferTrackType`
        /// does for every header, ended an inline track rename at once, so a walk already under
        /// way when the user starts typing must stop at the next header, not at the next read of
        /// the cycle. The default, for a runtime that does not set it, reads `trackStates` and never
        /// stops.
        let trackStatesStopping: @Sendable (@escaping @Sendable () -> Bool) -> (states: [TrackState]?, yielded: Bool)
        let selectedTrack: @Sendable () -> ChannelResult
        let selectTrack: @Sendable ([String: String]) async -> ChannelResult
        let setTrackToggle: @Sendable ([String: String], String) -> ChannelResult
        let renameTrack: @Sendable ([String: String]) -> ChannelResult
        let sortTracks: @Sendable ([String: String]) -> ChannelResult
        let mixerState: @Sendable () -> ChannelResult
        let mixerStates: (@Sendable (@escaping @Sendable () -> Bool) -> (states: [ChannelStripState]?, yielded: Bool))?
        let channelStrip: @Sendable ([String: String]) -> ChannelResult
        let setMixerValue: @Sendable ([String: String], MixerTarget) -> ChannelResult
        let projectInfo: @Sendable () -> ChannelResult
        let markers: @Sendable () -> ChannelResult
        let openMarkerList: @Sendable () async -> ChannelResult
        let createMarker: @Sendable ([String: String]) async -> ChannelResult
        let renameMarker: @Sendable ([String: String]) async -> ChannelResult
        let deleteMarker: @Sendable ([String: String]) async -> ChannelResult
        let importMIDIFile: @Sendable (String) async -> ChannelResult
        let confirmNewTrackDialog: @Sendable () -> Void
        let canPostEvents: @Sendable () -> Bool
        // v3.1.5 AppleScript-primary helpers (markersAppleScript /
        // projectInfoAppleScript / tracksAppleScript) removed in v3.1.8 —
        // see Issue #7. The dictionary terms they relied on (tracks /
        // markers / tempo) don't exist in Logic 12.x; the project-file
        // fallback now lives in `ResourceHandlers.read*`.
        let logicRuntime: AXLogicProElements.Runtime
        let observationMouseRuntime: AXMouseHelper.Runtime?

        init(
            isTrusted: @escaping @Sendable () -> Bool,
            isLogicProRunning: @escaping @Sendable () -> Bool,
            hasVisibleWindow: @escaping @Sendable () -> Bool = { true },
            appRoot: @escaping @Sendable () -> AXUIElement?,
            transportState: @escaping @Sendable () -> ChannelResult,
            toggleTransportButton: @escaping @Sendable (String) -> ChannelResult,
            toggleStepInputKeyboard: @escaping @Sendable () -> ChannelResult = { .error("toggleStepInputKeyboard not wired") },
            setTempo: @escaping @Sendable ([String: String]) -> ChannelResult,
            setCycleRange: @escaping @Sendable ([String: String]) -> ChannelResult,
            tracks: @escaping @Sendable () -> ChannelResult,
            trackStates: @escaping @Sendable () -> [TrackState]? = { nil },
            trackStatesStopping: (@Sendable (@escaping @Sendable () -> Bool) -> (states: [TrackState]?, yielded: Bool))? = nil,
            selectedTrack: @escaping @Sendable () -> ChannelResult,
            selectTrack: @escaping @Sendable ([String: String]) async -> ChannelResult,
            setTrackToggle: @escaping @Sendable ([String: String], String) -> ChannelResult,
            renameTrack: @escaping @Sendable ([String: String]) -> ChannelResult,
            sortTracks: @escaping @Sendable ([String: String]) -> ChannelResult = { _ in .error("sortTracks not wired") },
            mixerState: @escaping @Sendable () -> ChannelResult,
            mixerStates: (@Sendable (@escaping @Sendable () -> Bool) -> (states: [ChannelStripState]?, yielded: Bool))? = nil,
            channelStrip: @escaping @Sendable ([String: String]) -> ChannelResult,
            setMixerValue: @escaping @Sendable ([String: String], MixerTarget) -> ChannelResult,
            projectInfo: @escaping @Sendable () -> ChannelResult,
            markers: @escaping @Sendable () -> ChannelResult = { .success("[]") },
            openMarkerList: @escaping @Sendable () async -> ChannelResult = { .error("openMarkerList not wired") },
            createMarker: @escaping @Sendable ([String: String]) async -> ChannelResult = { _ in .error("createMarker not wired") },
            renameMarker: @escaping @Sendable ([String: String]) async -> ChannelResult = { _ in .error("renameMarker not wired") },
            deleteMarker: @escaping @Sendable ([String: String]) async -> ChannelResult = { _ in .error("deleteMarker not wired") },
            importMIDIFile: @escaping @Sendable (String) async -> ChannelResult = { _ in .error("importMIDIFile not wired") },
            confirmNewTrackDialog: @escaping @Sendable () -> Void = {
                AccessibilityChannel.sendReturnKey()
            },
            canPostEvents: @escaping @Sendable () -> Bool = {
                CGPreflightPostEventAccess()
            },
            logicRuntime: AXLogicProElements.Runtime = .production,
            observationMouseRuntime: AXMouseHelper.Runtime? = nil
        ) {
            self.isTrusted = isTrusted
            self.isLogicProRunning = isLogicProRunning
            self.hasVisibleWindow = hasVisibleWindow
            self.appRoot = appRoot
            self.transportState = transportState
            self.toggleTransportButton = toggleTransportButton
            self.toggleStepInputKeyboard = toggleStepInputKeyboard
            self.setTempo = setTempo
            self.setCycleRange = setCycleRange
            self.tracks = tracks
            self.trackStates = trackStates
            self.trackStatesStopping = trackStatesStopping ?? { _ in (trackStates(), false) }
            self.selectedTrack = selectedTrack
            self.selectTrack = selectTrack
            self.setTrackToggle = setTrackToggle
            self.renameTrack = renameTrack
            self.sortTracks = sortTracks
            self.mixerState = mixerState
            self.mixerStates = mixerStates
            self.channelStrip = channelStrip
            self.setMixerValue = setMixerValue
            self.projectInfo = projectInfo
            self.markers = markers
            self.openMarkerList = openMarkerList
            self.createMarker = createMarker
            self.renameMarker = renameMarker
            self.deleteMarker = deleteMarker
            self.importMIDIFile = importMIDIFile
            self.confirmNewTrackDialog = confirmNewTrackDialog
            self.canPostEvents = canPostEvents
            self.logicRuntime = logicRuntime
            self.observationMouseRuntime = observationMouseRuntime
        }

        static func axBacked(
            isTrusted: @escaping @Sendable () -> Bool = AXIsProcessTrusted,
            isLogicProRunning: @escaping @Sendable () -> Bool = { ProcessUtils.isLogicProRunning },
            hasVisibleWindow: @escaping @Sendable () -> Bool = { ProcessUtils.hasVisibleWindow() },
            logicRuntime: AXLogicProElements.Runtime = .production,
            controlBarMouseRuntime: AXMouseHelper.Runtime = .production,
            trackRenameMouseRuntime: AXMouseHelper.Runtime = .production,
            trackToggleKeyRuntime: AXMouseHelper.Runtime = .production,
            observationMouseRuntime: AXMouseHelper.Runtime? = nil,
            processRuntime: ProcessUtils.Runtime = .production,
            confirmNewTrackDialog: @escaping @Sendable () -> Void = {
                AccessibilityChannel.sendReturnKey()
            },
            canPostEvents: @escaping @Sendable () -> Bool = {
                CGPreflightPostEventAccess()
            },
            runTempoFallback: @escaping @Sendable (String) -> Bool = { tempo in
                AccessibilityChannel.runTempoFallbackScript(tempo: tempo)
            }
        ) -> Runtime {
            Runtime(
                isTrusted: isTrusted,
                isLogicProRunning: isLogicProRunning,
                hasVisibleWindow: hasVisibleWindow,
                appRoot: { AXLogicProElements.appRoot(runtime: logicRuntime) },
                transportState: { AccessibilityChannel.defaultGetTransportState(runtime: logicRuntime) },
                toggleTransportButton: {
                    AccessibilityChannel.defaultToggleTransportButton(
                        named: $0,
                        runtime: logicRuntime,
                        mouseRuntime: controlBarMouseRuntime
                    )
                },
                toggleStepInputKeyboard: {
                    AccessibilityChannel.defaultToggleStepInputKeyboard(runtime: logicRuntime)
                },
                setTempo: {
                    AccessibilityChannel.defaultSetTempo(
                        params: $0,
                        runtime: logicRuntime,
                        mouseRuntime: controlBarMouseRuntime,
                        runFallback: runTempoFallback
                    )
                },
                setCycleRange: { AccessibilityChannel.defaultSetCycleRange(params: $0, runtime: logicRuntime) },
                tracks: { AccessibilityChannel.defaultGetTracks(runtime: logicRuntime) },
                trackStates: { AccessibilityChannel.defaultGetTrackStates(runtime: logicRuntime) },
                trackStatesStopping: { stop in
                    let read = AccessibilityChannel.defaultGetTrackStates(runtime: logicRuntime, stoppingWhen: stop)
                    return (read.states, read.yielded)
                },
                selectedTrack: { AccessibilityChannel.defaultGetSelectedTrack(runtime: logicRuntime) },
                selectTrack: { await AccessibilityChannel.defaultSelectTrack(params: $0, runtime: logicRuntime) },
                setTrackToggle: {
                    AccessibilityChannel.defaultSetTrackToggle(
                        params: $0,
                        button: $1,
                        runtime: logicRuntime,
                        keyRuntime: trackToggleKeyRuntime,
                        processRuntime: processRuntime
                    )
                },
                renameTrack: {
                    ExactTrackNameAdapter.recordCoupledNameFocusTransport(mouse: trackRenameMouseRuntime,
                        canPostEvents: canPostEvents)
                    return AccessibilityChannel.defaultRenameTrack(
                        params: $0,
                        runtime: logicRuntime,
                        mouseRuntime: trackRenameMouseRuntime,
                        processRuntime: processRuntime
                    )
                },
                sortTracks: { AccessibilityChannel.defaultSortTracks(params: $0, runtime: logicRuntime) },
                mixerState: { AccessibilityChannel.defaultGetMixerState(runtime: logicRuntime) },
                mixerStates: { AccessibilityChannel.defaultGetMixerStates(runtime: logicRuntime, stoppingWhen: $0) },
                channelStrip: { AccessibilityChannel.defaultGetChannelStrip(params: $0, runtime: logicRuntime) },
                setMixerValue: { AccessibilityChannel.defaultSetMixerValue(params: $0, target: $1, runtime: logicRuntime) },
                projectInfo: { AccessibilityChannel.defaultGetProjectInfo(runtime: logicRuntime) },
                markers: { AccessibilityChannel.defaultGetMarkers(runtime: logicRuntime) },
                openMarkerList: { await AccessibilityChannel.defaultOpenMarkerList(runtime: logicRuntime) },
                createMarker: {
                    await AccessibilityChannel.defaultCreateMarker(
                        params: $0,
                        runtime: logicRuntime
                    )
                },
                renameMarker: {
                    await AccessibilityChannel.defaultRenameMarker(
                        params: $0,
                        runtime: logicRuntime
                    )
                },
                deleteMarker: { params in
                    await AccessibilityChannel.defaultDeleteMarker(
                        index: Int(params["index"] ?? "") ?? -1,
                        runtime: logicRuntime
                    )
                },
                importMIDIFile: { await AccessibilityChannel.defaultImportMIDIFile(path: $0, runtime: logicRuntime) },
                confirmNewTrackDialog: confirmNewTrackDialog,
                canPostEvents: canPostEvents,
                logicRuntime: logicRuntime,
                observationMouseRuntime: observationMouseRuntime
            )
        }

        static let production = Runtime.axBacked(observationMouseRuntime: .production)
    }

    init(runtime: Runtime = .production) {
        self.runtime = runtime
    }

    func readTrackStates() -> [TrackState]? {
        runtime.trackStates()
    }

    func readMixerStates(stoppingWhen stop: @escaping @Sendable () -> Bool) -> (states: [ChannelStripState]?, yielded: Bool, provided: Bool) {
        guard let reader = runtime.mixerStates else { return (nil, false, false) }
        let result = reader(stop)
        return (result.states, result.yielded, true)
    }

    /// Request-owned, read-only population collection. The bound window and physical rows,
    /// not cache counts or equal display names, bracket each attempt.
    func readFreshSessionPopulation(
        request: SessionPopulationObservation.Request,
        fileReader: LogicProjectFileReader.Runtime,
        navigationProject: TargetDescriptor? = nil,
        navigationReferenceIsCurrent: @escaping @Sendable () async -> Bool = { true },
        associationReadbackBoundary: @escaping @Sendable () async -> StateCache.CaptureBoundary? = { nil },
        readFocusScope: OwnedTrackStackObservationNavigation.ReadFocusScope? = nil,
        stoppingBeforeAXRead stopBeforeAXRead: (@Sendable () -> Bool)? = nil,
        stoppingWhen stop: @escaping @Sendable () -> Bool
    ) async throws -> SessionPopulationObservation.FreshPopulation {
        try SessionPopulationObservation.requireOwnedAcquisition()
        defer { readFocusScope?.retain(nil) }
        var navigation: OwnedMixerObservationNavigation?
        var stackNavigation: OwnedTrackStackObservationNavigation?
        var originalPresentation: SessionPopulationObservation.FreshPopulation?
        var reusesAssociationPresentation = false
        var routingPresentationRenewal: OriginalHeaderSourceRenewal?
        var association: HeldSelectionAssociation?
        var routingEffects = SessionPopulationObservation.UIEffects()
        var exposedMixerEndEffects = SessionPopulationObservation.UIEffects()
        if request.allowUINavigation, (request.domains.contains(.routing) || request.domains.contains(.strips)),
           !request.domains.contains(.associations),
           case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime.logicRuntime) {
            // Reuse this routing reader's exact existing focus witnesses, not
            // a different track-acquisition contract. No selection/write authority.
            readFocusScope?.retainPassiveRouting(in: window, logic: runtime.logicRuntime,
                includingHeader: request.domains == [.routing])
        }
        if request.allowUINavigation, request.domains.contains(.associations),
           case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime.logicRuntime),
           let candidate = HeldSelectionAssociation(window: window, logic: runtime.logicRuntime,
                expectedProject: navigationProject, requiresProjectReference: request.projectRef != nil,
                allowsSelectedChildRailEntry: true) {
            association = candidate
            readFocusScope?.retainAssociation(candidate)
        }
        if !request.allowUINavigation, request.needsTracks, !request.needsStrips,
           case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime.logicRuntime) {
            readFocusScope?.retainPassiveMixer(in: window, logic: runtime.logicRuntime)
        }
        if request.allowUINavigation, request.needsTracks, request.needsStrips,
           association == nil, runtime.canPostEvents(), let mouse = runtime.observationMouseRuntime,
           case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime.logicRuntime),
           let candidate = OwnedTrackStackObservationNavigation(window: window, logic: runtime.logicRuntime, mouse: mouse,
                expectedProject: navigationProject, requiresProjectReference: request.projectRef != nil,
                referenceIsCurrent: navigationReferenceIsCurrent) {
            // Hold the same original passive control before the Mixer baseline
            // consults its focus guard. No disclosure is changed until that
            // baseline and the existing matching-window checks succeed.
            stackNavigation = candidate
            readFocusScope?.retain(candidate)
        }
        if request.allowUINavigation, request.needsStrips,
           case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime.logicRuntime) {
            if association == nil {
                originalPresentation = try readPresentationBaseline(stoppingWhen: stopBeforeAXRead ?? stop)
            }
            navigation = OwnedMixerObservationNavigation(
                window: window, runtime: runtime.logicRuntime,
                expectedProject: navigationProject, requiresProjectReference: request.projectRef != nil,
                referenceIsCurrent: navigationReferenceIsCurrent)
            // An eligible association already holds the exposed Mixer and its
            // original physical path. A second whole-window discovery is not a
            // reveal prerequisite; later population and custody checks remain.
            if association == nil { await navigation?.reveal(stoppingWhen: stop) }
        }
        if request.allowUINavigation, request.needsTracks, runtime.canPostEvents(),
           let mouse = runtime.observationMouseRuntime,
           case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime.logicRuntime) {
            if let candidate = stackNavigation ?? OwnedTrackStackObservationNavigation(window: window, logic: runtime.logicRuntime, mouse: mouse,
                expectedProject: navigationProject, requiresProjectReference: request.projectRef != nil,
                referenceIsCurrent: navigationReferenceIsCurrent),
               navigation.map({ CFEqual(candidate.window, $0.window)
                   && candidate.title.utf8.elementsEqual($0.title.utf8)
                   && candidate.document.utf8.elementsEqual($0.document.utf8) }) ?? true {
                // A possible stack exposure still needs its original pre-action
                // view baseline. Only the held-association-only path reuses rows.
                if association != nil, originalPresentation == nil {
                    originalPresentation = try readPresentationBaseline(stoppingWhen: stopBeforeAXRead ?? stop)
                }
                stackNavigation = candidate
                readFocusScope?.retain(candidate)
                await candidate.expand(stoppingWhen: stop)
            }
        }
        func mergedEffects(_ stack: SessionPopulationObservation.UIEffects, _ mixer: SessionPopulationObservation.UIEffects) -> SessionPopulationObservation.UIEffects {
            guard stack.navigationPerformed else { return mixer }
            guard mixer.navigationPerformed else { return stack }
            var effects = stack
            effects.attempted += mixer.attempted.filter { !effects.attempted.contains($0) }
            effects.changed += mixer.changed.filter { !effects.changed.contains($0) }
            if mixer.restoration != "restored" { effects.restoration = mixer.restoration }
            effects.reason = stack.reason ?? mixer.reason
            return effects
        }
        do {
            var sharedAcquisitionPerformed = false
            var sharedPairs: [HeldSelectionAssociation.Pair] = []
            var sharedSelected: [AXMixerStripBinding.Binding]?
            let populationReadStarted = ContinuousClock.now
            var finishBookend: ((Bool) throws -> SessionPopulationObservation.FreshPopulation)?
            var firstReadDuration = Duration.zero
            let prepare: (Duration, @escaping (Bool) throws -> SessionPopulationObservation.FreshPopulation) -> Void = { duration, finish in
                firstReadDuration = duration; finishBookend = finish
            }
            let canPrepare = request.allowUINavigation && request.scope == .wholeProject
                && Set(request.domains) == Set([.tracks, .hierarchy, .strips, .associations])
                && association != nil && navigation != nil
                && stackNavigation?.effects.navigationPerformed != true && navigation?.effects.navigationPerformed != true
            var population: SessionPopulationObservation.FreshPopulation = try await readExposedSessionPopulation(
                request: request, fileReader: fileReader,
                exposure: stackNavigation?.effects.navigationPerformed == true ? stackNavigation?.exposure : nil,
                preparingBookend: canPrepare ? prepare : nil,
                stoppingBeforeAXRead: stopBeforeAXRead ?? stop, stoppingWhen: stop
            )
            if let finishBookend {
                if let association, let navigation,
                   population.hiddenTracksShown == true,
                   population.mixerPresentation?.mode == "all", population.mixerPresentation?.typeFilters.count == 8,
                   population.mixerPresentation?.typeFilters.values.allSatisfy({ $0 == true }) == true,
                   let tracks = population.tracks, !tracks.isEmpty, tracks.allSatisfy({ $0.isStackHeader == false }),
                   let strips = population.strips, !strips.isEmpty,
                   CFEqual(association.window, navigation.window),
                   association.document.utf8.elementsEqual(navigation.document.utf8),
                   population.project?.filePath == URL(string: association.document)?.path,
                   population.project?.name.utf8.elementsEqual(Self.projectName(fromWindowTitle: association.title).utf8) == true,
                   tracks.count == association.headers.count,
                   zip(tracks, association.headers).allSatisfy({ state, header in
                       guard let owner = state.physicalBinding else { return false }
                       return CFEqual(owner.window, association.window) && CFEqual(owner.header, header)
                           && owner.document.utf8.elementsEqual(association.document.utf8)
                   }), strips.count == association.strips.count,
                   zip(strips, association.strips).allSatisfy({ state, strip in
                       guard let owner = state.physicalBinding else { return false }
                       return CFEqual(owner.window, association.window) && CFEqual(owner.mixer, association.mixer)
                           && CFEqual(owner.strip, strip) && owner.document.utf8.elementsEqual(association.document.utf8)
                   }), association.permitsRead(), await navigationReferenceIsCurrent(), !stop() {
                    // This first sample is not accepted data. The same complete
                    // reader bookends the excursion before any rows are published.
                    sharedAcquisitionPerformed = true
                    sharedPairs = await association.observe(referenceIsCurrent: navigationReferenceIsCurrent,
                        stoppingWhen: stop, allHeldHeaders: true, populationReadDuration: firstReadDuration)
                    if association.effects.reason == nil {
                        sharedSelected = await navigation.observeWholeStripSelection(readFocusScope: readFocusScope,
                            stoppingBeforeAXRead: stopBeforeAXRead ?? stop, stoppingWhen: stop)
                    }
                }
                population = try finishBookend(sharedAcquisitionPerformed)
            }
            if sharedAcquisitionPerformed {
                population.uiEffects = association?.effects ?? .init()
                if let effects = navigation?.effects, effects.navigationPerformed {
                    population.uiEffects = mergedEffects(population.uiEffects, effects)
                }
                if population.uiEffects.reason != nil || (population.uiEffects.navigationPerformed && population.uiEffects.restoration != "restored") {
                    population.stable = false
                }
                if population.stable {
                    let pairs = sharedPairs.filter { pair in
                        population.tracks?.filter({ $0.physicalBinding?.matches(pair.track) == true }).count == 1
                            && population.strips?.filter({ $0.physicalBinding?.matches(pair.strip) == true }).count == 1
                    }
                    let selectedMatch = sharedSelected.map { selected in
                        population.strips?.count == selected.count
                            && zip(population.strips ?? [], selected).allSatisfy({ $0.physicalBinding?.matches($1) == true })
                    } ?? true
                    if pairs.count == sharedPairs.count, selectedMatch, association?.permitsRead() == true,
                       await navigationReferenceIsCurrent(), !stop() {
                        population.selectionAssociations = pairs
                        population.ownedMixerSelectedPopulation = sharedSelected
                        if !pairs.isEmpty { population.associationReadbackBoundary = await associationReadbackBoundary() }
                    } else { population.stable = false }
                }
            }
            let populationReadDuration = populationReadStarted.duration(to: .now)
            if association != nil, originalPresentation == nil {
                // These fresh independent bookends precede every association
                // selection. Retain them instead of another full view discovery.
                originalPresentation = population
                reusesAssociationPresentation = true
            }
            let mixerNavigationPerformed = navigation?.effects.navigationPerformed == true
            let stackNavigationPerformed = stackNavigation?.effects.navigationPerformed == true
            var associationCapturedAfterStackExposure = false
            var exposedHeaderFocus: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveHeaderReadFocus?
            if association == nil, request.allowUINavigation, request.domains.contains(.associations),
               population.stable, stackNavigationPerformed, !mixerNavigationPerformed,
               let stack = stackNavigation, stack.effects.reason == nil,
               !stack.capturedDisclosureExposures(in: population.tracks).isEmpty,
               stack.permitsHeldPassiveHeaderFocus(),
               let heldFocus = OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveHeaderReadFocus(
                    window: stack.window, logic: runtime.logicRuntime),
               CFEqual(heldFocus.focus, stack.originalFocus),
               let candidate = HeldSelectionAssociation(window: stack.window, logic: runtime.logicRuntime,
                    expectedProject: navigationProject, requiresProjectReference: request.projectRef != nil,
                    allowsSelectedChildRailEntry: true, retainedHeaderFocus: heldFocus,
                    retainedTrackBindings: population.tracks?.compactMap(\.physicalBinding)),
               let tracks = population.tracks, tracks.count == candidate.headers.count,
               zip(tracks, candidate.headers).allSatisfy({ row, header in
                    row.physicalBinding.map { CFEqual($0.window, candidate.window) && CFEqual($0.header, header)
                        && $0.document.utf8.elementsEqual(candidate.document.utf8) } == true
               }), let strips = population.strips, strips.count == candidate.strips.count,
               zip(strips, candidate.strips).allSatisfy({ row, strip in
                    row.physicalBinding.map { CFEqual($0.window, candidate.window) && CFEqual($0.mixer, candidate.mixer)
                        && CFEqual($0.strip, strip) && $0.document.utf8.elementsEqual(candidate.document.utf8) } == true
               }), candidate.permitsRead(), await navigationReferenceIsCurrent(), !stop() {
                // The collapsed baseline could not hold descendants. Acquire
                // only their actual exposed CFs, never a name/count/index join.
                association = candidate
                associationCapturedAfterStackExposure = true
                exposedHeaderFocus = heldFocus
                readFocusScope?.retainAssociation(candidate)
            }
            func collectRouting(_ original: SessionPopulationObservation.FreshPopulation) async throws -> SessionPopulationObservation.FreshPopulation {
                var population = original
                guard request.allowUINavigation, request.domains.contains(.routing), population.stable,
                      !stackNavigationPerformed, !mixerNavigationPerformed else { return population }
                // Retain the actual pre-popup restoration duty. Cancel may expose
                // a transient new-strip layout before the existing renewal settles.
                let inputRestorationGeometry = association?.observedMixerViewportGeometry()
                var checked: [SessionPopulationObservation.HeldCheckedOutput] = []
                var checkedInputs: [SessionPopulationObservation.HeldCheckedInput] = []
                var renewals: [OriginalHeaderSourceRenewal] = []
                var renewedSlots: [AXMixerInputSlotBinding] = []
                // Only the selected capture's actual association may supply
                // fresh popup membership without rediscovery.
                var routingReadScope = request.scope == .selection ? association : nil
                stripReads: for strip in population.strips ?? [] {
                    guard !stop(), await navigationReferenceIsCurrent() else {
                        try SessionPopulationObservation.requireOwnedAcquisition()
                        throw SessionPopulationObservation.AcquisitionError.ownershipLost
                    }
                    // The graph still publishes only checked bus edges. Acquire supported
                    // non-bus before-assignments too; the display label selects a reader,
                    // never supplies assignment, source or destination identity.
                    var candidates: [(input: Bool, ordinal: Int?, nonBusInput: Bool)] = []
                    if let slot = strip.inputSlotBinding, let owner = strip.physicalBinding,
                       slot.owner.matches(owner),
                       let observed = strip.inputObservation, observed.state == .observedSource,
                       let label = observed.source, label.utf8.elementsEqual(slot.source.utf8),
                       InputAssignment.classifiedMenuTitle(label) != nil
                        || AXLocalePolicy.unassignedInputSlotLabel.matches(label, mode: .exact) {
                        candidates.append((true, nil, RoutingGraphPublication.classifyOutputLabel(label).0 != .bus))
                    }
                    if let label = strip.output, OutputAssignment.observed(slotLabel: label) != nil {
                        candidates.append((false, nil, false))
                    }
                    let slots = strip.sendSlots ?? []
                    for slot in slots where slot.state == .occupiedUnknownDestination && slot.ordinal >= 0 {
                        if slots.filter({ $0.ordinal == slot.ordinal }).count == 1 {
                            candidates.append((false, slot.ordinal, false))
                        }
                    }
                    guard !candidates.isEmpty else { continue }
                    guard let originalOwner = strip.physicalBinding,
                          population.strips?.filter({ $0.physicalBinding?.matches(originalOwner) == true }).count == 1 else { continue }
                    let pairs = population.selectionAssociations.filter { $0.strip.matches(originalOwner) }
                    var heldOwner = originalOwner
                    var heldPair = pairs.count == 1 && population.selectionAssociations.filter { candidatePair in
                        pairs.first.map { candidatePair.track.matches($0.track) } ?? false
                    }.count == 1 ? pairs.first : nil
                    for candidate in candidates {
                        guard !stop(), await navigationReferenceIsCurrent() else {
                            try SessionPopulationObservation.requireOwnedAcquisition()
                            throw SessionPopulationObservation.AcquisitionError.ownershipLost
                        }
                        let owner = heldOwner
                        let pair = heldPair
                        let capturedPeerHeaders = request.scope == .selection && pair != nil
                            ? population.selectionAssociations.map(\.track) : nil
                        // A selection request qualifies only its captured pairs,
                        // not the unselected challenge or other raw physical rows.
                        // Whole-project outputs retain their broader observation;
                        // an unpaired input still cannot renew through a header.
                        if request.domains.contains(.associations), pair == nil,
                           request.scope == .selection || candidate.input { continue }
                        // Neutral output acquisition is limited to this capture's
                        // actual unique header/source pair, including whole-project
                        // requests. A No Output caption grants no recovery custody.
                        if !candidate.input, candidate.ordinal == nil, pair == nil,
                           strip.output.flatMap(OutputAssignment.observed(slotLabel:)) == .noOutput { continue }
                        let readingScope = routingReadScope
                        let read = await AXMixerStripBinding.$current.withValue(owner) {
                            if candidate.input {
                                return await AXMixerStripBinding.$outputAssociation.withValue(pair) {
                                    if candidate.nonBusInput {
                                        return await Self.getCheckedInputObservation(runtime: runtime.logicRuntime,
                                            restoringMixerGeometry: inputRestorationGeometry,
                                            observingPopupFocus: { readFocusScope?.retainRoutingPopupFocus($0) },
                                            observingRenewedFocus: { readFocusScope?.retainAssociation($0) },
                                            observingPeerHeaders: capturedPeerHeaders,
                                            readingOriginalScope: readingScope)
                                    }
                                    return await Self.getInputBusObservation(runtime: runtime.logicRuntime,
                                        restoringMixerGeometry: inputRestorationGeometry,
                                        observingPopupFocus: { readFocusScope?.retainRoutingPopupFocus($0) },
                                        observingRenewedFocus: { readFocusScope?.retainAssociation($0) },
                                        observingPeerHeaders: capturedPeerHeaders,
                                        readingOriginalScope: readingScope)
                                }
                            }
                            return await AXMixerStripBinding.$outputAssociation.withValue(pair) {
                                await Self.getOutputObservation(runtime: runtime.logicRuntime, sendOrdinal: candidate.ordinal,
                                    observingSendMode: candidate.ordinal != nil,
                                    requiringSendMode: false,
                                    readingOriginalScope: readingScope,
                                    observingPopupFocus: { readFocusScope?.retainRoutingPopupFocus($0) })
                            }
                        }
                        let receipt = read.result.message.data(using: .utf8).flatMap {
                            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                        }
                        if receipt?["navigation_attempted"] as? Bool == true {
                            population.uiEffects.navigationPerformed = true
                            if !population.uiEffects.attempted.contains("routing_popup") {
                                population.uiEffects.attempted.append("routing_popup")
                            }
                            if receipt?["popup_menu_state"] as? String == "closed"
                                || receipt?["menu_custody_at_read"] as? Bool == true {
                                if !population.uiEffects.changed.contains("routing_popup") {
                                    population.uiEffects.changed.append("routing_popup")
                                }
                            }
                            // A retired focus cannot be CF-equal to its replacement.
                            // Only the actual original selected header/focused-strip
                            // pair and its verified selection inverse can qualify it.
                            let renewedOriginalFocus = read.inputRenewal.map { renewal in
                                guard let association else { return false }
                                return renewal.restoresOriginalFocus(of: association, source: owner,
                                    runtime: runtime.logicRuntime)
                            } ?? false
                            let restored = receipt?["popup_menu_state"] as? String == "closed"
                                && (receipt?["focus_restoration"] as? String == "restored" || renewedOriginalFocus)
                            population.uiEffects.restoration = restored ? "restored" : "partially_restored"
                            if let renewalEffects = read.renewalEffects {
                                // The popup may have closed before a later owned
                                // selection failed to return. Preserve that actual
                                // duty even when no checked input can be retained.
                                population.uiEffects = mergedEffects(population.uiEffects, renewalEffects)
                            }
                            routingEffects = population.uiEffects
                            if population.uiEffects.restoration != "restored" {
                                population.stable = false
                                population.uiEffects.reason = population.uiEffects.reason ?? "routing_popup_not_restored"
                                break stripReads
                            }
                        }
                        if candidate.input {
                            let input = read.inputAssignment ?? read.assignment.flatMap { assignment -> InputAssignment? in
                                guard case .bus(let number) = assignment,
                                      OutputAssignment.busNumbers.contains(number) else { return nil }
                                return .bus(number)
                            }
                            if let input {
                                if let renewal = read.inputRenewal, let slot = read.inputSlot {
                                    if routingReadScope != nil { routingReadScope = renewal.observation }
                                    renewals.append(renewal)
                                    renewedSlots.append(slot)
                                    checkedInputs.append(.init(receiver: renewal.pair.strip, assignment: input))
                                    // Later destinations are independently read from this
                                    // actually renewed source, never the retired owner.
                                    // Earlier checked facts retain their own CF witnesses.
                                    heldOwner = renewal.pair.strip
                                    heldPair = renewal.pair
                                    population.uiEffects = mergedEffects(population.uiEffects, renewal.observation.effects)
                                } else {
                                    checkedInputs.append(.init(receiver: owner, assignment: input))
                                    if let slot = strip.inputSlotBinding { renewedSlots.append(slot) }
                                }
                            }
                        } else if let assignment = read.assignment {
                            checked.append(.init(source: owner, assignment: assignment, sendOrdinal: candidate.ordinal,
                                sendNonRoutingChecks: read.sendNonRoutingChecks, sendMode: read.sendMode,
                                observedBusNumbers: read.observedBusNumbers, sendControl: read.sendControl))
                        }
                    }
                }
                if population.stable, !checked.isEmpty || !checkedInputs.isEmpty {
                    let boundary = renewals.isEmpty
                        ? population.associationReadbackBoundary : await associationReadbackBoundary()
                    var current = try await readExposedSessionPopulation(request: request, fileReader: fileReader,
                        stoppingBeforeAXRead: stopBeforeAXRead ?? stop, stoppingWhen: stop)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let originalValues = try? encoder.encode(population.strips)
                    var valuesAgree = originalValues != nil && originalValues == (try? encoder.encode(current.strips))
                    let protectedPeers = population.selectionAssociations.map(\.strip)
                        + renewals.flatMap { [$0.original, $0.pair.strip] }
                        + checked.map(\.source) + checkedInputs.map(\.receiver)
                    if !valuesAgree, current.stable,
                       request.scope == .selection, request.domains.contains(.associations),
                       let before = population.strips, let after = current.strips,
                       Self.onlyPeerDisplaysBecameReadable(before: before, after: after, protecting: protectedPeers) {
                        // The earlier unreadable display proved no preserved value.
                        // Corroborate the new raw rows once, without another popup
                        // or setter; every known field and protected row stayed exact.
                        let corroborated = try await readExposedSessionPopulation(request: request, fileReader: fileReader,
                            stoppingBeforeAXRead: stopBeforeAXRead ?? stop, stoppingWhen: stop)
                        let oldRows = current.strips ?? [], newRows = corroborated.strips ?? []
                        let sameOwnersAndSlots = oldRows.count == newRows.count && zip(oldRows, newRows).allSatisfy { old, new in
                            guard let owner = old.physicalBinding, new.physicalBinding?.matches(owner) == true else { return false }
                            switch (old.inputSlotBinding, new.inputSlotBinding) {
                            case (nil, nil): return true
                            case (.some(let a), .some(let b)): return a.matches(b)
                            default: return false
                            }
                        }
                        if corroborated.stable, sameOwnersAndSlots,
                           let currentValues = try? encoder.encode(current.strips),
                           let corroboratedValues = try? encoder.encode(corroborated.strips),
                           currentValues == corroboratedValues,
                           current.project?.filePath == corroborated.project?.filePath {
                            current = corroborated
                            valuesAgree = true
                        }
                    }
                    let rows = current.strips ?? []
                    let survivingRenewals = renewals.filter { renewal in
                        rows.filter { $0.physicalBinding?.matches(renewal.pair.strip) == true }.count == 1
                    }
                    let ownersAgree: Bool
                    if survivingRenewals.count == 1, let renewal = survivingRenewals.first,
                       renewals.last?.pair.strip.matches(renewal.pair.strip) == true {
                        // Cancel may retire the entire physical census. These are
                        // new raw rows, not old identities mapped by label/index.
                        // Bookend their exact ordered ownership against the full
                        // census held by the actual renewed selection/inverse.
                        ownersAgree = population.strips?.count == current.strips?.count
                            && rows.count == renewal.observation.strips.count
                            && zip(rows, renewal.observation.strips).allSatisfy { row, strip in
                                guard let owner = row.physicalBinding else { return false }
                                return owner.matches(.init(window: renewal.pair.strip.window,
                                    mixer: renewal.pair.strip.mixer, strip: strip,
                                    document: renewal.pair.strip.document))
                            }
                    } else {
                        ownersAgree = population.strips?.count == current.strips?.count
                            && zip(population.strips ?? [], current.strips ?? []).allSatisfy { old, new in
                                guard let owner = old.physicalBinding else { return new.physicalBinding == nil }
                                return new.physicalBinding?.matches(owner) == true
                            }
                    }
                    let slotsAgree = renewedSlots.allSatisfy { slot in
                        if rows.contains(where: { $0.physicalBinding?.matches(slot.owner) == true }) {
                            return rows.filter { $0.inputSlotBinding?.matches(slot) == true }.count == 1
                        }
                        // A later owned acquisition can retire an earlier checked
                        // receiver again. Discard that fact, never transfer it to
                        // the new row; a still-current owner's changed slot refuses.
                        return renewals.contains { $0.pair.strip.matches(slot.owner) }
                    }
                    if current.stable, valuesAgree, ownersAgree, slotsAgree,
                       survivingRenewals.allSatisfy({ $0.permits(runtime: runtime.logicRuntime) }),
                       current.project?.filePath == population.project?.filePath,
                       await navigationReferenceIsCurrent(), !stop() {
                        var restored = current
                        restored.uiEffects = population.uiEffects
                        restored.checkedOutputs = checked.filter { reading in
                            current.strips?.filter { $0.physicalBinding?.matches(reading.source) == true }.count == 1
                        }
                        restored.checkedInputs = checkedInputs.filter { reading in
                            current.strips?.filter { $0.physicalBinding?.matches(reading.receiver) == true }.count == 1
                        }
                        restored.selectionAssociations = population.selectionAssociations.compactMap { pair in
                            let candidate = renewals.first {
                                $0.original.matches(pair.strip) && $0.originalTrack.matches(pair.track)
                            }?.pair ?? pair
                            // Unrelated retired pairs are discarded, never rebound.
                            return current.strips?.filter { $0.physicalBinding?.matches(candidate.strip) == true }.count == 1
                                ? candidate : nil
                        }
                        restored.associationReadbackBoundary = boundary
                        routingPresentationRenewal = survivingRenewals.count == 1 ? survivingRenewals.first : nil
                        population = restored
                    } else {
                        // Structural diagnostics only: no extra host read, value/name
                        // disclosure, replacement authority or acceptance relaxation.
                        var changedFields: [String] = []
                        if !valuesAgree {
                            for (index, pair) in zip(population.strips ?? [], rows).enumerated() {
                                guard changedFields.count < 4,
                                      let oldData = try? encoder.encode(pair.0), let newData = try? encoder.encode(pair.1),
                                      oldData != newData,
                                      let old = try? JSONSerialization.jsonObject(with: oldData) as? [String: Any],
                                      let new = try? JSONSerialization.jsonObject(with: newData) as? [String: Any] else { continue }
                                let keys = Set(old.keys).union(new.keys).filter {
                                    (old[$0] as? NSObject)?.isEqual(new[$0]) != true
                                }.sorted()
                                changedFields.append("\(index):\(keys.joined(separator: ","))")
                            }
                        }
                        Log.info("Routing population refused: stable=\(current.stable),values=\(valuesAgree),owners=\(ownersAgree),slots=\(slotsAgree),rows=\(population.strips?.count ?? -1)/\(rows.count),renewals=\(renewals.count)/\(survivingRenewals.count),fields=\(changedFields.joined(separator: ";"))", subsystem: "ax")
                        population.stable = false
                        population.uiEffects.reason = "routing_population_moved"
                    }
                }
                return population
            }
            if !sharedAcquisitionPerformed, let association,
               !stackNavigationPerformed || associationCapturedAfterStackExposure,
               navigation?.effects.navigationPerformed != true, population.stable {
                population.selectionAssociations = await association.observe(
                    referenceIsCurrent: navigationReferenceIsCurrent, stoppingWhen: stop,
                    allHeldHeaders: request.scope == .wholeProject,
                    narrowChallengeHeaders: (population.tracks ?? []).filter { $0.isStackHeader == false }
                        .compactMap(\.physicalBinding),
                    populationReadDuration: populationReadDuration)
                population.uiEffects = association.effects
                if association.effects.reason != nil { population.stable = false }
                // A refused association is already unstable and cannot publish
                // any rows. Its own cleanup has run; reacquire a population only
                // to reconcile a successful pair, not to consume the remaining
                // deadline after a verified refusal.
                if association.effects.navigationPerformed, population.stable {
                    let boundary = association.effects.restoration == "restored" && association.effects.reason == nil
                        ? await associationReadbackBoundary() : nil
                    let current = try? await readExposedSessionPopulation(request: request, fileReader: fileReader,
                        exposure: associationCapturedAfterStackExposure ? stackNavigation?.exposure : nil,
                        stoppingBeforeAXRead: stopBeforeAXRead ?? stop, stoppingWhen: stop)
                    func sameValues<T: Encodable>(_ lhs: T?, _ rhs: T?) -> Bool {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                        guard let a = try? encoder.encode(lhs), let b = try? encoder.encode(rhs) else { return false }
                        return a == b
                    }
                    if current?.stable != true || !sameValues(population.project, current?.project)
                        || !sameValues(population.tracks, current?.tracks)
                        || population.tracks?.map(\.selectionReadback) != current?.tracks?.map(\.selectionReadback)
                        || population.tracks?.map(\.hideButtonReadback) != current?.tracks?.map(\.hideButtonReadback)
                        || !sameValues(population.strips, current?.strips) {
                        population.selectionAssociations = []
                        population.stable = false
                        population.uiEffects.reason = "association_population_moved"
                    } else if population.stable, association.permitsRead(), await navigationReferenceIsCurrent(), !stop(),
                              var restoredPopulation = current {
                        // Return the new native rows, not the earlier observation
                        // accepted against a later cache boundary. All physical
                        // owners must still be the original held objects.
                        restoredPopulation.selectionAssociations = population.selectionAssociations
                        restoredPopulation.uiEffects = population.uiEffects
                        restoredPopulation.associationReadbackBoundary = boundary
                        population = restoredPopulation
                    } else {
                        population.selectionAssociations = []
                        population.stable = false
                        population.uiEffects.reason = population.uiEffects.reason ?? "association_population_moved"
                    }
                }
            }
            // Compose only after the original selection observation has restored
            // and reconciled its rows. No pair is inferred for an unobserved strip.
            var selectedMixerPopulation: [AXMixerStripBinding.Binding]?
            if !sharedAcquisitionPerformed, request.allowUINavigation, request.scope == .wholeProject,
               request.needsTracks, request.domains.contains(.strips), population.stable {
                if associationCapturedAfterStackExposure, let heldFocus = exposedHeaderFocus, let association,
                   association.effects.restoration == "restored", association.effects.reason == nil,
                   let owner = OwnedMixerObservationNavigation(window: heldFocus.window, runtime: runtime.logicRuntime,
                        expectedProject: navigationProject, requiresProjectReference: request.projectRef != nil,
                        referenceIsCurrent: navigationReferenceIsCurrent),
                   CFEqual(owner.focus, heldFocus.focus),
                   let tracks = population.tracks, tracks.count == owner.headers.count,
                   zip(tracks, owner.headers).allSatisfy({ row, header in
                       row.physicalBinding.map { CFEqual($0.header, header) && CFEqual($0.window, owner.window)
                           && $0.document.utf8.elementsEqual(owner.document.utf8) } == true
                   }) {
                    let pairs = population.selectionAssociations.filter { CFEqual($0.track.header, heldFocus.header) }
                    if pairs.count == 1, let pair = pairs.first {
                        // The original navigation baseline remains bound to the
                        // collapsed rail. This distinct exposed owner completes
                        // and inverses its focus excursion before stack cleanup.
                        selectedMixerPopulation = await owner.observeWholeStripSelectionFromRetainedHeader(
                            headerFocus: heldFocus, association: association, pair: pair,
                            readFocusScope: readFocusScope,
                            mouse: runtime.canPostEvents() ? runtime.observationMouseRuntime : nil,
                            stoppingBeforeAXRead: stopBeforeAXRead ?? stop, stoppingWhen: stop)
                        exposedMixerEndEffects = owner.effects
                        population.uiEffects = mergedEffects(population.uiEffects, owner.effects)
                        if owner.effects.reason != nil
                            || (owner.effects.navigationPerformed && owner.effects.restoration != "restored") {
                            population.stable = false
                        }
                    }
                } else if let navigation {
                    selectedMixerPopulation = await navigation.observeWholeStripSelection(
                        readFocusScope: readFocusScope, stoppingBeforeAXRead: stopBeforeAXRead ?? stop, stoppingWhen: stop)
                }
            }
            if population.stable, let selected = selectedMixerPopulation {
                let refreshed = try await readExposedSessionPopulation(request: request, fileReader: fileReader,
                    exposure: stackNavigationPerformed ? stackNavigation?.exposure : nil,
                    stoppingBeforeAXRead: stopBeforeAXRead ?? stop, stoppingWhen: stop)
                if refreshed.stable, let states = refreshed.strips, states.count == selected.count,
                   zip(states, selected).allSatisfy({ $0.physicalBinding?.matches($1) == true }) {
                    let pairs = population.selectionAssociations
                    let effects = population.uiEffects
                    population = refreshed
                    population.uiEffects = effects
                    population.selectionAssociations = pairs.filter { pair in
                        refreshed.tracks?.filter({ $0.physicalBinding?.matches(pair.track) == true }).count == 1
                            && states.filter({ $0.physicalBinding?.matches(pair.strip) == true }).count == 1
                    }
                    if population.selectionAssociations.count != pairs.count { population.stable = false }
                    if !population.selectionAssociations.isEmpty {
                        population.associationReadbackBoundary = await associationReadbackBoundary()
                    }
                    population.ownedMixerSelectedPopulation = selected
                } else { population.stable = false }
            }
            population = try await collectRouting(population)
            let disclosureExposures = request.domains.contains(.hierarchy) && population.stable
                ? stackNavigation?.capturedDisclosureExposures(in: population.tracks) ?? [] : []
            let stackEffects = await stackNavigation?.restore(stoppingWhen: stop) ?? .init()
            if let navigation {
                population.uiEffects = mergedEffects(population.uiEffects, await navigation.restore(stoppingWhen: stop))
                if population.uiEffects.navigationPerformed && population.uiEffects.restoration != "restored" {
                    population.stable = false
                }
                // A temporary reveal is not the state the user approves. Bookend the
                // original observation after restoration, without restoring an approved write.
                let restored = reusesAssociationPresentation
                    ? population : try? readPresentationBaseline(stoppingWhen: stopBeforeAXRead ?? stop)
                let matchingPresentation: SessionPopulationObservation.PresentationBinding? = {
                    guard let original = originalPresentation?.presentationBinding,
                          let current = restored?.presentationBinding else { return nil }
                    if original.matches(current) { return original }
                    guard reusesAssociationPresentation, let association, let renewal = routingPresentationRenewal,
                          original.matches(current, renewedThrough: renewal, originalAssociation: association)
                    else { return nil }
                    // Retain the freshly qualified owner, never the retired focus.
                    return current
                }()
                if let originalPresentation, let restored,
                   let observed = originalPresentation.presentationObservation,
                   let restoredObservation = restored.presentationObservation,
                   observed.matchesViewTransport(restoredObservation),
                   let matchingPresentation {
                    population.presentationObservation = .init(mixerVisible: observed.mixerVisible,
                        isPlaying: observed.isPlaying, isRecording: observed.isRecording,
                        uiLocale: observed.uiLocale == restoredObservation.uiLocale ? observed.uiLocale : nil)
                    population.presentationBinding = matchingPresentation
                } else {
                    population.presentationObservation = .init(mixerVisible: nil, isPlaying: nil, isRecording: nil)
                    population.presentationBinding = nil
                }
            } else if request.allowUINavigation && request.needsStrips {
                population.uiEffects.reason = "navigation_baseline_unavailable"
            }
            population.uiEffects = mergedEffects(stackEffects, population.uiEffects)
            if stackEffects.navigationPerformed {
                population.hasCapturedTrackExposure = true
                // An ended capture is not a current cache reading. Independently acquire
                // the restored rail; failure never falls back to the expanded rows.
                if stackEffects.restoration == "restored" || stackEffects.restoration == "partially_restored",
                   let current = try? await readExposedSessionPopulation(request: request, fileReader: fileReader,
                    stoppingBeforeAXRead: stopBeforeAXRead ?? stop, stoppingWhen: stop), current.stable,
                   let currentPath = current.project?.filePath, let observedPath = population.project?.filePath,
                   currentPath.utf8.elementsEqual(observedPath.utf8),
                   stackNavigation?.matchesRestoredTracks(current.tracks) == true {
                    population.restoredTracks = current.tracks
                }
                if population.restoredTracks == nil || stackEffects.restoration != "restored" { population.stable = false }
            }
            if population.stable, stackEffects.restoration == "restored" {
                population.disclosureExposures = disclosureExposures
            }
            try SessionPopulationObservation.requireOwnedAcquisition()
            return population
        } catch {
            Log.info("Population acquisition failed: \(error)", subsystem: "ax")
            let stack = await stackNavigation?.restoreAfterInterruptedRead(stoppingWhen: stop) ?? .init()
            let mixer = await navigation?.restore(stoppingWhen: stop) ?? .init()
            let effects = mergedEffects(routingEffects,
                mergedEffects(exposedMixerEndEffects,
                    mergedEffects(association?.effects ?? .init(), mergedEffects(stack, mixer))))
            throw SessionPopulationObservation.NavigationAcquisitionError(cause: error, effects: effects)
        }
    }

    /// Host metadata is captured beside the same held project's window/app. It does not
    /// qualify population or a sort leaf; unknown metadata does not poison view reads.
    private func readObservedHost(in window: AXUIElement, checking check: () throws -> Void) throws
        -> (locale: String?, version: ProcessUtils.LogicHostObservation?) {
        try check()
        let logic = runtime.logicRuntime
        guard let pid = logic.logicProPID(), let app = AXLogicProElements.appRoot(runtime: logic),
              let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: logic.ax),
              CFEqual(main, window) else { return (nil, nil) }
        try check()
        let reading = AXLogicProElements.logicUILocaleIdentifierRead(runtime: logic)
        let version = logic.observeHost(pid)
        try check()
        guard logic.logicProPID() == pid, let currentApp = AXLogicProElements.appRoot(runtime: logic), CFEqual(app, currentApp),
              let current: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: logic.ax),
              CFEqual(current, window) else { return (nil, nil) }
        try check()
        if case .locale(let locale) = reading { return (locale, version) }
        return (nil, version)
    }

    private func readPresentationBaseline(stoppingWhen stop: @Sendable () -> Bool) throws -> SessionPopulationObservation.FreshPopulation? {
        func check() throws {
            try SessionPopulationObservation.requireOwnedAcquisition()
            if stop() { throw SessionPopulationObservation.AcquisitionError.textEditing }
        }
        try check()
        let logic = runtime.logicRuntime
        guard case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: logic),
              let title = AXHelpers.getTitle(window, runtime: logic.ax),
              case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic) else { return nil }
        let hostBefore = try readObservedHost(in: window, checking: check)
        let lookup = try AXLogicProElements.mixerPopulationAreaLookup(in: window, runtime: logic,
            requiresCompleteAbsence: true, checking: check)
        let transport = try AXLogicProElements.observedTransportActivity(in: window, runtime: logic, checking: check)
        try check()
        guard case .found(let current) = AXLogicProElements.arrangeWindowRead(runtime: logic), CFEqual(window, current),
              AXHelpers.getTitle(window, runtime: logic.ax)?.utf8.elementsEqual(title.utf8) == true,
              case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
              currentDocument.utf8.elementsEqual(document.utf8) else { return nil }
        let hostAfter = try readObservedHost(in: window, checking: check)
        let locale = hostBefore.locale == hostAfter.locale ? hostBefore.locale : nil
        try check()
        let visible: Bool?
        switch lookup.lookup {
        case .found: visible = true
        case .notFound: visible = false
        case .childrenUnread: visible = nil
        }
        let now = Date()
        return .init(project: nil, tracks: nil, strips: nil, fileTrackCount: nil, beganAt: now, endedAt: now, stable: true,
            presentationObservation: .init(mixerVisible: visible, isPlaying: transport?.isPlaying, isRecording: transport?.isRecording,
                uiLocale: locale),
            hostObservation: hostBefore.version == hostAfter.version ? hostBefore.version : nil,
            presentationBinding: .init(window: window, title: title, document: document,
                mixer: lookup.binding?.mixer, transport: transport, runtime: logic, uiLocale: locale,
                mixerOwners: lookup.binding?.owners ?? []))
    }

    /// Only unknown, unrequested routing displays may gain information. Callers
    /// retain complete native custody and corroborate the result with a second
    /// fresh read; this comparison grants no binding or mutation authority.
    static func onlyPeerDisplaysBecameReadable(before: [ChannelStripState], after: [ChannelStripState],
                                             protecting protected: [AXMixerStripBinding.Binding]) -> Bool {
        guard before.count == after.count else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var refined = false
        for (old, new) in zip(before, after) {
            guard let oldBytes = try? encoder.encode(old), let newBytes = try? encoder.encode(new) else { return false }
            if oldBytes == newBytes { continue }
            guard let oldOwner = old.physicalBinding, let newOwner = new.physicalBinding,
                  !protected.contains(where: { $0.matches(oldOwner) || $0.matches(newOwner) }) else { return false }
            var comparable = new
            if old.input == nil, old.inputObservation == .init(state: .unreadable, source: nil),
               new.inputObservation?.state == .observedSource,
               let source = new.inputObservation?.source, !source.isEmpty,
               new.input?.utf8.elementsEqual(source.utf8) == true,
               let slot = new.inputSlotBinding, slot.owner.matches(newOwner),
               slot.source.utf8.elementsEqual(source.utf8) {
                comparable.input = old.input; comparable.inputObservation = old.inputObservation
            }
            // The generic Output caption identifies no control or destination.
            if let oldOutput = old.output,
               AXLocalePolicy.outputPopupOutputSubmenuTitle.matches(oldOutput, mode: .exact),
               OutputAssignment.observed(slotLabel: oldOutput) == nil,
               let newOutput = new.output, OutputAssignment.observed(slotLabel: newOutput) != nil {
                comparable.output = old.output
            }
            guard (try? encoder.encode(comparable)) == oldBytes else { return false }
            refined = true
        }
        return refined
    }

    private func readExposedSessionPopulation(
        request: SessionPopulationObservation.Request,
        fileReader: LogicProjectFileReader.Runtime,
        exposure: AXTrackBinding.Exposure? = nil,
        preparingBookend: ((Duration, @escaping (Bool) throws -> SessionPopulationObservation.FreshPopulation) -> Void)? = nil,
        stoppingBeforeAXRead stopBeforeAXRead: @escaping @Sendable () -> Bool,
        stoppingWhen stop: @escaping @Sendable () -> Bool
    ) async throws -> SessionPopulationObservation.FreshPopulation {
        let beganAt = Date()
        let logic = runtime.logicRuntime
        let wantsTracks = request.needsTracks
        let wantsStrips = request.needsStrips
        typealias HiddenView = AXLogicProElements.HiddenTrackViewRead
        func sameHiddenView(_ lhs: HiddenView?, _ rhs: HiddenView?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): return true
            case (.some(let a), .some(let b)): return CFEqual(a.control, b.control) && a.shown == b.shown
            default: return false
            }
        }
        // Reuse this read's physical headers. No independent rail scanner or Help
        // query: the native legend and header scroll live in sibling split groups.
        func readHiddenView(_ headers: [AXUIElement]?, in window: AXUIElement) -> HiddenView? {
            guard let headers else { return nil }
            let reading = AXLogicProElements.hiddenTrackViewRead(headers: headers, in: window, runtime: logic, exposure: exposure)
            exposure?.observeHiddenView(control: reading?.control, shown: reading?.shown)
            return reading
        }
        struct SinglePageEnd {
            let rail: AXUIElement
            let headerScroll: AXUIElement
            let workspace: AXUIElement
            let content: AXUIElement
            let scrollbar: AXUIElement
            let viewport: CGRect
            let frames: [CGRect]
            func matches(_ other: Self?) -> Bool {
                guard let other else { return false }
                return CFEqual(rail, other.rail) && CFEqual(headerScroll, other.headerScroll)
                    && CFEqual(workspace, other.workspace) && CFEqual(content, other.content)
                    && CFEqual(scrollbar, other.scrollbar) && viewport == other.viewport && frames == other.frames
            }
        }
        // No scrolling, Help or inferred membership. A matching saved count may
        // use this independent end only for the fully shown, unvirtualized page.
        func readSinglePageEnd(_ headers: [AXUIElement]?, tracks: [TrackState]?,
                               hiddenView: HiddenView?, in window: AXUIElement) throws -> SinglePageEnd? {
            guard request.scope == .wholeProject, hiddenView?.shown == true,
                  let headers, !headers.isEmpty, let tracks, tracks.count == headers.count,
                  tracks.allSatisfy({ $0.isStackHeader == false || ($0.isStackHeader == true && $0.stackCollapsed == false) }),
                  let rail: AXUIElement = AXHelpers.getAttribute(headers[0], kAXParentAttribute as String, runtime: logic.ax),
                  let headerScroll: AXUIElement = AXHelpers.getAttribute(rail, kAXParentAttribute as String, runtime: logic.ax),
                  AXHelpers.getRole(headerScroll, runtime: logic.ax) == kAXScrollAreaRole as String,
                  let split: AXUIElement = AXHelpers.getAttribute(headerScroll, kAXParentAttribute as String, runtime: logic.ax),
                  AXHelpers.getRole(split, runtime: logic.ax) == kAXSplitGroupRole as String,
                  case .success(let siblings) = AXHelpers.childrenResult(split, runtime: logic.ax),
                  siblings.filter({ CFEqual($0, headerScroll) }).count == 1 else { return nil }
            func frame(_ element: AXUIElement) -> CGRect? {
                let geometry = AXHelpers.getNonHelpAttributes(element,
                    [kAXPositionAttribute, kAXSizeAttribute] as [String], runtime: logic.ax,
                    permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
                guard case .success(.some(let p)) = geometry[0],
                      case .success(.some(let s)) = geometry[1],
                      let point = AXHelpers.point(fromRawAttribute: p), let size = AXHelpers.size(fromRawAttribute: s),
                      point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                      size.width > 0, size.height > 0 else { return nil }
                return CGRect(origin: point, size: size)
            }
            var candidates: [(AXUIElement, AXUIElement, [AXUIElement])] = []
            for sibling in siblings where !CFEqual(sibling, headerScroll) {
                try checkAXRead()
                guard let role = AXHelpers.getRole(sibling, runtime: logic.ax) else { return nil }
                guard role == kAXScrollAreaRole as String else { continue }
                guard case .success(let children) = AXHelpers.childrenResult(sibling, runtime: logic.ax) else { return nil }
                var contents: [AXUIElement] = []
                for child in children {
                    guard let role = AXHelpers.getRole(child, runtime: logic.ax) else { return nil }
                    if role == kAXGroupRole as String,
                       AXLocalePolicy.trackContentExplicit.matches(AXHelpers.getDescription(child, runtime: logic.ax)) {
                        contents.append(child)
                    }
                }
                if contents.count == 1 { candidates.append((sibling, contents[0], children)) }
            }
            guard candidates.count == 1, let (workspace, content, children) = candidates.first,
                  let viewport = frame(headerScroll) else { return nil }
            var vertical: [AXUIElement] = []
            for child in children where AXHelpers.getRole(child, runtime: logic.ax) == kAXScrollBarRole as String {
                guard let orientation: String = AXHelpers.getAttribute(child, kAXOrientationAttribute as String, runtime: logic.ax) else { return nil }
                if orientation == kAXVerticalOrientationValue as String { vertical.append(child) }
            }
            guard vertical.count == 1, let scrollbar = vertical.first else { return nil }
            var frames: [CGRect] = []
            for header in headers {
                try checkAXRead()
                guard let current = frame(header), viewport.contains(current),
                      frames.last.map({ $0.maxY <= current.minY }) ?? true else { return nil }
                frames.append(current)
            }
            guard case .success(let currentRows) = AXHelpers.childrenResult(rail, runtime: logic.ax),
                  currentRows.count == headers.count && zip(currentRows, headers).allSatisfy({ CFEqual($0, $1) }),
                  case .success(let currentChildren) = AXHelpers.childrenResult(workspace, runtime: logic.ax),
                  currentChildren.count == children.count && zip(currentChildren, children).allSatisfy({ CFEqual($0, $1) }),
                  let owner: AXUIElement = AXHelpers.getAttribute(scrollbar, kAXWindowAttribute as String, runtime: logic.ax), CFEqual(owner, window),
                  let parent: AXUIElement = AXHelpers.getAttribute(scrollbar, kAXParentAttribute as String, runtime: logic.ax), CFEqual(parent, workspace),
                  case .success(.some(let enabled)) = AXHelpers.getAttributeResult(scrollbar, kAXEnabledAttribute as String,
                    runtime: logic.ax) as Result<NSNumber?, AXHelpers.AXStatusError>, enabled.doubleValue == 0,
                  case .success(.some(let value)) = AXHelpers.getAttributeResult(scrollbar, kAXValueAttribute as String,
                    runtime: logic.ax) as Result<NSNumber?, AXHelpers.AXStatusError>,
                  // Logic exposes either endpoint for a disabled, non-scrollable page.
                  // Interior/invalid values still cannot establish the independent end.
                  value.doubleValue == 0 || value.doubleValue == 1 else { return nil }
            // Renew deciding metadata/geometry after the value read: an old
            // scrollbar can still answer after its actual owner replaced it.
            guard AXHelpers.getRole(scrollbar, runtime: logic.ax) == kAXScrollBarRole as String,
                  let orientationAfter: String = AXHelpers.getAttribute(scrollbar, kAXOrientationAttribute as String, runtime: logic.ax),
                  orientationAfter == kAXVerticalOrientationValue as String,
                  let ownerAfter: AXUIElement = AXHelpers.getAttribute(scrollbar, kAXWindowAttribute as String, runtime: logic.ax), CFEqual(ownerAfter, window),
                  let parentAfter: AXUIElement = AXHelpers.getAttribute(scrollbar, kAXParentAttribute as String, runtime: logic.ax), CFEqual(parentAfter, workspace),
                  frame(headerScroll) == viewport, zip(headers, frames).allSatisfy({ frame($0) == $1 }),
                  case .success(.some(let enabledAfter)) = AXHelpers.getAttributeResult(scrollbar, kAXEnabledAttribute as String,
                    runtime: logic.ax) as Result<NSNumber?, AXHelpers.AXStatusError>, enabledAfter.doubleValue == 0,
                  case .success(let decidingRows) = AXHelpers.childrenResult(rail, runtime: logic.ax),
                  decidingRows.count == headers.count && zip(decidingRows, headers).allSatisfy({ CFEqual($0, $1) }),
                  case .success(let decidingChildren) = AXHelpers.childrenResult(workspace, runtime: logic.ax),
                  decidingChildren.count == children.count && zip(decidingChildren, children).allSatisfy({ CFEqual($0, $1) })
            else { return nil }
            return .init(rail: rail, headerScroll: headerScroll, workspace: workspace, content: content,
                scrollbar: scrollbar, viewport: viewport, frames: frames)
        }
        struct SelectedTrackRead {
            let rail: AXUIElement
            let headers: [AXUIElement]
        }
        // This witnesses only the selected set, not the end of the whole rail.
        // Unknown, foreign or duplicated selected children cannot certify it.
        func readSelectedTracks(_ headers: [AXUIElement]?, states: [TrackState]?, in window: AXUIElement) throws -> SelectedTrackRead? {
            guard request.scope == .selection, let headers, let states, states.count == headers.count,
                  let rail = AXLogicProElements.uniqueTrackHeaderRail(in: window, runtime: logic,
                    observingExposure: exposure) else { return nil }
            try check()
            func selectedChildren() -> [AXUIElement]? {
                guard case .success(.some(let children)) = AXHelpers.getAttributeResult(rail,
                    kAXSelectedChildrenAttribute as String, runtime: logic.ax) as Result<[AXUIElement]?, AXHelpers.AXStatusError> else { return nil }
                return children
            }
            guard let selected = selectedChildren(),
                  case .success(let children) = AXHelpers.childrenResult(rail, runtime: logic.ax) else { return nil }
            exposure?.observeHeaders(children)
            var observed: [AXUIElement] = []
            var seen: [AXUIElement] = []
            for (header, state) in zip(headers, states) {
                try check()
                guard !seen.contains(where: { CFEqual($0, header) }),
                      children.filter({ CFEqual($0, header) }).count == 1,
                      let parent: AXUIElement = AXHelpers.getAttribute(header, kAXParentAttribute as String, runtime: logic.ax),
                      CFEqual(parent, rail),
                      case .success(.some(let isSelected)) = AXHelpers.getAttributeResult(header,
                        kAXSelectedAttribute as String, runtime: logic.ax) as Result<Bool?, AXHelpers.AXStatusError>,
                      state.selectionReadback == isSelected,
                      selected.filter({ CFEqual($0, header) }).count == (isSelected ? 1 : 0) else { return nil }
                seen.append(header)
                if isSelected { observed.append(header) }
            }
            guard observed.count == selected.count, let final = selectedChildren(),
                  final.count == selected.count,
                  zip(final, selected).allSatisfy({ CFEqual($0, $1) }) else { return nil }
            try check()
            return .init(rail: rail, headers: observed)
        }
        func sameSelectedTracks(_ lhs: SelectedTrackRead?, _ rhs: SelectedTrackRead?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): return true
            case (.some(let a), .some(let b)):
                return CFEqual(a.rail, b.rail) && sameElements(a.headers, b.headers)
            default: return false
            }
        }
        struct Read {
            let title: String?
            let document: String?
            let documentReadable: Bool
            let headers: [AXUIElement]?
            let mixer: AXUIElement?
            let mixerBinding: AXLogicProElements.MixerAreaBinding?
            let mixerOwners: [AXUIElement]
            let stripElements: [AXUIElement]?
            let tracks: [TrackState]?
            let strips: [ChannelStripState]?
            let presentation: AXLogicProElements.MixerPresentationRead?
            let mixerVisible: Bool?
            let transport: AXLogicProElements.ObservedTransportActivity?
            let uiLocale: String?
            let hostObservation: ProcessUtils.LogicHostObservation?
            let hiddenView: HiddenView?
            let singlePageEnd: SinglePageEnd?
            let selectedTracks: SelectedTrackRead?
        }
        func check() throws {
            try SessionPopulationObservation.requireOwnedAcquisition()
            if stop() { throw SessionPopulationObservation.AcquisitionError.textEditing }
        }
        // The poller can separate cheap lifecycle/latch checks from full focus
        // acquisition. Other callers retain their original per-read stop callback.
        func checkAXRead() throws {
            try SessionPopulationObservation.requireOwnedAcquisition()
            if stopBeforeAXRead() { throw SessionPopulationObservation.AcquisitionError.textEditing }
        }
        func read(in window: AXUIElement) throws -> Read {
            try check()
            let title = AXHelpers.getTitle(window, runtime: logic.ax)
            let document: String?
            let documentReadable: Bool
            switch AXLogicProElements.projectPickerDocumentRead(window, runtime: logic) {
            case .success(let value): document = value; documentReadable = true
            case .failure: document = nil; documentReadable = false
            }
            try check()
            var headers: [AXUIElement]?
            var tracks: [TrackState]?
            if wantsTracks,
               case .read(let observed) = AXLogicProElements.allTrackHeadersRead(in: window, runtime: logic,
                   observingExposure: exposure) {
                headers = observed
                exposure?.observeHeaders(observed)
                tracks = Self.readTrackStates(from: observed, in: window, runtime: logic, exposure: exposure,
                    readingTypeHelp: false, stoppingWhen: stop).states
            }
            try check()
            var mixer: AXUIElement?
            var stripElements: [AXUIElement]?
            var strips: [ChannelStripState]?
            var presentation: AXLogicProElements.MixerPresentationRead?
            let lookup = try AXLogicProElements.mixerPopulationAreaLookup(in: window, runtime: logic,
                requiresCompleteAbsence: true, observingExposure: exposure, checking: checkAXRead)
            let mixerVisible: Bool?
            switch lookup.lookup {
            case .found: mixerVisible = true
            case .notFound: mixerVisible = false
            case .childrenUnread: mixerVisible = nil
            }
            mixer = lookup.binding?.mixer
            if wantsStrips {
                try check()
                if let binding = lookup.binding {
                    mixer = binding.mixer
                    presentation = try AXLogicProElements.mixerPresentationRead(binding: binding, runtime: logic.ax, checking: checkAXRead)
                    try check()
                    if let enumeration = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: binding.mixer, runtime: logic.ax) {
                        stripElements = enumeration.strips
                        strips = Self.readChannelStrips(from: enumeration.strips, runtime: logic,
                            window: window, mixer: binding.mixer,
                            // Routing/association bookends still need physical strips,
                            // but classify inserts only for a requested strip footprint.
                            // Default and explicit strip requests retain the full chain.
                            readingPlugins: request.domains.contains(.strips),
                            readingRouting: request.domains.contains(.strips) || request.domains.contains(.routing),
                            readingScalarHelp: false, stoppingWhen: stop)
                    }
                }
            }
            let transport = try AXLogicProElements.observedTransportActivity(in: window, runtime: logic,
                observingExposure: exposure, checking: checkAXRead)
            let host = try readObservedHost(in: window, checking: checkAXRead)
            let hiddenView = wantsTracks ? readHiddenView(headers, in: window) : nil
            let singlePageEnd = wantsTracks ? try readSinglePageEnd(headers, tracks: tracks, hiddenView: hiddenView, in: window) : nil
            let selectedTracks = wantsTracks ? try readSelectedTracks(headers, states: tracks, in: window) : nil
            try check()
            return Read(title: title, document: document, documentReadable: documentReadable,
                        headers: headers, mixer: mixer, mixerBinding: lookup.binding, mixerOwners: lookup.binding?.owners ?? [],
                        stripElements: stripElements, tracks: tracks, strips: strips,
                        presentation: presentation, mixerVisible: mixerVisible, transport: transport, uiLocale: host.locale,
                        hostObservation: host.version,
                        hiddenView: hiddenView, singlePageEnd: singlePageEnd, selectedTracks: selectedTracks)
        }
        func sameElements(_ lhs: [AXUIElement]?, _ rhs: [AXUIElement]?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): return true
            case (.some(let a), .some(let b)):
                return a.count == b.count && zip(a, b).allSatisfy { CFEqual($0, $1) }
            default: return false
            }
        }
        func sameBytes(_ lhs: String?, _ rhs: String?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): return true
            case (.some(let a), .some(let b)): return a.utf8.elementsEqual(b.utf8)
            default: return false
            }
        }
        func sameValues<T: Encodable>(_ lhs: T?, _ rhs: T?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): return true
            case (.some(let a), .some(let b)):
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard let encodedA = try? encoder.encode(a), let encodedB = try? encoder.encode(b) else { return false }
                return encodedA == encodedB
            default: return false
            }
        }
        var last = SessionPopulationObservation.FreshPopulation(
            project: nil, tracks: nil, strips: nil, fileTrackCount: nil,
            beganAt: beganAt, endedAt: beganAt, stable: false
        )
        // A retry may stabilize the population, but must not adopt another input control
        // after this acquisition observed custody loss on the same physical owner.
        var changedInputOwners: [AXMixerStripBinding.Binding] = []
        var firstInputSlots: [AXMixerInputSlotBinding] = []
        func observeInputContinuity(_ before: [ChannelStripState]?, _ after: [ChannelStripState]?) {
            // A stable pair can still precede another population retry. Keep its first
            // native witness; an unread population cannot erase an earlier deciding read.
            for strip in (before ?? []) + (after ?? []) {
                guard let slot = strip.inputSlotBinding else { continue }
                let initial = firstInputSlots.filter { $0.owner.matches(slot.owner) }
                if initial.isEmpty { firstInputSlots.append(slot) }
                else if !initial.allSatisfy({ $0.matches(slot) }),
                        !changedInputOwners.contains(where: { $0.matches(slot.owner) }) {
                    changedInputOwners.append(slot.owner)
                }
            }
            for strip in before ?? [] {
                guard let owner = strip.physicalBinding else { continue }
                let matches = (after ?? []).filter { $0.physicalBinding?.matches(owner) == true }
                guard matches.count == 1 else { continue }
                let sameInput: Bool
                switch (strip.inputSlotBinding, matches[0].inputSlotBinding) {
                case (nil, nil): sameInput = true
                case (.some(let a), .some(let b)): sameInput = a.matches(b)
                default: sameInput = false
                }
                if !sameInput, !changedInputOwners.contains(where: { $0.matches(owner) }) {
                    changedInputOwners.append(owner)
                }
            }
        }
        func inputSafeStates(_ states: [ChannelStripState]?) -> [ChannelStripState]? {
            states?.map { state in
                guard let owner = state.physicalBinding,
                      changedInputOwners.contains(where: { $0.matches(owner) }) else { return state }
                var unknown = state
                unknown.inputSlotBinding = nil
                unknown.input = nil
                unknown.inputObservation = .init(state: .unreadable, source: nil)
                return unknown
            }
        }
        for _ in 0..<3 {
            try check()
            guard case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: logic) else {
                return .init(project: nil, tracks: nil, strips: nil, fileTrackCount: nil,
                             beganAt: beganAt, endedAt: Date(), stable: true)
            }
            let firstReadStarted = ContinuousClock.now
            let before = try read(in: window)
            var path: String?
            if let document = before.document, let url = URL(string: document), url.isFileURL,
               url.host == nil || url.host == "" || url.host == "localhost",
               let validated = LogicProjectFileReader.validatePath(url.path) {
                path = validated.bundle.path
            }
            let metadata: LogicProjectMetadata?
            if let path { metadata = await LogicProjectFileReader.readPath(path, runtime: fileReader) }
            else { metadata = nil }
            try check()
            let first = SessionPopulationObservation.FreshPopulation(
                project: before.title.map { .init(name: Self.projectName(fromWindowTitle: $0), filePath: path, source: "ax_request_read") },
                tracks: before.tracks, strips: before.strips, fileTrackCount: metadata?.trackCount,
                beganAt: beganAt, endedAt: Date(), stable: false,
                mixerPresentation: before.presentation?.presentation, hiddenTracksShown: before.hiddenView?.shown)
            func finishBookend(_ sharedRead: Bool) throws -> SessionPopulationObservation.FreshPopulation {
                try check()
                let after = try read(in: window)
                observeInputContinuity(before.strips, after.strips)
                let beforeStrips = inputSafeStates(before.strips)
                let afterStrips = inputSafeStates(after.strips)
                let sameWindow: Bool
                if case .found(let current) = AXLogicProElements.arrangeWindowRead(runtime: logic) {
                    sameWindow = CFEqual(window, current)
                } else { sameWindow = false }
                // The retained arrays precede the row reads. A disclosure can close during
                // the last row's deciding read while both copied arrays still look equal.
                var currentHeaders: [AXUIElement]?
                var sameStackExposure = true
                if wantsTracks, after.tracks != nil {
                    try check()
                    if case .read(let observed) = AXLogicProElements.allTrackHeadersRead(in: window, runtime: logic,
                        observingExposure: exposure) {
                        currentHeaders = observed
                        exposure?.observeHeaders(observed)
                        if let states = after.tracks, states.count == observed.count {
                            for (header, state) in zip(observed, states) {
                                try check()
                                let stack = AXValueExtractors.extractTrackStackState(from: header, runtime: logic.ax,
                                    observingChildren: { exposure?.observeDisclosureChildren(header: header, children: $0, selected: $1) })
                                exposure?.observeStackState(header: header, isStackHeader: stack.isStackHeader, collapsed: stack.collapsed)
                                if stack.isStackHeader != state.isStackHeader || stack.collapsed != state.stackCollapsed {
                                    sameStackExposure = false
                                }
                                if Self.readTrackHideButton(header, in: window, runtime: logic, exposure: exposure) != state.hideButtonReadback {
                                    sameStackExposure = false
                                }
                            }
                        } else { sameStackExposure = false }
                    } else { sameStackExposure = false }
                    try check()
                }
                // Both passes copy identity before reading their rows. Corroborate it
                // after the final census, so a same-window project switch during a
                // deciding value read cannot certify the earlier document's rows.
                try check()
                let finalTitle = AXHelpers.getTitle(window, runtime: logic.ax)
                let finalHiddenView = wantsTracks ? readHiddenView(currentHeaders, in: window) : nil
                let finalSinglePageEnd = wantsTracks ? try readSinglePageEnd(currentHeaders, tracks: after.tracks,
                    hiddenView: finalHiddenView, in: window) : nil
                let decidingHiddenView = wantsTracks ? readHiddenView(currentHeaders, in: window) : nil
                let finalSelectedTracks = wantsTracks ? try readSelectedTracks(currentHeaders, states: after.tracks, in: window) : nil
                let finalPresentation = sharedRead && after.mixerBinding != nil
                    ? try AXLogicProElements.mixerPresentationRead(binding: after.mixerBinding!, runtime: logic.ax, checking: checkAXRead) : nil
                let finalDocument: String?
                let finalDocumentReadable: Bool
                switch AXLogicProElements.projectPickerDocumentRead(window, runtime: logic) {
                case .success(let value): finalDocument = value; finalDocumentReadable = true
                case .failure: finalDocument = nil; finalDocumentReadable = false
                }
                try check()
                // A terminated acquisition cannot regain row authority merely because
                // its two later censuses agree. View-only cleanup is independent.
                let stable = exposure?.hasEnded != true
                    && sameWindow && before.title != nil && before.documentReadable && after.documentReadable && finalDocumentReadable
                    && sameBytes(before.title, after.title) && sameBytes(before.document, after.document)
                    && sameBytes(after.title, finalTitle) && sameBytes(after.document, finalDocument)
                    && sameElements(before.headers, after.headers)
                    && sameHiddenView(before.hiddenView, after.hiddenView) && sameHiddenView(after.hiddenView, finalHiddenView)
                    && sameHiddenView(finalHiddenView, decidingHiddenView)
                    && sameSelectedTracks(before.selectedTracks, after.selectedTracks)
                    && sameSelectedTracks(after.selectedTracks, finalSelectedTracks)
                    && (!wantsTracks || after.tracks == nil || (sameElements(after.headers, currentHeaders) && sameStackExposure))
                    && (!wantsStrips || sameElements(before.mixer.map { [$0] }, after.mixer.map { [$0] }))
                    && sameElements(before.stripElements, after.stripElements)
                    && sameElements(before.presentation?.elements, after.presentation?.elements)
                    && before.presentation?.presentation == after.presentation?.presentation
                    && (!sharedRead || (sameElements(after.presentation?.elements, finalPresentation?.elements)
                        && after.presentation?.presentation == finalPresentation?.presentation))
                    && before.tracks?.map(\.liveIdentityBacked) == after.tracks?.map(\.liveIdentityBacked)
                    && before.tracks?.map(\.selectionReadback) == after.tracks?.map(\.selectionReadback)
                    && before.tracks?.map(\.hideButtonReadback) == after.tracks?.map(\.hideButtonReadback)
                    && zip(before.strips ?? [], after.strips ?? []).allSatisfy {
                        switch ($0.physicalBinding, $1.physicalBinding) {
                        case (nil, nil): return true
                        case (.some(let a), .some(let b)): return a.matches(b)
                        default: return false
                        }
                    }
                    && sameValues(before.tracks, after.tracks) && sameValues(beforeStrips, afterStrips)
                let project = before.title.map {
                    ProjectInfo(name: Self.projectName(fromWindowTitle: $0), filePath: path, source: "ax_request_read")
                }
                let mixerStable = before.mixerVisible == after.mixerVisible
                    && sameElements(before.mixer.map { [$0] }, after.mixer.map { [$0] })
                    && sameElements(before.mixerOwners, after.mixerOwners)
                let transportStable = sameElements(before.transport.map { [$0.controlBar, $0.play, $0.record] },
                    after.transport.map { [$0.controlBar, $0.play, $0.record] })
                    && before.transport?.isPlaying == after.transport?.isPlaying
                    && before.transport?.isRecording == after.transport?.isRecording
                let candidate = SessionPopulationObservation.FreshPopulation(
                    project: project, tracks: sharedRead ? after.tracks : before.tracks, strips: sharedRead ? afterStrips : beforeStrips,
                    fileTrackCount: metadata?.trackCount, beganAt: beganAt, endedAt: Date(), stable: stable,
                    mixerPresentation: before.presentation?.presentation,
                    presentationObservation: .init(mixerVisible: mixerStable ? before.mixerVisible : nil,
                        isPlaying: transportStable ? before.transport?.isPlaying : nil,
                        isRecording: transportStable ? before.transport?.isRecording : nil,
                        uiLocale: sameBytes(before.uiLocale, after.uiLocale) ? before.uiLocale : nil),
                    hostObservation: stable && before.hostObservation == after.hostObservation ? before.hostObservation : nil,
                    presentationBinding: stable && mixerStable && transportStable && path != nil && before.title != nil && before.document != nil
                        ? .init(window: window, title: before.title!, document: before.document!,
                            mixer: before.mixer, transport: before.transport, runtime: logic,
                            uiLocale: sameBytes(before.uiLocale, after.uiLocale) ? before.uiLocale : nil,
                            mixerOwners: before.mixerOwners) : nil,
                    hiddenTracksShown: stable ? before.hiddenView?.shown : nil,
                    populationEndSource: stable && before.singlePageEnd?.matches(after.singlePageEnd) == true
                        && after.singlePageEnd?.matches(finalSinglePageEnd) == true ? "ax_all_shown_single_page" : nil,
                    selectedTrackMembershipObserved: stable && before.selectedTracks != nil
                )
                return candidate
            }
            if let preparingBookend, first.hiddenTracksShown == true,
               first.mixerPresentation?.mode == "all", first.mixerPresentation?.typeFilters.count == 8,
               first.mixerPresentation?.typeFilters.values.allSatisfy({ $0 == true }) == true,
               let tracks = first.tracks, !tracks.isEmpty, tracks.allSatisfy({ $0.isStackHeader == false }),
               let strips = first.strips, !strips.isEmpty, strips.allSatisfy({ $0.physicalBinding != nil }),
               tracks.allSatisfy({ $0.physicalBinding != nil }) {
                preparingBookend(firstReadStarted.duration(to: .now), finishBookend)
                return first
            }
            let candidate = try finishBookend(false)
            if candidate.stable { return candidate }
            last = candidate
        }
        try check()
        // Three attempts are the existing contract, not evidence of atomic host state.
        return last
    }

    /// #1079: `readTrackStates` for the background poll, which stops before the next header once
    /// `stop` answers true (`AccessibilityChannel.Runtime.trackStatesStopping`).
    func readTrackStates(
        stoppingWhen stop: @escaping @Sendable () -> Bool
    ) -> (states: [TrackState]?, yielded: Bool) {
        runtime.trackStatesStopping(stop)
    }

    func start() async throws {
        // Verify AX trust. If not trusted, the process needs to be added to
        // System Preferences > Privacy & Security > Accessibility.
        let trusted = runtime.isTrusted()
        guard trusted else {
            throw AccessibilityError.notTrusted
        }
        guard runtime.isLogicProRunning() else {
            Log.warn("Logic Pro not running at AX channel start", subsystem: "ax")
            return
        }
        Log.info("Accessibility channel started", subsystem: "ax")
    }

    func stop() async {
        Log.info("Accessibility channel stopped", subsystem: "ax")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard runtime.isLogicProRunning() else {
            return .error("Logic Pro is not running")
        }

        switch operation {
        // MARK: - Transport reads
        case "transport.get_state":
            return runtime.transportState()
        case "transport.get_tempo":
            return Self.defaultGetObservedTempo(runtime: runtime.logicRuntime)

        // MARK: - Transport mutations
        case "transport.toggle_cycle":
            return runtime.toggleTransportButton("Cycle")
        case "transport.toggle_metronome":
            return runtime.toggleTransportButton("Metronome")
        case "transport.toggle_count_in":
            return runtime.toggleTransportButton("CountIn")
        case "transport.toggle_autopunch":
            return runtime.toggleTransportButton("AutoPunch")

        case "edit.toggle_step_input":
            return runtime.toggleStepInputKeyboard()

        case "edit.quantize":
            return await AccessibilityChannel.quantizeSelectedRegions(params: params, runtime: runtime.logicRuntime)

        case "edit.undo":
            return await AccessibilityChannel.defaultUndoOrRedo(redo: false)
        case "edit.redo":
            return await AccessibilityChannel.defaultUndoOrRedo(redo: true)

        case "transport.play":
            return runtime.toggleTransportButton("Play")
        case "transport.stop":
            return runtime.toggleTransportButton("Stop")
        case "transport.pause":
            // Logic's control bar has no pause control, and Stop is not pause: Pause leaves Play on
            // with the playhead held, Stop turns Play off and clears Record. This case used to press
            // Stop, so a pause that fell through to it stopped the transport (#1029 review, R-01).
            // It refuses instead, so no route or caller reaches Stop through "pause". Not terminal:
            // a later rung that posts Pause may still run.
            return .error(HonestContract.encodeStateC(
                error: .notSupported,
                hint: "Logic's control bar has no pause control, and Stop is not pause, so the Accessibility channel sent nothing. Pause is the CGEvent Pause key (keypad Period).",
                extras: [
                    "operation": "transport.pause",
                    "write_attempted": false,
                    "safe_to_retry": true,
                ]
            ))
        case "transport.record":
            return runtime.toggleTransportButton("Record")

        case "transport.set_tempo":
            return runtime.setTempo(params)
        case "transport.set_cycle_range":
            return runtime.setCycleRange(params)

        case "transport.goto_position":
            // The Go To Position dialog route needs a live transport read immediately before it, in
            // the same request. Measured 2026-08-17 on Logic 12.3, three samples each way: as the
            // first thing a fresh server process does, the route reports `menu_state:
            // could_not_be_closed` with `menu_actuation_attempted: false` — it never tries, and no
            // menu is open (an external System Events read counts zero). READ THAT FIELD AS IT WAS
            // THEN: `menu_state` was a hardcoded constant on that refusal path until #921, so the
            // 2026-08-17 payload said `could_not_be_closed` whatever the script had observed. What
            // the measurement establishes is the 3/3 → 3/3 pair below, not the menu token. Adding this read turns
            // 3/3 FAIL into 3/3 OK. The same read issued seconds earlier as a separate request does
            // NOT help, so it is the immediacy that matters, not the warmth.
            //
            // It lives HERE rather than in the callers because that is what went wrong: every
            // caller reaching this operation through `TransportDispatcher.handleGotoPosition` was
            // covered by its `liveTransportState` pre-read, and `record_sequence` — the one caller
            // that routes the operation directly — was not, so its mandatory playhead reset failed
            // on every fresh process (#572). A precondition kept in each caller is a precondition
            // one caller will miss.
            //
            // Why the route needs it is NOT established. What is established is the pair above: an
            // in-request read fixes it and an earlier one does not. Do not delete this as a
            // pointless warm-up without reproducing that pair first.
            _ = runtime.transportState()
            return await AccessibilityChannel.gotoPositionViaBarSlider(
                params: params, runtime: runtime.logicRuntime,
                observeFrontmost: runtime.logicRuntime.observeFrontmost
            )

        case "nav.set_zoom_level":
            // #109: verified zoom via the writable Horizontal-Zoom AXSlider.
            return AccessibilityChannel.defaultSetZoomLevel(
                params: params, runtime: runtime.logicRuntime
            )

        case "nav.set_vertical_zoom_level":
            return Self.defaultSetVerticalZoomLevel(params: params, runtime: runtime.logicRuntime)

        case "view.set_mixer_visibility":
            return await Self.defaultSetMixerVisibility(params: params, runtime: runtime.logicRuntime)

        // MARK: - Track reads
        case "track.get_tracks":
            // v3.1.8 (Issue #7) — AX-only at the channel layer. The v3.1.5
            // AppleScript-primary fallback was removed because Logic 12.x
            // dropped `tracks` from its scripting dictionary (always
            // returned -2753). The project-file count fallback now lives
            // in `ResourceHandlers.readTracks` where placeholder rows can
            // be emitted to resource consumers without poisoning the
            // shared StateCache.
            return runtime.tracks()
        case "track.get_selected":
            return runtime.selectedTrack()

        // MARK: - Track mutations
        case "track.select":
            return await runtime.selectTrack(params)
        case "track.set_mute":
            return runtime.setTrackToggle(params, "Mute")
        case "track.set_solo":
            return runtime.setTrackToggle(params, "Solo")
        case "track.set_arm":
            return runtime.setTrackToggle(params, "Record")
        case "track.rename":
            return runtime.renameTrack(params)
        case "mixer.rename_exact":
            // Internal #968 primitive only. A caller must retain physical Mixer
            // custody; no public command, index fallback or new registry is added.
            return Self.renamePhysicalMixerStrip(params: params, runtime: runtime.logicRuntime,
                mouse: runtime.observationMouseRuntime ?? .production, canPostEvents: runtime.canPostEvents)
        case "track.sort_verified":
            return runtime.sortTracks(params)
        case "track.set_color":
            // v3.1.2 P2-1 — explicit State C `not_implemented` so callers
            // (and the router's terminal-error gate) can distinguish a
            // structural "this surface does not exist" from a transient AX
            // write failure. Logic Pro 12.0.1 does not expose track-color
            // mutation through the Accessibility API — the color swatch in
            // the inspector is a custom-drawn AppKit control with no AX
            // children or settable attributes.
            return .error(HonestContract.encodeStateC(
                error: .notImplemented,
                hint: "Track color is not exposed via AX in Logic Pro 12.0.1. Use Logic Pro UI directly."
            ))

        // MARK: - Library (instrument patch) operations
        case "library.list":
            return AccessibilityChannel.listLibrary(runtime: runtime.logicRuntime)
        case "library.scan_all":
            // E15: atomic check-and-set within actor step (no suspension points).
            // Library and plugin AX scans are mutually exclusive — either one in
            // flight rejects the other so we never run two concurrent AX-tree
            // traversals of Logic. Each scan still clears only its OWN flag.
            if libraryScanInProgress || pluginScanInProgress {
                return .error("Library scan already in progress")
            }
            libraryScanInProgress = true
            defer { libraryScanInProgress = false }
            // "mode" selects between disk (default, filesystem-backed,
            // Panel-taxonomy mapped), ax (legacy live Panel walk), or both
            // (diff report).
            switch Self.parseScanMode(params["mode"]) {
            case .disk:
                return await self.runDiskScan(runtime: runtime.logicRuntime)
            case .both:
                return await self.runBothScan(runtime: runtime.logicRuntime)
            case .ax:
                return await self.runLiveScan(runtime: runtime.logicRuntime)
            }
        case "library.resolve_path":
            // v3.1.0 (T6) + #222 — panel hits win; disk hits are loadable
            // candidates only when no panel cache has proved the path absent.
            return AccessibilityChannel.resolveLibraryPath(
                params: params,
                lastPanelScan: lastPanelScan,
                lastDiskScan: lastDiskScan,
                lastScan: lastScan,
                lastScanSource: lastScanSource
            )
        case "plugin.scan_presets":
            // F2 minimal scan handler — relies on currently-focused plugin window.
            // Full T6 (cache, persistence, axScanInProgress rename, AC-1.5b trackIndex
            // precedence) is follow-up. This handler delivers live menu enumeration.
            // E15: mutually exclusive with library.scan_all — either AX-tree scan
            // in flight rejects the other. Each scan still clears only its OWN flag.
            if libraryScanInProgress || pluginScanInProgress {
                return .error("AX scan already in progress")
            }
            pluginScanInProgress = true
            defer { pluginScanInProgress = false }
            let settleMs = Int(params["submenuOpenDelayMs"] ?? "250") ?? 250
            return await AccessibilityChannel.runLivePluginPresetScan(
                runtime: runtime.logicRuntime, settleMs: settleMs
            )
        case "track.set_instrument":
            // #135/#141/#222 — wire a cache-backed pre-resolver. A Panel cache
            // can certify a path as Panel-present; an already-captured disk
            // cache can fail fast for non-leaf factory paths, but we do not
            // create a fresh disk scan here. Disk inventory is not the same
            // denominator as the live Panel inventory, and treating an implicit
            // disk miss as a hard Panel miss reintroduces the #222 contract bug.
            let panelScanSnapshot = self.lastPanelScan
            let diskScanSnapshot = self.lastDiskScan
            let staging = AccessibilityChannel.LibraryPanelStaging(
                isPanelOpen: { rt in LibraryAccessor.isLibraryPanelOpen(runtime: rt) },
                openPanel: { rt in await AccessibilityChannel.openLibraryPanelViaKeyCommand(runtime: rt) },
                resolvePathKind: { path in
                    if let panelRoot = panelScanSnapshot {
                        let panelResolution = LibraryAccessor.resolvePath(path, in: panelRoot)
                        if panelResolution.exists {
                            if let diskRoot = diskScanSnapshot {
                                let diskResolution = LibraryAccessor.resolvePath(path, in: diskRoot)
                                if diskResolution.exists, diskResolution.kind != .leaf {
                                    return diskResolution.kind
                                }
                            }
                            return panelResolution.kind
                        }
                    }
                    if let diskRoot = diskScanSnapshot {
                        let diskResolution = LibraryAccessor.resolvePath(path, in: diskRoot)
                        if diskResolution.exists {
                            return diskResolution.kind
                        }
                    }
                    return nil
                },
                resolvePath: { path in
                    if let root = panelScanSnapshot {
                        let resolution = LibraryAccessor.resolvePath(path, in: root)
                        return resolution.exists
                    }
                    if let root = diskScanSnapshot {
                        let resolution = LibraryAccessor.resolvePath(path, in: root)
                        return resolution.exists
                    }
                    return nil   // no cache → undecided, attempt nav
                }
            )
            let result = await AccessibilityChannel.setTrackInstrument(
                params: params,
                runtime: runtime.logicRuntime,
                staging: staging,
                canPostEvents: runtime.canPostEvents
            )
            // T4 Tier-A cache population: remember what we routed for future scan restore.
            // Covers both legacy {category, preset} and path-mode {path} callers.
            if result.isSuccess {
                if let cat = params["category"], !cat.isEmpty,
                   let pre = params["preset"], !pre.isEmpty {
                    lastRoutedCategory = cat
                    lastRoutedPreset = pre
                } else if let path = params["path"],
                          let parts = LibraryAccessor.parsePath(path),
                          parts.count >= 2 {
                    lastRoutedCategory = parts[0]
                    lastRoutedPreset = parts[parts.count - 1]
                }
            }
            return result

        // MARK: - Project lifecycle via AX
        case "project.new":
            return await AccessibilityChannel.createEmptyProjectFromQualifiedState(runtime: runtime.logicRuntime)
        case "project.save_as":
            guard let path = params["path"] else {
                return .error("Missing 'path' parameter for project.save_as")
            }
            return await AccessibilityChannel.saveAsViaAXDialog(path: path, runtime: runtime.logicRuntime)
        case "project.bounce":
            return await AccessibilityChannel.openBounceDialogViaMenu()

        // MARK: - Track creation via menu click
        case "track.create_instrument":
            return await AccessibilityChannel.createTrackViaMenu(
                item: AXLocalePolicy.newSoftwareInstrumentTrackMenuItem,
                expectedTrackType: .softwareInstrument,
                confirmDialog: runtime.confirmNewTrackDialog,
                runtime: runtime.logicRuntime
            )
        case "track.create_audio":
            return await AccessibilityChannel.createTrackViaMenu(
                item: AXLocalePolicy.newAudioTrackMenuItem,
                expectedTrackType: .audio,
                confirmDialog: runtime.confirmNewTrackDialog,
                runtime: runtime.logicRuntime
            )
        case "track.create_drummer":
            // Logic 12.0.1+ renamed this leaf to `New Session Player SI Track…`, with Drummer as a
            // sub-option in the dialog that follows.
            //
            // The Logic 11 fallback that used to sit under this one was removed on 2026-09-16
            // in #907. It tried `New Drummer Track` and a Korean spelling of it, which is two of
            // the ten languages Logic ships, and neither string is in ANY locale of the pinned
            // 12.3 corpus -- Apple stopped shipping them when the item was renamed. So it was a
            // guess about an application this repository cannot read, cite or test, in two
            // languages, and widening it to ten was impossible for the same reason.
            //
            // #908 decided 2026-09-18 that Logic 11 is NOT supported, so nothing is restored here.
            // `LogicProSupport.minimumSupportedLogicVersion` is `12.0.1` and the doctor's
            // `logic.version_support` check fails below it -- which it did before the decision too,
            // and `Issue908LogicVersionFloorTests` is what now watches it refuse.
            return await AccessibilityChannel.createTrackViaMenu(
                item: AXLocalePolicy.newSessionPlayerTrackMenuItem,
                expectedTrackType: .drummer,
                confirmDialog: runtime.confirmNewTrackDialog,
                runtime: runtime.logicRuntime
            )
        case "track.create_external_midi":
            return await AccessibilityChannel.createTrackViaMenu(
                item: AXLocalePolicy.newExternalMIDITrackMenuItem,
                expectedTrackType: .externalMIDI,
                runtime: runtime.logicRuntime
            )

        case "track.delete":
            return await AccessibilityChannel.defaultDeleteTrack(
                runtime: runtime.logicRuntime
            )

        // MARK: - Mixer reads
        case "mixer.get_state":
            return runtime.mixerState()
        case "mixer.get_channel_strip":
            return runtime.channelStrip(params)

        // MARK: - Mixer mutations
        case "mixer.set_volume":
            return runtime.setMixerValue(params, .volume)
        case "mixer.set_pan":
            return runtime.setMixerValue(params, .pan)
        case "mixer.set_output_verified":
            return await AccessibilityChannel.setOutputVerified(params: params, runtime: runtime.logicRuntime)
        case "mixer.get_output_verified":
            return await AccessibilityChannel.getOutputVerified(params: params, runtime: runtime.logicRuntime)
        case "mixer.set_input_bus_verified":
            return await AccessibilityChannel.setInputBusVerified(params: params, runtime: runtime.logicRuntime)
        case "mixer.set_send_output_verified":
            return await AccessibilityChannel.setAssignedSendOutputVerified(params: params, runtime: runtime.logicRuntime)
        case "mixer.set_send_level_verified":
            return await Self.setSendLevelVerified(params: params, runtime: runtime.logicRuntime,
                mouse: runtime.observationMouseRuntime, canPostEvents: runtime.canPostEvents)
        case "mixer.set_send_mode_verified":
            return await Self.setSendModeVerified(params: params, runtime: runtime.logicRuntime)
        case "mixer.get_send_bypass_verified", "mixer.set_send_bypass_verified":
            return await AccessibilityChannel.sendBypassVerified(params: params,
                writing: operation == "mixer.set_send_bypass_verified", runtime: runtime.logicRuntime)
        case "mixer.get_input_bus_verified":
            guard params.isEmpty else {
                return .error(HonestContract.encodeStateC(error: .invalidParams,
                    hint: "The physical input-bus reader accepts no indices or write inputs.",
                    extras: ["operation": operation, "write_attempted": false]))
            }
            return await AccessibilityChannel.getInputBusVerified(runtime: runtime.logicRuntime)
        case "mixer.get_send_destination_verified":
            guard params.count == 1, let raw = params["ordinal"], let ordinal = Int(raw), ordinal >= 0 else {
                return .error(HonestContract.encodeStateC(error:.invalidParams,
                    hint:"A nonnegative assigned-send ordinal is required; no write inputs are accepted.",
                    extras:["operation":operation,"write_attempted":false]))
            }
            return await AccessibilityChannel.getAssignedSendVerified(ordinal:ordinal, runtime:runtime.logicRuntime)
        // #592: `mixer.set_send` routes `[.mcu]` and MCUChannel implements it, so this arm was
        // unreachable — a reader who grepped the operation found a refusal that is not what it does.

        // MARK: - MIDI file import (AX menu navigation)
        case "midi.import_file":
            guard let path = params["path"] else {
                return .error("midi.import_file requires 'path'")
            }
            // Restrict to the SMFWriter-managed temp dir after resolving
            // symlinks and path traversal. Raw MCP callers cannot point the
            // AX open-panel keystroke at arbitrary files on the user's
            // filesystem; the legitimate producer is TrackDispatcher.record_sequence.
            guard let safePath = AccessibilityChannel.validatedMIDIImportPath(path) else {
                return .error("midi.import_file path must be a server-managed LogicProMCP temp .mid")
            }
            return await runtime.importMIDIFile(safePath)

        // MARK: - Navigation
        case "nav.get_markers":
            // One path: `AXLogicProElements.enumerateMarkers` scrapes the dedicated Marker List
            // window's `AXTable`. The three that used to sit under it are gone -- an AppleScript
            // `tell front document → markers` that Logic 12's dictionary never exposed (removed
            // v3.1.8), an `AXRuler` scan of the arrange window, and an `AXGroup` keyword match.
            // Apple took markers out of the arrange subtree in 12.2, so the last two answered
            // empty on every build this repository pins, and an empty answer here is read as
            // "no markers" rather than "not found". Removed 2026-09-16 in #907; whether Logic 11 is
            // supported at all is #908.
            return runtime.markers()
        case "nav.open_marker_list":
            return await runtime.openMarkerList()
        case "nav.capture_markers":
            return await Self.defaultCaptureMarkers(
                runtime: runtime.logicRuntime,
                openMarkerList: { await Self.defaultOpenMarkerListForCapture(runtime: runtime.logicRuntime) }
            )
        case "nav.create_marker":
            return await runtime.createMarker(params)
        case "nav.rename_marker":
            guard let rawIndex = params["index"], let index = Int(rawIndex), index >= 0 else {
                return .error(HonestContract.encodeStateC(
                    error: .invalidParams,
                    hint: "nav.rename_marker requires 'index' as an integer >= 0"
                ))
            }
            guard let name = params["name"], !name.isEmpty else {
                return .error(HonestContract.encodeStateC(
                    error: .invalidParams,
                    hint: "nav.rename_marker requires a non-empty 'name'"
                ))
            }
            return await runtime.renameMarker(["index": String(index), "name": name])
        case "nav.delete_marker":
            guard let rawIndex = params["index"], let index = Int(rawIndex), index >= 0 else {
                return .error(HonestContract.encodeStateC(
                    error: .invalidParams,
                    hint: "nav.delete_marker requires 'index' as an integer >= 0"
                ))
            }
            return await runtime.deleteMarker(["index": String(index)])

        // MARK: - Project
        case "project.get_tempo_map":
            return Self.defaultGetTempoMap(runtime: runtime.logicRuntime,
                permittingRead: { !Task.isCancelled && runtime.isTrusted() && runtime.isLogicProRunning() })
        case "project.get_info":
            // v3.1.8 (Issue #7) — AppleScript-primary fallback removed
            // (Logic 12.x dropped the `tempo` / `time signature` /
            // `count of tracks` terms). The AX path returns the window
            // title only; `ResourceHandlers.readProjectInfo` performs
            // per-field merge with `MetaData.plist` for tempo / tsig /
            // trackCount.
            return runtime.projectInfo()

        // MARK: - Regions
        case "region.get_regions":
            return AccessibilityChannel.defaultGetRegions(runtime: runtime.logicRuntime)
        case "region.move_to_playhead":
            return await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(runtime: runtime.logicRuntime)
        case "region.select_last":
            return await AccessibilityChannel.defaultSelectLastRegion(runtime: runtime.logicRuntime)
        // #575: the five unimplemented region operations were removed from the routing table along
        // with this arm. They now fall through to the unsupported-operation default, which is what
        // an operation nothing implements should say — "not yet implemented via AX" reads as a
        // promise, and the router no longer offers a path to it either way.

        // MARK: - Plugins
        case "plugin.insert":
            return await AccessibilityChannel.defaultInsertPlugin(params: params, runtime: runtime.logicRuntime)
        // plugin.bypass / plugin.remove are still intentionally absent from
        // the public contract; no verified AX readback path exists for them.

        // MARK: - Verified plugin surface (logic_plugins.*)
        // Drift-safe inventory and verified live plugin writes. These route
        // through AX/CGEvent only, with readback as the only State-A authority
        // and State-C fail-closed behavior for unsupported or drifting UI.
        case "plugin.get_inventory":
            return await AccessibilityChannel.defaultGetPluginInventory(params: params, runtime: runtime.logicRuntime)
        case "plugin.get_param_verified":
            return await AccessibilityChannel.defaultGetParamVerified(params: params, runtime: runtime.logicRuntime)
        case "plugin.get_channel_eq_state_verified":
            return await AccessibilityChannel.defaultGetChannelEQStateVerified(params: params, runtime: runtime.logicRuntime)
        case "plugin.set_param_verified":
            return await AccessibilityChannel.defaultSetParamVerified(params: params, runtime: runtime.logicRuntime)
        case "plugin.set_eq_band_verified":
            return await AccessibilityChannel.defaultSetEQBandVerified(params: params, runtime: runtime.logicRuntime)
        case "plugin.insert_verified":
            return await AccessibilityChannel.defaultInsertVerified(params: params, runtime: runtime.logicRuntime)

        // MARK: - Automation
        // #592: `automation.set_mode` routes `[.mcu, .midiKeyCommands, .cgEvent]` — accessibility is
        // not in its chain and the key-command channel carries it, so this arm was unreachable too.

        default:
            return .error("Unsupported AX operation: \(operation)")
        }
    }

    nonisolated func healthCheck() async -> ChannelHealth {
        guard runtime.isTrusted() else {
            return .unavailable("Accessibility not trusted — add this process in System Preferences")
        }
        guard runtime.isLogicProRunning() else {
            return .unavailable("Logic Pro is not running")
        }
        // Quick smoke test: can we reach the app root?
        guard runtime.appRoot() != nil else {
            return .unavailable("Cannot access Logic Pro AX element")
        }
        return .healthy(detail: "AX connected to Logic Pro")
    }

    /// Production `library.scan_all` path — wires ScanOrchestration + live TreeProbe,
    /// populates `lastScan` for resolve_path, restores Tier-A selection, writes JSON.
    private func runLiveScan(runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        let t0 = Date()
        Log.info("scan_all: entering runLiveScan", subsystem: "ax")

        // Fail closed when Logic is running in a headless/no-window state.
        // Without this guard, AX can expose stale Library descendants from a
        // previous session and the scan may descend into a long probe despite
        // there being no visible project window to operate on.
        guard self.runtime.hasVisibleWindow() else {
            Log.info("scan_all: preflight failed — no visible Logic window", subsystem: "ax")
            return .error("Library panel not found. Open Library (Y) in Logic Pro.")
        }

        // Precondition: only start the scan if the Library panel is actually open.
        // This is a < 100 ms AX check and avoids descending into a multi-second
        // probe chain that has no Library to walk. Run FIRST so we bail before
        // any expensive setup (probe construction, snapshot extraction).
        guard LibraryAccessor.isLibraryPanelOpen(runtime: runtime) else {
            Log.info("scan_all: preflight failed in \(Int(Date().timeIntervalSince(t0) * 1000))ms — panel closed", subsystem: "ax")
            return .error("Library panel not found. Open Library (Y) in Logic Pro.")
        }
        Log.info("scan_all: preflight OK in \(Int(Date().timeIntervalSince(t0) * 1000))ms", subsystem: "ax")

        let snapshot: (category: String, preset: String)? = {
            if let c = lastRoutedCategory, let p = lastRoutedPreset { return (c, p) }
            return nil
        }()
        let channel = self
        let probe = Self.buildLiveTreeProbe(runtime: runtime)

        // 150ms settle is empirically sufficient on Apple Silicon; 500ms was
        // overly conservative and pushed full Library scans past the client
        // read-timeout (observed 164s at 500ms vs ~50s at 150ms).
        let result = await LibraryAccessor.ScanOrchestration.run(
            probe: probe,
            cachedSelection: snapshot,
            restoreSelection: { c, p in
                let okCat = LibraryAccessor.selectCategory(named: c, runtime: runtime)
                if !okCat { return false }
                try? await Task.sleep(nanoseconds: 150_000_000)
                return LibraryAccessor.selectPreset(named: p, runtime: runtime)
            },
            writeJSON: { root in Self.writeInventoryJSON(root, source: "ax") },
            onComplete: { root in await channel.setLastScan(root, source: "panel") },
            settleDelayMs: 150
        )
        guard let r = result else {
            return .error("Library panel not found. Open Library (Y) in Logic Pro.")
        }
        // v3.1.0 (T6) — AX scan response now includes `source:"panel"` so
        // clients can distinguish it from disk/both responses and route
        // `resolve_path` queries against the correct cache.
        return Self.encodeLibraryRoot(r.root, sourceTag: "panel")
    }

    /// Test-only seam for T6 cache-split coverage. Production call sites go
    /// through `runLiveScan` / `runDiskScan` / `runBothScan`. Internal so
    /// the `@testable import` surface sees it, external does not.
    func seedLastScanForTest(_ root: LibraryRoot, source: String) {
        setLastScan(root, source: source)
    }

    private func setLastScan(_ root: LibraryRoot, source: String) {
        self.lastScan = root
        self.lastScanSource = source
        switch source {
        case "panel":
            self.lastPanelScan = root
        case "disk":
            self.lastDiskScan = root
        default:
            break
        }
    }

    // MARK: - v3.0.5 disk-backed scan

    /// v3.0.5 — filesystem-backed `library.scan_all`. Enumerates the user
    /// Logic Library and Logic Pro app-bundle Instrument patch roots, dedupes
    /// relative `.patch` paths, and produces a schema-identical `LibraryRoot`
    /// to the AX scan, but with full depth. Falls back to the legacy AX scan if
    /// no configured bundle can be scanned. Populates `lastScan` so
    /// `library.resolve_path` works against the disk tree.
    private func runDiskScan(runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        let t0 = Date()
        Log.info("scan_all: entering runDiskScan (mode=disk)", subsystem: "ax")
        do {
            let root = try LibraryDiskScanner.scan()
            let durationMs = Int(Date().timeIntervalSince(t0) * 1000)
            Log.info(
                "scan_all: disk scan ok — \(root.leafCount) leaves, \(root.folderCount) folders in \(durationMs)ms",
                subsystem: "ax"
            )
            self.setLastScan(root, source: "disk")
            _ = Self.writeInventoryJSON(root, source: "disk")
            return Self.encodeLibraryRoot(root, sourceTag: "disk")
        } catch {
            Log.warn(
                "scan_all: disk scan failed (\(error)); falling back to AX scan",
                subsystem: "ax"
            )
            return await self.runLiveScan(runtime: runtime)
        }
    }

    /// v3.0.5 — run both disk and AX scans, return a diff summary. Useful
    /// for verifying coverage parity and catching schema drift between
    /// Logic's disk layout and its Library Panel exposure. The AX scan is
    /// kicked off after the disk scan because the AX scan both takes longer
    /// and requires the Library Panel to be open — if the panel is closed
    /// the disk result still ships and the AX block degrades to a zero-leaf
    /// stub with `axAvailable:false`.
    private func runBothScan(runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        let diskRoot: LibraryRoot
        do {
            diskRoot = try LibraryDiskScanner.scan()
        } catch {
            return .error("Disk scan failed: \(error); fall back to mode=ax")
        }
        self.setLastScan(diskRoot, source: "both")
        _ = Self.writeInventoryJSON(diskRoot, source: "disk")

        // Best-effort AX scan. If the panel is closed we still emit a diff
        // structure with ax={available:false, leafCount:0, ...} so clients
        // can detect the degraded case without parsing an error string.
        var axLeafCount = 0
        var axNodeCount = 0
        var axAvailable = false
        if LibraryAccessor.isLibraryPanelOpen(runtime: runtime) {
            let probe = Self.buildLiveTreeProbe(runtime: runtime)
            if let axRoot = await LibraryAccessor.enumerateTree(
                maxDepth: 12, settleDelayMs: 150, probe: probe
            ) {
                axLeafCount = axRoot.leafCount
                axNodeCount = axRoot.nodeCount
                axAvailable = true
                // v3.1.0 (Ralph-2 / C3) — mode=both did not previously expose
                // its AX scan to `resolve_path`. The disk tree was stored as
                // `lastBothScan` + `lastScan`, but `lastPanelScan` stayed nil,
                // so resolve_path hit the legacy fallback and labelled every
                // match `loadable:false` regardless of Panel presence. We
                // now seed `lastPanelScan` from the inline AX scan too so
                // Panel-loadable paths are correctly classified after
                // `scan_library {mode:"both"}`.
                self.lastPanelScan = axRoot
            }
        }

        let onlyOnDisk = max(0, diskRoot.leafCount - axLeafCount)
        let summary = """
        {"mode":"both","disk":{"leafCount":\(diskRoot.leafCount),"folderCount":\(diskRoot.folderCount),"nodeCount":\(diskRoot.nodeCount)},"ax":{"available":\(axAvailable),"leafCount":\(axLeafCount),"nodeCount":\(axNodeCount)},"diff":{"onlyOnDisk":\(onlyOnDisk)}}
        """
        return .success(summary)
    }
    // MARK: - Removed in v3.1.8 (Issue #7)
    //
    // The v3.1.5 AppleScript-primary read helpers (`markersViaAppleScript`,
    // `projectInfoViaAppleScript`, `tracksViaAppleScript`) have been removed.
    //
    // Background: v3.1.5 introduced these helpers because AX scrapes were
    // panel-focus dependent on Logic 12.x. The intent was to query
    // `tell front document → tracks / markers / tempo` directly. Logic Pro
    // 12.0+ ships an AppleScript scripting dictionary that does NOT expose
    // any of those terms — every call returns -2753 ("variable is not
    // defined"). The helpers therefore added a wasted IPC round-trip on
    // every poll without ever supplying real data on the targeted platform.
    //
    // The Issue #3/#4/#5 fix has moved to the resource layer
    // (`ResourceHandlers.readProjectInfo` / `readTracks`) which now reads
    // `MetaData.plist` directly via `LogicProjectFileReader` for the
    // project-file tier. The AX path stays as the live tier (hardened in
    // T6: strict `getTrackHeaders` / `allTrackHeaders`; AXRuler-based
    // `enumerateMarkers`).


    // MARK: - JSON encoding

    static func encodeResult<T: Encodable>(_ value: T) -> ChannelResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            guard let json = String(data: data, encoding: .utf8) else {
                return .error("Failed to encode result to UTF-8")
            }
            return .success(json)
        } catch {
            return .error("JSON encoding failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum AccessibilityError: Error, CustomStringConvertible {
    case notTrusted

    var description: String {
        switch self {
        case .notTrusted:
            return "Process is not trusted for Accessibility. Add it in System Preferences > Privacy & Security > Accessibility."
        }
    }
}
