import ApplicationServices
import AppKit
import Foundation

/// Track surface: enumerate/select tracks, mute/solo/arm/rename toggles, track creation via menu, and deletion.
extension AccessibilityChannel {
    // MARK: - Tracks

    static func defaultGetTracks(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        if headers.isEmpty {
            // Empty is a valid steady state (no project open / project picker
            // front). Return an empty list so the StatePoller can overwrite
            // stale cache from a prior session instead of silently holding
            // onto ghost tracks that break rename/mute/arm ops on index 0.
            return encodeResult([TrackState]())
        }
        var tracks: [TrackState] = []
        for (index, header) in headers.enumerated() {
            let track = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
            tracks.append(track)
        }
        return encodeResult(tracks)
    }

    static func defaultGetSelectedTrack(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        for (index, header) in headers.enumerated() {
            if AXValueExtractors.extractSelectedState(header, runtime: runtime.ax) == true {
                let track = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
                return encodeResult(track)
            }
        }
        return .error("No track is currently selected")
    }

    static func defaultSelectTrack(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard AXLogicProElements.findTrackHeader(at: index, runtime: runtime) != nil else {
            // v3.1.0 (T3) — missing track is a hard failure; no retry will
            // help. Keep legacy error-string path for ChannelResult.error so
            // existing callers that look at .isSuccess still see a failure,
            // but encode the structured envelope.
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track at index \(index) not found",
                extras: ["requested": index]
            ))
        }
        // v3.0.3+ — activate Logic so any coord-click fallback can land, then
        // go through the AX-native selection ladder.
        _ = ProcessUtils.Runtime.production.activateLogicPro()
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Failed to select track \(index) via AX or coord click",
                extras: ["requested": index]
            ))
        }

        // v3.1.0 (T3) — verifyTrackSelection already retries 6× at 100ms
        // intervals internally (see TrackSelectionVerification). We surface
        // the outcome as a 3-state Honest Contract response rather than the
        // legacy free-form text. Existing `verified:true/false` JSON path
        // stays valid because the new envelope still contains those keys.
        let verification = await verifyTrackSelection(index: index, runtime: runtime)
        let base: [String: Any] = ["requested": index, "selected": index]
        switch verification {
        case .verified:
            return .success(HonestContract.encodeStateA(extras: base.merging([
                "observed": index
            ]) { _, new in new }))
        case .selectionMetadataUnavailable:
            // Ralph-2 / W1 (guardian iter2) — retry budget exhausted: the
            // read-back metadata never surfaced across 6×100ms attempts.
            // Docs (README, CHANGELOG, API.md, PRD) consistently
            // promise `retry_exhausted` for this case; emitting
            // `readback_unavailable` here would make the enum an orphan.
            return .success(HonestContract.encodeStateB(
                reason: .retryExhausted,
                extras: base.merging(["observed": NSNull()]) { _, new in new }
            ))
        case .mismatch(let selectedIndex):
            // v3.1.0 (Ralph-2 / P2-2) — read-back succeeded but returned a
            // different index. That's the textbook `readback_mismatch` case
            // per docs/API.md (State B taxonomy).
            // `retry_exhausted` stays reserved for
            // `.selectionMetadataUnavailable` — read-back metadata never
            // appeared across the retry budget. Clients switching on
            // `reason` can now pick accept-and-diverge (mismatch) vs.
            // back-off-and-refetch (retry_exhausted) correctly.
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: base.merging([
                    "observed": selectedIndex as Any? ?? NSNull()
                ]) { _, new in new }
            ))
        case .trackDisappeared:
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track at index \(index) disappeared during selection verification",
                extras: base
            ))
        }
    }

    static func defaultSetTrackToggle(
        params: [String: String],
        button buttonName: String,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        let finder: (Int) -> AXUIElement? = switch buttonName {
        case "Mute": { AXLogicProElements.findTrackMuteButton(trackIndex: $0, runtime: runtime) }
        case "Solo": { AXLogicProElements.findTrackSoloButton(trackIndex: $0, runtime: runtime) }
        case "Record": { AXLogicProElements.findTrackArmButton(trackIndex: $0, runtime: runtime) }
        default: { _ in nil }
        }
        guard let button = finder(index) else {
            return .error("Cannot find \(buttonName) button on track \(index)")
        }
        // Press toggles state. To make `enabled: true/false` idempotent (the
        // user-visible contract), read current AXValue — only press when the
        // target state differs. This fixes the class of bug where `arm off`
        // was a silent no-op because MCU release-only was being sent and the
        // AX press was unconditionally toggling regardless of desired state.
        let desired: Bool = (params["enabled"] ?? "true") == "true"
        let current: Bool? = {
            if let raw = AXHelpers.getValue(button, runtime: runtime.ax) as? Int { return raw != 0 }
            if let raw = AXHelpers.getValue(button, runtime: runtime.ax) as? Bool { return raw }
            if let raw = AXHelpers.getValue(button, runtime: runtime.ax) as? NSNumber { return raw.boolValue }
            return nil
        }()
        let baseExtras: [String: Any] = [
            "track": index,
            "button": buttonName,
            "requested": desired,
            "verification_source": "ax_value"
        ]

        if let cur = current, cur == desired {
            return .success(HonestContract.encodeStateA(extras: baseExtras.merging([
                "observed": desired,
                "action": "no-op"
            ]) { _, new in new }))
        }

        func readCurrent() -> Bool? {
            guard let v = AXHelpers.getValue(button, runtime: runtime.ax) else { return nil }
            if let n = v as? NSNumber { return n.boolValue }
            if let b = v as? Bool { return b }
            if let i = v as? Int { return i != 0 }
            if let s = v as? String { return s == "1" || s.lowercased() == "true" }
            return nil
        }

        // #106: Logic 12.x track-header M/S/R checkboxes are `settable=false`
        // and ignore `AXPress`/`AXConfirm`/value writes entirely — only a real
        // mouse click at the control toggles Logic's internal state
        // (live-confirmed: AXPress leaves the value at 0 indefinitely; a HID
        // click flips it to 1 within ~350 ms). The earlier fixed 50 ms
        // read-back was also too fast for Logic to publish the new AX value
        // after a successful click, so even the arm path (whose locator did
        // find the checkbox) reported a false `ax_write_failed` *after*
        // physically toggling the control — a silent malfunction. The write
        // now polls the read-back up to a per-strategy deadline, and the
        // mouse-click last resort brings Logic frontmost first so the synthetic
        // click lands on the (un-occluded) track header.
        func pollMatched(deadlineMs: Int) -> Bool {
            let deadline = Date().addingTimeInterval(Double(deadlineMs) / 1000.0)
            repeat {
                if let after = readCurrent(), after == desired { return true }
                usleep(40_000)
            } while Date() < deadline
            return false
        }

        let strategies: [(name: String, pollMs: Int, action: () -> Void)] = [
            ("press", 160, { _ = AXHelpers.performAction(button, kAXPressAction, runtime: runtime.ax) }),
            ("confirm", 160, { _ = AXHelpers.performAction(button, kAXConfirmAction, runtime: runtime.ax) }),
            ("value-nsnumber", 160, {
                let n: NSNumber = desired ? 1 : 0
                AXHelpers.setAttribute(button, kAXValueAttribute, n as CFTypeRef, runtime: runtime.ax)
            }),
            ("value-cfbool", 160, {
                let b: CFBoolean = desired ? kCFBooleanTrue : kCFBooleanFalse
                AXHelpers.setAttribute(button, kAXValueAttribute, b, runtime: runtime.ax)
            }),
            ("mouse-click", 1_000, {
                _ = ProcessUtils.Runtime.production.activateLogicPro()
                usleep(120_000)
                Self.postMouseClickAt(element: button, runtime: runtime.ax)
            }),
        ]
        for strategy in strategies {
            strategy.action()
            if pollMatched(deadlineMs: strategy.pollMs) {
                return .success(HonestContract.encodeStateA(extras: baseExtras.merging([
                    "observed": desired,
                    "action": strategy.name
                ]) { _, new in new }))
            }
        }
        return .error(HonestContract.encodeStateC(
            error: .axWriteFailed,
            hint: "tried press/confirm/value-nsnumber/value-cfbool/mouse-click; read-back never matched on track \(index) \(buttonName)=\(desired)",
            extras: baseExtras
        ))
    }

    /// Simulate a real user mouse-click at the screen center of an AX element.
    /// Used as a last resort when AXPress / AXValue writes don't propagate to
    /// Logic Pro's internal handlers (observed with Logic 12 rec-arm checkboxes).
    private static func postMouseClickAt(element: AXUIElement, runtime: AXHelpers.Runtime) {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        let pr = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        let sr = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        // H2 (P2-5): fail-closed on non-AXValue / wrong-subtype rather than
        // posting a click at (0,0).
        guard pr == .success, sr == .success,
              let pt = AXHelpers.point(fromRawAttribute: posValue),
              let sz = AXHelpers.size(fromRawAttribute: sizeValue) else { return }
        let center = CGPoint(x: pt.x + sz.width / 2, y: pt.y + sz.height / 2)
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
           let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    static func defaultRenameTrack(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        mouseRuntime: AXMouseHelper.Runtime = .production,
        processRuntime: ProcessUtils.Runtime = .production
    ) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let name = params["name"] else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "track.rename requires 'index' (Int) and 'name' (String)"
            ))
        }
        let truncatedName = String(name.prefix(255))
        let baseExtras: [String: Any] = ["track": index, "requested": truncatedName]

        func observedTrackName() -> String? {
            AXLogicProElements.trackName(at: index, runtime: runtime)
        }

        func verifiedResult(via: String) -> ChannelResult? {
            guard let observed = observedTrackName(), observed == truncatedName else { return nil }
            return .success(HonestContract.encodeStateA(
                extras: baseExtras.merging([
                    "observed": observed,
                    "via": via
                ]) { _, new in new }
            ))
        }

        if let currentName = observedTrackName(), currentName == truncatedName {
            return .success(HonestContract.encodeStateA(
                extras: baseExtras.merging([
                    "observed": currentName,
                    "via": "no-op"
                ]) { _, new in new }
            ))
        }

        guard AXLogicProElements.findTrackHeader(at: index, runtime: runtime) != nil else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track at index \(index) not found",
                extras: baseExtras
            ))
        }

        if let field = AXLogicProElements.findTrackNameField(trackIndex: index, runtime: runtime) {
            AXHelpers.performAction(field, kAXPressAction, runtime: runtime.ax)
            AXHelpers.setAttribute(field, kAXValueAttribute, truncatedName as CFTypeRef, runtime: runtime.ax)
            AXHelpers.performAction(field, kAXConfirmAction, runtime: runtime.ax)
            usleep(50_000)
            if let verified = verifiedResult(via: "ax_set_value") {
                return verified
            }
        }

        _ = ProcessUtils.activateLogicPro(runtime: processRuntime)
        guard selectTrackForRename(index: index, runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Failed to select track \(index) before rename",
                extras: baseExtras
            ))
        }
        raiseTrackWindowForRename(index: index, runtime: runtime)

        let click = clickTrackMenu(
            ["Rename Track", "트랙 이름 변경", "이름 변경"],
            menuName: "트랙",
            englishMenuName: "Track",
            runtime: runtime
        )
        guard click.isSuccess else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track > Rename Track menu item not found / not pressable",
                extras: baseExtras
            ))
        }

        usleep(150_000)
        AXMouseHelper.typeText(truncatedName, runtime: mouseRuntime)
        usleep(50_000)
        AXMouseHelper.pressReturn(runtime: mouseRuntime)
        usleep(150_000)

        if let verified = verifiedResult(via: "track_menu") {
            return verified
        }

        AXMouseHelper.pressEscape(runtime: mouseRuntime)
        usleep(50_000)
        let observed = observedTrackName()
        return .success(HonestContract.encodeStateB(
            reason: observed == nil ? .readbackUnavailable : .readbackMismatch,
            extras: baseExtras.merging([
                "observed": observed as Any? ?? NSNull(),
                "via": "track_menu"
            ]) { _, new in new }
        ))
    }

    private static func raiseTrackWindowForRename(
        index: Int,
        runtime: AXLogicProElements.Runtime = .production
    ) {
        guard let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime),
              let window: AXUIElement = AXHelpers.getAttribute(header, kAXWindowAttribute, runtime: runtime.ax)
        else {
            return
        }
        _ = AXHelpers.performAction(window, kAXRaiseAction, runtime: runtime.ax)
        usleep(50_000)
    }

    private static func selectTrackForRename(
        index: Int,
        runtime: AXLogicProElements.Runtime = .production
    ) -> Bool {
        let initialHeaders = AXLogicProElements.allTrackHeaders(runtime: runtime)
        guard index >= 0 && index < initialHeaders.count else { return false }
        if AXValueExtractors.extractSelectedState(initialHeaders[index], runtime: runtime.ax) == true {
            return true
        }

        guard AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime) else {
            return false
        }

        var sawSelectionMetadata = false
        for attempt in 0..<6 {
            let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
            guard index < headers.count else { return false }

            let selectionStates = headers.map { AXValueExtractors.extractSelectedState($0, runtime: runtime.ax) }
            if selectionStates.contains(where: { $0 != nil }) {
                sawSelectionMetadata = true
            }
            if selectionStates[index] == true {
                return true
            }
            if attempt < 5 {
                usleep(100_000)
            }
        }
        return !sawSelectionMetadata
    }

    enum TrackSelectionVerification {
        case verified
        case selectionMetadataUnavailable
        case mismatch(selectedIndex: Int?)
        case trackDisappeared
    }

    static func verifyTrackSelection(
        index: Int,
        runtime: AXLogicProElements.Runtime
    ) async -> TrackSelectionVerification {
        var sawSelectionMetadata = false

        for attempt in 0..<6 {
            let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
            guard index >= 0 && index < headers.count else {
                return .trackDisappeared
            }

            let selectionStates = headers.enumerated().map { offset, header in
                (offset, AXValueExtractors.extractSelectedState(header, runtime: runtime.ax))
            }
            if selectionStates.contains(where: { $0.1 != nil }) {
                sawSelectionMetadata = true
            }
            if selectionStates[index].1 == true {
                return .verified
            }

            if attempt < 5 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        guard sawSelectionMetadata else {
            return .selectionMetadataUnavailable
        }

        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        let selectedIndex = headers.enumerated().first {
            AXValueExtractors.extractSelectedState($0.element, runtime: runtime.ax) == true
        }?.offset
        return .mismatch(selectedIndex: selectedIndex)
    }

    // MARK: - Track Creation via Menu

    static func createTrackViaMenu(
        korean: String,
        english: String,
        expectedTrackType: TrackType,
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        guard AXLogicProElements.mainWindow(runtime: runtime) != nil else {
            return .error("No document open for track creation")
        }

        let beforeTracks = observedTrackStates(runtime: runtime)
        let beforeCount = beforeTracks.count

        // Try Korean locale first
        let result = clickTrackMenu(korean, menuName: "트랙", englishMenuName: "Track", runtime: runtime)
        let menuClickedTitle: String
        if result.isSuccess {
            menuClickedTitle = korean
        } else {
            // Fallback: English locale with English item title
            let fallback = clickTrackMenu(english, menuName: "Track", englishMenuName: "Track", runtime: runtime)
            guard fallback.isSuccess else { return fallback }
            menuClickedTitle = english
        }

        // Logic 12.0.1: menu click may show "새로운 트랙 생성" dialog (sometimes invisible
        // to AX tree). Strategy: poll track count briefly. If track was already
        // created without a dialog, do NOT send Return (avoids sending Enter to
        // unrelated focused targets). If still unchanged after 400ms, assume
        // dialog is up and send Return; verify after.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let midCount = AXLogicProElements.allTrackHeaders(runtime: runtime).count
        let dialogConfirmationAttempted = midCount == beforeCount
        if dialogConfirmationAttempted {
            // Track not created yet — assume New Track dialog is awaiting confirmation
            sendReturnKey()
        }

        return await verifyTrackCreation(
            title: menuClickedTitle,
            expectedTrackType: expectedTrackType,
            beforeTracks: beforeTracks,
            dialogConfirmationAttempted: dialogConfirmationAttempted,
            runtime: runtime
        )
    }

    /// Send Return key via CGEvent — used to auto-confirm Logic 12's
    /// "New Track" dialog (which is sometimes opaque to AX tree).
    private static func sendReturnKey() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let returnVK: CGKeyCode = 0x24
        if let down = CGEvent(keyboardEventSource: src, virtualKey: returnVK, keyDown: true) {
            down.post(tap: .cghidEventTap)
        }
        usleep(20_000)
        if let up = CGEvent(keyboardEventSource: src, virtualKey: returnVK, keyDown: false) {
            up.post(tap: .cghidEventTap)
        }
    }

    private static func verifyTrackCreation(
        title: String,
        expectedTrackType: TrackType,
        beforeTracks: [TrackState],
        dialogConfirmationAttempted: Bool,
        runtime: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        let beforeCount = beforeTracks.count
        var lastObservedCount = beforeCount

        let extras: [String: Any] = [
            "menu_clicked": title,
            "track_count_before": beforeCount,
            "requested_delta": 1,
            "dialog_confirmation_attempted": dialogConfirmationAttempted,
            "observed_track_type": expectedTrackType.rawValue,
            "track_type_verification_source": "menu_clicked",
            "verification_source": "track_count_delta"
        ]

        for attempt in 0..<4 {
            let currentTracks = observedTrackStates(runtime: runtime)
            let currentCount = currentTracks.count
            lastObservedCount = currentCount
            if currentCount > beforeCount {
                var merged = extras.merging([
                    "track_count_after": currentCount,
                    "observed_delta": currentCount - beforeCount
                ]) { _, new in new }
                if let observedTrack = observedCreatedTrack(before: beforeTracks, after: currentTracks) {
                    merged["observed_track_index"] = observedTrack.id
                    merged["observed_track_name"] = observedTrack.name
                    merged["observed_track_type_inferred"] = observedTrack.type.rawValue
                }
                return .success(HonestContract.encodeStateA(extras: merged))
            }

            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        var merged = extras.merging([
            "track_count_after": lastObservedCount,
            "observed_delta": lastObservedCount - beforeCount
        ]) { _, new in new }
        let dialogPresent = AXLogicProElements.dialogPresent(runtime: runtime)
        merged["dialog_present"] = dialogPresent
        if dialogPresent {
            merged["waiting_for_user"] = true
            return .success(HonestContract.encodeStateB(
                reason: .retryExhausted,
                extras: merged
            ))
        }
        return .error(HonestContract.encodeStateC(
            error: .axWriteFailed,
            hint: "track count did not increase after '\(title)' click within 4×1s budget",
            extras: merged
        ))
    }

    private static func observedTrackStates(
        runtime: AXLogicProElements.Runtime = .production
    ) -> [TrackState] {
        AXLogicProElements.allTrackHeaders(runtime: runtime).enumerated().map { index, header in
            AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
        }
    }

    private static func observedCreatedTrack(
        before: [TrackState],
        after: [TrackState]
    ) -> TrackState? {
        if let selected = after.first(where: { $0.isSelected }) {
            return selected
        }
        guard after.count == before.count + 1 else {
            return after.last
        }
        var prefix = 0
        while prefix < before.count,
              trackCreationSignature(before[prefix]) == trackCreationSignature(after[prefix]) {
            prefix += 1
        }
        if prefix < after.count {
            return after[prefix]
        }
        return after.last
    }

    private static func trackCreationSignature(_ track: TrackState) -> String {
        [
            track.name,
            track.type.rawValue,
            String(track.isMuted),
            String(track.isSoloed),
            String(track.isArmed),
            track.color ?? ""
        ].joined(separator: "|")
    }

    /// Delete the currently-selected track via the `트랙 → 트랙 삭제` menu and
    /// verify the track count decremented by 1 within a 4×1s budget. Returns
    /// State A on confirmed delta, State B `retry_exhausted` if AX poll never
    /// catches the decrement, State C if the menu click itself fails.
    static func defaultDeleteTrack(
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        let beforeCount = AXLogicProElements.allTrackHeaders(runtime: runtime).count
        let click = clickTrackMenu("트랙 삭제", menuName: "트랙", englishMenuName: "Track", runtime: runtime)
        guard click.isSuccess else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track > 트랙 삭제 menu item not found / not pressable",
                extras: ["track_count_before": beforeCount]
            ))
        }

        let extras: [String: Any] = [
            "menu_clicked": "트랙 삭제",
            "track_count_before": beforeCount,
            "requested_delta": -1
        ]

        var lastObservedCount = beforeCount
        for attempt in 0..<4 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let currentCount = AXLogicProElements.allTrackHeaders(runtime: runtime).count
            lastObservedCount = currentCount
            if currentCount < beforeCount {
                let merged = extras.merging([
                    "track_count_after": currentCount,
                    "observed_delta": currentCount - beforeCount
                ]) { _, new in new }
                return .success(HonestContract.encodeStateA(extras: merged))
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }

        let merged = extras.merging([
            "track_count_after": lastObservedCount,
            "observed_delta": lastObservedCount - beforeCount
        ]) { _, new in new }
        return .success(HonestContract.encodeStateB(
            reason: .retryExhausted,
            extras: merged
        ))
    }

    private static func clickTrackMenu(
        _ menuItemTitle: String,
        menuName: String = "트랙",
        englishMenuName: String = "Track",
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        clickTrackMenu([menuItemTitle], menuName: menuName, englishMenuName: englishMenuName, runtime: runtime)
    }

    private static func clickTrackMenu(
        _ menuItemTitles: [String],
        menuName: String = "트랙",
        englishMenuName: String = "Track",
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        for menuTitle in [menuName, englishMenuName] {
            for itemTitle in menuItemTitles {
                guard let item = AXLogicProElements.menuItem(path: [menuTitle, itemTitle], runtime: runtime) else {
                    continue
                }
                guard AXHelpers.performAction(item, kAXPressAction, runtime: runtime.ax) else {
                    return .error("Failed to click menu item: \(itemTitle)")
                }
                return .success("{\"menu_clicked\":\"\(itemTitle)\"}")
            }
        }
        let joinedTitles = menuItemTitles.joined(separator: " | ")
        return .error("Cannot find menu item: \(menuName) > \(joinedTitles)")
    }

}
