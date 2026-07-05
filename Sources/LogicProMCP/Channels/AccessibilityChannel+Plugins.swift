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
        selectPlugin: (PluginInsertSpec, AXUIElement, AXHelpers.Runtime) async -> Bool = selectLivePluginFromOpenMenu,
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
        let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax)
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
        guard await selectPlugin(spec, app, runtime.ax) else {
            dismissOpenMenu()
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "plugin menu selection failed",
                extras: ["track": track, "slot": slotIndex, "plugin_name": spec.canonicalName]
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
        ]
        if let observed, spec.matches(observed) {
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        extras["rollback_attempted"] = true
        extras["rollback_succeeded"] = rollback()
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

    private static func selectLivePluginFromOpenMenu(
        spec: PluginInsertSpec,
        app: AXUIElement,
        runtime: AXHelpers.Runtime
    ) async -> Bool {
        guard let rootMenu = findAudioPluginRootMenu(in: app, runtime: runtime) else {
            return false
        }
        for path in spec.menuPaths {
            if await pressMenuPath(path, rootMenu: rootMenu, runtime: runtime) {
                return true
            }
        }
        return false
    }

    private static func pressMenuPath(
        _ path: [String],
        rootMenu: AXUIElement,
        runtime: AXHelpers.Runtime
    ) async -> Bool {
        guard !path.isEmpty else { return false }
        var menu = rootMenu
        for segment in path.dropLast() {
            guard let item = menuItem(named: segment, in: menu, runtime: runtime) else {
                return false
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
                return false
            }
            menu = submenu
        }
        guard let leaf = menuItem(named: path[path.count - 1], in: menu, runtime: runtime) else {
            return false
        }
        return AXHelpers.performAction(leaf, kAXPressAction, runtime: runtime)
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
