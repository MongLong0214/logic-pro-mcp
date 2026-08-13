import ApplicationServices
import AppKit
import Darwin
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

    /// Set the playhead to a specific bar through Logic's `탐색 → 이동 → 위치…`
    /// dialog. The Control Bar's `bar` slider is deliberately not used as a
    /// fallback: in Logic 12.3 its AX value is a relative increment rather than
    /// an absolute musical bar number.
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
        executeDialogScript: (@Sendable (String) async -> ChannelResult)? = nil,
        reconcileAfterDialogExecutionFailure: (@Sendable () async -> Bool)? = nil,
        createDialogIssuanceLedger: @escaping @Sendable () -> DialogIssuanceLedger? = DialogIssuanceLedger.create
    ) async -> ChannelResult {
        var requestedPosition: String? = nil
        if let barStr = params["bar"], let b = Int(barStr) {
            guard (1...9999).contains(b) else {
                return .error(HonestContract.encodeStateC(
                    error: .invalidParams,
                    hint: "goto_position requires 'bar' (Int 1..9999) or 'position' (B.B.S.S)"
                ))
            }
            requestedPosition = "\(b).1.1.1"
        } else if let pos = params["position"] {
            if pos.contains(":") {
                return .error("AX gotoPosition cannot handle timecode (use MCU mmc_locate)")
            }
            let parts = pos.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4,
                  let b = Int(parts[0]), (1...9999).contains(b),
                  let beat = Int(parts[1]), (1...16).contains(beat),
                  let subdivision = Int(parts[2]), (1...16).contains(subdivision),
                  let tick = Int(parts[3]), (1...999).contains(tick)
            else {
                return .error(HonestContract.encodeStateC(
                    error: .invalidParams,
                    hint: "goto_position requires 'bar' (Int 1..9999) or 'position' (B.B.S.S)"
                ))
            }
            // Keep the caller's complete request. The dialog must never silently replace its
            // beat/subdivision/tick components with defaults.
            requestedPosition = "\(b).\(beat).\(subdivision).\(tick)"
        }
        guard let requestedPosition
        else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "goto_position requires 'bar' (Int 1..9999) or 'position' (B.B.S.S)"
            ))
        }

        var baseExtras: [String: Any] = ["requested": requestedPosition]

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
                    "method": "ax_goto_position_dialog",
                    "frontmost_preparation": preparation.rawValue,
                    "write_attempted": false,
                    "safe_to_retry": true,
                ]) { _, new in new }
            ))
        }
        // Record it on the success paths too: a receipt that only mentions the gate when it refuses
        // cannot show that a successful run had to bring Logic forward first.
        baseExtras["frontmost_preparation"] = preparation.rawValue

        // An absence/appearance transition can identify this run's modal only while another server
        // process is not performing the same protocol. This advisory lock is released by the OS if
        // its owner exits; a contender refuses before any leaf click rather than sharing a dialog.
        // `executeDialogScript` is the unit-test-only protocol seam. Production callers use the
        // runtime executor and therefore always take the cross-process ownership lock.
        let dialogExecutionLock = executeDialogScript == nil
            ? GoToPositionDialogExecutionLock.acquire()
            : nil
        guard executeDialogScript != nil || dialogExecutionLock != nil else {
            return .error(HonestContract.encodeStateC(
                error: .mutatingOperationInProgress,
                hint: "Another Go To Position request is resolving Logic's modal dialog; retry after it completes.",
                extras: baseExtras.merging([
                    "operation": "transport.goto_position",
                    "method": "dialog",
                    "write_attempted": false,
                    "safe_to_retry": true,
                ]) { _, new in new }
            ))
        }
        defer { dialogExecutionLock?.release() }

        // The AX runtime owns the script seam. Calling `AppleScriptChannel` here would make a
        // custom runtime only partially injectable and could run a real Logic dialog in a unit
        // test. Production retains this route's measured eight-second budget; a custom runtime
        // without a timeout-specific override delegates to its injected `executeAppleScript`.
        let dialogScriptExecutor: @Sendable (String) async -> ChannelResult
        if let executeDialogScript {
            dialogScriptExecutor = executeDialogScript
        } else {
            dialogScriptExecutor = { script in
                await runtime.executeAppleScriptWithTimeout(script, 8.0)
            }
        }
        // Reconciliation is part of the same injected runtime as dialog execution. Otherwise a
        // fake runtime that omits this optional test seam can launch live osascript while cleaning
        // up a deliberately failed fixture.
        let dialogFailureReconciler: @Sendable () async -> Bool
        if let reconcileAfterDialogExecutionFailure {
            dialogFailureReconciler = reconcileAfterDialogExecutionFailure
        } else {
            dialogFailureReconciler = {
                await observeAndClearStrayGoToPositionUI(
                    executeScript: { script, timeout in
                        await runtime.executeAppleScriptWithTimeout(script, timeout)
                    }
                ) == .closed
            }
        }
        let dialogResult = await gotoPositionViaDialog(
            position: requestedPosition,
            executeScript: dialogScriptExecutor,
            reconcileAfterExecutionFailure: dialogFailureReconciler,
            createIssuanceLedger: createDialogIssuanceLedger
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
           classification.requiresFallbackSuppression {
            // A normal global-input result or a dead child after a durable UI/input boundary leaves
            // the target indeterminate, so another position actuator remains unsafe. The boundary
            // does not prove a Return was sent: only a normal script result can claim a submission.
            let dialogState = classification.cleanupObservedClosed ? "closed" : "unobserved"
            var extras = baseExtras.merging([
                "operation": "transport.goto_position",
                "method": "dialog",
                "dialog_route_outcome": classification.diagnosticLabel,
                "dialog_actuation_attempted": classification.dialogActuationMayHaveOccurred,
                "dialog_cleanup": dialogState,
                "safe_to_retry": false,
                "fallback_unsafe": true,
            ]) { _, new in new }
            switch classification.globalInputEvidence {
            case .attempted:
                extras["dialog_input_attempted"] = true
                if let inputBoundary = classification.globalInputBoundary {
                    extras["dialog_input_boundary"] = inputBoundary.rawValue
                }
                extras["dialog_input_target"] = "unknown"
                // The marker is written before the global event. A child can die immediately
                // afterwards, so this is deliberately conservative rather than a claim that the
                // observed Go To Position window consumed the input.
                extras["write_attempted"] = true
            case .indeterminate:
                // A durable marker is written before a global key, not after it. A dead child
                // can leave that marker without ever reaching the key (including when no child
                // spawned), so preserve the uncertainty instead of calling it an attempt.
                extras["dialog_input_indeterminate"] = true
                if let inputBoundary = classification.globalInputBoundary {
                    extras["dialog_input_boundary"] = inputBoundary.rawValue
                }
                extras["dialog_input_target"] = "unknown"
                extras["write_attempted_indeterminate"] = true
            case .notAttempted:
                break
            }
            switch classification.dialogSubmissionEvidence {
            case .attempted:
                extras["dialog_submission_attempted"] = true
                extras["write_attempted"] = true
            case .indeterminate:
                extras["dialog_submission_indeterminate"] = true
            case .notAttempted where classification.globalInputEvidence
                != GotoPositionDialogResultClassification.DialogInputEvidence.notAttempted:
                // The completed script proved it did not advance to RETURN_ARMED, but an earlier
                // global key may already have changed whichever target owned focus.
                extras["dialog_submission_attempted"] = false
            case .notAttempted:
                extras["dialog_submission_indeterminate"] = true
            }
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: extras
            ))
        }
        if case let .failed(classification) = dialogResult,
           classification.requiresUnsafeUIRefusal {
            // The normal script proved no Return was sent, but could not prove that the menu or
            // dialog closed. Do not let an unknown focus target receive any later position write.
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "The Go To Position menu or dialog was not observed closed; no later position route was attempted.",
                extras: baseExtras.merging([
                    "operation": "transport.goto_position",
                    "method": "dialog",
                    "dialog_route_outcome": classification.diagnosticLabel,
                    "menu_state": "could_not_be_closed",
                    "menu_actuation_attempted": classification.menuActuationAttemptedBeforeUnsafeRefusal,
                    "dialog_actuation_attempted": classification.dialogActuationMayHaveOccurred,
                    // Stated on this path too, and stated as false. The refusal above is about
                    // cleanup, not about submission: a caller reading only `dialog_actuation_
                    // attempted` cannot tell "we opened the dialog and never typed into it" from
                    // "we typed and cannot confirm". A field that appears on one refusal and is
                    // absent on the neighbouring one is not a contract.
                    "dialog_submission_attempted": false,
                    "dialog_cleanup": classification.cleanupObservedClosed ? "closed" : "unobserved",
                    "write_attempted": false,
                    "safe_to_retry": false,
                    "fallback_unsafe": true,
                ]) { _, new in new }
            ))
        }

        if case let .failed(classification) = dialogResult {
            baseExtras["dialog_route_outcome"] = classification.diagnosticLabel
        }

        // Logic Pro 12.3 exposes the `bar` control as a relative increment, not an absolute musical
        // bar number. This route neither resolved nor wrote a position slider, so do not label this
        // failure as a slider write. A non-terminal State C lets independently position-capable
        // later channels run.
        return .error(HonestContract.encodeStateC(
            error: .notSupported,
            hint: "The Go To Position dialog did not submit a position, and no alternative position route was taken.",
            extras: baseExtras.merging([
                "operation": "transport.goto_position",
                "position_route": "unavailable",
                "unobserved_position_components": ["bar", "beat", "subdivision", "tick"],
                "unexpressed_position_components": ["bar", "beat", "subdivision", "tick"],
                "write_attempted": false,
                "safe_to_retry": true,
            ]) { _, new in new }
        ))
    }

    /// Move the playhead to `bar` via Logic Pro 12's `탐색 → 이동 → 위치…`
    /// (Navigate → Go To → Position) dialog. Reliable because the dialog auto-
    /// extends project length; however the menu item is disabled when no
    /// regions exist yet, in which case the caller may use another position-capable channel.
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

    /// Cross-process ownership for the absence → leaf → appearance transition. The advisory POSIX
    /// lock cannot be re-entered by a second MCP server process and the kernel releases it if the
    /// owner exits, so a dead server cannot leave a stale dialog-ownership claim behind.
    private final class GoToPositionDialogExecutionLock {
        private let fileDescriptor: Int32

        private init(fileDescriptor: Int32) {
            self.fileDescriptor = fileDescriptor
        }

        static func acquire() -> GoToPositionDialogExecutionLock? {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("logic-pro-mcp-goto-position-dialog.lock").path
            let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return nil }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                return nil
            }
            return GoToPositionDialogExecutionLock(fileDescriptor: descriptor)
        }

        func release() {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }

    /// The script is internal so the menu-validation regression tests can assert the
    /// exact generated AppleScript ordering without invoking Logic Pro.
    static func gotoPositionViaDialogAppleScript(bar: Int) -> String {
        gotoPositionViaDialogAppleScript(position: "\(bar).1.1.1")
    }

    /// The optional ledger is owned by the Swift parent, not by `osascript`. The child advances it
    /// immediately *before* each irreversible UI boundary so a timeout cannot erase the fact that
    /// the child may already have issued it.
    static func gotoPositionViaDialogAppleScript(
        position: String,
        issuanceLedgerPath: String? = nil
    ) -> String {
        // Poll for the dialog's presence instead of relying on a fixed delay.
        // Without this guard, a slow machine (>500ms to render the dialog) would
        // send Cmd+A to the arrange area, selecting all regions unexpectedly.
        let logicProAppleScript = LogicProTarget.appleScriptTarget()
        let ledgerPath = issuanceLedgerPath ?? ""
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

        -- Check the global owner on both sides of the menu observation immediately before
        -- Escape. System Events cannot make those reads atomic with the global key, but this
        -- bracket rejects a handoff that happens while resolving the menu and leaves only the
        -- irreducible interval after the final read.
        on menuEscapeFocusState(theProcess)
            using terms from application "System Events"
                tell theProcess
                    try
                        set logicWasFrontmost to frontmost
                        if logicWasFrontmost is not true then return "NOT_FRONTMOST"
                        set menuState to my menuOpenState(theProcess)
                        if menuState is not "OPEN" then return menuState
                        set logicIsStillFrontmost to frontmost
                        if logicIsStillFrontmost is not true then return "NOT_FRONTMOST"
                        return "FOCUSED"
                    on error
                        return "UNREADABLE"
                    end try
                end tell
            end using terms from
        end menuEscapeFocusState

        -- Never claim that Escape cleaned up a menu until AXSelected says so.
        -- Three attempts are enough to cover a menu/submenu chain without
        -- turning a failed close into an unbounded retry.
        -- `knownOpen` says whether THIS run has issued its resolved leaf. Before that boundary,
        -- UNREADABLE returns without Escape because unknown focus might be an unrelated dialog/edit;
        -- the caller must refuse rather than treating the missing read as clean. After this run
        -- clicked, an unreadable read is not permission to skip Escape, because this run may leave
        -- its own menu chain up.
        on dismissOpenMenu(theProcess, knownOpen)
            set menuState to my menuOpenState(theProcess)
            if menuState is "CLOSED" then return "CLOSED"
            if menuState is "UNREADABLE" and not knownOpen then return "UNREADABLE"
            if menuState is not "OPEN" and menuState is not "UNREADABLE" then return menuState
            repeat 3 times
                set menuFocusState to my menuEscapeFocusState(theProcess)
                if menuFocusState is not "FOCUSED" then return menuFocusState
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

        -- The parent creates this file before launching osascript and reads it after the child
        -- exits or is killed. Write a sibling temporary file and atomically rename it over the
        -- ledger: killing the child during a marker update must leave the prior conservative
        -- marker intact, never truncate the ledger to an empty/unknown value.
        on recordDialogIssuance(stage, ledgerPath)
            if ledgerPath is "" then return true
            set temporaryLedgerPath to ""
            try
                set temporaryLedgerPath to do shell script "/usr/bin/mktemp " & quoted form of (ledgerPath & ".tmp.XXXXXX")
                do shell script "/usr/bin/printf %s " & quoted form of stage & " > " & quoted form of temporaryLedgerPath & " && /bin/mv -f " & quoted form of temporaryLedgerPath & " " & quoted form of ledgerPath
                return true
            on error
                if temporaryLedgerPath is not "" then
                    try
                        do shell script "/bin/rm -f " & quoted form of temporaryLedgerPath
                    end try
                end if
                return false
            end try
        end recordDialogIssuance

        -- Appending this context lets the Swift receipt distinguish an unsafe
        -- entry cleanup (no operation actuation) from an unsafe cleanup after a
        -- menu click. It is deliberately attached only to refusal results.
        on menuCleanupActuationContext(menuActuationAttempted)
            if menuActuationAttempted then return " after menu actuation"
            return ""
        end menuCleanupActuationContext

        -- Logic 12.3 measures Go To Position as AXFloatingWindow with AXModal=true.
        -- These measured subroles remain the KNOWN, operable set. Exact-title windows outside
        -- that set are deliberately handled by goToPositionDialogState as possibly blocking;
        -- this matcher must not turn an unfamiliar future subrole into an input target.
        on knownGoToPositionDialogSubrole(dialogSubrole)
            if dialogSubrole is "AXFloatingWindow" or dialogSubrole is "AXDialog" or dialogSubrole is "AXSystemDialog" then return true
            return false
        end knownGoToPositionDialogSubrole

        -- Capture every pre-leaf window by element identity. A track or plug-in editor can be
        -- titled "Go To Position", so title/subrole/modality alone cannot say that a window belongs
        -- to this request. The input target must be a matching window that appeared after this
        -- run's resolved leaf click.
        on goToPositionWindowSnapshot(theProcess)
            using terms from application "System Events"
                tell theProcess
                    try
                        return every window
                    on error
                        return "UNREADABLE"
                    end try
                end tell
            end using terms from
        end goToPositionWindowSnapshot

        on windowWasPresentBefore(dialogWindow, preLeafWindows)
            repeat with preLeafWindow in preLeafWindows
                try
                    if contents of preLeafWindow is dialogWindow then return true
                end try
            end repeat
            return false
        end windowWasPresentBefore

        -- Find only an operable, modal Go To Position window that this leaf could have opened.
        -- Pre-existing same-titled windows are skipped before reading their subrole or AXModal, so
        -- an unrelated plug-in editor with an unreadable modality cannot block this request.
        on matchingGoToPositionDialog(theProcess, preLeafWindows)
            if preLeafWindows is "UNREADABLE" then return "UNREADABLE"
            using terms from application "System Events"
                tell theProcess
                    try
                        repeat with dialogWindow in every window
                            set candidateWindow to contents of dialogWindow
                            set dialogTitle to name of dialogWindow
                            if dialogTitle is "위치로 이동" or dialogTitle is "Go To Position" or dialogTitle is "Go to Position" then
                                if not my windowWasPresentBefore(candidateWindow, preLeafWindows) then
                                    set dialogSubrole to subrole of dialogWindow
                                    if my knownGoToPositionDialogSubrole(dialogSubrole) then
                                        set dialogIsModal to value of attribute "AXModal" of dialogWindow
                                        if dialogIsModal is true then return candidateWindow
                                    end if
                                end if
                            end if
                        end repeat
                        return missing value
                    on error
                        return "UNREADABLE"
                    end try
                end tell
            end using terms from
        end matchingGoToPositionDialog

        -- The Go To Position dialog has its own lifecycle; a menu-bar observation says nothing
        -- about whether a titled modal is still blocking the arrange area. `AXModal` answers
        -- whether the measured known class is modal; subrole only classifies that class. This
        -- state is intentionally about the exact element newly observed for this run, never a
        -- title-only scan that can confuse an unrelated same-titled plug-in window for our dialog.
        on goToPositionDialogState(theProcess, dialogWindow)
            using terms from application "System Events"
                tell theProcess
                    try
                        if dialogWindow is missing value then return "CLOSED"
                        if not (exists dialogWindow) then return "CLOSED"
                        set dialogTitle to name of dialogWindow
                        if dialogTitle is not "위치로 이동" and dialogTitle is not "Go To Position" and dialogTitle is not "Go to Position" then return "CLOSED"
                        set dialogSubrole to subrole of dialogWindow
                        if not my knownGoToPositionDialogSubrole(dialogSubrole) then return "OPEN_UNKNOWN_SUBROLE"
                        try
                            set dialogIsModal to value of attribute "AXModal" of dialogWindow
                        on error
                            return "OPEN_UNREADABLE"
                        end try
                        if dialogIsModal is true then return "OPEN"
                        return "OPEN_UNVERIFIED_MODALITY"
                    on error
                        return "UNREADABLE"
                    end try
                end tell
            end using terms from
        end goToPositionDialogState

        -- System Events exposes keystroke only globally, not as an action on a
        -- window/text element. Bracket the exact process-local AXFocusedWindow read with global
        -- frontmost checks immediately before each key sequence. The second read catches a
        -- handoff during element resolution; only the unavoidable interval after it remains.
        on observedGoToPositionDialogFocusState(theProcess, dialogWindow)
            using terms from application "System Events"
                tell theProcess
                    try
                        set logicWasFrontmost to frontmost
                        if logicWasFrontmost is not true then return "NOT_FRONTMOST"
                        if not (exists dialogWindow) then return "MISSING"
                        set dialogTitle to name of dialogWindow
                        set dialogSubrole to subrole of dialogWindow
                        if dialogTitle is not "위치로 이동" and dialogTitle is not "Go To Position" and dialogTitle is not "Go to Position" then return "MISSING"
                        if not my knownGoToPositionDialogSubrole(dialogSubrole) then return "MISSING"
                        set dialogIsModal to value of attribute "AXModal" of dialogWindow
                        if dialogIsModal is not true then return "NOT_MODAL"
                        if not (exists attribute "AXFocusedWindow") then return "UNREADABLE"
                        set processFocusedWindow to value of attribute "AXFocusedWindow"
                        if processFocusedWindow is not dialogWindow then return "NOT_FOCUSED"
                        set logicIsStillFrontmost to frontmost
                        if logicIsStillFrontmost is not true then return "NOT_FRONTMOST"
                        return "FOCUSED"
                    on error
                        return "UNREADABLE"
                    end try
                end tell
            end using terms from
        end observedGoToPositionDialogFocusState

        -- Prefer this modal's localized Cancel button.  Escape is only a
        -- fallback while this exact dialog is observed open, and every attempt
        -- must be followed by a new exact-dialog observation before it counts
        -- as cleanup.
        on pressGoToPositionDialogCancel(theProcess, dialogWindow)
            using terms from application "System Events"
                tell theProcess
                    try
                        set dialogState to my goToPositionDialogState(theProcess, dialogWindow)
                        if dialogState is not "OPEN" then return dialogState
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
                    on error
                        return "UNREADABLE"
                    end try
                end tell
            end using terms from
        end pressGoToPositionDialogCancel

        on dismissOpenGoToPositionDialog(theProcess, dialogWindow)
            set dialogState to my goToPositionDialogState(theProcess, dialogWindow)
            if dialogState is "CLOSED" then return "CLOSED"
            if dialogState is not "OPEN" then return dialogState
            repeat 3 times
                set cancelOutcome to my pressGoToPositionDialogCancel(theProcess, dialogWindow)
                if cancelOutcome is "NO_BUTTON" or cancelOutcome is "UNREADABLE" then
                    -- The Cancel click may have landed even though AX reported failure. Re-observe
                    -- this exact dialog before choosing Escape as a second actuator; unreadable is
                    -- not permission to send a key into an unknown focus target.
                    set dialogState to my goToPositionDialogState(theProcess, dialogWindow)
                    if dialogState is "CLOSED" then return "CLOSED"
                    if dialogState is "UNREADABLE" then return "OPEN_UNREADABLE"
                    if dialogState is not "OPEN" then return dialogState
                    set cleanupDialogFocusState to my observedGoToPositionDialogFocusState(theProcess, dialogWindow)
                    if cleanupDialogFocusState is not "FOCUSED" then return cleanupDialogFocusState
                    using terms from application "System Events"
                        tell theProcess to key code 53
                    end using terms from
                end if
                delay 0.1
                set dialogState to my goToPositionDialogState(theProcess, dialogWindow)
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
                -- A timed-out predecessor or user action can leave a menu open. An unreadable
                -- entry read is not evidence that the menu is absent, so it must not release a
                -- later position actuation. `knownOpen:false` deliberately withholds Escape when
                -- focus is unknown.
                set entryMenuCleanup to my dismissOpenMenu(logicProcess, false)
                if entryMenuCleanup is not "CLOSED" then
                    return "MENU_PICK_FAILED: menu state was not observed closed at entry (" & entryMenuCleanup & ")"
                end if
                set menuActuationAttempted to false
                -- This records whether the resolved leaf actuation was issued. The
                -- leaf may succeed even if AX reports an error, so any result
                -- after it becomes true must not release another position route.
                set dialogActuationIssued to false
                delay 0.2

                -- Locale selection is a read-only path-resolution step. It
                -- deliberately performs no click, so an AX error cannot turn a
                -- Korean attempt into a second English menu actuation.
                try
                    if exists menu item "위치…" of menu 1 of menu item "이동" of menu 1 of menu bar item "탐색" of menu bar 1 then
                        set selectedLocaleChain to "KOREAN"
                    else if exists menu item "Position…" of menu 1 of menu item "Go To" of menu 1 of menu bar item "Navigate" of menu bar 1 then
                        set selectedLocaleChain to "ENGLISH"
                    else
                        -- No menu has been opened by this run. If the read is unreadable,
                        -- `knownOpen:false` must not send Escape into an unrelated focus target.
                        set cleanupState to my dismissOpenMenu(logicProcess, false)
                        if cleanupState is not "CLOSED" then
                            return "MENU_PICK_FAILED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                        end if
                        return "MENU_NOT_FOUND"
                    end if
                on error errMsg
                    -- Locale discovery is read-only; do not claim an unknown menu belongs to
                    -- this run and do not authorise Escape from an unreadable AX observation.
                    set cleanupState to my dismissOpenMenu(logicProcess, false)
                    if cleanupState is not "CLOSED" then
                        return "MENU_PICK_FAILED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                    end if
                    return "MENU_NOT_FOUND: " & errMsg
                end try
                try
                    if selectedLocaleChain is "KOREAN" then
                        set menuItemEnabled to enabled of menu item "위치…" of menu 1 of menu item "이동" of menu 1 of menu bar item "탐색" of menu bar 1
                    else
                        set menuItemEnabled to enabled of menu item "Position…" of menu 1 of menu item "Go To" of menu 1 of menu bar item "Navigate" of menu bar 1
                    end if
                on error
                    -- An unreadable AXEnabled must not authorise the pick.
                    set cleanupState to my dismissOpenMenu(logicProcess, false)
                    if cleanupState is not "CLOSED" then
                        return "MENU_PICK_FAILED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                    end if
                    return "MENU_STATE_UNREADABLE"
                end try
                if not menuItemEnabled then
                    set cleanupState to my dismissOpenMenu(logicProcess, false)
                    if cleanupState is not "CLOSED" then
                        return "MENU_PICK_FAILED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                    end if
                    return "MENU_DISABLED"
                end if
                -- The window identity snapshot, not its title, is the first half of this run's
                -- absence → leaf → appearance transition. A pre-existing plug-in editor may use
                -- the same title (and even AXDialog), but can never become this run's input target.
                set observedGoToPositionDialog to missing value
                set preLeafGoToPositionWindows to my goToPositionWindowSnapshot(logicProcess)
                if preLeafGoToPositionWindows is "UNREADABLE" then
                    return "DIALOG_PREEXISTENCE_UNREADABLE: Go To Position window snapshot was unreadable before leaf click"
                end if
                try
                    -- Persist before AXPress: if the child dies after the click, Swift still knows
                    -- that the dialog route may have become active and must not choose another route.
                    if not my recordDialogIssuance("LEAF_ARMED", "\(ledgerPath)") then
                        set cleanupState to my dismissOpenMenu(logicProcess, false)
                        if cleanupState is not "CLOSED" then
                            return "MENU_PICK_FAILED: menu cleanup was not observed (" & cleanupState & ")"
                        end if
                        return "MENU_PICK_FAILED: could not persist dialog issuance before leaf click"
                    end if
                    set menuActuationAttempted to true
                    set dialogActuationIssued to true
                    if selectedLocaleChain is "KOREAN" then
                        click menu item "위치…" of menu 1 of menu item "이동" of menu 1 of menu bar item "탐색" of menu bar 1
                    else
                        click menu item "Position…" of menu 1 of menu item "Go To" of menu 1 of menu bar item "Navigate" of menu bar 1
                    end if
                on error errMsg
                    set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog)
                    if dialogCleanupState is not "CLOSED" then
                        return "DIALOG_ACTUATION_ISSUED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                    end if
                    set cleanupState to my dismissOpenMenu(logicProcess, true)
                    if cleanupState is not "CLOSED" then
                        return "DIALOG_ACTUATION_ISSUED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                    end if
                    return "DIALOG_ACTUATION_ISSUED: " & errMsg
                end try
                -- Wait up to 3s for a new exact modal dialog to appear before typing. The
                -- pre-leaf absence plus this observed element prevents a stale/concurrent
                -- same-titled window from being accepted as this request's dialog.
                set dialogReady to false
                set dialogAppearanceUnreadable to false
                set observedGoToPositionDialog to missing value
                repeat 30 times
                    delay 0.1
                    set observedGoToPositionDialog to my matchingGoToPositionDialog(logicProcess, preLeafGoToPositionWindows)
                    if observedGoToPositionDialog is "UNREADABLE" then
                        set dialogAppearanceUnreadable to true
                        exit repeat
                    end if
                    if observedGoToPositionDialog is not missing value then
                        set dialogReady to true
                        exit repeat
                    end if
                end repeat
                if not dialogReady then
                    set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog)
                    if dialogCleanupState is not "CLOSED" then
                        return "DIALOG_ACTUATION_ISSUED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                    end if
                    set cleanupState to my dismissOpenMenu(logicProcess, true)
                    if cleanupState is not "CLOSED" then
                        return "DIALOG_ACTUATION_ISSUED: menu cleanup was not observed" & my menuCleanupActuationContext(menuActuationAttempted) & " (" & cleanupState & ")"
                    end if
                    if dialogAppearanceUnreadable then return "DIALOG_ACTUATION_ISSUED: dialog appearance became unreadable"
                    return "DIALOG_ACTUATION_ISSUED: dialog did not become ready"
                end if
            end tell
            -- Everything in this block is before Return, but System Events keyboard input is
            -- global. Once an input boundary is durably armed, a normal result must report that
            -- it may have reached an unknown target rather than advertising a clean retry.
            try
                if not my recordDialogIssuance("SELECT_ALL_ARMED", "\(ledgerPath)") then
                    set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog)
                    if dialogCleanupState is not "CLOSED" then
                        return "DIALOG_SUBMISSION_NOT_ISSUED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                    end if
                    set cleanupState to my dismissOpenMenu(logicProcess, true)
                    if cleanupState is not "CLOSED" then
                        return "DIALOG_SUBMISSION_NOT_ISSUED: menu cleanup was not observed (" & cleanupState & ")"
                    end if
                    return "DIALOG_SUBMISSION_NOT_ISSUED: could not persist Cmd+A issuance"
                end if
                -- The durable marker precedes the irreversible key. Re-read global application
                -- focus after that file operation so Cmd+A cannot land in an app that became
                -- frontmost while this run was preparing the receipt.
                set dialogFocusState to my observedGoToPositionDialogFocusState(logicProcess, observedGoToPositionDialog)
                if dialogFocusState is not "FOCUSED" then
                    set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog)
                    if dialogCleanupState is not "CLOSED" then
                        return "DIALOG_SUBMISSION_NOT_ISSUED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                    end if
                    set cleanupState to my dismissOpenMenu(logicProcess, true)
                    if cleanupState is not "CLOSED" then
                        return "DIALOG_SUBMISSION_NOT_ISSUED: menu cleanup was not observed (" & cleanupState & ")"
                    end if
                    return "DIALOG_SUBMISSION_NOT_ISSUED: observed Go To Position dialog was not focused before typing (" & dialogFocusState & ")"
                end if
                keystroke "a" using command down
                delay 0.1
            on error errMsg
                set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog)
                if dialogCleanupState is not "CLOSED" then
                    return "DIALOG_INPUT_ISSUED: SELECT_ALL_ARMED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                end if
                set cleanupState to my dismissOpenMenu(logicProcess, true)
                if cleanupState is not "CLOSED" then
                    return "DIALOG_INPUT_ISSUED: SELECT_ALL_ARMED: menu cleanup was not observed (" & cleanupState & ")"
                end if
                return "DIALOG_INPUT_ISSUED: SELECT_ALL_ARMED: Cmd+A may have been sent (" & errMsg & ")"
            end try

            try
                if not my recordDialogIssuance("POSITION_INPUT_ARMED", "\(ledgerPath)") then
                    set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog)
                    if dialogCleanupState is not "CLOSED" then
                        return "DIALOG_INPUT_ISSUED: SELECT_ALL_ARMED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                    end if
                    set cleanupState to my dismissOpenMenu(logicProcess, true)
                    if cleanupState is not "CLOSED" then
                        return "DIALOG_INPUT_ISSUED: SELECT_ALL_ARMED: menu cleanup was not observed (" & cleanupState & ")"
                    end if
                    return "DIALOG_INPUT_ISSUED: SELECT_ALL_ARMED: could not persist position input issuance"
                end if
                -- Re-read focus after persisting this input marker and immediately before the
                -- global position text, not merely after the preceding Cmd+A.
                set dialogTypingFocusState to my observedGoToPositionDialogFocusState(logicProcess, observedGoToPositionDialog)
                if dialogTypingFocusState is not "FOCUSED" then
                    set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog)
                    if dialogCleanupState is not "CLOSED" then
                        return "DIALOG_INPUT_ISSUED: SELECT_ALL_ARMED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                    end if
                    set cleanupState to my dismissOpenMenu(logicProcess, true)
                    if cleanupState is not "CLOSED" then
                        return "DIALOG_INPUT_ISSUED: SELECT_ALL_ARMED: menu cleanup was not observed (" & cleanupState & ")"
                    end if
                    return "DIALOG_INPUT_ISSUED: SELECT_ALL_ARMED: observed Go To Position dialog was not focused before typing (" & dialogTypingFocusState & ")"
                end if
                keystroke "\(position)"
                delay 0.1
            on error errMsg
                set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog)
                if dialogCleanupState is not "CLOSED" then
                    return "DIALOG_INPUT_ISSUED: POSITION_INPUT_ARMED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                end if
                set cleanupState to my dismissOpenMenu(logicProcess, true)
                if cleanupState is not "CLOSED" then
                    return "DIALOG_INPUT_ISSUED: POSITION_INPUT_ARMED: menu cleanup was not observed (" & cleanupState & ")"
                end if
                return "DIALOG_INPUT_ISSUED: POSITION_INPUT_ARMED: position text may have been sent (" & errMsg & ")"
            end try

            -- POSITION_INPUT_ARMED above is the text-write boundary. This separate marker is the
            -- Return submission boundary, so a timeout or nonzero child exit after either point is
            -- conservatively reported rather than releasing another actuator.
            if not my recordDialogIssuance("RETURN_ARMED", "\(ledgerPath)") then
                set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog)
                if dialogCleanupState is not "CLOSED" then
                    return "DIALOG_INPUT_ISSUED: POSITION_INPUT_ARMED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                end if
                set cleanupState to my dismissOpenMenu(logicProcess, true)
                if cleanupState is not "CLOSED" then
                    return "DIALOG_INPUT_ISSUED: POSITION_INPUT_ARMED: menu cleanup was not observed (" & cleanupState & ")"
                end if
                return "DIALOG_INPUT_ISSUED: POSITION_INPUT_ARMED: could not persist Return issuance"
            end if
            -- Return is global too. The focused Logic dialog must still be the global keyboard
            -- owner after its durable marker is written and immediately before submission.
            set dialogReturnFocusState to my observedGoToPositionDialogFocusState(logicProcess, observedGoToPositionDialog)
            if dialogReturnFocusState is not "FOCUSED" then
                set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog)
                if dialogCleanupState is not "CLOSED" then
                    return "DIALOG_INPUT_ISSUED: POSITION_INPUT_ARMED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                end if
                set cleanupState to my dismissOpenMenu(logicProcess, true)
                if cleanupState is not "CLOSED" then
                    return "DIALOG_INPUT_ISSUED: POSITION_INPUT_ARMED: menu cleanup was not observed (" & cleanupState & ")"
                end if
                return "DIALOG_INPUT_ISSUED: POSITION_INPUT_ARMED: observed Go To Position dialog was not focused before Return (" & dialogReturnFocusState & ")"
            end if
            try
                keystroke return
                delay 0.2
            on error errMsg
                set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog)
                if dialogCleanupState is not "CLOSED" then
                    return "DIALOG_SUBMISSION_ISSUED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                end if
                set cleanupState to my dismissOpenMenu(logicProcess, true)
                if cleanupState is not "CLOSED" then
                    return "DIALOG_SUBMISSION_ISSUED: menu cleanup was not observed (" & cleanupState & ")"
                end if
                return "DIALOG_SUBMISSION_ISSUED: Return may have been sent (" & errMsg & ")"
            end try
            -- A normal Return reply is not proof Logic consumed it. Observe this exact modal before
            -- returning OK; if it survived, clean it only after recording the submission boundary.
            set dialogPostReturnState to my goToPositionDialogState(logicProcess, observedGoToPositionDialog)
            if dialogPostReturnState is not "CLOSED" then
                set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog)
                if dialogCleanupState is not "CLOSED" then
                    return "DIALOG_SUBMISSION_ISSUED: dialog cleanup was not observed (" & dialogCleanupState & ")"
                end if
                set cleanupState to my dismissOpenMenu(logicProcess, true)
                if cleanupState is not "CLOSED" then
                    return "DIALOG_SUBMISSION_ISSUED: menu cleanup was not observed (" & cleanupState & ")"
                end if
                return "DIALOG_SUBMISSION_ISSUED: dialog was not observed closed after Return"
            end if
        end tell
        return "OK"
        """
    }

    /// State persisted by the parent-owned issuance ledger. `unknown` is deliberately unsafe: a
    /// missing/corrupt ledger after a dead child is not evidence that the child failed before Return.
    enum DialogIssuanceStage: String, Equatable, Sendable {
        case notIssued = "NOT_ISSUED"
        case leafArmed = "LEAF_ARMED"
        case selectAllArmed = "SELECT_ALL_ARMED"
        case positionInputArmed = "POSITION_INPUT_ARMED"
        case returnArmed = "RETURN_ARMED"
        case unknown
    }

    struct DialogIssuanceLedger: Sendable {
        let url: URL

        static func create() -> DialogIssuanceLedger? {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("logic-pro-mcp-goto-position-\(UUID().uuidString)")
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data(DialogIssuanceStage.notIssued.rawValue.utf8)
            ) else { return nil }
            return DialogIssuanceLedger(url: url)
        }

        var stage: DialogIssuanceStage {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .unknown }
            return DialogIssuanceStage(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
                ?? .unknown
        }

        func remove() {
            // The child may be killed after `mktemp` and before it can rename or clean its sibling.
            // This run's UUID makes the prefix exclusive, so the parent can safely collect those
            // orphaned staging files as well as the canonical ledger.
            let directory = url.deletingLastPathComponent()
            let temporaryPrefix = url.lastPathComponent + ".tmp."
            if let siblings = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) {
                for sibling in siblings where sibling.lastPathComponent.hasPrefix(temporaryPrefix) {
                    try? FileManager.default.removeItem(at: sibling)
                }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The successful AppleScript channel payload is a JSON object containing the script's return
    /// value in `result`. Normal script replies distinguish failures before Return from a Return that
    /// may have landed; execution failures use the parent-owned durable ledger instead.
    enum GotoPositionDialogResultClassification: Equatable {
        enum DialogInputEvidence: Equatable {
            case notAttempted
            case attempted
            case indeterminate
        }

        enum Failure: Equatable {
            case menuNotFound
            case menuStateUnreadable
            case menuDisabled
            case menuPickFailed
            case menuCouldNotBeClosed(writeAttempted: Bool)
            case dialogPreexisting
            case dialogPreexistenceUnreadable
            case dialogNotReady
            case dialogActuationIssued(cleanupObservedClosed: Bool)
            case dialogSubmissionNotIssued(cleanupObservedClosed: Bool)
            case dialogInputIssued(issuance: DialogIssuanceStage, cleanupObservedClosed: Bool)
            case dialogSubmissionIssued(cleanupObservedClosed: Bool)
            case executionFailed(issuance: DialogIssuanceStage, cleanupObservedClosed: Bool)
            case malformedPayload
            case unexpectedResult
        }

        case driven
        case failure(Failure)

        /// Why the dialog route ended, as a fixed structural token. Without this a caller that
        /// reaches the non-dialog route cannot tell whether the dialog route was tried and
        /// abandoned or never reachable.
        var diagnosticLabel: String {
            switch self {
            case .driven: return "driven"
            case .failure(.menuNotFound): return "menu_not_found"
            case .failure(.menuStateUnreadable): return "menu_state_unreadable"
            case .failure(.menuDisabled): return "menu_disabled"
            case .failure(.menuPickFailed): return "menu_pick_failed"
            case let .failure(.menuCouldNotBeClosed(writeAttempted)):
                return "menu_could_not_be_closed_write_attempted_\(writeAttempted)"
            case .failure(.dialogPreexisting): return "dialog_preexisting"
            case .failure(.dialogPreexistenceUnreadable): return "dialog_preexistence_unreadable"
            case .failure(.dialogNotReady): return "dialog_not_ready"
            case let .failure(.dialogActuationIssued(closed)):
                return "dialog_actuation_issued_cleanup_closed_\(closed)"
            case let .failure(.dialogSubmissionNotIssued(closed)):
                return "dialog_submission_not_issued_cleanup_closed_\(closed)"
            case let .failure(.dialogInputIssued(issuance, closed)):
                return "dialog_input_issued_\(issuance.rawValue)_cleanup_closed_\(closed)"
            case let .failure(.dialogSubmissionIssued(closed)):
                return "dialog_submission_issued_cleanup_closed_\(closed)"
            case let .failure(.executionFailed(issuance, closed)):
                return "execution_failed_issuance_\(issuance.rawValue)_cleanup_closed_\(closed)"
            case .failure(.malformedPayload): return "malformed_payload"
            case .failure(.unexpectedResult): return "unexpected_result"
            }
        }

        /// A second position actuator is unsafe after a normal global input or a dead child that
        /// crossed any durable UI/input boundary. LEAF_ARMED is a safety boundary only: it does
        /// not prove a dialog actuation, global input, or position submission occurred.
        var requiresFallbackSuppression: Bool {
            switch self {
            case .failure(.dialogInputIssued),
                 .failure(.dialogSubmissionIssued),
                 .failure(.executionFailed(issuance: .leafArmed, cleanupObservedClosed: _)),
                 .failure(.executionFailed(issuance: .selectAllArmed, cleanupObservedClosed: _)),
                 .failure(.executionFailed(issuance: .positionInputArmed, cleanupObservedClosed: _)),
                 .failure(.executionFailed(issuance: .returnArmed, cleanupObservedClosed: _)),
                 .failure(.executionFailed(issuance: .unknown, cleanupObservedClosed: _)):
                return true
            default:
                return false
            }
        }

        /// A normal script reply reached its key actuation statement. A durable ledger marker is
        /// earlier than that statement, so a dead child leaves the input outcome indeterminate —
        /// including the `unknown` case where ledger creation or reading failed before a spawn
        /// failure proves whether a child ever existed.
        var globalInputEvidence: DialogInputEvidence {
            switch self {
            case .failure(.dialogInputIssued),
                 .failure(.dialogSubmissionIssued):
                return .attempted
            case .failure(.executionFailed(issuance: .selectAllArmed, cleanupObservedClosed: _)),
                 .failure(.executionFailed(issuance: .positionInputArmed, cleanupObservedClosed: _)),
                 .failure(.executionFailed(issuance: .returnArmed, cleanupObservedClosed: _)),
                 .failure(.executionFailed(issuance: .unknown, cleanupObservedClosed: _)):
                return .indeterminate
            default:
                return .notAttempted
            }
        }

        /// The last durable global-input boundary for receipt diagnostics. A normal script result
        /// reports the exact stage; an execution failure reports the last marker safely persisted
        /// before the child exited.
        var globalInputBoundary: DialogIssuanceStage? {
            switch self {
            case let .failure(.dialogInputIssued(issuance, _)):
                return issuance
            case .failure(.dialogSubmissionIssued):
                return .returnArmed
            case let .failure(.executionFailed(issuance, _)) where issuance == .selectAllArmed
                || issuance == .positionInputArmed || issuance == .returnArmed || issuance == .unknown:
                return issuance
            default:
                return nil
            }
        }

        /// A normal script reply reached Return's actuation statement. A parent-owned marker is
        /// deliberately weaker: it precedes Return and therefore represents uncertainty, not an
        /// asserted submission attempt.
        var dialogSubmissionEvidence: DialogInputEvidence {
            switch self {
            case .failure(.dialogSubmissionIssued):
                return .attempted
            case .failure(.executionFailed(issuance: .returnArmed, cleanupObservedClosed: _)),
                 .failure(.executionFailed(issuance: .unknown, cleanupObservedClosed: _)):
                return .indeterminate
            default:
                return .notAttempted
            }
        }

        /// A later position route is unsafe when a non-submission path cannot prove the menu/dialog UI is gone.
        /// A clean, normal leaf or pre-input focus failure may fall through because the script
        /// proved no global input or Return was sent and observed the relevant UI closed.
        var requiresUnsafeUIRefusal: Bool {
            switch self {
            case .failure(.menuCouldNotBeClosed),
                 .failure(.dialogPreexisting),
                 .failure(.dialogPreexistenceUnreadable),
                 .failure(.dialogActuationIssued(cleanupObservedClosed: false)),
                 .failure(.dialogSubmissionNotIssued(cleanupObservedClosed: false)),
                 .failure(.dialogNotReady),
                 .failure(.executionFailed(issuance: .notIssued, cleanupObservedClosed: false)):
                return true
            default:
                return false
            }
        }

        var dialogActuationMayHaveOccurred: Bool {
            switch self {
            case .failure(.dialogNotReady),
                 .failure(.dialogActuationIssued),
                 .failure(.dialogSubmissionNotIssued),
                 .failure(.dialogInputIssued),
                 .failure(.dialogSubmissionIssued),
                 .failure(.executionFailed(issuance: .selectAllArmed, cleanupObservedClosed: _)),
                 .failure(.executionFailed(issuance: .positionInputArmed, cleanupObservedClosed: _)),
                 .failure(.executionFailed(issuance: .returnArmed, cleanupObservedClosed: _)),
                 .failure(.executionFailed(issuance: .unknown, cleanupObservedClosed: _)):
                return true
            default:
                return false
            }
        }

        var cleanupObservedClosed: Bool {
            switch self {
            case let .failure(.dialogActuationIssued(cleanupObservedClosed)),
                 let .failure(.dialogSubmissionNotIssued(cleanupObservedClosed)),
                 let .failure(.dialogInputIssued(issuance: _, cleanupObservedClosed: cleanupObservedClosed)),
                 let .failure(.dialogSubmissionIssued(cleanupObservedClosed)),
                 let .failure(.executionFailed(issuance: _, cleanupObservedClosed)):
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
        case let value where value.hasPrefix("DIALOG_PREEXISTING"):
            return .failure(.dialogPreexisting)
        case let value where value.hasPrefix("DIALOG_PREEXISTENCE_UNREADABLE"):
            return .failure(.dialogPreexistenceUnreadable)
        case let value where value.hasPrefix("MENU_PICK_FAILED"):
            if value.hasPrefix("MENU_PICK_FAILED: menu state was not observed closed at entry")
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
                // A closed dialog is insufficient if a menu cleanup remained unreadable. Both
                // surfaces must be observed closed before this known pre-Return path can fall
                // through to a later position route.
                cleanupObservedClosed: !value.contains("cleanup was not observed")
            ))
        case let value where value.hasPrefix("DIALOG_SUBMISSION_NOT_ISSUED"):
            return .failure(.dialogSubmissionNotIssued(
                cleanupObservedClosed: !value.contains("cleanup was not observed")
            ))
        case let value where value.hasPrefix("DIALOG_INPUT_ISSUED: SELECT_ALL_ARMED"):
            return .failure(.dialogInputIssued(
                issuance: .selectAllArmed,
                cleanupObservedClosed: !value.contains("cleanup was not observed")
            ))
        case let value where value.hasPrefix("DIALOG_INPUT_ISSUED: POSITION_INPUT_ARMED"):
            return .failure(.dialogInputIssued(
                issuance: .positionInputArmed,
                cleanupObservedClosed: !value.contains("cleanup was not observed")
            ))
        case let value where value.hasPrefix("DIALOG_SUBMISSION_ISSUED"):
            return .failure(.dialogSubmissionIssued(
                cleanupObservedClosed: !value.contains("cleanup was not observed")
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
        position: String,
        executeScript: @escaping @Sendable (String) async -> ChannelResult,
        reconcileAfterExecutionFailure: @escaping @Sendable () async -> Bool,
        createIssuanceLedger: @escaping @Sendable () -> DialogIssuanceLedger?
    ) async -> GotoPositionDialogRouteResult {
        let ledger = createIssuanceLedger()
        defer { ledger?.remove() }
        let script = gotoPositionViaDialogAppleScript(
            position: position,
            issuanceLedgerPath: ledger?.url.path
        )
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
                        "requested": position,
                        "via": "dialog",
                        // `OK` is emitted only after the script independently observed the exact
                        // Go To Position dialog closed following Return.
                        "dialog_cleanup": "closed",
                        "dialog_submission_attempted": true,
                        "write_attempted": true,
                    ]
                ))
            case .failure:
                return .failed(classification)
            }
        case .error:
            // Do this even when PID discovery fails. The durable checkpoint records whether the
            // child may have crossed a UI boundary, and a failed reconciliation is never evidence
            // that a dead child left no modal/menu behind.
            let issuance = ledger?.stage ?? .unknown
            let cleanupObservedClosed = await reconcileAfterExecutionFailure()
            return .failed(.failure(.executionFailed(
                issuance: issuance,
                cleanupObservedClosed: cleanupObservedClosed
            )))
        }
    }

    private enum StrayGoToPositionUIOutcome: Equatable { case closed, openOrUnknown }

    /// Reconcile the exact Go To Position modal before considering menu state. A menu-bar read does
    /// not describe a modal dialog, so a post-timeout `CLOSED` menu must never authorise another route
    /// while the dialog remains on screen.
    private static func observeAndClearStrayGoToPositionUI(
        executeScript: @escaping @Sendable (String, TimeInterval) async -> ChannelResult
    ) async -> StrayGoToPositionUIOutcome {
        let target = LogicProTarget.appleScriptTarget()
        let script = """
        on knownGoToPositionDialogSubrole(dialogSubrole)
            if dialogSubrole is "AXFloatingWindow" or dialogSubrole is "AXDialog" or dialogSubrole is "AXSystemDialog" then return true
            return false
        end knownGoToPositionDialogSubrole

        -- Reconciliation has no live AX element from the killed child, so it can only match the
        -- measured modal class. It must never turn a same-titled normal/editor window into a
        -- cleanup target merely because its title collides with the dialog.
        on matchingGoToPositionDialog(theProcess)
            using terms from application "System Events"
                tell theProcess
                    try
                        repeat with dialogWindow in every window
                            set dialogTitle to name of dialogWindow
                            if dialogTitle is "위치로 이동" or dialogTitle is "Go To Position" or dialogTitle is "Go to Position" then
                                set dialogSubrole to subrole of dialogWindow
                                if my knownGoToPositionDialogSubrole(dialogSubrole) then
                                    set dialogIsModal to value of attribute "AXModal" of dialogWindow
                                    if dialogIsModal is true then return contents of dialogWindow
                                end if
                            end if
                        end repeat
                        return missing value
                    on error
                        return "UNREADABLE"
                    end try
                end tell
            end using terms from
        end matchingGoToPositionDialog

        on goToPositionDialogState(theProcess)
            set dialogWindow to my matchingGoToPositionDialog(theProcess)
            if dialogWindow is "UNREADABLE" then return "UNREADABLE"
            if dialogWindow is missing value then return "CLOSED"
            return "OPEN"
        end goToPositionDialogState

        -- System Events keystrokes are global. Re-check frontmost after proving the exact modal
        -- is Logic's AXFocusedWindow so a handoff during AX resolution cannot authorise Escape.
        on observedGoToPositionDialogFocusState(theProcess, dialogWindow)
            using terms from application "System Events"
                tell theProcess
                    try
                        set logicWasFrontmost to frontmost
                        if logicWasFrontmost is not true then return "NOT_FRONTMOST"
                        if not (exists dialogWindow) then return "MISSING"
                        set dialogTitle to name of dialogWindow
                        if dialogTitle is not "위치로 이동" and dialogTitle is not "Go To Position" and dialogTitle is not "Go to Position" then return "MISSING"
                        set dialogSubrole to subrole of dialogWindow
                        if not my knownGoToPositionDialogSubrole(dialogSubrole) then return "MISSING"
                        set dialogIsModal to value of attribute "AXModal" of dialogWindow
                        if dialogIsModal is not true then return "NOT_MODAL"
                        if not (exists attribute "AXFocusedWindow") then return "UNREADABLE"
                        set processFocusedWindow to value of attribute "AXFocusedWindow"
                        if processFocusedWindow is not dialogWindow then return "NOT_FOCUSED"
                        set logicIsStillFrontmost to frontmost
                        if logicIsStillFrontmost is not true then return "NOT_FRONTMOST"
                        return "FOCUSED"
                    on error
                        return "UNREADABLE"
                    end try
                end tell
            end using terms from
        end observedGoToPositionDialogFocusState

        on menuEscapeFocusState(theProcess)
            using terms from application "System Events"
                tell theProcess
                    try
                        set logicWasFrontmost to frontmost
                        if logicWasFrontmost is not true then return "NOT_FRONTMOST"
                        set anyOpen to false
                        repeat with menuBarItem in every menu bar item of menu bar 1
                            if selected of menuBarItem then set anyOpen to true
                        end repeat
                        if not anyOpen then return "CLOSED"
                        set logicIsStillFrontmost to frontmost
                        if logicIsStillFrontmost is not true then return "NOT_FRONTMOST"
                        return "FOCUSED"
                    on error
                        return "UNREADABLE"
                    end try
                end tell
            end using terms from
        end menuEscapeFocusState

        on dismissGoToPositionDialog(theProcess)
            set dialogState to my goToPositionDialogState(theProcess)
            if dialogState is "CLOSED" then return "CLOSED"
            if dialogState is not "OPEN" then return dialogState
            repeat 3 times
                set dialogWindow to my matchingGoToPositionDialog(theProcess)
                if dialogWindow is "UNREADABLE" then return "UNREADABLE"
                if dialogWindow is missing value then return "CLOSED"
                set cancelPressed to false
                using terms from application "System Events"
                    tell theProcess
                        try
                            if exists button "Cancel" of dialogWindow then
                                click button "Cancel" of dialogWindow
                                set cancelPressed to true
                            else if exists button "취소" of dialogWindow then
                                click button "취소" of dialogWindow
                                set cancelPressed to true
                            else if exists button "キャンセル" of dialogWindow then
                                click button "キャンセル" of dialogWindow
                                set cancelPressed to true
                            end if
                        on error
                        end try
                        if not cancelPressed then
                            set cleanupFocusState to my observedGoToPositionDialogFocusState(theProcess, dialogWindow)
                            if cleanupFocusState is not "FOCUSED" then return cleanupFocusState
                            key code 53
                        end if
                    end tell
                end using terms from
                delay 0.1
                set dialogState to my goToPositionDialogState(theProcess)
                if dialogState is "CLOSED" then return "CLOSED"
                if dialogState is not "OPEN" then return dialogState
            end repeat
            return "OPEN"
        end dismissGoToPositionDialog

        tell application "System Events"
            tell \(target.systemEventsProcessTarget)
                try
                    set dialogCleanupState to my dismissGoToPositionDialog(it)
                    if dialogCleanupState is not "CLOSED" then return "DIALOG_" & dialogCleanupState
                    repeat 3 times
                        set menuFocusState to my menuEscapeFocusState(it)
                        if menuFocusState is "CLOSED" then return "CLOSED"
                        if menuFocusState is not "FOCUSED" then return menuFocusState
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
        guard case let .success(payload) = await executeScript(script, 4.0),
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
