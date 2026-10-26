@preconcurrency import ApplicationServices
import Foundation

/// #291 R2 — `logic_mixer set_output_verified`: set one strip's output to one exact destination
/// and prove it by reading the same strip's output slot back.
///
/// Everything before the press is a refusal that leaves the project as it was: the strip must
/// resolve, its current output must read and classify, `expected_current` must match it, the
/// transport must read as stopped, a bus must already have a receiver, and the destination must be
/// offered by the popup under the submenu that owns it. The only authority for State A is the
/// after-read of the strip that was pressed, plus a strip count that did not move.
extension AccessibilityChannel {
    /// How long each wait may take. Production uses `.live`; a test that models the UI answering
    /// at once passes zeros, so a refusal that has to wait out a timeout does not sleep.
    struct OutputAssignmentTiming: Sendable {
        var popupOpenTimeoutMs = 1_500
        var popupCloseTimeoutMs = 1_000
        var readbackTimeoutMs = 2_000
        var pollIntervalMs = 80

        static let live = OutputAssignmentTiming()
        static let immediate = OutputAssignmentTiming(
            popupOpenTimeoutMs: 0, popupCloseTimeoutMs: 0, readbackTimeoutMs: 0, pollIntervalMs: 0
        )
    }

    /// Which popup entry a destination selects, or why none can be pressed.
    enum OutputMenuChoice {
        case item(AXUIElement, path: [String])
        /// The Bus or Output submenu the destination lives under is not in the root menu.
        case parentMissing(String)
        /// More than one root entry carries that submenu's title.
        case parentRepeated(String, count: Int)
        /// Nothing under the owning parent names the destination. `offered` is what did, as tokens.
        case notOffered(offered: [String])
        /// Several entries under the owning parent name the destination. Never resolved by order.
        case repeated(count: Int)
        /// The menu at `path` (the root when empty) was not read whole, so no entry in it can be
        /// shown to be the only one: an entry passed over could be the second of two.
        case menuUnread(path: [String])

        var failureLabel: String {
            switch self {
            case .item: "none"
            case .parentMissing: "submenu_not_offered"
            case .parentRepeated: "submenu_title_repeated"
            case .notOffered: "destination_not_offered"
            case .repeated: "destination_title_repeated"
            case .menuUnread: "menu_not_read"
            }
        }
    }

    static func setOutputVerified(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        timing: OutputAssignmentTiming = .live,
        popupCleaner: @escaping PluginPopupMenuCleaner = livePluginPopupMenuCleaner
    ) async -> ChannelResult {
        let operation = "mixer.set_output_verified"
        guard let requestedIndex = params["index"].flatMap({ Int($0) }), requestedIndex >= 0 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams, hint: "\(operation) requires 'index' (Int >= 0)"
            ))
        }
        let physical = AXMixerStripBinding.current
        let outputAssociation: HeldSelectionAssociation.Pair?
        if let physical, let pair = AXMixerStripBinding.outputAssociation,
           pair.strip.matches(physical), pair.track.currentIndex() != nil { outputAssociation = pair }
        else { outputAssociation = nil }
        var index = requestedIndex
        if let physical {
            guard let current = physical.currentIndex(runtime: runtime) else {
                return .error(HonestContract.encodeStateC(error: .staleTargetReference,
                    hint: "The referenced physical Mixer strip is no longer in its observed project/window.",
                    extras: ["operation": operation, "write_attempted": false]))
            }
            index = current
        }
        guard let destination = params["destination"].flatMap(OutputAssignment.init(token:)) else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams, hint: "\(operation) requires a valid 'destination'"
            ))
        }
        // The historical No Output menu-discovery failure is preserved in
        // docs/observations/2026-09-11-routing-slots-open-their-menus-and-a-destination-can-be-selected.json.
        // Legacy index selectors retain their refusal. The held-source scalar
        // Stereo Output/No Output cycle below requires explicit before-state.
        guard destination != .noOutput || physical != nil else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams, hint: "\(operation) requires a current held physical source "
                    + "for No Output; legacy selectors cannot grant recovery authority."
            ))
        }
        var expected: OutputAssignment?
        if let raw = params["expected_current"] {
            guard let parsed = OutputAssignment(token: raw) else {
                return .error(HonestContract.encodeStateC(
                    error: .invalidParams, hint: "\(operation) 'expected_current' is not a valid destination"
                ))
            }
            expected = parsed
        }

        var extras: [String: Any] = [
            "operation": operation,
            (physical == nil ? "track" : "mixer_strip_index"): index,
            "destination": destination.json,
            "write_attempted": false,
        ]
        func refusal(
            _ error: HonestContract.FailureError,
            _ hint: String,
            _ more: [String: Any] = [:]
        ) -> ChannelResult {
            if ApprovedSessionRepair.current != nil {
                Log.info("Canonical output refused: \(hint)", subsystem: "saga")
            }
            return .error(HonestContract.encodeStateC(
                error: error, hint: hint, extras: extras.merging(more) { _, new in new }
            ))
        }

        // The strip, by the same ordinal convention `insert_plugin` uses, refusing when a Mixer
        // child would not report a role: a dropped child shifts every later ordinal.
        let lookup: AXLogicProElements.MixerAreaLookup = physical.map { .found($0.mixer) }
            ?? AXLogicProElements.mixerAreaLookup(runtime: runtime)
        guard let mixer = lookup.mixer else {
            return refusal(.elementNotFound, "Cannot locate the visible Mixer. Show it so the strip's "
                + "output slot can be read; nothing was pressed.")
        }
        guard let enumeration = AXLogicProElements.stripEnumeration(in: mixer, runtime: runtime.ax) else {
            return refusal(.elementNotFound, "The Mixer's children did not read, so no strip can be "
                + "addressed. They are unknown, not absent; nothing was pressed.",
                ["mixer_children_unread": true])
        }
        guard enumeration.unreadableChildren == 0 else {
            return refusal(.elementNotFound, "\(enumeration.unreadableChildren) Mixer child(ren) would "
                + "not report a role, so the strip at index \(index) cannot be trusted to be that "
                + "track's strip; nothing was pressed.",
                ["unreadable_mixer_children": enumeration.unreadableChildren])
        }
        let strips = enumeration.strips
        extras["strip_count_before"] = strips.count
        let strip: AXUIElement
        if let physical {
            let members = strips.indices.filter { CFEqual(strips[$0], physical.strip) }
            guard members.count == 1, let observedIndex = members.first,
                  physical.currentIndex(runtime: runtime) == observedIndex else {
                return refusal(.staleTargetReference, "The referenced physical source did not remain uniquely bound before its output read; nothing was pressed.")
            }
            index = observedIndex
            extras["mixer_strip_index"] = index
            strip = physical.strip
        } else {
            guard index < strips.count else {
                return refusal(.elementNotFound, "track index out of range for the visible Mixer; nothing was pressed.")
            }
            strip = strips[index]
        }

        // The current output, read by R1's reader. Unreadable is not absent, and a label this
        // cannot classify cannot be compared with anything, so both refuse.
        guard let beforeLabel = AXLogicProElements.outputSlotDestination(in: strip, runtime: runtime.ax) else {
            return refusal(.readbackUnavailable, "The strip's current output did not read. Unreadable is "
                + "not absent, so there is nothing to compare the request with; nothing was pressed.")
        }
        if let physical, physical.currentIndex(runtime: runtime) != index {
            return refusal(.staleTargetReference, "The referenced source changed during its current output read; nothing was pressed.")
        }
        guard let before = OutputAssignment.observed(slotLabel: beforeLabel) else {
            return refusal(.readbackUnavailable, "The strip's current output reads as a label this "
                + "operation cannot classify, so it cannot be compared; nothing was pressed.",
                ["observed_label": beforeLabel])
        }
        extras["before"] = before.json
        if let expected, expected != before {
            return refusal(.staleSnapshot, "expected_current does not match the strip's observed "
                + "output; re-read it and retry. Nothing was pressed.",
                ["expected_current": expected.json])
        }
        let noOutputChange = before == .noOutput || destination == .noOutput
        if noOutputChange {
            let noncanonical = ApprovedSessionRepair.current == nil && ApprovedSessionRepair.outputLeafPermission == nil
            let canonical = outputAssociation.map { pair in
                ApprovedSessionRepair.current?.ownsCanonicalNoOutputChange(
                    before: before, destination: destination, pair: pair) == true
            } ?? false
            guard physical != nil, expected == before,
                  noncanonical || canonical,
                  (before == .noOutput && destination == .stereoOutput)
                    || (before == .stereoOutput && destination == .noOutput) else {
                return refusal(.unsupportedState, "No Output changes require the current physical source, "
                    + "explicit matching expected_current and an owned Stereo Output/No Output change; nothing was pressed.")
            }
        }
        if before == destination {
            extras["after"] = before.json
            extras["changed"] = false
            extras["verify_source"] = "ax_output_slot"
            return .success(HonestContract.encodeStateA(extras: extras))
        }

        // Stopped, as a reading. Either checkbox unread refuses: it cannot be shown stopped.
        let playing = AXLogicProElements.readControlBarCheckboxValue(
            matching: AXLocalePolicy.transportPlayControl, runtime: runtime
        )
        let recording = AXLogicProElements.readControlBarCheckboxValue(
            matching: AXLocalePolicy.transportRecordControl, runtime: runtime
        )
        guard let playing, let recording else {
            return refusal(.transportStateUnknown, "The transport's Play or Record state did not read, "
                + "so it cannot be shown stopped; nothing was pressed.",
                ["transport_play_read": playing != nil, "transport_record_read": recording != nil])
        }
        if playing || recording {
            let state = recording ? "recording" : "playing"
            return refusal(.unsupportedState, "Refusing while the transport is \(state): stop it and "
                + "retry. Nothing was pressed.", ["transport": state])
        }

        if case .bus(let number) = destination {
            switch busCheck(into: number, from: index, strips: strips, runtime: runtime.ax) {
            case .receivers(let receivers):
                extras["bus_receivers"] = receivers
            case .refused(let error, let hint, let more):
                return refusal(error, hint + "; nothing was pressed.", more)
            }
        }

        // A menu already open is somebody else's, and the cleanup below would close it too.
        guard let logicPID = runtime.logicProPID(), let windows = runtime.onScreenWindowList() else {
            return refusal(.unsupportedState, "Logic's on-screen windows did not read, so an open popup "
                + "menu cannot be ruled out; nothing was pressed.")
        }
        let openBefore = LogicOnScreenWindows.popupMenuCount(windows, logicPID: logicPID)
        guard openBefore == 0 else {
            return refusal(.unsupportedState, "A Logic popup menu is already open. Close it and retry; "
                + "nothing was pressed.", ["open_popup_menu_windows": openBefore])
        }
        guard let slotButton = AXLogicProElements.outputSlotButton(in: strip, runtime: runtime.ax) else {
            return refusal(.elementNotFound, "The strip's output slot button was not found; nothing was pressed.")
        }
        if noOutputChange {
            guard checkedOutputPopupMenus(in: mixer, runtime: runtime.ax)?.isEmpty == true,
                  case .success(let actions) = AXHelpers.getActionNamesResult(slotButton, runtime: runtime.ax),
                  actions.contains(kAXPressAction as String),
                  AXLogicProElements.outputSlotDestination(in: strip, runtime: runtime.ax) == beforeLabel,
                  physical?.currentIndex(runtime: runtime) == index else {
                return refusal(.readbackUnavailable, "No Output recovery requires the current original slot's "
                    + "press capability and no pre-existing menu; nothing was pressed.")
            }
        }

        let sourceIndex = index
        var heldPopup: AXUIElement?
        var heldNativePopup: NativeOutputReadPopup?
        @Sendable func sourceStillCurrent(root: AXUIElement, native: NativeOutputReadPopup?) -> Bool {
            guard let physical else { return true } // Preserve the explicit legacy selector path.
            guard !Task.isCancelled,
                  AXHelpers.getRole(physical.strip, runtime: runtime.ax) == kAXLayoutItemRole as String,
                  let currentSlot = AXLogicProElements.outputSlotButton(in: physical.strip, runtime: runtime.ax),
                  CFEqual(currentSlot, slotButton),
                  case .success(let sourceChildren) = AXHelpers.childrenResult(physical.strip, runtime: runtime.ax),
                  sourceChildren.filter({ CFEqual($0, slotButton) }).count == 1 else { return false }
            if let native {
                guard let app = AXLogicProElements.appRoot(runtime: runtime),
                      checkedOutputPopupMenus(in: mixer, runtime: runtime.ax)?.isEmpty == true,
                      let current = NativeOutputReadPopup.read(physical: physical, app: app, pid: logicPID, runtime: runtime),
                      current.matches(native), CFEqual(root, native.root) else { return false }
            } else {
                guard case .success(let children) = AXHelpers.childrenResult(mixer, runtime: runtime.ax),
                      children.filter({ CFEqual($0, root) }).count == 1 else { return false }
                if noOutputChange {
                    guard let menus = checkedOutputPopupMenus(in: mixer, runtime: runtime.ax),
                          menus.count == 1, CFEqual(menus[0], root),
                          let parent: AXUIElement = AXHelpers.getAttribute(root, kAXParentAttribute, runtime: runtime.ax),
                          CFEqual(parent, mixer) else { return false }
                }
            }
            if noOutputChange {
                guard let app = AXLogicProElements.appRoot(runtime: runtime), runtime.focusedApplicationPID() == logicPID,
                      AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true,
                      !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked,
                      AXLogicProElements.outputSlotDestination(in: physical.strip, runtime: runtime.ax) == beforeLabel,
                      currentOutputMenuAssignment(in: root, runtime: runtime.ax) == before,
                      AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportPlayControl, runtime: runtime) == false,
                      AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportRecordControl, runtime: runtime) == false else { return false }
            }
            guard
                  physical.currentIndex(runtime: runtime) == sourceIndex,
                  runtime.logicProPID() == logicPID,
                  case .found(let currentWindow) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                  CFEqual(currentWindow, physical.window),
                  case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(
                    physical.window, runtime: runtime),
                  currentDocument.utf8.elementsEqual(physical.document.utf8), !Task.isCancelled else { return false }
            return true
        }
        func popupSourceStillCurrent() -> Bool {
            guard let root = heldPopup else { return physical == nil }
            return sourceStillCurrent(root: root, native: heldNativePopup)
        }
        func acquiredPopupCleaner() -> PluginPopupMenuCleaner {
            guard let native = heldNativePopup else { return popupCleaner }
            return { runtime in
                guard let windows = runtime.onScreenWindowList() else { return .popupCountUnavailable }
                let count = LogicOnScreenWindows.popupMenuCount(windows, logicPID: logicPID)
                if count == 0 { return .noPopupObserved }
                guard sourceStillCurrent(root: native.root, native: native),
                      case .success(let actions) = AXHelpers.getActionNamesResult(native.root, runtime: runtime.ax),
                      actions.contains(kAXCancelAction as String),
                      sourceStillCurrent(root: native.root, native: native) else {
                    return .couldNotDismiss(initialPopupCount: count, remainingPopupCount: count)
                }
                _ = AXHelpers.performActionResult(native.root, kAXCancelAction as String, runtime: runtime.ax)
                guard let after = runtime.onScreenWindowList() else { return .popupCountUnavailable }
                let remaining = LogicOnScreenWindows.popupMenuCount(after, logicPID: logicPID)
                return remaining == 0 ? .dismissed
                    : .couldNotDismiss(initialPopupCount: count, remainingPopupCount: remaining)
            }
        }

        // Keep the actual pre-popup presentation duty. The destination can
        // retire the strip or move the omitted native Mixer bars; sampling only
        // during header renewal would adopt that changed position as original.
        // This geometry grants no replacement-source or assignment authority.
        var outputRestorationGeometry: HeldSelectionAssociation.MixerViewportGeometry?
        if let physical, outputAssociation != nil,
           let observation = HeldSelectionAssociation(window: physical.window, logic: runtime,
               expectedProject: nil, requiresProjectReference: false, allowsSelectedChildRailEntry: true,
               retainedMixerSource: physical),
           CFEqual(observation.mixer, physical.mixer),
           observation.document.utf8.elementsEqual(physical.document.utf8) {
            outputRestorationGeometry = observation.observedMixerViewportGeometry()
        }
        // Open the popup of THIS strip and find the menu it opened: a new AXMenu among the Mixer
        // layout area's children, which is where Logic parents it (measured in ko and de).
        let menusBefore = popupMenus(in: mixer, runtime: runtime.ax)
        if let physical, physical.currentIndex(runtime: runtime) != index {
            return refusal(.staleTargetReference, "The referenced source changed before its output popup opened; nothing was pressed.")
        }
        if noOutputChange, let physical {
            guard let app = AXLogicProElements.appRoot(runtime: runtime), runtime.focusedApplicationPID() == logicPID,
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true,
                  !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked,
                  AXLogicProElements.outputSlotDestination(in: physical.strip, runtime: runtime.ax) == beforeLabel,
                  physical.currentIndex(runtime: runtime) == sourceIndex,
                  case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                  CFEqual(window, physical.window),
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
                  document.utf8.elementsEqual(physical.document.utf8), !Task.isCancelled else {
                return refusal(.staleTargetReference, "The No Output source changed during final acquisition reads; nothing was pressed.")
            }
        }
        _ = AXHelpers.performAction(slotButton, kAXPressAction, runtime: runtime.ax)
        var opened = await newPopupMenus(in: mixer, excluding: menusBefore, timing: timing, runtime: runtime.ax)
        if before == .noOutput, opened.isEmpty, let physical,
           let app = AXLogicProElements.appRoot(runtime: runtime), physical.currentIndex(runtime: runtime) == index,
           let native = NativeOutputReadPopup.read(physical: physical, app: app, pid: logicPID, runtime: runtime),
           sourceStillCurrent(root: native.root, native: native) {
            heldNativePopup = native
            opened = [native.root]
        }
        guard opened.count == 1, let root = opened.first,
              before != .noOutput || heldNativePopup != nil else {
            let cleanup = await closeOutputPopup(runtime: runtime, timing: timing, waitForSelfClose: false,
                                                 cleaner: acquiredPopupCleaner(), permittingCleanup: popupSourceStillCurrent)
            return refusal(.elementNotFound, opened.isEmpty
                ? "The output slot press opened no popup menu under the Mixer; nothing was selected."
                : "The output slot press opened \(opened.count) menus under the Mixer, so which one is "
                    + "this strip's cannot be told; nothing was selected.",
                cleanup.merging(["menu_failure": opened.isEmpty ? "popup_not_opened" : "popup_ambiguous",
                                 "menus_opened": opened.count]) { _, new in new })
        }

        heldPopup = root

        let choice = outputMenuChoice(for: destination, in: root, runtime: runtime.ax)
        guard case .item(let item, let path) = choice else {
            let cleanup = await closeOutputPopup(runtime: runtime, timing: timing, waitForSelfClose: false,
                                                 cleaner: acquiredPopupCleaner(), permittingCleanup: popupSourceStillCurrent)
            var more = cleanup
            more["menu_failure"] = choice.failureLabel
            switch choice {
            case .notOffered(let offered): more["offered"] = offered
            case .repeated(let count), .parentRepeated(_, let count): more["matching_entries"] = count
            case .menuUnread(let path): more["menu_path"] = path
            default: break
            }
            let error: HonestContract.FailureError
            if case .repeated = choice { error = .ambiguousTargetName }
            else if case .parentRepeated = choice { error = .ambiguousTargetName }
            else { error = .elementNotFound }
            if case .menuUnread = choice {
                return refusal(error, "A menu on the way to this destination did not read whole, so no "
                    + "entry in it can be shown to be the only one; nothing was selected.", more)
            }
            return refusal(error, "The output popup does not offer this destination as exactly one "
                + "entry under the submenu that owns it (\(choice.failureLabel)); nothing was selected.",
                more)
        }
        guard (AXHelpers.getAttribute(item, kAXEnabledAttribute, runtime: runtime.ax) as Bool?) == true else {
            let cleanup = await closeOutputPopup(runtime: runtime, timing: timing, waitForSelfClose: false,
                                                 cleaner: acquiredPopupCleaner(), permittingCleanup: popupSourceStillCurrent)
            return refusal(.elementNotFound, "The popup entry for this destination is disabled or its "
                + "enabled state did not read; nothing was selected.",
                cleanup.merging(["menu_failure": "destination_entry_not_enabled", "menu_path": path]) { _, new in new })
        }

        // Opening the popup must not change which source owns it. Reuse one complete
        // fresh census for this binding and the bus check immediately before selection.
        // A physical replacement requires an independently renewed held-header association;
        // the explicit legacy selector retains its historical ordinal readback.
        var refused: (HonestContract.FailureError, String, [String: Any])?
        let fresh = AXLogicProElements.stripEnumeration(in: mixer, runtime: runtime.ax)
        if let physical, physical.currentIndex(runtime: runtime) != index {
            refused = (.staleTargetReference, "The referenced source project/window/membership changed while the popup was open", [:])
        } else if let fresh, fresh.unreadableChildren == 0, fresh.strips.count == strips.count {
            if CFEqual(fresh.strips[index], strip),
               let currentSlot = AXLogicProElements.outputSlotButton(in: fresh.strips[index], runtime: runtime.ax),
               CFEqual(currentSlot, slotButton) {
                if case .bus(let number) = destination {
                    switch busCheck(into: number, from: index, strips: fresh.strips, runtime: runtime.ax) {
                    case .receivers(let receivers): extras["bus_receivers_at_press"] = receivers
                    case .refused(let error, let hint, let more): refused = (error, hint, more)
                    }
                }
            } else {
                refused = (.unsupportedState, "The source strip or its output slot changed while the popup was open", [:])
            }
        } else {
            refused = (.unsupportedState, "The Mixer's strips did not read whole, or their count moved",
                       ["strip_count_at_press": fresh?.strips.count ?? NSNull(),
                        "unreadable_mixer_children": fresh?.unreadableChildren ?? NSNull()])
        }
        if let (error, hint, more) = refused {
            let cleanup = await closeOutputPopup(runtime: runtime, timing: timing, waitForSelfClose: false,
                                                 cleaner: acquiredPopupCleaner(), permittingCleanup: popupSourceStillCurrent)
            return refusal(error, hint + ", read again with the popup open; nothing was selected.",
                cleanup.merging(more.merging(["read_with_popup_open": true]) { _, new in new }) { _, new in new })
        }

        if let permission = ApprovedSessionRepair.outputLeafPermission, !permission(root) {
            let cleanup = await closeOutputPopup(runtime: runtime, timing: timing, waitForSelfClose: false,
                                                 cleaner: acquiredPopupCleaner(), permittingCleanup: popupSourceStillCurrent)
            return refusal(.staleTargetReference,
                "The approved output's retained footprint changed; nothing was selected.", cleanup)
        }

        if noOutputChange {
            guard case .item(let currentItem, let currentPath) = outputMenuChoice(for: destination, in: root, runtime: runtime.ax),
                  CFEqual(currentItem, item), currentPath == path,
                  AXHelpers.getAttribute(currentItem, kAXEnabledAttribute, runtime: runtime.ax) as Bool? == true else {
                let cleanup = await closeOutputPopup(runtime: runtime, timing: timing, waitForSelfClose: false,
                                                     cleaner: acquiredPopupCleaner(), permittingCleanup: popupSourceStillCurrent)
                return refusal(.staleTargetReference,
                    "The original No Output destination entry changed during final acquisition reads; nothing was selected.", cleanup)
            }
        }

        if physical != nil {
            // Source-slot and bus deciding reads can coincide with a project
            // transition after currentIndex's earlier Document sample. Renew
            // the original source/control/menu, then read the main Document
            // last, with no further AX read before the destination action.
            guard popupSourceStillCurrent() else {
                // Lost scope also revokes popup cleanup authority. A generic
                // Cancel/Escape could affect the newly active project.
                return refusal(.staleTargetReference,
                    "Original source/project custody changed during the final popup reads; no destination was selected.",
                    ["popup_menu_state": "custody_lost",
                     "recovery_hint": "Re-read the current project and Mixer before retrying; popup cleanup was not authorized."])
            }
        }

        extras["write_attempted"] = true
        extras["menu_path"] = path
        _ = AXHelpers.performAction(item, kAXPressAction, runtime: runtime.ax)
        let closed = await closeOutputPopup(runtime: runtime, timing: timing, waitForSelfClose: true,
                                            cleaner: acquiredPopupCleaner(), permittingCleanup: popupSourceStillCurrent)
        extras.merge(closed) { _, new in new }

        // The committed output, by R1's reader, from the strip at the SAME ordinal, found again on
        // every poll the way the before-read found it. Logic replaces a strip's elements when its
        // output changes (measured ko, 2026-09-28: the held slot and its strip answer -25202 from
        // about 0.6 s after the press, while a fresh lookup reads the new output), so the element
        // read before the press cannot be read after it. The ordinal names the same strip only
        // while every Mixer child reads and the strip count has not moved; when it moved, nothing
        // is read from it. The request and the menu entry are never the evidence.
        var afterLabel: String?
        var after: OutputAssignment?
        var countAfter: Int?
        var attemptedAssociation = false
        let deadline = Date().addingTimeInterval(Double(timing.readbackTimeoutMs) / 1000.0)
        repeat {
            let enumeration = (physical?.mixer ?? AXLogicProElements.getMixerArea(runtime: runtime))
                .flatMap { AXLogicProElements.stripEnumeration(in: $0, runtime: runtime.ax) }
                .flatMap { $0.unreadableChildren == 0 ? $0 : nil }
            countAfter = enumeration?.strips.count
            afterLabel = nil
            if let enumeration, enumeration.strips.count == strips.count,
               physical == nil || physical?.currentIndex(runtime: runtime) == index {
                if let physical {
                    if CFEqual(enumeration.strips[index], physical.strip) {
                        afterLabel = AXLogicProElements.outputSlotDestination(in: physical.strip, runtime: runtime.ax)
                        if physical.currentIndex(runtime: runtime) != index { afterLabel = nil }
                    }
                } else {
                    afterLabel = AXLogicProElements.outputSlotDestination(in: enumeration.strips[index], runtime: runtime.ax)
                }
            }
            after = afterLabel.flatMap(OutputAssignment.observed(slotLabel:))
            if !attemptedAssociation, let physical, let outputAssociation,
               enumeration?.strips.count == strips.count {
                let currentIndex = physical.currentIndex(runtime: runtime)
                let retired = afterLabel == nil && currentIndex == nil
                // A No Output transition can commit while the exact surviving
                // slot retains its old AX label. Re-observe only that original
                // source through its retained header, never retry the setter.
                let surviving = noOutputChange && after != destination && currentIndex == index
                if retired || surviving {
                    attemptedAssociation = true
                    let observed = await readOutputThroughOriginalHeader(outputAssociation, original: physical, runtime: runtime,
                        sourceDisposition: retired ? .retiredOriginal : .survivingOriginal,
                        restoringMixerGeometry: outputRestorationGeometry)
                    extras["ui_effects"] = ["navigation_performed": observed.effects.navigationPerformed,
                        "attempted": observed.effects.attempted, "changed": observed.effects.changed,
                        "restoration": observed.effects.restoration, "reason": observed.effects.reason as Any? ?? NSNull()]
                    if let label = observed.label, let renewedIndex = observed.index {
                        afterLabel = label
                        after = OutputAssignment.observed(slotLabel: label)
                        extras["source_renewal"] = observed.source
                        extras["reference_reread_required"] = true
                        extras["source_index_after"] = renewedIndex
                    }
                }
            }
            if after == destination { break }
            if timing.pollIntervalMs > 0 { try? await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) }
        } while Date() < deadline
        extras["after"] = after?.json ?? NSNull()
        extras["verify_source"] = "ax_output_slot"
        extras["changed"] = after.map { $0 != before } ?? NSNull()
        extras["strip_count_after"] = countAfter ?? NSNull()

        if let countAfter, countAfter != strips.count {
            let sideEffect = countAfter > strips.count ? "strip_created" : "strip_removed"
            return refusal(.unexpectedSideEffect, "The output was pressed and the Mixer's strip count "
                + "moved from \(strips.count) to \(countAfter), so strip \(index) may no longer be "
                + "this track and its output was not read back. Nothing was cleaned up: removing a "
                + "strip is #967's job. Re-read the Mixer before any dependent write.",
                ["unexpected_side_effect": sideEffect, "write_attempted": true])
        }
        guard afterLabel != nil else {
            extras["hint"] = "The output was pressed and the strip's output did not read back (the "
                + "Mixer's strips or the strip's output slot did not read). The assignment is "
                + "unverified; stop dependent writes and re-read the strip."
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        }
        guard after == destination else {
            extras["observed_label"] = afterLabel ?? NSNull()
            extras["hint"] = "The output was pressed and the strip reads back something other than the "
                + "destination. Stop dependent writes and re-read the strip."
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras))
        }
        return .success(HonestContract.encodeStateA(extras: extras))
    }

    /// One post-press observation under the existing operation's gate/deadline.
    /// Never rebind the retired reference or infer a replacement from its name,
    /// ordinal, destination or unchanged population count.
    private static func readOutputThroughOriginalHeader(
        _ originalPair: HeldSelectionAssociation.Pair, original: AXMixerStripBinding.Binding,
        runtime: AXLogicProElements.Runtime,
        sourceDisposition: OriginalHeaderSourceDisposition = .retiredOriginal,
        restoringMixerGeometry: HeldSelectionAssociation.MixerViewportGeometry? = nil
    ) async -> (label: String?, index: Int?, source: String?, effects: SessionPopulationObservation.UIEffects) {
        let observed = await renewSourceThroughOriginalHeader(originalPair, original: original, runtime: runtime,
            sourceDisposition: sourceDisposition, restoringMixerGeometry: restoringMixerGeometry)
        guard let source = observed.source,
              let label = AXLogicProElements.outputSlotDestination(in: source.pair.strip.strip, runtime: runtime.ax),
              source.permits(runtime: runtime) else { return (nil, nil, nil, observed.effects) }
        return (label, source.index, source.pair.source, observed.effects)
    }

    struct OriginalHeaderSourceRenewal: Sendable {
        let pair: HeldSelectionAssociation.Pair
        let index: Int
        let original: AXMixerStripBinding.Binding
        let originalTrack: AXTrackBinding.Binding
        let observation: HeldSelectionAssociation
        /// The actual partial header/strip pairs observed by this owned read.
        /// Empty in older/manual witnesses; never inferred from labels or rows.
        var observedPairs: [HeldSelectionAssociation.Pair] = []

        func sourceForOriginalHeader(_ prior: HeldSelectionAssociation.Pair,
            runtime: AXLogicProElements.Runtime) -> Self? {
            guard permits(runtime: runtime), observation.effects.restoration == "restored",
                  prior.track.currentIndex(in: observation) != nil, CFEqual(prior.strip.window, original.window),
                  CFEqual(prior.strip.mixer, pair.strip.mixer),
                  prior.strip.document.utf8.elementsEqual(observation.document.utf8),
                  observation.headers.filter({ CFEqual($0, prior.track.header) }).count == 1 else { return nil }
            let candidates = observedPairs.filter { $0.track.matches(prior.track) }
            guard candidates.count == 1, let current = candidates.first,
                  observedPairs.filter({ $0.strip.matches(current.strip) }).count == 1,
                  observation.strips.filter({ CFEqual($0, current.strip.strip) }).count == 1,
                  let index = current.strip.currentIndex(in: observation), permits(runtime: runtime) else { return nil }
            return .init(pair: current, index: index, original: prior.strip, originalTrack: prior.track,
                observation: observation, observedPairs: observedPairs)
        }

        /// A retired original focus can be restored only through its actual selected header.
        func restoresOriginalFocus(of prior: HeldSelectionAssociation, source: AXMixerStripBinding.Binding,
            runtime: AXLogicProElements.Runtime) -> Bool {
            original.matches(source)
                && CFEqual(prior.originalFocus, source.strip)
                && CFEqual(prior.headers[prior.originalIndex], pair.track.header)
                && CFEqual(observation.originalFocus, pair.strip.strip)
                && CFEqual(observation.headers[observation.originalIndex], pair.track.header)
                && permits(runtime: runtime)
        }

        /// Renew after the caller's deciding slot read; the pair itself is not permission.
        func permits(runtime: AXLogicProElements.Runtime, ownedPopup: AXUIElement? = nil,
                     nativeOutputPopup: Bool = false) -> Bool {
            let usesOriginalHeaderScope = ownedPopup == nil || !nativeOutputPopup
            let sourceMatches: Bool
            if usesOriginalHeaderScope {
                // Both actual original-header bookends authenticate this complete
                // current Mixer census. Held CF/index metadata alone is not permission.
                sourceMatches = CFEqual(pair.strip.window, observation.window)
                    && CFEqual(pair.strip.mixer, observation.mixer)
                    && pair.strip.document.utf8.elementsEqual(observation.document.utf8)
                    && observation.strips.indices.contains(index)
                    && CFEqual(observation.strips[index], pair.strip.strip)
                    && observation.strips.filter({ CFEqual($0, pair.strip.strip) }).count == 1
                    && observation.originalMixerRoleStillHeld()
            } else {
                sourceMatches = pair.strip.currentIndex(runtime: runtime) == index
            }
            guard sourceMatches else { return false }
            func originalWindowCurrent() -> Bool {
                guard case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                      CFEqual(window, original.window),
                      case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(original.window, runtime: runtime),
                      document.utf8.elementsEqual(original.document.utf8) else { return false }
                return true
            }
            if usesOriginalHeaderScope {
                // All deciding native window reads precede final focus/popup custody.
                guard originalWindowCurrent() else { originalTrack.exposure?.end(); return false }
                if let ownedPopup {
                    guard originalTrack.currentIndex(in: observation, ownedPopup: ownedPopup) != nil,
                          observation.permitsOwnedPopupRead(ownedPopup) else { return false }
                } else {
                    guard originalTrack.currentIndex(in: observation, requiringPassiveRead: true) != nil else { return false }
                }
            } else {
                // The separately qualified native neutral-popup path retains its
                // original global identity reads and native source exception.
                guard originalTrack.currentIndex() != nil, let ownedPopup,
                      observation.permitsOwnedPopupRead(ownedPopup, nativeSource: pair.strip),
                      originalWindowCurrent() else { return false }
            }
            guard runtime.logicProPID() == observation.pid, runtime.focusedApplicationPID() == observation.pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            return true
        }
    }

    enum OriginalHeaderSourceDisposition {
        case retiredOriginal, survivingOriginal, readObservation

        func accepts(_ current: AXMixerStripBinding.Binding, original: AXMixerStripBinding.Binding) -> Bool {
            switch self {
            case .retiredOriginal: return !current.matches(original)
            case .survivingOriginal: return current.matches(original)
            case .readObservation:
                // The actual one-to-one original-header observation, not CF
                // retirement, qualifies this read-only post-popup source.
                return CFEqual(current.window, original.window) && CFEqual(current.mixer, original.mixer)
                    && current.document.utf8.elementsEqual(original.document.utf8)
            }
        }
    }

    /// Shared physical observation only: callers retain their own slot/readback contract.
    /// A successful inverse and original header CF are required; no reference is rebound.
    static func renewSourceThroughOriginalHeader(
        _ originalPair: HeldSelectionAssociation.Pair, original: AXMixerStripBinding.Binding,
        runtime: AXLogicProElements.Runtime, selectedHeaderRequired: Bool = true,
        sourceDisposition: OriginalHeaderSourceDisposition = .retiredOriginal,
        restoringMixerGeometry: HeldSelectionAssociation.MixerViewportGeometry? = nil,
        observingReadFocus: @Sendable (HeldSelectionAssociation) -> Void = { _ in },
        observingPeerHeaders: [AXTrackBinding.Binding]? = nil,
        observingPeerStrips: [AXMixerStripBinding.Binding]? = nil
    ) async -> (source: OriginalHeaderSourceRenewal?, effects: SessionPopulationObservation.UIEffects) {
        guard originalPair.strip.matches(original), originalPair.track.currentIndex() != nil,
              let observation = HeldSelectionAssociation(window: original.window, logic: runtime,
                  expectedProject: nil, requiresProjectReference: false, allowsSelectedChildRailEntry: true,
                  retainedMixerSource: sourceDisposition == .readObservation ? original : nil),
              CFEqual(observation.mixer, original.mixer),
              observation.document.utf8.elementsEqual(original.document.utf8),
              observation.headers.filter({ CFEqual($0, originalPair.track.header) }).count == 1,
              !selectedHeaderRequired || CFEqual(observation.headers[observation.originalIndex], originalPair.track.header)
        else { return (nil, .init()) }
        if let geometry = restoringMixerGeometry {
            // Geometry restores presentation only; it cannot rebind a source.
            // A caller's pre-popup duty must belong to this exact native scope.
            guard CFEqual(geometry.window, original.window), CFEqual(geometry.mixer, original.mixer),
                  geometry.document.utf8.elementsEqual(original.document.utf8),
                  geometry.headers.count == observation.headers.count,
                  zip(geometry.headers, observation.headers).allSatisfy({ CFEqual($0, $1) }),
                  geometry.frames.count == observation.strips.count else { return (nil, .init()) }
        }
        // The same fully qualified starting witness used by registered association
        // acquisition permits passive Help during this owned selection excursion.
        // Assignment authority still requires the actual pair and inverse below.
        observingReadFocus(observation)
        let originalMixerGeometry = restoringMixerGeometry ?? observation.observedMixerViewportGeometry()
        let pairs = await observation.observe(referenceIsCurrent: {
            originalPair.track.currentIndex(in: observation) != nil
                && (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
        }, stoppingWhen: { (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil },
            allHeldHeaders: true, prioritizingHeader: originalPair.track,
            observingPeerHeaders: observingPeerHeaders, observingPeerStrips: observingPeerStrips)
        if let originalMixerGeometry, observation.effects.restoration == "restored" {
            // The hidden Mixer bar is absent from the ordinary viewport census.
            // An original-header inverse must not retain a source after leaving
            // its controls offscreen. Reuse the existing owned native recovery;
            // an acknowledgement without exact layout readback is not restoration.
            let mixerRestored: Bool
            if let currentGeometry = observation.observedMixerViewportGeometry() {
                if currentGeometry.hasSameViewportPosition(as: originalMixerGeometry) { mixerRestored = true }
                else {
                    mixerRestored = await observation.recoverMixerReadability(restoring: originalMixerGeometry,
                        referenceIsCurrent: { originalPair.track.currentIndex(in: observation) != nil },
                        stoppingWhen: { (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil })
                }
            } else { mixerRestored = false }
            guard mixerRestored else {
                var effects = observation.effects
                effects.restoration = "not_restored"
                effects.reason = "association_mixer_viewport_restoration_unverified"
                return (nil, effects)
            }
        }
        let candidates = pairs.filter { $0.track.matches(originalPair.track) }
        guard candidates.count == 1, let pair = candidates.first,
              pairs.filter({ $0.strip.matches(pair.strip) }).count == 1,
              observation.effects.restoration == "restored",
              sourceDisposition.accepts(pair.strip, original: original), originalPair.track.currentIndex(in: observation) != nil,
              let index = pair.strip.currentIndex(in: observation) else {
            Log.info("Original-header source renewal refused: pairs=\(pairs.count), candidates=\(candidates.count), "
                + "restoration=\(observation.effects.restoration), dispositions=\(candidates.map { sourceDisposition.accepts($0.strip, original: original) })",
                subsystem: "ax")
            return (nil, observation.effects)
        }
        return (.init(pair: pair, index: index, original: original, originalTrack: originalPair.track,
            observation: observation, observedPairs: pairs), observation.effects)
    }

    /// Picks the popup entry for `destination` by structure: the parent submenu that owns it, then
    /// exactly one entry under that parent. The root's checked entry echoes the CURRENT output
    /// (measured ko, 2026-09-28: `Stereo Output` before a change, `버스 1 → Aux 1` after one), so it is
    /// never a destination: `Stereo Output` and the pairs come from the Output submenu, and the
    /// buses from the Bus submenu. A title repeated under the same parent is refused, and so is a
    /// menu on the way that was not read whole. Nothing is chosen by position.
    static func outputMenuChoice(
        for destination: OutputAssignment,
        in root: AXUIElement,
        runtime: AXHelpers.Runtime,
        receiverArrow: Character = "→"
    ) -> OutputMenuChoice {
        guard let rootItems = titledMenuItems(of: root, runtime: runtime) else { return .menuUnread(path: []) }
        switch destination {
        case .noOutput:
            let choices = rootItems.filter { OutputAssignment.observed(slotLabel: $0.title) == .noOutput }
            guard choices.count <= 1 else { return .repeated(count: choices.count) }
            guard let choice = choices.first else { return .notOffered(offered: []) }
            guard !choice.hasSubmenu else { return .menuUnread(path: [choice.title]) }
            return .item(choice.element, path: [choice.title])
        case .stereoOutput:
            let parent = submenu(titled: AXLocalePolicy.outputPopupOutputSubmenuTitle, among: rootItems, runtime: runtime)
            guard case .found(let title, let submenu) = parent else { return parent.choice }
            guard let items = titledMenuItems(of: submenu, runtime: runtime)?.filter({ !$0.hasSubmenu }) else {
                return .menuUnread(path: [title])
            }
            let matches = items.filter { AXLocalePolicy.stereoOutputLabel.matches($0.title, mode: .exact) }
            let offered = items.compactMap { OutputAssignment.observed(slotLabel: $0.title)?.token }
            return single(matches.map { ($0.element, [title, $0.title]) }, offered: offered)
        case .bus(let number):
            let parent = submenu(titled: AXLocalePolicy.outputPopupBusSubmenuTitle, among: rootItems, runtime: runtime)
            guard case .found(let title, let submenu) = parent else { return parent.choice }
            guard let leaves = leafItems(under: submenu, path: [title], depth: 0, runtime: runtime) else {
                return .menuUnread(path: [title])
            }
            let matches = leaves.filter {
                OutputAssignment.busNumber(ofMenuItemTitle: $0.title, receiverArrow: receiverArrow) == number
            }
            let offered = leaves.compactMap {
                OutputAssignment.busNumber(ofMenuItemTitle: $0.title, receiverArrow: receiverArrow)
            }
                .map { OutputAssignment.bus($0).token }
            return single(matches.map { ($0.element, $0.path) }, offered: offered)
        case .physical(let first, let second):
            let parent = submenu(titled: AXLocalePolicy.outputPopupOutputSubmenuTitle, among: rootItems, runtime: runtime)
            guard case .found(let title, let submenu) = parent else { return parent.choice }
            guard let items = titledMenuItems(of: submenu, runtime: runtime)?.filter({ !$0.hasSubmenu }) else {
                return .menuUnread(path: [title])
            }
            let matches = items.filter {
                OutputAssignment.pairPorts(ofRuntimeLabel: $0.title).map { $0 == (first, second) } ?? false
            }
            let offered = items.compactMap { OutputAssignment.pairPorts(ofRuntimeLabel: $0.title) }
                .map { OutputAssignment.physical($0.0, $0.1).token }
            return single(matches.map { ($0.element, [title, $0.title]) }, offered: offered)
        }
    }

    /// Send output choices have an additional Mono/Stereo branch in Logic.
    /// This remains observation only; callers must retain source/menu custody.
    static func sendMenuChoice(for destination: OutputAssignment, in root: AXUIElement,
        runtime: AXHelpers.Runtime) -> OutputMenuChoice {
        if case .bus = destination { return outputMenuChoice(for: destination, in: root, runtime: runtime) }
        guard destination != .noOutput else { return .notOffered(offered: []) }
        guard let roots = titledMenuItems(of: root, runtime: runtime) else { return .menuUnread(path: []) }
        let parent = submenu(titled: AXLocalePolicy.outputPopupOutputSubmenuTitle, among: roots, runtime: runtime)
        guard case .found(let title, let menu) = parent else { return parent.choice }
        guard let leaves = leafItems(under: menu, path: [title], depth: 0, runtime: runtime) else {
            return .menuUnread(path: [title])
        }
        let matches = leaves.filter { OutputAssignment.observed(slotLabel: $0.title) == destination }
        let offered = leaves.compactMap { OutputAssignment.observed(slotLabel: $0.title) }.filter {
            if case .bus = $0 { return false }; return $0 != .noOutput
        }.map(\.token)
        return single(matches.map { ($0.element, $0.path) }, offered: offered)
    }

    /// Observed EN/KO No Send root action, using the same complete typed
    /// role/title/submenu census as every other routing choice.
    static func sendRemovalMenuChoice(in root: AXUIElement, runtime: AXHelpers.Runtime) -> OutputMenuChoice {
        guard let items = titledMenuItems(of: root, runtime: runtime) else { return .menuUnread(path: []) }
        let matches = items.filter { !$0.hasSubmenu && isSendRemovalTitle($0.title) }
        return single(matches.map { ($0.element, [$0.title]) }, offered: [])
    }

    /// Unknown routing evidence is not empty. Require one explicitly checked
    /// No Send leaf and every routing leaf/echo known unchecked. Empty Send menus
    /// can disable the retained mode rows instead of checking them; final recreated
    /// mode readback still must match the capsule. This grants no source authority.
    static func checkedRemovedSendMenu(in root: AXUIElement, nonRoutingChecks: [String],
        runtime: AXHelpers.Runtime) -> Bool {
        func mark(_ element: AXUIElement) -> String? {
            let read: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(element,
                "AXMenuItemMarkChar", runtime: runtime)
            switch read {
            case .success(nil): return ""
            case .success(.some(let raw)):
                guard let text = raw as? String, text == "" || text == "✓" else { return nil }
                return text
            case .failure(let error) where error.isDefinitiveAbsence: return ""
            default: return nil
            }
        }
        guard let items = titledMenuItems(of: root, runtime: runtime),
              items.filter({ !$0.hasSubmenu && isSendRemovalTitle($0.title) }).count == 1 else { return false }
        var checkedNoSend = 0
        var checkedModes: [String] = []
        for item in items {
            guard let checked = mark(item.element) else { return false }
            if let submenu = item.submenu {
                guard checked.isEmpty,
                      let leaves = leafItems(under: submenu, path: [item.title], depth: 0, runtime: runtime),
                      leaves.allSatisfy({ mark($0.element) == "" }) else { return false }
            } else if checked == "✓" {
                if isSendRemovalTitle(item.title) { checkedNoSend += 1 }
                else {
                    guard nonRoutingChecks.contains(item.title) else { return false }
                    checkedModes.append(item.title)
                }
            }
        }
        guard checkedNoSend == 1 else { return false }
        if checkedModes == nonRoutingChecks { return true }
        guard checkedModes.isEmpty else { return false }
        return nonRoutingChecks.allSatisfy { title in
            let modes = items.filter { !$0.hasSubmenu && $0.title == title }
            guard modes.count == 1, let mode = modes.first, mark(mode.element) == "" else { return false }
            let enabled: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(mode.element,
                kAXEnabledAttribute as String, runtime: runtime)
            guard case .success(.some(let raw)) = enabled, CFGetTypeID(raw) == CFBooleanGetTypeID(),
                  let value = raw as? Bool else { return false }
            return !value
        }
    }

    /// Reads the host's checked current-output echo and its matching checked routing leaf.
    /// AXSelected is menu focus, not the checkmark. Root panner marks are not routing choices;
    /// root/submenu aliases must agree, and each routing submenu is read completely.
    /// This is an observation only: callers must separately prove popup/source custody.
    static func currentOutputMenuAssignment(
        in root: AXUIElement, runtime: AXHelpers.Runtime,
        observingBusNumbers: (([Int]) -> Void)? = nil
    ) -> OutputAssignment? {
        currentRoutingMenuAssignment(in: root, runtime: runtime, inputBusOnly: false,
            observingBusNumbers: observingBusNumbers)
    }

    enum SendMode: String, Sendable, CaseIterable {
        case postPan = "post_pan", postFader = "post_fader", preFader = "pre_fader"
    }

    /// Values from a complete owned mode menu, not a typed resource projection
    /// or permission to reacquire an unrelated control.
    struct SendModeState: Equatable, Sendable {
        let mode: SendMode
        let independentPan: Bool
        let otherChecks: [String]
    }

    private static func sendModeCensus(in root: AXUIElement, runtime: AXHelpers.Runtime)
        -> (state: SendModeState, rows: [SendMode: TitledMenuItem])? {
        guard let items = titledMenuItems(of: root, runtime: runtime),
              let checks = sendMenuNonRoutingChecks(in: root, runtime: runtime) else { return nil }
        func mode(_ title: String) -> SendMode? {
            switch title {
            case "Post Pan", "포스트 패닝": .postPan
            case "Post Fader", "포스트 페이더": .postFader
            case "Pre Fader", "프리 페이더": .preFader
            default: nil
            }
        }
        func mark(_ item: TitledMenuItem) -> Bool? {
            let result: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                item.element, "AXMenuItemMarkChar", runtime: runtime)
            switch result {
            case .success(nil): return false
            case .success(let value?):
                guard let text = value as? String else { return nil }
                if text == "" { return false }; if text == "✓" { return true }; return nil
            case .failure(let error) where error.raw == -25212: return false
            default: return nil
            }
        }
        var rows: [SendMode: TitledMenuItem] = [:], selected: [SendMode] = []
        for item in items {
            guard let kind = mode(item.title) else { continue }
            guard !item.hasSubmenu, rows[kind] == nil, let checked = mark(item) else { return nil }
            rows[kind] = item
            if checked { selected.append(kind) }
        }
        let independent = items.filter { ["Independent Pan", "독립 패닝"].contains($0.title) }
        guard rows.count == SendMode.allCases.count, selected.count == 1,
              independent.count == 1, !independent[0].hasSubmenu, let panned = mark(independent[0]) else { return nil }
        let known = Set(rows.values.map(\.title) + [independent[0].title])
        return (.init(mode: selected[0], independentPan: panned,
            otherChecks: checks.filter { !known.contains($0) }), rows)
    }

    static func currentSendMode(in root: AXUIElement, runtime: AXHelpers.Runtime) -> SendModeState? {
        sendModeCensus(in: root, runtime: runtime)?.state
    }

    static func sendModeMenuChoice(_ desired: SendMode, in root: AXUIElement,
        runtime: AXHelpers.Runtime) -> OutputMenuChoice {
        guard let census = sendModeCensus(in: root, runtime: runtime), let item = census.rows[desired] else {
            return .menuUnread(path: [])
        }
        return .item(item.element, path: [item.title])
    }

    /// Complete raw non-routing root checkmarks, solely to detect collateral
    /// changes during an occupied-send replacement. No label supplies routing authority.
    static func sendMenuNonRoutingChecks(in root: AXUIElement, runtime: AXHelpers.Runtime) -> [String]? {
        guard let roots = titledMenuItems(of: root, runtime: runtime) else { return nil }
        var checked: [String] = []
        for item in roots where !item.hasSubmenu {
            if OutputAssignment.observed(slotLabel: item.title) != nil
                || OutputAssignment.isBusMenuItemTitle(item.title, receiverArrow: "→") { continue }
            let result: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(item.element,
                "AXMenuItemMarkChar", runtime: runtime)
            switch result {
            case .success(nil), .success(""): break
            case .success("✓"): checked.append(item.title)
            case .failure(let error) where error.raw == -25212: break
            default: return nil
            }
        }
        return checked
    }

    /// Input bus echoes use the incoming arrow. Other input kinds stay unqualified.
    static func currentInputMenuBusAssignment(in root: AXUIElement, runtime: AXHelpers.Runtime) -> Int? {
        guard case .bus(let number)? = currentRoutingMenuAssignment(in: root, runtime: runtime, inputBusOnly: true) else { return nil }
        return number
    }

    static func currentInputMenuAssignment(in root: AXUIElement, runtime: AXHelpers.Runtime) -> InputAssignment? {
        checkedRoutingMenuAssignment(in: root, runtime: runtime, isInput: true, neutral: .noInput,
            destination: InputAssignment.classifiedMenuTitle,
            isBus: { if case .bus = $0 { return true }; return false })
    }

    /// Ownership scope for a native neutral-input popup only. This is deliberately
    /// not an assignment reader: the public checked-input capability remains bus-only.
    static func hasCheckedNoInputMenu(in root: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        guard let roots = titledMenuItems(of: root, runtime: runtime) else { return false }
        let neutral = roots.filter { AXLocalePolicy.noInputMenuLabel.matches($0.title, mode: .exact) }
        guard neutral.count == 1, let item = neutral.first, !item.hasSubmenu else { return false }
        func mark(_ element: AXUIElement) -> String? {
            let read: Result<AnyObject?, AXHelpers.AXStatusError> =
                AXHelpers.getAttributeResult(element, "AXMenuItemMarkChar", runtime: runtime)
            switch read {
            case .success(nil): return ""
            case .success(.some(let value)): return value as? String
            case .failure(let error) where error.raw == -25212: return ""
            case .failure: return nil
            }
        }
        guard mark(item.element) == "✓" else { return false }
        for other in roots where !CFEqual(other.element, item.element) {
            guard mark(other.element) == "" else { return false }
            if let submenu = other.submenu {
                guard let leaves = leafItems(under: submenu, path: [other.title], depth: 0, runtime: runtime),
                      leaves.allSatisfy({ mark($0.element) == "" }) else { return false }
            }
        }
        return true
    }

    private static func currentRoutingMenuAssignment(
        in root: AXUIElement, runtime: AXHelpers.Runtime, inputBusOnly: Bool,
        observingBusNumbers: (([Int]) -> Void)? = nil
    ) -> OutputAssignment? {
        if inputBusOnly {
            guard case .bus(let number)? = currentInputMenuAssignment(in: root, runtime: runtime) else { return nil }
            return .bus(number)
        }
        func destination(_ title: String) -> OutputAssignment? {
            if let bus = OutputAssignment.busNumber(ofMenuItemTitle: title) { return .bus(bus) }
            guard let observed = OutputAssignment.observed(slotLabel: title) else { return nil }
            // Display classification cannot re-authorize a bus rejected by the checked domain.
            if case .bus = observed { return nil }
            return observed
        }
        return checkedRoutingMenuAssignment(in: root, runtime: runtime, isInput: false, neutral: .noOutput,
            destination: destination, isBus: { if case .bus = $0 { return true }; return false },
            observingBusNumbers: observingBusNumbers)
    }

    private static func checkedRoutingMenuAssignment<Assignment: Equatable>(
        in root: AXUIElement, runtime: AXHelpers.Runtime, isInput: Bool, neutral: Assignment,
        destination: (String) -> Assignment?, isBus: (Assignment) -> Bool,
        observingBusNumbers: (([Int]) -> Void)? = nil
    ) -> Assignment? {
        let receiverArrow: Character = isInput ? "←" : "→"
        func mark(_ item: AXUIElement) -> String? {
            let result: Result<AnyObject?, AXHelpers.AXStatusError> =
                AXHelpers.getAttributeResult(item, "AXMenuItemMarkChar", runtime: runtime)
            switch result {
            case .success(nil): return ""
            case .success(.some(let value)): return value as? String
            case .failure(let error) where error.raw == -25212: return ""
            case .failure: return nil
            }
        }
        guard let roots = titledMenuItems(of: root, runtime: runtime) else { return nil }
        var echo: [Assignment] = []
        for item in roots where !item.hasSubmenu {
            guard let assignment = destination(item.title) else {
                if isInput || OutputAssignment.isBusMenuItemTitle(item.title, receiverArrow: receiverArrow) {
                    guard mark(item.element) == "" else { return nil }
                }
                continue
            }
            guard let checked = mark(item.element), checked == "" || checked == "✓" else { return nil }
            if checked == "✓" { echo.append(assignment) }
        }
        guard echo.count == 1, let current = echo.first else { return nil }
        var checkedLeaves: [Assignment] = []
        var branches: [(String,AXUIElement)] = []
        if isInput {
            guard case .found = submenu(titled: AXLocalePolicy.outputPopupBusSubmenuTitle, among: roots, runtime: runtime) else { return nil }
            if current != neutral, !isBus(current) {
                guard case .found = submenu(titled: AXLocalePolicy.unassignedInputSlotLabel, among: roots, runtime: runtime) else { return nil }
            }
            // Every other input branch must also read as unselected; it cannot be hidden behind
            // the bus-only capability's narrower result type.
            branches = roots.compactMap { item in item.submenu.map { (item.title,$0) } }
        } else {
            for labels in [AXLocalePolicy.outputPopupOutputSubmenuTitle, AXLocalePolicy.outputPopupBusSubmenuTitle] {
                switch submenu(titled: labels, among: roots, runtime: runtime) {
                case .missing: continue
                case .repeated: return nil
                case .found(let title, let menu): branches.append((title,menu))
                }
            }
        }
        var observedBusNumbers: [Int]?
        for (title,menu) in branches {
            guard let leaves = leafItems(under: menu, path: [title], depth: 0, runtime: runtime) else { return nil }
            if observingBusNumbers != nil, !isInput,
               AXLocalePolicy.outputPopupBusSubmenuTitle.matches(title, mode: .exact) {
                let numbers = leaves.compactMap {
                    OutputAssignment.busNumber(ofMenuItemTitle: $0.title, receiverArrow: receiverArrow)
                }
                // These are menu entries, not unused buses, selectable choices, or
                // an allocation reservation. An incomplete/ambiguous inventory is
                // withheld without erasing an independently checked assignment.
                if !numbers.isEmpty, numbers.count == leaves.count, Set(numbers).count == numbers.count {
                    observedBusNumbers = numbers.sorted()
                }
            }
            for item in leaves {
                guard let checked = mark(item.element), checked == "" || checked == "✓" else { return nil }
                if checked == "✓" {
                    guard let assignment = destination(item.title) else { return nil }
                    // Bus numbers only have authority under Bus, never a panner/Output branch.
                    let isBusParent = AXLocalePolicy.outputPopupBusSubmenuTitle.matches(title, mode: .exact)
                    if isBus(assignment) { guard isBusParent else { return nil } }
                    else {
                        guard !isBusParent,
                              !isInput || AXLocalePolicy.unassignedInputSlotLabel.matches(title, mode: .exact) else { return nil }
                    }
                    checkedLeaves.append(assignment)
                }
            }
        }
        let agrees = current == neutral ? checkedLeaves.isEmpty : checkedLeaves.count == 1 && checkedLeaves.first == current
        guard agrees else { return nil }
        if let observedBusNumbers { observingBusNumbers?(observedBusNumbers) }
        return current
    }

    private struct TitledMenuItem {
        let element: AXUIElement
        let title: String
        let submenu: AXUIElement?
        var hasSubmenu: Bool { submenu != nil }
    }

    private enum SubmenuLookup {
        case found(String, AXUIElement)
        case missing(String)
        case repeated(String, Int)

        var choice: OutputMenuChoice {
            switch self {
            case .found(let title, let menu): .item(menu, path: [title])
            case .missing(let canonical): .parentMissing(canonical)
            case .repeated(let canonical, let count): .parentRepeated(canonical, count: count)
            }
        }
    }

    private static func single(_ matches: [(AXUIElement, [String])], offered: [String]) -> OutputMenuChoice {
        switch matches.count {
        case 0: .notOffered(offered: offered)
        case 1: .item(matches[0].0, path: matches[0].1)
        default: .repeated(count: matches.count)
        }
    }

    private static func submenu(
        titled labels: AXLocalePolicy.LabelSet,
        among items: [TitledMenuItem],
        runtime: AXHelpers.Runtime
    ) -> SubmenuLookup {
        let parents = items.filter { labels.matches($0.title, mode: .exact) && $0.hasSubmenu }
        guard parents.count == 1, let parent = parents.first, let menu = parent.submenu else {
            return parents.isEmpty ? .missing(labels.canonical) : .repeated(labels.canonical, parents.count)
        }
        return .found(parent.title, menu)
    }

    /// Every entry under `menu` that opens no further submenu, with the titles leading to it, or
    /// `nil` when any menu on the way was not read whole or nests deeper than it looks. The Bus
    /// submenu nests its higher buses one level down (`33 - 64 >`), so this descends.
    private static func leafItems(
        under menu: AXUIElement,
        path: [String],
        depth: Int,
        runtime: AXHelpers.Runtime
    ) -> [(element: AXUIElement, title: String, path: [String])]? {
        guard depth <= 3, let items = titledMenuItems(of: menu, runtime: runtime) else { return nil }
        var leaves: [(element: AXUIElement, title: String, path: [String])] = []
        for item in items {
            guard let submenu = item.submenu else {
                leaves.append((item.element, item.title, path + [item.title]))
                continue
            }
            guard let below = leafItems(
                under: submenu, path: path + [item.title], depth: depth + 1, runtime: runtime
            ) else { return nil }
            leaves += below
        }
        return leaves
    }

    /// Every titled entry of `menu`, with its submenu when it has one, or `nil` when the menu was
    /// not read whole: its children, an entry's role, title or children did not read, or an entry
    /// holds more than one submenu. Nothing whose identity was not established is passed over,
    /// because it could be the second of two entries with the same title (#1062 review R2-03).
    ///
    /// -25205 and -25212 are answers to a read, but not every answer lets an entry be skipped:
    /// - a child whose role answers "none" is `nil` (it could be a menu item); a readable role
    ///   other than `AXMenuItem` is skipped;
    /// - an item whose title reads but is blank or whitespace is a separator and is skipped;
    /// - an item whose title answers "none" is skipped only when it is the popup's search field:
    ///   its children include an `AXTextField` and no `AXMenu`, every child's role read. Every
    ///   other untitled item is `nil`.
    /// Measured on Logic Pro 12.3 ko, 2026-09-29, the first strip's output-slot popup, whole tree
    /// walked: 284 `AXMenuItem` children, every role read; 277 titled; 6 separators whose title
    /// reads `""` with `AXEnabled` false; and exactly one item whose title answers -25212 — root
    /// item [0], whose single child is an `AXTextField` (holding one `AXButton`).
    private static func titledMenuItems(of menu: AXUIElement, runtime: AXHelpers.Runtime) -> [TitledMenuItem]? {
        guard let children = menuChildren(of: menu, runtime: runtime) else { return nil }
        var items: [TitledMenuItem] = []
        for child in children {
            guard case let .success(role) = menuString(child, kAXRoleAttribute as String, runtime: runtime) else {
                return nil
            }
            guard let role else { return nil }
            guard role == (kAXMenuItemRole as String) else { continue }
            guard case let .success(title) = menuString(child, kAXTitleAttribute as String, runtime: runtime) else {
                return nil
            }
            guard let title else {
                guard let isSearchField = isSearchFieldItem(child, runtime: runtime), isSearchField else {
                    return nil
                }
                continue
            }
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let below = menuChildren(of: child, runtime: runtime) else { return nil }
            var submenus: [AXUIElement] = []
            for element in below {
                guard case let .success(role) = menuString(element, kAXRoleAttribute as String, runtime: runtime), let role else {
                    return nil
                }
                if role == (kAXMenuRole as String) { submenus.append(element) }
            }
            guard submenus.count <= 1 else { return nil }
            items.append(TitledMenuItem(element: child, title: title, submenu: submenus.first))
        }
        return items
    }

    /// Whether an untitled menu item is the popup's search field: among its children an
    /// `AXTextField` and no `AXMenu`. `nil` when its children or any child's role did not read, or
    /// a child's role answers "none" (it could be the submenu that makes the item a real entry).
    private static func isSearchFieldItem(_ item: AXUIElement, runtime: AXHelpers.Runtime) -> Bool? {
        guard let children = menuChildren(of: item, runtime: runtime) else { return nil }
        var holdsTextField = false
        for child in children {
            guard case let .success(role) = menuString(child, kAXRoleAttribute as String, runtime: runtime),
                  let role else { return nil }
            if role == (kAXMenuRole as String) { return false }
            if role == (kAXTextFieldRole as String) { holdsTextField = true }
        }
        return holdsTextField
    }

    private static func menuChildren(of element: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement]? {
        switch AXHelpers.childrenResult(element, runtime: runtime) {
        case .success(let children): children
        case .failure(let error): error.isDefinitiveAbsence ? [] : nil
        }
    }

    /// A role or title with the two statuses that are answers read as "has none", so `.failure` is
    /// only ever a read that did not happen.
    private static func menuString(
        _ element: AXUIElement,
        _ attribute: String,
        runtime: AXHelpers.Runtime
    ) -> Result<String?, AXHelpers.AXStatusError> {
        let read: Result<String?, AXHelpers.AXStatusError> =
            AXHelpers.getAttributeResult(element, attribute, runtime: runtime)
        if case let .failure(error) = read, error.isDefinitiveAbsence { return .success(nil) }
        return read
    }

    /// A strip's input as a bus number, or `nil` when it is anything else or did not read.
    private static func busNumber(feeding reading: AXLogicProElements.InputSlotReading?) -> Int? {
        guard case .source(let label) = reading else { return nil }
        let (classification, bus) = RoutingGraphPublication.classifyOutputLabel(label)
        return classification == .bus ? bus : nil
    }

    /// The two checks a bus destination needs, read from `strips`: the assignment closes no loop,
    /// and another strip already reads the bus. They are made before the popup opens and again right
    /// before the press. A refusal's hint says what was found; the caller says what was not done.
    enum BusCheck {
        case receivers([Int])
        case refused(HonestContract.FailureError, String, [String: Any])
    }

    static func busCheck(
        into number: Int,
        from index: Int,
        strips: [AXUIElement],
        runtime: AXHelpers.Runtime
    ) -> BusCheck {
        var inputs: [Int: AXLogicProElements.InputSlotReading] = [:]
        for (ordinal, other) in strips.enumerated() where ordinal != index {
            inputs[ordinal] = AXLogicProElements.inputSlotReading(in: other, runtime: runtime)
        }
        // The loop check comes first: a strip that is the only reader of its own input bus has
        // no other receiver, and would otherwise be refused as if no strip read that bus.
        switch busLoop(into: number, from: index, strips: strips, inputs: inputs, runtime: runtime) {
        case .clear:
            break
        case .closes(let feed):
            let path = feed == number ? "that is the bus it was asked to output to"
                : "Bus \(number) reaches Bus \(feed) through the strips that receive it"
            return .refused(.routingCycle, "This strip reads Bus \(feed) as its input, and \(path), "
                + "so the assignment would close a loop", ["input_bus": feed])
        case .unknown(let ordinal, let part):
            let unread = ordinal == index ? "This strip's input did not read"
                : "This strip reads a bus as its input, and the strip at index \(ordinal), which the "
                    + "check had to follow from Bus \(number), did not say where its signal goes (\(part))"
            return .refused(.routingDependencyUnknown, "\(unread). A loop cannot be ruled out",
                ["dependency_strip": ordinal, "dependency_unread": part])
        }
        // A bus needs a receiver that already exists: Logic creates an aux for an unused bus, and
        // this operation has no creation authority (#967). An input that did not read is listed,
        // never counted as "not a receiver" — the refusal stands either way.
        let ordinals = inputs.keys.sorted()
        let receivers = ordinals.filter { busNumber(feeding: inputs[$0]) == number }
        guard !receivers.isEmpty else {
            return .refused(.busHasNoReceiver, "No other strip in the Mixer reads Bus \(number) as its "
                + "input. Logic creates an aux when a strip is sent to an unused bus, and this "
                + "operation may not create one (#967)",
                ["bus": number, "strips_with_input_not_read": ordinals.filter { inputs[$0] == .unreadable }])
        }
        return .receivers(receivers)
    }

    /// What routing the strip at `index` to a bus would close, read before the destination is pressed.
    enum BusLoop: Equatable {
        case clear
        /// The strip reads Bus `feed` as its input, and the destination bus reaches it.
        case closes(feed: Int)
        /// The strip at `ordinal` had to be followed, and its `part` (`input`, `output`, `sends`
        /// or `send`) did not say where its signal goes.
        case unknown(ordinal: Int, part: String)
    }

    /// A loop needs a way back into the strip, and the only one is its input slot reading a bus:
    /// a strip with no input slot, or one fed by anything else, closes nothing. Otherwise every bus
    /// reached from `bus` is followed through the strips that read it, by each one's output and
    /// sends, and reaching the strip's own input bus is a loop. A strip that cannot be followed
    /// stops the check: an input that did not read could be any bus's receiver, and an occupied
    /// send goes to a destination R1's reader does not read. `inputs` holds every other strip.
    static func busLoop(
        into bus: Int,
        from index: Int,
        strips: [AXUIElement],
        inputs: [Int: AXLogicProElements.InputSlotReading],
        runtime: AXHelpers.Runtime
    ) -> BusLoop {
        let own = AXLogicProElements.inputSlotReading(in: strips[index], runtime: runtime)
        if own == .unreadable { return .unknown(ordinal: index, part: "input") }
        guard let feed = busNumber(feeding: own) else { return .clear }
        let ordinals = inputs.keys.sorted()
        if let unread = ordinals.first(where: { inputs[$0] == .unreadable }) {
            return .unknown(ordinal: unread, part: "input")
        }
        var reached: Set<Int> = [bus]
        var queue = [bus]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current == feed { return .closes(feed: feed) }
            for ordinal in ordinals where busNumber(feeding: inputs[ordinal]) == current {
                let receiver = strips[ordinal]
                guard let label = AXLogicProElements.outputSlotDestination(in: receiver, runtime: runtime),
                      let output = OutputAssignment.observed(slotLabel: label) else {
                    return .unknown(ordinal: ordinal, part: "output")
                }
                guard let sends = AXLogicProElements.sendSlotObservations(in: receiver, runtime: runtime) else {
                    return .unknown(ordinal: ordinal, part: "sends")
                }
                if sends.contains(where: { $0.state != .observedEmpty }) {
                    return .unknown(ordinal: ordinal, part: "send")
                }
                if case .bus(let next) = output, reached.insert(next).inserted {
                    queue.append(next)
                }
            }
        }
        return .clear
    }

    private static func popupMenus(in mixer: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement] {
        AXHelpers.getChildren(mixer, runtime: runtime).filter {
            AXHelpers.getRole($0, runtime: runtime) == (kAXMenuRole as String)
        }
    }

    private static func newPopupMenus(
        in mixer: AXUIElement,
        excluding before: [AXUIElement],
        timing: OutputAssignmentTiming,
        runtime: AXHelpers.Runtime
    ) async -> [AXUIElement] {
        let deadline = Date().addingTimeInterval(Double(timing.popupOpenTimeoutMs) / 1000.0)
        repeat {
            let fresh = popupMenus(in: mixer, runtime: runtime).filter { menu in
                !before.contains { CFEqual($0, menu) }
            }
            if !fresh.isEmpty { return fresh }
            if timing.pollIntervalMs > 0 { try? await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) }
        } while Date() < deadline
        return []
    }

    /// Closes what this run opened and says what was measured. After a selection the menu closes
    /// itself, so Logic's popup-level windows are first given `popupCloseTimeoutMs` to go: the
    /// shared cleanup posts Escape when one is still counted, and an Escape with no menu open
    /// reaches the arrange window instead. Either way the shared cleanup has the last word.
    static func closeOutputPopup(
        runtime: AXLogicProElements.Runtime,
        timing: OutputAssignmentTiming,
        waitForSelfClose: Bool,
        cleaner: PluginPopupMenuCleaner,
        permittingCleanup: () -> Bool = { true }
    ) async -> [String: Any] {
        if waitForSelfClose {
            let deadline = Date().addingTimeInterval(Double(timing.popupCloseTimeoutMs) / 1000.0)
            repeat {
                if let pid = runtime.logicProPID(), let windows = runtime.onScreenWindowList(),
                   LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0 {
                    break
                }
                if timing.pollIntervalMs > 0 { try? await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) }
            } while Date() < deadline
        }
        guard permittingCleanup() else {
            // A self-closed popup needs no cleanup authority or action. The
            // original source may legitimately have retired after the write.
            if let pid = runtime.logicProPID(), let windows = runtime.onScreenWindowList(),
               LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0 {
                return ["popup_menu_state": "closed"]
            }
            return ["popup_menu_state": "custody_lost",
                    "recovery_hint": "Original popup/source/project custody was lost; cleanup was not authorized."]
        }
        switch cleaner(runtime) {
        case .noPopupObserved:
            return ["popup_menu_state": "closed"]
        case .dismissed:
            return ["popup_menu_state": "dismissed"]
        case .popupCountUnavailable:
            return ["popup_menu_state": "window_count_unavailable",
                    "recovery_hint": "Whether the output popup closed could not be read. Dismiss any "
                        + "Logic popup menu with Escape before the next call."]
        case let .couldNotDismiss(initial, remaining):
            return ["popup_menu_state": "could_not_be_dismissed",
                    "popup_menu_initial_window_count": initial,
                    "popup_menu_remaining_window_count": remaining,
                    "recovery_hint": "A Logic popup menu stayed open. Dismiss it with Escape before the "
                        + "next call, because an open one blocks Logic's AppleEvent handler."]
        }
    }
}
