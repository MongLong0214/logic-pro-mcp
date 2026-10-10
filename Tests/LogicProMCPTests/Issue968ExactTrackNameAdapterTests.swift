@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

private final class ExactNameFixture: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let window: AXUIElement
    let header: AXUIElement
    let field: AXUIElement
    let rail: AXUIElement
    let cache = StateCache()
    let registry = TargetRegistry()
    let router = ChannelRouter()
    private(set) var writes: [String] = []
    private(set) var events: [String] = []
    var additionalNameFields: [AXUIElement] = []
    private(set) var actedNameFields: [AXUIElement] = []
    var routedOperations: [String] = []
    var editOnPress: String?
    var hideReadbackAfterSet = false
    var acknowledgementOnly = false
    var onPress: (@Sendable () -> Void)?
    var onConfirm: (@Sendable () -> Void)?
    var onNameReadAfterWrite: (@Sendable () -> Void)?
    var nameReadsAfterWrite = 0
    var permitsSelection = false
    var exposeFieldWhenSelected = false
    var renameMenuItem: AXUIElement?
    var selectionWrites: [AXUIElement] = []
    var pressReportsFailure = false
    var boundaryOwnership = true
    var onSelection: (@Sendable () -> Void)?
    var onRenameMenuRead: (@Sendable () -> Void)?
    var menuFocusedEditor: AXUIElement?
    var typedCodeUnits: [UInt16] = []
    var postedReturn = false
    var onTypedCodeUnit: (@Sendable () -> Void)?
    var typingPostReportsFailure = false
    var returnReportsFailure = false
    var observedLogicPID: pid_t = 4242
    var observedFocusedPID: pid_t = 4242
    var logicIsFrontmost = true
    var typingSleeps: [useconds_t] = []
    var onTypingSleep: (@Sendable (useconds_t) -> Void)?
    var legacyHeaderRoleFailureRead: Int?
    var legacyHeaderRoleReads = 0
    var legacyHeaderRoleFailures = 0
    var legacyHeaderReadsAtSelection: [Int] = []
    var selectionReportsFailure = false
    var legacyHeaderRoleObservedRead: Int?
    var legacyHeaderRoleObservations = 0
    var onLegacyHeaderRoleRead: (@Sendable () -> Void)?
    var boundaryCancellation = false
    var adapterPermissionReads = 0
    var passiveHeaderNameLabel = false
    var menuEditorValueWrites: [String] = []
    var menuEditorSetterAcknowledgesOnly = false
    var onMenuEditorValueSet: (@Sendable () -> Void)?
    var coupledNameField: AXUIElement?
    var coupledPeerNameField: AXUIElement?
    var onMirrorReadAfterWrite: (@Sendable () -> Void)?
    var peerNameReadsAfterWrite = 0
    var onPeerNameReadAfterWrite: (@Sendable (Int) -> Void)?
    var rawHelpReads = 0
    var countRawHelpReads = false

    init(_ name: String = "A") {
        app = builder.element(968_100)
        window = builder.element(968_101)
        rail = builder.element(968_102)
        header = builder.element(968_103)
        field = builder.element(968_104)
        builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(window, kAXTitleAttribute as String, "Fixture - Tracks")
        builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/ExactName.logicx")
        builder.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
        builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(header, kAXSelectedAttribute as String, true)
        builder.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
        builder.setAttribute(field, kAXDescriptionAttribute as String, name)
        builder.setAttribute(field, kAXValueAttribute as String, "0")
        builder.setChildren(field, [])
        builder.setChildren(header, [field])
        builder.setChildren(rail, [header])
        builder.setChildren(window, [rail])
        builder.setChildren(app, [window])
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    }

    var runtime: AXLogicProElements.Runtime {
        let source = AXLogicProElements.Runtime(
            logicProPID: { [self] in observedLogicPID },
            ax: builder.makeAXRuntime(
                appElement: app,
                attributeValueHandler: { [self] element, attribute in
                    if countRawHelpReads, attribute == kAXHelpAttribute as String { rawHelpReads += 1 }
                    if !writes.isEmpty, additionalNameFields.contains(where: { CFEqual($0, element) }),
                       attribute == kAXDescriptionAttribute as String {
                        peerNameReadsAfterWrite += 1
                        onPeerNameReadAfterWrite?(peerNameReadsAfterWrite)
                    }
                    if !writes.isEmpty, let coupledNameField, CFEqual(element, coupledNameField),
                       attribute == kAXValueAttribute as String { onMirrorReadAfterWrite?() }
                    if let renameMenuItem, CFEqual(element, renameMenuItem), attribute == kAXTitleAttribute as String {
                        onRenameMenuRead?()
                    }
                    if !writes.isEmpty, CFEqual(element, field), attribute == kAXDescriptionAttribute as String {
                        nameReadsAfterWrite += 1
                        onNameReadAfterWrite?()
                    }
                    if hideReadbackAfterSet, !writes.isEmpty, CFEqual(element, field),
                       attribute == kAXDescriptionAttribute as String { return .some(nil) }
                    return nil
                },
                setAttributeHandler: { [self] element, attribute, value in
                    if let menuFocusedEditor, CFEqual(element, menuFocusedEditor),
                       attribute == kAXValueAttribute as String, let name = value as? String {
                        menuEditorValueWrites.append(name)
                        if !menuEditorSetterAcknowledgesOnly {
                            builder.setAttribute(element, attribute, name)
                        }
                        onMenuEditorValueSet?()
                        return true
                    }
                    if permitsSelection, CFEqual(element, rail), attribute == kAXSelectedChildrenAttribute as String,
                       let selected = value as? [AXUIElement], selected.count == 1 {
                        selectionWrites.append(selected[0])
                        legacyHeaderReadsAtSelection.append(legacyHeaderRoleReads)
                        for row in AXHelpers.getChildren(rail, runtime: builder.makeAXRuntime()) {
                            builder.setAttribute(row, kAXSelectedAttribute as String, CFEqual(row, selected[0]))
                        }
                        if exposeFieldWhenSelected, CFEqual(selected[0], header) {
                            builder.setChildren(header, [field])
                        }
                        onSelection?()
                        return !selectionReportsFailure
                    }
                    guard ([field] + additionalNameFields).contains(where: { CFEqual($0, element) }),
                          attribute == kAXValueAttribute as String,
                          let name = value as? String else {
                        Issue.record("Unexpected exact-name fixture setter")
                        return false
                    }
                    if passiveHeaderNameLabel, CFEqual(element, field) { return false }
                    writes.append(name)
                    actedNameFields.append(element)
                    builder.setAttribute(element, kAXDescriptionAttribute as String, name)
                    return true
                },
                performActionHandler: { [self] element, action in
                    if let renameMenuItem, CFEqual(element, renameMenuItem), action == kAXPressAction as String {
                        events.append("rename_menu")
                        if let menuFocusedEditor {
                            builder.setAttribute(app, kAXFocusedUIElementAttribute as String, menuFocusedEditor)
                        } else {
                            builder.setChildren(header, [field])
                        }
                        return true
                    }
                    guard ([field] + additionalNameFields).contains(where: { CFEqual($0, element) }),
                          [kAXPressAction as String, kAXConfirmAction as String].contains(action) else {
                        Issue.record("Unexpected exact-name fixture action")
                        return false
                    }
                    events.append(action)
                    actedNameFields.append(element)
                    if passiveHeaderNameLabel, CFEqual(element, field) { return false }
                    if action == kAXPressAction as String, let editOnPress {
                        builder.setAttribute(field, kAXDescriptionAttribute as String, editOnPress)
                    }
                    if action == kAXPressAction as String { onPress?() }
                    if action == kAXConfirmAction as String { onConfirm?() }
                    return !(action == kAXPressAction as String && pressReportsFailure)
                },
                executeAppleScript: { _ in .error("Injected AX runtime refuses scripts") }
            ),
            executeAppleScript: { _ in .error("Injected runtime refuses scripts") },
            onScreenWindowList: { [] },
            postPopupMenuEscape: { Issue.record("Unexpected Escape") },
            focusedApplicationPID: { [self] in observedFocusedPID }
        )
        guard legacyHeaderRoleFailureRead != nil || legacyHeaderRoleObservedRead != nil else { return source }
        let ax = source.ax
        return AXLogicProElements.Runtime(logicProPID: source.logicProPID,
            ax: AXHelpers.Runtime(axApp: ax.axApp,
                attributeValue: { [self] element, attribute in
                    if CFEqual(element, header), attribute == kAXRoleAttribute as String {
                        legacyHeaderRoleReads += 1
                        if legacyHeaderRoleReads == legacyHeaderRoleObservedRead {
                            legacyHeaderRoleObservations += 1
                            onLegacyHeaderRoleRead?()
                        }
                        if legacyHeaderRoleReads == legacyHeaderRoleFailureRead {
                            legacyHeaderRoleFailures += 1
                            return nil
                        }
                    }
                    return ax.attributeValue(element, attribute)
                },
                attributeIsSettable: ax.attributeIsSettable, setAttributeValue: ax.setAttributeValue,
                children: ax.children, performAction: ax.performAction, childCount: ax.childCount,
                actionNames: ax.actionNames, actionNamesResult: ax.actionNamesResult,
                childrenResult: ax.childrenResult, attributeValueResult: ax.attributeValueResult,
                performActionResult: ax.performActionResult),
            executeAppleScript: source.executeAppleScript,
            executeAppleScriptWithTimeout: source.executeAppleScriptWithTimeout,
            onScreenWindowList: source.onScreenWindowList, postPopupMenuEscape: source.postPopupMenuEscape,
            focusedApplicationPID: source.focusedApplicationPID, observeFrontmost: source.observeFrontmost)
    }

    func execute(_ params: [String: String]) -> ChannelResult {
        if acknowledgementOnly { return .success("acknowledged") }
        legacyHeaderRoleReads = 0
        legacyHeaderRoleFailures = 0
        legacyHeaderRoleObservations = 0
        return AccessibilityChannel.defaultRenameTrack(
            params: params, runtime: runtime,
            mouseRuntime: AXMouseHelper.Runtime(
                postMouseEvent: { _, _, _ in Issue.record("Unexpected mouse event"); return false },
                postKeyEvent: { [self] code in
                    guard menuFocusedEditor != nil, code == 0x24 else {
                        Issue.record("Unexpected key event"); return false
                    }
                    postedReturn = true
                    guard let editor = menuFocusedEditor,
                          let name: String = AXHelpers.getAttribute(editor, kAXValueAttribute as String,
                            runtime: builder.makeAXRuntime()) else { return false }
                    writes.append(name)
                    builder.setAttribute(header, kAXTitleAttribute as String, name)
                    builder.setAttribute(field, kAXDescriptionAttribute as String, name)
                    return !returnReportsFailure
                },
                postUnicodeScalar: { [self] code in
                    guard let menuFocusedEditor else { Issue.record("Unexpected typing"); return false }
                    typedCodeUnits.append(code)
                    builder.setAttribute(menuFocusedEditor, kAXValueAttribute as String,
                        String(decoding: typedCodeUnits, as: UTF16.self))
                    onTypedCodeUnit?()
                    return !typingPostReportsFailure
                },
                sleepMicros: { [self] micros in
                    typingSleeps.append(micros)
                    onTypingSleep?(micros)
                },
                postFlaggedKeyEvent: { _, _ in Issue.record("Unexpected flagged key"); return false }
            ),
            processRuntime: ProcessUtils.Runtime(
                logicProPID: { 4242 }, fallbackLogicProPID: { 4242 }, logicProRunning: { true },
                activateLogicPro: { false }, logicIsFrontmost: { [self] in logicIsFrontmost }, logicProBundleURL: { nil }
            )
        )
    }

    func mute(_ params: [String: String]) -> ChannelResult {
        AccessibilityChannel.defaultSetTrackToggle(params: params, button: "Mute", runtime: runtime,
            keyRuntime: .init(postMouseEvent: { _, _, _ in Issue.record("Unexpected mute mouse"); return false },
                postKeyEvent: { _ in Issue.record("Unexpected mute key"); return false },
                postUnicodeScalar: { _ in Issue.record("Unexpected mute typing"); return false }, sleepMicros: { _ in },
                postFlaggedKeyEvent: { _, _ in Issue.record("Unexpected mute flagged key"); return false }),
            processRuntime: .init(logicProPID: { 4242 }, fallbackLogicProPID: { 4242 }, logicProRunning: { true },
                activateLogicPro: { false }, logicIsFrontmost: { true }, logicProBundleURL: { nil }), environment: [:])
    }

    func prepare(typedProducer: Bool = false) async throws -> (TargetReference, TargetReference) {
        if typedProducer {
            await cache.updateTracks(try #require(AccessibilityChannel.defaultGetTrackStates(runtime: runtime)))
        } else {
            await cache.updateTracks([AXValueExtractors.extractTrackState(from: header, index: 0, runtime: runtime.ax)])
        }
        let snapshot = await registry.currentSnapshot
        let project = await ProjectReferenceIssuance.issue(
            cached: ProjectInfo(name: "ExactName", filePath: "/tmp/ExactName.logicx"),
            registry: registry, snapshot: snapshot
        )
        guard case .issued(let projectRef) = project else {
            throw NSError(domain: "ExactNameFixture", code: 1)
        }
        let refs = try #require(await TrackReferenceIssuance.issue(
            for: await cache.getTracks(), registry: registry, snapshot: snapshot
        ))
        await router.register(ExactNameChannel(self))
        return (projectRef, try #require(refs.byTrackIndex[0]))
    }

    func appendTrack(name: String, selected: Bool) -> (AXUIElement, AXUIElement) {
        let row = builder.element(968_140)
        let nameField = builder.element(968_141)
        builder.setAttribute(row, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(row, kAXSelectedAttribute as String, selected)
        builder.setAttribute(nameField, kAXRoleAttribute as String, kAXTextFieldRole as String)
        builder.setAttribute(nameField, kAXDescriptionAttribute as String, name)
        builder.setAttribute(nameField, kAXValueAttribute as String, "1")
        builder.setChildren(nameField, [])
        builder.setChildren(row, [nameField])
        builder.setChildren(rail, [header, row])
        additionalNameFields.append(nameField)
        return (row, nameField)
    }

    func rename(project: TargetReference, target: TargetReference, expected: String?, desired: String,
                index: Int? = nil) async -> CallTool.Result {
        var params: [String: Value] = ["project_ref": .string(project.rawValue),
                                       "target_ref": .string(target.rawValue), "name": .string(desired)]
        if let expected { params["expected_name"] = .string(expected) }
        if let index { params["index"] = .int(index) }
        let runtime = runtime
        return await TrackDispatcher.handle(
            command: "rename", params: params, router: router, cache: cache, targetRegistry: registry,
            liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
            liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) }
        )
    }

    func apply(project: TargetReference, target: TargetReference, before: String, after: String) async -> ExactTrackNameAdapter.Receipt {
        let runtime = runtime
        return await ExactTrackNameAdapter.apply(
            .init(projectReference: project, targetReference: target, expectedBefore: before, desiredAfter: after),
            router: router, cache: cache, registry: registry,
            liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
            liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) }
        )
    }

    func inverse(_ proof: ExactTrackNameAdapter.OwnedInverse) async -> ExactTrackNameAdapter.Receipt {
        let runtime = runtime
        return await ExactTrackNameAdapter.inverse(
            proof, router: router,
            liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
            liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) }
        )
    }

    func coupledCapture(link: String = "observed", peerStripName: String? = nil) async throws -> (SessionPopulationObservation.Capture, TargetReference, TargetReference, AXUIElement, AXUIElement) {
        let mixer = builder.element(968_170)
        let strip = builder.element(968_171)
        let name = builder.element(968_172)
        coupledNameField = name
        builder.setRole(mixer, kAXGroupRole as String)
        builder.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
        builder.setRole(strip, kAXLayoutItemRole as String)
        builder.setRole(name, kAXTextFieldRole as String)
        builder.setAttribute(name, kAXDescriptionAttribute as String, "name")
        builder.setAttribute(name, kAXValueAttribute as String, link == "different_name" ? "B" : "A")
        builder.setChildren(name, [])
        builder.setChildren(strip, [name])
        if let peerStripName {
            let peer = builder.element(968_173)
            let peerName = builder.element(968_174)
            coupledPeerNameField = peerName
            builder.setRole(peer, kAXLayoutItemRole as String)
            builder.setRole(peerName, kAXTextFieldRole as String)
            builder.setAttribute(peerName, kAXDescriptionAttribute as String, "name")
            builder.setAttribute(peerName, kAXValueAttribute as String, peerStripName)
            builder.setChildren(peerName, [])
            builder.setChildren(peer, [peerName])
            builder.setChildren(mixer, [strip, peer])
        } else { builder.setChildren(mixer, [strip]) }
        builder.setChildren(window, [rail, mixer])
        await cache.updateProject(.init(name: "ExactName", filePath: "/tmp/ExactName.logicx"))
        let (project, target) = try await prepare(typedProducer: true)
        let tracks = await cache.getTracks()
        let physical = try #require(tracks.first?.physicalBinding)
        let strips = try #require(AccessibilityChannel.defaultGetMixerStates(runtime: runtime, stoppingWhen: { false }).states)
        let source = try #require(strips.first?.physicalBinding)
        await cache.updateChannelStrips(strips)
        let pair = AccessibilityChannel.HeldSelectionAssociation.Pair(track: physical, strip: source)
        var population = SessionPopulationObservation.FreshPopulation(project: await cache.getProject(),
            tracks: tracks, strips: strips, fileTrackCount: nil, beganAt: Date(), endedAt: Date(), stable: true)
        population.selectionAssociations = link == "missing" ? [] : (link == "duplicate" ? [pair, pair] : [pair])
        population.uiEffects.restoration = "restored"
        let boundary = await cache.captureBoundary(watching: SessionPopulationObservation.watchedSections)
        let accepted = SessionPopulationObservation.AcceptedPopulation(
            reading: .init(state: await cache.auditSnapshot(), fileTrackCount: nil, projectFileNotBound: false),
            boundary: boundary, population: population)
        let capture = await SessionPopulationObservation.capture(cache: cache, targetRegistry: registry,
            fileReader: .unavailable,
            requestedProjectRef: project.rawValue, accepted: accepted)
        onConfirm = { [self] in
            builder.setAttribute(name, kAXValueAttribute as String,
                builder.attributeValue(field, kAXDescriptionAttribute as String))
        }
        return (capture, project, target, strip, name)
    }

    func applyCoupled(_ capture: SessionPopulationObservation.Capture, project: TargetReference,
                      target: TargetReference, before: String = "A", after: String = "C") async -> ExactTrackNameAdapter.Receipt {
        let runtime = runtime
        return await ExactTrackNameAdapter.applyCoupled(
            .init(projectReference: project, targetReference: target, expectedBefore: before, desiredAfter: after),
            capture: capture, router: router, cache: cache, registry: registry,
            liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
            liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) })
    }

    func canonicalNameApproval(_ capture: SessionPopulationObservation.Capture, project: TargetReference,
                               target: TargetReference, desired: String, key: String,
                               journal: SagaJournal) async throws -> ApprovedSessionRepair {
        let request = SessionPopulationObservation.Request(domains: [.tracks, .strips, .associations])
        let report = SessionPopulationObservation.build(request: request, capture: capture)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        let retained = await cache.retainSessionReport(id: capture.captureID, json: json,
            capturedEpoch: capture.projectEpoch, capturedPath: capture.project.filePath,
            capture: capture, request: request)
        #expect(retained)
        let raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
            "project_ref": .string(project.rawValue),
            "targets": .array([.object(["handle": .string("exact"), "track_ref": .string(target.rawValue)])])]
        guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
            throw NSError(domain: "ExactNameFixture", code: 1)
        }
        let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
            names: [.init(target: "exact", name: desired)], capture: capture,
            request: request, snapshotCurrent: true)
        let executable = try #require(sharedJSONObject(plan.json)?["executable"] as? Bool)
        #expect(executable)
        let stored = await cache.retainRepairPlan(plan, snapshotID: capture.captureID)
        #expect(stored)
        return try #require(await ApprovedSessionRepair.retained(id: plan.id, digest: plan.digest,
            key: key, cache: cache, registry: registry, journal: journal))
    }
}

private actor ExactNameChannel: Channel {
    nonisolated let id = ChannelID.accessibility
    let fixture: ExactNameFixture
    init(_ fixture: ExactNameFixture) { self.fixture = fixture }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "Injected exact-name fixture") }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        fixture.routedOperations.append(operation)
        if operation == "track.set_mute" { return fixture.mute(params) }
        guard operation == "track.rename" else { return .error("Unexpected route") }
        return fixture.execute(params)
    }
}

@Suite("#968 exact-local track naming adapter")
struct Issue968ExactTrackNameAdapterTests {
    @Test(arguments: ["Canonical, \"한글\" 😀", "Peer"])
    func aRetainedSingleCoupledNameUsesTheExistingCanonicalSaga(_ desired: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = ExactNameFixture()
                let (_, peer) = f.appendTrack(name: "Peer", selected: false)
                let (capture, project, target, _, mirror) = try await f.coupledCapture(peerStripName: "Peer")
                let request = SessionPopulationObservation.Request(domains: [.tracks, .strips, .associations])
                let report = SessionPopulationObservation.build(request: request, capture: capture)
                let reportJSON = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
                let retained = await f.cache.retainSessionReport(id: capture.captureID, json: reportJSON,
                    capturedEpoch: capture.projectEpoch, capturedPath: capture.project.filePath,
                    capture: capture, request: request)
                #expect(retained)
                let raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(project.rawValue),
                    "targets": .array([.object(["handle": .string("exact"), "track_ref": .string(target.rawValue)])])]
                guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
                    Issue.record("the explicit single naming policy must parse"); return
                }
                let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
                    names: [.init(target: "exact", name: desired)], capture: capture,
                    request: request, snapshotCurrent: true)
                let body = try #require(sharedJSONObject(plan.json))
                let executable = try #require(body["executable"] as? Bool)
                #expect(executable)
                let stored = await f.cache.retainRepairPlan(plan, snapshotID: capture.captureID)
                #expect(stored)
                let journal = SagaJournal()
                let approval = try #require(await ApprovedSessionRepair.retained(id: plan.id, digest: plan.digest,
                    key: "one-coupled-name", cache: f.cache, registry: f.registry, journal: journal))
                let runtime = f.runtime
                func run() async -> CallTool.Result {
                    await SystemDispatcher.handle(command: "saga_execute", params: [:], router: f.router,
                        cache: f.cache, targetRegistry: f.registry, dialogPresent: { false },
                        sagaJournal: journal, mutationGate: LogicMutationGate(), sagaRefreshAfterWrite: {},
                        liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                        liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) },
                        sagaLiveReadback: .unavailable, approvedSessionRepair: approval)
                }
                let outcome = try #require(sharedJSONObject(sharedToolText(await run())))
                #expect(outcome["saga_state"] as? String == "completed")
                let verified = try #require(outcome["verified"] as? Bool)
                #expect(verified)
                #expect((outcome["steps"] as? [[String: Any]])?.count == 1)
                #expect(f.writes == [desired])
                #expect(f.builder.attributeValue(f.field, kAXDescriptionAttribute as String) as? String == desired)
                #expect(f.builder.attributeValue(mirror, kAXValueAttribute as String) as? String == desired)
                #expect(f.builder.attributeValue(peer, kAXDescriptionAttribute as String) as? String == "Peer")
                #expect(f.routedOperations == ["track.rename"])
                let replay = try #require(sharedJSONObject(sharedToolText(await run())))
                let duplicate = try #require(replay["duplicate"] as? Bool)
                #expect(duplicate)
                #expect(f.writes == [desired])
            }
        }
    }

    @Test(arguments: ["healthy", "newer_peer", "newer_own_name", "inverse_peer_effect"])
    func canonicalNameCompensationPreservesNewerNamesAndVerifiesItsActualFootprint(_ change: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = ExactNameFixture()
                let (_, peer) = f.appendTrack(name: "Peer", selected: false)
                let (capture, project, target, _, mirror) = try await f.coupledCapture(peerStripName: "Peer")
                let peerMirror = try #require(f.coupledPeerNameField)
                let journal = SagaJournal()
                let approval = try await f.canonicalNameApproval(capture, project: project, target: target,
                    desired: "Canonical", key: "cancel-coupled-name", journal: journal)
                let runtime = f.runtime
                let executor = ProductionSagaStepExecutor(router: f.router, cache: f.cache,
                    targetRegistry: f.registry, dialogPresent: { false }, liveReadback: .unavailable,
                    liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                    liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) },
                    approvedSessionRepair: approval)
                let saga = MutationSaga(targetRegistry: f.registry, approvedSessionRepair: approval,
                    routeAvailable: { _ in true })
                let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { true })
                await OperationTraceContext.$current.withValue(context) {
                    let outcome = await saga.execute(approval.plan, executor: executor)
                    #expect(outcome.state == .completed)
                    #expect(f.writes == ["Canonical"])
                    if change == "newer_peer" || change == "inverse_peer_effect" {
                        f.builder.setAttribute(peer, kAXDescriptionAttribute as String, "Newer peer")
                        f.builder.setAttribute(peerMirror, kAXValueAttribute as String, "Newer peer")
                    }
                    if change == "newer_own_name" {
                        f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "Human")
                        f.builder.setAttribute(mirror, kAXValueAttribute as String, "Human")
                    }
                    if change == "inverse_peer_effect" {
                        f.onConfirm = {
                            f.builder.setAttribute(mirror, kAXValueAttribute as String,
                                f.builder.attributeValue(f.field, kAXDescriptionAttribute as String) as Any)
                            f.builder.setAttribute(peerMirror, kAXValueAttribute as String, "Unexpected")
                        }
                    }
                    let cancelled = await saga.cancel(outcome: outcome, executor: executor)
                    if change == "newer_own_name" || change == "inverse_peer_effect" {
                        #expect(cancelled.state == .rollbackUncertain)
                    } else {
                        #expect(cancelled.state == .fullyCompensated)
                    }
                    #expect(f.writes == (change == "newer_own_name" ? ["Canonical"] : ["Canonical", "A"]))
                    #expect(f.builder.attributeValue(f.field, kAXDescriptionAttribute as String) as? String
                        == (change == "newer_own_name" ? "Human" : "A"))
                    #expect(f.builder.attributeValue(mirror, kAXValueAttribute as String) as? String
                        == (change == "newer_own_name" ? "Human" : "A"))
                    #expect(f.builder.attributeValue(peer, kAXDescriptionAttribute as String) as? String
                        == (change == "newer_peer" || change == "inverse_peer_effect" ? "Newer peer" : "Peer"))
                    #expect(f.builder.attributeValue(peerMirror, kAXValueAttribute as String) as? String
                        == (change == "inverse_peer_effect" ? "Unexpected" : change == "newer_peer" ? "Newer peer" : "Peer"))
                }
            }
        }
    }

    @Test(arguments: ["different_name", "missing", "duplicate", "unrequested", "stale"])
    func canonicalNameOptInCannotReplaceMissingCapturedCoupling(_ observation: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = ExactNameFixture()
                let (capture, project, target, _, _) = try await f.coupledCapture(link: observation)
                let raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(project.rawValue),
                    "targets": .array([.object(["handle": .string("exact"), "track_ref": .string(target.rawValue)])])]
                guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
                    Issue.record("the explicit naming policy must parse"); return
                }
                let domains: [SessionPopulationObservation.Domain] = observation == "unrequested"
                    ? [.tracks, .strips] : [.tracks, .strips, .associations]
                let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
                    names: [.init(target: "exact", name: "Canonical")], capture: capture,
                    request: .init(domains: domains), snapshotCurrent: observation != "stale")
                let executable = try #require(sharedJSONObject(plan.json)?["executable"] as? Bool)
                #expect(!executable)
                #expect(f.writes.isEmpty && f.routedOperations.isEmpty && f.events.isEmpty)
            }
        }
    }

    @Test(arguments: ["primary_name", "mirror_name", "document", "physical_peer"])
    func canonicalNameRevalidatesTheOriginalFootprintBeforeAnyWrite(_ change: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = ExactNameFixture()
                let (capture, project, target, _, mirror) = try await f.coupledCapture()
                let journal = SagaJournal()
                let approval = try await f.canonicalNameApproval(capture, project: project, target: target,
                    desired: "Canonical", key: "stale-coupled-name", journal: journal)
                switch change {
                case "primary_name": f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "Human")
                case "mirror_name": f.builder.setAttribute(mirror, kAXValueAttribute as String, "Human")
                case "document": f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                default: _ = f.appendTrack(name: "New physical member", selected: false)
                }
                let runtime = f.runtime
                let result = await SystemDispatcher.handle(command: "saga_execute", params: [:], router: f.router,
                    cache: f.cache, targetRegistry: f.registry, dialogPresent: { false },
                    sagaJournal: journal, mutationGate: LogicMutationGate(), sagaRefreshAfterWrite: {},
                    liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                    liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) },
                    sagaLiveReadback: .unavailable, approvedSessionRepair: approval)
                #expect(sharedJSONObject(sharedToolText(result))?["state"] as? String == "C")
                #expect(f.writes.isEmpty && f.routedOperations.isEmpty && f.events.isEmpty)
            }
        }
    }

    @Test func canonicalNameJournalCancellationUsesTheSameOwnedInverseAndReplay() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = ExactNameFixture()
                let (capture, project, target, _, mirror) = try await f.coupledCapture()
                let journal = SagaJournal()
                let key = "cancel-canonical-name-in-dispatcher"
                let approval = try await f.canonicalNameApproval(capture, project: project, target: target,
                    desired: "Canonical", key: key, journal: journal)
                let runtime = f.runtime
                func run() async -> CallTool.Result {
                    await SystemDispatcher.handle(command: "saga_execute", params: [:], router: f.router,
                        cache: f.cache, targetRegistry: f.registry, dialogPresent: { false },
                        sagaJournal: journal, mutationGate: LogicMutationGate(), sagaRefreshAfterWrite: {
                            if f.writes == ["Canonical"] {
                                #expect(await journal.cancel(idempotencyKey: key) == .requested)
                            }
                        }, liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                        liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) },
                        sagaLiveReadback: .unavailable, approvedSessionRepair: approval)
                }
                let outcome = try #require(sharedJSONObject(sharedToolText(await run())))
                #expect(outcome["saga_state"] as? String == "fullyCompensated")
                #expect(f.writes == ["Canonical", "A"])
                #expect(f.builder.attributeValue(f.field, kAXDescriptionAttribute as String) as? String == "A")
                #expect(f.builder.attributeValue(mirror, kAXValueAttribute as String) as? String == "A")
                guard case .cancelled(_, verified: true)? = await journal.record(for: key) else {
                    Issue.record("actual canonical journal cancellation must verify its own inverse"); return
                }
                let planID = try #require(approval.plan.canonicalPlanID)
                let digest = try #require(approval.plan.canonicalDigest)
                let request = try #require(ApprovedSessionRepair.ApplyRequest.parse([
                    "plan_id": .string(planID), "digest": .string(digest),
                    "confirmed": .bool(true), "idempotency_key": .string(key)]))
                let dependencies = HandlerDependencies(router: f.router, cache: f.cache,
                    targetRegistry: f.registry,
                    poller: StatePoller(axChannel: AccessibilityChannel(), cache: f.cache,
                        runtime: .init(hasVisibleWindow: { false })),
                    dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal,
                    mutationGate: LogicMutationGate(),
                    liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) },
                    projectFileReader: .unavailable)
                let replay = try #require(sharedJSONObject(sharedToolText(
                    await ApprovedSessionRepair.apply(request: request, dependencies: dependencies))))
                #expect(replay["saga_state"] as? String == "fullyCompensated")
                let duplicate = try #require(replay["duplicate"] as? Bool)
                #expect(duplicate)
                #expect(f.writes == ["Canonical", "A"])
            }
        }
    }

    @Test(arguments: ["observed", "different_name", "missing", "duplicate", "unrequested", "stale"])
    func canonicalNamePreviewAccountsForOnlyProducerObservedAssociatedStrips(_ observation: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (capture, project, target, _, _) = try await f.coupledCapture(link: observation)
            let raw: [String: Value] = [
                "schema": .string(ProjectSessionAudit.intentPolicySchema),
                "project_ref": .string(project.rawValue),
                "targets": .array([.object(["handle": .string("exact"), "track_ref": .string(target.rawValue)])])
            ]
            guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
                Issue.record("The explicit naming policy was rejected")
                return
            }
            let desired = "Exact, \"한글\" 😀"
            let domains: [SessionPopulationObservation.Domain] = observation == "unrequested"
                ? [.tracks, .strips] : [.tracks, .strips, .associations]
            let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
                names: [.init(target: "exact", name: desired)], capture: capture,
                request: .init(domains: domains), snapshotCurrent: observation != "stale")
            let wire = try JSONDecoder().decode(Value.self, from: Data(plan.json.utf8))
            let body = try #require(wire.objectValue)
            let steps = try #require(body["steps"]?.arrayValue)
            let step = try #require(steps.first?.objectValue)
            #expect(body["preview"] == body["steps"])
            #expect(step["after"]?.objectValue?["name"] == .string(desired))
            if observation == "observed" || observation == "different_name" {
                let strip = try #require(capture.mixerReference(at: 0))
                #expect(step["associated_strip_names"] == .array([.object([
                    "target_ref": .string(strip.rawValue), "observed_name": .string(observation == "different_name" ? "B" : "A"),
                    "source": .string("held_exclusive_selection_focus")
                ])]))
            } else {
                // Unknown association is not an observed empty affected-object set.
                #expect(step["associated_strip_names"] == .null)
            }
            #expect(body["executable"] == .bool(false))
            let blocked = try #require(step["blocked_reasons"]?.arrayValue)
            #expect(blocked.contains(.string("naming_preservation_adapter_unavailable")))
            #expect(f.routedOperations.isEmpty && f.writes.isEmpty && f.events.isEmpty)
        }
    }

    @Test func openingTheRenameMenuCannotClaimAnExternalDesiredMirrorAsOwnTypingPreview() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (capture, project, target, _, mirror) = try await f.coupledCapture()
            f.passiveHeaderNameLabel = true
            f.builder.setAttribute(f.field, kAXValueAttribute as String, NSNumber(value: 0))
            f.builder.setAttributeSettable(f.field, kAXValueAttribute as String, false)
            let bar = f.builder.element(968_180)
            let trackMenu = f.builder.element(968_181)
            let menu = f.builder.element(968_182)
            let rename = f.builder.element(968_183)
            let editor = f.builder.element(968_184)
            f.renameMenuItem = rename
            f.menuFocusedEditor = editor
            f.builder.setAttribute(f.app, kAXMenuBarAttribute as String, bar)
            for (element, role) in [(bar, kAXMenuBarRole), (trackMenu, kAXMenuBarItemRole),
                                   (menu, kAXMenuRole), (rename, kAXMenuItemRole), (editor, kAXTextFieldRole)] {
                f.builder.setAttribute(element, kAXRoleAttribute as String, role as String)
            }
            f.builder.setAttribute(trackMenu, kAXTitleAttribute as String, AXLocalePolicy.trackMenuBar.canonical)
            f.builder.setAttribute(rename, kAXTitleAttribute as String, AXLocalePolicy.renameTrackMenuItem.canonical)
            f.builder.setAttribute(editor, kAXWindowAttribute as String, f.window)
            f.builder.setAttribute(editor, kAXValueAttribute as String, "A")
            f.builder.setAttributeSettable(editor, kAXValueAttribute as String, false)
            f.builder.setChildren(bar, [trackMenu])
            f.builder.setChildren(trackMenu, [menu])
            f.builder.setChildren(menu, [rename])
            f.onRenameMenuRead = { f.builder.setAttribute(mirror, kAXValueAttribute as String, "C") }
            let result = await f.applyCoupled(capture, project: project, target: target)
            #expect(result.status == .attemptedUnverified)
            #expect(result.inverse == nil)
            #expect(f.events == ["rename_menu"])
            #expect(f.typedCodeUnits.isEmpty)
            #expect(!f.postedReturn)
            #expect(f.menuEditorValueWrites.isEmpty && f.writes.isEmpty)
            #expect(f.builder.attributeValue(mirror, kAXValueAttribute as String) as? String == "C")
            #expect(f.builder.attributeValue(f.field, kAXDescriptionAttribute as String) as? String == "A")
        }
    }

    @Test(arguments: [false, true])
    func aNewerMirrorAtTheEditorBoundaryStopsTheNextCoupledWrite(inverting: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (capture, project, target, _, mirror) = try await f.coupledCapture()
            let proof: ExactTrackNameAdapter.OwnedInverse?
            if inverting {
                proof = try #require((await f.applyCoupled(capture, project: project, target: target)).inverse)
            } else { proof = nil }
            f.onPress = { f.builder.setAttribute(mirror, kAXValueAttribute as String, "Human") }
            let result: ExactTrackNameAdapter.Receipt
            if let proof { result = await f.inverse(proof) }
            else { result = await f.applyCoupled(capture, project: project, target: target) }
            #expect(result.status == .attemptedUnverified)
            #expect(result.inverse == nil)
            #expect(f.writes == (inverting ? ["C"] : []))
            #expect(f.builder.attributeValue(mirror, kAXValueAttribute as String) as? String == "Human")
        }
    }

    @Test func aLaterMirrorReadCannotHideANewerPrimaryName() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (capture, project, target, _, _) = try await f.coupledCapture()
            f.onMirrorReadAfterWrite = { f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "Human") }
            let result = await f.applyCoupled(capture, project: project, target: target)
            #expect(result.status == .attemptedUnverified)
            #expect(result.inverse == nil)
            #expect(result.survivingReference == nil)
            #expect(f.writes == ["C"])
        }
    }

    @Test func capturedCoupledNameIsReadBackAndInvertedOnBothOriginalSources() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (capture, project, target, _, mirror) = try await f.coupledCapture()
            let result = await f.applyCoupled(capture, project: project, target: target)
            #expect(result.status == .applied)
            #expect(f.builder.attributeValue(mirror, kAXValueAttribute as String) as? String == "C")
            let proof = try #require(result.inverse)
            let restored = await f.inverse(proof)
            #expect(restored.status == .applied)
            #expect(restored.after == "A")
            #expect(f.builder.attributeValue(mirror, kAXValueAttribute as String) as? String == "A")
            #expect(f.writes == ["C", "A"])
        }
    }

    @Test(arguments: ["before", "after"])
    func coupledRenameDoesNotCertifyAnUnexpectedCapturedPeerRename(phase: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (_, peer) = f.appendTrack(name: "Peer", selected: false)
            let (capture, project, target, _, mirror) = try await f.coupledCapture()
            if phase == "before" {
                f.builder.setAttribute(peer, kAXDescriptionAttribute as String, "Newer peer")
            } else {
                let commitPair = f.onConfirm
                f.onConfirm = {
                    commitPair?()
                    f.builder.setAttribute(peer, kAXDescriptionAttribute as String, "Newer peer")
                }
            }
            let result = await f.applyCoupled(capture, project: project, target: target)
            #expect(result.status == (phase == "before" ? .rejectedBeforeWrite : .attemptedUnverified))
            #expect(result.inverse == nil)
            #expect(f.writes == (phase == "before" ? [] : ["C"]))
            #expect(f.builder.attributeValue(mirror, kAXValueAttribute as String) as? String
                == (phase == "before" ? "A" : "C"))
            #expect(f.builder.attributeValue(peer, kAXDescriptionAttribute as String) as? String == "Newer peer")
            let receipt = try #require(sharedJSONObject(sharedToolText(result.result)))
            #expect(receipt["state"] as? String == (phase == "before" ? "C" : "B"))
        }
    }

    @Test(arguments: ["before", "after"])
    func coupledRenameAlsoPreservesAnObservedMixerOnlyPeer(phase: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (capture, project, target, _, _) = try await f.coupledCapture(peerStripName: "Aux")
            let peer = try #require(f.coupledPeerNameField)
            if phase == "before" {
                f.builder.setAttribute(peer, kAXValueAttribute as String, "Newer aux")
            } else {
                let commitPair = f.onConfirm
                f.onConfirm = {
                    commitPair?()
                    f.builder.setAttribute(peer, kAXValueAttribute as String, "Newer aux")
                }
            }
            let result = await f.applyCoupled(capture, project: project, target: target)
            #expect(result.status == (phase == "before" ? .rejectedBeforeWrite : .attemptedUnverified))
            #expect(result.inverse == nil)
            #expect(f.writes == (phase == "before" ? [] : ["C"]))
            #expect(f.builder.attributeValue(peer, kAXValueAttribute as String) as? String == "Newer aux")
        }
    }

    @Test func coupledRenamePreservesIntentionalDuplicatesAndDoesNotUndoANewerPeerName() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (_, peer) = f.appendTrack(name: "A", selected: false)
            let (capture, project, target, _, mirror) = try await f.coupledCapture(peerStripName: "A")
            let stripPeer = try #require(f.coupledPeerNameField)
            let forward = await f.applyCoupled(capture, project: project, target: target)
            #expect(forward.status == .applied)
            let inverse = try #require(forward.inverse)
            #expect(f.builder.attributeValue(peer, kAXDescriptionAttribute as String) as? String == "A")
            #expect(f.builder.attributeValue(stripPeer, kAXValueAttribute as String) as? String == "A")
            f.builder.setAttribute(peer, kAXDescriptionAttribute as String, "Newer track")
            f.builder.setAttribute(stripPeer, kAXValueAttribute as String, "Newer aux")
            let restored = await f.inverse(inverse)
            #expect(restored.status == .applied)
            #expect(f.writes == ["C", "A"])
            #expect(f.builder.attributeValue(mirror, kAXValueAttribute as String) as? String == "A")
            #expect(f.builder.attributeValue(peer, kAXDescriptionAttribute as String) as? String == "Newer track")
            #expect(f.builder.attributeValue(stripPeer, kAXValueAttribute as String) as? String == "Newer aux")
        }
    }

    @Test func aFinalPeerReadCannotCertifyANewerPrimaryAndMirrorName() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let healthy = ExactNameFixture()
            _ = healthy.appendTrack(name: "Peer", selected: false)
            let (baseline, baselineProject, baselineTarget, _, _) = try await healthy.coupledCapture()
            #expect((await healthy.applyCoupled(baseline, project: baselineProject, target: baselineTarget)).status == .applied)
            let finalRead = healthy.peerNameReadsAfterWrite
            #expect(finalRead > 0)
            let f = ExactNameFixture()
            _ = f.appendTrack(name: "Peer", selected: false)
            let (capture, project, target, _, mirror) = try await f.coupledCapture()
            f.onPeerNameReadAfterWrite = { count in
                if count == finalRead {
                    f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "Newer pair")
                    f.builder.setAttribute(mirror, kAXValueAttribute as String, "Newer pair")
                }
            }
            let result = await f.applyCoupled(capture, project: project, target: target)
            #expect(f.peerNameReadsAfterWrite >= finalRead)
            #expect(f.builder.attributeValue(f.field, kAXDescriptionAttribute as String) as? String == "Newer pair")
            #expect(result.status == .attemptedUnverified)
            #expect(result.inverse == nil && result.survivingReference == nil)
            #expect(f.writes == ["C"])
            let receipt = try #require(sharedJSONObject(sharedToolText(result.result)))
            #expect(receipt["state"] as? String == "B")
        }
    }

    @Test func ownedInverseCannotCertifyItsOwnUnexpectedChangeToANewerPeerName() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (_, peer) = f.appendTrack(name: "Peer", selected: false)
            let (capture, project, target, _, _) = try await f.coupledCapture()
            let forward = await f.applyCoupled(capture, project: project, target: target)
            let proof = try #require(forward.inverse)
            f.builder.setAttribute(peer, kAXDescriptionAttribute as String, "Newer peer")
            let commitPair = f.onConfirm
            f.onConfirm = {
                commitPair?()
                f.builder.setAttribute(peer, kAXDescriptionAttribute as String, "Unexpected peer")
            }
            let restored = await f.inverse(proof)
            #expect(restored.status == .attemptedUnverified)
            #expect(restored.inverse == nil)
            #expect(f.writes == ["C", "A"])
            #expect(f.builder.attributeValue(peer, kAXDescriptionAttribute as String) as? String == "Unexpected peer")
            let receipt = try #require(sharedJSONObject(sharedToolText(restored.result)))
            #expect(receipt["state"] as? String == "B")
        }
    }

    @Test(arguments: ["track_before", "track_after", "strip_before", "strip_after"])
    func aCoupledNameCannotCertifyAnUnexpectedNewPhysicalMember(phase: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (capture, project, target, strip, mirror) = try await f.coupledCapture()
            let mixer: AXUIElement = try #require(AXHelpers.getAttribute(strip, kAXParentAttribute as String, runtime: f.runtime.ax))
            let added = f.builder.element(968_180)
            let addedName = f.builder.element(968_181)
            f.builder.setRole(added, kAXLayoutItemRole as String)
            f.builder.setRole(addedName, kAXTextFieldRole as String)
            f.builder.setAttribute(addedName, kAXDescriptionAttribute as String, phase.hasPrefix("track") ? "New track" : "name")
            f.builder.setAttribute(addedName, kAXValueAttribute as String, "New strip")
            f.builder.setChildren(addedName, [])
            f.builder.setChildren(added, [addedName])
            let addMember: @Sendable () -> Void = {
                if phase.hasPrefix("track") { f.builder.setChildren(f.rail, [f.header, added]) }
                else { f.builder.setChildren(mixer, [strip, added]) }
            }
            if phase.hasSuffix("before") { addMember() }
            else {
                f.onConfirm = {
                    f.builder.setAttribute(mirror, kAXValueAttribute as String,
                        f.builder.attributeValue(f.field, kAXDescriptionAttribute as String))
                    addMember()
                }
            }
            let result = await f.applyCoupled(capture, project: project, target: target)
            #expect(result.status == (phase.hasSuffix("before") ? .rejectedBeforeWrite : .attemptedUnverified))
            #expect(result.inverse == nil)
            #expect(result.survivingReference == nil)
            #expect(f.writes == (phase.hasSuffix("before") ? [] : ["C"]))
            let members = try #require(AXLogicProElements.childrenIfRead(phase.hasPrefix("track") ? f.rail : mixer,
                runtime: f.runtime.ax))
            #expect(members.contains { CFEqual($0, added) })
        }
    }

    @Test func inversePeerBaselineDoesNotReadFocusMovingHelpInTheMixerCensus() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (capture, project, target, strip, _) = try await f.coupledCapture(peerStripName: "Aux")
            let forward = await f.applyCoupled(capture, project: project, target: target)
            let proof = try #require(forward.inverse)
            let mixer: AXUIElement = try #require(AXHelpers.getAttribute(strip, kAXParentAttribute as String, runtime: f.runtime.ax))
            // The same original source now uses the actual description-based
            // census instead of its legacy identifier fast path.
            f.builder.removeAttribute(mixer, kAXIdentifierAttribute as String)
            f.builder.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
            f.countRawHelpReads = true
            let restored = await f.inverse(proof)
            #expect(restored.status == .applied)
            #expect(f.writes == ["C", "A"])
            #expect(f.rawHelpReads == 0)
        }
    }

    @Test(arguments: ["missing", "duplicate", "stale_mirror"])
    func aCoupledNameNeedsOneCurrentCapturedPhysicalPairBeforeWriting(fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (capture, project, target, _, mirror) = try await f.coupledCapture(link: fault)
            if fault == "stale_mirror" { f.builder.setAttribute(mirror, kAXValueAttribute as String, "Newer") }
            let result = await f.applyCoupled(capture, project: project, target: target)
            #expect(result.status == .rejectedBeforeWrite)
            #expect(result.inverse == nil)
            #expect(f.writes.isEmpty && f.events.isEmpty)
        }
    }

    @Test func anUnchangedMirrorAfterTheActualTrackWriteCannotGrantACoupledInverse() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (capture, project, target, _, _) = try await f.coupledCapture()
            f.onConfirm = nil
            let result = await f.applyCoupled(capture, project: project, target: target)
            #expect(result.status == .attemptedUnverified)
            #expect(result.inverse == nil)
            #expect(result.survivingReference == nil)
            #expect(sharedJSONObject(sharedToolText(result.result))?["state"] as? String == "B")
            #expect(f.writes == ["C"])
        }
    }

    @Test(arguments: ["newer", "replacement"])
    func aCoupledInverseCannotOverwriteANewerOrReplacedMirror(fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (capture, project, target, strip, mirror) = try await f.coupledCapture()
            let applied = await f.applyCoupled(capture, project: project, target: target)
            let proof = try #require(applied.inverse)
            if fault == "newer" { f.builder.setAttribute(mirror, kAXValueAttribute as String, "Human") }
            else {
                let replacement = f.builder.element(968_173)
                f.builder.setRole(replacement, kAXLayoutItemRole as String)
                let parent: AXUIElement? = AXHelpers.getAttribute(strip, kAXParentAttribute as String, runtime: f.runtime.ax)
                let mixer = try #require(parent)
                f.builder.setChildren(mixer, [replacement])
            }
            let result = await f.inverse(proof)
            #expect(result.status == .rejectedBeforeWrite)
            #expect(result.inverse == nil)
            #expect(f.writes == ["C"])
        }
    }

    @Test(arguments: ["ownership", "cancel", "deadline", "healthy"])
    func successfulFinalAdapterNameReadCannotOutliveOperationAuthority(loss: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let healthy = ExactNameFixture()
            let (healthyProject, healthyTarget) = try await healthy.prepare(typedProducer: true)
            let confirmed = await OperationTraceContext.$current.withValue(OperationTraceContext(ownsGate: { true })) {
                await healthy.apply(project: healthyProject, target: healthyTarget, before: "A", after: "C")
            }
            #expect(confirmed.status == .applied)
            let finalNameRead = healthy.nameReadsAfterWrite
            #expect(finalNameRead > 0)

            let f = ExactNameFixture()
            let (project, target) = try await f.prepare(typedProducer: true)
            let deadline = loss == "deadline" ? ContinuousClock.now.advanced(by: .seconds(1)) : nil
            f.onNameReadAfterWrite = {
                guard f.nameReadsAfterWrite == finalNameRead else { return }
                if loss == "ownership" { f.boundaryOwnership = false }
                if loss == "cancel" { f.boundaryCancellation = true }
                // The final AX read remains successful and returns our written
                // name; only the operation authority expires during that read.
                if let deadline {
                    while ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.001) }
                }
            }
            let context = OperationTraceContext(ownsGate: { f.boundaryOwnership }, deadline: deadline,
                                                cancellationRequested: { f.boundaryCancellation })
            let receipt = await OperationTraceContext.$current.withValue(context) {
                await f.apply(project: project, target: target, before: "A", after: "C")
            }
            #expect(f.nameReadsAfterWrite == finalNameRead)
            #expect(f.writes == ["C"])
            #expect(receipt.before == "A")
            #expect(receipt.after == "C")
            let body = try #require(sharedJSONObject(sharedToolText(receipt.result)))
            if loss == "healthy" {
                #expect(receipt.status == .applied)
                #expect(receipt.inverse != nil)
                #expect(receipt.survivingReference == target)
                #expect(body["state"] as? String == "A")
            } else {
                #expect(receipt.status == .attemptedUnverified)
                #expect(receipt.inverse == nil)
                #expect(receipt.survivingReference == nil)
                #expect(body["state"] as? String == "B")
                let verified = try #require(body["verified"] as? Bool)
                let wrote = try #require(body["write_attempted"] as? Bool)
                #expect(!verified)
                #expect(wrote)
            }
        }
    }

    @Test(arguments: ["header", "name", "document"])
    func latePhysicalCustodyLossCannotGrantAnInverse(change: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            // Measure the unchanged scalar dispatcher, not the adapter being
            // repaired. The next permission read is the adapter's own boundary
            // after committed writer readback and reference rebind.
            let healthy = ExactNameFixture()
            let (healthyProject, healthyTarget) = try await healthy.prepare(typedProducer: true)
            let healthyContext = OperationTraceContext(ownsGate: {
                healthy.adapterPermissionReads += 1
                return true
            })
            let scalar = await OperationTraceContext.$current.withValue(healthyContext) {
                await healthy.rename(project: healthyProject, target: healthyTarget, expected: "A", desired: "C")
            }
            let scalarBody = try #require(sharedJSONObject(sharedToolText(scalar)))
            #expect(scalarBody["state"] as? String == "A")
            let adapterBoundary = healthy.adapterPermissionReads + 1

            let f = ExactNameFixture()
            let (project, target) = try await f.prepare(typedProducer: true)
            let replacement = f.appendTrack(name: "C", selected: true).0
            // Keep the original starting population equal to the scalar control.
            f.builder.setChildren(f.rail, [f.header])
            let context = OperationTraceContext(ownsGate: {
                f.adapterPermissionReads += 1
                if f.adapterPermissionReads == adapterBoundary {
                    switch change {
                    case "header": f.builder.setChildren(f.rail, [replacement])
                    case "name": f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "Newer edit")
                    default: f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                    }
                }
                return true
            })
            let receipt = await OperationTraceContext.$current.withValue(context) {
                await f.apply(project: project, target: target, before: "A", after: "C")
            }
            #expect(f.adapterPermissionReads >= adapterBoundary)
            #expect(f.writes == ["C"])
            #expect(receipt.status == .attemptedUnverified)
            #expect(receipt.inverse == nil)
            #expect(receipt.survivingReference == nil)
            #expect(receipt.before == "A")
            #expect(receipt.after == "C")
            let body = try #require(sharedJSONObject(sharedToolText(receipt.result)))
            #expect(body["state"] as? String == "B")
            let verified = try #require(body["verified"] as? Bool)
            #expect(!verified)
            let wrote = try #require(body["write_attempted"] as? Bool)
            #expect(wrote)
        }
    }

    @Test func losingTheFinalAdapterPermissionCannotReturnTheWritersEarlierStateA() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            // Learn the last adapter check from the same healthy production path,
            // then lose ownership exactly there, after the writer has committed.
            let healthy = ExactNameFixture()
            let (healthyProject, healthyTarget) = try await healthy.prepare(typedProducer: true)
            let healthyContext = OperationTraceContext(ownsGate: {
                healthy.adapterPermissionReads += 1
                return true
            })
            let confirmed = await OperationTraceContext.$current.withValue(healthyContext) {
                await healthy.apply(project: healthyProject, target: healthyTarget, before: "A", after: "C")
            }
            #expect(confirmed.status == .applied)
            #expect(confirmed.inverse != nil)
            let finalCheck = healthy.adapterPermissionReads
            #expect(finalCheck > 0)

            let lost = ExactNameFixture()
            let (project, target) = try await lost.prepare(typedProducer: true)
            let lostContext = OperationTraceContext(ownsGate: {
                lost.adapterPermissionReads += 1
                return lost.adapterPermissionReads < finalCheck
            })
            let receipt = await OperationTraceContext.$current.withValue(lostContext) {
                await lost.apply(project: project, target: target, before: "A", after: "C")
            }
            #expect(lost.adapterPermissionReads == finalCheck)
            #expect(receipt.status == .attemptedUnverified)
            #expect(receipt.inverse == nil)
            #expect(receipt.survivingReference == nil)
            #expect(lost.writes == ["C"])
            #expect(receipt.before == "A")
            #expect(receipt.after == "C")
            let body = try #require(sharedJSONObject(sharedToolText(receipt.result)))
            #expect(body["state"] as? String == "B")
            let verified = try #require(body["verified"] as? Bool)
            #expect(!verified)
            #expect(body["reason"] as? String == "readback_unavailable")
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(attempted)
            let isError = try #require(receipt.result.isError)
            #expect(isError)
        }
    }

    @Test(arguments: ["C", "B"])
    func staleBeforeAfterVerifiedRenameOnSameReferenceRefusesBeforeWrite(desired: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            let changed = await f.rename(project: project, target: target, expected: nil, desired: "B")
            let changedBody = try #require(sharedJSONObject(sharedToolText(changed)))
            #expect(try #require(changedBody["state"] as? String) == "A")
            #expect(f.writes == ["B"])
            let stale = await f.rename(project: project, target: target, expected: "A", desired: desired)
            let isError = stale.isError ?? false
            #expect(isError)
            #expect(f.writes == ["B"])
            let binding = try #require(await f.registry.resolve(target))
            #expect(binding.descriptor.trackName == "B")
        }
    }

    @Test func actualHeldFieldBeforeSetterMustStillMatchExpectedBytes() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            f.editOnPress = "User edit"
            let result = await f.rename(project: project, target: target, expected: "A", desired: "C")
            let isError = result.isError ?? false
            #expect(isError)
            #expect(f.writes.isEmpty)
            #expect(AXLogicProElements.trackName(at: 0, runtime: f.runtime) == "User edit")
        }
    }

    @Test func acknowledgementWithoutActualReadbackCannotRebindExactRequest() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            f.acknowledgementOnly = true
            let result = await f.rename(project: project, target: target, expected: "A", desired: "C")
            let isError = result.isError ?? false
            #expect(isError)
            let binding = try #require(await f.registry.resolve(target))
            #expect(binding.descriptor.trackName == "A")
            #expect(await f.cache.getTracks().first?.name == "A")
            #expect(f.writes.isEmpty)
        }
    }

    @Test func exactAlreadySatisfiedUnselectedTargetRequiresNoActuationOrInverse() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture("  Same, \"raw\"  ")
            let (project, target) = try await f.prepare()
            f.builder.setAttribute(f.header, kAXSelectedAttribute as String, false)
            let receipt = await f.apply(project: project, target: target, before: "  Same, \"raw\"  ", after: "  Same, \"raw\"  ")
            #expect(receipt.status == .alreadySatisfied)
            #expect(receipt.survivingReference == target)
            #expect(receipt.inverse == nil)
            #expect(f.writes.isEmpty)
            #expect(f.events.isEmpty)
            let selected = try #require(AXValueExtractors.extractSelectedState(f.header, runtime: f.runtime.ax))
            #expect(!selected)
        }
    }

    @Test(arguments: ["Aux, 1", "\"Quoted\"", "  padded 🎹  ", "q\u{0323}\u{0301}"])
    func rawNamesAndOwnedInverseUseActualReadbackAndSameReference(name: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let before = "q\u{0301}\u{0323}"
            let f = ExactNameFixture(before)
            let (project, target) = try await f.prepare()
            let receipt = await f.apply(project: project, target: target, before: before, after: name)
            #expect(receipt.status == .applied)
            #expect(try #require(receipt.before).utf8.elementsEqual(before.utf8))
            #expect(try #require(receipt.after).utf8.elementsEqual(name.utf8))
            #expect(receipt.survivingReference == target)
            #expect(f.writes.count == 1)
            #expect(try #require(f.writes.first).utf8.elementsEqual(name.utf8))
            let reversed = await f.inverse(try #require(receipt.inverse))
            #expect(reversed.status == .applied)
            #expect(try #require(reversed.before).utf8.elementsEqual(name.utf8))
            #expect(try #require(reversed.after).utf8.elementsEqual(before.utf8))
            #expect(reversed.survivingReference == target)
            #expect(f.writes.count == 2)
            let binding = try #require(await f.registry.resolve(target))
            #expect(binding.descriptor.trackName.utf8.elementsEqual(before.utf8))
        }
    }

    @Test func ownedInverseRefusesASeparateUserEdit() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            let applied = await f.apply(project: project, target: target, before: "A", after: "B")
            let inverse = try #require(applied.inverse)
            f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "User edit")
            let refused = await f.inverse(inverse)
            #expect(refused.status == .rejectedBeforeWrite)
            #expect(refused.inverse == nil)
            #expect(f.writes == ["B"])
            #expect(AXLogicProElements.trackName(at: 0, runtime: f.runtime) == "User edit")
        }
    }

    @Test func lostAfterReadbackStopsWithoutRetryOrOwnedInverse() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            f.hideReadbackAfterSet = true
            let receipt = await f.apply(project: project, target: target, before: "A", after: "B")
            #expect(receipt.status == .attemptedUnverified)
            #expect(receipt.before == "A")
            #expect(receipt.after == nil)
            #expect(receipt.inverse == nil)
            #expect(receipt.survivingReference == nil)
            #expect(f.writes == ["B"])
            #expect(f.events == [kAXPressAction as String, kAXConfirmAction as String])
            #expect(await f.cache.getTracks().first?.name == "A")
            #expect(try #require(await f.registry.resolve(target)).descriptor.trackName == "A")
        }
    }

    @Test(arguments: ["", String(repeating: "x", count: 129), "line\nfeed"])
    func invalidRawNamesAreRejectedBeforeAnyWrite(name: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            let receipt = await f.apply(project: project, target: target, before: "A", after: name)
            #expect(receipt.status == .rejectedBeforeWrite)
            #expect(receipt.inverse == nil)
            #expect(f.writes.isEmpty)
            #expect(f.events.isEmpty)
        }
    }

    @Test(arguments: ["project", "topology", "document", "cancel", "ownership", "deadline"])
    func changedProjectTopologyOrOperationOwnershipCannotWrite(change: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            if change == "project" { await f.registry.bumpProjectEpoch() }
            if change == "topology" { await f.registry.bumpTopologyGeneration() }
            if change == "document" {
                f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
            }
            let context = OperationTraceContext(
                mutationGateAcquired: true, ownsGate: { change != "ownership" },
                deadline: change == "deadline" ? ContinuousClock.now : nil,
                cancellationRequested: { change == "cancel" }
            )
            let receipt = await OperationTraceContext.$current.withValue(context) {
                await f.apply(project: project, target: target, before: "A", after: "B")
            }
            #expect(receipt.status == .rejectedBeforeWrite)
            #expect(f.writes.isEmpty)
            #expect(f.events.isEmpty)
            #expect(receipt.inverse == nil)
        }
    }

    @Test func byteDistinctEquivalentExpectedBeforeIsNotAuthority() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture("q\u{0301}\u{0323}")
            let (project, target) = try await f.prepare()
            let receipt = await f.apply(project: project, target: target, before: "q\u{0323}\u{0301}", after: "B")
            #expect(receipt.status == .rejectedBeforeWrite)
            #expect(f.writes.isEmpty)
            #expect(receipt.inverse == nil)
        }
    }

    @Test func duplicateDesiredNameDoesNotGrantContinuityButKeepsActualNameObservation() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let other = f.builder.element(968_110)
            let otherField = f.builder.element(968_111)
            f.builder.setAttribute(other, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            f.builder.setAttribute(other, kAXSelectedAttribute as String, false)
            f.builder.setAttribute(otherField, kAXRoleAttribute as String, kAXTextFieldRole as String)
            f.builder.setAttribute(otherField, kAXDescriptionAttribute as String, "Other")
            f.builder.setAttribute(otherField, kAXValueAttribute as String, "1")
            f.builder.setChildren(otherField, [])
            f.builder.setChildren(other, [otherField])
            f.builder.setChildren(f.rail, [f.header, other])
            let (project, target) = try await f.prepare()
            // A separate edit creates a collision only after our setter, at Confirm.
            // Initial duplicate evidence has its own pre-write refusal test below.
            f.onConfirm = {
                f.builder.setAttribute(otherField, kAXDescriptionAttribute as String, "B")
            }
            let receipt = await f.apply(project: project, target: target, before: "A", after: "B")
            #expect(receipt.status == .attemptedUnverified)
            #expect(receipt.before == "A")
            #expect(receipt.after == "B")
            #expect(receipt.survivingReference == nil)
            #expect(receipt.inverse == nil)
            #expect(f.writes == ["B"])
            #expect(AXLogicProElements.trackName(at: 1, runtime: f.runtime) == "B")
        }
    }

    @Test(arguments: ["remote", "localhost", ""])
    func actualDocumentAuthorityMustBeLocalBeforeActuation(host: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file://\(host)/tmp/ExactName.logicx")
            let receipt = await f.apply(project: project, target: target, before: "A", after: "B")
            if host == "remote" {
                #expect(receipt.status == .rejectedBeforeWrite)
                #expect(f.writes.isEmpty)
                #expect(f.events.isEmpty)
                #expect(receipt.inverse == nil)
            } else {
                #expect(receipt.status == .applied)
                #expect(f.writes == ["B"])
                #expect(receipt.survivingReference == target)
            }
        }
    }

    @Test func unsupportedDuplicateContinuityIsExposedBeforeSemanticWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let other = f.builder.element(968_120)
            let otherField = f.builder.element(968_121)
            f.builder.setAttribute(other, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            f.builder.setAttribute(other, kAXSelectedAttribute as String, false)
            f.builder.setAttribute(otherField, kAXRoleAttribute as String, kAXTextFieldRole as String)
            f.builder.setAttribute(otherField, kAXDescriptionAttribute as String, "B")
            f.builder.setAttribute(otherField, kAXValueAttribute as String, "1")
            f.builder.setChildren(otherField, [])
            f.builder.setChildren(other, [otherField])
            f.builder.setChildren(f.rail, [f.header, other])
            let (project, target) = try await f.prepare()
            let receipt = await f.apply(project: project, target: target, before: "A", after: "B")
            #expect(receipt.status == .rejectedBeforeWrite)
            #expect(f.writes.isEmpty)
            #expect(f.events.isEmpty)
            #expect(receipt.inverse == nil)
            #expect(AXLogicProElements.trackName(at: 0, runtime: f.runtime) == "A")
            #expect(AXLogicProElements.trackName(at: 1, runtime: f.runtime) == "B")
        }
    }

    @Test func documentSwitchDuringDecidingAfterReadCannotGrantOwnedInverse() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare()
            f.onNameReadAfterWrite = {
                f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file://remote/tmp/ExactName.logicx")
            }
            let receipt = await f.apply(project: project, target: target, before: "A", after: "B")
            #expect(receipt.status == .attemptedUnverified)
            #expect(receipt.survivingReference == nil)
            #expect(receipt.inverse == nil)
            #expect(f.writes == ["B"])
            #expect(await f.cache.getTracks().first?.name == "A")
        }
    }

    @Test func issuedTypedTrackReferenceCannotRenameSameNameReplacement() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare(typedProducer: true)
            let replacement = f.builder.element(968_130)
            let replacementField = f.builder.element(968_131)
            f.builder.setAttribute(replacement, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            f.builder.setAttribute(replacement, kAXSelectedAttribute as String, true)
            f.builder.setAttribute(replacementField, kAXRoleAttribute as String, kAXTextFieldRole as String)
            f.builder.setAttribute(replacementField, kAXDescriptionAttribute as String, "A")
            f.builder.setAttribute(replacementField, kAXValueAttribute as String, "0")
            f.builder.setChildren(replacementField, [])
            f.builder.setChildren(replacement, [replacementField])
            // Both physical fields accept and log the real writer's actions/setter.
            // A baseline wrong-target action must be observed, not hidden by a fake refusal.
            f.additionalNameFields.append(replacementField)
            f.builder.setChildren(f.rail, [replacement])
            let receipt = await f.apply(project: project, target: target, before: "A", after: "B")
            #expect(receipt.status == .rejectedBeforeWrite)
            #expect(receipt.inverse == nil)
            #expect(f.writes.isEmpty)
            #expect(f.events.isEmpty)
            #expect(f.actedNameFields.isEmpty)
            #expect(AXHelpers.getDescription(f.field, runtime: f.runtime.ax) == "A")
            #expect(AXHelpers.getDescription(replacementField, runtime: f.runtime.ax) == "A")
            #expect(await f.cache.getTracks().first?.name == "A")
        }
    }

    @Test func issuedDuplicateHeadersHaveIndependentUsableReferencesAndOwnedInverse() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (other, otherField) = f.appendTrack(name: "A", selected: true)
            f.builder.setAttribute(f.header, kAXSelectedAttribute as String, false)
            let (project, first) = try await f.prepare(typedProducer: true)
            let refs = try #require(await TrackReferenceIssuance.issue(for: await f.cache.getTracks(),
                registry: f.registry, snapshot: await f.registry.currentSnapshot))
            let second = try #require(refs.byRow[1])
            #expect(first != second)
            let secondBinding = try #require(await f.registry.resolve(second))
            #expect(CFEqual(try #require(secondBinding.physicalTrack).header, other))
            let receipt = await f.apply(project: project, target: second, before: "A", after: "B")
            #expect(receipt.status == .applied)
            #expect(receipt.survivingReference == second)
            #expect(AXHelpers.getDescription(f.field, runtime: f.runtime.ax) == "A")
            #expect(AXHelpers.getDescription(otherField, runtime: f.runtime.ax) == "B")
            #expect(f.actedNameFields.allSatisfy { CFEqual($0, otherField) })
            #expect(await f.cache.getTracks().map(\.name) == ["A", "B"])
            let reversed = await f.inverse(try #require(receipt.inverse))
            #expect(reversed.status == .applied)
            #expect(reversed.survivingReference == second)
            #expect(await f.cache.getTracks().map(\.name) == ["A", "A"])
            #expect(f.writes == ["B", "A"])
        }
    }

    @Test(arguments: [false, true])
    func issuedHeaderSurvivesPreApplyAndEditorBoundaryReorder(atPress: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (other, otherField) = f.appendTrack(name: "B", selected: false)
            let (project, target) = try await f.prepare(typedProducer: true)
            if atPress {
                f.onPress = { f.builder.setChildren(f.rail, [other, f.header]) }
            } else { f.builder.setChildren(f.rail, [other, f.header]) }
            let receipt = await f.apply(project: project, target: target, before: "A", after: "C")
            #expect(receipt.status == .applied)
            #expect(receipt.survivingReference == target)
            #expect(AXHelpers.getDescription(f.field, runtime: f.runtime.ax) == "C")
            #expect(AXHelpers.getDescription(otherField, runtime: f.runtime.ax) == "B")
            #expect(f.actedNameFields.allSatisfy { CFEqual($0, f.field) })
            #expect(await f.cache.getTracks().map(\.name) == ["C", "B"])
            #expect(try #require(await f.registry.resolve(target)).descriptor.trackIndex == 1)
            await f.cache.updateTracks(try #require(AccessibilityChannel.defaultGetTrackStates(runtime: f.runtime)))
            let refs = try #require(await TrackReferenceIssuance.issue(for: await f.cache.getTracks(),
                registry: f.registry, snapshot: await f.registry.currentSnapshot))
            #expect(refs.byRow[1] == target)
            let reversed = await f.inverse(try #require(receipt.inverse))
            #expect(reversed.status == .applied)
            #expect(await f.cache.getTracks().map(\.name) == ["B", "A"])
        }
    }

    @Test func twoPhysicalNameActionsCanSwapAndConditionallyReverseExactNames() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (other, otherField) = f.appendTrack(name: "B", selected: false)
            let (project, first) = try await f.prepare(typedProducer: true)
            let refs = try #require(await TrackReferenceIssuance.issue(for: await f.cache.getTracks(),
                registry: f.registry, snapshot: await f.registry.currentSnapshot))
            let second = try #require(refs.byRow[1])
            let firstChange = await f.apply(project: project, target: first, before: "A", after: "B")
            #expect(firstChange.status == .applied)
            f.builder.setAttribute(f.header, kAXSelectedAttribute as String, false)
            f.builder.setAttribute(other, kAXSelectedAttribute as String, true)
            let secondChange = await f.apply(project: project, target: second, before: "B", after: "A")
            #expect(secondChange.status == .applied)
            #expect(firstChange.survivingReference == first)
            #expect(secondChange.survivingReference == second)
            #expect(await f.cache.getTracks().map(\.name) == ["B", "A"])
            #expect(AXHelpers.getDescription(f.field, runtime: f.runtime.ax) == "B")
            #expect(AXHelpers.getDescription(otherField, runtime: f.runtime.ax) == "A")
            let reverseSecond = await f.inverse(try #require(secondChange.inverse))
            #expect(reverseSecond.status == .applied)
            f.builder.setAttribute(f.header, kAXSelectedAttribute as String, true)
            f.builder.setAttribute(other, kAXSelectedAttribute as String, false)
            let reverseFirst = await f.inverse(try #require(firstChange.inverse))
            #expect(reverseFirst.status == .applied)
            #expect(await f.cache.getTracks().map(\.name) == ["A", "B"])
            #expect(f.writes == ["B", "A", "B", "A"])
        }
    }

    @Test(arguments: ["unchanged", "reordered", "duplicate"])
    func typedTrackReferenceRetainsOriginalNonRenameGuards(shape: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (other, _) = f.appendTrack(name: shape == "duplicate" ? "A" : "B", selected: false)
            let mute = f.builder.element(968_150)
            f.builder.setAttribute(mute, kAXRoleAttribute as String, kAXCheckBoxRole as String)
            f.builder.setAttribute(mute, kAXDescriptionAttribute as String, "Mute")
            f.builder.setAttribute(mute, kAXValueAttribute as String, 0)
            f.builder.setChildren(mute, [])
            f.builder.setChildren(f.header, [f.field, mute])
            let (_, target) = try await f.prepare(typedProducer: true)
            if shape == "reordered" { f.builder.setChildren(f.rail, [other, f.header]) }
            let runtime = f.runtime
            let result = await TrackDispatcher.handle(command: "mute",
                params: ["target_ref": .string(target.rawValue), "enabled": .bool(false)],
                router: f.router, cache: f.cache, targetRegistry: f.registry,
                liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) })
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            if shape == "unchanged" {
                #expect(body["state"] as? String == "A")
                #expect(f.routedOperations == ["track.set_mute"])
                #expect(body["action"] as? String == "no-op")
            } else {
                #expect(body["state"] as? String == "C")
                #expect(f.routedOperations.isEmpty)
            }
            #expect(f.writes.isEmpty)
            #expect(f.events.isEmpty)
        }
    }

    @Test(arguments: ["missing", "duplicate", "document", "window", "external", "epoch", "topology", "json", "cancel", "ownership"])
    func issuedPhysicalTrackMustRetainItsOriginalOwnerAndUniqueMembership(change: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare(typedProducer: true)
            if change == "missing" { f.builder.setChildren(f.rail, []) }
            if change == "duplicate" { f.builder.setChildren(f.rail, [f.header, f.header]) }
            if change == "document" { f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx") }
            if change == "window" { f.builder.setAttribute(f.app, kAXWindowsAttribute as String, [AXUIElement]()) }
            if change == "external" { f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "User edit") }
            if change == "epoch" { await f.registry.bumpProjectEpoch() }
            if change == "topology" { await f.registry.bumpTopologyGeneration() }
            if change == "json" {
                let encoded = try JSONEncoder().encode(await f.cache.getTracks())
                let decoded = try JSONDecoder().decode([TrackState].self, from: encoded)
                #expect(decoded.allSatisfy { $0.physicalBinding == nil })
                await f.cache.updateTracks(decoded)
            }
            let context = OperationTraceContext(mutationGateAcquired: true,
                ownsGate: { change != "ownership" }, cancellationRequested: { change == "cancel" })
            let receipt = await OperationTraceContext.$current.withValue(context) {
                await f.apply(project: project, target: target, before: "A", after: "B")
            }
            #expect(receipt.status == .rejectedBeforeWrite)
            #expect(receipt.inverse == nil)
            #expect(f.writes.isEmpty)
            #expect(f.events.isEmpty)
            #expect(f.actedNameFields.isEmpty)
        }
    }

    @Test(arguments: [0, 1])
    func physicalReferenceCorroboratesAnExplicitCurrentIndex(requested: Int) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (other, otherField) = f.appendTrack(name: "B", selected: false)
            let (project, target) = try await f.prepare(typedProducer: true)
            f.builder.setChildren(f.rail, [other, f.header])
            let result = await f.rename(project: project, target: target, expected: "A", desired: "C", index: requested)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            if requested == 1 {
                #expect(body["state"] as? String == "A")
                #expect(f.writes == ["C"])
                #expect(f.actedNameFields.allSatisfy { CFEqual($0, f.field) })
            } else {
                #expect(body["state"] as? String == "C")
                #expect(f.writes.isEmpty)
                #expect(f.events.isEmpty)
            }
            #expect(AXHelpers.getDescription(otherField, runtime: f.runtime.ax) == "B")
        }
    }

    @Test(arguments: ["same", "other"])
    func physicalTrackReferenceCorroboratesCurrentProjectWithoutProjectRef(project: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (_, target) = try await f.prepare(typedProducer: true)
            let snapshot = await f.registry.currentSnapshot
            let issued = await ProjectReferenceIssuance.issue(
                cached: ProjectInfo(name: project == "same" ? "ExactName" : "Other",
                    filePath: project == "same" ? "/tmp/ExactName.logicx" : "/tmp/Other.logicx"),
                registry: f.registry, snapshot: snapshot)
            guard case .issued = issued else { Issue.record("Expected observed project"); return }
            #expect(await f.registry.currentSnapshot == snapshot)
            let runtime = f.runtime
            let result = await TrackDispatcher.handle(command: "rename",
                params: ["target_ref": .string(target.rawValue), "name": .string("B")],
                router: f.router, cache: f.cache, targetRegistry: f.registry,
                liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) })
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            if project == "same" {
                #expect(body["state"] as? String == "A")
                #expect(f.writes == ["B"])
            } else {
                #expect(body["state"] as? String == "C")
                #expect(f.writes.isEmpty)
                #expect(f.events.isEmpty)
                #expect(f.actedNameFields.isEmpty)
                #expect(await f.cache.getTracks().first?.name == "A")
            }
        }
    }

    @Test(arguments: ["direct", "selected_field", "menu_field"])
    func ordinaryTypedReferenceRenameKeepsSelectionAcquisitionWithoutWeakeningAdapter(shape: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (other, otherField) = f.appendTrack(name: "B", selected: true)
            f.builder.setAttribute(f.header, kAXSelectedAttribute as String, false)
            f.permitsSelection = true
            if shape != "direct" {
                f.builder.setChildren(f.header, [])
                f.builder.setAttribute(f.header, kAXTitleAttribute as String, "A")
                f.exposeFieldWhenSelected = shape == "selected_field"
            }
            if shape == "menu_field" {
                let bar = f.builder.element(968_160)
                let trackMenu = f.builder.element(968_161)
                let menu = f.builder.element(968_162)
                let rename = f.builder.element(968_163)
                f.renameMenuItem = rename
                f.builder.setAttribute(f.app, kAXMenuBarAttribute as String, bar)
                for (element, role) in [(bar, kAXMenuBarRole), (trackMenu, kAXMenuBarItemRole),
                                       (menu, kAXMenuRole), (rename, kAXMenuItemRole)] {
                    f.builder.setAttribute(element, kAXRoleAttribute as String, role as String)
                }
                f.builder.setAttribute(trackMenu, kAXTitleAttribute as String, AXLocalePolicy.trackMenuBar.canonical)
                f.builder.setAttribute(rename, kAXTitleAttribute as String, AXLocalePolicy.renameTrackMenuItem.canonical)
                f.builder.setChildren(bar, [trackMenu])
                f.builder.setChildren(trackMenu, [menu])
                f.builder.setChildren(menu, [rename])
            }
            let (project, target) = try await f.prepare(typedProducer: true)
            let exact = await f.apply(project: project, target: target, before: "A", after: "C")
            #expect(exact.status == .rejectedBeforeWrite)
            #expect(f.selectionWrites.isEmpty)
            #expect(f.events.isEmpty)
            let scalar = await f.rename(project: project, target: target, expected: nil, desired: "C")
            let body = try #require(sharedJSONObject(sharedToolText(scalar)))
            #expect(body["state"] as? String == "A")
            #expect(f.writes == ["C"])
            #expect(f.selectionWrites.count == 1)
            #expect(f.selectionWrites.allSatisfy { CFEqual($0, f.header) })
            #expect(f.actedNameFields.allSatisfy { CFEqual($0, f.field) })
            let selected = try #require(AXValueExtractors.extractSelectedState(f.header, runtime: f.runtime.ax) as Bool?)
            let otherSelected = try #require(AXValueExtractors.extractSelectedState(other, runtime: f.runtime.ax) as Bool?)
            #expect(selected)
            #expect(!otherSelected)
            #expect(AXHelpers.getDescription(otherField, runtime: f.runtime.ax) == "B")
        }
    }

    @Test func freshResourceReferenceAfterExternalReorderKeepsOldRefConservativeAndNewRefUsable() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (other, _) = f.appendTrack(name: "B", selected: false)
            let mute = f.builder.element(968_150)
            f.builder.setAttribute(mute, kAXRoleAttribute as String, kAXCheckBoxRole as String)
            f.builder.setAttribute(mute, kAXDescriptionAttribute as String, AXLocalePolicy.trackMuteButton.canonical)
            f.builder.setAttribute(mute, kAXValueAttribute as String, 0)
            f.builder.setChildren(mute, [])
            f.builder.setChildren(f.header, [f.field, mute])
            let (_, oldRef) = try await f.prepare(typedProducer: true)
            f.builder.setChildren(f.rail, [other, f.header])
            await f.cache.updateTracks(try #require(AccessibilityChannel.defaultGetTrackStates(runtime: f.runtime)))
            let resource = try await ResourceHandlers.readTracks(cache: f.cache, uri: "logic://tracks",
                targetRegistry: f.registry, fileReader: .unavailable)
            let rows = try #require(sharedJSONObject(sharedResourceText(resource))?["data"] as? [[String: Any]])
            let freshRef = TargetReference(rawValue: try #require(rows[1]["track_ref"] as? String))
            #expect(freshRef != oldRef)
            let binding = try #require(await f.registry.resolve(freshRef))
            #expect(binding.descriptor.trackIndex == 1)
            let runtime = f.runtime
            for (reference, expectedState) in [(oldRef, "C"), (freshRef, "A")] {
                let result = await TrackDispatcher.handle(command: "mute",
                    params: ["target_ref": .string(reference.rawValue), "enabled": .bool(false)],
                    router: f.router, cache: f.cache, targetRegistry: f.registry,
                    liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                    liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) })
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                #expect(body["state"] as? String == expectedState)
            }
            #expect(f.routedOperations == ["track.set_mute"])
            #expect(f.writes.isEmpty)
            #expect(f.events.isEmpty)
        }
    }

    @Test(arguments: ["healthy", "unselected", "multi", "gate_before_menu", "gate_after_editor", "ack_only", "foreign_focus", "newer_edit"])
    func exactAdapterMenuAcquiresOnlyItsAlreadySelectedHeldPassiveEditor(caseName: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (other, otherField) = f.appendTrack(name: "B", selected: caseName == "multi" || caseName == "unselected")
            f.builder.setAttribute(f.header, kAXSelectedAttribute as String, caseName != "unselected")
            f.passiveHeaderNameLabel = true
            f.builder.setAttribute(f.field, kAXValueAttribute as String, NSNumber(value: 0))
            f.builder.setAttributeSettable(f.field, kAXValueAttribute as String, false)
            let bar = f.builder.element(968_230), trackMenu = f.builder.element(968_231)
            let menu = f.builder.element(968_232), rename = f.builder.element(968_233)
            let editor = f.builder.element(968_234)
            f.renameMenuItem = rename
            f.menuFocusedEditor = editor
            f.builder.setAttribute(f.app, kAXMenuBarAttribute as String, bar)
            for (element, role) in [(bar, kAXMenuBarRole), (trackMenu, kAXMenuBarItemRole),
                                   (menu, kAXMenuRole), (rename, kAXMenuItemRole), (editor, kAXTextFieldRole)] {
                f.builder.setAttribute(element, kAXRoleAttribute as String, role as String)
            }
            f.builder.setAttribute(trackMenu, kAXTitleAttribute as String, AXLocalePolicy.trackMenuBar.canonical)
            f.builder.setAttribute(rename, kAXTitleAttribute as String, AXLocalePolicy.renameTrackMenuItem.canonical)
            f.builder.setAttribute(editor, kAXWindowAttribute as String, f.window)
            f.builder.setAttribute(editor, kAXValueAttribute as String, "A")
            f.builder.setAttributeSettable(editor, kAXValueAttribute as String, true)
            f.builder.setChildren(bar, [trackMenu])
            f.builder.setChildren(trackMenu, [menu])
            f.builder.setChildren(menu, [rename])
            f.onRenameMenuRead = {
                f.builder.setAttribute(editor, kAXValueAttribute as String,
                    AXHelpers.getDescription(f.field, runtime: f.runtime.ax) ?? "unread")
                if caseName == "gate_before_menu" { f.boundaryOwnership = false }
            }
            f.menuEditorSetterAcknowledgesOnly = caseName == "ack_only"
            f.onMenuEditorValueSet = {
                if caseName == "gate_after_editor" { f.boundaryOwnership = false }
                if caseName == "foreign_focus" { f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, otherField) }
            }
            let (project, target) = try await f.prepare(typedProducer: true)
            let context = OperationTraceContext(ownsGate: { f.boundaryOwnership })
            let receipt = await OperationTraceContext.$current.withValue(context) {
                await f.apply(project: project, target: target, before: "A", after: "C, exact")
            }
            let body = try #require(sharedJSONObject(sharedToolText(receipt.result)))
            if ["healthy", "newer_edit"].contains(caseName) {
                #expect(receipt.status == .applied)
                let proof = try #require(receipt.inverse)
                #expect(f.events == ["rename_menu"])
                #expect(f.writes == ["C, exact"])
                if caseName == "newer_edit" { f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "newer") }
                let inverse = await f.inverse(proof)
                #expect(inverse.status == (caseName == "healthy" ? .applied : .rejectedBeforeWrite))
                #expect(f.writes == (caseName == "healthy" ? ["C, exact", "A"] : ["C, exact"]))
                #expect(f.events == (caseName == "healthy" ? ["rename_menu", "rename_menu"] : ["rename_menu"]))
            } else if ["unselected", "multi", "gate_before_menu"].contains(caseName) {
                #expect(receipt.status == .rejectedBeforeWrite)
                #expect(body["state"] as? String == "C")
                let attempted = try #require(body["write_attempted"] as? Bool)
                #expect(!attempted)
                #expect(f.events.isEmpty)
                #expect(f.menuEditorValueWrites.isEmpty)
            } else {
                #expect(receipt.status == .attemptedUnverified)
                #expect(body["state"] as? String == "B")
                #expect(receipt.inverse == nil)
                #expect(f.events == ["rename_menu"])
                #expect(f.menuEditorValueWrites == ["C, exact"])
                #expect(f.writes.isEmpty)
                #expect(!f.postedReturn)
            }
            #expect(f.selectionWrites.isEmpty)
            #expect(f.actedNameFields.isEmpty)
            #expect(AXHelpers.getDescription(otherField, runtime: f.runtime.ax) == "B")
            let otherSelected = try #require(AXValueExtractors.extractSelectedState(other, runtime: f.runtime.ax) as Bool?)
            if caseName == "unselected" || caseName == "multi" { #expect(otherSelected) } else { #expect(!otherSelected) }
        }
    }

    @Test(arguments: [false, true], ["typing", "axvalue", "ack_only", "foreign_focus", "foreign_role"])
    func ordinaryMenuRenameRetainsItsExistingFocusedEditorTypingCapability(passiveHeaderLabel: Bool, editorRoute: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (other, otherField) = f.appendTrack(name: "B", selected: true)
            f.builder.setAttribute(f.header, kAXSelectedAttribute as String, false)
            f.builder.setAttribute(f.header, kAXTitleAttribute as String, "A")
            // Native Logic also retains a noneditable, numeric-zero name label on the
            // header. It is not the String-valued editor opened by Rename Track.
            if passiveHeaderLabel {
                f.passiveHeaderNameLabel = true
                f.builder.setAttribute(f.field, kAXValueAttribute as String, NSNumber(value: 0))
                f.builder.setAttributeSettable(f.field, kAXValueAttribute as String, false)
            }
            f.builder.setChildren(f.header, passiveHeaderLabel ? [f.field] : [])
            f.permitsSelection = true
            let bar = f.builder.element(968_180)
            let trackMenu = f.builder.element(968_181)
            let menu = f.builder.element(968_182)
            let rename = f.builder.element(968_183)
            let editor = f.builder.element(968_184)
            f.renameMenuItem = rename
            f.menuFocusedEditor = editor
            f.builder.setAttribute(f.app, kAXMenuBarAttribute as String, bar)
            for (element, role) in [(bar, kAXMenuBarRole), (trackMenu, kAXMenuBarItemRole),
                                   (menu, kAXMenuRole), (rename, kAXMenuItemRole), (editor, kAXTextFieldRole)] {
                f.builder.setAttribute(element, kAXRoleAttribute as String, role as String)
            }
            f.builder.setAttribute(trackMenu, kAXTitleAttribute as String, AXLocalePolicy.trackMenuBar.canonical)
            f.builder.setAttribute(rename, kAXTitleAttribute as String, AXLocalePolicy.renameTrackMenuItem.canonical)
            f.builder.setAttribute(editor, kAXWindowAttribute as String, f.window)
            f.builder.setAttribute(editor, kAXValueAttribute as String, "A")
            f.builder.setAttributeSettable(editor, kAXValueAttribute as String, editorRoute != "typing")
            if editorRoute == "foreign_role" {
                f.builder.setAttribute(editor, kAXRoleAttribute as String, kAXSliderRole as String)
            }
            f.menuEditorSetterAcknowledgesOnly = editorRoute == "ack_only"
            if editorRoute == "foreign_focus" {
                f.onMenuEditorValueSet = {
                    f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, otherField)
                }
            }
            f.builder.setChildren(bar, [trackMenu])
            f.builder.setChildren(trackMenu, [menu])
            f.builder.setChildren(menu, [rename])
            let (project, target) = try await f.prepare(typedProducer: true)
            let scalar = await f.rename(project: project, target: target, expected: nil, desired: "C")
            let body = try #require(sharedJSONObject(sharedToolText(scalar)))
            let succeeds = editorRoute == "typing" || editorRoute == "axvalue"
            #expect(body["state"] as? String == (succeeds ? "A" : "B"))
            #expect(f.writes == (succeeds ? ["C"] : []))
            #expect(f.typedCodeUnits == (editorRoute == "typing" ? Array("C".utf16) : []))
            #expect(f.menuEditorValueWrites == (["typing", "foreign_role"].contains(editorRoute) ? [] : ["C"]))
            if succeeds {
                #expect(f.postedReturn)
            } else {
                #expect(!f.postedReturn)
            }
            #expect(f.events == ["rename_menu"])
            #expect(f.selectionWrites.count == 1)
            #expect(f.selectionWrites.allSatisfy { CFEqual($0, f.header) })
            #expect(f.actedNameFields.isEmpty)
            #expect(AXHelpers.getDescription(otherField, runtime: f.runtime.ax) == "B")
            #expect(AXHelpers.getChildren(f.header, runtime: f.runtime.ax).count == (passiveHeaderLabel ? 1 : 0))
            let selected = try #require(AXValueExtractors.extractSelectedState(f.header, runtime: f.runtime.ax) as Bool?)
            let otherSelected = try #require(AXValueExtractors.extractSelectedState(other, runtime: f.runtime.ax) as Bool?)
            #expect(selected)
            #expect(!otherSelected)
        }
    }

    @Test(arguments: ["editable", "unreadable", "replacement", "ownership"])
    func ordinaryMenuRenameWaitsForTheSameHeldEditorToBecomeEditable(readiness: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            f.builder.setAttribute(f.header, kAXTitleAttribute as String, "A")
            f.builder.setChildren(f.header, [])
            let bar = f.builder.element(968_210)
            let trackMenu = f.builder.element(968_211)
            let menu = f.builder.element(968_212)
            let rename = f.builder.element(968_213)
            let editor = f.builder.element(968_214)
            f.renameMenuItem = rename
            f.menuFocusedEditor = editor
            f.builder.setAttribute(f.app, kAXMenuBarAttribute as String, bar)
            for (element, role) in [(bar, kAXMenuBarRole), (trackMenu, kAXMenuBarItemRole),
                                   (menu, kAXMenuRole), (rename, kAXMenuItemRole), (editor, kAXGroupRole)] {
                f.builder.setAttribute(element, kAXRoleAttribute as String, role as String)
            }
            f.builder.setAttribute(trackMenu, kAXTitleAttribute as String, AXLocalePolicy.trackMenuBar.canonical)
            f.builder.setAttribute(rename, kAXTitleAttribute as String, AXLocalePolicy.renameTrackMenuItem.canonical)
            f.builder.setAttribute(editor, kAXWindowAttribute as String, f.window)
            f.builder.setAttribute(editor, kAXValueAttribute as String, "A")
            f.builder.setChildren(bar, [trackMenu])
            f.builder.setChildren(trackMenu, [menu])
            f.builder.setChildren(menu, [rename])
            if readiness == "unreadable" {
                f.builder.setAttribute(editor, kAXRoleAttribute as String, NSNumber(value: 0))
            }
            let stranger = f.builder.element(968_215)
            f.builder.setAttribute(stranger, kAXRoleAttribute as String, kAXTextFieldRole as String)
            f.builder.setAttribute(stranger, kAXWindowAttribute as String, f.window)
            f.onTypingSleep = { micros in
                if micros == 50_000 {
                    f.builder.setAttribute(editor, kAXInsertionPointLineNumberAttribute as String, NSNumber(value: 0))
                    if readiness == "replacement" {
                        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, stranger)
                    }
                    if readiness == "ownership" { f.boundaryOwnership = false }
                }
            }
            let (project, target) = try await f.prepare(typedProducer: true)
            let context = OperationTraceContext(ownsGate: { f.boundaryOwnership })
            let result = await OperationTraceContext.$current.withValue(context) {
                await f.rename(project: project, target: target, expected: nil, desired: "C")
            }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            if readiness == "editable" {
                #expect(body["state"] as? String == "A")
                #expect(f.writes == ["C"])
                #expect(f.typedCodeUnits == Array("C".utf16))
                #expect(f.postedReturn)
                #expect(f.typingSleeps == [50_000, 12_000, 50_000])
            } else {
                #expect(body["state"] as? String == "B")
                #expect(f.writes.isEmpty)
                #expect(f.typedCodeUnits.isEmpty)
                #expect(!f.postedReturn)
                #expect(f.typingSleeps == (readiness == "unreadable" ? [] : [50_000]))
                #expect(await f.cache.getTracks().first?.name == "A")
                #expect(await f.registry.resolve(target)?.descriptor.trackName == "A")
            }
            #expect(f.events == ["rename_menu"])
            #expect(f.actedNameFields.isEmpty)
        }
    }

    @Test func ordinaryRenameFinalSelectionReadFailureHasNoWriteAttemptOrUIEvent() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (other, otherField) = f.appendTrack(name: "B", selected: true)
            f.builder.setAttribute(f.header, kAXSelectedAttribute as String, false)
            f.permitsSelection = true
            // Only legacy role reads are intercepted: the status-preserving physical
            // and expected-name result reads remain healthy. The recorded actual
            // producer/dispatcher/writer path reaches its first selection setter
            // after legacy role read 21. Fail that final filter once, then keep
            // the original unselected A and selected B readable for settle.
            f.legacyHeaderRoleFailureRead = 21
            let (project, target) = try await f.prepare(typedProducer: true)
            let result = await f.rename(project: project, target: target, expected: nil, desired: "C")
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(f.legacyHeaderRoleFailures == 1)
            #expect(f.legacyHeaderRoleReads > 21)
            #expect(body["state"] as? String == "C")
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(!attempted)
            #expect(f.selectionWrites.isEmpty, "Legacy header role reads at selection: \(f.legacyHeaderReadsAtSelection)")
            #expect(f.events.isEmpty)
            #expect(f.writes.isEmpty)
            #expect(f.actedNameFields.isEmpty)
            let selected = try #require(AXValueExtractors.extractSelectedState(f.header, runtime: f.runtime.ax) as Bool?)
            let otherSelected = try #require(AXValueExtractors.extractSelectedState(other, runtime: f.runtime.ax) as Bool?)
            #expect(!selected)
            #expect(otherSelected)
            #expect(AXHelpers.getDescription(otherField, runtime: f.runtime.ax) == "B")
        }
    }

    @Test(arguments: ["ownership", "cancel", "deadline", "healthy"])
    func ordinaryRenameSuccessfulFinalSelectionReadCannotOutliveOperationAuthority(loss: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (other, otherField) = f.appendTrack(name: "B", selected: true)
            f.builder.setAttribute(f.header, kAXSelectedAttribute as String, false)
            f.permitsSelection = true
            f.legacyHeaderRoleObservedRead = 21
            let (project, target) = try await f.prepare(typedProducer: true)
            let deadline = loss == "deadline" ? ContinuousClock.now.advanced(by: .seconds(1)) : nil
            f.onLegacyHeaderRoleRead = {
                if loss == "ownership" { f.boundaryOwnership = false }
                if loss == "cancel" { f.boundaryCancellation = true }
                // Expire the actual absolute deadline inside the deciding read,
                // not before dispatch and not by making the AX role unreadable.
                // No elapsed-time assertion or simulated latency earns a pass.
                if let deadline {
                    while ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.001) }
                }
            }
            let context = OperationTraceContext(ownsGate: { f.boundaryOwnership }, deadline: deadline,
                                                cancellationRequested: { f.boundaryCancellation })
            let result = await OperationTraceContext.$current.withValue(context) {
                await f.rename(project: project, target: target, expected: nil, desired: "C")
            }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(f.legacyHeaderRoleObservations == 1)
            #expect(f.legacyHeaderRoleFailures == 0)
            let attempted = try #require(body["write_attempted"] as? Bool)
            let selected = try #require(AXValueExtractors.extractSelectedState(f.header, runtime: f.runtime.ax) as Bool?)
            let otherSelected = try #require(AXValueExtractors.extractSelectedState(other, runtime: f.runtime.ax) as Bool?)
            if loss == "healthy" {
                #expect(body["state"] as? String == "A")
                #expect(attempted)
                #expect(f.selectionWrites.count == 1)
                #expect(f.selectionWrites.allSatisfy { CFEqual($0, f.header) })
                #expect(f.writes == ["C"])
                #expect(selected)
                #expect(!otherSelected)
            } else {
                #expect(body["state"] as? String == "C")
                #expect(!attempted)
                #expect(f.selectionWrites.isEmpty, "Legacy reads at selection: \(f.legacyHeaderReadsAtSelection)")
                #expect(f.events.isEmpty)
                #expect(f.writes.isEmpty)
                #expect(f.actedNameFields.isEmpty)
                #expect(!selected)
                #expect(otherSelected)
                #expect(await f.cache.getTracks().first?.name == "A")
                #expect(await f.registry.resolve(target)?.descriptor.trackName == "A")
            }
            #expect(AXHelpers.getDescription(otherField, runtime: f.runtime.ax) == "B")
        }
    }

    @Test(arguments: [true, false])
    func ordinarySelectionReceiptRecordsTheActualSetterEvenWithFalseAcknowledgement(acknowledged: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (other, _) = f.appendTrack(name: "B", selected: true)
            f.builder.setAttribute(f.header, kAXSelectedAttribute as String, false)
            f.permitsSelection = true
            f.selectionReportsFailure = !acknowledged
            f.onSelection = { f.boundaryOwnership = false }
            let (project, target) = try await f.prepare(typedProducer: true)
            let context = OperationTraceContext(ownsGate: { f.boundaryOwnership })
            let result = await OperationTraceContext.$current.withValue(context) {
                await f.rename(project: project, target: target, expected: nil, desired: "C")
            }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["state"] as? String == "B")
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(attempted)
            #expect(f.selectionWrites.count == 1)
            #expect(f.selectionWrites.allSatisfy { CFEqual($0, f.header) })
            #expect(f.events.isEmpty)
            #expect(f.writes.isEmpty)
            #expect(f.actedNameFields.isEmpty)
            let selected = try #require(AXValueExtractors.extractSelectedState(f.header, runtime: f.runtime.ax) as Bool?)
            let otherSelected = try #require(AXValueExtractors.extractSelectedState(other, runtime: f.runtime.ax) as Bool?)
            #expect(selected)
            #expect(!otherSelected)
            #expect(await f.cache.getTracks().first?.name == "A")
            #expect(await f.registry.resolve(target)?.descriptor.trackName == "A")
        }
    }

    @Test(arguments: ["select", "confirm"])
    func selectionBoundaryObserverPreservesTheExistingTrailingPermissionClosure(helper: String) {
        let f = ExactNameFixture()
        _ = f.appendTrack(name: "B", selected: true)
        f.builder.setAttribute(f.header, kAXSelectedAttribute as String, false)
        f.permitsSelection = true
        let selected: Bool
        if helper == "select" {
            selected = AXLogicProElements.selectTrackViaAX(at: 0, runtime: f.runtime, heldHeader: f.header) { false }
        } else {
            selected = AccessibilityChannel.confirmExclusiveSelection(index: 0, runtime: f.runtime, heldHeader: f.header) { false }
        }
        #expect(!selected)
        #expect(f.selectionWrites.isEmpty)
        #expect(f.events.isEmpty)
        #expect(f.writes.isEmpty)
    }

    @Test(arguments: ["name", "ownership", "false_ack"])
    func anEditorPressIsAnAttemptEvenWhenTheDecidingReadOrAcknowledgementFails(failure: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare(typedProducer: true)
            if failure == "name" { f.editOnPress = "User edit" }
            if failure == "ownership" { f.onPress = { f.boundaryOwnership = false } }
            f.pressReportsFailure = failure == "false_ack"
            let context = OperationTraceContext(ownsGate: { f.boundaryOwnership })
            let receipt = await OperationTraceContext.$current.withValue(context) {
                await f.apply(project: project, target: target, before: "A", after: "C")
            }
            #expect(receipt.status == .attemptedUnverified)
            #expect(receipt.inverse == nil)
            #expect(f.events == ["AXPress"])
            #expect(f.writes.isEmpty)
            let body = try #require(sharedJSONObject(sharedToolText(receipt.result)))
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(attempted)
            #expect(body["state"] as? String == "B")
            #expect(body["reason"] as? String == "readback_unavailable")
            let expectedHint = failure == "false_ack"
                ? "Held name field opening was attempted but unverified"
                : "Exact rename precondition changed before the setter"
            #expect(body["hint"] as? String == expectedHint)
        }
    }

    @Test(arguments: ["focus", "window", "replacement", "document", "ownership", "pid", "frontmost",
                      "false_post", "false_return", "name", "return_focus", "return_document",
                      "return_ownership", "return_selection"])
    func ordinaryMenuTypingRevalidatesTheHeldEditorBeforeEveryPost(failure: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            f.builder.setAttribute(f.header, kAXTitleAttribute as String, "A")
            f.builder.setChildren(f.header, [])
            let bar = f.builder.element(968_190)
            let trackMenu = f.builder.element(968_191)
            let menu = f.builder.element(968_192)
            let rename = f.builder.element(968_193)
            let editor = f.builder.element(968_194)
            let stranger = f.builder.element(968_195)
            f.renameMenuItem = rename
            f.menuFocusedEditor = editor
            f.builder.setAttribute(f.app, kAXMenuBarAttribute as String, bar)
            for (element, role) in [(bar, kAXMenuBarRole), (trackMenu, kAXMenuBarItemRole),
                                   (menu, kAXMenuRole), (rename, kAXMenuItemRole),
                                   (editor, kAXTextFieldRole), (stranger, kAXTextFieldRole)] {
                f.builder.setAttribute(element, kAXRoleAttribute as String, role as String)
            }
            f.builder.setAttribute(trackMenu, kAXTitleAttribute as String, AXLocalePolicy.trackMenuBar.canonical)
            f.builder.setAttribute(rename, kAXTitleAttribute as String, AXLocalePolicy.renameTrackMenuItem.canonical)
            f.builder.setAttribute(editor, kAXWindowAttribute as String, f.window)
            f.builder.setAttribute(editor, kAXValueAttribute as String, "A")
            f.builder.setAttribute(stranger, kAXWindowAttribute as String, f.window)
            f.builder.setChildren(bar, [trackMenu])
            f.builder.setChildren(trackMenu, [menu])
            f.builder.setChildren(menu, [rename])
            let (project, target) = try await f.prepare(typedProducer: true)
            let replacement = f.builder.element(968_196)
            f.builder.setAttribute(replacement, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            f.builder.setAttribute(replacement, kAXTitleAttribute as String, "A")
            f.builder.setAttribute(replacement, kAXSelectedAttribute as String, true)
            f.builder.setChildren(replacement, [])
            f.typingPostReportsFailure = failure == "false_post"
            f.returnReportsFailure = failure == "false_return"
            f.onTypedCodeUnit = {
                if failure == "focus" { f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, stranger) }
                if failure == "window" { f.builder.setAttribute(editor, kAXWindowAttribute as String, stranger) }
                if failure == "replacement" { f.builder.setChildren(f.rail, [replacement]) }
                if failure == "document" { f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx") }
                if failure == "ownership" { f.boundaryOwnership = false }
                if failure == "pid" { f.observedLogicPID = 5353; f.observedFocusedPID = 5353 }
                if failure == "frontmost" { f.logicIsFrontmost = false }
                if failure == "name" { f.builder.setAttribute(f.header, kAXTitleAttribute as String, "User edit") }
                if f.typedCodeUnits.count == 2 {
                    if failure == "return_focus" { f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, stranger) }
                    if failure == "return_document" { f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx") }
                    if failure == "return_ownership" { f.boundaryOwnership = false }
                    if failure == "return_selection" { f.builder.setAttribute(f.header, kAXSelectedAttribute as String, false) }
                }
            }
            let context = OperationTraceContext(ownsGate: { f.boundaryOwnership })
            let result = await OperationTraceContext.$current.withValue(context) {
                await f.rename(project: project, target: target, expected: nil, desired: "CD")
            }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["state"] as? String == "B")
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(attempted)
            let characters = failure == "false_return" || failure.hasPrefix("return_") ? "CD" : "C"
            #expect(f.typedCodeUnits == Array(characters.utf16))
            if failure == "false_return" { #expect(f.postedReturn) } else { #expect(!f.postedReturn) }
            #expect(f.writes == (failure == "false_return" ? ["CD"] : []))
            #expect(f.events == ["rename_menu"])
            #expect(f.actedNameFields.isEmpty)
            #expect(await f.cache.getTracks().first?.name == "A")
            #expect(await f.registry.resolve(target)?.descriptor.trackName == "A")
        }
    }

    @Test(arguments: ["selection_replacement", "selection_reorder", "selection_document", "selection_ownership",
                      "menu_replacement", "menu_reorder", "menu_document", "menu_ownership"])
    func ordinaryRenameAcquisitionCannotTransferHeldTargetAuthority(change: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let atSelection = change.hasPrefix("selection_")
            let (other, otherField) = f.appendTrack(name: "B", selected: atSelection)
            f.builder.setAttribute(f.header, kAXSelectedAttribute as String, !atSelection)
            f.permitsSelection = true
            if !atSelection {
                f.builder.setChildren(f.header, [])
                f.builder.setAttribute(f.header, kAXTitleAttribute as String, "A")
                let bar = f.builder.element(968_170)
                let trackMenu = f.builder.element(968_171)
                let menu = f.builder.element(968_172)
                let rename = f.builder.element(968_173)
                f.renameMenuItem = rename
                f.builder.setAttribute(f.app, kAXMenuBarAttribute as String, bar)
                for (element, role) in [(bar, kAXMenuBarRole), (trackMenu, kAXMenuBarItemRole),
                                       (menu, kAXMenuRole), (rename, kAXMenuItemRole)] {
                    f.builder.setAttribute(element, kAXRoleAttribute as String, role as String)
                }
                f.builder.setAttribute(trackMenu, kAXTitleAttribute as String, AXLocalePolicy.trackMenuBar.canonical)
                f.builder.setAttribute(rename, kAXTitleAttribute as String, AXLocalePolicy.renameTrackMenuItem.canonical)
                f.builder.setChildren(bar, [trackMenu])
                f.builder.setChildren(trackMenu, [menu])
                f.builder.setChildren(menu, [rename])
            }
            let (project, target) = try await f.prepare(typedProducer: true)
            let replacement = f.builder.element(968_174)
            f.builder.setAttribute(replacement, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            f.builder.setAttribute(replacement, kAXTitleAttribute as String, "A")
            f.builder.setAttribute(replacement, kAXSelectedAttribute as String, true)
            f.builder.setChildren(replacement, [])
            let interfere: @Sendable () -> Void = {
                if change.hasSuffix("replacement") { f.builder.setChildren(f.rail, [replacement, other]) }
                if change.hasSuffix("reorder") { f.builder.setChildren(f.rail, [other, f.header]) }
                if change.hasSuffix("document") {
                    f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                }
                if change.hasSuffix("ownership") { f.boundaryOwnership = false }
            }
            if atSelection { f.onSelection = interfere } else { f.onRenameMenuRead = interfere }
            let context = OperationTraceContext(ownsGate: { f.boundaryOwnership })
            let result = await OperationTraceContext.$current.withValue(context) {
                // An explicit original ordinal cannot silently become a new row after acquisition.
                await f.rename(project: project, target: target, expected: nil, desired: "C", index: 0)
            }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["state"] as? String == (atSelection ? "B" : "C"))
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(attempted == atSelection)
            #expect(f.selectionWrites.count == (atSelection ? 1 : 0))
            #expect(f.events.isEmpty)
            #expect(f.writes.isEmpty)
            #expect(f.actedNameFields.isEmpty)
            #expect(AXHelpers.getDescription(otherField, runtime: f.runtime.ax) == "B")
        }
    }

    @Test func requestOwnedProducerCarriesTheSameUnserializedHeaderWitness() async throws {
        let f = ExactNameFixture()
        let logic = f.runtime
        let channel = AccessibilityChannel(runtime: .init(isTrusted: { true }, isLogicProRunning: { true },
            hasVisibleWindow: { true }, appRoot: { f.app }, transportState: { .error("Unused transport") },
            toggleTransportButton: { _ in .error("Unused toggle") }, setTempo: { _ in .error("Unused tempo") },
            setCycleRange: { _ in .error("Unused cycle") }, tracks: { .error("Unused JSON tracks") },
            selectedTrack: { .error("Unused selected") }, selectTrack: { _ in .error("Unused select") },
            setTrackToggle: { _, _ in .error("Unused track toggle") }, renameTrack: { _ in .error("Unused rename") },
            mixerState: { .error("Unused Mixer") }, channelStrip: { _ in .error("Unused strip") },
            setMixerValue: { _, _ in .error("Unused Mixer write") }, projectInfo: { .error("Unused project") },
            confirmNewTrackDialog: { Issue.record("Unexpected dialog") }, canPostEvents: { false }, logicRuntime: logic))
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { true })
        let population = try await OperationTraceContext.$current.withValue(context) {
            try await channel.readFreshSessionPopulation(request: .init(domains: [.tracks]),
                fileReader: .unavailable, stoppingWhen: { false })
        }
        #expect(population.stable)
        let row = try #require(population.tracks?.first)
        let held = try #require(row.physicalBinding)
        #expect(CFEqual(held.header, f.header))
        #expect(CFEqual(held.window, f.window))
        #expect(held.document == "file:///tmp/ExactName.logicx")
        let decoded = try JSONDecoder().decode(TrackState.self, from: JSONEncoder().encode(row))
        #expect(decoded.physicalBinding == nil)
        #expect(!decoded.liveIdentityBacked)
        #expect(f.writes.isEmpty)
        #expect(f.events.isEmpty)
    }
}
