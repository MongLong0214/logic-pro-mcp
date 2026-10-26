import ApplicationServices
import Foundation

/// Verified-plugin surface (`logic_plugins.*`) channel implementation.
///
/// T3 scope (requirements §8 / development board T3):
///   - `plugin.get_inventory` — fully deterministic, drift-safe inventory built
///     from the T2 `audioPluginInsertSlots` enumerator (R3, AC2/AC12/AC22).
///   - `plugin.set_param_verified` — R6 precedence through live AX write/readback
///     for verified write-capable parameters (currently Compressor threshold).
///     Unsupported or unverified parameters fail closed at capability preflight.
///   - `plugin.insert_verified` — live validation gates (schema/mode/path/
///     identity/inventory-complete/slot-empty) followed by the
///     target slot's own popup menu, driven by AX actions. The
///     slot-popup path preserves the target slot context, and
///     a post-insert `get_inventory` readback is the SOLE State A precondition —
///     State A is reachable only when the requested plugin is observed at the
///     requested slot, so a false verified insert is structurally impossible
///     (T6). Any other outcome fails closed with a terminal HC v2 State C.
///
/// NOTE: `set_param_verified` is the only live AX parameter write/readback (State
/// A) path; `insert_verified` reaches State A solely through its post-insert
/// inventory readback. Every uncertain or mismatched outcome fails closed.
extension AccessibilityChannel {

    // MARK: - get_inventory (R3, AC2/AC12/AC22)

    struct MixerRevealResult: Sendable {
        let attempted: Bool
        let alreadyVisible: Bool
        let strategies: [String]
        let menuItemFound: Bool
        let menuClicked: Bool
        let keySent: Bool
        let mixerVisible: Bool
        /// A Mixer-named container was found but its children did not read (#982). The reveal
        /// stops there: the Mixer may already be showing, and View > Show Mixer or key 7 could
        /// hide it again.
        var mixerChildrenUnread = false
        var windowUnavailable = false

        static func notRevealed(windowUnavailable: Bool = false) -> Self {
            .init(attempted:false, alreadyVisible:false, strategies:[], menuItemFound:false,
                menuClicked:false, keySent:false, mixerVisible:false, windowUnavailable:windowUnavailable)
        }

        static let alreadyVisible = MixerRevealResult(
            attempted: false,
            alreadyVisible: true,
            strategies: [],
            menuItemFound: false,
            menuClicked: false,
            keySent: false,
            mixerVisible: true
        )

        static let childrenUnreadBeforeReveal = MixerRevealResult(
            attempted: false,
            alreadyVisible: false,
            strategies: [],
            menuItemFound: false,
            menuClicked: false,
            keySent: false,
            mixerVisible: false,
            mixerChildrenUnread: true
        )
    }

    typealias MixerRevealAction = @Sendable (
        _ runtime: AXLogicProElements.Runtime
    ) async -> (mixer: AXUIElement?, result: MixerRevealResult)

    /// Build the `plugins[]` array for one strip from its drift-safe slot
    /// enumeration. Pure + deterministic so it can be unit-tested against a
    /// strip element without a full mixer fixture.
    ///
    /// Per AC22 EVERY item carries `insert`/`read_status`/`occupied`/`name`/
    /// `plugin_id`/`bypassed` — value-less fields are explicit `NSNull`, never
    /// omitted, so a caller can tell "field absent" from "value unknown".
    static func pluginInventoryItems(
        for slots: [AXLogicProElements.PluginInsertSlot]
    ) -> (items: [[String: Any]], complete: Bool) {
        var items: [[String: Any]] = []
        var complete = true
        for slot in slots {
            var item: [String: Any] = [
                "insert": slot.index,
                "read_status": slot.readStatus.rawValue,
                "occupied": slot.occupied,
            ]
            switch slot.readStatus {
            case .empty:
                item["name"] = NSNull()
                item["plugin_id"] = NSNull()
                item["bypassed"] = NSNull()
            case .occupiedUnreadable:
                complete = false
                item["name"] = NSNull()
                item["plugin_id"] = NSNull()
                item["bypassed"] = NSNull()
            case .unclassified:
                // The strip's slots could not be put in screen order or told apart from its
                // instrument slot: the name is shown, but nothing here is an addressable insert.
                complete = false
                item["name"] = slot.name ?? NSNull()
                item["plugin_id"] = NSNull()
                item["bypassed"] = NSNull()
            case .occupiedReadable:
                let name = slot.name
                item["name"] = name ?? NSNull()
                // canonical match against the allowlist, else null (an occupied
                // readable slot whose name is not an allowlisted stock plugin is
                // a real slot but not a verified-write target — §5.2).
                item["plugin_id"] = name.flatMap(VerifiedPluginCatalog.pluginID(forObservedName:)) ?? NSNull()
                item["bypassed"] = slot.isBypassed ?? NSNull()
            }
            items.append(item)
        }
        return (items, complete)
    }

    // MARK: - #234 zero-slot honesty (shared)

    /// Recovery hint for a strip that exposes zero enumerable insert slots. Named
    /// once and shared by `get_inventory`'s State B branch and every write-path
    /// slot-addressing guard so the two likely causes are always spelled out
    /// identically: the mixer's AX layout drifted, or the addressed strip has no
    /// insert section (Master/VCA). #234 D6 — a single retry-able reason, never a
    /// `strip_has_no_inserts` confidence we cannot actually verify.
    static let insertSectionNotEnumerableRecoveryHint =
        "No insert slots were enumerable on the located mixer strip. This usually "
        + "means the mixer's AX layout drifted (reopen it via View > Show Mixer and "
        + "retry) or the addressed strip has no insert section (e.g. a Master or VCA "
        + "strip). Confirm the target track's channel strip shows an Audio FX "
        + "section, then retry."

    struct SlotAddressingFailureDetail {
        let observed: String
        let recoveryHint: String?
    }

    /// Shared slot-addressing failure detail (#234). A strip that enumerates ZERO
    /// insert slots is the Logic 12.3 mixer-drift signature: the pre-fix
    /// "slot N is out of range (0 slots)" wording hid a blind read behind a
    /// looks-like-a-bad-index message. When the chain is empty the observation
    /// names the real condition (insert_section_not_enumerable semantics) and
    /// carries the recovery hint; a non-empty chain addressed past its end keeps
    /// the plain wording and no hint. Write paths keep their existing State C error
    /// code — only the diagnostics change, never the fail-closed verdict.
    static func slotAddressingFailureDetail(
        requestedIndex: Int,
        slotCount: Int
    ) -> SlotAddressingFailureDetail {
        guard slotCount == 0 else {
            return SlotAddressingFailureDetail(
                observed: "slot \(requestedIndex) is out of range (\(slotCount) slots)",
                recoveryHint: nil
            )
        }
        return SlotAddressingFailureDetail(
            observed: "the located strip exposed no enumerable insert slots (0 slots), "
                + "so its insert section could not be read",
            recoveryHint: insertSectionNotEnumerableRecoveryHint
        )
    }

    /// `plugin.get_inventory` channel entry. Non-mutating: never carries
    /// `write_source`/`verify_source`. Returns a `complete:true|false` snapshot
    /// (HC-v2-adjacent inventory shape) when the strip can be enumerated, or
    /// State B `readback_unavailable` when the AX insert subtree cannot be read
    /// at all (AC2).
    static func defaultGetPluginInventory(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        revealMixer: MixerRevealAction = ensureMixerAreaVisibleForInventory
    ) async -> ChannelResult {
        let operation = "logic_plugins.get_inventory"
        guard let trackRaw = params["track"] ?? params["track_index"] ?? params["index"],
              let track = Int(trackRaw), track >= 0 else {
            return .error(HonestContract.encodeV2StateC(
                error: .invalidParams,
                extras: [
                    "operation": operation,
                    "what_was_attempted": "read insert chain inventory",
                    "what_was_observed": "missing or invalid 'track' (expected Int >= 0)",
                    "safe_to_retry": false,
                ]
            ))
        }

        let fetchedAt = ISO8601DateFormatter.cacheFormatter.string(from: Date())
        let revealRequested: Bool
        switch params["reveal_mixer"] {
        case nil, "false": revealRequested = false
        case "true": revealRequested = true
        default:
            return .error(HonestContract.encodeV2StateC(error:.invalidParams,
                extras:["operation":operation,"what_was_observed":"reveal_mixer must be a Boolean",
                    "safe_to_retry":false]))
        }

        // The AX insert subtree is unreadable when the mixer or the requested
        // strip cannot be located — there is nothing to enumerate, so this is
        // State B `readback_unavailable` rather than a fabricated empty chain.
        let ensuredMixer: (mixer: AXUIElement?, result: MixerRevealResult)
        if let observed = mixerWithoutReveal(runtime:runtime) {
            ensuredMixer = observed
        } else if revealRequested, inventoryRevealWindow(runtime:runtime) != nil {
            ensuredMixer = await revealMixer(runtime)
        } else {
            ensuredMixer = (nil,.notRevealed(windowUnavailable:inventoryRevealWindow(runtime:runtime) == nil))
        }
        let reveal = ensuredMixer.result
        // #982: children that did not read are unknown. Before, they read as no Mixer at all, as a
        // Mixer with no strips ("track index is not present") or as a strip with no inserts.
        func mixerChildrenUnread() -> ChannelResult {
            .success(HonestContract.encodeV2StateB(
                reason: .readbackUnavailable,
                extras: [
                    "operation": operation,
                    "track": track,
                    "plugins_source": "ax",
                    "plugins_fetched_at": fetchedAt,
                    "plugins_unknown_reason": "ax_subtree_unreadable",
                    "mixer_reveal_attempted": reveal.attempted,
                    "mixer_reveal_strategies": reveal.strategies,
                    "what_was_attempted": reveal.attempted
                        ? "reveal the mixer, then read insert chain inventory for track \(track)"
                        : "read insert chain inventory for track \(track)",
                    "what_was_observed": "the mixer's children did not read",
                    "safe_to_retry": true,
                ]
            ))
        }
        guard let mixer = ensuredMixer.mixer else {
            if reveal.mixerChildrenUnread { return mixerChildrenUnread() }
            return .success(HonestContract.encodeV2StateB(
                reason: .readbackUnavailable,
                extras: [
                    "operation": operation,
                    "track": track,
                    "plugins_source": "ax",
                    "plugins_fetched_at": fetchedAt,
                    "plugins_unknown_reason": reveal.windowUnavailable ? "logic_window_unavailable" : "mixer_not_visible",
                    "mixer_reveal_attempted": reveal.attempted,
                    "mixer_reveal_strategies": reveal.strategies,
                    "mixer_reveal_menu_item_found": reveal.menuItemFound,
                    "mixer_reveal_menu_clicked": reveal.menuClicked,
                    "mixer_reveal_key_sent": reveal.keySent,
                    "what_was_attempted": reveal.attempted
                        ? "reveal the mixer, then read insert chain inventory for track \(track)"
                        : "read insert chain inventory for track \(track)",
                    "what_was_observed": reveal.windowUnavailable
                        ? "Logic's window or modal state could not be observed safely; no Mixer reveal was attempted"
                        : reveal.attempted
                        ? "the mixer remained hidden after the reveal attempt, so the insert subtree could not be read"
                        : "mixer area was not locatable in the AX tree",
                    "recovery_hint": "Open View > Show Mixer in Logic Pro and retry the inventory read.",
                    "safe_to_retry": true,
                ]
            ))
        }
        guard AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax) != nil else {
            return mixerChildrenUnread()
        }
        var bindingRefusal: String?
        var failingHeader: Int?
        guard let target = AXPluginTrackBinding.resolve(track: track, mixer: mixer, runtime: runtime,
            onRefusal:{ bindingRefusal = $0 }, onRefusalHeaderIndex:{ failingHeader = $0 }) else {
            return .success(HonestContract.encodeV2StateB(
                reason: .readbackUnavailable,
                extras: [
                    "operation": operation,
                    "track": track,
                    "plugins_source": "ax",
                    "plugins_fetched_at": fetchedAt,
                    "plugins_unknown_reason": "ax_subtree_unreadable",
                    "binding_refusal_reason": bindingRefusal ?? "binding_unavailable",
                    "binding_refusal_header_index": failingHeader.map { $0 as Any } ?? NSNull(),
                    "what_was_attempted": "read insert chain inventory for track \(track)",
                    "what_was_observed": pluginTrackBindingFailureDetail(mixer: mixer, runtime: runtime),
                    "safe_to_retry": true,
                ]
            ))
        }

        guard let slots = AXLogicProElements.audioPluginInsertSlots(in: target.strip, runtime: runtime.ax) else {
            return .success(HonestContract.encodeV2StateB(
                reason: .readbackUnavailable,
                extras: [
                    "operation": operation,
                    "track": track,
                    "plugins_source": "ax",
                    "plugins_fetched_at": fetchedAt,
                    "plugins_unknown_reason": "ax_subtree_unreadable",
                    "what_was_attempted": "read insert chain inventory for track \(track)",
                    "what_was_observed": "the mixer strip for track \(track) was located but its children did not read",
                    "safe_to_retry": true,
                ]
            ))
        }
        // #234 honesty gate — a visible insert section always exposes at least the
        // empty append row, so an enumeration of ZERO slots means the strip could
        // not be read (12.3 mixer AX-layout drift, or a strip type without an insert
        // section such as Master/VCA), NOT a verified-empty chain. Encoding State A
        // with plugins:[] here would be a false verified-empty read; degrade to
        // State B so future drift can never masquerade as verified knowledge.
        guard !slots.isEmpty else {
            return .success(HonestContract.encodeV2StateB(
                reason: .readbackUnavailable,
                extras: [
                    "operation": operation,
                    "track": track,
                    "plugins_source": "ax",
                    "plugins_fetched_at": fetchedAt,
                    "plugins_unknown_reason": "insert_section_not_enumerable",
                    "mixer_reveal_attempted": reveal.attempted,
                    "mixer_reveal_strategies": reveal.strategies,
                    "what_was_attempted": "read insert chain inventory for track \(track)",
                    "what_was_observed": "the mixer strip for track \(track) was located but "
                        + "exposed 0 enumerable insert-slot elements",
                    "recovery_hint": insertSectionNotEnumerableRecoveryHint,
                    "safe_to_retry": true,
                ]
            ))
        }
        // #1228: occupied offscreen rows may expose only "audio plug-in".
        // Neither that placeholder nor its checkbox proves a name/bypass value.
        if slots.contains(where: { slot in
            guard slot.occupied,
                  let description = AXHelpers.getDescription(slot.element, runtime: runtime.ax) else { return false }
            return AXLogicProElements.isPluginSlotPlaceholderName(description)
        }) {
            return .success(HonestContract.encodeV2StateB(
                reason: .readbackUnavailable,
                extras: [
                    "operation": operation,
                    "track": track,
                    "plugins_source": "ax",
                    "plugins_fetched_at": fetchedAt,
                    "plugins_unknown_reason": "occupied_insert_name_unreadable",
                    "mixer_reveal_attempted": reveal.attempted,
                    "mixer_reveal_strategies": reveal.strategies,
                    "what_was_observed": "an occupied insert exposed a generic slot label instead of its plugin name",
                    "recovery_hint": "Scroll the target channel strip into the Mixer view and retry.",
                    "safe_to_retry": true,
                ]
            ))
        }
        let built = pluginInventoryItems(for: slots)

        return .success(HonestContract.encodeV2StateA(extras: [
            "operation": operation,
            "track": track,
            "plugins_source": "ax",
            "plugins_fetched_at": fetchedAt,
            "plugins_unknown_reason": NSNull(),
            "mixer_reveal_attempted": reveal.attempted,
            "mixer_reveal_strategies": reveal.strategies,
            "complete": built.complete,
            "track_name": target.trackName,
            "mixer_strip_index": target.mixerStripIndex,
            "plugins": built.items,
        ]))
    }

    /// Poll window for the mixer area to appear after a reveal action. #142
    /// lengthened this from 1500ms: Logic's mixer pane slide-in can exceed 1.5s
    /// on a cold window, so the previous timeout fail-closed to State B
    /// `mixer_not_visible` even when the reveal eventually succeeded.
    static let mixerRevealPollTimeoutMs = 2_500

    /// The reveal's first step, which actuates nothing: the Mixer when it is found, or the unread
    /// result when a Mixer-named container's children did not read (#982). Nil means no Mixer was
    /// found, and only then may a reveal run.
    static func mixerWithoutReveal(
        runtime: AXLogicProElements.Runtime
    ) -> (mixer: AXUIElement?, result: MixerRevealResult)? {
        let lookup = AXLogicProElements.mixerAreaLookup(runtime: runtime)
        if let mixer = lookup.mixer {
            return (mixer, .alreadyVisible)
        }
        if lookup.childrenUnread {
            return (nil, .childrenUnreadBeforeReveal)
        }
        return nil
    }

    /// A missing Mixer is hidden only when its owning Logic window is positively observable.
    /// Unknown/locked-window and modal observations never authorize a reveal or fallback key.
    static func inventoryRevealWindow(runtime: AXLogicProElements.Runtime) -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot(runtime:runtime),
              case .success(.elements(let windows)) = AXHelpers.getAXUIElementArrayRead(app,kAXWindowsAttribute as String,runtime:runtime.ax),
              !windows.isEmpty,
              case .found(let window) = AXLogicProElements.arrangeWindowVerifiedRead(runtime:runtime),
              windows.contains(where:{ CFEqual($0,window) }),
              AXHelpers.getRole(window,runtime:runtime.ax) == kAXWindowRole as String,
              case .success = AXHelpers.childrenResult(window,runtime:runtime.ax),
              !AXLogicProElements.dialogPresenceReason(runtime:runtime).isBlocked else { return nil }
        return window
    }

    /// The actions the menu-click reveal takes outside its AX runtime. Production by default. A
    /// test injects all four, so the reveal's branches after an actuation (#982) run without
    /// activating, keying or raising the running Logic.
    struct MenuClickActuators: Sendable {
        let activateLogic: @Sendable () -> Bool
        let postKeyEvent: @Sendable (CGKeyCode, CGEventFlags, pid_t) -> Bool
        let pressEscape: @Sendable () -> Void
        let raiseMixerWindow: @Sendable () -> Bool

        static let production = Self(
            activateLogic: { ProcessUtils.Runtime.production.activateLogicPro() },
            postKeyEvent: { CGEventChannel.Runtime.production.postKeyEvent($0, $1, $2) },
            pressEscape: { AXMouseHelper.pressEscape() },
            raiseMixerWindow: { forceMixerWindowFront() }
        )
    }

    static func ensureMixerAreaVisibleForInventory(
        runtime: AXLogicProElements.Runtime
    ) async -> (mixer: AXUIElement?, result: MixerRevealResult) {
        await ensureMixerAreaVisibleForInventory(runtime: runtime, actuators: .production)
    }

    static func ensureMixerAreaVisibleForInventory(
        runtime: AXLogicProElements.Runtime,
        actuators: MenuClickActuators
    ) async -> (mixer: AXUIElement?, result: MixerRevealResult) {
        if let found = mixerWithoutReveal(runtime: runtime) {
            return found
        }
        guard let window = inventoryRevealWindow(runtime:runtime) else {
            return (nil,.notRevealed(windowUnavailable:true))
        }
        func windowCurrent() -> Bool {
            inventoryRevealWindow(runtime:runtime).map { CFEqual($0,window) } == true
        }

        // #142 — reveal-reliability hardening. The deterministic AX menu-click
        // path (View > Show Mixer) is PREFERRED and retried (it targets the
        // exact menu item and verifies enabled-state) BEFORE the flaky
        // cgevent key-7 fallback, which blindly posts a key with no targeting
        // and was the dominant cause of the v43 `mixer_not_visible` State B.
        // The AX menu path also bookends the fallback: a final menu retry runs
        // after key-7 in case the keypress shifted focus enough for the menu to
        // resolve. `strategies` honestly records every distinct path tried.
        var strategies: [String] = []
        func unreadAfterReveal(
            itemFound: Bool, menuClicked: Bool, keySent: Bool
        ) -> (mixer: AXUIElement?, result: MixerRevealResult) {
            (nil, MixerRevealResult(
                attempted: true,
                alreadyVisible: false,
                strategies: strategies,
                menuItemFound: itemFound,
                menuClicked: menuClicked,
                keySent: keySent,
                mixerVisible: false,
                mixerChildrenUnread: true
            ))
        }
        guard windowCurrent(), actuators.activateLogic(), windowCurrent() else {
            return (nil,.notRevealed(windowUnavailable:true))
        }

        // Strategy 1 (preferred): AX menu-click, with retry.
        let menuAttempt = await clickTopLevelMenuItemViaAXMenuClick(
            candidates: [AXLocalePolicy.showMixerMenuPath],
            runtime: runtime,
            maxEnabledRetries: 2,
            focusBetweenAttempts: false,
            actuators: actuators,
            permittingActuation: windowCurrent
        )
        var itemFound = menuAttempt.itemFound
        var menuClicked = menuAttempt.clicked
        if menuAttempt.clicked {
            strategies.append("ax_menu_view_show_mixer")
            let polled = await pollMixerAreaVisible(runtime: runtime, timeoutMs: mixerRevealPollTimeoutMs,
                in:window, permittingObservation:windowCurrent)
            guard windowCurrent() else {
                return (nil,.init(attempted:true,alreadyVisible:false,strategies:strategies,
                    menuItemFound:itemFound,menuClicked:true,keySent:false,mixerVisible:false,windowUnavailable:true))
            }
            if polled.childrenUnread {
                return unreadAfterReveal(itemFound: itemFound, menuClicked: true, keySent: false)
            }
            if let mixer = polled.mixer {
                return (
                    mixer,
                    MixerRevealResult(
                        attempted: true,
                        alreadyVisible: false,
                        strategies: strategies,
                        menuItemFound: itemFound,
                        menuClicked: true,
                        keySent: false,
                        mixerVisible: true
                    )
                )
            }
        }

        // Strategy 2 (fallback): cgevent key-7 (View > Show Mixer default key).
        var keySent = false
        if windowCurrent(), let pid = runtime.logicProPID(),
           actuators.postKeyEvent(7, [], pid) {
            keySent = true
            strategies.append("cgevent_x")
            let polled = await pollMixerAreaVisible(runtime: runtime, timeoutMs: mixerRevealPollTimeoutMs,
                in:window, permittingObservation:windowCurrent)
            guard windowCurrent() else {
                return (nil,.init(attempted:true,alreadyVisible:false,strategies:strategies,
                    menuItemFound:itemFound,menuClicked:menuClicked,keySent:true,mixerVisible:false,windowUnavailable:true))
            }
            if polled.childrenUnread {
                return unreadAfterReveal(itemFound: itemFound, menuClicked: menuClicked, keySent: true)
            }
            if let mixer = polled.mixer {
                return (
                    mixer,
                    MixerRevealResult(
                        attempted: true,
                        alreadyVisible: false,
                        strategies: strategies,
                        menuItemFound: itemFound,
                        menuClicked: menuClicked,
                        keySent: true,
                        mixerVisible: true
                    )
                )
            }
        }

        // Strategy 3 (final AX menu retry): the deterministic path again, in
        // case key-7 restored focus the menu needs to resolve. Only attempted
        // when an earlier AX click did not already land the mixer.
        guard windowCurrent() else {
            return (nil,.init(attempted:true,alreadyVisible:false,strategies:strategies,
                menuItemFound:itemFound,menuClicked:menuClicked,keySent:keySent,mixerVisible:false,windowUnavailable:true))
        }
        let menuRetry = await clickTopLevelMenuItemViaAXMenuClick(
            candidates: [AXLocalePolicy.showMixerMenuPath],
            runtime: runtime,
            maxEnabledRetries: 1,
            focusBetweenAttempts: true,
            actuators: actuators,
            permittingActuation: windowCurrent
        )
        itemFound = itemFound || menuRetry.itemFound
        if menuRetry.clicked {
            menuClicked = true
            if !strategies.contains("ax_menu_view_show_mixer_retry") {
                strategies.append("ax_menu_view_show_mixer_retry")
            }
            let polled = await pollMixerAreaVisible(runtime: runtime, timeoutMs: mixerRevealPollTimeoutMs,
                in:window, permittingObservation:windowCurrent)
            guard windowCurrent() else {
                return (nil,.init(attempted:true,alreadyVisible:false,strategies:strategies,
                    menuItemFound:itemFound,menuClicked:true,keySent:keySent,mixerVisible:false,windowUnavailable:true))
            }
            if polled.childrenUnread {
                return unreadAfterReveal(itemFound: itemFound, menuClicked: true, keySent: keySent)
            }
            if let mixer = polled.mixer {
                return (
                    mixer,
                    MixerRevealResult(
                        attempted: true,
                        alreadyVisible: false,
                        strategies: strategies,
                        menuItemFound: itemFound,
                        menuClicked: true,
                        keySent: keySent,
                        mixerVisible: true
                    )
                )
            }
        }

        return (
            nil,
            MixerRevealResult(
                attempted: true,
                alreadyVisible: false,
                strategies: strategies,
                menuItemFound: itemFound,
                menuClicked: menuClicked,
                keySent: keySent,
                mixerVisible: false
            )
        )
    }

    /// Polls until the Mixer is found or its children fail to read. An unread Mixer ends the poll
    /// at once (#982): it is present, so waiting for it to appear cannot help.
    static func pollMixerAreaVisible(
        runtime: AXLogicProElements.Runtime,
        timeoutMs: Int,
        in window: AXUIElement? = nil,
        permittingObservation: () -> Bool = { true }
    ) async -> AXLogicProElements.MixerAreaLookup {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        repeat {
            guard permittingObservation() else { return .notFound }
            let lookup = window.map { AXLogicProElements.mixerAreaLookup(in:$0,runtime:runtime) }
                ?? AXLogicProElements.mixerAreaLookup(runtime:runtime)
            guard permittingObservation() else { return .notFound }
            if lookup.mixer != nil || lookup.childrenUnread {
                return lookup
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return .notFound
    }

    /// A single inspection's temporary Mixer view, using the same menu policy and bound-window
    /// reader as inventory. No activation, global Escape, key fallback or musical mutation.
    /// Matching bookends cannot detect an intervening same-value human edit; this is not a host lock.
    final class OwnedMixerObservationNavigation {
        let runtime: AXLogicProElements.Runtime
        let window: AXUIElement
        let title: String
        let document: String
        let focus: AXUIElement
        let focusPath: [AXUIElement]?
        private let acquiredApp: AXUIElement
        private let acquiredPID: pid_t
        let headers: [AXUIElement]
        let selected: [Bool]
        let referenceIsCurrent: @Sendable () async -> Bool
        var bar: AXUIElement?
        var revealedMixer: AXUIElement?
        var menuOpen = false
        private var focusRestoreAttempted = false
        private var mixerSelectionRestorationPending = false
        private var topologyRefreshIssued = false
        var effects = SessionPopulationObservation.UIEffects()

        init?(
            window: AXUIElement, runtime: AXLogicProElements.Runtime,
            expectedProject: TargetDescriptor?, requiresProjectReference: Bool,
            referenceIsCurrent: @escaping @Sendable () async -> Bool
        ) {
            guard let pid = runtime.logicProPID(), let app = AXLogicProElements.appRoot(runtime: runtime),
                  let title = AXHelpers.getTitle(window, runtime: runtime.ax),
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
                  let url = URL(string: document), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute, runtime: runtime.ax),
                  case .read(let headers) = AXLogicProElements.allTrackHeadersRead(in: window, runtime: runtime)
            else { return nil }
            if requiresProjectReference {
                guard let expectedProject,
                      expectedProject.projectName?.utf8.elementsEqual(AccessibilityChannel.projectName(fromWindowTitle: title).utf8) == true,
                      expectedProject.projectFilePath?.utf8.elementsEqual(url.path.utf8) == true else { return nil }
            }
            let selected = headers.compactMap { AXHelpers.getAttribute($0, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? }
            guard selected.count == headers.count else { return nil }
            self.runtime = runtime; self.window = window; self.title = title; self.document = document
            self.focus = focus; self.headers = headers; self.selected = selected
            self.acquiredApp = app; self.acquiredPID = pid
            self.focusPath = Self.retainedPath(focus, in: window, runtime: runtime.ax)
            self.referenceIsCurrent = referenceIsCurrent
        }

        /// A stale AXParent alone does not prove that a retired element is still live.
        private static func retainedPath(_ element: AXUIElement, in window: AXUIElement,
                                         runtime: AXHelpers.Runtime) -> [AXUIElement]? {
            var path = [element]
            for _ in 0..<32 {
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      let child = path.last else { return nil }
                if CFEqual(child, window) { return path }
                guard let parent: AXUIElement = AXHelpers.getAttribute(child, kAXParentAttribute as String, runtime: runtime),
                      !path.contains(where: { CFEqual($0, parent) }),
                      case .success(let children) = AXHelpers.childrenResult(parent, runtime: runtime),
                      children.filter({ CFEqual($0, child) }).count == 1 else { return nil }
                path.append(parent)
            }
            return nil
        }

        private func stillOwned(stoppingWhen stop: @Sendable () -> Bool,
                                afterReferenceCheck: (() -> Bool)? = nil,
                                isolation: isolated (any Actor)? = #isolation) async -> Bool {
            guard !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  await referenceIsCurrent() else { return false }
            guard afterReferenceCheck?() ?? true else { return false }
            return originalNativeScopeIsOwned(stoppingWhen: stop)
        }

        private func originalNativeScopeIsOwned(stoppingWhen stop: @Sendable () -> Bool) -> Bool {
            guard !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  runtime.logicProPID() == acquiredPID,
                  let app = AXLogicProElements.appRoot(runtime: runtime),
                  CFEqual(app, acquiredApp),
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true,
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute, runtime: runtime.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute, runtime: runtime.ax),
                  CFEqual(main, window), CFEqual(focusedWindow, window),
                  AXHelpers.getTitle(window, runtime: runtime.ax)?.utf8.elementsEqual(title.utf8) == true,
                  case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
                  currentDocument.utf8.elementsEqual(document.utf8),
                  !AXLogicProElements.dialogPresent(runtime: runtime),
                  case .read(let currentHeaders) = AXLogicProElements.allTrackHeadersRead(in: window, runtime: runtime),
                  currentHeaders.count == headers.count,
                  zip(headers, currentHeaders).allSatisfy({ CFEqual($0, $1) }),
                  currentHeaders.map({ AXHelpers.getAttribute($0, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? }) == selected.map(Optional.some),
                  !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
            else { return false }
            return true
        }

        private func sameFocus() -> Bool {
            guard let app = AXLogicProElements.appRoot(runtime: runtime),
                  let current: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute, runtime: runtime.ax)
            else { return false }
            return CFEqual(current, focus)
        }

        private func capturedFocusCanBeRestored(stripMixer: AXUIElement? = nil,
            headerFocus: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveHeaderReadFocus? = nil,
            inverseSource: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveMixerReadFocus? = nil) -> Bool {
            if let headerFocus {
                guard CFEqual(headerFocus.focus, focus), CFEqual(headerFocus.window, window),
                      headerFocus.document.utf8.elementsEqual(document.utf8),
                      inverseSource.map({ headerFocus.permitsOwnedMixerInverseMetadata(from: $0) }) ?? headerFocus.permits(),
                      let focusPath, let currentPath = Self.retainedPath(focus, in: window, runtime: runtime.ax),
                      currentPath.count == focusPath.count, zip(currentPath, focusPath).allSatisfy({ CFEqual($0, $1) }),
                      AXHelpers.isAttributeSettable(focus, kAXFocusedAttribute as String, runtime: runtime.ax) == true,
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
                return true
            }
            guard let role = AXHelpers.getRole(focus, runtime: runtime.ax),
                  [kAXGroupRole as String, kAXListRole as String, "AXLayoutArea"].contains(role)
                    || (role == kAXLayoutItemRole as String && stripMixer != nil),
                  let focusPath,
                  let currentPath = Self.retainedPath(focus, in: window, runtime: runtime.ax),
                  currentPath.count == focusPath.count,
                  zip(currentPath, focusPath).allSatisfy({ CFEqual($0, $1) }),
                  AXHelpers.isAttributeSettable(focus, kAXFocusedAttribute as String, runtime: runtime.ax) == true,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            if role == kAXLayoutItemRole as String {
                guard let stripMixer,
                      let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: stripMixer, runtime: runtime.ax),
                      census.strips.filter({ CFEqual($0, focus) }).count == 1,
                      let parent: AXUIElement = AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: runtime.ax), CFEqual(parent, stripMixer),
                      AXHelpers.isAttributeSettable(focus, kAXValueAttribute as String, runtime: runtime.ax) == false else { return false }
                let attributes = [kAXValueAttribute, kAXSelectedTextAttribute, kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute] as [String]
                let readings = AXHelpers.getNonHelpAttributes(focus, attributes, runtime: runtime.ax,
                    permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
                for (index, reading) in readings.enumerated() {
                    if index < 2 {
                        guard case .failure(let error) = reading, error.raw == AXError.noValue.rawValue else { return false }
                    } else {
                        guard case .success(.some(let raw)) = reading, CFGetTypeID(raw) == CFNumberGetTypeID(),
                              let number = raw as? NSNumber, number.doubleValue == 0 else { return false }
                    }
                }
            }
            return true
        }

        private func ownedMenuFocus() -> Bool {
            if sameFocus() { return true }
            guard menuOpen, let bar, let app = AXLogicProElements.appRoot(runtime: runtime),
                  var current: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute, runtime: runtime.ax)
            else { return false }
            var visited: [AXUIElement] = []
            for _ in 0..<8 {
                if CFEqual(current, bar) { return true }
                if visited.contains(where: { CFEqual($0, current) }) { return false }
                visited.append(current)
                guard let parent: AXUIElement = AXHelpers.getAttribute(current, kAXParentAttribute, runtime: runtime.ax) else { return false }
                current = parent
            }
            return false
        }

        private func dismissOwnedMenu(
            permittingActuation: (() async -> Bool)? = nil,
            stoppingWhen stop: @Sendable () -> Bool
        ) async -> Bool {
            guard menuOpen else { return true }
            guard await stillOwned(stoppingWhen: stop), ownedMenuFocus(), let bar else { return false }
            if AXHelpers.getAttribute(bar, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? == false,
               sameFocus() {
                menuOpen = false
                return true
            }
            guard
                  runtime.ax.actionNames(bar).contains(kAXCancelAction as String),
                  await stillOwned(stoppingWhen: stop), ownedMenuFocus(),
                  await permittingActuation?() ?? true,
                  !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  AXHelpers.performAction(bar, kAXCancelAction as String, runtime: runtime.ax) else { return false }
            guard await stillOwned(stoppingWhen: stop), sameFocus(),
                  AXHelpers.getAttribute(bar, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? == false
            else { return false }
            menuOpen = false
            return true
        }

        private func uniqueMenuTarget(
            _ candidates: [AXUIElement], role: String, labels: AXLocalePolicy.LabelSet
        ) -> AXUIElement? {
            var target: AXUIElement?
            for candidate in candidates {
                let observedRole: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                    candidate, kAXRoleAttribute as String, runtime: runtime.ax)
                guard case .success(.some(let candidateRole)) = observedRole else { return nil }
                guard candidateRole == role else { continue }
                switch AXLocalePolicy.elementMatchesResult(candidate, labels, runtime: runtime.ax) {
                case .failure: return nil
                case .success(false): continue
                case .success(true):
                    guard target == nil else { return nil }
                    target = candidate
                }
            }
            return target
        }

        private func toggle(
            desiredVisibility: Bool? = nil,
            permittingActuation: (() async -> Bool)? = nil,
            stoppingWhen stop: @Sendable () -> Bool
        ) async -> Bool {
            guard await stillOwned(stoppingWhen: stop), sameFocus(),
                  let menuBar = AXLogicProElements.getMenuBar(runtime: runtime),
                  case .success(let children) = AXHelpers.childrenResult(menuBar, runtime: runtime.ax) else { return false }
            guard let view = uniqueMenuTarget(children, role: kAXMenuBarItemRole as String, labels: AXLocalePolicy.viewMenuBar),
                  runtime.ax.actionNames(view).contains(kAXPressAction as String),
                  runtime.ax.actionNames(view).contains(kAXCancelAction as String),
                  AXHelpers.getAttribute(view, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? == false,
                  await stillOwned(stoppingWhen: stop), sameFocus() else { return false }
            if let bar, !CFEqual(bar, view) { return false }
            bar = view
            guard await permittingActuation?() ?? true else { return false }
            // An AX error is not proof that the attempted native action had no effect.
            menuOpen = true
            effects.navigationPerformed = true
            effects.restoration = "not_restored"
            if !effects.attempted.contains("view_menu") { effects.attempted.append("view_menu") }
            let opened = AccessibilityChannel.openMenuBarItem(view, runtime: runtime.ax)
            let selected: Bool? = AXHelpers.getAttribute(view, kAXSelectedAttribute as String, runtime: runtime.ax)
            if selected == true, !effects.changed.contains("view_menu") { effects.changed.append("view_menu") }
            guard opened, selected == true else { return false }
            // Menus update their dynamic labels only after opening. The shared deadline and
            // cancellation remain effective while waiting; no swallowed cancellation or retry key.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return false }
            guard await stillOwned(stoppingWhen: stop), ownedMenuFocus(),
                  case .success(let census) = AXHelpers.censusDescendantResult(
                    of: view, role: kAXMenuItemRole as String, maxDepth: 5, runtime: runtime.ax)
            else { return false }
            guard let item = uniqueMenuTarget(census.matches, role: kAXMenuItemRole as String, labels: AXLocalePolicy.showMixerMenuItem),
                  AXHelpers.getAttribute(item, kAXEnabledAttribute as String, runtime: runtime.ax) as Bool? == true,
                  runtime.ax.actionNames(item).contains(kAXPressAction as String),
                  await stillOwned(stoppingWhen: stop), ownedMenuFocus() else { return false }
            let lookup = AXLogicProElements.mixerAreaLookup(in: window, runtime: runtime,
                requiresCompleteAbsence: desiredVisibility != nil)
            if desiredVisibility == false {
                // Discovery accepts the same folded title OR description. Direction
                // cannot discard that evidence by rereading only a verbatim title.
                guard case .success(false) = AXLocalePolicy.elementMatchesResult(
                    item, AXLocalePolicy.mixerMenuShowDirection, runtime: runtime.ax)
                else { return false }
            }
            if let revealedMixer {
                guard let current = lookup.mixer, CFEqual(current, revealedMixer) else { return false }
            } else {
                guard case .notFound = lookup else { return false }
                if desiredVisibility != nil {
                    guard case .success(false) = AXLocalePolicy.elementMatchesResult(
                        item, AXLocalePolicy.mixerMenuHideDirection, runtime: runtime.ax)
                    else { return false }
                } else {
                    // Temporary observation uses the same own action direction as explicit
                    // final-state setting; translated discovery cannot authorize a Hide leaf.
                    guard case .success(false) = AXLocalePolicy.elementMatchesResult(
                        item, AXLocalePolicy.mixerMenuHideDirection, runtime: runtime.ax)
                    else { return false }
                }
            }
            // The final-state caller checks retained custody AFTER the deciding Mixer read.
            // Temporary inspection retains its original default-nil behavior.
            if desiredVisibility == nil, revealedMixer == nil {
                guard capturedFocusCanBeRestored(), await stillOwned(stoppingWhen: stop), ownedMenuFocus()
                else { return false }
            }
            guard await permittingActuation?() ?? true,
                  !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            if !effects.attempted.contains("mixer_visibility") { effects.attempted.append("mixer_visibility") }
            guard
                  AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax) else { return false }
            menuOpen = AXHelpers.getAttribute(view, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? != false
            return true
        }

        func reveal(stoppingWhen stop: @Sendable () -> Bool) async {
            // Keep request-owned discovery's proved control-forest Help omission;
            // ordinary discovery can move the retained pre-gesture header focus.
            guard let lookup = try? AXLogicProElements.mixerPopulationAreaLookup(
                in: window, runtime: runtime, requiresCompleteAbsence: true,
                checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                  case .notFound = lookup.lookup else { return }
            // Showing the Mixer may move focus even when its leaf reports an AX error.
            // Never acquire that UI effect if the retained original cannot be restored.
            guard capturedFocusCanBeRestored() else { effects.reason = "mixer_reveal_focus_unrestorable"; return }
            let toggled = await toggle(stoppingWhen: stop)
            guard toggled || effects.attempted.contains("mixer_visibility") else { effects.reason = "mixer_reveal_refused"; return }
            let end = min(OperationTraceContext.current?.deadline ?? ContinuousClock.now, ContinuousClock.now.advanced(by: .milliseconds(mixerRevealPollTimeoutMs)))
            repeat {
                guard await stillOwned(stoppingWhen: stop) else { effects.reason = "navigation_ownership_lost"; return }
                let lookup = AXLogicProElements.mixerAreaLookup(in: window, runtime: runtime)
                if let mixer = lookup.mixer {
                    revealedMixer = mixer
                    if !effects.changed.contains("mixer_visibility") { effects.changed.append("mixer_visibility") }
                    return
                }
                if lookup.childrenUnread { effects.reason = "mixer_children_unread"; return }
                if !toggled { effects.reason = "mixer_reveal_unverified"; return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { effects.reason = "navigation_cancelled"; return }
            } while ContinuousClock.now < end
            effects.reason = "mixer_reveal_unverified"
        }

        /// The lifecycle caller has already issued its one creation and observed
        /// full strip retirement. Refresh only this retained window's checked
        /// Control Bar toggle; generic temporary/final visibility rules stay intact.
        func refreshAfterIssuedCreation(
            expectedMixer: AXUIElement,
            permittingActuation: () async -> Bool,
            stoppingWhen stop: @escaping @Sendable () -> Bool,
            isolation: isolated (any Actor)? = #isolation
        ) async -> Bool {
            func refuse(_ reason: String) -> Bool { effects.reason = reason; return false }
            func owned(isolation: isolated (any Actor)? = #isolation) async -> Bool {
                guard await stillOwned(stoppingWhen: stop, isolation: isolation),
                      let observation = runtime.observeFrontmost?(), observation.isReady,
                      observation.keyboardOwnerPID == acquiredPID,
                      runtime.focusedApplicationPID() == acquiredPID,
                      await permittingActuation(), !stop(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
                return true
            }
            func activity(isolation: isolated (any Actor)? = #isolation) -> AXLogicProElements.ObservedTransportActivity? {
                try? AXLogicProElements.observedTransportActivity(in: window, runtime: runtime,
                    checking: { try SessionPopulationObservation.requireOwnedAcquisition() })
            }
            guard !topologyRefreshIssued, !effects.navigationPerformed, await owned(),
                  let original = activity(), !original.isPlaying, !original.isRecording else {
                return refuse("owned_mixer_refresh_unavailable")
            }
            func buttonState(isolation: isolated (any Actor)? = #isolation) -> (control: AXUIElement, visible: Bool)? {
                guard let current = activity(), !current.isPlaying, !current.isRecording,
                      CFEqual(original.controlBar, current.controlBar), CFEqual(original.play, current.play),
                      CFEqual(original.record, current.record),
                      case .success(let census) = AXHelpers.censusDescendantResult(of: current.controlBar,
                        role: kAXCheckBoxRole, maxDepth: 4, runtime: runtime.ax, requiresCompleteTraversal: true,
                        permittingRead: { !stop() && (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil }) else { return nil }
                var matches: [AXUIElement] = []
                for element in census.matches {
                    switch AXLocalePolicy.elementMatchesResult(element, AXLocalePolicy.controlBarMixerToggle, runtime: runtime.ax) {
                    case .success(true): matches.append(element)
                    case .success(false): break
                    case .failure: return nil
                    }
                }
                guard matches.count == 1, let control = matches.first,
                      case .success(let enabled?) = AXHelpers.getAttributeResult(control, kAXEnabledAttribute,
                        runtime: runtime.ax) as Result<NSNumber?, AXHelpers.AXStatusError>, enabled == 1,
                      case .success(let actions)? = runtime.ax.actionNamesResult?(control),
                      actions.contains(kAXPressAction as String),
                      case .success(let value?) = AXHelpers.getAttributeResult(control, kAXValueAttribute,
                        runtime: runtime.ax) as Result<NSNumber?, AXHelpers.AXStatusError>, value == 0 || value == 1 else { return nil }
                return (control, value.boolValue)
            }
            guard let initial = buttonState(), initial.visible,
                  let lookup = try? AXLogicProElements.mixerPopulationAreaLookup(in: window, runtime: runtime,
                    requiresCompleteAbsence: true, checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                  let area = lookup.binding, CFEqual(area.mixer, expectedMixer), await owned(),
                  let deciding = buttonState(), deciding.visible, CFEqual(initial.control, deciding.control),
                  await owned() else {
                return refuse("owned_mixer_refresh_before_changed")
            }
            func observed(_ visible: Bool, isolation: isolated (any Actor)? = #isolation) async -> Bool {
                let end = min(OperationTraceContext.current?.deadline ?? ContinuousClock.now.advanced(by: .milliseconds(mixerRevealPollTimeoutMs)),
                    ContinuousClock.now.advanced(by: .milliseconds(mixerRevealPollTimeoutMs)))
                repeat {
                    guard await owned(), let state = buttonState(), CFEqual(initial.control, state.control),
                          let lookup = try? AXLogicProElements.mixerPopulationAreaLookup(in: window, runtime: runtime,
                            requiresCompleteAbsence: true, checking: { try SessionPopulationObservation.requireOwnedAcquisition() }) else { return false }
                    switch lookup.lookup {
                    case .found(let mixer):
                        guard CFEqual(mixer, expectedMixer) else { return false }
                        if visible && state.visible { return true }
                    case .notFound: if !visible && !state.visible { return true }
                    case .childrenUnread: return false
                    }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
                } while ContinuousClock.now < end
                return false
            }
            topologyRefreshIssued = true
            effects.navigationPerformed = true; effects.restoration = "not_restored"
            effects.attempted.append("mixer_refresh_hide")
            _ = AXHelpers.performAction(initial.control, kAXPressAction, runtime: runtime.ax)
            guard await observed(false) else { return refuse("owned_mixer_refresh_hide_unverified") }
            effects.changed.append("mixer_visibility")
            guard await owned(), let deciding = buttonState(), !deciding.visible,
                  CFEqual(initial.control, deciding.control), await owned() else { return refuse("owned_mixer_refresh_show_refused") }
            effects.attempted.append("mixer_refresh_show")
            _ = AXHelpers.performAction(initial.control, kAXPressAction, runtime: runtime.ax)
            guard await observed(true), await owned(), let final = buttonState(), final.visible,
                  CFEqual(initial.control, final.control) else { return refuse("owned_mixer_refresh_show_unverified") }
            effects.changed.append("mixer_visibility_restoration")
            // This helper restores visibility, not the retired original focus.
            // Even a cached equal CF is not a live-path restoration certificate.
            effects.restoration = "not_restored"
            effects.reason = "owned_creation_focus_unverified"
            return true
        }

        /// An actual owned Select All relationship, not selection synthesized from our census.
        /// Limited to an already exposed All view; no filter or page navigation is inferred.
        func observeWholeStripSelectionFromRetainedHeader(
            headerFocus: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveHeaderReadFocus,
            association: HeldSelectionAssociation, pair: HeldSelectionAssociation.Pair,
            readFocusScope: OwnedTrackStackObservationNavigation.ReadFocusScope?,
            mouse: AXMouseHelper.Runtime? = nil,
            stoppingBeforeAXRead hardStop: (@Sendable () -> Bool)? = nil,
            stoppingWhen stop: @escaping @Sendable () -> Bool
        ) async -> [AXMixerStripBinding.Binding]? {
            guard !effects.navigationPerformed, await stillOwned(stoppingWhen: stop), sameFocus(),
                  CFEqual(headerFocus.focus, focus), CFEqual(headerFocus.header, pair.track.header),
                  capturedFocusCanBeRestored(headerFocus: headerFocus),
                  AXHelpers.isAttributeSettable(pair.strip.strip, kAXFocusedAttribute as String, runtime: runtime.ax) == true,
                  let menuBar = AXLogicProElements.getMenuBar(runtime: runtime),
                  case .success(let children) = AXHelpers.childrenResult(menuBar, runtime: runtime.ax),
                  let edit = uniqueMenuTarget(children, role: kAXMenuBarItemRole as String, labels: AXLocalePolicy.editMenuBar),
                  AXHelpers.getAttribute(edit, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? == false,
                  await referenceIsCurrent(), !stop(), association.permitsOriginalMixerFocusTarget(pair),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return nil }
            bar = edit
            effects.navigationPerformed = true; effects.restoration = "not_restored"
            effects.attempted.append("mixer_focus_acquisition")
            let accepted = AXHelpers.setAttribute(pair.strip.strip, kAXFocusedAttribute as String, NSNumber(value: true), runtime: runtime.ax)
            var focusAcquired = accepted
            var completedFocusClick = false
            var source: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveMixerReadFocus?
            for attempt in 0..<3 {
                guard await stillOwned(stoppingWhen: { false }),
                      let current: AXUIElement = AXHelpers.getAttribute(acquiredApp, kAXFocusedUIElementAttribute as String, runtime: runtime.ax)
                else { break }
                if CFEqual(current, pair.strip.strip) {
                    source = .init(window: window, logic: runtime)
                    break
                }
                guard CFEqual(current, focus), attempt < 2 else { break }
                if attempt == 0, let mouse {
                    completedFocusClick = await clickOriginalPairBlankFocus(headerFocus: headerFocus,
                        association: association, pair: pair, mouse: mouse, stoppingWhen: stop)
                    if effects.attempted.contains("mixer_focus_click") {
                        guard completedFocusClick else {
                            effects.reason = "mixer_focus_click_unverified"; return nil
                        }
                        focusAcquired = true
                    }
                }
                // Only wait for our completed paired click; it grants no Help,
                // Select All or inverse authority until the actual source below
                // independently observes its exact physical focus. No retry click.
                guard completedFocusClick || headerFocus.permits() else { break }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { break }
            }
            guard let source, CFEqual(source.focus, pair.strip.strip),
                  CFEqual(source.binding.mixer, pair.strip.mixer),
                  source.permits(), capturedFocusCanBeRestored(headerFocus: headerFocus, inverseSource: source)
            else { effects.reason = "mixer_focus_acquisition_unverified"; return nil }
            effects.changed.append("keyboard_focus")
            readFocusScope?.retainMixerInverseFocus(source)
            defer { readFocusScope?.retainMixerInverseFocus(nil) }
            let nested = OwnedMixerObservationNavigation(window: window, runtime: runtime,
                expectedProject: nil, requiresProjectReference: false, referenceIsCurrent: referenceIsCurrent)
            let selected: [AXMixerStripBinding.Binding]?
            if focusAcquired, let nested, CFEqual(nested.focus, source.focus),
               nested.document.utf8.elementsEqual(document.utf8),
               nested.headers.count == headers.count, zip(nested.headers, headers).allSatisfy({ CFEqual($0, $1) }) {
                selected = await nested.observeWholeStripSelection(readFocusScope: readFocusScope,
                    stoppingBeforeAXRead: hardStop, stoppingWhen: stop)
                effects.attempted += nested.effects.attempted.filter { !effects.attempted.contains($0) }
                effects.changed += nested.effects.changed.filter { !effects.changed.contains($0) }
                if nested.effects.navigationPerformed && nested.effects.restoration != "restored" {
                    effects.reason = nested.effects.reason ?? "mixer_selection_restoration_unverified"
                    return nil
                }
            } else { selected = nil }
            guard await restoreCapturedFocusAfterReveal(stripMixer: pair.strip.mixer,
                headerFocus: headerFocus, inverseSource: source, mouse: mouse,
                selectionOrigin: { current in CFEqual(current, source.focus) && source.permits() },
                stoppingWhen: stop), headerFocus.permits(), sameFocus() else {
                if effects.reason == "header_focus_release_unverified" { readFocusScope?.retain(nil) }
                effects.reason = effects.reason ?? "mixer_focus_restoration_unverified"; return nil
            }
            effects.changed.append("keyboard_focus_restoration")
            effects.restoration = "restored"
            return selected
        }

        /// One blank hit on the original observed pair, not a descendant/control
        /// click or a search for another focus target. Native ACK alone is not focus.
        private func clickOriginalPairBlankFocus(
            headerFocus: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveHeaderReadFocus,
            association: HeldSelectionAssociation, pair: HeldSelectionAssociation.Pair,
            mouse: AXMouseHelper.Runtime, stoppingWhen stop: @escaping @Sendable () -> Bool
        ) async -> Bool {
            func frame() -> CGRect? {
                let values = AXHelpers.getNonHelpAttributes(pair.strip.strip,
                    [kAXPositionAttribute, kAXSizeAttribute] as [String], runtime: runtime.ax,
                    permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
                guard case .success(.some(let p)) = values[0], case .success(.some(let s)) = values[1],
                      let point = AXHelpers.point(fromRawAttribute: p), let size = AXHelpers.size(fromRawAttribute: s),
                      point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                      size.width > 0, size.height > 0 else { return nil }
                return CGRect(origin: point, size: size)
            }
            guard await stillOwned(stoppingWhen: stop), sameFocus(), headerFocus.permits(),
                  capturedFocusCanBeRestored(headerFocus: headerFocus),
                  association.permitsOriginalMixerFocusTarget(pair), let heldFrame = frame() else { return false }
            // The center can contain a musical control. One fixed upper-quarter
            // point is eligible only when AX independently hits the blank strip CF.
            let point = CGPoint(x: heldFrame.midX, y: heldFrame.minY + heldFrame.height / 4)
            guard point.x.isFinite, point.y.isFinite,
                  let prepared = mouse.prepareMouseClick(point, 1), let hitTest = runtime.ax.elementAtPosition,
                  case .success(.some(let hit)) = hitTest(acquiredApp, point), CFEqual(hit, pair.strip.strip),
                  await stillOwned(stoppingWhen: stop), sameFocus(), headerFocus.permits(),
                  capturedFocusCanBeRestored(headerFocus: headerFocus), association.permitsOriginalMixerFocusTarget(pair),
                  await referenceIsCurrent(), !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  frame() == heldFrame,
                  case .success(.some(let decidingHit)) = hitTest(acquiredApp, point), CFEqual(decidingHit, pair.strip.strip),
                  let current: AXUIElement = AXHelpers.getAttribute(acquiredApp, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  CFEqual(current, focus),
                  let main: AXUIElement = AXHelpers.getAttribute(acquiredApp, kAXMainWindowAttribute as String, runtime: runtime.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(acquiredApp, kAXFocusedWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(main, window), CFEqual(focusedWindow, window),
                  AXHelpers.getTitle(window, runtime: runtime.ax)?.utf8.elementsEqual(title.utf8) == true,
                  case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
                  currentDocument.utf8.elementsEqual(document.utf8),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            effects.attempted.append("mixer_focus_click")
            guard prepared.postDown() else { return false }
            return prepared.postUp()
        }

        func observeWholeStripSelection(readFocusScope: OwnedTrackStackObservationNavigation.ReadFocusScope? = nil,
                                       stoppingBeforeAXRead hardStop: (@Sendable () -> Bool)? = nil,
                                       stoppingWhen stop: @escaping @Sendable () -> Bool) async -> [AXMixerStripBinding.Binding]? {
            guard !effects.navigationPerformed, await stillOwned(stoppingWhen: stop), sameFocus(),
                  let passive = OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveMixerReadFocus(window: window, logic: runtime),
                  passive.permits(),
                  let binding = (try? AXLogicProElements.mixerPopulationAreaLookup(in: window, runtime: runtime,
                    requiresCompleteAbsence: true,
                    checking: { try SessionPopulationObservation.requireOwnedAcquisition() }))?.binding,
                  let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: binding.mixer, runtime: runtime.ax),
                  !census.strips.isEmpty, census.strips.filter({ CFEqual($0, focus) }).count == 1,
                  AXHelpers.isAttributeSettable(binding.mixer, kAXSelectedChildrenAttribute as String, runtime: runtime.ax) == true,
                  let hidden = AXLogicProElements.hiddenTrackViewRead(headers: headers, in: window, runtime: runtime), hidden.shown,
                  let presentation = try? AXLogicProElements.mixerPresentationRead(binding: binding, runtime: runtime.ax,
                    checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                  presentation.presentation.mode == "all", presentation.presentation.typeFilters.count == 8,
                  presentation.presentation.typeFilters.values.allSatisfy({ $0 == true }),
                  let activity = try? AXLogicProElements.observedTransportActivity(in: window, runtime: runtime,
                    checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                  !activity.isPlaying, !activity.isRecording else { return nil }
            let strips = census.strips
            func same(_ a: [AXUIElement], _ b: [AXUIElement]) -> Bool {
                a.count == b.count && zip(a, b).allSatisfy { CFEqual($0, $1) }
            }
            func subset(_ a: [AXUIElement], of b: [AXUIElement]) -> Bool {
                a.allSatisfy { element in a.filter({ CFEqual($0, element) }).count == 1
                    && b.filter({ CFEqual($0, element) }).count == 1 }
            }
            func sameSet(_ a: [AXUIElement], _ b: [AXUIElement]) -> Bool {
                a.count == b.count && subset(a, of: b)
            }
            func elements(_ attribute: String) -> [AXUIElement]? {
                guard case .success(.elements(let values)) = AXHelpers.getAXUIElementArrayRead(binding.mixer, attribute, runtime: runtime.ax)
                else { return nil }
                return values
            }
            func frames() -> [CGRect]? {
                var result: [CGRect] = []
                for element in [binding.mixer] + strips {
                    let values = AXHelpers.getNonHelpAttributes(element, [kAXPositionAttribute, kAXSizeAttribute] as [String],
                        runtime: runtime.ax, permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
                    guard case .success(.some(let p)) = values[0], case .success(.some(let s)) = values[1],
                          let point = AXHelpers.point(fromRawAttribute: p), let size = AXHelpers.size(fromRawAttribute: s),
                          point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                          size.width > 0, size.height > 0 else { return nil }
                    result.append(CGRect(origin: point, size: size))
                }
                return result
            }
            guard let original = elements(kAXSelectedChildrenAttribute as String), subset(original, of: strips),
                  let visible = elements(kAXVisibleChildrenAttribute as String), subset(visible, of: strips),
                  let originalFrames = frames(),
                  let originalPath = Self.retainedPath(binding.mixer, in: window, runtime: runtime.ax) else { return nil }
            var selectionWasAccepted = false
            var firstSelectionFocus: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveMixerReadFocus?
            defer {
                if firstSelectionFocus != nil { readFocusScope?.retainMixerInverseFocus(nil) }
            }
            func ownedFirstSelectionFocus() -> Bool {
                // Native Select All can focus the first captured strip, even
                // when the original focus/selection is a different strip.
                // Only its exact complete selected population corroborates this
                // request-owned read focus; a partial/foreign set grants none.
                guard selectionWasAccepted, let first = strips.first, !CFEqual(first, focus),
                      let current: AXUIElement = AXHelpers.getAttribute(acquiredApp, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                      CFEqual(current, first), let selected = elements(kAXSelectedChildrenAttribute as String),
                      sameSet(selected, strips) else { return false }
                if firstSelectionFocus == nil {
                    guard let observed = OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveMixerReadFocus(window: window, logic: runtime),
                          CFEqual(observed.focus, first), CFEqual(observed.window, window),
                          observed.document.utf8.elementsEqual(document.utf8), observed.permits() else { return false }
                    firstSelectionFocus = observed
                    readFocusScope?.retainMixerInverseFocus(observed)
                }
                guard firstSelectionFocus?.permits() == true,
                      let bookend = elements(kAXSelectedChildrenAttribute as String), sameSet(bookend, strips) else { return false }
                return true
            }
            func selectionReadFocusOwned() -> Bool {
                (sameFocus() && passive.permits()) || ownedFirstSelectionFocus()
            }
            func renewAcceptedSelectionFocus() -> Bool {
                guard !(hardStop ?? stop)() else { return false }
                // An awaited reference renewal may cross the native focus
                // transition. Pending focus returns to bounded observation
                // before the generic editing guard can retire this read.
                return !selectionWasAccepted || sameFocus() || ownedFirstSelectionFocus()
            }
            func held(ownedSelectionFocus: AXUIElement? = nil) async -> Bool {
                // Inverse observation has its own exact original-subset focus
                // proof; forward Select All renewal must not replace it.
                let renewForwardFocus: (() -> Bool)? = ownedSelectionFocus == nil ? renewAcceptedSelectionFocus : nil
                let selectionFocus = ownedSelectionFocus.map { expected in
                    guard original.filter({ CFEqual($0, expected) }).count == 1,
                          let current: AXUIElement = AXHelpers.getAttribute(acquiredApp, kAXFocusedUIElementAttribute as String, runtime: runtime.ax)
                    else { return false }
                    return CFEqual(current, expected)
                } ?? false
                guard await stillOwned(stoppingWhen: stop, afterReferenceCheck: renewForwardFocus),
                      runtime.focusedApplicationPID() == acquiredPID,
                      ownedMenuFocus() || selectionFocus || ownedFirstSelectionFocus(),
                      let currentPath = Self.retainedPath(binding.mixer, in: window, runtime: runtime.ax), same(originalPath, currentPath),
                      let current = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: binding.mixer, runtime: runtime.ax),
                      same(strips, current.strips),
                      let currentHidden = AXLogicProElements.hiddenTrackViewRead(headers: headers, in: window, runtime: runtime),
                      CFEqual(currentHidden.control, hidden.control), currentHidden.shown,
                      let currentPresentation = try? AXLogicProElements.mixerPresentationRead(binding: binding, runtime: runtime.ax,
                        checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                      same(currentPresentation.elements, presentation.elements), currentPresentation.presentation == presentation.presentation,
                      let currentActivity = try? AXLogicProElements.observedTransportActivity(in: window, runtime: runtime,
                        checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                      CFEqual(currentActivity.controlBar, activity.controlBar), CFEqual(currentActivity.play, activity.play),
                      CFEqual(currentActivity.record, activity.record), !currentActivity.isPlaying, !currentActivity.isRecording,
                      await stillOwned(stoppingWhen: stop, afterReferenceCheck: renewForwardFocus)
                else { return false }
                return true
            }
            guard let menuBar = AXLogicProElements.getMenuBar(runtime: runtime),
                  case .success(let children) = AXHelpers.childrenResult(menuBar, runtime: runtime.ax),
                  let edit = uniqueMenuTarget(children, role: kAXMenuBarItemRole as String, labels: AXLocalePolicy.editMenuBar),
                  runtime.ax.actionNames(edit).contains(kAXPressAction as String),
                  runtime.ax.actionNames(edit).contains(kAXCancelAction as String),
                  AXHelpers.getAttribute(edit, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? == false,
                  await held(), sameFocus(), let before = elements(kAXSelectedChildrenAttribute as String), sameSet(before, original),
                  await held(),
                  await referenceIsCurrent(), !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return nil }
            bar = edit; menuOpen = true; effects.navigationPerformed = true; effects.restoration = "not_restored"
            effects.attempted.append("edit_menu")
            guard AccessibilityChannel.openMenuBarItem(edit, runtime: runtime.ax),
                  AXHelpers.getAttribute(edit, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? == true,
                  await held(),
                  case .success(let menuItems) = AXHelpers.censusDescendantResult(of: edit, role: kAXMenuItemRole as String,
                    maxDepth: 5, runtime: runtime.ax, requiresCompleteTraversal: true) else {
                _ = await dismissOwnedMenu(stoppingWhen: stop); effects.reason = "mixer_select_all_menu_unverified"; return nil
            }
            effects.changed.append("edit_menu")
            var targets: [AXUIElement] = []
            for item in menuItems.matches {
                switch AXHelpers.getAttributeResult(item, kAXIdentifierAttribute as String, runtime: runtime.ax) as Result<String?, AXHelpers.AXStatusError> {
                case .success(let identifier): if identifier == "selectAll:" { targets.append(item) }
                case .failure(let error) where error.isDefinitiveAbsence: break
                default: _ = await dismissOwnedMenu(stoppingWhen: stop); effects.reason = "mixer_select_all_menu_unread"; return nil
                }
            }
            guard targets.count == 1, let item = targets.first,
                  AXHelpers.getAttribute(item, kAXEnabledAttribute as String, runtime: runtime.ax) as Bool? == true,
                  runtime.ax.actionNames(item).contains(kAXPressAction as String),
                  await held(), let deciding = elements(kAXSelectedChildrenAttribute as String), sameSet(deciding, original),
                  await held(),
                  await referenceIsCurrent(), !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                _ = await dismissOwnedMenu(stoppingWhen: stop); effects.reason = "mixer_select_all_refused"; return nil
            }
            effects.attempted.append("mixer_select_all")
            mixerSelectionRestorationPending = true
            let accepted = AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)
            menuOpen = AXHelpers.getAttribute(edit, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? != false
            selectionWasAccepted = accepted
            if accepted { readFocusScope?.retainOriginalMixerReadFocus(passive) }
            _ = ownedFirstSelectionFocus()
            if accepted {
                // A successful dispatch can settle after its ACK. Observe at
                // most three owned states, 100ms apart, before cancelling a
                // still-open menu. Native selection can lag its closed-menu ACK
                // beyond 50ms; retain the original request deadline and never
                // retry the leaf or manufacture its selected children.
                for attempt in 0..<3 {
                    let focusOwned = sameFocus() || ownedFirstSelectionFocus()
                    let heldState = focusOwned ? await held() : false
                    if !heldState {
                        // The accepted leaf may move focus before its selection
                        // settles, including during the awaited custody check.
                        // Spend only the existing two waits on Help-free
                        // observations of the retained first strip. This passive
                        // witness is NOT installed as general read custody: that
                        // still requires the exact complete selected population.
                        let stopPendingRead = hardStop ?? stop
                        if attempt < 2, !stopPendingRead(), await referenceIsCurrent(), !stopPendingRead(),
                              let first = strips.first,
                              let pending = OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveMixerReadFocus(
                                window: window, logic: runtime),
                              CFEqual(pending.focus, first), CFEqual(pending.binding.mixer, binding.mixer),
                              let current = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: binding.mixer, runtime: runtime.ax),
                              same(current.strips, strips),
                              let selection = elements(kAXSelectedChildrenAttribute as String),
                              pending.permits(),
                              (sameSet(selection, original) || (sameSet(selection, strips) && ownedFirstSelectionFocus())),
                              !stopPendingRead() {
                            do { try await Task.sleep(for: .milliseconds(100)) }
                            catch { effects.reason = "navigation_cancelled"; return nil }
                            continue
                        }
                        _ = await dismissOwnedMenu(stoppingWhen: stop)
                        effects.reason = "mixer_global_selection_unverified"; return nil
                    }
                    if attempt > 0 {
                        menuOpen = AXHelpers.getAttribute(edit, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? != false
                    }
                    if !menuOpen {
                        guard selectionReadFocusOwned(),
                              let observed = elements(kAXSelectedChildrenAttribute as String), subset(observed, of: strips) else {
                            effects.reason = "mixer_global_selection_unverified"; return nil
                        }
                        if sameSet(observed, strips) { break }
                    }
                    guard attempt < 2 else { break }
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch {
                        _ = await dismissOwnedMenu(stoppingWhen: stop)
                        effects.reason = "navigation_cancelled"; return nil
                    }
                }
            }
            guard await dismissOwnedMenu(stoppingWhen: stop), await held(), selectionReadFocusOwned(),
                  let selected = elements(kAXSelectedChildrenAttribute as String), subset(selected, of: strips) else {
                effects.reason = "mixer_global_selection_unverified"; return nil
            }
            if !sameSet(selected, original) { effects.changed.append("mixer_selection") }
            guard await held(), let decidingSelected = elements(kAXSelectedChildrenAttribute as String) else {
                effects.reason = "mixer_selection_restoration_conflict"; return nil
            }
            var selectionAtInverse = selected
            if !sameSet(decidingSelected, selected) {
                // One accepted Select All can settle after the post-menu sample.
                // Renew only its exact requested original-CF population, never an
                // arbitrary changed subset. One matching bookend, no retry leaf,
                // new deadline or transfer of the captured original selection/focus.
                guard accepted, sameSet(selected, original), sameSet(decidingSelected, strips),
                      await held(), selectionReadFocusOwned(),
                      let settled = elements(kAXSelectedChildrenAttribute as String), sameSet(settled, strips) else {
                    effects.reason = "mixer_selection_restoration_conflict"; return nil
                }
                selectionAtInverse = settled
                if !sameSet(settled, original) { effects.changed.append("mixer_selection") }
            }
            let complete = accepted && sameSet(selectionAtInverse, strips)
            guard AXHelpers.isAttributeSettable(binding.mixer, kAXSelectedChildrenAttribute as String, runtime: runtime.ax) == true,
                  await held(), await referenceIsCurrent(), !stop(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                effects.reason = "mixer_selection_restoration_conflict"; return nil
            }
            effects.attempted.append("mixer_selection_restoration")
            let restored = AXHelpers.setAttribute(binding.mixer, kAXSelectedChildrenAttribute as String, original as CFArray, runtime: runtime.ax)
            // Select All's first-focus transition can arrive at the inverse ACK.
            // Renew only the existing exact complete-selection proof, not a
            // partial return or an arbitrary newly focused strip.
            if restored, firstSelectionFocus == nil, !(hardStop ?? stop)() {
                _ = ownedFirstSelectionFocus()
            }
            if restored, let firstSelectionFocus {
                // The one accepted inverse can return before its selection and
                // focus settle. Observe only the original or issued complete
                // set under the retained passive witnesses; never retry a setter.
                let stopInverseRead = hardStop ?? stop
                let inverseEnd = min(OperationTraceContext.current?.deadline
                    ?? ContinuousClock.now.advanced(by: .milliseconds(200)),
                    ContinuousClock.now.advanced(by: .milliseconds(200)))
                for attempt in 0..<3 {
                    guard !stopInverseRead(), await stillOwned(stoppingWhen: stopInverseRead),
                          let current = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: binding.mixer, runtime: runtime.ax),
                          same(current.strips, strips), frames() == originalFrames,
                          let currentHidden = AXLogicProElements.hiddenTrackViewRead(headers: headers, in: window, runtime: runtime),
                          CFEqual(currentHidden.control, hidden.control), currentHidden.shown,
                          let currentPresentation = try? AXLogicProElements.mixerPresentationRead(binding: binding, runtime: runtime.ax,
                            checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                          same(currentPresentation.elements, presentation.elements), currentPresentation.presentation == presentation.presentation,
                          let currentActivity = try? AXLogicProElements.observedTransportActivity(in: window, runtime: runtime,
                            checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                          CFEqual(currentActivity.controlBar, activity.controlBar), CFEqual(currentActivity.play, activity.play),
                          CFEqual(currentActivity.record, activity.record), !currentActivity.isPlaying, !currentActivity.isRecording,
                          let after = elements(kAXSelectedChildrenAttribute as String),
                          sameSet(after, original) || sameSet(after, selectionAtInverse),
                          !stopInverseRead(),
                          let returned: AXUIElement = AXHelpers.getAttribute(acquiredApp, kAXFocusedUIElementAttribute as String, runtime: runtime.ax)
                    else {
                        Log.info("Mixer selection inverse refused: settlement scope or native readback", subsystem: "ax")
                        effects.reason = "mixer_selection_restoration_unverified"; return nil
                    }
                    if sameSet(after, original), original.filter({ CFEqual($0, returned) }).count == 1 { break }
                    guard attempt < 2, ContinuousClock.now < inverseEnd,
                          firstSelectionFocus.permits() || (sameFocus() && passive.permits()),
                          !stopInverseRead() else {
                        Log.info("Mixer selection inverse refused: pending focus or settlement bound", subsystem: "ax")
                        effects.reason = "mixer_selection_restoration_unverified"; return nil
                    }
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { effects.reason = "navigation_cancelled"; return nil }
                }
            }
            if restored, !sameFocus() {
                // The inverse setter can focus an original selected strip. This exact
                // owned return is read custody, never adoption of arbitrary foreign focus.
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      await stillOwned(stoppingWhen: { false }),
                      let returned: AXUIElement = AXHelpers.getAttribute(acquiredApp, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                      original.filter({ CFEqual($0, returned) }).count == 1,
                      let after = elements(kAXSelectedChildrenAttribute as String), sameSet(after, original),
                      let inverseFocus = OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveMixerReadFocus(window: window, logic: runtime),
                      CFEqual(inverseFocus.focus, returned), inverseFocus.permits() else {
                    Log.info("Mixer selection inverse refused: returned original-subset focus proof", subsystem: "ax")
                    effects.reason = "mixer_selection_restoration_unverified"; return nil
                }
                // Keep the original read witness. The existing scoped exception is
                // temporary and grants no setter authority; all action gates remain below.
                readFocusScope?.retainMixerInverseFocus(inverseFocus)
                defer { readFocusScope?.retainMixerInverseFocus(nil) }
                guard await held(ownedSelectionFocus: returned) else {
                    Log.info("Mixer selection inverse refused: original-subset custody", subsystem: "ax")
                    effects.reason = "mixer_selection_restoration_unverified"; return nil
                }
                effects.attempted.append("mixer_focus_restoration")
                guard await restoreCapturedFocusAfterReveal(stripMixer: binding.mixer,
                        selectionOrigin: { current in
                            guard CFEqual(current, returned), inverseFocus.permits(),
                                  let selection = elements(kAXSelectedChildrenAttribute as String), sameSet(selection, original)
                            else { return false }
                            return await held(ownedSelectionFocus: returned)
                        }, stoppingWhen: stop) else {
                    Log.info("Mixer selection inverse refused: captured-focus restoration", subsystem: "ax")
                    effects.reason = "mixer_selection_restoration_unverified"; return nil
                }
                effects.changed.append("mixer_focus_restoration")
            }
            guard restored, await held(), sameFocus(), passive.permits(),
                  let after = elements(kAXSelectedChildrenAttribute as String), sameSet(after, original),
                  let afterVisible = elements(kAXVisibleChildrenAttribute as String), same(visible, afterVisible),
                  frames() == originalFrames, await held() else {
                Log.info("Mixer selection inverse refused: final original focus, selection or viewport", subsystem: "ax")
                effects.reason = "mixer_selection_restoration_unverified"; return nil
            }
            if !sameSet(selectionAtInverse, original) { effects.changed.append("mixer_selection_restoration") }
            mixerSelectionRestorationPending = false
            effects.restoration = "restored"
            return complete ? strips.map { .init(window: window, mixer: binding.mixer, strip: $0, document: document) } : nil
        }

        func restore(stoppingWhen stop: @Sendable () -> Bool) async -> SessionPopulationObservation.UIEffects {
            guard effects.navigationPerformed else { return effects }
            if mixerSelectionRestorationPending {
                _ = await dismissOwnedMenu(stoppingWhen: stop)
                effects.reason = effects.reason ?? "mixer_selection_restoration_unverified"
                return effects
            }
            guard await stillOwned(stoppingWhen: stop) else { effects.reason = "navigation_ownership_lost"; return effects }
            if !ownedMenuFocus(), revealedMixer != nil {
                guard await restoreCapturedFocusAfterReveal(stoppingWhen: stop) else {
                    effects.reason = "mixer_restoration_conflict"; return effects
                }
            }
            if menuOpen {
                // Cancel only the exact menu we opened, never a global Escape into another window.
                guard await dismissOwnedMenu(stoppingWhen: stop) else {
                    effects.reason = "menu_restoration_failed"; return effects
                }
                menuOpen = false
            }
            if let revealedMixer {
                guard sameFocus(), await toggle(stoppingWhen: stop) else {
                    _ = await dismissOwnedMenu(stoppingWhen: stop)
                    effects.reason = "mixer_restoration_conflict"; return effects
                }
                // Hide can return the original focus before its retained Mixer
                // leaves the native tree. Observe only that one accepted action;
                // neither its ACK nor a replacement Mixer proves restoration.
                let end = min(OperationTraceContext.current?.deadline
                    ?? ContinuousClock.now.advanced(by: .milliseconds(mixerRevealPollTimeoutMs)),
                    ContinuousClock.now.advanced(by: .milliseconds(mixerRevealPollTimeoutMs)))
                var hidden = false
                repeat {
                    guard await stillOwned(stoppingWhen: stop), sameFocus(), ContinuousClock.now < end,
                          let observed = try? AXLogicProElements.mixerPopulationAreaLookup(
                            in: window, runtime: runtime, requiresCompleteAbsence: true,
                            checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                          await stillOwned(stoppingWhen: stop), sameFocus() else { break }
                    if case .notFound = observed.lookup {
                        // The awaited reference renewal can change the native
                        // view. Decide absence afterward, with synchronous scope
                        // bookends rather than promoting its pre-await sample.
                        guard let deciding = try? AXLogicProElements.mixerPopulationAreaLookup(
                            in: window, runtime: runtime, requiresCompleteAbsence: true,
                            checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                              case .notFound = deciding.lookup,
                              originalNativeScopeIsOwned(stoppingWhen: stop), sameFocus() else { break }
                        hidden = true; break
                    }
                    guard let pending = observed.lookup.mixer, CFEqual(pending, revealedMixer) else { break }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                } while ContinuousClock.now < end
                guard hidden else {
                    effects.reason = "mixer_restoration_unverified"; return effects
                }
            } else if effects.attempted.contains("mixer_visibility") {
                effects.reason = "mixer_reveal_unverified"; return effects
            }
            guard sameFocus(), let bar,
                  AXHelpers.getAttribute(bar, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? == false
            else { effects.reason = "menu_restoration_unverified"; return effects }
            effects.restoration = "restored"
            effects.reason = nil
            return effects
        }

        /// Showing the owned Mixer can focus its physical container. Both temporary
        /// inspection and final visibility reuse the same exact retained workspace
        /// proof; an ACK or the target's AXFocused value alone is not restoration.
        private func restoreCapturedFocusAfterReveal(afterHide: Bool = false, stripMixer: AXUIElement? = nil,
                                                     headerFocus: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveHeaderReadFocus? = nil,
                                                     inverseSource: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveMixerReadFocus? = nil,
                                                     mouse: AXMouseHelper.Runtime? = nil,
                                                     selectionOrigin: ((AXUIElement) async -> Bool)? = nil,
                                                     stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            let pid = acquiredPID
            let app = acquiredApp
            guard (effects.attempted.contains("mixer_visibility") || (selectionOrigin != nil && mixerSelectionRestorationPending)
                    || (selectionOrigin != nil && headerFocus != nil && effects.attempted.contains("mixer_focus_acquisition"))),
                  !focusRestoreAttempted,
                  runtime.logicProPID() == pid,
                  let acquiredCurrentApp = AXLogicProElements.appRoot(runtime: runtime), CFEqual(app, acquiredCurrentApp), let bar,
                  AXHelpers.getAttribute(bar, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? == false,
                  await stillOwned(stoppingWhen: stop), runtime.logicProPID() == pid,
                  let currentApp = AXLogicProElements.appRoot(runtime: runtime), CFEqual(app, currentApp),
                  let current: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  !CFEqual(current, focus), !CFEqual(current, window),
                  await selectionOrigin?(current) ?? (AXHelpers.getRole(current, runtime: runtime.ax) == kAXGroupRole as String
                    && isOwnedVisibilityFocus(current, afterHide: afterHide)),
                  selectionOrigin == nil || capturedFocusCanBeRestored(stripMixer: stripMixer,
                    headerFocus: headerFocus, inverseSource: inverseSource),
                  let focusPath, let currentPath = Self.retainedPath(focus, in: window, runtime: runtime.ax),
                  currentPath.count == focusPath.count, zip(currentPath, focusPath).allSatisfy({ CFEqual($0, $1) }),
                  AXHelpers.isAttributeSettable(focus, kAXFocusedAttribute as String, runtime: runtime.ax) == true,
                  await stillOwned(stoppingWhen: stop), runtime.logicProPID() == pid,
                  let finalApp = AXLogicProElements.appRoot(runtime: runtime), CFEqual(app, finalApp),
                  let finalFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  CFEqual(current, finalFocus),
                  AXHelpers.getAttribute(bar, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? == false,
                  let decidingPath = Self.retainedPath(focus, in: window, runtime: runtime.ax),
                  decidingPath.count == focusPath.count, zip(decidingPath, focusPath).allSatisfy({ CFEqual($0, $1) }),
                  let decidingFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  CFEqual(current, decidingFocus), await selectionOrigin?(current) ?? true, !stop(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            // Positive closed-menu evidence ends the earlier acquired-menu flag.
            menuOpen = false
            focusRestoreAttempted = true
            if let headerFocus {
                guard let inverseSource, let mouse, let hitTest = runtime.ax.elementAtPosition else { return false }
                func frame() -> CGRect? {
                    let values = AXHelpers.getNonHelpAttributes(focus,
                        [kAXPositionAttribute, kAXSizeAttribute] as [String], runtime: runtime.ax,
                        permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
                    guard case .success(.some(let p)) = values[0], case .success(.some(let s)) = values[1],
                          let point = AXHelpers.point(fromRawAttribute: p), let size = AXHelpers.size(fromRawAttribute: s),
                          point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                          size.width > 0, size.height > 0 else { return nil }
                    let result = CGRect(origin: point, size: size)
                    return result.midX.isFinite && result.midY.isFinite ? result : nil
                }
                // One single click on the exact retained passive field, never a
                // rename setter or another descendant. Its selection must already
                // be exclusive: clicking cannot silently clear selected peers.
                let expected = zip(headers, selected).filter { $0.1 }.map { $0.0 }
                guard expected.count == 1, CFEqual(expected[0], headerFocus.header),
                      headerFocus.permitsOwnedMixerInverseMetadata(from: inverseSource),
                      case .success(.elements(let original)) = AXHelpers.getAXUIElementArrayRead(
                        headerFocus.rail, kAXSelectedChildrenAttribute as String, runtime: runtime.ax),
                      original.count == expected.count, zip(original, expected).allSatisfy({ CFEqual($0, $1) }),
                      let heldFrame = frame(),
                      let prepared = mouse.prepareMouseClick(CGPoint(x: heldFrame.midX, y: heldFrame.midY), 1),
                      case .success(.some(let hit)) = hitTest(app, CGPoint(x: heldFrame.midX, y: heldFrame.midY)), CFEqual(hit, focus),
                      await stillOwned(stoppingWhen: stop),
                      case .success(.elements(let deciding)) = AXHelpers.getAXUIElementArrayRead(
                        headerFocus.rail, kAXSelectedChildrenAttribute as String, runtime: runtime.ax),
                      deciding.count == original.count, zip(deciding, original).allSatisfy({ CFEqual($0, $1) }),
                      frame() == heldFrame,
                      case .success(.some(let decidingHit)) = hitTest(app, CGPoint(x: heldFrame.midX, y: heldFrame.midY)), CFEqual(decidingHit, focus),
                      headerFocus.permitsOwnedMixerInverseMetadata(from: inverseSource), !stop(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
                effects.attempted.append("header_focus_click")
                guard prepared.postDown() else { return false }
                // Complete only this preconstructed pair: no AX/read/await between halves.
                guard prepared.postUp() else {
                    effects.reason = "header_focus_release_unverified"; return false
                }
                guard case .success(.elements(let after)) = AXHelpers.getAXUIElementArrayRead(
                        headerFocus.rail, kAXSelectedChildrenAttribute as String, runtime: runtime.ax),
                      after.count == original.count, zip(after, original).allSatisfy({ CFEqual($0, $1) }) else { return false }
            } else {
                guard AXHelpers.setAttribute(focus, kAXFocusedAttribute as String,
                    NSNumber(value: true), runtime: runtime.ax) else { return false }
            }
            guard await stillOwned(stoppingWhen: stop), ownedMenuFocus(), sameFocus(),
                  runtime.logicProPID() == pid,
                  let restoredApp = AXLogicProElements.appRoot(runtime: runtime), CFEqual(app, restoredApp),
                  let restoredPath = Self.retainedPath(focus, in: window, runtime: runtime.ax),
                  restoredPath.count == focusPath.count, zip(restoredPath, focusPath).allSatisfy({ CFEqual($0, $1) }),
                  await stillOwned(stoppingWhen: stop), sameFocus(), !stop(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            return true
        }

        private func isOwnedVisibilityFocus(_ current: AXUIElement, afterHide: Bool) -> Bool {
            let lookup = AXLogicProElements.mixerAreaLookup(in: window, runtime: runtime, requiresCompleteAbsence: true)
            if afterHide {
                // A native Hide moves focus to a previously retained workspace ancestor.
                // Neither a newly discovered Tracks label nor a retired Mixer is authority.
                guard revealedMixer != nil, case .notFound = lookup, capturedFocusCanBeRestored(),
                      let focusPath,
                      focusPath.dropFirst().dropLast().filter({ CFEqual($0, current) }).count == 1
                else { return false }
                return true
            }
            guard case .found(let mixer) = lookup,
                  revealedMixer.map({ CFEqual($0, mixer) }) ?? true,
                  let mixerPath = Self.retainedPath(mixer, in: window, runtime: runtime.ax)
            else { return false }
            return CFEqual(current, mixer) || (mixerPath.count > 1 && CFEqual(mixerPath[1], current))
        }

        static func qualifiesFinalVisibilityFocus(role: String?) -> Bool {
            role == kAXGroupRole as String || role == kAXListRole as String
        }

        func hasQualifiedFinalVisibilityFocus() -> Bool {
            Self.qualifiesFinalVisibilityFocus(role: AXHelpers.getRole(focus, runtime: runtime.ax))
        }

        /// Leave the caller's approved Mixer state in place. Only the menu acquired here is
        /// cleaned up; unlike temporary inspection, this never compensates the final view.
        func approvedVisibility(expectedTransport: AXLogicProElements.ObservedTransportActivity? = nil,
                                stoppingWhen stop: @Sendable () -> Bool) async -> (Bool, AXUIElement?)? {
            guard await stillOwned(stoppingWhen: stop), ownedMenuFocus() else { return nil }
            let lookup = try? AXLogicProElements.mixerPopulationAreaLookup(in: window, runtime: runtime,
                requiresCompleteAbsence: true, checking: {
                    try SessionPopulationObservation.requireOwnedAcquisition()
                    if stop() { throw SessionPopulationObservation.AcquisitionError.textEditing }
                })
            let activity = try? AXLogicProElements.observedTransportActivity(in: window, runtime: runtime, checking: {
                try SessionPopulationObservation.requireOwnedAcquisition()
                if stop() { throw SessionPopulationObservation.AcquisitionError.textEditing }
            })
            guard let lookup, let activity, !activity.isPlaying, !activity.isRecording,
                  await stillOwned(stoppingWhen: stop), ownedMenuFocus(), !stop(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return nil }
            if let expectedTransport {
                guard CFEqual(activity.controlBar, expectedTransport.controlBar),
                      CFEqual(activity.play, expectedTransport.play),
                      CFEqual(activity.record, expectedTransport.record) else { return nil }
            }
            switch lookup.lookup {
            case .found(let mixer): return (true, mixer)
            case .notFound: return (false, nil)
            case .childrenUnread: return nil
            }
        }

        func setFinalVisibility(_ desired: Bool, expectedBefore: Bool? = nil, expectedMixer: AXUIElement? = nil,
                                permittingVisibilityChange: (() async -> Bool)? = nil,
                                stoppingWhen stop: @escaping @Sendable () -> Bool) async -> ChannelResult {
            let operation = "view.set_mixer_visibility"
            var before: Bool?
            var after: Bool?
            var menuRestored = true
            func result(verified: Bool, reason: String? = nil) -> ChannelResult {
                var extras: [String: Any] = [
                    "operation": operation, "requested_visible": desired,
                    "write_attempted": effects.navigationPerformed,
                    "menu_restored": menuRestored,
                    "visibility_source": "ax_bound_mixer",
                    "focus_restore_attempted": focusRestoreAttempted,
                ]
                if let before { extras["before_visible"] = before }
                if let after { extras["after_visible"] = after }
                if let reason { extras["navigation_reason"] = reason }
                if verified { return .success(HonestContract.encodeStateA(extras: extras)) }
                if effects.navigationPerformed {
                    extras["hint"] = "The attempted view operation was not verified; do not blindly repeat it."
                    // Preserve the attempted-effects envelope through the router. The dispatcher
                    // marks this unverified result as an error without replacing it with State C.
                    return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
                }
                return .error(HonestContract.encodeStateC(error: .readbackUnavailable,
                    hint: "Mixer visibility or its retained UI custody could not be observed; no action was sent.", extras: extras))
            }
            guard let pid = runtime.logicProPID(), let app = AXLogicProElements.appRoot(runtime: runtime) else {
                return result(verified: false)
            }
            func owned() async -> Bool {
                guard await stillOwned(stoppingWhen: stop), ownedMenuFocus(),
                      runtime.logicProPID() == pid,
                      let currentApp = AXLogicProElements.appRoot(runtime: runtime), CFEqual(app, currentApp),
                      !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
                return true
            }
            guard await owned() else { return result(verified: false, reason: "navigation_ownership_lost") }
            let initial = try? AXLogicProElements.mixerPopulationAreaLookup(in: window, runtime: runtime,
                requiresCompleteAbsence: true)
            guard await owned() else { return result(verified: false, reason: "navigation_ownership_lost") }
            guard let initial else { return result(verified: false, reason: "mixer_children_unread") }
            switch initial.lookup {
            case .found(let mixer): before = true; revealedMixer = mixer
            case .notFound: before = false
            case .childrenUnread: return result(verified: false, reason: "mixer_children_unread")
            }
            if let expectedBefore {
                guard before == expectedBefore,
                      expectedBefore == false || (expectedMixer != nil && revealedMixer != nil && CFEqual(expectedMixer!, revealedMixer!)),
                      await permittingVisibilityChange?() ?? true else {
                    return result(verified: false, reason: "approved_view_before_changed")
                }
            }
            // Hide retires the physical Mixer and its qualified containers. An
            // exact focus on either cannot survive our existing readback/inverse
            // contract. Refuse before opening View, not after destroying custody.
            if before == true, !desired, let binding = initial.binding,
               CFEqual(focus, binding.mixer) || binding.owners.contains(where: { CFEqual(focus, $0) }) {
                return result(verified: false, reason: "mixer_focus_would_be_retired")
            }
            var acknowledged = true
            if before != desired {
                // Deep workspace layout areas can advertise settable focus but
                // ignore restoration. Keep this admission local to changed
                // final visibility; temporary navigation has its own proof.
                guard hasQualifiedFinalVisibilityFocus() else {
                    return result(verified: false, reason: "workspace_focus_restoration_unavailable")
                }
                acknowledged = await toggle(desiredVisibility: desired, permittingActuation: {
                    guard await owned(), await permittingVisibilityChange?() ?? true,
                          self.hasQualifiedFinalVisibilityFocus() else { return false }
                    return await owned()
                }, stoppingWhen: stop)
            }
            func observe(_ lookup: AXLogicProElements.MixerAreaLookup) {
                switch lookup {
                case .found(let mixer):
                    if let revealedMixer, !CFEqual(mixer, revealedMixer) {
                        after = nil
                    } else {
                        revealedMixer = mixer
                        after = true
                    }
                case .notFound: after = false
                case .childrenUnread: after = nil
                }
            }
            func ownedAfterReveal() async -> Bool {
                if await owned() { return true }
                // Show may focus its physical Mixer container; Hide may focus a held
                // workspace ancestor. Both require restoring the exact live workspace.
                guard before != desired, runtime.logicProPID() == pid,
                      let currentApp = AXLogicProElements.appRoot(runtime: runtime), CFEqual(app, currentApp),
                      await restoreCapturedFocusAfterReveal(afterHide: !desired, stoppingWhen: stop), await owned() else { return false }
                return true
            }
            let end = min(OperationTraceContext.current?.deadline ?? ContinuousClock.now.advanced(by: .milliseconds(mixerRevealPollTimeoutMs)),
                          ContinuousClock.now.advanced(by: .milliseconds(mixerRevealPollTimeoutMs)))
            repeat {
                guard await ownedAfterReveal() else {
                    after = nil // The earlier sample no longer has current read custody.
                    menuRestored = !effects.navigationPerformed
                    return result(verified: false, reason: "navigation_ownership_lost")
                }
                let lookup = AXLogicProElements.mixerAreaLookup(in: window, runtime: runtime, requiresCompleteAbsence: true)
                guard await ownedAfterReveal() else {
                    after = nil
                    menuRestored = !effects.navigationPerformed
                    return result(verified: false, reason: "navigation_ownership_lost")
                }
                observe(lookup)
                if after == desired || !acknowledged || !effects.attempted.contains("mixer_visibility") { break }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            } while ContinuousClock.now < end
            menuRestored = await dismissOwnedMenu(permittingActuation: { await owned() }, stoppingWhen: stop)
            guard menuRestored, await owned(), sameFocus(),
                  !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                after = nil
                return result(verified: false, reason: "menu_restoration_failed")
            }
            let finalLookup = AXLogicProElements.mixerAreaLookup(in: window, runtime: runtime, requiresCompleteAbsence: true)
            guard await owned(), sameFocus(),
                  !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                after = nil
                return result(verified: false, reason: "navigation_ownership_lost")
            }
            observe(finalLookup)
            // An external appearance during menu acquisition is not an owned successful action.
            let actedOrUnchanged = before == desired || effects.attempted.contains("mixer_visibility")
            return result(verified: after == desired && actedOrUnchanged,
                          reason: after == desired && actedOrUnchanged ? nil : "mixer_visibility_unverified")
        }
    }

    static func defaultSetMixerVisibility(params: [String: String], runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        guard let raw = params["visible"], raw == "true" || raw == "false" else {
            return .error(HonestContract.encodeStateC(error: .invalidParams,
                hint: "visible must be a boolean", extras: ["write_attempted": false]))
        }
        if let approval = ApprovedSessionRepair.current {
            return await approval.perform(raw == "true", runtime: runtime)
        }
        let stop: @Sendable () -> Bool = {
            (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil
                || StatePoller.backgroundTickYields(to: Self.readLogicKeyboardFocus(runtime: runtime))
        }
        guard !stop(), case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
              let navigation = OwnedMixerObservationNavigation(window: window, runtime: runtime,
                  expectedProject: nil, requiresProjectReference: false, referenceIsCurrent: { true }) else {
            return .error(HonestContract.encodeStateC(error: .readbackUnavailable,
                hint: "The current project/window custody is unreadable; no action was sent.",
                extras: ["operation": "view.set_mixer_visibility", "write_attempted": false]))
        }
        return await navigation.setFinalVisibility(raw == "true", stoppingWhen: stop)
    }

    // MARK: - Shared validation inputs

    /// Live front-document path provider for the project-identity gate. Defaults
    /// to the AppleScript probe; tests inject a deterministic value so the gate
    /// can be exercised without a running Logic Pro.
    typealias FrontDocumentPathProvider = @Sendable () async -> String?

    static let liveFrontDocumentPath: FrontDocumentPathProvider = {
        await AppleScriptChannel.currentDocumentPath()
    }

    typealias PluginWindowOpener = @Sendable (
        _ targetSlot: AXUIElementSendable,
        _ pluginID: String,
        _ trackName: String,
        _ axDescription: String,
        _ runtime: AXLogicProElements.Runtime
    ) async -> AXUIElementSendable?

    /// Result of the CoreGraphics-backed popup cleanup that follows plug-in
    /// window acquisition. A remaining popup is unsafe: Logic stops servicing
    /// AppleEvents while it is open, so the next verified write would fail for
    /// an unrelated-looking reason.
    enum PluginPopupMenuCleanupOutcome: Sendable, Equatable {
        case noPopupObserved
        case dismissed
        /// CoreGraphics did not provide a popup-window count. This is not
        /// evidence that no popup exists, so the acquisition must not continue
        /// as if the screen were known clean.
        case popupCountUnavailable
        case couldNotDismiss(initialPopupCount: Int, remainingPopupCount: Int)

        var isClean: Bool {
            switch self {
            case .noPopupObserved, .dismissed:
                return true
            case .popupCountUnavailable, .couldNotDismiss:
                return false
            }
        }
    }

    typealias PluginPopupMenuCleaner = @Sendable (
        _ runtime: AXLogicProElements.Runtime
    ) -> PluginPopupMenuCleanupOutcome

    static let livePluginWindowOpener: PluginWindowOpener = { targetSlot, pluginID, trackName, axDescription, runtime in
        await openPluginWindowFromTargetSlot(
            targetSlot.element,
            pluginID: pluginID,
            trackName: trackName,
            axDescription: axDescription,
            // The plug-in remembers its last view. If that is Controls, its
            // native sliders have no descriptions until the caller selects and
            // confirms the editor view after this header-bound acquisition.
            requiringMatchingSlider: false,
            runtime: runtime
        )
    }

    static let liveNoOpPluginWindowOpener: PluginWindowOpener = { _, _, _, _, _ in nil }

    static let livePluginPopupMenuCleaner: PluginPopupMenuCleaner = { runtime in
        dismissLogicPopupMenuAfterPluginWindowAcquisition(runtime: runtime)
    }

    /// Steps 2-3 of the R6 precedence shared by both mutating verified ops:
    /// mode validation then the project path gate. Returns a State C envelope to
    /// short-circuit on failure, or nil to continue. `extras` carries the
    /// pre-resolution `target_identity` fields the caller already knows.
    private static func verifiedModeAndPathGate(
        operation: String,
        mode: String,
        projectExpectedPath: String?,
        preResolutionIdentity: [String: Any],
        frontDocumentPath: FrontDocumentPathProvider
    ) async -> String? {
        // Step 2 — mode. Release 1 only supports duplicate_applyback;
        // confirmed_live is refused BEFORE any write (P1-C, AC17).
        guard mode == "duplicate_applyback" else {
            return HonestContract.encodeV2StateC(
                error: .unsupportedMode,
                extras: [
                    "operation": operation,
                    "target_identity": preResolutionIdentity,
                    "what_was_attempted": "validate write mode '\(mode)'",
                    "what_was_observed": "mode '\(mode)' is not supported in Release 1 (only duplicate_applyback)",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            )
        }

        // Step 3 — project path gate (R10). Path is mandatory for duplicate
        // mutating ops (AC19), then the front document must match it (AC15).
        guard let expectedPath = projectExpectedPath,
              !expectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return HonestContract.encodeV2StateC(
                error: .projectPathRequired,
                extras: [
                    "operation": operation,
                    "target_identity": preResolutionIdentity,
                    "what_was_attempted": "verify the front document before writing",
                    "what_was_observed": "project_expected_path was not provided for a duplicate_applyback mutating op",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            )
        }
        let observedPath = await frontDocumentPath()
        guard let observedPath, AppleScriptChannel.projectPathsMatch(expectedPath, observedPath) else {
            var identity = preResolutionIdentity
            identity["project_path_expected"] = expectedPath
            identity["project_path_observed"] = observedPath ?? NSNull()
            return HonestContract.encodeV2StateC(
                error: .projectIdentityMismatch,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "what_was_attempted": "verify front document is the expected duplicate before writing",
                    "what_was_observed": observedPath == nil
                        ? "no front document path could be read"
                        : "front document path did not match project_expected_path",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            )
        }
        return nil
    }

    // MARK: - verified parameter writes (R6 single precedence; AC10/AC11/AC17/AC19/AC23)

    /// Verified parameter-write engine. Both `set_param_verified` and the
    /// named-band Channel EQ operation take this R6 precedence, in order:
    ///
    ///   1  schema/params (`invalid_params`)
    ///   2  mode          (`unsupported_mode`)
    ///   3  project path  (`project_path_required` / `project_identity_mismatch`)
    ///   4  identity alias resolution (`unknown_plugin_identity`)
    ///   5  capability preflight — `.unsupported`/`.unknownParameter` fail closed
    ///      with `unsupported_param_readback` (AC10); only `.writeReadback`
    ///      proceeds.
    ///   6  acquire the original Arrange/Mixer identity before selection, bind it to any
    ///      expected reference name, then verify track selection (`track_selection_failed`)
    ///      and retain the acquired identity through stabilization
    ///   7  inventory complete + occupied and identity-matched at `insert`
    ///      (`incomplete_inventory` / `target_plugin_mismatch`)
    ///   8  plugin window: a single plug-in instance uses the existing opener;
    ///      duplicate instances require zero header-proven editors before one
    ///      target-slot open press and exactly one afterward
    ///   9  slider match by AXDescription (`param_control_not_found`)
    ///  10  before `AXValue` read
    ///  11  dispatch the catalog's AX write method
    ///  12  read back the declared raw or display target
    ///  13  direct-set tolerance or increment-walk outcome; failures roll back
    ///      with the same declared write method.
    ///
    /// Step 4 runs BEFORE step 5 so a display-name/alias input still reaches the
    /// capability lookup (canonical id is required to query capability — AC23).
    ///
    /// Compressor threshold uses direct `AXValue` assignment. Channel EQ's
    /// named controls use the separately measured increment walk; their catalog
    /// provenance intentionally does not claim an end-to-end live round trip.
    static func defaultSetParamVerified(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        frontDocumentPath: FrontDocumentPathProvider = liveFrontDocumentPath,
        entryLookup: VerifiedPluginCatalog.EntryLookup = VerifiedPluginCatalog.productionEntryLookup,
        paramAliasLookup: VerifiedPluginCatalog.ParamAliasLookup = VerifiedPluginCatalog.canonicalParamKey,
        pluginWindowOpener: PluginWindowOpener = livePluginWindowOpener,
        pluginPopupMenuCleaner: PluginPopupMenuCleaner = livePluginPopupMenuCleaner,
        incrementWalkBudget: Int = ChannelEQBandCatalog.incrementWalkBudget
    ) async -> ChannelResult {
        await defaultVerifiedParameterWrite(
            operation: "logic_plugins.set_param_verified",
            params: params,
            selector: .plugin(
                pluginAlias: params["plugin"] ?? "",
                paramAlias: params["param"] ?? ""
            ),
            runtime: runtime,
            frontDocumentPath: frontDocumentPath,
            entryLookup: entryLookup,
            paramAliasLookup: paramAliasLookup,
            pluginWindowOpener: pluginWindowOpener,
            pluginPopupMenuCleaner: pluginPopupMenuCleaner,
            incrementWalkBudget: incrementWalkBudget
        )
    }

    /// Named-band Channel EQ variant of `set_param_verified`. It enters the
    /// same R6 engine at step 1; only the step-4 selector differs. The public
    /// surface never accepts a band ordinal or a slider position.
    static func defaultSetEQBandVerified(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        frontDocumentPath: FrontDocumentPathProvider = liveFrontDocumentPath,
        entryLookup: VerifiedPluginCatalog.EntryLookup = VerifiedPluginCatalog.productionEntryLookup,
        pluginWindowOpener: PluginWindowOpener = livePluginWindowOpener,
        pluginPopupMenuCleaner: PluginPopupMenuCleaner = livePluginPopupMenuCleaner,
        incrementWalkBudget: Int = ChannelEQBandCatalog.incrementWalkBudget
    ) async -> ChannelResult {
        await defaultVerifiedParameterWrite(
            operation: "logic_plugins.set_eq_band_verified",
            params: params,
            selector: .channelEQ(
                bandName: params["band"] ?? "",
                parameterName: params["parameter"] ?? ""
            ),
            runtime: runtime,
            frontDocumentPath: frontDocumentPath,
            entryLookup: entryLookup,
            paramAliasLookup: VerifiedPluginCatalog.canonicalParamKey,
            pluginWindowOpener: pluginWindowOpener,
            pluginPopupMenuCleaner: pluginPopupMenuCleaner,
            incrementWalkBudget: incrementWalkBudget
        )
    }

    private enum VerifiedParameterSelector {
        case plugin(pluginAlias: String, paramAlias: String)
        case channelEQ(bandName: String, parameterName: String)

        var preResolutionIdentity: [String: Any] {
            switch self {
            case let .plugin(pluginAlias, _):
                ["plugin_id_requested": pluginAlias]
            case let .channelEQ(bandName, parameterName):
                [
                    "plugin_id_requested": "logic.stock.effect.channel_eq",
                    "band_requested": bandName,
                    "parameter_requested": parameterName,
                ]
            }
        }

        var parameterLabel: String {
            switch self {
            case let .plugin(_, paramAlias): paramAlias
            case let .channelEQ(bandName, parameterName): "\(bandName) \(parameterName)"
            }
        }
    }

    private struct ResolvedVerifiedParameter {
        let pluginID: String
        let paramKey: String
        let paramAlias: String
        let metadata: StockPluginParameterMetadata
        let walkTarget: SliderIncrementWalk.Target?
        let responseDisplayUnit: String
    }

    private enum VerifiedParameterResolution {
        case success(ResolvedVerifiedParameter)
        case failure(String)
    }

    /// R6's single precedence implementation, shared by generic verified
    /// parameters and named Channel EQ bands. The selector resolution belongs at
    /// step 4, after mode/path/target-reference gates, so the two public
    /// operations cannot drift into different precedence rules.
    private static func defaultVerifiedParameterWrite(
        operation: String,
        params: [String: String],
        selector: VerifiedParameterSelector,
        runtime: AXLogicProElements.Runtime,
        frontDocumentPath: FrontDocumentPathProvider,
        entryLookup: VerifiedPluginCatalog.EntryLookup,
        paramAliasLookup: VerifiedPluginCatalog.ParamAliasLookup,
        pluginWindowOpener: PluginWindowOpener,
        pluginPopupMenuCleaner: PluginPopupMenuCleaner,
        incrementWalkBudget: Int
    ) async -> ChannelResult {

        // Step 1 — schema / params (presence, type, range, unit).
        guard let trackRaw = params["track"], let track = Int(trackRaw), track >= 0 else {
            return .error(invalidParamsStateC(operation, "missing or invalid 'track' (Int >= 0)"))
        }
        guard let insertRaw = params["insert"], let insert = Int(insertRaw), insert >= 0 else {
            return .error(invalidParamsStateC(operation, "missing or invalid 'insert' (Int >= 0)"))
        }
        switch selector {
        case let .plugin(pluginAlias, paramAlias):
            guard !pluginAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error(invalidParamsStateC(operation, "missing 'plugin' identity"))
            }
            guard !paramAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error(invalidParamsStateC(operation, "missing 'param' key"))
            }
        case let .channelEQ(bandName, parameterName):
            guard !bandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error(invalidParamsStateC(operation, "missing Channel EQ 'band' name"))
            }
            guard !parameterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error(invalidParamsStateC(operation, "missing Channel EQ 'parameter' name"))
            }
        }
        guard let valueRaw = params["value"], let value = Double(valueRaw), value.isFinite else {
            return .error(invalidParamsStateC(operation, "missing or non-finite 'value'"))
        }
        let unit = params["unit"]
        let mode = params["mode"] ?? ""

        var preResolutionIdentity = selector.preResolutionIdentity
        preResolutionIdentity["track_index"] = track

        // Steps 2-3 — mode + project path gate (precedence: path-mismatch wins
        // over a later unsupported-param, AC23).
        if let gate = await verifiedModeAndPathGate(
            operation: operation,
            mode: mode,
            projectExpectedPath: params["project_expected_path"],
            preResolutionIdentity: preResolutionIdentity,
            frontDocumentPath: frontDocumentPath
        ) {
            return .error(gate)
        }

        // ADR-002 F1 — when the target was resolved from a session-stable
        // `target_ref`, the caller's bound track name is threaded in as
        // `expected_track_name`. Require the LIVE AX header at this positional
        // index to still read back that exact name before any selection or write,
        // so an out-of-band UI track reorder fails closed with
        // `stale_target_reference` instead of a wrong-target write during the
        // state-cache latency window. Absent (explicit-index path) it is a no-op,
        // so the default/flag-off behaviour is byte-invariant.
        if let guardResult = targetTrackNameGuard(
            operation: operation,
            track: track,
            expectedTrackName: params["expected_track_name"],
            identity: preResolutionIdentity,
            runtime: runtime
        ) {
            return guardResult
        }

        // Steps 4-5 — selector resolution, unit/range honesty, and capability
        // preflight. This remains before any track/window AX mutation.
        switch resolveVerifiedParameter(
            selector: selector,
            requested: value,
            unit: unit,
            operation: operation,
            track: track,
            insert: insert,
            entryLookup: entryLookup,
            paramAliasLookup: paramAliasLookup,
            preResolutionIdentity: preResolutionIdentity
        ) {
        case let .failure(error):
            return .error(error)
        case let .success(target):
            return await performVerifiedParameterAccess(
                operation: operation,
                referenceParams: params,
                track: track,
                insert: insert,
                pluginID: target.pluginID,
                paramKey: target.paramKey,
                paramAlias: target.paramAlias,
                access: .write(requested: value, walkTarget: target.walkTarget,
                    displayUnit: target.responseDisplayUnit, budget: incrementWalkBudget),
                writeMethod: target.metadata.writeMethod ?? "",
                runtime: runtime,
                entryLookup: entryLookup,
                pluginWindowOpener: pluginWindowOpener,
                pluginPopupMenuCleaner: pluginPopupMenuCleaner
            )
        }
    }

    /// Pure selected-plan validation through the same catalog/unit/actuation
    /// resolver as the writer. Placeholder indices supply no target authority.
    static func verifiedEQParameterPreflight(band: String, parameter: String, value: Double, unit: String) -> Bool {
        switch resolveVerifiedParameter(selector: .channelEQ(bandName: band, parameterName: parameter),
            requested: value, unit: unit, operation: "logic_plugins.set_eq_band_verified", track: 0, insert: 0,
            entryLookup: VerifiedPluginCatalog.productionEntryLookup,
            paramAliasLookup: VerifiedPluginCatalog.canonicalParamKey, preResolutionIdentity: [:]) {
        case .success: true
        case .failure: false
        }
    }

    private static func resolveVerifiedParameter(
        selector: VerifiedParameterSelector,
        requested: Double,
        unit: String?,
        operation: String,
        track: Int,
        insert: Int,
        entryLookup: VerifiedPluginCatalog.EntryLookup,
        paramAliasLookup: VerifiedPluginCatalog.ParamAliasLookup,
        preResolutionIdentity: [String: Any]
    ) -> VerifiedParameterResolution {
        let pluginID: String
        let paramKey: String
        let paramAlias = selector.parameterLabel
        switch selector {
        case let .plugin(pluginAlias, suppliedParamAlias):
            guard let resolved = VerifiedPluginCatalog.canonicalPluginID(from: pluginAlias) else {
                return .failure(HonestContract.encodeV2StateC(
                    error: .unknownPluginIdentity,
                    extras: [
                        "operation": operation,
                        "target_identity": preResolutionIdentity,
                        "what_was_attempted": "resolve plugin identity '\(pluginAlias)' to a canonical catalog id",
                        "what_was_observed": "no alias mapping to a logic.stock.* id",
                        "safe_to_retry": false,
                        "write_attempted": false,
                    ]
                ))
            }
            pluginID = resolved
            paramKey = VerifiedPluginCatalog.canonicalParamKey(
                pluginID: pluginID,
                alias: suppliedParamAlias,
                paramAliasLookup: paramAliasLookup
            ) ?? suppliedParamAlias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case let .channelEQ(bandName, parameterName):
            guard let catalogParameter = ChannelEQBandCatalog.parameter(
                bandName: bandName,
                parameterName: parameterName
            ) else {
                return .failure(invalidParamsStateC(
                    operation,
                    "unknown Channel EQ band/parameter name '\(bandName)' / '\(parameterName)'"
                ))
            }
            pluginID = "logic.stock.effect.channel_eq"
            paramKey = catalogParameter.id
        }

        let identity = resolvedIdentity(track: track, insert: insert, pluginID: pluginID)
        guard let metadata = entryLookup(pluginID)?.parameters.first(where: { $0.id == paramKey }) else {
            return .failure(HonestContract.encodeV2StateC(
                error: .unsupportedParamReadback,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "param": paramAlias,
                    "what_was_attempted": "preflight write/readback capability for \(pluginID).\(paramAlias)",
                    "what_was_observed": "parameter is not in the verified allowlist",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        }

        // ADR-011 / ADR-018 negative evidence is a first-class preflight
        // refusal. The catalog gives this state explicitly to Controls-view
        // shapes whose AX role is known but whose write path is either measured
        // inert or unmeasured. Neither branch reaches AX window acquisition or
        // a speculative actuation.
        switch metadata.controlsViewActuationState {
        case .measuredNotActuable:
            return .failure(HonestContract.encodeV2StateC(
                error: .unsupportedParamReadback,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "param": paramAlias,
                    "what_was_attempted": "preflight the measured Controls-view slider actuation path for \(pluginID).\(paramAlias)",
                    "what_was_observed": ControlsViewBooleanParameterWriter.LocatorFailure.sliderNotActuable.observation,
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        case .unmeasured:
            return .failure(HonestContract.encodeV2StateC(
                error: .unsupportedParamReadback,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "param": paramAlias,
                    "what_was_attempted": "preflight the measured Controls-view popup actuation path for \(pluginID).\(paramAlias)",
                    "what_was_observed": ControlsViewBooleanParameterWriter.LocatorFailure.popupNotAddressableByName.observation,
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        case nil:
            break
        }

        if metadata.writeMethod == "ax_controls_view_checkbox_press",
           requested != 0, requested != 1 {
            return .failure(invalidParamsStateC(
                operation,
                "Controls-view boolean parameter \(pluginID).\(paramAlias) requires value 0 or 1"
            ))
        }

        let declaredUnits = metadata.acceptedUnits ?? metadata.unit.map { [$0] } ?? []
        let normalizedUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .channelEQ = selector, normalizedUnit?.isEmpty ?? true {
            return .failure(invalidParamsStateC(
                operation,
                "Channel EQ requires a declared 'unit' for \(paramAlias)"
            ))
        }
        let requestedUnit = normalizedUnit?.isEmpty == false ? normalizedUnit! : metadata.unit
        // Validate case-insensitively, then keep the catalog spelling. The
        // increment walk compares Logic's display rendering exactly, so an
        // accepted caller `db` must target Logic's declared `dB`, never reuse
        // the caller's casing verbatim.
        guard let requestedUnit,
              let effectiveUnit = declaredUnits.first(where: {
                  $0.caseInsensitiveCompare(requestedUnit) == .orderedSame
              }) else {
            let declared = declaredUnits.joined(separator: ", ")
            return .failure(invalidParamsStateC(
                operation,
                "unit '\(unit ?? "")' is not declared for \(pluginID).\(paramAlias); declared units: \(declared)"
            ))
        }

        let isIncrementWalk = metadata.writeMethod == "ax_slider_increment_walk"
        let rawUnit = metadata.unit
        let isRawRequest = rawUnit.map {
            $0.caseInsensitiveCompare(effectiveUnit) == .orderedSame
        } ?? false
        if !isIncrementWalk || isRawRequest,
           let range = metadata.valueRange,
           requested < range.min || requested > range.max {
            return .failure(invalidParamsStateC(
                operation,
                "value \(requested) is outside the valid range [\(range.min), \(range.max)] for \(pluginID).\(paramAlias)"
            ))
        }

        let hasWrite = !(metadata.writeMethod?.isEmpty ?? true)
        let hasReadback = !(metadata.readbackMethod?.isEmpty ?? true)
        guard hasWrite, hasReadback else {
            return .failure(HonestContract.encodeV2StateC(
                error: .unsupportedParamReadback,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "param": paramAlias,
                    "what_was_attempted": "preflight write/readback capability for \(pluginID).\(paramAlias)",
                    "what_was_observed": "no display-readback parser / write method is available for this parameter",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        }

        let walkTarget: SliderIncrementWalk.Target?
        if isIncrementWalk {
            if isRawRequest {
                walkTarget = .rawValue(requested, tolerance: metadata.tolerance ?? 0)
            } else {
                // This is formatting only, not a display-to-raw conversion. The
                // walk stops only when Logic reports this exact description.
                let displayValue = displayTargetValueText(requested)
                let signedValue = effectiveUnit.caseInsensitiveCompare("dB") == .orderedSame
                    && requested > 0
                    ? "+\(displayValue)"
                    : displayValue
                walkTarget = .display("\(signedValue) \(effectiveUnit)")
            }
        } else {
            walkTarget = nil
        }

        return .success(ResolvedVerifiedParameter(
            pluginID: pluginID,
            paramKey: paramKey,
            paramAlias: paramAlias,
            metadata: metadata,
            walkTarget: walkTarget,
            responseDisplayUnit: metadata.unit == "normalized" ? "%" : effectiveUnit
        ))
    }

    /// ADR-002 F1 — live track-identity cross-check for `target_ref`-resolved
    /// verified mutations. `expectedTrackName` is the reference's bound track
    /// name, threaded down only on the `target_ref` path. Reads the LIVE AX track
    /// header at the positional `track` index and requires matching raw UTF-8
    /// bytes. A mismatch — or an unreadable live name — fails closed with
    /// `stale_target_reference` and no write, making the live AX read authoritative
    /// over a possibly-stale state cache (closes the out-of-band-reorder window).
    /// Returns nil (proceed) when `expectedTrackName` is absent, so the
    /// explicit-index / flag-off path is unchanged.
    static func targetTrackNameGuard(
        operation: String,
        track: Int,
        expectedTrackName: String?,
        identity: [String: Any],
        runtime: AXLogicProElements.Runtime
    ) -> ChannelResult? {
        guard let expectedTrackName else { return nil }
        let expected = expectedTrackName
        guard let scannedNames = AXLogicProElements.trackNames(runtime: runtime) else {
            return .error(HonestContract.encodeV2StateC(
                error: .staleTargetReference,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "expected_track_name": expectedTrackName,
                    "observed_track_name": NSNull(),
                    "what_was_attempted": "confirm the live track at index \(track) still matches the referenced track before writing",
                    "what_was_observed": "live track headers were unreadable",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        }
        let names = scannedNames
        let live = names[track]
        guard let live, live.utf8.elementsEqual(expected.utf8) else {
            return .error(HonestContract.encodeV2StateC(
                error: .staleTargetReference,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "expected_track_name": expectedTrackName,
                    "observed_track_name": live as Any? ?? NSNull(),
                    "what_was_attempted": "confirm the live track at index \(track) still matches the referenced track before writing",
                    "what_was_observed": live.map { "index \(track) live track name is '\($0)'" }
                        ?? "index \(track) live track name was unreadable",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        }
        let ambiguousIndices = names
            .filter { $0.value.utf8.elementsEqual(expected.utf8) }
            .map(\.key)
            .sorted()
        guard ambiguousIndices.count <= 1 else {
            return .error(HonestContract.encodeV2StateC(
                error: .ambiguousTargetName,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "expected_track_name": expectedTrackName,
                    "observed_track_name": live,
                    "ambiguous_live_track_name": true,
                    "ambiguous_track_indices": ambiguousIndices,
                    "what_was_attempted": "confirm the live track at index \(track) is uniquely identified before writing",
                    "what_was_observed": "live track name '\(expected)' also appeared at indices \(ambiguousIndices.map(String.init).joined(separator: ", "))",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        }
        return nil
    }

    // MARK: - Shared occupied-instance acquisition and parameter access

    /// A read has no requested value and cannot enter the setter/walker branch.
    /// UI acquisition and its owned view/editor cleanup are shared with writers.
    private enum VerifiedParameterAccess {
        case read(unit: String, contextIsCurrent: () -> Bool, openerOverride: PluginWindowOpener?)
        case readEQState(contextIsCurrent: () -> Bool, openerOverride: PluginWindowOpener?)
        case write(requested: Double, walkTarget: SliderIncrementWalk.Target?, displayUnit: String, budget: Int)

        var isRead: Bool { readContextIsCurrent != nil }
        var isEQStateRead: Bool { if case .readEQState = self { return true }; return false }
        var readContextIsCurrent: (() -> Bool)? {
            switch self {
            case let .read(_, context, _), let .readEQState(context, _): return context
            case .write: return nil
            }
        }
        var readOpenerOverride: PluginWindowOpener? {
            switch self {
            case let .read(_, _, opener), let .readEQState(_, opener): return opener
            case .write: return nil
            }
        }
    }

    /// Internal reads share the caller's existing UI ownership; the public
    /// dispatcher takes the same VerifiedOpGate as scalar readers and writers.
    /// No ownership token, setter, or implicit insertion is exposed here.
    static func defaultGetChannelEQStateVerified(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        pluginWindowOpener: PluginWindowOpener? = nil
    ) async -> ChannelResult {
        let operation = "logic_plugins.get_channel_eq_state_verified"
        let pluginID = "logic.stock.effect.channel_eq"
        guard params["value"] == nil, params["mode"] == nil, params["confirmation"] == nil,
              let trackRaw = params["track"], let track = Int(trackRaw), track >= 0,
              let insertRaw = params["insert"], let insert = Int(insertRaw), insert >= 0,
              let alias = params["plugin"], VerifiedPluginCatalog.canonicalPluginID(from: alias) == pluginID,
              let expectedPath = params["project_expected_path"], !expectedPath.isEmpty,
              params["expected_track_name"] != nil, params["expected_slot_read_status"] == "ok",
              params["expected_plugin_identity"] == pluginID else {
            return .error(invalidParamsStateC(operation, "state reads require a resolved occupied Channel EQ insert and project binding, never write inputs"))
        }
        let modal = AXLogicProElements.dialogPresenceReason(runtime: runtime)
        guard !modal.isBlocked else {
            return .error(HonestContract.encodeV2StateC(error: .readbackUnavailable,
                extras: ["operation": operation, "dialog_presence_reason": modal.rawValue,
                         "refusal_names_an_actual_dialog": modal.namesAnActualDialog, "write_attempted": false]))
        }
        guard case .found(let projectWindow) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
              case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(projectWindow, runtime: runtime),
              let url = URL(string: document), url.isFileURL,
              AppleScriptChannel.projectPathsMatch(expectedPath, url.path) else {
            return .error(HonestContract.encodeV2StateC(error: .projectIdentityMismatch,
                extras: ["operation": operation, "write_attempted": false]))
        }
        let contextIsCurrent: () -> Bool = {
            guard !Task.isCancelled, !AXLogicProElements.dialogPresent(runtime: runtime),
                  case .found(let current) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
                  CFEqual(current, projectWindow),
                  case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(current, runtime: runtime),
                  currentDocument.utf8.elementsEqual(document.utf8) else { return false }
            return true
        }
        let popupCheck: PluginPopupMenuCleaner = { runtime in
            guard let count = logicOwnedPopupMenuWindowCount(runtime: runtime) else { return .popupCountUnavailable }
            return count == 0 ? .noPopupObserved : .couldNotDismiss(initialPopupCount: count, remainingPopupCount: count)
        }
        let result = await performVerifiedParameterAccess(
            operation: operation, referenceParams: params, track: track, insert: insert,
            pluginID: pluginID, paramKey: "low_shelf_frequency", paramAlias: "eight_band_state",
            access: .readEQState(contextIsCurrent: contextIsCurrent, openerOverride: pluginWindowOpener),
            writeMethod: "ax_slider_axvalue", runtime: runtime,
            entryLookup: VerifiedPluginCatalog.productionEntryLookup,
            pluginWindowOpener: pluginWindowOpener ?? livePluginWindowOpener, pluginPopupMenuCleaner: popupCheck
        )
        guard contextIsCurrent() else {
            return parameterReadContextFailure(result, error: .projectIdentityMismatch, operation: operation)
        }
        return result
    }

    static func defaultGetParamVerified(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        entryLookup: VerifiedPluginCatalog.EntryLookup = VerifiedPluginCatalog.productionEntryLookup,
        pluginWindowOpener: PluginWindowOpener? = nil
    ) async -> ChannelResult {
        let operation = "logic_plugins.get_param_verified"
        guard params["value"] == nil, params["mode"] == nil,
              let trackRaw = params["track"], let track = Int(trackRaw), track >= 0,
              let insertRaw = params["insert"], let insert = Int(insertRaw), insert >= 0,
              let pluginAlias = params["plugin"], let suppliedParam = params["param"], !suppliedParam.isEmpty,
              let expectedPath = params["project_expected_path"], !expectedPath.isEmpty,
              params["expected_track_name"] != nil,
              params["expected_slot_read_status"] == "ok",
              params["expected_plugin_identity"] != nil else {
            return .error(invalidParamsStateC(operation,
                "a read requires a resolved occupied insert, project binding and named parameter; value/mode are not read inputs"))
        }
        guard let pluginID = VerifiedPluginCatalog.canonicalPluginID(from: pluginAlias) else {
            return .error(HonestContract.encodeV2StateC(error: .unknownPluginIdentity,
                extras: ["operation": operation, "write_attempted": false]))
        }
        let paramKey = VerifiedPluginCatalog.canonicalParamKey(pluginID: pluginID, alias: suppliedParam)
            ?? suppliedParam.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let metadata = entryLookup(pluginID)?.parameters.first(where: { $0.id == paramKey }) else {
            return .error(HonestContract.encodeV2StateC(error: .unsupportedParamReadback,
                extras: ["operation": operation, "param": suppliedParam,
                    "parameter_read_status": "unknown", "write_attempted": false]))
        }
        let nativeSlider = metadata.readbackMethod == "ax_slider_axvalue" && metadata.axDescription != nil
        let controlsCheckbox = metadata.readbackMethod == "ax_controls_view_checkbox_value"
            && metadata.controlsViewControlRole == "AXCheckBox" && metadata.controlsViewRowLabel != nil
        let controlsReadKind = ControlsViewParameterReader.kind(for: metadata)
        guard nativeSlider || controlsCheckbox || controlsReadKind != nil,
              let rawUnit = metadata.readbackUnit ?? metadata.unit else {
            return .error(HonestContract.encodeV2StateC(error: .unsupportedParamReadback,
                extras: ["operation": operation, "param": suppliedParam,
                    "parameter_read_status": "unsupported", "write_attempted": false]))
        }
        guard params["unit"] == nil || params["unit"] == rawUnit else {
            return .error(invalidParamsStateC(operation,
                "this read returns '\(rawUnit)' AXValue and the host's verbatim display, not a raw-to-engineering conversion"))
        }
        let modal = AXLogicProElements.dialogPresenceReason(runtime: runtime)
        guard !modal.isBlocked else {
            return .error(HonestContract.encodeV2StateC(error: .readbackUnavailable,
                extras: ["operation": operation, "dialog_presence_reason": modal.rawValue,
                         "refusal_names_an_actual_dialog": modal.namesAnActualDialog, "write_attempted": false]))
        }
        guard case .found(let projectWindow) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
              case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(projectWindow, runtime: runtime),
              let documentURL = URL(string: document), documentURL.isFileURL,
              AppleScriptChannel.projectPathsMatch(expectedPath, documentURL.path) else {
            return .error(HonestContract.encodeV2StateC(error: .projectIdentityMismatch,
                extras: ["operation": operation, "write_attempted": false]))
        }
        let contextIsCurrent: () -> Bool = {
            if PluginsDispatcher.sagaLease != nil, !pluginRollbackOperationIsCurrent() { return false }
            guard !Task.isCancelled, !AXLogicProElements.dialogPresent(runtime: runtime),
                  case .found(let currentWindow) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
                  CFEqual(currentWindow, projectWindow),
                  case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(currentWindow, runtime: runtime),
                  currentDocument.utf8.elementsEqual(document.utf8) else { return false }
            return true
        }
        // A read does not cancel somebody else's menu or post global Escape.
        // Reuse the existing injected window-list reader, refusing unread or open popups.
        let popupCheck: PluginPopupMenuCleaner = { runtime in
            guard let count = logicOwnedPopupMenuWindowCount(runtime: runtime) else { return .popupCountUnavailable }
            return count == 0 ? .noPopupObserved : .couldNotDismiss(initialPopupCount: count, remainingPopupCount: count)
        }
        let result = await performVerifiedParameterAccess(
            operation: operation, referenceParams: params, track: track, insert: insert,
            pluginID: pluginID, paramKey: paramKey, paramAlias: suppliedParam,
            access: .read(unit: rawUnit, contextIsCurrent: contextIsCurrent, openerOverride: pluginWindowOpener),
            writeMethod: "", readsControlsCheckbox: controlsCheckbox, controlsReadKind: controlsReadKind,
            runtime: runtime, entryLookup: entryLookup,
            pluginWindowOpener: pluginWindowOpener ?? livePluginWindowOpener, pluginPopupMenuCleaner: popupCheck
        )
        guard contextIsCurrent() else {
            return parameterReadContextFailure(result, error: .projectIdentityMismatch, operation: operation)
        }
        return result
    }

    /// Context loss invalidates the sampled value, not the observed cleanup history.
    /// Never let a later bookend turn a known view/editor side effect into silence.
    static func parameterReadContextFailure(
        _ result: ChannelResult, error: HonestContract.FailureError, operation: String
    ) -> ChannelResult {
        var extras: [String: Any] = [
            "operation": operation, "write_attempted": false, "parameter_read_status": "unknown",
            "what_was_observed": "the acquired target/project context ended during parameter acquisition or cleanup",
        ]
        if let data = result.message.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object where key.hasPrefix("plugin_view_")
                || key == "editor_close_observed" || key == "editor_close_attempted"
                || key == "editor_cleanup_unobserved" || key == "editor_still_open" || key == "recovery_hint"
                || key == "opener_action_attempted" {
                extras[key] = value
            }
        }
        return .error(HonestContract.encodeV2StateC(error: error, extras: extras))
    }

    /// Shared exact occupied-insert acquisition, observed parameter access and
    /// owned UI cleanup. Reads return before every setter/walker branch. Writes
    /// retain their established requested-versus-observed verification contract.
    private static func performVerifiedParameterAccess(
        operation: String,
        referenceParams: [String: String],
        track: Int,
        insert: Int,
        pluginID: String,
        paramKey: String,
        paramAlias: String,
        access: VerifiedParameterAccess,
        writeMethod: String,
        readsControlsCheckbox: Bool = false,
        controlsReadKind: ControlsViewParameterReader.Kind? = nil,
        runtime: AXLogicProElements.Runtime,
        entryLookup: VerifiedPluginCatalog.EntryLookup,
        pluginWindowOpener: PluginWindowOpener,
        pluginPopupMenuCleaner: PluginPopupMenuCleaner
    ) async -> ChannelResult {
        let identity = resolvedIdentity(track: track, insert: insert, pluginID: pluginID)
        // Read metadata selects its plane without borrowing write qualification.
        let controlsViewCheckbox = access.isRead ? readsControlsCheckbox
            : writeMethod == "ax_controls_view_checkbox_press"
        let usesControlsView = controlsViewCheckbox || (access.isRead && controlsReadKind != nil)
        let controlsViewRowLabel = usesControlsView
            ? VerifiedPluginCatalog.controlsViewRowLabel(
                pluginID: pluginID,
                paramKey: paramKey,
                entryLookup: entryLookup
            )
            : nil
        let controlsViewEditorAnchor: String?
        let axDescription: String
        if usesControlsView {
            // An editor-view description can corroborate the header-bound
            // window when it happens to be present. It is not an acquisition
            // precondition: an editor may already be in Controls view, where
            // sliders intentionally have no AXDescription.
            controlsViewEditorAnchor = VerifiedPluginCatalog.editorWindowAnchorAXDescription(
                pluginID: pluginID,
                paramKey: paramKey,
                entryLookup: entryLookup
            )
            axDescription = controlsViewEditorAnchor ?? ""
        } else {
            controlsViewEditorAnchor = nil
            guard let description = VerifiedPluginCatalog.paramAXDescription(
                pluginID: pluginID,
                paramKey: paramKey,
                entryLookup: entryLookup
            ) else {
                return .error(HonestContract.encodeV2StateC(
                    error: .unsupportedParamReadback,
                    extras: [
                        "operation": operation,
                        "target_identity": identity,
                        "param": paramAlias,
                        "what_was_attempted": "resolve the AX control matcher for \(pluginID).\(paramAlias)",
                        "what_was_observed": "parameter declares no AX description matcher",
                        "safe_to_retry": false,
                        "write_attempted": false,
                    ]
                ))
            }
            axDescription = description
        }
        // A remembered Controls view has no described sliders. Bind the editor
        // by its measured track/plugin header first, then select and confirm
        // the view required by the write plane before any slider lookup.
        let requiringWindowSlider = false
        if usesControlsView, controlsViewRowLabel == nil {
            return .error(HonestContract.encodeV2StateC(
                error: .unsupportedParamReadback,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "param": paramAlias,
                    "what_was_attempted": "resolve the Controls-view AXRow label for \(pluginID).\(paramAlias)",
                    "what_was_observed": "parameter declares no measured Controls-view row label",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        }
        let tolerance = VerifiedPluginCatalog.paramTolerance(
            pluginID: pluginID,
            paramKey: paramKey,
            entryLookup: entryLookup
        ) ?? 1.0

        // Acquire identity before selection can yield to a changed Arrange order. A reference's
        // name must authorize this independently read binding, not a later replacement target.
        let mixerLookup = AXLogicProElements.mixerAreaLookup(runtime: runtime)
        guard let mixer = mixerLookup.mixer else {
            return .error(incompleteInventoryStateC(
                operation, identity,
                mixerLookup.childrenUnread ? "the mixer's children did not read" : "mixer area was not locatable"
            ))
        }
        guard let target = AXPluginTrackBinding.resolve(track: track, mixer: mixer, runtime: runtime) else {
            return .error(incompleteInventoryStateC(operation, identity,
                pluginTrackBindingFailureDetail(mixer: mixer, runtime: runtime)))
        }
        if let refusal = pluginReferenceBindingGuard(
            params: referenceParams, target: target, operation: operation, identity: identity
        ) { return refusal }

        // Step 6 — track verified select. Drive the AX-native selection ladder,
        // then confirm the target header reads back as selected (a write that the
        // AX API accepted vacuously must not be trusted — v3.0.9 lesson).
        if !access.isRead {
        guard AXLogicProElements.selectTrackViaAX(at: track, runtime: runtime) else {
            return .error(trackSelectionFailedStateC(operation, identity, "AX track selection write failed for track \(track)"))
        }
        guard await verifiedTrackSelected(track: track, runtime: runtime) else {
            return .error(trackSelectionFailedStateC(
                operation, identity,
                "track \(track) selection could not be verified via AXSelected readback"
            ))
        }
        guard await AXPluginTrackBinding.waitUntilStable(target, runtime: runtime) else {
            return .error(HonestContract.encodeV2StateC(
                error: referenceParams["expected_track_name"] == nil ? .incompleteInventory : .staleTargetReference,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "what_was_attempted": "retain the acquired track identity through selection",
                    "what_was_observed": "the acquired track or Mixer binding changed during selection",
                    "write_attempted": false,
                    "safe_to_retry": false,
                ]
            ))
        }
        } else if !AXPluginTrackBinding.isStable(target, runtime: runtime) {
            return .error(incompleteInventoryStateC(operation, identity, "the acquired Arrange/Mixer target changed before the read"))
        }

        // Step 7 — inventory complete + slot occupied at `insert` (reuse the
        // drift-safe enumerator; an unreadable chain or an empty target slot
        // means there is no plugin to write into).
        guard let slots = AXLogicProElements.audioPluginInsertSlots(in: target.strip, runtime: runtime.ax) else {
            return .error(incompleteInventoryStateC(operation, identity, "the strip's children did not read"))
        }
        let inventory = pluginInventoryItems(for: slots)
        guard inventory.complete else {
            return .error(incompleteInventoryStateC(operation, identity, "one or more insert slots are unreadable (complete:false)"))
        }
        guard insert < slots.count, slots[insert].occupied else {
            // #234 — an empty chain names the insert_section_not_enumerable
            // condition (with the recovery hint) rather than the bare "(0 slots)"
            // out-of-range wording. An empty-but-in-range slot or an out-of-range
            // index on a non-empty chain keeps its prior wording. Still State C —
            // the write never softens to State B.
            let observed: String
            var recoveryHint: String?
            if slots.isEmpty {
                let detail = slotAddressingFailureDetail(requestedIndex: insert, slotCount: 0)
                observed = detail.observed
                recoveryHint = detail.recoveryHint
            } else {
                observed = insert < slots.count
                    ? "insert \(insert) is empty — no plugin to write into"
                    : "insert \(insert) is out of range (\(slots.count) slots)"
            }
            var extras: [String: Any] = [
                "operation": operation,
                "target_identity": identity,
                "what_was_attempted": "locate the occupied plugin at insert \(insert)",
                "what_was_observed": observed,
                "safe_to_retry": false,
                "write_attempted": false,
            ]
            if let recoveryHint {
                extras["recovery_hint"] = recoveryHint
            }
            return .error(HonestContract.encodeV2StateC(error: .incompleteInventory, extras: extras))
        }

        let observedPluginName = slots[insert].name
        let observedPluginID = observedPluginName.flatMap(VerifiedPluginCatalog.pluginID(forObservedName:))
        if let refusal = pluginInsertReferenceGuard(params: referenceParams, slot: slots[insert], operation: operation) {
            return refusal
        }
        guard observedPluginID == pluginID else {
            return .error(HonestContract.encodeV2StateC(
                error: .targetPluginMismatch,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "requested_plugin_id": pluginID,
                    "observed_plugin_id": observedPluginID ?? NSNull(),
                    "observed_plugin_name": observedPluginName ?? NSNull(),
                    "observed_slot": insert,
                    "what_was_attempted": "verify insert \(insert) contains \(pluginID) before opening its window",
                    "what_was_observed": observedPluginName.map {
                        "insert \(insert) contains '\($0)'"
                    } ?? "insert \(insert) plugin name was unreadable",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        }

        let conflictingInsertIndices = slots.compactMap { slot -> Int? in
            guard slot.occupied,
                  slot.readStatus == .occupiedReadable,
                  let name = slot.name,
                  VerifiedPluginCatalog.pluginID(forObservedName: name) == pluginID else {
                return nil
            }
            return slot.index
        }
        let duplicatedPluginInstance = conflictingInsertIndices.count > 1
        let trackName = target.trackName
        var constructedWindow: AXUIElementSendable?
        // Set immediately after the target-slot press observes windows. It is
        // deliberately outside the success-only branch: a hidden sibling can
        // make acquisition fail with two editors, and every newly observed
        // editor from that failed attempt still needs best-effort cleanup.
        var constructedWindowsNeedingCleanup: [AXUIElement] = []
        var restorePluginViewOnExit: (() -> ControlsViewBooleanParameterWriter.ViewRestoration)?
        var readContextEnded = false
        var acquisitionActionAttempted = false
        func acquisitionAllowed() -> Bool {
            guard let contextIsCurrent = access.readContextIsCurrent else { return true }
            guard !readContextEnded, contextIsCurrent(),
                  targetPluginIdentityIsStable(target: target, insert: insert, pluginID: pluginID,
                    originalSlot: slots[insert].element, runtime: runtime) else {
                readContextEnded = true
                return false
            }
            return true
        }
        func beginAcquisitionAction() -> Bool {
            guard acquisitionAllowed() else { return false }
            acquisitionActionAttempted = true
            return true
        }
        func editorCloseAllowed(_ window: AXUIElement) -> Bool {
            guard let contextIsCurrent = access.readContextIsCurrent else { return true }
            guard !readContextEnded, contextIsCurrent(),
                  targetPluginIdentityIsStable(target: target, insert: insert, pluginID: pluginID,
                    originalSlot: slots[insert].element, runtime: runtime),
                  case .success(let editors) = AXLogicProElements.matchingPluginEditorWindows(
                    forTrackName: trackName, matchingPluginID: pluginID, runtime: runtime),
                  editors.contains(where: { CFEqual($0, window) }) else {
                readContextEnded = true
                return false
            }
            return true
        }
        defer {
            if !constructedWindowsNeedingCleanup.isEmpty {
                _ = closePluginEditorsOpenedByThisOperation(
                    constructedWindowsNeedingCleanup,
                    trackName: trackName,
                    pluginID: pluginID,
                    runtime: runtime,
                    allowingChanges: editorCloseAllowed
                )
            }
        }

        func append(
            pluginViewRestoration restoration: ControlsViewBooleanParameterWriter.ViewRestoration?,
            to extras: inout [String: Any]
        ) {
            guard let restoration else { return }
            extras["plugin_view_restore_attempted"] = restoration.attempted
            extras["plugin_view_restore_observed"] = restoration.confirmed
            if restoration.leftViewChanged {
                extras["plugin_view_left_changed"] = true
                extras["plugin_view_restore_observed_structure"] = restoration.observedStructure ?? NSNull()
                extras["plugin_view_restore_recovery_hint"] = "The plug-in view could not be restored to the view observed before this operation. Select the prior view manually before continuing."
            } else if !restoration.confirmed {
                // A failed restore confirmation does not establish that the
                // view changed. When AX cannot classify the current view, say
                // exactly that rather than reporting an unobserved change.
                extras["plugin_view_restore_unobserved"] = true
                extras["plugin_view_restore_observed_structure"] = restoration.observedStructure ?? NSNull()
                extras["plugin_view_restore_recovery_hint"] = "The plug-in view restoration could not be observed. Verify the prior view before continuing."
            }
        }

        func appendPluginViewRestoration(to extras: inout [String: Any]) {
            append(pluginViewRestoration: restorePluginViewOnExit?(), to: &extras)
        }

        func appendOwnedEditorCleanup(to extras: inout [String: Any]) {
            if access.isRead {
                extras["opener_action_attempted"] = acquisitionActionAttempted
                if constructedWindowsNeedingCleanup.isEmpty, acquisitionActionAttempted, readContextEnded {
                    extras["editor_cleanup_unobserved"] = true
                }
            }
            guard !constructedWindowsNeedingCleanup.isEmpty else { return }
            let windows = constructedWindowsNeedingCleanup
            var closeAttempted = false
            let closeObserved = closePluginEditorsOpenedByThisOperation(
                windows,
                trackName: trackName,
                pluginID: pluginID,
                runtime: runtime,
                allowingChanges: { window in
                    guard editorCloseAllowed(window) else { return false }
                    closeAttempted = true
                    return true
                }
            )
            // This explicit attempt owns cleanup on success and refusal alike.
            constructedWindowsNeedingCleanup.removeAll()
            extras["editor_close_observed"] = closeObserved
            if access.isRead { extras["editor_close_attempted"] = closeAttempted }
            if !closeObserved {
                if access.isRead, readContextEnded {
                    extras["editor_cleanup_unobserved"] = true
                    extras["recovery_hint"] = "Editor ownership ended before cleanup could be confirmed. Inspect the open editor manually before continuing."
                } else if !access.isRead || windows.contains(where: {
                    AXLogicProElements.pluginEditorWindowIsOpen($0, runtime: runtime) == true
                }) {
                    extras["editor_still_open"] = true
                    extras["recovery_hint"] = "The \(pluginID) editor opened for this operation is still visible on track \(track). Close it before another duplicate-instance write."
                } else {
                    extras["editor_cleanup_unobserved"] = true
                }
            }
        }

        /// Data verification and UI cleanup are distinct outcomes. Failed
        /// cleanup is reported; later read-context loss invalidates sampled data.
        func verifiedParameterEnvelope(extras: [String: Any]) -> String {
            var completedExtras = extras
            appendPluginViewRestoration(to: &completedExtras)
            appendOwnedEditorCleanup(to: &completedExtras)
            return HonestContract.encodeV2StateA(extras: completedExtras)
        }

        /// One terminal funnel owns temporary-view cleanup for every State C
        /// below. Returning an already encoded State C from the body is safe:
        /// the funnel decodes it once, performs restoration before it is exposed,
        /// and adds the observed outcome. New early exits cannot bypass it.
        func finishPluginViewSessionResult(_ result: ChannelResult) -> ChannelResult {
            guard case let .error(raw) = result,
                  let data = raw.data(using: .utf8),
                  var envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  envelope["state"] as? String == "C" else {
                return result
            }
            var extras: [String: Any] = [:]
            appendPluginViewRestoration(to: &extras)
            appendOwnedEditorCleanup(to: &extras)
            for (key, value) in extras {
                envelope[key] = value
            }
            guard let encoded = try? JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys]
            ), let message = String(data: encoded, encoding: .utf8) else {
                return result
            }
            return .error(message)
        }

        func stateCWithPluginViewRestoration(
            error: HonestContract.FailureError,
            extras: [String: Any]
        ) -> String {
            // The name remains at the Controls helper boundary; restoration is
            // applied by `finishPluginViewSessionResult`, not at each exit site.
            HonestContract.encodeV2StateC(error: error, extras: extras)
        }

        let resultAfterAcquisition: ChannelResult = await {
        if duplicatedPluginInstance {
            // #726 follow-up measurement: when no matching editor is open, one
            // target-slot `열기` press creates the target editor. A pre-existing
            // editor makes the result indistinguishable, and a hidden sibling can
            // make one press restore two editors. These header-proven counts are
            // therefore the provenance proof; neither geometry nor name-only
            // reuse chooses the editor in this branch.
            let matchingEditorsBeforePress: [AXUIElement]
            switch AXLogicProElements.matchingPluginEditorWindows(
                forTrackName: trackName,
                matchingPluginID: pluginID,
                runtime: runtime
            ) {
            case let .success(observed):
                matchingEditorsBeforePress = observed
            case let .failure(error):
                return .error(pluginWindowReadFailureStateC(
                    operation,
                    identity,
                    error,
                    phase: "the duplicate-editor pre-count before target-slot AXPress"
                ))
            }
            guard matchingEditorsBeforePress.isEmpty else {
                return .error(duplicatePluginEditorAlreadyOpenStateC(
                    operation: operation,
                    identity: identity,
                    pluginID: pluginID,
                    track: track,
                    insert: insert,
                    conflictingInsertIndices: conflictingInsertIndices,
                    matchingEditorCount: matchingEditorsBeforePress.count
                ))
            }

            // Retain the existing static-header guard: an editor that exposes
            // this track and parameter but cannot prove the requested plug-in is
            // not evidence of a clean, matching pre-count.
            if case let .pluginIdentityMismatch(observedNames) = AXLogicProElements.pluginWindowMatch(
                forTrackName: trackName,
                matchingPluginID: pluginID,
                matchingSliderDescription: axDescription,
                requiringMatchingSlider: requiringWindowSlider,
                runtime: runtime
            ) {
                return .error(pluginWindowPluginMismatchStateC(
                    operation,
                    identity,
                    pluginID: pluginID,
                    observedNames: observedNames
                ))
            }
            if case let .unreadable(error) = AXLogicProElements.pluginWindowMatch(
                forTrackName: trackName,
                matchingPluginID: pluginID,
                matchingSliderDescription: axDescription,
                requiringMatchingSlider: requiringWindowSlider,
                runtime: runtime
            ) {
                return .error(pluginWindowReadFailureStateC(
                    operation,
                    identity,
                    error,
                    phase: "the duplicate-editor identity census before target-slot AXPress"
                ))
            }

            guard let targetOpenControl = rankedPluginSlotOpenControls(
                in: slots[insert].element,
                runtime: runtime.ax
            ).first(where: { $0.rank == 0 })?.element else {
                return .error(windowOpenFailedStateC(
                    operation,
                    identity,
                    "the target insert exposes no AXPress-capable open control",
                    diagnostics: pluginWindowAcquisitionDiagnostics(
                        trackName: trackName,
                        axDescription: axDescription,
                        runtime: runtime
                    )
                ))
            }

            // Real Logic can report a non-zero AX status after opening the
            // editor, so that status cannot authenticate the action. Instead,
            // retain the complete pre-press editor set and require the accepted
            // candidate to be a new AX element. This is the strongest evidence
            // AX exposes here: we rely on Logic UI actions being serialized for
            // this operation. AX has no causal event token, so a concurrent
            // human or other automation opening the same-track sibling between
            // the snapshot and poll remains unprovable; the one-new-window rule
            // makes that uncertainty refuse rather than reuse an old editor.
            let pluginEditorWindowsBeforePress: [AXUIElement]
            switch AXLogicProElements.pluginEditorWindows(runtime: runtime) {
            case let .success(observed):
                pluginEditorWindowsBeforePress = observed
            case let .failure(error):
                return .error(pluginWindowReadFailureStateC(
                    operation,
                    identity,
                    error,
                    phase: "the complete editor census before target-slot AXPress"
                ))
            }
            guard beginAcquisitionAction() else {
                return .error(windowIdentityUnresolvedStateC(operation, identity,
                    "the read's acquired context ended before opening its editor"))
            }
            _ = pressElement(targetOpenControl, runtime: runtime.ax)
            let matchingEditorsAfterPress: [AXUIElement]
            switch await pollMatchingPluginEditorWindows(
                trackName: trackName,
                pluginID: pluginID,
                runtime: runtime,
                timeoutMs: 1_250,
                contextIsCurrent: acquisitionAllowed
            ) {
            case let .success(observed):
                matchingEditorsAfterPress = observed
            case let .failure(error):
                return .error(pluginWindowReadFailureStateC(
                    operation,
                    identity,
                    error,
                    phase: "the duplicate-editor post-press census"
                ))
            }
            let newlyObservedMatchingEditors = matchingEditorsAfterPress.filter { candidate in
                !pluginEditorWindowsBeforePress.contains { CFEqual($0, candidate) }
            }
            // A target press may have restored a hidden sibling as well. These
            // are newly observed during this operation's acquisition window;
            // install best-effort cleanup before any mismatch return can leave
            // an editor that this attempt may have opened behind.
            constructedWindowsNeedingCleanup = newlyObservedMatchingEditors
            guard matchingEditorsAfterPress.count == 1,
                  newlyObservedMatchingEditors.count == 1 else {
                if case let .pluginIdentityMismatch(observedNames) = AXLogicProElements.pluginWindowMatch(
                    forTrackName: trackName,
                    matchingPluginID: pluginID,
                    matchingSliderDescription: axDescription,
                    requiringMatchingSlider: requiringWindowSlider,
                    runtime: runtime
                ) {
                    return .error(pluginWindowPluginMismatchStateC(
                        operation,
                        identity,
                        pluginID: pluginID,
                        observedNames: observedNames
                    ))
                }
                return .error(duplicatePluginEditorCountMismatchStateC(
                    operation: operation,
                    identity: identity,
                    pluginID: pluginID,
                    track: track,
                    insert: insert,
                    conflictingInsertIndices: conflictingInsertIndices,
                    matchingEditorCount: matchingEditorsAfterPress.count,
                    newlyObservedMatchingEditorCount: newlyObservedMatchingEditors.count
                ))
            }
            // `matchingPluginEditorWindows` accepts a window only after its
            // direct static-text header maps to the requested plug-in id.
            constructedWindow = AXUIElementSendable(newlyObservedMatchingEditors[0])
        }

        // Step 8 — normal single-instance acquisition retains the original
        // name/parameter resolution and opener behaviour. For a duplicated
        // instance, `constructedWindow` above is already proven by the one
        // target-slot press and the two editor counts.
        let preAcquisitionWindowMatch = AXLogicProElements.pluginWindowMatch(
            forTrackName: trackName,
            matchingPluginID: pluginID,
            matchingSliderDescription: axDescription,
            requiringMatchingSlider: requiringWindowSlider,
            runtime: runtime
        )
        switch preAcquisitionWindowMatch {
        case let .unreadable(error):
            return .error(pluginWindowReadFailureStateC(
                operation,
                identity,
                error,
                phase: "the plugin-window acquisition census"
            ))
        case .ambiguous:
            var diagnostics = pluginWindowAcquisitionDiagnostics(
                trackName: trackName,
                axDescription: axDescription,
                runtime: runtime
            )
            diagnostics["opener_action_attempted"] = false
            diagnostics.merge(pluginPopupMenuCleanupDiagnostics(pluginPopupMenuCleaner(runtime))) { _, new in new }
            return .error(windowIdentityUnresolvedStateC(
                operation,
                identity,
                "more than one plugin-editor window exposes the requested track and parameter identity",
                diagnostics: diagnostics
            ))
        case let .pluginIdentityMismatch(observedNames):
            return .error(pluginWindowPluginMismatchStateC(
                operation,
                identity,
                pluginID: pluginID,
                observedNames: observedNames
            ))
        case .none, .unique:
            break
        }
        // A reused editor belongs to the caller, so the cleanup defer may only
        // own an editor that was absent from this complete pre-open census.
        // Take the snapshot before the normal opener can press its target slot;
        // this covers every later refusal, including a View-session refusal
        // immediately after a successful acquisition.
        let pluginEditorWindowsBeforeNormalAcquisition: [AXUIElement]?
        if constructedWindow == nil, case .none = preAcquisitionWindowMatch {
            switch AXLogicProElements.pluginEditorWindows(runtime: runtime) {
            case let .success(observed):
                pluginEditorWindowsBeforeNormalAcquisition = observed
            case let .failure(error):
                return .error(pluginWindowReadFailureStateC(
                    operation,
                    identity,
                    error,
                    phase: "the complete editor census before normal target-slot acquisition"
                ))
            }
        } else {
            pluginEditorWindowsBeforeNormalAcquisition = nil
        }
        let openedCandidate: AXUIElementSendable?
        if let constructedWindow {
            openedCandidate = constructedWindow
        } else if case let .unique(boundWindow) = preAcquisitionWindowMatch {
            // The header-aware matcher is the binding for a reused editor.
            // It cannot require the native slider because the remembered view
            // may be Controls; the requested view is selected below.
            openedCandidate = AXUIElementSendable(boundWindow)
        } else if usesControlsView || (access.isRead && access.readOpenerOverride == nil) {
            openedCandidate = await openPluginWindowFromTargetSlot(
                slots[insert].element,
                pluginID: pluginID,
                trackName: trackName,
                axDescription: controlsViewEditorAnchor ?? "",
                requiringMatchingSlider: false,
                runtime: runtime,
                allowingChanges: beginAcquisitionAction,
                contextIsCurrent: acquisitionAllowed
            )
        } else {
            guard beginAcquisitionAction() else {
                return .error(windowIdentityUnresolvedStateC(operation, identity,
                    "the read's acquired context ended before its editor opener"))
            }
            openedCandidate = await pluginWindowOpener(
                AXUIElementSendable(slots[insert].element),
                pluginID,
                trackName,
                axDescription,
                runtime
            )
        }
        guard let opened = openedCandidate else {
            // The opener can observe the exact new editor and then refuse its
            // frontness. That refusal must not discard custody of a window this
            // read created. Never close a pre-existing or ambiguously new editor.
            if access.isRead, acquisitionActionAttempted,
               let before = pluginEditorWindowsBeforeNormalAcquisition,
               case let .success(editors) = AXLogicProElements.matchingPluginEditorWindows(
                    forTrackName: trackName, matchingPluginID: pluginID, runtime: runtime) {
                let created = editors.filter { candidate in !before.contains { CFEqual($0, candidate) } }
                if created.count == 1 { constructedWindowsNeedingCleanup = created }
            }
            // A polling attempt may have observed a same-track editor with the
            // requested control but the wrong (or unreadable) header. Report
            // that identity failure directly; a concurrent popup-cleanup issue
            // must not hide the reason the editor was refused.
            if case let .pluginIdentityMismatch(observedNames) = AXLogicProElements.pluginWindowMatch(
                forTrackName: trackName,
                matchingPluginID: pluginID,
                matchingSliderDescription: axDescription,
                requiringMatchingSlider: requiringWindowSlider,
                runtime: runtime
            ) {
                return .error(pluginWindowPluginMismatchStateC(
                    operation,
                    identity,
                    pluginID: pluginID,
                    observedNames: observedNames
                ))
            }
            let popupCleanup = pluginPopupMenuCleaner(runtime)
            if !popupCleanup.isClean {
                var diagnostics = pluginWindowAcquisitionDiagnostics(
                    trackName: trackName,
                    axDescription: axDescription,
                    runtime: runtime
                )
                diagnostics.merge(pluginPopupMenuCleanupDiagnostics(popupCleanup)) { _, new in new }
                return .error(windowOpenFailedStateC(
                    operation,
                    identity,
                    "a Logic popup menu remained open after plugin-window acquisition",
                    diagnostics: diagnostics,
                    safeToRetry: false
                ))
            }
            switch AXLogicProElements.pluginWindowMatch(
                forTrackName: trackName,
                matchingPluginID: pluginID,
                matchingSliderDescription: axDescription,
                requiringMatchingSlider: requiringWindowSlider,
                runtime: runtime
            ) {
            case let .unreadable(error):
                return .error(pluginWindowReadFailureStateC(
                    operation,
                    identity,
                    error,
                    phase: "the plugin-window acquisition retry census"
                ))
            case .ambiguous:
                var diagnostics = pluginWindowAcquisitionDiagnostics(
                    trackName: trackName,
                    axDescription: axDescription,
                    runtime: runtime
                )
                diagnostics["opener_action_attempted"] = true
                return .error(windowIdentityUnresolvedStateC(
                    operation,
                    identity,
                    "more than one plugin-editor window exposed the requested track and parameter identity after acquisition",
                    diagnostics: diagnostics
                ))
            case let .pluginIdentityMismatch(observedNames):
                return .error(pluginWindowPluginMismatchStateC(
                    operation,
                    identity,
                    pluginID: pluginID,
                    observedNames: observedNames
                ))
            case .none, .unique:
                break
            }
            return .error(windowOpenFailedStateC(
                operation, identity,
                "no open plugin window titled '\(trackName)' exposes the '\(axDescription)' control, and one could not be opened",
                diagnostics: pluginWindowAcquisitionDiagnostics(
                    trackName: trackName,
                    axDescription: axDescription,
                    runtime: runtime
                )
            ))
        }
        let window = opened.element
        if let beforeNormalAcquisition = pluginEditorWindowsBeforeNormalAcquisition,
           !beforeNormalAcquisition.contains(where: { CFEqual($0, window) }) {
            // Register the acquired editor before popup or view setup can refuse.
            constructedWindowsNeedingCleanup = [window]
        }
        let popupCleanup = pluginPopupMenuCleaner(runtime)
        guard popupCleanup.isClean else {
            var diagnostics = pluginWindowAcquisitionDiagnostics(
                trackName: trackName,
                axDescription: axDescription,
                runtime: runtime
            )
            diagnostics.merge(pluginPopupMenuCleanupDiagnostics(popupCleanup)) { _, new in new }
            return .error(windowOpenFailedStateC(
                operation,
                identity,
                "a Logic popup menu remained open after plugin-window acquisition",
                diagnostics: diagnostics,
                safeToRetry: false
            ))
        }
        let requiredView: ControlsViewBooleanParameterWriter.PluginWindowView = (usesControlsView || access.isEQStateRead)
            ? .controls
            : .editor
        // Logic can replace the editor's AX window/switcher during a View
        // re-render. Rebind only when the already identity-verified editor is
        // uniquely recoverable; a same-track duplicate remains ambiguous rather
        // than letting a stale handle select a sibling's view.
        let refreshPluginWindowForViewSelection: () -> AXUIElement? = {
            switch AXLogicProElements.matchingPluginEditorWindows(
                forTrackName: trackName,
                matchingPluginID: pluginID,
                runtime: runtime
            ) {
            case let .success(editors) where editors.count == 1:
                return editors[0]
            case .success, .failure:
                return nil
            }
        }
        let viewSession: ControlsViewBooleanParameterWriter.ViewSession
        func viewChangesAllowed() -> Bool {
            guard let contextIsCurrent = access.readContextIsCurrent else { return true }
            guard !readContextEnded, contextIsCurrent(),
                  targetPluginIdentityIsStable(target: target, insert: insert, pluginID: pluginID,
                    originalSlot: slots[insert].element, runtime: runtime),
                  case .success(let editors) = AXLogicProElements.matchingPluginEditorWindows(
                    forTrackName: trackName, matchingPluginID: pluginID, runtime: runtime),
                  editors.count == 1, CFEqual(editors[0], window) else {
                readContextEnded = true
                return false
            }
            return true
        }
        func readViewIsBound(_ view: ControlsViewBooleanParameterWriter.PluginWindowView) -> Bool {
            guard viewChangesAllowed() else { return false }
            if view == .controls {
                guard let controlsViewRowLabel,
                      case let .success(controls) = ControlsViewBooleanParameterWriter.rowControls(
                        label: controlsViewRowLabel, in: window, runtime: runtime.ax),
                      !controls.isEmpty else { return false }
            }
            return viewChangesAllowed()
        }
        switch ControlsViewBooleanParameterWriter.prepareView(
            requiredView,
            in: window,
            windowRefresher: refreshPluginWindowForViewSelection,
            allowingChanges: viewChangesAllowed,
            headerBoundUndescribedView: access.isRead && controlsReadKind != nil ? readViewIsBound : nil,
            runtime: runtime.ax
        ) {
        case let .refused(failure, restoration):
            var extras: [String: Any] = [
                "operation": operation,
                "target_identity": identity,
                "param": paramAlias,
                "what_was_attempted": "select the plugin-window View menu item and confirm the required \(requiredView.rawValue) structure before locating its control",
                "what_was_observed": failure.observation,
                "safe_to_retry": false,
                "write_attempted": false,
            ]
            extras.merge(failure.responseDiagnostics) { _, new in new }
            // `prepareView` can have picked the target item before its structural
            // confirmation times out. Its compensating re-selection has no
            // ViewSession yet, so carry that observed attempt explicitly.
            append(pluginViewRestoration: restoration, to: &extras)
            return .error(HonestContract.encodeV2StateC(
                // The slider locator has not run. Keep a failed structural
                // confirmation distinct from a genuine missing AXSlider so the
                // live response shows whether view selection was reached.
                error: .pluginViewNotConfirmed,
                extras: extras
            ))
        case let .ready(session):
            viewSession = session
        }
        restorePluginViewOnExit = { viewSession.restore(allowingChanges: viewChangesAllowed) }
        let resultAfterViewPreparation: ChannelResult = {
        if let controlsReadKind, let controlsViewRowLabel,
           case let .read(rawUnit, contextIsCurrent, _) = access {
            func currentInstance() -> Bool {
                contextIsCurrent() && targetPluginIdentityIsStable(
                    target: target, insert: insert, pluginID: pluginID,
                    originalSlot: slots[insert].element, runtime: runtime
                ) && controlsViewAcquiredPluginWindowFailureStateC(
                    acquiredWindow: window, operation: operation, identity: identity,
                    pluginID: pluginID, trackName: trackName, runtime: runtime
                ) == nil
            }
            guard currentInstance() else {
                readContextEnded = true
                return .error(windowIdentityUnresolvedStateC(operation, identity,
                    "the acquired target/editor context ended before its Controls-view read"))
            }
            let observation = ControlsViewParameterReader.observe(kind: controlsReadKind,
                label: controlsViewRowLabel, in: window, runtime: runtime.ax)
            guard currentInstance() else {
                readContextEnded = true
                return .error(windowIdentityUnresolvedStateC(operation, identity,
                    "the acquired target/editor context ended during its Controls-view read"))
            }
            var extras: [String: Any] = [
                "operation": operation, "target_identity": identity, "param": paramAlias,
                "raw_unit": rawUnit, "observation_scope": "current_insert_parameter",
                "verify_source": "ax_plugin_window", "write_attempted": false,
            ]
            switch observation {
            case let .read(raw, display):
                extras["observed_raw"] = raw
                extras["observed_display"] = display
                extras["display_read_status"] = "read"
                extras["parameter_read_status"] = "read"
                return .success(verifiedParameterEnvelope(extras: extras))
            case let .unavailable(status):
                extras["parameter_read_status"] = status
                // State B is a successful transport response, so explicitly
                // finish the owned UI work before encoding it, as EQ reads do.
                appendPluginViewRestoration(to: &extras)
                appendOwnedEditorCleanup(to: &extras)
                return .success(HonestContract.encodeV2StateB(reason: .readbackUnavailable, extras: extras))
            }
        }
        if access.isEQStateRead, let contextIsCurrent = access.readContextIsCurrent {
            let instanceIsCurrent: () -> Bool = {
                contextIsCurrent() && targetPluginIdentityIsStable(
                    target: target, insert: insert, pluginID: pluginID,
                    originalSlot: slots[insert].element, runtime: runtime
                ) && controlsViewAcquiredPluginWindowFailureStateC(
                    acquiredWindow: window, operation: operation, identity: identity,
                    pluginID: pluginID, trackName: trackName, runtime: runtime
                ) == nil
            }
            var extras = ChannelEQControlsStateReader.collect(
                in: window, runtime: runtime.ax, contextIsCurrent: instanceIsCurrent
            )
            extras["operation"] = operation
            extras["target_identity"] = identity
            extras["verify_source"] = "ax_plugin_window"
            extras["write_attempted"] = false
            appendPluginViewRestoration(to: &extras)
            appendOwnedEditorCleanup(to: &extras)
            return .success(extras["complete"] as? Bool == true
                ? HonestContract.encodeV2StateA(extras: extras)
                : HonestContract.encodeV2StateB(reason: .readbackUnavailable, extras: extras))
        }
        func unavailableRead(_ status: String, error: AXHelpers.AXStatusError? = nil) -> ChannelResult {
            var extras: [String: Any] = ["operation": operation, "param": paramAlias,
                "parameter_read_status": status, "write_attempted": false]
            if let error { extras["parameter_read_error"] = error.diagnosticLabel }
            return .error(HonestContract.encodeV2StateC(error: .readbackUnavailable, extras: extras))
        }
        func finiteNumericValue(_ raw: AnyObject?) -> Double? {
            let value: Double?
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                value = number.doubleValue
            } else if let text = raw as? String { value = Double(text) }
            else { value = nil }
            guard let value, value.isFinite else { return nil }
            return value
        }
        func parameterDisplay(_ control: AXUIElement) -> (value: String?, status: String) {
            switch AXHelpers.getAttributeResult(control, kAXValueDescriptionAttribute as String, runtime: runtime.ax)
                as Result<AnyObject?, AXHelpers.AXStatusError> {
            case .success(.none): return (nil, "absent")
            case .success(.some(let value)):
                guard let text = value as? String else { return (nil, "malformed") }
                return (text, "read")
            case .failure(let error): return (nil, error.isDefinitiveAbsence ? "absent" : "unreadable")
            }
        }
        if controlsViewCheckbox, let controlsViewRowLabel {
            // This must run before the legacy slider locator: Controls view
            // deliberately removes the parameter's identity from the control
            // and places it on an AXRow label instead. The existing Threshold
            // slider path selects the paired native editor view below.
            guard targetPluginIdentityIsStable(
                target: target,
                insert: insert,
                pluginID: pluginID,
                originalSlot: slots[insert].element,
                runtime: runtime
            ) else {
                return .error(windowIdentityUnresolvedStateC(
                    operation,
                    identity,
                    "the target plugin slot identity was not stable immediately before Controls-view checkbox actuation"
                ))
            }
            if let failure = controlsViewAcquiredPluginWindowFailureStateC(
                acquiredWindow: window,
                operation: operation,
                identity: identity,
                pluginID: pluginID,
                trackName: trackName,
                runtime: runtime
            ) {
                return .error(failure)
            }
            if case let .read(rawUnit, contextIsCurrent, _) = access {
                let checkbox: AXUIElement
                switch ControlsViewBooleanParameterWriter.locate(label: controlsViewRowLabel, in: window, runtime: runtime.ax) {
                case .found(.checkBox(let control)): checkbox = control
                case .found, .refused:
                    return .error(HonestContract.encodeV2StateC(error: .paramControlNotFound,
                        extras: ["operation": operation, "param": paramAlias,
                            "parameter_read_status": "unknown", "write_attempted": false]))
                }
                func currentControl() -> Bool {
                    guard contextIsCurrent(),
                          targetPluginIdentityIsStable(target: target, insert: insert, pluginID: pluginID,
                            originalSlot: slots[insert].element, runtime: runtime),
                          controlsViewAcquiredPluginWindowFailureStateC(acquiredWindow: window, operation: operation,
                            identity: identity, pluginID: pluginID, trackName: trackName, runtime: runtime) == nil,
                          case .found(.checkBox(let current)) = ControlsViewBooleanParameterWriter.locate(
                            label: controlsViewRowLabel, in: window, runtime: runtime.ax), CFEqual(current, checkbox) else { return false }
                    return true
                }
                guard currentControl() else {
                    return .error(windowIdentityUnresolvedStateC(operation, identity, "the read's acquired target/editor/control context ended"))
                }
                let observed: Bool
                switch AXValueExtractors.extractButtonStateResult(checkbox, runtime: runtime.ax) {
                case .success(.some(let value)): observed = value
                case .success(.none):
                    return .error(HonestContract.encodeV2StateC(error: .readbackUnavailable,
                        extras: ["operation": operation, "param": paramAlias,
                            "parameter_read_status": "unknown", "write_attempted": false]))
                case .failure(let error):
                    return .error(HonestContract.encodeV2StateC(error: .readbackUnavailable,
                        extras: ["operation": operation, "param": paramAlias,
                            "parameter_read_status": "unreadable", "parameter_read_error": error.diagnosticLabel,
                            "write_attempted": false]))
                }
                let display = parameterDisplay(checkbox)
                switch AXValueExtractors.extractButtonStateResult(checkbox, runtime: runtime.ax) {
                case .success(.some(let latest)):
                    guard latest == observed else { return unavailableRead("unstable") }
                case .success(.none): return unavailableRead("unknown")
                case .failure(let error): return unavailableRead("unreadable", error: error)
                }
                guard currentControl() else {
                    return .error(windowIdentityUnresolvedStateC(operation, identity, "the read's acquired target/editor/control context ended after its Boolean read"))
                }
                return .success(verifiedParameterEnvelope(extras: [
                    "operation": operation, "target_identity": identity, "param": paramAlias,
                    "observed_raw": observed, "raw_unit": rawUnit,
                    "observed_display": display.value ?? NSNull(), "display_read_status": display.status,
                    "parameter_read_status": "read", "observation_scope": "current_insert_parameter",
                    "verify_source": "ax_plugin_window", "write_attempted": false,
                ]))
            }
            guard case let .write(requested, _, _, _) = access else {
                return .error(HonestContract.encodeV2StateC(error: .unsupportedParamReadback,
                    extras: ["operation": operation, "parameter_read_status": "unsupported", "write_attempted": false]))
            }
            return performControlsViewCheckboxWrite(
                operation: operation,
                identity: identity,
                paramAlias: paramAlias,
                requested: requested,
                rowLabel: controlsViewRowLabel,
                window: window,
                runtime: runtime.ax,
                verifiedWriteEnvelope: verifiedParameterEnvelope,
                stateCWithPluginViewRestoration: stateCWithPluginViewRestoration,
                allowingPress: { checkbox, before in
                    guard let expected = PluginSagaExpectedBefore.current else { return true }
                    guard expected.matches(track: track, insert: insert, pluginID: pluginID, param: paramKey,
                        projectPath: referenceParams["project_expected_path"] ?? "", observed: .bool(before)),
                        pluginRollbackOperationIsCurrent(),
                        targetPluginIdentityIsStable(target: target, insert: insert, pluginID: pluginID,
                            originalSlot: slots[insert].element, runtime: runtime),
                        controlsViewAcquiredPluginWindowFailureStateC(acquiredWindow: window, operation: operation,
                            identity: identity, pluginID: pluginID, trackName: trackName, runtime: runtime) == nil,
                        case .found(.checkBox(let current)) = ControlsViewBooleanParameterWriter.locate(
                            label: controlsViewRowLabel, in: window, runtime: runtime.ax), CFEqual(current, checkbox),
                        case .success(.some(let latest)) = AXValueExtractors.extractButtonStateResult(checkbox, runtime: runtime.ax),
                        latest == before else { return false }
                    return pluginRollbackOperationIsCurrent()
                }
            )
        }

        // Step 9 — slider match by AXDescription (the only stable identifier).
        // The view is confirmed native above, so this is the first parameter
        // lookup. An ambiguous description is a window-identity refusal, never
        // a positional choice between two sliders.
        let slider: AXUIElement
        switch AXLogicProElements.pluginWindowSliderResolution(
            in: window, axDescription: axDescription, runtime: runtime.ax
        ) {
        case let .unique(found):
            slider = found
        case .ambiguous:
            return .error(windowIdentityUnresolvedStateC(
                operation,
                identity,
                "more than one slider exposed the requested AXDescription in the confirmed native plugin view"
            ))
        case let .unreadable(error):
            return .error(stateCWithPluginViewRestoration(
                error: .windowIdentityUnresolved,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "param": paramAlias,
                    "slider_description_read_failure": error.diagnosticLabel,
                    "what_was_attempted": "locate the '\(axDescription)' AXSlider in the plugin window",
                    "what_was_observed": "no slider with that AX description was observed, and another slider's AXDescription read failed (AX status \(error.diagnosticLabel)); the control was not treated as absent",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        case .none:
            return .error(stateCWithPluginViewRestoration(
                error: .paramControlNotFound,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "param": paramAlias,
                    "what_was_attempted": "locate the '\(axDescription)' AXSlider in the plugin window",
                    "what_was_observed": "no slider with that AX description was found in the plugin window",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        }

        if let failure = acquiredPluginWindowFailureStateC(
            acquiredWindow: window,
            operation: operation,
            identity: identity,
            pluginID: pluginID,
            trackName: trackName,
            axDescription: axDescription,
            detail: "the acquired plugin window was no longer the unique matching window before the write",
            runtime: runtime
        ) {
            return .error(failure)
        }

        if case let .read(rawUnit, contextIsCurrent, _) = access {
            func currentControl() -> Bool {
                guard contextIsCurrent(),
                      targetPluginIdentityIsStable(target: target, insert: insert, pluginID: pluginID,
                        originalSlot: slots[insert].element, runtime: runtime),
                      acquiredPluginWindowFailureStateC(acquiredWindow: window, operation: operation,
                        identity: identity, pluginID: pluginID, trackName: trackName,
                        axDescription: axDescription, detail: "the editor changed during the parameter read", runtime: runtime) == nil,
                      case .unique(let current) = AXLogicProElements.pluginWindowSliderResolution(
                        in: window, axDescription: axDescription, runtime: runtime.ax), CFEqual(current, slider) else { return false }
                return true
            }
            guard currentControl() else {
                return .error(windowIdentityUnresolvedStateC(operation, identity, "the read's acquired target/editor/control context ended"))
            }
            let raw: AnyObject?
            switch AXHelpers.getAttributeResult(slider, kAXValueAttribute as String, runtime: runtime.ax)
                as Result<AnyObject?, AXHelpers.AXStatusError> {
            case .success(let value): raw = value
            case .failure(let error):
                return .error(HonestContract.encodeV2StateC(error: .readbackUnavailable,
                    extras: ["operation": operation, "param": paramAlias, "write_attempted": false,
                        "parameter_read_status": error.isDefinitiveAbsence ? "absent" : "unreadable",
                        "parameter_read_error": error.diagnosticLabel]))
            }
            guard let observed = finiteNumericValue(raw) else {
                return .error(HonestContract.encodeV2StateC(error: .readbackUnavailable,
                    extras: ["operation": operation, "param": paramAlias, "write_attempted": false,
                        "parameter_read_status": raw == nil ? "absent" : "malformed"]))
            }
            let display = parameterDisplay(slider)
            switch AXHelpers.getAttributeResult(slider, kAXValueAttribute as String, runtime: runtime.ax)
                as Result<AnyObject?, AXHelpers.AXStatusError> {
            case .success(let latestRaw):
                guard let latest = finiteNumericValue(latestRaw) else {
                    return unavailableRead(latestRaw == nil ? "absent" : "malformed")
                }
                guard latest == observed else { return unavailableRead("unstable") }
            case .failure(let error):
                return unavailableRead(error.isDefinitiveAbsence ? "absent" : "unreadable", error: error)
            }
            guard currentControl() else {
                return .error(windowIdentityUnresolvedStateC(operation, identity, "the read's acquired target/editor/control context ended after its value read"))
            }
            return .success(verifiedParameterEnvelope(extras: [
                "operation": operation, "target_identity": identity, "param": paramAlias,
                "observed_raw": observed, "raw_unit": rawUnit,
                "observed_display": display.value ?? NSNull(), "display_read_status": display.status,
                "parameter_read_status": "read", "observation_scope": "current_insert_parameter",
                "verify_source": "ax_plugin_window", "write_attempted": false,
            ]))
        }

        guard case let .write(requested, walkTarget, responseDisplayUnit, incrementWalkBudget) = access else {
            return .error(invalidParamsStateC(operation, "missing parameter access"))
        }

        // Step 10 — retain the before value for provenance and a possible owned
        // inverse. It does not authorize compensation if the after-state is lost.
        guard let before = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax), before.isFinite else {
            return .error(HonestContract.encodeV2StateC(
                error: .readbackUnavailable,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "param": paramAlias,
                    "what_was_attempted": "read the '\(axDescription)' slider value before any AXValue write",
                    "what_was_observed": "the slider value could not be read before the write, so no write was attempted without a rollback state",
                    "safe_to_retry": true,
                    "write_attempted": false,
                ]
            ))
        }

        if let failure = acquiredPluginWindowFailureStateC(
            acquiredWindow: window,
            operation: operation,
            identity: identity,
            pluginID: pluginID,
            trackName: trackName,
            axDescription: axDescription,
            detail: "the acquired plugin window was no longer the unique matching window immediately before the write",
            runtime: runtime
        ) {
            return .error(failure)
        }

        guard targetPluginIdentityIsStable(
            target: target,
            insert: insert,
            pluginID: pluginID,
            originalSlot: slots[insert].element,
            runtime: runtime
        ) else {
            return .error(windowIdentityUnresolvedStateC(
                operation,
                identity,
                "the target plugin slot identity was not stable immediately before the write"
            ))
        }

        if let failure = acquiredPluginWindowFailureStateC(
            acquiredWindow: window,
            operation: operation,
            identity: identity,
            pluginID: pluginID,
            trackName: trackName,
            axDescription: axDescription,
            detail: "the acquired plugin window was not unique after target-slot revalidation",
            runtime: runtime
        ) {
            return .error(failure)
        }

        guard let currentSlider = AXLogicProElements.pluginWindowSlider(
            in: window,
            axDescription: axDescription,
            runtime: runtime.ax
        ), CFEqual(currentSlider, slider) else {
            return .error(windowIdentityUnresolvedStateC(
                operation,
                identity,
                "the requested slider identity was not stable immediately before the write"
            ))
        }

        func rollbackTargetIsCurrent() -> Bool {
            guard pluginRollbackOperationIsCurrent(),
                  targetPluginIdentityIsStable(target: target, insert: insert, pluginID: pluginID,
                    originalSlot: slots[insert].element, runtime: runtime),
                  acquiredPluginWindowFailureStateC(acquiredWindow: window, operation: operation,
                    identity: identity, pluginID: pluginID, trackName: trackName,
                    axDescription: axDescription, detail: "the acquired editor changed before rollback", runtime: runtime) == nil,
                  case .unique(let current) = AXLogicProElements.pluginWindowSliderResolution(
                    in: window, axDescription: axDescription, runtime: runtime.ax),
                  CFEqual(current, slider) else { return false }
            return pluginRollbackOperationIsCurrent()
        }

        // Identity reads can outlive the numeric before-read even while every
        // original CF survives. A later user value is not this write's baseline.
        func beforeValueIsCurrent() -> Bool {
            guard rollbackTargetIsCurrent(),
                  let current = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax),
                  current.isFinite, current == before else { return false }
            if let expected = PluginSagaExpectedBefore.current,
               !expected.matches(track: track, insert: insert, pluginID: pluginID, param: paramKey,
                    projectPath: referenceParams["project_expected_path"] ?? "", observed: .double(current)) { return false }
            return pluginRollbackOperationIsCurrent()
        }
        func beforeValueRefusal() -> ChannelResult {
            .error(HonestContract.encodeV2StateC(error: .readbackUnavailable, extras: [
                "operation": operation, "target_identity": identity, "param": paramAlias,
                "before_normalized": before,
                "what_was_attempted": "require the retained before-value and target immediately before the first parameter mutation",
                "what_was_observed": "the current value was changed, unreadable or non-finite, or target/operation ownership ended; no parameter mutation or inverse was sent",
                "write_attempted": false, "rollback_attempted": false, "safe_to_retry": false,
            ]))
        }

        // Step 11 — choose the declared AX write method. Compressor threshold
        // remains a single AXValue assignment; Channel EQ's measured controls
        // require readback-driven AXValue nudges.
        switch writeMethod {
        case "ax_slider_axvalue":
            guard beforeValueIsCurrent() else { return beforeValueRefusal() }
            guard AXValueExtractors.setSliderValue(slider, requested, runtime: runtime.ax) else {
                let rollback = rollbackSliderValue(
                    slider,
                    to: before,
                    ownedAfter: nil,
                    targetIsCurrent: rollbackTargetIsCurrent,
                    writeMethod: writeMethod,
                    tolerance: tolerance,
                    runtime: runtime.ax
                )
                return .error(HonestContract.encodeV2StateC(
                    error: .axWriteFailed,
                    extras: [
                        "operation": operation,
                        "target_identity": identity,
                        "param": paramAlias,
                        "requested_normalized": requested,
                        "what_was_attempted": "set AXValue \(requested) on the '\(axDescription)' slider",
                        "rollback_attempted": rollback.attempted,
                        "rollback_succeeded": rollback.succeeded,
                        "rollback_observed": rollback.observed ?? NSNull(),
                        "rolled_back": rollback.attempted && rollback.succeeded,
                        "parameter_left_changed": rollback.parameterLeftChanged(before: before, tolerance: tolerance),
                        "what_was_observed": "the AX value write was rejected; no inverse was authorized without an owned after-state",
                        "safe_to_retry": rollback.succeeded,
                        "write_attempted": true,
                    ]
                ))
            }

            // Step 12 — read the after value (+ value description). A write
            // that cannot be read back is uncertain, not confirmed — fail closed.
            guard let after = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax) else {
                let rollback = rollbackSliderValue(
                    slider,
                    to: before,
                    ownedAfter: nil,
                    targetIsCurrent: rollbackTargetIsCurrent,
                    writeMethod: writeMethod,
                    tolerance: tolerance,
                    runtime: runtime.ax
                )
                return .error(HonestContract.encodeV2StateC(
                    error: .readbackLostAfterWrite,
                    extras: [
                        "operation": operation,
                        "target_identity": identity,
                        "param": paramAlias,
                        "requested_normalized": requested,
                        "what_was_attempted": "read back the '\(axDescription)' slider value after writing",
                        "rollback_attempted": rollback.attempted,
                        "rollback_succeeded": rollback.succeeded,
                        "rollback_observed": rollback.observed ?? NSNull(),
                        "rolled_back": rollback.attempted && rollback.succeeded,
                        "parameter_left_changed": rollback.parameterLeftChanged(before: before, tolerance: tolerance),
                        "what_was_observed": "the slider value could not be read after the write; no inverse was authorized from an unknown state",
                        "safe_to_retry": rollback.succeeded,
                        "write_attempted": true,
                    ]
                ))
            }
            let observedDisplay = AXValueExtractors.extractValueDescription(slider, runtime: runtime.ax)

            // Step 13 — tolerance gate.
            if abs(after - requested) <= tolerance {
                return .success(verifiedParameterEnvelope(extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "param": paramAlias,
                    "requested_normalized": requested,
                    "observed_normalized": after,
                    "observed_display": observedDisplay ?? NSNull(),
                    "display_unit": responseDisplayUnit,
                    "tolerance": tolerance,
                    "write_source": "ax_plugin_window",
                    "verify_source": "ax_plugin_window",
                ]))
            }

            // The observed mismatch is not permanent ownership: a fresh exact
            // value and target check must still permit any inverse.
            let rollback = rollbackSliderValue(
                slider,
                to: before,
                ownedAfter: after,
                targetIsCurrent: rollbackTargetIsCurrent,
                writeMethod: writeMethod,
                tolerance: tolerance,
                runtime: runtime.ax
            )
            return .error(HonestContract.encodeV2StateC(
                error: .readbackMismatch,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "param": paramAlias,
                    "requested_normalized": requested,
                    "observed_normalized": after,
                    "observed_display": observedDisplay ?? NSNull(),
                    "display_unit": responseDisplayUnit,
                    "tolerance": tolerance,
                    "rollback_attempted": rollback.attempted,
                    "rollback_succeeded": rollback.succeeded,
                    "rollback_observed": rollback.observed ?? NSNull(),
                    "rolled_back": rollback.attempted && rollback.succeeded,
                    "parameter_left_changed": rollback.parameterLeftChanged(before: before, tolerance: tolerance),
                    "rollback_outcome": rollback.walkOutcome ?? NSNull(),
                    "rollback_to": before,
                    "what_was_attempted": "verify the '\(axDescription)' write within tolerance \(tolerance)",
                    "what_was_observed": "observed \(after) differs from requested \(requested) beyond tolerance",
                    "safe_to_retry": false,
                    "write_attempted": true,
                ]
            ))

        case "ax_slider_increment_walk":
            guard let walkTarget else {
                return .error(HonestContract.encodeV2StateC(
                    error: .unsupportedParamReadback,
                    extras: [
                        "operation": operation,
                        "target_identity": identity,
                        "param": paramAlias,
                        "what_was_attempted": "select the declared increment-walk target for '\(axDescription)'",
                        "what_was_observed": "the parameter declares ax_slider_increment_walk without a raw or display target",
                        "safe_to_retry": false,
                        "write_attempted": false,
                    ]
                ))
            }
            let needsDisplay: Bool
            if case .display(_) = walkTarget {
                needsDisplay = true
            } else {
                needsDisplay = false
            }
            var nudgeAttempted = false
            var firstNudgeRefused = false
            let outcome = SliderIncrementWalk.walk(
                to: walkTarget,
                read: {
                    guard let value = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax) else {
                        return nil
                    }
                    let display = AXValueExtractors.extractValueDescription(slider, runtime: runtime.ax)
                    guard !needsDisplay || display != nil else { return nil }
                    return SliderIncrementWalk.Reading(value: value, display: display ?? "")
                },
                nudge: { rawTarget in
                    if !nudgeAttempted, !beforeValueIsCurrent() {
                        firstNudgeRefused = true
                        return false
                    }
                    nudgeAttempted = true
                    return AXValueExtractors.setSliderValue(slider, rawTarget, runtime: runtime.ax)
                },
                budget: incrementWalkBudget
            )
            if firstNudgeRefused { return beforeValueRefusal() }
            if !nudgeAttempted {
                if case .readbackLost = outcome { return beforeValueRefusal() }
                guard beforeValueIsCurrent() else { return beforeValueRefusal() }
            }
            switch outcome {
            case let .arrived(steps, final):
                var extras: [String: Any] = [
                    "operation": operation,
                    "target_identity": identity,
                    "param": paramAlias,
                    "requested_normalized": requested,
                    "observed_normalized": final.value,
                    "observed_display": final.display,
                    "display_unit": responseDisplayUnit,
                    "walk_steps": steps,
                    "write_source": "ax_plugin_window",
                    "verify_source": "ax_plugin_window",
                ]
                if case let .display(targetDisplay) = walkTarget {
                    extras["requested_display"] = targetDisplay
                } else {
                    extras["tolerance"] = tolerance
                }
                return .success(verifiedParameterEnvelope(extras: extras))
            case .noProgress(_, _), .budgetExhausted(_, _), .overshot(_, _), .readbackLost(_):
                let ownedAfter: Double?
                switch outcome {
                case let .noProgress(_, last), let .budgetExhausted(_, last), let .overshot(_, last):
                    ownedAfter = last.value
                case .readbackLost, .arrived: ownedAfter = nil
                }
                let rollback = rollbackSliderValue(
                    slider,
                    to: before,
                    ownedAfter: ownedAfter,
                    targetIsCurrent: rollbackTargetIsCurrent,
                    writeMethod: writeMethod,
                    tolerance: tolerance,
                    runtime: runtime.ax,
                    incrementWalkBudget: incrementWalkBudget
                )
                return .error(incrementWalkFailureStateC(
                    operation: operation,
                    identity: identity,
                    paramAlias: paramAlias,
                    requested: requested,
                    axDescription: axDescription,
                    outcome: outcome,
                    rollback: rollback,
                    before: before,
                    walkTarget: walkTarget
                ))
            }

        default:
            return .error(HonestContract.encodeV2StateC(
                error: .unsupportedParamReadback,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "param": paramAlias,
                    "what_was_attempted": "select the declared write method for '\(axDescription)'",
                    "what_was_observed": "unsupported write method '\(writeMethod)'",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        }
        }()
        return resultAfterViewPreparation
        }()
        let finished = finishPluginViewSessionResult(resultAfterAcquisition)
        if access.isRead, readContextEnded {
            return parameterReadContextFailure(finished, error: .windowIdentityUnresolved, operation: operation)
        }
        if (access.isEQStateRead || controlsReadKind != nil), let contextIsCurrent = access.readContextIsCurrent,
           (!contextIsCurrent() || !targetPluginIdentityIsStable(
                target: target, insert: insert, pluginID: pluginID,
                originalSlot: slots[insert].element, runtime: runtime
           )) {
            // Cleanup can yield after collection. Revalidate the occupied
            // instance, not just the project document, without requiring an
            // operation-owned editor to remain open after its successful close.
            return parameterReadContextFailure(finished, error: .staleTargetReference, operation: operation)
        }
        return finished
    }

    /// The additive ADR-011 / ADR-018 Controls-view checkbox branch. It is
    /// intentionally separate from the slider writer above: the label belongs
    /// to an AXRow, AXPress is the measured action, and success requires the
    /// checkbox's own AXValue to change to the requested Boolean state.
    private static func performControlsViewCheckboxWrite(
        operation: String,
        identity: [String: Any],
        paramAlias: String,
        requested: Double,
        rowLabel: String,
        window: AXUIElement,
        runtime: AXHelpers.Runtime,
        verifiedWriteEnvelope: ([String: Any]) -> String,
        stateCWithPluginViewRestoration: (HonestContract.FailureError, [String: Any]) -> String,
        allowingPress: (AXUIElement, Bool) -> Bool = { _, _ in true }
    ) -> ChannelResult {
        // The caller already selected and structurally confirmed Controls view.
        // Do not repeat the selection here: reopening its menu would make this
        // locator depend on a write status rather than the confirmed bound
        // window state it was handed.
        let checkbox: AXUIElement
        switch ControlsViewBooleanParameterWriter.locate(
            label: rowLabel,
            in: window,
            runtime: runtime
        ) {
        case let .refused(failure):
            return .error(stateCWithPluginViewRestoration(
                .paramControlNotFound,
                [
                    "operation": operation,
                    "target_identity": identity,
                    "param": paramAlias,
                    "controls_view_row_label": rowLabel,
                    "what_was_attempted": "bind the Controls-view AXRow label to one control",
                    "what_was_observed": failure.observation,
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        case let .found(control):
            guard case let .checkBox(found) = control else {
                let failure = control.failure ?? .checkboxNotFound
                return .error(stateCWithPluginViewRestoration(
                    .unsupportedParamReadback,
                    [
                        "operation": operation,
                        "target_identity": identity,
                        "param": paramAlias,
                        "controls_view_row_label": rowLabel,
                        "what_was_attempted": "confirm the labelled Controls-view control is a measured AXCheckBox",
                        "what_was_observed": failure.observation,
                        "safe_to_retry": false,
                        "write_attempted": false,
                    ]
                ))
            }
            checkbox = found
        }

        let requestedState = requested == 1
        let toggle = ControlsViewBooleanParameterWriter.pressAndVerify(
            checkbox,
            requested: requestedState,
            runtime: runtime,
            allowingPress: { allowingPress(checkbox, $0) }
        )
        if toggle.verified, let observed = toggle.observedAfterPress {
            return .success(verifiedWriteEnvelope([
                "operation": operation,
                "target_identity": identity,
                "param": paramAlias,
                "controls_view_row_label": rowLabel,
                "requested_normalized": requested,
                "requested_boolean": requestedState,
                "observed_normalized": observed ? 1.0 : 0.0,
                "observed_boolean": observed,
                "write_source": "ax_controls_view_checkbox",
                "verify_source": "ax_controls_view_checkbox",
                "write_attempted": toggle.pressAttempted,
            ]))
        }

        let restorationObservation: String
        switch toggle.restoreObserved {
        case .some(true):
            restorationObservation = "restore observed: AXValue returned to the pre-press state"
        case .some(false):
            restorationObservation = "restore not observed: AXValue did not return to the pre-press state"
        case nil:
            restorationObservation = "restore not observed: the after-state is unknown and no inverse was sent"
        }
        let failureObservation = [
            toggle.refusal ?? "Controls-view checkbox verification did not establish the requested state",
            restorationObservation,
        ].joined(separator: "; ")
        return .error(stateCWithPluginViewRestoration(
            toggle.observedAfterPress == nil ? .readbackLostAfterWrite : .readbackMismatch,
            [
                "operation": operation,
                "target_identity": identity,
                "param": paramAlias,
                "controls_view_row_label": rowLabel,
                "requested_normalized": requested,
                "requested_boolean": requestedState,
                "before_boolean": toggle.before ?? NSNull(),
                "observed_boolean": toggle.observedAfterPress ?? NSNull(),
                "restore_attempted": toggle.restoreAttempted,
                "restore_observed": toggle.restoreObserved ?? NSNull(),
                "restore_observed_boolean": toggle.restoreObservedValue ?? NSNull(),
                "parameter_left_changed": toggle.observedAfterPress == nil ? NSNull() : false,
                "what_was_attempted": "AXPress the labelled Controls-view AXCheckBox then require changed AXValue readback",
                "what_was_observed": failureObservation,
                "safe_to_retry": false,
                "write_attempted": toggle.pressAttempted,
            ]
        ))
    }

    private struct SliderRollback {
        let attempted: Bool
        let succeeded: Bool
        let observed: Double?
        let walkOutcome: String?

        func parameterLeftChanged(before: Double, tolerance: Double) -> Any {
            guard let observed, observed.isFinite, before.isFinite else { return NSNull() }
            return abs(observed - before) > tolerance
        }
    }

    private static func pluginRollbackOperationIsCurrent() -> Bool {
        guard !Task.isCancelled else { return false }
        guard let context = OperationTraceContext.current else { return true }
        return context.ownsGate() && !context.cancellationRequested()
            && (context.deadline.map { ContinuousClock.now < $0 } ?? true)
    }

    /// An inverse requires a finite observed after-state, the exact retained
    /// target, and an equal fresh value. A before-value alone is not ownership.
    private static func rollbackSliderValue(
        _ slider: AXUIElement,
        to before: Double?,
        ownedAfter: Double?,
        targetIsCurrent: () -> Bool,
        writeMethod: String,
        tolerance: Double,
        runtime: AXHelpers.Runtime,
        incrementWalkBudget: Int = ChannelEQBandCatalog.incrementWalkBudget
    ) -> SliderRollback {
        guard let before, before.isFinite, let ownedAfter, ownedAfter.isFinite,
              targetIsCurrent(),
              let current = AXValueExtractors.extractSliderValue(slider, runtime: runtime),
              current.isFinite, current == ownedAfter, targetIsCurrent(),
              pluginRollbackOperationIsCurrent() else {
            return SliderRollback(attempted: false, succeeded: false, observed: nil, walkOutcome: nil)
        }
        if current == before {
            return SliderRollback(attempted: false, succeeded: true, observed: current, walkOutcome: nil)
        }
        switch writeMethod {
        case "ax_slider_increment_walk":
            var ownedCurrent = current
            var inverseAttempted = false
            let outcome = SliderIncrementWalk.walk(
                to: .rawValue(before, tolerance: tolerance),
                read: {
                    guard targetIsCurrent(),
                          let value = AXValueExtractors.extractSliderValue(slider, runtime: runtime),
                          value.isFinite, (inverseAttempted || value == ownedCurrent),
                          pluginRollbackOperationIsCurrent() else { return nil }
                    ownedCurrent = value
                    return SliderIncrementWalk.Reading(value: value, display: "")
                },
                nudge: { rawTarget in
                    guard targetIsCurrent(),
                          let latest = AXValueExtractors.extractSliderValue(slider, runtime: runtime),
                          latest.isFinite, latest == ownedCurrent,
                          pluginRollbackOperationIsCurrent() else { return false }
                    inverseAttempted = true
                    return AXValueExtractors.setSliderValue(slider, rawTarget, runtime: runtime)
                },
                budget: incrementWalkBudget
            )
            if case let .arrived(_, final) = outcome {
                return SliderRollback(
                    attempted: inverseAttempted,
                    succeeded: true,
                    observed: final.value,
                    walkOutcome: "arrived"
                )
            }
            return SliderRollback(
                attempted: inverseAttempted,
                succeeded: false,
                observed: nil,
                walkOutcome: incrementWalkOutcomeName(outcome)
            )
        default:
            // ACK is not the resulting state. An accepted inverse can lose its
            // readback, and a rejected ACK can still leave the original value.
            _ = AXValueExtractors.setSliderValue(slider, before, runtime: runtime)
            guard targetIsCurrent(), pluginRollbackOperationIsCurrent(),
                  let restored = AXValueExtractors.extractSliderValue(slider, runtime: runtime),
                  restored.isFinite, targetIsCurrent(), pluginRollbackOperationIsCurrent() else {
                return SliderRollback(attempted: true, succeeded: false, observed: nil, walkOutcome: nil)
            }
            return SliderRollback(
                attempted: true,
                succeeded: abs(restored - before) <= tolerance,
                observed: restored,
                walkOutcome: nil
            )
        }
    }

    private static func incrementWalkFailureStateC(
        operation: String,
        identity: [String: Any],
        paramAlias: String,
        requested: Double,
        axDescription: String,
        outcome: SliderIncrementWalk.WalkOutcome,
        rollback: SliderRollback,
        before: Double?,
        walkTarget: SliderIncrementWalk.Target?
    ) -> String {
        let error: HonestContract.FailureError
        var extras: [String: Any] = [
            "operation": operation,
            "target_identity": identity,
            "param": paramAlias,
            "requested_normalized": requested,
            "walk_outcome": incrementWalkOutcomeName(outcome),
            "rollback_attempted": rollback.attempted,
            "rollback_succeeded": rollback.succeeded,
            "rollback_outcome": rollback.walkOutcome ?? NSNull(),
            "rollback_to": before ?? NSNull(),
            "what_was_attempted": "walk the '\(axDescription)' slider to its requested value",
            "safe_to_retry": false,
            "write_attempted": true,
        ]
        // The string the walk was looking for, on the FAILURE path as well as the success one. It
        // was reported only when the walk arrived, which is the half that needs it least: a run
        // that stops beside its target and cannot say what it was comparing against costs hours —
        // #292 spent them, deducing the requested rendering from step counts.
        switch walkTarget {
        case let .display(targetDisplay):
            extras["requested_display"] = targetDisplay
            extras["walk_target_kind"] = "display"
        case let .rawValue(value, tolerance):
            extras["requested_raw_value"] = value
            extras["tolerance"] = tolerance
            extras["walk_target_kind"] = "raw_value"
        case .none:
            extras["walk_target_kind"] = "none"
        }
        switch outcome {
        case let .noProgress(steps, last):
            error = .incrementWalkNoProgress
            extras["walk_steps"] = steps
            extras["last_observed_normalized"] = last.value
            extras["last_observed_display"] = last.display
            extras["what_was_observed"] = "the slider made no reliable progress toward the requested target"
        case let .budgetExhausted(steps, last):
            error = .incrementWalkBudgetExhausted
            extras["walk_steps"] = steps
            extras["last_observed_normalized"] = last.value
            extras["last_observed_display"] = last.display
            extras["what_was_observed"] = "the bounded slider walk exhausted its accepted-write budget"
        case let .overshot(steps, last):
            error = .incrementWalkOvershot
            extras["walk_steps"] = steps
            extras["last_observed_normalized"] = last.value
            extras["last_observed_display"] = last.display
            extras["what_was_observed"] = "the slider crossed the target then moved farther away on the same side"
        case let .readbackLost(steps):
            error = .readbackLostAfterWrite
            extras["walk_steps"] = steps
            extras["what_was_observed"] = "the slider readback was unavailable during the increment walk"
        case .arrived(_, _):
            fatalError("arrived must not be encoded as an increment-walk failure")
        }
        return HonestContract.encodeV2StateC(error: error, extras: extras)
    }

    private static func incrementWalkOutcomeName(_ outcome: SliderIncrementWalk.WalkOutcome) -> String {
        switch outcome {
        case .arrived(_, _): "arrived"
        case .noProgress(_, _): "noProgress"
        case .budgetExhausted(_, _): "budgetExhausted"
        case .overshot(_, _): "overshot"
        case .readbackLost(_): "readbackLost"
        }
    }

    /// Formats a caller's engineering value for the exact string comparison
    /// against Logic's `AXValueDescription`. This normalizes only numeric text
    /// (`100.0` → `100`); it does not derive or imply a raw slider position.
    private static func displayTargetValueText(_ value: Double) -> String {
        if value.rounded() == value,
           value >= Double(Int.min), value <= Double(Int.max) {
            return String(Int(value))
        }
        return String(value)
    }

    private static func trackSelectionFailedStateC(_ operation: String, _ identity: [String: Any], _ detail: String) -> String {
        HonestContract.encodeV2StateC(
            error: .trackSelectionFailed,
            extras: [
                "operation": operation,
                "target_identity": identity,
                "what_was_attempted": "select the target track before writing",
                "what_was_observed": detail,
                "safe_to_retry": true,
                "write_attempted": false,
            ]
        )
    }


    private static func incompleteInventoryStateC(_ operation: String, _ identity: [String: Any], _ detail: String) -> String {
        HonestContract.encodeV2StateC(
            error: .incompleteInventory,
            extras: [
                "operation": operation,
                "target_identity": identity,
                "what_was_attempted": "read the insert inventory before writing",
                "what_was_observed": detail,
                "safe_to_retry": true,
                "write_attempted": false,
            ]
        )
    }

    private static func pluginReferenceBindingGuard(
        params: [String: String], target: AXPluginTrackBinding.Binding,
        operation: String, identity: [String: Any]
    ) -> ChannelResult? {
        guard let expected = params["expected_track_name"],
              !target.trackName.utf8.elementsEqual(expected.utf8) else { return nil }
        return .error(HonestContract.encodeV2StateC(error: .staleTargetReference, extras: [
            "operation": operation,
            "target_identity": identity,
            "expected_track_name": expected,
            "observed_track_name": target.trackName,
            "what_was_attempted": "bind the acquired Arrange/Mixer identity to the referenced track",
            "what_was_observed": "the acquired target no longer has the reference's observed name",
            "write_attempted": false,
            "safe_to_retry": false,
        ]))
    }

    /// An insert reference carries the observed physical slot state, not just its number.
    /// Reusing a reference after replacement must not authorize a different plug-in.
    private static func pluginInsertReferenceGuard(
        params: [String: String],
        slot: AXLogicProElements.PluginInsertSlot,
        operation: String
    ) -> ChannelResult? {
        guard let expectedStatus = params["expected_slot_read_status"],
              let expectedIdentity = params["expected_plugin_identity"] else { return nil }
        let observedIdentity = slot.name.flatMap(VerifiedPluginCatalog.pluginID(forObservedName:)) ?? slot.name ?? ""
        let matches = expectedStatus == "empty"
            ? slot.isEmpty && expectedIdentity.isEmpty
            : expectedStatus == "ok" && slot.readStatus == .occupiedReadable
                && observedIdentity == expectedIdentity
        guard !matches else { return nil }
        return .error(HonestContract.encodeV2StateC(error: .staleTargetReference, extras: [
            "operation": operation,
            "what_was_attempted": "confirm the insert reference still identifies its observed slot state",
            "what_was_observed": "the referenced insert is unreadable or no longer has the observed plug-in identity",
            "write_attempted": false,
            "safe_to_retry": false,
        ]))
    }

    @TaskLocal private static var authorizedPluginTrack: AXPluginTrackBinding.Binding?

    /// Explain an unresolved association without misreporting a failed children read as absence.
    private static func pluginTrackBindingFailureDetail(
        mixer: AXUIElement, runtime: AXLogicProElements.Runtime
    ) -> String {
        guard let enumeration = AXLogicProElements.stripEnumeration(in: mixer, runtime: runtime.ax),
              enumeration.unreadableChildren == 0 else { return "the mixer's children did not read" }
        if enumeration.strips.contains(where: {
            AXLogicProElements.childrenIfRead($0, runtime: runtime.ax) == nil
        }) { return "the strip's children did not read" }
        return "the arrange track could not be uniquely joined to a readable Mixer strip by name"
    }

    /// Re-resolve by observed names while retaining the original header and strip elements.
    /// Mixer ordering may change; the actuation target may not change with it.
    private static func boundPluginTrack(
        track: Int,
        runtime: AXLogicProElements.Runtime,
        onRefusal: ((String) -> Void)? = nil
    ) -> AXPluginTrackBinding.Binding? {
        guard let mixer = authorizedPluginTrack?.mixer ?? AXLogicProElements.getMixerArea(runtime: runtime) else {
            onRefusal?("mixer_unavailable"); return nil
        }
        guard let target = AXPluginTrackBinding.resolve(
            track: track, mixer: mixer, runtime: runtime, onRefusal: onRefusal
        ) else { return nil }
        if let original = authorizedPluginTrack {
            guard original.trackIndex == target.trackIndex,
                  original.trackName.utf8.elementsEqual(target.trackName.utf8) else {
                onRefusal?("retained_track_mismatch"); return nil
            }
            guard CFEqual(original.header, target.header) else {
                onRefusal?("retained_header_mismatch"); return nil
            }
            guard CFEqual(original.strip, target.strip) else {
                onRefusal?("retained_strip_mismatch"); return nil
            }
        }
        return target
    }

    private static func windowOpenFailedStateC(
        _ operation: String,
        _ identity: [String: Any],
        _ detail: String,
        diagnostics: [String: Any] = [:],
        safeToRetry: Bool = true
    ) -> String {
        var extras: [String: Any] = [
            "operation": operation,
            "target_identity": identity,
            "what_was_attempted": "acquire the plugin window before writing",
            "what_was_observed": detail,
            "safe_to_retry": safeToRetry,
            "write_attempted": false,
        ]
        extras.merge(diagnostics) { current, _ in current }
        return HonestContract.encodeV2StateC(
            error: .windowOpenFailed,
            extras: extras
        )
    }

    private static func windowIdentityUnresolvedStateC(
        _ operation: String,
        _ identity: [String: Any],
        _ detail: String,
        diagnostics: [String: Any] = [:]
    ) -> String {
        var extras: [String: Any] = [
            "operation": operation,
            "target_identity": identity,
            "what_was_attempted": "resolve one plugin window before writing",
            "what_was_observed": detail,
            "safe_to_retry": false,
            "write_attempted": false,
        ]
        extras.merge(diagnostics) { current, _ in current }
        return HonestContract.encodeV2StateC(
            error: .windowIdentityUnresolved,
            extras: extras
        )
    }

    /// A failed AX window census/classification is not evidence that no
    /// competing editor exists. Keep the raw diagnostic in the State-C receipt
    /// and refuse before any window-dependent choice or slot press.
    private static func pluginWindowReadFailureStateC(
        _ operation: String,
        _ identity: [String: Any],
        _ error: AXHelpers.AXStatusError,
        phase: String
    ) -> String {
        windowIdentityUnresolvedStateC(
            operation,
            identity,
            "plugin-window acquisition could not complete \(phase) (AX status \(error.diagnosticLabel)); unreadable candidates were not treated as absent",
            diagnostics: ["plugin_window_read_failure": error.diagnosticLabel]
        )
    }

    private static func pluginWindowPluginMismatchStateC(
        _ operation: String,
        _ identity: [String: Any],
        pluginID: String,
        observedNames: [String]
    ) -> String {
        let observation: String
        if observedNames.isEmpty {
            observation = "the candidate plugin window exposed no readable direct AXStaticText values, so its plugin identity could not be verified"
        } else {
            observation = "the candidate plugin window's direct AXStaticText values were "
                + observedNames.map { "'\($0)'" }.joined(separator: ", ")
                + "; none mapped to requested plugin id '\(pluginID)'"
        }
        return HonestContract.encodeV2StateC(
            error: .pluginWindowPluginMismatch,
            extras: [
                "operation": operation,
                "target_identity": identity,
                "requested_plugin_id": pluginID,
                "observed_plugin_window_static_texts": observedNames,
                "what_was_attempted": "verify the plugin-window header identifies \(pluginID) before writing",
                "what_was_observed": observation,
                "safe_to_retry": false,
                "write_attempted": false,
            ]
        )
    }

    private static func duplicatePluginEditorAlreadyOpenStateC(
        operation: String,
        identity: [String: Any],
        pluginID: String,
        track: Int,
        insert: Int,
        conflictingInsertIndices: [Int],
        matchingEditorCount: Int
    ) -> String {
        HonestContract.encodeV2StateC(
            error: .duplicatePluginEditorAlreadyOpen,
            extras: [
                "operation": operation,
                "target_identity": identity,
                "requested_plugin_id": pluginID,
                "conflicting_insert_indices": conflictingInsertIndices,
                "matching_editor_count_before_press": matchingEditorCount,
                "what_was_attempted": "confirm no \(pluginID) editor was already open before pressing insert \(insert)",
                "what_was_observed": "\(matchingEditorCount) matching \(pluginID) editor(s) were already open on track \(track)",
                // A duplicated plug-in can only be bound by opening its editor
                // from a known-empty state, so an already-open editor is the one
                // thing the caller must clear. This operation closes the editors
                // it opens, so reaching here means either a human opened one or a
                // previous close could not be verified.
                "recovery_hint": "Close the open \(pluginID) editor(s) on track \(track), then retry. "
                    + "While the plug-in occupies more than one insert, its editor must be "
                    + "opened by this operation for the write to be attributable to insert \(insert).",
                "safe_to_retry": false,
                "write_attempted": false,
            ]
        )
    }

    private static func duplicatePluginEditorCountMismatchStateC(
        operation: String,
        identity: [String: Any],
        pluginID: String,
        track: Int,
        insert: Int,
        conflictingInsertIndices: [Int],
        matchingEditorCount: Int,
        newlyObservedMatchingEditorCount: Int
    ) -> String {
        HonestContract.encodeV2StateC(
            error: .duplicatePluginEditorCountMismatch,
            extras: [
                "operation": operation,
                "target_identity": identity,
                "requested_plugin_id": pluginID,
                "conflicting_insert_indices": conflictingInsertIndices,
                "matching_editor_count_after_press": matchingEditorCount,
                "new_matching_editor_count_after_press": newlyObservedMatchingEditorCount,
                "what_was_attempted": "press insert \(insert)'s open control once and observe exactly one newly created \(pluginID) editor",
                "what_was_observed": "the one target-slot press left \(matchingEditorCount) matching \(pluginID) editor(s), \(newlyObservedMatchingEditorCount) newly observed, visible on track \(track)",
                "safe_to_retry": false,
                "write_attempted": false,
            ]
        )
    }

    private static func acquiredPluginWindowFailureStateC(
        acquiredWindow: AXUIElement,
        operation: String,
        identity: [String: Any],
        pluginID: String,
        trackName: String,
        axDescription: String,
        detail: String,
        runtime: AXLogicProElements.Runtime
    ) -> String? {
        switch AXLogicProElements.pluginWindowMatch(
            forTrackName: trackName,
            matchingPluginID: pluginID,
            matchingSliderDescription: axDescription,
            runtime: runtime
        ) {
        case let .unique(currentWindow) where CFEqual(currentWindow, acquiredWindow):
            return nil
        case let .unreadable(error):
            return pluginWindowReadFailureStateC(
                operation,
                identity,
                error,
                phase: "the acquired plugin-window identity recheck"
            )
        case let .pluginIdentityMismatch(observedNames):
            return pluginWindowPluginMismatchStateC(
                operation,
                identity,
                pluginID: pluginID,
                observedNames: observedNames
            )
        case .none, .ambiguous, .unique:
            return windowIdentityUnresolvedStateC(
                operation,
                identity,
                detail,
                diagnostics: pluginWindowAcquisitionDiagnostics(
                    trackName: trackName,
                    axDescription: axDescription,
                    runtime: runtime
                )
            )
        }
    }

    /// Controls-view writes have already bound an editor through the caller's
    /// target slot and the header-aware `pluginWindowMatch` acquisition above.
    /// An editor-view slider description remains only an optional witness during
    /// that match: Controls view is expected to expose no described sliders, so
    /// its absence must never invalidate the already-bound editor.
    private static func controlsViewAcquiredPluginWindowFailureStateC(
        acquiredWindow: AXUIElement,
        operation: String,
        identity: [String: Any],
        pluginID: String,
        trackName: String,
        runtime: AXLogicProElements.Runtime
    ) -> String? {
        let headerBoundWindows: [AXUIElement]
        switch AXLogicProElements.matchingPluginEditorWindows(
            forTrackName: trackName,
            matchingPluginID: pluginID,
            runtime: runtime
        ) {
        case let .success(observed):
            headerBoundWindows = observed
        case let .failure(error):
            return pluginWindowReadFailureStateC(
                operation,
                identity,
                error,
                phase: "the Controls-view acquired-editor header recheck"
            )
        }
        guard headerBoundWindows.contains(where: { CFEqual($0, acquiredWindow) }) else {
            return windowIdentityUnresolvedStateC(
                operation,
                identity,
                "the target-slot editor no longer proved the requested track and plugin header identity before Controls view selection",
                diagnostics: pluginWindowAcquisitionDiagnostics(
                    trackName: trackName,
                    axDescription: "not required for Controls-view header binding",
                    runtime: runtime
                )
            )
        }
        return nil
    }

    private static func openPluginWindowFromTargetSlot(
        _ targetSlot: AXUIElement,
        pluginID: String,
        trackName: String,
        axDescription: String,
        requiringMatchingSlider: Bool = true,
        runtime: AXLogicProElements.Runtime,
        allowingChanges: () -> Bool = { true },
        contextIsCurrent: () -> Bool = { true }
    ) async -> AXUIElementSendable? {
        switch AXLogicProElements.pluginWindowMatch(
            forTrackName: trackName,
            matchingPluginID: pluginID,
            matchingSliderDescription: axDescription,
            requiringMatchingSlider: requiringMatchingSlider,
            runtime: runtime
        ) {
        case .unreadable:
            return nil
        case .ambiguous:
            return nil
        case .pluginIdentityMismatch:
            return nil
        case let .unique(window):
            guard demotePluginWindowBeforeAcquisition(window, runtime: runtime, allowingChanges: allowingChanges) else {
                return nil
            }
            // Live measurement: `열기` opens and fronts the editor; after
            // demotion, pressing `열기` again removes it from AXWindows. The
            // slot's open control is a toggle, so raise the known editor instead.
            guard allowingChanges() else { return nil }
            _ = AXHelpers.performAction(window, kAXRaiseAction as String, runtime: runtime.ax)
            if pluginWindowIsFront(window, runtime: runtime) {
                return AXUIElementSendable(window)
            }
        case .none:
            break
        }

        let rankedControls = rankedPluginSlotOpenControls(in: targetSlot, runtime: runtime.ax)
        let attempts = rankedControls.filter { $0.rank == 0 }.map(\.element)
            + [targetSlot]
            + rankedControls.filter { $0.rank != 0 }.map(\.element)
        for element in attempts {
            // Fire AXPress but IGNORE its return code, then consult the observed
            // window poll REGARDLESS of that return. On real Logic 12.3 an AXPress
            // that actually opens the plugin window can still report a NON-ZERO AX
            // status; gating the poll on the return (the former `guard … else
            // continue`) skips past a control that DID open the window. Honest-
            // contract: trust the OBSERVED window, not the unreliable return —
            // only advance to the next ranked control if the poll shows no window.
            guard allowingChanges() else { return nil }
            _ = pressElement(element, runtime: runtime.ax)
            switch await pollOpenPluginWindow(
                pluginID: pluginID,
                trackName: trackName,
                axDescription: axDescription,
                requiringMatchingSlider: requiringMatchingSlider,
                runtime: runtime,
                timeoutMs: 1_250,
                contextIsCurrent: contextIsCurrent
            ) {
            case .unreadable:
                return nil
            case let .unique(window):
                guard pluginWindowIsFront(window, runtime: runtime) else {
                    return nil
                }
                return AXUIElementSendable(window)
            case .ambiguous:
                return nil
            case .pluginIdentityMismatch:
                return nil
            case .none:
                continue
            }
        }
        return nil
    }

    private static func demotePluginWindowBeforeAcquisition(
        _ window: AXUIElement,
        runtime: AXLogicProElements.Runtime,
        allowingChanges: () -> Bool = { true }
    ) -> Bool {
        guard allowingChanges() else { return false }
        let mainCleared = AXHelpers.setAttribute(
            window, kAXMainAttribute as String, false as CFTypeRef, runtime: runtime.ax
        )
        guard allowingChanges() else { return false }
        let focusCleared = AXHelpers.setAttribute(
            window, kAXFocusedAttribute as String, false as CFTypeRef, runtime: runtime.ax
        )
        if mainCleared, focusCleared, !pluginWindowIsFront(window, runtime: runtime) {
            return true
        }
        guard let arrangeWindow = AXLogicProElements.mainWindow(runtime: runtime),
              allowingChanges(),
              AXHelpers.performAction(arrangeWindow, kAXRaiseAction as String, runtime: runtime.ax) else { return false }
        return !pluginWindowIsFront(window, runtime: runtime)
    }

    private static func pluginWindowIsFront(
        _ window: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        let isMain: NSNumber? = AXHelpers.getAttribute(
            window, kAXMainAttribute, runtime: runtime.ax
        )
        let isFocused: NSNumber? = AXHelpers.getAttribute(
            window, kAXFocusedAttribute, runtime: runtime.ax
        )
        if isMain?.boolValue == true || isFocused?.boolValue == true { return true }
        // Gain's Editor can report both flags false while the application's
        // AXFocusedWindow is this exact, already header-bound window. Use that
        // observed reference, never its title or a different window's focus.
        guard let app = AXLogicProElements.appRoot(runtime: runtime),
              case let .success(.some(focusedWindow)) = AXHelpers.getAttributeResult(
                app, kAXFocusedWindowAttribute as String, runtime: runtime.ax
              ) as Result<AnyObject?, AXHelpers.AXStatusError>,
              CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() else { return false }
        return CFEqual(focusedWindow, window)
    }

    private static func targetPluginIdentityIsStable(
        target: AXPluginTrackBinding.Binding,
        insert: Int,
        pluginID: String,
        originalSlot: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        guard AXPluginTrackBinding.isStable(target, runtime: runtime),
              let slots = AXLogicProElements.audioPluginInsertSlots(in: target.strip, runtime: runtime.ax),
              slots.indices.contains(insert), slots[insert].occupied,
              slots[insert].readStatus == .occupiedReadable,
              let observedName = slots[insert].name,
              VerifiedPluginCatalog.pluginID(forObservedName: observedName) == pluginID else {
            return false
        }
        return CFEqual(slots[insert].element, originalSlot)
    }

    static func rankedPluginSlotOpenControls(
        in targetSlot: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [(rank: Int, element: AXUIElement)] {
        let children = AXHelpers.getChildren(targetSlot, runtime: runtime)
        let buttons = children.filter {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXButtonRole as String)
        }
        return buttons.compactMap { button -> (rank: Int, element: AXUIElement)? in
            let text = AXLogicProElements.elementSearchText(button, runtime: runtime)
            guard !AXLocalePolicy.pluginBypassControl.containsAny(in: text) else { return nil }
            guard case let .success(actionNames) = AXHelpers.getActionNamesResult(button, runtime: runtime),
                  !pluginSlotControlOpensMenu(actionNames: actionNames) else {
                return nil
            }
            if AXLocalePolicy.pluginSlotOpenControl.containsAny(in: text) {
                return (0, button)
            }
            if AXLocalePolicy.pluginSlotListControl.containsAny(in: text) {
                return (1, button)
            }
            return (2, button)
        }
        .sorted { lhs, rhs in lhs.rank < rhs.rank }
    }

    /// Action names are the stable capability signal; a localised button label
    /// cannot say whether AXPress opens an editor or a menu.
    static func pluginSlotControlOpensMenu(actionNames: [String]) -> Bool {
        actionNames.contains(kAXShowMenuAction as String) || actionNames.contains { actionName in
            let normalized = actionName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.hasPrefix("name:") else { return false }
            // `menu` and `메뉴` stood here. The action name is LOCALIZED: measured 2026-09-18 on
            // Logic 12.3 ko-KR, 136 buttons carry `Name:Legacy 플러그인으로 플러그인 메뉴 열기`,
            // which is character-for-character the ko value of Apple's row `Open plug-in menu
            // with legacy plug-ins`. That pair happened to cover five more locales by accident --
            // the French, Italian and Portuguese sentences contain a lowercase `menu` -- but it
            // sees nothing in ja, de, es, zh-CN or zh-TW, where a menu-opening button was ranked
            // as an editor control. Each of the row's ten values contains its own locale's value
            // of `Menu`, which is why matching that row closes all five.
            return AXLocalePolicy.menuActionNameFragment.containsAny(in: normalized)
        }
    }

    /// The `plugin_popup_menu_*` envelope fields for every cleanup outcome, clean ones included.
    /// One vocabulary for both callers: the verified write reports only the unclean states (below),
    /// and #1016's insert refusal reports all four, because a refusal that says nothing about the
    /// menu it opened reads as a clean screen.
    static func pluginPopupMenuStateFields(
        _ outcome: PluginPopupMenuCleanupOutcome
    ) -> [String: Any] {
        switch outcome {
        case .noPopupObserved:
            return ["plugin_popup_menu_state": "no_popup_observed"]
        case .dismissed:
            return ["plugin_popup_menu_state": "dismissed"]
        case .popupCountUnavailable:
            return ["plugin_popup_menu_state": "window_count_unavailable"]
        case let .couldNotDismiss(initialPopupCount, remainingPopupCount):
            return [
                "plugin_popup_menu_state": "could_not_be_dismissed",
                "plugin_popup_menu_initial_window_count": initialPopupCount,
                "plugin_popup_menu_remaining_window_count": remainingPopupCount,
            ]
        }
    }

    private static func pluginPopupMenuCleanupDiagnostics(
        _ outcome: PluginPopupMenuCleanupOutcome
    ) -> [String: Any] {
        switch outcome {
        case .noPopupObserved, .dismissed:
            return [:]
        case .popupCountUnavailable:
            var fields = pluginPopupMenuStateFields(outcome)
            fields["recovery_hint"] = "Logic popup-menu state could not be read after plugin-window acquisition. Dismiss any visible popup with Escape before retrying."
            return fields
        case .couldNotDismiss:
            var fields = pluginPopupMenuStateFields(outcome)
            fields["recovery_hint"] = "A Logic popup menu remained open after plugin-window acquisition. Dismiss it with Escape before retrying, because it can block Logic's AppleEvent handler."
            return fields
        }
    }

    /// The live failure was one Logic-owned 230x593 CoreGraphics window at
    /// layer 101 — the popup-menu level. Querying
    /// `CGWindowLevelForKey(.popUpMenuWindow)` rather than baking in 101 keeps
    /// the signal tied to macOS's popup-menu level while avoiding the AppleEvent
    /// path that the stuck menu itself blocks.
    private static func dismissLogicPopupMenuAfterPluginWindowAcquisition(
        runtime: AXLogicProElements.Runtime
    ) -> PluginPopupMenuCleanupOutcome {
        let firstPopupCount = logicOwnedPopupMenuWindowCount(runtime: runtime)
        guard firstPopupCount != 0 else {
            return .noPopupObserved
        }

        // An unreadable first count used to end the cleanup here, and a menu the operation had just
        // opened stayed on screen (#1016 review). The AX cancel needs no count to be aimed: it acts
        // only on elements AX itself reports as menus. The Escape below is different -- it goes to
        // whatever has focus -- so it is still never typed unless some reading counted a popup.
        let cancelledMenus = cancelVisibleLogicPopupMenusViaAX(runtime: runtime)
        let afterCancelCount = logicOwnedPopupMenuWindowCount(runtime: runtime)
        if afterCancelCount == 0 {
            return firstPopupCount != nil || cancelledMenus > 0 ? .dismissed : .noPopupObserved
        }
        guard let initialPopupCount = firstPopupCount ?? afterCancelCount else {
            return .popupCountUnavailable
        }
        runtime.postPopupMenuEscape()

        for attempt in 0..<3 {
            guard let remainingPopupCount = logicOwnedPopupMenuWindowCount(runtime: runtime) else {
                return .popupCountUnavailable
            }
            if remainingPopupCount == 0 {
                return .dismissed
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        guard let remainingPopupCount = logicOwnedPopupMenuWindowCount(runtime: runtime) else {
            return .popupCountUnavailable
        }
        return .couldNotDismiss(
            initialPopupCount: initialPopupCount,
            remainingPopupCount: remainingPopupCount
        )
    }

    /// nil is a list that did not come back or a Logic that has no pid, not zero popups. The count
    /// itself is `LogicOnScreenWindows.popupMenuCount` (#942): one reader for the plug-in menu and
    /// the Go To Position menu, so the two cannot disagree about what a Logic popup is.
    private static func logicOwnedPopupMenuWindowCount(
        runtime: AXLogicProElements.Runtime
    ) -> Int? {
        guard let logicPID = runtime.logicProPID(),
              let windows = runtime.onScreenWindowList() else {
            return nil
        }
        return LogicOnScreenWindows.popupMenuCount(windows, logicPID: logicPID)
    }

    /// The number of menus the cancel action was performed on.
    private static func cancelVisibleLogicPopupMenusViaAX(
        runtime: AXLogicProElements.Runtime
    ) -> Int {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return 0 }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute, runtime: runtime.ax
        ) ?? []
        var menus: [AXUIElement] = []
        let roots = [app] + windows
        for root in roots {
            if AXHelpers.getRole(root, runtime: runtime.ax) == (kAXMenuRole as String) {
                menus.append(root)
            }
            for menu in AXHelpers.findAllDescendants(
                of: root, role: kAXMenuRole, maxDepth: 8, runtime: runtime.ax
            ) where !menus.contains(where: { CFEqual($0, menu) }) {
                menus.append(menu)
            }
        }
        var cancelled = 0
        for menu in menus where AXHelpers.getActionNames(menu, runtime: runtime.ax)
            .contains(kAXCancelAction as String) {
            _ = AXHelpers.performAction(menu, kAXCancelAction as String, runtime: runtime.ax)
            cancelled += 1
        }
        return cancelled
    }

    private static func pollOpenPluginWindow(
        pluginID: String,
        trackName: String,
        axDescription: String,
        requiringMatchingSlider: Bool = true,
        runtime: AXLogicProElements.Runtime,
        timeoutMs: Int,
        contextIsCurrent: () -> Bool = { true }
    ) async -> AXLogicProElements.PluginWindowMatch {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000.0)
        var lastUniqueWindow: AXUIElement?
        repeat {
            switch AXLogicProElements.pluginWindowMatch(
                forTrackName: trackName,
                matchingPluginID: pluginID,
                matchingSliderDescription: axDescription,
                requiringMatchingSlider: requiringMatchingSlider,
                runtime: runtime
            ) {
            case let .unique(window):
                lastUniqueWindow = window
            case .ambiguous:
                return .ambiguous
            case let .pluginIdentityMismatch(observedNames):
                return .pluginIdentityMismatch(observedNames: observedNames)
            case let .unreadable(error):
                return .unreadable(error)
            case .none:
                lastUniqueWindow = nil
            }
            guard contextIsCurrent(), Date() < deadline else { break }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        if let lastUniqueWindow {
            return .unique(lastUniqueWindow)
        }
        return .none
    }

    /// Wait only for a nonzero header-proven editor count after the one allowed
    /// duplicate-instance slot press. A count of two or more returns immediately
    /// so a hidden sibling can never be mistaken for the requested insert.
    private static func pollMatchingPluginEditorWindows(
        trackName: String,
        pluginID: String,
        runtime: AXLogicProElements.Runtime,
        timeoutMs: Int,
        contextIsCurrent: () -> Bool = { true }
    ) async -> Result<[AXUIElement], AXHelpers.AXStatusError> {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000.0)
        var matchingEditors: [AXUIElement] = []
        repeat {
            switch AXLogicProElements.matchingPluginEditorWindows(
                forTrackName: trackName,
                matchingPluginID: pluginID,
                runtime: runtime
            ) {
            case let .success(observed):
                matchingEditors = observed
            case let .failure(error):
                return .failure(error)
            }
            if !matchingEditors.isEmpty {
                return .success(matchingEditors)
            }
            guard contextIsCurrent(), Date() < deadline else { break }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return .success(matchingEditors)
    }

    /// ADR-001 coordinate ban: open the plugin window from its slot control via
    /// AXPress only. The former element-derived `clickElementCenter` fallback is
    /// removed; `openPluginWindowFromTargetSlot` fails closed (`window_open_failed`)
    /// when no ranked control responds to AXPress, never a coordinate click.
    private static func pressElement(_ element: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        AXHelpers.performAction(element, kAXPressAction as String, runtime: runtime)
    }

    /// Close an editor this operation opened from a known-empty state.
    ///
    /// Uses `kAXCloseButtonAttribute` rather than a titled button: the visible
    /// close control is localized («닫기» on a Korean system), and the slot's own
    /// open control is a toggle whose press would be indistinguishable from a
    /// user reopening the editor.
    ///
    /// The AX return status is deliberately ignored. Logic reports non-zero from
    /// presses that did work, so the exact window element's absence from
    /// `AXWindows` decides — the same observed-state rule used for acquisition.
    ///
    /// Returns whether the close was OBSERVED. A false return leaves the write
    /// verdict alone, but successful verified-write envelopes disclose the
    /// leftover editor and tell the caller how to recover.
    @discardableResult
    private static func closePluginEditorOpenedByThisOperation(
        _ window: AXUIElement,
        trackName: String,
        pluginID: String,
        runtime: AXLogicProElements.Runtime,
        allowingChanges: (AXUIElement) -> Bool = { _ in true }
    ) -> Bool {
        guard let closeButton: AXUIElement = AXHelpers.getAttribute(
            window, kAXCloseButtonAttribute, runtime: runtime.ax
        ) else {
            return false
        }
        for attempt in 0..<3 {
            guard allowingChanges(window) else { return false }
            _ = pressElement(closeButton, runtime: runtime.ax)
            if AXLogicProElements.pluginEditorWindowIsOpen(window, runtime: runtime) == false {
                return true
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        return false
    }

    /// Best-effort cleanup for every editor element newly observed after this
    /// operation's duplicate-instance slot press. The normal success path has
    /// one element; the count-mismatch path can have the target plus a hidden
    /// sibling restored by the same press. Return true only if each exact
    /// element was observed to leave AXWindows.
    private static func closePluginEditorsOpenedByThisOperation(
        _ windows: [AXUIElement],
        trackName: String,
        pluginID: String,
        runtime: AXLogicProElements.Runtime,
        allowingChanges: (AXUIElement) -> Bool = { _ in true }
    ) -> Bool {
        var everyCloseObserved = true
        for window in windows {
            if !closePluginEditorOpenedByThisOperation(
                window,
                trackName: trackName,
                pluginID: pluginID,
                runtime: runtime,
                allowingChanges: allowingChanges
            ) {
                everyCloseObserved = false
            }
        }
        return everyCloseObserved
    }

    private static func pluginWindowAcquisitionDiagnostics(
        trackName: String,
        axDescription: String,
        runtime: AXLogicProElements.Runtime
    ) -> [String: Any] {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return [
                "opener_action_attempted": true,
                "requested_window_title": trackName,
                "requested_slider_description": axDescription,
                "window_candidates": [],
            ]
        }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) ?? []
        let summaries = windows.prefix(12).map { window -> [String: Any] in
            let sliders = AXHelpers.findAllDescendants(
                of: window, role: kAXSliderRole, maxDepth: 4, runtime: runtime.ax
            )
            let sliderDescriptions = sliders.compactMap {
                AXHelpers.getDescription($0, runtime: runtime.ax)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            var summary: [String: Any] = [
                "title": AXHelpers.getTitle(window, runtime: runtime.ax) ?? "",
                "role": AXHelpers.getRole(window, runtime: runtime.ax) ?? "",
                "slider_descriptions": Array(sliderDescriptions.prefix(8)),
            ]
            if AXHelpers.getTitle(window, runtime: runtime.ax) == trackName {
                let subrole: String? = AXHelpers.getAttribute(window, kAXSubroleAttribute as String, runtime: runtime.ax)
                let closeButton: AXUIElement? = AXHelpers.getAttribute(window, kAXCloseButtonAttribute as String, runtime: runtime.ax)
                summary["subrole"] = subrole ?? ""
                summary["close_button_present"] = closeButton != nil
                let main: NSNumber? = AXHelpers.getAttribute(window, kAXMainAttribute as String, runtime: runtime.ax)
                let focused: NSNumber? = AXHelpers.getAttribute(window, kAXFocusedAttribute as String, runtime: runtime.ax)
                let focusedWindow: AXUIElement? = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: runtime.ax)
                summary["main"] = main.map { $0 as Any } ?? NSNull()
                summary["focused"] = focused.map { $0 as Any } ?? NSNull()
                summary["application_focused_window_matches"] = focusedWindow.map { CFEqual($0, window) } ?? false
                // Preserve shallow header/frontness fields when acquisition
                // is refused. Diagnostics never authenticate a candidate or
                // authorize an action.
                summary["direct_header_candidates"] = runtime.ax.children(window).prefix(24).map { child -> [String: Any] in
                    let value: String? = AXHelpers.getAttribute(child, kAXValueAttribute as String, runtime: runtime.ax)
                    return ["role": AXHelpers.getRole(child, runtime: runtime.ax) ?? "",
                        "value": value ?? "", "title": AXHelpers.getTitle(child, runtime: runtime.ax) ?? "",
                        "description": AXHelpers.getDescription(child, runtime: runtime.ax) ?? ""]
                }
            }
            return summary
        }
        return [
            "opener_action_attempted": true,
            "requested_window_title": trackName,
            "requested_slider_description": axDescription,
            "window_candidates": Array(summaries),
        ]
    }

    /// Confirm the header at `track` reads back as AX-selected, retrying briefly
    /// (Logic commits selection asynchronously). Self-contained so the verified
    /// write path does not depend on the main channel's private selection
    /// verifier; uses the same `AXSelected` readback contract.
    private static func verifiedTrackSelected(
        track: Int,
        runtime: AXLogicProElements.Runtime
    ) async -> Bool {
        for attempt in 0..<6 {
            let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
            if track >= 0, track < headers.count,
               AXValueExtractors.extractSelectedState(headers[track], runtime: runtime.ax) == true {
                return true
            }
            if attempt < 5 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return false
    }

    // MARK: - insert_verified (exact slot popup insert → readback-gated State A)

    /// Structured result of one live insert attempt. The production driver opens
    /// the requested slot's own popup with its measured custom AX action (or the
    /// coordinate fallback when that action is absent) and selects the exact
    /// plugin leaf with `AXPick`, then diffs the pre- vs post-insert inventory to
    /// detect WHERE the requested plugin actually landed. Only `.mounted` whose
    /// `slot` equals the requested `insert` becomes State A; a different slot is honest State C
    /// (`insert_landed_at_different_slot`), so a slot is never falsely confirmed.
    enum InsertDriverOutcome: Sendable {
        /// The requested plugin (`pluginID`) was observed newly mounted at the
        /// physical `slot` detected by the pre/post inventory diff. The gate maps
        /// `slot == insert` → State A, `slot != insert` → State C (after rollback).
        case mounted(slot: Int, pluginID: String, observedName: String?)
        /// The live insert path ran but the post-insert inventory readback
        /// could not be performed at all (mixer/strip unreadable). Uncertain →
        /// State C `post_insert_readback_unavailable` (fail-closed, not State B —
        /// a verified insert can never be uncertain-success).
        case readbackUnavailable
        /// The target track selection did not complete or could not be verified
        /// before opening the insert UI. No write was attempted.
        case trackSelectionFailed(String)
        /// A stray / wrong plugin appeared and automatic rollback could not
        /// confirm cleanup. Terminal fail-closed: do not continue trying fallback
        /// strategies while an unresolved mutation may remain in the project.
        case rollbackFailed(slot: Int?, pluginID: String?, observedName: String?, rollback: RollbackResult)
        /// A selection strategy appears to have committed/dismissed the dialog, but
        /// the inventory never reached a confirmed changed state before timeout.
        /// Do not keep clicking stale rows/buttons after the dialog has changed.
        case postCommitTimeout(strategy: String)
        /// Readback succeeded but the requested plugin did not appear at ANY slot
        /// after every result-selection strategy. The driver reports the name (if
        /// any) it last observed at the requested slot for diagnostics.
        case mountMismatch(observedName: String?)
        /// A TRANSIENT pre-mount setup step failed (the slot popup could not be
        /// opened/anchored or the exact plugin leaf could not be found). No write was
        /// attempted. Distinct from the
        /// permanent `.mountMismatch` (every strategy ran but the plugin never
        /// mounted) — these are retry-able (`safe_to_retry:true`), P2-3.
        /// `actuated` records whether anything was already dispatched at the target when this
        /// failure was raised. Several setup stages are only reachable after the slot's opener has
        /// been performed or clicked, and reporting those as "no write attempted" denies an
        /// actuation that did happen.
        case transientSetupFailure(stage: String, actuated: Bool = false, safeToRetry: Bool = true)
    }

    /// The injectable live-insert seam. Performs the live insert sequence and
    /// returns a structured outcome plus a `select_trace` diagnostic dict. Injected
    /// so the gate→outcome→envelope mapping is unit-testable without ever issuing
    /// real AX actions (custom opener + AXPick); the production default (`liveExactSlotPopupInsert`)
    /// is the only path that touches the live UI.
    typealias PluginInsertDriver = @Sendable (
        _ track: Int,
        _ insert: Int,
        _ pluginID: String,
        _ searchQuery: String,
        _ runtime: AXLogicProElements.Runtime
    ) async -> (outcome: InsertDriverOutcome, selectTrace: [String: Any])

    /// Injectable rollback seam for a stray/wrong-slot mount. Defaults to the
    /// live `verifiedUndoPluginInsert` (Edit-menu undo + readback confirmation);
    /// tests inject a fake so the gate's rollback reporting is hermetic (no live
    /// Logic / AppleScript).
    typealias PluginInsertRollback = @Sendable (
        _ track: Int,
        _ strayPluginID: String?,
        _ straySlot: Int?,
        _ runtime: AXLogicProElements.Runtime
    ) async -> RollbackResult

    static let liveInsertRollback: PluginInsertRollback = { track, strayPluginID, straySlot, runtime in
        await verifiedUndoPluginInsert(
            track: track, strayPluginID: strayPluginID, straySlot: straySlot, runtime: runtime
        )
    }

    /// Guarded verified insert entry. The write-preceding gates run live and are
    /// honest: schema → mode → project path → identity → inventory `complete:true`
    /// → slot-empty. Only after every gate passes does the op open the requested
    /// slot's own popup with its custom AX action (falling back to a coordinate
    /// click only when that action is absent), select the exact leaf with `AXPick`,
    /// then use a post-insert `get_inventory` readback (pre/post diff) as the SOLE
    /// State A precondition.
    ///
    /// State A is reachable ONLY when the readback observes the requested plugin
    /// newly mounted at the requested slot — a false verified insert is
    /// structurally impossible because the readback diff is the only State A path.
    ///
    /// `insert:K` honesty: the exact-slot popup path is expected to target K, but
    /// the op still detects WHERE the plugin actually landed and, if that differs
    /// from the requested `insert`, fails closed with
    /// `insert_landed_at_different_slot` (reporting `observed_slot`) and rolls the
    /// stray mount back — never a false "verified at K". `set_param_verified`
    /// State A is unaffected.
    static func defaultInsertVerified(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        frontDocumentPath: FrontDocumentPathProvider = liveFrontDocumentPath,
        insertDriver: PluginInsertDriver = liveExactSlotPopupInsert,
        rollback: PluginInsertRollback = liveInsertRollback
    ) async -> ChannelResult {
        let operation = "logic_plugins.insert_verified"

        // Step 1 — schema.
        guard let trackRaw = params["track"], let track = Int(trackRaw), track >= 0 else {
            return .error(invalidParamsStateC(operation, "missing or invalid 'track' (Int >= 0)"))
        }
        guard let insertRaw = params["insert"], let insert = Int(insertRaw), insert >= 0 else {
            return .error(invalidParamsStateC(operation, "missing or invalid 'insert' (Int >= 0)"))
        }
        let pluginAlias = params["plugin"] ?? ""
        guard !pluginAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error(invalidParamsStateC(operation, "missing 'plugin' identity"))
        }
        let mode = params["mode"] ?? ""

        let preResolutionIdentity: [String: Any] = [
            "track_index": track,
            "plugin_id_requested": pluginAlias,
        ]

        // Steps 2-3 — mode + project path gate.
        if let gate = await verifiedModeAndPathGate(
            operation: operation,
            mode: mode,
            projectExpectedPath: params["project_expected_path"],
            preResolutionIdentity: preResolutionIdentity,
            frontDocumentPath: frontDocumentPath
        ) {
            return .error(gate)
        }

        // ADR-002 F1 — same live track-identity cross-check as set_param_verified.
        // A wrong-target insert mutates topology, so the `target_ref` path must
        // fail closed before any selection/insert when the live AX header no
        // longer matches the bound track name. No-op on the explicit-index path.
        if let guardResult = targetTrackNameGuard(
            operation: operation,
            track: track,
            expectedTrackName: params["expected_track_name"],
            identity: preResolutionIdentity,
            runtime: runtime
        ) {
            return guardResult
        }

        // Step 4 — identity (insert allowlist excludes Noise Gate, R5/R7).
        guard let pluginID = VerifiedPluginCatalog.canonicalPluginID(from: pluginAlias),
              insertableAllowlist.contains(pluginID) else {
            return .error(HonestContract.encodeV2StateC(
                error: .unknownPluginIdentity,
                extras: [
                    "operation": operation,
                    "target_identity": preResolutionIdentity,
                    "what_was_attempted": "resolve insertable plugin identity '\(pluginAlias)'",
                    "what_was_observed": "not an insertable allowlisted stock plugin (Gain / Channel EQ / Compressor)",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        }
        let identity = resolvedIdentity(track: track, insert: insert, pluginID: pluginID)

        // Step 5 — inventory must be complete + slot must be verified-empty
        // before an insert is even considered (R3/R7, AC5).
        // #982: children that did not read are refused as such, not as a missing Mixer, a missing
        // track or an empty chain.
        func refuseBeforeInsert(_ observed: String) -> ChannelResult {
            .error(HonestContract.encodeV2StateC(
                error: .incompleteInventory,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "what_was_attempted": "read insert inventory before inserting",
                    "what_was_observed": observed,
                    "safe_to_retry": true,
                    "write_attempted": false,
                ]
            ))
        }
        let mixerLookup = AXLogicProElements.mixerAreaLookup(runtime: runtime)
        guard let mixer = mixerLookup.mixer else {
            return refuseBeforeInsert(
                mixerLookup.childrenUnread ? "the mixer's children did not read" : "mixer area was not locatable"
            )
        }
        guard let target = AXPluginTrackBinding.resolve(track: track, mixer: mixer, runtime: runtime) else {
            return refuseBeforeInsert(pluginTrackBindingFailureDetail(mixer: mixer, runtime: runtime))
        }
        if let refusal = pluginReferenceBindingGuard(
            params: params, target: target, operation: operation, identity: identity
        ) { return refusal }
        guard let slots = AXLogicProElements.audioPluginInsertSlots(in: target.strip, runtime: runtime.ax) else {
            return refuseBeforeInsert("the strip's children did not read")
        }
        let built = pluginInventoryItems(for: slots)
        guard built.complete else {
            return .error(HonestContract.encodeV2StateC(
                error: .incompleteInventory,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "what_was_attempted": "verify the insert inventory is complete before inserting",
                    "what_was_observed": "one or more insert slots are unreadable (complete:false)",
                    "safe_to_retry": true,
                    "write_attempted": false,
                ]
            ))
        }
        guard insert < slots.count else {
            // #234 — a zero-slot chain names the insert_section_not_enumerable
            // condition (with the recovery hint) instead of the bare "(0 slots)"
            // out-of-range wording; a non-empty chain addressed past its end is
            // unchanged. Still State C — the write never softens to State B.
            let detail = slotAddressingFailureDetail(requestedIndex: insert, slotCount: slots.count)
            var extras: [String: Any] = [
                "operation": operation,
                "target_identity": identity,
                "what_was_attempted": "address insert slot \(insert)",
                "what_was_observed": detail.observed,
                "safe_to_retry": false,
                "write_attempted": false,
            ]
            if let recoveryHint = detail.recoveryHint {
                extras["recovery_hint"] = recoveryHint
            }
            return .error(HonestContract.encodeV2StateC(error: .invalidParams, extras: extras))
        }
        if let refusal = pluginInsertReferenceGuard(params: params, slot: slots[insert], operation: operation) {
            return refusal
        }
        // `read_status == .empty` is the ONLY write-safe state — an
        // occupied-unreadable slot is never treated as empty (D4, AC21).
        guard slots[insert].isEmpty else {
            return .error(HonestContract.encodeV2StateC(
                error: .slotOccupied,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "existing_plugin_name": slots[insert].name ?? NSNull(),
                    "existing_read_status": slots[insert].readStatus.rawValue,
                    "what_was_attempted": "insert \(pluginID) into slot \(insert)",
                    "what_was_observed": "slot \(insert) is occupied (read_status=\(slots[insert].readStatus.rawValue))",
                    "safe_to_retry": false,
                    "write_attempted": false,
                ]
            ))
        }

        // Step 6 — drive the live exact-slot insert. The driver opens the target
        // slot's own popup, then diffs pre/post inventory to detect WHERE the
        // requested plugin actually landed, and reports that physical slot. State
        // A is reachable ONLY when the detected slot equals the requested `insert`
        // AND the identity matches — the readback diff is the only State A path.
        let searchQuery = StockPluginCatalog.entry(id: pluginID)?.displayName ?? pluginAlias
        let result: (outcome: InsertDriverOutcome, selectTrace: [String: Any]) = await $authorizedPluginTrack.withValue(target) {
            guard AXPluginTrackBinding.isStable(target, runtime: runtime) else {
                return (.transientSetupFailure(stage: "target_track_binding_changed"), [:])
            }
            return await insertDriver(track, insert, pluginID, searchQuery, runtime)
        }
        let trace = result.selectTrace

        switch result.outcome {
        case let .mounted(observedSlot, observedID, observedName):
            // Identity must match (defensive — the driver only reports `.mounted`
            // for a newly-appeared requested plugin, but the gate stays the sole
            // State A authority).
            guard observedID == pluginID else {
                return .error(HonestContract.encodeV2StateC(
                    error: .postInsertPluginMismatch,
                    extras: [
                        "operation": operation,
                        "target_identity": identity,
                        "observed_plugin_id": observedID,
                        "observed_plugin_name": observedName ?? NSNull(),
                        "observed_slot": observedSlot,
                        "select_trace": trace,
                        "what_was_attempted": "verify the exact slot popup insert is \(pluginID)",
                        "what_was_observed": "readback observed a different plugin \(observedID) at slot \(observedSlot)",
                        "safe_to_retry": false,
                        "write_attempted": true,
                    ]
                ))
            }
            // The plugin mounted somewhere other than the requested slot. Do NOT
            // confirm a slot we did not target — roll the stray mount back and
            // fail closed with the observed slot.
            guard observedSlot == insert else {
                let rollbackResult = await $authorizedPluginTrack.withValue(target) {
                    await rollback(track, observedID, observedSlot, runtime)
                }
                var extras: [String: Any] = [
                    "operation": operation,
                    "target_identity": identity,
                    "observed_plugin_id": observedID,
                    "observed_plugin_name": observedName ?? NSNull(),
                    "observed_slot": observedSlot,
                    "rollback_attempted": rollbackResult.attempted,
                    "rollback_succeeded": rollbackResult.succeeded,
                    "rollback_retries": rollbackResult.retries,
                    "rollback_last_click": rollbackResult.lastClickResult,
                    "select_trace": trace,
                    "what_was_attempted": "insert \(pluginID) at the requested slot \(insert) via the exact slot popup",
                    "what_was_observed": "the exact slot popup flow placed \(pluginID) at slot \(observedSlot), not the requested slot \(insert)",
                    "safe_to_retry": false,
                    "write_attempted": true,
                ]
                // When the automatic rollback could NOT confirm removal, the stray
                // plugin is still mounted — guide an LLM agent to clean up manually
                // rather than leave it guessing (P3-b).
                if !rollbackResult.succeeded {
                    extras["recovery_action"] = "undo the last insert manually in Logic Pro (Edit > Undo) — the plugin remains mounted at slot \(observedSlot)"
                }
                return .error(HonestContract.encodeV2StateC(
                    error: .insertLandedAtDifferentSlot,
                    extras: extras
                ))
            }
            // The front document was checked once, before any of this: track select, mixer raise,
            // inventory, pop-up, discovery, pick and poll all happen after it. Switching project
            // during that window would put the write — and this readback — in a different document
            // than the caller named, and every check above would still agree with itself. Re-read it
            // before certifying, so State A is never granted to a document we cannot still name.
            if let expectedPath = params["project_expected_path"],
               !expectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let stillObserved = await frontDocumentPath()
                guard let stillObserved,
                      AppleScriptChannel.projectPathsMatch(expectedPath, stillObserved) else {
                    var driftIdentity = identity
                    driftIdentity["project_path_expected"] = expectedPath
                    driftIdentity["project_path_observed"] = stillObserved ?? NSNull()
                    return .error(HonestContract.encodeV2StateC(
                        error: .projectIdentityMismatch,
                        extras: [
                            "operation": operation,
                            "target_identity": driftIdentity,
                            "observed_plugin_id": observedID,
                            "observed_plugin_name": observedName ?? NSNull(),
                            "observed_slot": observedSlot,
                            "select_trace": trace,
                            "what_was_attempted": "confirm the front document is still the expected one before certifying the insert",
                            "what_was_observed": stillObserved == nil
                                ? "no front document path could be read after the write"
                                : "the front document changed while the insert was in progress",
                            "safe_to_retry": false,
                            "write_attempted": true,
                        ]
                    ))
                }
            }
            return .success(HonestContract.encodeV2StateA(extras: [
                "operation": operation,
                "target_identity": identity,
                "observed_plugin_id": observedID,
                "observed_plugin_name": observedName ?? NSNull(),
                "observed_slot": observedSlot,
                "select_trace": trace,
                "write_source": trace["write_source"] as? String ?? "ax_exact_slot_popup",
                "verify_source": "ax_plugin_inventory",
            ]))

        case .readbackUnavailable:
            return .error(HonestContract.encodeV2StateC(
                error: .postInsertReadbackUnavailable,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "select_trace": trace,
                    "what_was_attempted": "read back the insert inventory after exact slot insert",
                    "what_was_observed": "the mixer/strip insert subtree was unreadable after the insert",
                    "safe_to_retry": true,
                    "write_attempted": true,
                ]
            ))

        case let .trackSelectionFailed(detail):
            return .error(trackSelectionFailedStateC(operation, identity, detail))

        case let .rollbackFailed(slot, observedID, observedName, rollbackResult):
            return .error(HonestContract.encodeV2StateC(
                error: .rollbackFailed,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "observed_plugin_id": observedID ?? NSNull(),
                    "observed_plugin_name": observedName ?? NSNull(),
                    "observed_slot": slot ?? NSNull(),
                    "rollback_attempted": rollbackResult.attempted,
                    "rollback_succeeded": rollbackResult.succeeded,
                    "rollback_retries": rollbackResult.retries,
                    "rollback_last_click": rollbackResult.lastClickResult,
                    "select_trace": trace,
                    "what_was_attempted": "roll back a stray exact-slot popup insert before continuing",
                    "what_was_observed": "a plugin mutation remained after automatic rollback could not confirm removal",
                    "recovery_action": slot.map {
                        "inspect Logic Pro insert slot \($0) and undo/remove the stray plugin manually before retrying"
                    } ?? "inspect Logic Pro and undo/remove the stray plugin manually before retrying",
                    "safe_to_retry": false,
                    "write_attempted": true,
                ]
            ))

        case let .postCommitTimeout(strategy):
            return .error(HonestContract.encodeV2StateC(
                error: .operationTimeout,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "commit_strategy": strategy,
                    "select_trace": trace,
                    "what_was_attempted": "wait for post-insert inventory to confirm the exact slot popup commit",
                    "what_was_observed": "the insert UI changed/closed before the requested plugin appeared in readback",
                    "safe_to_retry": true,
                    "write_attempted": true,
                ]
            ))

        case let .mountMismatch(observedName):
            // The requested plugin never appeared at the requested slot.
            // Honest-deferred terminal: the insert could not be verified in this
            // Logic build. The driver has already attempted rollback for any stray
            // mount it observed.
            return .error(HonestContract.encodeV2StateC(
                error: .insertNotAxAutomatable,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "observed_plugin_name": observedName ?? NSNull(),
                    "select_trace": trace,
                    "what_was_attempted": "insert \(pluginID) into slot \(insert) via the exact slot popup",
                    "what_was_observed": observedName == nil
                        ? "no plugin appeared at slot \(insert) after the exact slot popup path"
                        : "slot \(insert) showed '\(observedName!)' which is not the requested \(pluginID) after the exact slot popup path",
                    "safe_to_retry": false,
                    "write_attempted": true,
                ]
            ))

        case let .transientSetupFailure(stage, actuated, safeToRetry):
            // No plug-in leaf was chosen. Preserve whether the slot opener was dispatched;
            // lost target identity after opening is not an automatically safe retry.
            return .error(HonestContract.encodeV2StateC(
                error: .insertSetupFailed,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "setup_stage": stage,
                    "select_trace": trace,
                    "what_was_attempted": "open the requested slot popup and choose \(pluginID)",
                    "what_was_observed": actuated
                        ? "the slot's opener was dispatched, then setup stopped at stage '\(stage)' before any plugin was chosen"
                        : "the exact slot popup UI was not ready at stage '\(stage)' — nothing was dispatched at the slot",
                    "safe_to_retry": safeToRetry,
                    "write_attempted": actuated,
                ]
            ))
        }
    }

    // MARK: - insert_verified live drivers

    /// Logic's empty insert slot exposes this custom action verbatim, including
    /// the metadata lines. It opens the legacy-inclusive plug-in popup even
    /// though the AX call can report `cannotComplete` after opening it.
    static let slotPopupOpenCustomAction =
        "Name:Open plug-in menu with legacy plug-ins\nTarget:0x0\nSelector:(null)"

    /// The custom-action enumeration outcome. Only an explicit successful
    /// enumeration that omits the action may use the coordinate compatibility
    /// path; an unreadable enumeration must fail closed before any write.
    enum SlotPopupOpenCustomActionEnumerationResult: Sendable {
        case enumeratedAndPresent
        case enumeratedAndAbsent
        case enumerationFailed
    }

    /// Production exact-slot popup insert driver. Drives the target insert slot's
    /// own popup menu and returns a structured outcome plus a `select_trace`
    /// diagnostic dict. This is the default path that uses coordinate-free AX
    /// actions; `defaultInsertVerified` is unit-tested against an injected fake.
    ///
    /// Sequence:
    ///   0. hide any stray plugin windows (a front plugin window from a prior
    ///      attempt steals the menu — R14 live: AXPress menu nav opened the track
    ///      instrument window instead of the requested slot popup);
    ///   1. select the target track and verify `AXSelected` readback;
    ///   2. raise the mixer/main window and read the full pre-insert inventory;
    ///   3. locate the requested filtered insert slot and invoke its discovered
    ///      custom action to open that slot's popup (coordinate fallback only when
    ///      the action is absent);
    ///   4. prove the popup is anchored to the target slot, then choose the stock
    ///      plugin by exact leaf title from that anchored popup (direct/recursive
    ///      discovery), not by localized category names;
    ///   5. CONDITION-poll the inventory (wait for an actual change, not the first
    ///      readable snapshot) and diff against the pre-snapshot to detect WHERE
    ///      the requested plugin landed;
    ///   6. report `.mounted(slot:)` with the detected physical slot — the gate
    ///      maps slot==insert to State A, slot!=insert to State C; a permanent
    ///      no-mount is `.mountMismatch` (insert_not_ax_automatable), a transient
    ///      UI-setup failure (slot popup/anchor/exact leaf not ready) is
    ///      `.transientSetupFailure` (insert_setup_failed, retry-able), and an
    ///      unreadable pre-inventory refuses before slot actuation; unreadable post-inventory
    ///      is the retry-able `.readbackUnavailable` after the plugin leaf was chosen.
    static let liveExactSlotPopupInsert: PluginInsertDriver = { track, insert, pluginID, searchQuery, runtime in
        var trace: [String: Any] = [
            "requested_track": track,
            "requested_insert": insert,
            "requested_plugin_id": pluginID,
            "search_query": searchQuery,
            "write_source": "ax_exact_slot_popup",
            "strategies_attempted": [String](),
        ]

        trace["go_to_position_closed"] = closeGoToPositionDialog(runtime: runtime)
        trace["plugin_windows_hidden"] = await hideAllPluginWindows(runtime: runtime)
        try? await Task.sleep(for: .milliseconds(150))

        let trackSelected = AXLogicProElements.selectTrackViaAX(at: track, runtime: runtime)
        trace["track_select_ok"] = trackSelected
        let selectedVerified = trackSelected
            ? await verifiedTrackSelected(track: track, runtime: runtime)
            : false
        trace["track_select_verified"] = selectedVerified
        guard selectedVerified else {
            return (
                .trackSelectionFailed(trackSelected
                    ? "track \(track) selection could not be verified via AXSelected readback"
                    : "AX track selection write failed for track \(track)"
                ),
                trace
            )
        }
        try? await Task.sleep(for: .milliseconds(150))

        if let target = authorizedPluginTrack {
            let stable = await AXPluginTrackBinding.waitUntilStable(target, runtime: runtime)
            trace["target_binding_stable_after_selection"] = stable
            guard stable else {
                return (.transientSetupFailure(stage: "target_track_binding_changed_after_selection"), trace)
            }
        }
        let raised = raiseMixerWindow(runtime: runtime)
        trace["window_raised"] = raised
        guard raised else {
            return (.transientSetupFailure(stage: "target_mixer_window_unavailable"), trace)
        }
        try? await Task.sleep(for: .milliseconds(150))

        let preSnapshot = fullStripInventory(track: track, runtime: runtime)
        trace["pre_inventory_readable"] = (preSnapshot != nil)
        guard let preInventory = preSnapshot else {
            return (.transientSetupFailure(stage: "pre_insert_inventory_unavailable"), trace)
        }

        guard let targetSlot = liveInsertSlot(track: track, insert: insert, runtime: runtime) else {
            return (.transientSetupFailure(stage: "target_slot_not_found"), trace)
        }
        // The initial write gate and the just-read snapshot may already be stale.
        // Re-resolve and require the physical target is still the empty slot the
        // attempt was authorized to use before any popup-opening actuation.
        guard preInventory[insert] == nil, targetSlot.isEmpty else {
            return (.transientSetupFailure(stage: "target_slot_no_longer_empty"), trace)
        }
        trace["target_slot_found"] = true

        // One element must carry BOTH the authorisation and the actuation. Enumerating the custom
        // action on one resolution and acting on a later one authorised an element that is not the
        // element being driven: if the AX tree replaces the still-empty slot in between, the
        // replacement may expose the action, or have an unreadable action list — the case the
        // three-state enumeration exists to refuse — and would be actuated anyway.
        //
        // So re-resolve as late as possible, prove it is still the empty slot the attempt was
        // authorised to use, and from here on read and act only through `slot`.
        guard let slot = liveInsertSlot(track: track, insert: insert, runtime: runtime),
              slot.isEmpty else {
            return (.transientSetupFailure(stage: "target_slot_no_longer_empty"), trace)
        }
        let popupAnchorSlot = slot.element
        if let position = AXHelpers.getPosition(slot.element, runtime: runtime.ax),
           let size = AXHelpers.getSize(slot.element, runtime: runtime.ax) {
            trace["target_slot_frame"] = ["x": position.x, "y": position.y,
                                          "width": size.width, "height": size.height]
        }
        // Anything already open belongs to someone else; only a menu that appears after we actuate
        // can be evidence that WE opened this slot's pop-up.
        guard let preexistingMenus = visibleSlotPopupMenus(runtime: runtime) else {
            return (.transientSetupFailure(stage: "popup_snapshot_unreadable"), trace)
        }
        trace["slot_popup_preexisting_menus"] = preexistingMenus.count
        let authorisation = slotPopupOpenCustomActionEnumerationResult(on: slot.element, runtime: runtime.ax)

        // Enumeration is a read and takes time, so the slot may be occupied by the time we act.
        // Re-read it — but require the SAME element, not merely an empty one: a replacement element
        // was never the subject of `authorisation`, and it may expose the custom action or refuse to
        // enumerate at all. Occupancy and identity are reported separately so the receipt says which
        // one refused.
        guard let fresh = liveInsertSlot(track: track, insert: insert, runtime: runtime) else {
            return (.transientSetupFailure(stage: "target_slot_no_longer_empty"), trace)
        }
        guard fresh.isEmpty else {
            return (.transientSetupFailure(stage: "target_slot_no_longer_empty"), trace)
        }
        guard CFEqual(fresh.element, slot.element) else {
            return (.transientSetupFailure(stage: "target_slot_element_replaced"), trace)
        }

        switch authorisation {
        case .enumeratedAndPresent:
            // Live evidence: this can return `cannotComplete` (-25204) even when it opens the popup.
            // Dispatch it through the same runtime seam as AXPress, and let the observed popup poll
            // below make the decision.
            _ = AXHelpers.performAction(slot.element, slotPopupOpenCustomAction, runtime: runtime.ax)
            trace["slot_popup_open_fallback_taken"] = false
            trace["slot_popup_open_action"] = "custom_action"
            trace["slot_popup_open_action_enumeration"] = "present"
        case .enumeratedAndAbsent:
            // Compatibility path for builds that do not expose the measured custom action. Recorded
            // deliberately: a coordinate fallback is never reported as the coordinate-free path.
            trace["slot_popup_open_fallback_taken"] = true
            trace["slot_popup_open_action"] = "coordinate_fallback"
            trace["slot_popup_open_action_enumeration"] = "absent"
            switch clickElementCenterOutcome(slot.element, runtime: runtime.ax) {
            case .posted:
                break
            case .noTargetPoint:
                // Nothing was created or posted, so the envelope must not claim a write.
                return (.transientSetupFailure(stage: "target_slot_click_failed", actuated: false), trace)
            case .postFailed:
                return (.transientSetupFailure(stage: "target_slot_click_failed", actuated: true), trace)
            }
        case .enumerationFailed:
            // An AX read failure does not prove that this build lacks the custom action, so it must
            // not downgrade to the coordinate write path.
            trace["slot_popup_open_fallback_taken"] = false
            trace["slot_popup_open_action"] = "action_enumeration_failed"
            trace["slot_popup_open_action_enumeration"] = "failed"
            trace["slot_popup_open_setup_stage"] = "slot_action_enumeration_failed"
            return (.transientSetupFailure(stage: "slot_action_enumeration_failed"), trace)
        }
        try? await Task.sleep(for: .milliseconds(250))

        guard let rootMenu = await pollSlotPopupMenu(
            runtime: runtime, timeoutMs: 1_200, excluding: preexistingMenus
        ) else {
            AXMouseHelper.pressEscape()
            return (.transientSetupFailure(stage: "slot_popup_menu_not_found", actuated: true), trace)
        }
        trace["slot_popup_menu_found"] = true
        if let position = AXHelpers.getPosition(rootMenu, runtime: runtime.ax),
           let size = AXHelpers.getSize(rootMenu, runtime: runtime.ax) {
            trace["slot_popup_frame"] = ["x": position.x, "y": position.y,
                                         "width": size.width, "height": size.height]
        }

        let anchorVerified = slotPopupMenuIsAnchored(
            rootMenu, toSlot: popupAnchorSlot, runtime: runtime.ax
        )
        trace["slot_popup_anchor_verified"] = anchorVerified
        guard anchorVerified else {
            AXMouseHelper.pressEscape()
            return (.transientSetupFailure(stage: "slot_popup_not_anchored_to_target_slot", actuated: true), trace)
        }

        var commitTargetRefused = false
        guard let pluginClick = await clickPluginInAnchoredSlotPopup(
            pluginID: pluginID,
            displayName: searchQuery,
            rootMenu: rootMenu,
            runtime: runtime.ax,
            authorizePick: {
                // Menu discovery can yield while the user changes the track or physical slot.
                // Authorize the terminal AXPick from a fresh observation of the retained target,
                // never from popup geometry or the earlier empty-slot snapshot alone.
                trace.removeValue(forKey: "slot_commit_empty_observed")
                trace.removeValue(forKey: "slot_commit_same_physical_element")
                trace.removeValue(forKey: "slot_commit_read_status")
                trace.removeValue(forKey: "slot_commit_failure_stage")
                let fresh = liveInsertSlot(track: track, insert: insert, runtime: runtime, onRefusal: {
                    trace["slot_commit_failure_stage"] = $0
                })
                trace["slot_commit_target_resolved"] = fresh != nil
                guard let fresh else {
                    commitTargetRefused = true
                    return false
                }
                let sameElement = CFEqual(fresh.element, slot.element)
                trace["slot_commit_read_status"] = fresh.readStatus.rawValue
                trace["slot_commit_empty_observed"] = fresh.isEmpty
                trace["slot_commit_same_physical_element"] = sameElement
                guard fresh.isEmpty, sameElement else {
                    commitTargetRefused = true
                    return false
                }
                return true
            }
        ) else {
            if commitTargetRefused {
                // Cancel only the menu this attempt observed after its opener. A target failure
                // cannot authorize a global Escape or claim the popup is gone from AX's return.
                trace["slot_popup_cancel_attempted"] = true
                trace["slot_popup_cancel_returned"] = AXHelpers.performAction(
                    rootMenu, kAXCancelAction as String, runtime: runtime.ax
                )
                return (.transientSetupFailure(
                    stage: "target_slot_changed_before_plugin_commit", actuated: true, safeToRetry: false
                ), trace)
            }
            AXMouseHelper.pressEscape()
            return (.transientSetupFailure(stage: "plugin_exact_leaf_not_found", actuated: true), trace)
        }
        trace["strategies_attempted"] = pluginClick.strategies
        trace["winning_strategy"] = pluginClick.strategy
        trace["winning_menu_path"] = pluginClick.path.joined(separator: " > ")
        trace["plugin_selection_id"] = pluginID
        // Published compatibility receipt: every leaf-selection strategy at this
        // head is AXPick, so this is constant and not a discriminator.
        trace["leaf_select_coord_free"] = true

        #if DEBUG
        // QA/test-only seam (#425): after a winning leaf select, deterministically
        // take the postCommitTimeout branch — set via the env var
        // LOGIC_MCP_FORCE_POSTCOMMIT_TIMEOUT=1 (live server over stdio) or the
        // @TaskLocal (unit tests). It short-circuits the mount readback so a
        // controlled coord-free/coordinate win exercises the honest
        // `commit_strategy` end to end. It ONLY forces the fail-closed State-C
        // timeout envelope — it NEVER fabricates a State-A success. Stripped in
        // release (`#if DEBUG`).
        if forcePostCommitTimeoutForTestsActive {
            return (
                .postCommitTimeout(strategy: "slot_popup_axpick_menu_select"),
                trace
            )
        }
        #endif

        let poll = await pollStripInventoryUntil(
            track: track, runtime: runtime, timeoutMs: 2_000
        ) { inv in
            newlyMountedSlot(pluginID: pluginID, pre: preInventory, post: inv) != nil
                || newlyMountedAnyPlugin(pre: preInventory, post: inv) != nil
        }
        guard let postInventory = poll.satisfied ?? poll.lastReadable else {
            return (.readbackUnavailable, trace)
        }

        if let detected = newlyMountedSlot(pluginID: pluginID, pre: preInventory, post: postInventory) {
            trace["observed_slot"] = detected.slot
            trace["observed_name"] = detected.name ?? NSNull()
            return (.mounted(slot: detected.slot, pluginID: pluginID, observedName: detected.name), trace)
        }

        if let stray = newlyMountedAnyPlugin(pre: preInventory, post: postInventory) {
            trace["stray_mount_plugin_id"] = stray.pluginID ?? NSNull()
            trace["stray_mount_name"] = stray.name ?? NSNull()
            let rollback = await verifiedUndoPluginInsert(
                track: track, strayPluginID: stray.pluginID, straySlot: stray.slot,
                strayName: stray.name, runtime: runtime
            )
            trace["stray_rollback_succeeded"] = rollback.succeeded
            trace["stray_rollback_attempted"] = rollback.attempted
            trace["stray_rollback_retries"] = rollback.retries
            trace["stray_rollback_last_click"] = rollback.lastClickResult
            guard rollback.succeeded else {
                return (
                    .rollbackFailed(
                        slot: stray.slot,
                        pluginID: stray.pluginID,
                        observedName: stray.name,
                        rollback: rollback
                    ),
                    trace
                )
            }
        }

        if poll.satisfied == nil {
            return (
                .postCommitTimeout(strategy: "slot_popup_axpick_menu_select"),
                trace
            )
        }
        return (.mountMismatch(observedName: postInventory[insert]?.name), trace)
    }

    // MARK: - insert_verified live driver helpers

    #if DEBUG
    /// QA/test seam (#425): when set, `liveExactSlotPopupInsert` short-circuits to
    /// the postCommitTimeout branch after a winning leaf select, so a controlled
    /// insert deterministically exercises the honest `commit_strategy` without a
    /// real mount. It only forces the fail-closed State-C timeout envelope — it
    /// never fabricates a State-A success. Read from the @TaskLocal (unit tests)
    /// or the LOGIC_MCP_FORCE_POSTCOMMIT_TIMEOUT env var (live server driven over
    /// stdio). Stripped entirely in release.
    @TaskLocal static var forcePostCommitTimeoutForTests: Bool?

    static var forcePostCommitTimeoutForTestsActive: Bool {
        if let forcePostCommitTimeoutForTests { return forcePostCommitTimeoutForTests }
        return ProcessInfo.processInfo.environment["LOGIC_MCP_FORCE_POSTCOMMIT_TIMEOUT"] == "1"
    }

    static func withForcePostCommitTimeoutForTests<Result>(
        _ value: Bool,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $forcePostCommitTimeoutForTests.withValue(value, operation: operation)
    }
    #endif

    /// Raise the window that contains the visible mixer (the R12 key step — the
    /// Mix menu item is disabled until the mixer window is frontmost). Falls back
    /// to the main window. Returns whether an `AXRaise` was issued.
    private static func raiseMixerWindow(runtime: AXLogicProElements.Runtime) -> Bool {
        if let target = authorizedPluginTrack {
            guard AXPluginTrackBinding.isStable(target, runtime: runtime),
                  let window = AXPluginTrackBinding.owningWindow(target, runtime: runtime) else { return false }
            return AXHelpers.performAction(window, kAXRaiseAction as String, runtime: runtime.ax)
        }
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return false }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) ?? []
        // Prefer a window that actually holds a mixer area; else the main window.
        for window in windows {
            if AXHelpers.findDescendant(
                of: window, role: kAXGroupRole as String, identifier: "Mixer", maxDepth: 6, runtime: runtime.ax
            ) != nil {
                return AXHelpers.performAction(window, kAXRaiseAction as String, runtime: runtime.ax)
            }
        }
        if let main = AXLogicProElements.mainWindow(runtime: runtime) {
            return AXHelpers.performAction(main, kAXRaiseAction as String, runtime: runtime.ax)
        }
        return false
    }

    /// Hide every open plug-in window via "Window > Hide All Plug-in Windows" so a
    /// stray front plugin window (e.g. a track instrument window left open by a
    /// prior attempt) cannot capture the subsequent Mix-menu click (R14 live root
    /// cause). Best-effort: returns whether the menu item was clicked.
    @discardableResult
    private static func hideAllPluginWindows(runtime: AXLogicProElements.Runtime) async -> Bool {
        let result = await clickTopLevelMenuItemViaAXMenuClick(
            candidates: [AXLocalePolicy.hidePluginWindowsMenuPath],
            runtime: runtime,
            maxEnabledRetries: 1,
            focusBetweenAttempts: false
        )
        return result.clicked
    }

    private static func clickTopLevelMenuItemViaAXMenuClick(
        candidates: [AXLocalePolicy.MenuPath],
        runtime: AXLogicProElements.Runtime,
        maxEnabledRetries: Int,
        focusBetweenAttempts: Bool,
        actuators: MenuClickActuators = .production,
        permittingActuation: () -> Bool = { true }
    ) async -> (itemFound: Bool, clicked: Bool, enabledRetries: Int) {
        var itemFound = false
        for attempt in 0..<maxEnabledRetries {
            guard permittingActuation() else { return (itemFound,false,attempt) }
            _ = actuators.activateLogic()
            guard permittingActuation() else { return (itemFound,false,attempt) }
            for candidate in candidates {
                guard let barItem = menuBarItem(matching: candidate.bar, runtime: runtime) else {
                    continue
                }

                guard permittingActuation() else { return (itemFound,false,attempt) }
                if !openMenuBarItem(barItem, runtime: runtime.ax) {
                    continue
                }
                try? await Task.sleep(for: .milliseconds(120))
                guard permittingActuation() else { return (itemFound,false,attempt) }

                guard let item = menuItem(
                    matching: candidate.item,
                    mode: candidate.itemMode,
                    under: barItem,
                    runtime: runtime.ax
                ) else {
                    guard permittingActuation() else { return (itemFound,false,attempt) }
                    actuators.pressEscape()
                    continue
                }
                itemFound = true

                if let enabled: Bool = AXHelpers.getAttribute(item, kAXEnabledAttribute, runtime: runtime.ax),
                   enabled == false {
                    guard permittingActuation() else { return (itemFound,false,attempt) }
                    actuators.pressEscape()
                    continue
                }

                // ADR-001 coordinate ban: activate the menu ITEM via AXPress, like
                // the menu-bar OPEN above — the former element-derived
                // clickElementCenter rung is removed. AXPress reports success
                // synchronously; on failure the Escape + retry hygiene below still
                // runs, the mixer-reveal consumer falls back to the non-coordinate
                // cgevent key-7 channel, and the hide-plugin-windows consumer is
                // explicitly best-effort — so no feature is degraded.
                guard permittingActuation() else { return (itemFound,false,attempt) }
                if AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax) {
                    return (true, true, attempt)
                }
                guard permittingActuation() else { return (itemFound,false,attempt) }
                actuators.pressEscape()
            }

            if focusBetweenAttempts {
                guard permittingActuation() else { return (itemFound,false,attempt) }
                _ = actuators.raiseMixerWindow()
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return (itemFound, false, maxEnabledRetries)
    }

    private static func menuBarItem(
        matching labels: AXLocalePolicy.LabelSet,
        runtime: AXLogicProElements.Runtime
    ) -> AXUIElement? {
        guard let menuBar = AXLogicProElements.getMenuBar(runtime: runtime) else { return nil }
        return AXLocalePolicy.findMenuBarItem(in: menuBar, matching: labels, runtime: runtime.ax)
    }

    private static func openMenuBarItem(
        _ item: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        // ADR-001 coordinate ban: open the menu-bar item via AXPress only
        // (menu-bar items respond to AXPress). The former element-derived
        // clickElementCenter-first rung is removed. The features this serves keep
        // non-coordinate fallbacks — mixer reveal falls back to the cgevent key-7
        // channel and Edit▸Undo to Cmd+Z — so no feature is degraded.
        AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime)
    }

    private static func menuItem(
        matching labels: AXLocalePolicy.LabelSet,
        mode: AXLocalePolicy.MatchMode = .exact,
        under menuBarItem: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        AXLocalePolicy.findMenuItem(under: menuBarItem, matching: labels, mode: mode, runtime: runtime)
    }

    /// Outcome of a menu-item probe/click.
    private enum MenuItemScriptResult: String {
        case ok
        case disabled
        case missing
        /// The Edit menu offered an Undo entry, but it does not describe our plug-in insert. Nothing
        /// was pressed: undoing it would revert the user's work.
        case notOurs = "not_ours"
    }

    private static func clickEditUndoViaAXMenuClick(
        runtime: AXLogicProElements.Runtime = .production
    ) async -> MenuItemScriptResult {
        _ = ProcessUtils.Runtime.production.activateLogicPro()
        for candidate in [AXLocalePolicy.editUndoMenuPath] {
            guard let barItem = menuBarItem(matching: candidate.bar, runtime: runtime) else {
                continue
            }
            if !openMenuBarItem(barItem, runtime: runtime.ax) {
                continue
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard let item = menuItem(
                matching: candidate.item,
                mode: candidate.itemMode,
                under: barItem,
                runtime: runtime.ax
            ) else {
                AXMouseHelper.pressEscape()
                continue
            }
            // Only undo OUR insert. The template match above finds whatever sits on top of the stack,
            // and pressing that undoes the user's last action when it is not ours. Measured live:
            // Logic offers "Undo Insert Plug-in in Channel Strip" for our own write, and entries such
            // as "Undo selected Channel Strips" for things we must not touch.
            let offered: String = AXHelpers.getAttribute(
                item, kAXTitleAttribute, runtime: runtime.ax
            ) ?? ""
            guard AXLocalePolicy.undoPluginInsertMenuItem.containsAny(in: offered) else {
                Log.warn(
                    "rollback refused: Edit menu offers \(offered.isEmpty ? "an unreadable entry" : "'\(offered)'"), not our plug-in insert",
                    subsystem: "ax"
                )
                AXMouseHelper.pressEscape()
                return .notOurs
            }
            if let enabled: Bool = AXHelpers.getAttribute(
                item, kAXEnabledAttribute, runtime: runtime.ax
            ), enabled == false {
                AXMouseHelper.pressEscape()
                return .disabled
            }
            // ADR-001 coordinate ban: AXPress the Undo menu item (same conversion
            // as the menu-bar open above); the coordinate-free Cmd+Z fallback in
            // the caller still covers an AXPress failure, so no feature is degraded.
            if AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax) {
                return .ok
            }
            AXMouseHelper.pressEscape()
        }
        return .missing
    }

    private static func postCommandZToLogic() -> Bool {
        guard let pid = ProcessUtils.logicProPID() else { return false }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0x06, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x06, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    /// Force the mixer-bearing window to the AX front (`AXMain` + `AXFocused`
    /// true) and re-raise it. Used between enabled-poll iterations to coax Logic
    /// into syncing channel-strip focus so the Mix menu becomes enabled.
    private static func forceMixerWindowFront() -> Bool {
        if let target = authorizedPluginTrack {
            guard AXPluginTrackBinding.isStable(target, runtime: .production),
                  let window = AXPluginTrackBinding.owningWindow(target, runtime: .production) else { return false }
            _ = AXHelpers.setAttribute(window, kAXMainAttribute as String, true as CFTypeRef, runtime: .production)
            _ = AXHelpers.setAttribute(window, kAXFocusedAttribute as String, true as CFTypeRef, runtime: .production)
            return AXHelpers.performAction(window, kAXRaiseAction as String, runtime: .production)
        }
        guard let app = AXLogicProElements.appRoot(runtime: .production) else { return false }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: .production
        ) ?? []
        for window in windows where AXHelpers.findDescendant(
            of: window, role: kAXGroupRole as String, identifier: "Mixer", maxDepth: 6, runtime: .production
        ) != nil {
            _ = AXHelpers.setAttribute(window, kAXMainAttribute as String, true as CFTypeRef, runtime: .production)
            _ = AXHelpers.setAttribute(window, kAXFocusedAttribute as String, true as CFTypeRef, runtime: .production)
            return AXHelpers.performAction(window, kAXRaiseAction as String, runtime: .production)
        }
        return raiseMixerWindow(runtime: .production)
    }

    private static func liveInsertSlot(
        track: Int,
        insert: Int,
        runtime: AXLogicProElements.Runtime,
        onRefusal: ((String) -> Void)? = nil
    ) -> AXLogicProElements.PluginInsertSlot? {
        guard let target = boundPluginTrack(track: track, runtime: runtime, onRefusal: onRefusal) else { return nil }
        guard let slots = AXLogicProElements.audioPluginInsertSlots(in: target.strip, runtime: runtime.ax) else {
            onRefusal?("slot_inventory_unavailable"); return nil
        }
        // #234 — a zero-slot result on this mid-flight re-resolution means the
        // insert section became non-enumerable after the pre-insert snapshot
        // (insert_section_not_enumerable semantics, per slotAddressingFailureDetail).
        // Returning nil routes the caller to a transient setup failure; the static
        // fixture tree can't simulate a mid-operation vanish, so this wording is
        // pinned by the three tested envelope sites rather than a dedicated unit AC.
        guard insert >= 0, insert < slots.count else { onRefusal?("slot_index_absent"); return nil }
        return slots[insert]
    }

    /// Waits for a plug-in pop-up that was NOT already open before the caller actuated.
    ///
    /// Geometry alone cannot establish which slot a menu belongs to: insert slots in a strip sit
    /// ~17px apart, while the anchor test accepts a menu anywhere within ±96px of its own height and
    /// a ~500px horizontal band. A leftover menu from a neighbouring slot — or from a previous
    /// attempt — therefore passes that test and would be navigated as though it were ours, mounting
    /// the plug-in on somebody else's slot. Requiring the menu to have APPEARED after our actuation
    /// is causal evidence that geometry cannot supply.
    private static func pollSlotPopupMenu(
        runtime: AXLogicProElements.Runtime,
        timeoutMs: Int,
        excluding preexisting: [AXUIElement] = []
    ) async -> AXUIElement? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        repeat {
            let fresh = (visibleSlotPopupMenus(runtime: runtime) ?? []).filter { menu in
                !preexisting.contains { CFEqual($0, menu) }
            }
            if let menu = fresh.first {
                return menu
            }
            try? await Task.sleep(for: .milliseconds(80))
        } while Date() < deadline
        return nil
    }

    /// Enumerates the custom popup opener on this specific slot. Action discovery
    /// is separate from action execution because the latter can report failure
    /// after the popup is already open.
    private static func slotPopupOpenCustomActionEnumerationResult(
        on element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> SlotPopupOpenCustomActionEnumerationResult {
        #if DEBUG
        if let result = slotPopupOpenCustomActionEnumerationResultForTests {
            slotPopupOpenActionEnumerationHookForTests?()
            return result
        }
        #endif
        _ = runtime // action enumeration has no existing runtime hook.
        var actionNames: CFArray?
        guard AXUIElementCopyActionNames(element, &actionNames) == .success,
              let actionNames,
              let actions = actionNames as? [String] else {
            return .enumerationFailed
        }
        return actions.contains(slotPopupOpenCustomAction)
            ? .enumeratedAndPresent
            : .enumeratedAndAbsent
    }

    #if DEBUG
    /// Test-only action-enumeration override. The action itself is still
    /// dispatched through `AXHelpers.performAction` and the shared fake runtime.
    @TaskLocal static var slotPopupOpenCustomActionEnumerationResultForTests:
        SlotPopupOpenCustomActionEnumerationResult?

    /// Test-only hook that runs after a deterministic enumeration result and
    /// before the selected slot-opening write. It models live UI drift in the
    /// otherwise unobservable AX action-enumeration interval.
    @TaskLocal static var slotPopupOpenActionEnumerationHookForTests: (@Sendable () -> Void)?

    static func withSlotPopupOpenCustomActionEnumerationResultForTests<Result>(
        _ result: SlotPopupOpenCustomActionEnumerationResult,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $slotPopupOpenCustomActionEnumerationResultForTests.withValue(
            result, operation: operation
        )
    }

    static func withSlotPopupOpenActionEnumerationHookForTests<Result>(
        _ hook: @escaping @Sendable () -> Void,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $slotPopupOpenActionEnumerationHookForTests.withValue(hook, operation: operation)
    }

    /// Retained action-name test seam for present/absent compatibility fixtures.
    static func withSlotPopupOpenActionNamesForTests<Result>(
        _ actionNames: [String],
        operation: () async throws -> Result
    ) async rethrows -> Result {
        let result: SlotPopupOpenCustomActionEnumerationResult = actionNames.contains(slotPopupOpenCustomAction)
            ? .enumeratedAndPresent
            : .enumeratedAndAbsent
        return try await withSlotPopupOpenCustomActionEnumerationResultForTests(
            result, operation: operation
        )
    }
    #endif

    /// Every currently visible plug-in pop-up, so a caller can tell a menu that was already there
    /// from one its own actuation opened.
    /// nil when the tree could not be read. An unreadable snapshot must not be mistaken for "nothing
    /// was open": that would let a pop-up that existed all along be accepted as newly created.
    private static func visibleSlotPopupMenus(
        runtime: AXLogicProElements.Runtime
    ) -> [AXUIElement]? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return nil }
        let menus = AXHelpers.findAllDescendants(
            of: app, role: kAXMenuRole as String, maxDepth: 9, runtime: runtime.ax
        )
        return menus.filter { menu in
            isVisibleMenu(menu, runtime: runtime.ax)
                && AXHelpers.findDescendant(
                    of: menu, role: kAXTextFieldRole as String, maxDepth: 3, runtime: runtime.ax
                ) != nil
                && AXHelpers.getChildren(menu, runtime: runtime.ax).contains(where: {
                    (AXHelpers.getRole($0, runtime: runtime.ax) ?? "") == (kAXMenuItemRole as String)
                })
        }
    }

    private static func slotPopupMenu(runtime: AXLogicProElements.Runtime) -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return nil }
        let menus = AXHelpers.findAllDescendants(
            of: app, role: kAXMenuRole as String, maxDepth: 9, runtime: runtime.ax
        )
        return menus.first(where: { menu in
            isVisibleMenu(menu, runtime: runtime.ax)
                && AXHelpers.findDescendant(
                    of: menu, role: kAXTextFieldRole as String, maxDepth: 3, runtime: runtime.ax
                ) != nil
                && AXHelpers.getChildren(menu, runtime: runtime.ax).contains(where: {
                    (AXHelpers.getRole($0, runtime: runtime.ax) ?? "") == (kAXMenuItemRole as String)
                })
        })
    }

    private static func isVisibleMenu(_ menu: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        guard let pos = AXHelpers.getPosition(menu, runtime: runtime),
              let size = AXHelpers.getSize(menu, runtime: runtime) else {
            return false
        }
        return pos.x > 0 && pos.y > 0 && size.width > 20 && size.height > 20
    }

    static func slotPopupMenuIsAnchored(
        _ menu: AXUIElement,
        toSlot slot: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard let menuPos = AXHelpers.getPosition(menu, runtime: runtime),
              let menuSize = AXHelpers.getSize(menu, runtime: runtime),
              let slotPos = AXHelpers.getPosition(slot, runtime: runtime),
              let slotSize = AXHelpers.getSize(slot, runtime: runtime),
              menuSize.width > 20,
              menuSize.height > 20,
              slotSize.width > 1,
              slotSize.height > 1 else {
            return false
        }

        let slotCenter = CGPoint(x: slotPos.x + slotSize.width / 2, y: slotPos.y + slotSize.height / 2)
        let verticalBand = (menuPos.y - 96)...(menuPos.y + menuSize.height + 96)
        let horizontalBand = (slotPos.x - 140)...(slotPos.x + slotSize.width + 360)
        // At the screen edge Logic can open the popup to the left, with its
        // right edge touching the slot's left edge. That is still anchored;
        // unlike a wider origin band, interval contact adds no gap allowance.
        let horizontalContact = menuPos.x <= slotPos.x + slotSize.width
            && menuPos.x + menuSize.width >= slotPos.x
        return verticalBand.contains(slotCenter.y)
            && (horizontalBand.contains(menuPos.x) || horizontalContact)
    }

    static func popupExactLeafPaths(
        displayName: String,
        rootMenu: AXUIElement,
        runtime: AXHelpers.Runtime,
        maxDepth: Int = 6
    ) -> [[String]] {
        popupExactLeafPaths(
            displayName: displayName,
            menu: rootMenu,
            prefix: [],
            runtime: runtime,
            maxDepth: maxDepth
        )
    }

    static func preferredPopupExactLeafPath(
        displayName: String,
        rootMenu: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [String]? {
        if let direct = directExactPopupMenuItem(displayName: displayName, in: rootMenu, runtime: runtime),
           let label = popupMenuItemLabel(direct, runtime: runtime) {
            return [label]
        }
        return popupExactLeafPaths(displayName: displayName, rootMenu: rootMenu, runtime: runtime).first
    }

    /// `internal` (was `private`) so popup-navigation results are unit-testable
    /// without driving the live insert flow.
    struct SlotPopupPluginClick: Sendable {
        let strategy: String
        let path: [String]
        let strategies: [String]
    }

    /// `internal` (was `private`) so popup navigation is unit-testable without
    /// driving the live insert flow.
    static func clickPluginInAnchoredSlotPopup(
        pluginID: String,
        displayName: String,
        rootMenu: AXUIElement,
        runtime: AXHelpers.Runtime,
        authorizePick: () -> Bool = { true }
    ) async -> SlotPopupPluginClick? {
        var strategies: [String] = []
        strategies.append("slot_popup_direct_exact_leaf")
        if let item = directExactPopupMenuItem(displayName: displayName, in: rootMenu, runtime: runtime),
           let label = popupMenuItemLabel(item, runtime: runtime),
           await clickPopupPluginLeaf(item, runtime: runtime, authorizePick: authorizePick) {
            return SlotPopupPluginClick(
                strategy: "slot_popup_direct_exact_leaf",
                path: [label],
                strategies: strategies
            )
        }

        strategies.append("slot_popup_recursive_exact_leaf")
        if let result = await clickPopupExactLeafRecursively(
            displayName: displayName,
            menu: rootMenu,
            path: [],
            runtime: runtime,
            maxDepth: 5,
            authorizePick: authorizePick
        ) {
            return SlotPopupPluginClick(
                strategy: "slot_popup_recursive_exact_leaf",
                path: result,
                strategies: strategies
            )
        }

        _ = pluginID // kept in the trace by the caller; selection is by exact display leaf.
        return nil
    }

    private static func clickPopupExactLeafRecursively(
        displayName: String,
        menu: AXUIElement,
        path: [String],
        runtime: AXHelpers.Runtime,
        maxDepth: Int,
        authorizePick: () -> Bool
    ) async -> [String]? {
        guard maxDepth >= 0 else { return nil }

        if let direct = directExactPopupMenuItem(displayName: displayName, in: menu, runtime: runtime),
           let label = popupMenuItemLabel(direct, runtime: runtime),
           await clickPopupPluginLeaf(direct, runtime: runtime, authorizePick: authorizePick) {
            return path + [label]
        }

        let items = popupMenuItems(in: menu, runtime: runtime)
        for item in items {
            guard let label = popupMenuItemLabel(item, runtime: runtime),
                  !popupMenuItemMatches(item, displayName: displayName, runtime: runtime),
                  menuItemEnabled(item, runtime: runtime),
                  let submenu = axChildMenu(of: item, runtime: runtime) else {
                continue
            }
            // Logic already exposes this submenu as an AX child, so discovery can
            // recurse through the read-only tree without actuating the category.
            if let found = await clickPopupExactLeafRecursively(
                displayName: displayName,
                menu: submenu,
                path: path + [label],
                runtime: runtime,
                maxDepth: maxDepth - 1,
                authorizePick: authorizePick
            ) {
                return found
            }
        }
        return nil
    }

    /// Dispatch AXPick to the matched plugin leaf (or its preferred format leaf).
    /// AX's return code is deliberately ignored: the caller's post-insert inventory
    /// diff is the only acceptance signal.
    /// Dispatches `AXPick` at the plug-in, and reports whether it dispatched anything.
    ///
    /// The result CAN be false, and that is the point: an entry that owns a submenu we cannot
    /// identify as a channel-format chooser is a category wearing a plug-in's name, and picking it
    /// would actuate a category. Refusing lets the caller keep looking instead.
    static func clickPopupPluginLeaf(
        _ item: AXUIElement,
        runtime: AXHelpers.Runtime,
        authorizePick: () -> Bool = { true }
    ) async -> Bool {
        // A disabled entry cannot act, so pressing it produces a silent no-op that the caller then
        // has to distinguish from a real failure downstream. Refuse before touching it.
        guard menuItemEnabledForActuation(item, runtime: runtime) else { return false }
        if let submenu = axChildMenu(of: item, runtime: runtime) {
            guard submenuIsPluginFormatMenu(submenu, runtime: runtime),
                  let leaf = preferredFormatLeafByLabel(in: submenu, runtime: runtime) else {
                return false
            }
            guard authorizePick() else { return false }
            _ = AXHelpers.performAction(leaf, kAXPickAction as String, runtime: runtime)
            return true
        }
        guard authorizePick() else { return false }
        _ = AXHelpers.performAction(item, kAXPickAction as String, runtime: runtime)
        return true
    }

    /// A submenu exposed as an AX child of `item`, regardless of visual visibility.
    private static func axChildMenu(
        of item: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        AXHelpers.getChildren(item, runtime: runtime).first {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXMenuRole as String)
        }
    }

    /// `preferredFormatLeaf` without the on-screen-position requirement, so it works
    /// on a submenu that has not been visually revealed (AX children only).
    private static func preferredFormatLeafByLabel(
        in submenu: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        let items = AXHelpers.getChildren(submenu, runtime: runtime).filter {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXMenuItemRole as String)
        }
        for labels in AXLocalePolicy.pluginFormatLeafPriority {
            if let match = items.first(where: {
                AXLocalePolicy.elementMatches($0, labels, runtime: runtime)
                    && axChildMenu(of: $0, runtime: runtime) == nil
            }) {
                return match
            }
        }
        // No "whatever is first" fallback. An entry that matches no known format label is an entry
        // nothing identified, and picking it would actuate a target the caller never asked for.
        return nil
    }

    /// True when every entry of `submenu` is a known plug-in format label. Logic exposes category
    /// entries named like formats, so descending into "the first AXMenu child" is not enough to know
    /// the submenu is a format chooser rather than more of the plug-in tree.
    private static func submenuIsPluginFormatMenu(
        _ submenu: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let items = AXHelpers.getChildren(submenu, runtime: runtime).filter {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXMenuItemRole as String)
        }
        return !items.isEmpty && items.allSatisfy { item in
            AXLocalePolicy.pluginFormatLeafPriority.contains { labels in
                AXLocalePolicy.elementMatches(item, labels, runtime: runtime)
            }
        }
    }

    private static func popupExactLeafPaths(
        displayName: String,
        menu: AXUIElement,
        prefix: [String],
        runtime: AXHelpers.Runtime,
        maxDepth: Int
    ) -> [[String]] {
        guard maxDepth >= 0 else { return [] }
        var paths: [[String]] = []
        for item in popupMenuItems(in: menu, runtime: runtime) {
            guard let label = popupMenuItemLabel(item, runtime: runtime) else { continue }
            let next = prefix + [label]
            if popupMenuItemMatches(item, displayName: displayName, runtime: runtime) {
                paths.append(next)
            }
            for submenu in AXHelpers.getChildren(item, runtime: runtime)
                where (AXHelpers.getRole(submenu, runtime: runtime) ?? "") == (kAXMenuRole as String) {
                paths.append(contentsOf: popupExactLeafPaths(
                    displayName: displayName,
                    menu: submenu,
                    prefix: next,
                    runtime: runtime,
                    maxDepth: maxDepth - 1
                ))
            }
        }
        return paths
    }

    private static func directExactPopupMenuItem(
        displayName: String,
        in menu: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        popupMenuItems(in: menu, runtime: runtime).first {
            popupMenuItemMatches($0, displayName: displayName, runtime: runtime)
                && menuItemEnabled($0, runtime: runtime)
        }
    }

    private static func popupMenuItems(
        in menu: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [AXUIElement] {
        AXHelpers.getChildren(menu, runtime: runtime).filter {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXMenuItemRole as String)
        }
    }

    private static func popupMenuItemMatches(
        _ item: AXUIElement,
        displayName: String,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard let label = popupMenuItemLabel(item, runtime: runtime) else { return false }
        return label.caseInsensitiveCompare(displayName) == .orderedSame
    }

    private static func popupMenuItemLabel(
        _ item: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        for text in [
            AXHelpers.getTitle(item, runtime: runtime),
            AXHelpers.getDescription(item, runtime: runtime),
        ] {
            if let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    /// Lenient: an unreadable state counts as enabled. Used by READ-ONLY discovery, where refusing to
    /// descend on an unreadable attribute would hide reachable plug-ins and actuates nothing.
    private static func menuItemEnabled(
        _ item: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let enabled: Bool? = AXHelpers.getAttribute(item, kAXEnabledAttribute as String, runtime: runtime)
        return enabled ?? true
    }

    /// Strict: only an explicitly readable `true` authorises a pick.
    ///
    /// `AXEnabled` is the one pre-press signal that separates "will act" from "will do nothing", so
    /// guessing it while about to actuate is the wrong place to be lenient. Measured on Logic 12.3
    /// with the menu chain open: all 1090 items expose a readable value and 264 of them are disabled
    /// — section headers such as "Recent" among them. So there is a real population this can land on,
    /// and no legitimate entry that the strictness excludes.
    private static func menuItemEnabledForActuation(
        _ item: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let enabled: Bool? = AXHelpers.getAttribute(item, kAXEnabledAttribute as String, runtime: runtime)
        return enabled == true
    }

    #if DEBUG
    /// Test seam for the documented absent-custom-action coordinate fallback. When
    /// set, the retained coordinate primitives return this value without posting a
    /// real CGEvent. It is never compiled into release.
    @TaskLocal static var forceCoordinateActuationForTests: Bool?

    /// A test-only coordinate-click effect. This is invoked only after the
    /// fallback reaches `clickElementCenter`, so fixtures can model an observable
    /// consequence of the coordinate click without a real CGEvent.
    private struct CoordinateActuationTestEffect: @unchecked Sendable {
        let perform: () -> Bool
    }

    @TaskLocal private static var coordinateActuationTestEffect: CoordinateActuationTestEffect?

    static func withForceCoordinateActuationForTests<Result>(
        _ value: Bool,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $forceCoordinateActuationForTests.withValue(value, operation: operation)
    }

    static func withCoordinateActuationForTests<Result>(
        _ effect: @escaping () -> Bool,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $coordinateActuationTestEffect.withValue(
            CoordinateActuationTestEffect(perform: effect), operation: operation
        )
    }
    #endif

    /// Outcome of a coordinate click, distinguishing "we never posted anything" from "we posted and
    /// the post failed". The Honest Contract must not claim a write for the former.
    enum CoordinateClickOutcome {
        case posted
        case noTargetPoint
        case postFailed
    }

    private static func clickElementCenterOutcome(
        _ element: AXUIElement, runtime: AXHelpers.Runtime
    ) -> CoordinateClickOutcome {
        #if DEBUG
        if let coordinateActuationTestEffect { return coordinateActuationTestEffect.perform() ? .posted : .postFailed }
        if let forceCoordinateActuationForTests { return forceCoordinateActuationForTests ? .posted : .postFailed }
        #endif
        guard let center = elementCenter(element, runtime: runtime) else { return .noTargetPoint }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)
        else { return .postFailed }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .posted
    }

    @discardableResult
    private static func clickElementCenter(_ element: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        #if DEBUG
        if let coordinateActuationTestEffect { return coordinateActuationTestEffect.perform() }
        if let forceCoordinateActuationForTests { return forceCoordinateActuationForTests }
        #endif
        guard let center = elementCenter(element, runtime: runtime) else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
           let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        }
        return false
    }

    /// Screen centre of an element, or nil when its frame is degenerate (the
    /// R12 frameless-leaf failure mode: a (0, screen-bottom) / zero-size rect is
    /// rejected so we never misclick at the screen corner).
    private static func elementCenter(_ element: AXUIElement, runtime: AXHelpers.Runtime) -> CGPoint? {
        guard let pos = AXHelpers.getPosition(element, runtime: runtime),
              let size = AXHelpers.getSize(element, runtime: runtime),
              size.width > 1, size.height > 1 else { return nil }
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    }

    /// One readable, occupied insert slot observed during a strip inventory pass:
    /// physical slot index → (canonical plugin id, display name).
    struct InventoryEntry: Sendable {
        let pluginID: String?
        let name: String?
    }

    /// Snapshot the target strip's FULL occupied-slot inventory: physical slot
    /// index → observed (plugin id, name). Reuses the drift-safe enumerator and
    /// the same observed-name → canonical-id mapping as `get_inventory`, so the
    /// readback diff is identical to the inventory view. Returns nil when the
    /// mixer/strip subtree is unreadable OR when any occupied slot is unreadable:
    /// diff-based verification must never treat "previously unreadable" as
    /// "newly mounted".
    static func fullStripInventory(
        track: Int, runtime: AXLogicProElements.Runtime
    ) -> [Int: InventoryEntry]? {
        guard let target = boundPluginTrack(track: track, runtime: runtime) else { return nil }
        // #982: a strip whose children did not read is not an empty chain.
        guard let slots = AXLogicProElements.audioPluginInsertSlots(in: target.strip, runtime: runtime.ax),
              !slots.isEmpty,
              !slots.contains(where: { $0.readStatus == .occupiedUnreadable || $0.readStatus == .unclassified }) else {
            return nil
        }
        var result: [Int: InventoryEntry] = [:]
        for slot in slots where slot.readStatus == .occupiedReadable {
            let name = slot.name
            result[slot.index] = InventoryEntry(
                pluginID: name.flatMap(VerifiedPluginCatalog.pluginID(forObservedName:)),
                name: name
            )
        }
        return result
    }

    /// Poll `fullStripInventory` until it is readable or the timeout elapses
    /// (Logic commits the insert asynchronously). Returns the first readable
    /// snapshot, or nil if the strip stayed unreadable for the whole window.
    private static func pollFullStripInventory(
        track: Int, runtime: AXLogicProElements.Runtime, timeoutMs: Int
    ) async -> [Int: InventoryEntry]? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        repeat {
            if let inv = fullStripInventory(track: track, runtime: runtime) {
                return inv
            }
            try? await Task.sleep(for: .milliseconds(120))
        } while Date() < deadline
        return nil
    }

    /// Result of a CONDITION-based inventory poll (P1-2). `satisfied` is the last
    /// readable snapshot for which `condition` held (the settled state we waited
    /// for); when the deadline passes without the condition ever holding, returns
    /// the last readable snapshot (if any) so the caller can diagnose what it saw.
    private struct ConditionPollResult: Sendable {
        let satisfied: [Int: InventoryEntry]?   // non-nil only when condition held
        let lastReadable: [Int: InventoryEntry]?
    }

    /// Poll `fullStripInventory` until `condition` holds on a readable snapshot or
    /// the timeout elapses (P1-2: do NOT settle on the first merely-readable read —
    /// Logic commits/undoes asynchronously, so a fixed-sleep "first readable"
    /// could observe the pre-change state and drive a false-fail on insert or an
    /// extra Undo on rollback that eats a prior user action). The condition is the
    /// settled state the caller is waiting for (e.g. "the new plugin appeared" /
    /// "the stray slot is empty").
    private static func pollStripInventoryUntil(
        track: Int,
        runtime: AXLogicProElements.Runtime,
        timeoutMs: Int,
        condition: ([Int: InventoryEntry]) -> Bool
    ) async -> ConditionPollResult {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var lastReadable: [Int: InventoryEntry]? = nil
        repeat {
            if let inv = fullStripInventory(track: track, runtime: runtime) {
                lastReadable = inv
                if condition(inv) {
                    return ConditionPollResult(satisfied: inv, lastReadable: inv)
                }
            }
            try? await Task.sleep(for: .milliseconds(120))
        } while Date() < deadline
        return ConditionPollResult(satisfied: nil, lastReadable: lastReadable)
    }

    /// Find the slot where `pluginID` is NEWLY present (occupied-readable in
    /// `post` with that id, but not already in `pre` with the same id). This is
    /// the freshly-mounted target regardless of which physical slot Logic chose.
    /// Returns the lowest such slot for determinism.
    private static func newlyMountedSlot(
        pluginID: String, pre: [Int: InventoryEntry], post: [Int: InventoryEntry]
    ) -> (slot: Int, name: String?)? {
        let candidates = post
            .filter { $0.value.pluginID == pluginID && pre[$0.key]?.pluginID != pluginID }
            .sorted { $0.key < $1.key }
        guard let first = candidates.first else { return nil }
        return (first.key, first.value.name)
    }

    /// Find any slot where SOME plugin newly appeared — used to detect+roll back a
    /// stray mount of a non-requested plugin. P1-1: detect by SLOT-PRESENCE (a slot
    /// readable-occupied in `post` but NOT in `pre`) OR by a changed display name
    /// at an already-occupied slot. The previous id-only diff missed a
    /// non-allowlisted stray (its `plugin_id` resolves to nil, so `nil != nil` was
    /// false). Carries the observed display `name` so the rollback can confirm
    /// removal even when the canonical id is nil. Returns the lowest such slot.
    private static func newlyMountedAnyPlugin(
        pre: [Int: InventoryEntry], post: [Int: InventoryEntry]
    ) -> (slot: Int, pluginID: String?, name: String?)? {
        let changed = post
            .filter { (slot, entry) in
                guard let priorEntry = pre[slot] else { return true }  // newly occupied
                // Same slot already occupied before — changed iff id or name differs.
                return priorEntry.pluginID != entry.pluginID || priorEntry.name != entry.name
            }
            .sorted { $0.key < $1.key }
        guard let first = changed.first else { return nil }
        return (first.key, first.value.pluginID, first.value.name)
    }

    /// Close a leftover "위치로 이동" / "Go To Position" floating dialog (a prior
    /// AX side effect) so it cannot steal focus / keep the Mix menu disabled.
    /// Best-effort via AX + CGEvent only: click Cancel/close if present, otherwise
    /// Escape. Returns whether a matching dialog was found.
    @discardableResult
    static func closeGoToPositionDialog(
        runtime: AXLogicProElements.Runtime,
        escape: @Sendable () -> Void = { AXMouseHelper.pressEscape() }
    ) -> Bool {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return false }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) ?? []
        var found = false
        for window in windows {
            let subrole: String? = AXHelpers.getAttribute(
                window, kAXSubroleAttribute as String, runtime: runtime.ax
            )
            let isModal: Bool? = AXHelpers.getAttribute(
                window, kAXModalAttribute as String, runtime: runtime.ax
            )
            let title = AXHelpers.getTitle(window, runtime: runtime.ax) ?? ""
            guard subrole == kAXFloatingWindowSubrole as String,
                  isModal == true,
                  AXLocalePolicy.goToPositionDialogTitle.matches(title, mode: .exactStrict) else {
                continue
            }
            // #1063 (R1063-02): a tooltip listed in AXWindows can answer this shape too; one whose role
            // READS as AXHelpTag is not the dialog. Asked only of a match, so no other window pays the read.
            if windowRoleReadsAsHelpTag(window, runtime: runtime.ax) { continue }
            found = true
            // #628: identified, not merely found. `findDescendant` returns the first match in
            // traversal order, so with two Cancel-labelled buttons it presses one and nothing
            // records that there was a choice. Measured on the real dialog there is exactly one
            // (its children are Cancel and OK), so the census returns that one and the behaviour is
            // unchanged — the difference is that the single candidate is now a checked fact rather
            // than an assumption. A second one falls through to the close-button and Escape paths
            // below, which is the existing fail-open-to-a-safer-route behaviour, not a new refusal.
            let cancelCensus = AXLocalePolicy.censusDescendant(
                of: window,
                role: kAXButtonRole as String,
                matching: AXLocalePolicy.cancelButton,
                maxDepth: 4,
                runtime: runtime.ax
            )
            if let cancel = cancelCensus.element {
                // ADR-001 coordinate ban: dismiss via AXPress only (Escape remains
                // the terminal non-coordinate fallback below).
                if AXHelpers.performAction(cancel, kAXPressAction as String, runtime: runtime.ax) {
                    continue
                }
            }
            if let close = AXHelpers.findAllDescendants(
                of: window, role: kAXButtonRole as String, maxDepth: 4, runtime: runtime.ax
            ).first(where: {
                let subrole: String? = AXHelpers.getAttribute(
                    $0, kAXSubroleAttribute as String, runtime: runtime.ax
                )
                return subrole == kAXCloseButtonSubrole as String
            }) {
                // ADR-001 coordinate ban: AXPress only; no element-derived click.
                _ = AXHelpers.performAction(close, kAXPressAction as String, runtime: runtime.ax)
            } else {
                escape()
            }
        }
        return found
    }

    /// Honest outcome of a verified rollback attempt.
    struct RollbackResult: Sendable {
        let attempted: Bool
        let succeeded: Bool
        let retries: Int
        let lastClickResult: String
    }

    /// Live per-attempt undo action: hide plug-in windows (so the undo lands on
    /// the global Edit menu, not a focused plugin window that would swallow it)
    /// then click the Edit-menu undo item by localized prefix. Returns the click
    /// result's raw string ("ok"/"disabled"/"missing").
    static let liveUndoClick: @Sendable () async -> String = {
        _ = await hideAllPluginWindows(runtime: .production)
        let menuResult = await clickEditUndoViaAXMenuClick()
        if menuResult == .ok || menuResult == .disabled {
            return menuResult.rawValue
        }
        // A refusal must not fall through to the blind Cmd+Z below: we already read the entry and
        // it was not ours, so sending the shortcut would undo the user's work anyway and make the
        // check pointless.
        if menuResult == .notOurs {
            return menuResult.rawValue
        }
        if postCommandZToLogic() {
            return "ok"
        }
        return menuResult.rawValue
    }

    /// Removal-confirmation tristate for a readback snapshot: true (verified
    /// gone), false (verified still present), nil (cannot determine → never claim
    /// success). Identifies the stray by exact (slot, id), then (id only), then
    /// (slot + observed name), then (slot only); both-unknown is unverifiable.
    private static func strayRemovalConfirmed(
        in inv: [Int: InventoryEntry],
        strayPluginID: String?, straySlot: Int?, strayName: String?
    ) -> Bool? {
        if let straySlot, let strayPluginID {
            return inv[straySlot]?.pluginID != strayPluginID
        }
        if let strayPluginID {
            return !inv.values.contains { $0.pluginID == strayPluginID }
        }
        if let straySlot {
            // Known slot, nil id (non-allowlisted stray): confirmed gone iff the
            // slot is empty, OR — if it is occupied again — its display name no
            // longer matches the stray's name (P1-1: name-based confirmation).
            guard let entry = inv[straySlot] else { return true }
            if let strayName { return entry.name != strayName }
            return false  // slot still occupied, no name to disambiguate
        }
        return nil  // both unknown → unverifiable
    }

    /// Roll back a stray plugin insert and CONFIRM removal by CONDITION-based
    /// readback. R16 live: the old click-only undo reported `ok` but the plugin
    /// persisted. P1-2 safety: this clicks Edit-menu Undo at most ONCE per
    /// confirmed-still-present state, then condition-polls for the stray to leave
    /// — it never re-clicks Undo on an ambiguous/mid-settle snapshot (a blind
    /// retry could undo a PRIOR user action and corrupt real data). A retry's
    /// next Undo only fires when the stray is still DEFINITIVELY present.
    ///
    /// `undoClick` is the injectable per-attempt undo action (hide plug-in windows
    /// + send Undo), returning "ok"/"disabled"/"missing". Production wires the
    /// live AX/CGEvent path; tests inject a canned result so the honesty-critical
    /// removal-confirmation is exercised hermetically.
    static func verifiedUndoPluginInsert(
        track: Int,
        strayPluginID: String?,
        straySlot: Int?,
        strayName: String? = nil,
        runtime: AXLogicProElements.Runtime,
        maxRetries: Int = 4,
        undoClick: @Sendable () async -> String = liveUndoClick
    ) async -> RollbackResult {
        var attempted = false
        var lastClick = "missing"
        for attempt in 0..<maxRetries {
            let clickRaw = await undoClick()
            lastClick = clickRaw
            if clickRaw == "ok" { attempted = true }

            // CONDITION-poll for the stray to leave (P1-2): wait until a readable
            // snapshot CONFIRMS removal, rather than settling on the first readable
            // (mid-settle) snapshot. Success only on a confirmed-gone snapshot.
            let poll = await pollStripInventoryUntil(
                track: track, runtime: runtime, timeoutMs: 1_500
            ) { inv in
                strayRemovalConfirmed(
                    in: inv, strayPluginID: strayPluginID, straySlot: straySlot, strayName: strayName
                ) == true
            }
            if poll.satisfied != nil {
                return RollbackResult(
                    attempted: attempted, succeeded: true,
                    retries: attempt, lastClickResult: lastClick
                )
            }

            // Removal not confirmed within the window. Only retry the Undo when the
            // last readable snapshot shows the stray DEFINITIVELY STILL PRESENT
            // (confirmed == false). An unverifiable (nil) or unreadable snapshot
            // must NOT trigger another Undo — a blind retry risks undoing a prior
            // user action (P1-2 data-safety). Also stop if the menu had nothing to
            // undo / was missing.
            let stillDefinitelyPresent = poll.lastReadable.map { inv in
                strayRemovalConfirmed(
                    in: inv, strayPluginID: strayPluginID, straySlot: straySlot, strayName: strayName
                ) == false
            } ?? false
            // `not_ours` joins the stop list: the entry on top of the stack is not our insert, and
            // re-reading the menu cannot change that. Retrying would only keep opening the Edit menu
            // against the user's stack.
            if !stillDefinitelyPresent
                || clickRaw == "disabled" || clickRaw == "missing" || clickRaw == "not_ours" {
                break
            }
        }
        return RollbackResult(
            attempted: attempted, succeeded: false,
            retries: maxRetries, lastClickResult: lastClick
        )
    }

    // MARK: - Helpers

    /// Insertable stock plugins (R5/R7) — Noise Gate is identity-only, excluded.
    static let insertableAllowlist: Set<String> = [
        "logic.stock.effect.gain",
        "logic.stock.effect.channel_eq",
        "logic.stock.effect.compressor",
    ]

    private static func invalidParamsStateC(_ operation: String, _ detail: String) -> String {
        HonestContract.encodeV2StateC(
            error: .invalidParams,
            extras: [
                "operation": operation,
                "what_was_attempted": "validate request parameters",
                "what_was_observed": detail,
                "safe_to_retry": false,
                "write_attempted": false,
            ]
        )
    }

    private static func resolvedIdentity(track: Int, insert: Int, pluginID: String) -> [String: Any] {
        [
            "track_index": track,
            "insert": insert,
            "plugin_id": pluginID,
        ]
    }
}
