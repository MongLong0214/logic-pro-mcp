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
    var onUnwrittenNameRead: (@Sendable () -> Void)?
    var nameReadsAfterWrite = 0
    var permitsSelection = false
    var useBulkReads = false
    var globalMixerDiscoveries = 0
    var countedMixer: AXUIElement?
    var mixerPopulationReads = 0
    var mixerPopulationReadsAtLastPeer = 0
    var mixerCensusesWithinNameGroups: [Int] = []
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
    var activationCalls = 0
    var onActivation: (@Sendable () -> Bool)?
    var onWindowRaise: (@Sendable () -> Bool)?
    var raisedWindows: [AXUIElement] = []
    var windowRaiseFaultConsumed = false
    var windowNameReadArmed = false
    var windowNameReadFaultConsumed = false
    var renameMenuRequiresOriginalWindow = false
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
    var passiveRailFocus = false
    var passiveMixerStripFocus: AXUIElement?
    var additionalPassiveMixerStrips: [AXUIElement] = []
    var unreadPassiveMixerMetadata = false
    var passiveMixerHasValue = false
    var menuEditorValueWrites: [String] = []
    var menuEditorSetterAcknowledgesOnly = false
    var onMenuEditorValueSet: (@Sendable () -> Void)?
    var onMenuEditorValueReadAfterSet: (@Sendable () -> Void)?
    var menuEditorValueReadGeneration = 0
    var coupledNameField: AXUIElement?
    var coupledPeerNameField: AXUIElement?
    var onMirrorReadAfterWrite: (@Sendable () -> Void)?
    var peerNameReadsAfterWrite = 0
    var peerNameReadsAtLastMirror = 0
    var mostPeerReadsBeforeMirror = 0
    var popupFocusedWindowIsNoValue = false
    var physicalOwnerDocumentReads = 0
    var onPhysicalOwnerDocumentRead: (@Sendable (Int) -> Void)?
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
        builder.setAttribute(app, kAXFocusedWindowAttribute as String, window)
    }

    var runtime: AXLogicProElements.Runtime {
        let source = AXLogicProElements.Runtime(
            logicProPID: { [self] in observedLogicPID },
            ax: builder.makeAXRuntime(
                appElement: app,
                attributeValueHandler: { [self] element, attribute in
                    if CFEqual(element, window), attribute == kAXDocumentAttribute as String {
                        physicalOwnerDocumentReads += 1
                        onPhysicalOwnerDocumentRead?(physicalOwnerDocumentReads)
                    }
                    if menuEditorValueWrites.count > menuEditorValueReadGeneration, let menuFocusedEditor,
                       CFEqual(element, menuFocusedEditor), attribute == kAXValueAttribute as String {
                        menuEditorValueReadGeneration = menuEditorValueWrites.count
                        onMenuEditorValueReadAfterSet?()
                    }
                    if countRawHelpReads, attribute == kAXHelpAttribute as String { rawHelpReads += 1 }
                    if !writes.isEmpty, additionalNameFields.contains(where: { CFEqual($0, element) }),
                       attribute == kAXDescriptionAttribute as String {
                        peerNameReadsAfterWrite += 1
                        onPeerNameReadAfterWrite?(peerNameReadsAfterWrite)
                    }
                    if !writes.isEmpty, let coupledNameField, CFEqual(element, coupledNameField),
                       attribute == kAXValueAttribute as String {
                        mostPeerReadsBeforeMirror = max(mostPeerReadsBeforeMirror, peerNameReadsAfterWrite - peerNameReadsAtLastMirror)
                        peerNameReadsAtLastMirror = peerNameReadsAfterWrite
                        onMirrorReadAfterWrite?()
                    }
                    if let renameMenuItem, CFEqual(element, renameMenuItem), attribute == kAXTitleAttribute as String {
                        onRenameMenuRead?()
                    }
                    if !writes.isEmpty, CFEqual(element, field), attribute == kAXDescriptionAttribute as String {
                        nameReadsAfterWrite += 1
                        onNameReadAfterWrite?()
                    }
                    if writes.isEmpty, CFEqual(element, field), attribute == kAXDescriptionAttribute as String {
                        onUnwrittenNameRead?()
                    }
                    if hideReadbackAfterSet, !writes.isEmpty, CFEqual(element, field),
                       attribute == kAXDescriptionAttribute as String { return .some(nil) }
                    return nil
                },
                attributeValueResultHandler: { [self] element, attribute in
                    if popupFocusedWindowIsNoValue, CFEqual(element, app), attribute == kAXFocusedWindowAttribute as String {
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    if passiveRailFocus, CFEqual(element, rail),
                       [kAXValueAttribute, kAXSelectedTextAttribute, kAXNumberOfCharactersAttribute,
                        kAXInsertionPointLineNumberAttribute].contains(where: { attribute == $0 as String }) {
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    if passiveMixerStripFocus.map({ CFEqual(element, $0) }) == true
                        || additionalPassiveMixerStrips.contains(where: { CFEqual(element, $0) }) {
                        if [kAXValueAttribute as String, kAXSelectedTextAttribute as String].contains(attribute) {
                            if passiveMixerHasValue, attribute == kAXValueAttribute as String { return .success("editing" as AnyObject) }
                            return .failure(.init(raw: AXError.noValue.rawValue))
                        }
                        if [kAXNumberOfCharactersAttribute as String, kAXInsertionPointLineNumberAttribute as String].contains(attribute) {
                            if unreadPassiveMixerMetadata { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
                            return .success(builder.attributeValue(element, attribute) as AnyObject?)
                        }
                    }
                    guard passiveHeaderNameLabel, CFEqual(element, field),
                          attribute == kAXValueAttribute as String else { return nil }
                    // Preserve the actual stored CFNumber: the generic fixture bridge
                    // can cast NSNumber(0) through Bool, which is not this native label.
                    return .success(builder.attributeValue(element, attribute) as AnyObject?)
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
                    if action == kAXRaiseAction as String, let onWindowRaise {
                        raisedWindows.append(element)
                        return onWindowRaise()
                    }
                    if let renameMenuItem, CFEqual(element, renameMenuItem), action == kAXPressAction as String {
                        events.append("rename_menu")
                        if renameMenuRequiresOriginalWindow,
                           let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String,
                                runtime: builder.makeAXRuntime()), !CFEqual(focused, window) {
                            return true // Acknowledgement is not acquisition of the held window's editor.
                        }
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
        if useBulkReads {
            let ax = source.ax
            let bulk = AXHelpers.Runtime(axApp: ax.axApp, attributeValue: ax.attributeValue,
                attributeIsSettable: ax.attributeIsSettable, setAttributeValue: ax.setAttributeValue,
                children: ax.children, performAction: ax.performAction, childCount: ax.childCount,
                actionNames: ax.actionNames, actionNamesResult: ax.actionNamesResult,
                childrenResult: { [self] element in
                    if countedMixer.map({ CFEqual($0, element) }) == true { mixerPopulationReads += 1 }
                    return AXHelpers.childrenResult(element, runtime: ax)
                }, attributeValueResult: ax.attributeValueResult,
                performActionResult: ax.performActionResult, elementAtPosition: ax.elementAtPosition,
                attributeValuesResult: { [self] element, attributes in
                    if CFEqual(element, window), attributes == [kAXRoleAttribute, kAXIdentifierAttribute,
                        kAXDescriptionAttribute, kAXTitleAttribute, kAXChildrenAttribute] as [String] {
                        globalMixerDiscoveries += 1
                    }
                    var values: [AnyObject] = []
                    for attribute in attributes {
                        let reading: Result<AnyObject?, AXHelpers.AXStatusError>
                        if attribute == kAXChildrenAttribute as String {
                            if countedMixer.map({ CFEqual($0, element) }) == true { mixerPopulationReads += 1 }
                            reading = AXHelpers.childrenResult(element, runtime: ax).map { $0 as CFArray }
                        } else {
                            reading = AXHelpers.getAttributeResult(element, attribute, runtime: ax)
                        }
                        switch reading {
                        case .success(let value): values.append(value ?? NSNull())
                        case .failure(let error):
                            if popupFocusedWindowIsNoValue, attribute == kAXFocusedWindowAttribute as String,
                               error.raw == AXError.noValue.rawValue {
                                // The native batch preserves each attribute's error;
                                // NoValue for the focused window does not erase its
                                // readable main-window and membership attributes.
                                var status = AXError.noValue
                                guard let wrapped = AXValueCreate(.axError, &status) else { return .failure(error) }
                                values.append(wrapped)
                            } else { return .failure(error) }
                        }
                    }
                    return .success(values)
                })
            return AXLogicProElements.Runtime(logicProPID: source.logicProPID, ax: bulk,
                executeAppleScript: source.executeAppleScript,
                executeAppleScriptWithTimeout: source.executeAppleScriptWithTimeout,
                onScreenWindowList: source.onScreenWindowList, postPopupMenuEscape: source.postPopupMenuEscape,
                focusedApplicationPID: source.focusedApplicationPID, observeFrontmost: source.observeFrontmost)
        }
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
                activateLogicPro: { [self] in activationCalls += 1; return onActivation?() ?? false },
                logicIsFrontmost: { [self] in logicIsFrontmost }, logicProBundleURL: { nil }
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
        let identity = additionalNameFields.isEmpty ? 968_140 : 1_968_000 + additionalNameFields.count * 2
        let row = builder.element(identity)
        let nameField = builder.element(identity + 1)
        builder.setAttribute(row, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(row, kAXSelectedAttribute as String, selected)
        builder.setAttribute(nameField, kAXRoleAttribute as String, kAXTextFieldRole as String)
        builder.setAttribute(nameField, kAXDescriptionAttribute as String, name)
        builder.setAttribute(nameField, kAXValueAttribute as String, "1")
        builder.setChildren(nameField, [])
        builder.setChildren(row, [nameField])
        builder.setChildren(rail, builder.makeAXRuntime().children(rail) + [row])
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

    func coupledCapture(link: String = "observed", peerStripName: String? = nil,
                        includePeerAssociation: Bool = false, extraMixerPeerNames: [String] = [],
                        peerExposure: AXTrackBinding.Exposure? = nil,
                        passiveMixerFocus: Bool = false) async throws -> (SessionPopulationObservation.Capture, TargetReference, TargetReference, AXUIElement, AXUIElement) {
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
        for (offset, peerName) in extraMixerPeerNames.enumerated() {
            let peer = builder.element(2_968_000 + offset * 2), field = builder.element(2_968_001 + offset * 2)
            builder.setRole(peer, kAXLayoutItemRole as String)
            builder.setRole(field, kAXTextFieldRole as String)
            builder.setAttribute(field, kAXDescriptionAttribute as String, "name")
            builder.setAttribute(field, kAXValueAttribute as String, peerName)
            builder.setChildren(field, []); builder.setChildren(peer, [field])
            builder.setChildren(mixer, builder.makeAXRuntime().children(mixer) + [peer])
        }
        if passiveMixerFocus {
            let owner = builder.element(968_175)
            builder.setRole(owner, kAXGroupRole as String)
            builder.setAttribute(owner, kAXDescriptionAttribute as String, "Mixer")
            builder.setRole(mixer, kAXLayoutAreaRole as String)
            builder.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
            builder.setChildren(owner, [mixer])
            builder.setChildren(window, [rail, owner])
            passiveMixerStripFocus = strip
            builder.setAttributeSettable(strip, kAXValueAttribute as String, false)
            builder.setAttribute(strip, kAXNumberOfCharactersAttribute as String, NSNumber(value: 0))
            builder.setAttribute(strip, kAXInsertionPointLineNumberAttribute as String, NSNumber(value: 0))
            builder.setAttribute(app, kAXFocusedUIElementAttribute as String, strip)
            builder.setAttribute(app, kAXFrontmostAttribute as String, true)
        } else { builder.setChildren(window, [rail, mixer]) }
        await cache.updateProject(.init(name: "ExactName", filePath: "/tmp/ExactName.logicx"))
        let (project, target) = try await prepare(typedProducer: true)
        var tracks = await cache.getTracks()
        if let peerExposure, tracks.count > 1, let peer = tracks[1].physicalBinding {
            tracks[1].physicalBinding = .init(window: peer.window, header: peer.header, document: peer.document,
                runtime: peer.runtime, exposure: peerExposure)
            await cache.updateTracks(tracks)
        }
        let physical = try #require(tracks.first?.physicalBinding)
        let strips = try #require(AccessibilityChannel.defaultGetMixerStates(runtime: runtime, stoppingWhen: { false }).states)
        let source = try #require(strips.first?.physicalBinding)
        await cache.updateChannelStrips(strips)
        let pair = AccessibilityChannel.HeldSelectionAssociation.Pair(track: physical, strip: source)
        var population = SessionPopulationObservation.FreshPopulation(project: await cache.getProject(),
            tracks: tracks, strips: strips, fileTrackCount: nil, beganAt: Date(), endedAt: Date(), stable: true)
        population.selectionAssociations = link == "missing" ? [] : (link == "duplicate" ? [pair, pair] : [pair])
        if includePeerAssociation {
            let peerTrack = try #require(tracks.dropFirst().first?.physicalBinding)
            let peerStrip = try #require(strips.dropFirst().first?.physicalBinding)
            population.selectionAssociations.append(.init(track: peerTrack, strip: peerStrip))
        }
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
                               journal: SagaJournal, mixerOrigin: TargetReference? = nil) async throws -> ApprovedSessionRepair {
        let request = SessionPopulationObservation.Request(domains: [.tracks, .strips, .associations])
        let report = SessionPopulationObservation.build(request: request, capture: capture)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        let retained = await cache.retainSessionReport(id: capture.captureID, json: json,
            capturedEpoch: capture.projectEpoch, capturedPath: capture.project.filePath,
            capture: capture, request: request)
        #expect(retained)
        let raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
            "project_ref": .string(project.rawValue),
            "targets": .array([.object(["handle": .string("exact"),
                mixerOrigin == nil ? "track_ref" : "mixer_ref": .string((mixerOrigin ?? target).rawValue)])])]
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
    @Test(arguments: ["healthy", "foreign_keyboard", "foreign_focus", "foreign_window"])
    func coupledNameMustOwnTheKeyboardBeforeOpeningItsEditor(fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            f.passiveHeaderNameLabel = true
            f.builder.setAttribute(f.field, kAXValueAttribute as String, NSNumber(value: 0))
            f.builder.setAttributeSettable(f.field, kAXValueAttribute as String, false)
            let bar = f.builder.element(968_430), trackMenu = f.builder.element(968_431)
            let menu = f.builder.element(968_432), rename = f.builder.element(968_433)
            let editor = f.builder.element(968_434), otherWindow = f.builder.element(968_435)
            f.renameMenuItem = rename; f.menuFocusedEditor = editor
            f.builder.setAttribute(f.app, kAXMenuBarAttribute as String, bar)
            for (element, role) in [(bar, kAXMenuBarRole), (trackMenu, kAXMenuBarItemRole),
                                   (menu, kAXMenuRole), (rename, kAXMenuItemRole),
                                   (editor, kAXTextFieldRole), (otherWindow, kAXWindowRole)] {
                f.builder.setRole(element, role as String)
            }
            f.builder.setAttribute(trackMenu, kAXTitleAttribute as String, AXLocalePolicy.trackMenuBar.canonical)
            f.builder.setAttribute(rename, kAXTitleAttribute as String, AXLocalePolicy.renameTrackMenuItem.canonical)
            f.builder.setAttribute(editor, kAXWindowAttribute as String, f.window)
            f.builder.setAttribute(editor, kAXParentAttribute as String, f.rail)
            f.builder.setAttribute(editor, kAXValueAttribute as String, "A")
            f.builder.setAttributeSettable(editor, kAXValueAttribute as String, true)
            f.builder.setChildren(bar, [trackMenu]); f.builder.setChildren(trackMenu, [menu])
            f.builder.setChildren(menu, [rename])
            let (capture, project, target, _, _) = try await f.coupledCapture()
            if fault == "foreign_keyboard" { f.logicIsFrontmost = false }
            if fault == "foreign_focus" { f.observedFocusedPID = 9002 }
            if fault == "foreign_window" {
                f.builder.setAttribute(f.app, kAXFocusedWindowAttribute as String, otherWindow)
            }
            let receipt = await f.applyCoupled(capture, project: project, target: target)
            let body = try #require(sharedJSONObject(sharedToolText(receipt.result)))
            if fault == "healthy" {
                #expect(receipt.status == .applied, "Healthy coupled menu control: \(body)")
                #expect(f.events == ["rename_menu"])
                #expect(f.menuEditorValueWrites == ["C"] && f.writes == ["C"])
            } else {
                #expect(receipt.status == .rejectedBeforeWrite, "Reject before opening a foreign-owned editor: \(body)")
                #expect(body["state"] as? String == "C")
                let attempted = try #require(body["write_attempted"] as? Bool)
                #expect(!attempted)
                #expect(f.events.isEmpty, "A known unsafe owner must not first open Rename and then report uncertain rollback")
                #expect(f.menuEditorValueWrites.isEmpty && f.writes.isEmpty && !f.postedReturn)
            }
        }
    }

    @Test func registeredOrdinaryRenameAcquiresItsRetainedWindowBeforeOpeningTheEditor() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture("Audio 1")
            f.passiveHeaderNameLabel = true
            f.builder.setAttribute(f.field, kAXValueAttribute as String, NSNumber(value: 0))
            f.builder.setAttributeSettable(f.field, kAXValueAttribute as String, false)
            let bar = f.builder.element(968_410), trackMenu = f.builder.element(968_411)
            let menu = f.builder.element(968_412), rename = f.builder.element(968_413)
            let editor = f.builder.element(968_414)
            let otherWindow = f.builder.element(968_415), otherGroup = f.builder.element(968_416)
            f.renameMenuItem = rename; f.menuFocusedEditor = editor
            f.renameMenuRequiresOriginalWindow = true
            f.builder.setAttribute(f.app, kAXMenuBarAttribute as String, bar)
            for (element, role) in [(bar, kAXMenuBarRole), (trackMenu, kAXMenuBarItemRole),
                                   (menu, kAXMenuRole), (rename, kAXMenuItemRole),
                                   (editor, kAXTextFieldRole), (otherWindow, kAXWindowRole), (otherGroup, kAXGroupRole)] {
                f.builder.setAttribute(element, kAXRoleAttribute as String, role as String)
            }
            f.builder.setAttribute(trackMenu, kAXTitleAttribute as String, AXLocalePolicy.trackMenuBar.canonical)
            f.builder.setAttribute(rename, kAXTitleAttribute as String, AXLocalePolicy.renameTrackMenuItem.canonical)
            f.builder.setAttribute(editor, kAXWindowAttribute as String, f.window)
            f.builder.setAttribute(editor, kAXValueAttribute as String, "Audio 1")
            f.builder.setAttributeSettable(editor, kAXValueAttribute as String, true)
            f.builder.setAttribute(otherGroup, kAXWindowAttribute as String, otherWindow)
            f.builder.setChildren(bar, [trackMenu]); f.builder.setChildren(trackMenu, [menu]); f.builder.setChildren(menu, [rename])
            let (project, target) = try await f.prepare(typedProducer: true)
            f.builder.setAttribute(f.app, kAXFocusedWindowAttribute as String, otherWindow)
            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, otherGroup)
            f.onWindowRaise = {
                guard f.raisedWindows.count == 1, CFEqual(f.raisedWindows[0], f.window) else {
                    Issue.record("Only the retained original window may be raised"); return false
                }
                f.builder.setAttribute(f.app, kAXFocusedWindowAttribute as String, f.window)
                return true
            }
            let runtime = f.runtime
            let dependencies = HandlerDependencies(router: f.router, cache: f.cache, targetRegistry: f.registry,
                poller: StatePoller(axChannel: AccessibilityChannel(), cache: f.cache,
                    runtime: .init(hasVisibleWindow: { false })), dialogPresent: { false }, supportBundleExporter: nil,
                liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) }, projectFileReader: .unavailable)
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_tracks", command: "rename"))
            let result = await handler(dependencies, ["project_ref": .string(project.rawValue),
                "target_ref": .string(target.rawValue), "name": .string("Probe")])
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(f.observedFocusedPID == f.observedLogicPID && f.logicIsFrontmost)
            #expect(f.activationCalls == 0)
            #expect(f.raisedWindows.count == 1)
            #expect(body["state"] as? String == "A")
            #expect(f.menuEditorValueWrites == ["Probe"])
            #expect(f.writes == ["Probe"])
            #expect(f.events == ["rename_menu"])
            #expect(await f.registry.resolve(target)?.descriptor.trackName == "Probe")
        }
    }

    @Test(arguments: ["ack_only", "header_loss", "ownership_loss", "document_loss", "name_loss", "pid_loss",
                      "foreign_editor", "missing_focus_window", "before_menu_loss", "final_name_window_loss", "false_ack_owned"])
    func ordinaryWindowAcquisitionCannotBorrowAnAcknowledgementOrLostCustody(_ fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture("Audio 1")
            f.passiveHeaderNameLabel = true
            f.builder.setAttribute(f.field, kAXValueAttribute as String, NSNumber(value: 0))
            f.builder.setAttributeSettable(f.field, kAXValueAttribute as String, false)
            let bar = f.builder.element(968_420), trackMenu = f.builder.element(968_421)
            let menu = f.builder.element(968_422), rename = f.builder.element(968_423)
            let editor = f.builder.element(968_424)
            let otherWindow = f.builder.element(968_425), otherGroup = f.builder.element(968_426)
            f.renameMenuItem = rename; f.menuFocusedEditor = editor
            f.renameMenuRequiresOriginalWindow = true
            f.builder.setAttribute(f.app, kAXMenuBarAttribute as String, bar)
            for (element, role) in [(bar, kAXMenuBarRole), (trackMenu, kAXMenuBarItemRole),
                                   (menu, kAXMenuRole), (rename, kAXMenuItemRole),
                                   (editor, kAXTextFieldRole), (otherWindow, kAXWindowRole), (otherGroup, kAXGroupRole)] {
                f.builder.setAttribute(element, kAXRoleAttribute as String, role as String)
            }
            f.builder.setAttribute(trackMenu, kAXTitleAttribute as String, AXLocalePolicy.trackMenuBar.canonical)
            f.builder.setAttribute(rename, kAXTitleAttribute as String, AXLocalePolicy.renameTrackMenuItem.canonical)
            f.builder.setAttribute(editor, kAXWindowAttribute as String, f.window)
            f.builder.setAttribute(editor, kAXValueAttribute as String, "Audio 1")
            f.builder.setAttributeSettable(editor, kAXValueAttribute as String, true)
            f.builder.setAttribute(otherGroup, kAXWindowAttribute as String, otherWindow)
            f.builder.setChildren(bar, [trackMenu]); f.builder.setChildren(trackMenu, [menu]); f.builder.setChildren(menu, [rename])
            let (project, target) = try await f.prepare(typedProducer: true)
            f.builder.setAttribute(f.app, kAXFocusedWindowAttribute as String, otherWindow)
            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, otherGroup)
            if fault == "foreign_editor" {
                f.builder.setAttribute(otherGroup, kAXRoleAttribute as String, kAXTextFieldRole as String)
                f.builder.setAttribute(otherGroup, kAXValueAttribute as String, "Unrelated editing")
            }
            if fault == "missing_focus_window" { f.builder.removeAttribute(f.app, kAXFocusedWindowAttribute as String) }
            f.onWindowRaise = {
                f.windowRaiseFaultConsumed = true
                guard f.raisedWindows.count == 1, CFEqual(f.raisedWindows[0], f.window) else {
                    Issue.record("A changed target cannot redirect the retained-window raise"); return false
                }
                if fault == "ack_only" { return true }
                f.builder.setAttribute(f.app, kAXFocusedWindowAttribute as String, f.window)
                switch fault {
                case "header_loss": f.builder.setChildren(f.rail, [])
                case "ownership_loss": f.boundaryOwnership = false
                case "document_loss": f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                case "name_loss": f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "User edit")
                case "pid_loss": f.observedLogicPID = 9002
                default: break
                }
                return fault != "false_ack_owned"
            }
            if fault == "before_menu_loss" {
                f.onRenameMenuRead = { f.builder.setAttribute(f.app, kAXFocusedWindowAttribute as String, otherWindow) }
            }
            if fault == "final_name_window_loss" {
                f.onRenameMenuRead = { f.windowNameReadArmed = true }
                f.onUnwrittenNameRead = {
                    if f.windowNameReadArmed, !f.windowNameReadFaultConsumed {
                        f.windowNameReadFaultConsumed = true
                        f.builder.setAttribute(f.app, kAXFocusedWindowAttribute as String, otherWindow)
                    }
                }
            }
            let context = OperationTraceContext(ownsGate: { f.boundaryOwnership })
            let result = await OperationTraceContext.$current.withValue(context) {
                await f.rename(project: project, target: target, expected: nil, desired: "Probe")
            }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(f.activationCalls == 0)
            if fault == "false_ack_owned" {
                #expect(body["state"] as? String == "A")
                #expect(f.writes == ["Probe"])
                #expect(f.events == ["rename_menu"])
            } else {
                #expect(body["state"] as? String == (fault == "foreign_editor" || fault == "missing_focus_window" ? "C" : "B"))
                #expect(f.writes.isEmpty)
                #expect(f.events.isEmpty)
                #expect(f.menuEditorValueWrites.isEmpty)
                #expect(!f.postedReturn)
                #expect(await f.registry.resolve(target)?.descriptor.trackName == "Audio 1")
            }
            let mayRaise = fault != "foreign_editor" && fault != "missing_focus_window"
            #expect(f.raisedWindows.count == (mayRaise ? 1 : 0))
            if mayRaise { #expect(f.windowRaiseFaultConsumed) }
            else { #expect(!f.windowRaiseFaultConsumed) }
            if fault == "final_name_window_loss" { #expect(f.windowNameReadFaultConsumed) }
            if fault == "name_loss" {
                let current: String? = AXHelpers.getAttribute(f.field, kAXDescriptionAttribute as String,
                    runtime: f.builder.makeAXRuntime())
                #expect(current == "User edit")
            }
        }
    }

    @Test func verifiedRenameKeepsItsFreshReferenceAfterObservedHistoryNameDrift() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture("Audio 1")
            let (project, original) = try await f.prepare(typedProducer: true)
            let first = try #require(sharedJSONObject(sharedToolText(
                await f.rename(project: project, target: original, expected: nil, desired: "qualification_phase_b_probe"))))
            #expect(first["state"] as? String == "A")
            #expect(first["target_ref"] as? String == original.rawValue)
            let held = try #require(await f.registry.resolve(original)?.physicalTrack)
            // Model the independently read raw Undo effect. EditDispatcher does not
            // rebind name identities, so this read must issue a genuinely fresh ref.
            f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "Audio 1")
            f.builder.setAttribute(f.field, kAXValueAttribute as String, "Audio 1")
            let restoredRows = try #require(AccessibilityChannel.defaultGetTrackStates(runtime: f.runtime))
        let restoredPhysicalOwnerMatches = try #require(restoredRows.first?.physicalBinding?.matches(held))
        #expect(restoredPhysicalOwnerMatches)
            await f.cache.updateTracks(restoredRows)
            let snapshot = await f.registry.currentSnapshot
            let observed = try #require(await TrackReferenceIssuance.issue(for: restoredRows,
                registry: f.registry, snapshot: snapshot))
            let fresh = try #require(observed.byTrackIndex[0])
            #expect(fresh != original)
            let second = try #require(sharedJSONObject(sharedToolText(
                await f.rename(project: project, target: fresh, expected: nil, desired: "qualification_phase_b_probe"))))
            #expect(second["state"] as? String == "A")
            #expect(second["target_ref"] as? String == fresh.rawValue)
            let published = try #require(await TrackReferenceIssuance.issue(for: await f.cache.getTracks(),
                registry: f.registry, snapshot: snapshot))
            #expect(published.byTrackIndex[0] == fresh,
                "fresh publication must not select the historical alias by dictionary iteration")
            #expect(await f.registry.resolve(original) == nil,
                "the old name-drifted alias cannot regain authority after another ref's verified rename")
            let writes = f.writes
            let retired = try #require(sharedJSONObject(sharedToolText(
                await f.rename(project: project, target: original, expected: nil, desired: "Retired must not write"))))
            #expect(retired["state"] as? String == "C")
            #expect(f.writes == writes)
            let inverse = try #require(sharedJSONObject(sharedToolText(
                await f.rename(project: project, target: fresh, expected: nil, desired: "Audio 1"))))
            #expect(inverse["state"] as? String == "A")
            #expect(await f.registry.resolve(fresh)?.descriptor.trackName == "Audio 1")
        }
    }

    @Test(arguments: ["header", "window", "document", "name"])
    func verifiedRenameDoesNotRetireAnotherOwnerOrNameAsAnAlias(_ difference: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture("Audio 1")
            let (project, original) = try await f.prepare(typedProducer: true)
            let first = try #require(sharedJSONObject(sharedToolText(
                await f.rename(project: project, target: original, expected: nil, desired: "qualification_phase_b_probe"))))
            #expect(first["state"] as? String == "A")
            let held = try #require(await f.registry.resolve(original)?.physicalTrack)
            f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "Audio 1")
            f.builder.setAttribute(f.field, kAXValueAttribute as String, "Audio 1")
            let rows = try #require(AccessibilityChannel.defaultGetTrackStates(runtime: f.runtime))
            await f.cache.updateTracks(rows)
            let snapshot = await f.registry.currentSnapshot
            let refs = try #require(await TrackReferenceIssuance.issue(for: rows, registry: f.registry, snapshot: snapshot))
            let fresh = try #require(refs.byTrackIndex[0])
            #expect(fresh != original)
            let otherPhysical = AXTrackBinding.Binding(
                window: difference == "window" ? f.builder.element(968_321) : held.window,
                header: difference == "header" ? f.builder.element(968_322) : held.header,
                document: difference == "document" ? "file://localhost/tmp/ExactName.logicx" : held.document,
                runtime: held.runtime)
            let otherDescriptor = TargetDescriptor(trackIndex: 0,
                trackName: difference == "name" ? "qualification_phase_b_probe " : "qualification_phase_b_probe")
            let other = await f.registry.bind(kind: .track, descriptor: otherDescriptor,
                fingerprint: otherDescriptor.fingerprint, physicalTrack: otherPhysical)
            #expect(other != original && other != fresh)
            #expect(await f.registry.resolve(other) != nil)
            let second = try #require(sharedJSONObject(sharedToolText(
                await f.rename(project: project, target: fresh, expected: nil, desired: "qualification_phase_b_probe"))))
            #expect(second["state"] as? String == "A")
            #expect(await f.registry.resolve(original) == nil)
            #expect(await f.registry.resolve(other) != nil,
                "a different physical scope or exact name is not a superseded alias")
            let published = try #require(await TrackReferenceIssuance.issue(for: await f.cache.getTracks(),
                registry: f.registry, snapshot: snapshot))
            #expect(published.byTrackIndex[0] == fresh)
            let writes = f.writes
            let forbidden = try #require(sharedJSONObject(sharedToolText(
                await f.rename(project: project, target: other, expected: nil, desired: "Must not write"))))
            #expect(forbidden["state"] as? String == "C")
            #expect(f.writes == writes)
        }
    }

    @Test func ambiguousPhysicalHeaderCannotAuthorizeRenameOrAliasRetirement() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture("Audio 1")
            let (project, original) = try await f.prepare(typedProducer: true)
            let first = try #require(sharedJSONObject(sharedToolText(
                await f.rename(project: project, target: original, expected: nil, desired: "qualification_phase_b_probe"))))
            #expect(first["state"] as? String == "A")
            f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "Audio 1")
            f.builder.setAttribute(f.field, kAXValueAttribute as String, "Audio 1")
            let rows = try #require(AccessibilityChannel.defaultGetTrackStates(runtime: f.runtime))
            await f.cache.updateTracks(rows)
            let refs = try #require(await TrackReferenceIssuance.issue(for: rows, registry: f.registry,
                snapshot: await f.registry.currentSnapshot))
            let fresh = try #require(refs.byTrackIndex[0])
            let writes = f.writes
            f.builder.setChildren(f.rail, [f.header, f.header])
            let result = try #require(sharedJSONObject(sharedToolText(
                await f.rename(project: project, target: fresh, expected: nil, desired: "qualification_phase_b_probe"))))
            #expect(result["state"] as? String == "C")
            #expect(f.writes == writes)
            #expect(await f.registry.resolve(original) != nil,
                "no verified server rebind happened, so historical lookup is unchanged")
            #expect(await f.registry.resolve(fresh)?.descriptor.trackName == "Audio 1")
        }
    }

    @Test func verifiedPhysicalRenameRetiresItsOldAliasAfterAnObservedReorder() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture("Audio 1")
            let (peer, _) = f.appendTrack(name: "Peer", selected: false)
            let (project, original) = try await f.prepare(typedProducer: true)
            let first = try #require(sharedJSONObject(sharedToolText(
                await f.rename(project: project, target: original, expected: nil, desired: "qualification_phase_b_probe"))))
            #expect(first["state"] as? String == "A")
            let held = try #require(await f.registry.resolve(original)?.physicalTrack)
            f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "Audio 1")
            f.builder.setAttribute(f.field, kAXValueAttribute as String, "Audio 1")
            f.builder.setChildren(f.rail, [peer, f.header])
            let rows = try #require(AccessibilityChannel.defaultGetTrackStates(runtime: f.runtime))
            #expect(rows.count == 2)
        let reorderedPhysicalOwnerMatches = try #require(rows[1].physicalBinding?.matches(held))
        #expect(reorderedPhysicalOwnerMatches)
            #expect(held.currentIndex() == 1)
            await f.cache.updateTracks(rows)
            let snapshot = await f.registry.currentSnapshot
            let refs = try #require(await TrackReferenceIssuance.issue(for: rows, registry: f.registry, snapshot: snapshot))
            let fresh = try #require(refs.byTrackIndex[1])
            #expect(fresh != original)
            let second = try #require(sharedJSONObject(sharedToolText(
                await f.rename(project: project, target: fresh, expected: nil, desired: "qualification_phase_b_probe"))))
            #expect(second["state"] as? String == "A")
            #expect(await f.registry.resolve(fresh)?.descriptor.trackIndex == 1)
            #expect(await f.registry.resolve(original) == nil)
            let writes = f.writes
            let retired = try #require(sharedJSONObject(sharedToolText(
                await f.rename(project: project, target: original, expected: nil, desired: "Retired must not write"))))
            #expect(retired["state"] as? String == "C")
            #expect(f.writes == writes)
        }
    }

    @Test func registeredOrdinaryReferenceRenameAcquiresAndVerifiesForegroundBeforeItsMenu() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            f.passiveHeaderNameLabel = true
            f.builder.setAttribute(f.field, kAXValueAttribute as String, NSNumber(value: 0))
            f.builder.setAttributeSettable(f.field, kAXValueAttribute as String, false)
            let bar = f.builder.element(968_310), trackMenu = f.builder.element(968_311)
            let menu = f.builder.element(968_312), rename = f.builder.element(968_313)
            let editor = f.builder.element(968_314)
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
            f.builder.setChildren(bar, [trackMenu]); f.builder.setChildren(trackMenu, [menu]); f.builder.setChildren(menu, [rename])
            let (project, target) = try await f.prepare(typedProducer: true)
            f.observedFocusedPID = 9001
            f.logicIsFrontmost = false
            f.onActivation = { f.observedFocusedPID = f.observedLogicPID; f.logicIsFrontmost = true; return true }
            let runtime = f.runtime
            let dependencies = HandlerDependencies(router: f.router, cache: f.cache, targetRegistry: f.registry,
                poller: StatePoller(axChannel: AccessibilityChannel(), cache: f.cache,
                    runtime: .init(hasVisibleWindow: { false })), dialogPresent: { false }, supportBundleExporter: nil,
                liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) }, projectFileReader: .unavailable)
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_tracks", command: "rename"))
            let result = await handler(dependencies, ["project_ref": .string(project.rawValue),
                "target_ref": .string(target.rawValue), "name": .string("C")])
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(f.activationCalls == 1)
            #expect(body["state"] as? String == "A")
            #expect(f.writes == ["C"])
            #expect(f.events == ["rename_menu"])
            #expect(f.menuEditorValueWrites == ["C"])
            #expect(f.postedReturn)
            #expect(await f.registry.resolve(target)?.descriptor.trackName == "C")
        }
    }

    @Test(arguments: ["ack_only", "foreign_pid", "document", "gate", "false_ack_owned"])
    func ordinaryForegroundAcquisitionRequiresActualOriginalCustody(_ outcome: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare(typedProducer: true)
            f.observedFocusedPID = 9001
            f.logicIsFrontmost = false
            f.onActivation = {
                if outcome == "ack_only" { return true }
                f.observedFocusedPID = outcome == "foreign_pid" ? 9002 : f.observedLogicPID
                f.logicIsFrontmost = true
                if outcome == "document" {
                    f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                }
                if outcome == "gate" { f.boundaryOwnership = false }
                return outcome != "false_ack_owned"
            }
            let context = OperationTraceContext(ownsGate: { f.boundaryOwnership })
            let result = await OperationTraceContext.$current.withValue(context) {
                await f.rename(project: project, target: target, expected: nil, desired: "C")
            }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(f.activationCalls == 1)
            if outcome == "false_ack_owned" {
                #expect(body["state"] as? String == "A")
                #expect(f.writes == ["C"])
            } else {
                #expect(body["state"] as? String == "C")
                let attempted = try #require(body["write_attempted"] as? Bool)
                #expect(!attempted)
                #expect(f.writes.isEmpty)
                #expect(f.events.isEmpty)
                #expect(f.selectionWrites.isEmpty)
                #expect(f.menuEditorValueWrites.isEmpty)
            }
        }
    }

    @Test func exactOwnedNameAdapterDoesNotBorrowOrdinaryActivation() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (project, target) = try await f.prepare(typedProducer: true)
            f.onActivation = { Issue.record("Canonical owned naming must not activate through ordinary acquisition"); return false }
            let receipt = await f.apply(project: project, target: target, before: "A", after: "C")
            #expect(receipt.status == .applied)
            #expect(f.writes == ["C"])
            #expect(f.activationCalls == 0)
        }
    }

    @Test(arguments: ["multiple_selection", "unreadable_selection"])
    func canonicalNameBatchKeepsUnsupportedSelectionExplicit(_ kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = ExactNameFixture()
                _ = f.appendTrack(name: "B", selected: kind == "multiple_selection")
                if kind == "unreadable_selection" {
                    f.builder.removeAttribute(f.header, kAXSelectedAttribute as String)
                }
                let (capture, project, first, _, _) = try await f.coupledCapture(
                    peerStripName: "B", includePeerAssociation: true)
                let second = try #require(capture.issued?.byRow[1])
                let raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(project.rawValue), "targets": .array([
                        .object(["handle": .string("first"), "track_ref": .string(first.rawValue)]),
                        .object(["handle": .string("second"), "track_ref": .string(second.rawValue)])])]
                guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
                    Issue.record("the explicit naming policy must parse"); return
                }
                let names: [ProjectSessionAudit.ApprovedName] = [
                    .init(target: "first", name: "C"),
                    .init(target: "second", name: "D")]
                let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
                    names: names, capture: capture,
                    request: .init(domains: [.tracks, .strips, .associations]), snapshotCurrent: true)
                let body = try #require(sharedJSONObject(plan.json))
                let executable = try #require(body["executable"] as? Bool)
                #expect(!executable)
                let steps = try #require(body["steps"] as? [[String: Any]])
                #expect(steps.count == names.count)
                #expect(steps.allSatisfy { ($0["blocked_reasons"] as? [String])?.contains("naming_preservation_adapter_unavailable") == true })
                #expect(f.writes.isEmpty && f.selectionWrites.isEmpty)
            }
        }
    }

    @Test(arguments: ["healthy", "passive_name", "passive_mixer", "passive_mixer_editor", "passive_mixer_settable", "passive_mixer_value", "passive_mixer_unread", "passive_mixer_window", "passive_mixer_document", "passive_mixer_retired", "passive_mixer_unheld_focus", "refuse_second", "cancel_second", "newer_first", "selection_ack_only", "peer_after_first", "editing_after_first", "project_after_first",
        "swap", "duplicate", "swap_refuse_second", "duplicate_cancel_second", "swap_cancel_after_both", "duplicate_cancel_after_both", "swap_newer_first", "duplicate_peer_after_first"])
    func canonicalDistinctNamesShareOrderedReceiptsAndOwnedCompensation(_ scenario: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let swapping = scenario.hasPrefix("swap")
                let duplicating = scenario.hasPrefix("duplicate")
                let change = swapping ? String(scenario.dropFirst("swap".count)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                    : duplicating ? String(scenario.dropFirst("duplicate".count)).trimmingCharacters(in: CharacterSet(charactersIn: "_")) : scenario
                let outcome = change.isEmpty ? "healthy" : change
                let firstName = swapping ? "B" : "C"
                let secondName = swapping ? "A" : duplicating ? "C" : "D"
                let f = ExactNameFixture()
                let (other, otherName) = f.appendTrack(name: "B", selected: false)
                f.permitsSelection = true
                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.header)
                let (capture, project, first, _, mirror) = try await f.coupledCapture(
                    peerStripName: "B", includePeerAssociation: true, passiveMixerFocus: change.hasPrefix("passive_mixer"))
                if change.hasPrefix("passive_mixer") {
                    let observed = AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveMixerReadFocus(
                        window: f.window, logic: f.runtime, acquisitionPermitted: { true })
                    let proof = try #require(observed)
                    #expect(proof.permits())
                    if case .textEditing = AccessibilityChannel.readLogicKeyboardFocus(runtime: f.runtime) {} else {
                        Issue.record("The native-shaped passive Mixer still reaches the generic editing guard")
                    }
                }
                let second = try #require(capture.issued?.byRow[1])
                let otherMirror = try #require(f.coupledPeerNameField)
                let request = SessionPopulationObservation.Request(domains: [.tracks, .strips, .associations])
                let report = SessionPopulationObservation.build(request: request, capture: capture)
                let retained = await f.cache.retainSessionReport(id: capture.captureID,
                    json: String(decoding: try JSONEncoder().encode(report), as: UTF8.self),
                    capturedEpoch: capture.projectEpoch, capturedPath: capture.project.filePath,
                    capture: capture, request: request)
                #expect(retained)
                let raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(project.rawValue), "targets": .array([
                        .object(["handle": .string("first"), "track_ref": .string(first.rawValue)]),
                        .object(["handle": .string("second"), "track_ref": .string(second.rawValue)])])]
                guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
                    Issue.record("the ordered distinct naming policy must parse"); return
                }
                let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
                    names: [.init(target: "first", name: firstName), .init(target: "second", name: secondName)],
                    capture: capture, request: request, snapshotCurrent: true)
                let executable = try #require(sharedJSONObject(plan.json)?["executable"] as? Bool)
                #expect(executable)
                let stored = await f.cache.retainRepairPlan(plan, snapshotID: capture.captureID)
                #expect(stored)
                let journal = SagaJournal()
                let key = "ordered-distinct-canonical-names"
                let approval = try #require(await ApprovedSessionRepair.retained(id: plan.id, digest: plan.digest,
                    key: key, cache: f.cache, registry: f.registry, journal: journal))
                #expect(approval.plan.steps.map(\.targetRef) == [first, second])
                f.onConfirm = {
                    f.builder.setAttribute(mirror, kAXValueAttribute as String,
                        f.builder.attributeValue(f.field, kAXDescriptionAttribute as String))
                    f.builder.setAttribute(otherMirror, kAXValueAttribute as String,
                        f.builder.attributeValue(otherName, kAXDescriptionAttribute as String))
                }
                if change == "passive_name" {
                    f.passiveHeaderNameLabel = true
                    f.builder.setAttribute(f.field, kAXValueAttribute as String, NSNumber(value: 0))
                    f.builder.setAttributeSettable(f.field, kAXValueAttribute as String, false)
                    f.builder.setAttribute(f.field, kAXWindowAttribute as String, f.window)
                    f.builder.setAttribute(f.app, kAXFrontmostAttribute as String, true)
                    f.builder.setAttribute(f.app, kAXFocusedWindowAttribute as String, f.window)
                    f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.field)
                    let numeric: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                        f.field, kAXValueAttribute as String, runtime: f.runtime.ax)
                    let raw = try #require(try numeric.get())
                    #expect(CFGetTypeID(raw) == CFNumberGetTypeID())
                    let bar = f.builder.element(968_330), trackMenu = f.builder.element(968_331)
                    let menu = f.builder.element(968_332), rename = f.builder.element(968_333)
                    let editor = f.builder.element(968_334)
                    f.renameMenuItem = rename; f.menuFocusedEditor = editor
                    f.builder.setAttribute(f.app, kAXMenuBarAttribute as String, bar)
                    for (element, role) in [(bar, kAXMenuBarRole), (trackMenu, kAXMenuBarItemRole),
                        (menu, kAXMenuRole), (rename, kAXMenuItemRole), (editor, kAXTextFieldRole)] {
                        f.builder.setRole(element, role as String)
                    }
                    f.builder.setAttribute(trackMenu, kAXTitleAttribute as String, AXLocalePolicy.trackMenuBar.canonical)
                    f.builder.setAttribute(rename, kAXTitleAttribute as String, AXLocalePolicy.renameTrackMenuItem.canonical)
                    f.builder.setAttribute(editor, kAXWindowAttribute as String, f.window)
                    f.builder.setAttribute(editor, kAXValueAttribute as String, "A")
                    f.builder.setAttributeSettable(editor, kAXValueAttribute as String, true)
                    f.builder.setChildren(bar, [trackMenu]); f.builder.setChildren(trackMenu, [menu])
                    f.builder.setChildren(menu, [rename])
                    f.onMenuEditorValueSet = {
                        let name = f.builder.attributeValue(editor, kAXValueAttribute as String) as? String
                        f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, name as Any)
                        f.builder.setAttribute(mirror, kAXValueAttribute as String, name as Any)
                        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
                    }
                }
                if change.hasPrefix("passive_mixer_") {
                    let focus = try #require(f.passiveMixerStripFocus)
                    switch change {
                    case "passive_mixer_editor": f.builder.setAttribute(focus, kAXNumberOfCharactersAttribute as String, NSNumber(value: 1))
                    case "passive_mixer_settable": f.builder.setAttributeSettable(focus, kAXValueAttribute as String, true)
                    case "passive_mixer_value": f.passiveMixerHasValue = true
                    case "passive_mixer_unread": f.unreadPassiveMixerMetadata = true
                    case "passive_mixer_window": f.builder.setAttribute(f.app, kAXFocusedWindowAttribute as String, f.builder.element(968_299))
                    case "passive_mixer_document": f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    case "passive_mixer_retired":
                        let mixer = try #require(capture.channelStrips.first?.physicalBinding?.mixer)
                        f.builder.setChildren(mixer, capture.channelStrips.dropFirst().compactMap { $0.physicalBinding?.strip })
                    case "passive_mixer_unheld_focus":
                        let stranger = f.builder.element(968_299)
                        f.builder.setRole(stranger, kAXLayoutItemRole as String)
                        f.builder.setAttribute(stranger, kAXNumberOfCharactersAttribute as String, NSNumber(value: 0))
                        f.builder.setAttribute(stranger, kAXInsertionPointLineNumberAttribute as String, NSNumber(value: 0))
                        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, stranger)
                    default: Issue.record("Unknown passive Mixer refusal fixture")
                    }
                }
                f.onPress = {
                    let secondPress = f.actedNameFields.last.map { CFEqual($0, otherName) } == true
                    f.pressReportsFailure = secondPress && ["refuse_second", "newer_first"].contains(outcome)
                    if secondPress && outcome == "newer_first" {
                        f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "Human")
                        f.builder.setAttribute(mirror, kAXValueAttribute as String, "Human")
                    }
                }
                if change == "selection_ack_only" {
                    f.onSelection = {
                        f.builder.setAttribute(f.header, kAXSelectedAttribute as String, true)
                        f.builder.setAttribute(other, kAXSelectedAttribute as String, false)
                    }
                }
                let runtime = f.runtime
                func run() async -> CallTool.Result {
                    await SystemDispatcher.handle(command: "saga_execute", params: [:], router: f.router,
                        cache: f.cache, targetRegistry: f.registry, dialogPresent: { false },
                        sagaJournal: journal, mutationGate: LogicMutationGate(), sagaRefreshAfterWrite: {
                            if outcome == "cancel_second", f.writes == [firstName] {
                                #expect(await journal.cancel(idempotencyKey: key) == .requested)
                            }
                            if outcome == "cancel_after_both", f.writes == [firstName, secondName] {
                                #expect(await journal.cancel(idempotencyKey: key) == .requested)
                            }
                            if outcome == "peer_after_first", f.writes == [firstName] {
                                f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "Human")
                                f.builder.setAttribute(mirror, kAXValueAttribute as String, "Human")
                            }
                            if outcome == "editing_after_first", f.writes == [firstName] {
                                let editor = f.builder.element(968_299)
                                f.builder.setRole(editor, kAXTextAreaRole as String)
                                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, editor)
                            }
                            if outcome == "project_after_first", f.writes == [firstName] {
                                f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            }
                        }, liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                        liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) },
                        sagaLiveReadback: .unavailable, approvedSessionRepair: approval)
                }
                let body = try #require(sharedJSONObject(sharedToolText(await run())))
                if change.hasPrefix("passive_mixer_") {
                    #expect(body["saga_state"] as? String != "completed")
                    #expect(f.writes.isEmpty && f.menuEditorValueWrites.isEmpty && f.selectionWrites.isEmpty)
                    #expect(f.builder.attributeValue(mirror, kAXValueAttribute as String) as? String == "A")
                    #expect(f.builder.attributeValue(otherMirror, kAXValueAttribute as String) as? String == "B")
                } else if ["healthy", "passive_name", "passive_mixer"].contains(outcome) {
                    #expect(body["saga_state"] as? String == "completed")
                    let verified = try #require(body["verified"] as? Bool)
                    #expect(verified)
                    #expect(f.writes == (change == "passive_name" ? ["D"] : [firstName, secondName]))
                    #expect(f.menuEditorValueWrites == (change == "passive_name" ? ["C"] : []))
                    #expect(f.builder.attributeValue(mirror, kAXValueAttribute as String) as? String == firstName)
                    #expect(f.builder.attributeValue(otherMirror, kAXValueAttribute as String) as? String == secondName)
                } else if ["newer_first", "peer_after_first"].contains(outcome) {
                    #expect(f.writes == [firstName])
                    #expect(f.builder.attributeValue(f.field, kAXDescriptionAttribute as String) as? String == "Human")
                    #expect(body["saga_state"] as? String != "fullyCompensated")
                    if outcome == "newer_first" {
                        let steps = try #require(body["steps"] as? [[String: Any]])
                        let detail = try #require((steps[1]["result"] as? [String: Any])?["detail"] as? String)
                        #expect(detail.contains("not_restored"))
                    }
                } else if ["editing_after_first", "project_after_first"].contains(outcome) {
                    #expect(f.writes == [firstName])
                    #expect(f.selectionWrites.isEmpty)
                    #expect(body["saga_state"] as? String != "completed")
                } else {
                    #expect(body["saga_state"] as? String == "fullyCompensated")
                    #expect(f.writes == (outcome == "cancel_after_both" ? [firstName, secondName, "B", "A"] : [firstName, "A"]))
                    #expect(f.builder.attributeValue(otherName, kAXDescriptionAttribute as String) as? String == "B")
                }
                if outcome != "newer_first" {
                    let originalSelected = try #require(AXValueExtractors.extractSelectedState(f.header, runtime: runtime.ax))
                    let otherSelected = try #require(AXValueExtractors.extractSelectedState(other, runtime: runtime.ax))
                    #expect(originalSelected)
                    #expect(!otherSelected)
                }
                let writes = f.writes
                let selectionWrites = f.selectionWrites.count
                let events = f.events
                let routes = f.routedOperations
                let planID = try #require(approval.plan.canonicalPlanID)
                let digest = try #require(approval.plan.canonicalDigest)
                let applyRequest = try #require(ApprovedSessionRepair.ApplyRequest.parse([
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
                    await ApprovedSessionRepair.apply(request: applyRequest, dependencies: dependencies))))
                let duplicate = try #require(replay["duplicate"] as? Bool)
                #expect(duplicate)
                #expect(f.writes == writes)
                #expect(f.selectionWrites.count == selectionWrites)
                #expect(f.events == events)
                #expect(f.routedOperations == routes)
            }
        }
    }

    @Test(arguments: ["healthy", "mirror_edit_after_write"])
    func aMatchingMixerOriginRemainsVerifiedAlongsideAChangedTrackGoal(_ change: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = ExactNameFixture()
                let (_, peer) = f.appendTrack(name: "Peer", selected: false)
                let (capture, project, track, _, mirror) = try await f.coupledCapture(
                    peerStripName: "Peer", includePeerAssociation: true)
                let origin = try #require(capture.mixerReference(at: 1))
                let peerMirror = try #require(f.coupledPeerNameField)
                let request = SessionPopulationObservation.Request(domains: [.tracks, .strips, .associations])
                let report = SessionPopulationObservation.build(request: request, capture: capture)
                let retained = await f.cache.retainSessionReport(id: capture.captureID,
                    json: String(decoding: try JSONEncoder().encode(report), as: UTF8.self),
                    capturedEpoch: capture.projectEpoch, capturedPath: capture.project.filePath,
                    capture: capture, request: request)
                #expect(retained)
                let raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(project.rawValue), "targets": .array([
                        .object(["handle": .string("changed"), "track_ref": .string(track.rawValue)]),
                        .object(["handle": .string("matching"), "mixer_ref": .string(origin.rawValue)])])]
                guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
                    Issue.record("the mixed physical-origin naming policy must parse"); return
                }
                let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
                    names: [.init(target: "changed", name: "C"), .init(target: "matching", name: "Peer")],
                    capture: capture, request: request, snapshotCurrent: true)
                let stored = await f.cache.retainRepairPlan(plan, snapshotID: capture.captureID)
                #expect(stored)
                let journal = SagaJournal()
                let approval = try #require(await ApprovedSessionRepair.retained(id: plan.id, digest: plan.digest,
                    key: "mixed-mixer-origin", cache: f.cache, registry: f.registry, journal: journal))
                f.onConfirm = {
                    f.builder.setAttribute(mirror, kAXValueAttribute as String,
                        f.builder.attributeValue(f.field, kAXDescriptionAttribute as String))
                    if change == "mirror_edit_after_write" {
                        f.builder.setAttribute(peerMirror, kAXValueAttribute as String, "Human Mixer")
                    }
                }
                let runtime = f.runtime
                let result = await SystemDispatcher.handle(command: "saga_execute", params: [:], router: f.router,
                    cache: f.cache, targetRegistry: f.registry, dialogPresent: { false },
                    sagaJournal: journal, mutationGate: LogicMutationGate(), sagaRefreshAfterWrite: {},
                    liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                    liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) },
                    sagaLiveReadback: .unavailable, approvedSessionRepair: approval)
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                if change == "healthy" {
                    #expect(body["saga_state"] as? String == "completed")
                    let verified = try #require(body["verified"] as? Bool)
                    #expect(verified)
                } else {
                    let verified = body["verified"] as? Bool ?? false
                    #expect(!verified)
                }
                #expect(f.writes == ["C"])
                #expect(f.builder.attributeValue(peer, kAXDescriptionAttribute as String) as? String == "Peer")
            }
        }
    }

    @Test(arguments: ["healthy", "mirror_edit", "mirror_retired"])
    func aMatchingMixerOriginRequiresFreshTwoSidedEvidenceWithoutWrites(_ change: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = ExactNameFixture()
                let (capture, project, track, strip, mirror) = try await f.coupledCapture(peerStripName: "Peer")
                let origin = try #require(capture.mixerReference(at: 0))
                let journal = SagaJournal()
                let approval = try await f.canonicalNameApproval(capture, project: project, target: track,
                    desired: "A", key: "matching-mixer-origin", journal: journal, mixerOrigin: origin)
                #expect(approval.plan.steps.isEmpty)
                if change == "mirror_edit" { f.builder.setAttribute(mirror, kAXValueAttribute as String, "Human Mixer") }
                if change == "mirror_retired" {
                    let replacement = f.builder.element(968_298)
                    f.builder.setRole(replacement, kAXLayoutItemRole as String)
                    f.builder.setChildren(replacement, [mirror])
                    let mixer = try #require(capture.channelStrips.first?.physicalBinding?.mixer)
                    let children = AXHelpers.getChildren(mixer, runtime: f.runtime.ax)
                    f.builder.setChildren(mixer, children.map { CFEqual($0, strip) ? replacement : $0 })
                }
                let runtime = f.runtime
                let result = await SystemDispatcher.handle(command: "saga_execute", params: [:], router: f.router,
                    cache: f.cache, targetRegistry: f.registry, dialogPresent: { false },
                    sagaJournal: journal, mutationGate: LogicMutationGate(), sagaRefreshAfterWrite: {},
                    liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                    liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) },
                    sagaLiveReadback: .unavailable, approvedSessionRepair: approval)
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                if change == "healthy" {
                    #expect(body["saga_state"] as? String == "completed")
                    let verified = try #require(body["verified"] as? Bool)
                    #expect(verified)
                } else {
                    #expect(body["state"] as? String == "C")
                }
                #expect(f.writes.isEmpty)
                #expect(f.routedOperations.isEmpty)
                #expect(f.builder.attributeValue(f.field, kAXDescriptionAttribute as String) as? String == "A")
            }
        }
    }

    @Test(arguments: [true, false])
    func aPhysicalMixerOriginUsesItsCapturedPairAndTheExistingCoupledTrackSaga(coupled: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = ExactNameFixture()
                let (_, peer) = f.appendTrack(name: "Peer", selected: false)
                let (capture, project, track, _, mirror) = try await f.coupledCapture(peerStripName: "Peer")
                let mixer = try #require(capture.mixerReference(at: 0))
                let desired = "Mixer-origin, \"한글\" 😀"
                let request = SessionPopulationObservation.Request(domains: [.tracks, .strips, .associations])
                let raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(project.rawValue),
                    "targets": .array([.object(["handle": .string("exact"), "mixer_ref": .string(mixer.rawValue)])])]
                guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
                    Issue.record("An exact physical Mixer naming origin must parse without pretending to be a Track reference")
                    return
                }
                let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
                    names: [.init(target: "exact", name: desired)], capture: capture,
                    request: request, snapshotCurrent: true)
                let body = try #require(sharedJSONObject(plan.json))
                let executable = try #require(body["executable"] as? Bool)
                #expect(executable)
                let step = try #require((body["steps"] as? [[String: Any]])?.first)
                #expect(step["target_ref"] as? String == track.rawValue)
                #expect(step["requested_mixer_ref"] as? String == mixer.rawValue)
                let after = try #require(step["coupled_after"] as? [[String: String]])
                #expect(after == [["target_ref": track.rawValue, "name": desired],
                                  ["target_ref": mixer.rawValue, "name": desired]])
                let wire = try JSONDecoder().decode(Value.self, from: Data(plan.json.utf8))
                #expect(wire.objectValue?["steps"] == wire.objectValue?["preview"])
                #expect(wire.objectValue?["approved_policy"] == .object(raw))
                let repeated = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
                    names: [.init(target: "exact", name: desired)], capture: capture,
                    request: request, snapshotCurrent: true)
                #expect(plan.digest == repeated.digest)
                let report = SessionPopulationObservation.build(request: request, capture: capture)
                let retained = await f.cache.retainSessionReport(id: capture.captureID,
                    json: String(decoding: try JSONEncoder().encode(report), as: UTF8.self),
                    capturedEpoch: capture.projectEpoch, capturedPath: capture.project.filePath,
                    capture: capture, request: request)
                #expect(retained)
                #expect(await f.cache.retainRepairPlan(plan, snapshotID: capture.captureID))
                let journal = SagaJournal()
                let approval = try #require(await ApprovedSessionRepair.retained(id: plan.id, digest: plan.digest,
                    key: "physical-mixer-origin", cache: f.cache, registry: f.registry, journal: journal))
                if !coupled { f.onConfirm = nil }
                let runtime = f.runtime
                let result = await SystemDispatcher.handle(command: "saga_execute", params: [:], router: f.router,
                    cache: f.cache, targetRegistry: f.registry, dialogPresent: { false },
                    sagaJournal: journal, mutationGate: LogicMutationGate(), sagaRefreshAfterWrite: {},
                    liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                    liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) },
                    sagaLiveReadback: .unavailable, approvedSessionRepair: approval)
                let outcome = try #require(sharedJSONObject(sharedToolText(result)))
                #expect(outcome["saga_state"] as? String == (coupled ? "completed" : "fullyCompensated"))
                let verified = try #require(outcome["verified"] as? Bool)
                if coupled { #expect(verified) } else { #expect(!verified) }
                #expect(f.writes == (coupled ? [desired] : [desired, "A"]))
                #expect(f.routedOperations == (coupled ? ["track.rename"] : ["track.rename", "track.rename"]))
                #expect(f.builder.attributeValue(mirror, kAXValueAttribute as String) as? String == (coupled ? desired : "A"))
                #expect(f.builder.attributeValue(peer, kAXDescriptionAttribute as String) as? String == "Peer")
            }
        }
    }

    @Test(arguments: ["missing", "duplicate", "different_name", "unmatched", "foreign_ref", "stale", "same_alias", "conflicting_alias"])
    func aMixerOriginCannotGuessOrDuplicateItsCoupledTrackGoal(_ fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = ExactNameFixture()
                let (capture, project, track, _, _) = try await f.coupledCapture(link: fault, peerStripName: "Peer")
                let mixer = try #require(capture.mixerReference(at: fault == "unmatched" ? 1 : 0))
                var targets: [Value] = [.object(["handle": .string("exact"), "mixer_ref":
                    .string(fault == "foreign_ref" ? "mix_unissued" : mixer.rawValue)])]
                var names: [ProjectSessionAudit.ApprovedName] = [.init(target: "exact", name: "Desired")]
                if fault.hasSuffix("alias") {
                    targets.append(.object(["handle": .string("track"), "track_ref": .string(track.rawValue)]))
                    names.append(.init(target: "track", name: fault == "same_alias" ? "Desired" : "Other"))
                }
                let raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(project.rawValue), "targets": .array(targets)]
                guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
                    Issue.record("The structured naming request must reach captured-pair validation: \(fault)")
                    return
                }
                let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
                    names: names, capture: capture,
                    request: .init(domains: [.tracks, .strips, .associations]), snapshotCurrent: fault != "stale")
                let body = try #require(sharedJSONObject(plan.json))
                let executable = try #require(body["executable"] as? Bool)
                #expect(!executable)
                let steps = try #require(body["steps"] as? [[String: Any]])
                #expect(steps.count == names.count)
                #expect(steps.first?["requested_mixer_ref"] as? String == (fault == "foreign_ref" ? "mix_unissued" : mixer.rawValue))
                let reasons = try #require(body["reasons"] as? [String])
                #expect(!reasons.isEmpty)
                #expect(f.writes.isEmpty)
                #expect(f.routedOperations.isEmpty)
            }
        }
    }

    @Test(arguments: ["both_refs", "mixer_as_track", "track_as_mixer", "output", "send", "presentation"])
    func typedMixerNamingOriginsCannotImportTrackOrNonNamingAuthority(_ fault: String) {
        var target: [String: Value] = ["handle": .string("exact"), "mixer_ref": .string("mix_origin")]
        if fault == "both_refs" { target["track_ref"] = .string("trk_origin") }
        if fault == "mixer_as_track" { target = ["handle": .string("exact"), "track_ref": .string("mix_origin")] }
        if fault == "track_as_mixer" { target["mixer_ref"] = .string("trk_origin") }
        var raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
            "project_ref": .string("prj_origin"), "targets": .array([.object(target)])]
        if fault == "output" { raw["outputs"] = .array([.object(["target": .string("exact"), "bus": .int(3)])]) }
        if fault == "send" { raw["sends"] = .array([.object(["target": .string("exact"), "physical_slot": .int(0), "bus": .int(3)])]) }
        if fault == "presentation" { raw["presentation"] = .object(["mixer_visible": .bool(true)]) }
        guard case .rejected(let reasons) = ProjectSessionAudit.parseIntentPolicy(raw) else {
            Issue.record("Invalid physical-origin namespace or non-naming authority must be rejected: \(fault)")
            return
        }
        #expect(!reasons.isEmpty)
    }

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

    @Test(arguments: ["committed", "newer_name", "peer_changed", "project_changed", "membership_changed", "gate_lost",
                      "editing_elsewhere", "focus_unreadable"], ["immediate", "post_set_value_read"])
    func canonicalCancellationCanRestoreASetterCommittedNameWithoutPostingIntoLostEditor(change: String, closure: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = ExactNameFixture()
                let (peerHeader, peer) = f.appendTrack(name: "Peer", selected: false)
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
                let (capture, project, target, _, mirror) = try await f.coupledCapture(peerStripName: "Peer")
                f.onRenameMenuRead = {
                    f.builder.setAttribute(editor, kAXValueAttribute as String,
                        f.builder.attributeValue(f.field, kAXDescriptionAttribute as String) as Any)
                }
                let commitAndClose: @Sendable () -> Void = {
                    // This models a successful actual String setter which commits the
                    // original pair and closes its editor. It is not a channel ack-only.
                    let name = f.builder.attributeValue(editor, kAXValueAttribute as String) as? String
                    f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, name as Any)
                    f.builder.setAttribute(mirror, kAXValueAttribute as String, name as Any)
                    f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                        change == "editing_elsewhere" ? peer : change == "focus_unreadable" ? f.builder.element(968_242) : f.rail)
                    if change == "newer_name" {
                        f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "Human")
                        f.builder.setAttribute(mirror, kAXValueAttribute as String, "Human")
                    }
                    if change == "peer_changed" { f.builder.setAttribute(peer, kAXDescriptionAttribute as String, "Human peer") }
                    if change == "project_changed" {
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                    }
                    if change == "membership_changed" {
                        let added = f.builder.element(968_240), addedName = f.builder.element(968_241)
                        f.builder.setRole(added, kAXLayoutItemRole as String)
                        f.builder.setAttribute(added, kAXSelectedAttribute as String, false)
                        f.builder.setRole(addedName, kAXTextFieldRole as String)
                        f.builder.setAttribute(addedName, kAXDescriptionAttribute as String, "Unexpected")
                        f.builder.setChildren(addedName, [])
                        f.builder.setChildren(added, [addedName])
                        f.builder.setChildren(f.rail, [f.header, peerHeader, added])
                    }
                    if change == "gate_lost" { f.boundaryOwnership = false }
                }
                if closure == "immediate" { f.onMenuEditorValueSet = commitAndClose }
                else { f.onMenuEditorValueReadAfterSet = commitAndClose }
                let approval = try await f.canonicalNameApproval(capture, project: project, target: target,
                    desired: "Canonical", key: "cancel-auto-committed-name", journal: SagaJournal())
                let runtime = f.runtime
                let executor = ProductionSagaStepExecutor(router: f.router, cache: f.cache,
                    targetRegistry: f.registry, dialogPresent: { false }, liveReadback: .unavailable,
                    liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                    liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) }, approvedSessionRepair: approval)
                let saga = MutationSaga(targetRegistry: f.registry, approvedSessionRepair: approval, routeAvailable: { _ in true })
                let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { f.boundaryOwnership })
                await OperationTraceContext.$current.withValue(context) {
                    let outcome = await saga.execute(approval.plan, executor: executor,
                        cancellationRequested: { !f.menuEditorValueWrites.isEmpty })
                    #expect(outcome.state == (change == "committed" ? .fullyCompensated : .rollbackUncertain))
                    #expect(f.menuEditorValueWrites == (change == "committed" ? ["Canonical", "A"] : ["Canonical"]))
                    #expect(f.builder.attributeValue(f.field, kAXDescriptionAttribute as String) as? String
                        == (change == "committed" ? "A" : change == "newer_name" ? "Human" : "Canonical"))
                    #expect(f.builder.attributeValue(mirror, kAXValueAttribute as String) as? String
                        == (change == "committed" ? "A" : change == "newer_name" ? "Human" : "Canonical"))
                    #expect(!f.postedReturn && f.typedCodeUnits.isEmpty)
                    #expect(f.builder.attributeValue(peer, kAXDescriptionAttribute as String) as? String
                        == (change == "peer_changed" ? "Human peer" : "Peer"))
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

    @Test(arguments: ["healthy", "primary", "mirror", "old_goal_mirror"])
    func anIndependentMirrorReceiptFreezesBothActualNames(_ change: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (capture, project, target, _, mirror) = try await f.coupledCapture()
            f.onConfirm = nil
            let forward = await f.applyCoupled(capture, project: project, target: target)
            #expect(forward.status == .applied)
            let proof = try #require(forward.inverse)
            let effect = try #require(ExactTrackNameAdapter.recordedNameEffect(proof))
            #expect(effect.trackName == "C" && effect.stripName == "A")
            #expect(await ExactTrackNameAdapter.readOwnedCoupledName(proof) == "C")
            if change == "primary" { f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "External") }
            if change == "mirror" { f.builder.setAttribute(mirror, kAXValueAttribute as String, "External") }
            if change == "old_goal_mirror" { f.builder.setAttribute(mirror, kAXValueAttribute as String, "C") }
            #expect(await ExactTrackNameAdapter.readOwnedCoupledName(proof) == (change == "healthy" ? "C" : nil))
            let restored = await f.inverse(proof)
            #expect(restored.status == (change == "healthy" ? .applied : .rejectedBeforeWrite))
            #expect(f.writes == (change == "healthy" ? ["C", "A"] : ["C"]))
            #expect(f.builder.attributeValue(mirror, kAXValueAttribute as String) as? String
                == (change == "mirror" ? "External" : change == "old_goal_mirror" ? "C" : "A"))
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

    @Test func anInverseCannotReviveAnExposedPeerAfterAnEarlierOwnerReadFailed() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (peer, field) = f.appendTrack(name: "Peer", selected: false)
            let disclosure = f.builder.element(3_968_000)
            f.builder.setRole(disclosure, kAXDisclosureTriangleRole as String)
            f.builder.setAttribute(disclosure, kAXValueAttribute as String, NSNumber(value: 1))
            f.builder.setChildren(disclosure, []); f.builder.setChildren(peer, [field, disclosure])
            let exposure = AXTrackBinding.Exposure(header: peer, disclosure: disclosure, runtime: f.runtime)
            let (capture, project, target, _, _) = try await f.coupledCapture(peerExposure: exposure)
            let capturedExposure = try #require(capture.tracks[1].physicalBinding?.exposure)
            #expect(capturedExposure === exposure)
            #expect(exposure.isCurrent)
            let written = await f.applyCoupled(capture, project: project, target: target)
            #expect(written.status == .applied)
            let proof = try #require(written.inverse)
            let document = try #require(f.builder.attributeValue(f.window, kAXDocumentAttribute as String) as? String)
            f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
            #expect((await f.inverse(proof)).status == .rejectedBeforeWrite)
            #expect(exposure.hasEnded, "An earlier aggregate cutoff cannot hide the original exposed-peer loss")
            f.builder.setAttribute(f.window, kAXDocumentAttribute as String, document)
            #expect((await f.inverse(proof)).status == .rejectedBeforeWrite)
            #expect(f.writes == ["C"], "Reappearing handles cannot revive an ended exposure or permit another writer")
        }
    }

    private static var originalSourceScopeProfiles: [String] {
        var profiles: [String] = []
        for scope in ["unrenewed", "renewed"] {
            for fault in ["healthy", "primary", "mirror", "peer", "document", "gate"] {
                profiles.append("\(scope)/\(fault)")
            }
        }
        for fault in ["document", "selection", "transport", "population", "gate"] {
            profiles.append("renewed/late_\(fault)")
        }
        for fault in ["healthy", "primary", "mirror", "peer", "document", "gate", "late_population"] {
            profiles.append("renewed_retired/\(fault)")
        }
        profiles += ["renewed_rail/healthy", "renewed_retired_rail/healthy", "renewed/late_mixer_role", "renewed/late_rail_role",
            "renewed_retired/late_mixer_role", "renewed_retired/late_rail_role", "renewed_rail/late_population",
            "renewed_retired_rail/late_population", "renewed/focus_during_window_bookend",
            "renewed_retired/focus_during_window_bookend", "renewed_rail/focus_during_window_bookend",
            "renewed_retired_rail/focus_during_window_bookend"]
        for scope in ["renewed", "renewed_retired", "renewed_rail", "renewed_retired_rail"] {
            for fault in ["popup_healthy", "popup_focus", "popup_population",
                          "popup_search_healthy", "popup_search_focus", "popup_search_population"] {
                profiles.append("\(scope)/\(fault)")
            }
        }
        return profiles
    }

    @Test(arguments: Self.originalSourceScopeProfiles)
    func anOwnedNameReadUsesOnlyItsActualRenewedSourceScope(profile: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let renewed = profile.hasPrefix("renewed")
            let retired = profile.hasPrefix("renewed_retired")
            let railEntry = profile.contains("_rail/")
            let fault = String(try #require(profile.split(separator: "/").last))
            let f = ExactNameFixture()
            f.useBulkReads = true
            f.permitsSelection = true
            let (peerHeader, _) = f.appendTrack(name: "Peer", selected: false)
            let (capture, project, target, strip, mirror) = try await f.coupledCapture(
                peerStripName: "Peer", includePeerAssociation: true, passiveMixerFocus: true)
            f.builder.setAttributeSettable(f.rail, kAXSelectedChildrenAttribute as String, true)
            f.builder.setAttribute(f.rail, kAXSelectedChildrenAttribute as String, [f.header])
            let mixer = f.builder.element(968_170), peerStrip = f.builder.element(968_173)
            let originalMixerRole = try #require(AXHelpers.getRole(mixer, runtime: f.builder.makeAXRuntime()))
            let originalRailRole = try #require(AXHelpers.getRole(f.rail, runtime: f.builder.makeAXRuntime()))
            f.additionalPassiveMixerStrips = [peerStrip]
            f.builder.setAttribute(peerStrip, kAXNumberOfCharactersAttribute as String, NSNumber(value: 0))
            f.builder.setAttribute(peerStrip, kAXInsertionPointLineNumberAttribute as String, NSNumber(value: 0))
            f.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, [strip])
            f.onSelection = {
                let selected = f.selectionWrites.last.map { CFEqual($0, peerHeader) } == true ? peerStrip : strip
                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, selected)
                f.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, [selected])
            }
            let bar = f.builder.element(3_971_968), play = f.builder.element(3_971_969)
            let record = f.builder.element(3_971_970)
            f.builder.setRole(bar, kAXGroupRole as String)
            f.builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
            for (control, title) in [(play, "Play"), (record, "Record")] {
                f.builder.setRole(control, kAXCheckBoxRole as String)
                f.builder.setAttribute(control, kAXTitleAttribute as String, title)
                f.builder.setAttribute(control, kAXValueAttribute as String, 0)
                f.builder.setChildren(control, [])
            }
            f.builder.setChildren(bar, [play, record])
            f.builder.setChildren(f.window, AXHelpers.getChildren(f.window, runtime: f.builder.makeAXRuntime()) + [bar])
            let gate = LogicMutationGate()
            let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
            defer { gate.release(claim) }
            let context = OperationTraceContext(mutationGateAcquired: true,
                ownsGate: { gate.stillOwns(claim) && f.boundaryOwnership })
            try await OperationTraceContext.$current.withValue(context) {
                let written = await f.applyCoupled(capture, project: project, target: target)
                try #require(written.status == .applied)
                var proof = try #require(written.inverse)
                if renewed {
                    let pair = try #require(capture.freshPopulation?.selectionAssociations.first)
                    let currentStrip: AXUIElement
                    if retired {
                        let replacement = f.builder.element(3_971_971)
                        f.builder.setRole(replacement, kAXLayoutItemRole as String)
                        f.builder.setChildren(replacement, AXHelpers.getChildren(strip, runtime: f.builder.makeAXRuntime()))
                        f.builder.setChildren(mixer, [replacement, peerStrip])
                        f.builder.setAttribute(replacement, kAXNumberOfCharactersAttribute as String, NSNumber(value: 0))
                        f.builder.setAttribute(replacement, kAXInsertionPointLineNumberAttribute as String, NSNumber(value: 0))
                        f.passiveMixerStripFocus = replacement
                        currentStrip = replacement
                    } else { currentStrip = strip }
                    if railEntry {
                        f.passiveRailFocus = true
                        f.builder.setAttributeSettable(f.rail, kAXValueAttribute as String, false)
                    }
                    f.onSelection = {
                        let peerSelected = f.selectionWrites.last.map { CFEqual($0, peerHeader) } == true
                        let selected = peerSelected ? peerStrip : currentStrip
                        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                            railEntry && !peerSelected ? f.rail : selected)
                        f.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, [selected])
                    }
                    f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, railEntry ? f.rail : currentStrip)
                    f.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, [currentStrip])
                    let acquired = await AccessibilityChannel.renewSourceThroughOriginalHeader(pair, original: pair.strip,
                        runtime: f.runtime, sourceDisposition: retired ? .retiredOriginal : .readObservation)
                    let source = try #require(acquired.source, "Use the actual original-header producer and its verified selection inverse")
                    #expect(acquired.effects.restoration == "restored")
                    #expect(source.observedPairs.count == 2, "The actual producer must observe both native associations")
                    #expect(source.pair.strip.matches(pair.strip) == !retired)
                    if fault.hasPrefix("popup_") {
                        let popup = f.builder.element(3_971_974)
                        f.builder.setRole(popup, kAXMenuRole as String)
                        f.builder.setChildren(popup, [])
                        let mixerChildren = AXHelpers.getChildren(mixer, runtime: f.builder.makeAXRuntime())
                        f.builder.setChildren(mixer, mixerChildren + [popup])
                        let popupFault = fault.replacingOccurrences(of: "popup_search_", with: "popup_")
                        let popupFocus: AXUIElement
                        if fault.hasPrefix("popup_search_") {
                            let search = f.builder.element(3_971_976)
                            f.builder.setRole(search, kAXTextFieldRole as String)
                            f.builder.setChildren(search, [])
                            f.builder.setChildren(popup, [search])
                            f.popupFocusedWindowIsNoValue = true
                            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, search)
                            popupFocus = search
                        } else { popupFocus = railEntry ? f.rail : currentStrip }
                        #expect(source.observation.permitsOwnedPopupRead(popup), "The actual source must own this reciprocal popup")
                        f.physicalOwnerDocumentReads = 0
                        #expect(source.permits(runtime: f.runtime, ownedPopup: popup), "Prove current popup admission before measuring or injecting a fault")
                        let decidingDocumentRead = f.physicalOwnerDocumentReads
                        #expect(decidingDocumentRead > 0, "Calibrate the actual last native document read")
                        if popupFault == "popup_healthy" {
                            f.globalMixerDiscoveries = 0
                            #expect(source.permits(runtime: f.runtime, ownedPopup: popup))
                            #expect(f.globalMixerDiscoveries == 0,
                                "The actual original-header popup scope must retain current native bookends without global Mixer rediscovery")
                        } else if popupFault == "popup_focus" {
                            f.physicalOwnerDocumentReads = 0
                            let foreignFocus = f.builder.element(3_971_975)
                            f.onPhysicalOwnerDocumentRead = { read in
                                if read == decidingDocumentRead {
                                    f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, foreignFocus)
                                }
                            }
                            #expect(!source.permits(runtime: f.runtime, ownedPopup: popup),
                                "The final reciprocal popup check must refuse native-read focus drift")
                            #expect(f.physicalOwnerDocumentReads >= decidingDocumentRead, "Actually reach the last native document-read focus fault")
                            f.onPhysicalOwnerDocumentRead = nil
                            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, popupFocus)
                            #expect(!source.permits(runtime: f.runtime, ownedPopup: popup), "Restored focus cannot revive lost popup custody")
                        } else {
                            let originalHeaders = AXHelpers.getChildren(f.rail, runtime: f.builder.makeAXRuntime())
                            f.builder.setChildren(f.rail, [f.header])
                            #expect(!source.permits(runtime: f.runtime, ownedPopup: popup))
                            f.builder.setChildren(f.rail, originalHeaders)
                            #expect(!source.permits(runtime: f.runtime, ownedPopup: popup), "A restored population cannot revive observed original-header loss")
                        }
                        #expect(f.writes == ["C"], "Identity and popup permission reads cannot add a writer")
                        return
                    }
                    if fault == "focus_during_window_bookend" {
                        f.physicalOwnerDocumentReads = 0
                        #expect(source.permits(runtime: f.runtime), "First prove this actual source is admitted")
                        let decidingDocumentRead = f.physicalOwnerDocumentReads
                        #expect(decidingDocumentRead > 0)
                        f.physicalOwnerDocumentReads = 0
                        let foreignFocus = f.builder.element(3_971_973)
                        f.onPhysicalOwnerDocumentRead = { read in
                            if read == decidingDocumentRead {
                                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, foreignFocus)
                            }
                        }
                        #expect(!source.permits(runtime: f.runtime),
                            "Focus drift during later native document reads must be followed by final passive custody")
                        #expect(f.physicalOwnerDocumentReads >= decidingDocumentRead, "The actual last native document-read fault must fire")
                        f.onPhysicalOwnerDocumentRead = nil
                        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, railEntry ? f.rail : currentStrip)
                        #expect(!source.permits(runtime: f.runtime), "Observed focus loss cannot revive after restoration")
                        #expect(f.writes == ["C"], "Permission reads must not add writers")
                        return
                    }
                    if fault == "healthy" {
                        let native = source.pair.strip
                        let foreign = f.builder.element(3_971_972)
                        for mutation in ["index", "window", "mixer", "document"] {
                            let binding = AXMixerStripBinding.Binding(
                                window: mutation == "window" ? foreign : native.window,
                                mixer: mutation == "mixer" ? foreign : native.mixer, strip: native.strip,
                                document: mutation == "document" ? "file:///tmp/Foreign.logicx" : native.document)
                            let unowned = AccessibilityChannel.OriginalHeaderSourceRenewal(
                                pair: .init(track: source.pair.track, strip: binding),
                                index: source.index + (mutation == "index" ? 1 : 0), original: source.original,
                                originalTrack: source.originalTrack, observation: source.observation,
                                observedPairs: source.observedPairs)
                            #expect(!unowned.permits(runtime: f.runtime), "Foreign \(mutation) cannot borrow the actual source scope")
                        }
                        f.countedMixer = mixer
                        f.mixerPopulationReads = 0
                        #expect(source.permits(runtime: f.runtime))
                        #expect(f.mixerPopulationReads == (railEntry ? 4 : 3),
                            "The final original-header bookend must include passive custody without repeating the complete Mixer census; retain both header bookends and rail-selected-child custody")
                    }
                    f.globalMixerDiscoveries = 0
                    proof = try #require(await ExactTrackNameAdapter.renewingOwnedCoupledName(proof, through: source))
                    if fault == "healthy" {
                        #expect(f.globalMixerDiscoveries == 0,
                            "Actual surviving/retired source membership is already authenticated by the complete renewed native census")
                    }
                }
                if fault == "primary" { f.builder.setAttribute(f.field, kAXDescriptionAttribute as String, "External") }
                if fault == "mirror" { f.builder.setAttribute(mirror, kAXValueAttribute as String, "External") }
                if fault == "peer", let peer = f.coupledPeerNameField {
                    f.builder.setAttribute(peer, kAXValueAttribute as String, "External")
                }
                if fault == "document" { f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx") }
                if fault == "gate" { f.boundaryOwnership = false }
                f.countedMixer = mixer
                f.mixerPopulationReads = 0
                f.onPeerNameReadAfterWrite = { _ in f.mixerPopulationReadsAtLastPeer = f.mixerPopulationReads }
                f.onMirrorReadAfterWrite = {
                    f.mixerCensusesWithinNameGroups.append(f.mixerPopulationReads - f.mixerPopulationReadsAtLastPeer)
                    if fault == "late_document" {
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                    if fault == "late_selection" {
                        f.builder.setAttribute(f.header, kAXSelectedAttribute as String, false)
                        f.builder.setAttribute(peerHeader, kAXSelectedAttribute as String, true)
                    }
                    if fault == "late_transport" { f.builder.setAttribute(play, kAXValueAttribute as String, 1) }
                    if fault == "late_population" { f.builder.setChildren(mixer, [strip]) }
                    if fault == "late_mixer_role" { f.builder.setRole(mixer, kAXButtonRole as String) }
                    if fault == "late_rail_role" { f.builder.setRole(f.rail, kAXButtonRole as String) }
                    if fault == "late_gate" { f.boundaryOwnership = false }
                }
                f.globalMixerDiscoveries = 0
                #expect(await ExactTrackNameAdapter.readOwnedCoupledName(proof) == (fault == "healthy" ? "C" : nil))
                if fault == "late_mixer_role" || fault == "late_rail_role" {
                    f.onMirrorReadAfterWrite = nil
                    f.builder.setRole(mixer, originalMixerRole)
                    f.builder.setRole(f.rail, originalRailRole)
                    #expect(await ExactTrackNameAdapter.readOwnedCoupledName(proof) == nil,
                        "Observed invalid native roles irreversibly end this scope even if their old values return")
                }
                if fault == "healthy" {
                    if renewed {
                        #expect(f.globalMixerDiscoveries == 0,
                            "The actual renewed scope checks complete current membership without global Mixer rediscovery")
                        #expect(f.mixerCensusesWithinNameGroups == [0, 0],
                            "Both peer/name groups retain their full bookends without nesting another census between their values")
                        #expect(f.mixerPopulationReads > 0, "Fresh native census bookends must actually execute")
                    } else {
                        #expect(f.globalMixerDiscoveries > 0, "The original unrenewed name read retains its global discovery")
                    }
                }
                #expect(f.writes == ["C"], "Independent name reads cannot perform another rename or inverse")
            }
        }
    }

    @Test func anOwnedCoupledNameReadDoesNotRediscoverTheProjectForEveryPeer() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            var ownerReads: [Int] = []
            for count in [1, 6] {
                let f = ExactNameFixture()
                for ordinal in 0..<count { _ = f.appendTrack(name: "Peer \(ordinal)", selected: false) }
                let (capture, project, target, _, _) = try await f.coupledCapture(peerStripName: "Aux",
                    extraMixerPeerNames: (1..<count).map { "Aux \($0)" })
                let written = await f.applyCoupled(capture, project: project, target: target)
                #expect(written.status == .applied)
                let proof = try #require(written.inverse)
                f.physicalOwnerDocumentReads = 0
                #expect(await ExactTrackNameAdapter.readOwnedCoupledName(proof) == "C")
                #expect(f.physicalOwnerDocumentReads > 0, "Reach actual original-project owner reads")
                ownerReads.append(f.physicalOwnerDocumentReads)
                #expect(f.writes == ["C"], "An independent name read grants no peer or repeat write")
            }
            #expect(ownerReads[1] == ownerReads[0],
                "Complete original-membership bookends, not a global project rediscovery for each peer: \(ownerReads)")
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
            #expect(healthy.mostPeerReadsBeforeMirror == 1,
                "One fresh peer-name pass before each deciding pair read; do not repeat the complete peer census")
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

    @Test func anUnchangedMirrorAfterTheActualTrackWriteRetainsItsActualNameEffect() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = ExactNameFixture()
            let (capture, project, target, _, _) = try await f.coupledCapture()
            f.onConfirm = nil
            let result = await f.applyCoupled(capture, project: project, target: target)
            #expect(result.status == .applied)
            let inverse = try #require(result.inverse)
            let effect = try #require(ExactTrackNameAdapter.recordedNameEffect(inverse))
            #expect(effect.trackName == "C" && effect.stripName == "A")
            #expect(result.survivingReference == target)
            #expect(sharedJSONObject(sharedToolText(result.result))?["state"] as? String == "A")
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
            // producer/dispatcher/writer path now reaches its deciding filter
            // at legacy role read 13 after redundant single-window discovery is
            // removed. Its healthy selection setter is reached at read 15,
            // after the post-filter permission checks.
            // Fail that deciding filter once, then keep
            // the original unselected A and selected B readable for settle.
            f.legacyHeaderRoleFailureRead = 13
            let (project, target) = try await f.prepare(typedProducer: true)
            let result = await f.rename(project: project, target: target, expected: nil, desired: "C")
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(f.legacyHeaderRoleFailures == 1)
            #expect(f.legacyHeaderRoleReads > 13)
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
            f.legacyHeaderRoleObservedRead = 13
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
                #expect(f.legacyHeaderReadsAtSelection == [15], "the healthy path includes its post-filter typed permission checks")
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
