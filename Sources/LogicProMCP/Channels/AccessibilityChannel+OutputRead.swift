@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    /// A passive Arrange name is not an editable field despite its AXTextField
    /// role. This retained witness grants only this reader's semantic popup
    /// press, never a keyboard command, selection change, or parameter write.
    private struct PassiveRoutingReadFocus {
        let pid: pid_t
        let app: AXUIElement
        let window: AXUIElement
        let document: String
        let rail: AXUIElement
        let header: AXUIElement
        let focus: AXUIElement

        init?(window: AXUIElement, document: String, runtime: AXLogicProElements.Runtime) {
            guard let pid = runtime.logicProPID(), let app = AXLogicProElements.appRoot(runtime: runtime),
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  let header: AXUIElement = AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: runtime.ax),
                  let rail = AXLogicProElements.uniqueTrackHeaderRail(in: window, runtime: runtime) else { return nil }
            self.pid = pid; self.app = app; self.window = window; self.document = document
            self.rail = rail; self.header = header; self.focus = focus
            guard permits(runtime: runtime) else { return nil }
        }

        func permits(runtime: AXLogicProElements.Runtime) -> Bool {
            guard !Task.isCancelled, runtime.logicProPID() == pid, runtime.focusedApplicationPID() == pid,
                  let currentApp = AXLogicProElements.appRoot(runtime: runtime), CFEqual(currentApp, app),
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true,
                  let currentFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  CFEqual(currentFocus, focus),
                  let currentRail = AXLogicProElements.uniqueTrackHeaderRail(in: window, runtime: runtime), CFEqual(currentRail, rail),
                  case .success(let rows) = AXHelpers.childrenResult(rail, runtime: runtime.ax),
                  rows.filter({ CFEqual($0, header) }).count == 1,
                  AXHelpers.getRole(header, runtime: runtime.ax) == kAXLayoutItemRole as String,
                  case .success(let children) = AXHelpers.childrenResult(header, runtime: runtime.ax),
                  children.filter({ CFEqual($0, focus) }).count == 1,
                  AXHelpers.getRole(focus, runtime: runtime.ax) == kAXTextFieldRole as String,
                  let parent: AXUIElement = AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: runtime.ax),
                  CFEqual(parent, header),
                  let owner: AXUIElement = AXHelpers.getAttribute(focus, kAXWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(owner, window),
                  AXHelpers.isAttributeSettable(focus, kAXValueAttribute as String, runtime: runtime.ax) == false,
                  case .success(.some(let raw)) = AXHelpers.getAttributeResult(focus, kAXValueAttribute as String,
                    runtime: runtime.ax) as Result<AnyObject?, AXHelpers.AXStatusError>,
                  CFGetTypeID(raw) == CFNumberGetTypeID(), let value = raw as? NSNumber, value.doubleValue == 0 else { return false }
            for attribute in [kAXInsertionPointLineNumberAttribute, kAXSelectedTextRangeAttribute,
                              kAXSelectedTextAttribute, kAXNumberOfCharactersAttribute] {
                switch AXHelpers.getAttributeResult(focus, attribute as String, runtime: runtime.ax)
                    as Result<AnyObject?, AXHelpers.AXStatusError> {
                case .success(nil): break
                case .failure(let error) where error.isDefinitiveAbsence: break
                default: return false
                }
            }
            guard let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: runtime.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(main, window), CFEqual(focusedWindow, window),
                  case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
                  currentDocument.utf8.elementsEqual(document.utf8), runtime.logicProPID() == pid,
                  let finalFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  CFEqual(finalFocus, focus) else { return false }
            return true
        }
    }
    /// Internal bus-only input acquisition; no public operation or graph-edge qualification.
    static func getInputBusVerified(
        runtime: AXLogicProElements.Runtime = .production,
        timing: OutputAssignmentTiming = .live
    ) async -> ChannelResult {
        (await getCheckedRoutingDestination(params: [:], sendOrdinal: nil, inputBusOnly: true, runtime: runtime, timing: timing)).result
    }
    /// A checked assigned-send choice, not a routing-graph completeness claim.
    static func getAssignedSendVerified(
        ordinal: Int, runtime: AXLogicProElements.Runtime = .production,
        timing: OutputAssignmentTiming = .live
    ) async -> ChannelResult {
        (await getCheckedRoutingDestination(params: [:], sendOrdinal: ordinal, runtime: runtime, timing: timing)).result
    }
    /// Read-only output-popup acquisition on a retained physical source. No routing leaf is
    /// pressed, and a successful observation does not claim focus/viewport restoration.
    static func getOutputVerified(
        params: [String: String], runtime: AXLogicProElements.Runtime = .production,
        timing: OutputAssignmentTiming = .live
    ) async -> ChannelResult {
        (await getCheckedRoutingDestination(params: params, sendOrdinal: nil, runtime: runtime, timing: timing)).result
    }

    struct CheckedOutputReading: Sendable {
        let result: ChannelResult
        let assignment: OutputAssignment?
    }

    /// Shares the exact owned reader; wire receipt decoding never supplies graph identity.
    static func getOutputObservation(runtime: AXLogicProElements.Runtime,
                                     timing: OutputAssignmentTiming = .live) async -> CheckedOutputReading {
        await getCheckedRoutingDestination(params: [:], sendOrdinal: nil, runtime: runtime, timing: timing)
    }

    private static func getCheckedRoutingDestination(
        params: [String: String], sendOrdinal: Int?, inputBusOnly: Bool = false, runtime: AXLogicProElements.Runtime,
        timing: OutputAssignmentTiming
    ) async -> CheckedOutputReading {
        let operation = inputBusOnly ? "mixer.get_input_bus_verified" : (sendOrdinal == nil ? "mixer.get_output_verified" : "mixer.get_send_destination_verified")
        var extras: [String: Any] = ["operation": operation, "write_attempted": false,
                                   "navigation_attempted": false, "popup_menu_state": "not_opened"]
        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> CheckedOutputReading {
            .init(result: .error(HonestContract.encodeStateC(error: error, hint: hint, extras: extras)), assignment: nil)
        }
        guard params.isEmpty, sendOrdinal.map({ $0 >= 0 }) != false, let physical = AXMixerStripBinding.current else {
            return refuse(.invalidParams, "A current physical Mixer target_ref is required; no write inputs or indices are accepted.")
        }
        guard physical.currentIndex(runtime: runtime) != nil else {
            return refuse(.staleTargetReference, "The original physical source is no longer in its bound project/window.")
        }
        let passiveFocus = readLogicKeyboardFocus(runtime: runtime) == .notTextEditing ? nil
            : PassiveRoutingReadFocus(window: physical.window, document: physical.document, runtime: runtime)
        let passiveMixerFocus = readLogicKeyboardFocus(runtime: runtime) == .notTextEditing ? nil
            : OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveMixerReadFocus(
                window: physical.window, logic: runtime, acquisitionPermitted: { !Task.isCancelled })
        func focusAllowsAcquisition() -> Bool {
            if let passiveFocus { return passiveFocus.permits(runtime: runtime) }
            if let passiveMixerFocus { return passiveMixerFocus.permits() }
            return readLogicKeyboardFocus(runtime: runtime) == .notTextEditing
        }
        guard focusAllowsAcquisition(),
              !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked else {
            return refuse(.readbackUnavailable, "Cannot acquire an output menu while focus or modal state is unsafe or unreadable.")
        }
        guard let playing = AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportPlayControl, runtime: runtime),
              let recording = AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportRecordControl, runtime: runtime) else {
            return refuse(.transportStateUnknown, "Play and Record must read before menu acquisition.")
        }
        guard !playing, !recording else { return refuse(.unsupportedState, "Output-menu acquisition requires stopped transport.") }
        func assignedControl() -> AXLogicProElements.AssignedSendMenuControl? {
            guard let sendOrdinal else { return nil }
            var controls: [AXLogicProElements.AssignedSendMenuControl] = []
            guard let slots = AXLogicProElements.sendSlotObservations(in: physical.strip, runtime: runtime.ax,
                observingAssignedGroup: { controls.append($0) }), slots.indices.contains(sendOrdinal),
                  slots[sendOrdinal].state == .occupiedUnknownDestination else { return nil }
            let matches = controls.filter { $0.ordinal == sendOrdinal }
            guard matches.count == 1, let selected = matches.first,
                  controls.filter({ CFEqual($0.list, selected.list) }).count == 1 else { return nil }
            return selected
        }
        let assigned = assignedControl()
        guard sendOrdinal == nil || assigned != nil else {
            return refuse(.readbackUnavailable, "The requested ordinal has no uniquely qualified assigned-send list control; nothing was pressed.")
        }
        func selectedControl() -> AXUIElement? {
            if inputBusOnly {
                let read = AXLogicProElements.inputSlotRead(in: physical.strip, runtime: runtime.ax)
                guard case .source = read.reading else { return nil }
                return read.control
            }
            if let assigned {
                guard let current = assignedControl(), assigned.matches(current),
                      AXHelpers.getRole(current.group, runtime: runtime.ax) == kAXGroupRole as String,
                      AXHelpers.getRole(current.bypass, runtime: runtime.ax) == kAXCheckBoxRole as String,
                      AXHelpers.getRole(current.list, runtime: runtime.ax) == kAXButtonRole as String else { return nil }
                return current.list
            }
            return AXLogicProElements.outputSlotButton(in: physical.strip, runtime: runtime.ax)
        }
        guard let pid = runtime.logicProPID(), let windows = runtime.onScreenWindowList(),
              LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0,
              let beforeMenus = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax), beforeMenus.isEmpty,
              let slot = selectedControl(),
              case .success(.some(let originalLabel)) = AXHelpers.getAttributeResult(slot, kAXDescriptionAttribute as String, runtime: runtime.ax) as Result<String?, AXHelpers.AXStatusError> else {
            return refuse(.readbackUnavailable, "A unique output slot and absence of existing popups must be observed; nothing was pressed.")
        }
        // Deciding reads may themselves observe a host transition. Recheck the
        // held physical membership, then the exact current main window/document
        // after those reads. AX still offers no atomic compare-and-act primitive.
        func ownerBoundaryStillCurrent() -> Bool {
            guard !Task.isCancelled, runtime.logicProPID() == pid,
                  physical.currentIndex(runtime: runtime) != nil,
                  case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                  CFEqual(window, physical.window),
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(
                    physical.window, runtime: runtime),
                  document.utf8.elementsEqual(physical.document.utf8) else { return false }
            return true
        }
        func sourceOwned() -> Bool {
            guard !Task.isCancelled, runtime.logicProPID() == pid,
                  physical.currentIndex(runtime: runtime) != nil,
                  let current = selectedControl(),
                  CFEqual(current, slot),
                  case .success(.some(let label)) = AXHelpers.getAttributeResult(slot, kAXDescriptionAttribute as String, runtime: runtime.ax) as Result<String?, AXHelpers.AXStatusError>,
                  label.utf8.elementsEqual(originalLabel.utf8),
                  AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportPlayControl, runtime: runtime) == false,
                  AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportRecordControl, runtime: runtime) == false,
                  !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked else { return false }
            return ownerBoundaryStillCurrent()
        }
        let app = AXLogicProElements.appRoot(runtime: runtime)
        let originalFocus: AXUIElement? = app.flatMap { AXHelpers.getAttribute($0, kAXFocusedUIElementAttribute as String, runtime: runtime.ax) }
        guard sourceOwned() else { return refuse(.staleTargetReference, "Source custody changed before acquisition; nothing was pressed.") }
        if sendOrdinal != nil || inputBusOnly {
            guard case .success(let actions) = AXHelpers.getActionNamesResult(slot, runtime: runtime.ax),
                  actions.contains(kAXPressAction as String), sourceOwned() else {
                return refuse(.readbackUnavailable, "The held routing control does not advertise a current press capability; nothing was pressed.")
            }
            extras["send_ordinal"] = sendOrdinal
        }
        // The last focus read can itself observe a project transition. Renew
        // original source/document custody afterward, before any menu action.
        guard focusAllowsAcquisition(), sourceOwned(), focusAllowsAcquisition(), sourceOwned() else {
            return refuse(.readbackUnavailable, "Focus or source custody changed before the routing-popup press; nothing was pressed.")
        }
        extras["navigation_attempted"] = true
        let press = AXHelpers.performActionResult(slot, kAXPressAction as String, runtime: runtime.ax)
        if case .success = press { extras["popup_press_succeeded"] = true }
        else { extras["popup_press_succeeded"] = false }
        let deadline = Date().addingTimeInterval(Double(timing.popupOpenTimeoutMs) / 1_000)
        var opened: [AXUIElement]?
        repeat {
            opened = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax)
            if opened == nil || !(opened?.isEmpty ?? true) || !sourceOwned() { break }
            if timing.pollIntervalMs > 0 { try? await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) }
        } while !Task.isCancelled && Date() < deadline
        guard let opened, opened.count == 1, let root = opened.first, sourceOwned() else {
            extras["popup_menu_state"] = opened?.isEmpty == true ? "not_observed" : "unknown"
            return refuse(.readbackUnavailable, "The press did not establish one popup owned by the unchanged source; no destination was selected and no unowned cleanup was attempted.")
        }
        func menuOwned() -> Bool {
            guard sourceOwned(), let current = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax) else { return false }
            return current.count == 1 && CFEqual(current[0], root) && ownerBoundaryStillCurrent()
        }
        // Two agreeing reads bracketed by the same source/menu, not an atomic graph snapshot.
        func checkedChoice() -> OutputAssignment? {
            if inputBusOnly { return currentInputMenuBusAssignment(in: root, runtime: runtime.ax).map(OutputAssignment.bus) }
            return currentOutputMenuAssignment(in: root, runtime: runtime.ax)
        }
        let first = checkedChoice()
        let second = menuOwned() ? checkedChoice() : nil
        let dataOwned = menuOwned()
        var cancelSucceeded = false
        if dataOwned, runtime.ax.actionNames(root).contains(kAXCancelAction as String), menuOwned() {
            if case .success = AXHelpers.performActionResult(root, kAXCancelAction as String, runtime: runtime.ax) { cancelSucceeded = true }
        }
        let closed = sourceOwned() && checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax)?.isEmpty == true
            && runtime.onScreenWindowList().map { LogicOnScreenWindows.popupMenuCount($0, logicPID: pid) == 0 } == true
        extras["popup_menu_state"] = closed ? "closed" : "not_restored"
        extras["popup_cancel_succeeded"] = cancelSucceeded
        let currentFocus: AXUIElement? = app.flatMap { AXHelpers.getAttribute($0, kAXFocusedUIElementAttribute as String, runtime: runtime.ax) }
        let focusRestored = originalFocus.flatMap { old in currentFocus.map { CFEqual(old, $0) } } == true
        extras["focus_restoration"] = focusRestored ? "restored" : "not_restored"
        let sourceAfter = sourceOwned()
        extras["source_custody_after_cleanup"] = sourceAfter
        extras["menu_custody_at_read"] = dataOwned
        extras["output_checkmark_reads_observed"] = (first == nil ? 0 : 1) + (second == nil ? 0 : 1)
        extras["output_checkmark_reads_agree"] = first != nil && second == first
        // Logic can report a failed AXPress after actually opening this popup. The
        // acknowledgement is a receipt, not read authority: require the newly
        // observed, unchanged source/menu and two agreeing checked choices instead.
        guard dataOwned, sourceAfter, let first, second == first else {
            return refuse(.readbackUnavailable, "The checked output was unreadable, contradictory, or lost its original source/menu custody; no destination was selected.")
        }
        guard sendOrdinal == nil || first != .noOutput else {
            return refuse(.readbackUnavailable, "An output-only No Output marker is not an assigned-send destination.")
        }
        extras[inputBusOnly ? "current_input" : (sendOrdinal == nil ? "current_output" : "current_destination")] = first.json
        extras["verify_source"] = inputBusOnly ? "ax_input_menu_checkmark" : (sendOrdinal == nil ? "ax_output_menu_checkmark" : "ax_send_menu_checkmark")
        if inputBusOnly { extras["input_scope"] = "bus_only" }
        extras["snapshot_atomic"] = false
        return .init(result: .success(HonestContract.encodeStateA(extras: extras)), assignment: first)
    }

    static func outputReadContextFailure(_ result: ChannelResult, operation: String) -> ChannelResult {
        var extras: [String: Any] = ["operation": operation, "write_attempted": false]
        let receiptKeys: Set<String> = ["navigation_attempted", "popup_menu_state", "popup_cancel_succeeded",
            "focus_restoration", "popup_press_succeeded", "source_custody_after_cleanup",
            "menu_custody_at_read", "output_checkmark_reads_observed", "output_checkmark_reads_agree", "send_ordinal"]
        if let data = result.message.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object where receiptKeys.contains(key) { extras[key] = value }
        }
        return .error(HonestContract.encodeStateC(error: .staleTargetReference,
            hint: "The original target/project context ended; the output is withheld and known UI effects are preserved.", extras: extras))
    }

    private static func checkedOutputPopupMenus(in mixer: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement]? {
        guard case .success(let children) = AXHelpers.childrenResult(mixer, runtime: runtime) else { return nil }
        var menus: [AXUIElement] = []
        for child in children {
            let read: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(child, kAXRoleAttribute as String, runtime: runtime)
            guard case .success(.some(let role)) = read else { return nil }
            if role == kAXMenuRole as String { menus.append(child) }
        }
        return menus
    }
}
