@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

private actor SendRemovalSagaResultBoundary: Channel {
    nonisolated let id: ChannelID = .accessibility
    let base: AccessibilityChannel
    let journal: SagaJournal
    let mode: String
    let operation: String
    let idempotencyKey: String
    let afterForward: @Sendable () -> Void
    let beforeForward: @Sendable () -> Void
    let observedResult: @Sendable (ChannelResult) -> Void
    init(base: AccessibilityChannel, journal: SagaJournal, mode: String,
         operation: String = "mixer.set_send_output_verified", idempotencyKey: String = "owned-send-removal-saga",
         afterForward: @escaping @Sendable () -> Void = {},
         beforeForward: @escaping @Sendable () -> Void = {},
         observedResult: @escaping @Sendable (ChannelResult) -> Void = { _ in }) {
        self.base = base; self.journal = journal; self.mode = mode; self.afterForward = afterForward
        self.operation = operation; self.idempotencyKey = idempotencyKey
        self.beforeForward = beforeForward
        self.observedResult = observedResult
    }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { await base.healthCheck() }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        if operation == self.operation { beforeForward() }
        if operation == self.operation, mode == "no_observer" {
            return .success(HonestContract.encodeStateA(extras: ["verified": true, "write_attempted": true]))
        }
        let result: ChannelResult
        if operation == self.operation, mode == "lost_observer" {
            if operation == "mixer.set_send_level_verified" {
                result = await AccessibilityChannel.$sendLevelChangeObserver.withValue(nil) {
                    await base.execute(operation: operation, params: params)
                }
            } else if operation == "mixer.set_send_mode_verified" {
                result = await AccessibilityChannel.$sendModeChangeObserver.withValue(nil) {
                    await base.execute(operation: operation, params: params)
                }
            } else {
                result = await AccessibilityChannel.$sendCreationObserver.withValue(nil) {
                    await AccessibilityChannel.$sendChangeObserver.withValue(nil) {
                        await base.execute(operation: operation, params: params)
                    }
                }
            }
        } else { result = await base.execute(operation: operation, params: params) }
        if operation == self.operation { observedResult(result) }
        if operation == self.operation,
           sharedJSONObject(result.message)?["state"] as? String == "A" {
            afterForward()
            if mode == "cancel" { _ = await journal.cancel(idempotencyKey: idempotencyKey) }
            if mode == "failure" || mode.hasPrefix("late_inverse_") {
                return .error(HonestContract.encodeStateC(error: .readbackUnavailable, extras: ["write_attempted": true]))
            }
            if mode == "unverified" {
                return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: ["write_attempted": true]))
            }
        }
        return result
    }
}

/// A failure AFTER the real second writer's verified forward, not a response echo.
private actor SelectedOutputSagaResultBoundary: Channel {
    nonisolated let id: ChannelID = .accessibility
    let base: AccessibilityChannel
    var failed = false
    let shouldFail: Bool
    let observed: @Sendable (ChannelResult) -> Void
    let observedName: @Sendable (ChannelResult) -> Void
    init(_ base: AccessibilityChannel, shouldFail: Bool = true,
         observed: @escaping @Sendable (ChannelResult) -> Void = { _ in },
         observedName: @escaping @Sendable (ChannelResult) -> Void = { _ in }) {
        self.base = base; self.shouldFail = shouldFail; self.observed = observed; self.observedName = observedName
    }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { await base.healthCheck() }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        let result = await base.execute(operation: operation, params: params)
        if operation == "track.rename" { observedName(result) }
        if operation == "mixer.set_output_verified" { observed(result) }
        if shouldFail, operation == "mixer.set_output_verified", !failed,
           sharedJSONObject(result.message)?["state"] as? String == "A" {
            failed = true
            return .error(HonestContract.encodeStateC(error: .readbackUnavailable, extras: ["write_attempted": true]))
        }
        return result
    }
}

@Suite("#965 held selection association", .serialized)
struct Issue965HeldSelectionAssociationTests {
    @Test("One coupled-editor decision reuses its already-held stopped transport",
        arguments: ["held", "fallback", "play", "record", "bad_play", "bad_record", "play_role", "record_role",
                    "replaced_bar", "replaced_record", "competing_bar", "late_competing_bar",
                    "late_focus", "late_document", "late_source", "late_header", "late_header_role", "late_rail_role", "late_mixer", "late_peer",
                    "cancel", "lost", "fresh_values"])
    func coupledEditorGuardDoesNotRediscoverItsHeldTransport(_ fault: String) async throws {
        let f = try Fixture(), gate = LogicMutationGate()
        f.useBulkReads = true
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let claim = try #require(gate.tryAcquire(operation: "coupled-editor-transport"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) },
            cancellationRequested: { fault == "cancel" && f.routingLateScopeInjected })
        try OperationTraceContext.$current.withValue(context) {
            let runtime = f.logic()
            let held = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: runtime, expectedProject: nil, requiresProjectReference: false))
            #expect(held.permitsRead())
            let pair = AccessibilityChannel.HeldSelectionAssociation.Pair(
                track: .init(window: f.window, header: f.headers[0], document: f.bundle.absoluteString, runtime: runtime),
                strip: .init(window: f.window, mixer: f.mixer, strip: f.strips[1], document: f.bundle.absoluteString))
            let editor = f.builder.element(1_971_801)
            f.builder.setRole(editor, kAXTextFieldRole as String)
            f.builder.setAttribute(editor, kAXValueAttribute as String, "Duplicate")
            f.builder.setAttributeSettable(editor, kAXValueAttribute as String, true)
            f.builder.setAttribute(editor, kAXWindowAttribute as String, f.window)
            f.builder.setChildren(editor, [])
            f.builder.setChildren(f.headers[0], [editor])
            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, editor)
            let play = f.builder.element(1_965_721), record = f.builder.element(1_965_722)
            let otherBar = f.builder.element(1_971_802), otherRecord = f.builder.element(1_971_803)
            f.builder.setRole(otherBar, kAXGroupRole as String)
            f.builder.setAttribute(otherBar, kAXDescriptionAttribute as String, "Control Bar")
            f.builder.setRole(otherRecord, kAXCheckBoxRole as String)
            f.builder.setAttribute(otherRecord, kAXTitleAttribute as String, "Record")
            f.builder.setAttribute(otherRecord, kAXValueAttribute as String, NSNumber(value: 0))
            if fault == "play" { f.builder.setAttribute(play, kAXValueAttribute as String, NSNumber(value: 1)) }
            if fault == "bad_play" { f.builder.setAttribute(play, kAXValueAttribute as String, "unknown") }
            if fault == "bad_record" { f.builder.setAttribute(record, kAXValueAttribute as String, NSNumber(value: 0.5)) }
            if fault == "play_role" { f.builder.setRole(play, kAXTextFieldRole as String) }
            if fault == "record_role" { f.builder.setRole(record, kAXTextFieldRole as String) }
            if fault == "competing_bar" {
                f.builder.setChildren(otherBar, [otherRecord])
                f.builder.setChildren(f.window, [f.rail, f.mixer, f.builder.element(1_965_720), otherBar])
            }
            if fault == "lost" { #expect(!held.permitsRead()) }
            f.routingRead = { element, attribute in
                if f.coupledGuardCountDiscovery || f.coupledGuardRecordReads == 0,
                   CFEqual(element, f.builder.element(1_965_720)),
                   attribute == kAXDescriptionAttribute as String { f.coupledGuardBarReads += 1 }
                if attribute == kAXValueAttribute as String {
                    if CFEqual(element, play) {
                        f.coupledGuardPlayReads += 1
                        if fault == "record" { f.builder.setAttribute(record, kAXValueAttribute as String, NSNumber(value: 1)) }
                        if fault == "replaced_record" { f.builder.setChildren(f.builder.element(1_965_720), [play, otherRecord]) }
                        if fault == "replaced_bar" || fault == "late_competing_bar" {
                            f.builder.setChildren(otherBar, [otherRecord])
                            f.builder.setChildren(f.window, fault == "replaced_bar" ? [f.rail, f.mixer, otherBar]
                                : [f.rail, f.mixer, f.builder.element(1_965_720), otherBar])
                        }
                    }
                    if CFEqual(element, record) {
                        f.coupledGuardRecordReads += 1
                        if fault == "late_focus" { f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, otherRecord) }
                        if fault == "late_document" { f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/foreign.logicx") }
                        if fault == "late_source" { f.builder.setChildren(f.mixer, [f.strips[0]]) }
                        if fault == "late_header" { f.builder.setChildren(f.rail, [f.headers[1]]) }
                        if fault == "late_header_role" { f.builder.setRole(f.headers[0], kAXTextFieldRole as String) }
                        if fault == "late_rail_role" { f.builder.setRole(f.rail, kAXTextFieldRole as String) }
                        if fault == "late_mixer" { f.builder.setChildren(f.window, [f.rail, f.builder.element(1_965_720)]) }
                        if fault == "late_peer" { f.builder.setChildren(f.mixer, [otherRecord, f.strips[1]]) }
                        if fault == "cancel" { f.routingLateScopeInjected = true }
                    }
                }
            }
            let bar = AXLogicProElements.getControlBar(in: f.window, runtime: runtime.ax)
            if fault != "competing_bar" {
                let currentBar = try #require(bar)
                #expect(CFEqual(currentBar, held.transport.controlBar))
            }
            let oneDiscoveryReads = f.coupledGuardBarReads
            #expect(oneDiscoveryReads > 0)
            f.coupledGuardBarReads = 0
            f.coupledGuardPopulationScans = 0
            let admitted = ExactTrackNameAdapter.permitsCoupledEditorRead(editor, pair: pair, names: ["Duplicate"],
                transportProof: fault == "fallback" ? nil : held)
            if ["held", "fallback", "fresh_values"].contains(fault) {
                #expect(admitted)
                #expect(f.coupledGuardPlayReads > 0 && f.coupledGuardRecordReads > 0,
                    "Reach both actual deciding values, not an earlier refusal")
                if fault != "fallback" {
                    #expect(f.coupledGuardPopulationScans == 0,
                        "Renew the original complete owned paths/census instead of globally rediscovering a held Mixer")
                    #expect(f.coupledGuardBarReads <= oneDiscoveryReads,
                        "Do not repeat whole Control Bar discovery before deciding Record")
                } else { #expect(f.coupledGuardPopulationScans > 0) }
                if fault == "held" {
                    // The original rail's strict rows are already held. Its
                    // renewal must not rediscover unrelated Control Bar data;
                    // keep the one actual transport uniqueness discovery.
                    f.coupledGuardBarReads = 0
                    f.coupledGuardCountDiscovery = true
                    let playReads = f.coupledGuardPlayReads, recordReads = f.coupledGuardRecordReads
                    #expect(held.permitsCoupledEditorTransportRead(pair: pair))
                    #expect(f.coupledGuardBarReads == oneDiscoveryReads)
                    #expect(f.coupledGuardPopulationScans == 0)
                    #expect(f.coupledGuardPlayReads > playReads && f.coupledGuardRecordReads > recordReads)
                    f.coupledGuardCountDiscovery = false
                }
                if fault == "fresh_values" {
                    let reads = f.coupledGuardRecordReads
                    f.builder.setAttribute(record, kAXValueAttribute as String, NSNumber(value: 1))
                    #expect(!ExactTrackNameAdapter.permitsCoupledEditorRead(editor, pair: pair, names: ["Duplicate"], transportProof: held))
                    #expect(f.coupledGuardRecordReads > reads)
                }
            } else {
                #expect(!admitted)
                if fault.hasPrefix("late_") || ["record", "replaced_bar", "replaced_record", "cancel"].contains(fault) {
                    #expect(f.coupledGuardPlayReads > 0)
                }
            }
        }
        #expect(f.selections.isEmpty && f.focusRestorationWrites.isEmpty)
    }

    @Test("A held input popup may move focus without losing its original complete association",
          arguments: ["unchanged", "unchanged_focus", "popup_no_focused_window", "popup_unchanged_no_focused_window", "ordinary_no_focused_window", "popup_unreadable_window", "popup_foreign_window", "foreign_document", "foreign_focus", "detached_search", "retired_strip", "changed_selection", "playing", "rail", "rail_unchanged", "rail_missing_relationship", "rail_changed_child", "rail_editor", "rail_final_child_drift", "rail_final_focus_drift", "rail_final_rail_editor", "rail_final_rail_insertion"])
    func ownedPopupFocusPreservesOnlyActualHeldCustody(_ fault: String) async throws {
        let f = try Fixture(), gate = LogicMutationGate()
        if fault.hasPrefix("rail") {
            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
            f.builder.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.strips[1]])
        }
        _ = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: ["domains": .array([.string("associations")])], mutationGate: gate) {
            let base = f.builder.makeLogicRuntime(appElement: f.app, attributeValueHandler: { element, attribute in
                if ["rail_final_child_drift", "rail_final_focus_drift", "rail_final_rail_editor", "rail_final_rail_insertion"].contains(fault), f.ownedPopupObservationStarted,
                   CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String {
                    f.passivePermissionFocusReads += 1
                    if f.passivePermissionFocusReads == 2 {
                        if fault == "rail_final_child_drift" {
                            f.routingLateScopeInjected = true
                            f.builder.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.strips[0]])
                        } else { f.passivePermissionArmed = true }
                    }
                }
                if fault == "rail_final_focus_drift", f.passivePermissionArmed,
                   CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String {
                    let foreign = f.builder.element(1_965_983)
                    f.builder.setRole(foreign, kAXTextFieldRole as String)
                    f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, foreign)
                    f.routingLateScopeInjected = true
                }
                if ["rail_final_rail_editor", "rail_final_rail_insertion"].contains(fault), f.passivePermissionArmed,
                   CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String {
                    if fault == "rail_final_rail_editor" { f.builder.setRole(f.rail, kAXTextFieldRole as String) }
                    f.routingLateScopeInjected = true
                }
                return nil
            }, attributeValueResultHandler: { element, attribute in
                if fault.hasPrefix("rail"), CFEqual(element, f.rail), [kAXValueAttribute, kAXSelectedTextAttribute,
                    kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute].map({ $0 as String }).contains(attribute) {
                    if fault == "rail_final_rail_insertion", f.routingLateScopeInjected,
                       attribute == kAXInsertionPointLineNumberAttribute as String { return .success(NSNumber(value: 1)) }
                    return .failure(.init(raw: AXError.noValue.rawValue))
                }
                if fault == "rail_missing_relationship", f.ownedPopupObservationStarted,
                   CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String {
                    return .failure(.init(raw: AXError.noValue.rawValue))
                }
                if f.ownedPopupObservationStarted, CFEqual(element, f.app), attribute == kAXFocusedWindowAttribute as String {
                    if ["popup_no_focused_window", "popup_unchanged_no_focused_window", "ordinary_no_focused_window"].contains(fault) {
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    if fault == "popup_unreadable_window" { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
                }
                if f.strips.contains(where: { CFEqual($0, element) }),
                   attribute == kAXValueAttribute as String || attribute == kAXSelectedTextAttribute as String {
                    return .failure(.init(raw: AXError.noValue.rawValue))
                }
                return nil
            }, setAttributeHandler: nil, performActionHandler: nil)
            let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: base.ax,
                executeAppleScript: { _ in Issue.record("No scripts"); return .error("forbidden") },
                onScreenWindowList: { [] }, focusedApplicationPID: { 4242 })
            guard let association = AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: logic, expectedProject: nil, requiresProjectReference: false,
                allowsSelectedChildRailEntry: fault.hasPrefix("rail")) else {
                Issue.record("Fixture must hold a real association before its popup"); return .init(content: [])
            }
            let root = f.builder.element(1_965_980), search = f.builder.element(1_965_981)
            f.builder.setRole(root, kAXMenuRole as String)
            f.builder.setRole(search, kAXTextFieldRole as String)
            f.builder.setChildren(search, []); f.builder.setChildren(root, [search])
            f.builder.setChildren(f.mixer, f.strips + [root])
            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, search)
            f.ownedPopupObservationStarted = true
            switch fault {
            case "rail_unchanged", "rail_final_rail_editor", "rail_final_rail_insertion":
                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, association.originalFocus)
            case "unchanged_focus", "popup_unchanged_no_focused_window", "ordinary_no_focused_window":
                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, association.originalFocus)
                f.builder.setAttribute(association.originalFocus, kAXInsertionPointLineNumberAttribute as String, 0)
                #expect(AccessibilityChannel.readLogicKeyboardFocus(runtime: logic) != .notTextEditing,
                    "The existing full passive-strip witness, not a global focus exemption, must qualify this native-shaped control")
            case "foreign_document": f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
            case "popup_foreign_window": f.builder.setAttribute(f.app, kAXFocusedWindowAttribute as String, f.builder.element(1_965_982))
            case "foreign_focus": f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.headers[0])
            case "detached_search": f.builder.setChildren(root, [])
            case "retired_strip": f.builder.setChildren(f.mixer, [f.strips[1], root])
            case "changed_selection":
                f.builder.setAttribute(f.headers[0], kAXSelectedAttribute as String, false)
                f.builder.setAttribute(f.headers[1], kAXSelectedAttribute as String, true)
            case "playing": f.builder.setAttribute(f.builder.element(1_965_721), kAXValueAttribute as String, 1)
            case "rail_changed_child": f.builder.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.strips[0]])
            case "rail_editor": f.builder.setRole(f.rail, kAXTextFieldRole as String)
            default: break
            }
            let permitted = fault == "ordinary_no_focused_window" ? association.permitsRead() : association.permitsOwnedPopupRead(root)
            if ["unchanged", "unchanged_focus", "popup_no_focused_window", "popup_unchanged_no_focused_window", "rail", "rail_unchanged"].contains(fault) { #expect(permitted) } else { #expect(!permitted) }
            #expect(f.builder.actionCalls.isEmpty)
            if fault == "rail_final_child_drift" {
                #expect(f.routingLateScopeInjected, "Reach the deciding popup-focus read before refusing the changed original child")
            }
            if fault == "rail_final_focus_drift" {
                #expect(f.routingLateScopeInjected, "Move focus during the final child read without changing the original child or header")
            }
            if ["rail_final_rail_editor", "rail_final_rail_insertion"].contains(fault) {
                #expect(f.routingLateScopeInjected, "Change passive rail metadata during the final child read while retaining its CF focus identity")
            }
            return .init(content: [])
        }
    }
    @Test func publicDescriptionDistinguishesPhysicalPairsFromWholePopulation() {
        let description = ProjectDispatcher.tool.description ?? ""
        #expect(description.contains("held exclusive selection"), "Describe the implemented physical observation, not name/index joins")
        #expect(description.contains("partial association pairs"), "A bounded pair witness is not complete population coverage")
        #expect(!description.contains("actual track-to-strip associations remain unimplemented"), "The registered producer already publishes verified physical pairs")
        #expect(description.contains("complete population remain unqualified"), "Do not turn a capability-description correction into a native/global acceptance claim")
    }

    @Test(arguments: ["unchanged", "editor", "foreign_document", "foreign_window", "retired_focus", "playing", "changed_selection", "deciding_focus_window", "deciding_focus_document", "transport_on_strip_census"])
    func passiveHelpPermissionDoesNotReacquireAssociationAuthority(condition: String) async throws {
        let f = try Fixture()
        let gate = LogicMutationGate()
        _ = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: ["domains": .array([.string("associations")])], mutationGate: gate) {
            let base = f.builder.makeLogicRuntime(appElement: f.app, attributeValueHandler: { element, attribute in
                if f.headers.contains(where: { CFEqual($0, element) }), attribute == kAXSelectedAttribute as String {
                    f.passivePermissionSelectionReads += 1
                }
                if f.passivePermissionArmed, CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String {
                    f.passivePermissionFocusReads += 1
                    if f.passivePermissionFocusReads == 2 {
                        if condition == "deciding_focus_window" {
                            let foreign = f.builder.element(1_965_799)
                            f.builder.setAttribute(f.app, kAXMainWindowAttribute as String, foreign)
                            f.builder.setAttribute(f.app, kAXFocusedWindowAttribute as String, foreign)
                        } else if condition == "deciding_focus_document" {
                            f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        }
                    }
                }
                if f.passivePermissionArmed, condition == "transport_on_strip_census",
                   CFEqual(element, f.strips[0]), attribute == kAXRoleAttribute as String {
                    f.builder.setAttribute(f.builder.element(1_965_721), kAXValueAttribute as String, 1)
                }
                return nil
            }, attributeValueResultHandler: { element, attribute in
                if f.strips.contains(where: { CFEqual($0, element) }),
                   attribute == kAXValueAttribute as String || attribute == kAXSelectedTextAttribute as String {
                    return .failure(.init(raw: AXError.noValue.rawValue))
                }
                return nil
            }, setAttributeHandler: nil, performActionHandler: nil)
            let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: base.ax,
                executeAppleScript: { _ in Issue.record("No scripts"); return .error("forbidden") },
                onScreenWindowList: { [] }, focusedApplicationPID: { 4242 })
            guard let association = AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: logic, expectedProject: nil, requiresProjectReference: false) else {
                Issue.record("Expected a qualified original association")
                return .init(content: [])
            }
            let scope = AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope()
            scope.retainAssociation(association)
            f.passivePermissionSelectionReads = 0
            f.passivePermissionArmed = true
            switch condition {
            case "editor": f.builder.setAttribute(f.strips[1], kAXNumberOfCharactersAttribute as String, 1)
            case "foreign_document": f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
            case "foreign_window": f.builder.setAttribute(f.app, kAXFocusedWindowAttribute as String, f.builder.element(1_965_799))
            case "retired_focus": f.builder.setChildren(f.mixer, [f.strips[0]])
            case "playing": f.builder.setAttribute(f.builder.element(1_965_721), kAXValueAttribute as String, 1)
            case "changed_selection":
                f.builder.setAttribute(f.headers[0], kAXSelectedAttribute as String, false)
                f.builder.setAttribute(f.headers[1], kAXSelectedAttribute as String, true)
            default: break
            }
            let permitted = scope.permits()
            if condition == "unchanged" || condition == "changed_selection" || condition == "transport_on_strip_census" {
                #expect(permitted)
            } else {
                #expect(!permitted)
            }
            #expect(f.passivePermissionSelectionReads == 0, "Passive Help permission must not scan selection twice; action and publication boundaries retain the full association proof")
            #expect(f.selections.isEmpty && f.scrollWrites.isEmpty)
            if condition == "changed_selection" {
                #expect(!association.permitsRead(), "The read-only focus witness cannot authorize association actions")
            } else if condition == "transport_on_strip_census" {
                #expect(!association.permitsRead(), "Full association census must precede its deciding stopped-transport checks")
            }
            return .init(content: [])
        }
    }

    private final class Fixture: @unchecked Sendable {
        let builder = FakeAXRuntimeBuilder()
        let app: AXUIElement
        let window: AXUIElement
        let rail: AXUIElement
        let mixer: AXUIElement
        let headers: [AXUIElement]
        let strips: [AXUIElement]
        let scroll: AXUIElement
        let bundle: URL
        var selections: [Int] = []
        var focusRestorationWrites: [AXUIElement] = []
        var cleanupTransportReads = 0
        var cleanupTransportReadsAtWrite = 0
        var cleanupScopeInjected = false
        var focusRestorationAckOnly = false
        var wholeHeaderSelectionReads = 0
        var ownedPopupObservationStarted = false
        var scrollWrites: [Double] = []
        var viewportReadsAfterSelection = 0
        var selectedRelationshipReads = 0
        var inverseValueReadCount = 0
        var viewportFaultAtRead: Int?
        var viewportFaultInjected = false
        var referenceCurrent = true
        var useBulkReads = false
        var batchReadCalls = 0
        var reciprocalPathBatchCalls = 0
        var pathBatchFault: String?
        var windowScopeBatchCalls = 0
        var windowScopeBatchFault: String?
        var windowCustodyBatchCalls = 0
        var windowCustodySingleReads = 0
        var windowCustodyFault: String?
        var activeBulkAttributes: [String]?
        var fault: String?
        var transientEditorRead = false
        var transientForeignRead = false
        var delayedOwnFocusRead = false
        var metadataReads = 0
        var focusReadsBeforeWrite = [0, 0]
        var scopeLossPhase: Int?
        var scopeLossRead: Int?
        var scopeLossInjected = false
        var loseNextSelectionRead = false
        var postRestoreSelectionFaults = 0
        var volatileSlider: AXUIElement?
        var transientZoomRoleObserved = false
        var zoomRoleReadsAfterSelection = 0
        var zoomRoleReadsAtFirstValue: Int?
        var zoomRoleFaultAtRead: Int?
        var routingReplacement: AXUIElement?
        var routingOtherReplacement: AXUIElement?
        var routingAction: (@Sendable (AXUIElement, String) -> Bool)?
        var routingSetter: (@Sendable (AXUIElement, String, CFTypeRef) -> Bool?)?
        var routingMenuRename = false
        var routingNameReturn: (@Sendable () -> Bool)?
        var routingFocusMouse: AXMouseHelper.Runtime?
        var routingFocusHit: (@Sendable (AXUIElement, CGPoint) -> Result<AXUIElement?, AXHelpers.AXStatusError>)?
        var routingFocusClickEvents: [CGEventType] = []
        var routingFocusClickFault: String?
        var routingFocusHitReads = 0
        var routingOutputChannelStates: [String] = []
        var routingNameChannelStates: [String] = []
        var routingMenuNameOpens = 0
        var routingNameWrites: [String] = []
        var routingNameConfirms = 0
        var routingDocumentReads = 0
        var routingDocumentReadsAtFirstNameWrite: Int?
        var routingDocumentReadsAtFirstNameConfirm: Int?
        var routingDestinationPresses = 0
        var routingModePresses = 0
        var routingBypassPresses = 0
        var routingBypassMenuOpens = 0
        var routingBypassMenuCancels = 0
        var routingBypassFinalValueReads = 0
        var routingBypassFinalCapabilityRead = false
        var routingBypassPendingValue: Bool?
        var routingActionNames: (@Sendable (AXUIElement) -> Result<[String], AXHelpers.AXStatusError>?)?
        var routingLevelMouse: AXMouseHelper.Runtime?
        var routingLevelHit: AXUIElement?
        var routingLevelHitEffect: (@Sendable () -> Void)?
        var routingLevelClicks: [Int64] = []
        var routingLevelPairExpired = false
        var creationForwardReceipt: String?
        var routingLevelWrites: [String] = []
        var routingLevelCommits = 0
        var routingLevelCommitPending = false
        var routingLevelCancelled = false
        var routingLevelWaits = 0
        var routingLevelPendingFieldReads = 0
        var routingLevelReturnTransitions = 0
        var routingLevelTransientSourceLost = false
        var routingLevelTransientGateLost = false
        var routingChildrenRead: (@Sendable (AXUIElement) -> Void)?
        var routingLegacyChildrenRead: (@Sendable (AXUIElement) -> Void)?
        var routingRemovalPublications = 0
        var routingRemovedSend: AccessibilityChannel.RemovedSendObservation?
        var routingRemovalPermittedAtPublication: Bool?
        var routingIndependentSendReads = 0
        var routingOpenedOutputIndex: Int?
        var routingScalarControls: [AXUIElement] = []
        var routingClassifierHelpReads = 0
        var routingClassifierControls: [AXUIElement] = []
        var routingWrongSourcePressed = false
        var expireRetainedCapture = false
        var coupledGuardBarReads = 0
        var coupledGuardPopulationScans = 0
        var coupledGuardPlayReads = 0
        var coupledGuardRecordReads = 0
        var coupledGuardCountDiscovery = false
        var measuringFootprintReads = false
        // Retain the actual request-local guards so object IDs cannot be reused
        // between separate footprint reads. These are test observations only.
        var footprintReads: [ObjectIdentifier: (guardOwner: AXHelpers.HelpReadGuard,
            record: Int, help: Int, names: Set<Int>, firstDocument: Int?)] = [:]
        var footprintDocumentReads = 0
        var footprintDocumentFaultAt: Int?
        var footprintDocumentFault = "foreign"
        var footprintDocumentInjected = false
        var footprintDocumentRestored = false
        var routingRead: (@Sendable (AXUIElement, String) -> Void)?
        var routingReadResult: (@Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError>?)?
        var routingSelection: (@Sendable (Int) -> Void)?
        var sharedThirdStrip = false
        var thirdSharesOriginalStrip = false
        var thirdRetainsPreviousFocus = false
        var selectedChildrenReads = 0
        var selectedChildrenReadsAtWrite = 0
        var associationStopReads = 0
        var associationStopReadsAtWrite = 0
        var routingLateScopeInjected = false
        var routingModeInspectionReads = 0
        var lateAssociationFocusSampled = false
        var lateAssociationFocusLanded = false
        var inputMenuPresses = 0
        var inputMenuCancels = 0
        var renewedOutputPresses = 0
        var renewedOutputCancels = 0
        var inputRetirementCensusLag = false
        var inputRetiredSourceReadable = false
        var inputRetirementCensusLagObserved = false
        var inputMenuHadOwnedClaim = false
        var inputPreviousReadWasDescription = false
        var presentationCensusReads = 0
        var passivePermissionSelectionReads = 0
        var passivePermissionFocusReads = 0
        var passivePermissionArmed = false

        func installLaterOutputProbe(original: AXUIElement, renewed: AXUIElement) {
            let oldOutput = builder.element(1_965_990), renewedOutput = builder.element(1_965_991)
            let root = builder.element(1_965_992), parent = builder.element(1_965_993)
            let menu = builder.element(1_965_994), echo = builder.element(1_965_995), leaf = builder.element(1_965_996)
            for control in [oldOutput, renewedOutput] {
                builder.setButton(control, description: "Stereo Output",
                    help: "Output slot. Choose the channel strip output destination.", x: 0, y: 0, width: 1, height: 1)
                builder.setChildren(control, []); builder.setActionNames(control, [kAXPressAction as String])
            }
            builder.setChildren(original, builder.makeAXRuntime().children(original) + [oldOutput])
            builder.setChildren(renewed, builder.makeAXRuntime().children(renewed) + [renewedOutput])
            for item in [root, menu] { builder.setRole(item, kAXMenuRole as String) }
            for (item, title) in [(echo, "Stereo Output"), (parent, "Output"), (leaf, "Stereo Output")] {
                builder.setRole(item, kAXMenuItemRole as String)
                builder.setAttribute(item, kAXTitleAttribute as String, title)
                builder.setChildren(item, [])
            }
            for item in [echo, leaf] { builder.setAttribute(item, "AXMenuItemMarkChar", "✓") }
            builder.setChildren(menu, [leaf]); builder.setChildren(parent, [menu])
            builder.setChildren(root, [echo, parent]); builder.setActionNames(root, [kAXCancelAction as String])
            let inputAction = routingAction
            routingAction = { [self] element, action in
                if CFEqual(element, builder.element(1_965_991)), action == kAXPressAction as String {
                    guard let current = routingReplacement else {
                        Issue.record("Read the actual replacement only after owned input renewal")
                        return false
                    }
                    renewedOutputPresses += 1
                    builder.setChildren(mixer, [strips[0], current, builder.element(1_965_992)])
                    return true
                }
                if CFEqual(element, builder.element(1_965_992)), action == kAXCancelAction as String,
                   let current = routingReplacement {
                    renewedOutputCancels += 1
                    builder.setChildren(mixer, [strips[0], current])
                    return true
                }
                if CFEqual(element, builder.element(1_965_990)) {
                    Issue.record("The retired output control must never be used")
                    return false
                }
                return inputAction?(element, action) ?? false
            }
        }

        init(withViewport: Bool = false, fourTracks: Bool = false) throws {
            bundle = FileManager.default.temporaryDirectory.appendingPathComponent("965-selection-\(UUID().uuidString).logicx")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
            app = builder.element(1_965_700)
            window = builder.element(1_965_701)
            rail = builder.element(1_965_702)
            mixer = builder.element(1_965_703)
            headers = [builder.element(1_965_704), builder.element(1_965_705)]
                + (fourTracks ? [builder.element(1_965_760), builder.element(1_965_761)] : [])
            strips = [builder.element(1_965_706), builder.element(1_965_707)]
                + (fourTracks ? [builder.element(1_965_770), builder.element(1_965_771)] : [])
            scroll = builder.element(1_965_708)
            builder.setRole(window, kAXWindowRole as String)
            builder.setAttribute(window, kAXTitleAttribute as String, "Selection fixture - Tracks")
            builder.setAttribute(window, kAXDocumentAttribute as String, bundle.absoluteString)
            builder.setAttribute(app, kAXWindowsAttribute as String, [window])
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setAttribute(app, kAXFocusedWindowAttribute as String, window)
            builder.setAttribute(app, kAXFrontmostAttribute as String, true)
            builder.setAttribute(app, kAXFocusedUIElementAttribute as String, strips[1])
            builder.setRole(rail, kAXListRole as String)
            builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
            builder.setAttributeSettable(rail, kAXSelectedChildrenAttribute as String, true)
            builder.setRole(mixer, kAXGroupRole as String)
            builder.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
            for (index, header) in headers.enumerated() {
                builder.setRole(header, kAXLayoutItemRole as String)
                builder.setAttribute(header, kAXTitleAttribute as String, "Duplicate")
                builder.setAttribute(header, kAXSelectedAttribute as String, index == 0)
                builder.setChildren(header, [])
            }
            for (index, strip) in strips.enumerated() {
                builder.setRole(strip, kAXLayoutItemRole as String)
                builder.setAttribute(strip, kAXNumberOfCharactersAttribute as String, 0)
                builder.setAttribute(strip, kAXInsertionPointLineNumberAttribute as String, 0)
                let name = builder.element(1_965_710 + index)
                builder.setRole(name, kAXTextFieldRole as String)
                builder.setAttribute(name, kAXDescriptionAttribute as String, "Name")
                builder.setAttribute(name, kAXValueAttribute as String, "Duplicate")
                builder.setChildren(strip, [name])
            }
            builder.setChildren(rail, headers)
            builder.setChildren(mixer, strips)
            let bar = builder.element(1_965_720)
            let play = builder.element(1_965_721)
            let record = builder.element(1_965_722)
            builder.setRole(bar, kAXGroupRole as String)
            builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
            for (control, title) in [(play, "Play"), (record, "Record")] {
                builder.setRole(control, kAXCheckBoxRole as String)
                builder.setAttribute(control, kAXTitleAttribute as String, title)
                builder.setAttribute(control, kAXValueAttribute as String, 0)
                builder.setChildren(control, [])
            }
            builder.setChildren(bar, [play, record])
            builder.setRole(scroll, kAXScrollBarRole as String)
            builder.setAttribute(scroll, kAXValueAttribute as String, NSNumber(value: 0.8))
            builder.setAttributeSettable(scroll, kAXValueAttribute as String, true)
            builder.setChildren(scroll, [])
            builder.setChildren(window, [rail, mixer, bar] + (withViewport ? [scroll] : []))
        }

        deinit { try? FileManager.default.removeItem(at: bundle) }

        func logic() -> AXLogicProElements.Runtime {
            let base = builder.makeLogicRuntime(appElement: app,
                attributeValueHandler: { [self] element, attribute in
                    if CFEqual(element, app), [kAXMainWindowAttribute as String, kAXFocusedWindowAttribute as String].contains(attribute) {
                        if activeBulkAttributes == nil { windowCustodySingleReads += 1 }
                        if activeBulkAttributes == nil || activeBulkAttributes == [kAXMainWindowAttribute as String, kAXFocusedWindowAttribute as String] {
                            if windowCustodyFault == "absent" { return .some(nil) }
                            if windowCustodyFault == "main_type", attribute == kAXMainWindowAttribute as String { return .some(NSNumber(value: 0)) }
                            if windowCustodyFault == "focused_type", attribute == kAXFocusedWindowAttribute as String { return .some(NSNumber(value: 0)) }
                            if windowCustodyFault == "foreign_main", attribute == kAXMainWindowAttribute as String { return .some(builder.element(1_965_999)) }
                            if windowCustodyFault == "foreign_focused", attribute == kAXFocusedWindowAttribute as String { return .some(builder.element(1_965_999)) }
                            if windowCustodyFault == "late_document", attribute == kAXFocusedWindowAttribute as String {
                                builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            }
                        }
                    }
                    if CFEqual(element, window), attribute == kAXHelpAttribute as String { presentationCensusReads += 1 }
                    if measuringFootprintReads, !routingNameWrites.isEmpty,
                       let guardian = AXHelpers.HelpReadGuard.current {
                        let key = ObjectIdentifier(guardian)
                        var sample = footprintReads[key] ?? (guardian, 0, 0, [], nil)
                        if CFEqual(element, window), attribute == kAXDocumentAttribute as String {
                            footprintDocumentReads += 1
                            sample.firstDocument = sample.firstDocument ?? footprintDocumentReads
                            if footprintDocumentReads == footprintDocumentFaultAt {
                                footprintDocumentInjected = true
                                switch footprintDocumentFault {
                                case "foreign": builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                                case "missing": builder.removeAttribute(window, kAXDocumentAttribute as String)
                                case "malformed": builder.setAttribute(window, kAXDocumentAttribute as String, NSNumber(value: 7))
                                default: Issue.record("Unknown footprint document fault")
                                }
                            }
                        }
                        if footprintDocumentInjected, !footprintDocumentRestored,
                           CFEqual(element, builder.element(1_971_400)), attribute == kAXDescriptionAttribute as String {
                            // The foreign/unknown scope survives until extraction
                            // actually starts; the old first-row full check sees it.
                            builder.setAttribute(window, kAXDocumentAttribute as String, bundle.absoluteString)
                            footprintDocumentRestored = true
                        }
                        if attribute == kAXHelpAttribute as String { sample.help += 1 }
                        if attribute == kAXValueAttribute as String {
                            if CFEqual(element, builder.element(1_965_722)) { sample.record += 1 }
                            for index in strips.indices where CFEqual(element, builder.element(1_965_710 + index)) {
                                sample.names.insert(index)
                            }
                        }
                        footprintReads[key] = sample
                    }
                    routingRead?(element, attribute)
                    if routingScalarControls.contains(where: { CFEqual($0, element) }),
                       [kAXValueAttribute as String, kAXMinValueAttribute as String, kAXMaxValueAttribute as String].contains(attribute) {
                        return .some(builder.attributeValue(element, attribute) as AnyObject?)
                    }
                    if CFEqual(element, scroll), selections.count == 1 {
                        if attribute == kAXRoleAttribute as String {
                            zoomRoleReadsAfterSelection += 1
                            if zoomRoleReadsAfterSelection == zoomRoleFaultAtRead {
                                transientZoomRoleObserved = true
                                return .some(kAXTextFieldRole as NSString)
                            }
                        }
                        if attribute == kAXValueAttribute as String, zoomRoleReadsAtFirstValue == nil {
                            zoomRoleReadsAtFirstValue = zoomRoleReadsAfterSelection
                        }
                    }
                    if CFEqual(element, scroll), attribute == kAXValueAttribute as String, selections.count == 2 {
                        viewportReadsAfterSelection += 1
                        if viewportFaultAtRead == viewportReadsAfterSelection {
                            viewportFaultInjected = true
                            if fault == "scroll_document" { builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx") }
                            if fault == "scroll_focus" { builder.setAttribute(app, kAXFocusedUIElementAttribute as String, builder.element(1_965_730)) }
                            if fault == "scroll_playback" { builder.setAttribute(builder.element(1_965_721), kAXValueAttribute as String, 1) }
                            if fault == "scroll_cancel" { withUnsafeCurrentTask { $0?.cancel() } }
                            if fault == "scroll_reference" { referenceCurrent = false }
                            if fault == "scroll_replacement" {
                                let replacement = builder.element(1_965_741)
                                builder.setRole(replacement, kAXScrollBarRole as String)
                                builder.setAttribute(replacement, kAXValueAttribute as String, NSNumber(value: 0.1))
                                builder.setChildren(replacement, [])
                                builder.setChildren(window, [rail, mixer, builder.element(1_965_720), replacement])
                            }
                            if fault == "scroll_newer" {
                                builder.setAttribute(scroll, attribute, NSNumber(value: 0.6))
                                return .some(NSNumber(value: 0.6))
                            }
                        }
                    }
                    if fault == "post_restore_selection_missing" || fault == "post_restore_selection_malformed",
                       selections == [1, 0], CFEqual(element, headers[1]) {
                        if attribute == kAXTitleAttribute as String { loseNextSelectionRead = true }
                        if attribute == kAXSelectedAttribute as String, loseNextSelectionRead {
                            loseNextSelectionRead = false
                            postRestoreSelectionFaults += 1
                            return fault == "post_restore_selection_missing" ? .some(nil) : .some(NSNumber(value: 2))
                        }
                    }
                    if CFEqual(element, app), attribute == kAXFocusedUIElementAttribute as String,
                       selections.count < 2 {
                        focusReadsBeforeWrite[selections.count] += 1
                        if scopeLossPhase == selections.count, scopeLossRead == focusReadsBeforeWrite[selections.count] {
                            scopeLossInjected = true
                            if fault == "final_focus_document" {
                                builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            } else if fault == "final_focus_window" {
                                let foreign = builder.element(1_965_740)
                                builder.setAttribute(app, kAXMainWindowAttribute as String, foreign)
                                builder.setAttribute(app, kAXFocusedWindowAttribute as String, foreign)
                            }
                            // Still return the expected held focus. Its deciding
                            // read changed scope after the prior scope validation.
                        }
                    }
                    if fault == "delayed_own_focus", selections.count == 1,
                       CFEqual(element, app), attribute == kAXFocusedUIElementAttribute as String, !delayedOwnFocusRead {
                        delayedOwnFocusRead = true
                        return .some(strips[1])
                    }
                    if fault == "transient_foreign_focus", selections.count == 1,
                       CFEqual(element, app), attribute == kAXFocusedUIElementAttribute as String, !transientForeignRead {
                        transientForeignRead = true
                        return .some(builder.element(1_965_730))
                    }
                    return nil
                }, attributeValueResultHandler: { [self] element, attribute in
                    if let result = routingReadResult?(element, attribute) { return result }
                    if fault == "selected_child_unreadable", CFEqual(element, mixer),
                       attribute == kAXSelectedChildrenAttribute as String {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    if routingOtherReplacement != nil, CFEqual(element, strips[0]) {
                        return .failure(.init(raw: AXError.invalidUIElement.rawValue))
                    }
                    if routingReplacement != nil, !inputRetiredSourceReadable, CFEqual(element, strips[1]) {
                        return .failure(.init(raw: AXError.invalidUIElement.rawValue))
                    }
                    if let volatileSlider, CFEqual(element, volatileSlider), !selections.isEmpty,
                       attribute == kAXDescriptionAttribute as String {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    let isReplacement = routingReplacement.map { CFEqual($0, element) } == true
                        || routingOtherReplacement.map { CFEqual($0, element) } == true
                    if strips.contains(where: { CFEqual($0, element) }) || isReplacement,
                       attribute == kAXValueAttribute as String || attribute == kAXSelectedTextAttribute as String {
                        if fault == "transient_editor", selections.count == 1,
                           CFEqual(element, strips[0]), attribute == kAXValueAttribute as String, !transientEditorRead {
                            transientEditorRead = true
                            return .success("Editing" as NSString)
                        }
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    return nil
                },
                childrenHandler: { [self] element in
                    routingLegacyChildrenRead?(element)
                    return nil
                }, childrenResultHandler: { [self] element in
                    routingChildrenRead?(element)
                    guard inputRetirementCensusLag, CFEqual(element, mixer) else { return nil }
                    inputRetirementCensusLag = false
                    inputRetirementCensusLagObserved = true
                    return .success(strips)
                },
                setAttributeHandler: { [self] element, attribute, value in
                    if let handled = routingSetter?(element, attribute, value) { return handled }
                    if strips.contains(where: { CFEqual($0, element) }), attribute == kAXFocusedAttribute as String {
                        cleanupTransportReadsAtWrite = cleanupTransportReads
                        focusRestorationWrites.append(element)
                        if focusRestorationAckOnly { return true }
                        builder.setAttribute(app, kAXFocusedUIElementAttribute as String, element)
                        return true
                    }
                    if CFEqual(element, scroll), attribute == kAXValueAttribute as String,
                       let number = value as? NSNumber {
                        scrollWrites.append(number.doubleValue)
                        inverseValueReadCount = viewportReadsAfterSelection
                        if fault == "scroll_no_effect" { return true }
                        builder.setAttribute(scroll, attribute, number)
                        return true
                    }
                    guard CFEqual(element, rail), attribute == kAXSelectedChildrenAttribute as String,
                          let chosen = value as? [AXUIElement], chosen.count == 1,
                          let index = headers.firstIndex(where: { CFEqual($0, chosen[0]) }) else {
                        Issue.record("only exact held rail selection is authorized"); return false
                    }
                    selections.append(index)
                    let previousFocus = builder.attributeValue(app, kAXFocusedUIElementAttribute as String)
                    routingSelection?(index)
                    if fault == "no_op" { return true }
                    for (row, header) in headers.enumerated() {
                        builder.setAttribute(header, kAXSelectedAttribute as String, row == index)
                    }
                    if fault == "coupled_stack", index == 0 {
                        builder.setAttribute(headers[1], kAXSelectedAttribute as String, true)
                    }
                    // The actual physical relationship is deliberately not positional.
                    builder.setAttribute(app, kAXFocusedUIElementAttribute as String,
                        index == 0 ? routingReplacement ?? strips[1]
                            : index == 1 ? routingOtherReplacement ?? strips[0]
                                : strips[index == 2 ? (thirdSharesOriginalStrip ? 1 : sharedThirdStrip ? 0 : 3) : 2])
                    if index == 2, thirdRetainsPreviousFocus, let previousFocus {
                        builder.setAttribute(app, kAXFocusedUIElementAttribute as String, previousFocus)
                    }
                    if index == 0, fault == "restore_retains_held_focus", let previousFocus {
                        builder.setAttribute(app, kAXFocusedUIElementAttribute as String, previousFocus)
                    }
                    if fault == "selection_scroll" || fault?.hasPrefix("scroll_") == true {
                        // Native R11: restoring the selected header/focused strip did
                        // not restore the Tracks scrollbar's original value.
                        builder.setAttribute(scroll, kAXValueAttribute as String, NSNumber(value: 0.1))
                    }
                    if selections.count == 1 {
                        if fault == "foreign_focus" { builder.setAttribute(app, kAXFocusedUIElementAttribute as String, builder.element(1_965_730)) }
                        if fault == "unchanged_focus" { builder.setAttribute(app, kAXFocusedUIElementAttribute as String, strips[1]) }
                        if fault == "document" { builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx") }
                        if fault == "header_replacement" {
                            let replacement = builder.element(1_965_731)
                            builder.setRole(replacement, kAXLayoutItemRole as String)
                            builder.setAttribute(replacement, kAXTitleAttribute as String, "Duplicate")
                            builder.setAttribute(replacement, kAXSelectedAttribute as String, true)
                            builder.setChildren(replacement, [])
                            builder.setChildren(rail, [headers[0], replacement])
                        }
                        if fault == "strip_replacement" {
                            let replacement = builder.element(1_965_732)
                            builder.setRole(replacement, kAXLayoutItemRole as String)
                            builder.setChildren(replacement, [])
                            builder.setChildren(mixer, [replacement, strips[1]])
                        }
                        if fault == "playback" { builder.setAttribute(builder.element(1_965_721), kAXValueAttribute as String, 1) }
                        if fault == "header_name" { builder.setAttribute(headers[index], kAXTitleAttribute as String, "Changed during selection") }
                        if fault == "strip_name", let name = builder.makeAXRuntime().children(strips[1 - index]).first {
                            builder.setAttribute(name, kAXValueAttribute as String, "Changed during selection")
                        }
                    }
                    if selections.count == 2, fault == "restore_foreign_focus" {
                        builder.setAttribute(app, kAXFocusedUIElementAttribute as String, builder.element(1_965_730))
                    }
                    return true
                }, performActionHandler: { [self] element, action in
                    if let routingAction { return routingAction(element, action) }
                    Issue.record("no action fallback"); return false
                },
                executeAppleScript: { _ in Issue.record("no scripts"); return .error("forbidden") })
            let ax: AXHelpers.Runtime
            if useBulkReads {
                let levelHit: (@Sendable (AXUIElement, CGPoint) -> Result<AXUIElement?, AXHelpers.AXStatusError>)?
                if routingLevelMouse != nil {
                    levelHit = { [self] _, _ in routingLevelHitEffect?(); return .success(routingLevelHit) }
                } else { levelHit = base.ax.elementAtPosition }
                ax = AXHelpers.Runtime(axApp: base.ax.axApp, attributeValue: base.ax.attributeValue,
                    attributeIsSettable: base.ax.attributeIsSettable, setAttributeValue: base.ax.setAttributeValue,
                    children: base.ax.children, performAction: base.ax.performAction, childCount: base.ax.childCount,
                    actionNames: base.ax.actionNames, actionNamesResult: { [self] element in
                        routingActionNames?(element) ?? AXHelpers.getActionNamesResult(element, runtime: base.ax)
                    },
                    childrenResult: base.ax.childrenResult, attributeValueResult: base.ax.attributeValueResult,
                    performActionResult: base.ax.performActionResult,
                    elementAtPosition: levelHit,
                    attributeValuesResult: { [self] element, attributes in
                        batchReadCalls += 1
                        if CFEqual(element, window), attributes == [kAXRoleAttribute, kAXIdentifierAttribute,
                            kAXDescriptionAttribute, kAXTitleAttribute, kAXChildrenAttribute] as [String] {
                            coupledGuardPopulationScans += 1
                        }
                        activeBulkAttributes = attributes
                        defer { activeBulkAttributes = nil }
                        if CFEqual(element, app), attributes == [kAXMainWindowAttribute as String, kAXFocusedWindowAttribute as String] {
                            windowCustodyBatchCalls += 1
                            if windowCustodyFault == "failure" { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
                            if windowCustodyFault == "short" { return .success([window]) }
                        }
                        let scopeBatch = CFEqual(element, window)
                            && attributes == [kAXTitleAttribute as String, kAXDocumentAttribute as String]
                        if scopeBatch {
                            windowScopeBatchCalls += 1
                            switch windowScopeBatchFault {
                            case "failure": return .failure(.init(raw: AXError.cannotComplete.rawValue))
                            case "short": return .success(["Selection fixture - Tracks" as NSString])
                            case "title_type": return .success([NSNumber(value: 0), bundle.absoluteString as NSString])
                            case "document_type": return .success(["Selection fixture - Tracks" as NSString, NSNumber(value: 0)])
                            case "foreign_title": return .success(["Foreign - Tracks" as NSString, bundle.absoluteString as NSString])
                            case "foreign_document": return .success(["Selection fixture - Tracks" as NSString, "file:///tmp/Foreign.logicx" as NSString])
                            default: break
                            }
                        }
                        if attributes == [kAXChildrenAttribute as String, kAXParentAttribute as String] {
                            reciprocalPathBatchCalls += 1
                            if CFEqual(element, builder.element(1_965_720)), let pathBatchFault {
                                if pathBatchFault == "unreadable" { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
                                if pathBatchFault == "malformed_children" { return .success(["not children" as NSString, window]) }
                                if pathBatchFault == "foreign_children" { return .success([[] as CFArray, window]) }
                                if pathBatchFault == "malformed_parent" { return .success([[builder.element(1_965_721), builder.element(1_965_722)] as CFArray, "not parent" as NSString]) }
                            }
                        }
                        var values: [AnyObject] = []
                        for attribute in attributes {
                            let reading: Result<AnyObject?, AXHelpers.AXStatusError>
                            if attribute == kAXChildrenAttribute as String {
                                reading = AXHelpers.childrenResult(element, runtime: base.ax).map { $0 as CFArray }
                            } else {
                                reading = AXHelpers.getAttributeResult(element, attribute, runtime: base.ax)
                            }
                            switch reading {
                            case .success(let value): values.append(value ?? NSNull())
                            case .failure(let error):
                                var nativeError = AXError(rawValue: error.raw) ?? .cannotComplete
                                guard let wrapped = AXValueCreate(.axError, &nativeError) else { return .failure(error) }
                                values.append(wrapped)
                            }
                        }
                        if scopeBatch, windowScopeBatchFault == "document_after_batch" {
                            builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        }
                        return .success(values)
                    })
            } else if let routingFocusHit {
                ax = AXHelpers.Runtime(axApp: base.ax.axApp, attributeValue: base.ax.attributeValue,
                    attributeIsSettable: base.ax.attributeIsSettable, setAttributeValue: base.ax.setAttributeValue,
                    children: base.ax.children, performAction: base.ax.performAction, childCount: base.ax.childCount,
                    actionNames: base.ax.actionNames, actionNamesResult: base.ax.actionNamesResult,
                    childrenResult: base.ax.childrenResult, attributeValueResult: base.ax.attributeValueResult,
                    performActionResult: base.ax.performActionResult, elementAtPosition: routingFocusHit)
            } else { ax = base.ax }
            let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax,
                executeAppleScript: { _ in Issue.record("no scripts"); return .error("forbidden") },
                onScreenWindowList: { [] }, postPopupMenuEscape: { Issue.record("no Escape") },
                focusedApplicationPID: { 4242 })
            return logic
        }

        func configureOriginalPlateClick() throws {
            focusRestorationAckOnly = true
            let plate = builder.element(1_965_711)
            var position = CGPoint(x: 100, y: 300), size = CGSize(width: 100, height: 20)
            builder.setAttribute(plate, kAXPositionAttribute as String, try #require(AXValueCreate(.cgPoint, &position)))
            builder.setAttribute(plate, kAXSizeAttribute as String, try #require(AXValueCreate(.cgSize, &size)))
            builder.setAttributeSettable(plate, kAXValueAttribute as String, false)
            builder.setAttribute(plate, kAXWindowAttribute as String, window)
            routingFocusHit = { [self] app, point in
                guard CFEqual(app, self.app), point == CGPoint(x: 150, y: 310) else { return .success(nil) }
                routingFocusHitReads += 1
                if routingFocusHitReads == 1 {
                    if routingFocusClickFault == "plate" {
                        let replacement = builder.element(1_971_450)
                        builder.setRole(replacement, kAXTextFieldRole as String)
                        builder.setAttribute(replacement, kAXDescriptionAttribute as String, "Name")
                        builder.setAttribute(replacement, kAXValueAttribute as String, "Selected Canonical")
                        builder.setAttributeSettable(replacement, kAXValueAttribute as String, false)
                        builder.setChildren(replacement, [])
                        let children = builder.makeAXRuntime().children(strips[1]).map {
                            CFEqual($0, builder.element(1_965_711)) ? replacement : $0
                        }
                        builder.setChildren(strips[1], children)
                    } else if routingFocusClickFault == "frame" {
                        var changed = CGSize(width: 120, height: 20)
                        builder.setAttribute(builder.element(1_965_711), kAXSizeAttribute as String, AXValueCreate(.cgSize, &changed)!)
                    } else if routingFocusClickFault == "editor" {
                        builder.setAttributeSettable(builder.element(1_965_711), kAXValueAttribute as String, true)
                    } else if routingFocusClickFault == "source" {
                        builder.setChildren(mixer, [strips[0]])
                    } else if routingFocusClickFault == "peer" {
                        builder.setAttribute(builder.element(1_973_121), kAXValueAttribute as String, NSNumber(value: 0.4))
                    }
                }
                if routingFocusHitReads == 2 {
                    if routingFocusClickFault == "hit" { return .success(builder.element(1_971_451)) }
                    if routingFocusClickFault == "late_focus" {
                        builder.setAttribute(self.app, kAXFocusedUIElementAttribute as String, builder.element(1_971_451))
                    }
                    if routingFocusClickFault == "late_frame" {
                        var changed = CGSize(width: 120, height: 20)
                        builder.setAttribute(builder.element(1_965_711), kAXSizeAttribute as String, AXValueCreate(.cgSize, &changed)!)
                    }
                }
                return .success(builder.element(1_965_711))
            }
            routingFocusMouse = .init(postMouseEvent: { [self] type, point, count in
                guard point == CGPoint(x: 150, y: 310), count == 1,
                      type == .leftMouseDown || type == .leftMouseUp else {
                    Issue.record("Only the retained plate's single paired click is supported"); return false
                }
                routingFocusClickEvents.append(type)
                if type == .leftMouseUp {
                    if routingFocusClickFault == "release" { return false }
                    if routingFocusClickFault != "ack_only" {
                        builder.setAttribute(app, kAXFocusedUIElementAttribute as String, routingReplacement ?? strips[1])
                    }
                }
                return true
            }, postKeyEvent: { [self] key in key == 0x24 && (routingNameReturn?() ?? false) },
            postUnicodeScalar: { _ in Issue.record("No typing"); return false }, sleepMicros: { _ in })
        }

        func channel() -> AccessibilityChannel {
            if let routingLevelMouse {
                return AccessibilityChannel(runtime: .axBacked(isTrusted: { true },
                isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: logic(),
                observationMouseRuntime: routingLevelMouse, canPostEvents: { true }))
            }
            return AccessibilityChannel(runtime: .axBacked(isTrusted: { true },
                isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: logic(),
                trackRenameMouseRuntime: routingFocusMouse ?? (routingMenuRename ? .init(
                    postMouseEvent: { _, _, _ in Issue.record("No rename mouse fallback"); return false },
                    postKeyEvent: { [self] key in key == 0x24 && (routingNameReturn?() ?? false) },
                    postUnicodeScalar: { _ in Issue.record("No rename typing fallback"); return false }, sleepMicros: { _ in },
                    postFlaggedKeyEvent: { _, _ in Issue.record("No flagged rename key"); return false }) : .production),
                processRuntime: routingMenuRename ? .init(logicProPID: { 4242 }, fallbackLogicProPID: { 4242 },
                    logicProRunning: { true }, activateLogicPro: { false }, logicIsFrontmost: { true },
                    logicProBundleURL: { nil }) : .production, canPostEvents: { true }))
        }
    }

    /// Metadata censuses must reach the route with a genuinely retained native pair,
    /// not manufacture the association missing from a bare Mixer resource.
    func modeMetadataCapture() async throws -> (cache: StateCache, registry: TargetRegistry, reference: String) {
        let f = try Fixture(), cache = StateCache(), registry = TargetRegistry()
        let body = try await inspect(f, cache: cache, registry: registry,
            domains: ["tracks", "strips", "associations"], scope: "selection")
        let id = try #require(body["snapshot_id"] as? String)
        let retained = try #require(await cache.retainedInspection(id: id))
        let capture = retained.capture
        let index = try #require(capture.channelStrips.firstIndex {
            $0.physicalBinding.map { CFEqual($0.strip, f.strips[1]) } == true
        })
        let reference = try #require(capture.mixerReference(at: index))
        let source = try #require(capture.channelStrips[index].physicalBinding)
        _ = try #require(await cache.retainedMixerAssociation(reference: reference, source: source,
            snapshot: await registry.currentSnapshot))
        return (cache, registry, reference.rawValue)
    }

    private func inspect(_ f: Fixture, navigation: Bool = true, cache: StateCache = StateCache(),
                         fileReader: LogicProjectFileReader.Runtime = .unavailable,
                         registry: TargetRegistry = TargetRegistry(), projectRef: String? = nil,
                         domains: [String]? = ["associations"], guardedRenewalFocus: Bool = false,
                         guardedPassiveFocus: Bool = false,
                         scope: String = "whole_project") async throws -> [String: Any] {
        let gate = LogicMutationGate()
        let dependencies = HandlerDependencies(router: ChannelRouter(), cache: cache, targetRegistry: registry,
            poller: StatePoller(axChannel: f.channel(), cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: fileReader,
                               keyboardFocus: {
                                   guardedPassiveFocus || (guardedRenewalFocus && f.routingReplacement != nil)
                                       ? .textEditing(role: kAXLayoutItemRole as String, byInsertionPoint: true) : .notTextEditing
                               })),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: fileReader)
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
        var arguments: [String: Value] = ["allow_ui_navigation": .bool(navigation),
                                        "scope": .string(scope)]
        if let domains { arguments["domains"] = .array(domains.map(Value.string)) }
        if let projectRef { arguments["project_ref"] = .string(projectRef) }
        let params = arguments
        let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: params, mutationGate: gate) { await handler(dependencies, params) }
        return try #require(sharedJSONObject(sharedToolText(result)))
    }

    @Test("A checked physical output intent keeps the actual opposite-ordinal association in its canonical task",
          arguments: ["forward", "cancel", "late_peer", "unread_scalar", "unread_range", "boolean_scalar", "stereo", "no_op", "ack_only", "newer", "retired", "late_project", "absent_pan", "occupied_peer", "late_peer_send", "known_plugin", "unread_plugin", "unread_plugin_bypass", "post_write_loss", "unassigned_physical", "unoffered_physical", "census_redraw", "census_foreign", "census_scalar", "census_input", "census_send", "census_plugin", "census_header", "census_project", "coupled", "coupled_cancel", "coupled_second_failure", "coupled_newer_name", "coupled_late_peer", "coupled_project", "coupled_retired", "coupled_same", "coupled_name_leaf_peer", "coupled_editor", "coupled_foreign_editor", "coupled_retired_editor"])
    func canonicalPhysicalOutputUsesTheCapturedPair(mode: String) async throws {
        try await assertCanonicalPhysicalOutput(mode: mode)
    }

    @Test("Canonical output cancellation retains independent Saga reads without duplicate adapter popup reads")
    func canonicalOutputCancellationDoesNotRepeatTheSagasIndependentReadback() async throws {
        let f = try Fixture()
        try await assertCanonicalPhysicalOutput(mode: "cancel", fixture: f)
        #expect(f.routingDestinationPresses == 2)
        #expect(f.inputMenuPresses <= 8,
                "Keep the captured baseline, Saga before/after and inverse-ownership reads, and each checked scalar writer; duplicate adapter reads consume the same bounded native lifecycle")
    }

    @Test("Protected footprint rows retain full Help guards without repeating whole custody discovery for non-Help metadata")
    func coupledFootprintDoesNotRepeatWholeOwnershipAtEveryMetadataRow() async throws {
        let f = try Fixture()
        f.measuringFootprintReads = true
        try await assertCanonicalPhysicalOutput(mode: "coupled_menu_overlay", fixture: f)
        let footprints = f.footprintReads.values.filter {
            $0.names.count == f.strips.count && $0.help > 0 && $0.record > 0
        }
        #expect(!footprints.isEmpty, "Reach actual post-name complete protected reads and physical Help reads")
        for sample in footprints {
            #expect(sample.record <= sample.help,
                "Keep one fresh stopped-transport/custody check per actual Help read, not additional complete censuses per non-Help row: record=\(sample.record), Help=\(sample.help)")
        }
        #expect(f.routingNameWrites == ["Selected Canonical"] && f.routingDestinationPresses == 1)
    }

    @Test("A later restored document cannot authenticate already-sampled foreign or unknown Track footprint rows",
          arguments: ["foreign", "missing", "malformed"])
    func sampledTrackFootprintOwnershipCannotDisappearIntoJSON(fault: String) async throws {
        let calibration = try Fixture()
        calibration.measuringFootprintReads = true
        try await assertCanonicalPhysicalOutput(mode: "coupled_menu_overlay", fixture: calibration)
        let firstDocument = try #require(calibration.footprintReads.values.filter {
            $0.names.count == calibration.strips.count && $0.help > 0 && $0.record > 0
        }.compactMap(\.firstDocument).min())
        let f = try Fixture()
        f.measuringFootprintReads = true
        f.footprintDocumentFaultAt = firstDocument
        f.footprintDocumentFault = fault
        try await assertCanonicalPhysicalOutput(mode: "coupled_menu_overlay", fixture: f,
            refusingSampledTrackOwnership: true)
    }

    @Test("An owned output may redraw a peer while its exact source survives; changed protected state remains unknown",
          arguments: ["redraw", "foreign", "scalar", "input", "send", "plugin", "header", "project"])
    func canonicalOutputRenewsAnOwnedCensusWithASurvivingSource(fault: String) async throws {
        let f = try Fixture()
        try await assertCanonicalPhysicalOutput(mode: "surviving_census_" + fault, fixture: f)
        #expect(f.routingReplacement == nil, "The original source itself must not be retired in this counterexample")
        #expect(f.routingOtherReplacement != nil)
        #expect(f.routingDestinationPresses == 1, "No setter retry or guessed inverse is authorized")
    }

    @Test func lateOwnedEditorFocusAtFinalDocumentRefusesTheFirstSetter() async throws {
        let calibration = try Fixture()
        try await assertCanonicalPhysicalOutput(mode: "coupled_editor", fixture: calibration)
        let lastDocumentRead = try #require(calibration.routingDocumentReadsAtFirstNameWrite)
        #expect(lastDocumentRead > 0, "Calibrate from the actual first writer, not an earlier refusal")
        let lastConfirmDocumentRead = try #require(calibration.routingDocumentReadsAtFirstNameConfirm)
        #expect(lastConfirmDocumentRead > lastDocumentRead)
        for (mode, read) in [("coupled_late_editor", lastDocumentRead), ("coupled_late_confirm", lastConfirmDocumentRead)] {
            let fault = try Fixture()
            try await assertCanonicalPhysicalOutput(mode: mode, fixture: fault, foreignFocusAtDocumentRead: read)
            #expect(fault.routingLateScopeInjected)
            #expect(fault.routingNameWrites == (mode == "coupled_late_editor" ? [] : ["Selected Canonical"]))
            #expect(fault.routingNameConfirms == 0 && fault.routingDestinationPresses == 0)
        }
    }

    @Test(arguments: ["coupled_menu_overlay", "coupled_menu_overlay_second_failure",
                      "coupled_menu_overlay_foreign_rail", "coupled_menu_overlay_missing_header",
                      "coupled_menu_overlay_peer_change", "coupled_menu_overlay_late_editor",
                      "coupled_menu_overlay_post_peer", "coupled_menu_overlay_post_source",
                      "coupled_menu_overlay_post_editor", "coupled_menu_overlay_post_foreign_focus",
                      "coupled_menu_overlay_restore_ack_only"])
    func capturedOutputAndNameUseTheOwnedMenuEditorOverlay(mode: String) async throws {
        let f = try Fixture()
        try await assertCanonicalPhysicalOutput(mode: mode, fixture: f)
        let failing = !["coupled_menu_overlay", "coupled_menu_overlay_second_failure"].contains(mode)
        let inverses = mode == "coupled_menu_overlay_second_failure"
        let committed = mode.contains("_post_") || mode.hasSuffix("_restore_ack_only")
        #expect(f.routingMenuNameOpens == (inverses ? 2 : 1))
        #expect(f.routingNameWrites == (failing && !committed ? [] : inverses ? ["Selected Canonical", "Duplicate"] : ["Selected Canonical"]))
        #expect(f.routingNameConfirms == (failing && !committed ? 0 : inverses ? 2 : 1))
        #expect(f.routingDestinationPresses == (failing ? 0 : inverses ? 2 : 1))
        if failing { #expect(f.routingLateScopeInjected) }
        if !failing {
            let sampled: AXUIElement? = AXHelpers.getAttribute(f.app, kAXFocusedUIElementAttribute as String, runtime: f.logic().ax)
            let focus = try #require(sampled)
            #expect(CFEqual(focus, f.strips[1]), "Reacquisition must retain the original Mixer focus duty")
            #expect(f.focusRestorationWrites.isEmpty)
            #expect(f.routingFocusClickEvents == (inverses ? [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp] : [.leftMouseDown, .leftMouseUp]))
        } else {
            #expect(f.focusRestorationWrites.isEmpty)
            #expect(f.routingFocusClickEvents == (mode.hasSuffix("_restore_ack_only") ? [.leftMouseDown, .leftMouseUp] : []))
        }
    }

    @Test func committedMenuNameUsesOneOriginalPlateClickWhenFocusedSetterHasNoEffect() async throws {
        let f = try Fixture()
        try await assertCanonicalPhysicalOutput(mode: "coupled_menu_overlay_click", fixture: f)
        #expect(f.focusRestorationWrites.isEmpty, "This continuation must not attempt AXFocused before clicking")
        #expect(f.routingFocusClickEvents == [.leftMouseDown, .leftMouseUp])
        let sampled: AXUIElement? = AXHelpers.getAttribute(f.app, kAXFocusedUIElementAttribute as String, runtime: f.logic().ax)
        let focus = try #require(sampled)
        #expect(CFEqual(focus, f.strips[1]))
    }

    @Test func ownedCoupledNameContinuesThroughTheWholeOutputRenewalCensus() async throws {
        let f = try Fixture()
        try await assertCanonicalPhysicalOutput(mode: "coupled_menu_overlay_census", fixture: f)
        #expect(f.routingNameWrites == ["Selected Canonical"])
        #expect(f.routingDestinationPresses == 1)
        let peer = try #require(f.routingOtherReplacement)
        let source = try #require(f.routingReplacement)
        #expect(!CFEqual(peer, f.strips[0]) && !CFEqual(source, f.strips[1]))
        let census = try #require(AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: f.mixer, runtime: f.logic().ax))
        #expect(census.strips.count == 2)
        #expect(census.strips.allSatisfy { current in f.strips.allSatisfy { !CFEqual(current, $0) } })
    }

    @Test("Cancellation after the actual name writer preserves only its owned cleanup and inverse",
          arguments: ["healthy", "peer", "project", "source"])
    func coupledNameWriterCancellationFinishesOwnedFocusBeforeCompensation(fault: String) async throws {
        try await assertCanonicalPhysicalOutput(mode: "coupled_menu_overlay_name_cancel_" + fault)
    }

    @Test("A verified track alias keeps its actual unchanged Mixer name through output and inverse",
          arguments: ["forward", "second_failure", "newer_mirror", "newer_primary", "reverted_mirror"])
    func canonicalTrackAliasDoesNotInventAMirrorRename(_ fault: String) async throws {
        let f = try Fixture()
        try await assertCanonicalPhysicalOutput(mode: "coupled_menu_overlay_uncoupled_" + fault, fixture: f)
        #expect(f.routingNameChannelStates.first == "A", "Reach the actual verified name writer")
    }

    @Test("Coupled naming survives an owned peer redraw while its exact source remains current",
          arguments: ["coupled_menu_overlay_census", "coupled_menu_overlay_census_second_failure"])
    func coupledNameContinuationRetainsASurvivingOriginalSource(mode: String) async throws {
        let f = try Fixture()
        try await assertCanonicalPhysicalOutput(mode: "surviving_" + mode, fixture: f)
        #expect(f.routingReplacement == nil, "Keep the exact original source, not a replacement with the same name")
        let redrawnPeer = try #require(f.routingOtherReplacement)
        #expect(!CFEqual(redrawnPeer, f.strips[0]))
        let census = f.builder.makeAXRuntime().children(f.mixer)
        #expect(census.contains { CFEqual($0, f.strips[1]) })
        #expect(!census.contains { CFEqual($0, f.strips[0]) })
        #expect(f.routingOutputChannelStates == (mode.hasSuffix("second_failure") ? ["A", "A"] : ["A"]))
    }

    @Test("Coupled surviving-source continuation still refuses changed protected state",
          arguments: ["scalar", "input", "send", "plugin", "header", "project"])
    func coupledSurvivingSourceDoesNotAdoptChangedProtectedState(fault: String) async throws {
        try await assertCanonicalPhysicalOutput(mode: "surviving_coupled_menu_overlay_census_" + fault)
    }

    @Test func ownedWholeCensusContinuationCanCompensateBothActualLeaves() async throws {
        let f = try Fixture()
        try await assertCanonicalPhysicalOutput(mode: "coupled_menu_overlay_census_second_failure", fixture: f)
        #expect(f.routingOutputChannelStates == ["A", "A"])
        #expect(f.routingNameWrites == ["Selected Canonical", "Duplicate"])
        #expect(f.routingDestinationPresses == 2)
    }

    @Test(arguments: ["plate", "frame", "editor", "source", "peer", "hit", "late_focus", "late_frame", "ack_only", "release"])
    func committedMenuFocusClickRefusesChangedCustodyWithoutOutputOrGuessedInverse(fault: String) async throws {
        let f = try Fixture()
        f.routingFocusClickFault = fault
        try await assertCanonicalPhysicalOutput(mode: "coupled_menu_overlay_click", fixture: f)
        #expect(f.routingNameWrites == ["Selected Canonical"])
        #expect(f.routingNameConfirms == 1)
        #expect(f.routingDestinationPresses == 0)
        #expect(f.focusRestorationWrites.isEmpty)
        #expect(f.routingFocusHitReads > 0)
        #expect(f.routingFocusClickEvents == (["ack_only", "release"].contains(fault) ? [.leftMouseDown, .leftMouseUp] : []))
    }

    private func assertCanonicalPhysicalOutput(mode requestedMode: String, fixture: Fixture? = nil,
                                               foreignFocusAtDocumentRead: Int? = nil,
                                               refusingSampledTrackOwnership: Bool = false) async throws {
        let survivingSource = requestedMode.hasPrefix("surviving_")
        let mode = survivingSource ? String(requestedMode.dropFirst("surviving_".count)) : requestedMode
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try fixture ?? Fixture(), cache = StateCache(), registry = TargetRegistry()
                let composed = mode.hasPrefix("coupled")
                let censusMode = mode.hasPrefix("coupled_menu_overlay_")
                    ? String(mode.dropFirst("coupled_menu_overlay_".count)) : mode
                let menuOverlay = mode.hasPrefix("coupled_menu_overlay")
                let uncoupled = mode.hasPrefix("coupled_menu_overlay_uncoupled_")
                let newerUncoupled = uncoupled && ["newer_mirror", "newer_primary", "reverted_mirror"].contains(where: { mode.hasSuffix($0) })
                let cancelsAfterName = mode.hasPrefix("coupled_menu_overlay_name_cancel_")
                let ownsEditor = ["coupled_editor", "coupled_retired_editor", "coupled_late_editor", "coupled_late_confirm"].contains(mode)
                let compensatesBoth = ["coupled_cancel", "coupled_second_failure", "coupled_retired", "coupled_retired_editor", "coupled_menu_overlay_second_failure", "coupled_menu_overlay_census_second_failure", "coupled_menu_overlay_uncoupled_second_failure"].contains(mode)
                let nameField = f.builder.element(1_971_400)
                let menuEditor = f.builder.element(1_971_402), rename = f.builder.element(1_971_406)
                if composed {
                    f.builder.setRole(nameField, kAXTextFieldRole as String)
                    f.builder.setAttribute(nameField, kAXDescriptionAttribute as String, "Duplicate")
                    f.builder.setAttribute(nameField, kAXValueAttribute as String, "0")
                    f.builder.setAttribute(nameField, kAXWindowAttribute as String, f.window)
                    f.builder.setChildren(nameField, [])
                    f.builder.setChildren(f.headers[0], [nameField])
                    if menuOverlay {
                        f.routingMenuRename = true
                        f.builder.setAttributeSettable(f.strips[1], kAXFocusedAttribute as String, true)
                        f.builder.setAttributeSettable(f.rail, kAXValueAttribute as String, false)
                        try f.configureOriginalPlateClick()
                        if mode.hasSuffix("_restore_ack_only") { f.routingFocusClickFault = "ack_only" }
                        f.builder.setAttribute(nameField, kAXValueAttribute as String, NSNumber(value: 0))
                        f.builder.setAttributeSettable(nameField, kAXValueAttribute as String, false)
                        let bar = f.builder.element(1_971_403), trackMenu = f.builder.element(1_971_404)
                        let menu = f.builder.element(1_971_405)
                        for (node, role) in [(bar, kAXMenuBarRole), (trackMenu, kAXMenuBarItemRole),
                                             (menu, kAXMenuRole), (rename, kAXMenuItemRole), (menuEditor, kAXTextFieldRole)] {
                            f.builder.setRole(node, role as String)
                        }
                        f.builder.setAttribute(trackMenu, kAXTitleAttribute as String, AXLocalePolicy.trackMenuBar.canonical)
                        f.builder.setAttribute(rename, kAXTitleAttribute as String, AXLocalePolicy.renameTrackMenuItem.canonical)
                        f.builder.setChildren(bar, [trackMenu]); f.builder.setChildren(trackMenu, [menu]); f.builder.setChildren(menu, [rename])
                        f.builder.setAttribute(f.app, kAXMenuBarAttribute as String, bar)
                        f.builder.setAttribute(menuEditor, kAXWindowAttribute as String, f.window)
                        f.builder.setAttribute(menuEditor, kAXParentAttribute as String, f.rail)
                        f.builder.setAttribute(menuEditor, kAXValueAttribute as String, "Duplicate")
                        f.builder.setAttributeSettable(menuEditor, kAXValueAttribute as String, true)
                        f.builder.setChildren(menuEditor, [])
                        f.routingNameReturn = {
                            guard let name = f.builder.attributeValue(menuEditor, kAXValueAttribute as String) as? String else { return false }
                            f.routingNameConfirms += 1
                            f.builder.setAttribute(nameField, kAXDescriptionAttribute as String, name)
                            f.builder.setAttribute(f.headers[0], kAXTitleAttribute as String, name)
                            if !uncoupled { f.builder.setAttribute(f.builder.element(1_965_711), kAXValueAttribute as String, name) }
                            // Native menu Return closes the owned editor on the
                            // original rail path, not the earlier Mixer focus.
                            f.builder.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.routingReplacement ?? f.strips[1]])
                            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
                            if mode == "coupled_menu_overlay_post_peer" {
                                f.builder.setAttribute(f.builder.element(1_973_121), kAXValueAttribute as String, NSNumber(value: 0.4))
                            } else if mode == "coupled_menu_overlay_post_source" {
                                let replacement = f.builder.element(1_971_408)
                                f.builder.setRole(replacement, kAXLayoutItemRole as String)
                                f.builder.setChildren(replacement, f.builder.makeAXRuntime().children(f.strips[1]))
                                f.routingReplacement = replacement
                                f.builder.setChildren(f.mixer, [f.strips[0], replacement])
                                f.builder.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [replacement])
                            } else if mode == "coupled_menu_overlay_post_editor" || mode == "coupled_menu_overlay_post_foreign_focus" {
                                let foreign = f.builder.element(1_971_409)
                                f.builder.setRole(foreign, mode.hasSuffix("_post_editor") ? kAXTextFieldRole as String : kAXGroupRole as String)
                                f.builder.setAttribute(foreign, kAXWindowAttribute as String, f.window)
                                f.builder.setAttribute(foreign, kAXValueAttribute as String, "Selected Canonical")
                                f.builder.setAttributeSettable(foreign, kAXValueAttribute as String, true)
                                f.builder.setChildren(foreign, [])
                                f.builder.setAttribute(foreign, kAXParentAttribute as String, f.window)
                                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, foreign)
                            }
                            if mode.contains("_post_") || mode.hasSuffix("_restore_ack_only") { f.routingLateScopeInjected = true }
                            return true
                        }
                    }
                    f.routingSetter = { element, attribute, value in
                        guard CFEqual(element, menuOverlay ? menuEditor : nameField), attribute == kAXValueAttribute as String,
                              let name = value as? String else { return nil }
                        if f.routingNameWrites.isEmpty { f.routingDocumentReadsAtFirstNameWrite = f.routingDocumentReads }
                        f.routingNameWrites.append(name)
                        if menuOverlay {
                            f.builder.setAttribute(menuEditor, kAXValueAttribute as String, name)
                            return true
                        }
                        f.builder.setAttribute(nameField, kAXDescriptionAttribute as String, name)
                        f.builder.setAttribute(f.headers[0], kAXTitleAttribute as String, name)
                        if ownsEditor {
                            f.builder.setAttribute(nameField, kAXValueAttribute as String, name)
                        }
                        return true
                    }
                }
                let redrawsCensus = mode.hasPrefix("census_") || mode.hasPrefix("coupled_menu_overlay_census")
                if mode.hasPrefix("coupled_menu_overlay_census") {
                    f.routingSelection = { index in
                        f.builder.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String,
                            [index == 0 ? f.routingReplacement ?? f.strips[1] : f.routingOtherReplacement ?? f.strips[0]])
                    }
                }
                @Sendable func redrawPeer(_ node: AXUIElement, key: Int) -> AXUIElement {
                    let copy = f.builder.element(key)
                    for attribute in [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                                      kAXValueAttribute, kAXValueDescriptionAttribute, kAXMinValueAttribute, kAXMaxValueAttribute,
                                      kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute] as [String] {
                        if let value = f.builder.attributeValue(node, attribute) { f.builder.setAttribute(copy, attribute, value) }
                    }
                    f.builder.setChildren(copy, f.builder.makeAXRuntime().children(node).enumerated().map {
                        redrawPeer($0.element, key: key * 10 + $0.offset + 1)
                    })
                    if f.routingScalarControls.contains(where: { CFEqual($0, node) }) {
                        f.routingScalarControls.append(copy)
                    }
                    if censusMode == "census_scalar", CFEqual(node, f.builder.element(1_973_121)) {
                        f.routingLateScopeInjected = true
                        f.builder.setAttribute(copy, kAXValueAttribute as String, NSNumber(value: 0.4))
                    }
                    if censusMode == "census_input", CFEqual(node, f.builder.element(1_973_170)) {
                        f.routingLateScopeInjected = true
                        f.builder.setAttribute(copy, kAXDescriptionAttribute as String, "Input 2")
                    }
                    if censusMode == "census_send", CFEqual(node, f.builder.element(1_973_151)) {
                        f.routingLateScopeInjected = true
                        f.builder.setAttribute(copy, kAXDescriptionAttribute as String, "Bus 1")
                    }
                    if censusMode == "census_plugin", CFEqual(node, f.builder.element(19_731_601)) {
                        f.routingLateScopeInjected = true
                        f.builder.setAttribute(copy, kAXValueAttribute as String, NSNumber(value: 1))
                    }
                    return copy
                }
                let outer = f.builder.element(1_973_090)
                f.builder.setNamedContainer(f.mixer, role: kAXLayoutAreaRole as String, description: "Mixer",
                    x: 0, y: 0, width: 400, height: 400)
                f.builder.setRole(outer, kAXGroupRole as String)
                f.builder.setAttribute(outer, kAXDescriptionAttribute as String, "Mixer")
                f.builder.setChildren(outer, [f.mixer])
                f.builder.setChildren(f.window, [f.rail, outer, f.builder.element(1_965_720)])
                f.routingReadResult = { element, attribute in
                    if menuOverlay, CFEqual(element, f.rail),
                       [kAXValueAttribute, kAXSelectedTextAttribute, kAXNumberOfCharactersAttribute,
                        kAXInsertionPointLineNumberAttribute].map({ $0 as String }).contains(attribute) {
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    if menuOverlay, CFEqual(element, nameField), attribute == kAXValueAttribute as String {
                        return .success(NSNumber(value: 0))
                    }
                    if mode == "unread_scalar", CFEqual(element, f.builder.element(1_973_121)),
                       attribute == kAXValueAttribute as String {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    if f.strips.contains(where: { CFEqual($0, element) }) || f.routingReplacement.map({ CFEqual($0, element) }) == true,
                       [kAXNumberOfCharactersAttribute as String, kAXInsertionPointLineNumberAttribute as String].contains(attribute) {
                        return .success(NSNumber(value: 0))
                    }
                    return nil
                }
                let outputs = f.strips.indices.map { f.builder.element(1_973_100 + $0) }
                let root = f.builder.element(1_973_110), parent = f.builder.element(1_973_111)
                let submenu = f.builder.element(1_973_112), stereo = f.builder.element(1_973_113)
                let physical = f.builder.element(1_973_114)
                let echo = f.builder.element(1_973_115)
                f.builder.setRole(echo, kAXMenuItemRole as String)
                f.builder.setAttribute(echo, "AXMenuItemMarkChar", "✓")
                f.builder.setChildren(echo, [])
                f.routingRead = { element, attribute in
                    if mode == "coupled_menu_overlay_late_editor", f.routingMenuNameOpens > 0,
                       CFEqual(element, menuEditor), attribute == kAXParentAttribute as String, !f.routingLateScopeInjected {
                        let foreign = f.builder.element(1_971_401)
                        f.builder.setRole(foreign, kAXTextFieldRole as String)
                        f.builder.setAttribute(foreign, kAXValueAttribute as String, "Duplicate")
                        f.builder.setAttribute(foreign, kAXWindowAttribute as String, f.window)
                        f.builder.setAttribute(foreign, kAXParentAttribute as String, f.rail)
                        f.builder.setChildren(foreign, [])
                        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, foreign)
                        f.routingLateScopeInjected = true
                    }
                    if composed, CFEqual(element, f.window), attribute == kAXDocumentAttribute as String {
                        f.routingDocumentReads += 1
                        if f.routingDocumentReads == foreignFocusAtDocumentRead {
                            let foreign = f.builder.element(1_971_401)
                            f.builder.setRole(foreign, kAXTextFieldRole as String)
                            f.builder.setAttribute(foreign, kAXValueAttribute as String, "Duplicate")
                            f.builder.setAttribute(foreign, kAXWindowAttribute as String, f.window)
                            f.builder.setChildren(foreign, [])
                            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, foreign)
                            f.routingLateScopeInjected = true
                        }
                    }
                    if outputs.contains(where: { CFEqual($0, element) }), attribute == kAXHelpAttribute as String {
                        f.routingClassifierHelpReads += 1
                    }
                    if mode == "late_peer", CFEqual(element, physical), attribute == kAXEnabledAttribute as String,
                       f.routingOpenedOutputIndex == 1, f.inputMenuPresses > 1, !f.routingLateScopeInjected {
                        f.routingLateScopeInjected = true
                        f.builder.setAttribute(f.builder.element(1_973_121), kAXValueAttribute as String, NSNumber(value: 0.4))
                    }
                    if mode == "late_project", CFEqual(element, physical), attribute == kAXEnabledAttribute as String,
                       f.routingOpenedOutputIndex == 1, f.inputMenuPresses > 1, !f.routingLateScopeInjected {
                        f.routingLateScopeInjected = true
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                    if mode == "late_peer_send", CFEqual(element, physical), attribute == kAXEnabledAttribute as String,
                       f.routingOpenedOutputIndex == 1, f.inputMenuPresses > 1, !f.routingLateScopeInjected {
                        f.routingLateScopeInjected = true
                        f.builder.setAttribute(f.builder.element(1_973_151), kAXDescriptionAttribute as String, "Bus 1")
                    }
                }
                for index in outputs.indices {
                    f.builder.setButton(outputs[index], description: !["unassigned_physical", "unoffered_physical"].contains(mode) && (index == 0) != (mode == "stereo") ? "Output 3-4" : "Stereo Output",
                        help: "Output slot. Choose the channel strip output.", x: 0, y: 0, width: 1, height: 1)
                    f.builder.setChildren(outputs[index], [])
                    f.builder.setActionNames(outputs[index], [kAXPressAction as String])
                    let volume = f.builder.element(1_973_120 + index * 2), pan = f.builder.element(1_973_121 + index * 2)
                    for (control, description, value, minimum, maximum) in [
                        (volume, "Volume", 100.0, 0.0, 233.0), (pan, "Pan", 0.2, -1.0, 1.0)
                    ] {
                        f.builder.setRole(control, kAXSliderRole as String)
                        f.builder.setAttribute(control, kAXDescriptionAttribute as String, description)
                        f.builder.setAttribute(control, kAXValueAttribute as String, NSNumber(value: value))
                        f.builder.setAttribute(control, kAXMinValueAttribute as String, NSNumber(value: minimum))
                        f.builder.setAttribute(control, kAXMaxValueAttribute as String, NSNumber(value: maximum))
                        f.builder.setChildren(control, [])
                        f.routingScalarControls.append(control)
                    }
                    f.builder.setChildren(f.strips[index], f.builder.makeAXRuntime().children(f.strips[index]) + [outputs[index], volume, pan])
                }
                if mode == "unread_scalar" {
                    f.builder.setAttribute(f.builder.element(1_973_121), kAXValueAttribute as String, NSNull())
                }
                if mode == "unread_range" {
                    f.builder.setAttribute(f.builder.element(1_973_120), kAXMinValueAttribute as String, NSNull())
                }
                if mode == "boolean_scalar" {
                    f.builder.setAttribute(f.builder.element(1_973_121), kAXValueAttribute as String, NSNumber(value: false))
                }
                if mode == "absent_pan" {
                    f.builder.setChildren(f.strips[0], f.builder.makeAXRuntime().children(f.strips[0]).filter {
                        !CFEqual($0, f.builder.element(1_973_121))
                    })
                }
                if mode == "occupied_peer" || mode == "late_peer_send" || censusMode == "census_send" {
                    let anchor = f.builder.element(1_973_150), group = f.builder.element(1_973_151)
                    let bypass = f.builder.element(1_973_152), list = f.builder.element(1_973_153)
                    let knob = f.builder.element(1_973_154)
                    f.builder.setButton(anchor, description: "send button", help: "Send slot. Route signal.", x: 0, y: 0, width: 1, height: 1)
                    f.builder.setChildren(anchor, [])
                    f.builder.setRole(group, kAXGroupRole as String)
                    f.builder.setAttribute(group, kAXDescriptionAttribute as String, "Stereo Output")
                    f.builder.setRole(bypass, kAXCheckBoxRole as String)
                    f.builder.setAttribute(bypass, kAXValueAttribute as String, 0)
                    f.builder.setChildren(bypass, [])
                    f.builder.setRole(list, kAXButtonRole as String)
                    f.builder.setAttribute(list, kAXDescriptionAttribute as String, "list")
                    f.builder.setChildren(list, []); f.builder.setChildren(group, [bypass, list])
                    f.builder.setRole(knob, kAXSliderRole as String)
                    f.builder.setAttribute(knob, kAXHelpAttribute as String, "Send Level knob. Set level.")
                    f.builder.setAttribute(knob, kAXValueAttribute as String, NSNumber(value: 0))
                    f.builder.setChildren(knob, []); f.routingScalarControls.append(knob)
                    f.builder.setChildren(f.strips[0], f.builder.makeAXRuntime().children(f.strips[0]) + [anchor, group, knob])
                }
                if ["known_plugin", "unread_plugin", "unread_plugin_bypass"].contains(mode) || censusMode == "census_plugin" {
                    let plugin = Issue982UnreadChildrenTests.occupiedSlot(f.builder, 1_973_160, name: "Compressor")
                    if mode == "unread_plugin" { f.builder.setAttribute(plugin, kAXDescriptionAttribute as String, NSNull()) }
                    if mode == "unread_plugin_bypass" {
                        f.builder.setAttribute(f.builder.element(19_731_601), kAXValueAttribute as String, NSNull())
                    }
                    f.builder.setChildren(f.strips[0], f.builder.makeAXRuntime().children(f.strips[0]) + [plugin])
                }
                if censusMode == "census_input" {
                    let input = f.builder.element(1_973_170)
                    f.builder.setButton(input, description: "Input 1", help: "Input slot. Choose the channel strip input source.",
                        x: 0, y: 0, width: 1, height: 1)
                    f.builder.setChildren(input, [])
                    f.builder.setChildren(f.strips[0], f.builder.makeAXRuntime().children(f.strips[0]) + [input])
                }
                for (element, role) in [(root, kAXMenuRole), (parent, kAXMenuItemRole),
                    (submenu, kAXMenuRole), (stereo, kAXMenuItemRole), (physical, kAXMenuItemRole)] {
                    f.builder.setRole(element, role as String)
                }
                f.builder.setAttribute(parent, kAXTitleAttribute as String, "Output")
                f.builder.setAttribute(stereo, kAXTitleAttribute as String, "Stereo Output")
                f.builder.setAttribute(physical, kAXTitleAttribute as String, "Output 3-4")
                f.builder.setAttribute(stereo, kAXEnabledAttribute as String, true)
                f.builder.setAttribute(physical, kAXEnabledAttribute as String, true)
                f.builder.setChildren(stereo, []); f.builder.setChildren(physical, [])
                f.builder.setChildren(submenu, mode == "unoffered_physical" ? [stereo] : [stereo, physical]); f.builder.setChildren(parent, [submenu])
                f.builder.setChildren(root, [echo, parent]); f.builder.setActionNames(root, [kAXCancelAction as String])
                f.routingAction = { element, action in
                    if menuOverlay, CFEqual(element, rename), action == kAXPressAction as String {
                        f.routingMenuNameOpens += 1
                        f.builder.setAttribute(menuEditor, kAXValueAttribute as String,
                            f.builder.attributeValue(nameField, kAXDescriptionAttribute as String))
                        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, menuEditor)
                        if mode == "coupled_menu_overlay_foreign_rail" {
                            let foreignRail = f.builder.element(1_971_407)
                            f.builder.setRole(foreignRail, kAXGroupRole as String)
                            f.builder.setAttribute(foreignRail, kAXWindowAttribute as String, f.window)
                            f.builder.setChildren(foreignRail, [])
                            f.builder.setAttribute(menuEditor, kAXParentAttribute as String, foreignRail)
                            f.routingLateScopeInjected = true
                        } else if mode == "coupled_menu_overlay_missing_header" {
                            f.builder.setChildren(f.rail, [f.headers[0]])
                            f.routingLateScopeInjected = true
                        } else if mode == "coupled_menu_overlay_peer_change" {
                            f.builder.setAttribute(f.builder.element(1_973_121), kAXValueAttribute as String, NSNumber(value: 0.4))
                            f.routingLateScopeInjected = true
                        }
                        return true
                    }
                    if composed, CFEqual(element, nameField) {
                        if ownsEditor {
                            f.builder.setAttributeSettable(nameField, kAXValueAttribute as String, true)
                            f.builder.setAttribute(nameField, kAXValueAttribute as String,
                                f.builder.attributeValue(nameField, kAXDescriptionAttribute as String))
                            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                                action == kAXConfirmAction as String ? f.routingReplacement ?? f.strips[1] : nameField)
                        }
                        if mode == "coupled_foreign_editor", action == kAXPressAction as String {
                            let foreign = f.builder.element(1_971_401)
                            f.builder.setRole(foreign, kAXTextFieldRole as String)
                            f.builder.setAttribute(foreign, kAXValueAttribute as String, "Duplicate")
                            f.builder.setAttribute(foreign, kAXWindowAttribute as String, f.window)
                            f.builder.setChildren(foreign, [])
                            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, foreign)
                            f.routingLateScopeInjected = true
                        }
                        if mode == "coupled_name_leaf_peer", action == kAXPressAction as String, !f.routingLateScopeInjected {
                            f.routingLateScopeInjected = true
                            f.builder.setAttribute(f.builder.element(1_973_121), kAXValueAttribute as String, NSNumber(value: 0.4))
                        }
                        if action == kAXConfirmAction as String {
                            if f.routingNameConfirms == 0 { f.routingDocumentReadsAtFirstNameConfirm = f.routingDocumentReads }
                            f.routingNameConfirms += 1
                            f.builder.setAttribute(f.builder.element(1_965_711), kAXValueAttribute as String,
                                f.builder.attributeValue(nameField, kAXDescriptionAttribute as String))
                        }
                        return [kAXPressAction as String, kAXConfirmAction as String].contains(action)
                    }
                    if action == kAXPressAction as String,
                       let index = outputs.firstIndex(where: { CFEqual($0, element) }) {
                        let label = f.builder.attributeValue(outputs[index], kAXDescriptionAttribute as String) as? String
                        f.builder.setAttribute(echo, kAXTitleAttribute as String, label)
                        f.routingOpenedOutputIndex = index
                        if newerUncoupled, !f.routingLateScopeInjected,
                           f.routingNameWrites.count == 1, f.routingNameConfirms == 1 {
                            f.routingLateScopeInjected = true
                            if mode.hasSuffix("newer_primary") {
                                f.builder.setAttribute(nameField, kAXDescriptionAttribute as String, "External")
                                f.builder.setAttribute(f.headers[0], kAXTitleAttribute as String, "External")
                            } else {
                                f.builder.setAttribute(f.builder.element(1_965_711), kAXValueAttribute as String,
                                    mode.hasSuffix("reverted_mirror") ? "Selected Canonical" : "External")
                            }
                        }
                        f.builder.setAttribute(stereo, "AXMenuItemMarkChar", label == "Stereo Output" ? "✓" : "")
                        f.builder.setAttribute(physical, "AXMenuItemMarkChar", label == "Output 3-4" ? "✓" : "")
                        f.builder.setChildren(f.mixer, [f.routingOtherReplacement ?? f.strips[0], f.routingReplacement ?? f.strips[1], root])
                        f.inputMenuPresses += 1
                        return true
                    }
                    if CFEqual(element, root), action == kAXCancelAction as String {
                        f.routingOpenedOutputIndex = nil
                        f.builder.setChildren(f.mixer, [f.routingOtherReplacement ?? f.strips[0], f.routingReplacement ?? f.strips[1]])
                        f.inputMenuCancels += 1; return true
                    }
                    if action == kAXPressAction as String, CFEqual(element, physical) || CFEqual(element, stereo),
                       let index = f.routingOpenedOutputIndex {
                        f.routingDestinationPresses += 1
                        if mode != "ack_only" {
                            f.builder.setAttribute(outputs[index], kAXDescriptionAttribute as String,
                                CFEqual(element, physical) ? "Output 3-4" : "Stereo Output")
                        }
                        f.routingOpenedOutputIndex = nil
                        if !survivingSource,
                           mode == "retired" || mode.hasPrefix("coupled_retired") || redrawsCensus, f.routingReplacement == nil {
                            let replacement = f.builder.element(1_973_140)
                            f.builder.setRole(replacement, kAXLayoutItemRole as String)
                            f.builder.setAttribute(replacement, kAXNumberOfCharactersAttribute as String, 0)
                            f.builder.setAttribute(replacement, kAXInsertionPointLineNumberAttribute as String, 0)
                            f.builder.setChildren(replacement, f.builder.makeAXRuntime().children(f.strips[1]))
                            f.routingReplacement = replacement
                            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, replacement)
                            if redrawsCensus { f.routingOtherReplacement = redrawPeer(f.strips[0], key: 1_974_200) }
                        }
                        if survivingSource, f.routingOtherReplacement == nil {
                            f.routingOtherReplacement = redrawPeer(f.strips[0], key: 1_974_200)
                        }
                        f.builder.setChildren(f.mixer, [f.routingOtherReplacement ?? f.strips[0], f.routingReplacement ?? f.strips[1]])
                        if menuOverlay, let replacement = f.routingReplacement {
                            f.builder.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [replacement])
                        }
                        if censusMode == "census_header" {
                            f.routingLateScopeInjected = true
                            f.builder.setChildren(f.rail, [redrawPeer(f.headers[0], key: 1_974_201), f.headers[1]])
                        }
                        if censusMode == "census_project" {
                            f.routingLateScopeInjected = true
                            f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        }
                        return true
                    }
                    f.routingDestinationPresses += 1
                    Issue.record("Capture must never press an output destination"); return false
                }
                let domains = ["tracks", "strips", "associations", "routing"]
                let inspected = try await inspect(f, cache: cache, registry: registry, domains: domains, scope: "selection")
                let id = try #require(inspected["snapshot_id"] as? String)
                let retained = try #require(await cache.retainedInspection(id: id))
                let capture = retained.capture
                let stable = try #require(capture.freshPopulation?.stable)
                #expect(stable)
                if ["known_plugin", "unread_plugin", "unread_plugin_bypass"].contains(mode) {
                    let slots = try #require(AXLogicProElements.audioPluginInsertSlots(in: f.strips[0], runtime: f.logic().ax))
                    #expect(slots.count == 1 && slots[0].occupied)
                    #expect(slots[0].readStatus == (mode == "unread_plugin" ? .occupiedUnreadable : .occupiedReadable))
                    #expect([slots[0].isBypassed] == [mode == "unread_plugin_bypass" ? nil : false])
                }
                if mode == "occupied_peer" || mode == "late_peer_send" {
                    let occupied = try #require(capture.channelStrips[0].sendSlots?.first { $0.state == .occupiedUnknownDestination })
                    #expect(occupied.levelRaw == 0 && occupied.destinationDisplay == "Stereo Output")
                    let bypassed = try #require(occupied.bypassed)
                    #expect(!bypassed)
                }
                for (index, row) in capture.channelStrips.enumerated() where mode != "unread_scalar" {
                    let volume = try #require(AXLogicProElements.findVolumeFader(in: f.strips[index], runtime: f.logic().ax, requireUnique: true))
                    #expect(row.volume == AXValueExtractors.extractLogicMixerFaderValue(volume, runtime: f.logic().ax))
                    if mode == "absent_pan", index == 0 {
                        #expect(row.pan == 0)
                    } else {
                        let pan = try #require(AXLogicProElements.findPanControl(in: f.strips[index], runtime: f.logic().ax, requireUnique: true))
                        #expect(row.pan == AXValueExtractors.extractCenteredSliderValue(pan, runtime: f.logic().ax))
                    }
                }
                let pair = try #require(capture.freshPopulation?.selectionAssociations.first {
                    CFEqual($0.track.header, f.headers[0])
                })
                #expect(CFEqual(pair.strip.strip, f.strips[1]), "The captured pair is not an ordinal join")
                #expect(capture.freshPopulation?.checkedOutputs.filter {
                    $0.source.matches(pair.strip) && $0.assignment == (mode == "stereo" ? .physical(3, 4) : .stereoOutput) && $0.sendOrdinal == nil
                }.count == 1, "Actual outputs=\(capture.channelStrips.map(\.output)), Help reads=\(f.routingClassifierHelpReads), presses=\(f.inputMenuPresses), stable=\(capture.freshPopulation?.stable)")
                #expect(f.inputMenuPresses == 1 && f.inputMenuCancels == 1 && f.routingDestinationPresses == 0)
                let target = try #require(capture.issued?.byRow[0])
                guard case .issued(let project)? = capture.projectIssuance else {
                    Issue.record("Actual capture must issue the project"); return
                }
                let raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(project.rawValue),
                    "targets": .array([.object(["handle": .string("source"), "track_ref": .string(target.rawValue)])]),
                    "outputs": .array([.object(["target": .string("source"),
                        "output": mode == "stereo" || mode == "no_op" ? .object(["kind": .string("stereo_output")])
                            : .object(["kind": .string("physical"), "ports": .array([.int(3), .int(4)])])])])]
                guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
                    Issue.record("The explicit typed physical output must parse"); return
                }
                let names: [ProjectSessionAudit.ApprovedName] = composed
                    ? [.init(target: "source", name: mode == "coupled_same" ? "Duplicate" : "Selected Canonical")] : []
                let plan: ProjectSessionAudit.CanonicalRepairPlan
                if composed {
                    let dependencies = HandlerDependencies(router: ChannelRouter(), cache: cache, targetRegistry: registry,
                        poller: StatePoller(axChannel: f.channel(), cache: cache, runtime: .init(hasVisibleWindow: { false })),
                        dialogPresent: { false }, supportBundleExporter: nil, mutationGate: LogicMutationGate(),
                        liveTrackNames: { [:] }, projectFileReader: .unavailable)
                    let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "plan_session_repair"))
                    let params: [String: Value] = ["snapshot_id": .string(id), "policy": .object(raw),
                        "names": .array(names.map { .object(["target": .string($0.target), "name": .string($0.name)]) })]
                    #expect(LogicProServer.strictParamValidationResult(tool: "logic_project", command: "plan_session_repair", params: params) == nil)
                    let text = sharedToolText(await handler(dependencies, params))
                    let result = try #require(sharedJSONObject(text))
                    plan = .init(id: try #require(result["plan_id"] as? String),
                        digest: try #require(result["digest"] as? String), json: text)
                } else {
                    plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
                        names: names, capture: capture, request: retained.request, snapshotCurrent: true)
                }
                let body = try #require(sharedJSONObject(plan.json))
                let executable = try #require(body["executable"] as? Bool)
                if ["unread_scalar", "unread_range", "boolean_scalar", "unread_plugin", "unread_plugin_bypass"].contains(mode) {
                    if mode == "unread_scalar" || mode == "boolean_scalar" { #expect(capture.channelStrips[0].pan == 0, "The legacy fallback is not an observed protected baseline") }
                    #expect(!executable)
                    #expect(f.routingDestinationPresses == 0)
                    return
                }
                #expect(executable)
                if composed {
                    let combined = try #require(body["steps"] as? [[String: Any]])
                    #expect(combined.count == (mode == "coupled_same" ? 1 : 2))
                    #expect(combined.map { $0["kind"] as? String } == (mode == "coupled_same" ? ["local_output"] : ["name", "local_output"]))
                    #expect(combined.allSatisfy { $0["target_ref"] as? String == target.rawValue })
                    #expect(f.routingDestinationPresses == 0, "Preview never actuates either goal")
                }
                if ["absent_pan", "occupied_peer", "late_peer_send"].contains(mode), body["executable"] as? Bool != true { return }
                let steps = try #require(body["steps"] as? [[String: Any]])
                #expect(steps.count == (composed && mode != "coupled_same" ? 2 : 1) && steps[0]["target_ref"] as? String == target.rawValue)
                #expect((steps.last?["before"] as? [String: Any])?["kind"] as? String == (mode == "stereo" ? "physical" : "stereo_output"))
                #expect((steps.last?["after"] as? [String: Any])?["kind"] as? String == (mode == "stereo" || mode == "no_op" ? "stereo_output" : "physical"))
                #expect(await cache.retainRepairPlan(plan, snapshotID: id))
                let journal = SagaJournal(), key = "captured-physical-output-" + mode
                let approval = try #require(await ApprovedSessionRepair.retained(id: plan.id, digest: plan.digest,
                    key: key, cache: cache, registry: registry, journal: journal))
                #expect(approval.plan.steps.count == (composed && mode != "coupled_same" ? 2 : 1) && approval.plan.steps.last?.operationID == .mixerSetOutputVerified)
                #expect(approval.plan.steps[0].targetRef == target)
                let router = ChannelRouter()
                if cancelsAfterName {
                    await router.register(SendRemovalSagaResultBoundary(base: f.channel(), journal: journal,
                        mode: "cancel", operation: "track.rename", idempotencyKey: key,
                        afterForward: {
                            guard f.routingNameWrites.count == 1 else { return }
                            f.routingLateScopeInjected = true
                            if mode.hasSuffix("_peer") {
                                f.builder.setAttribute(f.builder.element(1_973_121), kAXValueAttribute as String, NSNumber(value: 0.4))
                            } else if mode.hasSuffix("_project") {
                                f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            } else if mode.hasSuffix("_source") {
                                let replacement = f.builder.element(1_971_409)
                                f.builder.setRole(replacement, kAXLayoutItemRole as String)
                                f.builder.setChildren(replacement, f.builder.makeAXRuntime().children(f.strips[1]))
                                f.builder.setChildren(f.mixer, [f.strips[0], replacement])
                            }
                        }, observedResult: { response in
                            f.routingOutputChannelStates.append(sharedJSONObject(response.message)?["state"] as? String ?? "unknown")
                        }))
                } else if uncoupled {
                    await router.register(SelectedOutputSagaResultBoundary(f.channel(), shouldFail: compensatesBoth,
                        observedName: { response in
                            f.routingNameChannelStates.append(sharedJSONObject(response.message)?["state"] as? String ?? "unknown")
                        }))
                } else if mode.hasPrefix("coupled_menu_overlay_census") {
                    await router.register(SelectedOutputSagaResultBoundary(f.channel(), shouldFail: mode.hasSuffix("second_failure"), observed: { response in
                        f.routingOutputChannelStates.append(sharedJSONObject(response.message)?["state"] as? String ?? "unknown")
                    }))
                } else if mode == "coupled_second_failure" || mode == "coupled_menu_overlay_second_failure" {
                    await router.register(SelectedOutputSagaResultBoundary(f.channel()))
                } else { await router.register(f.channel()) }
                let applyDependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                    poller: StatePoller(axChannel: f.channel(), cache: cache, runtime: .init(hasVisibleWindow: { false })),
                    dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal,
                    mutationGate: LogicMutationGate(), liveTrackNames: { [:] }, projectFileReader: .unavailable)
                let applyHandler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "apply_session_repair"))
                let approvedParams: [String: Value] = ["plan_id": .string(plan.id), "digest": .string(plan.digest),
                    "confirmed": .bool(true), "idempotency_key": .string(key)]
                if composed {
                    for (field, value) in [("confirmed", Value.bool(false)), ("digest", Value.string(String(repeating: "0", count: 64)))] {
                        var rejectedParams = approvedParams
                        rejectedParams[field] = value
                        let rejected = try #require(sharedJSONObject(sharedToolText(await applyHandler(applyDependencies, rejectedParams))))
                        #expect(rejected["state"] as? String == "C")
                        #expect(f.routingNameWrites.isEmpty && f.routingDestinationPresses == 0)
                    }
                }
                func run() async -> CallTool.Result {
                    if mode == "coupled" || mode == "coupled_same" || menuOverlay {
                        return await applyHandler(applyDependencies, approvedParams)
                    }
                    return await SystemDispatcher.handle(command: "saga_execute", params: [:], router: router,
                        cache: cache, targetRegistry: registry, dialogPresent: { false }, sagaJournal: journal,
                        mutationGate: LogicMutationGate(), sagaRefreshAfterWrite: {
                            if composed, f.routingNameWrites.count == 1, f.routingDestinationPresses == 0, !f.routingLateScopeInjected {
                                if mode == "coupled_newer_name" {
                                    f.routingLateScopeInjected = true
                                    f.builder.setAttribute(nameField, kAXDescriptionAttribute as String, "External")
                                    f.builder.setAttribute(f.builder.element(1_965_711), kAXValueAttribute as String, "External")
                                } else if mode == "coupled_late_peer" {
                                    f.routingLateScopeInjected = true
                                    f.builder.setAttribute(f.builder.element(1_973_121), kAXValueAttribute as String, NSNumber(value: 0.4))
                                } else if mode == "coupled_project" {
                                    f.routingLateScopeInjected = true
                                    f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                                }
                            }
                            if ["coupled_cancel", "coupled_retired", "coupled_retired_editor"].contains(mode), f.routingDestinationPresses == 1 {
                                _ = await journal.cancel(idempotencyKey: key)
                            }
                            if mode == "census_foreign", let peer = f.routingOtherReplacement {
                                f.routingLateScopeInjected = true
                                f.routingOtherReplacement = redrawPeer(peer, key: 1_975_200)
                                f.builder.setChildren(f.mixer, [f.routingOtherReplacement!, f.routingReplacement ?? f.strips[1]])
                            }
                            if mode == "post_write_loss" {
                                f.routingLateScopeInjected = true
                                f.builder.setAttribute(f.builder.element(1_973_121), kAXValueAttribute as String, NSNumber(value: 0.4))
                            }
                            if mode == "newer" {
                                f.builder.setAttribute(outputs[1], kAXDescriptionAttribute as String, "Output 5-6")
                            }
                            if ["cancel", "newer", "ack_only"].contains(mode) { _ = await journal.cancel(idempotencyKey: key) }
                        }, sagaLiveReadback: .unavailable, approvedSessionRepair: approval)
                }
                let result = try #require(sharedJSONObject(sharedToolText(await run())))
                if refusingSampledTrackOwnership {
                    #expect(f.footprintDocumentInjected && f.footprintDocumentRestored,
                        "Reach the initial Track-document sample and keep its contradiction until actual name extraction")
                    #expect(result["saga_state"] as? String != "completed")
                    let verified = try #require(result["verified"] as? Bool)
                    #expect(!verified)
                    #expect(f.routingDestinationPresses == 0,
                        "A restored final scope cannot authorize output from foreign/unknown sampled Track ownership")
                    #expect(f.routingNameWrites == ["Selected Canonical"])
                    return
                }
                if cancelsAfterName {
                    #expect(f.routingOutputChannelStates.first == "A", "Reach the actual verified name channel before cancellation")
                    #expect(f.routingLateScopeInjected)
                    let healthy = mode.hasSuffix("_healthy")
                    #expect(result["saga_state"] as? String == (healthy ? "fullyCompensated" : "rollbackUncertain"))
                    #expect(f.routingDestinationPresses == 0, "A pending cancellation cannot start the output writer")
                    #expect(f.routingNameWrites == (healthy ? ["Selected Canonical", "Duplicate"] : ["Selected Canonical"]))
                    if healthy {
                        #expect(f.builder.attributeValue(f.builder.element(1_965_711), kAXValueAttribute as String) as? String == "Duplicate")
                        guard case .cancelled(_, verified: true)? = await journal.record(for: key) else {
                            Issue.record("The actual journal must retain verified owned compensation"); return
                        }
                    }
                    let writes = f.routingNameWrites
                    let replay = try #require(sharedJSONObject(sharedToolText(await run())))
                    if healthy {
                        #expect(replay["state"] as? String == "C")
                    } else {
                        #expect(replay["state"] as? String == "B")
                        let duplicate = try #require(replay["duplicate"] as? Bool)
                        #expect(duplicate)
                    }
                    #expect(f.routingNameWrites == writes && f.routingDestinationPresses == 0)
                    return
                }
                if mode.hasPrefix("coupled_menu_overlay_census"), ["census", "census_second_failure"].contains(censusMode) {
                    #expect(f.routingOutputChannelStates.first == "A", "Reach the verified real channel before judging the owned-name continuation")
                }
                if composed {
                    if ["census_scalar", "census_input", "census_send", "census_plugin", "census_header", "census_project"].contains(censusMode) {
                        #expect(f.routingLateScopeInjected, "Reach the actual post-write protected-state change")
                        #expect(result["saga_state"] as? String != "completed")
                        let verified = try #require(result["verified"] as? Bool)
                        #expect(!verified)
                        #expect(f.routingDestinationPresses == 1, "No guessed inverse may follow the changed protected footprint")
                        #expect(f.routingNameWrites == ["Selected Canonical"])
                        return
                    }
                    if f.routingFocusClickFault != nil || newerUncoupled || ["coupled_newer_name", "coupled_late_peer", "coupled_project", "coupled_name_leaf_peer", "coupled_foreign_editor", "coupled_late_editor", "coupled_late_confirm", "coupled_menu_overlay_foreign_rail", "coupled_menu_overlay_missing_header", "coupled_menu_overlay_peer_change", "coupled_menu_overlay_late_editor"].contains(mode)
                        || (menuOverlay && (mode.contains("_post_") || mode.hasSuffix("_restore_ack_only"))) {
                        if f.routingFocusClickFault == nil { #expect(f.routingLateScopeInjected) }
                        #expect(result["saga_state"] as? String != "completed")
                        let verified = try #require(result["verified"] as? Bool)
                        #expect(!verified)
                        #expect(f.routingDestinationPresses == 0)
                        #expect(f.routingNameWrites == (["coupled_name_leaf_peer", "coupled_foreign_editor", "coupled_late_editor", "coupled_menu_overlay_foreign_rail", "coupled_menu_overlay_missing_header", "coupled_menu_overlay_peer_change", "coupled_menu_overlay_late_editor"].contains(mode) ? [] : ["Selected Canonical"]))
                        if mode == "coupled_late_peer" || mode == "coupled_name_leaf_peer" {
                            #expect(f.builder.attributeValue(f.builder.element(1_973_121), kAXValueAttribute as String) as? NSNumber == NSNumber(value: 0.4))
                        }
                        if newerUncoupled {
                            #expect(f.builder.attributeValue(f.builder.element(1_965_711), kAXValueAttribute as String) as? String
                                == (mode.hasSuffix("newer_primary") ? "Duplicate" : mode.hasSuffix("reverted_mirror") ? "Selected Canonical" : "External"))
                            if mode.hasSuffix("newer_primary") {
                                #expect(f.builder.attributeValue(nameField, kAXDescriptionAttribute as String) as? String == "External")
                            }
                        }
                    } else {
                        #expect(result["saga_state"] as? String == (compensatesBoth ? "fullyCompensated" : "completed"), "\(result)")
                        #expect(f.routingDestinationPresses == (compensatesBoth ? 2 : 1))
                        #expect(f.routingNameWrites == (mode == "coupled_same" ? [] : compensatesBoth ? ["Selected Canonical", "Duplicate"] : ["Selected Canonical"]))
                        #expect(f.builder.attributeValue(f.builder.element(1_965_711), kAXValueAttribute as String) as? String == (uncoupled || compensatesBoth || mode == "coupled_same" ? "Duplicate" : "Selected Canonical"))
                        if menuOverlay {
                            let verified = try #require(result["verified"] as? Bool)
                            if compensatesBoth { #expect(!verified) } else { #expect(verified) }
                        }
                    }
                    let presses = f.routingDestinationPresses, writes = f.routingNameWrites
                    let replay = try #require(sharedJSONObject(sharedToolText(await run())))
                    if !["coupled_cancel", "coupled_retired", "coupled_retired_editor"].contains(mode) {
                        let duplicate = try #require(replay["duplicate"] as? Bool)
                        #expect(duplicate)
                    }
                    #expect(f.routingDestinationPresses == presses && f.routingNameWrites == writes)
                    return
                }
                if mode == "census_redraw" {
                    #expect(((result["steps"] as? [[String: Any]])?.first?["result"] as? [String: Any])?["state"] as? String == "A",
                        "Reach the actually verified scalar write before judging the independent aggregate proof")
                }
                if ["late_peer", "late_project", "late_peer_send"].contains(mode) {
                    #expect(f.routingLateScopeInjected, "Reach the protected peer mutation during this source's popup")
                    if mode == "late_peer" { #expect(f.builder.attributeValue(f.window, kAXDocumentAttribute as String) as? String == f.bundle.absoluteString) }
                    #expect(pair.strip.currentIndex(runtime: f.logic()) == (mode == "late_project" ? nil : 1))
                    #expect(f.routingDestinationPresses == 0, "Unchanged source and document alone cannot authorize the changed footprint")
                    #expect(result["saga_state"] as? String != "completed")
                } else if mode == "unoffered_physical" {
                    #expect(f.inputMenuPresses > 1, "The actual source menu must be read before refusing a missing destination")
                    #expect(f.routingDestinationPresses == 0)
                    #expect(result["saga_state"] as? String != "completed")
                } else if mode == "newer" || mode == "ack_only" || mode == "post_write_loss" || (redrawsCensus && mode != "census_redraw") {
                    #expect(f.routingDestinationPresses == 1, "An unverified or newer value cannot authorize compensation")
                    #expect(result["saga_state"] as? String != "completed")
                    if redrawsCensus { #expect(f.routingLateScopeInjected) }
                    if mode == "post_write_loss" {
                        #expect(f.routingLateScopeInjected)
                        let verified = try #require(result["verified"] as? Bool)
                        #expect(!verified, "A scalar State A cannot replace the lost independent whole-footprint proof")
                    }
                } else {
                    #expect(result["saga_state"] as? String == (mode == "cancel" ? "fullyCompensated" : "completed"))
                    let verified = try #require(result["verified"] as? Bool)
                    if mode == "cancel" { #expect(!verified) } else { #expect(verified) }
                    if mode != "cancel" {
                    let evidence = try #require((result["steps"] as? [[String: Any]])?.last?["evidence"] as? [String: Any])
                        let verification = try #require(evidence["verification"] as? [String: Any])
                        let readback = try #require(verification["readback"] as? [String: Any])
                        #expect(readback["provenance"] as? String == "live_independent")
                        let equal = try #require((verification["comparison"] as? [String: Any])?["equal"] as? Bool)
                        #expect(equal)
                    }
                    #expect(f.routingDestinationPresses == (mode == "cancel" ? 2 : mode == "no_op" ? 0 : 1))
                }
                #expect(f.builder.attributeValue(outputs[1], kAXDescriptionAttribute as String) as? String
                    == (mode == "newer" ? "Output 5-6" : composed || redrawsCensus || ["forward", "retired", "absent_pan", "occupied_peer", "known_plugin", "post_write_loss", "unassigned_physical"].contains(mode) ? "Output 3-4" : "Stereo Output"))
                if composed {
                    #expect(f.routingNameWrites == ["Selected Canonical"])
                    #expect(f.builder.attributeValue(f.builder.element(1_965_711), kAXValueAttribute as String) as? String == "Selected Canonical")
                }
                #expect(f.builder.attributeValue(outputs[0], kAXDescriptionAttribute as String) as? String == (["stereo", "unassigned_physical", "unoffered_physical"].contains(mode) ? "Stereo Output" : "Output 3-4"))
                if mode == "retired" {
                    #expect(pair.strip.currentIndex(runtime: f.logic()) == nil)
                    #expect(f.routingReplacement != nil && !f.selections.isEmpty, "Renewal must re-observe the original header's actual pair")
                }
                if redrawsCensus {
                    #expect((f.routingReplacement == nil) == survivingSource && f.routingOtherReplacement != nil)
                    #expect(pair.strip.currentIndex(runtime: f.logic()) == (survivingSource && mode != "census_project" ? 1 : nil))
                    #expect(capture.channelStrips[0].physicalBinding?.currentIndex(runtime: f.logic()) == nil)
                    let oldPeerName = try #require(f.builder.makeAXRuntime().children(f.strips[0]).first)
                    let stillContainsOldName = try #require(f.routingOtherReplacement.map {
                        f.builder.makeAXRuntime().children($0).contains { CFEqual($0, oldPeerName) }
                    })
                    #expect(!stillContainsOldName, "The peer's old controls also retire; names/ordinals do not supply the renewed owner")
                }
                let selected = try #require(AXValueExtractors.extractSelectedState(f.headers[0], runtime: f.logic().ax))
                #expect(selected)
                let request = try #require(ApprovedSessionRepair.ApplyRequest.parse([
                    "plan_id": .string(plan.id), "digest": .string(plan.digest), "confirmed": .bool(true),
                    "idempotency_key": .string(key)]))
                let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                    poller: StatePoller(axChannel: f.channel(), cache: cache, runtime: .init(hasVisibleWindow: { false })),
                    dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal,
                    mutationGate: LogicMutationGate(), liveTrackNames: { [:] }, projectFileReader: .unavailable)
                let presses = f.routingDestinationPresses
                let replay = try #require(sharedJSONObject(sharedToolText(await ApprovedSessionRepair.apply(request: request, dependencies: dependencies))))
                let duplicate = try #require(replay["duplicate"] as? Bool)
                #expect(duplicate)
                #expect(f.routingDestinationPresses == presses)
            }
        }
    }

    @Test("Association-only acquisition omits unrequested routing classification without replacing observed scalars",
          arguments: ["association_only", "strips", "routing", "default"])
    func registeredAssociationAcquisitionReadsOnlyRequestedRouting(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture(withViewport: true)
            var routingControls: [AXUIElement] = []
            for index in f.strips.indices {
                let volume = f.builder.element(1_966_100 + index * 10), pan = f.builder.element(1_966_101 + index * 10)
                for (control, description, value, minimum) in [(volume, "Volume", 0.7, 0.0), (pan, "Pan", -0.25, -1.0)] {
                    f.builder.setRole(control, kAXSliderRole as String)
                    f.builder.setAttribute(control, kAXDescriptionAttribute as String, description)
                    f.builder.setAttribute(control, kAXValueAttribute as String, NSNumber(value: value))
                    f.builder.setAttribute(control, kAXMinValueAttribute as String, NSNumber(value: minimum))
                    f.builder.setAttribute(control, kAXMaxValueAttribute as String, NSNumber(value: 1.0))
                    f.builder.setChildren(control, [])
                }
                let output = f.builder.element(1_966_102 + index * 10), input = f.builder.element(1_966_103 + index * 10)
                let send = f.builder.element(1_966_104 + index * 10)
                for (control, description, help) in [
                    (output, "Stereo Output", "Output slot. Choose the channel strip output."),
                    (input, "Bus 1", "Input slot. Choose the channel strip input."),
                    (send, "send button", "Send slot. Choose the channel strip send.")
                ] {
                    f.builder.setButton(control, description: description, help: help, x: 0, y: 0, width: 1, height: 1)
                    f.builder.setChildren(control, [])
                    routingControls.append(control)
                }
                f.builder.setChildren(f.strips[index], f.builder.makeAXRuntime().children(f.strips[index]) + [volume, pan, output, input, send])
            }
            f.routingClassifierControls = routingControls
            f.routingRead = { element, attribute in
                // These exact leaf controls need no Inspector/discovery Help.
                // StripHelpSamples clears its TaskLocal while invoking the native provider.
                if attribute == kAXHelpAttribute as String,
                   f.routingClassifierControls.contains(where: { CFEqual($0, element) }) { f.routingClassifierHelpReads += 1 }
            }
            let cache = StateCache()
            let domains: [String]? = kind == "default" ? nil : kind == "association_only" ? ["associations"] : ["associations", kind]
            let body = try await inspect(f, cache: cache, domains: domains)
            let captureID = try #require(body["snapshot_id"] as? String)
            let retained = try #require(await cache.retainedInspection(id: captureID))
            let strips = retained.capture.channelStrips
            #expect(strips.count == 2 && strips.allSatisfy { $0.physicalBinding != nil && $0.name == "Duplicate" })
            #expect(strips.allSatisfy { $0.volume == 0.7 && $0.pan == -0.25 })
            #expect(await cache.getChannelStrips().allSatisfy { $0.volume == 0.7 && $0.pan == -0.25 })
            #expect(retained.capture.freshPopulation?.selectionAssociations.count == 2)
            #expect(f.selections == [1, 0] && (body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
            if kind == "association_only" {
                #expect(f.routingClassifierHelpReads == 0)
                #expect(strips.allSatisfy { $0.output == nil && $0.input == nil && $0.inputObservation == nil && $0.inputSlotBinding == nil && $0.sendSlots == nil })
                #expect((body["strips"] as? [String: Any])?["coverage"] as? String != "complete")
            } else {
                #expect(f.routingClassifierHelpReads > 0)
                #expect(strips.allSatisfy { $0.output == "Stereo Output" && $0.input == "Bus 1" && $0.inputObservation?.state == .observedSource && $0.sendSlots != nil })
            }
        }
    }

    @Test("A complete fresh track population qualifies only its fully observed physical associations",
          arguments: ["complete", "count_gap", "missing_pair", "hidden"])
    func completeFreshPopulationQualifiesAllObservedAssociations(fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture(withViewport: true, fourTracks: true)
            if fault == "missing_pair" { f.thirdRetainsPreviousFocus = true }
            let split = f.builder.element(1_966_000), headerSplit = f.builder.element(1_966_001)
            let legendSplit = f.builder.element(1_966_002), headerScroll = f.builder.element(1_966_003)
            let legend = f.builder.element(1_966_004), hide = f.builder.element(1_966_005)
            let workspace = f.builder.element(1_966_006), content = f.builder.element(1_966_007)
            let vertical = f.builder.element(1_966_008)
            for element in [split, headerSplit, legendSplit] {
                f.builder.setRole(element, kAXSplitGroupRole as String)
            }
            f.builder.setRole(headerScroll, kAXScrollAreaRole as String)
            f.builder.setFrame(headerScroll, x: 0, y: 0, width: 200, height: 200)
            f.builder.setRole(f.rail, kAXGroupRole as String)
            f.builder.setAttribute(f.rail, kAXDescriptionAttribute as String, "Tracks header")
            for (index, header) in f.headers.enumerated() {
                f.builder.setFrame(header, x: 0, y: CGFloat(index * 40), width: 200, height: 40)
            }
            f.builder.setRole(legend, kAXGroupRole as String)
            f.builder.setRole(hide, kAXCheckBoxRole as String)
            f.builder.setAttribute(hide, kAXDescriptionAttribute as String, "Show/Hide Hidden Tracks   H")
            f.builder.setAttribute(hide, kAXValueAttribute as String, NSNumber(value: fault == "hidden" ? 0 : 1))
            f.builder.setAttribute(hide, kAXWindowAttribute as String, f.window)
            f.builder.setChildren(hide, [])
            f.builder.setChildren(legend, [hide])
            f.builder.setRole(workspace, kAXScrollAreaRole as String)
            f.builder.setRole(content, kAXGroupRole as String)
            f.builder.setAttribute(content, kAXDescriptionAttribute as String, "Tracks contents")
            f.builder.setChildren(content, [])
            f.builder.setRole(vertical, kAXScrollBarRole as String)
            f.builder.setAttribute(vertical, kAXOrientationAttribute as String, kAXVerticalOrientationValue as String)
            f.builder.setAttribute(vertical, kAXEnabledAttribute as String, NSNumber(value: false))
            f.builder.setAttribute(vertical, kAXValueAttribute as String, NSNumber(value: 0))
            f.builder.setAttribute(vertical, kAXWindowAttribute as String, f.window)
            f.builder.setChildren(vertical, [])
            f.builder.setChildren(workspace, [content, vertical])
            f.builder.setChildren(headerScroll, [f.rail])
            f.builder.setChildren(headerSplit, [headerScroll, workspace])
            f.builder.setChildren(legendSplit, [legend])
            f.builder.setChildren(split, [legendSplit, headerSplit])
            f.builder.setChildren(f.window, [split, f.mixer, f.builder.element(1_965_720), f.scroll])
            let data = try PropertyListSerialization.data(fromPropertyList: ["NumberOfTracks": fault == "count_gap" ? 5 : 4],
                                                         format: .xml, options: 0)
            let reader = LogicProjectFileReader.Runtime(currentDocumentPath: { nil }, now: Date.init,
                readPlistData: { _ in data }, mtime: { _ in Date(timeIntervalSince1970: 0) }, sleep: { _ in })
            let body = try await inspect(f, fileReader: reader, domains: ["tracks", "associations"])
            let tracks = try #require(body["tracks"] as? [String: Any])
            let associations = try #require(body["associations"] as? [String: Any])
            let pairs = try #require(associations["rows"] as? [[String: Any]])
            if fault == "complete" {
                #expect(tracks["coverage"] as? String == "complete")
                #expect(pairs.count == 4)
                #expect(associations["coverage"] as? String == "complete")
                #expect(associations["reasons"] as? [String] == [])
                let overall = try #require(body["overall"] as? [String: Any])
                let complete = try #require(overall["complete"] as? Bool)
                #expect(complete)
            } else {
                #expect(associations["coverage"] as? String == "partial")
                #expect(associations["reasons"] as? [String] == ["association_population_not_observed"])
                if fault == "missing_pair" {
                    #expect(tracks["coverage"] as? String == "complete")
                    #expect(pairs.count < 4)
                } else {
                    #expect(tracks["coverage"] as? String == "partial")
                    #expect(pairs.count == 4)
                }
            }
            #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        }
    }

    @Test func retainedMixerPairUsesActualCaptureAndExactPhysicalReferenceOnly() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture()
            let cache = StateCache()
            let registry = TargetRegistry()
            let body = try await inspect(f, cache: cache, registry: registry)
            let id = try #require(body["snapshot_id"] as? String)
            let retained = try #require(await cache.retainedInspection(id: id))
            let pair = try #require(retained.capture.freshPopulation?.selectionAssociations.first)
            let row = try #require(retained.capture.channelStrips.indices.first {
                retained.capture.channelStrips[$0].physicalBinding?.matches(pair.strip) == true
            })
            let ref = try #require(retained.capture.mixerReference(at: row))
            let source = try #require(await registry.resolve(ref)?.physicalMixerStrip)
            let found = try #require(await cache.retainedMixerAssociation(
                reference: ref, source: source, snapshot: await registry.currentSnapshot))
            #expect(found.track.matches(pair.track) && found.strip.matches(source))
            #expect(await cache.retainedMixerAssociation(reference: .init(rawValue: "mix_unissued"),
                source: source, snapshot: await registry.currentSnapshot) == nil)
            let other = AXMixerStripBinding.Binding(window: source.window, mixer: source.mixer,
                strip: f.builder.element(1_965_999), document: source.document)
            #expect(await cache.retainedMixerAssociation(reference: ref, source: other,
                snapshot: await registry.currentSnapshot) == nil)
            await registry.bumpTopologyGeneration()
            #expect(await cache.retainedMixerAssociation(reference: ref, source: source,
                snapshot: await registry.currentSnapshot) == nil)
        }
    }

    @Test("A No Output after-read renews a surviving source's stale label only through its original header",
          arguments: ["refreshed", "mismatch", "missing_pair", "lost_inverse", "late_document", "changed_header", "late_population"])
    func noOutputAfterReadRenewsSurvivingOriginalSource(fault: String) async throws {
        let f = try Fixture(), b = f.builder
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let output = b.element(1_325_001), root = b.element(1_325_002), echo = b.element(1_325_003)
        let leaf = b.element(1_325_004), parent = b.element(1_325_005)
        let submenu = b.element(1_325_006), stereo = b.element(1_325_007)
        b.setButton(output, description: "Stereo Output", help: "Output slot. Choose the channel strip output.",
                    x: 0, y: 0, width: 60, height: 20)
        b.setChildren(output, []); b.setActionNames(output, [kAXPressAction as String])
        b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]) + [output])
        for menu in [root, submenu] { b.setRole(menu, kAXMenuRole as String) }
        for (item, title) in [(echo, "Stereo Output"), (leaf, "No Output"), (parent, "Output"), (stereo, "Stereo Output")] {
            b.setRole(item, kAXMenuItemRole as String)
            b.setAttribute(item, kAXTitleAttribute as String, title)
            b.setAttribute(item, kAXEnabledAttribute as String, true); b.setChildren(item, [])
        }
        for item in [echo, stereo] { b.setAttribute(item, "AXMenuItemMarkChar", "✓") }
        b.setChildren(submenu, [stereo]); b.setChildren(parent, [submenu]); b.setChildren(root, [echo, leaf, parent])
        f.routingAction = { element, action in
            guard action == kAXPressAction as String else { Issue.record("No cleanup fallback is authorized"); return false }
            if CFEqual(element, output) { b.setChildren(f.mixer, f.strips + [root]); return true }
            guard CFEqual(element, leaf) else { Issue.record("Only the original output and unique destination may be pressed"); return false }
            f.routingDestinationPresses += 1
            b.setChildren(f.mixer, f.strips)
            b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.strips[1])
            // The host committed the change, but this exact surviving slot
            // continues to report its old label until original-header acquisition.
            if fault == "changed_header" {
                let replacement = b.element(1_325_008)
                b.setRole(replacement, kAXLayoutItemRole as String); b.setChildren(replacement, [])
                b.setChildren(f.rail, [replacement, f.headers[1]])
                f.routingLateScopeInjected = true
            }
            return true
        }
        f.routingSelection = { index in
            guard f.routingDestinationPresses == 1 else { return }
            if fault == "lost_inverse" {
                b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                f.routingLateScopeInjected = true
            } else if index == 0, fault != "mismatch" {
                b.setAttribute(output, kAXDescriptionAttribute as String, "No Output")
                if fault == "late_population" {
                    let added = b.element(1_325_009)
                    b.setRole(added, kAXLayoutItemRole as String); b.setChildren(added, [])
                    b.setChildren(f.mixer, f.strips + [added])
                    f.routingLateScopeInjected = true
                }
            }
        }
        f.routingRead = { element, attribute in
            if fault == "late_document", f.selections.count >= 4,
               CFEqual(element, output), attribute == kAXDescriptionAttribute as String {
                b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                f.routingLateScopeInjected = true
            }
        }
        let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_output_verified", mutationGate: LogicMutationGate()) {
            let runtime = f.logic()
            guard let observation = AccessibilityChannel.HeldSelectionAssociation(window: f.window, logic: runtime,
                expectedProject: nil, requiresProjectReference: false) else { Issue.record("Original acquisition must start"); return toolTextResult(.error("fixture")) }
            let pairs = await observation.observe(referenceIsCurrent: { true }, stoppingWhen: { false }, allHeldHeaders: true)
            guard let pair = pairs.first(where: { CFEqual($0.track.header, f.headers[0]) }), observation.effects.restoration == "restored"
            else { Issue.record("Original source requires its actual restored header association"); return toolTextResult(.error("fixture")) }
            b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.window)
            return await AXMixerStripBinding.$current.withValue(pair.strip) {
                await AXMixerStripBinding.$outputAssociation.withValue(fault == "missing_pair" ? nil : pair) {
                    toolTextResult(await AccessibilityChannel.setOutputVerified(params: ["index": "1", "destination": "no_output", "expected_current": "stereo_output"],
                        runtime: runtime, timing: .immediate))
                }
            }
        }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["state"] as? String == (fault == "refreshed" ? "A" : "B"), "Actual writer receipt: \(body)")
        let attempted = try #require(body["write_attempted"] as? Bool); #expect(attempted)
        #expect(f.routingDestinationPresses == 1, "After-read acquisition must never retry the setter")
        if fault == "refreshed" {
            #expect(body["after"] as? [String: String] == ["kind": "no_output"])
            #expect(f.selections == [1, 0, 1, 0])
            let reread = try #require(body["reference_reread_required"] as? Bool); #expect(reread)
        }
        if ["lost_inverse", "late_document", "changed_header", "late_population"].contains(fault) { #expect(f.routingLateScopeInjected) }
    }

    @Test(arguments: ["paired", "missing_pair", "replaced_header", "foreign_project", "foreign_focus", "deciding_read", "partial_restore", "track_ref", "track_ref_missing_pair", "track_ref_replaced_strip", "rail", "rail_editor", "rail_missing_relationship", "rail_unselected_header"])
    func outputReadbackRenewsRetiredSourceOnlyThroughOriginalCapturedHeader(condition: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture()
            if condition.hasPrefix("track_ref") {
                f.builder.setAttribute(f.headers[0], kAXTitleAttribute as String, "Original")
                f.builder.setAttribute(f.headers[1], kAXTitleAttribute as String, "Other")
            }
            let captureNow = ContinuousClock.now
            let cache = StateCache(sessionCaptureNow: {
                f.expireRetainedCapture ? captureNow.advanced(by: StateCache.sessionCaptureLifetime) : captureNow
            }), registry = TargetRegistry()
            let output = f.builder.element(1_965_950), replacement = f.builder.element(1_965_951)
            let newOutput = f.builder.element(1_965_952), root = f.builder.element(1_965_953)
            let parent = f.builder.element(1_965_954), submenu = f.builder.element(1_965_955)
            let leaf = f.builder.element(1_965_956)
            let decoyOutput = f.builder.element(1_965_959)
            for (button, label) in [(output, "Stereo Output"), (newOutput, "Output 3-4"), (decoyOutput, "Stereo Output")] {
                f.builder.setButton(button, description: label, help: "Output slot. Choose the channel strip output.",
                    x: 0, y: 0, width: 1, height: 1)
                f.builder.setChildren(button, [])
            }
            f.builder.setChildren(f.strips[1], f.builder.makeAXRuntime().children(f.strips[1]) + [output])
            f.builder.setChildren(f.strips[0], f.builder.makeAXRuntime().children(f.strips[0]) + [decoyOutput])
            f.builder.setRole(replacement, kAXLayoutItemRole as String)
            f.builder.setAttribute(replacement, kAXNumberOfCharactersAttribute as String, 0)
            f.builder.setAttribute(replacement, kAXInsertionPointLineNumberAttribute as String, 0)
            f.builder.setChildren(replacement, [newOutput])
            for menu in [root, submenu] { f.builder.setRole(menu, kAXMenuRole as String) }
            for (item, title) in [(parent, "Output"), (leaf, "Output 3-4")] {
                f.builder.setRole(item, kAXMenuItemRole as String)
                f.builder.setAttribute(item, kAXTitleAttribute as String, title)
                f.builder.setAttribute(item, kAXEnabledAttribute as String, true)
            }
            f.builder.setChildren(leaf, []); f.builder.setChildren(submenu, [leaf])
            f.builder.setChildren(parent, [submenu]); f.builder.setChildren(root, [parent])
            if condition.hasPrefix("rail") {
                f.routingRead = { element, attribute in
                    guard f.routingReplacement != nil else { return }
                    if CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String {
                        f.builder.setAttribute(f.app, attribute, f.rail)
                    }
                    if CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String {
                        let selectedOther = AXValueExtractors.extractSelectedState(f.headers[1], runtime: f.builder.makeAXRuntime()) == true
                        f.builder.setAttribute(f.mixer, attribute, [selectedOther ? f.strips[0] : replacement])
                    }
                }
                f.routingReadResult = { element, attribute in
                    guard f.routingReplacement != nil else { return nil }
                    if CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String,
                       condition == "rail_missing_relationship" {
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    if CFEqual(element, f.rail), [kAXValueAttribute, kAXSelectedTextAttribute,
                        kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute].map({ $0 as String }).contains(attribute) {
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    return nil
                }
            }
            if condition == "deciding_read" {
                f.routingRead = { element, attribute in
                    if f.selections.count == 4, CFEqual(element, newOutput), attribute == kAXDescriptionAttribute as String {
                        f.routingLateScopeInjected = true
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                }
            } else if condition == "partial_restore" {
                f.routingSelection = { _ in
                    if f.selections.count == 3 {
                        f.routingLateScopeInjected = true
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                }
            }
            f.routingAction = { element, action in
                guard action == kAXPressAction as String else { Issue.record("unexpected routing action"); return false }
                if CFEqual(element, output) { f.builder.setChildren(f.mixer, f.strips + [root]); return true }
                if CFEqual(element, decoyOutput) {
                    f.routingWrongSourcePressed = true
                    f.builder.setChildren(f.mixer, f.strips + [root]); return true
                }
                if CFEqual(element, leaf) {
                    f.routingDestinationPresses += 1
                    if f.routingWrongSourcePressed {
                        f.builder.setAttribute(decoyOutput, kAXDescriptionAttribute as String, "Output 3-4")
                        f.builder.setChildren(f.mixer, f.strips)
                        return true
                    }
                    f.routingReplacement = replacement
                    f.builder.setChildren(f.mixer, [f.strips[0], replacement])
                    f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                        condition.hasPrefix("rail") ? f.rail : replacement)
                    if condition == "rail_editor" { f.builder.setRole(f.rail, kAXTextFieldRole as String) }
                    if condition == "rail_unselected_header" {
                        f.builder.setAttribute(f.headers[0], kAXSelectedAttribute as String, false)
                        f.builder.setAttribute(f.headers[1], kAXSelectedAttribute as String, true)
                    }
                    if condition == "replaced_header" {
                        let foreign = f.builder.element(1_965_957)
                        f.builder.setRole(foreign, kAXLayoutItemRole as String)
                        f.builder.setAttribute(foreign, kAXTitleAttribute as String, "Duplicate")
                        f.builder.setAttribute(foreign, kAXSelectedAttribute as String, true)
                        f.builder.setChildren(foreign, [])
                        f.builder.setChildren(f.rail, [foreign, f.headers[1]])
                    } else if condition == "foreign_project" {
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    } else if condition == "foreign_focus" {
                        let foreign = f.builder.element(1_965_958)
                        f.builder.setRole(foreign, kAXTextFieldRole as String)
                        f.builder.setAttributeSettable(foreign, kAXValueAttribute as String, true)
                        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, foreign)
                    }
                    return true
                }
                Issue.record("unowned routing action"); return false
            }
            let before = try await inspect(f, cache: cache, registry: registry)
            let id = try #require(before["snapshot_id"] as? String)
            let capture = try #require(await cache.retainedInspection(id: id)).capture
            let sourceRow = try #require(capture.channelStrips.indices.first {
                capture.channelStrips[$0].physicalBinding.map { CFEqual($0.strip, f.strips[1]) } == true
            })
            var target = try #require(capture.mixerReference(at: sourceRow))
            if condition.hasPrefix("track_ref") {
                let tracks = TrackReferenceIssuance.liveInventory(capture.tracks)
                let trackRow = try #require(tracks.indices.first {
                    tracks[$0].physicalBinding.map { CFEqual($0.header, f.headers[0]) } == true
                })
                target = try #require(capture.issued?.byRow[trackRow])
            }
            let project: String
            if case .issued(let issued)? = capture.projectIssuance { project = issued.rawValue }
            else { Issue.record("the actual capture must issue a project reference"); return }
            if condition == "missing_pair" || condition == "track_ref_missing_pair" { f.expireRetainedCapture = true }
            if condition == "track_ref_replaced_strip" {
                f.builder.setChildren(f.mixer, [f.strips[0], replacement])
                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, replacement)
            }
            let router = ChannelRouter(); await router.register(f.channel())
            let gate = LogicMutationGate()
            let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                poller: StatePoller(axChannel: f.channel(), cache: cache,
                    runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable,
                        keyboardFocus: { .notTextEditing })),
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
                liveTrackNames: { condition.hasPrefix("track_ref") ? [0: "Original", 1: "Other"] : [0: "Duplicate", 1: "Duplicate"] })
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "set_output_verified"))
            let params: [String: Value] = ["project_ref": .string(project), "target_ref": .string(target.rawValue),
                "destination": .object(["kind": .string("physical"), "ports": .array([.int(3), .int(4)])]),
                "expected_current": .object(["kind": .string("stereo_output")])]
            let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_output_verified",
                commandParams: params, mutationGate: gate) { await handler(dependencies, params) }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(!f.routingWrongSourcePressed, "An Arrange ordinal must never choose an unrelated physical Mixer strip")
            if condition == "track_ref_missing_pair" || condition == "track_ref_replaced_strip" {
                #expect(body["state"] as? String == "C")
                let wrote = try #require(body["write_attempted"] as? Bool)
                #expect(!wrote && f.routingDestinationPresses == 0)
                #expect(f.selections == [1, 0])
                return
            }
            let succeeds = condition == "paired" || condition == "track_ref" || condition == "rail"
            #expect(body["state"] as? String == (succeeds ? "A" : "B"), "Actual response: \(sharedToolText(result))")
            let verified = try #require(body["verified"] as? Bool)
            if succeeds {
                #expect(verified)
                let reread = try #require(body["reference_reread_required"] as? Bool)
                #expect(reread)
                #expect(body["source_renewal"] as? String == (condition == "rail"
                    ? "held_exclusive_selection_selected_child" : "held_exclusive_selection_focus"))
            } else { #expect(!verified) }
            #expect(f.routingReplacement != nil)
            let expectedSelections = condition == "partial_restore" ? [1, 0, 1]
                : ((succeeds || condition == "deciding_read") ? [1, 0, 1, 0] : [1, 0])
            #expect(f.selections == expectedSelections)
            if condition == "deciding_read" || condition == "partial_restore" { #expect(f.routingLateScopeInjected) }
            if condition == "partial_restore" {
                let effects = try #require(body["ui_effects"] as? [String: Any])
                #expect(effects["restoration"] as? String == "not_restored")
                let attempted = try #require(effects["attempted"] as? [String])
                #expect(attempted.contains("track_selection"))
            }
            #expect(f.routingDestinationPresses == 1)
            let refused = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_output_verified",
                commandParams: params, mutationGate: gate) { await handler(dependencies, params) }
            let refusal = try #require(sharedJSONObject(sharedToolText(refused)))
            #expect(refusal["state"] as? String == "C")
            let wrote = try #require(refusal["write_attempted"] as? Bool)
            #expect(!wrote && f.routingDestinationPresses == 1)
        }
    }

    @Test func occupiedSingleSendRenewsRetiredSourceThroughItsCapturedHeader() async throws {
        try await assertOccupiedSingleSendRenewal()
    }

    @Test func occupiedExistingBusSendRenewsOnlyItsCapturedSingleSlot() async throws {
        try await assertOccupiedSingleSendRenewal(existingBus: true)
    }

    @Test func occupiedExistingBusSendRefusesExpiredOriginalPairBeforeAnyLeaf() async throws {
        try await assertOccupiedSingleSendRenewal("expired_pair", existingBus: true)
    }

    @Test func registeredSendBypassReadsCapabilityAndChangesOnlyItsExactCheckbox() async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, bypassMode: "roundtrip")
    }

    @Test func registeredSendLevelUsesItsOwnedSemanticEditor() async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: "roundtrip")
    }

    @Test func registeredSendLevelKeepsSlowDiscoveryOutsideItsNativeClickPair() async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: "slow_pair")
    }

    @Test func registeredSendLevelKeepsWholeTransportWalkOutsideItsNativeClickPair() async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: "slow_transport_pair")
    }

    @Test func registeredSendLevelOwnsOnlyItsExactFirstClickFocusTransition() async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: "first_click_source_focus")
    }

    @Test func registeredSendLevelObservesItsDelayedFirstClickSourceFocus() async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: "first_click_deferred_source_focus")
    }

    @Test(arguments: ["first_click_foreign_focus", "first_click_document", "first_click_control", "first_click_play",
        "first_click_knob_window", "first_click_window_type", "first_click_window_unreadable", "first_click_population"])
    func registeredSendLevelFirstClickCannotAdoptForeignOrChangedCustody(_ fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: fault)
    }

    @Test(arguments: ["preflight", "failure", "cancel"])
    func registeredSendLevelSagaOwnsItsActualCompensation(_ outcome: String) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: "roundtrip", levelSaga: outcome)
    }

    @Test(arguments: ["no_observer", "lost_observer", "late_inverse_level", "late_inverse_document",
        "late_inverse_mode", "late_inverse_bypass", "late_inverse_peer", "late_inverse_control",
        "wrong_hash", "wrong_project", "wrong_target", "wrong_slot"])
    func registeredSendLevelSagaRefusesUnownedOrChangedEffects(_ fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: "roundtrip", levelSaga: fault)
    }

    @Test func registeredSendLevelCannotAdoptAPreexistingNumericWindow() async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: "preexisting_editor")
    }

    @Test func registeredSendLevelFinalHitCannotAuthorizeAnotherDocument() async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: "late_hit_document")
    }

    @Test(arguments: ["boolean_raw", "wrong_expected", "unsupported_level", "wrong_target", "wrong_project", "extra_param",
                      "scalar_level", "expired_deadline", "lost_gate", "wrong_hit", "editor_foreign", "editor_window",
                      "editor_value", "late_play", "late_record", "late_document", "changed_raw", "replaced_control"])
    func registeredSendLevelRefusesUnownedOrUnqualifiedEditor(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: fault)
    }

    @Test(arguments: ["noop", "minus95"])
    func registeredSendLevelKeepsQualifiedNormalizationAndNoop(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: mode)
    }

    @Test(arguments: ["setter_ack_only", "commit_ack_only", "source_lost_after", "route_changed_after", "no_editor", "incomplete_up"])
    func registeredSendLevelDoesNotInventReadbackOrInverse(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: mode)
    }

    @Test(arguments: ["deferred", "deferred_minus95"])
    func registeredSendLevelWaitsForOnlyItsExactDeferredEditor(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: mode)
    }

    @Test(arguments: ["deferred_foreign", "deferred_window", "deferred_source", "deferred_cancel", "deferred_never"])
    func registeredSendLevelDeferredCommitKeepsOwnershipAndBounds(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: mode)
    }

    @Test(arguments: ["return_window", "return_window_minus95", "return_window_before_fields",
        "return_window_before_fields_retired_peer"])
    func registeredSendLevelAcceptsOnlyItsObservedWindowReturn(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: mode)
    }

    @Test(arguments: ["return_window_foreign_focus", "return_window_foreign_window", "return_window_source", "return_window_gate",
        "return_window_before_fields_foreign_focus", "return_window_before_fields_foreign_window",
        "return_window_before_fields_source", "return_window_before_fields_new_window",
        "return_window_before_fields_duplicate_source"])
    func registeredSendLevelWindowReturnCannotReviveLostCustody(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, levelMode: mode)
    }

    @Test(arguments: [true, false])
    func registeredSendBypassObservesDelayedOwnedBitLanding(desired: Bool) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true,
            bypassMode: desired ? "delayed_on" : "delayed_off")
    }

    @Test(arguments: ["late_play", "late_record", "late_bit", "final_record_document"])
    func registeredSendBypassRefusesLateTransportAndBitChanges(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, bypassMode: fault)
    }

    @Test(arguments: ["malformed_binary", "wrong_expected", "wrong_target", "wrong_project", "extra_param",
                      "missing_target", "scalar_boolean", "negative_ordinal", "refs_disabled", "unsupported_press",
                      "changed_route", "changed_mode", "changed_raw", "replaced_control", "foreign_document",
                      "expired_deadline", "lost_gate", "malformed_after", "lost_source_after", "press_failed"])
    func registeredSendBypassPreservesTypedAndProtectedRefusals(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, bypassMode: fault)
    }

    @Test func registeredPhysicalOutputSendSagaCompletesAndReplaysWithoutAnotherWrite() async throws {
        try await assertOccupiedSingleSendRenewal(restoring: true,
            emptyModeMenu: true, sagaMode: "completed")
    }

    @Test func physicalSendSagaKeepsTheSharedPairValidationAndExactNativeScope() throws {
        func plan(_ destination: Value) -> SagaPlan {
            .init(steps: [.init(operationID: .mixerSetSendOutputVerified,
                targetRef: .init(rawValue: "mix_physical_send"), params: ["ordinal": .int(1),
                    "destination": destination, "expected_current": .object(["kind": .string("stereo_output")]),
                    "replace_existing": .bool(true)],
                expectedInverse: .init(operationID: .mixerSetSendOutputVerified, valueParameter: "destination"))],
                idempotencyKey: "physical-send-pair-contract")
        }
        func physical(_ ports: [Value]) -> Value {
            .object(["kind": .string("physical"), "ports": .array(ports)])
        }
        let accepted = plan(physical([.int(3), .int(4)]))
        #expect(SendRemovalSagaAdapter.accepts(accepted))
        #expect(SendRemovalSagaAdapter.journalValue(try #require(accepted.steps.first)) == .string("physical:3-4"))
        for ports: [Value] in [[.int(4), .int(3)], [.int(3), .int(3)], [.int(0), .int(4)], [.int(3)],
                               [.int(3), .int(4), .int(5)], [.bool(true), .int(4)], [.double(3.5), .int(4)],
                               [.string("3"), .int(4)]] {
            #expect(!SendRemovalSagaAdapter.accepts(plan(physical(ports))))
        }
        #expect(!SendRemovalSagaAdapter.accepts(plan(.object(["kind": .string("physical"),
            "ports": .array([.int(3), .int(4)]), "number": .int(1)]))))
        #expect(!SendRemovalSagaAdapter.accepts(plan(.object(["kind": .string("physical"),
            "ports": .array([.int(3), .int(4)]), "native_proof": .object([:])]))))
        var forgedCanonical = accepted
        forgedCanonical.canonicalPlanID = "unowned_plan"; forgedCanonical.canonicalDigest = "unowned_digest"
        #expect(!SendRemovalSagaAdapter.accepts(forgedCanonical))
    }

    @Test(arguments: ["failure", "cancel", "unverified"])
    func registeredPhysicalOutputSendSagaCompensatesOnlyItsActualNativeChange(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(restoring: true,
            emptyModeMenu: true, sagaMode: mode)
    }

    @Test(arguments: ["external_destination", "external_level", "external_mode", "replaced_control",
                      "unknown_after", "foreign_after", "no_observer", "lost_observer", "late_inverse_mode"])
    func registeredPhysicalOutputSendSagaCannotInvertUnobservedOrNewerState(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(restoring: true,
            emptyModeMenu: true, sagaMode: mode)
    }

    @Test(arguments: ["wrong_project", "wrong_target", "missing_confirmation", "wrong_confirmation", "invalid_later",
                      "multiple", "raw_level", "raw_bypass", "nondefault_mode", "expired_pair", "extra_param"])
    func registeredPhysicalOutputSendSagaRefusesInvalidRequestsBeforeAnyLeaf(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(restoring: true,
            emptyModeMenu: true, sagaMode: mode)
    }

    @Test(arguments: ["preflight", "wrong_project", "foreign_document", "refs_disabled"])
    func registeredPhysicalOutputSendSagaPreflightUsesActualRetainedCustody(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(restoring: true,
            emptyModeMenu: true, sagaMode: mode)
    }

    @Test(arguments: ["completed", "cancel", "failure", "unverified", "preflight",
                      "wrong_target", "wrong_project", "missing_confirmation", "wrong_confirmation", "extra_param",
                      "invalid_later", "multiple", "raw_level", "raw_bypass", "nondefault_mode", "expired_pair",
                      "external_destination", "external_level", "external_mode", "replaced_control",
                      "unknown_after", "foreign_after", "no_observer", "lost_observer", "late_inverse_mode"])
    func registeredFreshPhysicalSendReturnOwnsOnlyItsNewChange(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(restoring: true,
            emptyModeMenu: true, sagaMode: mode, freshPhysicalReturn: true)
    }

    @Test func freshPhysicalSendReturnKeepsItsTypedBeforeAndFiniteDirections() throws {
        func plan(_ before: Value) -> SagaPlan {
            .init(steps: [.init(operationID: .mixerSetSendOutputVerified,
                targetRef: .init(rawValue: "mix_fresh_physical_return"), params: ["ordinal": .int(1),
                    "destination": .object(["kind": .string("stereo_output")]),
                    "expected_current": before, "replace_existing": .bool(true)],
                expectedInverse: .init(operationID: .mixerSetSendOutputVerified, valueParameter: "destination"))],
                idempotencyKey: "fresh-physical-return")
        }
        let good = plan(.object(["kind": .string("physical"), "ports": .array([.int(3), .int(4)])]))
        #expect(SendRemovalSagaAdapter.accepts(good))
        #expect(SendRemovalSagaAdapter.journalValue(try #require(good.steps.first)) == .string("stereo_output"))
        for bad: Value in [
            .object(["kind": .string("physical"), "ports": .array([.int(4), .int(3)])]),
            .object(["kind": .string("physical"), "ports": .array([.bool(true), .int(4)])]),
            .object(["kind": .string("physical"), "ports": .array([.int(3), .int(4)]), "native_proof": .object([:])]),
            .object(["kind": .string("bus"), "number": .int(1)]),
            .object(["kind": .string("stereo_output")]),
            .object(["kind": .string("no_send")]),
            .string("physical:3-4"),
        ] { #expect(!SendRemovalSagaAdapter.accepts(plan(bad))) }
        var unowned = good
        unowned.canonicalPlanID = "unowned"; unowned.canonicalDigest = "unowned"
        #expect(!SendRemovalSagaAdapter.accepts(unowned))
    }

    @Test(arguments: ["failure", "cancel", "unverified"])
    func registeredExistingBusSendSagaCompensatesOnlyItsActualNativeChange(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true,
            emptyModeMenu: true, sagaMode: mode)
    }

    @Test(arguments: ["external_destination", "external_level", "external_mode", "replaced_control",
                      "unknown_after", "foreign_after", "no_observer", "lost_observer"])
    func registeredExistingBusSendSagaCannotInvertUnobservedOrNewerState(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true,
            emptyModeMenu: true, sagaMode: mode)
    }

    @Test func registeredExistingBusSendInverseRefusesModeChangedAtFinalOfferedLeaf() async throws {
        try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true,
            emptyModeMenu: true, sagaMode: "late_inverse_mode")
    }

    @Test(arguments: ["wrong_project", "wrong_target", "missing_confirmation", "wrong_confirmation", "invalid_later",
                      "multiple", "raw_level", "raw_bypass", "nondefault_mode", "expired_pair"])
    func registeredExistingBusSendSagaRefusesInvalidRequestsBeforeAnyLeaf(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true,
            emptyModeMenu: true, sagaMode: mode)
    }

    @Test(arguments: [OutputAssignment.bus(1), .physical(3, 4), .stereoOutput])
    func occupiedSendNoopRemainsObservedWithoutExpiredPair(destination: OutputAssignment) async throws {
        try await assertOccupiedSingleSendRenewal("expired_noop", existingBus: destination == .bus(1),
            noOpDestination: destination)
    }

    @Test func registeredSingleSendRemovalProvesOwnedRetirementAndSoleEmptyAfter() async throws {
        try await assertOccupiedSingleSendRenewal(removing: true)
    }

    @Test func survivingSingleSendRemovalRetainsOriginalSourceAndHeaderProof() async throws {
        try await assertOccupiedSingleSendRenewal(removing: true, survivingSource: true)
    }

    @Test(arguments: ["healthy_sibling_replaced", "healthy_occupied", "healthy_unreadable", "healthy_header_retired"])
    func survivingSingleSendRemovalRefusesChangedFootprintOrOwnership(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(fault, removing: true, survivingSource: true)
    }

    @Test func typedRemovedSendInverseRestoresOnlyItsRetainedSoleEmptyBinding() async throws {
        try await assertOccupiedSingleSendRenewal(removing: true, restoring: true)
    }

    @Test func typedRemovedSendInverseReadsDisabledEmptyMenuModesBeforeRestoring() async throws {
        try await assertOccupiedSingleSendRenewal(removing: true, restoring: true,
            survivingSource: true, emptyModeMenu: true)
    }

    @Test(arguments: [false, true])
    func registeredSendRemovalPublishesOnlyItsRequestLocalNativeProof(surviving: Bool) async throws {
        try await assertOccupiedSingleSendRenewal(removing: true, survivingSource: surviving, observeRemoval: true)
    }

    @Test(arguments: ["cancel", "failure", "unverified"])
    func registeredSendRemovalSagaCompensatesOnlyItsActualNativeEffect(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(removing: true, restoring: true, emptyModeMenu: true, sagaMode: mode)
    }

    @Test(arguments: ["forward", "cancel", "replacement", "late_replacement", "wrong_digest", "wrong_project", "physical_slot", "mixed", "missing_witness", "decoded"])
    func canonicalSendRemovalUsesItsRetainedNativeControl(mode: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(removing: true, restoring: true,
                emptyModeMenu: true, canonicalSend: mode)
        }
    }

    @Test(arguments: ["forward", "cancel", "replacement", "late_replacement", "wrong_digest", "wrong_project", "physical_slot", "mixed", "missing_witness", "decoded"])
    func canonicalPhysicalSendUsesTheSameRetainedControlAndOwnedInverse(mode: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(removing: false, restoring: true,
                emptyModeMenu: true, canonicalSend: mode, canonicalPhysical: true)
        }
    }

    @Test(arguments: ["forward", "cancel", "replacement", "late_replacement", "wrong_digest", "wrong_project", "physical_slot", "mixed", "missing_witness", "decoded", "unsupported_pair", "physical_removal"])
    func canonicalPhysicalSendReturnRetainsItsTypedBeforeAndOriginalControl(mode: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(restoring: true, emptyModeMenu: true,
                canonicalSend: mode, canonicalPhysical: true, freshPhysicalReturn: true)
        }
    }

    @Test(arguments: [false, true])
    func alreadyMatchingCanonicalSendVerifiesItsGoalWithoutASetter(physical: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(restoring: true, emptyModeMenu: true,
                canonicalSend: "matching", canonicalPhysical: true,
                freshPhysicalReturn: physical, canonicalMatching: true)
        }
    }

    @Test(arguments: ["replacement", "late_replacement", "wrong_project", "destination", "level", "bypass", "mode", "unread_mark", "source_retired", "wrong_digest", "unconfirmed", "cleanup_focus"], [false, true])
    func matchingCanonicalSendRefusesStaleOrUnapprovedGoalsWithoutASetter(fault: String, physical: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(restoring: true, emptyModeMenu: true,
                canonicalSend: "matching", canonicalPhysical: true,
                freshPhysicalReturn: physical, canonicalMatching: true, matchingFault: fault)
        }
    }

    @Test("Registered inspection preserves raw checked nonrouting titles without calling them a typed send mode")
    func registeredInspectionPreservesItsCheckedSendNonroutingWitness() async throws {
        try await assertOccupiedSingleSendRenewal(inspectSendWitness: "observed")
    }

    @Test func registeredInspectionCarriesItsCompleteNativeSendMode() async throws {
        try await assertOccupiedSingleSendRenewal(inspectSendWitness: "typed_mode")
    }

    @Test(arguments: ["missing", "duplicate", "unreadable", "conflict", "disagree", "changed_control",
                      "projection_cached", "projection_decoded", "projection_foreign", "projection_duplicate",
                      "projection_unqualified", "projection_unstable", "projection_duplicate_ordinal"])
    func registeredInspectionCannotInventTypedSendMode(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(inspectSendWitness: "typed_mode_" + fault)
    }

    @Test(arguments: ["unsupported_mark", "unread_mark", "malformed_title", "changed_control"])
    func registeredInspectionCannotPublishUnknownSendNonroutingWitness(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(inspectSendWitness: fault)
    }

    @Test(arguments: ["decoded", "cached", "duplicate", "foreign", "unstable", "unqualified"])
    func sendNonroutingProjectionClearsUnboundOrForgedWitness(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(inspectSendWitness: "projection_" + fault)
    }

    @Test(arguments: ["preflight", "wrong_project", "foreign_document", "refs_disabled"])
    func removalSagaPreflightRequiresItsActualProject(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(removing: true, restoring: true, emptyModeMenu: true, sagaMode: mode)
    }

    @Test(arguments: ["external_empty", "foreign_after", "no_observer"])
    func removalSagaNeverInvertsNewerOrUnownedEmptyState(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(removing: true, restoring: true, emptyModeMenu: true, sagaMode: mode)
    }

    @Test(arguments: ["missing_confirmation", "wrong_confirmation", "extra_param", "invalid_later", "multiple", "raw_level", "raw_bypass", "nondefault_mode"])
    func removalSagaRejectsUnapprovedOrInvalidWholeRequestsBeforeAnyLeaf(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(removing: true, restoring: true, emptyModeMenu: true, sagaMode: mode)
    }

    @Test(arguments: ["multiple_occupied", "foreign_project", "unreadable"])
    func unverifiedSendRemovalNeverPublishesNativeInverseAuthority(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(fault, removing: true, observeRemoval: true)
    }

    @Test func restoredSendSourceSupportsAnIndependentChangedDestinationRead() async throws {
        try await assertOccupiedSingleSendRenewal(removing: true, restoring: true, readRestored: "changed_destination")
    }

    @Test(arguments: ["wrong_original", "foreign_project", "retired_source", "replaced_control"])
    func restoredSendReaderRefusesWrongOrLostNativeCustody(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(removing: true, restoring: true, readRestored: fault)
    }

    @Test(arguments: ["empty_mode_mark_unreadable", "empty_mode_still_enabled", "empty_mode_enabled_unreadable", "after_mode"])
    func typedRemovedSendInverseRefusesUnknownOrEnabledEmptyModes(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(removing: true, restoring: true, inverseFault: fault,
            survivingSource: true, emptyModeMenu: true)
    }

    @Test(arguments: ["empty_replaced", "another_occupied", "foreign_project", "after_level", "after_bypass", "after_mode",
                      "conflicting_echo", "unreadable_echo_mark"])
    func typedRemovedSendInverseRefusesNewerOrUnknownState(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(removing: true, restoring: true, inverseFault: fault)
    }

    @Test(arguments: ["late_role_nil", "late_role_number", "late_title_nil", "late_title_number", "late_child_role"])
    func removalFinalSelectorCannotSkipUnknownCandidates(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(fault, removing: true)
    }

    @Test(arguments: ["multiple_occupied", "footprint", "foreign_project", "foreign_focus", "unreadable", "missing_pair"])
    func removedSingleSendCannotAdoptAmbiguityOrLostOwnership(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(fault, removing: true)
    }

    @Test(arguments: ["multiple_occupied", "footprint", "level", "bypass", "mode", "foreign_project",
                      "foreign_focus", "unreadable", "missing_pair", "deciding_control", "deciding_level"])
    func retiredSingleSendCannotAdoptAmbiguityOrNewerState(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(fault)
    }

    @Test func registeredSendModeHasItsVerifiedHandler() throws {
        _ = try #require(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "set_send_mode_verified"))
    }

    @Test(arguments: ["english", "korean", "compact_pan", "compact_post_pan", "compact_post_fader", "compact_pre_fader"])
    func sendModeCensusRequiresMeasuredWholeTitles(fault: String) throws {
        let f = try Fixture(), b = f.builder
        let root = b.element(1_965_2900)
        b.setRole(root, kAXMenuRole as String)
        var titles = fault == "english"
            ? ["Independent Pan", "Post Pan", "Post Fader", "Pre Fader"]
            : ["독립 패닝", "포스트 패닝", "포스트 페이더", "프리 페이더"]
        let compactFaults = ["compact_pan", "compact_post_pan", "compact_post_fader", "compact_pre_fader"]
        if let index = compactFaults.firstIndex(of: fault) {
            titles[index] = ["독립패닝", "포스트패닝", "포스트페이더", "프리페이더"][index]
        }
        let items = titles.enumerated().map { index, title in
            let item = b.element(1_965_2901 + index)
            b.setRole(item, kAXMenuItemRole as String)
            b.setAttribute(item, kAXTitleAttribute as String, title)
            b.setAttribute(item, kAXEnabledAttribute as String, true)
            b.setAttribute(item, "AXMenuItemMarkChar", index == 2 ? "✓" : "")
            b.setChildren(item, [])
            return item
        }
        b.setChildren(root, items)
        let ax = b.makeAXRuntime()
        let observed = AccessibilityChannel.currentSendMode(in: root, runtime: ax)
        let choice = AccessibilityChannel.sendModeMenuChoice(.preFader, in: root, runtime: ax)
        if fault.hasPrefix("compact_") {
            #expect(observed == nil)
            guard case .menuUnread = choice else {
                Issue.record("An unsupported compact title must not grant a mode choice")
                return
            }
        } else {
            let current = try #require(observed)
            #expect(current.mode == .postFader)
            #expect(!current.independentPan)
            #expect(current.otherChecks.isEmpty)
            guard case .item(let item, let path) = choice else {
                Issue.record("Measured whole titles must retain their mode choice")
                return
            }
            #expect(CFEqual(item, items[3]))
            #expect(path == [titles[3]])
        }
    }

    @Test func registeredSendModePreservesItsOccupiedSendRoundtrip() async throws {
        try await assertOccupiedSingleSendRenewal(modeCommand: "roundtrip")
    }

    @Test func registeredSendPostPanPreservesItsOccupiedSendRoundtrip() async throws {
        try await assertOccupiedSingleSendRenewal(modeCommand: "post_pan_roundtrip")
    }

    @Test(arguments: ["preflight", "failure", "cancel"])
    func registeredPostPanSagaOwnsItsActualCompensation(_ outcome: String) async throws {
        try await assertOccupiedSingleSendRenewal(modeCommand: "post_pan_roundtrip", modeSaga: outcome)
    }

    @Test(arguments: ["canonical_plan", "canonical_digest", "multiple_steps", "wrong_before", "noop",
        "unknown_mode", "boolean_mode", "extra_param", "missing_target", "negative_slot", "wrong_inverse", "blank_project"])
    func postPanSagaRetainsItsExactSingletonAdmission(_ fault: String) {
        var params: [String: Value] = ["ordinal": .int(1), "mode": .string("post_pan"),
            "expected_current": .string("post_fader")]
        switch fault {
        case "wrong_before": params["expected_current"] = .string("pre_fader")
        case "noop": params["mode"] = .string("post_fader")
        case "unknown_mode": params["mode"] = .string("post_pan_extra")
        case "boolean_mode": params["mode"] = .bool(true)
        case "extra_param": params["allow_create"] = .bool(true)
        case "negative_slot": params["ordinal"] = .int(-1)
        case "blank_project": params["project_ref"] = .string(" ")
        default: break
        }
        let step = SagaStep(operationID: .mixerSetSendModeVerified,
            targetRef: fault == "missing_target" ? nil : .init(rawValue: "mix_source"), params: params,
            expectedInverse: .init(operationID: .mixerSetSendModeVerified,
                valueParameter: fault == "wrong_inverse" ? "level_db" : "mode"))
        var plan = SagaPlan(steps: fault == "multiple_steps" ? [step, step] : [step], idempotencyKey: "mode-admission")
        if fault == "canonical_plan" { plan.canonicalPlanID = "plan_foreign" }
        if fault == "canonical_digest" { plan.canonicalDigest = String(repeating: "a", count: 64) }
        #expect(!SendModeSagaAdapter.accepts(plan))
    }

    @Test(arguments: ["roundtrip", "post_pan_roundtrip"])
    func checkedModeRenewsRetiredControlsOnTheExactSurvivingStrip(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(survivingSource: true, modeCommand: mode)
    }

    @Test(arguments: ["mode_control_peer", "mode_control_header", "mode_control_raw", "mode_control_duplicate"])
    func survivingModeControlRenewalCannotAdoptChangedCustody(fault: String) async throws {
        let boundary = ModePeerBoundary()
        try await assertOccupiedSingleSendRenewal(fault, survivingSource: true,
            modeCommand: "post_pan_roundtrip", modePeerBoundary: boundary)
        #expect(boundary.state == "B", "\(boundary.receipt)")
        #expect(boundary.leafCount == 1, "Unknown after-state must not cause another mode leaf")
    }

    @Test(arguments: ["roundtrip", "post_pan_roundtrip"], ["failure", "cancel"])
    func existingModeSagaKeepsOwnedCompensationAfterControlRetirement(mode: String, outcome: String) async throws {
        try await assertOccupiedSingleSendRenewal(survivingSource: true, modeCommand: mode, modeSaga: outcome)
    }

    @Test(arguments: ["preflight", "failure", "cancel"])
    func registeredSendModeSagaOwnsItsActualCompensation(_ outcome: String) async throws {
        try await assertOccupiedSingleSendRenewal(modeCommand: "roundtrip", modeSaga: outcome)
    }

    @Test(arguments: ["roundtrip", "post_pan_roundtrip"], ["no_observer", "lost_observer", "late_inverse_mode", "late_inverse_level",
        "late_inverse_document", "wrong_hash", "wrong_project", "wrong_target", "wrong_slot"])
    func registeredSendModeSagaRefusesUnownedOrChangedEffects(mode: String, fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(modeCommand: mode, modeSaga: fault)
    }

    private final class ModeEffectBoundary: @unchecked Sendable {
        var observed: [AccessibilityChannel.ChangedSendModeObservation] = []
        var permittedAtCapture: [Bool] = []
        var fault: String?
        var faultReached = false
        var permittedAfterFault: [Bool] = []
    }

    @Test(arguments: ["roundtrip", "post_pan_roundtrip"])
    func registeredSendModePublishesOnlyItsOwnNativeEffect(mode: String) async throws {
        let boundary = ModeEffectBoundary()
        try await assertOccupiedSingleSendRenewal(modeCommand: mode, modeEffectBoundary: boundary)
        #expect(boundary.observed.count == 2, "Both real registered leaves must publish their own native mode proof")
        guard boundary.observed.count == 2 else { return }
        #expect(boundary.permittedAtCapture == [true, true])
        let forward = boundary.observed[0], inverse = boundary.observed[1]
        let desired: AccessibilityChannel.SendMode = mode == "post_pan_roundtrip" ? .postPan : .preFader
        #expect(forward.before.mode == .postFader && forward.after.mode == desired)
        #expect(inverse.before.mode == desired && inverse.after.mode == .postFader)
        #expect(forward.checkedDestination == .stereoOutput && inverse.checkedDestination == .stereoOutput)
        if forward.before.independentPan { #expect(forward.after.independentPan) }
        else { #expect(!forward.after.independentPan) }
        #expect(forward.original.track.matches(forward.current.track))
    }

    @Test(arguments: ["roundtrip", "post_pan_roundtrip"], ["foreign_document", "changed_control", "changed_peer", "boolean_raw"])
    func nativeSendModeEffectRejectsChangedCustody(mode: String, fault: String) async throws {
        let boundary = ModeEffectBoundary()
        boundary.fault = fault
        let leaf = ModePeerBoundary()
        try await assertOccupiedSingleSendRenewal(modeCommand: mode,
            modePeerBoundary: leaf, modeEffectBoundary: boundary)
        #expect(leaf.leafCount == 1, "Invalidate only an effect from the actual mode leaf")
        #expect(boundary.observed.count == 1 && boundary.permittedAtCapture == [true])
        #expect(boundary.faultReached, "Reach the actual native mode effect before changing its protected facts")
        #expect(boundary.permittedAfterFault == [false])
    }

    private final class ModePeerBoundary: @unchecked Sendable {
        var peerReads = 0, beforeLeafPeerReads = 0, mutations = 0, leafCount = 0
        var injectAt = -1
        var state = "", receipt = ""
        let independentPan: Bool
        init(independentPan: Bool = false) { self.independentPan = independentPan }
    }

    @Test(arguments: [false, true])
    func registeredSendModeFinalPeerReadCannotHideModeOrPan(independentPan: Bool) async throws {
        let healthy = ModePeerBoundary()
        try await assertOccupiedSingleSendRenewal(modeCommand: "roundtrip", modePeerBoundary: healthy)
        #expect(healthy.state == "A" && healthy.leafCount == 1 && healthy.beforeLeafPeerReads > 0)
        let fault = ModePeerBoundary(independentPan: independentPan)
        fault.injectAt = healthy.beforeLeafPeerReads
        try await assertOccupiedSingleSendRenewal(modeCommand: "roundtrip", modePeerBoundary: fault)
        #expect(fault.mutations == 1, "Reach the final peer read after the deciding mode check")
        #expect(fault.state == "C", "\(fault.receipt)")
        #expect(fault.leafCount == 0, "An intervening checked mode or Independent Pan edit must prevent the leaf")
    }

    @Test(arguments: ["noop", "independent_pan"])
    func registeredSendModeUsesOnlyItsCheckedMode(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(modeCommand: mode)
    }

    @Test(arguments: ["missing", "duplicate", "unread_mark", "no_checked_mode", "two_checked_modes",
                      "wrong_target", "wrong_project", "unsupported_mode", "boolean_mode", "extra_param",
                      "late_document", "late_level", "late_bypass", "late_play", "late_mode", "late_peer", "boolean_raw"])
    func registeredSendModeRefusesUnownedOrUnknownBefore(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(modeCommand: fault)
    }

    @Test(arguments: ["after_route", "after_level", "after_bypass", "after_independent_pan", "after_source", "after_ack_only", "after_peer", "after_boolean_raw"])
    func registeredSendModeCannotInventItsAfterOrInverse(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(modeCommand: fault)
    }

    @Test func registeredFreshEmptySendCreatesOnlyItsExactControl() async throws {
        try await assertOccupiedSingleSendRenewal(freshEmpty: "observed")
    }

    @Test(arguments: ["multiple_empty", "occupied", "wrong_target", "wrong_project", "expired_pair",
                      "unread_mark", "conflicting_route", "late_empty", "late_document", "late_play", "before_peer"])
    func registeredFreshEmptySendRefusesLostOrAmbiguousBefore(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(freshEmpty: fault)
    }

    @Test(arguments: ["peer_padding", "peer_occupied", "peer_padding_three", "after_source", "after_mode"])
    func registeredFreshEmptySendVerifiesOnlyItsQualifiedAfter(fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(freshEmpty: fault)
    }

    @Test func registeredFreshEmptySendFinalPeerReadCannotMaskTargetChange() async throws {
        let witness = try Fixture()
        try await assertOccupiedSingleSendRenewal(freshEmpty: "calibrate_late_target", recordFreshFinalPeerRead: {
            witness.routingIndependentSendReads = $0
        })
        #expect(witness.routingIndependentSendReads > 0)
        try await assertOccupiedSingleSendRenewal(freshEmpty: "late_target",
            freshAfterTargetReads: witness.routingIndependentSendReads)
    }

    @Test func registeredFreshEmptySendRejectsBooleanRawAfterLeaf() async throws {
        try await assertOccupiedSingleSendRenewal(freshEmpty: "boolean_after")
    }

    @Test func registeredFreshEmptySendSagaPreflightReadsItsActualEmptySource() async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, freshEmpty: "observed", creationSaga: "preflight")
    }

    @Test(arguments: ["failure", "cancel", "peer_padding"])
    func registeredFreshEmptySendSagaRemovesOnlyItsActualCreatedControl(_ outcome: String) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true,
            freshEmpty: outcome == "peer_padding" ? "peer_padding" : "observed",
            creationSaga: outcome == "peer_padding" ? "failure" : outcome)
    }

    @Test(arguments: ["no_observer", "lost_observer", "late_inverse_level", "late_inverse_raw_boolean",
        "late_inverse_bypass", "late_inverse_mode", "late_inverse_leaf_mode", "late_inverse_peer",
        "late_inverse_control", "late_inverse_document", "late_inverse_route", "wrong_hash",
        "wrong_project", "wrong_target", "wrong_slot", "unknown_creation_mode"])
    func registeredFreshEmptySendSagaRefusesUnownedOrChangedCreation(_ fault: String) async throws {
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, freshEmpty: "observed", creationSaga: fault)
    }

    @Test(arguments: [false, true])
    func registeredFreshEmptySendFinalPeerReadCannotHideModeOrPan(independentPan: Bool) async throws {
        let healthy = ModePeerBoundary()
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, freshEmpty: "observed",
            modePeerBoundary: healthy, creationSaga: "failure")
        #expect(healthy.beforeLeafPeerReads > 0)
        let fault = ModePeerBoundary(independentPan: independentPan)
        fault.injectAt = healthy.beforeLeafPeerReads
        try await assertOccupiedSingleSendRenewal(emptyModeMenu: true, freshEmpty: "observed",
            modePeerBoundary: fault, creationSaga: "late_inverse_peer_mode")
        #expect(fault.mutations == 1, "Reach the actual final peer read before No Send")
    }

    private func assertFreshCreationSaga(_ creationSaga: String, fixture f: Fixture,
        cache: StateCache, registry: TargetRegistry, router: ChannelRouter, gate: LogicMutationGate,
        reference: TargetReference, params: [String: Value]) async throws {
        let b = f.builder
        let journal = SagaJournal(maxRecords: 1), key = "owned-fresh-send-creation"
        let creationDependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
            poller: StatePoller(axChannel: f.channel(), cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing })),
            dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal,
            mutationGate: gate, liveTrackNames: { [:] })
        var stepParams = params
        stepParams.removeValue(forKey: "target_ref")
        if creationSaga == "wrong_project" { stepParams["project_ref"] = .string("prj_foreign") }
        if creationSaga == "wrong_slot" { stepParams["ordinal"] = .int(1) }
        var wire: [String: Value] = ["idempotency_key": .string(key),
            "steps": .array([.object([
                "operation_id": .string(OperationID.mixerSetSendOutputVerified.rawValue),
                "target_ref": .string(creationSaga == "wrong_target"
                    ? "mix_00000000-0000-0000-0000-000000000000" : reference.rawValue), "params": .object(stepParams),
                "expected_inverse": .object([
                    "operation_id": .string(OperationID.mixerSetSendOutputVerified.rawValue),
                    "value_parameter": .string("destination")])])])]
        let preflight = try #require(OperationHandlerRegistry.handler(tool: "logic_system", command: "saga_preflight"))
        let preview = await FeatureFlags.withAdr004MutationSagaForTests(true) { await preflight(creationDependencies, wire) }
        let previewBody = try #require(sharedJSONObject(sharedToolText(preview)))
        let ready = try #require(previewBody["ok"] as? Bool, "\(sharedToolText(preview))")
        if ["wrong_project", "wrong_target", "wrong_slot"].contains(creationSaga) {
            #expect(!ready && f.routingDestinationPresses == 0)
            return
        }
        #expect(ready, "The actual registered preflight must observe the held sole-empty source: \(sharedToolText(preview))")
        #expect(f.routingDestinationPresses == 0 && f.routingRemovedSend == nil)
        if creationSaga == "preflight" { return }
        await router.register(SendRemovalSagaResultBoundary(base: f.channel(), journal: journal,
            mode: creationSaga, idempotencyKey: key,
            afterForward: {
                switch creationSaga {
                case "late_inverse_level": b.setAttribute(b.element(1_965_2644), kAXValueAttribute as String, 1)
                case "late_inverse_raw_boolean": b.setAttribute(b.element(1_965_2644), kAXValueAttribute as String, false)
                case "late_inverse_bypass": b.setAttribute(b.element(1_965_2642), kAXValueAttribute as String, 1)
                case "late_inverse_mode":
                    b.setAttribute(b.element(1_965_2603), "AXMenuItemMarkChar", "")
                    b.setAttribute(b.element(1_965_2771), "AXMenuItemMarkChar", "✓")
                case "late_inverse_peer": b.setChildren(f.strips[0], b.makeAXRuntime().children(f.strips[0]) + [b.element(1_965_2660)])
                case "late_inverse_control":
                    let group = b.element(1_965_2899)
                    b.setRole(group, kAXGroupRole as String)
                    b.setChildren(group, b.makeAXRuntime().children(b.element(1_965_2641)))
                    b.setChildren(b.element(1_965_2600), b.makeAXRuntime().children(b.element(1_965_2600)).map {
                        CFEqual($0, b.element(1_965_2641)) ? group : $0
                    })
                case "late_inverse_document": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                case "late_inverse_route":
                    b.setAttribute(b.element(1_965_2602), kAXTitleAttribute as String, "Bus 1 → Existing")
                    b.setAttribute(b.element(1_965_2606), "AXMenuItemMarkChar", "")
                default: return
                }
                f.routingLateScopeInjected = true
            },
            observedResult: { f.creationForwardReceipt = $0.message }))
        wire["confirmed_plan_hash"] = .string(SagaJournal.planHash(try SagaWire.plan(from: wire)))
        if creationSaga == "wrong_hash" { wire["confirmed_plan_hash"] = .string(String(repeating: "0", count: 64)) }
        let execute = try #require(OperationHandlerRegistry.handler(tool: "logic_system", command: "saga_execute"))
        let applied = await FeatureFlags.withAdr004MutationSagaForTests(true) { await execute(creationDependencies, wire) }
        let appliedBody = try #require(sharedJSONObject(sharedToolText(applied)))
        if creationSaga == "wrong_hash" {
            #expect(appliedBody["state"] as? String == "C" && f.routingDestinationPresses == 0)
            let wrote = try #require(appliedBody["write_attempted"] as? Bool); #expect(!wrote)
            return
        }
        if ["no_observer", "lost_observer", "unknown_creation_mode"].contains(creationSaga) || creationSaga.hasPrefix("late_inverse_") {
            let terminal = try #require(appliedBody["saga_state"] as? String)
            #expect(appliedBody["state"] as? String == "B" && terminal != "completed" && terminal != "fullyCompensated",
                "\(sharedToolText(applied))")
            let expectedWrites = creationSaga == "no_observer" ? 0 : 1
            #expect(f.routingDestinationPresses == expectedWrites && !gate.isHeldByEntitledHolder())
            if creationSaga.hasPrefix("late_inverse_") || creationSaga == "unknown_creation_mode" {
                #expect(f.routingLateScopeInjected)
            }
            let replay = await FeatureFlags.withAdr004MutationSagaForTests(true) { await execute(creationDependencies, wire) }
            let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
            let duplicate = try #require(replayBody["duplicate"] as? Bool); #expect(duplicate)
            #expect(replayBody["state"] as? String == "B" && f.routingDestinationPresses == expectedWrites)
            return
        }
        #expect(f.creationForwardReceipt.flatMap(sharedJSONObject)?["state"] as? String == "A",
            "Reach the real native creation before testing its missing compensation: \(f.creationForwardReceipt ?? "missing")")
        #expect(appliedBody["saga_state"] as? String == "fullyCompensated",
            "Forward: \(f.creationForwardReceipt ?? "missing"); Saga: \(sharedToolText(applied))")
        #expect(f.routingDestinationPresses == 2, "Exactly one creation and its own No Send inverse")
        #expect(AXLogicProElements.sendSlotObservations(in: b.element(1_965_2700), runtime: f.logic().ax)
            == [.init(ordinal: 0, state: .observedEmpty)])
        let replay = await FeatureFlags.withAdr004MutationSagaForTests(true) { await execute(creationDependencies, wire) }
        let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
        if creationSaga == "cancel" {
            #expect(replayBody["error"] as? String == HonestContract.FailureError.unsupportedState.rawValue)
        } else {
            let duplicate = try #require(replayBody["duplicate"] as? Bool); #expect(duplicate)
        }
        #expect(f.routingDestinationPresses == 2 && !gate.isHeldByEntitledHolder())
        return
    }

    private func assertSurvivingModeControlReadback(_ f: Fixture, originalList: AXUIElement,
        body: [String: Any], selectionsBefore: Int) {
        #expect(f.selections.count > selectionsBefore, "Same-strip renewal still needs an actual original-header observation and inverse")
        #expect(body["source_renewal"] as? String != nil)
        let role: String? = AXHelpers.getAttribute(f.strips[1], kAXRoleAttribute as String, runtime: f.logic().ax)
        #expect(role == kAXLayoutItemRole as String)
        let oldList: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(originalList,
            kAXRoleAttribute as String, runtime: f.logic().ax)
        if case .failure(let error) = oldList { #expect(error.raw == AXError.invalidUIElement.rawValue) }
        else { Issue.record("The old Send control, not the original strip, must actually retire") }
    }

    private func assertOccupiedSingleSendRenewal(_ fault: String? = nil, existingBus: Bool = false,
                                               removing: Bool = false, restoring: Bool = false,
                                               inverseFault: String? = nil, survivingSource: Bool = false,
                                               emptyModeMenu: Bool = false, observeRemoval: Bool = false,
                                               readRestored: String? = nil, sagaMode: String? = nil,
                                               inspectSendWitness: String? = nil,
                                               noOpDestination: OutputAssignment? = nil,
                                               bypassMode: String? = nil, levelMode: String? = nil,
                                               freshEmpty: String? = nil, freshAfterTargetReads: Int? = nil,
                                               recordFreshFinalPeerRead: (@Sendable (Int) -> Void)? = nil,
                                               modeCommand: String? = nil,
                                               modePeerBoundary: ModePeerBoundary? = nil,
                                               modeSaga: String? = nil,
                                               modeEffectBoundary: ModeEffectBoundary? = nil,
                                               levelSaga: String? = nil,
                                               creationSaga: String? = nil,
                                               canonicalSend: String? = nil,
                                               canonicalPhysical: Bool = false,
                                               freshPhysicalReturn: Bool = false,
                                               canonicalMatching: Bool = false,
                                               matchingFault: String? = nil) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture(), b = f.builder
            let inspectTypedMode = inspectSendWitness?.hasPrefix("typed_mode") == true
            let projectionWitness = inspectSendWitness.map {
                $0.hasPrefix("typed_mode_projection_") ? String($0.dropFirst("typed_mode_".count)) : $0
            }
            let mixerOwner = b.element(1_965_2599)
            b.setRole(mixerOwner, kAXGroupRole as String); b.setAttribute(mixerOwner, kAXDescriptionAttribute as String, "Mixer")
            b.setRole(f.mixer, kAXLayoutAreaRole as String); b.setAttribute(f.mixer, kAXDescriptionAttribute as String, "Mixer")
            let windowChildren = b.makeAXRuntime().children(f.window)
            b.setChildren(mixerOwner, [f.mixer])
            b.setChildren(f.window, windowChildren.map { CFEqual($0, f.mixer) ? mixerOwner : $0 })
            let captureNow = ContinuousClock.now
            let cache = StateCache(sessionCaptureNow: {
                f.expireRetainedCapture ? captureNow.advanced(by: StateCache.sessionCaptureLifetime) : captureNow
            }), registry = TargetRegistry()
            let replacement = b.element(1_965_2600), root = b.element(1_965_2601)
            let restoredSource = b.element(1_965_2700)
            let echo = b.element(1_965_2602), mode = b.element(1_965_2603)
            let parent = b.element(1_965_2604), menu = b.element(1_965_2605)
            let stereo = b.element(1_965_2606), destination = b.element(1_965_2607)
            let competitor = b.element(1_965_2720), leafChild = b.element(1_965_2721)
            let preFader = b.element(1_965_2771), postPan = b.element(1_965_2772), independentPan = b.element(1_965_2773)
            let lateRemovalChoice = removing && fault?.hasPrefix("late_") == true
            func send(_ base: Int) -> [AXUIElement] {
                let anchor = b.element(base), group = b.element(base + 1), bypass = b.element(base + 2)
                let list = b.element(base + 3), level = b.element(base + 4)
                b.setButton(anchor, description: "send button", help: "Send slot. Route signal.", x: 0, y: 0, width: 1, height: 1)
                b.setChildren(anchor, [])
                b.setRole(group, kAXGroupRole as String)
                b.setAttribute(group, kAXDescriptionAttribute as String, "not an endpoint identity")
                b.setRole(bypass, kAXCheckBoxRole as String); b.setAttribute(bypass, kAXValueAttribute as String, 0)
                b.setChildren(bypass, [])
                b.setButton(list, description: "list", x: 0, y: 0, width: 1, height: 1)
                b.setChildren(list, []); b.setActionNames(list, [kAXPressAction as String])
                b.setChildren(group, [bypass, list])
                b.setRole(level, kAXSliderRole as String)
                b.setAttribute(level, kAXHelpAttribute as String, "Send Level knob. Set level.")
                b.setAttribute(level, kAXValueAttribute as String, 0); b.setChildren(level, [])
                return [anchor, group, level]
            }
            let originalSend = send(1_965_2620), renewedSend = send(1_965_2640), extraSend = send(1_965_2660)
            b.setButton(b.element(1_965_2970), description: "send button", help: "Send slot. Route signal.",
                x: 0, y: 0, width: 1, height: 1)
            b.setChildren(b.element(1_965_2970), [])
            if freshEmpty != nil || modeCommand != nil || inspectTypedMode { f.useBulkReads = true }
            if levelMode != nil {
                f.useBulkReads = true
                let knob = b.element(1_965_2624), editor = b.element(1_965_2800), field = b.element(1_965_2801)
                b.setFrame(knob, x: 20, y: 30, width: 40, height: 20)
                b.setAttribute(knob, kAXValueDescriptionAttribute as String, "-∞")
                b.setAttribute(knob, kAXWindowAttribute as String, f.window)
                b.setRole(editor, kAXWindowRole as String); b.setChildren(editor, [field])
                b.setRole(field, kAXTextFieldRole as String); b.setChildren(field, [])
                b.setAttribute(field, kAXWindowAttribute as String, editor)
                b.setAttributeSettable(field, kAXValueAttribute as String, true)
                b.setAttribute(field, kAXValueAttribute as String, "-∞")
                b.setAttribute(editor, kAXTitleAttribute as String, "")
                f.routingLevelHit = knob
                f.routingSetter = { element, attribute, value in
                    guard CFEqual(element, field), attribute == kAXValueAttribute as String else { return nil }
                    guard let text = value as? String else { Issue.record("No raw knob setter"); return false }
                    f.routingLevelWrites.append(text)
                    if levelMode != "setter_ack_only" { b.setAttribute(field, attribute, text) }
                    return true
                }
                @Sendable func finishLevelCommit() {
                    let text = b.attributeValue(field, kAXValueAttribute as String) as? String ?? ""
                    if levelMode != "commit_ack_only" {
                        b.setAttribute(knob, kAXValueAttribute as String, text == "-∞" ? 0 : 123456)
                        b.setAttribute(knob, kAXValueDescriptionAttribute as String, text)
                    }
                    if levelMode == "source_lost_after" { b.setChildren(f.mixer, [f.strips[0]]) }
                    if levelMode == "route_changed_after" {
                        b.setAttribute(echo, kAXTitleAttribute as String, "Output 3-4")
                        b.setAttribute(stereo, "AXMenuItemMarkChar", "")
                        b.setAttribute(destination, "AXMenuItemMarkChar", "✓")
                    }
                    b.setAttribute(f.app, kAXWindowsAttribute as String, [f.window])
                    b.setAttribute(f.app, kAXFocusedWindowAttribute as String, f.window)
                    b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.strips[1])
                    f.routingLevelCommitPending = false
                }
                f.routingLevelMouse = .init(postMouseEvent: { type, _, count in
                    guard type == .leftMouseDown || type == .leftMouseUp else { Issue.record("Only paired click"); return false }
                    if type == .leftMouseUp {
                        f.routingLevelClicks.append(count)
                        if count == 1 { f.routingLevelPairExpired = false }
                        if levelMode == "incomplete_up" { return false }
                        if count == 1, levelMode?.hasPrefix("first_click_") == true,
                           levelMode != "first_click_deferred_source_focus" {
                            f.routingLateScopeInjected = true
                            b.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                                levelMode == "first_click_foreign_focus" ? f.strips[0] : f.strips[1])
                            if levelMode == "first_click_document" {
                                b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            }
                            if levelMode == "first_click_control" {
                                b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]).filter { !CFEqual($0, knob) })
                            }
                            if levelMode == "first_click_play" {
                                b.setAttribute(b.element(1_965_721), kAXValueAttribute as String, 1)
                            }
                            if levelMode == "first_click_knob_window" {
                                b.setAttribute(knob, kAXWindowAttribute as String, b.element(1_965_2897))
                            }
                            if levelMode == "first_click_window_type" {
                                b.setAttribute(knob, kAXWindowAttribute as String, "not a native window")
                            }
                            if levelMode == "first_click_population" { b.setChildren(f.mixer, [f.strips[1]]) }
                        }
                        if count == 2, levelMode != "no_editor",
                           !(["slow_pair", "slow_transport_pair"].contains(levelMode ?? "") && f.routingLevelPairExpired) {
                            let display = b.attributeValue(knob, kAXValueDescriptionAttribute as String) as? String ?? ""
                            b.setAttribute(field, kAXValueAttribute as String, display == "-6.0" ? "-6" : display == "-95.0" ? "-95" : display)
                            b.setAttribute(f.app, kAXWindowsAttribute as String, [f.window, editor])
                            if levelMode == "return_window_before_fields_retired_peer" {
                                b.setAttribute(f.app, kAXWindowsAttribute as String,
                                    [f.window, b.element(1_965_2892), editor])
                            }
                            b.setAttribute(f.app, kAXFocusedWindowAttribute as String, editor)
                            b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, field)
                            switch levelMode {
                            case "editor_foreign":
                                f.routingLateScopeInjected = true
                                b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, b.element(1_965_2899))
                            case "editor_window":
                                f.routingLateScopeInjected = true
                                b.setAttribute(field, kAXWindowAttribute as String, f.window)
                            case "editor_value":
                                f.routingLateScopeInjected = true
                                b.setAttribute(field, kAXValueAttribute as String, "-95")
                            default: break
                            }
                        }
                    }
                    return true
                }, postKeyEvent: { key in
                    guard key == 36 else { Issue.record("No fallback key"); return false }
                    f.routingLevelCommits += 1
                    if levelMode?.hasPrefix("deferred") == true || levelMode?.hasPrefix("return_window") == true {
                        f.routingLevelCommitPending = true
                        f.routingLevelPendingFieldReads = 0
                        switch levelMode {
                        case "deferred_foreign":
                            let foreign = b.element(1_965_2896)
                            b.setRole(foreign, kAXTextFieldRole as String)
                            b.setAttribute(foreign, kAXWindowAttribute as String, editor)
                            b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, foreign)
                        case "deferred_window": b.setAttribute(f.app, kAXFocusedWindowAttribute as String, f.window)
                        case "deferred_source": b.setChildren(f.mixer, [f.strips[0]])
                        case "deferred_cancel": f.routingLevelCancelled = true
                        default: break
                        }
                        return true // A real Return ACK need not synchronously close its own editor.
                    }
                    finishLevelCommit()
                    return true
                }, postUnicodeScalar: { _ in Issue.record("No Unicode typing fallback"); return false }, sleepMicros: { delay in
                    if delay == 40_000, levelMode == "first_click_deferred_source_focus" {
                        f.routingLateScopeInjected = true
                        b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.strips[1])
                    }
                    guard delay == 25_000, f.routingLevelCommitPending else { return }
                    f.routingLevelWaits += 1
                    if levelMode == "deferred" || levelMode == "deferred_minus95" { finishLevelCommit() }
                })
            }
            if bypassMode != nil {
                f.useBulkReads = true
                b.setActionNames(b.element(1_965_2622), [kAXPressAction as String])
                b.setAttribute(b.element(1_965_2622), kAXEnabledAttribute as String, false)
            }
            let originalList = b.element(1_965_2623), renewedList = b.element(1_965_2643)
            let originalChildren = b.makeAXRuntime().children(f.strips[1])
            b.setChildren(f.strips[1], originalChildren + (freshEmpty == nil ? originalSend : [originalSend[0]]))
            if freshEmpty != nil { b.setActionNames(originalSend[0], [kAXPressAction as String]) }
            if freshEmpty == "multiple_empty" { b.setChildren(f.strips[1], originalChildren + [originalSend[0], extraSend[0]]) }
            if freshEmpty == "occupied" { b.setChildren(f.strips[1], originalChildren + originalSend) }
            let peerChildren = b.makeAXRuntime().children(f.strips[0])
            if modePeerBoundary != nil || freshEmpty?.hasPrefix("peer_") == true || ["calibrate_late_target", "late_target"].contains(freshEmpty ?? "") {
                b.setChildren(f.strips[0], peerChildren + [extraSend[0]])
            }
            b.setRole(replacement, kAXLayoutItemRole as String)
            b.setAttribute(replacement, kAXNumberOfCharactersAttribute as String, 0)
            b.setAttribute(replacement, kAXInsertionPointLineNumberAttribute as String, 0)
            let name = b.element(1_965_2608)
            b.setRole(name, kAXTextFieldRole as String); b.setAttribute(name, kAXDescriptionAttribute as String, "Name")
            b.setAttribute(name, kAXValueAttribute as String, "Duplicate"); b.setChildren(name, [])
            b.setChildren(replacement, [name] + renewedSend)
            b.setRole(restoredSource, kAXLayoutItemRole as String)
            b.setAttribute(restoredSource, kAXNumberOfCharactersAttribute as String, 0)
            b.setAttribute(restoredSource, kAXInsertionPointLineNumberAttribute as String, 0)
            b.setChildren(restoredSource, [name] + extraSend)
            b.setActionNames(renewedSend[0], [kAXPressAction as String])
            for container in [root, menu] { b.setRole(container, kAXMenuRole as String) }
            for (item, title) in [(echo, freshPhysicalReturn ? "Output 3-4" : "Stereo Output"), (mode, emptyModeMenu || modeCommand != nil || inspectTypedMode ? "Post Fader" : "Post Pan"), (parent, "Output"),
                                  (stereo, freshPhysicalReturn ? "Output 3-4" : "Stereo Output"),
                                  (destination, freshPhysicalReturn ? "Stereo Output" : "Output 3-4")] {
                b.setRole(item, kAXMenuItemRole as String); b.setAttribute(item, kAXTitleAttribute as String, title)
                b.setAttribute(item, kAXEnabledAttribute as String, true); b.setChildren(item, [])
                b.setActionNames(item, [kAXPressAction as String])
            }
            for item in [echo, mode, stereo] { b.setAttribute(item, "AXMenuItemMarkChar", "✓") }
            b.setChildren(menu, [stereo, destination]); b.setChildren(parent, [menu]); b.setChildren(root, [echo, mode, parent])
            if modeCommand != nil || inspectTypedMode || creationSaga != nil {
                for (item, title) in [(preFader, "Pre Fader"), (postPan, "Post Pan"), (independentPan, "Independent Pan")] {
                    b.setRole(item, kAXMenuItemRole as String); b.setAttribute(item, kAXTitleAttribute as String, title)
                    b.setAttribute(item, kAXEnabledAttribute as String, true); b.setChildren(item, [])
                    b.setAttribute(item, "AXMenuItemMarkChar", ""); b.setActionNames(item, [kAXPressAction as String])
                }
                b.setChildren(root, [echo, independentPan, postPan, mode, preFader, parent])
                if modeCommand == "independent_pan" { b.setAttribute(independentPan, "AXMenuItemMarkChar", "✓") }
                if inspectTypedMode {
                    b.setAttribute(mode, "AXMenuItemMarkChar", "")
                    b.setAttribute(preFader, "AXMenuItemMarkChar", "✓")
                    b.setAttribute(independentPan, "AXMenuItemMarkChar", "✓")
                    switch inspectSendWitness {
                    case "typed_mode_missing": b.setChildren(root, [echo, independentPan, mode, preFader, parent])
                    case "typed_mode_duplicate":
                        b.setRole(competitor, kAXMenuItemRole as String)
                        b.setAttribute(competitor, kAXTitleAttribute as String, "Pre Fader")
                        b.setAttribute(competitor, "AXMenuItemMarkChar", ""); b.setChildren(competitor, [])
                        b.setChildren(root, [echo, independentPan, postPan, mode, preFader, competitor, parent])
                    case "typed_mode_conflict": b.setAttribute(mode, "AXMenuItemMarkChar", "✓")
                    default: break
                    }
                }
            }
            if freshEmpty != nil {
                b.setAttribute(echo, kAXTitleAttribute as String, "No Send")
                b.setAttribute(mode, "AXMenuItemMarkChar", "")
                b.setAttribute(mode, kAXEnabledAttribute as String, false)
                b.setAttribute(stereo, "AXMenuItemMarkChar", "")
            }
            if removing {
                b.setAttribute(destination, kAXTitleAttribute as String, "No Send")
                b.setChildren(menu, [stereo]); b.setChildren(root, [echo, mode, parent, destination])
                if lateRemovalChoice {
                    b.setRole(competitor, kAXMenuItemRole as String)
                    b.setAttribute(competitor, kAXTitleAttribute as String, "Unselected alternative")
                    b.setChildren(competitor, [])
                    b.setRole(leafChild, kAXStaticTextRole as String); b.setChildren(leafChild, [])
                    b.setChildren(root, [echo, mode, parent, destination, competitor])
                    if fault == "late_child_role" { b.setChildren(destination, [leafChild]) }
                }
            }
            if existingBus {
                let input = b.element(1_965_2680), busParent = b.element(1_965_2681), busMenu = b.element(1_965_2682)
                b.setButton(input, description: "Bus 1", help: "Input slot. Choose the channel strip input source.",
                    x: 0, y: 0, width: 1, height: 1)
                b.setChildren(input, [])
                b.setChildren(f.strips[0], b.makeAXRuntime().children(f.strips[0]) + [input])
                b.setRole(busParent, kAXMenuItemRole as String); b.setAttribute(busParent, kAXTitleAttribute as String, "Bus")
                b.setRole(busMenu, kAXMenuRole as String)
                b.setAttribute(destination, kAXTitleAttribute as String, "Bus 1 → Existing")
                b.setChildren(menu, [stereo]); b.setChildren(busMenu, [destination]); b.setChildren(busParent, [busMenu])
                b.setChildren(root, [echo, mode, parent, busParent])
            }
            if let noOpDestination, noOpDestination != .stereoOutput {
                b.setAttribute(echo, kAXTitleAttribute as String, existingBus ? "Bus 1 → Existing" : "Output 3-4")
                b.setAttribute(stereo, "AXMenuItemMarkChar", "")
                b.setAttribute(destination, "AXMenuItemMarkChar", "✓")
            }
            b.setActionNames(root, [kAXCancelAction as String])
            f.routingAction = { element, action in
                if modeCommand != nil, action == kAXPressAction as String,
                   CFEqual(element, mode) || CFEqual(element, preFader) || CFEqual(element, postPan) {
                    modePeerBoundary?.beforeLeafPeerReads = modePeerBoundary?.peerReads ?? 0
                    f.routingModePresses += 1
                    if modeCommand != "after_ack_only" {
                        b.setAttribute(mode, "AXMenuItemMarkChar", CFEqual(element, mode) ? "✓" : "")
                        b.setAttribute(preFader, "AXMenuItemMarkChar", CFEqual(element, preFader) ? "✓" : "")
                        b.setAttribute(postPan, "AXMenuItemMarkChar", CFEqual(element, postPan) ? "✓" : "")
                    }
                    if survivingSource, f.routingModePresses == 1 {
                        b.setChildren(f.strips[1], originalChildren + renewedSend)
                        if fault == "mode_control_peer" { b.setChildren(f.strips[0], peerChildren + extraSend) }
                        if fault == "mode_control_raw" { b.setAttribute(b.element(1_965_2644), kAXValueAttribute as String, 99) }
                        if fault == "mode_control_duplicate" { b.setChildren(f.strips[1], originalChildren + renewedSend + extraSend) }
                    }
                    switch modeCommand {
                    case "after_route":
                        b.setAttribute(echo, kAXTitleAttribute as String, "Output 3-4")
                        b.setAttribute(stereo, "AXMenuItemMarkChar", ""); b.setAttribute(destination, "AXMenuItemMarkChar", "✓")
                    case "after_level": b.setAttribute(b.element(1_965_2624), kAXValueAttribute as String, 99)
                    case "after_bypass": b.setAttribute(b.element(1_965_2622), kAXValueAttribute as String, 1)
                    case "after_independent_pan": b.setAttribute(independentPan, "AXMenuItemMarkChar", "✓")
                    case "after_source": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    case "after_peer": b.setChildren(f.strips[0], peerChildren + extraSend)
                    case "after_boolean_raw": b.setAttribute(b.element(1_965_2624), kAXValueAttribute as String, false)
                    default: break
                    }
                    b.setChildren(f.mixer, f.strips); return true
                }
                if bypassMode != nil, CFEqual(element, b.element(1_965_2622)), action == kAXPressAction as String {
                    f.routingBypassPresses += 1
                    if bypassMode == "press_failed" { return false }
                    let value: NSNumber? = AXHelpers.getAttribute(element, kAXValueAttribute as String, runtime: b.makeAXRuntime())
                    if ["delayed_on", "delayed_off"].contains(bypassMode ?? "") {
                        f.routingBypassPendingValue = value?.intValue == 0
                        return true // Native ACK precedes the independent bit landing.
                    }
                    b.setAttribute(element, kAXValueAttribute as String, value?.intValue == 0 ? 1 : 0)
                    if bypassMode == "malformed_after" { b.setAttribute(element, kAXValueAttribute as String, 2) }
                    if bypassMode == "lost_source_after" { b.setChildren(f.mixer, [f.strips[0]]) }
                    return true
                }
                let source = f.routingReplacement ?? f.strips[1]
                if freshEmpty != nil, action == kAXPressAction as String, CFEqual(element, originalSend[0]) {
                    b.setChildren(f.mixer, [f.routingOtherReplacement ?? f.strips[0], source, root]); return true
                }
                if freshEmpty != nil, action == kAXPressAction as String, CFEqual(element, stereo) {
                    f.routingDestinationPresses += 1; f.routingReplacement = replacement
                    b.setAttribute(echo, kAXTitleAttribute as String, "Stereo Output")
                    b.setAttribute(stereo, "AXMenuItemMarkChar", "✓")
                    b.setAttribute(mode, kAXEnabledAttribute as String, true)
                    b.setAttribute(mode, "AXMenuItemMarkChar", "✓")
                    if creationSaga != nil {
                        // A real occupied menu retains its checked routing echo
                        // and a separate unselected No Send action.
                        b.setAttribute(destination, kAXTitleAttribute as String, "No Send")
                        b.setAttribute(destination, "AXMenuItemMarkChar", "")
                        b.setChildren(menu, [stereo])
                        b.setChildren(root, [echo, independentPan, postPan, mode, preFader, parent, destination])
                        if creationSaga == "unknown_creation_mode" {
                            b.setChildren(root, [echo, independentPan, mode, preFader, parent, destination])
                            f.routingLateScopeInjected = true
                        }
                    }
                    b.setChildren(f.mixer, [f.routingOtherReplacement ?? f.strips[0], replacement])
                    b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, replacement)
                    if freshEmpty?.hasPrefix("peer_") == true {
                        var padding: [AXUIElement] = []
                        for offset in 0..<(freshEmpty == "peer_padding_three" ? 2 : 1) {
                            let button = b.element(1_965_2780 + offset)
                            b.setButton(button, description: "send button", help: "Send slot. Route signal.", x: 0, y: 0, width: 1, height: 1)
                            b.setChildren(button, []); padding.append(button)
                        }
                        b.setChildren(f.strips[0], peerChildren + [extraSend[0]] + padding)
                        if freshEmpty == "peer_occupied" { b.setChildren(f.strips[0], peerChildren + extraSend) }
                    }
                    if freshEmpty == "after_source" { b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx") }
                    if freshEmpty == "after_mode" { b.setAttribute(mode, "AXMenuItemMarkChar", "") }
                    if freshEmpty == "boolean_after" { b.setAttribute(b.element(1_965_2644), kAXValueAttribute as String, true) }
                    return true
                }
                if creationSaga != nil, f.routingDestinationPresses == 1,
                   action == kAXPressAction as String, CFEqual(element, destination) {
                    modePeerBoundary?.beforeLeafPeerReads = modePeerBoundary?.peerReads ?? 0
                    f.routingDestinationPresses += 1; f.routingReplacement = restoredSource
                    b.setChildren(restoredSource, [name, b.element(1_965_2970)])
                    if freshEmpty == "peer_padding" { b.setChildren(f.strips[0], peerChildren + [extraSend[0]]) }
                    b.setAttribute(echo, kAXTitleAttribute as String, "No Send")
                    b.setAttribute(echo, "AXMenuItemMarkChar", "✓")
                    b.setAttribute(stereo, "AXMenuItemMarkChar", "")
                    b.setAttribute(mode, kAXEnabledAttribute as String, false)
                    b.setAttribute(mode, "AXMenuItemMarkChar", "")
                    b.setChildren(root, [echo, independentPan, postPan, mode, preFader, parent])
                    b.setChildren(f.mixer, [f.strips[0], restoredSource])
                    b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, restoredSource)
                    return true
                }
                if action == kAXPressAction as String, CFEqual(element, originalList) || CFEqual(element, renewedList)
                    || (canonicalSend != nil && CFEqual(element, b.element(1_965_2799)))
                    || (restoring && CFEqual(element, b.element(1_965_2663))) {
                    if canonicalSend == "late_replacement", CFEqual(element, b.element(1_965_2799)) {
                        f.routingBypassMenuOpens += 1
                    }
                    if bypassMode != nil || canonicalMatching { f.routingBypassMenuOpens += 1 }
                    if f.routingBypassMenuOpens == 3, let pending = f.routingBypassPendingValue {
                        f.routingLateScopeInjected = true
                        b.setAttribute(b.element(1_965_2622), kAXValueAttribute as String, pending ? 1 : 0)
                        f.routingBypassPendingValue = nil
                    }
                    b.setChildren(f.mixer, [f.strips[0], source, root]); return true
                }
                if restoring, action == kAXPressAction as String, CFEqual(element, renewedSend[0]) {
                    b.setChildren(f.mixer, [f.strips[0], source, root]); return true
                }
                if action == kAXCancelAction as String, CFEqual(element, root) {
                    if bypassMode != nil { f.routingBypassMenuCancels += 1 }
                    b.setChildren(f.mixer, [f.strips[0], source]); return true
                }
                if action == kAXPressAction as String, CFEqual(element, destination) {
                    f.routingDestinationPresses += 1; f.routingReplacement = replacement
                    b.setAttribute(echo, kAXTitleAttribute as String, existingBus ? "Bus 1 → Existing" : freshPhysicalReturn ? "Stereo Output" : "Output 3-4")
                    b.setAttribute(stereo, "AXMenuItemMarkChar", ""); b.setAttribute(destination, "AXMenuItemMarkChar", "✓")
                    if removing {
                        b.setChildren(replacement, [name, renewedSend[0]])
                        b.setAttribute(echo, "AXMenuItemMarkChar", "")
                        if emptyModeMenu {
                            b.setAttribute(mode, kAXEnabledAttribute as String, false)
                            b.setAttribute(mode, "AXMenuItemMarkChar", "")
                        }
                    }
                    if fault == "multiple_occupied" { b.setChildren(replacement, [name] + renewedSend + extraSend) }
                    if fault == "footprint" { b.setChildren(replacement, [name] + renewedSend + [extraSend[0]]) }
                    if fault == "level" { b.setAttribute(b.element(1_965_2644), kAXValueAttribute as String, 1) }
                    if fault == "bypass" { b.setAttribute(b.element(1_965_2642), kAXValueAttribute as String, 1) }
                    if fault == "mode" { b.setAttribute(mode, kAXTitleAttribute as String, "Pre Fader") }
                    b.setChildren(f.mixer, [f.strips[0], replacement])
                    b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, replacement)
                    if survivingSource {
                        f.routingReplacement = nil
                        b.setChildren(f.strips[1], originalChildren + [renewedSend[0]])
                        b.setChildren(f.mixer, f.strips)
                        b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.strips[1])
                        if fault == "healthy_sibling_replaced" {
                            f.routingOtherReplacement = replacement
                            b.setChildren(f.mixer, [replacement, f.strips[1]])
                        }
                        if fault == "healthy_occupied" { b.setChildren(f.strips[1], originalChildren + renewedSend) }
                        if fault == "healthy_header_retired" {
                            let foreignHeader = b.element(1_965_2730)
                            b.setRole(foreignHeader, kAXLayoutItemRole as String)
                            b.setAttribute(foreignHeader, kAXTitleAttribute as String, "Duplicate")
                            b.setChildren(foreignHeader, [])
                            b.setChildren(f.rail, [foreignHeader, f.headers[1]])
                        }
                    }
                    if fault == "foreign_project" { b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx") }
                    if fault == "foreign_focus" { b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, name) }
                    return true
                }
                if restoring, action == kAXPressAction as String, CFEqual(element, stereo) {
                    f.routingDestinationPresses += 1; f.routingReplacement = restoredSource
                    b.setAttribute(echo, kAXTitleAttribute as String, freshPhysicalReturn ? "Output 3-4" : "Stereo Output")
                    b.setAttribute(echo, "AXMenuItemMarkChar", "✓")
                    b.setAttribute(stereo, "AXMenuItemMarkChar", "✓")
                    b.setAttribute(destination, "AXMenuItemMarkChar", "")
                    if emptyModeMenu {
                        b.setAttribute(mode, kAXEnabledAttribute as String, true)
                        b.setAttribute(mode, "AXMenuItemMarkChar", "✓")
                    }
                    b.setChildren(f.mixer, [f.strips[0], restoredSource])
                    b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, restoredSource)
                    if let inverseFault, inverseFault.hasPrefix("after_") {
                        f.routingLateScopeInjected = true
                        if inverseFault == "after_level" { b.setAttribute(b.element(1_965_2664), kAXValueAttribute as String, 1) }
                        if inverseFault == "after_bypass" { b.setAttribute(b.element(1_965_2662), kAXValueAttribute as String, 1) }
                        if inverseFault == "after_mode" { b.setAttribute(mode, kAXTitleAttribute as String, "Pre Fader") }
                    }
                    return true
                }
                Issue.record("Only the owned send popup, one destination leaf and Cancel may run"); return false
            }
            f.routingReadResult = { element, attribute in
                if sagaMode == "late_inverse_mode", f.routingDestinationPresses == 1, CFEqual(element, stereo) {
                    if attribute == kAXTitleAttribute as String, f.routingClassifierHelpReads > 0 {
                        f.routingClassifierHelpReads += 1
                        // The fresh checked-current scan is followed by the
                        // final offered-leaf lookup; mutate only that later read.
                        if f.routingClassifierHelpReads == 3 {
                            b.setAttribute(mode, kAXTitleAttribute as String, "Pre Fader")
                            f.routingLateScopeInjected = true
                        }
                    }
                }
                if sagaMode == "unknown_after", f.routingLateScopeInjected,
                   CFEqual(element, renewedList), attribute == kAXDescriptionAttribute as String {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                if let inspectSendWitness, CFEqual(element, mode),
                   b.makeAXRuntime().children(f.mixer).contains(where: { CFEqual($0, root) }) {
                    if inspectSendWitness == "malformed_title", attribute == kAXTitleAttribute as String {
                        f.routingLateScopeInjected = true; return .success(NSNumber(value: 123))
                    }
                    if attribute == "AXMenuItemMarkChar" {
                        if inspectTypedMode {
                            f.routingModeInspectionReads += 1
                            if inspectSendWitness == "typed_mode_unreadable" {
                                f.routingLateScopeInjected = true
                                return .failure(.init(raw: AXError.cannotComplete.rawValue))
                            }
                            if inspectSendWitness == "typed_mode_disagree", f.routingModeInspectionReads == 4 {
                                f.routingLateScopeInjected = true
                                b.setAttribute(preFader, "AXMenuItemMarkChar", "")
                                b.setAttribute(mode, "AXMenuItemMarkChar", "✓")
                            }
                        }
                        if ["unsupported_mark", "unread_mark"].contains(inspectSendWitness) {
                            f.routingLateScopeInjected = true
                            return .failure(.init(raw: inspectSendWitness == "unsupported_mark"
                                ? AXError.noValue.rawValue : AXError.cannotComplete.rawValue))
                        }
                        if ["changed_control", "typed_mode_changed_control"].contains(inspectSendWitness), !f.routingLateScopeInjected {
                            f.routingLateScopeInjected = true
                            b.setChildren(originalSend[1], [b.element(1_965_2622), renewedList])
                        }
                    }
                }
                if readRestored == "retired_source", f.routingLateScopeInjected, CFEqual(element, restoredSource) {
                    return .failure(.init(raw: AXError.invalidUIElement.rawValue))
                }
                if emptyModeMenu, removing, f.routingDestinationPresses == 1, CFEqual(element, mode) {
                    if attribute == "AXMenuItemMarkChar" {
                        f.routingClassifierHelpReads += 1
                        if inverseFault == "empty_mode_mark_unreadable" {
                            f.routingLateScopeInjected = true
                            return .failure(.init(raw: AXError.cannotComplete.rawValue))
                        }
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    if attribute == kAXEnabledAttribute as String, inverseFault == "empty_mode_enabled_unreadable" {
                        f.routingLateScopeInjected = true
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                }
                if survivingSource, modeCommand != nil, f.routingModePresses > 0 {
                    if fault == "mode_control_header", CFEqual(element, f.headers[0]) {
                        return .failure(.init(raw: AXError.invalidUIElement.rawValue))
                    }
                    if (originalSend + [originalList, b.element(1_965_2622)]).contains(where: { CFEqual($0, element) }) {
                        return .failure(.init(raw: AXError.invalidUIElement.rawValue))
                    }
                }
                if survivingSource, f.routingDestinationPresses == 1 {
                    if fault == "healthy_header_retired", CFEqual(element, f.headers[0]) {
                        return .failure(.init(raw: AXError.invalidUIElement.rawValue))
                    }
                    if fault == "healthy_unreadable", CFEqual(element, renewedSend[0]) {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    if (originalSend + [originalList, b.element(1_965_2622)]).contains(where: { CFEqual($0, element) }) {
                        return .failure(.init(raw: AXError.invalidUIElement.rawValue))
                    }
                }
                if lateRemovalChoice {
                    if CFEqual(element, b.element(1_965_2622)), attribute == kAXIdentifierAttribute as String {
                        f.routingClassifierHelpReads = 1
                    }
                    if CFEqual(element, destination), attribute == kAXTitleAttribute as String,
                       f.routingClassifierHelpReads > 0 { f.routingClassifierHelpReads += 1 }
                    let candidate = fault == "late_child_role" ? leafChild : competitor
                    let decidingAttribute = fault?.hasPrefix("late_title") == true ? kAXTitleAttribute : kAXRoleAttribute
                    if f.routingClassifierHelpReads == 5, !f.routingLateScopeInjected,
                       CFEqual(element, candidate), attribute == decidingAttribute as String {
                        f.routingLateScopeInjected = true
                        return fault?.hasSuffix("number") == true ? .success(NSNumber(value: 123)) : .success(nil)
                    }
                }
                if restoring, inverseFault == "unreadable_echo_mark", f.routingLateScopeInjected,
                   f.routingDestinationPresses == 1, CFEqual(element, echo), attribute == "AXMenuItemMarkChar" {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                if removing, fault == "unreadable", f.routingReplacement != nil,
                   CFEqual(element, renewedSend[0]) {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                if fault == "unreadable", f.routingReplacement != nil, CFEqual(element, b.element(1_965_2644)) {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                guard f.routingReplacement != nil,
                      (originalSend + [originalList, b.element(1_965_2622)]).contains(where: { CFEqual($0, element) })
                else { return nil }
                return .failure(.init(raw: AXError.invalidUIElement.rawValue))
            }
            let before = try await inspect(f, cache: cache, registry: registry,
                domains: inspectSendWitness == nil && canonicalSend == nil ? ["associations"] : ["tracks", "strips", "associations", "routing"])
            if ["changed_control", "typed_mode_changed_control"].contains(inspectSendWitness ?? ""), before["snapshot_id"] == nil {
                #expect(f.routingLateScopeInjected && f.routingDestinationPresses == 0)
                #expect(before["state"] as? String == "C")
                return
            }
            let id = try #require(before["snapshot_id"] as? String)
            let capture = try #require(await cache.retainedInspection(id: id)).capture
            let row = try #require(capture.channelStrips.indices.first {
                capture.channelStrips[$0].physicalBinding.map { CFEqual($0.strip, f.strips[1]) } == true
            })
            let reference = try #require(capture.mixerReference(at: row))
            let originalPair = try #require(capture.freshPopulation?.selectionAssociations.first {
                CFEqual($0.strip.strip, f.strips[1])
            })
            #expect(CFEqual(originalPair.track.header, f.headers[0]))
            if let canonicalSend {
                let router = ChannelRouter(), gate = LogicMutationGate()
                guard case .issued(let project)? = capture.projectIssuance else {
                    Issue.record("The capture must issue its actual project"); return
                }
                let target = try #require(capture.issued?.byRow[0])
                let key = (canonicalPhysical ? "canonical-physical-send-" : "canonical-send-") + canonicalSend, journal = SagaJournal()
                await router.register(SendRemovalSagaResultBoundary(base: f.channel(), journal: journal,
                    mode: canonicalSend == "cancel" ? "cancel" : "completed", idempotencyKey: key,
                    beforeForward: {
                        if canonicalSend == "late_replacement" {
                            let decoy = b.element(1_965_2799)
                            b.setButton(decoy, description: "list", x: 0, y: 0, width: 1, height: 1)
                            b.setChildren(decoy, []); b.setActionNames(decoy, [kAXPressAction as String])
                            b.setChildren(b.element(1_965_2621), [b.element(1_965_2622), decoy])
                            f.routingLateScopeInjected = true
                        }
                    }))
                let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                    poller: StatePoller(axChannel: f.channel(), cache: cache,
                        runtime: .init(hasVisibleWindow: { false }, keyboardFocus: { .notTextEditing })),
                    dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal,
                    mutationGate: gate, liveTrackNames: { [:] })
                let planHandler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "plan_session_repair"))
                var sendIntent: [String: Value] = ["target": .string("source"),
                    canonicalSend == "physical_slot" ? "physical_slot" : "observed_ordinal": .int(1)]
                if canonicalPhysical {
                    sendIntent["output"] = (canonicalMatching ? !freshPhysicalReturn : freshPhysicalReturn && canonicalSend != "unsupported_pair") ? .object(["kind": .string("stereo_output")])
                        : .object(["kind": .string("physical"), "ports": .array(canonicalSend == "unsupported_pair" ? [.int(1), .int(2)] : [.int(3), .int(4)])])
                } else { sendIntent["remove"] = .bool(true) }
                if canonicalSend == "physical_removal" {
                    sendIntent["output"] = nil
                    sendIntent["remove"] = .bool(true)
                }
                var policy: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(project.rawValue),
                    "targets": .array([.object(["handle": .string("source"), "track_ref": .string(target.rawValue)])]),
                    "sends": .array([.object(sendIntent)])]
                if canonicalSend == "mixed" { policy["presentation"] = .object(["mixer_visible": .bool(true)]) }
                if ["missing_witness", "decoded"].contains(canonicalSend) {
                    var fresh = capture.freshPopulation
                    let withoutControl: [SessionPopulationObservation.HeldCheckedOutput] = (fresh?.checkedOutputs ?? []).map { reading in
                        var copy = reading; copy.sendControl = nil; return copy
                    }
                    fresh?.checkedOutputs = withoutControl
                    let rows = canonicalSend == "decoded"
                        ? try JSONDecoder().decode([ChannelStripState].self, from: JSONEncoder().encode(capture.channelStrips))
                        : capture.channelStrips
                    let altered = SessionPopulationObservation.Capture(before: capture.before, after: capture.after,
                        projectEpoch: capture.projectEpoch, project: capture.project, tracks: capture.tracks,
                        tracksFetchedAt: capture.tracksFetchedAt, channelStrips: rows,
                        mixerFetchedAt: capture.mixerFetchedAt, fileTrackCount: capture.fileTrackCount,
                        projectFileNotBound: capture.projectFileNotBound, requestedProjectMatches: capture.requestedProjectMatches,
                        referencesEnabled: capture.referencesEnabled, targetSnapshot: capture.targetSnapshot,
                        issued: capture.issued, projectIssuance: capture.projectIssuance,
                        beganAt: capture.beganAt, endedAt: capture.endedAt, captureID: capture.captureID,
                        freshPopulation: fresh, mixerReferences: capture.mixerReferences)
                    guard case .accepted(let parsed) = ProjectSessionAudit.parseIntentPolicy(policy) else {
                        Issue.record("The explicit selector must parse"); return
                    }
                    let request = try #require(await cache.retainedInspection(id: id)).request
                    let blocked = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: parsed, policyValue: .object(policy),
                        names: [], capture: altered, request: request, snapshotCurrent: true)
                    let executable = try #require(sharedJSONObject(blocked.json)?["executable"] as? Bool)
                    #expect(!executable)
                    #expect(f.routingDestinationPresses == 0)
                    return
                }
                let plannedText = sharedToolText(await planHandler(dependencies,
                    ["snapshot_id": .string(id), "policy": .object(policy)]))
                let planned = try #require(sharedJSONObject(plannedText))
                if ["physical_slot", "mixed", "unsupported_pair", "physical_removal"].contains(canonicalSend) {
                    let executable = try #require(planned["executable"] as? Bool)
                    #expect(!executable)
                    #expect(f.routingDestinationPresses == 0)
                    return
                }
                let executable = try #require(planned["executable"] as? Bool)
                #expect(executable, "Actual plan: \(plannedText)")
                let planID = try #require(planned["plan_id"] as? String)
                let digest = try #require(planned["digest"] as? String)
                let preview = try #require(planned["steps"] as? [[String: Any]])
                if canonicalMatching {
                    try #require(executable)
                    #expect(preview.isEmpty)
                    #expect(planned["unchanged_tasks"] as? [String] == ["send.target.source.ordinal.1"])
                    let apply = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "apply_session_repair"))
                    let arguments: [String: Value] = ["plan_id": .string(planID),
                        "digest": .string(matchingFault == "wrong_digest" ? String(repeating: "0", count: 64) : digest),
                        "confirmed": .bool(matchingFault != "unconfirmed"), "idempotency_key": .string(key)]
                    switch matchingFault {
                    case "replacement":
                        let decoy = b.element(1_965_2799)
                        b.setButton(decoy, description: "list", x: 0, y: 0, width: 1, height: 1)
                        b.setChildren(decoy, []); b.setActionNames(decoy, [kAXPressAction as String])
                        b.setChildren(b.element(1_965_2621), [b.element(1_965_2622), decoy])
                    case "late_replacement":
                        f.routingRead = { element, attribute in
                            guard CFEqual(element, b.element(1_965_721)), attribute == kAXValueAttribute as String,
                                  !f.routingLateScopeInjected else { return }
                            f.routingLateScopeInjected = true
                            let decoy = b.element(1_965_2799)
                            b.setButton(decoy, description: "list", x: 0, y: 0, width: 1, height: 1)
                            b.setChildren(decoy, []); b.setActionNames(decoy, [kAXPressAction as String])
                            b.setChildren(b.element(1_965_2621), [b.element(1_965_2622), decoy])
                        }
                    case "wrong_project": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    case "destination":
                        b.setAttribute(echo, kAXTitleAttribute as String, freshPhysicalReturn ? "Stereo Output" : "Output 3-4")
                        b.setAttribute(stereo, "AXMenuItemMarkChar", "")
                        b.setAttribute(destination, "AXMenuItemMarkChar", "✓")
                    case "level": b.setAttribute(b.element(1_965_2624), kAXValueAttribute as String, 1)
                    case "bypass": b.setAttribute(b.element(1_965_2622), kAXValueAttribute as String, 1)
                    case "mode": b.setAttribute(mode, kAXTitleAttribute as String, "Pre Fader")
                    case "unread_mark":
                        b.setAttribute(echo, "AXMenuItemMarkChar", "")
                        b.setAttribute(stereo, "AXMenuItemMarkChar", "")
                    case "source_retired": b.setChildren(f.mixer, [f.strips[0]])
                    case "cleanup_focus":
                        let prior = f.routingAction
                        f.routingAction = { element, action in
                            let result = prior?(element, action) ?? false
                            if CFEqual(element, root), action == kAXCancelAction as String {
                                f.routingLateScopeInjected = true
                                b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.strips[0])
                            }
                            return result
                        }
                    default: break
                    }
                    let readsBeforeApply = f.routingBypassMenuOpens
                    let result = await apply(dependencies, arguments)
                    let body = try #require(sharedJSONObject(sharedToolText(result)))
                    if let matchingFault {
                        #expect(body["state"] as? String == "C", "Actual refusal for \(matchingFault): \(sharedToolText(result))")
                        #expect(f.routingDestinationPresses == 0)
                        if matchingFault == "cleanup_focus" {
                            #expect(f.routingLateScopeInjected)
                            let receipt = try #require(body["send_read_receipt"] as? [String: Any])
                            #expect(receipt["focus_restoration"] as? String == "not_restored")
                            #expect(receipt["popup_menu_state"] as? String == "closed")
                        }
                        if matchingFault == "late_replacement" { #expect(f.routingLateScopeInjected) }
                        if ["replacement", "late_replacement", "wrong_project", "level", "bypass", "source_retired", "wrong_digest", "unconfirmed"].contains(matchingFault) {
                            #expect(f.routingBypassMenuOpens == readsBeforeApply, "Invalid custody/approval refuses before opening a popup")
                        } else { #expect(f.routingBypassMenuOpens > readsBeforeApply) }
                        #expect(!gate.isHeldByEntitledHolder())
                        return
                    }
                    #expect(body["saga_state"] as? String == "completed")
                    let attempted = try #require(body["write_attempted"] as? Bool)
                    #expect(!attempted)
                    #expect(body["writes_performed"] as? Int == 0)
                    #expect(f.routingDestinationPresses == 0)
                    #expect(f.routingBypassMenuOpens > readsBeforeApply)
                    let evidence = try #require(body["goal_evidence"] as? [[String: Any]])
                    #expect(evidence.count == 1)
                    let read = try #require(evidence.first?["read"] as? [String: Any])
                    #expect(read["read_source"] as? String == "ax_send_menu_checkmark")
                    #expect(read["provenance"] as? String == "live_independent")
                    #expect(read["observed"] as? String == (freshPhysicalReturn ? OutputAssignment.physical(3, 4) : .stereoOutput).token)
                    let readsBeforeReplay = f.routingBypassMenuOpens
                    _ = await apply(dependencies, arguments)
                    #expect(f.routingDestinationPresses == 0)
                    #expect(f.routingBypassMenuOpens == readsBeforeReplay)
                    #expect(!gate.isHeldByEntitledHolder())
                    return
                }
                #expect(preview.count == 1 && preview[0]["kind"] as? String == (canonicalPhysical ? "local_send_output" : "local_send_removal"))
                #expect(preview[0]["observed_ordinal"] as? Int == 1 && preview[0]["physical_slot"] == nil)
                if canonicalPhysical {
                    let before = try #require(preview[0]["before"] as? [String: Any])
                    let after = try #require(preview[0]["after"] as? [String: Any])
                    if freshPhysicalReturn {
                        #expect(before["kind"] as? String == "physical" && before["ports"] as? [Int] == [3, 4])
                        #expect(after["kind"] as? String == "stereo_output" && after["ports"] == nil)
                    } else {
                        #expect(before["kind"] as? String == "stereo_output")
                        #expect(after["kind"] as? String == "physical" && after["ports"] as? [Int] == [3, 4])
                    }
                    #expect(before["level_raw"] as? Int == 0)
                    let bypassed = try #require(before["bypassed"] as? Bool)
                    #expect(!bypassed)
                }
                if canonicalSend == "replacement" {
                    let decoy = b.element(1_965_2799)
                    b.setButton(decoy, description: "list", x: 0, y: 0, width: 1, height: 1)
                    b.setChildren(decoy, []); b.setActionNames(decoy, [kAXPressAction as String])
                    b.setChildren(b.element(1_965_2621), [b.element(1_965_2622), decoy])
                }
                if canonicalSend == "wrong_project" {
                    b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                }
                let apply = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "apply_session_repair"))
                let arguments: [String: Value] = ["plan_id": .string(planID),
                    "digest": .string(canonicalSend == "wrong_digest" ? String(repeating: "0", count: 64) : digest),
                    "confirmed": .bool(true), "idempotency_key": .string(key)]
                let result = await apply(dependencies, arguments)
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                if ["replacement", "late_replacement", "wrong_digest", "wrong_project"].contains(canonicalSend) {
                    #expect(body["state"] as? String == "C", "Actual refusal: \(sharedToolText(result))")
                    #expect(f.routingDestinationPresses == 0)
                    if canonicalSend == "late_replacement" {
                        #expect(f.routingLateScopeInjected)
                        #expect(f.routingBypassMenuOpens == 0, "Refuse the same-valued replacement before its popup is opened")
                    }
                } else {
                    #expect(body["saga_state"] as? String == (canonicalSend == "cancel" ? "fullyCompensated" : "completed"),
                        "Actual apply: \(sharedToolText(result))")
                    #expect(f.routingDestinationPresses == (canonicalSend == "cancel" ? 2 : 1))
                    if canonicalPhysical {
                        let steps = try #require(body["steps"] as? [[String: Any]])
                        let evidence = try #require(steps[0]["evidence"] as? [String: Any])
                        let verification = try #require(evidence["verification"] as? [String: Any])
                        let readback = try #require(verification["readback"] as? [String: Any])
                        #expect(readback["observed"] as? String == (freshPhysicalReturn ? OutputAssignment.stereoOutput : .physical(3, 4)).token)
                        if canonicalSend == "cancel" {
                            let compensation = try #require(steps[0]["compensation"] as? [String: Any])
                            let inverseRead = try #require(compensation["readback"] as? [String: Any])
                            #expect(inverseRead["observed"] as? String == (freshPhysicalReturn ? OutputAssignment.physical(3, 4) : .stereoOutput).token)
                        }
                    }
                    let beforeReplay = f.routingDestinationPresses
                    _ = await apply(dependencies, arguments)
                    #expect(f.routingDestinationPresses == beforeReplay)
                }
                #expect(!gate.isHeldByEntitledHolder())
                return
            }
            if inspectSendWitness != nil {
                let checked = capture.freshPopulation?.checkedOutputs.filter {
                    $0.source.matches(originalPair.strip) && $0.sendOrdinal == 1
                } ?? []
                let healthy = inspectSendWitness == "typed_mode" || inspectSendWitness == "observed"
                    || projectionWitness?.hasPrefix("projection_") == true
                if healthy { #expect(checked.count == 1 && checked.first?.assignment == .stereoOutput) }
                else if !inspectTypedMode { #expect(f.routingLateScopeInjected) }
                let strips = try #require((before["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
                let target = try #require(strips.first { $0["mixer_strip_ref"] as? String == reference.rawValue })
                let slots = try #require(target["send_slots"] as? [[String: Any]])
                let send = try #require(slots.first { $0["ordinal"] as? Int == 1 })
                if inspectTypedMode {
                    if healthy {
                        #expect(send["mode"] as? String == "pre_fader")
                        let observedPan = try #require(send["independent_pan"] as? Bool)
                        #expect(observedPan)
                        #expect(send["mode_source"] as? String == "ax_send_mode_menu_census")
                        #expect(send["checked_destination"] as? String == OutputAssignment.stereoOutput.token)
                    } else {
                        #expect(send["mode"] == nil && send["independent_pan"] == nil && send["mode_source"] == nil)
                        #expect(f.routingModeInspectionReads > 0)
                        if ["typed_mode_unreadable", "typed_mode_disagree", "typed_mode_changed_control"].contains(inspectSendWitness ?? "") {
                            #expect(f.routingLateScopeInjected)
                        }
                    }
                    #expect(send["level_raw"] as? Double == 0)
                    let observedBypass = try #require(send["bypassed"] as? Bool)
                    #expect(!observedBypass)
                    #expect(send["physical_slot"] == nil)
                    #expect(f.routingDestinationPresses == 0 && f.routingModePresses == 0)
                    if projectionWitness?.hasPrefix("projection_") != true { return }
                }
                if healthy && !inspectTypedMode {
                    #expect(send["checked_nonrouting_titles"] as? [String] == ["Post Pan"])
                    #expect(send["nonrouting_source"] as? String == "ax_send_menu_checkmark")
                } else if !inspectTypedMode {
                    #expect(send["checked_nonrouting_titles"] == nil && send["nonrouting_source"] == nil)
                }
                #expect(send["physical_slot"] == nil)
                if !inspectTypedMode { #expect(send["mode"] == nil) }
                #expect(f.routingDestinationPresses == 0)
                if inspectSendWitness != "changed_control" {
                    #expect((before["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
                }
                if let inspectSendWitness = projectionWitness, inspectSendWitness.hasPrefix("projection_") {
                    var forged = capture.channelStrips[row]
                    forged.sendSlots = forged.sendSlots?.map { slot in
                        var result = slot
                        result.checkedNonRoutingTitles = ["forged mode"]
                        result.nonRoutingSource = "forged source"
                        result.mode = "forged mode"; result.independentPan = false; result.modeSource = "forged source"
                        return result
                    }
                    if inspectSendWitness == "projection_duplicate_ordinal", let slot = forged.sendSlots?.first(where: { $0.ordinal == 1 }) {
                        forged.sendSlots?.append(slot)
                    }
                    if inspectSendWitness == "projection_decoded" {
                        forged = try JSONDecoder().decode(ChannelStripState.self, from: JSONEncoder().encode(forged))
                        #expect(forged.physicalBinding == nil)
                    }
                    var fresh = capture.freshPopulation
                    if inspectSendWitness == "projection_duplicate" { fresh?.checkedOutputs += checked }
                    if inspectSendWitness == "projection_foreign", let witness = checked.first {
                        fresh?.checkedOutputs = [.init(source: .init(window: witness.source.window, mixer: witness.source.mixer,
                            strip: f.strips[0], document: witness.source.document), assignment: witness.assignment,
                            sendOrdinal: 1, sendNonRoutingChecks: ["foreign mode"], sendMode: witness.sendMode)]
                    }
                    if inspectSendWitness == "projection_cached" { fresh = nil }
                    if inspectSendWitness == "projection_unstable" { fresh?.stable = false }
                    let altered = SessionPopulationObservation.Capture(before: capture.before, after: capture.after,
                        projectEpoch: capture.projectEpoch, project: capture.project, tracks: capture.tracks,
                        tracksFetchedAt: capture.tracksFetchedAt, channelStrips: capture.channelStrips,
                        mixerFetchedAt: capture.mixerFetchedAt, fileTrackCount: capture.fileTrackCount,
                        projectFileNotBound: capture.projectFileNotBound, requestedProjectMatches: capture.requestedProjectMatches,
                        referencesEnabled: capture.referencesEnabled, targetSnapshot: capture.targetSnapshot,
                        issued: capture.issued, projectIssuance: capture.projectIssuance,
                        beganAt: capture.beganAt, endedAt: capture.endedAt, captureID: capture.captureID,
                        freshPopulation: fresh, mixerReferences: capture.mixerReferences)
                    let projected = try #require(SessionPopulationObservation.reportedSendSlots(of: forged,
                        capture: altered, qualified: inspectSendWitness != "projection_unqualified"))
                    #expect(projected.allSatisfy { $0.checkedNonRoutingTitles == nil && $0.nonRoutingSource == nil })
                    #expect(projected.allSatisfy { $0.mode == nil && $0.independentPan == nil && $0.modeSource == nil })
                }
                return
            }
            let initialSelections = f.selections
            if fault == "missing_pair" || fault == "expired_pair" || fault == "expired_noop" { f.expireRetainedCapture = true }
            if fault == "expired_pair" || fault == "expired_noop" {
                #expect(await cache.retainedInspection(id: id) == nil)
                #expect(await cache.retainedMixerAssociation(reference: reference, source: originalPair.strip,
                    snapshot: await registry.currentSnapshot) == nil)
                let stillIssued = try #require(await registry.resolve(reference)?.physicalMixerStrip)
                #expect(stillIssued.matches(originalPair.strip), "The physical ref outlives only the retained header tether")
                #expect(f.routingDestinationPresses == 0 && f.routingReplacement == nil)
            }
            f.routingRead = { element, attribute in
                if let boundary = modePeerBoundary, f.routingModePresses == 0,
                   CFEqual(element, extraSend[0]), attribute == kAXHelpAttribute as String {
                    boundary.peerReads += 1
                    if boundary.peerReads == boundary.injectAt {
                        boundary.mutations += 1
                        if creationSaga != nil { f.routingLateScopeInjected = true }
                        if boundary.independentPan { b.setAttribute(independentPan, "AXMenuItemMarkChar", "✓") }
                        else {
                            b.setAttribute(mode, "AXMenuItemMarkChar", "")
                            b.setAttribute(postPan, "AXMenuItemMarkChar", "✓")
                        }
                    }
                }
                if ["calibrate_late_target", "late_target"].contains(freshEmpty ?? ""), f.routingDestinationPresses == 1 {
                    if CFEqual(element, b.element(1_965_2644)), attribute == kAXValueAttribute as String {
                        f.routingIndependentSendReads += 1
                    }
                    if CFEqual(element, extraSend[0]), attribute == kAXHelpAttribute as String,
                       f.routingIndependentSendReads > 0 {
                        f.routingBypassFinalValueReads = f.routingIndependentSendReads
                        if let freshAfterTargetReads, f.routingIndependentSendReads == freshAfterTargetReads,
                           !f.routingLateScopeInjected {
                            f.routingLateScopeInjected = true
                            b.setAttribute(b.element(1_965_2644), kAXValueAttribute as String, 1)
                            b.setAttribute(b.element(1_965_2642), kAXValueAttribute as String, 1)
                        }
                    }
                }
                if bypassMode == "final_record_document", f.routingBypassFinalCapabilityRead,
                   CFEqual(element, b.element(1_965_722)), attribute == kAXValueAttribute as String,
                   !f.routingLateScopeInjected {
                    f.routingLateScopeInjected = true
                    b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                }
                if ["changed_route", "changed_mode"].contains(bypassMode ?? ""),
                   f.routingBypassMenuOpens == 2, CFEqual(element, echo),
                   attribute == kAXTitleAttribute as String, !f.routingLateScopeInjected {
                    f.routingLateScopeInjected = true
                    if bypassMode == "changed_route" {
                        b.setAttribute(echo, kAXTitleAttribute as String, "Output 3-4")
                        b.setAttribute(stereo, "AXMenuItemMarkChar", "")
                        b.setAttribute(destination, "AXMenuItemMarkChar", "✓")
                    } else { b.setAttribute(mode, kAXTitleAttribute as String, "Pre Fader") }
                }
                if bypassMode == "late_bit", f.routingBypassMenuCancels == 3 {
                    if CFEqual(element, b.element(1_965_2622)), attribute == kAXValueAttribute as String {
                        f.routingBypassFinalValueReads += 1
                    }
                }
                if sagaMode == "late_inverse_mode", f.routingDestinationPresses == 1,
                   CFEqual(element, stereo), attribute == kAXEnabledAttribute as String {
                    f.routingClassifierHelpReads = 1
                }
                if readRestored != nil, f.routingDestinationPresses == 2,
                   CFEqual(element, b.element(1_965_2663)), attribute == kAXDescriptionAttribute as String {
                    f.routingIndependentSendReads += 1
                }
                // Legacy getRole uses the untyped attribute channel, whereas
                // the strict selector uses the typed result channel above.
                if lateRemovalChoice, fault == "late_child_role", f.routingClassifierHelpReads == 5,
                   !f.routingLateScopeInjected, CFEqual(element, leafChild), attribute == kAXRoleAttribute as String {
                    f.routingLateScopeInjected = true
                    b.setAttribute(leafChild, kAXRoleAttribute as String, NSNumber(value: 123))
                    return
                }
                guard f.routingReplacement != nil, f.selections.count == initialSelections.count + 2,
                      CFEqual(element, renewedList), attribute == kAXDescriptionAttribute as String,
                      b.makeAXRuntime().children(f.mixer).contains(where: { CFEqual($0, root) }),
                      ["deciding_control", "deciding_level"].contains(fault ?? ""), !f.routingLateScopeInjected else { return }
                f.routingLateScopeInjected = true
                if fault == "deciding_level" { b.setAttribute(b.element(1_965_2644), kAXValueAttribute as String, 1) }
                else {
                    let decoy = b.element(1_965_2690)
                    b.setButton(decoy, description: "list", x: 0, y: 0, width: 1, height: 1)
                    b.setChildren(decoy, []); b.setActionNames(decoy, [kAXPressAction as String])
                    b.setChildren(b.element(1_965_2641), [b.element(1_965_2642), decoy])
                }
            }
            let router = ChannelRouter(); await router.register(f.channel())
            let gate = LogicMutationGate()
            let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                poller: StatePoller(axChannel: f.channel(), cache: cache,
                    runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing })),
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate, liveTrackNames: { [:] })
            if levelMode != nil {
                let set = try #require(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "set_send_level_verified"))
                let knob = b.element(1_965_2624), field = b.element(1_965_2801)
                if levelMode?.hasPrefix("first_click_") == true {
                    b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
                }
                let minus95 = ["minus95", "deferred_minus95", "return_window_minus95"].contains(levelMode ?? "")
                let desired = minus95 ? "-95.0" : "-6.0"
                if levelMode == "preexisting_editor" {
                    b.setAttribute(f.app, kAXWindowsAttribute as String, [f.window, b.element(1_965_2800)])
                }
                if levelMode == "return_window_before_fields_retired_peer" {
                    // The measured host retired a different original window
                    // along with its numeric editor, not the owned source.
                    b.setAttribute(f.app, kAXWindowsAttribute as String, [f.window, b.element(1_965_2892)])
                }
                var prepared: [String: Value] = ["target_ref": .string(reference.rawValue), "ordinal": .int(1),
                    "level_db": .string(desired), "expected_current": .string("-∞")]
                switch levelMode {
                case "boolean_raw": b.setAttribute(knob, kAXValueAttribute as String, true)
                case "wrong_expected": prepared["expected_current"] = .string("-95")
                case "unsupported_level": prepared["level_db"] = .string("-12")
                case "wrong_target": prepared["target_ref"] = .string(try #require(capture.issued?.byRow[0]).rawValue)
                case "wrong_project": prepared["project_ref"] = .string("prj_foreign")
                case "extra_param": prepared["value"] = .double(0.5)
                case "scalar_level": prepared["level_db"] = .double(-6)
                case "noop": prepared["level_db"] = .string("-∞")
                case "wrong_hit": f.routingLevelHit = f.strips[0]
                default: break
                }
                if levelMode == "late_hit_document" {
                    f.routingLevelHitEffect = {
                        f.routingLateScopeInjected = true
                        b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                }
                let priorRead = f.routingRead
                if levelMode == "slow_transport_pair" {
                    f.routingLegacyChildrenRead = { element in
                        // This unrelated peer subtree is reached by the full
                        // transport-bar search, never a held control/path read.
                        if f.routingLevelClicks.last == 1, CFEqual(element, f.strips[0]) {
                            f.routingLevelPairExpired = true
                        }
                    }
                }
                @Sendable func returnedWindow() {
                    let text = b.attributeValue(field, kAXValueAttribute as String) as? String ?? ""
                    b.setAttribute(knob, kAXValueAttribute as String, text == "-∞" ? 0 : 123456)
                    b.setAttribute(knob, kAXValueDescriptionAttribute as String, text)
                    b.setAttribute(f.app, kAXWindowsAttribute as String, [f.window])
                    b.setAttribute(f.app, kAXFocusedWindowAttribute as String, f.window)
                    b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.strips[1])
                    f.routingLevelReturnTransitions += 1
                    f.routingLevelCommitPending = false
                    if ["return_window_foreign_focus", "return_window_before_fields_foreign_focus"].contains(levelMode ?? "") {
                        let foreign = b.element(1_965_2895)
                        b.setRole(foreign, kAXTextFieldRole as String)
                        b.setAttribute(foreign, kAXWindowAttribute as String, f.window)
                        b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, foreign)
                    }
                    if ["return_window_foreign_window", "return_window_before_fields_foreign_window"].contains(levelMode ?? "") {
                        b.setAttribute(f.app, kAXFocusedWindowAttribute as String, b.element(1_965_2894))
                    }
                }
                let priorResult = f.routingReadResult
                f.routingReadResult = { element, attribute in
                    if levelMode == "first_click_window_unreadable", f.routingLevelClicks.last == 1,
                       CFEqual(element, knob), attribute == kAXWindowAttribute as String {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    // Virtual host clock at the strict metadata seam used by
                    // the expensive complete Mixer discovery, not a sleep/SLA.
                    if levelMode == "slow_pair", f.routingLevelClicks.last == 1,
                       attribute == kAXIdentifierAttribute as String {
                        f.routingLevelPairExpired = true
                    }
                    if levelMode == "return_window_source", f.routingLevelCommitPending,
                       f.routingLevelPendingFieldReads > 0, CFEqual(element, f.window),
                       attribute == kAXDocumentAttribute as String, !f.routingLevelTransientSourceLost {
                        returnedWindow()
                        f.routingLevelTransientSourceLost = true
                        return .success("file:///tmp/Foreign.logicx" as NSString)
                        // Subsequent source reads are healthy: a failed owner must still stay lost.
                    }
                    return priorResult?(element, attribute)
                }
                f.routingRead = { element, attribute in
                    priorRead?(element, attribute)
                    if levelMode?.hasPrefix("return_window_before_fields") == true, f.routingLevelCommitPending,
                       CFEqual(element, f.app), attribute == kAXMainWindowAttribute as String {
                        // Return completed while the first ownership census
                        // ran, before any read of the retiring editor field.
                        returnedWindow()
                        if levelMode == "return_window_before_fields_source" {
                            f.routingLevelTransientSourceLost = true
                            b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        }
                        if levelMode == "return_window_before_fields_new_window" {
                            b.setAttribute(f.app, kAXWindowsAttribute as String, [f.window, b.element(1_965_2893)])
                        }
                        if levelMode == "return_window_before_fields_duplicate_source" {
                            b.setAttribute(f.app, kAXWindowsAttribute as String, [f.window, f.window])
                        }
                    }
                    if levelMode == "slow_pair", f.routingLevelClicks.last == 1,
                       attribute == kAXIdentifierAttribute as String {
                        f.routingLevelPairExpired = true
                    }
                    if levelMode?.hasPrefix("return_window") == true, f.routingLevelCommitPending {
                        if CFEqual(element, field), attribute == kAXValueAttribute as String {
                            f.routingLevelPendingFieldReads += 1
                        }
                        if !["return_window_source", "return_window_gate"].contains(levelMode ?? ""),
                           f.routingLevelPendingFieldReads > 0, CFEqual(element, f.app),
                           attribute == kAXFocusedWindowAttribute as String { returnedWindow() }
                    }
                    guard ["late_play", "late_record", "late_document", "changed_raw", "replaced_control"].contains(levelMode ?? ""),
                          CFEqual(element, field), attribute == kAXValueAttribute as String,
                          f.routingLevelWrites.isEmpty, !f.routingLateScopeInjected else { return }
                    f.routingLateScopeInjected = true
                    switch levelMode {
                    case "late_document": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    case "changed_raw": b.setAttribute(knob, kAXValueAttribute as String, 99)
                    case "replaced_control":
                        let replacementKnob = b.element(1_965_2898)
                        b.setRole(replacementKnob, kAXSliderRole as String)
                        b.setAttribute(replacementKnob, kAXHelpAttribute as String, "Send Level knob. Set level.")
                        b.setAttribute(replacementKnob, kAXValueAttribute as String, 0)
                        b.setAttribute(replacementKnob, kAXValueDescriptionAttribute as String, "-∞")
                        b.setChildren(replacementKnob, [])
                        b.setChildren(f.strips[1], (b.makeAXRuntime().children(f.strips[1])).map { CFEqual($0, knob) ? replacementKnob : $0 })
                    default: b.setAttribute(b.element(levelMode == "late_play" ? 1_965_721 : 1_965_722), kAXValueAttribute as String, 1)
                    }
                }
                let params = prepared
                if let levelSaga {
                    let journal = SagaJournal(maxRecords: 1), key = "owned-send-level-saga"
                    await router.register(SendRemovalSagaResultBoundary(base: f.channel(), journal: journal,
                        mode: levelSaga, operation: "mixer.set_send_level_verified", idempotencyKey: key,
                        afterForward: {
                            if levelSaga == "late_inverse_level" {
                                b.setAttribute(knob, kAXValueAttribute as String, 99)
                                b.setAttribute(knob, kAXValueDescriptionAttribute as String, "-95")
                                f.routingLateScopeInjected = true
                            }
                            if levelSaga == "late_inverse_document" {
                                b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                                f.routingLateScopeInjected = true
                            }
                            if levelSaga == "late_inverse_mode" {
                                b.setAttribute(mode, kAXTitleAttribute as String, "Post Pan")
                                f.routingLateScopeInjected = true
                            }
                            if levelSaga == "late_inverse_bypass" {
                                b.setAttribute(b.element(1_965_2622), kAXValueAttribute as String, true)
                                f.routingLateScopeInjected = true
                            }
                            if levelSaga == "late_inverse_peer" {
                                b.setChildren(f.strips[0], peerChildren + [extraSend[0]])
                                f.routingLateScopeInjected = true
                            }
                            if levelSaga == "late_inverse_control" {
                                let originalGroup = b.element(1_965_2621), replacementGroup = b.element(1_965_2899)
                                b.setRole(replacementGroup, kAXGroupRole as String)
                                b.setChildren(replacementGroup, b.makeAXRuntime().children(originalGroup))
                                b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]).map {
                                    CFEqual($0, originalGroup) ? replacementGroup : $0
                                })
                                f.routingLateScopeInjected = true
                            }
                        }))
                    let sagaDependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                        poller: StatePoller(axChannel: f.channel(), cache: cache,
                            runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing })),
                        dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal,
                        mutationGate: gate, liveTrackNames: { [:] })
                    var stepParams = params
                    stepParams.removeValue(forKey: "target_ref")
                    stepParams["level_db"] = .string("-6")
                    if case .issued(let project)? = capture.projectIssuance { stepParams["project_ref"] = .string(project.rawValue) }
                    if levelSaga == "wrong_project" { stepParams["project_ref"] = .string("prj_foreign") }
                    if levelSaga == "wrong_slot" { stepParams["ordinal"] = .int(0) }
                    let levelTarget = levelSaga == "wrong_target" ? try #require(capture.mixerReference(at: 0)) : reference
                    var wire: [String: Value] = ["idempotency_key": .string(key), "steps": .array([.object([
                        "operation_id": .string(OperationID.mixerSetSendLevelVerified.rawValue),
                        "target_ref": .string(levelTarget.rawValue), "params": .object(stepParams),
                        "expected_inverse": .object(["operation_id": .string(OperationID.mixerSetSendLevelVerified.rawValue),
                            "value_parameter": .string("level_db")])])])]
                    wire["confirmed_plan_hash"] = .string(SagaJournal.planHash(try SagaWire.plan(from: wire)))
                    if levelSaga == "wrong_hash" { wire["confirmed_plan_hash"] = .string(String(repeating: "0", count: 64)) }
                    let preflight = try #require(OperationHandlerRegistry.handler(tool: "logic_system", command: "saga_preflight"))
                    let preview = await FeatureFlags.withAdr004MutationSagaForTests(true) { await preflight(sagaDependencies, wire) }
                    let previewBody = try #require(sharedJSONObject(sharedToolText(preview)))
                    let ready = try #require(previewBody["ok"] as? Bool,
                        "Actual registered level preflight: \(sharedToolText(preview))")
                    if ["wrong_project", "wrong_target", "wrong_slot"].contains(levelSaga) {
                        #expect(!ready)
                        #expect(f.routingLevelWrites.isEmpty && f.routingLevelCommits == 0)
                        return
                    }
                    #expect(ready)
                    #expect(f.routingLevelWrites.isEmpty && f.routingLevelCommits == 0)
                    if levelSaga == "preflight" { return }
                    let execute = try #require(OperationHandlerRegistry.handler(tool: "logic_system", command: "saga_execute"))
                    let result = await FeatureFlags.withAdr004MutationSagaForTests(true) { await execute(sagaDependencies, wire) }
                    let resultBody = try #require(sharedJSONObject(sharedToolText(result)))
                    if levelSaga == "wrong_hash" {
                        #expect(resultBody["state"] as? String == "C")
                        let wrote = try #require(resultBody["write_attempted"] as? Bool); #expect(!wrote)
                        #expect(f.routingLevelWrites.isEmpty && f.routingLevelCommits == 0)
                        return
                    }
                    if ["no_observer", "lost_observer"].contains(levelSaga) || levelSaga.hasPrefix("late_inverse_") {
                        let terminal = try #require(resultBody["saga_state"] as? String)
                        #expect(terminal != "completed" && terminal != "fullyCompensated")
                        #expect(resultBody["state"] as? String == "B", "\(sharedToolText(result))")
                        let expectedWrites = levelSaga == "no_observer" ? 0 : 1
                        #expect(f.routingLevelWrites.count == expectedWrites && f.routingLevelCommits == expectedWrites)
                        #expect(f.routingDestinationPresses == 0 && !gate.isHeldByEntitledHolder())
                        if levelSaga.hasPrefix("late_inverse_") { #expect(f.routingLateScopeInjected) }
                        if levelSaga == "late_inverse_level" {
                            #expect(b.attributeValue(knob, kAXValueDescriptionAttribute as String) as? String == "-95")
                        }
                        let replay = await FeatureFlags.withAdr004MutationSagaForTests(true) { await execute(sagaDependencies, wire) }
                        let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
                        let duplicate = try #require(replayBody["duplicate"] as? Bool); #expect(duplicate)
                        #expect(replayBody["state"] as? String == "B")
                        #expect(f.routingLevelWrites.count == expectedWrites && f.routingLevelCommits == expectedWrites)
                        return
                    }
                    #expect(resultBody["saga_state"] as? String == "fullyCompensated", "\(sharedToolText(result))")
                    #expect(f.routingLevelWrites == ["-6", "-∞"] && f.routingLevelCommits == 2)
                    #expect(b.attributeValue(knob, kAXValueDescriptionAttribute as String) as? String == "-∞")
                    #expect(f.routingDestinationPresses == 0 && !gate.isHeldByEntitledHolder())
                    let replay = await FeatureFlags.withAdr004MutationSagaForTests(true) { await execute(sagaDependencies, wire) }
                    let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
                    if levelSaga == "cancel" {
                        #expect(replayBody["error"] as? String == HonestContract.FailureError.unsupportedState.rawValue)
                    } else {
                        let duplicate = try #require(replayBody["duplicate"] as? Bool); #expect(duplicate)
                    }
                    #expect(f.routingLevelWrites.count == 2 && f.routingLevelCommits == 2)
                    return
                }
                let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_send_level_verified",
                    commandParams: params, mutationGate: gate) {
                    if ["expired_deadline", "lost_gate", "deferred_cancel", "return_window_gate"].contains(levelMode ?? "") {
                        let parent = OperationTraceContext.current
                        let child = OperationTraceContext(mutationGateAcquired: parent?.mutationGateAcquired ?? false,
                            ownsGate: {
                                if levelMode == "return_window_gate", f.routingLevelCommitPending,
                                   f.routingLevelPendingFieldReads > 0, !f.routingLevelTransientGateLost {
                                    returnedWindow(); f.routingLevelTransientGateLost = true; return false
                                }
                                return levelMode == "lost_gate" ? false : parent?.ownsGate() == true
                            },
                            deadline: levelMode == "expired_deadline" ? ContinuousClock.now : parent?.deadline,
                            cancellationRequested: { f.routingLevelCancelled || parent?.cancellationRequested() == true })
                        return await OperationTraceContext.$current.withValue(child) { await set(dependencies, params) }
                    }
                    return await set(dependencies, params)
                }
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                if !["roundtrip", "slow_pair", "slow_transport_pair", "first_click_source_focus", "first_click_deferred_source_focus", "minus95", "noop", "deferred", "deferred_minus95", "return_window", "return_window_minus95", "return_window_before_fields", "return_window_before_fields_retired_peer"].contains(levelMode ?? "") {
                    if ["setter_ack_only", "commit_ack_only", "source_lost_after", "route_changed_after",
                        "deferred_foreign", "deferred_window", "deferred_source", "deferred_cancel", "deferred_never",
                        "return_window_foreign_focus", "return_window_foreign_window", "return_window_source", "return_window_gate",
                        "return_window_before_fields_foreign_focus", "return_window_before_fields_foreign_window",
                        "return_window_before_fields_source", "return_window_before_fields_new_window",
                        "return_window_before_fields_duplicate_source"].contains(levelMode ?? "") {
                        #expect(body["state"] as? String == "B", "\(sharedToolText(result))")
                        let attempted = try #require(body["write_attempted"] as? Bool)
                        #expect(attempted)
                        #expect(f.routingLevelWrites.count == 1 && f.routingLevelCommits <= 1)
                        #expect(f.routingDestinationPresses == 0)
                        if levelMode?.hasPrefix("deferred") == true {
                            #expect(f.routingLevelCommits == 1 && f.routingLevelCommitPending)
                            if levelMode == "deferred_never" { #expect(f.routingLevelWaits <= 2) }
                            else { #expect(f.routingLevelWaits == 0) }
                        }
                        if levelMode?.hasPrefix("return_window") == true {
                            #expect(f.routingLevelReturnTransitions == 1 && f.routingLevelWaits == 0)
                            if ["return_window_source", "return_window_before_fields_source"].contains(levelMode ?? "") { #expect(f.routingLevelTransientSourceLost) }
                            if levelMode == "return_window_gate" { #expect(f.routingLevelTransientGateLost) }
                        }
                        return
                    }
                    #expect(body["state"] as? String == "C", "\(sharedToolText(result))")
                    #expect(f.routingLevelWrites.isEmpty && f.routingLevelCommits == 0)
                    if levelMode == "preexisting_editor" { #expect(f.routingLevelClicks == [1, 2]) }
                    if levelMode == "late_hit_document" {
                        #expect(f.routingLateScopeInjected && f.routingLevelClicks.isEmpty)
                    }
                    if levelMode?.hasPrefix("first_click_") == true {
                        #expect(f.routingLateScopeInjected && f.routingLevelClicks == [1],
                            "A changed deciding source/focus after our first click must prevent the second click and data write")
                    }
                    if ["late_play", "late_record", "late_document", "changed_raw", "replaced_control", "editor_foreign", "editor_window", "editor_value"].contains(levelMode ?? "") {
                        #expect(f.routingLateScopeInjected, "Reach the actual owned editor boundary")
                    }
                    return
                }
                #expect(body["state"] as? String == "A", "\(sharedToolText(result))")
                if ["first_click_source_focus", "first_click_deferred_source_focus"].contains(levelMode ?? "") {
                    #expect(f.routingLateScopeInjected && f.routingLevelClicks == [1, 2],
                        "Reach the native-shaped exact-source focus landing after the first paired click")
                    #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored",
                        "Verified level data must not impersonate restoration of the original Tracks focus")
                }
                guard body["state"] as? String == "A" else {
                    if ["slow_pair", "slow_transport_pair"].contains(levelMode ?? "") {
                        #expect(f.routingLevelPairExpired && f.routingLevelClicks == [1, 2],
                            "Reach the costly discovery between the actual paired clicks")
                        return
                    }
                    if ["first_click_source_focus", "first_click_deferred_source_focus"].contains(levelMode ?? "") { return }
                    if levelMode?.hasPrefix("return_window") == true {
                        #expect(f.routingLevelCommits == 1 && f.routingLevelReturnTransitions == 1 && !f.routingLevelCommitPending)
                    } else {
                        #expect(f.routingLevelCommits == 1 && f.routingLevelCommitPending,
                            "The real registered Return must reach the deferred owned editor before refusing its after-state")
                    }
                    return // Never send a dependent inverse after an unverified forward.
                }
                if levelMode == "noop" {
                    #expect(f.routingLevelWrites.isEmpty && f.routingLevelClicks.isEmpty && f.routingLevelCommits == 0)
                    return
                }
                #expect(f.routingLevelWrites == [desired] && f.routingLevelClicks == [1, 2] && f.routingLevelCommits == 1)
                #expect(f.routingDestinationPresses == 0 && f.routingBypassPresses == 0)
                let inverse = params.merging(["level_db": Value.string("-∞"), "expected_current": .string(minus95 ? "-95" : "-6")]) { _, new in new }
                let restored = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_send_level_verified",
                    commandParams: inverse, mutationGate: gate) { await set(dependencies, inverse) }
                #expect(sharedJSONObject(sharedToolText(restored))?["state"] as? String == "A", "\(sharedToolText(restored))")
                #expect(f.routingLevelWrites == [desired, "-∞"] && f.routingLevelCommits == 2)
                if levelMode == "deferred" || levelMode == "deferred_minus95" {
                    #expect(f.routingLevelWaits == 2 && !f.routingLevelCommitPending)
                }
                if levelMode?.hasPrefix("return_window") == true {
                    #expect(f.routingLevelReturnTransitions == 2 && f.routingLevelWaits == 0)
                }
                return
            }
            if bypassMode != nil {
                let get = try #require(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "get_send_bypass_verified"))
                let set = try #require(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "set_send_bypass_verified"))
                let getterParams: [String: Value] = ["target_ref": .string(reference.rawValue), "ordinal": .int(1)]
                let beforeSlots = try #require(AXLogicProElements.sendSlotObservations(in: f.strips[1], runtime: f.logic().ax))
                let read = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "get_send_bypass_verified",
                    commandParams: getterParams, mutationGate: gate) {
                    await FeatureFlags.withAdr002TargetRefForTests(true) { await get(dependencies, getterParams) }
                }
                let initial = try #require(sharedJSONObject(sharedToolText(read)))
                #expect(initial["state"] as? String == "A", "Actual registered bypass read: \(sharedToolText(read))")
                let initialBypass = try #require(initial["bypassed"] as? Bool)
                #expect(!initialBypass)
                #expect(initial["ax_action_names"] as? [String] == [kAXPressAction as String])
                #expect(initial["ax_action_names_status"] as? Int == 0)
                f.routingBypassMenuOpens = 0; f.routingBypassMenuCancels = 0
                f.routingActionNames = { element in
                    if bypassMode == "final_record_document", f.routingBypassMenuCancels == 2,
                       CFEqual(element, b.element(1_965_2622)) {
                        f.routingBypassFinalCapabilityRead = true
                    }
                    guard ["late_play", "late_record", "changed_raw", "replaced_control", "foreign_document"].contains(bypassMode ?? ""),
                          f.routingBypassMenuCancels == 2, CFEqual(element, b.element(1_965_2622)),
                          !f.routingLateScopeInjected else { return nil }
                    f.routingLateScopeInjected = true
                    switch bypassMode {
                    case "changed_raw": b.setAttribute(b.element(1_965_2624), kAXValueAttribute as String, 1)
                    case "foreign_document": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    case "replaced_control":
                        let decoy = b.element(1_965_2797)
                        b.setRole(decoy, kAXCheckBoxRole as String); b.setAttribute(decoy, kAXValueAttribute as String, 0)
                        b.setChildren(decoy, []); b.setActionNames(decoy, [kAXPressAction as String])
                        b.setChildren(b.element(1_965_2621), [decoy, originalList])
                    default:
                        b.setAttribute(b.element(bypassMode == "late_play" ? 1_965_721 : 1_965_722),
                            kAXValueAttribute as String, 1)
                    }
                    return .success([kAXPressAction as String])
                }
                f.routingChildrenRead = { element in
                    // Calibrated in the healthy actual registered path: twelve
                    // strict checkbox reads after the third popup Cancel precede
                    // the final custody census, after the after-snapshot corroboration.
                    guard bypassMode == "late_bit", f.routingBypassMenuCancels == 3,
                          f.routingBypassFinalValueReads == 12, CFEqual(element, f.mixer),
                          !f.routingLateScopeInjected else { return }
                    f.routingLateScopeInjected = true
                    b.setAttribute(b.element(1_965_2622), kAXValueAttribute as String, 0)
                }
                if bypassMode != "roundtrip" {
                    var prepared: [String: Value] = getterParams.merging([
                        "bypassed": .bool(true), "expected_current": .bool(false)]) { _, new in new }
                    switch bypassMode {
                    case "delayed_off":
                        b.setAttribute(b.element(1_965_2622), kAXValueAttribute as String, 1)
                        prepared["bypassed"] = .bool(false); prepared["expected_current"] = .bool(true)
                    case "malformed_binary": b.setAttribute(b.element(1_965_2622), kAXValueAttribute as String, 2)
                    case "wrong_expected": prepared["expected_current"] = .bool(true)
                    case "wrong_target": prepared["target_ref"] = .string(try #require(capture.issued?.byRow[0]).rawValue)
                    case "wrong_project": prepared["project_ref"] = .string("prj_foreign")
                    case "extra_param": prepared["destination"] = .object(["kind": .string("no_send")])
                    case "missing_target": prepared.removeValue(forKey: "target_ref")
                    case "scalar_boolean": prepared["bypassed"] = .int(1)
                    case "negative_ordinal": prepared["ordinal"] = .int(-1)
                    case "unsupported_press": b.setActionNames(b.element(1_965_2622), [])
                    default: break
                    }
                    let setterParams = prepared
                    let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_send_bypass_verified",
                        commandParams: setterParams, mutationGate: gate) {
                        await FeatureFlags.withAdr002TargetRefForTests(bypassMode != "refs_disabled") {
                            if ["expired_deadline", "lost_gate"].contains(bypassMode ?? "") {
                                let parent = OperationTraceContext.current
                                let child = OperationTraceContext(mutationGateAcquired: parent?.mutationGateAcquired ?? false,
                                    ownsGate: { bypassMode == "lost_gate" ? false : parent?.ownsGate() == true },
                                    deadline: bypassMode == "expired_deadline" ? ContinuousClock.now : parent?.deadline,
                                    cancellationRequested: { parent?.cancellationRequested() == true })
                                return await OperationTraceContext.$current.withValue(child) { await set(dependencies, setterParams) }
                            }
                            return await set(dependencies, setterParams)
                        }
                    }
                    let body = try #require(sharedJSONObject(sharedToolText(result)))
                    if ["delayed_on", "delayed_off"].contains(bypassMode ?? "") {
                        #expect(f.routingLateScopeInjected && f.routingBypassPendingValue == nil)
                        #expect(f.routingBypassMenuOpens >= 3 && f.routingBypassPresses == 1)
                        #expect(body["state"] as? String == "A", "\(sharedToolText(result))")
                        let observed = try #require(body["bypassed"] as? Bool)
                        let observedBefore = try #require(body["before"] as? Bool)
                        if bypassMode == "delayed_on" { #expect(observed); #expect(!observedBefore) }
                        else { #expect(!observed); #expect(observedBefore) }
                        #expect(f.routingDestinationPresses == 0 && !gate.isHeldByEntitledHolder())
                        return
                    }
                    if ["late_play", "late_record", "late_bit", "final_record_document", "changed_route", "changed_mode", "changed_raw", "replaced_control", "foreign_document"].contains(bypassMode ?? "") {
                        #expect(f.routingLateScopeInjected, "The actual deciding boundary must be reached")
                    }
                    let afterAttempt = ["late_bit", "malformed_after", "lost_source_after", "press_failed"].contains(bypassMode ?? "")
                    #expect(body["state"] as? String == (afterAttempt ? "B" : "C"), "\(sharedToolText(result))")
                    #expect(f.routingBypassPresses == (afterAttempt ? 1 : 0))
                    #expect(f.routingDestinationPresses == 0)
                    #expect(!gate.isHeldByEntitledHolder())
                    return
                }
                for desired in [true, false, false] {
                    var prepared = getterParams
                    prepared["bypassed"] = .bool(desired)
                    prepared["expected_current"] = .bool(f.routingBypassPresses == 1)
                    let setterParams = prepared
                    let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_send_bypass_verified",
                        commandParams: setterParams, mutationGate: gate) {
                        await FeatureFlags.withAdr002TargetRefForTests(true) { await set(dependencies, setterParams) }
                    }
                    let body = try #require(sharedJSONObject(sharedToolText(result)))
                    #expect(body["state"] as? String == "A", "Actual exact checkbox mutation: \(sharedToolText(result))")
                    let observed = try #require(body["bypassed"] as? Bool)
                    if desired { #expect(observed) } else { #expect(!observed) }
                }
                #expect(f.routingBypassPresses == 2 && f.routingDestinationPresses == 0)
                #expect(f.routingReplacement == nil && f.selections == initialSelections)
                #expect(AXLogicProElements.sendSlotObservations(in: f.strips[1], runtime: f.logic().ax) == beforeSlots)
                #expect(!gate.isHeldByEntitledHolder())
                return
            }
            if let modeCommand {
                let effectObserver: (@Sendable (AccessibilityChannel.ChangedSendModeObservation) -> Void)?
                if let boundary = modeEffectBoundary {
                    effectObserver = { proof in
                        boundary.observed.append(proof)
                        boundary.permittedAtCapture.append(proof.permits(runtime: proof.current.track.runtime))
                        switch boundary.fault {
                        case "foreign_document":
                            b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            boundary.faultReached = true
                        case "changed_control":
                            if let parent: AXUIElement = AXHelpers.getAttribute(proof.control.group,
                                kAXParentAttribute as String, runtime: b.makeAXRuntime()),
                               let role = AXHelpers.getRole(proof.control.group, runtime: b.makeAXRuntime()) {
                                let replacement = b.element(1_965_2698)
                                b.setRole(replacement, role)
                                b.setChildren(replacement, b.makeAXRuntime().children(proof.control.group))
                                b.setChildren(parent, b.makeAXRuntime().children(parent).map {
                                    CFEqual($0, proof.control.group) ? replacement : $0
                                })
                                boundary.faultReached = true
                            }
                        case "changed_peer":
                            b.setChildren(f.strips[0], peerChildren + extraSend)
                            boundary.faultReached = true
                        case "boolean_raw":
                            if let level = proof.control.level {
                                b.setAttribute(level, kAXValueAttribute as String, false)
                                boundary.faultReached = true
                            }
                        default: break
                        }
                        if boundary.fault != nil {
                            boundary.permittedAfterFault.append(proof.permits(runtime: proof.current.track.runtime))
                        }
                    }
                } else { effectObserver = nil }
                let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "set_send_mode_verified"))
                let desiredMode = modeCommand == "noop" ? "post_fader"
                    : modeCommand == "post_pan_roundtrip" ? "post_pan" : "pre_fader"
                var prepared: [String: Value] = ["target_ref": .string(reference.rawValue), "ordinal": .int(1),
                    "mode": .string(desiredMode), "expected_current": .string("post_fader")]
                switch modeCommand {
                case "boolean_raw": b.setAttribute(b.element(1_965_2624), kAXValueAttribute as String, false)
                case "wrong_target": prepared["target_ref"] = .string(try #require(capture.mixerReference(at: 0)).rawValue)
                case "wrong_project": prepared["project_ref"] = .string("prj_foreign")
                case "unsupported_mode": prepared["mode"] = .string("post_pan_extra")
                case "boolean_mode": prepared["mode"] = .bool(true)
                case "extra_param": prepared["value"] = .double(0.5)
                case "missing": b.setChildren(root, [echo, independentPan, mode, preFader, parent])
                case "duplicate":
                    b.setRole(competitor, kAXMenuItemRole as String); b.setAttribute(competitor, kAXTitleAttribute as String, "Pre Fader")
                    b.setChildren(competitor, []); b.setChildren(root, [echo, independentPan, postPan, mode, preFader, competitor, parent])
                case "no_checked_mode": b.setAttribute(mode, "AXMenuItemMarkChar", "")
                case "two_checked_modes": b.setAttribute(preFader, "AXMenuItemMarkChar", "✓")
                default: break
                }
                if modeCommand == "unread_mark" {
                    let prior = f.routingReadResult
                    f.routingReadResult = { element, attribute in
                        if CFEqual(element, postPan), attribute == "AXMenuItemMarkChar" {
                            f.routingLateScopeInjected = true; return .failure(.init(raw: AXError.cannotComplete.rawValue))
                        }
                        return prior?(element, attribute)
                    }
                }
                f.routingActionNames = { element in
                    guard CFEqual(element, preFader), !f.routingLateScopeInjected else { return nil }
                    switch modeCommand {
                    case "late_document": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    case "late_level": b.setAttribute(b.element(1_965_2624), kAXValueAttribute as String, 99)
                    case "late_bypass": b.setAttribute(b.element(1_965_2622), kAXValueAttribute as String, 1)
                    case "late_play": b.setAttribute(b.element(1_965_721), kAXValueAttribute as String, 1)
                    case "late_mode": b.setAttribute(mode, "AXMenuItemMarkChar", ""); b.setAttribute(preFader, "AXMenuItemMarkChar", "✓")
                    case "late_peer": b.setChildren(f.strips[0], peerChildren + extraSend)
                    default: return nil
                    }
                    f.routingLateScopeInjected = true; return nil
                }
                let params = prepared
                if let modeSaga {
                    let journal = SagaJournal(maxRecords: 1), key = "owned-send-mode-saga"
                    await router.register(SendRemovalSagaResultBoundary(base: f.channel(), journal: journal,
                        mode: modeSaga, operation: "mixer.set_send_mode_verified", idempotencyKey: key,
                        afterForward: {
                            switch modeSaga {
                            case "late_inverse_mode":
                                b.setAttribute(mode, "AXMenuItemMarkChar", "✓")
                                b.setAttribute(preFader, "AXMenuItemMarkChar", "")
                                b.setAttribute(postPan, "AXMenuItemMarkChar", "")
                            case "late_inverse_level": b.setAttribute(b.element(1_965_2624), kAXValueAttribute as String, 99)
                            case "late_inverse_document": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            default: return
                            }
                            f.routingLateScopeInjected = true
                        }))
                    let sagaDependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                        poller: StatePoller(axChannel: f.channel(), cache: cache,
                            runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing })),
                        dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal,
                        mutationGate: gate, liveTrackNames: { [:] })
                    var stepParams = params
                    stepParams.removeValue(forKey: "target_ref")
                    if case .issued(let project)? = capture.projectIssuance { stepParams["project_ref"] = .string(project.rawValue) }
                    if modeSaga == "wrong_project" { stepParams["project_ref"] = .string("prj_foreign") }
                    if modeSaga == "wrong_slot" { stepParams["ordinal"] = .int(0) }
                    let modeTarget = modeSaga == "wrong_target" ? try #require(capture.mixerReference(at: 0)) : reference
                    var wire: [String: Value] = ["idempotency_key": .string(key), "steps": .array([.object([
                        "operation_id": .string(OperationID.mixerSetSendModeVerified.rawValue),
                        "target_ref": .string(modeTarget.rawValue), "params": .object(stepParams),
                        "expected_inverse": .object(["operation_id": .string(OperationID.mixerSetSendModeVerified.rawValue),
                            "value_parameter": .string("mode")])])])]
                    wire["confirmed_plan_hash"] = .string(SagaJournal.planHash(try SagaWire.plan(from: wire)))
                    if modeSaga == "wrong_hash" { wire["confirmed_plan_hash"] = .string(String(repeating: "0", count: 64)) }
                    let preflight = try #require(OperationHandlerRegistry.handler(tool: "logic_system", command: "saga_preflight"))
                    let preview = await FeatureFlags.withAdr004MutationSagaForTests(true) { await preflight(sagaDependencies, wire) }
                    let previewBody = try #require(sharedJSONObject(sharedToolText(preview)))
                    let ready = try #require(previewBody["ok"] as? Bool,
                        "Actual registered mode preflight response: \(sharedToolText(preview))")
                    if ["wrong_project", "wrong_target", "wrong_slot"].contains(modeSaga) {
                        #expect(!ready)
                        #expect(f.routingModePresses == 0 && f.routingDestinationPresses == 0)
                        return
                    }
                    #expect(ready, "Actual registered mode preflight: \(sharedToolText(preview))")
                    #expect(f.routingModePresses == 0 && f.routingDestinationPresses == 0)
                    if modeSaga == "preflight" { return }
                    let execute = try #require(OperationHandlerRegistry.handler(tool: "logic_system", command: "saga_execute"))
                    let result = await FeatureFlags.withAdr004MutationSagaForTests(true) { await execute(sagaDependencies, wire) }
                    let body = try #require(sharedJSONObject(sharedToolText(result)))
                    if modeSaga == "wrong_hash" {
                        #expect(body["state"] as? String == "C")
                        let wrote = try #require(body["write_attempted"] as? Bool); #expect(!wrote)
                        #expect(f.routingModePresses == 0 && f.routingDestinationPresses == 0)
                        return
                    }
                    if ["no_observer", "lost_observer"].contains(modeSaga) || modeSaga.hasPrefix("late_inverse_") {
                        let terminal = try #require(body["saga_state"] as? String)
                        #expect(terminal != "completed" && terminal != "fullyCompensated", "\(sharedToolText(result))")
                        #expect(body["state"] as? String == "B", "\(sharedToolText(result))")
                        #expect(f.routingModePresses == (modeSaga == "no_observer" ? 0 : 1))
                        #expect(f.routingDestinationPresses == 0 && !gate.isHeldByEntitledHolder())
                        if modeSaga.hasPrefix("late_inverse_") { #expect(f.routingLateScopeInjected) }
                        if modeSaga == "late_inverse_mode" {
                            #expect(b.attributeValue(mode, "AXMenuItemMarkChar") as? String == "✓")
                            #expect(b.attributeValue(preFader, "AXMenuItemMarkChar") as? String == "")
                            #expect(b.attributeValue(postPan, "AXMenuItemMarkChar") as? String == "")
                        }
                        let count = f.routingModePresses
                        let replay = await FeatureFlags.withAdr004MutationSagaForTests(true) { await execute(sagaDependencies, wire) }
                        let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
                        let duplicate = try #require(replayBody["duplicate"] as? Bool); #expect(duplicate)
                        #expect(replayBody["state"] as? String == "B")
                        #expect(f.routingModePresses == count, "An uncertain same-key replay must not repeat a mode leaf")
                        return
                    }
                    #expect(body["saga_state"] as? String == "fullyCompensated", "\(sharedToolText(result))")
                    #expect(f.routingModePresses == 2 && f.routingDestinationPresses == 0)
                    #expect(b.attributeValue(mode, "AXMenuItemMarkChar") as? String == "✓")
                    #expect(b.attributeValue(preFader, "AXMenuItemMarkChar") as? String == "")
                    #expect(b.attributeValue(postPan, "AXMenuItemMarkChar") as? String == "")
                    #expect(!gate.isHeldByEntitledHolder())
                    let count = f.routingModePresses
                    let replay = await FeatureFlags.withAdr004MutationSagaForTests(true) { await execute(sagaDependencies, wire) }
                    let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
                    if modeSaga == "cancel" {
                        #expect(replayBody["error"] as? String == HonestContract.FailureError.unsupportedState.rawValue)
                    } else {
                        let duplicate = try #require(replayBody["duplicate"] as? Bool)
                        #expect(duplicate)
                    }
                    #expect(f.routingModePresses == count)
                    return
                }
                let beforeModeSelections = f.selections.count
                let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_send_mode_verified",
                    commandParams: params, mutationGate: gate) {
                    await AccessibilityChannel.$sendModeChangeObserver.withValue(effectObserver) { await handler(dependencies, params) }
                }
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                if let boundary = modePeerBoundary {
                    boundary.state = body["state"] as? String ?? "missing"
                    boundary.leafCount = f.routingModePresses
                    boundary.receipt = sharedToolText(result)
                    return
                }
                if modeCommand.hasPrefix("after_") {
                    #expect(body["state"] as? String == "B", "\(sharedToolText(result))")
                    #expect(f.routingModePresses == 1 && f.routingDestinationPresses == 0)
                    return
                }
                if !["roundtrip", "post_pan_roundtrip", "noop", "independent_pan"].contains(modeCommand) {
                    #expect(body["state"] as? String == "C", "\(sharedToolText(result))")
                    #expect(f.routingModePresses == 0 && f.routingDestinationPresses == 0)
                    if modeCommand.hasPrefix("late_") || modeCommand == "unread_mark" { #expect(f.routingLateScopeInjected) }
                    return
                }
                #expect(body["state"] as? String == "A", "\(sharedToolText(result))")
                guard body["state"] as? String == "A" else { return }
                if modeCommand == "noop" { #expect(f.routingModePresses == 0); return }
                if survivingSource {
                    assertSurvivingModeControlReadback(f, originalList: originalList,
                        body: body, selectionsBefore: beforeModeSelections)
                }
                #expect(body["after"] as? String == desiredMode)
                if modeCommand == "post_pan_roundtrip" {
                    #expect(b.attributeValue(postPan, "AXMenuItemMarkChar") as? String == "✓")
                    #expect(b.attributeValue(mode, "AXMenuItemMarkChar") as? String == "")
                    #expect(b.attributeValue(independentPan, "AXMenuItemMarkChar") as? String == "")
                }
                let inverse = params.merging(["mode": Value.string("post_fader"), "expected_current": .string(desiredMode)]) { _, new in new }
                let restored = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_send_mode_verified",
                    commandParams: inverse, mutationGate: gate) {
                    await AccessibilityChannel.$sendModeChangeObserver.withValue(effectObserver) { await handler(dependencies, inverse) }
                }
                #expect(sharedJSONObject(sharedToolText(restored))?["state"] as? String == "A", "\(sharedToolText(restored))")
                #expect(f.routingModePresses == 2 && f.routingDestinationPresses == 0)
                #expect(b.attributeValue(mode, "AXMenuItemMarkChar") as? String == "✓")
                if modeCommand == "post_pan_roundtrip" {
                    #expect(b.attributeValue(postPan, "AXMenuItemMarkChar") as? String == "")
                    #expect(b.attributeValue(independentPan, "AXMenuItemMarkChar") as? String == "")
                }
                return
            }
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "set_send_output_verified"))
            if freshEmpty != nil {
                var prepared: [String: Value] = ["target_ref": .string(reference.rawValue), "ordinal": .int(0),
                    "destination": .object(["kind": .string("stereo_output")]),
                    "expected_current": .object(["kind": .string("no_send")]), "replace_existing": .bool(false)]
                if freshEmpty == "wrong_target" { prepared["target_ref"] = .string(try #require(capture.mixerReference(at: 0)).rawValue) }
                if freshEmpty == "wrong_project" { prepared["project_ref"] = .string("prj_foreign") }
                if freshEmpty == "expired_pair" { f.expireRetainedCapture = true }
                if freshEmpty == "conflicting_route" { b.setAttribute(stereo, "AXMenuItemMarkChar", "✓") }
                if freshEmpty == "unread_mark" {
                    let prior = f.routingReadResult
                    f.routingReadResult = { element, attribute in
                        if CFEqual(element, stereo), attribute == "AXMenuItemMarkChar" {
                            f.routingLateScopeInjected = true
                            return .failure(.init(raw: AXError.cannotComplete.rawValue))
                        }
                        return prior?(element, attribute)
                    }
                }
                f.routingActionNames = { element in
                    let trigger = freshEmpty == "before_peer" ? originalSend[0] : stereo
                    if creationSaga == "late_inverse_leaf_mode", f.routingDestinationPresses == 1,
                       CFEqual(element, destination), !f.routingLateScopeInjected {
                        f.routingLateScopeInjected = true
                        b.setAttribute(mode, "AXMenuItemMarkChar", "")
                        b.setAttribute(preFader, "AXMenuItemMarkChar", "✓")
                    }
                    guard CFEqual(element, trigger), !f.routingLateScopeInjected else { return nil }
                    switch freshEmpty {
                    case "before_peer":
                        let peer = b.element(1_965_2790)
                        b.setRole(peer, kAXLayoutItemRole as String); b.setChildren(peer, peerChildren)
                        f.routingOtherReplacement = peer
                        b.setChildren(f.mixer, [peer, f.strips[1]])
                    case "late_empty": b.setChildren(f.strips[1], originalChildren + [extraSend[0]])
                    case "late_document": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    case "late_play": b.setAttribute(b.element(1_965_721), kAXValueAttribute as String, 1)
                    default: return nil
                    }
                    f.routingLateScopeInjected = true
                    return nil
                }
                let params = prepared
                let slots = try #require(AXLogicProElements.sendSlotObservations(in: f.strips[1], runtime: f.logic().ax))
                if freshEmpty != "multiple_empty" && freshEmpty != "occupied" { #expect(slots.count == 1 && slots[0].state == .observedEmpty) }
                #expect(f.routingRemovedSend == nil && f.routingDestinationPresses == 0)
                if let creationSaga {
                    try await assertFreshCreationSaga(creationSaga, fixture: f, cache: cache, registry: registry,
                        router: router, gate: gate, reference: reference, params: params)
                    return
                }
                let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_send_output_verified",
                    commandParams: params, mutationGate: gate) { await handler(dependencies, params) }
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                if !["observed", "peer_padding", "peer_occupied", "peer_padding_three", "after_source", "after_mode",
                     "calibrate_late_target", "late_target", "boolean_after"].contains(freshEmpty ?? "") {
                    #expect(body["state"] as? String == "C", "Actual refused fresh-empty source: \(sharedToolText(result))")
                    #expect(f.routingDestinationPresses == 0)
                    if ["unread_mark", "late_empty", "late_document", "late_play", "before_peer"].contains(freshEmpty ?? "") { #expect(f.routingLateScopeInjected) }
                    return
                }
                if ["peer_occupied", "peer_padding_three", "after_source", "after_mode", "late_target", "boolean_after"].contains(freshEmpty ?? "") {
                    #expect(body["state"] as? String == "B", "Actual unverified fresh-empty after-state: \(sharedToolText(result))")
                    #expect(f.routingDestinationPresses == 1)
                    if freshEmpty == "late_target" { #expect(f.routingLateScopeInjected) }
                    return
                }
                if freshEmpty == "calibrate_late_target" {
                    #expect(f.routingBypassFinalValueReads > 0)
                    recordFreshFinalPeerRead?(f.routingBypassFinalValueReads)
                }
                #expect(body["state"] as? String == "A", "Actual registered fresh-empty creation: \(sharedToolText(result))")
                #expect(f.routingDestinationPresses == 1)
                #expect(f.routingRemovedSend == nil, "Fresh creation never forges a removed-send capsule")
                return
            }
            var preparedParams: [String: Value] = ["target_ref": .string(reference.rawValue), "ordinal": .int(1),
                "destination": removing ? .object(["kind": .string("no_send")])
                    : existingBus ? .object(["kind": .string("bus"), "number": .int(1)])
                    : .object(["kind": .string("physical"), "ports": .array([.int(3), .int(4)])]),
                "expected_current": .object(["kind": .string("stereo_output")]), "replace_existing": .bool(true)]
            if freshPhysicalReturn {
                preparedParams["destination"] = .object(["kind": .string("stereo_output")])
                preparedParams["expected_current"] = .object(["kind": .string("physical"), "ports": .array([.int(3), .int(4)])])
            }
            if let noOpDestination {
                let value: Value = switch noOpDestination {
                case .bus(let number): .object(["kind": .string("bus"), "number": .int(number)])
                case .physical(let first, let second): .object(["kind": .string("physical"),
                    "ports": .array([.int(first), .int(second)])])
                case .stereoOutput: .object(["kind": .string("stereo_output")])
                default: .null
                }
                preparedParams["destination"] = value
                preparedParams["expected_current"] = value
            }
            let params = preparedParams
            if let sagaMode {
                let journal = SagaJournal(maxRecords: 1)
                if sagaMode == "raw_level" { b.setAttribute(b.element(1_965_2624), kAXValueAttribute as String, 1) }
                if sagaMode == "raw_bypass" { b.setAttribute(b.element(1_965_2622), kAXValueAttribute as String, 1) }
                if sagaMode == "nondefault_mode" { b.setAttribute(mode, kAXTitleAttribute as String, "Post Pan") }
                if sagaMode == "expired_pair" { f.expireRetainedCapture = true }
                await router.register(SendRemovalSagaResultBoundary(base: f.channel(), journal: journal, mode: sagaMode,
                    afterForward: {
                        if sagaMode == "external_empty" {
                            b.setChildren(replacement, [name, extraSend[0]]); f.routingLateScopeInjected = true
                        } else if sagaMode == "foreign_after" {
                            b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            f.routingLateScopeInjected = true
                        } else if existingBus || !removing {
                            switch sagaMode {
                            case "external_destination":
                                let changed = existingBus ? "Bus 2 → Existing" : "Output 5-6"
                                b.setAttribute(echo, kAXTitleAttribute as String, changed)
                                b.setAttribute(destination, kAXTitleAttribute as String, changed)
                            case "external_level": b.setAttribute(b.element(1_965_2644), kAXValueAttribute as String, 1)
                            case "external_mode": b.setAttribute(mode, kAXTitleAttribute as String, "Pre Fader")
                            case "replaced_control":
                                let decoy = b.element(1_965_2799)
                                b.setButton(decoy, description: "list", x: 0, y: 0, width: 1, height: 1)
                                b.setChildren(decoy, []); b.setActionNames(decoy, [kAXPressAction as String])
                                b.setChildren(b.element(1_965_2641), [b.element(1_965_2642), decoy])
                            case "unknown_after", "lost_observer": break
                            default: return
                            }
                            f.routingLateScopeInjected = true
                        }
                    }))
                let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                    poller: StatePoller(axChannel: f.channel(), cache: cache,
                        runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing })),
                    dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal,
                    mutationGate: gate, liveTrackNames: { [:] })
                var stepParams = params; stepParams.removeValue(forKey: "target_ref")
                if sagaMode != "refs_disabled", case .issued(let project)? = capture.projectIssuance {
                    stepParams["project_ref"] = .string(project.rawValue)
                }
                if sagaMode == "wrong_project" { stepParams["project_ref"] = .string("project_wrong_session") }
                if sagaMode == "extra_param" { stepParams["native_proof"] = .object([:]) }
                var wire: [String: Value] = ["idempotency_key": .string("owned-send-removal-saga"),
                    "steps": .array([.object(["operation_id": .string(OperationID.mixerSetSendOutputVerified.rawValue),
                        "target_ref": .string(reference.rawValue), "params": .object(stepParams),
                        "expected_inverse": .object(["operation_id": .string(OperationID.mixerSetSendOutputVerified.rawValue),
                            "value_parameter": .string("destination")])])])]
                if sagaMode == "wrong_target" {
                    let otherRow = try #require(capture.channelStrips.indices.first {
                        capture.channelStrips[$0].physicalBinding.map { CFEqual($0.strip, f.strips[0]) } == true
                    })
                    let otherReference = try #require(capture.mixerReference(at: otherRow))
                    var wrongStep = try #require(wire["steps"]?.arrayValue?.first?.objectValue)
                    wrongStep["target_ref"] = .string(otherReference.rawValue)
                    wire["steps"] = .array([.object(wrongStep)])
                }
                if sagaMode == "invalid_later" {
                    wire["steps"] = .array((wire["steps"]?.arrayValue ?? []) + [.object([
                        "operation_id": .string(OperationID.tracksMute.rawValue), "target_ref": .string(reference.rawValue),
                        "params": .object(["enabled": .string("invalid")]),
                        "expected_inverse": .object(["operation_id": .string(OperationID.tracksMute.rawValue),
                            "value_parameter": .string("enabled")])])])
                }
                if sagaMode == "multiple", let steps = wire["steps"]?.arrayValue { wire["steps"] = .array(steps + steps) }
                if sagaMode != "missing_confirmation" {
                    wire["confirmed_plan_hash"] = .string(sagaMode == "wrong_confirmation" ? "wrong_hash"
                        : (try? SagaWire.plan(from: wire)).map(SagaJournal.planHash) ?? "invalid_hash")
                }
                if sagaMode == "foreign_document" { b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx") }
                let preflight = ["preflight", "wrong_project", "foreign_document", "refs_disabled"].contains(sagaMode)
                let sagaHandler = try #require(OperationHandlerRegistry.handler(tool: "logic_system",
                    command: preflight ? "saga_preflight" : "saga_execute"))
                let result = await FeatureFlags.withAdr004MutationSagaForTests(true) {
                    await FeatureFlags.withAdr002TargetRefForTests(sagaMode != "refs_disabled") {
                        await sagaHandler(dependencies, wire)
                    }
                }
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                if preflight {
                    let ready = try #require(body["ok"] as? Bool)
                    if sagaMode == "preflight" { #expect(ready) }
                    else { #expect(!ready, "Actual preflight: \(sharedToolText(result))") }
                    #expect(f.routingDestinationPresses == 0 && !gate.isHeldByEntitledHolder())
                    return
                }
                if ["wrong_target", "missing_confirmation", "wrong_confirmation", "extra_param", "invalid_later", "multiple", "raw_level", "raw_bypass", "nondefault_mode", "expired_pair"].contains(sagaMode) {
                    #expect(body["state"] as? String == "C" && f.routingDestinationPresses == 0)
                    if ["missing_confirmation", "wrong_confirmation", "extra_param", "invalid_later", "multiple"].contains(sagaMode) {
                        #expect(await journal.record(for: "owned-send-removal-saga") == nil)
                    }
                    return
                }
                if ["external_empty", "foreign_after", "no_observer", "external_destination", "external_level",
                    "external_mode", "replaced_control", "unknown_after", "late_inverse_mode", "lost_observer"].contains(sagaMode) {
                    if sagaMode == "no_observer" { #expect(f.routingDestinationPresses == 0) }
                    else { #expect(f.routingLateScopeInjected && f.routingDestinationPresses == 1) }
                    if sagaMode == "late_inverse_mode" {
                        #expect(body["saga_state"] as? String == "compensationFailed", "Known protected-state conflict refuses the inverse before its leaf")
                    } else {
                        #expect(body["saga_state"] as? String == "rollbackUncertain", "Actual lost-custody receipt: \(sharedToolText(result))")
                    }
                    #expect(!gate.isHeldByEntitledHolder())
                    return
                }
                let completed = sagaMode == "completed"
                #expect(f.routingDestinationPresses == (completed ? 1 : 2), "Actual registered Send response: \(sharedToolText(result))")
                if completed {
                    #expect(body["state"] as? String == "A")
                    #expect(body["saga_state"] as? String == "completed")
                    let verified = try #require(body["verified"] as? Bool)
                    #expect(verified)
                } else {
                    let compensation = try #require(body["compensation"] as? [String: Any])
                    let fullyCompensated = try #require(compensation["fully_compensated"] as? Bool)
                    #expect(fullyCompensated)
                }
                if freshPhysicalReturn {
                    let steps = try #require(body["steps"] as? [[String: Any]])
                    let evidence = try #require(steps[0]["evidence"] as? [String: Any])
                    let beforeState = try #require(evidence["before_state"] as? [String: Any])
                    #expect(beforeState["observed"] as? String == "physical:3-4")
                    let verification = try #require(evidence["verification"] as? [String: Any])
                    let readback = try #require(verification["readback"] as? [String: Any])
                    #expect(readback["observed"] as? String == "stereo_output")
                    if !completed {
                        let compensation = try #require(steps[0]["compensation"] as? [String: Any])
                        let inverseReadback = try #require(compensation["readback"] as? [String: Any])
                        #expect(inverseReadback["observed"] as? String == "physical:3-4")
                    }
                }
                let slots = try #require(AXLogicProElements.sendSlotObservations(in: completed ? replacement : restoredSource,
                    runtime: f.logic().ax))
                #expect(slots.filter { $0.state == .occupiedUnknownDestination }.count == 1)
                #expect(!gate.isHeldByEntitledHolder())
                let beforeReplay = f.routingDestinationPresses
                let replay = await FeatureFlags.withAdr004MutationSagaForTests(true) { await sagaHandler(dependencies, wire) }
                let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
                if sagaMode == "cancel" {
                    #expect(replayBody["state"] as? String == "C")
                    #expect(replayBody["error"] as? String == HonestContract.FailureError.unsupportedState.rawValue)
                    #expect(replayBody["duplicate"] == nil)
                } else {
                    let duplicate = try #require(replayBody["duplicate"] as? Bool)
                    #expect(duplicate)
                }
                #expect(f.routingDestinationPresses == beforeReplay, "Existing journal replay never reissues removal or inverse")
                var conflicting = wire
                var conflictingStep = try #require(wire["steps"]?.arrayValue?.first?.objectValue)
                var conflictingParams = try #require(conflictingStep["params"]?.objectValue)
                conflictingParams["ordinal"] = .int(0); conflictingStep["params"] = .object(conflictingParams)
                conflicting["steps"] = .array([.object(conflictingStep)])
                conflicting.removeValue(forKey: "confirmed_plan_hash")
                conflicting["confirmed_plan_hash"] = .string(SagaJournal.planHash(try SagaWire.plan(from: conflicting)))
                let conflict = await FeatureFlags.withAdr004MutationSagaForTests(true) { await sagaHandler(dependencies, conflicting) }
                #expect(sharedJSONObject(sharedToolText(conflict))?["error"] as? String == HonestContract.FailureError.idempotencyKeyConflict.rawValue)
                _ = await journal.begin(.init(steps: [], idempotencyKey: "body-pressure"))
                let evicted = await FeatureFlags.withAdr004MutationSagaForTests(true) { await sagaHandler(dependencies, wire) }
                #expect(sharedJSONObject(sharedToolText(evicted))?["error"] as? String == HonestContract.FailureError.sagaOutcomeUnavailable.rawValue)
                #expect(f.routingDestinationPresses == beforeReplay)
                return
            }
            let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_send_output_verified",
                commandParams: params, mutationGate: gate) {
                await FeatureFlags.withAdr002TargetRefForTests(true) {
                    if restoring {
                        return await AXMixerStripBinding.$current.withValue(originalPair.strip) {
                            await AXMixerStripBinding.$outputAssociation.withValue(originalPair) {
                                let removed = await AccessibilityChannel.removeAssignedSendObservation(ordinal: 1,
                                    expected: .stereoOutput, runtime: f.logic(), timing: .immediate)
                                let proof = try? #require(removed.removedSend)
                                guard let proof else { return toolTextResult(removed.result) }
                                #expect(proof.permits(runtime: f.logic()))
                                guard let beforeBypassed = try? #require(proof.before.bypassed) else {
                                    return toolTextResult(removed.result)
                                }
                                #expect(proof.before.levelRaw == 0 && !beforeBypassed)
                                #expect(proof.checkedDestination == .stereoOutput
                                    && proof.nonRoutingChecks == [emptyModeMenu ? "Post Fader" : "Post Pan"])
                                if survivingSource {
                                    let originalRole: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                                        f.strips[1], kAXRoleAttribute as String, runtime: f.logic().ax)
                                    if case .success(let role) = originalRole { #expect(role == kAXLayoutItemRole as String) }
                                    else { Issue.record("The original physical source must survive before the explicit inverse") }
                                    let deleted: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                                        originalList, kAXRoleAttribute as String, runtime: f.logic().ax)
                                    if case .failure(let error) = deleted { #expect(error.raw == AXError.invalidUIElement.rawValue) }
                                    else { Issue.record("The original occupied send control must retire at removal") }
                                }
                                if let inverseFault, !inverseFault.hasPrefix("after_") {
                                    f.routingLateScopeInjected = true
                                    switch inverseFault {
                                    case "empty_replaced": b.setChildren(replacement, [name, extraSend[0]])
                                    case "another_occupied": b.setChildren(replacement, [name] + renewedSend)
                                    case "foreign_project": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                                    case "conflicting_echo": b.setAttribute(echo, "AXMenuItemMarkChar", "✓")
                                    case "unreadable_echo_mark": break
                                    case "empty_mode_mark_unreadable", "empty_mode_enabled_unreadable":
                                        f.routingLateScopeInjected = false
                                    case "empty_mode_still_enabled": b.setAttribute(mode, kAXEnabledAttribute as String, true)
                                    default: Issue.record("Unknown inverse fixture fault")
                                    }
                                }
                                let restored = await AccessibilityChannel.restoreRemovedSendObservation(proof,
                                    runtime: f.logic(), timing: .immediate)
                                if let readRestored {
                                    #expect(restored.assignment == .stereoOutput)
                                    #expect(restored.restoredSend != nil, "Successful restoration must retain its native renewed source and control")
                                    let expectedOriginal = readRestored == "wrong_original"
                                        ? AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
                                            strip: f.strips[0], document: proof.source.pair.strip.document)
                                        : proof.source.pair.strip
                                    f.routingIndependentSendReads = 0
                                    switch readRestored {
                                    case "changed_destination":
                                        b.setAttribute(echo, kAXTitleAttribute as String, "Output 3-4")
                                        b.setAttribute(stereo, kAXTitleAttribute as String, "Output 3-4")
                                    case "foreign_project": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                                    case "retired_source":
                                        f.routingLateScopeInjected = true
                                        b.setChildren(f.mixer, [f.strips[0], replacement])
                                    case "replaced_control": b.setChildren(restoredSource, [name] + renewedSend)
                                    case "wrong_original": break
                                    default: Issue.record("Unknown renewed send read fixture")
                                    }
                                    let reading = await AccessibilityChannel.readRestoredSendObservation(restored,
                                        original: expectedOriginal, runtime: f.logic(), timing: .immediate)
                                    let readBody = try? sharedJSONObject(reading.result.message)
                                    if readRestored == "changed_destination" {
                                        #expect(reading.assignment == OutputAssignment.physical(3, 4))
                                        #expect(readBody?["state"] as? String == "A")
                                        #expect(readBody?["output_checkmark_reads_observed"] as? Int == 2)
                                        #expect(f.routingIndependentSendReads > 0)
                                    } else {
                                        #expect(reading.assignment == nil && readBody?["state"] as? String == "C")
                                        #expect(f.routingIndependentSendReads == 0)
                                    }
                                    #expect(f.routingDestinationPresses == 2, "The independent reader never selects a routing destination")
                                }
                                return toolTextResult(restored.result)
                            }
                        }
                    }
                    if observeRemoval {
                        return await AccessibilityChannel.$sendRemovalObserver.withValue({ proof in
                            f.routingRemovalPublications += 1
                            f.routingRemovedSend = proof
                            f.routingRemovalPermittedAtPublication = proof.permits(runtime: f.logic())
                        }) { await handler(dependencies, params) }
                    }
                    return await handler(dependencies, params)
                }
            }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            if noOpDestination != nil {
                #expect(body["state"] as? String == "A", "An observed no-op does not need retirement authority")
                let verified = try #require(body["verified"] as? Bool)
                #expect(verified)
                let attempted = try #require(body["write_attempted"] as? Bool)
                #expect(!attempted)
                #expect(f.routingDestinationPresses == 0 && f.routingReplacement == nil)
                #expect(f.selections == initialSelections)
                #expect(!gate.isHeldByEntitledHolder())
                return
            }
            if fault == "expired_pair" {
                #expect(body["state"] as? String == "C", "An expired restoration tether must refuse before the send mutation")
                let attempted = try #require(body["write_attempted"] as? Bool)
                #expect(!attempted)
                #expect(f.routingDestinationPresses == 0 && f.routingReplacement == nil)
                #expect(f.selections == initialSelections)
                #expect(!gate.isHeldByEntitledHolder())
                return
            }
            if lateRemovalChoice {
                #expect(f.routingLateScopeInjected, "The actual second removal selector must reach the unknown read after strict checked/menu reads")
                #expect(f.routingDestinationPresses == 0)
                #expect(body["state"] as? String == "C", "Actual final selector response: \(sharedToolText(result))")
                let attempted = try #require(body["write_attempted"] as? Bool)
                #expect(!attempted && f.routingReplacement == nil)
                return
            }
            let inverseReached = restoring && (inverseFault == nil || inverseFault?.hasPrefix("after_") == true)
            #expect(f.routingDestinationPresses == (inverseReached ? 2 : 1), "Actual removal and explicit inverse leaves must be reached")
            let originalRole: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                f.strips[1], kAXRoleAttribute as String, runtime: f.logic().ax)
            if survivingSource && !inverseReached {
                if case .success(let role) = originalRole { #expect(role == kAXLayoutItemRole as String) }
                else { Issue.record("The original physical source must actually survive this observed No Send shape") }
                let deleted: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(originalList,
                    kAXRoleAttribute as String, runtime: f.logic().ax)
                if case .failure(let error) = deleted { #expect(error.raw == AXError.invalidUIElement.rawValue) }
                else { Issue.record("The original occupied send control must actually retire, not mutate in place") }
            } else {
                if case .failure(let error) = originalRole { #expect(error.raw == AXError.invalidUIElement.rawValue) }
                else { Issue.record("The original source must actually be retired") }
            }
            if restoring {
                if emptyModeMenu { #expect(f.routingClassifierHelpReads > 0, "The actual empty-menu absent mode check must be read") }
                if let inverseFault {
                    #expect(f.routingLateScopeInjected, "The calibrated native state boundary must be reached")
                    #expect(body["state"] as? String == (inverseReached ? "B" : "C"), "Actual inverse refusal: \(sharedToolText(result))")
                    let attempted = try #require(body["write_attempted"] as? Bool)
                    #expect(attempted == inverseReached)
                    #expect(body["after"] == nil)
                    if inverseReached {
                        let verified = try #require(body["verified"] as? Bool)
                        #expect(!verified)
                    }
                    #expect(f.routingDestinationPresses == (inverseReached ? 2 : 1), "No blind retry/compensation after lost ownership")
                    return
                }
                #expect(body["state"] as? String == "A", "Actual inverse response: \(sharedToolText(result))")
                #expect(body["before"] as? [String: String] == ["state": "observed_empty"])
                let verified = try #require(body["verified"] as? Bool)
                #expect(verified)
                let slots = try #require(AXLogicProElements.sendSlotObservations(in: restoredSource, runtime: f.logic().ax))
                #expect(slots.count == 2)
                let restoredBypassed = try #require(slots[1].bypassed)
                #expect(slots[1].levelRaw == 0 && !restoredBypassed)
                #expect(Array(f.selections.dropFirst(initialSelections.count)) == [1, 0, 1, 0])
                return
            }
            if let fault {
                if observeRemoval { #expect(f.routingRemovalPublications == 0 && f.routingRemovedSend == nil) }
                #expect(body["state"] as? String == "B", "Actual uncertain retired-send response: \(sharedToolText(result))")
                let verified = try #require(body["verified"] as? Bool)
                #expect(!verified)
                #expect(body["after"] == nil)
                #expect(f.routingDestinationPresses == 1, "No guessed retry or inverse after a lost correspondence")
                if fault.hasPrefix("deciding_") { #expect(f.routingLateScopeInjected, "The actual deciding control read must reach the fault") }
                #expect(!gate.isHeldByEntitledHolder())
                return
            }
            #expect(body["state"] as? String == "A", "Actual retired-send response: \(sharedToolText(result))")
            if observeRemoval {
                #expect(f.routingRemovalPublications == 1)
                let observed = try #require(f.routingRemovedSend)
                let permittedAtPublication = try #require(f.routingRemovalPermittedAtPublication)
                #expect(permittedAtPublication)
                #expect(!observed.permits(runtime: f.logic()), "Native authority expires with the request's actual operation claim")
                let beforeBypassed = try #require(observed.before.bypassed)
                #expect(observed.checkedDestination == .stereoOutput && observed.before.levelRaw == 0 && !beforeBypassed)
            }
            #expect(body["before"] as? [String: String] == ["kind": "stereo_output"])
            let verified = try #require(body["verified"] as? Bool)
            #expect(verified)
            let reread = try #require(body["reference_reread_required"] as? Bool)
            #expect(reread)
            #expect(Array(f.selections.dropFirst(initialSelections.count)) == [1, 0])
            #expect(body["after"] as? [String: Any] != nil)
            if removing {
                let after = try #require(body["after"] as? [String: Any])
                #expect(after["state"] as? String == "observed_empty")
                let slots = try #require(AXLogicProElements.sendSlotObservations(in: survivingSource ? f.strips[1] : replacement,
                    runtime: f.logic().ax))
                #expect(slots.count == 1 && slots.allSatisfy { $0.state == .observedEmpty })
            }
            #expect(!gate.isHeldByEntitledHolder())
        }
    }

    private func assertInputBusRenewal(number: Int, condition: String, graph: Bool = false, keep: Bool = false,
                                      readOutputAfterRenewal: Bool = false) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture(), registry = TargetRegistry()
            let captureNow = ContinuousClock.now
            let cache = StateCache(sessionCaptureNow: {
                f.expireRetainedCapture ? captureNow.advanced(by: StateCache.sessionCaptureLifetime) : captureNow
            })
            let input = f.builder.element(1_965_960), replacement = f.builder.element(1_965_961)
            let newInput = f.builder.element(1_965_962), root = f.builder.element(1_965_963)
            let echo = f.builder.element(1_965_964), bus = f.builder.element(1_965_965)
            let submenu = f.builder.element(1_965_966), leaf = f.builder.element(1_965_967)
            let decoy = f.builder.element(1_965_968)
            let mixerOwner = f.builder.element(1_965_971)
            let unpairedStrip = f.builder.element(1_965_973), unpairedInput = f.builder.element(1_965_974)
            let unpairedRows = condition == "unpaired_bus" ? [unpairedStrip] : []
            let otherReplacement = f.builder.element(1_965_975)
            let retiresWholeCensus = condition.hasPrefix("whole_census_")
            f.builder.setRole(f.mixer, kAXLayoutAreaRole as String)
            f.builder.setAttribute(f.mixer, kAXDescriptionAttribute as String, "Mixer")
            f.builder.setRole(mixerOwner, kAXGroupRole as String)
            f.builder.setAttribute(mixerOwner, kAXDescriptionAttribute as String, "Mixer")
            f.builder.setChildren(mixerOwner, [f.mixer])
            f.builder.setChildren(f.window, [f.rail, mixerOwner, f.builder.element(1_965_720)])
            for button in [input, newInput, decoy] {
                f.builder.setButton(button, description: "Bus 256", help: "Input slot. Choose the channel strip input source.",
                    x: 0, y: 0, width: 1, height: 1)
                f.builder.setChildren(button, [])
                f.builder.setActionNames(button, [kAXPressAction as String])
            }
            // This Bus-renewal fixture deliberately supplies no owned physical-input
            // menu for the sibling. Keep it unknown, rather than advertising the
            // physical-input capability exercised by the separate input-domain suite.
            if graph { f.builder.setAttribute(decoy, kAXDescriptionAttribute as String, "Input unavailable") }
            if !unpairedRows.isEmpty {
                f.builder.setRole(unpairedStrip, kAXLayoutItemRole as String)
                f.builder.setButton(unpairedInput, description: "Bus 1", help: "Input slot. Choose the channel strip input source.",
                    x: 0, y: 0, width: 1, height: 1)
                f.builder.setActionNames(unpairedInput, [kAXPressAction as String])
                f.builder.setChildren(unpairedInput, [])
                f.builder.setChildren(unpairedStrip, [unpairedInput])
                f.builder.setChildren(f.mixer, f.strips + unpairedRows)
            }
            f.builder.setChildren(f.strips[1], f.builder.makeAXRuntime().children(f.strips[1]) + [input])
            f.builder.setChildren(f.strips[0], f.builder.makeAXRuntime().children(f.strips[0]) + [decoy])
            if retiresWholeCensus {
                f.builder.setRole(otherReplacement, kAXLayoutItemRole as String)
                f.builder.setAttribute(otherReplacement, kAXNumberOfCharactersAttribute as String, 0)
                f.builder.setAttribute(otherReplacement, kAXInsertionPointLineNumberAttribute as String, 0)
                f.builder.setChildren(otherReplacement, f.builder.makeAXRuntime().children(f.strips[0]))
            }
            f.builder.setRole(replacement, kAXLayoutItemRole as String)
            f.builder.setAttribute(replacement, kAXNumberOfCharactersAttribute as String, 0)
            f.builder.setAttribute(replacement, kAXInsertionPointLineNumberAttribute as String, 0)
            f.builder.setChildren(replacement, graph
                ? f.builder.makeAXRuntime().children(f.strips[1]).filter { !CFEqual($0, input) } + [newInput]
                : [newInput])
            if keep {
                for (strip, id) in [(f.strips[1], 1_967_801), (replacement, 1_967_802)] {
                    let label = f.builder.element(id)
                    f.builder.setRole(label, kAXStaticTextRole as String)
                    f.builder.setAttribute(label, kAXDescriptionAttribute as String, "label")
                    f.builder.setAttribute(label, kAXValueAttribute as String, "Aux 7")
                    f.builder.setChildren(label, [])
                    f.builder.setChildren(strip, f.builder.makeAXRuntime().children(strip) + [label])
                }
            }
            for menu in [root, submenu] { f.builder.setRole(menu, kAXMenuRole as String) }
            f.builder.setActionNames(root, [kAXCancelAction as String])
            for (item, title) in [(echo, "Bus \(number) ← Audio 2"), (bus, "Bus"), (leaf, "Bus \(number) ← Audio 2")] {
                f.builder.setRole(item, kAXMenuItemRole as String)
                f.builder.setAttribute(item, kAXTitleAttribute as String, title)
                f.builder.setChildren(item, [])
            }
            for item in [echo, leaf] { f.builder.setAttribute(item, "AXMenuItemMarkChar", "✓") }
            f.builder.setChildren(submenu, [leaf]); f.builder.setChildren(bus, [submenu])
            f.builder.setChildren(root, [echo, bus])
            f.routingAction = { element, action in
                if CFEqual(element, input), action == kAXPressAction as String {
                    f.inputMenuPresses += 1
                    if let context = OperationTraceContext.current {
                        f.inputMenuHadOwnedClaim = context.mutationGateAcquired && context.ownsGate()
                    }
                    f.builder.setChildren(f.mixer, f.strips + unpairedRows + [root])
                    return true
                }
                if CFEqual(element, root), action == kAXCancelAction as String {
                    f.inputMenuCancels += 1
                    if keep, f.inputMenuCancels == 1 {
                        // Capture keeps its original owner; the independent apply read
                        // below performs the real replacement and must renew its own proof.
                        f.builder.setChildren(f.mixer, f.strips)
                        return true
                    }
                    f.routingReplacement = replacement
                    if keep, condition == "renewed_label_changed" {
                        f.routingLateScopeInjected = true
                        f.builder.setAttribute(f.builder.element(1_967_802), kAXValueAttribute as String, "Aux 9")
                    }
                    if retiresWholeCensus { f.routingOtherReplacement = otherReplacement }
                    if condition == "retirement_census_lag" {
                        f.inputRetirementCensusLag = true
                        f.inputRetiredSourceReadable = true
                    }
                    f.builder.setChildren(f.mixer, [f.routingOtherReplacement ?? f.strips[0], replacement] + unpairedRows + (condition == "popup_still_open" ? [root] : []))
                    f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                        condition == "unselected_pair" ? f.strips[0] : replacement)
                    if graph, condition == "unselected_pair" {
                        f.builder.setAttribute(f.headers[0], kAXSelectedAttribute as String, false)
                        f.builder.setAttribute(f.headers[1], kAXSelectedAttribute as String, true)
                    }
                    if condition == "replaced_header" {
                        let foreign = f.builder.element(1_965_969)
                        f.builder.setRole(foreign, kAXLayoutItemRole as String)
                        f.builder.setAttribute(foreign, kAXTitleAttribute as String, "Duplicate")
                        f.builder.setAttribute(foreign, kAXSelectedAttribute as String, true)
                        f.builder.setChildren(foreign, [])
                        f.builder.setChildren(f.rail, [foreign, f.headers[1]])
                    } else if condition == "foreign_project" {
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    } else if condition == "foreign_focus" {
                        let foreign = f.builder.element(1_965_970)
                        f.builder.setRole(foreign, kAXTextFieldRole as String)
                        f.builder.setAttributeSettable(foreign, kAXValueAttribute as String, true)
                        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, foreign)
                    }
                    return condition != "popup_still_open"
                }
                if CFEqual(element, decoy) { f.routingWrongSourcePressed = true }
                if CFEqual(element, leaf) { f.routingDestinationPresses += 1 }
                Issue.record("The input reader must not press any destination, decoy, or replacement popup")
                return false
            }
            if readOutputAfterRenewal {
                f.installLaterOutputProbe(original: f.strips[1], renewed: replacement)
            }
            if condition == "two_input_retirements" {
                let otherInput = decoy, renewedOtherInput = f.builder.element(1_965_976)
                let finalOther = f.builder.element(1_965_977), finalOtherInput = f.builder.element(1_965_978)
                for control in [otherInput, renewedOtherInput, finalOtherInput] {
                    f.builder.setButton(control, description: "Bus 256", help: "Input slot. Choose the channel strip input source.",
                        x: 0, y: 0, width: 1, height: 1)
                    f.builder.setChildren(control, []); f.builder.setActionNames(control, [kAXPressAction as String])
                }
                for strip in [otherReplacement, finalOther] {
                    f.builder.setRole(strip, kAXLayoutItemRole as String)
                    f.builder.setAttribute(strip, kAXNumberOfCharactersAttribute as String, 0)
                    f.builder.setAttribute(strip, kAXInsertionPointLineNumberAttribute as String, 0)
                }
                f.routingAction = { element, action in
                    if action == kAXPressAction as String, CFEqual(element, otherInput) || CFEqual(element, input) {
                        f.inputMenuPresses += 1
                        f.builder.setChildren(f.mixer, [f.routingOtherReplacement ?? f.strips[0], f.routingReplacement ?? f.strips[1], root])
                        return true
                    }
                    if CFEqual(element, root), action == kAXCancelAction as String {
                        f.inputMenuCancels += 1
                        if f.inputMenuCancels == 1 {
                            f.builder.setChildren(otherReplacement,
                                f.builder.makeAXRuntime().children(f.strips[0]).filter { !CFEqual($0, otherInput) } + [renewedOtherInput])
                            f.routingOtherReplacement = otherReplacement
                        } else {
                            f.builder.setChildren(finalOther,
                                f.builder.makeAXRuntime().children(otherReplacement).filter { !CFEqual($0, renewedOtherInput) } + [finalOtherInput])
                            f.routingOtherReplacement = finalOther
                            f.routingReplacement = replacement
                        }
                        f.builder.setChildren(f.mixer, [f.routingOtherReplacement ?? f.strips[0], f.routingReplacement ?? f.strips[1]])
                        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.routingReplacement ?? f.strips[1])
                        return true
                    }
                    Issue.record("Only the two exact receiver input menus and their Cancel actions are permitted")
                    return false
                }
            }
            if condition == "partial_restore" {
                f.routingSelection = { _ in
                    if f.selections.count == (graph ? 5 : 3) {
                        f.routingLateScopeInjected = true
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                }
            }
            f.routingRead = { element, attribute in
                if keep, !f.routingLateScopeInjected, f.routingReplacement != nil,
                   CFEqual(element, f.builder.element(1_967_802)), attribute == kAXValueAttribute as String,
                   condition == "deciding_read" || condition == "deciding_control_replaced" {
                    f.routingLateScopeInjected = true
                    if condition == "deciding_read" {
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    } else {
                        let changedInput = f.builder.element(1_965_972)
                        f.builder.setButton(changedInput, description: "Bus 256",
                            help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 1, height: 1)
                        f.builder.setChildren(changedInput, [])
                        f.builder.setChildren(replacement, f.builder.makeAXRuntime().children(replacement).map {
                            CFEqual($0, newInput) ? changedInput : $0
                        })
                    }
                }
                if condition == "selected_child", f.routingReplacement != nil,
                   CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String {
                    let selectedOther = AXValueExtractors.extractSelectedState(f.headers[1], runtime: f.builder.makeAXRuntime()) == true
                    f.builder.setAttribute(f.mixer, attribute, [selectedOther ? f.strips[0] : replacement])
                }
                let inputDescription = !keep && f.selections.count == (graph ? 6 : 4) && CFEqual(element, newInput)
                    && attribute == kAXDescriptionAttribute as String
                let decidingDescription = inputDescription && f.inputPreviousReadWasDescription
                f.inputPreviousReadWasDescription = inputDescription
                if inputDescription {
                    if decidingDescription, condition == "whole_census_late_reorder" {
                        f.routingLateScopeInjected = true
                        f.builder.setChildren(f.mixer, [replacement, otherReplacement])
                    }
                    if decidingDescription, condition == "deciding_read" || condition == "deciding_control_replaced" {
                        f.routingLateScopeInjected = true
                        if condition == "deciding_control_replaced" {
                            let changedInput = f.builder.element(1_965_972)
                            f.builder.setButton(changedInput, description: "Bus 256",
                                help: "Input slot. Choose the channel strip input source.",
                                x: 0, y: 0, width: 1, height: 1)
                            f.builder.setChildren(changedInput, [])
                            f.builder.setChildren(replacement, [changedInput])
                        } else {
                            f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        }
                    }
                }
            }
            let before = try await inspect(f, cache: cache, registry: registry)
            let id = try #require(before["snapshot_id"] as? String)
            let capture = try #require(await cache.retainedInspection(id: id)).capture
            let row = try #require(capture.channelStrips.indices.first {
                capture.channelStrips[$0].physicalBinding.map { CFEqual($0.strip, f.strips[1]) } == true
            })
            let target = try #require(capture.mixerReference(at: row))
            let source = try #require(capture.channelStrips[row].physicalBinding)
            let pair = try #require(await cache.retainedMixerAssociation(reference: target,
                source: source, snapshot: await registry.currentSnapshot))
            #expect(CFEqual(pair.track.header, f.headers[0]) && CFEqual(pair.strip.strip, f.strips[1]),
                "Only the actual opposite-ordinal own-gesture pair may tether renewal")
            #expect(f.selections == [1, 0])
            if graph {
                let body = try await inspect(f, navigation: condition != "navigation_disabled", cache: cache,
                    registry: registry, domains: keep ? ["tracks", "strips", "associations", "routing"]
                        : condition == "missing_pair" ? ["routing"] : ["associations", "routing"],
                    guardedRenewalFocus: true)
                let retained = if let id = body["snapshot_id"] as? String {
                    await cache.retainedInspection(id: id)?.capture
                } else { nil as SessionPopulationObservation.Capture? }
                let routing = retained.map { SessionPopulationObservation.routingGraph(capture: $0) }
                let edges = routing?.edges.filter { $0.kind == .inputAssignment } ?? []
                if keep {
                    let snapshot = try #require(body["snapshot_id"] as? String)
                    let project = try #require((body["project"] as? [String: Any])?["project_ref"] as? String)
                    let fresh = try #require(retained)
                    let originalRow = try #require(fresh.channelStrips.indices.first {
                        fresh.channelStrips[$0].physicalBinding?.matches(source) == true
                    })
                    let approvedRef = try #require(fresh.mixerReference(at: originalRow))
                    #expect(edges.count == 1 && edges.first?.destination == approvedRef.rawValue)
                    let gate = LogicMutationGate(), router = ChannelRouter(), journal = SagaJournal()
                    let channel = f.channel(); await router.register(channel)
                    let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                        poller: StatePoller(axChannel: channel, cache: cache,
                            runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable,
                                keyboardFocus: { .notTextEditing })),
                        dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal,
                        mutationGate: gate, liveTrackNames: { [0: "Duplicate", 1: "Duplicate"] },
                        projectFileReader: .unavailable)
                    func call(_ command: String, _ params: [String: Value]) async throws -> [String: Any] {
                        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: command))
                        let execution = LogicProServer.sagaExecutionOwnsLifecycle(tool: "logic_project", command: command)
                        let lifecycle = execution ? ContinuousClock.now.advanced(by: .seconds(
                            LogicProServer.commandDeadlineSeconds(tool: "logic_project", command: command))) : nil
                        let scoped = lifecycle.map { dependencies.withSagaLifecycleDeadline($0) } ?? dependencies
                        let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: command,
                            commandParams: params,
                            outerAbsoluteDeadline: lifecycle.map { LogicProServer.sagaOuterAbsoluteDeadline(lifecycleDeadline: $0) },
                            mutationGate: execution ? nil : gate, externallyManagedMutation: execution) {
                            await FeatureFlags.withAdr002TargetRefForTests(true) {
                                await FeatureFlags.withAdr004MutationSagaForTests(true) { await handler(scoped, params) }
                            }
                        }
                        return try #require(sharedJSONObject(sharedToolText(result)))
                    }
                    let planned = try await call("plan_session_repair", ["snapshot_id": .string(snapshot),
                        "policy": .object(["schema": .string(ProjectSessionAudit.intentPolicySchema),
                            "project_ref": .string(project), "targets": .array([]),
                            "receivers": .array([.object(["bus": .int(number), "aux": .string("keep")])])])])
                    let executable = try #require(planned["executable"] as? Bool)
                    #expect(executable, "The actual initial own-control capture must support KEEP: \(planned)")
                    guard executable else { return }
                    let arguments: [String: Value] = ["plan_id": .string(try #require(planned["plan_id"] as? String)),
                        "digest": .string(try #require(planned["digest"] as? String)), "confirmed": .bool(true),
                        "idempotency_key": .string("keep-renewed-original-header")]
                    let result = try await call("apply_session_repair", arguments)
                    #expect(f.inputMenuPresses == 2 && f.inputMenuCancels == 2,
                        "Apply must independently reopen and cancel the actual input after capture")
                    #expect(source.currentIndex(runtime: f.builder.makeLogicRuntime(appElement: f.app)) == nil,
                        "The originally approved physical object really retired during apply")
                    if condition != "paired" {
                        #expect(result["state"] as? String == "C", "A lost original KEEP renewal must refuse: \(result)")
                        let wrote = try #require(result["write_attempted"] as? Bool); #expect(!wrote)
                        #expect(!f.routingWrongSourcePressed && f.routingDestinationPresses == 0 && f.scrollWrites.isEmpty)
                        if ["partial_restore", "deciding_read", "deciding_control_replaced", "renewed_label_changed"].contains(condition) {
                            #expect(f.routingLateScopeInjected, "Reach the actual late original-source boundary")
                        }
                        return
                    }
                    #expect(result["saga_state"] as? String == "completed", "Actual registered KEEP renewal: \(result)")
                    let verified = try #require(result["verified"] as? Bool); #expect(verified)
                    let wrote = try #require(result["write_attempted"] as? Bool); #expect(!wrote)
                    #expect(result["writes_performed"] as? Int == 0)
                    let evidence = try #require(result["goal_evidence"] as? [[String: Any]])
                    #expect(evidence.count == 1 && evidence.first?["target_ref"] as? String == approvedRef.rawValue)
                    let beforeReplay = f.inputMenuPresses
                    let replay = try await call("apply_session_repair", arguments)
                    let duplicate = try #require(replay["duplicate"] as? Bool); #expect(duplicate)
                    #expect(f.inputMenuPresses == beforeReplay)
                    #expect(!f.routingWrongSourcePressed && f.routingDestinationPresses == 0 && f.scrollWrites.isEmpty)
                    return
                }
                if condition == "two_input_retirements" {
                    #expect(f.inputMenuPresses == 2 && f.inputMenuCancels == 2,
                        "Both registered input acquisitions must actually replace physical owners")
                    let fresh = try #require(retained)
                    let receiver = try #require(fresh.channelStrips.indices.first {
                        $0 < fresh.channelStrips.count && fresh.channelStrips[$0].physicalBinding.map { CFEqual($0.strip, replacement) } == true
                    })
                    #expect(edges.count == 1 && edges.first?.source == "bus_\(number)",
                        "Retain the last fresh checked receiver, not an all-or-nothing loss after a second renewal")
                    #expect(edges.first?.destination == fresh.mixerReference(at: receiver)?.rawValue)
                    #expect(edges.first?.provenance == .axInputMenuCheckmark)
                    #expect(!fresh.channelStrips.contains {
                        $0.physicalBinding.map { CFEqual($0.strip, otherReplacement) } == true
                    }, "The first checked physical owner really retired again; do not transfer its checked bus to a replacement")
                    #expect(!f.routingWrongSourcePressed && f.routingDestinationPresses == 0 && f.scrollWrites.isEmpty)
                    let complete = try #require(routing?.complete)
                    #expect(!complete)
                    return
                }
                if condition == "navigation_disabled" {
                    #expect(edges.isEmpty && f.inputMenuPresses == 0 && f.inputMenuCancels == 0)
                    #expect(f.selections == [1, 0])
                    return
                }
                #expect(f.inputMenuPresses == 1 && f.inputMenuCancels == 1,
                    "Registered acquisition must execute Cancel's real physical retirement")
                #expect(source.currentIndex(runtime: f.builder.makeLogicRuntime(appElement: f.app)) == nil)
                if condition != "paired" && condition != "retirement_census_lag" && condition != "unpaired_bus" && condition != "whole_census_retirement" {
                    #expect(edges.isEmpty, "Lost original authority must not publish a bus input")
                    #expect(!f.routingWrongSourcePressed && f.routingDestinationPresses == 0 && f.scrollWrites.isEmpty)
                    if ["partial_restore", "deciding_read", "deciding_control_replaced", "whole_census_late_reorder"].contains(condition) {
                        #expect(f.routingLateScopeInjected, "The refusing late boundary must actually execute")
                    }
                    return
                }
                let fresh = try #require(retained)
                if condition == "retirement_census_lag" { #expect(f.inputRetirementCensusLagObserved) }
                let edge = try #require(edges.first,
                    "The checked input must survive only through the actual original-header renewal: selections=\(f.selections), report=\(body)")
                #expect(edges.count == 1 && edge.source == "bus_\(number)")
                #expect(edge.destination != target.rawValue, "Never rebind the retired reference")
                #expect(edge.provenance == .axInputMenuCheckmark)
                let receiverRow = try #require(fresh.channelStrips.indices.first {
                    fresh.channelStrips[$0].physicalBinding.map { CFEqual($0.strip, replacement) } == true
                })
                #expect(edge.destination == fresh.mixerReference(at: receiverRow)?.rawValue)
                if readOutputAfterRenewal {
                    #expect(f.renewedOutputPresses == 1 && f.renewedOutputCancels == 1)
                    let output = try #require(routing?.edges.first {
                        $0.kind == .mainOutput && $0.source == edge.destination
                    }, "Input renewal must not suppress the source's later checked output")
                    #expect(output.destination == "output_stereo" && output.provenance == .axOutputMenuCheckmark)
                }
                if retiresWholeCensus {
                    let currentPopulation = try #require(fresh.freshPopulation)
                    #expect(!currentPopulation.selectionAssociations.contains { CFEqual($0.strip.strip, f.strips[0]) },
                        "A retired unrelated association must be dropped, never retargeted")
                    let otherRow = try #require(fresh.channelStrips.indices.first {
                        fresh.channelStrips[$0].physicalBinding.map { CFEqual($0.strip, otherReplacement) } == true
                    })
                    let otherRef = try #require(fresh.mixerReference(at: otherRow))
                    #expect(await cache.retainedMixerAssociation(reference: otherRef,
                        source: try #require(fresh.channelStrips[otherRow].physicalBinding),
                        snapshot: await registry.currentSnapshot) == nil)
                }
                #expect(f.selections == [1, 0, 1, 0, 1, 0])
                #expect(!f.routingWrongSourcePressed && f.routingDestinationPresses == 0 && f.scrollWrites.isEmpty)
                let currentRouting = try #require(routing)
                #expect(!currentRouting.complete && !currentRouting.nodes.contains { $0.kind == .aux })
                return
            }
            if condition == "unselected_pair" {
                // The retained target is still the exact captured header, but a
                // different track is selected when its input popup is read.
                f.builder.setAttribute(f.headers[0], kAXSelectedAttribute as String, false)
                f.builder.setAttribute(f.headers[1], kAXSelectedAttribute as String, true)
                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.strips[0])
            }
            if condition == "missing_pair" { f.expireRetainedCapture = true }
            let gate = LogicMutationGate(), router = ChannelRouter(), channel = f.channel()
            await router.register(channel)
            let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                poller: StatePoller(axChannel: channel, cache: cache,
                    runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable,
                        keyboardFocus: { .notTextEditing })),
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
                liveTrackNames: { [0: "Duplicate", 1: "Duplicate"] }, projectFileReader: .unavailable)
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "get_input_bus_verified"))
            let params: [String: Value] = ["target_ref": .string(target.rawValue)]
            let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "get_input_bus_verified",
                commandParams: params, mutationGate: gate) {
                    return await FeatureFlags.withAdr002TargetRefForTests(true) {
                        await handler(dependencies, params)
                    }
                }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(f.inputMenuPresses == 1 && f.inputMenuCancels == 1, "The owned input popup and its retirement must actually execute")
            #expect(f.routingReplacement != nil)
            #expect(!f.routingWrongSourcePressed && f.routingDestinationPresses == 0 && f.scrollWrites.isEmpty)
            let current = try #require(AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: f.mixer,
                runtime: f.builder.makeAXRuntime()))
            #expect(!current.strips.contains { CFEqual($0, f.strips[1]) }, "The original source is genuinely absent, not renamed in place")
            let succeeded = condition == "paired" || condition == "unselected_pair" || condition == "selected_child"
            #expect(body["state"] as? String == (succeeded ? "A" : "C"), "Input renewal response: \(sharedToolText(result))")
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(!attempted)
            if succeeded {
                #expect(f.inputMenuHadOwnedClaim, "The real read-only deadline path must hold the existing observation claim")
                #expect(f.selections == (condition == "unselected_pair" ? [1, 0, 0, 1] : [1, 0, 1, 0]))
                let input = try #require(body["current_input"] as? [String: Any])
                #expect(input["kind"] as? String == "bus" && input["number"] as? Int == number,
                    "Bus 256 display text cannot assign the checked Bus 1 value")
                let reread = try #require(body["reference_reread_required"] as? Bool)
                #expect(reread)
                #expect(body["source_renewal"] as? String == (condition == "selected_child"
                    ? "held_exclusive_selection_selected_child" : "held_exclusive_selection_focus"))
                #expect(body["popup_menu_state"] as? String == "closed")
                if condition == "unselected_pair" {
                    let selected = try #require(f.builder.attributeValue(f.headers[1], kAXSelectedAttribute as String) as? Bool)
                    #expect(selected)
                    let focus: AXUIElement = try #require(AXHelpers.getAttribute(f.app,
                        kAXFocusedUIElementAttribute as String, runtime: f.builder.makeAXRuntime()))
                    #expect(CFEqual(focus, f.strips[0]), "Renewal must restore the other originally selected track, not leave its target selected")
                }
                #expect(!gate.isHeldByEntitledHolder())
            } else {
                #expect(body["current_input"] == nil)
                if condition == "partial_restore" || condition == "deciding_read" || condition == "deciding_control_replaced" {
                    #expect(f.routingLateScopeInjected, "The refusing late boundary must actually be reached")
                } else { #expect(f.selections == [1, 0], "Unavailable original authority must not acquire by duplicate name or ordinal") }
            }
        }
    }

    @Test("A failed final input renewal cannot inherit an earlier restored writer receipt")
    func inputWriterFinalRenewalFailureOverridesEarlierRestoration() async throws {
        let f = try Fixture(), b = f.builder
        let input = b.element(1_291_100), output = b.element(1_291_101)
        let renewed = b.element(1_291_102), finalRetired = b.element(1_291_103)
        let inputRoot = b.element(1_291_104), inputEcho = b.element(1_291_105)
        let busParent = b.element(1_291_106), busMenu = b.element(1_291_107)
        let busOne = b.element(1_291_108), busTwo = b.element(1_291_109)
        let outputRoot = b.element(1_291_110), outputParent = b.element(1_291_111)
        let outputMenu = b.element(1_291_112), outputEcho = b.element(1_291_113), outputLeaf = b.element(1_291_114)
        b.setRole(f.mixer, kAXLayoutAreaRole as String); b.setAttribute(f.mixer, kAXDescriptionAttribute as String, "Mixer")
        let mixerOwner = b.element(1_291_115)
        b.setRole(mixerOwner, kAXGroupRole as String); b.setAttribute(mixerOwner, kAXDescriptionAttribute as String, "Mixer")
        b.setChildren(mixerOwner, [f.mixer])
        b.setChildren(f.window, [f.rail, mixerOwner, b.element(1_965_720)])
        b.setButton(input, description: "Bus 1", help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 60, height: 20)
        b.setButton(output, description: "Stereo Output", help: "Output slot. Choose the channel strip output destination.", x: 0, y: 30, width: 60, height: 20)
        for control in [input, output] { b.setChildren(control, []); b.setActionNames(control, [kAXPressAction as String]) }
        let name = try #require(b.makeAXRuntime().children(f.strips[1]).first)
        b.setChildren(f.strips[1], [name, input, output])
        for strip in [renewed, finalRetired] {
            b.setRole(strip, kAXLayoutItemRole as String)
            b.setAttribute(strip, kAXNumberOfCharactersAttribute as String, 0)
            b.setAttribute(strip, kAXInsertionPointLineNumberAttribute as String, 0)
        }
        for menu in [inputRoot, busMenu, outputRoot, outputMenu] { b.setRole(menu, kAXMenuRole as String) }
        for root in [inputRoot, outputRoot] { b.setActionNames(root, [kAXCancelAction as String]) }
        for (node, title) in [(inputEcho, "Bus 1"), (busParent, "Bus"), (busOne, "Bus 1"), (busTwo, "Bus 2"),
                              (outputParent, "Output"), (outputEcho, "Stereo Output"), (outputLeaf, "Stereo Output")] {
            b.setRole(node, kAXMenuItemRole as String); b.setAttribute(node, kAXTitleAttribute as String, title)
            b.setAttribute(node, kAXEnabledAttribute as String, true); b.setChildren(node, [])
        }
        b.setActionNames(busTwo, [kAXPressAction as String])
        b.setAttribute(inputEcho, "AXMenuItemMarkChar", "✓"); b.setAttribute(busOne, "AXMenuItemMarkChar", "✓")
        for node in [outputEcho, outputLeaf] { b.setAttribute(node, "AXMenuItemMarkChar", "✓") }
        b.setChildren(busMenu, [busOne, busTwo]); b.setChildren(busParent, [busMenu]); b.setChildren(inputRoot, [inputEcho, busParent])
        b.setChildren(outputMenu, [outputLeaf]); b.setChildren(outputParent, [outputMenu]); b.setChildren(outputRoot, [outputEcho, outputParent])
        f.routingAction = { element, action in
            let source = f.routingReplacement ?? f.strips[1]
            if action == kAXPressAction as String, CFEqual(element, input) || CFEqual(element, output) {
                if CFEqual(element, input) { f.inputMenuPresses += 1 }
                b.setChildren(f.mixer, [f.strips[0], source, CFEqual(element, input) ? inputRoot : outputRoot])
                return true
            }
            if action == kAXPressAction as String, CFEqual(element, busTwo) {
                f.routingDestinationPresses += 1
                b.setAttribute(input, kAXDescriptionAttribute as String, "Bus 2")
                b.setAttribute(inputEcho, kAXTitleAttribute as String, "Bus 2")
                b.setAttribute(busOne, "AXMenuItemMarkChar", ""); b.setAttribute(busTwo, "AXMenuItemMarkChar", "✓")
                b.setChildren(renewed, [name, input, output]); f.routingReplacement = renewed
                b.setChildren(f.mixer, [f.strips[0], renewed]); b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, renewed)
                return true
            }
            if action == kAXCancelAction as String, CFEqual(element, inputRoot) || CFEqual(element, outputRoot) {
                if CFEqual(element, inputRoot) {
                    f.inputMenuCancels += 1
                    if f.inputMenuPresses == 3 {
                        b.setChildren(finalRetired, [name, input, output]); f.routingReplacement = finalRetired
                    }
                }
                let current = f.routingReplacement ?? f.strips[1]
                b.setChildren(f.mixer, [f.strips[0], current])
                b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.routingReplacement == nil ? f.window : current)
                return true
            }
            Issue.record("Only owned input/output popups, Cancel and the exact Bus 2 leaf are allowed"); return false
        }
        f.routingSelection = { _ in
            if f.inputMenuPresses == 3 {
                f.routingLateScopeInjected = true
                b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
            }
        }
        let gate = LogicMutationGate()
        let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_input_bus_verified", mutationGate: gate) {
            let runtime = f.logic()
            guard let observation = AccessibilityChannel.HeldSelectionAssociation(window: f.window, logic: runtime,
                expectedProject: nil, requiresProjectReference: false) else {
                Issue.record("The original pair must be actually acquired"); return toolTextResult(.error("fixture"))
            }
            let pairs = await observation.observe(referenceIsCurrent: { true }, stoppingWhen: { false }, allHeldHeaders: true)
            guard let pair = pairs.first(where: { CFEqual($0.track.header, f.headers[0]) }), observation.effects.restoration == "restored" else {
                Issue.record("The original selected header must have its actual restored physical pair"); return toolTextResult(.error("fixture"))
            }
            // Stable-source writer entry uses the same nonediting window focus
            // as the existing input-writer fixture; later retirement uses actual HSA focus.
            b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.window)
            return await AXMixerStripBinding.$current.withValue(pair.strip) {
                await AXMixerStripBinding.$outputAssociation.withValue(pair) {
                    toolTextResult(await AccessibilityChannel.setInputBusVerified(params: ["destination": "bus:2", "expected_current": "bus:1", "replace_existing": "true"], runtime: runtime, timing: .immediate))
                }
            }
        }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(f.routingDestinationPresses == 1 && f.inputMenuPresses == 3 && f.inputMenuCancels == 2)
        #expect(f.routingLateScopeInjected)
        #expect(body["state"] as? String == "B", "Input writer reached receipt: \(body)")
        let verified = try #require(body["verified"] as? Bool); #expect(!verified)
        let attempted = try #require(body["write_attempted"] as? Bool); #expect(attempted)
        let after = try #require(body["after_acquisition"] as? [String: Any])
        #expect(after["output_checkmark_reads_observed"] as? Int == 2)
        let afterEffects = try #require(after["ui_effects"] as? [String: Any])
        #expect(afterEffects["restoration"] as? String == "not_restored")
        #expect(afterEffects["reason"] as? String == "association_restoration_unverified")
        let effects = try #require(body["ui_effects"] as? [String: Any])
        #expect(effects["restoration"] as? String == "not_restored")
        #expect(effects["reason"] as? String == "association_restoration_unverified")
    }

    @Test(arguments: [1, 256], ["paired", "selected_child"])
    func inputBusRenewsRetiredSourceThroughOriginalCapturedHeader(number: Int, condition: String) async throws {
        try await assertInputBusRenewal(number: number, condition: condition)
    }

    @Test(arguments: [1, 256])
    func registeredRoutingCapturePublishesRenewedInputReceiver(number: Int) async throws {
        try await assertInputBusRenewal(number: number, condition: "paired", graph: true)
    }

    @Test("An owned input renewal retains exact source authority for later checked output acquisition")
    func registeredInputRenewalPreservesLaterCheckedOutput() async throws {
        try await assertInputBusRenewal(number: 1, condition: "paired", graph: true, readOutputAfterRenewal: true)
    }

    @Test func registeredReceiverKeepRenewsOnlyItsOriginallyCapturedHeader() async throws {
        try await assertInputBusRenewal(number: 1, condition: "paired", graph: true, keep: true)
    }

    @Test(arguments: ["replaced_header", "foreign_project", "foreign_focus", "partial_restore",
                      "deciding_read", "deciding_control_replaced", "renewed_label_changed"])
    func registeredReceiverKeepRefusesLostOriginalRenewal(condition: String) async throws {
        try await assertInputBusRenewal(number: 1, condition: condition, graph: true, keep: true)
    }

    @Test(arguments: [1, 256])
    func registeredInputGraphDoesNotReadRetiredControlsAfterFocusMoves(number: Int) async throws {
        try await assertInputBusRenewal(number: number, condition: "retirement_census_lag", graph: true)
    }

    @Test func registeredPairedInputGraphDoesNotOpenAnUnpairedAuxPopup() async throws {
        try await assertInputBusRenewal(number: 256, condition: "unpaired_bus", graph: true)
    }

    @Test(arguments: [1, 256])
    func registeredInputGraphUsesActualRenewalCensusWithoutRetargetingOldAssociations(number: Int) async throws {
        try await assertInputBusRenewal(number: number, condition: "whole_census_retirement", graph: true)
    }

    @Test func registeredInputGraphKeepsOnlyTheSurvivingSecondRenewal() async throws {
        try await assertInputBusRenewal(number: 1, condition: "two_input_retirements", graph: true)
    }

    @Test(arguments: ["missing_pair", "replaced_header", "foreign_project", "foreign_focus", "partial_restore",
                      "deciding_read", "deciding_control_replaced", "popup_still_open", "unselected_pair", "navigation_disabled",
                      "whole_census_late_reorder"])
    func registeredInputGraphRefusesLostRenewalAuthority(condition: String) async throws {
        try await assertInputBusRenewal(number: 1, condition: condition, graph: true)
    }

    @Test func inputBusRenewsCapturedTargetWhileAnotherTrackIsSelected() async throws {
        try await assertInputBusRenewal(number: 1, condition: "unselected_pair")
    }

    @Test(arguments: ["missing_pair", "replaced_header", "foreign_project", "foreign_focus", "partial_restore", "deciding_read", "deciding_control_replaced", "popup_still_open"])
    func inputBusRenewalRefusesLostOriginalAuthority(condition: String) async throws {
        try await assertInputBusRenewal(number: 1, condition: condition)
    }

    @Test(arguments: [false, true])
    func heldWindowScopeUsesFreshTitleDocumentBatchOnlyOnCapableRuntimes(bulk: Bool) async throws {
        let f = try Fixture()
        f.useBulkReads = bulk
        let body = try await inspect(f)
        let rows = try #require((body["associations"] as? [String: Any])?["rows"] as? [[String: Any]])
        #expect(rows.count == 2 && f.selections == [1, 0])
        #expect(bulk ? f.windowScopeBatchCalls > 0 : f.windowScopeBatchCalls == 0)
    }

    @Test("One selected-child custody decision coalesces only its two app-window reads",
          arguments: [false, true])
    func selectedChildWindowCustodyUsesOneFreshBatch(bulk: Bool) async throws {
        let f = try Fixture(withViewport: true)
        f.useBulkReads = bulk
        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
        f.builder.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.strips[0]])
        f.routingReadResult = { element, attribute in
            if CFEqual(element, f.rail), [kAXValueAttribute, kAXSelectedTextAttribute,
                kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute].map({ $0 as String }).contains(attribute) {
                return .failure(.init(raw: AXError.noValue.rawValue))
            }
            return nil
        }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        try await OperationTraceContext.$current.withValue(context) {
            let scalarDefault = AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: f.logic(), expectedProject: nil, requiresProjectReference: false)
            #expect(scalarDefault == nil, "Request-owned rail entry must not change scalar/default acquisition")
            let association = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: f.logic(), expectedProject: nil, requiresProjectReference: false,
                allowsSelectedChildRailEntry: true))
            f.windowCustodyBatchCalls = 0; f.windowCustodySingleReads = 0
            #expect(association.permitsRead())
            #expect(f.windowCustodyBatchCalls == (bulk ? 1 : 0))
            #expect(f.windowCustodySingleReads == (bulk ? 0 : 4))
            #expect(f.selections.isEmpty && f.focusRestorationWrites.isEmpty)
        }
    }

    @Test("Selected-child app-window custody refuses bad values and a later document change",
          arguments: ["absent", "main_type", "focused_type", "foreign_main", "foreign_focused", "late_document", "failure", "short"])
    func selectedChildWindowCustodyRetainsRefusals(fault: String) async throws {
        let f = try Fixture(withViewport: true)
        f.useBulkReads = true
        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
        f.builder.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.strips[0]])
        f.routingReadResult = { element, attribute in
            if CFEqual(element, f.rail), [kAXValueAttribute, kAXSelectedTextAttribute,
                kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute].map({ $0 as String }).contains(attribute) {
                return .failure(.init(raw: AXError.noValue.rawValue))
            }
            return nil
        }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        try await OperationTraceContext.$current.withValue(context) {
            let association = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: f.logic(), expectedProject: nil, requiresProjectReference: false,
                allowsSelectedChildRailEntry: true))
            f.windowCustodyBatchCalls = 0
            f.windowCustodyFault = fault
            #expect(!association.permitsRead())
            #expect(f.windowCustodyBatchCalls > 0)
            #expect(f.selections.isEmpty && f.focusRestorationWrites.isEmpty)
        }
    }

    @Test(arguments: ["failure", "short", "title_type", "document_type",
                      "foreign_title", "foreign_document", "document_after_batch"])
    func failedFreshWindowScopeBatchOrLaterDocumentChangeCannotAuthorizeSelection(fault: String) async throws {
        let f = try Fixture()
        f.useBulkReads = true
        f.windowScopeBatchFault = fault
        let body = try await inspect(f)
        #expect(f.windowScopeBatchCalls > 0)
        #expect(f.selections.isEmpty)
        let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]]
        #expect((rows?.count ?? 0) == 0)
    }

    @Test(arguments: [false, true])
    func unchangedHeldMixerFocusRefusesAssociationButRestoresOwnedSelection(bulk: Bool) async throws {
        let f = try Fixture()
        f.useBulkReads = bulk
        f.fault = "unchanged_focus"
        let body = try await inspect(f)
        #expect(f.selections == [1, 0], "Actual Logic can change the held rail selection without changing its original passive Mixer focus")
        let selected = try #require(f.builder.attributeValue(f.headers[0], kAXSelectedAttribute as String) as? Bool)
        #expect(selected)
        let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]]
        #expect((rows?.count ?? 0) == 0, "An unchanged physical focus proves no track-to-strip pair")
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        #expect(f.presentationCensusReads == 2, "A refused association publishes no population; do not repeat a whole native acquisition after its verified cleanup")
        let focus: AXUIElement = try #require(AXHelpers.getAttribute(f.app, kAXFocusedUIElementAttribute as String,
            runtime: f.builder.makeAXRuntime()))
        #expect(CFEqual(focus, f.strips[1]))
    }

    @Test func delayedOwnMixerFocusPublishesPairsAndRestoresOriginalSelection() async throws {
        let f = try Fixture()
        f.fault = "delayed_own_focus"
        let body = try await inspect(f)
        #expect(f.delayedOwnFocusRead, "The first post-selection read must actually return the original held focus")
        #expect(f.selections == [1, 0])
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        let rows = try #require((body["associations"] as? [String: Any])?["rows"] as? [[String: Any]])
        let tracks = try #require((body["tracks"] as? [String: Any])?["rows"] as? [[String: Any]])
        let strips = try #require((body["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
        #expect(rows.count == 2)
        for row in rows {
            let index = try #require(row["track_index"] as? Int)
            #expect(row["track_ref"] as? String == tracks[index]["track_ref"] as? String)
            #expect(row["mixer_strip_ref"] as? String == strips[1 - index]["mixer_strip_ref"] as? String)
        }
        let selected = try #require(f.builder.attributeValue(f.headers[0], kAXSelectedAttribute as String) as? Bool)
        #expect(selected)
        let focus: AXUIElement = try #require(AXHelpers.getAttribute(f.app, kAXFocusedUIElementAttribute as String,
            runtime: f.builder.makeAXRuntime()))
        #expect(CFEqual(focus, f.strips[1]))
    }

    @Test func explicitNavigationPublishesPhysicalPairsWithoutNameOrOrdinalJoin() async throws {
        let f = try Fixture()
        let body = try await inspect(f)
        let section = try #require(body["associations"] as? [String: Any])
        let rows = try #require(section["rows"] as? [[String: Any]])
        let tracks = try #require((body["tracks"] as? [String: Any])?["rows"] as? [[String: Any]])
        let strips = try #require((body["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
        #expect(rows.count == 2)
        for row in rows {
            let trackIndex = try #require(row["track_index"] as? Int)
            #expect(row["track_ref"] as? String == tracks[trackIndex]["track_ref"] as? String)
            #expect(row["mixer_strip_ref"] as? String == strips[1 - trackIndex]["mixer_strip_ref"] as? String)
            #expect(row["source"] as? String == "held_exclusive_selection_focus")
        }
        #expect(section["coverage"] as? String == "partial", "visible pairs are not whole-population proof")
        #expect(f.selections == [1, 0])
        let selected = try #require(f.builder.attributeValue(f.headers[0], kAXSelectedAttribute as String) as? Bool)
        #expect(selected)
        let focus: AXUIElement = try #require(AXHelpers.getAttribute(f.app, kAXFocusedUIElementAttribute as String,
            runtime: f.builder.makeAXRuntime()))
        #expect(CFEqual(focus, f.strips[1]))
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
    }

    @Test(arguments: ["healthy", "retained_focus", "own_landing", "foreign_editor", "foreign_held_strip"])
    func wholeInspectionKeepsOnlyItsOwnLateSelectionFocus(fault: String) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true), b = f.builder
        f.useBulkReads = true
        for (index, header) in f.headers.enumerated() {
            b.setAttribute(header, kAXSelectedAttribute as String, index == 3)
        }
        b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.strips[2])
        b.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.strips[2]])
        f.thirdRetainsPreviousFocus = fault == "retained_focus"
        f.routingSelection = { index in
            let source = index == 0 ? 1 : index == 1 ? 0 : index == 2 ? 3 : 2
            b.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.strips[source]])
        }
        let inject = ["own_landing", "foreign_editor", "foreign_held_strip"].contains(fault)
        let foreign = b.element(1_965_799)
        b.setRole(foreign, kAXTextFieldRole as String)
        b.setAttribute(foreign, kAXWindowAttribute as String, f.window)
        f.routingRead = { element, attribute in
            guard inject, f.selections.last == 2 else { return }
            if CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String,
               !f.lateAssociationFocusSampled {
                f.lateAssociationFocusSampled = true
                // The selected child already identifies challenge 2; keyboard
                // focus still reflects the preceding, completely held strip.
                b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.strips[0])
            }
            if f.lateAssociationFocusSampled, !f.lateAssociationFocusLanded,
               CFEqual(element, f.scroll), attribute == kAXValueAttribute as String {
                f.lateAssociationFocusLanded = true
                let focus = fault == "own_landing" ? f.strips[3]
                    : fault == "foreign_held_strip" ? f.strips[1] : foreign
                b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, focus)
            }
        }
        let body = try await inspect(f)
        let effects = try #require(body["ui_effects"] as? [String: Any])
        let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
        if inject {
            #expect(f.lateAssociationFocusSampled && f.lateAssociationFocusLanded,
                "Reach the target-2 focus sample and unchanged viewport boundary")
        }
        if fault.hasPrefix("foreign_") {
            #expect(rows.isEmpty)
            #expect(effects["restoration"] as? String != "restored")
            #expect(f.selections.last == 2, "A foreign focus must not grant another selection write")
        } else {
            #expect(rows.count == 4, "\(body)")
            #expect(effects["restoration"] as? String == "restored")
            #expect(f.selections == [0, 1, 2, 3])
            let focus: AXUIElement = try #require(AXHelpers.getAttribute(f.app,
                kAXFocusedUIElementAttribute as String, runtime: f.logic().ax))
            #expect(CFEqual(focus, f.strips[2]))
            #expect(b.attributeValue(f.scroll, kAXValueAttribute as String) as? Double == 0.8)
        }
    }

    @Test("Whole-project inspection observes all held headers, without a duplicate-name or ordinal join",
          arguments: [false, true])
    func wholeInspectionObservesEveryHeldHeader(shared: Bool) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        f.sharedThirdStrip = shared
        f.fault = "selection_scroll"
        let cache = StateCache(), registry = TargetRegistry()
        let body = try await inspect(f, cache: cache, registry: registry)
        let section = try #require(body["associations"] as? [String: Any])
        let rows = try #require(section["rows"] as? [[String: Any]])
        let strips = try #require((body["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
        #expect(rows.count == 4)
        for (trackIndex, stripIndex) in [(0, 1), (1, 0), (2, shared ? 0 : 3), (3, 2)] {
            let row = try #require(rows.first { $0["track_index"] as? Int == trackIndex })
            #expect(row["mixer_strip_ref"] as? String == strips[stripIndex]["mixer_strip_ref"] as? String)
        }
        #expect(f.selections == (shared ? [1, 2, 0, 2, 3, 0] : [1, 2, 3, 0]))
        #expect(f.scrollWrites == [0.8])
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        #expect(section["coverage"] as? String == "partial", "Held exposed headers still do not prove global population")
        if shared {
            let id = try #require(body["snapshot_id"] as? String)
            let retained = try #require(await cache.retainedInspection(id: id))
            let source = try #require(retained.capture.channelStrips[0].physicalBinding)
            let ref = try #require(retained.capture.mixerReference(at: 0))
            #expect(await cache.retainedMixerAssociation(reference: ref, source: source,
                snapshot: await registry.currentSnapshot) == nil,
                "Publishing observed aliases must not grant a scalar writer unique source-header custody")
        }
    }

    @Test("An original held focus may be restored without manufacturing an original-header association")
    func wholeInspectionRestoresRetainedFocusWithoutUsingInverseAsPairEvidence() async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        f.fault = "restore_retains_held_focus"
        f.builder.setAttributeSettable(f.strips[1], kAXFocusedAttribute as String, true)
        let body = try await inspect(f)
        let section = try #require(body["associations"] as? [String: Any])
        let rows = section["rows"] as? [[String: Any]] ?? []
        #expect(Set(rows.compactMap { $0["track_index"] as? Int }) == Set([1, 2, 3]),
            "Explicit focus restoration is cleanup, never evidence that the original header maps to that strip")
        #expect(f.selections == [1, 2, 3, 0])
        #expect(f.focusRestorationWrites.count == 1)
        let restoredFocus = try #require(f.focusRestorationWrites.first)
        #expect(CFEqual(restoredFocus, f.strips[1]))
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        let focus: AXUIElement = try #require(AXHelpers.getAttribute(f.app,
            kAXFocusedUIElementAttribute as String, runtime: f.builder.makeAXRuntime()))
        #expect(CFEqual(focus, f.strips[1]))
    }

    @Test("Native-shaped passive focus guarding permits only the observed original-focus inverse",
          arguments: [false, true])
    func originalFocusInverseRenewsBeforeThePassiveEditingGuard(ackOnly: Bool) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        f.fault = "restore_retains_held_focus"
        f.focusRestorationAckOnly = ackOnly
        f.builder.setAttributeSettable(f.strips[1], kAXFocusedAttribute as String, true)
        for strip in f.strips {
            f.builder.setAttribute(strip, kAXInsertionPointLineNumberAttribute as String, 0)
        }
        let body = try await inspect(f, guardedPassiveFocus: true)
        #expect(f.focusRestorationWrites.count == 1)
        if ackOnly {
            #expect(body["associations"] == nil)
            #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored")
        } else {
            let section = try #require(body["associations"] as? [String: Any])
            let rows = section["rows"] as? [[String: Any]] ?? []
            #expect(Set(rows.compactMap { $0["track_index"] as? Int }) == Set([1, 2, 3]))
            #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        }
    }

    @Test("An ambiguous held focus does not erase independently observed pairs when baseline selection retains focus")
    func retainedBaselineFocusLeavesOnlyTheAmbiguousHeaderUnknown() async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        f.fault = "restore_retains_held_focus"
        f.thirdRetainsPreviousFocus = true
        f.builder.setAttributeSettable(f.strips[1], kAXFocusedAttribute as String, true)
        let body = try await inspect(f, guardedPassiveFocus: true)
        let section = try #require(body["associations"] as? [String: Any])
        let rows = section["rows"] as? [[String: Any]] ?? []
        #expect(Set(rows.compactMap { $0["track_index"] as? Int }) == Set([1, 3]))
        #expect(section["coverage"] as? String == "partial")
        #expect(f.selections == [1, 2, 0, 3, 0])
        #expect(f.focusRestorationWrites.count == 1)
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
    }

    @Test("Optional whole-held challenges leave deadline time for the original inverse and final population",
          arguments: [6, 11])
    func wholeHeldCollectionLeavesOwnedDeadlineTimeForRestoration(elapsedSeconds: Int) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let start = ContinuousClock.now
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) },
                                            deadline: start.advanced(by: .seconds(20)))
        try await OperationTraceContext.$current.withValue(context) {
            let association = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: f.logic(), expectedProject: nil, requiresProjectReference: false))
            let pairs = await association.observe(referenceIsCurrent: { true }, stoppingWhen: { false },
                allHeldHeaders: true, collectionNow: {
                    start.advanced(by: f.selections.isEmpty ? .zero : .seconds(elapsedSeconds))
                })
            #expect(f.selections == [1, 0], "Stop optional challenges, not the still-owned inverse")
            #expect(pairs.count == 2, "Retain only the independently verified subset")
            #expect(association.effects.restoration == "restored")
        }
    }

    @Test("Measured population cost reserves both rechecks without an unrelated quarter-deadline cap",
          arguments: [6, 11, 16])
    func measuredCollectionUsesAvailableTimeWithoutSpendingRecheckReserve(elapsedSeconds: Int) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let start = ContinuousClock.now
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) },
                                            deadline: start.advanced(by: .seconds(20)))
        try await OperationTraceContext.$current.withValue(context) {
            let association = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: f.logic(), expectedProject: nil, requiresProjectReference: false))
            let pairs = await association.observe(referenceIsCurrent: { true }, stoppingWhen: { false },
                allHeldHeaders: true, populationReadDuration: .seconds(2), collectionNow: {
                    start.advanced(by: f.selections.isEmpty ? .zero : .seconds(elapsedSeconds))
                })
            if elapsedSeconds < 16 {
                #expect(f.selections == [1, 2, 3, 0])
                #expect(pairs.count == 4)
            } else {
                #expect(f.selections == [1, 0], "The measured two-read reserve still ends optional challenges")
                #expect(pairs.count == 2)
            }
            #expect(association.effects.restoration == "restored")
        }
    }

    @Test("Insufficient measured recheck time refuses optional navigation without inventing instability")
    func measuredRecheckReservePreservesUnchangedInitialPopulation() async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let start = ContinuousClock.now
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) },
                                            deadline: start.advanced(by: .seconds(20)))
        try await OperationTraceContext.$current.withValue(context) {
            let association = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: f.logic(), expectedProject: nil, requiresProjectReference: false))
            let pairs = await association.observe(referenceIsCurrent: { true }, stoppingWhen: { false },
                allHeldHeaders: true, populationReadDuration: .seconds(11), collectionNow: { start })
            #expect(pairs.isEmpty)
            #expect(f.selections.isEmpty)
            #expect(f.focusRestorationWrites.isEmpty)
            #expect(f.scrollWrites.isEmpty)
            #expect(!association.effects.navigationPerformed)
            #expect(association.effects.attempted.isEmpty)
            #expect(association.effects.restoration == "not_applicable")
            #expect(association.effects.reason == nil)
        }
    }

    @Test("Final focus-restoration reads cannot overwrite foreign focus or a retired reference",
          arguments: ["reference", "foreign_focus"])
    func finalFocusInverseCustodyReadCannotAuthorizeItsWrite(fault: String) async throws {
        func observe(_ f: Fixture) async throws -> SessionPopulationObservation.FreshPopulation {
            let gate = LogicMutationGate()
            let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
            defer { gate.release(claim) }
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
            return try await OperationTraceContext.$current.withValue(context) {
                try await f.channel().readFreshSessionPopulation(
                    request: .init(domains: [.tracks, .strips, .associations], allowUINavigation: true),
                    fileReader: .unavailable,
                    navigationReferenceIsCurrent: { f.referenceCurrent }, stoppingWhen: { false })
            }
        }
        let calibration = try Fixture(withViewport: true, fourTracks: true)
        calibration.fault = "restore_retains_held_focus"
        calibration.builder.setAttributeSettable(calibration.strips[1], kAXFocusedAttribute as String, true)
        calibration.routingRead = { element, attribute in
            if calibration.selections == [1, 2, 3, 0], CFEqual(element, calibration.builder.element(1_965_721)),
               attribute == kAXValueAttribute as String { calibration.cleanupTransportReads += 1 }
        }
        let positive = try await observe(calibration)
        #expect(positive.selectionAssociations.count == 3)
        #expect(calibration.focusRestorationWrites.count == 1)
        #expect(calibration.cleanupTransportReadsAtWrite > 0)
        let f = try Fixture(withViewport: true, fourTracks: true)
        f.fault = "restore_retains_held_focus"
        f.builder.setAttributeSettable(f.strips[1], kAXFocusedAttribute as String, true)
        f.routingRead = { element, attribute in
            if f.selections == [1, 2, 3, 0], CFEqual(element, f.builder.element(1_965_721)),
               attribute == kAXValueAttribute as String {
                f.cleanupTransportReads += 1
                if f.cleanupTransportReads == calibration.cleanupTransportReadsAtWrite {
                    f.cleanupScopeInjected = true
                    if fault == "reference" { f.referenceCurrent = false }
                    else {
                        let editor = f.builder.element(1_965_989)
                        f.builder.setRole(editor, kAXTextFieldRole as String)
                        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, editor)
                    }
                }
            }
        }
        let refused = try await observe(f)
        #expect(f.cleanupScopeInjected, "Inject at the actual final custody read before the explicit inverse")
        #expect(f.focusRestorationWrites.isEmpty)
        #expect(refused.selectionAssociations.isEmpty)
        #expect(refused.uiEffects.restoration == "not_restored")
    }

    @Test("Focus cleanup refuses lost custody and never treats a setter acknowledgement as restoration",
          arguments: ["unsettable", "document", "foreign_focus", "retired_original", "playing", "newer_viewport", "ack_only"])
    func focusCleanupRequiresOriginalCustodyAndObservedEffect(fault: String) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        f.fault = "restore_retains_held_focus"
        f.focusRestorationAckOnly = fault == "ack_only"
        f.builder.setAttributeSettable(f.strips[1], kAXFocusedAttribute as String, fault != "unsettable")
        if fault != "unsettable", fault != "ack_only" {
            f.routingRead = { element, attribute in
                guard !f.cleanupScopeInjected, f.selections == [1, 2, 3, 0],
                      CFEqual(element, f.strips[1]), attribute == kAXNumberOfCharactersAttribute as String else { return }
                f.cleanupScopeInjected = true
                switch fault {
                case "document": f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                case "foreign_focus": f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.headers[0])
                case "retired_original": f.builder.setChildren(f.mixer, f.strips.filter { !CFEqual($0, f.strips[1]) })
                case "playing": f.builder.setAttribute(f.builder.element(1_965_721), kAXValueAttribute as String, 1)
                case "newer_viewport": f.builder.setAttribute(f.scroll, kAXValueAttribute as String, NSNumber(value: 0.6))
                default: Issue.record("Unknown cleanup counterexample")
                }
            }
        }
        let body = try await inspect(f)
        #expect(f.selections == [1, 2, 3, 0])
        if fault != "unsettable", fault != "ack_only" { #expect(f.cleanupScopeInjected) }
        #expect(f.focusRestorationWrites.count == (fault == "ack_only" ? 1 : 0))
        #expect(f.scrollWrites.isEmpty)
        #expect(body["associations"] == nil)
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored")
    }

    @Test("Selection scope retains its bounded challenge and excludes unselected pairs")
    func selectionInspectionDoesNotScanAllHeldHeaders() async throws {
        let f = try Fixture(fourTracks: true)
        let body = try await inspect(f, scope: "selection")
        let rows = try #require((body["associations"] as? [String: Any])?["rows"] as? [[String: Any]])
        #expect(rows.count == 1 && rows.first?["track_index"] as? Int == 0)
        #expect(f.selections == [1, 0])
    }

    @Test("Selection challenge evidence cannot authorize an unselected peer's routing popup", arguments: ["input", "output"])
    func selectionChallengeDoesNotPromotePeerRoutingAuthority(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture(), cache = StateCache()
            let mixerOwner = f.builder.element(1_974_101)
            f.builder.setRole(f.mixer, kAXLayoutAreaRole as String)
            f.builder.setAttribute(f.mixer, kAXDescriptionAttribute as String, "Mixer")
            f.builder.setRole(mixerOwner, kAXGroupRole as String)
            f.builder.setAttribute(mixerOwner, kAXDescriptionAttribute as String, "Mixer")
            f.builder.setChildren(mixerOwner, [f.mixer])
            f.builder.setChildren(f.window, [f.rail, mixerOwner, f.builder.element(1_965_720)])
            let peerInput = f.builder.element(1_974_100)
            f.builder.setButton(peerInput, description: kind == "input" ? "Bus 1" : "Stereo Output",
                help: kind == "input" ? "Input slot. Choose the channel strip input source." : "Output slot. Choose the channel strip output.",
                x: 0, y: 0, width: 1, height: 1)
            f.builder.setChildren(peerInput, [])
            f.builder.setActionNames(peerInput, [kAXPressAction as String])
            f.builder.setChildren(f.strips[0], f.builder.makeAXRuntime().children(f.strips[0]) + [peerInput])
            f.routingAction = { element, action in
                if CFEqual(element, peerInput), action == kAXPressAction as String { f.inputMenuPresses += 1 }
                return false
            }
            let body = try await inspect(f, cache: cache,
                domains: ["tracks", "strips", "associations", "routing"], scope: "selection")
            #expect(f.inputMenuPresses == 0, "The restored challenge is not a selected routing target")
            #expect(f.selections == [1, 0])
            let id = try #require(body["snapshot_id"] as? String, "Actual response: \(body)")
            let retained = try #require(await cache.retainedInspection(id: id))
            let population = try #require(retained.capture.freshPopulation)
            #expect(population.selectionAssociations.count == 1)
            let pair = try #require(population.selectionAssociations.first)
            #expect(CFEqual(pair.track.header, f.headers[0]) && CFEqual(pair.strip.strip, f.strips[1]))
            if kind == "input" {
                #expect(retained.capture.channelStrips[0].inputObservation?.source == "Bus 1")
                #expect(retained.capture.channelStrips[0].inputObservation?.state == .observedSource)
            } else { #expect(retained.capture.channelStrips[0].output == "Stereo Output") }
            #expect(population.checkedInputs.isEmpty)
            #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        }
    }

    @Test("Whole-header selection does not repeat full selection bookends before the same action")
    func wholeHeaderSelectionsAvoidRedundantBookends() async throws {
        let f = try Fixture(fourTracks: true)
        f.routingRead = { element, attribute in
            if attribute == kAXSelectedAttribute as String,
               f.headers.contains(where: { CFEqual($0, element) }) { f.wholeHeaderSelectionReads += 1 }
        }
        let body = try await inspect(f)
        let rows = try #require((body["associations"] as? [String: Any])?["rows"] as? [[String: Any]])
        #expect(rows.count == 4 && f.selections == [1, 2, 3, 0])
        #expect(f.wholeHeaderSelectionReads <= 300,
            "Retain deciding ownership and selection checks without redundant pre-action full censuses: \(f.wholeHeaderSelectionReads)")
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
    }

    @Test("A later header's custody loss discards earlier pairs and prohibits further selection",
          arguments: ["document", "strip_replacement", "playing", "cancel"])
    func laterWholeInspectionLossCannotPublishEarlierPairs(_ fault: String) async throws {
        let f = try Fixture(fourTracks: true)
        f.routingSelection = { index in
            if index == 2 {
                switch fault {
                case "document": f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                case "strip_replacement": f.builder.setChildren(f.mixer, [f.strips[0], f.strips[1], f.strips[2]])
                case "playing": f.builder.setAttribute(f.builder.element(1_965_721), kAXValueAttribute as String, 1)
                case "cancel": withUnsafeCurrentTask { $0?.cancel() }
                default: Issue.record("Unexpected fault")
                }
            }
        }
        let body = try await inspect(f)
        #expect(body["state"] as? String == "C")
        #expect(body["associations"] == nil)
        #expect(f.selections == [1, 2])
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String != "restored")
    }

    @Test("A fresh changed focus can prove an alias of the original strip without treating unchanged focus as proof")
    func wholeHeaderAliasOfOriginalHasAnIndependentFocusTransition() async throws {
        let f = try Fixture(fourTracks: true)
        f.thirdSharesOriginalStrip = true
        let cache = StateCache(), registry = TargetRegistry()
        let body = try await inspect(f, cache: cache, registry: registry)
        let rows = try #require((body["associations"] as? [String: Any])?["rows"] as? [[String: Any]])
        let original = try #require(rows.first { $0["track_index"] as? Int == 0 })
        let alias = try #require(rows.first { $0["track_index"] as? Int == 2 })
        #expect(original["mixer_strip_ref"] as? String == alias["mixer_strip_ref"] as? String)
        #expect(rows.count == 4 && f.selections == [1, 2, 3, 0])
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        let id = try #require(body["snapshot_id"] as? String)
        let retained = try #require(await cache.retainedInspection(id: id))
        let source = try #require(retained.capture.channelStrips[1].physicalBinding)
        let ref = try #require(retained.capture.mixerReference(at: 1))
        #expect(await cache.retainedMixerAssociation(reference: ref, source: source,
            snapshot: await registry.currentSnapshot) == nil,
            "An observed alias of the original strip must not acquire unique scalar actuation custody")
    }

    @Test("Returning an already focused strip proves restoration, not a new baseline association",
          arguments: [false, true])
    func finalChallengeAtOriginalFocusRequiresAnIndependentOriginalHeaderWitness(provedEarlier: Bool) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        f.thirdRetainsPreviousFocus = provedEarlier
        f.routingRead = { element, attribute in
            if f.selections.last == 3, CFEqual(element, f.app),
               attribute == kAXFocusedUIElementAttribute as String {
                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.strips[1])
            }
        }
        let body = try await inspect(f)
        let section = try #require(body["associations"] as? [String: Any])
        let rows = try #require(section["rows"] as? [[String: Any]])
        let expected: Set<Int> = provedEarlier ? [0, 1] : [1, 2, 3]
        #expect(Set(rows.compactMap { $0["track_index"] as? Int }) == expected)
        #expect(f.selections == (provedEarlier ? [1, 2, 0, 2, 3, 0] : [1, 2, 3, 0]))
        #expect(f.focusRestorationWrites.isEmpty)
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
    }

    @Test("Actual Mixer selected-child transitions can prove held pairs while keyboard focus stays elsewhere",
          arguments: [false, true])
    func mixerSelectedChildrenObservePairsWithoutInventingFocus(shared: Bool) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        let mapping = [0, 3, shared ? 3 : 1, 2]
        f.routingRead = { element, attribute in
            if CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String {
                f.builder.setAttribute(f.app, attribute, f.strips[1])
            }
            if CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String {
                f.builder.setAttribute(f.mixer, attribute, [f.strips[mapping[f.selections.last ?? 0]]])
            }
        }
        let body = try await inspect(f)
        let section = try #require(body["associations"] as? [String: Any])
        let rows = try #require(section["rows"] as? [[String: Any]])
        let strips = try #require((body["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
        #expect(rows.count == 4)
        for index in mapping.indices {
            let row = try #require(rows.first { $0["track_index"] as? Int == index })
            #expect(row["mixer_strip_ref"] as? String == strips[mapping[index]]["mixer_strip_ref"] as? String)
            #expect(row["source"] as? String == "held_exclusive_selection_selected_child")
        }
        #expect(f.focusRestorationWrites.isEmpty)
        #expect(f.selections == (shared ? [1, 2, 0, 2, 3, 0] : [1, 2, 3, 0]))
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        #expect(section["coverage"] as? String == "partial", "This does not certify global population")
    }

    @Test("Selection-scoped association uses a changed reciprocal Mixer child, not stationary keyboard focus",
          arguments: ["changed", "unchanged", "malformed", "retired"])
    func selectedScopeUsesTheActualMixerRelationshipWithoutChangingFocus(kind: String) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        let mapping = [0, 3, 1, 2]
        f.routingRead = { element, attribute in
            if CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String {
                f.builder.setAttribute(f.app, attribute, f.strips[1])
            }
            if CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String {
                f.selectedRelationshipReads += 1
                let selected = kind == "unchanged" ? 0 : mapping[f.selections.last ?? 0]
                f.builder.setAttribute(f.mixer, attribute,
                    kind == "malformed" ? [f.strips[0], f.strips[0]] : [f.strips[selected]])
                if kind == "retired", f.selections.last == 1 {
                    f.builder.setChildren(f.mixer, f.strips.filter { !CFEqual($0, f.strips[3]) })
                }
            }
        }
        let body = try await inspect(f, scope: "selection")
        #expect(f.selectedRelationshipReads > 0)
        let section = body["associations"] as? [String: Any] ?? [:]
        let rows = section["rows"] as? [[String: Any]] ?? []
        let effects = try #require(body["ui_effects"] as? [String: Any])
        #expect(f.focusRestorationWrites.isEmpty)
        if kind == "changed" {
            #expect(f.selections == [1, 0])
            #expect(effects["restoration"] as? String == "restored")
            #expect(rows.count == 1, "Actual registered capture: \(body)")
            let row = try #require(rows.first)
            let strips = try #require((body["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
            #expect(row["track_index"] as? Int == 0)
            #expect(row["mixer_strip_ref"] as? String == strips[0]["mixer_strip_ref"] as? String)
            #expect(row["source"] as? String == "held_exclusive_selection_selected_child")
        } else {
            #expect(rows.isEmpty)
            if kind == "malformed" { #expect(f.selections.isEmpty) }
            if kind == "unchanged" {
                #expect(f.selections == [1, 0])
                #expect(effects["restoration"] as? String == "restored")
            }
            if kind == "retired" { #expect(f.selections == [1]) }
        }
    }

    @Test("Selection-scoped challenge uses a captured non-stack CF instead of a coupled stack header",
          arguments: ["healthy", "unknown", "only_stacks", "late_stack", "late_cf"])
    func selectedScopeAvoidsCoupledStackChallenges(kind: String) async throws {
        let f = try Fixture(fourTracks: true)
        f.fault = "coupled_stack"
        f.builder.setAttribute(f.headers[0], kAXSelectedAttribute as String, false)
        f.builder.setAttribute(f.headers[1], kAXSelectedAttribute as String, true)
        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.strips[0])
        for index in [0, 2] {
            let disclosure = f.builder.element(1_965_880 + index)
            f.builder.setRole(disclosure, kAXDisclosureTriangleRole as String)
            f.builder.setAttribute(disclosure, kAXValueAttribute as String, NSNumber(value: 1))
            f.builder.setChildren(disclosure, [])
            f.builder.setChildren(f.headers[index], [disclosure])
        }
        let otherMetadata = f.builder.element(1_965_883)
        f.builder.setRole(otherMetadata, kind == "only_stacks" ? kAXDisclosureTriangleRole as String : kAXGroupRole as String)
        f.builder.setAttribute(otherMetadata, kAXValueAttribute as String, NSNumber(value: 1))
        f.builder.setChildren(otherMetadata, [])
        f.builder.setChildren(f.headers[3], [otherMetadata])
        let mapping = [1, 0, 3, 2]
        f.routingRead = { element, attribute in
            if CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String {
                if f.presentationCensusReads >= 2, !f.routingLateScopeInjected,
                   kind == "late_stack" || kind == "late_cf" {
                    f.routingLateScopeInjected = true
                    if kind == "late_stack" {
                        f.builder.setRole(otherMetadata, kAXDisclosureTriangleRole as String)
                    } else {
                        let replacement = f.builder.element(1_965_884)
                        f.builder.setRole(replacement, kAXLayoutItemRole as String)
                        f.builder.setAttribute(replacement, kAXTitleAttribute as String, "Duplicate")
                        f.builder.setAttribute(replacement, kAXSelectedAttribute as String, false)
                        f.builder.setChildren(replacement, [])
                        f.builder.setChildren(f.rail, [f.headers[0], f.headers[1], f.headers[2], replacement])
                    }
                }
                f.builder.setAttribute(f.app, attribute, f.strips[0])
            }
            if CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String {
                f.builder.setAttribute(f.mixer, attribute, [f.strips[mapping[f.selections.last ?? 1]]])
            }
        }
        if kind == "unknown" {
            f.routingReadResult = { element, attribute in
                if CFEqual(element, otherMetadata), attribute == kAXRoleAttribute as String {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                return nil
            }
        }
        let body = try await inspect(f, scope: "selection")
        let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
        if kind == "healthy" {
            #expect(f.selections == [3, 1], "The first header is an actual coupled stack, not a safe exclusive challenge")
            #expect(rows.count == 1, "Actual registered capture: \(body)")
            let row = try #require(rows.first)
            #expect(row["track_index"] as? Int == 1)
            #expect(row["source"] as? String == "held_exclusive_selection_selected_child")
            #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        } else {
            #expect(f.selections.isEmpty)
            #expect(rows.isEmpty)
            if kind.hasPrefix("late_") { #expect(f.routingLateScopeInjected) }
        }
        #expect(f.focusRestorationWrites.isEmpty)
    }

    @Test("Request-owned selected-child observation can enter from its exact nonediting rail without changing scalar entry",
          arguments: ["whole", "selection", "unchanged", "wrong_return"])
    func mixerSelectedChildrenCanEnterFromTheOriginalPassiveRail(profile: String) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        let whole = profile == "whole"
        let mapping = [0, 3, 1, 2]
        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
        f.routingRead = { element, attribute in
            if CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String {
                f.builder.setAttribute(f.app, attribute, f.rail)
            }
            if CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String {
                let index = profile == "unchanged" ? 0
                    : (profile == "wrong_return" && f.selections == [1, 0] ? 1 : f.selections.last ?? 0)
                f.builder.setAttribute(f.mixer, attribute, [f.strips[mapping[index]]])
            }
        }
        f.routingReadResult = { element, attribute in
            if CFEqual(element, f.rail), [kAXValueAttribute, kAXSelectedTextAttribute,
                kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute].map({ $0 as String }).contains(attribute) {
                return .failure(.init(raw: AXError.noValue.rawValue))
            }
            return nil
        }
        let body = try await inspect(f, scope: whole ? "whole_project" : "selection")
        let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
        #expect(rows.count == (whole ? 4 : profile == "selection" ? 1 : 0),
            "Only a changed-strip challenge and exact original return establish the selected source pair")
        if !rows.isEmpty {
            let stripRows = try #require((body["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
            for index in (whole ? Array(mapping.indices) : [0]) {
                let row = try #require(rows.first { $0["track_index"] as? Int == index })
                #expect(row["mixer_strip_ref"] as? String == stripRows[mapping[index]]["mixer_strip_ref"] as? String)
                #expect(row["source"] as? String == "held_exclusive_selection_selected_child")
            }
            #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        }
        #expect(f.selections == (whole ? [1, 2, 3, 0] : [1, 0]))
        #expect(f.focusRestorationWrites.isEmpty)
    }

    @Test("Passive rail entry refuses editing, unknown metadata and lost exact custody before navigation",
          arguments: ["text_role", "settable", "zero_insertion", "unreadable", "nil_metadata", "foreign_focus", "detached_rail", "retired_strip", "foreign_document", "missing_relationship"],
          ["whole_project", "selection"])
    func passiveRailSelectedChildEntryMustRetainExactNoneditingCustody(fault: String, scope: String) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        let mapping = [0, 3, 1, 2]
        let foreign = f.builder.element(1_965_998)
        f.builder.setRole(foreign, kAXGroupRole as String)
        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
        if fault == "text_role" { f.builder.setRole(f.rail, kAXTextFieldRole as String) }
        if fault == "settable" { f.builder.setAttributeSettable(f.rail, kAXValueAttribute as String, true) }
        f.routingRead = { element, attribute in
            if CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String {
                f.builder.setAttribute(f.app, attribute, fault == "foreign_focus" ? foreign : f.rail)
            }
            if CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String {
                f.selectedChildrenReads += 1
                f.builder.setAttribute(f.mixer, attribute, [f.strips[mapping[f.selections.last ?? 0]]])
                if fault == "detached_rail" { f.builder.setChildren(f.window, [f.mixer]) }
                if fault == "retired_strip" { f.builder.setChildren(f.mixer, Array(f.strips.dropFirst())) }
            }
        }
        f.routingReadResult = { element, attribute in
            if CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String,
               fault == "missing_relationship" { return .failure(.init(raw: AXError.noValue.rawValue)) }
            if CFEqual(element, f.rail), [kAXValueAttribute, kAXSelectedTextAttribute,
                kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute].map({ $0 as String }).contains(attribute) {
                if fault == "foreign_document" {
                    // Switch after the association has captured its original
                    // document, at the new rail-focus qualification itself.
                    f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                }
                if fault == "zero_insertion", attribute == kAXInsertionPointLineNumberAttribute as String {
                    return .success(NSNumber(value: 0))
                }
                if fault == "unreadable" { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
                if fault == "nil_metadata" { return .success(nil) }
                return .failure(.init(raw: AXError.noValue.rawValue))
            }
            return nil
        }
        let body = try await inspect(f, scope: scope)
        let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
        #expect(rows.isEmpty)
        #expect(f.selections.isEmpty, "An unknown/editor/foreign rail must not authorize a selection")
        #expect(f.focusRestorationWrites.isEmpty)
    }

    @Test("The final passive rail metadata read cannot authorize a retired selected strip")
    func passiveRailFinalMetadataMustRenewSelectedStripCustody() async throws {
        func fixture(injectAt: Int?) throws -> Fixture {
            let f = try Fixture(withViewport: true, fourTracks: true)
            let mapping = [0, 3, 1, 2]
            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
            f.routingRead = { element, attribute in
                if CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String {
                    f.builder.setAttribute(f.app, attribute, f.rail)
                }
                if CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String {
                    f.builder.setAttribute(f.mixer, attribute, [f.strips[mapping[f.selections.last ?? 0]]])
                }
            }
            f.routingReadResult = { element, attribute in
                if CFEqual(element, f.rail), [kAXValueAttribute, kAXSelectedTextAttribute,
                    kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute].map({ $0 as String }).contains(attribute) {
                    if attribute == kAXInsertionPointLineNumberAttribute as String {
                        f.cleanupTransportReads += 1
                        if f.selections.isEmpty, f.cleanupTransportReads == injectAt {
                            f.cleanupScopeInjected = true
                            // A retired AX child can retain its old parent and
                            // the Mixer's old selected-child attribute.
                            f.builder.setChildren(f.mixer, Array(f.strips.dropFirst()))
                        }
                    }
                    return .failure(.init(raw: AXError.noValue.rawValue))
                }
                return nil
            }
            f.routingSelection = { index in
                if index == 1, f.selections == [1] { f.cleanupTransportReadsAtWrite = f.cleanupTransportReads }
            }
            return f
        }
        let calibration = try fixture(injectAt: nil)
        let positive = try await inspect(calibration)
        #expect(((positive["associations"] as? [String: Any])?["rows"] as? [[String: Any]])?.count == 4)
        #expect(calibration.cleanupTransportReadsAtWrite > 0)
        let f = try fixture(injectAt: calibration.cleanupTransportReadsAtWrite)
        let body = try await inspect(f)
        #expect(f.cleanupScopeInjected, "Reach the actual final metadata read before the first action")
        #expect(f.selections.isEmpty, "A deciding rail metadata read must not authorize a retired selected strip")
        #expect(((body["associations"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []).isEmpty)
        #expect(f.focusRestorationWrites.isEmpty)
    }

    @Test("The deciding selected-child read cannot outlive reference, editor, document or strip custody",
          arguments: ["reference", "document", "editor", "same_focus_editor", "retired_strip"])
    func mixerSelectedChildDecidingReadMustRemainOwned(fault: String) async throws {
        func observe(_ f: Fixture) async throws -> SessionPopulationObservation.FreshPopulation {
            let gate = LogicMutationGate()
            let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
            defer { gate.release(claim) }
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
            return try await OperationTraceContext.$current.withValue(context) {
                try await f.channel().readFreshSessionPopulation(
                    request: .init(domains: [.tracks, .strips, .associations], allowUINavigation: true),
                    fileReader: .unavailable,
                    navigationReferenceIsCurrent: { f.referenceCurrent }, stoppingWhen: { false })
            }
        }
        func fixture(injectAt: Int?) throws -> Fixture {
            let f = try Fixture(withViewport: true, fourTracks: true)
            let mapping = [0, 3, 1, 2]
            f.routingRead = { element, attribute in
                if CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String {
                    if !f.cleanupScopeInjected || fault != "editor" {
                        f.builder.setAttribute(f.app, attribute, f.strips[1])
                    }
                }
                if CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String {
                    f.selectedChildrenReads += 1
                    f.builder.setAttribute(f.mixer, attribute, [f.strips[mapping[f.selections.last ?? 0]]])
                    if f.selections.isEmpty, f.selectedChildrenReads == injectAt {
                        f.cleanupScopeInjected = true
                        switch fault {
                        case "reference": f.referenceCurrent = false
                        case "document": f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        case "editor":
                            let editor = f.builder.element(1_965_995)
                            f.builder.setRole(editor, kAXTextFieldRole as String)
                            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, editor)
                        case "same_focus_editor":
                            f.builder.setAttribute(f.strips[1], kAXNumberOfCharactersAttribute as String, 1)
                        case "retired_strip": f.builder.setChildren(f.mixer, f.strips.filter { !CFEqual($0, f.strips[0]) })
                        default: Issue.record("Unexpected fault")
                        }
                    }
                }
            }
            f.routingSelection = { index in
                if index == 1, f.selections == [1] { f.selectedChildrenReadsAtWrite = f.selectedChildrenReads }
            }
            return f
        }
        let calibration = try fixture(injectAt: nil)
        let positive = try await observe(calibration)
        #expect(positive.selectionAssociations.count == 4)
        #expect(calibration.selectedChildrenReadsAtWrite > 0)
        let f = try fixture(injectAt: calibration.selectedChildrenReadsAtWrite)
        let body = try await observe(f)
        #expect(f.cleanupScopeInjected)
        #expect(f.selections.isEmpty, "Lost custody at the actual deciding relationship read must prevent the first selection")
        #expect(body.selectionAssociations.isEmpty)
        #expect(f.focusRestorationWrites.isEmpty)
    }

    @Test("A focus-reading stop callback must precede the final selected-child action proof",
          arguments: ["reference", "document", "editor", "retired_strip"])
    func mixerSelectedChildStopReadCannotInvalidateTheFinalActionProof(fault: String) async throws {
        func observe(_ f: Fixture, injectAt: Int?) async throws -> SessionPopulationObservation.FreshPopulation {
            let gate = LogicMutationGate()
            let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
            defer { gate.release(claim) }
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
            return try await OperationTraceContext.$current.withValue(context) {
                try await f.channel().readFreshSessionPopulation(
                    request: .init(domains: [.tracks, .strips, .associations], allowUINavigation: true),
                    fileReader: .unavailable, navigationReferenceIsCurrent: { f.referenceCurrent },
                    stoppingWhen: {
                        f.associationStopReads += 1
                        if f.selections.isEmpty, f.associationStopReads == injectAt {
                            f.cleanupScopeInjected = true
                            switch fault {
                            case "reference": f.referenceCurrent = false
                            case "document": f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            case "editor":
                                let editor = f.builder.element(1_965_997)
                                f.builder.setRole(editor, kAXTextFieldRole as String)
                                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, editor)
                            case "retired_strip": f.builder.setChildren(f.mixer, f.strips.filter { !CFEqual($0, f.strips[0]) })
                            default: Issue.record("Unexpected fault")
                            }
                        }
                        return false
                    })
            }
        }
        func fixture() throws -> Fixture {
            let f = try Fixture(withViewport: true, fourTracks: true)
            f.routingRead = { element, attribute in
                if CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String {
                    f.builder.setAttribute(f.mixer, attribute, [f.strips[f.selections.last ?? 0]])
                }
            }
            f.routingSelection = { index in
                if index == 1, f.selections == [1] { f.associationStopReadsAtWrite = f.associationStopReads }
            }
            return f
        }
        let calibration = try fixture()
        #expect(try await observe(calibration, injectAt: nil).selectionAssociations.count == 4)
        #expect(calibration.associationStopReadsAtWrite > 0)
        let f = try fixture()
        let body = try await observe(f, injectAt: calibration.associationStopReadsAtWrite)
        #expect(f.cleanupScopeInjected)
        #expect(f.selections.isEmpty)
        #expect(body.selectionAssociations.isEmpty)
        #expect(f.focusRestorationWrites.isEmpty)
    }

    @Test("Malformed or lost Mixer selected-child relationships cannot fall back to keyboard focus",
          arguments: ["malformed", "non_element", "empty", "multiple", "foreign", "wrong_parent", "unreadable", "lost_after_selection"])
    func mixerSelectedChildMustBeOneActualReciprocalHeldElement(fault: String) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        if fault == "unreadable" { f.fault = "selected_child_unreadable" }
        f.routingRead = { element, attribute in
            guard CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String else { return }
            f.selectedChildrenReads += 1
            let selected = f.strips[f.selections.last ?? 0]
            switch fault {
            case "malformed": f.builder.setAttribute(f.mixer, attribute, "not an array")
            case "non_element": f.builder.setAttribute(f.mixer, attribute, ["not an AX element"])
            case "empty": f.builder.setAttribute(f.mixer, attribute, [AXUIElement]())
            case "multiple": f.builder.setAttribute(f.mixer, attribute, [f.strips[0], f.strips[1]])
            case "foreign": f.builder.setAttribute(f.mixer, attribute, [f.builder.element(1_965_996)])
            case "wrong_parent":
                f.builder.setAttribute(selected, kAXParentAttribute as String, f.builder.element(1_965_996))
                f.builder.setAttribute(f.mixer, attribute, [selected])
            case "lost_after_selection":
                f.builder.setAttribute(f.mixer, attribute, f.selections.isEmpty ? [selected] : [AXUIElement]())
            default: break
            }
        }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let body = try await OperationTraceContext.$current.withValue(context) {
            try await f.channel().readFreshSessionPopulation(
                request: .init(domains: [.tracks, .strips, .associations], allowUINavigation: true),
                fileReader: .unavailable, stoppingWhen: { false })
        }
        #expect(body.selectionAssociations.isEmpty)
        #expect(f.selectedChildrenReads > 0)
        #expect(f.selections == (fault == "lost_after_selection" ? [1] : []))
        #expect(f.focusRestorationWrites.isEmpty)
    }

    @Test("A header with unchanged focus remains unknown without discarding other independently proved pairs")
    func anUnprovedHeaderDoesNotInventAnAliasOrPoisonOtherProofs() async throws {
        let f = try Fixture(fourTracks: true)
        f.thirdRetainsPreviousFocus = true
        let body = try await inspect(f)
        let section = try #require(body["associations"] as? [String: Any])
        let rows = try #require(section["rows"] as? [[String: Any]])
        #expect(Set(rows.compactMap { $0["track_index"] as? Int }) == [0, 1, 3])
        #expect(f.selections == [1, 2, 0, 2, 3, 0])
        #expect(section["coverage"] as? String == "partial")
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
    }

    @Test func aQualifiedAssociationReusesItsFreshPopulationPresentationBookends() async throws {
        let f = try Fixture()
        let body = try await inspect(f)
        let rows = try #require((body["associations"] as? [String: Any])?["rows"] as? [[String: Any]])
        #expect(rows.count == 2 && f.selections == [1, 0])
        #expect(f.presentationCensusReads == 4, "Initial and restored populations already independently read the Mixer twice each; no separate view baseline is needed")
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
    }

    @Test func reusedPresentationCannotIgnoreTransportChangingAfterSelectionRestoration() async throws {
        let f = try Fixture()
        f.routingRead = { element, attribute in
            if f.selections == [1, 0], CFEqual(element, f.window), attribute == kAXHelpAttribute as String {
                f.builder.setAttribute(f.builder.element(1_965_721), kAXValueAttribute as String, 1)
            }
        }
        let body = try await inspect(f)
        #expect(f.selections == [1, 0])
        #expect(body["state"] as? String == "C" && body["associations"] == nil)
    }

    @Test(arguments: [false, true])
    func selectionInducedViewportDriftRestoresOnlyItsOriginalControl(bulk: Bool) async throws {
        let f = try Fixture(withViewport: true)
        f.useBulkReads = bulk
        f.fault = "selection_scroll"
        let body = try await inspect(f)
        #expect(f.selections == [1, 0])
        #expect(f.scrollWrites == [0.8], "restore the exact held scrollbar, not a new matching control")
        #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.8)
        #expect((body["associations"] as? [String: Any])?["rows"] as? [[String: Any]] != nil)
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        #expect(bulk ? f.batchReadCalls > 0 : f.batchReadCalls == 0)
        #expect(bulk ? f.reciprocalPathBatchCalls > 0 : f.reciprocalPathBatchCalls == 0)
    }

    @Test(arguments: ["Vertical Zoom", "수직 확대/축소"], [false, true])
    func selectionInducedZoomDriftCannotClaimRestoration(label: String, noEffect: Bool) async throws {
        let f = try Fixture(withViewport: true)
        f.useBulkReads = true
        f.builder.setRole(f.scroll, kAXSliderRole as String)
        f.builder.setAttribute(f.scroll, kAXDescriptionAttribute as String, label)
        f.fault = noEffect ? "scroll_no_effect" : "selection_scroll"
        let body = try await inspect(f)
        #expect(f.selections == [1, 0])
        #expect(f.scrollWrites == [0.8], "selection-owned zoom drift requires the original physical control's inverse")
        let restoration = try #require((body["ui_effects"] as? [String: Any])?["restoration"] as? String)
        if noEffect {
            #expect(restoration != "restored", "a successful AX write without exact zoom readback is not restoration")
            #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.1)
        } else {
            #expect(restoration == "restored")
            #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.8)
        }
    }

    @Test(arguments: ["Volume", "Pan", "Zoom", "Vertical Zoom calibration"])
    func viewportInverseCannotUseAnUnrelatedSliderDescription(label: String) async throws {
        let f = try Fixture(withViewport: true)
        f.builder.setRole(f.scroll, kAXSliderRole as String)
        f.builder.setAttribute(f.scroll, kAXDescriptionAttribute as String, label)
        f.fault = "selection_scroll"
        _ = try await inspect(f)
        #expect(f.selections == [1, 0])
        #expect(f.scrollWrites.isEmpty, "neither generic zoom containment nor a musical slider authorizes a viewport write")
        #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.1)
    }

    @Test func malformedZoomDescriptionCannotBeTreatedAsAbsent() async throws {
        let f = try Fixture(withViewport: true)
        f.builder.setRole(f.scroll, kAXSliderRole as String)
        f.builder.setAttribute(f.scroll, kAXDescriptionAttribute as String, NSNumber(value: 42))
        f.fault = "selection_scroll"
        _ = try await inspect(f)
        #expect(f.selections.isEmpty, "a malformed successful description is not proof that an owned viewport control is absent")
        #expect(f.scrollWrites.isEmpty)
        #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.8)
    }

    @Test func anUnrelatedInspectorSliderCannotPreventOriginalZoomRestoration() async throws {
        let f = try Fixture(withViewport: true)
        f.builder.setRole(f.scroll, kAXSliderRole as String)
        f.builder.setAttribute(f.scroll, kAXDescriptionAttribute as String, "Vertical Zoom")
        let unrelated = f.builder.element(1_965_780)
        f.builder.setRole(unrelated, kAXSliderRole as String)
        f.builder.setAttribute(unrelated, kAXDescriptionAttribute as String, "Gain")
        f.builder.setChildren(unrelated, [])
        f.builder.setChildren(f.window, [f.rail, f.mixer, f.builder.element(1_965_720), f.scroll, unrelated])
        f.volatileSlider = unrelated
        f.fault = "selection_scroll"
        let body = try await inspect(f)
        #expect(f.selections == [1, 0], "do not abandon the owned selection because a non-viewport Inspector slider was redrawn")
        #expect(f.scrollWrites == [0.8])
        #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.8)
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
    }

    @Test func aSampledOriginalZoomRoleContradictionCannotBeRenewedAway() async throws {
        let calibration = try Fixture(withViewport: true)
        calibration.builder.setRole(calibration.scroll, kAXSliderRole as String)
        calibration.builder.setAttribute(calibration.scroll, kAXDescriptionAttribute as String, "Vertical Zoom")
        calibration.fault = "selection_scroll"
        _ = try await inspect(calibration)
        let firstValueRoleReads = try #require(calibration.zoomRoleReadsAtFirstValue)
        #expect(firstValueRoleReads >= 2)
        let f = try Fixture(withViewport: true)
        f.builder.setRole(f.scroll, kAXSliderRole as String)
        f.builder.setAttribute(f.scroll, kAXDescriptionAttribute as String, "Vertical Zoom")
        f.fault = "selection_scroll"
        // The last role read before this viewport value is the direct held
        // role check; the preceding read is its fresh complete census sample.
        f.zoomRoleFaultAtRead = firstValueRoleReads - 1
        let body = try await inspect(f)
        #expect(f.transientZoomRoleObserved)
        #expect(f.selections == [1])
        #expect(f.scrollWrites.isEmpty)
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored")
    }

    @Test(arguments: ["unreadable", "malformed_children", "foreign_children", "malformed_parent"])
    func aFailedFreshReciprocalPathBatchCannotAuthorizeSelection(fault: String) async throws {
        let f = try Fixture()
        f.useBulkReads = true
        f.pathBatchFault = fault
        let body = try await inspect(f)
        #expect(f.reciprocalPathBatchCalls > 0, "exercise the original intermediate transport parent")
        #expect(f.selections.isEmpty, "do not reconstruct a failed physical reciprocal path")
        let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]]
        #expect((rows ?? []).isEmpty, "no physical pairs without the original reciprocal path")
    }

    @Test(arguments: ["scroll_document", "scroll_focus", "scroll_replacement", "scroll_newer", "scroll_playback", "scroll_cancel"], [false, true])
    func decidingViewportLossCannotAuthorizeItsInverse(fault: String, bulk: Bool) async throws {
        let calibration = try Fixture(withViewport: true)
        calibration.useBulkReads = bulk
        calibration.fault = "selection_scroll"
        _ = try await inspect(calibration)
        #expect(calibration.scrollWrites == [0.8])
        let f = try Fixture(withViewport: true)
        f.useBulkReads = bulk
        f.fault = fault
        f.viewportFaultAtRead = calibration.inverseValueReadCount
        let body = try await inspect(f)
        #expect(f.viewportFaultInjected, "exercise the actual last deciding viewport-value read")
        #expect(f.selections == [1, 0])
        #expect(f.scrollWrites.isEmpty, "do not overwrite a newer view or act through lost control/document/focus custody")
        #expect(body["associations"] == nil)
        #expect(body["state"] as? String == "C")
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored")
    }

    @Test func scrollbarAckWithoutReadbackDoesNotClaimRestoration() async throws {
        let f = try Fixture(withViewport: true)
        f.fault = "scroll_no_effect"
        let body = try await inspect(f)
        #expect(f.scrollWrites == [0.8])
        #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.1)
        #expect(body["associations"] == nil)
        #expect(body["state"] as? String == "C")
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored")
    }

    @Test func unwriteableOriginalScrollbarCannotAuthorizeAnInverse() async throws {
        let f = try Fixture(withViewport: true)
        f.fault = "selection_scroll"
        f.builder.setAttributeSettable(f.scroll, kAXValueAttribute as String, false)
        let body = try await inspect(f)
        #expect(f.selections == [1, 0])
        #expect(f.scrollWrites.isEmpty)
        #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.1)
        #expect(body["associations"] == nil)
        #expect(body["state"] as? String == "C")
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored")
    }

    @Test func decidingViewportReferenceRetirementCannotAuthorizeAnInverse() async throws {
        func observe(_ f: Fixture) async throws -> SessionPopulationObservation.FreshPopulation {
            let gate = LogicMutationGate()
            let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
            defer { gate.release(claim) }
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
            return try await OperationTraceContext.$current.withValue(context) {
                try await f.channel().readFreshSessionPopulation(
                    request: .init(domains: [.tracks, .strips, .associations], allowUINavigation: true),
                    fileReader: .unavailable,
                    navigationReferenceIsCurrent: { f.referenceCurrent }, stoppingWhen: { false })
            }
        }
        let calibration = try Fixture(withViewport: true)
        calibration.fault = "selection_scroll"
        let positive = try await observe(calibration)
        #expect(calibration.scrollWrites == [0.8])
        #expect(positive.selectionAssociations.count == 2)
        let f = try Fixture(withViewport: true)
        f.fault = "scroll_reference"
        f.viewportFaultAtRead = calibration.inverseValueReadCount
        let refused = try await observe(f)
        #expect(f.viewportFaultInjected && !f.referenceCurrent)
        #expect(f.selections == [1, 0], "all physical custody remains unchanged at reference retirement")
        #expect(f.scrollWrites.isEmpty, "renew the request's current-reference authority after deciding AX reads")
        #expect(refused.selectionAssociations.isEmpty)
        #expect(refused.uiEffects.restoration == "not_restored")
    }

    @Test(arguments: ["post_restore_selection_missing", "post_restore_selection_malformed"])
    func restoredPopulationCannotLoseOriginalSelectionReadback(fault: String) async throws {
        let f = try Fixture()
        f.fault = fault
        let body = try await inspect(f)
        #expect(f.selections == [1, 0], "the physical challenge and restoration must actually run")
        #expect(f.postRestoreSelectionFaults == 3, "Both restored-population bookends and final held ownership still consume the fault; the redundant view baseline is gone")
        #expect(body["associations"] == nil, "do not retain pairs after initial-vs-restored selection provenance changes")
        #expect(body["state"] as? String == "C")
        #expect(body["error"] as? String == "stale_snapshot")
        #expect((body["ui_effects"] as? [String: Any])?["reason"] as? String == "association_population_moved")
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
    }

    @Test(arguments: ["header_name", "strip_name"])
    func decidingSelectionCannotPublishEarlierPresentation(fault: String) async throws {
        let f = try Fixture()
        f.fault = fault
        let body = try await inspect(f)
        #expect(f.selections == [1, 0], "the physical selection and restoration must actually run")
        #expect(body["associations"] == nil)
        #expect(body["state"] as? String == "C")
        #expect(body["error"] as? String == "stale_snapshot")
        let navigationPerformed = try #require(body["navigation_performed"] as? Bool)
        #expect(navigationPerformed)
        #expect((body["ui_effects"] as? [String: Any])?["reason"] as? String == "association_population_moved")
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
    }

    @Test func aCurrentReferenceForAnotherLiveDocumentDoesNotSelect() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture(), registry = TargetRegistry()
            let snapshot = await registry.currentSnapshot
            let descriptor = TargetDescriptor.project(name: "Other", filePath: "/tmp/Other.logicx", epoch: snapshot.projectEpoch)
            let reference = try #require(await registry.bind(kind: .project, descriptor: descriptor,
                fingerprint: descriptor.fingerprint, snapshot: snapshot))
            let body = try await inspect(f, registry: registry, projectRef: reference.rawValue)
            #expect(f.selections.isEmpty, "a registry-current reference must also match the actual held native document before UI writes")
            #expect(body["state"] as? String == "C")
            #expect(body["associations"] == nil)
        }
    }

    @Test(arguments: ["final_focus_document", "final_focus_window"], [0, 1])
    func finalDecidingFocusCannotMoveScopeBeforeForwardOrCleanupWrite(fault: String, phase: Int) async throws {
        let calibration = try Fixture()
        let positive = try await inspect(calibration)
        #expect((positive["associations"] as? [String: Any])?["rows"] != nil)
        let f = try Fixture()
        f.fault = fault
        f.scopeLossPhase = phase
        f.scopeLossRead = calibration.focusReadsBeforeWrite[phase]
        let body = try await inspect(f)
        #expect(f.scopeLossInjected, "exercise the actual final deciding focus read, not an earlier proxy")
        #expect(f.selections == (phase == 0 ? [] : [1]), "R965-ASSOC-C001: no write after the final focus read moved document/window scope")
        #expect(body["associations"] == nil)
        #expect(body["state"] as? String == "C")
    }

    @Test func navigationOptOutCannotSelectOrInventPairs() async throws {
        let f = try Fixture()
        let body = try await inspect(f, navigation: false)
        let section = try #require(body["associations"] as? [String: Any])
        #expect(section["rows"] == nil)
        #expect(section["coverage"] as? String == "unavailable")
        #expect(f.selections.isEmpty)
    }

    @Test(arguments: [-1.0, 2.0, 0.9, Double.nan, Double.infinity, -Double.infinity])
    func malformedSelectedValueCannotAuthorizeAssociationNavigation(value: Double) async throws {
        let f = try Fixture()
        f.builder.setAttribute(f.headers[0], kAXSelectedAttribute as String, NSNumber(value: value))
        let body = try await inspect(f)
        #expect(f.selections.isEmpty, "an unread selection cannot authorize a forward or restoration write")
        let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]]
        #expect(rows == nil, "non-Boolean numeric selection is not physical association evidence")
    }

    @Test(arguments: ["foreign_focus", "transient_foreign_focus", "document", "header_replacement", "strip_replacement", "playback", "transient_editor"], [false, true])
    func observedCustodyLossCannotAuthorizeAnotherSelection(fault: String, bulk: Bool) async throws {
        let f = try Fixture()
        f.useBulkReads = bulk
        f.fault = fault
        let body = try await inspect(f)
        #expect(f.selections == [1], "never rebind a replacement or overwrite a sampled foreign/editor state")
        #expect(body["associations"] == nil)
        #expect(body["state"] as? String == "C")
        if fault == "transient_foreign_focus" { #expect(f.transientForeignRead, "the actual optional focus-read seam must be exercised") }
        if fault == "foreign_focus" {
            #expect((body["ui_effects"] as? [String: Any])?["changed"] as? [String] == ["track_selection"],
                    "a deciding read observed actual selection even though its focus could not qualify a pair")
        }
    }

    @Test(arguments: ["no_op", "restore_foreign_focus"])
    func anAckWithoutACompleteRoundtripCannotPublishPairs(fault: String) async throws {
        let f = try Fixture()
        f.fault = fault
        let body = try await inspect(f)
        #expect(f.selections == (fault == "no_op" ? [1] : [1, 0]))
        #expect(body["associations"] == nil)
        #expect(body["state"] as? String == "C")
    }

    @Test(arguments: ["before_final_read", "during_final_read", "project_epoch", "occlusion"])
    func restoredSelectionStartsAFreshReadWithoutIgnoringItsBoundary(fault: String) async throws {
        let f = try Fixture(), cache = StateCache()
        let metadata = try PropertyListSerialization.data(fromPropertyList: ["NumberOfTracks": 2], format: .xml, options: 0)
        let fileReader = LogicProjectFileReader.Runtime(currentDocumentPath: { nil }, now: Date.init,
            readPlistData: { _ in metadata }, mtime: { _ in
                f.metadataReads += 1
                return Date(timeIntervalSince1970: Double(f.metadataReads % 2))
            }, sleep: { _ in
                // An actual awaited metadata retry deterministically delivers the
                // cache echo. No timed Task, sleep or synthetic boundary callback.
                if fault == "before_final_read", f.selections.isEmpty {
                    await cache.updateFader(strip: 0, volume: 0.5)
                } else if fault == "during_final_read", f.selections.count == 2 {
                    await cache.updateFader(strip: 0, volume: 0.5)
                } else if fault == "project_epoch", f.selections.isEmpty {
                    await cache.advanceProjectEpoch()
                } else if fault == "occlusion", f.selections.isEmpty {
                    await cache.updateAXOccluded(true); await cache.updateAXOccluded(false)
                }
            })
        let body = try await inspect(f, cache: cache, fileReader: fileReader)
        #expect(f.selections == [1, 0])
        if fault == "before_final_read" {
            let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]]
            #expect(rows?.count == 2, "accept only a new full post-restoration read, never the earlier cache boundary")
            #expect(await cache.sectionRevision(.mixer) > 0, "the cache echo must actually occur")
        } else {
            #expect(body["associations"] == nil)
            #expect(body["state"] as? String == "C", "new read revision, project epoch and occlusion losses remain blocking")
        }
    }
}
