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
        popupCleaner: PluginPopupMenuCleaner = livePluginPopupMenuCleaner
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
        // No Output has no way back through this command: after it was selected, pressing the slot
        // opened no menu on three attempts, nor 0, 5, 15 or 30 seconds later (docs/observations/
        // 2026-09-11-routing-slots-open-their-menus-and-a-destination-can-be-selected.json). It is
        // a value this reads, never one it sets.
        guard destination != .noOutput else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams, hint: "\(operation) does not set No Output: a strip set to it "
                    + "was measured to open no output menu, so this command could not set it back. "
                    + "'no_output' is accepted only as 'expected_current'."
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
            .error(HonestContract.encodeStateC(
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
        if before == destination {
            extras["after"] = before.json
            extras["changed"] = false
            extras["verify_source"] = "ax_output_slot"
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        // The same measurement as the refusal of `no_output` above: this strip's slot is not
        // expected to open a menu, and a press on it is not one this command can account for.
        if before == .noOutput {
            return refusal(.unsupportedState, "The strip's output is No Output, and a slot set to No "
                + "Output was measured to open no menu when pressed, so this command cannot change it. "
                + "Choose its output in Logic; nothing was pressed.")
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

        var heldPopup: AXUIElement?
        func popupSourceStillCurrent() -> Bool {
            guard let physical else { return true } // Preserve the explicit legacy selector path.
            guard !Task.isCancelled, let root = heldPopup,
                  AXHelpers.getRole(physical.strip, runtime: runtime.ax) == kAXLayoutItemRole as String,
                  let currentSlot = AXLogicProElements.outputSlotButton(in: physical.strip, runtime: runtime.ax),
                  CFEqual(currentSlot, slotButton),
                  case .success(let sourceChildren) = AXHelpers.childrenResult(physical.strip, runtime: runtime.ax),
                  sourceChildren.filter({ CFEqual($0, slotButton) }).count == 1,
                  case .success(let children) = AXHelpers.childrenResult(mixer, runtime: runtime.ax),
                  children.filter({ CFEqual($0, root) }).count == 1,
                  physical.currentIndex(runtime: runtime) == index,
                  runtime.logicProPID() == logicPID,
                  case .found(let currentWindow) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                  CFEqual(currentWindow, physical.window),
                  case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(
                    physical.window, runtime: runtime),
                  currentDocument.utf8.elementsEqual(physical.document.utf8), !Task.isCancelled else { return false }
            return true
        }

        // Open the popup of THIS strip and find the menu it opened: a new AXMenu among the Mixer
        // layout area's children, which is where Logic parents it (measured in ko and de).
        let menusBefore = popupMenus(in: mixer, runtime: runtime.ax)
        if let physical, physical.currentIndex(runtime: runtime) != index {
            return refusal(.staleTargetReference, "The referenced source changed before its output popup opened; nothing was pressed.")
        }
        _ = AXHelpers.performAction(slotButton, kAXPressAction, runtime: runtime.ax)
        let opened = await newPopupMenus(in: mixer, excluding: menusBefore, timing: timing, runtime: runtime.ax)
        guard opened.count == 1, let root = opened.first else {
            let cleanup = await closeOutputPopup(runtime: runtime, timing: timing, waitForSelfClose: false,
                                                 cleaner: popupCleaner, permittingCleanup: popupSourceStillCurrent)
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
                                                 cleaner: popupCleaner, permittingCleanup: popupSourceStillCurrent)
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
                                                 cleaner: popupCleaner, permittingCleanup: popupSourceStillCurrent)
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
                                                 cleaner: popupCleaner, permittingCleanup: popupSourceStillCurrent)
            return refusal(error, hint + ", read again with the popup open; nothing was selected.",
                cleanup.merging(more.merging(["read_with_popup_open": true]) { _, new in new }) { _, new in new })
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
                                            cleaner: popupCleaner, permittingCleanup: popupSourceStillCurrent)
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
            if afterLabel == nil, !attemptedAssociation, let physical, let outputAssociation,
               enumeration?.strips.count == strips.count, physical.currentIndex(runtime: runtime) == nil {
                attemptedAssociation = true
                let observed = await readOutputThroughOriginalHeader(outputAssociation, original: physical, runtime: runtime)
                extras["ui_effects"] = ["navigation_performed": observed.effects.navigationPerformed,
                    "attempted": observed.effects.attempted, "changed": observed.effects.changed,
                    "restoration": observed.effects.restoration, "reason": observed.effects.reason as Any? ?? NSNull()]
                if let label = observed.label, let renewedIndex = observed.index {
                    afterLabel = label
                    after = OutputAssignment.observed(slotLabel: label)
                    extras["source_renewal"] = "held_exclusive_selection_focus"
                    extras["reference_reread_required"] = true
                    extras["source_index_after"] = renewedIndex
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
        runtime: AXLogicProElements.Runtime
    ) async -> (label: String?, index: Int?, effects: SessionPopulationObservation.UIEffects) {
        guard originalPair.strip.matches(original), originalPair.track.currentIndex() != nil,
              let observation = HeldSelectionAssociation(window: original.window, logic: runtime,
                  expectedProject: nil, requiresProjectReference: false),
              CFEqual(observation.mixer, original.mixer),
              observation.document.utf8.elementsEqual(original.document.utf8),
              CFEqual(observation.headers[observation.originalIndex], originalPair.track.header) else { return (nil, nil, .init()) }
        let pairs = await observation.observe(referenceIsCurrent: {
            originalPair.track.currentIndex() != nil
                && (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
        }, stoppingWhen: { (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil })
        let candidates = pairs.filter { $0.track.matches(originalPair.track) }
        guard candidates.count == 1, let pair = candidates.first,
              pairs.filter({ $0.strip.matches(pair.strip) }).count == 1,
              observation.effects.restoration == "restored",
              !pair.strip.matches(original), originalPair.track.currentIndex() != nil,
              let index = pair.strip.currentIndex(runtime: runtime),
              let label = AXLogicProElements.outputSlotDestination(in: pair.strip.strip, runtime: runtime.ax),
              pair.strip.currentIndex(runtime: runtime) == index,
              originalPair.track.currentIndex() != nil,
              observation.permitsRead(),
              case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
              CFEqual(window, original.window),
              case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(original.window, runtime: runtime),
              document.utf8.elementsEqual(original.document.utf8),
              runtime.logicProPID() == observation.pid, runtime.focusedApplicationPID() == observation.pid,
              (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return (nil, nil, observation.effects) }
        return (label, index, observation.effects)
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
        runtime: AXHelpers.Runtime
    ) -> OutputMenuChoice {
        guard let rootItems = titledMenuItems(of: root, runtime: runtime) else { return .menuUnread(path: []) }
        switch destination {
        case .noOutput:
            // Never asked: `setOutputVerified` refuses No Output before any popup opens.
            return .notOffered(offered: [])
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
            let matches = leaves.filter { OutputAssignment.busNumber(ofMenuItemTitle: $0.title) == number }
            let offered = leaves.compactMap { OutputAssignment.busNumber(ofMenuItemTitle: $0.title) }
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

    /// Reads the host's checked current-output echo and its matching checked routing leaf.
    /// AXSelected is menu focus, not the checkmark. Root panner marks are not routing choices;
    /// root/submenu aliases must agree, and each routing submenu is read completely.
    /// This is an observation only: callers must separately prove popup/source custody.
    static func currentOutputMenuAssignment(
        in root: AXUIElement, runtime: AXHelpers.Runtime
    ) -> OutputAssignment? {
        currentRoutingMenuAssignment(in: root, runtime: runtime, inputBusOnly: false)
    }

    /// Input bus echoes use the incoming arrow. Other input kinds stay unqualified.
    static func currentInputMenuBusAssignment(in root: AXUIElement, runtime: AXHelpers.Runtime) -> Int? {
        guard case .bus(let number)? = currentRoutingMenuAssignment(in: root, runtime: runtime, inputBusOnly: true) else { return nil }
        return number
    }

    private static func currentRoutingMenuAssignment(
        in root: AXUIElement, runtime: AXHelpers.Runtime, inputBusOnly: Bool
    ) -> OutputAssignment? {
        let receiverArrow: Character = inputBusOnly ? "\u{2190}" : "\u{2192}"
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
        func destination(_ title: String) -> OutputAssignment? {
            if let bus = OutputAssignment.busNumber(ofMenuItemTitle: title, receiverArrow: receiverArrow) { return .bus(bus) }
            guard !inputBusOnly else { return nil }
            guard let observed = OutputAssignment.observed(slotLabel: title) else { return nil }
            // Display classification cannot re-authorize a bus rejected by the checked domain.
            if case .bus = observed { return nil }
            return observed
        }
        guard let roots = titledMenuItems(of: root, runtime: runtime) else { return nil }
        var echo: [OutputAssignment] = []
        for item in roots where !item.hasSubmenu {
            guard let assignment = destination(item.title) else {
                if inputBusOnly || OutputAssignment.isBusMenuItemTitle(item.title, receiverArrow: receiverArrow) {
                    guard mark(item.element) == "" else { return nil }
                }
                continue
            }
            guard let checked = mark(item.element), checked == "" || checked == "✓" else { return nil }
            if checked == "✓" { echo.append(assignment) }
        }
        guard echo.count == 1, let current = echo.first else { return nil }
        var checkedLeaves: [OutputAssignment] = []
        var branches: [(String,AXUIElement)] = []
        if inputBusOnly {
            guard case .found = submenu(titled: AXLocalePolicy.outputPopupBusSubmenuTitle, among: roots, runtime: runtime) else { return nil }
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
        for (title,menu) in branches {
            guard let leaves = leafItems(under: menu, path: [title], depth: 0, runtime: runtime) else { return nil }
            for item in leaves {
                guard let checked = mark(item.element), checked == "" || checked == "✓" else { return nil }
                if checked == "✓" {
                    guard let assignment = destination(item.title) else { return nil }
                    // Bus numbers only have authority under Bus, never a panner/Output branch.
                    let isBusParent = AXLocalePolicy.outputPopupBusSubmenuTitle.matches(title, mode: .exact)
                    if case .bus = assignment { guard isBusParent else { return nil } }
                    else { guard !isBusParent else { return nil } }
                    checkedLeaves.append(assignment)
                }
            }
        }
        if current == .noOutput { return checkedLeaves.isEmpty ? current : nil }
        return checkedLeaves.count == 1 && checkedLeaves.first == current ? current : nil
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
    private static func closeOutputPopup(
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
