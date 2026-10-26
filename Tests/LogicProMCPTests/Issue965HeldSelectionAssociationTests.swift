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
    let observedOperation: @Sendable (String) -> Void
    let observedResult: @Sendable (ChannelResult) -> Void
    init(base: AccessibilityChannel, journal: SagaJournal, mode: String,
         operation: String = "mixer.set_send_output_verified", idempotencyKey: String = "owned-send-removal-saga",
         afterForward: @escaping @Sendable () -> Void = {},
         beforeForward: @escaping @Sendable () -> Void = {},
         observedOperation: @escaping @Sendable (String) -> Void = { _ in },
         observedResult: @escaping @Sendable (ChannelResult) -> Void = { _ in }) {
        self.base = base; self.journal = journal; self.mode = mode; self.afterForward = afterForward
        self.operation = operation; self.idempotencyKey = idempotencyKey
        self.beforeForward = beforeForward
        self.observedOperation = observedOperation
        self.observedResult = observedResult
    }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { await base.healthCheck() }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        observedOperation(operation)
        if operation == self.operation { beforeForward() }
        if operation == self.operation, mode == "no_observer" {
            return .success(HonestContract.encodeStateA(extras: ["verified": true, "write_attempted": true]))
        }
        let result: ChannelResult
        if operation == self.operation, mode == "lost_observer" {
            if operation == "mixer.set_input_bus_verified" {
                result = await AccessibilityChannel.$inputChangeObserver.withValue(nil) {
                    await base.execute(operation: operation, params: params)
                }
            } else if operation == "mixer.set_send_level_verified" {
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
    @Test func heldWindowMembershipRejectsNonAXMembers() throws {
        let f = try Fixture(), gate = LogicMutationGate()
        f.useBulkReads = true
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let applicationAttributes = [kAXFrontmostAttribute, kAXWindowsAttribute,
            kAXMainWindowAttribute, kAXFocusedWindowAttribute] as [String]
        f.routingReadResult = { element, attribute in
            guard f.routingLateScopeInjected, CFEqual(element, f.app), attribute == kAXWindowsAttribute as String,
                  f.activeBulkAttributes == applicationAttributes else { return nil }
            return .success(NSArray(array: [f.window as AnyObject, NSNumber(value: 7)]))
        }
        let claim = try #require(gate.tryAcquire(operation: "typed-held-window-census"))
        defer { gate.release(claim) }
        try OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true,
            ownsGate: { gate.stillOwns(claim) })) {
            let held = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: f.logic(), expectedProject: nil, requiresProjectReference: false))
            #expect(held.permitsRead())
            f.routingLateScopeInjected = true
            #expect(!held.permitsRead(), "Known main/focused handles do not make a malformed window census complete")
            f.routingLateScopeInjected = false
            #expect(!held.permitsRead(), "A later valid window census cannot revive lost custody")
            #expect(f.selections.isEmpty && f.focusRestorationWrites.isEmpty)
        }
    }

    @Test(arguments: ["bar", "window", "record_branch"], [false, true])
    func transportParentCensusRejectsNonAXMembers(parent: String, bulk: Bool) throws {
        let f = try Fixture(), gate = LogicMutationGate()
        f.useBulkReads = true
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let bar = f.builder.element(1_965_720), record = f.builder.element(1_965_722)
        let wrapper = f.builder.element(1_971_904)
        if parent == "record_branch" {
            f.builder.setRole(wrapper, kAXGroupRole as String)
            f.builder.setChildren(wrapper, [record])
            f.builder.setChildren(bar, [f.builder.element(1_965_721), wrapper])
        }
        let corruptedParent = parent == "window" ? f.window : parent == "bar" ? bar : wrapper
        let claim = try #require(gate.tryAcquire(operation: "typed-transport-parent-census"))
        defer { gate.release(claim) }
        try OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true,
            ownsGate: { gate.stillOwns(claim) })) {
            let base = f.logic()
            let held = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: base, expectedProject: nil, requiresProjectReference: false))
            let rawChildren: @Sendable () -> AnyObject = {
                NSArray(array: f.builder.makeAXRuntime().children(corruptedParent).map { $0 as AnyObject }
                    + [NSNumber(value: 7)])
            }
            let bulkRead = try #require(base.ax.attributeValuesResult)
            let mixedBulkRead: @Sendable (AXUIElement, [String]) -> Result<[AnyObject], AXHelpers.AXStatusError> = { element, attributes in
                let reading = bulkRead(element, attributes)
                guard f.routingLateScopeInjected, CFEqual(element, corruptedParent),
                      let index = attributes.firstIndex(of: kAXChildrenAttribute as String) else { return reading }
                return reading.map { original in
                    var changed = original; changed[index] = rawChildren(); return changed
                }
            }
            let ax = AXHelpers.Runtime(axApp: base.ax.axApp, attributeValue: base.ax.attributeValue,
                attributeIsSettable: base.ax.attributeIsSettable, setAttributeValue: base.ax.setAttributeValue,
                children: base.ax.children, performAction: base.ax.performAction, childCount: base.ax.childCount,
                actionNames: base.ax.actionNames, childrenResult: { element in
                    if f.routingLateScopeInjected, CFEqual(element, corruptedParent) {
                        return AXHelpers.projectChildrenStatus(.success, rawChildren())
                    }
                    return AXHelpers.childrenResult(element, runtime: base.ax)
                }, attributeValueResult: base.ax.attributeValueResult,
                attributeValuesResult: bulk ? mixedBulkRead : nil)
            let runtime = AXLogicProElements.Runtime(logicProPID: base.logicProPID, ax: ax,
                executeAppleScript: base.executeAppleScript, onScreenWindowList: base.onScreenWindowList,
                postPopupMenuEscape: base.postPopupMenuEscape, focusedApplicationPID: base.focusedApplicationPID)
            #expect(AccessibilityChannel.HeldSelectionAssociation.stoppedTransportPathsMatch(
                held.transportPaths, activity: held.transport, window: f.window, logic: runtime))
            f.routingLateScopeInjected = true
            #expect(!AccessibilityChannel.HeldSelectionAssociation.stoppedTransportPathsMatch(
                held.transportPaths, activity: held.transport, window: f.window, logic: runtime),
                "Expected native children plus a non-AX member is an unreadable census in either path")
            #expect(f.selections.isEmpty && f.focusRestorationWrites.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func aSharedTransportAncestorIsReadAfterItsSeparateChildBranch(bulk: Bool) throws {
        let f = try Fixture(), gate = LogicMutationGate()
        f.useBulkReads = bulk
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let bar = f.builder.element(1_965_720), play = f.builder.element(1_965_721)
        let record = f.builder.element(1_965_722), wrapper = f.builder.element(1_971_903)
        f.builder.setRole(wrapper, kAXGroupRole as String)
        f.builder.setChildren(wrapper, [record])
        f.builder.setChildren(bar, [play, wrapper])
        let claim = try #require(gate.tryAcquire(operation: "branched-native-transport"))
        defer { gate.release(claim) }
        try OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true,
            ownsGate: { gate.stillOwns(claim) })) {
            let runtime = f.logic()
            let held = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: runtime, expectedProject: nil, requiresProjectReference: false))
            #expect(held.permitsRead())
            #expect(held.transportPaths[1].contains(where: { CFEqual($0, wrapper) }))
            f.routingLateScopeInjected = false
            f.routingRead = { element, attribute in
                guard !f.routingLateScopeInjected, CFEqual(element, wrapper), attribute == kAXParentAttribute as String else { return }
                f.routingLateScopeInjected = true
                f.builder.setChildren(bar, [play])
            }
            #expect(!held.permitsRead(), "A later branch's native read must not reuse an earlier shared-parent census")
            #expect(f.routingLateScopeInjected)
            f.routingRead = nil
            f.builder.setChildren(bar, [play, wrapper])
            #expect(!held.permitsRead(), "Restored branches cannot revive refused transport custody")
            #expect(f.selections.isEmpty && f.focusRestorationWrites.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func aTransportDecisionReadsEachSharedAncestorOnce(deep: Bool) throws {
        let f = try Fixture(), gate = LogicMutationGate()
        f.useBulkReads = true
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let bar = f.builder.element(1_965_720)
        if deep {
            let wrapper = f.builder.element(1_971_901)
            f.builder.setRole(wrapper, kAXGroupRole as String)
            f.builder.setChildren(wrapper, [bar])
            f.builder.setChildren(f.window, [f.rail, f.mixer, wrapper])
        }
        let claim = try #require(gate.tryAcquire(operation: "shared-native-transport"))
        defer { gate.release(claim) }
        try OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true,
            ownsGate: { gate.stillOwns(claim) })) {
            let runtime = f.logic()
            let held = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: runtime, expectedProject: nil, requiresProjectReference: false))
            #expect(held.permitsRead())
            var ancestors: [AXUIElement] = []
            for path in held.transportPaths {
                for parent in path.dropFirst().dropLast() where !ancestors.contains(where: { CFEqual($0, parent) }) {
                    ancestors.append(parent)
                }
            }
            #expect(!ancestors.isEmpty)
            f.reciprocalPathBatchCalls = 0
            #expect(AccessibilityChannel.HeldSelectionAssociation.stoppedTransportPathsMatch(
                held.transportPaths, activity: held.transport, window: f.window, logic: runtime))
            #expect(f.reciprocalPathBatchCalls == ancestors.count,
                "Each actual common ancestor needs one fresh reciprocal census within this decision")
            #expect(f.selections.isEmpty && f.focusRestorationWrites.isEmpty)
        }
    }

    @Test(arguments: ["play_value", "play_parent", "record_parent", "bar_parent", "bar_children"], [false, true])
    func aRecordReadCannotPreserveEarlierTransportCustody(fault: String, bulk: Bool) throws {
        let f = try Fixture(), gate = LogicMutationGate()
        f.useBulkReads = bulk
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let claim = try #require(gate.tryAcquire(operation: "late-native-transport"))
        defer { gate.release(claim) }
        try OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true,
            ownsGate: { gate.stillOwns(claim) })) {
            let runtime = f.logic()
            let held = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: runtime, expectedProject: nil, requiresProjectReference: false))
            #expect(held.permitsRead())
            let bar = held.transport.controlBar, play = held.transport.play, record = held.transport.record
            let foreign = f.builder.element(1_971_902)
            f.routingLateScopeInjected = false
            f.routingRead = { element, attribute in
                guard !f.routingLateScopeInjected, CFEqual(element, record), attribute == kAXValueAttribute as String else { return }
                f.routingLateScopeInjected = true
                switch fault {
                case "play_value": f.builder.setAttribute(play, kAXValueAttribute as String, NSNumber(value: 1))
                case "play_parent": f.builder.setAttribute(play, kAXParentAttribute as String, foreign)
                case "record_parent": f.builder.setAttribute(record, kAXParentAttribute as String, foreign)
                case "bar_parent": f.builder.setAttribute(bar, kAXParentAttribute as String, foreign)
                case "bar_children": f.builder.setChildren(bar, [record])
                default: Issue.record("Unknown transport fault")
                }
            }
            #expect(!held.permitsRead(), "The real held read must refuse transport custody lost during Record")
            #expect(f.routingLateScopeInjected, "Reach the deciding native Record value")
            f.routingRead = nil
            f.builder.setAttribute(play, kAXValueAttribute as String, NSNumber(value: 0))
            f.builder.setChildren(bar, [play, record])
            f.builder.setAttribute(bar, kAXParentAttribute as String, f.window)
            #expect(!held.permitsRead(), "Restoring controls cannot revive the refused held observation")
            #expect(f.selections.isEmpty && f.focusRestorationWrites.isEmpty)
        }
    }

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

    @Test("Passive Help retains a fresh final focus/window tuple and separate document bookend",
          arguments: ["unchanged", "legacy", "null_fallback", "failure", "short", "focus_type", "main_type", "window_type",
                      "foreign_focus", "foreign_main", "foreign_window", "absent", "late_document"])
    func passiveHelpFinalAppTupleIsFreshAndStrict(fault: String) async throws {
        let f = try Fixture()
        f.useBulkReads = fault != "legacy"
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        try await OperationTraceContext.$current.withValue(context) {
            let association = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: f.logic(), expectedProject: nil, requiresProjectReference: false))
            f.passiveFinalAppTupleFault = fault
            #expect(association.permitsPassiveFocusRead() == ["unchanged", "legacy", "null_fallback"].contains(fault))
            #expect(f.passiveFinalAppTupleReads == (fault == "legacy" ? 0 : 1),
                    "Read the original app's final focus and both windows together, not an earlier ownership tuple")
            #expect(f.selections.isEmpty && f.focusRestorationWrites.isEmpty)
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
        var globalFocusClassificationsDuringHeldEntry = 0
        var guardedEntryHelpReads = 0
        var focusOrderFaultInjected = false
        var helpReadsAfterFocusOrderFault = 0
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
        var passiveFinalAppTupleReads = 0
        var passiveFinalAppTupleFault: String?
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
        var inputReadReplacementPeer: AXUIElement?
        var routingOtherReplacement: AXUIElement?
        var routingAction: (@Sendable (AXUIElement, String) -> Bool)?
        var peerHydrationSamples: [AXHelpers.StripHelpSamples] = []
        var peerHydrationFaultInjected = false
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
        var routingBeforeSendMenuOpens = 0
        var routingDecidingSendFaultInjected = false
        var routingDecidingLeafActionsRead = false
        var routingDecidingModeRead = false
        var routingDecidingFinalChoiceRead = false
        var routingBusLeafPresses: [Int] = []
        var routingCanonicalInputBuses: [Int] = []
        var routingCanonicalContradictedInputs: [Int] = []
        var routingSourceInputCancelledAtSelectionCount: Int?
        var routingSourceInputFreshHeaderChallenges = 0
        var routingChangedSendPublished = false
        var routingChangedPermissionControlWalks = 0
        var routingInputReadRenewalArmed = false
        var routingInputReadRenewed = false
        var routingInverseRenewedSendMenuOpens = 0
        var routingSelectionsAtInverseLeaf: Int?
        var routingForwardSelections: [Int] = []

        func expectMinimumInverseSourceChallenges() throws {
            let start = try #require(routingSelectionsAtInverseLeaf, "Reach the actual inverse leaf")
            let actual = Array(selections.dropFirst(start))
            #expect(actual.count == 2,
                "Keep one changed-strip challenge and the actual source return; optional peer discovery is finished")
            let first = actual.first, last = actual.last
            #expect(first != nil && first != 0)
            #expect(last == 0)
        }

        func expectCanonicalInverseMeasurements(_ body: [String: Any], measuringAssociations: Bool,
                                                singleWriterPopup: Bool) throws {
            if measuringAssociations {
                try expectMinimumInverseSourceChallenges()
                #expect(body["saga_state"] as? String == "fullyCompensated")
            }
            if singleWriterPopup {
                #expect(routingInputReadRenewed, "Reach the actual owned Input read that retired the source")
                #expect(routingInverseRenewedSendMenuOpens == 1,
                    "Keep the deciding inverse popup; do not first open and Cancel another checked Send popup")
                #expect(routingBusLeafPresses == [2, 1], "The actual forward and owned inverse must both run")
                #expect(body["saga_state"] as? String == "fullyCompensated")
            }
        }
        var routingNamedSendBeforeInputCount: Int?
        var routingNamedSendPreInputPeerNameReads = 0
        var routingNamedSendPostInputObserverReads = 0
        var measureNamedBusPreInput = false

        func observeNamedSendBeforeRead() {
            if measureNamedBusPreInput, routingNameWrites == ["Selected Canonical"],
               routingDestinationPresses == 0,
               SendRemovalSagaAdapter.requiredSendControl == nil {
                if let count = routingNamedSendBeforeInputCount {
                    if routingCanonicalInputBuses.count > count { routingNamedSendPostInputObserverReads += 1 }
                } else {
                    // End of the real independent before-Send read, after
                    // the actual name write and before the first Input read.
                    routingNamedSendBeforeInputCount = routingCanonicalInputBuses.count
                }
            }
        }

        func expectNamedSendInputFootprint() throws {
            guard measureNamedBusPreInput else { return }
            let count = try #require(routingNamedSendBeforeInputCount,
                "Reach the independent checked Send read after the actual name write")
            #expect(routingCanonicalInputBuses.count > count,
                "Reach actual Input acquisition after that independent Send read")
            #expect(routingNamedSendPreInputPeerNameReads == 0,
                "The renewed Input scope checks the complete footprint; do not duplicate it before acquisition")
            #expect(routingNamedSendPostInputObserverReads == 0,
                "Corroborate the actual independent before-state in the deciding writer's popup, without another observer popup")
        }
        var routingInputOpenDiscoveryStart: Int?
        var routingInputOpenDiscoveryCounts: [Int] = []
        var routingOutputOpenDiscoveryStart: Int?
        var routingOutputOpenDiscoveryCounts: [Int] = []
        var routingInputOpenWindowScans = 0
        var routingInputDiscoveryProbe: AXUIElement?
        var routingPopupReadFocusRetained = false
        var routingForeignHelpReads = 0
        var routingForeignHelpFirstStack: [String] = []
        var scrollToChangedOutput = false
        var scrollToViewportDriftEnabled = false
        var scrollToViewportShifted = false
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
        var captureExpiredAtCheckedSendDispatch = false
        var inspectionExpiredBeforeSendRead = false
        var routingNamePropagatedDuringInputRead = false
        var coupledGuardBarReads = 0
        var coupledGuardPopulationScans = 0
        var heldHeaderDiscoveryScans = 0
        var heldHeaderDiscoveryActive = false
        var coupledGuardPlayReads = 0
        var coupledGuardRecordReads = 0
        var coupledGuardCountDiscovery = false
        var measuringFootprintReads = false
        var footprintTransportCensuses: [ObjectIdentifier: Int] = [:]
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
        var routingWindowListRead: (@Sendable () -> Void)?
        var routingNativePopupFrame: CGRect?
        var routingNativeApplicationFocusWrites = 0
        var inputForeignScopeHelpReads = 0
        var inputSetterDispatches = 0
        var inputReadAfterOutput = false
        var routingSelection: (@Sendable (Int) -> Void)?
        var sharedThirdStrip = false
        var thirdSharesOriginalStrip = false
        var thirdRetainsPreviousFocus = false
        var selectionKeepsPassiveRailFocus = false
        var selectedChildrenReads = 0
        var selectedChildrenReadsAtWrite = 0
        var associationStopReads = 0
        var associationStopReadsAtWrite = 0
        var routingLateScopeInjected = false
        var routingHeaderPresentationRefreshed = false
        var routingModeInspectionReads = 0
        var lateAssociationFocusSampled = false
        var lateAssociationFocusLanded = false
        var inputMenuPresses = 0
        var matchingGoalContextID: ObjectIdentifier?
        var matchingAfterNameReads: Int?
        var matchingNameCancelTask: Task<CallTool.Result, Never>?
        var inputMenuCancels = 0
        var renewedOutputPresses = 0
        var renewedOutputCancels = 0
        var inputRetirementCensusLag = false
        var inputRetiredSourceReadable = false
        var inputRetirementCensusLagObserved = false
        var inputTransientGeometrySettled = false
        func setInputGeometry(top: CGFloat, renewed: Bool) {
            builder.setFrame(strips[0], x: 0, y: top, width: 100, height: 300)
            let source = renewed ? routingReplacement ?? strips[1] : strips[1]
            builder.setFrame(source, x: 100, y: top, width: 100, height: 300)
        }
        var inputMenuHadOwnedClaim = false
        var inputSagaForwardVerified = false
        var inputInverseLeafObserved = false
        var inputInverseDocumentRead = false
        var inputInverseDescriptionRead = false
        var inputInverseDocumentCandidates = 0
        var inputInverseReadSequence = 0
        var inputInverseLastDocument = 0
        var inputInverseLastInput = 0
        var inputInverseScopeOrderedAtWrite = false
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
                    if measureNamedBusPreInput, let count = routingNamedSendBeforeInputCount,
                       routingCanonicalInputBuses.count == count,
                       CFEqual(element, builder.element(1_965_710)), attribute == kAXValueAttribute as String {
                        routingNamedSendPreInputPeerNameReads += 1
                    }
                    if routingInputOpenDiscoveryStart != nil,
                       routingInputDiscoveryProbe.map({ CFEqual(element, $0) }) == true,
                       attribute == kAXRoleAttribute as String, activeBulkAttributes == nil {
                        routingInputOpenWindowScans += 1
                    }
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
                    if measuringFootprintReads, !routingNameWrites.isEmpty,
                       CFEqual(element, builder.element(1_965_720)),
                       let guardian = AXHelpers.HelpReadGuard.current {
                        footprintTransportCensuses[ObjectIdentifier(guardian), default: 0] += 1
                    }
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
                    let selectedStrip = index == 0 ? routingReplacement ?? strips[1]
                            : index == 1 ? routingOtherReplacement ?? strips[0]
                                : strips[index == 2 ? (thirdSharesOriginalStrip ? 1 : sharedThirdStrip ? 0 : 3) : 2]
                    builder.setAttribute(app, kAXFocusedUIElementAttribute as String, selectedStrip)
                    if selectionKeepsPassiveRailFocus {
                        builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, [selectedStrip])
                        if let previousFocus, CFEqual(previousFocus as AnyObject, rail) {
                            builder.setAttribute(app, kAXFocusedUIElementAttribute as String, rail)
                        }
                    }
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
                } else { levelHit = routingFocusHit ?? base.ax.elementAtPosition }
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
                        if CFEqual(element, app), attributes == [kAXFocusedUIElementAttribute,
                            kAXMainWindowAttribute, kAXFocusedWindowAttribute] as [String] {
                            passiveFinalAppTupleReads += 1
                            let foreign = builder.element(1_965_999)
                            switch passiveFinalAppTupleFault {
                            case "failure": return .failure(.init(raw: AXError.cannotComplete.rawValue))
                            case "short": return .success([strips[1], window])
                            case "focus_type": return .success([NSNumber(value: 0), window, window])
                            case "main_type": return .success([strips[1], NSNumber(value: 0), window])
                            case "window_type": return .success([strips[1], window, NSNumber(value: 0)])
                            case "foreign_focus": return .success([foreign, window, window])
                            case "foreign_main": return .success([strips[1], foreign, window])
                            case "foreign_window": return .success([strips[1], window, foreign])
                            case "null_fallback": return .success([NSNull(), NSNull(), NSNull()])
                            case "absent":
                                var error = AXError.noValue
                                guard let wrapped = AXValueCreate(.axError, &error) else {
                                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                                }
                                return .success([wrapped, window, window])
                            case "late_document":
                                builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                                return .success([strips[1], window, window])
                            default: break
                            }
                        }
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
                onScreenWindowList: { [self] in
                    routingWindowListRead?()
                    guard let frame = routingNativePopupFrame else { return [] }
                    return [[kCGWindowOwnerPID as String: 4242, kCGWindowNumber as String: 1_973_119,
                        kCGWindowLayer as String: LogicOnScreenWindows.popupMenuLevel,
                        kCGWindowBounds as String: frame.dictionaryRepresentation]]
                }, postPopupMenuEscape: { Issue.record("no Escape") },
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
                                   if f.guardedEntryHelpReads > 0, f.selections.isEmpty {
                                       f.globalFocusClassificationsDuringHeldEntry += 1
                                   }
                                   return guardedPassiveFocus || (guardedRenewalFocus && f.routingReplacement != nil)
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

    @Test("An existing checked Bus output may depart only through a singleton local output goal",
          arguments: ["physical", "stereo", "physical_input", "misleading_input", "mixed_name", "mixed_input", "no_output", "no_receiver", "own_bus_input"])
    func canonicalBusDeparturePreviewRetainsItsNarrowContract(destination: String) async throws {
        try await assertCanonicalPhysicalOutput(mode: "bus_departure_" + destination)
    }

    @Test("An observed existing Bus destination retains only its singleton supported output goal",
          arguments: ["arrival", "arrival_physical_before", "arrival_physical_input", "arrival_no_receiver", "arrival_own_bus_input", "arrival_misleading_input", "arrival_mixed_name", "arrival_mixed_input", "arrival_bus_before"])
    func canonicalObservedExistingBusPreview(_ profile: String) async throws {
        try await assertCanonicalPhysicalOutput(mode: "bus_departure_" + profile)
    }

    @Test("A checked Bus replacement retains both distinct existing receiver prerequisites",
          arguments: ["replacement", "replacement_no_before_receiver", "replacement_no_after_receiver",
                      "replacement_mixed_name", "replacement_mixed_input"])
    func canonicalExistingBusReplacementPreview(_ profile: String) async throws {
        try await assertCanonicalPhysicalOutput(mode: "bus_departure_arrival_" + profile)
    }

    @Test("Existing-Bus replacement checks both receivers before writing and verifies its owned inverse",
          arguments: ["forward", "physical_input", "physical_cancel", "misleading_before", "misleading_after",
                      "cancel", "late_peer", "late_project", "popup_both_retired"])
    func canonicalExistingBusReplacementExecution(_ outcome: String) async throws {
        try await assertCanonicalPhysicalOutput(mode: "bus_departure_execute_arrival_replacement_" + outcome)
    }

    @Test("A post-write input Cancel must recover retained offscreen observations before final verification")
    func canonicalBusReplacementRecoversOffscreenReadback() async throws {
        try await assertCanonicalPhysicalOutput(mode: "bus_departure_execute_arrival_replacement_offscreen_peer")
    }

    @Test("Scroll To recovery cannot reuse a checked output sampled before its navigation")
    func canonicalBusRecoveryRenewsTheCheckedOutput() async throws {
        try await assertCanonicalPhysicalOutput(mode: "bus_departure_execute_arrival_replacement_offscreen_peer_checked_change")
    }

    @Test("Recovery restores the first viewport, not a later owned input-menu displacement")
    func canonicalBusRecoveryRetainsItsFirstViewport() async throws {
        try await assertCanonicalPhysicalOutput(mode: "bus_departure_execute_arrival_replacement_offscreen_peer_intermediate_viewport")
    }

    @Test("Original-header renewal restores its observed Mixer position before retaining an input source",
          arguments: ["owned", "stable_frames", "stable_recovery_frames", "ack_only", "unread_geometry", "foreign_bar", "vertical_bar",
                      "foreign_geometry_window", "foreign_geometry_mixer", "foreign_geometry_document", "foreign_geometry_headers", "foreign_geometry_count"])
    func originalHeaderRenewalRestoresItsObservedMixerViewport(profile: String) async throws {
        final class Probe: @unchecked Sendable { var leaves = 0; var writes = 0; var injected = false }
        let f = try Fixture(), b = f.builder, gate = LogicMutationGate(), probe = Probe()
        let owner = b.element(1_291_900), controls = b.element(1_291_901), toolbar = b.element(1_291_902)
        let view = b.element(1_291_903), root = b.element(1_291_904), scroll = b.element(1_291_905)
        let submenu = b.element(1_291_906), output = b.element(1_291_907), audio = b.element(1_291_908)
        let horizontal = b.element(1_291_909), thumb = b.element(1_291_910), replacement = b.element(1_291_911)
        for node in [owner, controls, toolbar] { b.setRole(node, kAXGroupRole as String) }
        b.setFrame(f.window, x: 0, y: 30, width: 1000, height: 800)
        b.setFrame(owner, x: 0, y: 300, width: 1000, height: 530)
        b.setFrame(f.mixer, x: 0, y: 300, width: 2000, height: 600)
        b.setChildren(toolbar, [view]); b.setChildren(controls, [toolbar]); b.setChildren(owner, [f.mixer, controls])
        b.setChildren(f.window, [f.rail, owner, b.element(1_965_720)])
        for (node, role, title) in [(view, kAXMenuButtonRole, AXLocalePolicy.viewMenuBar.canonical),
            (root, kAXMenuRole, ""), (scroll, kAXMenuItemRole, AXLocalePolicy.mixerScrollToMenuItem.canonical),
            (submenu, kAXMenuRole, ""), (output, kAXMenuItemRole, AXLocalePolicy.mixerScrollToOutputsMenuItem.canonical),
            (audio, kAXMenuItemRole, AXLocalePolicy.mixerTypeFilterAudio.canonical)] {
            b.setRole(node, role as String); b.setAttribute(node, kAXTitleAttribute as String, title)
            b.setAttribute(node, kAXEnabledAttribute as String, true); b.setAttribute(node, kAXWindowAttribute as String, f.window)
            b.setActionNames(node, [kAXPressAction as String, kAXCancelAction as String])
        }
        b.setChildren(output, []); b.setChildren(audio, []); b.setChildren(submenu, [output, audio])
        b.setChildren(scroll, [submenu]); b.setChildren(root, [scroll]); b.setChildren(view, [])
        b.setRole(horizontal, kAXScrollBarRole as String)
        b.setAttribute(horizontal, kAXOrientationAttribute as String, kAXHorizontalOrientationValue as String)
        b.setAttribute(horizontal, kAXWindowAttribute as String, f.window); b.setAttribute(horizontal, kAXParentAttribute as String, owner)
        b.setAttribute(horizontal, kAXValueAttribute as String, NSNumber(value: 0.25))
        b.setAttributeSettable(horizontal, kAXValueAttribute as String, true)
        b.setFrame(horizontal, x: 0, y: 813, width: 1000, height: 17)
        b.setRole(thumb, kAXValueIndicatorRole as String); b.setAttribute(thumb, kAXWindowAttribute as String, f.window)
        b.setFrame(thumb, x: 75, y: 814, width: 700, height: 15); b.setChildren(horizontal, [thumb]); b.setChildren(thumb, [])
        f.routingFocusHit = { _, _ in .success(thumb) }
        f.routingRead = { element, attribute in
            if profile == "unread_geometry", f.selections.count >= 4,
               CFEqual(element, replacement), attribute == kAXPositionAttribute as String {
                probe.injected = true
                b.removeAttribute(replacement, attribute)
            }
        }
        f.routingReadResult = { element, attribute in
            if CFEqual(element, horizontal), attribute == kAXValueAttribute as String {
                return .success(b.attributeValue(horizontal, attribute) as? NSNumber)
            }
            return nil
        }
        for (index, strip) in f.strips.enumerated() { b.setFrame(strip, x: CGFloat(index) * 100 - 55, y: 350, width: 100, height: 300) }
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        try await OperationTraceContext.$current.withValue(context) {
            let runtime = f.logic()
            let before = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: runtime, expectedProject: nil, requiresProjectReference: false))
            let pairs = await before.observe(referenceIsCurrent: { true }, stoppingWhen: { false }, allHeldHeaders: true)
            let original = try #require(pairs.first { CFEqual($0.track.header, f.headers[0]) })
            #expect(before.effects.restoration == "restored")
            let sampledGeometry = try #require(before.observedMixerViewportGeometry())
            let suppliedGeometry: AccessibilityChannel.HeldSelectionAssociation.MixerViewportGeometry? = profile.hasPrefix("foreign_geometry_")
                ? .init(window: profile == "foreign_geometry_window" ? b.element(1_291_912) : sampledGeometry.window,
                    mixer: profile == "foreign_geometry_mixer" ? b.element(1_291_912) : sampledGeometry.mixer,
                    headers: profile == "foreign_geometry_headers" ? Array(sampledGeometry.headers.reversed()) : sampledGeometry.headers,
                    document: profile == "foreign_geometry_document" ? "file:///foreign.logicx" : sampledGeometry.document,
                    frames: profile == "foreign_geometry_count" ? Array(sampledGeometry.frames.dropLast()) : sampledGeometry.frames,
                    horizontal: sampledGeometry.horizontal, vertical: sampledGeometry.vertical) : nil
            b.setRole(replacement, kAXLayoutItemRole as String)
            b.setAttribute(replacement, kAXNumberOfCharactersAttribute as String, 0)
            b.setAttribute(replacement, kAXInsertionPointLineNumberAttribute as String, 0)
            b.setChildren(replacement, b.makeAXRuntime().children(f.strips[1]))
            b.setFrame(replacement, x: 45, y: 350, width: 100, height: 300)
            f.routingReplacement = replacement; b.setChildren(f.mixer, [f.strips[0], replacement])
            b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, replacement)
            f.routingSelection = { _ in
                b.setAttribute(horizontal, kAXValueAttribute as String, NSNumber(value: 0.75))
                if profile == "foreign_bar" { b.setAttribute(horizontal, kAXParentAttribute as String, controls) }
                if profile == "vertical_bar" { b.setAttribute(horizontal, kAXOrientationAttribute as String, kAXVerticalOrientationValue as String) }
                if profile != "stable_frames" {
                    for (index, strip) in [f.strips[0], replacement].enumerated() {
                        b.setFrame(strip, x: CGFloat(index) * 100 - 255, y: 350, width: 100, height: 300)
                    }
                }
            }
            f.routingSetter = { element, attribute, value in
                guard CFEqual(element, horizontal), attribute == kAXValueAttribute as String,
                      let number = value as? NSNumber else { return nil }
                probe.writes += 1
                if profile != "ack_only" {
                    b.setAttribute(horizontal, attribute, number)
                    for (index, strip) in [f.strips[0], replacement].enumerated() {
                        b.setFrame(strip, x: CGFloat(index) * 100 - 55, y: 350, width: 100, height: 300)
                    }
                }
                return true
            }
            f.routingAction = { element, action in
                if CFEqual(element, view), action == kAXPressAction as String { b.setChildren(view, [root]); return true }
                if CFEqual(element, root), action == kAXCancelAction as String { b.setChildren(view, []); return true }
                if (CFEqual(element, output) || CFEqual(element, audio)), action == kAXPressAction as String {
                    probe.leaves += 1
                    let offset: CGFloat = CFEqual(element, audio) ? (profile == "stable_recovery_frames" ? -55 : 0) : -600
                    b.setAttribute(horizontal, kAXValueAttribute as String, NSNumber(value: CFEqual(element, audio) ? 0 : 1))
                    for (index, strip) in [f.strips[0], replacement].enumerated() {
                        b.setFrame(strip, x: CGFloat(index) * 100 + offset, y: 350, width: 100, height: 300)
                    }
                    b.setChildren(view, []); return true
                }
                Issue.record("Only the existing owned Scroll To and native viewport inverse are allowed"); return false
            }
            let renewed = await AccessibilityChannel.renewSourceThroughOriginalHeader(original,
                original: original.strip, runtime: runtime, restoringMixerGeometry: suppliedGeometry)
            if profile.hasPrefix("foreign_geometry_") {
                #expect(f.selections.count == 2, "Foreign geometry must refuse before any renewal selection")
            }
            let positive = ["owned", "stable_frames", "stable_recovery_frames"].contains(profile)
            if positive || profile == "ack_only" { #expect(probe.leaves == 2 && probe.writes == 1) }
            else { #expect(probe.writes == 0) }
            if profile == "unread_geometry" { #expect(probe.injected, "Reach the actual deciding native geometry read") }
            if !positive {
                #expect(renewed.source == nil)
                #expect(renewed.effects.restoration != "restored")
            } else {
                let renewedSource = try #require(renewed.source)
                #expect(renewedSource.pair.track.matches(original.track))
                #expect(renewed.effects.restoration == "restored")
                #expect((b.attributeValue(horizontal, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.25)
                #expect(AXHelpers.getPosition(replacement, runtime: runtime.ax)?.x == 45)
            }
        }
    }

    @Test("Explicitly scoped native Mixer Scroll To preserves its original physical viewport",
          .enabled(if: ProcessInfo.processInfo.environment["LOGIC_MCP_NATIVE_MIXER_RECOVERY_PROJECT"] != nil))
    func nativeMixerScrollToRetainsItsObservedOwners() async throws {
        let expectedPath = try #require(ProcessInfo.processInfo.environment["LOGIC_MCP_NATIVE_MIXER_RECOVERY_PROJECT"])
        try #require(!expectedPath.isEmpty && AXIsProcessTrusted(), "Native AX permission and an explicit project are required")
        let runtime = AXLogicProElements.Runtime.production
        let app = try #require(AXLogicProElements.appRoot(runtime: runtime))
        let window: AXUIElement = try #require(AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: runtime.ax))
        let observedDocument = try #require(AXHelpers.getAttribute(window, kAXDocumentAttribute as String, runtime: runtime.ax) as String?)
        let observedURL = try #require(URL(string: observedDocument))
        try #require(observedURL.isFileURL && observedURL.standardizedFileURL.path == URL(fileURLWithPath: expectedPath).standardizedFileURL.path,
                     "Refuse a different project before any navigation")
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "native-owned-mixer-scroll"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) },
            deadline: ContinuousClock.now.advanced(by: .seconds(45)))
        try await OperationTraceContext.$current.withValue(context) {
            let held = try #require(AccessibilityChannel.HeldSelectionAssociation(window: window,
                logic: runtime, expectedProject: nil, requiresProjectReference: false))
            let geometry = try #require(held.observedMixerViewportGeometry())
            let recovered = await held.recoverMixerReadability(restoring: geometry,
                referenceIsCurrent: { true }, stoppingWhen: { !gate.stillOwns(claim) })
            #expect(recovered)
            #expect(held.effects.restoration == "restored")
            #expect(Array(held.effects.changed.prefix(2)) == ["mixer_scroll_to_output", "mixer_scroll_to_audio"])
            #expect(held.effects.changed.dropFirst(2).allSatisfy({
                ["mixer_horizontal_viewport", "mixer_vertical_viewport"].contains($0)
            }))
            #expect(held.observedMixerViewportGeometry()?.frames == geometry.frames)
            #expect(held.permitsRead())
        }
    }

    private final class MixerViewportRecoveryProbe: @unchecked Sendable {
        var viewParentReads = 0
        var viewChildrenReads = 0
        var firstOpenParentRead: Int?
        var firstLeafChildrenRead: Int?
        var injected = false
        var foreignActions = 0
        var cancels = 0
        var leafPresses = 0
        var viewportWrites = 0
        var initialSelectionMoved = false
        var initialReferenceCalls = 0
        var initialStopCalls = 0
        var initialStopsAtWrite: Int?
        var referenceCurrent = true
        var referencesAfterInverse = 0
        var stopsAfterInverse = 0
        var rootAvailableAt: ContinuousClock.Instant?
    }

    private typealias MixerViewportRecoveryNodes = (
        view: AXUIElement,
        root: AXUIElement,
        output: AXUIElement,
        audio: AXUIElement,
        controls: AXUIElement,
        toolbar: AXUIElement,
        foreignControls: AXUIElement,
        competingRoot: AXUIElement,
        horizontal: AXUIElement,
        thumb: AXUIElement,
        otherAxis: AXUIElement
    )

    private static func runMixerViewportRecovery(_ fault: String, parentFault: Int? = nil, childrenFault: Int? = nil, failedOpen: Bool = false,
             stopFault: Int? = nil, publicationReferenceFault: Int? = nil,
             publicationStopFault: Int? = nil) async throws -> MixerViewportRecoveryProbe {
        let f = try Fixture(), gate = LogicMutationGate(), probe = MixerViewportRecoveryProbe()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        for (index, strip) in f.strips.enumerated() {
            f.builder.setFrame(strip, x: CGFloat(index) * 100, y: 100, width: 100, height: 300)
        }
        let view = f.builder.element(1_975_500), root = f.builder.element(1_975_501)
        let scroll = f.builder.element(1_975_502), submenu = f.builder.element(1_975_503)
        let output = f.builder.element(1_975_504), audio = f.builder.element(1_975_505)
        let controls = f.builder.element(1_975_506), toolbar = f.builder.element(1_975_507)
        let foreignControls = f.builder.element(1_975_508), competingRoot = f.builder.element(1_975_509)
        f.builder.setRole(controls, kAXGroupRole as String); f.builder.setRole(toolbar, kAXGroupRole as String)
        f.builder.setRole(foreignControls, kAXGroupRole as String); f.builder.setChildren(foreignControls, [])
        f.builder.setRole(competingRoot, kAXMenuRole as String); f.builder.setChildren(competingRoot, [])
        for (element, role, title) in [
            (view, kAXMenuButtonRole, AXLocalePolicy.viewMenuBar.canonical),
            (root, kAXMenuRole, ""),
            (scroll, kAXMenuItemRole, AXLocalePolicy.mixerScrollToMenuItem.canonical),
            (submenu, kAXMenuRole, ""),
            (output, kAXMenuItemRole, fault == "native_english_outputs" ? "Outputs"
                : fault == "native_korean_outputs" ? "출력"
                : fault == "native_japanese_outputs" ? "出力"
                : fault == "singular_filter_output" ? "Output" : AXLocalePolicy.mixerScrollToOutputsMenuItem.canonical),
            (audio, kAXMenuItemRole, AXLocalePolicy.mixerTypeFilterAudio.canonical)
        ] {
            f.builder.setRole(element, role as String)
            f.builder.setAttribute(element, kAXTitleAttribute as String, title)
            f.builder.setAttribute(element, kAXEnabledAttribute as String, true)
            f.builder.setAttribute(element, kAXWindowAttribute as String, f.window)
            f.builder.setActionNames(element, [kAXPressAction as String, kAXCancelAction as String])
        }
        f.builder.setChildren(output, []); f.builder.setChildren(audio, [])
        f.builder.setChildren(submenu, [output, audio]); f.builder.setChildren(scroll, [submenu])
        f.builder.setChildren(root, [scroll]); f.builder.setChildren(view, [])
        f.builder.setChildren(toolbar, [view]); f.builder.setChildren(controls, [toolbar])
        f.builder.setChildren(f.window, f.builder.makeAXRuntime().children(f.window) + [controls, foreignControls])
        let nativeHorizontal = fault.hasPrefix("native_hidden_horizontal")
        let nativeVertical = fault.hasPrefix("native_hidden_vertical")
        let nativeViewport = nativeHorizontal || nativeVertical
        let horizontal = f.builder.element(1_975_510), thumb = f.builder.element(1_975_511)
        let mixedViewport = fault.contains("_mixed")
        let otherAxis = f.builder.element(1_975_513), otherThumb = f.builder.element(1_975_514)
        if nativeViewport {
            let owner = f.builder.element(1_975_512)
            f.builder.setRole(owner, kAXGroupRole as String)
            f.builder.setFrame(f.window, x: 0, y: 30, width: 1000, height: 800)
            f.builder.setFrame(owner, x: 0, y: 300, width: 1000, height: 530)
            f.builder.setFrame(f.mixer, x: 0, y: 300, width: 2000, height: 600)
            f.builder.setChildren(owner, [f.mixer, controls])
            f.builder.setChildren(f.window, [f.rail, owner, f.builder.element(1_965_720)])
            f.builder.setRole(horizontal, kAXScrollBarRole as String)
            f.builder.setAttribute(horizontal, kAXOrientationAttribute as String,
                nativeVertical || fault.hasSuffix("_vertical")
                    ? kAXVerticalOrientationValue as String : kAXHorizontalOrientationValue as String)
            f.builder.setAttribute(horizontal, kAXWindowAttribute as String, f.window)
            f.builder.setAttribute(horizontal, kAXParentAttribute as String, fault.hasSuffix("_foreign") ? foreignControls : owner)
            f.builder.setAttribute(horizontal, kAXValueAttribute as String, NSNumber(value: 0.25))
            f.builder.setAttributeSettable(horizontal, kAXValueAttribute as String, true)
            f.builder.setFrame(horizontal, x: nativeVertical ? 983 : 0, y: nativeVertical ? 300 : 813,
                width: nativeVertical ? 17 : 1000, height: nativeVertical ? 530 : 17)
            f.builder.setRole(thumb, kAXValueIndicatorRole as String)
            f.builder.setAttribute(thumb, kAXWindowAttribute as String, f.window)
            f.builder.setFrame(thumb, x: nativeVertical ? 984 : 75, y: nativeVertical ? 350 : 814,
                width: nativeVertical ? 15 : 700, height: nativeVertical ? 400 : 15)
            f.builder.setChildren(horizontal, [thumb]); f.builder.setChildren(thumb, [])
            // Like the observed native bar, its owner omits it from AXChildren.
            if fault.contains("_exposed") {
                f.builder.setChildren(owner, [f.mixer, controls, horizontal])
            }
            if mixedViewport {
                f.builder.setRole(otherAxis, kAXScrollBarRole as String)
                f.builder.setAttribute(otherAxis, kAXOrientationAttribute as String, kAXVerticalOrientationValue as String)
                f.builder.setAttribute(otherAxis, kAXWindowAttribute as String, f.window)
                f.builder.setAttribute(otherAxis, kAXParentAttribute as String, owner)
                f.builder.setAttribute(otherAxis, kAXValueAttribute as String, NSNumber(value: 0.25))
                f.builder.setAttributeSettable(otherAxis, kAXValueAttribute as String, true)
                f.builder.setFrame(otherAxis, x: 983, y: 300, width: 17, height: 530)
                f.builder.setRole(otherThumb, kAXValueIndicatorRole as String)
                f.builder.setAttribute(otherThumb, kAXWindowAttribute as String, f.window)
                f.builder.setFrame(otherThumb, x: 984, y: 350, width: 15, height: 400)
                f.builder.setChildren(otherAxis, [otherThumb]); f.builder.setChildren(otherThumb, [])
            }
            f.routingFocusHit = { _, point in .success(mixedViewport && point.y < 800 ? otherThumb : thumb) }
            for (index, strip) in f.strips.enumerated() {
                f.builder.setFrame(strip, x: CGFloat(index) * 100 - (nativeVertical ? 0 : 55),
                    y: nativeVertical || mixedViewport ? 337 : 350, width: 100, height: 300)
            }
            f.routingSetter = { element, attribute, value in
                guard (CFEqual(element, horizontal) || mixedViewport && CFEqual(element, otherAxis)),
                      attribute == kAXValueAttribute as String,
                      let number = value as? NSNumber else { return nil }
                probe.viewportWrites += 1
                if f.builder.attributeValue(f.window, kAXDocumentAttribute as String) as? String == "file:///tmp/Foreign.logicx" {
                    probe.foreignActions += 1
                }
                if fault.hasSuffix("_ack_only") { return true }
                f.builder.setAttribute(element, attribute, number)
                if fault.hasSuffix("_mixed_late_peer"), probe.viewportWrites == 1 {
                    probe.injected = true
                    f.builder.setAttribute(otherAxis, kAXValueAttribute as String, NSNumber(value: 0.5))
                }
                f.builder.setFrame(thumb, x: nativeVertical ? 984 : 75, y: nativeVertical ? 350 : 814,
                    width: nativeVertical ? 15 : 700, height: nativeVertical ? 400 : 15)
                for (index, strip) in f.strips.enumerated() {
                    let x = mixedViewport
                        ? ((f.builder.attributeValue(horizontal, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.25 ? 55 : 0)
                        : (nativeVertical ? 0 : 55)
                    let otherValue = (f.builder.attributeValue(otherAxis, kAXValueAttribute as String) as? NSNumber)?.doubleValue
                    let y = mixedViewport ? (otherValue == 0.25 ? 337 : otherValue == 0.5 ? 324 : 350)
                        : (nativeVertical ? 337 : 350)
                    f.builder.setFrame(strip, x: CGFloat(index) * 100 - CGFloat(x),
                        y: CGFloat(y), width: 100, height: 300)
                }
                return true
            }
        }
        let claim = try #require(gate.tryAcquire(operation: "scroll-to-readback"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        try await OperationTraceContext.$current.withValue(context) { @Sendable in
            try await Self.exerciseMixerViewportRecovery(fault, fixture: f, probe: probe,
                nodes: (view, root, output, audio, controls, toolbar, foreignControls,
                    competingRoot, horizontal, thumb, otherAxis),
                nativeViewport: nativeViewport, nativeVertical: nativeVertical, mixedViewport: mixedViewport,
                parentFault: parentFault, childrenFault: childrenFault, failedOpen: failedOpen,
                stopFault: stopFault, publicationReferenceFault: publicationReferenceFault,
                publicationStopFault: publicationStopFault)
        }
        return probe
    }

    private static func exerciseMixerViewportRecovery(
        _ fault: String, fixture f: Fixture, probe: MixerViewportRecoveryProbe,
        nodes: MixerViewportRecoveryNodes, nativeViewport: Bool, nativeVertical: Bool, mixedViewport: Bool,
        parentFault: Int?, childrenFault: Int?, failedOpen: Bool, stopFault: Int?,
        publicationReferenceFault: Int?, publicationStopFault: Int?
    ) async throws {
        let (view, root, output, audio, controls, toolbar, foreignControls,
            competingRoot, horizontal, thumb, otherAxis) = nodes
        let held = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
            logic: f.logic(), expectedProject: nil, requiresProjectReference: false))
        let geometry = try #require(held.observedMixerViewportGeometry())
        f.routingReadResult = { element, attribute in
            if nativeViewport, (CFEqual(element, horizontal) || mixedViewport && CFEqual(element, otherAxis)),
               attribute == kAXValueAttribute as String {
                if probe.leafPresses == 2, fault.hasSuffix("_late_document") {
                    f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    probe.injected = true
                }
                if probe.leafPresses == 2, fault.hasSuffix("_boolean") { return .success(NSNumber(value: false)) }
                // Preserve native numeric zero; the generic fixture's
                // convenience bridge otherwise coerces NSNumber(0) to Bool.
                return .success(f.builder.attributeValue(element, attribute) as? NSNumber)
            }
            if fault == "unread_parent", CFEqual(element, root), attribute == kAXParentAttribute as String {
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            }
            return nil
        }
        f.routingRead = { element, attribute in
            if CFEqual(element, view), attribute == kAXParentAttribute as String {
                probe.viewParentReads += 1
                if probe.viewParentReads == parentFault {
                    probe.injected = true
                    f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                }
            }
        }
        f.routingChildrenRead = { element in
            if CFEqual(element, view) {
                if let ready = probe.rootAvailableAt, ContinuousClock.now >= ready {
                    probe.rootAvailableAt = nil
                    f.builder.setChildren(view, [root])
                }
                probe.viewChildrenReads += 1
                if probe.viewChildrenReads == childrenFault {
                    probe.injected = true
                    if fault == "late_competing_root" {
                        f.builder.setChildren(view, [root, competingRoot])
                    } else {
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                }
            }
        }
        f.routingAction = { element, action in
            if f.builder.attributeValue(f.window, kAXDocumentAttribute as String) as? String == "file:///tmp/Foreign.logicx" {
                probe.foreignActions += 1
            }
            if CFEqual(element, view), action == kAXPressAction as String {
                if probe.firstOpenParentRead == nil { probe.firstOpenParentRead = probe.viewParentReads }
                if fault == "delayed_root" {
                    probe.rootAvailableAt = ContinuousClock.now.advanced(by: .milliseconds(160))
                    f.builder.setChildren(view, []); return true
                }
                f.builder.setChildren(view, [root])
                if fault == "native_container_parent" { f.builder.setAttribute(root, kAXParentAttribute as String, controls) }
                if fault == "foreign_container_parent" { f.builder.setAttribute(root, kAXParentAttribute as String, foreignControls) }
                if fault == "wrong_depth_parent" { f.builder.setAttribute(root, kAXParentAttribute as String, toolbar) }
                if fault == "missing_parent" { f.builder.removeAttribute(root, kAXParentAttribute as String) }
                return !failedOpen
            }
            if CFEqual(element, root), action == kAXCancelAction as String {
                probe.cancels += 1; f.builder.setChildren(view, []); return true
            }
            if CFEqual(element, output) || CFEqual(element, audio), action == kAXPressAction as String {
                probe.leafPresses += 1
                if probe.firstLeafChildrenRead == nil { probe.firstLeafChildrenRead = probe.viewChildrenReads }
                if nativeViewport, CFEqual(element, audio) {
                    f.builder.setAttribute(horizontal, kAXValueAttribute as String, NSNumber(value: 0))
                    if mixedViewport { f.builder.setAttribute(otherAxis, kAXValueAttribute as String, NSNumber(value: 0)) }
                    f.builder.setFrame(thumb, x: nativeVertical ? 984 : 0, y: nativeVertical ? 300 : 814,
                        width: nativeVertical ? 15 : 700, height: nativeVertical ? 400 : 15)
                    for (index, strip) in f.strips.enumerated() {
                        f.builder.setFrame(strip, x: CGFloat(index) * 100, y: 350, width: 100, height: 300)
                    }
                }
                f.builder.setChildren(view, []); return true
            }
            return false
        }
        let referenceIsCurrent: @Sendable () async -> Bool = {
            if probe.viewportWrites > 0 {
                probe.referencesAfterInverse += 1
                if probe.referencesAfterInverse == publicationReferenceFault {
                    probe.injected = true
                    f.builder.setAttribute(horizontal, kAXValueAttribute as String, NSNumber(value: 0.5))
                    for (index, strip) in f.strips.enumerated() {
                        f.builder.setFrame(strip, x: CGFloat(index) * 100 - 110, y: 350, width: 100, height: 300)
                    }
                }
            }
            if fault.hasSuffix("_before_selection"), f.selections.isEmpty {
                probe.initialReferenceCalls += 1
                if probe.initialReferenceCalls == 2 {
                    probe.injected = true
                    f.builder.setAttribute(horizontal, kAXValueAttribute as String, NSNumber(value: 0.5))
                    for (index, strip) in f.strips.enumerated() {
                        f.builder.setFrame(strip, x: CGFloat(index) * 100 - 110, y: 350, width: 100, height: 300)
                    }
                }
            }
            if probe.leafPresses == 2, fault.contains("_late_reference_"), !probe.injected {
                probe.injected = true
                if fault.hasSuffix("_project") {
                    f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                } else if fault.hasSuffix("_control") {
                    f.builder.setAttribute(horizontal, kAXParentAttribute as String, foreignControls)
                } else {
                    f.builder.setAttribute(horizontal, kAXValueAttribute as String, NSNumber(value: 0.5))
                }
            }
            return probe.referenceCurrent
        }
        let recovered: Bool
        if fault.contains("_initial_observation") {
            // Native selection can move an omitted Mixer scrollbar
            // before any later original-header renewal takes a sample.
            f.routingSelection = { _ in
                if probe.initialStopsAtWrite == nil { probe.initialStopsAtWrite = probe.initialStopCalls }
                guard !probe.initialSelectionMoved else { return }
                probe.initialSelectionMoved = true
                f.builder.setAttribute(horizontal, kAXValueAttribute as String, NSNumber(value: 0))
                if mixedViewport { f.builder.setAttribute(otherAxis, kAXValueAttribute as String, NSNumber(value: 0)) }
                for (index, strip) in f.strips.enumerated() {
                    f.builder.setFrame(strip, x: CGFloat(index) * 100, y: 350, width: 100, height: 300)
                }
            }
            let pairs = await held.observe(referenceIsCurrent: referenceIsCurrent,
                stoppingWhen: {
                    probe.initialStopCalls += 1
                    if probe.viewportWrites > 0 {
                        probe.stopsAfterInverse += 1
                        if probe.stopsAfterInverse == publicationStopFault {
                            probe.injected = true
                            f.builder.setAttribute(horizontal, kAXValueAttribute as String, NSNumber(value: 0.5))
                            for (index, strip) in f.strips.enumerated() {
                                f.builder.setFrame(strip, x: CGFloat(index) * 100 - 110, y: 350, width: 100, height: 300)
                            }
                        }
                    }
                    if f.selections.isEmpty, probe.initialStopCalls == stopFault {
                        probe.injected = true
                        probe.referenceCurrent = false
                    }
                    return false
                }, allHeldHeaders: true)
            if fault.hasSuffix("_mixed_late_peer") {
                #expect(probe.injected && pairs.isEmpty && probe.viewportWrites == 1 && probe.leafPresses == 0)
                #expect((f.builder.attributeValue(otherAxis, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.5)
            } else if publicationReferenceFault != nil || publicationStopFault != nil {
                #expect(probe.injected && probe.initialSelectionMoved && f.selections == [1, 0])
                #expect(pairs.isEmpty && probe.viewportWrites == 1 && probe.leafPresses == 2)
                #expect((f.builder.attributeValue(horizontal, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.5)
            } else if stopFault != nil {
                #expect(probe.injected && !probe.initialSelectionMoved && f.selections.isEmpty)
                #expect(pairs.isEmpty && probe.viewportWrites == 0 && probe.leafPresses == 0)
            } else if fault.hasSuffix("_before_selection") {
                #expect(probe.injected && !probe.initialSelectionMoved && f.selections.isEmpty)
                #expect(pairs.isEmpty && probe.viewportWrites == 0 && probe.leafPresses == 0)
                #expect((f.builder.attributeValue(horizontal, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.5)
            } else {
                #expect(probe.initialSelectionMoved && f.selections == [1, 0])
                #expect(pairs.count == (fault.contains("_late_reference_") ? 0 : 2))
            }
            recovered = held.effects.restoration == "restored"
        } else {
            recovered = await held.recoverMixerReadability(restoring: geometry,
                referenceIsCurrent: referenceIsCurrent, stoppingWhen: { false })
        }
        if parentFault != nil || childrenFault != nil {
            #expect(probe.injected, "Reach the actual last deciding native path/menu read")
            #expect(probe.foreignActions == 0, "No opening, leaf or cleanup action in a foreign document")
            #expect(!recovered)
            if fault == "late_competing_root" { #expect(probe.leafPresses == 0) }
        } else if ["foreign_container_parent", "wrong_depth_parent", "missing_parent", "unread_parent", "singular_filter_output"].contains(fault) {
            #expect(!recovered)
            #expect(probe.leafPresses == 0)
        } else if failedOpen {
            #expect(!recovered)
            #expect(probe.cancels == 1)
            #expect(f.builder.makeAXRuntime().children(view).isEmpty)
        } else if publicationReferenceFault != nil || publicationStopFault != nil || fault.hasSuffix("_mixed_late_peer") {
            #expect(!recovered)
            #expect(probe.foreignActions == 0)
        } else if nativeViewport && !["native_hidden_horizontal", "native_hidden_vertical",
            "native_hidden_horizontal_initial_observation", "native_hidden_vertical_initial_observation",
            "native_hidden_horizontal_initial_observation_stop_reference",
            "native_hidden_horizontal_initial_observation_exposed", "native_hidden_vertical_initial_observation_exposed",
            "native_hidden_horizontal_initial_observation_exposed_mixed",
            "native_hidden_horizontal_initial_observation_publication_reference",
            "native_hidden_horizontal_initial_observation_publication_stop"].contains(fault) || stopFault != nil {
            #expect(!recovered)
            #expect(probe.viewportWrites == (fault.hasSuffix("_ack_only") ? 1 : 0))
            #expect(probe.foreignActions == 0)
            if fault.hasSuffix("_late_document") || fault.contains("_late_reference_") { #expect(probe.injected) }
        } else {
            #expect(recovered)
            if nativeViewport {
                #expect(probe.leafPresses == (fault.hasSuffix("_exposed") ? 0 : 2))
                #expect(probe.viewportWrites == (mixedViewport ? 3 : 1))
                #expect((f.builder.attributeValue(horizontal, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.25)
                #expect(held.observedMixerViewportGeometry()?.frames == geometry.frames)
            }
        }
    }

    @Test("Scroll To actions renew native scope after deciding reads and clean up a failed opening",
          arguments: ["late_open", "late_leaf", "failed_open", "delayed_root", "native_container_parent",
                      "foreign_container_parent", "wrong_depth_parent", "missing_parent", "unread_parent", "late_competing_root",
                      "native_english_outputs", "native_korean_outputs", "native_japanese_outputs", "singular_filter_output",
                      "native_hidden_horizontal", "native_hidden_horizontal_vertical", "native_hidden_horizontal_foreign",
                      "native_hidden_horizontal_boolean", "native_hidden_horizontal_ack_only", "native_hidden_horizontal_late_document",
                      "native_hidden_horizontal_late_reference_project", "native_hidden_horizontal_late_reference_control",
                      "native_hidden_horizontal_late_reference_value",
                      "native_hidden_vertical", "native_hidden_vertical_ack_only", "native_hidden_vertical_foreign",
                      "native_hidden_vertical_boolean", "native_hidden_vertical_late_document",
                      "native_hidden_vertical_late_reference_project", "native_hidden_vertical_late_reference_control",
                      "native_hidden_vertical_late_reference_value",
                      "native_hidden_horizontal_initial_observation", "native_hidden_vertical_initial_observation",
                      "native_hidden_horizontal_initial_observation_late_reference_value",
                      "native_hidden_horizontal_initial_observation_before_selection",
                      "native_hidden_horizontal_initial_observation_stop_reference",
                      "native_hidden_horizontal_initial_observation_exposed",
                      "native_hidden_vertical_initial_observation_exposed",
                      "native_hidden_horizontal_initial_observation_exposed_mixed",
                      "native_hidden_horizontal_initial_observation_exposed_mixed_late_peer",
                      "native_hidden_horizontal_initial_observation_publication_reference",
                      "native_hidden_horizontal_initial_observation_publication_stop"])
    func mixerScrollToRecoveryOwnsItsLastActionBoundary(_ fault: String) async throws {
        let calibration = try await Self.runMixerViewportRecovery(fault)
        if fault == "late_open" { _ = try await Self.runMixerViewportRecovery(fault, parentFault: try #require(calibration.firstOpenParentRead)) }
        if fault == "late_leaf" { _ = try await Self.runMixerViewportRecovery(fault, childrenFault: try #require(calibration.firstLeafChildrenRead)) }
        if fault == "late_competing_root" { _ = try await Self.runMixerViewportRecovery(fault, childrenFault: try #require(calibration.firstLeafChildrenRead)) }
        if fault == "failed_open" { _ = try await Self.runMixerViewportRecovery(fault, failedOpen: true) }
        if fault.hasSuffix("_stop_reference") {
            _ = try await Self.runMixerViewportRecovery(fault, stopFault: try #require(calibration.initialStopsAtWrite))
        }
        if fault.hasSuffix("_publication_reference") {
            #expect(calibration.referencesAfterInverse > 1)
            _ = try await Self.runMixerViewportRecovery(fault, publicationReferenceFault: calibration.referencesAfterInverse)
        }
        if fault.hasSuffix("_publication_stop") {
            #expect(calibration.stopsAfterInverse > 1)
            _ = try await Self.runMixerViewportRecovery(fault, publicationStopFault: calibration.stopsAfterInverse)
        }
    }

    @Test("An existing Bus output goal uses the current checked receiver and owns only its conditional inverse",
          arguments: ["forward", "physical_before", "cancel", "physical_input", "physical_cancel", "popup_both_retired", "late_peer", "late_project", "external_peer"])
    func canonicalObservedExistingBusExecutes(_ outcome: String) async throws {
        try await assertCanonicalPhysicalOutput(mode: "bus_departure_execute_arrival_" + outcome)
    }

    @Test("Bus departure reuses the exact source, protected footprint and conditional Bus inverse",
          arguments: ["forward", "stereo", "cancel", "late_peer", "late_project", "post_write_loss", "ack_only", "newer", "retired", "physical_input", "physical_cancel", "changed_source_input", "changed_receiver_input", "misleading_receiver", "popup_source", "popup_receiver", "popup_source_retired", "popup_both_retired", "external_peer"])
    func canonicalBusDepartureExecutesOnlyItsCapturedOutput(outcome: String) async throws {
        try await assertCanonicalPhysicalOutput(mode: "bus_departure_execute_" + outcome)
    }

    @Test("Bus prerequisite reads refuse lost native custody before physical Help",
          arguments: ["source_document", "source_editor", "physical_editor", "receiver_document"])
    func canonicalBusDeparturePrerequisitesGuardPhysicalHelp(fault: String) async throws {
        try await assertCanonicalPhysicalOutput(mode: "bus_departure_execute_prereq_" + fault)
    }

    @Test("An explicit No Output policy retains the checked source in its existing canonical output task")
    func canonicalNoOutputPreviewUsesTheCapturedPair() async throws {
        try await assertCanonicalPhysicalOutput(mode: "preview_no_output")
    }

    @Test("Canonical No Output and a fresh Stereo return use the retained source and public apply contract",
          arguments: ["canonical_no_output", "canonical_no_output_return"])
    func canonicalNoOutputExecutesOnlyItsCapturedSource(mode: String) async throws {
        try await assertCanonicalPhysicalOutput(mode: mode)
    }

    @Test("Only the original application focus of its owned native neutral popup permits return",
          arguments: ["app_focus", "foreign_app_focus", "no_value_app_focus", "unread_window_app_focus", "absent_window_app_focus", "foreign_window_app_focus"])
    func canonicalNoOutputNativeApplicationFocusRemainsOwned(mode: String) async throws {
        try await assertCanonicalPhysicalOutput(mode: "canonical_no_output_return_" + mode)
    }

    @Test("Canonical No Output retains its existing fault and verified compensation boundaries",
          arguments: ["cancel", "late_peer", "late_project", "return_late_peer", "return_late_project", "ack_only", "newer", "retired", "post_write_loss"])
    func canonicalNoOutputRejectsLostCustodyAndCompensatesOnlyItsEffect(mode: String) async throws {
        try await assertCanonicalPhysicalOutput(mode: "canonical_no_output_" + mode)
    }

    @Test("No Output admission does not grant mixed goals or physical-output transitions",
          arguments: ["mixed_input", "mixed_name", "physical_before", "return_physical"])
    func canonicalNoOutputDoesNotExpandOtherContracts(mode: String) async throws {
        try await assertCanonicalPhysicalOutput(mode: "canonical_no_output_" + mode)
    }

    @Test("Canonical output cancellation retains independent Saga reads without duplicate adapter popup reads")
    func canonicalOutputCancellationDoesNotRepeatTheSagasIndependentReadback() async throws {
        let f = try Fixture()
        try await assertCanonicalPhysicalOutput(mode: "cancel", fixture: f)
        #expect(f.routingDestinationPresses == 2)
        #expect(f.inputMenuPresses <= 8,
                "Keep the captured baseline, Saga before/after and inverse-ownership reads, and each checked scalar writer; duplicate adapter reads consume the same bounded native lifecycle")
    }

    @Test("Canonical output exposes the actual forward and inverse child results without replacing its parent trace",
          arguments: ["forward", "cancel", "ack_only"])
    func canonicalOutputChildTracesReflectActualResults(mode: String) async throws {
        try await FeatureFlags.withAdr005OperationTraceForTests(true) {
            let f = try Fixture(), context = OperationTraceContext(), store = OperationTraceStore()
            try await OperationTraceStore.$shared.withValue(store) {
                try await OperationTraceContext.$current.withValue(context) {
                    try await assertCanonicalPhysicalOutput(mode: mode, fixture: f)
                }
            }
            let parentID = try #require(context.traceID)
            let parent = try #require(await store.trace(parentID))
            #expect(parent.operationID == "system.saga_execute")
            let children = await store.recent(limit: 128).filter { trace in
                trace.operationID == "mixer.set_output_verified" && trace.events.contains {
                    $0.phase == .requestReceived && $0.attributes["parent_trace_id"] == parentID.rawValue
                }
            }
            #expect(children.count == (mode == "cancel" ? 2 : 1), "Each actual output writer needs its own observable child")
            for child in children {
                #expect(child.traceID != parentID)
                #expect(child.events.filter { $0.phase == .writeBoundaryCrossed }.count == 1)
                #expect(child.events.contains {
                    $0.phase == .verificationCompleted && $0.attributes["readback_state"] == (mode == "ack_only" ? "B" : "A")
                }, "An ineffective acknowledged setter must never publish a verified A event")
                #expect(child.events.contains { $0.phase == .resultEmitted })
            }
            #expect(f.routingDestinationPresses == (mode == "cancel" ? 2 : 1))
        }
    }

    @Test("An unavailable input goal cannot authorize only the supported output subset")
    func mixedInputCannotExecuteOnlyItsSupportedOutput() async throws {
        try await assertCanonicalPhysicalOutput(mode: "mixed_input")
    }

    @Test("Protected footprint rows retain full Help guards without repeating whole custody discovery for non-Help metadata")
    func coupledFootprintDoesNotRepeatWholeOwnershipAtEveryMetadataRow() async throws {
        let f = try Fixture()
        f.measuringFootprintReads = true
        try await assertCanonicalPhysicalOutput(mode: "coupled_menu_overlay", fixture: f)
        let footprints = f.footprintReads.filter {
            $0.value.names.count == f.strips.count && $0.value.help > 0 && $0.value.record > 0
        }
        #expect(!footprints.isEmpty, "Reach actual post-name complete protected reads and physical Help reads")
        for (key, sample) in footprints {
            let censuses = f.footprintTransportCensuses[key, default: 0]
            #expect(censuses > 0 && censuses <= sample.help,
                "Keep one fresh shared transport census per actual Help read, not additional complete censuses per non-Help row")
            #expect(sample.record <= 2 * sample.help,
                "Both fresh stopped-value bookends belong to that same single transport decision")
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

    private static func finalOutputLabel(mode: String, busDeparture: Bool, noOutput: Bool, noOutputReturn: Bool) -> String {
        if busDeparture {
            switch mode {
            case "cancel", "late_peer", "late_project", "ack_only": return "Bus 2"
            default: break
            }
        }
        if noOutput {
            if mode == "newer" { return "Output 5-6" }
            if noOutputReturn {
                return ["late_peer", "late_project"].contains(mode) ? "No Output" : "Stereo Output"
            }
            return ["cancel", "late_peer", "late_project", "ack_only"].contains(mode) ? "Stereo Output" : "No Output"
        }
        switch mode {
        case "newer": return "Output 5-6"
        case "cancel", "late_peer", "stereo", "no_op", "ack_only", "late_project", "late_peer_send", "unoffered_physical":
            return "Stereo Output"
        default: return "Output 3-4"
        }
    }

    private func assertCanonicalPhysicalOutput(mode requestedMode: String, fixture: Fixture? = nil,
                                               foreignFocusAtDocumentRead: Int? = nil,
                                               refusingSampledTrackOwnership: Bool = false) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                try await runCanonicalPhysicalOutput(mode: requestedMode, fixture: fixture,
                    foreignFocusAtDocumentRead: foreignFocusAtDocumentRead,
                    refusingSampledTrackOwnership: refusingSampledTrackOwnership)
            }
        }
    }

    private func runCanonicalPhysicalOutput(mode requestedMode: String, fixture: Fixture?,
                                            foreignFocusAtDocumentRead: Int?,
                                            refusingSampledTrackOwnership: Bool) async throws {
        let survivingSource = requestedMode.hasPrefix("surviving_")
        let profile = survivingSource ? String(requestedMode.dropFirst("surviving_".count)) : requestedMode
        let busDeparture = profile.hasPrefix("bus_departure_")
            ? String(profile.dropFirst("bus_departure_".count)) : nil
        let executingBusDeparture = busDeparture?.hasPrefix("execute_") == true
        let rawBusMode = executingBusDeparture ? String(busDeparture!.dropFirst("execute_".count)) : busDeparture
        let busArrival = rawBusMode?.hasPrefix("arrival") == true
        let busScenario = busArrival ? (rawBusMode == "arrival" ? "stereo" : String(rawBusMode!.dropFirst("arrival_".count))) : rawBusMode
        let busReplacement = busScenario?.hasPrefix("replacement") == true
        let replacementScenario = busScenario == "replacement" ? "forward"
            : busReplacement ? String(busScenario!.dropFirst("replacement_".count)) : nil
        let noOutput = profile.hasPrefix("canonical_no_output")
        let noOutputReturn = profile.hasPrefix("canonical_no_output_return")
        let nativeApplicationFocus = noOutput && profile.hasSuffix("_app_focus")
        let nativeForeignApplication = profile.hasSuffix("_foreign_app_focus")
        let nativeNoWindow = profile.hasSuffix("_no_value_app_focus")
        let nativeUnreadWindow = profile.hasSuffix("_unread_window_app_focus")
        let nativeAbsentWindow = profile.hasSuffix("_absent_window_app_focus")
        let nativeForeignWindow = profile.hasSuffix("_foreign_window_app_focus")
        let nativeRefusingWindow = nativeUnreadWindow || nativeAbsentWindow || nativeForeignWindow
        let outputMode = executingBusDeparture ? (replacementScenario ?? busScenario!)
            : !noOutput ? profile : profile == "canonical_no_output" ? "forward"
            : String(profile.dropFirst("canonical_no_output_".count))
        let prerequisiteFault = executingBusDeparture && outputMode.hasPrefix("prereq_")
        let inputPopupFocus = executingBusDeparture && outputMode.hasPrefix("popup_")
        let sourceInputPopup = executingBusDeparture && (outputMode.hasPrefix("popup_source") || outputMode == "popup_both_retired")
        let physicalBusInput = busScenario == "physical_input" || (executingBusDeparture
            && (["physical_input", "physical_cancel", "changed_source_input"].contains(outputMode)
                || outputMode == "prereq_physical_editor" || sourceInputPopup))
        let changedBusInput = executingBusDeparture && ["changed_source_input", "changed_receiver_input"].contains(outputMode)
        let misleadingBeforeReceiver = busReplacement && executingBusDeparture && outputMode == "misleading_before"
        let misleadingReceiver = misleadingBeforeReceiver || (executingBusDeparture && (outputMode == "misleading_receiver"
            || (busReplacement && outputMode == "misleading_after")))
        let mode = inputPopupFocus ? "forward" : physicalBusInput || changedBusInput ? (outputMode == "physical_input" ? "forward" : "cancel")
            : outputMode.hasPrefix("return_late_") ? String(outputMode.dropFirst("return_".count)) : outputMode
        let destinationLeafLabel = noOutput ? "No Output" : "Output 3-4"
                let f = try fixture ?? Fixture(fourTracks: busReplacement), cache = StateCache(), registry = TargetRegistry()
                @Sendable func mixerRows() -> [AXUIElement] {
                    [f.routingOtherReplacement ?? f.strips[0], f.routingReplacement ?? f.strips[1]]
                        + Array(f.strips.dropFirst(2))
                }
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
                    if nativeApplicationFocus, f.routingNativePopupFrame != nil,
                       ApprovedSessionRepair.outputLeafPermission != nil,
                       CFEqual(element, f.app), attribute == kAXFocusedWindowAttribute as String {
                        if nativeNoWindow || nativeRefusingWindow { f.routingLateScopeInjected = true }
                        if nativeNoWindow { return .failure(.init(raw: AXError.noValue.rawValue)) }
                        if nativeUnreadWindow { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
                        if nativeAbsentWindow { return .success(nil) }
                        if nativeForeignWindow { return .success(f.builder.element(1_973_198)) }
                    }
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
                let scrollView = f.builder.element(1_975_400), scrollRoot = f.builder.element(1_975_401)
                let scrollTo = f.builder.element(1_975_402), scrollSubmenu = f.builder.element(1_975_403)
                let scrollOutput = f.builder.element(1_975_404), scrollAudio = f.builder.element(1_975_405)
                if mode.hasPrefix("offscreen_peer") {
                    for (index, strip) in f.strips.enumerated() {
                        f.builder.setFrame(strip, x: CGFloat(index) * 100, y: 100, width: 100, height: 300)
                    }
                    for (element, role, title) in [
                        (scrollView, kAXMenuButtonRole, AXLocalePolicy.viewMenuBar.canonical),
                        (scrollRoot, kAXMenuRole, ""),
                        (scrollTo, kAXMenuItemRole, AXLocalePolicy.mixerScrollToMenuItem.canonical),
                        (scrollSubmenu, kAXMenuRole, ""),
                        (scrollOutput, kAXMenuItemRole, AXLocalePolicy.mixerScrollToOutputsMenuItem.canonical),
                        (scrollAudio, kAXMenuItemRole, AXLocalePolicy.mixerTypeFilterAudio.canonical)
                    ] {
                        f.builder.setRole(element, role as String)
                        f.builder.setAttribute(element, kAXTitleAttribute as String, title)
                        f.builder.setAttribute(element, kAXEnabledAttribute as String, true)
                        f.builder.setAttribute(element, kAXWindowAttribute as String, f.window)
                        f.builder.setActionNames(element, [kAXPressAction as String, kAXCancelAction as String])
                    }
                    f.builder.setChildren(scrollSubmenu, [scrollOutput, scrollAudio])
                    f.builder.setChildren(scrollTo, [scrollSubmenu])
                    f.builder.setChildren(scrollRoot, [scrollTo])
                    f.builder.setChildren(scrollView, [])
                    f.builder.setChildren(outer, f.builder.makeAXRuntime().children(outer) + [scrollView])
                }
                let root = f.builder.element(1_973_110), parent = f.builder.element(1_973_111)
                let submenu = f.builder.element(1_973_112), stereo = f.builder.element(1_973_113)
                let physical = f.builder.element(1_973_114)
                let echo = f.builder.element(1_973_115)
                let busParent = f.builder.element(1_973_310), busMenu = f.builder.element(1_973_311)
                let busTwo = f.builder.element(1_973_312)
                let sourceBusInput = f.builder.element(1_973_314)
                let inputParent = f.builder.element(1_973_315), inputMenu = f.builder.element(1_973_316)
                let physicalInput = f.builder.element(1_973_317)
                let inputSearch = f.builder.element(1_973_320)
                if inputPopupFocus {
                    f.builder.setRole(inputSearch, kAXTextFieldRole as String)
                    f.builder.setAttribute(inputSearch, kAXValueAttribute as String, "")
                    f.builder.setAttribute(inputSearch, kAXWindowAttribute as String, f.window)
                    f.builder.setChildren(inputSearch, [])
                }
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
                    if mode == "late_peer", CFEqual(element, noOutputReturn ? stereo : busArrival ? busTwo : physical), attribute == kAXEnabledAttribute as String,
                       !busArrival || ApprovedSessionRepair.outputLeafPermission != nil,
                       f.routingOpenedOutputIndex == 1, f.inputMenuPresses > 1, !f.routingLateScopeInjected {
                        f.routingLateScopeInjected = true
                        f.builder.setAttribute(f.builder.element(1_973_121), kAXValueAttribute as String, NSNumber(value: 0.4))
                    }
                    if mode == "late_project", CFEqual(element, noOutputReturn ? stereo : busArrival ? busTwo : physical), attribute == kAXEnabledAttribute as String,
                       !busArrival || ApprovedSessionRepair.outputLeafPermission != nil,
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
                if busDeparture != nil {
                    f.builder.setAttribute(outputs[1], kAXDescriptionAttribute as String,
                        busReplacement ? "Bus 3" : busArrival && busScenario != "bus_before"
                            ? (busScenario == "physical_before" ? "Output 3-4" : "Stereo Output") : "Bus 2")
                    let receiverInput = f.builder.element(1_973_313)
                    f.builder.setButton(receiverInput, description: "Bus 2",
                        help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 1, height: 1)
                    f.builder.setChildren(receiverInput, [])
                    f.builder.setActionNames(receiverInput, [kAXPressAction as String])
                    if busScenario != "no_receiver", replacementScenario != "no_after_receiver" {
                        f.builder.setChildren(f.strips[0], f.builder.makeAXRuntime().children(f.strips[0]) + [receiverInput])
                    }
                    if busReplacement, replacementScenario != "no_before_receiver" {
                        let beforeReceiverInput = f.builder.element(1_973_319)
                        f.builder.setButton(beforeReceiverInput, description: "Bus 3",
                            help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 1, height: 1)
                        f.builder.setChildren(beforeReceiverInput, [])
                        f.builder.setActionNames(beforeReceiverInput, [kAXPressAction as String])
                        f.builder.setChildren(f.strips[2], f.builder.makeAXRuntime().children(f.strips[2]) + [beforeReceiverInput])
                    }
                    if physicalBusInput || ["own_bus_input", "misleading_input"].contains(busScenario) {
                        f.builder.setButton(sourceBusInput, description: busScenario == "own_bus_input" ? "Bus 2" : "Input 1",
                            help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 1, height: 1)
                        f.builder.setActionNames(sourceBusInput, [kAXPressAction as String])
                        f.builder.setChildren(sourceBusInput, [])
                        f.builder.setChildren(f.strips[1], f.builder.makeAXRuntime().children(f.strips[1]) + [sourceBusInput])
                    }
                    if physicalBusInput {
                        for (element, role) in [(inputParent, kAXMenuItemRole), (inputMenu, kAXMenuRole),
                                                (physicalInput, kAXMenuItemRole)] {
                            f.builder.setRole(element, role as String)
                        }
                        f.builder.setAttribute(inputParent, kAXTitleAttribute as String, "Input")
                        f.builder.setAttribute(physicalInput, kAXTitleAttribute as String, "Input 1")
                        f.builder.setAttribute(physicalInput, "AXMenuItemMarkChar", "✓")
                        f.builder.setChildren(physicalInput, [])
                        f.builder.setChildren(inputMenu, [physicalInput]); f.builder.setChildren(inputParent, [inputMenu])
                    }
                    f.builder.setRole(busParent, kAXMenuItemRole as String)
                    f.builder.setAttribute(busParent, kAXTitleAttribute as String, "Bus")
                    f.builder.setRole(busMenu, kAXMenuRole as String)
                    f.builder.setRole(busTwo, kAXMenuItemRole as String)
                    f.builder.setAttribute(busTwo, kAXTitleAttribute as String, "Bus 2")
                    f.builder.setAttribute(busTwo, kAXEnabledAttribute as String, true)
                    f.builder.setChildren(busTwo, [])
                    f.builder.setChildren(busMenu, [busTwo]); f.builder.setChildren(busParent, [busMenu])
                    let busThree = f.builder.element(1_973_318)
                    f.builder.setRole(busThree, kAXMenuItemRole as String)
                    f.builder.setAttribute(busThree, kAXTitleAttribute as String, "Bus 3")
                    f.builder.setAttribute(busThree, kAXEnabledAttribute as String, true)
                    f.builder.setChildren(busThree, [])
                    f.builder.setChildren(busMenu, [busTwo, busThree])
                }
                if noOutputReturn {
                    f.builder.setAttribute(outputs[1], kAXDescriptionAttribute as String, "No Output")
                } else if noOutput && mode == "physical_before" {
                    f.builder.setAttribute(outputs[1], kAXDescriptionAttribute as String, "Output 3-4")
                }
                f.builder.setAttribute(physical, kAXTitleAttribute as String, destinationLeafLabel)
                f.builder.setAttribute(stereo, kAXEnabledAttribute as String, true)
                f.builder.setAttribute(physical, kAXEnabledAttribute as String, true)
                f.builder.setChildren(stereo, []); f.builder.setChildren(physical, [])
                f.builder.setChildren(submenu, mode == "unoffered_physical" || noOutput ? [stereo] : [stereo, physical]); f.builder.setChildren(parent, [submenu])
                if noOutput && mode == "physical_before" {
                    let checkedPhysical = f.builder.element(1_973_118)
                    f.builder.setRole(checkedPhysical, kAXMenuItemRole as String)
                    f.builder.setAttribute(checkedPhysical, kAXTitleAttribute as String, "Output 3-4")
                    f.builder.setAttribute(checkedPhysical, "AXMenuItemMarkChar", "✓")
                    f.builder.setChildren(checkedPhysical, [])
                    f.builder.setChildren(submenu, [stereo, checkedPhysical])
                }
                f.builder.setChildren(root, noOutput ? [echo, physical, parent] : [echo, parent]); f.builder.setActionNames(root, [kAXCancelAction as String])
                if busDeparture != nil { f.builder.setChildren(root, [echo, parent, busParent]) }
                let nativeWrapper = f.builder.element(1_973_119)
                let nativeFrame = CGRect(x: 20, y: 100, width: 230, height: 175)
                if noOutput {
                    if nativeApplicationFocus { f.builder.setRole(f.app, kAXApplicationRole as String) }
                    f.builder.setRole(nativeWrapper, kAXPopUpButtonRole as String)
                    f.builder.setAttribute(nativeWrapper, kAXParentAttribute as String, f.mixer)
                    f.builder.setAttribute(nativeWrapper, kAXWindowAttribute as String, f.window)
                    f.builder.setFrame(root, x: 20, y: 100, width: 230, height: 175)
                    f.routingFocusHit = { app, point in
                        #expect(CFEqual(app, f.app))
                        #expect(point == CGPoint(x: nativeFrame.midX, y: nativeFrame.midY))
                        return .success(f.routingNativePopupFrame == nil ? nil : physical)
                    }
                }
                f.routingAction = { element, action in
                    if mode.hasPrefix("offscreen_peer"), action == kAXPressAction as String {
                        if CFEqual(element, scrollView) {
                            f.builder.setChildren(scrollView, [scrollRoot])
                            return true
                        }
                        if CFEqual(element, scrollOutput) || CFEqual(element, scrollAudio) {
                            // Scroll exposes the unchanged host value; this is
                            // not a destination leaf or another audio write.
                            f.builder.setAttribute(outputs[3], kAXDescriptionAttribute as String, "Stereo Output")
                            if mode == "offscreen_peer_checked_change", CFEqual(element, scrollAudio) {
                                f.scrollToChangedOutput = true
                            }
                            let offset: CGFloat = CFEqual(element, scrollOutput) ? -100 : 0
                            for (index, strip) in f.strips.enumerated() {
                                f.builder.setFrame(strip, x: CGFloat(index) * 100 + offset, y: 100, width: 100, height: 300)
                            }
                            f.builder.setChildren(scrollView, [])
                            return true
                        }
                    }
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
                    if action == kAXPressAction as String, busDeparture != nil,
                       CFEqual(element, f.builder.element(1_973_313)) {
                        let wrongBus = (misleadingReceiver && !misleadingBeforeReceiver)
                            || (outputMode == "changed_receiver_input" && f.routingLateScopeInjected)
                        f.builder.setAttribute(echo, kAXTitleAttribute as String, "Bus 2")
                        f.builder.setAttribute(busTwo, "AXMenuItemMarkChar", wrongBus ? "" : "✓")
                        f.builder.setAttribute(f.builder.element(1_973_318), "AXMenuItemMarkChar", wrongBus ? "✓" : "")
                        f.builder.setChildren(root, [echo, busParent])
                        if outputMode == "popup_receiver" || outputMode == "popup_both_retired" {
                            f.builder.setChildren(root, [inputSearch, echo, busParent])
                            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, inputSearch)
                        }
                        f.builder.setChildren(f.mixer, mixerRows() + [root])
                        f.inputMenuPresses += 1
                        return true
                    }
                    if action == kAXPressAction as String, busReplacement,
                       CFEqual(element, f.builder.element(1_973_319)) {
                        f.builder.setAttribute(echo, kAXTitleAttribute as String, "Bus 3")
                        f.builder.setAttribute(busTwo, "AXMenuItemMarkChar", misleadingBeforeReceiver ? "✓" : "")
                        f.builder.setAttribute(f.builder.element(1_973_318), "AXMenuItemMarkChar", misleadingBeforeReceiver ? "" : "✓")
                        f.builder.setChildren(root, [echo, busParent])
                        f.builder.setChildren(f.mixer, mixerRows() + [root])
                        f.inputMenuPresses += 1
                        return true
                    }
                    if action == kAXPressAction as String,
                       physicalBusInput || ["own_bus_input", "misleading_input"].contains(busScenario), CFEqual(element, sourceBusInput) {
                        let physical = physicalBusInput && !(outputMode == "changed_source_input" && f.routingLateScopeInjected)
                        f.builder.setAttribute(echo, kAXTitleAttribute as String, physical ? "Input 1" : "Bus 2")
                        f.builder.setAttribute(stereo, "AXMenuItemMarkChar", "")
                        f.builder.setAttribute(f.builder.element(1_973_114), "AXMenuItemMarkChar", "")
                        f.builder.setAttribute(busTwo, "AXMenuItemMarkChar", physical ? "" : "✓")
                        f.builder.setAttribute(physicalInput, "AXMenuItemMarkChar", physical ? "✓" : "")
                        f.builder.setAttribute(f.builder.element(1_973_318), "AXMenuItemMarkChar", "")
                        f.builder.setChildren(root, [echo] + (physicalBusInput ? [inputParent] : [parent]) + [busParent])
                        if sourceInputPopup {
                            f.builder.setChildren(root, [inputSearch, echo, inputParent, busParent])
                            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, inputSearch)
                        }
                        f.builder.setChildren(f.mixer, mixerRows() + [root])
                        f.inputMenuPresses += 1
                        return true
                    }
                    if action == kAXPressAction as String,
                       let index = outputs.firstIndex(where: { CFEqual($0, element) }) {
                        let label = f.builder.attributeValue(outputs[index], kAXDescriptionAttribute as String) as? String
                        f.builder.setAttribute(echo, kAXTitleAttribute as String, label)
                        if busDeparture != nil { f.builder.setChildren(root, [echo, parent, busParent]) }
                        if noOutput {
                            // A neutral menu has one checked root leaf, not both
                            // a checked title echo and a second checked No Output.
                            f.builder.setChildren(root, label == "No Output" ? [physical, parent] : [echo, physical, parent])
                        }
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
                        f.builder.setAttribute(physical, "AXMenuItemMarkChar", label == destinationLeafLabel ? "✓" : "")
                        if busDeparture != nil {
                            let checked = index == 1 && f.scrollToChangedOutput ? "Bus 3" : label
                            f.builder.setAttribute(busTwo, "AXMenuItemMarkChar", checked == "Bus 2" ? "✓" : "")
                            f.builder.setAttribute(f.builder.element(1_973_318), "AXMenuItemMarkChar", checked == "Bus 3" ? "✓" : "")
                        }
                        if noOutput, label == "No Output" {
                            // Model the qualified host's neutral popup: it is
                            // a native window, not a Mixer AXChildren menu.
                            f.builder.setChildren(nativeWrapper, [root])
                            f.routingNativePopupFrame = nativeFrame
                            if nativeApplicationFocus, ApprovedSessionRepair.outputLeafPermission != nil {
                                f.routingNativeApplicationFocusWrites += 1
                                let foreign = f.builder.element(1_973_199)
                                f.builder.setRole(foreign, kAXApplicationRole as String)
                                let injectingForeign = nativeForeignApplication && ApprovedSessionRepair.outputLeafPermission != nil
                                if injectingForeign { f.routingLateScopeInjected = true }
                                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                                    injectingForeign ? foreign : f.app)
                            }
                            f.builder.setChildren(f.mixer, mixerRows())
                        } else {
                            f.routingNativePopupFrame = nil
                            f.builder.setChildren(f.mixer, mixerRows() + [root])
                        }
                        f.inputMenuPresses += 1
                        return true
                    }
                    if CFEqual(element, root), action == kAXCancelAction as String {
                        f.routingNativePopupFrame = nil
                        if mode == "offscreen_peer_intermediate_viewport", f.scrollToViewportDriftEnabled,
                           f.routingDestinationPresses == 0,
                           f.routingOpenedOutputIndex == nil {
                            // A native input excursion can shift the viewport
                            // before a later source read needs peer recovery.
                            for (index, strip) in f.strips.enumerated() {
                                f.builder.setFrame(strip, x: CGFloat(index) * 100 - 100, y: 100, width: 100, height: 300)
                            }
                            f.scrollToViewportShifted = true
                        }
                        if mode.hasPrefix("offscreen_peer"), f.routingDestinationPresses == 1,
                           f.routingOpenedOutputIndex == nil {
                            // Native counterexample: input-popup Cancel retires
                            // the old presentation and an offscreen peer loses
                            // its rendered slot value, without an audio write.
                            f.routingLateScopeInjected = true
                            f.builder.setAttribute(outputs[3], kAXDescriptionAttribute as String, "Output")
                        }
                        if ["popup_source_retired", "popup_both_retired"].contains(outputMode), f.inputMenuPresses > 2, f.routingReplacement == nil {
                            let replacement = f.builder.element(1_973_140)
                            f.builder.setRole(replacement, kAXLayoutItemRole as String)
                            f.builder.setAttribute(replacement, kAXNumberOfCharactersAttribute as String, 0)
                            f.builder.setAttribute(replacement, kAXInsertionPointLineNumberAttribute as String, 0)
                            f.builder.setChildren(replacement, f.builder.makeAXRuntime().children(f.strips[1]))
                            f.routingReplacement = replacement
                            if outputMode == "popup_both_retired" {
                                let peer = f.builder.element(1_973_141)
                                f.builder.setRole(peer, kAXLayoutItemRole as String)
                                f.builder.setAttribute(peer, kAXNumberOfCharactersAttribute as String, 0)
                                f.builder.setAttribute(peer, kAXInsertionPointLineNumberAttribute as String, 0)
                                f.builder.setChildren(peer, f.builder.makeAXRuntime().children(f.strips[0]))
                                f.routingOtherReplacement = peer
                            }
                        }
                        if outputMode == "popup_both_retired", f.routingOtherReplacement != nil,
                           f.builder.attributeValue(echo, kAXTitleAttribute as String) as? String == "Bus 2",
                           f.routingOpenedOutputIndex == nil, !f.routingLateScopeInjected {
                            f.routingLateScopeInjected = true
                            let source = f.builder.element(1_973_142), peer = f.builder.element(1_973_143)
                            for (replacement, prior) in [(source, f.routingReplacement!), (peer, f.routingOtherReplacement!)] {
                                f.builder.setRole(replacement, kAXLayoutItemRole as String)
                                f.builder.setAttribute(replacement, kAXNumberOfCharactersAttribute as String, 0)
                                f.builder.setAttribute(replacement, kAXInsertionPointLineNumberAttribute as String, 0)
                                f.builder.setChildren(replacement, f.builder.makeAXRuntime().children(prior))
                            }
                            f.routingReplacement = source; f.routingOtherReplacement = peer
                        }
                        if inputPopupFocus {
                            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.routingReplacement ?? f.strips[1])
                        }
                        if nativeApplicationFocus {
                            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.routingReplacement ?? f.strips[1])
                        }
                        f.routingOpenedOutputIndex = nil
                        f.builder.setChildren(f.mixer, mixerRows())
                        f.inputMenuCancels += 1; return true
                    }
                    if action == kAXPressAction as String,
                       CFEqual(element, physical) || CFEqual(element, stereo) || (executingBusDeparture && CFEqual(element, busTwo))
                        || (busReplacement && CFEqual(element, f.builder.element(1_973_318))),
                       let index = f.routingOpenedOutputIndex {
                        f.routingDestinationPresses += 1
                        if mode != "ack_only" {
                            f.builder.setAttribute(outputs[index], kAXDescriptionAttribute as String,
                                CFEqual(element, physical) ? destinationLeafLabel : CFEqual(element, busTwo) ? "Bus 2"
                                    : busReplacement && CFEqual(element, f.builder.element(1_973_318)) ? "Bus 3" : "Stereo Output")
                        }
                        f.routingOpenedOutputIndex = nil
                        f.routingNativePopupFrame = nil
                        if nativeApplicationFocus {
                            f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.routingReplacement ?? f.strips[1])
                        }
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
                        f.builder.setChildren(f.mixer, mixerRows())
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
                if mode == "offscreen_peer_intermediate_viewport" { f.scrollToViewportDriftEnabled = true }
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
                    $0.source.matches(pair.strip) && $0.assignment == (busReplacement ? .bus(3) : busArrival && busScenario != "bus_before" ? (busScenario == "physical_before" ? .physical(3, 4) : .stereoOutput) : busDeparture != nil ? .bus(2) : noOutputReturn ? .noOutput : mode == "stereo" || mode == "physical_before" ? .physical(3, 4) : .stereoOutput) && $0.sendOrdinal == nil
                }.count == 1, "Actual outputs=\(capture.channelStrips.map(\.output)), Help reads=\(f.routingClassifierHelpReads), presses=\(f.inputMenuPresses), stable=\(capture.freshPopulation?.stable)")
                let expectedAcquisitionMenus = physicalBusInput || ["own_bus_input", "misleading_input"].contains(busScenario) ? 2 : 1
                #expect(f.inputMenuPresses == expectedAcquisitionMenus && f.inputMenuCancels == expectedAcquisitionMenus && f.routingDestinationPresses == 0)
                let target = try #require(capture.issued?.byRow[0])
                guard case .issued(let project)? = capture.projectIssuance else {
                    Issue.record("Actual capture must issue the project"); return
                }
                var raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(project.rawValue),
                    "targets": .array([.object(["handle": .string("source"), "track_ref": .string(target.rawValue)])]),
                    "outputs": .array([.object(["target": .string("source"),
                        "output": mode == "return_physical" ? .object(["kind": .string("physical"), "ports": .array([.int(3), .int(4)])])
                            : busDeparture == "no_output" || mode == "preview_no_output" || (noOutput && !noOutputReturn) ? .string("no_output")
                            : busDeparture == "stereo" || noOutputReturn || mode == "stereo" || mode == "no_op" ? .object(["kind": .string("stereo_output")])
                            : .object(["kind": .string("physical"), "ports": .array([.int(3), .int(4)])])])])]
                if busArrival {
                    raw["outputs"] = .array([.object(["target": .string("source"), "bus": .int(2)])])
                }
                if busScenario == "mixed_input" || (busReplacement && replacementScenario == "mixed_input") {
                    raw["inputs"] = .array([.object(["target": .string("source"), "bus": .int(2)])])
                }
                guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
                    Issue.record("The explicit typed physical output must parse"); return
                }
                if let busDeparture, !executingBusDeparture {
                    let names: [ProjectSessionAudit.ApprovedName] = busScenario == "mixed_name" || (busReplacement && replacementScenario == "mixed_name")
                        ? [.init(target: "source", name: "Selected Canonical")] : []
                    let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
                        names: names, capture: capture, request: retained.request, snapshotCurrent: true)
                    let preview = try #require(sharedJSONObject(plan.json))
                    let executable = try #require(preview["executable"] as? Bool)
                    let supported = busArrival ? ["stereo", "physical_before", "physical_input", "replacement"].contains(busScenario)
                        : ["physical", "stereo", "physical_input"].contains(busDeparture)
                    if supported { #expect(executable) } else { #expect(!executable) }
                    let verifiable = ApprovedSessionRepair.canVerifyCapturedGoals(policy: policy,
                        policyValue: .object(raw), names: names, source: capture, request: retained.request)
                    if supported { #expect(verifiable) } else { #expect(!verifiable) }
                    #expect(await cache.retainRepairPlan(plan, snapshotID: id))
                    let approval = await ApprovedSessionRepair.retained(id: plan.id, digest: plan.digest,
                        key: "bus-departure-preview-" + busDeparture, cache: cache, registry: registry, journal: SagaJournal())
                    if supported {
                        let step = try #require((preview["steps"] as? [[String: Any]])?.first)
                        #expect(step["kind"] as? String == "local_output")
                        if busArrival {
                            #expect((step["before"] as? [String: Any])?["kind"] as? String
                                == (busReplacement ? "bus" : busScenario == "physical_before" ? "physical" : "stereo_output"))
                            if busReplacement { #expect((step["before"] as? [String: Any])?["number"] as? Int == 3) }
                            if busScenario == "physical_before" {
                                #expect((step["before"] as? [String: Any])?["ports"] as? [Int] == [3, 4])
                            }
                            #expect((step["after"] as? [String: Any])?["number"] as? Int == 2)
                        } else {
                            #expect((step["before"] as? [String: Any])?["number"] as? Int == 2)
                        }
                        #expect(approval != nil)
                    } else { #expect(approval == nil) }
                    #expect(f.routingDestinationPresses == 0 && f.routingNameWrites.isEmpty)
                    return
                }
                if noOutput && ["mixed_name", "physical_before", "return_physical"].contains(mode) {
                    let rejectedNames: [ProjectSessionAudit.ApprovedName] = mode == "mixed_name"
                        ? [.init(target: "source", name: "Selected Canonical")] : []
                    let blocked = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy,
                        policyValue: .object(raw), names: rejectedNames, capture: capture,
                        request: retained.request, snapshotCurrent: true)
                    let preview = try #require(sharedJSONObject(blocked.json))
                    let executable = try #require(preview["executable"] as? Bool)
                    #expect(!executable)
                    #expect(!ApprovedSessionRepair.canVerifyCapturedGoals(policy: policy, policyValue: .object(raw),
                        names: rejectedNames, source: capture, request: retained.request))
                    #expect(await cache.retainRepairPlan(blocked, snapshotID: id))
                    #expect(await ApprovedSessionRepair.retained(id: blocked.id, digest: blocked.digest,
                        key: "blocked-no-output-" + mode, cache: cache, registry: registry, journal: SagaJournal()) == nil)
                    #expect(f.routingDestinationPresses == 0 && f.routingNameWrites.isEmpty)
                    return
                }
                if mode == "mixed_input" {
                    #expect(ApprovedSessionRepair.canVerifyCapturedGoals(policy: policy, policyValue: .object(raw),
                        names: [], source: capture, request: retained.request),
                        "Reach a genuinely supported output before adding the unavailable input task")
                    var mixed = raw
                    mixed["inputs"] = .array([.object(["target": .string("source"), "bus": .int(2)])])
                    guard case .accepted(let mixedPolicy) = ProjectSessionAudit.parseIntentPolicy(mixed) else {
                        Issue.record("The explicit mixed policy must parse"); return
                    }
                    let blocked = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: mixedPolicy,
                        policyValue: .object(mixed), names: [], capture: capture,
                        request: retained.request, snapshotCurrent: true)
                    let preview = try #require(sharedJSONObject(blocked.json))
                    let executable = try #require(preview["executable"] as? Bool)
                    #expect(!executable)
                    let steps = try #require(preview["steps"] as? [[String: Any]])
                    #expect(steps.contains { $0["kind"] as? String == "input_assignment" })
                    #expect(!ApprovedSessionRepair.canVerifyCapturedGoals(policy: mixedPolicy,
                        policyValue: .object(mixed), names: [], source: capture, request: retained.request))
                    #expect(await cache.retainRepairPlan(blocked, snapshotID: id))
                    let approved = await ApprovedSessionRepair.retained(id: blocked.id, digest: blocked.digest,
                        key: "blocked-mixed-input", cache: cache, registry: registry, journal: SagaJournal())
                    #expect(approved == nil)
                    #expect(f.routingDestinationPresses == 0)
                    return
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
                if mode == "preview_no_output" {
                    #expect(executable, "The already-checked singleton must support an explicit No Output preview")
                    let steps = try #require(body["steps"] as? [[String: Any]])
                    #expect(steps.count == 1)
                    let step = try #require(steps.first)
                    #expect(step["kind"] as? String == "local_output")
                    #expect(step["target_ref"] as? String == target.rawValue)
                    #expect((step["before"] as? [String: Any])?["kind"] as? String == "stereo_output")
                    #expect((step["after"] as? [String: Any])?["kind"] as? String == "no_output")
                    #expect(ApprovedSessionRepair.canVerifyCapturedGoals(policy: policy, policyValue: .object(raw),
                        names: [], source: capture, request: retained.request))
                    #expect(f.routingDestinationPresses == 0, "No Output preview must not disconnect the source")
                    return
                }
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
                    #expect((steps.last?["before"] as? [String: Any])?["kind"] as? String == (busReplacement || (executingBusDeparture && !busArrival) ? "bus" : noOutputReturn ? "no_output" : mode == "stereo" || (busArrival && busScenario == "physical_before") ? "physical" : "stereo_output"))
                #expect((steps.last?["after"] as? [String: Any])?["kind"] as? String == (busArrival ? "bus" : noOutput && !noOutputReturn ? "no_output" : noOutputReturn || mode == "stereo" || mode == "no_op" ? "stereo_output" : "physical"))
                #expect(await cache.retainRepairPlan(plan, snapshotID: id))
                let journal = SagaJournal(), key = "captured-physical-output-" + mode
                let approval = try #require(await ApprovedSessionRepair.retained(id: plan.id, digest: plan.digest,
                    key: key, cache: cache, registry: registry, journal: journal))
                let busPreExecutionReads = f.inputMenuPresses
                if executingBusDeparture, outputMode == "external_peer" {
                    let replacement = f.builder.element(1_973_141)
                    f.builder.setRole(replacement, kAXLayoutItemRole as String)
                    f.builder.setAttribute(replacement, kAXNumberOfCharactersAttribute as String, 0)
                    f.builder.setAttribute(replacement, kAXInsertionPointLineNumberAttribute as String, 0)
                    f.builder.setChildren(replacement, f.builder.makeAXRuntime().children(f.strips[0]))
                    f.routingOtherReplacement = replacement
                    f.builder.setChildren(f.mixer, [replacement, f.strips[1]])
                }
                if prerequisiteFault {
                    let previous = f.routingRead
                    f.routingRead = { element, attribute in
                        previous?(element, attribute)
                        let button = outputMode == "prereq_receiver_document" ? outputs[0] : outputs[1]
                        if !f.routingLateScopeInjected, CFEqual(element, button), attribute == kAXRoleAttribute as String {
                            f.routingLateScopeInjected = true
                            if outputMode.hasSuffix("document") {
                                f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            } else {
                                let editor = f.builder.element(1_973_319)
                                f.builder.setRole(editor, kAXTextFieldRole as String)
                                f.builder.setAttribute(editor, kAXValueAttribute as String, "Uncommitted")
                                f.builder.setAttribute(editor, kAXWindowAttribute as String, f.window)
                                f.builder.setChildren(editor, [])
                                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, editor)
                            }
                        }
                        if f.routingLateScopeInjected, attribute == kAXHelpAttribute as String { f.inputForeignScopeHelpReads += 1 }
                    }
                }
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
                } else if noOutput || executingBusDeparture {
                    await router.register(SelectedOutputSagaResultBoundary(f.channel(), shouldFail: false, observed: { response in
                        f.routingOutputChannelStates.append(response.message)
                    }))
                } else { await router.register(f.channel()) }
                let applyDependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                    poller: StatePoller(axChannel: f.channel(), cache: cache, runtime: .init(hasVisibleWindow: { false })),
                    dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal,
                    mutationGate: LogicMutationGate(), liveTrackNames: { [:] }, projectFileReader: .unavailable)
                let applyHandler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "apply_session_repair"))
                let approvedParams: [String: Value] = ["plan_id": .string(plan.id), "digest": .string(plan.digest),
                    "confirmed": .bool(true), "idempotency_key": .string(key)]
                if composed || noOutput {
                    for (field, value) in [("confirmed", Value.bool(false)), ("digest", Value.string(String(repeating: "0", count: 64)))] {
                        var rejectedParams = approvedParams
                        rejectedParams[field] = value
                        let rejected = try #require(sharedJSONObject(sharedToolText(await applyHandler(applyDependencies, rejectedParams))))
                        #expect(rejected["state"] as? String == "C")
                        #expect(f.routingNameWrites.isEmpty && f.routingDestinationPresses == 0)
                    }
                }
                func run() async -> CallTool.Result {
                    if (noOutput && (mode == "forward" || noOutputReturn)) || mode == "coupled" || mode == "coupled_same" || menuOverlay {
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
                            if changedBusInput, f.routingDestinationPresses == 1 { f.routingLateScopeInjected = true }
                            if ["cancel", "newer", "ack_only"].contains(mode) { _ = await journal.cancel(idempotencyKey: key) }
                        }, sagaLiveReadback: .unavailable, approvedSessionRepair: approval)
                }
                let result = try #require(sharedJSONObject(sharedToolText(await run())))
                if executingBusDeparture, outputMode == "external_peer" {
                    #expect(f.routingOtherReplacement != nil && pair.strip.currentIndex(runtime: f.logic()) != nil)
                    #expect(f.routingDestinationPresses == 0 && f.inputMenuPresses == busPreExecutionReads,
                        "An externally replaced peer must refuse before owned observation can establish a new census")
                    #expect(result["saga_state"] as? String != "completed")
                    return
                }
                if outputMode == "popup_source_retired" {
                    #expect(f.routingReplacement != nil && pair.strip.currentIndex(runtime: f.logic()) == nil,
                        "The actual input Cancel must retire the original native source after capture")
                }
                if outputMode == "popup_both_retired" {
                    #expect(f.routingReplacement != nil && f.routingOtherReplacement != nil)
                    #expect(f.routingLateScopeInjected, "The receiver's own Cancel must also retire the current native census")
                    #expect(capture.channelStrips[0].physicalBinding?.currentIndex(runtime: f.logic()) == nil)
                }
                if prerequisiteFault {
                    #expect(f.routingLateScopeInjected, "Reach actual initial source/receiver traversal custody loss")
                    #expect(f.inputForeignScopeHelpReads == 0, "No physical Help may reach the host after native custody is lost")
                    #expect(f.routingDestinationPresses == 0)
                    #expect(result["saga_state"] as? String != "completed")
                    return
                }
                if changedBusInput || misleadingReceiver {
                    if changedBusInput { #expect(f.routingLateScopeInjected, "Change the actual input assignment only after the forward write") }
                    #expect(f.routingDestinationPresses == (misleadingReceiver ? 0 : 1),
                        "A contradictory checked input must not permit a Bus inverse or any initial output write")
                    #expect(result["saga_state"] as? String != "completed" && result["saga_state"] as? String != "fullyCompensated")
                    #expect(f.builder.attributeValue(outputs[1], kAXDescriptionAttribute as String) as? String
                        == (misleadingReceiver ? (busReplacement ? "Bus 3" : "Bus 2") : "Output 3-4"))
                    return
                }
                if executingBusDeparture, ["forward", "cancel", "retired"].contains(mode) {
                    let step = try #require((result["steps"] as? [[String: Any]])?.first)
                    let evidence = try #require(step["evidence"] as? [String: Any])
                    #expect((evidence["before_state"] as? [String: Any])?["observed"] as? String == (busReplacement ? "bus:3" : busArrival ? "stereo_output" : "bus:2"))
                    if mode == "cancel" {
                        let inverse = try #require(step["compensation"] as? [String: Any])
                        #expect(inverse["disposition"] as? String == "verified")
                        #expect((inverse["readback"] as? [String: Any])?["observed"] as? String == (busReplacement ? "bus:3" : busArrival ? "stereo_output" : "bus:2"))
                    }
                }
                if nativeApplicationFocus {
                    #expect(f.routingNativeApplicationFocusWrites > 0,
                        "Reach application focus at the actual approved return popup, after a valid initial capture")
                    if nativeNoWindow {
                        #expect(f.routingLateScopeInjected, "Reach the actual AXNoValue window response")
                    }
                }
                if nativeForeignApplication || nativeRefusingWindow {
                    #expect(f.routingLateScopeInjected, "Reach foreign focus or unread/absent/foreign window at the actual owned scalar popup")
                    let verified = try #require(result["verified"] as? Bool)
                    #expect(!verified && result["saga_state"] as? String != "completed")
                    #expect(f.routingDestinationPresses == 0)
                    #expect(f.builder.attributeValue(outputs[1], kAXDescriptionAttribute as String) as? String == "No Output")
                    return
                }
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
                if mode.hasPrefix("offscreen_peer") {
                    #expect(f.routingLateScopeInjected, "Reach the actual post-write input Cancel before judging recovery")
                    #expect(f.routingDestinationPresses == 1, "An unreadable peer does not authorize a guessed inverse")
                    if mode == "offscreen_peer_intermediate_viewport" {
                        #expect(f.scrollToViewportShifted, "Reach the owned input displacement after the capture")
                        let position = try #require(AXHelpers.getPosition(f.strips[0], runtime: f.logic().ax))
                        #expect(position.x == 0, "Restoration belongs to the first viewport, not the later displacement")
                    }
                    let verified = try #require(result["verified"] as? Bool)
                    if mode == "offscreen_peer_checked_change" {
                        #expect(f.scrollToChangedOutput)
                        #expect(result["saga_state"] as? String != "completed", "Do not publish the old pre-navigation checkmark")
                        #expect(!verified)
                    } else {
                        #expect(result["saga_state"] as? String == "completed", "The retained peer needs owned re-exposure and fresh final readback")
                        #expect(verified)
                    }
                    return
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
                    #expect(result["saga_state"] as? String == (mode == "cancel" ? "fullyCompensated" : "completed"), "\(result); output responses: \(f.routingOutputChannelStates)")
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
                let expectedOutputLabel = busArrival
                    ? (["cancel", "late_peer", "late_project"].contains(mode) ? (busReplacement ? "Bus 3" : "Stereo Output") : "Bus 2")
                    : Self.finalOutputLabel(mode: mode, busDeparture: executingBusDeparture,
                        noOutput: noOutput, noOutputReturn: noOutputReturn)
                let actualOutputLabel = f.builder.attributeValue(outputs[1], kAXDescriptionAttribute as String) as? String
                let outputLabelMatches = actualOutputLabel == expectedOutputLabel
                #expect(outputLabelMatches,
                    "actual=\(actualOutputLabel ?? "nil"), expected=\(expectedOutputLabel), profile=\(profile), mode=\(mode), composed=\(composed), census=\(redrawsCensus), neutral=\(noOutput), bus=\(executingBusDeparture)")
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

    @Test("Selected routing can corroborate newly readable peer displays without accepting changed known values",
          arguments: ["unchanged", "input", "output", "both", "known_input", "known_output",
                      "no_slot", "selected_input", "name", "whole_project", "later_input",
                      "later_owner", "later_slot", "later_project", "unclassified_output"])
    func selectedRoutingCorroboratesOnlyMonotonePeerObservations(profile: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture(withViewport: true), b = f.builder
            let outer = b.element(1_291_928)
            b.setRole(outer, kAXGroupRole as String); b.setAttribute(outer, kAXDescriptionAttribute as String, "Mixer")
            b.setRole(f.mixer, kAXLayoutAreaRole as String); b.setAttribute(f.mixer, kAXDescriptionAttribute as String, "Mixer")
            b.setChildren(outer, [f.mixer])
            b.setChildren(f.window, [f.rail, outer, b.element(1_965_720), f.scroll])
            let output = b.element(1_291_920), peerInput = b.element(1_291_921), peerOutput = b.element(1_291_922)
            let root = b.element(1_291_923), parent = b.element(1_291_924), menu = b.element(1_291_925)
            let echo = b.element(1_291_926), leaf = b.element(1_291_927)
            b.setButton(output, description: "Stereo Output", help: "Output slot. Choose the channel strip output.",
                x: 0, y: 0, width: 60, height: 20)
            b.setChildren(output, []); b.setActionNames(output, [kAXPressAction as String])
            b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]) + [output])
            let inputOwner = profile == "selected_input" ? f.strips[1] : f.strips[0]
            b.setButton(peerInput, description: profile == "known_input" ? "Bus 1" : profile == "no_slot" ? "Settings" : "Input",
                help: profile == "known_input" ? "Input slot. Choose the channel strip input." : "",
                x: 0, y: 0, width: 60, height: 20)
            b.setChildren(peerInput, [])
            b.setChildren(inputOwner, b.makeAXRuntime().children(inputOwner) + [peerInput])
            b.setButton(peerOutput, description: profile == "known_output" ? "Bus 1"
                : profile == "unclassified_output" ? "External Destination" : "Output",
                help: "Output slot. Choose the channel strip output.", x: 0, y: 0, width: 60, height: 20)
            b.setChildren(peerOutput, [])
            b.setChildren(f.strips[0], b.makeAXRuntime().children(f.strips[0]) + [peerOutput])
            for node in [root, menu] { b.setRole(node, kAXMenuRole as String) }
            for (node, title) in [(echo, "Stereo Output"), (parent, "Output"), (leaf, "Stereo Output")] {
                b.setRole(node, kAXMenuItemRole as String); b.setAttribute(node, kAXTitleAttribute as String, title)
                b.setChildren(node, [])
            }
            for node in [echo, leaf] { b.setAttribute(node, "AXMenuItemMarkChar", "✓") }
            b.setChildren(menu, [leaf]); b.setChildren(parent, [menu]); b.setChildren(root, [echo, parent])
            b.setActionNames(root, [kAXCancelAction as String])
            f.routingAction = { element, action in
                if CFEqual(element, output), action == kAXPressAction as String {
                    b.setChildren(f.mixer, f.strips + [root]); return true
                }
                if CFEqual(element, root), action == kAXCancelAction as String {
                    f.renewedOutputCancels += 1
                    b.setChildren(f.mixer, f.strips)
                    if !["unchanged", "output", "known_output", "unclassified_output"].contains(profile) {
                        b.setAttribute(peerInput, kAXDescriptionAttribute as String, "Bus 2")
                        b.setAttribute(peerInput, kAXHelpAttribute as String, "Input slot. Choose the channel strip input.")
                    }
                    if ["output", "both", "known_output", "whole_project", "unclassified_output"].contains(profile) {
                        b.setAttribute(peerOutput, kAXDescriptionAttribute as String, "Stereo Output")
                    }
                    if profile == "name" { b.setAttribute(b.element(1_965_710), kAXValueAttribute as String, "External Name") }
                    return true
                }
                Issue.record("Only the held selected-source output popup and its own Cancel are allowed")
                return false
            }
            f.routingRead = { element, attribute in
                guard profile.hasPrefix("later_"), f.renewedOutputCancels == 1,
                      CFEqual(element, peerInput), attribute == kAXDescriptionAttribute as String else { return }
                f.routingClassifierHelpReads += 1
                // Two cleanup reads and eight first-population reads precede
                // this first deciding read of the corroborating population.
                guard f.routingClassifierHelpReads == 11 else { return }
                f.routingLateScopeInjected = true
                switch profile {
                case "later_input":
                    b.setAttribute(peerInput, kAXDescriptionAttribute as String, "Bus 3")
                case "later_owner":
                    let replacement = b.element(1_291_929)
                    b.setRole(replacement, kAXLayoutItemRole as String)
                    b.setAttribute(replacement, kAXNumberOfCharactersAttribute as String, 0)
                    b.setAttribute(replacement, kAXInsertionPointLineNumberAttribute as String, 0)
                    b.setChildren(replacement, b.makeAXRuntime().children(f.strips[0]))
                    f.routingOtherReplacement = replacement
                    b.setChildren(f.mixer, [replacement, f.strips[1]])
                case "later_slot":
                    let replacement = b.element(1_291_930)
                    b.setButton(replacement, description: "Bus 2", help: "Input slot. Choose the channel strip input.",
                        x: 0, y: 0, width: 60, height: 20)
                    b.setChildren(replacement, [])
                    b.setChildren(f.strips[0], b.makeAXRuntime().children(f.strips[0]).map {
                        CFEqual($0, peerInput) ? replacement : $0
                    })
                case "later_project":
                    b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                default: Issue.record("Unknown late corroboration fault")
                }
            }
            let gate = LogicMutationGate()
            let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
            defer { gate.release(claim) }
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
            let fresh = try await OperationTraceContext.$current.withValue(context) {
                try await f.channel().readFreshSessionPopulation(request: .init(
                    scope: profile == "whole_project" ? .wholeProject : .selection,
                    domains: [.tracks, .strips, .associations, .routing], allowUINavigation: true),
                    fileReader: .unavailable, stoppingWhen: { false })
            }
            #expect(f.renewedOutputCancels == 1, "Reach actual checked routing acquisition and cleanup")
            #expect(f.routingDestinationPresses == 0)
            let positive = ["unchanged", "input", "output", "both"].contains(profile)
            let stable = fresh.stable
            if positive {
                #expect(stable)
                #expect(fresh.checkedOutputs.count == 1)
                #expect(fresh.checkedInputs.isEmpty, "Newly readable peer captions are not checked input edges")
                if profile == "input" || profile == "both" {
                    #expect(fresh.strips?.first?.inputObservation == .init(state: .observedSource, source: "Bus 2"))
                }
                if profile == "output" || profile == "both" { #expect(fresh.strips?.first?.output == "Stereo Output") }
            } else {
                #expect(!stable)
                #expect(fresh.uiEffects.reason == "routing_population_moved")
                #expect(fresh.checkedOutputs.isEmpty)
                if profile.hasPrefix("later_") { #expect(f.routingLateScopeInjected) }
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
          arguments: ["refreshed", "mismatch", "missing_pair", "lost_inverse", "late_document", "changed_header", "late_population",
                      "popup_vertical", "popup_horizontal", "popup_ack_only", "popup_foreign_bar"])
    func noOutputAfterReadRenewsSurvivingOriginalSource(fault: String) async throws {
        let f = try Fixture(), b = f.builder
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let output = b.element(1_325_001), root = b.element(1_325_002), echo = b.element(1_325_003)
        let leaf = b.element(1_325_004), parent = b.element(1_325_005)
        let submenu = b.element(1_325_006), stereo = b.element(1_325_007)
        let nativeViewport = fault.hasPrefix("popup_")
        let vertical = fault != "popup_horizontal"
        let owner = b.element(1_325_020), controls = b.element(1_325_021), toolbar = b.element(1_325_022)
        let view = b.element(1_325_023), viewRoot = b.element(1_325_024), scrollTo = b.element(1_325_025)
        let viewSubmenu = b.element(1_325_026), viewOutput = b.element(1_325_027), viewAudio = b.element(1_325_028)
        let axis = b.element(1_325_029), thumb = b.element(1_325_030)
        if nativeViewport {
            for node in [owner, controls, toolbar] { b.setRole(node, kAXGroupRole as String) }
            b.setFrame(f.window, x: 0, y: 30, width: 1000, height: 800)
            b.setFrame(owner, x: 0, y: 300, width: 1000, height: 530)
            b.setFrame(f.mixer, x: 0, y: 300, width: 2000, height: 600)
            b.setChildren(toolbar, [view]); b.setChildren(controls, [toolbar]); b.setChildren(owner, [f.mixer, controls])
            b.setChildren(f.window, [f.rail, owner, b.element(1_965_720)])
            for (node, role, title) in [(view, kAXMenuButtonRole, AXLocalePolicy.viewMenuBar.canonical),
                (viewRoot, kAXMenuRole, ""), (scrollTo, kAXMenuItemRole, AXLocalePolicy.mixerScrollToMenuItem.canonical),
                (viewSubmenu, kAXMenuRole, ""), (viewOutput, kAXMenuItemRole, AXLocalePolicy.mixerScrollToOutputsMenuItem.canonical),
                (viewAudio, kAXMenuItemRole, AXLocalePolicy.mixerTypeFilterAudio.canonical)] {
                b.setRole(node, role as String); b.setAttribute(node, kAXTitleAttribute as String, title)
                b.setAttribute(node, kAXEnabledAttribute as String, true); b.setAttribute(node, kAXWindowAttribute as String, f.window)
                b.setActionNames(node, [kAXPressAction as String, kAXCancelAction as String])
            }
            b.setChildren(viewOutput, []); b.setChildren(viewAudio, []); b.setChildren(viewSubmenu, [viewOutput, viewAudio])
            b.setChildren(scrollTo, [viewSubmenu]); b.setChildren(viewRoot, [scrollTo]); b.setChildren(view, [])
            b.setRole(axis, kAXScrollBarRole as String)
            b.setAttribute(axis, kAXOrientationAttribute as String,
                vertical ? kAXVerticalOrientationValue as String : kAXHorizontalOrientationValue as String)
            b.setAttribute(axis, kAXWindowAttribute as String, f.window); b.setAttribute(axis, kAXParentAttribute as String, owner)
            b.setAttribute(axis, kAXValueAttribute as String, NSNumber(value: 0.25))
            b.setAttributeSettable(axis, kAXValueAttribute as String, true)
            b.setFrame(axis, x: vertical ? 983 : 0, y: vertical ? 300 : 813,
                width: vertical ? 17 : 1000, height: vertical ? 530 : 17)
            b.setRole(thumb, kAXValueIndicatorRole as String); b.setAttribute(thumb, kAXWindowAttribute as String, f.window)
            b.setFrame(thumb, x: vertical ? 984 : 75, y: vertical ? 350 : 814,
                width: vertical ? 15 : 700, height: vertical ? 400 : 15)
            b.setChildren(axis, [thumb]); b.setChildren(thumb, [])
            f.routingFocusHit = { _, _ in .success(thumb) }
            f.routingReadResult = { element, attribute in
                if CFEqual(element, axis), attribute == kAXValueAttribute as String {
                    return .success(b.attributeValue(axis, attribute) as? NSNumber)
                }
                return nil
            }
            for (index, strip) in f.strips.enumerated() { b.setFrame(strip, x: CGFloat(index) * 100, y: 350, width: 100, height: 300) }
            f.routingSetter = { element, attribute, value in
                guard CFEqual(element, axis), attribute == kAXValueAttribute as String, let number = value as? NSNumber else { return nil }
                f.scrollWrites.append(number.doubleValue)
                if fault != "popup_ack_only" {
                    b.setAttribute(axis, attribute, number)
                    for (index, strip) in f.strips.enumerated() { b.setFrame(strip, x: CGFloat(index) * 100, y: 350, width: 100, height: 300) }
                }
                return true
            }
        }
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
            if nativeViewport {
                if CFEqual(element, view), action == kAXPressAction as String { b.setChildren(view, [viewRoot]); return true }
                if CFEqual(element, viewRoot), action == kAXCancelAction as String { b.setChildren(view, []); return true }
                if (CFEqual(element, viewOutput) || CFEqual(element, viewAudio)), action == kAXPressAction as String {
                    b.setChildren(view, [])
                    b.setAttribute(axis, kAXValueAttribute as String, NSNumber(value: CFEqual(element, viewAudio) ? 0 : 1))
                    for (index, strip) in f.strips.enumerated() {
                        b.setFrame(strip, x: CGFloat(index) * 100 - (vertical ? 0 : 150), y: vertical ? 200 : 350, width: 100, height: 300)
                    }
                    return true
                }
            }
            guard action == kAXPressAction as String else { Issue.record("No cleanup fallback is authorized"); return false }
            if CFEqual(element, output) { b.setChildren(f.mixer, f.strips + [root]); return true }
            guard CFEqual(element, leaf) else { Issue.record("Only the original output and unique destination may be pressed"); return false }
            f.routingDestinationPresses += 1
            b.setChildren(f.mixer, f.strips)
            b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.strips[1])
            if nativeViewport {
                b.setAttribute(axis, kAXValueAttribute as String, NSNumber(value: 0.75))
                for (index, strip) in f.strips.enumerated() {
                    b.setFrame(strip, x: CGFloat(index) * 100 - (vertical ? 0 : 150), y: vertical ? 200 : 350, width: 100, height: 300)
                }
                if fault == "popup_foreign_bar" { b.setAttribute(axis, kAXParentAttribute as String, controls) }
            }
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
            if nativeViewport {
                guard let geometry = observation.observedMixerViewportGeometry(),
                      (vertical ? geometry.vertical : geometry.horizontal)?.value == 0.25 else {
                    Issue.record("Reach the actual observed original native axis before the popup"); return toolTextResult(.error("fixture"))
                }
            }
            b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, nativeViewport ? f.strips[1] : f.window)
            return await AXMixerStripBinding.$current.withValue(pair.strip) {
                await AXMixerStripBinding.$outputAssociation.withValue(fault == "missing_pair" ? nil : pair) {
                    toolTextResult(await AccessibilityChannel.setOutputVerified(params: ["index": "1", "destination": "no_output", "expected_current": "stereo_output"],
                        runtime: runtime, timing: .immediate))
                }
            }
        }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let succeeds = ["refreshed", "popup_vertical", "popup_horizontal"].contains(fault)
        #expect(body["state"] as? String == (succeeds ? "A" : "B"), "Actual writer receipt: \(body)")
        let attempted = try #require(body["write_attempted"] as? Bool); #expect(attempted)
        #expect(f.routingDestinationPresses == 1, "After-read acquisition must never retry the setter")
        if succeeds {
            #expect(body["after"] as? [String: String] == ["kind": "no_output"])
            #expect(f.selections == [1, 0, 1, 0])
            let reread = try #require(body["reference_reread_required"] as? Bool); #expect(reread)
        }
        if nativeViewport {
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == (succeeds ? "restored" : "not_restored"))
            if succeeds {
                #expect((b.attributeValue(axis, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.25)
                #expect(f.strips.enumerated().allSatisfy { index, strip in
                    AXHelpers.getPosition(strip, runtime: b.makeAXRuntime()) == CGPoint(x: CGFloat(index) * 100, y: 350)
                })
                #expect(f.scrollWrites == [0.25], "Reach the actual native inverse, not an acknowledged position echo")
            }
            if fault == "popup_foreign_bar" { #expect(f.scrollWrites.isEmpty, "Lost native control custody prohibits cleanup") }
            if fault == "popup_ack_only" { #expect(f.scrollWrites == [0.25], "Reach the acknowledged but ineffective inverse") }
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
        if fault == "late_bit" {
            let healthy = BypassCensusBoundary()
            try await assertOccupiedSingleSendRenewal(emptyModeMenu: true,
                bypassMode: "measure_late_bit", bypassBoundary: healthy)
            let count = try #require(healthy.censuses > 0 ? healthy.censuses : nil)
            for index in 1...count {
                let boundary = BypassCensusBoundary(injectAt: index)
                try await assertOccupiedSingleSendRenewal(emptyModeMenu: true,
                    bypassMode: fault, bypassBoundary: boundary)
            }
            return
        }
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

    @Test(arguments: ["completed", "failure", "cancel", "unverified", "wrong_project", "wrong_target",
                      "missing_confirmation", "wrong_confirmation", "invalid_later", "multiple",
                      "raw_level", "raw_bypass", "nondefault_mode", "expired_pair",
                      "external_destination", "external_level", "external_mode", "replaced_control",
                      "unknown_after", "foreign_after", "no_observer", "lost_observer", "late_inverse_mode",
                      "late_inverse_missing_bus_receiver", "late_inverse_bus_receiver"])
    func registeredFreshBusStereoReturnOwnsOnlyItsNewChange(mode: String) async throws {
        try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true,
            emptyModeMenu: true, sagaMode: mode, freshPhysicalReturn: true, freshBusStereoReturn: true)
    }

    @Test func freshBusStereoReturnDoesNotEnableCanonicalRepair() async throws {
        try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
            canonicalSend: "unsupported_pair", canonicalPhysical: true,
            freshPhysicalReturn: true, freshBusStereoReturn: true)
    }

    @Test func freshBusStereoReturnRequiresTypedBusAndCannotForgeCanonicalAuthority() throws {
        #expect(!ApprovedSessionRepair.supportsCapturedSendDirection(before: .bus(1), after: .stereoOutput))
        #expect(ApprovedSessionRepair.supportsCapturedSendDirection(before: .physical(3, 4), after: .stereoOutput))
        #expect(ApprovedSessionRepair.supportsCapturedSendDirection(before: .bus(1), after: .bus(2)))
        #expect(!AccessibilityChannel.supportsOccupiedSendChange(before: .bus(1), after: .physical(3, 4)))
        func plan(_ number: Value) -> SagaPlan {
            .init(steps: [.init(operationID: .mixerSetSendOutputVerified,
                targetRef: .init(rawValue: "mix_fresh_bus_return"), params: ["ordinal": .int(1),
                    "destination": .object(["kind": .string("stereo_output")]),
                    "expected_current": .object(["kind": .string("bus"), "number": number]),
                    "replace_existing": .bool(true)],
                expectedInverse: .init(operationID: .mixerSetSendOutputVerified, valueParameter: "destination"))],
                idempotencyKey: "fresh-bus-return")
        }
        for number: Value in [.int(1), .int(256)] {
            let good = plan(number)
            #expect(SendRemovalSagaAdapter.accepts(good))
            #expect(SendRemovalSagaAdapter.journalValue(try #require(good.steps.first)) == .string("stereo_output"))
            var forged = good
            forged.canonicalPlanID = "unowned"; forged.canonicalDigest = "unowned"
            #expect(!SendRemovalSagaAdapter.accepts(forged))
        }
        for number: Value in [.int(0), .int(257), .double(1), .bool(true), .string("1"), .null] {
            #expect(!SendRemovalSagaAdapter.accepts(plan(number)))
        }
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

    @Test("One retained approval composes an actual track rename and its occupied Send destination change",
          arguments: ["forward", "cancel", "replacement", "late_replacement", "wrong_digest", "wrong_project",
                      "mixed", "physical_slot", "missing_witness", "decoded", "expired"], [false, true])
    func canonicalNameAndPhysicalSendUseTheSameRetainedApproval(mode: String, returning: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(restoring: true, emptyModeMenu: true,
                canonicalSend: mode, canonicalPhysical: true, canonicalName: true,
                freshPhysicalReturn: returning)
        }
    }

    @Test("An admitted name/Send operation keeps its checked native pair when inspection retention expires before dispatch",
          arguments: ["forward", "cancel"], [false, true])
    func canonicalNameSendKeepsItsPairAcrossInspectionExpiry(mode: String, stable: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(restoring: true, emptyModeMenu: true,
                canonicalSend: mode, canonicalPhysical: true, canonicalName: true,
                stableDestinationControls: stable, expireInspectionBeforeSendDispatch: true)
        }
    }

    @Test("Cancellation restores the owned name through its renewed source's ordinary Rename editor", arguments: [false, true])
    func canonicalNameSendCancellationOwnsItsMenuEditor(returning: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(restoring: true, emptyModeMenu: true,
                canonicalSend: "cancel", canonicalPhysical: true, canonicalName: true,
                stableDestinationControls: true, coupledMixerName: true, inverseNameMenu: true,
                freshPhysicalReturn: returning)
        }
    }

    @Test("A named Bus Send retains its original Mixer focus when the first Rename commit lands on the rail",
          arguments: [false, true])
    func canonicalNamedBusSendRestoresItsFirstNameFocus(bulk: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "cancel", canonicalBus: true,
                canonicalBusChange: true, canonicalName: true, stableDestinationControls: true,
                stableDestinationBulkReads: bulk, coupledMixerName: true, inverseNameMenu: true,
                forwardNameMovesFocus: true)
        }
    }

    @Test("A named Bus Send preserves its held passive rail focus through both owned names",
          arguments: [false, true])
    func canonicalNamedBusSendPreservesItsInitialRailFocus(bulk: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "cancel", canonicalBus: true,
                canonicalBusChange: true, canonicalName: true, stableDestinationControls: true,
                stableDestinationBulkReads: bulk, coupledMixerName: true, inverseNameMenu: true,
                forwardNameMovesFocus: true, initialNameRailFocus: true)
        }
    }

    @Test("Named Bus Send compensation refreshes only its observed stale Mixer name through the original header",
          arguments: [false, true])
    func canonicalNamedBusSendRefreshesItsRestoredNameCaption(bulk: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            let caption = RestoredNameCaptionScenario()
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "cancel", canonicalBus: true,
                canonicalBusChange: true, canonicalName: true, stableDestinationControls: true,
                stableDestinationBulkReads: bulk, coupledMixerName: true, inverseNameMenu: true,
                forwardNameMovesFocus: true, restoredNameCaption: caption)
        }
    }

    @Test("Restored name presentation cannot hide lost original custody or an unchanged stale caption",
          arguments: ["persistent", "project", "peer", "source"])
    func canonicalNamedBusSendRefusesLostCaptionRestorationCustody(fault: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            let caption = RestoredNameCaptionScenario(fault: fault)
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "cancel", canonicalBus: true,
                canonicalBusChange: true, canonicalName: true, stableDestinationControls: true,
                stableDestinationBulkReads: true, coupledMixerName: true, inverseNameMenu: true,
                forwardNameMovesFocus: true, restoredNameCaption: caption)
        }
    }

    @Test("An owned cancellation menu still refuses changed editor, project and physical membership",
          arguments: ["foreign_rail", "missing_header", "foreign_focus", "project", "peer", "late_membership"])
    func canonicalNameSendCancellationRefusesLostEditorCustody(fault: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(restoring: true, emptyModeMenu: true,
                canonicalSend: "cancel", canonicalPhysical: true, canonicalName: true,
                stableDestinationControls: true, coupledMixerName: true, inverseNameMenu: true,
                inverseNameFault: fault)
        }
    }

    @Test("An owned name may reach the Mixer only when its Send redraws", arguments: [false, true], [false, true])
    func canonicalNameSendAcceptsDelayedCoupledName(stable: Bool, returning: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(restoring: true, emptyModeMenu: true,
                canonicalSend: "forward", canonicalPhysical: true, canonicalName: true,
                stableDestinationControls: stable, delayedMixerName: "Selected Canonical",
                freshPhysicalReturn: returning)
        }
    }

    @Test("A Send redraw cannot adopt an unrelated Mixer name", arguments: [false, true])
    func canonicalNameSendRefusesForeignDelayedMixerName(stable: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(restoring: true, emptyModeMenu: true,
                canonicalSend: "forward", canonicalPhysical: true, canonicalName: true,
                stableDestinationControls: stable, delayedMixerName: "External")
        }
    }

    @Test("A name edited after dispatch cannot authorize the later Send leaf", arguments: [false, true])
    func canonicalNameSendRefusesALateExternalName(returning: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(restoring: true, emptyModeMenu: true,
                canonicalSend: "late_name", canonicalPhysical: true, canonicalName: true,
                freshPhysicalReturn: returning)
        }
    }

    @Test("A composed Send that preserves its original controls still publishes owned effect custody",
          arguments: ["forward", "cancel"], [false, true])
    func canonicalNameSendRetainsSurvivingNativeControls(mode: String, returning: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(restoring: true, emptyModeMenu: true,
                canonicalSend: mode, canonicalPhysical: true, canonicalName: true,
                stableDestinationControls: true, freshPhysicalReturn: returning)
        }
    }

    @Test("Composed stable Send custody survives the native bulk-read path",
          arguments: ["forward", "cancel"], [false, true])
    func canonicalNameSendRetainsSurvivingNativeControlsWithBulkReads(mode: String, returning: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(restoring: true, emptyModeMenu: true,
                canonicalSend: mode, canonicalPhysical: true, canonicalName: true,
                stableDestinationControls: true, stableDestinationBulkReads: true,
                freshPhysicalReturn: returning)
        }
    }

    @Test("A coupled Mixer name remains owned through a stable Send change",
          arguments: ["forward", "cancel"], [false, true])
    func canonicalNameSendRetainsCoupledMixerName(mode: String, returning: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(restoring: true, emptyModeMenu: true,
                canonicalSend: mode, canonicalPhysical: true, canonicalName: true,
                stableDestinationControls: true, stableDestinationBulkReads: true,
                coupledMixerName: true, freshPhysicalReturn: returning)
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

    private final class BypassCensusBoundary: @unchecked Sendable {
        var censuses = 0, lastValueReads = -1
        var insideNativeWriter = false
        let injectAt: Int?
        init(injectAt: Int? = nil) { self.injectAt = injectAt }
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

    @Test("An already-correct Bus Send is freshly verified without a routing write")
    func canonicalMatchingBusSendUsesCheckedReadback() async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "matching", canonicalBus: true,
                canonicalMatching: true)
        }
    }

    @Test("Matching Bus Send verification retains approval and exact native custody",
          arguments: ["wrong_digest", "unconfirmed", "wrong_project", "replacement", "late_replacement",
                      "destination", "level", "bypass", "mode", "unread_mark", "source_retired", "cleanup_focus"])
    func canonicalMatchingBusSendRefusesChangedEvidence(_ fault: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "matching", canonicalBus: true,
                canonicalMatching: true, matchingFault: fault)
        }
    }

    @Test(arguments: ["forward", "cancel"], [false, true])
    func canonicalExistingBusSendUsesItsQualifiedReceiversAndOwnedInverse(mode: String, named: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: mode, canonicalBus: true,
                canonicalBusChange: true, canonicalName: named)
        }
    }

    @Test("An occupied Send forward uses its actual checked peer headers for source verification")
    func occupiedSendForwardUsesItsCheckedPeerHeaders() async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "forward", canonicalBus: true, canonicalBusChange: true,
                canonicalBusReceiverFault: "physical_source_read_renewal", measureForwardAssociations: true)
        }
    }

    @Test(arguments: ["forward", "cancel"])
    func canonicalBusStereoDepartureUsesCapturedInputsAndOwnEffect(mode: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: mode, canonicalBus: true,
                canonicalBusChange: true, canonicalBusStereoReturn: true,
                canonicalBusReceiverFault: "physical_source")
        }
    }

    @Test func canonicalBusStereoDepartureDoesNotRequireAnUnrelatedBusReceiver() async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "cancel", canonicalBus: true,
                canonicalBusChange: true, canonicalBusStereoReturn: true, canonicalBusReceiverFault: "missing_after")
        }
    }

    @Test func canonicalBusStereoDepartureRetainsItsEffectThroughInputReadRenewal() async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "cancel", canonicalBus: true,
                canonicalBusChange: true, canonicalBusStereoReturn: true,
                canonicalBusReceiverFault: "physical_source_inverse_read_renewal")
        }
    }

    @Test(arguments: ["missing_before", "checked_before_at_capture", "checked_before_after_preview",
                      "checked_before_after_forward", "checked_source_after_preview", "checked_source_after_forward"])
    func canonicalBusStereoDepartureRefusesMissingOrChangedInputProof(fault: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "cancel", canonicalBus: true,
                canonicalBusChange: true, canonicalBusStereoReturn: true, canonicalBusReceiverFault: fault)
        }
    }

    @Test(arguments: ["physical_source_inverse_read_renewal_peer_volume", "physical_source_inverse_read_renewal_mode",
                      "physical_source_inverse_read_renewal_project"])
    func canonicalBusStereoDepartureCannotRenewChangedProtectedState(fault: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "cancel", canonicalBus: true,
                canonicalBusChange: true, canonicalBusStereoReturn: true, canonicalBusReceiverFault: fault)
        }
    }

    @Test(arguments: ["missing_before", "missing_after"], [false, true])
    func canonicalExistingBusSendRequiresBothReturnAndForwardReceivers(fault: String, named: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "missing_receiver", canonicalBus: true,
                canonicalBusChange: true, canonicalBusReceiverFault: fault, canonicalName: named)
        }
    }

    @Test(arguments: ["checked_before_at_capture", "checked_after_at_capture",
                      "checked_before_after_preview", "checked_after_after_preview",
                      "checked_before_after_forward", "checked_source_after_preview",
                      "checked_source_after_forward"], [false, true])
    func canonicalExistingBusSendChecksReceiverMenusRatherThanCaptions(fault: String, named: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: fault.hasSuffix("after_forward") ? "cancel" : "forward",
                canonicalBus: true, canonicalBusChange: true, canonicalBusReceiverFault: fault, canonicalName: named)
        }
    }

    @Test("An external source name cannot authorize a later existing-Bus Send leaf", arguments: [false, true])
    func canonicalNamedExistingBusSendRefusesALateExternalName(expired: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "late_name", canonicalBus: true,
                canonicalBusChange: true, canonicalName: true, expireInspectionBeforeSendRead: expired)
        }
    }

    @Test("An owned name keeps the original Send source after historical inspection expiry", arguments: ["forward", "cancel"])
    func canonicalNamedExistingBusSendKeepsItsPairBeforeFirstReadAfterInspectionExpires(mode: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: mode, canonicalBus: true,
                canonicalBusChange: true, canonicalName: true, expireInspectionBeforeSendRead: true)
        }
    }

    @Test("An owned Mixer name may propagate while checking existing Bus inputs", arguments: ["forward", "cancel"])
    func canonicalNamedExistingBusSendAcceptsNamePropagationDuringInputRead(mode: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: mode, canonicalBus: true,
                canonicalBusChange: true, canonicalName: true, mixerNameAfterInputRead: "Selected Canonical")
        }
    }

    @Test("An input read cannot adopt an unrelated Mixer name")
    func canonicalNamedExistingBusSendRefusesForeignNameDuringInputRead() async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "forward", canonicalBus: true,
                canonicalBusChange: true, canonicalName: true, mixerNameAfterInputRead: "External")
        }
    }

    @Test(arguments: ["forward", "cancel"])
    func canonicalExistingBusSendRetainsItsCheckedPhysicalSourceInput(mode: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: mode, canonicalBus: true, canonicalBusChange: true,
                canonicalBusReceiverFault: "physical_source")
        }
    }

    @Test("Canonical Send input prerequisites keep the admitted Mixer census while their own popup is open",
          arguments: ["forward", "cancel"], [false, true])
    func canonicalExistingBusSendReadsInputsThroughItsHeldMixer(mode: String, anotherWindow: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: mode, canonicalBus: true, canonicalBusChange: true,
                canonicalBusReceiverFault: "physical_source_scoped_input", stableDestinationBulkReads: true,
                scopedInputAdditionalWindow: anotherWindow)
        }
    }

    @Test("Selected routing capture reads its popups through its actual held Mixer", arguments: ["selection", "whole_project"])
    func routingCaptureKeepsItsHeldInputReadScope(scope: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "forward", canonicalBus: true, canonicalBusChange: true,
                canonicalBusReceiverFault: "physical_source_scoped_input", stableDestinationBulkReads: true,
                captureInputReadScope: scope)
        }
    }

    @Test("An input read borrowing a held Mixer still uses the existing native-popup custody path",
          arguments: ["unscoped", "unscoped_ordinary", "owned", "foreign_scope", "guarded_ordinary", "guarded_ordinary_document",
                      "guarded_ordinary_window", "guarded_ordinary_source", "guarded_ordinary_gate",
                      "guarded_native", "guarded_native_document",
                      "guarded_native_window", "guarded_native_source", "guarded_native_root",
                      "guarded_native_editor", "guarded_native_gate"])
    func heldInputReadPreservesNativePopupWithoutFocusedWindow(scope: String) async throws {
        let f = try Fixture(), b = f.builder
        f.useBulkReads = scope == "guarded_ordinary" || scope == "unscoped_ordinary"
        let ordinary = scope.hasPrefix("guarded_ordinary") || scope == "unscoped_ordinary"
        let input = b.element(1_971_980), root = b.element(1_971_981), echo = b.element(1_971_982)
        let parent = b.element(1_971_983), submenu = b.element(1_971_984), leaf = b.element(1_971_985)
        let wrapper = b.element(1_971_986), frame = CGRect(x: 20, y: 100, width: 230, height: 175)
        let outer = b.element(1_971_987)
        b.setRole(f.mixer, kAXLayoutAreaRole as String); b.setAttribute(f.mixer, kAXDescriptionAttribute as String, "Mixer")
        b.setRole(outer, kAXGroupRole as String); b.setAttribute(outer, kAXDescriptionAttribute as String, "Mixer")
        let windowChildren = b.makeAXRuntime().children(f.window)
        b.setChildren(outer, [f.mixer])
        b.setChildren(f.window, windowChildren.map { CFEqual($0, f.mixer) ? outer : $0 })
        b.setButton(input, description: "Bus 1", help: "Input slot. Choose the channel strip input source.",
            x: 0, y: 0, width: 1, height: 1)
        b.setChildren(input, [])
        b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]) + [input])
        for (node, role, title) in [(root, kAXMenuRole, ""), (echo, kAXMenuItemRole, "Bus 1"),
                                   (parent, kAXMenuItemRole, "Bus"), (submenu, kAXMenuRole, ""),
                                   (leaf, kAXMenuItemRole, "Bus 1")] {
            b.setRole(node, role as String); b.setAttribute(node, kAXTitleAttribute as String, title)
            b.setChildren(node, [])
        }
        for node in [echo, leaf] { b.setAttribute(node, "AXMenuItemMarkChar", "✓") }
        b.setChildren(submenu, [leaf]); b.setChildren(parent, [submenu]); b.setChildren(root, [echo, parent])
        b.setActionNames(input, [kAXPressAction as String]); b.setActionNames(root, [kAXCancelAction as String])
        b.setRole(wrapper, kAXPopUpButtonRole as String)
        b.setAttribute(wrapper, kAXParentAttribute as String, f.mixer)
        b.setAttribute(wrapper, kAXWindowAttribute as String, f.window)
        b.setFrame(root, x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        f.routingFocusHit = { _, _ in .success(f.routingNativePopupFrame == nil ? nil : echo) }
        f.routingReadResult = { element, attribute in
            if !ordinary, f.routingNativePopupFrame != nil, CFEqual(element, f.app), attribute == kAXFocusedWindowAttribute as String {
                if scope == "guarded_native_window" { return .success(b.element(1_971_988)) }
                return .failure(.init(raw: AXError.noValue.rawValue))
            }
            return nil
        }
        f.routingAction = { element, action in
            if CFEqual(element, input), action == kAXPressAction as String {
                b.setChildren(wrapper, [root]); f.routingNativePopupFrame = frame; f.inputMenuPresses += 1
                if ordinary { b.setChildren(f.mixer, b.makeAXRuntime().children(f.mixer) + [root]) }
                switch scope {
                case "guarded_native_document", "guarded_ordinary_document":
                    b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                case "guarded_ordinary_window": b.setAttribute(f.app, kAXFocusedWindowAttribute as String, b.element(1_971_988))
                case "guarded_native_source", "guarded_ordinary_source":
                    b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]).filter { !CFEqual($0, input) })
                case "guarded_native_root": b.setChildren(wrapper, [])
                case "guarded_native_editor":
                    let editor = b.element(1_971_989)
                    b.setRole(editor, kAXTextFieldRole as String); b.setAttribute(editor, kAXValueAttribute as String, "Editing")
                    b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, editor)
                default: break
                }
                return true
            }
            if CFEqual(element, root), action == kAXCancelAction as String {
                if ordinary { b.setChildren(f.mixer, b.makeAXRuntime().children(f.mixer).filter { !CFEqual($0, root) }) }
                b.setChildren(wrapper, []); f.routingNativePopupFrame = nil
                return true
            }
            Issue.record("Only the acquired input popup and its Cancel may run"); return false
        }
        let gate = LogicMutationGate(), claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: {
            gate.stillOwns(claim) && (!scope.hasSuffix("_gate") || f.routingNativePopupFrame == nil)
        })
        try await OperationTraceContext.$current.withValue(context) {
            let runtime = f.logic()
            let held = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: runtime, expectedProject: nil, requiresProjectReference: false))
            var borrowed = scope.hasPrefix("unscoped") || scope.hasPrefix("guarded_native") ? nil : held
            if scope == "foreign_scope" {
                b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                borrowed = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                    logic: runtime, expectedProject: nil, requiresProjectReference: false))
                b.setAttribute(f.window, kAXDocumentAttribute as String, held.document)
            }
            let owner = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
                strip: f.strips[1], document: held.document)
            let readScope = borrowed
            let focus = AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope()
            let readGuard = AXHelpers.HelpReadGuard(allowHelpReads: true, stop: {
                guard scope.hasPrefix("guarded_native") || ordinary else { return false }
                let permitted = focus.permits() || held.permitsRead()
                if !permitted, f.routingForeignHelpFirstStack.isEmpty { f.routingForeignHelpFirstStack = Thread.callStackSymbols }
                return !permitted
            })
            let discoveriesBeforeRead = f.coupledGuardPopulationScans
            let read = await AXHelpers.HelpReadGuard.$current.withValue(readGuard) {
                await AXMixerStripBinding.$current.withValue(owner) {
                    await AccessibilityChannel.getInputBusObservation(runtime: runtime, timing: .immediate,
                        observingPopupFocus: { f.routingPopupReadFocusRetained = $0 != nil; focus.retainRoutingPopupFocus($0) },
                        readingOriginalScope: readScope)
                }
            }
            if scope == "guarded_ordinary" {
                #expect(f.coupledGuardPopulationScans == discoveriesBeforeRead,
                    "Use the actual original held census at entry as well as inside its ordinary Input popup")
            } else if scope == "unscoped_ordinary" {
                #expect(f.coupledGuardPopulationScans > discoveriesBeforeRead,
                    "Unscoped/native readers retain their existing global discovery")
            }
            #expect(!f.routingPopupReadFocusRetained, "Every reader exit clears its temporary native focus proof")
            if scope.hasPrefix("guarded_native_") || scope.hasPrefix("guarded_ordinary_") {
                #expect(read.assignment == nil, "A changed source, project, root, focus or gate cannot qualify input")
                return
            }
            if scope == "foreign_scope" {
                #expect(read.assignment == nil)
                #expect(f.inputMenuPresses == 0, "Reject foreign metadata before acquiring a popup")
                #expect(held.permitsRead(), "The foreign scope cannot retire the original observation")
                return
            }
            #expect(read.assignment == .bus(1), "Actual native input read: \(read.result.message)")
            #expect(f.inputMenuPresses == 1)
            #expect(f.routingNativePopupFrame == nil, "The acquired native popup must actually close")
            if scope == "guarded_native" || scope == "guarded_ordinary" {
                #expect(held.permitsRead(), "A qualified native popup cannot retire the original capture: \(f.routingForeignHelpFirstStack.joined(separator: "\n"))")
            }
        }
    }

    @Test(arguments: ["forward", "cancel"], [false, true])
    func canonicalExistingBusSendSurvivesItsOwnedInputReadRenewal(mode: String, named: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: mode, canonicalBus: true, canonicalBusChange: true,
                canonicalBusReceiverFault: "physical_source_read_renewal", canonicalName: named)
        }
    }

    @Test(arguments: ["forward", "cancel"], [false, true])
    func canonicalNamedBusSendChecksItsFootprintAfterInputRenewal(mode: String, bulk: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: mode, canonicalBus: true, canonicalBusChange: true,
                canonicalBusReceiverFault: "physical_source_read_renewal", canonicalName: true,
                stableDestinationBulkReads: bulk, measureNamedBusPreInput: true)
        }
    }

    @Test("Named Bus Send corroborates an unrequested peer becoming readable after its actual Input renewal",
          arguments: ["forward", "cancel"])
    func canonicalNamedBusSendCorroboratesNewlyReadablePeer(mode: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: mode, canonicalBus: true, canonicalBusChange: true,
                canonicalBusReceiverFault: "physical_source_read_renewal", canonicalName: true,
                peerDisplayHydration: true)
        }
    }

    @Test("Named Bus Send refuses a peer or custody change in its corroborating native sample",
          arguments: ["input", "slot", "owner", "project"])
    func canonicalNamedBusSendRejectsChangedCorroboratingPeer(fault: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "forward", canonicalBus: true, canonicalBusChange: true,
                canonicalBusReceiverFault: "physical_source_read_renewal", canonicalName: true,
                peerDisplayHydration: true, peerDisplaySecondSampleFault: fault)
        }
    }

    @Test(arguments: [false, true])
    func canonicalNamedBusSendCorroboratesModeAfterInputRenewal(bulk: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "forward", canonicalBus: true, canonicalBusChange: true,
                canonicalBusReceiverFault: "physical_source_read_renewal", canonicalName: true,
                stableDestinationBulkReads: bulk, decidingSendFault: "mode", measureNamedBusPreInput: true)
        }
    }

    @Test("Canonical Send corroborates its approved before-state in the deciding popup without a duplicate read lifecycle",
          arguments: ["healthy", "level", "bypass", "mode", "project",
                      "late_action_mode", "late_choice_mode", "late_bus_mode"])
    func canonicalSendDecidingPopupRetainsItsApprovedBeforeState(fault: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "forward", canonicalBus: true,
                canonicalBusChange: true, stableDestinationBulkReads: fault.hasPrefix("late_"),
                decidingSendFault: fault)
        }
    }

    @Test("An owned changed Send retains only its effect through inverse input-read renewal",
          arguments: ["healthy", "peer_volume", "level", "mode", "destination", "project"])
    func canonicalExistingBusSendRetainsItsEffectThroughInverseInputReadRenewal(fault: String) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "cancel", canonicalBus: true, canonicalBusChange: true,
                canonicalBusReceiverFault: "physical_source_inverse_read_renewal" + (fault == "healthy" ? "" : "_" + fault))
        }
    }

    @Test("The owned inverse corroborates its original expected Send in its deciding popup after Input renewal",
          arguments: [false, true], [false, true])
    func canonicalInverseUsesItsDecidingPopupAfterInputRenewal(named: Bool, bulk: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "cancel", canonicalBus: true, canonicalBusChange: true,
                canonicalBusReceiverFault: "physical_source_inverse_read_renewal", canonicalName: named,
                stableDestinationBulkReads: bulk, singleInverseWriterPopup: true)
        }
    }

    @Test("A restored Send source needs one changed-strip challenge and its verified return",
          arguments: [false, true], [false, true])
    func anOwnedSendInverseDoesNotCollectUnneededAssociations(named: Bool, stable: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "cancel", canonicalBus: true, canonicalBusChange: true,
                canonicalName: named, stableDestinationControls: stable, measureInverseAssociations: true)
        }
    }

    @Test("An occupied Send retains the actual pre-popup geometry through post-press source renewal")
    func occupiedSendRenewalRetainsPrePopupMixerGeometry() async throws {
        try await assertOccupiedSingleSendRenewal(sendGeometry: true)
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
    func canonicalExistingBusSendRenewsHelpCustodyDuringInverseControlScan(roleSample: Int) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "cancel", canonicalBus: true, canonicalBusChange: true,
                canonicalBusReceiverFault: "checked_inverse_help", inverseHelpRole: roleSample)
        }
    }

    @Test("An actual changed named Send checks its exact control and protected slots in one fresh census",
          arguments: [false, true], [false, true])
    func canonicalNamedBusSendUsesOneEffectCustodyCensus(stable: Bool, bulk: Bool) async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, restoring: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "forward", canonicalBus: true, canonicalBusChange: true,
                canonicalName: true, stableDestinationControls: stable, stableDestinationBulkReads: bulk,
                measureChangedPermissionCensus: true)
        }
    }

    @Test("A different Bus Send goal does not gain write authority from matching-goal support")
    func canonicalMatchingBusSendCannotAdmitAnotherBus() async throws {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await assertOccupiedSingleSendRenewal(existingBus: true, emptyModeMenu: true,
                noOpDestination: .bus(1), canonicalSend: "nonmatching_bus", canonicalBus: true,
                canonicalMatching: true)
        }
    }

    private final class RestoredNameCaptionScenario: @unchecked Sendable {
        private var refreshed = false
        private let fault: String?

        init(fault: String? = nil) { self.fault = fault }

        func prepare(_ f: Fixture) {
            f.builder.setAttribute(f.strips[1], kAXDescriptionAttribute as String, "Duplicate")
        }

        func nameWritten(_ f: Fixture, name: String) {
            guard f.routingNameConfirms == 0 else { return }
            // The forward caption propagates; the inverse changes only the
            // actual name field until an observed header excursion occurs.
            f.builder.setAttribute(f.strips[1], kAXDescriptionAttribute as String, name)
        }

        func headerSelected(_ f: Fixture, index: Int) {
            guard f.routingNameConfirms == 2, index == 1 else { return }
            refreshed = true
            if fault == "persistent" { return }
            f.builder.setAttribute(f.strips[1], kAXDescriptionAttribute as String, "Duplicate")
            switch fault {
            case "project":
                f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
            case "peer":
                f.builder.setAttribute(f.headers[1], kAXTitleAttribute as String, "External Peer")
            case "source":
                let children = f.builder.makeAXRuntime().children(f.mixer)
                f.builder.setChildren(f.mixer, children.filter { !CFEqual($0, f.strips[1]) })
            default: break
            }
        }

        func verifyRefusal(_ f: Fixture, body: [String: Any]) -> Bool {
            guard let fault else { return false }
            #expect(refreshed, "The actual original-header presentation path must reach the fault")
            #expect(f.routingNameWrites == ["Selected Canonical", "Duplicate"])
            #expect(f.routingDestinationPresses == 2)
            let state = body["state"] as? String
            let saga = body["saga_state"] as? String
            #expect(state == "B")
            #expect(saga != "fullyCompensated")
            if fault == "peer" {
                let name = f.builder.attributeValue(f.headers[1], kAXTitleAttribute as String) as? String
                #expect(name == "External Peer", "The intervening peer edit must survive")
            }
            return true
        }

        func verify(_ f: Fixture) {
            #expect(refreshed, "The restored group caption needs an actual original-header excursion")
            let caption = f.builder.attributeValue(f.strips[1], kAXDescriptionAttribute as String) as? String
            #expect(caption == "Duplicate")
        }
    }

    private func assertOccupiedSingleSendRenewal(_ fault: String? = nil, existingBus: Bool = false,
                                               removing: Bool = false, restoring: Bool = false,
                                               inverseFault: String? = nil, survivingSource: Bool = false,
                                               emptyModeMenu: Bool = false, observeRemoval: Bool = false,
                                               readRestored: String? = nil, sagaMode: String? = nil,
                                               inspectSendWitness: String? = nil,
                                               noOpDestination: OutputAssignment? = nil,
                                               bypassMode: String? = nil,
                                               bypassBoundary: BypassCensusBoundary? = nil,
                                               levelMode: String? = nil,
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
                                               canonicalBus: Bool = false,
                                               canonicalBusChange: Bool = false,
                                               canonicalBusStereoReturn: Bool = false,
                                               canonicalBusReceiverFault: String? = nil,
                                               inverseHelpRole: Int = 1,
                                               canonicalName: Bool = false,
                                               stableDestinationControls: Bool = false,
                                               stableDestinationBulkReads: Bool = false,
                                               coupledMixerName: Bool = false,
                                               inverseNameMenu: Bool = false,
                                               inverseNameFault: String? = nil,
                                               delayedMixerName: String? = nil,
                                               mixerNameAfterInputRead: String? = nil,
                                               expireInspectionBeforeSendDispatch: Bool = false,
                                               expireInspectionBeforeSendRead: Bool = false,
                                               freshPhysicalReturn: Bool = false,
                                               freshBusStereoReturn: Bool = false,
                                               canonicalMatching: Bool = false,
                                               matchingFault: String? = nil,
                                               sendGeometry: Bool = false,
                                               decidingSendFault: String? = nil,
                                               scopedInputAdditionalWindow: Bool = false,
                                               captureInputReadScope: String? = nil,
                                               measureNamedBusPreInput: Bool = false,
                                               measureChangedPermissionCensus: Bool = false,
                                               singleInverseWriterPopup: Bool = false,
                                               measureInverseAssociations: Bool = false,
                                               measureForwardAssociations: Bool = false,
                                               forwardNameMovesFocus: Bool = false,
                                               initialNameRailFocus: Bool = false,
                                               peerDisplayHydration: Bool = false,
                                               peerDisplaySecondSampleFault: String? = nil,
                                               restoredNameCaption: RestoredNameCaptionScenario? = nil) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture(fourTracks: measureInverseAssociations || measureForwardAssociations), b = f.builder
            let hydrationPeer = peerDisplayHydration ? b.element(1_971_800) : nil
            let hydrationInput = b.element(1_971_801), hydrationOutput = b.element(1_971_802)
            defer {
                if measureForwardAssociations {
                    #expect(f.routingBusLeafPresses == [2] && f.routingDestinationPresses == 1,
                        "The real occupied Send Bus leaf must execute exactly once")
                    #expect(f.routingForwardSelections == [1, 0],
                        "Verify the actual source and checked receiver without unrelated post-write headers")
                }
                if measureChangedPermissionCensus {
                    #expect(f.routingChangedSendPublished, "Every measured case must reach the actual native effect publisher")
                }
            }
            let inverseInputReadRenewal = canonicalBusReceiverFault?.hasPrefix("physical_source_inverse_read_renewal") == true
            let sourceInputReadRenewal = canonicalBusReceiverFault == "physical_source_read_renewal" || inverseInputReadRenewal
            f.measureNamedBusPreInput = measureNamedBusPreInput
            if stableDestinationBulkReads { f.useBulkReads = true }
            let nameField = b.element(1_971_400)
            let inverseEditor = b.element(1_971_402), renameItem = b.element(1_971_406)
            if canonicalName {
                restoredNameCaption?.prepare(f)
                // No real AX activation or mouse fallback from an injected fixture.
                f.routingMenuRename = true
                b.setRole(nameField, kAXTextFieldRole as String)
                b.setAttribute(nameField, kAXDescriptionAttribute as String, "Duplicate")
                b.setAttribute(nameField, kAXValueAttribute as String, "0")
                b.setAttribute(nameField, kAXWindowAttribute as String, f.window)
                b.setChildren(nameField, [])
                b.setChildren(f.headers[0], [nameField])
                if inverseNameMenu {
                    try f.configureOriginalPlateClick()
                    b.setAttributeSettable(f.strips[1], kAXFocusedAttribute as String, true)
                    b.setAttributeSettable(f.rail, kAXValueAttribute as String, false)
                    let bar = b.element(1_971_403), trackMenu = b.element(1_971_404), menu = b.element(1_971_405)
                    for (node, role) in [(bar, kAXMenuBarRole), (trackMenu, kAXMenuBarItemRole),
                        (menu, kAXMenuRole), (renameItem, kAXMenuItemRole), (inverseEditor, kAXTextFieldRole)] {
                        b.setRole(node, role as String)
                    }
                    b.setAttribute(trackMenu, kAXTitleAttribute as String, AXLocalePolicy.trackMenuBar.canonical)
                    b.setAttribute(renameItem, kAXTitleAttribute as String, AXLocalePolicy.renameTrackMenuItem.canonical)
                    b.setChildren(bar, [trackMenu]); b.setChildren(trackMenu, [menu]); b.setChildren(menu, [renameItem])
                    b.setAttribute(f.app, kAXMenuBarAttribute as String, bar)
                    b.setAttribute(inverseEditor, kAXWindowAttribute as String, f.window)
                    // The actual menu editor is parented by, but not exported in, the original rail.
                    b.setAttribute(inverseEditor, kAXParentAttribute as String, f.rail)
                    b.setAttributeSettable(inverseEditor, kAXValueAttribute as String, true)
                    b.setChildren(inverseEditor, [])
                    f.routingNameReturn = {
                        guard let name = b.attributeValue(inverseEditor, kAXValueAttribute as String) as? String else { return false }
                        f.routingNameConfirms += 1
                        b.setAttribute(nameField, kAXDescriptionAttribute as String, name)
                        b.setAttribute(f.headers[0], kAXTitleAttribute as String, name)
                        b.setAttribute(b.element(1_965_711), kAXValueAttribute as String, name)
                        b.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.strips[1]])
                        b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
                        return true
                    }
                }
                f.routingSetter = { element, attribute, value in
                    if inverseNameMenu, CFEqual(element, inverseEditor), attribute == kAXValueAttribute as String,
                       let name = value as? String {
                        f.routingNameWrites.append(name)
                        b.setAttribute(inverseEditor, kAXValueAttribute as String, name)
                        return true
                    }
                    guard CFEqual(element, nameField), attribute == kAXValueAttribute as String,
                          let name = value as? String else { return nil }
                    if inverseNameMenu, f.routingDestinationPresses == 2 { return false }
                    f.routingNameWrites.append(name)
                    b.setAttribute(nameField, kAXDescriptionAttribute as String, name)
                    b.setAttribute(nameField, kAXValueAttribute as String, name)
                    b.setAttribute(f.headers[0], kAXTitleAttribute as String, name)
                    if coupledMixerName { b.setAttribute(b.element(1_965_711), kAXValueAttribute as String, name) }
                    restoredNameCaption?.nameWritten(f, name: name)
                    if mixerNameAfterInputRead != nil, f.routingNamePropagatedDuringInputRead {
                        // Once the actual name has propagated, a later owned
                        // rename affects this same source, including its redraw.
                        b.setAttribute(b.element(1_965_711), kAXValueAttribute as String, name)
                        b.setAttribute(b.element(1_965_2608), kAXValueAttribute as String, name)
                    }
                    return true
                }
            }
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
                if expireInspectionBeforeSendRead, !f.routingNameWrites.isEmpty,
                   SendRemovalSagaAdapter.checkedSourcePair == nil {
                    f.inspectionExpiredBeforeSendRead = true
                    f.expireRetainedCapture = true
                }
                if expireInspectionBeforeSendDispatch, !f.routingNameWrites.isEmpty,
                   SendRemovalSagaAdapter.checkedSourcePair != nil {
                    // Expire at the actual admitted Send dispatch, after its
                    // independent before-read, regardless of earlier lookup count.
                    f.captureExpiredAtCheckedSendDispatch = true
                    f.expireRetainedCapture = true
                }
                return f.expireRetainedCapture ? captureNow.advanced(by: StateCache.sessionCaptureLifetime) : captureNow
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
                if freshBusStereoReturn {
                    b.setAttribute(echo, kAXTitleAttribute as String, "Bus 1 → Existing")
                    b.setAttribute(stereo, kAXTitleAttribute as String, "Bus 1 → Existing")
                    b.setAttribute(destination, kAXTitleAttribute as String, "Stereo Output")
                    b.setChildren(menu, [destination]); b.setChildren(busMenu, [stereo])
                }
            }
            if let noOpDestination, noOpDestination != .stereoOutput {
                b.setAttribute(echo, kAXTitleAttribute as String, existingBus ? "Bus 1 → Existing" : "Output 3-4")
                b.setAttribute(stereo, "AXMenuItemMarkChar", "")
                b.setAttribute(destination, "AXMenuItemMarkChar", "✓")
            }
            b.setActionNames(root, [kAXCancelAction as String])
            f.routingAction = { element, action in
                if inverseNameMenu, CFEqual(element, renameItem), action == kAXPressAction as String {
                    f.routingMenuNameOpens += 1
                    b.setAttribute(inverseEditor, kAXValueAttribute as String,
                        b.attributeValue(nameField, kAXDescriptionAttribute as String))
                    b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, inverseEditor)
                    if let inverseNameFault, !["foreign_focus", "late_membership"].contains(inverseNameFault) {
                        f.routingLateScopeInjected = true
                        switch inverseNameFault {
                        case "foreign_rail":
                            let foreign = b.element(1_971_407)
                            b.setRole(foreign, kAXGroupRole as String); b.setChildren(foreign, [])
                            b.setAttribute(foreign, kAXWindowAttribute as String, f.window)
                            b.setAttribute(inverseEditor, kAXParentAttribute as String, foreign)
                        case "missing_header": b.setChildren(f.rail, [f.headers[0]])
                        case "project": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        case "peer": b.setAttribute(f.headers[1], kAXTitleAttribute as String, "External")
                        default: Issue.record("Unknown inverse name fault")
                        }
                    }
                    return true
                }
                if canonicalName, CFEqual(element, nameField) {
                    if inverseNameMenu, f.routingDestinationPresses == 2 { return false }
                    if action == kAXConfirmAction as String {
                        f.routingNameConfirms += 1
                        if forwardNameMovesFocus, f.routingNameConfirms == 1 {
                            b.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.strips[1]])
                            b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
                        }
                    }
                    return [kAXPressAction as String, kAXConfirmAction as String].contains(action)
                }
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
                    if f.routingInputReadRenewed, f.routingDestinationPresses == 1 {
                        f.routingInverseRenewedSendMenuOpens += 1
                    }
                    if captureInputReadScope != nil, !f.routingInputReadRenewalArmed {
                        f.routingOutputOpenDiscoveryStart = f.coupledGuardPopulationScans
                    }
                    if let decidingSendFault, f.routingDestinationPresses == 0 {
                        f.routingBeforeSendMenuOpens += 1
                        if decidingSendFault != "healthy", !decidingSendFault.hasPrefix("late_"),
                           !f.routingDecidingSendFaultInjected,
                           SendRemovalSagaAdapter.requiredSendControl != nil {
                            f.routingDecidingSendFaultInjected = true
                            switch decidingSendFault {
                            case "level": b.setAttribute(b.element(1_965_2624), kAXValueAttribute as String, 1)
                            case "bypass": b.setAttribute(b.element(1_965_2622), kAXValueAttribute as String, 1)
                            case "mode":
                                b.setAttribute(mode, "AXMenuItemMarkChar", "")
                                b.setAttribute(preFader, "AXMenuItemMarkChar", "✓")
                            case "project": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///different.logicx/")
                            default: Issue.record("Unknown deciding Send fault")
                            }
                        }
                    }
                    if canonicalSend == "late_replacement", CFEqual(element, b.element(1_965_2799)) {
                        f.routingBypassMenuOpens += 1
                    }
                    if bypassMode != nil || canonicalMatching { f.routingBypassMenuOpens += 1 }
                    if f.routingBypassMenuOpens == 3, let pending = f.routingBypassPendingValue {
                        f.routingLateScopeInjected = true
                        b.setAttribute(b.element(1_965_2622), kAXValueAttribute as String, pending ? 1 : 0)
                        f.routingBypassPendingValue = nil
                    }
                    b.setChildren(f.mixer, [f.strips[0], source] + Array(f.strips.dropFirst(2)) + [root]); return true
                }
                if restoring, action == kAXPressAction as String, CFEqual(element, renewedSend[0]) {
                    b.setChildren(f.mixer, [f.strips[0], source] + Array(f.strips.dropFirst(2)) + [root]); return true
                }
                if action == kAXCancelAction as String, CFEqual(element, root) {
                    f.observeNamedSendBeforeRead()
                    if let start = f.routingOutputOpenDiscoveryStart {
                        f.routingOutputOpenDiscoveryCounts.append(f.coupledGuardPopulationScans - start)
                        f.routingOutputOpenDiscoveryStart = nil
                    }
                    if bypassMode != nil { f.routingBypassMenuCancels += 1 }
                    b.setChildren(f.mixer, [f.strips[0], source] + Array(f.strips.dropFirst(2))); return true
                }
                if action == kAXPressAction as String, CFEqual(element, destination) {
                    if let delayedMixerName {
                        b.setAttribute(stableDestinationControls ? b.element(1_965_711) : name,
                            kAXValueAttribute as String, delayedMixerName)
                    }
                    if stableDestinationControls {
                        f.routingDestinationPresses += 1
                        if inverseNameMenu {
                            b.setAttribute(nameField, kAXValueAttribute as String, NSNumber(value: 0))
                            b.setAttributeSettable(nameField, kAXValueAttribute as String, false)
                        }
                        b.setAttribute(echo, kAXTitleAttribute as String, freshPhysicalReturn ? "Stereo Output" : "Output 3-4")
                        b.setAttribute(stereo, "AXMenuItemMarkChar", "")
                        b.setAttribute(destination, "AXMenuItemMarkChar", "✓")
                        b.setChildren(f.mixer, f.strips)
                        b.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                            initialNameRailFocus ? f.rail : f.strips[1])
                        return true
                    }
                    f.routingDestinationPresses += 1; f.routingReplacement = replacement
                    b.setAttribute(echo, kAXTitleAttribute as String, freshBusStereoReturn ? "Stereo Output" : existingBus ? "Bus 1 → Existing" : freshPhysicalReturn ? "Stereo Output" : "Output 3-4")
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
                    b.setChildren(f.mixer, [f.strips[0], replacement] + Array(f.strips.dropFirst(2)))
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
                    if measureInverseAssociations, f.routingDestinationPresses == 1 {
                        f.routingSelectionsAtInverseLeaf = f.selections.count
                    }
                    if stableDestinationControls {
                        f.routingDestinationPresses += 1
                        b.setAttribute(echo, kAXTitleAttribute as String, freshPhysicalReturn ? "Output 3-4" : "Stereo Output")
                        b.setAttribute(stereo, "AXMenuItemMarkChar", "✓")
                        b.setAttribute(destination, "AXMenuItemMarkChar", "")
                        b.setChildren(f.mixer, f.strips)
                        b.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                            initialNameRailFocus ? f.rail : f.strips[1])
                        return true
                    }
                    f.routingDestinationPresses += 1; f.routingReplacement = restoredSource
                    b.setAttribute(echo, kAXTitleAttribute as String, freshBusStereoReturn ? "Bus 1 → Existing" : freshPhysicalReturn ? "Output 3-4" : "Stereo Output")
                    b.setAttribute(echo, "AXMenuItemMarkChar", "✓")
                    b.setAttribute(stereo, "AXMenuItemMarkChar", "✓")
                    b.setAttribute(destination, "AXMenuItemMarkChar", "")
                    if emptyModeMenu {
                        b.setAttribute(mode, kAXEnabledAttribute as String, true)
                        b.setAttribute(mode, "AXMenuItemMarkChar", "✓")
                    }
                    b.setChildren(f.mixer, [f.strips[0], restoredSource] + Array(f.strips.dropFirst(2)))
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
            f.routingRead = { element, attribute in
                // The inverse already committed its own name. Lose a peer
                // while the pure renewed peer-name group is being read: its
                // final complete membership bookend must still reject it.
                if inverseNameFault == "late_membership", f.routingNameConfirms == 2,
                   CFEqual(element, b.element(1_965_710)), attribute == kAXValueAttribute as String,
                   !f.routingLateScopeInjected {
                    f.routingLateScopeInjected = true
                    b.setChildren(f.rail, [f.headers[0]])
                }
                if inverseNameFault == "foreign_focus", f.routingMenuNameOpens == 1,
                   CFEqual(element, inverseEditor), attribute == kAXParentAttribute as String,
                   !f.routingLateScopeInjected {
                    f.routingLateScopeInjected = true
                    let foreign = b.element(1_971_408)
                    b.setRole(foreign, kAXTextFieldRole as String)
                    b.setAttribute(foreign, kAXValueAttribute as String, "Selected Canonical")
                    b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, foreign)
                }
            }
            f.routingReadResult = { element, attribute in
                if inverseNameMenu, CFEqual(element, f.rail),
                   [kAXValueAttribute, kAXSelectedTextAttribute, kAXNumberOfCharactersAttribute,
                    kAXInsertionPointLineNumberAttribute].map({ $0 as String }).contains(attribute) {
                    return .failure(.init(raw: AXError.noValue.rawValue))
                }
                if ["late_inverse_mode", "late_inverse_bus_receiver"].contains(sagaMode ?? ""),
                   f.routingDestinationPresses == 1, CFEqual(element, stereo) {
                    if attribute == kAXTitleAttribute as String, f.routingClassifierHelpReads > 0 {
                        f.routingClassifierHelpReads += 1
                        // The fresh checked-current scan is followed by the
                        // final offered-leaf lookup; mutate only that later read.
                        if f.routingClassifierHelpReads == 3 {
                            if sagaMode == "late_inverse_bus_receiver" {
                                b.setAttribute(b.element(1_965_2680), kAXDescriptionAttribute as String, "Bus 2")
                            } else { b.setAttribute(mode, kAXTitleAttribute as String, "Pre Fader") }
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
            if canonicalBusChange {
                let receiver = b.element(1_971_500), receiverName = b.element(1_971_501)
                let input = b.element(1_971_502), busTwo = b.element(1_971_503)
                b.setRole(receiver, kAXLayoutItemRole as String)
                b.setAttribute(receiver, kAXNumberOfCharactersAttribute as String, 0)
                b.setAttribute(receiver, kAXInsertionPointLineNumberAttribute as String, 0)
                b.setRole(receiverName, kAXTextFieldRole as String)
                b.setAttribute(receiverName, kAXDescriptionAttribute as String, "Name")
                b.setAttribute(receiverName, kAXValueAttribute as String, "Existing Bus 2")
                b.setChildren(receiverName, [])
                b.setButton(input, description: canonicalBusReceiverFault == "missing_after" ? "Bus 3" : "Bus 2",
                    help: "Input slot. Choose the channel strip input source.",
                    x: 0, y: 0, width: 1, height: 1)
                b.setChildren(input, [])
                b.setChildren(receiver, [receiverName, input])
                let inputRoot = b.element(1_971_510), inputEcho = b.element(1_971_511)
                let inputBusParent = b.element(1_971_512), inputBusMenu = b.element(1_971_513)
                let inputBuses = (1...3).map { b.element(1_971_513 + $0) }
                let sourceInput = b.element(1_971_517), physicalParent = b.element(1_971_518)
                let physicalMenu = b.element(1_971_519), physicalLeaf = b.element(1_971_520)
                let mainRoot = b.element(1_971_550), mainEcho = b.element(1_971_551)
                let mainParent = b.element(1_971_552), mainMenu = b.element(1_971_553), mainLeaf = b.element(1_971_554)
                if canonicalBusReceiverFault?.contains("source") == true {
                    b.setButton(sourceInput, description: "Input 1",
                        help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 1, height: 1)
                    b.setChildren(sourceInput, []); b.setActionNames(sourceInput, [kAXPressAction as String])
                    b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]) + [sourceInput])
                    b.setRole(physicalParent, kAXMenuItemRole as String)
                    b.setAttribute(physicalParent, kAXTitleAttribute as String, "Input")
                    b.setRole(physicalMenu, kAXMenuRole as String)
                    b.setRole(physicalLeaf, kAXMenuItemRole as String)
                    b.setAttribute(physicalLeaf, kAXTitleAttribute as String, "Input 1")
                    b.setChildren(physicalLeaf, []); b.setChildren(physicalMenu, [physicalLeaf])
                    b.setChildren(physicalParent, [physicalMenu])
                }
                for node in [inputRoot, inputBusMenu] { b.setRole(node, kAXMenuRole as String) }
                b.setRole(inputBusParent, kAXMenuItemRole as String)
                b.setAttribute(inputBusParent, kAXTitleAttribute as String, "Bus")
                b.setChildren(inputBusParent, [inputBusMenu]); b.setChildren(inputBusMenu, inputBuses)
                b.setRole(inputEcho, kAXMenuItemRole as String); b.setChildren(inputEcho, [])
                b.setAttribute(inputEcho, "AXMenuItemMarkChar", "✓")
                for (offset, leaf) in inputBuses.enumerated() {
                    b.setRole(leaf, kAXMenuItemRole as String)
                    b.setAttribute(leaf, kAXTitleAttribute as String, "Bus \(offset + 1)")
                    b.setChildren(leaf, [])
                }
                b.setActionNames(inputRoot, [kAXCancelAction as String])
                for slot in [input, b.element(1_965_2680)] {
                    b.setActionNames(slot, [kAXPressAction as String])
                }
                b.setRole(busTwo, kAXMenuItemRole as String)
                b.setAttribute(busTwo, kAXTitleAttribute as String, "Bus 2 → Existing")
                b.setAttribute(busTwo, kAXEnabledAttribute as String, true)
                b.setAttribute(busTwo, "AXMenuItemMarkChar", "")
                b.setChildren(busTwo, []); b.setActionNames(busTwo, [kAXPressAction as String])
                b.setChildren(b.element(1_965_2682), [destination, busTwo])
                b.setChildren(f.mixer, f.strips + [receiver])
                do {
                    // Read renewal must preserve independently observed scalars,
                    // inserts and the unchanged main output, not just Send values.
                    for (index, owner) in (f.strips + [receiver]).enumerated() {
                        let volume = b.element(1_971_530 + index * 3), pan = b.element(1_971_531 + index * 3)
                        let output = b.element(1_971_532 + index * 3)
                        for (control, description, value, minimum, maximum) in [
                            (volume, "Volume", 100.0, 0.0, 233.0), (pan, "Pan", 0.2, -1.0, 1.0)
                        ] {
                            b.setRole(control, kAXSliderRole as String)
                            b.setAttribute(control, kAXDescriptionAttribute as String, description)
                            b.setAttribute(control, kAXValueAttribute as String, NSNumber(value: value))
                            b.setAttribute(control, kAXMinValueAttribute as String, NSNumber(value: minimum))
                            b.setAttribute(control, kAXMaxValueAttribute as String, NSNumber(value: maximum))
                            b.setChildren(control, [])
                            f.routingScalarControls.append(control)
                        }
                        b.setButton(output, description: "Stereo Output",
                            help: "Output slot. Choose the channel strip output.", x: 0, y: 0, width: 1, height: 1)
                        b.setChildren(output, [])
                        b.setChildren(owner, b.makeAXRuntime().children(owner) + [volume, pan, output])
                    }
                    for node in [mainRoot, mainMenu] { b.setRole(node, kAXMenuRole as String) }
                    for (node, title) in [(mainEcho, "Stereo Output"), (mainParent, "Output"), (mainLeaf, "Stereo Output")] {
                        b.setRole(node, kAXMenuItemRole as String)
                        b.setAttribute(node, kAXTitleAttribute as String, title)
                        b.setChildren(node, [])
                    }
                    for node in [mainEcho, mainLeaf] { b.setAttribute(node, "AXMenuItemMarkChar", "✓") }
                    b.setChildren(mainRoot, [mainEcho, mainParent]); b.setChildren(mainParent, [mainMenu])
                    b.setChildren(mainMenu, [mainLeaf]); b.setActionNames(mainRoot, [kAXCancelAction as String])
                }
                if canonicalBusReceiverFault == "missing_before" {
                    b.setChildren(f.strips[0], b.makeAXRuntime().children(f.strips[0]).filter {
                        !CFEqual($0, b.element(1_965_2680))
                    })
                }
                let originalAction = try #require(f.routingAction)
                let originalRead = f.routingRead
                if canonicalBusReceiverFault == "checked_inverse_help" {
                    f.routingRead = { element, attribute in
                        originalRead?(element, attribute)
                        if f.routingChangedSendPublished, !f.routingLateScopeInjected,
                           CFEqual(element, renewedSend[1]), attribute == kAXRoleAttribute as String {
                            f.routingClassifierHelpReads += 1
                            if f.routingClassifierHelpReads == inverseHelpRole {
                                f.routingLateScopeInjected = true
                                b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            }
                        }
                        if f.routingLateScopeInjected, attribute == kAXHelpAttribute as String {
                            if f.routingForeignHelpReads == 0 {
                                f.routingForeignHelpFirstStack = Thread.callStackSymbols
                            }
                            f.routingForeignHelpReads += 1
                        }
                    }
                }
                f.routingAction = { element, action in
                    do {
                        if action == kAXPressAction as String,
                           (0...f.strips.count).contains(where: { CFEqual(element, b.element(1_971_532 + $0 * 3)) }) {
                            if captureInputReadScope != nil, !f.routingInputReadRenewalArmed {
                                f.routingOutputOpenDiscoveryStart = f.coupledGuardPopulationScans
                            }
                            b.setChildren(f.mixer, b.makeAXRuntime().children(f.mixer) + [mainRoot])
                            return true
                        }
                        if CFEqual(element, mainRoot), action == kAXCancelAction as String {
                            if let start = f.routingOutputOpenDiscoveryStart {
                                f.routingOutputOpenDiscoveryCounts.append(f.coupledGuardPopulationScans - start)
                                f.routingOutputOpenDiscoveryStart = nil
                            }
                            b.setChildren(f.mixer, b.makeAXRuntime().children(f.mixer).filter { !CFEqual($0, mainRoot) })
                            return true
                        }
                    }
                    if action == kAXPressAction as String,
                       CFEqual(element, input) || CFEqual(element, b.element(1_965_2680)) || CFEqual(element, sourceInput) {
                        let ownInput = CFEqual(element, sourceInput)
                        let bus = CFEqual(element, input) ? 2 : 1
                        if f.routingInputReadRenewalArmed, canonicalBusReceiverFault == "physical_source", !ownInput,
                           let count = f.routingSourceInputCancelledAtSelectionCount {
                            #expect(f.selections.count > count,
                                "The canonical caller must actually re-observe its header after Source Input Cancel")
                            f.routingSourceInputFreshHeaderChallenges += 1
                            f.routingSourceInputCancelledAtSelectionCount = nil
                        }
                        f.routingCanonicalInputBuses.append(ownInput ? 0 : bus)
                        let appliesToReceiver = canonicalBusReceiverFault?.hasPrefix(ownInput ? "checked_source_"
                            : bus == 1 ? "checked_before_" : "checked_after_") == true
                        let contradicted = appliesToReceiver && (canonicalBusReceiverFault?.hasSuffix("at_capture") == true
                            || f.routingLateScopeInjected
                            || (canonicalBusReceiverFault?.hasSuffix("after_forward") == true && f.routingDestinationPresses > 0))
                        if contradicted { f.routingCanonicalContradictedInputs.append(ownInput ? 0 : bus) }
                        // The original caption and native owner stay unchanged. Only the actual
                        // checked input differs, which a caption-only guard cannot observe.
                        b.setAttribute(inputEcho, kAXTitleAttribute as String, ownInput ? "Input 1" : "Bus \(bus)")
                        for (offset, leaf) in inputBuses.enumerated() {
                            let checked = ownInput ? (contradicted ? 2 : 0) : (contradicted ? 3 : bus)
                            b.setAttribute(leaf, "AXMenuItemMarkChar", offset + 1 == checked ? "✓" : "")
                        }
                        if ownInput { b.setAttribute(physicalLeaf, "AXMenuItemMarkChar", contradicted ? "" : "✓") }
                        b.setChildren(inputRoot, [inputEcho] + (ownInput ? [physicalParent] : []) + [inputBusParent])
                        let rows = b.makeAXRuntime().children(f.mixer)
                        b.setChildren(f.mixer, rows + [inputRoot]); f.inputMenuPresses += 1
                        if canonicalBusReceiverFault == "physical_source_scoped_input",
                           f.routingInputReadRenewalArmed || captureInputReadScope != nil {
                            f.routingInputOpenDiscoveryStart = f.coupledGuardPopulationScans
                        }
                        return true
                    }
                    if CFEqual(element, inputRoot), action == kAXCancelAction as String {
                        if let start = f.routingInputOpenDiscoveryStart {
                            f.routingInputOpenDiscoveryCounts.append(f.coupledGuardPopulationScans - start)
                            f.routingInputOpenDiscoveryStart = nil
                        }
                        b.setChildren(f.mixer, b.makeAXRuntime().children(f.mixer).filter { !CFEqual($0, inputRoot) })
                        if f.routingInputReadRenewalArmed, canonicalBusReceiverFault == "physical_source",
                           f.routingCanonicalInputBuses.last == 0 {
                            f.routingSourceInputCancelledAtSelectionCount = f.selections.count
                        }
                        if sourceInputReadRenewal, f.routingInputReadRenewalArmed, !f.routingInputReadRenewed,
                           canonicalBusReceiverFault == "physical_source_read_renewal" || f.routingDestinationPresses == 1 {
                            f.routingInputReadRenewed = true
                            let readSource = canonicalBusReceiverFault == "physical_source_read_renewal"
                                ? replacement : b.element(1_971_570)
                            b.setRole(readSource, kAXLayoutItemRole as String)
                            b.setAttribute(readSource, kAXNumberOfCharactersAttribute as String, 0)
                            b.setAttribute(readSource, kAXInsertionPointLineNumberAttribute as String, 0)
                            f.routingReplacement = readSource
                            b.setChildren(readSource, [name] + renewedSend + [sourceInput]
                                + [b.element(1_971_533), b.element(1_971_534), b.element(1_971_535)])
                            let peer = b.element(1_971_560)
                            b.setRole(peer, kAXLayoutItemRole as String)
                            b.setAttribute(peer, kAXNumberOfCharactersAttribute as String, 0)
                            b.setAttribute(peer, kAXInsertionPointLineNumberAttribute as String, 0)
                            b.setChildren(peer, b.makeAXRuntime().children(f.strips[0]))
                            f.routingOtherReplacement = peer
                            b.setChildren(f.mixer, [peer, readSource] + Array(f.strips.dropFirst(2))
                                + [receiver] + (hydrationPeer.map { [$0] } ?? []))
                            if hydrationPeer != nil {
                                #expect(f.routingNameWrites == ["Selected Canonical"],
                                    "The peer must become readable only after the actual owned name and Input renewal")
                                b.setAttribute(hydrationInput, kAXDescriptionAttribute as String, "Bus 9")
                                b.setAttribute(hydrationInput, kAXHelpAttribute as String, "Input slot. Choose the channel strip input.")
                                b.setAttribute(hydrationOutput, kAXDescriptionAttribute as String, "Stereo Output")
                            }
                            b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, readSource)
                            switch canonicalBusReceiverFault {
                            case "physical_source_inverse_read_renewal_peer_volume":
                                b.setAttribute(b.element(1_971_530), kAXValueAttribute as String, NSNumber(value: 101.0))
                            case "physical_source_inverse_read_renewal_level":
                                b.setAttribute(b.element(1_965_2644), kAXValueAttribute as String, 1)
                            case "physical_source_inverse_read_renewal_mode":
                                b.setAttribute(mode, kAXTitleAttribute as String, "Pre Fader")
                            case "physical_source_inverse_read_renewal_destination":
                                b.setAttribute(echo, kAXTitleAttribute as String, "Bus 1 → Existing")
                                b.setAttribute(destination, "AXMenuItemMarkChar", "✓")
                                b.setAttribute(busTwo, "AXMenuItemMarkChar", "")
                            case "physical_source_inverse_read_renewal_project":
                                b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            default: break
                            }
                        }
                        if let mixerNameAfterInputRead, !f.routingNamePropagatedDuringInputRead,
                           f.routingNameWrites == ["Selected Canonical"], f.routingDestinationPresses == 0 {
                            f.routingNamePropagatedDuringInputRead = true
                            b.setAttribute(f.routingReplacement == nil || stableDestinationControls
                                ? b.element(1_965_711) : name, kAXValueAttribute as String, mixerNameAfterInputRead)
                            // A Send redraw must retain that actual source name;
                            // it is not a second external rename back to Duplicate.
                            b.setAttribute(name, kAXValueAttribute as String, mixerNameAfterInputRead)
                        }
                        return true
                    }
                    let forward = CFEqual(element, canonicalBusStereoReturn ? stereo : busTwo) && action == kAXPressAction as String
                    let inverse = CFEqual(element, destination) && action == kAXPressAction as String
                    if (forward && !canonicalBusStereoReturn) || inverse {
                        f.routingBusLeafPresses.append(forward ? 2 : 1)
                    }
                    // Reuse the source redraw model while retaining this untouched receiver.
                    let acknowledged = originalAction(forward ? destination : inverse ? stereo : element, action)
                    if sourceInputReadRenewal, let peer = f.routingOtherReplacement {
                        b.setChildren(f.mixer, b.makeAXRuntime().children(f.mixer).map {
                            CFEqual($0, f.strips[0]) ? peer : $0
                        })
                    }
                    let currentSource = f.routingReplacement ?? f.strips[1]
                    if canonicalBusReceiverFault?.contains("source") == true {
                        let currentChildren = b.makeAXRuntime().children(currentSource)
                        if !currentChildren.contains(where: { CFEqual($0, sourceInput) }) {
                            b.setChildren(currentSource, currentChildren + [sourceInput])
                        }
                    }
                    do {
                        let fields = [b.element(1_971_533), b.element(1_971_534), b.element(1_971_535)]
                        let observed = b.makeAXRuntime().children(currentSource)
                        b.setChildren(currentSource, observed + fields.filter { control in
                            !observed.contains(where: { CFEqual($0, control) })
                        })
                    }
                    if forward || inverse {
                        b.setAttribute(echo, kAXTitleAttribute as String, forward
                            ? (canonicalBusStereoReturn ? "Stereo Output" : "Bus 2 → Existing") : "Bus 1 → Existing")
                        b.setAttribute(echo, "AXMenuItemMarkChar", "✓")
                        b.setAttribute(stereo, "AXMenuItemMarkChar", forward && canonicalBusStereoReturn ? "✓" : "")
                        b.setAttribute(destination, "AXMenuItemMarkChar", forward ? "" : "✓")
                        b.setAttribute(busTwo, "AXMenuItemMarkChar", forward && !canonicalBusStereoReturn ? "✓" : "")
                    }
                    for owner in [receiver] + (hydrationPeer.map { [$0] } ?? []) {
                        let children = b.makeAXRuntime().children(f.mixer)
                        if !children.contains(where: { CFEqual($0, owner) }) {
                            b.setChildren(f.mixer, children + [owner])
                        }
                    }
                    return acknowledged
                }
            }
            if let hydrationPeer {
                b.setRole(hydrationPeer, kAXLayoutItemRole as String)
                b.setAttribute(hydrationPeer, kAXNumberOfCharactersAttribute as String, 0)
                b.setAttribute(hydrationPeer, kAXInsertionPointLineNumberAttribute as String, 0)
                let peerName = b.element(1_971_803)
                b.setRole(peerName, kAXTextFieldRole as String)
                b.setAttribute(peerName, kAXDescriptionAttribute as String, "Name")
                b.setAttribute(peerName, kAXValueAttribute as String, "Unrequested Peer")
                b.setChildren(peerName, [])
                b.setButton(hydrationInput, description: "Input", help: "", x: 0, y: 0, width: 1, height: 1)
                b.setButton(hydrationOutput, description: "Output",
                    help: "Output slot. Choose the channel strip output.", x: 0, y: 0, width: 1, height: 1)
                b.setChildren(hydrationInput, []); b.setChildren(hydrationOutput, [])
                b.setChildren(hydrationPeer, [peerName, hydrationInput, hydrationOutput])
                b.setChildren(f.mixer, b.makeAXRuntime().children(f.mixer) + [hydrationPeer])
                if let fault = peerDisplaySecondSampleFault {
                    let originalRead = f.routingRead
                    f.routingRead = { element, attribute in
                        originalRead?(element, attribute)
                        guard f.routingInputReadRenewed, f.routingNameWrites.first == "Selected Canonical",
                              f.routingDestinationPresses == 0, CFEqual(element, peerName),
                              attribute == kAXValueAttribute as String,
                              let sample = AXHelpers.StripHelpSamples.current else { return }
                        // Retain each actual row sampler, so a recycled address
                        // cannot manufacture a distinct corroborating read.
                        if !f.peerHydrationSamples.contains(where: { $0 === sample }) {
                            f.peerHydrationSamples.append(sample)
                        }
                        guard f.peerHydrationSamples.count == 2, !f.peerHydrationFaultInjected else { return }
                        f.peerHydrationFaultInjected = true
                        switch fault {
                        case "input": b.setAttribute(hydrationInput, kAXDescriptionAttribute as String, "Bus 10")
                        case "slot":
                            let replacement = b.element(1_971_804)
                            b.setButton(replacement, description: "Bus 9", help: "Input slot. Choose the channel strip input.",
                                x: 0, y: 0, width: 1, height: 1)
                            b.setChildren(replacement, [])
                            b.setChildren(hydrationPeer, [peerName, replacement, hydrationOutput])
                        case "owner":
                            let replacement = b.element(1_971_805)
                            b.setRole(replacement, kAXLayoutItemRole as String)
                            b.setAttribute(replacement, kAXNumberOfCharactersAttribute as String, 0)
                            b.setAttribute(replacement, kAXInsertionPointLineNumberAttribute as String, 0)
                            b.setChildren(replacement, [peerName, hydrationInput, hydrationOutput])
                            b.setChildren(f.mixer, b.makeAXRuntime().children(f.mixer).map {
                                CFEqual($0, hydrationPeer) ? replacement : $0
                            })
                        case "project": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        default: Issue.record("Unknown corroborating peer fault")
                        }
                    }
                }
            }
            if sendGeometry {
                f.setInputGeometry(top: 100, renewed: false)
                f.routingSelection = { index in
                    if index == 0, f.routingDestinationPresses > 0 {
                        f.setInputGeometry(top: 100, renewed: true)
                    }
                }
                let originalAction = try #require(f.routingAction)
                f.routingAction = { element, action in
                    let writes = f.routingDestinationPresses
                    let acknowledged = originalAction(element, action)
                    if f.routingDestinationPresses > writes {
                        // Native counterexample: a transient post-press layout
                        // is not the original presentation restoration duty.
                        f.setInputGeometry(top: 115, renewed: true)
                    }
                    return acknowledged
                }
            }
            if forwardNameMovesFocus {
                let selection = f.routingSelection
                f.routingSelection = { index in
                    selection?(index)
                    guard f.routingNameConfirms > 0 else { return }
                    b.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String,
                        [index == 0 ? f.routingReplacement ?? f.strips[1] : f.routingOtherReplacement ?? f.strips[0]])
                    restoredNameCaption?.headerSelected(f, index: index)
                }
            }
            if initialNameRailFocus {
                f.selectionKeepsPassiveRailFocus = true
                b.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.strips[1]])
                b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
            }
            if measureForwardAssociations {
                let selection = f.routingSelection
                f.routingSelection = { index in
                    selection?(index)
                    if f.routingDestinationPresses == 1 { f.routingForwardSelections.append(index) }
                }
            }
            let before = try await inspect(f, cache: cache, registry: registry,
                domains: inspectSendWitness == nil && canonicalSend == nil ? ["associations"] : ["tracks", "strips", "associations", "routing"],
                scope: initialNameRailFocus ? "selection"
                    : captureInputReadScope ?? (canonicalBusReceiverFault == "physical_source_read_renewal" ? "selection" : "whole_project"))
            if let captureInputReadScope {
                #expect(f.routingDestinationPresses == 0 && f.routingNameWrites.isEmpty,
                    "Capture reads must not cross a data-write boundary")
                let scans = f.routingInputOpenDiscoveryCounts
                let outputScans = f.routingOutputOpenDiscoveryCounts
                #expect(!scans.isEmpty, "Reach the captured source's actual Input popup")
                #expect(outputScans.count >= 2, "Reach the captured source's actual main Output and Send popups")
                if captureInputReadScope == "selection" {
                    #expect(scans.allSatisfy { $0 == 0 },
                        "The admitted selected capture must retain its original native scope during Input reads: \(scans)")
                    #expect(outputScans.allSatisfy { $0 == 0 },
                        "Main Output and Send reads retain that same actual scope: \(outputScans)")
                } else {
                    #expect(scans.contains { $0 > 0 }, "Whole-project capture keeps its existing discovery path")
                    #expect(outputScans.contains { $0 > 0 }, "Whole-project Output capture keeps its existing discovery path")
                }
                f.routingInputOpenDiscoveryCounts.removeAll()
            }
            if ["changed_control", "typed_mode_changed_control"].contains(inspectSendWitness ?? ""), before["snapshot_id"] == nil {
                #expect(f.routingLateScopeInjected && f.routingDestinationPresses == 0)
                #expect(before["state"] as? String == "C")
                return
            }
            let id = try #require(before["snapshot_id"] as? String, "Actual initial capture: \(before)")
            let capture = try #require(await cache.retainedInspection(id: id)).capture
            if let hydrationPeer {
                let peer = try #require(capture.channelStrips.first {
                    $0.physicalBinding.map { CFEqual($0.strip, hydrationPeer) } == true
                })
                #expect(peer.input == nil && peer.inputObservation?.state == .unreadable)
                #expect(peer.output == "Output")
            }
            let row = try #require(capture.channelStrips.indices.first {
                capture.channelStrips[$0].physicalBinding.map { CFEqual($0.strip, f.strips[1]) } == true
            })
            let reference = try #require(capture.mixerReference(at: row))
            let originalPair = try #require(capture.freshPopulation?.selectionAssociations.first {
                CFEqual($0.strip.strip, f.strips[1])
            })
            #expect(CFEqual(originalPair.track.header, f.headers[0]))
            if canonicalBus {
                let checked = capture.freshPopulation?.checkedOutputs.filter {
                    $0.source.matches(originalPair.strip) && $0.sendOrdinal == 1
                } ?? []
                try #require(checked.count == 1, "The matching Bus case must begin with an actual captured checked Send")
                #expect(checked.first?.assignment == .bus(1))
                #expect(checked.first?.sendNonRoutingChecks == ["Post Fader"])
                #expect(checked.first?.sendControl != nil)
                if canonicalBusChange {
                    let receiver = try #require(capture.channelStrips.first {
                        $0.physicalBinding.map { CFEqual($0.strip, b.element(1_971_500)) } == true
                    })
                    #expect(receiver.inputObservation?.source == (canonicalBusReceiverFault == "missing_after" ? "Bus 3" : "Bus 2"))
                    #expect(receiver.inputSlotBinding != nil)
                }
            }
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
                        if canonicalName, canonicalSend == "late_name" {
                            b.setAttribute(nameField, kAXDescriptionAttribute as String, "External")
                            b.setAttribute(f.headers[0], kAXTitleAttribute as String, "External")
                            f.routingLateScopeInjected = true
                        }
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
                if canonicalBusStereoReturn {
                    sendIntent["output"] = .object(["kind": .string("stereo_output")])
                } else if canonicalBus {
                    sendIntent["bus"] = .int(canonicalBusChange || canonicalSend == "nonmatching_bus" ? 2 : 1)
                } else if canonicalPhysical {
                    sendIntent["output"] = (freshBusStereoReturn || (canonicalMatching ? !freshPhysicalReturn : freshPhysicalReturn && canonicalSend != "unsupported_pair")) ? .object(["kind": .string("stereo_output")])
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
                        names: canonicalName ? [.init(target: "source", name: "Selected Canonical")] : [],
                        capture: altered, request: request, snapshotCurrent: true)
                    let executable = try #require(sharedJSONObject(blocked.json)?["executable"] as? Bool)
                    #expect(!executable)
                    #expect(f.routingDestinationPresses == 0)
                    if canonicalName { #expect(f.routingNameWrites.isEmpty) }
                    return
                }
                var planArguments: [String: Value] = ["snapshot_id": .string(id), "policy": .object(policy)]
                if canonicalName {
                    #expect(ExactTrackNameAdapter.hasCapturedCoupledFootprint(.init(projectReference: project,
                        targetReference: target, expectedBefore: "Duplicate", desiredAfter: "Selected Canonical"), capture: capture))
                    planArguments["names"] = .array([.object([
                        "target": .string("source"), "name": .string("Selected Canonical")])])
                }
                let plannedText = sharedToolText(await planHandler(dependencies, planArguments))
                let planned = try #require(sharedJSONObject(plannedText))
                if canonicalBusReceiverFault?.hasPrefix("missing_") == true
                    && !(canonicalBusStereoReturn && canonicalBusReceiverFault == "missing_after") {
                    let executable = try #require(planned["executable"] as? Bool)
                    #expect(!executable)
                    #expect(f.routingDestinationPresses == 0)
                    #expect(f.routingBusLeafPresses.isEmpty)
                    return
                }
                if ["physical_slot", "mixed", "unsupported_pair", "physical_removal", "nonmatching_bus"].contains(canonicalSend) {
                    let executable = try #require(planned["executable"] as? Bool)
                    #expect(!executable)
                    #expect(f.routingDestinationPresses == 0)
                    if canonicalName { #expect(f.routingNameWrites.isEmpty) }
                    return
                }
                let executable = try #require(planned["executable"] as? Bool)
                try #require(executable, "Actual plan: \(plannedText)")
                let planID = try #require(planned["plan_id"] as? String)
                let digest = try #require(planned["digest"] as? String)
                let preview = try #require(planned["steps"] as? [[String: Any]])
                let contradictionsBeforeApply = f.routingCanonicalContradictedInputs.count
                if canonicalBusReceiverFault?.hasSuffix("after_preview") == true { f.routingLateScopeInjected = true }
                if sourceInputReadRenewal || canonicalBusReceiverFault == "physical_source"
                    || canonicalBusReceiverFault == "physical_source_scoped_input" {
                    f.routingInputReadRenewalArmed = true
                }
                if canonicalName {
                    try #require(executable, "The combined task must be executable, not a supported subset")
                    if initialNameRailFocus {
                        let focus: AXUIElement = try #require(AXHelpers.getAttribute(f.app,
                            kAXFocusedUIElementAttribute as String, runtime: b.makeAXRuntime()))
                        #expect(CFEqual(focus, f.rail), "The accepted capture must retain the observed initial rail focus")
                        #expect(f.routingNameWrites.isEmpty && f.routingDestinationPresses == 0)
                    }
                    #expect(preview.count == 2)
                    #expect(preview.first?["kind"] as? String == "name")
                    #expect(preview.last?["kind"] as? String == "local_send_output")
                    #expect(preview.last?["dependencies"] as? [String] == ["name_source"])
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
                    if canonicalSend == "expired" { f.expireRetainedCapture = true }
                    let result: CallTool.Result
                    if measureChangedPermissionCensus {
                        result = await AccessibilityChannel.$sendChangeObserver.withValue({ proof in
                            let priorChildrenRead = f.routingChildrenRead
                            f.routingChildrenRead = { element in
                                priorChildrenRead?(element)
                                if CFEqual(element, proof.control.list) {
                                    f.routingChangedPermissionControlWalks += 1
                                }
                            }
                            defer { f.routingChildrenRead = priorChildrenRead }
                            f.routingChangedPermissionControlWalks = 0
                            let current = AXLogicProElements.assignedSendMenuControl(in: proof.source.pair.strip.strip,
                                ordinal: proof.control.ordinal, runtime: f.logic().ax)
                            if let current {
                                #expect(proof.control.matches(current),
                                    "Measure the current native control from the actual published effect")
                            } else { Issue.record("The actual published effect must retain its current native control") }
                            let singleCensusControlWalks = f.routingChangedPermissionControlWalks
                            #expect(singleCensusControlWalks > 0, "The independent calibration must actually walk the native Send control")
                            f.routingChangedPermissionControlWalks = 0
                            #expect(proof.permits(runtime: f.logic()), "The actual current effect remains owned")
                            print("Changed Send control walks: calibration=\(singleCensusControlWalks), custody=\(f.routingChangedPermissionControlWalks)")
                            #expect(f.routingChangedPermissionControlWalks == singleCensusControlWalks,
                                "Control identity and protected slots need one complete native Send census, retaining its source/Help bookends")
                            f.routingChangedSendPublished = true
                        }) { await apply(dependencies, arguments) }
                    } else { result = await apply(dependencies, arguments) }
                    let body = try #require(sharedJSONObject(sharedToolText(result)))
                    try f.expectCanonicalInverseMeasurements(body, measuringAssociations: measureInverseAssociations,
                        singleWriterPopup: singleInverseWriterPopup)
                    if restoredNameCaption?.verifyRefusal(f, body: body) == true { return }
                    if sourceInputReadRenewal { #expect(f.routingInputReadRenewed, "Reach the actual owned Input source renewal") }
                    if let fault = peerDisplaySecondSampleFault {
                        #expect(f.peerHydrationFaultInjected && f.peerHydrationSamples.count >= 2,
                            "The fault must reach two distinct actual native population samplers after the owned name")
                        #expect(f.routingNameWrites.first == "Selected Canonical")
                        #expect(f.routingDestinationPresses == 0 && f.routingBusLeafPresses.isEmpty)
                        #expect(body["state"] as? String != "A" && body["saga_state"] as? String != "completed",
                            "Actual corroboration refusal: \(sharedToolText(result))")
                        if fault == "input" {
                            #expect(b.attributeValue(hydrationInput, kAXDescriptionAttribute as String) as? String == "Bus 10")
                        }
                        if fault == "slot" {
                            #expect(b.makeAXRuntime().children(hydrationPeer!).contains { CFEqual($0, b.element(1_971_804)) })
                        }
                        if fault == "project" {
                            #expect(b.attributeValue(f.window, kAXDocumentAttribute as String) as? String == "file:///tmp/Foreign.logicx")
                        }
                        return
                    }
                    try f.expectNamedSendInputFootprint()
                    if expireInspectionBeforeSendDispatch {
                        #expect(f.captureExpiredAtCheckedSendDispatch)
                        #expect(f.expireRetainedCapture)
                        #expect(await cache.retainedInspection(id: id) == nil)
                    }
                    if expireInspectionBeforeSendRead {
                        #expect(f.inspectionExpiredBeforeSendRead)
                        #expect(await cache.retainedInspection(id: id) == nil)
                    }
                    if mixerNameAfterInputRead != nil {
                        #expect(f.routingNamePropagatedDuringInputRead,
                            "The changed Mixer name must be observed after an actual owned name and input popup")
                    }
                    if canonicalBusReceiverFault?.hasPrefix("checked_") == true {
                        #expect(f.routingCanonicalContradictedInputs.count > contradictionsBeforeApply,
                            "The named task must reach the actual changed input proof")
                        let afterForward = canonicalBusReceiverFault?.hasSuffix("after_forward") == true
                        let expectedDestinationPresses: Int = afterForward ? 1 : 0
                        #expect(f.routingDestinationPresses == expectedDestinationPresses)
                        #expect(f.routingBusLeafPresses == (afterForward ? [2] : []),
                            "A changed receiver cannot authorize the forward or owned inverse leaf")
                        #expect(body["state"] as? String == (afterForward ? "B" : "C"),
                            "Actual named refusal: \(sharedToolText(result))")
                        #expect(body["saga_state"] as? String == (afterForward ? "partiallyCompensated" : "fullyCompensated"))
                        #expect(f.routingNameWrites == ["Selected Canonical", "Duplicate"])
                        #expect(b.attributeValue(f.headers[0], kAXTitleAttribute as String) as? String == "Duplicate")
                    } else if decidingSendFault == "mode" {
                        #expect(f.routingDecidingSendFaultInjected, "Reach the renewed source's actual deciding writer popup")
                        #expect(f.routingDestinationPresses == 0 && f.routingBusLeafPresses.isEmpty)
                        #expect(body["state"] as? String == "C")
                        #expect(body["saga_state"] as? String == "fullyCompensated")
                        #expect(f.routingNameWrites == ["Selected Canonical", "Duplicate"])
                        #expect(b.attributeValue(mode, "AXMenuItemMarkChar") as? String == "")
                        #expect(b.attributeValue(preFader, "AXMenuItemMarkChar") as? String == "✓",
                            "The refusal retains the external mode change")
                    } else if inverseNameFault != nil {
                        #expect(f.routingLateScopeInjected)
                        #expect(body["saga_state"] as? String == "rollbackUncertain")
                        #expect(f.routingNameWrites == (inverseNameFault == "late_membership"
                            ? ["Selected Canonical", "Duplicate"] : ["Selected Canonical"]))
                        #expect(f.routingDestinationPresses == 2)
                        #expect(b.attributeValue(f.headers[0], kAXTitleAttribute as String) as? String
                            == (inverseNameFault == "late_membership" ? "Duplicate" : "Selected Canonical"))
                    } else if mixerNameAfterInputRead == "External" {
                        #expect(body["state"] as? String == "B")
                        #expect(body["saga_state"] as? String == "rollbackUncertain")
                        #expect(f.routingNameWrites == ["Selected Canonical"])
                        #expect(f.routingDestinationPresses == 0 && f.routingBusLeafPresses.isEmpty)
                        #expect(b.attributeValue(f.headers[0], kAXTitleAttribute as String) as? String == "Selected Canonical")
                        #expect(b.attributeValue(f.routingReplacement == nil || stableDestinationControls
                            ? b.element(1_965_711) : name, kAXValueAttribute as String) as? String == "External")
                    } else if delayedMixerName == "External" {
                        #expect(body["state"] as? String == "B")
                        #expect(body["saga_state"] as? String != "completed")
                        #expect(body["saga_state"] as? String != "fullyCompensated")
                        #expect(f.routingNameWrites == ["Selected Canonical"])
                        #expect(b.attributeValue(stableDestinationControls ? b.element(1_965_711) : name,
                            kAXValueAttribute as String) as? String == "External")
                    } else if canonicalSend == "late_name" {
                        #expect(f.routingLateScopeInjected)
                        #expect(f.routingNameWrites == ["Selected Canonical"])
                        #expect(f.routingDestinationPresses == 0, "The later Send must refuse after the approved name is lost")
                        #expect(b.attributeValue(f.headers[0], kAXTitleAttribute as String) as? String == "External")
                        #expect(body["saga_state"] as? String != "completed")
                        #expect(body["saga_state"] as? String != "fullyCompensated")
                    } else if ["replacement", "wrong_digest", "wrong_project", "expired"].contains(canonicalSend) {
                        #expect(body["state"] as? String == "C", "Actual refusal: \(sharedToolText(result))")
                        #expect(f.routingNameWrites.isEmpty && f.routingDestinationPresses == 0)
                    } else {
                        let compensated = canonicalSend == "cancel" || canonicalSend == "late_replacement"
                        #expect(body["saga_state"] as? String == (compensated ? "fullyCompensated" : "completed"),
                            "Actual apply: \(sharedToolText(result))")
                        #expect(f.routingNameWrites == (compensated ? ["Selected Canonical", "Duplicate"] : ["Selected Canonical"]))
                        #expect(f.routingDestinationPresses == (canonicalSend == "late_replacement" ? 0 : compensated ? 2 : 1))
                        #expect(b.attributeValue(f.headers[0], kAXTitleAttribute as String) as? String == (compensated ? "Duplicate" : "Selected Canonical"))
                        if mixerNameAfterInputRead != nil {
                            #expect(b.attributeValue(f.routingReplacement == nil || stableDestinationControls
                                ? b.element(1_965_711) : name, kAXValueAttribute as String) as? String
                                == (compensated ? "Duplicate" : "Selected Canonical"))
                        }
                        if canonicalSend == "late_replacement" {
                            #expect(f.routingLateScopeInjected && f.routingBypassMenuOpens == 0)
                        }
                    }
                    let writes = f.routingDestinationPresses
                    let nameWrites = f.routingNameWrites
                    if inverseNameMenu {
                        #expect(f.routingMenuNameOpens == 1)
                        #expect(f.routingNameConfirms == (inverseNameFault == nil || inverseNameFault == "late_membership" ? 2 : 1))
                        if inverseNameFault == nil {
                            let expectedClicks: [CGEventType] = initialNameRailFocus ? [] : forwardNameMovesFocus
                                ? [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp]
                                : [.leftMouseDown, .leftMouseUp]
                            #expect(f.routingFocusClickEvents == expectedClicks)
                            let focus: AXUIElement = try #require(AXHelpers.getAttribute(f.app,
                                kAXFocusedUIElementAttribute as String, runtime: b.makeAXRuntime()))
                            #expect(CFEqual(focus, initialNameRailFocus ? f.rail : f.strips[1]))
                            let steps = try #require(body["steps"] as? [[String: Any]])
                            #expect(steps.count == 2)
                            for step in steps {
                                let compensation = try #require(step["compensation"] as? [String: Any])
                                #expect(compensation["disposition"] as? String == "verified")
                            }
                            restoredNameCaption?.verify(f)
                        }
                    }
                    _ = await apply(dependencies, arguments)
                    #expect(f.routingDestinationPresses == writes && f.routingNameWrites == nameWrites)
                    #expect(!gate.isHeldByEntitledHolder())
                    return
                }
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
                    let expected = canonicalBus ? OutputAssignment.bus(1)
                        : freshPhysicalReturn ? .physical(3, 4) : .stereoOutput
                    #expect(read["observed"] as? String == expected.token)
                    let readsBeforeReplay = f.routingBypassMenuOpens
                    _ = await apply(dependencies, arguments)
                    #expect(f.routingDestinationPresses == 0)
                    #expect(f.routingBypassMenuOpens == readsBeforeReplay)
                    #expect(!gate.isHeldByEntitledHolder())
                    return
                }
                #expect(preview.count == 1 && preview[0]["kind"] as? String == (canonicalPhysical || canonicalBusChange ? "local_send_output" : "local_send_removal"))
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
                if scopedInputAdditionalWindow {
                    let additional = b.element(1_971_999)
                    b.setRole(additional, kAXWindowRole as String)
                    b.setAttribute(additional, kAXTitleAttribute as String, "Auxiliary")
                    b.setChildren(additional, [])
                    b.setAttribute(f.app, kAXWindowsAttribute as String, [f.window, additional])
                    let unrelated = b.element(1_971_998)
                    b.setRole(unrelated, kAXGroupRole as String)
                    b.setChildren(unrelated, [])
                    let container = b.element(1_971_997)
                    b.setRole(container, kAXGroupRole as String)
                    b.setChildren(container, [unrelated])
                    // Modal guards inspect direct window children. Only a full
                    // descendant walk reaches this unrelated nested probe.
                    b.setChildren(f.window, b.makeAXRuntime().children(f.window) + [container])
                    f.routingInputDiscoveryProbe = unrelated
                }
                let apply = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "apply_session_repair"))
                let arguments: [String: Value] = ["plan_id": .string(planID),
                    "digest": .string(canonicalSend == "wrong_digest" ? String(repeating: "0", count: 64) : digest),
                    "confirmed": .bool(true), "idempotency_key": .string(key)]
                let result: CallTool.Result
                let inputReadsBeforeApply = f.routingCanonicalInputBuses.count
                if decidingSendFault != nil { f.routingBeforeSendMenuOpens = 0 }
                if let decidingSendFault, decidingSendFault.hasPrefix("late_") {
                    let priorActions = f.routingActionNames, priorRead = f.routingRead
                    @Sendable func changeMode() {
                        b.setAttribute(mode, "AXMenuItemMarkChar", "")
                        b.setAttribute(preFader, "AXMenuItemMarkChar", "✓")
                        f.routingDecidingSendFaultInjected = true
                    }
                    f.routingActionNames = { element in
                        let prior = priorActions?(element)
                        if CFEqual(element, b.element(1_971_503)),
                           SendRemovalSagaAdapter.requiredBeforeState != nil,
                           f.routingDestinationPresses == 0 {
                            f.routingDecidingLeafActionsRead = true
                            if decidingSendFault == "late_action_mode", !f.routingDecidingSendFaultInjected { changeMode() }
                        }
                        return prior
                    }
                    f.routingRead = { element, attribute in
                        priorRead?(element, attribute)
                        guard f.routingDecidingLeafActionsRead, !f.routingDecidingSendFaultInjected,
                              SendRemovalSagaAdapter.requiredBeforeState != nil else { return }
                        if CFEqual(element, mode), attribute == "AXMenuItemMarkChar" { f.routingDecidingModeRead = true }
                        if f.routingDecidingModeRead, CFEqual(element, b.element(1_971_503)),
                           attribute == kAXTitleAttribute as String {
                            f.routingDecidingFinalChoiceRead = true
                            if decidingSendFault == "late_choice_mode" { changeMode() }
                        }
                        if decidingSendFault == "late_bus_mode", f.routingDecidingFinalChoiceRead,
                           CFEqual(element, b.element(1_971_502)), attribute == kAXHelpAttribute as String { changeMode() }
                    }
                }
                if canonicalBusReceiverFault == "checked_inverse_help" {
                    result = await AccessibilityChannel.$sendChangeObserver.withValue({ _ in
                        f.routingChangedSendPublished = true
                    }) { await apply(dependencies, arguments) }
                } else { result = await apply(dependencies, arguments) }
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                try f.expectCanonicalInverseMeasurements(body, measuringAssociations: measureInverseAssociations,
                    singleWriterPopup: singleInverseWriterPopup)
                if let decidingSendFault {
                    if decidingSendFault == "healthy" {
                        #expect(f.routingBeforeSendMenuOpens == 4,
                            "Keep approval, prerequisite and independent Saga reads plus the deciding writer; remove only the duplicate adapter read-and-Cancel lifecycle")
                    } else {
                        #expect(f.routingDecidingSendFaultInjected, "Reach the actual deciding writer popup")
                        #expect(body["state"] as? String == "C", "Changed approved before-state must refuse before a Send leaf: \(sharedToolText(result))")
                        #expect(f.routingDestinationPresses == 0)
                        if decidingSendFault.hasSuffix("mode") {
                            #expect(b.attributeValue(mode, "AXMenuItemMarkChar") as? String == "")
                            #expect(b.attributeValue(preFader, "AXMenuItemMarkChar") as? String == "✓",
                                "Refusal must retain the externally changed mode")
                        }
                        #expect(!gate.isHeldByEntitledHolder())
                        return
                    }
                }
                if canonicalBusReceiverFault == "physical_source_scoped_input" {
                    #expect(f.routingInputOpenDiscoveryCounts.count >= (canonicalSend == "cancel" ? 6 : 3),
                        "Reach checked source and both receivers, including inverse prerequisites when cancelling")
                    #expect(f.routingInputOpenDiscoveryCounts.allSatisfy { $0 == 0 },
                        "Read the admitted original native census instead of rediscovering the whole window during Input popups: \(f.routingInputOpenDiscoveryCounts)")
                    #expect(f.routingInputOpenWindowScans == 0,
                        "An admitted Input popup must not rescan the whole Arrange window when another non-dialog window exists")
                }
                if sourceInputReadRenewal {
                    #expect(f.routingInputReadRenewed, "Reach actual post-menu retirement before routing")
                }
                if inverseInputReadRenewal, canonicalBusReceiverFault != "physical_source_inverse_read_renewal" {
                    #expect(f.routingBusLeafPresses == (canonicalBusStereoReturn ? [] : [2]), "Read renewal must not adopt any changed protected value")
                    #expect(f.routingDestinationPresses == 1)
                    #expect(body["saga_state"] as? String != "fullyCompensated")
                    #expect(!gate.isHeldByEntitledHolder())
                    return
                }
                if canonicalBusReceiverFault == "checked_inverse_help" {
                    #expect(f.routingChangedSendPublished)
                    #expect(f.routingLateScopeInjected, "Reach the actual post-effect Send control Role read")
                    #expect(f.routingForeignHelpReads == 0,
                        "A later scope refusal cannot excuse foreign-scope Help reads: \(f.routingForeignHelpFirstStack.joined(separator: "\n"))")
                    #expect(f.routingBusLeafPresses == [2])
                    #expect(body["saga_state"] as? String != "fullyCompensated")
                    #expect(!gate.isHeldByEntitledHolder())
                    return
                }
                if canonicalBusReceiverFault?.hasPrefix("checked_") == true {
                    if canonicalBusStereoReturn {
                        #expect(f.routingCanonicalContradictedInputs.count > contradictionsBeforeApply,
                            "Refusal must reach the actual changed input proof, not an earlier unsupported path")
                        let expectedDestinationPresses: Int = canonicalBusReceiverFault?.hasSuffix("after_forward") == true ? 1 : 0
                        #expect(f.routingDestinationPresses == expectedDestinationPresses)
                    }
                    if canonicalBusReceiverFault?.hasSuffix("after_forward") == true {
                        #expect(f.routingBusLeafPresses == (canonicalBusStereoReturn ? [] : [2]), "An invalid original receiver must prevent the owned inverse")
                        #expect(body["saga_state"] as? String != "fullyCompensated")
                    } else {
                        #expect(body["state"] as? String == "C", "Actual refusal: \(sharedToolText(result))")
                        #expect(f.routingBusLeafPresses.isEmpty, "No routing leaf may run from a misleading receiver caption")
                        #expect(f.routingDestinationPresses == 0)
                    }
                    #expect(!gate.isHeldByEntitledHolder())
                    return
                }
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
                    if canonicalBusChange {
                        let expectedBusLeaves = canonicalBusStereoReturn
                            ? (canonicalSend == "cancel" ? [1] : []) : (canonicalSend == "cancel" ? [2, 1] : [2])
                        #expect(f.routingBusLeafPresses == expectedBusLeaves)
                        if canonicalBusStereoReturn {
                            let checkedInputs = f.routingCanonicalInputBuses.dropFirst(inputReadsBeforeApply)
                            #expect(checkedInputs.filter { $0 == 1 }.count >= (canonicalSend == "cancel" ? 2 : 1))
                            #expect(!checkedInputs.contains(2), "An unrelated Bus receiver is not a routing prerequisite")
                            if canonicalBusReceiverFault?.contains("source") == true {
                                #expect(checkedInputs.contains(0))
                            }
                        }
                        if canonicalBusReceiverFault == "physical_source" {
                            #expect(f.routingSourceInputFreshHeaderChallenges >= (canonicalSend == "cancel" ? 2 : 1),
                                "Each checked physical-input read must actually renew its original native header before old-source Help")
                        }
                        let steps = try #require(body["steps"] as? [[String: Any]])
                        let evidence = try #require(steps.first?["evidence"] as? [String: Any])
                        let verification = try #require(evidence["verification"] as? [String: Any])
                        let readback = try #require(verification["readback"] as? [String: Any])
                        #expect(readback["observed"] as? String == (canonicalBusStereoReturn ? .stereoOutput : OutputAssignment.bus(2)).token)
                        if canonicalSend == "cancel" {
                            let compensation = try #require(steps.first?["compensation"] as? [String: Any])
                            let restored = try #require(compensation["readback"] as? [String: Any])
                            #expect(restored["observed"] as? String == OutputAssignment.bus(1).token)
                        }
                    }
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
                if ["late_bit", "measure_late_bit"].contains(bypassMode ?? ""), f.routingBypassMenuCancels == 3 {
                    if CFEqual(element, b.element(1_965_2622)), attribute == kAXValueAttribute as String {
                        f.routingBypassFinalValueReads += 1
                    }
                }
                if ["late_inverse_mode", "late_inverse_bus_receiver"].contains(sagaMode ?? ""), f.routingDestinationPresses == 1,
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
            let router = ChannelRouter()
            if let boundary = bypassBoundary {
                await router.register(SendRemovalSagaResultBoundary(base: f.channel(), journal: SagaJournal(),
                    mode: "observe", operation: "mixer.set_send_bypass_verified",
                    beforeForward: { boundary.insideNativeWriter = true },
                    observedResult: { _ in boundary.insideNativeWriter = false }))
            } else { await router.register(f.channel()) }
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
                    // Exercise each actual custody census following a new
                    // post-write checkbox observation. Unrelated whole-window
                    // discovery counts do not choose the race boundary.
                    guard let boundary = bypassBoundary, boundary.insideNativeWriter,
                          f.routingBypassMenuCancels == 3,
                          f.routingBypassFinalValueReads > 0, CFEqual(element, f.mixer),
                          boundary.lastValueReads != f.routingBypassFinalValueReads else { return }
                    boundary.lastValueReads = f.routingBypassFinalValueReads
                    boundary.censuses += 1
                    guard bypassMode == "late_bit", boundary.censuses == boundary.injectAt,
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
                    if bypassMode == "measure_late_bit" {
                        #expect(body["state"] as? String == "A", "\(sharedToolText(result))")
                        #expect(f.routingBypassPresses == 1 && f.routingBypassMenuCancels == 3)
                        return
                    }
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
                    #expect(body["state"] as? String == (afterAttempt ? "B" : "C"),
                        "Native census \(bypassBoundary?.injectAt ?? 0) of \(bypassBoundary?.censuses ?? 0): \(sharedToolText(result))")
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
                preparedParams["expected_current"] = freshBusStereoReturn
                    ? .object(["kind": .string("bus"), "number": .int(1)])
                    : .object(["kind": .string("physical"), "ports": .array([.int(3), .int(4)])])
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
                            case "late_inverse_missing_bus_receiver":
                                b.setAttribute(b.element(1_965_2680), kAXDescriptionAttribute as String, "Bus 2")
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
                if ["late_inverse_missing_bus_receiver", "late_inverse_bus_receiver"].contains(sagaMode) {
                    #expect(f.routingLateScopeInjected && f.routingDestinationPresses == 1)
                    let state = try #require(body["saga_state"] as? String)
                    #expect(["compensationFailed", "rollbackUncertain"].contains(state))
                    #expect(b.attributeValue(b.element(1_965_2680), kAXDescriptionAttribute as String) as? String == "Bus 2")
                    #expect(!gate.isHeldByEntitledHolder())
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
                    #expect(beforeState["observed"] as? String == (freshBusStereoReturn ? "bus:1" : "physical:3-4"))
                    let verification = try #require(evidence["verification"] as? [String: Any])
                    let readback = try #require(verification["readback"] as? [String: Any])
                    #expect(readback["observed"] as? String == "stereo_output")
                    if !completed {
                        let compensation = try #require(steps[0]["compensation"] as? [String: Any])
                        let inverseReadback = try #require(compensation["readback"] as? [String: Any])
                        #expect(inverseReadback["observed"] as? String == (freshBusStereoReturn ? "bus:1" : "physical:3-4"))
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

    private func assertCapturedInputIntent(capture: SessionPopulationObservation.Capture, graph: RoutingGraph,
                                          originalHeader: AXUIElement, number: Int, inputGoal: Int) throws {
        guard case .issued(let project)? = capture.projectIssuance else {
            Issue.record("The actual capture must issue its project reference"); return
        }
        let tracks = capture.tracks.filter { $0.physicalBinding.map { CFEqual($0.header, originalHeader) } == true }
        #expect(tracks.count == 1)
        let track = try #require(tracks.first)
        let reference = try #require(capture.issued?.byTrackIndex[track.id])
        let raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
            "project_ref": .string(project.rawValue),
            "targets": .array([.object(["handle": .string("source"), "track_ref": .string(reference.rawValue)])]),
            "inputs": .array([.object(["target": .string("source"), "bus": .int(inputGoal)])])]
        guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
            Issue.record("The explicit input intent must parse"); return
        }
        let assessment = ProjectSessionAudit.assessIntent(policy: policy, capture: capture, graph: graph)
        let findings = try #require(assessment.inputFindings)
        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.status == (inputGoal == number ? .compliant : .violation))
        #expect(finding.observed?.objectValue?["kind"] == .string("bus"))
        #expect(finding.observed?.objectValue?["number"] == .int(number))
        #expect(finding.target.trackRef == reference.rawValue)
        let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
            names: [], capture: capture, request: .init(scope: .selection,
                domains: [.tracks, .strips, .associations, .routing], allowUINavigation: true), snapshotCurrent: true)
        let preview = try #require(sharedJSONObject(plan.json))
        let steps = try #require(preview["steps"] as? [[String: Any]])
        let input = try #require(steps.first { $0["kind"] as? String == "input_assignment" })
        #expect((input["before"] as? [String: Any])?["kind"] as? String == "bus")
        #expect((input["before"] as? [String: Any])?["number"] as? Int == number)
        let executable = try #require(preview["executable"] as? Bool)
        #expect(!executable, "A historical checked value is not a retained canonical execution adapter")
    }

    private func assertInputBusRenewal(number: Int, condition: String, graph: Bool = false, keep: Bool = false,
                                      readOutputAfterRenewal: Bool = false, inputGoal: Int? = nil) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await runInputBusRenewal(number: number, condition: condition, graph: graph, keep: keep,
                readOutputAfterRenewal: readOutputAfterRenewal, inputGoal: inputGoal)
        }
    }

    private func runInputBusRenewal(number: Int, condition: String, graph: Bool, keep: Bool,
                                    readOutputAfterRenewal: Bool, inputGoal: Int?) async throws {
        let hasUnrequestedPeer = condition.hasPrefix("cold_rail_input_unrequested_peer")
        let f = try Fixture(fourTracks: hasUnrequestedPeer), registry = TargetRegistry()
        let coldRailInput = condition.hasPrefix("cold_rail_input_")
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
        if condition == "transient_cancel_geometry" {
            f.setInputGeometry(top: 350, renewed: false)
        }
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
                if condition.hasPrefix("force_fresh_"), !condition.hasSuffix("retired_source") {
                    f.builder.setChildren(f.mixer, f.strips)
                    if condition == "force_fresh_changed_label" {
                        f.builder.setAttribute(input, kAXDescriptionAttribute as String, "Bus 9")
                    } else if condition == "force_fresh_foreign_project" {
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                    return true
                }
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
                if condition == "transient_cancel_geometry" {
                    // Native Cancel briefly reports every new strip 15 points
                    // lower. The existing selection excursion settles them
                    // back to the actual pre-popup viewport, not this transient.
                    f.setInputGeometry(top: 365, renewed: true)
                }
                if retiresWholeCensus { f.routingOtherReplacement = otherReplacement }
                if condition == "retirement_census_lag" {
                    f.inputRetirementCensusLag = true
                    f.inputRetiredSourceReadable = true
                }
                f.builder.setChildren(f.mixer, [f.routingOtherReplacement ?? f.strips[0], replacement]
                    + Array(f.strips.dropFirst(2)) + unpairedRows + (condition == "popup_still_open" ? [root] : []))
                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                    condition.hasPrefix("force_fresh_rail_") || coldRailInput ? f.rail
                        : condition == "unselected_pair" ? f.strips[0] : replacement)
                if coldRailInput {
                    f.builder.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [replacement])
                }
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
        let firstChallengeRetiresPeer = condition == "cold_rail_input_peer_retired"
            || condition == "cold_rail_input_unrequested_peer_changed"
        if firstChallengeRetiresPeer || condition == "cold_rail_input_unrequested_peer" {
            f.routingSelection = { index in
                guard f.inputMenuCancels == 1, !f.routingLateScopeInjected else { return }
                if !firstChallengeRetiresPeer, index != 2 { return }
                f.routingLateScopeInjected = true
                // Native cold capture: Cancel retained the original rail focus,
                // then a peer CF retired during the original-header excursion.
                // The checked popup's earlier focus receipt cannot prove this
                // later selection inverse, and lost custody forbids forcing it.
                f.builder.setRole(otherReplacement, kAXLayoutItemRole as String)
                f.builder.setChildren(otherReplacement,
                    f.builder.makeAXRuntime().children(f.strips[hasUnrequestedPeer ? 3 : 0]))
                if hasUnrequestedPeer {
                    f.builder.setChildren(f.mixer, [f.strips[0], replacement, f.strips[2], otherReplacement])
                } else {
                    f.routingOtherReplacement = otherReplacement
                    f.builder.setChildren(f.mixer, [otherReplacement, replacement])
                }
            }
        } else if condition == "partial_restore" {
            f.routingSelection = { _ in
                if f.selections.count == (graph ? 5 : 3) {
                    f.routingLateScopeInjected = true
                    f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                }
            }
        }
        f.routingRead = { element, attribute in
            if condition == "transient_cancel_geometry", f.routingReplacement != nil,
               f.selections.count > (graph ? 4 : 2) {
                f.inputTransientGeometrySettled = true
                f.setInputGeometry(top: 350, renewed: true)
            }
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
        let before = try await inspect(f, cache: cache, registry: registry,
            scope: hasUnrequestedPeer ? "selection" : "whole_project")
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
        if condition.hasPrefix("force_fresh_") {
            let gate = LogicMutationGate()
            let claim = try #require(gate.tryAcquire(operation: "fresh-original-input-read"))
            defer { gate.release(claim) }
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
            let suppliedPair: AccessibilityChannel.HeldSelectionAssociation.Pair? = condition == "force_fresh_missing_pair"
                ? nil : condition == "force_fresh_wrong_pair" ? .init(track: pair.track,
                    strip: .init(window: f.window, mixer: f.mixer, strip: f.strips[0], document: f.bundle.absoluteString)) : pair
            let railEntry = condition.hasPrefix("force_fresh_rail_")
            if railEntry {
                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
                let previousResult = f.routingReadResult
                f.routingReadResult = { element, attribute in
                    if CFEqual(element, f.rail), [kAXValueAttribute, kAXSelectedTextAttribute,
                        kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute]
                        .map({ $0 as String }).contains(attribute) {
                        // Native non-editor absence, not an unknown success(nil).
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    return previousResult?(element, attribute)
                }
                let previousRead = f.routingRead
                f.routingRead = { element, attribute in
                    previousRead?(element, attribute)
                    if CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String,
                       f.inputMenuCancels > 0, f.selections.count > 2, f.selections.last == 0 {
                        // Like the native Tracks entry, returning our original
                        // selected header restores its original rail focus.
                        f.builder.setAttribute(f.app, attribute, f.rail)
                    }
                    if CFEqual(element, f.mixer), attribute == kAXSelectedChildrenAttribute as String {
                        let originalSelected = AXValueExtractors.extractSelectedState(f.headers[0],
                            runtime: f.builder.makeAXRuntime()) == true
                        f.builder.setAttribute(f.mixer, attribute,
                            [originalSelected ? f.routingReplacement ?? f.strips[1] : f.strips[0]])
                    }
                }
            }
            let (read, permittedInClaim) = try await OperationTraceContext.$current.withValue(context) {
                let focus = AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope()
                let proof: AccessibilityChannel.HeldSelectionAssociation?
                if railEntry {
                    proof = try #require(AccessibilityChannel.HeldSelectionAssociation(
                        window: f.window, logic: f.logic(), expectedProject: nil, requiresProjectReference: false,
                        allowsSelectedChildRailEntry: true))
                } else { proof = nil }
                let guardian = AXHelpers.HelpReadGuard(allowHelpReads: true,
                    stop: { proof.map { !focus.permits() && !$0.permitsRead() } ?? false })
                let reading = await AXHelpers.HelpReadGuard.$current.withValue(guardian) {
                    await AXMixerStripBinding.$current.withValue(source) {
                        await AXMixerStripBinding.$outputAssociation.withValue(suppliedPair) {
                            await AccessibilityChannel.getInputBusObservation(runtime: f.logic(), timing: .immediate,
                                observingPopupFocus: { focus.retainRoutingPopupFocus($0) },
                                observingRenewedFocus: { focus.retainAssociation($0) },
                                refreshingOriginalSourceAfterCleanup: true)
                        }
                    }
                }
                if railEntry { #expect(!guardian.stopped, "The old census cannot authorize Help before the fresh observation is retained") }
                return (reading, reading.inputRenewal?.permits(runtime: f.logic()) == true)
            }
            if ["force_fresh_missing_pair", "force_fresh_wrong_pair"].contains(condition) {
                let body = try #require(sharedJSONObject(read.result.message))
                #expect(body["state"] as? String == "C")
                #expect(read.assignment == nil && read.inputRenewal == nil)
                #expect(f.inputMenuPresses == 0 && f.inputMenuCancels == 0)
                #expect(f.selections == [1, 0])
                return
            }
            if ["force_fresh_changed_label", "force_fresh_foreign_project"].contains(condition) {
                let body = try #require(sharedJSONObject(read.result.message))
                #expect(body["state"] as? String == "C")
                #expect(read.assignment == nil && read.inputRenewal == nil && !permittedInClaim)
                #expect(f.inputMenuPresses == 1 && f.inputMenuCancels == 1, "Reach the actual post-Cancel change")
                #expect(f.routingDestinationPresses == 0)
                if condition == "force_fresh_foreign_project" { #expect(f.selections == [1, 0]) }
                return
            }
            #expect(read.assignment == .bus(number))
            let renewed = try #require(read.inputRenewal, "Observe the original header before any post-Cancel source Help")
            let survives = condition.hasSuffix("surviving_source")
            #expect(renewed.original.matches(source))
            #expect(renewed.pair.strip.matches(source) == survives)
            #expect(CFEqual(renewed.pair.strip.strip, survives ? source.strip : replacement))
            #expect(renewed.originalTrack.matches(pair.track) && permittedInClaim)
            #expect(!renewed.permits(runtime: f.logic()), "No retained native permission outside its own claim context")
            if survives {
                #expect(f.routingReplacement == nil)
            } else {
                #expect(f.routingReplacement != nil)
            }
            #expect(source.currentIndex(runtime: f.logic()) == (survives ? 1 : nil))
            #expect(f.inputMenuPresses == 1 && f.inputMenuCancels == 1)
            #expect(f.selections == [1, 0, 1, 0], "Actual native header challenges, not a JSON restoration receipt")
            #expect(!f.routingWrongSourcePressed && f.routingDestinationPresses == 0 && f.scrollWrites.isEmpty)
            return
        }
        if graph {
            if coldRailInput {
                f.selectionKeepsPassiveRailFocus = true
                f.builder.setAttributeSettable(f.rail, kAXValueAttribute as String, false)
                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
                f.builder.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.strips[1]])
                f.routingReadResult = { element, attribute in
                    if CFEqual(element, f.rail), [kAXValueAttribute, kAXSelectedTextAttribute,
                        kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute]
                        .map({ $0 as String }).contains(attribute) {
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    return nil
                }
            }
            let body = try await inspect(f, navigation: condition != "navigation_disabled", cache: cache,
                registry: registry, domains: keep || coldRailInput ? ["tracks", "strips", "associations", "routing"]
                    : condition == "missing_pair" ? ["routing"] : ["associations", "routing"],
                guardedRenewalFocus: !coldRailInput, scope: coldRailInput ? "selection" : "whole_project")
            let retained = if let id = body["snapshot_id"] as? String {
                await cache.retainedInspection(id: id)?.capture
            } else { nil as SessionPopulationObservation.Capture? }
            let routing = retained.map { SessionPopulationObservation.routingGraph(capture: $0) }
            let edges = routing?.edges.filter { $0.kind == .inputAssignment } ?? []
            if coldRailInput {
                #expect(f.inputMenuPresses == 1 && f.inputMenuCancels == 1)
                #expect(!f.routingWrongSourcePressed && f.routingDestinationPresses == 0 && f.scrollWrites.isEmpty)
                let effects = try #require(body["ui_effects"] as? [String: Any])
                if firstChallengeRetiresPeer {
                    #expect(f.routingLateScopeInjected && f.selections == [1, 0, 1, 0, 1],
                        "Reach the post-Cancel challenge, then refuse another write after its census retires")
                    let peerIsSelected = try #require(f.builder.attributeValue(f.headers[1], kAXSelectedAttribute as String) as? Bool)
                    #expect(peerIsSelected,
                        "The original header was not restored; a matching passive focus alone cannot claim otherwise")
                    let incomplete = try #require(retained)
                    let populationIsStable = try #require(incomplete.freshPopulation?.stable)
                    #expect(!populationIsStable,
                        "The report may retain an incomplete capture, but cannot preserve its earlier live authority")
                    let associations = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
                    #expect(associations.isEmpty)
                    #expect(effects["restoration"] as? String == "not_restored")
                    #expect(effects["reason"] as? String == "association_restoration_unverified")
                    guard case .issued(let originalProject)? = capture.projectIssuance else {
                        Issue.record("The original prepared capture must issue its project reference"); return
                    }
                    let raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
                        "project_ref": .string(originalProject.rawValue), "targets": .array([]),
                        "presentation": .object(["mixer_visible": .bool(false)])]
                    guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
                        Issue.record("The explicit visibility intent must parse"); return
                    }
                    let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
                        names: [], capture: incomplete,
                        request: .init(scope: .selection, domains: [.tracks, .strips, .associations, .routing],
                            allowUINavigation: true), snapshotCurrent: true)
                    let preview = try #require(sharedJSONObject(plan.json))
                    let executable = try #require(preview["executable"] as? Bool)
                    let reasons = try #require(preview["reasons"] as? [String])
                    #expect(!executable)
                    #expect(reasons.contains("project_view_binding_unavailable"),
                        "A cache-current snapshot still cannot authorize a repair through its failed acquisition")
                } else {
                    #expect(retained != nil && edges.count == 1)
                    #expect(f.selections == [1, 0, 1, 0, 1, 0])
                    #expect(effects["restoration"] as? String == "restored")
                    let originalIsSelected = try #require(f.builder.attributeValue(f.headers[0], kAXSelectedAttribute as String) as? Bool)
                    #expect(originalIsSelected)
                    if hasUnrequestedPeer {
                        #expect(!f.routingLateScopeInjected,
                            "The selected capture needs its original-header return, not an unrequested second peer excursion")
                    }
                }
                return
            }
            if let inputGoal {
                let fresh = try #require(retained)
                let observedGraph = try #require(routing)
                try assertCapturedInputIntent(capture: fresh, graph: observedGraph,
                    originalHeader: f.headers[0], number: number, inputGoal: inputGoal)
                #expect(f.routingDestinationPresses == 0 && !f.routingWrongSourcePressed)
                return
            }
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
            if condition != "paired" && condition != "retirement_census_lag" && condition != "unpaired_bus" && condition != "whole_census_retirement" && condition != "transient_cancel_geometry" {
                #expect(edges.isEmpty, "Lost original authority must not publish a bus input")
                #expect(!f.routingWrongSourcePressed && f.routingDestinationPresses == 0 && f.scrollWrites.isEmpty)
                if ["partial_restore", "deciding_read", "deciding_control_replaced", "whole_census_late_reorder"].contains(condition) {
                    #expect(f.routingLateScopeInjected, "The refusing late boundary must actually execute")
                }
                return
            }
            let fresh = try #require(retained)
            if condition == "transient_cancel_geometry" {
                #expect(f.inputTransientGeometrySettled, "Reach the actual post-Cancel selection settling")
                #expect(f.scrollWrites.isEmpty, "Already-restored pre-popup geometry needs no scroll inverse")
            }
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

    @Test("An input Saga compensates only its actual Bus change under its original pair",
          arguments: ["completed", "failure", "cancel", "wrong_target", "wrong_track", "wrong_project", "wrong_hash", "missing_hash",
                      "no_observer", "lost_observer", "late_inverse_input", "late_inverse_project",
                      "late_inverse_source", "late_inverse_control", "late_inverse_output",
                      "inverse_boundary_control", "inverse_boundary_sink", "inverse_boundary_peer",
                      "inverse_boundary_final_control", "inverse_boundary_final_sink", "inverse_boundary_final_peer",
                      "inverse_boundary_final_document_1", "inverse_boundary_final_document_4",
                      "retired_track_failure", "retired_track_cancel", "retired_track_changed_input", "retired_track_removed_header",
                      "retired_track_peer_failure", "retired_track_peer_cancel", "checked_inverse_input"])
    func registeredInputSagaOwnsItsActualCompensation(_ outcome: String) async throws {
        try await assertRegisteredInputSaga(outcome)
    }

    @Test("An approved singleton input repair reuses its checked capture, actual writer and journal",
          arguments: ["completed", "different_display", "owned_renewal", "owned_renewal_cancel", "owned_renewal_failure",
                      "cancel", "failure", "wrong_digest", "replaced_control", "foreign_project", "changed_peer", "foreign_focus",
                      "late_proof_document",
                      "dispatch_control", "dispatch_peer", "dispatch_focus", "late_inverse_input", "late_inverse_control",
                      "late_inverse_project", "late_inverse_output", "late_inverse_source", "no_observer", "lost_observer"])
    func canonicalInputRepairExecutesItsExactApprovedGoal(outcome: String) async throws {
        try await assertRegisteredInputSaga(outcome, canonical: true)
    }

    @Test(arguments: ["matching", "matching_different_display", "matching_renewal", "matching_renewal_rail", "matching_preopen_focus", "matching_checkmark", "matching_control",
                      "matching_project", "matching_focus", "matching_peer", "matching_cleanup", "matching_late_proof_document"])
    func matchingCanonicalInputUsesIndependentReadWithoutSetter(outcome: String) async throws {
        try await assertRegisteredInputSaga(outcome, canonical: true)
    }

    @Test("Selected receiver KEEP retains presentation only through the actual original-header input renewal",
          arguments: ["healthy", "no_type", "foreign_focus", "foreign_project"])
    func selectedReceiverKeepCaptureRenewsItsOriginalFocus(fault: String) async throws {
        try await assertRegisteredInputSaga("keep_capture_" + fault, canonical: true)
    }

    @Test func canonicalInputAndApprovedNameRetainOneOrderedPlan() async throws {
        try await assertRegisteredInputSaga("composed_name_preview", canonical: true)
    }

    @Test func matchingInputAndChangedOutputRetainBothApprovedGoals() async throws {
        try await assertRegisteredInputSaga("matching_output_preview", canonical: true)
    }

    @Test(arguments: ["completed", "source_renewal", "peer_renewal", "preflight_renewal", "ack_only", "wrong_digest", "before_control", "before_peer", "before_project",
                      "final_input", "final_output", "cancel"])
    func matchingInputAndChangedOutputExecuteOnlyTheOutputWriter(outcome: String) async throws {
        try await assertRegisteredInputSaga("matching_output_" + outcome, canonical: true)
    }

    @Test(arguments: ["completed", "different_display", "wrong_digest", "foreign_project", "changed_peer",
                      "changed_input", "replaced_control", "foreign_focus", "after_name_input", "external_name",
                      "between_name_input", "cancel", "preflight_renewal"])
    func changedNameDoesNotTurnAnAlreadyMatchingInputIntoASetter(outcome: String) async throws {
        try await assertRegisteredInputSaga("composed_name_matching_input_" + outcome, canonical: true)
    }

    @Test(arguments: ["completed", "wrong_digest", "foreign_project", "changed_peer", "changed_name",
                      "replaced_control", "foreign_focus", "dispatch_control", "dispatch_peer", "dispatch_name",
                      "owned_renewal", "owned_renewal_cancel", "cancel", "failure", "late_inverse_name"])
    func matchingApprovedNameRemainsAnObservedGoalDuringInputChange(outcome: String) async throws {
        try await assertRegisteredInputSaga("retained_name_" + outcome, canonical: true)
    }

    @Test(arguments: ["matching", "matching_different_display", "matching_renewal", "matching_renewal_rail",
                      "matching_preopen_focus", "matching_checkmark", "matching_control", "matching_project",
                      "matching_focus", "matching_peer", "matching_cleanup", "matching_late_proof_document",
                      "matching_name_before", "matching_final_name", "matching_final_checkmark",
                      "matching_between_name_input"])
    func alreadyMatchingNameAndInputAreBothIndependentlyVerified(outcome: String) async throws {
        try await assertRegisteredInputSaga("retained_name_" + outcome, canonical: true)
    }

    @Test(arguments: ["matching_peer_send", "retained_name_matching_peer_send",
                      "retained_name_matching_peer_send_changed", "retained_name_matching_peer_send_unread",
                      "retained_name_peer_send_changed_input", "composed_name_matching_input_peer_send",
                      "matching_output_peer_send", "retained_name_matching_peer_send_source"])
    func zeroWriteMatchingGoalsPreserveAnObservedOccupiedPeerSend(outcome: String) async throws {
        try await assertRegisteredInputSaga(outcome, canonical: true)
    }

    @Test(arguments: ["composed_name_execution", "composed_name_execution_preflight_renewal",
                      "composed_name_execution_wrong_digest", "composed_name_execution_foreign_project",
                      "composed_name_execution_changed_peer", "composed_name_execution_changed_input",
                      "composed_name_execution_replaced_control", "composed_name_execution_cancel",
                      "composed_name_execution_failure", "composed_name_execution_preflight_renewal_cancel",
                      "composed_name_execution_preflight_renewal_failure", "composed_name_execution_preflight_renewal_peer",
                      "composed_name_execution_preflight_renewal_project", "composed_name_execution_preflight_renewal_header",
                      "composed_name_execution_external_name", "composed_name_execution_caption_cancel",
                      "composed_name_execution_caption_peer_cancel", "composed_name_execution_caption_peer_changed_cancel",
                      "composed_name_execution_caption_project_cancel", "composed_name_execution_caption_control_cancel",
                      "composed_name_execution_caption_late_control_cancel", "composed_name_execution_caption_post_read_project_cancel",
                      "composed_name_execution_caption_header_refresh_cancel"])
    func canonicalInputAndApprovedNameExecuteBothActualWriters(outcome: String) async throws {
        try await assertRegisteredInputSaga(outcome, canonical: true)
    }

    @Test func canonicalInputStringsCannotConstructTheApprovedAdapter() {
        let step = SagaStep(operationID: .mixerSetInputBusVerified, targetRef: .init(rawValue: "trk_source"),
            params: ["destination": .object(["kind": .string("bus"), "number": .int(2)]),
                "expected_current": .object(["kind": .string("bus"), "number": .int(1)]), "replace_existing": .bool(true)],
            expectedInverse: .init(operationID: .mixerSetInputBusVerified, valueParameter: "destination"))
        let plain = SagaPlan(steps: [step], idempotencyKey: "input-custody-control")
        #expect(InputBusSagaAdapter(plan: plain) != nil)
        let forged = SagaPlan(steps: [step], idempotencyKey: "input-custody-forgery",
            canonicalPlanID: "plan_supplied", canonicalDigest: String(repeating: "0", count: 64))
        #expect(InputBusSagaAdapter(plan: forged) == nil)
        var unchanged = step.params
        unchanged["destination"] = .object(["kind": .string("bus"), "number": .int(1)])
        let noOp = SagaStep(operationID: step.operationID, targetRef: step.targetRef,
            params: unchanged, expectedInverse: step.expectedInverse)
        #expect(InputBusSagaAdapter(plan: .init(steps: [noOp], idempotencyKey: "generic-input-noop")) == nil)
    }

    private func injectForeignInputEditor(_ f: Fixture) {
        let editor = f.builder.element(1_291_498)
        f.builder.setRole(editor, kAXTextFieldRole as String)
        f.builder.setAttribute(editor, kAXValueAttribute as String, "Unrelated editor")
        f.builder.setChildren(editor, [])
        f.builder.setChildren(f.window, f.builder.makeAXRuntime().children(f.window) + [editor])
        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, editor)
    }

    private func assertCanonicalInputExecution(_ f: Fixture, dependencies: HandlerDependencies,
                                               snapshotID: String, capture: SessionPopulationObservation.Capture,
                                               trackReference: TargetReference, key: String, outcome requestedOutcome: String) async throws {
        let retainedName = requestedOutcome.hasPrefix("retained_name_")
        let outcome = retainedName ? String(requestedOutcome.dropFirst("retained_name_".count)) : requestedOutcome
        let matchingInputWithChangedName = outcome.hasPrefix("composed_name_matching_input")
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            guard case .issued(let project)? = capture.projectIssuance else {
                Issue.record("The captured input needs an issued project"); return
            }
            let fresh = try #require(capture.freshPopulation)
            #expect(fresh.stable && fresh.uiEffects.restoration == "restored")
            #expect(capture.channelStrips.count == 2)
            for strip in capture.channelStrips {
                #expect(strip.volumeReadback != nil && strip.panReadback != nil)
                #expect(strip.pluginsSource == "ax")
                let pluginsObserved = try #require(strip.pluginsFullyObserved as Bool?)
                #expect(pluginsObserved)
                let sends = try #require(strip.sendSlots)
                if outcome.contains("peer_send"), sends.contains(where: { $0.state == .occupiedUnknownDestination }) {
                    #expect(sends.filter { $0.state == .occupiedUnknownDestination }.count == 1)
                } else { #expect(sends.allSatisfy { $0.state == .observedEmpty }) }
            }
            let pair = try #require(fresh.selectionAssociations.first)
            let input = try #require(fresh.checkedInputs.first { $0.receiver.matches(pair.strip) })
            #expect(input.assignment == .bus(1))
            var policy: Value = .object(["schema": .string(ProjectSessionAudit.intentPolicySchema),
                "project_ref": .string(project.rawValue),
                "targets": .array([.object(["handle": .string("source"), "track_ref": .string(trackReference.rawValue)])]),
                "inputs": .array([.object(["target": .string("source"), "bus": .int(outcome.hasPrefix("matching") || matchingInputWithChangedName ? 1 : 2)])])])
            if outcome.hasPrefix("matching_output_"), var fields = policy.objectValue {
                fields["outputs"] = .array([.object(["target": .string("source"),
                    "output": .object(["kind": .string("physical"), "ports": .array([.int(3), .int(4)])])])])
                policy = .object(fields)
            }
            let planner = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "plan_session_repair"))
            var planning: [String: Value] = ["snapshot_id": .string(snapshotID), "policy": policy]
            if outcome.hasPrefix("composed_name_") {
                planning["names"] = .array([.object(["target": .string("source"), "name": .string("Approved Input Source")])])
            }
            if retainedName {
                let row = try #require(capture.tracks.first { $0.physicalBinding?.matches(pair.track) == true })
                planning["names"] = .array([.object(["target": .string("source"), "name": .string(row.name)])])
            }
            let planned = await planner(dependencies, planning)
            let preview = try #require(sharedJSONObject(sharedToolText(planned)))
            let executable = try #require(preview["executable"] as? Bool)
            if outcome.contains("peer_send"), outcome.hasSuffix("_unread") || outcome.hasSuffix("_changed_input")
                || outcome.hasSuffix("_source") || outcome.hasPrefix("composed_name_") || outcome.hasPrefix("matching_output_") {
                #expect(!executable, "Occupied Send preservation cannot extend any writer or an unread baseline")
                #expect(f.inputSetterDispatches == 0 && f.routingDestinationPresses == 0 && f.routingNameWrites.isEmpty)
                return
            }
            #expect(executable, "The qualified singleton input must have an executable plan: \(preview)")
            #expect(f.routingDestinationPresses == 0)
            guard executable else { return }
            if outcome.hasPrefix("matching_output_") {
                let steps = try #require(preview["steps"] as? [[String: Any]])
                #expect(steps.compactMap { $0["kind"] as? String } == ["local_output"])
                #expect(steps.first?["target_ref"] as? String == trackReference.rawValue)
                #expect((steps.first?["after"] as? [String: Any])?["ports"] as? [Int] == [3, 4])
                #expect(preview["unchanged_tasks"] as? [String] == ["input_source"])
                #expect(f.routingDestinationPresses == 0)
                if outcome == "matching_output_preview" { return }
                var params: [String: Value] = ["plan_id": .string(try #require(preview["plan_id"] as? String)),
                    "digest": .string(try #require(preview["digest"] as? String)),
                    "confirmed": .bool(true), "idempotency_key": .string(key)]
                let source = try #require(capture.freshPopulation?.selectionAssociations.first?.strip.strip)
                if outcome == "matching_output_wrong_digest" { params["digest"] = .string(String(repeating: "0", count: 64)) }
                if outcome == "matching_output_before_control" {
                    let control = f.builder.element(1_291_200), replacement = f.builder.element(1_291_219)
                    f.builder.setButton(replacement, description: "Bus 1", help: "Input slot.", x: 0, y: 0, width: 60, height: 20)
                    f.builder.setChildren(replacement, []); f.builder.setActionNames(replacement, [kAXPressAction as String])
                    f.builder.setChildren(source, f.builder.makeAXRuntime().children(source).map { CFEqual($0, control) ? replacement : $0 })
                }
                if outcome == "matching_output_before_peer" {
                    f.builder.setAttribute(f.routingScalarControls[0], kAXValueAttribute as String, NSNumber(value: 0.4))
                }
                if outcome == "matching_output_before_project" {
                    f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                }
                let apply = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "apply_session_repair"))
                let applied = await apply(dependencies, params)
                let result = try #require(sharedJSONObject(sharedToolText(applied)))
                if !["matching_output_completed", "matching_output_source_renewal", "matching_output_peer_renewal", "matching_output_preflight_renewal"].contains(outcome) {
                    let state = try #require(result["state"] as? String)
                    #expect(state == "B" || state == "C", "No failed retained goal may produce A: \(result)")
                    #expect(f.inputSetterDispatches == 0)
                    if outcome.contains("_before_") || outcome.hasSuffix("_wrong_digest") || outcome.hasSuffix("_ack_only") {
                        #expect(f.routingDestinationPresses == 0)
                    } else if outcome.hasSuffix("_cancel") {
                        #expect(f.routingDestinationPresses == 2)
                        #expect(f.builder.attributeValue(f.builder.element(1_291_201), kAXDescriptionAttribute as String) as? String == "Stereo Output")
                    } else {
                        #expect(f.routingLateScopeInjected && f.routingDestinationPresses > 0)
                        if outcome.hasSuffix("_final_input") {
                            #expect(f.builder.attributeValue(f.builder.element(1_291_207), "AXMenuItemMarkChar") as? String == "✓")
                        }
                    }
                    return
                }
                #expect(result["state"] as? String == "A", "Actual composed output result: \(result)")
                #expect(result["saga_state"] as? String == "completed")
                #expect(f.inputSetterDispatches == 0 && f.routingDestinationPresses == 1)
                if outcome.hasSuffix("_source_renewal") { #expect(f.routingReplacement != nil) }
                if outcome.hasSuffix("_peer_renewal") { #expect(f.inputReadReplacementPeer != nil) }
                if outcome.hasSuffix("_preflight_renewal") { #expect(f.routingReplacement != nil) }
                let evidence = try #require(result["goal_evidence"] as? [[String: Any]])
                let inputRead = try #require(evidence.first { ($0["read"] as? [String: Any])?["read_source"] as? String == "ax_input_menu_checkmark" })
                #expect(inputRead["target_ref"] as? String == trackReference.rawValue)
                #expect((inputRead["read"] as? [String: Any])?["observed"] as? String == "bus:1")
                let outputRead = try #require(evidence.first { ($0["read"] as? [String: Any])?["read_source"] as? String == "ax_output_menu_checkmark" })
                #expect(outputRead["target_ref"] as? String == trackReference.rawValue)
                #expect((outputRead["read"] as? [String: Any])?["observed"] as? String == "physical:3-4")
                let replay = await apply(dependencies, params)
                let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
                let duplicate = try #require(replayBody["duplicate"] as? Bool)
                #expect(duplicate)
                #expect(f.inputSetterDispatches == 0 && f.routingDestinationPresses == 1)
                return
            }
            if retainedName && !outcome.hasPrefix("matching") {
                let steps = try #require(preview["steps"] as? [[String: Any]])
                #expect(steps.compactMap { $0["kind"] as? String } == ["input_assignment"])
                #expect(steps.first?["dependencies"] as? [String] == [])
                #expect(preview["unchanged_tasks"] as? [String] == ["name_source"])
            }
            if outcome.hasPrefix("composed_name_") {
                let steps = try #require(preview["steps"] as? [[String: Any]])
                #expect(steps.compactMap { $0["kind"] as? String } == (matchingInputWithChangedName ? ["name"] : ["name", "input_assignment"]))
                if !matchingInputWithChangedName {
                    #expect(steps.last?["dependencies"] as? [String] == ["name_source"])
                }
                let id = try #require(preview["plan_id"] as? String)
                let digest = try #require(preview["digest"] as? String)
                let approval = try #require(await ApprovedSessionRepair.retained(
                    id: id, digest: digest, key: key,
                    cache: dependencies.cache, registry: dependencies.targetRegistry, journal: dependencies.sagaJournal))
                #expect(approval.plan.steps.map(\.operationID) == (matchingInputWithChangedName ? [.tracksRename] : [.tracksRename, .mixerSetInputBusVerified]))
                #expect(f.routingNameWrites.isEmpty && f.inputSetterDispatches == 0 && f.routingDestinationPresses == 0)
                if matchingInputWithChangedName {
                    #expect(preview["unchanged_tasks"] as? [String] == ["input_source"])
                    #expect(InputBusSagaAdapter(approved: approval) == nil)
                    #expect(InputBusSagaAdapter(matchingInput: approval) != nil)
                    let apply = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "apply_session_repair"))
                    var params: [String: Value] = ["plan_id": .string(id), "digest": .string(digest),
                        "confirmed": .bool(true), "idempotency_key": .string(key)]
                    let fault = String(outcome.dropFirst("composed_name_matching_input_".count)), b = f.builder
                    let prewriteRefusal = ["wrong_digest", "foreign_project", "changed_peer", "changed_input", "replaced_control", "foreign_focus"].contains(fault)
                    if fault == "wrong_digest" { params["digest"] = .string(String(repeating: "0", count: 64)) }
                    if fault == "foreign_project" { b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx") }
                    if fault == "changed_peer" { b.setAttribute(b.element(1_291_401), kAXValueAttribute as String, NSNumber(value: 0.4)) }
                    if fault == "foreign_focus" { injectForeignInputEditor(f) }
                    if fault == "changed_input" {
                        b.setAttribute(b.element(1_291_206), "AXMenuItemMarkChar", "")
                        b.setAttribute(b.element(1_291_207), "AXMenuItemMarkChar", "✓")
                    }
                    if fault == "replaced_control" {
                        let replacement = b.element(1_291_499)
                        b.setButton(replacement, description: "Bus 1", help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 60, height: 20)
                        b.setChildren(replacement, []); b.setActionNames(replacement, [kAXPressAction as String])
                        b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]).map { CFEqual($0, b.element(1_291_200)) ? replacement : $0 })
                    }
                    if fault == "after_name_input" || fault == "external_name" {
                        let previous = f.routingAction
                        f.routingAction = { element, action in
                            let result = previous?(element, action) ?? false
                            guard action == kAXConfirmAction as String, CFEqual(element, b.element(1_971_400)),
                                  f.routingNameConfirms == 1, !f.routingLateScopeInjected else { return result }
                            if fault == "after_name_input" {
                                b.setAttribute(b.element(1_291_206), "AXMenuItemMarkChar", "")
                                b.setAttribute(b.element(1_291_207), "AXMenuItemMarkChar", "✓")
                            } else {
                                b.setAttribute(b.element(1_971_400), kAXDescriptionAttribute as String, "External Name")
                                b.setAttribute(f.headers[0], kAXTitleAttribute as String, "External Name")
                                b.setAttribute(b.element(1_965_711), kAXValueAttribute as String, "External Name")
                            }
                            f.routingLateScopeInjected = true
                            return result
                        }
                    }
                    if fault == "between_name_input" || fault == "cancel" {
                        let previous = f.routingRead
                        f.routingRead = { element, attribute in
                            previous?(element, attribute)
                            guard CFEqual(element, f.headers[0]), attribute == kAXTitleAttribute as String,
                                  let context = OperationTraceContext.current else { return }
                            if f.matchingGoalContextID == nil { f.matchingGoalContextID = ObjectIdentifier(context) }
                            guard ObjectIdentifier(context) == f.matchingGoalContextID,
                                  f.routingNameWrites.count == 1, f.routingNameConfirms == 1 else { return }
                            if f.matchingAfterNameReads == nil { f.matchingAfterNameReads = f.inputMenuPresses }
                            guard let baseline = f.matchingAfterNameReads, f.inputMenuPresses == baseline + 1,
                                  !f.routingLateScopeInjected else { return }
                            f.routingLateScopeInjected = true
                            if fault == "cancel" {
                                f.matchingNameCancelTask = Task {
                                    await SystemDispatcher.handle(command: "saga_cancel",
                                        params: ["idempotency_key": .string(key)], router: dependencies.router,
                                        cache: dependencies.cache, targetRegistry: dependencies.targetRegistry,
                                        sagaJournal: dependencies.sagaJournal, mutationGate: dependencies.mutationGate)
                                }
                            } else {
                                b.setAttribute(b.element(1_291_206), "AXMenuItemMarkChar", "")
                                b.setAttribute(b.element(1_291_207), "AXMenuItemMarkChar", "✓")
                            }
                        }
                    }
                    let result = await apply(dependencies, params)
                    let body = try #require(sharedJSONObject(sharedToolText(result)))
                    #expect(f.inputSetterDispatches == 0 && f.routingDestinationPresses == 0)
                    if prewriteRefusal {
                        #expect(body["state"] as? String == "C", "Unqualified original input must block all writes: \(body)")
                        #expect(f.routingNameWrites.isEmpty && f.routingNameConfirms == 0)
                        return
                    }
                    let postwriteFault = ["after_name_input", "external_name", "between_name_input"].contains(fault)
                    if postwriteFault || fault == "cancel" {
                        #expect(f.routingLateScopeInjected, "The actual named phase must reach the fault")
                        let verified = try #require(body["verified"] as? Bool)
                        let state = try #require(body["state"] as? String)
                        #expect(!verified && ["B", "C"].contains(state), "A partial goal must not become success: \(body)")
                        if fault == "external_name" {
                            #expect(b.attributeValue(f.headers[0], kAXTitleAttribute as String) as? String == "External Name")
                            #expect(f.routingNameWrites == ["Approved Input Source"])
                        } else if fault == "cancel" {
                            let task = try #require(f.matchingNameCancelTask)
                            let cancelBody = try #require(sharedJSONObject(sharedToolText(await task.value)))
                            f.matchingNameCancelTask = nil
                            #expect(cancelBody["status"] as? String == "cancellation_requested")
                            #expect(body["saga_state"] as? String == "fullyCompensated", "Owned name cancellation: \(body)")
                            #expect(f.routingNameWrites == ["Approved Input Source", "Duplicate"])
                            #expect(b.attributeValue(f.headers[0], kAXTitleAttribute as String) as? String == "Duplicate")
                        } else {
                            #expect(b.attributeValue(b.element(1_291_207), "AXMenuItemMarkChar") as? String == "✓")
                            #expect(f.routingNameWrites == ["Approved Input Source"] || f.routingNameWrites == ["Approved Input Source", "Duplicate"])
                        }
                    } else {
                        #expect(body["state"] as? String == "A", "Changed name with unchanged input: \(body)")
                        #expect(body["saga_state"] as? String == "completed")
                        #expect(f.routingNameWrites == ["Approved Input Source"])
                        let evidence = try #require(body["goal_evidence"] as? [[String: Any]])
                        #expect(evidence.count == 2, "Both independently sampled goals must be present")
                        let samples = evidence.compactMap { $0["read"] as? [String: Any] }
                        let nameRead = try #require(samples.first { $0["field"] as? String == "name" })
                        let inputRead = try #require(samples.first { $0["field"] as? String == "input_bus" })
                        #expect(nameRead["read_source"] as? String == "ax_track_name" && nameRead["observed"] as? String == "Approved Input Source")
                        #expect(inputRead["read_source"] as? String == "ax_input_menu_checkmark" && inputRead["observed"] as? String == "bus:1")
                        if fault == "preflight_renewal" { #expect(f.routingReplacement != nil) }
                    }
                    let reads = f.inputMenuPresses
                    let writes = f.routingNameWrites
                    let replay = await apply(dependencies, params)
                    let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
                    let duplicate = try #require(replayBody["duplicate"] as? Bool)
                    #expect(duplicate && f.inputMenuPresses == reads)
                    #expect(f.routingNameWrites == writes && f.inputSetterDispatches == 0 && f.routingDestinationPresses == 0)
                    return
                }
                if outcome.hasPrefix("composed_name_execution") {
                    let apply = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "apply_session_repair"))
                    var params: [String: Value] = ["plan_id": .string(id), "digest": .string(digest),
                        "confirmed": .bool(true), "idempotency_key": .string(key)]
                    let b = f.builder
                    let refusal = ["_wrong_digest", "_foreign_project", "_changed_peer", "_changed_input", "_replaced_control",
                                   "_preflight_renewal_peer", "_preflight_renewal_project", "_preflight_renewal_header"]
                        .contains { outcome.hasSuffix($0) }
                    if outcome.hasSuffix("_wrong_digest") { params["digest"] = .string(String(repeating: "0", count: 64)) }
                    if outcome.hasSuffix("_foreign_project") {
                        b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                    if outcome.hasSuffix("_changed_peer") {
                        b.setAttribute(b.element(1_291_401), kAXValueAttribute as String, NSNumber(value: 0.4))
                    }
                    if outcome.hasSuffix("_changed_input") {
                        b.setAttribute(b.element(1_291_206), "AXMenuItemMarkChar", "")
                        b.setAttribute(b.element(1_291_207), "AXMenuItemMarkChar", "✓")
                    }
                    if outcome.hasSuffix("_replaced_control") {
                        let replacement = b.element(1_291_499)
                        b.setButton(replacement, description: "Bus 1", help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 60, height: 20)
                        b.setChildren(replacement, []); b.setActionNames(replacement, [kAXPressAction as String])
                        b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]).map {
                            CFEqual($0, b.element(1_291_200)) ? replacement : $0
                        })
                    }
                    if outcome == "composed_name_execution_caption_post_read_project_cancel" {
                        let previous = f.routingRead
                        f.routingRead = { element, attribute in
                            previous?(element, attribute)
                            guard !f.routingLateScopeInjected, f.routingNameConfirms == 2, f.routingDestinationPresses == 2,
                                  CFEqual(element, b.element(1_291_200)), attribute == kAXDescriptionAttribute as String else { return }
                            let stack = Thread.callStackSymbols
                            guard stack.contains(where: { $0.contains("ApprovedSessionRepair") && $0.contains("readState") }),
                                  stack.contains(where: { $0.contains("inputSlotRead") }),
                                  !stack.contains(where: { $0.contains("readOwnedCoupledName") || $0.contains("readCapturedCoupledName") }) else { return }
                            f.routingLateScopeInjected = true
                            b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        }
                    }
                    let result = await apply(dependencies, params)
                    let body = try #require(sharedJSONObject(sharedToolText(result)))
                    if refusal {
                        #expect(body["state"] as? String == "C", "Whole composed-plan refusal: \(body)")
                        #expect(f.routingNameWrites.isEmpty && f.inputSetterDispatches == 0 && f.routingDestinationPresses == 0)
                        if outcome.contains("_preflight_renewal") {
                            #expect(f.routingReplacement != nil && f.routingLateScopeInjected,
                                "Reach the actual retired-source and changed protection boundary")
                        }
                        return
                    }
                    if outcome.hasSuffix("_external_name") {
                        #expect(body["state"] as? String == "B", "External edits must not be overwritten: \(body)")
                        #expect(f.routingLateScopeInjected && f.routingNameWrites == ["Approved Input Source"])
                        #expect(f.routingDestinationPresses == 1)
                        #expect(b.attributeValue(f.headers[0], kAXTitleAttribute as String) as? String == "External Name")
                        return
                    }
                    let compensated = outcome.hasSuffix("_cancel") || outcome.hasSuffix("_failure")
                    if compensated {
                        if ["composed_name_execution_caption_peer_changed_cancel", "composed_name_execution_caption_project_cancel",
                            "composed_name_execution_caption_control_cancel", "composed_name_execution_caption_late_control_cancel",
                            "composed_name_execution_caption_post_read_project_cancel"].contains(outcome) {
                            #expect(f.routingLateScopeInjected, "Reach the actual presentation cleanup fault")
                            #expect(body["state"] as? String == "B")
                            #expect(body["saga_state"] as? String == "rollbackUncertain")
                            #expect(f.routingNameWrites == ["Approved Input Source", "Duplicate"])
                            #expect(f.inputSetterDispatches == 1 && f.routingDestinationPresses == 2,
                                "Lost cleanup custody cannot dispatch another setter or inverse")
                            if outcome == "composed_name_execution_caption_peer_changed_cancel" {
                                let value = try #require(b.attributeValue(b.element(1_291_401), kAXValueAttribute as String) as? NSNumber)
                                #expect(value.doubleValue == 0.4, "The intervening peer edit remains intact")
                            }
                            return
                        }
                        #expect(body["state"] as? String == "C", "Composed compensation: \(body)")
                        #expect(body["saga_state"] as? String == "fullyCompensated")
                        #expect(f.routingNameWrites == ["Approved Input Source", "Duplicate"])
                        #expect(f.inputSetterDispatches == 1 && f.routingDestinationPresses == 2,
                            "The owned inverse uses its actual native capsule, not a second public dispatch")
                        #expect(b.attributeValue(b.element(1_291_206), "AXMenuItemMarkChar") as? String == "✓")
                        #expect(b.attributeValue(f.headers[0], kAXTitleAttribute as String) as? String == "Duplicate")
                        if outcome.hasPrefix("composed_name_execution_caption_") {
                            #expect(b.attributeValue(f.strips[1], kAXDescriptionAttribute as String) as? String == "Duplicate",
                                "Owned name/input compensation must refresh the original Mixer presentation, not leave its old name alias")
                            if outcome == "composed_name_execution_caption_header_refresh_cancel" {
                                #expect(f.routingHeaderPresentationRefreshed, "Reach the original-header presentation refresh")
                                #expect(b.makeAXRuntime().children(f.strips[1]).contains { CFEqual($0, b.element(1_291_200)) },
                                    "An unnecessary popup must not retire the already-verified original input control")
                            }
                            if outcome == "composed_name_execution_caption_peer_cancel" {
                                #expect(f.inputReadReplacementPeer != nil,
                                    "Reach the actual peer retirement during the presentation popup")
                            }
                        }
                    } else {
                        #expect(body["state"] as? String == "A", "Actual composed name/input: \(body)")
                        #expect(body["saga_state"] as? String == "completed")
                        #expect(f.routingNameWrites == ["Approved Input Source"])
                        #expect(f.inputSetterDispatches == 1 && f.routingDestinationPresses == 1)
                    }
                    if outcome.contains("_preflight_renewal") {
                        #expect(f.routingReplacement != nil, "Reach the actual preflight Cancel-retired source")
                    }
                    let replay = await apply(dependencies, params)
                    let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
                    let duplicate = try #require(replayBody["duplicate"] as? Bool)
                    #expect(duplicate)
                    let writes = compensated ? 2 : 1
                    #expect(f.routingNameWrites.count == writes && f.inputSetterDispatches == 1 && f.routingDestinationPresses == writes)
                }
                return
            }
            if outcome.hasPrefix("matching") {
                try await assertMatchingInputExecution(f, dependencies: dependencies, preview: preview, key: key,
                    outcome: outcome, retainedName: retainedName)
                return
            }
            let id = try #require(preview["plan_id"] as? String)
            let digest = try #require(preview["digest"] as? String)
            let apply = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "apply_session_repair"))
            var params: [String: Value] = ["plan_id": .string(id), "digest": .string(digest),
                "confirmed": .bool(true), "idempotency_key": .string(key)]
            let original = try #require(capture.channelStrips.first { $0.physicalBinding?.matches(pair.strip) == true }?.inputSlotBinding)
            if outcome == "wrong_digest" { params["digest"] = .string(String(repeating: "0", count: 64)) }
            if outcome == "foreign_project" { f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx") }
            if outcome == "foreign_focus" { injectForeignInputEditor(f) }
            if outcome == "changed_peer" {
                f.builder.setAttribute(f.builder.element(1_291_401), kAXValueAttribute as String, NSNumber(value: 0.4))
            }
            if outcome == "changed_name" {
                f.builder.setAttribute(f.headers[0], kAXTitleAttribute as String, "External Name")
            }
            if outcome == "replaced_control" {
                let replacement = f.builder.element(1_291_499)
                f.builder.setButton(replacement, description: "Bus 1", help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 60, height: 20)
                f.builder.setChildren(replacement, []); f.builder.setActionNames(replacement, [kAXPressAction as String])
                f.builder.setChildren(pair.strip.strip, f.builder.makeAXRuntime().children(pair.strip.strip).map {
                    CFEqual($0, original.control) ? replacement : $0
                })
            }
            if outcome == "late_proof_document" {
                let readsBeforeApply = f.inputMenuPresses
                f.routingWindowListRead = {
                    // Reach fresh proof construction only after the independent
                    // checked input has left its original binding scope. Earlier
                    // original-pair checks have already succeeded at this point.
                    guard f.inputMenuPresses > readsBeforeApply,
                          AXMixerStripBinding.current == nil, !f.routingLateScopeInjected else { return }
                    f.routingLateScopeInjected = true
                    f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                }
                let previous = f.routingRead
                f.routingRead = { element, attribute in
                    previous?(element, attribute)
                    if f.routingLateScopeInjected, attribute == kAXHelpAttribute as String,
                       f.builder.attributeValue(f.window, kAXDocumentAttribute as String) as? String == "file:///tmp/Foreign.logicx" {
                        f.inputForeignScopeHelpReads += 1
                    }
                }
            }
            let result = await apply(dependencies, params)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let prewriteRefusal = ["wrong_digest", "replaced_control", "foreign_project", "changed_peer", "changed_name", "foreign_focus", "dispatch_control", "dispatch_peer", "dispatch_focus", "dispatch_name", "late_proof_document"].contains(outcome)
            if prewriteRefusal {
                #expect(body["state"] as? String == "C", "Actual input refusal: \(body)")
                #expect(f.routingDestinationPresses == 0)
                if outcome.hasPrefix("dispatch_") { #expect(f.routingLateScopeInjected) }
                if outcome == "late_proof_document" {
                    #expect(f.routingLateScopeInjected, "Reach the late document transition during fresh proof construction")
                    #expect(f.inputForeignScopeHelpReads == 0, "Refuse before any raw Help read under the foreign scope")
                }
            } else if ["cancel", "failure", "owned_renewal_cancel", "owned_renewal_failure"].contains(outcome) {
                #expect(body["saga_state"] as? String == "fullyCompensated", "Actual canonical compensation: \(body)")
                #expect(body["state"] as? String != "A", "A restored input does not satisfy the requested Bus 2 goal")
                #expect(f.routingDestinationPresses == 2)
                #expect(f.builder.attributeValue(original.control, kAXDescriptionAttribute as String) as? String == "Bus 1")
            } else if ["completed", "different_display", "owned_renewal"].contains(outcome) {
                #expect(body["state"] as? String == "A", "Actual canonical input result: \(body)")
                #expect(body["saga_state"] as? String == "completed")
                #expect(f.routingDestinationPresses == 1)
                #expect(f.inputSetterDispatches == 1, "The same fixture observes actual changed-input dispatch")
                if retainedName {
                    let evidence = try #require(body["goal_evidence"] as? [[String: Any]])
                    #expect(evidence.count == 1)
                    let read = try #require(evidence.first?["read"] as? [String: Any])
                    #expect(read["observed"] as? String == "Duplicate")
                    #expect(read["read_source"] as? String == "ax_track_name")
                }
            } else {
                #expect(body["state"] as? String == "B", "Actual unverified input result: \(body)")
                #expect(f.routingDestinationPresses == (outcome == "no_observer" ? 0 : 1))
                if outcome.hasPrefix("late_inverse_") { #expect(f.routingLateScopeInjected) }
            }
            if retainedName {
                #expect(f.routingNameWrites.isEmpty && f.routingNameConfirms == 0,
                    "An unchanged approved name must never acquire a name writer")
                let expectedName = ["changed_name", "dispatch_name", "late_inverse_name"].contains(outcome) ? "External Name" : "Duplicate"
                #expect(f.builder.attributeValue(f.headers[0], kAXTitleAttribute as String) as? String == expectedName)
            }
            let presses = f.routingDestinationPresses
            let reads = f.inputMenuPresses
            if outcome.hasPrefix("owned_renewal") {
                let renewed = try #require(f.routingReplacement)
                #expect(!CFEqual(renewed, pair.strip.strip))
                let current = f.builder.makeAXRuntime().children(f.mixer)
                #expect(current.contains { CFEqual($0, renewed) })
                #expect(!current.contains { CFEqual($0, pair.strip.strip) })
            }
            let replay = await apply(dependencies, params)
            let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
            if outcome == "cancel" || outcome == "owned_renewal_cancel" { #expect(replayBody["state"] as? String == "C") }
            else if !prewriteRefusal {
                let duplicate = try #require(replayBody["duplicate"] as? Bool)
                #expect(duplicate)
            }
            #expect(f.routingDestinationPresses == presses)
            if !prewriteRefusal { #expect(f.inputMenuPresses == reads, "Replay must not reopen a native input") }
        }
    }

    private func assertMatchingInputExecution(_ f: Fixture, dependencies: HandlerDependencies,
                                               preview: [String: Any], key: String, outcome: String,
                                               retainedName: Bool = false) async throws {
        let steps = try #require(preview["steps"] as? [[String: Any]])
        #expect(steps.isEmpty, "An already-matching input is not a mutating task")
        let unchanged = try #require(preview["unchanged_tasks"] as? [String])
        let expectedIDs = retainedName ? ["input_source", "name_source"] : ["input_source"]
        #expect(unchanged.count == expectedIDs.count && Set(unchanged) == Set(expectedIDs))
        let id = try #require(preview["plan_id"] as? String), digest = try #require(preview["digest"] as? String)
        let apply = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "apply_session_repair"))
        let params: [String: Value] = ["plan_id": .string(id), "digest": .string(digest),
            "confirmed": .bool(true), "idempotency_key": .string(key)]
        let approval = try #require(await ApprovedSessionRepair.retained(id: id, digest: digest, key: key,
            cache: dependencies.cache, registry: dependencies.targetRegistry, journal: dependencies.sagaJournal))
        #expect(InputBusSagaAdapter(approved: approval) == nil, "Matching approval is not an input writer")
        let readOnly = try #require(InputBusSagaAdapter(matchingInput: approval))
        let gate = try #require(dependencies.mutationGate)
        let claim = try #require(gate.tryAcquire(operation: "matching-input-readonly-control"))
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let denied = await OperationTraceContext.$current.withValue(context) {
            #expect(gate.stillOwns(claim), "The read-only refusal is not caused by a missing gate")
            if retainedName && outcome == "matching" {
                let b = f.builder
                b.setAttribute(b.element(1_291_206), "AXMenuItemMarkChar", "")
                b.setAttribute(b.element(1_291_207), "AXMenuItemMarkChar", "✓")
                #expect(!approval.verifiesMatchingNamesOnly,
                    "An approved input goal cannot be completed by a names-only verifier")
                let namesOnly = await approval.verifyMatchingNames()
                let body = sharedJSONObject(namesOnly.body)
                #expect(body?["state"] as? String == "C",
                    "Checking names alone must not certify the unchecked changed input: \(namesOnly.body)")
                b.setAttribute(b.element(1_291_206), "AXMenuItemMarkChar", "✓")
                b.setAttribute(b.element(1_291_207), "AXMenuItemMarkChar", "")
            }
            return await readOnly.run(readOnly.forward, router: dependencies.router,
                cache: dependencies.cache, registry: dependencies.targetRegistry)
        }
        gate.release(claim)
        #expect(denied.state == .stateC && !denied.writeBoundaryCrossed)
        #expect(f.inputSetterDispatches == 0)
        let b = f.builder, input = b.element(1_291_200)
        switch outcome {
        case "matching_name_before":
            b.setAttribute(f.headers[0], kAXTitleAttribute as String, "External Name")
        case "matching_between_name_input":
            let reads = f.inputMenuPresses, previousRead = f.routingRead
            f.routingRead = { element, attribute in
                previousRead?(element, attribute)
                guard CFEqual(element, f.headers[0]), attribute == kAXTitleAttribute as String,
                      let context = OperationTraceContext.current else { return }
                if f.inputMenuPresses == reads, f.matchingGoalContextID == nil {
                    f.matchingGoalContextID = ObjectIdentifier(context)
                }
                guard f.inputMenuPresses == reads + 1, !f.routingLateScopeInjected,
                      ObjectIdentifier(context) == f.matchingGoalContextID else { return }
                // Mutate during the independent name sample, outside the first
                // input reader. This happens even if the final read is omitted.
                b.setAttribute(b.element(1_291_206), "AXMenuItemMarkChar", "")
                b.setAttribute(b.element(1_291_207), "AXMenuItemMarkChar", "✓")
                f.routingLateScopeInjected = true
            }
        case "matching_final_name", "matching_final_checkmark":
            let reads = f.inputMenuPresses, previous = f.routingAction
            f.routingAction = { element, action in
                let result = previous?(element, action) ?? false
                guard f.inputMenuPresses >= reads + 2, !f.routingLateScopeInjected else { return result }
                if outcome == "matching_final_name", action == kAXCancelAction as String,
                   CFEqual(element, b.element(1_291_202)) {
                    b.setAttribute(f.headers[0], kAXTitleAttribute as String, "External Name")
                    f.routingLateScopeInjected = true
                }
                if outcome == "matching_final_checkmark", action == kAXPressAction as String, CFEqual(element, input) {
                    b.setAttribute(b.element(1_291_206), "AXMenuItemMarkChar", "")
                    b.setAttribute(b.element(1_291_207), "AXMenuItemMarkChar", "✓")
                    f.routingLateScopeInjected = true
                }
                return result
            }
        case "matching_checkmark":
            b.setAttribute(b.element(1_291_203), kAXTitleAttribute as String, "Bus 2")
            b.setAttribute(b.element(1_291_206), "AXMenuItemMarkChar", "")
            b.setAttribute(b.element(1_291_207), "AXMenuItemMarkChar", "✓")
        case "matching_control":
            let replacement = b.element(1_291_499)
            b.setButton(replacement, description: "Bus 1", help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 60, height: 20)
            b.setChildren(replacement, []); b.setActionNames(replacement, [kAXPressAction as String])
            b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]).map { CFEqual($0, input) ? replacement : $0 })
        case "matching_project": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
        case "matching_focus": injectForeignInputEditor(f)
        case "matching_peer": b.setAttribute(b.element(1_291_401), kAXValueAttribute as String, NSNumber(value: 0.4))
        case "matching_peer_send_changed":
            b.setAttribute(b.element(1_291_454), kAXValueAttribute as String, NSNumber(value: 0.5))
        case "matching_cleanup":
            let previous = f.routingAction
            f.routingAction = { element, action in
                let result = previous?(element, action) ?? false
                if action == kAXCancelAction as String, CFEqual(element, b.element(1_291_202)) {
                    f.routingLateScopeInjected = true
                    injectForeignInputEditor(f)
                }
                return result
            }
        case "matching_late_proof_document":
            let reads = f.inputMenuPresses
            f.routingWindowListRead = {
                guard f.inputMenuPresses > reads, AXMixerStripBinding.current == nil, !f.routingLateScopeInjected else { return }
                f.routingLateScopeInjected = true
                b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
            }
            let previous = f.routingRead
            f.routingRead = { element, attribute in
                previous?(element, attribute)
                if f.routingLateScopeInjected, attribute == kAXHelpAttribute as String { f.inputForeignScopeHelpReads += 1 }
            }
        case "matching_preopen_focus":
            let reads = f.inputMenuPresses
            f.routingWindowListRead = {
                guard AXMixerStripBinding.current != nil, f.inputMenuPresses == reads, !f.routingLateScopeInjected else { return }
                f.routingLateScopeInjected = true
                b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.strips[0])
            }
        default: break
        }
        let beforeReads = f.inputMenuPresses
        let result = await apply(dependencies, params)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(f.routingNameWrites.isEmpty && f.routingNameConfirms == 0)
        if !["matching", "matching_different_display", "matching_renewal", "matching_peer_send"].contains(outcome) {
            #expect(body["state"] as? String == "C", "Actual matching refusal: \(body)")
            #expect(f.inputSetterDispatches == 0 && f.routingDestinationPresses == 0)
            if outcome == "matching_checkmark" { #expect(f.inputMenuPresses > beforeReads) }
            if outcome == "matching_peer_send_changed" {
                let level = try #require(b.attributeValue(b.element(1_291_454), kAXValueAttribute as String) as? NSNumber)
                #expect(level.doubleValue == 0.5)
            }
            if ["matching_cleanup", "matching_late_proof_document", "matching_preopen_focus"].contains(outcome) { #expect(f.routingLateScopeInjected) }
            if outcome == "matching_late_proof_document" { #expect(f.inputForeignScopeHelpReads == 0) }
            if ["matching_final_name", "matching_final_checkmark"].contains(outcome) {
                #expect(f.routingLateScopeInjected, "Reach the deciding second read, not only the earlier matching sample")
            }
            if outcome == "matching_between_name_input" {
                #expect(f.routingLateScopeInjected, "The input changed during the independently reached name sample")
                #expect(b.attributeValue(b.element(1_291_207), "AXMenuItemMarkChar") as? String == "✓")
                let receipt = try #require(body["input_read_receipt"] as? [String: Any])
                #expect(receipt["state"] as? String == "C")
            }
            if ["matching_name_before", "matching_final_name"].contains(outcome) {
                #expect(b.attributeValue(f.headers[0], kAXTitleAttribute as String) as? String == "External Name")
            }
            if outcome == "matching_name_before" { #expect(f.inputMenuPresses == beforeReads) }
            if outcome == "matching_renewal_rail" {
                #expect(f.routingReplacement != nil, "Reach the real Cancel-retired source before the reader refuses changed focus")
                let receipt = try #require(body["input_read_receipt"] as? [String: Any])
                #expect(receipt["state"] as? String == "C")
            }
            return
        }
        #expect(body["state"] as? String == "A", "Actual matching input result: \(body)")
        let verified = try #require(body["verified"] as? Bool)
        #expect(verified)
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(body["writes_performed"] as? Int == 0)
        #expect(f.inputMenuPresses > beforeReads, "Completion must independently reread the native input")
        #expect(f.inputSetterDispatches == 0)
        #expect(f.routingDestinationPresses == 0)
        #expect(f.routingNameWrites.isEmpty && f.routingNameConfirms == 0)
        if outcome == "matching_renewal" {
            #expect(f.routingReplacement != nil, "Reach the actual Cancel-retired source and original-header renewal")
        }
        let goals = try #require(body["goal_evidence"] as? [[String: Any]])
        let read = try #require(goals.compactMap { $0["read"] as? [String: Any] }
            .first { $0["read_source"] as? String == "ax_input_menu_checkmark" })
        #expect(read["read_source"] as? String == "ax_input_menu_checkmark")
        #expect(read["observed"] as? String == "bus:1")
        if retainedName {
            #expect(goals.count == 2)
            let name = try #require(goals.compactMap { $0["read"] as? [String: Any] }
                .first { $0["read_source"] as? String == "ax_track_name" })
            #expect(name["observed"] as? String == "Duplicate")
        }
        let reads = f.inputMenuPresses
        let replay = await apply(dependencies, params)
        let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
        let duplicate = try #require(replayBody["duplicate"] as? Bool)
        #expect(duplicate)
        #expect(f.inputMenuPresses == reads, "Replay must not reacquire a native popup")
        #expect(f.inputSetterDispatches == 0 && f.routingDestinationPresses == 0)
    }

    private func assertRegisteredInputSaga(_ requestedOutcome: String, canonical: Bool = false) async throws {
        let retainedName = requestedOutcome.hasPrefix("retained_name_")
        let outcome = retainedName ? String(requestedOutcome.dropFirst("retained_name_".count)) : requestedOutcome
        let composedNameExecution = outcome.hasPrefix("composed_name_execution") || outcome.hasPrefix("composed_name_matching_input")
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture(), b = f.builder, cache = StateCache(), registry = TargetRegistry()
            f.useBulkReads = outcome.contains("_final_")
            let retiring = outcome.hasPrefix("retired_track_")
            let canonicalRenewal = canonical && outcome.hasPrefix("owned_renewal")
            let matchingRenewal = canonical && (outcome.hasPrefix("matching_renewal") || outcome == "matching_output_preflight_renewal")
            let captureKeep = canonical && outcome.hasPrefix("keep_capture_")
            let composedRenewal = canonical && composedNameExecution && outcome.contains("_preflight_renewal")
            if retiring || canonicalRenewal || matchingRenewal || composedRenewal || captureKeep
                || outcome == "matching_output_source_renewal" || outcome == "matching_output_peer_renewal"
                || outcome.hasPrefix("composed_name_execution_caption_") {
                f.routingSelection = { index in
                    b.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String,
                        [index == 0 ? f.routingReplacement ?? f.strips[1] : f.inputReadReplacementPeer ?? f.strips[0]])
                    if outcome == "composed_name_execution_caption_header_refresh_cancel", index == 0,
                       f.routingNameConfirms == 2, f.routingDestinationPresses == 2,
                       AXMixerStripBinding.current == nil,
                       Thread.callStackSymbols.contains(where: { $0.contains("renewSourceThroughOriginalHeader") }) {
                        // A header excursion can refresh the stale presentation
                        // without opening another input popup or replacing its control.
                        b.setAttribute(f.strips[1], kAXDescriptionAttribute as String, "Duplicate")
                        f.routingHeaderPresentationRefreshed = true
                    }
                    if outcome == "composed_name_execution_caption_late_control_cancel", index == 1,
                       f.routingNameConfirms == 2, AXMixerStripBinding.current == nil, !f.routingLateScopeInjected,
                       b.attributeValue(f.strips[1], kAXDescriptionAttribute as String) as? String == "Duplicate" {
                        // The checked read and its Cancel already finished. Replace
                        // only the input control during the new all-header observer.
                        let replacement = b.element(1_291_215), original = b.element(1_291_200)
                        b.setButton(replacement, description: "Bus 1", help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 60, height: 20)
                        b.setChildren(replacement, []); b.setActionNames(replacement, [kAXPressAction as String])
                        b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]).map { CFEqual($0, original) ? replacement : $0 })
                        f.routingLateScopeInjected = true
                    }
                }
            }
            let input = b.element(1_291_200), output = b.element(1_291_201)
            let root = b.element(1_291_202), echo = b.element(1_291_203), parent = b.element(1_291_204)
            let submenu = b.element(1_291_205), one = b.element(1_291_206), two = b.element(1_291_207)
            let outputRoot = b.element(1_291_208), outputParent = b.element(1_291_209)
            let outputMenu = b.element(1_291_210), outputEcho = b.element(1_291_211), outputLeaf = b.element(1_291_212)
            let replacementInput = b.element(1_291_215)
            let replacementPeer = b.element(1_291_216)
            let trailingInputMarker = b.element(1_291_217)
            let physicalOutput = b.element(1_291_218)
            let matchingOutput = canonical && outcome.hasPrefix("matching_output_")
            b.setRole(f.mixer, kAXLayoutAreaRole as String); b.setAttribute(f.mixer, kAXDescriptionAttribute as String, "Mixer")
            let mixerOwner = b.element(1_291_213)
            b.setRole(mixerOwner, kAXGroupRole as String); b.setAttribute(mixerOwner, kAXDescriptionAttribute as String, "Mixer")
            b.setChildren(mixerOwner, [f.mixer]); b.setChildren(f.window, [f.rail, mixerOwner, b.element(1_965_720)])
            b.setButton(input, description: canonical && outcome.hasSuffix("different_display") ? "Bus 256" : "Bus 1",
                help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 60, height: 20)
            b.setButton(output, description: "Stereo Output", help: "Output slot. Choose the channel strip output destination.", x: 0, y: 30, width: 60, height: 20)
            for control in [input, output] { b.setChildren(control, []); b.setActionNames(control, [kAXPressAction as String]) }
            b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]) + [input, output])
            if captureKeep, outcome != "keep_capture_no_type" {
                let label = b.element(1_967_901)
                b.setRole(label, kAXStaticTextRole as String)
                b.setAttribute(label, kAXDescriptionAttribute as String, "label")
                b.setAttribute(label, kAXValueAttribute as String, "Aux 7")
                b.setChildren(label, [])
                b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]) + [label])
            }
            if canonical {
                for index in f.strips.indices {
                    let volume = b.element(1_291_400 + index * 2), pan = b.element(1_291_401 + index * 2)
                    for (control, description, value, minimum, maximum) in [
                        (volume, "Volume", 100.0, 0.0, 233.0), (pan, "Pan", 0.2, -1.0, 1.0)
                    ] {
                        b.setRole(control, kAXSliderRole as String)
                        b.setAttribute(control, kAXDescriptionAttribute as String, description)
                        b.setAttribute(control, kAXValueAttribute as String, NSNumber(value: value))
                        b.setAttribute(control, kAXMinValueAttribute as String, NSNumber(value: minimum))
                        b.setAttribute(control, kAXMaxValueAttribute as String, NSNumber(value: maximum))
                        b.setChildren(control, [])
                        f.routingScalarControls.append(control)
                    }
                    b.setChildren(f.strips[index], b.makeAXRuntime().children(f.strips[index]) + [volume, pan])
                }
            }
            if outcome.hasPrefix("inverse_boundary_final_document_") {
                b.setRole(trailingInputMarker, kAXStaticTextRole as String); b.setChildren(trailingInputMarker, [])
                b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]) + [trailingInputMarker])
            }
            for menu in [root, submenu, outputRoot, outputMenu] { b.setRole(menu, kAXMenuRole as String) }
            for menu in [root, outputRoot] { b.setActionNames(menu, [kAXCancelAction as String]) }
            for (node, title) in [(echo, "Bus 1"), (parent, "Bus"), (one, "Bus 1"), (two, "Bus 2"),
                                  (outputParent, "Output"), (outputEcho, "Stereo Output"), (outputLeaf, "Stereo Output")] {
                b.setRole(node, kAXMenuItemRole as String); b.setAttribute(node, kAXTitleAttribute as String, title)
                b.setAttribute(node, kAXEnabledAttribute as String, true); b.setChildren(node, [])
            }
            for leaf in [one, two] { b.setActionNames(leaf, [kAXPressAction as String]) }
            for node in [echo, one, outputEcho, outputLeaf] { b.setAttribute(node, "AXMenuItemMarkChar", "✓") }
            b.setAttribute(two, "AXMenuItemMarkChar", "")
            b.setChildren(submenu, [one, two]); b.setChildren(parent, [submenu]); b.setChildren(root, [echo, parent])
            b.setChildren(outputMenu, [outputLeaf]); b.setChildren(outputParent, [outputMenu]); b.setChildren(outputRoot, [outputEcho, outputParent])
            if matchingOutput {
                b.setRole(physicalOutput, kAXMenuItemRole as String)
                b.setAttribute(physicalOutput, kAXTitleAttribute as String, "Output 3-4")
                b.setAttribute(physicalOutput, kAXEnabledAttribute as String, true)
                b.setAttribute(physicalOutput, "AXMenuItemMarkChar", "")
                b.setChildren(physicalOutput, [])
                for leaf in [physicalOutput, outputLeaf] { b.setActionNames(leaf, [kAXPressAction as String]) }
                b.setChildren(outputMenu, [outputLeaf, physicalOutput])
            }
            let nameField = b.element(1_971_400)
            if outcome.hasPrefix("composed_name_execution_caption_") {
                b.setAttribute(f.strips[1], kAXDescriptionAttribute as String, "Duplicate")
            }
            if composedNameExecution {
                // The real name writer receives only this fixture's native AX editor.
                // Any fallback remains inside the fake channel, never the desktop.
                f.routingMenuRename = true
                b.setRole(nameField, kAXTextFieldRole as String)
                b.setAttribute(nameField, kAXDescriptionAttribute as String, "Duplicate")
                b.setAttribute(nameField, kAXValueAttribute as String, "0")
                b.setAttribute(nameField, kAXWindowAttribute as String, f.window)
                b.setActionNames(nameField, [kAXPressAction as String, kAXConfirmAction as String])
                b.setChildren(nameField, []); b.setChildren(f.headers[0], [nameField])
                f.routingSetter = { element, attribute, value in
                    guard CFEqual(element, nameField), attribute == kAXValueAttribute as String,
                          let name = value as? String else { return nil }
                    f.routingNameWrites.append(name)
                    b.setAttribute(nameField, kAXDescriptionAttribute as String, name)
                    b.setAttribute(f.headers[0], kAXTitleAttribute as String, name)
                    return true
                }
            }
            f.routingAction = { element, action in
                let source = f.routingReplacement ?? f.strips[1]
                let peer = outcome.hasPrefix("inverse_boundary_") && outcome.hasSuffix("_peer") && f.routingLateScopeInjected ? replacementPeer : f.inputReadReplacementPeer ?? f.strips[0]
                let census = [peer, source]
                if composedNameExecution, CFEqual(element, nameField) {
                    if action == kAXPressAction as String {
                        b.setAttributeSettable(nameField, kAXValueAttribute as String, true)
                        b.setAttribute(nameField, kAXValueAttribute as String,
                            b.attributeValue(nameField, kAXDescriptionAttribute as String))
                        b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, nameField); return true
                    }
                    if action == kAXConfirmAction as String {
                        f.routingNameConfirms += 1
                        if outcome.hasPrefix("composed_name_execution_caption_"), f.routingNameConfirms == 1 {
                            // The host keeps this alias after the inverse name commit;
                            // only a later native input-menu lifecycle refreshes it.
                            b.setAttribute(source, kAXDescriptionAttribute as String, "Approved Input Source")
                        }
                        b.setAttribute(b.element(1_965_711), kAXValueAttribute as String,
                            b.attributeValue(nameField, kAXDescriptionAttribute as String))
                        b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, source); return true
                    }
                }
                if action == kAXPressAction as String, CFEqual(element, input) || CFEqual(element, replacementInput) || CFEqual(element, output) {
                    let inputPressed = !CFEqual(element, output)
                    if inputPressed { f.inputMenuPresses += 1 }
                    if outcome.hasPrefix("composed_name_execution_caption_"), inputPressed, f.routingNameConfirms == 2 {
                        b.setAttribute(source, kAXDescriptionAttribute as String, "Duplicate")
                    }
                    if matchingOutput, inputPressed, f.routingDestinationPresses == 1 { f.inputReadAfterOutput = true }
                    if outcome == "checked_inverse_input", inputPressed, f.inputSagaForwardVerified,
                       AccessibilityChannel.inputChangeObserver != nil, f.routingDestinationPresses == 1 {
                        // The display/control still say Bus 2. Only the freshly opened
                        // menu reveals the intervening change; retained evidence cannot win.
                        b.setAttribute(one, "AXMenuItemMarkChar", "✓")
                        b.setAttribute(two, "AXMenuItemMarkChar", "")
                        f.routingLateScopeInjected = true
                    }
                    b.setChildren(f.mixer, census + [inputPressed ? root : outputRoot]); return true
                }
                if matchingOutput, action == kAXPressAction as String,
                   CFEqual(element, physicalOutput) || CFEqual(element, outputLeaf) {
                    let physical = CFEqual(element, physicalOutput)
                    f.routingDestinationPresses += 1
                    b.setAttribute(output, kAXDescriptionAttribute as String, physical ? "Output 3-4" : "Stereo Output")
                    b.setAttribute(outputEcho, kAXTitleAttribute as String, physical ? "Output 3-4" : "Stereo Output")
                    b.setAttribute(physicalOutput, "AXMenuItemMarkChar", physical ? "✓" : "")
                    b.setAttribute(outputLeaf, "AXMenuItemMarkChar", physical ? "" : "✓")
                    if physical, outcome == "matching_output_source_renewal" {
                        let renewed = b.element(1_291_220)
                        b.setRole(renewed, kAXLayoutItemRole as String)
                        b.setAttribute(renewed, kAXNumberOfCharactersAttribute as String, 0)
                        b.setAttribute(renewed, kAXInsertionPointLineNumberAttribute as String, 0)
                        b.setChildren(renewed, b.makeAXRuntime().children(source))
                        f.routingReplacement = renewed
                    } else if physical, outcome == "matching_output_peer_renewal" {
                        b.setRole(replacementPeer, kAXLayoutItemRole as String)
                        b.setAttribute(replacementPeer, kAXNumberOfCharactersAttribute as String, 0)
                        b.setAttribute(replacementPeer, kAXInsertionPointLineNumberAttribute as String, 0)
                        b.setChildren(replacementPeer, b.makeAXRuntime().children(peer))
                        f.inputReadReplacementPeer = replacementPeer
                        f.routingOtherReplacement = replacementPeer
                    }
                    let current = f.routingReplacement ?? source
                    b.setChildren(f.mixer, [f.inputReadReplacementPeer ?? peer, current])
                    if outcome.hasSuffix("_renewal") {
                        b.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [current])
                        b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, current)
                    }
                    return true
                }
                if action == kAXPressAction as String, CFEqual(element, one) || CFEqual(element, two) {
                    if f.inputInverseLeafObserved, f.routingDestinationPresses == 1 {
                        f.inputInverseScopeOrderedAtWrite = f.inputInverseLastInput > 0
                            && f.inputInverseLastDocument > f.inputInverseLastInput
                    }
                    f.routingDestinationPresses += 1
                    let title = CFEqual(element, one) ? "Bus 1" : "Bus 2"
                    b.setAttribute(input, kAXDescriptionAttribute as String, title); b.setAttribute(echo, kAXTitleAttribute as String, title)
                    if f.routingLateScopeInjected, outcome.hasPrefix("inverse_boundary_"), outcome.hasSuffix("_control") {
                        b.setAttribute(replacementInput, kAXDescriptionAttribute as String, title)
                    }
                    b.setAttribute(one, "AXMenuItemMarkChar", CFEqual(element, one) ? "✓" : "")
                    b.setAttribute(two, "AXMenuItemMarkChar", CFEqual(element, two) ? "✓" : "")
                    b.setChildren(f.mixer, census)
                    if !canonical || retiring {
                        b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, retiring ? source : f.window)
                    }
                    return true
                }
                if action == kAXCancelAction as String, CFEqual(element, root) || CFEqual(element, outputRoot) {
                    if CFEqual(element, root) { f.inputMenuCancels += 1 }
                    let willRetire = retiring || (canonicalRenewal && InputBusSagaAdapter.writePermission != nil)
                        || (matchingRenewal && f.inputMenuCancels > 1)
                        || (composedRenewal && f.inputMenuCancels > 1)
                        || (captureKeep && f.inputMenuCancels == 1)
                    if willRetire, CFEqual(element, root) {
                        let replacement = b.element(1_291_300 + f.inputMenuCancels)
                        b.setRole(replacement, kAXLayoutItemRole as String)
                        b.setAttribute(replacement, kAXNumberOfCharactersAttribute as String, 0)
                        b.setAttribute(replacement, kAXInsertionPointLineNumberAttribute as String, 0)
                        b.setChildren(replacement, b.makeAXRuntime().children(source))
                        f.routingReplacement = replacement
                    }
                    let current = f.routingReplacement ?? f.strips[1]
                    if outcome.hasPrefix("composed_name_execution_caption_peer_"), f.routingNameConfirms == 2,
                       CFEqual(element, root) {
                        // Native presentation cleanup can retain the exact source
                        // and input control while retiring an unrelated peer.
                        b.setRole(replacementPeer, kAXLayoutItemRole as String)
                        b.setAttribute(replacementPeer, kAXNumberOfCharactersAttribute as String, 0)
                        b.setAttribute(replacementPeer, kAXInsertionPointLineNumberAttribute as String, 0)
                        b.setChildren(replacementPeer, b.makeAXRuntime().children(peer))
                        f.inputReadReplacementPeer = replacementPeer
                        f.routingOtherReplacement = replacementPeer
                        if outcome == "composed_name_execution_caption_peer_changed_cancel" {
                            b.setAttribute(b.element(1_291_401), kAXValueAttribute as String, NSNumber(value: 0.4))
                            f.routingLateScopeInjected = true
                        }
                    }
                    if outcome.hasPrefix("composed_name_execution_caption_"), f.routingNameConfirms == 2,
                       CFEqual(element, root) {
                        if outcome == "composed_name_execution_caption_project_cancel" {
                            b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            f.routingLateScopeInjected = true
                        } else if outcome == "composed_name_execution_caption_control_cancel"
                            || outcome == "composed_name_execution_caption_header_refresh_cancel" {
                            b.setButton(replacementInput, description: "Bus 1", help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 60, height: 20)
                            b.setChildren(replacementInput, []); b.setActionNames(replacementInput, [kAXPressAction as String])
                            b.setChildren(current, b.makeAXRuntime().children(current).map { CFEqual($0, input) ? replacementInput : $0 })
                            f.routingLateScopeInjected = true
                        }
                    }
                    if outcome.hasPrefix("retired_track_peer_"), f.inputSagaForwardVerified,
                       f.routingDestinationPresses == 1, CFEqual(element, root) {
                        b.setRole(replacementPeer, kAXLayoutItemRole as String)
                        b.setChildren(replacementPeer, b.makeAXRuntime().children(peer))
                        f.inputReadReplacementPeer = replacementPeer
                    }
                    b.setChildren(f.mixer, [f.inputReadReplacementPeer ?? peer, current])
                    if willRetire { b.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [current]) }
                    if !canonical || willRetire {
                        b.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                            outcome == "matching_renewal_rail" && willRetire ? f.rail : willRetire ? current : f.window)
                    }
                    if captureKeep, willRetire {
                        if outcome == "keep_capture_foreign_focus" { injectForeignInputEditor(f) }
                        if outcome == "keep_capture_foreign_project" {
                            b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        }
                    }
                    if composedRenewal, willRetire, !f.routingLateScopeInjected {
                        if outcome.hasSuffix("_peer") {
                            b.setAttribute(b.element(1_291_401), kAXValueAttribute as String, NSNumber(value: 0.4))
                        } else if outcome.hasSuffix("_project") {
                            b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        } else if outcome.hasSuffix("_header") {
                            let foreign = b.element(1_971_499)
                            b.setRole(foreign, kAXGroupRole as String)
                            b.setAttribute(foreign, kAXTitleAttribute as String, "Duplicate")
                            b.setAttribute(foreign, kAXSelectedAttribute as String, true); b.setChildren(foreign, [])
                            b.setChildren(f.rail, b.makeAXRuntime().children(f.rail).map { CFEqual($0, f.headers[0]) ? foreign : $0 })
                        } else { return true }
                        f.routingLateScopeInjected = true
                    }
                    return true
                }
                Issue.record("Unexpected input Saga action"); return false
            }
            if outcome.contains("peer_send") {
                let anchor = b.element(1_291_450), group = b.element(1_291_451)
                let bypass = b.element(1_291_452), list = b.element(1_291_453), knob = b.element(1_291_454)
                b.setButton(anchor, description: "send button", help: "Send slot. Route signal.", x: 0, y: 0, width: 1, height: 1)
                b.setChildren(anchor, [])
                b.setRole(group, kAXGroupRole as String); b.setAttribute(group, kAXDescriptionAttribute as String, "Stereo Output")
                b.setRole(bypass, kAXCheckBoxRole as String); b.setAttribute(bypass, kAXValueAttribute as String, 0)
                b.setChildren(bypass, [])
                b.setRole(list, kAXButtonRole as String); b.setAttribute(list, kAXDescriptionAttribute as String, "list")
                b.setChildren(list, []); b.setChildren(group, [bypass, list])
                b.setRole(knob, kAXSliderRole as String); b.setAttribute(knob, kAXHelpAttribute as String, "Send Level knob. Set level.")
                b.setAttribute(knob, kAXValueAttribute as String, outcome.hasSuffix("_unread") ? NSNull() : NSNumber(value: 0))
                b.setAttribute(knob, kAXValueDescriptionAttribute as String, "-∞")
                b.setChildren(knob, []); f.routingScalarControls.append(knob)
                let owner = outcome.hasSuffix("_source") ? f.strips[1] : f.strips[0]
                b.setChildren(owner, b.makeAXRuntime().children(owner) + [anchor, group, knob])
            }
            let captured = try await inspect(f, cache: cache, registry: registry,
                domains: canonical ? ["tracks", "strips", "associations", "routing"] : ["associations"],
                scope: canonical ? "selection" : "whole_project")
            if captureKeep, ["keep_capture_foreign_focus", "keep_capture_foreign_project"].contains(outcome) {
                #expect(f.inputMenuPresses > 0 && f.routingReplacement != nil)
                #expect(captured["snapshot_id"] == nil && captured["error"] != nil,
                    "Foreign custody cannot publish a successful retained snapshot")
                #expect(f.routingDestinationPresses == 0 && f.inputSetterDispatches == 0)
                return
            }
            let snapshotID = try #require(captured["snapshot_id"] as? String, "Actual input capture: \(captured)")
            let capture = try #require(await cache.retainedInspection(id: snapshotID)).capture
            if captureKeep {
                #expect(f.inputMenuPresses > 0 && f.routingReplacement != nil,
                    "Reach the actual owned popup and native source retirement during capture")
                #expect(f.routingDestinationPresses == 0 && f.inputSetterDispatches == 0)
                guard case .issued(let project)? = capture.projectIssuance else {
                    #expect(outcome == "keep_capture_foreign_project"); return
                }
                let wire: Value = .object(["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(project.rawValue), "targets": .array([]),
                    "receivers": .array([.object(["bus": .int(1), "aux": .string("keep")])])])
                guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(try #require(wire.objectValue))
                else { Issue.record("The receiver KEEP policy must parse"); return }
                let retained = try #require(await cache.retainedInspection(id: snapshotID))
                try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                    let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: wire,
                        names: [], capture: capture, request: retained.request, snapshotCurrent: true)
                    let preview = try #require(sharedJSONObject(plan.json))
                    let executable = try #require(preview["executable"] as? Bool)
                    if outcome == "keep_capture_healthy" { #expect(executable, "\(preview)") }
                    else { #expect(!executable, "\(preview)") }
                    if outcome == "keep_capture_healthy" {
                        let fresh = try #require(capture.freshPopulation)
                        #expect(fresh.presentationBinding != nil && fresh.stable && fresh.uiEffects.restoration == "restored")
                        let focus = try #require(fresh.presentationBinding?.focus)
                        #expect(CFEqual(focus, try #require(f.routingReplacement)))
                    }
                }
                return
            }
            let row = try #require(capture.channelStrips.indices.first { capture.channelStrips[$0].physicalBinding.map { CFEqual($0.strip, f.strips[1]) } == true })
            let reference = try #require(capture.mixerReference(at: row))
            if !canonical {
                b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, retiring ? f.strips[1] : f.window)
            }
            let router = ChannelRouter(), gate = LogicMutationGate(), journal = SagaJournal(), key = "owned-input-saga"
            let boundaryOutcome = matchingOutput && outcome.hasSuffix("_ack_only") ? "no_observer"
                : matchingOutput && outcome.hasSuffix("_cancel") ? "cancel"
                : canonicalRenewal ? (outcome.hasSuffix("_cancel") ? "cancel" : outcome.hasSuffix("_failure") ? "failure" : "completed")
                : outcome.hasPrefix("composed_name_execution") ? (outcome.hasSuffix("_cancel") ? "cancel" : outcome.hasSuffix("_failure") || outcome.hasSuffix("_external_name") ? "failure" : "completed")
                : outcome.hasPrefix("inverse_boundary_") || outcome == "checked_inverse_input" ? "failure"
                : outcome.hasPrefix("retired_track_peer_") ? String(outcome.dropFirst("retired_track_peer_".count))
                : retiring ? String(outcome.dropFirst("retired_track_".count)) : outcome
            @Sendable func injectInverseBoundary() {
                guard outcome.hasPrefix("inverse_boundary_"), f.inputSagaForwardVerified, f.routingDestinationPresses == 1,
                      AccessibilityChannel.inputChangeObserver != nil, !f.routingLateScopeInjected else { return }
                f.routingLateScopeInjected = true
                if outcome.hasSuffix("_control") {
                    b.setButton(replacementInput, description: "Bus 2", help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 60, height: 20)
                    b.setChildren(replacementInput, []); b.setActionNames(replacementInput, [kAXPressAction as String])
                    b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]).filter { !CFEqual($0, input) } + [replacementInput])
                } else if outcome.hasSuffix("_sink") {
                    b.setAttribute(output, kAXDescriptionAttribute as String, "Output 3-4")
                    b.setAttribute(outputEcho, kAXTitleAttribute as String, "Output 3-4")
                    b.setAttribute(outputLeaf, kAXTitleAttribute as String, "Output 3-4")
                } else {
                    b.setRole(replacementPeer, kAXLayoutItemRole as String)
                    b.setChildren(replacementPeer, b.makeAXRuntime().children(f.strips[0]))
                    b.setChildren(f.mixer, b.makeAXRuntime().children(f.mixer).map { CFEqual($0, f.strips[0]) ? replacementPeer : $0 })
                }
            }
            f.routingRead = { element, attribute in
                if matchingOutput, f.routingDestinationPresses == 1, !f.routingLateScopeInjected {
                    if outcome == "matching_output_final_input", CFEqual(element, one), attribute == "AXMenuItemMarkChar" {
                        b.setAttribute(one, "AXMenuItemMarkChar", ""); b.setAttribute(two, "AXMenuItemMarkChar", "✓")
                        f.routingLateScopeInjected = true
                    }
                    if outcome == "matching_output_final_output", f.inputReadAfterOutput,
                       CFEqual(element, physicalOutput), attribute == "AXMenuItemMarkChar" {
                        b.setAttribute(physicalOutput, "AXMenuItemMarkChar", ""); b.setAttribute(outputLeaf, "AXMenuItemMarkChar", "✓")
                        f.routingLateScopeInjected = true
                    }
                }
                if f.inputInverseLeafObserved, f.routingDestinationPresses == 1 {
                    f.inputInverseReadSequence += 1
                    if CFEqual(element, f.window), attribute == kAXDocumentAttribute as String {
                        f.inputInverseLastDocument = f.inputInverseReadSequence
                    }
                    if CFEqual(element, trailingInputMarker), attribute == kAXRoleAttribute as String {
                        f.inputInverseLastInput = f.inputInverseReadSequence
                    }
                }
                if outcome.hasPrefix("inverse_boundary_final_document_"), f.inputInverseLeafObserved,
                   f.routingDestinationPresses == 1, !f.routingLateScopeInjected {
                    if CFEqual(element, f.window), attribute == kAXDocumentAttribute as String {
                        f.inputInverseDocumentRead = true; f.inputInverseDescriptionRead = false
                    }
                    if f.inputInverseDocumentRead, CFEqual(element, input), attribute == kAXDescriptionAttribute as String {
                        f.inputInverseDescriptionRead = true
                    }
                    if f.inputInverseDescriptionRead, CFEqual(element, trailingInputMarker), attribute == kAXRoleAttribute as String {
                        f.inputInverseDocumentRead = false; f.inputInverseDescriptionRead = false
                        f.inputInverseDocumentCandidates += 1
                        // Both popupOwned checks scan the input before and after their owner
                        // checks. The fourth group is the final, deciding pre-action scan;
                        // the first is the earlier refusal control. Neither runs after a write.
                        if f.inputInverseDocumentCandidates == Int(outcome.split(separator: "_").last ?? "") {
                            f.routingLateScopeInjected = true
                            b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        }
                    }
                }
                // Mutate only after the actual verified forward, at inverse acquisition.
                if !outcome.contains("_final_"), CFEqual(element, output), attribute == kAXDescriptionAttribute as String {
                    injectInverseBoundary()
                }
            }
            f.routingActionNames = { element in
                // A separate witness reaches the actual inverse leaf's capability read.
                if outcome.hasPrefix("inverse_boundary_final_document_"), CFEqual(element, one), f.inputSagaForwardVerified,
                   AccessibilityChannel.inputChangeObserver != nil { f.inputInverseLeafObserved = true }
                else if outcome.contains("_final_"), CFEqual(element, one) { injectInverseBoundary() }
                return nil
            }
            await router.register(SendRemovalSagaResultBoundary(base: f.channel(), journal: journal, mode: boundaryOutcome,
                operation: matchingOutput ? "mixer.set_output_verified" : "mixer.set_input_bus_verified", idempotencyKey: key, afterForward: {
                    f.inputSagaForwardVerified = true
                    switch outcome {
                    case "late_inverse_name":
                        b.setAttribute(f.headers[0], kAXTitleAttribute as String, "External Name")
                    case "composed_name_execution_external_name":
                        b.setAttribute(b.element(1_971_400), kAXDescriptionAttribute as String, "External Name")
                        b.setAttribute(f.headers[0], kAXTitleAttribute as String, "External Name")
                        b.setAttribute(b.element(1_965_711), kAXValueAttribute as String, "External Name")
                    case "late_inverse_input": b.setAttribute(input, kAXDescriptionAttribute as String, "Bus 256")
                    case "late_inverse_project": b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    case "late_inverse_source": b.setChildren(f.mixer, [f.strips[0]])
                    case "late_inverse_output": b.setAttribute(output, kAXDescriptionAttribute as String, "Bus 2")
                    case "late_inverse_control":
                        let foreign = b.element(1_291_214)
                        b.setButton(foreign, description: "Bus 2", help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 60, height: 20)
                        b.setChildren(foreign, [])
                        b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]).filter { !CFEqual($0, input) } + [foreign])
                    default: return
                    }
                    f.routingLateScopeInjected = true
                }, beforeForward: {
                    if !matchingOutput { f.inputSetterDispatches += 1 }
                    guard canonical, outcome.hasPrefix("dispatch_") else { return }
                    f.routingLateScopeInjected = true
                    if outcome == "dispatch_name" {
                        b.setAttribute(f.headers[0], kAXTitleAttribute as String, "External Name")
                    } else if outcome == "dispatch_focus" {
                        injectForeignInputEditor(f)
                    } else if outcome == "dispatch_peer" {
                        b.setAttribute(b.element(1_291_401), kAXValueAttribute as String, NSNumber(value: 0.4))
                    } else {
                        b.setButton(replacementInput, description: "Bus 1", help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 60, height: 20)
                        b.setChildren(replacementInput, []); b.setActionNames(replacementInput, [kAXPressAction as String])
                        b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]).map { CFEqual($0, input) ? replacementInput : $0 })
                    }
                }, observedOperation: { operation in
                    if matchingOutput, operation == "mixer.set_input_bus_verified" { f.inputSetterDispatches += 1 }
                }, observedResult: { result in
                    let expected = canonical && outcome.hasPrefix("dispatch_") ? "C" : "A"
                    #expect(sharedJSONObject(result.message)?["state"] as? String == expected, "Actual scalar input result: \(result.message)")
                }))
            let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                poller: StatePoller(axChannel: f.channel(), cache: cache,
                    runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing })),
                dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal, mutationGate: gate,
                liveTrackNames: { [:] })
            var stepParams: [String: Value] = ["destination": .object(["kind": .string("bus"), "number": .int(2)]),
                "expected_current": .object(["kind": .string("bus"), "number": .int(1)]), "replace_existing": .bool(true)]
            if outcome == "wrong_project" { stepParams["project_ref"] = .string("prj_foreign") }
            let trackReference = try #require(capture.issued?.byRow.first ?? nil)
            let wrongTrackReference = try #require(capture.issued?.byRow.last ?? nil)
            if canonical {
                try await assertCanonicalInputExecution(f, dependencies: dependencies, snapshotID: snapshotID,
                    capture: capture, trackReference: trackReference, key: key, outcome: requestedOutcome)
                return
            }
            let target = outcome == "wrong_target" ? try #require(capture.mixerReference(at: 0))
                : outcome == "wrong_track" ? wrongTrackReference : retiring ? trackReference : reference
            var wire: [String: Value] = ["idempotency_key": .string(key), "steps": .array([.object([
                "operation_id": .string(OperationID.mixerSetInputBusVerified.rawValue), "target_ref": .string(target.rawValue),
                "params": .object(stepParams),
                "expected_inverse": .object(["operation_id": .string(OperationID.mixerSetInputBusVerified.rawValue), "value_parameter": .string("destination")])])])]
            wire["confirmed_plan_hash"] = .string(SagaJournal.planHash(try SagaWire.plan(from: wire)))
            if outcome == "wrong_hash" { wire["confirmed_plan_hash"] = .string(String(repeating: "0", count: 64)) }
            if outcome == "missing_hash" { wire.removeValue(forKey: "confirmed_plan_hash") }
            let preflight = try #require(OperationHandlerRegistry.handler(tool: "logic_system", command: "saga_preflight"))
            let preview = await FeatureFlags.withAdr004MutationSagaForTests(true) { await preflight(dependencies, wire) }
            let previewBody = try #require(sharedJSONObject(sharedToolText(preview)))
            if ["wrong_target", "wrong_track", "wrong_project"].contains(outcome) {
                let ok = try #require(previewBody["ok"] as? Bool)
                #expect(!ok)
                #expect(f.routingDestinationPresses == 0)
                return
            }
            let ok = try #require(previewBody["ok"] as? Bool)
            #expect(ok, "Actual input preflight: \(previewBody)")
            #expect(f.routingDestinationPresses == 0)
            if outcome == "retired_track_changed_input" {
                b.setAttribute(input, kAXDescriptionAttribute as String, "Bus 2")
                b.setAttribute(echo, kAXTitleAttribute as String, "Bus 2")
                b.setAttribute(one, "AXMenuItemMarkChar", ""); b.setAttribute(two, "AXMenuItemMarkChar", "✓")
            }
            if outcome == "retired_track_removed_header" { b.setChildren(f.rail, [f.headers[1]]) }
            let execute = try #require(OperationHandlerRegistry.handler(tool: "logic_system", command: "saga_execute"))
            let result = await FeatureFlags.withAdr004MutationSagaForTests(true) { await execute(dependencies, wire) }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            if ["wrong_hash", "missing_hash"].contains(outcome) {
                #expect(body["state"] as? String == "C")
                let wrote = try #require(body["write_attempted"] as? Bool)
                #expect(!wrote && f.routingDestinationPresses == 0)
                return
            }
            if ["retired_track_changed_input", "retired_track_removed_header"].contains(outcome) {
                #expect(body["state"] as? String == "C", "Changed original input target: \(body)")
                #expect(f.routingDestinationPresses == 0 && !gate.isHeldByEntitledHolder())
                return
            }
            // Moving the protected read before the final owner check removes the unsafe
            // fourth post-document group. If it is absent, require actual input reads AND
            // a later document check at the real inverse press, not mere non-injection.
            let orderedFinalScope = outcome == "inverse_boundary_final_document_4" && !f.routingLateScopeInjected
            if orderedFinalScope { #expect(f.inputInverseScopeOrderedAtWrite) }
            if !orderedFinalScope && (["no_observer", "lost_observer", "checked_inverse_input"].contains(outcome) || outcome.hasPrefix("late_inverse_") || outcome.hasPrefix("inverse_boundary_") || outcome == "completed") {
                #expect(body["state"] as? String == (outcome == "completed" ? "A" : "B"), "Actual input result: \(body)")
                #expect(body["saga_state"] as? String == (outcome == "completed" ? "completed"
                    : outcome.hasPrefix("inverse_boundary_") || outcome == "checked_inverse_input" ? "compensationFailed" : "rollbackUncertain"))
                #expect(f.routingDestinationPresses == (outcome == "no_observer" ? 0 : 1))
                if outcome.hasPrefix("late_inverse_") || outcome.hasPrefix("inverse_boundary_") || outcome == "checked_inverse_input" { #expect(f.routingLateScopeInjected) }
                let presses = f.routingDestinationPresses
                let replay = await FeatureFlags.withAdr004MutationSagaForTests(true) { await execute(dependencies, wire) }
                let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
                let duplicate = try #require(replayBody["duplicate"] as? Bool)
                #expect(duplicate)
                #expect(f.routingDestinationPresses == presses && !gate.isHeldByEntitledHolder())
                return
            }
            #expect(body["saga_state"] as? String == "fullyCompensated", "Actual input Saga: \(body)")
            #expect(f.routingDestinationPresses == 2)
            if outcome.hasPrefix("retired_track_peer_") {
                #expect(f.inputReadReplacementPeer == nil,
                    "Do not cancel a redundant input popup between the verified effect and its checked inverse")
            }
            #expect(b.attributeValue(one, "AXMenuItemMarkChar") as? String == "✓")
            #expect(b.attributeValue(two, "AXMenuItemMarkChar") as? String == "")
            if retiring { #expect(f.routingReplacement != nil && f.inputMenuCancels > 2) }
            let readsBeforeReplay = f.inputMenuPresses
            let replay = await FeatureFlags.withAdr004MutationSagaForTests(true) { await execute(dependencies, wire) }
            let replayBody = try #require(sharedJSONObject(sharedToolText(replay)))
            if boundaryOutcome == "cancel" {
                #expect(replayBody["error"] as? String == HonestContract.FailureError.unsupportedState.rawValue)
            } else {
                let duplicate = try #require(replayBody["duplicate"] as? Bool)
                #expect(duplicate)
            }
            #expect(f.routingDestinationPresses == 2 && !gate.isHeldByEntitledHolder())
            #expect(f.inputMenuPresses == readsBeforeReplay, "Replay must not reacquire a native input")
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

    @Test("Input renewal restores pre-popup geometry, not a transient post-Cancel layout")
    func registeredInputGraphKeepsItsPrePopupGeometry() async throws {
        try await assertInputBusRenewal(number: 1, condition: "transient_cancel_geometry", graph: true)
    }

    @Test("Input intent assessment reuses the renewed original pair and checked input, not its label",
          arguments: [1, 256])
    func canonicalInputAssessmentUsesItsActualCapturedPair(desired: Int) async throws {
        try await assertInputBusRenewal(number: 256, condition: "paired", graph: true, inputGoal: desired)
    }

    @Test("An owned input renewal retains exact source authority for later checked output acquisition")
    func registeredInputRenewalPreservesLaterCheckedOutput() async throws {
        try await assertInputBusRenewal(number: 1, condition: "paired", graph: true, readOutputAfterRenewal: true)
    }

    @Test("A restored input popup cannot hide its later original-header inverse failure",
          arguments: ["healthy", "peer_retired", "unrequested_peer", "unrequested_peer_changed"])
    func selectedInputCaptureReportsItsActualRenewalRestoration(_ outcome: String) async throws {
        try await assertInputBusRenewal(number: 1, condition: "cold_rail_input_\(outcome)", graph: true)
    }

    @Test func registeredReceiverKeepRenewsOnlyItsOriginallyCapturedHeader() async throws {
        try await assertInputBusRenewal(number: 1, condition: "paired", graph: true, keep: true)
    }

    @Test(arguments: ["replaced_header", "foreign_project", "foreign_focus", "partial_restore",
                      "deciding_read", "deciding_control_replaced", "renewed_label_changed"])
    func registeredReceiverKeepRefusesLostOriginalRenewal(condition: String) async throws {
        try await assertInputBusRenewal(number: 1, condition: condition, graph: true, keep: true)
    }

    @Test(arguments: ["force_fresh_surviving_source", "force_fresh_retired_source", "force_fresh_missing_pair",
                      "force_fresh_wrong_pair", "force_fresh_changed_label", "force_fresh_foreign_project",
                      "force_fresh_rail_retired_source", "force_fresh_rail_surviving_source"])
    func requestedInputRefreshNeedsItsActualOriginalHeader(_ condition: String) async throws {
        try await assertInputBusRenewal(number: 1, condition: condition)
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

    @Test(arguments: ["healthy", "retained_focus", "own_landing", "foreign_editor", "foreign_held_strip",
                     "joint_landing", "foreign_joint_focus", "foreign_joint_child", "foreign_joint_document",
                     "foreign_joint_parent", "foreign_joint_unreadable", "child_landing",
                     "foreign_child_focus", "foreign_child_child", "foreign_child_document",
                     "foreign_child_parent", "foreign_child_unreadable"])
    func wholeInspectionKeepsOnlyItsOwnLateSelectionFocus(fault: String) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true), b = f.builder
        f.useBulkReads = true
        let jointLanding = fault == "joint_landing" || fault.hasPrefix("foreign_joint_")
        let childLanding = fault == "child_landing" || fault.hasPrefix("foreign_child_")
        let delayedChild = jointLanding || childLanding
        for (index, header) in f.headers.enumerated() {
            b.setAttribute(header, kAXSelectedAttribute as String, index == 3)
        }
        b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.strips[2])
        b.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.strips[2]])
        f.thirdRetainsPreviousFocus = fault == "retained_focus"
        f.routingSelection = { index in
            let source = index == 0 ? 1 : index == 1 ? 0 : index == 2 ? 3 : 2
            b.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String,
                [f.strips[delayedChild && index == 2 ? 0 : source]])
        }
        let inject = delayedChild || ["own_landing", "foreign_editor", "foreign_held_strip"].contains(fault)
        let foreign = b.element(1_965_799)
        b.setRole(foreign, kAXTextFieldRole as String)
        b.setAttribute(foreign, kAXWindowAttribute as String, f.window)
        f.routingRead = { element, attribute in
            guard inject, f.selections.last == 2 else { return }
            if CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String,
               !f.lateAssociationFocusSampled {
                f.lateAssociationFocusSampled = true
                // Focus and, in the joint case, the selected-child relation
                // still reflect the preceding, completely held strip. The
                // child-only case already has this selection's actual focus.
                b.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                    f.strips[childLanding ? 3 : 0])
            }
            if f.lateAssociationFocusSampled, !f.lateAssociationFocusLanded,
               CFEqual(element, f.scroll), attribute == kAXValueAttribute as String {
                f.lateAssociationFocusLanded = true
                let focus = fault == "own_landing" || delayedChild ? f.strips[3]
                    : fault == "foreign_held_strip" ? f.strips[1] : foreign
                b.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                    fault == "foreign_joint_focus" || fault == "foreign_child_focus" ? f.strips[1] : focus)
                if delayedChild {
                    b.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String,
                        [f.strips[fault == "foreign_joint_child" ? 0 : fault == "foreign_child_child" ? 1 : 3]])
                    if fault == "foreign_joint_document" || fault == "foreign_child_document" {
                        b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                    if fault == "foreign_joint_parent" || fault == "foreign_child_parent" {
                        b.setAttribute(f.strips[3], kAXParentAttribute as String, f.rail)
                    }
                }
            }
        }
        if fault == "foreign_joint_unreadable" || fault == "foreign_child_unreadable" {
            f.routingReadResult = { element, attribute in
                if f.lateAssociationFocusLanded, CFEqual(element, f.mixer),
                   attribute == kAXSelectedChildrenAttribute as String {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                return nil
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

    @Test("Held native custody avoids global strip reclassification and still stops the next Help after loss",
          arguments: ["none", "project", "editor", "transport", "retired"])
    func heldNativeCustodyPrecedesGlobalFocusClassification(fault: String) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        f.useBulkReads = true
        f.builder.setAttributeSettable(f.strips[1], kAXFocusedAttribute as String, true)
        for (index, strip) in f.strips.enumerated() {
            f.builder.setAttribute(strip, kAXInsertionPointLineNumberAttribute as String, 0)
            let slot = f.builder.element(1_966_200 + index)
            f.builder.setRole(slot, kAXButtonRole as String)
            f.builder.setAttribute(slot, kAXDescriptionAttribute as String, "Audio Plug-in")
            f.builder.setAttribute(slot, kAXHelpAttribute as String, "Audio Effect slot. Insert an audio effect.")
            f.builder.setAttribute(slot, kAXPositionAttribute as String, axPoint(200 + CGFloat(index) * 70, 300))
            f.builder.setAttribute(slot, kAXSizeAttribute as String, axSize(58, 16))
            let children = f.builder.makeAXRuntime().children(strip)
            f.builder.setChildren(strip, children + [slot])
        }
        f.routingReadResult = { element, attribute in
            guard attribute == kAXHelpAttribute as String, AXHelpers.HelpReadGuard.current != nil else { return nil }
            if f.focusOrderFaultInjected { f.helpReadsAfterFocusOrderFault += 1 }
            do {
                f.guardedEntryHelpReads += 1
                if fault != "none", !f.focusOrderFaultInjected {
                    f.focusOrderFaultInjected = true
                    switch fault {
                    case "project":
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///different.logicx/")
                    case "editor":
                        let editor = f.builder.element(1_965_996)
                        f.builder.setRole(editor, kAXTextFieldRole as String)
                        f.builder.setAttribute(editor, kAXValueAttribute as String, "typing")
                        f.builder.setAttributeSettable(editor, kAXValueAttribute as String, true)
                        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, editor)
                    case "transport":
                        f.builder.setAttribute(f.builder.element(1_965_721), kAXValueAttribute as String, 1)
                    case "retired":
                        f.builder.setChildren(f.mixer, f.strips.filter { !CFEqual($0, f.strips[1]) })
                    default: Issue.record("unknown focus-order fault")
                    }
                }
            }
            return nil
        }
        let body = try await inspect(f, domains: ["tracks", "strips", "associations", "routing"],
                                     guardedPassiveFocus: true, scope: "selection")
        #expect(f.guardedEntryHelpReads > 0, "The actual guarded native Help reader must be reached")
        if fault == "none" {
            let section = try #require(body["associations"] as? [String: Any])
            let rows = try #require(section["rows"] as? [[String: Any]])
            #expect(rows.compactMap { $0["track_index"] as? Int } == [0])
            #expect(f.passiveFinalAppTupleReads > 0, "Fresh original-focus custody remains exercised")
            #expect(f.globalFocusClassificationsDuringHeldEntry == 0,
                    "A current held proof must precede the global hierarchy classifier")
            #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        } else {
            #expect(f.focusOrderFaultInjected)
            #expect(f.helpReadsAfterFocusOrderFault == 0)
            #expect(f.selections.isEmpty)
            #expect(body["associations"] == nil)
        }
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

    @Test("Requested native header is observed before optional peers within the unchanged collection reserve",
          arguments: ["owned", "foreign_document", "foreign_window", "missing_header", "unrequested_census_change"])
    func requestedNativeHeaderPrecedesOptionalCollection(fault: String) async throws {
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
            let target = AXTrackBinding.Binding(
                window: fault == "foreign_window" ? f.builder.element(965_991_001) : f.window,
                header: fault == "missing_header" ? f.builder.element(965_991_002) : f.headers[3],
                document: fault == "foreign_document" ? "file:///Foreign.logicx" : association.document,
                runtime: f.logic())
            if fault == "unrequested_census_change" {
                f.routingSelection = { index in
                    if index == 3 {
                        f.routingLateScopeInjected = true
                        f.builder.setChildren(f.rail, [f.headers[0], f.headers[1], f.headers[3]])
                    }
                }
            }
            let pairs = await association.observe(referenceIsCurrent: { true }, stoppingWhen: { false },
                allHeldHeaders: true, prioritizingHeader: target, collectionNow: {
                    start.advanced(by: f.selections.isEmpty ? .zero : .seconds(6))
                })
            if fault == "owned" {
                #expect(f.selections == [3, 0], "Spend optional collection time on the actual requested header first")
                #expect(pairs.count == 2)
                #expect(pairs.contains { CFEqual($0.track.header, target.header) })
                #expect(association.effects.restoration == "restored")
                #expect(association.headers.count == 4 && association.strips.count == 4,
                    "Prioritizing a challenge does not narrow complete ownership custody")
            } else {
                #expect(pairs.isEmpty, "A priority hint supplies no foreign or incomplete ownership authority")
                if fault == "unrequested_census_change" { #expect(f.routingLateScopeInjected) }
                else { #expect(f.selections.isEmpty) }
            }
        }
    }

    @Test("Original-header renewal actually challenges its retained native source before optional peers")
    func sourceRenewalPrioritizesItsActualNativeHeader() async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        try await OperationTraceContext.$current.withValue(context) {
            let initial = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: f.logic(), expectedProject: nil, requiresProjectReference: false))
            let pairs = await initial.observe(referenceIsCurrent: { true }, stoppingWhen: { false }, allHeldHeaders: true)
            let source = try #require(pairs.first { CFEqual($0.track.header, f.headers[3]) })
            let selectionCount = f.selections.count
            let renewal = await AccessibilityChannel.renewSourceThroughOriginalHeader(source, original: source.strip,
                runtime: f.logic(), selectedHeaderRequired: false, sourceDisposition: .readObservation)
            let actual = try #require(renewal.source)
            #expect(actual.originalTrack.matches(source.track) && actual.pair.track.matches(source.track))
            #expect(Array(f.selections.dropFirst(selectionCount)).first == 3,
                "The input consumer must request the exact retained header priority, not merely expose an unused helper")
            #expect(actual.observation.headers.count == 4 && actual.observation.strips.count == 4)
            #expect(renewal.effects.restoration == "restored")
        }
    }

    @Test("Optional peer discovery ends only after the requested native strips were actually associated",
          arguments: ["owned", "late_peer", "missing_peer", "foreign_document", "unrequested_census_change"])
    func requestedNativePeersEndOnlyOptionalDiscovery(fault: String) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        try await OperationTraceContext.$current.withValue(context) {
            let initial = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: f.logic(), expectedProject: nil, requiresProjectReference: false))
            let originalPairs = await initial.observe(referenceIsCurrent: { true }, stoppingWhen: { false }, allHeldHeaders: true)
            let first = try #require(originalPairs.first { CFEqual($0.track.header, f.headers[1]) })
            let second = try #require(originalPairs.first { CFEqual($0.track.header, f.headers[fault == "late_peer" ? 3 : 2]) })
            let absent = AXTrackBinding.Binding(window: f.window,
                header: f.builder.element(965_992_001), document: initial.document, runtime: f.logic())
            let foreign = AXTrackBinding.Binding(window: f.window,
                header: second.track.header, document: "file:///Foreign.logicx", runtime: f.logic())
            let targets = [first.track, fault == "missing_peer" ? absent : fault == "foreign_document" ? foreign : second.track]
            let count = f.selections.count
            if fault == "late_peer" {
                f.routingSelection = { index in
                    guard index == 2 else { return }
                    f.routingLateScopeInjected = true
                    let replacement = f.builder.element(965_992_210)
                    f.builder.setRole(replacement, kAXLayoutItemRole as String)
                    f.builder.setAttribute(replacement, kAXNumberOfCharactersAttribute as String, 0)
                    f.builder.setAttribute(replacement, kAXInsertionPointLineNumberAttribute as String, 0)
                    f.builder.setChildren(replacement, f.builder.makeAXRuntime().children(f.strips[3]))
                    f.builder.setChildren(f.mixer, [f.strips[0], f.strips[1], f.strips[2], replacement])
                }
            }
            if fault == "unrequested_census_change" {
                f.routingSelection = { index in
                    if index == 2 {
                        f.routingLateScopeInjected = true
                        f.builder.setChildren(f.rail, [f.headers[0], f.headers[1], f.headers[2]])
                    }
                }
            }
            let observation = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: f.logic(), expectedProject: nil, requiresProjectReference: false))
            let pairs = await observation.observe(referenceIsCurrent: { true }, stoppingWhen: { false },
                allHeldHeaders: true, observingPeerHeaders: targets)
            let selected = Array(f.selections.dropFirst(count))
            if fault == "owned" || fault == "late_peer" {
                #expect(selected == (fault == "late_peer" ? [1, 3, 0] : [1, 2, 0]),
                    "Observe requested native peers before unrelated headers")
                #expect(!f.routingLateScopeInjected)
                #expect(pairs.count == 3 && !pairs.contains { CFEqual($0.track.header, f.headers[fault == "late_peer" ? 2 : 3]) })
                #expect(observation.headers.count == 4 && observation.strips.count == 4)
                #expect(observation.effects.restoration == "restored")
            } else if fault == "unrequested_census_change" {
                #expect(f.routingLateScopeInjected && pairs.isEmpty)
            } else {
                #expect(selected == [1, 2, 3, 0], "Unobserved or foreign native peers must not terminate collection early")
                #expect(pairs.count == 4)
                #expect(!pairs.contains { $0.track.matches(fault == "missing_peer" ? absent : foreign) })
            }
        }
    }

    @Test("Captured physical receivers end discovery only after actual original-header relationships",
          arguments: ["owned", "foreign_document", "foreign_window", "foreign_mixer",
                      "same_label_foreign_strip", "required_retired", "unrelated_retired"])
    func capturedNativeReceiversAvoidUnrelatedSelectionRetirement(fault: String) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        try await OperationTraceContext.$current.withValue(context) {
            let initial = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: f.logic(), expectedProject: nil, requiresProjectReference: false))
            let pairs = await initial.observe(referenceIsCurrent: { true }, stoppingWhen: { false },
                allHeldHeaders: true, observingPeerHeaders: [])
            let source = try #require(pairs.first { CFEqual($0.track.header, f.headers[0]) })
            let peer = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
                strip: f.strips[0], document: initial.document)
            let foreign = f.builder.element(965_992_100)
            f.builder.setRole(foreign, kAXLayoutItemRole as String)
            let capturedName = try #require(f.builder.attributeValue(f.builder.element(1_965_713),
                kAXValueAttribute as String) as? String)
            let foreignName = f.builder.element(965_992_102)
            f.builder.setRole(foreignName, kAXTextFieldRole as String)
            f.builder.setAttribute(foreignName, kAXDescriptionAttribute as String, "Name")
            f.builder.setAttribute(foreignName, kAXValueAttribute as String, capturedName)
            f.builder.setChildren(foreign, [foreignName])
            let foreignWindow = f.builder.element(965_992_103), foreignMixer = f.builder.element(965_992_104)
            f.builder.setRole(foreignWindow, kAXWindowRole as String)
            f.builder.setRole(foreignMixer, kAXGroupRole as String)
            f.builder.setChildren(foreignWindow, [foreignMixer]); f.builder.setChildren(foreignMixer, [])
            let second = AXMixerStripBinding.Binding(window: fault == "foreign_window" ? foreignWindow : f.window,
                mixer: fault == "foreign_mixer" ? foreignMixer : f.mixer,
                strip: fault == "same_label_foreign_strip" ? foreign : f.strips[3],
                document: fault == "foreign_document" ? "file:///Foreign.logicx" : initial.document)
            let count = f.selections.count
            f.routingSetter = { element, attribute, value in
                let challenge = fault == "required_retired" || fault == "unrelated_retired" ? 2 : 3
                guard !f.routingLateScopeInjected, CFEqual(element, f.rail),
                      attribute == kAXSelectedChildrenAttribute as String,
                      let chosen = value as? [AXUIElement], chosen.count == 1,
                      CFEqual(chosen[0], f.headers[challenge]) else { return nil }
                f.routingLateScopeInjected = true
                f.selections.append(challenge)
                let changed = fault == "required_retired" ? 3 : 2
                let replacement = f.builder.element(965_992_101)
                for name in [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                             kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute] as [String] {
                    if let current = f.builder.attributeValue(f.strips[changed], name) {
                        f.builder.setAttribute(replacement, name, current)
                    }
                }
                f.builder.setChildren(replacement, f.builder.makeAXRuntime().children(f.strips[changed]))
                f.builder.setChildren(f.mixer, f.strips.enumerated().map { $0.offset == changed ? replacement : $0.element })
                for (index, header) in f.headers.enumerated() {
                    f.builder.setAttribute(header, kAXSelectedAttribute as String, index == challenge)
                }
                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String,
                    fault == "unrelated_retired" ? f.strips[3] : replacement)
                return true
            }
            let renewed = await AccessibilityChannel.renewSourceThroughOriginalHeader(source, original: source.strip,
                runtime: f.logic(), sourceDisposition: .readObservation, observingPeerStrips: [peer, second])
            if fault == "owned" {
                let actual = try #require(renewed.source)
                #expect(Array(f.selections.dropFirst(count)) == [1, 2, 0])
                #expect(!f.routingLateScopeInjected, "Do not select the unrelated header whose native strip retires")
                #expect(actual.pair.track.matches(source.track) && actual.pair.strip.matches(source.strip))
                #expect(actual.observedPairs.count == 3 && actual.observation.strips.count == 4)
                #expect(renewed.effects.restoration == "restored")
            } else {
                #expect(f.routingLateScopeInjected, "Reach the actual native retirement instead of trusting invalid candidates")
                #expect(renewed.source == nil)
            }
        }
    }

    @Test("Input source renewal forwards actual peer custody without optional unrelated selections")
    func inputRenewalForwardsActualNativePeerCollection() async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        try await OperationTraceContext.$current.withValue(context) {
            let initial = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: f.logic(), expectedProject: nil, requiresProjectReference: false))
            let pairs = await initial.observe(referenceIsCurrent: { true }, stoppingWhen: { false }, allHeldHeaders: true)
            let source = try #require(pairs.first { CFEqual($0.track.header, f.headers[3]) })
            let peer = try #require(pairs.first { CFEqual($0.track.header, f.headers[1]) })
            let count = f.selections.count
            let renewed = await AccessibilityChannel.renewSourceThroughOriginalHeader(source, original: source.strip,
                runtime: f.logic(), selectedHeaderRequired: false, sourceDisposition: .readObservation,
                observingPeerHeaders: [peer.track])
            let actual = try #require(renewed.source)
            #expect(Array(f.selections.dropFirst(count)) == [3, 1, 0])
            #expect(actual.pair.track.matches(source.track) && actual.observedPairs.count == 3)
            #expect(actual.observation.headers.count == 4 && actual.observation.strips.count == 4)
            #expect(renewed.effects.restoration == "restored")
        }
    }

    @Test("A retained header read renews its exact original rail and lifetime without whole-window rediscovery",
          arguments: ["owned", "foreign_scope", "missing_peer", "rail_role", "header_shape"])
    func originalHeldRailRetainsHeaderIdentity(fault: String) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        f.useBulkReads = true
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        try await OperationTraceContext.$current.withValue(context) {
            let runtime = f.logic()
            let held = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: runtime, expectedProject: nil, requiresProjectReference: false))
            let binding = AXTrackBinding.Binding(window: f.window, header: f.headers[0],
                document: held.document, runtime: runtime, observedStackHeader: false, observedHeaders: held.headers)
            #expect(binding.currentIndex() == 0)
            var scope = held
            if fault == "foreign_scope" {
                f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                scope = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                    logic: runtime, expectedProject: nil, requiresProjectReference: false))
                f.builder.setAttribute(f.window, kAXDocumentAttribute as String, held.document)
            }
            if fault == "missing_peer" { f.builder.setChildren(f.rail, Array(f.headers.dropLast())) }
            if fault == "rail_role" { f.builder.setRole(f.rail, kAXButtonRole as String) }
            if fault == "header_shape" {
                let arrow = f.builder.element(965_992_002)
                f.builder.setRole(arrow, kAXDisclosureTriangleRole as String)
                f.builder.setAttribute(arrow, kAXValueAttribute as String, NSNumber(value: 1))
                f.builder.setChildren(f.headers[0], f.builder.makeAXRuntime().children(f.headers[0]) + [arrow])
            }
            f.heldHeaderDiscoveryScans = 0
            f.routingRead = { element, attribute in
                if CFEqual(element, f.window), attribute == kAXRoleAttribute as String,
                   f.activeBulkAttributes == [kAXRoleAttribute, kAXIdentifierAttribute, kAXChildrenAttribute] as [String] {
                    f.heldHeaderDiscoveryScans += 1
                }
            }
            let actual = binding.currentIndex(in: scope)
            if fault == "owned" {
                #expect(actual == 0)
                #expect(f.heldHeaderDiscoveryScans == 0, "Renew the original rail, not another global discovery")
            } else { #expect(actual == nil) }
            if fault == "foreign_scope" {
                #expect(binding.currentIndex() == 0, "A foreign proof cannot retire an otherwise current original binding")
            }
            if fault == "missing_peer" {
                f.builder.setChildren(f.rail, f.headers)
                #expect(binding.currentIndex() == nil, "Restoration cannot erase an observed lifetime loss")
            }
            if fault == "rail_role" {
                f.builder.setRole(f.rail, kAXGroupRole as String)
                #expect(binding.currentIndex(in: scope) == nil, "A lost native scope cannot revive when its role returns")
            }
            #expect(f.selections.isEmpty && f.focusRestorationWrites.isEmpty)
        }
    }

    @Test("A post-input source receipt renews its original native rail and Mixer without rediscovering the window",
          arguments: ["owned", "foreign_scope", "missing_strip", "mixer_role"])
    func renewedInputSourceUsesItsActualHeldRail(fault: String) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        f.useBulkReads = true
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        try await OperationTraceContext.$current.withValue(context) {
            let runtime = f.logic()
            let held = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: runtime, expectedProject: nil, requiresProjectReference: false))
            let pairs = await held.observe(referenceIsCurrent: { true }, stoppingWhen: { false }, allHeldHeaders: true)
            let pair = try #require(pairs.first { CFEqual($0.track.header, f.headers[0]) })
            let observed = await AccessibilityChannel.renewSourceThroughOriginalHeader(pair, original: pair.strip,
                runtime: runtime, sourceDisposition: .readObservation)
            let originalSource = try #require(observed.source)
            var source = originalSource
            let originalMixerRole = try #require(AXHelpers.getRole(f.mixer, runtime: runtime.ax))
            if fault == "foreign_scope" {
                f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                let foreign = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                    logic: runtime, expectedProject: nil, requiresProjectReference: false))
                f.builder.setAttribute(f.window, kAXDocumentAttribute as String, held.document)
                source = .init(pair: source.pair, index: source.index, original: source.original,
                    originalTrack: source.originalTrack, observation: foreign, observedPairs: source.observedPairs)
            }
            if fault == "missing_strip" { f.builder.setChildren(f.mixer, Array(f.strips.dropLast())) }
            if fault == "mixer_role" { f.builder.setRole(f.mixer, kAXButtonRole as String) }
            f.heldHeaderDiscoveryScans = 0
            f.coupledGuardPopulationScans = 0
            f.routingRead = { element, attribute in
                if CFEqual(element, f.window), attribute == kAXRoleAttribute as String,
                   f.activeBulkAttributes == [kAXRoleAttribute, kAXIdentifierAttribute, kAXChildrenAttribute] as [String] {
                    f.heldHeaderDiscoveryScans += 1
                }
            }
            let permitted = source.permits(runtime: runtime)
            if fault == "owned" {
                #expect(permitted)
                #expect(f.heldHeaderDiscoveryScans == 0, "The actual source consumer must use its retained native scope")
                #expect(f.coupledGuardPopulationScans == 0, "An admitted original Mixer must use fresh bound census, not another whole-window discovery")
            } else { #expect(!permitted) }
            if fault == "foreign_scope" {
                #expect(originalSource.permits(runtime: runtime), "A foreign proof cannot retire the valid original source")
            }
            if fault == "missing_strip" {
                f.builder.setChildren(f.mixer, f.strips)
                #expect(!source.permits(runtime: runtime), "An observed missing Mixer peer ends this scope even if it returns")
            }
            if fault == "mixer_role" {
                f.builder.setRole(f.mixer, originalMixerRole)
                #expect(!source.permits(runtime: runtime), "A positively observed foreign Mixer role cannot revive this read scope")
            }
        }
    }

    @Test("Association publication uses fresh original census rows and refuses late native scope loss",
          arguments: ["owned", "late_peer", "late_rail_role"])
    func associationPublicationKeepsItsActualNativeCensus(fault: String) async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        f.useBulkReads = true
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        try await OperationTraceContext.$current.withValue(context) {
            let runtime = f.logic()
            let held = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: runtime, expectedProject: nil, requiresProjectReference: false))
            f.routingRead = { element, attribute in
                if CFEqual(element, f.window), attribute == kAXRoleAttribute as String,
                   f.activeBulkAttributes == [kAXRoleAttribute, kAXIdentifierAttribute, kAXChildrenAttribute] as [String] {
                    f.heldHeaderDiscoveryScans += 1
                }
            }
            f.routingChildrenRead = { element in
                if fault != "owned", !f.routingLateScopeInjected, f.selections.count >= 4,
                   f.selections.last == held.originalIndex, CFEqual(element, f.headers[2]) {
                    f.routingLateScopeInjected = true
                    if fault == "late_peer" { f.builder.setChildren(f.rail, Array(f.headers.dropLast())) }
                    else { f.builder.setRole(f.rail, kAXButtonRole as String) }
                }
            }
            let pairs = await held.observe(referenceIsCurrent: { true }, stoppingWhen: { false }, allHeldHeaders: true)
            if fault == "owned" {
                #expect(pairs.count == 4 && held.effects.restoration == "restored")
                #expect(held.headers.count == 4 && held.strips.count == 4)
                #expect(f.heldHeaderDiscoveryScans == 0, "Use the producer's actual final strict census, not a new global population for each binding")
            } else {
                #expect(f.routingLateScopeInjected, "Inject the native change after the actual selection inverse")
                #expect(pairs.isEmpty, "Late native scope loss must withhold the whole association result")
            }
        }
    }

    @Test("Original-header collection renews its reference through the same qualified rail")
    func originalHeaderCollectionUsesItsActualReferenceScope() async throws {
        let f = try Fixture(withViewport: true, fourTracks: true)
        f.useBulkReads = true
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        try await OperationTraceContext.$current.withValue(context) {
            let runtime = f.logic()
            let initial = try #require(AccessibilityChannel.HeldSelectionAssociation(window: f.window,
                logic: runtime, expectedProject: nil, requiresProjectReference: false))
            let pairs = await initial.observe(referenceIsCurrent: { true }, stoppingWhen: { false }, allHeldHeaders: true)
            let pair = try #require(pairs.first { CFEqual($0.track.header, f.headers[initial.originalIndex]) })
            f.routingRead = { element, attribute in
                if f.heldHeaderDiscoveryActive, CFEqual(element, f.window), attribute == kAXRoleAttribute as String,
                   f.activeBulkAttributes == [kAXRoleAttribute, kAXIdentifierAttribute, kAXChildrenAttribute] as [String] {
                    f.heldHeaderDiscoveryScans += 1
                }
            }
            let observed = await AccessibilityChannel.renewSourceThroughOriginalHeader(pair, original: pair.strip,
                runtime: runtime, sourceDisposition: .readObservation,
                observingReadFocus: { _ in f.heldHeaderDiscoveryActive = true })
            let source = try #require(observed.source)
            #expect(f.heldHeaderDiscoveryActive && observed.effects.restoration == "restored")
            #expect(source.originalTrack.matches(pair.track) && source.observation.headers.count == 4)
            #expect(f.heldHeaderDiscoveryScans == 0, "After admission, reference checks and binding publication must renew the original native rail")
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

    @Test("Selection scope restores its original passive focus without using the inverse as pair evidence",
          arguments: ["aligned", "moving", "unsettable", "ack_only", "unreported", "moving_unreported", "late_document", "late_focus", "late_child"])
    func selectionInspectionRestoresItsOriginalPassiveFocus(profile: String) async throws {
        let f = try Fixture(fourTracks: profile == "moving_unreported")
        let originalFocus = f.strips[1]
        let moving = profile != "aligned" && profile != "unreported"
        let unreported = profile == "unreported" || profile == "moving_unreported"
        if !unreported {
            f.builder.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String,
                [moving ? f.strips[0] : originalFocus])
        }
        if moving {
            f.builder.setAttributeSettable(originalFocus, kAXFocusedAttribute as String, profile != "unsettable")
            f.focusRestorationAckOnly = profile == "ack_only"
            f.routingRead = { element, attribute in
                if CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String,
                   f.focusRestorationWrites.isEmpty, !f.cleanupScopeInjected,
                   let selected = f.selections.last {
                    f.builder.setAttribute(f.app, attribute,
                        f.strips[profile == "moving_unreported" && selected == 1 ? 2 : selected])
                }
                if profile.hasPrefix("late_"), !f.cleanupScopeInjected, f.selections == [1, 0],
                   CFEqual(element, originalFocus), attribute == kAXNumberOfCharactersAttribute as String {
                    f.cleanupScopeInjected = true
                    if profile == "late_document" {
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    } else if profile == "late_focus" {
                        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.builder.element(1_965_999))
                    } else {
                        f.builder.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.strips[1]])
                    }
                }
            }
        }
        f.routingSelection = { index in
            guard !unreported else { return }
            let selected = moving ? f.strips[index] : f.strips[1 - index]
            f.builder.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [selected])
        }
        let body = try await inspect(f, scope: "selection")
        let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
        let effects = try #require(body["ui_effects"] as? [String: Any])
        #expect(f.selections == [1, 0])
        #expect(f.scrollWrites.isEmpty)
        if ["aligned", "moving", "unreported", "moving_unreported"].contains(profile) {
            if profile == "moving_unreported" {
                #expect(rows.isEmpty, "Restoring strip1 focus cannot prove header0 belongs to strip1")
            } else { #expect(rows.count == 1 && rows.first?["track_index"] as? Int == 0) }
            #expect(effects["restoration"] as? String == "restored")
            let finalFocus: AXUIElement = try #require(AXHelpers.getAttribute(f.app,
                kAXFocusedUIElementAttribute as String, runtime: f.builder.makeAXRuntime()))
            #expect(CFEqual(finalFocus, originalFocus))
            #expect(f.focusRestorationWrites.count == (moving ? 1 : 0))
            if moving && !unreported {
                let strips = try #require((body["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
                #expect(rows.first?["mixer_strip_ref"] as? String == strips[0]["mixer_strip_ref"] as? String,
                    "The actual selected child, not the inverse focus, identifies the selected header")
            }
        } else {
            #expect(rows.isEmpty)
            #expect(effects["restoration"] as? String != "restored")
            #expect(f.focusRestorationWrites.count == (profile == "ack_only" ? 1 : 0))
            if profile.hasPrefix("late_") { #expect(f.cleanupScopeInjected, "Reach the actual deciding inverse reads") }
        }
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
