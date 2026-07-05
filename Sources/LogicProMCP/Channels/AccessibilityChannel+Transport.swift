import ApplicationServices
import AppKit
import Foundation

/// Transport surface: play/stop/record, tempo, cycle range, playhead goto, zoom, and control-bar checkboxes (metronome/count-in).
extension AccessibilityChannel {
    // MARK: - Transport

    static func defaultGetTransportState(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        guard let transport = AXLogicProElements.getControlBar(runtime: runtime)
                ?? AXLogicProElements.getTransportBar(runtime: runtime) else {
            return .error("Cannot locate transport bar")
        }
        var state = AXValueExtractors.extractTransportState(from: transport, runtime: runtime.ax)
        if let isPlaying = AXLogicProElements.readControlBarCheckboxValue(
            named: "재생", englishName: "Play", runtime: runtime
        ) {
            state.isPlaying = isPlaying
        }
        if let isRecording = AXLogicProElements.readControlBarCheckboxValue(
            named: "녹음", englishName: "Record", runtime: runtime
        ) {
            state.isRecording = isRecording
        }
        if let isCycleEnabled = AXLogicProElements.readControlBarCheckboxValue(
            named: "사이클", englishName: "Cycle", runtime: runtime
        ) {
            state.isCycleEnabled = isCycleEnabled
        }
        if let isMetronomeEnabled = AXLogicProElements.readControlBarCheckboxValue(
            named: "메트로놈 클릭", englishName: "Metronome", runtime: runtime
        ) {
            state.isMetronomeEnabled = isMetronomeEnabled
        }
        return encodeResult(state)
    }

    static func defaultToggleTransportButton(
        named name: String,
        runtime: AXLogicProElements.Runtime = .production,
        mouseRuntime: AXMouseHelper.Runtime = .production
    ) -> ChannelResult {
        // Try the Logic Pro 12 control-bar checkbox first (Korean + English UI).
        // Falls back to legacy toolbar button search.
        let controlBarMapping: [String: (korean: String, english: String, desired: Bool?)] = [
            "Cycle":      ("사이클",        "Cycle",     nil),
            "Metronome":  ("메트로놈 클릭",  "Metronome", nil),
            "CountIn":    ("카운트 인",     "Count-in",  nil),
            "Play":       ("재생",          "Play",      true),
            "Stop":       ("재생",          "Play",      false),
            "Record":     ("녹음",          "Record",    true),
        ]
        // Stop semantics: clear Record too (else recording continues even after Play=false).
        // Avoids regression where stop() during recording leaves track in armed-record loop.
        if name == "Stop" {
            _ = AccessibilityChannel.setControlBarCheckboxValue(
                korean: "녹음",
                english: "Record",
                desired: false,
                runtime: runtime,
                mouseRuntime: mouseRuntime
            )
        }
        if let mapping = controlBarMapping[name] {
            if let desired = mapping.desired {
                // Conditional toggle: only click if current != desired
                if let result = AccessibilityChannel.setControlBarCheckboxValue(
                    korean: mapping.korean,
                    english: mapping.english,
                    desired: desired,
                    runtime: runtime,
                    mouseRuntime: mouseRuntime
                ) {
                    return result
                }
            } else {
                // Unconditional toggle
                if let result = AccessibilityChannel.clickControlBarCheckbox(
                    korean: mapping.korean,
                    english: mapping.english,
                    runtime: runtime,
                    mouseRuntime: mouseRuntime
                ) {
                    return result
                }
            }
        }
        // Legacy fallback: search by role=Button with title/description.
        guard let button = AXLogicProElements.findTransportButton(named: name, runtime: runtime) else {
            var extras = transportLookupDiagnostics(named: name, runtime: runtime)
            extras["button"] = name
            extras["recovery_hint"] =
                "Bring Logic's main arrange window frontmost and dismiss any plugin, chooser, or modal window covering the transport controls."
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "transport button '\(name)' not located in the visible Logic transport UI",
                extras: extras
            ))
        }
        guard AXHelpers.performAction(button, kAXPressAction, runtime: runtime.ax) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "AXPress failed on transport button '\(name)'",
                extras: ["button": name]
            ))
        }
        return .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: ["button": name, "via": "legacy-axpress"]
        ))
    }

    private static func transportLookupDiagnostics(
        named name: String,
        runtime: AXLogicProElements.Runtime
    ) -> [String: Any] {
        let mainWindow = AXLogicProElements.mainWindow(runtime: runtime)
        let windowTitle = mainWindow.flatMap { AXHelpers.getTitle($0, runtime: runtime.ax) } ?? ""
        let controlBar = AXLogicProElements.getControlBar(runtime: runtime)
        let transportBar = AXLogicProElements.getTransportBar(runtime: runtime)
        return [
            "requested_button": name,
            "window_title": windowTitle,
            "control_bar_present": controlBar != nil,
            "transport_bar_present": transportBar != nil,
            "control_bar_checkboxes": controlBar.map {
                transportLandmarkLabels(root: $0, role: kAXCheckBoxRole, runtime: runtime)
            } ?? [],
            "transport_buttons": transportBar.map {
                transportLandmarkLabels(root: $0, role: kAXButtonRole, runtime: runtime)
            } ?? []
        ]
    }

    private static func transportLandmarkLabels(
        root: AXUIElement,
        role: String,
        runtime: AXLogicProElements.Runtime
    ) -> [String] {
        let elements = AXHelpers.findAllDescendants(
            of: root,
            role: role,
            maxDepth: 4,
            runtime: runtime.ax
        )
        var seen = Set<String>()
        var labels: [String] = []
        for element in elements {
            let candidates = [
                AXHelpers.getTitle(element, runtime: runtime.ax),
                AXHelpers.getDescription(element, runtime: runtime.ax),
                AXHelpers.getIdentifier(element, runtime: runtime.ax)
            ]
            for candidate in candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                guard !candidate.isEmpty, seen.insert(candidate).inserted else { continue }
                labels.append(candidate)
                break
            }
            if labels.count >= 12 { break }
        }
        return labels
    }

    static func defaultSetTempo(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        mouseRuntime: AXMouseHelper.Runtime = .production,
        runFallback: @escaping @Sendable (String) -> Bool = runTempoFallbackScript
    ) -> ChannelResult {
        guard let tempoStr = params["bpm"] ?? params["tempo"], let tempoValue = Double(tempoStr) else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "transport.set_tempo requires 'tempo' or 'bpm' (Double)"
            ))
        }
        guard tempoValue >= 5.0 && tempoValue <= 990.0 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "tempo \(tempoStr) out of slider range (5.0 .. 990.0)",
                extras: ["requested": tempoValue]
            ))
        }

        let baseExtras: [String: Any] = ["requested": tempoValue]

        if let slider = AXLogicProElements.findTempoSlider(runtime: runtime) {
            guard let position = AXHelpers.getPosition(slider, runtime: runtime.ax),
                  let size = AXHelpers.getSize(slider, runtime: runtime.ax) else {
                AXHelpers.setAttribute(slider, kAXValueAttribute, tempoStr as CFTypeRef, runtime: runtime.ax)
                _ = AXHelpers.performAction(slider, kAXConfirmAction, runtime: runtime.ax)
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: baseExtras.merging(["via": "slider-direct"]) { _, new in new }
                ))
            }
            let center = CGPoint(
                x: position.x + size.width / 2,
                y: position.y + size.height / 2
            )
            AXMouseHelper.doubleClick(at: center, runtime: mouseRuntime)
            Thread.sleep(forTimeInterval: 0.12)
            AXMouseHelper.typeNumericString(tempoStr, runtime: mouseRuntime)
            Thread.sleep(forTimeInterval: 0.05)
            AXMouseHelper.pressReturn(runtime: mouseRuntime)
            Thread.sleep(forTimeInterval: 0.15)

            if let finalValue = AXHelpers.getValue(slider, runtime: runtime.ax) as? Double,
               abs(finalValue - tempoValue) < 1.0 {
                return .success(HonestContract.encodeStateA(
                    extras: baseExtras.merging(["observed": finalValue, "via": "slider"]) { _, new in new }
                ))
            }

            AXMouseHelper.pressEscape(runtime: mouseRuntime)
            Thread.sleep(forTimeInterval: 0.05)
            let current = (AXHelpers.getValue(slider, runtime: runtime.ax) as? Double) ?? 0
            let delta = tempoValue - current
            let stepsInt = Int((abs(delta) / 10.0).rounded())
            if stepsInt > 0 {
                let action = delta > 0 ? kAXIncrementAction : kAXDecrementAction
                for _ in 0..<stepsInt {
                    _ = AXHelpers.performAction(slider, action, runtime: runtime.ax)
                }
            }
            if let afterIncrement = AXHelpers.getValue(slider, runtime: runtime.ax) as? Double {
                // Honest Contract (#189): the slider-increment fallback steps in
                // 10-BPM granularity, so it only reaches the requested tempo by
                // coincidence. Report success ONLY when the observed value matches
                // the request within tolerance; ANY readback mismatch fails closed
                // with State C — a write path must never report success when the
                // observed tempo differs from the requested tempo.
                if abs(afterIncrement - tempoValue) < 1.0 {
                    return .success(HonestContract.encodeStateA(
                        extras: baseExtras.merging([
                            "observed": afterIncrement,
                            "via": "slider-increment"
                        ]) { _, new in new }
                    ))
                }
                return .error(HonestContract.encodeStateC(
                    error: .readbackMismatch,
                    hint: "tempo write fell back to a 10-BPM increment step that did not land on the requested value (typed entry didn't commit); the slider cannot represent this exact tempo via increment",
                    extras: baseExtras.merging([
                        "observed": afterIncrement,
                        "via": "slider-increment",
                        "write_attempted": true,
                        "safe_to_retry": true
                    ]) { _, new in new }
                ))
            }
        }

        let tempoLandmarks = tempoControlLandmarks(runtime: runtime)
        let missingHint = tempoControlMissingHint(landmarks: tempoLandmarks)
        let missingExtras = baseExtras.merging(tempoLandmarks) { _, new in new }

        if shouldAttemptTempoFallback(landmarks: tempoLandmarks) && runFallback(tempoStr) {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "tempo fallback executed but no tempo readback was available",
                extras: missingExtras.merging(["via": "keyboard-fallback"]) { _, new in new }
            ))
        }
        return .error(HonestContract.encodeStateC(
            error: .elementNotFound,
            hint: missingHint,
            extras: missingExtras
        ))
    }

    private static func tempoControlLandmarks(
        runtime: AXLogicProElements.Runtime
    ) -> [String: Any] {
        let window = AXLogicProElements.mainWindow(runtime: runtime)
        let controlBar = AXLogicProElements.getControlBar(runtime: runtime)
        let transportBar = AXLogicProElements.getTransportBar(runtime: runtime)

        return [
            "main_window_title": (window.flatMap { AXHelpers.getTitle($0, runtime: runtime.ax) } ?? "") as Any,
            "dialog_present": AXLogicProElements.dialogPresent(runtime: runtime),
            "control_bar_found": controlBar != nil,
            "transport_bar_found": transportBar != nil,
            "track_header_count": AXLogicProElements.allTrackHeaders(runtime: runtime).count,
            "control_bar_slider_descriptions": tempoLandmarkStrings(
                in: controlBar,
                role: kAXSliderRole,
                runtime: runtime.ax
            ),
            "transport_slider_descriptions": tempoLandmarkStrings(
                in: transportBar,
                role: kAXSliderRole,
                runtime: runtime.ax
            ),
            "control_bar_checkbox_labels": tempoLandmarkCheckboxLabels(
                in: controlBar,
                runtime: runtime.ax
            ),
        ]
    }

    private static func tempoControlMissingHint(landmarks: [String: Any]) -> String {
        let dialogPresent = landmarks["dialog_present"] as? Bool ?? false
        let trackHeaderCount = landmarks["track_header_count"] as? Int ?? 0
        let controlBarFound = landmarks["control_bar_found"] as? Bool ?? false
        let transportBarFound = landmarks["transport_bar_found"] as? Bool ?? false

        if dialogPresent {
            return "tempo slider not located while a Logic dialog is present. Dismiss the dialog, clear the Create New Track prompt if visible, and retry."
        }
        if trackHeaderCount == 0 {
            return "tempo slider not located: no track headers are visible yet. Clear the Create New Track dialog or create a software instrument track first."
        }
        if !controlBarFound && !transportBarFound {
            return "tempo slider not located: Logic's Control Bar and transport UI were both absent from the AX tree. Ensure the project window is frontmost and fully loaded, then retry."
        }
        if !controlBarFound {
            return "tempo slider not located in Logic's Control Bar. Ensure the project window is frontmost and the Control Bar is visible, then retry."
        }
        return "tempo slider not located in Logic control bar; ensure Logic Pro is frontmost with an open project"
    }

    private static func shouldAttemptTempoFallback(landmarks: [String: Any]) -> Bool {
        let dialogPresent = landmarks["dialog_present"] as? Bool ?? false
        let trackHeaderCount = landmarks["track_header_count"] as? Int ?? 0
        let controlBarFound = landmarks["control_bar_found"] as? Bool ?? false
        let transportBarFound = landmarks["transport_bar_found"] as? Bool ?? false

        return !dialogPresent && trackHeaderCount > 0 && (controlBarFound || transportBarFound)
    }

    private static func tempoLandmarkStrings(
        in root: AXUIElement?,
        role: String,
        runtime: AXHelpers.Runtime
    ) -> [String] {
        guard let root else { return [] }
        let descendants = AXHelpers.findAllDescendants(
            of: root,
            role: role,
            maxDepth: 6,
            runtime: runtime
        )
        var values: [String] = []
        for element in descendants {
            let label = [
                AXHelpers.getDescription(element, runtime: runtime),
                AXHelpers.getTitle(element, runtime: runtime),
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            if let label, !values.contains(label) {
                values.append(label)
            }
        }
        return values
    }

    private static func tempoLandmarkCheckboxLabels(
        in root: AXUIElement?,
        runtime: AXHelpers.Runtime
    ) -> [String] {
        tempoLandmarkStrings(in: root, role: kAXCheckBoxRole, runtime: runtime)
    }

    static func runTempoFallbackScript(tempo: String) -> Bool {
        let script = """
        tell application "System Events"
            tell process "Logic Pro"
                set frontmost to true
                delay 0.2
                -- Open Tempo & Project Settings (⌥+⌘+T)
                key code 17 using {command down, option down}
                delay 0.4
                -- The tempo input field should be focused; type new value
                keystroke "\(tempo)"
                delay 0.1
                key code 36
                delay 0.2
                key code 53
            end tell
        end tell
        """
        // 5s hard cap — script intent is < 1.5s, anything longer means Logic
        // is unresponsive (modal dialog stuck, focus lost, etc.).
        guard case let .completed(output) = BoundedProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 5.0,
            outputLimitBytes: 4 * 1024
        ) else {
            return false
        }
        return output.exitCode == 0
    }

    static func defaultSetCycleRange(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        runFallback: @escaping @Sendable (String, String) -> Bool = runCycleRangeFallbackScript
    ) -> ChannelResult {
        guard let startStr = params["start"], let endStr = params["end"] else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "set_cycle_range requires explicit 'start' and 'end'",
                extras: ["operation": "transport.set_cycle_range"]
            ))
        }
        // Normalise input: accept plain bar int ("5") or full bar/beat string ("5.1.1.1").
        let startPos = startStr.contains(".") ? startStr : "\(startStr).1.1.1"
        let endPos = endStr.contains(".") ? endStr : "\(endStr).1.1.1"
        let requested = cycleRangeRequested(start: startPos, end: endPos)

        // AX path: locate cycle locator text fields in the transport bar.
        // Logic Pro exposes two text fields whose descriptions contain
        // "cycle" + "start"/"end" (both ko/en locales covered).
        if let transport = AXLogicProElements.getTransportBar(runtime: runtime) {
            let texts = AXHelpers.findAllDescendants(
                of: transport,
                role: kAXTextFieldRole,
                maxDepth: 6,
                runtime: runtime.ax
            )
            var startField: AXUIElement?
            var endField: AXUIElement?
            for field in texts {
                let desc = (AXHelpers.getDescription(field, runtime: runtime.ax) ?? "").lowercased()
                // Match on description fragments present in both Korean and English Logic builds.
                if startField == nil && (desc.contains("cycle") || desc.contains("사이클"))
                    && (desc.contains("start") || desc.contains("시작") || desc.contains("in") || desc.contains("left")) {
                    startField = field
                }
                if endField == nil && (desc.contains("cycle") || desc.contains("사이클"))
                    && (desc.contains("end") || desc.contains("끝") || desc.contains("out") || desc.contains("right")) {
                    endField = field
                }
            }
            if let s = startField, let e = endField {
                let sSet = AXHelpers.setAttribute(
                    s, kAXValueAttribute, startPos as CFTypeRef, runtime: runtime.ax
                )
                AXHelpers.performAction(s, kAXConfirmAction, runtime: runtime.ax)
                let eSet = AXHelpers.setAttribute(
                    e, kAXValueAttribute, endPos as CFTypeRef, runtime: runtime.ax
                )
                AXHelpers.performAction(e, kAXConfirmAction, runtime: runtime.ax)

                // v3.1.0 (T5) — read back the two cycle locator fields and
                // build a 3-state Honest Contract envelope. Schema now
                // matches the osascript fallback: both paths emit
                // `{start, end, via, verified, requested, observed}`.
                let extras: [String: Any] = [
                    "operation": "transport.set_cycle_range",
                    "start": startPos,
                    "end": endPos,
                    "via": "ax",
                    "method": "ax_cycle_locator_text_fields",
                    "requested": requested
                ]
                if !sSet || !eSet {
                    // v3.1.0 (Ralph-2 / M-1) — State C must route through
                    // `.error(...)` so the MCP envelope's isError:true is
                    // set. The prior `.success(...)` wrapping produced an
                    // inconsistent signal vs. `track.select`'s State C.
                    return .error(HonestContract.encodeStateC(
                        error: .axWriteFailed,
                        hint: "setAttribute on cycle locator failed",
                        extras: extras
                    ))
                }
                let startReadBack: String? = AXHelpers.getAttribute(
                    s, kAXValueAttribute, runtime: runtime.ax
                )
                let endReadBack: String? = AXHelpers.getAttribute(
                    e, kAXValueAttribute, runtime: runtime.ax
                )
                let observed: [String: Any] = [
                    "start": startReadBack as Any? ?? NSNull(),
                    "end": endReadBack as Any? ?? NSNull()
                ]
                var merged = extras
                merged["observed"] = observed
                if startReadBack == nil || endReadBack == nil {
                    return .success(HonestContract.encodeStateB(
                        reason: .readbackUnavailable, extras: merged
                    ))
                }
                if startReadBack == startPos && endReadBack == endPos {
                    return .success(HonestContract.encodeStateA(extras: merged))
                }
                return .success(HonestContract.encodeStateB(
                    reason: .readbackMismatch, extras: merged
                ))
            }

            let transportLandmarks = cycleRangeLandmarks(
                runtime: runtime,
                transport: transport,
                textFields: texts
            )
            if runFallback(startPos, endPos) {
                return .error(HonestContract.encodeStateC(
                    error: .readbackUnavailable,
                    hint: "set_cycle_range could drive Logic's 'Set Locators' dialog fallback, but this build exposes no deterministic numeric locator readback; refusing to claim success without observed start/end locators",
                    extras: [
                        "operation": "transport.set_cycle_range",
                        "method": "osascript_set_locators_dialog",
                        "attempted_methods": ["ax_cycle_locator_text_fields", "osascript_set_locators_dialog"],
                        "requested": requested,
                        "observed": cycleRangeObserved(start: nil, end: nil),
                        "write_attempted": true,
                        "safe_to_retry": false,
                        "what_was_attempted": "locate numeric cycle locator AX text fields, then drive Logic's 'Set Locators' dialog as a fallback",
                        "what_was_observed": "Logic exposes no cycle start/end AX text fields in the transport bar, so the fallback write could not be independently read back",
                        "scanned_landmarks": transportLandmarks,
                        "recovery_hint": "Set the cycle range manually in Logic or select a region and use Logic's 'Set Locators by Selection' command before bounce/export."
                    ]
                ))
            }

            return .error(HonestContract.encodeStateC(
                error: .notImplemented,
                hint: "set_cycle_range could not find numeric cycle locator fields and could not complete the 'Set Locators' dialog fallback. This Logic build/session does not expose a verifiable numeric cycle locator automation path.",
                extras: [
                    "operation": "transport.set_cycle_range",
                    "method": "ax_cycle_locator_text_fields",
                    "attempted_methods": ["ax_cycle_locator_text_fields", "osascript_set_locators_dialog"],
                    "requested": requested,
                    "observed": cycleRangeObserved(start: nil, end: nil),
                    "write_attempted": false,
                    "safe_to_retry": false,
                    "what_was_attempted": "locate numeric cycle locator AX text fields, then open Logic's 'Set Locators' dialog as a fallback",
                    "what_was_observed": "Logic exposes no cycle start/end AX text fields in the transport bar and the fallback dialog could not be completed",
                    "scanned_landmarks": transportLandmarks,
                    "recovery_hint": "Set the cycle range manually in Logic or select a region and use Logic's 'Set Locators by Selection' command before bounce/export."
                ]
            ))
        }

        let missingTransportLandmarks = cycleRangeLandmarks(runtime: runtime)
        if runFallback(startPos, endPos) {
            // Fail closed when the fallback may have written but we still have
            // no observed numeric locator readback surface.
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "set_cycle_range could drive Logic's 'Set Locators' dialog fallback, but no transport bar was locatable for independent numeric locator readback",
                extras: [
                    "operation": "transport.set_cycle_range",
                    "method": "osascript_set_locators_dialog",
                    "attempted_methods": ["ax_cycle_locator_text_fields", "osascript_set_locators_dialog"],
                    "requested": requested,
                    "observed": cycleRangeObserved(start: nil, end: nil),
                    "write_attempted": true,
                    "safe_to_retry": false,
                    "what_was_attempted": "find the transport bar, then drive Logic's 'Set Locators' dialog as a fallback",
                    "what_was_observed": "no transport bar was locatable for AX readback, so the fallback write could not be independently verified",
                    "scanned_landmarks": missingTransportLandmarks,
                    "recovery_hint": "Bring the arrange window to the front and set the cycle range manually before bounce/export."
                ]
            ))
        }
        return .error(HonestContract.encodeStateC(
            error: .notImplemented,
            hint: "set_cycle_range could not locate Logic's transport bar or a verifiable numeric cycle locator surface. The MCP server cannot currently set numeric cycle locators programmatically in this UI state.",
            extras: [
                "operation": "transport.set_cycle_range",
                "method": "ax_cycle_locator_text_fields",
                "attempted_methods": ["ax_cycle_locator_text_fields", "osascript_set_locators_dialog"],
                "requested": requested,
                "observed": cycleRangeObserved(start: nil, end: nil),
                "write_attempted": false,
                "safe_to_retry": false,
                "what_was_attempted": "find Logic's transport bar and numeric cycle locator fields",
                "what_was_observed": "no transport bar was locatable and the fallback dialog path could not be completed",
                "scanned_landmarks": missingTransportLandmarks,
                "recovery_hint": "Bring the arrange window to the front and set the cycle range manually before bounce/export."
            ]
        ))
    }

    private static func cycleRangeRequested(start: String, end: String) -> [String: Any] {
        ["start": start, "end": end]
    }

    private static func cycleRangeObserved(start: String?, end: String?) -> [String: Any] {
        ["start": start ?? NSNull(), "end": end ?? NSNull()]
    }

    private static func cycleRangeLandmarks(
        runtime: AXLogicProElements.Runtime,
        transport: AXUIElement? = nil,
        textFields: [AXUIElement]? = nil
    ) -> [String: Any] {
        let window = AXLogicProElements.mainWindow(runtime: runtime)
        let resolvedTransport = transport ?? AXLogicProElements.getTransportBar(runtime: runtime)
        let resolvedTextFields: [AXUIElement]
        if let textFields {
            resolvedTextFields = textFields
        } else if let resolvedTransport {
            resolvedTextFields = AXHelpers.findAllDescendants(
                of: resolvedTransport,
                role: kAXTextFieldRole,
                maxDepth: 6,
                runtime: runtime.ax
            )
        } else {
            resolvedTextFields = []
        }

        let textFieldSnapshots: [[String: Any]] = Array(resolvedTextFields.prefix(6)).map { field in
            let value: String? = AXHelpers.getAttribute(field, kAXValueAttribute, runtime: runtime.ax)
            return [
                "role": AXHelpers.getRole(field, runtime: runtime.ax) ?? NSNull(),
                "title": AXHelpers.getTitle(field, runtime: runtime.ax) ?? NSNull(),
                "description": AXHelpers.getDescription(field, runtime: runtime.ax) ?? NSNull(),
                "identifier": AXHelpers.getIdentifier(field, runtime: runtime.ax) ?? NSNull(),
                "value": value ?? NSNull(),
            ]
        }

        let cycleCheckbox = AXLogicProElements.findControlBarCheckbox(
            named: "사이클",
            englishName: "Cycle",
            runtime: runtime
        )

        return [
            "main_window_found": window != nil,
            "main_window_title": window.flatMap { AXHelpers.getTitle($0, runtime: runtime.ax) } ?? NSNull(),
            "transport_bar_found": resolvedTransport != nil,
            "transport_role": resolvedTransport.flatMap { AXHelpers.getRole($0, runtime: runtime.ax) } ?? NSNull(),
            "transport_title": resolvedTransport.flatMap { AXHelpers.getTitle($0, runtime: runtime.ax) } ?? NSNull(),
            "transport_description": resolvedTransport.flatMap { AXHelpers.getDescription($0, runtime: runtime.ax) } ?? NSNull(),
            "transport_identifier": resolvedTransport.flatMap { AXHelpers.getIdentifier($0, runtime: runtime.ax) } ?? NSNull(),
            "transport_child_count": resolvedTransport.flatMap { AXHelpers.getChildCount($0, runtime: runtime.ax) } ?? NSNull(),
            "transport_text_field_count": resolvedTextFields.count,
            "transport_text_fields": textFieldSnapshots,
            "cycle_checkbox_found": cycleCheckbox != nil,
            "cycle_checkbox_value": cycleCheckbox.flatMap { AXHelpers.getValue($0, runtime: runtime.ax) } ?? NSNull(),
        ]
    }

    private static func runCycleRangeFallbackScript(startPos: String, endPos: String) -> Bool {
        // Strategy: use Logic's "Go To > Go To Beginning" (not ideal) — we instead
        // rely on the menu path "Navigate > Set Locators…" which opens a dialog
        // with start/end text fields. Keystroke start, Tab, end, Return.
        // Menu path (Logic 12, ko): "탐색 > 로케이터 설정…"; (en): "Navigate > Set Locators…"
        let script = """
        tell application "System Events"
            tell process "Logic Pro"
                set frontmost to true
                delay 0.2
                -- Attempt Korean menu first
                try
                    click menu item "로케이터 설정…" of menu 1 of menu bar item "탐색" of menu bar 1
                on error
                    try
                        click menu item "Set Locators…" of menu 1 of menu bar item "Navigate" of menu bar 1
                    on error
                        return "no-menu"
                    end try
                end try
                delay 0.3
                keystroke "\(startPos)"
                key code 48   -- Tab
                delay 0.1
                keystroke "\(endPos)"
                delay 0.1
                key code 36   -- Return
                delay 0.2
                return "ok"
            end tell
        end tell
        """
        guard case let .completed(output) = BoundedProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 5.0,
            outputLimitBytes: 4 * 1024
        ), output.exitCode == 0 else {
            return false
        }
        let result = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result == "ok"
    }

    // MARK: - Control-bar playhead position helper

    /// Set the playhead to a specific bar. Two paths:
    /// 1) `탐색 → 이동 → 위치…` dialog (precise, auto-extends project, requires
    ///    at least one region in arrange — menu item is disabled on empty project)
    /// 2) Control-bar 마디 slider (clamps to project length; silently stops at
    ///    end when requested bar exceeds length)
    /// Accepts `{"bar": Int}` or `{"position": "B.B.S.S"}`.
    /// #109: set the arrange horizontal zoom to `level` (1...10) by writing the
    /// Horizontal-Zoom AXSlider (range 0...1, level 1 = fully out, 10 = fully
    /// in) and reading it back. Returns verified State A on a confirmed write,
    /// State B if the read-back can't confirm it. If the slider can't be found,
    /// returns a plain (non-terminal) error so the router falls back to the
    /// key-command channel.
    static func defaultSetZoomLevel(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        // Malformed input fails closed as terminal State C: a bad level must NOT
        // fall through to the key-command channel (which doesn't validate and
        // would fire a generic zoom). Mirrors gotoPositionViaBarSlider's guard.
        guard let levelStr = params["level"], let level = Int(levelStr), (1...10).contains(level) else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "nav.set_zoom_level requires 'level' (Int 1..10)",
                extras: ["operation": "nav.set_zoom"]
            ))
        }
        // Slider absent is NOT terminal: plain error lets the router fall back to
        // the key-command / CGEvent channels.
        guard let slider = AXLogicProElements.findHorizontalZoomSlider(runtime: runtime) else {
            return .error("Horizontal Zoom slider not found — falling back to key command")
        }
        let target = Double(level - 1) / 9.0
        let before = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax)
        _ = AXValueExtractors.setSliderValue(slider, target, runtime: runtime.ax)
        usleep(120_000)
        let after = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax)
        let extras: [String: Any] = [
            "operation": "nav.set_zoom",
            "axis": "horizontal",
            "level": level,
            "requested": target,
            "observed_before": before ?? NSNull(),
            "observed": after ?? NSNull(),
            "observed_after": after ?? NSNull(),
            "verify_source": "ax_zoom_slider",
        ]
        if let after, abs(after - target) < 0.02 {
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        return .success(HonestContract.encodeStateB(
            reason: after == nil ? .readbackUnavailable : .readbackMismatch,
            extras: extras
        ))
    }

    static func gotoPositionViaBarSlider(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        var targetBar: Int? = nil
        if let barStr = params["bar"], let b = Int(barStr) {
            targetBar = b
        } else if let pos = params["position"] {
            if pos.contains(":") {
                return .error("AX gotoPosition cannot handle timecode (use MCU mmc_locate)")
            }
            let parts = pos.split(separator: ".")
            if let first = parts.first, let b = Int(first) {
                targetBar = b
            }
        }
        guard let bar = targetBar, (1...9999).contains(bar) else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "goto_position requires 'bar' (Int 1..9999) or 'position' (B.B.S.S)"
            ))
        }

        let baseExtras: [String: Any] = ["requested": "\(bar).1.1.1"]

        let dialogResult = await gotoPositionViaDialog(bar: bar)
        if case .success = dialogResult { return dialogResult }

        guard let slider = AXLogicProElements.findControlBarBarSlider(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Neither goto-position dialog nor 마디 slider available",
                extras: baseExtras
            ))
        }
        let setOK = AXHelpers.setAttribute(
            slider, kAXValueAttribute, NSNumber(value: bar), runtime: runtime.ax
        )
        if !setOK {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Failed to set 마디 slider value",
                extras: baseExtras
            ))
        }
        if let beatSlider = AXLogicProElements.findControlBarBeatSlider(runtime: runtime) {
            _ = AXHelpers.setAttribute(
                beatSlider, kAXValueAttribute, NSNumber(value: 1), runtime: runtime.ax
            )
        }
        _ = AXHelpers.performAction(slider, kAXConfirmAction, runtime: runtime.ax)

        let observedBar = (AXHelpers.getValue(slider, runtime: runtime.ax) as? NSNumber)?.intValue
        let observedPos = observedBar.map { "\($0).1.1.1" }
        let extras = baseExtras.merging([
            "observed": observedPos ?? NSNull(),
            "via": "slider"
        ]) { _, new in new }
        if let observedBar, observedBar == bar {
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        if observedBar != nil {
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras))
        }
        return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
    }

    /// Move the playhead to `bar` via Logic Pro 12's `탐색 → 이동 → 위치…`
    /// (Navigate → Go To → Position) dialog. Reliable because the dialog auto-
    /// extends project length; however the menu item is disabled when no
    /// regions exist yet, in which case this returns an error and callers
    /// should try the slider fallback.
    private static func gotoPositionViaDialog(bar: Int) async -> ChannelResult {
        // Poll for the dialog's presence instead of relying on a fixed delay.
        // Without this guard, a slow machine (>500ms to render the dialog) would
        // send Cmd+A to the arrange area, selecting all regions unexpectedly.
        let script = """
        tell application "Logic Pro" to activate
        delay 0.2
        tell application "System Events"
            tell process "Logic Pro"
                try
                    set mi to menu item "위치…" of menu 1 of menu item "이동" of menu 1 of menu bar item "탐색" of menu bar 1
                on error errMsg
                    try
                        set mi to menu item "Position…" of menu 1 of menu item "Go To" of menu 1 of menu bar item "Navigate" of menu bar 1
                    on error errMsg2
                        return "MENU_NOT_FOUND: " & errMsg2
                    end try
                end try
                if not (enabled of mi) then
                    return "MENU_DISABLED"
                end if
                click mi
                -- Wait up to 3s for the dialog window to appear before typing,
                -- otherwise keystrokes would go to the arrange area and click
                -- Cmd+A there — silently "Select All Regions".
                set dialogReady to false
                repeat 30 times
                    delay 0.1
                    try
                        set _ to first window whose name is "위치로 이동"
                        set dialogReady to true
                        exit repeat
                    end try
                    try
                        set _ to first window whose name is "Go to Position"
                        set dialogReady to true
                        exit repeat
                    end try
                end repeat
                if not dialogReady then
                    return "DIALOG_NOT_READY"
                end if
            end tell
            delay 0.1
            keystroke "a" using command down
            delay 0.1
            keystroke "\(bar)"
            delay 0.1
            keystroke return
            delay 0.2
        end tell
        return "OK"
        """
        let result = await AppleScriptChannel.executeAppleScript(script)
        switch result {
        case .success(let output):
            if output.contains("MENU_DISABLED") {
                return .error("goto-position dialog disabled (project has no regions yet)")
            }
            if output.hasPrefix("MENU_NOT_FOUND") {
                return .error("goto-position menu not found: \(output)")
            }
            if output.contains("DIALOG_NOT_READY") {
                return .error("goto-position dialog did not appear within timeout")
            }
            // #105: this State B reports only that the Go-To-Position dialog
            // keystroke was sent; the playhead is verified independently by
            // `TransportDispatcher.finalizeGotoPositionResult` via a transport-
            // state read-back. Earlier this carried a `note` claiming the
            // playhead was "not read back" — which the finalize step then
            // contradicted by reading it back and gating `verified` on it, so a
            // verified State A shipped a self-contradictory note. The provenance
            // (`via:"dialog"`) plus finalize's `verification_source` /
            // `observed` / `verified` fields describe the outcome honestly
            // without it.
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: [
                    "requested": "\(bar).1.1.1",
                    "via": "dialog"
                ]
            ))
        case .error(let msg):
            return .error("goto-position dialog failed: \(msg)")
        }
    }

    // MARK: - Control-bar checkbox helpers (Logic Pro 12 transport)

    /// Click a control-bar checkbox by Korean/English name, toggling its value.
    /// Returns nil if the checkbox couldn't be located — callers may fall back.
    private static func clickControlBarCheckbox(
        korean: String,
        english: String,
        runtime: AXLogicProElements.Runtime = .production,
        mouseRuntime: AXMouseHelper.Runtime = .production
    ) -> ChannelResult? {
        guard let cb = AXLogicProElements.findControlBarCheckbox(
            named: korean, englishName: english, runtime: runtime
        ) else {
            return nil
        }
        let before = controlBarCheckboxValue(cb, runtime: runtime)
        var attempts: [String] = []

        for strategy in controlBarClickStrategies(
            element: cb,
            runtime: runtime,
            mouseRuntime: mouseRuntime
        ) {
            guard strategy.action() else {
                attempts.append("\(strategy.name):failed")
                continue
            }
            attempts.append(strategy.name)
            if let before {
                if let after = waitForControlBarCheckboxValue(
                    cb,
                    runtime: runtime,
                    matching: { $0 != before }
                ) {
                    return .success(HonestContract.encodeStateA(
                        extras: [
                            "button": english,
                            "control": korean,
                            "observed": after,
                            "previous": before,
                            "action": strategy.name,
                            "attempts": attempts
                        ]
                    ))
                }
            } else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "button": english,
                        "control": korean,
                        "action": strategy.name,
                        "attempts": attempts
                    ]
                ))
            }
        }

        if let before {
            return .error(HonestContract.encodeStateC(
                error: .readbackMismatch,
                hint: "control-bar checkbox '\(english)' did not change after real click / AXPress attempts",
                extras: [
                    "button": english,
                    "control": korean,
                    "observed": before,
                    "attempts": attempts,
                    "safe_to_retry": true
                ]
            ))
        }
        return .error(HonestContract.encodeStateC(
            error: .axWriteFailed,
            hint: "control-bar checkbox '\(english)' had no readable value and no click strategy succeeded",
            extras: [
                "button": english,
                "control": korean,
                "attempts": attempts,
                "safe_to_retry": true
            ]
        ))
    }

    /// Ensure a control-bar checkbox matches `desired` state. Reads current
    /// value and clicks only if it differs. Returns nil if the checkbox
    /// cannot be located (caller may fall back).
    private static func setControlBarCheckboxValue(
        korean: String,
        english: String,
        desired: Bool,
        runtime: AXLogicProElements.Runtime = .production,
        mouseRuntime: AXMouseHelper.Runtime = .production
    ) -> ChannelResult? {
        guard let cb = AXLogicProElements.findControlBarCheckbox(
            named: korean, englishName: english, runtime: runtime
        ) else {
            return nil
        }
        guard let current = controlBarCheckboxValue(cb, runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "control-bar checkbox '\(english)' current value is unreadable; refusing unsafe toggle-click for desired=\(desired)",
                extras: [
                    "button": english,
                    "control": korean,
                    "requested": desired,
                    "safe_to_retry": true
                ]
            ))
        }
        let baseExtras: [String: Any] = [
            "button": english,
            "control": korean,
            "requested": desired
        ]
        if current == desired {
            return .success(HonestContract.encodeStateA(
                extras: baseExtras.merging([
                    "observed": desired,
                    "action": "no-op"
                ]) { _, new in new }
            ))
        }

        var attempts: [String] = []
        for strategy in controlBarClickStrategies(
            element: cb,
            runtime: runtime,
            mouseRuntime: mouseRuntime
        ) {
            guard strategy.action() else {
                attempts.append("\(strategy.name):failed")
                continue
            }
            attempts.append(strategy.name)
            if let observed = waitForControlBarCheckboxValue(
                cb,
                runtime: runtime,
                matching: { $0 == desired }
            ) {
                return .success(HonestContract.encodeStateA(
                    extras: baseExtras.merging([
                        "observed": observed,
                        "action": strategy.name,
                        "attempts": attempts
                    ]) { _, new in new }
                ))
            }
        }

        let observed = controlBarCheckboxValue(cb, runtime: runtime) as Any
        return .error(HonestContract.encodeStateC(
            error: .readbackMismatch,
            hint: "control-bar checkbox '\(english)' did not reach desired=\(desired) after real click / AXPress attempts",
            extras: baseExtras.merging([
                "observed": observed,
                "attempts": attempts,
                "safe_to_retry": true
            ]) { _, new in new }
        ))
    }

    private struct ControlBarClickStrategy {
        let name: String
        let action: () -> Bool
    }

    private static func controlBarClickStrategies(
        element: AXUIElement,
        runtime: AXLogicProElements.Runtime,
        mouseRuntime: AXMouseHelper.Runtime
    ) -> [ControlBarClickStrategy] {
        [
            ControlBarClickStrategy(name: "mouse-click", action: {
                guard let position = AXHelpers.getPosition(element, runtime: runtime.ax),
                      let size = AXHelpers.getSize(element, runtime: runtime.ax),
                      position.x.isFinite,
                      position.y.isFinite,
                      size.width.isFinite,
                      size.height.isFinite,
                      size.width > 0,
                      size.height > 0 else {
                    return false
                }
                let center = CGPoint(
                    x: position.x + size.width / 2,
                    y: position.y + size.height / 2
                )
                return AXMouseHelper.click(at: center, runtime: mouseRuntime)
            }),
            ControlBarClickStrategy(name: "axpress", action: {
                AXHelpers.performAction(element, kAXPressAction, runtime: runtime.ax)
            }),
            ControlBarClickStrategy(name: "axconfirm", action: {
                AXHelpers.performAction(element, kAXConfirmAction, runtime: runtime.ax)
            }),
        ]
    }

    private static func controlBarCheckboxValue(
        _ element: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> Bool? {
        guard let raw = AXHelpers.getValue(element, runtime: runtime.ax) else { return nil }
        if let n = raw as? NSNumber { return n.boolValue }
        if let b = raw as? Bool { return b }
        if let i = raw as? Int { return i != 0 }
        if let s = raw as? String {
            let normalized = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "on"].contains(normalized) { return true }
            if ["0", "false", "no", "off"].contains(normalized) { return false }
        }
        return nil
    }

    private static func waitForControlBarCheckboxValue(
        _ element: AXUIElement,
        runtime: AXLogicProElements.Runtime,
        matching predicate: (Bool) -> Bool
    ) -> Bool? {
        for _ in 0..<12 {
            usleep(50_000)
            if let value = controlBarCheckboxValue(element, runtime: runtime),
               predicate(value) {
                return value
            }
        }
        return nil
    }

}
