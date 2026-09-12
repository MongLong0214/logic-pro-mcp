import ApplicationServices
import AppKit
import Foundation

/// Plugin insert surface (plugin.insert): name to spec resolution and live AX/CGEvent insert via the target slot popup menu.
extension AccessibilityChannel {
    static func pluginInsertSpec(named rawName: String) -> PluginInsertSpec? {
        let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "gain":
            return PluginInsertSpec(
                canonicalName: "Gain",
                aliases: ["Gain"],
                menuPaths: [
                    ["Utility", "Gain", "스테레오"],
                    ["Utility", "Gain", "Stereo"],
                    ["유틸리티", "Gain", "스테레오"],
                    ["유틸리티", "Gain", "Stereo"],
                ]
            )
        case "compressor":
            return PluginInsertSpec(
                canonicalName: "Compressor",
                aliases: ["Compressor"],
                menuPaths: [
                    ["Dynamics", "Compressor", "스테레오"],
                    ["Dynamics", "Compressor", "Stereo"],
                    ["다이내믹스", "Compressor", "스테레오"],
                    ["다이내믹스", "Compressor", "Stereo"],
                ]
            )
        case "channel eq", "channeleq":
            return PluginInsertSpec(
                canonicalName: "Channel EQ",
                aliases: ["Channel EQ"],
                menuPaths: [
                    ["Channel EQ", "스테레오"],
                    ["Channel EQ", "Stereo"],
                    ["EQ", "Channel EQ", "스테레오"],
                    ["EQ", "Channel EQ", "Stereo"],
                ]
            )
        default:
            return nil
        }
    }

    static func defaultInsertPlugin(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        selectPlugin: (PluginInsertSpec, AXUIElement, String?, AXHelpers.Runtime) async -> MenuSelectionOutcome = selectLivePluginFromOpenMenu,
        rollback: () -> Bool = undoLastLogicAction,
        readbackTimeoutMs: Int = 2_000
    ) async -> ChannelResult {
        guard let trackRaw = params["track"] ?? params["track_index"] ?? params["index"],
              let track = Int(trackRaw), track >= 0 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "insert_plugin requires explicit 'track' (Int >= 0)"
            ))
        }
        guard let slotRaw = params["slot"] ?? params["insert"],
              let slotIndex = Int(slotRaw), slotIndex >= 0 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "insert_plugin requires explicit 'slot' (Int >= 0)"
            ))
        }
        // #871 — the channel configuration, when the caller names one. Optional: a strip that
        // offers exactly one, or offers the spec's preference, needs no choice made. It becomes
        // REQUIRED in effect on a strip that offers several and none preferred — the case that was
        // simply unreachable before, because the caller had no way to express it.
        let configuration = (params["configuration"] ?? params["channel_configuration"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pluginName = params["plugin_name"] ?? params["plugin"] ?? params["name"],
              let spec = pluginInsertSpec(named: pluginName) else {
            let requestedPluginName: Any
            if let rawPluginName = params["plugin_name"] ?? params["plugin"] ?? params["name"] {
                requestedPluginName = rawPluginName
            } else {
                requestedPluginName = NSNull()
            }
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "unsupported plugin for insert_plugin. Supported stock plugins: Gain, Compressor, Channel EQ",
                extras: ["requested_plugin_name": requestedPluginName]
            ))
        }
        guard let app = AXLogicProElements.appRoot(runtime: runtime),
              let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Cannot locate visible mixer for insert_plugin"
            ))
        }
        // #290: this operation indexes the strip list by ORDINAL, so it may only do so when that
        // list was read whole. A child whose role would not read is dropped by the filter and every
        // later strip moves down one — a request for track 0 then inserts into physical strip 1, and
        // no readback catches it because the readback reads the same shifted list. Resolve exactly,
        // or refuse.
        let enumeration = AXLogicProElements.stripEnumeration(in: mixer, runtime: runtime.ax)
        guard enumeration.unreadableChildren == 0 else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "refusing insert_plugin: \(enumeration.unreadableChildren) mixer child(ren) "
                    + "would not report a role, so the strip at index \(track) cannot be trusted to "
                    + "be the strip for that track — a dropped child shifts every later ordinal and "
                    + "no readback can catch the wrong target.",
                extras: [
                    "track": track,
                    "visible_strips": enumeration.strips.count,
                    "unreadable_mixer_children": enumeration.unreadableChildren,
                    "write_attempted": false,
                ]
            ))
        }
        let strips = enumeration.strips
        guard track < strips.count else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "track index out of range for visible mixer",
                extras: ["track": track, "visible_strips": strips.count]
            ))
        }
        let strip = strips[track]
        let slots = AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: runtime.ax)
        guard slotIndex < slots.count else {
            // #234 — a zero-slot strip names the insert_section_not_enumerable
            // condition (retaining visible_slots:0); an out-of-range index on a
            // non-empty chain keeps the generic wording.
            let detail = AccessibilityChannel.slotAddressingFailureDetail(
                requestedIndex: slotIndex, slotCount: slots.count
            )
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: slots.isEmpty
                    ? "\(detail.observed). \(AccessibilityChannel.insertSectionNotEnumerableRecoveryHint)"
                    : "plugin slot out of range for visible mixer strip",
                extras: ["track": track, "slot": slotIndex, "visible_slots": slots.count]
            ))
        }
        let targetSlot = slots[slotIndex]
        guard targetSlot.isEmpty else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "slot_occupied: refusing to replace existing plugin",
                extras: [
                    "track": track,
                    "slot": slotIndex,
                    "existing_plugin_name": targetSlot.name ?? NSNull(),
                ]
            ))
        }

        _ = AXHelpers.performAction(targetSlot.element, kAXPressAction, runtime: runtime.ax)
        try? await Task.sleep(for: .milliseconds(250))
        let selection = await selectPlugin(spec, app, configuration, runtime.ax)
        guard selection.succeeded else {
            dismissOpenMenu()
            // #855 — the failure names WHICH step failed and, for the one that actually bites, what
            // the menu offered instead. All three used to be "plugin menu selection failed", and a
            // caller reading that had no way to tell a wrong category name from a channel
            // configuration this strip does not have.
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: menuSelectionHint(selection, spec: spec),
                extras: [
                    "track": track,
                    "slot": slotIndex,
                    "plugin_name": spec.canonicalName,
                    "menu_failure": menuFailureLabel(selection),
                    "menu_paths_tried": spec.menuPaths.map { $0.joined(separator: " > ") },
                    "menu_leaf_offered": menuLeafOffered(selection),
                    "requested_configuration": configuration ?? "",
                ]
            ))
        }

        let observed = await pollPluginSlotName(
            track: track,
            slot: slotIndex,
            runtime: runtime,
            timeoutMs: readbackTimeoutMs
        )
        var extras: [String: Any] = [
            "track": track,
            "slot": slotIndex,
            "plugin_name": spec.canonicalName,
            "observed_plugin_name": observed ?? NSNull(),
            "verify_source": "ax_plugin_slot",
            // #855 — WHICH channel configuration was pressed. It is not always the one the spec
            // prefers: on a mono strip the only configuration on offer is `Mono`, and reporting the
            // request back instead of the choice would hide the entire behaviour this fix adds.
            "menu_leaf_chosen": menuLeafChosen(selection),
        ]
        if let observed, spec.matches(observed) {
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        extras["rollback_attempted"] = true
        // #872 — the rollback is CONFIRMED, not assumed. `undoLastLogicAction` posts a Cmd+Z and
        // returns true unconditionally, so reporting its return value meant `rollback_succeeded`
        // said "a key event was posted" rather than "the insert was undone". A rollback is what a
        // caller trusts when a verified write fails its readback; one that cannot fail is worse
        // than none, because the envelope says the project was put back when nobody looked.
        //
        // The slot is the readback this operation already has. After the undo it is re-read: the
        // insert is undone when the slot no longer carries the plug-in that was just put there.
        // That is an observation of the world, and it can say no.
        let rollbackPosted = rollback()
        let slotAfterRollback = await pollPluginSlotName(
            track: track,
            slot: slotIndex,
            runtime: runtime,
            timeoutMs: readbackTimeoutMs
        )
        let rolledBack = slotAfterRollback.map { !spec.matches($0) } ?? true
        extras["rollback_action_posted"] = rollbackPosted
        extras["rollback_observed_plugin_name"] = slotAfterRollback ?? NSNull()
        extras["rollback_verify_source"] = "ax_plugin_slot"
        extras["rollback_succeeded"] = rolledBack
        extras["requested_plugin_name"] = spec.canonicalName
        if observed == nil {
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: extras
            ))
        }
        return .success(HonestContract.encodeStateB(
            reason: .readbackMismatch,
            extras: extras
        ))
    }

    private static func pollPluginSlotName(
        track: Int,
        slot: Int,
        runtime: AXLogicProElements.Runtime,
        timeoutMs: Int
    ) async -> String? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if let mixer = AXLogicProElements.getMixerArea(runtime: runtime) {
                let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax)
                if track < strips.count {
                    let slots = AXLogicProElements.audioPluginInsertSlots(in: strips[track], runtime: runtime.ax)
                    if slot < slots.count, let name = slots[slot].name {
                        return name
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// The configuration actually pressed, or "" when nothing was.
    static func menuLeafChosen(_ outcome: MenuSelectionOutcome) -> String {
        guard case .selected(let step) = outcome, case .pressed(let leaf) = step else { return "" }
        return leaf
    }

    /// A label a caller can branch on, as distinct from the prose hint.
    static func menuFailureLabel(_ outcome: MenuSelectionOutcome) -> String {
        switch outcome {
        case .selected: return "none"
        case .rootMenuNotFound: return "root_menu_not_found"
        case .noPathWalked(let attempts):
            // The most informative ending wins. A leaf that was REACHED and read says more than a
            // category name that did not match, because reaching it proves the category walked.
            if attempts.contains(where: { if case .leafMissing = $0 { return true } else { return false } }) {
                return "leaf_not_offered_by_this_strip"
            }
            if attempts.contains(where: { if case .pressRefused = $0 { return true } else { return false } }) {
                return "leaf_press_refused"
            }
            if attempts.contains(where: { if case .submenuNeverAppeared = $0 { return true } else { return false } }) {
                return "submenu_never_appeared"
            }
            return "no_path_segment_matched"
        }
    }

    /// What the leaf menu actually contained, when one was reached. Empty when none was.
    static func menuLeafOffered(_ outcome: MenuSelectionOutcome) -> [String] {
        guard case .noPathWalked(let attempts) = outcome else { return [] }
        for attempt in attempts {
            if case .leafMissing(_, let offered) = attempt, !offered.isEmpty { return offered }
        }
        return []
    }

    static func menuSelectionHint(_ outcome: MenuSelectionOutcome, spec: PluginInsertSpec) -> String {
        switch outcome {
        case .selected:
            return ""
        case .rootMenuNotFound:
            return "the plug-in menu never opened: the slot was pressed and no menu carrying the "
                + "audio plug-in library was found"
        case .noPathWalked:
            let offered = menuLeafOffered(outcome)
            if !offered.isEmpty {
                return "\(spec.canonicalName) was found, but this strip offers "
                    + "\(offered.joined(separator: ", ")) for it — the last segment of a menu path is "
                    + "the CHANNEL CONFIGURATION, which belongs to the strip and not to the request. "
                    + "Name one with 'configuration' to choose; this operation will not pick a "
                    + "channel layout on your behalf"
            }
            return "no configured menu path matched: none of "
                + spec.menuPaths.map { $0.joined(separator: " > ") }.joined(separator: " | ")
                + " walked this menu"
        }
    }

    /// #855 — what happened to the whole attempt, not just whether it worked.
    enum MenuSelectionOutcome {
        case selected(MenuPathOutcome)
        /// The slot was pressed and no menu matching the audio-plug-in root ever appeared.
        case rootMenuNotFound
        /// The root was found and every configured path was tried; here is how each ended.
        case noPathWalked([MenuPathOutcome])

        var succeeded: Bool {
            if case .selected = self { return true }
            return false
        }
    }

    private static func selectLivePluginFromOpenMenu(
        spec: PluginInsertSpec,
        app: AXUIElement,
        configuration: String?,
        runtime: AXHelpers.Runtime
    ) async -> MenuSelectionOutcome {
        guard let rootMenu = findAudioPluginRootMenu(in: app, runtime: runtime) else {
            return .rootMenuNotFound
        }
        var attempts: [MenuPathOutcome] = []
        for path in spec.menuPaths {
            let outcome = await pressMenuPath(
                path, rootMenu: rootMenu, configuration: configuration, runtime: runtime
            )
            attempts.append(outcome)
            if case .pressed = outcome { return .selected(outcome) }
        }
        return .noPathWalked(attempts)
    }

    /// Why one path did not walk, in the words the failure needs.
    ///
    /// #855 — every one of these used to be the single sentence "plugin menu selection failed",
    /// which is why locating the real cause needed a replication of this algorithm against the live
    /// tree rather than a reading of a response. They are distinguished now because they call for
    /// different fixes: a missing SEGMENT is a wrong category name, a missing LEAF is a channel
    /// configuration this strip does not offer, and no root at all is the menu never having opened.
    enum MenuPathOutcome: Equatable {
        case pressed(leaf: String)
        case segmentMissing(String)
        case submenuNeverAppeared(String)
        /// The leaf menu was reached and read; `offered` is what it actually contained.
        case leafMissing(wanted: String, offered: [String])
        case pressRefused(leaf: String)
    }

    /// The item to press in a leaf menu, given what the caller preferred.
    ///
    /// #855 — the last segment of a configured path is the CHANNEL CONFIGURATION (`Stereo`,
    /// `Mono`, …), and that is a property of the STRIP, not of the request. Measured 2026-09-12: on
    /// a mono audio track the Compressor submenu offers exactly `["Mono"]`, so all four configured
    /// paths — each ending in `Stereo` or `스테레오` — missed, and the operation refused to insert a
    /// plug-in that was sitting right there. On a stereo strip the same paths walk end to end.
    ///
    /// So the preference is honoured when the strip offers it, and a menu with exactly ONE item is
    /// taken because there is no choice to make. Anything else refuses: picking the first of several
    /// unrequested configurations would be choosing a channel layout on the operator's behalf.
    static func leafChoice(preferred: String, offered: [String], requested: String? = nil) -> String? {
        // #871 — the CALLER's configuration outranks the spec's preference, and is honoured only
        // when the strip actually offers it. A requested value the strip does not have is refused
        // rather than falling back: the caller named a layout, and quietly giving them a different
        // one is the failure this whole path exists to avoid.
        if let requested, !requested.isEmpty {
            return offered.contains(requested) ? requested : nil
        }
        if offered.contains(preferred) { return preferred }
        return offered.count == 1 ? offered[0] : nil
    }

    private static func pressMenuPath(
        _ path: [String],
        rootMenu: AXUIElement,
        configuration: String?,
        runtime: AXHelpers.Runtime
    ) async -> MenuPathOutcome {
        guard !path.isEmpty else { return .segmentMissing("") }
        var menu = rootMenu
        for segment in path.dropLast() {
            guard let item = menuItem(named: segment, in: menu, runtime: runtime) else {
                return .segmentMissing(segment)
            }
            if AXHelpers.getChildren(item, runtime: runtime).first(where: {
                (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXMenuRole as String)
            }) == nil {
                _ = AXHelpers.performAction(item, kAXPressAction, runtime: runtime)
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let submenu = AXHelpers.getChildren(item, runtime: runtime).first(where: {
                (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXMenuRole as String)
            }) else {
                return .submenuNeverAppeared(segment)
            }
            menu = submenu
        }
        let preferred = path[path.count - 1]
        let offered = AXHelpers.getChildren(menu, runtime: runtime)
            .filter { (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXMenuItemRole as String) }
            .compactMap { AXHelpers.getTitle($0, runtime: runtime) }
        guard let wanted = leafChoice(preferred: preferred, offered: offered, requested: configuration),
              let leaf = menuItem(named: wanted, in: menu, runtime: runtime) else {
            return .leafMissing(wanted: preferred, offered: offered)
        }
        return AXHelpers.performAction(leaf, kAXPressAction, runtime: runtime)
            ? .pressed(leaf: wanted)
            : .pressRefused(leaf: wanted)
    }

    private static func menuItem(
        named title: String,
        in menu: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        AXHelpers.getChildren(menu, runtime: runtime).first {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXMenuItemRole as String)
                && AXHelpers.getTitle($0, runtime: runtime) == title
        }
    }

    private static func findAudioPluginRootMenu(
        in element: AXUIElement,
        runtime: AXHelpers.Runtime,
        depth: Int = 0
    ) -> AXUIElement? {
        guard depth <= 8 else { return nil }
        if (AXHelpers.getRole(element, runtime: runtime) ?? "") == (kAXMenuRole as String) {
            let titles = Set(AXHelpers.getChildren(element, runtime: runtime).compactMap {
                AXHelpers.getTitle($0, runtime: runtime)
            })
            if titles.contains("Audio Units"),
               titles.contains("Utility") || titles.contains("유틸리티"),
               titles.contains("Channel EQ") {
                return element
            }
        }
        for child in AXHelpers.getChildren(element, runtime: runtime) {
            if let found = findAudioPluginRootMenu(in: child, runtime: runtime, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private static func dismissOpenMenu() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func undoLastLogicAction() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

}
