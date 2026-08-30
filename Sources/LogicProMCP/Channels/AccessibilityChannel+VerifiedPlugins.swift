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

        static let alreadyVisible = MixerRevealResult(
            attempted: false,
            alreadyVisible: true,
            strategies: [],
            menuItemFound: false,
            menuClicked: false,
            keySent: false,
            mixerVisible: true
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

        // The AX insert subtree is unreadable when the mixer or the requested
        // strip cannot be located — there is nothing to enumerate, so this is
        // State B `readback_unavailable` rather than a fabricated empty chain.
        let ensuredMixer = await revealMixer(runtime)
        let reveal = ensuredMixer.result
        guard let mixer = ensuredMixer.mixer else {
            return .success(HonestContract.encodeV2StateB(
                reason: .readbackUnavailable,
                extras: [
                    "operation": operation,
                    "track": track,
                    "plugins_source": "ax",
                    "plugins_fetched_at": fetchedAt,
                    "plugins_unknown_reason": "mixer_not_visible",
                    "mixer_reveal_attempted": reveal.attempted,
                    "mixer_reveal_strategies": reveal.strategies,
                    "mixer_reveal_menu_item_found": reveal.menuItemFound,
                    "mixer_reveal_menu_clicked": reveal.menuClicked,
                    "mixer_reveal_key_sent": reveal.keySent,
                    "what_was_attempted": reveal.attempted
                        ? "reveal the mixer, then read insert chain inventory for track \(track)"
                        : "read insert chain inventory for track \(track)",
                    "what_was_observed": reveal.attempted
                        ? "the mixer remained hidden after the reveal attempt, so the insert subtree could not be read"
                        : "mixer area was not locatable in the AX tree",
                    "recovery_hint": "Open View > Show Mixer in Logic Pro and retry the inventory read.",
                    "safe_to_retry": true,
                ]
            ))
        }
        let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax)
        guard track < strips.count else {
            return .success(HonestContract.encodeV2StateB(
                reason: .readbackUnavailable,
                extras: [
                    "operation": operation,
                    "track": track,
                    "plugins_source": "ax",
                    "plugins_fetched_at": fetchedAt,
                    "plugins_unknown_reason": "ax_subtree_unreadable",
                    "what_was_attempted": "read insert chain inventory for track \(track)",
                    "what_was_observed": "track index \(track) is not present in the visible mixer (\(strips.count) strips)",
                    "safe_to_retry": true,
                ]
            ))
        }

        let slots = AXLogicProElements.audioPluginInsertSlots(in: strips[track], runtime: runtime.ax)
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
            "plugins": built.items,
        ]))
    }

    /// Poll window for the mixer area to appear after a reveal action. #142
    /// lengthened this from 1500ms: Logic's mixer pane slide-in can exceed 1.5s
    /// on a cold window, so the previous timeout fail-closed to State B
    /// `mixer_not_visible` even when the reveal eventually succeeded.
    static let mixerRevealPollTimeoutMs = 2_500

    private static func ensureMixerAreaVisibleForInventory(
        runtime: AXLogicProElements.Runtime
    ) async -> (mixer: AXUIElement?, result: MixerRevealResult) {
        if let mixer = AXLogicProElements.getMixerArea(runtime: runtime) {
            return (mixer, .alreadyVisible)
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
        _ = ProcessUtils.Runtime.production.activateLogicPro()

        // Strategy 1 (preferred): AX menu-click, with retry.
        let menuAttempt = await clickTopLevelMenuItemViaAXMenuClick(
            candidates: [AXLocalePolicy.showMixerMenuPath],
            runtime: runtime,
            maxEnabledRetries: 2,
            focusBetweenAttempts: false
        )
        var itemFound = menuAttempt.itemFound
        var menuClicked = menuAttempt.clicked
        if menuAttempt.clicked {
            strategies.append("ax_menu_view_show_mixer")
            if let mixer = await pollMixerAreaVisible(
                runtime: runtime, timeoutMs: mixerRevealPollTimeoutMs
            ) {
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
        if let pid = runtime.logicProPID(),
           CGEventChannel.Runtime.production.postKeyEvent(7, [], pid) {
            keySent = true
            strategies.append("cgevent_x")
            if let mixer = await pollMixerAreaVisible(
                runtime: runtime, timeoutMs: mixerRevealPollTimeoutMs
            ) {
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
        let menuRetry = await clickTopLevelMenuItemViaAXMenuClick(
            candidates: [AXLocalePolicy.showMixerMenuPath],
            runtime: runtime,
            maxEnabledRetries: 1,
            focusBetweenAttempts: true
        )
        itemFound = itemFound || menuRetry.itemFound
        if menuRetry.clicked {
            menuClicked = true
            if !strategies.contains("ax_menu_view_show_mixer_retry") {
                strategies.append("ax_menu_view_show_mixer_retry")
            }
            if let mixer = await pollMixerAreaVisible(
                runtime: runtime, timeoutMs: mixerRevealPollTimeoutMs
            ) {
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

    private static func pollMixerAreaVisible(
        runtime: AXLogicProElements.Runtime,
        timeoutMs: Int
    ) async -> AXUIElement? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        repeat {
            if let mixer = AXLogicProElements.getMixerArea(runtime: runtime) {
                return mixer
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return nil
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
        _ trackName: String,
        _ axDescription: String,
        _ runtime: AXLogicProElements.Runtime
    ) async -> AXUIElementSendable?

    static let livePluginWindowOpener: PluginWindowOpener = { targetSlot, trackName, axDescription, runtime in
        await openPluginWindowFromTargetSlot(
            targetSlot.element,
            trackName: trackName,
            axDescription: axDescription,
            runtime: runtime
        )
    }

    static let liveNoOpPluginWindowOpener: PluginWindowOpener = { _, _, _, _ in nil }

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
    ///   6  track verified select (`track_selection_failed`)
    ///   7  inventory complete + occupied at `insert` (`incomplete_inventory`)
    ///   8  plugin window: resolve one candidate, then acquire it through the
    ///      target slot (`window_open_failed` / `window_identity_unresolved`)
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
            return await performVerifiedParamWrite(
                operation: operation,
                track: track,
                insert: insert,
                pluginID: target.pluginID,
                paramKey: target.paramKey,
                paramAlias: target.paramAlias,
                requested: value,
                writeMethod: target.metadata.writeMethod ?? "",
                walkTarget: target.walkTarget,
                responseDisplayUnit: target.responseDisplayUnit,
                runtime: runtime,
                entryLookup: entryLookup,
                pluginWindowOpener: pluginWindowOpener,
                incrementWalkBudget: incrementWalkBudget
            )
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

        let declaredUnits = metadata.acceptedUnits ?? metadata.unit.map { [$0] } ?? []
        let normalizedUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .channelEQ = selector, normalizedUnit?.isEmpty ?? true {
            return .failure(invalidParamsStateC(
                operation,
                "Channel EQ requires a declared 'unit' for \(paramAlias)"
            ))
        }
        let effectiveUnit = normalizedUnit?.isEmpty == false ? normalizedUnit! : metadata.unit
        guard let effectiveUnit,
              declaredUnits.contains(where: { $0.caseInsensitiveCompare(effectiveUnit) == .orderedSame }) else {
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
    /// header at the positional `track` index and requires an exact (trimmed)
    /// match. A mismatch — or an unreadable live name — fails closed with
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
        let expected = expectedTrackName.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let names = scannedNames.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let live = names[track]
        guard let live, live == expected else {
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
            .filter { $0.value == expected }
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

    // MARK: - set_param_verified live write/readback (R6 steps 6-13)

    /// The live AX write/readback round-trip for a `.writeReadback` parameter.
    /// Reached ONLY after steps 1-5 pass, so identity/mode/path/capability are
    /// already validated. Every failure is a terminal HC v2 State C; success is
    /// State A with the full requested/observed payload. No State A is ever
    /// emitted unless an actual `AXValue` write landed AND the read-back value
    /// matched within tolerance.
    private static func performVerifiedParamWrite(
        operation: String,
        track: Int,
        insert: Int,
        pluginID: String,
        paramKey: String,
        paramAlias: String,
        requested: Double,
        writeMethod: String,
        walkTarget: SliderIncrementWalk.Target?,
        responseDisplayUnit: String,
        runtime: AXLogicProElements.Runtime,
        entryLookup: VerifiedPluginCatalog.EntryLookup,
        pluginWindowOpener: PluginWindowOpener,
        incrementWalkBudget: Int
    ) async -> ChannelResult {
        let identity = resolvedIdentity(track: track, insert: insert, pluginID: pluginID)
        guard let axDescription = VerifiedPluginCatalog.paramAXDescription(
            pluginID: pluginID,
            paramKey: paramKey,
            entryLookup: entryLookup
        ) else {
            // A `.writeReadback` parameter must declare its AX matcher; absence is
            // a catalog defect, surfaced honestly rather than guessed around.
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
        let tolerance = VerifiedPluginCatalog.paramTolerance(
            pluginID: pluginID,
            paramKey: paramKey,
            entryLookup: entryLookup
        ) ?? 1.0

        // Step 6 — track verified select. Drive the AX-native selection ladder,
        // then confirm the target header reads back as selected (a write that the
        // AX API accepted vacuously must not be trusted — v3.0.9 lesson).
        guard AXLogicProElements.selectTrackViaAX(at: track, runtime: runtime) else {
            return .error(trackSelectionFailedStateC(operation, identity, "AX track selection write failed for track \(track)"))
        }
        guard await verifiedTrackSelected(track: track, runtime: runtime) else {
            return .error(trackSelectionFailedStateC(
                operation, identity,
                "track \(track) selection could not be verified via AXSelected readback"
            ))
        }

        // Step 7 — inventory complete + slot occupied at `insert` (reuse the
        // drift-safe enumerator; an unreadable chain or an empty target slot
        // means there is no plugin to write into).
        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else {
            return .error(incompleteInventoryStateC(operation, identity, "mixer area was not locatable"))
        }
        let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax)
        guard track < strips.count else {
            return .error(incompleteInventoryStateC(operation, identity, "track index \(track) is not present in the visible mixer"))
        }
        let slots = AXLogicProElements.audioPluginInsertSlots(in: strips[track], runtime: runtime.ax)
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

        // Step 8 — plugin window: reject ambiguity, then acquire through the
        // target slot so the slot is the provenance for the selected editor.
        guard let trackName = AXLogicProElements.trackName(at: track, runtime: runtime) else {
            return .error(windowOpenFailedStateC(operation, identity, "the target track name could not be resolved for window matching"))
        }
        switch AXLogicProElements.pluginWindowMatch(
            forTrackName: trackName,
            matchingSliderDescription: axDescription,
            runtime: runtime
        ) {
        case .ambiguous:
            var diagnostics = pluginWindowAcquisitionDiagnostics(
                trackName: trackName,
                axDescription: axDescription,
                runtime: runtime
            )
            diagnostics["opener_action_attempted"] = false
            return .error(windowIdentityUnresolvedStateC(
                operation,
                identity,
                "more than one plugin-editor window exposes the requested track and parameter identity",
                diagnostics: diagnostics
            ))
        case .none, .unique:
            break
        }
        guard let opened = await pluginWindowOpener(
            AXUIElementSendable(slots[insert].element),
            trackName,
            axDescription,
            runtime
        ) else {
            if case .ambiguous = AXLogicProElements.pluginWindowMatch(
                forTrackName: trackName,
                matchingSliderDescription: axDescription,
                runtime: runtime
            ) {
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

        // Step 9 — slider match by AXDescription (the only stable identifier).
        guard let slider = AXLogicProElements.pluginWindowSlider(
            in: window, axDescription: axDescription, runtime: runtime.ax
        ) else {
            return .error(HonestContract.encodeV2StateC(
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

        guard case let .unique(currentWindow) = AXLogicProElements.pluginWindowMatch(
            forTrackName: trackName,
            matchingSliderDescription: axDescription,
            runtime: runtime
        ), CFEqual(currentWindow, window) else {
            return .error(windowIdentityUnresolvedStateC(
                operation,
                identity,
                "the acquired plugin window was no longer the unique matching window before the write",
                diagnostics: pluginWindowAcquisitionDiagnostics(
                    trackName: trackName,
                    axDescription: axDescription,
                    runtime: runtime
                )
            ))
        }

        // Step 10 — read the before value (for rollback + provenance).
        let before = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax)

        guard case let .unique(currentWindow) = AXLogicProElements.pluginWindowMatch(
            forTrackName: trackName,
            matchingSliderDescription: axDescription,
            runtime: runtime
        ), CFEqual(currentWindow, window) else {
            return .error(windowIdentityUnresolvedStateC(
                operation,
                identity,
                "the acquired plugin window was no longer the unique matching window immediately before the write",
                diagnostics: pluginWindowAcquisitionDiagnostics(
                    trackName: trackName,
                    axDescription: axDescription,
                    runtime: runtime
                )
            ))
        }

        guard targetPluginIdentityIsStable(
            track: track,
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

        guard case let .unique(currentWindow) = AXLogicProElements.pluginWindowMatch(
            forTrackName: trackName,
            matchingSliderDescription: axDescription,
            runtime: runtime
        ), CFEqual(currentWindow, window) else {
            return .error(windowIdentityUnresolvedStateC(
                operation,
                identity,
                "the acquired plugin window was not unique after target-slot revalidation",
                diagnostics: pluginWindowAcquisitionDiagnostics(
                    trackName: trackName,
                    axDescription: axDescription,
                    runtime: runtime
                )
            ))
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

        // Step 11 — choose the declared AX write method. Compressor threshold
        // remains a single AXValue assignment; Channel EQ's measured controls
        // require readback-driven AXValue nudges.
        switch writeMethod {
        case "ax_slider_axvalue":
            guard AXValueExtractors.setSliderValue(slider, requested, runtime: runtime.ax) else {
                return .error(HonestContract.encodeV2StateC(
                    error: .axWriteFailed,
                    extras: [
                        "operation": operation,
                        "target_identity": identity,
                        "param": paramAlias,
                        "requested_normalized": requested,
                        "what_was_attempted": "set AXValue \(requested) on the '\(axDescription)' slider",
                        "what_was_observed": "the AX value write was rejected",
                        "safe_to_retry": true,
                        "write_attempted": true,
                    ]
                ))
            }

            // Step 12 — read the after value (+ value description). A write
            // that cannot be read back is uncertain, not confirmed — fail closed.
            guard let after = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax) else {
                return .error(HonestContract.encodeV2StateC(
                    error: .readbackLostAfterWrite,
                    extras: [
                        "operation": operation,
                        "target_identity": identity,
                        "param": paramAlias,
                        "requested_normalized": requested,
                        "what_was_attempted": "read back the '\(axDescription)' slider value after writing",
                        "what_was_observed": "the slider value could not be read after the write",
                        "safe_to_retry": true,
                        "write_attempted": true,
                    ]
                ))
            }
            let observedDisplay = AXValueExtractors.extractValueDescription(slider, runtime: runtime.ax)

            // Step 13 — tolerance gate.
            if abs(after - requested) <= tolerance {
                return .success(HonestContract.encodeV2StateA(extras: [
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

            // Mismatch — roll back to the before value (re-set + re-read) so a
            // failed verified write does not leave the parameter changed.
            let rollback = rollbackSliderValue(
                slider,
                to: before,
                writeMethod: writeMethod,
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
                    "rollback_outcome": rollback.walkOutcome ?? NSNull(),
                    "rollback_to": before ?? NSNull(),
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
                    AXValueExtractors.setSliderValue(slider, rawTarget, runtime: runtime.ax)
                },
                budget: incrementWalkBudget
            )
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
                return .success(HonestContract.encodeV2StateA(extras: extras))
            case .noProgress(_, _), .budgetExhausted(_, _), .overshot(_, _), .readbackLost(_):
                let rollback = rollbackSliderValue(
                    slider,
                    to: before,
                    writeMethod: writeMethod,
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
                    before: before
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
    }

    private struct SliderRollback {
        let attempted: Bool
        let succeeded: Bool
        let walkOutcome: String?
    }

    /// Roll a slider back to its pre-write value. A slider that required an
    /// increment walk for the forward write gets the same walk for rollback;
    /// using one AXValue set there would only leave it one step closer.
    private static func rollbackSliderValue(
        _ slider: AXUIElement,
        to before: Double?,
        writeMethod: String,
        runtime: AXHelpers.Runtime,
        incrementWalkBudget: Int = ChannelEQBandCatalog.incrementWalkBudget
    ) -> SliderRollback {
        guard let before else { return SliderRollback(attempted: false, succeeded: false, walkOutcome: nil) }
        switch writeMethod {
        case "ax_slider_increment_walk":
            let outcome = SliderIncrementWalk.walk(
                to: .rawValue(before, tolerance: 0),
                read: {
                    AXValueExtractors.extractSliderValue(slider, runtime: runtime).map {
                        SliderIncrementWalk.Reading(value: $0, display: "")
                    }
                },
                nudge: { rawTarget in
                    AXValueExtractors.setSliderValue(slider, rawTarget, runtime: runtime)
                },
                budget: incrementWalkBudget
            )
            if case .arrived(_, _) = outcome {
                return SliderRollback(attempted: true, succeeded: true, walkOutcome: "arrived")
            }
            return SliderRollback(
                attempted: true,
                succeeded: false,
                walkOutcome: incrementWalkOutcomeName(outcome)
            )
        default:
            guard AXValueExtractors.setSliderValue(slider, before, runtime: runtime) else {
                return SliderRollback(attempted: true, succeeded: false, walkOutcome: nil)
            }
            guard let restored = AXValueExtractors.extractSliderValue(slider, runtime: runtime) else {
                return SliderRollback(attempted: true, succeeded: false, walkOutcome: nil)
            }
            return SliderRollback(
                attempted: true,
                succeeded: abs(restored - before) <= 0.5,
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
        before: Double?
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

    private static func windowOpenFailedStateC(
        _ operation: String,
        _ identity: [String: Any],
        _ detail: String,
        diagnostics: [String: Any] = [:]
    ) -> String {
        var extras: [String: Any] = [
            "operation": operation,
            "target_identity": identity,
            "what_was_attempted": "acquire the plugin window before writing",
            "what_was_observed": detail,
            "safe_to_retry": true,
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

    private static func openPluginWindowFromTargetSlot(
        _ targetSlot: AXUIElement,
        trackName: String,
        axDescription: String,
        runtime: AXLogicProElements.Runtime
    ) async -> AXUIElementSendable? {
        switch AXLogicProElements.pluginWindowMatch(
            forTrackName: trackName,
            matchingSliderDescription: axDescription,
            runtime: runtime
        ) {
        case .ambiguous:
            return nil
        case let .unique(window):
            guard demotePluginWindowBeforeAcquisition(window, runtime: runtime) else {
                return nil
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
            _ = pressElement(element, runtime: runtime.ax)
            switch await pollOpenPluginWindow(
                trackName: trackName,
                axDescription: axDescription,
                runtime: runtime,
                timeoutMs: 1_250
            ) {
            case let .unique(window):
                guard pluginWindowIsFront(window, runtime: runtime.ax) else {
                    return nil
                }
                return AXUIElementSendable(window)
            case .ambiguous:
                return nil
            case .none:
                continue
            }
        }
        return nil
    }

    private static func demotePluginWindowBeforeAcquisition(
        _ window: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        let mainCleared = AXHelpers.setAttribute(
            window, kAXMainAttribute as String, false as CFTypeRef, runtime: runtime.ax
        )
        let focusCleared = AXHelpers.setAttribute(
            window, kAXFocusedAttribute as String, false as CFTypeRef, runtime: runtime.ax
        )
        if mainCleared, focusCleared, !pluginWindowIsFront(window, runtime: runtime.ax) {
            return true
        }
        guard let arrangeWindow = AXLogicProElements.mainWindow(runtime: runtime),
              AXHelpers.performAction(arrangeWindow, kAXRaiseAction as String, runtime: runtime.ax) else { return false }
        return !pluginWindowIsFront(window, runtime: runtime.ax)
    }

    private static func pluginWindowIsFront(
        _ window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let isMain: NSNumber? = AXHelpers.getAttribute(
            window, kAXMainAttribute, runtime: runtime
        )
        let isFocused: NSNumber? = AXHelpers.getAttribute(
            window, kAXFocusedAttribute, runtime: runtime
        )
        return isMain?.boolValue == true || isFocused?.boolValue == true
    }

    private static func targetPluginIdentityIsStable(
        track: Int,
        insert: Int,
        pluginID: String,
        originalSlot: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else { return false }
        let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax)
        guard track >= 0, track < strips.count else { return false }
        let slots = AXLogicProElements.audioPluginInsertSlots(in: strips[track], runtime: runtime.ax)
        guard slots.indices.contains(insert), slots[insert].occupied,
              slots[insert].readStatus == .occupiedReadable,
              let observedName = slots[insert].name,
              VerifiedPluginCatalog.pluginID(forObservedName: observedName) == pluginID else {
            return false
        }
        return CFEqual(slots[insert].element, originalSlot)
    }

    private static func rankedPluginSlotOpenControls(
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
            if text.range(of: "open", options: [.caseInsensitive]) != nil || text.contains("열기") {
                return (0, button)
            }
            if text.range(of: "list", options: [.caseInsensitive]) != nil || text.contains("목록") {
                return (1, button)
            }
            if AXLocalePolicy.pluginOpenOrListControl.containsAny(in: text) {
                return (1, button)
            }
            return (2, button)
        }
        .sorted { lhs, rhs in lhs.rank < rhs.rank }
    }

    private static func pollOpenPluginWindow(
        trackName: String,
        axDescription: String,
        runtime: AXLogicProElements.Runtime,
        timeoutMs: Int
    ) async -> AXLogicProElements.PluginWindowMatch {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000.0)
        var lastUniqueWindow: AXUIElement?
        repeat {
            switch AXLogicProElements.pluginWindowMatch(
                forTrackName: trackName,
                matchingSliderDescription: axDescription,
                runtime: runtime
            ) {
            case let .unique(window):
                lastUniqueWindow = window
            case .ambiguous:
                return .ambiguous
            case .none:
                lastUniqueWindow = nil
            }
            guard Date() < deadline else { break }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        if let lastUniqueWindow {
            return .unique(lastUniqueWindow)
        }
        return .none
    }

    /// ADR-001 coordinate ban: open the plugin window from its slot control via
    /// AXPress only. The former element-derived `clickElementCenter` fallback is
    /// removed; `openPluginWindowFromTargetSlot` fails closed (`window_open_failed`)
    /// when no ranked control responds to AXPress, never a coordinate click.
    private static func pressElement(_ element: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        AXHelpers.performAction(element, kAXPressAction as String, runtime: runtime)
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
            return [
                "title": AXHelpers.getTitle(window, runtime: runtime.ax) ?? "",
                "role": AXHelpers.getRole(window, runtime: runtime.ax) ?? "",
                "slider_descriptions": Array(sliderDescriptions.prefix(8)),
            ]
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
        case transientSetupFailure(stage: String, actuated: Bool = false)
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
        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else {
            return .error(HonestContract.encodeV2StateC(
                error: .incompleteInventory,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "what_was_attempted": "read insert inventory before inserting",
                    "what_was_observed": "mixer area was not locatable",
                    "safe_to_retry": true,
                    "write_attempted": false,
                ]
            ))
        }
        let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax)
        guard track < strips.count else {
            return .error(HonestContract.encodeV2StateC(
                error: .incompleteInventory,
                extras: [
                    "operation": operation,
                    "target_identity": identity,
                    "what_was_attempted": "read insert inventory before inserting",
                    "what_was_observed": "track index \(track) is not present in the visible mixer",
                    "safe_to_retry": true,
                    "write_attempted": false,
                ]
            ))
        }
        let slots = AXLogicProElements.audioPluginInsertSlots(in: strips[track], runtime: runtime.ax)
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
        let result = await insertDriver(track, insert, pluginID, searchQuery, runtime)
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
                let rollbackResult = await rollback(track, observedID, observedSlot, runtime)
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

        case let .transientSetupFailure(stage, actuated):
            // A pre-mount UI-setup step did not complete (slot popup, anchor, or
            // exact leaf not ready). No write attempted → retry-able (P2-3), distinct from the
            // permanent insert_not_ax_automatable.
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
                    "safe_to_retry": true,
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
    ///      unreadable strip (pre OR post) is the retry-able `.readbackUnavailable`.
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

        trace["window_raised"] = raiseMixerWindow(runtime: runtime)
        try? await Task.sleep(for: .milliseconds(150))

        let preSnapshot = fullStripInventory(track: track, runtime: runtime)
        trace["pre_inventory_readable"] = (preSnapshot != nil)
        guard let preInventory = preSnapshot else {
            return (.readbackUnavailable, trace)
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

        let anchorVerified = slotPopupMenuIsAnchored(
            rootMenu, toSlot: popupAnchorSlot, runtime: runtime.ax
        )
        trace["slot_popup_anchor_verified"] = anchorVerified
        guard anchorVerified else {
            AXMouseHelper.pressEscape()
            return (.transientSetupFailure(stage: "slot_popup_not_anchored_to_target_slot", actuated: true), trace)
        }

        guard let pluginClick = await clickPluginInAnchoredSlotPopup(
            pluginID: pluginID,
            displayName: searchQuery,
            rootMenu: rootMenu,
            runtime: runtime.ax
        ) else {
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
        focusBetweenAttempts: Bool
    ) async -> (itemFound: Bool, clicked: Bool, enabledRetries: Int) {
        var itemFound = false
        for attempt in 0..<maxEnabledRetries {
            _ = ProcessUtils.Runtime.production.activateLogicPro()
            for candidate in candidates {
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
                itemFound = true

                if let enabled: Bool = AXHelpers.getAttribute(item, kAXEnabledAttribute, runtime: runtime.ax),
                   enabled == false {
                    AXMouseHelper.pressEscape()
                    continue
                }

                // ADR-001 coordinate ban: activate the menu ITEM via AXPress, like
                // the menu-bar OPEN above — the former element-derived
                // clickElementCenter rung is removed. AXPress reports success
                // synchronously; on failure the Escape + retry hygiene below still
                // runs, the mixer-reveal consumer falls back to the non-coordinate
                // cgevent key-7 channel, and the hide-plugin-windows consumer is
                // explicitly best-effort — so no feature is degraded.
                if AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax) {
                    return (true, true, attempt)
                }
                AXMouseHelper.pressEscape()
            }

            if focusBetweenAttempts {
                _ = forceMixerWindowFront()
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
            // Only undo OUR insert. The prefix match above finds whatever sits on top of the stack,
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
        runtime: AXLogicProElements.Runtime
    ) -> AXLogicProElements.PluginInsertSlot? {
        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else { return nil }
        // Strips are addressed by ordinal, so a child whose role could not be read moves every
        // later strip down one and turns a request for track N into an act on physical strip N+1.
        // A downstream readback cannot catch that: it reads the same shifted list. Refuse instead.
        let enumeration = AXLogicProElements.stripEnumeration(in: mixer, runtime: runtime.ax)
        guard enumeration.unreadableChildren == 0 else { return nil }
        let strips = enumeration.strips
        guard track >= 0, track < strips.count else { return nil }
        let slots = AXLogicProElements.audioPluginInsertSlots(in: strips[track], runtime: runtime.ax)
        // #234 — a zero-slot result on this mid-flight re-resolution means the
        // insert section became non-enumerable after the pre-insert snapshot
        // (insert_section_not_enumerable semantics, per slotAddressingFailureDetail).
        // Returning nil routes the caller to a transient setup failure; the static
        // fixture tree can't simulate a mid-operation vanish, so this wording is
        // pinned by the three tested envelope sites rather than a dedicated unit AC.
        guard insert >= 0, insert < slots.count else { return nil }
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
        return verticalBand.contains(slotCenter.y) && horizontalBand.contains(menuPos.x)
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
        runtime: AXHelpers.Runtime
    ) async -> SlotPopupPluginClick? {
        var strategies: [String] = []
        strategies.append("slot_popup_direct_exact_leaf")
        if let item = directExactPopupMenuItem(displayName: displayName, in: rootMenu, runtime: runtime),
           let label = popupMenuItemLabel(item, runtime: runtime),
           await clickPopupPluginLeaf(item, runtime: runtime) {
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
            maxDepth: 5
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
        maxDepth: Int
    ) async -> [String]? {
        guard maxDepth >= 0 else { return nil }

        if let direct = directExactPopupMenuItem(displayName: displayName, in: menu, runtime: runtime),
           let label = popupMenuItemLabel(direct, runtime: runtime),
           await clickPopupPluginLeaf(direct, runtime: runtime) {
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
                maxDepth: maxDepth - 1
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
        runtime: AXHelpers.Runtime
    ) async -> Bool {
        // A disabled entry cannot act, so pressing it produces a silent no-op that the caller then
        // has to distinguish from a real failure downstream. Refuse before touching it.
        guard menuItemEnabledForActuation(item, runtime: runtime) else { return false }
        if let submenu = axChildMenu(of: item, runtime: runtime) {
            guard submenuIsPluginFormatMenu(submenu, runtime: runtime),
                  let leaf = preferredFormatLeafByLabel(in: submenu, runtime: runtime) else {
                return false
            }
            _ = AXHelpers.performAction(leaf, kAXPickAction as String, runtime: runtime)
            return true
        }
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
        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else { return nil }
        // Strips are addressed by ordinal, so a child whose role could not be read moves every
        // later strip down one and turns a request for track N into an act on physical strip N+1.
        // A downstream readback cannot catch that: it reads the same shifted list. Refuse instead.
        let enumeration = AXLogicProElements.stripEnumeration(in: mixer, runtime: runtime.ax)
        guard enumeration.unreadableChildren == 0 else { return nil }
        let strips = enumeration.strips
        guard track < strips.count else { return nil }
        let slots = AXLogicProElements.audioPluginInsertSlots(in: strips[track], runtime: runtime.ax)
        guard !slots.contains(where: { $0.readStatus == .occupiedUnreadable }) else {
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
    static func closeGoToPositionDialog(runtime: AXLogicProElements.Runtime) -> Bool {
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
                AXMouseHelper.pressEscape()
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
