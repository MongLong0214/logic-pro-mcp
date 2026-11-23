import ApplicationServices
import CoreGraphics
import Foundation

// Per-operation UI invariants for the live driver.
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

/// One of Logic's AX windows. Identity is the AX element (CFEqual), never the descriptive fields:
/// two windows with the same title and subrole are two windows.
struct QualificationAXWindowFacts: Equatable, @unchecked Sendable {
    let element: AXUIElement
    let title: String?
    let subrole: String?
    let modal: Bool?
    /// True only when the window's AXRole READ and named AXHelpTag (a tooltip). A role that could not
    /// be read, or reads anything else, is false: such a window is never excused.
    let helpTag: Bool
    /// The window's AXPosition and AXSize as read, nil when either did not read.
    let frame: CGRect?

    init(
        element: AXUIElement, title: String?, subrole: String?, modal: Bool?,
        helpTag: Bool = false, frame: CGRect? = nil
    ) {
        self.element = element
        self.title = title
        self.subrole = subrole
        self.modal = modal
        self.helpTag = helpTag
        self.frame = frame
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.element, rhs.element) && lhs.title == rhs.title && lhs.subrole == rhs.subrole
            && lhs.modal == rhs.modal && lhs.helpTag == rhs.helpTag && lhs.frame == rhs.frame
    }
}

/// The keyboard-focused element. Identity is the AX element and its window, compared with CFEqual
///: distinct controls Logic describes identically (same role, same description, same
/// window title) are different focus targets. The descriptive fields only name it in a violation.
struct QualificationFocusIdentity: Equatable, @unchecked Sendable {
    let element: AXUIElement
    let window: AXUIElement?
    let role: String?
    let subrole: String?
    let description: String?
    let windowTitle: String?

    var summary: String {
        "\(role ?? "?")/\(subrole ?? "-") \"\(description ?? "")\" in \"\(windowTitle ?? "")\""
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard CFEqual(lhs.element, rhs.element) else { return false }
        switch (lhs.window, rhs.window) {
        case (nil, nil): return true
        case let (left?, right?): return CFEqual(left, right)
        default: return false
        }
    }
}

struct QualificationUIObservation: Equatable, Sendable {
    /// Logic-owned windows at exactly the popup-menu layer (101).
    let menuLayerWindows: [Int: QualificationWindowFacts]
    /// Logic-owned windows at the modal-panel layer.
    let modalLayerWindows: [Int: QualificationWindowFacts]
    /// Every other Logic-owned on-screen window, by window-server number.
    let windows: [Int: QualificationWindowFacts]
    /// Logic's AX windows. Meaningful only when `axWindowsRead`.
    let axWindows: [QualificationAXWindowFacts]
    /// False when the AXWindows list itself did not read: an empty `axWindows` is then unknown.
    let axWindowsRead: Bool
    /// False when the window-server list was never taken (Logic not found, or no list returned):
    /// the empty `windows` is then unknown, and no window delta can be judged against it.
    let windowListRead: Bool
    let focus: QualificationFocusIdentity?
    /// The AXError of the focus read. Anything but 0 is a violation: a read that did not happen is
    /// not "no focus".
    let focusStatus: Int32
    /// Every read this observation needed and did not get. Each one fails the
    /// operation as `ui_invariant_unreadable`; none is ever taken as an empty answer.
    let unreadable: [String]

    init(
        menuLayerWindows: [Int: QualificationWindowFacts] = [:],
        modalLayerWindows: [Int: QualificationWindowFacts] = [:],
        windows: [Int: QualificationWindowFacts] = [:],
        axWindows: [QualificationAXWindowFacts] = [],
        axWindowsRead: Bool = true,
        windowListRead: Bool = true,
        focus: QualificationFocusIdentity? = nil,
        focusStatus: Int32 = 0,
        unreadable: [String] = []
    ) {
        self.windowListRead = windowListRead
        self.menuLayerWindows = menuLayerWindows
        self.modalLayerWindows = modalLayerWindows
        self.windows = windows
        self.axWindows = axWindows
        self.axWindowsRead = axWindowsRead
        self.focus = focus
        self.focusStatus = focusStatus
        self.unreadable = unreadable
    }

    /// Whether `facts` is the window-server twin of a tooltip in THIS observation: unnamed, and with
    /// exactly the frame of an AX window whose role read as AXHelpTag.
    func isReadHelpTagTwin(_ facts: QualificationWindowFacts) -> Bool {
        guard facts.title?.isEmpty ?? true, let bounds = facts.bounds else { return false }
        return axWindows.contains { $0.helpTag && $0.frame == bounds }
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
        axWindowsRead: Bool = true,
        focus: QualificationFocusIdentity?,
        focusStatus: Int32,
        unreadable: [String] = []
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
            axWindows: axWindows, axWindowsRead: axWindowsRead, focus: focus, focusStatus: focusStatus,
            unreadable: unreadable)
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
        // A tooltip appears and disappears with the pointer, not with the operation (measured on
        // Logic 13: layer 103, AXRole AXHelpTag, 32x19). It is excused ONLY when its AX role READ as
        // AXHelpTag; its window-server twin is the unnamed window with exactly that AX frame.
        // A window list that was never read is unknown, not empty: every on-screen window would
        // otherwise be reported as newly opened (measured: the main window, native run 9e6d22b7-r2).
        // The unreadable read itself is reported below and still fails the operation.
        let windowDeltaJudgeable = before.windowListRead && after.windowListRead
        for number in (windowDeltaJudgeable ? Set(after.windows.keys).subtracting(before.windows.keys).sorted() : []) {
            if after.windows[number].map(after.isReadHelpTagTwin) == true { continue }
            let summary = after.windows[number]?.summary ?? "?"
            found.append("ui_invariant: window_left_open(window \(number), \(summary))")
        }
        for number in (windowDeltaJudgeable ? Set(before.windows.keys).subtracting(after.windows.keys).sorted() : []) {
            if before.windows[number].map(before.isReadHelpTagTwin) == true { continue }
            let summary = before.windows[number]?.summary ?? "?"
            found.append("ui_invariant: window_closed(window \(number), \(summary))")
        }
        if before.axWindowsRead, after.axWindowsRead {
            for window in after.axWindows
            where !window.helpTag && !before.axWindows.contains(where: { CFEqual($0.element, window.element) }) {
                found.append(
                    "ui_invariant: window_left_open(AX \"\(window.title ?? "")\" subrole \(window.subrole ?? "-"))")
            }
            for window in before.axWindows
            where !window.helpTag && !after.axWindows.contains(where: { CFEqual($0.element, window.element) }) {
                found.append(
                    "ui_invariant: window_closed(AX \"\(window.title ?? "")\" subrole \(window.subrole ?? "-"))")
            }
        }
        for read in after.unreadable {
            found.append("ui_invariant: ui_invariant_unreadable(after: \(read))")
        }
        for read in before.unreadable {
            found.append("ui_invariant: ui_invariant_unreadable(baseline: \(read))")
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

    // MARK: baseline

    /// The baseline is read before anything is sent, so re-reading it cannot hide an effect of the
    /// operation. Only a window-server list that was never taken (Logic not found by the lookup) is
    /// retried, up to `limit`; the last reading is returned as is and, if still unreadable, still
    /// fails the operation as `ui_invariant_unreadable(baseline: ...)`.
    static func settledBaseline(
        observe: () -> QualificationUIObservation?,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        interval: TimeInterval = settleInterval,
        limit: TimeInterval = settleLimit
    ) -> QualificationUIObservation? {
        var waited: TimeInterval = 0
        var reading = observe()
        while let current = reading, !current.windowListRead, waited < limit {
            sleep(interval)
            waited += interval
            reading = observe()
        }
        return reading
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
        observeLogic(
            runningPID: { LogicProTarget.runningApplication()?.processIdentifier },
            windowList: {
                CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
            },
            runtime: .production)
    }

    /// A reading that cannot be taken is returned as an observation that names the missing read
    /// (`unreadable`), so the operation still fails closed and the failure says WHICH read was
    /// missing instead of a generic "cannot be read".
    static func observeLogic(
        runningPID: () -> pid_t?,
        windowList: () -> [[String: Any]]?,
        runtime: AXHelpers.Runtime
    ) -> QualificationUIObservation {
        guard let pid = runningPID() else {
            return QualificationUIObservation(
                axWindowsRead: false, windowListRead: false, focusStatus: Int32(AXError.cannotComplete.rawValue),
                unreadable: ["Logic application not found by the running-application lookup"])
        }
        guard let cg = windowList() else {
            return QualificationUIObservation(
                axWindowsRead: false, windowListRead: false, focusStatus: Int32(AXError.cannotComplete.rawValue),
                unreadable: ["CGWindowListCopyWindowInfo returned no list"])
        }
        return observeLogic(pid: pid, cgWindows: cg, runtime: runtime)
    }

    static func observeLogic(
        pid: pid_t, cgWindows cg: [[String: Any]], runtime: AXHelpers.Runtime
    ) -> QualificationUIObservation {
        let root = runtime.axApp(pid)
        var unreadable: [String] = []
        /// A descriptive string field: a value or a definitive absence (-25205/-25212) is an answer;
        /// any other status is recorded as unreadable, never as nil.
        func text(_ element: AXUIElement, _ attribute: String, _ what: String) -> String? {
            switch AXHelpers.getAttributeResult(element, attribute, runtime: runtime)
                as Result<String?, AXHelpers.AXStatusError> {
            case .success(let value): return value
            case .failure(let error) where error.isDefinitiveAbsence: return nil
            case .failure(let error):
                unreadable.append("\(what) \(attribute) AXError \(error.raw)")
                return nil
            }
        }
        var axWindows: [QualificationAXWindowFacts] = []
        var axWindowsRead = false
        switch AXHelpers.getAttributeResult(root, kAXWindowsAttribute as String, runtime: runtime)
            as Result<[AXUIElement]?, AXHelpers.AXStatusError> {
        case .success(let windows?):
            axWindowsRead = true
            axWindows = windows.map { window in
                let title = text(window, kAXTitleAttribute as String, "window")
                let subrole = text(window, kAXSubroleAttribute as String, "window \"\(title ?? "")\"")
                let helpTag = AccessibilityChannel.windowRoleReadsAsHelpTag(window, runtime: runtime)
                var frame: CGRect?
                if let origin = AXHelpers.getPosition(window, runtime: runtime),
                   let size = AXHelpers.getSize(window, runtime: runtime) {
                    frame = CGRect(origin: origin, size: size)
                }
                // AXModal is the modal invariant itself: only a Bool is a reading. 0c4ada89 recorded a
                // real blocker passing when an entry's absent AXModal was taken as "not modal". The one
                // exception is the recorded #1063 rule: an entry whose role READS as AXHelpTag is a
                // tooltip (measured after a Logic 13 insert, role AXHelpTag,
                // AXModal -25205, CG layer 103). It is still an AX window, so its appearing or closing
                // is a window delta; a failed or other role keeps the entry unreadable.
                var modal: Bool?
                switch AXHelpers.getAttributeResult(window, "AXModal", runtime: runtime)
                    as Result<Bool?, AXHelpers.AXStatusError> {
                case .success(let value?): modal = value
                case .success(nil):
                    if !helpTag {
                        unreadable.append("window \"\(title ?? "")\" AXModal absent")
                    }
                case .failure(let error):
                    if !helpTag {
                        unreadable.append("window \"\(title ?? "")\" AXModal AXError \(error.raw)")
                    }
                }
                return QualificationAXWindowFacts(
                    element: window, title: title, subrole: subrole, modal: modal, helpTag: helpTag, frame: frame)
            }
        case .success(nil):
            unreadable.append("AXWindows absent")
        case .failure(let error):
            unreadable.append("AXWindows AXError \(error.raw)")
        }
        var focus: QualificationFocusIdentity?
        var status: Int32 = 0
        let read: Result<AXUIElement?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            root, kAXFocusedUIElementAttribute as String, runtime: runtime)
        switch read {
        case .success(let element?):
            var window: AXUIElement?
            switch AXHelpers.getAttributeResult(element, kAXWindowAttribute as String, runtime: runtime)
                as Result<AXUIElement?, AXHelpers.AXStatusError> {
            case .success(let value): window = value
            case .failure(let error) where error.isDefinitiveAbsence: window = nil
            case .failure(let error):
                unreadable.append("focus AXWindow AXError \(error.raw)")
            }
            // Descriptive only: they name the element in a violation and take no part in identity.
            let subrole: String? = (AXHelpers.getAttributeResult(element, kAXSubroleAttribute as String, runtime: runtime)
                as Result<String?, AXHelpers.AXStatusError>).successValue ?? nil
            focus = QualificationFocusIdentity(
                element: element, window: window,
                role: AXHelpers.getRole(element, runtime: runtime), subrole: subrole,
                description: AXHelpers.getDescription(element, runtime: runtime),
                windowTitle: window.flatMap { AXHelpers.getTitle($0, runtime: runtime) })
        case .success(nil):
            status = Int32(AXError.noValue.rawValue)
        case .failure(let error):
            status = error.raw
        }
        return observation(
            cgWindows: cg, logicPID: pid, axWindows: axWindows, axWindowsRead: axWindowsRead,
            focus: focus, focusStatus: status, unreadable: unreadable)
    }
}

private extension Result {
    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
