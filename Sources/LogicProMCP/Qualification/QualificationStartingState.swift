import ApplicationServices
import CoreGraphics
import Foundation

// The state the live gate must start from.
//
// On Logic 13 a write acts only on the SELECTED track, and the keyboard rungs depend on where the
// keyboard focus is. A gate that starts wherever the last session left Logic therefore fails for
// reasons that have nothing to do with the operation under test: `tracks.arm` refuses a track that
// is not the selected row, `tracks.mute` finds no key target while the focus sits on a Mixer
// group, and a typed tempo entry starts from a focus it then cannot put back.
//
// So the gate establishes nothing silently. Before the first operation it reads the starting
// state, and every condition that does not hold is named; one unmet condition stops the run. This
// is a check, not a repair: the operator (or the fixture builder) puts Logic into the state, and a
// state that is not there is a refusal rather than something the gate quietly works around.
//
// Read-only throughout (CommitLore r-7e11617670de): a window-server list and AX attribute reads.

/// What was read about Logic's windows and keyboard, beyond the per-operation observation.
struct QualificationStartingWindowFacts: @unchecked Sendable {
    /// Whether the window server and the focused-application read both name Logic as the keyboard
    /// owner. nil when the ownership could not be read.
    let logicOwnsKeyboard: Bool?
    /// Logic's `AXMainWindow`. nil when it did not read.
    let mainWindow: AXUIElement?
    /// The Arrange regions as the product's own read-only enumeration sees them. nil when that
    /// enumeration did not read; an unread selection is never "nothing selected".
    let selectedRegions: SelectedRegionEventListReader.SelectionObservation?
    /// Every read this snapshot needed and did not get.
    let unreadable: [String]

    init(
        logicOwnsKeyboard: Bool?, mainWindow: AXUIElement?,
        selectedRegions: SelectedRegionEventListReader.SelectionObservation?,
        unreadable: [String] = []
    ) {
        self.logicOwnsKeyboard = logicOwnsKeyboard
        self.mainWindow = mainWindow
        self.selectedRegions = selectedRegions
        self.unreadable = unreadable
    }
}

/// Everything the starting-state decision reads. A value of nil is "could not be read", which is
/// itself an unmet condition and never "nothing there".
struct QualificationStartingStateReadings: @unchecked Sendable {
    let ui: QualificationUIObservation?
    let windowFacts: QualificationStartingWindowFacts?
    /// The number of tracks `logic://tracks` reports as selected. nil when it did not read.
    let selectedTrackCount: Int?
    /// Whether the transport reads as stopped. nil when it did not read.
    let transportStopped: Bool?

    init(
        ui: QualificationUIObservation?,
        windowFacts: QualificationStartingWindowFacts?,
        selectedTrackCount: Int?,
        transportStopped: Bool?
    ) {
        self.ui = ui
        self.windowFacts = windowFacts
        self.selectedTrackCount = selectedTrackCount
        self.transportStopped = transportStopped
    }
}

enum QualificationStartingState {
    /// Every string names ONE unmet condition and starts with this prefix.
    static let unmetPrefix = "starting_state_unmet:"

    /// The unmet conditions, in a fixed order. Empty means the gate may start.
    static func unmetConditions(_ readings: QualificationStartingStateReadings) -> [String] {
        var unmet: [String] = []
        func add(_ condition: String) { unmet.append("\(unmetPrefix) \(condition)") }

        if let ui = readings.ui {
            for read in ui.unreadable { add("ui_unreadable(\(read))") }
            if !ui.axWindowsRead { add("ui_unreadable(the AXWindows list did not read)") }
            if ui.focusStatus != 0 { add("focus_unreadable(AXError \(ui.focusStatus))") }
            for (number, facts) in ui.menuLayerWindows.sorted(by: { $0.key < $1.key }) {
                add("layer_101_menu_open(window \(number), \(facts.summary))")
            }
            for (number, facts) in ui.modalLayerWindows.sorted(by: { $0.key < $1.key }) {
                add("modal_present(window \(number), \(facts.summary))")
            }
            for window in ui.axWindows where window.modal == true {
                add("modal_present(AXModal window \"\(window.title ?? "")\")")
            }
            // The project window is the only window there may be. A plug-in editor, the Marker
            // List and any other window an earlier session left open are extra windows. A tooltip
            // is not a window the operator left: it follows the pointer, and is excused only by a
            // role that READ as AXHelpTag.
            if ui.axWindowsRead {
                let realWindows = ui.axWindows.filter { !$0.helpTag }
                if realWindows.isEmpty { add("no_project_window(Logic has no open window)") }
                if realWindows.count > 1 {
                    let titles = realWindows.map { "\"\($0.title ?? "")\"" }.joined(separator: ", ")
                    add("extra_window_open(\(realWindows.count) windows: \(titles))")
                }
            }
            if let facts = readings.windowFacts {
                for read in facts.unreadable { add("ui_unreadable(\(read))") }
                if facts.logicOwnsKeyboard == false {
                    add("main_window_not_frontmost(Logic does not own the keyboard)")
                }
                if let focus = ui.focus, ui.focusStatus == 0, let main = facts.mainWindow {
                    if let window = focus.window {
                        if !CFEqual(window, main) {
                            add("main_window_not_frontmost(the focus is in \"\(focus.windowTitle ?? "")\", not the main window)")
                        }
                    } else {
                        add("main_window_not_frontmost(the focused element has no window)")
                    }
                } else if facts.mainWindow == nil, facts.unreadable.isEmpty {
                    add("main_window_not_frontmost(Logic has no main window)")
                }
                // The MIDI-region read ops act on the selected region: exactly one, a MIDI one.
                if let regions = facts.selectedRegions {
                    if !regions.scopeComplete {
                        add("selected_region_scope_incomplete(the Arrange regions were not read in full)")
                    } else if regions.selected.count != 1 {
                        add("selected_region_count(\(regions.selected.count) regions are selected, exactly one MIDI region is required)")
                    } else if let region = regions.selected.first, region.kind != "midi" {
                        add("selected_region_not_midi(the selected region \"\(region.name)\" is \(region.kind))")
                    }
                } else {
                    add("selected_region_unreadable(the Arrange region selection did not read)")
                }
            } else {
                add("ui_unreadable(the window facts did not read)")
            }
            if let focus = ui.focus, ui.focusStatus == 0, !isTrackGroup(focus) {
                add("focus_not_on_track_group(\(focus.summary))")
            }
        } else {
            add("ui_unreadable(Logic is not running or its windows cannot be read)")
        }

        switch readings.selectedTrackCount {
        case nil: add("selected_track_unreadable(logic://tracks did not report the selection)")
        case 1?: break
        case let count?:
            add("selected_track_count(\(count) tracks are selected, exactly one is required)")
        }
        switch readings.transportStopped {
        case nil: add("transport_unreadable(logic://transport/state did not read)")
        case true?: break
        case false?: add("transport_not_stopped(the transport is playing, paused or recording)")
        }
        return unmet
    }

    /// The keyboard focus is the arrange view's track group: an AXGroup whose description is the
    /// arrange view's own label (`AXLocalePolicy.arrangeWindowTitleSuffix`, derived from Logic's
    /// own strings for every locale). A mixer strip group, a Mixer group, a text field and the
    /// bare window all fail it.
    static func isTrackGroup(_ focus: QualificationFocusIdentity) -> Bool {
        focus.role == (kAXGroupRole as String)
            && AXLocalePolicy.arrangeWindowTitleSuffix.containsNormalized(focus.description)
    }

    // MARK: production reader

    /// Logic's keyboard owner and main window. The window server is listed BEFORE the first AX
    /// focus read: a fresh process's first AX focus read answers -25204 otherwise (measured).
    static func observeLogicWindows() -> QualificationStartingWindowFacts {
        observeLogicWindows(
            runningPID: { LogicProTarget.runningApplication()?.processIdentifier },
            keyboardOwnership: { ProcessUtils.keyboardOwnershipObservation() },
            runtime: .production)
    }

    static func observeLogicWindows(
        runningPID: () -> pid_t?,
        keyboardOwnership: () -> ProcessUtils.KeyboardOwnershipObservation,
        selectedRegions: () -> SelectedRegionEventListReader.SelectionObservation? = {
            AccessibilityChannel.selectedRegionObservation()
        },
        runtime: AXHelpers.Runtime
    ) -> QualificationStartingWindowFacts {
        guard let pid = runningPID() else {
            return QualificationStartingWindowFacts(
                logicOwnsKeyboard: nil, mainWindow: nil, selectedRegions: nil,
                unreadable: ["Logic application not found by the running-application lookup"])
        }
        var unreadable: [String] = []
        let ownership = keyboardOwnership()
        // The window server decides where keystrokes go; an unreadable window list is the only
        // case where the owner is unknown. Any other reason is a definite answer, ready or not.
        let owns: Bool? = ownership.reason == .windowListUnavailable ? nil : ownership.isReady
        if owns == nil {
            unreadable.append("keyboard owner not read (\(ownership.reason.rawValue))")
        }
        var main: AXUIElement?
        let root = runtime.axApp(pid)
        switch AXHelpers.getAttributeResult(root, kAXMainWindowAttribute as String, runtime: runtime)
            as Result<AXUIElement?, AXHelpers.AXStatusError> {
        case .success(let window): main = window
        case .failure(let error) where error.isDefinitiveAbsence: main = nil
        case .failure(let error): unreadable.append("AXMainWindow AXError \(error.raw)")
        }
        return QualificationStartingWindowFacts(
            logicOwnsKeyboard: owns, mainWindow: main,
            selectedRegions: selectedRegions(), unreadable: unreadable)
    }

    // MARK: product reads

    /// The number of selected rows in a `logic://tracks` body, nil when the body is not a track
    /// list. A row that does not state `isSelected` as a Bool is not counted as selected AND makes
    /// the whole read unreadable: an unstated flag is not "not selected".
    static func selectedTrackCount(tracksResource data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]], !rows.isEmpty else { return nil }
        var count = 0
        for row in rows {
            guard let selected = row["isSelected"] as? Bool else { return nil }
            if selected { count += 1 }
        }
        return count
    }

    /// The row index of the single selected track in a `logic://tracks` body. nil when none, more
    /// than one, or an unreadable body: a recipe must never pick a row that is not THE selection.
    static func selectedTrackIndex(tracksResource data: Data) -> Int? {
        guard selectedTrackCount(tracksResource: data) == 1,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else { return nil }
        return rows.firstIndex { ($0["isSelected"] as? Bool) == true }
    }
}
