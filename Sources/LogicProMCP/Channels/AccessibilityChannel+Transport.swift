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
            "CountIn":    ("카운트 인",     "Count In",  nil),
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
        if name == "AutoPunch" {
            return AccessibilityChannel.defaultToggleAutopunch(
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
                if abs(afterIncrement - tempoValue) < 1.0 {
                    return .success(HonestContract.encodeStateA(
                        extras: baseExtras.merging([
                            "observed": afterIncrement,
                            "via": "slider-increment"
                        ]) { _, new in new }
                    ))
                }

                // Logic treats a numeric AXValue write as a one-BPM nudge. The
                // coarse step leaves at most five BPM, so ten writes are bounded.
                var observed = afterIncrement
                for _ in 0..<10 {
                    let previous = observed
                    guard AXHelpers.setAttribute(
                        slider,
                        kAXValueAttribute,
                        NSNumber(value: tempoValue),
                        runtime: runtime.ax
                    ) else { break }
                    Thread.sleep(forTimeInterval: 0.02)
                    guard let next = AXHelpers.getValue(slider, runtime: runtime.ax) as? Double else { break }
                    observed = next
                    if abs(observed - tempoValue) < 1.0 {
                        return .success(HonestContract.encodeStateA(
                            extras: baseExtras.merging([
                                "observed": observed,
                                "via": "slider-value-nudge"
                            ]) { _, new in new }
                        ))
                    }
                    if observed == previous { break }
                }
                return .error(HonestContract.encodeStateC(
                    error: .readbackMismatch,
                    hint: "typed tempo entry did not commit and the slider's coarse and exact value fallbacks did not converge",
                    extras: baseExtras.merging([
                        "observed": observed,
                        "via": "slider-value-nudge",
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
        let logicProAppleScript = LogicProTarget.appleScriptTarget()
        let script = """
        tell application "System Events"
            tell \(logicProAppleScript.systemEventsProcessTarget)
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
        let logicProAppleScript = LogicProTarget.appleScriptTarget()
        // Strategy: use Logic's "Go To > Go To Beginning" (not ideal) — we instead
        // rely on the menu path "Navigate > Set Locators…" which opens a dialog
        // with start/end text fields. Keystroke start, Tab, end, Return.
        // Menu path (Logic 12, ko): "탐색 > 로케이터 설정…"; (en): "Navigate > Set Locators…"
        let script = """
        tell application "System Events"
            tell \(logicProAppleScript.systemEventsProcessTarget)
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

    /// #440 D: the same precondition the CGEvent channel applies. Measured on the release artifact,
    /// driving this from the background lands on the wrong bar — requested 1.1.1.1, observed 3.3.1.1
    /// and 2.3.1.1 on two runs, against 2/2 exact hits with Logic frontmost — so the playhead moves
    /// before anything can tell it went wrong. The seams carry production defaults; tests inject.
    static func gotoPositionViaBarSlider(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        isFrontmost: @Sendable () -> Bool = ProcessUtils.Runtime.production.logicIsFrontmost,
        activateLogic: @Sendable () -> Bool = ProcessUtils.Runtime.production.activateLogicPro,
        sleepMicros: @Sendable (UInt32) -> Void = { usleep($0) },
        executeDialogScript: @escaping @Sendable (String) async -> ChannelResult = { script in
            await AppleScriptChannel.executeAppleScript(script, timeout: 8.0)
        }
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

        var baseExtras: [String: Any] = ["requested": "\(bar).1.1.1"]

        // Refuse before touching anything: a non-ready result means nothing has been actuated, so
        // the caller can retry without wondering whether the playhead already moved.
        let preparation = FrontmostGate.prepare(
            isFrontmost: isFrontmost, activate: activateLogic, sleepMicros: sleepMicros
        )
        guard preparation.isReady else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "goto_position drives Logic's own UI; from the background it moves the playhead "
                    + "to the wrong bar, so nothing was touched. Bring Logic Pro to the front and retry.",
                extras: baseExtras.merging([
                    "operation": "transport.goto_position",
                    "method": "ax_bar_slider",
                    "frontmost_preparation": preparation.rawValue,
                    "write_attempted": false,
                    "safe_to_retry": true,
                ]) { _, new in new }
            ))
        }
        // Record it on the success paths too: a receipt that only mentions the gate when it refuses
        // cannot show that a successful run had to bring Logic forward first.
        baseExtras["frontmost_preparation"] = preparation.rawValue

        let dialogResult = await gotoPositionViaDialog(
            bar: bar, executeScript: executeDialogScript
        )
        if case let .driven(payload) = dialogResult {
            // The dialog rung builds its own envelope, so without this the same operation reports
            // the frontmost gate on one path and stays silent on the other — a receipt field you
            // cannot rely on is worse than none.
            return .success(mergingJSONField(
                payload, key: "frontmost_preparation", value: preparation.rawValue
            ))
        }
        if case let .failed(classification) = dialogResult,
           classification.isUnsafeToActuateAgain {
            // `dismissOpenMenu` could not prove that the menu closed. A slider write from this
            // state can operate on the still-open menu, so this is terminal rather than fallback.
            // This branch runs before the dialog input is typed and submitted. Opening the menu
            // chain is UI navigation, not a `transport.goto_position` write, so this remains a
            // State C refusal with `write_attempted:false`. Retain that the navigation click did
            // happen separately for diagnosis.
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "The Go To Position menu could not be closed; the slider fallback was not attempted.",
                extras: baseExtras.merging([
                    "operation": "transport.goto_position",
                    "method": "dialog",
                    "menu_state": "could_not_be_closed",
                    "menu_actuation_attempted": classification.menuActuationAttemptedBeforeUnsafeRefusal,
                    "write_attempted": false,
                    "safe_to_retry": false,
                    // #530: even though ax_write_failed is normally non-terminal, a still-open
                    // menu makes every weaker transport channel unsafe to invoke.
                    "fallback_unsafe": true,
                ]) { _, new in new }
            ))
        }
        if case let .failed(classification) = dialogResult,
           classification.hasIssuedGoToPositionActuator {
            // A leaf menu click, dialog input, or Return may take effect even when the AX / AppleScript
            // invocation says it failed.  Once one of those has been issued, the slider is a *second*
            // goto-position actuator, not a fallback-safe retry.  This deliberately keys off issuance,
            // never the return code, following the Delete-key path's write-attempt boundary.
            let submissionIssued = classification.hasIssuedDialogSubmission
            let dialogState = classification.dialogCleanupObservedClosed ? "closed" : "unobserved"
            let extras = baseExtras.merging([
                "operation": "transport.goto_position",
                "method": "dialog",
                "dialog_actuation_attempted": true,
                "dialog_submission_attempted": submissionIssued,
                "dialog_cleanup": dialogState,
                // Opening the dialog is navigation, while a submitted Return may have moved the
                // playhead. Keep that distinction explicit rather than using a false AX result to
                // say no position write was attempted.
                "write_attempted": submissionIssued,
                "safe_to_retry": false,
                "fallback_unsafe": true,
            ]) { _, new in new }
            if submissionIssued {
                // Return was issued, so a position write may have landed. The result is uncertain
                // rather than a known hard failure, but the slider remains unsafe as a second actuator.
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: extras
                ))
            }
            // The issued leaf only navigates to the dialog. With no submission, no position write was
            // attempted, so this remains the known State C navigation failure.
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "The Go To Position menu item was issued but reported an error; "
                    + "the slider fallback was not attempted.",
                extras: extras
            ))
        }

        guard let slider = AXLogicProElements.findControlBarBarSlider(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Neither goto-position dialog nor 마디 slider available",
                extras: baseExtras
            ))
        }

        // AX setters cannot establish either outcome: Logic has returned both failure after an
        // effective write and success after no change.  The issued write is recorded below, then
        // every subsequent action is authorised by a status-preserving observation instead.
        func sliderValue(_ element: AXUIElement) -> Result<Int?, AXHelpers.AXStatusError> {
            let value: Result<NSNumber?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                element, kAXValueAttribute as String, runtime: runtime.ax
            )
            return value.map { $0?.intValue }
        }

        func observedPosition(bar: Int, beat: Int?) -> String {
            // These are slider readings, not a transport-state parse.  Do not append beat/subbeat/tick
            // components that no AX reader supplied.
            guard let beat else { return "\(bar)" }
            return "\(bar).\(beat)"
        }

        func sliderExtras(observedBar: Int?, observedBeat: Int? = nil) -> [String: Any] {
            baseExtras.merging([
                "observed": observedBar.map { observedPosition(bar: $0, beat: observedBeat) } ?? NSNull(),
                "via": "slider",
                "write_attempted": true,
            ]) { _, new in new }
        }

        _ = AXHelpers.setAttribute(
            slider, kAXValueAttribute, NSNumber(value: bar), runtime: runtime.ax
        )
        let initialBar: Int?
        switch sliderValue(slider) {
        case .failure, .success(nil):
            // The bar write was issued.  A failed read is not evidence that it was refused, so this
            // must be uncertain State B rather than State C; neither beat nor Confirm is authorised.
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: sliderExtras(observedBar: nil)
            ))
        case let .success(value?):
            initialBar = value
        }
        guard initialBar == bar else {
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: sliderExtras(observedBar: initialBar)
            ))
        }

        let beatSlider = AXLogicProElements.findControlBarBeatSlider(runtime: runtime)
        var initialBeat: Int?
        if let beatSlider {
            _ = AXHelpers.setAttribute(
                beatSlider, kAXValueAttribute, NSNumber(value: 1), runtime: runtime.ax
            )
            switch sliderValue(beatSlider) {
            case .failure, .success(nil):
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: sliderExtras(observedBar: initialBar)
                ))
            case let .success(value?):
                initialBeat = value
            }
            guard initialBeat == 1 else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackMismatch,
                    extras: sliderExtras(observedBar: initialBar, observedBeat: initialBeat)
                ))
            }
        }

        // Confirm is also an AX actuation whose return code is not a trustworthy outcome.  Read the
        // actual sliders again afterwards, and certify only the components those reads vended.
        _ = AXHelpers.performAction(slider, kAXConfirmAction, runtime: runtime.ax)
        let finalBar: Int?
        switch sliderValue(slider) {
        case .failure, .success(nil):
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: sliderExtras(observedBar: initialBar, observedBeat: initialBeat)
            ))
        case let .success(value?):
            finalBar = value
        }
        guard finalBar == bar else {
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: sliderExtras(observedBar: finalBar)
            ))
        }

        var finalBeat: Int?
        if let beatSlider {
            switch sliderValue(beatSlider) {
            case .failure, .success(nil):
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: sliderExtras(observedBar: finalBar)
                ))
            case let .success(value?):
                finalBeat = value
            }
            guard finalBeat == 1 else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackMismatch,
                    extras: sliderExtras(observedBar: finalBar, observedBeat: finalBeat)
                ))
            }
        }
        return .success(HonestContract.encodeStateA(
            extras: sliderExtras(observedBar: finalBar, observedBeat: finalBeat)
        ))
    }

    /// Move the playhead to `bar` via Logic Pro 12's `탐색 → 이동 → 위치…`
    /// (Navigate → Go To → Position) dialog. Reliable because the dialog auto-
    /// extends project length; however the menu item is disabled when no
    /// regions exist yet, in which case this returns an error and callers
    /// should try the slider fallback.
    /// Adds one field to an already-encoded JSON envelope, leaving it untouched if it cannot be
    /// parsed — a receipt is never worth corrupting to annotate.
    private static func mergingJSONField(_ payload: String, key: String, value: String) -> String {
        guard let data = payload.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return payload }
        obj[key] = value
        guard let merged = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: merged, encoding: .utf8)
        else { return payload }
        return text
    }

    /// The script is internal so the menu-validation regression tests can assert the
    /// exact generated AppleScript ordering without invoking Logic Pro.
    static func gotoPositionViaDialogAppleScript(bar: Int) -> String {
        // Poll for the dialog's presence instead of relying on a fixed delay.
        // Without this guard, a slow machine (>500ms to render the dialog) would
        // send Cmd+A to the arrange area, selecting all regions unexpectedly.
        let logicProAppleScript = LogicProTarget.appleScriptTarget()
        return """
        -- A selected menu-bar item is the AX observation that one of Logic's
        -- menus is currently open. Return UNREADABLE rather than treating a
        -- failed read as a clean menu state.
        on menuOpenState(theProcess)
            using terms from application "System Events"
                tell theProcess
                    try
                        repeat with menuBarItem in every menu bar item of menu bar 1
                            if selected of menuBarItem then return "OPEN"
                        end repeat
                        return "CLOSED"
                    on error
                        return "UNREADABLE"
                    end try
                end tell
            end using terms from
        end menuOpenState

        -- Never claim that Escape cleaned up a menu until AXSelected says so.
        -- Three attempts are enough to cover a menu/submenu chain without
        -- turning a failed close into an unbounded retry.
        -- `knownOpen` says whether THIS run has already clicked a menu open. It changes what an
        -- unreadable first read means. At entry nothing has been opened, so UNREADABLE is an absent
        -- observation and returning it lets the run proceed — refusing there sent 5 of 8 fresh
        -- processes to the slider route. After this run clicked, a menu IS open: an unreadable read
        -- is not permission to skip the Escape, because skipping it can end the run with the menu
        -- still up.
        on dismissOpenMenu(theProcess, knownOpen)
            set menuState to my menuOpenState(theProcess)
            if menuState is "CLOSED" then return "CLOSED"
            if menuState is "UNREADABLE" and not knownOpen then return "UNREADABLE"
            if menuState is not "OPEN" and menuState is not "UNREADABLE" then return menuState
            repeat 3 times
                using terms from application "System Events"
                    tell theProcess to key code 53
                end using terms from
                delay 0.1
                set menuState to my menuOpenState(theProcess)
                if menuState is "CLOSED" then return "CLOSED"
                if menuState is "UNREADABLE" then return "OPEN_UNREADABLE"
                if menuState is not "OPEN" then return menuState
            end repeat
            return "OPEN"
        end dismissOpenMenu

        -- Appending this context lets the Swift receipt distinguish an unsafe
        -- entry cleanup (no operation actuation) from an unsafe cleanup after a
        -- menu click. It is deliberately attached only to refusal results.
        on menuCleanupActuationContext(menuActuationAttempted)
            if menuActuationAttempted then return " after menu actuation"
            return ""
        end menuCleanupActuationContext

        -- AXPress can return before Logic has opened the clicked item's own menu.
        -- AXSelected belongs to that exact item, so an unrelated open menu cannot
        -- authorise the next click.
        on menuItemOpenedAfterClick(theMenuItem)
            repeat 3 times
                using terms from application "System Events"
                    try
                        if selected of theMenuItem then return "OPEN"
                    on error
                        return "UNREADABLE"
                    end try
                end using terms from
                delay 0.1
            end repeat
            return "CLOSED"
        end menuItemOpenedAfterClick

        -- The Go To Position floating dialog has its own lifecycle; a menu-bar
        -- observation says nothing about whether this modal is still blocking
        -- the arrange area.  Keep unreadable distinct from closed, just as the
        -- #529 menu cleanup does.
        on goToPositionDialogState(theProcess)
            using terms from application "System Events"
                tell theProcess
                    try
                        repeat with dialogWindow in every window
                            set dialogTitle to name of dialogWindow
                            if dialogTitle is "위치로 이동" then return "OPEN"
                            if dialogTitle is "Go To Position" then return "OPEN"
                            if dialogTitle is "Go to Position" then return "OPEN"
                        end repeat
                        return "CLOSED"
                    on error
                        return "UNREADABLE"
                    end try
                end tell
            end using terms from
        end goToPositionDialogState

        -- Prefer this modal's localized Cancel button.  Escape is only a
        -- fallback while this exact dialog is observed open, and every attempt
        -- must be followed by a new exact-dialog observation before it counts
        -- as cleanup.
        on pressGoToPositionDialogCancel(theProcess)
            using terms from application "System Events"
                tell theProcess
                    try
                        repeat with dialogWindow in every window
                            set dialogTitle to name of dialogWindow
                            if dialogTitle is "위치로 이동" or dialogTitle is "Go To Position" or dialogTitle is "Go to Position" then
                                if exists button "Cancel" of dialogWindow then
                                    click button "Cancel" of dialogWindow
                                    return "PRESSED"
                                end if
                                if exists button "취소" of dialogWindow then
                                    click button "취소" of dialogWindow
                                    return "PRESSED"
                                end if
                                if exists button "キャンセル" of dialogWindow then
                                    click button "キャンセル" of dialogWindow
                                    return "PRESSED"
                                end if
                                return "NO_BUTTON"
                            end if
                        end repeat
                        return "NO_BUTTON"
                    on error
                        return "UNREADABLE"
                    end try
                end tell
            end using terms from
        end pressGoToPositionDialogCancel

        on dismissOpenGoToPositionDialog(theProcess)
            set dialogState to my goToPositionDialogState(theProcess)
            if dialogState is "CLOSED" then return "CLOSED"
            if dialogState is not "OPEN" then return dialogState
            repeat 3 times
                set cancelOutcome to my pressGoToPositionDialogCancel(theProcess)
                if cancelOutcome is "NO_BUTTON" or cancelOutcome is "UNREADABLE" then
                    -- The Cancel click may have landed even though AX reported failure. Re-observe
                    -- this exact dialog before choosing Escape as a second actuator; unreadable is
                    -- not permission to send a key into an unknown focus target.
                    set dialogState to my goToPositionDialogState(theProcess)
                    if dialogState is "CLOSED" then return "CLOSED"
                    if dialogState is "UNREADABLE" then return "OPEN_UNREADABLE"
                    if dialogState is not "OPEN" then return dialogState
                    using terms from application "System Events"
                        tell theProcess to key code 53
                    end using terms from
                end if
                delay 0.1
                set dialogState to my goToPositionDialogState(theProcess)
                if dialogState is "CLOSED" then return "CLOSED"
                if dialogState is "UNREADABLE" then return "OPEN_UNREADABLE"
                if dialogState is not "OPEN" then return dialogState
            end repeat
            return "OPEN"
        end dismissOpenGoToPositionDialog

        \(logicProAppleScript.activateByBundleID)
        tell application "System Events"
            set logicProcess to \(logicProAppleScript.systemEventsProcessTarget)
            tell logicProcess
                -- A timed-out predecessor can leave a menu open. Clear and
                -- observe that state before this run performs any menu read or
                -- actuation, so a later fallback never inherits an open menu.
                set entryMenuCleanup to my dismissOpenMenu(logicProcess, false)
                if entryMenuCleanup is "OPEN" or entryMenuCleanup is "OPEN_UNREADABLE" then
                    return "MENU_PICK_FAILED: a menu was open at entry and would not close (" & entryMenuCleanup & ")"
                end if
                -- UNREADABLE is NOT a refusal here. Nothing has been opened by this
                -- run yet, so an unreadable menu bar is an absent observation, not
                -- evidence that something is open — and on a cold System Events
                -- connection the first read frequently is unreadable. Refusing on it
                -- sent 5 of 8 fresh processes to the slider route, measured. After
                -- this run opens a menu the same value IS a refusal, because then
                -- there is something known to be open.
                set menuActuationAttempted to false
                -- This marks the write boundary for actuator selection.  The
                -- leaf may succeed even if AX reports an error, so any result
                -- after it becomes true must not release the slider route.
                set dialogActuationIssued to false
                delay 0.2

                -- Locale selection is a read-only path-resolution step. It
                -- deliberately performs no click, so an AX error cannot turn a
                -- Korean attempt into a second English menu actuation.
                try
                    if exists menu item "위치…" of menu 1 of menu item "이동" of menu 1 of menu bar item "탐색" of menu bar 1 then
                        set selectedMenuBarItem to menu bar item "탐색" of menu bar 1
                        set selectedSubmenuItem to menu item "이동" of menu 1 of selectedMenuBarItem
                        set mi to menu item "위치…" of menu 1 of selectedSubmenuItem
                    else if exists menu item "Position…" of menu 1 of menu item "Go To" of menu 1 of menu bar item "Navigate" of menu bar 1 then
                        set selectedMenuBarItem to menu bar item "Navigate" of menu bar 1
                        set selectedSubmenuItem to menu item "Go To" of menu 1 of selectedMenuBarItem
                        set mi to menu item "Position…" of menu 1 of selectedSubmenuItem
                    else
                        set cleanupState to my dismissOpenMenu(logicProcess, true)
                        if cleanupState is not "CLOSED" then
                            return "MENU_PICK_FAILED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                        end if
                        return "MENU_NOT_FOUND"
                    end if
                on error errMsg
                    set cleanupState to my dismissOpenMenu(logicProcess, true)
                    if cleanupState is not "CLOSED" then
                        return "MENU_PICK_FAILED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                    end if
                    return "MENU_NOT_FOUND: " & errMsg
                end try
                try
                    -- Opening the selected chain refreshes AXEnabled. This is
                    -- the only menu-bar chain that can be clicked in this run.
                    set menuActuationAttempted to true
                    click selectedMenuBarItem
                    set menuBarOpenState to my menuItemOpenedAfterClick(selectedMenuBarItem)
                    if menuBarOpenState is not "OPEN" then
                        set cleanupState to my dismissOpenMenu(logicProcess, true)
                        if cleanupState is not "CLOSED" then
                            return "MENU_PICK_FAILED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                        end if
                        return "MENU_PICK_FAILED: selected menu bar item did not open (" & menuBarOpenState & ")"
                    end if
                    click selectedSubmenuItem
                    set submenuOpenState to my menuItemOpenedAfterClick(selectedSubmenuItem)
                    if submenuOpenState is not "OPEN" then
                        set cleanupState to my dismissOpenMenu(logicProcess, true)
                        if cleanupState is not "CLOSED" then
                            return "MENU_PICK_FAILED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                        end if
                        return "MENU_PICK_FAILED: selected submenu item did not open (" & submenuOpenState & ")"
                    end if
                on error errMsg
                    set cleanupState to my dismissOpenMenu(logicProcess, true)
                    if cleanupState is not "CLOSED" then
                        return "MENU_PICK_FAILED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                    end if
                    return "MENU_NOT_FOUND: " & errMsg
                end try
                try
                    set menuItemEnabled to enabled of mi
                on error
                    -- An unreadable AXEnabled must not authorise the pick.
                    set cleanupState to my dismissOpenMenu(logicProcess, true)
                    if cleanupState is not "CLOSED" then
                        return "MENU_PICK_FAILED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                    end if
                    return "MENU_STATE_UNREADABLE"
                end try
                if not menuItemEnabled then
                    set cleanupState to my dismissOpenMenu(logicProcess, true)
                    if cleanupState is not "CLOSED" then
                        return "MENU_PICK_FAILED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                    end if
                    return "MENU_DISABLED"
                end if
                try
                    set dialogActuationIssued to true
                    click mi
                on error errMsg
                    set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess)
                    if dialogCleanupState is not "CLOSED" then
                        return "DIALOG_ACTUATION_ISSUED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                    end if
                    set cleanupState to my dismissOpenMenu(logicProcess, true)
                    if cleanupState is not "CLOSED" then
                        return "DIALOG_ACTUATION_ISSUED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                    end if
                    return "DIALOG_ACTUATION_ISSUED: " & errMsg
                end try
                -- Wait up to 3s for the dialog window to appear before typing,
                -- otherwise keystrokes would go to the arrange area and click
                -- Cmd+A there — silently "Select All Regions".
                set dialogReady to false
                repeat 30 times
                    delay 0.1
                    set dialogOpenState to my goToPositionDialogState(logicProcess)
                    if dialogOpenState is "OPEN" then
                        set dialogReady to true
                        exit repeat
                    end if
                end repeat
                if not dialogReady then
                    set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess)
                    if dialogCleanupState is not "CLOSED" then
                        return "DIALOG_ACTUATION_ISSUED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                    end if
                    set cleanupState to my dismissOpenMenu(logicProcess, true)
                    if cleanupState is not "CLOSED" then
                        return "DIALOG_ACTUATION_ISSUED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                    end if
                    return "DIALOG_ACTUATION_ISSUED: dialog did not become ready"
                end if
            end tell
            try
                delay 0.1
                keystroke "a" using command down
                delay 0.1
                keystroke "\(bar)"
                delay 0.1
                keystroke return
                delay 0.2
            on error errMsg
                set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess)
                if dialogCleanupState is not "CLOSED" then
                    return "DIALOG_SUBMISSION_FAILED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                end if
                return "DIALOG_SUBMISSION_FAILED: dialog input or Return failed after the dialog opened (" & errMsg & ")"
            end try
        end tell
        return "OK"
        """
    }

    /// The successful AppleScript channel payload is a JSON object containing the
    /// script's return value in `result`. Only an exact `OK` means this route
    /// reached the dialog and submitted it. Only failures before the position
    /// menu leaf is issued may fall through to the slider route.  AX return
    /// codes do not prove whether that leaf (or later dialog input) took effect.
    enum GotoPositionDialogResultClassification: Equatable {
        enum Failure: Equatable {
            case menuNotFound
            case menuStateUnreadable
            case menuDisabled
            case menuPickFailed
            case menuCouldNotBeClosed(writeAttempted: Bool)
            case dialogNotReady
            case dialogActuationIssued(cleanupObservedClosed: Bool)
            case dialogSubmissionIssued(cleanupObservedClosed: Bool)
            case malformedPayload
            case unexpectedResult
            case executionFailed
        }

        case driven
        case failure(Failure)

        var isUnsafeToActuateAgain: Bool {
            if case .failure(.menuCouldNotBeClosed) = self {
                return true
            }
            return false
        }

        /// A menu leaf click opens the Go To Position dialog, and keyboard input / Return can
        /// commit it.  Their status returns are not a licence to choose the slider as another
        /// position actuator.  `dialogNotReady` is included because the generated script can only
        /// produce it after it has issued the leaf click.
        var hasIssuedGoToPositionActuator: Bool {
            switch self {
            case .failure(.dialogNotReady),
                 .failure(.dialogActuationIssued),
                 .failure(.dialogSubmissionIssued):
                return true
            default:
                return false
            }
        }

        var hasIssuedDialogSubmission: Bool {
            if case .failure(.dialogSubmissionIssued) = self {
                return true
            }
            return false
        }

        /// Closed is an observed result from the dialog-specific cleanup, never an inference from
        /// a setter or an Escape return.  A leaf error / not-ready outcome has no closed-dialog
        /// proof, so the receipt keeps that absence visible.
        var dialogCleanupObservedClosed: Bool {
            switch self {
            case let .failure(.dialogActuationIssued(cleanupObservedClosed)),
                 let .failure(.dialogSubmissionIssued(cleanupObservedClosed)):
                return cleanupObservedClosed
            default:
                return false
            }
        }

        var menuActuationAttemptedBeforeUnsafeRefusal: Bool {
            if case let .failure(.menuCouldNotBeClosed(writeAttempted)) = self {
                return writeAttempted
            }
            return false
        }
    }

    private struct GotoPositionDialogScriptPayload: Decodable {
        let result: String
    }

    /// Kept internal for the menu-validation regression tests. This consumes
    /// the JSON envelope produced by `AppleScriptChannel.channelResult` rather
    /// than inspecting its serialized representation.
    static func classifyGotoPositionDialogResult(
        _ output: String
    ) -> GotoPositionDialogResultClassification {
        guard let data = output.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GotoPositionDialogScriptPayload.self, from: data)
        else {
            return .failure(.malformedPayload)
        }

        switch payload.result {
        case "OK":
            return .driven
        case let value where value.hasPrefix("MENU_NOT_FOUND"):
            return .failure(.menuNotFound)
        case "MENU_STATE_UNREADABLE":
            return .failure(.menuStateUnreadable)
        case "MENU_DISABLED":
            return .failure(.menuDisabled)
        case let value where value.hasPrefix("MENU_PICK_FAILED"):
            if value.hasPrefix("MENU_PICK_FAILED: a menu was open at entry and would not close")
                || value.hasPrefix("MENU_PICK_FAILED: menu cleanup was not observed") {
                return .failure(.menuCouldNotBeClosed(
                    writeAttempted: value.hasPrefix(
                        "MENU_PICK_FAILED: menu cleanup was not observed after menu actuation"
                    )
                ))
            }
            return .failure(.menuPickFailed)
        case "DIALOG_NOT_READY":
            return .failure(.dialogNotReady)
        case let value where value.hasPrefix("DIALOG_ACTUATION_ISSUED"):
            return .failure(.dialogActuationIssued(
                cleanupObservedClosed: !value.contains("dialog cleanup was not observed")
            ))
        case let value where value.hasPrefix("DIALOG_SUBMISSION_FAILED"):
            return .failure(.dialogSubmissionIssued(
                cleanupObservedClosed: !value.contains("dialog cleanup was not observed")
            ))
        default:
            return .failure(.unexpectedResult)
        }
    }

    private enum GotoPositionDialogRouteResult {
        case driven(String)
        case failed(GotoPositionDialogResultClassification)
    }

    private static func gotoPositionViaDialog(
        bar: Int,
        executeScript: @escaping @Sendable (String) async -> ChannelResult
    ) async -> GotoPositionDialogRouteResult {
        let script = gotoPositionViaDialogAppleScript(bar: bar)
        let result = await executeScript(script)
        switch result {
        case .success(let output):
            let classification = classifyGotoPositionDialogResult(output)
            switch classification {
            case .driven:
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
                return .driven(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "requested": "\(bar).1.1.1",
                        "via": "dialog"
                    ]
                ))
            case .failure:
                return .failed(classification)
            }
        case .error:
            // The script died — timeout, TCC refusal, anything. It clicks menus open, so its death
            // leaves the menu state UNKNOWN, and unknown is not safe: the slider would actuate into
            // whatever is on screen. Try once to observe and clear any open menu; only a state
            // observed CLOSED lets the fallback proceed.
            // If Logic is not running at all, no menu of its can be open, and the script's death
            // says nothing about menu state. Only when the app IS there does an unobservable menu
            // become a reason to withhold the fallback.
            guard ProcessUtils.logicProPID() != nil else {
                return .failed(.failure(.executionFailed))
            }
            switch await observeAndClearStrayMenu() {
            case .closed:
                return .failed(.failure(.executionFailed))
            case .openOrUnknown:
                return .failed(.failure(.menuCouldNotBeClosed(writeAttempted: false)))
            }
        }
    }


    private enum StrayMenuOutcome { case closed, openOrUnknown }

    /// Independent of the script that just died: ask System Events whether any menu bar item is
    /// selected, send Escape if so, and observe again. Anything other than an observed CLOSED —
    /// including an unreadable menu bar — is `openOrUnknown`, because a failed reading is not
    /// evidence that nothing is open.
    private static func observeAndClearStrayMenu() async -> StrayMenuOutcome {
        let target = LogicProTarget.appleScriptTarget()
        let script = """
        tell application "System Events"
            tell \(target.systemEventsProcessTarget)
                try
                    repeat 3 times
                        set anyOpen to false
                        repeat with menuBarItem in every menu bar item of menu bar 1
                            if selected of menuBarItem then set anyOpen to true
                        end repeat
                        if not anyOpen then return "CLOSED"
                        key code 53
                        delay 0.1
                    end repeat
                    return "OPEN"
                on error
                    return "UNREADABLE"
                end try
            end tell
        end tell
        """
        guard case let .success(payload) = await AppleScriptChannel.executeAppleScript(script, timeout: 4.0),
              let data = payload.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["result"] as? String) == "CLOSED"
        else { return .openOrUnknown }
        return .closed
    }

    // MARK: - Control-bar checkbox helpers (Logic Pro 12 transport)

    static func defaultToggleAutopunch(
        runtime: AXLogicProElements.Runtime = .production,
        mouseRuntime: AXMouseHelper.Runtime = .production
    ) -> ChannelResult {
        guard let button = AXLogicProElements.findControlBarCheckbox(
            matching: AXLocalePolicy.transportAutopunchControl,
            runtime: runtime
        ) else {
            let controlBar = AXLogicProElements.getControlBar(runtime: runtime)
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Autopunch was not found in Logic Pro's Control Bar. Customize the Control Bar to show Autopunch, then retry.",
                extras: [
                    "button": "Autopunch",
                    "operation": "transport.toggle_autopunch",
                    "control_bar_present": controlBar != nil,
                    "control_bar_checkboxes": controlBar.map {
                        transportLandmarkLabels(root: $0, role: kAXCheckBoxRole, runtime: runtime)
                    } ?? [],
                    "recovery_hint": "Customize Logic Pro's Control Bar and enable the Autopunch button."
                ]
            ))
        }

        let before = controlBarCheckboxValue(button, runtime: runtime)
        let pressed = AXHelpers.performAction(button, kAXPressAction, runtime: runtime.ax)
        guard pressed else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "AXPress failed on Control Bar Autopunch",
                extras: [
                    "button": "Autopunch",
                    "operation": "transport.toggle_autopunch",
                    "action": "axpress",
                    "safe_to_retry": true
                ]
            ))
        }

        let after: Bool?
        if let before {
            after = waitForControlBarCheckboxValue(
                button,
                runtime: runtime,
                matching: { $0 != before }
            ) ?? controlBarCheckboxValue(button, runtime: runtime)
        } else {
            after = controlBarCheckboxValue(button, runtime: runtime)
        }

        var extras: [String: Any] = [
            "button": "Autopunch",
            "control": AXLocalePolicy.transportAutopunchControl.canonical,
            "operation": "transport.toggle_autopunch",
            "action": "axpress",
            "previous": before as Any? ?? NSNull(),
            "observed": after as Any? ?? NSNull()
        ]

        guard let before, let after else {
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: extras
            ))
        }

        let requested = !before
        extras["requested"] = requested
        if after == requested {
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        return .success(HonestContract.encodeStateB(
            reason: .readbackMismatch,
            extras: extras
        ))
    }

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
                hint: "control-bar checkbox '\(english)' did not change after AXPress / AXConfirm attempts",
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
            hint: "control-bar checkbox '\(english)' did not reach desired=\(desired) after AXPress / AXConfirm attempts",
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
        // ADR-001 coordinate ban: the control-bar checkboxes are actuated by
        // AXPress/AXConfirm only. The former mouse-click (element-derived HID
        // click) rung is removed — Cycle/Metronome retain keycmd (C/K) channel
        // fallbacks and Count-In routes native AXPress-first (#255), so the
        // non-coordinate paths preserve full function. `mouseRuntime` is left in
        // the signature (still threaded by the test doubles) but is no longer
        // read here; a clear-win control-bar toggle must never post a mouse event.
        _ = mouseRuntime
        return [
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
