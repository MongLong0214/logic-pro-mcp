import ApplicationServices
import Foundation

/// A marker operation that has to look at Logic's Marker List opens that window when it is not
/// already open. Opening it moves the key view into the list, and nothing used to close it again:
/// the window stayed on screen and every later operation inherited the moved focus. An operation
/// must close what it opened and put the focus back.
///
/// Ownership is exact: only a Marker List window that was NOT in the window census before the
/// operation, and that is the bound Marker List now, is closed. A list the user already had open
/// is never touched.
extension AccessibilityChannel {
    struct MarkerListOrigin: @unchecked Sendable {
        let app: AXUIElement
        let windows: [AXUIElement]
        let listWasOpen: Bool
        let main: AXUIElement?
        let focusedWindow: AXUIElement?
        let focusedElement: AXUIElement?
    }

    struct MarkerListRestoration: Equatable, Sendable {
        /// True when this operation opened the list and it is gone again.
        let closed: Bool
        /// True when focus (window and element) reads as it did before the operation.
        let focusRestored: Bool
        /// Why a restoration step did not hold; nil when everything did.
        let reason: String?
    }

    /// The screen as it was before `nav.open_marker_list` opened the list on behalf of a caller that
    /// will release it (`nav.release_marker_list`). One slot: marker operations hold the mutation
    /// gate, so two cannot interleave.
    private final class OpenedListLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var origin: MarkerListOrigin?
        func record(_ value: MarkerListOrigin) { lock.withLock { origin = value } }
        func take() -> MarkerListOrigin? { lock.withLock { let value = origin; origin = nil; return value } }
    }
    private static let openedListLedger = OpenedListLedger()

    static func recordOpenedMarkerList(_ origin: MarkerListOrigin) {
        guard !origin.listWasOpen else { return }
        openedListLedger.record(origin)
    }

    /// Closes the list `nav.open_marker_list` opened and restores focus. Answers State A with
    /// `marker_list_closed` / `ui_restored`; with nothing recorded it states that nothing was owned.
    static func releaseMarkerList(runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        guard let origin = openedListLedger.take() else {
            return .success(HonestContract.encodeStateA(extras: [
                "operation": "nav.release_marker_list", "owned": false,
            ]))
        }
        let restoration = await restoreMarkerListOrigin(origin, runtime: runtime)
        var extras: [String: Any] = [
            "operation": "nav.release_marker_list", "owned": true,
            "marker_list_closed": restoration.closed,
            "ui_restored": restoration.closed && restoration.focusRestored,
        ]
        if let reason = restoration.reason { extras["ui_restore_reason"] = reason }
        return .success(HonestContract.encodeStateA(extras: extras))
    }

    static func markerListOrigin(
        runtime: AXLogicProElements.Runtime,
        listWasOpen knownListWasOpen: Bool? = nil
    ) -> MarkerListOrigin? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime),
              let windows: [AXUIElement] = AXHelpers.getAttribute(
                app, kAXWindowsAttribute as String, runtime: runtime.ax) else { return nil }
        return MarkerListOrigin(
            app: app, windows: windows,
            listWasOpen: knownListWasOpen ?? (AXLogicProElements.findMarkerListWindow(runtime: runtime) != nil),
            main: AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: runtime.ax),
            focusedWindow: AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: runtime.ax),
            focusedElement: AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax))
    }

    /// Puts the focus back on the window and element it was on, and answers whether a fresh read
    /// agrees. A write that AX accepted is not evidence: only the re-read counts.
    static func restoreFocus(_ origin: MarkerListOrigin, runtime: AXLogicProElements.Runtime) -> Bool {
        func current(_ attribute: String) -> AXUIElement? {
            AXHelpers.getAttribute(origin.app, attribute, runtime: runtime.ax)
        }
        func same(_ left: AXUIElement?, _ right: AXUIElement?) -> Bool {
            switch (left, right) {
            case (nil, nil): return true
            case let (l?, r?): return CFEqual(l, r)
            default: return false
            }
        }
        func focusMatches() -> Bool {
            same(current(kAXFocusedWindowAttribute as String), origin.focusedWindow)
                && same(current(kAXFocusedUIElementAttribute as String), origin.focusedElement)
        }
        if !focusMatches() {
            if let main = origin.main {
                _ = AXHelpers.setAttribute(main, kAXMainAttribute as String, kCFBooleanTrue, runtime: runtime.ax)
            }
            if let window = origin.focusedWindow {
                _ = AXHelpers.setAttribute(window, kAXFocusedAttribute as String, kCFBooleanTrue, runtime: runtime.ax)
            }
            if let element = origin.focusedElement {
                _ = AXHelpers.setAttribute(element, kAXFocusedAttribute as String, kCFBooleanTrue, runtime: runtime.ax)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return focusMatches()
    }

    /// Runs a synchronous operation that moves the key view (a typed entry into a control-bar
    /// field) and puts it back. The response says whether the re-read agrees.
    static func withFocusRestored(
        runtime: AXLogicProElements.Runtime,
        _ operation: () -> ChannelResult
    ) -> ChannelResult {
        guard let origin = markerListOrigin(runtime: runtime, listWasOpen: true) else { return operation() }
        let result = operation()
        let restored = restoreFocus(origin, runtime: runtime)
        return annotate(result, with: ["focus_restored": restored])
    }

    static func restoreMarkerListOrigin(
        _ origin: MarkerListOrigin,
        runtime: AXLogicProElements.Runtime
    ) async -> MarkerListRestoration {
        var reason: String?
        var closed = false
        if !origin.listWasOpen {
            if let list = AXLogicProElements.findMarkerListWindow(runtime: runtime) {
                if origin.windows.contains(where: { CFEqual($0, list) }) {
                    reason = "the Marker List window pre-dates the operation"
                } else if let button: AXUIElement = AXHelpers.getAttribute(
                    list, kAXCloseButtonAttribute as String, runtime: runtime.ax) {
                    _ = AXHelpers.performAction(button, kAXPressAction as String, runtime: runtime.ax)
                    for _ in 0..<30 {
                        if AXLogicProElements.findMarkerListWindow(runtime: runtime) == nil { closed = true; break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if !closed { reason = "the Marker List window did not close" }
                } else {
                    reason = "the Marker List window has no readable close button"
                }
            } else {
                closed = true // the operation never left a list open
            }
        }
        let focusRestored = restoreFocus(origin, runtime: runtime)
        if !focusRestored, reason == nil { reason = "focus did not return to the element it was on" }
        return MarkerListRestoration(closed: closed, focusRestored: focusRestored, reason: reason)
    }

    /// Runs a marker operation and, when it opened the Marker List itself (the opener records the
    /// screen it found in the ledger), closes it and restores focus. The outcome is reported in the
    /// response as `marker_list_closed` / `ui_restored`; the operation's own verdict is never
    /// changed by it. An operation that opened nothing performs no read here.
    static func withMarkerListRestored(
        runtime: AXLogicProElements.Runtime,
        _ operation: () async -> ChannelResult
    ) async -> ChannelResult {
        let result = await operation()
        guard let origin = openedListLedger.take() else { return result }
        let restoration = await restoreMarkerListOrigin(origin, runtime: runtime)
        var extras: [String: Any] = [
            "marker_list_closed": restoration.closed,
            "ui_restored": restoration.closed && restoration.focusRestored,
        ]
        if let reason = restoration.reason { extras["ui_restore_reason"] = reason }
        return annotate(result, with: extras)
    }

    private static func annotate(_ result: ChannelResult, with extras: [String: Any]) -> ChannelResult {
        guard let data = result.message.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return result }
        for (key, value) in extras { object[key] = value }
        guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else { return result }
        switch result {
        case .success: return .success(text)
        case .error: return .error(text)
        }
    }
}
