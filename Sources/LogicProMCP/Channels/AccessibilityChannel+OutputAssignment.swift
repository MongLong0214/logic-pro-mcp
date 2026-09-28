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

        var failureLabel: String {
            switch self {
            case .item: "none"
            case .parentMissing: "submenu_not_offered"
            case .parentRepeated: "submenu_title_repeated"
            case .notOffered: "destination_not_offered"
            case .repeated: "destination_title_repeated"
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
        guard let index = params["index"].flatMap({ Int($0) }), index >= 0 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams, hint: "\(operation) requires 'index' (Int >= 0)"
            ))
        }
        guard let destination = params["destination"].flatMap(OutputAssignment.init(token:)) else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams, hint: "\(operation) requires a valid 'destination'"
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
            "track": index,
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
        let lookup = AXLogicProElements.mixerAreaLookup(runtime: runtime)
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
        guard index < strips.count else {
            return refusal(.elementNotFound, "track index out of range for the visible Mixer; nothing was pressed.")
        }
        let strip = strips[index]

        // The current output, read by R1's reader. Unreadable is not absent, and a label this
        // cannot classify cannot be compared with anything, so both refuse.
        guard let beforeLabel = AXLogicProElements.outputSlotDestination(in: strip, runtime: runtime.ax) else {
            return refusal(.readbackUnavailable, "The strip's current output did not read. Unreadable is "
                + "not absent, so there is nothing to compare the request with; nothing was pressed.")
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

        // A bus needs a receiver that already exists: Logic creates an aux for an unused bus, and
        // this operation has no creation authority (#967). An input that did not read is listed,
        // never counted as "not a receiver" — the refusal stands either way.
        if case .bus(let number) = destination {
            var receivers: [Int] = []
            var inputsNotRead: [Int] = []
            for (ordinal, other) in strips.enumerated() where ordinal != index {
                guard let input = AXLogicProElements.inputSlotSource(in: other, runtime: runtime.ax) else {
                    inputsNotRead.append(ordinal)
                    continue
                }
                let (classification, bus) = RoutingGraphPublication.classifyOutputLabel(input)
                if classification == .bus, bus == number {
                    receivers.append(ordinal)
                }
            }
            guard !receivers.isEmpty else {
                return refusal(.busHasNoReceiver, "No strip in the Mixer reads Bus \(number) as its input. "
                    + "Logic creates an aux when a strip is sent to an unused bus, and this operation "
                    + "may not create one (#967); nothing was pressed.",
                    ["bus": number, "strips_with_input_not_read": inputsNotRead])
            }
            extras["bus_receivers"] = receivers
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

        // Open the popup of THIS strip and find the menu it opened: a new AXMenu among the Mixer
        // layout area's children, which is where Logic parents it (measured in ko and de).
        let menusBefore = popupMenus(in: mixer, runtime: runtime.ax)
        _ = AXHelpers.performAction(slotButton, kAXPressAction, runtime: runtime.ax)
        let opened = await newPopupMenus(in: mixer, excluding: menusBefore, timing: timing, runtime: runtime.ax)
        guard opened.count == 1, let root = opened.first else {
            let cleanup = await closeOutputPopup(runtime: runtime, timing: timing, waitForSelfClose: false,
                                                 cleaner: popupCleaner)
            return refusal(.elementNotFound, opened.isEmpty
                ? "The output slot press opened no popup menu under the Mixer; nothing was selected."
                : "The output slot press opened \(opened.count) menus under the Mixer, so which one is "
                    + "this strip's cannot be told; nothing was selected.",
                cleanup.merging(["menu_failure": opened.isEmpty ? "popup_not_opened" : "popup_ambiguous",
                                 "menus_opened": opened.count]) { _, new in new })
        }

        let choice = outputMenuChoice(for: destination, in: root, runtime: runtime.ax)
        guard case .item(let item, let path) = choice else {
            let cleanup = await closeOutputPopup(runtime: runtime, timing: timing, waitForSelfClose: false,
                                                 cleaner: popupCleaner)
            var more = cleanup
            more["menu_failure"] = choice.failureLabel
            switch choice {
            case .notOffered(let offered): more["offered"] = offered
            case .repeated(let count), .parentRepeated(_, let count): more["matching_entries"] = count
            default: break
            }
            let error: HonestContract.FailureError
            if case .repeated = choice { error = .ambiguousTargetName }
            else if case .parentRepeated = choice { error = .ambiguousTargetName }
            else { error = .elementNotFound }
            return refusal(error, "The output popup does not offer this destination as exactly one "
                + "entry under the submenu that owns it (\(choice.failureLabel)); nothing was selected.",
                more)
        }
        guard (AXHelpers.getAttribute(item, kAXEnabledAttribute, runtime: runtime.ax) as Bool?) == true else {
            let cleanup = await closeOutputPopup(runtime: runtime, timing: timing, waitForSelfClose: false,
                                                 cleaner: popupCleaner)
            return refusal(.elementNotFound, "The popup entry for this destination is disabled or its "
                + "enabled state did not read; nothing was selected.",
                cleanup.merging(["menu_failure": "destination_entry_not_enabled", "menu_path": path]) { _, new in new })
        }

        extras["write_attempted"] = true
        extras["menu_path"] = path
        _ = AXHelpers.performAction(item, kAXPressAction, runtime: runtime.ax)
        let closed = await closeOutputPopup(runtime: runtime, timing: timing, waitForSelfClose: true,
                                            cleaner: popupCleaner)
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
        let deadline = Date().addingTimeInterval(Double(timing.readbackTimeoutMs) / 1000.0)
        repeat {
            let enumeration = AXLogicProElements.getMixerArea(runtime: runtime)
                .flatMap { AXLogicProElements.stripEnumeration(in: $0, runtime: runtime.ax) }
                .flatMap { $0.unreadableChildren == 0 ? $0 : nil }
            countAfter = enumeration?.strips.count
            afterLabel = nil
            if let enumeration, enumeration.strips.count == strips.count {
                afterLabel = AXLogicProElements.outputSlotDestination(in: enumeration.strips[index], runtime: runtime.ax)
            }
            after = afterLabel.flatMap(OutputAssignment.observed(slotLabel:))
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

    /// Picks the popup entry for `destination` by structure: the parent submenu that owns it, then
    /// exactly one entry under that parent. The root's checked entry echoes the CURRENT output
    /// (measured ko, 2026-09-28: `Stereo Output` before a change, `버스 1 → Aux 1` after one), so it is
    /// never a destination: `Stereo Output` and the pairs come from the Output submenu, the buses
    /// from the Bus submenu, and only `No Output` from the root. A title repeated under the same
    /// parent is refused. Nothing is chosen by position.
    static func outputMenuChoice(
        for destination: OutputAssignment,
        in root: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> OutputMenuChoice {
        let rootItems = titledMenuItems(of: root, runtime: runtime)
        switch destination {
        case .noOutput:
            let matches = rootItems.filter { AXLocalePolicy.noOutputLabel.matches($0.title, mode: .exact) && !$0.hasSubmenu }
            let offered = rootItems.filter { !$0.hasSubmenu }
                .compactMap { OutputAssignment.observed(slotLabel: $0.title)?.token }
            return single(matches.map { ($0.element, [$0.title]) }, offered: offered)
        case .stereoOutput:
            let parent = submenu(titled: AXLocalePolicy.outputPopupOutputSubmenuTitle, among: rootItems, runtime: runtime)
            guard case .found(let title, let submenu) = parent else { return parent.choice }
            let items = titledMenuItems(of: submenu, runtime: runtime).filter { !$0.hasSubmenu }
            let matches = items.filter { AXLocalePolicy.stereoOutputLabel.matches($0.title, mode: .exact) }
            let offered = items.compactMap { OutputAssignment.observed(slotLabel: $0.title)?.token }
            return single(matches.map { ($0.element, [title, $0.title]) }, offered: offered)
        case .bus(let number):
            let parent = submenu(titled: AXLocalePolicy.outputPopupBusSubmenuTitle, among: rootItems, runtime: runtime)
            guard case .found(let title, let submenu) = parent else { return parent.choice }
            let leaves = leafItems(under: submenu, path: [title], depth: 0, runtime: runtime)
            let matches = leaves.filter { OutputAssignment.busNumber(ofMenuItemTitle: $0.title) == number }
            let offered = leaves.compactMap { OutputAssignment.busNumber(ofMenuItemTitle: $0.title) }
                .map { OutputAssignment.bus($0).token }
            return single(matches.map { ($0.element, $0.path) }, offered: offered)
        case .physical(let first, let second):
            let parent = submenu(titled: AXLocalePolicy.outputPopupOutputSubmenuTitle, among: rootItems, runtime: runtime)
            guard case .found(let title, let submenu) = parent else { return parent.choice }
            let items = titledMenuItems(of: submenu, runtime: runtime).filter { !$0.hasSubmenu }
            let matches = items.filter {
                OutputAssignment.pairPorts(ofRuntimeLabel: $0.title).map { $0 == (first, second) } ?? false
            }
            let offered = items.compactMap { OutputAssignment.pairPorts(ofRuntimeLabel: $0.title) }
                .map { OutputAssignment.physical($0.0, $0.1).token }
            return single(matches.map { ($0.element, [title, $0.title]) }, offered: offered)
        }
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

    /// Every entry under `menu` that opens no further submenu, with the titles leading to it. The
    /// Bus submenu nests its higher buses one level down (`33 - 64 >`), so this descends.
    private static func leafItems(
        under menu: AXUIElement,
        path: [String],
        depth: Int,
        runtime: AXHelpers.Runtime
    ) -> [(element: AXUIElement, title: String, path: [String])] {
        guard depth <= 3 else { return [] }
        return titledMenuItems(of: menu, runtime: runtime).flatMap { item in
            if let submenu = item.submenu {
                return leafItems(under: submenu, path: path + [item.title], depth: depth + 1, runtime: runtime)
            }
            return [(item.element, item.title, path + [item.title])]
        }
    }

    private static func titledMenuItems(of menu: AXUIElement, runtime: AXHelpers.Runtime) -> [TitledMenuItem] {
        AXHelpers.getChildren(menu, runtime: runtime).compactMap { child in
            guard AXHelpers.getRole(child, runtime: runtime) == (kAXMenuItemRole as String),
                  let title = AXHelpers.getTitle(child, runtime: runtime),
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let submenus = AXHelpers.getChildren(child, runtime: runtime).filter {
                AXHelpers.getRole($0, runtime: runtime) == (kAXMenuRole as String)
            }
            return TitledMenuItem(element: child, title: title, submenu: submenus.first)
        }
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
        cleaner: PluginPopupMenuCleaner
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
