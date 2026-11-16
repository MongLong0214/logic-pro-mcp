import ApplicationServices
import CoreGraphics
import Foundation

// DESIGN §2 (analysis-gate): per-operation UI invariants for the live driver.
//
// After every operation the gate used to look at nothing but the operation's own reply, so a
// layer-101 menu left on screen (measured: a 234x355 window at 1077,98 after record_sequence), a
// plug-in editor or Marker List window left open, a modal, or keyboard focus moved off where it was
// were invisible to the test and silently disarmed every operation that ran after them.
//
// The host side stays READ-ONLY (CommitLore r-7e11617670de): the window server list read through
// `CGWindowListCopyWindowInfo` and AX attribute reads of Logic's application element. Nothing is
// actuated.

struct QualificationWindowFacts: Equatable, Sendable {
    let layer: Int
    let title: String?
    let bounds: CGRect?

    var summary: String {
        let box = bounds.map {
            "\(Int($0.width))x\(Int($0.height))@\(Int($0.origin.x)),\(Int($0.origin.y))"
        } ?? "no-bounds"
        return "layer \(layer) \(box)" + (title.map { " \"\($0)\"" } ?? "")
    }
}

struct QualificationAXWindowFacts: Equatable, Hashable, Sendable {
    let title: String?
    let subrole: String?
    let modal: Bool?
}

struct QualificationFocusIdentity: Equatable, Sendable {
    let role: String?
    let subrole: String?
    let description: String?
    let windowTitle: String?

    var summary: String {
        "\(role ?? "?")/\(subrole ?? "-") \"\(description ?? "")\" in \"\(windowTitle ?? "")\""
    }
}

struct QualificationUIObservation: Equatable, Sendable {
    /// Logic-owned windows at exactly the popup-menu layer (101).
    let menuLayerWindows: [Int: QualificationWindowFacts]
    /// Logic-owned windows at the modal-panel layer.
    let modalLayerWindows: [Int: QualificationWindowFacts]
    /// Every other Logic-owned on-screen window, by window-server number.
    let windows: [Int: QualificationWindowFacts]
    /// Logic's AX windows, as a multiset keyed by title and subrole.
    let axWindows: [QualificationAXWindowFacts]
    let focus: QualificationFocusIdentity?
    /// The AXError of the focus read. Anything but 0 is a violation: a read that did not happen is
    /// not "no focus".
    let focusStatus: Int32

    init(
        menuLayerWindows: [Int: QualificationWindowFacts] = [:],
        modalLayerWindows: [Int: QualificationWindowFacts] = [:],
        windows: [Int: QualificationWindowFacts] = [:],
        axWindows: [QualificationAXWindowFacts] = [],
        focus: QualificationFocusIdentity? = nil,
        focusStatus: Int32 = 0
    ) {
        self.menuLayerWindows = menuLayerWindows
        self.modalLayerWindows = modalLayerWindows
        self.windows = windows
        self.axWindows = axWindows
        self.focus = focus
        self.focusStatus = focusStatus
    }
}

enum QualificationUIInvariants {
    /// A closing window keeps its id, unnamed, for about 1.3 s (measured), so the verdict is the
    /// reading after the screen settles, not the first one.
    static let settleInterval: TimeInterval = 0.1
    static let settleLimit: TimeInterval = 2.0

    // MARK: build an observation from raw readings

    static func observation(
        cgWindows: [[String: Any]],
        logicPID: pid_t,
        axWindows: [QualificationAXWindowFacts],
        focus: QualificationFocusIdentity?,
        focusStatus: Int32
    ) -> QualificationUIObservation {
        let menuLevel = LogicOnScreenWindows.popupMenuLevel
        let modalLevel = LogicOnScreenWindows.modalPanelLevel
        var menus: [Int: QualificationWindowFacts] = [:]
        var modals: [Int: QualificationWindowFacts] = [:]
        var others: [Int: QualificationWindowFacts] = [:]
        for entry in LogicOnScreenWindows.logicOwned(cgWindows, logicPID: logicPID) {
            let facts = QualificationWindowFacts(layer: entry.layer, title: entry.name, bounds: entry.bounds)
            if entry.layer == menuLevel {
                menus[entry.number] = facts
            } else if entry.layer == modalLevel {
                modals[entry.number] = facts
            } else {
                others[entry.number] = facts
            }
        }
        return QualificationUIObservation(
            menuLayerWindows: menus, modalLayerWindows: modals, windows: others,
            axWindows: axWindows, focus: focus, focusStatus: focusStatus)
    }

    // MARK: rules

    /// Absolute rules (no baseline needed) plus the delta against `before`. Every string starts
    /// with `ui_invariant:`.
    static func violations(
        before: QualificationUIObservation,
        after: QualificationUIObservation
    ) -> [String] {
        var found: [String] = []
        for (number, facts) in after.menuLayerWindows.sorted(by: { $0.key < $1.key }) {
            found.append("ui_invariant: logic_menu_layer_101_open(window \(number), \(facts.summary))")
        }
        for (number, facts) in after.modalLayerWindows.sorted(by: { $0.key < $1.key }) {
            found.append("ui_invariant: modal_present(window \(number), \(facts.summary))")
        }
        for window in after.axWindows where window.modal == true {
            found.append("ui_invariant: modal_present(AXModal window \"\(window.title ?? "")\")")
        }
        for number in Set(after.windows.keys).subtracting(before.windows.keys).sorted() {
            let summary = after.windows[number]?.summary ?? "?"
            found.append("ui_invariant: window_left_open(window \(number), \(summary))")
        }
        for number in Set(before.windows.keys).subtracting(after.windows.keys).sorted() {
            let summary = before.windows[number]?.summary ?? "?"
            found.append("ui_invariant: window_closed(window \(number), \(summary))")
        }
        let beforeAX = multiset(before.axWindows)
        let afterAX = multiset(after.axWindows)
        for (window, count) in afterAX where count > (beforeAX[window] ?? 0) {
            found.append(
                "ui_invariant: window_left_open(AX \"\(window.title ?? "")\" subrole \(window.subrole ?? "-"))")
        }
        for (window, count) in beforeAX where count > (afterAX[window] ?? 0) {
            found.append(
                "ui_invariant: window_closed(AX \"\(window.title ?? "")\" subrole \(window.subrole ?? "-"))")
        }
        if after.focusStatus != 0 {
            found.append("ui_invariant: focus_unreadable(AXError \(after.focusStatus))")
        } else if before.focusStatus != 0 {
            found.append("ui_invariant: focus_baseline_unreadable(AXError \(before.focusStatus))")
        } else if after.focus != before.focus {
            found.append(
                "ui_invariant: focus_moved(\(before.focus?.summary ?? "none") -> \(after.focus?.summary ?? "none"))")
        }
        return found
    }

    private static func multiset(_ windows: [QualificationAXWindowFacts]) -> [QualificationAXWindowFacts: Int] {
        windows.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    // MARK: settle

    /// Re-observes while a violation persists, up to `limit`, and returns the FINAL reading's
    /// violations. A reading that cannot be taken at all is itself a violation.
    static func settledViolations(
        before: QualificationUIObservation,
        observe: () -> QualificationUIObservation?,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        interval: TimeInterval = settleInterval,
        limit: TimeInterval = settleLimit
    ) -> [String] {
        var waited: TimeInterval = 0
        while true {
            guard let after = observe() else {
                return ["ui_invariant: observation_unavailable(Logic is not running or its windows cannot be read)"]
            }
            let found = violations(before: before, after: after)
            if found.isEmpty || waited >= limit { return found }
            sleep(interval)
            waited += interval
        }
    }

    // MARK: production reader

    /// The live reader. It lists the window server BEFORE the first AX focus read: a fresh
    /// process's first AX focus read answers -25204 otherwise (measured). Read-only throughout.
    static func observeLogic() -> QualificationUIObservation? {
        guard let app = LogicProTarget.runningApplication() else { return nil }
        let pid = app.processIdentifier
        guard let cg = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        let root = AXUIElementCreateApplication(pid)
        var axWindows: [QualificationAXWindowFacts] = []
        if case .success(let windows?) = AXHelpers.getAttributeResult(root, kAXWindowsAttribute as String)
            as Result<[AXUIElement]?, AXHelpers.AXStatusError> {
            axWindows = windows.map { window in
                let modal: Bool? = (AXHelpers.getAttributeResult(window, "AXModal")
                    as Result<Bool?, AXHelpers.AXStatusError>).successValue ?? nil
                let subrole: String? = (AXHelpers.getAttributeResult(window, kAXSubroleAttribute as String)
                    as Result<String?, AXHelpers.AXStatusError>).successValue ?? nil
                return QualificationAXWindowFacts(
                    title: AXHelpers.getTitle(window), subrole: subrole, modal: modal)
            }
        }
        var focus: QualificationFocusIdentity?
        var status: Int32 = 0
        let read: Result<AXUIElement?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            root, kAXFocusedUIElementAttribute as String)
        switch read {
        case .success(let element?):
            let subrole: String? = (AXHelpers.getAttributeResult(element, kAXSubroleAttribute as String)
                as Result<String?, AXHelpers.AXStatusError>).successValue ?? nil
            let window: AXUIElement? = (AXHelpers.getAttributeResult(element, kAXWindowAttribute as String)
                as Result<AXUIElement?, AXHelpers.AXStatusError>).successValue ?? nil
            focus = QualificationFocusIdentity(
                role: AXHelpers.getRole(element), subrole: subrole,
                description: AXHelpers.getDescription(element),
                windowTitle: window.flatMap { AXHelpers.getTitle($0) })
        case .success(nil):
            status = Int32(AXError.noValue.rawValue)
        case .failure(let error):
            status = error.raw
        }
        return observation(
            cgWindows: cg, logicPID: pid, axWindows: axWindows, focus: focus, focusStatus: status)
    }
}

private extension Result {
    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
